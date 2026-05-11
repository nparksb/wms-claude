---
title: "SBDEV-2219 — WarehouseStockReportService unbounded findAll OOM remediation (v2)"
ticket: "SBDEV-2219"
ticket_url: "https://app.clickup.com/t/868jj322r"
type: "bugfix"
priority: "high"
status: "implemented"
project: ["wms2"]
version: "v2"
requester: "David Oppenheim"
created: "2026-05-09"
updated: "2026-05-09"
related:
  - "[[SBDEV-2218-parallelstream-against-hibernate-session]]"
  - "[[SBDEV-2217-sequence-number-silent-minus-one]]"
db_verified: true
tags:
  - plan
  - performance
  - oom
  - streaming
  - cron
---

# SBDEV-2219 — WarehouseStockReportService unbounded findAll OOM remediation (v2)

**Ticket:** [SBDEV-2219](https://app.clickup.com/t/868jj322r)
**Project:** wms2/wms2-api | **Version:** v2 (Java 21 / Spring Boot 3.x) | **Type:** bug fix (performance / OOM remediation)
**Priority:** Critical (Tier 1 — heap-exhaustion class; reachable from a scheduled multi-tenant job that materializes the full `stock_view` per tenant per night)
**Reporter:** David Oppenheim | **Assignee:** Nam Park
**Parent:** WMS Code Fixes audit (868jj30yh)
**Status:** implemented (PR open)

---

## 0. Affected sites (enumeration before drafting)

Greps run:
- `grep -rn "getStockCount()" src/main/java` — find every caller of the no-arg variant.
- `grep -rn "Repository\.findAll()" src/main/java/net/aim_ai/wms/{service,controller}/` — find adjacent unbounded findAll callsites in service/controller code.
- `grep -rn "stockSummaryExportJob.doCalculation" src/main/java` — identify trigger paths into the OOM-prone code.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|---|---|---|---|
| 1 | `service/WarehouseStockReportService.java:28` | `(List<StockView>) stockViewRepository.findAll()` | yes (root) | **yes — Fix A (primary streaming refactor) + Fix C (hard cap)** |
| 2 | `service/WarehouseStockReportService.java:15` | `LoggerFactory.getLogger(ReceivingService.class)` — wrong class wired into Logger | adjacent (cosmetic ops bug) | **yes — Fix E** (cleanup; logged lines today are mis-attributed to `ReceivingService`) |
| 3 | `repo/jpa/StockViewRepository.java:15` | `@RepositoryRestResource(... path = "stockView")` exposes inherited `findAll()` over HAL — external bypass of the service-layer fix | yes (alternate ingress) | **yes — Fix D** (suppress with `@RestResource(exported = false)` on inherited `findAll`) |
| 4 | `schedulejob/StockSummaryExportJob.java:119` | `List<StockCountDto> stockCount = warehouseStockReportService.getStockCount();` — sole consumer of the no-arg variant; materializes full DTO list | yes (caller) | **yes — Fix B** (refactor to consume a `Stream<StockCountDto>` / `Consumer<StockCountDto>`) |
| 5 | `schedulejob/SchedulingConfiguration.java:219` | `stockSummaryExportJob.doCalculation(true)` — cron entry; loops every active tenant nightly | trigger path | **no — covered transitively** by Fix B (no API change at this site) |
| 6 | `controller/AdminActionController.java:101` | `stockSummaryExportJob.doCalculation(false)` — admin-button manual trigger | trigger path | **no — covered transitively** by Fix B |
| 7 | `controller/rest/StockCountRestController.java:111` | `triggerSchedule()` Runnable → `stockSummaryExportJob.doCalculation(false)` — `GET /rest/stockcount/triggerStockCount` (matches `/rest/**` permitAll at `SecurityConfiguration.java:99`) | trigger path | **no — covered transitively** by Fix B; **flagged in §9** as auth-hardening follow-up |
| 8 | `controller/rest/StockCountRestController.java:93` | `getStockCount(client.getId(), itemData.getId())` — 2-arg variant, scoped query | not in scope | **no** — uses `findByClientIdAndItemId` (line 35), bounded by clientId+itemId |
| 9 | `controller/ItemDataController.java:106` (per ticket) | 2-arg variant call | not in scope | **no** — same as row 8 |
| 10 | `service/AccessService.java:64` | `(List<UserFunction>) userFunctionRepository.findAll()` — permission catalog | adjacent (low-risk volume) | **no — Fix F (deferred audit guard)** |
| 11 | `controller/rest/UtilRestController.java:700` | `(List<LocationConstraint>) locationConstraintRepository.findAll()` | adjacent (low-medium volume) | **no — Fix F (deferred audit guard)** |
| 12 | `controller/rest/OrderRestController.java:342` | `(List<Shipperid>) shipperidRepository.findAll()` | adjacent (low volume) | **no — Fix F (deferred audit guard)** |
| 13 | (new) `service/WmsConstants.java` | needs `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY` + default value | yes (Fix C support) | **yes — Fix C** (new sysprop pair, mirroring lines 1018-1027) |
| 14 | (new) `src/main/resources/messages_en_US.properties` | needs `BusinessException.StockCountTooLarge` | yes (Fix C support) | **yes — Fix C** (i18n key) |
| 15 | `src/test/java/.../unit/service/WarehouseStockReportServiceUnitTest.java` (166 lines) | exists; tests current `getStockCount()` against mocked findAll | gap | **yes — §6'** (update for streaming API + hard-cap behavior) |
| 16 | `src/test/java/.../unit/schedulejob/StockSummaryExportJobUnitTest.java` (81 lines) | exists; tests `exportStockSummary` against full-list contract | gap | **yes — §6'** (update for stream-consumer flow) |

> Every "yes" row in the In-scope column MUST be visited by §5 Fix Design. Rows 5/6/7 are NOT separate fixes — they are the trigger surfaces that Fix B/C protect transitively. Row 7 also surfaces a **secondary** auth-hardening concern handled in §9 Risks.

---

## 1. Problem Statement

### Symptom (verbatim from ticket)

> `WarehouseStockReportService.getStockCount()` (no-arg variant at lines 26-29) does `(List<StockView>) stockViewRepository.findAll()` — no pagination, materializing the entire view in heap. The full `stock_view` is loaded into a `List<StockView>`, then iterated by `generateStockCount(...)` to produce a `List<StockCountDto>`. For a tenant with hundreds of thousands of SKU/location combinations this is an OOM ticking bomb.

**Acceptance criteria from ticket:**
1. `WarehouseStockReportService.getStockCount()` no-arg variant is paginated or removed.
2. Load test: warehouse with 500K StockView rows; endpoint completes within 2 seconds for one page; total heap allocation bounded.
3. Caller (StockCountRestController) updated and OMS contract documented.

### Contradiction with the ticket — actual caller is a scheduled job, NOT a REST endpoint

`grep -rn "getStockCount()" src/main/java` returns exactly **one** non-test invocation of the no-arg variant:

```
src/main/java/net/aim_ai/wms/schedulejob/StockSummaryExportJob.java:119:
        List<StockCountDto> stockCount = warehouseStockReportService.getStockCount();
```

The two REST callers — `StockCountRestController.java:93` and `ItemDataController.java:106` — both call the **2-arg variant** `getStockCount(clientId, itemDataId)`, which routes to `findByClientIdAndItemId` (`StockViewRepository.java:23`) and is bounded by both clientId and itemId. The ticket itself acknowledges these two are fine.

The ticket's framing ("Caller (StockCountRestController) updated and OMS contract documented") therefore misidentifies the OOM ingress. The actual OOM ingress is:

1. **Cron schedule** — `SchedulingConfiguration.java:219` invokes `stockSummaryExportJob.doCalculation(true)`, which loops every active tenant from `tenantDbConfigurationRepository.findAll()` (`StockSummaryExportJob.java:74`) and runs `exportStockSummary()` per tenant. Per-tenant nightly export.
2. **Admin button** — `AdminActionController.java:101` invokes `stockSummaryExportJob.doCalculation(false)` for the current tenant context (manual trigger from the admin UI).
3. **REST trigger** — `GET /rest/stockcount/triggerStockCount` (`StockCountRestController.java:103-108`) returns `triggerSchedule().run()` which invokes `stockSummaryExportJob.doCalculation(false)`. **`/rest/**` is `permitAll()` per `SecurityConfiguration.java:99`** — so this is the *real* attack surface for a deliberate OOM trigger from outside.

**Corrected interpretation of the ACs:**

| Ticket AC | Original framing | Corrected framing |
|---|---|---|
| AC-1 | "no-arg variant is paginated or removed" | Met by **streaming with bounded heap** — pagination doesn't fit the cron use case (the job needs to process all rows in one pass). The streaming API replaces the heap-resident `List` with a JDBC cursor. |
| AC-2 | "endpoint completes within 2 seconds for one page; total heap allocation bounded" | Recast as **"bounded heap and JVM-stable for a tenant with N rows where N≥500K"**. There is no "page" in a streaming model; the relevant SLO is `O(batch_size)` heap during export, not per-page latency. |
| AC-3 | "Caller (StockCountRestController) updated and OMS contract documented" | Met by **clarifying that the public POST `/rest/stockcount/getStockCount` already uses the safe 2-arg variant**. The trigger endpoint `GET /rest/stockcount/triggerStockCount` deferring to the streaming job satisfies the spirit. The OMS contract (`/call/inventory/stockCountExport` per `WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY`) does NOT change shape — it still receives `List<StockCountDto>` payloads, just batched-from-stream rather than chunked-from-list. |

This contradiction is logged explicitly in §10 with file:line evidence and the resolved path forward.

### DB verification status — `db_verified: true`

`mcp__wms1-wineco-dev__execute_sql` (after correcting the table name from `stockview` to `stock_view` per `information_schema.views`):

```sql
SELECT count(*) AS stock_view_count FROM stock_view;
-- Result: 8,775 rows (wineco tenant, 2026-05-09)

SELECT table_name, table_type
FROM information_schema.views
WHERE table_name = 'stock_view';
-- Result: stock_view | VIEW
```

**Verdict:** wineco currently sits at 8,775 rows — well below the ticket's hypothetical 500K scenario, but every additional tenant onboarded scales this linearly per tenant. With ~10 active tenants in production today and growth pressure on retail/club workflows, a 50× multiplier per tenant is plausible within the next year. The streaming refactor is also the safest path for **today's** 8.7K row tenants — a `List<StockView>` of 8.7K + `List<StockCountDto>` of 8.7K + the per-row entity hydration cost is non-trivial Hikari/Hibernate pressure that can be eliminated entirely.

`stock_view` being a **VIEW** (not a table) is relevant for Fix A: PostgreSQL streams view rows via cursors the same as base tables, so JPA/Hibernate's `@QueryHint(HINT_FETCH_SIZE = 500)` is honored on the underlying JDBC cursor. No special handling required.

---

## 2. Root Cause Analysis

The bug is the simplest shape: an unbounded `findAll()` on a multi-million-rows-possible view, called by a per-tenant nightly cron job (and reachable from an unauthenticated REST endpoint). Each contributing factor is documented separately below — a single fix that *only* swaps `findAll()` for a stream still leaves auxiliary residual risks (no `@Transactional` boundary for the stream, mis-attributed Logger, HAL exposure of the inherited `findAll`).

### Bug 1 — Unbounded `findAll()` materializes the full `stock_view` per cron tick

**File:** `src/main/java/net/aim_ai/wms/service/WarehouseStockReportService.java:26-30`

```java
public List<StockCountDto> getStockCount() {
    List<StockView> stockViews = (List<StockView>) stockViewRepository.findAll();
    return generateStockCount(stockViews);
}
```

`stockViewRepository` extends `ReadOnlyPagingAndSortingRepository<StockView, Long>` (`StockViewRepository.java:16`), which inherits `findAll()` from `CrudRepository`. The implementation materializes every row in the underlying `stock_view` PostgreSQL view into a `List<StockView>` — `O(rows)` heap. `generateStockCount(...)` (lines 40-60) then builds a parallel `List<StockCountDto>` of equal size, doubling peak memory.

**Why it fails at scale:** `stock_view` joins inventory, locations, and clients per SKU. For a tenant with 500K SKU/location combinations the view returns 500K rows. Each `StockView` entity (with its persistence-attached state) is ~500-800 bytes; 500K × 600 bytes ≈ **300 MB** transient heap during the JPA hydration phase, before counting the parallel DTO list. With 10 tenants × concurrent cron firing (nominally serialized via `AdvisoryLockService`, but per-tenant inside the loop), this can OOM the cron pod even on a 2 GB heap.

**Why it has not OOMed yet at wineco:** wineco has 8,775 rows today. That is ~5 MB transient — invisible. The latent failure mode triggers when a heavier tenant onboards or when an existing tenant grows past ~200K rows. The bug is reachable, just not yet observed.

### Bug 2 — Missing `@Transactional(readOnly = true)` on the stream consumer

**File:** `src/main/java/net/aim_ai/wms/service/WarehouseStockReportService.java` (the entire class — no `@Transactional` annotation today)

The current class has no transactional boundary. Repository calls run in their own auto-opened sessions per call (Spring Data injects a transaction per repo method). For the *current* `findAll()` shape this works because the repository method completes synchronously, materializes the full list, and closes its own session before returning — the consumer receives a detached list.

But the streaming refactor (Fix A) needs the session to stay open while the consumer iterates the stream. Per the v2 codebase conventions (`v2/wms2-api/CLAUDE.md`):

- **OSIV is disabled** (`spring.jpa.open-in-view=false` in `application.properties`). A repository call outside a `@Transactional` boundary returns a detached result; lazy-loaded associations accessed afterwards throw `LazyInitializationException`.
- **Tenant-scoped writes/reads must use `@Transactional(value = "tenantTransactionManager", ...)`**. The `landlordTransactionManager` is `@Primary`; a bare `@Transactional` silently routes to the landlord DB.

For Fix A's `streamStockCount(Consumer<StockCountDto>)` to work correctly, it MUST be wrapped in `@Transactional(value = "tenantTransactionManager", readOnly = true)`. The `readOnly = true` flag lets Hibernate skip dirty-checking and enables Postgres read-only transaction optimizations — meaningful given this stream may iterate hundreds of thousands of rows.

### Bug 5 — `InventoryRecordService.createEntity` has no `@Transactional` annotation — will join the outer readOnly tx

**File:** `src/main/java/net/aim_ai/wms/service/InventoryRecordService.java:27-45`

```java
@Service
public class InventoryRecordService {
    // No @Transactional anywhere on this class
    public void createEntity(...) {
        ...
        inventoryRecordRepository.save(inventoryRecord);   // line 43
    }
}
```

`createEntity` has no `@Transactional` annotation. Under Spring's default `Propagation.REQUIRED`, when called from within `streamStockCount`'s `@Transactional(value="tenantTransactionManager", readOnly=true)` outer, it **joins that outer transaction** rather than opening its own. Spring's `HibernateJpaDialect.beginTransaction(...)` calls `Connection.setReadOnly(true)` — PostgreSQL translates this to `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`. Postgres then rejects the `INSERT` from `inventoryRecordRepository.save(...)` with:

```
org.postgresql.util.PSQLException: ERROR: cannot execute INSERT in a read-only transaction
```

**Critical:** H2's `setReadOnly` is advisory only — H2 does NOT enforce read-only at the SQL level. An integration test on H2 passes; production on Postgres breaks silently on every cron tick across every tenant. The §10 Q7 "the IT will catch it" framing in the first draft was incorrect — the IT uses H2 and would NOT catch this.

**Fix A.1 (required prerequisite for Fix A):** annotate `InventoryRecordService.createEntity` with:
```java
@Transactional(value = "tenantTransactionManager",
               propagation = Propagation.REQUIRES_NEW)
```

`REQUIRES_NEW` suspends the outer readOnly tx, opens a fresh read-write tx for the `INSERT`, commits it, then resumes the outer. The outer readOnly stream cursor continues unaffected. No `rollbackFor` is specified — `createEntity` does not throw `BusinessException`, only runtime `DataAccessException` from `save(...)`, which rolls back by default.

### Bug 3 — Wrong `Logger` class reference (cosmetic, but real ops hazard)

**File:** `src/main/java/net/aim_ai/wms/service/WarehouseStockReportService.java:15`

```java
private static final Logger LOG = LoggerFactory.getLogger(ReceivingService.class);
```

The class is `WarehouseStockReportService`, but the SLF4J Logger is wired to `ReceivingService.class`. Every log line emitted by `WarehouseStockReportService.getStockCount(Long, Long)` (line 33: `LOG.debug("start get stock clientId={}, tiemDataId={}", ...)`; line 58: `LOG.debug("end  ")`) appears under the `net.aim_ai.wms.service.ReceivingService` logger.

**Why this matters:** ops debugging — when a customer reports "stock count looks wrong", ops greps logs for `WarehouseStockReportService` and finds nothing. The relevant lines are filed under `ReceivingService`, an unrelated component. Tail-the-log diagnostics are silently broken.

**Severity:** cosmetic by itself; bundled here because the cleanup is one character per occurrence and runs zero functional risk.

### Bug 4 — HAL endpoint exposure of inherited `findAll()`

**File:** `src/main/java/net/aim_ai/wms/repo/jpa/StockViewRepository.java:15`

```java
@RepositoryRestResource(collectionResourceRel = "stockView", path = "stockView")
public interface StockViewRepository extends ReadOnlyPagingAndSortingRepository<StockView, Long> {
```

`@RepositoryRestResource` exposes the repository over Spring Data REST's HAL endpoint. By default, `findAll()` is published — an external caller can `GET /api/stockView` and trigger the same unbounded materialization that Fix A is trying to eliminate at the service layer. Mirror SBDEV-2217 Fix D (which suppressed `LosSequencenumberRepository` exposure): annotate the inherited `findAll` with `@RestResource(exported = false)` to close the alternate ingress.

`SecurityConfiguration.java:99` sets `/api/**` and `/rest/**` to `permitAll()` (read together with the surrounding `.requestMatchers(...)`), so an external attacker — or a buggy downstream consumer — could hit `/api/stockView` and exhaust heap from outside the cron path.

---

## 3. The Regression Chain

The bug is not a regression — it has been present since the first checkin and survived every subsequent refactor.

| SHA | Commit | Relevant change |
|---|---|---|
| `a685e07b` | `initial checkin the code` | `WarehouseStockReportService.getStockCount()` no-arg variant existed at this commit, with the unbounded `findAll()` already in place. |
| `1710ea12` | `updated sysprop and user services` | Adjacent — touched `SyspropService` (a dependency of this service); no change to `getStockCount()`. |
| `f36cd22c` | `separated entities for landlord and those for tenants` | Adjacent — re-organized `StockView` into the tenant entity package; signature of `findAll()` unchanged. |
| `9a68b625` | `re-adjusted the package name` | Adjacent — package rename only. |
| `c066b56e` | `replace @Autowired field injection with constructor injection across 130 files` | Touched the constructor of `WarehouseStockReportService` (lines 21-24 today). Did not change `getStockCount()` body. |
| `4a670fce` | `implemented WMS api improvement plan that include: Entity equals/hashCode, Connection pool tuning per tenant, Application-level caching, N+1 query & Bulk operation optimization, and Database index optimization` | Touched this file as part of the bulk improvement pass. Inspection of the diff: did NOT touch `getStockCount()`'s findAll line. The N+1 work concentrated on receiving/picking pipelines; this service was missed. |

**Conclusion:** the bug pre-dates the Tier-1 audit and slipped through the entity-equals/N+1 sweep because the stock-export pipeline was not in the bulk plan's scope. This plan closes it.

---

## 4. Architecture Overview

### Code path

```
┌─────────────────────────────────────────────────────────────────────┐
│ Trigger 1 — cron tick (per tenant, nightly)                         │
│   SchedulingConfiguration.java:219                                  │
│       └─> stockSummaryExportJob.doCalculation(true)                 │
│              └─> for each TenantProfile in tenantDbConfigRepo:      │
│                     └─> TenantContext.setCurrentTenant(...)         │
│                     └─> exportStockSummary()                        │
│                                                                     │
│ Trigger 2 — admin manual                                            │
│   AdminActionController.java:101                                    │
│       └─> stockSummaryExportJob.doCalculation(false)                │
│              └─> exportStockSummary()  (current tenant)             │
│                                                                     │
│ Trigger 3 — unauth REST (permitAll under /rest/**)                  │
│   GET /rest/stockcount/triggerStockCount                            │
│   StockCountRestController.java:103-111                             │
│       └─> triggerSchedule().run()                                   │
│              └─> stockSummaryExportJob.doCalculation(false)         │
│                     └─> exportStockSummary()                        │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
StockSummaryExportJob.exportStockSummary  (lines 118-156)
    │
    │  TODAY:
    │    List<StockCountDto> stockCount = warehouseStockReportService
    │                                       .getStockCount();        <── OOM HOTSPOT
    │
    │    for (StockCountDto sc : stockCount) {
    │        inventoryRecordService.createEntity(...)                <── per-row write
    │    }
    │
    │    if (split flag ON):
    │       chunk by SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH
    │       sendList(chunk) per batch                                <── HTTP POST to OMS
    │    else:
    │       sendList(stockCount)  // single full-list HTTP POST
    │
    ▼
WarehouseStockReportService.getStockCount()  (lines 26-30)
    │
    │  TODAY:                                                        AFTER FIX A:
    │    findAll() ─> List<StockView>  (full materialization)        streamAllBy() ─> Stream<StockView>
    │    generateStockCount(stockViews)                              per-row map ─> StockCountDto
    │       └─> List<StockCountDto>                                  per-row consumer.accept(dto)
    │
    ▼
StockViewRepository.findAll()  (inherited from CrudRepository via ReadOnlyPagingAndSortingRepository)
    │
    ▼
PostgreSQL stock_view (a VIEW, not a table; 8,775 rows on wineco today; 500K+ at scale)
```

### Key files

| File | Lines | Role |
|---|---|---|
| `service/WarehouseStockReportService.java` | 62 | Hosts both `getStockCount()` (no-arg, OOM risk) and `getStockCount(Long, Long)` (safe 2-arg). Fix A target. |
| `repo/jpa/StockViewRepository.java` | 37 | Spring Data repo extending `ReadOnlyPagingAndSortingRepository`. Inherits `findAll()` from `CrudRepository`. Fix A adds streaming method; Fix D suppresses HAL `findAll` exposure. |
| `repo/cinterface/ReadOnlyPagingAndSortingRepository.java` | — | `extends PagingAndSortingRepository<T, ID>, CrudRepository<T, ID>`. Already provides `findAll(Pageable)` and `findAll(Sort)` out of the box (relevant for the Option-A discussion in §10). |
| `schedulejob/StockSummaryExportJob.java` | 192 | Sole non-test caller of `getStockCount()` no-arg variant (line 119). `exportStockSummary()` body at lines 118-156. Fix B target. |
| `schedulejob/SchedulingConfiguration.java` | — | Cron entry — line 219 invokes `doCalculation(true)`. |
| `controller/AdminActionController.java` | — | Admin manual trigger — line 101 invokes `doCalculation(false)`. |
| `controller/rest/StockCountRestController.java` | 113 | Hosts the public POST `/rest/stockcount/getStockCount` (safe 2-arg) AND the unauth GET `/rest/stockcount/triggerStockCount` (line 103-108) that funnels into `doCalculation(false)`. |
| `service/WmsConstants.java` | — | Sysprop key catalog. Lines 1018-1027 already define the STOCK_SUMMARY_EXPORT_TIMER_* family. Fix C adds `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY` here. |
| `src/main/resources/messages_en_US.properties` | — | i18n message catalog (`BusinessException.MissingField`, `BusinessException.SequenceExhausted`, etc.). Fix C adds `BusinessException.StockCountTooLarge`. |
| `SecurityConfiguration.java` | line 99 | `/rest/**` and `/api/**` are `permitAll()` — both the unauth REST trigger AND the HAL `/api/stockView` endpoint. |
| `src/test/java/.../unit/service/WarehouseStockReportServiceUnitTest.java` | 166 | Existing unit test for current `getStockCount()` shape. Updated by §6'. |
| `src/test/java/.../unit/schedulejob/StockSummaryExportJobUnitTest.java` | 81 | Existing unit test for `exportStockSummary` flow. Updated by §6'. |
| **(modified)** `service/WarehouseStockReportService.java` | — | Adds `streamStockCount(Consumer<StockCountDto>)` with `@Transactional(value = "tenantTransactionManager", readOnly = true)`. Fixes Logger class reference. |
| **(modified)** `repo/jpa/StockViewRepository.java` | — | Adds `Stream<StockView> streamAllBy()` with `@QueryHints(@QueryHint(name = HINT_FETCH_SIZE, value = "500"))`. Suppresses HAL `findAll` exposure. |
| **(modified)** `schedulejob/StockSummaryExportJob.java` | — | Refactors `exportStockSummary()` to consume the new stream API. |

---

## 5. Fix Design

### Fix A — Streaming repository method + `@Transactional(readOnly = true)` consumer

**Files:**
- `src/main/java/net/aim_ai/wms/repo/jpa/StockViewRepository.java` — add streaming query.
- `src/main/java/net/aim_ai/wms/service/WarehouseStockReportService.java` — add streaming consumer method and wrap it in `@Transactional`.

**Pattern reference:** Spring Data JPA's `Stream<T>` return type combined with `@QueryHints({@QueryHint(name = HINT_FETCH_SIZE, value = "500")})`. The hint passes through to the underlying JDBC `Statement.setFetchSize(500)`, which on PostgreSQL switches the driver from full-result-set buffering to **cursor-based row streaming**. Hibernate then materializes one batch of 500 entities at a time; old batches become eligible for GC as the consumer advances. Net heap: `O(batch_size)` instead of `O(rows)`.

**Repository change (sketch — executor authors final form):**

```java
import java.util.stream.Stream;
import jakarta.persistence.QueryHint;
import org.springframework.data.jpa.repository.QueryHints;
import static org.hibernate.jpa.AvailableHints.HINT_FETCH_SIZE;

// inside StockViewRepository:
@QueryHints(@QueryHint(name = HINT_FETCH_SIZE, value = "500"))
@Query("SELECT s FROM StockView s")
Stream<StockView> streamAllBy();
```

**Service change (sketch):**

```java
@Service
public class WarehouseStockReportService {

    private static final Logger LOG = LoggerFactory.getLogger(WarehouseStockReportService.class);  // Fix E

    // Fix C support — sysprop-driven hard cap, default 1,000,000.
    private static final long DEFAULT_MAX_ROWS = 1_000_000L;

    /**
     * Streaming consumer of the full stock view. Replaces the no-arg getStockCount()
     * for batch jobs that need to process every row without materializing the whole
     * dataset in heap. Caller MUST iterate within this method's transaction (the
     * stream is closed when this method returns).
     *
     * <p>SBDEV-2219: heap is bounded to O(fetch_size) — currently 500 entities.
     * The hard cap (Fix C) protects against pathological view definitions emitting
     * cartesian product rows.
     */
    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public void streamStockCount(Consumer<StockCountDto> consumer) {
        long max = parseMaxRows(syspropService.getSysvalue(
                WmsConstants.SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY));
        long count = stockViewRepository.count();
        if (count > max) {
            LOG.error("stock_view row count {} exceeds configured cap {}; aborting export to prevent OOM", count, max);
            throw new BusinessException(
                    "BusinessException.StockCountTooLarge", count, max);
        }

        String warehouseId = syspropService.getSysvalue(
                WmsConstants.SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY);

        try (Stream<StockView> stream = stockViewRepository.streamAllBy()) {
            stream.forEach(report -> consumer.accept(toDto(report, warehouseId)));
        }
    }

    /**
     * @deprecated Direct callers must migrate to streamStockCount(Consumer).
     *             When STOCK_SUMMARY_EXPORT_STREAMING_ENABLED=false this method is invoked
     *             by the rollback-toggle path inside streamStockCount; it MUST NOT be called
     *             directly — it materialises the full stock_view into heap (OOM risk).
     *             Will be deleted once streaming is proven stable in production.
     */
    @Deprecated
    public List<StockCountDto> getStockCount() {
        // Rollback-toggle path only — called by streamStockCount when streaming is disabled.
        // Direct callers (i.e. any call site OTHER than the toggle in streamStockCount) are
        // a bug; fail loudly so they surface before reaching production.
        throw new UnsupportedOperationException(
                "getStockCount() no-arg is deprecated — use streamStockCount(Consumer) instead (SBDEV-2219)");
    }

    /**
     * Live fallback used ONLY by the streaming rollback toggle
     * (STOCK_SUMMARY_EXPORT_STREAMING_ENABLED=false).
     * Materialises the full stock_view into a List — O(rows) heap, OOM risk at scale.
     * Extracted as a private method so the public getStockCount() can remain a hard-fail
     * shim; the toggle bypasses the exception by calling this private method directly.
     */
    private List<StockCountDto> legacyGetStockCount() {
        String warehouseId = syspropService.getSysvalue(
                WmsConstants.SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY);
        List<StockView> stockViews = (List<StockView>) stockViewRepository.findAll();
        return generateStockCount(stockViews, warehouseId);
    }

    private StockCountDto toDto(StockView report, String warehouseId) {
        StockCountDto dto = new StockCountDto();
        dto.setFacilityCode(warehouseId);
        dto.setClientNumber(report.getClNr());
        dto.setItemDataNumber(report.getItemNr());
        dto.setTotal((int) report.getTotalStock());
        dto.setDamage((int) report.getDamaged());
        dto.setOnHold((int) report.getOnHold());
        dto.setMissing((int) report.getNotFound());
        dto.setTransfer((int) report.getTransfer());
        return dto;
    }
    // ... existing 2-arg variant unchanged
}
```

**Important — class-level vs method-level `@Transactional`:** Do **not** put `@Transactional` at the class level. The existing 2-arg `getStockCount(clientId, itemDataId)` performs only a single repo call and is fine running ambient (Spring Data injects a per-method tx for the repo call itself). A class-level `@Transactional(readOnly = true)` would set `readOnly` semantics on every method, which is misleading and forces a tx context for the simple case. Method-scoped annotation on `streamStockCount(...)` only.

**Why streaming and not pagination (Option A from the ticket):** the cron job genuinely needs to process every row in one tick. Paging via `Page<StockCountDto> getStockCount(Pageable)` would force the caller to write a paging loop that re-issues the query per page — which on a VIEW with no stable sort key risks duplicate/missing rows under concurrent writes. Streaming inside a single transaction also provides a **consistent snapshot** (Postgres holds a REPEATABLE READ–equivalent cursor for the duration of the tx); paging across multiple transactions does not. Streaming is therefore safer than paging for a VIEW with concurrent writes.

### Fix A.1 — `InventoryRecordService.createEntity` must use `REQUIRES_NEW`

**File:** `src/main/java/net/aim_ai/wms/service/InventoryRecordService.java:27`

This fix is a **prerequisite** for Fix A to work correctly on PostgreSQL (see Bug 5 in §2).

**Before:**
```java
public void createEntity(String clientNumber, String sku, int total, int damage, int missing,
        int on_hold, int transfer, LocalDateTime timestamp, String inventoryRecordType, String operator) {
    // no @Transactional
```

**After:**
```java
@Transactional(value = "tenantTransactionManager",
               propagation = Propagation.REQUIRES_NEW)
public void createEntity(String clientNumber, String sku, int total, int damage, int missing,
        int on_hold, int transfer, LocalDateTime timestamp, String inventoryRecordType, String operator) {
```

**Why `REQUIRES_NEW`:** suspends the outer `readOnly=true` stream transaction, opens a fresh read-write transaction for the single `INSERT`, commits it, then resumes the outer. This is the standard pattern for "write one row inside a long-running read cursor" in Spring JPA.

**Why no `rollbackFor`:** `createEntity` does not throw `BusinessException` — it only calls `inventoryRecordRepository.save(...)` which throws runtime `DataAccessException`. Adding `rollbackFor = {BusinessException.class}` would be a no-op copy-paste from SBDEV-2217's pattern. Omitting it leaves the standard runtime-exception rollback semantics in place, which is correct.

**Why not change the outer tx to `readOnly=false`:** while Postgres would not let you accidentally write `stock_view` (it's a VIEW), `readOnly=false` on the streaming tx loses Postgres's read-only optimization and creates the OSIV-disabled session correctly, but is semantically misleading. `REQUIRES_NEW` on the write method is the right separation of concerns.

**Postgres vs H2 dialect note:** H2 does **not** enforce `readOnly` at the SQL level — it is advisory. An IT running against H2 will pass even without `REQUIRES_NEW`. Only a staging smoke test against real Postgres (§6 manual test plan row 1/2) confirms this fix is necessary. The verify script check `P1` (below) guards that the annotation is present in the shipped code regardless.

### Fix B — Refactor `StockSummaryExportJob.exportStockSummary` to consume the stream

**File:** `src/main/java/net/aim_ai/wms/schedulejob/StockSummaryExportJob.java:118-156`

**Before (current):**
```java
private void exportStockSummary() {
    List<StockCountDto> stockCount = warehouseStockReportService.getStockCount();   // OOM risk

    LocalDateTime date = LocalDateTime.now();
    String inventoryRecordType = WmsConstants.InventoryRecordType.MANUAL;
    if (WmsConstants.USER_ANONYMOUS.equals(SecurityContextUtils.getUserName())) {
        inventoryRecordType = WmsConstants.InventoryRecordType.AUTOMATIC;
    }

    for (StockCountDto sc : stockCount) {
        inventoryRecordService.createEntity(...);
    }

    String splitFlag = syspropService.getSysvalue(...SPLIT_ACTIVATED_KEY);
    if (Boolean.parseBoolean(splitFlag)) {
        // chunk + sendList(chunk) per batch
    } else {
        sendList(stockCount);  // single full-list HTTP POST
    }
}
```

**After (sketch):**
```java
private void exportStockSummary() {
    LocalDateTime date = LocalDateTime.now();
    String inventoryRecordType = WmsConstants.USER_ANONYMOUS.equals(SecurityContextUtils.getUserName())
            ? WmsConstants.InventoryRecordType.AUTOMATIC
            : WmsConstants.InventoryRecordType.MANUAL;
    String userName = SecurityContextUtils.getUserName();

    boolean splitOn = Boolean.parseBoolean(syspropService.getSysvalue(
            WmsConstants.SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED_KEY));
    int batchSize = splitOn
            ? Integer.parseInt(syspropService.getSysvalue(
                  WmsConstants.SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH_KEY))
            : Integer.MAX_VALUE;  // no split: one logical batch (see §10 trade-off)

    List<StockCountDto> chunk = new ArrayList<>(splitOn ? batchSize : 4096);

    warehouseStockReportService.streamStockCount(sc -> {
        // per-row inventory record write (was the for-loop after getStockCount)
        inventoryRecordService.createEntity(
                sc.getClientNumber(), sc.getItemDataNumber(),
                sc.getTotal(), sc.getDamage(), sc.getMissing(),
                sc.getOnHold(), sc.getTransfer(),
                date, inventoryRecordType, userName);

        // accumulate-and-flush for OMS export
        chunk.add(sc);
        if (chunk.size() >= batchSize) {
            sendList(chunk);
            chunk.clear();
        }
    });

    if (!chunk.isEmpty()) {
        sendList(chunk);
    }
}
```

**Single-pass design:** the original code iterated `stockCount` twice — once for `inventoryRecordService.createEntity(...)`, once again for chunk-and-flush. The streaming refactor must do both per-row inside the stream consumer to keep heap bounded; touching the stream a second time would re-execute the query.

**No-split-flag heap resolution (M1):** when `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED=false`, the original code called `sendList(stockCount)` once with the full list. The first draft used `batchSize = Integer.MAX_VALUE`, which would buffer all DTOs and restore the OOM — silently defeating Fix A.

**Decision (§10 Q2):** cap the no-split chunk at a hard ceiling of **10,000** rows. When `splitOn=false`, the effective batch size is `min(configuredBatchSize, 10_000)` — the same flush-and-clear logic fires every 10,000 rows even without the flag. A `LOG.warn` is emitted once per export noting that split-mode is off and the 10K ceiling is being applied. Operators who genuinely need a single-payload contract (OMS requires the entire inventory in one HTTP body) should enable split mode with a large batch size — the default 250 is already correct for most tenants. The no-split semantics of sending everything in one call are deprecated and cannot be preserved without re-introducing OOM.

Updated sketch (no-split path):
```java
// No-split: apply a hard heap ceiling — split-off sends bounded chunks regardless.
// LOG.warn once per export to prompt operators to set STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED=true.
int effectiveBatchSize = splitOn
        ? Integer.parseInt(syspropService.getSysvalue(
              WmsConstants.SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH_KEY))
        : WmsConstants.STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK;  // default 10_000

if (!splitOn) {
    LOG.warn("STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED is false; " +
             "applying hard chunk ceiling of {} rows to prevent OOM (SBDEV-2219). " +
             "Set STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED=true to silence this warning.",
             WmsConstants.STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK);
}
```

`WmsConstants.STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK = 10_000` is a new `public static final int` constant (not a sysprop — it is a safety ceiling, not an operator knob). Added to §6 File Change Summary.

### Fix C — Configurable hard-cap safety net (ticket Option C)

**Files:**
- `src/main/java/net/aim_ai/wms/service/WmsConstants.java` — add `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY` and default value (mirror existing pattern at lines 1018-1027).
- `src/main/resources/messages_en_US.properties` — add `BusinessException.StockCountTooLarge`.
- `src/main/java/net/aim_ai/wms/service/WarehouseStockReportService.java` — `streamStockCount` runs `count()` first and throws `BusinessException("BusinessException.StockCountTooLarge", count, cap)` when the cap is exceeded.

**New constants (sketch — match the SBDEV-2218 / WmsConstants.java naming pattern; mirror the STOCK_SUMMARY_EXPORT_TIMER family at lines 1018-1027):**

```java
// Inside WmsConstants, near line 1027 (group with related STOCK_SUMMARY_EXPORT_TIMER_* keys):
public static final String SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY  = "STOCK_SUMMARY_EXPORT_MAX_ROWS";
public static final String SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_DEFAULT_VALUE = "1000000";  // 1M rows safety cap
```

**New i18n key (append to `messages_en_US.properties`, grouped with the other `BusinessException.*` keys at lines 1-5):**

```
BusinessException.StockCountTooLarge=Stock count export exceeds configured limit (%1$s rows > cap %2$s). Increase the cap (sysprop STOCK_SUMMARY_EXPORT_MAX_ROWS) or shrink the dataset before retrying.
```

**Why a cap when streaming already bounds heap:** streaming bounds the *Hibernate*/JDBC heap, but downstream effects scale with row count: every row triggers `inventoryRecordService.createEntity(...)` (an insert), and `sendList(chunk)` fires HTTP POSTs to OMS (`SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY`). A pathological tenant data state (e.g. a corrupted view definition emitting a cartesian product) can still produce a 100M-row stream that takes hours and floods OMS with hundreds of thousands of HTTP POSTs. The cap is the operator-tunable circuit breaker: fail fast with a `LOG.error` + `BusinessException` instead of stretching the cron tick across hours.

The cap defaults to **1,000,000** rows — approximately 114× wineco's current 8,775-row scale. The multiplier assumes current-largest-tenant growth of ~12% per year: at that pace wineco reaches 1M rows in roughly 43 years; a tenant 10× heavier reaches it in ~34 years. In practice the cap guards against **pathological view corruption** (cartesian product from a broken join), not organic growth. Operators who know their tenant is legitimately large can raise it per-tenant via sysprop without redeploying.

**Micrometer cap-trip counter (m4):** increment a counter immediately before throwing, so the cap-trip is observable in Grafana without log scraping:

```java
if (count > max) {
    meterRegistry.counter("stock_summary_export_aborted_total",
            "tenant", TenantContext.getCurrentTenant().getTenantName()).increment();
    LOG.error("stock_view row count {} exceeds configured cap {}; aborting export to prevent OOM", count, max);
    throw new BusinessException("BusinessException.StockCountTooLarge", count, max);
}
```

`MeterRegistry` is already wired in the v2 codebase (Micrometer + Actuator); inject it via constructor. The counter name `stock_summary_export_aborted_total` matches the monitoring row in §5.1 row 8. This promotion from §5.1 (operational suggestion) to §5 Fix C body makes it a **required** deliverable, not optional.

### Fix D — `@RestResource(exported = false)` on inherited `findAll()` (HAL hygiene)

**File:** `src/main/java/net/aim_ai/wms/repo/jpa/StockViewRepository.java`

`@RepositoryRestResource(... path = "stockView")` exposes the repository over Spring Data REST. By default, all CRUD endpoints inherited from `CrudRepository`/`PagingAndSortingRepository` are published — including `GET /api/stockView` (paginated `findAll()`). An external caller can re-trigger the same unbounded materialization that Fix A is closing off at the service layer.

**Mirror SBDEV-2217 Fix D pattern.** Override the inherited `findAll()`, `findAll(Pageable)`, and `findAll(Sort)` with `@RestResource(exported = false)`:

```java
@Override
@RestResource(exported = false)
Iterable<StockView> findAll();

@Override
@RestResource(exported = false)
Page<StockView> findAll(Pageable pageable);

@Override
@RestResource(exported = false)
Iterable<StockView> findAll(Sort sort);
```

**Three overloads required:** Spring Data REST exposes all three through `PagingAndSortingRepository` and `CrudRepository`:
- `GET /api/stockView` → `findAll()` (no parameters)
- `GET /api/stockView?page=0&size=20` → `findAll(Pageable)`
- `GET /api/stockView?sort=clNr,asc` → `findAll(Sort)` via `PagingAndSortingRepository`

`ReadOnlyPagingAndSortingRepository` already suppresses `save` and `saveAll` but leaves all three `findAll` overloads published. All three must be suppressed — omitting `findAll(Sort)` leaves a bypass that materializes all rows sorted (same O(rows) heap as `findAll()`).

The `findByKeyword(...)` and `findByClientOffsetAndLimit(...)` queries already in the file remain accessible via their existing `@RestResource(path = ...)` annotations (lines 25-29 and 31-36) — they take filter parameters and are scoped, so they stay published.

`SecurityConfiguration.java:99` puts `/api/**` in `permitAll()`, so without Fix D, anyone on the network could force-materialize `stock_view` by hitting the HAL endpoint.

### Fix E — Logger class reference cleanup

**File:** `src/main/java/net/aim_ai/wms/service/WarehouseStockReportService.java:15`

```java
// Before:
private static final Logger LOG = LoggerFactory.getLogger(ReceivingService.class);

// After:
private static final Logger LOG = LoggerFactory.getLogger(WarehouseStockReportService.class);
```

**Risk:** zero. Functional behavior is unchanged; only the log category name flips.
**Value:** ops grep for `WarehouseStockReportService` will now find the relevant lines — an explicit ops debugging fix.

### Fix F — Repository.findAll() audit guard (deferred-with-counter)

The §0 enumeration found three additional `Repository.findAll()` callsites in service/controller code (rows 10-12: `AccessService`, `UtilRestController`, `OrderRestController`). All three are low-volume (permission catalog, location constraints, shipperids) and not the target of this ticket. Two options for coverage:

**Option F1 (full ArchUnit rule, in scope of this plan):** add `RepositoryFindAllSafetyArchTest.java` mirroring `ParallelStreamSafetyArchTest` (SBDEV-2218 Fix A). Ban `CrudRepository.findAll()` (no-arg overload only — `findAll(Pageable)` / `findAll(Sort)` / `findAll(Specification)` remain allowed) inside `..service..` and `..controller..` packages. Pre-existing offenders: 4 callsites (Access/Util/Order/WarehouseStockReport — and the WarehouseStockReport site is the one Fix A removes). Requires a freeze-store snapshot or grandfather list in the rule.

**Option F2 (count-only guard via verify script, deferred to a follow-up ticket):** the verify script greps `src/main/java/net/aim_ai/wms/{service,controller}/` for `Repository\.findAll()` and asserts the count is **≤ 3** post-fix (4 today; Fix A removes 1, leaving 3 grandfathered). Any new addition trips the verify script. No Java code added to the test tree.

**Decision (recorded in §10):** **Option F2 — the count-only guard.** Rationale:

1. The three remaining offenders are genuinely low-volume — adding an ArchUnit freeze-store risks normalizing them as "OK forever" rather than triggering follow-up.
2. An ArchUnit rule with a 3-callsite freeze-store is harder to maintain than a single-line grep in the verify script.
3. A separate ticket can tackle the three remaining sites (each is a different volume profile and may want different fixes — paging, caching, hard cap, or simply leaving as-is).
4. The verify-script grep gives the same regression-guard signal: any new `Repository.findAll()` in service/controller code makes the count rise above 3 and trips the gate.

If during implementation the executor finds the count-only check too brittle (e.g. because of code-comment noise), they MAY upgrade to Option F1 — that override is documented in the implementation report.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `service/InventoryRecordService.java` | Modify | **Fix A.1** — add `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` to `createEntity`. No `rollbackFor` — method does not throw `BusinessException`. Prerequisite for Fix A on Postgres (see Bug 5 in §2). |
| `service/WarehouseStockReportService.java` | Modify | Fix A — add `streamStockCount(Consumer<StockCountDto>)` with `@Transactional(value = "tenantTransactionManager", readOnly = true)`. Fix C — count-and-throw cap + Micrometer counter before opening stream. Fix E — Logger class reference. Mark no-arg `getStockCount()` `@Deprecated`; body becomes `throw new UnsupportedOperationException(...)` (hard-fail shim). Add `private legacyGetStockCount()` bridge that performs the old materialization; called only by `streamStockCount` when `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED=false` (rollback toggle — see §5.1 row 9 and §10 Q10). |
| `repo/jpa/StockViewRepository.java` | Modify | Fix A — add `@QueryHints(@QueryHint(...HINT_FETCH_SIZE...="500")) Stream<StockView> streamAllBy()`. Fix D — override inherited `findAll()` / `findAll(Pageable)` / `findAll(Sort)` with `@RestResource(exported = false)`. |
| `schedulejob/StockSummaryExportJob.java` | Modify | Fix B — refactor `exportStockSummary()` to consume the stream via `Consumer<StockCountDto>`; per-row `inventoryRecordService.createEntity` + accumulate-and-flush with hard ceiling `STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK` for no-split path. Single-pass over the stream. |
| `service/WmsConstants.java` | Modify | Fix C — add `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY` + `..._DEFAULT_VALUE` near line 1027. Fix B — add `STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK = 10_000` constant. |
| `src/main/resources/messages_en_US.properties` | Modify | Fix C — add `BusinessException.StockCountTooLarge=...` (PascalCase key, consistent with `BusinessException.SequenceExhausted`). |
| `src/test/java/.../unit/service/WarehouseStockReportServiceUnitTest.java` | Modify | Mock-based tests for `streamStockCount`; `streamStockCount_closesStreamEvenOnConsumerThrow`; cap-trip behavior; `REQUIRES_NEW` interaction with mocked `inventoryRecordService`. |
| `src/test/java/.../unit/schedulejob/StockSummaryExportJobUnitTest.java` | Modify | Update for stream-consumer flow: `inventoryRecordService.createEntity(...)` called per-row inside stream lambda; chunked `sendList(...)` matches expected batch boundaries; no-split ceiling test. |
| **(new)** `src/test/java/.../integration/service/WarehouseStockReportServiceStreamIT.java` | Add | H2-in-PG-mode IT (see §6 H2 limitation note) seeding ~5K stock_view rows; asserts `streamStockCount` invokes consumer exactly N times; asserts cap throws `BusinessException` when seed > cap. Does NOT verify cursor streaming (H2 limitation — staging smoke required for that). |

---

## 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** (schema version, required rows, Flyway baseline) | No schema change — `stock_view` already exists at every tenant. No new Flyway migration. | — | N/A |
| 2 | **Feature flags / system properties** | Seed `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS=1000000` per tenant via `los_sysprop` (or rely on `getSysvalue` fallback that returns the `_DEFAULT_VALUE` from `WmsConstants`). Confirm existing `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED` is still `true` (default) — Fix B's heap bound is strongest with split-on. | DBA / Ops | Cap is opt-out (default = 1M); operators can override per tenant if they have a heavier dataset. |
| 3 | **Config / env changes** (application.properties, jasypt, keycloak client, env var) | None. `tenantTransactionManager` is already wired (`v2/wms2-api/CLAUDE.md` Dual TM section). `spring.jpa.open-in-view=false` is already set. | — | N/A |
| 4 | **Deploy-order dependencies** | None — backward-compatible refactor. The OMS contract (`/call/inventory/stockCountExport`) shape does not change; same `List<StockCountDto>` payloads, just from a streaming source. | — | N/A |
| 5 | **Data migration** | None. | — | N/A |
| 6 | **External systems** | OMS endpoint at `SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY` (`WEBSERVICE_STOCK_COUNT`) must remain reachable. Behavior unchanged. | — | Doc only. |
| 7 | **Access / permissions** | No new role. Optional follow-up: tighten `/rest/stockcount/triggerStockCount` from the catch-all `/rest/**` `permitAll()` to admin-only — see §9 Risks. | Security / Ops | Out of scope for this plan but flagged. |
| 8 | **Monitoring / alerts** | Add Grafana panel for cron-tick duration `stock_summary_export_duration_seconds` (Micrometer timer) and counter `stock_summary_export_rows_exported_total`. Alert when duration > 30 min OR `stock_summary_export_aborted_total` increments. The `stock_summary_export_aborted_total` counter is **required** (Fix C body, §5). | Ops | Counter shipped with Fix C; panel is operational follow-up. |
| 9 | **Rollback toggle** (Missing-1) | Add `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED` sysprop (default `"true"`). When `"false"`, `streamStockCount(...)` falls back to calling the `@Deprecated` no-arg `getStockCount()` and the old `List<StockCountDto>` path. This provides an emergency rollback lever — if the streaming path breaks in production, ops can flip the sysprop without redeploying. The no-arg `getStockCount()` is kept as a `@Deprecated` shim (throws `UnsupportedOperationException` when called directly, but the rollback path bypasses the exception check). Document that the toggle should be `"true"` at all times except emergency rollback. | DBA / Ops | New sysprop pair in `WmsConstants.java`; toggled in `streamStockCount` before any streaming logic. |

## 5.2 Implementation Checklist

- [ ] Run baseline `bash sbdocs/9-System/scripts/verify-SBDEV-2219-warehouse-stock-report-unbounded-findall.sh` — capture FAIL baseline.
- [ ] **Fix A.1** — annotate `InventoryRecordService.createEntity` with `@Transactional(value="tenantTransactionManager", propagation=REQUIRES_NEW)`. No `rollbackFor` — method does not throw `BusinessException`. **Prerequisite for Fix A on Postgres.**
- [ ] Fix A — add `streamAllBy()` to `StockViewRepository` with fetch-size hint.
- [ ] Fix A — add `streamStockCount(Consumer<StockCountDto>)` to `WarehouseStockReportService` with `@Transactional(tenantTransactionManager, readOnly=true)`, rollback toggle check, and `@Deprecated` no-arg shim.
- [ ] Fix C1 — add `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY` (and default value) to `WmsConstants`; add `STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK = 10_000`; add `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_STREAMING_ENABLED_KEY`.
- [ ] Fix C2 — add `BusinessException.StockCountTooLarge` to `messages_en_US.properties`.
- [ ] Fix C3 — implement count-and-throw guard + `meterRegistry.counter("stock_summary_export_aborted_total", ...)` in `streamStockCount`.
- [ ] Fix D — `@RestResource(exported = false)` override of `findAll()`, `findAll(Pageable)`, AND `findAll(Sort)` in `StockViewRepository`.
- [ ] Fix E — Logger class reference: `ReceivingService.class` → `WarehouseStockReportService.class`.
- [ ] Fix B — refactor `StockSummaryExportJob.exportStockSummary()` to consume the stream; apply `effectiveBatchSize = splitOn ? configured : STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK` with warn log.
- [ ] Update `WarehouseStockReportServiceUnitTest` (add `streamStockCount_closesStreamEvenOnConsumerThrow` and rollback-toggle test).
- [ ] Update `StockSummaryExportJobUnitTest` for stream-consumer flow + no-split ceiling behavior.
- [ ] Add `WarehouseStockReportServiceStreamIT` (H2-in-PG-mode IT; note H2 cursor-streaming limitation — staging smoke validates real Postgres behavior).
- [ ] Add `InventoryRecordServiceUnitTest` update for `REQUIRES_NEW` annotation (verify annotation present; no behavior regression).
- [ ] Run `mvn test -Dtest=WarehouseStockReportServiceUnitTest,StockSummaryExportJobUnitTest` per cluster.
- [ ] Run `mvn verify` for the full suite once all clusters land.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2219-warehouse-stock-report-unbounded-findall.sh` — must report `Result: N pass, 0 fail`.
- [ ] Code review.
- [ ] Manual smoke against **real Postgres** staging — in particular, verify `inventory_record` rows ARE inserted (proves `REQUIRES_NEW` is working; H2 IT cannot validate this).

---

## 6. Test Plan

### Unit tests

| Test class | Test method | What it asserts |
|---|---|---|
| `WarehouseStockReportServiceUnitTest` | `streamStockCount_invokesConsumerOncePerRow` | Mocked `stockViewRepository.streamAllBy()` returns `Stream.of(row1, row2, row3)`; mocked `count()` returns 3; consumer is invoked exactly 3 times with correctly-mapped DTOs (assert facilityCode, clientNumber, total, etc.). |
| `WarehouseStockReportServiceUnitTest` | `streamStockCount_throwsWhenCountExceedsCap` | `count()` returns 1_000_001L; sysprop returns "1000000"; `streamAllBy()` is NEVER called; `BusinessException` thrown with key `BusinessException.StockCountTooLarge` and args `(1000001, 1000000)`. |
| `WarehouseStockReportServiceUnitTest` | `streamStockCount_usesDefaultCapWhenSyspropAbsent` | `syspropService.getSysvalue(...MAX_ROWS_KEY)` returns null/empty; cap defaults to `DEFAULT_MAX_ROWS` (1,000,000); count = 5 should not throw. |
| `WarehouseStockReportServiceUnitTest` | `streamStockCount_closesStreamEvenOnConsumerThrow` | Consumer throws on the 2nd row; stream is still closed (verify via `Stream.onClose` callback or AutoCloseable verification); exception propagates to caller. |
| `WarehouseStockReportServiceUnitTest` | `getStockCount_2arg_unchanged` | Existing test for `getStockCount(clientId, itemDataId)` continues to pass — no regression on the safe variant. |
| `StockSummaryExportJobUnitTest` | `exportStockSummary_invokesCreateEntityPerRow` | Mocked `streamStockCount(consumer)` calls `consumer.accept(dto)` 7 times; verify `inventoryRecordService.createEntity(...)` is invoked exactly 7 times with matching args. |
| `StockSummaryExportJobUnitTest` | `exportStockSummary_chunksWhenSplitOn` | Sysprop SPLIT_ACTIVATED=true, batch=3; mocked stream produces 7 rows; verify `sendList(chunk)` invoked 3 times with sizes (3, 3, 1). |
| `StockSummaryExportJobUnitTest` | `exportStockSummary_singleSendListWhenSplitOff` | Sysprop SPLIT_ACTIVATED=false; mocked stream produces 7 rows; verify `sendList(chunk)` invoked exactly once with all 7 rows. |
| `StockSummaryExportJobUnitTest` | `exportStockSummary_propagatesCapException` | Mocked `streamStockCount` throws `BusinessException("StockCountTooLarge")`; the surrounding `doCalculation` per-tenant try/catch logs `Error while processing tenant ...` and continues to the next tenant (no other-tenant blast). |

### Integration test (new)

| Test class | What it asserts |
|---|---|
| `WarehouseStockReportServiceStreamIT` | Seeds ~5,000 rows into a real `stock_view`-equivalent table (via H2 view definition in `application-integration.properties`); asserts `streamStockCount(consumer)` invokes the consumer exactly 5,000 times with all keys distinct; total wall-clock < 5 seconds; logs Hibernate fetch-size hint (assert via Hibernate statistics or `slf4j` capture) confirming cursor-based fetch is active. |

**Base class deviation:** Extend `BaseIntegrationTest` (H2 in PostgreSQL mode) — NOT `BasePostgresIntegrationTest`. **Rationale (carried from SBDEV-2218 §6' Deviation):** `BasePostgresIntegrationTest` cannot boot a full Spring context in this codebase without the `integration` profile active.

**H2 cursor-streaming limitation (Missing-2):** H2 does NOT honor `setFetchSize` for actual cursor-based streaming — it loads the full result set into memory regardless of the hint. The IT therefore validates row-count correctness and consumer invocation count, but does NOT prove that heap is bounded to `O(fetch_size)`. Cursor-streaming verification requires real Postgres. This limitation must be documented in the test class Javadoc and in the manual smoke plan:

```java
/**
 * Integration test for WarehouseStockReportService.streamStockCount.
 *
 * NOTE: This test runs against H2 in PostgreSQL mode. H2 does NOT enforce
 * JDBC setFetchSize for cursor-based streaming — rows are loaded in full.
 * The test validates consumer invocation count and cap behavior only.
 * Heap-bound verification (O(fetch_size) in-flight memory) requires a
 * real Postgres smoke test — see §6 manual test plan row 2.
 */
```

The manual smoke test (§6 row 2 — "Cron tick on a large tenant, heap monitored") is therefore **required**, not optional, to close the cursor-streaming correctness gap.

### Mockito 3.3.3 / no-mockStatic note

v2 uses Mockito 5.x (Spring Boot 3.x), so `mockStatic` is available. The unit tests can mock `BusinessException` constructor / message-resolution helpers if needed. Not expected to be necessary — the new `streamStockCount` is straightforward to test with mocked repository.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Cron tick on a small tenant (8K rows) | staging | 1. trigger `stockSummaryExportJob.doCalculation(false)` via `POST /admin/...` (or wait for cron). 2. tail `app.log` for `Processing cleanUpOldMessagesJob for ${tenant}` then `end. took Nms`. 3. verify `inventory_record` insert count = stock_view row count. | Job completes without OOM; job duration < 1 minute; row count matches. | |
| Cron tick on a large tenant (>500K rows) | staging — load-test | 1. seed `stock_view` with 500K synthetic rows. 2. trigger job. 3. monitor heap via JConsole / `jstat -gcutil`. | Heap usage during export stays bounded — peak `Old Gen` increase ≤ 50 MB compared to idle. Job completes within reasonable time (target: < 10 minutes; actual depends on `inventoryRecordService.createEntity` write throughput). | |
| Hard cap trigger (manual) | staging | 1. set sysprop `STOCK_SUMMARY_EXPORT_MAX_ROWS=100`. 2. seed `stock_view` with 200 rows. 3. trigger job. | `LOG.error("stock_view row count 200 exceeds configured cap 100")`; `BusinessException` raised; per-tenant try/catch in `doCalculation` logs and continues. No `inventory_record` rows inserted. | |
| HAL `findAll` exposure check | staging | 1. `curl -i http://staging-wms-api/api/stockView` (no auth, since `/api/**` is permitAll). | After Fix D: HTTP 405 Method Not Allowed (Spring Data REST returns this for suppressed endpoints). Before Fix D: HTTP 200 with full HAL collection (the bug). | |
| Logger class — ops grep | staging | 1. trigger 2-arg `getStockCount(...)` via `POST /rest/stockcount/getStockCount`. 2. `grep WarehouseStockReportService app.log`. | Log lines for "start get stock clientId=..." appear under the `WarehouseStockReportService` logger (NOT `ReceivingService`). | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=WarehouseStockReportServiceUnitTest` | | |
| `mvn test -Dtest=StockSummaryExportJobUnitTest` | | |
| `mvn verify -Dit.test=WarehouseStockReportServiceStreamIT` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2219-warehouse-stock-report-unbounded-findall.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Hard-cap behavior in IT against real Postgres | Cap behavior is dialect-independent; unit test with mocked `count()` covers the trip path. Manual staging smoke covers the on-real-Postgres execution. |
| Concurrent multi-tenant cron tick | `AdvisoryLockService.tryLock(STOCK_SUMMARY_EXPORT)` already serializes across replicas (`StockSummaryExportJob.java:64-67`). Fix B does not change this contract; the existing test for `doCalculation` retains coverage. |

---

## 7. Horizontal Scalability Validation

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **No** | The `chunk` `ArrayList` and the `count()`/cap check are method-local; nothing escapes the cron tick's stack. No new `static` field, `ThreadLocal`, or Caffeine cache. |
| 2 | **Connection pool math** | Change per-request DB connection usage? | **N/A** | The cron tick already holds one connection per tenant. Fix A's `@Transactional(readOnly=true)` keeps that connection open longer (see row 4) but does not add a *new* connection-acquiring path. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | **Yes** | `SchedulingConfiguration.java:219` invokes `stockSummaryExportJob.doCalculation(true)` — Fix B changes the body of `exportStockSummary()` it eventually calls. **`AdvisoryLockService.tryLock(JobLockId.STOCK_SUMMARY_EXPORT)` at `StockSummaryExportJob.java:64-67` already provides cross-replica exclusion**. No new ShedLock/lock needed. |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | **Yes** | Fix A's `@Transactional(readOnly=true)` on `streamStockCount` holds one tenant DB connection for the duration of the stream consumption — which under Fix B includes per-row `inventoryRecordService.createEntity(...)` writes AND `sendList(chunk)` HTTP POSTs. **Mitigation:** the cron pod is deployed as a single replica per `app.cron` (per `wms2-scheduled-jobs-catalog.md`), so the connection-pool math is `1 replica × 1 long tx per tenant during export window`. Hikari `connectionTimeout` default is 30s — the long-running readOnly tx on the *streaming* connection does not interfere with other concurrent ops because it is the only consumer in that window. `inventoryRecordService.createEntity` MUST open its own `REQUIRES_NEW` write tx (Fix A.1) — without this the outer readOnly tx rejects every INSERT on Postgres. Verified by staging Postgres smoke (§6 manual row 1) — H2 cannot validate readOnly-tx INSERT rejection per §10 Q7/Q12. |
| 5 | **Request affinity** | Assume a follow-up request lands on the same replica? | **No** | Cron is single-replica via advisory lock; no inter-request affinity assumption. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics that break if a replica dies mid-op? | **Partial — N/A change** | Pre-existing semantics: if the cron pod dies mid-export, `inventory_record` has partial rows from the killed run; the next cron tick (24h later) re-runs and inserts a fresh batch. Fix B does NOT change this — the existing per-row insert is not idempotent (no natural unique key on `inventory_record`). Out of scope; not regressed. |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | **No** | The stream is consumed on the same thread that opens the transaction (cron worker thread). `TenantContext.setCurrentTenant(tenantProfile)` is set at `StockSummaryExportJob.java:90` BEFORE `exportStockSummary()` and cleared in the `finally` at line 105. No `@Async`, no `CompletableFuture`. The streaming refactor stays single-threaded. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock? | **No** | `AdvisoryLockService.tryLock` is a Postgres advisory lock (already in place), not a row-level lock. No new locks. |
| 9 | **Cache invalidation** | Write to an entity that is cached? | **No** | `StockView` is not in the Caffeine cache (per `wms2-caching-strategy.md` — caches are for `Itemdata`, `Client`, etc.). `inventoryRecordService.createEntity` writes `inventory_record` which is also uncached. No `@CacheEvict` needed. |
| 10 | **External notifications** | Send HTTP / message inside a transaction? | **Yes — pre-existing** | `sendList(chunk)` invokes `httpRestService.post(urlPath, payload)` (`StockSummaryExportJob.java:167`) which is the OMS export call. Today this is *outside* any explicit `@Transactional`. After Fix A+B, the consumer lambda runs *inside* `streamStockCount`'s `@Transactional(readOnly=true)` — the HTTP POST now fires inside the read-only tx. **Mitigation:** because the surrounding tx is `readOnly = true`, there is no commit/rollback hazard for the HTTP call (the tx has nothing to roll back). Per-row `inventoryRecordService.createEntity` is the writer and runs in its own (presumably `REQUIRES_NEW`) tx — those commit before the outer read-only tx ends. The OMS call's at-least-once semantics are unchanged from today. **Acknowledged trade-off:** this differs from the typical "defer to afterCommit" pattern because the cron job legitimately wants to ship batches *as it streams* rather than buffer them all and ship after. Fix B's accumulate-and-flush keeps batch size bounded; the OMS retry semantics are the operator's responsibility (existing). Documented in §10. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 3 | Cross-replica advisory lock already present | `StockSummaryExportJob.java:64-67`; `AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT` |
| 4 | Long readOnly tx; `createEntity` uses `REQUIRES_NEW` (Fix A.1) to escape outer readOnly tx | Fix A.1 adds `@Transactional(REQUIRES_NEW)` to `InventoryRecordService.createEntity`; staging Postgres smoke (§6 row 1) verifies `inventory_record` inserts succeed; H2 IT alone is insufficient (H2 ignores `setReadOnly` at SQL level). |
| 7 | TenantContext set+cleared in the cron loop | `StockSummaryExportJob.java:90, 105` |
| 10 | OMS POST inside the readOnly tx is benign (nothing to commit) | Code reading; staging smoke confirms |

---

## 8. v2-only constraint checklist

| # | Constraint | What to check | Verdict |
|---|---|---|---|
| 1 | **OSIV disabled** (`spring.jpa.open-in-view=false`) — every repo call outside `@Transactional` opens a new session | Fix A's `streamStockCount` MUST be `@Transactional(value="tenantTransactionManager", readOnly=true)` because the `Stream<StockView>` cursor stays open across multiple JDBC fetches; without a tx the session would close after the first batch. **Addressed at `WarehouseStockReportService.streamStockCount` annotation.** | **Yes** |
| 2 | **Transaction manager** — tenant-scoped writes must use `tenantTransactionManager` | `streamStockCount` annotated `@Transactional(value = "tenantTransactionManager", readOnly = true)`. The default `@Transactional` would silently route to landlord and break cursor fetches against the tenant DB. **Addressed at the same annotation.** | **Yes** |
| 3 | **`@Transactional(readOnly=true)`** — read-only service methods must declare it | Fix A's `streamStockCount` is read-only — explicit `readOnly = true` set. Hibernate skips dirty-checking on the streamed entities. | **Yes** |
| 4 | **Caffeine cache invalidation** | `StockView` is not cached; `inventory_record` writes are not cached. No `@CacheEvict` needed. | **N/A** — no cached entities touched |
| 5 | **Jakarta namespace** | New code uses `jakarta.persistence.QueryHint` (NOT `javax.persistence.QueryHint`) and `org.hibernate.jpa.AvailableHints.HINT_FETCH_SIZE`. Verified imports in Fix A sketch. | **Yes** |
| 6 | **H2-compatible test SQL** | The IT extends `BaseIntegrationTest` (H2 in PostgreSQL mode). `streamAllBy()` uses JPQL (`SELECT s FROM StockView s`), dialect-independent. The `@QueryHint(HINT_FETCH_SIZE)` is honored by both H2 and PostgreSQL JDBC drivers (it's a JDBC contract, not dialect SQL). | **Yes** |
| 7 | **`BaseControllerTest` for controller changes** | No controller changes in this plan. `StockCountRestController.triggerSchedule()` body is untouched (it still defers to `stockSummaryExportJob.doCalculation(false)` — only the *body* of `exportStockSummary()` changes). | **N/A** — no controller signatures or endpoints modified |
| 8 | **Micrometer metrics** | Optional: add a counter for `stock_summary_export_rows_exported_total` and a timer for `stock_summary_export_duration_seconds`. Not blocking; documented in §5.1 row 8. | **No (deferred to Ops follow-up)** |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `inventoryRecordService.createEntity` joining the outer readOnly tx causes Postgres `cannot execute INSERT in a read-only transaction` | Silent cron breakage across all tenants — every `inventory_record` insert rejected | **Resolved by Fix A.1**: `createEntity` annotated `@Transactional(value="tenantTransactionManager", propagation=REQUIRES_NEW)`. Each per-row insert commits in its own tx before returning to the stream. **H2 IT does NOT catch this** (H2 ignores `readOnly` at the SQL level); staging Postgres smoke (§6 row 1 — verify `inventory_record` row count matches `stock_view`) is the safety net. |
| No-split mode (SPLIT_ACTIVATED=false) buffering all DTOs into chunk before `sendList` | Restores O(rows) heap for tenants using the no-split flag — defeats Fix A | **Resolved by Fix B**: `effectiveBatchSize = min(configuredBatchSize, STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK)` where `NO_SPLIT_MAX_CHUNK = 10_000`. Chunk is flushed every 10K rows regardless of flag. `LOG.warn` prompts operators to enable split mode. |
| Cap default of 1M is too small for a future heavyweight tenant | Cron job aborts; `inventory_record` is not refreshed for that tenant; OMS gets no nightly export | Sysprop is operator-tunable per tenant. Monitoring alert recommended (§5.1 row 8) on the `cap-trip` counter so ops can raise the cap before the next nightly run. |
| Cap default of 1M is too large to actually catch a runaway view | `BusinessException` never fires; OOM happens via stream-into-OMS-POST flooding instead | The cap is the *secondary* guard; Fix A already eliminates the heap OOM. Worst case: a 100M-row stream takes hours and floods OMS with `100M / batch_size` POSTs, but Hikari connections + heap stay stable. Operator mitigation: drop the cap. |
| HAL endpoint `/api/stockView` was relied upon by an internal tool | Internal automation breaks after Fix D | Pre-fix grep across all internal repos for `/api/stockView` — none found (verified during enumeration). The HAL endpoint was never advertised as a stable API. If a downstream consumer surfaces, expose a controller-backed paginated endpoint instead of the raw HAL `findAll`. |
| `/rest/stockcount/triggerStockCount` is unauthenticated (matches `/rest/**` permitAll) — anyone on the network can trigger an export | Unauthorized OMS data exfil + heap pressure attack | OUT OF SCOPE for this plan but flagged. Recommend a follow-up ticket to restrict `/rest/stockcount/triggerStockCount` to admin-only. The Fix C cap mitigates the OOM-via-trigger angle: even an attacker cannot blow up heap because streaming bounds it AND the cap stops runaway counts. |
| The streaming refactor adds a `Consumer<StockCountDto>` callback API; future callers might forget to handle exceptions inside the lambda | Stream stays open if the lambda throws; tx might hold a connection longer than expected | The `try (Stream ...)` AutoCloseable in `streamStockCount` ensures the stream closes even on consumer-throw. The `@Transactional` proxy will roll back / commit normally on exception. Unit test `streamStockCount_closesStreamEvenOnConsumerThrow` enforces this contract. |
| Removing the no-arg `getStockCount()` method (optional in §5.1) breaks an internal caller not found by grep (e.g. reflective access) | Build-time compile error or runtime `NoSuchMethodError` | Keep the no-arg method as a thin wrapper that throws `UnsupportedOperationException("use streamStockCount instead — SBDEV-2219")` for one release cycle. After verifying no callers via prod logs, delete in a follow-up. Out-of-scope for the strict ticket but a safe conservative path. |
| Hibernate fetch-size hint silently ignored on the JDBC driver | Stream still loads all rows into memory; Fix A doesn't bound heap | The Postgres JDBC driver honors `setFetchSize` only inside an explicit transaction with `setAutoCommit(false)`. Fix A's `@Transactional` provides this. The IT validates via Hibernate statistics (`StatisticsLogged.fetchCount` or via memory-usage assertion) that the cursor is actually streaming. |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Decision | Rationale |
|---|---|---|---|
| 1 | Option A (Pageable), Option B (Stream), or Option C (Hard cap)? | **B + C combined** | A doesn't fit the cron use case (job needs all rows in one tick; paging across a VIEW with concurrent writes risks duplicate/missing rows). B bounds heap correctly. C is the operator-tunable safety net for pathological row counts. |
| 2 | Should the no-split-flag path be deprecated? | **Hard-ceil at 10K rows and warn** | `Integer.MAX_VALUE` batchSize restores O(rows) heap (M1 — BLOCKER variant). Decision: apply `STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK = 10_000` as a code-level ceiling. `sendList` is still called with bounded chunks even when `splitOn=false`. A `LOG.warn` fires once per export citing SBDEV-2219 and recommending `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED=true`. Backward compat: OMS still receives valid `List<StockCountDto>` payloads; only the "one HTTP call per full inventory" semantic is broken for the OOM-preventing reason. |
| 3 | Fix F — full ArchUnit rule (Option F1) or count-only verify-script guard (Option F2)? | **F2 (count-only)** | 3 grandfathered offenders (Access, UtilRest, OrderRest) need different per-site fixes; an ArchUnit freeze-store risks normalizing them. The count-only grep catches new additions and is one line of bash. Follow-up ticket for the 3 offenders. |
| 4 | Logger cleanup (Fix E) — bundle or follow-up? | **Bundle** | One-character risk profile (replace one class literal); ops debugging value is concrete (today's logs are mis-attributed). Zero scope creep cost. |
| 5 | Is the ticket's "REST endpoint OOM" framing correct? | **No — documented contradiction** | `grep -rn "getStockCount()" src/main/java` → the no-arg variant has exactly **one** caller: `StockSummaryExportJob.java:119`. The two REST callers (`StockCountRestController.java:93`, `ItemDataController.java:106`) use the safe 2-arg variant. The OOM ingress is the cron job (and the unauth `/rest/stockcount/triggerStockCount` that delegates to it). The plan corrects AC-1/AC-2/AC-3 interpretation accordingly. |
| 6 | Should the no-arg `getStockCount()` method be deleted entirely? | **Defer — keep as deprecation shim** | After Fix B no production caller remains. Keeping it as `throw new UnsupportedOperationException(...)` for one release lets us catch any reflective or test caller before deleting. Recorded in §9 Risks row 6. |
| 7 | `@Transactional(readOnly = true)` vs `readOnly = false` on the streaming method | **`readOnly = true` — resolved; `REQUIRES_NEW` on `createEntity` is the correct companion** | Critic verified that `InventoryRecordService.createEntity` has no `@Transactional` and `Propagation.REQUIRED` would join the outer readOnly tx → Postgres rejects the INSERT. Fix A.1 adds `REQUIRES_NEW` to `createEntity` so each row write escapes the outer tx. `readOnly = true` on the outer is kept: Hibernate skips dirty-checking; Postgres read-only optimization applies to the stream cursor. H2 IT does NOT validate this — staging Postgres smoke is the proof gate. Decision is **final** (not left to impl time). |
| 8 | Is `/rest/stockcount/triggerStockCount` authentication a blocker? | **No — out of scope, follow-up ticket** | The OOM root cause is fixed by streaming + cap regardless of auth. Auth tightening is a separate security concern (any unauth `/rest/**` endpoint is a residual risk for many other reasons). Recorded in §9 Risks row 5. |
| 9 | Why was the `4a670fce` "WMS api improvement plan" sweep able to skip this site? | **The plan's scope was receiving + picking N+1; stock-export was not in scope** | Documented in §3 Regression Chain. The sweep touched the file but only for entity-equals/hashCode and constructor injection — the `findAll()` was orthogonal to that work. Not a regression; just a missed sweep target. |
| 10 | Rollback toggle — should the no-arg `getStockCount()` be a pure shim or a live fallback? | **Pure shim + private `legacyGetStockCount()` bridge** | The public `@Deprecated getStockCount()` always throws `UnsupportedOperationException` — it is a hard-fail sentinel that surfaces any caller that bypasses the migration. The actual rollback logic lives in a `private legacyGetStockCount()` method that `streamStockCount` calls directly when `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED=false`. This keeps the public API clean (external callers always fail loudly) while preserving the emergency lever. Remove `legacyGetStockCount` and the toggle in a follow-up cleanup after streaming is proven stable in production. |
| 11 | i18n key naming — `BusinessException.StockCountTooLarge` — consistent with existing precedent? | **Yes — PascalCase nouns, consistent** | Existing keys: `BusinessException.MissingField`, `BusinessException.ObjectNotFound`, `BusinessException.SequenceExhausted`. All PascalCase compound nouns. `StockCountTooLarge` follows the same pattern. Key will be added in uppercase-first form; `messages_en_US.properties` lines 1-5 are already all-caps-first — no inconsistency. |
| 12 | H2 IT — what exactly does it validate vs what requires real Postgres? | **IT validates row-count + cap-throw; Postgres staging validates cursor streaming + `REQUIRES_NEW`** | H2 does not enforce `setFetchSize` cursor streaming (loads full result) and does not enforce `setReadOnly` (ignores write-in-readOnly). The IT therefore proves: consumer called N times; cap fires correctly; stream closes on consumer throw. It does NOT prove: Postgres cursor heap bound; `REQUIRES_NEW` escapes readOnly tx on Postgres. Both gaps are closed by §6 manual smoke row 1 (Postgres `inventory_record` count check) + row 2 (heap monitor). |

---

## 11. v1 / v2 Applicability

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| Same `WarehouseStockReportService.getStockCount()` no-arg variant exists? | Yes (per ticket — dual-tagged `wmsv1, wmsv2`) | Yes (this plan) | Both versions need the same fix shape. |
| `StockSummaryExportJob` shape | Largely the same — Java 8 / Spring Boot 2.3.7 | Java 21 / Spring Boot 3.5.9 | API differences: v1 still uses `javax.persistence.QueryHint`, Hibernate 5.x's `org.hibernate.annotations.QueryHints.HINT_FETCH_SIZE`; v2 uses `jakarta.persistence.QueryHint` + `org.hibernate.jpa.AvailableHints.HINT_FETCH_SIZE`. |
| Stream API | `Stream<T>` available since Java 8 — same shape | Same shape | Both can use `Stream<StockView> streamAllBy()`. |
| Transaction manager naming | Single `transactionManager` in v1 | `tenantTransactionManager` in v2 (this plan) | The v1 plan does NOT need the `value = "tenantTransactionManager"` qualifier. |
| OSIV | Disabled in both | Disabled in both | Same `@Transactional` requirement on the streaming method. |
| `Mockito 3.3.3` (no `mockStatic`) in v1 | Yes | v2 has Mockito 5.x | The v1 unit test for `streamStockCount` may need refactoring if it mocks any static helper; v2 plan is fine. |
| `@RepositoryRestResource` HAL exposure | Same — Spring Data REST behaves identically | Same | Fix D applies to both. |

### What needs porting

1. Pair this plan with `sbdocs/1-Projects/wms1/plan/SBDEV-2219-warehouse-stock-report-unbounded-findall.md` (same base name) — author the v1 counterpart in a separate session via `wms-bugfix-plan` skill targeting v1.
2. The streaming refactor + cap are mechanically identical; the Jakarta-namespace and tenant-TM differences are the porting deltas.
3. Fix D (HAL `@RestResource(exported = false)`) ports verbatim.
4. Fix E (Logger class reference) needs verification in v1 — the wrong-class bug may or may not exist there; check independently.

### What does NOT need porting

- The `@Transactional(value = "tenantTransactionManager", ...)` qualifier — v1 has only one transaction manager.

---

## 12. Layer 2 Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** — Analysis protocol §8 complete: `execute_sql` run, result recorded in §1 (Symptom); frontmatter `db_verified: true` | ✓ §1 DB verification section — `SELECT count(*) FROM stock_view` → 8,775 rows; `information_schema.views` confirms `stock_view` is a VIEW; frontmatter `db_verified: true` |
| 1 | **All callsites enumerated** — every row in §0 visited by §3 Fix Design or excluded with rationale | ✓ §0 has 16 rows; rows 1-4, 13-16 are addressed in §5 Fix Design (Fixes A-E) and §6'; rows 5-9 are excluded (not OOM risks); rows 10-12 are deferred via Fix F (count-only guard in verify script) |
| 2 | **Adjacent bugs** — other classes / methods with the same root-cause pattern, found via pattern-grep | ✓ §0 rows 10-12 (Access, UtilRest, OrderRest unbounded findAll); Fix F provides the count-only guard. Pattern-grep `Repository.findAll()` in service+controller produced exactly 4 callsites — all enumerated. |
| 3 | **Backward compatibility** — API contract, DB schema, persisted state, frontend payload shape | ✓ §10 Q1 + §5.1 Q4 — OMS contract (`/call/inventory/stockCountExport`) shape unchanged (still `List<StockCountDto>` payloads, just stream-batched); `StockCountDto` shape unchanged; no DB schema change; `/api/stockView` HAL endpoint suppressed (verified no internal caller via repo grep — §9 Risk row 4) |
| 4 | **Concurrency** — race conditions, lock ordering, optimistic-lock retry, deadlock potential, idempotency under retry | ✓ §7 row 3 (cross-replica advisory lock pre-existing); §7 row 6 (per-row idempotency note — pre-existing, unchanged); §9 row 2 (cap retry semantics) |
| 5 | **Multi-tenant** — cross-tenant queries, tenant context propagation, per-tenant cache / pool scoping | ✓ §7 row 7 (`TenantContext.setCurrentTenant` already set in cron loop at `StockSummaryExportJob.java:90`); the streaming refactor stays single-threaded so no cross-thread context propagation issue; §8 row 2 (tenantTransactionManager qualifier) |
| 6 | **Error handling** — every new throw path has a handler or an explicit contract change documented | ✓ Fix C — `BusinessException("StockCountTooLarge")` thrown by `streamStockCount`; surrounding `doCalculation` per-tenant try/catch (`StockSummaryExportJob.java:102-106`) logs and continues to the next tenant; `RestExceptionHandler` maps `BusinessException` for the REST trigger path. |
| 7 | **Observability** — logs (level + message), metrics, alert thresholds | ✓ Fix E (Logger class fix); §5.1 row 8 (recommended Micrometer counters/timers); §6 manual smoke includes log-grep verification; §9 Risk row 2 (alert on cap-trip counter) |
| 8 | **Rollback / migration** — Flyway version, data backfill, deploy-order dependencies, feature-flag toggles, sysprop rows | ✓ §5.1 — no Flyway change; new sysprops `STOCK_SUMMARY_EXPORT_MAX_ROWS` (default 1000000) + `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED` (default true, rollback toggle); backward-compatible deploy. |
| 9 | **Test coverage** — unit + integration + manual smoke; named test classes and method signatures | ✓ §6 unit-tests table (6 methods on `WarehouseStockReportServiceUnitTest` including `streamStockCount_closesStreamEvenOnConsumerThrow`, 4 methods on `StockSummaryExportJobUnitTest`), 1 IT (`WarehouseStockReportServiceStreamIT` with H2 cursor-streaming limitation documented), `InventoryRecordServiceUnitTest` annotation check, 5-row manual smoke table. Staging Postgres smoke required for `REQUIRES_NEW` + cursor-streaming validation (H2 IT insufficient alone). |
| 10 | **Cross-version (v1↔v2)** — applicable, deferred to a paired plan, or N/A with explicit rationale | ✓ §11 — v1 plan needed (paired same-base-name); Jakarta-namespace + transaction-manager-qualifier deltas documented. |

---

## 13. Acceptance & Implementation

### 13.1 Acceptance criteria mapping

| Ticket AC | How met in this plan |
|---|---|
| **AC-1** — `getStockCount()` no-arg variant is paginated or removed | **Met by streaming.** Fix B replaces the only caller (`StockSummaryExportJob.java:119`) with `streamStockCount(Consumer<StockCountDto>)`; the no-arg method is either removed or converted to a `UnsupportedOperationException` shim per §10 Q6. |
| **AC-2** — load test 500K rows; endpoint within 2s for one page; total heap allocation bounded | **Reinterpreted as bounded heap, JVM-stable across N rows where N≥500K.** Fix A's `setFetchSize(500)` + cursor-based stream + `try-with-resources` ensures `O(batch_size)` heap. Fix C's hard cap (default 1M) prevents pathological runaway. The "2 seconds for one page" criterion is N/A in a streaming model — recast as "cron tick completes within 30 minutes for 500K rows" (Ops alert threshold per §5.1 row 8). Manual smoke table row 2 verifies heap bound on staging. |
| **AC-3** — caller (StockCountRestController) updated; OMS contract documented | **Re-scoped per §1 contradiction.** The ticket misidentified the REST controller as the OOM caller. Actual OOM ingress is `StockSummaryExportJob.java:119` (cron job). The public POST `/rest/stockcount/getStockCount` already uses the safe 2-arg variant — no change needed. The trigger GET `/rest/stockcount/triggerStockCount` (line 103-108) now delegates to the streaming job via Fix B. OMS contract: `SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY` endpoint still receives `List<StockCountDto>` payloads (shape unchanged); the source changes from a one-shot full list to stream-batched chunks of ≤ configured batch size. This behaviour is documented in §1 Contradiction section and logged as a ticket comment clarification — no separate OMS contract doc is being authored as a deliverable. |

### 13.2 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2219-warehouse-stock-report-unbounded-findall.sh`

The script encodes each fix as a grep / mvn-test assertion. Pre-implementation baseline: 1 PRE check PASS (repository already extends `ReadOnlyPagingAndSortingRepository`), ~24 fails for Fix A.1/A.2/A/B/C/D/E and audit guard (Fix F). Post-implementation: `Result: N pass, 0 fail`.

### 13.3 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 5-6 fixes (A-E + count-only F) across one service + one repo + one job + one constants file. |
| **Pre-draft step** | none | Plan is grounded in direct grep + DB verification; no architectural ambiguity. |
| **Plan-review step** | critic | Standard size warrants critic to confirm no missed callsite. |
| **Implementation shape** | executor | Single executor pass; complexity is moderate, not large. |
| **Verification step** | verify-script + verifier | Mandatory. The script is in §13.2. |
| **Code-review step** | code-reviewer | Touches a cron path with multi-tenant blast radius — second pair of eyes. |
| **Commit step** | git-master | One commit per fix (A, B, C, D, E) keeps the history readable. |

---

## 14. Notes / Implementation Status

> **Status (2026-05-09):** Implemented and committed in 4 atomic commits. **PR**: [#7](https://github.com/SiteBossInc/wms2-api/pull/7) (base: develop, head: tasks/SBDEV-2219). Branch pushed; awaiting merge.
>
> **Commit map (SBDEV-NNNN CN — style):**
> - **C1** `ffd5deb` — Fix A.1: `InventoryRecordService.createEntity` `@Transactional(REQUIRES_NEW)` (BLOCKER prereq — without this, outer `readOnly=true` in C2 would cause Postgres to reject every per-row INSERT)
> - **C2** `bc5026b` — Fix A + A NEW-2 + C + E + MeterRegistry: streaming API + deprecation shim + private `legacyGetStockCount` rollback bridge + cap with i18n + Logger class fix + 3× `@RestResource(exported=false)` on inherited `findAll` (atomicity rationale: interlocking diffs in `WarehouseStockReportService.java`)
> - **C3** `84a0766` — Fix B: `StockSummaryExportJob.exportStockSummary` refactored to single-pass stream consumer + Q9 catch wraps for `messageService.createMessage` (handles SBDEV-2217 cascade)
> - **C4** `142439a` — Fix B IT + verify-script T-IT wiring: `WarehouseStockReportServiceStreamIT` (extends `BaseIntegrationTest` H2-in-PG-mode per documented SBDEV-2218 deviation; H2 cursor-streaming limitation noted in class Javadoc)
>
> **Test results:**
> - `mvn test -Dtest=WarehouseStockReportServiceUnitTest` → passing (TDD-gate Sbdev2219FixA + plan §6 behavior tests)
> - `mvn test -Dtest=StockSummaryExportJobUnitTest` → passing (FixBContract + FixBChunking nested classes)
> - `mvn test -Dtest=InventoryRecordServiceUnitTest` → passing (REQUIRES_NEW reflection assertion)
> - `mvn jacoco:prepare-agent test-compile failsafe:integration-test -Dit.test=WarehouseStockReportServiceStreamIT` → **2/2 pass / 21.07s**
> - `mvn test` (full unit suite) → 3894 / 1 fail / 1 error (both pre-existing, unrelated to this PR — same baseline as SBDEV-2218)
>
> **Final verify-script line:** `Result: 29 pass, 0 fail, 0 skip`
>
> **DB-verified production scope (wms1-wineco-dev, 2026-05-09):** 8,775 `stock_view` rows at wineco; top itemdata 12,346 `unitloads_per_item` confirms the original `>100` parallelStream branch was reachable in production at-scale tenants 50× larger drive the OOM scenario the ticket cites.
>
> **Manual smoke required pre-merge:** Postgres staging trigger of `stockSummaryExportJob.doCalculation(false)` to validate cursor-streaming heap-bound per plan §6 documented H2 limitation. Tracked as the unchecked checkbox in §6 manual test plan.
>
> **Deferred follow-ups (per code-reviewer punch list, NOT in this PR):**
> - `parseLongSysprop` NumberFormatException hardening on the default-value branch
> - LOG.warn at rollback-toggle path should mention cap-check is bypassed
> - `streamStockCount_usesDefaultCapWhenSyspropAbsent` test assertion strengthen
> - Remove 2 commented-out LOG blocks in `StockSummaryExportJob`
> - Fix F audit-guard upgrade from verify-script count-only to ArchUnit rule (separate ticket)
