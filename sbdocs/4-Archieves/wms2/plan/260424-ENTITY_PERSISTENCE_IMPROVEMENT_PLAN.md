# Entity Persistence Improvement Plan

**Created:** 2026-02-04
**Updated:** 2026-02-05
**Status:** COMPLETE (All 5 Phases)
**Goal:** Fix missing save() calls, optimistic lock issues, and improve transaction boundaries

---

## Executive Summary

Analysis of the `net.aim_ai.wms.service` package revealed several entity persistence issues that could cause data loss, inconsistency, and concurrency problems in production. This plan outlines a phased approach to address these issues by severity.

| Severity | Issues Found | Effort | Impact |
|----------|--------------|--------|--------|
| Critical | 2 | Low | High |
| High | 5 | Medium | High |
| Medium | 4 | Medium | Medium |

---

## Issue Categories

### Category 1: Missing save() Calls
Entities are modified but never persisted to the database.

### Category 2: Silent Exception Swallowing
Optimistic lock exceptions are caught and logged but not handled properly.

### Category 3: Stale Entity Modifications
Entities passed as parameters are modified without re-fetching fresh state.

### Category 4: Missing Transaction Boundaries
Multiple entity modifications happen without `@Transactional`, causing partial commits.

---

## Phase 1: Critical Fixes (Immediate)

**Effort:** Low
**Risk:** Low
**Impact:** High
**Timeline:** Immediate
**Status:** COMPLETE (2026-02-04)

### 1.1 Fix Missing save() in MobileReplenishService.resetOrder()

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`
**Line:** ~209-211

**Current Code:**
```java
public void resetOrder(Replenishorder order) {
    order.setOperatorId(null);
    order.setState(State.PROCESSABLE);
    // BUG: Missing save() - changes are LOST
}
```

**Fix:**
```java
public void resetOrder(Replenishorder order) {
    order.setOperatorId(null);
    order.setState(State.PROCESSABLE);
    replenishorderRepository.save(order);  // ADD THIS LINE
}
```

**Verification:**
```bash
mvn test -Dtest=MobileReplenishServiceUnitTest#resetOrder*
```

---

### 1.2 Fix Silent Exception Swallowing in UnitloadBusinessService

**File:** `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`
**Line:** ~148-153

**Current Code (DANGEROUS):**
```java
try {
    unitload = unitloadRepository.save(unitload);
} catch (Exception e) {
    LOG.error("Error in transferUnitLoadToLocation with unitload: " + unitload.getId());
    LOG.error("StaleObjectStateException", e);
    // BUG: Exception swallowed - caller thinks operation succeeded!
}
```

**Fix:**
```java
try {
    unitload = unitloadRepository.save(unitload);
} catch (ObjectOptimisticLockingFailureException e) {
    LOG.error("Concurrent modification detected for unitload: {}", unitload.getId());
    throw new BusinessException("Unit load was modified by another user. Please refresh and try again.", e);
} catch (Exception e) {
    LOG.error("Error saving unitload: {}", unitload.getId(), e);
    throw new BusinessException("Failed to save unit load changes.", e);
}
```

**Verification:**
```bash
mvn test -Dtest=UnitloadBusinessServiceUnitTest#*OptimisticLock*
```

---

## Phase 2: High Priority Fixes

**Effort:** Medium
**Risk:** Low-Medium
**Impact:** High
**Timeline:** 1-2 sprints

### 2.1 Fix Commented Out save() in ReceivingService

**File:** `src/main/java/net/aim_ai/wms/service/ReceivingService.java`
**Line:** ~456-457

**Issue:** `unitload.setBoxtypeId(boxType.getId())` is set but save is commented out.

**Task:**
- [ ] Review why save() was commented out (check git history)
- [ ] Either uncomment and fix underlying issue, or remove dead code
- [ ] Add unit test for boxtype persistence

---

### 2.2 Fix Missing OrderBatch save() in CustomerorderBatchService

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
**Line:** ~122-126

**Current Code:**
```java
public void setPriority(CustomerorderBatch orderBatch, int priority) {
    orderBatch.setPriority(priority);
    // BUG: Missing save() for the batch itself
    // Only orders inside batch are saved
}
```

**Fix:**
```java
public void setPriority(CustomerorderBatch orderBatch, int priority) {
    orderBatch.setPriority(priority);
    customerorderBatchRepository.save(orderBatch);  // ADD THIS
}
```

---

### 2.3 Fix CustomerorderPosition save() in forceCancelOrder()

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Line:** ~266-267

**Issue:** Position state is set in loop but individual positions are not saved.

**Current Pattern:**
```java
for (CustomerorderPosition position : positions) {
    position.setState(WmsConstants.State.CANCELED);
    // BUG: position.save() missing - relies on cascade which may not work
}
customerorderRepository.save(customerOrder);  // Only parent saved
```

**Fix:**
```java
for (CustomerorderPosition position : positions) {
    position.setState(WmsConstants.State.CANCELED);
    customerorderPositionRepository.save(position);  // ADD THIS
}
customerorderRepository.save(customerOrder);
```

---

### 2.4 Add Transaction Boundary to PickingorderBusinessService.confirmPick()

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
**Line:** ~239-322

**Issue:** Long method modifies multiple entities without transaction boundary:
- PickingorderPosition
- Stockunit
- CustomerorderPosition
- Customerorder
- Pickingorder
- PickingorderUnitload

**Fix:**
```java
@Transactional(rollbackFor = Exception.class)  // ADD THIS
public void confirmPick(Pickingorder pickingorder, PickingorderPosition position, ...) {
    // existing code
}
```

---

### 2.5 Fix Stale Entity in StockunitBusinessService.transferStockToUnitLoad()

**File:** `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java`
**Line:** ~222-224

**Issue:** Method receives stockunit as parameter but doesn't re-fetch before modification.

**Current Code:**
```java
public void transferStockToUnitLoad(Stockunit sourceStockunit, ...) {
    sourceStockunit.setUnitloadId(destUnitload.getId());
    stockunitRepository.save(sourceStockunit);  // May fail with stale entity
}
```

**Fix:**
```java
public void transferStockToUnitLoad(Stockunit staleSourceStockunit, ...) {
    // Re-fetch to get current version
    Stockunit sourceStockunit = stockunitRepository.findById(staleSourceStockunit.getId())
        .orElseThrow(() -> new BusinessException("Stock unit not found"));
    sourceStockunit.setUnitloadId(destUnitload.getId());
    stockunitRepository.save(sourceStockunit);
}
```

---

## Phase 3: Improve Optimistic Lock Handling

**Effort:** Medium
**Risk:** Medium
**Impact:** Medium-High
**Timeline:** 2-3 sprints

### 3.1 Create Standard Retry Utility

**New File:** `src/main/java/net/aim_ai/wms/util/OptimisticLockRetry.java`

```java
@Component
public class OptimisticLockRetry {

    private static final int MAX_RETRIES = 3;
    private static final long RETRY_DELAY_MS = 100;

    public <T> T executeWithRetry(Supplier<T> operation, String operationName) {
        int attempts = 0;
        while (true) {
            try {
                return operation.get();
            } catch (ObjectOptimisticLockingFailureException e) {
                attempts++;
                if (attempts >= MAX_RETRIES) {
                    LOG.error("Max retries ({}) exceeded for: {}", MAX_RETRIES, operationName);
                    throw new BusinessException("Operation failed after " + MAX_RETRIES +
                        " attempts due to concurrent modifications. Please try again.");
                }
                LOG.warn("Optimistic lock conflict on attempt {} for: {}. Retrying...",
                    attempts, operationName);
                sleep(RETRY_DELAY_MS * attempts);  // Exponential backoff
            }
        }
    }
}
```

### 3.2 Fix Incomplete Retry in PickingorderBusinessService

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
**Line:** ~309-322

**Issue:** Current retry only attempts once and doesn't re-fetch entities.

**Current Code:**
```java
try {
    pickingorderRepository.save(pickingorder);
} catch (ObjectOptimisticLockingFailureException e) {
    // Single retry without re-fetching
    pickingorder.setState(newState);
    pickingorderRepository.save(pickingorder);  // Same stale object!
}
```

**Fix:**
```java
try {
    pickingorderRepository.save(pickingorder);
} catch (ObjectOptimisticLockingFailureException e) {
    // Re-fetch fresh entity before retry
    Pickingorder freshOrder = pickingorderRepository.findById(pickingorder.getId())
        .orElseThrow();
    freshOrder.setState(newState);
    pickingorderRepository.save(freshOrder);
}
```

---

### 3.3 Add @Version to Entities Missing It

Check and add `@Version` annotation to critical entities:

```java
@Entity
public class Stockunit {
    @Version
    private Long version;  // Add if missing
}
```

**Entities to check:**
- [ ] Stockunit
- [ ] Unitload
- [ ] Pickingorder
- [ ] PickingorderPosition
- [ ] Replenishorder
- [ ] Customerorder
- [ ] CustomerorderPosition

---

## Phase 4: Add Transaction Boundaries

**Effort:** Medium-High
**Risk:** Medium
**Impact:** High
**Timeline:** 2-3 sprints

### 4.1 Services Requiring @Transactional

| Service | Method | Reason |
|---------|--------|--------|
| PickingorderBusinessService | confirmPick() | Modifies 6+ entities |
| CustomerorderService | cancelOrder() | Modifies order + all positions |
| CustomerorderService | forceCancelOrder() | Modifies order + positions + stock |
| StockunitBusinessService | transferStockToUnitLoad() | Modifies 2 stockunits |
| MobileReplenishService | finishReplenishmentOrderInternal() | Modifies order + stock |
| ReceivingService | processGoodsReceipt() | Creates multiple entities |

### 4.2 Transaction Propagation Strategy

```java
// For methods that should join existing transaction or create new:
@Transactional(propagation = Propagation.REQUIRED)

// For methods that always need new transaction (e.g., audit logging):
@Transactional(propagation = Propagation.REQUIRES_NEW)
```

---

## Phase 5: Mobile Service Hardening

**Effort:** High
**Risk:** Medium
**Impact:** High
**Timeline:** 3-4 sprints

Mobile services have the highest concurrency due to multiple handheld devices operating simultaneously.

### 5.1 MobilePickingService

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

**Issues:**
- `startPickingOrder()` (line ~251-253): Modifies without re-fetch
- Multiple pickers can attempt same order concurrently

**Improvements:**
- Add `@Transactional` to critical methods
- Implement pessimistic locking for order claiming:
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
Optional<Pickingorder> findByIdForUpdate(Long id);
```

### 5.2 MobileReplenishService

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`

**Issues:**
- `checkSource()` modifies reserved amounts without transaction
- Multiple users can claim same replenish order

**Improvements:**
- Wrap reservation logic in transaction
- Add validation before save to detect stale state

### 5.3 MobilePutAwayService

Review for similar patterns and apply fixes.

---

## Testing Strategy

### Unit Tests for Each Fix

```java
@Test
void resetOrder_shouldPersistChanges() {
    Replenishorder order = createTestOrder(State.STARTED);
    order.setOperatorId(123L);

    mobileReplenishService.resetOrder(order);

    Replenishorder saved = replenishorderRepository.findById(order.getId()).get();
    assertThat(saved.getState()).isEqualTo(State.PROCESSABLE);
    assertThat(saved.getOperatorId()).isNull();
}

@Test
void transferUnitLoad_shouldThrowOnConcurrentModification() {
    // Setup: Another thread modifies the unitload
    Unitload unitload = createTestUnitload();
    simulateConcurrentModification(unitload);

    // Act & Assert
    assertThrows(BusinessException.class, () ->
        unitloadBusinessService.transferUnitLoadToLocation(unitload, location));
}
```

### Integration Tests for Concurrency

```java
@Test
void confirmPick_shouldHandleConcurrentPicks() throws Exception {
    Pickingorder order = createTestOrder();

    // Simulate concurrent picks
    ExecutorService executor = Executors.newFixedThreadPool(2);
    Future<?> pick1 = executor.submit(() -> confirmPick(order, position1));
    Future<?> pick2 = executor.submit(() -> confirmPick(order, position2));

    // Both should complete without data corruption
    pick1.get();
    pick2.get();

    // Verify final state is consistent
    assertOrderStateConsistent(order);
}
```

---

## Progress Tracking

| Phase | Task | Status | Completion Date |
|-------|------|--------|-----------------|
| 1 | Fix MobileReplenishService.resetOrder() | [x] **COMPLETE** | 2026-02-04 |
| 1 | Fix UnitloadBusinessService exception handling | [x] **COMPLETE** | 2026-02-04 |
| 2 | Fix ReceivingService commented save | [x] **COMPLETE** | 2026-02-05 |
| 2 | Fix CustomerorderBatchService.setPriority() | [x] **COMPLETE** | 2026-02-05 |
| 2 | Fix CustomerorderService.forceCancelOrder() | [x] **COMPLETE** | 2026-02-05 |
| 2 | Add @Transactional to PickingorderBusinessService | [x] **COMPLETE** | 2026-02-05 |
| 2 | Fix StockunitBusinessService stale entity | [x] **N/A - Already correct** | 2026-02-05 |
| 3 | Create OptimisticLockRetry utility | [x] **COMPLETE** | 2026-02-05 |
| 3 | Fix PickingorderBusinessService retry | [x] **N/A - Already correct** | 2026-02-05 |
| 3 | Audit @Version on entities | [x] **COMPLETE - All have @Version** | 2026-02-05 |
| 4 | Add @Transactional to CustomerorderService.cancelOrder() | [x] **COMPLETE** | 2026-02-05 |
| 4 | Add @Transactional to StockunitBusinessService.transferStockToUnitLoad() | [x] **COMPLETE** | 2026-02-05 |
| 4 | Add @Transactional to MobileReplenishService.finishReplenishmentOrder() | [x] **COMPLETE** | 2026-02-05 |
| 4 | Add @Transactional to ReceivingService.receiveGoods() | [x] **COMPLETE** | 2026-02-05 |
| 4 | Add @Transactional to PickingorderBusinessService.confirmPick() | [x] **COMPLETE** (Phase 2) | 2026-02-05 |
| 5 | MobilePickingService - Add @Transactional to critical methods | [x] **COMPLETE** | 2026-02-05 |
| 5 | MobileReplenishService - Add @Transactional to checkSource/startOrder | [x] **COMPLETE** | 2026-02-05 |
| 5 | MobilePutAwayService - Add @Transactional to store methods | [x] **COMPLETE** | 2026-02-05 |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Adding @Transactional increases lock time | Keep transactions short, avoid external calls inside transactions |
| Pessimistic locking reduces throughput | Only use for high-contention resources (order claiming) |
| Re-fetching adds DB round trips | Use only for long-running operations where staleness is likely |
| Breaking existing behavior | Comprehensive test coverage before and after changes |

---

## References

- Spring Data JPA Optimistic Locking: https://docs.spring.io/spring-data/jpa/docs/current/reference/html/#locking
- JPA @Version: https://jakarta.ee/specifications/persistence/3.0/jakarta-persistence-spec-3.0.html#a12051
- Transaction Propagation: https://docs.spring.io/spring-framework/docs/current/reference/html/data-access.html#tx-propagation

---

## Appendix: Files Requiring Changes

### Phase 1 (Critical)
- `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`
- `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`

### Phase 2 (High)
- `src/main/java/net/aim_ai/wms/service/ReceivingService.java`
- `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
- `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
- `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
- `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java`

### Phase 3 (Medium)
- `src/main/java/net/aim_ai/wms/util/OptimisticLockRetry.java` (new)
- `src/main/java/net/aim_ai/wms/model/*.java` (audit @Version)

### Phase 4 (Transaction Boundaries)
- Multiple service classes (see Section 4.1)

### Phase 5 (Mobile)
- `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`
- `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`
- `src/main/java/net/aim_ai/wms/service/mobile/MobilePutAwayService.java`
