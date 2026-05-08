# Debug Plan: Replenish Job Stockunit Optimistic Lock Failure

**Date:** 2026-04-01
**Priority:** High
**Reporter:** Production log
**Status: IMPLEMENTED (2026-04-01)** — Fix applied, all 92 tests passing.

---

## 1. Problem Summary

The `ReplenishOrderJob` cron job fails with `ObjectOptimisticLockingFailureException` on `Stockunit#23513147` when calling `StockunitBusinessService.changeReservedAmount()`. The pessimistic lock (`findByIdForUpdate`) was added (SBDEV-1710) to prevent this exact scenario, but it doesn't work because Hibernate's first-level cache returns the stale entity instead of refreshing from the DB row that was just locked.

## 2. Root Cause Analysis

### Call Chain

```
ReplenishOrderJob.triggerRegularReplenishment()           [NO TX]
  └─ ReplenishOrderJobService.refillFixedLocationAssignment()  [@Transactional(REQUIRES_NEW)]
       └─ ReplenishGeneratorService.calculateOrder()           [NO @Transactional — joins parent TX]
            ├─ stockunitRepository.findById(id)                [line 118 — loads Stockunit v=N, NO LOCK]
            └─ stockUnitBusinessService.changeReservedAmount() [line 147]
                 ├─ stockunitRepository.findByIdForUpdate(id)  [line 314 — acquires DB lock, returns CACHED v=N]
                 └─ stockunitRepository.save(stockUnit)        [line 334 — FAILS: entity v=N != DB v=N+1]
```

### Why `findByIdForUpdate` Doesn't Prevent the Failure

The `findByIdForUpdate` method is defined as:

```java
// StockunitRepository.java:30-32
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT s FROM Stockunit s WHERE s.id = :id")
Optional<Stockunit> findByIdForUpdate(@Param("id") Long id);
```

This executes `SELECT ... FOR UPDATE` at the DB level — correctly acquiring a row lock. However, `changeReservedAmount()` has `@Transactional` with default `REQUIRED` propagation, so it **joins the parent transaction** (`refillFixedLocationAssignment`'s `REQUIRES_NEW`). Both methods share the **same persistence context**.

When `findByIdForUpdate(id)` is called, Hibernate sees the entity is already managed in the first-level cache (loaded at `ReplenishGeneratorService.java:118`) and returns the **cached copy with version=N** — even though the DB row now has version=N+1 (modified by a concurrent transaction between the two loads).

The parameter is already named `staleStockUnit`, showing awareness of the issue — but the fix (`findByIdForUpdate`) is insufficient because it cannot bypass the first-level cache within the same transaction.

### Race Condition Sequence

1. **T=0** — `calculateOrder()` loads `Stockunit#23513147` via `findById()` → version=N enters persistence context
2. **T=1** — A concurrent transaction (e.g., picking, mobile replenish) modifies the same Stockunit → DB version becomes N+1, commits
3. **T=2** — `changeReservedAmount()` calls `findByIdForUpdate()` → DB lock acquired, but Hibernate returns cached entity (version=N)
4. **T=3** — `save()` flushes → Hibernate's `@Version` check: entity version=N != DB version=N+1 → `StaleObjectStateException`

## 3. Reproduction Conditions

This occurs when:
- The replenish job runs while concurrent operations (picking, mobile replenish, order release) modify the same Stockunit
- Most likely during busy warehouse hours when cron jobs overlap with active picking/replenishment
- The `destination=null` in the log suggests a regular (non-destination-specific) replenishment, which queries broadly across stock

## 4. Proposed Fix

### Fix A: Refresh the entity after acquiring the pessimistic lock

**File:** `StockunitBusinessService.java:312-315`
**Current:** `findByIdForUpdate` returns the cached stale entity
**Change:** After acquiring the lock, use `entityManager.refresh()` to force Hibernate to reload the entity from the DB, overwriting the stale cached version.

```java
@Transactional
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount, boolean zeroIfNegative, String activityCode, String orderNumber, String comment) throws FacadeException {
    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
        .orElseThrow(() -> new FacadeException("STOCKUNIT_NOT_FOUND", String.valueOf(staleStockUnit.getId())));

    // Force refresh from DB to overwrite stale first-level cache entry
    entityManager.refresh(stockUnit);

    BigDecimal oldReservedAmount = stockUnit.getReservedamount();
    // ... rest unchanged
}
```

**Why this works:** `entityManager.refresh()` forces Hibernate to reload all fields (including `version`) from the DB row — which is now locked by `FOR UPDATE` — overwriting whatever was in the first-level cache. The subsequent `save()` will use the correct version.

**Prerequisite:** `StockunitBusinessService` needs `@PersistenceContext EntityManager entityManager;` injected. Check if it already has one.

### Fix B (Alternative): Detach the stale entity before re-fetching

If `entityManager` injection is undesirable, an alternative is to evict the stale entity from the persistence context before re-fetching:

```java
@Transactional
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount, boolean zeroIfNegative, String activityCode, String orderNumber, String comment) throws FacadeException {
    // Evict stale copy so findByIdForUpdate fetches fresh from DB
    entityManager.detach(staleStockUnit);

    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
        .orElseThrow(() -> new FacadeException("STOCKUNIT_NOT_FOUND", String.valueOf(staleStockUnit.getId())));

    BigDecimal oldReservedAmount = stockUnit.getReservedamount();
    // ... rest unchanged
}
```

**Why this works:** Detaching the stale entity removes it from the first-level cache. The subsequent `findByIdForUpdate` must then hit the DB, returning the entity with the current version. The `FOR UPDATE` lock prevents further concurrent modifications.

**Recommendation:** Fix A (`refresh` after lock) is safer — it preserves the lock guarantee and doesn't risk orphaning other references to the entity in the caller's scope.

## 5. Similar Risk Sites

All callers of `changeReservedAmount()` that load a Stockunit in an outer scope and pass it in are vulnerable to the same cache staleness issue, because `changeReservedAmount` joins the caller's transaction:

| File | Line | Method | Risk | Pattern |
|------|------|--------|------|---------|
| `ReplenishGeneratorService.java` | 147 | `calculateOrder()` | **HIGH** — this is the failing site | Loads at 118, passes at 147 |
| `ReplenishGeneratorService.java` | 157 | `reserveExplicitStockForOrder()` | **HIGH** | Caller loads stock externally |
| `ReplenishorderService.java` | 153, 170 | `redirectSource()` | **HIGH** | Loads sourceStock at ~146, passes to changeReservedAmount |
| `ReplenishmentOrderMaintenanceService.java` | 291 | `redirectSource()` | **HIGH** | Loads targetStock at ~277 |
| `ReplenishmentOrderMaintenanceService.java` | 348 | `updateRequestedAmount()` | **MEDIUM** | Loads source earlier in same method |
| `ReleaseOrderJobService.java` | 473, 494, 518, 526 | `createPickingPositions()` | **HIGH** | Loads Stockunit in loop, multiple calls |
| `MobileReplenishService.java` | 281, 288 | `switchReplenishStock()` | **HIGH** | Loads old/new stock, calls twice |
| `MobileReplenishService.java` | 420, 424, 426 | `cancelReplenishment()` | **MEDIUM** | Multiple releases |
| `MobileReplenishService.java` | 857 | `completeReplenishment()` | **MEDIUM** | Releases on completion |
| `CustomerorderPositionService.java` | 133 | `cancelOrderPosition()` | **LOW** | Short-lived, less contention |
| `CustomerorderService.java` | 238, 290 | `setPickingDate()`, `cancelOrder()` | **LOW** | User-initiated, less concurrent |
| `PickingorderPositionService.java` | 128, 140 | `fixPickingPosition()` | **MEDIUM** | Unreserves + reserves pair |
| `PickingorderBusinessService.java` | 259 | `forceCancelOrder()` | **LOW** | Force cancel, less concurrent |

**However:** The fix in `changeReservedAmount` itself (Fix A: `entityManager.refresh()`) protects **all** callers automatically, because the refresh happens inside the method regardless of who calls it. This is the correct fix location — a single change that covers all 23 call sites.

## 6. Risks & Side Effects

- **Risk:** `entityManager.refresh()` issues an extra SELECT — minor performance cost per call
  - **Mitigation:** The entity is already locked (`FOR UPDATE`), so the refresh just re-reads the locked row. No additional round-trip beyond what the lock already does. Negligible overhead.
- **Risk:** If the stale entity was modified in the caller before passing to `changeReservedAmount`, those modifications would be lost by `refresh`
  - **Mitigation:** The parameter is already named `staleStockUnit` and the method only uses `staleStockUnit.getId()` to look up the fresh copy. Callers should not rely on the passed-in object being modified.
- **Regression areas to test:**
  - Replenish order creation (the failing path)
  - Order release job (`ReleaseOrderJobService.createPickingPositions`)
  - Mobile replenish (switch stock, cancel, complete)
  - Order cancellation reserved amount release
  - Picking position fix

## 7. Task Checklist

- [x] Inject `EntityManager` into `StockunitBusinessService` via `@PersistenceContext` **(Critical)**
- [x] Add `entityManager.refresh(stockUnit)` after `findByIdForUpdate` in `changeReservedAmount()` **(Critical)**
- [x] Add unit test: `changeReservedAmount_refreshesEntityAfterPessimisticLock` verifies `entityManager.refresh()` is called **(High)**
- [x] Verify existing `StockunitBusinessService` tests still pass — 25/25 pass **(High)**
- [x] Run all affected test classes — 92/92 pass (StockunitBusinessServiceUnitTest + CustomerorderPositionServiceUnitTest + CustomerorderServiceUnitTest) **(High)**
- [ ] Monitor production logs after deploy for reduction in optimistic lock warnings in `ReplenishOrderJob` **(Medium)**
