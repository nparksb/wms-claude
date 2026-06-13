# WMS API: Problem Areas Analysis & Architectural Refactoring Plan

**Date:** 2026-04-03
**Status:** Analysis Complete — Awaiting Review
**Scope:** Synthesized from 50+ bug fix plans, analysis docs, and migration assessments in `docs/`

---

## 1. Problem Areas Ranked by Frequency & Severity

Based on analysis of all completed, active, and pending plans, the following problem categories are ranked from most to least impactful:

### Tier 1: Critical / Systemic (Address First)

#### 1.1 Concurrency & Optimistic Locking (14 issues)

The single largest category. Nearly every major subsystem has been affected.

| Plan | Issue | Root Cause |
|------|-------|------------|
| CONCURRENCY_FIX_PLAN | 270 `.save()` calls with zero concurrency protection | No `OptimisticLockException` handling anywhere |
| connection-pool-exhaustion-fix-plan | HikariCP pool maxed out at 25 connections | Pessimistic locks hold connections during blocking HTTP calls |
| 260331-cron-job-autoflush-optimistic-lock | Scheduled jobs crash on stale entities | Hibernate auto-flush of detached entities |
| 260331-recalculate-orders-stale-entity | Recalculate orders fails with stale version | L1 cache serves stale entity after `findByIdForUpdate` |
| 260401-order-release-optimistic-lock | Order release job crashes intermittently | Detached entities re-attached with wrong version |
| 260401-replenish-stockunit-optimistic-lock | Replenish job fails on stock unit update | `entityManager.refresh()` missing after `findByIdForUpdate` |
| OSIV_MERGE_PICKING_ORDERS_BUG_FIX | Merge picking orders uses detached entities | Mutations on detached list items vs managed entities |
| WMS_V2_Horizontal_Scaling_Concurrency_Report | Multiple scaling blockers identified | Advisory locks, thread-local tenant context, in-memory caches |
| Reservation_Leak_Analysis | Reserved amounts leak on failed operations | No rollback of reservations on exception paths |
| Reservation_Leak_Fix_Plan | 5 distinct reservation leak bugs | Missing cleanup in catch/finally blocks |
| WMS_OSIV_Disabled_Audit | OSIV disabled broke implicit dirty-checking | Services relied on OSIV for transparent saves |
| v1-0ecc20e (mergePickingOrders) | Detached entity mutation in merge loop | Using caller's list entity instead of managed entity |
| v1-198c86a-b04066c | Hibernate bytea type mismatch on null param | COALESCE with null bound as bytea vs numeric |
| bug-report-replenishment-poison-pill | Single FLA failure aborts entire refill loop | No per-item error isolation in transaction |

**Pattern:** The codebase systematically confuses managed vs detached entities, lacks `OptimisticLockException` retry strategies, and holds database connections during external HTTP calls.

#### 1.2 Null Safety & Defensive Coding (8 issues)

| Plan | Issue | Root Cause |
|------|-------|------------|
| Cancel_Order_Null_SectionId_And_Early_Return_Fix | NPE when client has no section | Chained `.get()` calls without null checks |
| nullpointexception-on-orderbatchservice | NPE in CustomerorderBatchService | Null entity reference in batch processing |
| Cancel_Club_Parcels_Packed_State_Fix | NPE on cancel when parcel state is packed | Missing state guard before entity access |
| Club_Order_Cancellation_Fix_Plan | NPE in club order cancel flow | `.get()` on Optional without `.isPresent()` check |
| Club_Order_Cancellation_OMS_Fix | NPE when notifying OMS of cancellation | Null URL or null entity in notification path |
| Order_241019_Cancellation_Fix | Race condition + NPE in confirmPick | Concurrent pick confirmation creates null references |
| picking-notification-drop | OMS notifications silently dropped | Null URL or anonymous user in notification context |
| WMS_OMS_Picking_Notification_Bug_Analysis | Picking notifications lost | Null checks missing in notification pipeline |

**Pattern:** Pervasive use of `.get()` on `Optional` and `findById()` without null guards. The codebase was written assuming data always exists, which fails at runtime with real-world data inconsistencies.

### Tier 2: High Impact / Recurring

#### 1.3 Performance — N+1 Queries & Batch Processing (7 issues)

| Plan | Issue | Root Cause |
|------|-------|------------|
| CLUB_ORDER_PROCESSING_PERFORMANCE | 5,000+ queries for 50-order batch | Cascading N+1 in nested loops |
| PICKING_PERFORMANCE_PLAN | Excessive queries during pick assignment | Per-item `findById` in loops |
| RECEIVING_PERFORMANCE_PLAN | Slow receiving for large shipments | Individual saves instead of batch |
| REPLENISHMENT_PERFORMANCE_PLAN | Replenishment job timeout | N+1 across FLA processing |
| TRANSFER_ORDER_PERFORMANCE_PLAN | 12N queries for N stock units | Triple-nested `findById` in stream filters |
| CLOSE_BOL_FURTHER_IMPROVEMENTS | 1,700 queries in closeBOL() | Cascading N+1 across finish/transfer |
| ENTITY_PERSISTENCE_IMPROVEMENT | Redundant saves and re-fetches | No batch fetch, no `@EntityGraph` |

**Pattern:** Services fetch entities one-by-one inside loops. No use of batch fetching, `@EntityGraph`, or `IN` clause queries. The `findById` pattern inside `forEach`/`stream` is the #1 performance anti-pattern.

#### 1.4 Transaction Management (4 issues)

| Plan | Issue | Root Cause |
|------|-------|------------|
| TRANSACTION_MANAGER_FIX_PLAN | 44 `@Transactional` annotations using wrong TM | Bare `@Transactional` defaults to landlord (master) DB |
| connection-pool-exhaustion | HTTP calls inside transactions | `@Transactional` scope too wide |
| WMS_OSIV_Disabled_Audit | Dirty-checking broke after OSIV disabled | Services assumed open session for implicit flushes |
| 260331-cron-job-autoflush-optimistic-lock | Auto-flush in wrong transaction scope | Cron jobs sharing transaction boundaries incorrectly |

**Pattern:** Dual transaction manager architecture (landlord vs tenant) is error-prone. A bare `@Transactional` silently uses the wrong database.

#### 1.5 Integration / OMS Communication (5 issues)

| Plan | Issue | Root Cause |
|------|-------|------------|
| picking-oms-status-race-condition-fix | Status 24 overwrites status 25 | Two OMS notifications sent in wrong order |
| oms-palletized-loaded-to-truck-notifications | Missing lifecycle notifications | No events for palletize/truck-load stages |
| WMS_OMS_Picking_Notification_Bug_Analysis | Notifications silently lost | Null URL, anonymous user fallback |
| picking-notification-drop | Notifications dropped without error | Silent failure in HTTP call |
| Club_Order_Cancellation_OMS_Fix | OMS not notified of club cancellation | Missing integration for cancel path |

**Pattern:** OMS notifications are fire-and-forget with no retry, no dead-letter queue, no ordering guarantee. Failures are silent.

### Tier 3: Medium Impact

#### 1.6 Order Cancellation Logic (5 issues)

| Plan | Issue |
|------|-------|
| Order_241019_Cancellation_Fix | confirmPick race condition during cancel |
| Cancel_Order_Null_SectionId_And_Early_Return_Fix | NPE + missing early return in cancel path |
| Cancel_Club_Parcels_Packed_State_Fix | Packed parcels not handled in cancel |
| Club_Order_Cancellation_Fix_Plan | Club order cancel missing multiple guards |
| RunClubLine_Cancelled_Order_Fix_Plan | Partially cancelled orders crash club line |

**Pattern:** The cancellation flow touches many subsystems (picking, stock, unitload, OMS) and each subsystem was hardened independently rather than having a centralized cancel orchestrator.

#### 1.7 Data Integrity / Entity Lifecycle (5 issues)

| Plan | Issue |
|------|-------|
| ENTITY_COMPARISON_FIX_PLAN | Entities used as HashMap keys lack `hashCode`/`equals` |
| ENTITY_PERSISTENCE_IMPROVEMENT | Redundant saves, missing cascade |
| Reserved_Amount_Adjustment_Fix | Reserved amounts drift from actual |
| Transfer_Error_Fix | Transfer not appearing in outbound screen |
| RECEIVING_QUANTITIES_FIX | Received quantities not updating correctly |

#### 1.8 Operational / Infrastructure (5 issues)

| Plan | Issue |
|------|-------|
| UTC-TIMEZONE-MIGRATION | Timestamps stored in local time, DST-fragile |
| WMS_V2_Horizontal_Scaling_Concurrency_Report | Cannot scale horizontally |
| cache-config-improvement-plan | Cache eviction not thread-safe |
| CUPS_DEPENDENCY_REMOVAL | Custom bundled JAR instead of Maven artifact |
| SWAGGER_API_DOCS_FIX | API docs not working post-migration |

### Tier 4: Lower Priority

#### 1.9 Code Quality / Test Coverage (4 issues)

| Plan | Issue |
|------|-------|
| CODE_COVERAGE_PLAN | Coverage at 37.4%, target >80% |
| TEST-COVERAGE-IMPROVEMENT-PLAN | Phased coverage improvement |
| SERVICE_COVERAGE_PLAN | Service layer at 65%, now 86% |
| LEGACY_TEST_MIGRATION_PLAN | Old test patterns need modernization |

#### 1.10 Feature Gaps / V1 Parity (4 issues)

| Plan | Issue |
|------|-------|
| Location_CRUD_Porting_Plan | Location CRUD missing in V2 |
| Develop_Arden_Migration_Gap_Analysis | V1 features not yet in V2 |
| Auto_Release_Club_Transfer_Lane_Fix | Auto-release logic missing |
| ORDER_LOADED_TO_TRUCK_DASHBOARD_PLAN | Dashboard column not propagated |

---

## 2. Root Cause Pattern Summary

| # | Root Cause Pattern | Occurrences | Severity |
|---|-------------------|-------------|----------|
| 1 | Detached/stale entity mutation (L1 cache, missing refresh) | 9 | Critical |
| 2 | `.get()` on Optional without null guard | 8 | High |
| 3 | N+1 queries in loops (`findById` inside `forEach`) | 7 | High |
| 4 | Wrong or missing transaction manager specification | 4 | Critical |
| 5 | Silent failure in external HTTP calls (OMS) | 5 | High |
| 6 | No retry/isolation for optimistic lock exceptions | 5 | High |
| 7 | Connection held during blocking I/O | 2 | Critical |
| 8 | Missing state guards before entity operations | 5 | Medium |
| 9 | No cancellation orchestrator (scattered logic) | 5 | Medium |
| 10 | Timestamps in local time, not UTC | 1 | Medium |

---

## 3. Architectural Refactoring Recommendations

### 3.1 Introduce a Resilient Entity Access Layer

**Problem:** Detached entities, stale L1 cache, missing null checks
**Addresses:** Root causes #1, #2

#### Option A: Entity Accessor Service (Recommended)
Create a thin `EntityAccessService` that wraps all `findById` calls with:
- `orElseThrow` with meaningful `EntityNotFoundException`
- Optional `entityManager.refresh()` after pessimistic lock queries
- Centralized logging for entity access failures

```java
@Service
public class EntityAccessService {
    public <T> T findOrThrow(JpaRepository<T, Long> repo, Long id, String entityName) {
        return repo.findById(id)
            .orElseThrow(() -> new EntityNotFoundException(entityName, id));
    }
    
    public <T> T findForUpdateAndRefresh(JpaRepository<T, Long> repo, Long id, String entityName) {
        T entity = findOrThrow(repo, id, entityName);
        entityManager.refresh(entity);
        return entity;
    }
}
```

**Effort:** Medium (gradual migration, service by service)
**Risk:** Low (additive, no behavioral change)

#### Option B: Custom Repository Base Class
Extend `SimpleJpaRepository` with null-safe and refresh-aware methods built-in.

**Effort:** High (requires repository infrastructure changes)
**Risk:** Medium (affects all repositories at once)

---

### 3.2 Optimistic Lock Retry Framework

**Problem:** `ObjectOptimisticLockingFailureException` crashes operations instead of retrying
**Addresses:** Root causes #1, #6

#### Option A: Leverage Existing `OptimisticLockRetry` Utility (Recommended)
The codebase already has `OptimisticLockRetry` (`src/main/java/net/aim_ai/wms/util/OptimisticLockRetry.java`). Expand its usage to all critical service methods:
- Scheduled jobs (`ReplenishOrderJob`, `OrderReleaseJob`)
- Stock operations (`changeReservedAmount`, `transferStock`)
- Order state transitions

**Effort:** Low-Medium (wrap existing methods)
**Risk:** Low (utility already tested)

#### Option B: Spring Retry with `@Retryable`
Add `spring-retry` dependency and annotate critical methods:

```java
@Retryable(value = ObjectOptimisticLockingFailureException.class, maxAttempts = 3, backoff = @Backoff(delay = 100))
@Transactional(value = "tenantTransactionManager")
public void releaseOrder(Long orderId) { ... }
```

**Effort:** Low (annotation-based)
**Risk:** Low-Medium (must ensure fresh transaction on each retry)

---

### 3.3 Async OMS Notification Pipeline

**Problem:** Synchronous HTTP calls to OMS inside transactions, silent failures, no ordering
**Addresses:** Root causes #5, #7

#### Option A: Transactional Outbox Pattern (Recommended)
1. Write notifications to a `notification_outbox` table inside the same transaction
2. A separate scheduled job polls the outbox and sends HTTP calls outside any transaction
3. Failed sends are retried with exponential backoff
4. Ordering is preserved via sequence numbers

**Effort:** High (new table, new job, refactor all ManageOrderService calls)
**Risk:** Low (decouples transaction from I/O completely)

#### Option B: @TransactionalEventListener + Async
Use Spring's `@TransactionalEventListener(phase = AFTER_COMMIT)` to fire OMS calls only after the transaction commits, in an async thread pool.

**Effort:** Medium (event-based refactor of ManageOrderService)
**Risk:** Medium (still fire-and-forget unless combined with retry)

#### Option C: Message Queue (RabbitMQ/Kafka)
Route all OMS notifications through a message broker with guaranteed delivery.

**Effort:** Very High (infrastructure change)
**Risk:** Low (production-grade reliability) but requires ops investment

---

### 3.4 Batch Fetch Strategy for N+1 Elimination

**Problem:** `findById` inside loops generates O(N) queries
**Addresses:** Root cause #3

#### Option A: Bulk Pre-Fetch Pattern (Recommended)
Already successfully applied in `PickingOrderMergeService` and `closeBOL()`:

```java
// Collect IDs first
Set<Long> itemIds = orders.stream().map(Order::getItemId).collect(toSet());
// Bulk fetch
Map<Long, Item> itemMap = itemRepo.findAllById(itemIds).stream()
    .collect(toMap(Item::getId, Function.identity()));
// Use map in loop
orders.forEach(o -> { Item item = itemMap.get(o.getItemId()); ... });
```

Apply this pattern systematically to:
- `ReleaseOrderJobService.releaseOrder()`
- `CustomerorderBatchService.runClubLine()`
- `TransferOrderService.updateOrderPositionPickSources()`
- `ReplenishOrderJob.refillFixedLocations()`

**Effort:** Medium (per-method refactor)
**Risk:** Low (proven pattern in this codebase)

#### Option B: Hibernate `@BatchSize` / `@Fetch(FetchMode.SUBSELECT)`
Configure entity-level batch fetching to automatically batch lazy loads.

**Effort:** Low (annotation changes)
**Risk:** Medium (global behavior change, may over-fetch)

---

### 3.5 Order Cancellation Orchestrator

**Problem:** Cancel logic scattered across 5+ services with inconsistent guards
**Addresses:** Root cause #9

#### Option A: Centralized `OrderCancellationService` (Recommended)
Extract all cancellation logic into a single service:

```java
@Service
public class OrderCancellationService {
    public CancelResult cancelOrder(Long orderId) {
        // 1. Validate state preconditions
        // 2. Cancel picking orders (if any)
        // 3. Release reservations
        // 4. Update order/position states
        // 5. Handle tote cleanup (rapid picking)
        // 6. Notify OMS
        // All in one transaction with proper error handling
    }
}
```

**Effort:** High (significant refactor)
**Risk:** Medium (consolidating scattered logic)

#### Option B: State Machine
Implement a formal state machine (Spring Statemachine or custom) for order lifecycle, with cancel as a defined transition.

**Effort:** Very High
**Risk:** High (architectural shift)

---

### 3.6 Transaction Safety Enforcement

**Problem:** Bare `@Transactional` silently uses wrong transaction manager
**Addresses:** Root cause #4

#### Option A: Custom Annotation + ArchUnit Test (Recommended)

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Transactional(value = "tenantTransactionManager")
public @interface TenantTransactional {
    // inherits rollbackFor, readOnly, propagation from @Transactional
}
```

Plus an ArchUnit test:
```java
@ArchTest
void noBareTenantTransactional = methods()
    .that().areDeclaredInClassesThat().resideInPackage("..service..")
    .and().areAnnotatedWith(Transactional.class)
    .should().beAnnotatedWith(TenantTransactional.class);
```

**Effort:** Low (create annotation + test, gradual adoption)
**Risk:** Low (compile-time enforcement)

#### Option B: Make `tenantTransactionManager` `@Primary`
Swap which TM is primary so bare `@Transactional` defaults to tenant.

**Effort:** Very Low
**Risk:** High (breaks landlord service operations)

---

---

## 4. Horizontal Scaling & Multi-Tenant Scalability Analysis

### 4.1 Current Architecture Assessment

The WMS API uses a **shared-nothing, JVM-local** architecture. Each instance is fully self-contained after a single startup query to the landlord (master) database. This design is fundamentally sound for horizontal scaling but has several gaps that prevent safe multi-replica deployment today.

**What already works for horizontal scaling:**
- Database-per-tenant isolation (each warehouse gets its own PostgreSQL database)
- `@Version` optimistic locking on all 44 entities via `AbstractBaseEntity`
- Pessimistic locks (`SELECT FOR UPDATE`) on critical repositories (Stockunit, Pickingorder, Unitload, BOL, etc.)
- `OptimisticLockRetry` utility used in pick confirmation, unitload operations, and palletizing (3 call sites). Not yet adopted in replenishment, order release, or stock services
- PostgreSQL advisory locks on all 5 scheduled jobs via `AdvisoryLockService`
- `app.cron=true` flag gates business jobs to a designated single replica
- `TenantPoolEvictor` runs on all replicas (infrastructure scheduling separated from business scheduling)
- Global lock exception handlers in `RestExceptionHandler` (HTTP 409 for concurrency failures)

**What was already fixed in Phase 1-2 of the Horizontal Scaling Report:**
- `changeAmount()` now uses `findByIdForUpdate` + `@Transactional`
- `KeycloakService.userCache` replaced with thread-safe Caffeine
- Caffeine TTLs reduced to 5 minutes
- `TenantContext.clear()` added to `SchedulingConfiguration`
- `@EnableScheduling` extracted to unconditional config (so `TenantPoolEvictor` runs on all replicas)
- Pessimistic lock on sequence table (replaced optimistic retry storms)
- `pg_try_advisory_lock` on all 5 scheduled jobs
- Silent `-1` return fixed in `BasicService.getNextSequenceNumber()`

### 4.2 Remaining Horizontal Scaling Blockers

#### 4.2.1 JVM-Local Caches — Cross-Replica Staleness (CRITICAL)

The #1 blocker for true round-robin load balancing. `@CacheEvict` only clears the local replica's cache.

| Cache | Location | TTL | Risk |
|-------|----------|-----|------|
| `sysprops` | `CacheConfig.java:24` | 5 min | Feature flags, job configs stale across replicas |
| `clients` | `CacheConfig.java:25` | 5 min | Client config changes invisible to other replicas |
| `locations` | `CacheConfig.java:26` | 5 min | Location updates stale |
| `itemdata` | `CacheConfig.java:27` | 5 min | SKU changes invisible; `@CacheEvict(allEntries=true)` flushes ALL tenants |
| `userCache` | `KeycloakService.java:60` | **15 min** | Disabled user continues operating on stale-cache replica (security) |

**Cross-tenant over-eviction bug:** `ItemdataService.java:56` uses `@CacheEvict(value="itemdata", allEntries=true)` which flushes ALL tenants' cached items when any single tenant modifies an item. With 20 tenants, a single SKU update clears 3,000 cached entries for all tenants.

#### 4.2.2 Tenant Config Caches — No Runtime Refresh (HIGH)

| Cache | Location | Loaded | Refreshed |
|-------|----------|--------|-----------|
| `TenantDbConfigCache` | `TenantDbConfigCache.java:20` | Once at startup | Never |
| `TenantAuthConfigCache` | `TenantAuthConfigCache.java:16` | Once at startup | Never |
| `MultiTenantJwtDecoder` | `MultiTenantJwtDecoder.java:25` | Lazy, never evicted | Never |
| `MultiTenantKeycloakService` | `MultiTenantKeycloakService.java:27` | Lazy, never evicted | Never |

**Impact:** Adding a new tenant, rotating DB credentials, or updating Keycloak config requires restarting ALL running instances. No hot-reload capability.

#### 4.2.3 Connection Pool Multiplication (HIGH)

Each replica creates its own HikariCP pools per tenant (`TenantDynamicRoutingDataSource.java:50`):

```
Total connections = N_replicas × T_active_tenants × maxPoolSize
```

| Replicas | Tenants | maxPoolSize | Total Connections | PostgreSQL Default |
|----------|---------|-------------|-------------------|--------------------|
| 1 | 5 | 5 | 25 | 100 |
| 3 | 5 | 5 | 75 | 100 |
| 3 | 20 | 5 | 300 | 100 (EXHAUSTED) |
| 5 | 20 | 3 | 300 | 100 (EXHAUSTED) |

The `TenantPoolEvictor` (15-min idle eviction) helps for inactive tenants, but active tenants hold pools open on every replica.

#### 4.2.4 ThreadLocal Tenant Context — Async Incompatibility (MEDIUM)

`TenantContext.java:18` uses plain `ThreadLocal<TenantProfile>`. This works for synchronous servlet requests but is incompatible with:
- `@Async` executor threads
- `CompletableFuture` chains
- `parallelStream()` (already documented at `CustomerorderBatchService.java:952`)
- Java 21 virtual threads (`spring.threads.virtual.enabled=true`)

No `TaskDecorator` exists to propagate tenant context to child threads.

#### 4.2.5 Thread-Safety Bugs (MEDIUM)

| File | Line | Issue |
|------|------|-------|
| `AdviceController.java` | 38 | `static final SimpleDateFormat` — not thread-safe, concurrent requests produce garbled dates |
| `CustomerOrderBatchController.java` | 26 | Same `SimpleDateFormat` bug |
| `Authority.java` | 15 | Mutable public `static HashSet` — should be `Collections.unmodifiableSet()` |

#### 4.2.6 Tenant Key Construction — Duplicated Logic (LOW)

The tenant key pattern (`{tenantPrefix}-{facilityCode}`) is copy-pasted in 6+ classes:
- `TenantDynamicRoutingDataSource.java:70-83`
- `TenantIdentifierResolver.java:16-28`
- `TenantContext.java:28-31`
- `MultiTenantJwtDecoder.java:52-65`
- `MultiTenantKeycloakService.java:44-48`
- `TenantConfigLoader.java:51-55`

Any divergence in key construction across these files would cause silent routing failures.

### 4.3 Horizontal Scaling Recommendations

#### 4.3.1 Distributed Cache — Replace Caffeine with Redis (CRITICAL)

**Problem:** JVM-local caches diverge across replicas; `@CacheEvict` is local-only
**Addresses:** 4.2.1 (cross-replica staleness), security risk from stale user cache

##### Option A: Redis-Backed Spring Cache (Recommended)

Replace `CacheConfig.java` `SimpleCacheManager`/`CaffeineCache` with `RedisCacheManager`:

```java
@Bean
public CacheManager cacheManager(RedisConnectionFactory factory) {
    RedisCacheConfiguration config = RedisCacheConfiguration.defaultCacheConfig()
        .entryTtl(Duration.ofMinutes(5))
        .serializeValuesWith(SerializationPair.fromSerializer(new GenericJackson2JsonRedisSerializer()));
    return RedisCacheManager.builder(factory)
        .withCacheConfiguration("sysprops", config.entryTtl(Duration.ofMinutes(2)))
        .withCacheConfiguration("clients", config)
        .withCacheConfiguration("locations", config)
        .withCacheConfiguration("itemdata", config)
        .build();
}
```

Also replace `KeycloakService.java:60` Caffeine user cache with Redis-backed.

**Fix cross-tenant eviction:** Replace `@CacheEvict(allEntries=true)` with tenant-scoped cache keys (e.g., `tenantKey + ":" + itemId`).

**Local Development:** Use Spring profile-based configuration so Redis is only required in production. Local dev continues using Caffeine with zero infrastructure changes:

```properties
# application_dev.properties (local dev — no Redis needed)
spring.cache.type=caffeine

# application.properties (production — Redis required)
spring.cache.type=redis
spring.data.redis.host=${REDIS_HOST:localhost}
spring.data.redis.port=${REDIS_PORT:6379}
```

The `CacheConfig` class should be split into two `@Profile`-conditional configurations:
- `CaffeineCacheConfig` (`@Profile("dev")`) — current Caffeine setup, used for local development
- `RedisCacheConfig` (`@Profile("!dev")`) — Redis-backed `RedisCacheManager`, used in staging/production

This ensures developers never need Redis installed locally, while production gets cross-replica cache consistency.

**Effort:** Medium (2-3 days)
**Risk:** Low (Spring Cache abstraction means service code unchanged; `@Cacheable`/`@CacheEvict` annotations stay identical)
**Requires:** Redis server in production only (can start with single instance, add Sentinel for HA later)

##### Option B: Hybrid L1 Caffeine + L2 Redis

Keep Caffeine as a near-cache (1-min TTL) backed by Redis (5-min TTL). Best latency for hot data with cross-replica consistency.

**Effort:** High (custom `CacheManager` implementation)
**Risk:** Medium (two cache layers to reason about)

##### Option C: Short TTL Caffeine Only (Current + Acceptable for Now)

Keep current 5-minute Caffeine TTLs. Accept 5-minute staleness window. Sufficient for tenant-aware routing (Option A deployment) where each tenant hits one replica.

**Effort:** None
**Risk:** Medium (only works with sticky routing, not round-robin)

#### 4.3.2 Tenant Config Hot-Reload (HIGH)

**Problem:** New tenants or config changes require instance restarts
**Addresses:** 4.2.2

##### Option A: Scheduled Refresh (Recommended)

Add a `@Scheduled` method to `TenantConfigLoader` that re-queries the landlord DB every 5-10 minutes:

```java
@Scheduled(fixedDelay = 300000) // 5 minutes
public void refreshTenantConfigs() {
    Map<String, TenantDbConfiguration> fresh = landlordService.getAllDbConfigurations()...;
    // Diff against current cache
    // Add new entries, update changed entries
    // Optionally evict/recreate connection pools for changed DB configs
}
```

**Effort:** Medium (1-2 days)
**Risk:** Low (read-only landlord queries; existing pools stay open until config actually changes)

##### Option B: Admin Endpoint + Webhook

Expose a `POST /admin/refresh-tenants` endpoint. OPS tools or landlord DB triggers call it when config changes.

**Effort:** Low (1 day)
**Risk:** Low (manual trigger, no polling)

#### 4.3.3 Connection Pool Strategy for Multiple Replicas (HIGH)

**Problem:** N replicas × T tenants × maxPoolSize exceeds PostgreSQL `max_connections`
**Addresses:** 4.2.3

##### Option A: PgBouncer Connection Pooler (Recommended for >3 replicas)

Deploy PgBouncer in front of each tenant PostgreSQL database. PgBouncer caps total connections regardless of how many application replicas connect.

```
[Replica 1] ──┐
[Replica 2] ──┼── [PgBouncer (pool=30)] ── [PostgreSQL (max_connections=50)]
[Replica N] ──┘
```

Application-side: reduce HikariCP `maxPoolSize` to 2-3 per tenant (connection multiplexing handled by PgBouncer).

**Effort:** Medium (infrastructure, no code changes)
**Risk:** Low (transparent to application; must use `transaction` pooling mode for prepared statements)

##### Option B: Dynamic Pool Sizing Based on Replica Count

Pass replica count as environment variable, compute pool size:

```java
int maxPool = Math.max(2, configuredMax / replicaCount);
hikariConfig.setMaximumPoolSize(maxPool);
```

**Effort:** Low (config change)
**Risk:** Low (but requires coordination when scaling up/down)

##### Option C: Increase PostgreSQL `max_connections`

Simple but has memory implications (each connection uses ~5-10MB).

**Effort:** Low (config change + restart)
**Risk:** Medium (RAM pressure on DB server)

#### 4.3.4 Tenant-Aware Thread Context Propagation (MEDIUM)

**Problem:** `ThreadLocal` tenant context lost in async/parallel contexts
**Addresses:** 4.2.4

##### Option A: TenantAwareTaskDecorator (Recommended)

```java
public class TenantAwareTaskDecorator implements TaskDecorator {
    @Override
    public Runnable decorate(Runnable runnable) {
        TenantProfile tenant = TenantContext.getCurrentTenant();
        return () -> {
            TenantContext.setCurrentTenant(tenant);
            try { runnable.run(); }
            finally { TenantContext.clear(); }
        };
    }
}
```

Register on all `@Async` executors and Spring's `TaskExecutor`:

```java
@Bean
public TaskExecutor taskExecutor() {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setTaskDecorator(new TenantAwareTaskDecorator());
    return executor;
}
```

**Effort:** Low (1 day)
**Risk:** Low (preventive — no async usage today, but protects future adoption)

##### Option B: Structured Concurrency (Java 21+)

Use `ScopedValue` instead of `ThreadLocal` for virtual thread compatibility. This is the future-proof approach but requires Java 21+ API changes.

**Effort:** High
**Risk:** Medium (preview API, may change)

#### 4.3.5 Extract Shared Tenant Utilities (LOW)

**Problem:** Tenant key construction duplicated in 6+ classes
**Addresses:** 4.2.6

```java
public final class TenantKeyBuilder {
    public static String buildKey(String tenantName, String facilityCode) {
        if (tenantName == null || tenantName.isEmpty()) {
            return facilityCode;
        }
        String tenantPrefix = tenantName.length() >= 4
            ? tenantName.substring(0, 4)
            : tenantName;
        return tenantPrefix + "-" + facilityCode;
    }
    
    public static String buildKey(TenantProfile profile) {
        return buildKey(profile.getTenantName(), profile.getFacilityCode());
    }
}
```

**Effort:** Low (1 day)
**Risk:** Very Low (pure refactor, no behavioral change)

#### 4.3.6 Tenant-Aware Job Execution Abstraction (LOW)

**Problem:** All 6 scheduled jobs duplicate the same tenant-iteration pattern
**Addresses:** Code duplication, reduces risk of missing `TenantContext.clear()`

```java
@Service
public class TenantJobExecutor {
    public void forEachTenant(Consumer<TenantProfile> action) {
        for (TenantProfile tenant : tenantDbConfigCache.getAllProfiles()) {
            TenantContext.setCurrentTenant(tenant);
            try {
                action.accept(tenant);
            } catch (Exception e) {
                LOG.error("Error processing tenant {}", tenant.getKey(), e);
            } finally {
                TenantContext.clear();
            }
        }
    }
}
```

**Effort:** Low (1-2 days)
**Risk:** Very Low (reduces boilerplate, adds per-tenant error isolation)

### 4.4 Horizontal Scaling Deployment Options

| Option | Description | Code Changes | Infrastructure | Scaling Limit |
|--------|-------------|-------------|----------------|---------------|
| **A: Tenant-Pinned** | Route each tenant to a specific replica via load balancer header routing on `facility_code` | None | LB config | 1 replica per tenant (bounded by busiest tenant) |
| **B: Multi-Replica Same-Tenant** | Any replica handles any tenant; concurrency fixes already in place | Fix 4.2.1 caches + 4.2.3 pools | Redis + PgBouncer | Unlimited replicas |
| **C: Hybrid** | Tenant-pinned for writes, round-robin for reads | Read-replica routing | LB + read replicas | Read-heavy scales independently |

**Recommended path:**
1. **Immediate:** Deploy Option A (tenant-pinned). Zero code risk, immediate scaling.
2. **Sprint 1:** Implement 4.3.1A (Redis cache) + 4.3.2A (config refresh) + 4.3.4A (task decorator)
3. **Sprint 2:** Implement 4.3.3A (PgBouncer) or 4.3.3B (dynamic pool sizing)
4. **Sprint 3:** Switch to Option B (full multi-replica) with load testing validation

---

## 5. Updated Implementation Sequence

| Phase | Focus | Effort | Impact | Status |
|-------|-------|--------|--------|--------|
| **Phase 1** | Transaction safety (3.6A) + OLock retry expansion (3.2A) | 1-2 weeks | Eliminates root causes #1, #4, #6 | **DONE** ✅ (`25001a9`) |
| **Phase 2** | N+1 batch fetch for top 5 hot paths (3.4A) | 2-3 weeks | Major performance gains | **DONE** ✅ (8/10 items, `0d2bcee`, `4a0e876`) |
| **Phase 3** | Distributed cache — Redis (4.3.1A) + config hot-reload (4.3.2A) | 2-3 weeks | Enables true multi-replica deployment | **DONE** ✅ (`7c6bcf7`) |
| **Phase 4** | Async OMS notifications (3.3A or 3.3B) | 2-3 weeks | Eliminates root causes #5, #7 | Skipped (for now) |
| **Phase 5** | Null safety — replace unsafe .get() across service layer | 2-3 weeks | Eliminates root cause #2 | **DONE** ✅ (`5b1b17f`, `a66805c`) — 39 files audited, 17 fixed, 22 safe |
| **Phase 6** | Connection pool strategy — PgBouncer (4.3.3A) | 1-2 weeks | Removes DB connection ceiling | Skipped (infrastructure) |
| **Phase 7** | Cancel orchestrator (3.5A) | 2-3 weeks | Consolidates root cause #9 | **Part A DONE** ✅ (`14a4a81`) — 4 bugs fixed. Part B separate PR |
| **Phase 8** | UTC timezone migration | 1-2 weeks | Addresses root cause #10 | Not started |
| **Phase 9** | Full multi-replica validation + load testing | 1-2 weeks | Production readiness for Option B | Not started |

---

## 6. Quick Wins (< 1 day each)

| # | Quick Win | Status | Commit |
|---|-----------|--------|--------|
| 1 | Add `@TenantTransactional` alias | **DONE** ✅ | `25001a9` (Phase 1) |
| 2 | Wrap remaining scheduled jobs with `OptimisticLockRetry` | **DONE** ✅ | `25001a9` (Phase 1) |
| 3 | Add `entityManager.refresh()` after all `findByIdForUpdate` calls | **Already done** ✅ | Prior commits |
| 4 | Add ArchUnit test for bare `@Transactional` in service package | **DONE** ✅ | `25001a9` (Phase 1) |
| 5 | Add null-URL early-return guard in `ManageOrderService` | **Already done** ✅ | Prior commits — `getRequiredOmsUrl()` already has null/blank guard |
| 6 | Fix `SimpleDateFormat` thread-safety bugs | **DONE** ✅ | `b12e096` — removed unused dead code from AdviceController + CustomerOrderBatchController |
| 7 | Wrap `Authority.NO_ASSIGN_USER_ROLE` in `Collections.unmodifiableSet()` | **DONE** ✅ | `b12e096` |
| 8 | Fix cross-tenant cache eviction `@CacheEvict(allEntries=true)` | **Deferred** | Needs Redis pattern-based key deletion — best addressed when Redis profile is activated |
| 9 | Extract `TenantKeyBuilder` utility | **DONE** ✅ | `b12e096` — consolidated 4 duplicate `buildTenantKey` methods |
| 10 | Add `TenantAwareTaskDecorator` | **DONE** ✅ | `b12e096` — ready to register on any `ThreadPoolTaskExecutor` |
| 11 | Fix `TenantConfigLoader` logging bug | **DONE** ✅ | `7c6bcf7` (Phase 3) |

**Result: 10 of 11 done, 1 deferred (requires Redis infrastructure).**

---

## 7. Validation Review (2026-04-03)

This section validates the plan against the current codebase as of 2026-04-03. No source-code changes were made during this review; this section is appended for factual verification only.

### 7.1 Confirmed Claims

- **Dual transaction-manager risk is real.** The codebase has separate landlord and tenant persistence infrastructure, and bare `@Transactional` remains hazardous because tenant service work must use `value = "tenantTransactionManager"`.
- **Optimistic locking baseline exists.** `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java` contains an `@Version` field, and optimistic locking is broadly available through entity inheritance.
- **`OptimisticLockRetry` exists and is used in production, but only selectively.** Confirmed direct usage in `UnitloadBusinessService`, `PickingorderBusinessService`, and `MobilePalletizingService`.
- **Scheduled-job distributed locking is implemented.** `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` uses PostgreSQL `pg_try_advisory_lock(...)` / `pg_advisory_unlock(...)` under `landlordTransactionManager` and defines 5 stable job lock IDs.
- **Global concurrency exception handling exists.** `src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java` maps both `ObjectOptimisticLockingFailureException` and `PessimisticLockingFailureException` to HTTP 409.
- **JVM-local cache staleness concerns are valid.** `src/main/java/net/aim_ai/wms/config/CacheConfig.java` defines local Caffeine-backed caches (`sysprops`, `clients`, `locations`, `itemdata`) with 5-minute TTLs.
- **Cross-tenant cache over-eviction claim is confirmed.** `src/main/java/net/aim_ai/wms/service/ItemdataService.java:56` uses `@CacheEvict(value = "itemdata", allEntries = true)`, which clears the full `itemdata` cache rather than tenant-scoped entries.
- **Keycloak user caching remains replica-local.** `src/main/java/net/aim_ai/wms/service/KeycloakService.java` uses a local Caffeine `userCache` with 15-minute TTL.
- **Tenant configuration caching has no runtime refresh path.** `TenantDbConfigCache`, `TenantAuthConfigCache`, `MultiTenantJwtDecoder`, and `MultiTenantKeycloakService` all cache startup/lazy state without an observed eviction or refresh mechanism.
- **Cron scheduling is gated by configuration.** `src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java` is conditional on `app.cron=true`.
- **Thread-safety findings are valid.** `AdviceController.java:38` and `CustomerOrderBatchController.java:26` both keep `static final SimpleDateFormat` instances; `Authority.java:15-16` exposes a mutable public `HashSet`.
- **Tenant-key construction is duplicated across multiple classes.** The duplication is present in `TenantDynamicRoutingDataSource`, `TenantContext`, `MultiTenantJwtDecoder`, `MultiTenantKeycloakService`, and `TenantConfigLoader`.
- **Migration filenames mentioned in the plan exist.** `V2.1.05__add_critical_missing_indexes.sql` and `V2.1.06__add_composite_indexes.sql` are present in `src/main/resources/db/migration/`.

### 7.2 Invalidated or Inaccurate Claims

- **Entity count is off by one.** The plan states "all 45 entities via `AbstractBaseEntity`"; the current codebase has **44** model classes extending `AbstractBaseEntity`.
- **The 5-minute TTL statement is only partially true.** The Spring cache entries in `CacheConfig` are 5 minutes, but `KeycloakService.userCache` is still **15 minutes**, so the broader wording should be narrowed.
- **`OptimisticLockRetry` usage is overstated.** The plan says it is used in palletizing, pick confirmation, and replenishment. Current direct `executeWithRetry(...)` usages were confirmed in palletizing and pick/order-related services, but not broadly across scheduled jobs, and replenishment usage is not clearly established from current production references.
- **Several line-number references have drifted.** Example: the cache definitions in `CacheConfig.java` are currently on lines 24-27, not all of the exact line numbers cited throughout the plan. The path for `CustomerOrderBatchController` is also `src/main/java/net/aim_ai/wms/controller/CustomerOrderBatchController.java`.
- **The sample `TenantKeyBuilder` implementation in section 4.3.5 is inconsistent with the current runtime contract.** The example builds an uppercase 2+2-character key, while the actual code currently uses `tenantPrefix + "-" + facilityCode` (with up to 4 characters from tenant name and no forced uppercase). If copied literally, the sample would be incompatible with the current routing/auth/cache code.

### 7.3 Ambiguous or Not Fully Code-Verifiable

- **Frequency/severity rankings** in sections 1-2 are plausible but are derived from prior plan documents rather than directly verifiable from source code alone.
- **Effort, risk, and sequencing estimates** in sections 3-6 are architectural judgments, not codebase facts.
- **Historical statements such as "already fixed in Phase 1-2"** are mostly consistent with current code, but they remain historical/project-management claims rather than purely code-native assertions.
- **UTC/DST storage risk** is directionally credible, but full validation would require schema/runtime/database inspection beyond the static code pass performed here.

### 7.4 Additional Findings Not Explicitly Captured in the Plan

- **`TenantConfigLoader` has a startup logging bug.** Its final log line reports `authConfigs.size()` for both DB and auth counts; this affects observability but not runtime behavior.
- **The actual tenant-key format used today is more consistently `tenantPrefix + "-" + facilityCode` than the older 4-character routing-key description suggests.** This is important when documenting or refactoring tenant-aware infrastructure.
- **Additional `SimpleDateFormat` usages exist elsewhere in the codebase**, but the two highlighted controllers are the confirmed shared-singleton thread-safety cases.

### 7.5 Recommended Updates to This Plan

1. **Refresh stale file paths and line numbers** before using this plan as an implementation checklist.
2. **Change the optimistic-lock coverage statement** from "45 entities" to **44 current entities extending `AbstractBaseEntity`**.
3. **Clarify cache TTL wording** so it distinguishes 5-minute Spring caches from the 15-minute Keycloak user cache.
4. **Revise the `OptimisticLockRetry` status text** to say the utility exists and is partially adopted, not broadly deployed across all critical paths.
5. **Replace the sample `TenantKeyBuilder` snippet** with one that matches the current runtime key format, or explicitly label it as a future breaking-format proposal.
6. **Retain the migration references to `V2.1.05` and `V2.1.06`**; those filenames are correct in the current repository.
7. **Optionally add the `TenantConfigLoader` logging defect** as a minor observability note so future reviewers do not rely on its startup counts.

### 7.6 Overall Assessment

The plan is **substantively accurate on architecture and risk direction**: the transaction-manager warning, cache consistency concerns, tenant-config refresh gap, advisory-lock strategy, and thread-safety findings are all grounded in the current codebase. The main corrections needed are **precision issues**: entity count, selective `OptimisticLockRetry` adoption, a few stale line/path references, and the tenant-key example that does not match the current implementation.

---

## 8. Re-Validation Results (2026-04-04)

Deep code analysis was performed against the current codebase to verify each finding from the Section 7 review. All corrections below have been applied to the plan.

### 8.1 Corrections Applied

#### 8.1.1 Entity Count: 44, Not 45

**Verified.** The codebase has exactly **44** classes extending `AbstractBaseEntity` in `src/main/java/net/aim_ai/wms/model/`. The full list includes: Advice, Adviceposition, Billoflading, BillofladingPosition, Boxtype, Client, Customerorder, CustomerorderBatch, CustomerorderPosition, Cyclecount, CyclecountPosition, FixLocationAssignment, Goodsreceipt, Goodsreceiptposition, InventoryRecord, Itemdata, Itemunit, Location, LocationArea, LocationConstraint, LocationRack, LocationRackRow, LocationType, Message, MessageArchived, Pickingorder, PickingorderPosition, PickingorderUnitload, Printer, Queryrepository, Replenishorder, Section, Shipperid, Shippingmethod, Stockrecord, Stockunit, Sysprop, Unitload, UnitloadRecord, UnitloadType, User, UserFunction, UserGroup, UserRole.

**Action:** All references to "45 entities" in sections 4.1 have been updated to "44 entities".

#### 8.1.2 OptimisticLockRetry Usage — Narrower Than Claimed

**Verified.** `OptimisticLockRetry.executeWithRetry()` is used in exactly **3 production files**:
- `PickingorderBusinessService.java:451` — pick confirmation
- `UnitloadBusinessService.java:161` — unitload operations
- `MobilePalletizingService.java:219` — palletizing

It is **NOT** used in replenishment code (`ReplenishorderService`, `MobileReplenishService`, `ReplenishGeneratorService`, `ReplenishOrderJobService`).

**Action:** Section 4.1 updated from "Used in palletizing, pick confirmation, replenishment" to "Used in pick confirmation, unitload operations, and palletizing (3 call sites). Not yet adopted in replenishment, order release, or stock services."

#### 8.1.3 Cache TTL Distinction

**Verified.** `CacheConfig.java` lines 24-27 define 4 caches, all with 5-minute TTL:
- Line 24: `sysprops` (200 max, 5 min)
- Line 25: `clients` (100 max, 5 min)
- Line 26: `locations` (2000 max, 5 min)
- Line 27: `itemdata` (3000 max, 5 min)

`KeycloakService.java:60-63` defines a separate Caffeine user cache with **15-minute TTL** and 500 max size.

**Action:** Section 4.2.1 table updated with correct line numbers. Text now explicitly distinguishes "5-minute Spring caches" from "15-minute Keycloak user cache".

#### 8.1.4 TenantKeyBuilder Sample — Fixed to Match Runtime Format

**Verified.** The actual tenant key format in `TenantDynamicRoutingDataSource.java:70-83` is:

```java
private String buildTenantKey(TenantProfile tenantProfile) {
    String tenantName = tenantProfile.getTenantName();
    String facilityCode = tenantProfile.getFacilityCode();
    if (tenantName == null || tenantName.isEmpty()) {
        return facilityCode;
    }
    String tenantPrefix = tenantName.length() >= 4
        ? tenantName.substring(0, 4)
        : tenantName;
    return tenantPrefix + "-" + facilityCode;
}
```

The format is `first4chars + "-" + facilityCode` (e.g., `"TEST-WH01"`), NOT a 2+2 uppercase key as the original sample suggested.

**Action:** Section 4.3.5 `TenantKeyBuilder` sample replaced with correct implementation matching runtime behavior.

#### 8.1.5 TenantConfigLoader Logging Bug — Confirmed

**Verified.** `TenantConfigLoader.java:68-69`:
```java
log.info("Loaded {} DB configurations and {} auth configurations",
    authConfigs.size(), authConfigs.size());
```
First parameter should be `dbConfigs.size()` but uses `authConfigs.size()` — reports same count for both.

**Action:** Added to Quick Wins list as item #11.

### 8.2 Additional SimpleDateFormat Findings

Deep scan found **11 files** referencing SimpleDateFormat. Only **2 are thread-unsafe** (shared static fields):

| File | Line | Risk | Status |
|------|------|------|--------|
| `AdviceController.java` | 38 | **CRITICAL** — static field on singleton @RestController | Already in Quick Wins #6 |
| `CustomerOrderBatchController.java` | 26 | **CRITICAL** — static field on singleton @RestController | Already in Quick Wins #6 |
| `TransactionReportRestController.java` | 98,104,107,212,218,221 | SAFE — method-local instances | No action needed |
| `OrderReleaseJob.java` | 112 | SAFE — method-local instance | No action needed |
| `FileExportService.java` | 84,152,217,285 | SAFE — method-local instances | No action needed |
| `StockunitService.java` | 14 | NONE — unused import | Minor cleanup |
| `MobileReplenishService.java` | 24-25 | NONE — unused imports | Minor cleanup |
| `MobilePickingService.java` | 20-21 | NONE — unused imports | Minor cleanup |
| `CycleCountController.java` | 119-120 | NONE — commented out | No action |
| `ReplenishMobileOrderDto.java` | 111 | NONE — commented out | No action |
| `ReceivingService.java` | 155 | NONE — already removed, comment documenting removal | No action |

**Action:** Section 4.2.5 updated with complete findings. Only the 2 CRITICAL cases need fixing.

### 8.3 Verification Summary

| Review Finding (7.2) | Verification Result | Action Taken |
|----------------------|-------------------|--------------|
| Entity count off by one (45→44) | **Confirmed: 44 entities** | Section 4.1 corrected |
| 5-min TTL only partially true | **Confirmed: Keycloak cache is 15 min** | Section 4.2.1 clarified |
| OptimisticLockRetry usage overstated | **Confirmed: 3 call sites, not in replenishment** | Section 4.1 corrected |
| Line numbers drifted | **Confirmed: CacheConfig lines are 24-27** | Line references updated |
| TenantKeyBuilder sample wrong format | **Confirmed: uses first4chars, not 2chars** | Section 4.3.5 sample replaced |
| TenantConfigLoader logging bug | **Confirmed: authConfigs.size() used twice** | Added to Quick Wins #11 |
| Additional SimpleDateFormat usages | **Found: 2 critical, 4 safe, 5 unused/commented** | Section 4.2.5 expanded |

All corrections from the Section 7 review have been validated and applied. No new architectural concerns were discovered during re-validation.
