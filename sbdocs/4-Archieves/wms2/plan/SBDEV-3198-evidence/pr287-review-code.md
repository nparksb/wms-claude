# SBDEV-3198 — independent code review of PR #287 (`adb141b1`)

**Verdict: FIX BEFORE MERGE — one ~12-line test (M-A). The code fixes are real; two of them are
unpinned, and one of those two silently re-opens the finding it closed.**

Every prescribed code change is present and, where it is load-bearing, mutation-verified. H-1 in
particular is genuinely fixed and genuinely pinned. But **M-3's fix lives entirely at the caller and
no test can see it**: reverting `schedule.resolvedZone().getId()` to `spec.zoneId()` leaves 86/86
green. That is the same silent-dead-WARN defect the original finding described, one "simplify the
record away" refactor from returning — and the same suite now hard-codes the equality M-3 disproved.

- Lane: independent code review, worktree
  `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-287-review-a` @ `adb141b1`
  (base `7b7db3b6`, = `develop` tip). Worktree verified clean after every mutation.
- Instruments: `mvn -o test-compile -q` — **clean, exit 0**. `mvn -o test` over the 10 changed /
  affected test classes — **154 tests, 0 failures, 0 errors**. **9 hand mutants** (results inline;
  JDK `21.0.11-ms`, Maven `3.9.15`, offline).
- Findings: **0 High, 3 Medium, 7 Low.**

---

## Mutation ledger (the whole basis for the checklist below — do not re-derive)

| # | mutant applied to `src/main` | tests run | result |
|---|---|---|---|
| A | **H-1 revert** — two-key `tryLock`/`unlock` use the one-key slot `lockedConnection` again (field decl kept, so it compiles) | 28 | **KILLED** — `DualLockNesting.oneKeyAndTwoKeyNestWithoutOverwritingEachOther`. H-1 is really fixed. |
| B | **M-4 revert** — move the no-context guard back below the two sysprop reads | 90 | **KILLED** (1 failure) |
| C | **M-2/M1** — delete the malformed-row guard (`&& false`) | 17 | **KILLED** (1 error — the NPE escapes `runFor`) |
| D | **M-2/M4** — retype `catch (ArithmeticException e)` to an unreachable type | 17 | **KILLED** (1 failure) |
| E | **M-2/M8** — `if (anyReadFailure)` → `if (false)` | 17 | **KILLED** (1 failure) |
| F | **L-2 revert** — drop `Objects.requireNonNull(cronExpression, "cronExpression")` from `of()` | 13 | **KILLED** (1 failure) |
| G | **L-5 vacuity probe** — rename `advisoryLockService`→`lockService` in `OutboxDispatcherJob` **and** convert both calls to the two-key form | 11 | **KILLED** (1 failure) — see L-6 below for *which* assertion caught it |
| H | **M-3 revert** — `SchedulingConfiguration:868` back to `if ("UTC".equals(spec.zoneId()))` | 86 | **SURVIVED** → **M-A** |
| I | **M-7 revert** — `if (registrations.containsKey(registryKey))` → `if (true)` | 71 | **SURVIVED** → **M-B** |

---

## MEDIUM

### M-A — M-3 is fixed in code and invisible to the suite; the one suite that could see it now bakes in the false equality

`SchedulingConfiguration.java:868` correctly tests the pre-collapse zone:

```java
if ("UTC".equals(schedule.resolvedZone().getId())) {
```

Mutant **H** reverts exactly that one expression to `spec.zoneId()` — the original M-3 defect,
verbatim — and `SchedulingConfigurationUnitTest, SchedulingReconcileIdempotencyUnitTest,
StaleClubBatchCleanupJobDeriveSpecUnitTest, TriggerSpecUnitTest` report **86 run, 0 failures, BUILD
SUCCESS**.

Why the new test does not cover it: `StaleClubBatchCleanupJobDeriveSpecUnitTest
.resolvedZoneSurvivesTheZoneInvariantCollapse` pins the **record** (`schedule.resolvedZone()` is
`UTC` while `schedule.spec().zoneId()` is the sentinel). Nothing pins that the **caller reads the
right field**. The only caller-side UTC test, `SchedulingConfigurationUnitTest.utcFallbackIsNamed`,
still calls `givenTwoTenants(ZoneId.of("UTC"), …)` whose fixture yields the *zoned* cron
`0 5 5 * * *` — so `spec.zoneId()` is `"UTC"` too and both spellings pass. The finding's own
prescribed fix was explicit about this: *"assert the WARN fires for `TriggerSpec.of("0 * * * * *",
ZoneId.of("UTC"))`"* — a **zone-invariant** cron. That test was not written.

It is worse than a plain missing test. `SchedulingReconcileIdempotencyUnitTest:196-198`'s new
fixture line is

```java
return staleClubSpec == null ? null
    : new StaleClubBatchCleanupJob.TenantSchedule(staleClubSpec, ZoneId.of(staleClubSpec.zoneId()));
```

i.e. the registry suite now **asserts by construction** that `resolvedZone == spec.zoneId()` — the
precise identity M-3 proved false for a zone-invariant cron. So the two mocked registry suites can
never distinguish the two fields, and the one suite that can (`…DeriveSpecUnitTest`) never runs the
registration.

**Failure scenario.** Step 5 converts `orderRelease` (zone-invariant on prd hydra and all four UAT
tenants, per `TriggerSpec`'s own javadoc) by copying this shape. Someone reviewing the copy sees a
two-field record where one field is only read at one site, collapses it back to `spec.zoneId()` for
tidiness, and every test stays green. A tenant with a null/blank/invalid `System Time Zone` sysprop
is then no longer named at registration — `TimezoneService.parseToZoneId` defaults it to UTC and
caches that for the process lifetime — and the "silent third schedule" §4a's *Remaining honest
costs* says the provenance line must prevent is back, undetectably.

**Fix (~12 lines, in `SchedulingConfigurationUnitTest.GroupedRegistration`).** Add a tenant whose
derived spec is zone-invariant with a UTC resolved zone — the fixture at `:181-189` already takes a
`ZoneId` per facility, so it needs a hour/minute-`*` variant returning
`new TenantSchedule(TriggerSpec.of("0 * * * * *", ZoneId.of("UTC")), ZoneId.of("UTC"))` — and assert
the `"resolved to zone UTC"` WARN names that tenant key. Then re-run mutant **H** and confirm it
dies. While there, guard the `SchedulingReconcileIdempotencyUnitTest` fixture (see L-5).

### M-B — M-7's ground-truth check is unpinned, and the branch it added can never fire

`SchedulingConfiguration.java:932` gates the membership INFO on the registry:

```java
if (registrations.containsKey(registryKey)) {
```

Mutant **I** replaces that with `if (true)` — restoring the unconditional "covers tenant(s)" claim
the finding objected to — and 71 tests pass. The `else` WARN (*"was NOT registered this pass"*) has
no test at all.

Two things make this less alarming than it looks, and one that makes it worth fixing anyway:

- The gate's substance is right. `registryKey` is `JOB_NAME@cron@zoneId`, which is **injective** on
  `TriggerSpec`, so for a given key `desired` is always the same spec and `register`'s
  `current != null && current.spec().equals(desired)` strict-no-op branch is the only branch a
  second visit can take. The consequence: `containsKey` is true on the boot-after-reconcile pass
  (INFO fires, as before — no regression, and `sameZoneMeansOneGroup` still pins it), and false only
  on a genuine registration failure.
- But the only failure it catches is `register`'s `future == null` path, whose **own javadoc at
  `:1117-1119` declares it unreachable**: *"Unreachable with today's inputs (the day/month fields
  are hard-coded `* * *`, and a malformed hour/minute throws in `CronTrigger`'s constructor
  instead)"*. So the new WARN is defensive code guarding a documented-impossible state, with no
  test, in the file step 4 is about to copy.
- The finding M-7 actually raised — *"nothing reports a tenant whose current spec matches no
  registered trigger"* — **is** substantively covered, contra the framing in the review request: after
  the loop every spec in `groups` has either been registered, hit the new WARN, or hit the
  `catch`; and the `reconciling && registrations.containsKey` `continue` skips only keys that *are*
  registered. The 02:52-edit window M-7's scenario described stays open by construction (no walk
  runs in it), which the finding itself conceded.

**Fix:** either pin it — one test that stubs the scheduler to return `null` for the grouped job's
trigger and asserts the WARN names both tenant keys (`SchedulingConfigurationUnitTest` already
hands out futures per registration at `:200`-ish, so this is a two-line fixture change) — or delete
the `else` branch and say in one line that `register`'s own ERROR is the report. Do not leave an
untested branch guarding a state the neighbouring javadoc calls impossible.

### M-C — M-5's restatement drops the one term that was operationally load-bearing

The restated paragraph (`SchedulingConfiguration.java:1189-1200`) is accurate as far as it goes and
addresses M-5's item **3** (the stale idle-pool-eviction claim) squarely. It is silent on items
**1** and **2**, and item 1 is the expensive one.

Verified independently, not inferred: `configureAllTasks(scheduler, source, reconciling)` opens with
`synchronized (registrationLock) {` at `:624` and calls
`configureStaleClubBatchCleanupGroups(...)` **first** at `:635`; the reconcile re-enters the same
monitor at `:1233` around its own `configureAllTasks` call. So `registrationLock` is held across the
entire per-tenant walk — N blocking tenant-DB reads, two sysprops plus a zone each — every reconcile
cycle. `registrationLock`'s own javadoc (`:150-155`) states that a concurrent boot pass is *"the
EXPECTED case, not an edge case"*, and cites SBDEV-3204's bounds (pool `connectTimeout=10s`). At
UAT's four tenants, one unreachable tenant therefore holds the registration monitor for a
double-digit number of seconds every five minutes, blocking the boot pass that AC10's self-heal
exists to let through. Item 2: it all runs on the shared `ThreadPoolTaskScheduler` with
`POOL_SIZE = 10` (`:36`) alongside the six cron jobs and the 15s outbox dispatcher.

M-5's ask was *"the arithmetic should be restated before step 4 copies the shape"*. A restatement
that keeps the pool-eviction footnote and drops "the registration lock is held across N blocking
connects" does not meet it — step 4 multiplies exactly that term.

**Fix:** two sentences in the same paragraph naming the lock hold and the shared pool. No code change.

---

## LOW

- **L-1** The new M-4 test's own comment is **wrong about its own discriminating power**, in the
  direction that invites deletion. `StaleClubBatchCleanupJobDeriveSpecUnitTest:63-66` says: *"This
  test would have passed even with the pre-fix ordering (the exception still gets thrown eventually
  …) — the discriminating assertion is the `never()` below."* Mutant **B** applies exactly the
  pre-fix ordering and the test **fails**: with both sysprops unstubbed (`null` under
  `MockitoExtension`'s default strict stubs), the pre-fix body short-circuits to `return null` and
  throws **nothing**, so `assertThatThrownBy` fails before `never()` is ever reached. Both
  assertions discriminate. Correct the comment — as written it teaches a future reader that the
  `assertThatThrownBy` is decorative and safe to drop.

- **L-2** `Math.toIntExact(tenantId);` at `StaleClubBatchCleanupJob.java:182` **discards its
  result** — a call made purely for its exception. L-4's prescribed form was
  `int objId = Math.toIntExact(config.getId());`. Assign it and thread `objId` through (which also
  retires the duplicate narrowing the comment calls *"redundant but harmless"*), or keep the discard
  and say so; as written a static analyser or IDE flags it and the next reader deletes it as dead.

- **L-3** `anyReadFailure = true;` in the new overflow branch (`:187`) is a **dead store**.
  `anyMember = true` runs two lines earlier at `:173`, and `anyReadFailure` is read only inside
  `if (!anyMember)` at `:227-228`. So an id-overflow tenant can never influence the group-level log.
  Harmless — and identical in shape to the unobservable counters PIT already had removed from
  `SchedulingConfiguration` (§7a step 3). Either drop it or comment that it is set for symmetry
  only. (Behaviour is unchanged from `7b7db3b6`, where the `catch` sat after the same `anyMember`
  assignment — so this is not a regression, just an inherited one the L-4 rework re-typed.)

- **L-4** `JOB_NAME`'s javadoc (`StaleClubBatchCleanupJob.java:52`) still reads *"must match
  `SchedulingConfiguration.CONFIGURED_JOB_NAMES`"*. M-6 **inverted that direction** —
  `CONFIGURED_JOB_NAMES` at `SchedulingConfiguration.java:69` now references this constant, so
  nothing "must match" anything and there is no drift left to warn about. Restate as "the single
  source; `CONFIGURED_JOB_NAMES` references it." (M-6 itself is fully closed: `grep -rn
  '"staleClubBatchCleanup' src/main/` returns the declaration and nothing else.)

- **L-5** `SchedulingReconcileIdempotencyUnitTest:198`'s `ZoneId.of(staleClubSpec.zoneId())` is a
  live landmine, and its comment documents it rather than guarding it. A future test that sets
  `staleClubSpec` to a zone-invariant spec gets `ZoneRulesException` thrown **from inside the mock
  answer**, at which point the production walk's own `catch` (`SchedulingConfiguration.java:~886`)
  swallows it and files the tenant under `unreadable` — so the suite goes **green while measuring
  nothing**, rather than red. Guard it:
  `TriggerSpec.ZONE_INVARIANT.equals(s.zoneId()) ? ZoneId.of("UTC") : ZoneId.of(s.zoneId())`, or
  `fail("this fixture cannot represent a zone-invariant spec")`.

- **L-6** L-5's re-anchoring introduced a narrow false-green mode of its own, which I probed rather
  than assumed. The negative pins are now anchored to the receiver name
  (`advisoryLockService\.tryLock\(…,…\)`), so a field rename makes them vacuous. Mutant **G**
  renamed the field to `lockService` **and** converted both calls to the two-key form — the test
  still **REDS**, but via the sibling *positive control*
  `containsPattern("tryLock\\(\\s*AdvisoryLockService\\.JobLockId\\.[A-Z_]+\\s*\\)")`, which stops
  matching once the call takes two arguments. The pin holds; it is the positive control, not the
  anchored negative, that is now doing the work. Acceptable as-is — recorded so a later lane does
  not "simplify away" the positive control and leave two vacuous negatives behind.

- **L-7** `DualLockNesting`'s stub comment mis-describes its own mechanism: *"the FIRST call
  (one-key) gets `oneKeyConn` only via a one-shot answer below; the SECOND call (two-key) falls
  through to the fixture default."* `when(landlordDataSource.getConnection()).thenReturn(oneKeyConn,
  connection)` does not fall through to `setUp()`'s stub — it **replaces** it, returning `oneKeyConn`
  once and then `connection` for every subsequent call. Immaterial here (there are exactly two
  acquires); misleading to anyone extending the test to a third.

---

## Checklist — original findings, independently confirmed

| Finding | Status | Evidence |
|---|---|---|
| **H-1** dual-lock unimplementable | **CLOSED, pinned** | Separate `lockedConnection` / `lockedTenantConnection` slots; `unlock(long)` reads the former (`:114`), `unlock(long,long)` the latter (`:216`); each `SQLException` path `remove()`s only its own slot (`:97`, `:199`). Same-form nesting still forbidden and still documented (`:163-167`). New test holds both forms **simultaneously** and asserts two distinct connections, two distinct unlock SQL shapes, and that neither release touches the other's connection. **Mutant A KILLED.** |
| **M-2** three unpinned `runFor` branches | **CLOSED, pinned ×3** | **Mutants C, D, E all KILLED** — the three PIT survivors from #286 are dead. All three tests are discriminating for the right reason (C errors because the NPE escapes `runFor` entirely, which is the failure mode the guard's comment names). |
| **M-3** UTC-fallback WARN blind to the collapse | **code CLOSED, test MISSING** | Caller reads `schedule.resolvedZone().getId()`; `runFor` correctly still compares **specs** (`own.spec().equals(spec)` at `:169`), not schedules, so grouping is unaffected. **Mutant H SURVIVED** → **M-A**. |
| **M-4** no-context guard unreachable | **CLOSED, pinned** | Guard is now the first three statements of the method body (`:96-101`), ahead of both sysprop reads; the `@throws` javadoc was corrected to name this method as the source. **Mutant B KILLED.** |
| **M-5** stale reconcile-cost claim | **PARTIAL** | Item 3 restated accurately; items 1 (lock held across N blocking reads) and 2 (shared 10-thread pool) still unstated → **M-C**. |
| **M-6** five raw `"staleClubBatchCleanup"` literals | **CLOSED** | `grep -rn '"staleClubBatchCleanup' src/main/` → **1 hit, the declaration**. All five call sites plus the `CONFIGURED_JOB_NAMES` entry now use `StaleClubBatchCleanupJob.JOB_NAME`; it is a compile-time constant so there is no class-init-order exposure. Javadoc direction now stale → L-4. |
| **M-7** unreported no-trigger tenant / unconditional success log | **code CLOSED, test MISSING; branch unreachable** | See **M-B**. Substance is right and injectivity of `registryKey` means no INFO regression; **mutant I SURVIVED**. |
| **L-1** `registeredSpecs()` order javadoc | **CLOSED** | Body is `new TreeMap<>()` (`:1307`); new text says "alphabetical key order … the body is a `TreeMap` and always has been" — verified accurate, including the key-shape sentence. |
| **L-2** `of(null, zone)` loses the parameter name | **CLOSED, pinned** | `Objects.requireNonNull(cronExpression, "cronExpression")` precedes `isZoneInvariant`. **Mutant F KILLED.** |
| **L-3** broken javadoc indentation | **CLOSED** | `TriggerSpec.java:19-21` continuation lines re-indented to ` * `. |
| **L-4** over-broad `ArithmeticException` catch | **CLOSED, pinned** | Narrowed to a dedicated `try` around the id narrowing only; the outer `catch (Exception)` now correctly treats a business `ArithmeticException` as generic. **Mutant D KILLED**, and `int4OverflowIsNamedAtTheJobLevel` additionally pins `never()).tryLock(JOB, overflowingId)` — the discriminating check that the guard fires *before* the lock. Both `never()` matchers use concrete `long`s, so no `any()`-unboxing trap. Cosmetics → L-2, L-3. |
| **L-5** unanchored source-scan patterns | **CLOSED, non-vacuous** | Both guarded files do use `advisoryLockService.` as the receiver, and the positive control proves the file was read. Residual risk characterised in **L-6**. |

### The three deferrals — sanity-checked, not rubber-stamped

- **L-6 (duplicate whole-fleet WARN per group)** — reasonable. `active.isEmpty()` is genuinely a
  whole-fleet condition and the duplication is bounded by the registered group count (UAT: 2). Log
  noise, no information lost.
- **L-7 (explicit-facility overload)** — deferring is **right, and the finding was arguably
  wrong**. `TimezoneService.getWarehouseZoneId()`'s own guard message (`TimezoneService.java:59-60`)
  reads *"called without TenantContext. Use `getWarehouseZoneId(facilityCode)` from
  scheduled/async threads."* A scheduled job is precisely that caller, so the job is following the
  documented instruction. The thing that should change is the *other* javadoc — the String
  overload's *"Reserved for callers that look up a facility other than the one in TenantContext"*
  (`:66-68`), which contradicts its sibling's error message. Worth one line on the ticket; not this
  PR's job.
- **L-8 (single-source-of-truth untested end-to-end)** — **the weakest deferral, and it is not
  merely a design tradeoff.** L-8 is the exact test that would have caught M-A: it asks for one case
  feeding the *real* derivation into the *real* registration, which is the only construction that
  can distinguish `resolvedZone()` from `spec.zoneId()` at the caller. #287 made the deferral more
  costly, not less — it changed the derivation's return type and hand-mirrored the new record into
  two mocked fixtures, one of which (L-5) now encodes `resolvedZone == spec.zoneId()` as a fixture
  invariant. Fixing M-A with a targeted caller test discharges the urgent half of L-8; the full
  end-to-end version can still be deferred.

## Confirmed-good (stated so a later lane does not re-derive it)

- `mvn -o test-compile -q` clean; **154/154 green** at `adb141b1` across
  `SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest`, `TriggerSpecUnitTest`,
  `StaleClubBatchCleanupJobDeriveSpecUnitTest`, `StaleClubBatchCleanupJobUnitTest`,
  `AdvisoryLockServicePerTenantLockUnitTest`, `AdvisoryLockServiceUnitTest`,
  `NeverMatcherNullBlindnessArchTest`, `WholeRunSuccessGaugeUnitTest`,
  `AdminTriggerTenantScopeUnitTest`.
- **Nothing already live on `develop` was broken by these fixes.** Checked each: (a)
  `deriveSpecForCurrentTenant`'s only production caller is
  `SchedulingConfiguration.java:864`, which sets the context immediately before, so the reordered
  guard cannot fire in the shipped path; (b) `TriggerSpec.of`'s only production call site builds its
  cron by concatenation, so the new `requireNonNull` cannot fire; (c) the M-7 gate cannot suppress
  an INFO the pre-fix code emitted, because `registryKey` is injective on `TriggerSpec` and the
  boot-after-reconcile pass therefore always finds the key present; (d) `runFor` still groups on
  `own.spec()`, so the `TenantSchedule` return type did not perturb membership; (e) the two-key
  form's move to its own `ThreadLocal` is invisible to the only current caller, which holds one form
  at a time.
- The new `StaleClubBatchCleanupJobDeriveSpecUnitTest` lives in `net.aim_ai.wms.schedulejob` for a
  real reason (package-private method + package-private record), and its class javadoc states that
  reason correctly. Its `TenantContext.clear()` in both `@BeforeEach` and `@AfterEach` is the right
  hygiene for a `ThreadLocal` the surefire thread reuses.
- `int4OverflowIsNamedAtTheJobLevel` and `malformedRowCostsOnlyItself` both assert a **surviving
  sibling** (`cleaned).containsExactly("nywh2")` / `("nywh")`), which is what makes them tests of
  *isolation* rather than of a log string.
- `unreadableTenantIsDistinguishedFromAnEmptyGroup` uses `doThrow(...).when(mock)` and explains in
  its own comment why `when(mock.method()).thenThrow(...)` would misfire against `setUp()`'s lenient
  `anyString()` stub. That is the right caveat to have written down.
