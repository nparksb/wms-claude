---
title: "Landlord tenant `active` flag — deactivate clients without deleting rows"
ticket: "SBDEV-2727"
ticket_url: "https://app.clickup.com/t/868kgan3v"
type: feature
priority: normal
status: archived
project: [wms2]
version: v2
requester: "nam.park@siteboss.net"
created: 2026-07-26
updated: 2026-07-26
db_verified: true
related: []
tags:
  - plan
  - wms2
  - multi-tenancy
  - landlord
---

# Landlord tenant `active` flag — deactivate clients without deleting rows

**Ticket:** [SBDEV-2727](https://app.clickup.com/t/868kgan3v)
**Project:** wms2 | **Version:** v2 | **Type:** feature
**Priority:** normal
**Status:** approved-pending-execution (ralplan consensus: Planner → Architect r1 [SOUND-WITH-CHANGES] → Critic r1 [ITERATE] → Architect r2 [SOUND-WITH-CHANGES] → Critic r2 [ITERATE → all fixes folded] → APPROVE)
**Date:** 2026-07-26
**Acceptance script:** `sbdocs/4-Archieves/scripts/verify-SBDEV-2727-landlord-tenant-active-flag.sh` (retired on archival)

> **Archived 2026-07-26** — implemented & merged (wms2-api PR #95, merge `c4660ce`), ClickUp "on dev", dev landlord DB migrated (L001 applied). Acceptance script retired to `sbdocs/4-Archieves/scripts/verify-SBDEV-2727-landlord-tenant-active-flag.sh`.

> **Scope:** backend only — `v2/wms2-api`. No UI code change (web + mobile already redirect a 404 to `/unknown-tenant`). The landlord DB is **separate** from tenant DBs and is **not** Flyway-managed.

---

## 0. Affected sites (enumeration before drafting)

### In scope

| # | File | Construct | Change | Phase |
|---|------|-----------|--------|-------|
| 1 | `landlord/model/TenantDiscovery.java` | entity | Add `private Boolean active = Boolean.TRUE;` `@Column(name="active", nullable=false)` + `@JsonIgnore` + getter/setter | P1 |
| 2 | `landlord/model/TenantDbConfiguration.java` | entity | Add `private Boolean active = Boolean.TRUE;` `@Column(name="active", nullable=false)` + getter/setter | P1 |
| 3 | `landlord/jpa/TenantDiscoveryRepository.java:23` | `findByKey` | Add `Optional<TenantDiscovery> findByKeyAndActiveTrue(String key)` (mirror `findByKey` return type) | P1 |
| 4 | `landlord/jpa/TenantDbConfigurationRepository.java` | repo | Add `List<TenantDbConfiguration> findByActiveTrue()`; add `Optional<TenantDbConfiguration> findByWarehouseAndActiveTrue(String warehouse)` (for the actuator guard, site 9) | P1 |
| 5 | `landlord/service/LandlordService.java:89` | `getTenantDiscoveryByKey` | `findByKey` → `findByKeyAndActiveTrue` | P1 |
| 6 | `landlord/service/LandlordService.java:68` | `getAllDbConfigurations` | `findAll` → `findByActiveTrue` | P1 |
| 7 | `landlord/config/TenantDynamicRoutingDataSource.java` | new method | Add `evictAbsentPools()`: for each live pool key absent from `dbConfigCache`, `removeTenant(key)` (+ dedicated log line) | P2 |
| 8 | `landlord/config/TenantConfigLoader.java:91` | `refreshTenantConfigs` | After `evictChangedPools()`, call `routingDataSource.evictAbsentPools()` | P2 |
| 9 | `controller/actuator/TenantPoolEndpoint.java:45` | `findByWarehouse` + `dbConfigCache.put` (:48) | Route through `findByWarehouseAndActiveTrue` (or check `fresh.getActive()`), refuse the cache put for an inactive tenant | P1 |
| 10 | NEW `src/main/resources/db/landlord/L001__add_active_flag.sql` | operator DDL | `ADD COLUMN active boolean NOT NULL DEFAULT true` on both tables + parameterized both-tables toggle snippet | P0 |
| 11 | **8 scheduled jobs** (see §3.7) — `schedulejob/OrderReleaseJob.java:74`, `CleanUpOldMessagesJob.java:53`, `OutboxDispatcherJob.java:72`, `StaleClubBatchCleanupJob.java:42`, `ReleaseExpiredPickingOrdersFromUserJob.java:63`, `StockSummaryExportJob.java:93`, `ReplenishOrderJob.java:107`, `RestIdempotencyCleanupJob.java:55` | `tenantDbConfigurationRepository.findAll()` tenant enumeration | Replace `findAll()` → `findByActiveTrue()` so cron work skips inactive tenants (these read the landlord repo **directly**, bypassing `dbConfigCache`) | P1 |

### Excluded (verify-only or out of scope, with rationale)

| Site | Rationale |
|------|-----------|
| `TenantDiscoveryRepository.findByRealm:18` | No live callers; JWT decoding does not use discovery. Verify-only. |
| `LandlordService.getAllAuthConfigurations:81` (`findAll`) | Filtering is **redundant** — `dbConfigCache` is the enforcement funnel (see §2.5); `MultiTenantKeycloakService.getCurrentTenantAuthConfig` resolves `dbConfigCache.get` **first** and returns null if absent. Leaving auth configs unfiltered is safe. Verify-only. |
| `TenantRoutingService.getWarehouseDataSourceMap:24` / `getRuntimeConfig:35` | No live callers. **Note (nice-to-have):** must gain the active filter if ever wired into a routing/resurrection path. |
| `LandlordService.getDbConfigByWarehouse:72` / `findByTenantNameAndWarehouse` / `findAllByTenantName` | No live callers (only a unit test references `getDbConfigByWarehouse`). Same note as above. |
| web `plugins/tenant-auth-fetch.js` + `initTenantAuth.client.js`, mobile equivalents | Inactive → 404 → `/unknown-tenant` (web) / `/mobile/unknown-tenant` (mobile) already handled. **Verify-only** — manual test plan §6.3 exercises it. |
| `TenantHealthService`, `MultiTenantKeycloakService` | Consume `dbConfigCache.get(...)`; inactive tenants are naturally absent from the active-filtered cache — a **desirable** side effect. Verify-only. |
| `SchedulingConfiguration.java:107,147` | Uses `dbConfigCache.getAll()` only to pick **one representative** active tenant to bootstrap the scheduler + test DB init; after the §3.3 cache filter this naturally selects an active tenant (all-inactive → empty → scheduling aborts, correct). **No change** — verify-only. **NOTE:** the actual per-tenant cron iteration is NOT here — it is inside each job via `findAll()` (see site 11 / §3.7), which IS in scope. |

---

## 1. Problem Statement

Operators need to **deactivate a client** (tenant/warehouse) without physically deleting rows from the landlord DB. Today, disabling a client means deleting its `tenant_discovery` and `tenant_db_configuration` rows — destructive, hard to reverse, and it discards history.

This feature adds an `active` boolean to both landlord tables so a client is disabled by flipping a flag. Two effects are required:

1. **WMS Web/Mobile UI** must only receive *active* tenants from `tenant_discovery`. An inactive key returns 404 from `/api/public/authConfig`, which the existing UI already redirects to `/unknown-tenant`.
2. **WMS API** must only load DB connection pools for *active* tenants from `tenant_db_configuration`. An inactive tenant's requests hit a `dbConfigCache` miss and are rejected with `TenantException`, and any live Hikari pool is force-closed within one 5-minute refresh cycle.

Backend-only (`v2/wms2-api`). No UI change, no admin endpoint (deactivation is a manual operator `UPDATE`), no feature flag.

---

## 2. Current Architecture

### 2.1 `tenant_db_configuration` → API DB-pool load path

| Step | Location | Behavior |
|------|----------|----------|
| Load | `LandlordService.getAllDbConfigurations()`:68 → `repo.findAll()` | **The** DB-config load path |
| Refresh | `TenantConfigLoader.refreshTenantConfigs()`:71-106 | `@EventListener(ApplicationReadyEvent)` + `@Scheduled(fixedDelay 300000ms / 5min)`; `dbConfigCache.clear()` (:77) then re-put keyed by `TenantKeyBuilder.buildKey` (lowercased name+facility, :81-84); then `routingDataSource.evictChangedPools()` (:91) |
| Route | `TenantDynamicRoutingDataSource.determineTargetDataSource()`:49-77 | `computeIfAbsent` builds Hikari pool from `dbConfigCache.get(key)`; **cache miss → throws `TenantException` (:62-64)** — the runtime enforcement point |
| Evict changed | `evictChangedPools()`:194-207 | Evicts only pools whose connection config **changed**; `fresh == null` (key absent from cache) → `continue` ("left for the idle evictor", :192,198) ← **THE GAP** |
| Remove | `removeTenant()`:224 | Closes + removes a pool |
| Idle evict | `TenantPoolEvictor.evictIdlePools` | Evicts by `lastAccess` age only (idle > 15 min) |

### 2.2 `tenant_discovery` → UI login path

| Step | Location | Behavior |
|------|----------|----------|
| Lookup | `LandlordService.getTenantDiscoveryByKey(key)`:89 → `repo.findByKey()`:23 | Returns entity or empty |
| Endpoint | `TenantDiscoveryController` `/api/public/authConfig?key=`:24-37 | Returns entity JSON, or 404 when empty |
| Web | `plugins/tenant-auth-fetch.js`:106-109 + `initTenantAuth.client.js`:165-171 | 404 → `'notfound'` → `/unknown-tenant` |
| Mobile | mirrors web | 404 → `/mobile/unknown-tenant` |

Active-only `findByKeyAndActiveTrue` ⇒ inactive key → empty → 404 → existing UI redirect. **No UI change.**

### 2.3 Live landlord DB state (dev `wms1-landlord-dev`, recorded pre-change; db_verified: true)

**`tenant_discovery`** (4 rows): id24 `wsl-wineco`/`wineco`; id25 `nywh-hydra`/`hydra`; id27 `nywh-shipitez`/`shipitez`; id28 `c1wh-shipitez`/`shipitez`.

**`tenant_db_configuration`** (4 rows): id20 `wsl`/`wineco`; id21 `nywh`/`hydra`; id22 `nywh`/`shipitez`; id23 `c1wh`/`shipitez`.

Both use `landlord_id_sequence`; `tenant_db_configuration` has `uq_warehouse_tenant` unique constraint. **No `active` column exists yet on either table.**

### 2.4 Persistence configuration (critical)

- `ddl-auto=none` for **both** persistence units in production (`application.properties:70`; `LandlordDatabaseConfig.java:32-33,50`). Adding an entity field does **not** break context load; a query referencing `active` **does** fail at runtime if the column is absent.
- Landlord schema is **not** Flyway-managed. Flyway `db/migration/` (highest `V2.2.04`) targets **tenant** DBs only ("The landlord schema is managed separately"). **Zero landlord DDL exists in the repo.**
- Dual transaction managers: `landlordTransactionManager` is `@Primary`; `LandlordService` uses the default (landlord) TM correctly. **Do not** add `tenantTransactionManager` to landlord service methods.
- Test profiles: default test profile = Postgres `wms_test` + `ddl-auto=validate` (`application.properties:39`); `@ActiveProfiles("integration")` = H2 `ddl-auto=create-drop` from entities (`application-integration.properties:9,27,29`). **Repo tests for this feature MUST use `@ActiveProfiles("integration")`** so the `active` column materializes from the entity (§6.2).

### 2.5 The enforcement funnel (why filtering `db-config` alone is sufficient)

`dbConfigCache` is the single security boundary. Every live path that grants a tenant access reads it:
- Routing: `TenantDynamicRoutingDataSource.determineTargetDataSource:62-64` — cache miss → `TenantException` (DB unreachable).
- Per-tenant JWT decoder resolution: `MultiTenantKeycloakService.getCurrentTenantAuthConfig` does `dbConfigCache.get(tenantKey)` first and returns null if absent (`MultiTenantKeycloakService.java:120-126`), consumed by `MultiTenantJwtDecoder.getJwtDecoder` (`:73-78`).

The **only** live write-paths to `dbConfigCache` are `TenantConfigLoader` (P1 filter) and `TenantPoolEndpoint` actuator (P1 guard, site 9). Close both and an inactive tenant cannot reach its DB even with a valid JWT. This is why filtering `getAllAuthConfigurations` is redundant, and why the actuator guard is **mandatory** (it is the second write-path).

### 2.6 Cron jobs enumerate tenants directly from the landlord repo (bypass the cache)

**This is a second enforcement surface, independent of the request-path funnel in §2.5.** The scheduled jobs (`@ConditionalOnProperty app.cron=true`) do **not** read `dbConfigCache` to decide which tenants to process. Each job enumerates tenants by calling `tenantDbConfigurationRepository.findAll()` **directly against the landlord DB**, maps each row to a `TenantProfile`, then loops `TenantContext.setCurrentTenant(profile)` → per-tenant work:

```java
// e.g. OrderReleaseJob.java:74 (identical shape in all 8 jobs; comment even says "active" but calls findAll())
List<TenantProfile> tenantProfiles = tenantDbConfigurationRepository.findAll()
    .stream().map(c -> new TenantProfile(c.getTenant().getName(), c.getWarehouse())).toList();
for (TenantProfile p : tenantProfiles) { TenantContext.setCurrentTenant(p); ...work... }
```

Eight jobs use this pattern (all verified): `OrderReleaseJob:74`, `CleanUpOldMessagesJob:53`, `OutboxDispatcherJob:72`, `StaleClubBatchCleanupJob:42`, `ReleaseExpiredPickingOrdersFromUserJob:63`, `StockSummaryExportJob:93`, `ReplenishOrderJob:107`, `RestIdempotencyCleanupJob:55`. The **only** other `tenantDbConfigurationRepository.findAll()` caller in main is `LandlordService:69` (fixed by §3.3).

**Consequence if unfixed:** after deactivation, every cron tick still iterates the inactive tenant, sets `TenantContext` to it, then fails at routing (`dbConfigCache.get` → null → `TenantException`) for that tenant on every run — noisy per-tenant errors and a direct contradiction of "only work with active tenants." This is the specific gap the request-path filter (§3.3) does **not** close, because the jobs never consult the cache.

---

## 3. Design

**Three independent enforcement surfaces** must each filter to active (a deactivated tenant must be blocked on all three):
1. **Discovery / UI login** — `getTenantDiscoveryByKey` → `findByKeyAndActiveTrue` (§3.3) → 404 → existing `/unknown-tenant`.
2. **Request-path DB routing** — `getAllDbConfigurations` → `findByActiveTrue` feeds the active-only `dbConfigCache` (§3.3); cache miss → `TenantException`. Second write-path to the cache — the **actuator** — is guarded (§3.5).
3. **Cron-job tenant enumeration** — the 8 jobs read the landlord repo directly (bypassing the cache); each switches `findAll()` → `findByActiveTrue()` (§3.7).

Plus the immediate pool teardown (§3.4) and the operator DDL (§3.6).

### 3.1 Entity fields

**`landlord/model/TenantDiscovery.java`**:
```java
@JsonIgnore
@Column(name = "active", nullable = false)
private Boolean active = Boolean.TRUE;

public Boolean getActive() { return active; }
public void setActive(Boolean active) { this.active = active; }
```

**`landlord/model/TenantDbConfiguration.java`** — same field + accessors (no `@JsonIgnore` needed; not serialized on a public endpoint).

**Rationale:**
- **Field initializer `= Boolean.TRUE` is mandatory** (Architect change #2 / Critic-verified). Hibernate lists all mapped columns in INSERT statements. `LandlordService.addDatabaseConfig` → `save()` (:55-62) on a new provision would send `active = NULL` and violate the `NOT NULL` constraint without the initializer. This mirrors the existing field-default pattern (`maxPoolSize = 2`, `minIdle = 0`, `timezone = "UTC"`).
- `@Column(nullable = false)` documents the DB constraint and gives H2 create-drop parity with the L001 `NOT NULL` for repo tests.
- `@JsonIgnore` on `TenantDiscovery.active` keeps the public `/authConfig` response payload byte-for-byte unchanged.

### 3.2 Repository queries

**`landlord/jpa/TenantDiscoveryRepository.java`**:
```java
Optional<TenantDiscovery> findByKeyAndActiveTrue(String key);
```
(Confirm `findByKey`'s exact return type at impl and mirror it.)

**`landlord/jpa/TenantDbConfigurationRepository.java`**:
```java
List<TenantDbConfiguration> findByActiveTrue();
Optional<TenantDbConfiguration> findByWarehouseAndActiveTrue(String warehouse);
```

**Rationale:** derived queries push `WHERE active = true` into SQL (avoids load-then-discard) and are H2-compatible boolean predicates. Chosen over a service-layer `findAll()`+stream (§9 alt b).

### 3.3 Service wiring

- **`LandlordService.java:89` `getTenantDiscoveryByKey`** — `repo.findByKey(key)` → `repo.findByKeyAndActiveTrue(key)`. Inactive → empty → controller 404 → existing UI redirect.
- **`LandlordService.java:68` `getAllDbConfigurations`** — `repo.findAll()` → `repo.findByActiveTrue()`. `TenantConfigLoader` now populates `dbConfigCache` with active configs only ⇒ inactive tenant is a cache miss ⇒ `TenantException` on any request.

No transaction-manager changes: both remain on the landlord (default `@Primary`) TM.

### 3.4 `evictAbsentPools()` + loader wiring (immediate force-evict — mandatory, not a preference)

**`config/TenantDynamicRoutingDataSource.java`** — add:
```java
/**
 * Closes and removes any live pool whose key is no longer present in the
 * active-filtered dbConfigCache (e.g. tenant deactivated). Complements
 * evictChangedPools(), which only evicts CHANGED configs and leaves absent
 * ones "for the idle evictor". Per-replica, local cache maintenance only.
 */
public void evictAbsentPools() {
    for (String key : getTenantPools().keySet()) {   // fresh HashMap snapshot (:177-181) — CME-safe
        if (dbConfigCache.get(key) == null) {
            log.info("Tenant {} no longer in active config cache; evicting pool (deactivated)", key);
            removeTenant(key);
        }
    }
}
```

**`config/TenantConfigLoader.java:91`** — after `routingDataSource.evictChangedPools()`, add `routingDataSource.evictAbsentPools();`. Ordering: rebuild active-only cache → evict changed → **evict absent**.

**Why immediate eviction is a correctness requirement (Critic fix #2):** the idle evictor (`TenantPoolEvictor`) evicts by `lastAccess` age only. A **busy** deactivated tenant whose requests keep arriving never goes idle, so its pool would *never* be torn down by the idle path. `evictAbsentPools()` in the 5-min refresh is therefore the only mechanism that reliably closes a deactivated-but-active-traffic tenant's pool.

**Concurrency:** `getTenantPools()` returns a fresh `HashMap` snapshot (:177-181), so iterating while `removeTenant` mutates `poolHolders` is safe (also `poolHolders` is a `ConcurrentHashMap`). Pool keys and cache keys share the same lowercased `TenantKeyBuilder` domain (loader :81-84 vs `determineTargetDataSource` :56) — `evictChangedPools` already depends on this equivalence, so no wrong-eviction risk. `dbConfigCache.get` returns `null` on miss (`TenantDbConfigCache.java:32-38`).

### 3.5 Actuator guard (mandatory — the second cache write-path)

**`controller/actuator/TenantPoolEndpoint.java:45,48`** currently does `findByWarehouse(fac)` (unfiltered) then `dbConfigCache.put(key, fresh)` — for a deactivated tenant this **re-inserts the row into the cache and rebuilds its pool**, resurrecting it until the next ≤5-min refresh re-clears it. Fix: use `findByWarehouseAndActiveTrue` (or check `fresh.getActive()`); for an inactive tenant, **refuse the put** and return `EntityNotFoundException` / a 404-style response. Without this, the operator's manual-refresh fast-path defeats deactivation.

### 3.7 Scheduled-job tenant enumeration (the second enforcement surface)

In each of the 8 jobs listed in §2.6, replace the tenant-enumeration call:
```java
// before
tenantDbConfigurationRepository.findAll()
// after
tenantDbConfigurationRepository.findByActiveTrue()
```
This reuses the **same** derived query added in §3.2 (no new repo method), so cron work — order release, replenishment, stock-summary export, message/idempotency cleanup, stale-club cleanup, expired-pick release, outbox dispatch — is skipped for inactive tenants at the source, before any `TenantContext` is set or any pool is touched.

**Why filter at enumeration rather than lean on the cache miss:** the jobs never read `dbConfigCache`, so the request-path funnel (§2.5) does not cover them; filtering the `findAll()` is the only place to enforce active-only for cron. It is also cleaner than letting each tenant throw `TenantException` mid-loop (which some jobs catch-and-continue and others count as failures / emit error metrics).

**Rollout coupling:** because these jobs call `findByActiveTrue()` after §3.2 adds it, they inherit the same P0 prerequisite — the `active` column must exist in the landlord DB before a cron-enabled (`app.cron=true`) replica boots, or the enumeration query throws (caught per §5.2 P0 risk). No new deploy-order concern beyond the existing hard gate.

**No new scheduled job, no new advisory lock, no tenant-context change** — the existing per-tenant loop, `AdvisoryLockService` locks, `JobMetrics`, and `TenantContext` set/clear lifecycle are untouched; only the source list shrinks to active tenants.

### 3.6 Operator DDL script

**NEW `src/main/resources/db/landlord/L001__add_active_flag.sql`** (committed for traceability; **not** wired into Flyway — nothing on the classpath auto-executes `db/landlord/`):
```sql
-- SBDEV-2727 — Landlord schema is managed OUT OF BAND (ddl-auto=none, NOT Flyway-managed).
-- Apply MANUALLY to EACH landlord DB (dev, then prod) BEFORE deploying the API JAR.
-- NOT NULL DEFAULT true backfills all existing rows as active => zero behavior change on apply.
ALTER TABLE tenant_discovery
    ADD COLUMN IF NOT EXISTS active boolean NOT NULL DEFAULT true;

ALTER TABLE tenant_db_configuration
    ADD COLUMN IF NOT EXISTS active boolean NOT NULL DEFAULT true;

-- ---------------------------------------------------------------------------
-- DEACTIVATE a client (single operator action — flip BOTH tables atomically).
-- Partial flips (one table only) are UNSUPPORTED and cause split-brain:
--   discovery-only  => new logins 404 but existing API sessions keep routing;
--   db-config-only  => API blocked but the login/discovery page still resolves.
-- Replace :key and :warehouse with the client's discovery key and warehouse code.
-- ---------------------------------------------------------------------------
-- BEGIN;
--   UPDATE tenant_discovery        SET active = false WHERE key = :key;
--   UPDATE tenant_db_configuration SET active = false WHERE warehouse = :warehouse;
-- COMMIT;
--
-- REACTIVATE: same UPDATEs with active = true. Cache repopulates and the pool
-- rebuilds on demand within <=1 refresh cycle (5 min), or force via the
-- /actuator tenant-pool evict endpoint.
```

`ADD COLUMN IF NOT EXISTS` makes re-application idempotent per environment.

---

## 4. File Change Summary

| File | Add/Modify/Delete | Description |
|------|-------------------|-------------|
| `landlord/model/TenantDiscovery.java` | Modify | `Boolean active = Boolean.TRUE` `@Column(nullable=false)` + `@JsonIgnore` + accessors |
| `landlord/model/TenantDbConfiguration.java` | Modify | `Boolean active = Boolean.TRUE` `@Column(nullable=false)` + accessors |
| `landlord/jpa/TenantDiscoveryRepository.java` | Modify | `findByKeyAndActiveTrue(String)` |
| `landlord/jpa/TenantDbConfigurationRepository.java` | Modify | `findByActiveTrue()`, `findByWarehouseAndActiveTrue(String)` |
| `landlord/service/LandlordService.java` | Modify | :89 `findByKey`→`findByKeyAndActiveTrue`; :68 `findAll`→`findByActiveTrue` |
| `landlord/config/TenantDynamicRoutingDataSource.java` | Modify | Add `evictAbsentPools()` + eviction log line |
| `landlord/config/TenantConfigLoader.java` | Modify | :91 call `evictAbsentPools()` after `evictChangedPools()` |
| `controller/actuator/TenantPoolEndpoint.java` | Modify | Guard against inactive tenant (findByWarehouseAndActiveTrue / refuse put) |
| `schedulejob/{OrderReleaseJob, CleanUpOldMessagesJob, OutboxDispatcherJob, StaleClubBatchCleanupJob, ReleaseExpiredPickingOrdersFromUserJob, StockSummaryExportJob, ReplenishOrderJob, RestIdempotencyCleanupJob}.java` | Modify (×8) | Tenant enumeration `findAll()` → `findByActiveTrue()` (§3.7) |
| **21 existing test files** (`unit/schedulejob/*` + `LandlordServiceUnitTest`) | Modify (×21) | Migrate `findAll()` stubs/verifies → `findByActiveTrue()` (§6.1.1) — dominant cost |
| `src/main/resources/db/landlord/L001__add_active_flag.sql` | Add | Operator DDL + parameterized both-tables toggle snippet |
| `unit/service/landlord/LandlordServiceUnitTest` | Modify | Inactive-exclusion assertions (both methods) |
| `unit/controller/TenantDiscoveryControllerUnitTest` | Modify | 404 when service empty (inactive) |
| `landlord/config/TenantConfigLoaderAutoEvictTest` / `TenantDynamicRoutingDataSourceEvictRebuildTest` | Modify | `evictAbsentPools()` closes+removes absent-key pool; keeps present pools |
| Actuator test (`TenantPoolEndpointSecurityTest` or new) | Modify/Add | Actuator refuses to rebuild an inactive tenant's pool |
| Landlord repository H2 test (`@ActiveProfiles("integration")`) | Add | `findByKeyAndActiveTrue` / `findByActiveTrue` / `findByWarehouseAndActiveTrue` |

---

## 5. Prerequisites & Phased Implementation Plan

**Branch:** `feature/SBDEV-2727-landlord-tenant-active-flag`

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **Database state** | `active` column present on `tenant_discovery` + `tenant_db_configuration` in the target landlord DB (via L001) **before** the P1 JAR boots | Landlord DB is not Flyway-managed — operator-applied |
| 2 | **Feature flags / system properties** | N/A | Additive default-`true` is inert until a flag is flipped; a runtime toggle adds no value |
| 3 | **Config / env changes** | N/A | No new properties; `wms.tenant.config.refresh-interval-ms` default 300000ms already governs eviction cadence |
| 4 | **Deploy-order dependencies** | **HARD GATE:** apply L001 to **every** environment's landlord DB, and **never scale a fresh replica**, before rolling the P1 JAR — see §5.2 P0 risk | Fresh pod on a column-less landlord DB → empty cache → all tenants 500 |
| 5 | **Data migration** | Backfill is implicit (`DEFAULT true`) — all existing rows become active | No separate backfill script |
| 6 | **External systems** | N/A | No OMS / printer / Keycloak change |
| 7 | **Access / permissions** | N/A | No new endpoint/role (manual SQL toggle) |
| 8 | **Monitoring / alerts** | Watch logs post-deploy for `column "active" does not exist`; confirm `TenantConfigLoader` "Loaded {N} DB configurations" INFO (:101) still fires per replica (this line is the per-replica active-count observable) | No new metric required |

### 5.2 Phases

#### P0 — Operator DDL (prerequisite, before deploy)
- **Goal:** `active` column exists on both landlord tables in every target landlord DB.
- **Changes:** commit `L001__add_active_flag.sql`; operator applies it to dev landlord, verifies, then prod landlord.
- **Testing:** post-apply `\d tenant_discovery` / `\d tenant_db_configuration` shows `active boolean not null default true`; all existing rows `true`.
- **Risk (HIGH if mis-sequenced):** landlord `ddl-auto=none` means no boot-time validation failure, so a fresh JAR pod against a column-less landlord DB does **not** fail loudly — `getAllDbConfigurations()` (:76, before `clear()` at :77) throws, is caught+logged at `TenantConfigLoader.java:103-105`, and the pod runs with an **empty cache → every tenant `TenantException`/500 (fail-silent-open)**. Mitigation: the §5.1(4) hard gate.
- **Effort:** XS.

#### P1 — Entity fields + active-only queries + service + actuator guard + cron enumeration
- **Goal:** UI receives only active tenants; API loads only active DB configs; actuator cannot resurrect an inactive tenant; **cron jobs skip inactive tenants**.
- **Changes:** sites 1–6, 9, **11** (8 jobs, §3.7).
- **Testing:** `LandlordServiceUnitTest`, `TenantDiscoveryControllerUnitTest`, actuator guard test, per-job enumeration tests (§6.1), repo H2 tests (§6.2); `mvn clean compile` + touched unit tests.
- **Risk:** requires P0 applied to the target DB. Discovery query return-type mismatch — `findByKey` returns `Optional<TenantDiscovery>` (confirmed), mirror it. Cron-enabled replicas (`app.cron=true`) hit `findByActiveTrue` at job time — same P0 prerequisite.
- **Effort:** M — the 8 production job edits are mechanical, but the **dominant cost is migrating ~21 existing test files / ~21 `verify().findAll()` sites** (§6.1.1). Gate on `mvn test -Dtest='net.aim_ai.wms.unit.schedulejob.*'` (§6.4), not just the grep script.

#### P2 — `evictAbsentPools()` + loader wiring (immediate force-evict)
- **Goal:** a deactivated tenant's live pool closes within one 5-min refresh cycle.
- **Changes:** sites 7–8.
- **Testing:** `TenantConfigLoaderAutoEvictTest` / `TenantDynamicRoutingDataSourceEvictRebuildTest`.
- **Risk:** none beyond code (per-replica local cache; no shared state / locks).
- **Effort:** S.

---

## 6. Test Plan

### 6.1 Unit tests (named)

| Test class | Test method | Asserts |
|------------|-------------|---------|
| `LandlordServiceUnitTest` | `getTenantDiscoveryByKey_inactive_returnsEmpty` | mock `findByKeyAndActiveTrue`→empty ⇒ service returns empty |
| `LandlordServiceUnitTest` | `getAllDbConfigurations_excludesInactive` | mock `findByActiveTrue` returns active-only ⇒ service returns active-only |
| `TenantDiscoveryControllerUnitTest` | `authConfig_inactiveTenant_returns404` | service empty ⇒ 404 (extends `BaseControllerTest`) |
| `TenantConfigLoaderAutoEvictTest` / `TenantDynamicRoutingDataSourceEvictRebuildTest` | `evictAbsentPools_closesDeactivatedTenantPool` | key dropped from active-filtered cache ⇒ `removeTenant` invoked once for that key; still-present key retained (assert via `getTenantPools()`) |
| Actuator test | `refresh_inactiveTenant_refusesRebuild` | actuator does **not** `dbConfigCache.put` / rebuild pool for an inactive tenant |
| **All 21 schedulejob/landlord test files** that mock `TenantDbConfigurationRepository` and stub/verify `.findAll()` (see §6.1.1) | `enumeratesOnlyActiveTenants` (new, on the 8 `*JobUnitTest`) + convert every existing stub/verify | mock `findByActiveTrue` (not `findAll`) is invoked; an inactive tenant never gets `TenantContext.setCurrentTenant`. **This is the dominant cost of the ticket — see §6.1.1** |

#### 6.1.1 Existing-test migration (mandatory — the `findAll()`→`findByActiveTrue()` blast radius)

The swap breaks every test that stubs or verifies `tenantDbConfigurationRepository.findAll()` in **three** ways: (a) `verify(...).findAll()` fails (production no longer calls it); (b) `when(findAll()).thenReturn(List.of(cfg))` becomes an unnecessary stub (Mockito strict → `UnnecessaryStubbingException`) **and** production `findByActiveTrue()` returns Mockito's default empty list → job iterates zero tenants → downstream `verify(dispatchBatch/metrics…)` fail; (c) `never().findAll()` assertions go semantically dead.

**Method (alias-robust — do NOT rely on the literal `tenantDbConfigurationRepository.` prefix):**
```
grep -rln "TenantDbConfigurationRepository" src/test/java \
  | while read f; do grep -qE "\.findAll\(\)" "$f" && echo "$f"; done
```
This lists **21 files** (verified). Convert **every** `when(<mock>.findAll())` → `when(<mock>.findByActiveTrue())` and **every** `verify(<mock>...).findAll()` → `verify(<mock>...).findByActiveTrue()`, including aliased mock variables — e.g. `OutboxDispatcherJobUnitTest.java:108,297,316` uses local names `repo` / `oneTenant` / `twoTenants`. Specifically flip the negative assertion at `StaleClubBatchCleanupJobUnitTest.java:56` (`verify(..., never()).findAll()` → `never()).findByActiveTrue()`).

Non-exhaustive file list (21): `OrderReleaseJob{UnitTest,Test,MetricsUnitTest,StreamingTest}`, `CleanUpOldMessagesJob{UnitTest,Test,MetricsUnitTest}`, `OutboxDispatcherJobUnitTest`, `StaleClubBatchCleanupJobUnitTest`, `ReleaseExpiredPickingOrdersFromUserJob{UnitTest,Test,MetricsUnitTest}`, `StockSummaryExportJob{Test,MetricsUnitTest}`, `ReplenishOrderJob{Test,MetricsUnitTest,PaginationTest,ConnectionBudgetTest}`, `RestIdempotencyCleanupJobUnitTest`, `LandlordServiceUnitTest`.

### 6.2 Repository tests (H2) — **MUST use `@ActiveProfiles("integration")`**

`findByKeyAndActiveTrue`, `findByActiveTrue`, `findByWarehouseAndActiveTrue` — active vs inactive rows. The integration profile builds landlord tables from entities via H2 `create-drop`, so the `active` column materializes automatically. **Do NOT** author these under the default profile (Postgres `wms_test` + `ddl-auto=validate`) — L001 is not in that schema and the test fails with the same missing-column error as prod.

### 6.3 Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Deactivate blocks UI (web) | dev | SQL-flip a tenant `tenant_discovery.active=false`; load web with its key | `/authConfig?key=` → 404; redirect to `/unknown-tenant` | |
| Deactivate blocks UI (mobile) | dev | same key on mobile | redirect to `/mobile/unknown-tenant` | |
| Deactivate blocks API | dev | flip `tenant_db_configuration.active=false`; send API request for that tenant | request rejected (`TenantException`; DB unreachable) | |
| Pool force-closed | dev | wait one 5-min refresh cycle | tenant's Hikari pool closed (log "evicting pool (deactivated)" / actuator shows pool absent) | |
| Actuator cannot resurrect | dev | with tenant inactive, hit the actuator pool-refresh for that warehouse | refused; no pool rebuilt | |
| Reactivate restores | dev | flip both back to `true`; wait one cycle (or force via actuator) | `/authConfig` 200; API request succeeds; pool rebuilt on demand | |
| SQL sanity | dev landlord DB | `\d tenant_discovery` / `\d tenant_db_configuration` | `active boolean not null default true`; existing rows `true` | |

### 6.4 Test execution (fill in after running)

| Command | Result | Pass/Fail/Skipped |
|---------|--------|-------------------|
| `mvn test -Dtest=LandlordServiceUnitTest,TenantDiscoveryControllerUnitTest` | | |
| `mvn test -Dtest=TenantConfigLoaderAutoEvictTest,TenantDynamicRoutingDataSourceEvictRebuildTest` | | |
| **`mvn test -Dtest='net.aim_ai.wms.unit.schedulejob.*'`** (MANDATORY gate — the grep acceptance script cannot detect a red job-test suite broken by the `findAll()`→`findByActiveTrue()` migration; §6.1.1) | | |
| `mvn clean compile` | | |

### 6.5 Integration tests

v2 IT harness is broken (SBDEV-2217) — gate on unit tests + `mvn clean compile`; leave any new `@SpringBootTest` IT `@Disabled` with `TODO(SBDEV-2217)`.

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | N/A | Uses the **existing** per-replica `dbConfigCache` + `poolHolders`; adds no new in-JVM state |
| 2 | Connection pool math | No | Reduces or holds pool count (inactive tenants no longer get pools); never increases it |
| 3 | Scheduled jobs | Yes | Modifies the tenant-enumeration source of 8 existing cron jobs (`findAll()`→`findByActiveTrue()`, §3.7). No new job, no new/changed advisory lock, no schedule change — each job's existing per-replica `AdvisoryLockService` guard, `JobMetrics`, and `TenantContext` lifecycle are untouched; only the iterated tenant list shrinks to active. `TenantConfigLoader.@Scheduled` refresh is likewise reused for eviction |
| 4 | Long transactions | No | Landlord reads are short `@Transactional(readOnly=true)` |
| 5 | Request affinity | No | Stateless; each replica routes from its own cache |
| 6 | Retry / idempotency | N/A | No new write path; DDL is idempotent (`IF NOT EXISTS`) |
| 7 | Tenant context | No | No async/ThreadLocal changes |
| 8 | Distributed lock correctness | No | No locks added |
| 9 | Cache invalidation | Yes | Handled by the existing `dbConfigCache.clear()`+repopulate each 5-min cycle; `evictAbsentPools()` closes now-absent pools. **Per replica** — each rebuilds active-only within its own cycle; a deactivation is fully in effect fleet-wide within one cycle |
| 10 | External notifications | No | None |

**Evidence (row 3):** 8 jobs enumerate via `tenantDbConfigurationRepository.findAll()` (OrderReleaseJob:74, CleanUpOldMessagesJob:53, OutboxDispatcherJob:72, StaleClubBatchCleanupJob:42, ReleaseExpiredPickingOrdersFromUserJob:63, StockSummaryExportJob:93, ReplenishOrderJob:107, RestIdempotencyCleanupJob:55) → `findByActiveTrue()` (§3.7). Per-replica advisory locks (`AdvisoryLockService.JobLockId.*`) and `app.cron` gate unchanged.

**Evidence (row 9):** `TenantConfigLoader.refreshTenantConfigs:77-91` (clear→repopulate→evictChanged→evictAbsent); `TenantDynamicRoutingDataSource.evictAbsentPools()` (new, §3.4); per-replica because each JVM owns its own `poolHolders`/`dbConfigCache`.

### v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | N/A — landlord reads are `@Transactional(readOnly=true)`; no lazy associations crossed |
| 2 | Transaction manager | Yes — landlord methods stay on default/`@Primary` landlord TM (correct); **no** `tenantTransactionManager` added |
| 3 | `readOnly=true` | Yes — `LandlordService` read methods are read-only |
| 4 | Caffeine cache invalidation | N/A — `dbConfigCache` is a bespoke cache, not `@Cacheable`; invalidation via `clear()`+repopulate |
| 5 | Micrometer metrics | N/A — no new high-frequency path |
| 6 | Jakarta namespace | Yes — new `@Column`/`@JsonIgnore` use `jakarta.persistence.*` / Jackson |
| 7 | H2-compatible test SQL | Yes — `active = true` boolean predicate; repo tests under integration profile |
| 8 | `BaseControllerTest` for endpoints | Yes — `TenantDiscoveryControllerUnitTest` extends it (controller unchanged; behavior via service) |

---

## 8. Rollout Plan & Known Behavior

### 8.1 Rollout
1. **Branch** `feature/SBDEV-2727-landlord-tenant-active-flag` off `develop`; PR into `develop`.
2. **Operator DDL:** apply `L001` to **dev landlord** → verify columns + all rows `active=true` → run §6.3 on dev → apply to **prod landlord** ahead of the prod deploy. **Hard gate:** every landlord DB has the column before its JAR rolls; do not scale a fresh replica in between.
3. **Deploy API** (P1 + P2 together) after P0 confirmed on the target landlord DB.
4. **Per-replica note:** with N replicas, each independently rebuilds its active-only cache and evicts absent pools within its own 5-min cycle; a deactivation is fully in effect fleet-wide within one cycle. No rolling-restart coordination required.

### 8.2 Rollback
- **Code rollback:** revert the JAR **before** dropping the `active` column (mirror of the P0 gate) — a deployed `findByActiveTrue`/`findByKeyAndActiveTrue` against a dropped column re-triggers the empty-cache 500 storm. The column can safely remain in place after a code revert (additive, default true); there is no data migration to undo.
- **Reactivate a client:** flip `active=true` on both tables; cache repopulates + pool rebuilds within ≤1 refresh cycle, or force via the actuator evict endpoint.

### 8.3 Known behavior (not a defect)
- **Token-validation vs data-access window.** After deactivation, **no tenant data is reachable** — routing is denied via `TenantException` within ≤1 refresh cycle (≤5 min). Separately, `MultiTenantJwtDecoder` caches per-tenant decoders for 24h and fast-paths `getIfPresent` (`:34-37,66-69`), so a deactivated tenant's **existing** JWT still *parses* for up to 24h — but that grants **zero** data access (the DB is unreachable). The 24h is a token-parse artifact, not an exposure window; the data-access window is ≤5 min.
- **Outbox delivery pauses for a deactivated tenant (not lost).** §3.7's cron filter also skips a deactivated tenant in `OutboxDispatcherJob`, so its **undelivered** outbox rows are not dispatched while inactive. This is a **pause, not a loss** — `dispatchService.cleanupSent()` only purges SENT rows, so PENDING rows are retained, and `findByActiveTrue()` re-includes the tenant on reactivation → dispatch resumes (late/stale OMS-bound events may deliver then). If a clean drain is required, dispatch the tenant's outbox to empty **before** deactivating. Acceptable default for "deactivate = stop the client's activity."
- **Pre-existing (not introduced here):** `TenantConfigLoader`'s non-atomic `clear()`-then-repopulate (:77-87) is a pre-existing transient-miss window during refresh for *active* tenants; SBDEV-2727 does not change it.

---

## 9. Alternatives Considered

| Option | Description | Why rejected |
|--------|-------------|--------------|
| (a) `active` on parent `tenant` table only | Single source of truth; one UPDATE disables everything | **Impossible for the discovery path** — `TenantDiscovery` has no `tenant_id` FK (keyed by `key`/`realm`/`client_id`, verified `TenantDiscovery.java:39-40`); `findByKey` cannot join `tenant`. Two child-table columns are forced, not arbitrary. (User also explicitly chose both child tables.) Trade-off accepted: operator flips two rows (mitigated by the atomic both-tables snippet in L001). |
| (b) Filter in service via `findAll()` + stream | Keep repo methods; filter in `LandlordService` | Loads all rows each cycle then discards inactive; a derived `findByActiveTrue` pushes the filter into SQL — cleaner and cheaper. |
| (c) Rely on the 15-min idle evictor | No new eviction code | Idle evictor keys off `lastAccess` only; a **busy** deactivated tenant never goes idle ⇒ pool never closes. `evictAbsentPools()` is the only reliable teardown. (User chose immediate.) |
| (d) Admin API endpoint to toggle | Secured endpoint flips `active` | New auth surface, audit, and test cost for a rare operator action; manual SQL matches the "just flip the flag" intent. (User chose manual SQL.) |

---

## 10. Open Questions / Resolved Decisions

### Resolved (user-fixed constraints)
1. **Immediate force-evict** — `evictAbsentPools()` closes a deactivated tenant's pool on the next 5-min cycle (not the 15-min idle evictor).
2. **Reuse `/unknown-tenant`** — inactive → 404 → existing UI redirect; no web/mobile code change.
3. **Manual SQL only** — operator UPDATEs the landlord DB; no admin endpoint.

### Resolved during consensus (Architect + Critic)
4. **Actuator `TenantPoolEndpoint` MUST honor `active`** (site 9) — it is the second write-path to `dbConfigCache`; without a guard it resurrects deactivated tenants.
5. **Entity `active` field initialized `= Boolean.TRUE`** — prevents `NULL`-insert NOT-NULL violation on new provision.
6. **Landlord repo tests use `@ActiveProfiles("integration")`** — H2 create-drop from entities; default profile (`validate` vs Postgres `wms_test`) would fail.
7. **`getAllAuthConfigurations` need NOT be filtered** — `dbConfigCache` funnel makes db-config the gate.
8. **Hard DDL-before-JAR sequencing gate** documented (§5.1(4), §5.2 P0) — fail-silent-open empty-cache risk.
9. **Cron-job tenant enumeration must be filtered too** (added post-review, site 11 / §2.6 / §3.7) — the 8 scheduled jobs read `tenantDbConfigurationRepository.findAll()` **directly** (not via `dbConfigCache`), so the request-path filter does not cover them; each job's enumeration is changed to `findByActiveTrue()`. This is a second, independent enforcement surface the original draft missed.

### Open (confirm during implementation)
- **[ ] `RestExceptionHandler` mapping of `TenantException`** — does it map to a clean 4xx or a 500? If 500, a still-tokened deactivated user sees a 500 (data is still safe). One-line confirmation during impl; adjust mapping only if trivially clean.

### Resolved during re-review (Architect round 2)
- **`findByKey` return type = `Optional<TenantDiscovery>`** (`TenantDiscoveryRepository.java:23`) — `findByKeyAndActiveTrue` mirrors it as `Optional<TenantDiscovery>`.
- **Outbox pause caveat** added to §8.3 (deactivation pauses, does not lose, undelivered outbox rows).
- **Three enforcement surfaces confirmed complete** — Architect swept every `tenantDbConfigurationRepository`/`TenantDiscoveryRepository` caller, every `@Scheduled`/`ApplicationReadyEvent` bean, `TenantRoutingService` (dead — zero injection sites), `TenantPoolEvictor` (iterates live-pool `lastAccessMap`, not the repo); no missed surface.

---

## 11. Acceptance & Implementation

### 11.0 Implementation record (2026-07-26)

- **Status:** MERGED — wms2-api PR **[#95](https://github.com/SiteBossInc/wms2-api/pull/95)** merged into `develop` 2026-07-26 (merge commit **`c4660ce`**; feature commit `02a148a`, 39 files, +456/-112; branch deleted). ClickUp SBDEV-2727 → **on dev**.
- **Tests:** `mvn test` **174 run, 0 failures, 0 errors** (6 skipped = pre-existing `@Disabled`). 6 new gate tests + 21 migrated schedulejob/landlord tests (`findAll`→`findByActiveTrue`).
- **Verify script:** `verify-SBDEV-2727-landlord-tenant-active-flag.sh` → **35 pass, 0 fail**.
- **Code review:** 0 critical/high; 1 MEDIUM (fresh-replica-before-DDL silently served empty cache) **fixed** — `TenantConfigLoader` now logs a loud, actionable startup ERROR banner (non-fatal) naming the missing `active` column / L001; low findings addressed (`@JsonIgnore` symmetry, strengthened exclude-test assertions).
- **Actuator guard note:** implemented via `findByWarehouse` + `getActive()` (plan §3.5 alternative) rather than `findByWarehouseAndActiveTrue`, to preserve the pre-existing `TenantPoolEndpointSecurityTest`; `findByWarehouseAndActiveTrue` remains declared (verify-script contract).
- **Deploy gate (unchanged, critical):** apply `db/landlord/L001__add_active_flag.sql` to every landlord DB (dev→prod) **before** rolling the JAR.
- **Docs (verify-docs):** implicated docs `wms2-tenant-routing-datasource-topology.md`, `wms2-scheduled-jobs-catalog.md`, `wms2-transaction-osiv-boundary-map.md` all within 60-day cadence (green) — recommend a light note on next edit re `evictAbsentPools()` + active-flag enforcement; not blocking.

### 11.1 Acceptance script
`sbdocs/9-System/scripts/verify-SBDEV-2727-landlord-tenant-active-flag.sh` — run after every pass; a "DONE" claim with any FAIL line is not accepted. Positive checks: `findByActiveTrue` in `getAllDbConfigurations`, `findByKeyAndActiveTrue` in `getTenantDiscoveryByKey`, `evictAbsentPools` present + called in `TenantConfigLoader`, entity field initialized `= Boolean.TRUE`, actuator guard present, `L001` script exists. Negative checks are **file+method-scoped** (not tree-wide): `getAllDbConfigurations` no longer calls `findAll()` and `getTenantDiscoveryByKey` no longer calls `findByKey(` **within `LandlordService.java`** (tree-wide would false-positive on `getAllAuthConfigurations`'s legitimate `findAll` and the surviving repo declarations / the `findByKeyAndActiveTrue` substring).

### 11.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | ~9 code sites in one subsystem (landlord) |
| Pre-draft step | analyst+planner (done via ralplan) | consensus complete |
| Plan-review step | critic (done) | ITERATE items folded in |
| Implementation shape | `executor` | single subsystem; verify script is the exit gate |
| Verification step | verify-script + `verifier` | mandatory |
| Code-review step | `code-reviewer` | touches multi-tenant routing — worth a pass |
| Commit step | `git-master` | P0/P1/P2 map to logical commits |
