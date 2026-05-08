# Club Order Cancellation Fix — v2 Consolidated Migration Plan

**Date:** 2026-03-27
**Status:** Implemented — Ready for Code Review
**Priority:** High
**Source Plans:**
- [v1 Club Order Cancellation Fix](../../wms1/plan/260424-Club_Order_Cancellation_Fix_Plan.md)
- [v1 Club Order Cancellation OMS Fix](../../wms1/plan/260424-Club_Order_Cancellation_OMS_Fix.md)
**Scope:** v2 WMS (wms2-api), branch `tmp/np106-v1-fixes-migration`

---

## Summary

Two related v1 plans addressed club order cancellation failures:
1. **Plan 1:** Service-level fix to allow OMS-originated cancellation of pre-QA packed club orders
2. **Plan 2:** Controller-level defensive coding (section lookup NPE, catch-all, HTTP status)

**In v2, the core `forceCancelOrder()` method exists and works, but the `cancelOrder()` guard logic was never restructured to support OMS-originated club order cancellation.** The controller-level fixes are also absent.

---

## What Needs to Be Done

### Phase 1: Service Layer — `CustomerorderService.java`

#### 1A. Add 4 Helper Methods (lines ~530, before `cancelOrder`)

These private helpers make the cancellation boundary logic readable and testable.

```java
private boolean isAlreadyCancelled(Customerorder order) {
    return Integer.valueOf(WmsConstants.State.CANCELED).equals(order.getState());
}

private boolean isPackedOrPalletized(Customerorder order) {
    return Integer.valueOf(WmsConstants.State.PACKED).equals(order.getState())
        || Integer.valueOf(WmsConstants.State.PALLETIZED).equals(order.getState());
}

private boolean isShippedOrPastCancellationBoundary(Customerorder order) {
    if (order.getState() >= WmsConstants.State.FINISHED) {
        return true;
    }
    // Check if parcel is already physically shipped
    if (order.getParcelId() != null) {
        Unitload parcel = unitloadRepository.findById(order.getParcelId()).orElse(null);
        if (parcel != null && parcel.getEntityLock() == WmsConstants.BusinessObjectLockState.SHIPPED) {
            return true;
        }
    }
    return false;
}

private boolean isOmsPreQaPackedCancellationAllowed(Customerorder order) {
    if (!isPackedOrPalletized(order)) {
        return false;
    }
    if (order.getOrderbatchId() == null) {
        return false;
    }
    CustomerorderBatch batch = customerorderBatchRepository.findById(order.getOrderbatchId()).orElse(null);
    return batch != null && WmsConstants.OrderBatchType.CLUB.equals(batch.getType());
}
```

**Note:** Uses `Integer.valueOf().equals()` for null-safe comparison (consistent with v2 pattern established in the Cancel Club Parcels fix).

#### 1B. Restructure `cancelOrder()` Guard Logic (lines 536-543)

**Current v2 code:**
```java
if (customerOrder.getState() >= WmsConstants.State.PACKED && cancellationFromWithinWMS) {
    forceCancelOrder(customerOrder);
    return;
}
if (customerOrder.getState() >= WmsConstants.State.PACKED) {
    throw new BusinessException("order is beyond status PACKED");
}
```

**Target code (matching v1 structure):**
```java
// 1. Already cancelled → no-op (idempotent)
if (isAlreadyCancelled(customerOrder)) {
    LOG.debug("cancelOrder: order {} is already cancelled, skipping", customerOrder.getNumber());
    return;
}

// 2. Shipped / finished → hard block
if (isShippedOrPastCancellationBoundary(customerOrder)) {
    throw new BusinessException("order is already shipped or past cancellation boundary");
}

// 3. Packed/Palletized → force cancel if WMS-internal OR pre-QA club order
if (isPackedOrPalletized(customerOrder)) {
    if (cancellationFromWithinWMS || isOmsPreQaPackedCancellationAllowed(customerOrder)) {
        forceCancelOrder(customerOrder);
        // Note: finalizeBatchIfComplete is called inside forceCancelOrder (v2 line 399)
        return;
    }
    throw new BusinessException("order is beyond status PACKED and not a pre-QA club order");
}
```

**Key v2 consideration:** `forceCancelOrder()` already calls `finalizeBatchIfComplete()` at line 399, so do NOT add a duplicate call in `cancelOrder()`.

#### 1C. Improve Section Lookup (line 562)

**Current v2 code (one-liner, partially defensive):**
```java
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).orElseThrow(() -> new EntityNotFoundException("Client", customerOrder.getClientId())).getSectionId()).orElse(null);
```

**Target code (split into readable lines, matching `packageOrder()` pattern at lines 511-512):**
```java
Client client = clientRepository.findById(customerOrder.getClientId())
    .orElseThrow(() -> new EntityNotFoundException("Client", customerOrder.getClientId()));
Section section = null;
if (client.getSectionId() != null) {
    section = sectionRepository.findById(client.getSectionId()).orElse(null);
}
```

**Note:** Keep `orElse(null)` for section (not `orElseThrow`) because the subsequent check at line 564 already handles `section == null` gracefully. Adding `orElseThrow` would break orders whose clients don't have section assignments.

---

### Phase 2: Controller Layer — `OrderRestController.java`

#### 2A. Add Catch-All for Unchecked Exceptions (line 726)

**Current v2 code (lines 720-726):**
```java
try {
    customerorderService.cancelOrder(customerOrder, false);
} catch (BusinessException e) {
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.WRONG_STATE, e, WmsConstants.State.getCodeText(customerOrder.getState()), order);
} catch (FacadeException e) {
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);
}
```

**Add after line 726:**
```java
} catch (Exception e) {
    LOG.error("Unexpected error cancelling order={}: {}", order.getUniqueId(), e.getMessage(), e);
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);
}
```

#### 2B. Change HTTP Response from 204 to 200 (lines 742, 748)

**Line 742 — service log:** Change `HttpStatus.NO_CONTENT.value()` → `HttpStatus.OK.value()`

**Line 748 — response:** Change:
```java
return ResponseEntity.status(HttpStatus.NO_CONTENT).body(Collections.singletonMap("status", "success"));
```
To:
```java
return ResponseEntity.ok(Collections.singletonMap("status", "success"));
```

**Important:** Coordinate with OMS team before deploying — if OMS checks for HTTP 204 status code specifically, this is a breaking change.

#### 2C. Per-Order Error Collection (Enhancement — Optional)

Currently, the first order that fails cancellation aborts the entire batch loop. The `errors` map at line 688 is declared but never populated (dead code).

**Recommended approach:** Restructure the inner loop to catch errors per-order, collect them in the `errors` map, continue processing remaining orders, and return a partial-success response if any orders failed.

This is the largest change and introduces a new response shape (`{"status":"partial","errors":{...}}`). **Recommend deferring to a separate PR** to keep this migration focused.

---

## Existing v2 Tests That Need Modification

| Test | Location | Current Behavior | Required Change |
|------|----------|-----------------|-----------------|
| `throwsExceptionWhenOrderAlreadyCancelled` | line 355 | Asserts `BusinessException` thrown | Change to assert silent no-op (no exception) |
| `cancelOrderShouldThrowForPalletizedState` | line 1927 | Asserts throw for all PALLETIZED | Scope to non-CLUB batches only |

---

## New Tests Required

### Service Tests (`CustomerorderServiceUnitTest.java`)

| # | Test Name | Description |
|---|-----------|-------------|
| 1 | `cancelOrder_packedClubOrder_fromOms_forceCancelsAndFinalizesBatch` | OMS cancel of PACKED order in CLUB batch → `forceCancelOrder` called |
| 2 | `cancelOrder_palletizedClubOrder_fromOms_forceCancelsAndFinalizesBatch` | OMS cancel of PALLETIZED order in CLUB batch → `forceCancelOrder` called |
| 3 | `cancelOrder_packedRegularOrder_fromOms_throwsBusinessException` | OMS cancel of PACKED order in PICK_PACK batch → throws |
| 4 | `cancelOrder_finishedOrShippedOrder_fromOms_throwsBusinessException` | OMS cancel of FINISHED order → throws |
| 5 | `cancelOrder_alreadyCanceled_fromOms_isNoOp` | Already CANCELED order → returns silently, no exception |
| 6 | `cancelOrder_regularPickedAwaitingQa_stillUsesNormalCancellationPath` | PICKED regular order → uses standard cancel (not force) |

### Controller Tests (`OrderRestControllerUnitTest.java` — optional, can be deferred)

| # | Test Name | Description |
|---|-----------|-------------|
| 7 | `cancelPositions_packedClubOrder_returnsSuccess` | Packed club order cancelled via REST → HTTP 200 |
| 8 | `cancelPositions_alreadyCancelledOrder_returnsSuccess` | Already cancelled order → HTTP 200 (not 400/500) |
| 9 | `cancelPositions_uncheckedExceptionHandled` | Unexpected error → HTTP 400 (not 500) |

---

## Implementation Order

| Step | Action | File | Risk | Effort | Status |
|------|--------|------|------|--------|--------|
| 1 | Add 4 helper methods | `CustomerorderService.java` | Low | Small | **Done** |
| 2 | Restructure `cancelOrder()` guard logic | `CustomerorderService.java:536-543` | **High** — core cancel flow | Medium | **Done** |
| 3 | Improve section lookup | `CustomerorderService.java:562` | Low | Small | **Done** |
| 4 | Add catch-all in controller | `OrderRestController.java:726` | Low | Small | **Done** |
| 5 | Change HTTP 204 → 200 | `OrderRestController.java:742,748` | Low (coordinate with OMS) | Small | **Done** |
| 6 | Update existing tests (3) | `CustomerorderServiceUnitTest.java`, `OrderRestControllerUnitTest.java` | Medium | Small | **Done** |
| 7 | Add new service tests (6) | `CustomerorderServiceUnitTest.java` | Low | Medium | **Done** |
| 8 | *(Optional)* Per-order error collection | `OrderRestController.java` | Medium | Medium | Deferred |

---

## Additional Recommendations

### 1. Boolean Refactoring (Future PR)

The `cancellationFromWithinWMS` boolean mixes caller origin, permission, cleanup mode, and callback behavior. The v1 plan recommends replacing it with an explicit policy enum (`STANDARD_OMS`, `WMS_FORCE`, etc.) or separate method signatures. This is a structural improvement for a follow-up PR.

### 2. `customerorderBatchRepository` Dependency

The `isOmsPreQaPackedCancellationAllowed()` helper needs access to `customerorderBatchRepository`. Verify it's already injected in `CustomerorderService` (it should be, since `finalizeBatchIfComplete` uses `customerorderBatchService`).

### 3. WmsConstants References

| Constant | Location | Value |
|----------|----------|-------|
| `State.PACKED` | WmsConstants.java | 650 |
| `State.PALLETIZED` | WmsConstants.java | 660 |
| `State.FINISHED` | WmsConstants.java | 700 |
| `State.CANCELED` | WmsConstants.java | 800 |
| `OrderBatchType.CLUB` | WmsConstants.java:494 | `"CLUB"` |
| `BusinessObjectLockState.SHIPPED` | WmsConstants.java:1115 | 405 |

---

## Verification Checklist

- [ ] Helper methods added to `CustomerorderService`
- [ ] `cancelOrder()` guard logic restructured
- [ ] Section lookup improved
- [ ] Controller catch-all added
- [ ] HTTP 204 → 200 changed
- [ ] 2 existing tests updated
- [ ] 6 new service tests added and passing
- [ ] Full related test suite passes
- [ ] OMS team notified about HTTP status change

---

## Current Status

| Area | Status | Action |
|------|--------|--------|
| **cancelOrder() helpers (4)** | **Done** | Ported from v1 |
| **cancelOrder() guard logic** | **Done** | Restructured |
| **forceCancelOrder()** | Present (correct) | None |
| **Section lookup** | **Done** | Improved |
| **Controller catch-all** | **Done** | Added |
| **HTTP 204→200** | **Done** | Changed |
| **Per-order errors** | Deferred | Separate PR |
| **Service tests (6 new)** | **Done** | Created |
| **Tests updated (3)** | **Done** | Updated |

### Test Results (2026-03-27, post-implementation)

```
CustomerorderServiceUnitTest:      Tests run: 85, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
CustomerorderBatchServiceUnitTest: Tests run: 80, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
BillofladingServiceUnitTest:       Tests run: 57, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
OrderRestControllerUnitTest:       Tests run: 85, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
Total:                             307 tests, 0 failures
```

### Files Changed

- `src/main/java/net/aim_ai/wms/service/CustomerorderService.java` — 4 helpers + guard restructuring + section lookup
- `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java` — catch-all + HTTP 200
- `src/test/java/net/aim_ai/wms/unit/service/CustomerorderServiceUnitTest.java` — 6 new + 2 updated tests
- `src/test/java/net/aim_ai/wms/unit/controller/rest/OrderRestControllerUnitTest.java` — 1 updated test
