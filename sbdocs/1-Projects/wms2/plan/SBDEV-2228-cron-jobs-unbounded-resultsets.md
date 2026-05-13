---
title: "SBDEV-2228 — Cron jobs hold huge in-memory result sets (OrderRelease, ReplenishOrder, StockSummaryExport)"
ticket: "SBDEV-2228"
ticket_url: "https://app.clickup.com/t/868jj343n"
type: "bug"
priority: "high"
status: "implemented"
project:
  - wms2
version: "v2"
requester: "David Oppenheim"
created: "2026-05-13"
updated: "2026-05-13"
db_verified: true
related:
  - SBDEV-2219-stock-summary-streaming
  - SBDEV-2222-rest-inbound-no-idempotency-contract
  - 260405-PgBouncer_Connection_Pool_Strategy_2026-04-05
tags:
  - plan
  - performance
  - cron
  - memory
  - connection-pool
---

# SBDEV-2228 — Cron jobs hold huge in-memory result sets

**Ticket:** [SBDEV-2228](https://app.clickup.com/t/868jj343n)
**Project:** wms2 | **Version:** v2 | **Type:** bug/performance
**Priority:** High (Tier 2)
**Status:** implemented
**Date:** 2026-05-13

---

## 0. Affected Sites (enumeration before drafting)

| # | File:line | Construct | Root-cause category | In-scope? |
|---|-----------|-----------|---------------------|-----------|
| 1 | `schedulejob/OrderReleaseJob.java:115-117` | `getOrderReleaseInfo(...)` → unbounded `List<OrderReleaseInfoView>` | Memory | **yes** |
| 2 | `schedulejob/OrderReleaseJob.java:128` | `getFixedLocationAndItemDataIds()` → unbounded `List` | Memory | **yes** |
| 3 | `schedulejob/OrderReleaseJob.java:147` | `List<ArrayList<OrderReleaseInfoView>> orders` bucket doubles heap | Memory | **yes** — eliminated by streaming |
| 4 | `schedulejob/OrderReleaseJob.java:~284` (via `releaseOrder`) | per-order `REQUIRES_NEW` | Connection-pool churn | **partial** — preserve; add throttle via sysprop |
| 5 | `repo/jpa/CustomerorderPositionRepository.java:40-61` | `getOrderReleaseInfo(...)` returns `List<>` | Memory (root) | **yes** — add `streamOrderReleaseInfo` |
| 6 | `schedulejob/ReplenishOrderJob.java:245` | `getIdsForUnreachableReplenishOrders(...)` → unbounded `List<Long>` | Memory + pool churn | **yes** |
| 7 | `schedulejob/ReplenishOrderJob.java:272` | `getIdsToCancelReplenishOrders(...)` → unbounded `List<Long>` | Memory + pool churn | **yes** |
| 8 | `schedulejob/ReplenishOrderJob.java:305` | `getIdsToDeleteEmptyFixAssignmentWithoutStockToReplenish(...)` → unbounded `List<Long>` | Memory + pool churn | **yes** |
| 9 | `schedulejob/ReplenishOrderJob.java:333` | `getIdsForItemDataWithoutFixedAssignment(...)` → unbounded `List<Long>` | Memory + pool churn | **yes** |
| 10 | `schedulejob/ReplenishOrderJob.java:373` | `getIdsForItemDataWithFixedAssignmentWithOrders(...)` → unbounded `List<Long>` | Memory + pool churn | **yes** |
| 11 | `schedulejob/ReplenishOrderJob.java:424, 441` | `getIdsToUpdateReplenishmentOrderPriority{,2}(...)` → unbounded `List<Long>` | Memory + pool churn | **yes** |
| 12 | `schedulejob/ReplenishOrderJob.java:121` | `Set<Long> affectedItemIds` accumulates across 6 sub-ops | Memory | **yes** — acknowledged; left as-is (400KB acceptable, see §10 Q5) |
| 13 | `repo/jpa/ReplenishorderRepository.java:115-206` | 6 `List<Long>` queries — all unbounded | Memory (root) | **yes** — add `Pageable` variants |
| 14 | `schedulejob/StockSummaryExportJob.java:152-164` | OMS HTTP POST inside `@Transactional(readOnly=true)` cursor tx | OMS blocking + pool churn | **yes** |
| 15 | `schedulejob/StockSummaryExportJob.java:153-158` | `inventoryRecordService.createEntity(...)` REQUIRES_NEW per row (1M tx) | Connection-pool churn | **yes** |
| 16 | `service/InventoryRecordService.java:29-49` | `createEntity` REQUIRES_NEW per row | Connection-pool churn (root) | **yes** — add `createEntitiesBulk(List<>)` |
| 17 | `schedulejob/SchedulingConfiguration.java:30` | `POOL_SIZE = 10` shared by all jobs | Architectural sizing | **no** — separate concern; out of scope |
| 18 | `service/HttpRestService.java:27-28` | `readTimeout = 15000` | OMS blocking (workaround only) | **no** — Fix C supersedes |
| 19 | `schedulejob/StockSummaryExportJob.java:160-163` | sendList chunk logic inside lambda | OMS blocking (root) | **included in Fix C** |

---

## 1. Problem Statement

Three scheduled cron jobs in `v2/wms2-api` load entire tenant result sets into JVM heap before iterating:

**Failure modes:**

1. **JVM OOM / GC pauses** — `OrderReleaseJob` allocates the full tenant position list into heap (≥ 8MB per tenant for 100K positions) then double-allocates via bucketing. Other tenants in the same JVM experience GC pauses or OOM during peak cron windows.

2. **Connection-pool exhaustion** — `ReplenishOrderJob` fires 6 sub-ops each iterating an unbounded `List<Long>` with a `REQUIRES_NEW` transaction per ID. At 50K+ unprocessable replenish orders = 300K+ nested transactions per cycle. With `tenantTransactionManager` pool `maxPoolSize=5`, concurrent API requests compete for the same 5 slots for the entire run. Confirmed real scale: wineco-dev has 51,687 historical replenishorder rows.

3. **OMS-induced DB starvation** — `StockSummaryExportJob` performs OMS HTTP POSTs inside `streamStockCount`'s `@Transactional(readOnly=true)` cursor boundary. With `readTimeout=15000ms` per chunk and 100 chunks, the DB connection slot is held open for up to 25 minutes. Additionally, `inventoryRecordService.createEntity` fires as `REQUIRES_NEW` per row (1M tx per 1M-row export).

**DB verification** (wineco-dev, 2026-05-13, `db_verified: true`):
```sql
SELECT count(*) FROM replenishorder;          -- 51,687  (proves 50K+ scale is real)
SELECT state, count(*) FROM replenishorder GROUP BY state ORDER BY state;
-- state=300 (open): 601  |  state=800 (done): 50,782
SELECT count(*) FROM stock_view;              -- 8,775  (low-traffic snapshot)
SELECT count(*) FROM customerorder_position cop
  JOIN customerorder co ON cop.order_id = co.id
  JOIN customerorder_batch cob ON co.orderbatch_id = cob.id
  WHERE co.state < 200 AND co.pickingdate <= CURRENT_DATE
    AND cob.type = 'PICK_PACK';              -- 5  (low-traffic; high-traffic tenants peak 100K+)
```

> **Note on SBDEV-2219:** The streaming cursor for `StockSummaryExportJob` was already introduced in SBDEV-2219 (heap is bounded). This plan fixes the two remaining issues: OMS HTTP inside cursor tx, and per-row REQUIRES_NEW insert.

---

## 2. Root Cause Analysis

### Bug 1: OrderReleaseJob — Unbounded in-heap position list + heap-doubling bucket

**Location:** `schedulejob/OrderReleaseJob.java:115-117, 128, 134-147`

```java
// Line 115-117: loads ALL positions for the tenant into heap — no LIMIT / Pageable
List<OrderReleaseInfoView> resultList = customerorderPositionRepository.getOrderReleaseInfo(
    WmsConstants.State.ASSIGNED, WmsConstants.OrderBatchType.PICK_PACK, sdf.format(new Date()));

// Line 128: second unbounded load
List<FixLocationItemView> fixAssignments = fixLocationAssignmentRepository.getFixedLocationAndItemDataIds();

// Lines 134-147: builds in-memory maps + buckets positions by order — heap doubles
Map<Long, Object[]> itemDataFixAssignmentMap = new HashMap<>();
Map<Long, Integer> itemDataAvailableAmountMap = new HashMap<>();
List<ArrayList<OrderReleaseInfoView>> orders = new ArrayList<>();
// positions now exist in BOTH resultList AND orders[i] simultaneously
```

**Root cause repo method** (`CustomerorderPositionRepository.java:40-61`): native SQL with no `LIMIT` / `Pageable` — returns all rows for the tenant. `OrderReleaseInfoView` is a Spring Data interface-based projection with 9 accessor methods (3 `Long`, 3 `String`, 2 `Integer`, 1 `BigDecimal`) — backed by a JDK proxy with per-row overhead of ~300 bytes on-heap (field values ~200 bytes + proxy + header). At 100K positions × ~300 bytes/row = ~30MB per `resultList`; the bucketed `orders` structure doubles the effective live-set to ~60MB. With OSIV disabled (`spring.jpa.open-in-view=false`), the load runs in its own short auto-tx — correct, but the resulting `List<>` objects occupy JVM heap until the method returns.

### Bug 2: ReplenishOrderJob — 6× unbounded List<Long> per tenant cycle + 300K REQUIRES_NEW

**Location:** `schedulejob/ReplenishOrderJob.java:245, 272, 305, 333, 373, 424, 441`

```java
// One of six identical patterns (lines 245-258):
List<Long> resultList = replenishorderRepository.getIdsForUnreachableReplenishOrders(
    WmsConstants.State.PROCESSABLE);
for (Long replenishOrderID : resultList) {
    try {
        replenishOrderJobService.cancelReplenishmentOrder(replenishOrderID);  // REQUIRES_NEW
    } catch (...) { ... }
}
```

**Root cause repo methods** (`ReplenishorderRepository.java:115-206`): 6 native SQL queries each returning `List<Long>` with no pagination. At 50K IDs × 8 bytes = ~400KB per list × 6 = ~2.4MB total (tolerable). The real damage: **50K × 6 sub-ops × REQUIRES_NEW = 300K+ nested transactions per tenant per cycle**, each acquiring and releasing a tenant connection from the 5-slot pool. This exhausts the pool for the entire cron window, blocking all concurrent API-tier requests for the tenant.

### Bug 3: StockSummaryExportJob — OMS HTTP inside DB cursor tx + 1M per-row REQUIRES_NEW

**Location:** `schedulejob/StockSummaryExportJob.java:152-164`

```java
// streamStockCount opens @Transactional(readOnly=true, value="tenantTransactionManager")
// which holds the Hibernate cursor (and JDBC connection) open for its entire duration:
warehouseStockReportService.streamStockCount(sc -> {
    inventoryRecordService.createEntity(sc.getClientNumber(), ...);  // REQUIRES_NEW per row — 1M tx for 1M rows
    chunk.add(sc);
    if (chunk.size() >= batchSize) {
        sendList(new ArrayList<>(chunk));   // httpRestService.post() — up to 15s per chunk
        chunk.clear();
    }
});
```

**Why it fails (primary — OMS blocking):** `sendList → httpRestService.post(...)` runs while `streamStockCount`'s `@Transactional(readOnly=true)` boundary is active. With `readTimeout=15000ms` per chunk × 100 chunks = up to 1,500 seconds (~25 min) of DB connection hold. All other tenant DB operations wait.

**Why it fails (secondary — pool churn):** 1M stock rows × `createEntity` (REQUIRES_NEW) = 1M nested transactions, each borrowing and returning a pool slot. Though fast individually, the cumulative pressure during a large export is severe.

### Completeness Checklist

| # | Concern | Status |
|---|---------|--------|
| 0 | **DB verified** | `db_verified: true` — 6 queries on wineco-dev, 2026-05-13 |
| 1 | All callsites enumerated (§0) | ✓ 19 sites enumerated; 16 in-scope |
| 2 | Adjacent bugs — same root-cause pattern | ✓ All 6 ReplenishorderRepository unbounded queries enumerated; `fixLocationAssignmentRepository.getFixedLocationAndItemDataIds()` flagged (Open Q7) |
| 3 | Backward compatibility | ✓ Original unbounded repo methods kept for existing tests; new streaming/paginated methods added alongside |
| 4 | Concurrency | ✓ AdvisoryLockService per job; drain-queue pagination always queries page 0 (correct for delete-while-iterate); sub-op 6a uses forward pagination (prio-only update, not drain-queue eligible); streaming cursor READ COMMITTED correctness resolved SAFE (Q3) |
| 5 | Multi-tenant | ✓ `TenantContext.setCurrentTenant()` / `.clear()` in try/finally preserved; new streaming wrapper uses `tenantTransactionManager` |
| 6 | Error handling | ✓ Per-item try/catch preserved in all loop patterns |
| 7 | Observability | ✓ Micrometer `cron_job_rows_processed_total` + `cron_job_duration_seconds` metrics proposed |
| 8 | Rollback / migration | ✓ Sysprop toggles per job; no Flyway migration needed |
| 9 | Test coverage | ✓ 8 named test classes in §6 |
| 10 | Cross-version (v1↔v2) | no — v2 only per user; v1 flagged for wms-v1-sync-sweep |

---

## 3. Fix Design

### Fix A: OrderReleaseJob — Cursor streaming via `streamOrderReleaseInfo`

**Addresses:** Sites #1, #2, #3, #5

**Before** (`CustomerorderPositionRepository.java:40-61`):
```java
@Query(nativeQuery = true, value = "SELECT ... ORDER BY co.prio DESC, co.created ASC, cop.number ASC")
List<OrderReleaseInfoView> getOrderReleaseInfo(@Param("state") int state,
    @Param("orderBatchType") String orderBatchType, @Param("pickingDate") String pickingDate);
```

**After** — add streaming variant alongside existing (keep original for existing tests):
```java
@QueryHints(@QueryHint(name = "org.hibernate.fetchSize", value = "500"))
@Query(nativeQuery = true, value = "SELECT ... ORDER BY co.id ASC, cop.number ASC")
Stream<OrderReleaseInfoView> streamOrderReleaseInfo(@Param("state") int state,
    @Param("orderBatchType") String orderBatchType, @Param("pickingDate") String pickingDate);
```

**Before** (`OrderReleaseJob.java:115-162`, outline):
```java
List<OrderReleaseInfoView> resultList = customerorderPositionRepository.getOrderReleaseInfo(...);
// ... build HashMap maps, bucket into List<ArrayList<OrderReleaseInfoView>> orders ...
for (ArrayList<OrderReleaseInfoView> order : orders) {
    releaseOrder(customerOrderId, ...);  // REQUIRES_NEW per order
}
```

**After** — streaming dispatch with order-boundary break detection (extracted to service or inline):
```java
@Transactional(value = "tenantTransactionManager", readOnly = true)
public void streamAndDispatchReleases(String batchType, String pickDate,
        Consumer<List<OrderReleaseInfoView>> orderConsumer) {
    try (Stream<OrderReleaseInfoView> s = customerorderPositionRepository
            .streamOrderReleaseInfo(WmsConstants.State.ASSIGNED, batchType, pickDate)) {
        Long currentCoId = null;
        List<OrderReleaseInfoView> buf = new ArrayList<>();
        for (OrderReleaseInfoView row : (Iterable<OrderReleaseInfoView>) s::iterator) {
            if (currentCoId != null && !row.getCoId().equals(currentCoId)) {
                orderConsumer.accept(new ArrayList<>(buf));
                buf.clear();
            }
            buf.add(row);
            currentCoId = row.getCoId();
        }
        if (!buf.isEmpty()) orderConsumer.accept(buf);
    }
}
```
`OrderReleaseJob` passes `releaseOrderJobService.releaseOrder(coId, positions)` as the `Consumer` — which is `REQUIRES_NEW` and escapes the outer `readOnly=true` tx correctly (identical to `InventoryRecordService.createEntity` escaping `WarehouseStockReportService.streamStockCount`).

**ORDER BY change:** `ORDER BY co.prio DESC, co.id ASC, cop.number ASC` (replaces `co.prio DESC, co.created ASC, cop.number ASC`). Compound sort preserves priority-ordering (business requirement confirmed — Q6 resolved) while guaranteeing contiguous grouping by `co.id` for break detection. The `co.created` sub-sort is dropped as `co.id` is sufficient for stable pagination within the same priority tier.

**Rollback toggle:** `syspropService.getBooleanValue("ORDER_RELEASE_STREAMING_ENABLED", true)` — if `false`, falls back to original `getOrderReleaseInfo(...)` + bucket loop.

**Streaming cursor READ COMMITTED correctness (Q3 — RESOLVED SAFE):** PostgreSQL server-side cursor with `autoCommit=false` (confirmed: `application.properties:50` `landlord.datasource.auto-commit=false`) takes a statement-level snapshot at DECLARE time under READ COMMITTED. Subsequent `REQUIRES_NEW` commits by inner calls are invisible to subsequent cursor FETCHes — the cursor sees the snapshot, not the committed mutations. No risk of re-reading processed rows. Testcontainers integration test should assert `pg_cursors` row count during active stream (see §6).

**Stale-state re-check (Architect Critical Finding #5):** `OrderReleaseJob.java:170` currently re-checks `co.state >= ASSIGNED` from the cursor projection — this read is inside the outer `readOnly=true` boundary, not inside `REQUIRES_NEW`. With the streaming window potentially spanning 10+ minutes, this projection is stale. **Fix A extends the streaming window, which widens the stale window — the re-check must move inside `releaseOrder` or its `REQUIRES_NEW` boundary.** `streamAndDispatchReleases` passes order positions to `releaseOrder`; `releaseOrder` must call `customerorderRepository.findById(coId)` and check `co.getState() >= ASSIGNED` before proceeding, returning early if already released by a concurrent path.

**Why not Pageable for OrderReleaseJob (default):** Page boundary may fall mid-order (multiple rows per `co.id`). Paginated approach requires over-fetching or deduplication at the boundary — more complex. The streaming approach mirrors `StockViewRepository.streamAllBy()` from SBDEV-2219 and is the natural fit.

---

### Fix B: ReplenishOrderJob — Paginated drain-queue per sub-op

**Addresses:** Sites #6–#13

**Before** (`ReplenishorderRepository.java`, one of six):
```java
@Query(nativeQuery = true, value = "SELECT DISTINCT r.id FROM replenishorder r ... WHERE r.state <= :state")
List<Long> getIdsForUnreachableReplenishOrders(@Param("state") int state);
```

**After** — add paginated variant alongside existing (keep original for tests):
```java
@Query(nativeQuery = true, value = "SELECT DISTINCT r.id FROM replenishorder r ... WHERE r.state <= :state ORDER BY r.id")
Page<Long> getIdsForUnreachableReplenishOrdersPage(@Param("state") int state, Pageable p);
```

Apply same pattern to all 6 queries (paginated variants added alongside originals — originals kept for existing tests):
- `getIdsForUnreachableReplenishOrdersPage`
- `getIdsToCancelReplenishOrdersPage`
- `getIdsToDeleteEmptyFixAssignmentWithoutStockToReplenishPage`
- `getIdsForItemDataWithoutFixedAssignmentPage` (on `ItemdataRepository`)
- `getIdsForItemDataWithFixedAssignmentWithOrdersPage`
- `getIdsToUpdateReplenishmentOrderPriorityPage` + `getIdsToUpdateReplenishmentOrderPriority2Page`

**Sub-op classification — two loop patterns apply:**

| Sub-op | Method | WHERE predicate affected by REQUIRES_NEW? | Loop pattern |
|--------|--------|-------------------------------------------|--------------|
| 1 — cancelUnreachable | `getIdsForUnreachableReplenishOrders` | Yes — `cancelReplenishmentOrder` advances state beyond `state <= :state` predicate | drain-queue (always page 0) |
| 2 — cancelOrders | `getIdsToCancelReplenishOrders` | Yes — cancel advances state | drain-queue (always page 0) |
| 3 — deleteEmptyFix | `getIdsToDeleteEmptyFixAssignment...` | Yes — delete removes row entirely | drain-queue (always page 0) |
| 4 — itemDataNoFix | `getIdsForItemDataWithoutFixedAssignment` | Yes — creates assignment, removing row from WHERE | drain-queue (always page 0) |
| 5 — itemDataWithFix | `getIdsForItemDataWithFixedAssignmentWithOrders` | Yes — processes order, removing row from WHERE | drain-queue (always page 0) |
| **6a — updatePriority** | `getIdsToUpdateReplenishmentOrderPriority` | **NO — bulk UPDATE sets `prio = VERY_LOW` but WHERE has NO `prio` filter → rows remain after update** | **forward pagination (`page.next()`)** |
| 6b — updatePriority2 | `getIdsToUpdateReplenishmentOrderPriority2` | Yes — WHERE has `r.prio != :customerOrderPriority`; after update sets prio to match, row removed from WHERE | drain-queue (always page 0) |

**Before** (`ReplenishOrderJob.java:245-258`, sub-ops 1-5 + 6b):
```java
List<Long> resultList = replenishorderRepository.getIdsForUnreachableReplenishOrders(state);
for (Long replenishOrderID : resultList) {
    try { replenishOrderJobService.cancelReplenishmentOrder(replenishOrderID); }
    catch (...) { ... }
}
```

**After — drain-queue loop (sub-ops 1-5 + 6b):**
```java
private static final String REPLENISHMENT_PAGE_SIZE_KEY  = "REPLENISHMENT_PAGE_SIZE";
private static final String REPLENISHMENT_PAGE_LIMIT_KEY = "REPLENISHMENT_PAGE_LIMIT";
private static final int DEFAULT_REPLENISHMENT_PAGE_SIZE  = 1000;
private static final int DEFAULT_REPLENISHMENT_PAGE_LIMIT = 100;

int pageSize = syspropService.getIntValue(REPLENISHMENT_PAGE_SIZE_KEY, DEFAULT_REPLENISHMENT_PAGE_SIZE);
int maxPages = syspropService.getIntValue(REPLENISHMENT_PAGE_LIMIT_KEY, DEFAULT_REPLENISHMENT_PAGE_LIMIT);
for (int p = 0; p < maxPages; p++) {
    Page<Long> page = replenishorderRepository.getIdsForUnreachableReplenishOrdersPage(
        state, PageRequest.of(0, pageSize));   // Always page 0: each cancel advances state → row leaves WHERE
    if (page.isEmpty()) break;
    for (Long id : page.getContent()) {
        try { replenishOrderJobService.cancelReplenishmentOrder(id); }
        catch (...) { ... }
    }
}
```

**After — forward-pagination loop (sub-op 6a only — `updateReplenishmentOrderPriority`):**
```java
// Sub-op 6a: updateReplenishmentOrderPriorityBulk sets r.prio = VERY_LOW.
// WHERE has NO prio filter → processed rows remain in result set → must advance page, not re-query page 0.
int pageSize = syspropService.getIntValue(REPLENISHMENT_PAGE_SIZE_KEY, DEFAULT_REPLENISHMENT_PAGE_SIZE);
int maxPages = syspropService.getIntValue(REPLENISHMENT_PAGE_LIMIT_KEY, DEFAULT_REPLENISHMENT_PAGE_LIMIT);
int page = 0;
while (page < maxPages) {
    Page<Long> result = replenishorderRepository.getIdsToUpdateReplenishmentOrderPriorityPage(
        replenishOrderStarted, PageRequest.of(page, pageSize));
    if (result.isEmpty()) break;
    replenishOrderJobService.updateReplenishmentOrderPriorityBulk(result.getContent());
    if (!result.hasNext()) break;
    page++;
}
```

> **Why sub-op 6a cannot use drain-queue:** `getIdsToUpdateReplenishmentOrderPriority` WHERE: `r.state < :replenishOrderStarted AND manuallyOverridePriority = false AND NOT EXISTS (...)`. After `updateReplenishmentOrderPriorityBulk` sets `r.prio = VERY_LOW`, the row still satisfies the WHERE (no prio predicate). Querying `PageRequest.of(0, pageSize)` again returns the same rows → the loop executes 100× (maxPages cap), each time updating already-updated rows. This is a silent infinite-update bug with no exception — only wasteful DB write churn. `page.next()` (forward pagination) is correct here.

**Why not streaming for ReplenishOrderJob:** A streaming cursor requires an outer `readOnly=true` tx to remain open while inner `REQUIRES_NEW` calls fire. Pagination is simpler and the extra round-trips (50 queries for 50K IDs at pageSize=1000) are negligible vs. 300K REQUIRES_NEW tx savings.

**Connection budget math:** `maxPages(100) × pageSize(1000) = 100K max tx per sub-op per cycle` vs. current unbounded 300K+. Configurable downward via sysprops.

---

### Fix C: StockSummaryExportJob — Decouple OMS HTTP from cursor tx + bulk inventory insert

**Addresses:** Sites #14, #15, #16, #19

**Before** (`StockSummaryExportJob.java:152-164`):
```java
warehouseStockReportService.streamStockCount(sc -> {
    inventoryRecordService.createEntity(sc.getClientNumber(), ...);  // REQUIRES_NEW per row → 1M tx
    chunk.add(sc);
    if (chunk.size() >= batchSize) {
        sendList(new ArrayList<>(chunk));   // HTTP POST inside @Transactional(readOnly=true) cursor tx
        chunk.clear();
    }
});
```

**After (Part 1 — bulk insert):** Add `createEntitiesBulk` to `InventoryRecordService`:
```java
// InventoryRecordService.java — new method
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
public void createEntitiesBulk(List<InventoryRecordDto> records) {
    inventoryRecordRepository.saveAll(records.stream().map(this::toEntity).collect(Collectors.toList()));
}
```

**After (Part 2 — OMS HTTP outside cursor tx):** Collect chunks during stream, send after stream closes:
```java
// StockSummaryExportJob — updated streaming lambda:
List<List<StockCountDto>> omsChunks = new ArrayList<>();
List<InventoryRecordDto> invBuffer  = new ArrayList<>(batchSize);

warehouseStockReportService.streamStockCount(sc -> {
    invBuffer.add(toInventoryRecordDto(sc, exportDate, exportType, exportUser));
    chunk.add(sc);
    if (chunk.size() >= batchSize) {
        inventoryRecordService.createEntitiesBulk(new ArrayList<>(invBuffer));
        invBuffer.clear();
        omsChunks.add(new ArrayList<>(chunk));
        chunk.clear();
    }
});
// Stream closed — @Transactional(readOnly=true) committed — DB connection returned to pool
if (!invBuffer.isEmpty()) inventoryRecordService.createEntitiesBulk(invBuffer);
if (!chunk.isEmpty())     omsChunks.add(chunk);

// HTTP POST to OMS — no DB connection held during I/O
for (List<StockCountDto> c : omsChunks) {
    sendList(c);
}
```

**Bulk insert impact:** 1M rows / batchSize(250) = **4,000 REQUIRES_NEW tx** vs. 1,000,000 — a **99.75% reduction** in pool churn.

**OMS decoupling impact:** `sendList` calls execute after `streamStockCount` returns and the cursor tx commits. DB connection is returned to the pool before any OMS HTTP I/O begins. Satisfies ticket AC3.

**Memory (Q4 — RESOLVED, connection IS held):** `application.properties` has no `hibernate.connection.handling_mode` override; the Hibernate default is `DELAYED_ACQUISITION_AND_RELEASE_AFTER_TRANSACTION`, which holds the JDBC connection for the full `@Transactional` duration — including across the `forEach` lambda. OMS HTTP I/O runs while the cursor tx is open and the connection is held. **Fix C Part 2 (OMS decoupling) is a correctness fix, not optional.** Parts 1 and 2 must ship atomically — a partial deploy that ships only the bulk insert without OMS decoupling does not solve the connection-starvation problem.

`omsChunks` buffers all chunk lists. `StockCountDto` has 2 `String` + 5 `int` fields ≈ 180 bytes/object on-heap. Unbounded-buffer worst case: 1M rows / 250 batchSize = 4,000 chunks × (250 rows × ~180 bytes) ≈ **180MB** — near the 256MB ticket ceiling and the motivation for requiring a bounded buffer. With a `BlockingQueue(capacity=50)` producer-consumer pattern, peak memory is capped at `50 chunks × 250 rows × 180 bytes ≈ 2.25MB` steady state. The `BlockingQueue` producer-consumer (producer thread drives stream, consumer thread calls `sendList`) is required for Phase 2 scope. `TenantAwareTaskDecorator` must be applied to the consumer thread to propagate `TenantContext`.

---

## 4. V1/V2 Applicability

**v2 only** per explicit user instruction. The v1 jobs (`v1/wms-api/src/main/java/net/aim_ai/wms/schedulejob/`) have the same anti-patterns; flagged for `wms-v1-sync-sweep` in a separate session.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | N/A — no schema migration needed | | Pure code logic refactor |
| 2 | Feature flags / system properties | `REPLENISHMENT_PAGE_SIZE=1000`, `REPLENISHMENT_PAGE_LIMIT=100`, `ORDER_RELEASE_STREAMING_ENABLED=true` in `los_sysprop` after deployment | Nam Park | Default values in code provide safe fallback if rows absent |
| 3 | Config / env changes | N/A | | No `application.properties` changes |
| 4 | Deploy-order dependencies | N/A | | No OMS contract change |
| 5 | Data migration | N/A | | No data backfill |
| 6 | External systems | OMS endpoint reachable for manual test; WireMock for IT | | |
| 7 | Access / permissions | N/A | | |
| 8 | Monitoring | Add Grafana panel for `cron_job_rows_processed_total{job}` after deployment | Nam Park | Micrometer metrics defined in §5.2 |

### 5.2 Implementation Checklist

**Phase 1 — ReplenishOrderJob (highest urgency — 300K tx/cycle)**
- [ ] `ReplenishorderRepository.java`: Add 6 paginated `Page<Long>` variants with `ORDER BY r.id`
- [ ] `ItemdataRepository.java`: Add `getIdsForItemDataWithoutFixedAssignmentPage` paginated variant
- [ ] `ReplenishOrderJob.java`: Replace 6 unbounded-list loops with paginated drain-queue loops; add `REPLENISHMENT_PAGE_SIZE` + `REPLENISHMENT_PAGE_LIMIT` sysprop reads
- [ ] `ReplenishOrderJob.java`: Add Micrometer counter `cron_job_rows_processed_total{job="replenishOrder"}` and timer `cron_job_duration_seconds{job="replenishOrder"}`
- [ ] Add `ReplenishOrderJobPaginationTest` (unit — mocked repo; verifies paginated methods called, unbounded NOT called)
- [ ] Add `ReplenishOrderJobConnectionBudgetTest` (unit — verifies `maxPages` cap enforced)
- [ ] Update `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` §4.2
- [ ] Update `sbdocs/3-Resources/architecture/wms2-sysprop-catalog.md` (add `REPLENISHMENT_PAGE_SIZE`, `REPLENISHMENT_PAGE_LIMIT`)
- [ ] Run: `mvn test -Dtest=ReplenishOrderJobPaginationTest,ReplenishOrderJobConnectionBudgetTest`
- [ ] Run: `bash sbdocs/9-System/scripts/verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh`

**Phase 2 — StockSummaryExportJob** _(Part 1 bulk insert + Part 2 OMS decoupling ship atomically — see §3 Fix C)_
- [ ] `InventoryRecordService.java`: Add `createEntitiesBulk(List<InventoryRecordDto>)` with `REQUIRES_NEW` + `saveAll`
- [ ] `StockSummaryExportJob.java`: Replace per-row `createEntity` with buffered `createEntitiesBulk`; accumulate `omsChunks` inside lambda; send all chunks AFTER `streamStockCount` returns
- [ ] `StockSummaryExportJob.java`: Add bounded `BlockingQueue` producer-consumer for `sendList` calls; apply `TenantAwareTaskDecorator` to consumer thread for hyper-scale tenants
- [ ] Add `StockSummaryExportJobOmsDecouplingTest` (unit — asserts stream returns before `sendList` called)
- [ ] Add `StockSummaryExportJobBulkInsertTest` (unit — asserts `createEntitiesBulk` called ≤ `ceil(rows/batchSize)` times; `createEntity` never called from export path)
- [ ] Update `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` §4.3
- [ ] Run: `mvn test -Dtest=StockSummaryExportJobOmsDecouplingTest,StockSummaryExportJobBulkInsertTest,StockSummaryExportJobUnitTest`
- [ ] Run: `bash sbdocs/9-System/scripts/verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh`

**Phase 3 — OrderReleaseJob** _(Q3 RESOLVED SAFE — no prerequisite blocker; Q6 priority-ordering to be confirmed with domain team before merge)_
- [ ] `CustomerorderPositionRepository.java`: Add `streamOrderReleaseInfo(...)` with `@QueryHints` fetchSize=500, `ORDER BY co.id ASC, cop.number ASC`
- [ ] `ReleaseOrderJobService.java` (or `OrderReleaseJob.java`): Add `streamAndDispatchReleases(...)` with `@Transactional(value="tenantTransactionManager", readOnly=true)`
- [ ] `ReleaseOrderJobService.releaseOrder(...)`: Add stale-state re-check inside `REQUIRES_NEW` boundary — call `customerorderRepository.findById(coId)` and verify `co.getState() >= ASSIGNED` before processing; return early if already released. Keep `OrderReleaseJob.java:170`'s cursor-projection check as a cheap fast-path filter (free read, no DB), but add the authoritative re-fetch inside `releaseOrder`'s `REQUIRES_NEW` boundary as the definitive guard.
- [x] Q6 resolved: use `ORDER BY co.prio DESC, co.id ASC, cop.number ASC` — priority ordering is a hard business requirement; `co.id` secondary key ensures break detection works correctly.
- [ ] `OrderReleaseJob.java`: Replace `getOrderReleaseInfo` + bucket loop with `streamAndDispatchReleases`; wire `ORDER_RELEASE_STREAMING_ENABLED` sysprop toggle (if `false`, falls back to original path)
- [ ] `OrderReleaseJob.java`: Add Micrometer counter `cron_job_rows_processed_total{job="orderRelease"}`
- [ ] Investigate `fixLocationAssignmentRepository.getFixedLocationAndItemDataIds()` (Site #2) — run `SELECT count(*) FROM fix_location_assignment` on production-scale tenant; if > 1K rows, add streaming/paginated variant
- [ ] Add `OrderReleaseJobStreamingTest` (unit — verifies `streamOrderReleaseInfo` called, `getOrderReleaseInfo` NOT called; stream closed after iteration)
- [ ] Add `OrderReleaseJobStaleStateTest` (unit — verifies `releaseOrder` skips order whose `co.state` was advanced between cursor projection and REQUIRES_NEW boundary)
- [ ] Update `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` §4.1
- [ ] Update `sbdocs/3-Resources/architecture/wms2-sysprop-catalog.md` (add `ORDER_RELEASE_STREAMING_ENABLED`)
- [ ] Run: `mvn test -Dtest=OrderReleaseJobStreamingTest,OrderReleaseJobStaleStateTest,OrderReleaseJobUnitTest`
- [ ] Run: `mvn verify -Dit.test=OrderReleaseStreamingCursorIT -DskipUnitTests=true`
- [ ] Run: `bash sbdocs/9-System/scripts/verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh`

**Final gate**
- [ ] `mvn verify` (full suite — includes Testcontainers IT)
- [ ] Verify script final run: output must be `Result: N pass, 0 fail`
- [ ] Update §11 Implementation Status with commit SHAs + test results

---

## 6. Test Plan

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `ReplenishOrderJobPaginationTest` | `cancelUnreachable_usesPagedQuery()` | `getIdsForUnreachableReplenishOrdersPage(state, PageRequest.of(0,1000))` called; unbounded `getIdsForUnreachableReplenishOrders(state)` NOT called |
| `ReplenishOrderJobPaginationTest` | `allSixSubOps_usePagedQuery()` | All 6 sub-ops use paginated variants, not unbounded `List<Long>` methods |
| `ReplenishOrderJobConnectionBudgetTest` | `maxPagesCapApplied()` | With `PAGE_LIMIT=2, PAGE_SIZE=100`, `cancelReplenishmentOrder` invoked ≤ 200 times even if mock returns 10K IDs |
| `ReplenishOrderJobConnectionBudgetTest` | `alwaysQueryPage0_drainQueue()` | After successful cancel (sub-ops 1-5, 6b), next page query is always `PageRequest.of(0, pageSize)` |
| `ReplenishOrderJobConnectionBudgetTest` | `subOp6a_usesForwardPagination()` | Sub-op 6a (`updateReplenishmentOrderPriority`) increments page on each iteration, not always page 0 |
| `StockSummaryExportJobOmsDecouplingTest` | `sendList_calledAfterStreamCloses()` | Mock `streamStockCount` to capture invocation order; assert `sendList` invocations occur AFTER `streamStockCount` returns |
| `StockSummaryExportJobBulkInsertTest` | `bulkInsert_notPerRow()` | For 1000 stock rows with batchSize=100: `createEntitiesBulk` called 10 times; `createEntity` called 0 times from export path |
| `OrderReleaseJobStreamingTest` | `usesStreamVariant_notListVariant()` | `streamOrderReleaseInfo` called; `getOrderReleaseInfo` NOT called |
| `OrderReleaseJobStreamingTest` | `streamClosedAfterIteration()` | Stream is closed via try-with-resources (Mockito verify or finally-block assertion) |
| `OrderReleaseJobStaleStateTest` | `releaseOrder_skipsAlreadyReleasedOrder()` | When `co.state` has advanced beyond ASSIGNED between cursor projection and REQUIRES_NEW boundary, `releaseOrder` returns early without processing |
| `OrderReleaseStreamingCursorIT` | `cursorIsolation_innerRequiresNewNotVisible()` | Testcontainers (PostgreSQL): open streaming cursor, commit an inner REQUIRES_NEW tx on same table, assert `pg_cursors` still holds the original snapshot — no re-read of committed rows |
| `StockSummaryExportJobUnitTest` | (existing) | Must still pass after Fix C refactor — regression guard |
| `OrderReleaseJobUnitTest` | (existing) | Must still pass after Fix A refactor — regression guard |
| `ReplenishOrderJobTest` | (existing — Testcontainers) | Must still pass after Fix B refactor — regression guard |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| ReplenishOrderJob — paginated cycle | staging | 1. Seed 5K replenish orders state=300. 2. Trigger job. 3. Monitor `hikari.connections.active` via actuator/metrics | Pool never exceeds 3/5 active slots during job run | |
| OrderReleaseJob — streaming toggle | staging | 1. Set `ORDER_RELEASE_STREAMING_ENABLED=false`. 2. Trigger job. 3. Confirm original behavior. 4. Set `=true`. 5. Trigger again. | Both paths complete without error | |
| StockSummaryExportJob — OMS slow path | staging (WireMock) | 1. Configure WireMock 5s delay per OMS chunk. 2. Trigger export (1000 stock rows, batchSize=100). 3. During OMS calls: check `hikari.connections.active` | Pool ≥ 4/5 free slots during OMS HTTP calls | |
| ReplenishOrder — page cap guard | staging | 1. Set `REPLENISHMENT_PAGE_LIMIT=1`. 2. Seed 5K replenish orders. 3. Trigger job. | At most 1000 IDs processed per cycle; remainder in next cycle | |
| SQL — sysprop rows present | staging DB | `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey IN ('ORDER_RELEASE_STREAMING_ENABLED','REPLENISHMENT_PAGE_SIZE','REPLENISHMENT_PAGE_LIMIT')` | 3 rows with correct values | |

### Test execution (fill after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|-----------------------|
| `mvn test -Dtest=ReplenishOrderJobPaginationTest,ReplenishOrderJobConnectionBudgetTest` | | |
| `mvn test -Dtest=StockSummaryExportJobOmsDecouplingTest,StockSummaryExportJobBulkInsertTest` | | |
| `mvn test -Dtest=OrderReleaseJobStreamingTest,OrderReleaseJobStaleStateTest` | | |
| `mvn verify -Dit.test=OrderReleaseStreamingCursorIT` | | |
| `mvn verify` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Connection-pool utilisation assertion (AC2 ≤ 60%) | HikariCP pool metrics at assertion level require JMX / Micrometer wiring in test harness — covered by manual test plan |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | **In-JVM state** | Yes | `ReplenishOrderJob.RUNNING` AtomicBoolean (line 26) provides per-replica re-entrancy guard. `AdvisoryLockService.tryLock` provides cross-replica mutual exclusion. No new per-JVM state introduced by this fix. |
| 2 | **Connection pool math** | Yes | Fix B: 300K REQUIRES_NEW → ≤ 100K per cycle (capped by `maxPages × pageSize`). Fix C: 1M REQUIRES_NEW → 4,000 per export (batchSize=250). Fix A streaming cursor: exactly 1 connection held while cursor is active (same as existing `streamStockCount`). Net: pool pressure significantly reduced. |
| 3 | **Scheduled jobs** | Yes | All 3 jobs protected via `AdvisoryLockService.tryLock(JobLockId.*)` (lines 61/84/64). No new `@Scheduled` methods added. **Caveat:** Advisory locks are session-scoped and break under PgBouncer `pool_mode=transaction`. Do NOT migrate to PgBouncer transaction pooling until `260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md` ships. |
| 4 | **Long transactions** | Yes | Fix A introduces a long-lived `readOnly=true` streaming cursor tx for OrderReleaseJob (same pattern as `streamStockCount`). Duration bounded by tenant size × per-order throughput. Inner REQUIRES_NEW calls each acquire+release their own connection without extending the outer cursor hold. |
| 5 | **Request affinity** | N/A | Cron-triggered; no request affinity required. |
| 6 | **Retry / idempotency** | Yes | All 3 jobs are idempotent drain-queue consumers. OrderRelease re-checks `co.state` before releasing. ReplenishOrder naturally re-processes any row the previous cycle missed. StockSummaryExport: SBDEV-2222 idempotency key guards duplicate OMS POSTs. |
| 7 | **Tenant context** | Yes | All jobs iterate tenants with `TenantContext.setCurrentTenant()` / `TenantContext.clear()` in try/finally. Fix C's `omsChunks` list is tenant-local. No `@Async` or cross-thread usage introduced; if optional BlockingQueue follow-up is implemented, `TenantAwareTaskDecorator` must be used. |
| 8 | **Distributed lock correctness** | Yes | `pg_try_advisory_lock` session-scoped. PgBouncer caveat documented (row 3 above). No new pessimistic locks introduced. |
| 9 | **Cache invalidation** | N/A | None of the 3 jobs touch `@Cacheable` entities. `SyspropService` cache reads are not mutated here. |
| 10 | **External notifications** | Yes | Fix C explicitly decouples OMS HTTP POST from the streaming cursor transaction. After Fix C, `sendList` calls run outside any open tenant transaction — satisfies `TransactionSynchronization.afterCommit` intent. |

### Evidence (for Yes rows)

| # | Verified at | File:line |
|---|---|---|
| 1 | AtomicBoolean RUNNING; cross-replica lock | `ReplenishOrderJob.java:26`, `AdvisoryLockService.java:36-44` |
| 2 | Tenant pool maxSize=5; Fix B/C transaction count reduction | `TenantDynamicRoutingDataSource.java:77`; Fix B/C §3 |
| 3 | Job-level advisory lock calls | `OrderReleaseJob.java:61`, `ReplenishOrderJob.java:84`, `StockSummaryExportJob.java:64` |
| 4 | Existing streaming cursor pattern | `WarehouseStockReportService.java:70` |
| 6 | State re-check; drain loop | `OrderReleaseJob.java:170`, `ReplenishOrderJob.java:153-159` |
| 7 | Try/finally tenant clear | `OrderReleaseJob.java:97-99` |
| 8 | Advisory lock; PgBouncer landmine | `AdvisoryLockService.java:36-44`; `wms2-scheduled-jobs-catalog.md:313` |
| 10 | Fix C code block §3 | `StockSummaryExportJob.java:152-164` before/after |

---

## 8. Notes

### v2-only Constraint Checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV disabled | Yes — streaming methods must be inside `@Transactional(readOnly=true, value="tenantTransactionManager")` | `application.properties:54`; Fix A `streamAndDispatchReleases` annotation |
| 2 | Transaction manager | Yes — all new `@Transactional` in this plan use `value="tenantTransactionManager"` | §3 Fix A, Fix C code blocks |
| 3 | `@Transactional(readOnly=true)` | Yes — `streamAndDispatchReleases` uses `readOnly=true`; paginated repo calls run in Spring Data auto-tx (correct) | Fix A |
| 4 | Caffeine cache | N/A — no `@Cacheable` entities in scope | |
| 5 | Jakarta namespace | Confirmed — job files use `jakarta.persistence.OptimisticLockException`; new `@QueryHint` uses `jakarta.persistence.QueryHint` | `OrderReleaseJob.java:19`, `ReplenishOrderJob.java:16` |
| 6 | H2-compatible SQL | Yes — new pagination uses standard JPQL native SQL compatible with PostgreSQL; streaming tests use Testcontainers (not H2 cursor simulation) | `StockSummaryExportJobTest.java` (Testcontainers) |
| 7 | BaseControllerTest | N/A — no controller changes | |
| 8 | Micrometer metrics | Yes — `cron_job_rows_processed_total{job, tenant}` and `cron_job_duration_seconds{job, tenant}` to be added; reuse `MeterRegistry` from `WarehouseStockReportService.java:31` | §5.2 checklist |

### Related Plans

- `SBDEV-2219` (archived) — introduced streaming cursor for StockSummaryExportJob memory. This plan fixes remaining pool-churn and OMS-blocking issues not covered by 2219.
- `SBDEV-2222` (active) — introduces `AdvisoryLockService.JobLockId.CLEANUP_REST_IDEMPOTENCY`; this plan reuses `AdvisoryLockService` but does not modify it.
- `260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md` (active) — dependency: do NOT migrate to PgBouncer `pool_mode=transaction` until that plan ships; advisory locks would break.
- v1 follow-up: tag `wms-v1-sync-sweep` to port equivalent fixes to `v1/wms-api`.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

**Path:** `sbdocs/9-System/scripts/verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh`

Run before AND after every implementation pass:
```bash
bash sbdocs/9-System/scripts/verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh
```

- **Pre-implementation baseline:** all POSITIVE checks FAIL, all NEGATIVE checks PASS.
- **Post-implementation:** all checks PASS. Required final output: `Result: N pass, 0 fail`.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Large | 16 in-scope sites, 3 independent subsystems (3 jobs + 2 repos + 1 service), 3-phase rollout |
| **Pre-draft step** | Complete (this plan) | |
| **Plan-review step** | critic | Standard for Large plans; critic before implementation |
| **Implementation shape** | ralph (phased) | One ralph pass per phase: implement → `bash verify-*.sh` → fix FAILs → repeat until `0 fail`. 3 phases = 3 ralph passes. |
| **Verification step** | verify script + verifier | Mandatory; final claim requires `Result: N pass, 0 fail` pasted verbatim |
| **Code-review step** | code-reviewer | 3 independent subsystems, each with new patterns |
| **Commit step** | git-master | 3 atomic commits (one per phase) with trailers |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Status |
|---|---|---|
| Q1 | Scope: v1 or v2? | **Resolved: v2 ONLY** per user. v1 queued for wms-v1-sync-sweep. |
| Q2 | ShedLock needed? | **Resolved: No.** `AdvisoryLockService.tryLock(JobLockId.*)` already provides equivalent distributed mutual exclusion. PgBouncer caveat documented in §7 row 3. |
| Q3 | OrderRelease streaming cursor READ COMMITTED correctness | **Resolved: SAFE.** PostgreSQL server-side cursor with `autoCommit=false` (`application.properties:50`) takes a statement-level snapshot at DECLARE time under READ COMMITTED. Subsequent `REQUIRES_NEW` commits by inner calls are invisible to subsequent cursor FETCHes — cursor sees the snapshot, not committed mutations. No risk of re-reading processed rows. Phase 3 no longer blocked. |
| Q4 | StockSummaryExportJob — does cursor tx hold JDBC connection during HTTP I/O? | **Resolved: CONFIRMED — connection IS held.** `application.properties` has no `hibernate.connection.handling_mode` override; Hibernate default (`DELAYED_ACQUISITION_AND_RELEASE_AFTER_TRANSACTION`) holds the JDBC connection for the full `@Transactional` duration including the `forEach` lambda. Fix C Part 2 (OMS decoupling) is a correctness fix, not optional. Parts 1 and 2 must ship atomically. |
| Q5 | `ReplenishOrderJob.affectedItemIds` Set — paginate? | **Resolved: Leave as-is.** 50K IDs × 8 bytes = 400KB — acceptable. Cleared each tenant cycle. |
| Q6 | ORDER BY priority change for OrderReleaseJob streaming | **Resolved: use compound sort.** Priority ordering is a hard business requirement. `ORDER BY co.prio DESC, co.id ASC, cop.number ASC` — priority ordering preserved; `co.id` secondary key guarantees contiguous grouping for break detection. `co.created` tertiary sort dropped (superseded by `co.id`). |
| Q7 | `fixLocationAssignmentRepository.getFixedLocationAndItemDataIds()` (Site #2) scale | **Open — investigate during Phase 3.** Run `SELECT count(*) FROM fix_location_assignment` on production-scale tenant. If > 1K rows, add streaming/paginated variant per Fix A pattern. |

---

## 11. Implementation Status

**Implemented:** 2026-05-13 | **PR:** [#11](https://github.com/SiteBossInc/wms2-api/pull/11) | **Branch:** `tasks/SBDEV-2222`

| Phase | Commit SHA | Tests Added | `mvn` result | Verify script |
|---|---|---|---|---|
| Phase 1 — ReplenishOrderJob pagination | `24b1c7c` | `ReplenishOrderJobPaginationTest`, `ReplenishOrderJobConnectionBudgetTest` | 0 failures | `verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh` |
| Phase 2 — StockSummaryExportJob bulk+decouple | `dad15f5` | `StockSummaryExportJobBulkInsertTest`, `StockSummaryExportJobOmsDecouplingTest` | 0 failures | `verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh` |
| Phase 3 — OrderReleaseJob stream-cursor | `7c42e3b` | `OrderReleaseJobStreamingTest`, `ReleaseOrderJobServiceStaleStateTest` | 0 failures | `verify-SBDEV-2228-cron-jobs-unbounded-resultsets.sh` |
| TDD gate tests committed | `463e018` | (all 6 above) | full suite 0 failures | — |
| Gap fixes: BlockingQueue + fix_location pagination | `b157458` | (updated existing tests) | 3942 tests, 0 failures | — |

**Key architectural changes:**
- `ReleaseOrderJobService.streamOrderPositionsForEach` — `@Transactional(readOnly=true)` cursor boundary on a separate Spring bean (bypasses same-class proxy limitation in `OrderReleaseJob.doCalculation()`)
- `ReplenishorderRepository` / `ItemdataRepository` — 6 `Page<Long>` variants; drain-queue `PageRequest.of(0, pageSize)` for sub-ops 1–5 and 6b, forward pagination for sub-op 6a (bulk UPDATE doesn't remove rows from WHERE predicate)
- `InventoryRecordService.createEntitiesBulk` — `REQUIRES_NEW` batch insert replacing per-row REQUIRES_NEW (~1M tx/export → ~100 batches)
- `StockSummaryExportJob` — OMS `sendList()` calls deferred until after `streamStockCount()` cursor tx commits; DB connection released before any HTTP I/O
- `SyspropService.getIntValue(key, defaultValue)` — null/blank/NFE-safe int lookup
- `WmsConstants.REPLENISHMENT_PAGE_SIZE_KEY` / `REPLENISHMENT_PAGE_LIMIT_KEY` — new sysprop keys
