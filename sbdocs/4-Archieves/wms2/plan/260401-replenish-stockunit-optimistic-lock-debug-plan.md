# Debug Plan: Replenish Job Stockunit Optimistic Lock Failure (v2 Migration)

**Date:** 2026-04-01
**Priority:** High
**Source:** v1 plan `docs/plan/v1-fixes/260401-replenish-stockunit-optimistic-lock-debug-plan.md` (implemented on `release-260327` branch of `wms-api`)
**Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## 1. Problem Summary

`StockunitBusinessService.changeReservedAmount()` uses `findByIdForUpdate()` to acquire a pessimistic lock before modifying a Stockunit's reserved amount. However, when the caller has already loaded the same Stockunit within the same transaction (shared persistence context), Hibernate's first-level cache returns the **stale cached entity** instead of refreshing from the locked DB row. If a concurrent transaction modified the Stockunit between the initial load and the `findByIdForUpdate` call, the version is stale, and the subsequent `save()` fails with `ObjectOptimisticLockingFailureException`.

The same issue exists in `changeAmount()` which follows the identical pattern.

## 2. Applicability Analysis

| v1 Fix | v2 Status | Applicable? |
|:-------|:----------|:------------|
| **Inject `EntityManager` into `StockunitBusinessService`** | **NOT injected.** No `EntityManager` field, no `@PersistenceContext` | **YES — needed** |
| **Add `entityManager.refresh(stockUnit)` after `findByIdForUpdate` in `changeReservedAmount()`** | **NOT present.** Line 386-387 acquires lock but no refresh | **YES — needed** |
| **Unit test verifying `refresh()` is called** | **NOT present.** No EntityManager mock in test file | **YES — needed** |

### Why the fix is valid in v2

The v2 `StockunitBusinessService` has the **identical structural problem** as v1:

1. **`changeReservedAmount()` (lines 384-409):** Uses `@Transactional(value = "tenantTransactionManager", ...)` with default `REQUIRED` propagation — joins the caller's transaction. Calls `findByIdForUpdate(staleStockUnit.getId())` at line 386, but Hibernate returns the cached entity from the first-level cache (loaded by the caller) instead of refreshing from the locked DB row.

2. **`changeAmount()` (lines 349-378):** Same pattern — `findByIdForUpdate(staleStockUnit.getId())` at line 352, no refresh. Same vulnerability.

3. **The parameter is already named `staleStockUnit`** in both methods — showing awareness that the passed-in entity may be stale, but the fix (`findByIdForUpdate`) is insufficient because it cannot bypass the first-level cache within the same transaction.

### v2-specific call sites at risk

All callers that load a Stockunit in an outer transaction scope and then pass it to `changeReservedAmount()` are vulnerable. The fix inside `changeReservedAmount`/`changeAmount` protects **all callers automatically**:

| File | Lines | Method | Calls |
|:-----|:------|:-------|:------|
| `ReplenishGeneratorService.java` | 194, 204 | `calculateOrder()`, `reserveExplicitStockForOrder()` | `changeReservedAmount` |
| `ReplenishorderService.java` | 178, 195, 217 | `redirectSource()`, `cancelReplenishmentOrder()` | `changeReservedAmount` |
| `ReplenishmentOrderMaintenanceService.java` | 301, 358, 381 | `redirectSource()`, `updateRequestedAmount()`, `releaseReservation()` | `changeReservedAmount` |
| `ReleaseOrderJobService.java` | 504, 527, 551, 559 | Stock reservation during picking position creation | `changeReservedAmount` |
| `MobileReplenishService.java` | 328, 335, 467, 471, 473, 916 | `switchReplenishStock()`, `cancelReplenishment()`, `completeReplenishment()` | `changeReservedAmount` |
| `PickingorderBusinessService.java` | 417 | `confirmPick()` | `changeReservedAmount` |
| `CustomerorderService.java` | 265, 332 | `setPickingDate()`, `cancelOrder()` | `changeReservedAmount` |
| `CustomerorderPositionService.java` | 129 | `cancelOrderPosition()` | `changeReservedAmount` |
| `PickingorderPositionService.java` | 149, 167 | `fixPickingPosition()` | `changeReservedAmount` |
| `CustomerorderBatchService.java` | 309 | batch cancel | `changeReservedAmount` |
| `StockunitService.java` | 452 | manual adjustment | `changeAmount` |

---

## 3. Implementation Plan

### Fix A: Inject `EntityManager` into `StockunitBusinessService`

**File:** `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java`

**Add import and field:**

```java
// Add import (after existing imports):
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;

// Add field (after the existing private fields, before the constructor):
@PersistenceContext(unitName = "tenant")
private EntityManager entityManager;
```

**Why `unitName = "tenant"`:** The v2 codebase has dual persistence units (`landlord` and `tenant`). `StockunitBusinessService` operates on tenant data, so it must use the `tenant` persistence unit's EntityManager. This matches the `tenantTransactionManager` used in the `@Transactional` annotations.

### Fix B: Add `entityManager.refresh()` in `changeReservedAmount()`

**File:** `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java`

**Change lines 385-388:**

```java
// BEFORE (lines 385-388):
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount, boolean zeroIfNegative, String activityCode, String orderNumber, String comment) throws FacadeException {
    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
        .orElseThrow(() -> new FacadeException("STOCKUNIT_NOT_FOUND", String.valueOf(staleStockUnit.getId())));

    BigDecimal oldReservedAmount = stockUnit.getReservedamount();

// AFTER:
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount, boolean zeroIfNegative, String activityCode, String orderNumber, String comment) throws FacadeException {
    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
        .orElseThrow(() -> new FacadeException("STOCKUNIT_NOT_FOUND", String.valueOf(staleStockUnit.getId())));

    // Force refresh from DB to overwrite stale first-level cache entry
    entityManager.refresh(stockUnit);

    BigDecimal oldReservedAmount = stockUnit.getReservedamount();
```

**Why:** `entityManager.refresh()` forces Hibernate to reload all fields (including `@Version`) from the DB row — which is now locked by `FOR UPDATE` — overwriting the stale cached entry. The subsequent `save()` will use the correct version.

### Fix C: Add `entityManager.refresh()` in `changeAmount()`

**File:** `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java`

**Change lines 350-354:**

```java
// BEFORE (lines 350-354):
public Stockunit changeAmount(Stockunit staleStockUnit, BigDecimal amount, String activityCode, String orderNumber, String comment) throws FacadeException {
    // Re-fetch with pessimistic lock to prevent concurrent modification
    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
        .orElseThrow(() -> new FacadeException("Stockunit not found", String.valueOf(staleStockUnit.getId())));

    BigDecimal amountOld = stockUnit.getAmount();

// AFTER:
public Stockunit changeAmount(Stockunit staleStockUnit, BigDecimal amount, String activityCode, String orderNumber, String comment) throws FacadeException {
    // Re-fetch with pessimistic lock to prevent concurrent modification
    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
        .orElseThrow(() -> new FacadeException("Stockunit not found", String.valueOf(staleStockUnit.getId())));

    // Force refresh from DB to overwrite stale first-level cache entry
    entityManager.refresh(stockUnit);

    BigDecimal amountOld = stockUnit.getAmount();
```

**Why:** Same pattern as `changeReservedAmount()`. Although `changeAmount()` is called less frequently (primarily from `StockunitService.adjustStockManually()`), it has the same vulnerability and should be protected consistently.

---

## 4. Test Plan

### 4.1 Add `EntityManager` mock to `StockunitBusinessServiceUnitTest`

**File:** `src/test/java/net/aim_ai/wms/unit/service/StockunitBusinessServiceUnitTest.java`

Add mock field:
```java
@Mock
private EntityManager entityManager;
```

Add import:
```java
import jakarta.persistence.EntityManager;
```

**Note:** Since `StockunitBusinessService` uses `@PersistenceContext` (field injection) rather than constructor injection, Mockito's `@InjectMocks` will inject the `@Mock EntityManager` via field reflection automatically.

### 4.2 New test: Verify `refresh()` is called in `changeReservedAmount`

Add to `StockunitBusinessServiceUnitTest`:

```java
@Test
@DisplayName("changeReservedAmount refreshes entity after pessimistic lock to prevent stale cache")
void changeReservedAmount_refreshesEntityAfterPessimisticLock() throws FacadeException {
    Stockunit staleStock = new Stockunit();
    staleStock.setId(1L);

    Stockunit freshStock = new Stockunit();
    freshStock.setId(1L);
    freshStock.setAmount(new BigDecimal("100"));
    freshStock.setReservedamount(BigDecimal.ZERO);

    when(stockunitRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(freshStock));

    stockunitBusinessService.changeReservedAmount(staleStock, BigDecimal.TEN, false, "TEST", "ORD-1", null);

    // Verify refresh was called to overwrite stale L1 cache
    verify(entityManager).refresh(freshStock);
}
```

### 4.3 New test: Verify `refresh()` is called in `changeAmount`

```java
@Test
@DisplayName("changeAmount refreshes entity after pessimistic lock to prevent stale cache")
void changeAmount_refreshesEntityAfterPessimisticLock() throws FacadeException {
    Stockunit staleStock = new Stockunit();
    staleStock.setId(1L);

    Stockunit freshStock = new Stockunit();
    freshStock.setId(1L);
    freshStock.setAmount(new BigDecimal("50"));
    freshStock.setReservedamount(BigDecimal.ZERO);

    when(stockunitRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(freshStock));

    stockunitBusinessService.changeAmount(staleStock, new BigDecimal("60"), "TEST", "ORD-1", null);

    // Verify refresh was called to overwrite stale L1 cache
    verify(entityManager).refresh(freshStock);
}
```

### 4.4 Update existing tests

Existing `changeReservedAmount` and `changeAmount` tests should continue to pass without changes because:
- `@Mock EntityManager entityManager` is injected but `refresh()` is a void method that does nothing by default on a mock
- The existing test stubs (`findByIdForUpdate` returning a test stockunit) still work — the `refresh()` call is a no-op on the mock

However, verify all existing tests pass after adding the mock.

---

## 5. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| `entityManager.refresh()` issues an extra SELECT per call | Minor performance cost | The entity is already locked (`FOR UPDATE`), so the refresh just re-reads the locked row. Negligible overhead. |
| If caller modified the stale entity before passing to `changeReservedAmount`, those modifications are lost by `refresh` | None in practice | The parameter is named `staleStockUnit` and both methods only use `staleStockUnit.getId()` to look up the fresh copy. No caller relies on the passed-in object being returned. |
| `@PersistenceContext(unitName = "tenant")` — wrong unit name would inject landlord EM | Would cause silent data access to wrong DB | Use `unitName = "tenant"` to match the `tenantTransactionManager` used in `@Transactional` annotations. Verify by checking `TenantDatabaseConfig.java` for the persistence unit name. |

---

## 6. Task Checklist

- [x] **Fix A**: Inject `EntityManager` into `StockunitBusinessService` via `@PersistenceContext(unitName = "tenant")` — (Critical) ✓ Implemented 2026-04-01
- [x] **Fix B**: Add `entityManager.refresh(stockUnit)` after `findByIdForUpdate` in `changeReservedAmount()` — (Critical) ✓ Implemented 2026-04-01
- [x] **Fix C**: Add `entityManager.refresh(stockUnit)` after `findByIdForUpdate` in `changeAmount()` — (High) ✓ Implemented 2026-04-01
- [x] **Tests**: Add `@Mock EntityManager entityManager` + `ReflectionTestUtils.setField` to `StockunitBusinessServiceUnitTest` — (High) ✓ Implemented 2026-04-01
- [x] **Tests**: Add `changeReservedAmount_refreshesEntityAfterPessimisticLock` test — (High) ✓ Implemented 2026-04-01
- [x] **Tests**: Add `changeAmount_refreshesEntityAfterPessimisticLock` test — (High) ✓ Implemented 2026-04-01
- [x] Run all affected test classes and verify 0 new failures ✓ 2 new tests pass. 4 ChangeReservedAmount tests pass, 3 EdgeCases reserved-amount tests pass (previously NPE, now fixed). 139 tests across related classes (ReplenishmentOrderMaintenanceServiceUnitTest, ReplenishOrderJobTest, StockunitServiceUnitTest) pass with 0 failures. Pre-existing ChangeAmount test failures (Facade Stockunit not found) are unrelated.
- [ ] Verify in staging — monitor production logs for reduction in optimistic lock warnings in `ReplenishOrderJob`

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` | Inject `EntityManager`, add `refresh()` after `findByIdForUpdate` in both `changeReservedAmount()` and `changeAmount()` |
| `src/test/java/net/aim_ai/wms/unit/service/StockunitBusinessServiceUnitTest.java` | Add `@Mock EntityManager`, add 2 new tests verifying `refresh()` is called |

### Verification Note

Before implementing, verify the correct persistence unit name by checking:
```
src/main/java/net/aim_ai/wms/landlord/config/TenantDatabaseConfig.java
```
Look for the `@PersistenceUnit` or `LocalContainerEntityManagerFactoryBean` bean name that corresponds to `tenantTransactionManager`. The unit name in `@PersistenceContext` must match.
