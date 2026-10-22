# SBDEV-3341 — guard placement: top of `transferStock` (A) vs whole-container branch (B)

All citations read from `origin/develop` via `git show origin/develop:<path>` (2026-09-14).

## Recommendation: **(B)** — inside the whole-container `else` branch, immediately before `transferUnitLoadToLocation`.

Point 2 is decisive and rules (A) out. Detail below.

---

## 2. (A) breaks the damaged-stock path — DECISIVE

`StockunitService.transferStock` reaches the damaged branches only **after** the whole-container
condition evaluates false. A top-of-method "refuse any non-zero lock" fires before that test, so it
kills both:

```java
// StockunitService.java — inside the `else` of the whole-container test
if (stockUnit.getEntityLock() == WmsConstants.BusinessObjectLockState.QUALITY_FAULT && ulLocation.getId().equals(destinationLocation.getId()) && destinationLocation.getName().equals(WmsConstants.STORAGE_LOCATION_DAMAGED)) {
    ...
    Stockunit stockUnitDest = stockunitBusinessService.transferStockToUnitLoad(stockUnit, unitLoad, amountToTransfer, WmsConstants.CODE_MANUAL_SPLIT, null, comment, true, true);
} else if (stockUnit.getEntityLock() != WmsConstants.BusinessObjectLockState.QUALITY_FAULT && destinationLocation.getName().equals(WmsConstants.STORAGE_LOCATION_DAMAGED)) {
    Stockunit damagedStock = stockunitBusinessService.transferStockToUnitLoad(stockUnit, unitLoad, amountToTransfer, WmsConstants.CODE_DAMAGED, null, comment, true, true);
    damagedStock.setEntityLock(WmsConstants.BusinessObjectLockState.QUALITY_FAULT);
```

- First arm **requires** `entityLock == QUALITY_FAULT` (`WmsConstants.java`: `public static final int QUALITY_FAULT = 103;`). A top-of-method refusal of any non-zero lock makes it unreachable — the "adjust damaged stock within the Damaged location" operation, gated on `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`, would always 400 before the permission check runs.
- Second arm requires `!= QUALITY_FAULT`, which still admits `ON_HOLD = 104` and `GOING_TO_DELETE = 2` — moving an on-hold unit to Damaged also dies under (A).
- Both call `transferStockToUnitLoad(..., ignoreLock=true, ...)` deliberately, i.e. they are *by design* exempt from the sibling guard. (A) would override that design decision from outside.

This alone is sufficient: **do not place the guard at the top of `transferStock`.**

The other (A)-widened routes are harmless but redundant: the existing-container pallet branch
(`transferStockToUnitLoad(..., false, true); unitloadBusinessService.transferUnitLoadToCarrier(...)`),
the existing-container non-pallet branch, and the flow-bin branch all already pass `ignoreLock=false`
and are therefore already guarded by `StockunitBusinessService`. (A) buys nothing there.

## 1. Message-change question (moot given the above, recorded for completeness)

The existing text is a raw concatenation, not a bundle key:

```java
// StockunitBusinessService.java, inside `if (!ignoreLock)`
int lock = sourceStockunit.getEntityLock();
if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
    throw new BusinessException("Source stockUnit=" + sourceStockunit.getId() + " is locked=" + lock);
}
```

- `git grep -n "is locked=" origin/develop` → only `StockunitBusinessService.java` (6 sites) plus **comments** in `CancellationReversalService.java` and two test files. No `messages*.properties` entry.
- Only one assertion pins it: `StockunitBusinessServiceUnitTest.java` — `shouldThrowExceptionWhenSourceStockUnitIsLocked` calls `stockunitBusinessService.transferStockToUnitLoad(...)` **directly** and asserts `.hasMessageContaining("is locked")`. It does not go through `transferStock`, so neither placement touches it.
- UIs: `wms2-mobile-ui` has zero matches outside a synthetic Jest fixture (`test/store/moveStockNonce.spec.js`: `{ message: 'Destination is locked' }`). `wms2-web-ui` matches are Cypress report prose and Jest fixtures (`test/store/transferToDamagedToastReason.spec.js`: `{ message: 'stock unit is locked' }`) — both UIs surface the server message verbatim in a toast and match on nothing.

So the message change would be cosmetic-but-operator-visible, not a functional regression. Irrelevant under (B), which never pre-empts the sibling guard.

## 3. Refactor durability

(B) is the weaker position on paper — a guard inside a branch can be dropped when the branch is
rewritten. Two mitigations that cost nothing:

- Put the guard **immediately above** `unitloadBusinessService.transferUnitLoadToLocation(suUnitLoad, destinationLocation, false, WmsConstants.CODE_MANUAL_TRANSFER, null, comment);` in a named private method (e.g. `assertWholeContainerSourceUnlocked(stockUnit, suUnitLoad, ulLocation)`), so a grep for the method name finds the invariant even if the branch moves.
- Pin it with a unit test that drives `transferStock(..., isTransferToExistingContainer=false, ...)` on the whole-container shape (`amount == amountToTransfer`, no FLA, `stockUnitList.size() == 1`) — a route test, not a call-site test, so a refactor that relocates the guard keeps it honest.

Check the **same three sources** the sibling guard checks, not just the stock unit — the call relocates the **container**, so `suUnitLoad.getEntityLock()` and `ulLocation.getEntityLock()` are in scope too. Otherwise the guard is an instance fix, not the invariant.

⚠ `getEntityLock()` is boxed. `CancellationReversalService` already documents the trap: a null "unboxes into an NPE at `int lock = sourceStockunit.getEntityLock()`". Write the new guard null-safe.

## Does (B) refuse anything that legitimately succeeds today?

Yes — this is the accepted blast radius, stated plainly:

1. **A whole-container move of stock at any non-zero lock.** Today it succeeds silently, including for `QUALITY_FAULT`: a lone damaged stock unit moved in full skips the damaged branches entirely (the whole-container test is evaluated first), so it also skips the `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` permission check. Under (B) it is refused. Hydra PRD live stock carries non-zero locks `2` (30 rows, 0 alone in container), `100` (7 rows, 0 alone) and `405 = SHIPPED` (328 rows, **76 alone in their container**) — those 76 are the population that would route here and be refused.
2. **Not affected:** truck loading. Those 204 moves call `UnitloadBusinessService.transferUnitLoadToLocation` directly, not through `transferStock`; (B) touches only the `StockunitService` call site.
3. **Not affected:** cancellation reversal. `CancellationReversalService` pre-validates and then clears to `NOT_LOCKED` with an explicit `entityManager.flush()` before `stockunitService.transferStock(stockUnit, log.getAmountPicked(), false, log.getPickfromlocationname(), null, null, false);`, so it arrives at 0.

DB check (Hydra PRD, `stockrecord` by `activitycode`): `MANUAL_SPLIT` 15 rows (latest 2026-09-03) — the partial/damaged routes are live; `MANUAL_TRANSFER` **0 rows**, `DAMAGED` **0 rows**. Caveat: `stockrecordService.recordRelocation(...)` in the whole-container branch is a recent addition, so 0 `MANUAL_TRANSFER` rows is **not** proof the branch never ran — treat it as "no post-deploy evidence", not "never used".
