# SBDEV-3198 step 3 — independent code review of PR #286 (`a35cab5a`)

**Verdict: FIX BEFORE IT BECOMES THE TEMPLATE FOR STEP 4.** The shape is right and the four
invariants the brief singles out are all genuinely pinned (mutation-verified below). But one
finding (H-1) makes the *already-decided* step-4 mitigation unimplementable against this service
API, and one (M-1) silently disables an acceptance criterion for exactly the two jobs step 5
converts. Nothing here is a live-behaviour defect for `staleClubBatchCleanup` itself (it is inert
everywhere), which is why this is "fix before copying", not "fix before merge".

- Lane: independent code review, worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-DPRIME-review-a` @ `a35cab5a` (base `e818ff11`).
- Instruments run: `mvn -o test-compile` — clean. `mvn -o test` over the 8 changed/affected test
  classes — **147 tests, 0 failures**. Seven hand mutants (results inline).
- Findings: **1 High, 6 Medium, 9 Low.**

---

## Mutation verification of the brief's invariants (do not re-litigate these)

Seven hand mutants applied to `src/main`, each run against
`StaleClubBatchCleanupJobUnitTest, TriggerSpecUnitTest, SchedulingConfigurationUnitTest,
SchedulingReconcileIdempotencyUnitTest, AdvisoryLockServicePerTenantLockUnitTest` (107 tests).

| # | mutant | result |
|---|---|---|
| M6 | disarm the caller-context restore at `SchedulingConfiguration.java:884` (`callerContext != null && false`) | **KILLED** — `callerContextIsRestored`. **Invariant 7 is really fixed, not just commented.** |
| M11 | loosen the collapse rule to "day-and-below wildcards" (`TriggerSpec.isZoneInvariant`, `i = 1` → `i = 2`) | **KILLED** — `fixedMinuteIsNotInvariant` + `fixedFieldsKeepTheZone[2]`. **Invariant 3 pinned.** |
| M9 | hold every tenant's lock across the whole group instead of lock/work/unlock per tenant | **KILLED** — `locksAreNeverNested` + `lockKeyIsJobAndTenantPrimaryKey`. **Invariant 6 pinned.** |
| M12 | gate additive-only PER JOB (`registeredJobNames().contains("staleClubBatchCleanup")`) instead of per spec — the exact AC11 trap §4a names | **KILLED** — `tenantAddedAfterBootGetsANewGroupOnReconcile`. **Invariant 4 pinned.** |
| M1 | delete the malformed-row guard in `runFor` (`StaleClubBatchCleanupJob.java:137-144` → `if (false)`) | **SURVIVED** → M-2 |
| M4 | replace `catch (ArithmeticException e)` (`:177`) with an unreachable type | **SURVIVED** → M-2 |
| M8 | make `anyReadFailure` unobservable (`:202` → `if (false)`) | **SURVIVED** → M-2 |

Also confirmed present and correct by reading the diff, not inferred:
**invariant 1** — the lock key is `(JobLockId.STALE_CLUB_BATCH_CLEANUP, tenant_db_configuration.id)`
with `Math.toIntExact`, and there is no hash/ordinal/membership derivation anywhere in the diff;
**invariant 2** — triggers carry `(cronExpression, resolvedZoneId)` and `runFor` re-derives members
from `findByActiveTrue()` on every fire, both directions tested
(`deactivatedTenantStopsImmediately`, `tenantAddedAfterBootGetsANewGroupOnReconcile`);
**invariant 5** — `doCalculation(Boolean)` is **deleted**, not degenerate, and `git grep` finds zero
surviving callers; **invariant 8** — the `never()` census is updated to 144 with
`StaleClubBatchCleanupJobUnitTest:2`, and `NeverMatcherNullBlindnessArchTest` passes 4/4.

---

## HIGH

### H-1 — The service API this PR establishes cannot support the dual-lock mitigation step 4 has already been decided to use; attempting it leaks a landlord connection per fire against a pool of **2**

`AdvisoryLockService` keeps **one** `ThreadLocal<Connection> lockedConnection`
(`AdvisoryLockService.java:43`) shared by both lock forms. The new two-key `tryLock` does
`lockedConnection.set(conn)` at `AdvisoryLockService.java:169`, unconditionally overwriting whatever
the one-key `tryLock(long)` pinned at `:65`. The javadoc names the hazard itself:

> **⚠ Never nest.** This service holds ONE pinned connection per thread. Taking a second lock
> (either form) before releasing the first overwrites the `ThreadLocal` slot and leaks the first
> connection with its lock still held.

The plan then decided the opposite. §7a step 3, *MUST READ before converting `StockSummaryExportJob`*:

> **✅ DECIDED 2026-09-03 (Nam): dual-lock for one release, then drop the one-key form in the next.**
> `StockSummaryExportJob`'s converting release takes **both** `100006L` (whole-job) and
> `(100006, tenantId)` (per-tenant) before doing its per-tenant work

**Failure scenario (step 4, first tick after deploy).** The job does
`tryLock(STOCK_SUMMARY_EXPORT)` → conn **A** pinned, one-key lock held. Per tenant:
`tryLock(STOCK_SUMMARY_EXPORT, id)` → conn **B** pinned, **A is now unreachable with its advisory
lock still held**; `unlock(STOCK_SUMMARY_EXPORT, id)` releases B, closes it, and clears the slot.
After the walk, the outer `unlock(STOCK_SUMMARY_EXPORT)` finds `lockedConnection.get() == null`,
logs *"unlock(100005) called with no pinned connection — tryLock() was not called or already
released"* and returns. The one-key lock is never released and conn A never returns to the pool.
`landlord.datasource.maximum-pool-size=2` (`src/main/resources/application.properties:66`), so the
**second** export tick exhausts the landlord pool — after which every tenant route,
`probeForReachableTenant`, and the reconcile block on `getConnection()`. The symptom is a
process-wide tenant-routing outage that looks nothing like a scheduling change.

The plan's cost analysis for that decision ("the extra acquisition pins one additional landlord
connection only during the overlap window") assumes the second acquisition is *releasable*. Against
this API it is not.

**Fix before copying:** either key the pin per `(classId, objId)` (a small `ThreadLocal<Map>` or
`Deque`), or give the two-key form its own slot, and add a test that acquires one-key then two-key
and releases both — asserting two distinct connections and two `pg_advisory_unlock*` calls. The
existing `doubleUnlockIsSafe` / `closeFailureAfterAcquireClearsThePin` tests cover the
single-form paths only; nothing in the suite exercises nesting, which is why the API and the
decision could drift apart unnoticed.

---

## MEDIUM

### M-2 — Three `runFor` branches are entirely unpinned (mutation-confirmed)

M1, M4 and M8 above each left **all 107 tests green**. Concretely:

- **`SchedulingConfiguration`-mirroring malformed-row guard, `StaleClubBatchCleanupJob.java:137-144`.**
  Its own comment states the stake: *"Without it, a null tenant/blank warehouse throws an NPE that
  escapes THIS loop entirely (profile is unassigned, so the catch below cannot even log which tenant
  failed) and skips every tenant after the bad row for the whole occurrence."* Delete the guard and
  nothing notices. `StaleClubBatchCleanupJobUnitTest` has no malformed-row fixture at all
  (`grep -n "malformed" src/test/.../StaleClubBatchCleanupJobUnitTest.java` → 0 hits).
- **`catch (ArithmeticException e)`, `:177`.** AC12's "deliberately loud" int4 diagnosis is
  unobserved at the job level. `AdvisoryLockServicePerTenantLockUnitTest.tenantIdOverflowIsLoud`
  pins that the *service* throws; nothing pins that the *job* turns it into the named
  configuration ERROR rather than the generic per-tenant one the comment says must not happen.
- **`anyReadFailure`, `:131`/`:202`.** The two group-level log branches — "found no MATCHING
  readable tenant this occurrence" vs "matched no active tenant this occurrence" — collapse into
  one and no test can tell them apart. The whole reason the first branch exists (per its own
  comment: *"so an operator does not conclude the group is simply stale"*) is unprotected.

Three small tests close all three. Given how much of this PR is organised around mutation
evidence, these are the gaps a scoped PIT run on `StaleClubBatchCleanupJob` would have reported —
and §7a step 3 records **no final PIT score** for the new classes, unlike step 2's `118/118`.

### M-3 — The AC2′ UTC-fallback WARN goes silently dead for exactly the two jobs step 5 converts

`SchedulingConfiguration.java:869`:

```java
if ("UTC".equals(spec.zoneId())) {
```

For a zone-invariant cron `TriggerSpec.of` sets `zoneId` to `ZONE_INVARIANT` (`"zone-invariant"`),
so this can never match. `TriggerSpec`'s own javadoc lists `orderRelease` and `replenish` as
zone-invariant while their `*_TIMER_HOUR`/`_MINUTE` sysprops sit at the `*` default — *"true on prd
hydra and all four UAT tenants, measured 2026-09-02"*. So the moment step 5 converts them, a tenant
whose `System Time Zone` sysprop is null/blank/invalid — which `TimezoneService.parseToZoneId`
silently defaults to UTC and then caches for the whole process lifetime, with the only WARN at first
read — is no longer named at registration. That is precisely the "silent third schedule" §4a's
*Remaining honest costs* says the provenance line must prevent.

It is also untested for the invariant case: `utcFallbackIsNamed` uses `0 5 5 * * *`, a zoned cron.

**Fix:** test the *resolved* zone, not the post-collapse field — e.g. have `of()` hand back (or the
caller keep) the pre-collapse `ZoneId`, and assert the WARN fires for `TriggerSpec.of("0 * * * * *",
ZoneId.of("UTC"))`.

### M-4 — `deriveSpecForCurrentTenant`'s no-context guard sits after the reads it protects, so it cannot fire

`StaleClubBatchCleanupJob.java:91-104` reads both timer sysprops, checks them for blank, and *only
then* does:

```java
TenantProfile current = TenantContext.getCurrentTenant();
if (current == null) {
    throw new IllegalStateException(
        "deriveSpecForCurrentTenant() requires TenantContext to be set by the caller");
}
```

With no context, `TenantDynamicRoutingDataSource.determineTargetDataSource` routes to the
**landlord** DataSource (`TenantDynamicRoutingDataSource.java:127-130`, *"No tenant context; routing
to landlord database"*), where `los_sysprop` does not exist — as the probe's own javadoc in this
same file spells out. So the two reads throw a `DataAccessException` first and the guard is
unreachable in production. Failure scenario: a future caller (or a dropped
`setCurrentTenant` in the walk) presents as `relation "los_sysprop" does not exist` inside the
`unreadable` WARN list, not as the named guard — the misdiagnosis this method's own guard exists to
prevent. The javadoc's `@throws IllegalStateException if no tenant context is set (from
TimezoneService)` also names the wrong source; the method throws it itself. No test covers it
(`grep` finds the message only in the two test files' own simulated stubs).

**Fix:** move the context check to the first statement of the method. One line, and it makes the
guard genuinely load-bearing — which matters because "a no-context read must be loud, not silently
null" is the stated lesson of this very slice.

### M-5 — The reconcile now performs a real tenant-DB round trip per tenant every 5 minutes; §4a's "cost is near-zero" is false at this cadence, and the code's own javadoc is now stale

`sysprops` is a Caffeine cache with a **2-minute** TTL (`src/main/java/net/aim_ai/wms/config/CacheConfig.java:36`,
`buildCaffeineCache("sysprops", 200, Duration.ofMinutes(2))`) and `RECONCILE_CRON` is
`"50 */5 * * * *"`. Every entry is therefore expired on every cycle, so
`configureStaleClubBatchCleanupGroups`'s walk **misses on every tenant, every cycle, forever**.
§4a item 2's *"Cost is near-zero — the jobs already ... read `NEW_CRON_JOB_ACTIVATED` +
`*_TIMER_ACTIVATED` per tenant per tick, so two more cached sysprop reads are marginal"* does not
hold for the registration path. Three consequences not covered by the doc's "Third" note:

1. The walk runs inside `synchronized (registrationLock)` (`SchedulingConfiguration.java:624`,
   and the reconcile re-enters it at `:1204`), so the lock is held across N blocking tenant reads.
   An unreachable tenant costs its SBDEV-3204 bound per cycle, and the boot pass contends on the
   same lock.
2. It runs on the shared `ThreadPoolTaskScheduler` with `POOL_SIZE = 10`
   (`SchedulingConfiguration.java:36`) — the same pool that runs the six cron jobs and the 15s
   outbox dispatcher.
3. `reconcileSchedules`' javadoc still reasons *"touching **one** tenant's pool on this cadence
   interacts with `TenantPoolEvictor`'s idle-pool eviction ... at the cost of one pool
   construction"*. It now touches **every** tenant's pool every 5 minutes, which defeats idle-pool
   eviction rather than interacting with it. Multiply by six after step 5.

Not a correctness defect — but it is a stale claim inside the changed file, and the arithmetic
should be restated before step 4 copies the shape. `syspropChangeDoesNotRescheduleAnAlreadyRegisteredJob`
honestly pins `staleClubDerivations == 1` for one tenant; there is no pin at N tenants, so the
proportionality is asserted in prose only.

### M-6 — `"staleClubBatchCleanup"` is a raw literal at five sites while `JOB_NAME` exists and claims to be authoritative

`StaleClubBatchCleanupJob.java:52-53` declares `static final String JOB_NAME = "staleClubBatchCleanup"`
with the javadoc *"The registry / provenance name; must match `SchedulingConfiguration.CONFIGURED_JOB_NAMES`"*.
`SchedulingConfiguration` then uses the literal at `:891`, `:895`, `:901`, `:916` (the value stored
in `Registration.jobName`) and `:933` (`registeredJobNames().contains("staleClubBatchCleanup")`),
plus the `CONFIGURED_JOB_NAMES` entry at `:70`. Nothing enforces the "must match".

Failure scenario: change `:916` without `:933` (or rename the `CONFIGURED_JOB_NAMES` entry) and
`alreadyRegistered` is false forever — the boot pass logs *"staleClubBatchCleanup cron schedule not
configured for any tenant — task not registered"* while the triggers ARE live, `configured`
undercounts by one so *"Only 5/6 scheduled tasks configured"* fires, and *"Scheduled-task
bookkeeping DISAGREES with the registry"* fires every 5 minutes on prd. A three-way string identity
with no single source is the same shape as the sysprop guarded-key hooks in SBDEV-3103.

**Fix:** use `StaleClubBatchCleanupJob.JOB_NAME` at all five sites and derive the
`CONFIGURED_JOB_NAMES` entry from it (both classes are in the same package, so it is already
visible).

### M-7 — Nothing anywhere reports a tenant whose current spec matches no registered trigger

`runFor` can only know its own spec, so it cannot say "tenant X is in no group"; the registration
side reports `noSchedule` (blank sysprops), `unreadable` and `utcFallbacks`, but not "this tenant's
derived spec is not in `registrations`".

Failure scenario: an operator edits a tenant's `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` at 02:52, just
after the 02:50 reconcile. At 03:00 the old group logs *"matched no active tenant this occurrence"*
— which reads as a stale group, not a missed tenant — and the tenant's new spec has no trigger yet,
so it is skipped with nothing naming it. The job's javadoc glosses this as a parenthetical
("*zero if its current spec matches no registered trigger yet*"). Exposure is bounded by the
5-minute reconcile, so for a daily job it is one missed day; for `orderRelease` at step 5 it is up
to five missed minutes, and the same reasoning then applies to a per-minute job where nobody is
watching a daily log line.

**Fix:** in the registration walk, after `groups` is built, list any derived spec that is not in
`registrations` at WARN (it will be non-empty for exactly one cycle after a legitimate edit, and
permanently if a spec keeps failing to schedule — which is the case worth seeing).

---

## LOW

- **L-1** `registeredSpecs()`'s javadoc (`SchedulingConfiguration.java:1269`) still says *"in
  `CONFIGURED_JOB_NAMES` order"*; the body is now a `TreeMap`, i.e. alphabetical by registry key.
  Stale in the method whose output the reconcile's CHANGED line prints.
- **L-2** `TriggerSpec.of(null, zone)` NPEs inside `isZoneInvariant`'s `cronExpression.trim()`
  before the canonical constructor's named `Objects.requireNonNull(cronExpression, "cronExpression")`,
  so the message loses the parameter name. `TriggerSpecUnitTest.nullsRejected` covers
  `of(cron, null)` but not `of(null, zone)`.
- **L-3** Javadoc indentation is broken in `TriggerSpec.java:19-21` — three continuation lines are
  indented `     * ` instead of ` * `, so the "Always construct through `of()`" paragraph renders as
  a code block.
- **L-4** `catch (ArithmeticException e)` at `StaleClubBatchCleanupJob.java:177` also catches an
  `ArithmeticException` raised inside `cleanupStaleBatches()` (ordinary business arithmetic) and
  would misreport it as *"tenant_db_configuration.id N does not fit int4 ... skipped every
  occurrence until the id is fixed"*. Narrow it: convert the id once at the top of the iteration
  (`int objId = Math.toIntExact(config.getId());`) instead of catching the type around the work.
- **L-5** `AdvisoryLockServicePerTenantLockUnitTest.outboxAndIdempotencyStayOneKey` asserts
  `doesNotContainPattern("tryLock\\([^)]*,[^)]*\\)")` / `"unlock\\([^)]*,[^)]*\\)"` over the whole
  source of two files. A javadoc mention of `tryLock(long, long)`, or a
  `LOG.debug("unlock({}, {})", a, b)` line, would red the pin with a message unrelated to its
  purpose. Anchor to a call site (`advisoryLockService.tryLock(`).
- **L-6** `runFor`'s `active.isEmpty()` WARN (*"No tenants configured. Skipping {} for {}."*,
  `:127`) now fires once **per group per occurrence** rather than once per job — two identical
  whole-fleet-sounding WARNs per tick at UAT's two groups.
- **L-7** `timezoneService.getWarehouseZoneId(current.getFacilityCode())` (`:102`) uses the
  explicit-facility overload to ask for the current tenant's own facility, which is what the no-arg
  `getWarehouseZoneId()` already does. That overload's javadoc says it is *"Reserved for callers
  that look up a facility other than the one in TenantContext"*.
- **L-8** The single-source-of-truth claim (*"Both sides MUST use this method"*) is not tested
  end-to-end. `SchedulingConfigurationUnitTest:164` and `SchedulingReconcileIdempotencyUnitTest:192`
  both **mock** `deriveSpecForCurrentTenant()` and hand-mirror the real cron format
  (`"0 5 5 * * *"`), so a change to the real derivation's cron shape would be caught only by the job
  test while every registry-key assertion kept passing. One test that feeds the real job's derived
  spec into the real registration would close it.
- **L-9** Design-doc claim check for the brief's question. The two PIT findings §7a step 3 records
  are both visibly reflected in the diff: the context restore is scoped to the walk
  (`SchedulingConfiguration.java:883-887`, killed by M6) and the unobservable counters
  (`members++`, `registeredGroups`) are gone in favour of `boolean anyMember` and the
  `registeredJobNames()` ground-truth lookup at `:933`. What the doc does **not** record for this
  step is a final PIT score, and M-2's three survivors are exactly what a scoped run would have
  surfaced. Either ask for the score or take M-2's three tests as the substitute.

---

## Confirmed-good (stated so a later lane does not re-derive it)

- `mvn -o test-compile` clean; the 8 changed/affected test classes are **147/147 green** at
  `a35cab5a` (`SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest`,
  `TriggerSpecUnitTest`, `StaleClubBatchCleanupJobUnitTest`,
  `AdvisoryLockServicePerTenantLockUnitTest`, `NeverMatcherNullBlindnessArchTest`,
  `WholeRunSuccessGaugeUnitTest`, `AdminTriggerTenantScopeUnitTest`).
- `eachGroupFiresInItsOwnZone` proves the per-spec zone **behaviourally** (two distinct `Instant`s
  three hours apart) rather than by string, and the test's own comment correctly limits what the
  `Collectors.toSet()` collapse can prove. That is the right kind of caveat to have written down.
- `register(String, TaskScheduler, String, Runnable, String)`'s delegation preserves the five
  unconverted jobs exactly: their spec zone is still `CRON_SCHEDULE_ZONE.getID()` and
  `TimeZone.getTimeZone(ZoneId.of("America/Los_Angeles"))` round-trips to the same zone — verified
  behaviourally by the three LA triggers landing on 05:05 LA in the same test.
- Failure isolation is per group, not per job: a malformed cron and an unreadable tenant each cost
  one group (`malformedCronCostsOnlyItsGroup`, `unreadableTenantIsIsolated`), and the new
  method-level `catch (Exception)` at the end of `configureStaleClubBatchCleanupGroups` stops a
  `dbConfigCache.getAll()` throw from aborting all six jobs.
- `git grep` finds zero surviving references to `StaleClubBatchCleanupJob.doCalculation` in `src/`,
  and the four javadoc corrections (`AdminTriggerTenantScopeUnitTest`,
  `WholeRunSuccessGaugeUnitTest`, `SchedulingConfiguration`'s "Slice B" and "removing the loop"
  paragraphs) all move in the right direction rather than leaving a superseded claim asserted.
