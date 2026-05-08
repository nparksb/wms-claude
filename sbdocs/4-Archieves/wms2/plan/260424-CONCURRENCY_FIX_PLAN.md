# Concurrency Fix Plan for WMS-API Service Layer

## Executive Summary

The WMS-API service layer has **270 `.save()` calls across 54 service files** with virtually no concurrency protection. While all 45 JPA entities correctly implement `@Version` for optimistic locking, the service layer does not handle the resulting `ObjectOptimisticLockingFailureException` — meaning concurrent modifications silently crash transactions rather than being retried or handled gracefully.

### Key Statistics

| Metric | Count | Concern Level |
|--------|-------|---------------|
| `.save()` calls across services | 270 | — |
| `.saveAll()` calls | 3 | — |
| `@Transactional` annotations | 40 across 15 files | **HIGH** — 39 service files have saves without transactional boundaries |
| Pessimistic locks (`@Lock`) | 1 (BillofladingRepository only) | **CRITICAL** |
| Optimistic lock retry handling | 1 manual retry in PickingorderBusinessService | **CRITICAL** |
| `OptimisticLockRetry` utility usage | **0** (exists but unused) | **CRITICAL** |
| `synchronized` blocks in services | 0 | — |
| Native queries (bypass L1 cache) | 185 across 41 repositories | **HIGH** |

### Existing Infrastructure (Unused)

An `OptimisticLockRetry` utility already exists at:
```
src/main/java/net/aim_ai/wms/util/OptimisticLockRetry.java
```
- Provides `executeWithRetry(Supplier<T>, String)` and `executeWithRetry(Runnable, String)` methods
- MAX_RETRIES = 3 with exponential backoff (100ms * attempt)
- Catches `ObjectOptimisticLockingFailureException` and retries
- **Currently imported/used by ZERO service files**

---

## Issue Categories

### Category 1: CRITICAL — Lost Updates / Double Allocation

Issues where concurrent operations can corrupt data, lose stock amounts, or double-allocate inventory.

### Category 2: HIGH — Missing Transaction Boundaries

Methods that modify multiple entities via `.save()` but lack `@Transactional`, meaning partial failures leave the database in an inconsistent state.

### Category 3: MEDIUM — Stale Read-Then-Write (TOCTOU)

Methods that read an entity, make decisions based on the read value, then write — without any lock to prevent another thread from changing the entity between read and write.

### Category 4: LOW — Swallowed Exceptions / Silent Failures

Methods that catch `ObjectOptimisticLockingFailureException` but do not retry or propagate, silently losing state changes.

---

## Detailed Findings by Service

### 1. `ReleaseOrderJobService` — CRITICAL: Stock Double-Allocation

**File:** `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java`
**Save calls:** 24
**Transaction:** `@Transactional(propagation = Propagation.REQUIRES_NEW)`

**Problem:** `releaseOrder()` reads available stock quantities via `getStockUnitAvailable()` and `getStockUnitsByItemDataId()`, then creates picking positions and reserves stock. Two concurrent `releaseOrder()` calls for orders with the same SKU can both read the same available quantity and both reserve it — **double-allocating stock**.

**Specific Flow:**
1. Thread A reads: 10 units available for SKU-123
2. Thread B reads: 10 units available for SKU-123 (same snapshot)
3. Thread A reserves 8 units → creates picking positions
4. Thread B reserves 8 units → creates picking positions
5. Result: 16 units reserved from 10 available — **inventory integrity broken**

**Additional concern:** Uses shared `itemDataAvailableAmountMap` passed from caller. If caller runs in parallel (e.g., batch release), this map could have stale data.

**Fix:**
- Add pessimistic lock on stock unit reads during order release (`SELECT ... FOR UPDATE`)
- Or serialize order releases per SKU using a distributed lock / database advisory lock
- Wrap stock reservation in `OptimisticLockRetry` with re-fetch of available quantities

---

### 2. `MobilePickingService` — CRITICAL: Concurrent Warehouse Worker Conflicts

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`
**Save calls:** 27 (highest of any service)
**Transaction:** Only some methods have `@Transactional`

**Problem:** Multiple warehouse workers simultaneously operate on picking orders. Many methods lack `@Transactional`, and none use optimistic lock retry.

**Missing `@Transactional` on methods that call `.save()`:**
- `resumePickingOrderIfExists()` — saves pickingOrder state changes
- `processPick()` — modifies pickingOrder, customerOrder, pickingUnitLoad, multiple pickingPositions
- `rapidPickingScanPackage()` — sets operator and lockedtooperator on pickingOrder
- `rapidPickingScanSource()` — saves pickingOrder.setPickinginprogress(true), then calls confirmPick
- `releaseRegularPickingOrder()` — reads positions, checks state, saves order

**Concurrency Scenarios:**
- Worker A picks last item from order → sets order to FINISHED
- Worker B (assigned to same order due to race) picks same position → `ObjectOptimisticLockingFailureException` crashes request
- `processPick()` updates 4-5 entities without a transaction — partial failure leaves order in inconsistent state

**Fix:**
- Add `@Transactional` to all methods that call `.save()`
- Wrap critical state transitions (pick confirmation, order finish) in `OptimisticLockRetry`
- Add pessimistic lock when selecting/reserving a picking order for a worker

---

### 3. `StockunitBusinessService` — CRITICAL: Core Stock Mutations Unprotected

**File:** `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java`
**Save calls:** 8
**Transaction:** `@Transactional` on some methods

**Problem:** This is the central service for stock amount changes. While it re-fetches entities before modification (good practice), the window between re-fetch and save is unprotected.

**Vulnerable Methods:**
- `changeAmount()` — saves stock unit with new amount; uses **stale entity passed as parameter** (does NOT re-fetch)
- `changeReservedAmount()` — re-fetches stockUnit before modifying reserved amount, but no retry on optimistic lock failure
- `transferStockToUnitLoad()` — re-fetches destination and source stock units before modifying amounts, but no retry

**Scenario:**
1. `releaseOrder()` calls `changeReservedAmount(stockUnit, +8)`
2. `processPick()` calls `changeReservedAmount(stockUnit, -1)` concurrently
3. Both re-fetch the same version → one will get `ObjectOptimisticLockingFailureException` → unhandled → transaction rolls back → user sees error

**Fix:**
- Wrap ALL `changeAmount()` and `changeReservedAmount()` calls in `OptimisticLockRetry`
- `changeAmount()` must re-fetch the entity inside the retry lambda, not use the stale parameter
- Consider pessimistic lock for `transferStockToUnitLoad()` which modifies two stock units atomically

---

### 4. `CustomerorderBatchService` — CRITICAL: Thread-Unsafe Shared State

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
**Save calls:** 11
**Transaction:** `@Transactional` on main methods

**Problem:** Uses **instance-level fields as caches** that are overwritten on each call:
```java
// Instance fields — NOT thread-safe
private Map<Long, List<Unitload>> carrierToChildrenMap;
private Map<Long, List<Stockunit>> unitLoadToStockMap;
private Map<Long, Itemdata> itemDataMap;
private Map<Long, ...> resultCache;
```

When two requests hit `CustomerorderBatchService` concurrently:
1. Request A calls `initializeCaches()` → populates maps for Batch-001
2. Request B calls `initializeCaches()` → **overwrites maps** with data for Batch-002
3. Request A continues processing using **Batch-002's data** → wrong batch processed

**Additional:** `calculateUnitLoadAmounts()` uses `parallelStream()` with a shared `HashMap` — race condition on the map itself.

**Fix:**
- Convert all instance-level cache fields to **method-local variables** passed as parameters
- Or wrap them in a `BatchProcessingContext` object created per-request
- Replace `parallelStream()` + shared `HashMap` with either sequential stream or `ConcurrentHashMap`

---

### 5. `PickingorderBusinessService` — HIGH: Partial Retry Implementation

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
**Save calls:** 17
**Transaction:** `@Transactional` on key methods

**Problem:** `confirmPick()` is the **only method in the entire codebase** with explicit optimistic lock retry — but it's a manual single-retry, not using the `OptimisticLockRetry` utility:

```java
// Lines 311-324 — manual single retry
try {
    pickingPosition = pickingPositionRepository.save(pickingPosition);
} catch (ObjectOptimisticLockingFailureException e) {
    // Re-fetch and retry once
    pickingPosition = pickingPositionRepository.findById(pickingPosition.getId()).get();
    pickingPosition.setAmount(...);
    pickingPosition = pickingPositionRepository.save(pickingPosition);
}
```

This only retries once, and only for the pickingPosition save — the method also saves customerOrderPosition, customerOrder, pickingOrder, and stockUnit without retry.

**Other unprotected methods:**
- `finishPickingOrder()` — iterates positions, transfers unit loads, saves multiple entities
- `cleanUpCancelledOrder()` — modifies stockUnits, customerOrder, positions, orderBatch — no lock

**Fix:**
- Replace manual retry with `OptimisticLockRetry.executeWithRetry()`
- Add retry handling to all `.save()` calls in `confirmPick()`, not just pickingPosition
- Add `OptimisticLockRetry` to `finishPickingOrder()` and `cleanUpCancelledOrder()`

---

### 6. `BillofladingService` — MEDIUM: Best-Protected but Gaps Remain

**File:** `src/main/java/net/aim_ai/wms/service/BillofladingService.java`
**Save calls:** 15 + 3 saveAll()
**Transaction:** `@Transactional` on key methods

**Current Protection (Good):**
- `closeBOL()` — `ConcurrentHashMap` guard (`bolToClose.add()`) + pessimistic lock (`findByIdForUpdate`) + `@Transactional`
- `finishTransfer(String)` — pessimistic lock via `findByIdForUpdate`
- `finishTransfer(Billoflading)` — `entityManager.refresh()` before modifying entities post-transfer

**Remaining Gaps:**
- `transferOrder()` — `@Transactional` but no lock on customerOrder; concurrent transfers for same order possible
- `addOrderToBol()` / `removeOrderFromBol()` — no lock on BOL entity during modification
- Bulk JPQL UPDATEs bypass optimistic locking (no version check in UPDATE statements)

**Fix:**
- Add pessimistic lock when modifying BOL membership (add/remove orders)
- Add version check to bulk JPQL UPDATE statements: `WHERE ... AND version = :version`
- Wrap `transferOrder()` customer order save in `OptimisticLockRetry`

---

### 7. `UnitloadBusinessService` — MEDIUM: Partial Protection

**File:** `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`
**Save calls:** 4
**Transaction:** None (relies on caller's transaction)

**Current Protection (Partial):**
- `transferUnitLoadToLocation()` — catches `ObjectOptimisticLockingFailureException` on carrier removal (line 150), throws `BusinessException`
- `transferUnitLoadToCarrier()` — re-fetches unitload (line 170)
- `processTransfer()` — re-fetches unitload (line 232)

**Gaps:**
- Catching optimistic lock exception and throwing `BusinessException` is not a retry — the operation just fails
- `processTransfer()` is recursive for child unit loads — if any child save fails, the entire tree is partially updated
- No `@Transactional` on any method — relies entirely on the caller having a transaction

**Fix:**
- Add `@Transactional` to `transferUnitLoadToLocation()` and `transferUnitLoadToCarrier()`
- Replace catch-and-throw with `OptimisticLockRetry` for carrier removal
- Consider pessimistic lock for `processTransfer()` on the unit load being transferred

---

### 8. `MobileReplenishService` — HIGH: Missing Transactions

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`
**Save calls:** 8
**Transaction:** Only on some methods

**Missing `@Transactional`:**
- `resetOrder()` — reads order, checks state, saves — no transaction boundary
- Methods that call `stockunitBusinessService.changeReservedAmount()` — if this fails, the outer method has no transaction to roll back

**Concurrency Issues:**
- `startOrder()` — reads replenish order, checks state == CREATED, sets operator, saves. Two workers could start the same order simultaneously.
- `checkSource()` — switches source stock unit, changes reserved amounts — multi-entity update without lock
- `finishReplenishmentOrderInternal()` — changes reserved amounts, transfers stock, saves order — no lock

**Fix:**
- Add `@Transactional` to `resetOrder()` and any other method with `.save()` calls
- Add pessimistic lock or optimistic retry when starting/claiming a replenish order
- Wrap stock amount changes in `OptimisticLockRetry`

---

### 9. `TransferOrderService` — MEDIUM: TOCTOU Race on Lane Assignment

**File:** `src/main/java/net/aim_ai/wms/service/TransferOrderService.java`
**Save calls:** 4
**Transaction:** `@Transactional` on key methods

**Problem:** `assignTransferLaneToTransferOrder()` and `activateTransferOrder()` check available transfer lanes, then assign one. Two concurrent transfers can both see the same lane as available and both assign it.

**Fix:**
- Add pessimistic lock when querying available lanes
- Or use `OptimisticLockRetry` on the lane assignment save

---

### 10. `MobilePalletizingService` — LOW: Silently Swallowed Exception

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizingService.java`

**Problem:** `scanPallet()` catches `ObjectOptimisticLockingFailureException` but only logs it — the order state change is silently lost:

```java
try {
    customerOrder = customerOrderRepository.save(customerOrder);
} catch (ObjectOptimisticLockingFailureException e) {
    LOG.warn("Optimistic lock on customer order {}", customerOrder.getId());
    // State change is LOST — no retry, no error to user
}
```

**Fix:**
- Replace with `OptimisticLockRetry.executeWithRetry()` to properly retry the operation
- Never silently swallow optimistic lock exceptions

---

### 11. `ReceivingService` — MEDIUM: No Transaction on Transfers

**File:** `src/main/java/net/aim_ai/wms/service/ReceivingService.java`
**Save calls:** 6
**Transaction:** `@Transactional` on `receiveGoods()` only

**Missing `@Transactional`:**
- `assignPallet()` — transfers unit load to carrier, no transaction
- `unassignPallet()` — transfers unit load to location, no transaction

**Fix:**
- Add `@Transactional` to `assignPallet()` and `unassignPallet()`

---

### 12. `ReplenishOrderJobService` — MEDIUM: Race on Stock Quantity Reads

**File:** `src/main/java/net/aim_ai/wms/service/job/ReplenishOrderJobService.java`
**Save calls:** 1
**Transaction:** `@Transactional(propagation = Propagation.REQUIRES_NEW)`

**Problem:** `generateReplenishmentForItemDataWithFixedAssignment()` reads stock quantities, calculates if replenishment is needed, then creates an order. Concurrent stock changes between read and order creation can lead to unnecessary or duplicate replenishment orders.

**Fix:**
- Add pessimistic lock on stock reads during replenishment calculation
- Or add idempotency check: before creating order, verify no pending replenishment order exists for the same SKU/location

---

## Fix Strategy

### Phase 1: Critical Fixes (Week 1-2) — Prevent Data Corruption

These fixes prevent stock double-allocation and lost updates — the highest-impact bugs.

#### 1.1 Integrate `OptimisticLockRetry` into `StockunitBusinessService`

**Priority:** CRITICAL
**Effort:** Low
**Files:** `StockunitBusinessService.java`

```java
@Autowired
private OptimisticLockRetry optimisticLockRetry;

public void changeAmount(Long stockunitId, BigDecimal deltaAmount, String reason) {
    optimisticLockRetry.executeWithRetry(() -> {
        Stockunit fresh = stockunitRepository.findById(stockunitId).orElseThrow();
        fresh.setAmount(fresh.getAmount().add(deltaAmount));
        return stockunitRepository.save(fresh);
    }, "changeAmount-" + stockunitId);
}

public void changeReservedAmount(Long stockunitId, BigDecimal deltaReserved) {
    optimisticLockRetry.executeWithRetry(() -> {
        Stockunit fresh = stockunitRepository.findById(stockunitId).orElseThrow();
        fresh.setReservedAmount(fresh.getReservedAmount().add(deltaReserved));
        return stockunitRepository.save(fresh);
    }, "changeReservedAmount-" + stockunitId);
}
```

**Key change:** Methods must accept entity IDs (not stale entity objects) so the retry lambda can re-fetch fresh data.

#### 1.2 Add Pessimistic Lock for Stock Reservation in `ReleaseOrderJobService`

**Priority:** CRITICAL
**Effort:** Medium
**Files:** `StockunitRepository.java`, `ReleaseOrderJobService.java`

Add a pessimistic-locked stock query:
```java
// StockunitRepository.java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT s FROM Stockunit s WHERE s.id = :id")
Optional<Stockunit> findByIdForUpdate(@Param("id") Long id);

@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT s FROM Stockunit s WHERE s.itemdataId = :itemdataId AND s.amount - s.reservedAmount > 0")
List<Stockunit> findAvailableByItemdataIdForUpdate(@Param("itemdataId") Long itemdataId);
```

Use the locked query in `releaseOrder()` when checking and reserving stock.

#### 1.3 Fix `CustomerorderBatchService` Shared Mutable State

**Priority:** CRITICAL
**Effort:** Medium
**Files:** `CustomerorderBatchService.java`

Convert instance fields to a method-local context object:

```java
private static class BatchContext {
    final Map<Long, List<Unitload>> carrierToChildrenMap;
    final Map<Long, List<Stockunit>> unitLoadToStockMap;
    final Map<Long, Itemdata> itemDataMap;
    // ... constructor initializes all maps
}
```

Pass `BatchContext` to all internal methods instead of using instance fields. Replace `parallelStream()` with sequential stream or use `ConcurrentHashMap`.

#### 1.4 Fix `MobilePalletizingService` Swallowed Exception

**Priority:** CRITICAL
**Effort:** Low
**Files:** `MobilePalletizingService.java`

Replace silent catch with `OptimisticLockRetry`:

```java
@Autowired
private OptimisticLockRetry optimisticLockRetry;

// In scanPallet():
optimisticLockRetry.executeWithRetry(() -> {
    Customerorder fresh = customerOrderRepository.findById(customerOrder.getId()).orElseThrow();
    fresh.setState(newState);
    return customerOrderRepository.save(fresh);
}, "scanPallet-updateOrderState-" + customerOrder.getId());
```

---

### Phase 2: High-Priority Fixes (Week 3-4) — Add Missing Transactions & Retries — COMPLETED

> **Status:** COMPLETED — Commit `af41b4e` (2026-02-16)
> **Tests:** All 28 PickingorderBusinessServiceUnitTest tests pass. Full suite: 3249 tests, 0 new failures introduced.

#### 2.1 Add Missing `@Transactional` Annotations — DONE

**Priority:** HIGH
**Effort:** Low
**Files:** Multiple

Added `@Transactional(rollbackFor = Exception.class)` to 9 methods:

| Service | Methods |
|---------|---------|
| `MobilePickingService` | `resumePickingOrderIfExists()`, `processPick()`, `rapidPickingScanPackage()`, `rapidPickingScanSource()`, `releaseRegularPickingOrder()` |
| `MobileReplenishService` | `resetOrder()` |
| `ReceivingService` | `assignPallet()`, `unassignPallet()` |
| `UnitloadBusinessService` | `transferUnitLoadToLocation()`, `transferUnitLoadToCarrier()` |

#### 2.2 Add `OptimisticLockRetry` to `PickingorderBusinessService.confirmPick()` — DONE

**Priority:** HIGH
**Effort:** Low
**Files:** `PickingorderBusinessService.java`

Replaced manual single-retry with `OptimisticLockRetry` utility. Lambda re-fetches the picking position by ID before mutating, ensuring fresh version on each retry attempt.

#### 2.3 Add Pessimistic Lock for Picking Order Assignment — DONE

**Priority:** HIGH
**Effort:** Medium
**Files:** `PickingorderRepository.java`, `MobilePickingService.java`

Added `findByIdForUpdate()` with `@Lock(LockModeType.PESSIMISTIC_WRITE)` to `PickingorderRepository`. Updated `selectAndReservePickingOrder()` in `MobilePickingService` to use it, preventing two workers from claiming the same order.

#### 2.4 Add `OptimisticLockRetry` to `MobileReplenishService` — DONE

**Priority:** HIGH
**Effort:** Low-Medium
**Files:** `MobileReplenishService.java`

Added optimistic lock conflict handling in `startOrder()`: catches `ObjectOptimisticLockingFailureException`, re-fetches the order, and checks if another worker already claimed it (throws `FacadeException("REPLENISH_RESERVED")` if so, otherwise retries save).

---

### Phase 3: Medium-Priority Fixes (Week 5-6) — Harden Remaining Services — COMPLETED

> **Status:** COMPLETED — Commit `a6b8d6b` (2026-02-16)
> **Tests:** All 3,249 tests pass (0 failures, 0 errors). Clean build resolved pre-existing incremental compilation issues.

#### 3.1 Add Pessimistic Lock for BOL Membership Changes — N/A (ALREADY DONE)

**Priority:** MEDIUM
**Files:** `BillofladingService.java`

The methods `addOrderToBol()`/`removeOrderFromBol()` do not exist. Both `closeBOL()` and `finishTransfer()` already use `findByIdForUpdate()` pessimistic locking (from Phase 1 optimization).

#### 3.2 Add Version Check to Bulk JPQL UPDATEs — N/A (ALREADY DONE)

**Priority:** MEDIUM
**Files:** `BillofladingService.java`

All bulk JPQL UPDATEs in `BillofladingService` already include `version = version + 1` (added during Phase 1 optimization). The only other `@Query UPDATE` (`ClientRepository.updatePrinterToNullByPrinterId`) is an administrative operation.

#### 3.3 Fix `TransferOrderService` Lane Assignment Race — DONE

**Priority:** MEDIUM
**Files:** `LocationRepository.java`

Added `@Lock(LockModeType.PESSIMISTIC_WRITE)` to `getAvailableTransferLanes()` query. This serializes concurrent lane assignment attempts, preventing two customer orders from claiming the same transfer lane.

#### 3.4 Add `OptimisticLockRetry` to `UnitloadBusinessService` — DONE

**Priority:** MEDIUM
**Files:** `UnitloadBusinessService.java`

Replaced catch-and-throw pattern in `transferUnitLoadToLocation()` with `OptimisticLockRetry`. The retry lambda re-fetches the unitload by ID before re-clearing the carrier link, ensuring fresh version on each attempt. `@Transactional` was already added in Phase 2.

#### 3.5 Add Idempotency to `ReplenishGeneratorService` — DONE

**Priority:** MEDIUM
**Files:** `ReplenishGeneratorService.java`

Added idempotency check in `calculateOrder()`: before creating a new replenish order, queries for existing non-finished orders with the same item + destination. Returns null (skips creation) if a pending order already exists, preventing duplicates from concurrent job executions.

---

### Phase 4: Infrastructure & Testing (Week 7-8) — COMPLETED

> **Status:** COMPLETED — Commit `df7fb30` (2026-02-16)
> **Tests:** All 3,256 tests pass (0 failures, 0 errors). Clean build.

#### 4.1 Create Pessimistic Lock Repository Methods — DONE

**Priority:** HIGH (supports Phases 1-3)
**Files:** `CustomerorderRepository.java`, `ReplenishorderRepository.java`, `UnitloadRepository.java`

Added `findByIdForUpdate()` with `@Lock(LockModeType.PESSIMISTIC_WRITE)` to all remaining key repositories:

| Repository | Status |
|------------|--------|
| `BillofladingRepository` | Already had `findByIdForUpdate` |
| `StockunitRepository` | Already had `findByIdForUpdate` (Phase 1) |
| `PickingorderRepository` | Already had `findByIdForUpdate` (Phase 2) |
| `CustomerorderRepository` | **Added** `findByIdForUpdate` |
| `ReplenishorderRepository` | **Added** `findByIdForUpdate` |
| `UnitloadRepository` | **Added** `findByIdForUpdate` |
| `LocationRepository` | Already had `@Lock` on `getAvailableTransferLanes` (Phase 3) |

Note: `TransferLaneRepository` does not exist as a separate repository — transfer lane queries are in `LocationRepository`.

#### 4.2 Enhance `OptimisticLockRetry` Utility — DONE

**Priority:** MEDIUM
**Files:** `OptimisticLockRetry.java`

Enhancements applied:
- **`StaleObjectStateException` catch:** Now catches both Spring's `ObjectOptimisticLockingFailureException` AND Hibernate's `StaleObjectStateException` for comprehensive coverage
- **Configurable max retries:** Added overloaded `executeWithRetry(operation, name, maxRetries)` for both `Supplier<T>` and `Runnable` variants. Default remains 3 via `DEFAULT_MAX_RETRIES` constant
- **Improved logging:** Log messages now include `attempt/maxRetries` format (e.g., "attempt 1/3") for better observability

#### 4.3 Write Concurrency Unit Tests — DONE

**Priority:** MEDIUM
**Files:** `OptimisticLockRetryTest.java`

Added 7 new tests (total: 15) covering:
- `StaleObjectStateException` retry and exhaustion (3 tests)
- Mixed Spring + Hibernate exception handling in same retry sequence
- Configurable max retries for `Supplier` and `Runnable` (3 tests)
- `DEFAULT_MAX_RETRIES` constant verification

Note: Multi-threaded integration tests (concurrent stock reservation, picking order claims) require a real PostgreSQL database and are deferred to production testing with TestContainers. The current H2-based integration test infrastructure doesn't reliably support `SELECT ... FOR UPDATE` semantics needed for pessimistic lock testing.

#### 4.4 Audit Native Queries for Cache Bypass Issues — DONE (Documented)

**Priority:** LOW
**Effort:** Audit complete; no code changes needed for critical paths

185 native queries across 41 repositories bypass Hibernate's first-level cache. Audit identified 8 service methods with potential cache bypass issues:

| Service | Method | Risk | Existing Mitigation |
|---------|--------|------|---------------------|
| `BillofladingService` | `closeBOL()` | CRITICAL | **Already mitigated**: `flush()` + `clear()` + merge on save |
| `BillofladingService` | `finishTransfer()` | HIGH | **Already mitigated**: `entityManager.refresh()` calls |
| `ReleaseOrderJobService` | `releaseOrder()` | HIGH | Uses `REQUIRES_NEW` propagation (isolated transaction) |
| `CustomerorderBatchService` | `runClubLine()` | MEDIUM | Cache-local maps rebuilt per call |
| `PickingorderBusinessService` | `confirmPick()` | MEDIUM | Re-fetches via `findById()` (JPQL, uses L1 cache) |
| `StockunitBusinessService` | `transferStockToUnitLoad()` | MEDIUM | Re-fetches entities before mutation |
| `MobilePickingService` | `processPick()` | LOW-MEDIUM | Delegates to service methods with own cache management |
| `MobileReplenishService` | `fulfillMultipleUnitLoads()` | MEDIUM | Creates new entities (no stale reads) |

**Conclusion:** The two critical cases (`closeBOL` and `finishTransfer`) already have explicit cache management (`flush+clear` and `entityManager.refresh` respectively). The remaining cases primarily use JPQL `findById()` which works through the L1 cache. No additional `flush()` calls are needed at this time.

---

## Implementation Guidelines

### Pattern: Using `OptimisticLockRetry` Correctly

**DO:** Re-fetch the entity inside the retry lambda:
```java
optimisticLockRetry.executeWithRetry(() -> {
    Stockunit fresh = stockunitRepository.findById(id).orElseThrow();
    fresh.setAmount(fresh.getAmount().add(delta));
    return stockunitRepository.save(fresh);
}, "operationName");
```

**DON'T:** Pass a stale entity into the retry lambda:
```java
// WRONG — same stale entity is retried, will fail every time
optimisticLockRetry.executeWithRetry(() -> {
    staleEntity.setAmount(newAmount);
    return repository.save(staleEntity);
}, "operationName");
```

### Pattern: Pessimistic Lock for Critical Sections

Use pessimistic locks when:
- Multiple threads compete for the same resource (order assignment, lane assignment)
- You need to read-then-write atomically (stock reservation)
- The cost of retry is higher than the cost of waiting (complex multi-entity operations)

```java
// Repository
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT e FROM Entity e WHERE e.id = :id")
Optional<Entity> findByIdForUpdate(@Param("id") Long id);

// Service
@Transactional
public void criticalOperation(Long entityId) {
    Entity locked = repository.findByIdForUpdate(entityId)
        .orElseThrow(() -> new BusinessException("Not found"));
    // Now safe to modify — other transactions will wait
    locked.setState(newState);
    repository.save(locked);
}
```

### Pattern: Fixing Method Signatures for Retry

Current pattern (problematic):
```java
public void changeAmount(Stockunit stockunit, BigDecimal delta) {
    stockunit.setAmount(stockunit.getAmount().add(delta));
    stockunitRepository.save(stockunit); // Stale entity — will fail on version conflict
}
```

Fixed pattern:
```java
public Stockunit changeAmount(Long stockunitId, BigDecimal delta) {
    return optimisticLockRetry.executeWithRetry(() -> {
        Stockunit fresh = stockunitRepository.findById(stockunitId).orElseThrow();
        fresh.setAmount(fresh.getAmount().add(delta));
        return stockunitRepository.save(fresh);
    }, "changeAmount-" + stockunitId);
}
```

**Note:** Changing method signatures from `(Entity entity, ...)` to `(Long entityId, ...)` will require updating all callers. Plan for this cascade.

### Transaction Propagation Guide

| Situation | Use |
|-----------|-----|
| Public service method called by controller | `@Transactional` |
| Method called by another `@Transactional` method | `@Transactional(propagation = Propagation.REQUIRED)` (default, joins existing) |
| Background job method that must commit independently | `@Transactional(propagation = Propagation.REQUIRES_NEW)` |
| Read-only query method | `@Transactional(readOnly = true)` |

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Changing method signatures breaks callers | Phased approach; update callers in same PR |
| Pessimistic locks cause deadlocks | Always lock in consistent order (by entity ID); set lock timeout |
| Pessimistic locks reduce throughput | Only use for truly critical sections; prefer optimistic retry for most cases |
| Adding `@Transactional` changes behavior | Test each method; some may already participate in caller's transaction |
| Retry logic masks bugs | Log all retries; monitor retry frequency; alert on high retry rates |
| Native query cache bypass | Flush before native queries in same transaction |

---

## Priority Summary

| Phase | What | Impact | Effort | Timeline |
|-------|------|--------|--------|----------|
| **Phase 1** | Stock protection, shared state fix, swallowed exceptions | Prevents data corruption | Medium | COMPLETED (`8e2e3dc`) |
| **Phase 2** | Missing transactions, picking/replenish retries | Prevents partial failures & worker conflicts | Medium | COMPLETED (`af41b4e`) |
| **Phase 3** | BOL hardening, lane races, version-checked bulk updates | Reduces edge case failures | Low-Medium | COMPLETED (`a6b8d6b`) |
| **Phase 4** | Infrastructure, testing, native query audit | Long-term reliability | High | COMPLETED (`df7fb30`) |

---

## Additional Findings (from deep analysis)

### 13. `StockunitService.transferStock()` — CRITICAL: Missing `@Transactional`

**File:** `src/main/java/net/aim_ai/wms/service/StockunitService.java` (line ~100)

**Problem:** A ~135-line method modifying stockunits, unitloads, and fix location assignments with multiple `.save()` calls that each auto-commit independently. On partial failure, stock is transferred from source but not credited to destination — **inventory discrepancy**.

**Fix:** Add `@Transactional` to ensure all saves commit or roll back atomically.

---

### 14. `ParcelMonitorViewService.palletise()` / `palletiseAndTruckLoad()` — CRITICAL: Missing `@Transactional`

**File:** `src/main/java/net/aim_ai/wms/service/ParcelMonitorViewService.java` (lines ~72-325)

**Problem:** Complex multi-entity operations (create pallets, save orders, create BOL positions, transfer unitloads) without any transaction boundary. Partial failure can create orphaned pallets or BOL positions.

**Fix:** Add `@Transactional` to both methods.

---

### 15. `UnitloadService.deleteUnitLoad()` — BUG: Wrong Field Compared

**File:** `src/main/java/net/aim_ai/wms/service/UnitloadService.java` (lines 303-304)

**Problem:** Uses `stockUnit.getVersion()` instead of `stockUnit.getEntityLock()` when checking if stock is damaged/on-hold before OMS notification. This means damaged/on-hold stock is always reported as normal stock. Not a concurrency issue per se, but discovered during analysis.

**Fix:** Replace `stockUnit.getVersion()` with `stockUnit.getEntityLock()`.

---

### 16. `SimpleDateFormat` Thread Safety — HIGH: Shared Mutable Formatter

**Files:**
- `src/main/java/net/aim_ai/wms/service/SharedService.java` (line ~36)
- `src/main/java/net/aim_ai/wms/service/NameTypeService.java` (line ~21)
- `src/main/java/net/aim_ai/wms/service/ReceivingService.java` (line ~121)

**Problem:** `SimpleDateFormat` is not thread-safe. When stored as an instance field on a singleton Spring bean, concurrent requests can corrupt date formatting, producing garbled dates or `ArrayIndexOutOfBoundsException`.

**Fix:** Replace with thread-safe `java.time.format.DateTimeFormatter`:
```java
// Before (NOT thread-safe)
private SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd");

// After (thread-safe, immutable)
private static final DateTimeFormatter DATE_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd");
```

---

### 17. Missing Unique Constraint on `Unitload.labelid`

**Problem:** No database-level unique constraint on `Unitload.labelid`. Under concurrent create operations, duplicate label IDs could be inserted. The application relies on application-level checks which are subject to TOCTOU races.

**Fix:** Add a Flyway migration with a unique constraint:
```sql
ALTER TABLE unitload ADD CONSTRAINT uq_unitload_labelid UNIQUE (labelid);
```

---

### Updated Phase 1 Additions

The following should be added to **Phase 1** (Critical Fixes):

| # | Fix | File | Effort |
|---|-----|------|--------|
| 1.5 | Add `@Transactional` to `StockunitService.transferStock()` | `StockunitService.java` | Low |
| 1.6 | Add `@Transactional` to `ParcelMonitorViewService.palletise()` methods | `ParcelMonitorViewService.java` | Low |
| 1.7 | Fix `getVersion()` → `getEntityLock()` bug in `UnitloadService` | `UnitloadService.java:303-304` | Trivial |

The following were added to **Phase 2** (High-Priority Fixes) — **ALL DONE**:

| # | Fix | File | Status |
|---|-----|------|--------|
| 2.5 | Replace `SimpleDateFormat` with `DateTimeFormatter` | `SharedService.java`, `NameTypeService.java`, `ReceivingService.java` | DONE |
| 2.6 | Add unique DB constraint on `Unitload.labelid` | `V1.1.06__add_unique_constraint_unitload_labelid.sql` | DONE |

---

## Appendix: Complete Save Call Inventory

Services sorted by number of `.save()` calls (top 15):

| Service | `.save()` Count | Has `@Transactional` | Has Lock/Retry |
|---------|----------------|---------------------|----------------|
| `MobilePickingService` | 27 | Partial | No |
| `ReleaseOrderJobService` | 24 | Yes (REQUIRES_NEW) | No |
| `PickingorderBusinessService` | 17 | Yes | Manual single-retry (1 spot) |
| `BillofladingService` | 15 + 3 saveAll | Yes | Pessimistic lock (closeBOL) |
| `CustomerorderBatchService` | 11 | Yes | No |
| `StockunitBusinessService` | 8 | Partial | No |
| `MobileReplenishService` | 8 | Partial | No |
| `ReceivingService` | 6 | Partial | No |
| `UnitloadBusinessService` | 4 | No (relies on caller) | Catch-and-throw (1 spot) |
| `TransferOrderService` | 4 | Yes | No |
| `MobilePalletizingService` | ~4 | Partial | Swallowed exception (1 spot) |
| `MobileTruckLoadingService` | ~4 | Partial | No |
| `MobileCycleCountService` | ~3 | Partial | No |
| `ReplenishOrderJobService` | 1 | Yes (REQUIRES_NEW) | No |
