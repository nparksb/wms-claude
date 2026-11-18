---
ticket: SBDEV-4031
kind: tdd-gate-baseline
date: 2026-11-06
worktree: .claude/worktrees/wms2-api/SBDEV-4031
branch: bugfix/SBDEV-4031-fla-lock
base: origin/develop d6424491
src_main_touched: false
---

# SBDEV-4031 — TDD-gate baseline (pre-fix)

Nothing under `src/main` was changed. Nothing was committed. All runs used JDK 21.0.8 (`mvn -v`).

## Results

| Test class | Method | AC | Kind | Result (pre-fix) |
|---|---|---|---|---|
| FixLocationAssignmentLockRaceIT | userDelete_vsRefillParkedInCreate_leavesNoOrphan | AC-1 | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | cronDeleteHoldingFla_refillSkipsWithNull | AC-2 | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | cronDelete_vsRefill_refusesAndKeepsOrder | AC-3 | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | recalcForItem_vsUserDelete_doesNotAlignToDeletedFla | AC-4 | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | perOrderRecalc_vsMove_alignsToNewLocation | AC-4b | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | recalcForItem_blockedByHeldFla | AC-4c | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | perOrderRecalc_nullDest_blockedByHeldFla | AC-4d | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | r3_blockedByHeldFla_otherOrdersStillAssigned | AC-4e | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | recalcForItem_vsUserDelete_noDeadlock | AC-5 | guard | **guard green** |
| FixLocationAssignmentLockRaceIT | refillParkedBeforeCreate_vsMove_skips | AC-6 | red-first | **correct failure** |
| FixLocationAssignmentLockRaceIT | moveHoldingFla_vsRefill_createsNothingAtOldLocation | AC-11 | red-first | **correct failure** |
| ReplenishOrderJobUnitTest$Sbdev4031LockFailureContinuesRun | deleteSubOp_pessimisticLockFailure_continuesRun | AC-7 | red-first | **correct failure** |
| ReplenishOrderJobUnitTest$Sbdev4031LockFailureContinuesRun | deleteSubOp_unexpectedRollback_continuesRun | AC-7 | red-first | **correct failure** |
| ReplenishOrderJobUnitTest$Sbdev4031LockFailureContinuesRun | fixedAssignmentSubOp_pessimisticLockFailure_continuesRun | AC-7 | red-first | **correct failure** |
| ReplenishOrderJobUnitTest$Sbdev4031LockFailureContinuesRun | r3_pessimisticLockFailure_continuesRun | AC-7 | red-first | **correct failure** |
| FixLocationAssignmentControllerIT | delete_whileFlaHeld_blocksAtFlaLockAndReturns409 | AC-9 | red-first | **correct failure** |
| FixLocationAssignmentMoveIT | move_repointsProcessableOrdersToNewLocation | AC-10 | red-first | **correct failure** |
| FixLocationAssignmentMoveIT | move_refusesWhenAnOrderAlreadyTargetsDestination | AC-10b | red-first | **correct failure** |
| FixLocationAssignmentMoveIT | move_vsTransferOfSourcePallet_noDeadlock | AC-10c | guard | **guard green** |
| Sbdev4031LockFinderContractUnitTest | flaRepository_declaresTheFourSbdev4031Finders | Fix A / AC-8 | contract | **correct failure** (finders missing) |
| Sbdev4031LockFinderContractUnitTest | flaFinders_lockAndExportContract | Fix A / AC-8 | contract | **correct failure** |
| Sbdev4031LockFinderContractUnitTest | replenishorderRepository_declaresTheThreeSbdev4031FindersUnexported | Fix A / AC-8 | contract | **correct failure** |
| Sbdev4031LockFinderContractUnitTest | replenishorderRepository_retiresR3EntityFinder | Fix A | contract | **correct failure** (old finder still declared) |
| FixLocationAssignmentLockCallSiteArchTest | scanSeesAKnownFlaRepositoryAccess | AC-8b | rail (positive control) | **green** |
| FixLocationAssignmentLockCallSiteArchTest | flaLockFinders_onlyFromAllowedMethods | AC-8b | rail | **green** |
| FixLocationAssignmentLockCallSiteArchTest | mobileReplenishService_fulfillMultipleUnitLoads_isNotTransactional | AC-8b | rail | **green** |

Totals: 15 red-first (all correct failures), 2 guards green, 4 contract tests red as intended, 3 rail tests green. No setup problems, no compile errors, **no unexpected passes**.

## Key assertion-failure lines (first failing message; the plan's §8.2 pre-fix red)

| AC | Excerpt |
|---|---|
| AC-1 | `[B blocked by A's pid] expected: "BLOCKED" but was: "B completed"`; then `[orphans] expected: 0 but was: 1` |
| AC-2 | `[A blocked by B's pid] expected: "BLOCKED" but was: "A completed"`; then `[orders] expected: 0 but was: 1` |
| AC-3 | `[B blocked by A's pid] expected: "BLOCKED" but was: "B completed"`; then `[FLA expected present] expected: 1 but was: 0` |
| AC-4 | `[destination] expected: null but was: 40314L` (40314 = L) |
| AC-4b | `[destination] expected: 40315L but was: 40314L` (L′ vs L) |
| AC-4c | `[expected blocked at the FLA lock] expected: "BLOCKED" but was: "recalculateForItem completed"` |
| AC-4d | `[expected blocked at the FLA lock] expected: "BLOCKED" but was: "recalculateOpenOrders completed"` |
| AC-4e | `[expected blocked at the FLA lock] expected: "BLOCKED" but was: "R3 completed"` (item-2 assertion green pre-fix, as expected) |
| AC-6 | `[orders to old location] expected: 0 but was: 1` |
| AC-11 | `[B blocked by A's pid] expected: "BLOCKED" but was: "B completed"`; then `[orders to old location] expected: 0 but was: 1` |
| AC-7 ×4 | `Wanted but not invoked: replenishorderRepository.getIdsForUnreachableReplenishOrdersPage(...)` (both delete-sub-op tests); `Wanted but not invoked: replenishOrderJobService.getRefillFixedLocationIds()`; `Wanted but not invoked: replenishmentOrderMaintenanceService.recalculateOpenOrders(false)` |
| AC-9 | `[blocked statement] Expecting actual: "delete from fix_location_assignment where id=$1 and version=$2" to contain: "for no key update"` |
| AC-10 | `[destination] expected: 40315L but was: 40314L` |
| AC-10b | `[expected BusinessException ("already targets the destination") but nothing was thrown] Expecting actual not to be null`; then the move went through (`FLA location expected 40314L but was 40315L`, same for its unit load) |
| Contract | `Expecting empty but was: ["lockIdByItemdataIdAndLocation/2: missing", "findByIdForUpdate/1: missing", "findActiveLocationIdByItemdataId/1: missing", "lockIdByItemdataId/1: missing"]`; order finders: `["existsByItemdataIdAndStateGreaterThanAndStateLessThan/3: missing", "findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById/1: missing", "findItemdataIdByIdAndDestinationIdIsNull/1: missing"]`; retire: `... not to contain "findByStateLessThanEqualAndDestinationIdIsNull/1"` |

Every IT red is an AssertJ soft-assertion failure (`Failures`, `Errors: 0`): no latch timeout, no setup NPE, no "harness timeout" text appeared.

## Commands

All from the worktree, with `export JAVA_HOME=$(/usr/libexec/java_home -v 21)`.

1. Compile: `mvn -o -q test-compile -Dmaven.javadoc.skip=true` → clean.
2. Unit lane:
   `mvn -o test -Dtest='Sbdev4031LockFinderContractUnitTest,FixLocationAssignmentLockCallSiteArchTest,ReplenishOrderJobUnitTest,TestClassTransactionManagerArchTest' -Dmaven.javadoc.skip=true -Dspringdoc.skip=true`
   → `Tests run: 73, Failures: 8, Errors: 0, Skipped: 0` (the 8 = 4 AC-7 + 4 contract; all pre-existing ReplenishOrderJobUnitTest nested classes green; TestClassTransactionManagerArchTest 6/6 green with the three new EXEMPT entries).
3. IT lane, first attempt (shared reused container):
   `mvn -o verify -Dit.test='FixLocationAssignmentLockRaceIT,FixLocationAssignmentMoveIT,FixLocationAssignmentControllerIT' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true -Djacoco.skip=true`
   → `Tests run: 3, Failures: 0, Errors: 3` — **environmental, not ours**: `FlywayValidateException: Migration checksum mismatch for migration version 2.2.46`. The shared reused container holds a PEER branch's V2.2.46 (memory `editing-unmerged-migration-breaks-reusable-test-container`, the SBDEV-4044 case). The shared container was not touched.
4. IT lane, graded run (throwaway container):
   `TESTCONTAINERS_REUSE_ENABLE=false mvn -o verify -Dit.test='FixLocationAssignmentLockRaceIT,FixLocationAssignmentMoveIT,FixLocationAssignmentControllerIT' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true`
   → `FixLocationAssignmentControllerIT: Tests run: 1, Failures: 1, Errors: 0, Skipped: 0`;
   `FixLocationAssignmentMoveIT: Tests run: 3, Failures: 2, Errors: 0, Skipped: 0`;
   `FixLocationAssignmentLockRaceIT: Tests run: 11, Failures: 10, Errors: 0, Skipped: 0`;
   lane total `Tests run: 15, Failures: 13, Errors: 0, Skipped: 0`. Report files written to `target/failsafe-reports/` (the testcase list was checked against the XML: all 11 + 3 + 1 methods present).
5. AC-8b detector mutation (test-only, reverted): temporarily added `findByItemdataIdIn` to `LOCK_FINDERS` →
   `Tests run: 3, Failures: 1` with `Expecting empty but was: ["service.ReplenishmentOrderMaintenanceService.buildRecalcContext", "service.ViewDtoService.getStockPerLocation"]`. File restored. Re-run: `FixLocationAssignmentLockCallSiteArchTest, TestClassTransactionManagerArchTest, ArchUnitImportReleaseRuleTest` → `Tests run: 10, Failures: 0, Errors: 0, Skipped: 0`.

The full suite was NOT run (out of scope for the gate). The executor needs it: the new ArchUnit class and the EXEMPT edit are repo-wide rails.

## Harness notes the executor needs

- **`FlaLockRaceSupport`** (new, abstract, shared by the three ITs) holds the fixture (client 40310, ids 40310–40349, deleted before and after each test) and the harness: `Park` (repository-spy park, thread-scoped, captures the parked transaction's `pg_backend_pid()`), `Holder` (two-latch `FOR UPDATE` holder on one FLA row), and `observeBlockedBy`/`blockedStatement` (`pg_blocking_pids` plus `BlockedBackendReads.confirmedBlockedStatement`; `BLOCKED` only when the statement has both `fix_location_assignment` and `for no key update`). The time-box is 2 s. Every other outcome is named: "`<X> completed`", "`blocked on: <stmt>`", or "`harness timeout: …`".
- **`wms.tenant.lock-timeout-ms=3000`** is set via `@TestPropertySource` (the lane default is 10000). AC-4e and AC-9 hold for 3.6 s once blocked.
- **The post-commit maintenance trigger is muted** off the threads an AC names. `findIdsByStateAndItemdataId` is stubbed to return empty unless the thread called `allowRecalc()`. Without the mute, the trigger runs `recalculateForItem` on B's thread after B's delete or move commits. In AC-4/4b it would then align or cancel the order before A resumes, and the red would come for the wrong reason.
- `deleteByUser`'s caller check is stubbed on `ClientService`/`AccessService` spies, copying the `FixLocationAssignmentDeleteByUserIT` precedent. These are the only non-repository spies, and they are never parked. AC-9 also stubs `checkAnyAccess` for the controller's `@RequiresFunction`.
- **AC-9 note:** pre-fix, the endpoint already answers 409 "Resource Locked", `retryable:true`. The held row makes the commit-time `DELETE` hit 55P03, and that surfaces as a `PessimisticLockingFailureException`. So the 409 and body assertions are green before the fix. Only the "FIRST statement is the lock" assertion is red, exactly as the plan's red column says.
- **AC-5 note:** pre-fix, A's recalc of O fails with 23505 `idx_replenishorder_active_item_dest` because it aligns O to L while order B still targets L (log line `duplicate key value violates unique constraint`). The guard only asserts no 40P01/55P03, so it is green. That is a real pre-fix outcome, not a harness fault. Post-fix, F is taken first and O's post-lock read still finds L. The executor should check whether the guard stays green for the right reason after Fix D.
- **AC-10c note:** the guard asserts only "no 40P01/55P03 on either side". It does not assert that the transfer succeeded, because a BLOCK_REALIGN refusal is acceptable for a deadlock guard. This is weaker than it looks, so read it before relying on it.

## Deferred items

| Item | Why deferred |
|---|---|
| AC-8 pins in `FunctionGuardArchTest` (`fixLocationAssignmentRepository_shouldStillExportItsSiblingSearches` +4 names; new `replenishorderRepository_sbdev4031FindersAreUnexported`) | They are part of §6.2 step 1 (Fix A + rails) and would be red until the finders exist. `Sbdev4031LockFinderContractUnitTest` pins the same names, arities, `@Lock` and `exported = false` now. The executor edits the existing pin in the step-1 commit. |
| AC-8b positive control "each allowed method has ≥1 call" (critic N1) | It holds only after Fix F. Until then, `scanSeesAKnownFlaRepositoryAccess` proves the instrument works. |
| AC-8b mutation "annotate `fulfillMultipleUnitLoads` / the class" | It needs a src/main edit, so the executor runs it. |
| AC-10 fourth clause: a follow-up `fulfillMultipleUnitLoads` scanning L′ succeeds | It needs the mobile claim flow (a STARTED, claimed order and a `MultiReplenishRequestDto`) and is post-fix evidence only. The first red (destination) is in place. |
| Behavioural tests that call the new finders directly (unit re-stubs, `calculateOrder_automatic_flaGone_returnsNullAndInsertsNothing`, `alignDestination_flaGoneUnderLock_nullsAssignment`) | Per the gate rule, they belong to the executor's first commit once the finders exist (§8.3). |
| Every mutation in the §8.2 mutation column (AC-1…AC-11, AC-5, AC-10c) | Each one removes or reorders code the fix adds, so the mutation check is deferred to the executor. The only one provable now (the AC-8b detector) was done; see command 5. |
| §8.3 churn tests | Not touched, by instruction. They are: `FixLocationAssignmentServiceUnitTest`, `FixLocationAssignmentUserDeleteContractUnitTest`, `ReplenishGeneratorServiceUnitTest`, `ReplenishmentOrderMaintenanceServiceUnitTest`, `ReplenishorderServiceUnitTest` (R3 nested), `ReplenishOrderJobServiceUnitTest`, `FixLocationAssignmentServiceIT`, `ManualCutCooldownEndToEndIT`, `DeleteContainerWithStockIT`. |

## Unexpected passes

None. Two soft sub-assertions are green pre-fix, both by design and both noted above: AC-4e's item-2 assertion, and AC-9's 409/body assertions. In each case the AC's first assertion is red.

## Files (`git -C .claude/worktrees/wms2-api/SBDEV-4031 status --short`)

```
 M src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java   (+3 EXEMPT_NON_TRANSACTIONAL entries)
 M src/test/java/net/aim_ai/wms/unit/schedulejob/ReplenishOrderJobUnitTest.java        (+@Nested Sbdev4031LockFailureContinuesRun)
?? src/test/java/net/aim_ai/wms/integration/service/FixLocationAssignmentControllerIT.java
?? src/test/java/net/aim_ai/wms/integration/service/FixLocationAssignmentLockRaceIT.java
?? src/test/java/net/aim_ai/wms/integration/service/FixLocationAssignmentMoveIT.java
?? src/test/java/net/aim_ai/wms/integration/service/FlaLockRaceSupport.java
?? src/test/java/net/aim_ai/wms/unit/config/FixLocationAssignmentLockCallSiteArchTest.java
?? src/test/java/net/aim_ai/wms/unit/repo/Sbdev4031LockFinderContractUnitTest.java
```

**Local IT reminder:** the shared reused PG container carries a peer's V2.2.46. Run this lane with `TESTCONTAINERS_REUSE_ENABLE=false` until that peer merges or repairs it.
