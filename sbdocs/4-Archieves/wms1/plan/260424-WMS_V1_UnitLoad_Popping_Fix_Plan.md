# WMS V1 — Unit Load "Popping" Fix Plan

**Date:** 2026-02-13
**Based on:** `docs/WMS_V1_UnitLoad_Popping_Root_Cause_Analysis.md`
**Branch:** `release`
**Status:** Phase 1, Phase 2, and Phase 3 implemented. Phase 4 (optional hardening) pending.

---

## Corrections to Original Root Cause Analysis

Before detailing the fix plan, the following corrections to the original RCA are important:

### Correction 1: `spring.jpa.open-in-view` is NOT `false`

The RCA states `spring.jpa.open-in-view=false` at "application.properties line 40". This is **incorrect** — line 40 is `spring.jpa.show-sql=false`. The `open-in-view` property is **not set anywhere** in the codebase, meaning Spring Boot 2.3.7 uses the **default value `true`**.

**Impact on analysis:** The core conclusion remains correct — `OpenEntityManagerInView` keeps the `EntityManager` open for lazy loading but does **NOT** wrap the request in a transaction. Each `repository.save()` still auto-commits in its own micro-transaction via `SimpleJpaRepository.save()` which has its own `@Transactional`. The missing service-level `@Transactional` is still the root cause.

### Correction 2: Use `@Transactional`, NOT `@Transactional("tenantTransactionManager")`

The RCA recommends `@Transactional("tenantTransactionManager")`. **No named transaction manager exists in this codebase.** The project uses Spring Boot's auto-configured default `transactionManager`. All 17 existing `@Transactional` annotations use either plain `@Transactional` or `@Transactional(propagation = Propagation.REQUIRES_NEW)` — none reference a named manager.

Using `@Transactional("tenantTransactionManager")` would cause Spring to look for a non-existent bean and likely fail or silently not wrap in a transaction.

### Correction 3: Additional Bugs Discovered

Two additional bugs were found during code verification:

1. **`UnitloadRecordService.createRecord()` calls `getNextId()` TWICE** (lines 44 and 59) — the second call is inside a `LOG.info()` statement, burning an extra sequence number on every record creation and potentially causing sequence gaps or ID conflicts.

2. **`UnitloadBusinessService.transferUnitLoadToLocation()` swallows exceptions on carrier detach** (lines 130-135) — when removing a unit load from its carrier, the `save()` failure is caught and logged but execution continues to `processTransfer()`, which could save inconsistent state.

3. **`StockUnitController.bulkTransferStock()` has an empty catch block** (lines 159-161) — silently swallows any exception from the outer loop, including `NumberFormatException` or `NoSuchElementException`.

---

## Fix Plan

### Phase 1: Immediate Critical Fixes (New Code on Feature Branch off `release`)

These are the highest priority — direct fixes for the production "popping" issue.

---

#### Fix 1: Add `@Transactional` to Move/Transfer Service Methods

**Why:** Without `@Transactional`, each `repository.save()` auto-commits independently. If the location change commits but the history record fails, the move is invisible.

**Files and changes:**

**File: `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java`**

```java
// ADD import:
import org.springframework.transaction.annotation.Transactional;

// ADD annotation to scanDestination() (line 181):
@Transactional
public void scanDestination(TransferInfoDto dto) throws BusinessException, FacadeException {
```

**File: `src/main/java/net/aim_ai/wms/service/StockunitService.java`**

```java
// ADD import:
import org.springframework.transaction.annotation.Transactional;

// ADD annotation to transferStock() (line 101):
@Transactional
public void transferStock(Stockunit stockUnit, BigDecimal amountToTransfer, ...) throws BusinessException, FacadeException {
```

**File: `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`**

```java
// ADD annotation to finishReplenishmentOrder() (line 365):
@Transactional
public void finishReplenishmentOrder(ReplenishMobileOrderDto mobileOrder) throws FacadeException, BusinessException {

// ADD annotation to finishReplenishmentOrderInternal() (line 373):
@Transactional
private void finishReplenishmentOrderInternal(ReplenishMobileOrderDto mobileOrder, boolean triggerRefill)
```

> **Note on `private` method:** `@Transactional` on `finishReplenishmentOrderInternal()` only works when called from within the same bean if a transaction is already active (via `finishReplenishmentOrder()`). Since `finishReplenishmentOrder()` always calls `finishReplenishmentOrderInternal()`, and both `finishReplenishmentOrder()` and `fulfillMultipleUnitLoads()` (which already has `@Transactional`) are the only callers, this effectively covers all entry points. The `@Transactional` on the private method serves as documentation of intent — the actual transaction boundary is at the public method.

**File: `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`**

```java
// ADD import:
import org.springframework.transaction.annotation.Transactional;

// ADD annotation to transferUnitLoadToLocation() (line 70):
@Transactional
public void transferUnitLoadToLocation(Unitload unitload, Location destinationLocation, ...) throws FacadeException, BusinessException {

// ADD annotation to transferUnitLoadToCarrier() (line 147):
@Transactional
public void transferUnitLoadToCarrier(Unitload staleUnitload, Unitload destinationUnitload, ...) throws FacadeException, BusinessException {
```

**File: `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java`**

```java
// ADD import:
import org.springframework.transaction.annotation.Transactional;

// ADD annotation to transferStockToUnitLoad() (line 118):
@Transactional
public Stockunit transferStockToUnitLoad(Stockunit sourceStockunit, Unitload destinationUnitload, ...) throws FacadeException, BusinessException {

// ADD annotation to changeReservedAmount() (line 310):
@Transactional
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount, ...) throws FacadeException {
```

**Risk:** Low. Standard Spring pattern. Transactions will hold DB connections slightly longer. Since `transferUnitLoadToLocation` calls `processTransfer` recursively (for child unit loads), the transaction scope includes all child moves — this is actually **correct and desired** behavior (all-or-nothing for the entire move tree).

**Nesting behavior:** When `scanDestination()` calls `unitloadBusinessService.transferUnitLoadToLocation()`, the inner `@Transactional` will **join** the outer transaction (default `Propagation.REQUIRED`). This is the desired behavior — one transaction for the entire operation.

---

#### Fix 2: Remove Exception Swallowing in History Recording

**Why:** `UnitloadRecordService.createRecord()` catches and swallows ALL exceptions from `unitloadRecordRepository.save(rec)`. Combined with Fix 1, this catch block would prevent the transaction from rolling back when history recording fails.

**File: `src/main/java/net/aim_ai/wms/service/UnitloadRecordService.java`**

**Before** (lines 64-68):
```java
try {
    unitloadRecordRepository.save(rec);
} catch (Exception e) {
    LOG.error("e: " + e.getMessage());
}
```

**After:**
```java
unitloadRecordRepository.save(rec);
```

**Risk:** Medium. If there are legitimate scenarios where the record save fails (missing required fields, constraint violations), moves will now fail entirely instead of succeeding silently. This is **correct behavior** — a move without history is worse than a failed move. Review production error logs for `"e: "` messages from `UnitloadRecordService` before deploying to understand if there are pre-existing record save failures.

**Pre-deployment check:** Search production logs for:
```
grep "UnitloadRecordService.*e: " /path/to/logs
```
If there are frequent record save failures, investigate and fix the root cause before deploying this change.

---

#### Fix 3: Fix Record Type for Transfers

**Why:** `recordForTransferUnitLoad()` uses `CREATED` instead of `TRANSFERRED`, making transfer records invisible to any query filtering by record type.

**File: `src/main/java/net/aim_ai/wms/service/UnitloadRecordService.java`**

**Before** (line 38):
```java
createRecord(WmsConstants.UnitloadRecordType.CREATED, clientId, unitLoad, sourceUnitLoad, ...);
```

**After:**
```java
createRecord(WmsConstants.UnitloadRecordType.TRANSFERRED, clientId, unitLoad, sourceUnitLoad, ...);
```

**Risk:** Low. This corrects the record type to its intended value. Verify that no downstream queries filter for `CREATED` when expecting transfer records.

---

#### Fix 4: Remove Double `getNextId()` Call in History Recording

**Why:** `createRecord()` calls `unitloadRecordRepository.getNextId()` on line 44 to set the ID, then calls it **again** on line 59 inside a `LOG.info()` statement. This burns an extra sequence number per record and could cause ID collisions if the sequence is shared.

**File: `src/main/java/net/aim_ai/wms/service/UnitloadRecordService.java`**

**Before** (line 59):
```java
LOG.info("unitloadRecordRepository.getNextId() " + unitloadRecordRepository.getNextId());
```

**After:**
```java
LOG.info("unitloadRecord created with id=" + rec.getId());
```

**Risk:** None. Pure bug fix — removes side-effectful logging.

---

#### Fix 5: Fix Exception Swallowing on Carrier Detach

**Why:** In `transferUnitLoadToLocation()`, when a unit load is being detached from its carrier, the `save()` exception is swallowed. If this fails, `processTransfer()` continues with potentially stale/inconsistent state.

**File: `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`**

**Before** (lines 130-136):
```java
try {
    unitload = unitloadRepository.save(unitload);
} catch (Exception e) {
    LOG.error("Error in transferUnitLoadToLocation with unitload: " + unitload.getId());
    LOG.error("StaleObjectStateException", e);
}
```

**After:**
```java
unitload = unitloadRepository.save(unitload);
```

With `@Transactional` from Fix 1 now wrapping this method, any save failure will properly roll back the entire operation. The original try-catch was a workaround for the lack of transactions — it's no longer needed and is actively harmful.

**Risk:** Low. With Fix 1 in place, exceptions will trigger a full rollback instead of leaving partial state.

---

### Phase 2: SBDEV-1710 — Pessimistic Locking on `changeReservedAmount()` (DONE)

**Status:** Implemented manually (cherry-pick had conflicts with Phase 1 changes).

**Why:** `changeReservedAmount()` has a read-modify-write race condition. Two concurrent calls can read the same `reservedamount`, both add their amount, and the last write wins — losing one reservation.

**What was applied (equivalent to SBDEV-1710 commit `c4ac107`):**

1. Added `findByIdForUpdate()` with `@Lock(LockModeType.PESSIMISTIC_WRITE)` to `StockunitRepository`
2. Changed `changeReservedAmount()` to use `findByIdForUpdate()` instead of `findById()` — acquires a PostgreSQL `SELECT ... FOR UPDATE` row lock
3. Removed stale `System.out.println("before decimal comparison")` debug line

**Files changed:**

| File | Change |
|------|--------|
| `repo/jpa/StockunitRepository.java` | Added `findByIdForUpdate()` with `@Lock(PESSIMISTIC_WRITE)` |
| `service/StockunitBusinessService.java` | `changeReservedAmount()` now uses `findByIdForUpdate()` for row-level locking |

**Risk:** Medium. Pessimistic locking can cause deadlocks if two transactions lock resources in different orders. Test with concurrent batch processing (order release + replenishment generation) in UAT. Monitor for `LockTimeoutException` or deadlock errors.

---

### Phase 3: Merge from `develop` (SBDEV-1742)

**Why:** Without `ReplenishmentOrderMaintenanceService`, replenishment orders never update when stock moves. The dashboard shows stale source locations indefinitely.

**What to merge:**

| File | Description |
|------|-------------|
| `ReplenishmentOrderMaintenanceService.java` | **New file** — 489-line service that recalculates open replenishment orders |
| `StockunitService.java` | Add `triggerReplenishmentMaintenance()` calls after stock operations |
| `ReplenishOrderJob.java` | Add `recalculateOpenOrders()` call in scheduled job |
| `StockunitRepository.java` | Add `getStockAndReservedForLocation()`, `getStockAndReservedForPickingAreas()`, `getAvailableReplenishmentSources()` |

**Risk:** High. This is a large change with new business logic. Requires thorough UAT testing of the full replenishment lifecycle:
- Create replenishment order
- Move source stock to a different location
- Verify replenishment order updates its `requestedlocationId`
- Verify scheduled job recalculation
- Verify no regressions in existing replenishment flow

---

### Phase 4 (Optional): Additional Hardening

These are not root causes of the current issue but are related weaknesses found during investigation.

#### Fix 6: Add `@Transactional` to `MobileReplenishService.checkSource()`

`checkSource()` (line 216) calls `changeReservedAmount()` twice — once to unreserve from the old stock unit (line 277), once to reserve on the new one (line 284). Without a wrapping transaction, a failure between these two calls leaves reservations in an inconsistent state.

```java
@Transactional
public ReplenishMobileOrderDto checkSource(ReplenishMobileOrderDto mOrder, String code) throws FacadeException, BusinessException {
```

#### Fix 7: Fix Empty Catch Block in `StockUnitController.bulkTransferStock()`

Lines 159-161 silently swallow all exceptions from the outer loop:
```java
} catch (Exception e) {
    // Error
}
```

Change to:
```java
} catch (Exception e) {
    LOG.error("Error in bulkTransferStock", e);
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
}
```

---

## Implementation Order

```
Phase 1 (feature branch off release)     Phase 2 (SBDEV-1710)          Phase 3 (merge)
┌──────────────────────────────────┐     ┌─────────────────────────┐   ┌──────────────────────┐
│ Fix 1: @Transactional on moves   │     │ SBDEV-1710:             │   │ SBDEV-1742:          │
│ Fix 2: Remove exception catch    │────>│ Pessimistic lock on     │──>│ Replenishment order  │
│ Fix 3: CREATED → TRANSFERRED     │     │ changeReservedAmount    │   │ maintenance service  │
│ Fix 4: Double getNextId()        │     │ via findByIdForUpdate() │   └──────────────────────┘
│ Fix 5: Carrier detach catch      │     └─────────────────────────┘
└──────────────────────────────────┘
         DONE (commit cfc3ae2)              DONE (commit 85f786f)        DONE (this commit)
```

**Phase 1 can be deployed independently** and will immediately fix the "moved without history" problem. Phases 2 and 3 build on it.

---

## Files Changed Summary

### Phase 1 (4 files)

| File | Changes |
|------|---------|
| `service/UnitloadBusinessService.java` | Add `@Transactional` to `transferUnitLoadToLocation()` and `transferUnitLoadToCarrier()`; remove exception swallowing on carrier detach save (lines 130-135) |
| `service/UnitloadRecordService.java` | Remove try-catch in `createRecord()` (lines 64-68); fix record type `CREATED` → `TRANSFERRED` in `recordForTransferUnitLoad()` (line 38); fix double `getNextId()` call (line 59) |
| `service/mobile/MobileMoveUnitloadService.java` | Add `@Transactional` to `scanDestination()` |
| `service/StockunitService.java` | Add `@Transactional` to `transferStock()` |
| `service/StockunitBusinessService.java` | Add `@Transactional` to `transferStockToUnitLoad()` and `changeReservedAmount()` |
| `service/mobile/MobileReplenishService.java` | Add `@Transactional` to `finishReplenishmentOrder()` and `finishReplenishmentOrderInternal()` |

### Phase 2 (2 files — cherry-pick SBDEV-1710)

| File | Changes |
|------|---------|
| `repo/jpa/StockunitRepository.java` | Add `findByIdForUpdate()` with `@Lock(PESSIMISTIC_WRITE)` |
| `service/StockunitBusinessService.java` | Use `findByIdForUpdate()` in `changeReservedAmount()` |

### Phase 3 (6 files — merge SBDEV-1742)

| File | Changes |
|------|---------|
| `service/ReplenishmentOrderMaintenanceService.java` | **New file** — 489-line service that recalculates open replenishment orders |
| `service/StockunitService.java` | Add `@Autowired ReplenishmentOrderMaintenanceService`; add `triggerReplenishmentMaintenance()` private method; add 6 trigger calls after `transferStock`, `setLockOnHold`, `setLockDamaged`, `adjustAmount`, `adjustReservedAmount`, `removeLock` |
| `schedulejob/ReplenishOrderJob.java` | Add `@Autowired ReplenishmentOrderMaintenanceService`; add `recalculateOpenOrders()` call after `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` |
| `repo/jpa/StockunitRepository.java` | Add 3 new query methods: `getStockAndReservedForLocation()`, `getStockAndReservedForPickingAreas()`, `getAvailableReplenishmentSources()` |
| `repo/jpa/ReplenishorderRepository.java` | Add `findByState()` and `sumRequestedAmountForOpenOrders()` methods |
| `service/WmsConstants.java` | Add 4 new system property constants for replenishment recalculation cadence and cancel threshold |

---

## Testing Checklist

### Pre-Deployment

- [ ] **Search production logs** for `UnitloadRecordService` errors: `grep "e: " logs` — understand if record saves are currently failing and why
- [ ] **Run SQL on shipitez tenant** to find affected unit loads:
```sql
-- Unit loads that changed location but have no unitload_record
SELECT u.id, u.labelid, u.storagelocation_id, u.modified
FROM unitload u
WHERE u.modified > NOW() - INTERVAL '30 days'
AND NOT EXISTS (
    SELECT 1 FROM unitload_record ur
    WHERE ur.label = u.labelid
    AND ur.created > u.modified - INTERVAL '1 minute'
);
```

### Phase 1 Post-Deployment

- [ ] **Move unit load via mobile UI** → verify location change AND history record both exist (or both absent on failure)
- [ ] **Transfer stock via web UI** → verify location change AND stock record are atomic
- [ ] **Simulate history record failure** (e.g., null required field) → verify entire move rolls back — unit load stays at original location
- [ ] **Move a unit load** → verify `unitload_record.recordtype` is `TRANSFERRED`, not `CREATED`
- [ ] **Move unit load from carrier** → verify carrier detach + location change + history are all in one transaction
- [ ] **Check recursive child moves** → move a pallet with child unit loads → verify all children are moved atomically

### Phase 2 Post-Deployment

- [ ] **Concurrent reserved amount changes** → trigger parallel order release for the same item → verify reserved amounts are correct (no lost updates)
- [ ] **Monitor for deadlocks** → watch for `PessimisticLockException` or PostgreSQL deadlock errors during batch processing

### Phase 3 Post-Deployment

- [ ] **Move stock from location A to B** → verify replenishment order `requestedlocationId` updates to B
- [ ] **Run `ReplenishOrderJob`** → verify `recalculateOpenOrders()` executes without errors
- [ ] **End-to-end replenishment flow** → OMS order → order release → replenishment generation → stock move → verify dashboard shows correct location

### UL007670 Specific

- [ ] After all phases deployed, manually verify/correct UL007670:
  - Current location matches database record
  - Replenishment order updated or cancelled/regenerated
  - Dashboard shows correct information

---

## Rollback Plan

**Phase 1:** Revert the feature branch merge. Since the changes only add `@Transactional` and remove try-catch blocks, reverting returns to the original (broken but familiar) behavior.

**Phase 2:** Revert the cherry-pick. This restores the non-locking `findById()` call.

**Phase 3:** Revert the merge. This removes the maintenance service. Replenishment orders will stop auto-updating but will not corrupt data.

Each phase can be rolled back independently without affecting the others, except that Phase 2 builds on Phase 1's `@Transactional` for `changeReservedAmount()`.

---

## Data Correction

After deploying at minimum Phase 1, run the following against the shipitez tenant database:

```sql
-- 1. Identify UL007670's current actual location
SELECT u.id, u.labelid, u.storagelocation_id, l.name as location_name
FROM unitload u
JOIN storagelocation l ON l.id = u.storagelocation_id
WHERE u.labelid = 'UL007670';

-- 2. Find any stale replenishment orders referencing UL007670's old location
SELECT r.id, r.number, r.requestedlocation_id, r.destination_id, r.state,
       rl.name as requested_location, dl.name as destination_location
FROM replenishorder r
LEFT JOIN storagelocation rl ON rl.id = r.requestedlocation_id
LEFT JOIN storagelocation dl ON dl.id = r.destination_id
WHERE r.state < 700  -- not finished
AND r.requestedlocation_id IN (
    SELECT id FROM storagelocation WHERE name = 'A204FY'
);

-- 3. After verifying, cancel stale replenishment orders
-- UPDATE replenishorder SET state = 800 WHERE id = <identified_ids>;
```
