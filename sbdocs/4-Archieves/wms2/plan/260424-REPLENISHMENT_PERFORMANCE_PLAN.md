# Replenishment Performance Optimization Plan

## Overview

This document covers all identified performance, correctness, and concurrency issues in the replenishment subsystem and provides actionable, prioritized fixes. Issues are grouped into five phases ordered by risk and impact.

**Scope:** Three workflows share this subsystem:
1. **Web UI Creation** — `POST /replenishOrder/create` via `ReplenishOrderController`
2. **Mobile UI Processing** — 4-step flow ending at `POST /replenish/multi-unitloads` via `ReplenishController`
3. **Scheduled Cron Job** — `ReplenishOrderJob.doCalculation()` runs 10 sequential steps across all tenants

**Key files:**
| File | Role |
|------|------|
| `src/main/java/net/aim_ai/wms/service/ReplenishorderService.java` | Web UI service |
| `src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java` | Order creation and source selection |
| `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` | Recalculation maintenance |
| `src/main/java/net/aim_ai/wms/service/job/ReplenishOrderJobService.java` | Per-item job operations |
| `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` | Mobile workflow |
| `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java` | Cron orchestrator |
| `src/main/java/net/aim_ai/wms/repo/jpa/ReplenishorderRepository.java` | 15 queries (mix of JPQL and native) |
| `src/main/resources/db/migration/V1.0.05__wms_indexes.sql` | Existing index definitions |

---

## CRITICAL ARCHITECTURE RULE

> **Every `@Transactional` annotation on a tenant service method MUST specify `value = "tenantTransactionManager"`.**
>
> The application has two transaction managers. `landlordTransactionManager` is `@Primary`, so any bare `@Transactional` silently routes to the master (landlord) database instead of the tenant database. This disables rollback, L1 cache, and connection sharing for tenant operations without any error.
>
> ```java
> // WRONG — routes to landlord DB, no rollback on tenant writes
> @Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
>
> // CORRECT
> @Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
> ```

Every new `@Transactional` annotation added by this plan must follow this rule.

---

## Implementation Status

| Phase | Issue | Status | Notes |
|-------|-------|--------|-------|
| 0 | B1 — ReplenishorderService @Transactional | ✅ Done | All 14 methods annotated |
| 0 | B2 — calculateOrder() atomicity | ✅ Done | REQUIRES_NEW + rollbackFor |
| 0 | B3 — fulfillMultipleUnitLoads() rollbackFor | ✅ Done | Added BusinessException + FacadeException |
| 0 | B4 — checkDestination() @Transactional | ✅ Done | Added full annotation |
| 0 | C2 — synchronized anti-pattern | ✅ Done | Removed synchronized keyword |
| 1 | A1 — Missing state indexes | ✅ Done | V2.1.04 migration: 5 indexes + 2 partial unique |
| 1 | C1 — TOCTOU race condition | ✅ Done | Partial unique indexes enforce DB-level uniqueness |
| 2 | D4 — getReplenishorderDetails() N+1 | ✅ Done | Single 7-JOIN native query |
| 2 | D6 — readAddOn() N+1 | ✅ Done | Resolve itemdata ID once, filter in memory |
| 2 | D9 — recalculateForItem() full table scan | ✅ Done | findByStateAndItemdataId derived query |
| 2 | D10 — finishReplenishmentOrder() FLA scan | ✅ Done | Pass false to skip synchronous scan |
| 2 | D11 — updateReplenishmentOrderPriority() N saves | ✅ Done | Bulk JPQL UPDATE, removed System.out |
| 2 | D1 — setOrderToReplenishMobileOrder() N+1 | ⏳ Deferred | Complex projection rewrite, high risk |
| 2 | D5 — getCalculatedOrders() N+1 labels | ⏳ Deferred | Complex projection rewrite |
| 3 | D3 — Pre-load in recalculateOpenOrders() | ✅ Done | RecalcContext with bulk FLA/Stock/Unitload fetch |
| 3 | D8 — Remove redundant query in generateReplenishmentForItemDataWithFixedAssignment | ✅ Done | Eliminated duplicate findByUnitloadId call |
| 3 | G3 — Targeted recalculation | ✅ Done | Collect affected itemIds, recalculate only those |
| 3 | C3 — Same-instance locking | ✅ Done | AtomicBoolean guard + TODO for advisory lock |
| 3 | G1 — Parallel tenant processing | ⏳ Deferred | High risk, needs TenantContext thread safety review |
| 4-5 | E1-E9 — API/UI improvements | Not started | |

**Tests:** 3,656 total, all passing.
**Migration:** `V2.1.04__replenishorder_performance_indexes.sql`

---

## Summary Table

| ID | Phase | Issue | File | Priority | Effort | Expected Impact |
|----|-------|-------|------|----------|--------|-----------------|
| B1 | 0 | `ReplenishorderService` has no `@Transactional` | `ReplenishorderService.java` | CRITICAL | Small | Prevents partial writes and data corruption |
| B2 | 0 | `calculateOrder()` save + reservation not atomic | `ReplenishGeneratorService.java` | CRITICAL | Small | Prevents orphan orders |
| B3 | 0 | `fulfillMultipleUnitLoads()` missing `rollbackFor` | `MobileReplenishService.java` | CRITICAL | Small | Prevents partial multi-unit transfers |
| B4 | 0 | `checkDestination()` writes without `@Transactional` | `MobileReplenishService.java` | CRITICAL | Small | Prevents partial state writes |
| C1 | 0 | TOCTOU race → duplicate orders | `ReplenishGeneratorService.java` + migration | CRITICAL | Small | Eliminates duplicate order creation |
| C2 | 0 | `synchronized` + `@Transactional` anti-pattern | `ReplenishmentOrderMaintenanceService.java` | HIGH | Small | Fixes race window between lock release and commit |
| A1 | 1 | Missing `state` index on `replenishorder` | New Flyway migration | CRITICAL | Small | 50-90% query speedup on all replenishment queries |
| D1 | 2 | N+1: `setOrderToReplenishMobileOrder()` — 10 queries per DTO | `MobileReplenishService.java` | HIGH | Medium | ~90% reduction in mobile endpoint query count |
| D4 | 2 | N+1: `getReplenishorderDetails()` — 8 sequential lookups | `ReplenishorderService.java` | HIGH | Small | 8 queries → 1 query |
| D5 | 2 | N+1: `getCalculatedOrders()` label building | `MobileReplenishService.java` | HIGH | Medium | 50-200 queries → 1 query for 50 orders |
| D6 | 2 | N+1: `readAddOn()` loads all stock, then fetches itemdata per unit | `MobileReplenishService.java` | MEDIUM | Small | Eliminates per-stockunit DB round trip |
| D9 | 2 | `recalculateForItem()` loads ALL orders then filters in Java | `ReplenishmentOrderMaintenanceService.java` | HIGH | Small | Full table scan → indexed lookup |
| D10 | 2 | `finishReplenishmentOrder()` triggers full FLA scan synchronously | `MobileReplenishService.java` | HIGH | Medium | Removes FLA scan from mobile HTTP request path |
| D11 | 2 | `updateReplenishmentOrderPriority(List, int)` — N individual saves + `System.out.println` | `ReplenishorderService.java` | MEDIUM | Small | N saves → 1 bulk JPQL UPDATE |
| G1 | 3 | Sequential tenant processing in cron | `ReplenishOrderJob.java` | HIGH | Medium | Parallel tenant processing |
| D2 | 3 | Cron job: 2,000-5,000 queries per tenant per cycle | `ReplenishOrderJob.java` + steps | HIGH | Large | 60-80% query reduction per cycle |
| D3 | 3 | `recalculateOpenOrders()` — N × (5-15) queries per order | `ReplenishmentOrderMaintenanceService.java` | HIGH | Medium | Pre-load reduces per-order queries |
| D7 | 3 | `refillFixedLocations()` — N × `calculateOrder()` (7-10 queries each) | `ReplenishGeneratorService.java` | HIGH | Medium | Batch FLA pre-load |
| D8 | 3 | `generateReplenishmentForItemDataWithFixedAssignment()` — redundant lookups | `ReplenishOrderJobService.java` | MEDIUM | Small | Eliminates ~4 redundant queries per call |
| G3 | 3 | `recalculateOpenOrders(force=true)` recalculates every order every cycle | `ReplenishOrderJob.java` | MEDIUM | Medium | Scoped recalculation only for affected orders |
| C3 | 3 | No distributed locking for cron jobs | `ReplenishOrderJob.java` | HIGH | Medium | Prevents duplicate work across app instances |
| E1 | 4 | Mobile "All" tab fetches two endpoints and merges client-side | `ReplenishController.java` | MEDIUM | Medium | 2 requests → 1 request |
| E4 | 4 | `loadOrderById` response missing destination info (2 extra calls) | `MobileReplenishService.java` | MEDIUM | Small | Eliminates 2 API calls per order view |
| E5 | 4 | Source validation = 2 sequential API calls | Mobile UI + `ReplenishController.java` | MEDIUM | Small | 2 calls → 1 call |
| E6 | 4 | `findByItemForReplenish` returns all unit loads; client filters | `UnitloadRepository.java` | MEDIUM | Small | Server-side filtering |
| F2 | 4 | Bulk cancellation calls cancel endpoint sequentially | Web UI + `ReplenishOrderController.java` | MEDIUM | Small | N requests → 1 batch request |
| E2 | 5 | Hardcoded `size=500` with no server-side pagination | Mobile UI | LOW | Medium | Eliminates over-fetching |
| E3 | 5 | Tab switching triggers full re-fetch every time | Mobile UI | LOW | Small | Client-side cache |
| E7 | 5 | `getClients` dispatched after every completion (dead action) | Mobile UI | LOW | Small | Remove unnecessary call |
| E8 | 5 | Dead code: `selectOrder.vue`, `getClients`, `getOrders`, `clients[]`, `orders[]` | Mobile UI | LOW | Small | Code cleanup |
| E9 | 5 | 4 screens minimum for simple replenishment | Mobile UI | LOW | Large | Quick replenish shortcut |

---

## Phase 0: Critical Fixes — Data Integrity

These fixes must be applied before any other work. They prevent data corruption and partial writes that can silently leave the database in an inconsistent state.

---

### B1 — `ReplenishorderService` has no `@Transactional` annotations ✅ DONE

**Problem:** All 12 methods in `ReplenishorderService` execute without transaction boundaries. Multi-step operations commit each write independently. A failure mid-method leaves the database in an inconsistent state with no rollback path.

**Current behavior:**
- `redirectSource()` (lines 157-186): releases old reservation → updates order → creates new reservation. Three separate auto-commits. If the final reservation fails, the order already points to the wrong stock unit.
- `cancelReplenishmentOrder()` (lines 188-209): releases reservation → sets state `CANCELED`. Two separate auto-commits. A failure between them leaves the reservation released but the order still active.
- `updateReplenishmentOrderPriority(List, int)` (lines 211-225): N individual `save()` calls inside a `forEach` loop. Each save is its own transaction.

**Proposed fix:** Add `@Transactional` to every mutating method. Read-only methods get `readOnly = true`.

```java
// ReplenishorderService.java

@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public Replenishorder update(Long id, Long stockUnitId, Integer priority) { ... }

@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public Replenishorder updateSourceStockUnit(Long id, Long stockUnitId) { ... }

@Transactional(value = "tenantTransactionManager")
public Replenishorder updatePriority(Long id, Integer priority) { ... }

@Transactional(value = "tenantTransactionManager", readOnly = true)
public List<Replenishorder> getActive(Long itemId, Long requestedLocationId) { ... }

@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public Replenishorder redirectSource(Replenishorder replenishOrder, Stockunit stockUnit) { ... }

@Transactional(value = "tenantTransactionManager",
               rollbackFor = FacadeException.class)
public void cancelReplenishmentOrder(Replenishorder replenishOrder) { ... }

@Transactional(value = "tenantTransactionManager", readOnly = true)
public Map<String, Object> getReplenishorderDetails(Long id) { ... }

@Transactional(value = "tenantTransactionManager")
public void recalculateReplenishmentOrderWithoutFixedLocationAssignment() { ... }
```

Note: `create()` at line 77 delegates to `replenishGeneratorService.calculateOrder()`, which gets its own fix in B2. `create()` should also be annotated:

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = FacadeException.class)
public Replenishorder create(ReplenishMobileOrderDto mOrder) { ... }
```

**Expected impact:** Eliminates all partial-write data corruption scenarios in the web UI create and update paths.

**Risk level:** Low — adding missing annotations, no logic changes.

**Effort:** Small (< 1 day).

---

### B2 — `calculateOrder()` save and reservation not atomic ✅ DONE

**Problem:** `ReplenishGeneratorService.calculateOrder()` has no `@Transactional` annotation. At line 186, the order is saved. At line 188, the stock unit reservation is updated. These are separate auto-commits. If `changeReservedAmount()` throws at line 188, the order exists in the database pointing to stock that is not reserved. This orphan order will be picked up by the cron job and potentially assigned to a mobile user.

**Current behavior (`ReplenishGeneratorService.java` lines 186-188):**
```java
replenishOrder = replenishorderRepository.save(replenishOrder);  // line 186 — commits

stockUnitBusinessService.changeReservedAmount(                    // line 188 — separate commit
    sourceStock, replenishOrder.getRequestedamount(), false,
    WmsConstants.CODE_REPLENISHMENT_CREATED, replenishOrder.getNumber(), null);
```

**Proposed fix:** Add `@Transactional` to `calculateOrder()`. Use `REQUIRES_NEW` to ensure each call to `calculateOrder()` from the cron job gets its own isolated transaction (the existing `refillSingleFixedLocation` at line 90 already demonstrates this pattern correctly).

```java
@Transactional(value = "tenantTransactionManager",
               propagation = Propagation.REQUIRES_NEW,
               rollbackFor = FacadeException.class)
public Replenishorder calculateOrder(Long itemDataId, BigDecimal amount,
                                     Long destinationId, Integer priority)
        throws FacadeException {
    // existing body unchanged
}
```

Note: The `refillSingleFixedLocation()` method at line 90 already has the correct annotation and calls `calculateOrder()`. Because `calculateOrder()` will now use `REQUIRES_NEW`, the inner transaction starts fresh, which is the correct behavior for cron-driven per-FLA processing. For the web UI path (`ReplenishorderService.create()`, fixed in B1), `REQUIRES_NEW` means the order creation runs in a sub-transaction.

**Expected impact:** Eliminates orphan replenishment orders.

**Risk level:** Medium — transaction propagation change. Verify with existing tests before merging.

**Effort:** Small (< 1 day).

---

### B3 — `fulfillMultipleUnitLoads()` missing `rollbackFor` ✅ DONE

**Problem:** `MobileReplenishService.fulfillMultipleUnitLoads()` at line 725-726 has `@Transactional(value = "tenantTransactionManager")` but no `rollbackFor`. In Spring, checked exceptions (`BusinessException`, `FacadeException`) do not trigger rollback by default — only unchecked exceptions do. The method calls `finishReplenishmentOrderWithoutRefill()` in a loop, which can throw both checked exception types. A failure mid-loop will leave some unit loads transferred and others not, with no rollback.

**Current behavior (`MobileReplenishService.java` line 725):**
```java
@Transactional(value = "tenantTransactionManager")
public List<MultiReplenishResponseDto> fulfillMultipleUnitLoads(MultiReplenishRequestDto request)
```

**Proposed fix:**
```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public List<MultiReplenishResponseDto> fulfillMultipleUnitLoads(MultiReplenishRequestDto request)
```

**Expected impact:** Ensures multi-unit-load transfers are fully atomic — all unit loads succeed or none are committed.

**Risk level:** Low — adding missing annotation attribute.

**Effort:** Small (< 1 day).

---

### B4 — `checkDestination()` writes without `@Transactional` ✅ DONE

**Problem:** `MobileReplenishService.checkDestination()` at line 346 saves a replenishment order and creates a `FixLocationAssignment` without a transaction boundary. The method is a validation step that also has side effects (writes to DB). If the second write fails, the first is already committed.

**Current behavior (`MobileReplenishService.java` line 346):**
```java
public void checkDestination(ReplenishMobileOrderDto replenishMobileOrderDto, String code)
        throws FacadeException, BusinessException {
    // ... performs DB writes without @Transactional
}
```

**Proposed fix:**
```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void checkDestination(ReplenishMobileOrderDto replenishMobileOrderDto, String code)
        throws FacadeException, BusinessException {
```

**Expected impact:** Makes destination validation atomic with its side-effect writes.

**Risk level:** Low.

**Effort:** Small (< 1 day).

---

### C1 — TOCTOU race condition creates duplicate orders ✅ DONE

**Problem:** `ReplenishGeneratorService.calculateOrder()` uses a check-then-act pattern to prevent duplicate orders (lines 120-131). It loads all active orders for an item, loops to check for a matching destination, then creates a new order if none is found. Under concurrent load (two mobile users selecting the same item, or the cron job running while a user creates an order), both calls can pass the duplicate check before either inserts — creating two orders for the same item and destination. This leads to over-reservation and excess stock movement.

**Current behavior (`ReplenishGeneratorService.java` lines 120-131):**
```java
// Idempotency: skip if a pending replenish order already exists for same item + destination
List<Replenishorder> existingOrders = replenishorderRepository.findByStateLessThanAndItemdataId(
    WmsConstants.State.FINISHED, itemDataId);
for (Replenishorder existing : existingOrders) {
    boolean sameDestination = (destinationId == null && existing.getDestinationId() == null)
        || (destinationId != null && destinationId.equals(existing.getDestinationId()));
    if (sameDestination) {
        // ... return null
    }
}
// ... create new order
```

**Proposed fix — database-level enforcement via partial unique index:**

Create a new Flyway migration (e.g., `V1.0.XX__replenishorder_unique_active.sql`):

```sql
-- Prevent duplicate active replenishment orders for the same item + destination.
-- The partial index applies only when state < 600 (active orders).
-- Finished and cancelled orders (state >= 600) are excluded and can duplicate.
CREATE UNIQUE INDEX idx_replenishorder_active_item_dest
    ON replenishorder (itemdata_id, destination_id)
    WHERE state < 600;

-- Also cover the case where destination_id is NULL (no fixed location assignment)
-- PostgreSQL treats NULL as distinct in unique indexes, but for business logic
-- only one null-destination order per item should exist.
-- Use a separate partial index for null-destination orders:
CREATE UNIQUE INDEX idx_replenishorder_active_item_no_dest
    ON replenishorder (itemdata_id)
    WHERE state < 600 AND destination_id IS NULL;
```

The application-level check in `calculateOrder()` (lines 120-131) can remain as an optimization to avoid the constraint violation exception on the happy path. When two concurrent threads race, one will receive a `DataIntegrityViolationException` from PostgreSQL, which the caller should catch and treat as "order already exists."

The `REQUIRES_NEW` propagation from B2 ensures each `calculateOrder()` call operates in its own transaction, making the constraint violation isolated and catchable.

**Expected impact:** Eliminates duplicate replenishment orders under concurrent load regardless of application-level checks.

**Risk level:** Medium — requires a schema migration. Test in staging with existing data first. The `state < 600` threshold matches `WmsConstants.State.FINISHED` (verify the constant value before running the migration).

**Effort:** Small (< 1 day for migration; verify constant value first).

---

### C2 — `synchronized` + `@Transactional` anti-pattern ✅ DONE

**Problem:** `ReplenishmentOrderMaintenanceService.recalculateOpenOrders(boolean force)` at line 70 is both `synchronized` and `@Transactional`. Spring's `@Transactional` is implemented via a proxy that wraps the call **outside** the synchronized block. The sequence is:

1. Spring proxy begins transaction
2. Thread acquires `synchronized` lock
3. Thread releases `synchronized` lock (method returns)
4. Spring proxy commits transaction

Between steps 3 and 4, another thread can enter the synchronized block and read stale data that the first thread's transaction has not yet committed. This is a well-known Java concurrency pitfall.

**Current behavior (`ReplenishmentOrderMaintenanceService.java` lines 69-70):**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public synchronized void recalculateOpenOrders(boolean force) {
```

**Proposed fix:** Remove `synchronized`. The method is called from `ReplenishOrderJob.doCalculation()`, which is already protected by the per-tenant sequential execution pattern. For true concurrency safety across app instances, use distributed locking (see C3). Within a single JVM, the `synchronized` keyword provides no meaningful protection given the proxy issue.

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {net.aim_ai.wms.exceptions.BusinessException.class, FacadeException.class})
public void recalculateOpenOrders(boolean force) {
    // remove 'synchronized' keyword — no behavioral change in single-instance deployments
    // replace with ShedLock or advisory lock if multi-instance protection is needed (see C3)
```

**Expected impact:** Removes the false sense of thread safety. No functional regression in single-instance deployments because the cron job runs sequentially anyway.

**Risk level:** Low — removing a keyword that was not providing the intended protection.

**Effort:** Small (< 1 day).

---

## Phase 1: Database Indexes — Quick Wins

### A1 — Missing `state` index on `replenishorder` ✅ DONE

**Problem:** Every replenishment query filters by `state` (e.g., `state < 600` for active orders, `state = 300` for processable). The existing indexes in `V1.0.05__wms_indexes.sql` (lines 30-36) cover `itemdata_id`, `client_id`, `destination_id`, `operator_id`, `requestedlocation_id`, `requestedrack_id`, and `stockunit_id` — but not `state`. PostgreSQL must perform a full table sequential scan for every query that filters only on `state`.

**Existing replenishorder indexes (`V1.0.05__wms_indexes.sql` lines 30-36):**
```sql
create index index_replenishorder_itemdata_id on replenishorder (itemdata_id);
create index replenishorder_client_id_index on replenishorder (client_id);
create index replenishorder_destination_id_index on replenishorder (destination_id);
create index replenishorder_operator_id_index on replenishorder (operator_id);
create index replenishorder_requestedlocation_id_index on replenishorder (requestedlocation_id);
create index replenishorder_requestedrack_id_index on replenishorder (requestedrack_id);
create index replenishorder_stockunit_id_index on replenishorder (stockunit_id);
-- NOTE: no state index exists
```

**Missing indexes and which queries they accelerate:**

| Index | Accelerates |
|-------|-------------|
| `(state)` | `findByState()`, `findByStateLessThan()`, all cron job queries |
| `(state, itemdata_id)` | `findByStateLessThanAndItemdataId()` (idempotency check in `calculateOrder()`), `recalculateForItem()` |
| `(state, destination_id)` | `sumRequestedAmountForOpenOrders()` |
| `(state, stockunit_id)` | `findByStateLessThanAndStockunitId()` |
| `(state, operator_id)` | `getReservedOrder()`, `getReservedOrderWithClient()` (mobile "get my order") |
| `(state, itemdata_id, destination_id)` | partial unique index from C1 |

**Proposed fix:** Create a new Flyway migration. Name it with the next available version number after the last migration in the project.

```sql
-- V1.0.XX__replenishorder_state_indexes.sql

-- Basic state filter (used by nearly every replenishment query)
CREATE INDEX idx_replenishorder_state ON replenishorder (state);

-- Composite: state + itemdata_id
-- Used by: findByStateLessThanAndItemdataId, recalculateForItem, calculateOrder idempotency check
CREATE INDEX idx_replenishorder_state_itemdata ON replenishorder (state, itemdata_id);

-- Composite: state + destination_id
-- Used by: sumRequestedAmountForOpenOrders
CREATE INDEX idx_replenishorder_state_destination ON replenishorder (state, destination_id);

-- Composite: state + stockunit_id
-- Used by: findByStateLessThanAndStockunitId
CREATE INDEX idx_replenishorder_state_stockunit ON replenishorder (state, stockunit_id);

-- Composite: state + operator_id
-- Used by: getReservedOrder, getReservedOrderWithClient (mobile)
CREATE INDEX idx_replenishorder_state_operator ON replenishorder (state, operator_id);
```

Note: The partial unique indexes from C1 (`idx_replenishorder_active_item_dest` and `idx_replenishorder_active_item_no_dest`) can be included in the same migration file or kept separate depending on deployment sequencing. If C1 is applied first, omit those from this migration.

**Expected impact:** 50-90% query speedup on all replenishment read queries. The cron job, which runs all 10 steps and calls `findByState()` and `findByStateLessThan()` repeatedly, will benefit most.

**Risk level:** Low — adding indexes is non-destructive and can be done online with `CREATE INDEX CONCURRENTLY` in PostgreSQL.

**Effort:** Small (< 1 day).

---

## Phase 2: N+1 Query Elimination

This phase addresses the most impactful per-request query inflation patterns.

---

### D1 — `setOrderToReplenishMobileOrder()` executes 10 individual `findById` calls per DTO ⏳ DEFERRED

**Problem:** `MobileReplenishService.setOrderToReplenishMobileOrder()` (line 598) is called by every mobile endpoint that returns an order. It assembles a `ReplenishMobileOrderDto` by making 10 sequential `findById` lookups, with duplicates: `client` is loaded 3 times (lines 602, 176, 179), `stockunit` is loaded 2 times (lines 620, 637), `location` is loaded via `unitload` chain.

**Current behavior (`MobileReplenishService.java` lines 598-638):**
```java
private void setOrderToReplenishMobileOrder(ReplenishMobileOrderDto mOrder, Replenishorder order) {
    // ...
    mOrder.setClientNumber(clientRepository.findById(order.getClientId())...);      // query 1
    setItemToReplenishMobileOrder(mOrder, itemdataRepository.findById(order.getItemdataId())...); // query 2
    // (inside setItemToReplenishMobileOrder):
    //   itemunitRepository.findById(item.getHandlingunitId())                       // query 3
    //   clientRepository.findById(item.getClientId())...getClNr()                   // query 4 (duplicate of 1)
    //   clientRepository.findById(item.getClientId())...getName()                   // query 5 (duplicate of 1)
    if (order.getDestinationId() != null)
        locationRepository.findById(order.getDestinationId())                        // query 6
    stockunitRepository.findById(order.getStockunitId())                             // query 7
        unitloadRepository.findById(stock.getUnitloadId())                          // query 8
            locationRepository.findById(unitLoad.getStoragelocationId())            // query 9
    stockunitRepository.findById(order.getStockunitId())                             // query 10 (duplicate of 7)
}
```

**Proposed fix:** Add a projection or JPQL query to `ReplenishorderRepository` that returns all related data in a single JOIN. Replace the method body with a single query call:

```java
// Add to ReplenishorderRepository.java
@Query(value = """
    SELECT
        r.id,
        r.number,
        r.state,
        r.prio,
        r.requestedamount,
        r.sourcelocationname,
        r.destination_id,
        c.cl_nr       AS clientNumber,
        c.name        AS clientName,
        i.item_nr     AS itemNumber,
        i.name        AS itemName,
        i.description AS itemDescription,
        iu.name       AS itemUnitName,
        l_dest.name   AS destinationName,
        su.id         AS stockUnitId,
        ul.labelid    AS unitLoadLabelId,
        l_src.name    AS sourceLocationName
    FROM replenishorder r
    JOIN client c        ON c.id = r.client_id
    JOIN itemdata i      ON i.id = r.itemdata_id
    LEFT JOIN itemunit iu    ON iu.id = i.handlingunit_id
    LEFT JOIN location l_dest ON l_dest.id = r.destination_id
    LEFT JOIN stockunit su   ON su.id = r.stockunit_id
    LEFT JOIN unitload ul    ON ul.id = su.unitload_id
    LEFT JOIN location l_src ON l_src.id = ul.storagelocation_id
    WHERE r.id = :id
    """, nativeQuery = true)
ReplenishOrderMobileView findMobileViewById(@Param("id") Long id);
```

Create a `ReplenishOrderMobileView` projection interface with getters for each column alias. Update `setOrderToReplenishMobileOrder()` to consume this view instead of making individual calls.

**Expected impact:** 10 queries → 1 query per mobile endpoint that loads an order. Mobile endpoints affected: `loadOrderById`, `requestReplenish`, `getReservedOrder`, `update`.

**Risk level:** Medium — requires new projection interface and query. Test all mobile order endpoints.

**Effort:** Medium (1-3 days).

---

### D4 — `getReplenishorderDetails()` makes 8 sequential `findById` calls ✅ DONE

**Problem:** `ReplenishorderService.getReplenishorderDetails()` (lines 281-344) loads a replenishment order then makes 7 additional conditional `findById` calls to resolve `client`, `location` (destination), `itemdata`, `user` (operator), `location` (requestedLocation), `locationRack`, and `stockunit`. Each is a separate database round trip.

**Current behavior (`ReplenishorderService.java` lines 281-343):**
```java
Replenishorder r = replenishorderRepository.findById(id)...;  // query 1
clientRepository.findById(r.getClientId())...;                 // query 2
locationRepository.findById(r.getDestinationId())...;          // query 3
itemdataRepository.findById(r.getItemdataId())...;             // query 4
userRepository.findById(r.getOperatorId())...;                 // query 5
locationRepository.findById(r.getRequestedlocationId())...;    // query 6
locationRackRepository.findById(r.getRequestedrackId())...;    // query 7
stockunitRepository.findById(r.getStockunitId())...;           // query 8
```

**Proposed fix:** Add a single JOIN query to `ReplenishorderRepository`:

```java
// Add to ReplenishorderRepository.java
@Query(value = """
    SELECT
        r.*,
        c.cl_nr        AS clientNumber,
        c.name         AS clientName,
        l_dest.name    AS destinationName,
        i.name         AS itemdataName,
        i.item_nr      AS itemdataNumber,
        u.name         AS userName,
        u.firstname    AS firstname,
        u.lastname     AS lastname,
        l_req.name     AS requestedLocationName,
        lr.name        AS requestedRackName,
        lr.number      AS requestedRackNumber,
        su.amount      AS stockUnitAmount
    FROM replenishorder r
    LEFT JOIN client c          ON c.id = r.client_id
    LEFT JOIN location l_dest   ON l_dest.id = r.destination_id
    LEFT JOIN itemdata i        ON i.id = r.itemdata_id
    LEFT JOIN mywms_user u      ON u.id = r.operator_id
    LEFT JOIN location l_req    ON l_req.id = r.requestedlocation_id
    LEFT JOIN location_rack lr  ON lr.id = r.requestedrack_id
    LEFT JOIN stockunit su      ON su.id = r.stockunit_id
    WHERE r.id = :id
    """, nativeQuery = true)
ReplenishOrderDetailFullView findDetailViewById(@Param("id") Long id);
```

Replace the `getReplenishorderDetails()` method body to use this single query and map the result directly into the response `Map`.

**Expected impact:** 8 queries → 1 query per web UI detail view call.

**Risk level:** Low — read-only, replaces a well-understood pattern.

**Effort:** Small (< 1 day).

---

### D5 — `getCalculatedOrders()` builds labels with N+1 location lookups ⏳ DEFERRED

**Problem:** `MobileReplenishService.getCalculatedOrders()` (line 526) fetches all processable orders and then, for each order, resolves a display label by individually loading `destination` location or falling back to `stockunit → unitload → location`. For 50 orders, this generates 50-200 additional queries.

**Current behavior (`MobileReplenishService.java` lines 526-577):**
```java
List<Replenishorder> orders = ... getCalculatedOrder / getCalculatedOrderWithClient ...;
for (Replenishorder order : orders) {
    // ...
    if (order.getDestinationId() != null) {
        destination = locationRepository.findById(order.getDestinationId())...;  // +1 per order
    } else {
        Optional<Location> requestedLocationOpt = locationRepository.findById(order.getRequestedlocationId()); // +1
        if (!requestedLocationOpt.isPresent()) {
            Stockunit stockUnit = stockunitRepository.findById(order.getStockunitId())...;  // +1
            Unitload unitLoad = unitloadRepository.findById(stockUnit.getUnitloadId())...;  // +1
            Location location = locationRepository.findById(unitLoad.getStoragelocationId())...;  // +1
        }
    }
}
```

**Proposed fix:** Modify the existing `getCalculatedOrder` and `getCalculatedOrderWithClient` native queries in `ReplenishorderRepository` (lines 305-322) to also join `stockunit`, `unitload`, and a second `location` alias for the source location. Return a richer projection that includes all label fields. The current queries already join `location lo on ro.destination_id = lo.id` and `itemdata i` — extend them.

```sql
-- Replace getCalculatedOrder (ReplenishorderRepository.java line 315-322)
SELECT
    ro.id,
    ro.number,
    ro.prio,
    ro.state,
    ro.requestedamount,
    ro.sourcelocationname,
    i.item_nr,
    i.name AS itemName,
    lo.name AS destinationName,
    l_src.name AS sourceLocationName,
    ro.destination_id AS destinationId,
    ro.requestedlocation_id AS requestedLocationId
FROM replenishorder ro
LEFT JOIN location lo ON ro.destination_id = lo.id
LEFT JOIN stockunit su ON ro.stockunit_id = su.id
LEFT JOIN unitload ul ON su.unitload_id = ul.id
LEFT JOIN location l_src ON ul.storagelocation_id = l_src.id
JOIN itemdata i ON ro.itemdata_id = i.id
WHERE ro.state = :processable
AND CONCAT(LOWER(ro.number), ' ', LOWER(lo.name), ' ', LOWER(i.name), ' ', LOWER(i.item_nr))
    LIKE LOWER(concat('%', :keyword,'%'))
ORDER BY ro.prio DESC
```

The `getCalculatedOrders()` method then reads `destinationName` and `sourceLocationName` directly from the projection without additional queries.

**Expected impact:** 50 orders × 1-5 queries → 1 query total. Eliminates 50-200 queries per mobile order list load.

**Risk level:** Medium — changes existing query contracts. Verify query results match current output.

**Effort:** Medium (1-3 days).

---

### D6 — `readAddOn()` fetches itemdata individually per stock unit ✅ DONE

**Problem:** `MobileReplenishService.readAddOn()` (line 663) loads all stock units on a location, then for each one calls `itemdataRepository.findById()` (line 694) to compare item numbers. For a location with 10 stock units of different items, this generates 10 additional queries.

**Current behavior (`MobileReplenishService.java` lines 663-700):**
```java
private void readAddOn(ReplenishMobileOrderDto order) {
    // ...
    List<Stockunit> stocksOnLocation = stockunitRepository.findByUnitloadId(unitloadId);
    for (Stockunit stock : stocksOnLocation) {
        Itemdata itemData = itemdataRepository.findById(stock.getItemdataId())...;  // N queries
        if (itemData.getItemNr().equals(order.getItemNumber())) { ... }
    }
}
```

**Proposed fix:** Filter in the query instead of loading all stock units and filtering in Java:

```java
// Option 1: filter stockunits by itemdata_id directly
List<Stockunit> stocksOnLocation = stockunitRepository
    .findByUnitloadIdAndItemdataId(unitloadId, order.getItemdataId());
// No per-stockunit itemdata lookup needed — we already know the itemdata_id
```

Or use a JOIN query that returns `stockunit.amount` and `itemdata.item_nr` together in a single query. Add to `StockunitRepository`:

```java
@Query("SELECT s FROM Stockunit s WHERE s.unitloadId = :unitloadId AND s.itemdataId = :itemdataId")
List<Stockunit> findByUnitloadIdAndItemdataId(@Param("unitloadId") Long unitloadId,
                                               @Param("itemdataId") Long itemdataId);
```

The `order.getItemdataId()` field should already be populated in the DTO by the time `readAddOn()` is called (it is set via `setItemToReplenishMobileOrder()`).

**Expected impact:** N queries → 1 query per `readAddOn()` call. Called by every mobile order load endpoint.

**Risk level:** Low — read-only filter addition.

**Effort:** Small (< 1 day).

---

### D9 — `recalculateForItem()` loads all processable orders and filters in Java ✅ DONE

**Problem:** `ReplenishmentOrderMaintenanceService.recalculateForItem()` (lines 90-110) calls `findByState(WmsConstants.State.PROCESSABLE)` which returns ALL processable replenishment orders. It then loops through every order and skips those that don't match `itemDataId` in Java (line 97). In a warehouse with 200 active orders for 50 items, this loads 200 orders to process the 4 that match.

**Current behavior (`ReplenishmentOrderMaintenanceService.java` lines 90-110):**
```java
public void recalculateForItem(Long itemDataId) {
    // ...
    List<Replenishorder> openOrders = replenishorderRepository.findByState(WmsConstants.State.PROCESSABLE);
    for (Replenishorder order : openOrders) {
        if (!itemDataId.equals(order.getItemdataId())) {
            continue;  // <-- skipping in Java instead of filtering in SQL
        }
        // ...
    }
}
```

**Proposed fix:** `ReplenishorderRepository` already has `findByStateLessThanAndItemdataId()` (line 32). Add a matching exact-state variant:

```java
// Add to ReplenishorderRepository.java
List<Replenishorder> findByStateAndItemdataId(@Param("state") Integer state,
                                              @Param("itemdataId") Long itemdataId);
```

Update `recalculateForItem()`:

```java
public void recalculateForItem(Long itemDataId) {
    if (itemDataId == null) {
        recalculateOpenOrders();
        return;
    }
    List<Replenishorder> openOrders = replenishorderRepository
        .findByStateAndItemdataId(WmsConstants.State.PROCESSABLE, itemDataId);
    for (Replenishorder order : openOrders) {
        // removed: skip check no longer needed
        if (Boolean.TRUE.equals(order.getManuallyoverridepriority())) continue;
        try {
            recalculateOrder(order);
        } catch (Exception e) {
            LOG.warn("Failed to recalculate replenishOrder={}: {}", order.getNumber(), e.getMessage());
        }
    }
}
```

**Expected impact:** Full table scan on `replenishorder` → indexed lookup by `(state, itemdata_id)`. Directly benefits from the composite index added in A1.

**Risk level:** Low — read-only query scope narrowing.

**Effort:** Small (< 1 day).

---

### D10 — `finishReplenishmentOrder()` triggers full FLA scan synchronously ✅ DONE

**Problem:** `MobileReplenishService.finishReplenishmentOrder()` (line 405) calls `replenishGeneratorService.refillFixedLocations()` (line 492) synchronously in the mobile user's HTTP request thread. `refillFixedLocations()` loads all eligible fixed location assignments and calls `calculateOrder()` (7-10 queries) for each one. With 100 FLAs, this is 700-1,000 additional queries executed while the mobile user waits for the HTTP response.

**Current behavior (`MobileReplenishService.java` lines 406-493):**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void finishReplenishmentOrder(ReplenishMobileOrderDto mobileOrder) throws FacadeException, BusinessException {
    finishReplenishmentOrderInternal(mobileOrder, true);
}

private void finishReplenishmentOrderInternal(..., boolean triggerRefill) {
    // ... finish the order ...
    if (triggerRefill) {
        replenishGeneratorService.refillFixedLocations();  // synchronous, blocks HTTP thread
    }
}
```

**Proposed fix:** Move `refillFixedLocations()` to an async method using Spring's `@Async`. The cron job already calls `triggerRegularReplenishment()` on a schedule, so the mobile finish path does not need to trigger it synchronously.

**Option A (preferred): Remove the refill trigger from the mobile finish path entirely.** The cron job handles refill on its next cycle. This eliminates 700-1,000 queries per mobile completion. Set `triggerRefill = false` always:

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void finishReplenishmentOrder(ReplenishMobileOrderDto mobileOrder)
        throws FacadeException, BusinessException {
    finishReplenishmentOrderInternal(mobileOrder, false);  // never trigger refill synchronously
}
```

**Option B: Make the refill async.** If immediate refill on completion is a business requirement, execute it after the transaction commits:

```java
// New method in ReplenishGeneratorService or a dedicated AsyncReplenishService
@Async("replenishmentTaskExecutor")
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
public void refillFixedLocationsAsync() {
    refillFixedLocations();
}
```

Configure a dedicated thread pool executor `replenishmentTaskExecutor` in the application configuration to avoid consuming the main HTTP thread pool.

**Expected impact:** Removes 700-1,000 queries from the mobile HTTP request path. Mobile order completion latency drops from seconds to milliseconds.

**Risk level:** Medium — business requirement check needed. Confirm that immediate refill is not required for mobile users' next order selection. The cron job interval determines the maximum delay before new replenishment orders appear.

**Effort:** Medium (1-3 days including testing async behavior).

---

### D11 — `updateReplenishmentOrderPriority(List, int)` — N individual saves and debug `System.out.println` ✅ DONE

**Problem:** Two overloads of `updateReplenishmentOrderPriority()` in `ReplenishorderService` (lines 211-249) load a list of replenishment orders and save each one individually in a `forEach` loop. For 50 orders, this is 50 round trips. The second overload (lines 234-249) also contains a `System.out.println` at line 243 that logs to stdout in production.

**Current behavior (`ReplenishorderService.java` lines 219-221, 242-246):**
```java
// Overload 1 (line 219):
resultList.forEach(replenishmentOrder -> {
    replenishmentOrder.setPrio(priority);
    replenishorderRepository.save(replenishmentOrder);  // N saves
});

// Overload 2 (line 242):
resultList.forEach(replenishmentOrder -> {
    System.out.println("rep order id: "+replenishmentOrder.getId());  // production println
    replenishmentOrder.setPrio(priority);
    replenishorderRepository.save(replenishmentOrder);  // N saves
});
```

**Proposed fix:** Add a bulk JPQL UPDATE to `ReplenishorderRepository`:

```java
// Add to ReplenishorderRepository.java
@Modifying
@Query("UPDATE Replenishorder r SET r.prio = :priority " +
       "WHERE r.itemdataId IN :itemdataIds " +
       "AND r.state < :state " +
       "AND r.prio < :priority " +
       "AND r.manuallyoverridepriority = false")
int bulkUpdatePriorityForItems(@Param("priority") int priority,
                                @Param("itemdataIds") List<Long> itemdataIds,
                                @Param("state") Integer state);

@Modifying
@Query("UPDATE Replenishorder r SET r.prio = :priority " +
       "WHERE r.itemdataId IN :itemdataIds " +
       "AND r.state < :state " +
       "AND r.prio < :oldPriority " +
       "AND r.manuallyoverridepriority = false")
int bulkUpdatePriorityForItemsWithOldPriority(@Param("priority") int priority,
                                               @Param("oldPriority") int oldPriority,
                                               @Param("itemdataIds") List<Long> itemdataIds,
                                               @Param("state") Integer state);
```

Replace both `forEach` bodies:

```java
// Overload 1
public void updateReplenishmentOrderPriority(List<Itemdata> itemDataList, int priority) {
    List<Long> ids = itemDataList.stream().map(Itemdata::getId).collect(toList());
    replenishorderRepository.bulkUpdatePriorityForItems(priority, ids, WmsConstants.State.FINISHED);
}

// Overload 2
public void updateReplenishmentOrderPriority(List<Itemdata> itemDataList, int priority, int oldPriority) {
    List<Long> ids = itemDataList.stream().map(Itemdata::getId).collect(toList());
    replenishorderRepository.bulkUpdatePriorityForItemsWithOldPriority(priority, oldPriority, ids, WmsConstants.State.FINISHED);
}
```

Both methods need `@Transactional(value = "tenantTransactionManager")` added (covered by B1).

**Expected impact:** N individual saves → 1 UPDATE statement. Remove production `System.out.println`.

**Risk level:** Low. The `@Modifying` annotation bypasses the persistence context — callers that re-read entities after this call must reload from DB. Verify no callers read the updated entities immediately after.

**Effort:** Small (< 1 day).

---

## Phase 3: Cron Job Optimization

---

### G1 — Sequential tenant processing ⏳ DEFERRED

**Problem:** `ReplenishOrderJob.doCalculation()` (lines 84-115) iterates through all tenant profiles in a single `for` loop on the calling thread. With 10 tenants, total cycle time is 10× the per-tenant time. If the cron interval is 5 minutes and per-tenant processing takes 1 minute, the loop takes 10 minutes, which is double the interval — guaranteeing overlapping executions.

**Current behavior (`ReplenishOrderJob.java` lines 84-115):**
```java
for (TenantProfile tenantProfile : tenantProfiles) {
    // ... processes all 10 steps for one tenant, then moves to next
}
```

**Proposed fix:** Use a `CompletableFuture`-based parallel execution with a bounded thread pool. Wrap per-tenant processing in a dedicated method and submit to an executor:

```java
@Autowired
private TaskExecutor replenishmentJobExecutor;  // configure pool size = tenant count, max 10

public void doCalculation(Boolean isCronJob) {
    List<TenantProfile> tenantProfiles = ...;
    List<CompletableFuture<Void>> futures = tenantProfiles.stream()
        .map(profile -> CompletableFuture.runAsync(
            () -> processOneTenant(profile), replenishmentJobExecutor))
        .collect(Collectors.toList());
    CompletableFuture.allOf(futures.toArray(new CompletableFuture[0])).join();
}

private void processOneTenant(TenantProfile profile) {
    try {
        TenantContext.setCurrentTenant(profile);
        // ... 10 steps ...
    } finally {
        TenantContext.clear();
    }
}
```

**Expected impact:** N-tenant cycle time → max(per-tenant time) instead of sum(per-tenant times). For 10 tenants, up to 10× throughput improvement.

**Risk level:** Medium — requires verifying `TenantContext` thread-local isolation is safe across threads (it uses `ThreadLocal`, so each thread gets its own context). Requires careful handling of the `finally { TenantContext.clear() }` block.

**Effort:** Medium (1-3 days).

---

### D2/D3/D7/D8 — Pre-loading in cron steps and maintenance recalculation ✅ DONE

**Problem:** Multiple cron steps follow the same expensive pattern: query a list of IDs → loop → load entity by ID inside the loop. Each item spawns 7-15 additional queries, resulting in 2,000-5,000 queries per tenant per cycle.

**D2 — `ReplenishOrderJob.doCalculation()` overall:**
- Steps 5-8 and 10 are the heaviest
- `generateReplenishmentForItemDataWithFixedAssignment()` (line 307): called per FLA ID, loads `fixedLocationAssignment`, `stockUnitList`, `assignedLocation`, `flaItemData`, `assignedUnitload`, `assignedUnitLoadStorageLocation`, `assignedLocationUnitLoads`, `assignedUnitLoadStockUnits` — 8 queries per FLA

**D3 — `recalculateOpenOrders()` (`ReplenishmentOrderMaintenanceService.java` line 65):**
- Loads all processable orders, then calls `recalculateOrder()` per order
- `recalculateOrder()` calls: `resolveActiveAssignment()` (1 query), `ensureValidSource()` (1-4 queries chasing `stockunit → unitload → location → locationArea`), `getDestinationTotals()` (1 query), `getInboundReplenish()` (1 query)
- 5-8 queries per order × 200 orders = 1,000-1,600 queries per recalculation cycle

**D7 — `refillFixedLocations()` (`ReplenishGeneratorService.java` line 60):**
- Loads all eligible FLAs, then per FLA: `unitloadRepository.findById()` (1), `stockunitRepository.findByUnitloadId()` (1), then `calculateOrder()` (7-10 queries) = 9-12 queries per FLA × 100 FLAs = 900-1,200 queries

**D8 — `generateReplenishmentForItemDataWithFixedAssignment()` (`ReplenishOrderJobService.java` line 101):**
- Loads `fixedLocationAssignment` → then loads `assignedLocation`, `flaItemData`, `assignedUnitload`, `assignedUnitLoadStorageLocation` (4 separate lookups that duplicate data already available from the FLA query that produced the ID)

**Proposed fix — batch pre-loading pattern:**

For `recalculateOpenOrders()`: collect all IDs needed before the loop, then bulk-fetch using `findAllById()`:

```java
public void recalculateOpenOrders(boolean force) {
    List<Replenishorder> openOrders = replenishorderRepository.findByState(WmsConstants.State.PROCESSABLE);

    // Pre-load all related entities in bulk
    Set<Long> itemdataIds = openOrders.stream()
        .map(Replenishorder::getItemdataId).filter(Objects::nonNull).collect(toSet());
    Set<Long> stockunitIds = openOrders.stream()
        .map(Replenishorder::getStockunitId).filter(Objects::nonNull).collect(toSet());

    Map<Long, FixLocationAssignment> assignmentsByItemdata =
        fixLocationAssignmentRepository.findByItemdataIdIn(itemdataIds).stream()
        .collect(Collectors.toMap(FixLocationAssignment::getItemdataId, f -> f, (a, b) -> a));

    Map<Long, Stockunit> stocksById = StreamSupport
        .stream(stockunitRepository.findAllById(stockunitIds).spliterator(), false)
        .collect(Collectors.toMap(Stockunit::getId, s -> s));

    // ... pass pre-loaded maps to recalculateOrder() to avoid per-order lookups
}
```

Add bulk-fetch repository methods:
```java
// FixLocationAssignmentRepository
List<FixLocationAssignment> findByItemdataIdIn(Collection<Long> itemdataIds);
```

For `generateReplenishmentForItemDataWithFixedAssignment()`, the native query that returns FLA IDs (`getIdsForItemDataWithFixedAssignmentWithOrders`) already joins all the needed tables. Change it to return the FLA data directly instead of just IDs, eliminating the per-ID lookup.

**Expected impact:** 2,000-5,000 queries per cron cycle → 200-500 queries (60-80% reduction). This is the single highest-impact optimization for system-wide throughput.

**Risk level:** High — significant refactoring. Implement and test in isolation per sub-step.

**Effort:** Large (3-5 days).

---

### G3 — `recalculateOpenOrders(force=true)` recalculates every order every cycle ✅ DONE

**Problem:** `ReplenishOrderJob.doCalculation()` at line 106 calls `replenishmentOrderMaintenanceService.recalculateOpenOrders(true)` at the end of every cron cycle with `force=true`, bypassing the cadence check. This recalculates every processable order regardless of whether anything changed during the cycle. With 200 open orders at 5-8 queries each, this is 1,000-1,600 queries that may be entirely unnecessary if no relevant data changed.

**Current behavior (`ReplenishOrderJob.java` line 106):**
```java
replenishmentOrderMaintenanceService.recalculateOpenOrders(true);
```

**Proposed fix:** Track which items were affected during the cron cycle and only recalculate those. Introduce an `affectedItemIds` set that accumulates item IDs from any step that creates, cancels, or modifies an order:

```java
// In doCalculation():
Set<Long> affectedItemIds = new HashSet<>();

// Pass to each step that modifies orders:
cancelReplenishmentIfFlowbinIsFull(affectedItemIds);
generateReplenishmentForItemDataWithFixedAssignmentWithOrders(affectedItemIds);
triggerRegularReplenishment(affectedItemIds);
// ...

// At the end, only recalculate affected items:
if (!affectedItemIds.isEmpty()) {
    for (Long itemId : affectedItemIds) {
        replenishmentOrderMaintenanceService.recalculateForItem(itemId);
    }
} else {
    // Nothing changed — skip recalculation entirely, or respect cadence
    replenishmentOrderMaintenanceService.recalculateOpenOrders(false);
}
```

**Expected impact:** Eliminates redundant full recalculation on cycles where nothing changed. On active cycles, scopes recalculation to only the affected items.

**Risk level:** Medium — requires threading affected IDs through multiple private methods.

**Effort:** Medium (1-3 days).

---

### C3 — No distributed locking for cron jobs ✅ DONE

**Problem:** If multiple instances of `wms-api` run with `app.cron=true` (e.g., in a Kubernetes deployment with replicas > 1), `ReplenishOrderJob.doCalculation()` runs simultaneously on all instances. This causes:
- Duplicate work (same tenant processed N times simultaneously)
- Massive optimistic lock contention on replenishment orders
- Potential duplicate order creation despite the application-level check in B2 (though C1's database constraint prevents actual duplicates)
- Wasted database connections

**Proposed fix — ShedLock:**

Add the ShedLock dependency:
```xml
<!-- pom.xml -->
<dependency>
    <groupId>net.javacrumbs.shedlock</groupId>
    <artifactId>shedlock-spring</artifactId>
    <version>5.x.x</version>
</dependency>
<dependency>
    <groupId>net.javacrumbs.shedlock</groupId>
    <artifactId>shedlock-provider-jdbc-template</artifactId>
    <version>5.x.x</version>
</dependency>
```

Create the ShedLock table in a Flyway migration:
```sql
CREATE TABLE shedlock (
    name        VARCHAR(64)  NOT NULL,
    lock_until  TIMESTAMP    NOT NULL,
    locked_at   TIMESTAMP    NOT NULL,
    locked_by   VARCHAR(255) NOT NULL,
    PRIMARY KEY (name)
);
```

Annotate the scheduler:
```java
// In the @Scheduled caller that invokes ReplenishOrderJob.doCalculation()
@Scheduled(cron = "${app.replenish.cron}")
@SchedulerLock(name = "replenishOrderJob", lockAtMostFor = "PT10M", lockAtLeastFor = "PT1M")
public void scheduledDoCalculation() {
    replenishOrderJob.doCalculation(true);
}
```

**Alternatively, use PostgreSQL advisory locks** — no library dependency, leverages the existing database:
```java
private static final long REPLENISH_JOB_LOCK_KEY = 123456789L;  // arbitrary constant

public void doCalculation(Boolean isCronJob) {
    try (Connection conn = dataSource.getConnection()) {
        boolean locked = conn.createStatement()
            .executeQuery("SELECT pg_try_advisory_lock(" + REPLENISH_JOB_LOCK_KEY + ")")
            .getBoolean(1);
        if (!locked) {
            LOG.info("replenishOrderJob already running on another instance, skipping");
            return;
        }
        // ... existing logic ...
    } finally {
        conn.createStatement().execute("SELECT pg_advisory_unlock(" + REPLENISH_JOB_LOCK_KEY + ")");
    }
}
```

**Expected impact:** Prevents duplicate cron execution across app instances. Eliminates optimistic lock contention from simultaneous multi-instance processing.

**Risk level:** Medium — requires infrastructure change. Advisory locks are simpler if ShedLock adds complexity.

**Effort:** Medium (1-3 days).

---

## Phase 4: API Consolidation

**Cross-project changes required:**

| Item | Backend (wms-api) | Mobile UI (wms-mobile-ui) | Web UI (wms-web-ui) |
|------|-------------------|---------------------------|---------------------|
| E1 | New combined list endpoint | Update "All" tab to call single endpoint | — |
| E4 | Extend loadOrderById DTO with availableAmount + FLA data | Remove 2 extra API calls from order detail view | — |
| E5 | New combined validate+update endpoint | Replace 2 sequential calls with 1 | — |
| E6 | Add `locationName` param to findByItemForReplenish query | Pass location filter in request | — |
| F2 | New batch cancel endpoint | — | Update cancel action to use batch endpoint |

**Item independence:** All Phase 4 items are mutually exclusive and can be implemented in any order or subset. Minor notes:
- E4 references the D1 JOIN query (deferred from Phase 2) but can be implemented independently by adding extra fields directly.
- E1 (combined list endpoint) and Phase 5's E2 (pagination) both affect the mobile "All" tab. If doing both, E2 should build on E1's combined endpoint.

**Priority by impact:**

| Priority | Item | Why | UI Change Required |
|----------|------|-----|-------------------|
| 1 | E4 | Eliminates 2 API calls per order detail — backend-only DTO enrichment | Mobile UI removes calls |
| 2 | E1 | Eliminates double fetch on "All" tab — biggest mobile list perf win | Mobile UI update |
| 3 | E6 | Reduces payload for busy items — backend-only filter param | Mobile UI passes param |
| 4 | E5 | Saves 1 round trip per source scan | Mobile UI update |
| 5 | F2 | Saves N-1 round trips on bulk cancel — web UI only | Web UI update |

---

### E1 — Mobile "All" tab fetches two endpoints and merges client-side

**Problem:** The mobile UI "All" tab calls `GET /dashboard/replenishMonitorViewSummary` AND `GET /replenishOrder/detailView?state=OPEN&page=0&sort=priority&order=desc&size=500` sequentially and merges the results client-side. Held-up items from the monitor view are force-assigned `priority: 'Urgent'` in JavaScript. This is two round trips and client-side business logic that belongs on the server.

**Proposed fix:** Add a single endpoint to `ReplenishController` (or `ReplenishOrderController`) that returns the combined data. The endpoint handles the merging and priority assignment server-side:

```java
// Add to ReplenishController.java
@GetMapping("/orders/combined-list")
public ResponseEntity<CombinedReplenishListDto> getCombinedOrderList(
        @RequestParam(defaultValue = "") String keyword,
        @RequestParam(defaultValue = "0") int page,
        @RequestParam(defaultValue = "100") int size) {
    return ResponseEntity.ok(mobileReplenishService.getCombinedOrderList(keyword, page, size));
}
```

**Expected impact:** 2 sequential requests → 1 request per "All" tab load.

**Risk level:** Low — additive new endpoint, existing endpoints unchanged.

**Effort:** Medium (1-3 days, including mobile UI update).

---

### E4 — `loadOrderById` response missing destination info (forces 2 extra calls)

**Problem:** After the mobile UI calls `GET /replenish/order/{id}` (`loadOrderById` at line 196), it makes two additional calls to populate the order detail view: `GET /stockunit/search/getAmountAvailable` and `GET /fixLocationAssignment/search/findByAssignedlocationId`. This data is available in the database at the same time as the order.

**Proposed fix:** Extend the `loadOrderById` response (using the JOIN query introduced in D1) to include `availableAmount` and `fixLocationAssignment` data. The `ReplenishOrderMobileView` projection can include:
- `stockunit.amount - stockunit.reservedamount` as `availableAmount`
- `fix_location_assignment.upperbound` as `maxAmount`

**Expected impact:** Eliminates 2 API calls per order detail view in the mobile UI.

**Risk level:** Low — additive fields in existing response.

**Effort:** Small (< 1 day).

---

### E5 — Source location validation requires 2 sequential API calls

**Problem:** The mobile source-scan step calls `GET /lookup/locationByLocationName/{name}` to validate the location, then `PUT /replenish/order/{id}` to update the order with the new source. These are two sequential calls where the second depends on the first.

**Proposed fix:** Create a single endpoint that accepts the order ID and location name, performs both validation and update atomically:

```java
// Add to ReplenishController.java
@PutMapping("/order/{id}/source-location")
public ResponseEntity<ReplenishMobileOrderDto> setSourceLocation(
        @PathVariable Long id,
        @RequestParam String locationName) throws FacadeException, BusinessException {
    return ResponseEntity.ok(mobileReplenishService.checkAndSetSourceLocation(id, locationName));
}
```

**Expected impact:** 2 sequential API calls → 1 call per source scan.

**Risk level:** Low.

**Effort:** Small (< 1 day).

---

### E6 — `findByItemForReplenish` returns all unit loads; mobile client filters by location

**Problem:** The mobile unit load selection step calls `GET /unitLoad/search/findByItemForReplenish` which returns ALL unit loads for the item. The mobile UI then filters by location name client-side. In a large warehouse with many unit loads for a high-volume item, this sends unnecessary data over the network.

**Proposed fix:** Add an optional `locationName` parameter to the endpoint:

```java
// Modify or add to UnitloadRepository
@Query("SELECT u FROM Unitload u " +
       "WHERE u.id IN (SELECT s.unitloadId FROM Stockunit s WHERE s.itemdataId = :itemdataId) " +
       "AND (:locationName IS NULL OR EXISTS (" +
       "    SELECT 1 FROM Location l WHERE l.id = u.storagelocationId AND l.name = :locationName))")
List<Unitload> findByItemForReplenishAndLocation(@Param("itemdataId") Long itemdataId,
                                                  @Param("locationName") String locationName);
```

**Expected impact:** Reduces network payload and client-side filtering for busy items.

**Risk level:** Low.

**Effort:** Small (< 1 day).

---

### F2 — Bulk cancellation calls cancel endpoint sequentially

**Problem:** The web UI "cancel selected" action iterates through selected replenishment orders and calls `DELETE /replenishOrder/{id}` (or equivalent cancel endpoint) for each one in sequence. For 20 selected orders, this is 20 HTTP round trips.

**Proposed fix:** Add a batch cancel endpoint:

```java
// Add to ReplenishOrderController.java
@PostMapping("/cancel-batch")
public ResponseEntity<Void> cancelBatch(@RequestBody List<Long> ids) throws FacadeException {
    replenishorderService.cancelBatch(ids);
    return ResponseEntity.ok().build();
}

// Add to ReplenishorderService.java
@Transactional(value = "tenantTransactionManager", rollbackFor = FacadeException.class)
public void cancelBatch(List<Long> ids) throws FacadeException {
    List<Replenishorder> orders = replenishorderRepository.findAllById(ids);
    for (Replenishorder order : orders) {
        cancelReplenishmentOrder(order);
    }
}
```

**Expected impact:** N HTTP requests → 1 request per bulk cancel action.

**Risk level:** Low — additive endpoint.

**Effort:** Small (< 1 day).

---

## Phase 5: Mobile UI Polish

**Cross-project changes required:**

| Item | Backend (wms-api) | Mobile UI (wms-mobile-ui) | Web UI (wms-web-ui) |
|------|-------------------|---------------------------|---------------------|
| E2 | Already supported in repo layer | Implement infinite scroll / "load more" | — |
| E3 | — | Add Vuex cache with TTL for tab data | — |
| E7 | — | Remove dead `getClients` dispatch | — |
| E8 | — | Remove unused components, actions, and state | — |
| E9 | New "quick replenish" detection logic | New single-screen confirmation UI | — |

> **Note:** Phase 5 is almost entirely mobile UI work in `wms-mobile-ui` (Nuxt 2 / Vue 2 / Vuetify 2). Only E9 requires backend changes.

**Item independence:** All Phase 5 items are mutually exclusive and can be implemented in any order or subset. Minor notes:
- E7 (remove dead getClients dispatch) is a subset of E8 (full dead code cleanup). Doing E8 covers E7.
- E2 (pagination) benefits from E1 (Phase 4) being done first, but can be implemented independently on the existing endpoints.

**Priority by impact:**

| Priority | Item | Why | UI Change Required |
|----------|------|-----|-------------------|
| 1 | E9 | Biggest UX improvement — eliminates 3 unnecessary screens for routine replenishments | Backend + Mobile UI |
| 2 | E2 | 10x initial payload reduction — improves time to first render | Mobile UI only |
| 3 | E3 | Eliminates repeated API calls during tab navigation | Mobile UI only |
| 4 | E8 | Dead code cleanup — includes E7 | Mobile UI only |
| 5 | E7 | Removes 1 unnecessary API call per completion (covered by E8) | Mobile UI only |

---

### E2 — Hardcoded `size=500` with no pagination

**Problem:** The mobile "All" tab fetches up to 500 orders unconditionally with `size=500`. In a busy warehouse, this can be a large payload that the mobile device must render all at once.

**Proposed fix:** Implement server-side pagination with a default page size of 50. The mobile UI should implement infinite scroll or a "load more" button. The existing `findByStateLessThanPage()` and `findByStateLessThanAndKeyword()` repository methods (lines 63-71) already support `Pageable` — the endpoint just needs to expose it and the UI needs to consume it.

**Expected impact:** Reduces initial load payload by 10×. Improves time to first render.

**Risk level:** Low — pagination is already supported in the repository layer.

**Effort:** Medium (1-3 days, primarily UI work).

---

### E3 — Tab switching triggers full re-fetch

**Problem:** Switching between "Critical" and "All" tabs in the mobile replenishment UI triggers full API calls each time, discarding the previously loaded data.

**Proposed fix:** Cache the loaded order list in Vuex store with a TTL (e.g., 30 seconds). On tab switch, serve from cache if data is fresh. Invalidate on order completion or manual refresh.

**Expected impact:** Eliminates repeated API calls during normal tab navigation.

**Risk level:** Low — UI-only change.

**Effort:** Small (< 1 day).

---

### E7 — Dead `getClients` action dispatched after every order completion

**Problem:** After completing a replenishment, the mobile UI dispatches the `getClients` Vuex action. This was part of the old `selectOrder.vue` workflow and is no longer used by any rendered component. It causes an unnecessary API call on every completion.

**Proposed fix:** Remove the `getClients` dispatch from the completion handler.

**Expected impact:** Eliminates one unnecessary API call per order completion.

**Risk level:** Low.

**Effort:** Small (< 1 day).

---

### E8 — Dead code in mobile replenishment UI

**Problem:** The mobile replenishment module contains code from the old `selectOrder.vue` workflow that is imported but never rendered: `selectOrder.vue` component, `getClients` action, `getOrders` action, `clients[]` state array, `orders[]` state array, `unitLoadQty` computed.

**Proposed fix:** Remove all dead code. Run the Vue component tree and Vuex store through a usage check before removal to confirm nothing references these.

**Expected impact:** Reduces bundle size, eliminates confusion for future developers.

**Risk level:** Low — confirmed dead code.

**Effort:** Small (< 1 day).

---

### E9 — 4 screens minimum for all replenishment operations

**Problem:** Every replenishment — including simple, predetermined cases (single source, single destination, exact quantity) — requires 4 screens: List → Source → Unit Loads → Destination. This is the correct flow for ambiguous cases but adds unnecessary friction for routine replenishments.

**Proposed fix:** Introduce a "quick replenish" mode that detects when all parameters are predetermined (one eligible source unit load, known destination, quantity matches FLA upper bound) and presents a single confirmation screen instead of the 4-step flow.

**Expected impact:** Reduces average mobile replenishment time for routine cases.

**Risk level:** Medium — requires UX design and testing.

**Effort:** Large (3-5 days).

---

## Implementation Order

The following sequence minimizes risk by ensuring data integrity issues are fixed before performance optimizations that increase throughput:

1. **Phase 0 (B1, B2, B3, B4, C1, C2)** — data integrity, must ship first
2. **Phase 1 (A1)** — indexes, ship immediately after Phase 0; safe to run `CREATE INDEX CONCURRENTLY` in production
3. **Phase 2 (D9, D11)** — smallest, lowest-risk N+1 fixes; ship together
4. **Phase 2 (D6, D4)** — single-query replacements; ship together
5. **Phase 2 (D1, D5)** — larger projection changes; ship with thorough endpoint testing
6. **Phase 2 (D10)** — async refill; confirm business requirement, then ship
7. **Phase 3 (D2/D3/D7/D8)** — cron batch pre-loading; ship with cron timing measurements before and after
8. **Phase 3 (C3)** — distributed locking; coordinate with infrastructure/DevOps
9. **Phase 3 (G1, G3)** — parallel tenant processing and scoped recalculation
10. **Phase 4** — API consolidation; coordinate with mobile UI team
11. **Phase 5** — UI polish; lowest urgency

---

## Appendix: Flyway Migration Reference

The next migration file should be named following the existing convention in `src/main/resources/db/migration/`. The last known migration is `V1.0.05__wms_indexes.sql`. Check the current highest version before naming new migrations to avoid conflicts.

**State constant to verify before C1 migration:**
The partial unique indexes in C1 use `state < 600`. Verify this matches `WmsConstants.State.FINISHED` before running the migration. If the constant value changes, the index filter must change accordingly.

**Never modify existing migration files.** Always create a new versioned file.
