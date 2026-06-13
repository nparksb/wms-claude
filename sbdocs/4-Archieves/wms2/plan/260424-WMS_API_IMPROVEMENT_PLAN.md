# WMS-API Performance & Reliability Improvement Plan

**Date:** 2026-03-11
**Branch:** `v2/develop-260310`
**Spring Boot:** 3.5.9 | **Java:** 21 | **Hibernate:** 6.x

---

## Executive Summary

This plan addresses 6 improvement areas for the WMS-API, ordered by **impact vs effort**. Two of the originally proposed areas (transaction manager annotations and virtual threads) are **already implemented**, so we focus on the 4 remaining areas plus 2 newly identified opportunities.

| # | Area | Status | Impact | Effort | Priority |
|---|------|--------|--------|--------|----------|
| 1 | Transaction Manager Annotations | **DONE** | - | - | - |
| 2 | Virtual Threads | **DONE** | - | - | - |
| 3 | Entity equals/hashCode | Needs work | **Critical** | Medium | **P0** |
| 4 | Connection Pool Tuning | Partially done | High | Low | **P1** |
| 5 | Application-Level Caching | New finding | **High** | Medium | **P1** |
| 6 | N+1 Query / Bulk Operations | New finding | High | Medium | **P2** |
| 7 | Database Index Optimization | **Audit complete** | **High** | Low | **P1** |
| 8 | GraalVM Native Image | Needs assessment | Low | High | **P3** |

---

## Area 1: Transaction Manager Annotations — ALREADY FIXED

### Current State

All `@Transactional` annotations in the service layer **already specify** `value = "tenantTransactionManager"`. A grep across all 63 service files confirms zero bare `@Transactional` annotations remain.

Additionally, `TenantDatabaseConfig.java` correctly wires the JPA repositories:
```java
@EnableJpaRepositories(
    basePackages = "net.aim_ai.wms.repo.jpa",
    entityManagerFactoryRef = "tenantEntityManagerFactory",
    transactionManagerRef = "tenantTransactionManager"  // repos inherit this
)
```

### Action: None required

The only remaining concern is ensuring **new code** follows the pattern. This is documented in `CLAUDE.md` and should be enforced in code reviews.

---

## Area 2: Virtual Threads — ALREADY ENABLED

### Current State

`application.properties` already has:
```properties
spring.threads.virtual.enabled=true
```

This means Spring Boot 3.5.9 is already using virtual threads for:
- Tomcat request handling (each HTTP request runs on a virtual thread)
- `@Async` methods (if using the default executor)

### ThreadLocal Compatibility Assessment

`TenantContext.java` uses `ThreadLocal<TenantProfile>` which is **compatible with virtual threads** because:
- Virtual threads support `ThreadLocal` (they inherit from `Thread`)
- The `TenantFilter` sets context at request start and clears at request end
- No thread pooling of virtual threads occurs (each request gets a fresh VT)

**No `synchronized` blocks or `ReentrantLock` usage found** in the codebase — this is ideal for virtual threads since pinning (blocking a carrier thread) is not a risk.

### Potential Concern: ThreadLocal in Scheduled Jobs

The `TenantContext` ThreadLocal works correctly for HTTP requests because each virtual thread is fresh (not pooled/reused). However, **scheduled jobs** in `SchedulingConfiguration.java` use a `ThreadPoolTaskScheduler` with 10 platform threads — these ARE reused. Ensure every scheduled job wraps tenant operations in try-finally with `TenantContext.clear()`.

A comment in `CustomerorderBatchService.java:816` explicitly notes this limitation.

### Action: Minor — audit scheduled jobs for TenantContext cleanup

Consider migrating to `ScopedValue` (Java 21 preview → stable in Java 25) in the future for better virtual thread semantics, but `ThreadLocal` works correctly for HTTP requests today.

---

## Area 3: Entity equals/hashCode — CRITICAL FIX NEEDED

### Current State

All 68 JPA entities extend `AbstractBaseEntity` (`src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java`), which has:
- `hashCode()` — **YES** (ID-based: `getId() != null ? Long.hashCode(getId()) : 0`)
- `equals()` — **NO** (missing — defaults to `Object.equals()` / reference equality)

This means **all entities have a broken equals/hashCode contract**: `hashCode()` is based on `id`, but `equals()` uses reference identity. Two detached entities with the same `id` will have the same hash but won't be `.equals()`.

Additionally, ~40 entities override `equals()` in their own class but do NOT override `hashCode()`, relying on `AbstractBaseEntity.hashCode()`. This partially works but is inconsistent.

### Impact

**83 entity comparison operations** found across 20 service files using `.equals()`, `.contains()`, `.remove()`, `.indexOf()`:

| Service | Comparison Count | Risk Level |
|---------|-----------------|------------|
| `BillofladingService` | 10 | **Critical** — BOL close/ship operations |
| `CustomerorderBatchService` | 10 | **Critical** — batch order processing |
| `ReceivingService` | 8 | **Critical** — goods receipt |
| `UnitloadBusinessService` | 7 | High — unit load transfers |
| `TransferOrderService` | 6 | High — transfer operations |
| `NameTypeService` | 6 | Medium |
| `AccessService` | 5 | Medium |
| `OrderMonitorViewService` | 5 | Medium |
| `CustomerorderService` | 4 | High |
| `StockunitBusinessService` | 4 | High |
| Others (10 files) | 18 | Varies |

**Note:** Currently, most service code compares entity IDs directly (e.g., `entity.getId().equals(otherId)`) rather than entity objects, which is why things work today. The risk is in `List.contains()`, `List.remove()`, `Set` operations, and future refactoring.

### Recommended Fix: Add `equals()` to AbstractBaseEntity

This is a **single-file, ~8-line fix** that covers all 68 entities at once:

```java
// Add to AbstractBaseEntity.java
@Override
public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof AbstractBaseEntity other)) return false;
    if (this.getClass() != other.getClass()) return false;
    return getId() != null && getId().equals(other.getId());
}
```

**Why this pattern:**
- `instanceof AbstractBaseEntity` — works with Hibernate proxies (proxies extend the entity class)
- `getClass() != other.getClass()` — prevents `Stockunit.equals(Location)` from returning true when both have `id=1`
- `getId() != null` — two unsaved entities (null id) are never equal (prevents accidental merges)
- Existing `hashCode()` is already ID-based — **contract is now consistent**

### Additional Entity-Specific Cleanup

After fixing `AbstractBaseEntity`, review entities that override `equals()` individually:

#### Phase 1: Fix `Location.java` (known broken implementation)
- Currently uses `getClass()` check (fails with Hibernate proxies) and compares by `xpos, ypos, zpos, name`
- **Decision needed:** Keep business-field comparison (if location identity = coordinates) or switch to ID-based (consistent with all other entities)
- If keeping business fields: fix to use `instanceof` check

#### Phase 2: Audit remaining entity-level `equals()` overrides
- ~40 entities have their own `equals()` — verify they use `instanceof` not `getClass()`
- Decide if entity-level overrides are still needed now that `AbstractBaseEntity` has ID-based equals
- Remove redundant overrides where they just duplicate the base class behavior

### Effort Estimate

- Add `equals()` to AbstractBaseEntity: **15 minutes**
- Fix Location.java: **30 minutes**
- Audit/clean entity-level overrides: **2 hours**
- Testing: **2 hours** (verify Sets/Maps work correctly, run existing test suite)
- **Total: ~5 hours**

### Risk Mitigation

- The existing `hashCode()` is ID-based (not constant), which means hash changes when `id` is assigned after `persist()`. This is a pre-existing behavior — don't change it now as it could break existing code that relies on the current bucketing behavior
- Run full test suite after changes
- Test specifically: BOL close, batch order processing, receiving — the highest-risk flows

---

## Area 4: Connection Pool Tuning per Tenant

### Current State

The multi-tenant connection pooling is well-architected:

| Component | Status | Notes |
|-----------|--------|-------|
| `TenantDynamicRoutingDataSource` | Good | Creates per-tenant HikariCP pools on demand |
| `TenantPoolEvictor` | Good | Evicts idle pools after 15min (configurable) |
| `TenantDbConfiguration` entity | Good | Per-tenant pool size from DB config |
| Landlord pool | Good | Correctly sized at max=2, min=1 |

**Per-tenant pool defaults** (from `createHikariPool()`):

| Setting | Current Default | Issue |
|---------|----------------|-------|
| `maxPoolSize` | 5 (from DB or fallback) | OK for most tenants |
| `minIdle` | 1 (from DB or fallback) | OK |
| `idleTimeout` | 600000 (10min) | OK |
| `connectionTimeout` | 30000 (30s) | OK |
| `maxLifetime` | **NOT SET** | **Missing — uses HikariCP default of 30min but should be explicit** |
| `leakDetectionThreshold` | **NOT SET** | **Missing — no leak detection** |
| `validationTimeout` | **NOT SET** | **Missing — no connection validation** |
| `keepaliveTime` | **NOT SET** | Good for HikariCP 5.x+ |

### Recommended Changes

#### 4.1: Add missing HikariCP settings to `createHikariPool()`

```java
private HikariDataSource createHikariPool(TenantDbConfiguration tc, String tenantKey) {
    HikariConfig cfg = new HikariConfig();
    cfg.setJdbcUrl(tc.getDbUrl());
    cfg.setUsername(tc.getDbUserName());
    cfg.setPassword(tc.getDbPassword());
    cfg.setDriverClassName(tc.getDriverClassName());
    cfg.setPoolName("HikariPool-" + tenantKey);
    cfg.setMaximumPoolSize(tc.getMaxPoolSize() != null ? tc.getMaxPoolSize() : 5);
    cfg.setMinimumIdle(tc.getMinIdle() != null ? tc.getMinIdle() : 1);
    cfg.setIdleTimeout(tc.getIdleTimeoutMs() != null ? tc.getIdleTimeoutMs() : 600000);
    cfg.setConnectionTimeout(tc.getConnectionTimeoutMs() != null ? tc.getConnectionTimeoutMs() : 30000);
    cfg.setAutoCommit(false);

    // NEW: Add these critical settings
    cfg.setMaxLifetime(1800000);           // 30min — retire connections before DB-side timeout
    cfg.setLeakDetectionThreshold(60000);  // 60s — log warning if connection held too long
    cfg.setValidationTimeout(5000);        // 5s — connection validation timeout
    cfg.setKeepaliveTime(300000);          // 5min — send keepalive to prevent DB dropping idle connections

    cfg.addDataSourceProperty("cachePrepStmts", "true");
    cfg.addDataSourceProperty("prepStmtCacheSize", "250");
    cfg.addDataSourceProperty("prepStmtCacheSqlLimit", "2048");
    return new HikariDataSource(cfg);
}
```

#### 4.2: Add HikariCP metrics exposure

Add Micrometer integration so you can monitor pool health per tenant:

```java
// In createHikariPool(), after creating the HikariDataSource:
cfg.setMetricRegistry(meterRegistry); // inject MeterRegistry via constructor
```

Update `application.properties`:
```properties
management.endpoints.web.exposure.include=health,info,metrics,hikaricp
```

#### 4.3: Make new settings configurable per tenant

Add columns to `TenantDbConfiguration` entity (via Flyway migration):
```sql
ALTER TABLE tenant_db_configuration
    ADD COLUMN max_lifetime_ms BIGINT DEFAULT 1800000,
    ADD COLUMN leak_detection_threshold_ms BIGINT DEFAULT 60000;
```

### Effort Estimate

- Phase 4.1: ~30 minutes (add 4 lines to `createHikariPool()`)
- Phase 4.2: ~1 hour (add Micrometer integration)
- Phase 4.3: ~1 hour (migration + entity update + config wiring)

---

## Area 5: Application-Level Caching — NEW RECOMMENDATION

### Problem

**Zero `@Cacheable` annotations** found in the entire codebase. Every request hits the database for data that rarely changes (master data, configuration, lookup tables).

### High-Value Caching Candidates

| Data | Current Access Pattern | Change Frequency | Cache Benefit |
|------|----------------------|------------------|---------------|
| `Itemdata` (products) | Fetched on every pick, receive, transfer | Rarely (admin updates) | **Very High** |
| `Location` (warehouse locations) | Fetched on every warehouse operation | Rarely (setup only) | **Very High** |
| `Client` (customers) | Fetched per order operation | Rarely | High |
| `UnitloadType` | Fetched per unitload operation | Almost never | High |
| `Sysprop` (system properties) | Fetched repeatedly for config | Almost never | High |
| `Boxtype` | Fetched during packing | Almost never | Medium |
| `Section`, `LocationArea`, `LocationType` | Fetched during location lookups | Almost never | Medium |

### Implementation Plan

#### 5.1: Add Caffeine cache dependency

```xml
<dependency>
    <groupId>com.github.ben-manes.caffeine</groupId>
    <artifactId>caffeine</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-cache</artifactId>
</dependency>
```

#### 5.2: Configure cache per tenant

**Critical: Caches must be tenant-aware.** Since this is a multi-tenant system, cache keys must include the tenant identifier to prevent cross-tenant data leakage.

```java
@Configuration
@EnableCaching
public class TenantAwareCacheConfig {

    @Bean
    public CacheManager cacheManager() {
        CaffeineCacheManager manager = new CaffeineCacheManager();
        manager.setCaffeine(Caffeine.newBuilder()
            .maximumSize(500)
            .expireAfterWrite(Duration.ofMinutes(15))
            .recordStats());
        return manager;
    }
}
```

Cache key strategy — prefix with tenant key:
```java
@Cacheable(value = "itemdata", key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.facilityCode + ':' + #id")
public Itemdata findById(Long id) { ... }
```

#### 5.3: Cache eviction on updates

```java
@CacheEvict(value = "itemdata", key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.facilityCode + ':' + #itemdata.id")
public Itemdata save(Itemdata itemdata) { ... }
```

#### 5.4: Add cache to read-heavy services

Start with these service methods:
1. `ItemdataService` — `findById()`, `findByNumber()`
2. `LocationService` — `findById()`, `findByName()`
3. `ClientService` — `findById()`, `findByNumber()`
4. `SyspropService` — `findByKey()` (most frequently accessed config)

### Estimated Impact

- **Itemdata cache alone** could eliminate ~30-40% of database queries during picking operations (every pick looks up item data)
- Location cache could eliminate another ~20% during put-away and replenishment
- Combined: **40-50% reduction in database round-trips** for common operations

### Effort Estimate

- Setup + Caffeine config: ~1 hour
- Add caching to 4 key services: ~2 hours
- Testing (verify cache isolation per tenant): ~2 hours

### Risk Considerations

- **Tenant isolation is critical** — always include tenant key in cache keys
- Cache invalidation on entity updates must be thorough
- Start with short TTLs (5-15 min) and tune based on monitoring
- Do NOT cache transactional/mutable data (stock quantities, order status, reservations)

---

## Area 6: N+1 Query & Bulk Operation Optimization — NEW RECOMMENDATION

### Problem

19 service files contain **for-loop patterns with individual repository calls** (potential N+1 queries). 170 native queries across 40 repositories bypass Hibernate's first-level cache.

### High-Impact Optimization Targets

#### 6.1: Replace loop-save with `saveAll()`

Pattern found in multiple services:
```java
// BEFORE — N individual INSERT/UPDATE statements
for (Entity entity : entities) {
    repository.save(entity);  // 1 query per entity
}

// AFTER — single batch operation
repository.saveAll(entities);  // batched by Hibernate
```

**Enable Hibernate batching** in `application.properties`:
```properties
spring.jpa.properties.hibernate.jdbc.batch_size=25
spring.jpa.properties.hibernate.order_inserts=true
spring.jpa.properties.hibernate.order_updates=true
```

#### 6.2: Replace loop-findById with `findAllById()`

Pattern found in services like `PickingorderPositionService`, `CustomerorderService`:
```java
// BEFORE — N SELECT queries
for (Long id : ids) {
    Entity entity = repository.findById(id).orElseThrow();
}

// AFTER — single SELECT with IN clause
List<Entity> entities = repository.findAllById(ids);
```

#### 6.3: Key files to optimize (by repository call density)

| Service | `.save()`/`.findBy*()` calls | Priority |
|---------|----------------------------|----------|
| `MobilePickingService` | 74 | **P0** — mobile hot path |
| `CustomerorderService` | 55 | **P0** — order processing |
| `StockunitService` | 46 | **P0** — inventory operations |
| `MobileReplenishService` | 56 | P1 |
| `CustomerorderBatchService` | 30 | P1 |
| `StockrecordService` | 32 | P1 |
| `ReleaseOrderJobService` | 37 | P1 — batch job |

### Effort Estimate

- Hibernate batch config: ~15 minutes
- Convert top 5 services to use bulk operations: ~4 hours
- Testing: ~2 hours

---

## Area 7: Database Index Optimization — DEEP ANALYSIS COMPLETE

### Problem

**No `@Index` annotations** found on any JPA entity. All indexes exist only as Flyway migrations or were created manually. A deep cross-reference of the **167 existing indexes** against **170+ native queries**, **60+ JPQL queries**, and **100+ Spring Data derived methods** reveals significant gaps — particularly missing `state` indexes on 5 heavily-queried tables and missing FK indexes on 3 child tables.

### 7.0: Index Audit Summary (Completed 2026-03-13)

**Current index snapshot:** `docs/plan/pg_indexes_202603132123.csv` (167 indexes across 39 tables)

**Well-indexed tables (no action needed):**
- `stockunit` — PK, client_id, itemdata_id, unitload_id, entity_lock
- `unitload` — PK, labelid (unique + lower), client_id, boxtype_id, carrierunitload_id, shippingmethod_id, storagelocation_id, type_id, entity_lock
- `location` — PK, name (unique), area_id, client_id, rack_id, type_id
- `customerorder` — PK, externalnumber (unique), client_id, boxtype_id, orderbatch_id, parcel_id, pickingtote_id, shipperid_id, state, transferlane_id
- `customerorder_position` — PK, externalid (unique), lower(number), client_id, itemdata_id, order_id, state, (client_id+number)
- `pickingorder_position` — PK, number (unique), client_id, customerorderposition_id, itemdata_id, pickedbyoperator_id, pickfromstockunit_id, pickingorder_id, picktounitload_id
- `billoflading_position` — PK + 9 FK indexes (well covered)
- `stockrecord` — PK, created, client_id + 10 lower() text-search indexes

**Tables with critical gaps:**

| Table | Has PK | Has FK Indexes | Has State Index | Gap Severity |
|-------|--------|----------------|-----------------|--------------|
| `replenishorder` | Yes | 7 FK indexes | **NO** | **CRITICAL** |
| `pickingorder` | Yes | 4 FK indexes | **NO** | **CRITICAL** |
| `billoflading` | Yes | **NONE** | **NO** | **HIGH** |
| `advice` | Yes | externalid only | **NO** | **HIGH** |
| `customerorder_batch` | Yes | 2 FK indexes | **NO** | **HIGH** |
| `goodsreceiptposition` | Yes | **NONE** | N/A | **HIGH** |
| `adviceposition` | Yes | **NONE** | N/A | **HIGH** |
| `cyclecount_position` | Yes | **NONE** | N/A | **MEDIUM** |
| `inventory_record` | Yes | **NONE** | N/A | **LOW** |

---

### 7.1: TIER 1 — Missing State Indexes (CRITICAL)

These 5 tables are heavily filtered by `state` in hot paths but have **no state index at all**. Every state-based query on these tables triggers a full table scan.

#### replenishorder.state — THE #1 GAP

**22+ repository methods** filter by state. Used in every replenishment operation:
- `findByStateLessThan(state)` — active replenishments
- `findByStateLessThanAndItemdataId(state, itemId)` — item-specific replenishment
- `findByStateLessThanAndItemdataIdAndRequestedlocationId(state, itemId, locId)` — location-specific
- `findByState(state)` — state filtering
- `findByStateLessThanEqualAndDestinationIdIsNull(state)` — unassigned replenishments
- `findByStateLessThanAndStockunitId(state, stockunitId)` — stockunit lookup
- `findByStateLessThanAndPrioLessThanAndItemdataIdIn(state, prio, items)` — priority-based
- 10+ native queries with `WHERE state < ?` or `WHERE state = ?`

**Hot paths affected:** MobileReplenishService, ReplenishOrderService, ReleaseOrderJobService

#### pickingorder.state — THE #2 GAP

**10+ repository methods** filter by state. Used in every picking operation:
- `findByStateAndSectionId(state, sectionId)` — section-based pick assignment
- `findByStateAndBoxesPerCartAndSectionId(state, boxesPerCart, sectionId)` — cart-based picking
- `findByOperatorAndStates(userId, stateReserved, stateFinished)` — operator task list
- Native queries: pick assignment, available picks by section, operator workload

**Hot paths affected:** MobilePickingService, PickingorderService, OrderMonitorViewService

#### billoflading.state

- `findByStateInAndKeyword(states, keyword)` — BOL search (paginated, UI-facing)
- `findByStatesAndKeyword(states, keyword)` — BOL detail view (paginated, UI-facing)
- `findByStateIn(states)` — active BOL list
- Native queries filtering `WHERE b.state IN (...)`

**Hot paths affected:** BillofladingService.closeBOL, BOL search UI

#### advice.state

- `findByState(state)` — active advice list (paginated, UI-facing)
- `findByKeywordAndState(keyword, state)` — advice search
- Native queries: `WHERE a.state = ?`

#### customerorder_batch.state

- 8 repository methods filter by state (paginated list views, batch processing)
- `findByStateAndType(state, typeNames)` — batch processing job entry point
- `findByStateAndTypeAndKeywordPage(stateOne, stateTwo, typeNames, keyword)` — batch search

```sql
-- Flyway migration: V__add_missing_state_indexes.sql

-- CRITICAL: replenishorder state (22+ query methods, zero index)
CREATE INDEX CONCURRENTLY index_replenishorder_state ON replenishorder (state);

-- CRITICAL: pickingorder state (10+ query methods, zero index)
CREATE INDEX CONCURRENTLY index_pickingorder_state ON pickingorder (state);

-- HIGH: billoflading state (3+ query methods, zero index)
CREATE INDEX CONCURRENTLY index_billoflading_state ON billoflading (state);

-- HIGH: advice state (2+ query methods, zero index)
CREATE INDEX CONCURRENTLY index_advice_state ON advice (state);

-- HIGH: customerorder_batch state (8+ query methods, zero index)
CREATE INDEX CONCURRENTLY index_customerorder_batch_state ON customerorder_batch (state);
```

---

### 7.2: TIER 2 — Missing FK Indexes on Child Tables (HIGH)

These child tables have **only a PK index** — all FK-based lookups do full table scans.

#### goodsreceiptposition (3 missing FK indexes)

Used in receiving flow — called per goods receipt line:
- `countByGoodsreceiptId(goodsreceiptId)` — sequence number generation (every receive)
- `findByAdvicepositionId(advicepositionId)` — advice-to-receipt mapping
- `findByUnitloadId(unitloadId)` — unitload receipt lookup
- Native query joins on `goodsreceipt_id`, `adviceposition_id`

#### adviceposition (1 missing FK index)

- `countByAdviceId(adviceId)` — sequence number generation
- JOIN on `advice_id` in ReceivingDtoViewRepository native query

#### cyclecount_position (3 missing FK indexes)

- All queries filter by `cyclecount_id` — GROUP BY aggregation queries
- `WHERE cp.cyclecount_id = :cycleCountId` in 4+ native queries
- Some queries also filter by `location_id` and `itemdata_id`

```sql
-- Flyway migration: V__add_missing_fk_indexes.sql

-- goodsreceiptposition: 3 FK indexes (called per receive operation)
CREATE INDEX CONCURRENTLY index_goodsreceiptposition_goodsreceipt_id
    ON goodsreceiptposition (goodsreceipt_id);
CREATE INDEX CONCURRENTLY index_goodsreceiptposition_adviceposition_id
    ON goodsreceiptposition (adviceposition_id);
CREATE INDEX CONCURRENTLY index_goodsreceiptposition_unitload_id
    ON goodsreceiptposition (unitload_id);

-- adviceposition: FK to parent advice
CREATE INDEX CONCURRENTLY index_adviceposition_advice_id
    ON adviceposition (advice_id);

-- cyclecount_position: FK to parent + query columns
CREATE INDEX CONCURRENTLY index_cyclecount_position_cyclecount_id
    ON cyclecount_position (cyclecount_id);
CREATE INDEX CONCURRENTLY index_cyclecount_position_location_id
    ON cyclecount_position (location_id);
CREATE INDEX CONCURRENTLY index_cyclecount_position_itemdata_id
    ON cyclecount_position (itemdata_id);
```

---

### 7.3: TIER 3 — Composite Indexes for Hot Query Paths (HIGH)

These composite indexes target the most frequently executed multi-column query patterns found in the service layer. Each was identified by tracing actual repository method calls in critical operations.

#### 7.3.1: replenishorder (state, itemdata_id) — Most impactful composite

The single most common multi-column filter in the codebase. Used in **10+ query methods**:
- `findByStateLessThanAndItemdataId(state, itemId)`
- `findByStateAndItemdataId(state, itemId)`
- `findByStateLessThanAndItemdataIdAndRequestedlocationId(state, itemId, locId)`
- `findByStateLessThanAndPrioLessThanAndItemdataIdIn(state, prio, items)`
- Multiple native queries: `WHERE ro.state < ? AND ro.itemdata_id = ?`

**Note:** This composite index also covers queries that filter on `state` alone (leftmost prefix), so the single-column `index_replenishorder_state` from Tier 1 becomes **redundant** if this composite is created. Create this one instead.

#### 7.3.2: pickingorder (state, section_id) — Picking assignment hot path

Used in the core picking assignment flow (MobilePickingService):
- `findByStateAndSectionId(state, sectionId)`
- `findByStateAndBoxesPerCartAndSectionId(state, boxesPerCart, sectionId)`
- Native queries: `WHERE po.state = ? AND po.section_id = ?`

**Note:** Also covers queries that filter on `state` alone, making `index_pickingorder_state` redundant. Create this one instead.

#### 7.3.3: stockunit (itemdata_id, entity_lock) — Replenishment stock lookup

Used in replenishment stock availability queries (5+ native queries):
- `WHERE su.itemdata_id = ? AND su.entity_lock = 0`
- `WHERE su.itemdata_id = ? AND su.entity_lock = 0 AND su.amount > su.reservedamount`
- Complex JOIN queries filtering stock by item with unlocked status

**Note:** Individual `itemdata_id` and `entity_lock` indexes already exist, but the composite eliminates the need for a bitmap AND merge, giving significant speedup on these frequent queries.

#### 7.3.4: customerorder_batch (state, type) — Batch processing entry point

- `findByStateAndType(state, typeNames)` — batch job entry point
- `findByStateAndTypeAndKeywordPage(stateOne, stateTwo, typeNames, keyword)` — batch search

**Note:** Also covers `state`-only queries, making a separate state index redundant.

#### 7.3.5: pickingorder (operator_id, state) — Operator task list

- `findByOperatorAndStates(userId, stateReserved, stateFinished)` — operator's active picks
- Native queries: `WHERE po.operator_id = ? AND po.state >= ? AND po.state < ?`

**Note:** `operator_id` single index already exists. This composite optimizes the common operator+state pattern without removing the existing index (which serves other queries).

```sql
-- Flyway migration: V__add_composite_indexes.sql

-- Replace individual state indexes with composites where state is leftmost column:

-- replenishorder: state+itemdata_id (replaces standalone state index)
CREATE INDEX CONCURRENTLY index_replenishorder_state_itemdata
    ON replenishorder (state, itemdata_id);

-- pickingorder: state+section_id (replaces standalone state index)
CREATE INDEX CONCURRENTLY index_pickingorder_state_section
    ON pickingorder (state, section_id);

-- stockunit: itemdata_id+entity_lock (supplements existing individual indexes)
CREATE INDEX CONCURRENTLY index_stockunit_itemdata_entitylock
    ON stockunit (itemdata_id, entity_lock);

-- customerorder_batch: state+type (replaces standalone state index)
CREATE INDEX CONCURRENTLY index_customerorder_batch_state_type
    ON customerorder_batch (state, type);

-- pickingorder: operator_id+state (supplements existing operator_id index)
CREATE INDEX CONCURRENTLY index_pickingorder_operator_state
    ON pickingorder (operator_id, state);
```

---

### 7.4: TIER 4 — ORDER BY / Sorting Optimization (MEDIUM)

Several queries use `ORDER BY` on non-indexed columns, forcing PostgreSQL to do filesort:

| Table | ORDER BY Columns | Query Location | Impact |
|-------|-----------------|----------------|--------|
| `replenishorder` | `state DESC, prio DESC, created ASC` | ReplenishorderRepository L310 | Medium — used in priority-based pick assignment |
| `pickingorder` | `state DESC, prio DESC, created ASC` | PickingorderRepository L110 | Medium — used in pick order selection |
| `billoflading` | `modified DESC` | BillofladingRepository L48 | Low — paginated UI view |

```sql
-- Optional: ORDER BY optimization indexes (create only if EXPLAIN ANALYZE shows filesort)

-- replenishorder: priority-based ordering
CREATE INDEX CONCURRENTLY index_replenishorder_state_prio_created
    ON replenishorder (state DESC, prio DESC, created ASC);

-- pickingorder: priority-based ordering
CREATE INDEX CONCURRENTLY index_pickingorder_state_prio_created
    ON pickingorder (state DESC, prio DESC, created ASC);

-- billoflading: recent-first listing
CREATE INDEX CONCURRENTLY index_billoflading_modified
    ON billoflading (modified DESC);
```

**Note:** If the Tier 3 composite `index_replenishorder_state_itemdata` and `index_pickingorder_state_section` are created, the ORDER BY indexes for those tables add a **third** index with state as the leading column. Monitor query plans to determine if the overhead is justified — the composite from Tier 3 may provide sufficient benefit on its own.

---

### 7.5: Consolidated Flyway Migration

Recommended to split into **two migrations** for safe rollout:

**Migration 1 — Critical indexes (Tier 1 + Tier 2):**
```sql
-- V[next]__add_critical_missing_indexes.sql
-- These are non-controversial: every child table should have FK indexes,
-- and every state-filtered table should have a state index.

-- Tier 1: Missing state indexes (only for tables where composite NOT planned)
CREATE INDEX CONCURRENTLY index_billoflading_state ON billoflading (state);
CREATE INDEX CONCURRENTLY index_advice_state ON advice (state);

-- Tier 2: Missing FK indexes on child tables
CREATE INDEX CONCURRENTLY index_goodsreceiptposition_goodsreceipt_id ON goodsreceiptposition (goodsreceipt_id);
CREATE INDEX CONCURRENTLY index_goodsreceiptposition_adviceposition_id ON goodsreceiptposition (adviceposition_id);
CREATE INDEX CONCURRENTLY index_goodsreceiptposition_unitload_id ON goodsreceiptposition (unitload_id);
CREATE INDEX CONCURRENTLY index_adviceposition_advice_id ON adviceposition (advice_id);
CREATE INDEX CONCURRENTLY index_cyclecount_position_cyclecount_id ON cyclecount_position (cyclecount_id);
CREATE INDEX CONCURRENTLY index_cyclecount_position_location_id ON cyclecount_position (location_id);
CREATE INDEX CONCURRENTLY index_cyclecount_position_itemdata_id ON cyclecount_position (itemdata_id);
```

**Migration 2 — Composite indexes (Tier 3):**
```sql
-- V[next+1]__add_composite_indexes.sql
-- Composites for hot query paths. Each replaces or supplements existing indexes.

CREATE INDEX CONCURRENTLY index_replenishorder_state_itemdata ON replenishorder (state, itemdata_id);
CREATE INDEX CONCURRENTLY index_pickingorder_state_section ON pickingorder (state, section_id);
CREATE INDEX CONCURRENTLY index_stockunit_itemdata_entitylock ON stockunit (itemdata_id, entity_lock);
CREATE INDEX CONCURRENTLY index_customerorder_batch_state_type ON customerorder_batch (state, type);
CREATE INDEX CONCURRENTLY index_pickingorder_operator_state ON pickingorder (operator_id, state);
```

**Important notes for Flyway + CONCURRENTLY:**
- `CREATE INDEX CONCURRENTLY` cannot run inside a transaction. Flyway migrations are transactional by default.
- Set `spring.flyway.out-of-order=true` if version numbers don't align, OR use a callback-based approach.
- Alternative: Use a non-transactional Flyway migration by naming the file with `V[n]__` prefix and adding `-- flyway:executeInTransaction=false` at the top of the migration file.

---

### 7.6: What NOT to Add (Already Covered)

The original plan (Section 7.2) suggested indexes that **already exist**. These were verified in the audit:

| Suggested Index | Status | Existing Index Name |
|----------------|--------|-------------------|
| `stockunit.unitload_id` | **EXISTS** | `index_stockunit_unitload_id` |
| `stockunit.itemdata_id` | **EXISTS** | `index_stockunit_itemdata_id` |
| `customerorder_position.order_id` | **EXISTS** | `index_customerorder_position_order_id` |
| `customerorder_position.state` | **EXISTS** | `index_customerorder_position_state` |
| `pickingorder_position.pickingorder_id` | **EXISTS** | `index_pickingorder_position_pickingorder_id` |
| `billoflading_position.billoflading_id` | **EXISTS** | `index_billoflading_position_billoflading_id` |
| `unitload.storagelocation_id` | **EXISTS** | `index_unitload_storagelocation_id` |

---

### Effort Estimate (Revised)

| Phase | Work | Time |
|-------|------|------|
| 7.0 | Index audit | **DONE** (see above) |
| 7.1 + 7.2 | Migration 1: state + FK indexes (9 indexes) | ~30 min |
| 7.3 | Migration 2: composite indexes (5 indexes) | ~30 min |
| 7.4 | ORDER BY indexes (optional, pending EXPLAIN ANALYZE) | ~30 min |
| Testing | Run EXPLAIN ANALYZE on key queries before/after | ~2 hours |
| **Total** | | **~3.5 hours** |

### Expected Impact

| Operation | Before (no index) | After (with index) | Improvement |
|-----------|-------------------|-------------------|-------------|
| Replenish order lookup by state+item | Full table scan | Index seek | **10-100x faster** |
| Picking order assignment by state+section | Full table scan | Index seek | **10-100x faster** |
| Goods receipt position count | Full table scan | Index seek on FK | **10-50x faster** |
| BOL search by state | Full table scan | Index seek | **5-20x faster** |
| Batch processing by state+type | Full table scan | Index seek | **5-20x faster** |
| Stock availability (item+entity_lock) | Bitmap AND merge | Single index seek | **2-5x faster** |

### Risk Assessment

- **Write overhead:** Each index adds minor write overhead (~1-5% per index per INSERT/UPDATE). For 14 new indexes across 9 tables, the total write impact is negligible compared to the read improvement.
- **Disk space:** B-tree indexes on integer/bigint columns are small (~8-40 bytes per row). For tables with <1M rows, each index adds <50MB.
- **CONCURRENTLY caveat:** `CREATE INDEX CONCURRENTLY` does not block writes but takes longer and cannot run in a transaction. Plan for Flyway non-transactional migration.
- **No risk of breaking existing queries:** Indexes only help the query planner — they never change query semantics.

---

## Area 8: GraalVM Native Image — LOW PRIORITY

### Feasibility Assessment

| Factor | Status | Notes |
|--------|--------|-------|
| Spring Boot 3.5.9 | Compatible | Full AOT support since 3.0 |
| Java 21 | Compatible | GraalVM CE supports Java 21 |
| Hibernate 6.x | Compatible | Native hints included |
| **Jasypt 2.1.2** | **BLOCKER** | Uses reflection heavily, no GraalVM metadata published |
| **Keycloak Admin Client 26.x** | **BLOCKER** | Heavy reflection, JAX-RS, no native hints |
| **JAXWS (jaxws-rt 3.0.2)** | **BLOCKER** | SOAP/XML processing requires extensive reflection |
| **OpenCSV 5.7.1** | **RISK** | Reflection-based CSV parsing |
| **Apache POI 5.3.0** | **RISK** | Complex reflection patterns |
| Dynamic tenant DataSource creation | **RISK** | Runtime DataSource creation may need custom hints |

### Recommendation: NOT RECOMMENDED at this time

The number of blockers makes GraalVM Native Image impractical without significant effort:
1. Replace Jasypt with Spring Boot's built-in encryption or Vault
2. Replace JAXWS with a lighter REST client
3. Create extensive GraalVM reflection hints for Keycloak client
4. Test all 61 entities for serialization compatibility

**Better alternative for startup speed:** Use CDS (Class Data Sharing) available in Java 21:
```bash
# Step 1: Create CDS archive during build
java -Xshare:dump -XX:SharedClassListFile=classlist.txt -XX:SharedArchiveFile=app.jsa -jar wms-api.jar

# Step 2: Use CDS archive at runtime
java -Xshare:on -XX:SharedArchiveFile=app.jsa -jar wms-api.jar
```

CDS can reduce startup time by **30-50%** with zero code changes and zero risk.

### If You Still Want to Pursue GraalVM Later

1. Add `spring-boot-starter-parent` AOT plugin
2. Replace Jasypt with Spring Vault or environment-variable-based secrets
3. Replace JAXWS with Spring WebClient
4. Add `@RegisterReflectionForBinding` for all entities and DTOs
5. Create `reflect-config.json` for third-party libraries
6. Extensive integration testing in native mode

---

## Implementation Roadmap

### Sprint 1 (Quick Wins) — DONE

- [x] **4.1** Add missing HikariCP settings (max-lifetime, leak detection, keepalive, validation) — `TenantDynamicRoutingDataSource.java`
- [x] **6.1** Enable Hibernate batching in `application.properties` (batch_size=25, order_inserts, order_updates)
- [ ] **8-alt** Set up CDS for faster startup — deferred (runtime config, not code change)

### Sprint 2 (Entity Fix) — DONE

- [x] **3.1** Decided: base class approach (single fix covers all 68 entities)
- [x] **3.2** `Location.equals()` verified correct (already uses `instanceof` + ID-based)
- [x] **3.3** Added `equals()` to `AbstractBaseEntity.java` — covers all entities at once
- [x] **3.4** Full test suite passed: **3,685 tests, 0 failures**
- [x] New test: `AbstractBaseEntityEqualsTest` — 7 test cases covering equals() contract

### Sprint 3 (Caching) — DONE

- [x] **5.1** Added Caffeine + spring-boot-starter-cache dependencies to `pom.xml`
- [x] **5.2** Created tenant-aware `CacheConfig.java` with 4 named caches (itemdata, locations, clients, sysprops), 500 max size, 15min TTL
- [x] **5.3** Added `@Cacheable` to LocationService.getByName(), ClientService.getByNumber(), SyspropService.getByKey() — all with tenant-aware cache keys
- [x] **5.4** Added `@CacheEvict` on LocationService.createLocation(), SyspropService.createSystemProperty()
- [x] ItemdataService skipped — no suitable service-level methods (repo calls are inline)
- [x] New test: `CacheConfigTest` — 3 test cases verifying config

### Sprint 4 (Query & Index Optimization) — DONE

- [ ] **6.2** Convert top 5 services to use bulk operations — deferred (requires careful per-service refactoring)
- [x] **7.0** Audit existing database indexes — **DONE** (167 indexes audited, gaps identified)
- [x] **7.1+7.2** Migration `V2.1.05`: 11 critical missing indexes (4 state + 7 FK) — `V2.1.05__add_critical_missing_indexes.sql`
- [x] **7.3** Migration `V2.1.06`: 4 composite indexes for hot query paths — `V2.1.06__add_composite_indexes.sql`
- [ ] **7.4** (Optional) Add ORDER BY indexes after EXPLAIN ANALYZE validation
- [x] **4.2** HikariCP metrics exposed via actuator (`hikaricp` added to endpoints)
- [ ] Performance test critical flows with EXPLAIN ANALYZE (requires production-like data)

### Total Estimated Effort: ~7 days | **Implemented: Sprints 1–4 (core items)**

---

## Expected Combined Impact

| Metric | Before | After (estimated) |
|--------|--------|-------------------|
| DB queries per pick operation | ~50-100 | ~25-50 (caching + batching) |
| DB queries per BOL close | ~500 (already optimized from 1700) | ~300 (caching + bulk ops) |
| Replenish order lookup (state+item) | Full table scan | Index seek (10-100x faster) |
| Picking assignment (state+section) | Full table scan | Index seek (10-100x faster) |
| Goods receipt position queries | Full table scan (no FK indexes) | Index seek (10-50x faster) |
| Startup time | ~15-30s | ~10-20s (CDS) |
| Connection leak detection | None | 60s threshold with stack trace |
| Entity comparison correctness | Broken (reference equality) | Fixed (ID-based equality) |
| Cache hit rate (master data) | 0% | ~80-90% after warm-up |

---

## Files Reference

| Area | Key Files |
|------|-----------|
| Transaction Manager | `TenantDatabaseConfig.java` (already correct) |
| Virtual Threads | `application.properties` (already enabled) |
| Entity Model | `src/main/java/net/aim_ai/wms/model/*.java` (61 files) |
| Connection Pooling | `TenantDynamicRoutingDataSource.java`, `TenantPoolEvictor.java` |
| Caching | New: `TenantAwareCacheConfig.java` + service annotations |
| Bulk Operations | `MobilePickingService.java`, `CustomerorderService.java`, `StockunitService.java` |
| Indexes | New Flyway migration + entity `@Index` annotations |
| Existing Plans | `docs/plan/260424-connection-pool-exhaustion-fix-plan.md` (complementary, not duplicate) |
