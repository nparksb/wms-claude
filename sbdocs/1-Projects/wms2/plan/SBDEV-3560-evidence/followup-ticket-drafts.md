---
source_ticket: SBDEV-3560
status: FILED 2026-09-28 — SBDEV-3561, 3562, 3563, 3564 (in that order below); all linked to SBDEV-3560
list: Fulfillment Development Backlog (901103718309)
tags: 1-wms, wmsv2
type: Bug
related: SBDEV-3560 (wms2-web-ui PR #148)
---

# Follow-up tickets proposed from SBDEV-3560

## 1. [WMS v2] "Change Source Stock Unit" has never worked; enabling it needs a backend state guard
Priority: normal · Tier: **T3** (stock reservations, data integrity) · Repos: wms2-api, wms2-web-ui

**Symptom.** In the Replenishment → Open Requests row menu, "Change Source Stock Unit" does nothing. `components/internalOps/replenishment/open/updateStockUnitPop.vue` dispatches `internalOps/replenishments/updateStockUnit`, and that action does not exist. The existing action is `updateSourceStockUnit`, which posts the same `{id, stockUnitId}` payload to `POST /replenishOrder/updateStockUnit`. Vuex drops an unknown dispatch without any error, so the write never happens. `git log -S` shows the wrong name has been there since the initial check-in.

**Why it isn't a one-line fix.** Pointing the component at the real action turns on a live stock-reservation move, and the backend isn't safe for that:
- `ReplenishorderService.redirectSource` has no state check. The menu appears for every open row, so an operator could move the source reservation of a STARTED order while someone is picking it.
- Its reserved-amount guard is inverted: `BigDecimal.ZERO.compareTo(stockUnit.getReservedamount()) > 0` throws only when the reservation is *negative*. The list query filters `reservedAmount = 0` when it loads, so the guard only matters if a reservation lands between load and submit.

**Fix.**
- API: reject the move unless the order is in a pre-start state. Reject `reserved > 0`, not `< 0`. Add ITs for both.
- UI: dispatch `updateSourceStockUnit` and gate the close on the result, as done for SBDEV-3560. The round-3 commit `e58d08e` on that branch did exactly this before it was reverted, and its tests can be reused.

**AC**
- [ ] A move on an order in STARTED or a later state is refused with a 422 that names the state. IT covers it.
- [ ] A move onto a stock unit with `reserved > 0` is refused. IT covers it.
- [ ] Choosing a unit in the dialog updates the order's source. The dialog closes only on success.
- [ ] A test asserts that the dispatched action name is a key of the store module's `actions`.

## 2. [WMS v2] Batch endpoints abort after a partial commit when an id is missing, so the UI can't tell anything was applied
Priority: normal · Tier: T2 · Repo: wms2-api

**Symptom.** Several batch endpoints loop over ids and give each id its own transaction and error. But they look the entity up with `orElseThrow(EntityNotFoundException)` *outside* the per-id `try`:
- `GoodsReceiptPositionController` delete and adjust (the `findById(goodsId)` lookup)
- `CycleCountController.cancel`
- `AdviceController.closeMultipleInboundBol`

A stale id (for example, a row deleted in another tab) throws a 404 after the earlier ids have already committed. The whole response becomes a non-2xx, so the UI can't see that anything was applied. It shows "network or server issue", and under SBDEV-3560's batch rule its dialog stays open even though rows changed.

SBDEV-3560 handles the UI side by reloading the list in the catch. The real fix belongs in the API.

**Fix.** Move each lookup inside the per-id try and report a missing id as a per-id error, the same pattern as SBDEV-2632.

**AC**
- [ ] For each of the 4 endpoints, an IT sends a batch where one id is missing and asserts: 200, the other ids applied, and one error naming the missing id.
- [ ] Existing ITs and suite results are unchanged.

## 3. [WMS v2] Fixed location: any decimal upper/middle/lower bound fails with a 500
Priority: low · Tier: T1 · Repo: wms2-api (optionally wms2-web-ui)

**Symptom.** `components/masterData/location/fixedLocations/updateBound.vue` accepts decimals (it only checks `Number()` and that the value isn't negative) and sends `parseFloat(value)`. `FixLocationAssignmentController` setUpperBound, setMiddleBound and setLowerBound do `(Integer) reqMap.get("value")`, so a value like 5.5 throws a ClassCastException, which comes back as a 500.

Since SBDEV-3560 the dialog keeps the typed value. The operator therefore sees a "network or server issue" toast and can retry forever.

**Fix.** Decide whether bounds are whole numbers:
- If they are: reject decimals in the UI with a clear message, and have the API parse the value with `Number.intValue()` or return a 422.
- If they aren't: parse it as a `BigDecimal`.

**AC**
- [ ] Entering 5.5 gives either a clear validation message or a saved bound, never a 500.
- [ ] A controller unit test covers a decimal value.

## 4. [WMS v2] Fixed location delete leaves the row on screen, because the store commits a mutation that doesn't exist
Priority: low · Tier: T0/T1 · Repo: wms2-web-ui

**Symptom.** `store/masterData/fixedLocation.js` `deleteFixedLocation` commits `removeDeletedSection` after a successful delete. That mutation exists only in `store/masterData/section.js`. Vuex drops an unknown commit silently, so the deleted row stays in the table until the page is reloaded.

SBDEV-3560 fixed the sibling bug in the same file: `moveFixedLocation` committed `setShowDialog`, which also doesn't exist, so its dialog never closed.

**Fix.** Dispatch `getFixedLocations`, or add a real `removeDeletedFixedLocation` mutation. Also sweep the module for any other commit whose name isn't in its `mutations`.

**AC**
- [ ] After a successful delete, the row disappears without a reload.
- [ ] A test asserts that every mutation name committed in `store/masterData/fixedLocation.js` is a key of that module's `mutations`.
