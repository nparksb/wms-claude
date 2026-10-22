# SBDEV-3353 — architect consult: where the Package refusal lives

Source: `origin/develop` @ `978b3a14` (fetched 2026-09-24), read via `git show`. DB: wsl-wineco-uat, nywh-hydra-uat (read-only).

## 1. The lock guards already cover most of the Package population. The damaged arms and unlocked parcels are the gaps

Packing reuses the same stock unit row and keeps its lock.
- `CustomerorderService.packageOrder`: `transferStockToUnitLoad(stockUnit, packageUnitLoad, stockUnit.getAmount(), CODE_PACKAGING, …, true, false)`. The call passes the full amount, a brand-new empty Package and `ignoreLock=true`.
- `StockunitBusinessService.transferStockToUnitLoad`: when `destinationStockUnit == null` and no split or FLA applies, it runs `sourceStockunit.setUnitloadId(destinationUnitload.getId())`. The same row is re-homed with its lock untouched.
- Picking stamps that lock: `PickingorderBusinessService`: `pickToStock.setEntityLock(...PICKED_FOR_GOODSOUT)` (100).

DB check (wsl-wineco-uat). Package stock that is not SHIPPED, grouped:
- `su_lock=100`, co 670, `Gate_01`, on a carrier: **63**
- `su_lock=100`, co 650, `Packaging`: **15**
- `su_lock=0`, co **800 (CANCELED)**, `Packaging`: **1**

Hydra UAT has 1 row (100 / 650). Positive control: 469,625 Package unit loads exist on WineCo UAT, so an empty result would have been meaningful.

So a live parcel's stock is already refused by:
- every `ignoreLock=false` arm: `if (!ignoreLock) { … "Source stockUnit=… is locked="`
- the whole-unit-load arm: `SourceLockGuard.assertSourceUnlockedForContainerRelocation`, which refuses ANY non-zero lock

**The real holes on develop today:**
- **H1: the damaged arm.** `StockunitService.transferStock`, destination = `STORAGE_LOCATION_DAMAGED`: `transferStockToUnitLoad(stockUnit, unitLoad, amountToTransfer, WmsConstants.CODE_DAMAGED, null, comment, true, true)`. Here `ignoreLock=true`, and `removeUnitLoadIfEmpty=true` sends an emptied parcel to Nirvana. The QF sibling (`CODE_MANUAL_SPLIT, …, true, true`) needs the source lock to be 103, so lock-100 stock cannot reach it. H1 is live for all 79 rows above, including the 63 on truck pallets.
- **H2: unlocked parcels.** `forceCancelOrder`'s PACKED arm does `stockUnit.setEntityLock(NOT_LOCKED)` and then `sendToClearing(parcel…)`, and it leaves `parcel_id` set. Every arm accepts that stock, including the whole-unit-load arm that relocates the parcel into a bin.
- **H3: after the planned `TYPES_THAT_REST…` change.** For H2 rows, the whole-unit-load arm stops firing and the split arm drains the parcel. That empties it to `relocateEmptiedContainer` → `default:` → `sendToNirvana`. This is the irreversible case the set's javadoc warns about.

So the guard is **not** redundant with the lock checks. It must fire regardless of the lock, because `ignoreLock=true` exists on this path.

## 2. Route sweep

Method: `git grep -n "transferStockToUnitLoad\|transferUnitLoadToLocation\|\.transferStock(\|restsInStorageLocation" origin/develop -- src/main`.

**Operator routes that can take stock out of a Package:**

| Route | Entry | Arms |
|---|---|---|
| Web Move Stock | `StockUnitController` `/transferStock` (:156) and the bulk endpoint (:270) → `StockunitService.transferStock` | existing-container (pallet + non-pallet), FLA flow bin, whole-unit-load, new-container split, QF-damaged, damaged |
| Mobile transfer order | `TransferOrderController:101` → `MobileTransferOrderService.transferStock` | FLA whole-unit-load (`SourceLockGuard`), 3× split `…CODE_MANUAL_SPLIT, null, null, false, true` |
| **Missed: mobile Move Unit Load** | `MobileMoveUnitloadService` (~:611) `transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad, …, CODE_TRANSFER, …, false, false)`, then a type switch with `case UNIT_LOAD_TYPE_PACKAGE: // waterfall default: sendToClearing(sourceUnitLoad…)` | lock guard `!= NOT_LOCKED && != QUALITY_FAULT` → refuses 100 but **accepts H2 rows**. Also `handleTruckOffLoading` (:489/:545) |
| RTS | `CancellationReversalService.completeReversal` → `transferStock(stockUnit, log.getAmountPicked(), false, log.getPickfromlocationname(), …)` | new-container split / whole-unit-load |

**Non-operator callers (out of scope, and they must NOT be guarded):** `packageOrder` (the Package is the destination), `BillofladingService:1075/1094` (the parcel is the destination), `ClubLineOrderProcessor:197`, picking, replenishment, putaway, `UnitloadService:175` damage, and the system relocations of `transferUnitLoadToLocation`.

Blind spots of this sweep:
- Callers that write `stockunit.unitload_id` directly are not matched, and I did not grep `setUnitloadId(`.
- The SDR repository surface is not matched (see the memory "Access-chain hops writable over SDR").
- Reflection and proxy calls are not matched.
- `MobileMoveUnitloadService.scanDestination`'s whole-container `transferUnitLoadToLocation` (:376) moves a Package **whole**. It relocates the parcel but does not drain it, so it is a sibling concern and not in this guard's scope.

## 3. RTS: can a reversal's stock be inside a Package?

Mostly no, by construction. There is one residual gap I have not proven either way.
- The PACKED branch of `forceCancelOrder` writes **no** cancellation log. Only the `if (customerOrder.getState() < WmsConstants.State.PACKED)` branch calls `cancellationLogService.recordCancellation`.
- `CustomerorderPositionService`: `if (customerOrderPosition.getState() >= PACKED) throw … "can not be cancelled anymore"`.
- `isShippedOrPastCancellationBoundary` blocks orders at state FINISHED or later, and orders whose parcel carries a 405 lock on the unit load or any of its stock units. It does **not** block PACKED; PACKED goes to `forceCancelOrder`.
- Late recovery also fails after packing. `resolvePicktoStockunitId` maps `pickingorder_unitload.unitload_id`, and `packageOrder` nulls that with `pickingUnitLoad.setUnitloadId(null)`. A log created post-pack therefore gets `picktostockunit_id=null`, and `completeReversal` throws "no source stock unit could be resolved".
- **Residual gap:** `PickingorderBusinessService.cancelOpenPickLines` writes a `reversal_required=true` log for a PICKED line on a *marked* order before the order is cancelled. Its javadoc mentions "a position blocked at PACKED". If that order is then packed, `picktostockunit_id` already names the row that packing re-homes into the Package. `completeReversal` would then clear lock 100 (`arrivedLocked … setEntityLock(NOT_LOCKED)`) and call `transferStock` on Package stock.
- DB: `customerorder_cancellation_log` has **0 rows** on WineCo UAT and 0 `reversal_required` rows on Hydra UAT, so there is no population evidence either way.

**Verdict:** the guard SHOULD fire on RTS too. Returning a parcel's contents to the pick bin while `parcel_id` and the BOL still point at the parcel is the same corruption. The refusal becomes a 422 with the "manual intervention" wording that the reversal already uses. Do not add an RTS exemption flag.

## 4. Does it fire on every amount?

Confirmed: partial moves corrupt the parcel too. When `sourceStockunit.getAmount().compareTo(amount) > 0`, `transferStockToUnitLoad` calls `createStockUnit(…, destinationUnitload…)` and then runs `sourceStockunit.setAmount(sourceStockunit.getAmount().subtract(amount))`. The parcel's quantity drops while the OMS manifest and the BOL keep the packed quantity. The guard must therefore sit **before** the arm dispatch, not inside the `restsInStorageLocation` arm.

## 5. What "not yet shipped" means, and what to key on

- In code, "shipped" means lock **405 on the parcel unit load OR on any of its stock units**. That is the rule `isShippedOrPastCancellationBoundary` uses (`parcelOpt.get().getEntityLock() == SHIPPED` / `anyMatch(su -> su.getEntityLock() == SHIPPED)`). The stock-unit lock is the one BOL close actually stamps.
- **Recommendation: key on the source container type alone (`Package`), without a shipped test.**
  - A shipped parcel must not be drained either.
  - The lock checks already refuse shipped stock on `ignoreLock=false` arms, so adding a shipped test only narrows the guard on the H1 damaged arm, which is exactly the arm that needs it.
  - Carrier (Pallet) and open-BOL tests would each need a query. There is **no** `findByParcelId` or `existsBySourceId` finder on develop; I grepped `repo/` and got 0 hits. Adding one is mid-flight escalation trigger (2), for no additional safety.
- **Tension:** keying on the type alone also refuses H2, the CANCELED-order parcel in Clearing (1 row on WineCo UAT). Web Move Stock can then no longer restock it, and nothing in RTS covers it. The alternative remedy is mobile Move Unit Load unless that route is guarded as well. Nam should decide: (a) type-only, accepting that restocking goes through mobile or an admin, or (b) exempt a parcel whose order is CANCELED, which needs a new repository method and moves this to T2.

## 6. Exception pattern

Use the keyed form, `BusinessException(String key, Object... parameter)` (`BusinessException.java:49`). The precedent is `throw new BusinessException(WmsConstants.MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION, mintedTypeName, …)` with `unitloadTypeNotPermittedOnLocation=Unit load type %1$s is not permitted…` in `messages_en_US.properties`. Add `MSG_TRANSFER_SOURCE_IS_PARCEL = "transferStockSourceIsParcel"` and a positional message, `%1$s`, not bare `%s`. The 1-arg constructor sets `key="placeholder"`, so tests must assert `getKey()`.

Put the check in a static helper next to `SourceLockGuard`, for example `SourceContainerGuard.assertNotParcel(Unitload, UnitloadType)`. Do **not** put it in `transferStockToUnitLoad`: packing, BOL and club call that method with a Package as source or destination.

## Recommended placement

- Add one guard at the **top of `StockunitService.transferStock`**, after the comment clamp and **before** the `if (isTransferToExistingContainer)` dispatch. It resolves `stockUnit.getUnitloadId()` → type name and throws when the name is `UNIT_LOAD_TYPE_PACKAGE`. This covers both web endpoints, all eight arms, every amount and RTS.
- Call the same helper at the top of `MobileTransferOrderService.transferStock`, which is its own copy.
- Call the same helper in `MobileMoveUnitloadService` before the stock-arm `transferStockToUnitLoad` (~:611). Leave `handleTruckOffLoading` out and list it as an open question for Nam, because offloading a returned parcel may be legitimate.
- Remove `UNIT_LOAD_TYPE_PACKAGE` from `TYPES_THAT_REST_IN_A_STORAGE_LOCATION` in the same change and update both javadocs. The set then diverges from `KNOWN_NON_REUSABLE_TYPE_NAMES`, as its javadoc predicts.
- Fail closed: an unresolvable unit load or type is not a Package, so the guard does not throw. That matches `restsInStorageLocation`'s split-path default. This is safe only because no arm reaches Nirvana for a non-Package type.

## Failing-test cases (StockunitServiceTest plus the mobile service tests; assert `getKey()` and no-write via `never()`)

1. Web, new-container, **full** amount, Package source, lock 0 (H2): refused; no `transferUnitLoadToLocation` or `transferStockToUnitLoad` call.
2. Web, new-container, **partial** amount, Package, lock 0: refused.
3. Web, destination DAMAGED, Package, **lock 100** (H1): refused. This is the live hole; it has to be red before the fix.
4. Web, destination DAMAGED, Package, lock 103 (QF arm): refused.
5. Web, existing container, pallet destination and non-pallet destination, Package source: refused.
6. Web, FLA flow-bin destination, Package source: refused.
7. Package source already SHIPPED (405) on the damaged arm: refused. This pins "type-only, no shipped test".
8. RTS: `completeReversal` whose pick-to stock sits in a Package: refused with the key, the log stays pending, and lock 100 is **not** left cleared (rollback).
9. Mobile `MobileTransferOrderService.transferStock`, Package source, split and FLA arms: refused.
10. Mobile Move Unit Load stock arm, Package source, lock 0: refused and no `sendToClearing`.
11. Controls: Box, Default and PickLocation sources proceed unchanged on each arm, and `packageOrder` and BOL still move stock **into** a Package.
12. After the set change: `restsInStorageLocation(Package) == false`, and a mutation that re-adds Package to the set turns an existing test red.
13. Mutation check: delete the guard call and cases 1–10 go red; flip `equals` to `!equals` and case 11 goes red.
