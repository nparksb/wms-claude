# Debug Plan: Recalculate Orders Stale Entity Optimistic Lock (v2 Migration)

**Date:** 2026-04-01
**Priority:** Medium
**Source:** v1 plan `docs/plan/v1-fixes/260331-recalculate-orders-stale-entity-debug-plan.md` (implemented on `release-260327` branch of `wms-api`)
**Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## 1. Applicability Analysis

The v1 plan addressed three issues in `ReplenishmentOrderMaintenanceService`:

| v1 Fix | v2 Status | Applicable? |
|:-------|:----------|:------------|
| **Fix A-1:** Remove `@Transactional` from `recalculateOpenOrders(boolean)` | **Still present** at line 73 — `@Transactional(value = "tenantTransactionManager", ...)` | **YES — needed** |
| **Fix A-2:** Remove `@Transactional` from `recalculateForItem(Long)` | **Still present** at line 96 — `@Transactional(value = "tenantTransactionManager", ...)` | **YES — needed** |
| **Fix B:** Re-fetch order by ID at start of `recalculateOrder()` | **Not implemented** — line 124 still operates on batch-loaded entity directly | **YES — needed** |

### Why all three fixes are still valid in v2

The v2 `ReplenishmentOrderMaintenanceService` has the **identical structural problems** as v1:

1. **Self-invocation bypass (lines 69-71):** `recalculateOpenOrders()` calls `this.recalculateOpenOrders(false)` — Spring proxy is bypassed, so the `@Transactional` on line 73 never triggers. This is unchanged from v1.

2. **Poison transaction on `recalculateForItem` (line 96):** This `@Transactional` IS active when called through the proxy (from `StockunitService.triggerReplenishmentMaintenance()` at line 123 and `FixLocationAssignmentService.triggerReplenishmentMaintenance()` at line 286). If one order's `save()` hits an optimistic lock exception, the catch at line 112 catches it, but the transaction is already marked rollback-only — subsequent iterations silently fail with `UnexpectedRollbackException`.

3. **Stale batch-loaded entities (line 124):** `recalculateOrder(order, ctx)` operates on entities loaded at batch time (lines 79 and 102). By the time `updateRequestedAmount()` calls `save()` at line 364, the entity's `@Version` may be stale from concurrent modifications.

### v2-specific considerations

- **v2 uses `tenantTransactionManager` correctly** — the `@Transactional` annotations already specify `value = "tenantTransactionManager"`. The removal of `@Transactional` itself is what we need, not a TM correction.
- **v2 has `RecalcContext` bulk loading (lines 461-504)** — the v1 plan's Fix B (re-fetch by ID) is still valid because `RecalcContext` pre-loads stock units and unit loads, but does NOT re-fetch the `Replenishorder` entity itself before mutation. The order entity is the one going stale.
- **v2 also has a single-arg `recalculateOrder(Replenishorder)` at line 119-122** — this has its own `@Transactional` annotation. Since it delegates to the two-arg version, the re-fetch in Fix B will cover it. However, the `@Transactional` here should also be removed for consistency (called internally or from tests).
- **`updateReplenishmentOrderPriority` in v2 uses bulk SQL** — `ReplenishorderService` lines 226-248 now use `bulkUpdatePriorityForItems` and `bulkUpdatePriorityForItemsWithOldPriority` (native UPDATE queries) instead of the entity-by-entity save loop from v1. **This means v1 hotspot §8.2 is already resolved in v2 and does NOT need a fix.**
- **`recalculateReplenishmentOrderWithoutFixedLocationAssignment` (v1 hotspot §8.1)** — still present at `ReplenishorderService` lines 250-272 with the same entity-by-entity save-in-loop pattern, no per-order try-catch. This remains a valid concern but is lower priority.

---

## 2. Implementation Plan

### Fix A: Remove `@Transactional` from recalculation loop methods

**File:** `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java`

#### A-1: Remove `@Transactional` from `recalculateOpenOrders(boolean)` (line 73)

```java
// BEFORE (line 73-74):
@Transactional(value = "tenantTransactionManager", rollbackFor = {net.aim_ai.wms.exceptions.BusinessException.class, FacadeException.class})
public void recalculateOpenOrders(boolean force) {

// AFTER:
public void recalculateOpenOrders(boolean force) {
```

**Why:** (1) Never triggers due to self-invocation from no-arg overload at line 69. (2) If it did trigger (e.g., future caller through proxy), it would be harmful — one failed `save()` marks the transaction rollback-only, and all subsequent `save()` calls fail with `UnexpectedRollbackException` despite the catch block. Without `@Transactional`, each `replenishorderRepository.save()` gets its own auto-committed transaction, and failures are isolated per-order.

#### A-2: Remove `@Transactional` from `recalculateOpenOrders()` (no-arg, line 68)

```java
// BEFORE (line 68-69):
@Transactional(value = "tenantTransactionManager", rollbackFor = {net.aim_ai.wms.exceptions.BusinessException.class, FacadeException.class})
public void recalculateOpenOrders() {

// AFTER:
public void recalculateOpenOrders() {
```

**Why:** Consistency with A-1. This method only delegates to the boolean overload. Its `@Transactional` suffers the same self-invocation bypass and poison-transaction risks.

#### A-3: Remove `@Transactional` from `recalculateForItem(Long)` (line 96)

```java
// BEFORE (line 96-97):
@Transactional(value = "tenantTransactionManager", rollbackFor = {net.aim_ai.wms.exceptions.BusinessException.class, FacadeException.class})
public void recalculateForItem(Long itemDataId) {

// AFTER:
public void recalculateForItem(Long itemDataId) {
```

**Why:** This `@Transactional` IS active in production (callers `StockunitService` line 123 and `FixLocationAssignmentService` line 286 invoke through the proxy). Same poison-transaction problem: if one order's `save()` hits optimistic lock, the catch at line 112 catches the exception, but the transaction is rollback-only — subsequent iterations silently fail. Removing it gives each `save()` its own transaction with isolated failures. Both callers already wrap the call in their own try-catch.

#### A-4: Remove `@Transactional` from `recalculateOrder(Replenishorder)` (line 119)

```java
// BEFORE (line 119-120):
@Transactional(value = "tenantTransactionManager", rollbackFor = {net.aim_ai.wms.exceptions.BusinessException.class, FacadeException.class})
void recalculateOrder(Replenishorder order) {

// AFTER:
void recalculateOrder(Replenishorder order) {
```

**Why:** Consistency. This single-arg overload delegates to the two-arg version. Its `@Transactional` would only trigger if called from another bean (currently no external callers in production). Removing prevents the same poison-transaction risk if a future caller appears.

#### A-5: Clean up unused import

After removing all `@Transactional` annotations from this class, the `org.springframework.transaction.annotation.Transactional` import (line 32) becomes unused. Remove it.

---

### Fix B: Re-fetch each order by ID to reduce staleness

**File:** `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java`

**Change `recalculateOrder(Replenishorder order, RecalcContext ctx)` at line 124:**

```java
// BEFORE (line 124-127):
void recalculateOrder(Replenishorder order, RecalcContext ctx) {
    if (order == null || !Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) {
        return;
    }

// AFTER:
void recalculateOrder(Replenishorder order, RecalcContext ctx) {
    if (order == null) {
        return;
    }
    // Re-fetch to get latest version and avoid stale-entity optimistic lock failures
    order = replenishorderRepository.findById(order.getId()).orElse(null);
    if (order == null || !Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) {
        return;
    }
```

**Why:** Reduces the staleness window from "entire batch iteration time" to "single order processing time". The batch query at lines 79/102 becomes just an ID collector. Each order gets the latest `@Version` before mutation, drastically reducing optimistic lock conflicts. Benefits both `recalculateOpenOrders` (many orders) and `recalculateForItem` (few orders).

---

## 3. Test Plan

### 3.1 Existing test updates

**File:** `src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java`

All tests that invoke `recalculateOrder` (directly or through `recalculateOpenOrders`/`recalculateForItem`) must now stub `replenishorderRepository.findById(order.getId())` to return the re-fetched order, because Fix B adds a `findById` call at the top of `recalculateOrder`.

**Add a helper method:**

```java
/** Stubs the re-fetch that recalculateOrder() now performs at the start. */
private void mockRefetch(Replenishorder order) {
    when(replenishorderRepository.findById(order.getId())).thenReturn(Optional.of(order));
}
```

**Update the following tests** (add `mockRefetch(order)` before calling the service method):

| Test class | Test method | Orders to mock |
|:-----------|:-----------|:---------------|
| `RecalculateOpenOrders` | `continuesOnExceptionInSingleOrder` | `order1`, `order2` |
| `RecalculateOpenOrders` | `skipsManuallyOverriddenOrders` | `order` |
| `RecalculateForItem` | `processesOnlyMatchingItemOrders` | `matchingOrder` |
| `RecalculateForItem` | `skipsManuallyOverriddenForItem` | `order` |
| `RecalculateOrder` | `cancelsOrderWhenShortageAtOrBelowThreshold` | `order` |
| `RecalculateOrder` | `cancelsOrderWhenDesiredAmountIsZero` | `order` |
| `RecalculateOrder` | `updatesRequestedAmountWhenDiffers` | `order` |
| All other `RecalculateOrder` tests that call through `recalculateForItem` or `recalculateOpenOrders` | Each order used | Each order |

**Note:** Tests that already stub `replenishorderRepository.findById(...)` for the same ID (e.g., for source redirection) need their existing stub adjusted to also cover the order re-fetch, or the mock should be set up to return the correct object for the order ID specifically.

### 3.2 New tests to add

**File:** `src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java`

Add these inside the `RecalculateOrder` nested class:

#### Test 1: Order deleted between batch load and re-fetch

```java
@Test
@DisplayName("skips order that was deleted between batch load and re-fetch")
void orderDeletedBeforeRecalculation_skips() {
    stubSyspropsNoCadenceNoThreshold();

    Replenishorder order = buildProcessableOrder(1L, 10L, 20L, 30L, 40L, BigDecimal.TEN);

    when(replenishorderRepository.findByStateAndItemdataId(WmsConstants.State.PROCESSABLE, 10L))
            .thenReturn(List.of(order));

    // Re-fetch returns empty — order was deleted concurrently
    when(replenishorderRepository.findById(1L)).thenReturn(Optional.empty());

    service.recalculateForItem(10L);

    // No save, no stock operations — just skipped
    verify(replenishorderRepository, never()).save(any());
    verify(stockunitRepository, never()).findById(anyLong());
}
```

#### Test 2: Order state changed between batch load and re-fetch

```java
@Test
@DisplayName("skips order whose state changed to non-PROCESSABLE between batch load and re-fetch")
void orderNoLongerProcessableOnRefetch_skips() {
    stubSyspropsNoCadenceNoThreshold();

    Replenishorder order = buildProcessableOrder(1L, 10L, 20L, 30L, 40L, BigDecimal.TEN);

    when(replenishorderRepository.findByStateAndItemdataId(WmsConstants.State.PROCESSABLE, 10L))
            .thenReturn(List.of(order));

    // Re-fetch returns the order but with state=STARTED (no longer PROCESSABLE)
    Replenishorder staleOrder = buildProcessableOrder(1L, 10L, 20L, 30L, 40L, BigDecimal.TEN);
    staleOrder.setState(WmsConstants.State.STARTED);
    when(replenishorderRepository.findById(1L)).thenReturn(Optional.of(staleOrder));

    service.recalculateForItem(10L);

    // No save, no stock operations — state guard tripped
    verify(replenishorderRepository, never()).save(any());
    verify(stockunitRepository, never()).findById(anyLong());
}
```

---

## 4. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| Re-fetching adds one extra SELECT per order | Minor DB load increase | Negligible — one SELECT per order vs. multiple native queries already executed per order in `recalculateOrder` |
| Race condition still possible between re-fetch and save | Occasional optimistic lock exception | Already handled by existing try-catch — just reduces frequency dramatically |
| Removing `@Transactional` from all four methods changes session management | Each repo call gets its own mini-transaction | For `recalculateOpenOrders(boolean)`: already the actual behavior (annotation never triggered). For `recalculateForItem`: real change but **improves** per-order failure isolation. Both callers treat it as best-effort fire-and-forget. |
| `findById` in `recalculateOrder` may conflict with existing `findById` stubs in tests | Test failures until stubs are updated | Addressed in test plan §3.1 — add `mockRefetch()` helper |

---

## 5. Related Hotspots (Informational — NOT part of this plan)

### 5.1 `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment()` (lines 250-272)

- **Pattern:** Batch-loads orders at line 255, iterates with `save()` at line 267, **no per-order try-catch**
- **Transaction:** Participates in caller's `REQUIRES_NEW` from `ReplenishOrderJobService`
- **Risk:** One stale entity rolls back the entire batch
- **Status:** Same as v1 — not yet addressed. Lower priority since this method only sets `destinationId` on orders without a fixed location (narrow scope).
- **Recommendation:** Future plan — add per-order try-catch and re-fetch by ID.

### 5.2 `updateReplenishmentOrderPriority` — RESOLVED in v2

The v1 plan flagged `ReplenishorderService.updateReplenishmentOrderPriority(List<Itemdata>...)` as a concurrency hotspot (entity-by-entity save in loop). **v2 has already resolved this** by switching to bulk native UPDATE queries (`bulkUpdatePriorityForItems` at line 230, `bulkUpdatePriorityForItemsWithOldPriority` at line 246). No action needed.

### 5.3 Integration test gap

The current unit tests instantiate the service directly via `@InjectMocks`, so they do **not** exercise Spring proxy behavior, self-invocation bypass, or real transaction commit/rollback-only state. A Spring-backed integration test that proves the real behavior under optimistic lock failure would be valuable but is out of scope for this plan.

---

## 6. Task Checklist

- [x] **Fix A-1**: Remove `@Transactional` from `recalculateOpenOrders(boolean)` — (High) ✓ Implemented 2026-04-01
- [x] **Fix A-2**: Remove `@Transactional` from `recalculateOpenOrders()` (no-arg) — (High) ✓ Implemented 2026-04-01
- [x] **Fix A-3**: Remove `@Transactional` from `recalculateForItem(Long)` — (High) ✓ Implemented 2026-04-01
- [x] **Fix A-4**: Remove `@Transactional` from `recalculateOrder(Replenishorder)` — (Medium) ✓ Implemented 2026-04-01
- [x] **Fix A-5**: Remove unused `Transactional` import — (Low) ✓ Implemented 2026-04-01
- [x] **Fix B**: Re-fetch order by ID at start of `recalculateOrder()` — (Medium) ✓ Implemented 2026-04-01
- [x] **Tests**: Add `mockRefetch()` helper and update 21 existing tests — (High) ✓ Implemented 2026-04-01
- [x] **Tests**: Add `orderDeletedBeforeRecalculation_skips` test — (Medium) ✓ Implemented 2026-04-01
- [x] **Tests**: Add `orderNoLongerProcessableOnRefetch_skips` test — (Medium) ✓ Implemented 2026-04-01
- [x] Run full test suite and verify 0 new failures ✓ 35 tests in ReplenishmentOrderMaintenanceServiceUnitTest pass (0 failures), 169 tests across all related classes pass (0 failures). Pre-existing failures in SequenceTransactionServiceUnitTest, StockunitBusinessServiceUnitTest, MobileReplenishServiceH2Test are unrelated.
- [ ] Verify in staging

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` | Remove `@Transactional` from 4 methods, remove unused import, add re-fetch in `recalculateOrder()` |
| `src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | Add `mockRefetch()` helper, update all existing recalculation tests, add 2 new tests |
