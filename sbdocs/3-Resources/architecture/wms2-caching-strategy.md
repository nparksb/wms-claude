---
title: "WMS v2 — Caching Strategy (Caffeine)"
type: architecture
status: active
system: wms2
owner: Nam Park
created: 2026-04-26
updated: 2026-08-31
last_verified: 2026-08-31
verified_by: "SBDEV-3135 (2026-08-31, 4 review rounds) — code read of CacheConfig, SyspropService, ClientService, ItemdataService, LocationService, KeycloakService, MultiTenantJwtDecoder, SystemPropertyController, ClientController, FileImportController, SkuRestController, RestConfiguration, PutawayConfigRepositoryEventHandler; expiry policy, tenant-key form and every eviction site re-derived. (ItemDataController was dropped from this list — SBDEV-3017 deleted that class.)"
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
**Owner:** Nam Park · **Last verified:** 2026-08-31

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

All four Spring-managed caches are defined in `CacheConfig.java` (`net.aim_ai.wms.config`). All use **`expireAfterWrite`** (a hard bound — the TTL does *not* reset on a read) and `recordStats()`.

| Cache name  | What is cached                                   | Max entries | TTL (write-based) | Eviction policy         |
|-------------|--------------------------------------------------|-------------|--------------------|-------------------------|
| `sysprops`  | `Sysprop` entity — warehouse configuration KV pairs | 200      | **2 minutes**      | LRU + TTL expiry        |
| `clients`   | `Client` entity — warehouse client/owner records | 100         | 5 minutes          | LRU + TTL expiry        |
| `locations` | `Location` entity — physical warehouse locations | 2000        | 5 minutes          | LRU + TTL expiry        |
| `itemdata`  | `Itemdata` entity — SKU / item master records    | 3000        | 5 minutes          | LRU + TTL expiry        |

**Note on `expireAfterWrite` vs `expireAfterAccess`:** all four caches use **`expireAfterWrite`**, so 5 minutes is a **hard** ceiling on staleness — an entry expires 5 minutes after it was written no matter how often it is read. `@CacheEvict` discipline still matters (5 minutes of wrong data is plenty), but no entry can outlive that window by being hot.

> ⚠ **Correction, 2026-08-31 (SBDEV-3135).** This section previously asserted the opposite — that all four caches use `expireAfterAccess`, that "a cached entry that is read frequently will never expire naturally", and that this was "a deliberate trade-off (hot data stays cached)". **All of it was false.** Commit `695a4549` (SBDEV-2218, 2026-05-12) switched Caffeine from `expireAfterAccess` (sliding) to `expireAfterWrite` precisely to get a hard staleness bound; the docs were never updated. `expireAfterAccess` appears **zero** times in `src/` — the only expiry calls are `CacheConfig:90`, `KeycloakService:62` and `MultiTenantJwtDecoder:35`, all `expireAfterWrite`. The claim survived in **five** places in this doc and **three** more in [wms2-stockunit-design.md](../design/wms2-stockunit-design.md) §caching (including a hand-written code block that never matched the source), all corrected on 2026-08-31. The archived plan [260424-cache-config-improvement-plan](../../4-Archieves/wms2/plan/260424-cache-config-improvement-plan.md) is where it came from: its Improvement 5 recorded `expireAfterAccess` as **DONE**, and SBDEV-2218 reverted it three weeks later without touching the docs. Archived plans are history and were left as-is.
>
> **Why this mattered enough to chase.** A reader reasoning about *any* staleness bug in this system from these docs would conclude a hot key can stay stale indefinitely, and size the impact accordingly. That is the wrong mental model, and it is load-bearing for exactly the kind of ticket that reaches this doc.

**Out-of-band caches (not in `CacheConfig`):** two manually managed Caffeine caches live outside Spring Cache annotations. `KeycloakService.userCache` caches `UserRepresentation` objects from Keycloak. The landlord `MultiTenantJwtDecoder` caches per-tenant `JwtDecoder` instances to avoid rebuilding JWK sets on every request — added by the 260610 hardening Phase B (GAP F fix, PR #41) to bound what was previously an unbounded, never-evicted `ConcurrentHashMap`. See [end-to-end request journey §4.2](./wms2-end-to-end-request-journey.md) for where the decoder cache sits in the auth chain.

| Cache       | What is cached            | Max entries | TTL (write-based) | Managed by      |
|-------------|---------------------------|-------------|-------------------|-----------------|
| `userCache` | Keycloak `UserRepresentation` per username | 500 | 15 minutes (`expireAfterWrite`) | `KeycloakService` manually |
| `jwtDecoders` | Per-tenant `JwtDecoder` instances (one per Keycloak realm) | 200 | 24 hours (`expireAfterWrite`) | `MultiTenantJwtDecoder` manually (260610 Phase B) |

---

## §3 Multi-Tenant Cache Key Isolation

**This is the most critical correctness property.** All four Spring-managed caches store data that is tenant-scoped. Without key isolation, tenant A could read tenant B's cached data.

### Key pattern

Every `@Cacheable` / `@CacheEvict` annotation uses SpEL to prefix the logical key with **`TenantKeyBuilder.cacheKey(...)`**:

```
T(net.aim_ai.wms.landlord.config.TenantKeyBuilder).cacheKey(
    T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()) + ':' + <discriminator>
```

`TenantContext` is a thread-local holder set by `TenantFilter` at the start of every request. `cacheKey` returns **`{full tenantName}:{facilityCode}`** — deliberately the *full* tenant name, unlike `TenantKeyBuilder.buildKey`, whose 4-character truncation is a datasource-routing concern and would leave a narrower version of the same collision. With no tenant in context it returns the named bucket `"no-tenant"` rather than throwing, so scheduled and unauthenticated paths keep working.

> ⚠ **Correction, 2026-08-31 (SBDEV-3135).** This section previously documented the prefix as `getCurrentTenant()?.getFacilityCode()` alone and stated that "tenants sharing a warehouse code would collide, but the routing architecture ensures this does not happen." **The routing architecture does not ensure that** — it was the SBDEV-3033 defect, and it was live: on the UAT landlord warehouse `nywh` is shared by `hydra` and `shipitez`, so those two tenants shared entries in all four caches, and because the evict keys had the same shape each tenant's writes evicted the other's. Also corrected: `getFacilityCode()` is not "the 2-char warehouse code" — facility codes here are not fixed-length (`develop`, `nywh`, `wh01`). SBDEV-3033's fix is merged; this section had simply never been updated to describe it. Pinned by `unit/config/TenantCacheKeyUnitTest`, which grades key shape across every cache annotation by classpath scan.

### Key examples by cache

| Cache      | Effective key format                                      | Example                              |
|------------|-----------------------------------------------------------|--------------------------------------|
| `sysprops` | `<tenant>:<propKey>`                   | `wineco:wh01:PICK_CONFIRM_REQUIRED`  |
| `clients`  | `<tenant>:<clientNumber>`             | `wineco:wh01:CLIENT001`              |
| `clients`  | `<tenant>:SYSTEM`                     | `wineco:wh01:SYSTEM` (system client) |
| `locations`| `<tenant>:<locationName>`             | `wineco:wh01:ZONE-A-01`              |
| `itemdata` | `<tenant>:id:<entityId>`              | `wineco:wh01:id:1042`                |
| `itemdata` | `<tenant>:<clientId>:<itemNr>`        | `wineco:wh01:7:SKU-ABCDE`            |
| *(any)*    | `no-tenant:<discriminator>` when no tenant is in context  | `no-tenant:PICK_CONFIRM_REQUIRED`    |

### No tenant in context → the `"no-tenant"` bucket, not a null key

`TenantKeyBuilder.cacheKey(...)` returns the literal string **`"no-tenant"`** when the profile is null, so a key is always well-formed and nothing throws. That is deliberate: scheduled jobs and unauthenticated paths evaluate this SpEL with no tenant in context, and making them throw would take those callers out.

The residual hazard is **sharing**, not nullity — every tenant-less caller lands in the *same* bucket, so two jobs running for different tenants can see each other's entries there. That is the §7 "scheduled jobs without tenant context" row.

> ⚠ **Corrected 2026-08-31 (SBDEV-3135, review round 4).** This subsection was titled "Null-safe operator (`?.`)" and claimed that "all key expressions use the null-safe operator on `getCurrentTenant()`" and that the expression "produces `null`", which Spring would then use as a key. All of it was false at the time of writing: `?.` appears **once** in all of `src/main` and that occurrence is inside `TenantKeyBuilder`'s own javadoc describing the pre-SBDEV-3033 form. It was a leftover from that defect, and it contradicted both §3's own correction note above and §7's gap row.

---

## §4 `@Cacheable` / `@CacheEvict` / `@CachePut` Usage Map

> Throughout this section `<tenant>` stands for `TenantKeyBuilder.cacheKey(...)` =
> `{full tenantName}:{facilityCode}` (or the literal `no-tenant`). Every key format below read
> `<facilityCode>:…` until 2026-08-31 — the pre-SBDEV-3033 form that §3 now documents as the defect.
> Corrected under SBDEV-3135; **21 occurrences across §3 and §4** (6 in §3, 15 in §4, none in §5).
> §5's two occurrences were a different shape — `getFacilityCode()` inside SpEL *samples* — and were
> corrected separately in review round 4; see the discipline note there.

### `sysprops` cache

| Location | Annotation | Method | Key | Trigger |
|----------|-----------|--------|-----|---------|
| `SyspropService` | `@CacheEvict` | `createSystemProperty(client, workstation, key, ...)` | `<tenant>:<key>` | Creating a sysprop evicts the old value for that key |
| `SyspropService` | `@CacheEvict` | `setSysvalue(key, value)` | `<tenant>:<key>` | Direct value write. *Was missing from this table before SBDEV-3135* |
| `SyspropService` | **programmatic** | `getStringDefault(...)` → `evictSyspropKey(key)` | `<tenant>:<key>` | A READ that SEEDS a missing row. Its intra-bean call to `createSystemProperty` bypasses that method's own annotation, so the evict is explicit (SBDEV-3135) |
| `SyspropService` | `@Cacheable` | `getByKey(String key)` | `<tenant>:<key>` | Cache-on-read. ⚠ **No `unless`** — caches nulls. **Zero callers in `src/main`** (tests only) |
| `SyspropService` | `@Cacheable` | `getSysvalue(String key)` | `<tenant>:<key>` | Cache-on-read. Carries `unless = "#result == null"`, so it never stores a miss. The only live reader |
| `SystemPropertyController` | `@CacheEvict` | `updateValue(reqMap, principal)` | `<tenant>:<reqMap['key']>` | `POST /v3/systemProperty/updateValue` |
| `SystemPropertyController` | `@CacheEvict` | `createSystemProperty(reqMap, principal)` | `allEntries = true` | `POST /v3/systemProperty/create` (added SBDEV-3135) |
| `SystemPropertyController` | `@CacheEvict` | `updateClient(reqMap, principal)` | `allEntries = true` | `POST /v3/systemProperty/updateClient` (added SBDEV-3135) — re-points `client_id`, which both readers resolve *through* while the key carries only the syskey |
| `PutawayConfigService` | `@CacheEvict` | `setWarehouseDestination(locationId)` · `auditAndEvictWarehouse(...)` | `<tenant>:DEFAULT_PUTAWAY_LOCATION` | SBDEV-2732 tier 3 write (typed + HAL). **PR #139 MERGED 2026-08-11** |

⚠ **SBDEV-2732 shipped this key as a bare literal `'DEFAULT_PUTAWAY_LOCATION'`** with no
`<tenant>:` prefix, so it matched nothing and evicted nothing — caught in review. It was harmless
only because the resolver deliberately bypasses `SyspropService` (it reads the row with
`findBySyskeyAndClientIdAndWorkstation`, per landmines A3/A4), so nothing cached that key. **The moment
any reader goes through `SyspropService.getByKey` for it, both a stale read and a cross-tenant key
collision go live.** The prefix is not decoration; it is the tenant isolation boundary described in §3.

**Corrected 2026-08-31 (SBDEV-3135) — this paragraph was false.** It claimed `SystemPropertyController.createSystemProperty` "delegates to `SyspropService.createSystemProperty` which carries `@CacheEvict`" and that "the eviction fires correctly on create". It does neither: the handler builds the `Sysprop` inline and calls **`syspropRepository.save(sysProp)` directly**, with no eviction anywhere on the path. That was the same create-has-none / update-has-one asymmetry as `SkuRestController.delete`, sitting in a class whose own `updateValue` has always evicted.

**Closed by SBDEV-3135:** `createSystemProperty` and `updateClient` both now carry `@CacheEvict(value = "sysprops", allEntries = true)`. `allEntries` rather than a key-scoped evict because the syskey arrives inside a `Map` body, and `updateClient` **re-points the row's `client_id`** — both cached readers resolve a sysprop *through* `client_id` while the cache key carries only the syskey, so moving the row changes what an unchanged key should resolve to, which no key expression can express.

⚠ Two readers on this cache have **opposite** null semantics: `getSysvalue` carries `unless = "#result == null"`, `getByKey(String)` does not and returns `null` for an absent key — so the negative *is* cached for `getByKey`. Still open; see §7.

A sysprop written by a Flyway migration or a direct DB insert still evicts nothing — unchanged, and unfixable from inside the app.

### `clients` cache

SBDEV-2732 (PR #139, merged 2026-08-11) adds evictions on both `clients` entries when a merchant's default putaway
destination changes — `<tenant>:<clNr>` **and** `<tenant>:SYSTEM`. Its first cut used
`<tenant>:id:<id>`, a key shape copied from the `itemdata` cache that `ClientService` does not
have, so it matched nothing. Reviewer-caught. The lesson generalises: **read the `@Cacheable` you are
evicting, do not pattern-match a neighbouring cache.**

| Location | Annotation | Method | Key | Trigger |
|----------|-----------|--------|-----|---------|
| `ClientService` | `@Cacheable` | `getByNumber(String clientNumber)` | `<tenant>:<clientNumber>` | Cache-on-read |
| `ClientService` | `@Cacheable` | `getSystemClient()` | `<tenant>:SYSTEM` | Cache-on-read |

**`ClientService` itself declares no `@CacheEvict`** — it is read-only at the service layer, with no client create/update/delete methods. Eviction therefore lives with the writers:

| Writer | Annotation | Since |
|---|---|---|
| `FileImportController.importClients` (`POST /v3/import/clients`) | `@CacheEvict(value = "clients", allEntries = true)` | **SBDEV-3135, 2026-08-31** — previously absent, so an imported client stayed invisible through `getByNumber` for the full TTL |
| `PutawayConfigService` (merchant default putaway destination) | `@CacheEvict` × 2 on both key shapes | SBDEV-2732, PR #139 |

⚠ **Both `@Cacheable` readers above cache a negative result** — neither carries `unless = "#result == null"`, and `getByNumber` returns `null` for an absent client (`catch (NoSuchElementException) { return null; }`). So a lookup taken *before* a client exists is remembered as "no such client". That is an open gap in its own right — see §7.

### `locations` cache

| Location | Annotation | Method | Key | Trigger |
|----------|-----------|--------|-----|---------|
| `LocationService` | `@CacheEvict` | `createLocation(client, name, type, area)` | `<tenant>:<name>` | Evicts by name on creation |
| `LocationService` | `@Cacheable` | `getByName(String name)` | `<tenant>:<name>` | Cache-on-read |

**Closed by SBDEV-3135 (2026-08-31).** `createLocationFromRequest` and `updateLocation` now carry `@CacheEvict(value = "locations", allEntries = true)`, joining `createLocation`. `allEntries` rather than a key-scoped evict is **required** on `updateLocation`: it can RENAME a location while `getByName` is keyed on the name, and the OLD name is not a parameter of the method, so no SpEL expression can reach it.

`FileImportController.importLocations` (`POST /v3/import/locations`) also evicts as of the same ticket — it writes through `locationRepository` directly and never touches `LocationService`, so it got no cover from the two fixes above. A review lane caught that the original sweep had stopped one method short.

⚠ Still open: `LocationService.createSystemStorageLocation` calls `getByName` and `createLocation` on `this`, so **neither** advice fires (self-invocation bypasses the proxy). Benign today — it is an init-only path and an un-cached read cannot serve stale — but the `createLocation` evict silently does not happen there.

### `itemdata` cache

| Location | Annotation | Method | Key | Trigger |
|----------|-----------|--------|-----|---------|
| `ItemdataService` | `@Cacheable` | `getById(Long id)` | `<tenant>:id:<id>` | Cache-on-read |
| `ItemdataService` | `@Cacheable` | `findByClientIdAndItemNr(Long clientId, String itemNr)` | `<tenant>:<clientId>:<itemNr>` | Cache-on-read. Since 260610 (SKU trim normalization) the method body trims `itemNr` before the repository call, but the SpEL key uses the **raw** argument — a padded lookup caches the trimmed row under the padded key. Accepted trade-off (plan 260610 §6): padded-key entries self-heal via the `allEntries` evictions on every SKU sync write + 5-min TTL |
| ~~`ItemdataService`~~ · ~~`ItemDataController`~~ | — | ~~`setPutAwayLocation`~~ | **DELETED 2026-08-27** | Both `setPutAwayLocation` methods were deleted under SBDEV-3017: `GET /v3/itemData/setPutAwayLocation/{id}/{locid}` was a **mutating GET** on a controller outside `FunctionGuardInterceptor.GUARDED` (ungated the moment its `@RequiresFunction` was lost — measured), and the `ItemdataService` twin had zero callers. The surviving SKU-putaway writer is `PutawayConfigService.setSkuDestination`, reached only via `PUT /v3/putawayConfig/sku/{itemdataId}`. ⚠ **Row 154 was already stale before the deletion**: it credited `ItemDataController.setPutAwayLocation` with `@CacheEvict(allEntries = true)`, which SBDEV-2732 had removed — see the 2026-08-27 log entry. |
| `FileImportController` | `@CacheEvict` | `importSkus(adviceList, principal)` | `allEntries = true` | `POST /v3/import/skus` |
| `SkuRestController` | **programmatic** (`finally` → `CacheManager`) | `create(skuList)` | whole cache | `PUT /rest/sku/create` |
| `SkuRestController` | **programmatic** (`finally` → `CacheManager`) | `update(skuList)` | whole cache | `POST /rest/sku/update` |
| `SkuRestController` | **programmatic** (`finally` → `CacheManager`) | `delete(skuList)` | whole cache | `DELETE /rest/sku/delete` |

**Note on eviction strategy:** the `itemdata` cache mixes three styles. `FileImportController.importSkus` uses `@CacheEvict(allEntries = true)`. All three `SkuRestController` handlers clear the whole cache **programmatically** from a `finally` block since SBDEV-3135 and carry **no annotation at all** — see the `delete` note below for why an annotation cannot do it, and why keeping one alongside the `finally` on `create`/`update` was measured redundant. Either way a batch write clears every entry for ALL tenants sharing the JVM, which is deliberate: a batch can touch many items. The key-targeted `@Caching(evict)` example that used to sit here (`ItemdataService.setPutAwayLocation`, two keys) is **gone as of 2026-08-27** — the method was deleted. Targeted eviction now lives on `PutawayConfigService`; its key expressions must stay in sync with the `@Cacheable` keys above whenever either changes.

**`SkuRestController.delete` — closed by SBDEV-3135 (2026-08-31), and NOT with an annotation.** `delete` now evicts the whole `itemdata` cache from a **`finally` block**, via a constructor-injected `CacheManager`, mirroring `IdempotencyFilter.cacheEvictOnReplay`. No form of `@CacheEvict` can do the job:

- `delete` has **no** `@Transactional`, so each `itemdataRepository.delete` commits on its own. Eight foreign keys reference `itemdata` and none carries `ON DELETE CASCADE`, so deleting a SKU that any advice / order / stock row still points at raises `23503` → `DataIntegrityViolationException`. Measured on `dev_wh01_om1`: **8805 SKUs, only 1132 unreferenced** — so **~87% of SKUs cannot be deleted at all**. (Stated as a share of the SKU *population*, not of delete *attempts*: whether real deletes skew toward the deletable 13% was not measured. Blind spot: one tenant DB.) That exception is not a `WebserviceBusinessExceptionClientSide`, so it escapes the handler's catch, and `@CacheEvict` fires only on a **normal return** — leaving warmed entries for the rows that *did* commit.
- `beforeInvocation = true` does not rescue it, and the pair of both does not either: the handler's loop **re-warms** the cache as it walks (it locates each row through the `@Cacheable` `findByClientIdAndItemNr`), so anything evicted on entry is put straight back before the throw. Measured — the paired-annotation shape fails the regression test written for this path.

A `finally` block is the only construct that runs on all three exits: normal return, caught business exception, and escaping runtime exception.


---

## §5 Safe Modification Patterns

### Adding a new cached read

1. Add `@Cacheable(value = "<cacheName>", key = "T(net.aim_ai.wms.landlord.config.TenantKeyBuilder).cacheKey(T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()) + ':' + <discriminator>")` to the read method. ⚠ **Not** `getCurrentTenant()?.getFacilityCode()` — see the key-expression discipline below.
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
3. Decide `expireAfterWrite` vs `expireAfterAccess`: **`expireAfterWrite` is the established pattern here** — all four Spring caches use it, as do both out-of-band caches (`KeycloakService.userCache`, `MultiTenantJwtDecoder`). It gives a hard upper bound on staleness regardless of read frequency. Reach for `expireAfterAccess` only if hot data genuinely should stay resident indefinitely, and note that SBDEV-2218 deliberately moved *away* from it (`695a4549`) — so departing from `expireAfterWrite` needs a reason that ticket did not already reject.

### Key expression discipline

Always copy the exact SpEL pattern:

```java
"T(net.aim_ai.wms.landlord.config.TenantKeyBuilder).cacheKey(T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()) + ':' + #<param>"
```

> 🔴 **Corrected 2026-08-31 (SBDEV-3135, review round 4) — this subsection previously prescribed the defect.**
> It told the next developer to copy
> `T(...TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #<param>`, which is exactly the
> **SBDEV-3033 cross-tenant key collision** documented in §3 — a merged-and-closed data leak where two
> tenants sharing a facility code shared cache entries and evicted each other's. Following §5 as written
> would have reintroduced it. Measured at the time of the correction: **21** annotations in `src/main`
> use `TenantKeyBuilder.cacheKey(...)`, and `getCurrentTenant()?.` survives in exactly **one** place —
> inside `TenantKeyBuilder`'s own javadoc, describing the old form.
>
> The same block also said *"do not abbreviate or introduce a helper method for the key — method
> references to non-bean utilities will fail at runtime."* **That is false, and it forbade what §3
> requires:** every one of those 21 annotations calls the static non-bean helper
> `T(...TenantKeyBuilder).cacheKey(...)` and it works. SpEL's `T(...)` type reference resolves static
> methods without any bean involvement.

**Do** route the tenant prefix through `TenantKeyBuilder.cacheKey(...)` — a `T(...)` static reference is
the mandated pattern, not an abbreviation to avoid. **Do not** inline `getFacilityCode()`, and do not use
`TenantKeyBuilder.buildKey`, whose 4-character truncation is for datasource routing and would preserve a
narrower version of the SBDEV-3033 collision.

---

## §6 Cache-Aside vs Write-Through Patterns

All four Spring-managed caches use **cache-aside** (lazy population):

- On read: Spring checks the cache; on a miss, executes the method, stores the result, and returns it.
- On write: The application explicitly evicts (or does nothing, relying on TTL).

There is no **write-through** (`@CachePut`) in this codebase. `@CachePut` was not used because the write methods (import endpoints, REST SKU endpoints) operate on bulk lists, making single-key repopulation awkward. The pattern chosen is: evict-on-write, repopulate lazily on next read.

The `KeycloakService.userCache` differs slightly — it is managed with explicit `put()` calls after every Keycloak API response, which is effectively a write-through pattern, and explicit `invalidate()` calls on user modification. This is appropriate because Keycloak round-trips are expensive (HTTP), and repopulating on every read miss would be unacceptable.

---

## §7 Known Invalidation Gaps

These are locations where data can become stale without any explicit cache eviction. They rely on TTL expiry, and that bound is **hard at 5 minutes**: `CacheConfig.buildCaffeineCache` uses **`expireAfterWrite`**, so an entry expires 5 minutes after it was written no matter how often it is read.

> ⚠ **Correction, 2026-08-31 (SBDEV-3135).** This preamble previously read "up to 5 minutes, potentially longer under load due to `expireAfterAccess`". That was wrong in a way that understated nothing but mis-described the mechanism: the builder has always used `expireAfterWrite`, never `expireAfterAccess`, so a hot key does **not** renew its own staleness. Verified by code read of `buildCaffeineCache`.

### Open gaps

| Gap | Stale cache | Affected write path | Risk level |
|-----|-------------|---------------------|------------|
| **Negative results are cached** — `ClientService.getByNumber` (`:53`), `ClientService.getSystemClient` (`:100`), `LocationService.getByName` and `ItemdataService.findByClientIdAndItemNr` (`:51`) carry **no** `unless = "#result == null"`; only `SyspropService.getSysvalue` does | `clients`, `locations`, `itemdata` | Any check-then-create loop: the existence check caches the MISS, and every reader keeps seeing "absent" until something evicts | **Medium.** Found 2026-08-31 under SBDEV-3135 while fixing the four rows below; it is *why* those four mattered more than "stale after an update". Deliberately **not** fixed there — adding `unless` changes read semantics across ~95 `itemdata` call sites in `src/main` plus the `clients`/`locations` readers, which is its own change. Proposed to Nam as a separate item; the eviction fixes below close the practical exposure on the four known write paths |
| **SDR write surfaces for `client`, `location` and `sysprop`** — `POST`/`PATCH`/`PUT`/`DELETE` on `/v3/{client,location,sysprop}` write these entities through `RepositoryEntityController`, which carries no `@CacheEvict` at all | `clients`, `locations`, `sysprops` | any SDR write | **Medium–High, and no annotation can close it.** All four cached entities' repositories are `@RepositoryRestResource` with no class-level `exported = false`. `Itemdata` **is** listed in `RestConfiguration.SDR_WRITE_WITHDRAWN`, so the `itemdata` cache is safe from this. `Client`, `Location` and `Sysprop` are deliberately **not** — they are on the must-stay-writable list precisely because a live UI writes at their SDR path, so withdrawing the verbs would break screens. `PutawayConfigRepositoryEventHandler` does hook SDR writes for `Itemdata`/`Client`/`Sysprop`, but every eviction on that path is gated on the write being a **putaway** write (`validateDelta` returns early unless the destination changed; `onAfterCreate` returns early when no destination is set; and there is **no** delete hook for `Itemdata` or `Client`, nor any handler at all for `Location`). Closing this needs a repository-event or interceptor mechanism, and that class is authz-entangled — its own comments record that calling `validateOnly` unconditionally once made every HAL `POST /v3/itemdata` require `sb_admin`. **Not live-probed:** derived from code only |
| `SyspropService.getStringDefault` self-invoked its own `@CacheEvict` | `sysprops` | a READ that seeds a missing row | **Closed by SBDEV-3135** (2026-08-31, review round 2) — was Medium. `getStringDefault` calls `createSystemProperty` on `this`, so the proxy is bypassed and that method's `@CacheEvict` never fired: a read that INSERTs a default left the cached MISS in place for the 2-minute TTL, and `getByKey(String)` caches nulls. `AdviceService` reaches `getStringDefault` through the 2-arg overload on the advice / customer-order path, so the code path is live even though no live reader currently caches a miss for the key. Now evicts the exact key programmatically. ⚠ **Defence in depth, not a currently-reachable bug** — corrected after review round 3, which measured that the reader caching nulls (`getByKey(String)`) has **no callers in `src/main`** while the only live reader (`getSysvalue`) carries `unless = "#result == null"` and so never stores a miss. It becomes load-bearing the moment `getByKey` is wired up or that `unless` is dropped. **Only two self-invocations of an evicting (`@CacheEvict`) method exist in `src/main`** — self-invoked `@Cacheable` READS are more common (at least five more, all live) (this one and the dead `LocationService` one below); `PutawayConfigService` has none |
| ~~`LocationService.createSystemStorageLocation` self-invokes `getByName` and `createLocation`~~ | `locations` | — | **Not a gap — dead code.** The method is private and all four call sites are commented out (`// TODO if null create? createSystemStorageLocation(...)`), so it has zero live callers repo-wide. Kept in the table only so the next sweep does not "fix" it as though it were live |
| Multi-replica staleness (all caches) | All four Spring caches | Any write on any replica | **High in multi-replica deployments.** `@CacheEvict` only evicts the local JVM's cache; other replicas keep stale entries until TTL. The `redis` profile is the intended fix and **no in-repo artefact activates it** — the only reference is a comment at `application.properties:22`; nothing in `src/`, the Dockerfiles or `.gitlab-ci.yml` sets it. ⚠ *That does NOT establish that Caffeine is what runs in production:* `SPRING_PROFILES_ACTIVE` is an environment variable, and a k8s manifest, GitLab CI variable or `docker run -e` outside this repo sets it just as well. Neither the profile in effect nor the replica count is derivable here — no deployment descriptor lives in this repo. **Confirm against the running dev/UAT config before relying on "Caffeine everywhere".** See §1 "Caffeine, not Redis" |
| Scheduled jobs without tenant context | All caches | Any `@Scheduled` job that calls a cached service method without explicitly setting `TenantContext` | High: `TenantContext.getCurrentTenant()` returns `null`, the SpEL key resolves to the `"no-tenant"` bucket (`TenantKeyBuilder.cacheKey`), and jobs across tenants then share that bucket |

### Closed gaps

Kept rather than deleted, because each one's mechanism is the reason its fix is shaped the way it is.

| Gap | Closed by | Note |
|-----|-----------|------|
| `SkuRestController.delete` did not evict `itemdata` | **SBDEV-3135** (2026-08-31) — programmatic eviction in a `finally` block, **not** `@CacheEvict`. All **three** `/rest/sku` write handlers now use that one mechanism and none carries the annotation: round 3 measured `create`/`update`'s `@CacheEvict` as 100% redundant once they had the `finally` (two `cache.clear()` calls per request, a doubled KEYS+DEL round-trip under the `redis` profile), so it was dropped | Was rated Low, re-rated Low→Medium on 2026-08-27, and shipped as **High**. Two escalations. The stale entry was **deterministic**: the handler locates each row through the `@Cacheable` `findByClientIdAndItemNr` immediately before deleting it, so every delete warmed the cache with the entity it removed. And the stale entry reached a **write**: `update` feeds the same cached lookup into `SkuBatchCreateUpdateService.upsertAll`, whose non-null branch calls `save()` on a detached entity whose row is gone. With `@Version Integer` non-null, Spring Data's `isNew()` is false, so that resolves to `merge()` — and on **Hibernate 6.6.39** a merge whose row has been deleted throws **`StaleObjectStateException`** (`DefaultMergeEventListener`, the `result == null` branch (416-434): `isTransient` returns `FALSE` for an entity carrying both a generated id and a version), surfacing as `ObjectOptimisticLockingFailureException`. ⚠ **An earlier version of this row said Hibernate silently RE-INSERTS the SKU under a fresh sequence id — that is wrong**, and it is Hibernate-**5** behaviour: in 5.4 the `StaleObjectStateException` is commented out above an unconditional `entityIsTransient(...)`; Hibernate 6 activated that throw behind the `isTransient() == FALSE` condition and demoted `entityIsTransient` to the `else` arm, where it still exists. (An earlier phrasing here had the two the wrong way round — the conclusion was right, the supporting detail inverted.) A review lane caught it. So the real symptom is a SKU update failing as an unexplained optimistic-lock error against a row nobody touched, for the full TTL — a different and less alarming defect than data resurrection, but still a real one. (The `UNIQUE (client_id, item_nr)` argument that used to sit here is true in isolation but defends against a re-insert that does not happen; dropped.) A second, self-healing effect: `create` read the stale *present* `Optional` and refused re-creation with `ENTITY_ALREADY_EXITS` (422) for the TTL |
| `FileImportController.importClients` did not evict `clients` | **SBDEV-3135** (2026-08-31) — `@CacheEvict(value = "clients", allEntries = true)` | Matches the eviction `importSkus` already carried. The negative-caching row above is what made this bite: a lookup taken before the import is remembered as "no such client" |
| `LocationService.createLocationFromRequest` did not evict `locations` | **SBDEV-3135** (2026-08-31) — `@CacheEvict(value = "locations", allEntries = true)` | Textbook sibling gap: two methods on one class create locations and only `createLocation` evicted. Its own duplicate check caches the miss |
| `LocationService.updateLocation` did not evict `locations` | **SBDEV-3135** (2026-08-31) — `@CacheEvict(value = "locations", allEntries = true)` | **`allEntries` is required here, not merely consistent.** This method can RENAME a location while `getByName` is keyed on the name, so a key-scoped evict (`key = "…#location.name"`) would clear only the new name and leave the OLD name resolving to a location that no longer answers to it. Pinned by `CacheEvictionOnWriteUnitTest.updateLocation_shouldEvictOldName_whenLocationRenamed`, which renames deliberately so a key-scoped variant cannot pass |
| `FileImportController.importLocations` did not evict `locations` | **SBDEV-3135** (2026-08-31) — `@CacheEvict(value = "locations", allEntries = true)` | Found by a review lane, not by the sweep: it sits 45 lines from `importClients` in the same class and got **no** cover from the `createLocationFromRequest` fix, because it never touches `LocationService` — it writes through `locationRepository` directly |
| `ClientController.create` / `setSection` / `setPrinter` / `toggleReceiving` did not evict `clients` | **SBDEV-3135** (2026-08-31) — `@CacheEvict(value = "clients", allEntries = true)` on all four | Found by a review lane. The file had no cache import at all. These are the **single-client UI** routes — higher traffic and more user-facing than the bulk import that the ticket named. `setSection` is the one with a named operational consequence: a client whose Section is wrong silently stalls Pick&Pack at RAW with no operator signal, so a stale `Client` reporting the old section is a five-minute silent stall right after an operator "fixed" it |
| `SystemPropertyController.createSystemProperty` and `updateClient` did not evict `sysprops` | **SBDEV-3135** (2026-08-31) — `@CacheEvict(value = "sysprops", allEntries = true)` on both | Found by a review lane. Same create-has-none / update-has-one asymmetry as `SkuRestController.delete`, in a class whose own `updateValue` has always evicted. This doc's §4 had actively asserted the opposite — see the correction there |

**How these fixes are guarded.** `unit/config/CacheEvictionOnWriteUnitTest` — **17 tests over 14 write paths** (one per eviction site this ticket adds or changes) — drives a **real Spring cache proxy** (real services, mocked repositories) rather than asserting the annotations are present: it warms the cache through the same `@Cacheable` reader production uses, invokes the writer, and asserts on what the reader then returns.

**Exactly what the mutation testing establishes, and what it does not.** Each of the **14 eviction sites SBDEV-3135 adds or changes** — 10 `@CacheEvict` annotations plus 4 programmatic calls — was removed **one at a time** and killed at least one test. Stripping all of them at once fails 17 of 17. ⚠ On the classes this suite touches there are **5** pre-existing annotations the ticket did not change (`FileImportController.importSkus`, `SystemPropertyController.updateValue`, `LocationService.createLocation`, `SyspropService.createSystemProperty` and `.setSysvalue`), and all 5 **survive** individual removal against this suite. That is a count over *these classes only* — `PutawayConfigService` carries a further 10 `@CacheEvict` declarations across 6 methods, also uncovered — it was never written to cover them, and they remain unpinned. An earlier version of this paragraph claimed "every eviction was removed one at a time and killed exactly its own test(s)", which a third review round measured false for 5 of the then-11 claimed sites; the phrasing here is deliberately scoped to what was actually measured.

Two things that pass measurement worth recording, because both are counter-intuitive:

- **`proxyTargetClass = true` is NOT load-bearing**, contrary to what an earlier version of this paragraph and the test's own javadoc claimed. Replacing it with a bare `@EnableCaching` leaves every test green: `DefaultAopProxyFactory` picks CGLIB when `isOptimize() || isProxyTargetClass() || !hasUserSuppliedInterfaces()` (Spring 6.2), and none of the classes under test implements an interface, so the second disjunct already holds. The flag stays only to keep the harness aligned with Boot's production default.
- **`create` and `update` needed the `finally` too, and a second review round found it.** Their `@CacheEvict` still fires on the normal path, but an exception escaping *after* `upsertAll` has committed skips it — the inner `try` around the service-log write catches only `IOException`, while `getOmsInstanceName()` is a DB read and `createMessage()` a DB write. Measured: a `RuntimeException` from either leaves the misses those handlers' own `@Cacheable` lookups warmed, so a retry sees the SKU as absent, passes the duplicate check, and hits `UNIQUE (client_id, item_nr)` — a 500 constraint violation instead of a clean 422, for the full TTL. `@Transactional` on `upsertAll` does **not** close this: it protects against a rollback leaving stale cache, not against an exception after the commit.
- **A harness can be vacuous through aliasing.** The `toggleReceiving` eviction could be deleted with all tests still green, because the harness handed the *same* `Client` instance to both the cached reader and the writer — so the writer flipped the field on the very object in the cache and the assertion passed without any eviction. Fixed by answering each stub with a fresh instance. That aliasing is a real property of caching mutable JPA entities here, not just a test artefact, and it is why `PutawayConfigController.setSku` loads through `itemdataRepository` rather than the `@Cacheable` accessor.

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
| **2026-08-31** | **SBDEV-3135 — cache eviction on write.** **Fourteen** eviction sites fixed across as many write paths, not the four the ticket named: `SkuRestController.delete` (programmatic `finally`-block eviction — no `@CacheEvict` variant can cover its escaping-exception path), `FileImportController.importClients` and `.importLocations`, `LocationService.createLocationFromRequest` and `.updateLocation`, `ClientController.create`/`setSection`/`setPrinter`/`toggleReceiving`, `SystemPropertyController.createSystemProperty`/`.updateClient`, the `finally` blocks on `SkuRestController.create`/`.update`, and `SyspropService.getStringDefault`'s explicit evict. The last seven were found by two independent review lanes after the first cut shipped only the four named rows — the sibling sweep had stopped one method short *inside a file it was already editing*. Guarded by `unit/config/CacheEvictionOnWriteUnitTest` (**17** tests, real cache proxy). Each of the **14 sites this ticket adds or changes** was removed one at a time and killed at least one test; stripping all of them fails 17 of 17. ⚠ The pre-existing annotations on those same classes are **not** covered by this suite — see §7. **Six measured doc corrections, all pre-existing:** (1) **expiry policy** — asserted `expireAfterAccess` in 5 places here + 3 in `wms2-stockunit-design.md` incl. a fabricated code block; `expireAfterAccess` appears **zero** times in `src/`, and `695a4549` (SBDEV-2218, 2026-05-12) switched to `expireAfterWrite`. (2) **§3/§4/§5 tenant key** — documented the pre-SBDEV-3033 `facilityCode`-only prefix as current (21 occurrences in §3/§4, plus two SpEL samples in §5 that **prescribed** it as the pattern to copy — caught only in review round 4) and claimed "the routing architecture ensures" no collision; it did not. (3) `sysprops` TTL is 2 minutes, not 5. (4) `wms2-stockunit-design.md`'s eviction table named **five methods that do not exist**. (5) §4 claimed `SystemPropertyController.createSystemProperty` "delegates to `SyspropService.createSystemProperty` which carries `@CacheEvict`" — it saves through the repository directly, with no eviction; that false claim is why the gap survived. (6) §4 still described two of the four fixed gaps as open after §7 had been rewritten, so the doc contradicted itself ~40 lines apart. **Claims of my own that review REFUTED and are corrected here:** the deleted-SKU merge does **not** silently re-insert under a fresh sequence id (Hibernate 6.6 throws `StaleObjectStateException`); `proxyTargetClass = true` is **not** load-bearing; `Itemdata`'s SDR writes **are** withdrawn, so only `client`/`location`/`sysprop` are exposed. **New open gaps recorded:** negative caching (no `unless` on 4 readers), the SDR write surfaces for three caches, and `createSystemStorageLocation`'s self-invocation. | 14 sites fixed, 13 doc errors corrected across 2 docs, 3 new gaps recorded, 9 of my own claims refuted over 4 review rounds | Code read of `origin/develop` + `git log -S` + psql on `dev_wh01_om1` + 20 mutation runs (every added site individually) + **4** independent review rounds + full suite (**5803 / 0 failures / 0 errors / 67 skipped** on `3a3acf3e`; the one red seen during the work, `NeverMatcherNullBlindnessArchTest`, was pre-existing from PR #247 and was cleared by PR #248 mid-review) |
| 2026-04-27 | Initial — `CacheConfig.java`, `SyspropService`, `ClientService`, `ItemdataService`, `LocationService`, `KeycloakService`, `SystemPropertyController`, `ItemDataController`, `FileImportController`, `SkuRestController` | All cache definitions and `@Cacheable` / `@CacheEvict` sites confirmed against source | Code read |
| 2026-08-27 | SBDEV-3017 deletion sweep. **Two §4 `itemdata` rows retired**: `ItemdataService.setPutAwayLocation` and `ItemDataController.setPutAwayLocation` were both deleted (mutating GET on a controller outside `GUARDED`; the service twin had zero callers). **Found pre-existing drift**: the `ItemDataController` row claimed `@CacheEvict(allEntries = true)`, which SBDEV-2732 had already removed — so that row had been wrong since then, and the identical wrong claim also sat in `IdempotencyFilter`'s javadoc at `:413` (corrected in code). **Re-rated the `SkuRestController.delete` gap Low→Medium**: the handler warms the `itemdata` cache through a `@Cacheable` lookup at `:323` immediately before deleting the row, making the stale entry deterministic rather than incidental. | 2 rows retired, 1 pre-existing error corrected, 1 gap re-rated | Code read + full suite (5672/0/67) |
| 2026-06-14 | Added the second out-of-band cache to the §out-of-band table: `MultiTenantJwtDecoder.jwtDecoders` (per-tenant `JwtDecoder`, `maximumSize(200)`, `expireAfterWrite(24h)`) — merged via 260610 hardening Phase B (PR #41), replacing an unbounded `ConcurrentHashMap`. Cross-linked to end-to-end §4.2. | Doc addition; matches code | Doc-drift audit (verify-docs) |
| 2026-06-11 | Targeted re-verify for plan 260610 (SKU trim normalization): `ItemdataService.findByClientIdAndItemNr` now trims `itemNr` in the body while the `@Cacheable` SpEL key stays on the raw arg (padded-key entries self-heal — note added to §table row). Found + fixed drift: `setPutAwayLocation` no longer uses `allEntries = true`; it carries `@Caching(evict)` with the two targeted keys (`ItemdataService.java:60-65`). `SkuRestController.delete` no-eviction gap (§7 row) still present and now marginally wider since padded deletes resolve. | §table row + §7 confirmed; one row corrected | Code read (plan 260610 implementation) |
| 2026-05-08 | Re-verified Caffeine swap: `CacheConfig.java` defines 4 caches (`sysprops`, `clients`, `locations`, `itemdata`) all with 5-min TTL via `Duration.ofMinutes(5)` (lines 34-37); `SyspropService.@Cacheable("sysprops")` (lines 95, 288) + `@CacheEvict` (line 53) supersede the prior 30s volatile cache pattern. Optimistic-lock resilience for Group C — 9 catch sites across `service/job/ReleaseOrderJobService.java`, `service/job/ReplenishOrderJobService.java`, `MobileReplenishService`, `MobilePickingService`, `MobilePutAwayService`, `PickingorderBusinessService`, `BasicService`, plus the `OptimisticLockRetry` utility and the controller-layer `PickingController` retry. ItemData cache eviction story confirmed — `ItemdataService.setPutAwayLocation` + `ItemDataController.setPutAwayLocation` + `FileImportController.importSkus` + `SkuRestController.create` / `update` all carry `@CacheEvict(value = "itemdata", allEntries = true)`. `SkuRestController.delete` gap (no eviction) still present — see §7 row. | All claims confirmed; no drift; only frontmatter and verified-line bumped. | Code read (grep-based) |

**Re-verify every 60 days.** Next due: **2026-07-07**.
