# SBDEV-3198 step 5 part 4 (`ReplenishOrderJob` → D′) — independent code-correctness review

- **Repo / branch**: `SiteBossInc/wms2-api`, `bugfix/SBDEV-3198-replenish-order`
- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-STEP5-PART4`
- **State reviewed**: UNCOMMITTED working tree, fork point `a6c22ac7`
- **Template compared against**: `29a64776` (`OrderReleaseJob` D′ conversion, merged)
- **Lane**: code-correctness, round 1
- **Date**: 2026-09-04

**Verdict: FIX FIRST** — 2 High, 5 Medium, 5 Low. No functional defect found in the production
code; every High and the first Medium are **test-coverage gaps in the newly-written locking /
refusal code**, proven by PIT and by direct comparison against the merged template, which pins the
same code paths and this one does not.

---

## 0. Verification performed (instruments, not claims)

| Check | Instrument | Result |
|---|---|---|
| Full suite | `mvn clean test` | **6295 run / 0 failures / 0 errors / 67 skipped — BUILD SUCCESS**. Reproduces the stated 6295/0/0/67. |
| PIT (as specified in the brief) | `pitest:mutationCoverage` over `ReplenishOrderJob,SchedulingConfiguration,AdminActionController` | **394 mutations, 288 killed, 65 survived, 41 no-coverage → 82% test strength.** Reproduces the stated figure exactly. |
| PIT, template baseline | same goal, `-DtargetClasses=…OrderReleaseJob` + its 7 test classes | see §H-1 / §H-2 — the aggregate comparison in the brief **inverts** once scoped to changed code |
| `"20"` seconds offset preserved | read `ReplenishOrderJob:296`; grep fixtures | **PRESERVED.** `TriggerSpec.of("20 " + minutes + " " + hours + " * * *", zone)`. Carried through every fixture (`replenish@20 5 5 …`, `replenish@20 9 9 …`) and asserted in 5 places. |
| `RUNNING` acquire/release on every path | line-by-line read of `runFor` (`:190-316`) and `runForCurrentTenant` (`:342-393`) | **CORRECT.** No path exits between the CAS and the `finally`; both `finally` blocks are unconditional. |
| Deadlock / lock nesting | read `AdvisoryLockService:150-245`, both entry points, `AdminActionController:112-119` | **NO RISK.** Two-key locks are taken/released per tenant sequentially, never nested; the two jobs in `triggerOrderReplenish` run in sequence; the one-key and two-key forms use separate `ThreadLocal` slots and this job no longer takes the one-key form at all. |
| Optimistic-lock javadoc audit (the "eight of nine" claim) | `grep -n OptimisticLock` + method line-range map | **CLAIM VERIFIED LINE-BY-LINE.** 9 catch sites across the 8 named methods (`updateReplenishmentOrderPriority` has two, `:708`/`:729`); `mergePickingOrders` (`:450-510`) genuinely has none. |
| Metric-javadoc claim (brief item 1) | read `replenish()` (`:401-445`) and `runFor` | **NOW CORRECT.** The 4 `replenishSubOpRows` sites are all inside `replenish()`; `tenantSuccess`/`tenantFailure`/`tenantSkippedNotActivated` are `runFor`-only. |
| Job-count bookkeeping | `CONFIGURED_JOB_NAMES` (`:68`), `configureAllTasks` (`:642-690`), `registeredJobNames()` (`:1694`) | **CORRECT.** 6 names; 5 grouped + 1 `onlyIfMissing`; `registeredJobNames()` de-dupes `job@cron@zone` back to `jobName`, so `configured == registeredNow == 6`. Pinned by `SchedulingConfigurationUnitTest` (`EXPECTED_TRIGGER_COUNT + 5` triggers, `registeredJobNames()` still `hasSize(EXPECTED_TRIGGER_COUNT)`). |
| Combined-boolean semantics | `AdminActionControllerUnitTest` 3 tests; PIT on `triggerOrderReplenish` | **CORRECT and fully pinned** — **zero** surviving mutants on that handler. Tested in all three directions incl. the differing one. |
| Downstream impact of the boolean | `git grep triggerOrderReplenish` in `v2/wms2-web-ui`, `v2/wms2-mobile-ui` | **NONE.** `store/admin/mgmt/action.js:18` only `console.log`s the result; mobile does not call it. |
| Fixture-`setId` fix (brief item 2) | traced `runFor` `:264` `long tenantId = config.getId()` against the two fixtures | **REAL and load-bearing** — without it tenant 2 NPE-unboxes into the per-tenant catch and `verify(…, times(2))` fails. (Framing quibble in §L-5.) |
| Doc sweep | `grep -ni "four\|five\|six\|single-trigger\|not-yet-converted"` over `SchedulingConfiguration.java`, `TriggerSpec.java`, all 6 job classes | **4 stale sites found** — §M-2, §M-3, §M-4 |

---

## 1. Findings

### H-1 — `runForCurrentTenant()`'s entire refusal ladder is untested; the merged template pins all of it
**Severity: High · Confidence: High**
**Files**: `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:342-393`;
`src/test/java/net/aim_ai/wms/unit/schedulejob/AdminTriggerTenantScopeUnitTest.java:625-760`

PIT reports **12 `NO_COVERAGE` mutants inside `runForCurrentTenant()`** — i.e. those lines are
never executed by any test in the repo:

| Line | Refusal path | PIT status |
|---|---|---|
| `:351` | **JVM busy** (`RUNNING` CAS failed) → `return false` | NO_COVERAGE ×1 |
| `:360` | no landlord `tenant_db_configuration` row → `return false` | NO_COVERAGE ×2 |
| `:368` | id does not fit int4 → `return false` | NO_COVERAGE ×2 |
| `:373` | two-key lock busy → `return false` | NO_COVERAGE ×2 |
| `:380` | not activated (either flag) → `return false` | NO_COVERAGE ×2 |
| `:386` | `catch (Exception)` → `return false` | NO_COVERAGE ×2 |

The only manual-path tests for this job are `AdminTriggerTenantScopeUnitTest.Replenish`'s three:
happy path, no-`TenantContext`, and context-intact.

The template this change states it mirrors does not have this gap. `OrderReleaseJobUnitTest:203`
carries a dedicated nested class, *"SBDEV-3198 step 5 part 3 — `runForCurrentTenant()`'s two-key
lock widening"*, with five tests: `refusesWhenTenantCannotBeResolved`, `refusesWhenIdOverflowsInt4`,
`skipsWhenTwoKeyLockIsBusy`, `refusesWhenNotActivated`, and a global-kill-switch test. PIT scoped to
`OrderReleaseJob`'s wrapper reports **zero** `NO_COVERAGE` and only three survivors, **all three of
which are equivalent mutants** (`return false` → `false`, `return true` → `true`).

This is not a cosmetic parity gap. `runForCurrentTenant()`'s return value is the thing
`AdminActionController` now surfaces (`orderReleaseRan && replenishRan`), and `:351`'s JVM-busy
refusal is the *one* behaviour this job has that no sibling has — so no sibling's tests cover it by
accident, and nothing in this change covers it on purpose.

**Fix**: mirror `OrderReleaseJobUnitTest`'s `RunForCurrentTenantLocking` nested class for
`ReplenishOrderJob`, plus one test the template cannot have — a manual trigger that finds
`RUNNING` already `true` returns `false`, takes **no** lock (`verify(advisoryLockService,
never()).tryLock(anyLong(), anyLong())`), and leaves `RUNNING` unchanged.

---

### H-2 — the `RUNNING` release and both `unlock` calls are removal-mutant survivors
**Severity: High · Confidence: High**
**File**: `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:289`, `:388`, `:391`

Three removal mutants **SURVIVE** the full nine-class test set:

| Line | Mutation | Effect if the line were really lost |
|---|---|---|
| `:391` | *removed call to `AtomicBoolean::set`* — the `RUNNING.set(false)` in `runForCurrentTenant`'s outer `finally` | one admin click permanently wedges `RUNNING` true; **every scheduled replenish group on that replica is skipped for the life of the JVM**, with a single DEBUG line as the only signal |
| `:388` | *removed call to `AdvisoryLockService::unlock`* (manual path) | the pinned landlord connection is never returned and `(100002, tenantId)` is held until the connection dies — that tenant's scheduled replenish is skipped every occurrence |
| `:289` | *removed call to `AdvisoryLockService::unlock`* (scheduled per-tenant path) | same, for every tenant in the group |

The class's own test comment (`AdminTriggerTenantScopeUnitTest:702-716`) names this hazard exactly —
*"the flag sticks true for the life of the JVM and replenishment stops fleet-wide"* — but the
assertion it guards (`replenishRunningFlag()` is false) only covers the **pre-acquire** no-context
refusal, where the CAS never ran. Every **post-acquire** path is unpinned, and the class's
`@BeforeEach` reflective `RUNNING` reset actively hides the difference.

The template again does not have this gap: `OrderReleaseJob`'s equivalent per-tenant
`unlock` (`:242`) is **KILLED**. This is a per-line regression against the merged precedent, on the
single mechanism this change deliberately deviates on.

**Fix**: assert `replenishRunningFlag()` is `false` after (a) a successful `runForCurrentTenant()`,
(b) a `runForCurrentTenant()` whose `replenish()` throws, and (c) a `runFor(spec)` whose tenant loop
throws; and add `verify(advisoryLockService).unlock(JobLockId.REPLENISH_ORDER, <id>)` on both the
success and the throw paths of each entry point.

---

### M-1 — no non-member test: the D′ group-membership filter has no negative coverage for this job
**Severity: Medium · Confidence: High**
**File**: `ReplenishOrderJob.java:255-257` (`if (own == null || !own.spec().equals(spec)) continue;`), `:301-309`

Every replenish fixture in the repo stubs `HOUR`/`MINUTE`/zone so that **every** tenant matches the
trigger's spec (`ReplenishOrderJobTest.setUp`, `ReplenishOrderJobMetricsUnitTest.stubMatchesSpec()`,
`WholeRunSuccessGaugeUnitTest.lockHeldWithTwoTenants()`,
`AdminTriggerTenantScopeUnitTest.cronRun_stillLoopsEveryActiveTenant`). Nothing exercises "this
tenant derives a *different* spec, so it is not in this group" — which is the entire mechanism the
D′ conversion exists to introduce.

PIT confirms the consequence: `:301` (`if (!anyMember)`) **SURVIVED** and `:302`
(`if (anyReadFailure)`) is **NO_COVERAGE** — the inner branch is never executed.

The template added a test specifically for this, with a comment naming these very mutants:
`OrderReleaseJobUnitTest:118`, *"PIT: a tenant that exists but derives a DIFFERENT spec is skipped
without a lock attempt, and the fire still counts as successful … Kills the negated-conditional
mutants on runFor's `if (!anyMember) { if (anyReadFailure) … }` tail, which had zero coverage."*
`StaleClubBatchCleanupJobUnitTest:223` carries the same idea. This conversion skipped it.

**Fix**: port `runFor_tenantNotMatchingSpec_isSkippedWithoutTouchingLockOrPerTenantMetrics`
verbatim, substituting `REPLENISHMENT_TIMER_*` and the `"20"` offset. One more test covering a
tenant whose derivation *throws* closes `:302`.

---

### M-2 — `SchedulingConfiguration`'s boot-probe javadoc is now false, in the paragraph corrected once already for this exact drift
**Severity: Medium · Confidence: High**
**File**: `src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java:292-311`

Still asserts, verbatim:

> **Still one shared schedule for the ONE remaining unconverted job.** … As of SBDEV-3198 step 5
> part 3, FIVE jobs are converted … and exactly ONE, `replenish`, is not. For that one job, the
> winning tenant's `*_TIMER_*` sysprops still drive every tenant's schedule. … Until `replenish`
> converts, AC5's provenance logging is what makes the arbitrary winner visible for that one job.

Every clause is now wrong: all six are converted, `replenish` derives its own schedule per tenant,
and no job's schedule is still driven by the winning tenant's timer sysprops.

The same paragraph carries `⚠ CORRECTED 2026-09-03 (M-3, PR #301 review)` — it was found stale once
before, in a review of the *previous* part of this same ticket, with the note *"this file's own
history: it was already wrong after steps 4, 5.1 and 5.2, none of which fixed it."* The last
conversion in the series is exactly where it needed rewriting, and it was not swept.

**Fix**: rewrite to "no unconverted job remains; every one of the six derives its own schedule (or
is hard-coded)", and retire the AC5-provenance sentence.

---

### M-3 — `TriggerSpec`'s javadoc still describes `replenish` as unconverted, in two places
**Severity: Medium · Confidence: High**
**File**: `src/main/java/net/aim_ai/wms/schedulejob/TriggerSpec.java:20-22`, `:62-80`

1. `:20-22` — *"the canonical constructor has ONE call site in production: the one-arg `register`
   overload used by the **two not-yet-converted jobs (replenish, releaseExpiredPickingOrdersFromUser**
   — corrected, PR #301 round-2 review …)"*. Now one, not two. This sentence was already corrected
   once in PR #301 round 2 for the same reason.
2. `:62-80` — the `⚠ LIVE as of SBDEV-3198 step 5 part 3 (M-1, PR #301 review)` block names only
   `orderRelease` as routing through `of(…)`, and still lists `replenish` in the merely-*conditional*
   set. `replenish` now routes through `of(…)` too, and by that paragraph's own measurement
   (`REPLENISHMENT_TIMER_HOUR`/`_MINUTE` at `*` on prd hydra and all four UAT tenants) the
   zone-invariant collapse **fires for real** for it — every tenant lands in the single group
   `replenish@20 * * * * *@zone-invariant`. That is a live, prd-visible consequence of this change,
   documented as hypothetical.

---

### M-4 — two more stale counts / an unactioned in-code TODO in `SchedulingConfiguration`
**Severity: Medium · Confidence: High**

- `:1350-1356` — *"L-4 (PR #301 review): with **FOUR** grouped jobs (not one), this adds AT LEAST six
  more triggers every cycle"*. Five now; the "≥6" floor also moves.
- `:1550-1558` — *"Acceptable at today's cadence and tenant count — **restate this arithmetic again
  before step 5 groups the remaining five jobs**, which multiplies the per-cycle query count by up to
  six."* This change is the point that instruction named. It is not a correctness issue (the
  landlord-pool-cap risk is separately accepted for parts 2–4), but the arithmetic it asks for is now
  concrete: five grouped walks × every cached tenant × 2 sysprop reads + a zone lookup, every
  reconcile cycle. Either restate it or delete the instruction; leaving it makes the next reader
  re-derive it.

---

### M-5 — a test whose name now asserts the opposite of what it checks, over a branch that is now unreachable in production
**Severity: Medium · Confidence: High**
**File**: `src/test/java/net/aim_ai/wms/schedulejob/SchedulingReconcileIdempotencyUnitTest.java:566-605`, `:606-632`

With `replenish` grouped, **no production job can reach `register()`'s cancel-and-reschedule
branch** any more: grouped jobs embed the spec in the registry key, so a key hit implies a spec
match (the strict no-op), and `releaseExpiredPickingOrdersFromUser`'s cron is hard-coded. That makes
`SchedulingConfiguration:1489`'s `"Rescheduling {}: cron {} -> {}…"` INFO and the `cancel(false)`
call beneath it dead from every call site in `src/main`.

The change adapts honestly rather than deleting coverage — flipping
`aRealChangeIsLoggedWithBeforeAndAfter` into `noJobLogsReschedulingAnyMore`, which is a defensible
tripwire. Two problems remain:

1. `theRetiredTriggerIsCancelledWithFalse` now asserts `cancelled == 0`. The `@DisplayName` and
   method name say the retired trigger *is* cancelled with false. A future reader greps the name,
   believes the path is covered, and it is not.
2. Its comment says *"see `cancel(false)`'s single remaining caller pinned elsewhere if that coverage
   is still wanted."* That pointer does not resolve — `grep -rn "cancel(false)" src/test` returns
   exactly one production-behaviour assertion, and it is the one inside this now-zero-asserting test.
   The `"-> "` before/after log format is now asserted nowhere.

**Fix**: rename both tests to match what they assert, and either (a) delete the now-dead
cancel/reschedule branch from `register()`, or (b) add a direct unit test against `register()` with
a synthetic single-trigger key whose spec changes, so the branch and its log format stay pinned
while the code exists.

---

### L-1 — two metric behaviours silently disappeared for this job; the javadoc's framing implies otherwise
**Severity: Low · Confidence: High**
**File**: `ReplenishOrderJob.java:87-95`

`grep -rn skippedLockBusy src/main` → **no call site for `replenish` at all** after this change
(pre-D′ the job-wide `tryLock` failure incremented it). `skippedJvmBusy` is now called only from
`runFor:214`; pre-D′ the manual path shared that same guard and incremented it too. So:

- a tenant skipped every occurrence because its two-key lock is persistently held is invisible above
  DEBUG;
- a manual "run now" refused because the JVM is busy — the *stated reason* the `RUNNING` flag is
  kept — is likewise invisible above DEBUG.

The class javadoc lists both counters under "`runForCurrentTenant()` deliberately touches NONE of
…", which reads as "these are scheduled-run gauges that `runFor` writes". `runFor` writes only
`skippedJvmBusy`. The template recorded the equivalent regression explicitly and separately
(`OrderReleaseJob:67`, *"⚠ M-2 (PR #301 review): the job-wide `skippedLockBusy` counter this job
wrote pre-D′ is GONE"*); this conversion folded it into a list where it reads as unchanged.

**Fix**: add the same ⚠ paragraph naming both counters as behaviour changes from this job's own
pre-D′ shape. (Operationally low-urgency — nothing scrapes Prometheus in this estate yet.)

---

### L-2 — dead one-key `tryLock` stubs left behind in three test classes
**Severity: Low · Confidence: High**

`when(advisoryLockService.tryLock(anyLong())).thenReturn(true)` still sits in
`ReplenishOrderJobTest:120`, `ReplenishOrderJobConnectionBudgetTest:106`, and
`ReplenishOrderJobPaginationTest:94`, for a one-key overload the job no longer calls on any path.
`AdminTriggerTenantScopeUnitTest` and `WholeRunSuccessGaugeUnitTest` both removed theirs, with a
comment explaining why — so the sweep is inconsistent, not absent. Harmless today only because those
three classes are not strict-stubs.

---

### L-3 — the per-tenant `TenantContext.clear()` is a surviving removal mutant
**Severity: Low · Confidence: High**
**File**: `ReplenishOrderJob.java:298`

PIT: *removed call to `TenantContext::clear`* **SURVIVED**. `OrderReleaseJob`'s equivalent (`:251`)
is KILLED. Nothing pins that the new per-tenant loop clears context between tenants — a leak here
would let tenant N+1's work run under tenant N's routing key if the `setCurrentTenant` for N+1 ever
failed. Same fixture shape as H-2's fix; add
`assertThat(TenantContext.getCurrentTenant()).isNull()` after a multi-tenant `runFor`.

---

### L-4 — the mutation-coverage comparison in the change summary does not hold once scoped to changed code
**Severity: Low · Confidence: High**

The stated comparison — 82% here vs 74% for the `OrderReleaseJob` precedent — is reproducible but
is an aggregate over whole classes with very different amounts of untouched legacy. Scoped to the
code each conversion actually wrote:

| | `ReplenishOrderJob` wrapper (`:190-445`) | `OrderReleaseJob` wrapper (`:155-340`) |
|---|---|---|
| mutations | 74 | 47 |
| killed | 46 | 40 |
| survived | 16 | 7 (all three in `runForCurrentTenant` are **equivalent**) |
| **no-coverage** | **12** | **0** |
| **test strength** | **74%** | **85%** |
| **mutation coverage** | **62%** | **85%** |

Both bands were measured with the same PIT goal and each job's own test classes. The direction of
the comparison reverses. This is context for H-1/H-2, not an independent defect — but the "at or
above the precedent" claim should not be carried into the PR description as it stands.

---

### L-5 — the two `setId(…)` additions are adaptations, not "pre-existing test-fixture bugs"
**Severity: Low · Confidence: High**

Verified: pre-D′ `doCalculation(true)` built a `TenantProfile` from `config.getTenant()` /
`config.getWarehouse()` and never read `config.getId()`, so the missing ids were harmless before and
both tenants were genuinely exercised (`times(2)` passed). They become mandatory only because the
new two-key lock needs the id. The fix is real and load-bearing; the *characterisation* as a latent
pre-existing bug is not, and matters because it implies a class of defect worth sweeping for
elsewhere.

---

## 2. Explicitly checked and found correct

- **`RUNNING` guard placement.** Acquired before any work on both entry points, released in an
  unconditional outermost `finally` on both. No path can exit between the CAS and the `finally`
  (`runFor`'s early `active.isEmpty()` return and every `continue` are inside the `try`;
  `runForCurrentTenant`'s six `return false`s are all inside the `try`). The JVM-busy early returns
  correctly do **not** reset the flag (the CAS did not succeed). No wedge, no leak, no deadlock.
- **Two-key advisory-lock scoping.** `tryLock(REPLENISH_ORDER, tenantId)` / `unlock(...)` are
  lock-work-unlock per tenant, never nested — which matters, because
  `AdvisoryLockService:163-168` states nesting two two-key locks overwrites the `ThreadLocal` slot
  and leaks the first connection with its lock held. The `unlock` sits in a `finally` scoped
  tightly to the locked region on both paths. The `Math.toIntExact` guard precedes the lock on both.
- **The `"20"` seconds offset** is preserved, not normalised to the template's `"0"`, and is
  asserted in `SchedulingConfigurationUnitTest`, `SchedulingReconcileIdempotencyUnitTest` (×3) and
  three job fixtures.
- **`orderReleaseRan && replenishRan`.** Semantics are right (both are evaluated as separate
  statements, so no short-circuit skips the second job), tested in all three meaningful directions
  including the newly added differing case, and PIT finds **zero** surviving mutants on the handler.
  No downstream consumer regresses — the only caller `console.log`s the value.
- **Job-count bookkeeping** across `CONFIGURED_JOB_NAMES` / `configured` / `registeredNow` /
  the boot summary, at 5 grouped + 1 single-trigger.
- **The class javadoc's optimistic-lock audit** — verified against the source method-by-method,
  including the deliberately-called-out `mergePickingOrders` exception. This is a claim that would
  have been easy to assert loosely and was not.

## 3. Positive observations

- The metric-javadoc correction (brief item 1) is genuinely correct now, and correct for the right
  reason: `replenishSubOpRows` fires from both paths *because* it lives inside the shared
  `replenish()`, and the four sites are all there.
- `replenish()` is a verbatim extraction — a line-by-line diff of the nine operations against the
  deleted loop body shows no behavioural edit smuggled into a mechanical refactor. That discipline is
  what makes the rest of this review tractable.
- The `SchedulingReconcileIdempotencyUnitTest` adaptations avoid the vacuity trap the class javadoc
  warns about: `orderRelease`/`replenish` are removed from the `registeredSpecs().get(jobName)` loop
  with an explicit note that a bare-key lookup would now pass as `null == null`.
- `AdminActionControllerUnitTest.surfacesReplenishRefusalEvenWhenOrderReleaseSucceeds` was added
  with an explicit statement of the mutant it kills, and it does kill it.
- The `NeverMatcherNullBlindnessArchTest` inventory was updated in both directions (per-class counts
  and total), not just bumped upward.

## 4. Suggested order of work

1. **H-1** — port `RunForCurrentTenantLocking` from `OrderReleaseJobUnitTest`, plus the JVM-busy case.
2. **H-2** — pin `RUNNING.set(false)` and both `unlock` calls (largely free once H-1's fixtures exist).
3. **M-1** — port the non-member test.
4. **M-2 / M-3 / M-4** — the doc sweep, in one pass.
5. **M-5** — rename the two tests; decide whether to delete or pin `register()`'s dead swap branch.
6. **L-1 … L-5** — javadoc paragraph, dead stubs, context-clear assertion, PR-description wording.

Re-run PIT after 1–3; the expected result is `NO_COVERAGE` at 0 inside `ReplenishOrderJob:190-393`,
matching the template's wrapper.
