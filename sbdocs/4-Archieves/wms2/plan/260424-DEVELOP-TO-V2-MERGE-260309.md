# Merge Plan: develop → v2/develop-260309 (Post March 2, 2026)

**Date:** 2026-03-09
**Source Branch:** `develop` (commits after March 2, 2026)
**Target Branch:** `v2/develop-260309`
**Commits Analyzed:** 11 (7ac04aa through c8e2961)

---

## Summary

Of the 11 commits on `develop` after March 2nd, **5 changes need porting** to v2. The remaining 6 are either already implemented in v2 or are not applicable.

| Status | Count | Details |
|--------|-------|---------|
| **NEEDS PORTING** | 5 | Bugs/fixes not yet in v2 |
| **ALREADY DONE** | 5 | Already implemented differently in v2 |
| **NOT APPLICABLE** | 1 | Merge commit only |

---

## Changes ALREADY in v2 (No Action Needed)

| Commit | Description | Why Skip |
|--------|-------------|----------|
| `a6c283e` | Compare CustomerorderBatch by ID instead of `.equals()` | v2 already has `.getId().equals()` at OrderRestController:831 |
| `d8e1600` | Remove REQUIRES_NEW from `recalculateForItem` | v2 already has proper `@Transactional(value = "tenantTransactionManager", ...)` without REQUIRES_NEW |
| `08f8ae7` | SQL-level filtering (`findByStateAndItemdataId`) + dedup trigger calls | v2 already has `findByStateAndItemdataId` in repo (line 46) and service (line 103). Single trigger calls per method. |
| `cfd9269` | `AdviceService.close()` - missing `adviceRepository.save(advice)` | v2 already has `adviceRepository.saveAndFlush(advice)` at line 304 |
| `a377010` | `MobileReplenishService.resetOrder()` - missing `replenishorderRepository.save(order)` | v2 already has `replenishorderRepository.save(order)` at line 258 |

---

## Changes to PORT (Action Required)

### Port 1: Fix `getBoxTypeNameFromUnitLoad` null check

**Source Commit:** `7ac04aa` — fix: prevent UnexpectedRollbackException on stock transfer with label printing
**File:** `src/main/java/net/aim_ai/wms/service/StockunitService.java`
**Priority:** HIGH — causes transaction rollback on stock transfers with print label enabled

**Problem:** When transferring stock to a new unit load with print label enabled, `getBoxTypeNameFromUnitLoad()` calls `findById(null)` when `boxtypeId` is null. The resulting exception marks the transaction rollback-only, failing the entire transfer.

**Current v2 code (lines ~545-555):**
```java
private String getBoxTypeNameFromUnitLoad(Unitload unitLoad) {
    // unitLoad may not have a boxtype associated with it
    String caseType;
    try {
        Boxtype boxtype = boxtypeRepository.findById(unitLoad.getBoxtypeId())
            .orElseThrow(() -> new EntityNotFoundException("BoxType", unitLoad.getBoxtypeId()));
        caseType = boxtype.getName();
    }
    catch(Exception e) {
        caseType = "*";
    }
    return caseType;
}
```

**Replace with (adapted for v2 style):**
```java
private String getBoxTypeNameFromUnitLoad(Unitload unitLoad) {
    if (unitLoad.getBoxtypeId() == null) {
        return "*";
    }
    return boxtypeRepository.findById(unitLoad.getBoxtypeId())
        .map(Boxtype::getName)
        .orElse("*");
}
```

**Why:** The try-catch swallows the exception at Java level, but Spring Data JPA's proxy has already marked the transaction rollback-only. The null check avoids the exception entirely.

---

### Port 2: Move OMS `customerOrderPickingStarted` to afterCommit

**Source Commit:** `423bced` — implementation of the phase 1 (connection pool exhaustion fix)
**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
**Priority:** HIGH — OMS HTTP call holds DB connection for up to 15s inside transaction

**Problem:** `confirmPick()` calls `manageOrderService.customerOrderPickingStarted()` synchronously inside the transaction. This HTTP call can block up to 15s (5s connect + 10s read timeout), holding a DB connection the entire time, contributing to connection pool exhaustion.

**Current v2 code (~line 455-457):**
```java
if (customerOrder.getState() < WmsConstants.State.STARTED) {
    customerOrder.setState(WmsConstants.State.STARTED);
    customerOrder = customerorderRepository.save(customerOrder);
    if (basicService.isProduction())
        manageOrderService.customerOrderPickingStarted(Collections.singletonList(customerOrder));
}
```

**Replace with:**
```java
if (customerOrder.getState() < WmsConstants.State.STARTED) {
    customerOrder.setState(WmsConstants.State.STARTED);
    customerOrder = customerorderRepository.save(customerOrder);
    if (basicService.isProduction()) {
        final Customerorder pickingStartedOrder = customerOrder;
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronizationAdapter() {
            @Override
            public void afterCommit() {
                try {
                    manageOrderService.customerOrderPickingStarted(Collections.singletonList(pickingStartedOrder));
                } catch (Exception e) {
                    LOG.error("OMS picking started callback failed for order " + pickingStartedOrder.getNumber(), e);
                }
            }
        });
    }
}
```

**Required imports to add:**
```java
import org.springframework.transaction.support.TransactionSynchronizationAdapter;
import org.springframework.transaction.support.TransactionSynchronizationManager;
```

**Note for v2:** In Spring Boot 3.x / Spring 6, `TransactionSynchronizationAdapter` is deprecated. Use `TransactionSynchronization` interface directly instead:
```java
TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
    @Override
    public void afterCommit() {
        // ... same body
    }
});
```

---

### Port 3: Move OMS `customerOrderToteAssigned` to afterCommit

**Source Commit:** `423bced` — implementation of the phase 1 (connection pool exhaustion fix)
**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`
**Priority:** HIGH — same connection pool exhaustion issue

**Problem:** `processPick()` calls `manageOrderService.customerOrderToteAssigned()` synchronously inside the transaction.

**Current v2 code (in `processPick()`, around the tote assignment block):**
```java
if (basicService.isProduction()) {
    try {
        manageOrderService.customerOrderToteAssigned(Collections.singletonList(customerOrder));
    } catch (Exception e) {
        LOG.error("OMS tote assigned callback failed for order " + customerOrder.getNumber() + ", continuing with pick", e);
    }
}
```

**Replace with:**
```java
if (basicService.isProduction()) {
    final Customerorder toteAssignedOrder = customerOrder;
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
        @Override
        public void afterCommit() {
            try {
                manageOrderService.customerOrderToteAssigned(Collections.singletonList(toteAssignedOrder));
            } catch (Exception e) {
                LOG.error("OMS tote assigned callback failed for order " + toteAssignedOrder.getNumber(), e);
            }
        }
    });
}
```

**Required imports to add:**
```java
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
```

---

### Port 4: Re-read detached entities in `processPick()`

**Source Commit:** `3e3c825` — fix(picking): re-read detached entities in processPick to prevent OptimisticLockingFailureException
**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`
**Priority:** HIGH — causes OptimisticLockingFailureException during picks

**Problem:** The controller loads `pickingOrder` and `pickingPosition` outside a transaction, so they arrive as detached objects in `processPick()`. When the method later tries to save these, it hits version mismatch. Also, after the tote-assignment loop saves `pickingPosition` with a new `picktounitloadId`, the in-memory copy is stale.

**Change A — At the start of `processPick()`, after the LOG.debug line, add:**
```java
// Re-read entities within the transaction boundary to get managed copies with current versions.
// The controller loads these outside a transaction, so they arrive as detached objects.
pickingOrder = pickingorderRepository.findById(pickingOrder.getId())
    .orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingOrder.getId()));
pickingPosition = pickingorderPositionRepository.findById(pickingPosition.getId())
    .orElseThrow(() -> new EntityNotFoundException("PickingOrderPosition", pickingPosition.getId()));
```

**Change B — After the tote-assignment loop (after the block that saves pickingPosition with picktounitloadId), add:**
```java
// Re-read pickingPosition after the tote-assignment loop above, which saved this row
// with a new picktounitloadId (bumping its version). Without this re-read, confirmPick()
// would try to merge() the stale copy and hit an OptimisticLockingFailureException.
pickingPosition = pickingorderPositionRepository.findById(pickingPosition.getId())
    .orElseThrow(() -> new EntityNotFoundException("PickingOrderPosition", pickingPosition.getId()));
```

---

### Port 5: Move OMS `customerOrderPicked` to afterCommit (Race Condition Fix)

**Source Commit:** `f3a08d1` — fix OMS status race condition (status 24 overwrites status 25)
**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
**Priority:** HIGH — single-SKU orders get stuck at "PICKING" status in OMS instead of "WAITING_FOR_QA"

**Problem:** For single-SKU orders, `finishPickingOrder()` sends status 25 (WAITING_FOR_QA) synchronously inside the transaction, then after TX commits, the `afterCommit` from `confirmPick()` sends status 24 (PICKING), overwriting 25. OMS ends up stuck at status 24.

**Current v2 code (in `finishPickingOrder()`, around line 241):**
```java
if (basicService.isProduction()) {
    LOG.info("WMS is in production mode. Sending picking confirmation for order={}", customerOrder.getNumber());
    manageOrderService.customerOrderPicked(Collections.singletonList(customerOrder));
    customerOrder.setPickingconfirmationsent(true);
}
```

**Replace with:**
```java
if (basicService.isProduction()) {
    LOG.info("WMS is in production mode. Sending picking confirmation for order={}", customerOrder.getNumber());

    // Set flag optimistically inside TX. Current code already sets this
    // even when OMS call fails (IOException caught inside ManageOrderService).
    customerOrder.setPickingconfirmationsent(true);

    if (TransactionSynchronizationManager.isSynchronizationActive()) {
        // Defer OMS call until after TX commits, ensuring it fires AFTER
        // any previously registered afterCommit callbacks (e.g., picking started status 24).
        // This prevents the race condition where status 24 overwrites status 25.
        final Customerorder pickedOrder = customerOrder;
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                try {
                    manageOrderService.customerOrderPicked(Collections.singletonList(pickedOrder));
                } catch (Exception e) {
                    LOG.error("OMS picked callback failed for order " + pickedOrder.getNumber(), e);
                }
            }
        });
    } else {
        // No active TX synchronization (e.g., admin controller).
        // Fall back to synchronous call.
        manageOrderService.customerOrderPicked(Collections.singletonList(customerOrder));
    }
}
```

**Required imports (if not already added from Port 2):**
```java
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
```

**IMPORTANT — v2 `finishPickingOrder()` structure differs from develop:**
The v2 version has batch-optimized logic with maps and loops. The OMS call location is around line 241 (`manageOrderService.customerOrderPicked(...)`) inside the customer order loop. Apply the afterCommit pattern at that exact location. The `isSynchronizationActive()` guard is essential because `finishPickingOrder()` has 8+ callers, some potentially non-transactional.

---

## Implementation Order

```
1. Port 1: StockunitService.getBoxTypeNameFromUnitLoad()     — standalone, no dependencies
2. Port 2: PickingorderBusinessService.confirmPick()          — prerequisite for Port 5
3. Port 3: MobilePickingService (tote assigned afterCommit)   — independent of Port 2
4. Port 4: MobilePickingService (re-read detached entities)   — same file as Port 3, apply together
5. Port 5: PickingorderBusinessService.finishPickingOrder()   — depends on Port 2 being done first
```

Ports 1, 2+5, and 3+4 can be implemented in parallel since they touch different logical areas.

---

## Test Impact

| Port | Tests to Update/Verify |
|------|------------------------|
| Port 1 | `StockunitServiceUnitTest` — verify stock transfer with null boxtypeId |
| Port 2 | `PickingorderBusinessServiceUnitTest` — mock `TransactionSynchronizationManager` |
| Port 3 | `MobilePickingServiceUnitTest` — mock `TransactionSynchronizationManager` |
| Port 4 | `MobilePickingServiceUnitTest` — verify re-read calls |
| Port 5 | `PickingorderBusinessServiceUnitTest` — verify afterCommit for picked status |

---

## Plan Docs to Copy

The following plan docs from develop provide detailed context for the fixes:

| Doc | Commit | Copy to v2? |
|-----|--------|-------------|
| `docs/plan/260424-connection-pool-exhaustion-fix-plan.md` | `423bced` | Optional — reference only |
| `docs/plan/260424-picking-oms-status-race-condition-fix.md` | `f3a08d1` | Optional — reference only |

---

## Key Differences Between v2 and develop to Watch For

| Aspect | develop | v2 |
|--------|---------|-----|
| DI Style | `@Autowired` fields | Constructor injection |
| Imports | `javax.servlet` | `jakarta.servlet` |
| Sysprop | `LosSyspropRepository` | `SyspropRepository` |
| User Repo | `MywmsUserRepository` | `UserRepository` |
| Entity Lookups | `.get()` (no null safety) | `.orElseThrow(() -> new EntityNotFoundException(...))` |
| Transaction Mgr | Default (landlord) `@Transactional` | `@Transactional(value = "tenantTransactionManager", ...)` |
| Spring Version | Spring Boot 2.x / Spring 5 | Spring Boot 3.x / Spring 6 |
| TX Sync Adapter | `TransactionSynchronizationAdapter` (class) | `TransactionSynchronization` (interface, adapter deprecated) |

**When porting, always use v2 conventions** (constructor injection, jakarta imports, EntityNotFoundException, tenantTransactionManager, TransactionSynchronization interface).
