---
title: "SBDEV-3755 Fix 1 — TDD gate baseline"
ticket: SBDEV-3755
created: 2026-10-13
---

# SBDEV-3755 Fix 1: TDD gate baseline

## Where

| Item | Value |
|---|---|
| Worktree | `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3755-fix1` |
| Branch | `fix/SBDEV-3755-transferstock-replen-held-opt-in` (not pushed) |
| Base | `c6f0cbc0` (PR #510 head) |
| Scaffold commit | `2113fdc5` `test-scaffold(stockunit): ...` |
| Failing-tests commit | `7b59ae5c` `test(stockunit,replenish): SBDEV-3755 TDD gate ...` |

## Run counts

| Run | Command | Result |
|---|---|---|
| Base c6f0cbc0, full `clean verify` (other worktree) | baseline log | unit 8264 / 0 F / 0 E / 1 skip; IT 842 / 0 / 0 / 23 skip; BUILD SUCCESS |
| Scaffold `2113fdc5`, affected classes | `mvn -o test -Dtest='TransferVerificationsUnitTest,StockunitBusinessService*,...'` | 1104 run, 1 failure: the NeverMatcher inventory drift, which I then fixed. Re-run green |
| Scaffold `2113fdc5`, full unit lane | `mvn -o test` | **8276 run, 0 F, 0 E, 1 skip.** Same failing set as base (empty); +12 = `TransferVerificationsUnitTest` |
| Gate `7b59ae5c`, full unit lane | `mvn -o test` | **8328 run, 36 F, 0 E, 1 skip.** All 36 are the intended REDs below |
| Gate ITs | `mvn -o verify -Dit.test='ReplenishMultiHolderMoveIT,TransferStockReplenHoldGuardIT' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | 9 run: 6 RED (assertion), 3 green |

I did not run the IT lane on the scaffold, because the baseline run was holding the shared container. The scaffold changes no behaviour, and the SBS constructor change does load in every surefire Spring context.

## Results on the scaffold

Key: RED-a means the test fails on an assertion. Mockito "Wanted but not invoked" and "Argument(s) are different" errors count as assertions that name the missing call.

### Fix A: guard (`StockunitBusinessServiceReplenHoldGuardUnitTest`)

| Method | AC | Label | Result | Key failure line |
|---|---|---|---|---|
| `transferStockToUnitLoad_shouldRefuseNamingHolderSuAndUnitLoad_whenReparentDisplacesHolder` | A1 | RED | RED-a | `[A1: moving the whole of a stock unit ... the guard must refuse it] Expecting actual not to be null` |
| `transferStockToUnitLoad_shouldWriteNothing_whenReparentIsRefused` | A1 | RED | RED-a | `[A1: the re-parent must be refused before its first write]` |
| `transferStockToUnitLoad_shouldRefuseAndLeaveDestinationAmount_whenDrainToZeroDisplacesHolder` | A2 | RED | RED-a | `[A2: merging the whole source ... the guard must refuse it]` |
| `transferStockToUnitLoad_shouldSucceedWithoutHolderRead_whenSplit` | A3 | CTRL | green | — |
| `transferStockToUnitLoad_shouldSucceedWithoutHolderRead_whenSourceHasFixLocationAssignment` | A4 | CTRL | green | — |
| `transferStockToUnitLoad_shouldReparent_whenNoHolders` | A5 | CTRL | green | — |
| `transferStockToUnitLoad_shouldLockThenProjectThenLoadOneOrder_whenRefusing` | A6 | RED | RED-a | `Verification in order failure Wanted but not invoked: findHoldersByStateLessThanAndStockunitIdOrderById(700, 4711L)` |
| `transferStockToUnitLoad_shouldReadProjectionWithoutLoadingOrders_whenAllowAny` | A6 | RED | RED-a | `Wanted but not invoked: findHoldersByStateLessThanAndStockunitIdOrderById(700, 4711L)` |
| `transferStockToUnitLoad_shouldNameInProgressHolder_whenOneHolderBlocksMove` | A7 | RED | RED-a | `[A7: the in-progress holder is the one ...]` |
| `transferStockToUnitLoad_shouldNameLowestIdHolder_whenNoHolderBlocksMove` | A7 | RED | RED-a | `[A7: no holder blocks the move ...]` |
| `transferStockToUnitLoad_shouldNameNextCandidate_whenChosenHolderRowIsGone` | A8 | RED | RED-a | `[A8: REPL-9's row is gone ... REPL-5 is named]` |
| `transferStockToUnitLoad_shouldProceedAfterTryingEachCandidate_whenAllHolderRowsAreGone` | A8 | RED | RED-a | `Wanted but not invoked: replenishorderRepository.findById(9L)` |
| `transferStockToUnitLoad8_shouldRefuse_whenReparentDisplacesHolder` | A9 | RED | RED-a | `[A9: the 8-arg overload ... must delegate with REFUSE]` |
| `transferStockToUnitLoad9_shouldRefuse_whenReparentDisplacesHolder` | A9 | RED | RED-a | `[A9: the 9-arg overload ...]` |
| `transferStockToUnitLoad_shouldWarnNamingForeignHoldersOnly_whenAllowAnyDisplacesWithOwnOrder` | A10 | RED | RED-a | `[A10: exactly one REPLEN_HELD_DISPLACED WARN ...] Expected size: 1 but was: 0` |
| `transferStockToUnitLoad_shouldReturnForeignHoldersOnly_whenAllowAnyDisplacesWithOwnOrder` | A10 | RED | RED-a | `[A10: the outcome carries the displaced siblings ...] Expecting actual: [] to contain exactly [2L]` |
| `transferStockToUnitLoad_shouldNameAllHolders_whenAllowAnyWithNullOrderNumber` | A10 | RED | RED-a | `[A10: with no own order every holder is displaced and named]` |
| `transferStockToUnitLoad_shouldLogRefusal_whenRefusing` | A11 | RED | RED-a | `[A11: support finds refusals by the REPLEN_HELD_REFUSED token]` |
| `OptionalSafetyArchTest` (existing) | A12 | CTRL | green | store line 38 deleted in the scaffold |

### Fix A: rails

| Class | Method | AC | Label | Result | Key failure line |
|---|---|---|---|---|---|
| `ReplenHoldPolicyCallerArchTest` | `policyOverload_shouldBeReachedOnlyByDecidedOptIns_whenScanningProductionCode` | A13 | RAIL | RED-a (as planned) | `expected: {4 decided methods} but was: {}` |
| `ReplenHoldPolicyCallerArchTest` | `policyOverload_shouldHaveAtLeastTheDecidedCallers_whenScanningProductionCode` | A13 | RAIL (non-vacuity) | RED-a | `Expecting actual: 0L to be greater than or equal to: 4L` |
| `StockunitBusinessServiceReplenLockFenceArchTest` | `sbs_shouldNotReferenceReplenishorderRepositoryMethods_whenScanningProductionCode` | A14 | RAIL | green (vacuous until the guard exists) | — |
| `StockunitBusinessServiceReplenLockFenceArchTest` | `sbs_shouldCallOnlyNonLockingReplenFinders_whenScanningProductionCode` | A14 | RAIL | green (vacuous until the guard exists) | — |
| `StockunitBusinessServiceReplenLockFenceArchTest` | `detector_shouldSeeAKnownMethodReference_whenScanningSbs` | A14 | positive control | green | — |
| `NoBareTransferNeverRailTest` | `bareTransferNevers_shouldBeAbsent_whenOutsideTransferVerifications` | A20 | RAIL | green | — |
| `NoBareTransferNeverRailTest` | `detector_shouldFindTheHelpersOwnNevers_whenScanningTransferVerifications` | A20 | positive control (≥3) | green | — |
| `NoBareTransferNeverRailTest` | `detector_shouldFlagEachPlantedShape_whenGivenLiteralOffenders` | A20 | planted offenders (two-line, `never ()`, `times(0)`, `.description(...)`, `Mockito.never()`) | green | — |
| `NoBareTransferNeverRailTest` | `detector_shouldIgnoreNeverOnOtherMethods_whenGivenANeighbouringVerify` | A20 | negative control | green | — |
| `NoBareTransferNeverRailTest` | `helperCallSitesMeetTheFloor` | A20 | floor ≥19 | green (19 sites) | — |
| `MobileReplenishServiceUnitTest$Sbdev2854NonFlowbinDestination` | `finish_rejectsDestinationScopedToAnotherClient` (existing, now `verifyNoTransfer`) | A20 | CTRL | green | — |
| `TransferVerificationsUnitTest` | 12 (null-slot ×3 overloads ×3 helpers, plus 3 pass cases) | H1 self-test | — | green | — |

### Fix A: opt-ins

| Class | Method | AC | Label | Result | Key failure line |
|---|---|---|---|---|---|
| `MobileReplenishServiceUnitTest$FinishReplenishmentOrder` | `finishReplenishmentOrder_shouldCallPolicyOverloadWithAllowAnyAndOwnNumber_whenFinishing` | A15 | RED | RED-a | `Argument(s) are different! Wanted: transferStockToUnitLoad(..., "REPLENISHMENT", "RO-3755", ..., <any>, ALLOW_ANY)` |
| `PickingorderBusinessServiceUnitTest$Sbdev3755ConfirmPickOptIn` | `confirmPick_shouldCallPolicyOverloadWithAllowAny_whenMovingPickedStock` | A16 | RED | RED-a | `Argument(s) are different! Wanted: ... "PICKING", "PP-001", ..., ALLOW_ANY` |
| `PickingorderBusinessServiceUnitTest$Sbdev3755ConfirmPickOptIn` | `confirmPick_shouldRequestHealForDisplacedHolders_whenTransferDisplacedOne` | A16 | RED | RED-a | `Wanted but not invoked: replenishmentMaintenanceTrigger.requestIfDisplaced(same(TransferOutcome[...REPL-77@300]), 5L)` |
| `StockunitServiceUnitTest$TransferStockSourceLockGuard` | `transferStock_shouldCallPolicyOverloadWithAllowAny_whenMovingToDamaged` | A17 | RED | RED-a | `Argument(s) are different! Wanted: ... "DAMAGED", ..., ALLOW_ANY` |
| `StockunitServiceUnitTest$TransferStockSourceLockGuard` | `transferStock_shouldRequestHealForDisplacedHolders_whenDamageDisplacedOne` | A17 | RED | RED-a | `Wanted but not invoked: replenishmentMaintenanceTrigger.requestIfDisplaced(same(...), 1L)` |
| `StockunitServiceUnitTest$TransferStockSourceLockGuard` | `transferStock_shouldStayOnRefusingOverload_whenMovingToNewContainerElsewhere` | A17 (#11) | CTRL | green | — |
| `UnitloadServiceUnitTest$MoveStockToNewDamagedContainerBoundary` | `moveStockToNewDamagedContainer_shouldCallPolicyOverloadWithAllowAny_whenMovingDamagedStock` | A18 | RED | RED-a | `Argument(s) are different! Wanted: ... "DAMAGED", isNull(), "broken pallet", false, true, <any>, ALLOW_ANY` |
| `UnitloadServiceUnitTest$MoveStockToNewDamagedContainerBoundary` | `unitloadService_shouldNotDependOnTheTrigger_whenConstructed` | A18 | RAIL | green | — |
| `StockunitServiceUnitTest$SetLockDamagedExtended` | `transfersEntireUnitloadWhenAmountEqualsTotal` (existing; `recalculateForItem times(1)`) | A18 (setLockDamaged half) | RAIL | green | — |
| `ReplenishmentMaintenanceTriggerUnitTest` | `requestIfDisplaced_shouldRequestMaintenanceOnce_whenOutcomeHasDisplacedHolders` | A19 | RED | RED-a | `Wanted but not invoked: recalculateForItem(55L); zero interactions` |
| `ReplenishmentMaintenanceTriggerUnitTest` | `requestIfDisplaced_shouldRequestNothing_whenOutcomeHasNoDisplacedHolders` | A19 | CTRL | green | — |

### Fix B

| Class | Method | AC | Label | Result | Key failure line |
|---|---|---|---|---|---|
| `ReplenishmentOrderSourceSyncServiceTest$MultiHolder` | `syncForMovedStockUnit_shouldLockAscendingAndRepointBoth_whenTwoProcessableHolders` | B1 | RED | RED-a | `[B1: every holder ... is re-pointed onto the destination, not just one]` |
| `…$MultiHolder` | `syncForMovedStockUnit_shouldKeepBindingAndAmounts_whenRepointingTwoHolders` | B1 | RED | RED-a | `[B1: REPL-9 was re-pointed] expected: 900L but was: 100L` |
| `…$MultiHolder` | `syncForMovedStockUnit_shouldNotLoadEntityBeforeLock_whenTwoHolders` | B1 | RED | RED-a | `Wanted but not invoked: findHoldersByStateLessThanAndStockunitIdOrderById(700, 42L)` |
| `…$MultiHolder` | `syncForMovedStockUnit_shouldRefuseBeforeAnyLock_whenProjectedHolderStarted` | B2 | RED | RED-a | `[B2: an in-progress holder blocks the move ...] Expecting actual not to be null` |
| `…$MultiHolder` | `syncForMovedStockUnit_shouldSkipHolder_whenItFinishedAfterProjection` | B3 | RED | RED-a | `[B3: REPL-5 is still a holder and is re-pointed] expected: 900L but was: 100L` |
| `…$MultiHolder` | `syncForMovedStockUnit_shouldSkipHolder_whenItWasRedirectedAfterProjection` | B3 | RED | RED-a | same |
| `…$MultiHolder` | `syncForMovedStockUnit_shouldRefuseWithoutRepointing_whenHolderStartedUnderLock` | B3 | RED | RED-a | `[B3: re-checked under lock, REPL-9 is now in progress ...]` |
| `ReplenishmentOrderMaintenanceServiceReassignTest` | `reassignOrCancelForMovedStockUnit_shouldCancelEveryHolder_whenTwoHoldersAndNoCandidate` | B4 | RED | RED-a | `[B4: every holder ... is acted on] Expecting [300, 300] to contain exactly [800, 800]` |
| same | `reassignOrCancelForMovedStockUnit_shouldLockOrdersThenStockUnitThenAct_whenTwoHolders` | B4 | RED | RED-a | `Wanted but not invoked: findByIdForUpdate(5L)` |
| same | `reassignOrCancelForMovedStockUnit_shouldLockStockUnitOnce_whenTwoHolders` | B4 | RED | RED-a | `Wanted but not invoked: findByIdForUpdate(9L)` |
| `ReplenishMultiHolderMoveIT` | `locationMove_twoProcessableHolders_repointsBoth` | B5 | RED | RED-a | `[B5: ...] expected: null but was: IncorrectResultSizeDataAccessException: Query did not return a unique result: 2 results` (type confirmed) |
| same | `laneMove_twoHolders_noCandidate_cancelsBoth` | B6 | RED | RED-a | `[B6: the move itself must succeed] ... IncorrectResultSizeDataAccessException` |
| same | `laneMove_twoHolders_bothRedirected_releaseOwnShares` | B7 | RED | RED-a | `[B7: the move itself must succeed] ... IncorrectResultSizeDataAccessException` |
| same | `moveAndAttributedCut_sameTwoHolderSu_noDeadlock` | B8 | PROBE | RED-a (control) | `[B8 positive control: the move must have WAITED on a lock leg A holds within 10 s ...; move outcome = IncorrectResultSizeDataAccessException]` |
| `ReplenishmentIdProjectionContractUnitTest` | `replenishorderRepository_shouldNotDeclareSingleRowIdProbe_whenMultiHolderIsLegal` | B9 | RED | RED-a | `[B9: findIdByStateLessThanAndStockunitId is an Optional single-row probe ...]` |
| same | `replenishorderRepository_shouldReturnListFromHoldersFinder_whenDeclared` | B9 | pin | green | — |
| `FindByStateLessThanAndStockunitIdNoMainCallerArchTest` | `findByStateLessThanAndStockunitId_shouldHaveNoMainAccess_whenScanningProductionCode` | B10 | RAIL | green | — |
| same | `detector_shouldSeeTheHoldersProjectionAccess_whenScanningProductionCode` | B10 | positive control | green | — |

### Fix C

| Class | Method | AC | Label | Result | Key failure line |
|---|---|---|---|---|---|
| `SdrUncalledSurfaceNotExportedContextTest` | `callerlessSearchesOnExportedTypesAreWithdrawnIndividually` (new `Withdrawn` entry) | C1 | RED | RED-a | `[a search with no HTTP caller is routed and unguarded. Withdraw it with @RestResource(exported = false) ...]` |

### End to end (`TransferStockReplenHoldGuardIT`)

| Method | AC | Label | Result | Key failure line |
|---|---|---|---|---|
| `transferStock_shouldRefuseNamingOrder_whenWholeHeldStockUnitMovesToNewContainer` | E1a | RED | RED-a | `[E1a: the whole of X re-parents into a new container and strands RO-3755-E1 ...] Expecting actual not to be null` |
| `transferStock_shouldLeaveNoTrace_whenWholeHeldStockUnitMoveIsRefused` | E1a | RED | RED-a | `[E1a: the move must be refused]` |
| `transferStock_shouldSplitAndLeaveReplen_whenHalfOfHeldStockUnitMoves` | E1b | CTRL | green | — |
| `fulfillMultipleUnitLoads_shouldFinishOrder_whenItMovesItsOwnHeldStockUnit` | E1c | CTRL | green | — |
| `transferStock_shouldMoveContainerAndRepoint_whenHeldStockUnitIsAloneOnItsUnitLoad` | E1d | CTRL | green | — |

## B8 probe

- **Contention not observed on the scaffold, by design.** The move threw `IncorrectResultSizeDataAccessException` before it took any order lock, so the 10 s `pg_stat_activity` control (`wait_event_type = 'Lock'` and leg A's pid in `pg_blocking_pids`) failed. Leg A then ran the real `adjustReservedAmount` and completed (`outcomeA=null`).
- **Not yet shown:** that the control fires under a correct Fix B. That needs the implementation, and it must be confirmed at step 3 before B8 counts as a passing probe.
- **Design note:** the move targets a replenishable location (the re-point path). B never locks the SU there, so A's SU lock cannot meet B anywhere except the order locks.
- B8 is not tagged `timing-sensitive`.

## Unexpected passes

- None among the RED rows.
- The three green non-CTRL rows are green by construction, not by accident:
  - the A14 rules are vacuously green while SBS has no replen access;
  - the B9 "returns a List" pin passes because the finder already returns a List;
  - the A19 empty-list row passes because the scaffold no-op requests nothing.
- Each green row has its named mutant still to run in §8.2.

## Deviations and setup adjustments

1. **H1 helper variants.** I added `verifyNoTransferFrom(sbs, source)` and `verifyNoTransferTo(sbs, destination)` next to `verifyNoTransfer(sbs)`, each covering all three overloads.
   - Two of the 19 sites legitimately transfer other stock, so a blanket `verifyNoTransfer` would have failed against correct code: `BillofladingServiceUnitTest:3366` uses `eq(suForeign)`, and `MobileReplenishServiceUnitTest:3453` uses `eq(sameSku)`.
   - The A20 floor regex counts all three names, and it excludes the helper and its self-test.
2. **NeverMatcher inventory.** Moving the 19 sites shifted the per-class `anyBoolean()` counts by 2 per site.
   - Two entries were removed (ClubLine, TransferStockDestination).
   - `TransferVerifications:18` was added (3 helpers × 3 overloads × 2).
   - Signatures were read: params 7–8 are primitive `boolean`.
3. **Shared lexer.** `NeverMatcherNullBlindnessArchTest.stripComments` and `spanEnd` went from `private` to package-private so A20 can reuse the lexer (Cr N1). This is test-only.
4. **NOT_SUPPORTED declarations.** `TestClassTransactionManagerArchTest.EXEMPT_NON_TRANSACTIONAL` gains both new ITs, with a reason. Its `nonTransactionalPropagationsMustBeDeclared` rule requires the declaration.
5. **B1 field check.** "reservedamount unchanged" is asserted as `stockunitId` + `requestedamount` unchanged. `Replenishorder` has no `reservedamount` column, and the sync service has no SU dependency.
6. **A6 ALLOW_ANY and A8 all-gone gained a non-vacuity verify** (holders read; `findById(9)` then `(5)` in order). Without it they would be green on the scaffold.
7. **A13** is two tests: the equality check and the ≥4 floor.
   - **A18's `setLockDamaged → requestForItem times(1)` half** is already pinned by `StockunitServiceUnitTest$SetLockDamagedExtended#transfersEntireUnitloadWhenAmountEqualsTotal`, so no new test was added.
   - **A12** is the existing `OptionalSafetyArchTest`.
8. **E1c** enters the finish through the public `MobileReplenishService.fulfillMultipleUnitLoads`. That is the public entry to the private `finishReplenishmentOrderWithoutRefill` (#15).
9. **Opt-in tests stub both transfer overloads leniently.** The scaffold calls the 8-arg overload and the implementation will call the policy overload. A18 uses its own lenient `arrangeHelperCallForEitherOverload`, so it does not depend on the step-5 migration of `arrangeHelperCall`. Existing caller stubs were not migrated (that is step 5).
10. **New test fixture** `common/fixtures/ReplenishorderHolderViews.holder(id, state, number)`, a hand-built projection row whose `toString` is `NUMBER@state`.
11. **Fixture fix in my own IT.** The holders' `stockunit_id` FK needs the SU seeded first. The first B run errored on `DataIntegrityViolationException`; the fix was to seed the SU before the orders and have each test UPDATE the amount.
12. **IT ids** are in the band 37550–37589. `git grep "375NNL"` over `src/test` was empty.

## Not done here (by plan)

- Caller stub/verify migration to the policy overload (step 5).
- Mutation checks of CTRL/RAIL rows (§8.2).
- Scoped PIT.
- `-Pci` full verify.
- The review lane.
- Nothing pushed.
