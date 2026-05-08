# Debug Plan: Optimistic Locking Failure in mergePickingOrders

**Date:** 2026-04-03
**Priority:** Critical
**Reporter:** Production log

---

## 1. Problem Summary

The `ReplenishOrderJob.mergePickingOrders()` method fails with `ObjectOptimisticLockingFailureException` on `Pickingorder` entities. The error appears during `basicService.showLog()` but is actually caused by Hibernate auto-flushing stale detached entities that were merged into the persistence context with outdated `@Version` values.

## 2. Root Cause Analysis

**Transaction boundary mismatch causes detached entity staleness.**

The call chain:
1. `mergePickingOrders()` (private, line 99, **non-transactional**) loads `pickingOrders` at line 139
2. `self.mergePickingOrders(pickingOrders, ...)` (public, line 388, **`@Transactional(REQUIRES_NEW)`**) starts a new transaction — the passed-in entities are **detached** in this new context

Inside the `REQUIRES_NEW` method:
- **Line 401:** `findByIdForUpdate(pickingOrder.getId())` acquires a pessimistic lock and returns a fresh **managed** entity `poCurrent` with the current DB version
- **Line 403:** `poCurrent` is used for the state check — correct
- **Line 429-431:** `pickingOrder.setState(CANCELED)` etc. — modifies the **detached** entity from the parameter list, NOT `poCurrent`
- **Line 433:** `pickingOrderList.add(pickingOrder)` — stores the **detached** entity
- **Line 457:** `pickingOrder = pickingOrderList.remove(0)` — retrieves the detached entity
- **Line 463:** `pickingorderRepository.save(pickingOrder)` — merges the detached entity (stale `@Version`) into the persistence context
- **Line 466:** `basicService.showLog()` calls `findSysvalueBySyskey` → Hibernate auto-flushes → attempts SQL UPDATE with stale version → **OptimisticLockingFailureException**

The `findByIdForUpdate` was correctly added for concurrency safety, but the subsequent code continues operating on the original detached `pickingOrder` instead of the freshly-locked `poCurrent`.

## 3. Reproduction Steps

1. Enable cron jobs (`app.cron=true`) with merge picking orders enabled
2. Have multiple picking orders in RESERVED state for the same section
3. Have concurrent activity that modifies any of those picking orders between the initial query (line 139) and the merge operation
4. **Expected:** Picking orders merge successfully
5. **Actual:** `ObjectOptimisticLockingFailureException` on `Pickingorder`

## 4. Proposed Fix

### Fix A: Use `poCurrent` instead of `pickingOrder` for all mutations and list operations

- **File:** `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:429-433`
- **Current:**
  ```java
  pickingOrder.setState(WmsConstants.State.CANCELED);
  pickingOrder.setCustomerordernumber(null);
  pickingOrder.setSectionId(null);
  pickingOrderList.add(pickingOrder);
  ```
- **Change:**
  ```java
  poCurrent.setState(WmsConstants.State.CANCELED);
  poCurrent.setCustomerordernumber(null);
  poCurrent.setSectionId(null);
  pickingOrderList.add(poCurrent);
  ```
- **Why:** `poCurrent` is the managed entity with the correct version from `findByIdForUpdate`. Using it for all subsequent mutations ensures Hibernate tracks the correct version, and the pessimistic lock actually protects the modifications.

### Fix B: Use `poCurrent` for the position lookup (line 408)

- **File:** `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:408`
- **Current:** `pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());`
- **Change:** `pickingorderPositionRepository.findByPickingorderId(poCurrent.getId());`
- **Why:** While functionally identical (same ID), this makes the code consistent — all operations within the `poCurrent != null` block use the managed entity.

## 5. Risks & Side Effects

- **Risk:** Minimal. The fix simply switches from a detached entity to the managed entity that was already being fetched via `findByIdForUpdate`. The business logic is unchanged.
- **Regression areas to test:**
  - Merge picking orders job completes without errors
  - Picking order positions are correctly reassigned after merge
  - Leftover (unused) picking orders are correctly saved as CANCELED (line 492-494)
  - Concurrent picking operations don't deadlock with the pessimistic lock

## 6. Task Checklist

- [x] Replace `pickingOrder` with `poCurrent` for all mutations and list operations inside the `for` loop (lines 408-433) (Critical) — **Done 2026-04-03**
- [x] Update unit tests to verify managed entities from `findByIdForUpdate` are saved, not detached input entities — **Done 2026-04-03** (5 tests, all pass)
- [x] Run full test suite — **Done 2026-04-03** (1608 tests, 0 failures from this change; 2 pre-existing failures in `ViewDtoServiceUnitTest`)
- [ ] Verify the merge picking orders job runs cleanly in staging
- [ ] Check for similar patterns in other `ReplenishOrderJob` methods where detached entities from outer methods are passed into `REQUIRES_NEW` transactions
