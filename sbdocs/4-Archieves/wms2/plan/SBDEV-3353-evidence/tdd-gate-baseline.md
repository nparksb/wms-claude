# SBDEV-3353 — TDD gate baseline (failing tests, pre-implementation)

- Worktree: `.claude/worktrees/wms2-api/SBDEV-3353`, branch `bugfix/SBDEV-3353-refuse-move-stock-out-of-parcel` @ `978b3a14` (origin/develop)
- Date: 2026-09-24. No concurrent Maven (`pgrep -fl "surefire|failsafe"` empty before each run)
- **No `src/main` file touched.** `git status`: 6 modified test files and 1 new test file. Nothing committed.
- Refusal key asserted as the **string literal** `"transferStockSourceIsParcel"`, via `getKey()`. `WmsConstants.MSG_TRANSFER_SOURCE_IS_PARCEL` does not exist yet. The fix must define it equal to this literal.

## Command

```bash
mvn -ntp test -Dtest='StockunitServiceParcelSourceRefusalUnitTest,CancellationReversalServiceUnitTest,MobileTransferOrderServiceUnitTest,MobileMoveUnitloadServiceUnitTest,UnitloadServiceUnitTest,StockunitBusinessServiceFullMoveInvariantUnitTest,NeverMatcherNullBlindnessArchTest,StockunitServiceToteContainerRelocationUnitTest' -Dsurefire.failIfNoSpecifiedTests=false
```

Lane total: **Tests run: 241, Failures: 17, Errors: 0, Skipped: 0**. All 17 failures are intended red tests, and every one fails at an assertion. There are 0 errors, 0 compile failures and 0 setup NPEs. `target/surefire-reports` was wiped before the run, so no stale XML is counted.

## Per-class results (surefire `.txt`, line 4)

@Nested outer classes report `Tests run: 0`. Their tests are counted under the nested report files listed below.

| Report | Tests run | Failures | Note |
|---|---|---|---|
| `StockunitServiceParcelSourceRefusalUnitTest` (new) | 26 | 10 | 10 refusals red; 16 controls green |
| `CancellationReversalServiceUnitTest` | 27 | 0 | +1 new pin (green by design, see below) |
| `MobileTransferOrderServiceUnitTest$Sbdev3353ParcelSource` (new nest) | 5 | 4 | 4 refusals red; 1 control green |
| `MobileTransferOrderServiceUnitTest$TransferStock` (+ 5 other nests) | 10 (+18) | 0 | pre-existing, green |
| `MobileMoveUnitloadServiceUnitTest$Sbdev3353ParcelSourceStockMove` (new nest) | 4 | 2 | 2 refusals red; 2 controls green |
| `MobileMoveUnitloadServiceUnitTest` other nests (incl. `$Sbdev3452MoveTruckBoundary` 16) | 51 | 0 | pre-existing, green |
| `UnitloadServiceUnitTest$RestsInStorageLocation` | 9 | 1 | new Package→false test red |
| `UnitloadServiceUnitTest` other nests | 76 | 0 | pre-existing, green |
| `StockunitBusinessServiceFullMoveInvariantUnitTest` | 3 | 0 | +1 packaging pin (green by design) |
| `StockunitServiceToteContainerRelocationUnitTest` | 8 | 0 | SBDEV-3340 sibling, untouched, green |
| `NeverMatcherNullBlindnessArchTest` | 4 | 0 | inventory updated (see "Rail edit") |

## Tests written

### Refusal tests: must be red now and green after the fix

| Class | Method | Case (architect-consult #) |
|---|---|---|
| StockunitServiceParcelSourceRefusalUnitTest | `transferStock_shouldRefuse_whenFullAmountOfParcelStockMovesToARack` | #1: full amount, single SU, rack; whole-UL arm (taxonomy=true, develop's answer) |
| 〃 | `transferStock_shouldRefuse_whenFullAmountOfParcelStockTakesTheSplitArm` | #1 / H3: full amount after the set change (taxonomy=false, split arm drains the parcel) |
| 〃 | `transferStock_shouldRefuse_whenPartialAmountOfParcelStockMovesToARack` | #2: partial amount |
| 〃 | `transferStock_shouldRefuse_whenLock100ParcelStockMovesToDamaged` | #3 **H1 LIVE**: Damaged, lock 100, arm `CODE_DAMAGED, null, comment, true, true` |
| 〃 | `transferStock_shouldRefuse_whenQualityFaultParcelStockMovesWithinDamaged` | #4: QF arm, lock 103, source already at Damaged |
| 〃 | `transferStock_shouldRefuse_whenParcelStockMovesIntoAnExistingContainer` | #5: existing non-pallet container |
| 〃 | `transferStock_shouldRefuse_whenParcelStockMovesOntoAnExistingPallet` | #5: existing pallet (mint-and-carry) |
| 〃 | `transferStock_shouldRefuse_whenParcelStockMovesToAFlowBin` | #6: FLA flow bin |
| 〃 | `transferStock_shouldRefuse_whenShippedParcelStockMovesToDamaged` | #7: lock 405 on the damaged arm (type-only, no shipped test) |
| 〃 | `completeReversal_shouldRefuse_whenThePickToStockSitsInAParcel` | #8: RTS. A **real** `CancellationReversalService` drives the **real** `StockunitService.transferStock` on lock-100 Package stock |
| MobileTransferOrderServiceUnitTest$Sbdev3353ParcelSource | `transferStock_shouldRefuse_whenAFixedAssignedParcelWouldBeRelocatedWhole` | #9: FLA whole-container arm |
| 〃 | `transferStock_shouldRefuse_whenTheWholeParcelStockWouldBeSplitOut` | #9: whole stock, no FLA (split) |
| 〃 | `transferStock_shouldRefuse_whenTheAvailablePartOfParcelStockWouldBeSplitOut` | #9: reserved>0 split |
| 〃 | `transferStock_shouldRefuse_whenPartOfTheParcelStockWouldBeSplitOut` | #9: partial split |
| MobileMoveUnitloadServiceUnitTest$Sbdev3353ParcelSourceStockMove | `scanDestination_shouldRefuse_whenMoveStockDrainsAParcel` | #10: `isMoveStock` → private `transferStock`, lock 0 (H2) |
| 〃 | `scanDestination_shouldRefuse_whenAParcelIsDrainedIntoAFixedAssignedUnitLoad` | #10: FLA-backed destination UL arm |
| UnitloadServiceUnitTest$RestsInStorageLocation | `restsInStorageLocation_shouldBeFalse_whenTheContainerIsAPackage` | #12: set change |

Every StockunitService / mobile refusal asserts both of these:
- `getKey()` equals `"transferStockSourceIsParcel"`
- `never()` on the mutating collaborators:
  - StockunitService: `transferStockToUnitLoad`, `transferUnitLoadToLocation`, `transferUnitLoadToCarrier`, `createUnitload`, `createFixedLocationAssignment`, `messageService.sendStockChangeMessage`, `stockunitRepository.save`
  - mobile transfer: `transferStockToUnitLoad`, `transferUnitLoadToLocation`, `createUnitload`
  - mobile move-UL: `transferStockToUnitLoad`, `sendToClearing`, `sendToNirvana`

The RTS case asserts:
- `reversal_completed_at` stays null
- `logRepository.save` is never called
- `outboxService.enqueue` is never called
- no `transferUnitLoadToLocation` / `transferStockToUnitLoad` call

### Controls: green now and must stay green

| Class | Method | What it pins |
|---|---|---|
| StockunitServiceParcelSourceRefusalUnitTest | `transferStock_shouldProceed_whenNonParcelStockMovesPartiallyToARack` ×3 (Case/Default/PickLocation) | partial split arm |
| 〃 | `transferStock_shouldProceed_whenNonParcelStockMovesToDamaged` ×3 | lock-100 CODE_DAMAGED arm (+ OMS stock-change message) |
| 〃 | `transferStock_shouldProceed_whenNonParcelStockMovesIntoAnExistingContainer` ×3 | existing-container arm |
| 〃 | `transferStock_shouldRelocateTheContainer_whenAWholeCaseMovesToARack` | whole-UL arm still relocates for a Case |
| 〃 | `transferStock_shouldCarryOntoThePallet_whenTheSourceIsACase` | arm-reach control for #5b |
| 〃 | `transferStock_shouldMoveIntoTheFlowBin_whenTheSourceIsACase` | arm-reach control for #6 |
| 〃 | `transferStock_shouldMoveOnTheQualityFaultArm_whenTheSourceIsACase` | arm-reach control for #4 |
| 〃 | `transferStock_shouldProceed_whenTheSourceContainerHasNoType` | fail-closed: typeId null |
| 〃 | `transferStock_shouldProceed_whenTheSourceContainerTypeRowIsMissing` | fail-closed: type row missing (id 99) |
| 〃 | `transferStock_shouldProceed_whenTheSourceUnitLoadIsUnresolvable` | fail-closed: source UL `findById` empty (existing-container arm, the only arm that doesn't itself need the source UL) |
| MobileTransferOrderServiceUnitTest$Sbdev3353ParcelSource | `transferStock_shouldProceed_whenTheSourceContainerIsACase` | partial arm, Case source |
| MobileMoveUnitloadServiceUnitTest$Sbdev3353ParcelSourceStockMove | `scanDestination_shouldMoveTheStock_whenTheSourceIsACase` | Case source → transfer + sendToNirvana |
| 〃 | `scanDestination_shouldMoveTheStock_whenTheSourceIsADefaultContainer` | **Default is Package's `// waterfall` neighbour into sendToClearing.** This kills a guard keyed on the switch arm instead of the name |
| CancellationReversalServiceUnitTest | `completeReversal_shouldPropagateTheParcelRefusal_whenTransferStockRefusesAParcelSource` | with the refusal stubbed on the mocked `stockunitService`: the key propagates un-rewrapped, the log stays pending, no save, no outbox. A pin, not a red test (see below) |
| StockunitBusinessServiceFullMoveInvariantUnitTest | `transferStockToUnitLoad_shouldStillMoveStock_whenBothContainersArePackages` | #11 packing control: real `transferStockToUnitLoad`, Package→Package, lock 100, `CODE_PACKAGING`, ignoreLock=true still re-homes the SU. It goes red if the guard is misplaced into `transferStockToUnitLoad` |

Existing UnitloadServiceUnitTest controls already cover Box/Default/PickLocation → true (`shouldBeTrue_forCase`, `shouldBeTrue_forTheRemainingStorableTypes`), so I added no duplicates.

The arm-reach controls exist for a reason. A refusal that reads "nothing was thrown" proves the fixture ran to completion, but it doesn't prove which arm ran. Each refusal fixture is therefore paired with a Case-typed control on the **same fixture**, and that control verifies the arm's own move call.

## Failure excerpts (assertion messages)

Every StockunitService refusal (10) fails like this:
```
a stock move out of a Package (parcel) must be refused with key 'transferStockSourceIsParcel' — no SBDEV-3353 refusal was raised ==> Expected net.aim_ai.wms.exceptions.BusinessException to be thrown, but nothing was thrown.
```
The RTS case fails the same way, at `completeReversal_shouldRefuse_whenThePickToStockSitsInAParcel:593->assertRefusedAsParcel:382`. On develop, the reversal clears lock 100 and moves the parcel's stock into the rack without any error.

Mobile transfer order (4):
```
[a transfer-order move out of a Package must be refused with key 'transferStockSourceIsParcel' — no SBDEV-3353 refusal was raised]
Expecting actual not to be null
```
Mobile move-UL (2):
```
[a Move Unit Load stock move out of a Package must be refused with key 'transferStockSourceIsParcel' — no SBDEV-3353 refusal was raised]
Expecting actual not to be null
```
Set change (1):
```
[a parcel is outbound packaging, not a storage container — relocating it into a rack bin with the goods inside is the same defect SBDEV-3340 fixed for the tote]
Expecting value to be false but was true
```

No refusal test passed unexpectedly.

## Existing tests that must FLIP with the fix (not edited)

1. **`UnitloadServiceUnitTest$RestsInStorageLocation.shouldBeTrue_forPackage`** (`:2049-2069`) asserts `restsInStorageLocation(Package) == true`, and SBDEV-3340 pinned it deliberately. It directly contradicts the new `restsInStorageLocation_shouldBeFalse_whenTheContainerIsAPackage`, so the two cannot both pass. The implementer must delete it or invert it, and should rewrite its comment, which argues against the removal on the grounds that Nirvana would be reachable. That argument no longer holds once the guard exists.
2. **Placement-dependent risk, may flip:** `MobileMoveUnitloadServiceUnitTest$Sbdev3452MoveTruckBoundary.shouldNotConsultGuards_whenMoveStockIsSet` (AC-10). It sends a **Package** source with **no stock units** down the `isMoveStock` arm and expects `"has no stocks"`. If the parcel guard sits at the top of the private `transferStock`, or anywhere before the `stockUnits.size() > 0` check, this test flips to the parcel key. The architect's placement is immediately before the `transferStockToUnitLoad` at `:611`, inside the `if`, and that keeps AC-10 green. Prefer that placement over editing AC-10.
3. **Possible STRICT_STUBS fallout (verify during implementation):** the existing `MobileTransferOrderServiceUnitTest$TransferStock` tests leave `unitload.typeId` null and stub `unitloadTypeRepository.findById(20L)`. If the mobile guard calls `unitloadTypeRepository.findById(null)`, Mockito raises `PotentialStubbingProblem` (arg mismatch), not a behaviour failure. Short-circuit on a null typeId before the lookup, which is what fail-closed means anyway.
4. `StockunitServiceToteContainerRelocationUnitTest`: none of its tests asserts Package in the allow-list; `UnitloadService` is mocked there. It stays green as is.

## Rail edit (test tree only)

`NeverMatcherNullBlindnessArchTest.PRIMITIVE_MATCHER_INVENTORY` needed updating. The new `never()` calls use `anyBoolean()` on parameters I checked in the source signatures and confirmed are **primitive**:
- `transferStockToUnitLoad(..., boolean ignoreLock, boolean removeUnitLoadIfEmpty)` (`StockunitBusinessService.java:168`)
- `transferUnitLoadToLocation(..., boolean ignoreLock, ...)` (`UnitloadBusinessService.java:221`)

Bare `any()` would NPE at unboxing on these.

Count changes, each annotated with an SBDEV-3353 comment in the inventory:

| Test class | Before | After |
|---|---|---|
| `MobileMoveUnitloadServiceUnitTest` | 1 | 3 |
| `MobileTransferOrderServiceUnitTest` | 2 | 5 |
| `StockunitServiceParcelSourceRefusalUnitTest` (new) | 0 | 6 |

## Needs an integration test, not a unit test

- **RTS lock-clear rollback (#8, second half).** `completeReversal` runs `stockUnit.setEntityLock(NOT_LOCKED)`, `stockunitRepository.save` and `entityManager.flush()` **before** calling `transferStock`. When the guard throws, only the `@Transactional(rollbackFor = BusinessException)` rollback restores lock 100 in the DB. In a unit test the save is a recorded mock call and the in-memory row stays NOT_LOCKED whether or not a rollback happens, so no unit assertion can grade it. It needs an IT in the shape of `CancellationReversalLockClearIntegrationTest`: seed a lock-100 SU in a Package plus a pending log, call `completeReversal`, expect the keyed refusal, then **re-read in a new transaction** and assert `entity_lock=100`, `reversal_completed_at IS NULL`, and 0 `outbox_message` rows for the order.
- **Web controller mapping of the key to the rendered message** (a 422 with the `messages_en_US.properties` text). The controller test lane covers this, not these service tests. The message needs a positional `%1$s`, not a bare `%s`.
- **#13 mutation checks** can only run once the guard exists. Delete the guard call and all 17 red tests go red again. Flip `equals` to `!equals` and the Case/Default/PickLocation and fail-closed controls go red. Re-add Package to the set and `restsInStorageLocation_shouldBeFalse_whenTheContainerIsAPackage` goes red. Remove the null-typeId short-circuit and the fail-closed controls should catch it. If they don't, note that in the implementation evidence.

## Packing / BOL control (#11)

- **New:** `StockunitBusinessServiceFullMoveInvariantUnitTest.transferStockToUnitLoad_shouldStillMoveStock_whenBothContainersArePackages`, described above. No existing test ran the **real** `transferStockToUnitLoad` with a Package container. `git grep` found no Package-typed fixture in any `StockunitBusinessService*` test.
- **Existing, mocked-collaborator only.** These prove that packing and BOL call `StockunitBusinessService.transferStockToUnitLoad` directly and never route through `StockunitService.transferStock`. They do not prove the guard is absent from `transferStockToUnitLoad`:
  - `CustomerorderServiceUnitTest$PackageOrderSuccessPaths.shouldPackageOrderWithTotesOnCart` / `shouldPackageOrderWithRapidPicking` (`packageOrder` → `CustomerorderService.java:646`)
  - `BillofladingServiceUnitTest.transferOrder_toggleOff_exactMatch_sweepsAllUnitLoads` (verifies `transferStockToUnitLoad(eq(suA), eq(parcel), …)`, `BillofladingService.java:1075/1094`)

## Not covered, by design

- `MobileMoveUnitloadService.handleTruckOffLoading`: out of scope per the decision, and an open question for Nam.
- `scanDestination`'s whole-container `transferUnitLoadToLocation` (`:376`): relocates the parcel without draining it. That is a sibling concern.
- The mobile "No stock required" early return in `MobileTransferOrderService.transferStock` moves nothing. With the guard at the top it will also be refused for a Package source, which is harmless. No test pins either way.
