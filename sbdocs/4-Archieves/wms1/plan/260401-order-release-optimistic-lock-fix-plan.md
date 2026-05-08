# Order Release Job — OptimisticLockingFailureException on Customerorder

**Date:** 2026-04-01
**Error:** `ObjectOptimisticLockingFailureException` on `Customerorder` (ID `25387403`) during `OrderReleaseJob`
**Stack trace origin:** `PickingorderService.create()` → `pickingorderRepository.save()` → Hibernate flush

---

## 1. Root Cause Analysis

### The Flow

1. `OrderReleaseJob.releaseOrders()` (line 237) calls `releaseOrderJobService.releaseOrder(customerOrderId, ...)` via Spring proxy with `@Transactional(propagation = REQUIRES_NEW)`.
2. Inside `releaseOrder()`:
   - **Line 79**: `Customerorder order = customerorderRepository.findById(orderId).get()` — loads entity with version N.
   - **Lines 102–175**: First loop iterates `CustomerorderPosition`s, may modify positions' states (lines 126, 135, 162, 170). The `order` entity itself is not yet dirty.
   - **Lines 177–179**: `order.setMarkasvisited(true)` + `customerorderRepository.save(order)` — **dirties the `Customerorder` entity in the persistence context**.
   - **Lines 182–193**: If unsatisfied positions exist, may set `order.setState(RAW_ON_HOLD)` and save — potentially a second dirty write.
   - **Lines 204–433**: Second loop — intensive processing with many DB queries. Most are derived/JPQL queries on unrelated tables (`FixLocationAssignment`, `Unitload`, `Stockunit`, `Location`), which Hibernate's AUTO flush mode does NOT flush before (because those queries don't touch the `customerorder` table).
   - **Line 225**: `stockunitRepository.getStockUnitAvailable(...)` — **native query** that triggers a full persistence context flush. If `order` was dirtied at line 179, the flush attempts `UPDATE customerorder SET ... WHERE id=? AND version=N`. If version is now N+1 in DB → **OptimisticLockException**.
   - **Line 458**: `pickingOrderService.create()` → `pickingorderRepository.getNextId()` — another **native query** that triggers a flush. Same risk.

### Why the Version is Stale

Between loading the `Customerorder` at line 79 and the flush at line 225 or 458, another process has modified the same row and incremented its version. The transaction window is very large — it does extensive work (stock availability checks, fix location validations, etc.) which can take hundreds of milliseconds to seconds.

### Concurrent Writers That Increment `Customerorder.version`

| Writer | How | When |
|--------|-----|------|
| **UI: `setPickingDate()`** | `customerorderRepository.save(order)` (CustomerorderService:212) | User changes picking date via web UI |
| **UI: `cancelOrder()`** | `customerorderRepository.save(order)` (CustomerorderService:595,688) | User cancels order via web UI |
| **UI: `batchUpdatePriorityByOrderIds()`** | `customerorderRepository.save(order)` (CustomerorderService) | User changes priority via web UI |
| **REST: `UtilRestController.resetOrders()`** | `customerorderRepository.save(order)` (line 998) | External system resets orders |
| **BOL close: `BillofladingService.closeBOL()`** | `customerorderRepository.updateStateByIds()` — native SQL `version = version + 1` (line 507) | Truck loading completion |
| **`PickingorderBusinessService.confirmPick()`** | `customerorderRepository.save(customerOrder)` (line 320) | Mobile picker confirms a pick |
| **`PickingorderBusinessService.finishPickingOrder()`** | `customerorderRepository.save(customerOrder)` (line 145) | Picking order completion |
| **Spring Data REST** | Auto-exposed `PUT /customerorder/{id}` | Any REST client |

The most likely production culprit is `closeBOL()` using native SQL `updateStateByIds()` which directly increments the version bypassing JPA, or a UI operation like `setPickingDate()` or `cancelOrder()`.

---

## 2. Why the Current Catch Block Doesn't Fully Help

`OrderReleaseJob.releaseOrders()` line 240 catches `OptimisticLockException | OptimisticLockingFailureException` and logs a warning. This means the order simply **doesn't get released** in this cycle and must wait for the next cron run. While this prevents a crash, it causes:
- **Delayed order release** — orders can be stuck for one or more cron cycles.
- **Wasted work** — all the stock availability calculations done before the flush are thrown away.
- **Log noise** — repeated warnings in production logs.

---

## 3. Proposed Fix for `ReleaseOrderJobService.releaseOrder()`

### Option A: Defer `Customerorder` Modifications (Recommended)

**Problem**: The `Customerorder` entity is dirtied early (line 179 `setMarkasvisited`) but not actually needed until the final state transition at line 541–543. The early dirty makes the entity vulnerable to concurrent version increments during the long processing window.

**Fix**: Defer all `Customerorder` modifications to the end of the method, after all position processing and picking order creation is complete. This minimizes the window between dirtying the entity and flushing it.

```java
// Instead of dirtying order at line 177-179:
// order.setMarkasvisited(true);
// order = customerorderRepository.save(order);

// ... do all processing ...

// At the end (around line 541), re-fetch and apply all changes atomically:
order = customerorderRepository.findById(orderId).get(); // re-fetch fresh version
if (!order.getMarkasvisited()) {
    order.setMarkasvisited(true);
}
if (order.getState() < WmsConstants.State.ASSIGNED) {
    order.setState(WmsConstants.State.ASSIGNED);
}
order = customerorderRepository.save(order);
```

**Files to change:**
- `ReleaseOrderJobService.java` — restructure to defer order modifications

### Option B: Use Pessimistic Lock on Load

Lock the `Customerorder` row at load time to prevent concurrent modifications:

```java
// Line 79: Replace findById with findByIdForUpdate
Customerorder order = customerorderRepository.findByIdForUpdate(orderId)
    .orElseThrow(() -> new FacadeException("Order not found: " + orderId));
```

**Pros**: Guarantees no concurrent modification during the transaction.
**Cons**: Holds a row-level lock for the entire duration of `releaseOrder()`, which can be long. This blocks UI operations (cancel, priority change, picking date change) on the same order until the release completes.

### Recommendation

**Option A** is preferred because it doesn't hold locks and the only risk is a race on the final save — which is an extremely narrow window. If needed, Option A can be combined with a pessimistic lock on the final re-fetch:

```java
order = customerorderRepository.findByIdForUpdate(orderId).get();
```

This locks the row only for the brief final update, not the entire processing window.

**Files to change:**
| File | Change |
|------|--------|
| `ReleaseOrderJobService.java` | Remove early `order.setMarkasvisited(true)` + `save()`. Re-fetch order at end of method before final state change. |

---

## 4. Similar Issues in the Picking Pipeline

### 4.1 `PickingorderBusinessService.finishPickingOrder()` — MEDIUM RISK

**File:** `PickingorderBusinessService.java` lines 100–201
**Entity at risk:** `Customerorder`

**Problem:** `finishPickingOrder()` loads `Customerorder` via `findById()` (line 125) — **not** `findByIdForUpdate()` — and then modifies it (line 144: `setPickingconfirmationsent(true)`) and saves it (line 145). Between the load and the save, the method does significant work (iterating positions, checking states, transferring unit loads). Any concurrent modification to the same order will cause an optimistic lock failure.

**Note:** `confirmPick()` in the same class already uses `findByIdForUpdate()` (lines 242, 316, 354) — so this pattern is established but was not applied to `finishPickingOrder()`.

**Fix:** Use `findByIdForUpdate()` when loading the `Customerorder` in `finishPickingOrder()`:
```java
// Line 125: Replace
Customerorder customerOrder = customerorderRepository.findById(coPosition.getOrderId()).get();
// With
Customerorder customerOrder = customerorderRepository.findByIdForUpdate(coPosition.getOrderId()).get();
```

**Risk if unfixed:** When mobile picking finishes the last pick and `confirmPick()` calls `finishPickingOrder()`, a concurrent `closeBOL()` or UI operation on the same order will cause the transaction to fail with `OptimisticLockingFailureException`. The picker sees an error and must retry.

### 4.2 `PickingorderBusinessService.finishPickingOrder()` — HashSet Contains Check with Broken Equals

**File:** `PickingorderBusinessService.java` line 113, 126–128
**Entity at risk:** `Customerorder`

**Problem:** The method uses `Set<Customerorder> customerOrderSet = new HashSet<>()` and `customerOrderSet.contains(customerOrder)` to deduplicate orders. Per CLAUDE.md, `Customerorder` does NOT have `equals()`/`hashCode()` — it uses Object reference equality. If the same order is loaded by two different `findById()` calls (which can happen if positions from the same order appear in different picking positions), they will be different object references. The `contains()` check will return `false`, causing the order to be processed twice — setting `pickingconfirmationsent` and saving the entity twice, potentially triggering a version mismatch on the second save.

**Fix:** Use a `Set<Long>` to track processed order IDs:
```java
Set<Long> processedOrderIds = new HashSet<>();
// ...
if (processedOrderIds.contains(customerOrder.getId())) {
    continue;
}
processedOrderIds.add(customerOrder.getId());
```

### 4.3 `MobilePickingService` — Stale Pickingorder After `finishPickingOrder()`

**File:** `MobilePickingService.java` lines 980–985
**Entity at risk:** `Pickingorder`

**Problem:** After calling `pickingorderBusinessService.finishPickingOrder(pickingOrder)` (line 982), the code modifies the returned `pickingOrder` (lines 983-984: `setLockedtooperator(false)`, `setPickinginprogress(false)`) and saves it (line 985). However, `finishPickingOrder()` already saves the `Pickingorder` at its line 198 with a new state. The returned object should be fresh, but if the save inside `finishPickingOrder()` encounters any concurrent modification, the version will be wrong.

**Risk level:** LOW — `confirmPick()` acquires a pessimistic lock on the `Pickingorder` before calling through to `finishPickingOrder()`, so concurrent modifications are unlikely. But the post-finish modifications (lines 983-985) happen outside the lock scope if called from a different path.

### 4.4 `CustomerorderBatchService` — Re-fetch Pattern Already Applied But Incomplete

**File:** `CustomerorderBatchService.java` lines 614–620
**Entity at risk:** `Customerorder`

**Problem:** The club order flow already re-fetches orders with `customerorderRepository.findById(staleOrder.getId())` (line 615), recognizing the stale-entity risk. However, this re-fetch uses `findById()`, not `findByIdForUpdate()`. If two club runs process the same batch concurrently, both will load fresh versions but one will fail on save.

**Fix:** Use `findByIdForUpdate()` for the re-fetch in the club order completion path.

---

## 5. Additional Risk: `BillofladingService.closeBOL()` Native SQL Bypassing JPA

**File:** `CustomerorderRepository.java` line 172
**Method:** `updateStateByIds()` — native SQL `UPDATE customerorder SET state = :state, version = version + 1 WHERE id IN (:ids)`

**Problem:** This native SQL update increments the version directly in the database, but any `Customerorder` entity already loaded in a different transaction's persistence context will still have the old version. This is the most likely cause of the `OptimisticLockingFailureException` in the `OrderReleaseJob`, because:
1. `closeBOL()` typically runs during truck loading (a separate thread/request).
2. It updates orders to `FINISHED` state with `version + 1`.
3. If `releaseOrder()` loaded the same order before `closeBOL()` ran, its persistence context has a stale version.

**Note:** This is by design — `closeBOL()` intentionally uses native SQL for performance. The fix is on the reader side (`releaseOrder()`) to minimize its stale-data window, not on the writer side.

---

## 6. Implementation Priority

| # | Fix | Priority | Effort | Risk if Unfixed |
|---|-----|----------|--------|-----------------|
| 1 | `ReleaseOrderJobService.releaseOrder()` — defer order dirty + re-fetch at end | **HIGH** | Low | Orders fail to release, delayed fulfillment |
| 2 | `PickingorderBusinessService.finishPickingOrder()` — use `findByIdForUpdate()` | **MEDIUM** | Low | Finish-pick fails, picker must retry |
| 3 | `PickingorderBusinessService.finishPickingOrder()` — fix HashSet dedup | **MEDIUM** | Low | Double-processing of same order, potential OLE |
| 4 | `CustomerorderBatchService` club flow — use `findByIdForUpdate()` | **LOW** | Low | Rare: club batches rarely overlap |
| 5 | `MobilePickingService` post-finish save — defensive re-fetch | **LOW** | Low | Rare: lock already acquired |

---

## 7. Testing Strategy

- **Unit test**: Mock `customerorderRepository.findById()` to return entity with version N, then verify `releaseOrder()` calls `findById()` again at the end (re-fetch pattern).
- **Integration test**: Use two concurrent threads — one running `releaseOrder()`, another running `customerorderRepository.save()` with a state change — and verify no `OptimisticLockingFailureException`.
- **Existing test check**: `ReleaseOrderJobServiceTest` (if it exists) should be updated to verify the deferred-save pattern.

---

## 8. Files Affected

| File | Change Summary |
|------|---------------|
| `ReleaseOrderJobService.java` | Remove early `save(order)` after `setMarkasvisited`. Re-fetch order at end before final `setState(ASSIGNED)` + `save()`. |
| `PickingorderBusinessService.java` | `finishPickingOrder()`: use `findByIdForUpdate()` for Customerorder load; replace `Set<Customerorder>` with `Set<Long>`. |
| `CustomerorderBatchService.java` | Club flow: change `findById()` to `findByIdForUpdate()` at line 615. |

---

## 9. Review Results

### 9.1 CRITICAL FLAW: Option A's Re-fetch via `findById()` Does Not Work

The plan's Option A proposes:
```java
// At the end:
order = customerorderRepository.findById(orderId).get(); // re-fetch fresh version
```

**This will NOT get a fresh version.** Within the same `REQUIRES_NEW` transaction, Hibernate's first-level cache guarantees entity identity: `findById()` delegates to `em.find()`, which checks the first-level cache first and returns the **cached entity with version N** without hitting the database. The "re-fetch" returns the exact same stale object.

Even `findByIdForUpdate()` (which uses JPQL `@Lock(PESSIMISTIC_WRITE)`) **does not refresh the entity state** in Hibernate 5.x. It executes the SQL and acquires the row lock, but returns the cached managed entity from the first-level cache — still version N. This is Hibernate's "repeatable read" guarantee for the persistence context.

**Only `entityManager.refresh(entity)` forces Hibernate to re-read from the database and update the managed entity's field values (including `version`).** `ReleaseOrderJobService` does not currently inject `EntityManager`.

**Corrected Option A:**
1. Inject `EntityManager` into `ReleaseOrderJobService`
2. Remove early `order.setMarkasvisited(true)` + `save(order)` at lines 177-179 and the state changes at lines 186-187, 436-440. Track needed changes in local variables.
3. At the end (around line 541), call `entityManager.refresh(order)` to reload from DB with the current version.
4. Apply all tracked changes (`markasvisited`, state) to the refreshed entity.
5. Call `customerorderRepository.save(order)` — the flush now uses the correct version from DB.

```java
// At the end, instead of findById:
entityManager.refresh(order); // re-reads from DB, updates version + all fields
order.setMarkasvisited(true);
if (order.getState() < WmsConstants.State.ASSIGNED) {
    order.setState(WmsConstants.State.ASSIGNED);
}
order = customerorderRepository.save(order);
```

**Alternative to `entityManager.refresh()`:** Use `entityManager.detach(order)` immediately after loading at line 79. This removes the entity from the first-level cache, so native query auto-flushes won't touch it. At the end, `findById()` will go to the DB (no cache entry) and return a fresh entity. However, this is fragile — any accidental `save(order)` during processing would re-attach the entity and recreate the problem.

**Recommendation:** `entityManager.refresh(order)` at the end is the safest approach. It's explicit, localized, and doesn't require restructuring intermediate saves.

### 9.2 Early Returns Break the Deferred-Save Pattern

The plan proposes deferring all `Customerorder` modifications to the end. But `releaseOrder()` has **multiple early return paths** that depend on the entity being saved:

| Line | Early Return Condition | Customerorder Modification |
|:-----|:-----------------------|:---------------------------|
| 87 | `order.getState() >= ASSIGNED` | None (safe) |
| 93 | Future picking date | None (safe) |
| 179 | Always (after first loop) | `setMarkasvisited(true)` + `save()` |
| 186-193 | Unsatisfied positions + not processAnyways | `setState(RAW_ON_HOLD)` + `save()` + `customerOrderOnHold()` |
| 436-445 | Second round unsatisfied positions | `setState(RAW_ON_HOLD)` + `save()` + `customerOrderOnHold()` |

Lines 186-193 and 436-445 set the order to `RAW_ON_HOLD` and call `manageOrderService.customerOrderOnHold()` which sends an OMS notification. These are **functional side-effects** that cannot simply be deferred — they must execute when the condition is detected. The `markasvisited` at line 179 also serves a functional purpose: it prevents the order from going through the first-round calculations on the next cron cycle.

**Impact on Option A:** The deferred-save approach cannot be a simple "move all saves to the end." Each early return path must be handled:
- For the `markasvisited` save at line 179: This is the primary conflict point. It could be deferred IF we also defer the early return at line 193 (move the `containsUnsatisfiedPosition` check to after native query execution). But this changes the method's control flow significantly.
- For the `RAW_ON_HOLD` saves at lines 186-193 and 436-445: These trigger OMS notifications and cannot be deferred past the return point.

**Revised approach for each early return:**
- Line 179 (`markasvisited`): Use `entityManager.refresh(order)` BEFORE the save to get the current version, then save. This narrows the stale window to microseconds.
- Lines 186-193 and 436-445 (`RAW_ON_HOLD`): Same pattern — `refresh` before the save.
- Lines 541-543 (final `ASSIGNED`): Same pattern — `refresh` before the save.

### 9.3 Additional Native Query Flush Points Not Documented

The plan identifies lines 225 (`getStockUnitAvailable`) and 458 (`pickingOrderService.create()` → `getNextId()`). There are additional native query flush points in the second loop:

| Line | Method | Native Query? |
|:-----|:-------|:-------------|
| 225 | `stockunitRepository.getStockUnitAvailable()` | Yes (`nativeQuery = true`) |
| 458/52 | `pickingorderRepository.getNextId()` (via `pickingOrderService.create()`) | Yes (`select nextval('seqentities')`, `nativeQuery = true`) |
| 483 | `stockunitRepository.getStockUnitsByItemDataId()` | Yes (`nativeQuery = true`) |

Additionally, `basicService.showLog()` was previously a native query flush point (called ~30+ times in this method), but our earlier fix (`commit f0bef13`) cached the result with a 30s TTL, so it now only triggers one DB call per cycle instead of 30+. **This significantly reduces the number of flush points**, though it doesn't eliminate the core issue.

### 9.4 Section 4.1 — `finishPickingOrder()` Lock Assessment is Overstated

The plan recommends adding `findByIdForUpdate()` for the Customerorder load in `finishPickingOrder()` (line 125). However:

- **Primary path** (`confirmPick()` → `finishPickingOrder()`): The `confirmPick()` method at line 242 already acquires `findByIdForUpdate()` on the Customerorder **before** calling `finishPickingOrder()`. Since both run in the same transaction, the pessimistic lock is already held. The `findById()` at line 125 returns the already-locked entity from the first-level cache. **No change needed for this path.**

- **Secondary paths** (`AdminActionController:226`, `CustomerorderService:310`, `MobilePickingService:189,266,318,470`): These callers do NOT acquire a lock before calling `finishPickingOrder()`. These are genuine risk paths.

**Corrected recommendation:** The `findByIdForUpdate` fix is valid but only for the secondary paths. The plan should note that the primary `confirmPick()` path is already protected. Priority should be **LOW** (not MEDIUM), since the secondary paths are admin/edge-case flows with lower concurrency.

### 9.5 Section 4.2 — HashSet Dedup Fix is Correct and Important

**Confirmed.** `Customerorder` has no `equals()`/`hashCode()`, so `Set<Customerorder>` with `HashSet` uses Object reference equality. If `findById()` at line 125 returns the same cached instance (which it does within the same transaction), the `contains()` check works correctly. However, if `findByIdForUpdate()` is introduced (as suggested in 4.1), or if the entity is ever detached and re-loaded, different object references would bypass the dedup.

**The fix to use `Set<Long>` is correct, low-risk, and should be applied regardless.** It removes a latent bug that could manifest if the code is ever refactored.

### 9.6 Section 4.4 — `CustomerorderBatchService` Re-fetch is Already Correct

The plan suggests changing `findById()` to `findByIdForUpdate()` at line 615. However, the code at line 615 uses `findById(staleOrder.getId())` where `staleOrder` comes from the `orders` list populated **earlier in the same method**. Since `CustomerorderBatchService` has class-level `@Transactional`, the entity IS in the first-level cache.

But looking more carefully: the `orders` list is populated from `customerorderRepository.findByOrderbatchIdAndState()` (earlier in the method). These entities are managed. At line 615, `findById()` returns the same cached entity — it does NOT re-read from DB. The variable name `staleOrder` is misleading; the "re-fetch" is a no-op.

**Corrected assessment:** The re-fetch at line 615 does not actually refresh the entity. If true freshness is needed (e.g., to detect concurrent cancellation), `entityManager.refresh(order)` would be required. However, since `CustomerorderBatchService` is `@Transactional` at class level and club runs are typically non-concurrent, the risk is genuinely low. **Keep as LOW priority, but note the re-fetch is illusory.**

### 9.7 Updated Implementation Priority

| # | Fix | Priority | Change from Original |
|---|-----|----------|---------------------|
| 1 | `ReleaseOrderJobService.releaseOrder()` — inject `EntityManager`, use `refresh(order)` before each `save(order)` | **HIGH** | Changed: `findById()` → `entityManager.refresh()` |
| 2 | `PickingorderBusinessService.finishPickingOrder()` — fix `Set<Customerorder>` → `Set<Long>` dedup | **MEDIUM** | Unchanged |
| 3 | `PickingorderBusinessService.finishPickingOrder()` — `findByIdForUpdate()` for secondary callers | **LOW** | Downgraded from MEDIUM: primary path already locked |
| 4 | `CustomerorderBatchService` club flow — `entityManager.refresh()` if true freshness needed | **LOW** | Changed: `findByIdForUpdate()` → note re-fetch is illusory |
| 5 | `MobilePickingService` post-finish save — defensive re-fetch | **LOW** | Unchanged |

---

## 10. Implementation Status (2026-04-01)

### Completed Fixes

- [x] ~~**Fix #1** (HIGH): Injected `EntityManager` into `ReleaseOrderJobService`. Added `entityManager.refresh(order)` before each save point.~~ **SUPERSEDED** by pessimistic lock approach — see `260401-order-release-definitive-fix-plan.md`. The `refresh()` approach was insufficient because auto-flush at native query points could re-flush the entity against a stale version even between save points. Replaced with `findByIdForUpdate()` pessimistic lock on load.
- [x] **Fix #2** (MEDIUM): Replaced `Set<Customerorder>` with `Set<Long> processedOrderIds` in `finishPickingOrder()`, using `customerOrder.getId()` for dedup instead of object reference equality.
- [x] **Fix #3** (LOW): Changed `customerorderRepository.findById()` to `findByIdForUpdate()` at line 125 of `finishPickingOrder()` to protect secondary callers.
- [x] Tests updated: `PickingorderBusinessServiceUnitTest` (updated `findById` → `findByIdForUpdate` in finishPickingOrder tests)
- [x] Full test suite: 1603 tests, 0 failures, 2 pre-existing errors (unrelated `ViewDtoServiceUnitTest`), 0 skipped
- [ ] Fix #4 (LOW): `CustomerorderBatchService` club flow — deferred
- [ ] Fix #5 (LOW): `MobilePickingService` post-finish save — deferred
- [ ] Verify in staging

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java` | `findById` → `findByIdForUpdate` (pessimistic lock), removed `EntityManager` and `refresh()` calls, removed redundant save |
| `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | `Set<Customerorder>` → `Set<Long>`, `findById` → `findByIdForUpdate` in `finishPickingOrder()` |
| `src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java` | 24x `findById` → `findByIdForUpdate` mocks |
| `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java` | Updated `findById` → `findByIdForUpdate` mocks in finishPickingOrder tests |
