# SBDEV-3353 — P1 review fix pass

- Worktree `.claude/worktrees/wms2-api/SBDEV-3353`, branch `bugfix/SBDEV-3353-refuse-move-stock-out-of-parcel`, base HEAD `3bcb4a69`. Date 2026-09-24.
- Inputs: `p1-code-review.md` (H1, M1, L1–L10, Q1, Q2) and `p1-security-review.md` (L1, L2, S1–S3), plus Nam's decisions of 2026-09-24 (Q1: guard it; Q2: separate ticket [868m9914u](https://app.clickup.com/t/868m9914u); handleTruckOffLoading stays unguarded).
- Commit: `69de9e8e` — `SBDEV-3353: review fixes — guard Transfer to Damaged and putaway flow-bin drain, RTS pre-validate refusal` (on top of `3bcb4a69`). **Not pushed.**
- No finding disputes Nam's design. One observation for Nam is at the end (hub-and-spoke parcels), and it does not change anything here.

## Finding → fix → proving test

| Finding | Fixed? How (file + snippet) | Proving test(s) |
|---|---|---|
| **H1** = security **S1**: web Transfer to Damaged drains an unlocked parcel | Fixed. `StockunitService.setLockDamaged:769`, first statement after the clamp and log, before the lock switch: `SourceContainerGuard.assertStockNotInParcel(stockunitRepository.findById(stockUnit.getId()).orElse(stockUnit), unitloadRepository, unitloadTypeRepository);`. This covers `/transferToDamaged` and `/bulkTransferToDamaged`. | `StockunitServiceParcelSourceRefusalUnitTest.setLockDamaged_shouldRefuse_whenTheStockSitsInAParcel`: asserts the key, then `never()` on `mintUnitloadLabel`, `moveStockToNewDamagedContainer`, `sendStockChangeMessage` and `recalculateForItem`. Same-arm control `setLockDamaged_shouldMoveTheStock_whenTheSourceIsNotAParcel` ×3 (Case / Default / PickLocation). |
| H1: the other caller, `ReturnAdviceAutoReceiveService`, is unaffected | Cited reason, plus a test. `applyDamage` damages the stock unit that `receiveGoods` has just created. `ReceivingService` takes its unit-load type from `adviceposition.unitloadtype_id`, and `AdviceRestController.create` (`:411`, `:431`) sets that to `UNIT_LOAD_TYPE_BOX` ("Case"), so it is never a Package. The reason is written in the call-site comment. | The Case row of the control above is that caller's exact shape. `ReturnAdviceAutoReceiveServiceUnitTest` is still 84/84. |
| **Q1** = security **S2** (putaway): Nam said guard it | Fixed on the **draining arm only**. `MobilePutAwayService.storeBoxOnLocation:552`, at the top of the `FLOWBIN` case and before `createFixedLocationAssignment` writes: `SourceContainerGuard.assertNotParcel(unitLoad, unitloadTypeRepository);`. The other arms (overstock, stock-restriction, staging lane) call `transferUnitLoadToLocation`, which relocates the box **whole** and does not drain it. That is the separate ticket 868m9914u, so they are not refused, and the comment cites that ticket. | `MobilePutAwayServiceUnitTest$Sbdev3353ParcelSourcePutaway`: refusal `storeBoxOnLocation_shouldRefuse_whenAParcelWouldBeDrainedIntoAFlowBin` (key, never FLA, never transfer, never Nirvana). Case control `…_shouldDrainIntoTheFlowBin_whenTheBoxIsACase`. Scope pin `…_shouldStillRelocateAParcelWhole_whenTheArmDoesNotDrainIt`. |
| **Q2**: whole-parcel relocation | Not fixed, by decision (ticket 868m9914u). Every comment or javadoc I touched that mentions it now cites 868m9914u as its carrier (`UnitloadService` set javadoc, `MobilePutAwayService:551`, `MobileMoveUnitloadServiceUnitTest` nested javadoc). `git grep -i "out of scope"` finds no remaining parcel-related text. | Pinned by the putaway scope test above. |
| **M1**: "unreachable" over-claim | Fixed. The `UnitloadService` `TYPES_THAT_REST_IN_A_STORAGE_LOCATION` javadoc now lists the six guarded call sites. It names what stays open: whole-parcel relocation (868m9914u), `handleTruckOffLoading` (deliberately unguarded, per Nam), and `adjustAmount` (not a move). It describes the set as the **backstop** for the guard's fail-closed and bypass cases, not as a second active control. The test `@DisplayName` now reads "…a parcel is not a storage container; the source guard keeps the split arm from draining it", and its comment is narrowed to the predicate's one caller. | Wording only. `UnitloadServiceUnitTest` is 84/84. |
| **L1** (both reviews): guard reads a detached snapshot | Fixed, but it narrows the window rather than closing it. `StockunitService.transferStock:337`, `setLockDamaged:769` and `MobileTransferOrderService.transferStock:392` now judge `stockunitRepository.findById(id).orElse(stockUnit)`, a plain `findById` and **not** `findByIdForUpdate`, because of the SBDEV-3341 F1 lock-order reason. `setLockDamaged` and the mobile method are not `@Transactional`, so their re-read is a later read rather than an in-transaction one, and their comments say so. RTS needs no re-read: its `sourceStockunit` is loaded in-transaction. The `SourceContainerGuard` class javadoc records that closing the window needs a lock-order change and that the gap is **accepted as residual** (security L1). | `…ParcelSourceRefusalUnitTest.transferStock_shouldRefuse_whenTheReReadRowIsInAParcelButTheSnapshotIsNot`, `setLockDamaged_shouldRefuse_whenTheReReadRowIsInAParcelButTheSnapshotIsNot`, and `MobileTransferOrderServiceUnitTest$Sbdev3353ParcelSource.transferStock_shouldRefuse_whenTheReReadRowIsInAParcelButTheSnapshotIsNot`. In each, the snapshot names a Case and the re-read row is in the parcel. |
| **L2** (code): three `lenient()` fixtures went through the fail-closed branch | Fixed, and `lenient()` is dropped from all three stubs. `StockunitServiceToteContainerRelocationUnitTest` adds a strict `findById(TOTE_TYPE_ID)` returning a real Tote. `StockunitServiceTransferStockDestinationTest` and `StockunitServiceUnitTest$TransferStockToFlowbin` each add a strict source unit load of type Case plus the Case type row. STRICT_STUBS stays armed, and the guard answers "not a parcel" on a real type. | Those three classes are green: 8, 16 and 90. |
| **Security L2**: fail-open branches were silent | Fixed. `SourceContainerGuard` now has an SLF4J `LOG.warn` on each of the 5 proceed branches: no unit load id, unit load not found, null unit load, null type id, type row missing. Messages are parameterized and carry ids only, e.g. `"SBDEV-3353 parcel guard: type {} of unit load {} not found; proceeding unguarded"`. The type test was restructured to `findById(typeId).orElse(null)` so that a missing row is its own branch. | New `unit/util/SourceContainerGuardUnitTest` (11 tests). A ListAppender asserts exactly one WARN, with the ids, on each branch, and asserts no WARN on the refuse and the Case paths. |
| **L3**: ArchTest ratchet comment named a site that does not exist | Fixed. The `MobileMoveUnitloadServiceUnitTest:3` entry now names only `transferStockToUnitLoad`. The new `MobilePutAwayServiceUnitTest` entry went 7 → 11 (two new `never().transferStockToUnitLoad`, params 7–8 primitive `boolean`, signature read at `StockunitBusinessService:168`), with a comment. | `NeverMatcherNullBlindnessArchTest` 4/4. |
| **L4**: stale "/ Package" in a test comment | Fixed. `StockunitServiceUnitTest` now reads "(Case / PickLocation / Default — not a Tote, and since SBDEV-3353 not a Package)". | n/a (comment) |
| **L5**: mobile guard pre-empted outcomes that move nothing | Fixed per the recommendation. The guard in `MobileTransferOrderService.transferStock` moved below the two transfer-lane checks and the "No stock required" return, to just above `int amountLeft`. Every arm that writes is still below it. | `…$Sbdev3353ParcelSource.transferStock_shouldAnswerNoStockRequired_whenTheSourceIsAParcelAndNothingIsNeeded` and `transferStock_shouldNameTheLane_whenTheSourceIsAParcelScannedAtTheWrongLane`. All previous gate tests are still green (39/39). |
| **L6**: an empty label rendered as "Container  is" | Fixed. `SourceContainerGuard:114`: `label == null \|\| label.isBlank() ? String.valueOf(sourceUnitload.getId()) : label`. | `SourceContainerGuardUnitTest.assertNotParcel_shouldNameTheParcelById_whenTheLabelIsBlank` ("", " ", "\t"), and `…ParcelSourceRefusalUnitTest.refusal_shouldNameTheParcelById_whenItsLabelIsBlank` ("", "   "). |
| **L7**: mobile refusals had no same-arm control | Fixed. `MobileTransferOrderServiceUnitTest` adds Case controls on the FLA-whole arm (asserts `transferUnitLoadToLocation`), the whole-stock split and the reserved split (the partial arm already had one). `MobileMoveUnitloadServiceUnitTest` adds a Case control on the FLA-backed destination-unit-load arm, plus a **new refusal and Case control on the flow-bin LOCATION arm**, which was not exercised before. | 6 new tests, named in the "L7" and "[pin]" display names. MobileMove 64/64, MobileTransferOrder 39/39. |
| **L8**: the IT's lock assertion had never been shown red | Fixed. See "Hand mutants" below: with the pre-check deleted **and** `rollbackFor` removed from both `completeReversal` and `StockunitService.transferStock`, the IT goes red at `after.lock()` with `expected: 100 but was: 0` and the message "the parcel's stock must still be reserved for goods-out (100)…". With the pre-check deleted but the rollback intact, it stays green: the second layer holds. | `CancellationReversalParcelSourceIntegrationTest.aReversalOutOfAParcelIsRefusedAndLeavesTheLockAt100`, renamed from `…RollsBackTheLockClear`. After L10 no clear happens on the refusal path. Its javadoc now describes both layers and records the two measurements. |
| **L9**: dead `case UNIT_LOAD_TYPE_PACKAGE` | Fixed. `MobileMoveUnitloadService:673` now carries the comment `// unreachable since SBDEV-3353: SourceContainerGuard refuses a Package source above, before its stock moves.` | n/a (comment) |
| **L10**: RTS refused only after the lock-clear write | Fixed. `CancellationReversalService.completeReversal:282` calls `SourceContainerGuard.assertStockNotInParcel(sourceStockunit, …)` at the end of the atomic **pre-validate** loop, so it runs before any lock clear, flush or sibling move. It needs a constructor change: `UnitloadRepository` and `UnitloadTypeRepository` are appended, and both hand-built test sites are updated. The `transferStock`-level guard is kept as the second layer. | `CancellationReversalServiceUnitTest.completeReversal_shouldRefuseBeforeTheLockClear_whenThePickToStockSitsInAParcel`: `never()` on `stockunitRepository.save`, `never()` on `flush`, in-memory lock still 100. Tote control `…_shouldClearAndMove_whenThePickToStockSitsInATote`. `…ParcelSourceRefusalUnitTest` case 8 now also asserts `never().save` and `never().flush` with descriptions. The existing unit test fixtures resolve the tote to a real Tote type (lenient, in `setUp`). |
| Security **S3** (info) | No change, by decision: `handleTruckOffLoading` stays unguarded (Nam), and whole-parcel relocation is 868m9914u. Also observed in the sweep: `MobileMoveUnitloadService.setStockDamaged` (Move Unit Load → Damaged) relocks and relocates the whole unit load and takes no stock out, so it belongs with 868m9914u, not here. | n/a |
| Old-literal sweep | Done. `git grep` over `src/` for `at the top of`, `whose only move`, `NOT observable here`, `unreachable`, `out of scope`, `three services`/`every caller already` and every `3353` comment. The fixes are: the `SourceContainerGuard` javadoc (it said callers add "no constructor parameter to three services"; it now lists all 6 callers and the one constructor change), the ParcelSourceRefusal class and case-8 javadocs, the MobileTransferOrder nested javadoc ("at the top" → below the lane checks), the IT javadoc and `@DisplayName`, and the second-layer pin javadoc in `CancellationReversalServiceUnitTest`. The remaining "at the top of transferStock" hits are true, because that guard still sits there. `StockunitServiceUnitTest:2229` is SBDEV-3341's SourceLockGuard, not this ticket. | n/a |

## Verification

**Targeted lane:**

```
mvn -o -ntp test -Dtest='SourceContainerGuardUnitTest,StockunitService*Test,CancellationReversalServiceUnitTest,MobileTransferOrderServiceUnitTest,MobileMoveUnitloadServiceUnitTest,MobileMoveUnitloadServiceTest,MobilePutAwayServiceUnitTest,UnitloadServiceUnitTest,StockunitBusinessServiceFullMoveInvariantUnitTest,NeverMatcherNullBlindnessArchTest,PutawayControllerUnitTest,TransferOrderControllerUnitTest,TransferOrderServiceUnitTest,StockUnitControllerUnitTest,ReturnAdviceAutoReceiveService*Test' -Dsurefire.failIfNoSpecifiedTests=false
```

Result: **728 run / 0 fail / 0 err / 0 skip**. Per class, summed over `@Nested` reports from the XML:

| Class | Run |
|---|---|
| SourceContainerGuardUnitTest (new) | 11 |
| StockunitServiceParcelSourceRefusalUnitTest | 38 (was 30) |
| CancellationReversalServiceUnitTest | 29 (was 27) |
| MobileTransferOrderServiceUnitTest | 39 (was 33) |
| MobileMoveUnitloadServiceUnitTest | 64 (was 61) |
| MobileMoveUnitloadServiceTest | 25 |
| MobilePutAwayServiceUnitTest | 67 |
| UnitloadServiceUnitTest | 84 |
| StockunitServiceUnitTest | 90 |
| StockunitServiceTransferStockDestinationTest | 16 |
| StockunitServiceToteContainerRelocationUnitTest | 8 |
| StockunitServiceAuditCommentClampUnitTest / LockOnHoldTxTest / TransferStockGuardTest | 13 / 1 / 1 |
| StockunitBusinessServiceFullMoveInvariantUnitTest | 3 |
| NeverMatcherNullBlindnessArchTest | 4 |
| StockUnitControllerUnitTest | 74 |
| ReturnAdviceAutoReceiveServiceUnitTest | 84 |
| PutawayControllerUnitTest / TransferOrderControllerUnitTest / TransferOrderServiceUnitTest | 13 / 10 / 54 |

**RTS IT**, same command shape as the implementation pass:

```
mvn -o -ntp verify -Dit.test='CancellationReversalParcelSourceIntegrationTest,CancellationReversalLockClearIntegrationTest,MobilePutawayServiceIntegrationTest' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
```

- `CancellationReversalParcelSourceIntegrationTest`: 2/2.
- `CancellationReversalLockClearIntegrationTest`: 8/8.
- `MobilePutawayServiceIntegrationTest`: 1 skipped, which it already was before this change.
- BUILD SUCCESS.

**Compile:** `mvn -o -ntp clean compile` exit 0. The 5 `[WARNING]`s are all deprecation or varargs warnings in untouched files.

**Full suite:** `mvn -o -ntp clean test` → **Tests run: 7102, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS. 7102 = 7069 + 33 new tests (11 + 8 + 2 + 6 + 3 + 3). No concurrent Maven was running (`pgrep` checked before every run). The previous run was 7069/0/0/1, so the difference is this pass's new tests. `git status` afterwards shows only the intended files, with no ArchUnit store drift.

## PIT (scoped, `mvn -o org.pitest:pitest-maven:mutationCoverage -DtargetClasses=… -DtargetTests=…`)

Mutants were filtered to lines added on the branch (`git diff -U0 origin/develop`).

| Class | Tests | Mutants on branch-added lines |
|---|---|---|
| `util.SourceContainerGuard` | Guard, ParcelSourceRefusal, MobileTransferOrder, MobileMoveUnitload, MobilePutAway, CancellationReversal unit tests | **9 generated, 9 KILLED** (whole class: 9/9). These are every null or blank conditional plus the removed `assertNotParcel` call. |
| `service.StockunitService` | ParcelSourceRefusal | `:337` (transferStock guard) and `:769` (setLockDamaged guard) removed-call: **both KILLED** |
| `service.mobile.MobileTransferOrderService` | MobileTransferOrderServiceUnitTest | `:392` removed-call: **KILLED** |
| `service.mobile.MobilePutAwayService` | MobilePutAwayServiceUnitTest | `:552` removed-call: **KILLED** |
| `service.CancellationReversalService` | CancellationReversal, ParcelSourceRefusal | `:282` (pre-check) removed-call: **KILLED** |
| `service.mobile.MobileMoveUnitloadService` | MobileMoveUnitloadServiceUnitTest | `:636` removed-call: **KILLED** (this pass changed only a comment in this class) |

- **0 survivors on new lines.** The class-wide percentages (e.g. StockunitService 28/147) cover untouched code graded against one test class, which is out of scope.
- **Not a PIT mutation site, so covered by hand mutants instead:**
  - The `LOG.warn` calls: PIT's default `avoidCallsTo` skips logging.
  - The `findById(...).orElse(...)` re-reads: a non-void argument expression.
  - `UnitloadService`: javadoc only.

## Hand mutants

Each mutant was copied to the scratchpad, applied, run, and restored from that copy (no git stash, checkout or restore). The dirty-path count was 19 before and 19 after every mutant.

- **Unit mutants** ran on `SourceContainerGuardUnitTest,StockunitServiceParcelSourceRefusalUnitTest,CancellationReversalServiceUnitTest,MobileTransferOrderServiceUnitTest,MobileMoveUnitloadServiceUnitTest,MobilePutAwayServiceUnitTest` (248 tests).
- **IT mutants** ran on `CancellationReversalParcelSourceIntegrationTest`.

| Mutant | Result | Red test(s) and message |
|---|---|---|
| Delete the `setLockDamaged` guard call | 2 red | `setLockDamaged_shouldRefuse_whenTheStockSitsInAParcel` and `…_whenTheReReadRowIsInAParcelButTheSnapshotIsNot`: "a stock move out of a Package (parcel) must be refused with key 'transferStockSourceIsParcel' — no SBDEV-3353 refusal was raised" |
| Delete the putaway guard call | 1 red | `storeBoxOnLocation_shouldRefuse_whenAParcelWouldBeDrainedIntoAFlowBin`: "a putaway that drains a Package into a flow bin must be refused with key 'transferStockSourceIsParcel' — no SBDEV-3353 refusal was raised" |
| Delete the `completeReversal` pre-check | 2 red | `CancellationReversalServiceUnitTest.completeReversal_shouldRefuseBeforeTheLockClear_…`: "…must be refused with key 'transferStockSourceIsParcel' in the pre-validate — no SBDEV-3353 parcel refusal was raised before the lock clear". `…ParcelSourceRefusalUnitTest.completeReversal_shouldRefuse_…`: "SBDEV-3353 L10: the parcel refusal must fire in completeReversal's pre-validate, BEFORE the lock-100 clear is saved" |
| Remove the re-read in `transferStock` (judge the snapshot) | 1 red | `transferStock_shouldRefuse_whenTheReReadRowIsInAParcelButTheSnapshotIsNot` (parcel-refusal message) |
| Remove the re-read in `setLockDamaged` | 1 red | `setLockDamaged_shouldRefuse_whenTheReReadRowIsInAParcelButTheSnapshotIsNot` (parcel-refusal message) |
| Remove the re-read in mobile `transferStock` | 1 red | `…$Sbdev3353ParcelSource.transferStock_shouldRefuse_whenTheReReadRowIsInAParcelButTheSnapshotIsNot`: "the guard must judge the RE-READ row (in the parcel) and refuse with key 'transferStockSourceIsParcel' — no SBDEV-3353 refusal was raised, so it judged the controller's stale snapshot" |
| Move the mobile guard back to the top (undo L5) | 2 fail + 1 error | The two L5 tests fail. For example, the lane test expected "Order has transfer lane = TRANSFER-LANE-01" but got "Container UL-001 is a parcel (Package)…". The L1 test also went red. |
| Revert the blank-label check (`label == null ?` only) | 5 red | The 3 guard-test cases and 2 refusal-class cases, e.g. `"Container  is a parcel…" to contain "Container 42 is a parcel"` |
| All `LOG.warn` → `LOG.debug` in the guard | 5 red | Every `SourceContainerGuardUnitTest.*_shouldWarn_*`: "a fail-closed proceed must be logged at WARN, once — a silent one hides a parcel let through. Expected size: 1 but was: 0" |
| **L8a**: delete the pre-check only (IT) | IT **green** 2/2 | Expected. The transferStock guard throws, and `rollbackFor` restores lock 100. This proves the second layer. |
| **L8b**: delete the pre-check **and** remove `rollbackFor` from both `completeReversal` and `StockunitService.transferStock` (IT) | IT **red** 1/2 | `aReversalOutOfAParcelIsRefusedAndLeavesTheLockAt100`: "[the parcel's stock must still be reserved for goods-out (100) — refused before the clear, or the clear rolled back; left at 0 it is pickable stock that is packed for an order] expected: 100 but was: 0" |

The implementation pass already mutated the original `transferStock`, mobile-transfer and mobile-move guard calls (mutants a/b/c). PIT kills those three again above.

## Not fixed, and why

- **Whole-parcel relocation** (Move Unit Load to a non-flow-bin location, putaway's whole-unit-load arms, and the whole-unit-load relocation in Move Unit Load → Damaged): Nam's decision, carried by [868m9914u](https://app.clickup.com/t/868m9914u).
- **`handleTruckOffLoading`**: deliberately unguarded (Nam).
- **`adjustAmount`**: it rewrites a parcel's quantity but is not a move. Named in the `UnitloadService` javadoc as still open. It needs a decision from Nam if it should be guarded.
- **Mobile Move Unit Load, flow-bin LOCATION arm with no FLA yet:** `createFixedLocationAssignment` runs before the private `transferStock` guard. The refusal still rolls that write back, because `scanDestination` is `@Transactional(rollbackFor=BusinessException)`. The code was not moved, since that placement is the one the spec required (inside the stock branch, keeping AC-10). The new L7 test uses an existing FLA.
- **L1 residual:** as accepted above, the check is not made on the `FOR UPDATE` row.

## Observation for Nam (not a dispute, no change made)

`AdviceService` (`:226`) and `AdviceRestController.createHubAndSpoke` (`:790`) create **inbound hub-and-spoke parcels** as `Package` unit loads. Under the type-only rule, a stock move out of one of those is now refused too, not only out of outbound packed parcels.

- This is consistent with the decision as written ("keyed on type alone").
- It does widen the refused population beyond `customerorder.parcel_id` parcels.
- If splitting stock out of a hub-and-spoke parcel is a real warehouse workflow, it would need an exemption.
- I did not query how many hub-and-spoke Package unit loads hold live stock.

## Corrections (added 2026-09-24 by the P2 fix pass, after `p2-rereview.md`)

The table above is left as written. These are the claims in it that were wrong.

| Claim above | What is actually true | Fixed where |
|---|---|---|
| **L1 row:** "setLockDamaged and the mobile method are not @Transactional, so their re-read is a later read rather than an in-transaction one, **and their comments say so**." | Only the `setLockDamaged` comment said so. The mobile comment (`MobileTransferOrderService`, above the guard) said "fresh plain findById, not the controller's detached row" and nothing about the transaction. | `p2-fixes.md` N3: the mobile comment now says why an entity re-read is safe there. |
| **L1 row:** the `transferStock` re-read is presented as a pure narrowing of the packing race. | It was not only a narrowing. `transferStock` is `@Transactional`, so the entity `findById` made the source `Stockunit` managed before `transferStockToUnitLoad`'s `findByIdForUpdate`. On the existing-container arms and the flow-bin new-container arm, which otherwise touch the row first under the lock, a concurrent commit to the row now made the lock read throw `StaleObjectStateException` (re-review N1). | `p2-fixes.md` N1: replaced with a scalar read. |
| (Not claimed above, but missed by it and by both P1 reviews.) The guard itself, since the first commit `d7c77870`, resolved the source **unit load** with an entity `unitloadRepository.findById`. | Inside `transferStock`'s transaction that manages the source `Unitload` before `transferStockToUnitLoad`'s `unitloadRepository.findByIdForUpdate` on the same row (`StockunitBusinessService:237`). That is the same defect as N1, on the unit load, and it affected the same two arms (the pallet and rack arms read the source unit load themselves anyway). On RTS to a flow-bin location it applied too. | `p2-fixes.md` N1: the guard now reads the unit load as scalars (`UnitloadRepository.findParcelGuardViewById`). |
| **M1 row:** the javadoc "describes the set as the **backstop** for the guard's fail-closed and bypass cases". | The set is a backstop only for removal or bypass of the guard. For the guard's unresolved-type branches, `restsInStorageLocation` cannot resolve the type either, answers "not storable", and the split arm drains the container. So it gives no protection there (re-review N2). | `p2-fixes.md` N2: `UnitloadService` javadoc reworded. |
| **Security L2 row, L2 row, and the hand-mutant table:** the guard's proceed branches are called "fail-closed" (and the WARN assertion message said "a fail-closed proceed must be logged"). | They are fail-**open**: on an unknown the move proceeds unguarded. The security review had it right. | `p2-fixes.md` N2: every copy in the branch's files renamed to "fail-open (proceed-unguarded)". |
| **L10 row and the `CancellationReversalService` comment:** "a refused reversal writes nothing". | It **commits** nothing. The SBDEV-3316 recovery `logRepository.save` in the same pre-validate can run before the parcel check (for this row or an earlier one), and the method's `rollbackFor` undoes it (re-review N5). | `p2-fixes.md` N5: comment reworded. |
