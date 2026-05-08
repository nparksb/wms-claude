# RunClubLine Catastrophic Failure: Partially Cancelled Club Orders

**Date:** 2026-03-16 (Updated: 2026-03-21)
**Severity:** Critical
**Status:** V2 Implemented - All 7 applicable fixes applied, 9 new tests added, 155 affected tests pass (34 pre-existing H2/integration context errors unrelated)

## Problem Summary

When a club order batch is partially cancelled (some orders cancelled via OMS `/cancelPositions` endpoint while others remain active), the `runClubLine` operation processes **all orders including cancelled ones**. This creates ghost parcels, consumes stock for cancelled orders, sends incorrect OMS notifications, and overwrites the CANCELED state to PACKED -- effectively reversing the cancellation.

## Root Cause

The `runClubLine` method and its supporting methods were designed under the assumption that all orders in an activated batch are valid. The partial cancellation feature (`cancelPositions` REST endpoint) was added without corresponding guards in the club line run path.

**Zero state checks exist** in the entire `runClubLine` processing pipeline.

## V2 Architecture Differences

The v2 codebase has several structural changes from v1 that affect how fixes must be applied:

| Aspect | V1 | V2 |
|--------|----|----|
| `runClubLine` signature | `runClubLine(Long orderBatchId)` | `runClubLine(CustomerorderBatch orderBatch)` |
| Transaction annotation | Class-level bare `@Transactional` | Method-level `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})` |
| Position fetching | Per-order via `findByOrderId()` inside loop | Pre-fetched in bulk via `findAllPositionsByOrderBatchId()`, grouped by order ID |
| Itemdata fetching | Per-position via `itemdataService.getById()` inside loop | Pre-fetched in bulk via `findAllById()` into a map |
| Stock validation | Separate method, result discarded | `StockValidationResult` record reuses stock map in `runClubLine` |
| State update | Individual re-fetch + save loop per order | Bulk `updateStateByIds()` and `updateStateByOrderIds()` queries |
| FixLocationAssignment | Fetched per stock transfer call | Pre-fetched once before the loop |

## Affected Code Paths (V2 Line References)

| File | Method | Line(s) | Issue |
|------|--------|---------|-------|
| `CustomerorderBatchService.java` | `runClubLine()` | 460-566 | Main loop iterates ALL orders, no CANCELED filter |
| `CustomerorderBatchService.java` | `validateStockOnStagingLane()` | 369-437 | Counts cancelled orders in parcel total, inflating stock requirement |
| `CustomerorderRepository.java` | `findByOrderbatchId()` | 39 | Simple derived query with no state filter |
| `ManageOrderService.java` | `customerOrderReleaseForPicking()` | 124 | Sends OMS notification for cancelled orders |
| `ManageOrderService.java` | `customerOrderPickingStarted()` | 235 | Sends OMS notification for cancelled orders; no empty list guard |
| `ManageOrderService.java` | `customerOrderPicked()` | 278 | Sends OMS notification and mutates cancelled orders with historytote UUID; no empty list guard |
| `CustomerorderRepository.java` | `updateStateByIds()` | 157-158 | Bulk UPDATE with no `state != CANCELED` guard |
| `CustomerorderPositionRepository.java` | `updateStateByOrderIds()` | 66-67 | Bulk UPDATE with no `state != CANCELED` guard |

## Catastrophic Failure Scenario

1. OMS sends a club batch with 100 orders
2. WMS operator assigns staging lane, activates batch
3. OMS sends `cancelPositions` for 10 of the 100 orders
4. Those 10 orders become CANCELED (800), their positions become CANCELED (800)
5. The batch stays ACTIVATED (520) because 90 orders are still active
6. Operator clicks "Run Club Line"

**Result:**
- `validateStockOnStagingLane` calculates required stock for **100** parcels (not 90) -- may falsely block the run
- If stock check passes, `runClubLine` creates **100 parcels** (including 10 for cancelled orders)
- 10 cancelled orders get parcels created, stock physically moved to those parcels
- OMS receives "released/started/picked" messages for 10 orders it already cancelled
- Bulk `updateStateByIds` sets ALL 100 orders to PACKED (650), **destroying the CANCELED state**
- Stock is locked in 10 ghost parcels with no valid customer order
- Ghost parcels appear in palletization and BOL workflows, can be loaded onto trucks
- OMS and WMS completely out of sync on those 10 orders

**Secondary failure:** If cancelled orders' stock transfer consumes stock units before valid orders are processed, valid orders may receive insufficient stock or encounter NullPointerException when the item-to-stock map runs dry.

## Fix Plan (V2)

### Fix 1: Filter cancelled orders in `runClubLine` (CRITICAL)

**File:** `CustomerorderBatchService.java`
**Location:** Line 500, immediately after fetching orders

**Current code (v2):**
```java
List<Customerorder> orders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
for (Customerorder order : orders) {
```

**Fix:** Add filter after the fetch:
```java
List<Customerorder> orders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
orders.removeIf(o -> o.getState() == WmsConstants.State.CANCELED);

if (orders.isEmpty()) {
    throw new BusinessException("No active orders in batch to process");
}

for (Customerorder order : orders) {
```

This single change prevents parcel creation, stock movement, OMS notifications, and state overwrite for cancelled orders.

**V2-specific note:** The filtered `orders` list flows through:
- Parcel creation loop (lines 501-551)
- OMS messaging calls (lines 554-556)
- Bulk state update via `orderIds` list (lines 559-561)

Since the same `orders` variable is used to build `orderIds` at line 559, the bulk `updateStateByIds` will naturally exclude cancelled orders.

**V2-specific note on pre-fetched positions:** The positions are pre-fetched at line 485 via `findAllPositionsByOrderBatchId` before the orders are filtered. This is harmless -- positions for cancelled orders will exist in `positionsByOrderId` but will never be accessed because the filtered `orders` loop won't include those order IDs.

---

### Fix 2: Filter cancelled orders in `validateStockOnStagingLane` (HIGH)

**File:** `CustomerorderBatchService.java`
**Location:** Lines 378-379 (inside `validateStockOnStagingLane`, called by both `isEnoughStockOnStagingLane` and `runClubLine`)

**Current code (v2):**
```java
List<Customerorder> orders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
int parcels = orders.size();

if (parcels == 0) {
    throw new BusinessException("Order batch does not contain any orders / parcels / positions");
}
```

**Fix:**
```java
List<Customerorder> orders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
orders.removeIf(o -> o.getState() == WmsConstants.State.CANCELED);
int parcels = orders.size();

if (parcels == 0) {
    throw new BusinessException("No active orders in batch for stock check");
}
```

This ensures the stock sufficiency calculation is based on the actual number of active orders, not the original batch size. The filter must happen **before** both `parcels = orders.size()` (line 379) and `orders.get(0)` (line 387) to ensure the representative order used as the SKU template is an active order, not a cancelled one.

**V2-specific note:** In v2, `validateStockOnStagingLane` returns a `StockValidationResult` that is reused by `runClubLine`. The stock map built here will correctly exclude stock requirements for cancelled orders after this fix. The existing `parcels == 0` guard (line 381) already handles the all-cancelled edge case.

---

### Fix 3: Filter cancelled orders in OMS message methods (MEDIUM - Defense-in-depth)

**File:** `ManageOrderService.java`
**Location:** At the start of each method: `customerOrderReleaseForPicking` (line 124), `customerOrderPickingStarted` (line 235), `customerOrderPicked` (line 278)

**Fix for `customerOrderReleaseForPicking` (line 124):** Already has an empty-list guard at line 127. Add cancelled filter before it:
```java
public void customerOrderReleaseForPicking(List<Customerorder> customerOrderList) {
    LOG.debug("start");
    customerOrderList.removeIf(o -> o.getState() == WmsConstants.State.CANCELED);

    if (customerOrderList.isEmpty()) {
        LOG.debug("end without doing anything (list is empty).");
        return;
    }
    // ... existing code ...
```

**Fix for `customerOrderPickingStarted` (line 235):** Currently has NO empty-list guard and uses `customerOrderList.get(0)` at line 239. Add both:
```java
public void customerOrderPickingStarted(List<Customerorder> customerOrderList) {
    LOG.debug("start");
    customerOrderList.removeIf(o -> o.getState() == WmsConstants.State.CANCELED);

    if (customerOrderList.isEmpty()) {
        LOG.debug("end without doing anything (list is empty after filtering cancelled orders).");
        return;
    }

    // TODO check that list contains orders from the same order batch only
    Customerorder representative = customerOrderList.get(0);
    // ... existing code ...
```

**Fix for `customerOrderPicked` (line 278):** Currently has NO empty-list guard and uses `customerOrderList.get(0)` at line 283. Add both:
```java
public void customerOrderPicked(List<Customerorder> customerOrderList) {
    LOG.debug("start customerOrderPicked");
    customerOrderList.removeIf(o -> o.getState() == WmsConstants.State.CANCELED);

    if (customerOrderList.isEmpty()) {
        LOG.debug("end without doing anything (list is empty after filtering cancelled orders).");
        return;
    }

    // TODO check that list contains orders from the same order batch only
    Customerorder representative = customerOrderList.get(0);
    // ... existing code ...
```

**Important:** `customerOrderPickingStarted()` and `customerOrderPicked()` use `customerOrderList.get(0)` internally. The empty-list return guard **must** come before the `get(0)` call to prevent `IndexOutOfBoundsException` when all orders are cancelled.

This is belt-and-suspenders -- Fix 1 already prevents cancelled orders from reaching these methods via `runClubLine`, but other callers may also pass mixed-state lists.

---

### Fix 4: Add batch-state guard to `runClubLine` entry (MEDIUM)

**File:** `CustomerorderBatchService.java`
**Location:** Start of `runClubLine` method (line 460), after the LOG.debug (line 461)

**Fix:** Add state validation using a positive check for expected pre-run state:
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void runClubLine(CustomerorderBatch orderBatch) throws BusinessException, FacadeException {
    LOG.debug("start runClubLine with orderBatch={}", orderBatch);

    if (orderBatch.getState() != WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED) {
        throw new BusinessException("Cannot run club line on batch in state: " + orderBatch.getState()
            + ". Expected state: " + WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED);
    }

    long start = System.currentTimeMillis();
    // ... existing code ...
```

**V2-specific note:** In v2, the batch object is passed directly (not fetched by ID inside the method). The state check is applied to the passed-in object. This is identical in effect to v1.

**Rationale:** A positive check (`!= ORDER_BATCH_STAGING_LANE_ASSIGNED`, value 525) is stronger than a negative check. It prevents running club line from any unexpected state, including `ORDER_BATCH_CLUB_RUN_FINISHED` (530) which would cause duplicate processing.

---

### Fix 5: Filter cancelled positions within each order (LOW - Defensive)

**File:** `CustomerorderBatchService.java`
**Location:** Line 485-487, where all positions are pre-fetched and grouped

**Current code (v2):**
```java
// Pre-fetch all positions for the batch and group by order ID
List<CustomerorderPosition> allPositions = customerorderPositionRepository.findAllPositionsByOrderBatchId(orderBatch.getId());
Map<Long, List<CustomerorderPosition>> positionsByOrderId = allPositions.stream()
    .collect(Collectors.groupingBy(CustomerorderPosition::getOrderId));
```

**Fix:** Filter cancelled positions during the stream grouping:
```java
// Pre-fetch all positions for the batch and group by order ID (excluding cancelled positions)
List<CustomerorderPosition> allPositions = customerorderPositionRepository.findAllPositionsByOrderBatchId(orderBatch.getId());
Map<Long, List<CustomerorderPosition>> positionsByOrderId = allPositions.stream()
    .filter(p -> p.getState() != WmsConstants.State.CANCELED)
    .collect(Collectors.groupingBy(CustomerorderPosition::getOrderId));
```

**V2-specific note:** Unlike v1 which filtered per-order inside the loop, v2 pre-fetches all positions in bulk. The filter is applied during the stream grouping, which is more efficient (single pass). This also means the `itemdataIds` set (line 490) and `itemdataMap` (line 493) may still include itemdata for cancelled positions, but this is harmless -- just extra data pre-loaded.

**Alternative approach:** Add `AND cp.state != 800` to the native query in `CustomerorderPositionRepository.findAllPositionsByOrderBatchId()` (lines 76-79) to filter at the database level. This is more efficient but less explicit in the service code. If chosen, the query becomes:
```java
@Query(value = "SELECT cp.* FROM customerorder_position cp "
    + "JOIN customerorder co ON cp.order_id = co.id "
    + "WHERE co.orderbatch_id = :batchId "
    + "AND cp.state != 800", nativeQuery = true)
List<CustomerorderPosition> findAllPositionsByOrderBatchId(@Param("batchId") Long batchId);
```

**Recommendation:** Use the Java stream filter approach (first option) for explicitness and consistency with other fixes in this plan.

---

### Fix 6: Add post-transfer completeness check (MEDIUM)

**File:** `CustomerorderBatchService.java`
**Location:** After the stock transfer inner loop (after line 546), before the `emptyOrMovedStockUnits` cleanup

**Issue:** Inside `runClubLine()`, after the stock transfer loop for each position, there is no assertion that `requiredAmount` reached zero. If stock is insufficient or becomes inconsistent, the code silently continues, creates the parcel, sends OMS messages, and sets state to PACKED despite incomplete fulfillment.

**Current code (v2):**
```java
                    } else { // resultCompareAmountOnStockWithRequired < 0
                        // ... transfer partial amount ...
                        requiredAmount = requiredAmount.subtract(amountOnSourceStockUnit);
                        // ...
                    }
                }

                Set<Long> idsToRemove = emptyOrMovedStockUnits.stream().map(Stockunit::getId).collect(Collectors.toSet());
```

**Fix:** Add assertion after the inner for-loop ends (after line 546, before line 548):
```java
                }

                // Verify all required stock was transferred for this position
                if (requiredAmount.compareTo(BigDecimal.ZERO) > 0) {
                    throw new BusinessException("Insufficient stock for position " + orderPosition.getId()
                        + " of order " + order.getNumber()
                        + ". Remaining unfulfilled amount: " + requiredAmount);
                }

                Set<Long> idsToRemove = emptyOrMovedStockUnits.stream().map(Stockunit::getId).collect(Collectors.toSet());
```

**V2-specific note:** In v2, the `@Transactional` annotation at line 459 already includes `rollbackFor = {BusinessException.class, FacadeException.class}`, so this `BusinessException` will correctly trigger a full transaction rollback, undoing all parcels and stock transfers created so far. This is why Fix 7 is not needed in v2.

---

### Fix 7: Ensure transaction rollback on checked exceptions -- ALREADY APPLIED IN V2

**File:** `CustomerorderBatchService.java`
**Location:** Line 459

**V2 code already has:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void runClubLine(CustomerorderBatch orderBatch) throws BusinessException, FacadeException {
```

This correctly:
- Uses the `tenantTransactionManager` (not the default landlord TM)
- Specifies `rollbackFor` for both checked exception types
- Ensures any `BusinessException` thrown mid-processing (e.g., from Fix 6) triggers a full rollback

**No change needed.**

---

### Fix 8: Conditional bulk update to protect concurrent cancellations (MEDIUM - V2 approach differs from V1)

**File:** `CustomerorderRepository.java` and `CustomerorderPositionRepository.java`
**Location:** `updateStateByIds` (line 157-158) and `updateStateByOrderIds` (line 66-67)

**Issue (V2-specific):** V2 uses bulk UPDATE queries instead of v1's individual re-fetch+save loop. The current queries unconditionally set all matching IDs to PACKED:

```java
// CustomerorderRepository.java:157-158
@Modifying
@Query("UPDATE Customerorder c SET c.state = :state WHERE c.id IN :ids")
int updateStateByIds(@Param("ids") List<Long> ids, @Param("state") int state);

// CustomerorderPositionRepository.java:66-67
@Modifying
@Query("UPDATE CustomerorderPosition cp SET cp.state = :state WHERE cp.orderId IN :orderIds")
int updateStateByOrderIds(@Param("orderIds") List<Long> orderIds, @Param("state") int state);
```

If a concurrent transaction cancels an order between the initial fetch (line 500) and the bulk update (line 560), the cancelled order's state will be overwritten to PACKED.

**Fix:** Add `AND state != CANCELED` guard to both queries:

```java
// CustomerorderRepository.java
@Modifying
@Query("UPDATE Customerorder c SET c.state = :state WHERE c.id IN :ids AND c.state != 800")
int updateStateByIds(@Param("ids") List<Long> ids, @Param("state") int state);

// CustomerorderPositionRepository.java
@Modifying
@Query("UPDATE CustomerorderPosition cp SET cp.state = :state WHERE cp.orderId IN :orderIds AND cp.state != 800")
int updateStateByOrderIds(@Param("orderIds") List<Long> orderIds, @Param("state") int state);
```

**V2-specific advantage:** This approach is actually cleaner than v1's individual re-check loop. The database enforces the guard atomically -- there's no TOCTOU race between checking and updating. The `int` return value can be compared against `orderIds.size()` to detect skipped rows.

**Optional enhancement in `runClubLine`:** After the bulk updates (lines 559-561), log a warning if rows affected differ from expected:
```java
int updatedOrders = customerorderRepository.updateStateByIds(orderIds, WmsConstants.State.PACKED);
int updatedPositions = customerorderPositionRepository.updateStateByOrderIds(orderIds, WmsConstants.State.PACKED);
if (updatedOrders < orderIds.size()) {
    LOG.warn("Expected to update {} orders but only updated {}. Some orders may have been cancelled concurrently.",
        orderIds.size(), updatedOrders);
}
```

**Impact assessment:** These queries are also used from other code paths. The `AND state != 800` guard is universally safe -- no caller should ever want to overwrite a CANCELED state via these bulk methods.

---

## Implementation Order (V2)

1. **Fix 1** - Filter cancelled orders in `runClubLine` (addresses the core catastrophe)
2. **Fix 2** - Filter cancelled orders in `validateStockOnStagingLane` (corrects stock calculation)
3. **Fix 4** - Batch-state guard with positive state check (prevents invalid batch states)
4. **Fix 6** - Post-transfer completeness check (catches insufficient stock; Fix 7 already present)
5. **Fix 8** - Conditional bulk update queries (concurrency guard; v2-specific approach)
6. **Fix 3** - Filter in OMS message methods (defense-in-depth)
7. **Fix 5** - Filter cancelled positions within each order (defensive, low priority)

**Note:** Fix 7 is skipped -- already applied in v2.

## Testing Strategy

### Manual Test Cases

1. **Partially cancel a club batch, then run club line**
   - Create a club batch with 5 orders
   - Cancel 2 orders via OMS `/cancelPositions`
   - Verify batch remains ACTIVATED
   - Run club line
   - Verify only 3 parcels created (not 5)
   - Verify cancelled orders remain in CANCELED state
   - Verify OMS messages only reference 3 active orders

2. **Cancel all orders in a batch, then attempt run club line**
   - Create a club batch with 3 orders
   - Cancel all 3 via OMS
   - Run club line
   - Verify BusinessException thrown ("No active orders in batch to process")

3. **Stock calculation with partial cancellation**
   - Create a club batch with 10 orders
   - Stage stock for 10 orders
   - Cancel 5 orders
   - Verify stock check passes (requires stock for 5, not 10)
   - Verify all 5 active orders get correct stock allocation

4. **Position-level cancellation within active order**
   - Create a club batch where one order has 3 positions
   - Cancel 1 position within that order (order stays active)
   - Run club line
   - Verify the cancelled position does not get stock transferred

5. **Batch state guard prevents re-run**
   - Run club line successfully on a batch
   - Verify batch state is ORDER_BATCH_CLUB_RUN_FINISHED (530)
   - Attempt to run club line again
   - Verify BusinessException thrown with state mismatch message

6. **Insufficient stock triggers rollback**
   - Create a club batch with 5 orders
   - Stage stock sufficient for only 3 orders
   - Verify that when stock runs out mid-processing, the transaction rolls back (Fix 7 already present in v2)
   - Verify no ghost parcels remain after rollback

### Existing Data Check

Before deploying, query production for any existing ghost parcels:
```sql
-- Find orders that were CANCELED but now show PACKED (evidence of past bug occurrence)
SELECT co.ordernumber, co.state, co.parcel_id, cob.batchnumber
FROM customerorder co
JOIN customerorder_batch cob ON co.orderbatch_id = cob.id
WHERE co.state = 650  -- PACKED
AND co.parcel_id IS NOT NULL
AND EXISTS (
    SELECT 1 FROM customerorder_position cop
    WHERE cop.order_id = co.id
    AND cop.state = 800  -- position still CANCELED
);
```

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Fix breaks non-cancelled order processing | Low | High | `removeIf` only removes state=800; active orders unaffected |
| Concurrent cancel during club run | Low-Medium | High | Fix 8 adds `state != 800` guard to bulk UPDATE; atomic DB-level protection |
| Post-transfer check throws after partial writes | Low | Medium | Fix 7 already present in v2 ensures rollback |
| Empty batch after filtering | Medium | Low | Handled by BusinessException guard in Fix 1 |
| Fix 4 positive state check too strict | Low | Low | If other valid pre-run states exist, the guard can be expanded |
| OMS sends cancel during club run | Low | Medium | HTTP call is separate from the batch transaction; Fix 8 prevents state overwrite |
| Fix 8 query change affects other callers of `updateStateByIds` | Low | Low | No caller should ever want to overwrite CANCELED state via bulk update |

## Separate Issues Identified (Out of Scope)

These were identified during review but are separate from the cancelled-order bug:

1. **`CustomerorderPositionRepository.findByOrderBatchId()` bug** (lines 69-74): Returns positions only for the **minimum customer order ID** in the batch, not all orders. This is a separate correctness issue. (Note: v2 added `findAllPositionsByOrderBatchId` at lines 76-79 which correctly fetches all positions.)

2. **Club batch homogeneity assumption**: `validateStockOnStagingLane()` and `getClubLineSKUOverview()` both use the first order as a template and multiply by parcel count. If club batches are not guaranteed to be identical, this is a separate correctness risk.
