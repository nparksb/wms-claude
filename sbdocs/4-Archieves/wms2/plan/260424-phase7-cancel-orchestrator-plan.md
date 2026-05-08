# Phase 7: Cancel Orchestrator — Implementation Plan

**Date:** 2026-04-04
**Status:** Analysis Complete — Awaiting Review
**Branch:** `tmp/np2-api-problem-areas`

---

## Current State: 5 Cancel Paths, 4 Bugs, Scattered Logic

Order cancellation is implemented across **5 distinct code paths** in 5 services and 2 controllers. Each path implements a different subset of the required cancel operations with inconsistent guards, stock release strategies, and OMS notifications.

### Cancel Paths

| # | Path | Entry Point | @Transactional |
|---|------|------------|----------------|
| 1 | OMS-initiated cancel | `POST /rest/order/cancelPositions` → `cancelOrder(order, false)` | Yes (service) |
| 2 | WMS-internal cancel | `cancelOrder(order, true)` (programmatic) | Yes (service) |
| 3 | Batch cancel | `CustomerorderBatchService.cancelBatch()` | Yes |
| 4 | Admin reset | `GET /rest/util/resetOrdersInReleasedStatus` | **No** (controller) |
| 5 | Deferred cancel | `markedforcancellation=true` → `cleanUpCancelledOrder()` | Split (2 copies) |

### Bugs Found

| # | Bug | Severity | File:Line |
|---|-----|----------|-----------|
| **B1** | Wrong OMS URL for cancel notification — uses stock count URL instead of cancel URL | High | `CustomerorderService.java:706` |
| **B2** | `resetOrdersInReleasedStatus` state corruption — calls `cancelOrder()` then overwrites to RAW, leaving picking positions in CANCELED state | High | `UtilRestController.java:958-968` |
| **B3** | `cancelBatch()` uses `zeroIfNegative=false` for stock release — throws on negative reserved amount instead of clamping to zero like `cancelOrder()` | Medium | `CustomerorderBatchService.java:309` |
| **B4** | Duplicate `cleanUpCancelledOrder()` — two diverging implementations in `PickingorderBusinessService:325` and `CustomerorderService:736` | Medium | Two files |

### Inconsistency Matrix

| Aspect | cancelOrder | cancelBatch | forceCancelOrder | cleanUpCancelledOrder |
|--------|------------|-------------|------------------|----------------------|
| Calls `canOrderPositionBeCancelled` | Yes | **No** | No | No |
| `zeroIfNegative` for stock release | `true` | **`false`** | `true` | N/A |
| Handles rapid picking totes | Yes | **No** | No | No |
| OMS notification | **Wrong URL** | Correct URL | No (caller) | No |
| `@Transactional` | Yes | Yes | **No** | Split |

---

## Implementation Plan

### Part A: Immediate Bug Fixes (implement now)

#### A1. Fix wrong OMS URL in `cancelOrder()`
**File:** `CustomerorderService.java:706`
```java
// BEFORE (wrong URL)
String url = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY);

// AFTER (correct URL)
String url = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY);
```

#### A2. Fix `zeroIfNegative` inconsistency in `cancelBatch()`
**File:** `CustomerorderBatchService.java:309`
```java
// BEFORE (throws on negative reserved)
stockunitBusinessService.changeReservedAmount(stockunit, reservedAmount.negate(), false, ...);

// AFTER (clamps to zero, consistent with cancelOrder)
stockunitBusinessService.changeReservedAmount(stockunit, reservedAmount.negate(), true, ...);
```

#### A3. Eliminate redundant position state setting in `cancelOrder()`
**File:** `CustomerorderService.java:652-661`
Lines 652-654 call `cancelOrderPosition()` which sets each position to CANCELED.
Then lines 658-661 iterate and set them to CANCELED again. Remove the redundant loop.

#### A4. Consolidate `cleanUpCancelledOrder()` — keep one copy
**Files:** `PickingorderBusinessService.java:325` (has `@Transactional`, uses batch saves) vs `CustomerorderService.java:736` (no `@Transactional`, individual saves)

Keep the `PickingorderBusinessService` version. Have `CustomerorderService` delegate to it.

### Part B: Cancel Orchestrator (implement after Part A, separate PR)

Create `OrderCancelOrchestrator` service with a pipeline of discrete steps:

```java
@Service
public class OrderCancelOrchestrator {

    public CancelResult cancelOrder(Long orderId, CancelContext context) {
        Customerorder order = loadAndValidate(orderId, context);
        cancelPickingPositions(order);
        releaseStockReservations(order);
        cleanupTotes(order, context);
        cancelOrderPositions(order);
        updateOrderState(order);
        finalizeBatch(order);
        if (context.shouldNotifyOms()) {
            notifyOms(order, context);
        }
        return CancelResult.success(order);
    }
}
```

With a `CancelContext`:
```java
public class CancelContext {
    public enum Source { OMS, WMS_UI, BATCH, ADMIN }
    private final Source source;
    private final boolean force;
    // getters
}
```

This is a larger refactor best done as a dedicated PR after the bug fixes are in and validated.

---

## Status: PENDING REVIEW
