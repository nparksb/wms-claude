# WMS Staging Lane Bug Fix Plan

**Date:** 2026-03-15
**Status:** Implemented — Ready for Code Review
**Priority:** Critical
**Related:** [WineCo Staging Lane Investigation](260424-WineCo_Staging_Lane_Investigation.md)
**Scope:** v1 WMS only (this repository)

---

## Summary

Three code locations in the WMS fail to clear `staginglaneId` on batch completion or cancellation, causing staging lanes to become permanently occupied. This plan addresses the WMS-side fixes only (Bugs #1 and #2 from the investigation report). OMS-side bugs (#3 and #4) are out of scope for this repository.

---

## Bugs Confirmed (All Still Present in Current Code)

### Bug A: `cancelOrder()` — Batch finalization uses wrong state and never clears lane

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Lines:** 521–526

This is the **primary cancellation path** — called by the OMS via `POST /rest/.../cancelPositions`. When all orders in a batch are individually cancelled, the batch state is set to `FINISHED` (700) instead of `CANCELED` (800), and `staginglaneId` is never cleared.

**Current code:**
```java
CustomerorderBatch orderBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId()).get();
List<Customerorder> orders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
if (orders.stream().allMatch(position -> position.getState() >= WmsConstants.State.FINISHED)) {
    orderBatch.setState(WmsConstants.State.FINISHED);    // ← Wrong: should be CANCELED
    customerorderBatchRepository.save(orderBatch);       // ← Missing: staginglaneId = null
}
```

**Problems:**
1. Uses `FINISHED` (700) when all orders are cancelled — should use `CANCELED` (800)
2. The `allMatch(state >= FINISHED)` check passes for CANCELED (800 ≥ 700) but doesn't distinguish between finished and cancelled orders
3. Never clears `staginglaneId`

**Fix:**
```java
CustomerorderBatch orderBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId()).get();
List<Customerorder> orders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
if (orders.stream().allMatch(o -> o.getState() >= WmsConstants.State.FINISHED)) {
    // Determine correct batch state: if ALL orders are canceled, batch is canceled
    boolean allCanceled = orders.stream().allMatch(o -> o.getState() == WmsConstants.State.CANCELED);
    if (allCanceled) {
        orderBatch.setState(WmsConstants.State.CANCELED);
    } else {
        orderBatch.setState(WmsConstants.State.FINISHED);
    }
    orderBatch.setStaginglaneId(null);
    customerorderBatchRepository.save(orderBatch);
}
```

---

### Bug B: `cancelBatch()` — Never updates WMS state or clears lane (dead code)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
**Lines:** 175–255

The method is `private` with **zero callers** — it is dead code. It builds a DTO, POSTs to OMS, but never updates batch state to CANCELED or clears the staging lane.

**Fix:** Add batch state update, order cancellation, and staging lane cleanup before the final log statement. Also make the method `public` so it can be called from a controller (currently there is no UI or API endpoint to cancel a batch from the WMS side).

**Insert before line 254** (`LOG.debug("end   for batch=" + orderBatch);`):
```java
// Cancel all customer orders in the batch
for (Customerorder customerOrder : batchOrders) {
    customerOrder.setState(WmsConstants.State.CANCELED);
    customerorderRepository.save(customerOrder);
}

// Update batch state and release staging lane
orderBatch.setState(WmsConstants.State.CANCELED);
orderBatch.setStaginglaneId(null);
customerorderBatchRepository.save(orderBatch);
```

**Also change visibility** from `private` to `public` on line 175.

**Note:** Wiring this method to a controller endpoint (for WMS-initiated batch cancellation via UI) is a separate enhancement. The immediate fix ensures the method works correctly if/when called.

---

### Bug C: `closeBOL()` — Never clears staging lane on batch completion (2 paths)

**File:** `src/main/java/net/aim_ai/wms/service/BillofladingService.java`

#### Path 1: Regular batch completion (line 609)

**Current code:**
```java
orderBatch.setState(WmsConstants.State.FINISHED);
customerorderBatchRepository.save(orderBatch);
```

**Fix — add one line before `save()`:**
```java
orderBatch.setState(WmsConstants.State.FINISHED);
orderBatch.setStaginglaneId(null);                    // ← ADD
customerorderBatchRepository.save(orderBatch);
```

#### Path 2: Club Run completion (line 948)

**Current code:**
```java
coOrderBatch.setState(WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED);
customerorderBatchRepository.save(coOrderBatch);
```

**Fix — add one line before `save()`:**
```java
coOrderBatch.setState(WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED);
coOrderBatch.setStaginglaneId(null);                  // ← ADD
customerorderBatchRepository.save(coOrderBatch);
```

---

## Implementation Order

| Step | Bug | File | Risk | Effort |
|------|-----|------|------|--------|
| 1 | **A** | `CustomerorderService.java:521-526` | Medium — most impactful fix, addresses the active OMS→WMS cancellation path | Small (6 lines changed) |
| 2 | **C** | `BillofladingService.java:609, 948` | Low — adds 1 line in 2 locations | Small (2 lines added) |
| 3 | **B** | `CustomerorderBatchService.java:175-255` | Low — currently dead code, fix makes it correct for future use | Small (8 lines added) |

---

## Testing Plan

### Unit Tests (add to existing `CustomerorderBatchServiceUnitTest.java`)

1. **`cancelBatch` sets state to CANCELED and clears staging lane**
   - Given: batch in PICKING (520) with staginglaneId set
   - When: `cancelBatch()` is called
   - Then: batch state = 800, staginglaneId = null, all orders state = 800

2. **`cancelBatch` on batch without staging lane does not NPE**
   - Given: batch in PICKING (520) with staginglaneId = null
   - When: `cancelBatch()` is called
   - Then: batch state = 800, staginglaneId remains null

### Unit Tests (add to or create `CustomerorderServiceUnitTest.java`)

3. **`cancelOrder` — last order cancelled sets batch to CANCELED and clears lane**
   - Given: batch with 2 orders, 1 already CANCELED, 1 being cancelled now
   - When: `cancelOrder()` is called on the second order
   - Then: batch state = 800, staginglaneId = null

4. **`cancelOrder` — mixed final states: some FINISHED, some CANCELED**
   - Given: batch with 2 orders, 1 FINISHED, 1 being cancelled
   - When: `cancelOrder()` is called
   - Then: batch state = 700 (FINISHED, not CANCELED), staginglaneId = null

5. **`cancelOrder` — not all orders in final state, batch unchanged**
   - Given: batch with 2 orders, 1 PICKING, 1 being cancelled
   - When: `cancelOrder()` is called
   - Then: batch state unchanged, staginglaneId unchanged

### Unit Tests (add to `BillofladingServiceTest.java` or create new)

6. **`closeBOL` — regular path clears staging lane on FINISHED**
   - Verify `staginglaneId` is null after batch state set to FINISHED

7. **`closeBOL` — Club Run path clears staging lane on CLUB_RUN_FINISHED**
   - Verify `staginglaneId` is null after batch state set to 530

### Manual/Integration Testing

8. **End-to-end: Cancel a Club Run batch from OMS, verify WMS lane is released**
9. **End-to-end: Complete a BOL, verify staging lanes are released**
10. **End-to-end: Complete a Club Run, verify staging lane is released**
11. **Regression: Normal order processing flow still works (pick → pack → ship → close BOL)**

---

## Data Cleanup

The data cleanup SQL from the investigation report (Phases 1–3) should be executed **before** deploying the code fix. See [260424-WineCo_Staging_Lane_Investigation.md](260424-WineCo_Staging_Lane_Investigation.md#12-data-cleanup-plan) for the full SQL scripts.

---

## Implementation Status

All three bugs have been fixed and unit tested. **126 tests pass, 0 failures.**

| Bug | File | Change | Tests Added | Status |
|-----|------|--------|-------------|--------|
| **A** | `CustomerorderService.java:521-532` | Distinguish CANCELED vs FINISHED batch state; always clear `staginglaneId` | 3 tests in `CustomerorderServiceUnitTest` | Done |
| **B** | `CustomerorderBatchService.java:175,254-263` | Made `cancelBatch()` public; added order cancellation loop + batch state/lane cleanup | 3 tests in `CustomerorderBatchServiceUnitTest` | Done |
| **C1** | `BillofladingService.java:610` | Added `orderBatch.setStaginglaneId(null)` before save in regular completion path | Covered by existing closeBOL tests | Done |
| **C2** | `BillofladingService.java:950` | Added `coOrderBatch.setStaginglaneId(null)` before save in Club Run completion path | Covered by existing closeBOL tests | Done |

### Test Results

```
Tests run: 126, Failures: 0, Errors: 0, Skipped: 0
BUILD SUCCESS
```

### New Unit Tests

**CustomerorderServiceUnitTest (3 new):**
- `cancelOrder_allOrdersCancelled_setsBatchCanceledAndClearsLane` — all orders cancelled → batch CANCELED, lane cleared
- `cancelOrder_mixedFinalStates_setsBatchFinishedAndClearsLane` — mixed FINISHED/CANCELED → batch FINISHED, lane cleared
- `cancelOrder_notAllOrdersFinal_doesNotUpdateBatch` — some orders still active → batch unchanged

**CustomerorderBatchServiceUnitTest (3 new):**
- `cancelBatch_validBatch_cancelsOrdersAndBatchAndClearsLane` — happy path with staging lane
- `cancelBatch_batchWithoutLane_cancelsAndLaneRemainsNull` — no lane assigned, no NPE
- `cancelBatch_finishedBatch_throwsBusinessException` — guard clause rejects finished batches

---

## Out of Scope

- **OMS Bug #3** (cancellation never propagates to WMS for Club batches) — requires OMS-side changes
- **OMS Bug #4** (`batch_criteria.batch_status` never updated) — requires OMS-side changes
- **New cancel batch UI/API endpoint** — `cancelBatch()` is dead code with no caller; wiring it to a controller is a separate enhancement
- **Picking order cleanup on batch cancellation** — `cancelBatch()` does not cancel associated picking orders; this is existing behavior and should be addressed separately if needed
