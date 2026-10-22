---
ticket: "SBDEV-3758"
kind: evidence
lane: architect consult (read-only)
created: 2026-10-13
code: worktree .claude/worktrees/wms2-api/SBDEV-3758 @ origin/develop 8553299d (unmodified)
verdict: GO-WITH-CHANGES
---

# SBDEV-3758 fix A: architect consult

## Verdict: GO-WITH-CHANGES (stays T2)

Fix A loses no load-bearing behaviour. The pick-line bucket does not change. Downstream readers
already handle both the minted lane UL and a 0-amount SU left on an FLA bin. **One change is needed:**
the hoist in step 2 only covers *source* locks. The old FLA arm also refused a locked **transfer
lane**, before any write (`FacadeException STORAGELOCATION_LOCKED`). On the split path that refusal
comes from inside `transferStockToUnitLoad`, after `createUnitload` has already committed. So unless
the lane lock is pre-checked too, fix A brings the orphan-UL defect into the whole-stock FLA case,
where it does not exist today.

## (a) Activity code / PickLineActivityCodeClassifier: no change

- The old arm passed a **null** activity code: `unitloadBusinessService.transferUnitLoadToLocation(unitLoad, transferLane, false, null, null, null)` (`MobileTransferOrderService.java:424`). The signature is `(Unitload, Location, boolean ignoreLock, String activityCode, ...)` (`UnitloadBusinessService.java:221`).
- The classifier maps null to PASS_THROUGH: `if (activityCode == null || activityCode.isEmpty()) { return Bucket.PASS_THROUGH; }` (`PickLineActivityCodeClassifier.java`, `classify`). `CODE_MANUAL_SPLIT` is listed in `PASS_THROUGH_CODES`.
- So before and after, neither `lockOwningPickingorders` (`StockunitBusinessService.java:196-199`) nor `assertNoActivePickFor`/`realignForMovedStockUnit` (`:346-350`, full-move branch only) runs. This arm also requires `reservedamount == 0` (`MobileTransferOrderService.java:404`), so no pick line holds a reservation on the source SU in either version.

## (b) Downstream readers

| reader | evidence | effect of fix A |
|---|---|---|
| Split for an FLA source | `if (destinationStockUnit == null && (sourceStockunit.getAmount().compareTo(amount) > 0 \|\| fixLocationAssignment != null))` mints a fresh dst SU (`StockunitBusinessService.java:328-335`); `if (fixLocationAssignment == null && BigDecimal.ZERO.compareTo(sourceStockunit.getAmount()) == 0) { sendStockUnitToNirvana(...)` (`:416`) | Bin keeps its UL and a 0-SU. No Nirwana send. The FLA is looked up by **location** (`findByAssignedlocationId(sourceLocation.getId())`, `:324`), not by UL like the old arm (`findByAssignedunitloadId`, `MobileTransferOrderService.java:406`). See the divergence note below |
| Pick-source listing (`updateOrderPositionPickSources`) | `getStockUnitItemIdAndNotLocked` ends `"AND su.amount > 0"` (`StockunitRepository.java:595`) | The 0-SU left on the bin is **not** offered as a pick source |
| 0-SU on an FLA bin is already a normal state | WineCo PRD (read-only, this consult): `zero_su_on_fla_bins = 71`, `pos_su_on_fla_bins = 1482` across 1,556 FLAs | Not a new shape for any reader |
| `calculateStockOnStagingLane` → `getAmountAvailable` | Sums by `location.id = :locationId AND itemdata.id = :itemdataId` with `unitload.entity_lock = 0` (`StockunitRepository.java:189-199`). The minted UL gets `unitload.setEntityLock(0)` (`UnitloadService.insertUnitload`) | A minted lane UL counts exactly as the relocated one did |
| BOL build-truck | `unitloadRepository.findByStoragelocationId(transferLane.getId())`, then `combineStock` per UL, each SU via `transferStockToUnitLoad(..., CODE_TRANSFER_BUILD_TRUCK, ...)` (`BillofladingService.java:908-929, 1099-1137`). Nothing keys on UL type or FLA except `transferLaneFla` (the lane's own FLA) | Generic. The minted UL is drained and retired the same way. Now **it** goes to Nirwana instead of the pick-face UL, which is the fix |
| OMS | No outbox or OMS call in `transferUnitLoadToLocation`, `transferStockToUnitLoad` or `transferStock` (grep: `outbox\|omsNotification` gives 0 hits in the three files) | None. This agrees with the sizing doc (OMS receives the build-truck parcel label) |
| Audit trail | Old arm: one `unitload_record` TRANSFERRED (`UnitloadBusinessService.java:541`), no stockrecord. New: `recordRemoval` + `recordCreation` (`StockunitBusinessService.java:413-414`), plus a STOCK_CREATED amount=0 row from `createStockUnitCore` (`:139-163`, the SBDEV-3382 known artefact) | Adds rows; nothing read the absence. The incident query in the sizing doc (`unitload_record ... activitycode IS NULL`) stops matching new events. That is fine, but a monitor built on it would go silent |

**A behaviour change that is a fix, not a loss:** the old arm moved the *whole container*, including any
sibling SUs, so more stock could leave than `amountLeft`. The split moves only the scanned SU's
`available`. On WineCo PRD this is latent: `fla_ul_with_multi_su = 0` and `fla_bins_with_multi_ul = 0`.

**Divergence of the FLA key (residual, out of scope):** the old arm keyed on "UL is an FLA's UL". The
split keys on "source location is an FLA bin". The two differ only for an FLA UL that is already off
its bin. Such a UL would now take the full-move branch, and `relocateEmptiedContainer(sourceUnitload, CODE_SEND_TO_NIRVANA, ...)` (`:402-404`) would retire it. That is the same dangling end state as today, just reached faster. PRD has `fla_ul_off_bin = 3`, and all three are in Nirwana with 0 stock, so they cannot be pick sources. This belongs to fix B, not A.

## (c) Hoisting SourceLockGuard

- The guard checks the same three entities as the split's `!ignoreLock` block: SU, UL, location (`SourceLockGuard.assertSourceUnlockedForContainerRelocation` vs `StockunitBusinessService.java:282-298`). It is not a whole-container check, so a split never gains a refusal over a sibling SU's lock. All three arms pass `ignoreLock=false`, so the outcome set is unchanged. Only the timing moves earlier.
- Message text differs for UL/location locks. The guard renders `describe(lock)` = `lock + " (" + codeText + ")"` (`LockRefusalMessages.java:26-27`). The split renders the raw `"is locked=" + lock` (`:293, :297`). The string "is locked=104" is still a prefix, so substring asserts survive, but exact-equality asserts in tests on the reserved/partial arms will need updating.
- The guard reads with plain `findById`, outside the row lock. The in-transaction recheck stays, so a lock that lands after the pre-check is still refused, now after the mint (residual orphan, narrowed but not closed).
- **Gap (the GO-WITH-CHANGES item):** other refusals inside `transferStockToUnitLoad` still fire after the mint commits:
  - destination location lock: `"Destination location=... is locked="` (`:314-317`)
  - `!unitloadType.getStockunitallowed()` (`:212`)
  - stale `available` from the controller's detached SU (`:206`)
  - mixed stock (`:229`, cannot happen on a fresh UL)

  Today the whole-stock FLA case has **no** orphan path for a locked lane: `transferUnitLoadToLocation` refuses first, with `throw new FacadeException("STORAGELOCATION_LOCKED", ...)` (`UnitloadBusinessService.java:247-249`), and mints nothing. Fix A as written regresses this, and also changes the operator message from the localized `STORAGELOCATION_LOCKED` to `Destination location=X is locked=N`.

  **Change:** add `transferLane.getEntityLock()` to the hoisted pre-check, so all three arms refuse a locked lane before the mint. `transferLane` is already loaded at `:365`. The stale-available and stockunitallowed orphans are pre-existing on the partial/reserved arms. Note them on the ticket; they do not block.

## (d) T2 or T3: T2 holds

- No authz, Flyway, multi-repo or irreversible-data change. The split path for FLA sources already runs on PRD through the reserved>0 and partial arms (`:433-441`), with the same `transferStockToUnitLoad` call.
- Wrapping `transferStock` in `@Transactional` to close every orphan **would** be T3-shaped, and it is not recommended here. `SourceContainerGuard`'s comment at `:392-395` relies on the method being non-transactional ("the row is detached ... cannot turn a later findByIdForUpdate ... into a lock upgrade"). The pre-check is the T2-sized answer.
- None of the escalation triggers fired. The DB agrees with the ticket (3 off-bin FLA ULs). No new repository method is needed. Nothing here disputes the design.
- Step 3 is safe: `fixLocationAssignmentRepository` has one use in the class (`:406`); its other references are the field and constructor (`:30, :62, :78`). Removing it changes the constructor shape in `MobileTransferOrderServiceUnitTest`, `TransferOrderControllerUnitTest` (if it constructs the service) and the IT wiring, so compile both lanes.

## Tests the change should carry

1. Whole-stock FLA source: the bin keeps the FLA UL plus a 0-SU, the lane holds a minted UL with the amount, there is a MANUAL_SPLIT removal/creation pair, and **no** unitload TRANSFERRED/Nirwana record for the pick-face UL. Invert `transferOrder_MoveBothUnitLoadsTest`.
2. Locked transfer lane, all three arms: refused with **0 new unitload rows** (`unitloadService.createUnitload` never called). Mutation check: remove the lane pre-check and confirm red.
3. Locked source, all three arms: `createUnitload` never called.
