# V2 Migration Plan — Transfer Error Fix (Transfer Not Appearing in Outbound Screen)

- **Date:** 2026-03-26
- **Status:** IMPLEMENTED — All 3 code fixes applied, 5 new tests added. All tests pass.
- **Priority:** Medium
- **V1 Source Plan:** `docs/plan/v1-fixes/260424-Transfer_Error_Fix.md`
- **V1 Branch:** `develop-arden` / `release` (wms-api)
- **V2 Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## Summary

The V1 plan identified 5 findings related to transfer orders not appearing in the Outbound screen. Three code fixes were implemented in V1:
1. **Finding 4**: Transfer_id duplicate check bug — CANCELED transfers blocked re-send
2. **Finding 5**: `@Param` vs `@RequestParam` in TransfersController
3. **Finding 3**: Front-end error toasts commented out in wms-web-ui

All three fixes were confirmed **missing in V2** and have been applied.

---

## V1 Fix Applicability Analysis

| Finding | V1 Status | V2 Status | Action |
|---------|-----------|-----------|--------|
| Finding 1: Duplicate rejection diagnosis (SQL) | PENDING (manual) | NOT APPLICABLE | Operational SQL — no code change |
| Finding 2: Missing @Transactional on create() | DEFERRED | DEFERRED | Requires service extraction refactor — separate task |
| **Finding 3**: Front-end error toasts | DONE | **Was missing → FIXED** | Uncommented error toasts in wms2-web-ui |
| **Finding 4**: Transfer_id duplicate check bug | DONE | **Was missing → FIXED** | Added CANCELED state check |
| **Finding 5**: @Param → @RequestParam | DONE | **Was missing → FIXED** | Changed annotations in TransfersController |

---

## Changes by File

### 1. `OrderRestController.java` — Transfer_id Duplicate Check (Finding 4)

**V2 path:** `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java`

| # | Fix | Status | Description |
|---|-----|--------|-------------|
| **FIX-1** | Allow CANCELED transfers to be re-sent | **DONE** | Added `&& getState() != CANCELED` to duplicate check |

**Before (line 178-181):**
```java
if (coBatchTrans.isPresent() && coBatchTrans.get().getState() != WmsConstants.State.FINISHED) {
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.NOT_UNIQUE_VALUE, null, "transfer_id", orderBatch);
}
```

**After:**
```java
if (coBatchTrans.isPresent()
    && coBatchTrans.get().getState() != WmsConstants.State.FINISHED
    && coBatchTrans.get().getState() != WmsConstants.State.CANCELED) {
    // if previous transfer order exists and has not reached a terminal state (finished or cancelled)
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.NOT_UNIQUE_VALUE, null, "transfer_id", orderBatch);
}
```

**Why:** When a transfer is CANCELED (800), the user should be able to re-send the same transfer_id. The original code only excluded FINISHED (700), treating CANCELED as active and blocking re-sends.

---

### 2. `TransfersController.java` — @Param → @RequestParam (Finding 5)

**V2 path:** `src/main/java/net/aim_ai/wms/controller/TransfersController.java`

| # | Fix | Status | Description |
|---|-----|--------|-------------|
| **FIX-2** | Fix parameter annotations | **DONE** | Changed `@Param` to `@RequestParam` on 4 endpoints |

**Changes:**
- Import: `org.springframework.data.repository.query.Param` → `org.springframework.web.bind.annotation.RequestParam`
- All `@Param("...")` → `@RequestParam("...")` across 4 endpoints: `openTransfer`, `activeTransfer`, `closedTransfer`, `skus`
- Added `required = false` to `sort` and `order` parameters (they are optional)

**Why:** `@Param` is a Spring Data annotation for repository queries, not Spring MVC. Using it on controller parameters works by accident (due to `-parameters` compiler flag) but is technically incorrect and could break if the compiler configuration changes.

---

### 3. `store/outbound/transfer.js` — Error Toasts (Finding 3)

**V2 path:** `../wms2-web-ui/store/outbound/transfer.js` (separate repository)

| # | Fix | Status | Description |
|---|-----|--------|-------------|
| **FIX-3** | Restore error toasts | **DONE** | Uncommented `this.$toast.error(...)` in catch blocks |

**Changes:**
- `searchOpenTransfer` catch block (line 135): Uncommented `this.$toast.error('Error: ' + error)`
- `searchClosedTransfer` catch block (line 175): Uncommented `this.$toast.error('Error: ' + error)`

**Why:** API errors were silently swallowed — users saw empty/stale tables with no indication of failure.

---

## Testing

### New Tests Created

**File:** `src/test/java/net/aim_ai/wms/unit/controller/rest/OrderRestControllerCreateTransferTest.java` (NEW)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `createTransfer_noPriorTransferId_succeeds` | No prior transfer_id → HTTP 204 |
| 2 | `createTransfer_priorFinishedTransferId_succeeds` | FINISHED prior → allows re-send |
| 3 | `createTransfer_priorCancelledTransferId_succeeds` | CANCELED prior → allows re-send (KEY FIX TEST) |
| 4 | `createTransfer_priorActiveTransferId_rejected` | RAW prior → HTTP 400 |
| 5 | `createTransfer_duplicateBatchId_rejected` | Duplicate batch_id → HTTP 400 |

### Existing Tests

- `OrderRestControllerUnitTest`: 85 tests — all pass (no regressions)

---

## Deferred Items

### Missing @Transactional on create() (Finding 2)

**Status:** DEFERRED (same as V1)

The `create()` method in `OrderRestController` has no `@Transactional`. Each `repository.save()` auto-commits independently, risking orphan `CustomerorderBatch` records if order creation fails mid-way. The INNER JOIN in the transfer query makes orphan batches invisible to the UI.

**Why deferred:** Adding `@Transactional` directly to the controller is unsafe because the method's internal try/catch swallows exceptions and returns `ResponseEntity` — the transaction would commit even on validation failures. The proper fix requires extracting entity creation into a service method with `@Transactional(rollbackFor = Exception.class)`, which is a larger refactor.

**Recommendation:** Create a dedicated task to extract the order creation logic from `OrderRestController.create()` into a service class (e.g., `OrderBatchCreationService`) with proper transactional boundaries.

---

## Additional Recommendations

### 1. Orphan Batch Detection Query

Run periodically against production to detect orphan batches:
```sql
SELECT cb.id, cb.batchid, cb.type, cb.state, cb.transferid, cb.created
FROM customerorder_batch cb
LEFT JOIN customerorder co ON cb.id = co.orderbatch_id
WHERE co.id IS NULL AND cb.type IN ('TRANSFER_OFFSITE', 'TRANSFER_INTRACOMPANY');
```

### 2. Additional Error Toast Coverage (wms2-web-ui)

Several other methods in `store/outbound/transfer.js` also have commented-out error toasts:
- `getOrderBatches` (line ~148)
- `saveShipDate` (line ~185)
- `getOrderDetails` (line ~198)
- `getAvailableTransferLanes` (line ~211)
- `getItemInfo` (line ~225)

Consider uncomenting these in a follow-up task for complete error visibility.

### 3. Transfer_id Duplicate Check — Consider Extracting Terminal State Check

The current check uses individual state comparisons. Consider extracting a helper:
```java
private boolean isTerminalState(int state) {
    return state == WmsConstants.State.FINISHED || state == WmsConstants.State.CANCELED;
}
```
This would make the intent clearer and prevent missing states if new terminal states are added.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| CANCELED transfer re-send creates duplicate data | Low | Medium | The existing `batch_id` and `unique_id` checks still prevent true duplicates |
| @RequestParam change breaks existing API calls | None | N/A | `@RequestParam` is the correct annotation; behavior is functionally identical |
| Error toast disrupts user workflow | Low | Low | Toasts are informational; they reveal errors that were previously hidden |

---

## Implementation Status

| # | Fix | File | Status |
|---|-----|------|--------|
| FIX-1 | Transfer_id duplicate check | `OrderRestController.java` | **DONE** |
| FIX-2 | @Param → @RequestParam | `TransfersController.java` | **DONE** |
| FIX-3 | Error toasts | `wms2-web-ui/store/outbound/transfer.js` | **DONE** |
| TEST-1 | Transfer duplicate tests | `OrderRestControllerCreateTransferTest.java` | **DONE** (5 tests) |
| DEFERRED | @Transactional on create() | `OrderRestController.java` | DEFERRED (separate task) |
