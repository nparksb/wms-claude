# Tote / Pickingorder Disconnect — Implementation Plan

- **Date:** 2026-03-18
- **Status:** Implemented & Tests Passing
- **Priority:** High
- **Based on:** `docs/plan/260424-Tote_Pickingorder_Disconnect_Fix.md`

---

## Implementation Status

All 4 fixes have been implemented and verified:

| Fix | Status | Tests |
|-----|--------|-------|
| #1 — Filter tote assignment by current picking order | Done | `processPick_ToteAssignment_OnlyUpdatesCurrentPickingOrderPositions` |
| #2 — Check ALL positions for STARTED state | Done | `setPickingDate_withMultiplePickingOrders_oneStarted_throwsBusinessException` |
| #3 — Clean up orphaned picking orders | Done | `setPickingDate_deletesPositions_cancelsOrphanedPickingOrders`, `setPickingDate_deletesPositions_skipsPickingOrderWithRemainingPositions` |
| #4 — Allow tote reuse from finished orders | Done | `processPick_ToteReuse_ClearsStaleReferenceFromFinishedOrder` |

**Test results:** 117 tests run, 0 failures, 0 errors (42 CustomerorderServiceUnitTest + 75 MobilePickingServiceUnitTest)

---

## Fix #1 — Filter tote assignment by current picking order

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`
**Lines:** 430-435

**Problem:** The tote assignment loop sets `picktounitloadId` on ALL `PickingorderPosition` records for a customer order, including positions belonging to other picking orders (e.g. orphaned or cancelled ones).

**Change:** Add a guard so only positions belonging to the current `pickingOrder` are updated.

```java
// CURRENT (line 430-435)
for (CustomerorderPosition orderPosition : customerorderPositionRepository.findByOrderId(customerOrder.getId()) ) {
    for (PickingorderPosition pickPos : pickingorderPositionRepository.findByCustomerorderpositionId(orderPosition.getId()) ) {
        pickPos.setPicktounitloadId(pickingUnitLoad.getId());
        pickingorderPositionRepository.save(pickPos);
    }
}

// FIXED
for (CustomerorderPosition orderPosition : customerorderPositionRepository.findByOrderId(customerOrder.getId()) ) {
    for (PickingorderPosition pickPos : pickingorderPositionRepository.findByCustomerorderpositionId(orderPosition.getId()) ) {
        if (pickPos.getPickingorderId().equals(pickingOrder.getId())) {
            pickPos.setPicktounitloadId(pickingUnitLoad.getId());
            pickingorderPositionRepository.save(pickPos);
        }
    }
}
```

**Risk:** Low. Only adds a filter — positions from other picking orders are simply skipped.

---

## Fix #2 — Check ALL positions for STARTED state

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Lines:** 217-219

**Problem:** The STARTED-state check fetches positions from only the first picking order found (`poPositions.get(0).getPickingorderId()`). If the customer order spans multiple picking orders, actively-picked positions on a second picking order are missed.

**Change:** Check the already-fetched `poPositions` list directly instead of re-querying a single picking order.

```java
// CURRENT (lines 217-219)
List<PickingorderPosition> poPositionsMerged = pickingorderPositionRepository.findByPickingorderId(poPositions.get(0).getPickingorderId());
boolean hasPickingStated = poPositionsMerged.stream().anyMatch(p -> p.getState() >= WmsConstants.State.STARTED);
if (!poPositions.isEmpty() && hasPickingStated) {

// FIXED (removes one DB query, uses correct dataset)
boolean hasPickingStarted = poPositions.stream().anyMatch(p -> p.getState() >= WmsConstants.State.STARTED);
if (hasPickingStarted) {
```

**Risk:** Low. `poPositions` already contains all picking positions for this customer order (joined via parcel external number). This is strictly more correct than the original.

---

## Fix #3 — Clean up orphaned picking orders and unitloads

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Lines:** After the deletion loop (after current line 235)

**Problem:** After deleting picking order positions during a picking-date change, the parent `Pickingorder` and `PickingorderUnitload` records are left behind with no positions. These orphans participate in Bug #1's cross-contamination on subsequent picks.

**Change:** After the deletion loop, collect distinct picking order IDs, check each for remaining positions, and cancel empty ones along with their unitloads.

```java
// NEW — insert after the position deletion loop (after line 235, before the closing brace)

// Collect distinct picking order IDs from the deleted positions
Set<Long> affectedPickingorderIds = new HashSet<>();
for (PickingorderPosition position : poPositions) {
    affectedPickingorderIds.add(position.getPickingorderId());
}

// Cancel any picking orders that now have zero remaining positions
for (Long pickingorderId : affectedPickingorderIds) {
    List<PickingorderPosition> remaining = pickingorderPositionRepository.findByPickingorderId(pickingorderId);
    if (remaining.isEmpty()) {
        // Cancel associated unitloads
        for (PickingorderUnitload pul : pickingorderUnitloadRepository.findByPickingorderId(pickingorderId)) {
            pul.setHistorytote(pul.getCustomerordernumber());
            pul.setUnitloadId(null);
            pul.setState(WmsConstants.State.CANCELED);
            pickingorderUnitloadRepository.save(pul);
        }
        // Cancel the picking order itself
        pickingorderRepository.findById(pickingorderId).ifPresent(po -> {
            po.setState(WmsConstants.State.CANCELED);
            pickingorderRepository.save(po);
        });
    }
}
```

**Required imports** in `CustomerorderService.java`:
- `java.util.HashSet`
- `java.util.Set`
- `net.aim_ai.wms.model.PickingorderUnitload` (verify if already imported)

**Required injections** in `CustomerorderService.java`:
- `PickingorderUnitloadRepository pickingorderUnitloadRepository` (verify if already injected)
- `PickingorderRepository pickingorderRepository` (verify if already injected)

**Note on `setHistorytote()`:** The `forceCancelOrder()` method at line 287 uses `pickingTote.getLabelid()` for `historytote`. Here we don't have the tote entity loaded, so we use the customer order number stored on the unitload as a reference. Alternatively, load the `Unitload` from `pul.getUnitloadId()` to get the label — but `unitloadId` may already be null if the tote was never fully assigned. Using `customerordernumber` is safe.

**Risk:** Medium. Must verify:
1. That `findByPickingorderId` on `PickingorderPositionRepository` is called AFTER the `delete()` calls have flushed (they should be, since `delete()` is synchronous within the transaction).
2. That no downstream code expects to find these picking orders in a non-cancelled state.

---

## Fix #4 — Allow tote reuse when old order has finished picking

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`
**Lines:** 382-387

**Problem:** When a tote is scanned, the code unconditionally throws "belongs to different order!" if any customer order references it via `pickingtoteId`, even if that order has already finished picking. Since `pickingtoteId` is intentionally kept for downstream packing, this permanently blocks tote reuse.

**Change:** Check the old order's state. If picking is done (state >= PICKED), clear the stale reference and allow reuse.

```java
// CURRENT (lines 382-387)
Optional<Customerorder> possibleOldCustomerOrderOpt = customerorderRepository.getOrderByToteLabelId(toteName);

if (possibleOldCustomerOrderOpt.isPresent()) {
    LOG.debug("tote=" + toteName + " already/still bound to order=" + possibleOldCustomerOrderOpt.get().getId());
    throw new BusinessException(toteName + " belongs to different order!");
}

// FIXED
Optional<Customerorder> possibleOldCustomerOrderOpt = customerorderRepository.getOrderByToteLabelId(toteName);

if (possibleOldCustomerOrderOpt.isPresent()) {
    Customerorder oldOrder = possibleOldCustomerOrderOpt.get();
    if (oldOrder.getState() >= WmsConstants.State.PICKED) {
        // Old order finished picking — clear stale tote reference to allow reuse
        LOG.debug("tote=" + toteName + " clearing stale reference from finished order=" + oldOrder.getId());
        oldOrder.setPickingtoteId(null);
        customerorderRepository.save(oldOrder);
    } else {
        LOG.debug("tote=" + toteName + " already/still bound to active order=" + oldOrder.getId());
        throw new BusinessException(toteName + " belongs to different order!");
    }
}
```

**Risk:** Low-Medium. The `historytote` field (set at line 413) already stores the tote label for downstream reference, so clearing `pickingtoteId` after picking is safe. Verify that no downstream packing/shipping logic relies on `pickingtoteId` after the order reaches PICKED state.

---

## Implementation Order

1. **Fix #1** (tote assignment filter) — highest impact, prevents the core disconnect
2. **Fix #2** (STARTED state check) — prevents data loss from deleting active picks
3. **Fix #3** (orphan cleanup) — prevents accumulation of orphans that trigger Bug #1
4. **Fix #4** (tote reuse) — quality-of-life for pickers, lower urgency

Fixes #1-#3 address the root cause chain. Fix #4 is independent.

---

## Files to Modify

| File | Changes |
|------|---------|
| `src/main/java/.../service/mobile/MobilePickingService.java` | Fix #1 (line ~431): add `pickingorderId` guard. Fix #4 (lines 384-387): state-aware tote reuse. |
| `src/main/java/.../service/CustomerorderService.java` | Fix #2 (lines 218-220): check `poPositions` directly. Fix #3 (after line 235): orphan cleanup block. |

---

## Testing Plan

### Unit Tests to Update

**`MobilePickingServiceUnitTest`:**
- Existing `processPick` tests must set `pickingorderId` on test `PickingorderPosition` objects so the new filter in Fix #1 matches correctly.
- Add test: `processPick_ToteAssignment_OnlyUpdatesCurrentPickingOrderPositions` — create positions for two different picking orders under the same customer order; verify only the current picking order's positions get `picktounitloadId` set.
- Add test: `processPick_ToteReuse_ClearsStaleReferenceFromFinishedOrder` — set up an old customer order with state >= PICKED referencing the tote; verify `pickingtoteId` is cleared and no exception is thrown.
- Existing test `processPick_PickingUnitLoadNullToteBelongsToDifferentOrder_ThrowsBusinessException` should still pass (old order state < PICKED).

**`CustomerorderServiceUnitTest`:**
- Remove or update the `findByPickingorderId` stub that is no longer called (Fix #2 removes that query).
- Add test: `setPickingDate_withMultiplePickingOrders_oneStarted_throwsBusinessException` — positions span two picking orders, second one has STARTED positions; verify the exception is thrown.
- Add test: `setPickingDate_deletesPositions_cancelsOrphanedPickingOrders` — verify that after position deletion, empty picking orders and their unitloads are set to CANCELED state.

### Manual QA

- [ ] Pick an order — verify tote assignment only links positions from the current picking order
- [ ] Change picking date on an order with picking positions — verify orphaned picking orders are cancelled
- [ ] Reuse a tote from a completed (PICKED+) order — should succeed
- [ ] Attempt to reuse a tote from an in-progress order — should throw "belongs to different order!"
- [ ] Query DB after picking-date change: no `pickingorder` records with 0 positions in non-cancelled state

---

## Risks & Considerations

1. **Fix #3 flush ordering:** The `delete()` calls must be flushed before `findByPickingorderId()` is called to check for remaining positions. Spring Data JPA `delete()` within the same transaction should flush by default, but if issues arise, an explicit `pickingorderPositionRepository.flush()` can be added before the orphan cleanup block.

2. **Fix #4 downstream impact:** Verify that no code after the PICKED state reads `pickingtoteId` for packing/shipping logic. The `historytote` field (String label) is the intended downstream reference. Grep for `getPickingtoteId` and `pickingtote_id` usage beyond MobilePickingService to confirm.

3. **Concurrency:** Fix #4 clears `pickingtoteId` on the old order. If two pickers simultaneously try to reuse the same tote, there's a small race window. The existing optimistic locking on `Customerorder` (via `@Version`) should handle this — the second save would fail and retry.

4. **v2 codebase:** Per the original report, these bugs exist in both v1 and v2. This plan covers v1 only. A follow-up should port these fixes to v2.
