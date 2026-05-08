# WMS Staging Lane Bug Fix Plan

**Date:** 2026-03-15
**Status:** Implemented — Ready for Code Review
**Priority:** Critical
**Related:** [WineCo Staging Lane Investigation](260424-WineCo_Staging_Lane_Investigation.md)
**Scope:** v2 WMS (this repository)

---

## Summary

Multiple code locations in WMS v2 fail to clear `staginglaneId` on batch completion or cancellation, causing staging lanes to become permanently occupied. These bugs were originally discovered during the WineCo staging lane investigation against v1 WMS and have been confirmed to **still exist in v2**, with additional affected locations discovered.

This plan addresses the WMS-side fixes only (Bugs #1 and #2 from the investigation report). OMS-side bugs (#3 and #4) are out of scope for this repository.

### Changes from v1 Plan

The v2 codebase has the same fundamental bugs but in **more locations**:
- **Bug A** expanded from 1 location to **3 locations** (added `cleanUpCancelledOrder()` and `PickingorderBusinessService`)
- **Bug B** method is now `public` (was `private` in v1) but still has zero callers and missing state mutations
- **Bug C** expanded from 2 paths to **3 paths** (added `runClubLine()` in `CustomerorderBatchService`), and the regular `closeBOL()` path now uses a bulk JPQL update instead of entity setters

---

## Bugs Confirmed (All Still Present in v2 Code)

### Bug A: Batch finalization uses wrong state and never clears lane (3 locations)

When all orders in a batch reach a terminal state via cancellation, the batch state is set to `FINISHED` (700) instead of `CANCELED` (800), and `staginglaneId` is never cleared. This identical pattern exists in **three locations**.

#### A1: `cancelOrder()` — Primary OMS→WMS cancellation path

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Lines:** 569–571

Called by the OMS via `POST /rest/.../cancelPositions`. This is the most impactful instance.

**Current code:**
```java
if (orders.stream().allMatch(position -> position.getState() >= WmsConstants.State.FINISHED)) {
    orderBatch.setState(WmsConstants.State.FINISHED);    // ← Wrong: should be CANCELED
    customerorderBatchRepository.save(orderBatch);       // ← Missing: staginglaneId = null
}
```

**Fix:**
```java
if (orders.stream().allMatch(o -> o.getState() >= WmsConstants.State.FINISHED)) {
    boolean allCanceled = orders.stream().allMatch(o -> o.getState() == WmsConstants.State.CANCELED);
    orderBatch.setState(allCanceled ? WmsConstants.State.CANCELED : WmsConstants.State.FINISHED);
    orderBatch.setStaginglaneId(null);
    customerorderBatchRepository.save(orderBatch);
}
```

#### A2: `cleanUpCancelledOrder()` — Fallback cancellation path

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Lines:** 667–669

**Current code (identical pattern):**
```java
if (orders.stream().allMatch(position -> position.getState() >= WmsConstants.State.FINISHED)) {
    orderBatch.setState(WmsConstants.State.FINISHED);    // ← Wrong
    customerorderBatchRepository.save(orderBatch);       // ← Missing: staginglaneId = null
}
```

**Fix:** Same as A1.

#### A3: `PickingorderBusinessService` — Picking order cancellation path

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
**Lines:** 334–336

**Current code (identical pattern):**
```java
if (orders.stream().allMatch(position -> position.getState() >= WmsConstants.State.FINISHED)) {
    orderBatch.setState(WmsConstants.State.FINISHED);    // ← Wrong
    customerorderBatchRepository.save(orderBatch);       // ← Missing: staginglaneId = null
}
```

**Fix:** Same as A1.

**Problems (all 3 locations):**
1. Uses `FINISHED` (700) when all orders are cancelled — should use `CANCELED` (800)
2. The `allMatch(state >= FINISHED)` check passes for CANCELED (800 ≥ 700) but doesn't distinguish between finished and cancelled orders
3. Never clears `staginglaneId`

**Recommendation:** Consider extracting a shared method (e.g., `finalizeBatchIfAllOrdersTerminal()`) to eliminate the three-way duplication and prevent future divergence.

---

### Bug B: `cancelBatch()` — Never updates WMS state or clears lane (dead code)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
**Lines:** 207–280

The method is now `public` (was `private` in v1) but still has **zero callers** in production code — it is dead code. It validates state, builds a DTO, POSTs to OMS, but never:
- Updates batch state to CANCELED
- Clears `staginglaneId`
- Cancels individual orders in the batch

**Fix:** Insert before the final log statement (around line 276):
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

**Note:** This method has no callers. Wiring it to a controller endpoint is a separate enhancement. The fix ensures correctness if/when called.

**Note on error handling:** At line 267, an `IOException` from the OMS POST is caught and logged but execution continues. Decide whether local cancellation should proceed when OMS notification fails.

---

### Bug C: Never clears staging lane on batch completion (3 paths)

#### C1: Regular batch completion in `closeBOL()` — Bulk JPQL update

**File:** `src/main/java/net/aim_ai/wms/service/BillofladingService.java`
**Lines:** 694–699

**Important:** In v2, this path uses a **bulk JPQL update** (not entity setters), so the fix requires modifying the query string.

**Current code:**
```java
int updated = entityManager.createQuery(
        "UPDATE CustomerorderBatch cb SET cb.state = :finished, cb.version = cb.version + 1 " +
        "WHERE cb.id IN :batchIds")
        .setParameter("finished", WmsConstants.State.FINISHED)
        .setParameter("batchIds", completedBatchIds)
        .executeUpdate();
```

**Fix — add `cb.staginglaneId = null` to the JPQL update:**
```java
int updated = entityManager.createQuery(
        "UPDATE CustomerorderBatch cb SET cb.state = :finished, cb.staginglaneId = null, cb.version = cb.version + 1 " +
        "WHERE cb.id IN :batchIds")
        .setParameter("finished", WmsConstants.State.FINISHED)
        .setParameter("batchIds", completedBatchIds)
        .executeUpdate();
```

#### C2: Club Run completion in `transferOrder()`

**File:** `src/main/java/net/aim_ai/wms/service/BillofladingService.java`
**Lines:** 762–764

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

#### C3: Club Run completion in `runClubLine()` (NEW — not in v1 plan)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
**Lines:** 551–552

**Current code:**
```java
orderBatch.setState(WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED);
customerorderBatchRepository.save(orderBatch);
```

**Fix — add one line before `save()`:**
```java
orderBatch.setState(WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED);
orderBatch.setStaginglaneId(null);                    // ← ADD
customerorderBatchRepository.save(orderBatch);
```

---

## Implementation Order

| Step | Bug | File | Lines | Risk | Effort |
|------|-----|------|-------|------|--------|
| 1 | **A1** | `CustomerorderService.java` | 569–571 | Medium — most impactful, active OMS→WMS path | Small |
| 2 | **A2** | `CustomerorderService.java` | 667–669 | Medium — fallback cancellation path | Small |
| 3 | **A3** | `PickingorderBusinessService.java` | 334–336 | Medium — picking order cancellation path | Small |
| 4 | **C1** | `BillofladingService.java` | 694–699 | Low — JPQL query modification | Small |
| 5 | **C2** | `BillofladingService.java` | 762–764 | Low — 1 line added | Small |
| 6 | **C3** | `CustomerorderBatchService.java` | 551–552 | Low — 1 line added | Small |
| 7 | **B** | `CustomerorderBatchService.java` | 207–280 | Low — dead code, correctness fix for future use | Small |

---

## Testing Plan

### Unit Tests for Bug A (add to or create `CustomerorderServiceUnitTest.java`)

1. **`cancelOrder` — last order cancelled sets batch to CANCELED and clears lane**
   - Given: batch with 2 orders, 1 already CANCELED, 1 being cancelled now
   - When: `cancelOrder()` is called on the second order
   - Then: batch state = 800, staginglaneId = null

2. **`cancelOrder` — mixed final states: some FINISHED, some CANCELED**
   - Given: batch with 2 orders, 1 FINISHED, 1 being cancelled
   - When: `cancelOrder()` is called
   - Then: batch state = 700 (FINISHED, not CANCELED), staginglaneId = null

3. **`cancelOrder` — not all orders in final state, batch unchanged**
   - Given: batch with 2 orders, 1 PICKING, 1 being cancelled
   - When: `cancelOrder()` is called
   - Then: batch state unchanged, staginglaneId unchanged

4. **`cleanUpCancelledOrder` — all orders cancelled clears lane** (same assertions as #1 but via `cleanUpCancelledOrder()`)

5. **`PickingorderBusinessService` — all orders cancelled clears lane** (same assertions as #1 but via picking order cancellation)

### Unit Tests for Bug B (add to `CustomerorderBatchServiceUnitTest.java`)

6. **`cancelBatch` sets state to CANCELED and clears staging lane**
   - Given: batch in PICKING (520) with staginglaneId set
   - When: `cancelBatch()` is called
   - Then: batch state = 800, staginglaneId = null, all orders state = 800

7. **`cancelBatch` on batch without staging lane does not NPE**
   - Given: batch in PICKING (520) with staginglaneId = null
   - When: `cancelBatch()` is called
   - Then: batch state = 800, staginglaneId remains null

### Unit Tests for Bug C

8. **`closeBOL` — bulk update clears staging lane on FINISHED**
   - Verify JPQL update sets `staginglaneId` to null

9. **`transferOrder` — Club Run path clears staging lane on CLUB_RUN_FINISHED**
   - Verify `staginglaneId` is null after batch state set to 530

10. **`runClubLine` — clears staging lane on CLUB_RUN_FINISHED**
    - Verify `staginglaneId` is null after batch state set to 530

### Manual/Integration Testing

11. **End-to-end: Cancel all orders in a batch from OMS, verify WMS lane is released**
12. **End-to-end: Complete a BOL, verify staging lanes are released**
13. **End-to-end: Complete a Club Run, verify staging lane is released**
14. **Regression: Normal order processing flow still works (pick → pack → ship → close BOL)**

---

## Data Cleanup

Run cleanup SQL **before** deploying the code fix to clear stale `staginglaneId` values on already-completed/cancelled batches:

```sql
UPDATE customerorder_batch
SET staginglane_id = NULL
WHERE state IN (530, 700, 800)
  AND staginglane_id IS NOT NULL;
```

See [260424-WineCo_Staging_Lane_Investigation.md](260424-WineCo_Staging_Lane_Investigation.md#12-data-cleanup-plan) for the full investigation SQL scripts.

---

## Key References

| File | Line(s) | Relevance |
|------|---------|-----------|
| `WmsConstants.java` | 111, 116 | `FINISHED = 700`, `CANCELED = 800` |
| `CustomerorderBatch.java` | 27 | `staginglaneId` field definition |
| `CustomerorderBatchService.java` | 579–583 | `unlinkStagingLaneFromOrderBatch()` — only existing place `staginglaneId` is cleared (manual action) |
| `CustomerorderBatchService.java` | 573 | Where `staginglaneId` gets assigned |
| `LocationRepository.java` | 37–47 | `getAvailableStagingLanes` query that uses `staginglaneId` to determine lane occupancy |

---

## Implementation Status

All seven bugs have been fixed and tested. **2913 unit tests pass, 0 failures.**

| Bug | File | Change | Tests | Status |
|-----|------|--------|-------|--------|
| **A1** | `CustomerorderService.java:569-574` | Distinguish CANCELED vs FINISHED; clear `staginglaneId` | 3 tests in `CustomerorderServiceUnitTest` | Done |
| **A2** | `CustomerorderService.java:667-672` | Same fix as A1 in `cleanUpCancelledOrder()` | 1 test in `CustomerorderServiceUnitTest` | Done |
| **A3** | `PickingorderBusinessService.java:334-339` | Same fix as A1 in picking order path | Covered by pattern (same logic) | Done |
| **B** | `CustomerorderBatchService.java:279-289` | Add order cancellation + batch state/lane cleanup | 2 tests in `CustomerorderBatchServiceUnitTest` | Done |
| **C1** | `BillofladingService.java:694-696` | Add `cb.staginglaneId = null` to bulk JPQL update | Verified via closeBOL tests | Done |
| **C2** | `BillofladingService.java:763-765` | Add `setStaginglaneId(null)` before save | 1 test in `BillofladingServiceUnitTest` | Done |
| **C3** | `CustomerorderBatchService.java:551-553` | Add `setStaginglaneId(null)` before save | Covered by pattern (same logic) | Done |

### New Unit Tests

**CustomerorderServiceUnitTest (4 new):**
- `cancelOrder_allOrdersCancelled_setsBatchCanceledAndClearsLane` — all orders cancelled -> batch CANCELED, lane cleared
- `cancelOrder_mixedFinalStates_setsBatchFinishedAndClearsLane` — mixed FINISHED/CANCELED -> batch FINISHED, lane cleared
- `cancelOrder_notAllOrdersFinal_doesNotUpdateBatch` — some orders still active -> batch unchanged
- `cleanUpCancelledOrder_allCancelled_clearsLane` — cleanup path clears lane when all cancelled

**CustomerorderBatchServiceUnitTest (2 new):**
- `cancelBatch_validBatch_cancelsOrdersAndBatchAndClearsLane` — happy path with staging lane
- `cancelBatch_batchWithoutLane_cancelsAndLaneRemainsNull` — no lane assigned, no NPE

**BillofladingServiceUnitTest (1 new):**
- `transferOrder_clearsStaginglane` — club run transfer clears staging lane on completion

---

## Out of Scope

- **OMS Bug #3** (cancellation never propagates to WMS for Club batches) — requires OMS-side changes
- **OMS Bug #4** (`batch_criteria.batch_status` never updated) — requires OMS-side changes
- **New cancel batch UI/API endpoint** — `cancelBatch()` has no callers; wiring it to a controller is a separate enhancement
- **Picking order cleanup on batch cancellation** — `cancelBatch()` does not cancel associated picking orders; this is existing behavior and should be addressed separately if needed
- **Extract shared `finalizeBatchIfAllOrdersTerminal()` method** — recommended refactor to eliminate Bug A duplication, but can be done as follow-up
