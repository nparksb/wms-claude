# Cancel Club Parcels Packed State Fix — v2 Migration Assessment

**Date:** 2026-03-27
**Status:** Implemented — Ready for Review
**Priority:** Medium
**Source Plan:** [v1 Cancel Club Parcels Fix](../../wms1/plan/260424-Cancel_Club_Parcels_Packed_State_Fix.md)
**Scope:** v2 WMS (wms2-api), branch `tmp/np106-v1-fixes-migration`

---

## Summary

The v1 plan addressed cancelled club orders incorrectly moving to PACKED state due to missing cancelled-order filtering. The v1 fix touched 3 files with changes across `runClubLine()`, helper methods, and `ManageOrderService`.

**In v2, the core `runClubLine()` fix and ManageOrderService fixes are already present.** However, **5 helper methods in `CustomerorderBatchService` were missing cancelled-order filtering**, causing inflated counts and unnecessary priority updates on cancelled orders.

---

## Migration Analysis

### 1. `runClubLine()` — 6 Changes (A-F)

| Change | Description | v2 Status | Notes |
|--------|------------|-----------|-------|
| **A** | `@Transactional(rollbackFor)` | **Present** (line 546) | v2 correctly uses `tenantTransactionManager` |
| **B** | Batch-state guard | **Present** (line 550) | v2 accepts only state 525 (stricter than v1 which accepts 520+525) |
| **C** | Filter cancelled orders | **Present** (line 594) | `removeIf(state == CANCELED)` |
| **D** | Filter cancelled positions | **Present** (lines 578-580) | Bulk pre-fetch with stream filter (superior to v1) |
| **E** | Re-check before PACKED | **Present** (lines 667-669) | Bulk SQL with `state != 800` guard (superior to v1's per-entity loop) |
| **F** | `requiredAmount = ZERO` + fulfillment check | **Present** (lines 632, 637, 649-654) | Identical to v1 |

**No action needed for `runClubLine()`.**

---

### 2. `isEnoughStockOnStagingLane()` — Already Fixed

v2 `validateStockOnStagingLane()` (lines 464-465) already filters cancelled orders.

---

### 3. `ManageOrderService` — All 3 Methods Already Fixed

| Method | v2 Line | Filter |
|--------|---------|--------|
| `customerOrderReleaseForPicking()` | 127 | `removeIf(state == CANCELED)` |
| `customerOrderPickingStarted()` | 239 | `removeIf(state == CANCELED)` |
| `customerOrderPicked()` | 288 | `removeIf(state == CANCELED)` |

---

### 4. Helper Methods — 5 Methods MISSING Filter (Fixed)

These methods fetched all orders including cancelled ones, inflating counts and applying unnecessary updates.

| Method | Line | Issue | Fix Applied |
|--------|------|-------|-------------|
| `setPriority()` | 158 | Priority set on cancelled orders | Added `removeIf(CANCELED)` |
| `getAmountSKU()` | 391 | SKU count includes cancelled orders; NPE on empty list | Added `removeIf(CANCELED)` + empty guard |
| `getAmountBottles()` | 405 | Bottle count includes cancelled orders | Added `removeIf(CANCELED)` |
| `getAmountParcels()` | 420 | Parcel count includes cancelled orders | Added `removeIf(CANCELED)` |
| `getClubLineSKUOverview()` | 1008 | SKU overview includes cancelled; NPE on empty list | Added `removeIf(CANCELED)` + empty guard |

**Implementation note:** Used `Integer.valueOf(WmsConstants.State.CANCELED).equals(o.getState())` (null-safe) instead of `o.getState() == WmsConstants.State.CANCELED` because `getState()` returns `Integer` wrapper which can be null in test fixtures and potentially in edge cases.

---

## Test Changes

### New Tests Added (2)

| Test | Class | Purpose |
|------|-------|---------|
| `getAmountBottles_excludesCancelledOrders` | `GetAmountBottles` | Verifies cancelled orders' positions not counted in bottle total |
| `getAmountParcels_excludesCancelledOrders` | `GetAmountParcels` | Verifies cancelled orders excluded from parcel count |

### Existing Tests Updated (1)

| Test | Change | Reason |
|------|--------|--------|
| `GetAmountSKUAdditional.returnsZeroWhenBatchHasNoOrders` | Changed from expecting `IndexOutOfBoundsException` to asserting return value 0 | The `getAmountSKU` fix adds an early return when all orders are cancelled/empty, replacing the previous crash with graceful behavior |

### Pre-existing Tests (already in v2)

| Test | Nested Class | Purpose |
|------|-------------|---------|
| `runClubLine_shouldSkipCancelledOrders` | `RunClubLineCancelledOrderTests` | Verifies cancelled orders not packed |
| `runClubLine_shouldThrowWhenBatchStateInvalid` | `RunClubLineCancelledOrderTests` | Verifies batch-state guard |
| `runClubLine_shouldThrowWhenAllOrdersCancelled` | `RunClubLineCancelledOrderTests` | Verifies all-cancelled throws exception |
| `isEnoughStockOnStagingLane_shouldExcludeCancelledOrders` | `RunClubLineCancelledOrderTests` | Verifies stock check excludes cancelled |

---

## Implementation Plan

| Step | Action | File | Risk | Effort | Status |
|------|--------|------|------|--------|--------|
| 1 | Add cancelled-order filter to `setPriority()` | `CustomerorderBatchService.java:158` | Low | Small | **Done** |
| 2 | Add cancelled-order filter + empty guard to `getAmountSKU()` | `CustomerorderBatchService.java:391` | Low | Small | **Done** |
| 3 | Add cancelled-order filter to `getAmountBottles()` | `CustomerorderBatchService.java:405` | Low | Small | **Done** |
| 4 | Add cancelled-order filter to `getAmountParcels()` | `CustomerorderBatchService.java:420` | Low | Small | **Done** |
| 5 | Add cancelled-order filter + empty guard to `getClubLineSKUOverview()` | `CustomerorderBatchService.java:1008` | Low | Small | **Done** |
| 6 | Add `getAmountBottles_excludesCancelledOrders` test | `CustomerorderBatchServiceUnitTest.java` | Low | Small | **Done** |
| 7 | Add `getAmountParcels_excludesCancelledOrders` test | `CustomerorderBatchServiceUnitTest.java` | Low | Small | **Done** |
| 8 | Update `returnsZeroWhenBatchHasNoOrders` test | `CustomerorderBatchServiceUnitTest.java` | Low | Small | **Done** |

---

## Additional Recommendations

### 1. Batch-State Guard Scope (Change B)

v2 only accepts state 525 (`ORDER_BATCH_STAGING_LANE_ASSIGNED`), while v1 accepts both 520 (`ORDER_BATCH_ACTIVATED`) and 525. Verify whether any v2 caller invokes `runClubLine()` when the batch is in state 520. If so, the guard should be relaxed.

### 2. Concurrent Cancellation Observability (Change E)

v2's bulk `updateStateByIds` silently skips cancelled orders (via SQL `state != 800` guard). Consider logging when the updated row count differs from the expected count to detect concurrent cancellation events.

### 3. `getAmountSKU` Repository Call Mismatch (Pre-existing)

v2 line 394 uses `pickingorderPositionRepository.findByCustomerorderpositionId(orders.get(0).getId())` while v1 uses `customerorderPositionRepository.findByOrderId(orders.get(0).getId())`. These query different tables. This is a pre-existing issue unrelated to the cancelled-order fix.

---

## Verification Checklist

- [x] Cancelled-order filtering added to all 5 helper methods
- [x] Null-safe comparison used (`Integer.valueOf().equals()`)
- [x] New tests added for `getAmountParcels` and `getAmountBottles`
- [x] Existing test updated for `getAmountSKU` graceful empty handling
- [x] `CustomerorderBatchServiceUnitTest`: 80 tests, 0 failures
- [x] All related test suites pass (216 total: 80 + 79 + 57)

---

## Current Status

| Area | v2 Fix Status | Tests | Action |
|------|--------------|-------|--------|
| **runClubLine (A-F)** | Complete | 5 tests present | None |
| **isEnoughStockOnStagingLane** | Complete | 1 test present | None |
| **ManageOrderService (3 methods)** | Complete | — | None |
| **setPriority** | **Fixed** | — | Done |
| **getAmountSKU** | **Fixed** | 1 test updated | Done |
| **getAmountBottles** | **Fixed** | 1 new test | Done |
| **getAmountParcels** | **Fixed** | 1 new test | Done |
| **getClubLineSKUOverview** | **Fixed** | — | Done |

### Test Results (2026-03-27, post-implementation)

```
CustomerorderBatchServiceUnitTest: Tests run: 80, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
CustomerorderServiceUnitTest:      Tests run: 79, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
BillofladingServiceUnitTest:       Tests run: 57, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
Total:                             216 tests, 0 failures
```
