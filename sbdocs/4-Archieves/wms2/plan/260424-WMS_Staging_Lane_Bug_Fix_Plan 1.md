# WMS Staging Lane Bug Fix Plan — v2 Migration Assessment

**Date:** 2026-03-27
**Status:** Implemented — Committed (2c7096c)
**Priority:** Medium
**Source Plan:** [v1 WMS Staging Lane Bug Fix Plan](../../wms1/plan/260424-WMS_Staging_Lane_Bug_Fix_Plan.md)
**Scope:** v2 WMS (wms2-api), branch `tmp/np106-v1-fixes-migration`

---

## Summary

The v1 plan addressed three bugs (A, B, C) where `staginglaneId` was never cleared on batch completion or cancellation. **Two of three bugs are already fully fixed in v2. One partial fix remains** — a save-ordering issue in `cancelOrder()` that could cause batch finalization to see stale order state under certain conditions.

---

## Migration Analysis

### Bug A: `cancelOrder()` — Save-Ordering Issue

**v1 Fix:** Distinguished CANCELED vs FINISHED batch state; always clear `staginglaneId`; save order BEFORE batch finalization.

**v2 Status:** PARTIALLY FIXED

The core logic (CANCELED vs FINISHED distinction + lane clearing) was already extracted into `CustomerorderBatchService.finalizeBatchIfComplete()` (lines 354-377), which correctly handles both concerns. **However**, the order of operations in `cancelOrder()` differs from v1:

| Step | v1 (correct) | v2 (current) |
|------|-------------|-------------|
| 1 | Set order state to CANCELED | Set order state to CANCELED |
| 2 | **Save order** | Cancel positions |
| 3 | Call `finalizeBatchIfComplete()` | Call `finalizeBatchIfComplete()` — order NOT yet saved |
| 4 | — | **Save order** (line 612) |

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Lines:** 597-612

**Risk Assessment:** Medium. JPA's default `FlushModeType.AUTO` will flush dirty entities before `findByOrderbatchId()` executes at line 359 of `finalizeBatchIfComplete()`, so the CANCELED state *should* be visible. However:
- This relies on Hibernate implementation behavior, not an explicit guarantee
- If flush mode is ever changed (e.g., for performance tuning), the batch could be set to FINISHED instead of CANCELED
- The v1 codebase explicitly fixed this ordering with a comment explaining why

**Current code (lines 597-612):**
```java
            customerOrder.setState(WmsConstants.State.CANCELED);
            coPositions.forEach(position -> {
                position.setState(WmsConstants.State.CANCELED);
                customerorderPositionRepository.save(position);
            });

            customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
        } else {
            LOG.debug("cancelOrder: order can not be cancelled");
            if (customerOrder.getPickingconfirmationsent()) {
                cleanUpCancelledOrder(customerOrder);
            } else {
                customerOrder.setMarkedforcancellation(true);
            }
        }
        customerorderRepository.save(customerOrder);
```

**Proposed fix:**
```java
            customerOrder.setState(WmsConstants.State.CANCELED);
            coPositions.forEach(position -> {
                position.setState(WmsConstants.State.CANCELED);
                customerorderPositionRepository.save(position);
            });

            // Save order BEFORE batch finalization so CANCELED state is visible on re-read
            customerorderRepository.save(customerOrder);
            customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
        } else {
            LOG.debug("cancelOrder: order can not be cancelled");
            if (customerOrder.getPickingconfirmationsent()) {
                cleanUpCancelledOrder(customerOrder);
            } else {
                customerOrder.setMarkedforcancellation(true);
                customerorderRepository.save(customerOrder);
            }
        }
```

**Changes:**
1. Move `customerorderRepository.save(customerOrder)` from line 612 to before `finalizeBatchIfComplete()` (inside the cancellable branch)
2. Add a save in the `else` → `setMarkedforcancellation` branch (since the unconditional save at 612 is removed)
3. The `cleanUpCancelledOrder` path already handles its own persistence internally

**Effort:** Small (6 lines changed)

---

### Bug B: `cancelBatch()` — Dead Code Fix

**v1 Fix:** Made method public; added order cancellation loop + batch state/lane cleanup.

**v2 Status:** FULLY FIXED — No action needed.

The v2 `cancelBatch()` method (lines 210-352) is:
- `public` (line 211)
- Properly cancels all customer orders and their child entities (lines 286-333)
- Sets batch state to `CANCELED` (line 347)
- Clears `staginglaneId` (line 348)
- Has proper `@Transactional(value = "tenantTransactionManager")` annotation

V2 is actually more thorough than v1 — it also clears `transferlaneId` on individual orders and handles `PickingorderUnitload` cleanup.

---

### Bug C: `closeBOL()` — Lane Not Cleared on Completion

**v1 Fix:** Added `setStaginglaneId(null)` in two paths (regular + Club Run completion).

**v2 Status:** FULLY FIXED — No action needed.

- **Path 1 (Regular completion):** v2 uses a bulk JPQL UPDATE at line 695 that includes `cb.staginglaneId = null` directly in the query — more efficient than v1's per-entity save.
- **Path 2 (Club Run completion):** v2 has `coOrderBatch.setStaginglaneId(null)` at line 764, identical to v1.

---

## Test Coverage Assessment

### Existing Tests (Already in v2)

| Test Class | Test Method | Bug | Status |
|-----------|------------|-----|--------|
| `CustomerorderServiceUnitTest` | `cancelOrder_allOrdersCancelled_setsBatchCanceledAndClearsLane` (line 2074) | A | Present |
| `CustomerorderServiceUnitTest` | `cancelOrder_mixedFinalStates_setsBatchFinishedAndClearsLane` (line 2111) | A | Present |
| `CustomerorderServiceUnitTest` | `cancelOrder_notAllOrdersFinal_doesNotUpdateBatch` (line 2138) | A | Present |
| `CustomerorderServiceUnitTest` | `cleanUpCancelledOrder_allCancelled_clearsLane` (line 2182) | A | Present |
| `CustomerorderBatchServiceUnitTest` | `cancelBatch_validBatch_cancelsOrdersAndBatchAndClearsLane` (line 1951) | B | Present |
| `CustomerorderBatchServiceUnitTest` | `cancelBatch_batchWithoutLane_cancelsAndLaneRemainsNull` (line 1996) | B | Present |
| `BillofladingServiceUnitTest` | `transferOrder_clearsStaginglane` (line 1522) | C2 | Present |

### Tests Needed for Save-Ordering Fix

The existing `cancelOrder` tests verify that `finalizeBatchIfComplete` is called, but they don't verify the save ordering. A new test should confirm the order is persisted before batch finalization:

**New test to add to `CustomerorderServiceUnitTest.java`:**

1. **`cancelOrder_savesOrderBeforeFinalizingBatch`**
   - Given: Order in PICKING state with batch
   - When: `cancelOrder()` is called
   - Then: Verify `customerorderRepository.save(customerOrder)` is called BEFORE `customerorderBatchService.finalizeBatchIfComplete(batchId)` using Mockito `InOrder`

### Test Gap: closeBOL Staging Lane Cleanup

Neither v1 nor v2 has a dedicated test for Path 1 (regular batch completion clearing `staginglaneId` in `closeBOL`). This is a pre-existing gap.

**Optional new test to add to `BillofladingServiceUnitTest.java`:**

2. **`closeBOL_regularCompletion_clearsStagingLane`**
   - Given: BOL with batches that have `staginglaneId` set, all orders FINISHED
   - When: `closeBOL()` is called
   - Then: Verify the bulk JPQL update includes staging lane clearing (via repository method verification)

---

## Implementation Plan

| Step | Action | File | Risk | Effort | Status |
|------|--------|------|------|--------|--------|
| 1 | Fix save ordering in `cancelOrder()` | `CustomerorderService.java:597-612` | Medium — most impactful remaining fix | Small (6 lines) | **Done** (2c7096c) |
| 2 | Add save-ordering test | `CustomerorderServiceUnitTest.java` | Low | Small (1 test) | **Done** (2c7096c) |
| 3 | *(Optional)* Add closeBOL staging lane test | `BillofladingServiceUnitTest.java` | Low | Small (1 test) | Not started |

---

## Additional Recommendations

### 1. Parcel Cleanup in cancelBatch (Minor Gap)

The v1 `cancelBatch()` includes parcel cleanup logic (unlocking parcel unitload and its stockunits) at v1 lines 296-307 which v2 lacks. If parcels can be assigned to orders at the time of batch cancellation, this could leave orphaned locks.

**Recommendation:** Verify whether `customerOrder.getParcelId()` can be non-null at batch cancellation time in v2's workflow. If yes, port the parcel cleanup logic from v1.

### 2. OMS Notification Scope in cancelBatch (Minor)

V2 sends ALL batch orders (including already-canceled ones) to OMS in the cancel notification, while v1 filters out already-canceled orders. This causes redundant cancel requests.

**Recommendation:** Low priority. Only worth addressing if OMS logs show noise from duplicate cancel notifications.

### 3. finalizeBatchIfComplete Guard Clause

The `finalizeBatchIfComplete()` method currently has no guard against being called on an already-finalized batch. If called twice (e.g., due to retry logic), it would re-save the batch unnecessarily.

**Recommendation:** Add an early return if `batch.getState() >= WmsConstants.State.FINISHED` at the top of the method.

---

## Verification Checklist

- [ ] Save ordering fix applied in `CustomerorderService.java`
- [ ] New save-ordering test added and passing
- [ ] All existing staging lane tests still pass
- [ ] Full test suite passes (`mvn test`)
- [ ] Code review completed

---

## Current Status

| Bug | v2 Fix Status | Tests Present | Test Results | Action Required |
|-----|--------------|---------------|-------------|-----------------|
| **A** | **Complete** — save ordering fixed (2c7096c) | Yes (3 + 1 + 1 new tests) | 79/79 pass | None |
| **B** | Complete | Yes (2 tests) | 78/78 pass | None |
| **C1** | Complete (bulk JPQL) | No dedicated test | 57/57 pass | Optional: add test |
| **C2** | Complete | Yes (1 test) | 57/57 pass | None |

### Verified Test Results (2026-03-27, post-implementation)

```
CustomerorderServiceUnitTest:      Tests run: 79, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
CustomerorderBatchServiceUnitTest: Tests run: 78, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
BillofladingServiceUnitTest:       Tests run: 57, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
Total:                             214 tests, 0 failures
```

**Note:** Pre-existing H2/integration test failures (ApplicationContext loading issues in repository and H2 controller tests) are unrelated to this change — verified by running the same tests against the unchanged codebase.

### Overall Assessment

All v1 staging lane fixes are now **fully ported** to v2. The save-ordering fix in `cancelOrder()` was the only remaining gap and has been implemented in commit `2c7096c` with a corresponding `InOrder` verification test.

**Remaining optional items:**
- Add closeBOL staging lane test (neither v1 nor v2 has one)
- Investigate parcel cleanup gap in `cancelBatch`
- Add guard clause to `finalizeBatchIfComplete()` for already-finalized batches
