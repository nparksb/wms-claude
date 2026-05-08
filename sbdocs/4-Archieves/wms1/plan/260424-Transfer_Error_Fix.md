# Transfer Not Appearing in Outbound Screen - Analysis & Fix Plan

**Date**: 2026-03-23
**Branch**: develop-arden
**Reported Issue**: Transfer with `batch_type: TRANSFER_OFFSITE` was pushed to the WMS, appears received, but does not show on the Transfers Outbound screen.

---

## Transfer Message Analyzed

```json
{
  "batch_id": "41540-1",
  "batch_type": "TRANSFER_OFFSITE",
  "transfer_id": "TCOMPANY-TestTransfer032326-01",
  "client_id": "TCOMPANY",
  "positions": [{
    "unique_id": "564058",
    "client_order_number": "TestTransfer032326-01",
    "parcel_external_number": "XN1774281569927",
    "box_sku": "Transfer",
    "fulfillment_type": "Transfer",
    "shippers_id": "TRANSFER",
    "picking_date": "2026-03-23 00:00:00"
  }]
}
```

---

## Code Path Traced

### 1. Ingestion: `PUT /rest/order/create` (OrderRestController.java:86-493)

The message enters via `OrderRestController.create()` which:
1. Validates facility_code, batch_id, priority, client_id, positions (lines 111-163)
2. For `TRANSFER_OFFSITE` batch_type: validates single order per batch, transfer_id required, transfer_id uniqueness (lines 145-159)
3. Validates order fields: unique_id, shippers_id, box_sku, fulfillment_type, weight, positions (lines 167-270)
4. Validates cross-request uniqueness: external numbers, parcel numbers (lines 311-313)
5. Creates `CustomerorderBatch` with `type="TRANSFER_OFFSITE"`, `state=RAW(0)` (lines 319-354)
6. Creates `Customerorder` with `state=RAW(0)` or `FUTURE_PICKING_DATE(80)` (lines 374-426)
7. Creates `CustomerorderPosition` records (lines 435-456)
8. Logs success message with status `RECEIVED` (lines 461-469)
9. Returns HTTP 204 on success (line 476)

### 2. Display: `GET /v3/transfers/openTransfer` (TransfersController.java:276-293)

The Open Transfers tab calls `ViewDtoService.getOpenTransfer()` (ViewDtoService.java:216-224) which executes `CustomerorderBatchRepository.getTransferBatchOrders()` (CustomerorderBatchRepository.java:105-116):

```sql
SELECT cb.id, cb.batchId, ... co.state as status, count(co.id) as parcels, ...
FROM customerorder_batch cb
JOIN client c ON cb.client_id = c.id
JOIN customerorder co ON cb.id = co.orderbatch_id       -- INNER JOIN
LEFT JOIN location lo ON co.transferlane_id = lo.id
WHERE co.state >= 0 AND co.state <= 670                 -- RAW to PALLETIZED
AND cb.type IN ('TRANSFER_OFFSITE', 'TRANSFER_INTRACOMPANY')
AND CONCAT(LOWER(cb.batchid), ' ', LOWER(c.name)) LIKE LOWER(concat('%', :keyword, '%'))
GROUP BY ...
```

---

## Root Cause Analysis

### Finding 1 (MOST LIKELY): Duplicate Rejection - Transfer Never Created

**Severity: HIGH**

The `create()` method has multiple uniqueness checks that would reject the transfer with HTTP 400:

| Check | Location | Condition |
|-------|----------|-----------|
| Duplicate `batch_id` | Line 139-141 | If `batch_id` "41540-1" already exists in `customerorder_batch.batchid` |
| Duplicate `transfer_id` | Line 155-159 | If `transfer_id` "TCOMPANY-TestTransfer032326-01" exists AND batch state != FINISHED(700) |
| Duplicate `unique_id` (order) | Line 311 | If `unique_id` "564058" exists in `customerorder.externalnumber` |
| Duplicate `unique_id` (position) | Line 312 | If position unique_ids "564058-0"/"564058-1" exist in `customerorder_position.externalid` |
| Duplicate `parcel_external_number` | Line 313 | If "XN1774281569927" exists in `customerorder.parcelexternalnumber` or `unitload.labelid` |

**If this transfer was sent before (e.g., during testing), any subsequent attempt would be silently rejected.** The user may see a "RECEIVED" status in the Messages table from the FIRST successful import, not realizing the second attempt created a "FAILED" message alongside it.

**Diagnostic Steps:**
```sql
-- Check if the batch exists
SELECT id, batchid, type, state, transferid, created
FROM customerorder_batch
WHERE batchid = '41540-1' OR transferid = 'TCOMPANY-TestTransfer032326-01';

-- Check for the order
SELECT co.id, co.externalnumber, co.state, co.orderbatch_id, co.clientordernumber
FROM customerorder co
WHERE co.externalnumber = '564058';

-- Check Messages table for both RECEIVED and FAILED entries
SELECT id, process_type, status, response_code, created
FROM message
WHERE process_type = 'ORDER_BATCH_IMPORT'
ORDER BY created DESC
LIMIT 10;
```

### Finding 2: Missing @Transactional - Orphan Batch Risk

**Severity: MEDIUM**

The `create()` method (OrderRestController.java:86-493) has **NO `@Transactional` annotation**. Each `repository.save()` call auto-commits independently. If:
1. `CustomerorderBatch` saves successfully (line 351) - COMMITTED
2. `Customerorder` save fails (line 423) with an uncaught exception (e.g., `DataIntegrityViolationException`)

Result: An orphan `CustomerorderBatch` exists with NO associated `Customerorder`. The transfer query uses **INNER JOIN** on `customerorder`, so orphan batches are invisible to the UI.

**Note:** If this occurred, the success message log (lines 461-469) would NOT be created, and the HTTP response would be 500 (not 204). So this scenario is only possible if the user didn't verify the actual HTTP response.

**Diagnostic Steps:**
```sql
-- Find orphan batches (batches with no orders)
SELECT cb.id, cb.batchid, cb.type, cb.state, cb.transferid, cb.created
FROM customerorder_batch cb
LEFT JOIN customerorder co ON cb.id = co.orderbatch_id
WHERE co.id IS NULL AND cb.type IN ('TRANSFER_OFFSITE', 'TRANSFER_INTRACOMPANY');
```

### Finding 3: Front-End Error Swallowing

**Severity: MEDIUM**

The Vuex store actions (store/outbound/transfer.js) catch API errors but the error toast is **commented out**:

```javascript
// store/outbound/transfer.js:96-99
} catch (error) {
    console.log(error);
    // this.$toast.error('Error: ' + error)  // <-- COMMENTED OUT
}
```

If the API returns any error (400, 500), the front-end silently swallows it. The user sees an empty or stale table with no indication of failure. This applies to BOTH `searchOpenTransfer` (line 96) and `searchClosedTransfer` (line 134).

### Finding 4: transfer_id Duplicate Check Bug - Comment/Code Mismatch

**Severity: LOW (but a latent bug)**

`OrderRestController.java:155-159`:
```java
if (coBatchTrans.isPresent() && coBatchTrans.get().getState() != WmsConstants.State.FINISHED) {
    // if previous transfer order exists and has not been cancelled  <-- WRONG COMMENT
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.NOT_UNIQUE_VALUE, ...);
}
```

The comment says "has not been cancelled" but the code checks `!= FINISHED (700)`, NOT `!= CANCELED (800)`. This means:
- **FINISHED (700) transfers**: CAN be re-used (correct)
- **CANCELED (800) transfers**: CANNOT be re-used (800 != 700 is true, so exception is thrown)

If the user previously created this transfer and then CANCELLED it, trying to re-send would be blocked. This is likely unintended behavior.

### Finding 5: @Param vs @RequestParam in Controller

**Severity: LOW**

`TransfersController.java:26` imports `org.springframework.data.repository.query.Param` (Spring Data annotation). The controller methods use `@Param("keyword")` etc. (lines 277-281) instead of the correct `@RequestParam("keyword")` (Spring MVC annotation).

This works because Spring Boot's default Maven compiler uses `-parameters` flag, allowing Spring MVC to resolve parameters by their Java names. However, it's technically incorrect and could break if the compiler configuration changes.

---

## Recommended Fix Plan

### Step 1: Diagnose (Immediate - No Code Changes)

Run the diagnostic SQL queries from Finding 1 above against the production/staging database to determine if:
- The batch was created or rejected
- There are orphan batches
- There are duplicate RECEIVED/FAILED message entries

### Step 2: Fix Transfer Duplicate Check (Finding 4) -- IMPLEMENTED

**Status**: DONE
**File**: `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java`
**Lines**: 155-160

Changed the transfer_id duplicate check to also allow CANCELED transfers to be re-sent:

```java
if (coBatchTrans.isPresent()
    && coBatchTrans.get().getState() != WmsConstants.State.FINISHED
    && coBatchTrans.get().getState() != WmsConstants.State.CANCELED) {
    // if previous transfer order exists and has not reached a terminal state (finished or cancelled)
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.NOT_UNIQUE_VALUE, null, "transfer_id", orderBatch);
}
```

**Tests**: 7 new unit tests in `OrderRestControllerCreateTransferTest.java`:
- `createTransfer_noPriorTransferId_succeeds` — no prior transfer_id, 204
- `createTransfer_priorFinishedTransferId_succeeds` — FINISHED prior, 204
- `createTransfer_priorCancelledTransferId_succeeds` — CANCELED prior, 204 (key fix test)
- `createTransfer_priorActiveTransferId_rejected` — RAW prior, 400
- `createTransfer_priorActivatedTransferId_rejected` — ACTIVATED prior, 400
- `createTransfer_missingTransferId_rejected` — null transfer_id, 400
- `createTransfer_duplicateBatchId_rejected` — duplicate batch_id, 400

### Step 3: Add @Transactional to create() (Finding 2) -- DEFERRED

**Status**: DEFERRED (requires separate task)

Adding `@Transactional` directly to the controller method is unsafe because the method's internal try/catch swallows `WebserviceBusinessExceptionClientSide` and returns a `ResponseEntity` — the transaction would commit even on validation failures. The proper fix requires extracting entity creation into a service method with `@Transactional(rollbackFor = Exception.class)`, which is a larger refactor best done in a dedicated task.

### Step 4: Restore Front-End Error Toasts (Finding 3) -- IMPLEMENTED

**Status**: DONE
**File**: `wms-web-ui/store/outbound/transfer.js`

Uncommented error toasts in both `searchOpenTransfer` (line 98) and `searchClosedTransfer` (line 135) actions so API errors are now visible to users.

### Step 5: Fix @Param Annotations (Finding 5) -- IMPLEMENTED

**Status**: DONE
**File**: `src/main/java/net/aim_ai/wms/controller/TransfersController.java`

- Changed import from `org.springframework.data.repository.query.Param` to `org.springframework.web.bind.annotation.RequestParam`
- Changed all `@Param("...")` to `@RequestParam("...")` across 4 endpoints: `openTransfer`, `activeTransfer`, `closedTransfer`, `skus`
- Added `required = false` to `sort` and `order` parameters since they are optional

---

## Implementation Status

| Priority | Fix | Status | Impact | Risk |
|----------|-----|--------|--------|------|
| 1 | Run diagnostic SQL (Step 1) | PENDING (manual) | Confirms root cause | None |
| 2 | Fix transfer_id duplicate check (Step 2) | DONE | Unblocks cancelled transfer re-sends | Low |
| 3 | Restore front-end error toasts (Step 4) | DONE | Makes API errors visible to users | None |
| 4 | Add @Transactional (Step 3) | DEFERRED | Prevents orphan batches | Medium - needs service extraction |
| 5 | Fix @Param annotations (Step 5) | DONE | Correctness, prevents future breakage | Low |

---

## Files Changed

### Backend (wms-api)
- `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java` — transfer_id duplicate check fix
- `src/main/java/net/aim_ai/wms/controller/TransfersController.java` — @Param → @RequestParam fix
- `src/test/java/net/aim_ai/wms/unit/controller/rest/OrderRestControllerCreateTransferTest.java` — NEW: 7 unit tests

### Frontend (wms-web-ui)
- `store/outbound/transfer.js` — restored error toasts in searchOpenTransfer and searchClosedTransfer

---

## Summary

The transfer ingestion code and the outbound screen query both correctly handle `TRANSFER_OFFSITE` batch types. The most probable cause is that **the transfer was rejected due to a duplicate `batch_id`, `transfer_id`, or `unique_id` from a prior test attempt**, and the user saw an older "RECEIVED" message entry rather than the rejection. The front-end's silent error handling (commented-out error toasts) compounds the problem by hiding any API errors from the user.

The transfer_id duplicate check also had a bug where CANCELED transfers block re-sending (checking `!= FINISHED` instead of checking for terminal states), which would prevent re-sending a previously cancelled transfer. This has been fixed.
