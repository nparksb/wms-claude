# Cache Configuration Improvement Plan

**Date:** 2026-03-13
**Last Updated:** 2026-03-14 (All 5 improvements implemented, all 3703 tests passing)
**Status:** ALL IMPROVEMENTS IMPLEMENTED
**Severity:** Medium — performance optimization, no functional bugs

---

## 1. Current State

### CacheConfig (`src/main/java/net/aim_ai/wms/config/CacheConfig.java`)

```java
@Configuration
@EnableCaching
public class CacheConfig {
    @Bean
    public CacheManager cacheManager() {
        CaffeineCacheManager manager = new CaffeineCacheManager(
            "itemdata", "locations", "clients", "sysprops"
        );
        manager.setCaffeine(Caffeine.newBuilder()
            .maximumSize(500)
            .expireAfterWrite(Duration.ofMinutes(15))
            .recordStats());
        return manager;
    }
}
```

### Cache Usage Summary

| Cache | `@Cacheable` | `@CacheEvict` | Key Strategy | Status |
|-------|:---:|:---:|---|---|
| `clients` | `ClientService.getByNumber()` | — | `facilityCode + ':' + clientNumber` | Working |
| `locations` | `LocationService.getByName()` | `LocationService.createLocation()` | `facilityCode + ':' + name` | Working |
| `sysprops` | `SyspropService.getByKey()` | `SyspropService.createSystemProperty()` | `facilityCode + ':' + key` | Partially working |
| `itemdata` | **NONE** | **NONE** | **NONE** | **Dead — never used** |

---

## 2. Issues Found

### Issue 1: `itemdata` Cache Is Dead (Critical Gap)

The `itemdata` cache is declared in `CacheConfig` but has **zero `@Cacheable` or `@CacheEvict` annotations** anywhere in the codebase. No service method populates or reads from it.

**Impact:** Itemdata lookups (SKU/product records) hit the DB on every call. Itemdata is one of the most frequently accessed entities — used in receiving, picking, shipping, replenishment, stock transfers, and cycle counts.

### Issue 2: `findSysvalueBySyskey` Bypasses Cache (146 calls, 47 files)

The `SyspropService.getByKey(key)` method has `@Cacheable` but returns a `Sysprop` entity object. However, the **vast majority of sysprop lookups** go directly to `SyspropRepository.findSysvalueBySyskey()` which returns a raw `String` and completely bypasses the cache.

**Key callers bypassing cache:**
- `ReceivingService` — 4 calls
- `BillofladingService` — 6 calls
- `PrintService` — 8 calls
- `ManageOrderService` — 8 calls
- `MobilePalletizingService` — 9 calls
- `SchedulingConfiguration` — 13 calls
- All scheduled jobs

**Impact:** System properties are small, rarely change, and queried on nearly every operation. Every request triggers multiple DB queries for the same static config values.

### Issue 3: `getSystemClient()` Not Cached (46 calls, 29 files)

`ClientService.getSystemClient()` queries `clientRepository.findByClNr(WmsConstants.SYSTEM_CLIENT_NUMBER)` on every call. The system client **never changes** during runtime. It's the single most queried client record.

**Impact:** 46 redundant DB queries per request path that touches system client (which is most of them).

### Issue 4: Single Cache Config for Different Access Patterns

All 4 caches share identical settings (`maximumSize(500)`, `expireAfterWrite(15 min)`), despite very different characteristics:

| Cache | Cardinality | Mutation Frequency | Access Frequency |
|-------|:---:|:---:|:---:|
| `sysprops` | ~50-100 per tenant | Rare (admin-only changes) | Very high (every request) |
| `clients` | ~5-20 per tenant | Very rare | High |
| `locations` | ~500-5000 per tenant | Rare | High |
| `itemdata` | ~1000-10000 per tenant | Moderate (new SKUs added) | Very high |

**Problems:**
- **`sysprops`**: 500 max entries is way too many; 15min TTL is unnecessarily short for data that rarely changes
- **`locations`**: 500 max entries may be too few for large warehouses with 3000+ locations
- **`itemdata`**: If ever wired up, 500 entries would be far too few for a catalog of 5000+ SKUs

### Issue 5: Multi-Tenant Cache Isolation

The cache keys correctly prefix with `facilityCode` (e.g., `WH01:locationName`), which is good. But the `maximumSize(500)` is **per cache, shared across all tenants**. With 5 tenants each having 200 locations, the `locations` cache would be at capacity and evicting entries constantly.

---

## 3. Recommended Improvements

### Improvement 1: Wire Up `itemdata` Cache (High Priority)

Add `@Cacheable` to the most frequently called itemdata lookup methods. Need to identify which service/repository methods to cache.

**Likely candidates:**
- `ItemdataRepository.findById()` — called in virtually every flow
- `ItemdataRepository.findByClientIdAndItemNr()` — called during receiving, order processing

**Approach:** Create an `ItemdataService` (or add to an existing service) with cached lookup methods, similar to `LocationService.getByName()`.

**Key strategy:** `facilityCode + ':' + itemdataId` or `facilityCode + ':' + clientId + ':' + itemNr`

**Eviction:** Add `@CacheEvict` to any methods that update itemdata (likely in the admin controller).

### Improvement 2: Cache `findSysvalueBySyskey` Calls (High Priority)

**Option A (minimal change):** Add `@Cacheable` directly to `SyspropRepository.findSysvalueBySyskey()`:
```java
@Cacheable(value = "sysprops", key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #syskey")
String findSysvalueBySyskey(String syskey);
```
But this won't work — Spring cache proxies don't intercept repository interface default methods correctly for native queries.

**Option B (recommended):** Route all `findSysvalueBySyskey` calls through `SyspropService` with a cached wrapper method:
```java
@Cacheable(value = "sysprops", key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #key")
public String getSysvalue(String key) {
    return syspropRepository.findSysvalueBySyskey(key);
}
```
Then refactor the 47 callers to use `syspropService.getSysvalue(key)` instead of `syspropRepository.findSysvalueBySyskey(key)`.

**Risk:** Medium — large refactor touching 47 files. Can be done incrementally, starting with the hottest callers.

### Improvement 3: Cache `getSystemClient()` (High Priority, Easy Win)

```java
@Cacheable(value = "clients", key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':SYSTEM'")
public Client getSystemClient() {
    return clientRepository.findByClNr(WmsConstants.SYSTEM_CLIENT_NUMBER).orElse(null);
}
```

**Risk:** Low — system client never changes. No eviction needed.

### Improvement 4: Per-Cache Configuration (Medium Priority)

Replace the single `CaffeineCacheManager` with individual cache configurations:

```java
@Configuration
@EnableCaching
public class CacheConfig {

    @Bean
    public CacheManager cacheManager() {
        SimpleCacheManager manager = new SimpleCacheManager();
        manager.setCaches(List.of(
            buildCache("sysprops", 200, Duration.ofMinutes(60)),
            buildCache("clients", 100, Duration.ofMinutes(60)),
            buildCache("locations", 2000, Duration.ofMinutes(30)),
            buildCache("itemdata", 3000, Duration.ofMinutes(15))
        ));
        return manager;
    }

    private CaffeineCache buildCache(String name, int maxSize, Duration ttl) {
        return new CaffeineCache(name, Caffeine.newBuilder()
            .maximumSize(maxSize)
            .expireAfterAccess(ttl)  // Use expireAfterAccess for reference data
            .recordStats()
            .build());
    }
}
```

**Key changes:**
- **`sysprops`**: 200 max, 60min TTL — small cardinality, rarely changes
- **`clients`**: 100 max, 60min TTL — very few per tenant, rarely changes
- **`locations`**: 2000 max, 30min TTL — large cardinality, rarely changes
- **`itemdata`**: 3000 max, 15min TTL — largest cardinality, moderately changes
- **`expireAfterAccess`** instead of `expireAfterWrite` — keeps hot entries longer, only evicts truly unused entries

### Improvement 5: Consider `expireAfterAccess` for Reference Data (Low Priority)

Current config uses `expireAfterWrite(15 min)` — entries expire 15 minutes after being written, even if accessed constantly. For reference data (locations, clients, sysprops) that rarely changes, `expireAfterAccess` is better:

- **`expireAfterWrite`**: Good for data that changes externally (e.g., itemdata updated by imports)
- **`expireAfterAccess`**: Good for stable reference data (locations, clients, sysprops)

---

## 4. Implementation Priority

| # | Improvement | Effort | Impact | Risk |
|---|------------|--------|--------|------|
| 1 | Cache `getSystemClient()` | Small (1 annotation) | High (eliminates ~46 DB calls/request) | Low |
| 2 | Per-cache configuration | Small (config change) | Medium (right-sized caches) | Low |
| 3 | Cache `findSysvalueBySyskey` via service | Medium (47 files) | High (eliminates ~146 DB calls) | Medium |
| 4 | Wire up `itemdata` cache | Medium (new service method + callers) | High (most queried entity) | Medium |
| 5 | `expireAfterAccess` for reference data | Small (config change) | Low-Medium (better hit rates) | Low |

**Recommended order:** 1 → 2 → 5 → 3 → 4

Improvements 1, 2, and 5 are config-only changes with immediate benefit and near-zero risk. Improvements 3 and 4 require service refactoring and should be done incrementally.

---

## 5. Monitoring

The current config includes `.recordStats()` which is good. To observe cache performance, expose Caffeine metrics via the actuator:

```properties
# Already exposed in application.properties:
management.endpoints.web.exposure.include=health,info,metrics,hikaricp
# Add 'caches' or use metrics endpoint to query cache.* metrics
```

Cache hit/miss rates are available at `/actuator/metrics/cache.gets` with tags for cache name and result (hit/miss).

---

## 6. Implementation Log

### Implemented (2026-03-13)

| # | Improvement | Status | Files Changed |
|---|------------|--------|---------------|
| 1 | Cache `getSystemClient()` | DONE | `ClientService.java` — added `@Cacheable` with tenant-aware key |
| 2 | Per-cache configuration | DONE | `CacheConfig.java` — replaced single `CaffeineCacheManager` with `SimpleCacheManager` + per-cache `CaffeineCache` instances |
| 3 | Cache `findSysvalueBySyskey` via service | DONE | `SyspropService.java` — added cached `getSysvalue()` method; ~45 source files + ~32 test files updated to route through service |
| 4 | Wire up `itemdata` cache | DONE | `ItemdataService.java` — added `@Cacheable getById()` and `findByClientIdAndItemNr()`; 37 source files + 30 test files refactored to route through cached service |
| 5 | `expireAfterAccess` for reference data | DONE | `CacheConfig.java` — switched from `expireAfterWrite` to `expireAfterAccess` for all caches |

### Additional fixes during implementation

- `SystemPropertyController.java` — added `@CacheEvict` on `updateValue()` for sysprops cache invalidation
- `LocationRepository.java` — replaced Java text blocks (`"""`) with string concatenation in `@Query` annotations to fix ByteBuddy/Mockito class instrumentation issue
- `TenantPoolConfigTest.java` — fixed pre-existing compilation error (`TenantProfile` constructor changed to require 2 args)
- 3 test files (`AdminActionControllerUnitTest`, `SystemControllerUnitTest`, `ManageOrderServiceUnitTest`) — fixed incorrect `verify(syspropRepository).getSysvalue()` → `verify(syspropService).getSysvalue()`

### Test results

- **3,703 tests run, 0 failures, 0 errors, 3 skipped (pre-existing)**
- BUILD SUCCESS

### Improvement 4: Itemdata Cache (Implemented 2026-03-14)

Wired up the `itemdata` Caffeine cache using Option A from the original plan:

**Changes:**
- `ItemdataService.java` — added two cached methods:
  - `@Cacheable getById(Long id)` — returns `Itemdata`, throws `EntityNotFoundException` if not found; key: `facilityCode + ':id:' + id`
  - `@Cacheable findByClientIdAndItemNr(Long clientId, String itemNr)` — returns `Optional<Itemdata>`; key: `facilityCode + ':' + clientId + ':' + itemNr`
  - `@CacheEvict(value = "itemdata", allEntries = true)` on `setPutAwayLocation()`
- `@CacheEvict` added to: `ItemDataController`, `SkuRestController.create/update`, `FileImportController` SKU import
- 37 source files refactored: `itemdataRepository.findById()` → `itemdataService.getById()` for all `.orElseThrow()` patterns
- `findByClientIdAndItemNr` callers routed through `itemdataService.findByClientIdAndItemNr()`
- 6 files kept using `itemdataRepository.findById()` directly for Optional-pattern usage (`StockrecordService`, `StockunitService.getStockunitDetails`, `AdviceRestController`)
- 30+ test files updated to mock `itemdataService.getById()` instead of `itemdataRepository.findById()`
- 4 new unit tests added in `ItemdataServiceUnitTest`: `getById` (exists + not found), `findByClientIdAndItemNr` (exists + not found)

---

## 7. Multi-Replica Deployment Considerations

The current Caffeine cache is **in-process (local JVM memory)**. Each replica has its own independent cache. This has implications when running multiple replicas of WMS-API.

### Problem

1. **Stale data across replicas**: Replica A updates a record and evicts its local cache. Replicas B and C still serve the old cached value until the TTL expires.
2. **Cache eviction is local-only**: `@CacheEvict` only clears the cache in the replica that processed the request. Other replicas are unaware of the change.

### Risk Assessment per Cache

| Cache | Mutation Frequency | TTL | Risk with Multiple Replicas |
|-------|---|---|---|
| `getSystemClient()` | Never at runtime | 60min | **None** — completely safe |
| `sysprops` | Very rare (admin-only) | 60min | **Low** — changes are infrequent, TTL-based self-healing is acceptable |
| `clients` | Very rare | 60min | **Low** — same reasoning |
| `locations` | Rare | 30min | **Low** — same reasoning |
| `itemdata` | Moderate (SKU imports, putaway changes) | 15min | **Medium** — SKU imports could serve stale data on other replicas for up to 15 minutes |

### Options for Future Improvement

1. **Accept with current TTLs (recommended for now)** — WMS reference data (SKUs, locations, clients, sysprops) changes rarely during warehouse operations. The 15-60min stale windows are acceptable for read-heavy reference data. Replicas self-heal when the TTL expires.

2. **Redis as distributed cache** — Replace Caffeine with `spring-boot-starter-data-redis`. All replicas share one cache. Evictions are global. Requires a Redis instance. Highest consistency but adds infrastructure dependency.

3. **Hybrid approach** — Keep Caffeine for truly immutable or very-low-mutation data (`getSystemClient()`, `sysprops`, `clients`, `locations`). Add Redis only for `itemdata` which has the highest mutation rate. Balances performance with consistency.

4. **Event-based invalidation** — Use PostgreSQL `LISTEN/NOTIFY` or a lightweight message bus to broadcast cache eviction events to all replicas when data changes. Most complex but zero-TTL staleness.

### Current Recommendation

**Option 1** is pragmatic for the current deployment. If stale `itemdata` becomes an issue after SKU imports, consider reducing the itemdata TTL to 2-5 minutes, or adding Redis for itemdata specifically (Option 3).
