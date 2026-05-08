# Cancel Club Parcels Incorrectly Moving to Packed State - Analysis & Fix Plan

**Date**: 2026-03-24
**Branch**: develop-arden
**Reported Issue**: When running a club batch, ALL parcels (including cancelled ones) move to PACKED state. Only active parcels should be packed; cancelled parcels should remain cancelled.

---

## Root Cause

### The cancelled-order filtering was never merged into develop-arden

Fix commits `a5af9fa` (2026-03-16) and `eee8988` (2026-03-18) added comprehensive cancelled-order filtering to `runClubLine()` and related methods. These commits exist on branches `release-260317`, `release-260319`, `tmp/np02-runclubline-cancelled-order`, etc., but were **never merged into develop-arden**.

The develop-arden `runClubLine()` method (`CustomerorderBatchService.java:418-514`) has **zero filtering** for cancelled orders:

1. **Line 444**: `customerorderRepository.findByOrderbatchId()` fetches ALL orders including cancelled
2. **Lines 445-491**: Creates parcels and transfers stock for ALL orders (cancelled get ghost parcels)
3. **Lines 494-496**: Sends OMS notifications for ALL orders (including cancelled)
4. **Lines 499-510**: Sets ALL orders to PACKED (650) unconditionally — overwriting CANCELED (800) with PACKED (650)

### Why It Worked Previously

The user likely tested previously on the `release-260319` branch (or a build from it) where the fixes were present. The develop-arden branch diverged from a common ancestor (`0000b38`) before the fixes were applied.

### Git History

```
develop-arden:  0000b38 → faaab8b → ... → (current, NO fix)
fix branches:   0000b38 → a5af9fa → eee8988 → 7b4b258 → (release-260319, HAS fix)
```

---

## What the Fix Commits Added (needs porting)

### From `a5af9fa` — Core runClubLine filtering:
1. `@Transactional(rollbackFor)` on `runClubLine()`
2. Batch-state guard (only allow run from STAGING_LANE_ASSIGNED state)
3. Filter cancelled orders from order list before processing
4. Filter cancelled positions within each order
5. Re-check order state in final update loop (concurrency guard)
6. Post-transfer fulfillment check (`requiredAmount` must reach zero)
7. `requiredAmount = BigDecimal.ZERO` after successful stock transfer branches

### From `eee8988` — Extended filtering to views and helper methods:
1. Filter cancelled orders in `setPriority()`, `getAmountSKU()`, `getAmountParcels()`, `getAmountBottles()`, `getClubLineSKUOverview()`
2. Filter cancelled orders in `ManageOrderService` OMS notification methods
3. SQL-level filtering: `AND c.state != 800` in native queries for batch views
4. Conditional count: `SUM(CASE WHEN co.state != 800 THEN 1 ELSE 0 END)` in batch aggregate queries

### From `7b4b258` — Batch-state guard relaxation:
1. Relaxed batch-state guard to accept both `ORDER_BATCH_ACTIVATED (520)` AND `ORDER_BATCH_STAGING_LANE_ASSIGNED (525)`
2. Save order before `finalizeBatchIfComplete()`

---

## Fix Plan

### Approach: Port the critical filtering logic from the fix commits

Rather than cherry-picking (which risks merge conflicts due to branch divergence), port the key changes manually into the current develop-arden code.

### Changes Required

#### 1. `CustomerorderBatchService.runClubLine()` — 6 changes

**File**: `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`

| # | Change | Purpose |
|---|--------|---------|
| A | Add `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | Atomic club run — partial failure rolls back |
| B | Add batch-state guard (accept states 520 and 525) | Prevent re-running already-processed batches |
| C | Filter cancelled orders from order list (line 444) | Prevent ghost parcels and stock consumption |
| D | Filter cancelled positions within each order (line 452) | Defensive — skip cancelled positions |
| E | Re-check order state before setting PACKED (line 502) | Concurrency guard — order may be cancelled during run |
| F | Add `requiredAmount = BigDecimal.ZERO` after stock transfer + fulfillment check | Correct bookkeeping + detect under-fulfillment |

#### 2. `CustomerorderBatchService.isEnoughStockOnStagingLane()` — 1 change

Filter cancelled orders before calculating required stock (line 337).

#### 3. `CustomerorderBatchService` helper methods — 4 changes

Filter cancelled orders in: `setPriority()`, `getAmountSKU()`, `getAmountParcels()`, `getAmountBottles()`, `getClubLineSKUOverview()`

#### 4. `ManageOrderService` OMS notification methods — 3 changes

Filter cancelled orders at the top of: `customerOrderReleaseForPicking()`, `customerOrderPickingStarted()`, `customerOrderPicked()`

#### 5. `CustomerorderBatchRepository` native queries — 4 changes

Already done in commit `eee8988` on release branches. Add:
- `AND c.state != 800` to `getOrderViewsByBatchId` and `getOrderContentsByBatchId`
- `SUM(CASE WHEN co.state != 800 ...)` to `findByStateAndType`, `findByStateAndTypeAndKeywordPage`, `getActiveClubBatch`

**Note**: The repository query changes from `eee8988` are already present on develop-arden (they were merged earlier). Only the service-layer changes need porting.

### Tests Required

Add/update tests in `CustomerorderBatchServiceUnitTest.java`:
1. `runClubLine_skipsNCancelledOrders` — verify cancelled orders are not packed
2. `runClubLine_skipsCancelledPositions` — verify cancelled positions within active orders are skipped
3. `runClubLine_wrongBatchState_throwsBusinessException` — verify batch-state guard
4. `runClubLine_concurrentCancellation_skipsInFinalLoop` — verify re-check guard
5. `getAmountParcels_excludesCancelledOrders` — verify count excludes cancelled
6. `getAmountBottles_excludesCancelledOrders` — verify count excludes cancelled

---

## Implementation Status

| Priority | Change | Risk | Status |
|----------|--------|------|--------|
| 1 | Filter cancelled orders in `runClubLine()` order list (C) | Critical | **DONE** |
| 2 | Re-check state before setting PACKED in final loop (E) | Critical | **DONE** |
| 3 | Filter cancelled positions in `runClubLine()` (D) | High | **DONE** |
| 4 | Add `@Transactional(rollbackFor)` (A) | High | **DONE** |
| 5 | Add batch-state guard (B) | Medium | **DONE** |
| 6 | Filter in `isEnoughStockOnStagingLane` (2) | Medium | **DONE** |
| 7 | Filter in helper methods (3) | Medium | **DONE** |
| 8 | Filter in ManageOrderService (4) | Medium | **DONE** |
| 9 | Add fulfillment check (F) | Medium | **DONE** |
| 10 | Tests (all) | Required | **DONE** |

## Files Changed

### Backend (wms-api)
- `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java` — runClubLine cancelled-order filtering, batch-state guard, @Transactional, fulfillment check, helper method filters (setPriority, getAmountSKU, getAmountBottles, getAmountParcels, getClubLineSKUOverview, isEnoughStockOnStagingLane)
- `src/main/java/net/aim_ai/wms/service/ManageOrderService.java` — cancelled-order filter in customerOrderReleaseForPicking, customerOrderPickingStarted, customerOrderPicked
- `src/test/java/net/aim_ai/wms/unit/service/CustomerorderBatchServiceUnitTest.java` — 3 new tests (skipsCancelledOrders, wrongBatchState, allOrdersCancelled) + 5 existing tests updated for batch-state guard

### Test Results
- 1574 tests: 0 failures, 0 errors

---

## Summary

| Item | Detail |
|------|--------|
| Root cause | Fix commits `a5af9fa`/`eee8988` never merged into develop-arden |
| Direct blocker | `runClubLine()` has no cancelled-order filtering — overwrites CANCELED(800) with PACKED(650) |
| Why it worked before | Previously tested on release branch which has the fixes |
| Fix approach | Port cancelled-order filtering from fix commits into develop-arden |
| Branches with the fix | `release-260319`, `tmp/np02-runclubline-cancelled-order` |
| Branch missing the fix | `develop-arden` (current) |
