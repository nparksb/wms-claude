# Club Order Cancellation from OMS — Analysis & Fix Plan

**Date**: 2026-03-25
**Branch**: `tmp/np08-develop-argen-migration-gap`
**Reported Issue**: OMS displays "The order was NOT cancelled successfully!" when cancelling club orders — both single cancel and multi-select cancel.

---

## Full Cancel Flow Traced

### OMS Side (PHP)

1. `OrdersController::cancelorderAction()` (line 10609)
2. Gets batch IDs for parcels: `getBatchedParcelBatchIds($orderId)`
3. If parcels are batched → calls `cancelOrderInWms($getBatchIds, $orderId)` (line 10772)
4. Constructs payload: `[{"batch_id": "...", "facility_code": "...", "positions": [...]}]`
5. POSTs to `$wmsLocation . $wmsOrderCancelApi` (the WMS `/rest/order/cancelPositions` endpoint)
6. Checks `$wmsCancelStatus['status'] == 'success'` (line 10666)
7. If NOT 'success' → shows error: `$error_status['description']` → **"The order was NOT cancelled successfully!"**

### WMS Side (Java)

1. `OrderRestController.cancelPositions()` (line 675) — accepts `List<OrderBatchDto>`
2. For each batch → validates warehouse, batch_id, positions
3. For each order → looks up by `findByExternalNumber(unique_id)`
4. Calls `customerorderService.cancelOrder(customerOrder, false)` (line 717)
5. On success → returns HTTP 204 with `{"status": "success"}`
6. On `BusinessException` → wraps in `WebserviceBusinessExceptionClientSide` → returns HTTP 400
7. On `FacadeException` → wraps in `WebserviceBusinessExceptionClientSide` → returns HTTP 400
8. On **unchecked exception** (NPE, NSEE, IAE) → NOT caught → returns HTTP 500

---

## Root Cause Analysis

### The refactored `cancelOrder()` has a potential unchecked exception path

The `cancelOrder()` method was recently refactored with new helper methods. The code at **line 560** is the most likely failure point for RAW club orders:

```java
Section section = sectionRepository.findById(
    clientRepository.findById(customerOrder.getClientId()).get().getSectionId()
).get();
```

This chained call can throw unchecked exceptions:
- If `clientId` is null → `findById(null)` throws `IllegalArgumentException`
- If client not found → `.get()` throws `NoSuchElementException`
- If `sectionId` is null → `findById(null)` throws `IllegalArgumentException`
- If section not found → `.get()` throws `NoSuchElementException`

These are **unchecked exceptions** that bypass both `catch (BusinessException e)` and `catch (FacadeException e)` at lines 718-721 in the controller. The result is an HTTP 500, which the OMS interprets as a failure.

**This code existed before the refactoring**, but the refactoring may have changed the execution path so that this line is now reached for orders that previously took a different path. Specifically:

- **Before refactoring**: `if (customerOrder.getState() >= PACKED)` was the first guard. For RAW orders, this is false, and the flow proceeds to the section lookup. This was the same before.
- **Possible data issue**: If the dev server has clients without proper section assignments, or if a new client was created without a section, this would fail.

### Additional potential issues

1. **HTTP 204 body ignored**: The WMS returns `HttpStatus.NO_CONTENT` (204) with body `{"status": "success"}`. HTTP 204 technically means "no content" — some HTTP clients may ignore the body. The OMS checks `$jsonResponse['status'] == 'success'` which would fail if the body wasn't parsed. However, this was the same before and worked.

2. **OMS parcel `unique_id` mismatch**: The OMS sends parcel `unique_id`s from its database. The WMS looks up orders by `externalnumber`. If these don't match, the order isn't found.

3. **`finalizeBatchIfComplete()` throws**: The newly added `customerorderBatchService.finalizeBatchIfComplete()` call (line 603) could throw if the batch lookup fails. However, it handles null batch gracefully.

4. **Circular dependency**: `CustomerorderService` now autowires `CustomerorderBatchService`. If there's a circular dependency, Spring would fail at startup. But tests pass, so this is not the issue.

---

## Recommended Fixes

### Fix 1: Make the section lookup defensive (CRITICAL)

The section lookup at line 560 should NOT throw unchecked exceptions. Wrap it safely:

```java
// BEFORE (line 560):
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();

// AFTER:
Section section = null;
Optional<Client> clientOpt = clientRepository.findById(customerOrder.getClientId());
if (clientOpt.isPresent() && clientOpt.get().getSectionId() != null) {
    section = sectionRepository.findById(clientOpt.get().getSectionId()).orElse(null);
}
```

The subsequent check at line 562 already handles `section == null`:
```java
if (section != null && section.getSectionpickingtype().equals(...))
```

### Fix 2: Wrap `cancelOrder` exceptions in the controller (IMPORTANT)

The `cancelPositions` controller only catches `BusinessException` and `FacadeException`. Unchecked exceptions (NPE, NSEE, IAE) escape and cause HTTP 500. Add a catch-all:

```java
try {
    customerorderService.cancelOrder(customerOrder, false);
} catch (BusinessException e) {
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.WRONG_STATE, e, ...);
} catch (FacadeException e) {
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);
} catch (Exception e) {
    LOG.error("Unexpected error cancelling order " + order.getUniqueId(), e);
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);
}
```

This ensures ALL exceptions are returned as structured 400 responses (with error details) instead of generic 500s.

### Fix 3: Change HTTP response from 204 to 200 (RECOMMENDED)

HTTP 204 NO_CONTENT with a body is technically incorrect and some HTTP clients may ignore the body:

```java
// BEFORE:
return new ResponseEntity<>(Collections.singletonMap("status", "success"), HttpStatus.NO_CONTENT);

// AFTER:
return new ResponseEntity<>(Collections.singletonMap("status", "success"), HttpStatus.OK);
```

This ensures the OMS can always read the `{"status": "success"}` response body.

### Fix 4: Improve cancellation process (ENHANCEMENT)

Several improvements to make the cancellation more robust:

**4a. Skip already-cancelled orders silently in the controller loop:**
Currently, if one order in the batch fails, ALL orders fail (the exception exits the loop). Instead, collect errors per-order and return a mixed response:

```java
// Currently: throw on first failure (all-or-nothing)
// Improvement: collect per-order results

Map<String, String> orderResults = new LinkedHashMap<>();
for (OrderDto order : orderBatch.getPositions()) {
    try {
        customerorderService.cancelOrder(customerOrder, false);
        orderResults.put(order.getUniqueId(), "success");
    } catch (Exception e) {
        orderResults.put(order.getUniqueId(), e.getMessage());
        errors.add(getErrorMessage(order.getUniqueId(), e.getMessage()));
    }
}
```

This would allow partial success in multi-select scenarios.

**4b. Add `@Transactional` to `cancelPositions` controller:**
Currently the endpoint has no transaction boundary. Each `cancelOrder` call runs in its own transaction (from `CustomerorderService`'s class-level `@Transactional`). If a partial failure occurs, some orders are cancelled and some aren't, with no way to roll back.

---

## Implementation Priority

| Priority | Fix | Impact | Risk |
|----------|-----|--------|------|
| 1 | Defensive section lookup (Fix 1) | Critical — prevents unchecked exception | Low |
| 2 | Catch-all in controller (Fix 2) | Important — prevents 500 errors | Low |
| 3 | HTTP 200 instead of 204 (Fix 3) | Recommended — HTTP compliance | Low |
| 4 | Per-order error collection (Fix 4a) | Enhancement — partial success | Medium |

---

## Diagnostic Steps

To confirm the root cause, check the WMS server logs for:

```
grep -i "cancelPositions\|cancelOrder\|NoSuchElement\|IllegalArgument\|getSectionId\|NullPointer" wms.log
```

Look for unchecked exceptions around the time of the failed cancel request. If the logs show `NoSuchElementException` or `IllegalArgumentException` from the section/client lookup chain, Fix 1 is confirmed as the root cause.

Also check:
- Does the client associated with the club orders have a valid `section_id`?
- Does that section exist in the `section` table?

```sql
SELECT co.id, co.externalnumber, co.state, co.client_id,
       cl.cl_nr, cl.section_id, sec.name as section_name
FROM customerorder co
JOIN client cl ON co.client_id = cl.id
LEFT JOIN section sec ON cl.section_id = sec.id
WHERE co.orderbatch_id = (SELECT id FROM customerorder_batch WHERE batchid = '<batch_id>');
```

If `section_id` is NULL or the section doesn't exist, that confirms Fix 1 is needed.
