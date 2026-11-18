---
ticket: SBDEV-4031
kind: implementation-report
date: 2026-11-06
worktree: .claude/worktrees/wms2-api/SBDEV-4031
branch: bugfix/SBDEV-4031-fla-lock
base: origin/develop 8507785d (gate commit 68d3b7f2)
pushed: false
---

# SBDEV-4031 — implementation report

JDK 21.0.8 for every run (`mvn -v`). Every IT run used `TESTCONTAINERS_REUSE_ENABLE=false`. Nothing pushed.

## Commits (on top of the gate commit 68d3b7f2)

| SHA | Subject |
|---|---|
| 91860679 | fix(SBDEV-4031): lock the FLA row before deciding an order's destination from it (WIP) |
| 88d09578 | test(SBDEV-4031): AC-8b per-method positive control; F2 stale javadoc |
| ab718d72 | test(SBDEV-4031): AC-10c-bis - park move holding its order lock, so r1's F->O->P order deadlocks |
| 16d45d6b | test(SBDEV-4031): AC-10 clause 4 - multi-UL confirm at L' after a move (post-fix evidence) |
| 85daa64b | test(SBDEV-4031): NeverMatcherNullBlindness rail - bare any() on reference params, inventory 1->2 and 6->8 |

The first commit carries all of Fixes A–F at once: retiring `findByStateLessThanEqualAndDestinationIdIsNull` (Fix A) does not compile without Fix E, so the plan's §6.2 per-step commits could not each build. The main session may split or squash.

## Files changed (8507785d..HEAD, src only)

Production: `repo/jpa/FixLocationAssignmentRepository.java` (+4 finders, F2 javadoc), `repo/jpa/ReplenishorderRepository.java` (+3 scalar finders, entity finder retired), `schedulejob/ReplenishOrderJob.java` (D3), `service/FixLocationAssignmentService.java` (D1, D2, Fix F), `service/ReplenishGeneratorService.java` (C0), `service/ReplenishmentOrderMaintenanceService.java` (Fix D + A1), `service/ReplenishorderService.java` (Fix E), `service/job/ReplenishOrderJobService.java` (no pre-read, R3 wrapper non-tx).

Tests: gate files (unchanged assertions), plus `FixLocationAssignmentLockCallSiteArchTest` (+positive control), `FixLocationAssignmentMoveIT` (+AC-10c-bis, +AC-10 clause 4), `FunctionGuardArchTest` (AC-8 pins), `NeverMatcherNullBlindnessArchTest` (inventory), and the §8.3 churn: `FixLocationAssignmentServiceUnitTest`, `ReplenishGeneratorServiceUnitTest`, `ReplenishmentOrderMaintenanceServiceUnitTest`, `ReplenishorderServiceUnitTest`, `ReplenishOrderJobServiceUnitTest`, `ReplenishmentFirstTouchInvariantUnitTest`, `ReplenishorderRepositoryIntegrationTest`. ArchUnit store `5fb3fee0-…`: exactly the two planned removals (`delete(Long)` + R3 `Optional.get()`), nothing else.

Docs (sbdocs, not git): `3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §8.5 "5 s" → 3000 ms (F5).

## §0 rows

| Row | Done? | Where |
|---|---|---|
| D1 `deleteByUser` | done | `findByIdForUpdate` first; javadoc step 0 |
| D2 `delete(Long)` + caller | done | lock first, `MANDATORY`, no `rollbackFor`; caller pre-read dropped |
| D3 job catches | done | delete sub-op `+PLF` and final `catch (Exception)` logging `e`; fixed-assignment creator `+PLF`; R3 `+PLF` |
| C0 `calculateOrder(…, automatic)` | done | scalar lock (item, location) first, null skip, javadoc widened |
| C4, C5/C6, C7/C8, A1–A3, V1 | OUT as planned | V1 fenced by AC-8b |
| R1/R2 recalc | done | outer lock after ctx before loop; per-order hint lock; post-lock location read; `alignDestination` returns null when FLA gone; javadocs retired |
| Amendment A1 | done | `recalculateOrder` takes `lockIdByItemdataId` after the order lock when the hint missed and the destination is null under the lock |
| R3 | done | id loop, per-order `REQUIRES_NEW` via `self`, per-order catch, (item, loc) already-targeted skip at INFO |
| M1 `move` | done | F → P → L′ → O, refusals on projections, re-point + INFO log |
| F2 rider | **partial** | stale javadoc fixed; `refillFixedLocations` NOT deleted (see "Not done") |
| F5 rider | done | boundary map §8.5 |

## Test commands and results

All from the worktree with `export JAVA_HOME=$(/usr/libexec/java_home -v 21)`.

1. Gate ITs + adjacent FLA ITs (post-fix):
   `TESTCONTAINERS_REUSE_ENABLE=false mvn -o verify -Dit.test='FixLocationAssignmentLockRaceIT,FixLocationAssignmentMoveIT,FixLocationAssignmentControllerIT,FixLocationAssignmentServiceIT,FixLocationAssignmentDeleteByUserIT' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true`
   → ControllerIT `1/0/0/0`, MoveIT `3/0/0/0`, LockRaceIT `11/0/0/0`, DeleteByUserIT `5/0/0/0`, ServiceIT `13/0/0/0` (nested); lane `Tests run: 33, Failures: 0, Errors: 0, Skipped: 0`. `FixLocationAssignmentServiceIT` needed no reseed (§8.3 "run it first").
2. Added MoveIT tests, unmutated: AC-10c + AC-10c-bis `Tests run: 2, Failures: 0, Errors: 0, Skipped: 0`; AC-10 clause 4 `Tests run: 1, Failures: 0, Errors: 0, Skipped: 0`.
3. Gate unit + rails + churn:
   `mvn -o test -Dtest='Sbdev4031LockFinderContractUnitTest,FixLocationAssignmentLockCallSiteArchTest,ReplenishOrderJobUnitTest,FunctionGuardArchTest,…'` — churn classes `Tests run: 408, Failures: 0, Errors: 0, Skipped: 0`; FLA service unit `101/0/0/0`; rail fix rerun `163/0/0/0`.
4. Full `mvn -o clean verify` #1 (before the rail fix): surefire `Tests run: 9766, Failures: 2, Errors: 0, Skipped: 1` — both in `NeverMatcherNullBlindnessArchTest`, caused by my new `never()` matchers; fixed in 85daa64b. Failsafe did not run (surefire red).
5. Full `mvn -o clean verify` #2 (HEAD 85daa64b): `TESTCONTAINERS_REUSE_ENABLE=false mvn -o clean verify -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` → **BUILD SUCCESS**. Surefire (summed from `target/surefire-reports/TEST-*.xml`): `tests=9766, failures=0, errors=0, skipped=1`. Failsafe (summed XML, and `failsafe-summary.xml` `completed=1221`): `Tests run: 1221, Failures: 0, Errors: 0, Skipped: 23` — the whole IT lane, which includes every FixLocationAssignment*, Replenish*, ReplenishmentOrderMaintenance*, ManualCutCooldown* and DeleteContainerWithStockIT class. Two summary lines present in the log. `git status` clean afterwards (no ArchUnit store churn).

Baseline (coordinator, clean 8507785d surefire): `tests=9740, failures=0, errors=0, skipped=1`. Branch delta +26 tests = the new/added unit tests.

## Mutation table

Hand mutations through a driver (`scratchpad/mut/run.py`): backup copy → edit → `mvn -o clean …` (the log shows "Compiling", so no stale bytecode) → restore from the backup copy (never git). `git status` was clean after every batch. PIT not used: every target is either a lock call whose effect is only visible in a two-thread Postgres IT or a catch arm, and hand edits gave attributable messages directly.

| # | Mutation | Killed by | Kill message (first) |
|---|---|---|---|
| I01 | remove C0 lock | LockRaceIT AC-1, AC-2, AC-11 | `[B blocked by A's pid] expected: "BLOCKED" but was: "B completed"` (AC-1, AC-11); `[A blocked by B's pid] … "A completed"` (AC-2) |
| M1 | remove C0 lock (unit) | `ReplenishGeneratorServiceUnitTest` `calculateOrder_automatic_locksFlaBeforeTheIdempotencyRead` | `Wanted but not invoked: lockIdByItemdataIdAndLocation(1L, 63802L)` |
| I12 | C0 by item only (drop location predicate) | AC-6, AC-11 | `[orders to old location] expected: 0 but was: 1` |
| I02 | D1 lock moved after the holder projection | AC-1 | `[orphans] expected: 0 but was: 1` |
| I03 | D1 reverted to `findById` | ControllerIT AC-9 | `[blocked statement] Expecting actual: "delete from fix_location_assignment where id=$1 and version=$2" to contain "for no key update"` |
| I04 | remove `delete(Long)` lock | AC-2 | `[A blocked by B's pid] expected: "BLOCKED" but was: "A completed"` |
| I05 | restore caller's `findById` pre-read | AC-3 | `SBDEV-3286 lock-read rail: a locking repository query returned a row this transaction already held without its lock …` |
| I06 | `rollbackFor = BusinessException` on `delete(Long)` | AC-3 | `[B (cron delete) threw, e.g. UnexpectedRollbackException] expected: null` |
| I07 | remove `recalculateForItem` outer lock | AC-4c | `[expected blocked at the FLA lock] expected: "BLOCKED" but was: "recalculateForItem completed"` |
| I13 | outer lock moved into the loop after the first order (AC-5) | AC-5 | `[B ended in a deadlock or lock timeout …]`; log shows `40P01 deadlock detected` |
| I08 | remove `recalculateOrder` hint lock only | **SURVIVED AC-4d** (by design, see note 1) | — |
| I08b | remove hint lock AND the A1 lock | AC-4d | `[expected blocked at the FLA lock] expected: "BLOCKED" but was: "recalculateOpenOrders completed"` |
| M4 | remove hint lock (unit) | `ReplenishmentOrderMaintenanceServiceUnitTest.setsDestinationFromActiveFla`; `ReplenishmentFirstTouchInvariantUnitTest` ×3 | `VerificationInOrderFailure … Wanted but not invoked: findByIdForUpdate(1L)` (2 locks expected before the order lock) |
| M5 | remove A1 stale-hint lock | `alignDestination_staleHint_locksFlaAfterTheOrderBeforeAligning` | `VerificationInOrderFailure … Wanted but not invoked: lockIdByItemdataId(10L)` |
| I09 | `alignDestination` reads ctx location again | AC-4, AC-4b | `[destination] expected: null but was: 40314L`; `[destination] expected: 40315L but was: 40314L` |
| I10 | remove R3 per-order lock | AC-4e | `[expected blocked at the FLA lock] expected: "BLOCKED" but was: "R3 completed"` |
| M6 | remove R3 lock (unit) | `ReplenishorderServiceUnitTest$RecalculateReplenishmentOrder.shouldUpdateDestinationForOrdersWithFixedAssignment` | `Wanted but not invoked: lockIdByItemdataId(10L)` |
| I11 | remove R3 per-order catch | AC-4e | `[item-2 destination] Expecting actual not to be null` |
| M7 | remove R3 catch (unit) | `oneOrdersFailureDoesNotStopTheNext` | `PessimisticLockingFailureException: 55P03` escapes |
| I14 | `move` lock order reverted to r1 (P/L′ after O) | **SURVIVED AC-10c** (note 2) | — |
| I14b | same, vs new AC-10c-bis | `move_parkedOnOrderLock_vsTransferOfSourcePallet_noDeadlock` | `[B (transfer) ended in a deadlock or lock timeout …]`; log shows `40P01 deadlock detected` |
| I15 | remove move re-point | AC-10 | `[destination] expected: 40315L but was: 40314L` |
| M9 | remove re-point (unit) | `shouldAllowMoveWhenReplenishmentOrderStateIsProcessable`, `move_locksFlaThenPickordersThenDestinationThenOrders` | `[SBDEV-4031: re-pointed to the destination] expected: 2L but was: 1L` |
| I15b | remove re-point, vs AC-10 clause 4 | **SURVIVED** (note 3) | — |
| I16 | remove move "already targets" refusal | AC-10b | `[expected BusinessException ("already targets the destination") but nothing was thrown]` |
| M10 | remove refusal (unit) | `move_refusesWhenAnOrderAlreadyTargetsTheDestination` | `Expecting message … already targets the destination! but was … No unit load on assigned location` |
| M12a | drop `PessimisticLockingFailureException` from the delete sub-op catch | **SURVIVED** (note 4, equivalent) | — |
| M12b | narrow the delete sub-op's final `catch (Exception)` | AC-7 `deleteSubOp_unexpectedRollback_continuesRun` | `Wanted but not invoked: replenishorderRepository.getIdsForUnreachableReplenishOrdersPage(…)` |
| M12c | drop PLF from the fixed-assignment creator catch | AC-7 `fixedAssignmentSubOp_pessimisticLockFailure_continuesRun` | `Wanted but not invoked: replenishOrderJobService.getRefillFixedLocationIds()` |
| M12d | drop PLF from the R3 job catch | AC-7 `r3_pessimisticLockFailure_continuesRun` | `Wanted but not invoked: replenishmentOrderMaintenanceService.recalculateOpenOrders(false)` |
| M18a | `lockIdByItemdataId` inside `assignDestinationForMultiUnitLoads` | AC-8b `flaLockFinders_onlyFromAllowedMethods` | `A method outside the SBDEV-4031 allowlist takes the FLA lock …` |
| M18b | `@Transactional` on `fulfillMultipleUnitLoads` | AC-8b `mobileReplenishService_fulfillMultipleUnitLoads_isNotTransactional` | `… fulfillMultipleUnitLoads(…) must stay non-transactional …` |
| M19 | drop `exported = false` from `findItemdataIdByIdAndDestinationIdIsNull` | AC-8 `replenishorderRepository_sbdev4031FindersAreUnexported` + contract test | `Expecting empty but was: ["findItemdataIdByIdAndDestinationIdIsNull"]` |

Notes:
1. **I08 survives AC-4d by design of Amendment A1.** With the pre-lock hint gone, the A1 branch still takes the FLA lock (after the order lock) before aligning, so the recalc still blocks at the FLA statement. Lock order there becomes O → F, ABBA-1's cycle-free direction. The hint's F-before-O ordering is pinned by the unit test (M4); I08b proves AC-4d bites once both locks go.
2. **AC-10c cannot see ABBA-10b.** It parks `move` on `findByStoragelocationId(L)`, which comes after every move lock in both the fixed and the r1 order, so A already holds P when B starts and B just queues. Not an assertion defect, a park-point defect: the plan's AC-10c mutation cannot be killed by it. I did not change AC-10c; I added **AC-10c-bis**, which parks right after the order lock returns (post-fix A holds F, P, L′, O there; under r1 it holds O without P). Green on the fix, `40P01` under r1 (I14b).
3. **AC-10 clause 4 is post-fix evidence, not a guard.** `assignDestinationForMultiUnitLoads` overwrites the order's destination with the SCANNED location whenever the item's FLA is there, so a confirm scanning L′ succeeds even without the re-point. The stale order only fails when the operator scans the destination it displays (old L). Javadoc on the test says so. The re-point is guarded by AC-10 (I15) and two unit tests (M9).
4. **M12a is an equivalent mutant.** The plan also adds a final `catch (Exception e)` to the same sub-op, which catches PLF too; the only observable difference is WARN (lock conflict, behind `showLog()`) vs ERROR. Not pinned.

## Deviations from the plan

| # | Plan | Done instead | Why |
|---|---|---|---|
| 1 | Fix F step 2 `unitloadRepository.getReferenceById(...)` | `unitloadRepository.findById(...).orElse(null)` | `UnitloadRepository` is a `PagingAndSortingRepository`/`CrudRepository`, not a `JpaRepository`: no `getReferenceById` (compile error). `orElse(null)` keeps the architect-N2 property (a missing UL reaches the existing refusals; a null top walks nothing). It costs one plain SELECT of the UL; the existing code already read the UL plainly before the transfer, so no new lock upgrade. |
| 2 | Fix D: `alignDestination` itself calls `findActiveLocationIdByItemdataId` | `recalculateOrder` does the A1 lock and the post-lock read and passes the location into `alignDestination(order, assignment, lockedLocationId)` | AC-8b's method-level allowlist names `recalculateOrder`, not the private `alignDestination`; calling a lock-rail finder from `alignDestination` would fail the gate rail. Behaviour identical. |
| 3 | Fix F step 4 "in processing" refusal via `existsBy…` | `existsBy…` decides; on refusal only, `replenishorderService.getActive` names the order | Keeps the existing message `ReplenishmentOrder=<number> is currently in processing!` (asserted by `FixLocationAssignmentServiceUnitTest`). The entity read happens only on the refusal path, whose transaction rolls back, so no later lock is upgraded. |
| 4 | §6.2 one commit per step | one production commit for Fixes A–F | Fix A retires the R3 entity finder, which does not compile without Fix E. |
| 5 | `ReplenishGeneratorServiceUnitTest`: re-stub `lockIdByItemdataIdAndLocation` per test | one `lenient()` default `Optional.of(1L)` in `@BeforeEach`, plus 3 new tests that override/verify | Same effect for 13–15 tests with one line; the skip and the order are pinned by explicit tests. |
| 6 | §8.3 "never weaken an assertion" | `FixLocationAssignmentServiceUnitTest$…$Move.probeFalse_neverReadsFlag`: `verify(locationRepository, never()).lockById(any())` → `verify(locationRepository, times(1)).lockById(2L)` | Fix F intentionally takes the destination lock up front, so `never()` is false by design. The exact count still kills a bounds-path lock (it would be 2). Flag for review. |
| 7 | — | `ReplenishorderServiceUnitTest.handlesRecalculateWhenAssignedLocationNotFound` rewritten: "location missing" is now "no active location under lock" | The plan drops R3's `locationRepository.findById` existence check (FK guarantees it). The `never().save` assertion kept. Flag for review. |
| 8 | — | `ReplenishmentFirstTouchInvariantUnitTest` ×3: added `verify(replenishorderRepository).findItemdataIdByIdAndDestinationIdIsNull(ORDER_ID)` before each `verifyNoMoreInteractions` | The rail correctly flagged the new pre-lock read; it is a scalar (no entity at READ), so it is accounted for explicitly rather than hidden. |
| 9 | — | `ReplenishorderRepositoryIntegrationTest` nested class ported from the retired entity finder to `findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById` (+ `isSorted()`) | The finder it tested is retired by the plan. |
| 10 | — | Retired finder was an SDR-exported search (`/replenishorder/search/findByStateLessThanEqualAndDestinationIdIsNull`) | Plan retires it; `grep` of wms2-web-ui, wms2-mobile-ui and oms-laravel-api found no caller. HTTP-visible removal: mention in the PR. |
| 11 | — | `ReplenishOrderJobService` delete log lines now log the id instead of the FLA entity | the entity is no longer loaded there. |

## Not done / for the main session

- **F2: `refillFixedLocations` not deleted.** Deleting it means deleting `ReplenishGeneratorServiceUnitTest$RefillFixedLocations` (2 tests), `refillFixedLocations_shouldSwitchTheCooldownOnForEligibilityAndCreate`, and the sole assertion of `MobileReplenishServiceUnitTest.fulfillMultipleUnitLoads_shouldNotRunWarehouseWideRefill_afterCommit` (`never().refillFixedLocations()`). That is deleting assertions, which the brief forbids without sign-off. The stale javadoc half of F2 is done. Decide: delete method + those tests, or leave.
- **AC-10c is weaker than its plan row** (note 2): the main session may want AC-10c-bis listed in the plan's §8.2 and the AC-10c row's mutation column updated.
- §8.4 manual DEV test plan: not run (not in scope of this lane).
- No code review lane run (not in this brief).

## Review fix pass (code r1 APPROVE 1M/7L; security PASS 2L) — 2026-11-06

| SHA | Subject |
|---|---|
| 03850bb0 | fix(SBDEV-4031): review r1 M1 - skip align on a stale hint, no O->F lock (plan 10.z) |
| fd1a5378 | fix(SBDEV-4031): review r1 - move runs its lock-free refusals before P->L' (security L1, code L7) |
| e60a10c4 | fix(SBDEV-4031): review r1 - dead itemdataRepository, lock-conflict log labels, R3 WARN class name, R3 test fixes (code L2/L3/L6, security L2) |

| Finding | Disposition |
|---|---|
| Code M1 (§10.z "skip align") | Done. `recalculateOrder`: when the hint missed and the destination is null under the order lock, there is no `lockIdByItemdataId` and no align, and `assignment = null` for this pass. The A1 lock and its false comment are deleted and replaced by a 3-line §10.z comment. `alignDestination_staleHint_locksFlaAfterTheOrderBeforeAligning` is replaced by `…_skipsAlignAndTakesNoLateFlaLock`, which asserts: no F lock after `findByIdForUpdate`, no post-lock read, destination null, default upper bound 84. |
| Code L5 | `alignDestination_staleHint_perOrder_takesNoFlaLock` (via `recalculateOpenOrders(true)`): no FLA lock at all, destination null. |
| Code L4 | `flaLocked` renamed `flaLockAttempted`, with a comment. |
| Code L2 | `ReplenishorderService.itemdataRepository` field and constructor parameter removed (`@InjectMocks`, so no test constructor). The unit test keeps its `@Mock ItemdataRepository`: two existing `never().findById` rows reference it and are now trivially true. They were not deleted (no assertion deletion without sign-off). |
| Code L3 | `ReplenishOrderJob` :825 (with `fixAssignmentId`) and :924 relabelled "lock conflict occurred". |
| Code L6 | `shouldSkipOrdersWithoutFixedAssignment` stubs the FLA lock empty. The location-not-found test is renamed `handlesRecalculateWhenFlaInactiveUnderLock` and now asserts destination null plus InOrder lock → order lock → location read. |
| Code L7 | DisplayName is now "…; no order locked, nothing moved". **Deviation:** after security L1 that refusal runs BEFORE the L′ lock, so the test asserts `verify(locationRepository, never()).lockById(any())` and `never().lockOwningPickingorders`, not the requested `verify(...).lockById(2L)`. That would now be false. |
| Code L1 | Left for the main session (commit-subject reword). |
| Security L1 | Done. After F and before P → L′, `move` now refuses: destination missing or not a flowbin, an order in processing, an order already at L′. All are plain reads or projections, so they add no lock edge. **Kept under the L′ lock on purpose:** "FLA already at L′" and "unit load already at L′". A transfer or FLA create into L′ locks the same location row, so checking those before it would reopen a check-then-act gap. The javadoc's "Accepted tension" is narrowed to those two plus the source checks. In `MoveSourceValidation.setUp` two L′ stubs became `lenient()` (Arrange only). AC-10b, AC-10c, AC-10c-bis and the move InOrder unit test all stay green (full verify below). |
| Security L2 | The R3 per-order WARN logs `e.getClass().getName()`; the throwable stays at DEBUG. |

Mutations (same driver, restored from backup copies, tree clean after):

| # | Mutation | Killed by | Message |
|---|---|---|---|
| R1 | re-add the late `lockIdByItemdataId` in the stale-hint branch | `…_skipsAlignAndTakesNoLateFlaLock`, `…_staleHint_perOrder_takesNoFlaLock` | `VerificationInOrderFailure: fixLocationAssignmentRepository.lockIdByItemdataId(<any>); Wanted 0 times` |
| R1b | restore the old A1 (late lock + align) | same two tests | same |
| I08r | remove the pre-lock hint (re-run of I08) | **now KILLED by AC-4d** `perOrderRecalc_nullDest_blockedByHeldFla` | `[expected blocked at the FLA lock] expected: "BLOCKED" but was: "recalculateOpenOrders completed"`. With A1 gone nothing else takes F, so the hint is the only lock and the IT sees its removal. |

Full `TESTCONTAINERS_REUSE_ENABLE=false mvn -o clean verify -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` at e60a10c4 → BUILD SUCCESS. Surefire (XML sum): `tests=9767, failures=0, errors=0, skipped=1` (+27 vs the 9740 baseline: the earlier 26, plus L5's test). Failsafe (XML sum; `failsafe-summary.xml` `completed=1221`): `Tests run: 1221, Failures: 0, Errors: 0, Skipped: 23`. `git status` clean.

## Review fix pass r2 (code r2 APPROVE, 0 High/Medium) — 2026-11-06

Commit: **1114fa26** fix(SBDEV-4031): review r2 - re-check already-targets under the L' lock, pin the L'-guarded checks and lock-free refusals, lock-conflict WARNs log the class only.

| Finding | Disposition |
|---|---|
| L-1 | New `move_checksDestinationOccupancyUnderTheDestinationLock`. It checks with InOrder that `lockById(2L)` runs before `findByAssignedlocationId(2L)` and before `findByStoragelocationId(2L)`. |
| L-2 | Both stale-hint tests now share a lenient stub `findActiveLocationIdByItemdataId(10L) → Optional.of(55L)`, in `stubStaleHintTotals`. |
| L-3 | Removed the `@Mock ItemdataRepository` and its two `never().findById` rows from `ReplenishorderServiceUnitTest`. Deletion approved by the main session. |
| L-4 | The two `ReplenishOrderJob` lock-conflict WARNs now log `e.getClass().getName()`; the throwable goes to DEBUG. |
| Q-1 | `move` keeps the early lock-free refusal. It now re-runs the same projection under the L′ lock (helper `refuseIfAnOrderAlreadyTargets`, same message). Pinned by `move_reChecksAlreadyTargetsUnderTheDestinationLock`: the projection is stubbed empty and then non-empty, so the move is refused after `lockById(2L)`, with no order lock, save or transfer. |
| Conformance gap | `shouldThrowExceptionWhenDestinationIsNotFlowbin` and `shouldThrowExceptionWhenReplenishmentOrderInProcessing` now also check that `never().lockOwningPickingorders(any())` and `never().lockById(any())` were called. |
| Rail | `NeverMatcherNullBlindnessArchTest` inventory: `FixLocationAssignmentServiceUnitTest` goes 2 → 3, because Q-1's `never().transferUnitLoadToLocation(…, anyBoolean(), …)` hits the primitive `boolean ignoreLock`. |

Mutations (same driver; files restored from scratchpad copies; tree clean after):

| # | Mutation | Killed by | Message |
|---|---|---|---|
| K1 | hoist the FLA/UL-at-L′ checks above P → L′ (r2 mutant d) | `move_checksDestinationOccupancyUnderTheDestinationLock` | `VerificationInOrderFailure … Wanted but not invoked: fixLocationAssignmentRepository.findByAssignedlocationId(2L)` |
| K2 | stale-hint branch aligns without the lock | both stale-hint tests | `[not aligned: §10.z skips align on a stale hint] expected: null but was: 55L` |
| K3 | remove the under-lock re-check | `move_reChecksAlreadyTargetsUnderTheDestinationLock` | `Expecting message … REPL-LATE already targets the destination! but was … No unit load on assigned location` |
| K4a | P → L′ prefix before the flowbin refusal | `shouldThrowExceptionWhenDestinationIsNotFlowbin` (+3 others) | `NeverWantedButInvoked: pickLineRealignmentService.lockOwningPickingorders(<any>)` |
| K4b | P → L′ prefix before the in-processing refusal | `shouldThrowExceptionWhenReplenishmentOrderInProcessing` (+2 others) | `NeverWantedButInvoked: pickLineRealignmentService.lockOwningPickingorders(<any>)` |

Runs:
- `FixLocationAssignmentMoveIT,FixLocationAssignmentLockRaceIT` (fresh container): `Tests run: 16, Failures: 0, Errors: 0, Skipped: 0`.
- Full `TESTCONTAINERS_REUSE_ENABLE=false mvn -o clean verify -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` at 1114fa26: BUILD SUCCESS.
  - Surefire (XML sum): `9769/0/0/1`, +2 vs e60a10c4 (L-1, Q-1).
  - Failsafe (XML sum; `completed=1221`): `1221/0/0/23`, same as e60a10c4.
- `git status` clean afterwards.
