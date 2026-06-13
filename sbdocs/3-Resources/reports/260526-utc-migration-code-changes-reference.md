---
title: UTC Timezone Migration — Code Changes Reference
plan: "[[260523-UTC-TIMEZONE-MIGRATION]]"
created: 2026-05-26
last_verified: 2026-05-26
status: reference
tags: [wms2, timezone, utc, migration, reference]
---

# UTC Timezone Migration — Code Changes Reference

> **Source plan:** `sbdocs/1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md` (Round 12 — Architect + Critic review applied 2026-05-26)
> **Purpose:** Concise implementation reference for all code changes across the four deployment phases.

---

## Who This Plan Applies To

| Client type | Does this plan apply? | Why |
|---|---|---|
| **Existing v1 clients migrating to wms2** | ✅ Yes — primary purpose | v1 data has warehouse-local wall-clock timestamps; must be converted to UTC + `timestamptz` before wms2 can serve them correctly |
| **Clients already on wms2** | ✅ Yes — existing tenant DBs need the same UTC conversion | All wms2 data written with `hibernate.jdbc.time_zone=America/Los_Angeles` (global config) |
| **New clients onboarding directly to wms2** | ❌ No migration needed | Fresh DB + shared `application.properties` → writes UTC from row one |

---

## Critical Concept: Two Independent Timezone Layers

Before reading the change list, understand the two-layer model. Confusing them is the root cause of most migration complexity.

### Layer 1 — Hibernate Write-Path TZ (Global — ALL tenants = `America/Los_Angeles`)

`spring.jpa.properties.hibernate.jdbc.time_zone=America/Los_Angeles` is a **single server-wide setting**.
It applies to **every tenant's DB writes regardless of where the warehouse is physically located.**

- A NY-warehouse user acts at 3 PM NY time → stored as `15:00 LA wall-clock` in the DB
- Therefore the DB migration SQL uses `AT TIME ZONE 'America/Los_Angeles'` for **all tenants' data** — including NY warehouses — because Hibernate always wrote LA wall-clock globally

### Layer 2 — Business-Date TZ (Per-Tenant — from `los_sysprop`)

The `System Time Zone` row in `los_sysprop` controls what **"today" means** for each individual warehouse (order release, picking-date comparisons, `CURRENT_DATE` in views).

| Warehouse | `System Time Zone` sysprop | UTC-rollover window |
|-----------|---------------------------|---------------------|
| LA warehouse | `America/Los_Angeles` | 8 h (UTC midnight = 4 PM LA) |
| NY warehouse | `America/New_York` | 5 h (UTC midnight = 7 PM NY) |

**Why Deploy 1 pins LA globally:** Deploy 1 is a stabilization step — it makes the server's *existing implicit* behavior explicit in code without changing anything. The server already runs in LA (via `application.properties`). Pinning LA in `main()` and all 6 `CronTrigger`s hardens that fact against host-OS clock differences. It is NOT saying "all warehouses are LA warehouses." Business-date logic (`OrderReleaseJob`, etc.) already reads the per-tenant sysprop and is explicitly exempted from the LA hardcode.

---

## v1 Client Database Onboarding Pre-flight (§0.6)

**Run this before §0.5 for any database being migrated from v1.** Not needed for existing wms2 tenant databases.

### Key schema fact

v1 and v2 share the **same 50 base tables** (byte-identical schema). Only 2 tables are wms2-additive:

| Table | Added in | Notes |
|---|---|---|
| `rest_idempotency` | V2.1.10 | `LocalDateTime` but populated by native `INSERT...NOW()` |
| `outbox_message` | V2.1.11 | Uses `Instant` (UTC wall-clock) — Group B in V1.2.03 |
| `customerorder_cancellation_log` | V2.1.12 (SBDEV-1921) | Uses `OffsetDateTime`; all timestamp columns already **`TIMESTAMPTZ`** — no V1.2.x conversion needed |

v1 Flyway watermark: **V1.1.09**. wms2 watermark: **V2.1.13** (the v2-specific sequence is contiguous V2.1.01–V2.1.13, all in the main migration folder; SBDEV-1921's cancellation feature ships as V2.1.12 + V2.1.13). The full **V2.1.01–V2.1.13** sequence is applied on a v1 DB before the UTC scripts — a single linear apply, in order (see §0.6 Step 3).

> **⚠️ Round 14 update (2026-05-30):** Earlier revisions required a v1-compat variant and a lettered Steps A–F runbook because the old V2.1.08 PK-collided on v1. That is **obsolete** — the v2 sysprop scripts were re-id'd to align with the v1 baseline (V2.1.08 → 140/141/142, V2.1.09 → 143, V2.1.02 → free 144/145), so the standard scripts no-op cleanly on v1. The `v1-onboarding/` subdirectory and its two scripts were **deleted**. Step 3 below is now a single linear loop.

### Step 1 — Determine this client's `AT TIME ZONE` clause

Check the v1 instance's `application.properties`:

```bash
grep "hibernate.jdbc.time_zone" v1/wms-api/src/main/resources/application.properties
```

| v1 `hibernate.jdbc.time_zone` | Client | Data stored as | Use in V1.2.01/V1.2.02 |
|---|---|---|---|
| `America/Los_Angeles` | West coast | LA wall-clock | `AT TIME ZONE 'America/Los_Angeles'` (original scripts, no change) |
| `America/New_York` | East coast | NY wall-clock | `AT TIME ZONE 'America/New_York'` (parameterized copies — see Step 4) |

⚠️ Running `AT TIME ZONE 'America/Los_Angeles'` on NY wall-clock data shifts every timestamp **3 hours forward** — silently wrong.

### Step 2 — Verify `System Time Zone` sysprop

```sql
SELECT sysvalue FROM los_sysprop WHERE syskey = 'System Time Zone';
-- If missing: UPDATE los_sysprop SET sysvalue = '<IANA_TZ>' WHERE syskey = 'System Time Zone';
```

### Step 3 — Run the V2.1.01–V2.1.13 sequence on the v1 DB *(single linear apply — Round 14)*

Apply the standard V2.1.x scripts **in order, in a single loop** — no v1-compat branching, no separate onboarding step. Per-client pre-flight: (1) fix stuck transfer orders, (2) substitute the OMS host in V2.1.02 and V2.1.13. V2.1.08/V2.1.09 are re-id'd to match the v1 baseline (140-143), so they no-op via composite `ON CONFLICT`.

```bash
# Pre-flight 1: Fix stuck transfer orders (idempotent)
PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <client_db> \
  -c "UPDATE customerorder SET state=505, modified=now() WHERE state=510 AND transferlane_id IS NULL;"

# Pre-flight 2: Substitute the OMS host placeholder in V2.1.02 and V2.1.13 for THIS client
#   sed -i "s/oms-XXXXX\.siteboss\.net/oms-<client>.siteboss.net/g" \
#     v2/wms2-api/src/main/resources/db/migration/V2.1.02__*.sql \
#     v2/wms2-api/src/main/resources/db/migration/V2.1.13__*.sql

# Apply the contiguous V2.1.01–V2.1.13 sequence in order
for script in V2.1.01__add_unique_constraint_unitload_labelid.sql \
              V2.1.02__add_palletized_loaded_to_truck_sysprops.sql \
              V2.1.03__update_dashboard_summary_view.sql \
              V2.1.04__replenishorder_performance_indexes.sql \
              V2.1.05__add_critical_missing_indexes.sql \
              V2.1.06__add_composite_indexes.sql \
              V2.1.07__update_transaction_detail_pick_amount_filter.sql \
              V2.1.08__stale_club_batch_cleanup_sysprops.sql \
              V2.1.09__add_pick_path_direction_sysprop.sql \
              V2.1.10__add_rest_idempotency.sql \
              V2.1.11__add_outbox_message.sql \
              V2.1.12__add_cancellation_reversal_log_and_grant.sql \
              V2.1.13__add_reversal_completed_sysprop.sql; do
  echo "Applying $script..."
  [ -f "v2/wms2-api/src/main/resources/db/migration/$script" ] \
    || { echo "ABORT: $script not found on disk"; exit 1; }
  PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <client_db> \
    -f v2/wms2-api/src/main/resources/db/migration/$script \
    || { echo "ABORT: $script failed"; exit 1; }
done
```

> **V2.1.13 caveat:** it seeds `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` by copying the `WEBSERVICE_ORDER_BATCH_CANCELLED` sibling row — silently a no-op if that row is absent. Verify it exists per client before relying on the cancellation-reversal callback.

### Step 2.5 — Flyway schema history divergence warning *(NEW — Review fix CRITICAL-3 Architect)*

v1 Flyway migrations **V1.1.06–V1.1.09 have completely different SQL content** from the scripts wms2 used to ship under those same version numbers. This collision is now resolved: wms2 renamed its top-level scripts to the **V2.1.x** namespace (V2.1.01–V2.1.13), so there is no longer any version overlap with v1's V1.1.06–V1.1.09 and per-tenant Flyway checksums can no longer collide. After the v1 DB is committed to wms2, run:

```sql
SELECT version, description, checksum FROM flyway_schema_history ORDER BY installed_rank;
```

**Recommended:** `TRUNCATE flyway_schema_history` after Steps 3–6 complete so wms2's Flyway can re-baseline cleanly. Note: wms2-api never invokes Flyway at runtime — this is a forward-compatibility risk only.

### Step 2.6 — Check `customerorder_old` row count *(NEW — Review fix MEDIUM-2)*

```sql
SELECT COUNT(*) FROM customerorder_old;
```

If > 0: confirm with client whether data is archived. Take a targeted `pg_dump --table=customerorder_old` backup if needed. V1.2.01 intentionally does not touch this table (zero wms2-api references).

### Step 3.5 — Confirm `customerorder_old` exclusion *(NEW — Review fix CRITICAL-3 Critic)*

Before running V1.2.01, confirm the table is archive-only and document the decision:

```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'customerorder_old';
-- timestamp without time zone columns here are ACCEPTED residual risk — intentionally not migrated
```

If any application code still accesses this table, **escalate before proceeding**.

### Step 4 — Create parameterized migration scripts for NY clients

> `[2026-06-03]` NY copies of `V1.2.01/02/99` are **already pre-generated** in `db/onboarding-tz-variants/`; the `sed` below is only needed to regenerate after the LA originals change. Only `V1.2.01/02/99` carry an `AT TIME ZONE 'America/Los_Angeles'` literal — `V1.2.03` (UTC), `V1.2.04` (views) and `V1.2.05` (functions) are timezone-agnostic and used as-is for every client.

```bash
# NY clients only — west coast clients use the originals as-is
CLIENT_HIBERNATE_TZ="America/New_York"
sed "s/AT TIME ZONE 'America\/Los_Angeles'/AT TIME ZONE '${CLIENT_HIBERNATE_TZ}'/g" \
  db/migration/V1.2.01__utc_standard_tables.sql > V1.2.01__utc_standard_tables_NY.sql
sed "s/AT TIME ZONE 'America\/Los_Angeles'/AT TIME ZONE '${CLIENT_HIBERNATE_TZ}'/g" \
  db/migration/V1.2.02__utc_large_tables.sql > V1.2.02__utc_large_tables_NY.sql
# V1.2.03 / V1.2.04 (views) / V1.2.05 (functions) are used as-is for all clients

# Rollback NY copy — note the source is db/rollback/, NOT db/migration/ (Review fix — Ambiguity):
sed "s/AT TIME ZONE 'America\/Los_Angeles'/AT TIME ZONE '${CLIENT_HIBERNATE_TZ}'/g" \
  db/rollback/V1.2.99__rollback_utc_migration.sql > V1.2.99__rollback_utc_migration_NY.sql
```

### Step 5 — Landlord DB setup

```sql
-- On landlord DB: tenant_db_configuration.tenant is a @ManyToOne FK (Review fix — MEDIUM-5):
SELECT tdc.* FROM tenant_db_configuration tdc
JOIN tenant t ON t.id = tdc.tenant_id
WHERE t.tenant_name = '<tenant_name>' AND tdc.warehouse = '<facility_code>';

-- Set timezone for frontend (GET /api/public/authConfig returns this field):
UPDATE tenant_discovery SET timezone = '<IANA_TZ>'
WHERE key = '<warehouse>-<clientName>';
-- e.g. 'America/Los_Angeles' or 'America/New_York'
```

### Step 6 — Proceed with §0.5 runbook

Use the parameterized scripts (NY) or originals (LA) for V1.2.01/V1.2.02. Run in order: 01 → 02 → 03 → **04 (recreate views)** → **05 (functions)**. V1.2.03/V1.2.04/V1.2.05 are identical for all clients.

---

### §5.7 — Ongoing v1 Client Onboarding Checklist

For each future v1 client being migrated to wms2 (after this UTC migration is complete):

1. §0.6 Step 1 — determine v1 Hibernate TZ (LA or NY)
2. §0.6 Step 3 — run the single linear V2.1.01–V2.1.13 apply on the v1 client DB (pre-flight: stuck-order fix + OMS host substitution in V2.1.02/V2.1.13)
3. §0.6 Step 4 — create parameterized V1.2.01/V1.2.02 for NY clients
4. §0.6 Step 5 — set landlord DB `tenant_discovery.timezone`
5. §0.6 Step 2 — verify `los_sysprop` `System Time Zone`
6. §0.5 runbook — run V1.2.01–V1.2.05 (01 standard → 02 large → 03 outbox → 04 views → 05 functions) with maintenance window
7. Smoke test: order release, picking dates, `CURRENT_DATE` views return correct warehouse-local dates

> After Deploy 2, wms2 columns are `timestamptz`. The V1.2.01–V1.2.05 scripts convert incoming v1 data to UTC and it lands directly into `timestamptz` — no extra step needed.

---

## Deploy 1 — Phase 1: Stabilize (behavior-preserving) — ✅ IMPLEMENTED `[2026-06-03]`

**Goal:** Make all implicit LA-timezone assumptions explicit BEFORE changing anything. Safe to deploy at any time; no behavior change.

> ✅ **Implemented + verified — committed `2011651` on `feature/utc-timezone`** (not yet merged/deployed). `mvn clean compile` exit 0; `OmsNotificationConfigContextLoadTest` Tests run:1, Failures:0; code-reviewer APPROVE.

| File | Change | Status |
|------|--------|--------|
| `StartApplication.java` | `main()` calls `TimeZone.setDefault(getTimeZone("America/Los_Angeles"))` + `System.setProperty("user.timezone", …)` before `SpringApplication.run()`. **Not `@PostConstruct`** — DataSources initialize before that fires. | ✅ done |
| `schedulejob/SchedulingConfiguration.java` | New `CRON_SCHEDULE_ZONE` constant (`= America/Los_Angeles`) passed to all **6** `CronTrigger` constructors. Controls *when the job fires*, not per-tenant business-date logic. | ✅ done |
| `WebConfigurer.java` | `builder.timeZone(TimeZone.getDefault())` → `getTimeZone("America/Los_Angeles")` | ✅ done |
| `schedulejob/OrderReleaseJob.java` | **No change** — already reads `System Time Zone` sysprop and sets it on the `SimpleDateFormat`. Do NOT hardcode LA. Phase 5 refactors to `TimezoneService`. *(Review fix — HIGH-3)* | ✅ n/a |
| `TransactionReportRestController.java` | Both report methods pin `SimpleDateFormat` to LA (single reused instance; inline `new SimpleDateFormat(...).format()` removed) | ✅ done |

---

## Deploy 2 — Phases 2 + 3: The Big Switch (maintenance window)

Phase 2 (app config) and Phase 3 (DB migration) go out in the same deployment. Flyway migration scripts are run manually via `psql` per tenant before the new app image starts.

---

### Phase 2.1 — `application.properties`

```diff
-#user.timezone=America/New_York
-spring.jackson.time-zone=America/Los_Angeles
-spring.jpa.properties.hibernate.jdbc.time_zone=America/Los_Angeles
+spring.jackson.time-zone=UTC
+spring.jpa.properties.hibernate.jdbc.time_zone=UTC
+spring.jpa.properties.hibernate.type.preferred_instant_jdbc_type=TIMESTAMP_WITH_TIMEZONE
 spring.jackson.deserialization.adjust-dates-to-context-time-zone=true  ← keep as-is
```

---

### Phase 2.2–2.3 — JVM & Jackson Config

| File | Change |
|------|--------|
| `StartApplication.java` | Change `main()` TZ from `America/Los_Angeles` → `UTC`; also fix `repositoryPopulator()` method — its bare `new ObjectMapper()` lacks `JavaTimeModule` |
| `WebConfigurer.java` | `builder.timeZone(TZ("UTC"))`; change date format from `"yyyy-MM-dd HH:mm:ss"` to ISO-8601 `"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"` |

---

### Three Timezone-Reading Mechanisms (How They Relate)

After the UTC migration, three independent mechanisms all read the same `los_sysprop` `System Time Zone` row but serve completely different purposes:

| Mechanism | Runs at | Purpose | File |
|---|---|---|---|
| `resolveWarehouseTz()` | **Pool creation** — bare `DriverManager` (no Hikari pool yet) | Sets `connectionInitSql = "SET timezone = '<IANA_TZ>'"` so SQL `CURRENT_DATE` in views/queries uses warehouse TZ | `TenantDynamicRoutingDataSource.java` |
| `TimezoneService` | **Runtime** — via `SyspropService` (requires existing pool) | Provides `ZoneId` / `todayInWarehouse()` for Java business logic (`LocalDate.now(zoneId)`) | New `TimezoneService.java` |
| Frontend `warehouseTimezone` | **Browser startup** — `GET /api/public/authConfig` response | Converts UTC API responses to warehouse-local time for display | `plugins/initTenantAuth.client.js` + Vuex |

> **Must NOT mix:** `TimezoneService` cannot be called during pool creation — `SyspropService` requires an existing pool, causing a circular dependency. `resolveWarehouseTz()` uses bare `DriverManager` specifically to avoid this. `resolveWarehouseTz()` must never call Spring beans.

---

### Phase 2.4 — New `TimezoneService.java`

New `@Component` class. Key design points:

- **Cache keyed by composite `tenantName+facilityCode`** (not facilityCode alone — different tenants can share the same facilityCode)
- Reads `System Time Zone` from `los_sysprop` via `SyspropService.getSysvalue(...)` — per-tenant, not global
- `parseToZoneId()` normalises quirky formats like `"America / Los_Angeles"` or `"America / New_York (-05:00)"` to valid `ZoneId`, falls back to UTC + `LOG.warn` on invalid input
- No-arg `getWarehouseZoneId()` requires `TenantContext` to be set (request-scoped callers, scheduled job per-tenant loops)
- `getWarehouseZoneId(facilityCode)` overload for callers that need a specific facility (rare)
- `invalidateCache(tenantKey)` / `invalidateCacheAll()` for admin eviction

```java
@Component
public class TimezoneService {
    private static final Logger LOG = LoggerFactory.getLogger(TimezoneService.class);
    private final SyspropService syspropService;
    private final ConcurrentHashMap<String, ZoneId> cache = new ConcurrentHashMap<>();

    public ZoneId getWarehouseZoneId() { /* reads TenantContext, calls getByTenantKey */ }
    public ZoneId getWarehouseZoneId(String facilityCode) { /* explicit facilityCode */ }
    public LocalDate todayInWarehouse() { return LocalDate.now(getWarehouseZoneId()); }
    public LocalDate todayInWarehouse(String facilityCode) { ... }
    public void invalidateCache(String tenantKey) { cache.remove(tenantKey); }
    public void invalidateCacheAll() { cache.clear(); }
    private ZoneId parseToZoneId(String syspropValue) { /* normalise + ZoneId.of() + fallback */ }
}
```

---

### Phase 2.5 — Business Logic: "Today in Warehouse Timezone"

All callers of `LocalDate.now()` that represent a business date must switch to `timezoneService.todayInWarehouse()`.

| File | Line | Change | Note |
|------|------|--------|------|
| `service/job/ReleaseOrderJobService.java` | 121 | `LocalDate.now()` → `timezoneService.todayInWarehouse()` | Fixes 8h early-release for LA, 5h for NY (Scenario A) |
| `service/CustomerorderService.java` | 248 | `LocalDate today = LocalDate.now()` → `timezoneService.todayInWarehouse()` | Fixes stuck-FUTURE_PICKING_DATE state during UTC-rollover window (Scenario A) |
| `service/BillofladingService.java` | 655 | `billOfLading.setShipped(LocalDate.now())` → `timezoneService.todayInWarehouse()` | Fixes BOL shipped-date off-by-one during UTC-rollover (Scenario C) |
| `service/GoodsreceiptService.java` (or caller) | TBD | Any `setReceiptdate(LocalDateTime.now())` call → `LocalDateTime.now(timezoneService.getWarehouseZoneId())` | Audit required *(Review fix — HIGH-7)*: `goodsreceipt.receiptdate` is a business-specific `LocalDateTime` column; find all call sites: `grep -rn "setReceiptdate" v2/wms2-api/src/main/java/ --include="*.java"` |
| `model/Billoflading.java` | 21 | Remove `= LocalDate.now()` field default | Only `new Billoflading()` site is `BillofladingService.java:221`; explicit `setShipped(LocalDate.now())` at line 655 follows immediately. **However, line 239 calls `setShipped(null)` — verify `billoflading.shipped` column allows NULL before removing the default** *(Review fix — CRITICAL-2 Critic)* |
| `service/OrderBatchCreationService.java` | 158, 166 | `LocalDate.now()` → `timezoneService.todayInWarehouse()` | No-arg — request-scoped, TenantContext is set |
| `schedulejob/ReplenishOrderJob.java` | 371, 405 | **No change required** | `new Date()` (UTC instant) vs `date` column via native query; PostgreSQL session-TZ midnight cast handles this correctly — Scenario D |

**Use the no-arg overload everywhere except `StockSummaryExportJob`** — all service methods called from within per-tenant job loops already have `TenantContext` set (confirmed: `OrderReleaseJob.java:94`, `ReplenishOrderJob.java:127` both call `TenantContext.setCurrentTenant(tenantProfile)` before entering business logic).

#### UTC-Rollover Window Impact Analysis

| Scenario | What breaks without fix | Fix |
|----------|------------------------|-----|
| **A** — UTC− warehouses (current tenants) | Orders with `pickingdate = D+1` released 8h early (LA) or 5h early (NY) when UTC crosses midnight before the warehouse does | `timezoneService.todayInWarehouse()` at `ReleaseOrderJobService.java:121` |
| **B** — UTC+ warehouses (future tenants) | Orders with `pickingdate = today` not released until UTC catches up (up to 12h late) | Same fix |
| **C** — BOL `shipped` date | `BillofladingService.java:655` stamps tomorrow's date when BOL is closed at 4 PM LA (= UTC midnight) | `timezoneService.todayInWarehouse()` at line 655 |
| **D** — ReplenishOrderJob filter | `new Date()` vs `date` column: session-TZ midnight cast shields against UTC-rollover | **No change** |

---

### Phase 2.6 — Per-Tenant Session Timezone on DB Connections

**File:** `landlord/config/TenantDynamicRoutingDataSource.java`

Add `resolveWarehouseTz(TenantDbConfiguration tc)` private method:
- Opens a one-shot `DriverManager` connection to the tenant DB (before the Hikari pool exists)
- Queries: `SELECT sysvalue FROM los_sysprop WHERE syskey = 'System Time Zone' AND workstation = 'DEFAULT' ORDER BY client_id LIMIT 1`
  *(Review fix — CRITICAL-1: corrected column names from `key`/`value` → `syskey`/`sysvalue`, added `workstation='DEFAULT'` filter per `SyspropRepository.java:30`; prior wrong names caused a silent `PSQLException` that was swallowed, making `connectionInitSql` a no-op for all tenants)*
- Validates the returned string via `ZoneId.of()` (rejects invalid IANA names)
- Returns the IANA string, or `null` (logs **ERROR** — not WARN) if absent or invalid
- **Never call `SyspropService` from this method** — it requires an existing pool, creating a circular dependency *(Review fix — CRITICAL-2 Architect: pool-init path must use bare DriverManager only)*

In `createHikariPool()`, before `return new HikariDataSource(cfg)`:
```java
String warehouseTz = resolveWarehouseTz(tc);
if (warehouseTz != null) {
    cfg.setConnectionInitSql("SET timezone = '" + warehouseTz + "'");
}
```

**Effect:** `CURRENT_DATE` and `CURRENT_TIMESTAMP` in all native queries and views automatically use the correct warehouse timezone. Transparent to:
- `order_monitor_view` (6+ uses of `CURRENT_DATE`)
- `replenishment_monitor_view`
- `MessageRepository` message cleanup

> ⚠️ **PgBouncer warning:** `connectionInitSql` works correctly only in **session-pool mode**. If PgBouncer uses transaction-pool mode, session GUCs are reset per transaction — verify before deploying.

---

### Phase 2.7 — Fix 46 `new ObjectMapper()` Instances

All bare `new ObjectMapper()` instances bypass Spring's UTC timezone config and lack `JavaTimeModule` — `LocalDateTime`/`LocalDate` fields will serialize as numeric arrays.

Fix: inject the Spring-managed `ObjectMapper` bean, or add `JavaTimeModule` + UTC timezone to the bare instance.

| File | Instances | Priority |
|------|-----------|----------|
| `OrderRestController.java` | 10 | HIGH |
| `ManageOrderService.java` | 7 | HIGH |
| `AdviceRestController.java` | 6 | HIGH |
| `SkuRestController.java` | 4 | HIGH |
| `TransactionReportRestController.java` | 4 | HIGH |
| `BillofladingService.java` (static `MAPPER`) | 1 | HIGH |
| `OrderBatchCreationService.java` (static `OBJECT_MAPPER`) | 1 | HIGH |
| `AdviceService.java` (static `MAPPER`) | 1 | HIGH |
| `CustomerorderService.java` (static `MAPPER`) | 1 | MEDIUM |
| `CustomerorderBatchService.java` (static `MAPPER`) | 1 | MEDIUM |
| `StockSummaryExportJob.java` | 1 | MEDIUM |
| `StockChangeNotificationService.java` | 1 | MEDIUM |
| Various controllers (Dashboard, CycleCount, etc.) | ~8 | LOW |
| `SecurityConfiguration.java` (JWT only) | 1 | SKIP |

---

### Phase 2.10 — DB Stored Function Callers

| File | Line | Change | Note |
|------|------|--------|------|
| `repo/jpa/ClientRepository.java` | 55 | `::timestamp without time zone` → `::timestamptz` | `to_timestamp(..., ...)::timestamptz` interprets in session TZ (warehouse TZ) — correct |
| `repo/jpa/ClientRepository.java` | 65 | Same | |
| `StockrecordRepository.java` | — | No change | `java.util.Date` → JDBC → PostgreSQL maps to `timestamptz` correctly |
| `StockViewRepository.java` | — | No change | Same |

**API contract (must document):**
- `POST /rest/getTransactionSummaryReport` — `startDate`/`endDate` must be **warehouse-local** `"yyyy-MM-dd HH:mm:ss"`, NOT UTC. The session-TZ `::timestamptz` cast interprets these as warehouse-local. Sending UTC strings causes double-conversion.
- `POST /rest/getTransactionDetailedReport` — same rule.
- All other timestamp fields in API responses → UTC ISO-8601.

---

### Phase 3 — 5 New Flyway SQL Files `[updated 2026-06-03 — was 4; authored + validated on PostgreSQL 16]`

Run manually via `psql` per tenant DB (Flyway is not auto-invoked at runtime in wms2-api).

> **🔄 2026-06-03 — the script set changed (view-dependency wall).** PostgreSQL blocks `ALTER COLUMN TYPE` on a column any view references, so the migration is now **5 forward files**: `V1.2.01` additionally **DROPs all 11 reporting views first**; a new **`V1.2.04` RECREATES the 11 views**; the stored functions **moved to `V1.2.05`** and must run AFTER the views (`stock_history` RETURNS `stock_view.%TYPE`). The rollback `V1.2.99` lives in **`db/rollback/`** (NOT `db/migration/` — it outranks V1.2.05 and would auto-undo if Flyway ran). NY copies of `V1.2.01/02/99` are pre-generated in `db/onboarding-tz-variants/`. All validated end-to-end on PostgreSQL 16 (forward chain, NY `08:24 EST → 13:24 UTC` math, forward→rollback round-trip). See `260523-UTC-TIMEZONE-MIGRATION.md` Phases 3/3.3.

#### Pre-flight before running any script
```bash
DELETE FROM rest_idempotency;   -- drain; eliminates timezone ambiguity
# Wait for OutboxDispatcherJob to flush: SELECT COUNT(*) FROM outbox_message
#   WHERE status IN ('PENDING','IN_FLIGHT','FAILED_RETRY') = 0
# Scale all wms2-api instances to 0 before running migrations
```

| File | Tables | Transactional | Key detail |
|------|--------|---------------|------------|
| `V1.2.01__utc_standard_tables.sql` | **DROPs all 11 views first**, then **40 standard** `AbstractBaseEntity` tables (80 `created`/`modified` cols) + `goodsreceipt.receiptdate` = **81 cols** (the 4 large tables are in V1.2.02) | YES | `USING col AT TIME ZONE 'America/Los_Angeles'` — correct for ALL tenants incl. NY (Hibernate wrote LA wall-clock globally). **Idempotency canary** on `advice.created` aborts if already `timestamptz` *(MAJOR-3)*. `SET statement_timeout=0` inside *(LOW-1)*. Post-migration assertion. |
| `V1.2.02__utc_large_tables.sql` | `stockrecord`, `unitload_record`, `inventory_record` (+`timestamp`), `pickingorder_position` (9 cols) | **NO** (per-table `DO` blocks, autocommit each) | `SET lock_timeout=0; SET statement_timeout=0;`. **Per-table guard on `data_type`** → idempotent + resumable; partial progress survives failure |
| `V1.2.03__utc_outbox_and_new_tables.sql` | `outbox_message`, `rest_idempotency` | YES | `outbox_message` uses `Instant` (UTC wall-clock) → `USING col AT TIME ZONE 'UTC'`; `rest_idempotency` drained first. Skips `customerorder_cancellation_log` (already `timestamptz`). |
| `V1.2.04__utc_recreate_views.sql` *(NEW position)* | recreates all **11 reporting views** verbatim (over the now-`timestamptz` columns) | YES | `DROP VIEW … CASCADE` then `CREATE`; **must run BEFORE V1.2.05** — `stock_history` RETURNS `stock_view.%TYPE`. Post-recreate assertion (11 views). |
| `V1.2.05__utc_update_functions.sql` *(moved from 04)* | `stock_history`, `transaction_detail`, `transaction_summary` | YES | DROP old `timestamp`-signature overloads first, then recreate with `timestamptz` params/returns; `stock_history` first. Runs LAST (needs `stock_view`). |

**Date columns NOT converted** (remain `date` type — timezone-agnostic):
`customerorder.pickingdate`, `billoflading.shipped`, `advice.dayofdelivery`, `advice.dayofdeliveryuntil`

**Rollback script:** `db/rollback/V1.2.99__rollback_utc_migration.sql` — manual use only, NOT run by Flyway, kept OUT of `db/migration/`. Single-file complete revert (validated round-trip): PART 0 drop 11 views → PART 1/2 revert standard + large (inverse `AT TIME ZONE`) → PART 3 revert outbox/rest_idempotency (UTC) → PART 4 recreate 11 views → PART 5 restore the 3 functions to `timestamp`-without-tz signatures.

---

## Deploy 3 — Phase 4: Frontend Updates

Applies to both `wms2-web-ui` and `wms2-mobile-ui`.

**Principle:** The backend emits UTC ISO-8601 (`"2026-02-10T22:30:00.000Z"`) for all timestamps. Converting to warehouse-local time for display is **entirely the frontend's responsibility.** No raw UTC is ever shown in the UI.

---

### Phase 4.0 — Bootstrap Timezone from `tenant_discovery`

Both UIs call `GET /api/public/authConfig` at startup via `plugins/initTenantAuth.client.js`. The response includes a `timezone` field from `tenant_discovery.timezone` (e.g. `"America/Los_Angeles"`, `"America/New_York"`).

**`plugins/initTenantAuth.client.js`** (both UIs) — add after existing Keycloak inject:
```javascript
const warehouseTimezone = tenantConfig.timezone || 'UTC'
localStorage.setItem('warehouseTimezone', warehouseTimezone)
store.dispatch('setWarehouseTimezone', warehouseTimezone)
```

**`store/index.js`** (both UIs — root Vuex store) — add:
```javascript
// state:
warehouseTimezone: localStorage.getItem('warehouseTimezone') || 'UTC',

// mutations:
setWarehouseTimezone(state, payload) { state.warehouseTimezone = payload },

// actions:
setWarehouseTimezone(context, timezone) {
  context.commit('setWarehouseTimezone', timezone)
  localStorage.setItem('warehouseTimezone', timezone)
},
```

Placed at root (not a module) because both UIs have a single root `store/index.js`.

---

### Phase 4.2 — Fix Nuxt Moment Config

| File | Change |
|------|--------|
| `wms2-web-ui/nuxt.config.js` | Remove `publicRuntimeConfig.moment` block (dead config; contradicts with `America/New_York`) |
| `wms2-mobile-ui/nuxt.config.js` | Add `moment: { timezone: true }` config block (currently absent — timezone support not activated) |

---

### Phase 4.3 — New `plugins/dateFormatter.js` (both projects, same file)

New plugin providing centralized, warehouse-TZ-aware helpers. Uses `safeParse()` internally to handle both old `"yyyy-MM-dd HH:mm:ss"` (legacy bare LA-local) and new `"2026-02-10T22:30:00.000Z"` (UTC ISO-8601) formats during the transition window.

| Injected helper | Purpose | Use for |
|-----------------|---------|---------|
| `$formatDateTime(value)` | → warehouse-local `MM/DD/YYYY h:mm:ss a` | General datetime display |
| `$formatDate(value)` | → `MM/DD/YYYY` | Date-only display |
| `$formatDateShort(value)` | → `MM/DD/YY` | Compact date |
| `$formatTimeOnly(value)` | → `h:mm:ss a` | Time-only display |
| `$formatDateTimeShort(value)` | → `MM/DD/YY h:mm:ss a` | Compact datetime |
| `$parseDateForApi(value)` | Warehouse-local picker → UTC ISO-8601 string | POST/PUT `timestamptz` fields |
| `$parseTransactionReportDate(value)` | Picker → warehouse-local `"YYYY-MM-DD HH:mm:ss"` | `POST /rest/getTransactionSummaryReport` and `getTransactionDetailedReport` **only** — do NOT use `$parseDateForApi` here. Uses `app.$moment.tz()` (not bare `moment.tz` — throws `ReferenceError` in Nuxt). Throws `TypeError` on non-string input. *(Review fix — HIGH-2, MAJOR-2)* |
| `$formatDateForPicker(value)` | → `YYYY-MM-DD` | `date`-column pickers |

---

### Phase 4.4 — Refactor 70+ Vue Components

Replace all component-local `getDate()`, `getTimeDate()`, `formatDate()` etc. with injected plugin calls.

| Before | After |
|--------|-------|
| `this.$moment(value).format('MM/DD/YYYY h:mm:ss a')` | `this.$formatDateTime(value)` |
| `this.$moment(value).format('MM/DD/YYYY')` | `this.$formatDate(value)` |
| `this.$moment(value).format('MM/DD/YY h:mm:ss a')` | `this.$formatDateTimeShort(value)` |
| `this.$moment(value).format('MM/DD/YY')` | `this.$formatDateShort(value)` |
| `this.$moment(value).format('h:mm:ss a')` | `this.$formatTimeOnly(value)` |

Key components: `stockUnitRecord.vue` (also remove hardcoded `'Time Stamp (EST)'`), `openTransfers.vue`, `closedTransfers.vue`, `parcelDetails.vue`, `inventoryReport.vue`, `receivingReport.vue`, `editRepleishmentRequest.vue`.

---

### Phase 4.5 & 4.7 — Frontend → Backend Timestamp Contract

| Field category | Wire format to send | Helper |
|----------------|---------------------|--------|
| Pure `date` columns (`LocalDate`) | `"YYYY-MM-DD"` — no time, no TZ | None — unchanged |
| `timestamptz` fields in request bodies | UTC ISO-8601 `"2026-02-10T22:30:00.000Z"` | `this.$parseDateForApi(value)` |
| Transaction-report `startDate`/`endDate` | Warehouse-local `"yyyy-MM-dd HH:mm:ss"` — **do NOT convert to UTC** | `this.$parseTransactionReportDate(value)` |

**`transferDetails.vue:164`** — confirm whether the backing column is `date` or `timestamptz`; switch `parseDate()` accordingly.

Pre-deploy audit grep (before Deploy 3):
```bash
grep -rn "getTransactionSummaryReport\|getTransactionDetailedReport" \
  v2/wms2-web-ui/components/ v2/wms2-web-ui/pages/ \
  v2/wms2-mobile-ui/components/ v2/wms2-mobile-ui/pages/ \
  --include="*.vue"
# Every hit must use $parseTransactionReportDate (not $parseDateForApi)
```

---

## Phase 5 — Post-Migration Cleanup (lower priority)

| Item | Change |
|------|--------|
| `OrderReleaseJob.java` | Refactor to use `timezoneService.getWarehouseZoneId()` instead of manual `SimpleDateFormat` + sysprop parsing |
| `TimezoneService.java` | Replace `ConcurrentHashMap` with Caffeine cache (already in wms2-api) with 24h TTL — allows TZ changes to propagate without restart |
| Remaining `new ObjectMapper()` instances | Consolidate any not fixed in Phase 2.7 |
| Startup validator | Add `CommandLineRunner` that iterates all tenants, calls `timezoneService.getWarehouseZoneId()`, and logs WARN for any tenant falling back to UTC |
| Landlord DB | Separate follow-up migration: `TenantDbConfiguration.created/modified` columns also need `USING col AT TIME ZONE 'America/Los_Angeles'` migration |

---

## Deployment Sequence Summary

```
Phase 0 (pre-work, any time before):
  - pg_dump all tenant DBs
  - Rollback rehearsal on staging (V1.2.99 on staged migrated DB)
  - Name decision owner
  - Verify disk free > total DB size
  - Verify PgBouncer pool mode (must be session, not transaction)

Deploy 1 (Phase 1):
  - 5 files — behavior-preserving LA stabilization
  - Full mvn test, smoke test, verify 6 cron jobs fire correctly

Deploy 2 (Phases 2+3) [MAINTENANCE WINDOW]:
  Pre-work (before maintenance window):
    - Measure rollback RTO during rehearsal — MUST fit within 2-hour go/no-go window (Review fix — MAJOR-1)
    - Audit StockrecordRepository HAL endpoints: grep for callers of
      transactionDetailByClientNumberAndSkuBetweenDates — they shift 8h after Deploy 2 (Review fix — MAJOR-4)
    - Verify OMS-side timestamp parsing is compatible with UTC ISO-8601 (Review fix — MAJOR-5)
  1. Enter maintenance mode (quiesce all HTTP writes)
  2. Wait 10s for afterCommit callbacks
  3. Drain OutboxDispatcherJob (SELECT COUNT WHERE status IN PENDING/IN_FLIGHT = 0)
  4. DELETE FROM rest_idempotency
  5. Verify zero IN_FLIGHT rows, then scale all instances to 0
  6. Run V1.2.01–V1.2.05 per tenant via psql (01 standard → 02 large → 03 outbox → 04 recreate views → 05 functions)
  7. Verify schema (all columns = timestamptz, all 11 views recreated, row counts match pre-migration)
  8. Deploy new app image (UTC properties + TimezoneService + per-tenant connectionInitSql)
  9. Smoke test: verify UTC format; run `SHOW timezone;` per tenant connection — must return
     warehouse IANA TZ (e.g. 'America/Los_Angeles'), NOT 'UTC' (Review fix — HIGH-4)
  10. 2-hour go/no-go window

Deploy 3 (Phase 4) [immediately after Deploy 2]:
  - Frontend: centralized dateFormatter, initTenantAuth timezone capture, 70+ components

Flag flip (Phase 2.9):
  - Flip API_TIMESTAMP_FORMAT sysprop LEGACY → ISO8601_UTC
  - Force-logout active sessions

Phase 5 (ongoing, lower priority):
  - TimezoneService Caffeine cache, ObjectMapper cleanup, landlord DB follow-up
```

---

## File Count Summary

| Phase | Backend files | Frontend files | DB/SQL files |
|-------|-------------|----------------|-------------|
| Phase 1 | 5 | 0 | 0 |
| Phase 2 | ~60 (46 ObjectMapper + ~14 others) | 0 | 0 |
| Phase 3 | 1 (`ClientRepository`) | 0 | 5 (V1.2.01–04 + V1.2.99) |
| Phase 4 | 0 | ~75 (70 components + ~5 config/plugin/store) | 0 |

---

## Key Pre-Deploy Audit Commands

```bash
# Phase 3: must return zero results before deploying
grep -rn "::timestamp\b\|timestamp without time zone" v2/wms2-api/src/main/java/ --include="*.java"

# Phase 4: verify transaction report endpoints use $parseTransactionReportDate
grep -rn "getTransactionSummaryReport\|getTransactionDetailedReport" \
  v2/wms2-web-ui/components/ v2/wms2-web-ui/pages/ \
  v2/wms2-mobile-ui/components/ v2/wms2-mobile-ui/pages/ \
  --include="*.vue"

# DB: verify schema after V1.2.02 (all large tables must be timestamptz)
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('stockrecord','unitload_record','inventory_record','pickingorder_position')
  AND column_name IN ('created','modified','timestamp')
ORDER BY table_name, column_name;
-- Every row must show data_type = 'timestamp with time zone'

# DB: verify per-tenant sysprops before deploy
SELECT 'tenant_db_here' AS db, sysvalue
FROM los_sysprop WHERE syskey = 'System Time Zone';

# DB: verify session timezone was set by connectionInitSql (run against each tenant connection post-deploy)
SHOW timezone;
-- Must return IANA TZ (e.g. 'America/Los_Angeles'), NOT 'UTC'
-- If 'UTC' on a non-UTC tenant → resolveWarehouseTz() failed; check ERROR logs (Review fix — LOW-4 / HIGH-4)

# GoodsreceiptService audit (before Phase 2 deploy):
grep -rn "setReceiptdate" v2/wms2-api/src/main/java/ --include="*.java"
# Every hit: change LocalDateTime.now() → LocalDateTime.now(timezoneService.getWarehouseZoneId())
```

---

## Round 12 Fixes Applied (2026-05-26 — Architect + Critic Review)

| Severity | Finding | What changed in this report |
|----------|---------|----------------------------|
| **CRITICAL** | `resolveWarehouseTz()` used wrong column names (`key`/`value`) — `PSQLException` silently swallowed, `connectionInitSql` never fired | Phase 2.6: query updated to `syskey`/`sysvalue` + `workstation='DEFAULT'`; logs upgraded to ERROR |
| **CRITICAL** | Pool-init and runtime timezone paths could be confused | Phase 2.6: explicit note that `DriverManager` path must never call `SyspropService` |
| **CRITICAL** | `BillofladingService:239` calls `setShipped(null)` — missed in construction-site audit | Phase 2.5: `Billoflading.java:21` row updated with nullability check requirement |
| **CRITICAL** | v1 Flyway V1.1.06–V1.1.09 collided with wms2's same version numbers (now resolved: wms2 renamed to V2.1.x namespace, no overlap) | §0.6: Step 2.5 added (Flyway truncation recommendation) |
| **CRITICAL** | `customerorder_old` may have v1 data; V1.2.01 has no guard | §0.6: Steps 2.6 + 3.5 added |
| **HIGH** | `$parseTransactionReportDate` used bare `moment.tz` → ReferenceError in Nuxt | Phase 4.3: description updated to `app.$moment.tz` |
| **HIGH** | Files Summary said "pin OrderReleaseJob:131 to LA" but body said "do NOT hardcode" | Deploy 1 table: row updated to "No change" |
| **HIGH** | `SHOW timezone` missing from Deploy 2 smoke test | Deploy 2 step 9 + Key Pre-Deploy Audit Commands updated |
| **HIGH** | `TimezoneService` cache described as keyed by `facilityCode` only | Multi-Tenant §5 note: updated to composite tenant key |
| **HIGH** | `receiptdate` audit missing from Phase 2.5 | Phase 2.5 fix table: row added |
| **MAJOR** | V1.2.01 not idempotent — re-run double-shifts timestamps | Phase 3 table: idempotency guard noted |
| **MAJOR** | `$parseTransactionReportDate` silently accepted non-string inputs | Phase 4.3: `TypeError` on non-string input noted |
| **MAJOR** | V1.2.04 recovery missing inline SQL | Plan expanded (see full plan for recovery script) |
| **MAJOR** | Rollback RTO not measured during rehearsal | Deploy 2 pre-work: RTO measurement step added |
| **MAJOR** | OMS-side UTC compatibility not verified pre-deploy | Deploy 2 pre-work: OMS verification step added |
| **MAJOR** | StockrecordRepository HAL callers experience 8h shift | Deploy 2 pre-work: HAL audit step added |
| **MEDIUM** | `tenant_db_configuration.tenant` is FK, not string — Step 5 query wrong | §0.6 Step 5: query updated with JOIN |
| **MEDIUM** | V1.2.99 rollback not parameterized for NY clients | §0.6 Step 4: sed command for rollback added |
| **MINOR** | `SyspropService` caches by `facilityCode:key` only — wrong tenant possible | Phase 2.4 note in full plan; Phase 2.6 audit note added |
| **LOW** | `SET statement_timeout=0` only in §0.5 psql call, not inside V1.2.01 | Phase 3 table: noted |
