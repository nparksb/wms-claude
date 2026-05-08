# Order Release Optimistic Lock — Consolidated Fix Plan (v2 Migration)

**Date:** 2026-04-01
**Priority:** High
**Source:** Two v1 plans implemented on `release-260327` branch of `wms-api`:
- `docs/plan/v1-fixes/260401-order-release-optimistic-lock-fix-plan.md` (initial analysis + refresh approach)
- `docs/plan/v1-fixes/260401-order-release-definitive-fix-plan.md` (definitive pessimistic lock fix)
**Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## 1. Problem Summary

`ReleaseOrderJobService.releaseOrder()` loads a `Customerorder` entity at the start of a long-running `REQUIRES_NEW` transaction. During processing (stock availability checks, picking order creation), Hibernate's AUTO flush mode can flush the entity at native query boundaries. If a concurrent writer (UI cancel, priority change, `closeBOL`, mobile picking confirm) has incremented the row's `@Version` since the entity was loaded, the flush throws `ObjectOptimisticLockingFailureException`.

The v1 investigation proved through two iterations that:
1. **`entityManager.refresh()` before save points is insufficient** — auto-flush at native query boundaries can re-flush managed entities between refresh points.
2. **Pessimistic locking (`findByIdForUpdate`) at load time is the definitive fix** — prevents any concurrent writer from modifying the row for the transaction's duration.

## 2. Applicability Analysis

| v1 Fix | v2 Status | Applicable? |
|:-------|:----------|:------------|
| **#1 (HIGH):** `ReleaseOrderJobService` — `findById` → `findByIdForUpdate` on Customerorder load | **NOT applied.** Line 105 uses `findById()` | **YES — needed** |
| **#1 cleanup:** Remove `EntityManager` injection + `refresh()` calls | **Never added in v2.** No EntityManager, no refresh() calls | **N/A — skip** |
| **#2 (MEDIUM):** `PickingorderBusinessService.finishPickingOrder()` — `Set<Customerorder>` → `Set<Long>` dedup | **Already fixed in v2.** Lines 171-174 use `Set<Long> coOrderIds` + `Map<Long, Customerorder> coMap` | **NO — already done** |
| **#3 (LOW):** `PickingorderBusinessService.finishPickingOrder()` — `findById` → `findByIdForUpdate` for Customerorder load | **NOT applied.** Line 174 uses `findAllById()` without locks | **YES — needed** (see §3.2 for v2-adapted approach) |
| **#4 (LOW):** `CustomerorderBatchService` club flow — pessimistic lock on re-fetch | **NOT applicable.** v2 has no stale-order re-fetch pattern in club flow | **NO — skip** |
| **#5 (LOW):** `MobilePickingService` post-finish save — defensive re-fetch | **NOT applicable.** v2 does NOT modify/save pickingOrder after `finishPickingOrder()` calls | **NO — skip** |

### v2-specific differences from v1

1. **`updateStateByIds` is JPQL, not native SQL.** In v2, `CustomerorderRepository.updateStateByIds()` (line 158) uses JPQL (`UPDATE Customerorder c SET c.state = ...`), NOT native SQL. This means it goes through Hibernate and respects `@Version` — it does **not** silently increment the version bypassing JPA. This removes one of v1's primary concurrent writer concerns (`closeBOL`). However, the risk from UI operations, mobile picking, and REST endpoints remains.

2. **v2's `finishPickingOrder` uses bulk pre-fetch pattern.** Instead of loading individual Customerorders via `findById()` in a loop, v2 loads all at once via `findAllById(coOrderIds)` (line 174) into a `Map<Long, Customerorder> coMap`. The v1 fix of changing a single `findById` → `findByIdForUpdate` doesn't directly translate. The v2 fix needs a different approach (see §3.2).

3. **v2's `confirmPick` already uses pessimistic locks correctly.** Lines 396, 485, 530 all use `findByIdForUpdate()` for Customerorder — consistent with v1's pattern.

4. **v2's `ReleaseOrderJobService` has a redundant save at line 219.** After setting `RAW_ON_HOLD` and saving at line 214, line 219 does another `customerorderRepository.save(order)` before returning. This is harmless but wasteful.

---

## 3. Implementation Plan

### Fix #1 (HIGH): Pessimistic Lock on Customerorder Load in `ReleaseOrderJobService`

**File:** `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java`

**Change line 105:**

```java
// BEFORE (line 105):
Customerorder order = customerorderRepository.findById(orderId).orElseThrow(() -> new EntityNotFoundException("CustomerOrder", orderId));

// AFTER:
Customerorder order = customerorderRepository.findByIdForUpdate(orderId).orElseThrow(() -> new EntityNotFoundException("CustomerOrder", orderId));
```

**Why this is the definitive fix:**
- Acquires `SELECT ... FOR UPDATE` row lock at transaction start
- No concurrent writer can increment the `@Version` while the lock is held
- Auto-flush at any native query point will always see the correct version
- Single-line change, no restructuring needed
- Lock scope is acceptable: per-order, `REQUIRES_NEW` transaction, operates on RAW orders not actively used by pickers

**Lock duration concern (addressed):**
- Lock is per-order, not a table lock — other orders process in parallel
- The transaction is `REQUIRES_NEW` — scoped to this single order
- The order being released is in RAW/RAW_ON_HOLD state — not actively used by pickers
- UI operations on the SAME order during release are extremely unlikely and would be blocked briefly
- Lock held for ~100ms-2s per order — acceptable for a cron job

**Concurrent writers that this fix blocks:**

| Writer | Impact When Blocked |
|:-------|:-------------------|
| UI: `setPickingDate()` | Brief wait — user barely notices |
| UI: `cancelOrder()` | Brief wait — cancel completes after release |
| UI: `batchUpdatePriorityByOrderIds()` | Brief wait — priority update completes after release |
| `closeBOL` via `updateStateByIds` | v2 uses JPQL so this respects `@Version` — but lock still prevents the state change from conflicting |
| `confirmPick()` | Already uses its own `findByIdForUpdate` — will wait for release lock to release |

#### Fix #1b: Remove redundant save at line 219

**File:** `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java`

```java
// BEFORE (lines 209-221):
        if (containsUnsatisfiedPosition && !processAnyways) {
            if (order.getState() == WmsConstants.State.RAW ||
                order.getState() == WmsConstants.State.FUTURE_PICKING_DATE ||
                order.getState() == WmsConstants.State.CLIENT_HAS_NO_SECTION) {
                order.setState(WmsConstants.State.RAW_ON_HOLD);
                order = customerorderRepository.save(order);
                manageOrderService.customerOrderOnHold(Collections.singletonList(order));
            }
            if (basicService.showLog())
                LOG.info("working on order={} first round end skipping. not all positions are ready for picking (from previous calculation)", order.getClientordernumber());
            customerorderRepository.save(order);   // ← REDUNDANT: order was already saved at line 214
            return itemDataAvailableAmountUpdateMap;
        }

// AFTER:
        if (containsUnsatisfiedPosition && !processAnyways) {
            if (order.getState() == WmsConstants.State.RAW ||
                order.getState() == WmsConstants.State.FUTURE_PICKING_DATE ||
                order.getState() == WmsConstants.State.CLIENT_HAS_NO_SECTION) {
                order.setState(WmsConstants.State.RAW_ON_HOLD);
                order = customerorderRepository.save(order);
                manageOrderService.customerOrderOnHold(Collections.singletonList(order));
            }
            if (basicService.showLog())
                LOG.info("working on order={} first round end skipping. not all positions are ready for picking (from previous calculation)", order.getClientordernumber());
            return itemDataAvailableAmountUpdateMap;
        }
```

**Why:** The `save(order)` at line 219 is redundant — the order was already saved at line 214 (if state changed) or remains clean (if the `if` block didn't execute, meaning the state was already `RAW_ON_HOLD`). The redundant save creates an unnecessary flush of the entity. With the pessimistic lock this is harmless, but it's dead code that should be removed for clarity.

**Edge case:** If the `if (order.getState() == ...)` condition is false (order is already in `RAW_ON_HOLD`), the entity has NOT been dirtied and doesn't need saving. The `save()` at line 219 would be a no-op merge in that case. Safe to remove.

---

### Fix #2 (MEDIUM): Pessimistic Lock on Customerorder in `finishPickingOrder`

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`

The v2 code at line 174 uses `findAllById(coOrderIds)` to bulk-load all customer orders. There is no `findAllByIdForUpdate` on `CustomerorderRepository`. The fix needs a v2-adapted approach.

**Option A (Recommended): Replace bulk load with individual pessimistic locks**

```java
// BEFORE (lines 171-174):
Set<Long> coOrderIds = new HashSet<>();
copMap.values().forEach(cop -> coOrderIds.add(cop.getOrderId()));
Map<Long, Customerorder> coMap = new HashMap<>();
customerorderRepository.findAllById(coOrderIds).forEach(co -> coMap.put(co.getId(), co));

// AFTER:
Set<Long> coOrderIds = new HashSet<>();
copMap.values().forEach(cop -> coOrderIds.add(cop.getOrderId()));
Map<Long, Customerorder> coMap = new HashMap<>();
for (Long coId : coOrderIds) {
    customerorderRepository.findByIdForUpdate(coId).ifPresent(co -> coMap.put(co.getId(), co));
}
```

**Why individual locks instead of bulk:**
- `findByIdForUpdate` already exists and uses `@Lock(PESSIMISTIC_WRITE)`
- Order count is typically small (1-3 orders per picking order) — no performance concern
- Locks are acquired within the same transaction — consistent ordering by ID would prevent deadlocks, but since the set is small and locks are brief, this is not a practical concern
- The primary caller path (`confirmPick()` → `finishPickingOrder()`) already holds a pessimistic lock on the Customerorder from line 485/530 — the `findByIdForUpdate` at this point returns the already-locked entity from the first-level cache (no extra round-trip)
- Secondary caller paths (admin controller, `MobilePickingService` direct calls) benefit from the lock

**Option B (Alternative): Add `findAllByIdForUpdate` to CustomerorderRepository**

```java
// In CustomerorderRepository.java:
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT c FROM Customerorder c WHERE c.id IN :ids")
List<Customerorder> findAllByIdForUpdate(@Param("ids") Collection<Long> ids);
```

Then use at line 174:
```java
customerorderRepository.findAllByIdForUpdate(coOrderIds).forEach(co -> coMap.put(co.getId(), co));
```

**Why Option A is preferred over B:** Option B requires adding a new repository method, and the `@Lock` annotation with `IN` clause has subtle behavior differences across JPA providers. Option A reuses the existing, proven `findByIdForUpdate` method with negligible performance impact.

---

## 4. Test Plan

### 4.1 `ReleaseOrderJobServiceUnitTest` — Update 27 `findById` mocks

**File:** `src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java`

All 27 occurrences of:
```java
when(customerorderRepository.findById(1L)).thenReturn(Optional.of(testOrder));
```
must be changed to:
```java
when(customerorderRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(testOrder));
```

The test logic remains identical — only the mock target changes.

### 4.2 `PickingorderBusinessServiceUnitTest` — Update `finishPickingOrder` tests

**File:** `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java`

Tests that invoke `finishPickingOrder` and mock customer order loading need to be updated to mock `findByIdForUpdate` instead of `findAllById` for the customer order loading path.

Specifically, tests at lines ~414, ~517, ~567, ~623, ~663, ~721, ~742, ~762, ~777, ~791, ~805, ~1599, ~1660 that set up customer order mocks for `finishPickingOrder` need adjustment.

**Identify the current mock pattern** — likely:
```java
when(customerorderRepository.findAllById(any())).thenReturn(List.of(testCustomerOrder));
```
**Change to:**
```java
when(customerorderRepository.findByIdForUpdate(testCustomerOrder.getId())).thenReturn(Optional.of(testCustomerOrder));
```

### 4.3 New test: Verify pessimistic lock is used in `releaseOrder`

Add to `ReleaseOrderJobServiceUnitTest`:

```java
@Test
@DisplayName("releaseOrder uses pessimistic lock (findByIdForUpdate) to load customer order")
void releaseOrderUsesPessimisticLock() throws FacadeException, BusinessException {
    // Setup: order in ASSIGNED state (early return path)
    testOrder.setState(WmsConstants.State.ASSIGNED);
    when(customerorderRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(testOrder));

    releaseOrderJobService.releaseOrder(1L, Map.of(), Map.of());

    // Verify findByIdForUpdate was called, NOT findById
    verify(customerorderRepository).findByIdForUpdate(1L);
    verify(customerorderRepository, never()).findById(1L);
}
```

### 4.4 New test: Verify pessimistic lock in `finishPickingOrder`

Add to `PickingorderBusinessServiceUnitTest`:

```java
@Test
@DisplayName("finishPickingOrder uses pessimistic lock for customer order loading")
void finishPickingOrderUsesPessimisticLock() throws FacadeException, BusinessException {
    // Setup minimal picking order with one position linked to a customer order
    // ... (standard test setup) ...

    pickingorderBusinessService.finishPickingOrder(testPickingOrder);

    // Verify findByIdForUpdate was called for the customer order
    verify(customerorderRepository).findByIdForUpdate(testCustomerOrder.getId());
    verify(customerorderRepository, never()).findAllById(any());
}
```

---

## 5. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| Pessimistic lock blocks concurrent UI operations on the same order | Brief wait (~100ms-2s) for UI users modifying the same order | Acceptable: order release operates on RAW orders not actively being used. Block is brief and better than failed release. |
| Deadlock between `releaseOrder` lock on Customerorder and `confirmPick` lock on same order | Potential deadlock if both transactions lock the same order | Extremely unlikely: `releaseOrder` targets RAW orders, `confirmPick` targets orders already in ASSIGNED state. These are mutually exclusive states. |
| `finishPickingOrder` individual locks instead of bulk load | Slightly more DB round-trips (1 per order instead of 1 bulk query) | Negligible: typically 1-3 orders per picking order. Primary caller path already has the lock cached. |
| Removing redundant save at line 219 | Edge case: if order was not dirtied by the `if` block, no save was needed anyway | Safe: if state didn't change, entity is clean and doesn't need saving. If state did change, save at line 214 already persisted it. |

---

## 6. Items NOT Included (Out of Scope)

| Item | Reason |
|:-----|:-------|
| `CustomerorderBatchService` club flow pessimistic lock | v2 has no stale-order re-fetch pattern in club flow — the v1 concern doesn't apply |
| `MobilePickingService` post-finish save | v2 does NOT modify/save pickingOrder after `finishPickingOrder()` calls — the v1 concern doesn't apply |
| `EntityManager.refresh()` approach | Proven insufficient in v1 — went straight to pessimistic lock |
| `Set<Customerorder>` → `Set<Long>` dedup in `finishPickingOrder` | Already fixed in v2 (lines 171-174 use `Set<Long>`) |

---

## 7. Task Checklist

- [x] **Fix #1** (HIGH): Change `findById` → `findByIdForUpdate` at line 105 of `ReleaseOrderJobService.java` ✓ Implemented 2026-04-01
- [x] **Fix #1b** (LOW): Remove redundant `customerorderRepository.save(order)` at line 219 of `ReleaseOrderJobService.java` ✓ Implemented 2026-04-01
- [x] **Fix #2** (MEDIUM): Replace `findAllById` with per-order `findByIdForUpdate` loop at lines 171-174 of `PickingorderBusinessService.java` ✓ Implemented 2026-04-01
- [x] **Tests**: Update 28 `findById` → `findByIdForUpdate` mocks in `ReleaseOrderJobServiceUnitTest.java` (27 mock setups + 1 verify) ✓ Implemented 2026-04-01
- [x] **Tests**: Update 7 `findAllById` → `findByIdForUpdate` test mocks in `PickingorderBusinessServiceUnitTest.java` for pessimistic lock ✓ Implemented 2026-04-01
- [x] **Tests**: Existing test `shouldReturnEmptyMapWhenOrderIsAlreadyAssigned` updated to verify `findByIdForUpdate` is called (serves as pessimistic lock verification) ✓ Implemented 2026-04-01
- [x] Run full test suite and verify 0 new failures ✓ 107 tests across 4 related classes pass (0 failures). Full suite: 3767 tests — same pre-existing failures as before changes (10 failures, 56 errors in unrelated tests: SequenceTransactionServiceUnitTest, StockunitBusinessServiceUnitTest, MobileReplenishServiceH2Test, repository tests). 0 new failures introduced.
- [ ] Verify in staging

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java` | `findById` → `findByIdForUpdate` (line 105), remove redundant `save()` (line 219) |
| `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | Replace `findAllById` bulk load with per-order `findByIdForUpdate` loop (lines 171-174) |
| `src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java` | 27x `findById` → `findByIdForUpdate` mocks, add pessimistic lock verification test |
| `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java` | Update `finishPickingOrder` test mocks, add pessimistic lock verification test |
