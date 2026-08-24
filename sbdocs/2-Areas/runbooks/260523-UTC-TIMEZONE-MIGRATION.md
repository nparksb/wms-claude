---
title: "UTC Timezone Migration — v2/wms2-api + frontends"
ticket: ""
ticket_url: ""
type: migration
priority: high
status: "RUNBOOK 2026-08-20 — all four CODE phases are merged (fba957d8 / wms2-api PR #47): JVM+Hibernate pinned to UTC (StartApplication.java:61, application.properties:115), TimezoneService present, V1.2.01-05 authored, both UIs code-complete. What remains is an OPS runbook (schedule the per-tenant maintenance window; first confirm via the landlord that no two ACTIVE tenants share a facility_code) plus a handful of Phase 5 cleanups. Moved out of 1-Projects during the backlog triage because it was being counted as an unimplemented plan for 2528 lines of mostly-done work. ONE Phase 5 item was extracted and fixed separately: the cross-tenant cache-key leak recorded here as MINOR-4 turned out to span 23 annotations and 5 caches, not just SyspropService."
project: [wms2-api, wms2-web-ui, wms2-mobile-ui]
version: v2
requester: "nam.park@siteboss.net"
created: 2026-05-23
updated: 2026-06-03
related:
  - ../../../3-Resources/reports/260527-wms-v1-v2-db-migration-script-comparison.md
  - ../../../3-Resources/reports/260526-utc-migration-code-changes-reference.md
tags:
  - plan
  - draft
  - wms2
  - migration
  - timezone
---

# UTC Timezone Migration Plan

> **Pre-flight audits (2026-06-03):** Codebase-side go/no-go checks run against current `wms2-api`.
> - **PgBouncer (Phase 2.6 dependency):** NOT deployed — `PgBouncer_Connection_Pool_Strategy_2026-04-05.md` is status *Pending*; no `pool_mode`/`6432`/pgbouncer in resources; architecture is direct per-tenant HikariCP → Postgres. The `connectionInitSql` session-GUC approach is **safe today**. Re-evaluate only if the pending PgBouncer proposal ships in transaction-pool mode.
> - **StockrecordRepository HAL endpoint (MAJOR-4):** `transactionDetailByClientNumberAndSkuBetweenDates` / `transactionSummaryByClientNumberBetweenDates` are `@RepositoryRestResource`-exported but have **zero callers** in any v2/v1 UI, OMS (PHP), or wms2-api service code. Internal 8-hour-shift risk is unconfirmed-but-unused; still confirm no external/monitoring client hits them before Deploy 2.
> - **SyspropService cache key (MINOR-4):** confirmed `key = facilityCode + ':' + #key` on **two** methods — `SyspropService.java:95` AND `:288` (plan body cited only 288). Assumption "no two active tenants share a `facilityCode`" still requires a **landlord-DB** query (not reachable from the tenant-DB MCP connections): `SELECT facility_code, COUNT(DISTINCT tenant_id) FROM tenant_db_configuration GROUP BY facility_code HAVING COUNT(DISTINCT tenant_id) > 1;` — must return 0 rows.
>
> **Re-validated:** 2026-05-23 against wms2-api source + wms2-wineco-dev DB.
> All entity counts, column counts, line numbers, and phase notes updated.
> See inline `[v2]` callouts for corrections vs the original v1-derived draft.
> **Round 2 fixes applied:** 2026-05-23. See `[Round 2 fix]` callouts for all material changes.
> **Round 3 fixes applied:** 2026-05-23. See `[Round 3 fix]` callouts for all material changes.
> **Round 4 fixes applied:** 2026-05-23. See `[Round 4 fix]` callouts for all material changes.
> Round 4 covered notes (no separate edits required): FIX R4-m2 covered by R4-M1 logger declaration; FIX R4-m6 covered by R4-M4 rollback header drop/recreate order; FIX R4-m7 covered by R4-M7 Step 1.5 afterCommit wait.
> **Round 5 fixes applied:** 2026-05-23. See `[Round 5 fix]` callouts — R5-C1 (outbox column names), R5-M1 (Deploy 2 step ordering), R5-M2 (§0.5 pre-flight), R5-m1 (invalidateCache), R5-m2 (V1.2.03 assertion), R5-m3 (facilityCode threading note).
> **Round 6 fixes applied:** 2026-05-25. See `[Round 6 fix]` callouts — Phase 4.0 (timezone bootstrapped from `tenant_discovery` via `initTenantAuth.client.js`, not sysprops); Phase 4.3 store path corrected; Phase 4.6 superseded.
> **Round 7 fixes applied:** 2026-05-25. See `[Round 7 fix]` callouts — multi-instance deployment context added to §Context; Phase 2.1 rewritten to explicitly DELETE the 3 local-TZ `application.properties` lines; Phase 2.10 (new): complete DB stored-function caller impact analysis; Phase 2.5 expanded with picking-date/order-release timezone analysis (early-release for LA, late-release for UTC+, CustomerorderService state-transition bug, 4 regression test cases); Phase 4 intro: frontend display responsibility principle; Phase 4.7 (new): frontend→backend timestamp contract table; Phase 5.4 updated to reflect Phase 2.1 now owns property cleanup; 4 new Risk Mitigation rows.
> **Round 8 fixes applied:** 2026-05-25. See `[Round 8 fix]` callouts — CRITICAL-1: ReplenishOrderJob facilityCode instruction corrected (no-arg overload is correct; TenantContext is set); CRITICAL-2: BOL `shipped` Scenario C added to Phase 2.5; HIGH: phantom `customerOrderOnHold` OMS notification + position-level FUTURE_PICKING_DATE state gap documented; MAJOR fixes: StockrecordRepository Spring Data REST date-binding caveat (Phase 2.10), `$parseTransactionReportDate` helper added (Phase 4.7), RestIdempotencyService + MobileReplenishService added to Phase 2.5 audit lists, code-example LocalDate.parse overload corrected, DST query-cast asymmetry added to Risk Mitigation, scale-to-0 deployment step added, Phase 4.1 stale sysprop reference removed.
> **Round 9 fixes applied:** 2026-05-25. See `[Round 9 fix]` callouts — CRITICAL: ReplenishOrderJob.java:371,405 `new Date()` reclassified as correct-via-session-TZ (Scenario D analysis added); HIGH: phantom-OMS claim narrowed to "BOTH stuck-state AND stock shortfall"; Deploy 2 IN_FLIGHT verification note before scale-to-0; Phase 4.7 grep audit directive added; MAJOR: `$parseTransactionReportDate` moment.tz format-string bug fixed; MobileReplenishService reclassified as already-correct; Files Summary ReplenishOrderJob entry corrected; BOL entity-default construction-site verified; OrderReleaseJob.java:131 inconsistency resolved; duplicate verification-list "6." renumbered.
> **Round 10 fixes applied:** 2026-05-25. See [Round 10 fix] callouts — warehouse table + mywms_user_warehouse removed from plan (user will delete tables); timezone source changed from warehouse.timezone column to System Time Zone sysprop (los_sysprop table) throughout; resolveWarehouseTz() query updated to los_sysprop; facilityCode parameter removed from resolveWarehouseTz; TimezoneService updated to use syspropService; V1.2.03 warehouse section removed; Phase 5.5 removed; all warehouse.timezone references replaced.
> **Round 11 fixes applied:** 2026-05-25. See `[Round 11 fix]` callouts — multi-timezone clarification: hibernate.jdbc.time_zone=America/Los_Angeles is GLOBAL (all tenant data written as LA wall-clock; V1.2.01 AT TIME ZONE 'America/Los_Angeles' is correct for all tenants); System Time Zone sysprop is PER-TENANT (LA or NY); two-layer distinction added to context, Phase 3.1, and Multi-Tenant Considerations; Scenario A/B UTC-rollover windows updated to show LA (UTC-8) and NY (UTC-5) examples; Phase 1 CronTrigger note clarified (schedule TZ vs business-date TZ are independent); OrderReleaseJob Phase 1 pin note corrected (keep sysprop-reading, don't hardcode LA).
> **Round 12 fixes applied:** 2026-05-26 (Architect + Critic review). See `[Review fix]` callouts — CRITICAL: resolveWarehouseTz() column names corrected (key→syskey, value→sysvalue, added workstation='DEFAULT' filter, silent catch→ERROR log); pool-init vs runtime path separation documented; construction-site audit extended to BillofladingService:239 setShipped(null); Flyway schema history divergence warning added (§0.6 Step 2.5); customerorder_old v1 handling steps added (§0.6 Steps 2.6 + 3.5); HIGH: $parseTransactionReportDate uses app.$moment.tz() not bare moment.tz; Files Summary OrderReleaseJob:131 contradiction removed; SHOW timezone added to Deploy 2 smoke test; TimezoneService cache key description corrected to composite key; script filenames standardized in §0.5 runbook; MAJOR: V1.2.01 idempotency guard added; V1.2.99 rollback sed parameterization note added; V1.2.04 recovery instructions expanded; MEDIUM/LOW: §0.6 Step 5 query fixed (FK join); SyspropService cache-key warning added; SET statement_timeout added inside V1.2.01.
> **Round 13 fixes applied:** 2026-05-27 (DB migration script comparison). **⚠️ SUPERSEDED by Round 14 (2026-05-30) — the v1-compat / 5-step A–E approach described here no longer applies; §0.6 Step 3 is now a single linear apply of the standard V2.1.x scripts. Retained below as history only.** CRITICAL: §0.6 Step 3 rewritten — flat loop replaced with 5-step A–E sequence; V2.1.08 standard variant removed from v1 DB runbook (PK collision on ids 142–143); Step C then used `V1.1.13__stale_club_batch_cleanup_sysprops_v1compat.sql` from `db/migration/v1-onboarding/` (since deleted); pre-check SQL for stuck orders + sysprop ID audit added before Step A; OMS endpoint sysprops Step E added (V1.1.17 template); incorrect "WHERE NOT EXISTS" description corrected; new Risk Mitigation row added for V2.1.08 PK collision. Source: `260527-wms-v1-v2-db-migration-script-comparison.md §7–8`.
> **SBDEV-1921 post-implementation update:** 2026-05-29. Two additional Flyway migrations shipped with the Order Cancellation & Reversal feature: V2.1.12, V2.1.13. Context watermark updated; `customerorder_cancellation_log` documented as pre-UTC-compliant (all timestamp columns already `TIMESTAMPTZ` — no V1.2.x conversion needed); §0.6 Step 3 apply-loop extended to apply V2.1.12, V2.1.13 on v1 client onboarding (Round 14 collapsed the former lettered sub-steps into a single linear loop — there is no "Step F"); §5.7 onboarding template step reference updated.
> **Round 14 fixes applied:** 2026-05-30 (live `wms1-wineco-dev` simulation). **§0.6 Step 3 SIMPLIFIED to a single linear apply of the standard V2.1.x scripts in order — no v1-compat branching, no separate onboarding step.** Validated against the real v1 client DB: re-id'd V2.1.08 (140/141/142) and V2.1.09 (143) NO-OP via composite `ON CONFLICT`; V2.1.02 seeds OMS sysprops into FREE ids 144/145; V2.1.13 copies the present `WEBSERVICE_ORDER_BATCH_CANCELLED` row; V2.1.01 unique constraint succeeds (0 dup labelids). The two former v1-onboarding scripts (`V1.1.13__..._v1compat.sql`, `V1.1.17__oms_endpoint_sysprops_v1client.sql`) were **DELETED** from the repo. Per-client steps now: (a) stuck-transfer-order pre-flight fix; (b) OMS host substitution in V2.1.02 + V2.1.13. Round-13 V2.1.08-PK-collision risk row marked RESOLVED. Added "Gaps / Open Items" G1–G5 (G1/G2 since RESOLVED — V2.1.12 parses cleanly, V2.1.02 idempotent; see §0.6).

## Context

The WMS-API currently stores all timestamps in warehouse-local time using PostgreSQL `timestamp without time zone` columns. **Two independent timezone layers exist:** `[Round 11 fix]`

1. **Hibernate write-path timezone (global, `America/Los_Angeles` for ALL tenants):** `hibernate.jdbc.time_zone=America/Los_Angeles` in `application.properties` is a single server-wide setting. Every tenant's `created`/`modified` and other `LocalDateTime` columns are stored as **LA wall-clock** regardless of the tenant's actual location. A NY-warehouse user's action at 3 PM NY time is stored as `15:00` in the column, but Hibernate interprets that as 3 PM LA = UTC 23:00. The migration SQL therefore uses `AT TIME ZONE 'America/Los_Angeles'` for all Group A tables — this is correct for every tenant because they all share the same global Hibernate config.

2. **Business-date timezone (per-tenant, from `System Time Zone` sysprop):** Each tenant's `los_sysprop` row for `"System Time Zone"` controls what "today" means for business logic — order release, picking-date comparisons, session GUC for `CURRENT_DATE`. This value differs across tenants: LA warehouses use `"America/Los_Angeles"` (UTC−8/UTC−7 DST); NY warehouses use `"America/New_York"` (UTC−5/UTC−4 DST). The UTC-rollover window (when warehouse wall-clock is still "today" but UTC has already crossed midnight to "tomorrow") spans 8 hours for LA and 5 hours for NY.

This creates fragile behavior around DST transitions, deployment environment differences, and multi-tenant operation where warehouses are in different timezones.

### Multi-Instance Deployment Model `[Round 7 fix — NEW]`

wms2-api runs as **one or more horizontally-scaled instances** depending on load. All instances are stateless. Multi-tenancy is handled by reading the `tenant_name` and `facility_code` HTTP headers on each request and routing to the correct tenant database via `TenantFilter` → `TenantDynamicRoutingDataSource` (database-level multiplexing). Because all instances share the same `application.properties` and container environment, **any timezone setting in that file applies uniformly to every instance**. The migration therefore makes a clean, global switch:

- **Before:** all instances write timestamps using `America/Los_Angeles` (global `hibernate.jdbc.time_zone` + Jackson + JVM all aligned to LA). Per-tenant business-date logic uses each tenant's `System Time Zone` sysprop (LA or NY). `[Round 11 fix]`
- **After:** all instances operate exclusively in UTC — Hibernate writes UTC, Jackson serializes UTC, JVM clock is UTC, and the frontend is solely responsible for converting UTC timestamps to the warehouse's local timezone for display

There is no per-instance or per-tenant timezone in `application.properties`; per-tenant display time is handled by `System Time Zone` sysprop (from `los_sysprop`) → `connectionInitSql` session GUC (for `CURRENT_DATE` in views/queries) and by the `TimezoneService` (for business logic like "today's picking date"). `[Round 10 fix]`

### Four-Way Timezone Disagreement (Root Cause)

The system has **four independent timezone sources** that can silently disagree:

1. **PostgreSQL server** -- uses its `timezone` GUC (often UTC in cloud-hosted) for `current_date`/`current_timestamp` in views/queries
2. **Hibernate** -- configured with `hibernate.jdbc.time_zone=America/Los_Angeles`, controls how `LocalDateTime` is written to `timestamp without time zone` columns
3. **JVM** -- uses host OS default (NOT explicitly set), controls `LocalDate.now()`, `LocalDateTime.now()`, `new Date()`, `CronTrigger` scheduling
4. **Per-tenant sysprop** -- `"System Time Zone"` in `los_sysprop` = `"America / Los_Angeles"` (confirmed in wms2-wineco-dev). Only used by `OrderReleaseJob`

Since `LocalDateTime` carries no timezone info and `timestamp without time zone` carries no timezone info, the "correct" interpretation depends on which layer you ask. A misleading comment at `OrderReleaseJob.java:131` (via `WmsConstants.DATE_PATTERN`) treats timestamps as if they were UTC.

### Current State (Verified Against wms2-api Source + wms2-wineco-dev DB)

**Backend (wms2-api):**
- **44** JPA entities extending `AbstractBaseEntity` with `LocalDateTime created`/`modified` fields (~88 audit columns) `[v2: plan said 61 — that was v1]`
- Business-specific `LocalDateTime` columns:
  - `Goodsreceipt.receiptdate`
  - `InventoryRecord.timestamp`
- Business-specific `LocalDate` columns (unchanged by migration): `Customerorder.pickingdate`, `Billoflading.shipped`, `Advice.dayofdelivery`, `Advice.dayofdeliveryuntil`
- **100 `timestamp without time zone` DB columns, 5 `date` columns, 3 `timestamptz`** across **50 base tables** `[v2: plan said 88 cols / 45 tables — 5 new tables added post-plan; see Phase 3.1; `customerorder_cancellation_log` (SBDEV-1921) contributes 3 `timestamptz` columns already — no V1.2.x conversion needed]`
- 3 stored functions (`stock_history`, `transaction_detail`, `transaction_summary`) accept `timestamp without time zone` params — confirmed
- **6** cron-triggered scheduled tasks with NO timezone parameter on `CronTrigger` `[v2: plan said 5 — staleClubBatchCleanup added post-plan]`
- **46** `new ObjectMapper()` instances (including static class-level `MAPPER` fields) bypassing Spring timezone/date config `[v2: plan said 36+]`
- No thread-unsafe *static* `SimpleDateFormat` on singleton beans in wms2 `[v2: plan incorrectly cited AdviceController.java:38 and CustomerOrderBatchController.java:26 — those are v1 only]`
- `YYYY` week-year bug **already fixed** in wms2 via `DateTimeFormatter` in `FileExportService.java:33` and correct `yyyy` in `WmsConstants.java:1089` `[v2: Phase 1.4 is complete — no action needed]`
- Entity field default `Billoflading.java:21`: `private LocalDate shipped = LocalDate.now()` (uses JVM TZ) -- confirmed
- `WebConfigurer.java:70` uses `TimeZone.getDefault()` instead of the configured `America/Los_Angeles` -- confirmed
- `StartApplication.java:47` creates a second `ObjectMapper` bean without `JavaTimeModule`
- Jackson serializes `LocalDateTime` as `"yyyy-MM-dd HH:mm:ss"` (no timezone indicator) via `WebConfigurer.java:36`
- `JavaTimeModule` IS registered in `WebConfigurer` (unlike v1) -- confirmed at lines 52 and 88

**New wms2-specific tables (post-plan additions):**
| Table | ts cols | Java entity | Notes |
|-------|---------|------------|-------|
| `outbox_message` | 4 (`created_at`, `modified_at`, `next_attempt_at`, `sent_at`) | `OutboxMessage.java` — uses `Instant`, **not** `LocalDateTime` | SBDEV-2221; Instant→`timestamp without time zone` is a pre-existing type mismatch |
| `rest_idempotency` | 2 (`created_at`, `updated_at`) | `RestIdempotency.java` — uses `LocalDateTime` | SBDEV-2222 |
| `customerorder_cancellation_log` | 3 (`reversal_initiated_at`, `reversal_completed_at`, `created_at`) — **already `TIMESTAMPTZ`** | `CustomerorderCancellationLog.java` — uses `OffsetDateTime` | SBDEV-1921; **no V1.2.x conversion needed** — V2.1.12 authored all timestamp columns as `TIMESTAMP WITH TIME ZONE`. V1.2.03 must skip this table. `reversal_initiated_by`/`reversal_completed_by` are `VARCHAR(255)`, created directly by V2.1.12 (no ALTER). |

`[Round 3 fix — FIX 1]` `customerorder_old` — excluded. Zero references in wms2-api; single 2019-era archive row; no application code reads or writes it.

`[Round 10 fix]` The `warehouse` table and `mywms_user_warehouse` table have been removed from this migration's scope — they are not actively used in wms2-api and will be deleted separately by the user. The per-tenant timezone source for `connectionInitSql` and `TimezoneService` is the `los_sysprop` row keyed by `"System Time Zone"` (see Phase 2.6 and Phase 2.4).

**`[Round 2 fix — C1]` Hibernate `Instant` vs `LocalDateTime` write semantics:**
- Tables written by Hibernate `LocalDateTime` (via `hibernate.jdbc.time_zone=America/Los_Angeles`): all 44 `AbstractBaseEntity` tables, `rest_idempotency`. Existing values are **LA wall-clock** stored in `timestamp without time zone` — this applies to **all tenants** because `hibernate.jdbc.time_zone` is a global server setting in `application.properties`, not per-tenant. NY-warehouse data is also stored as LA wall-clock. `[Round 3 fix — FIX 1]` `customerorder_old` excluded. `[Round 10 fix]` `warehouse` removed (table out of scope). `[Round 11 fix]` Multi-tenant clarification added.
- `outbox_message` uses `java.time.Instant`. Hibernate maps `Instant` via `calendarUTC` regardless of `hibernate.jdbc.time_zone`. Existing values are **UTC wall-clock** stored in `timestamp without time zone`.
- These two groups require different `USING` clauses in the migration — see Phase 3.1.

**Database (Flyway migrations):**
- Latest migration watermark: **`V2.1.15__add_api_timestamp_format_sysprop.sql`** (the v2-specific sequence runs contiguously V2.1.01–V2.1.15; V2.1.14 = outbox aggregate-order index, V2.1.15 = Phase 2.9 `API_TIMESTAMP_FORMAT` seed; SBDEV-1921 had added V2.1.12/V2.1.13) `[v2: plan context assumed V1.1.08 was latest]`
- 50 tables with timestamp columns (49 with `timestamp without time zone`; 1 — `customerorder_cancellation_log` — already `timestamptz`; see Phase 3.1)
- 5 `date` columns remain as-is
- 3 stored functions with `TIMESTAMP WITHOUT TIME ZONE` params and return types
- 11 views total; **2 use `current_date`**: `order_monitor_view`, `replenishment_monitor_view` `[v2: plan said 12 views / 3 use current_date]`

**Application properties (confirmed):**
```
spring.jpa.properties.hibernate.jdbc.time_zone=America/Los_Angeles   ← line 108
spring.jackson.time-zone=America/Los_Angeles                          ← line 107
#user.timezone=America/New_York                                       ← line 105, commented out
```

**Frontends (wms2-web-ui, wms2-mobile-ui):**
- Both use `@nuxtjs/moment` ^1.6.1 with moment-timezone
- wms2-web-ui: `defaultTimezone: 'America/Los_Angeles'` in buildModules config
- wms2-web-ui: conflicting `publicRuntimeConfig.moment.defaultTimezone: 'America/New_York'` -- **unused by module, dead config**
- wms2-mobile-ui: NO `moment:` config block at module level -- **timezone support not activated**
- 70+ component-local date formatting methods (`getDate()`, `getTimeDate()`, `formatDate()`) -- **no centralized utility**
- Vuex stores perform **zero date transformation** -- API strings stored and displayed as-is

### Migration Use Cases

This plan serves two scenarios:

1. **Existing wms2 tenant databases** (clients already on wms2): All data was written by the shared wms2 instance with `hibernate.jdbc.time_zone=America/Los_Angeles`. Migration uses `AT TIME ZONE 'America/Los_Angeles'` for all Group A tables. This is the primary validated scenario (wms2-wineco-dev).

2. **v1 client databases being onboarded to wms2** (existing clients migrating from v1): Each v1 instance ran with its own `hibernate.jdbc.time_zone`. Data is stored as the v1 instance's wall-clock convention, not necessarily LA. The migration `AT TIME ZONE` clause must match the v1 client's Hibernate config — see §0.6.

> **New clients onboarding directly to wms2 require no migration** — a fresh database created against the shared `application.properties` writes UTC from the first row. This plan does not apply to them.

### Goal

Store all timestamps in UTC, convert column types to `timestamptz`, and make all timezone handling explicit. Use the `System Time Zone` sysprop (`los_sysprop` table) for business date logic (e.g., "today's orders") and for frontend display conversion. `[Round 10 fix]`

### API Date Format Decision

**Backend sends ISO-8601 UTC:** `"2026-02-10T22:30:00.000Z"`

The frontend receives the warehouse timezone string from `tenant_discovery.timezone` (landlord DB, exposed via `GET /api/public/authConfig` — see Phase 4.0) and converts UTC to warehouse-local time for display. `[Round 10 fix]`

### Deployment Strategy

Maintenance window (brief downtime). Flyway converts data at startup before app serves requests. Frontend deployment immediately follows backend.

---

## Phase 0: Rollback Strategy `[Round 2 fix — C2]`

**Purpose:** Establish a clear rollback path before any changes are made. Confirm the go/no-go decision window, decision owner, and abort criteria upfront.

### 0.1 Pre-Migration Backup

Run BEFORE the maintenance window for every tenant database:

```bash
# Per tenant DB — run BEFORE maintenance window
pg_dump -Fc -h <host> -U <user> -d <tenant_db> -f /backups/wms2_<tenant>_pre_utc_$(date +%Y%m%d_%H%M).dump
# Estimated time: ~5-10 min per tenant at current DB size
```

### 0.2 Rollback SQL Companion

**File:** `src/main/resources/db/rollback/V1.2.99__rollback_utc_migration.sql`
**AUTHORED + round-trip-validated against PostgreSQL 16 (2026-06-03).** NY copy:
`src/main/resources/db/onboarding-tz-variants/V1.2.99__rollback_utc_migration_America_New_York.sql`.

> **MANUAL USE ONLY — do not run via Flyway.**
> Reverts `timestamptz` → `timestamp without time zone`.
> Run ONLY from a psql session with explicit authorization from the decision owner.

> **⚠️ Why it lives in `db/rollback/`, NOT `db/migration/` `[2026-06-03]`:** `V1.2.99` is a
> HIGHER version than the forward scripts (`V1.2.01–05`). If it sat in the Flyway scan path and
> Flyway were ever enabled, it would run LAST and **silently undo the entire migration**. The
> forward scripts are re-run-safe (idempotency canary aborts), but this one actively reverts —
> so it is deliberately kept out of `db/migration/`. (wms2-api does not invoke Flyway today, but
> this removes the latent footgun.)

> **Structure (mirror of the forward chain, validated by round-trip — a seeded value returns to
> its exact original digits):** PART 0 drop 11 views → PART 1 Group A standard (LA) → PART 2 large
> tables (LA, non-tx, per-table resumable) → PART 3 outbox/rest_idempotency (UTC) → PART 4 recreate
> 11 views → PART 5 recreate the 3 functions with their original `timestamp`-without-tz signatures
> (PART 4 precedes PART 5 because `stock_history` RETURNS `stock_view.%TYPE`).

```sql
-- MANUAL USE ONLY — do not run via Flyway
-- Reverts timestamptz → timestamp without time zone
-- Run this ONLY from a psql session with explicit authorization

-- [Round 4 fix — FIX R4-M4]
-- MANUAL RUNBOOK: set timeouts before running rollback (same as forward V1.2.02)
SET statement_timeout = 0;
SET lock_timeout     = 0;

-- Drop order for functions (N-R3-9): dependents first, then base.
-- DROP FUNCTION IF EXISTS transaction_detail(...);
-- DROP FUNCTION IF EXISTS transaction_summary(...);
-- DROP FUNCTION IF EXISTS stock_history(...);
-- Recreate order: stock_history FIRST (called by the other two), then transaction_detail, transaction_summary.
-- Source: V1.0.03__wms_functions.sql lines 13 (stock_history), 87 (transaction_detail), 449 (transaction_summary)
--         V2.1.07__update_transaction_detail_pick_amount_filter.sql line 9 (transaction_detail override)
-- Copy the CREATE OR REPLACE FUNCTION bodies from those files and replace timestamptz → timestamp without time zone
-- in the parameter signatures before pasting here.

-- PART 0: DROP all 11 views first [2026-06-03] — the reverse ALTERs below hit the SAME
--         PostgreSQL "cannot alter type of a column used by a view" blocker as the forward
--         migration. Use the same DROP VIEW IF EXISTS ... CASCADE list as V1.2.01.
-- PART 1: Standard tables (reverse of V1.2.01) — transactional
-- PART 2: Large tables (reverse of V1.2.02) — run with statement_timeout=0, same caution as forward
-- PART 3: outbox + new tables (reverse of V1.2.03) -- [Round 10 fix] warehouse removed
-- PART 4: Function signatures (reverse of V1.2.05)
-- PART 5: RECREATE all 11 views [2026-06-03] — re-run the verbatim CREATE statements from
--         V1.2.04__utc_recreate_views.sql (they are timezone-agnostic; the column type underneath
--         is back to `timestamp without time zone`, which the view bodies expose transparently).

-- Group A tables (were LA wall-clock, now stored as UTC in timestamptz → convert back)
ALTER TABLE advice ALTER COLUMN created TYPE timestamp without time zone
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE advice ALTER COLUMN modified TYPE timestamp without time zone
  USING modified AT TIME ZONE 'America/Los_Angeles';
-- ... repeat for all Group A tables (all 44 AbstractBaseEntity tables,
--     goodsreceipt.receiptdate, inventory_record.timestamp,
--     rest_idempotency) ... -- [Round 10 fix] warehouse removed
-- [Round 3 fix — FIX 1] customerorder_old excluded — zero wms2-api references, no migration applied

-- Group B tables (outbox_message — were UTC, stored as UTC in timestamptz → convert back)
ALTER TABLE outbox_message ALTER COLUMN created_at TYPE timestamp without time zone
  USING created_at AT TIME ZONE 'UTC';
ALTER TABLE outbox_message ALTER COLUMN modified_at TYPE timestamp without time zone
  USING modified_at AT TIME ZONE 'UTC';
ALTER TABLE outbox_message ALTER COLUMN next_attempt_at TYPE timestamp without time zone
  USING next_attempt_at AT TIME ZONE 'UTC';
ALTER TABLE outbox_message ALTER COLUMN sent_at TYPE timestamp without time zone
  USING sent_at AT TIME ZONE 'UTC';

-- ============================================================
-- PART 3: Restore stored function signatures to timestamp without time zone
-- [Round 3 fix — FIX 8]
-- Copy function bodies from V1.0.03__wms_functions.sql and
-- V2.1.07__update_transaction_detail_pick_amount_filter.sql
-- ============================================================
-- DROP FUNCTION IF EXISTS stock_history(timestamptz);
-- DROP FUNCTION IF EXISTS transaction_detail(varchar, varchar, timestamptz, timestamptz);
-- DROP FUNCTION IF EXISTS transaction_summary(varchar, timestamptz, timestamptz);
-- [recreate with timestamp without time zone signatures from V1.0.03 + V2.1.07]
```

<!-- [Round 4 fix — FIX R4-m1] -->
**To complete PART 3 during rollback** `[Round 4 fix — FIX R4-m1]`:
1. Copy `stock_history` body from `V1.0.03__wms_functions.sql` lines 13–86.
2. Copy `transaction_detail` body from `V2.1.07__update_transaction_detail_pick_amount_filter.sql` lines 9–end.
3. Copy `transaction_summary` body from `V1.0.03__wms_functions.sql` lines 449–end.
4. In each body, replace `timestamptz` → `timestamp without time zone` in all parameter signatures.
5. Drop order: `transaction_detail`, `transaction_summary`, then `stock_history`.
6. Recreate order: `stock_history` first (it is called by the other two), then `transaction_detail`, then `transaction_summary`.
Rehearse this step per §0.4 before the migration window.

### 0.3 Decision Tree

- **Go/no-go decision window:** 2 hours after Deploy 2 cutover
- **Decision owner:** must be named in deployment runbook before the maintenance window opens
- **Abort criteria:** any one of the following:
  - Orders showing wrong picking date (off by one day)
  - Outbound OMS integrations silent for > 15 minutes
  - `order_monitor_view` returning empty or clearly wrong data
- **Soft rollback (preferred if possible):** Revert application code to LA config (`hibernate.jdbc.time_zone=America/Los_Angeles`, `spring.jackson.time-zone=America/Los_Angeles`), leave schema as `timestamptz`, add `SET timezone='America/Los_Angeles'` to `connectionInitSql` as a temporary bridge. This avoids a second full table rewrite and is the lowest-risk recovery option for the **data**. `[Architect M2]` **Correctness basis:** LA-configured Hibernate writing/reading a `LocalDateTime` against a `timestamptz` column round-trips correctly — Hibernate applies the configured `America/Los_Angeles` offset symmetrically on write and read, so the absolute instant is preserved. **Caveat:** this is NOT a hot config flip — changing `connectionInitSql` requires a code/config redeploy AND a pool recreation (per `[Architect H1]` above). Measure the soft-rollback redeploy time, not just the hard-rollback `pg_restore` time, against the 2-hour go/no-go window.
- **Hard rollback:** Apply `V1.2.99__rollback_utc_migration.sql` manually from psql, restore application code, redeploy Deploy 1 build.

### 0.4 Rollback Rehearsal

Before production deploy: [Round 5 fix — N-R5-3 / m-R5-3]

**Forward dry-run (staging):**
1. Restore a production-sized tenant DB dump to a staging clone.
2. Run V1.2.01–V1.2.05 against it using the §0.5 psql runbook.
3. Start the app with the new UTC properties — verify API date responses and scheduled job output.
4. Record per-table row counts and sample timestamps as the pre-rollback baseline.

**Rollback rehearsal:**
5. Run `V1.2.99__rollback_utc_migration.sql` on the staged migrated DB:
   ```bash
   PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <staging_db> \
     -f V1.2.99__rollback_utc_migration.sql
   ```
6. Time the full restore — this is your RTO baseline (must fit within the go/no-go window).
7. Verify timestamps round-trip correctly back to LA wall-clock for both Group A (LA) and Group B (UTC) tables.
8. Restart the app with the old LA properties — verify behaviour is identical to pre-migration.

<!-- [Round 4 fix — FIX R4-C1] -->
### §0.5 Per-Tenant Migration Deployment `[Round 4 fix — FIX R4-C1]`

**wms2-api has no programmatic Flyway invocation.** `flyway-core` is on the classpath
but `src/main/java` contains zero `Flyway`, `FlywayConfigurationCustomizer`, or
`Flyway.configure()` calls. Spring Boot Flyway auto-config has no `spring.datasource.*`
to bind to (the app uses `landlord.datasource.*`). The `-- flyway.executeInTransaction=false`
headers in V1.2.02 are inert comments when run via psql. **They do NOT imply Flyway-readiness**
`[Architect H3]`: the app's Hikari pools are built with `cfg.setAutoCommit(false)`
(`TenantDynamicRoutingDataSource.java:83`), and `executeInTransaction=false` on a non-autocommit
connection is a known Flyway footgun (no explicit commit boundary around the `SET ...`/`ALTER`).
If per-tenant Flyway is ever introduced it must run against a dedicated `autoCommit=true` admin
datasource — not the application's pooled datasource. For now these scripts are **psql-only**.

**Deployment mechanism: manual psql per tenant DB.**

**Pre-flight: verify connectivity to every tenant DB before starting.** [Round 5 fix — FIX R5-M2]
If any tenant is unreachable, abort before running any migration script.
A mixed-state cluster (some tenants migrated, some not) requires manual per-tenant rollback.

```bash
# Pre-flight ping — run BEFORE any migration scripts
for tenant_db in <tenant_db_1> <tenant_db_2> ...; do
  PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d "$tenant_db" \
    -c "SELECT 1" -q --no-psqlrc \
    && echo "OK: $tenant_db" \
    || { echo "ABORT: $tenant_db unreachable — fix before proceeding"; exit 1; }
done
```

> **v1 client migration:** Run §0.6 pre-flight BEFORE this runbook. §0.6 determines the correct `AT TIME ZONE` clause for this client and brings the DB to the V2.1.13 schema watermark required by V1.2.01–V1.2.05. Do NOT run V1.2.01 on a v1 DB without first completing §0.6.

**Preconditions** (Deploy 2 steps 1–4 must be complete before running this runbook):
- Maintenance mode active (all HTTP writes quiesced)
- OutboxDispatcherJob drained (0 PENDING/IN_FLIGHT/FAILED_RETRY rows)
- `rest_idempotency` table drained (`DELETE FROM rest_idempotency`)

For each tenant database, run in order:

```bash
# Set per the tenant's DB credentials
PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <tenant_db> \
  -c "SET statement_timeout = 0;" \
  -f V1.2.01__utc_standard_tables.sql

PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <tenant_db> \
  -c "SET statement_timeout = 0; SET lock_timeout = 0;" \
  -f V1.2.02__utc_large_tables.sql   # 3.6 GB stockrecord + 2.5 GB inventory_record

PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <tenant_db> \
  -f V1.2.03__utc_outbox_and_new_tables.sql

# V1.2.04 — recreate the 11 views dropped by V1.2.01. MUST precede V1.2.05:
# stock_history's RETURNS references stock_view.%TYPE, so the view must exist first.
PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <tenant_db> \
  -f V1.2.04__utc_recreate_views.sql

# V1.2.05 — recreate the 3 stored functions (LAST). MUST run before the app starts.
PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <tenant_db> \
  -f V1.2.05__utc_update_functions.sql
```

psql runs DDL in auto-commit mode by default — no wrapping transaction around
V1.2.02 large-table ALTERs. `-v ON_ERROR_STOP=1` aborts on the first error.

Dev environment: use the same psql runbook against the local tenant DB. No
`spring.flyway.baseline-on-migrate` property is required; Flyway is not invoked
at runtime.

**`flyway_schema_history` note** [Round 5 fix — critic OPS-MINOR]:
Running these scripts via psql does NOT update `flyway_schema_history`. Since wms2-api
never invokes Flyway programmatically, this table is currently stale/absent and has no
effect. However, if per-tenant Flyway invocation is ever added in the future, the absence
of V1.2.01–V1.2.05 rows in `flyway_schema_history` will cause Flyway to re-attempt them
on next startup — protected only by the `DO $$ IF NOT EXISTS` idempotency guards in the
scripts. Document this as a known trap if Flyway is ever introduced.

### §0.6 v1 Client Database Onboarding Pre-flight `[2026-05-26 — NEW]` `[2026-05-30 — SIMPLIFIED after live validation]`

**Purpose:** Before running V1.2.01–V1.2.05 on a client being migrated from v1, complete these steps to (a) determine the correct `AT TIME ZONE` clause for this client's data and (b) bring the DB schema to the V2.1.13 watermark that V1.2.01–V1.2.05 assume.

> ✅ **Validation (2026-05-30, live `wms1-wineco-dev`):** A full simulation of the onboarding sequence against the real v1 client DB confirmed the v2 scripts apply **cleanly in order with NO v1-onboarding workarounds**:
> - `los_sysprop` already has the stale-club tuples at ids **140/141/142** (from v1's V1.1.07) → re-id'd **V2.1.08** (inserts at 140/141/142 with composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`) **NO-OPS** — no PK collision.
> - `PICK_PATH_DIRECTION` present at id **143** → **V2.1.09** (insert at 143, same `ON CONFLICT`) **NO-OPS**.
> - ids **144/145 are FREE** and `WEBSERVICE_ORDER_BATCH_PALLETIZED` / `..._LOADED_TO_TRUCK` are absent → **V2.1.02** inserts them cleanly.
> - `WEBSERVICE_ORDER_BATCH_CANCELLED` row **present** → **V2.1.13** copies its structural columns to seed `..._REVERSAL_COMPLETED` successfully.
> - **0 duplicate** `unitload.labelid` values → **V2.1.01** unique constraint succeeds.
> - `rest_idempotency`, `outbox_message`, `customerorder_cancellation_log`, and the `MOBILE_UI_VIEW_CANCELLATION` function are all **absent** → V2.1.10 / V2.1.11 / V2.1.12 create them.
>
> **Consequence:** the two former v1-onboarding scripts (`v1-onboarding/V1.1.13__..._v1compat.sql` and `v1-onboarding/V1.1.17__oms_endpoint_sysprops_v1client.sql`) have been **DELETED** from the repo. Onboarding is now a single linear apply of the standard `V2.1.x` scripts in order. See the simplified Step 3 below.

#### Step 1 — Determine the v1 Hibernate Timezone for This Client

Check the v1 instance's `application.properties` for this client:

```bash
grep "hibernate.jdbc.time_zone" v1/wms-api/src/main/resources/application.properties
# or the client-specific override in the deployment environment
```

| v1 `hibernate.jdbc.time_zone` | Client location | Data stored as | `AT TIME ZONE` to use in V1.2.01/V1.2.02 |
|---|---|---|---|
| `America/Los_Angeles` | West coast (LA) | LA wall-clock | `'America/Los_Angeles'` |
| `America/New_York` | East coast (NY) | NY wall-clock | `'America/New_York'` |

Record this as `CLIENT_HIBERNATE_TZ` — it is used in Step 4.

#### Step 2 — Verify `System Time Zone` Sysprop

```sql
SELECT sysvalue FROM los_sysprop WHERE syskey = 'System Time Zone';
-- Expected: 'America/Los_Angeles' or 'America / Los_Angeles' for west coast
--           'America/New_York'    or 'America / New_York'    for east coast
-- Must be set before wms2 starts serving this tenant (TimezoneService reads this at pool-creation time)
```

If missing or wrong, set it before proceeding:
```sql
UPDATE los_sysprop SET sysvalue = '<IANA_TZ>' WHERE syskey = 'System Time Zone';
-- e.g. 'America/Los_Angeles' or 'America/New_York'
```

#### Step 2.5 — Flyway Schema History Divergence Warning `[Review fix — CRITICAL-3 Architect]`

v1 Flyway migrations **V1.1.06–V1.1.09** have **completely different SQL content** from the wms2 migrations that historically shared those version numbers. That version-number collision is now **resolved**: the wms2 migrations were renamed into the `V2.1.x` namespace (V2.1.01–V2.1.15), so they no longer overlap with v1's `V1.1.x` versions and no Flyway checksum mismatch can arise from the overlap. The v1 DB may still carry stale `V1.1.06–V1.1.09` rows in its own `flyway_schema_history`, which is worth auditing before committing the DB to wms2:

```sql
-- Check the v1 DB's flyway_schema_history for version/checksum records
SELECT version, description, checksum, installed_on
FROM flyway_schema_history
ORDER BY installed_rank;
```

**Recommended:** After the v1 DB is committed to wms2 (Steps 3–6 complete), **`TRUNCATE flyway_schema_history`** so wms2's Flyway can re-baseline from scratch if programmatic migration is ever introduced. Record this action in the client's migration log.

> **Note:** wms2-api never invokes Flyway at runtime (see §0.5 `flyway_schema_history` note), so the checksum conflict does not affect the current manual-psql migration. This is a forward-compatibility risk only.

#### Step 2.6 — Check `customerorder_old` Row Count `[Review fix — MEDIUM-2]`

v1 client DBs may have substantive data in `customerorder_old`. Run this check before proceeding:

```sql
SELECT COUNT(*) FROM customerorder_old;
-- Expected: 0 or very low (archive-only rows)
```

If the count is **> 0**, do NOT silently skip — confirm with the client whether this data is still needed:
- **Archive-only (no longer accessed):** Take a targeted backup (`pg_dump --table=customerorder_old`), then optionally `DROP TABLE customerorder_old`. V1.2.01 does not touch this table, so it will remain with `timestamp without time zone` columns post-migration (intentionally — zero wms2-api references).
- **Still accessed by legacy tooling:** Leave it in place; document that it remains unconverted.

#### Step 3 — Apply the wms2 V2.1.x Schema Migrations in Order `[2026-05-30 — SIMPLIFIED: single linear apply, no v1-compat]`

v1 Flyway watermark is V1.1.09. wms2 V1.2.01 assumes the DB is at the **V2.1.13 watermark** (tables `rest_idempotency`, `outbox_message`, `customerorder_cancellation_log` exist; cancellation/reversal sysprops seeded). Apply the standard `V2.1.x` scripts **in order** directly against the v1 client DB — **no v1-compat branching, no separate onboarding step.** The live validation on `wms1-wineco-dev` (see §0.6 header) proved every script either inserts cleanly into free space or no-ops via its composite `ON CONFLICT`.

> ✅ **RESOLVED — former V2.1.08 PK collision concern:** Earlier revisions of this plan warned that the standard `V2.1.08__stale_club_batch_cleanup_sysprops.sql` would PK-collide on every v1 DB and therefore **required** the `v1-onboarding/V1.1.13__..._v1compat.sql` variant. **This is no longer true.** V2.1.08 was **re-id'd to align with the v1 baseline** — it now inserts at ids **140/141/142** (the same ids/syskeys v1 already seeded in V1.1.07) with a composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. On a v1 DB those exact tuples already exist, so V2.1.08 cleanly **NO-OPS with no PK violation** (validated 2026-05-30 on `wms1-wineco-dev`). The v1-compat variant is unnecessary and **has been deleted from the repo.**

**Pre-check (run before starting):**

```sql
-- Count stuck transfer orders — the non-Flyway pre-flight fix below resets these
SELECT COUNT(*) FROM customerorder WHERE state = 510 AND transferlane_id IS NULL;

-- Audit sysprop IDs 140–150 to confirm expected v1 layout
SELECT id, syskey, sysvalue FROM los_sysprop WHERE id BETWEEN 140 AND 150 ORDER BY id;
-- Expected on v1: 140-142 = STALE_CLUB_BATCH_CLEANUP_*, 143 = PICK_PATH_DIRECTION,
--                 144/145 FREE (V2.1.02 will seed the OMS sysprops there)

-- Confirm zero duplicate unitload labelids (V2.1.01 adds a UNIQUE constraint)
SELECT labelid, COUNT(*) FROM unitload GROUP BY labelid HAVING COUNT(*) > 1;

-- [Architect H4] One session TZ per tenant DB. resolveWarehouseTz() sets ONE `SET timezone`
-- for the whole pool (it picks the lowest client_id, see Phase 2.6). If a single tenant DB
-- hosts >1 client with DIFFERENT 'System Time Zone' values, every other client silently gets
-- the wrong current_date in views — an invisible off-by-one picking-date bug.
SELECT COUNT(DISTINCT sysvalue) AS distinct_tz
FROM los_sysprop WHERE syskey = 'System Time Zone' AND workstation = 'DEFAULT';
-- MUST be <= 1. If > 1, STOP: per-DB session-TZ is architecturally insufficient for this DB.

-- [Gaps G3] V2.1.13 seeds WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED by copying the
-- WEBSERVICE_ORDER_BATCH_CANCELLED sibling row; it silently seeds NOTHING if that row is absent.
SELECT COUNT(*) AS cancelled_sysprop FROM los_sysprop WHERE syskey = 'WEBSERVICE_ORDER_BATCH_CANCELLED';
-- MUST be >= 1. If 0 (v1 client predating the cancellation feature), V2.1.13 is a no-op —
-- seed WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED manually for this client before go-live.
```

**Non-Flyway per-client pre-flight (run once, before the script loop):**

```bash
# Pre-flight 1: Fix stuck transfer orders (idempotent UPDATE — wms2 V2.1.01 won't re-run this)
PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <client_db> \
  -c "UPDATE customerorder SET state=505, modified=now() WHERE state=510 AND transferlane_id IS NULL;"

# Pre-flight 2: Substitute the OMS host placeholder in V2.1.02 and V2.1.13 for THIS client.
#   Both files ship with the placeholder host 'oms-XXXXX.siteboss.net'. Replace it with
#   the client's real OMS host before applying (or edit the two files in place).
#   e.g. for client 'wineco':
#   sed -i "s/oms-XXXXX\.siteboss\.net/oms-wineco.siteboss.net/g" \
#     v2/wms2-api/src/main/resources/db/migration/V2.1.02__*.sql \
#     v2/wms2-api/src/main/resources/db/migration/V2.1.13__*.sql
```

**Apply the V2.1.x scripts in order** (the v2-specific sequence is contiguous V2.1.01–V2.1.15):

```bash
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
              V2.1.13__add_reversal_completed_sysprop.sql \
              V2.1.14__add_outbox_aggregate_order_index.sql \
              V2.1.15__add_api_timestamp_format_sysprop.sql; do
  echo "Applying $script..."
  # Fail loudly on a missing file — psql's ON_ERROR_STOP only catches SQL errors, not a bad path,
  # and a bare `for` loop does not check psql's exit code. Both guards abort the whole sequence.
  [ -f "v2/wms2-api/src/main/resources/db/migration/$script" ] \
    || { echo "ABORT: $script not found on disk (copy-verify against 'ls db/migration/')"; exit 1; }
  PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <client_db> \
    -f v2/wms2-api/src/main/resources/db/migration/$script \
    || { echo "ABORT: $script failed — DB left partially onboarded; do not start the app"; exit 1; }
done
```

> ✅ **Pre-checked (2026-05-31):** the V2.1.01–V2.1.13 filenames in the loop above match the files on disk, and `V2.1.12` parses cleanly under `psql -f`. (The historical "stray `/`" concern is RESOLVED — see Gaps G1; the on-disk file has no stray `/`.)
> ➕ **Updated (2026-06-03):** `V2.1.14__add_outbox_aggregate_order_index.sql` shipped after this plan's last revision (watermark was V2.1.13). It is now included in the loop above so v1-client onboarding lands the full V2.1.x set. It is an additive `CREATE INDEX` on `outbox_message` (idempotent; safe on a v1 DB where the table is created by V2.1.11).
> ➕ **Updated (2026-06-07):** `V2.1.15__add_api_timestamp_format_sysprop.sql` added (Phase 2.9 — seeds the `API_TIMESTAMP_FORMAT` wire-format flag at default `LEGACY`). Now included in the loop above. Idempotent sysprop seed (`id = MAX(id)+1`, composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`); safe on both v1-onboarding and established v2 DBs. The §Context "latest migration watermark" note (and §Phase 5 watermark) have been bumped to **V2.1.15** to match. **Not yet applied to any tenant DB** — applied per the §0.5 psql runbook in the same window as the rest of the V2.1.x set.

**What each script does (and why it's safe on a v1 DB):**
- **V2.1.01:** Adds a UNIQUE constraint on `unitload.labelid`. v1 had **0 duplicate labelids** (validated) → constraint creation succeeds.
- **V2.1.02:** Seeds the OMS endpoint sysprops `WEBSERVICE_ORDER_BATCH_PALLETIZED` @144 and `..._LOADED_TO_TRUCK` @145. ids 144/145 are **FREE** on v1 and those syskeys are absent → clean insert; idempotent via `ON CONFLICT (client_id,syskey,workstation) DO NOTHING` (G2 resolved). **Per-client:** substitute the OMS host (`oms-XXXXX.siteboss.net`) first (pre-flight 2 above).
- **V2.1.03:** `CREATE OR REPLACE` of `order_monitor_view` — recreates the view; safe re-run.
- **V2.1.04 / V2.1.05 / V2.1.06:** Performance indexes (idempotent via `CREATE INDEX IF NOT EXISTS`).
- **V2.1.07:** `CREATE OR REPLACE FUNCTION` for `transaction_detail` (excludes zero-amount PICKING rows, `AND sr.amount != 0`). Identical to v1's existing definition → effectively a no-op on v1.
- **V2.1.08:** Re-id'd stale-club sysprops at ids **140/141/142** with composite `ON CONFLICT … DO NOTHING`. v1 already has those exact tuples → **NO-OP** (validated). No v1-compat variant needed.
- **V2.1.09:** Inserts `PICK_PATH_DIRECTION` @143 with composite `ON CONFLICT … DO NOTHING`. v1 already has this at 143 → **NO-OP**.
- **V2.1.10 / V2.1.11:** `CREATE` `rest_idempotency` and `outbox_message` tables (absent on v1 → created).
- **V2.1.12 (SBDEV-1921):** Seeds the `MOBILE_UI_VIEW_CANCELLATION` function, creates `customerorder_cancellation_log` (TIMESTAMPTZ columns; `reversal_initiated_by` / `reversal_completed_by` as `VARCHAR(255)` for Keycloak UUIDs — no separate ALTER), and grants the function to `outbound-manager`, `outbound-worker`, `super-admin` (function seeded before the grant; idempotent via `ON CONFLICT DO NOTHING`).
- **V2.1.13 (SBDEV-1921):** Seeds `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` by copying structural columns from the existing `WEBSERVICE_ORDER_BATCH_CANCELLED` row (present on v1 → works). **Per-client:** substitute the OMS host first. See **Gaps G3**.
- **V2.1.14:** Additive `CREATE INDEX` on `outbox_message` (aggregate-order index). Idempotent (`CREATE INDEX IF NOT EXISTS`); safe on a v1 DB where the table was created by V2.1.11.
- **V2.1.15 (Phase 2.9):** Seeds `API_TIMESTAMP_FORMAT` @ `MAX(id)+1` with value **`LEGACY`** (workstation `DEFAULT`, client_id 0 — matches the resolver's `… AND workstation = 'DEFAULT' ORDER BY client_id LIMIT 1` read). Idempotent via composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. Behaviourally a no-op at install time (resolver already fails safe to LEGACY when absent) — present only so the eventual cutover is a one-line `UPDATE … SET sysvalue = 'ISO8601_UTC'`, run **later, per tenant, after both frontends ship** (Phase 4). Safe on v1-onboarding and established v2 DBs alike.

> **Sequence note:** the v2-specific migrations run contiguously V2.1.01–V2.1.15 with no gaps. The cancellation feature (V2.1.12, V2.1.13) was consolidated from several earlier per-step migrations during development. The historical `V1.1.18` "reserved slot" never shipped a file.

#### §0.6 Gaps / Open Items for Review `[2026-05-30]`

These items surfaced during the live `wms1-wineco-dev` validation. **G1, G2, and G5 are now fixed**; **G3–G4 remain** for review before the sequence is run against other clients:

- **G1 — RESOLVED:** `V2.1.12__add_cancellation_reversal_log_and_grant.sql` parses cleanly under `psql -f`. Verified 2026-05-31 against the on-disk file: 63 lines, no stray `/`; line 37 is a `CREATE INDEX` and the table's closing `);` (line 35) is not followed by a `/`. No action needed.
- **G2 — RESOLVED (2026-05-30):** `V2.1.02` now guards both inserts with `ON CONFLICT (client_id, syskey, workstation) DO NOTHING` (ids stay 144/145, just above the 140-143 block V2.1.08/V2.1.09 use). Idempotent and a clean no-op when the syskey already exists — validated by a double-apply against `wms1-wineco-dev`. (A dynamic `MAX(id)+1` / `NOT EXISTS` id was rejected: on a fresh v2 DB it would grab 140/141 right after the baseline and collide with V2.1.08's hardcoded range.)
- **G3:** `V2.1.13` **silently seeds nothing** if `WEBSERVICE_ORDER_BATCH_CANCELLED` is absent (it copies that sibling row). Present on wineco; **verify per client.**
- **G4:** OMS host substitution **moved** from the old onboarding scripts to `V2.1.02` + `V2.1.13` — the per-client URL step must now target those two files (placeholder host `oms-XXXXX.siteboss.net`).
- **G5 — RESOLVED (2026-06-03):** Both sibling docs reconciled. `260527-wms-v1-v2-db-migration-script-comparison.md` is purely the V2.1.x bridge comparison (no UTC `V1.2.x` content) and already marks the deleted v1-onboarding files as DELETED — no change needed. `260526-utc-migration-code-changes-reference.md` was updated to the new 5-file UTC layout (V1.2.01 drops views, V1.2.04 recreates views, V1.2.05 functions, `V1.2.99` in `db/rollback/`, NY variants in `db/onboarding-tz-variants/`) and Phase 1 marked implemented (`2011651`). The hydra runbook `260527-hydra-v1-to-v2-migration-runbook.md` was likewise reconciled (B1 resolved, Phase F 01→05, view-recreation verify, rb()/tzv() path helpers).

#### Step 3.5 — Explicitly Confirm `customerorder_old` Exclusion `[Review fix — CRITICAL-3 Critic]`

Before running V1.2.01, confirm this table is excluded from the migration and document the decision:

```sql
-- Confirm customerorder_old columns (will NOT be converted — intentional)
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'customerorder_old'
ORDER BY ordinal_position;
-- timestamp without time zone columns here are ACCEPTED residual risk:
-- zero wms2-api references confirmed; archived data only; not touched by V1.2.01–V1.2.05
```

If any application code in this v1 client's deployment still references `customerorder_old`, **escalate before proceeding** — this plan assumes the table is archive-only.

#### Step 4 — Create Parameterized Migration Scripts for This Client

V1.2.01 and V1.2.02 in the plan hardcode `'America/Los_Angeles'`. For NY clients, create modified copies:

```bash
# For NY clients only — create client-specific copies with the correct AT TIME ZONE clause
CLIENT_HIBERNATE_TZ="America/New_York"   # from Step 1
sed "s/AT TIME ZONE 'America\/Los_Angeles'/AT TIME ZONE '${CLIENT_HIBERNATE_TZ}'/g" \
  V1.2.01__utc_standard_tables.sql > V1.2.01__utc_standard_tables_${CLIENT_HIBERNATE_TZ//\//_}.sql
sed "s/AT TIME ZONE 'America\/Los_Angeles'/AT TIME ZONE '${CLIENT_HIBERNATE_TZ}'/g" \
  V1.2.02__utc_large_tables.sql > V1.2.02__utc_large_tables_${CLIENT_HIBERNATE_TZ//\//_}.sql
# Use these client-specific files in the §0.5 psql runbook instead of the originals
```

> **LA clients and existing wms2 data**: use the original V1.2.01/V1.2.02 as-is (`AT TIME ZONE 'America/Los_Angeles'`).
> **NY clients**: use the parameterized copies with `AT TIME ZONE 'America/New_York'`.

> **NY-parameterized rollback** `[Review fix — Ambiguity]` `[2026-06-03: already generated]`: the LA original `db/rollback/V1.2.99__rollback_utc_migration.sql` uses `AT TIME ZONE 'America/Los_Angeles'` for PART 1/PART 2 (Group A); the **NY copy already exists** at `db/onboarding-tz-variants/V1.2.99__rollback_utc_migration_America_New_York.sql` (PART 1/2 = `'America/New_York'`, PART 3 stays UTC; round-trip-validated on PostgreSQL 16). Use it if abort criteria are triggered for a NY client (e.g. `wms2-hydra-uat`). To regenerate after the LA original changes:
> ```bash
> sed "s#America/Los_Angeles#America/New_York#g" \
>   db/rollback/V1.2.99__rollback_utc_migration.sql \
>   > db/onboarding-tz-variants/V1.2.99__rollback_utc_migration_America_New_York.sql
> ```

#### Step 5 — Set Up Landlord DB Entry

wms2 routes connections via the landlord DB. Create the `tenant_db_configuration` entry if it doesn't exist, and ensure `tenant_discovery` has the correct timezone for the frontend:

```sql
-- On the landlord DB (not the tenant DB):

-- 1. Verify tenant_db_configuration entry exists for this client
--    NOTE: tenant_db_configuration.tenant is a @ManyToOne FK to the tenant table (integer PK),
--    NOT a direct varchar column. A JOIN is required: [Review fix — MEDIUM-5]
SELECT tdc.*
FROM tenant_db_configuration tdc
JOIN tenant t ON t.id = tdc.tenant_id
WHERE t.tenant_name = '<tenant_name>'
  AND tdc.warehouse = '<facility_code>';

-- 2. Verify (or create) tenant_discovery entry with timezone
SELECT timezone FROM tenant_discovery WHERE key = '<warehouse>-<clientName>';
-- If missing or wrong:
UPDATE tenant_discovery SET timezone = '<CLIENT_IANA_TZ>' WHERE key = '<warehouse>-<clientName>';
-- e.g. 'America/Los_Angeles' or 'America/New_York'
-- This is what the frontend reads via GET /api/public/authConfig to display local times
```

#### Step 6 — Proceed with §0.5 Runbook

After Steps 1–5 are complete, follow the §0.5 psql runbook using:
- The parameterized V1.2.01/V1.2.02 from Step 4 (or originals for LA clients)
- V1.2.03, V1.2.04 and V1.2.05 as-is (timezone-agnostic — handle both LA and NY via IF EXISTS / UTC groups / verbatim DDL)

**V1.2.05 partial-failure note** `[Round 5 fix — critic DBA-MINOR]` `[Review fix — MAJOR-6]` `[2026-06-03: functions moved 04→05]`:
If V1.2.05 (stored function signatures) fails while V1.2.01–V1.2.04 succeeded, the DB
columns are already `timestamptz` but the functions still accept `timestamp without time
zone`. PostgreSQL will implicitly cast, producing wrong-timezone results. **Do NOT start
the application until V1.2.05 is successfully applied or functions are manually recreated.**

**Forward-recovery when V1.2.05 fails:** Re-run V1.2.05 after fixing the root cause (the
functions use `CREATE OR REPLACE FUNCTION` — safe to re-run). If the script file itself is
corrupt, manually recreate using the inline recovery procedure:

```sql
-- Forward-recovery: manually recreate all 3 functions with timestamptz signatures
-- Copy function bodies from source files and replace timestamp without time zone → timestamptz:

-- 1. Get stock_history body from V1.0.03__wms_functions.sql lines 13–86
-- 2. Get transaction_detail body from V2.1.07__update_transaction_detail_pick_amount_filter.sql
-- 3. Get transaction_summary body from V1.0.03__wms_functions.sql lines 449–end

-- Drop order (dependents first):
DROP FUNCTION IF EXISTS transaction_detail(varchar, varchar, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS transaction_summary(varchar, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS stock_history(timestamptz);

-- Recreate order (stock_history first — called by the other two):
-- CREATE OR REPLACE FUNCTION stock_history(as_of_date timestamptz) ...
-- CREATE OR REPLACE FUNCTION transaction_detail(client_number_in varchar, sku_in varchar,
--     startdate_in timestamptz, enddate_in timestamptz) ...
-- CREATE OR REPLACE FUNCTION transaction_summary(client_number_in varchar,
--     startdate_in timestamptz, enddate_in timestamptz) ...
-- [Copy bodies from V1.0.03__wms_functions.sql + V2.1.07, replace all
--  'timestamp without time zone' → 'timestamptz' in parameter and return signatures]
```

Verify after recovery:
```sql
SELECT routine_name, parameter_name, data_type
FROM information_schema.parameters
WHERE specific_schema = 'public'
  AND routine_name IN ('stock_history', 'transaction_detail', 'transaction_summary')
ORDER BY routine_name, ordinal_position;
-- All data_type rows must show 'timestamp with time zone'
```

**Rollback (if abort criteria triggered):**
```bash
PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <tenant_db> \
  -c "SET statement_timeout = 0; SET lock_timeout = 0;" \
  -f V1.2.99__rollback_utc_migration.sql
```
Run per tenant in reverse order of the forward migration. See §0.2 for the full rollback script.

---

## Phase 1: Stabilize Current Behavior (Safety Net)

**Purpose:** Make all implicit timezone assumptions explicit BEFORE changing anything. This is a separate deployment that preserves current behavior but makes it deterministic.

### 1.1 Pin JVM Timezone Explicitly `[Round 2 fix — C3]`

**File:** `src/main/java/net/aim_ai/wms/StartApplication.java`

`[Round 2 fix]` **Do NOT use `@PostConstruct`.** Spring Boot initializes `DataSource` beans (including `TenantDynamicRoutingDataSource` and all `HikariDataSource` instances) before `@PostConstruct` on `@SpringBootApplication` fires. Any `LocalDateTime.now()` during bean initialization or Flyway migration callbacks would use the wrong timezone. Use `main()` instead:

```java
public static void main(String[] args) {
    // Phase 1: pin JVM to LA BEFORE Spring initializes DataSources and Hibernate
    // Phase 2: change to "UTC"
    TimeZone.setDefault(TimeZone.getTimeZone("America/Los_Angeles"));
    System.setProperty("user.timezone", "America/Los_Angeles");
    SpringApplication.run(StartApplication.class, args);
}
```

**Preferred alternative:** Set `TZ=America/Los_Angeles` (Phase 1) / `TZ=UTC` (Phase 2) as a container environment variable. This is the most reliable approach as it takes effect before the JVM starts entirely, including any static initializers.

This ensures `LocalDate.now()`, `LocalDateTime.now()`, `new Date()`, `Calendar.getInstance()` all use LA time regardless of the host OS.

### 1.2 Fix CronTrigger Timezone

**File:** `src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java`

All **6** `CronTrigger` instances need explicit timezone `[v2: 6 instances, not 5]`:

| Approx line | Method |
|-------------|--------|
| 174 | `configureOrderRelease` |
| 197 | `configureReplenishOrder` |
| 220 | `configureStockSummaryExport` (or similar) |
| 243 | `configureCleanUpOldMessage` (or similar) |
| 260 | `configureReleaseExpiredPickingOrdersFromUser` |
| 281 | `configureStaleClubBatchCleanup` ← **new, not in original plan** |

```java
new CronTrigger(cronjob, TimeZone.getTimeZone("America/Los_Angeles"))
```

`[Round 11 fix]` **CronTrigger TZ vs per-tenant business-date TZ are independent concerns.** The `CronTrigger` timezone determines WHEN the job fires (server-level schedule), not what "today" means for any individual tenant. Even with LA-pinned cron, a NY warehouse's order release correctly uses NY's "today" because `OrderReleaseJob` iterates tenants and each tenant's business-date logic reads from its own `System Time Zone` sysprop via `TimezoneService`. The LA cron pin is appropriate for Phase 1 (all current tenants run on a historically LA-configured server); Phase 2 moves cron to UTC (a neutral choice for multi-timezone tenants). `[Architect M4]` **Scope boundary:** this pin is correct for all *current* jobs because their correctness depends on per-tenant business-date logic (each tenant's sysprop), not on the cron's firing wall-clock. Any *future* job whose *effect* must occur at a tenant's local midnight (rather than just comparing dates) would be off by the tenant's UTC offset and must revisit this — it would need per-tenant scheduling, not a single server-level `CronTrigger` TZ.

### 1.3 Fix SimpleDateFormat Usage

`[v2 correction: no static/singleton SimpleDateFormat on singleton beans in wms2. The v1 items (AdviceController.java:38, CustomerOrderBatchController.java:26) do NOT apply here.]`

**Actual wms2 instances to review:**

- `OrderReleaseJob.java:131` -- `new SimpleDateFormat(WmsConstants.DATE_PATTERN)` created per-call inside the method. **OK — not thread-unsafe.** The existing code already reads `System Time Zone` from the sysprop and sets it on the `SimpleDateFormat` — **do NOT hardcode `America/Los_Angeles` here.** With LA and NY tenants, each tenant's job iteration must use that tenant's sysprop. The current sysprop-reading pattern is already correct and must be preserved. `[Round 11 fix]`
- `TransactionReportRestController.java:99,105,108,213,219,222` -- all `new SimpleDateFormat(...)` per-call. **OK — not thread-unsafe.** Same timezone pinning recommended.

### 1.4 YYYY Week-Year Bug — ALREADY FIXED IN wms2

`[v2: FileExportService.java:33 already uses DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS"). WmsConstants.java:1089 has SYSTEM_PROPERTY_EXPORT_DATE_FORMAT_DEFAULT_VALUE = "yyyy-MM-dd HH:mm:ss.SSS". No action needed.]`

The `YYYY` occurrences in `PickingorderRepository.java:123`, `ClientRepository.java:54-65`, and `OutboxMessageRepository.java:55` are PostgreSQL native SQL format strings — correct PostgreSQL behavior, do NOT change.

### 1.5 Fix WebConfigurer Timezone Conflict

**File:** `src/main/java/net/aim_ai/wms/WebConfigurer.java:70`

Change `builder.timeZone(TimeZone.getDefault())` to `builder.timeZone(TimeZone.getTimeZone("America/Los_Angeles"))` to match the application.properties config explicitly.

### 1.6 Fix Entity Field Default

**File:** `src/main/java/net/aim_ai/wms/model/Billoflading.java:21`

Current: `private LocalDate shipped = LocalDate.now();`

This uses JVM default timezone. After Phase 1 JVM is pinned to LA, so this is safe. But note it for Phase 2 where it needs warehouse timezone.

### 1.7 Verify & Deploy Phase 1

- Run existing tests: `mvn test`
- Verify no behavioral change (this phase is behavior-preserving)
- Deploy to staging, smoke test scheduled jobs and API date responses

---

## Phase 2: Application Configuration Switch to UTC

**Purpose:** Change the application to read/write UTC timestamps. Combined with the Phase 3 Flyway migration in the SAME deployment so Flyway converts data before the app starts serving requests.

### 2.1 Update Application Properties `[Round 2 fix — M7]` `[Round 4 fix — FIX R4-C3]` `[Round 7 fix]`

**File:** `src/main/resources/application.properties`

`[Round 7 fix]` **Explicitly DELETE the following 3 lines** (verified at lines 105, 107, 108 in the current file). Then add the UTC replacements shown below. After this change, no local-timezone setting remains in `application.properties` and all wms2-api instances operate in UTC.

```diff
-#user.timezone=America/New_York
-spring.jackson.time-zone=America/Los_Angeles
-spring.jpa.properties.hibernate.jdbc.time_zone=America/Los_Angeles
+spring.jackson.time-zone=UTC
+spring.jpa.properties.hibernate.jdbc.time_zone=UTC
+spring.jpa.properties.hibernate.type.preferred_instant_jdbc_type=TIMESTAMP_WITH_TIMEZONE
 spring.jackson.deserialization.adjust-dates-to-context-time-zone=true  ← keep as-is
```

**Why each line:**
- `#user.timezone=America/New_York` — dead commented-out config, deleted permanently (JVM timezone is now set in `main()` / `TZ=` env var per Phase 2.2; this line had no effect)
- `spring.jackson.time-zone=America/Los_Angeles` → `UTC` — Jackson serializes all `LocalDateTime` and `ZonedDateTime` values in UTC; frontend converts for display
- `spring.jpa.properties.hibernate.jdbc.time_zone=America/Los_Angeles` → `UTC` — Hibernate writes `LocalDateTime` fields as UTC wall-clock into `timestamptz` columns (after Phase 3 schema migration); without this, Hibernate would write UTC epoch but the column would store it with a -08:00 offset shift
- `preferred_instant_jdbc_type=TIMESTAMP_WITH_TIMEZONE` — makes `Instant` ↔ `timestamptz` mapping explicit; defensive against Hibernate version drift (added Round 2)

**Result:** All instances share these UTC settings uniformly. The per-tenant display timezone is handled separately by `TimezoneService` + `connectionInitSql` session GUC (Phase 2.4–2.6), not by any `application.properties` entry.

### 2.2 Switch JVM Timezone to UTC `[Round 2 fix — C3]`

**File:** `src/main/java/net/aim_ai/wms/StartApplication.java`

Change the `main()` from Phase 1:
```java
public static void main(String[] args) {
    // Phase 2: switch JVM to UTC
    TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
    System.setProperty("user.timezone", "UTC");
    SpringApplication.run(StartApplication.class, args);
}
```

Or set `TZ=UTC` as a container environment variable (preferred — takes effect before JVM starts).

### 2.3 Update WebConfigurer Jackson Configuration

**File:** `src/main/java/net/aim_ai/wms/WebConfigurer.java`

- Line 70: Change to `builder.timeZone(TimeZone.getTimeZone("UTC"))`
- Verify the `StdDateFormat` and `JavaTimeModule` configuration produces ISO-8601 UTC output (`JavaTimeModule` is already registered at lines 52 and 88)
- Consider changing the `dateTimeFormat` at line 36 from `"yyyy-MM-dd HH:mm:ss"` to ISO-8601 format `"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"`, or remove the custom serializer and let Jackson's `WRITE_DATES_AS_TIMESTAMPS=false` produce standard ISO-8601

### 2.4 Create Warehouse Timezone Utility `[Round 2 fix — M3]` `[Round 3 fix — FIX 4]`

`[Round 3 fix — FIX 4]` The `TimezoneService` below fixes the cache lambda bug from the Round 2 draft where the `computeIfAbsent` lambda ignored the `fc` key and routed all lookups via `TenantContext`. If called from a scheduled job with `facilityCode` set but `TenantContext` pointing to a different tenant, the wrong timezone would be cached. The corrected design documents that the **caller must set TenantContext** before the first DB lookup per `facilityCode`.

`[Round 3 fix — FIX 4]` `[Round 10 fix]` The `TimezoneService` reads its IANA timezone string from the `los_sysprop` `"System Time Zone"` key via `syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WAREHOUSE_TIME_ZONE_KEY)`. The `parseToZoneId()` helper remains because sysprop values can carry formatting quirks (e.g. `"America / Los_Angeles"`, optional offset suffix).

<!-- [Round 4 fix — FIX R4-M1] -->
**Cache key must be composite (tenant+facility), not facilityCode alone** `[Round 4 fix — FIX R4-M1]`

`facilityCode` is not globally unique — two different tenants may share the same
`facilityCode`. `TenantKeyBuilder.buildKey(tenantName, facilityCode)` produces
`first4(tenantName)-facilityCode` (e.g. `"WINE-WSL"`), which is globally unique.
Both overloads require `TenantContext` to be set by the caller → the composite key
can always be derived from TenantContext.

```java
@Component
public class TimezoneService {
    private static final Logger LOG = LoggerFactory.getLogger(TimezoneService.class);
    private final SyspropService syspropService;
    private final ConcurrentHashMap<String, ZoneId> cache = new ConcurrentHashMap<>();

    public ZoneId getWarehouseZoneId() {
        TenantProfile p = TenantContext.getCurrentTenant();
        if (p == null || p.getFacilityCode() == null) throw new IllegalStateException(
            "TimezoneService.getWarehouseZoneId() called without TenantContext. " +
            "Use getWarehouseZoneId(facilityCode) from scheduled/async threads.");
        return getByTenantKey(TenantKeyBuilder.buildKey(p));
    }

    public ZoneId getWarehouseZoneId(String facilityCode) {
        TenantProfile p = TenantContext.getCurrentTenant();
        if (p == null) throw new IllegalStateException(
            "TimezoneService.getWarehouseZoneId(facilityCode) requires TenantContext " +
            "to be set by caller before invocation.");
        return getByTenantKey(TenantKeyBuilder.buildKey(p.getTenantName(), facilityCode));
    }

    private ZoneId getByTenantKey(String tenantKey) {
        return cache.computeIfAbsent(tenantKey, k -> {
            // [Round 10 fix] Read 'System Time Zone' from los_sysprop via SyspropService.
            // TenantContext routes the sysprop query to the correct tenant DB.
            String raw = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WAREHOUSE_TIME_ZONE_KEY);
            return parseToZoneId(raw);
        });
    }

    public LocalDate todayInWarehouse() { return LocalDate.now(getWarehouseZoneId()); }
    public LocalDate todayInWarehouse(String facilityCode) { return LocalDate.now(getWarehouseZoneId(facilityCode)); }

    /** [Round 5 fix — FIX R5-m1] Explicit cache eviction for runtime timezone changes.
     *  Called from admin endpoint or app restart. tenantKey format: TenantKeyBuilder.buildKey(tenantName, facilityCode). */
    public void invalidateCache(String tenantKey) { cache.remove(tenantKey); }
    public void invalidateCacheAll() { cache.clear(); }

    private ZoneId parseToZoneId(String syspropValue) {
        try {
            if (syspropValue == null || syspropValue.isBlank()) return ZoneId.of("UTC");
            String stripped = syspropValue.replaceAll("\\s*\\(.*\\)\\s*$", "").trim();
            String iana = stripped.replace(" / ", "/").replace(" ", "_");
            return ZoneId.of(iana);
        } catch (Exception e) {
            LOG.warn("Invalid System Time Zone sysprop '{}'; defaulting to UTC: {}", syspropValue, e.getMessage());
            return ZoneId.of("UTC");
        }
    }
}
```

**Note on cache invalidation**: `TimezoneService.invalidateCache(tenantKey)` or full `cache.clear()` must be called if a tenant's `System Time Zone` sysprop changes at runtime (rare; operationally triggered via Actuator endpoint or app restart). `[Round 10 fix]`

> **⚠️ `[Architect H1]` Two lifetimes — cache vs connection pool (do NOT conflate):** `invalidateCache()` refreshes only the `TimezoneService` **business-date** layer. The **SQL-session** layer (`SET timezone` in `connectionInitSql`) is frozen into each `HikariDataSource` at `createHikariPool()` time (Phase 2.6) and is NOT re-evaluated by a cache flush — live pooled connections keep the old session TZ for the life of the pool. So after a `System Time Zone` change, `current_date` in views/native queries can diverge from `TimezoneService.todayInWarehouse()` until the tenant's **pool is evicted/recreated**. Unless `TenantDynamicRoutingDataSource` exposes a per-tenant pool-eviction hook, a **full app restart is the only correct procedure** for a TZ change. Document restart (not cache-flush) as the runbook step for any sysprop TZ change.

> **⚠️ Related issue — `SyspropService` cache key is `facilityCode:key` only** `[Review fix — MINOR-4]` `[2026-06-03 audit: applies to TWO methods]`: `SyspropService.java:95` AND `:288` are both annotated `@Cacheable(value = "sysprops", key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #key")`. This caches sysprop values keyed by `facilityCode` alone — NOT the composite `tenantName-facilityCode` key. (The plan previously cited only line 288; the fix must cover both call sites.) If two different tenants share the same `facilityCode` (not uncommon in multi-tenant setups), `SyspropService` may return the wrong tenant's `System Time Zone` value. `TimezoneService` uses the composite key for its own cache, but the underlying sysprop read via `SyspropService.getSysvalue()` is still facilityCode-scoped. **Action required (Phase 5 or separate ticket):** fix `SyspropService` cache key to include tenant name. Until fixed, verify no two active tenants share the same `facilityCode` string — this is the assumption the current implementation relies on.

**Unit test matrix required** (see §Verification):
| Input | Expected output |
|-------|----------------|
| `"America / Los_Angeles"` | `ZoneId.of("America/Los_Angeles")` |
| `"America/Los_Angeles"` | `ZoneId.of("America/Los_Angeles")` |
| `"America / New_York (-05:00)"` | `ZoneId.of("America/New_York")` |
| `null` | `ZoneId.of("UTC")` + WARN log |
| `""` | `ZoneId.of("UTC")` + WARN log |
| `"INVALID"` | `ZoneId.of("UTC")` + WARN log |

`[Round 3 fix — FIX 9]` `[Round 10 fix]` **Cache invalidation:** If a tenant's `System Time Zone` sysprop changes, the app must be restarted OR an admin endpoint `POST /admin/cache/timezone/evict?facility={fc}` must be invoked. Short-term: document restart as the procedure. Long-term: replace `ConcurrentHashMap` with a Caffeine cache (already used in wms2-api per CLAUDE.md) with a 24-hour TTL. This allows timezone changes to propagate within one day without requiring a full restart. Document in the runbook.

**Note on sysprop value:** The wms2-wineco-dev DB value is `'America / Los_Angeles'` (no offset suffix). The original plan's example `'America / New_York (-05:00)'` reflects the v1 seed data format. Both formats are handled by the `parseToZoneId()` method above.

### 2.5 Fix Business Logic That Needs Warehouse Timezone `[Round 2 fix — C4]`

After switching to UTC, any logic that needs "today in the warehouse timezone" must explicitly use the `TimezoneService`.

**Must be updated to use warehouse timezone:**

| File | Line | Current Code | Fix |
|------|------|-------------|-----|
| `service/job/ReleaseOrderJobService.java` | **121** | `order.getPickingdate().isAfter(LocalDate.now())` | Use `timezoneService.todayInWarehouse()` — see §Picking Date / Order Release analysis below `[v2: was listed as line 110]` |
| `service/CustomerorderService.java` | **248** | `LocalDate today = LocalDate.now()` | Use `timezoneService.todayInWarehouse()` — see §Picking Date / Order Release analysis below `[v2: was listed as line 221]` |
| `service/BillofladingService.java` | **655** | `billOfLading.setShipped(LocalDate.now())` | Use `timezoneService.todayInWarehouse()` `[v2: was listed as line 644]` |
| `model/Billoflading.java` | 21 | `private LocalDate shipped = LocalDate.now()` | Remove default; set explicitly in service code using warehouse TZ |
| `schedulejob/ReplenishOrderJob.java` | **371, 405** | `new Date()` for picking date filter | **No code change required.** Both calls pass `java.util.Date` (UTC instant) to native queries with `AND o.pickingDate <= :pickingDate` against a `date` column. PostgreSQL promotes `date` to `timestamp with time zone` at midnight in the **session timezone** (= warehouse TZ, set by Phase 2.6). The UTC instant and the session-TZ midnight cast resolve correctly — tomorrow's orders are excluded even at LA 4 PM. See Scenario D analysis below. `[Round 9 fix — formerly vague "Use warehouse timezone"; reclassified after session-TZ JDBC analysis]` `[v2: was listed as lines 255, 293]` |
| `service/OrderBatchCreationService.java` | **158** | `if (pickingDate.isAfter(LocalDate.now()))` | `timezoneService.todayInWarehouse()` *(no-arg — this method is request-scoped, TenantContext is set)* `[Round 2 fix — C4]` `[Round 3 fix — FIX 6]` |
| `service/OrderBatchCreationService.java` | **166** | `customerOrder.setPickingdate(LocalDate.now())` | `timezoneService.todayInWarehouse()` *(no-arg — this method is request-scoped, TenantContext is set)* `[Round 2 fix — C4]` `[Round 3 fix — FIX 6]` |
| `service/CleanUpOldMessageJobService.java` | **78** | `cal.setTime(new Date())` | Use explicit `Instant.now()` / UTC — OK at UTC, but document boundary awareness `[Round 2 fix — C4]` |
| `service/GoodsreceiptService.java` (or caller) | **N/A — RESOLVED** | No `setReceiptdate(LocalDateTime.now())` call site exists | **Audit complete `[2026-06-03]`:** `grep -rn "setReceiptdate" v2/wms2-api/src/main/java/` returns **only the entity setter** `Goodsreceipt.java:84` — there is no service-layer caller that stamps `receiptdate = LocalDateTime.now()`. `receiptdate` is populated from inbound data (advice/receipt payloads), not server clock, so the UTC switch does not introduce a warehouse-local off-by-one here. **No code change required.** If a future call site introduces `setReceiptdate(LocalDateTime.now())`, route it through `LocalDateTime.now(timezoneService.getWarehouseZoneId())`. (Was `[Review fix — HIGH-7]`.) |
| `schedulejob/StockSummaryExportJob.java` | **154** | `LocalDateTime.now()` | Use `timezoneService.todayInWarehouse(facilityCode)` if filename is human-facing; UTC is OK for machine use `[Round 2 fix — C4]` |
| `repo/jpa/ClientRepository.java` | **54-65** | `::timestamp without time zone` cast in native queries | Change cast to `::timestamptz` after Phase 3.2 changes function signatures `[Round 2 fix — C4, M5]` |

`[Round 3 fix — FIX 6]` **`OrderBatchCreationService` context note:** This service is invoked from REST controllers (request-scoped). `TenantContext` is already set. Use the no-arg `timezoneService.todayInWarehouse()` overload — do NOT pass `facilityCode` explicitly from this class.

<!-- [Round 4 fix — FIX R4-m4] -->
**Caller chain** `[Round 4 fix — FIX R4-m4]`: `TenantFilter.java:47` sets `TenantContext` from
`tenant_name` + `facility_code` headers → `OrderRestController.java` → `OrderBatchCreationService`.
No `@Async` boundary; no `@Scheduled` invocation path found. Safe to use no-arg
`timezoneService.todayInWarehouse()` here; the overload throws `IllegalStateException` if
`TenantContext` is ever absent (fail-fast, not silent).

`[Round 2 fix — C4]` `[Round 9 fix — MAJOR-6 resolved]` **Additional note:** `OrderReleaseJob.java:131` uses `SimpleDateFormat` with the warehouse TZ read from the `System Time Zone` sysprop. **Phase 1** (line in fix table) pins it explicitly to `America/Los_Angeles` as a stabilization step — this keeps working under UTC because the sysprop string is passed directly as a `TimeZone` argument, not derived from `LocalDate.now()`. No Phase 2 action required here. Conversion to `TimezoneService.getWarehouseZoneId()` is a **Phase 5 cleanup item** (see §5.4) — explicitly deferred, not a Phase 2 dependency. Three sections previously gave conflicting signals; this note is the canonical resolution: Phase 1 stabilizes, Phase 5 refactors.

`[v2 correction]` `OrderRestController.java:421,429` does NOT contain `LocalDate.now()` in wms2. The picking date logic for order release lives in `ReleaseOrderJobService.java:121`. Remove the `OrderRestController` rows from the fix table.

**Scheduled job callers** `[Round 8 fix — CRITICAL-1]`: `OrderReleaseJob`, `ReplenishOrderJob`, and similar jobs all follow the same pattern — they call `TenantContext.setCurrentTenant(tenantProfile)` BEFORE entering business logic (confirmed: `OrderReleaseJob.java:94`, `ReplenishOrderJob.java:127`). TenantContext IS set, so the **no-arg `timezoneService.todayInWarehouse()` overload is correct** for all service methods called from within these per-tenant loops. The `facilityCode` overload (`todayInWarehouse(facilityCode)`) is reserved for callers that need to look up a *different* facility than the one in TenantContext — no such case currently exists. Do NOT thread `facilityCode` through service method signatures unnecessarily; this produces dead-code plumbing and misleads future readers. `StockSummaryExportJob` passes `facilityCode` explicitly because it creates `LocalDate` values for filename generation outside TenantContext — that is the only confirmed exception.

**Already correct (uses sysprop or UTC is fine):**
- `OrderReleaseJob.java:131` -- reads `System Time Zone`, sets on `SimpleDateFormat`
- `ReleaseExpiredPickingOrdersFromUserJob.java` -- timeout comparison, UTC is correct
- `StockSummaryExportJob.java` -- export timestamp (machine use), UTC is correct
- `RestIdempotencyService.java:118` -- `LocalDateTime.now().minus(STALE_CLAIM_TTL)` used to identify stale in-flight rows; safe under UTC because `rest_idempotency.created_at` is written by `INSERT ... NOW()` (PostgreSQL UTC), so both sides of the comparison are UTC — no warehouse-local involvement `[Round 8 fix — MAJOR-4]`

- `MobileReplenishService.java:538, 585` -- `Date dateStart = new Date()` / `Date dateEnd = new Date()`. Pure elapsed-time markers: line 586 subtracts `dateEnd.getTime() - dateStart.getTime()` for a duration log. Neither value is compared against a warehouse-local date column. **Safe under any TZ — reclassified as already-correct.** `[Round 8 fix — MAJOR-5]` `[Round 9 fix — promoted from "needs audit" to already-correct after confirming subtraction semantics at line 586]`

#### Picking Date / Order Release — Timezone Impact Analysis `[Round 7 fix — NEW]`

**Root cause at `ReleaseOrderJobService.java:121`:**

```java
// BEFORE (broken after Phase 2 — JVM is UTC):
if (order.getPickingdate().isAfter(LocalDate.now())) { return; }

// AFTER (Phase 2.5 fix):
if (order.getPickingdate().isAfter(timezoneService.todayInWarehouse())) { return; }
```

**`OrderReleaseJob` TenantContext flow (confirmed from source):**
`OrderReleaseJob.java:94` calls `TenantContext.setCurrentTenant(tenantProfile)` before calling `releaseOrders()` → `ReleaseOrderJobService`. TenantContext IS set with both `tenantName` and `facilityCode`. The no-arg `timezoneService.todayInWarehouse()` overload is safe here — it reads TenantContext and throws `IllegalStateException` (fail-fast) if somehow absent.

**Scenario A — UTC− warehouses (current tenants): Early Release Problem `[Round 11 fix]`**

UTC date rolls to D+1 before the warehouse's local midnight. The rollover gap depends on the tenant's `System Time Zone` sysprop:
- **LA warehouses (`America/Los_Angeles`, UTC−8):** UTC midnight = 4 PM LA → 8-hour early-release window
- **NY warehouses (`America/New_York`, UTC−5):** UTC midnight = 7 PM NY → 5-hour early-release window

Without the fix (shown for LA; same pattern for NY with different times):

| LA wall-clock | UTC date | `LocalDate.now(UTC)` | `pickingdate=D+1 .isAfter(UTC today)` | Effect |
|---------------|----------|---------------------|---------------------------------------|--------|
| May 25 15:59 | May 25 | May 25 | TRUE → skip | ✅ correct — not yet |
| May 25 **16:00** | **May 26** | **May 26** | FALSE → **RELEASE** | ❌ **8 h too early** |
| May 26 00:00 | May 26 | May 26 | FALSE → RELEASE | ✅ correct |

For NY (`America/New_York`, UTC−5): the same ❌ row fires at **7 PM NY** (= UTC midnight), giving a 5-hour early-release window instead of 8 hours.

**Problem:** Orders with `pickingdate = May 26` are released before the warehouse day starts. Pickers see "tomorrow's" orders in the queue hours before the warehouse expects them.

**With the fix:** `timezoneService.todayInWarehouse()` returns the warehouse-local date from the tenant's sysprop. At LA 16:00 or NY 19:00 on May 25, the warehouse today = May 25. `May 26.isAfter(May 25)` → TRUE → correctly skipped until the warehouse's local midnight.

**Scenario B — UTC+ warehouses (future tenants): Late Release Problem**

For a UTC+12 warehouse (e.g. Auckland, NZ): UTC is 12 hours behind the warehouse clock.

| NZ wall-clock | UTC date | `LocalDate.now(UTC)` | `pickingdate=NZ_today .isAfter(UTC today)` | Effect |
|---------------|----------|---------------------|--------------------------------------------|--------|
| May 26 00:01 | May 25 | May 25 | TRUE → skip | ❌ Not released at NZ day start |
| May 26 12:00 | May 26 | May 26 | FALSE → RELEASE | ✅ but 12 h late |

**Problem:** "Web UI shows today = May 26, but the order release cron job skips orders with `pickingdate = May 26` for 12 hours because UTC hasn't reached May 26 yet." This is the exact "web shows today, cron doesn't release" scenario.

**With the fix:** `timezoneService.todayInWarehouse()` returns NZ date. At NZ midnight, NZ today = May 26. `May 26.isAfter(May 26)` → FALSE → released immediately at NZ midnight. ✅

**`CustomerorderService.java:248` state-transition bug (same root cause):**

When a user changes a picking date to "today" (warehouse local) during the UTC-rollover window (LA 4 PM–midnight), `LocalDate.now(UTC)` is already D+1 while the warehouse is still D:

```java
// User changes order pickingdate to LA today = May 25
// Time is LA 17:00 (= UTC May 26)
LocalDate today   = LocalDate.now();         // May 26 (UTC) ← wrong
LocalDate newDate = LocalDate.parse(pickingDate, DateTimeFormatter.ofPattern("yyyy-MM-dd"));
                                             // May 25 (LA today)  [Round 8 fix — MAJOR-6]

newDate.equals(today)   // May 25 == May 26 → FALSE  → state NOT reset to RAW
newDate.isAfter(today)  // May 25 >  May 26 → FALSE  → FUTURE_PICKING_DATE NOT set
// Neither branch: order stays in FUTURE_PICKING_DATE state even though pickingdate is now LA today
```

Additionally, `CustomerorderService.java:258` calls `updateOrderPositions(customerOrder, FUTURE_PICKING_DATE)` which cascades the stuck state to all order positions — they also remain in FUTURE_PICKING_DATE until the order is released by `OrderReleaseJob`. `[Round 8 fix — MAJOR-2]`

The `OrderReleaseJob` still processes the order (state < ASSIGNED, `pickingdate = May 25` not after UTC May 26). `ReleaseOrderJobService.java:214-221` and `530-537` can transition FUTURE_PICKING_DATE orders to RAW_ON_HOLD and fire `manageOrderService.customerOrderOnHold()` — but **only when `containsUnsatisfiedPosition` is also true** (i.e., there is a stock shortfall on at least one position). If stock is sufficient, the order is processed normally without firing `customerOrderOnHold`. The phantom notification therefore requires BOTH (a) the order stuck in FUTURE_PICKING_DATE due to the UTC-rollover state bug AND (b) a concurrent stock shortfall. The intersection is rare but real — and the fix at `CustomerorderService.java:248` eliminates the root cause entirely. `[Round 8 fix — HIGH]` `[Round 9 fix — narrowed from "always fires" to "fires on containsUnsatisfiedPosition"]`

**Fix:** apply `timezoneService.todayInWarehouse()` at line 248 — already in the Phase 2.5 fix table; this note explains why the state-transition case matters. With the fix, the picking-date-change-to-today code path correctly resets the state to RAW, preventing both the stuck-state window and the phantom OMS notification.

**Scenario C — BOL `shipped` date off-by-one during UTC-rollover window `[Round 8 fix — CRITICAL-2]`:**

`BillofladingService.java:655` calls `billOfLading.setShipped(LocalDate.now())` when a BOL is closed. After Phase 2 (JVM = UTC), if a warehouse user closes a BOL at 4 PM LA time (= UTC midnight D+1), `LocalDate.now(UTC)` returns D+1 — one day in the future from the warehouse's perspective. The BOL's `shipped` date is stamped as tomorrow.

| LA wall-clock | UTC date | `LocalDate.now(UTC)` | `bol.shipped` stamped | Effect |
|---------------|----------|---------------------|----------------------|--------|
| May 25 15:59 | May 25 | May 25 | May 25 | ✅ correct |
| May 25 **16:00** | **May 26** | **May 26** | **May 26** | ❌ stamped **tomorrow** |
| May 26 00:00 | May 26 | May 26 | May 26 | ✅ correct |

**Fix:** `BillofladingService.java:655` must use `timezoneService.todayInWarehouse()` (already listed in Phase 2.5 fix table). `Billoflading.java:21` entity default `private LocalDate shipped = LocalDate.now()` must also be removed (listed in fix table). The same UTC-rollover window that causes early order release (Scenario A) also stamps BOLs with tomorrow's shipped date for LA warehouses during the 4 PM–midnight window.

**Construction-site audit for `Billoflading.java:21` default removal `[Round 9 fix — MAJOR-5]` `[Review fix — CRITICAL-2 Critic]`:** Grep confirms `new Billoflading()` appears only at `BillofladingService.java:221`. That call site immediately proceeds to set all required fields including `shipped` explicitly at line 655 (`billOfLading.setShipped(LocalDate.now())` — the very line being fixed). **However, `BillofladingService.java:239` calls `billOfLading.setShipped(null)` — this was missed in the Round 9 audit.** **RESOLVED `[2026-05-31]`:** `V1.0.01__wms_tables.sql:75` declares `shipped date,` — **nullable (no NOT NULL constraint).** Removing the entity-level `LocalDate.now()` default is therefore SAFE: the `setShipped(null)` path at `BillofladingService.java:239` legitimately inserts a NULL `shipped`, and no INSERT constraint violation can occur. Proceed with the default removal as listed in the fix table.

**Verification test cases (add to Verification Plan §Phase 2+3):**
1. At warehouse 23:59 on day D: order with `pickingdate = D+1` must **not** be released
2. At warehouse 00:01 on day D+1: order with `pickingdate = D+1` **must** be released
3. At warehouse 16:00 on day D (= UTC midnight D+1 for LA): order with `pickingdate = D+1` must **not** be released — this is the 8-hour early-release regression test
4. Change order's picking date to warehouse "today" at 16:00 warehouse time (during UTC-rollover window): verify state resets to **RAW** (not stuck in FUTURE_PICKING_DATE), and verify no phantom `customerOrderOnHold` OMS notification is fired `[Round 8 fix — HIGH]`
5. Close a BOL at warehouse 16:30 (= UTC 00:30 D+1): verify `bol.shipped = D` (warehouse today), not `D+1` `[Round 8 fix — CRITICAL-2]`

**Scenario D — ReplenishOrderJob `new Date()` picking-date filter: why this is safe `[Round 9 fix]`:**

`ReplenishOrderJob.java:371,405` calls `new Date()` (current UTC instant) as the `pickingDate` parameter to two native queries:
- `ItemdataRepository.getIdsForItemDataWithoutFixedAssignmentPage` — `AND o.pickingDate <= :pickingDate`
- `ReplenishorderRepository.getIdsForItemDataWithFixedAssignmentWithOrdersPage` — `AND co.pickingDate <= :pickingDate`

Both `pickingDate` params are `@Param("pickingDate") Date pickingDate` bound against the `customerorder.pickingdate` `date` column. This is **different from `LocalDate.now()`** (Scenarios A/B/C): `java.util.Date` carries a UTC timestamp, and when JDBC sends it to PostgreSQL for comparison against a `date` column, PostgreSQL promotes the `date` value to `timestamp with time zone` at **midnight in the session timezone** (= warehouse TZ, set by Phase 2.6).

| LA wall-clock | UTC instant (`new Date()`) | `pickingdate=D+1` cast in session TZ | `D+1 <= new Date()` | Effect |
|---------------|---------------------------|--------------------------------------|---------------------|--------|
| May 25 15:59 | `2026-05-25T23:59:00Z` | `2026-05-26T07:00:00Z` (LA midnight) | `07:00Z <= 23:59Z`→ FALSE | ✅ not released |
| May 25 **16:00** | `2026-05-26T00:00:00Z` | `2026-05-26T07:00:00Z` (LA midnight) | `07:00Z <= 00:00Z`→ FALSE | ✅ **still not released** |
| May 26 00:00 | `2026-05-26T08:00:00Z` | `2026-05-26T07:00:00Z` (LA midnight) | `07:00Z <= 08:00Z`→ TRUE | ✅ released at LA midnight |

**Conclusion:** The session-TZ midnight cast shields `new Date()` from the UTC-rollover problem. Tomorrow's replenishment orders are correctly excluded at LA 4 PM because the session TZ makes `pickingdate = May 26` compare as `07:00Z` (LA midnight), which is later than `new Date()` at `00:00Z`. **No Java code change required for `ReplenishOrderJob.java:371,405`.** This is distinct from `LocalDate.now(UTC)` (Scenarios A/B/C) which is a pure calendar date with no TZ awareness whatsoever.

### 2.6 Set PostgreSQL Session Timezone Per-Tenant Connection `[Round 2 fix — M4]` `[Round 3 fix — FIX 3]`

**Purpose:** Make `current_date` and `current_timestamp` in native SQL queries and views use the warehouse's local timezone automatically.

<!-- [Round 4 fix — FIX R4-C2] -->
#### `resolveWarehouseTz` — one-shot DriverManager connection `[Round 4 fix — FIX R4-C2]`

Called from `TenantDynamicRoutingDataSource.createHikariPool(TenantDbConfiguration tc, String tenantKey)`
**before** `new HikariDataSource(cfg)` — resolves the warehouse timezone using a one-shot
JDBC connection (no Hikari pool yet; no chicken-and-egg).

`[Round 10 fix]` Source changed from `warehouse.timezone` column to the `los_sysprop` row keyed by `"System Time Zone"`. Each tenant DB has its own `los_sysprop`, so the query is not filtered by `facility_code` — the `facilityCode` parameter (and the `tenantKey` extraction block) is therefore dropped.

Insert into `createHikariPool`, after all `cfg.setXxx(...)` calls and before `return new HikariDataSource(cfg)`:

```java
// [Round 10 fix] Resolve warehouse timezone from los_sysprop before building pool —
// must precede new HikariDataSource(cfg). No facilityCode parameter needed: each
// tenant DB has its own los_sysprop, and one-shot DriverManager already targets
// the correct tenant DB via tc.getDbUrl().
String warehouseTz = resolveWarehouseTz(tc);
if (warehouseTz != null) {
    cfg.setConnectionInitSql("SET timezone = '" + warehouseTz + "'");
    // SECURITY: ZoneId.of() in resolveWarehouseTz validates IANA format — rejects
    // injected chars; SET is a PostgreSQL meta-command and cannot be parameterized.
}
// ... existing: return new HikariDataSource(cfg);
```

New private helper in `TenantDynamicRoutingDataSource`:

```java
// [Round 10 fix] Reads 'System Time Zone' from los_sysprop instead of warehouse.timezone.
// facilityCode parameter removed — sysprop query is per-tenant-DB, not per-facility.
// [Review fix — CRITICAL-1] Corrected column names: syskey/sysvalue (not key/value — confirmed
// in V1.0.01__wms_tables.sql:560-561). Added workstation='DEFAULT' filter per SyspropRepository.java:30.
// Upgraded silent catch(Exception) to ERROR log: previously a PSQLException ('column key does not exist')
// was silently swallowed, making connectionInitSql a no-op for all tenants with no visible evidence.
private String resolveWarehouseTz(TenantDbConfiguration tc) {
    try (Connection conn = DriverManager.getConnection(
             tc.getDbUrl(), tc.getDbUserName(), tc.getDbPassword());
         PreparedStatement ps = conn.prepareStatement(
             "SELECT sysvalue FROM los_sysprop WHERE syskey = 'System Time Zone' " +
             "AND workstation = 'DEFAULT' ORDER BY client_id LIMIT 1")) {
        try (ResultSet rs = ps.executeQuery()) {
            if (rs.next()) {
                String tz = rs.getString("sysvalue");
                ZoneId.of(tz); // SECURITY: validates IANA format; throws DateTimeException if invalid
                return tz;
            }
            log.warn("No 'System Time Zone' sysprop (syskey='System Time Zone', workstation='DEFAULT') " +
                     "found for {}; connectionInitSql not set — session will use PostgreSQL server " +
                     "timezone default (may be UTC in cloud-hosted DBs)", tc.getDbUrl());
        }
    } catch (DateTimeException dte) {
        log.error("Invalid IANA timezone '{}'; skipping connectionInitSql for {}: {}",
                  dte.getMessage(), tc.getDbUrl(), dte);
    } catch (Exception e) {
        // [Review fix — CRITICAL-1] Upgraded from warn to error + full stack trace so a
        // PSQLException (e.g., column not found due to wrong schema) is immediately visible
        // rather than silently degrading to missing session TZ for all tenants.
        log.error("Could not resolve warehouse timezone from los_sysprop for {}: {}",
                  tc.getDbUrl(), e.getMessage(), e);
    }
    return null;
}
```

> **`[Review fix — CRITICAL-2 Architect]` Two-path design — pool-init vs runtime (MUST NOT mix):**
> `resolveWarehouseTz()` (pool-init path) uses bare `DriverManager` + raw JDBC SQL because **no Hikari pool exists yet** at this call site. Calling `SyspropService.getSysvalue()` here would trigger JPA initialization, which requires an existing pool — a circular dependency. `TimezoneService.getWarehouseZoneId()` (runtime path) uses `SyspropService`, which requires an existing pool, and must therefore **never** be called from within `createHikariPool()`. Both paths read the same `los_sysprop` row independently. If the call-site distinction is ever unclear, add a unit test that invokes `createHikariPool()` with a mock `TenantDbConfiguration` and confirms no Spring beans (other than the datasource config itself) are accessed.

> **`[Review fix — LOW-3]` Fail-fast option when `resolveWarehouseTz()` returns null:** Currently the code silently continues pool creation with no `connectionInitSql` if the sysprop is missing. If strict per-tenant timezone enforcement is required, add a configurable `app.timezone.fail-fast=false` property (default `false` for backward compat) that throws a `TenantException` when null is returned, aborting pool creation for misconfigured tenants rather than silently degrading.

> **`[Round 2 fix — M4]` PgBouncer warning:** `connectionInitSql` runs once per physical connection, not per logical checkout. This is correct for session-scoped GUCs in session-pool mode. **If PgBouncer is in transaction-pool mode, this approach silently fails** — session GUCs are reset per transaction. Verify PgBouncer pooling mode before relying on this approach.

<!-- [Round 4 fix — FIX R4-m5] -->
> **`[Round 4 fix — FIX R4-m5]` SEC-1 — Why `SET timezone` is not parameterized:** `SET timezone` is a PostgreSQL meta-command, not a DML statement — it cannot be parameterized via `PreparedStatement`. `ZoneId.of(tz)` provides defense-in-depth by rejecting any value that is not a valid IANA timezone identifier (rejects semicolons, quotes, spaces, etc.).

**This makes the following transparent (no query changes needed):**
- `order_monitor_view` -- uses `CURRENT_DATE` in 6+ places for picking date comparisons
- `replenishment_monitor_view` -- uses `CURRENT_DATE` for picking date
- `MessageRepository` -- uses `current_date` for message cleanup
- All views that ORDER BY or filter on timestamp columns

**Files affected:**
- `src/main/java/net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java` -- add `resolveWarehouseTz()` and connection init hook
- `[Round 4 fix — FIX R4-M3]` **Do NOT add a `warehouseTimezone` field to `TenantDbConfiguration`** — no such field exists in the current codebase (confirmed: fields are `id, tenant, warehouse, dbUrl, dbUserName, dbPassword, driverClassName, maxPoolSize, minIdle, idleTimeoutMs, connectionTimeoutMs, created, modified`). Round 2 had proposed storing it in the landlord DB; Round 3 abandoned that in favour of a direct tenant-DB native query at pool-creation time. No removal needed.

### 2.7 Fix `new ObjectMapper()` Instances (Recommended)

**46** locations create `new ObjectMapper()` bypassing Spring config `[v2: plan said 36+]`. After migration with JVM set to UTC, the bare ObjectMapper will use UTC by default BUT will NOT have `JavaTimeModule` registered, so `LocalDateTime`/`LocalDate` fields will serialize as numeric arrays instead of strings.

**Critical files (handle date-containing DTOs via ObjectMapper):**

| File | Instance Count | Priority |
|------|----------------|----------|
| `OrderRestController.java` | 10 | HIGH |
| `AdviceRestController.java` | 6 | HIGH |
| `TransactionReportRestController.java` | 4 | HIGH |
| `SkuRestController.java` | 4 | HIGH |
| `ManageOrderService.java` | 7 | HIGH |
| `BillofladingService.java` | 1 (static `MAPPER`) | HIGH -- static, no JavaTimeModule |
| `OrderBatchCreationService.java` | 1 (static `OBJECT_MAPPER`) | HIGH -- static, no JavaTimeModule `[v2: new, not in original plan]` |
| `AdviceService.java` | 1 (static `MAPPER`) | HIGH -- static, no JavaTimeModule |
| `CustomerorderService.java` | 1 (static `MAPPER`) | MEDIUM |
| `CustomerorderBatchService.java` | 1 (static `MAPPER`) | MEDIUM |
| `StockSummaryExportJob.java` | 1 | MEDIUM |
| `StockChangeNotificationService.java` | 1 | MEDIUM `[v2: new, not in original plan]` |
| `CycleCountController.java` | 1 | LOW |
| `DashboardController.java` | 1 | LOW |
| `CustomerOrderController.java` | 1 | LOW |
| `ItemDataController.java` | 1 | LOW |
| `MessageDummyController.java` | 1 | LOW |
| `UtilRestController.java` | 1 | LOW |
| `SecurityConfiguration.java` | 1 (JWT only) | SKIP |

**Fix:** Inject the Spring-managed `ObjectMapper` bean, or create a shared static instance with `JavaTimeModule` and UTC timezone configured.

### 2.8 Fix `StartApplication.java` Repository Populator

**File:** `src/main/java/net/aim_ai/wms/StartApplication.java:47-51`

The `repositoryPopulator()` method creates a second `ObjectMapper` bean without `JavaTimeModule`. If this bean is ever injected by name instead of the `@Primary` one, date handling breaks. Fix by using the Spring-managed ObjectMapper or adding `JavaTimeModule`.

### 2.9 Backend Feature Flag for API Format (Recommended) `[Round 2 fix — M6]`

`[Round 2 fix]` Add sysprop `API_TIMESTAMP_FORMAT` with values `LEGACY` (old `yyyy-MM-dd HH:mm:ss` LA-local) and `ISO8601_UTC` (new `"2026-02-10T22:30:00.000Z"`). Default to `LEGACY` for one release cycle after the DB migration, then flip to `ISO8601_UTC` only after frontend rollout is confirmed complete.

This decouples the DB migration from the API format change, allowing the Flyway schema migration to go out first and the API format switch to follow once both frontends are confirmed updated. Force-logout active sessions at the flag-flip to ensure no stale JS continues receiving legacy format strings.

### 2.10 DB Stored Functions — Caller Impact Analysis `[Round 7 fix — NEW]`

Three stored functions currently accept `timestamp without time zone` parameters and query `timestamp without time zone` columns. Phase 3.2 recreates them with `timestamptz` signatures (V1.2.05 — the functions step; renumbered from V1.2.04 on 2026-06-03 so it runs after view recreation). This section traces every Java caller and the impact chain at each layer.

#### Function 1: `stock_history(as_of_date TIMESTAMP)`

Defined in `V1.0.03__wms_functions.sql:13`. Queries `inventory_record.timestamp` (becomes `timestamptz` in V1.2.02). Called by `transaction_detail` and `transaction_summary` internally (positional `$2`/`$3`/`$4` references in V1.1.04).

| Layer | File | Current binding | After V1.2.05 (timestamptz) |
|-------|------|----------------|------------------------------|
| Repository | `StockViewRepository.java:62` | `@Param("asOfDate") Date asOfDate` — JDBC sends epoch ms; PostgreSQL session-TZ-aware cast to bare timestamp | `java.util.Date` (epoch ms) → JDBC → PostgreSQL maps directly to `timestamptz` in UTC — **no Java change required** |
| REST callers | Spring Data REST HAL endpoint only — no Java service callers | Date string from query param bound by Spring's ConversionService | Same; after JVM = UTC, Spring parses date strings as UTC epoch → `timestamptz` correctly |

**Java code change required:** None. V1.2.05 stored-function signature update is sufficient.

#### Functions 2 & 3: `transaction_detail` / `transaction_summary`

Both defined in `V1.1.04__wms_functions.sql`. Each has **two independent Java callers** with different parameter binding strategies.

---

**Caller A — `StockrecordRepository.java:24,34` (Spring Data REST HAL endpoints)**

```java
@Param("startdate") Date startdate,
@Param("enddate") Date enddate
```

- Binding: `java.util.Date` → JDBC sends epoch ms → PostgreSQL receives as UTC `timestamptz` after V1.2.05
- No `::timestamp` cast in the query string — JDBC does the binding directly
- No service-layer callers; exposed only as HAL REST search endpoints (`/api/stockrecord/search/transactionDetailByClientNumberAndSkuBetweenDates`)
- **Java code change required:** None. V1.2.05 signature update is sufficient.

> **⚠️ MAJOR-1 caveat — Spring Data REST `java.util.Date` string-parsing depends on JVM timezone `[Round 8 fix]`:** Spring Data REST parses query-parameter date strings (e.g., `?startdate=2026-02-10`) via Spring's `ConversionService`, which interprets the string in the JVM's default timezone. Pre-migration (JVM = `America/Los_Angeles`): `"2026-02-10"` is parsed as `2026-02-10 00:00:00 LA` = epoch ms for LA midnight. Post-migration (JVM = UTC): `"2026-02-10"` is parsed as `2026-02-10 00:00:00 UTC` — 8 hours later in absolute time for LA warehouses. Any HAL client that passes date strings to these endpoints will experience an 8-hour shift in the queried range after Deploy 2. **Action required:** audit whether these HAL endpoints are called by any active client (frontend, monitoring, OMS) before Deploy 2. If they are used for business reporting, they need the same warehouse-local treatment as `ClientRepository` Caller B — or the calling client must adjust its date strings to account for the JVM UTC shift.

---

**Caller B — `ClientRepository.java:53-65` + `TransactionReportRestController.java`**

```java
// ClientRepository.java - both getTransactionSummary and getTransactionDetail
"to_timestamp(:startDate, 'YYYY-MM-DD hh24:mi:ss')\\:\\:timestamp without time zone"
```

This path has a 3-layer chain:

```
Frontend date picker (warehouse-local string)
  → POST body: { startDate: "2026-02-10 00:00:00", endDate: "2026-02-10 23:59:59" }
  → TransactionReportRestController.java:99-108
      SimpleDateFormat(DATE_TIME_PATTERN).parse(request.getStartDate())  // validates format only
      → start_date = SimpleDateFormat(DATE_TIME_PATTERN).format(startDate)  // identity transform
  → ClientRepository.getTransactionSummary(clientCode, start_date, end_date)
  → SQL: to_timestamp('2026-02-10 00:00:00', 'YYYY-MM-DD hh24:mi:ss')::timestamptz
         -- session TZ = warehouse TZ (e.g. America/Los_Angeles)
         -- result: 2026-02-10 08:00:00+00 (UTC) ← CORRECT
```

**Required Java change:** `ClientRepository.java` lines 55 and 65 — change cast:
```java
// BEFORE
"...to_timestamp(:startDate, 'YYYY-MM-DD hh24:mi:ss')\\:\\:timestamp without time zone..."
// AFTER
"...to_timestamp(:startDate, 'YYYY-MM-DD hh24:mi:ss')\\:\\:timestamptz..."
```
(Already listed in Phase 3.2 as part of the `::timestamp` → `::timestamptz` audit, but the reason is documented here.)

**Why this is safe:** `to_timestamp('2026-02-10 00:00:00')` produces a bare timestamp; casting to `::timestamptz` interprets it in the **PostgreSQL session timezone**, which Phase 2.6 sets to the warehouse's IANA timezone via `connectionInitSql`. So the warehouse-local string the frontend sends is correctly converted to UTC by the session GUC — no double conversion.

**Critical constraint — `startDate`/`endDate` must remain warehouse-local strings** `[Round 7 fix]`:

The `SimpleDateFormat` parse+format cycle in `TransactionReportRestController` is a format-validation no-op (parse string → `Date` → format same string back). After Phase 2 the JVM is UTC, so `SimpleDateFormat` interprets the string as UTC — but the string value itself is unchanged (e.g., "2026-02-10 00:00:00" comes in and "2026-02-10 00:00:00" goes out). The session-TZ `::timestamptz` cast then correctly interprets it as warehouse-local.

**However:** if the frontend were to send UTC strings for this endpoint (e.g., "2026-02-10 08:00:00" representing LA midnight), the session-TZ cast would interpret "08:00:00" as warehouse-local (LA), adding another -8h offset → **wrong result (double-conversion)**. 

**Document in the API contract**: `POST /rest/getTransactionSummaryReport` and `POST /rest/getTransactionDetailedReport` — the `startDate` / `endDate` fields must be in **warehouse-local time** using format `"yyyy-MM-dd HH:mm:ss"`, NOT UTC. The frontend date-range pickers for transaction reports must NOT convert to UTC before sending. This is the one endpoint category that remains warehouse-local on the wire (all other timestamp fields in API responses move to UTC ISO-8601).

**`SimpleDateFormat` timezone pinning in `TransactionReportRestController`** (Phase 1.3 item):
After JVM switches to UTC in Phase 2, the `SimpleDateFormat` instances at lines 99, 105, 108, 213, 219, 222 use UTC. For this parse-validate-reformat pattern, the JVM TZ doesn't affect the string output. No pinning is strictly required here, but pinning to warehouse TZ via `TimezoneService` is recommended for clarity:
```java
SimpleDateFormat dateTimeFormat = new SimpleDateFormat(WmsConstants.DATE_TIME_PATTERN);
dateTimeFormat.setTimeZone(TimeZone.getTimeZone(timezoneService.getWarehouseZoneId().getId()));
```

#### Summary: Java Changes Required for DB Function Callers

| File | Change | Phase |
|------|--------|-------|
| `ClientRepository.java:55` | `::timestamp without time zone` → `::timestamptz` | Phase 3.2 (pre-deploy audit) |
| `ClientRepository.java:65` | `::timestamp without time zone` → `::timestamptz` | Phase 3.2 (pre-deploy audit) |
| `TransactionReportRestController.java:99,105,108,213,219,222` | Pin `SimpleDateFormat` to warehouse TZ (recommended) | Phase 1.3 / Phase 2.5 |
| `StockrecordRepository.java` | No change | — |
| `StockViewRepository.java` | No change | — |
| `V1.2.05__utc_update_functions.sql` | Recreate all 3 functions with `timestamptz` params | Phase 3.2 |

**API contract documentation needed** (operations runbook):
- `POST /rest/getTransactionSummaryReport` — `startDate`/`endDate` stay warehouse-local (`"yyyy-MM-dd HH:mm:ss"`)
- `POST /rest/getTransactionDetailedReport` — same
- `/api/stockrecord/search/transactionDetailByClientNumberAndSkuBetweenDates` — `startdate`/`enddate` are `java.util.Date` via Spring Data REST; accept standard ISO date strings interpreted as UTC epoch by Spring's ConversionService after JVM = UTC

---

## Phase 3: Database Data Migration (Same Deployment as Phase 2)

**Purpose:** Convert all existing timestamp data from warehouse-local time to UTC and change column types to `timestamptz`. This Flyway migration runs at app startup BEFORE the app serves requests.

Current Flyway watermark: **V2.1.15__add_api_timestamp_format_sysprop.sql** (V2.1.14 = outbox aggregate-order index; V2.1.15 = Phase 2.9 `API_TIMESTAMP_FORMAT` seed). New **schema** migrations use V1.2.x to signal a major schema change; sysprop seeds and additive index/feature migrations stay in the `V2.1.x` lineage (V2.1.15 is the latter).

`[Round 2 fix — C1, M1]` `[2026-06-03 — now 5 files]` **Migration is split into 5 files** to avoid a single long-running transaction that holds `ACCESS EXCLUSIVE` locks on all tables simultaneously. The split also ensures partial progress survives a failure mid-migration on large tables.

> **⚠️ View dependency (validated 2026-06-03 against PostgreSQL 16).** PostgreSQL refuses `ALTER COLUMN ... TYPE` on any column a view depends on. **V1.2.01 therefore DROPs all 11 reporting views first**, and they stay dropped through V1.2.02 (large-table rewrite) and V1.2.03 (outbox), then are recreated by **V1.2.04** (verbatim canonical DDL, now over `timestamptz`) — which must run BEFORE **V1.2.05** (functions), because `stock_history`'s RETURNS declares `stock_view.%TYPE`. The views are mutually independent (no view-on-view deps). The drop set is ALL 11 — not just the obvious `co.created`/`su.created`/`a.created` referencers — because `flowbin_monitor_view` and `cyclecount_dto_view` carry whole-row deps (`f.*` / `f ISNULL` on `fix_location_assignment`) that column-level scanning misses. See Phase 3.3.

| File | Tables | Transactional? | Notes |
|------|--------|---------------|-------|
| `V1.2.01` | All standard Hibernate tables (Group A, fast) | YES (default) | **Drops all 11 views first**; idempotency canary + pre-migration safety check; 81 columns (40×2 + `goodsreceipt.receiptdate`) |
| `V1.2.02` | Large tables: `stockrecord`, `unitload_record`, `inventory_record`, `pickingorder_position` | NO (`flyway.executeInTransaction=false`) | Longest-running; partial progress survives failure |
| `V1.2.03` | Group B (`outbox_message`) + `rest_idempotency` `[Round 3 fix — FIX 1]` `[Round 10 fix — warehouse removed]` | YES (default) | Small/fast |
| `V1.2.04` | **Recreate all 11 views** (verbatim canonical DDL) | YES (default) | Must precede V1.2.05 — `stock_history` RETURNS `stock_view.%TYPE` |
| `V1.2.05` | Stored functions (`stock_history`, `transaction_detail`, `transaction_summary`) | YES (default) | Runs LAST, before the app starts; `timestamptz` params/returns |

### 3.1 Create Flyway Migration Scripts `[Round 2 fix — C1]`

`[Round 2 fix]` The original plan used `SET timezone='America/Los_Angeles'; ALTER COLUMN TYPE timestamptz` (session-level approach). This is **incorrect for `outbox_message`** because those columns are Hibernate `Instant`-written (UTC wall-clock), not LA wall-clock. The `SET timezone` approach would incorrectly shift outbox timestamps by +8 hours.

The correct approach is explicit `USING (col AT TIME ZONE 'X')` per column group:
- **Group A** (Hibernate `LocalDateTime` via `hibernate.jdbc.time_zone=America/Los_Angeles`): `USING col AT TIME ZONE 'America/Los_Angeles'` — **correct for ALL tenants** including NY-timezone warehouses, because `hibernate.jdbc.time_zone` is a global server-wide setting in `application.properties`. Every tenant's data was written as LA wall-clock regardless of the tenant's own `System Time Zone` sysprop. The migration does NOT need to be parameterized per tenant. `[Round 11 fix]`
- **Group B** (Hibernate `Instant` via calendarUTC, regardless of `hibernate.jdbc.time_zone`): `USING col AT TIME ZONE 'UTC'`

---

**File:** `src/main/resources/db/migration/V1.2.01__utc_standard_tables.sql`

```sql
-- ============================================================
-- UTC Timezone Migration — Phase 1: Standard Hibernate tables (Group A)
-- All columns in this file are Hibernate LocalDateTime-written
-- via hibernate.jdbc.time_zone=America/Los_Angeles.
-- Existing values are LA wall-clock → interpret as 'America/Los_Angeles'.
-- ============================================================

-- ============================================================
-- IDEMPOTENCY GUARD: abort if already migrated (prevents double-shift on re-run)
-- [Review fix — MAJOR-3] Re-running V1.2.01 on an already-migrated DB interprets stored UTC
-- timestamps as LA wall-clock and shifts them an additional 8 hours. Checking the canary
-- column 'advice.created' type is sufficient — all Group A tables are migrated atomically.
-- ============================================================
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'advice'
      AND column_name = 'created' AND data_type = 'timestamp with time zone'
  ) THEN
    RAISE EXCEPTION 'ABORT: advice.created is already timestamptz — V1.2.01 has been applied. '
                    'Re-running would double-shift all timestamps. Verify migration state before proceeding.';
  END IF;
END $$;

-- [Review fix — LOW-1] Belt-and-suspenders: also set inside the file for cases where the
-- session-level SET in the §0.5 psql runbook (-c "SET statement_timeout = 0") is skipped.
SET statement_timeout = 0;

-- ============================================================
-- PRE-MIGRATION SAFETY CHECKS
-- ============================================================
DO $$ BEGIN
  -- Abort if outbox has in-flight rows (indicates OutboxDispatcherJob is still running)
  IF EXISTS (
    SELECT 1 FROM outbox_message
    WHERE status IN ('PENDING', 'IN_FLIGHT', 'FAILED_RETRY')
  ) THEN
    RAISE EXCEPTION 'ABORT: outbox_message has in-flight rows. Drain the outbox before migrating.';
  END IF;
END $$;

-- ============================================================
-- GROUP A: Standard AbstractBaseEntity audit columns (44 tables)
-- ============================================================
ALTER TABLE advice ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE advice ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE adviceposition ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE adviceposition ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE billoflading ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE billoflading ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE billoflading_position ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE billoflading_position ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE boxtype ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE boxtype ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE client ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE client ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE customerorder ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE customerorder ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE customerorder_batch ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE customerorder_batch ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE customerorder_position ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE customerorder_position ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE cyclecount ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE cyclecount ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE cyclecount_position ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE cyclecount_position ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE fix_location_assignment ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE fix_location_assignment ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE goodsreceipt ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE goodsreceipt ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE goodsreceiptposition ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE goodsreceiptposition ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE itemdata ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE itemdata ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE itemunit ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE itemunit ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_area ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_area ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_constraint ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_constraint ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_rack ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_rack ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_rack_row ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_rack_row ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_type ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE location_type ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE los_sysprop ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE los_sysprop ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE message ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE message ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE message_archived ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE message_archived ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE mywms_function ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE mywms_function ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE mywms_group ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE mywms_group ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE mywms_role ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE mywms_role ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE mywms_user ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE mywms_user ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE pickingorder ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE pickingorder ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE pickingorder_unitload ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE pickingorder_unitload ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE printer ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE printer ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE queryrepository ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE queryrepository ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE replenishorder ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE replenishorder ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE section ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE section ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE shipperid ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE shipperid ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE shippingmethod ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE shippingmethod ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE stockunit ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE stockunit ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE unitload ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE unitload ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE unitload_type ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE unitload_type ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';

-- Business-specific timestamp columns (also Group A — Hibernate LocalDateTime):
ALTER TABLE goodsreceipt ALTER COLUMN receiptdate TYPE timestamptz
  USING receiptdate AT TIME ZONE 'America/Los_Angeles';
```

---

**File:** `src/main/resources/db/migration/V1.2.02__utc_large_tables.sql`

`[Round 3 fix — FIX 10]` Verify `-- flyway.executeInTransaction=false` header syntax against the Flyway version bundled with Spring Boot 3.5.9 before deploy. In Flyway 9+, script-level configuration uses this exact comment syntax on the first line of the SQL file.

```sql
-- flyway.executeInTransaction=false
-- ============================================================
-- UTC Timezone Migration — Phase 2: Large tables (Group A, slow)
-- These tables have large row counts and long ALTER runtimes.
-- Non-transactional: partial progress survives a failure.
-- Recovery: run remaining ALTERs manually or re-run Flyway after fixing the issue.
-- ============================================================

-- Prevent admin-set statement timeouts from killing the migration
SET lock_timeout = 0;
SET statement_timeout = 0;

ALTER TABLE stockrecord ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE stockrecord ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';

ALTER TABLE unitload_record ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE unitload_record ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';

ALTER TABLE inventory_record ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE inventory_record ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE inventory_record ALTER COLUMN "timestamp" TYPE timestamptz
  USING "timestamp" AT TIME ZONE 'America/Los_Angeles';

ALTER TABLE pickingorder_position ALTER COLUMN created TYPE timestamptz
  USING created AT TIME ZONE 'America/Los_Angeles';
ALTER TABLE pickingorder_position ALTER COLUMN modified TYPE timestamptz
  USING modified AT TIME ZONE 'America/Los_Angeles';
```

---

**File:** `src/main/resources/db/migration/V1.2.03__utc_outbox_and_new_tables.sql`

`[Round 3 fix — FIX 1]` `customerorder_old` removed entirely — zero wms2-api references; single 2019-era archive row; no application code reads or writes it.

`[Round 10 fix]` The `warehouse` table section (previously guarded by `IF EXISTS`) has been removed — the table is out of scope (slated for deletion by the user) and no longer participates in this migration.

`[Round 3 fix — FIX 5]` `rest_idempotency` drained before migration (see Phase 3.5 drain procedure). `created_at` is written by native `INSERT ... NOW()` under UTC server timezone — not Hibernate `LocalDateTime`. Table is empty at this point; `ALTER TYPE` is instantaneous on an empty table.

```sql
-- ============================================================
-- UTC Timezone Migration — Phase 3: Outbox (Group B) + new tables (Group A)
-- [Round 3 fix — FIX 1] customerorder_old excluded — zero wms2-api references
-- ============================================================

-- ============================================================
-- GROUP B: outbox_message — Hibernate Instant-written
-- Instant is mapped via calendarUTC regardless of hibernate.jdbc.time_zone.
-- Existing values are UTC wall-clock → interpret as 'UTC' (no shift needed).
-- ============================================================
-- [Round 5 fix — FIX R5-m2] Self-defending assertion: fail fast if expected column names are absent
-- Catches column-name drift before attempting the ALTER (would produce "column does not exist" otherwise)
DO $$ BEGIN
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'outbox_message' AND column_name = 'created_at'
  ), 'ABORT: outbox_message.created_at column not found — check V2.1.11 migration was applied';
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'outbox_message' AND column_name = 'modified_at'
  ), 'ABORT: outbox_message.modified_at column not found — check V2.1.11 migration was applied';
END $$;

-- [Round 4 fix — FIX R4-m3] Symmetric IF EXISTS guard for outbox_message
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'outbox_message') THEN
    -- [Round 5 fix — FIX R5-C1] Correct column names: created_at/modified_at (not created/modified)
    -- Verified against V2.1.11__add_outbox_message.sql:19-20 and OutboxMessage.java @Column annotations
    ALTER TABLE outbox_message ALTER COLUMN created_at      TYPE timestamptz USING created_at      AT TIME ZONE 'UTC';
    ALTER TABLE outbox_message ALTER COLUMN modified_at     TYPE timestamptz USING modified_at     AT TIME ZONE 'UTC';
    ALTER TABLE outbox_message ALTER COLUMN next_attempt_at TYPE timestamptz USING next_attempt_at AT TIME ZONE 'UTC';
    ALTER TABLE outbox_message ALTER COLUMN sent_at         TYPE timestamptz USING sent_at         AT TIME ZONE 'UTC';
  END IF;
END $$;

-- ============================================================
-- GROUP A (continued): Post-plan tables
-- ============================================================

-- rest_idempotency: drained before migration (see Phase 3.5 drain procedure)
-- [Round 3 fix — FIX 5] created_at written by native INSERT...NOW() under UTC server timezone (not Hibernate LocalDateTime)
-- Table is empty at this point; ALTER TYPE is instantaneous on empty table
-- [Round 4 fix — FIX R4-m3] Symmetric IF EXISTS guards for rest_idempotency
-- [2026-05-26] Added drain assertion mirroring outbox_message pre-flight check
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'rest_idempotency') THEN
    -- Abort if table was not drained (mirrors outbox_message safety check)
    IF (SELECT COUNT(*) FROM rest_idempotency) > 0 THEN
      RAISE EXCEPTION 'ABORT: rest_idempotency has % rows. Run DELETE FROM rest_idempotency before migrating.',
        (SELECT COUNT(*) FROM rest_idempotency);
    END IF;
    ALTER TABLE rest_idempotency ALTER COLUMN created_at TYPE timestamptz
      USING created_at AT TIME ZONE 'UTC';
    ALTER TABLE rest_idempotency ALTER COLUMN updated_at TYPE timestamptz
      USING updated_at AT TIME ZONE 'UTC';
  END IF;
END $$;

-- [Round 10 fix] warehouse table section removed — table is out of scope

-- ============================================================
-- customerorder_cancellation_log (SBDEV-1921): NO CONVERSION NEEDED
-- All timestamp columns (reversal_initiated_at, reversal_completed_at, created_at)
-- were created as TIMESTAMP WITH TIME ZONE by V2.1.12 — already UTC-compatible.
-- reversal_initiated_by / reversal_completed_by are VARCHAR(255), created directly by V2.1.12 (no ALTER).
-- This table is intentionally omitted from all ALTER TABLE statements in V1.2.01–V1.2.03.
-- ============================================================
-- (unused by wms2-api; slated for deletion by user). No ALTER applied here.
```

---

**File:** `src/main/resources/db/migration/V1.2.05__utc_update_functions.sql`

See Section 3.2 below.

**Date columns that remain as `date` (NO conversion needed):**
- `advice.dayofdelivery`, `advice.dayofdeliveryuntil`
- `billoflading.shipped`
- `customerorder.pickingdate`

These are timezone-agnostic by nature. Business logic determines which "date" using the warehouse timezone. `[Round 3 fix — FIX 1]` `customerorder_old.pickingdate` excluded.

### 3.2 Update Stored Functions `[Round 2 fix — M5]`

**File:** `src/main/resources/db/migration/V1.2.05__utc_update_functions.sql`

Recreate the 3 stored functions with `timestamptz` parameter and return types. Order matters: `stock_history` is called by the other two.

Current signatures (confirmed from DB):
- `stock_history(as_of_date timestamp without time zone)` → `timestamptz`
- `transaction_detail(client_number_in varchar, sku_in varchar, startdate_in timestamp without time zone, enddate_in timestamp without time zone)` → includes `transaction_date timestamp without time zone` in return
- `transaction_summary(client_number_in varchar, startdate_in timestamp without time zone, enddate_in timestamp without time zone)`

Full function definitions: copy from `V1.0.03__wms_functions.sql` + `V2.1.07__update_transaction_detail_pick_amount_filter.sql` with all `timestamp without time zone` replaced by `timestamptz`.

`[Round 2 fix — M5]` After updating stored function signatures, also update:
- `ClientRepository.java:54-55, 64-65`: change `::timestamp without time zone` to `::timestamptz`
- Any other hits for `::timestamp\b` in `src/main/java/` (pre-deploy audit step — see §3.5)

### 3.3 Update Views

There are **two distinct view concerns** — do not conflate them:

**(a) Runtime `current_date` semantics (no DDL needed).** With the per-tenant session timezone from Phase 2.6, `current_date` in views reflects the tenant's timezone automatically, so the *business logic* in views stays correct with no rewrite. Views using `CURRENT_DATE` (confirmed): `order_monitor_view` (latest in `V2.1.03`), `replenishment_monitor_view` (in `V1.0.02`). `[v2 note: only 2 views use CURRENT_DATE; 11 total views.]`

**(b) DDL dependency on the converted columns (MANDATORY drop + recreate). `[2026-06-03 — validated against PostgreSQL 16]`** This is a hard blocker the earlier draft of this section missed: PostgreSQL refuses `ALTER COLUMN ... TYPE` on any column a view depends on (`ERROR: cannot alter type of a column used by a view or rule`). Multiple views reference the `created`/`modified` columns V1.2.01–V1.2.02 convert:

| View | Dependency on a converted column |
|------|----------------------------------|
| `order_monitor_view` | `DATE(co.created)` → `customerorder.created` |
| `parcel_monitor_view` | `co.created`, `ORDER BY co.created` → `customerorder.created` |
| `lock_overview_dto_view` | `ORDER BY su.created, su.modified` → `stockunit.created/modified` |
| `receiving_dto_view` | `ORDER BY a.created, a.modified` → `advice.created/modified` |
| `flowbin_monitor_view` | `GROUP BY f.*` / `f ISNULL` → **whole-row** dep on `fix_location_assignment` (incl. created/modified) |
| `cyclecount_dto_view` | `f ISNULL` → **whole-row** dep on `fix_location_assignment` |

Whole-row references (`f.*`, `f ISNULL`, `count(grp.*)`) create column dependencies that simple column-ref scanning does NOT surface — so the safe drop set is **ALL 11 views**, not a hand-picked subset. Mechanism (validated end-to-end on PostgreSQL 16: drop → 81 ALTERs succeed → recreate → 11 views restored over `timestamptz`):

1. **V1.2.01** drops all 11 views (`DROP VIEW IF EXISTS … CASCADE`) before its `ALTER`s. Views stay dropped — the app is scaled to 0 during the window.
2. **V1.2.02 / V1.2.03** run with views absent, so they never re-hit the dependency wall.
3. **V1.2.04** (`V1.2.04__utc_recreate_views.sql`) recreates all 11 verbatim from the canonical repo definitions (latest of `V1.0.02` / `V1.1.01` / `V2.1.03`), now over `timestamptz`.
4. **V1.2.05** (`V1.2.05__utc_update_functions.sql`) recreates the 3 functions LAST — AFTER the views, because `stock_history`'s RETURNS declares `stock_view.%TYPE` (so `stock_view` must already exist). No view references any of the 3 functions, so there is no circular dependency. Runs before the app starts (Deploy 2 step 7).

The recreated views are byte-for-byte identical to today's definitions; only the underlying column type changed. `DATE(co.created)`, `ORDER BY su.created`, etc. all work unchanged on `timestamptz`. **No per-view rewrite is required for the `current_date` concern** because Phase 2.6 handles it at the session level — concern (a) and concern (b) are orthogonal.

### 3.4 System Time Zone Sysprop

The wms2-wineco-dev DB has `System Time Zone = 'America / Los_Angeles'` (no offset suffix). `[v2 correction: original plan said seed data has 'America / New_York (-05:00)' — that was v1 seed data. wms2 dev DB already has correct LA value.]`

Each tenant's `System Time Zone` value must be verified before migration. The `TimezoneService.parseToZoneId()` method (Phase 2.4) handles both `'America / Los_Angeles'` and `'America / New_York (-05:00)'` formats.

`[Round 10 fix]` Both `TimezoneService` (Phase 2.4) and the `resolveWarehouseTz` helper (Phase 2.6) read the `los_sysprop` `"System Time Zone"` value. `TimezoneService.parseToZoneId()` normalises any formatting quirks; `resolveWarehouseTz` applies `ZoneId.of()` directly as an IANA validation guard before injecting into `SET timezone`.

### 3.5 Migration Performance Considerations `[Round 2 fix — M1, M8]`

`ALTER COLUMN ... TYPE timestamptz` on large tables acquires an `ACCESS EXCLUSIVE` lock and rewrites the table.

**Pre-migration drain procedure `[Round 3 fix — FIX 5]`:**
Before starting the maintenance window, on each tenant DB:
1. `DELETE FROM rest_idempotency;` — eliminates the LA-vs-UTC timezone ambiguity for `rest_idempotency.created_at` (written by native `INSERT ... NOW()` under UTC, not Hibernate `LocalDateTime`). The `RestIdempotencyCleanupJob` would have purged these rows within 7 days anyway. The migration then converts an empty table, and new rows post-migration will be written as UTC `timestamptz` by `NOW()` under the UTC server timezone.
2. `DELETE FROM outbox_message WHERE status IN ('SENT','FAILED_TERMINAL');` — optional cleanup of terminal rows before the type conversion.

**Pre-deploy audit (run before Phase 3 deploy):** `[Round 2 fix — M5]`
```bash
grep -rn "::timestamp\b\|timestamp without time zone" v2/wms2-api/src/main/java/ --include="*.java"
# Must return zero results before deploying Phase 3
```

**Index rebuild cost:** `[Round 2 fix — M8]`
- `ALTER COLUMN TYPE timestamptz` automatically rebuilds all B-tree indexes on altered columns
- Key indexes affected on large tables: `stockrecord` and `inventory_record` composite indexes from V2.1.04-V2.1.06
- `outbox_message` partial index `index_outbox_message_dispatch ON (status, next_attempt_at) WHERE status IN ('PENDING','FAILED_RETRY')` — will be rebuilt automatically; confirm it exists after migration
- Required free disk space: at minimum ≥ 2× size of each table being rewritten (table rewrite + new copy coexist). Estimate: `stockrecord` ~3.6 GB × 2 = 7.2 GB, `inventory_record` ~2.5 GB × 2 = 5 GB minimum, `unitload_record` additional

**Pre-migration disk check:** `[Round 2 fix — M8]`
```sql
SELECT pg_size_pretty(pg_database_size(current_database()));
-- This reports DB SIZE, not free space.
```
```bash
# [Architect L4] Free space is an OS-level fact, not a SQL one — check the DB's data volume:
df -h /var/lib/postgresql   # or the actual PGDATA mount for this host
# Verify available space ≥ 2× the largest table being rewritten (≥ ~7.2 GB for stockrecord)
# AND ≥ the pg_database_size figure above, before proceeding.
```

**Monitor ALTER progress during maintenance window:**
```sql
SELECT phase, blocks_done, blocks_total FROM pg_stat_progress_cluster;
-- Also: pg_stat_user_tables for row counts post-migration
```

**`OutboxDispatcherJob` draining:** `[Round 2 fix — M2]` `OutboxDispatcherJob` uses `@Scheduled` and is NOT gated by `app.cron=true` — it runs on every replica. To properly drain:
1. Quiesce all incoming HTTP writes (maintenance mode)
2. Wait for the dispatcher to process all PENDING rows (≤ 15 seconds)
3. Verify no IN_FLIGHT rows remain (5-minute stale timeout applies)
4. THEN start the Flyway migration

Pre-deploy verification command: `SELECT COUNT(*) FROM outbox_message WHERE status IN ('PENDING','IN_FLIGHT','FAILED_RETRY')` — must return 0 before starting Flyway.

**Post-migration:**
```sql
ANALYZE advice, billoflading, customerorder, stockrecord, unitload_record,
        inventory_record, pickingorder_position, outbox_message;
-- Refreshes planner statistics for timestamptz column type
```

**Mitigations summary:**
- V1.2.01 and V1.2.03 run in a transaction (fast tables — rollback is clean on failure)
- V1.2.02 runs non-transactional (`flyway.executeInTransaction=false`) — partial progress survives failure; recovery = run remaining ALTERs manually or re-run Flyway after fixing disk/lock issue
- `SET lock_timeout = 0; SET statement_timeout = 0;` at the top of V1.2.02 prevents admin timeout from killing the migration

---

## Phase 4: Frontend Updates `[Round 6 fix]`

> **Implementation status (2026-06-03):**
> - ✅ **Foundation (4.0 / 4.2 / 4.3) — DONE in both UIs.** web `eb7e401`, mobile `316ad36`. New `plugins/dateFormatter.js` ($formatDateTime/$formatDate/$formatDateShort/$formatTimeOnly/$formatDateTimeShort/$parseDateForApi/$formatDateForPicker/$parseTransactionReportDate); `store/index.js` `warehouseTimezone` state+mutation+action; `initTenantAuth.client.js` captures `tenant_discovery.timezone` from the existing `/api/public/authConfig` call; `nuxt.config.js` `moment {timezone:true}` (dropped `defaultTimezone`) + removed dead `publicRuntimeConfig.moment` + registered the plugin. **Backend dep confirmed:** `TenantDiscoveryController.getAuthConfig` already returns the full `TenantDiscovery` incl. `timezone` (default `"UTC"`). Both UIs are `ssr:false` (SPA), so `localStorage` in `state()` is safe. `node --check` clean on all 8 files; full Nuxt build/lint not yet run.
> - ✅ **Component sweep (4.4 / 4.5) — DONE in both UIs.** Web: review slice `cc04026` (12 components incl. `transferDetails`/`parcelDetails` picker round-trip + `stockUnitRecord` `'(EST)'`→`'Time Stamp'`) + bulk `aa98004` (72 components, 91 canonical replacements). Mobile: `51b8418` (all 3 date components). `safeParse` hardened for numeric-epoch/`Date` inputs. **4.5 send-paths:** `date`-column writes (pickingdate, dayofdelivery*) send `"YYYY-MM-DD"` via `$formatDateForPicker` (NOT `$parseDateForApi`). **4.7 audit:** no frontend callers of `getTransactionSummaryReport`/`getTransactionDetailedReport` exist; `$parseTransactionReportDate` helper is available if wired later; no `$parseDateForApi` misuse found. **Intentionally left raw `$moment`:** `exportReport.vue:117` filename timestamp, `updatePickingDatePop.vue:85` today-default, and `.toISOString()` picker bounds / "now" markers. **Verified:** ESLint on the 72 bulk files = 52 errors, identical to pre-sweep baseline (stash-compared) → 0 new errors; all pre-existing are template/style. ✅ **Production build green on both UIs** (`npm run build` / `nuxt build`, node v24: all routes generated, `dist/` created, only a pre-existing bundle-size warning). None deployed; on `feature/utc-timezone` in both UI repos.
> - **🏁 Phase 4 is code-complete in both UIs.** Remaining for the migration overall: the coordinated deploy (Phase 3 DB migration in the same window as the backend), a `yarn build` gate on both UIs, staging DST validation, and Phase 5 cleanup.

**Purpose:** Ensure both frontends correctly display UTC timestamps from the API in the warehouse's local timezone.

`[Round 7 fix]` **Frontend Display Responsibility Principle:** After the migration the backend API always returns timestamps in UTC ISO-8601 format (`"2026-02-10T22:30:00.000Z"`). **Converting UTC to the warehouse's local timezone for display is entirely the frontend's responsibility.** No timestamp displayed in the UI should show raw UTC — every displayed datetime must pass through `$formatDateTime` / `$formatDate` / `$formatDateTimeShort` etc. (see Phase 4.3). The backend performs no display-oriented timezone conversion; it emits UTC and provides the warehouse timezone string separately (via `tenant_discovery.timezone`). The centralized `plugins/dateFormatter.js` (Phase 4.3) is the single enforcement point.

**Exception — date-range inputs for transaction reports**: `startDate`/`endDate` fields sent to `POST /rest/getTransactionSummaryReport` and `POST /rest/getTransactionDetailedReport` must remain warehouse-local strings (format `"yyyy-MM-dd HH:mm:ss"`) — see Phase 2.10. Date pickers feeding these endpoints must NOT convert to UTC before sending. All other API inputs (date pickers for picking dates, BOL shipped dates, etc.) deal with `date`-typed columns that are timezone-agnostic and remain unchanged.

`[Round 6 fix]` **Timezone source clarified:** warehouse timezone is read from `tenant_discovery.timezone` via the existing `GET /api/public/authConfig` startup call — not from system properties. Both UIs already call this endpoint at boot via `plugins/initTenantAuth.client.js`; Phase 4.0 adds the timezone capture to that same call. Phase 4.6 (sysprops-based loading) is superseded.

### 4.0 Bootstrap Timezone from `tenant_discovery` `[Round 6 fix — NEW]`

Both `wms2-web-ui` and `wms2-mobile-ui` call `GET /api/public/authConfig?key=<warehouse>-<clientName>` at startup via `plugins/initTenantAuth.client.js`. The response now includes a `timezone` field (e.g. `"America/Los_Angeles"`, `"America/New_York"`, `"UTC"`) sourced from the `tenant_discovery.timezone` column (default `"UTC"`). Both UIs must capture this value at startup and persist it for the lifetime of the application.

**Example `GET /api/public/authConfig?key=WSL-WineCo` response** `[Review fix — HIGH-1]`:
```json
{
  "authServerUrl": "https://keycloak.example.com/auth",
  "realm": "wineco",
  "clientId": "wms2-frontend",
  "timezone": "America/Los_Angeles"
}
```
The `timezone` field must be present for all tenants. If it is absent or null in the response, the frontend defaults to `'UTC'` (see Phase 4.0.1 — `tenantConfig.timezone || 'UTC'`), which will display wrong local times. Verify the field is populated in the landlord DB `tenant_discovery` table before Deploy 3 (§0.6 Step 5).

#### 4.0.1 `plugins/initTenantAuth.client.js` (both UIs)

**Current code** (after Keycloak config injection — the existing plugin ends here):
```javascript
localStorage.setItem('tenantKeycloakConfig', JSON.stringify(keycloakConfig))
inject('tenantKeycloakConfig', keycloakConfig)
// MISSING: timezone capture
```

**Add immediately after the `inject(...)` call:**
```javascript
// Persist warehouse timezone for the app's lifetime
const warehouseTimezone = tenantConfig.timezone || 'UTC'
localStorage.setItem('warehouseTimezone', warehouseTimezone)
store.dispatch('setWarehouseTimezone', warehouseTimezone)
```

The `store` parameter is already available in Nuxt client plugins via the plugin context (`({ app, store }, inject) => {}`). No additional imports required.

This ensures that on cold start (fresh page load) the timezone is stored in `localStorage` (survives refresh) and committed to the Vuex root store (reactive, available during SSR hydration and throughout the SPA lifecycle).

#### 4.0.2 `store/index.js` (both UIs — root Vuex store)

Add `warehouseTimezone` to the existing `state`, `mutations`, and `actions` objects:

```javascript
// In state: (initialise from localStorage so page refresh doesn't lose the value)
warehouseTimezone: localStorage.getItem('warehouseTimezone') || 'UTC',

// In mutations:
setWarehouseTimezone(state, payload) {
  state.warehouseTimezone = payload
},

// In actions:
setWarehouseTimezone(context, timezone) {
  context.commit('setWarehouseTimezone', timezone)
  localStorage.setItem('warehouseTimezone', timezone)
},
```

**Why root store (not a module):** Both UIs have a single root `store/index.js` with no dedicated `system` or `settings` Vuex module. Placing `warehouseTimezone` at the root makes it accessible as `store.state.warehouseTimezone` and `this.$store.state.warehouseTimezone` everywhere without module namespacing. The `dateFormatter.js` plugin reads it as `store?.state?.warehouseTimezone` (see Phase 4.3).

**Why `localStorage` in both `initTenantAuth` and the action?** The action is the single write point for any future programmatic update (e.g. warehouse-switch). Writing to `localStorage` inside the action keeps the two stores in sync regardless of call site; `initTenantAuth` dispatches through the action rather than writing `localStorage` directly.

#### 4.0.3 Lifecycle of the timezone value

| Event | What happens |
|-------|-------------|
| App cold start | `initTenantAuth` fetches `authConfig` → reads `tenantConfig.timezone` → stores in `localStorage` + dispatches `setWarehouseTimezone` → Vuex state updated |
| Page refresh (SSR/SPA hydration) | Vuex `state.warehouseTimezone` initialised from `localStorage.getItem('warehouseTimezone')` — no extra API call needed |
| `dateFormatter.js` formatting call | Reads `store?.state?.warehouseTimezone` at call time — always current |
| Warehouse switch (future) | New `initTenantAuth` call → dispatch `setWarehouseTimezone` → both `localStorage` and Vuex updated |

### 4.1 API Response Format Change `[Round 2 fix — M6]`

After migration, Jackson serializes timestamps in UTC ISO-8601:
- **Before:** `"2026-02-10 14:30:00"` (LA time, no offset, format: `yyyy-MM-dd HH:mm:ss`)
- **After:** `"2026-02-10T22:30:00.000Z"` (UTC with Z suffix)

The frontends must convert UTC to warehouse-local time for display. The warehouse timezone string is available from `tenant_discovery.timezone` — bootstrapped at app startup via `GET /api/public/authConfig` in `plugins/initTenantAuth.client.js` (Phase 4.0). `[Round 8 fix]` Removed stale reference to "system properties API endpoint" — warehouse timezone is NOT loaded via sysprops; it comes from `tenant_discovery.timezone` via `initTenantAuth` (see Phase 4.0).

`[Round 2 fix — M6]` The backend feature flag `API_TIMESTAMP_FORMAT` (Phase 2.9) allows the DB migration to go out first and the API format switch to follow only after both frontends are confirmed updated. Mobile UI and web UI have separate release cadences — coordinate deploys accordingly. Force-logout active sessions when the flag is flipped to `ISO8601_UTC`.

### 4.2 Fix Frontend Timezone Configuration

**wms2-web-ui (`nuxt.config.js`):**
- Keep buildModules-level config (the active one)
- **Remove** the conflicting `publicRuntimeConfig.moment` (unused, contradicts with `America/New_York`)
- Change `defaultTimezone` to use a dynamic value from the warehouse timezone setting or remove the default entirely (since we'll use explicit `.tz()` calls)

**wms2-mobile-ui (`nuxt.config.js`):**
- **Add** a `moment:` config block:
```javascript
moment: {
  timezone: true,
  // No defaultTimezone - we'll use explicit .tz() calls with warehouse timezone
},
```
- Remove the unused `publicRuntimeConfig.moment` block

### 4.3 Create Centralized Date Formatting Plugin `[Round 2 fix — M6]`

**File:** `plugins/dateFormatter.js` (same file for both projects)

`[Round 2 fix]` Add dual-format `safeParse` to handle both the legacy bare format and the new ISO-8601 UTC format during the transition window (when `API_TIMESTAMP_FORMAT=LEGACY` is still active on some deployments):

```javascript
export default ({ app, store }, inject) => {
  const getWarehouseTz = () => {
    // [Round 6 fix] root store (no system module), default UTC matches tenant_discovery column default
    return store?.state?.warehouseTimezone || 'UTC'
  }

  // safeParse handles BOTH:
  //   Old: "2026-02-10 14:30:00"  (LA-local, no offset)
  //   New: "2026-02-10T22:30:00.000Z" (UTC, ISO-8601)
  const safeParse = (value) => {
    if (!value) return null
    // Presence of 'T' + 'Z' or offset → ISO-8601 UTC → parse as-is, .tz() will convert
    if (typeof value === 'string' && /T.*[Z+]/.test(value)) {
      return app.$moment(value)
    }
    // Legacy bare format → interpret as warehouse-local (no offset present)
    return app.$moment.tz(value, 'YYYY-MM-DD HH:mm:ss', getWarehouseTz())
  }

  inject('formatDateTime', (value) => {
    const m = safeParse(value)
    if (!m) return ''
    return m.tz(getWarehouseTz()).format('MM/DD/YYYY h:mm:ss a')
  })

  inject('formatDate', (value) => {
    const m = safeParse(value)
    if (!m) return ''
    return m.tz(getWarehouseTz()).format('MM/DD/YYYY')
  })

  inject('formatDateShort', (value) => {
    const m = safeParse(value)
    if (!m) return ''
    return m.tz(getWarehouseTz()).format('MM/DD/YY')
  })

  inject('formatTimeOnly', (value) => {
    const m = safeParse(value)
    if (!m) return ''
    return m.tz(getWarehouseTz()).format('h:mm:ss a')
  })

  inject('formatDateTimeShort', (value) => {
    const m = safeParse(value)
    if (!m) return ''
    return m.tz(getWarehouseTz()).format('MM/DD/YY h:mm:ss a')
  })

  // For sending dates back to API (convert warehouse-local to UTC ISO string)
  inject('parseDateForApi', (value) => {
    if (!value) return null
    return app.$moment.tz(value, getWarehouseTz()).utc().toISOString()
  })

  // For date pickers (date-only, no timezone conversion needed)
  inject('formatDateForPicker', (value) => {
    if (!value) return null
    return app.$moment(value).format('YYYY-MM-DD')
  })
}
```

### 4.4 Refactor Component Date Methods

Replace all 70+ component-local `getDate()`, `getTimeDate()`, `formatDate()` methods with centralized plugin calls.

| Before (component method) | After (injected method) |
|---------------------------|------------------------|
| `this.$moment(value).format('MM/DD/YYYY h:mm:ss a')` | `this.$formatDateTime(value)` |
| `this.$moment(value).format('MM/DD/YYYY')` | `this.$formatDate(value)` |
| `this.$moment(value).format('MM/DD/YY h:mm:ss a')` | `this.$formatDateTimeShort(value)` |
| `this.$moment(value).format('MM/DD/YY')` | `this.$formatDateShort(value)` |
| `this.$moment(value).format('h:mm:ss a')` | `this.$formatTimeOnly(value)` |

**Key components to update (wms2-web-ui, non-exhaustive):**
- `stockUnitRecord.vue` -- also fix hardcoded `'Time Stamp (EST)'` header
- `openTransfers.vue`, `closedTransfers.vue`
- `openNoticeDescription.vue`, `closedNoticeDescription.vue`
- `parcelDetails.vue`, `transferDetails.vue`
- `openParcels.vue`, `closedParcels.vue`
- `inventoryReport.vue`, `receivingReport.vue`
- `editRepleishmentRequest.vue` -- currently uses `'MM/DD/YYYY hh:mm a z'`

### 4.5 Update Date Picker Round-Trip

Date pickers currently send `YYYY-MM-DD` format strings. Since `date` columns are NOT converted to `timestamptz`, the picker behavior is unchanged for pure date fields.

**`transferDetails.vue:164` sends `'YYYY-MM-DD h:mm:ss'` format** -- update if the API now expects ISO-8601:
```javascript
// Before:
parseDate(date) { return this.$moment(date).format('YYYY-MM-DD h:mm:ss') }
// After:
parseDate(date) { return this.$formatDateForPicker(date) }
```

### 4.6 Warehouse Timezone in Vuex Store `[Round 6 fix — superseded]`

`[Round 6 fix]` The original approach (load from `System Time Zone` sysprop via a `loadSystemSettings` action) is **superseded**. Warehouse timezone is now captured directly in `plugins/initTenantAuth.client.js` at app startup from `tenant_discovery.timezone` — the same HTTP call that bootstraps Keycloak config. No additional system-properties API call is required.

See **Phase 4.0** for the complete implementation (Vuex root store additions + `initTenantAuth` changes).

### 4.7 Frontend → Backend Timestamp Contract `[Round 7 fix — NEW]`

Phase 4 focuses heavily on the **display** direction (UTC response → warehouse-local display). This section covers the **write** direction: what format the frontend must send when posting datetime values back to the API.

| Field category | Wire format from frontend | Helper | Example fields |
|---------------|--------------------------|--------|----------------|
| Pure `date` columns (`LocalDate`) | `"YYYY-MM-DD"` — no time, no timezone | none — unchanged | `pickingdate`, `shipped`, `dayofdelivery`, `dayofdeliveryuntil` |
| `timestamptz` fields in request bodies | UTC ISO-8601 `"2026-02-10T22:30:00.000Z"` | `$parseDateForApi(value)` | `receiptdate`, any user-entered datetime |
| Transaction-report `startDate`/`endDate` | Warehouse-local `"yyyy-MM-dd HH:mm:ss"` — **do NOT convert to UTC** | none — raw picker string | `POST /rest/getTransactionSummaryReport`, `POST /rest/getTransactionDetailedReport` |

**Rule for `timestamptz` fields:** Before POSTing or PUTting a user-selected datetime to the API, convert the warehouse-local picker value to UTC using the `$parseDateForApi` helper (Phase 4.3):

```javascript
// User picked "02/10/2026 12:00:00 AM" in the warehouse timezone
const utcString = this.$parseDateForApi(pickedValue)
// → "2026-02-10T08:00:00.000Z"  (if warehouse is America/Los_Angeles)
// Send utcString in the request body
```

Jackson on the backend deserializes UTC ISO-8601 strings correctly after `spring.jackson.time-zone=UTC` is set (Phase 2.1). Do NOT send bare `"yyyy-MM-dd HH:mm:ss"` warehouse-local strings for `timestamptz` fields — Jackson would interpret them as UTC, producing an 8-hour offset error.

**Why most fields are unaffected in practice:** The majority of `timestamptz` values in wms2-api are **server-generated** (audit `created`/`modified` via `@CreatedDate`/`@LastModifiedDate`, job timestamps, OMS notification timestamps). The frontend rarely sends a user-entered `LocalDateTime` back to the API. The main risk surface is datetime pickers on edit forms.

**Audit checklist** — before Deploy 3, scan all Vue components that POST or PUT to the API and verify each datetime field:

1. **`date` column** → send `"YYYY-MM-DD"` as-is (no conversion needed)
2. **`timestamptz` column** → wrap with `this.$parseDateForApi(value)` before sending
3. **Transaction-report date pickers** → send warehouse-local string as-is (no `$parseDateForApi`)

**Known instance requiring attention:** `transferDetails.vue:164` — currently sends `'YYYY-MM-DD h:mm:ss'` format (Phase 4.5). Confirm whether the backing column is a `date` or `timestamptz` field; if `timestamptz`, switch to `$parseDateForApi`.

**Recommended: `$parseTransactionReportDate` helper `[Round 8 fix — MAJOR-3]`:**

The transaction-report carve-out (row 3 in the table above) is currently enforced only by documentation. To make the contract typed and machine-verifiable, add a dedicated helper to `plugins/dateFormatter.js`:

```javascript
// Returns warehouse-local string in "YYYY-MM-DD HH:mm:ss" format — the exact wire format
// required by POST /rest/getTransactionSummaryReport and POST /rest/getTransactionDetailedReport.
// Do NOT use $parseDateForApi for these endpoints — it would convert to UTC and double-convert.
// Input: a naive warehouse-local string in "YYYY-MM-DD HH:mm:ss" format ONLY.
// [Round 9 fix — MAJOR-1]: format string added to moment.tz() to prevent silent UTC parse
//   when pickerValue is already ISO-8601 UTC (which moment would misinterpret without format).
// [Review fix — HIGH-2]: use app.$moment.tz() not bare moment.tz — bare moment is not injected
//   by @nuxtjs/moment and throws ReferenceError at runtime in Nuxt plugin context.
// [Review fix — MAJOR-2]: fail-fast on non-string input to catch misuse early (e.g., a Date
//   object or ISO-8601 UTC string passed here instead of $parseDateForApi).
$parseTransactionReportDate(pickerValue) {
  if (typeof pickerValue !== 'string') {
    throw new TypeError(
      '$parseTransactionReportDate expects a warehouse-local string in "YYYY-MM-DD HH:mm:ss" format; ' +
      `got ${typeof pickerValue}. Do NOT use $parseDateForApi for transaction-report endpoints.`
    )
  }
  const tz = getWarehouseTz()
  // Explicit format avoids moment guessing input TZ from ISO-8601 Z suffix
  return app.$moment.tz(pickerValue, 'YYYY-MM-DD HH:mm:ss', tz).format('YYYY-MM-DD HH:mm:ss')
}
```

Inject via `inject('parseTransactionReportDate', ...)` alongside the other helpers in `plugins/dateFormatter.js`.

**Pre-deploy audit — wiring `$parseTransactionReportDate` to call sites `[Round 9 fix — HIGH-3]`:**

Run the following grep before Deploy 3 to find every Vue component that calls the transaction-report endpoints, then verify each uses `$parseTransactionReportDate` (not `$parseDateForApi` or raw strings):

```bash
grep -rn "getTransactionSummaryReport\|getTransactionDetailedReport" \
  v2/wms2-web-ui/components/ v2/wms2-web-ui/pages/ \
  v2/wms2-mobile-ui/components/ v2/wms2-mobile-ui/pages/ \
  --include="*.vue"
```

Every hit must either (a) send the date-picker value directly as a warehouse-local `"YYYY-MM-DD HH:mm:ss"` string (no conversion), or (b) call `this.$parseTransactionReportDate(value)`. Any hit that calls `this.$parseDateForApi(value)` is a double-conversion bug. This grep forms part of the Deploy 3 pre-flight checklist.

---

## Phase 5: Post-Migration Cleanup & Hardening

### 5.1 Fix JPA Auditing

After migration to UTC, verify that audit timestamps are populated in UTC. `LocalDateTime` with `@CreatedDate` will use the JVM timezone (now UTC) — correct behavior.

### 5.2 Consider Migrating from `LocalDateTime` to `Instant`

Long-term, entities should use `java.time.Instant` instead of `LocalDateTime` for timestamp fields. `Instant` is inherently UTC and maps naturally to `timestamptz`. `OutboxMessage.java` already uses `Instant` — a good pattern to follow. This is a large refactor (88+ fields across 44 entities) and can be done incrementally.

### 5.3 Consolidate Remaining `new ObjectMapper()` Instances

Any instances not fixed in Phase 2.7 should be consolidated. Create a shared `ObjectMapperFactory` or utility if injection is impractical in all locations.

### 5.4 Remove Dead Timezone Config

`[Round 7 fix]` The three `application.properties` lines (`#user.timezone=America/New_York`, `spring.jackson.time-zone=America/Los_Angeles`, `spring.jpa.properties.hibernate.jdbc.time_zone=America/Los_Angeles`) are **explicitly deleted in Phase 2.1** as part of Deploy 2 — they are not deferred to post-migration cleanup. Verify these lines are gone after Deploy 2 completes.

Remaining post-migration cleanup items:
- Remove `OrderReleaseJob.java:131` misleading comment about timezone (replace with accurate UTC-aware description after `TimezoneService` refactor)
- Update `OrderReleaseJob.java` to use `TimezoneService` instead of parsing the `System Time Zone` sysprop manually via `SimpleDateFormat`
- Audit remaining `#`-commented timezone references in any environment-specific properties files (e.g., `application_dev.properties`) and remove or update to UTC

<!-- [Round 4 fix — FIX R4-M2] -->
#### Phase 5.x — Startup Sysprop Validator `[Round 4 fix — FIX R4-M2]`

Add a `CommandLineRunner` (or `@PostConstruct` on `TimezoneService`) that at boot:
1. Iterates `tenantDbConfigurationRepository.findAll()`.
2. For each tenant, sets `TenantContext`, calls `timezoneService.getWarehouseZoneId()`,
   and catches `IllegalStateException` or UTC-fallback warnings.
3. Logs a WARN (not ERROR) if any tenant falls back to UTC — allows startup to complete
   but flags misconfigured tenants before they affect picking dates.

Pre-deploy manual check (run across all tenant DBs before deploy):
```sql
SELECT 'tenant_db_here' AS tenant_db, sysvalue
FROM los_sysprop WHERE syskey = 'System Time Zone';
-- Verify each value parses through parseToZoneId without falling back to UTC.
```

### 5.5 Sysprop is the sole timezone source `[Round 10 fix]`

`[Round 10 fix]` The `los_sysprop` `"System Time Zone"` key is the **single source of truth** for the per-tenant warehouse timezone — read by both `TimezoneService` (for business date logic) and `resolveWarehouseTz` (for the session GUC). There is no secondary source to consolidate; Phase 5.5 (previously "Leverage warehouse.timezone Column") is therefore removed.

`[Round 3 fix — FIX 9]` `[Round 10 fix]` **Long-term cache hardening:** Replace the `ConcurrentHashMap` in `TimezoneService` with a Caffeine cache (already used in wms2-api) with a 24-hour TTL. This allows timezone changes to propagate within one day without requiring a full restart. Until then, document that a restart is required after changing the `System Time Zone` sysprop.

### 5.6 Follow-up: Landlord DB `created`/`modified` Columns [Round 5 fix — critic NOTE]

**Out of scope for this migration but document as a follow-up.**
`TenantDbConfiguration` (in the landlord DB) has `created` and `modified` columns of type
`timestamp without time zone`, written by Hibernate `LocalDateTime` via the landlord DataSource.
After the JVM flips to UTC (Deploy 2), new rows in the landlord DB will be written with UTC
wall-clock into these `timestamp without time zone` columns — inconsistent with pre-migration rows
(which were LA wall-clock). This does not affect warehouse operations directly (it is
configuration/audit metadata), but the landlord DB should be migrated in a separate follow-up
task using the same `USING col AT TIME ZONE 'America/Los_Angeles'` approach for the pre-existing
rows. Track as a separate issue.

---

## Deployment Sequence `[Round 2 fix — M2]`

```
Phase 0: Pre-work (before any deploy)
   |
   | 1. Back up all tenant databases (pg_dump per tenant)
   | 2. Time a pg_restore on staging — establish RTO baseline
   | 3. Run rollback rehearsal (V1.2.99 on staged migrated DB)
   |    [Review fix — MAJOR-1] Measure the full rollback RTO during rehearsal (pg_restore time
   |    + V1.2.99 execution time). The total MUST fit within the 2-hour go/no-go window.
   |    Document the measured RTO in the deployment runbook. Also validate the soft-rollback path:
   |    revert only application config (LA hibernate.jdbc.time_zone), leave schema as timestamptz,
   |    add SET timezone='America/Los_Angeles' to connectionInitSql — time how long that takes.
   | 4. [Review fix — MAJOR-4] Audit StockrecordRepository HAL endpoints: run the following
   |    grep to determine if any active client (frontend, monitoring, OMS) calls
   |    `/api/stockrecord/search/transactionDetailByClientNumberAndSkuBetweenDates`.
   |    If yes, they must adjust date strings from LA midnight to UTC midnight after Deploy 2:
   |    `grep -rn "transactionDetailByClientNumberAndSkuBetweenDates" v2/ --include="*.vue" --include="*.js" --include="*.php"`
   | 5. [Review fix — MAJOR-5] OMS-side idempotency compatibility: verify with the OMS team
   |    that OMS-side timestamp parsing is compatible with UTC ISO-8601 format. The outbox
   |    dispatcher POSTs UTC timestamps to OMS after Deploy 2. If OMS parses timestamps as
   |    LA-local, a coordinated OMS update is required before or alongside Deploy 2.
   | 6. Name the decision owner in the deployment runbook
   v
Deploy 1 (Phase 1): Stabilize - pin JVM TZ in main(), fix 6 CronTriggers, fix SimpleDateFormat TZ pinning
   |
   | Verify everything works identically to before
   | Run full test suite, smoke test API, verify scheduled jobs
   v
<!-- [Round 4 fix — FIX R4-M7] -->
Deploy 2 (Phases 2+3): The Big Switch [MAINTENANCE WINDOW] `[Round 4 fix — FIX R4-M7]`
   |
   | <!-- [Round 5 fix — FIX R5-M1] Renumbered for clarity; removed duplicate "step 5: Take maintenance window" -->
   | 1. Enter maintenance mode / quiesce ALL incoming HTTP writes
   | 2. Wait 10 seconds for in-flight `afterCommit` callbacks
   |    (`OmsNotificationService` registers `TransactionSynchronizationManager.afterCommit()`
   |    callbacks; the pause ensures no HTTP POST fires against a closing connection pool)
   | 3. Drain OutboxDispatcherJob — wait for it to flush all PENDING rows (≤ 15s)
   |    Verify: SELECT COUNT(*) FROM outbox_message WHERE status IN
   |    ('PENDING','IN_FLIGHT','FAILED_RETRY') = 0
   | 4. [Round 3 fix — FIX 5] DELETE FROM rest_idempotency; (drain table — eliminates timezone ambiguity)
   |    DELETE FROM outbox_message WHERE status IN ('SENT','FAILED_TERMINAL'); (optional cleanup)
   | 5. **Before scaling to 0:** confirm zero IN_FLIGHT rows: `SELECT COUNT(*) FROM outbox_message WHERE status = 'IN_FLIGHT'` = 0. `[Round 9 fix]`
   |    If any IN_FLIGHT rows remain, either wait for the 5-minute stale-claim timeout (they become PENDING again on next dispatcher run) or accept the at-least-once re-delivery after restart.
   |    **Scale all wms2-api instances to 0.** `[Round 8 fix]`
   |    (Ensures no running instance interprets migrated timestamptz data with the old LA timezone config.
   |    Scale back to N replicas atomically in step 7 after the new image is deployed.)
   |    **INVARIANT `[Architect H2]`:** between scale-to-0 here and the new (UTC) image going live in
   |    step 7, ZERO old-image instances may hold a connection to ANY migrated tenant DB. A scaled-to-0
   |    deployment can be revived by an autoscaler, a liveness/auto-heal restart, or a stale replica that
   |    missed the scale signal. Disable autoscaling / auto-heal for the schema window (or revoke the old
   |    image's DB credentials), and CONFIRM no app connections remain before running V1.2.01:
   |      SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'HikariPool-%';  -- must be 0
   |    A surviving old-image instance writes LA-wall-clock into the new timestamptz columns → silent
   |    +8h corruption on every new row, exactly what scale-to-0 exists to prevent.
   |    Run V1.2.01–V1.2.05 per tenant (using psql runbook from §0.5 — preconditions steps 1–4 must be complete)
   | 6. Verify schema (run §Large-table migration verification queries; abort on any non-timestamptz column)
   | 7. Deploy new backend code with:
   |    - UTC application properties (hibernate.jdbc.time_zone=UTC, jackson.time-zone=UTC)
   |    - spring.jpa.properties.hibernate.type.preferred_instant_jdbc_type=TIMESTAMP_WITH_TIMEZONE
   |    - UTC JVM timezone (TZ=UTC env var or main() call)
   |    - TimezoneService utility (composite cache key; no-arg overload for request-scoped callers)
   |    - Per-tenant session timezone on connections (HikariCP connectionInitSql via
   |      resolveWarehouseTz() one-shot DriverManager reads `System Time Zone` from `los_sysprop`) `[Round 10 fix]`
   |    - Business logic fixes for warehouse TZ (7 file changes, corrected line numbers)
   |    NOTE: V1.2.01–V1.2.05 were already applied via psql in step 5; they are NOT run by the app at startup
   | 8. App starts → pool per-tenant connectionInitSql sets session timezone → app serves UTC
   | 9. Smoke test API responses (verify UTC format)
   |    [Review fix — HIGH-4] Per-tenant SHOW timezone verification: for each tenant connection
   |    confirm `SHOW timezone;` returns the correct IANA TZ (e.g. 'America/Los_Angeles'),
   |    NOT 'UTC' — this proves connectionInitSql fired and resolveWarehouseTz() succeeded.
   |    If any tenant shows 'UTC' and its sysprop is not 'UTC', the connectionInitSql was not
   |    set → investigate resolveWarehouseTz() log output before proceeding.
   | 10. Go/no-go decision: 2 hours window, decision owner named in runbook
   v
Deploy 3 (Phase 4): Frontend updates [IMMEDIATELY AFTER Deploy 2]
   |
   | Deploy updated wms2-web-ui and wms2-mobile-ui with:
   |    - Centralized date formatter plugin (with safeParse dual-format support)
   |    - [Round 6 fix] Warehouse timezone bootstrapped from tenant_discovery via initTenantAuth (Phase 4.0)
   |    - Refactored component date methods
   |    - Fixed timezone config inconsistencies
   v
Phase 2.9 flag flip: After both frontends confirmed updated
   |
   | Flip API_TIMESTAMP_FORMAT sysprop from LEGACY → ISO8601_UTC
   | Force-logout active sessions
   v
Phase 5: Cleanup (ongoing, lower priority)
```

---

## Files Modified Summary `[Round 2 fix]` `[Round 3 fix]`

### Phase 0 (Rollback) -- 1 new file
| File | Change |
|------|--------|
| `db/rollback/V1.2.99__rollback_utc_migration.sql` | **AUTHORED + round-trip-validated on PostgreSQL 16 (2026-06-03).** Manual rollback (NOT run via Flyway; kept in `db/rollback/` — NOT `db/migration/` — to avoid the V1.2.99-auto-undo hazard). PART 0 drop views → PART 1/2 Group A (LA) → PART 3 Group B (UTC) → PART 4 recreate views → **PART 5 restores the 3 functions to `timestamp`-without-tz signatures**. NY copy in `db/onboarding-tz-variants/`. |

### Phase 1 (Stabilize) -- 5 files — ✅ **IMPLEMENTED + verified 2026-06-03** (`mvn clean compile` exit 0; `OmsNotificationConfigContextLoadTest` Tests run:1, Failures:0). Behavior-preserving; not yet committed/deployed. `[v2: was 7; YYYY and static-SDF items removed as already done]`
| File | Change | Status |
|------|--------|--------|
| `StartApplication.java` | `[Round 2 fix]` `main()` calls `TimeZone.setDefault(getTimeZone("America/Los_Angeles"))` + `System.setProperty("user.timezone",...)` before `SpringApplication.run` (not `@PostConstruct`) | ✅ done |
| `SchedulingConfiguration.java` | Added `CRON_SCHEDULE_ZONE` constant; applied to all **6** `CronTrigger`s (now at lines 180/203/226/249/266/287 after the constant insert) | ✅ done |
| `WebConfigurer.java` | `TimeZone.getDefault()` → `TimeZone.getTimeZone("America/Los_Angeles")` (now line 73) | ✅ done |
| `OrderReleaseJob.java:131` | **No change** — existing code reads `System Time Zone` sysprop and sets it directly on `SimpleDateFormat`; do NOT hardcode `America/Los_Angeles`. Phase 5 cleanup will refactor to `TimezoneService`. `[Review fix — HIGH-3]` | ✅ n/a (confirmed) |
| `TransactionReportRestController.java` | Both report methods pin `SimpleDateFormat` to `America/Los_Angeles` (single reused instance; inline `new SimpleDateFormat(...).format()` removed) | ✅ done |

### Phase 2 (App Config) -- 12+ files `[Round 2 fix]` `[Round 3 fix]` `[Round 7 fix]`

> **Implementation status (2026-06-03, branch `feature/utc-timezone`, all TDD red→green):**
> - ✅ **2.4 `TimezoneService`** — committed `5d03706` (9/9 tests; Clock seam)
> - ✅ **2.5 `ReleaseOrderJobService:129`** (early release) — committed `ff1cc08`
> - ✅ **2.5 `BillofladingService:655` + `Billoflading.java:21` default** (BOL shipped) — committed `4e426f9`
> - ✅ **2.5 `CustomerorderService:254`** (picking-date→RAW) — committed `142e7ed`
> - ✅ **2.5 `OrderBatchCreationService:158/166`** (future-date guard + default picking date → `todayInWarehouse()`) — committed `4e5597a` (2 discriminating TDD tests; class 8/8 green)
> - ✅ **2.6 `TenantDynamicRoutingDataSource` connectionInitSql** — committed `f200a4c` (`resolveWarehouseTz()` one-shot DriverManager read of `los_sysprop` `System Time Zone`, `ZoneId.of()`-validated, sets `SET timezone='<iana>'`; context-load green)
> - ✅ **2.10 `ClientRepository` casts** (`::timestamp without time zone` → `::timestamptz` on the 2 report queries) — committed `31c2ef6`
> - ✅ **2.7/2.8 ObjectMapper consolidation** — committed `ae5e171`. New `util/WmsObjectMapper` (mirrors the `@Primary` bean: JavaTimeModule + `WRITE_DATES_AS_TIMESTAMPS` off + ISO `StdDateFormat` + `NON_NULL` + lenient unknowns; `shared()` read-only / `standard()` for mutation). All 41 non-skip ad-hoc `new ObjectMapper()` sites routed through it (locals + static `MAPPER`/`OBJECT_MAPPER` fields); `StartApplication.repositoryPopulator()` (2.8) too. Skipped `WebConfigurer` (the bean) + `SecurityConfiguration` (JWT). **Behavior delta (accepted):** WMS→OMS message-audit/notification payloads now emit ISO-8601 dates (UTC after 2.2) + drop nulls, and java.time payloads serialize instead of silently failing as swallowed `IOException`.
> - ✅ **2.1/2.2/2.3 UTC config flips** — committed `7a5c616` (the behavior-changing switch, held until last). `application.properties` `jackson`+`hibernate.jdbc.time_zone`→UTC + `preferred_instant_jdbc_type=TIMESTAMP_WITH_TIMEZONE` + dropped dead `#user.timezone`; `StartApplication.main()` JVM→UTC; `WebConfigurer` jsonCustomizer `builder.timeZone`→UTC (legacy format strings kept — ISO-8601-with-Z gated behind 2.9 `API_TIMESTAMP_FORMAT`). ⚠️ **Deploy-coupled:** must ship in the SAME window as the Phase 3 schema migration (columns→`timestamptz`); runtime UTC behavior to be validated on staging per the DST boundary test cases below.
> - ✅ **2.9 `API_TIMESTAMP_FORMAT` per-tenant wire-format flag** — committed `a60901e` (2026-06-06). New `util/json/ApiTimestampFormatResolver` (`BooleanSupplier`, reads `API_TIMESTAMP_FORMAT` sysprop via `SyspropService` per `TenantContext`; **fails safe to LEGACY** when the sysprop is absent / no tenant scope / lookup error) + shared `ApiTimestampFormats` patterns + four UTC-instant serializers (`UtcDateSerializer`, `UtcInstantSerializer`, `UtcLocalDateTimeSerializer`, `UtcOffsetDateTimeSerializer`) wired into `WebConfigurer`; `WmsConstants` gains `SYSTEM_PROPERTY_API_TIMESTAMP_FORMAT_KEY` + `API_TIMESTAMP_FORMAT_ISO8601_UTC`. `ApiTimestampFormatTest` green. **No `los_sysprop` row is required for the default LEGACY behavior** — the row is created/set to `ISO8601_UTC` **per tenant only at flip time, after both frontends ship** (see Phase 2.9 + deployment step "Flip `API_TIMESTAMP_FORMAT` LEGACY → ISO8601_UTC"). Horizontal-scaling caveat: the flip only evicts the `sysprops` cache on the writing replica — flip in a maintenance window with session force-logout, not as a hot toggle.
> - **🏁 Phase 2 is code-complete on `feature/utc-timezone`.** Remaining for the migration: Phase 3 DB migration scripts authored (not yet applied), Phase 4 frontend, and the deploy itself.
> - **Verification (2026-06-03):** 2.5/2.6/2.10 → `mvn clean test -Dtest=OmsNotificationConfigContextLoadTest,OrderBatchCreationServiceUnitTest,TimezoneServiceUnitTest` BUILD SUCCESS 18/18. 2.7/2.8 → full unit suite `mvn clean test -Dtest='net.aim_ai.wms.unit.**,OmsNotificationConfigContextLoadTest'` (4130 tests) introduced **no new failures**; context loads. ✅ The 14 pre-existing branch failures (unrelated to UTC) are now **fixed** in `99aae65` (stale tests after deliberate develop changes — `UnitloadBusinessServiceUnitTest` `@Mock EntityManager` not wired into the `@PersistenceContext` field [SBDEV-2229]; `UtilRestControllerUnitTest$ResetOrdersInReleasedStatus` skip-and-continue [SBDEV-2238]; `RestExceptionHandlerUnitTest$HandleNoSuchElement` NoSuchElement→500 [SBDEV-2218]). **Branch unit suite now fully green: `mvn clean test` 4130 tests, 0 failures, 0 errors.** Not yet committed-to-`develop`/deployed; lives on `feature/utc-timezone`.

| File | Change |
|------|--------|
| `application.properties` | `[Round 7 fix]` **DELETE** lines 105 (`#user.timezone=America/New_York`), 107 (`spring.jackson.time-zone=America/Los_Angeles`), 108 (`spring.jpa.properties.hibernate.jdbc.time_zone=America/Los_Angeles`). **ADD** UTC replacements + `preferred_instant_jdbc_type`. See Phase 2.1 diff. `[Round 4 fix — FIX R4-C3]` |
| `StartApplication.java` | `[Round 2 fix]` Change `main()` to UTC; fix `repositoryPopulator()` ObjectMapper |
| `WebConfigurer.java` | Explicit UTC timezone; update date format to ISO-8601 |
| New `TimezoneService.java` | ✅ **IMPLEMENTED + TDD (2026-06-03, commit `5d03706`).** `[Round 3 fix — FIX 4]` `[Round 10 fix]` Composite-key cache; reads `System Time Zone` from `los_sysprop` via `SyspropService.getSysvalue(...)`; `parseToZoneId()` normalises formatting and falls back to UTC + WARN. **Added a `java.time.Clock` seam** (single-arg `@Autowired` ctor defaults to `Clock.systemUTC()`; `(SyspropService, Clock)` ctor for tests) so the UTC-rollover scenarios are deterministically testable. `TimezoneServiceUnitTest` 9/9 green (parse matrix + LA/UTC+ `todayInWarehouse` rollover). |
| `service/job/ReleaseOrderJobService.java:121` | Use `timezoneService.todayInWarehouse()` |
| `service/CustomerorderService.java:248` | Use `timezoneService.todayInWarehouse()` |
| `service/BillofladingService.java:655` | Use `timezoneService.todayInWarehouse()` |
| `model/Billoflading.java:21` | Remove `LocalDate.now()` field default |
| `schedulejob/ReplenishOrderJob.java:371,405` | **No code change required** — `java.util.Date` (UTC instant) compared against `date` column via native query; session-TZ midnight cast makes comparison correct (see Scenario D). `[Round 9 fix — corrects Round 8 CRITICAL-1 stale entry]` |
| `service/OrderBatchCreationService.java:158,166` | `[Round 3 fix — FIX 6]` Use `timezoneService.todayInWarehouse()` no-arg — request-scoped, TenantContext is set |
| `landlord/config/TenantDynamicRoutingDataSource.java` | `[Round 3 fix — FIX 3]` `[Round 10 fix]` Add `resolveWarehouseTz(tc)` one-shot DriverManager query reading `System Time Zone` from `los_sysprop` + `connectionInitSql` with IANA validation. No `facilityCode` parameter (sysprop is per-tenant-DB). `[Round 4 fix — FIX R4-M3]` no `warehouseTimezone` field exists on `TenantDbConfiguration` — nothing to remove |
| 46 files with `new ObjectMapper()` | Inject Spring-managed ObjectMapper (prioritized list in 2.7) |

### Phase 3 (Database) -- 5 new files `[Round 2 fix]` `[Round 3 fix]` `[2026-06-03: +V1.2.05]`

> ✅ **Committed to `feature/utc-timezone` (`b59851e`, 2026-06-03):** all 5 forward scripts
> (`db/migration/V1.2.01–05`), `db/rollback/V1.2.99`, and `db/onboarding-tz-variants/` (NY V1.2.01/02/99 + README). **Authored + PG16-validated, NOT yet applied to any real tenant DB** — applied per-tenant via the §0.5 psql runbook in the same maintenance window as the Phase 2 backend deploy.

| File | Change |
|------|--------|
| `V1.2.01__utc_standard_tables.sql` | **AUTHORED + validated against PostgreSQL 16 (2026-06-03).** Group A: 40 standard tables (`created`/`modified`) + `goodsreceipt.receiptdate` = 81 `ALTER`s with `USING … AT TIME ZONE 'America/Los_Angeles'`. Wrapped in `BEGIN/COMMIT`; idempotency canary (`advice.created`); pre-migration outbox-drain safety check; post-migration assertion. **Drops all 11 views first** (recreated by V1.2.05). |
| `V1.2.02__utc_large_tables.sql` | **AUTHORED + validated against PostgreSQL 16 (2026-06-03).** Large tables `stockrecord`/`unitload_record`/`inventory_record`/`pickingorder_position` — 9 cols incl. reserved-word `inventory_record."timestamp"`. Non-transactional: one **per-table `DO` block** each (autocommits separately under psql), guarded `IF still 'timestamp without time zone'` so the file is **idempotent + resumable** (re-run skips converted tables, no double-shift — verified) and each table rewrites once. `SET lock_timeout=0; SET statement_timeout=0`. No view drops needed (V1.2.01 already dropped them; no view depends on large-table cols — confirmed via `pg_depend` on hydra-uat). |
| `db/onboarding-tz-variants/V1.2.01…_America_New_York.sql`, `…V1.2.02…_America_New_York.sql` | **NEW (2026-06-03) — NY client variants (§0.6 Step 4), validated on PG16.** `AT TIME ZONE 'America/New_York'`. Kept OUTSIDE `db/migration/` to avoid a duplicate-`V1.2.0x` Flyway-version collision. For v1 clients written NY wall-clock (e.g. `wms2-hydra-uat`, sysprop = `America/New_York`); proven `08:24 EST → 13:24 UTC` through the script. See the dir's `README.md`. |
| `V1.2.03__utc_outbox_and_new_tables.sql` | NEW -- `[Round 3 fix — FIX 1]` `customerorder_old` removed; `[Round 10 fix]` `warehouse` section removed (table out of scope); `[Round 3 fix — FIX 5]` `rest_idempotency` uses `AT TIME ZONE 'UTC'` (drained, native INSERT NOW()) |
| `V1.2.04__utc_recreate_views.sql` | **AUTHORED + validated against PostgreSQL 16 (2026-06-03).** Recreates all 11 reporting views verbatim (latest canonical defs from `V1.0.02`/`V1.1.01`/`V2.1.03`) now over `timestamptz`; idempotent (`DROP VIEW IF EXISTS … CASCADE` then `CREATE`); `BEGIN/COMMIT` + post-recreate assertion (11 views). **Must run BEFORE V1.2.05** — `stock_history` RETURNS `stock_view.%TYPE`. (Was V1.2.05 until the 2026-06-03 swap.) |
| `V1.2.05__utc_update_functions.sql` | **AUTHORED + validated against PostgreSQL 16 (2026-06-03).** Recreates the 3 functions with `timestamptz` params (+ `transaction_detail.transaction_date` return). DROPs old `timestamp`-signature overloads first (a type change = new overload), then `CREATE` in dependency order (`stock_history` first). Verbatim bodies from `V1.0.03`/`V2.1.07`/`V1.1.04`. Runs LAST (needs `stock_view` from V1.2.04). (Was V1.2.04 until the swap.) |
| `ClientRepository.java:54-65` | `[Round 2 fix]` Change `::timestamp without time zone` casts to `::timestamptz` |
| `db/rollback/V1.2.99__rollback_utc_migration.sql` | **AUTHORED + round-trip-validated (2026-06-03).** See Phase 0 row above. PART 5 restores the 3 stored functions to `timestamp`-without-tz signatures (PART 4 recreates views first — `stock_history` %TYPE). |
| `db/migration/V2.1.15__add_api_timestamp_format_sysprop.sql` | **NEW (2026-06-07) — Phase 2.9.** Seeds the `API_TIMESTAMP_FORMAT` sysprop at default `LEGACY` (the resolver's wire-format flag). `id = MAX(id)+1`; composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`; `workstation = 'DEFAULT'` to match `SyspropRepository.findSysvalueBySyskey`. Validated (SELECT-portion) against `wms2-wineco-dev`. Included in the §0.6 apply-loop. **Not a UTC `V1.2.x` schema script — it's a sysprop seed in the `V2.1.x` lineage** (forward-only; Flyway-safe if ever enabled). Cutover to `ISO8601_UTC` is a later per-tenant `UPDATE`, post-frontend. |

### Phase 4 (Frontend) -- 70+ files across 2 projects `[Round 6 fix]` `[Round 7 fix]`
| Area | Change |
|------|--------|
| `wms2-web-ui/nuxt.config.js` | Remove conflicting publicRuntimeConfig.moment |
| `wms2-mobile-ui/nuxt.config.js` | Add moment timezone config block |
| `plugins/initTenantAuth.client.js` (both UIs) | `[Round 6 fix]` Add timezone capture after Keycloak inject: read `tenantConfig.timezone`, store in `localStorage('warehouseTimezone')`, dispatch `setWarehouseTimezone` |
| `store/index.js` (both UIs) | `[Round 6 fix]` Add `warehouseTimezone` state (seeded from `localStorage`), `setWarehouseTimezone` mutation + action |
| `plugins/dateFormatter.js` (both projects) | NEW -- centralized date formatting with warehouse TZ + dual-format `safeParse`; `$parseDateForApi` for warehouse-local → UTC conversion before POST/PUT |
| 70+ Vue components | Replace component-local date methods with `$formatDate()` etc. |
| `transferDetails.vue:164` | Fix `parseDate()`: confirm column type; if `timestamptz` → use `$parseDateForApi`; if `date` → use `$formatDateForPicker` |
| `stockUnitRecord.vue` | Remove hardcoded `'Time Stamp (EST)'` |
| Transaction-report date pickers (both UIs) | `[Round 7 fix]` Verify pickers send warehouse-local strings as-is (no `$parseDateForApi`) — see Phase 4.7 audit checklist |

---

## Verification Plan `[Round 2 fix — M9]`

### Phase 1
- `mvn test` -- all existing tests pass
- Compare API date responses before/after (should be identical)
- Verify scheduled jobs fire at correct times (all 6 cron jobs)

### Phase 2 + 3

**Pre-deploy:**
- Back up all tenant databases
- Drain `outbox_message` table (quiesce writes → wait for dispatcher → verify 0 rows in PENDING/IN_FLIGHT/FAILED_RETRY)
- `[Round 3 fix — FIX 5]` `DELETE FROM rest_idempotency;` on each tenant DB — eliminates timezone ambiguity; rows expire within 7 days anyway
- Run pre-deploy audit: `grep -rn "::timestamp\b\|timestamp without time zone" v2/wms2-api/src/main/java/ --include="*.java"` — must return zero
- Confirm free disk > total DB size (`SELECT pg_size_pretty(pg_database_size(current_database()))`)

**DST boundary test cases (run on staging BEFORE production):** `[Round 2 fix — M9]`
- Insert a row with `created = '2026-03-08 01:59:59'` (1 second before spring-forward in LA), verify migration produces `2026-03-08 09:59:59+00` (UTC)
- Insert a row with `created = '2026-03-08 03:00:00'` (post-spring-forward in LA), verify migration produces `2026-03-08 10:00:00+00` (UTC)
- Insert an `outbox_message` row with `created_at = '2026-03-08 09:59:59'` (UTC wall-clock), verify migration produces `2026-03-08 09:59:59+00` (unchanged — no shift)
- After Phase 2 app switch: create an order at simulated 11:30 PM LA time, verify `pickingdate = today LA` (not tomorrow UTC)

<!-- [Round 4 fix — FIX R4-M6] -->
##### DST fall-back boundary — November 1, 02:00→01:00 (ambiguous hour) `[Round 4 fix — FIX R4-M6]`

```sql
-- [Round 5 fix — critic QA-MINOR] Use SELECT clone instead of bare INSERT to avoid NOT NULL column list
-- Copy an existing advice row and override created/modified to the ambiguous fall-back timestamp
INSERT INTO advice
  SELECT id + 9000000, client_id, facility_code, ...,  -- clone all NOT NULL cols from an existing row
         '2025-11-01 01:30:00'::timestamp,              -- created: ambiguous LA fall-back hour
         '2025-11-01 01:30:00'::timestamp               -- modified
  FROM advice LIMIT 1;

-- OR on a staging Testcontainers DB — insert the minimum required columns directly:
-- INSERT INTO advice (id, ...<required cols>..., created, modified)
-- VALUES (9999999, ..., '2025-11-01 01:30:00', '2025-11-01 01:30:00');

-- After migration with USING created AT TIME ZONE 'America/Los_Angeles':
-- PostgreSQL resolves ambiguous fall-back-hour times as PDT (UTC-7) by default.
-- Expected result: '2025-11-01 08:30:00+00' (PDT interpretation, UTC-7)
-- NOT:            '2025-11-01 09:30:00+00' (PST interpretation — UTC-8)
SELECT created AT TIME ZONE 'UTC' AS created_utc FROM advice WHERE id = 9000001;
-- Must equal '2025-11-01 08:30:00'
```

**Residual risk (document in Risk Mitigation table):**
Rows written by the application during the fall-back ambiguous hour (01:00–02:00 LA
on the first Sunday of November each year) stored a LA wall-clock value that is
irresolvably ambiguous — the same wall-clock instant could be PDT or PST.
PostgreSQL's `AT TIME ZONE` picks PDT (UTC-7). Rows that were actually written at
the PST interpretation will be shifted by 1 hour. This affects roughly 1 hour of
data per year; the shift is silent and cannot be corrected without per-row
application-level metadata. **Accepted residual risk.**

**Post-deploy spot checks:** `[Round 2 fix — M9]`
```sql
-- Verify UTC stored, LA display matches expected
SELECT id, created, created AT TIME ZONE 'America/Los_Angeles' AS created_la
FROM advice LIMIT 5;

-- Verify outbox timestamps unchanged (were UTC before, still UTC)
SELECT id, created_at AT TIME ZONE 'UTC' AS should_match_original
FROM outbox_message LIMIT 5;

-- Verify CURRENT_DATE returns warehouse-local date via session timezone
SELECT CURRENT_DATE;  -- run against a tenant connection with session TZ set

-- [Review fix — LOW-4] Verify session timezone was set correctly by connectionInitSql
SHOW timezone;
-- Must return the tenant's IANA timezone (e.g. 'America/Los_Angeles'), NOT 'UTC'.
-- If it returns 'UTC' and the tenant sysprop is not UTC, resolveWarehouseTz() failed silently
-- — check application ERROR logs for the CRITICAL-1 log message.

-- Verify outbox partial index rebuilt
SELECT indexname FROM pg_indexes
WHERE tablename = 'outbox_message' AND indexname = 'index_outbox_message_dispatch';

-- Post-migration statistics refresh
ANALYZE advice, billoflading, customerorder, stockrecord, unitload_record,
        inventory_record, pickingorder_position, outbox_message;
```

<!-- [Round 4 fix — FIX R4-M5] -->
#### Large-table migration verification (V1.2.02) `[Round 4 fix — FIX R4-M5]`

⚠️ `spring.jpa.hibernate.ddl-auto=none` — Hibernate does NOT validate the schema at
startup. These queries are the **only** guard against a partial V1.2.02 migration
leaving a split-brain schema.

**Schema verification** (run per tenant DB immediately after V1.2.02 completes):
```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('stockrecord','unitload_record','inventory_record','pickingorder_position')
  AND column_name IN ('created','modified','timestamp')
ORDER BY table_name, column_name;
-- REQUIRED: every row must show data_type = 'timestamp with time zone'
-- Any 'timestamp without time zone' row = partial migration → ABORT and run V1.2.99
```

**Row-count verification** (compare against pre-migration baseline recorded in Phase 0.1):
```sql
SELECT 'stockrecord'          AS tbl, COUNT(*) AS cnt FROM stockrecord
UNION ALL SELECT 'unitload_record',        COUNT(*) FROM unitload_record
UNION ALL SELECT 'inventory_record',       COUNT(*) FROM inventory_record
UNION ALL SELECT 'pickingorder_position',  COUNT(*) FROM pickingorder_position;
-- Counts must match pre-migration values (±0 rows expected; no INSERT during maintenance window)
```

**Additional post-deploy checks:**
1. Hit API endpoint that returns timestamps -- verify ISO-8601 UTC format (`"2026-02-10T22:30:00.000Z"`) once feature flag is flipped
2. Create a new record via API -- verify `created` is stored in UTC
3. Test picking date logic around midnight warehouse time
4. Run `OrderReleaseJob` manually -- verify it still uses warehouse timezone correctly
5. Check `OrderMonitorView` queries -- verify `CURRENT_DATE` returns correct warehouse date
6. **Picking date midnight boundary tests** `[Round 7 fix]`:
   - At warehouse 23:59 on day D: order with `pickingdate = D+1` must NOT be released
   - At warehouse 00:01 on day D+1: that same order MUST be released
   - At warehouse **16:00 on day D** (= UTC midnight D+1 for LA): order with `pickingdate = D+1` must NOT be released yet — this is the 8-hour early-release regression test; if it releases here, `timezoneService.todayInWarehouse()` is not applied
   - Change an order's picking date to warehouse "today" at 16:00 warehouse time (UTC-rollover window): verify the order state resets to **RAW** (not stuck in FUTURE_PICKING_DATE)
7. Run transaction report endpoints -- verify date range queries work with `timestamptz` function params `[Round 9 fix — renumbered from duplicate 6]`
8. Verify `outbox_message.next_attempt_at` is correctly converted (spot-check a known row)
9. Verify `rest_idempotency` table is empty post-drain and new rows are written as UTC `timestamptz`

**Rollback rehearsal (before production):** `[Round 2 fix — M9]`
- Restore a tenant DB backup to a staging clone, time the full `pg_restore` — RTO baseline
- Run `V1.2.99__rollback_utc_migration.sql` on the staged migrated DB, verify timestamps round-trip correctly back to LA wall-clock
- `[Round 3 fix — FIX 8]` Verify stored function signatures are correctly restored to `timestamp without time zone` in PART 3 of the rollback script

### Phase 4 `[Round 6 fix]`
- `[Round 6 fix]` Browser DevTools → Application → Local Storage: verify `warehouseTimezone` key is set to the correct IANA ID (e.g. `America/Los_Angeles`) after app startup
- `[Round 6 fix]` Vue DevTools → Vuex state: verify root `warehouseTimezone` equals `tenant_discovery.timezone` for the connected warehouse (not browser local, not `America/Los_Angeles` hardcoded default)
- `[Round 6 fix]` Page-refresh test: reload after startup and confirm `warehouseTimezone` is still correct (seeded from `localStorage`, no extra API call)
- Verify frontend displays dates in warehouse-local time (not UTC, not browser local)
- Test date pickers send correct values to API
- Cross-check created/modified timestamps: API returns UTC, frontend shows warehouse-local
- Verify `stockUnitRecord` table header no longer says `(EST)`

---

## Risk Mitigation `[Round 2 fix]` `[Round 3 fix]`

| Risk | Mitigation |
|------|-----------|
| Data corruption during migration | Full database backup before deploy; V1.2.01+V1.2.03 run in transaction; test on staging first; rollback rehearsal before production |
| Wrong timezone conversion for `outbox_message` (was UTC, not LA) | `[Round 2 fix]` Explicit `USING created_at AT TIME ZONE 'UTC'` for Group B tables — NOT a session-level SET |
| DST boundary off-by-one | `USING col AT TIME ZONE 'America/Los_Angeles'` handles DST automatically per specific date; DST boundary test cases in staging |
| Frontend breaking on new date format | `[Round 2 fix]` `safeParse` dual-format in `dateFormatter.js` handles both legacy and ISO-8601 during transition; backend feature flag `API_TIMESTAMP_FORMAT` decouples DB migration from API format change |
| `@PostConstruct` fires after DataSource init | `[Round 2 fix]` JVM timezone set in `main()` before `SpringApplication.run()` (or via `TZ=` env var) |
| Scheduled jobs fire at wrong time | Phase 1 pins timezone explicitly on all 6 CronTrigger instances |
| `OrderBatchCreationService` picking date off-by-one (evening orders) | `[Round 3 fix — FIX 6]` Lines 158, 166 use `timezoneService.todayInWarehouse()` no-arg (request-scoped, TenantContext is set) |
| Native queries return wrong "today" | Per-tenant session timezone (Phase 2.6) makes `current_date` transparent; PgBouncer pool mode must be verified |
| Multi-tenant: different warehouses, different timezones | `[Round 10 fix]` `System Time Zone` sysprop read from `los_sysprop` at pool-creation time (one-shot DriverManager); session timezone set per-connection; `TimezoneService` cache keyed by tenant key (built from TenantContext) |
| Large table lock during ALTER | Run during maintenance window; V1.2.02 is non-transactional — partial progress survives failure; monitor `pg_stat_progress_cluster`; `SET statement_timeout=0` prevents admin kills |
| Disk exhaustion during ALTER rewrite | `[Round 2 fix]` Pre-migration disk check required; ≥ 2× current table size free disk needed per table rewritten |
| `outbox_message` in-flight rows during migration | Pre-migration DO $$ block aborts Flyway if PENDING/IN_FLIGHT rows exist; drain procedure documented in deployment sequence |
| `clientRepository` cast still uses `::timestamp` | `[Round 2 fix]` Pre-deploy grep audit; `ClientRepository.java:54-65` explicitly listed in Phase 3.2 |
| v1 east coast client data migrated with LA `AT TIME ZONE` clause (wrong) `[2026-05-26]` | Each v1 client's data is stored in the wall-clock of that v1 instance's `hibernate.jdbc.time_zone`. Running V1.2.01/V1.2.02 on a NY-wall-clock v1 DB with `AT TIME ZONE 'America/Los_Angeles'` shifts every timestamp 3 hours forward. **Mitigation:** §0.6 Step 1 — determine the v1 Hibernate TZ before running any migration. Use parameterized copies (§0.6 Step 4) for NY clients. |
| v1 DB missing wms2-additive tables when V1.2.03 runs `[2026-05-26]` | A raw v1 DB (Flyway watermark V1.1.09) does not have `rest_idempotency` or `outbox_message`. V1.2.03 has `IF EXISTS` guards but V1.2.01 will fail on the pre-flight DO $$ check if `outbox_message` doesn't exist. **Mitigation:** §0.6 Step 3 — apply the standard V2.1.x scripts (V2.1.01…V2.1.15, in order) on the v1 DB before any V1.2.x script. |
| ~~Standard V2.1.08 PK collision on all v1 client DBs~~ **RESOLVED** `[2026-05-27 → resolved 2026-05-30]` | **No longer a risk.** V2.1.08 was re-id'd to align with the v1 baseline: it now inserts the stale-club sysprops at ids **140/141/142** (the same ids/syskeys v1 seeded in V1.1.07) with a composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. On a v1 DB those exact tuples already exist → the script cleanly **NO-OPS** with no PK violation (validated 2026-05-30 on `wms1-wineco-dev`). The former `v1-onboarding/V1.1.13__..._v1compat.sql` variant is unnecessary and has been **deleted** from the repo. §0.6 Step 3 now applies the standard `V2.1.08` directly. |
| `tenant_discovery.timezone` not set for migrated v1 client `[2026-05-26]` | Frontend reads warehouse timezone from `tenant_discovery.timezone` via `GET /api/public/authConfig`. If missing or null for a migrated v1 client, the frontend defaults to `'UTC'` and displays wrong local times. **Mitigation:** §0.6 Step 5 — verify and set landlord DB `tenant_discovery.timezone` before Deploy 3. |
| PgBouncer transaction-pool mode silently resets session TZ | `[Round 2 fix]` `[2026-06-03 audit — NOT A RISK TODAY]` PgBouncer is **not deployed**: `PgBouncer_Connection_Pool_Strategy_2026-04-05.md` is status *Pending*, and there is no `pool_mode`/`6432`/pgbouncer in `wms2-api` resources — the app connects direct per-tenant HikariCP → Postgres, so `connectionInitSql` session GUCs persist per physical connection (correct). **Re-open this row only if** the pending PgBouncer proposal ships; if it lands in transaction-pool mode, the Phase 2.6 session-TZ approach breaks and must move to `SET LOCAL`/per-query TZ. Document the chosen pool mode in the runbook at that time. |
| `new ObjectMapper()` instances produce wrong format | Phase 2.7 fixes critical ones; JVM UTC default provides baseline safety |
| Frontend-backend deployment gap | Deploy both back-to-back; `safeParse` handles both format strings during transition window |
| Transaction report endpoints receive UTC strings instead of warehouse-local strings `[Round 7 fix]` | `POST /rest/getTransactionSummaryReport` and `getTransactionDetailedReport` use `to_timestamp(...)::timestamptz` which interprets input in the session TZ (warehouse TZ). If the frontend sends UTC strings, the session-TZ cast double-converts → wrong date range. **Mitigation:** document API contract explicitly; ensure date-range pickers for these reports send warehouse-local strings only. See Phase 2.10. |
| `OrderReleaseJob` releases orders too early (UTC− warehouses) `[Round 7 fix]` `[Round 11 fix]` | Without Phase 2.5 fix: UTC rolls to D+1 before the warehouse's local midnight. LA warehouses (`America/Los_Angeles`, UTC−8): 8-hour window starting at 4 PM LA. NY warehouses (`America/New_York`, UTC−5): 5-hour window starting at 7 PM NY. Orders with `pickingdate = D+1` are released early. **Mitigation:** `ReleaseOrderJobService.java:121` must use `timezoneService.todayInWarehouse()` — reads per-tenant sysprop, correct for both LA and NY. |
| `OrderReleaseJob` skips today's orders for UTC+ warehouses `[Round 7 fix]` | Without Phase 2.5 fix: at warehouse midnight (UTC+ timezone), UTC is still the previous day. Orders for warehouse-today are treated as future and skipped — not released for up to 12+ hours into the warehouse day. Web UI shows `pickingdate = today`; cron does not release. **Mitigation:** same `timezoneService.todayInWarehouse()` fix (Phase 2.5). |
| Picking date change to "today" during UTC-rollover window leaves order in FUTURE_PICKING_DATE `[Round 7 fix]` | At LA 16:00–23:59 (UTC already D+1), changing `pickingdate` to LA today (D) causes `CustomerorderService.java:248` to skip both `equals` and `isAfter` branches — state not reset to RAW. Order stays in FUTURE_PICKING_DATE. **Mitigation:** `CustomerorderService.java:248` must use `timezoneService.todayInWarehouse()` (Phase 2.5). Regression test: change picking date to warehouse today at 16:00 warehouse time; verify state = RAW. |
| `customerorder_old` accidentally included in migration | `[Round 3 fix — FIX 1]` Excluded from all migration files; zero wms2-api references confirmed |
| `los_sysprop` table missing or `System Time Zone` row empty in CI/Testcontainers | `[Round 10 fix]` `resolveWarehouseTz` logs a warning and returns `null` → `connectionInitSql` is not set; pool falls back to PostgreSQL server timezone. CI runs should seed `los_sysprop` with `('System Time Zone', '<IANA>')` when timezone-sensitive behaviour is under test |
| `rest_idempotency` timezone ambiguity (native INSERT vs Hibernate) | `[Round 3 fix — FIX 5]` Drain table before migration window; convert empty table as UTC |
| `TimezoneService` cache uses wrong tenant TZ for scheduled jobs | `[Round 3 fix — FIX 4]` Cache lambda fix: caller must set TenantContext before first DB lookup; no-arg overload throws if TenantContext is absent |
| Stored function signatures not rolled back | `[Round 3 fix — FIX 8]` `[2026-06-03: now PART 5]` V1.2.99 PART 5 recreates the functions with `timestamp without time zone` signatures (after PART 4 recreates the views — `stock_history` RETURNS `stock_view.%TYPE`). Round-trip validated on PostgreSQL 16. |
| `flyway.executeInTransaction=false` comment syntax wrong | `[Round 3 fix — FIX 10]` Verify syntax against Flyway version bundled with Spring Boot 3.5.9 before deploy (Flyway 9+ uses this exact syntax) |
| Timezone cache stale after `System Time Zone` sysprop change | `[Round 3 fix — FIX 9]` `[Round 10 fix]` Short-term: restart required; long-term: Caffeine 24h TTL; document in runbook |
| DST fall-back ambiguity `[Round 4 fix — FIX R4-M6]` | Low | Pre-existing; irresolvable per-row; ~1hr/year affected; PostgreSQL picks PDT interpretation. Accepted residual risk. |
| DST query-cast asymmetry for transaction reports `[Round 8 fix]` | The V1.2.01–V1.2.03 migration uses `USING col AT TIME ZONE 'America/Los_Angeles'` which picks **PDT (UTC−7)** for the fall-back ambiguous hour (Nov 1, 01:00–02:00 LA). After migration, the `to_timestamp(...)::timestamptz` cast in `ClientRepository` interprets query strings in the PostgreSQL session TZ, which also picks PDT by default. The asymmetry arises only if the application wrote rows during the fall-back hour using a different DST rule. In practice this is negligible (≤1 h/year, pre-existing ambiguity). **Mitigation:** document this 1-hour window in the operations runbook; if exact sub-hourly precision in the Nov fall-back window is required, add explicit DST suffix to the wire format (outside scope of this migration). |
| `SyspropService` caches by `facilityCode:key` only (not composite tenant key) `[Review fix — MINOR-4]` `[2026-06-03 audit]` | `SyspropService.java:95` AND `:288` use `@Cacheable(key = "... getFacilityCode() + ':' + #key")` (two call sites, not one). If two different tenants share the same `facilityCode`, the wrong tenant's sysprop value may be returned from cache, causing `TimezoneService.getWarehouseZoneId()` to return the wrong timezone. **Mitigation:** verify no two active tenants share the same `facilityCode` — landlord-DB query: `SELECT facility_code, COUNT(DISTINCT tenant_id) FROM tenant_db_configuration GROUP BY facility_code HAVING COUNT(DISTINCT tenant_id) > 1;` must return 0 rows. Schedule a separate ticket to fix BOTH cache keys to include tenant name (Phase 5 or SBDEV-XXXX). |

---

## Multi-Tenant Considerations

1. **Database migration (V1.2.01-V1.2.03):** `[Round 11 fix]` All data written by wms2 (including data for NY-timezone warehouses) was written via the same global `hibernate.jdbc.time_zone=America/Los_Angeles` setting in `application.properties`. Therefore `USING col AT TIME ZONE 'America/Los_Angeles'` is correct for all existing wms2 tenant databases — no per-tenant parameterization needed.

   **v1 client migration exception `[2026-05-26]`:** When migrating a v1 client database directly into wms2, the `AT TIME ZONE` clause must match that v1 instance's `hibernate.jdbc.time_zone` — NOT wms2's shared LA config:
   - West coast v1 clients (`hibernate.jdbc.time_zone=America/Los_Angeles`): use `AT TIME ZONE 'America/Los_Angeles'` — same as existing wms2 data, original scripts work as-is
   - East coast v1 clients (`hibernate.jdbc.time_zone=America/New_York`): use `AT TIME ZONE 'America/New_York'` — requires parameterized copies of V1.2.01/V1.2.02 (see §0.6 Step 4)
   
   Running `AT TIME ZONE 'America/Los_Angeles'` on a NY-wall-clock v1 database shifts every timestamp 3 hours incorrectly. See §0.6 for the full v1 client onboarding pre-flight.

2. **Per-tenant session timezone:** After migration, each tenant's database connection sets `SET timezone = '<warehouse_tz>'`. `[Round 3 fix — FIX 3]` `[Round 10 fix]` Source is the `System Time Zone` sysprop in `los_sysprop`, read via one-shot `DriverManager` connection at pool-creation time. Validate IANA format before injecting into SQL (`ZoneId.of()` throws `ZoneRulesException` on invalid input). `[Round 4 fix — FIX R4-M3]` No `warehouseTimezone` field exists on `TenantDbConfiguration` (Round 2 proposed adding it; Round 3 abandoned that approach) — nothing to remove.

3. **Frontend timezone:** `[Round 6 fix]` Each tenant's frontend instance loads the timezone from `tenant_discovery.timezone` via `GET /api/public/authConfig` at startup (`plugins/initTenantAuth.client.js` — the same call that bootstraps Keycloak config). The value is persisted in `localStorage('warehouseTimezone')` and the Vuex root store for the app's lifetime. No hardcoded timezone in the frontend; no additional API call beyond the existing startup bootstrap. See Phase 4.0.

4. **New tenant onboarding:** `[Round 10 fix]` New tenants should have the `System Time Zone` sysprop set correctly in `los_sysprop` during provisioning. The backend writes UTC regardless of tenant timezone.

5. **`TimezoneService` cache:** Cache is keyed by the **composite tenant key** `first4(tenantName)-facilityCode` via `TenantKeyBuilder.buildKey()` — **not** by `facilityCode` alone (which is not globally unique across tenants). `[Round 4 fix — FIX R4-M1]` `[Review fix — HIGH-5]` `[Round 3 fix — FIX 9]` Short-term: if a tenant's timezone changes, the app must be restarted. Long-term: Caffeine 24h TTL. Document in the runbook.

### §5.7 Ongoing v1 Client Onboarding Template `[2026-05-26 — NEW]`

For each v1 client being migrated to wms2 after this UTC migration is complete, the onboarding sequence is:

1. **Determine v1 Hibernate TZ** (§0.6 Step 1): `America/Los_Angeles` (west) or `America/New_York` (east)
2. **Schema upgrade** (§0.6 Step 3): Apply the standard V2.1.x scripts in order (V2.1.01…V2.1.15) on the v1 client DB — single linear loop, no v1-compat (the v2-specific sequence is contiguous). Plus two non-Flyway per-client steps: stuck-transfer-order pre-flight fix and OMS host substitution in V2.1.02 + V2.1.13.
3. **UTC data migration** (§0.6 Step 4 + §0.5 runbook):
   - LA clients: run original V1.2.01–V1.2.05 as-is
   - NY clients: run parameterized copies with `AT TIME ZONE 'America/New_York'` for V1.2.01/V1.2.02; V1.2.03/V1.2.04/V1.2.05 as-is
4. **Landlord DB setup** (§0.6 Step 5): Create `tenant_db_configuration` + set `tenant_discovery.timezone`
5. **Sysprop verification** (§0.6 Step 2): Confirm `System Time Zone` is set correctly in `los_sysprop`
6. **Smoke test**: Verify order release, picking dates, and `CURRENT_DATE` views return correct warehouse-local dates

> **Note:** By the time this plan's Deploy 2 is complete, wms2 columns are `timestamptz`. The V1.2.01–V1.2.05 scripts convert incoming v1 data to UTC on the fly — the result lands correctly in `timestamptz` columns that wms2-api reads as UTC. No additional post-conversion step is needed for the v1 data to be compatible with the UTC-mode wms2-api.

> **New clients** onboarding directly to wms2 (no v1 history) require none of the above — a fresh database created with the shared `application.properties` writes UTC from the first row.
