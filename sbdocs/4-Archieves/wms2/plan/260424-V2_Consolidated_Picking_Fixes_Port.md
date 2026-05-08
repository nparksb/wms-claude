# V2 Consolidated Porting Plan — Picking Fixes

- **Date:** 2026-03-21 (Updated: 2026-03-21 — V2 implementation complete)
- **Status:** V2 Implemented — All 17 fixes applied (10 ported + 7 new), 8 new tests added, all unit tests pass (37 pre-existing H2/integration context errors unrelated)
- **Priority:** Critical
- **V1 Source Plans:**
  - `docs/plan/260424-Tote_Pickingorder_Disconnect_Fix.md` (4 bugs, prefix: TD)
  - `docs/plan/Merge_Race_Condition_Fix.md` (13 fixes, prefix: RC)
- **V2 Target:** `wms2-api` repository

---

## Summary

17 V1 fixes were analyzed against the V2 codebase. After deep code analysis:
- **7 already exist in V2** (mostly `@Transactional` and some `findByIdForUpdate`)
- **10 confirmed still needed** (all validated with exact v2 line numbers)
- **6 NEW issues discovered** during deep analysis (missing `@Transactional`, stock unit race, stale reads, NPE risks)

V2 has significant architectural differences: multi-tenant `tenantTransactionManager`, constructor injection, extracted `PickingOrderMergeService`, bulk JPQL `assignToteToAllPositions`, Spring Boot 3+ with Jakarta EE namespace, and `orElseThrow(EntityNotFoundException)` patterns.

---

## V2-Specific Adaptation Notes

These apply to ALL ported code:

1. **Transaction manager:** `@Transactional(value = "tenantTransactionManager", ...)` — never bare `@Transactional`
2. **Jakarta vs javax:** Lock timeout property is `jakarta.persistence.lock.timeout`, not `javax.persistence.lock.timeout`
3. **`orElseThrow` pattern:** Use `.orElseThrow(() -> new EntityNotFoundException(...))` instead of `.get()`
4. **SLF4J parameterized logging:** `LOG.debug("message={}", var)` — not string concatenation
5. **Constructor injection:** Add new dependencies as constructor parameters, not `@Autowired` fields
6. **Extracted merge service:** Merge logic is in `PickingOrderMergeService`, not `ReplenishOrderJob`

---

## Changes by File

### 1. `MobilePickingService.java`

**V2 path:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| RC-1 | `@Transactional` on 5 methods | 146,165,210,619,663 | Already done | None | -- |
| RC-3 | `findByIdForUpdate` in selectAndReservePickingOrder | 150 | Already done | None | -- |
| **RC-6** | `findByIdForUpdate` in processPick | **388** | **Confirmed missing** | Change `findById` to `findByIdForUpdate` | Medium |
| **RC-9** | `findByIdForUpdate` in getPickingOrderPositionsInfo | **667** | **Confirmed missing** | Change `findById` to `findByIdForUpdate` | Medium |
| **TD-4** | Tote reuse when old order finished picking | **429-434** | **Confirmed missing** | Replace unconditional throw with state check | High |
| **TD-1** | Filter tote assignment by current pickingorderId | **487** | **Confirmed data corruption bug** | Modify `assignToteToAllPositions` JPQL | Critical |
| **NEW-1** | Missing state guard in processPick | **388+** | **New finding** | Add upper-bound state check after re-read | Low |

#### RC-6 Detail

**Current code (line 388):**
```java
pickingOrder = pickingorderRepository.findById(pickingOrderId)
    .orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingOrderId));
```

**Fix:** Single-line change — replace `findById` with `findByIdForUpdate`. The method already exists in `PickingorderRepository.java:21-23`.

**Why:** Two concurrent pickers processing positions on the same picking order can race on state transitions and tote assignment. The comment at lines 384-386 acknowledges the detached-entity problem but doesn't address concurrent-access.

---

#### RC-9 Detail

**Current code (line 667):**
```java
Pickingorder pickingOrder = pickingorderRepository.findById(pickingOrderID)
    .orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingOrderID));
```

**Fix:** Single-line change — replace `findById` with `findByIdForUpdate`.

**Why:** This method conditionally calls `startPickingOrder` at line 675. Without the lock, two users could both read the order in `< STARTED` state and both attempt `startPickingOrder`, causing duplicate state transitions.

---

#### TD-4 Detail

**Current code (lines 429-434):**
```java
Optional<Customerorder> possibleOldCustomerOrderOpt = customerorderRepository.getOrderByToteLabelId(toteName);

if (possibleOldCustomerOrderOpt.isPresent()) {
    LOG.debug("tote={} already/still bound to order={}", toteName, possibleOldCustomerOrderOpt.get().getId());
    throw new BusinessException(toteName + " belongs to different order!");
}
```

**Bug:** The `getOrderByToteLabelId` query has no state filter. When an old order has completed picking (state >= `PICKED` = 600), the tote is physically available but the stale `pickingtoteId` reference blocks reassignment.

**Fix:**
```java
Optional<Customerorder> possibleOldCustomerOrderOpt = customerorderRepository.getOrderByToteLabelId(toteName);

if (possibleOldCustomerOrderOpt.isPresent()) {
    Customerorder oldOrder = possibleOldCustomerOrderOpt.get();
    if (oldOrder.getState() >= WmsConstants.State.PICKED) {
        LOG.debug("tote={} reclaimed from finished order={}", toteName, oldOrder.getId());
        oldOrder.setPickingtoteId(null);
        customerorderRepository.save(oldOrder);
    } else {
        LOG.debug("tote={} already/still bound to active order={}", toteName, oldOrder.getId());
        throw new BusinessException(toteName + " belongs to different order!");
    }
}
```

**Note:** Only `pickingtoteId` is cleared — NOT `historytote` (audit trail). The tote must still pass location and emptiness checks at lines 436-447 after this change. Confirm with business whether the expected physical tote flow allows reuse from `FinishedPicking` location (not just `EmptyTotes`).

---

#### TD-1 Detail

**Current JPQL at `PickingorderPositionRepository.java:123-126`:**
```sql
UPDATE pickingorder_position SET picktounitload_id = :picktounitloadId
WHERE customerorderposition_id IN (SELECT id FROM customerorder_position WHERE order_id = :orderId)
```

**Bug confirmed:** This query filters by customer order but NOT by picking order. When a customer order has positions split across multiple picking orders (different sections, different waves), this updates ALL of them — corrupting positions in other picking orders.

**Only caller:** `MobilePickingService.java:487` — no other callers exist (grep confirmed).

**Fix — Repository (`PickingorderPositionRepository.java:123-126`):**
```java
@Modifying
@Query(value = "UPDATE pickingorder_position SET picktounitload_id = :picktounitloadId "
    + "WHERE customerorderposition_id IN (SELECT id FROM customerorder_position WHERE order_id = :orderId) "
    + "AND pickingorder_id = :pickingorderId", nativeQuery = true)
int assignToteToAllPositions(@Param("picktounitloadId") Long picktounitloadId,
                             @Param("orderId") Long orderId,
                             @Param("pickingorderId") Long pickingorderId);
```

**Fix — Call site (`MobilePickingService.java:487`):**
```java
pickingorderPositionRepository.assignToteToAllPositions(
    pickingUnitLoad.getId(), customerOrder.getId(), pickingOrder.getId());
```

---

#### NEW-1: Missing state guard in processPick

After re-reading the picking order at line 388, the code checks operator assignment (line 395) but never checks `pickingOrder.getState()`. If the order is in state `PICKED` (600) or `FINISHED` (700), processing should not continue.

**Fix:** After line 395, add:
```java
if (pickingOrder.getState() >= WmsConstants.State.PICKED) {
    throw new BusinessException("Picking order " + pickingOrder.getId() + " is already in state " + pickingOrder.getState());
}
```

---

### 2. `CustomerorderService.java`

**V2 path:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| **TD-2** | Check ALL positions for STARTED state | **248-250** | **Confirmed missing** | Replace `poPositionsMerged` with direct check on `poPositions`. Fix typo. | High |
| **TD-3** | Clean up orphaned picking orders after position deletion | **after 279** | **Confirmed missing** | Add orphan cleanup. `PickingorderUnitloadRepository` already injected (line 63). | High |
| **NEW-2** | Missing `@Transactional` on `setPickingDate` | **200** | **New finding** | Add `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})` | Critical |
| **NEW-3** | `forceCancelOrder` potential NPE | **324** | **New finding** | Add null guard before `pickingOrder.getId()` | Medium |
| **NEW-4** | Comment typo | **246** | **New finding** | Change "packing has stated" to "picking has started" | Low |

#### TD-2 Detail

**Current code (lines 248-250):**
```java
List<PickingorderPosition> poPositionsMerged = pickingorderPositionRepository.findByPickingorderId(poPositions.get(0).getPickingorderId());
boolean hasPickingStated = poPositionsMerged.stream().anyMatch(p -> p.getState() >= WmsConstants.State.STARTED);
if (!poPositions.isEmpty() && hasPickingStated) {
```

**Bug:** `poPositionsMerged` only checks positions from the FIRST picking order. If positions span multiple picking orders, positions in other picking orders that are STARTED are not detected — allowing deletion of active positions.

**Fix:**
```java
// check if picking has started (across ALL picking orders for this customer order)
boolean hasPickingStarted = poPositions.stream().anyMatch(p -> p.getState() >= WmsConstants.State.STARTED);
if (!poPositions.isEmpty() && hasPickingStarted) {
```

Remove line 248 entirely. Fix typo `hasPickingStated` → `hasPickingStarted` on lines 249-250.

---

#### TD-3 Detail

**Insertion point:** After line 280 (after position deletion `for` loop), before line 281 (closing brace).

**Dependencies verified:**
- `PickingorderUnitloadRepository` — already injected at line 63, constructor at line 101/128
- `PickingorderRepository` — already injected at line 61, constructor at line 100/127
- `findByPickingorderId` — available on both repositories

**Fix:**
```java
// Clean up orphaned picking orders (TD-3)
Set<Long> pickingOrderIds = poPositions.stream()
    .map(PickingorderPosition::getPickingorderId)
    .collect(Collectors.toSet());

for (Long pickingOrderId : pickingOrderIds) {
    List<PickingorderPosition> remainingPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrderId);
    if (remainingPositions.isEmpty()) {
        Pickingorder pickingOrder = pickingorderRepository.findById(pickingOrderId)
            .orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingOrderId));
        pickingOrder.setState(WmsConstants.State.CANCELED);
        pickingorderRepository.save(pickingOrder);

        List<PickingorderUnitload> unitloads = pickingorderUnitloadRepository.findByPickingorderId(pickingOrderId);
        for (PickingorderUnitload unitload : unitloads) {
            unitload.setState(WmsConstants.State.CANCELED);
            pickingorderUnitloadRepository.save(unitload);
        }
    }
}
```

**Pattern reference:** `CustomerorderPositionService.java:132-137` uses the same orphan-check pattern.

---

#### NEW-2: Missing @Transactional on setPickingDate (CRITICAL)

Neither `batchUpdatePickingDate` (line 194) nor `setPickingDate` (line 200) has `@Transactional`. The `checkAndCleanUpPickingOrderPositions` method called from `setPickingDate` performs multiple deletes, reserved amount changes, and saves. Without a transaction:
- Each operation auto-commits separately
- If a failure occurs mid-way, earlier changes are already committed and won't roll back
- TD-3's orphan cleanup queries after deletes without transactional consistency

**Fix:** Add to `setPickingDate` at line 200:
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public Map<String, Object> setPickingDate(...)
```

---

#### NEW-3: forceCancelOrder NPE risk (line 324)

```java
List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
if (pickingOrder != null && poPositions.stream().allMatch(...)) {
```

If `pickingOrder` is null (no picking order positions found in the loop at lines 302-317), line 324 throws NPE on `pickingOrder.getId()` before the null check on line 325.

**Fix:** Add null guard before line 324:
```java
if (pickingOrder != null) {
    List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
    if (poPositions.stream().allMatch(p -> p.getState() >= WmsConstants.State.FINISHED)) {
        // ... existing logic ...
    }
}
```

---

### 3. `PickingOrderMergeService.java`

**V2 path:** `src/main/java/net/aim_ai/wms/service/PickingOrderMergeService.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| **RC-2** | Pessimistic lock during merge | **58** | **Confirmed missing** | Replace `findAllById` with new `findAllByIdForUpdate` | Medium |
| RC-12 | Mutate locked managed entity | 127-131 | Already done | V2's `currentOrderMap` pattern avoids the V1 bug | -- |
| **RC-5** | Clear `picktounitloadId` during position reassignment | **170-172** | **Confirmed missing** | Add `pickingPosition.setPicktounitloadId(null)` | High |

#### RC-2 Detail

**Current code (line 58):**
```java
pickingorderRepository.findAllById(pickingOrderIds).forEach(po -> currentOrderMap.put(po.getId(), po));
```

Plain SELECT with no locking. Two concurrent merge operations could both read the same picking orders as eligible.

**Fix — Add to `PickingorderRepository.java`:**
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT p FROM Pickingorder p WHERE p.id IN :ids")
List<Pickingorder> findAllByIdForUpdate(@Param("ids") Collection<Long> ids);
```

**Fix — `PickingOrderMergeService.java:58`:**
```java
pickingorderRepository.findAllByIdForUpdate(pickingOrderIds).forEach(po -> currentOrderMap.put(po.getId(), po));
```

---

#### RC-5 Detail

**Current code (lines 170-172):**
```java
for (PickingorderPosition pickingPosition : pickingPositions) {
    pickingPosition.setPickingorderId(pickingOrder.getId());
    positionsToSave.add(pickingPosition);
}
```

The `picktounitloadId` references a unit load from the original picking order's workflow. After merge, it becomes stale and could direct items to the wrong container.

**Fix — Add line between 171 and 172:**
```java
pickingPosition.setPickingorderId(pickingOrder.getId());
pickingPosition.setPicktounitloadId(null);
positionsToSave.add(pickingPosition);
```

---

### 4. `CustomerorderPositionService.java`

**V2 path:** `src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| **RC-8** | `findByIdForUpdate` in cancelOrderPosition (validation loop) | **115** | **Confirmed missing** | Change `findById` to `findByIdForUpdate` | Medium |
| **RC-8** | `findByIdForUpdate` in cancelOrderPosition (cancellation loop) | **132** | **Confirmed missing** | Change `findById` to `findByIdForUpdate` | Medium |
| **NEW-5** | Missing `@Transactional` on `cancelOrderPosition` | **107** | **New finding — CRITICAL** | Add `@Transactional(value = "tenantTransactionManager", ...)`. Without this, RC-8 locks are ineffective. | Critical |
| **NEW-6** | Stock unit race in cancelOrderPosition | **126** | **New finding** | Change `stockunitRepository.findById` to `findByIdForUpdate` | Medium |

#### RC-8 Detail

**Validation loop (line 115):**
```java
Pickingorder pickingOrder = pickingorderRepository.findById(pickingPosition.getPickingorderId()).orElseThrow(...);
```

**Cancellation loop (line 132):**
```java
Pickingorder pickingOrder = pickingorderRepository.findById(pickingPosition.getPickingorderId()).orElseThrow(...);
```

Both use plain `findById`. Creates a TOCTOU race between validation and cancellation.

**Fix:** Change both to `findByIdForUpdate`. Method already exists in `PickingorderRepository.java:21-23`.

---

#### NEW-5: Missing @Transactional (CRITICAL)

`cancelOrderPosition` at line 107 has **no** `@Transactional`. The class has no class-level annotation either. Without a transaction, each repository call auto-commits separately, making pessimistic locks from RC-8 **completely ineffective** (lock released immediately after each query).

**Fix:** Add to line 107:
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void cancelOrderPosition(List<Long> customerorderPositionIds) throws BusinessException {
```

**This must be implemented BEFORE or WITH RC-8, otherwise the locks provide zero protection.**

---

#### NEW-6: Stock unit race (line 126)

```java
Stockunit stockunit = stockunitRepository.findById(pickingPosition.getPickfromstockunitId()).orElseThrow(...);
```

Two concurrent cancellations of positions referencing the same stock unit could both read the same reserved amount, then both subtract, causing double-decrement. `StockunitRepository` already has `findByIdForUpdate` (line 29).

**Fix:** Change to `stockunitRepository.findByIdForUpdate(...)`.

---

### 5. `PickingController.java`

**V2 path:** `src/main/java/net/aim_ai/wms/controller/mobile/PickingController.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| **RC-7** | `ObjectOptimisticLockingFailureException` catch | 21, 227 | Partial — only `releasePickingOrder` has it | Add to 7 other state-mutating endpoints | Low |
| **RC-10** | `PessimisticLockingFailureException` catch | -- | Missing entirely | Add import + catch blocks | Low |
| **RC-11** | `PessimisticLockingFailureException` on releasePickingOrder | 225-235 | Missing | Add catch to existing try-catch | Low |
| **NEW-7** | Stale read + unsafe `.get()` in processPick | **302** | **New finding** | Change to `findByIdForUpdate(...).orElseThrow(...)` | Medium |

**Endpoint inventory:**

| # | Method | Line | Has OLF catch? | Has PLF catch? | Needs fix? |
|---|--------|------|----------------|----------------|------------|
| 1 | `processRapidPickScanPackage` | 61 | NO | NO | YES |
| 2 | `processRapidPickScanSource` | 122 | NO | NO | YES |
| 3 | `processRapidPickScanSourcePass` | 146 | NO | NO | YES |
| 4 | `processRapidPickScanPackageToVerify` | 167 | NO | NO | YES |
| 5 | `resetPickingOrder` | 188 | NO (no try/catch) | NO | YES |
| 6 | `pickTimeOutValue` | 195 | N/A (config read) | N/A | NO |
| 7 | `pickingOrders` | 205 | NO (read-only) | NO | NO |
| 8 | `releasePickingOrder` | 219 | **YES** (line 227) | NO | YES (add PLF) |
| 9 | `pickingOrderPositionsInfo` | 247 | NO (read-only) | NO | NO |
| 10 | `processLocation` | 271 | NO | NO | YES |
| 11 | `processPick` | 293 | NO | NO | YES |

**Focus on 8 state-mutating endpoints** (1-5, 8, 10, 11). Import `org.springframework.dao.PessimisticLockingFailureException` (not yet imported).

---

#### NEW-7: Stale read + unsafe `.get()` (line 302)

```java
Pickingorder order = pickingorderepository.findById(orderId).get();
```

Uses `findById` (no lock) and `.get()` (unsafe). If concurrent transaction finishes the order, stale entity causes incorrect state transitions.

**Fix:**
```java
Pickingorder order = pickingorderepository.findByIdForUpdate(orderId)
    .orElseThrow(() -> new EntityNotFoundException("PickingOrder", orderId));
```

---

### 6. `application.properties`

**V2 path:** `src/main/resources/application.properties`

| # | Fix | Status | Action | Priority |
|---|-----|--------|--------|----------|
| **RC-4** | Lock timeout 5s | **Confirmed missing** (grep: zero matches for `lock.timeout`) | Add after JPA properties block (line ~49) | Medium |

**Fix:** Add to JPA properties section:
```properties
spring.jpa.properties.jakarta.persistence.lock.timeout=5000
```

---

### 7. `PickingorderRepository.java`

**V2 path:** `src/main/java/net/aim_ai/wms/repo/jpa/PickingorderRepository.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| -- | `findByIdForUpdate` | 21-23 | Already exists | None | -- |
| **NEW** | `findAllByIdForUpdate` (for bulk merge lock) | -- | **Confirmed missing** | Add method with `@Lock(PESSIMISTIC_WRITE)` | Medium |

**Fix:**
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT p FROM Pickingorder p WHERE p.id IN :ids")
List<Pickingorder> findAllByIdForUpdate(@Param("ids") Collection<Long> ids);
```

---

### 8. `PickingorderPositionRepository.java`

**V2 path:** `src/main/java/net/aim_ai/wms/repo/jpa/PickingorderPositionRepository.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| **TD-1** | Scope `assignToteToAllPositions` by pickingorderId | **123-126** | **Confirmed data corruption bug** | Add `AND pickingorder_id = :pickingorderId` + add parameter | Critical |

---

## Implementation Priority (Updated)

### Phase 0 — Prerequisites (CRITICAL — must be done first)

| # | Fix | File | Description |
|---|-----|------|-------------|
| NEW-5 | Add `@Transactional` to `cancelOrderPosition` | `CustomerorderPositionService` | **Without this, RC-8 pessimistic locks are completely ineffective** |
| NEW-2 | Add `@Transactional` to `setPickingDate` | `CustomerorderService` | **Without this, TD-3 orphan cleanup is non-atomic** |

### Phase 1 — Data corruption prevention (HIGH)

| # | Fix | File | Description |
|---|-----|------|-------------|
| TD-1 | Scope tote assignment JPQL | `PickingorderPositionRepository` + `MobilePickingService` | Prevents cross-order tote contamination |
| RC-5 | Clear picktounitloadId in merge | `PickingOrderMergeService` | Prevents stale tote references after merge |
| TD-2 | Check ALL positions for STARTED | `CustomerorderService` | Prevents deleting active picking positions |
| TD-3 | Orphan cleanup after position deletion | `CustomerorderService` | Prevents orphaned picking orders accumulating |
| TD-4 | Tote reuse from finished orders | `MobilePickingService` | Unblocks tote reuse |

### Phase 2 — Race condition protection (MEDIUM)

| # | Fix | File | Description |
|---|-----|------|-------------|
| RC-6 | Lock in processPick | `MobilePickingService` | Serializes picks against merge |
| RC-9 | Lock in getPickingOrderPositionsInfo | `MobilePickingService` | Locks the real regular-picking entry point |
| RC-8 | Lock in cancelOrderPosition | `CustomerorderPositionService` | Prevents cancel/merge/pick races |
| NEW-6 | Lock stock unit in cancelOrderPosition | `CustomerorderPositionService` | Prevents double-decrement of reserved amount |
| RC-2 | Lock in merge service | `PickingOrderMergeService` + `PickingorderRepository` | Prevents merge from reading stale state |
| RC-4 | Lock timeout config | `application.properties` | Prevents indefinite waits |

### Phase 3 — Safety & error handling (LOW-MEDIUM)

| # | Fix | File | Description |
|---|-----|------|-------------|
| NEW-3 | NPE guard in forceCancelOrder | `CustomerorderService` | Prevents NPE when order has no picking positions |
| NEW-7 | Stale read + unsafe `.get()` in controller | `PickingController` | Fix stale entity + replace `.get()` with `orElseThrow` |
| NEW-1 | State guard in processPick | `MobilePickingService` | Prevents processing on already-picked orders |
| RC-7 | OptimisticLock catch on all endpoints | `PickingController` | User-friendly retry message |
| RC-10 | PessimisticLock catch on all endpoints | `PickingController` | Lock timeout shows retry message |
| RC-11 | Error handling on releasePickingOrder | `PickingController` | Catch missing exceptions |
| NEW-4 | Comment typo fix | `CustomerorderService` | "packing has stated" → "picking has started" |

---

## Testing Plan

### Unit Tests to Port/Create

| V1 Test | V2 Equivalent | What it tests |
|---------|--------------|---------------|
| `processPick_ToteAssignment_OnlyUpdatesCurrentPickingOrderPositions` | Adapt for JPQL mock | TD-1: Verify `pickingorderId` parameter passed to `assignToteToAllPositions` |
| `processPick_ToteReuse_ClearsStaleReferenceFromFinishedOrder` | Direct port | TD-4: Tote reuse from finished order clears `pickingtoteId` |
| `setPickingDate_withMultiplePickingOrders_oneStarted_throwsBusinessException` | Direct port | TD-2: STARTED check across ALL picking orders |
| `setPickingDate_deletesPositions_cancelsOrphanedPickingOrders` | Direct port | TD-3: Orphan picking order + unitload cleanup |
| `setPickingDate_deletesPositions_skipsPickingOrderWithRemainingPositions` | Direct port | TD-3: Skip non-empty picking orders |
| `ReplenishOrderJobUnitTest` (4 tests) | New `PickingOrderMergeServiceUnitTest` | RC-2,5: Merge lock + picktounitloadId clearing |
| NEW | `cancelOrderPosition_locksPickingOrder` | RC-8: Verify `findByIdForUpdate` is called |
| NEW | `cancelOrderPosition_locksStockUnit` | NEW-6: Verify stock unit locked during cancel |

### V2-Specific Test Considerations

- `assignToteToAllPositions` is a JPQL query — unit tests mock the repository call, not the SQL. The TD-1 test should verify the correct 3 parameters are passed (including `pickingorderId`)
- V2's `PickingOrderMergeService` uses `findAllById` → `findAllByIdForUpdate`. Tests must mock the new method
- Integration tests are recommended for the JPQL changes (TD-1, RC-5) since mocks don't validate SQL correctness
- NEW-5 and NEW-2 (`@Transactional`) are annotation-only changes — verify via integration tests that rollback works correctly

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| TD-1 JPQL change breaks other callers of `assignToteToAllPositions` | Low | High | Grep confirmed single caller: `MobilePickingService.processPick()` |
| V2 `tenantTransactionManager` not applied to new annotations | Medium | High | Review all new `@Transactional` annotations use correct transaction manager |
| `jakarta.persistence.lock.timeout` property name wrong | Low | Medium | Verify Spring Boot 3 documentation for correct property name |
| Bulk `findAllByIdForUpdate` causes contention under load | Low | Medium | Lock is held briefly within the `REQUIRES_NEW` merge transaction |
| Constructor injection changes cause circular dependency | Low | Medium | V2 already resolved injection order — no new deps needed (all verified) |
| NEW-5 `@Transactional` on `cancelOrderPosition` creates nested tx | Low | Low | Spring default is REQUIRED (joins existing) — safe unless caller uses REQUIRES_NEW |
| NEW-2 `@Transactional` on `setPickingDate` creates nested tx | Low | Low | Same as above — verify no callers use REQUIRES_NEW |
| TD-4 tote location check rejects reclaimed tote | Medium | Medium | Confirm with business whether totes at `FinishedPicking` location are allowed for reuse |

---

## New Issues Summary (Discovered During V2 Analysis)

| # | Issue | File:Line | Severity | Description |
|---|-------|-----------|----------|-------------|
| NEW-1 | Missing state guard in processPick | `MobilePickingService:388+` | Low | No upper-bound state check after re-reading picking order |
| NEW-2 | Missing `@Transactional` on `setPickingDate` | `CustomerorderService:200` | **Critical** | Position deletion + orphan cleanup not atomic |
| NEW-3 | NPE in `forceCancelOrder` | `CustomerorderService:324` | Medium | `pickingOrder.getId()` called before null check |
| NEW-4 | Comment typo | `CustomerorderService:246` | Low | "packing has stated" → "picking has started" |
| NEW-5 | Missing `@Transactional` on `cancelOrderPosition` | `CustomerorderPositionService:107` | **Critical** | Makes ALL RC-8 pessimistic locks completely ineffective |
| NEW-6 | Stock unit race in cancel | `CustomerorderPositionService:126` | Medium | `findById` instead of `findByIdForUpdate` on stock unit |
| NEW-7 | Stale read + unsafe `.get()` | `PickingController:302` | Medium | No lock, `.get()` instead of `orElseThrow` |
