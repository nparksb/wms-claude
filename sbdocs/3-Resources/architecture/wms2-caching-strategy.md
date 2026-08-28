---
title: "WMS v2 — Caching Strategy (Caffeine)"
type: architecture
status: active
system: wms2
owner: Nam Park
created: 2026-04-26
updated: 2026-06-11
last_verified: 2026-06-11
verified_by: code read of CacheConfig.java, SyspropService, ClientService, ItemdataService, LocationService, KeycloakService, SystemPropertyController, ItemDataController, FileImportController, SkuRestController
related:
  - ./wms2-end-to-end-request-journey.md
  - ./wms2-transaction-osiv-boundary-map.md
  - ./wms2-tenant-routing-datasource-topology.md
tags:
  - architecture
  - caching
  - caffeine
  - multi-tenancy
  - wms2
---

# WMS v2 — Caching Strategy (Caffeine)

**Scope:** Application-level in-process caching in `v2/wms2-api` · **Version:** v2 only
**Owner:** Nam Park · **Last verified:** 2026-05-08

---

## §1 Overview

### Why v2 caches and v1 does not

`v1/wms-api` (Spring Boot 2.3 / Java 8) has no application-level caching — every request goes to PostgreSQL. `v2/wms2-api` introduced Caffeine caching to reduce repeated DB reads for four high-frequency, low-churn reference datasets: system properties, client records, item master data, and location records. These are read on virtually every warehouse operation (pick, receive, put-away) but change infrequently, making them ideal cache candidates.

### Caffeine, not Redis

The `CacheConfig` comment explains the decision directly:

> TTLs reduced for multi-replica safety — local Caffeine caches become stale across replicas. Plan Redis migration for full cross-replica consistency.

**Current state:** Caffeine is an in-process, JVM-heap cache. Each replica holds its own independent cache state. A write on replica A does not invalidate replica B's cache. TTLs have been reduced (to 5 minutes) as a mitigation, but this is an acknowledged gap, not a full solution. Redis is the planned replacement for cross-replica coherence but has not been implemented.

**Consequence for developers:** Any mutation that should be immediately visible across all replicas cannot rely solely on `@CacheEvict`. In multi-replica production deployments, up to 5 minutes of stale data is possible on non-evicting replicas after a write.

---

## §2 Cache Inventory

All four Spring-managed caches are defined in `CacheConfig.java` (`net.aim_ai.wms.config`). All use `expireAfterAccess` (TTL resets on each read) and `recordStats()`.

| Cache name  | What is cached                                   | Max entries | TTL (access-based) | Eviction policy         |
|-------------|--------------------------------------------------|-------------|--------------------|-------------------------|
| `sysprops`  | `Sysprop` entity — warehouse configuration KV pairs | 200      | 5 minutes          | LRU + TTL expiry        |
| `clients`   | `Client` entity — warehouse client/owner records | 100         | 5 minutes          | LRU + TTL expiry        |
| `locations` | `Location` entity — physical warehouse locations | 2000        | 5 minutes          | LRU + TTL expiry        |
| `itemdata`  | `Itemdata` entity — SKU / item master records    | 3000        | 5 minutes          | LRU + TTL expiry        |

**Note on `expireAfterAccess` vs `expireAfterWrite`:** The `sysprops`, `clients`, `locations`, and `itemdata` caches all use `expireAfterAccess`. A cached entry that is read frequently will never expire naturally — it will stay live indefinitely as long as it is accessed within the 5-minute window. For low-traffic tenants this is less of a concern, but for busy tenants a stale entry could persist much longer than 5 minutes if it is read continuously. This is a deliberate trade-off (hot data stays cached) but means `@CacheEvict` discipline is critical for correctness.

**Out-of-band caches (not in `CacheConfig`):** two manually managed Caffeine caches live outside Spring Cache annotations. `KeycloakService.userCache` caches `UserRepresentation` objects from Keycloak. The landlord `MultiTenantJwtDecoder` caches per-tenant `JwtDecoder` instances to avoid rebuilding JWK sets on every request — added by the 260610 hardening Phase B (GAP F fix, PR #41) to bound what was previously an unbounded, never-evicted `ConcurrentHashMap`. See [end-to-end request journey §4.2](./wms2-end-to-end-request-journey.md) for where the decoder cache sits in the auth chain.

| Cache       | What is cached            | Max entries | TTL (write-based) | Managed by      |
|-------------|---------------------------|-------------|-------------------|-----------------|
| `userCache` | Keycloak `UserRepresentation` per username | 500 | 15 minutes (`expireAfterWrite`) | `KeycloakService` manually |
| `jwtDecoders` | Per-tenant `JwtDecoder` instances (one per Keycloak realm) | 200 | 24 hours (`expireAfterWrite`) | `MultiTenantJwtDecoder` manually (260610 Phase B) |

---

## §3 Multi-Tenant Cache Key Isolation

**This is the most critical correctness property.** All four Spring-managed caches store data that is tenant-scoped. Without key isolation, tenant A could read tenant B's cached data.

### Key pattern

Every `@Cacheable` annotation uses SpEL to prefix the logical key with the current tenant's facility code:

```
T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + <discriminator>
```

`TenantContext` is a thread-local holder set by `TenantFilter` at the start of every request. `getFacilityCode()` returns the 2-char warehouse code that is part of the 4-char routing key. This means keys are namespaced per warehouse, not per tenant+warehouse combination — tenants sharing a warehouse code would collide, but the routing architecture ensures this does not happen.

### Key examples by cache

| Cache      | Effective key format                          | Example                  |
|------------|-----------------------------------------------|--------------------------|
| `sysprops` | `<facilityCode>:<propKey>`                    | `WH:PICK_CONFIRM_REQUIRED` |
| `clients`  | `<facilityCode>:<clientNumber>`               | `WH:CLIENT001`           |
| `clients`  | `<facilityCode>:SYSTEM`                       | `WH:SYSTEM` (system client) |
| `locations`| `<facilityCode>:<locationName>`               | `WH:ZONE-A-01`           |
| `itemdata` | `<facilityCode>:id:<entityId>`                | `WH:id:1042`             |
| `itemdata` | `<facilityCode>:<clientId>:<itemNr>`          | `WH:7:SKU-ABCDE`         |

### Null-safe operator (`?.`)

All key expressions use the null-safe operator on `getCurrentTenant()`. If tenant context is not set (e.g., in a scheduled job), `getFacilityCode()` is not called and the SpEL expression produces `null`. Spring Cache will still attempt to use `null` as a key — this is a hazard in scheduled jobs that touch cached services without first setting tenant context (see §7).

---

## §4 `@Cacheable` / `@CacheEvict` / `@CachePut` Usage Map

### `sysprops` cache

| Location | Annotation | Method | Key | Trigger |
|----------|-----------|--------|-----|---------|
| `SyspropService` | `@CacheEvict` | `createSystemProperty(client, workstation, key, ...)` | `<facilityCode>:<key>` | Creating a sysprop evicts the old value for that key |
| `SyspropService` | `@Cacheable` | `getByKey(String key)` | `<facilityCode>:<key>` | Cache-on-read |
| `SyspropService` | `@Cacheable` | `getSysvalue(String key)` | `<facilityCode>:<key>` | Cache-on-read |
| `SystemPropertyController` | `@CacheEvict` | `updateValue(reqMap, principal)` | `<facilityCode>:<reqMap['key']>` | `POST /v3/systemProperty/updateValue` |

| `PutawayConfigService` | `@CacheEvict` | `setWarehouseDestination(locationId)` · `auditAndEvictWarehouse(...)` | `<facilityCode>:DEFAULT_PUTAWAY_LOCATION` | SBDEV-2732 tier 3 write (typed + HAL). **PR #139 MERGED 2026-08-11** |

⚠ **SBDEV-2732 shipped this key as a bare literal `'DEFAULT_PUTAWAY_LOCATION'`** with no
`<facilityCode>:` prefix, so it matched nothing and evicted nothing — caught in review. It was harmless
only because the resolver deliberately bypasses `SyspropService` (it reads the row with
`findBySyskeyAndClientIdAndWorkstation`, per landmines A3/A4), so nothing cached that key. **The moment
any reader goes through `SyspropService.getByKey` for it, both a stale read and a cross-tenant key
collision go live.** The prefix is not decoration; it is the tenant isolation boundary described in §3.

**Gap:** `SystemPropertyController.createSystemProperty` (`POST /v3/systemProperty/create`) delegates to `SyspropService.createSystemProperty` which carries `@CacheEvict`. The eviction fires correctly on create. However, if a sysprop is created via a path that bypasses `SyspropService.createSystemProperty` (e.g., direct DB insert or Flyway migration), no cache eviction occurs.

### `clients` cache

SBDEV-2732 (PR #139, merged 2026-08-11) adds evictions on both `clients` entries when a merchant's default putaway
destination changes — `<facilityCode>:<clNr>` **and** `<facilityCode>:SYSTEM`. Its first cut used
`<facilityCode>:id:<id>`, a key shape copied from the `itemdata` cache that `ClientService` does not
have, so it matched nothing. Reviewer-caught. The lesson generalises: **read the `@Cacheable` you are
evicting, do not pattern-match a neighbouring cache.**

| Location | Annotation | Method | Key | Trigger |
|----------|-----------|--------|-----|---------|
| `ClientService` | `@Cacheable` | `getByNumber(String clientNumber)` | `<facilityCode>:<clientNumber>` | Cache-on-read |
| `ClientService` | `@Cacheable` | `getSystemClient()` | `<facilityCode>:SYSTEM` | Cache-on-read |

**No `@CacheEvict` exists for `clients`.** There are no client update/create/delete methods in `ClientService` (it is read-only at the service layer). Client records are loaded via `FileImportController.importClients` (`POST /v3/import/clients`) which does NOT carry `@CacheEvict`. If a client record is updated via import, the cache will serve stale data until TTL expiry (up to 5 minutes, longer if accessed continuously — see §2 note on `expireAfterAccess`).

### `locations` cache

| Location | Annotation | Method | Key | Trigger |
|----------|-----------|--------|-----|---------|
| `LocationService` | `@CacheEvict` | `createLocation(client, name, type, area)` | `<facilityCode>:<name>` | Evicts by name on creation |
| `LocationService` | `@Cacheable` | `getByName(String name)` | `<facilityCode>:<name>` | Cache-on-read |

**Gap:** `LocationService.createLocationFromRequest(Location)` and `updateLocation(Location)` do NOT carry `@CacheEvict`. Updates to an existing location via `POST /v3/import/locations` or through the admin update path will not evict the cached entry. The old location object (with stale type, area, or attributes) will be served until TTL expiry.

### `itemdata` cache

| Location | Annotation | Method | Key | Trigger |
|----------|-----------|--------|-----|---------|
| `ItemdataService` | `@Cacheable` | `getById(Long id)` | `<facilityCode>:id:<id>` | Cache-on-read |
| `ItemdataService` | `@Cacheable` | `findByClientIdAndItemNr(Long clientId, String itemNr)` | `<facilityCode>:<clientId>:<itemNr>` | Cache-on-read. Since 260610 (SKU trim normalization) the method body trims `itemNr` before the repository call, but the SpEL key uses the **raw** argument — a padded lookup caches the trimmed row under the padded key. Accepted trade-off (plan 260610 §6): padded-key entries self-heal via the `allEntries` evictions on every SKU sync write + 5-min TTL |
| ~~`ItemdataService`~~ · ~~`ItemDataController`~~ | — | ~~`setPutAwayLocation`~~ | **DELETED 2026-08-27** | Both `setPutAwayLocation` methods were deleted under SBDEV-3017: `GET /v3/itemData/setPutAwayLocation/{id}/{locid}` was a **mutating GET** on a controller outside `FunctionGuardInterceptor.GUARDED` (ungated the moment its `@RequiresFunction` was lost — measured), and the `ItemdataService` twin had zero callers. The surviving SKU-putaway writer is `PutawayConfigService.setSkuDestination`, reached only via `PUT /v3/putawayConfig/sku/{itemdataId}`. ⚠ **Row 154 was already stale before the deletion**: it credited `ItemDataController.setPutAwayLocation` with `@CacheEvict(allEntries = true)`, which SBDEV-2732 had removed — see the 2026-08-27 log entry. |
| `FileImportController` | `@CacheEvict` | `importSkus(adviceList, principal)` | `allEntries = true` | `POST /v3/import/skus` |
| `SkuRestController` | `@CacheEvict` | `create(skuList)` | `allEntries = true` | `PUT /rest/sku/create` |
| `SkuRestController` | `@CacheEvict` | `update(skuList)` | `allEntries = true` | `POST /rest/sku/update` |

**Note on eviction strategy:** The `itemdata` cache mixes two eviction styles. The bulk write paths (`SkuRestController.create`/`update`, `FileImportController.importSkus`) use `allEntries = true` — defensive, clears the entire cache (all entries for ALL tenants in the same JVM) because a batch can touch many items. The key-targeted `@Caching(evict)` example that used to sit here (`ItemdataService.setPutAwayLocation`, two keys) is **gone as of 2026-08-27** — the method was deleted. Targeted eviction now lives on `PutawayConfigService`; its key expressions must stay in sync with the `@Cacheable` keys above whenever either changes.

**`SkuRestController.delete` gap:** `delete(skuList)` (`DELETE /rest/sku/delete`) does NOT carry `@CacheEvict`, while its `create`/`update` siblings do. Deleted SKUs remain in the `itemdata` cache until TTL expiry (5 min). ⚠ **Sharpened 2026-08-27 — it is worse than a missed eviction.** The handler's own loop calls `itemdataService.findByClientIdAndItemNr(...)` (`SkuRestController:323`) to locate each row before `itemdataRepository.delete(...)`, and that method is `@Cacheable`. So the delete **populates** the cache with the very entity it then removes. The stale entry is therefore *guaranteed*, not merely possible-if-previously-read — which is why the §7 severity below reads Low but the failure is deterministic.

---

## §5 Safe Modification Patterns

### Adding a new cached read

1. Add `@Cacheable(value = "<cacheName>", key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + <discriminator>")` to the read method.
2. Verify the cache name exists in `CacheConfig.cacheManager()`. If not, add a `buildCache(...)` entry with an appropriate `maxSize` and `Duration`.
3. Ensure all write paths for the same entity carry a matching `@CacheEvict`. Check both the service layer and any controller that calls `repository.save()` directly.

### Adding a new write that mutates cached data

1. Identify which cache(s) contain the entity being mutated.
2. Add `@CacheEvict` to the mutating method. Use a specific key expression when possible; use `allEntries = true` only when the entity has multiple cache keys and targeted eviction is impractical.
3. If the write path is in a controller (not a service), add `@CacheEvict` on the controller method — Spring AOP intercepts the proxy boundary, so both layers can carry the annotation.
4. Consider whether other caches transitively depend on this entity (e.g., a `Location` change may affect `itemdata` if put-away defaults reference location records).

### Adding a new cache

1. Add the cache to `CacheConfig.buildCache(...)` inside `cacheManager()`. All caches must be declared here — Spring will throw `NoSuchCacheException` at startup for any `@Cacheable` referencing an undeclared cache name.
2. Choose `maxSize` based on expected tenant data volume (e.g., `locations` is 2000 because large warehouses have hundreds of locations per tenant, and the single JVM may serve multiple tenants).
3. Decide `expireAfterAccess` vs `expireAfterWrite`: use `expireAfterWrite` if you need a hard upper bound on staleness regardless of read frequency (as `KeycloakService.userCache` does). Use `expireAfterAccess` (current pattern for all four Spring caches) only when hot data should stay resident indefinitely.

### Key expression discipline

Always copy the exact SpEL pattern:

```java
"T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #<param>"
```

Do not abbreviate or introduce a helper method for the key — Spring Cache evaluates SpEL at the AOP proxy boundary, and method references to non-bean utilities will fail at runtime.

---

## §6 Cache-Aside vs Write-Through Patterns

All four Spring-managed caches use **cache-aside** (lazy population):

- On read: Spring checks the cache; on a miss, executes the method, stores the result, and returns it.
- On write: The application explicitly evicts (or does nothing, relying on TTL).

There is no **write-through** (`@CachePut`) in this codebase. `@CachePut` was not used because the write methods (import endpoints, REST SKU endpoints) operate on bulk lists, making single-key repopulation awkward. The pattern chosen is: evict-on-write, repopulate lazily on next read.

The `KeycloakService.userCache` differs slightly — it is managed with explicit `put()` calls after every Keycloak API response, which is effectively a write-through pattern, and explicit `invalidate()` calls on user modification. This is appropriate because Keycloak round-trips are expensive (HTTP), and repopulating on every read miss would be unacceptable.

---

## §7 Known Invalidation Gaps

These are locations where data can become stale without any explicit cache eviction. All rely on TTL expiry (up to 5 minutes, potentially longer under load due to `expireAfterAccess`).

| Gap | Stale cache | Affected write path | Risk level |
|-----|-------------|---------------------|------------|
| `FileImportController.importClients` does not evict `clients` | `clients` | `POST /v3/import/clients` — bulk client import | Medium: client records rarely change, but re-imports of updated client data serve stale records |
| `LocationService.createLocationFromRequest` does not evict `locations` | `locations` | Used by `POST /v3/import/locations` import path (separate from `createLocation`) | Medium: new or updated locations may not be immediately visible to picking/receiving operations |
| `LocationService.updateLocation` does not evict `locations` | `locations` | Admin location update flow | Medium: location type or area changes will not be reflected until TTL |
| `SkuRestController.delete` does not evict `itemdata` | `itemdata` | `DELETE /rest/sku/delete` | **Low→Medium (re-rated 2026-08-27)**: deleted SKUs in cache cause `getById`/`findByClientIdAndItemNr` to return a stale entity that no longer exists in the DB, and callers must handle `EntityNotFoundException` defensively. Re-rated because the stale entry is **deterministic, not incidental** — the handler itself warms the cache via the `@Cacheable` lookup it uses to find each row (`:323`) immediately before deleting it. Not fixed here: out of scope for SBDEV-3017, and it needs Nam's call on whether it is its own ticket. |
| Multi-replica staleness (all caches) | All four Spring caches | Any write on any replica | High in multi-replica deployments: `@CacheEvict` only evicts the local JVM's cache. Other replicas keep stale entries until TTL expiry. |
| Scheduled jobs without tenant context | All caches | Any `@Scheduled` job that calls a cached service method without explicitly setting `TenantContext` | High: `TenantContext.getCurrentTenant()` returns `null`, SpEL key resolves to `null`, and Spring Cache may serve or store entries under a `null` key — effectively mixing tenant data |

---

## §8 Local Development — Disabling and Resetting the Cache

### Disable caching for a dev/test run

Spring Boot supports a no-op cache type that bypasses all caching without changing application code:

```properties
# src/main/resources/application_dev.properties  (or application-test.properties)
spring.cache.type=none
```

With `spring.cache.type=none`, all `@Cacheable` methods always delegate to the underlying method, and `@CacheEvict` becomes a no-op. This is the safest way to rule out cache-related bugs in development.

**Current state:** The dev properties file (`application_dev.properties`) and the test `application.properties` do not currently set `spring.cache.type=none`. Caching is active in all environments including test runs.

### Reset the cache at runtime (actuator)

If `spring-boot-actuator` is on the classpath (it is in this project), Spring Boot exposes a cache management endpoint:

```bash
# List all caches
curl http://localhost:8088/actuator/caches

# Evict all entries from a specific cache (requires correct tenant header context)
curl -X DELETE http://localhost:8088/actuator/caches/itemdata
```

The actuator endpoint requires appropriate security permissions. In production, the actuator endpoints are not publicly exposed.

### Reset the cache in tests

The test suite uses H2 or TestContainers (PostgreSQL) but does not inject a no-op `CacheManager`. To isolate a test from cache state, either:

1. Annotate the test method or class with `@DirtiesContext` to reload the application context (expensive).
2. Inject the `CacheManager` bean and call `cache.clear()` in `@BeforeEach`:

```java
@Autowired
private CacheManager cacheManager;

@BeforeEach
void clearCaches() {
    cacheManager.getCacheNames().forEach(name -> {
        Cache cache = cacheManager.getCache(name);
        if (cache != null) cache.clear();
    });
}
```

This is the pattern to use in any service or integration test that exercises a cached method and needs deterministic DB reads.

---

## §9 Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-27 | Initial — `CacheConfig.java`, `SyspropService`, `ClientService`, `ItemdataService`, `LocationService`, `KeycloakService`, `SystemPropertyController`, `ItemDataController`, `FileImportController`, `SkuRestController` | All cache definitions and `@Cacheable` / `@CacheEvict` sites confirmed against source | Code read |
| 2026-08-27 | SBDEV-3017 deletion sweep. **Two §4 `itemdata` rows retired**: `ItemdataService.setPutAwayLocation` and `ItemDataController.setPutAwayLocation` were both deleted (mutating GET on a controller outside `GUARDED`; the service twin had zero callers). **Found pre-existing drift**: the `ItemDataController` row claimed `@CacheEvict(allEntries = true)`, which SBDEV-2732 had already removed — so that row had been wrong since then, and the identical wrong claim also sat in `IdempotencyFilter`'s javadoc at `:413` (corrected in code). **Re-rated the `SkuRestController.delete` gap Low→Medium**: the handler warms the `itemdata` cache through a `@Cacheable` lookup at `:323` immediately before deleting the row, making the stale entry deterministic rather than incidental. | 2 rows retired, 1 pre-existing error corrected, 1 gap re-rated | Code read + full suite (5672/0/67) |
| 2026-06-14 | Added the second out-of-band cache to the §out-of-band table: `MultiTenantJwtDecoder.jwtDecoders` (per-tenant `JwtDecoder`, `maximumSize(200)`, `expireAfterWrite(24h)`) — merged via 260610 hardening Phase B (PR #41), replacing an unbounded `ConcurrentHashMap`. Cross-linked to end-to-end §4.2. | Doc addition; matches code | Doc-drift audit (verify-docs) |
| 2026-06-11 | Targeted re-verify for plan 260610 (SKU trim normalization): `ItemdataService.findByClientIdAndItemNr` now trims `itemNr` in the body while the `@Cacheable` SpEL key stays on the raw arg (padded-key entries self-heal — note added to §table row). Found + fixed drift: `setPutAwayLocation` no longer uses `allEntries = true`; it carries `@Caching(evict)` with the two targeted keys (`ItemdataService.java:60-65`). `SkuRestController.delete` no-eviction gap (§7 row) still present and now marginally wider since padded deletes resolve. | §table row + §7 confirmed; one row corrected | Code read (plan 260610 implementation) |
| 2026-05-08 | Re-verified Caffeine swap: `CacheConfig.java` defines 4 caches (`sysprops`, `clients`, `locations`, `itemdata`) all with 5-min TTL via `Duration.ofMinutes(5)` (lines 34-37); `SyspropService.@Cacheable("sysprops")` (lines 95, 288) + `@CacheEvict` (line 53) supersede the prior 30s volatile cache pattern. Optimistic-lock resilience for Group C — 9 catch sites across `service/job/ReleaseOrderJobService.java`, `service/job/ReplenishOrderJobService.java`, `MobileReplenishService`, `MobilePickingService`, `MobilePutAwayService`, `PickingorderBusinessService`, `BasicService`, plus the `OptimisticLockRetry` utility and the controller-layer `PickingController` retry. ItemData cache eviction story confirmed — `ItemdataService.setPutAwayLocation` + `ItemDataController.setPutAwayLocation` + `FileImportController.importSkus` + `SkuRestController.create` / `update` all carry `@CacheEvict(value = "itemdata", allEntries = true)`. `SkuRestController.delete` gap (no eviction) still present — see §7 row. | All claims confirmed; no drift; only frontmatter and verified-line bumped. | Code read (grep-based) |

**Re-verify every 60 days.** Next due: **2026-07-07**.
