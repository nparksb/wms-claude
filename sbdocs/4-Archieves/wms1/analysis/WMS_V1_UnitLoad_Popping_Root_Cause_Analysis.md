# WMS V1 — Unit Load "Popping" Between Locations with No History (ShipItEZ)

**Date:** 2026-02-12
**Status:** In Progress
**Priority:** Critical
**Instance:** ShipItEZ (WMS v1, `origin/release` branch, `:uat` container image)
**Reported By:** CSR / WMS Engineer (Brent Campbell, Nam Park)

---

## Problem Statement

Unit loads are mysteriously moving between locations in the ShipItEZ WMS instance without any history being recorded. Specifically:

- **Unit Load UL007670** containing product **PGB20C** was instructed to move from **A204FY** to **A204B7**, but appeared at **A104FZ** instead
- No unit load record (move history) exists for UL007670 — searching the container record yields a blank result
- The replenishment dashboard still shows the old source location (A204FY) instead of the actual current location (A104FZ)
- The database shows conflicting records: one showing 120 units in A204FY, another showing UL007670 on A104FZ with 120 units
- The "replenish from location" field has not updated, preventing the replenishment order from being corrected
- Replenishments that were previously fixed are suddenly reverting to having issues
- The move most likely happened from the **desktop/web UI**, not mobile UI
- Last deployment was around 1/30/26

---

## Root Cause Analysis

### Investigation Scope

Analyzed the full call chain for both mobile and web UI move/transfer paths on the `origin/release` branch. Performed a comprehensive branch discrepancy analysis between `origin/release` (production) and `origin/develop` to identify missing fixes.

### 🚨 CRITICAL #1: Complete Absence of Transaction Boundaries on Move Paths

The **entire unit load move flow** has **ZERO `@Transactional` annotations** at every level of the call chain, for BOTH mobile and web UI paths:

**Mobile UI Path:**
```
MoveUnitloadController.selectStock()                    → NO @Transactional
  └─ MobileMoveUnitloadService.scanDestination()         → NO @Transactional
       └─ UnitloadBusinessService.transferUnitLoadToLocation() → NO @Transactional
            └─ UnitloadBusinessService.processTransfer()       → NO @Transactional
```

**Web UI Path:**
```
StockUnitController.transferStock()                      → NO @Transactional
  └─ StockunitService.transferStock()                     → NO @Transactional
       └─ StockunitBusinessService.transferStockToUnitLoad() → NO @Transactional
```

Combined with `spring.jpa.open-in-view=false` (application.properties line 40), Spring does **not** auto-wrap web requests in a transaction. Every `repository.save()` call auto-commits immediately in its own micro-transaction.

In `UnitloadBusinessService.processTransfer()` (lines 231-250):
```java
unitload.setStoragelocationId(destinationLocation.getId());
unitload = unitloadRepository.save(unitload);  // ← AUTO-COMMITS IMMEDIATELY
unitloadRecordService.recordForTransferUnitLoad(unitload, sourceLocation, destinationLocation, ...);
// ↑ If this fails, the location change is ALREADY committed. No rollback possible.
```

**Impact:** The unit load location change is permanently committed before history recording is even attempted. If anything goes wrong after the save, the move is "done" but invisible.

### 🚨 CRITICAL #2: Silent Exception Swallowing in History Recording

`UnitloadRecordService.createRecord()` (lines 58-62) catches and **swallows ALL exceptions**:
```java
try {
    unitloadRecordRepository.save(rec);
} catch (Exception e) {
    LOG.error("e: " + e.getMessage());  // Logged but NOT re-thrown!
}
```

Combined with Critical #1, this **guarantees** the "moved without history" scenario: the location change auto-commits, then if the history record save fails for any reason (constraint violation, optimistic lock, connection issue), the exception is silently swallowed and the method returns normally.

### 🚨 CRITICAL #3: No Replenishment Order Maintenance in Production

The `ReplenishmentOrderMaintenanceService` — a **489-line service** that continuously recalculates open replenishment orders — exists **only in the `develop` branch** and is completely missing from `release` (production).

Without this service:
- Replenishment orders **never update** when stock moves to a different location
- The `requestedlocationId` (source) remains stale after stock is moved
- The `destinationId` is never realigned when fixed location assignments change
- The `requestedamount` is never recalculated when stock levels change
- The `stockunitId` is never revalidated
- The scheduled `ReplenishOrderJob` does NOT call `recalculateOpenOrders()`

**This directly explains why the dashboard shows A204FY instead of A104FZ** — the replenishment order was never recalculated after the stock moved.

### ⚠️ ISSUE #4: Wrong Record Type for Transfers

`UnitloadRecordService.recordForTransferUnitLoad()` (line 35) uses `WmsConstants.UnitloadRecordType.CREATED` instead of `TRANSFERRED`. Any queries filtering for transfer records will find nothing.

### ⚠️ ISSUE #5: `changeReservedAmount()` Race Condition (SBDEV-1710 Missing from Release)

The `changeReservedAmount()` method in production has **no `@Transactional` annotation** and **no pessimistic locking**:
```java
// RELEASE BRANCH (production):
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount, ...) {
    Stockunit stockUnit = stockunitRepository.findById(staleStockUnit.getId()).orElseThrow(...);
    BigDecimal newReservedAmount = stockUnit.getReservedamount().add(amount);
    // ⚠️ Between this read and the save, another thread can read the SAME old value
    stockUnit.setReservedamount(newReservedAmount);
    stockUnit = stockunitRepository.save(stockUnit);  // Last-write-wins!
}
```

The `develop` branch (SBDEV-1710) fixes this with `@Transactional` + `@Lock(LockModeType.PESSIMISTIC_WRITE)` via `findByIdForUpdate()`. This fix is NOT in production.

### ⚠️ ISSUE #6: No `@Transactional` on Replenishment Finish

`MobileReplenishService.finishReplenishmentOrder()` and `finishReplenishmentOrderInternal()` have no `@Transactional` annotation, creating the same auto-commit risk as the move paths.


---

## OMS Batching Connection

### Question: Could OMS batching issues yesterday have caused WMS issues today?

**Answer: OMS batching was the _trigger_, not the _cause_.** It created the demand that set the broken WMS machinery in motion. The actual root causes are the three critical bugs above that exist in WMS regardless of OMS.

### Chain of Events

```
OMS Batching (Yesterday)
    │
    ▼
WMS rest/order/create ─── Creates CustomerorderBatch + Customerorder records
    │                      (NO stock moves, NO replenishment — just data import)
    │
    ▼
OrderReleaseJob (Scheduled) ─── Processes new orders
    │   └─ releaseOrder() [has @Transactional]
    │       └─ Creates PickingorderPosition
    │       └─ changeReservedAmount() ◀── 🚨 RACE CONDITION (SBDEV-1710 NOT in release)
    │           └─ Reserves stock on picking area stock units
    │
    ▼
ReplenishOrderJob (Scheduled) ─── Detects stock below middlebound threshold
    │   └─ generateReplenishmentForItemDataWithFixedAssignment()
    │       └─ Compares amountOnLocation vs middlebound
    │       └─ If below → calculateOrder()
    │           └─ Finds source stock in overstock area
    │           └─ Creates Replenishorder (source=A204FY, dest=A204B7)
    │           └─ changeReservedAmount() ◀── 🚨 SAME RACE CONDITION
    │
    ▼
Warehouse Worker Executes Replenishment (Today)
    │   └─ Mobile or Web UI
    │       └─ scanDestination() / transferStock() ◀── 🚨 NO @Transactional
    │           └─ processTransfer() ◀── 🚨 Auto-commits location change
    │           └─ recordForTransferUnitLoad() ◀── 🚨 Swallows exceptions silently
    │
    ▼
Result: Unit load moved but no history, replenishment not updated
```

### How OMS Batching Amplifies WMS Bugs

| Factor | Direct Cause? | Indirect Cause? |
|--------|:---:|:---:|
| OMS batching pushing orders to WMS | ❌ No | ✅ Yes — new orders → stock reservation → replenishment trigger |
| `changeReservedAmount()` race condition (SBDEV-1710) | ❌ No | ✅ Yes — corrupt reservations → wrong source selection |
| Missing `@Transactional` on move path | ✅ **YES** | — |
| Silent exception swallowing in history | ✅ **YES** | — |
| Missing ReplenishmentOrderMaintenanceService | ✅ **YES** | — prevents self-correction |

### UL007670 Most Likely Scenario

1. **Yesterday**: OMS batching pushed orders for PGB20C to WMS
2. **OrderReleaseJob** processed orders, calling `changeReservedAmount()` on PGB20C stock. If concurrent processing occurred, reserved amounts may have been corrupted (last-write-wins race condition)
3. **ReplenishOrderJob** detected picking location stock below `middlebound` → created replenishment order: "move PGB20C from overstock source to A204B7"
4. Source selection query found UL007670 at A204FY as the source (possibly wrong source due to corrupted reservations)
5. **Today**: Warehouse worker executed move/replenishment involving UL007670
6. Due to **CRITICAL #1** (no `@Transactional`), the unit load location updated to A104FZ and auto-committed
7. Due to **CRITICAL #2** (silent exception swallowing), the history record failed to save — error was swallowed
8. Due to **CRITICAL #3** (missing maintenance service), the replenishment order still points to A204FY — dashboard shows old location
9. Unit load record search returns blank because record was never created (exception swallowed) or was created with wrong type `CREATED` instead of `TRANSFERRED`

---

## Branch Discrepancy: `origin/release` vs `origin/develop`

### ✅ Already in Release (Production)

| Ticket | Description | Impact |
|--------|-------------|--------|
| **SBDEV-1727** | Optimistic locking fixes | `processTransfer()` re-fetches fresh entity before save; `transferUnitLoadToCarrier()` no longer swallows `ObjectOptimisticLockingFailureException`; removed broken write lock code |
| **SBDEV-1704** | Enhanced destination location ID handling in `ReplenishMobileOrderDto` and `MobileReplenishService` | DTO enhancement — adds `destinationLocationId` field for consistent tracking. Prerequisite for SBDEV-1708. Does not fix transaction or data consistency issues. |
| **SBDEV-1708** | Multi-unit load replenishment support | New `POST /multi-unitloads` endpoint, `fulfillMultipleUnitLoads()` with `@Transactional`, `createOrderFromTemplate()` in `ReplenishGeneratorService`. Already had proper transaction boundaries on its own code path. |

### ❌ Missing from Release (Only in Develop)

| Ticket | Description | Severity |
|--------|-------------|----------|
| **SBDEV-1710** | `@Transactional` + pessimistic locking on `changeReservedAmount()` with `findByIdForUpdate()` | 🚨 CRITICAL |
| **SBDEV-1742** | `ReplenishmentOrderMaintenanceService` (489 lines) — continuous recalculation of open replenishment orders | 🚨 CRITICAL |
| **SBDEV-1742** | `triggerReplenishmentMaintenance()` calls added after every stock operation in `StockunitService` | 🚨 CRITICAL |
| **SBDEV-1742** | New repository queries: `getStockAndReservedForLocation()`, `getStockAndReservedForPickingAreas()`, `getAvailableReplenishmentSources()` | 🚨 HIGH |

---

## Solution — Recommended Fixes

### 🔴 Immediate (Critical) — New Code on Feature Branch off `release`

**Fix 1: Add `@Transactional` to Move Paths**

Add `@Transactional("tenantTransactionManager")` to the service methods that handle moves:

**Before:**
```java
// MobileMoveUnitloadService.java
public OutDto scanDestination(InDto inDto) {
```

**After:**
```java
// MobileMoveUnitloadService.java
@Transactional("tenantTransactionManager")
public OutDto scanDestination(InDto inDto) {
```

Apply the same to:
- `StockunitService.transferStock()`
- `MobileReplenishService.finishReplenishmentOrder()`
- `MobileReplenishService.finishReplenishmentOrderInternal()`

**Fix 2: Remove Exception Swallowing in History Recording**

**Before** (`UnitloadRecordService.createRecord()`, lines 58-62):
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
// No try-catch — let exception propagate to trigger transaction rollback
```

**Fix 3: Fix Record Type for Transfers**

**Before** (`UnitloadRecordService.recordForTransferUnitLoad()`, line 35):
```java
createRecord(unitload, WmsConstants.UnitloadRecordType.CREATED, ...);
```

**After:**
```java
createRecord(unitload, WmsConstants.UnitloadRecordType.TRANSFERRED, ...);
```

### 🟠 High Priority — Cherry-Pick / Merge from `develop`

**Fix 4:** Cherry-pick SBDEV-1710 to release — adds `@Transactional` + `@Lock(PESSIMISTIC_WRITE)` to `changeReservedAmount()` and adds `findByIdForUpdate()` to `StockunitRepository`

**Fix 5:** Merge `ReplenishmentOrderMaintenanceService` and all SBDEV-1742 changes to release — this is the 489-line service that recalculates open replenishment orders, plus the `triggerReplenishmentMaintenance()` calls in `StockunitService`, plus the new repository queries

~~**Fix 6:** Merge SBDEV-1708 multi-unit load replenishment support~~ — **CORRECTION:** SBDEV-1708 and SBDEV-1704 are already in `release` (commits `0253881` and `92ae131`). No merge needed.

---

## Files Changed (Fixes 1–3, new code on feature branch off `release`)

| File | Change Description |
|------|-------------------|
| `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java` | Add `@Transactional("tenantTransactionManager")` to `scanDestination()` |
| `src/main/java/net/aim_ai/wms/service/StockunitService.java` | Add `@Transactional("tenantTransactionManager")` to `transferStock()` |
| `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` | Add `@Transactional("tenantTransactionManager")` to `finishReplenishmentOrder()` and `finishReplenishmentOrderInternal()` |
| `src/main/java/net/aim_ai/wms/service/UnitloadRecordService.java` | Remove try-catch in `createRecord()` (lines 58-62); fix record type in `recordForTransferUnitLoad()` (line 35) — use `TRANSFERRED` instead of `CREATED` |

### Files Changed (Cherry-pick / Merge from `develop`)

| File | Ticket | Change Description |
|------|--------|-------------------|
| `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` | SBDEV-1710 | `@Transactional` + pessimistic locking on `changeReservedAmount()` |
| `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` | SBDEV-1710 | Add `findByIdForUpdate()` with `@Lock(PESSIMISTIC_WRITE)` |
| `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` | SBDEV-1742 | **New file** — 489-line service for continuous replenishment order recalculation |
| `src/main/java/net/aim_ai/wms/service/StockunitService.java` | SBDEV-1742 | Add `triggerReplenishmentMaintenance()` calls after every stock operation |
| `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java` | SBDEV-1742 | Add `recalculateOpenOrders()` call in scheduled job |
| `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` | SBDEV-1742 | Add `getStockAndReservedForLocation()`, `getStockAndReservedForPickingAreas()`, `getAvailableReplenishmentSources()` |

---

## Commits

| Branch | Commit Hash | Status |
|--------|-------------|--------|
| `release` (feature branch) | `` | Pending — Fixes 1–3 |
| `release` (cherry-pick) | `c4ac107` (SBDEV-1710 from develop) | Pending — Fix 4 |
| `release` (merge) | Multiple (SBDEV-1742) | Pending — Fixes 5–6 |

---

## Deployment Steps

1. **Create feature branch** off `release` for Fixes 1–3
2. Implement Fixes 1–3 (transaction annotations, exception handling, record type)
3. Cherry-pick SBDEV-1710 commit to release branch (Fix 4)
4. Coordinate merge of SBDEV-1742 changes from develop to release (Fixes 5–6)
5. Build new `:uat` container image
6. Deploy to UAT environment and test
7. If UAT passes, deploy to production

---

## Testing Checklist

### Pre-Deployment: Database Verification

Run against the **shipitez tenant database** to identify affected unit loads:

```sql
-- Find unit loads that changed location but have no unitload_record
SELECT u.id, u.labelid, u.storagelocation_id, u.modified
FROM unitload u
WHERE u.modified > NOW() - INTERVAL '30 days'
AND NOT EXISTS (
    SELECT 1 FROM unitload_record ur
    WHERE ur.label = u.labelid
    AND ur.created > u.modified - INTERVAL '1 minute'
);
```

### Post-Deployment Verification

- [ ] **Fix 1 verification**: Move a unit load via mobile UI → verify both location change AND history record are created in the same transaction (or both roll back on failure)
- [ ] **Fix 1 verification**: Transfer stock via web UI → verify both location change AND stock record are created atomically
- [ ] **Fix 2 verification**: Simulate a history record save failure → verify the entire move transaction rolls back (location change is NOT committed)
- [ ] **Fix 3 verification**: Move a unit load → verify the `unitload_record.type` is `TRANSFERRED`, not `CREATED`
- [ ] **Fix 4 verification**: Trigger concurrent `changeReservedAmount()` calls → verify no race condition (reserved amounts are correct)
- [ ] **Fix 5 verification**: Move stock from one location to another → verify the replenishment order `requestedlocationId` updates to the new location
- [ ] **Fix 5 verification**: Verify `ReplenishOrderJob` now calls `recalculateOpenOrders()` on each scheduled run
- [ ] **UL007670 specific**: After fixes deployed, manually verify/correct UL007670 location and replenishment order in the database

---

## Additional Notes

### Immediate Data Correction Needed

UL007670 may require manual database correction to align the replenishment order with the actual stock location (A104FZ). The replenishment order should be updated or cancelled and regenerated after the fix is deployed.

### Related Issues

- **SBDEV-1727** (already in release): Optimistic locking fixes — partially addresses the issue but does not add transaction boundaries
- **SBDEV-1710** (develop only): The `changeReservedAmount()` race condition is a ticking time bomb for any high-volume batch processing
- **Club run `@Transactional` gap** (see `plans/2026-02-10/club-run-full-revert-plan.md`): `runClubLine()` also has no `@Transactional` — same class of issue

### Risk Assessment

| Fix | Risk | Mitigation |
|-----|------|------------|
| Adding `@Transactional` | Low — standard Spring pattern; worst case is slightly longer-held DB connections | Test with realistic move volumes in UAT |
| Removing try-catch | Medium — if there are legitimate reasons history records fail (e.g., missing data), moves will now fail instead of succeeding silently | Review error logs for history save failures before deploying; ensure all record fields are populated |
| Cherry-pick SBDEV-1710 | Medium — changes locking behavior; could cause deadlocks if not tested | Test with concurrent batch processing in UAT |
| Merge SBDEV-1742 | High — 489-line new service + changes to scheduled jobs + new repository queries | Thorough UAT testing of replenishment flow end-to-end |

### Technical Debt Identified

- The WMS v1 codebase has a systemic lack of `@Transactional` annotations on service methods. A comprehensive audit of all service methods that perform multiple `repository.save()` calls should be conducted.
- `spring.jpa.open-in-view=false` is correct for performance, but the codebase was likely written assuming open-in-view was enabled (auto-wrapping). This mismatch is the root cause of many issues.
- The `UnitloadRecordService.createRecord()` exception swallowing pattern may exist in other record services — should audit all similar patterns.