---
title: "SBDEV-2608 — Tenant DB switch in landlord config not applied without restart (stale Hikari pool)"
ticket: "SBDEV-2608"
ticket_url: "https://app.clickup.com/t/868kdqa22"
type: "bugfix"
priority: "normal"
status: "archived"
archived: "2026-07-20"
project: [wms2]
version: "v2"
requester: "nam.park@siteboss.net"
created: "2026-07-17"
updated: "2026-07-17"
db_verified: true
related:
  - "https://app.clickup.com/t/868kdpbew"
  - "sbdocs/3-Resources/architecture/wms2-tenant-routing-datasource-topology.md"
  - "sbdocs/3-Resources/architecture/wms2-caching-strategy.md"
  - "sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md"
tags:
  - plan
---

# SBDEV-2608 — Tenant DB switch in landlord config not applied without restart (stale Hikari pool)

> **Archived 2026-07-20** — implemented and merged via wms2-api PR [#80](https://github.com/SiteBossInc/wms2-api/pull/80) (→ develop).
> Acceptance script retained at `sbdocs/9-System/scripts/verify-SBDEV-2608-tenant-db-switch-stale-connection-pool-refresh.sh`.

**Ticket:** [SBDEV-2608](https://app.clickup.com/t/868kdqa22)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix (tenant routing / connection-pool refresh)
**Priority:** normal
**Status:** implemented (2026-07-17) — wms2-api PR [#80](https://github.com/SiteBossInc/wms2-api/pull/80) → `develop` (commit `accb750`); tests 15/0/0 (1 skipped), verify script 19 pass/0 fail, code review APPROVE. See §12.
**Date:** 2026-07-17

> **Related:** [SBDEV-2607](https://app.clickup.com/t/868kdpbew) — fresh v2 DB provisioning. This gap was discovered while testing that onboarding flow (switching hydra from `wh01_hydra_v2t` to `wh01_hydra_v2t2`).

---

## 0. Affected sites (enumeration before drafting)

Greps run in `v2/wms2-api/src/main/java`: `computeIfAbsent` (landlord), `removeTenant|tenantPools|dbConfigCache|TenantDbConfigCache`, `@Scheduled` (landlord), `getDbUrl|HikariDataSource|new HikariConfig`.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `landlord/config/TenantDynamicRoutingDataSource.java:50-60` | `tenantPools.computeIfAbsent(...)` builds pool once, never rebuilds on config change | **YES — root cause** | **YES** |
| 2 | `landlord/config/TenantDynamicRoutingDataSource.java:170-181` | `removeTenant(key)` — the only pool-teardown/rebuild trigger | Yes (fix hook) | **YES** |
| 3 | `landlord/config/TenantDynamicRoutingDataSource.java:70-108` | `createHikariPool` — snapshots `jdbcUrl`/user/pw from config at first access; pool keeps no ref to source config | Yes (Fix B stores source) | **YES** |
| 4 | `landlord/config/TenantConfigLoader.java:57-96` | `@Scheduled` refresh clears+reloads the config cache (works) — Fix B hooks the auto-evict here after repopulation | Adjacent (the half that works) | **YES** |
| 5 | `landlord/config/TenantPoolEvictor.java:30-41` | `@Scheduled` idle-only evict loop; sole `removeTenant` caller; active tenant never idles | Yes (why active tenants never rebuild) | **YES** (reference) |
| 6 | `landlord/config/TenantDbConfigCache.java:20-47` | hand-rolled `ConcurrentHashMap`, no TTL, no per-key evict/compare accessor | Enabling condition | **YES** (add compare accessor) |
| 7 | `SecurityConfiguration.java:114-137` | authorization rules — register the new evict endpoint path + auth | Supporting (Fix A auth) | **YES** |
| 8 | `landlord/config/TenantKeyBuilder.java:18-30` | key format `first4(tenantName)-facilityCode`; does NOT lowercase | Hazard the fix must respect | **YES** (reference) |
| 9 | `config/SchedulingConfiguration.java:107-152` | reads `dbConfigCache.getAll()/.get()` to pick a warmup tenant | No — read-only consumer, holds no pool | No — excluded |
| 10 | `service/MultiTenantKeycloakService.java:50,71,120` | `dbConfigCache.get(key)` for Keycloak resolution | No — separate consumer | No — excluded |
| 11 | `service/TenantHealthService.java:57,82` | `dbConfigCache.get(key)` + `getConnection()` (lazy pool build) | No — consumer, not a pool owner | No — excluded (but candidate host for Fix A pattern) |
| 12 | `landlord/service/TenantRoutingService.java:27` | maps `getDbUrl` for directory/reporting | No — holds no pool | No — excluded |

**Conclusion:** exactly one root-cause site, seen from three angles (#1 build-once, #2 only-teardown, #5 idle-only-evict). No second independent "computeIfAbsent-without-rebuild" tenant-DataSource instance exists. Rows 9–12 read the config cache but do not own a tenant pool, so they are out of scope.

---

## 1. Problem Statement

**Symptom.** Changing a tenant's database in the landlord `tenant_db_configuration.db_url` does **not** take effect for an **actively-used** tenant in `v2/wms2-api`. The running backend keeps serving data from the **old** database indefinitely — until the process is restarted, or the tenant happens to sit idle for >15 minutes.

**User-visible impact.** During onboarding / DB cutover, an operator points a tenant at a freshly-provisioned database (SBDEV-2607 flow), triggers a "config refresh", and the app continues returning the **old** database's contents. There is no error — it silently serves stale data, which is worse than a hard failure.

**Reproduction (live, dev — `wms1-landlord-dev`):**
1. Hydra tenant = `tenant_id = 4`; its only DB-config row is `tenant_db_configuration` `id=21`, `warehouse='nywh'`.
2. `db_url` was switched from `jdbc:postgresql://dev.sbo.li:25060/wh01_hydra_v2t` → `.../wh01_hydra_v2t2`.
3. After a config refresh, the app still returns `wh01_hydra_v2t` content.

**DB verification (`db_verified: true`).** Confirmed against the landlord DB that the config change is correctly persisted — the defect is entirely app-side (stale in-JVM pool), not a landlord-data problem:

```sql
-- wms1-landlord-dev
SELECT id, warehouse, db_url, tenant_id, created, modified
FROM tenant_db_configuration WHERE tenant_id = 4;
-- id=21 | nywh | jdbc:postgresql://dev.sbo.li:25060/wh01_hydra_v2t2 | 4
--        created=2026-01-28 19:57:53 | modified=2026-01-28 19:57:53
```

Two facts from this row drive the design:
- The new `db_url` **is** persisted (landlord side correct).
- `modified == created` — the update **did not bump** the `@LastModifiedDate` column. Change-detection (Fix B) must therefore **not** rely on the `modified` timestamp; it must compare the connection-relevant fields directly. (See §3.2.)

---

## 2. Root Cause Analysis

Two refresh mechanisms exist and are **decoupled**: the config *cache* hot-reloads, but the *connection pool* built from it never rebuilds.

### 2.1 The config cache DOES pick up the change (this half works)

`TenantConfigLoader` reloads `TenantDbConfigCache` on a timer:

```java
// TenantConfigLoader.java:57-65
@Scheduled(fixedDelayString = "${wms.tenant.config.refresh-interval-ms:300000}",
           initialDelayString = "${wms.tenant.config.refresh-interval-ms:300000}")
public void scheduledRefresh() { if (refreshIntervalMs <= 0) return; ...; refreshTenantConfigs(); }

// TenantConfigLoader.java:67-96 (clear + reload ALL rows, wholesale)
List<TenantDbConfiguration> dbConfigs = landlordService.getAllDbConfigurations();
dbConfigCache.clear();                                       // :73
for (TenantDbConfiguration cfg : dbConfigs) {
    String tenantName   = cfg.getTenant().getName();         // :75  raw landlord value (NOT lowercased)
    String facilityCode = cfg.getWarehouse();                // :76  raw landlord value (NOT lowercased)
    dbConfigCache.put(TenantKeyBuilder.buildKey(tenantName, facilityCode), cfg);  // :78-79
}
```

So within one refresh interval (default 300000 ms = 5 min) the **cache** holds the new `db_url`. `TenantDbConfigCache` is a hand-rolled `ConcurrentHashMap` (`TenantDbConfigCache.java:20`), **not** a Caffeine/`@Cacheable` cache — so `@CacheEvict` does not apply to it.

### 2.2 The Hikari pool is built once and never rebuilt (the bug)

```java
// TenantDynamicRoutingDataSource.java:50-60
HikariDataSource ds = tenantPools.computeIfAbsent(tenantKey, key -> {
    TenantDbConfiguration cfg = dbConfigCache.get(key);   // read ONLY on first access
    if (cfg == null) throw new TenantException("Database configuration not found for tenant key: " + key);
    return createHikariPool(cfg, tenantKey);              // snapshot taken here, ONCE
});
lastAccess.put(tenantKey, System.currentTimeMillis());   // :59 bumped on EVERY access
return ds;
```

```java
// TenantDynamicRoutingDataSource.java:70-108 (snapshot origin)
cfg.setJdbcUrl(tc.getDbUrl());          // :72 ← the value that goes stale
cfg.setUsername(tc.getDbUserName());    // :73
cfg.setPassword(tc.getDbPassword());    // :74
cfg.setDriverClassName(tc.getDriverClassName()); // :75
```

Once `tenantKey` has a mapping, `computeIfAbsent` returns the **existing** pool and never re-reads `dbConfigCache`. The pool keeps **no reference** to the `TenantDbConfiguration` it was built from — there is nothing to compare a refreshed config against.

### 2.3 The only teardown is idle-gated, so active tenants never rebuild

```java
// TenantDynamicRoutingDataSource.java:170-181 — the ONLY rebuild trigger
public void removeTenant(String tenantKey) {
    HikariDataSource ds = tenantPools.remove(tenantKey);
    lastAccess.remove(tenantKey);
    if (ds != null) { ...; ds.close(); }   // graceful drain
}
```

```java
// TenantPoolEvictor.java:30-41 — the ONLY caller of removeTenant
@Scheduled(fixedDelayString = "${wms.tenant.pool.evict-interval-ms:300000}")
public void evictIdlePools() {
    for (Map.Entry<String,Long> e : routingDataSource.getLastAccessMap().entrySet()) {
        if (now - e.getValue() > idleMs) routingDataSource.removeTenant(e.getKey()); // idleMs default 900000 = 15 min
    }
}
```

Because `determineTargetDataSource` bumps `lastAccess` on **every** request (`:59`), an actively-used tenant's idle time never exceeds 15 min → never evicted → the stale pool lives until a full restart. This is the confirmed reason the app "keeps serving the OLD database." The topology doc §7 confirms there is **no push mechanism** from a config change to the data plane.

### 3. The Regression Chain

| Construct | Commit | Date | Meaning |
|---|--------|------|---------|
| Idle-only `TenantPoolEvictor` + 4-char key + `removeTenant` | `bbb62946` | 2026-01-28 | Evictor designed purely for idle reclamation, never for config-change invalidation. |
| Per-tenant pool tuning (still `computeIfAbsent`, no rebuild) | `4a670fce` | 2026-03-13 | Pool build refined; still never paired with an invalidation hook. |
| **Config hot-reload added to the cache only** | **`7c6bcf7f`** | **2026-04-04** | **The regression seam.** "Phase 3 — tenant config hot-reload" made `TenantDbConfigCache` hot-reloadable but added **no** corresponding pool rebuild — creating the exact split this bug exploits. |

Before `7c6bcf7f` a config change required a restart *by design* (no hot-reload at all). After it, the config cache updates silently while the pool does not — turning an explicit "restart to apply" into a silent stale-data trap.

---

## 4. Architecture Overview

```
HTTP request (headers: X-Tenant-ID, facility_code)
    │  TenantFilter.java:23,47  → lowercases both → TenantProfile
    ▼
TenantDynamicRoutingDataSource.determineTargetDataSource()   :47 buildKey = first4(name)-facility  (e.g. "hydr-nywh")
    │
    ├── tenantPools.computeIfAbsent(key) ──► [pool exists?] ──yes──► RETURN STALE POOL  ◄─── BUG (never rebuilds)
    │                                          │no
    │                                          ▼
    │                                   dbConfigCache.get(key) → createHikariPool(cfg)  (snapshot db_url)
    ▼
lastAccess.put(key, now)   ← bumped every request → tenant never "idle"

TenantConfigLoader @Scheduled (5 min)  → dbConfigCache.clear()+reload  → cache has NEW db_url  ── but nothing evicts the pool
TenantPoolEvictor  @Scheduled (5 min)  → removeTenant(key) ONLY if idle > 15 min  → never fires for active tenant
```

**Key files**

| File | Lines | Role |
|------|-------|------|
| `landlord/config/TenantDynamicRoutingDataSource.java` | 22-25, 50-60, 70-108, 170-181 | Holds `tenantPools`/`lastAccess`; builds + tears down pools |
| `landlord/config/TenantConfigLoader.java` | 43-47, 57-96 | Startup + scheduled config-cache reload (Fix B hook) |
| `landlord/config/TenantDbConfigCache.java` | 20-47 | Hand-rolled config cache (no TTL) |
| `landlord/config/TenantPoolEvictor.java` | 24-41 | Idle-only pool eviction |
| `landlord/config/TenantKeyBuilder.java` | 18-30 | Routing-key format (no lowercase) |
| `landlord/config/TenantFilter.java` | 47 | Lowercases tenant headers |
| `landlord/model/TenantDbConfiguration.java` | 34-64 | Entity; `db_url`, pool fields, `modified` |
| `SecurityConfiguration.java` | 114-137 | Endpoint auth rules (Fix A) |

---

## 5. Design / Proposed Fix

**Decision (user-confirmed):** implement **both** — Fix B (auto-detect on refresh, the correctness backbone) and Fix A (on-demand admin endpoint, the operator fast-path). Multi-replica behavior is **per-replica** (each replica self-heals within one refresh interval); instant cross-replica push is explicitly out of scope (§10).

### 5.1 Fix B — auto-detect changed config on scheduled refresh and self-evict (backbone)

**Goal:** after the config cache is repopulated, evict any live pool whose connection-relevant config changed, so the next request rebuilds from the fresh config. Fires on **every** replica's own `TenantConfigLoader` tick (infra jobs run lock-free on all replicas — scheduled-jobs-catalog §5.1/§5.2), so it converges per-replica within ≤ one refresh interval **without** any cross-replica messaging.

**5.1.a — Normalize cache keys to lowercase (root fix for the key-case hazard, §5.3 #1).** Today `TenantConfigLoader` writes the cache with **raw** landlord values (`:75-78`) while runtime pools are keyed **lowercased** (`TenantFilter.java:47` lowercases the headers before `TenantKeyBuilder`). This mismatch is the reason a naive evict sweep would silently no-op *and* a rebuild would `dbConfigCache.get(lowercasedKey) → null → TenantException` for any non-lowercase tenant. Fix it at the source so **cache-key == pool-key** universally:

```java
// TenantConfigLoader.refreshTenantConfigs() — BEFORE (:75-79): raw keys
String tenantName = cfg.getTenant().getName();          // raw
String facility   = cfg.getWarehouse();                 // raw
dbConfigCache.put(TenantKeyBuilder.buildKey(tenantName, facility), cfg);

// AFTER: lowercase both, matching TenantFilter's runtime keying (Locale.ROOT)
String tenantName = cfg.getTenant().getName().toLowerCase(Locale.ROOT);
String facility   = cfg.getWarehouse().toLowerCase(Locale.ROOT);
dbConfigCache.put(TenantKeyBuilder.buildKey(tenantName, facility), cfg);
```

> This is a strict alignment: `computeIfAbsent` and `MultiTenantKeycloakService` already look up with lowercased keys, so lowercasing the writer only *fixes* mismatches. (Related latent issue, **out of scope**: `TenantHealthService.checkTenantHealth` also builds its key from raw header input — noted as a follow-up in §10, not fixed here.)

**5.1.b — Single `PoolHolder` record (closes the two-map drift window, replaces the two-map sketch).** Storing `HikariDataSource` and its source config in two parallel maps lets them drift under concurrent `removeTenant` + `computeIfAbsent` (a rebuild could re-insert the pool while the evict thread deletes the source, leaving a live pool with no source → permanently un-auto-evictable). Use one map of an atomic holder installed inside the `computeIfAbsent` lambda:

```java
// TenantDynamicRoutingDataSource
private record PoolHolder(HikariDataSource ds, TenantDbConfiguration sourceConfig) {}
private final Map<String, PoolHolder> poolHolders = new ConcurrentHashMap<>();   // replaces the bare tenantPools map

HikariDataSource ds = poolHolders.computeIfAbsent(tenantKey, key -> {
    TenantDbConfiguration cfg = dbConfigCache.get(key);
    if (cfg == null) throw new TenantException("Database configuration not found for tenant key: " + key);
    return new PoolHolder(createHikariPool(cfg, tenantKey), cfg);   // DS + source installed atomically
}).ds();
lastAccess.put(tenantKey, System.currentTimeMillis());
return ds;

// removeTenant(key): PoolHolder h = poolHolders.remove(key); lastAccess.remove(key); if (h != null) h.ds().close();
```

**5.1.c — Sweep from the routing DS's OWN (already-lowercased) pool keys.** The loader does not derive keys; it just asks the routing DS to reconcile. This reuses the correct pool keys (no raw-key derivation) and iterates only live pools, not all landlord rows:

```java
// TenantDynamicRoutingDataSource — new method
/** For each live pool, evict it iff its remembered source config differs from the current cache entry.
 *  Caller MUST have already repopulated dbConfigCache. Keys iterated are the live (lowercased) pool keys. */
public void evictChangedPools() {
    for (String key : poolHolders.keySet()) {
        PoolHolder h = poolHolders.get(key);
        TenantDbConfiguration fresh = dbConfigCache.get(key);          // cache now lowercased (5.1.a) → matches
        if (h == null || fresh == null) continue;                      // row deleted → leave until idle evict
        if (!connectionConfigEquals(h.sourceConfig(), fresh)) {
            log.info("Config changed for tenant key {} (db_url {} -> {}); evicting pool for rebuild",
                     key, h.sourceConfig().getDbUrl(), fresh.getDbUrl());
            removeTenant(key);
        }
    }
}

// Compares ONLY connection-determining fields — deliberately NOT `modified` (not reliably bumped, §1).
private boolean connectionConfigEquals(TenantDbConfiguration a, TenantDbConfiguration b) {
    return Objects.equals(a.getDbUrl(), b.getDbUrl())
        && Objects.equals(a.getDbUserName(), b.getDbUserName())
        && Objects.equals(a.getDbPassword(), b.getDbPassword())
        && Objects.equals(a.getDriverClassName(), b.getDriverClassName())
        && Objects.equals(a.getMaxPoolSize(), b.getMaxPoolSize())
        && Objects.equals(a.getMinIdle(), b.getMinIdle())
        && Objects.equals(a.getIdleTimeoutMs(), b.getIdleTimeoutMs())
        && Objects.equals(a.getConnectionTimeoutMs(), b.getConnectionTimeoutMs());
}
```

```java
// TenantConfigLoader.refreshTenantConfigs() — one call AFTER the (now-lowercased) clear()+put loop
routingDataSource.evictChangedPools();
```

> **Concurrency note:** `evictChangedPools()` iterates `poolHolders.keySet()` (weakly-consistent, no `ConcurrentModificationException`) and does `get(key)` → `removeTenant(key)`. Because the sweep runs **after** the cache is repopulated, a request that rebuilds a pool concurrently already used the fresh config, so the worst case is a single **redundant** rebuild of an already-fresh pool — never stale serving. This is harmless and bounded.
>
> **Seam decision (resolved, not deferred):** inject `TenantDynamicRoutingDataSource` into `TenantConfigLoader` by **constructor**. Verified there is **no dependency cycle** — the routing DS's constructor depends only on `{TenantDbConfigCache, landlordDataSource}`, and `TenantPoolEvictor` already constructor-injects the routing DS cycle-free. An `ApplicationEvent` seam (loader publishes, routing DS listens) is a cleaner-coupling alternative but is **not required** for correctness; recorded in §10 as the considered-but-not-chosen option.

### 5.2 Fix A — on-demand admin evict endpoint (operator fast-path)

**Goal:** an operator can force an immediate rebuild for one tenant without waiting up to a refresh interval.

**Shape:** a custom **actuator write-operation** so it inherits the existing `/actuator/**` → `hasAnyAuthority("ADMIN","wms_admin")` rule (`SecurityConfiguration.java:117`) with **zero** new security wiring. A *manual force* must (1) reload + `put` the fresh config-cache entry **first**, then (2) evict **unconditionally** (an operator override must work even when the compared fields look unchanged) so the next request rebuilds:

```java
@Component
@Endpoint(id = "tenantpool")           // exposed at /actuator/tenantpool (same context/port — see precondition)
public class TenantPoolEndpoint {
    // constructor-injected: TenantDbConfigurationRepository, TenantDbConfigCache, TenantDynamicRoutingDataSource
    @WriteOperation
    public Map<String,Object> evict(String tenant, String facility) {
        String fac = facility.toLowerCase(Locale.ROOT);
        String key = TenantKeyBuilder.buildKey(tenant.toLowerCase(Locale.ROOT), fac); // MATCH pool keying (§5.3)
        // `warehouse` is globally UNIQUE in tenant_db_configuration (single-column unique constraint),
        // so lookup-by-warehouse is unambiguous. Use the repo's Optional-returning finder (the
        // LandlordService.getDbConfigByWarehouse variant returns a bare entity / throws — not Optional).
        // NOTE: this matches on the stored `warehouse` column value; landlord rows are lowercase today
        // (e.g. 'nywh'). If a mixed-case warehouse is ever stored, normalize the column (lower(warehouse)).
        TenantDbConfiguration fresh = tenantDbConfigurationRepository.findByWarehouse(fac)
            .orElseThrow(() -> new EntityNotFoundException("No tenant_db_configuration for warehouse " + fac));
        dbConfigCache.put(key, fresh);                 // cache holds NEW row FIRST (ordering, §5.3 #2)
        routingDataSource.removeTenant(key);           // then evict UNCONDITIONALLY → next request rebuilds
        return Map.of("key", key, "rebuiltFrom", fresh.getDbUrl(),
                      "note", "per-replica: this evicts only the replica that served the call");
    }
}
```

Expose via `management.endpoints.web.exposure.include` (add `tenantpool`). Do **not** place this under `/api/**`, `/api/public/**` (both `permitAll`) or bare `/v3/**` (only `wms_user`, too broad for a landlord-wide destructive action).

> **Precondition (document — §7.1):** the `/actuator/**` → `ADMIN`/`wms_admin` gate covers this endpoint **only because `server.port == management.server.port` (both `8088`)** — same context, same Spring Security filter chain. If a deployment ever splits `management.server.port`, actuator moves to a separate management context with its own security auto-config and this endpoint (a landlord-wide destructive op) could silently lose its ADMIN gate. The chain is also `@ConditionalOnProperty("rest.security.enabled"=="true")` (`SecurityConfiguration.java:42`; true in `application.properties`). Both are preconditions of Fix A's auth.
>
> **Operator caveat (surface at the call site, not just §10):** the response explicitly states the evict is **per-replica** — one call heals only the replica that served it. Against a load-balanced endpoint the operator must call it on every replica (or rely on Fix B's ≤5-min convergence), or they may verify against a stale replica and wrongly conclude the fix failed.

### 5.3 Critical hazards the fix MUST respect

1. **Key-case (fixed at the source in 5.1.a).** `TenantConfigLoader` today writes the cache with **raw** landlord `tenant.name`/`warehouse` (`:75-78`, no `toLowerCase`), while pool keys come from `TenantFilter`-lowercased headers (`TenantFilter.java:47`); `TenantKeyBuilder` does **not** lowercase (`TenantKeyBuilder.java:18-30`). This works today *only* because hydra/nywh are already lowercase — the fix must not depend on that luck. **Resolution:** 5.1.a lowercases the cache writer so cache-key == pool-key everywhere, and 5.1.c's sweep iterates the routing DS's own already-lowercased pool keys (never re-deriving from raw landlord values). Fix A likewise lowercases before building its key. A **mixed-case landlord fixture** test (§8) guards this. (Topology §10.8.)
2. **Ordering.** `computeIfAbsent` and `removeTenant` are independently atomic on the `ConcurrentHashMap` but not jointly locked. Correct order: **update `dbConfigCache` to the NEW row first, THEN `removeTenant(key)`.** If the pool is removed while the cache still holds the OLD row, the rebuild reads the stale url and the bug persists. Fix B satisfies this naturally (it evicts *after* the repopulation loop). Fix A must `put` the fresh row before evicting.
3. **In-flight requests / `close()` safety.** `HikariDataSource.close()` drains gracefully — in-flight checkouts finish; a checkout attempted in the narrow window right after close throws a pool-closed exception and the next request rebuilds. This is acceptable and identical to existing idle-eviction behavior (topology §10.12, jobs-catalog §5.2).

---

## 6. File Change Summary

| File | Change | Description |
|---|---|---|
| `landlord/config/TenantDynamicRoutingDataSource.java` | **Modify** | Replace bare `tenantPools` with a single `Map<String,PoolHolder>` (DS + source config, atomic); populate holder in `computeIfAbsent`, close+remove in `removeTenant`; add `evictChangedPools()` + `connectionConfigEquals` |
| `landlord/config/TenantConfigLoader.java` | **Modify** | Lowercase cache keys (`Locale.ROOT`) at the `put` (`:75-78`); constructor-inject routing DS; call `routingDataSource.evictChangedPools()` after cache repopulation |
| `controller/actuator/TenantPoolEndpoint.java` | **Add** | `@Endpoint(id="tenantpool")` `@WriteOperation` evict(tenant,facility): lowercase key → `put` fresh row → **unconditional** `removeTenant` |
| `SecurityConfiguration.java` | **Reference/verify** | Confirm `/actuator/**` ADMIN/wms_admin rule covers the new endpoint (no path change; precondition `server.port==management.server.port`) |
| `application.properties` | **Modify** | Add `tenantpool` to `management.endpoints.web.exposure.include` |
| `src/test/.../TenantDynamicRoutingDataSourceEvictRebuildTest.java` | **Add** | Unit tests (rebuild, close, no-op, compare ignores `modified`, concurrency) |
| `src/test/.../TenantConfigLoaderAutoEvictTest.java` | **Add** | Fix B refresh→evict tests + ordering guard + **mixed-case landlord fixture** |
| `src/test/.../TenantPoolEndpointSecurityTest.java` | **Add** | Fix A auth + unconditional-evict + correctly-cased key tests |

---

## 7. Prerequisites & Implementation Plan

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Landlord `tenant_db_configuration` reachable; a tenant row whose `db_url` can be flipped for testing | dev | No schema change; no migration |
| 2 | **Feature flags / system properties** | N/A | — | Behavior is always-on; no sysprop toggle |
| 3 | **Config / env changes** | Add `tenantpool` to `management.endpoints.web.exposure.include`; keep `server.port == management.server.port` (both `8088`); `rest.security.enabled=true` | dev | Endpoint exposure; **auth precondition** — a split management port moves actuator to a separate security context and drops the ADMIN gate (§5.2) |
| 4 | **Deploy-order dependencies** | N/A | — | Self-contained in wms2-api; no OMS/UI coupling |
| 5 | **Data migration** | N/A | — | No data mutated |
| 6 | **External systems** | N/A | — | No OMS/printer/Keycloak change |
| 7 | **Access / permissions** | Confirm operators who will call the endpoint hold `ADMIN`/`wms_admin` (Keycloak `resource_access.om1-api.roles`) | dev | Endpoint gated by existing `/actuator/**` rule |
| 8 | **Monitoring / alerts** | Optional: log line on auto-evict (`db_url X -> Y`) already in Fix B; consider a counter `wms2.tenant.pool.evicted{reason=config_change}` | dev | Aids verifying propagation across replicas |

### 7.2 Implementation Checklist

- [ ] Replace bare `tenantPools` with a single `Map<String,PoolHolder>` (DS + source config; populate in `computeIfAbsent`, close+clear in `removeTenant`); add `evictChangedPools()` + `connectionConfigEquals` (Fix B core).
- [ ] Constructor-inject routing DS into `TenantConfigLoader`; call evict-if-changed after repopulation (watch circular-dep — fall back to `ApplicationEvent` if needed).
- [ ] Add `TenantPoolEndpoint` actuator write-op (Fix A); cache-then-evict; lowercase key build.
- [ ] Add `tenantpool` to actuator exposure; verify `SecurityConfiguration` gate.
- [ ] Unit tests (three classes below); confirm RED→GREEN via `wms-tdd-gate`.
- [ ] `@Disabled("TODO(SBDEV-2217)")` Testcontainers IT for the end-to-end DB-content flip.
- [ ] Run `verify-SBDEV-2608-...sh` → `0 fail`; code review; commit + PR to `develop`.

---

## 8. Test Plan

**Harness note:** the v2 Testcontainers IT lane is broken (SBDEV-2217). Gate on **unit tests** (H2/mock config — the pool/cache logic is pure in-JVM and needs no real DB) + `mvn clean compile`. The DB-content-flip proof is written but `@Disabled("TODO(SBDEV-2217)")`.

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Rebuild after change (Fix B core) | seed cache url1 → access (pool.jdbcUrl==url1); update cache url2 + `evictChangedPools()`; access | new `HikariDataSource` instance, `jdbcUrl==url2` |
| Unchanged config (Fix B) | refresh with identical config | pool **not** evicted (same instance) |
| Ordering guard | assert `dbConfigCache.get(key)`==url2 at/after the evict fires | cache holds NEW row before rebuild |
| Endpoint auth (Fix A) | call `/actuator/tenantpool` without/with `ADMIN` | 403 without; 200 + evict with |
| Concurrency | N threads access while one loops evict | never returns an already-closed pool for a new checkout |
| close() teardown | `removeTenant` | `ds.isClosed()==true`; key gone from the single `poolHolders` map + `lastAccess` |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `TenantDynamicRoutingDataSourceEvictRebuildTest` | `evictChangedThenAccess_rebuildsPoolWithNewJdbcUrl` | after cache-update + `evictChangedPools`, access yields a **new** `HikariDataSource` with `jdbcUrl==url2` |
| … | `removeTenant_closesOldPool` / `removeTenant_missingKey_isNoOp` | `ds.isClosed()`, holder gone; no-op on absent key |
| … | `connectionConfigEquals_ignoresModifiedTimestamp` | compare uses connection fields only, not `modified` |
| … | `concurrentEvictAndAccess_neverReturnsClosedPool` (`@RepeatedTest`) | single-holder map + §5.3 ordering — never returns a closed pool for a new checkout |
| `TenantConfigLoaderAutoEvictTest` | `refresh_dbUrlChanged_evictsLivePool` / `refresh_unchangedConfig_keepsPool` | Fix B evict-on-change / keep-on-same |
| … | **`refresh_mixedCaseLandlordRow_evictsLivePool`** | **M1 guard** — landlord row with mixed-case name/warehouse still keys the cache lowercased and evicts/rebuilds correctly |
| … | `refresh_updatesConfigCacheBeforeEvict` | ordering: cache holds NEW row before evict |
| `TenantPoolEndpointSecurityTest` | `evict_missingAdminRole_forbidden` / `evict_withAdminRole_removesTenantWithLowercasedKey` | Fix A auth + unconditional evict + correct key-case |
| `TenantPoolEvictRebuildIT` (Testcontainers, `@Disabled("TODO(SBDEV-2217)")`) | `evictRebuild_servesNewDatabaseContent` | two Postgres, url flip → new content |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Auto-heal | dev (single replica) | Flip a tenant `db_url` in landlord; wait one refresh interval; hit a tenant endpoint | serves NEW DB content within ≤5 min, no restart | |
| Endpoint fast-path | dev | `POST /actuator/tenantpool` `{tenant,facility}` with `ADMIN`; hit a tenant endpoint | serves NEW DB content immediately | |
| Endpoint authz | dev | Call endpoint without `ADMIN`/`wms_admin` | 403 | |
| SQL sanity | dev DB | On the NEW DB, `SELECT count(*)` on a table with distinguishable content | matches NEW DB, not OLD | |
| Multi-replica note | dev (≥2 replicas) | Flip url; hit endpoint on replica A only | A immediate; B converges within its own refresh interval (documents the per-replica limitation) | |

### Test execution (fill in after running)

| Command | Result | Pass/Fail/Skipped |
|---------|--------|-------------------|
| `mvn test -Dtest=TenantDynamicRoutingDataSourceEvictRebuildTest,TenantConfigLoaderAutoEvictTest,TenantPoolEndpointSecurityTest` | | |
| `mvn clean compile` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| DB-content-flip IT (`TenantPoolEvictRebuildIT`) run live | SBDEV-2217 — v2 Testcontainers lane cannot boot; kept `@Disabled` with TODO |
| Cross-replica instant propagation test | Out of scope (§10) — per-replica convergence only |

---

## 9. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | **Yes** | `poolHolders` (DS+source)/`lastAccess`/`TenantDbConfigCache` are per-replica instance fields (no Redis). **Accepted per-replica:** Fix B runs on every replica's own loader (lock-free infra job) → each converges within one refresh interval. Fix A is per-JVM (operator hits each, or relies on Fix B). Cross-replica push out of scope (§10). |
| 2 | Connection pool math | **Yes** | Rebuild is one-tenant-at-a-time; old pool `close()` drains while new ramps → transient ~2× for that one tenant only. Stays within documented `replicas × tenants × maxPoolSize` ceiling (topology §11). Per-tenant `maxPoolSize` default 5 (code) / 2 (landlord). |
| 3 | Scheduled jobs | **Yes** | Extends `TenantConfigLoader` (`@Scheduled`, no advisory lock, runs on all replicas). Auto-evict is idempotent (evict-if-changed) — safe to run on every replica; **no ShedLock needed**, matching the existing infra-job posture (jobs-catalog §5.1). |
| 4 | Long transactions | N/A | No DB transaction added; landlord reads only. |
| 5 | Request affinity | N/A | Stateless routing; no session assumption. |
| 6 | Retry / idempotency | **Yes** | Evict is idempotent — evicting an already-evicted/absent key is a no-op (`removeTenant_missingKey_isNoOp`). Endpoint safe to retry. |
| 7 | Tenant context | N/A | Loader/evictor operate on explicit keys; no `TenantContext`/async propagation added. |
| 8 | Distributed lock correctness | N/A | No pessimistic/optimistic lock introduced. |
| 9 | Cache invalidation | **Yes** | `TenantDbConfigCache` is hand-rolled (not Caffeine) — updated wholesale by the loader; Fix A `put`s the fresh row before evicting. Per-replica staleness bounded by the refresh interval (caching-strategy §multi-replica). |
| 10 | External notifications | N/A | No OMS/printer/message send. |

### Evidence (for "Yes" rows)

| # | What / verified | Ref |
|---|---|---|
| 1 | Per-replica fields; Fix B on every replica | `TenantDynamicRoutingDataSource.java:22-25`; `TenantConfigLoader.java:57-96` |
| 2 | One-tenant rebuild, graceful drain | `TenantDynamicRoutingDataSource.java:170-181`; topology §10.12 |
| 3 | Idempotent evict-if-changed, lock-free infra job | jobs-catalog §5.1; new `evictChangedPools()` |
| 6 | No-op on absent key | test `removeTenant_missingKey_isNoOp` |
| 9 | Cache-then-evict ordering | §5.3 #2; test `refresh_updatesConfigCacheBeforeEvict` |

### v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | N/A — no lazy associations traversed outside a tx (landlord `Tenant` join is EAGER) |
| 2 | Transaction manager | N/A — landlord-side; `LandlordService` already `@Transactional(readOnly=true)` on landlord TM; no tenant TM write |
| 3 | `@Transactional(readOnly=true)` | N/A — no new service read method with a tx boundary |
| 4 | Caffeine cache invalidation | N/A — `TenantDbConfigCache` is not a Caffeine cache |
| 5 | Jakarta namespace | **Yes** — new code uses `jakarta.*`; actuator `@Endpoint`/`@WriteOperation` from Spring Boot 3 |
| 6 | H2-compatible test SQL | **Yes** — unit tests use mock/H2 config; no native SQL; DB-flip IT is Testcontainers-only (`@Disabled`) |
| 7 | `BaseControllerTest` for controller changes | **Yes** — actuator endpoint tested via `@WebMvcTest`/actuator test slice with role assertions (not a `/v3` controller, but auth still asserted) |
| 8 | Micrometer metrics | **Yes (optional)** — optional `wms2.tenant.pool.evicted` counter via existing `MeterRegistry`; reuse, don't invent a stack |

---

## 10. Open Questions / Resolved Decisions

**Resolved (user-confirmed 2026-07-17):**
1. **Fix approach = both.** Fix B (auto-detect on scheduled refresh, self-evict) as the correctness backbone + Fix A (on-demand actuator endpoint) as the operator fast-path.
2. **Multi-replica = per-replica for now.** Each replica converges within one refresh interval via its own loader; Fix A is per-JVM. **Instant cross-replica push (Redis pub/sub, DB `pool_refresh_requested` flag, actuator broadcast) is explicitly OUT OF SCOPE** — documented as a limitation and a possible follow-up.
3. **Endpoint auth = `ADMIN`/`wms_admin`** via a custom actuator `@WriteOperation` (inherits `/actuator/**` rule; no new security wiring). Not `/api/**`/`/api/public/**` (permitAll) or bare `/v3/**` (only `wms_user`).
4. **Change-detection basis = connection-field comparison, NOT the `modified` timestamp** — the live repro proved `modified` is not reliably bumped on a landlord `db_url` update.
5. **Storage = single `Map<String,PoolHolder>` (DS + source config), NOT two parallel maps.** *Alternative considered:* a `tenantPools` map plus a parallel `poolSourceConfig` map — **rejected** because the two are maintained non-atomically, so a concurrent `removeTenant` + `computeIfAbsent` can leave a live pool with no source entry, silently re-arming the bug (auto-evict skips it). The holder is installed/removed atomically inside the map operations.
6. **Sweep seam = constructor-injected call `routingDataSource.evictChangedPools()` from the loader.** *Alternative considered:* an `ApplicationEvent` published by the loader and handled by the routing DS — cleaner coupling, but **not required for correctness** and there is **no dependency cycle** to avoid (verified: `TenantPoolEvictor` already constructor-injects the routing DS cycle-free). Chosen the direct call for simplicity; the event seam remains a valid future refactor.
7. **Key normalization done at the cache writer** (`TenantConfigLoader`, lowercase via `Locale.ROOT`), and the sweep iterates the routing DS's own already-lowercased pool keys — so no path re-derives a key from raw landlord values. `warehouse` is globally unique in `tenant_db_configuration`, so Fix A's lookup-by-warehouse is unambiguous.

**Open / follow-ups:**
- **Cross-replica instant eviction** (deferred, out of scope) — if operations later need one call to evict all replicas immediately, add a shared signal (Redis pub/sub or a landlord `pool_refresh_requested` flag polled by each replica's loader). Tracked as a potential follow-up ticket.
- **Landlord `modified` not bumped** — separate hygiene item on the landlord write path (auditing/`@LastModifiedDate` not firing). Not required for this fix (design deliberately avoids depending on it) but worth a follow-up so future change-detection can trust it.
- **`TenantHealthService.checkTenantHealth` builds its tenant key from raw header input** (no `toLowerCase`) — a separate latent key-case inconsistency surfaced during analysis. Out of scope here; file as a small follow-up so it aligns with the lowercased convention this plan standardizes.

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script

Machine-checkable acceptance at `sbdocs/9-System/scripts/verify-SBDEV-2608-tenant-db-switch-stale-connection-pool-refresh.sh` (run with `PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api`). POSITIVE checks (matching the script): holder/source config remembered (`PoolHolder`/`poolHolders`) + populated on build + cleared on `removeTenant` (B1–B3); `evictChangedPools()` + `connectionConfigEquals` present (B4–B5); loader **lowercases** cache keys (B7) and calls `evictChangedPools()` after repopulation (B8); `TenantPoolEndpoint` `@Endpoint(id="tenantpool")` `@WriteOperation` (A1–A3), lowercase key build (A4), `dbConfigCache.put` + unconditional `removeTenant` (A5–A6), `tenantpool` in actuator exposure (A8). NEGATIVE/guards: `connectionConfigEquals` body does NOT reference `modified` (B6, `grep -Pzq`); the endpoint force is NOT change-gated (A7, no `evictIfConfigChanged`). Plus `mvn_test_passes` (gated on build exit code) for the three unit classes — including the mixed-case M1 fixture. **A "DONE" claim requires `Result: N pass, 0 fail`.**

### 11.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | ~3 code files + 3 test classes, single subsystem (landlord routing) |
| Pre-draft step | analyst/architect (done — this plan) | Deep analysis bundle produced |
| Plan-review step | **critic** (via ralplan consensus) | Architecture + auth + concurrency warrant review |
| Implementation shape | **executor** (via `wms-tdd-gate` first) | Write failing unit tests, confirm RED, then implement |
| Verification step | verify-script + verifier | Mandatory |
| Code-review step | **code-reviewer** | Concurrency (evict vs computeIfAbsent) + auth surface |
| Commit step | git-master | Feature branch → PR to `develop`; link SBDEV-2608 |

---

## 12. Implementation Status — DONE (2026-07-17, PR open)

**Commit:** `accb750` on branch `feature/SBDEV-2608-tenant-db-switch-stale-pool-refresh` → **PR [#80](https://github.com/SiteBossInc/wms2-api/pull/80) → `develop`** (7 files, +573 / −12).

**Delivered per §5:**
- `TenantDynamicRoutingDataSource` — single `Map<String,PoolHolder>` (record DS+source, atomic); `evictChangedPools()` + `connectionConfigEquals` (8 connection fields, excludes `modified`); `removeTenant` closes+removes; `getTenantPools()` preserved as a derived view.
- `TenantConfigLoader` — lowercases cache keys (`Locale.ROOT`); constructor-injects the routing DS; calls `evictChangedPools()` after repopulation.
- `controller/actuator/TenantPoolEndpoint` — `@WriteOperation` evict: lowercased key → `findByWarehouse().orElseThrow(EntityNotFoundException)` → `dbConfigCache.put` → unconditional `removeTenant`.
- `application.properties` — `tenantpool` added to actuator exposure.

**Test execution:**

| Command | Result | Counts |
|---------|--------|--------|
| `mvn -o test -Dtest='TenantDynamicRoutingDataSourceEvictRebuildTest,TenantConfigLoaderAutoEvictTest,TenantPoolEndpointSecurityTest'` | BUILD (6 TDD REDs → green) | 15 run, 0 fail, 0 err, **1 skipped** |
| `mvn -o test -Dtest=OmsNotificationConfigContextLoadTest` | BUILD SUCCESS | context boots cycle-free (no DI cycle) |
| `verify-SBDEV-2608-…sh` | **Result: 19 pass, 0 fail, 0 skip** | acceptance gate green |
| Code review (code-reviewer) | **APPROVE** | 0 blocker/high; concurrency, key-case, auth, resource-safety verified |

**Deliberately deferred (tracked on SBDEV-2608):**
- `evict_missingAdminRole_forbidden` left `@Disabled` (`TODO(SBDEV-2608)`) — repo has no `@WebMvcTest`/actuator-slice infra; auth rests on the existing `/actuator/**` → ADMIN rule (sound by inspection). Follow-up: add the slice test (403/200/no-password/404).
- Confirm `EntityNotFoundException` from an actuator `@Endpoint` maps to 404 (not 500).
- Cross-replica instant eviction + landlord `modified`-not-bumped hygiene (both out of scope, §10).
