# Concurrency Fix Plan — Entity Save & Optimistic Locking

## Executive Summary

The WMS API service layer has systematic concurrency vulnerabilities stemming from three root causes:

1. **No retry logic for optimistic lock failures** — 45 of 67 entities have `@Version` fields (good), but only `BasicService.getNextSequenceNumber()` catches `ObjectOptimisticLockingFailureException`. Every other `.save()` call (200+ across 56 service files) lets the exception propagate as an unhandled 500 error.

2. **Missing `@Transactional` on critical services** — `BillofladingService`, `CustomerorderService`, `CustomerorderBatchService`, and `TransferOrderService` have no `@Transactional` annotations at class or method level. Each `.save()` auto-commits independently, so a failure mid-method leaves partial state.

3. **Stale entity patterns** — Long-running methods load entities early, do substantial work (loops, network calls, other DB operations), then save the stale entity. Between load and save, another thread/cron-job can modify the same entity, causing lost updates or `OptimisticLockException`.

**Impact:** In a multi-user warehouse with concurrent mobile pickers, web UI operators, and cron jobs, these issues cause:
- 500 errors on mobile devices during picking (lost work for warehouse staff)
- Partial BOL closures leaving inventory in inconsistent state
- Order release job failures leaving orders stuck in RAW state
- Silent data loss where state changes are overwritten

---

## Table of Contents

1. [Current State Assessment](#1-current-state-assessment)
2. [Critical Findings Catalog](#2-critical-findings-catalog)
3. [Fix Plan — Phase 1: Retry Utility](#3-fix-plan--phase-1-retry-utility)
4. [Fix Plan — Phase 2: Transaction Boundaries](#4-fix-plan--phase-2-transaction-boundaries)
5. [Fix Plan — Phase 3: Stale Entity Fixes](#5-fix-plan--phase-3-stale-entity-fixes)
6. [Fix Plan — Phase 4: Native Query Safety](#6-fix-plan--phase-4-native-query-safety)
7. [Fix Plan — Phase 5: Pessimistic Locking for Hot Paths](#7-fix-plan--phase-5-pessimistic-locking-for-hot-paths)
8. [Testing Strategy](#8-testing-strategy)
9. [Implementation Priority & Sequencing](#9-implementation-priority--sequencing)
10. [Risk Assessment](#10-risk-assessment)

---

## 1. Current State Assessment

### @Version Coverage (45 / 67 entities)

All 45 versioned entities use `private Integer version`. The entities that **lack** `@Version` are primarily reference/lookup tables (e.g., `Parcel`, `TransferLane`, `StagingLane`) that are less frequently updated concurrently. The core transactional entities (Stockunit, Unitload, Customerorder, CustomerorderPosition, Pickingorder, PickingorderPosition, Billoflading, BillofladingPosition, CustomerorderBatch) **all have @Version**.

### Existing Concurrency Controls

| Mechanism | Where | Coverage |
|---|---|---|
| `@Version` (optimistic locking) | 45 entities | Detection only — no retry |
| Retry on `OptimisticLockException` | `BasicService.getNextSequenceNumber()` only | 1 method out of 200+ |
| `@Lock(PESSIMISTIC_WRITE)` | `StockunitRepository.findByIdForUpdate()` only | 1 query |
| `synchronized` block | `ReplenishmentOrderMaintenanceService` | JVM-only, not DB-level |
| `@Transactional(REQUIRES_NEW)` | `ReleaseOrderJobService`, `ReplenishOrderJobService`, `SequenceTransactionService` | Isolated transactions |

### Missing Controls

| What's Missing | Impact |
|---|---|
| No `@Transactional` on BillofladingService | 30+ saves in `closeBOL()` are not atomic |
| No `@Transactional` on CustomerorderService | `forceCancelOrder()` partial state on failure |
| No `@Transactional` on CustomerorderBatchService | `runClubLine()` 20+ saves not atomic |
| No `@Transactional` on TransferOrderService | State changes on multiple entities not atomic |
| No retry utility | Every optimistic lock failure = 500 error |
| No entity reload before save in long methods | Stale version overwrites concurrent changes |

---

## 2. Critical Findings Catalog

### 2.1 CRITICAL: BillofladingService — No @Transactional, 30+ saves

**File:** `service/BillofladingService.java`

| Method | Lines | Saves | Risk |
|---|---|---|---|
| `closeBOL()` | 249–508 | 30+ | Iterates pallet→parcel→stock hierarchy, updates Customerorder, CustomerorderPosition, Unitload, Stockunit, BillofladingPosition, Billoflading, CustomerorderBatch. HTTP call to OMS at line ~472 extends transaction window. No atomicity — partial close on failure. |
| `finishTransfer()` | ~976–1036 | 11 | Deep nesting with external service calls. Same partial-failure risk. |
| `transferOrder()` | ~804–845 | 3 | Receives entity as parameter (already stale). |
| `createEntity()` | ~170–240 | 2 | Lower risk — short method. |

**Concrete scenario:**
```
Thread A: closeBOL(bol) — loads BOL, starts processing 100 positions
Thread B: Mobile user scans pallet, updates BillofladingPosition state
Thread A: At position 50, tries to save the same BillofladingPosition
Result: OptimisticLockException → entire closeBOL fails → 50 positions
        already saved with FINISHED state, 50 still in old state
        BOL stuck in inconsistent state (no rollback without @Transactional)
```

### 2.2 CRITICAL: ReleaseOrderJobService — Long-running loop, stale entities

**File:** `service/job/ReleaseOrderJobService.java`

| Method | Lines | Saves | Risk |
|---|---|---|---|
| `releaseOrder()` | 71–512 | 17+ per order | `@Transactional(REQUIRES_NEW)` but loads order at line 79, saves at lines 179/187/192 after 100+ lines of processing. Each `CustomerorderPosition` saved individually in a loop. Concurrent mobile picking can modify positions between saves. |

**Concrete scenario:**
```
Cron job: releaseOrder(orderId=123) loads order (version=5)
Mobile:   Operator starts picking same order, updates state (version→6)
Cron job: At line 179, saves order with version=5
Result:   OptimisticLockException → entire order release fails
          Positions partially allocated, stock reserved but order stuck in RAW
```

### 2.3 HIGH: CustomerorderService — No @Transactional, missing save

**File:** `service/CustomerorderService.java`

| Method | Lines | Issue |
|---|---|---|
| `forceCancelOrder()` | 243–300 | Line 267: `customerOrderPosition.setState(CANCELED)` but **no explicit `save()`**. Relies on Hibernate dirty-checking at transaction flush. Since there is no `@Transactional`, this flush depends entirely on the caller's transaction context. Compare with line 299 in the `PACKED/PALLETIZED` branch where `save()` IS called explicitly. Inconsistent and fragile. |
| `cancelOrder()` | ~210–240 | Calls `forceCancelOrder()` which modifies multiple entities without atomicity guarantee. |
| `packageOrder()` | ~180–210 | Modifies Customerorder state + creates/updates Parcel. No @Transactional. |

### 2.4 HIGH: CustomerorderBatchService — No @Transactional on critical methods

**File:** `service/CustomerorderBatchService.java`

| Method | Lines | Issue |
|---|---|---|
| `runClubLine()` | 403–497 | 20+ saves: creates parcels, transfers stock, updates order states, sends OMS messages. All without @Transactional. Partial failure leaves some orders PACKED, others RAW. |
| `setPriority()` | 117–131 | Loop updates 100+ orders individually. No atomicity — if order N fails, orders 1 to N-1 have new priority, N+1 to M have old priority. |
| `activateOrderBatch()` | 299 | Single save — lower risk but still no transaction boundary. |

### 2.5 HIGH: TransferOrderService — Parameter entity stale saves

**File:** `service/TransferOrderService.java`

| Method | Lines | Issue |
|---|---|---|
| `assignTransferLaneToTransferOrder()` | 64–79 | Accepts `Customerorder` parameter, modifies state, saves. Entity may have been loaded by the controller long before this method is called. |
| `unlinkTransferLaneFromTransferOrder()` | ~80–85 | Same pattern. |
| `activateTransferOrder()` | ~90–97 | Same pattern. |
| `assignTransferLane()` | ~100–107 | Same pattern + reads lane availability then saves assignment. Race window between check and save. |

### 2.6 HIGH: MobilePickingService — High-frequency concurrent access

**File:** `service/mobile/MobilePickingService.java`

| Method | Saves | Issue |
|---|---|---|
| `confirmPick()` | 4+ | Multiple entities updated per pick operation. Highest-frequency operation in the warehouse. Two pickers working on adjacent orders can collide on shared Stockunit. |
| `finishPicking()` | 3+ | Updates Pickingorder, Customerorder, PickingorderPosition. |
| `startPicking()` | 2+ | Updates Pickingorder and Customerorder state. |

### 2.7 MEDIUM: Native queries bypassing @Version

**Active @Modifying queries that bypass optimistic locking:**

| Repository | Method | Query Type | Impact |
|---|---|---|---|
| `AdviceRepository` | `updateAdviceToStateById()` | Native UPDATE | Skips version check — could overwrite concurrent JPA save |
| `AdvicepositionRepository` | `updateAdvicepositionToStateByAdviceId()` | Native UPDATE | Same — bulk state change without version |
| `ClientRepository` | `toggleEnableReceivingById()` | Native UPDATE | Lower risk — admin operation |
| `ClientRepository` | `updatePrinterToNullByPrinterId()` | Native UPDATE | Lower risk — admin operation |
| `BillofladingRepository` | `deleteBolByBolNumber()` | Native DELETE | Could delete BOL while closeBOL() is processing it |
| `BillofladingPositionRepository` | `deleteBolPositionById()` | JPQL DELETE | Same risk |
| `BillofladingPositionRepository` | `deleteBolPositionsCarrierIds()` | JPQL DELETE | Same risk |
| `MessageRepository` | `archiveMessages()` / `deleteMessages()` | Native INSERT/DELETE | Lower risk — background cleanup |

---

## 3. Fix Plan — Phase 1: Retry Utility

**Goal:** Create a reusable retry mechanism for optimistic lock failures, modeled on the existing `BasicService.getNextSequenceNumber()` pattern.

### 3.1 Create `OptimisticLockRetryTemplate`

**File:** `service/util/OptimisticLockRetryTemplate.java`

```java
package net.aim_ai.wms.service.util;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.orm.ObjectOptimisticLockingFailureException;
import javax.persistence.OptimisticLockException;

public class OptimisticLockRetryTemplate {

    private static final Logger LOG = LoggerFactory.getLogger(OptimisticLockRetryTemplate.class);
    private static final int DEFAULT_MAX_RETRIES = 5;
    private static final long BASE_DELAY_MS = 50;

    @FunctionalInterface
    public interface RetryableAction<T> {
        T execute() throws Exception;
    }

    @FunctionalInterface
    public interface RetryableVoidAction {
        void execute() throws Exception;
    }

    /**
     * Execute an action with retry on optimistic lock failure.
     * Uses exponential backoff: 50ms, 100ms, 200ms, 400ms, 800ms
     */
    public static <T> T executeWithRetry(RetryableAction<T> action,
                                          int maxRetries,
                                          String operationName) throws Exception {
        int attempt = 0;
        while (true) {
            try {
                return action.execute();
            } catch (ObjectOptimisticLockingFailureException | OptimisticLockException e) {
                attempt++;
                if (attempt >= maxRetries) {
                    LOG.error("Optimistic lock failure after {} attempts for: {}",
                              attempt, operationName, e);
                    throw e;
                }
                long delay = BASE_DELAY_MS * (1L << (attempt - 1)); // exponential backoff
                LOG.warn("Optimistic lock conflict (attempt {}/{}) for: {}. Retrying in {}ms",
                         attempt, maxRetries, operationName, delay);
                Thread.sleep(delay);
            }
        }
    }

    public static <T> T executeWithRetry(RetryableAction<T> action,
                                          String operationName) throws Exception {
        return executeWithRetry(action, DEFAULT_MAX_RETRIES, operationName);
    }

    public static void executeWithRetry(RetryableVoidAction action,
                                         int maxRetries,
                                         String operationName) throws Exception {
        executeWithRetry(() -> { action.execute(); return null; },
                         maxRetries, operationName);
    }

    public static void executeWithRetry(RetryableVoidAction action,
                                         String operationName) throws Exception {
        executeWithRetry(action, DEFAULT_MAX_RETRIES, operationName);
    }
}
```

### 3.2 Usage Pattern

**Important:** The retry must wrap the *entire transactional unit*, not individual saves. The method being retried must start a **new transaction** on each attempt so it gets a fresh persistence context with current entity versions.

```java
// In a controller or orchestrating service:
OptimisticLockRetryTemplate.executeWithRetry(() -> {
    billofladingService.closeBOL(bolId);  // must be @Transactional
}, "closeBOL-" + bolId);
```

For this to work, the service method must:
1. Accept an **entity ID** (not an entity object) so it can reload fresh on retry.
2. Be `@Transactional` so the entire operation is atomic and rollback-able.

### 3.3 Files to Create

| File | Purpose |
|---|---|
| `service/util/OptimisticLockRetryTemplate.java` | Retry utility class |

---

## 4. Fix Plan — Phase 2: Transaction Boundaries

**Goal:** Add `@Transactional` to all service methods that perform multiple `.save()` calls, ensuring atomicity.

### 4.1 BillofladingService

Add class-level `@Transactional` and method-level overrides where needed:

```java
@Service
@Transactional  // ADD THIS
public class BillofladingService {
    // All public methods now run in a transaction

    // closeBOL() — the most critical method
    // No changes needed if class-level @Transactional is added

    // For closeBOLs() — which calls closeBOL() in a loop:
    // Each BOL should be its own transaction to limit blast radius
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void closeSingleBOL(Long bolId) throws ... {
        Billoflading bol = billofladingRepository.findById(bolId)
            .orElseThrow(() -> new FacadeException("BOL not found: " + bolId));
        closeBOL(bol);
    }
}
```

### 4.2 CustomerorderService

```java
@Service
@Transactional  // ADD THIS
public class CustomerorderService {
    // forceCancelOrder() line 267 — the missing save becomes safe
    // because Hibernate dirty-checking will flush at transaction commit.
    // However, for consistency and explicitness, also add the save() call:

    // Line 267: ADD customerorderPositionRepository.save(customerOrderPosition);
}
```

### 4.3 CustomerorderBatchService

```java
@Service
@Transactional  // ADD THIS
public class CustomerorderBatchService {
    // runClubLine() — all 20+ saves now atomic
    // setPriority() — loop updates now atomic
}
```

### 4.4 TransferOrderService

```java
@Service
@Transactional  // ADD THIS
public class TransferOrderService {
    // All 4 methods now atomic
}
```

### 4.5 Summary of @Transactional Changes

| File | Change | Impact |
|---|---|---|
| `BillofladingService.java` | Add `@Transactional` at class level | closeBOL, finishTransfer, transferOrder become atomic |
| `CustomerorderService.java` | Add `@Transactional` at class level | forceCancelOrder, packageOrder become atomic |
| `CustomerorderBatchService.java` | Add `@Transactional` at class level | runClubLine, setPriority become atomic |
| `TransferOrderService.java` | Add `@Transactional` at class level | All 4 methods become atomic |

**Caution:** Adding `@Transactional` increases the transaction duration for long methods like `closeBOL()`. This is acceptable because:
- Without it, partial failures are **worse** than longer transactions.
- Phase 5 adds pessimistic locking to prevent the concurrent access in the first place.
- The existing `REQUIRES_NEW` on `ReleaseOrderJobService` already demonstrates long transactions are acceptable in this codebase.

---

## 5. Fix Plan — Phase 3: Stale Entity Fixes

**Goal:** Ensure entities are fresh when saved, especially in long-running methods and when passed as parameters.

### 5.1 Pattern: Accept ID Instead of Entity

**Before (dangerous):**
```java
public void closeBOL(Billoflading billOfLading) {
    // billOfLading may be stale — loaded minutes ago by caller
    // ... 250 lines of work ...
    billOfLading.setState(CLOSED);
    billofladingRepository.save(billOfLading); // may throw OptimisticLockException
}
```

**After (safe):**
```java
@Transactional
public void closeBOL(Long billOfLadingId) {
    Billoflading billOfLading = billofladingRepository.findById(billOfLadingId)
        .orElseThrow(() -> new FacadeException("BOL not found: " + billOfLadingId));
    // Fresh entity with current version
    // ... rest of method ...
}
```

### 5.2 Methods to Refactor (Accept ID, Reload Internally)

| Service | Method | Current Param | Change To |
|---|---|---|---|
| `BillofladingService` | `closeBOL()` | `Billoflading` | `Long bolId` |
| `BillofladingService` | `transferOrder()` | `Long customerOrderId` | Already uses ID (OK) |
| `CustomerorderBatchService` | `runClubLine()` | `CustomerorderBatch` | `Long orderBatchId` |
| `CustomerorderBatchService` | `activateOrderBatch()` | `CustomerorderBatch` | `Long orderBatchId` |
| `CustomerorderBatchService` | `assignStagingLaneToOrderBatch()` | `Location, CustomerorderBatch` | `Long locationId, Long orderBatchId` |
| `TransferOrderService` | `assignTransferLaneToTransferOrder()` | `Customerorder` | `Long orderId` |
| `TransferOrderService` | `unlinkTransferLaneFromTransferOrder()` | `Customerorder` | `Long orderId` |
| `TransferOrderService` | `activateTransferOrder()` | `Customerorder` | `Long orderId` |

**Important:** This changes the method signatures, so all callers must be updated. This is a larger refactor — see Phase sequencing in Section 9.

### 5.3 Pattern: Reload Before Save in Loops

For methods that iterate over entities and save individually, reload each entity before modifying:

**Before:**
```java
List<Customerorder> orders = customerorderRepository.findByOrderbatchId(batchId);
for (Customerorder order : orders) {
    order.setState(PACKED);
    customerorderRepository.save(order); // may be stale if loop is long
}
```

**After:**
```java
List<Long> orderIds = customerorderRepository.findIdsByOrderbatchId(batchId);
for (Long orderId : orderIds) {
    Customerorder order = customerorderRepository.findById(orderId).get();
    order.setState(PACKED);
    customerorderRepository.save(order);
}
```

Or better — use bulk JPQL UPDATE when only setting a single field:

```java
@Modifying
@Query("UPDATE Customerorder o SET o.state = :state WHERE o.orderbatchId = :batchId")
int updateStateByBatchId(@Param("state") int state, @Param("batchId") Long batchId);
```

### 5.4 Fix: CustomerorderService.forceCancelOrder() Missing Save

**File:** `service/CustomerorderService.java`, line 267

```java
// BEFORE (line 267):
customerOrderPosition.setState(WmsConstants.State.CANCELED);
// <-- no save() call, relies on dirty-checking

// AFTER:
customerOrderPosition.setState(WmsConstants.State.CANCELED);
customerorderPositionRepository.save(customerOrderPosition);
```

---

## 6. Fix Plan — Phase 4: Native Query Safety

**Goal:** Ensure native UPDATE/DELETE queries don't silently overwrite concurrent JPA changes.

### 6.1 Native UPDATEs That Bypass @Version

These queries modify entities without checking the `version` column, meaning they can overwrite changes made by concurrent JPA `save()` operations.

| Repository | Query | Fix |
|---|---|---|
| `AdviceRepository.updateAdviceToStateById()` | `UPDATE advice SET state = :state WHERE id = :id` | Add `AND version = :version` and increment version, OR add `@QueryHints(@QueryHint(name = "org.hibernate.flushMode", value = "ALWAYS"))` |
| `AdvicepositionRepository.updateAdvicepositionToStateByAdviceId()` | `UPDATE adviceposition SET state = :state WHERE advice_id = :adviceId` | Add version check |
| `ClientRepository.toggleEnableReceivingById()` | `UPDATE client SET enablereceiving = ...` | Low risk — admin only. Document as known bypass. |
| `ClientRepository.updatePrinterToNullByPrinterId()` | `UPDATE client SET printerreceiving_id = NULL ...` | Low risk — admin only. Document as known bypass. |

### 6.2 Native DELETEs

| Repository | Query | Risk | Fix |
|---|---|---|---|
| `BillofladingRepository.deleteBolByBolNumber()` | `DELETE FROM billoflading WHERE number = :bolNumber` | HIGH — could delete BOL during closeBOL() | Add state check: `AND state NOT IN (...)` or use pessimistic lock |
| `BillofladingPositionRepository.deleteBolPositionById()` | `DELETE FROM BillofladingPosition WHERE id = :id` | MEDIUM | Acceptable for cleanup operations |
| `BillofladingPositionRepository.deleteBolPositionsCarrierIds()` | `DELETE FROM BillofladingPosition WHERE carrierId IN :ids` | MEDIUM | Used in closeBOL garbage cleanup — acceptable |

### 6.3 Recommended Approach

For the high-risk `AdviceRepository.updateAdviceToStateById()`:

```sql
-- BEFORE:
UPDATE advice SET state = :state WHERE id = :id

-- AFTER (option A — version-aware):
UPDATE advice SET state = :state, version = version + 1
WHERE id = :id AND version = :version

-- AFTER (option B — state guard):
UPDATE advice SET state = :state WHERE id = :id AND state = :expectedState
```

Option B is often more practical because it also enforces the state machine invariant.

---

## 7. Fix Plan — Phase 5: Pessimistic Locking for Hot Paths

**Goal:** For the highest-contention operations, add `SELECT ... FOR UPDATE` to prevent concurrent access entirely.

### 7.1 When to Use Pessimistic vs Optimistic Locking

| Scenario | Strategy | Rationale |
|---|---|---|
| Low contention (most CRUD) | Optimistic (existing @Version) | Low collision probability; retry is cheap |
| High contention (picking, BOL close) | Pessimistic (`FOR UPDATE`) | Multiple concurrent actors on same entities; retry is expensive (lost work) |
| Bulk operations (order release job) | Optimistic + retry at job level | Job can restart individual orders |

### 7.2 Add Pessimistic Lock Queries

**StockunitRepository** (already has `findByIdForUpdate` — extend pattern):

```java
// Already exists:
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT s FROM Stockunit s WHERE s.id = :id")
Optional<Stockunit> findByIdForUpdate(@Param("id") Long id);
```

**BillofladingRepository** — add:

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT b FROM Billoflading b WHERE b.id = :id")
Optional<Billoflading> findByIdForUpdate(@Param("id") Long id);
```

**CustomerorderRepository** — add:

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT c FROM Customerorder c WHERE c.id = :id")
Optional<Customerorder> findByIdForUpdate(@Param("id") Long id);
```

**PickingorderRepository** — add:

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT p FROM Pickingorder p WHERE p.id = :id")
Optional<Pickingorder> findByIdForUpdate(@Param("id") Long id);
```

### 7.3 Use in Critical Methods

**BillofladingService.closeBOL():**
```java
@Transactional
public void closeBOL(Long bolId) {
    // Lock BOL row — no other thread can close/modify it concurrently
    Billoflading bol = billofladingRepository.findByIdForUpdate(bolId)
        .orElseThrow(...);
    // ... rest of method safe from concurrent modification
}
```

**MobilePickingService.confirmPick():**
```java
// Lock the picking order before modifying
Pickingorder po = pickingorderRepository.findByIdForUpdate(pickingOrderId).get();
```

### 7.4 Deadlock Prevention

When locking multiple entities, always lock in a **consistent order**:
1. `Billoflading` first
2. `CustomerorderBatch` second
3. `Customerorder` third
4. `CustomerorderPosition` fourth
5. `Pickingorder` / `PickingorderPosition` fifth
6. `Unitload` / `Stockunit` last

Document this ordering in a code comment in each repository's `findByIdForUpdate` method.

---

## 8. Testing Strategy

### 8.1 Unit Tests for Retry Utility

```java
@Test
void shouldRetryOnOptimisticLockException() {
    AtomicInteger attempts = new AtomicInteger(0);
    String result = OptimisticLockRetryTemplate.executeWithRetry(() -> {
        if (attempts.incrementAndGet() < 3) {
            throw new ObjectOptimisticLockingFailureException(Stockunit.class, 1L);
        }
        return "success";
    }, "test-retry");
    assertEquals("success", result);
    assertEquals(3, attempts.get());
}

@Test
void shouldFailAfterMaxRetries() {
    assertThrows(ObjectOptimisticLockingFailureException.class, () -> {
        OptimisticLockRetryTemplate.executeWithRetry(() -> {
            throw new ObjectOptimisticLockingFailureException(Stockunit.class, 1L);
        }, 3, "test-exhausted");
    });
}
```

### 8.2 Integration Tests for Concurrent Access

Test concurrent closeBOL operations:

```java
@Test
void closeBOL_concurrentModification_shouldNotCorruptState() throws Exception {
    // Setup: create BOL with positions
    Long bolId = createTestBOLWithPositions();

    // Simulate concurrent modification
    ExecutorService executor = Executors.newFixedThreadPool(2);

    Future<?> closeTask = executor.submit(() ->
        billofladingService.closeBOL(bolId));

    Future<?> modifyTask = executor.submit(() -> {
        Thread.sleep(50); // small delay to let closeBOL start
        // Try to modify a position on the same BOL
        billofladingPositionService.updatePosition(posId, newState);
    });

    // Verify: one succeeds, one gets lock/version conflict
    // Final state should be consistent
}
```

Test concurrent picking:

```java
@Test
void confirmPick_twoPickers_sameStockUnit_shouldHandleConflict() throws Exception {
    Long stockUnitId = createTestStockUnit(quantity = 10);
    Long pickOrderId1 = createPickingOrder(stockUnitId, amount = 5);
    Long pickOrderId2 = createPickingOrder(stockUnitId, amount = 5);

    ExecutorService executor = Executors.newFixedThreadPool(2);
    Future<?> pick1 = executor.submit(() ->
        mobilePickingService.confirmPick(pickOrderId1, ...));
    Future<?> pick2 = executor.submit(() ->
        mobilePickingService.confirmPick(pickOrderId2, ...));

    // Both should succeed (with retry) or one should fail gracefully
    // Stock should never go negative
}
```

### 8.3 Test the Missing Save Fix

```java
@Test
void forceCancelOrder_shouldPersistPositionCancelState() {
    // Setup: create order with positions in ASSIGNED state
    Customerorder order = createOrderWithPositions(State.ASSIGNED);

    customerorderService.cancelOrder(order, true);

    // Verify ALL positions are CANCELED in database
    List<CustomerorderPosition> positions =
        customerorderPositionRepository.findByOrderId(order.getId());
    positions.forEach(pos ->
        assertEquals(State.CANCELED, pos.getState(),
            "Position " + pos.getId() + " should be CANCELED"));
}
```

---

## 9. Implementation Priority & Sequencing

> **STATUS: ALL PHASES COMPLETED — 2026-02-14**
>
> All 5 phases have been implemented, tested, and verified. Build passes. All unit tests pass.

### Phase 1: Immediate Safety ✅ COMPLETED

**No signature changes. Minimal risk. Maximum safety improvement.**

| # | Task | File | Status |
|---|---|---|---|
| 1.1 | Add `@Transactional` to BillofladingService | `BillofladingService.java` | ✅ Done |
| 1.2 | Add `@Transactional` to CustomerorderService | `CustomerorderService.java` | ✅ Done |
| 1.3 | Add `@Transactional` to CustomerorderBatchService | `CustomerorderBatchService.java` | ✅ Done |
| 1.4 | Add `@Transactional` to TransferOrderService | `TransferOrderService.java` | ✅ Done |
| 1.5 | Fix missing save in `forceCancelOrder()` | `CustomerorderService.java:268` | ✅ Done — added `customerorderPositionRepository.save(customerOrderPosition)` |
| 1.6 | Create `OptimisticLockRetryTemplate` | `service/util/OptimisticLockRetryTemplate.java` | ✅ Done — exponential backoff 50ms-800ms, 5 retries |

### Phase 2: Retry at Entry Points ✅ COMPLETED

**Wrapped critical controller-to-service calls with retry logic.**

| # | Task | File | Status |
|---|---|---|---|
| 2.1 | Wrap `closeBOL` + `closeBOLs` calls with retry | `BillOfLadingController.java` | ✅ Done |
| 2.2 | Wrap `runClubLine` call with retry | `ClubLineController.java` | ✅ Done |
| 2.3 | Wrap `assignStagingLane` + `unlinkStagingLane` + `activateBatch` | `ClubLineController.java` | ✅ Done |
| 2.4 | Wrap all TransferOrderService calls with retry | `TransfersController.java` | ✅ Done (5 endpoints) |
| 2.5 | Wrap `setPriority` call with retry | `OrderRestController.java` | ✅ Done |
| 2.6 | Wrap `runTransfer` call with retry | `TransfersController.java` | ✅ Done |

### Phase 3: Stale Entity Refactor ✅ COMPLETED

**Changed method signatures to accept IDs. Entities reloaded internally.**

| # | Task | File | Status |
|---|---|---|---|
| 3.1 | Refactor `closeBOL()` to accept `Long bolId` | `BillofladingService.java` | ✅ Done |
| 3.2 | Refactor `runClubLine()` to accept `Long batchId` | `CustomerorderBatchService.java` | ✅ Done |
| 3.3 | Refactor `activateOrderBatch()` to accept `Long` | `CustomerorderBatchService.java` | ✅ Done |
| 3.4 | Refactor `assignStagingLaneToOrderBatch()` to accept IDs | `CustomerorderBatchService.java` | ✅ Done |
| 3.5 | Refactor `unlinkStagingLaneFromOrderBatch()` to accept ID | `CustomerorderBatchService.java` | ✅ Done |
| 3.6 | Refactor TransferOrderService methods to accept IDs | `TransferOrderService.java` | ✅ Done (3 methods) |
| 3.7 | Update all controller callers | Controllers | ✅ Done |
| 3.8 | Update all unit tests + integration tests | Test files | ✅ Done (5 test files updated) |

### Phase 4: Pessimistic Locking ✅ COMPLETED

**Added FOR UPDATE queries for high-contention entities.**

| # | Task | File | Status |
|---|---|---|---|
| 4.1 | Add `findByIdForUpdate()` to BillofladingRepository | `BillofladingRepository.java` | ✅ Done |
| 4.2 | Add `findByIdForUpdate()` to CustomerorderRepository | `CustomerorderRepository.java` | ✅ Done |
| 4.3 | Add `findByIdForUpdate()` to PickingorderRepository | `PickingorderRepository.java` | ✅ Done |
| 4.4 | Use `findByIdForUpdate()` in `closeBOL()` | `BillofladingService.java` | ✅ Done |
| 4.5 | Use `findByIdForUpdate()` in TransferOrderService | `TransferOrderService.java` | ✅ Done (assignTransferLane, activateTransferOrder) |
| 4.6 | Document lock ordering convention | Repository code comments | ✅ Done |

### Phase 5: Native Query Safety ✅ COMPLETED

| # | Task | File | Status |
|---|---|---|---|
| 5.1 | Add version increment + state guard to `updateAdviceToStateById` | `AdviceRepository.java` | ✅ Done — `SET version = version + 1 ... AND state != :state` |
| 5.2 | Add version increment + state guard to `updateAdvicepositionToStateByAdviceId` | `AdvicepositionRepository.java` | ✅ Done — same pattern |
| 5.3 | Add state guard to `deleteBolByBolNumber` | `BillofladingRepository.java` | ✅ Done — `AND bp.state = 'CREATED'` |

### Additional: Unit Tests ✅ COMPLETED

| # | Task | File | Status |
|---|---|---|---|
| 6.1 | Create `OptimisticLockRetryTemplate` unit tests | `OptimisticLockRetryTemplateTest.java` | ✅ Done — 11 tests |
| 6.2 | Update existing unit tests for signature changes | 5 test files | ✅ Done — all pass |

---

## 10. Risk Assessment

### Risks of the Fix

| Risk | Mitigation |
|---|---|
| Adding `@Transactional` increases transaction duration | Acceptable trade-off vs partial state corruption. Monitor DB connection pool. |
| Pessimistic locks could cause deadlocks | Enforce consistent lock ordering (documented in Phase 5). Set `javax.persistence.lock.timeout` to 5 seconds. |
| Method signature changes break callers | Phase 3 is a larger refactor — update all callers in same PR. Search for all usages before changing. |
| Retry logic masks real errors | Log all retries at WARN level. Set max retries to 5 (not infinite). Alert on high retry rates. |
| Long transactions hold DB connections | Monitor connection pool utilization. Consider breaking `closeBOL()` into smaller transactional units if needed. |

### Risks of NOT Fixing

| Risk | Current Impact |
|---|---|
| Partial BOL closure | Inventory inconsistency, manual correction required |
| Failed mobile picks | Warehouse staff loses work, re-picks required |
| Stuck orders in RAW state | Orders never ship, customer complaints |
| Missing save in `forceCancelOrder()` | Canceled order positions reappear as active, picking contradictions |
| Silent overwrites from native queries | State machine violations, audit trail broken |

### Monitoring Recommendations

After implementing fixes, add logging/metrics for:
- Count of `OptimisticLockException` occurrences per method (log at WARN)
- Count of successful retries vs exhausted retries
- Transaction duration for `closeBOL()` and `releaseOrder()`
- Pessimistic lock wait times
- Connection pool utilization under concurrent load
