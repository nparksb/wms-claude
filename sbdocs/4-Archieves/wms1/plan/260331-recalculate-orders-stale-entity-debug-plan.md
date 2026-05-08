# Debug Plan: Recalculate Orders Stale Entity Optimistic Lock

**Date:** 2026-03-31
**Priority:** Medium
**Reporter:** Production logs (ReplenishmentOrderMaintenanceService)

---

## 1. Problem Summary

`ReplenishmentOrderMaintenanceService.recalculateOpenOrders()` loads all PROCESSABLE replenish orders in one batch query, then iterates and recalculates each. By the time `updateRequestedAmount()` calls `replenishorderRepository.save(order)`, the entity's `@Version` may be stale because earlier steps of `ReplenishOrderJob.doCalculation()` (which use `REQUIRES_NEW` transactions) or concurrent web requests modified the same row. The exception **is already caught gracefully** (WARN + DEBUG log, iteration continues), but it can be reduced by re-fetching each order before recalculation.

Additionally, the `@Transactional` annotation recently added to `recalculateOpenOrders(boolean)` is **ineffective** due to Spring's self-invocation limitation and would be **harmful** if it did work.

## 2. Root Cause Analysis

### 2.1 Stale Entity From Batch Load

```
ReplenishOrderJob.doCalculation()
  ├─ mergePickingOrders()                    // may modify related data
  ├─ deleteEmptyFixAssignment...()           // REQUIRES_NEW — may modify replenish orders
  ├─ cancelUnreachableReplenishment()        // REQUIRES_NEW — cancels replenish orders
  ├─ cancelReplenishmentIfFlowbinIsFull()    // REQUIRES_NEW — cancels replenish orders
  ├─ generateReplenishment...()              // REQUIRES_NEW — creates new replenish orders
  ├─ triggerRegularReplenishment()           // REQUIRES_NEW — creates new replenish orders
  ├─ updateReplenishmentOrderPriority()      // REQUIRES_NEW — updates replenish orders ← MODIFIES ROWS
  ├─ recalculateReplenishment...()           // REQUIRES_NEW — modifies replenish orders ← MODIFIES ROWS
  └─ recalculateOpenOrders()                 // LAST STEP — loads ALL processable orders
      └─ for each order:
          └─ recalculateOrder(order)          // order loaded ONCE at batch time, now stale
              └─ updateRequestedAmount()
                  └─ save(order)              // ← VERSION MISMATCH → StaleObjectStateException
```

The earlier steps (`updateReplenishmentOrderPriority`, `recalculateReplenishmentOrderWithoutFixedLocationAssignment`) use `REQUIRES_NEW` and commit independently. By the time `recalculateOpenOrders` loads entities at line 76, those changes are visible. But **concurrent** modifications (web requests, other cron cycles) that happen **during** the iteration can still cause version mismatches.

### 2.2 `@Transactional` Self-Invocation Bug

- **File:** `ReplenishmentOrderMaintenanceService.java:66-71`
- `ReplenishOrderJob.doCalculation()` (line 94) calls `replenishmentOrderMaintenanceService.recalculateOpenOrders()` (no-arg)
- The no-arg method at line 66 calls `this.recalculateOpenOrders(false)` — **self-invocation**
- Spring's proxy only intercepts calls that come through the proxy. Self-calls bypass it.
- Therefore the `@Transactional` on `recalculateOpenOrders(boolean)` at line 70 **never triggers**
- **If it DID trigger**, it would be harmful: one failed `save()` marks the transaction rollback-only, and all subsequent `save()` calls in the same iteration would fail with `UnexpectedRollbackException`

### 2.3 Exception Handling Status: ALREADY HANDLED

The try-catch at lines 81-86 correctly catches `Exception` (including `ObjectOptimisticLockingFailureException`), logs at WARN + DEBUG, and continues to the next order. The stack trace confirms this — the WARN and DEBUG messages match exactly. **The job does not crash.**

## 3. Reproduction Steps

1. Have multiple PROCESSABLE replenish orders in the database
2. Start the cron cycle (`ReplenishOrderJob.doCalculation()`)
3. While `recalculateOpenOrders` iterates, have another transaction modify the same `Replenishorder` row (e.g., priority update from web UI, or concurrent cron cycle)
4. `updateRequestedAmount` → `save()` → `StaleObjectStateException`
5. Expected: graceful skip and continue / Actual: graceful skip and continue (WARN log)

## 4. Proposed Fix

### Fix A: Remove `@Transactional` from `recalculateOpenOrders(boolean)` and `recalculateForItem(Long)`

- **File:** `ReplenishmentOrderMaintenanceService.java:70, 90`
- **Current:** Both methods have `@Transactional` and loop over orders with per-order try-catch
- **Change:** Remove `@Transactional` from both methods
- **Why for `recalculateOpenOrders(boolean)` (line 70):** (1) It never triggers due to self-invocation from the no-arg overload at line 66. (2) If it did trigger, it would be harmful — one failed `save()` marks the transaction rollback-only, and all subsequent `save()` calls fail with `UnexpectedRollbackException` despite the catch block. Without `@Transactional`, each `replenishorderRepository.save()` gets its own auto-committed transaction, and failures are isolated per-order.
- **Why for `recalculateForItem(Long)` (line 90):** This `@Transactional` IS active in production (callers `StockunitService.triggerReplenishmentMaintenance()` and `FixLocationAssignmentService.triggerReplenishmentMaintenance()` invoke through the proxy). Same poison problem: if one order's `save()` hits optimistic lock, the catch at line 104 catches the exception, but the transaction is rollback-only — subsequent iterations silently fail. Removing it gives each `save()` its own transaction with isolated failures. The practical impact is lower (typically 1-3 orders per itemDataId), but the design flaw is the same. Both callers already wrap the call in their own try-catch, so removing `@Transactional` doesn't change error propagation to callers.

### Fix B: Re-fetch each order in `recalculateOrder()` to reduce staleness

- **File:** `ReplenishmentOrderMaintenanceService.java:111`
- **Current:** `recalculateOrder(Replenishorder order)` operates on the entity loaded at batch time (line 76/97), which may be stale
- **Change:** Re-fetch the order by ID at the start of `recalculateOrder()`:
  ```java
  void recalculateOrder(Replenishorder order) {
      order = replenishorderRepository.findById(order.getId()).orElse(null);
      if (order == null || !Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) {
          return;
      }
      // ... rest of method unchanged
  }
  ```
- **Why:** Reduces the staleness window from "entire batch iteration time" to "single order processing time". The batch query at line 76 becomes just an ID collector. Each order gets the latest version before recalculation, drastically reducing optimistic lock conflicts. Benefits both `recalculateOpenOrders` (many orders) and `recalculateForItem` (few orders).

## 5. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| Re-fetching adds one extra query per order | Minor DB load increase | Negligible — one SELECT per order vs. the existing multiple native queries per order in `recalculateOrder` |
| Race condition still possible between re-fetch and save | Occasional optimistic lock exception | Already handled by existing try-catch — just reduces frequency |
| Removing `@Transactional` from both methods changes session management | Each repo call gets its own mini-transaction | For `recalculateOpenOrders(boolean)`, this is already the actual behavior (annotation never triggered). For `recalculateForItem`, this is a real change but improves per-order failure isolation. |
| Callers of `recalculateForItem` that relied on atomic behavior | No longer all-or-nothing | Both callers (`StockunitService`, `FixLocationAssignmentService`) already wrap the call in try-catch and treat it as best-effort fire-and-forget. Removing atomicity matches the caller's intent. |

## 6. Task Checklist

- [x] **Fix A-1**: Remove `@Transactional` from `recalculateOpenOrders(boolean)` — (High) ✓ Implemented 2026-03-31
- [x] **Fix A-2**: Remove `@Transactional` from `recalculateForItem(Long)` — (High) ✓ Implemented 2026-03-31
- [x] **Fix B**: Re-fetch order by ID at start of `recalculateOrder()` — (Medium) ✓ Implemented 2026-03-31
- [x] Update unit tests — added 2 new tests (`orderDeletedBeforeRecalculation_skips`, `orderNoLongerProcessableOnRefetch_skips`), updated 14 existing tests with `mockRefetch()` ✓ Implemented 2026-03-31
- [x] Full test suite: 1603 tests, 0 failures, 2 pre-existing errors (unrelated `ViewDtoServiceUnitTest`), 0 skipped ✓ Verified 2026-03-31
- [ ] Verify in staging

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` | Removed `@Transactional` from `recalculateOpenOrders(boolean)` and `recalculateForItem(Long)`, removed unused import, added re-fetch in `recalculateOrder()` |
| `src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | Added `mockRefetch()` helper, 2 new tests, updated 14 existing tests |
| `src/test/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceServiceTest.java` | Added `findById` mock to all 4 tests for re-fetch support |

## 8. Related Concurrency Hotspots (Validated Review Findings)

### 8.1 `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment()` — CONFIRMED

- **File:** `ReplenishorderService.java:239-257`
- **Pattern:** Batch-loads orders at line 243 (`findByStateLessThanEqualAndDestinationIdIsNull`), iterates with `save()` at line 255, **no per-order try-catch**
- **Transaction:** Participates in caller's `REQUIRES_NEW` from `ReplenishOrderJobService` (line 224-228)
- **Risk:** One stale entity rolls back the entire batch. The outer `ReplenishOrderJob` catches `OptimisticLockException | OptimisticLockingFailureException` at line 381, but commit-time rollback can surface as other Spring exception types.
- **Recommendation:** Add per-order try-catch and re-fetch by ID. Lower priority since this method only sets `destinationId` on orders that don't have a fixed location yet (narrow scope).

### 8.2 `ReplenishorderService.updateReplenishmentOrderPriority(List<Itemdata>...)` — CONFIRMED, LOW RISK

- **File:** `ReplenishorderService.java:199-213, 222-237`
- **Pattern:** Batch-loads, iterates with `save()`, no per-order try-catch
- **Transaction:** Participates in caller's transaction (`CustomerorderService` and `CustomerorderBatchService`, both class-level `@Transactional`)
- **Risk:** One stale replenish order could roll back a larger customer order operation
- **Assessment:** This is within an intentionally atomic business operation (order priority change should be all-or-nothing). The review correctly flagged it as a concurrency hotspot, but **this is not automatically a bug** — atomic rollback may be the desired behavior here. Flagged for review, not for immediate fix.

## 7. Review Result

### 7.1 Verdict on the Main Hypothesis

- **Confirmed:** `Replenishorder` does use `@Version`, and `ReplenishmentOrderMaintenanceService.recalculateOpenOrders(boolean)` does batch-load `PROCESSABLE` rows and then save the same entity instances later. That is a real optimistic-lock hotspot under concurrent writers.
- **Confirmed:** removing `@Transactional` from `recalculateOpenOrders(boolean)` is the right direction. In the current production path the annotation is bypassed by self-invocation (`recalculateOpenOrders()` → `this.recalculateOpenOrders(false)`). If some future caller invokes the boolean overload through the Spring proxy, the current annotation would become actively harmful because one conflict could mark the whole loop rollback-only.
- **Correction:** the earlier `REQUIRES_NEW` steps inside `ReplenishOrderJob.doCalculation()` do not themselves make the entities stale *before* `recalculateOpenOrders()` loads them, because that batch fetch happens **after** those steps commit. Those earlier steps are still relevant because they prove there are multiple writers to `replenishorder`, but the actual stale window for this method begins **after** `findByState(PROCESSABLE)` returns and lasts for the duration of the loop.
- **Confirmed:** re-fetching each order by ID at the start of `recalculateOrder()` is a good mitigation because it shrinks that stale window from "entire batch iteration" to "single-order processing". It will reduce conflicts, not eliminate them.

### 7.2 Important Issue Missed by the Original Plan: `recalculateForItem(Long)`

- `ReplenishmentOrderMaintenanceService.recalculateForItem(Long)` is also annotated with `@Transactional`.
- Unlike `recalculateOpenOrders(boolean)`, this transaction **is active in production**, because callers in `StockunitService.triggerReplenishmentMaintenance()` and `FixLocationAssignmentService.triggerReplenishmentMaintenance()` invoke it through the Spring proxy.
- The method still loops over multiple orders and catches `Exception` around each recalculation. That looks isolated, but under JPA optimistic locking the surrounding transaction can already be marked rollback-only after one conflict.
- In that case the visible failure may move to transaction commit time as `UnexpectedRollbackException` or another translated rollback exception, even though the per-order `try/catch` ran.
- **Review conclusion:** the plan should not stop at `recalculateOpenOrders(boolean)`. The same design fix should be applied to `recalculateForItem(Long)` as well: either remove the method-level `@Transactional`, or move the per-order recalculation into isolated transactions, and re-fetch the order by ID before mutating it.

### 7.3 Similar Issue Found: `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment()`

- Current call chain: `ReplenishOrderJob` → `ReplenishOrderJobService.recalculateReplenishmentOrderWithoutFixedLocationAssignment()` (`REQUIRES_NEW`) → `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment()`.
- The inner service loads a list with `findByStateLessThanEqualAndDestinationIdIsNull(...)` and then saves `Replenishorder` entities in a loop inside that one transaction.
- This is the same structural concurrency risk: stale entity instances are held across the loop, and one optimistic-lock conflict can poison or roll back the whole batch instead of skipping only one order.
- The outer job catches `OptimisticLockException`, but commit-time rollback can also surface as Spring rollback exceptions, so the failure isolation here is weaker than it appears.
- **Recommendation:** convert this flow to ID-based iteration and/or re-fetch-per-order, with per-order transaction boundaries if graceful partial progress is required.

### 7.4 Similar Issue Found: Batch Replenishment Priority Propagation

- `ReplenishorderService.updateReplenishmentOrderPriority(List<Itemdata>, int)` and `updateReplenishmentOrderPriority(List<Itemdata>, int, int)` batch-load replenish orders and save them in a loop.
- These methods are called from `CustomerorderService` and `CustomerorderBatchService`, both of which are class-level `@Transactional` services.
- That means one concurrent update on one replenish order can roll back a much larger business transaction that has already modified customer orders and picking orders.
- This may be acceptable if strict all-or-nothing atomicity is desired, so this is **not automatically a bug**. But it is the same long-lived batch-entity pattern and should be reviewed as a concurrency hotspot.

### 7.5 Test Coverage Gap

- The current unit tests for `ReplenishmentOrderMaintenanceService` validate the recalculation branches, but they instantiate the service directly.
- That means they do **not** exercise Spring proxy behavior, self-invocation bypass, transaction commit, rollback-only state, or `UnexpectedRollbackException` scenarios.
- **Recommendation:** add at least one Spring-backed integration test that proves the real behavior of `recalculateForItem(Long)` under optimistic lock failure.

### 7.6 Recommended Additions to This Plan

- Extend **Fix A** to cover `recalculateForItem(Long)`, not only `recalculateOpenOrders(boolean)`.
- Add a follow-up task for `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment()`.
- Add a review task for both `updateReplenishmentOrderPriority(List<Itemdata>...)` overloads to decide whether atomic rollback is intended or whether per-order isolation is preferable.
- Add one integration test that runs through the Spring proxy and verifies the real transactional behavior on optimistic lock conflict.
