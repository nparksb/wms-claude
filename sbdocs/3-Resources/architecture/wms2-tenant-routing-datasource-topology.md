---
title: "WMS v2 — Tenant Routing & DataSource Topology"
type: architecture
status: active
version: v2
scope: multi-tenancy
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-08
verified_by: code read of v2/wms2-api src/main at commit HEAD
related:
  - ./wms2-transaction-osiv-boundary-map.md
  - ./wms2-state-machine-catalog.md
  - ../../1-Projects/wms2/plan/260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md
  - ../../1-Projects/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md
  - ../../4-Archieves/wms2/plan/260424-connection-pool-exhaustion-fix-plan.md
  - ../../4-Archieves/wms2/plan/260424-TRANSACTION_MANAGER_FIX_PLAN.md
tags:
  - architecture
  - multi-tenancy
  - datasource
  - hikaricp
  - pgbouncer
  - wms2
---

# WMS v2 — Tenant Routing & DataSource Topology

**Scope:** How a tenant's HTTP request resolves to a PostgreSQL connection in `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19 (code read against `src/main/java`)

---

## 1. Overview

`wms2-api` runs one **landlord** PostgreSQL DB (tenant directory, Keycloak configs, system properties) and one physical PostgreSQL DB **per tenant-facility**. Connections are routed at query time by a custom `AbstractRoutingDataSource` that looks up a `TenantProfile` from a **ThreadLocal** set by a servlet filter, builds a 4-char routing key, and lazily creates a dedicated `HikariDataSource` on first access. Idle tenant pools are evicted after 15 min.

Two load-bearing facts to hold in memory:

1. **Tenant context is ThreadLocal only** — it does not propagate to `@Async`, `parallelStream`, `CompletableFuture.supplyAsync`, or raw `new Thread(...)`. A helper (`TenantAwareTaskDecorator`) exists but is **not registered** on any executor. Any code outside the HTTP filter must set `TenantContext` manually.
2. **Advisory locks assume session pooling.** The codebase uses `pg_try_advisory_lock()` to prevent duplicate cron runs across replicas. These locks are session-level in PostgreSQL. Under PgBouncer **transaction pooling**, they disappear at end-of-transaction — cron jobs would no longer be mutually exclusive across replicas.

---

## 2. Topology

```
   HTTP request
   (X-Tenant-ID: wineco, facility_code: cawh)
          │
          ▼
   TenantFilter (@Order HIGHEST_PRECEDENCE, servlet Filter)
     ├─ lowercased headers → TenantProfile(tenantName, facilityCode)
     ├─ TenantContext.setCurrentTenant(profile)   [ThreadLocal + MDC]
     ├─ chain.doFilter(...)
     └─ finally: TenantContext.clear()             [always]
                                                   │
                                                   ▼
                 Controller → Service (@Transactional("tenantTransactionManager"))
                                                   │
                                                   ▼
                   Hibernate → TenantIdentifierResolver.resolveCurrentTenantIdentifier()
                                                   │
                                                   ▼
                     TenantDynamicRoutingDataSource.determineTargetDataSource()
                        │
                        │  key = TenantKeyBuilder.buildKey(profile)
                        │        = first4Chars(tenantName) + "-" + facilityCode
                        │        e.g.  "wine-cawh"
                        │
                        ├─ tenantPools.computeIfAbsent(key, k -> createHikariPool(...))
                        │     └─ config from TenantDbConfigCache (loaded from landlord DB)
                        │
                        ├─ lastAccess.put(key, now())
                        └─ return HikariDataSource
                                                   │
                                                   ▼
                                    per-tenant PostgreSQL (one DB per tenant-facility)


   Landlord path (no TenantContext, or /api/public/*):
          │
          ▼
   determineTargetDataSource() → getResolvedDefaultDataSource()
          │
          ▼
   landlordDataSource (HikariPool, max 2) → landlord PostgreSQL

   Background: TenantConfigLoader (every 5m) refreshes TenantDbConfigCache + TenantAuthConfigCache from landlord.
   Background: TenantPoolEvictor (every 5m) closes tenant pools idle >15m.
```

---

## 3. Configuration Facts

### 3.1 Routing key

| Fact | Value | Source |
|---|---|---|
| Class | `TenantDynamicRoutingDataSource extends AbstractRoutingDataSource` | `net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java:18` |
| Key format | `{first4CharsOfTenantName}-{facilityCode}` (e.g. `wine-cawh`) | `TenantKeyBuilder.java:18-26` |
| Short-name exception | If tenant name < 4 chars, use full name | same file |
| Fallback when no context | Returns landlord datasource | `TenantDynamicRoutingDataSource.java:44` |
| Pool creation | Lazy, via `tenantPools.computeIfAbsent(...)` on first query | `TenantDynamicRoutingDataSource.java:52` |

### 3.2 Tenant context

| Fact | Value | Source |
|---|---|---|
| Storage | `ThreadLocal<TenantProfile>` (NOT `InheritableThreadLocal`) | `TenantContext.java:18` |
| Fields in `TenantProfile` | `tenantName`, `facilityCode` (both String) | `landlord/json/TenantProfile.java:4-5` |
| MDC correlation | `{tenantPrefix}-{facilityCode}` pushed into SLF4J MDC on set | `TenantContext.java:32` |
| Hibernate resolver | `TenantIdentifierResolver.resolveCurrentTenantIdentifier()` — returns tenant key or `"BOOTSTRAP"` when no context | `TenantIdentifierResolver.java:10-15` |
| Multi-tenancy strategy | `hibernate.multiTenancy = "DATABASE"` (one physical DB per tenant) | `TenantDatabaseConfig.java:60` |

### 3.3 Request entry point

| Fact | Value | Source |
|---|---|---|
| Filter | `TenantFilter implements jakarta.servlet.Filter` (`@Order(Ordered.HIGHEST_PRECEDENCE)`) | `TenantFilter.java` |
| Headers | `X-Tenant-ID`, `facility_code` (lowercased before use) | `TenantFilter.java:40-48` |
| Public-endpoint bypass | Paths starting with `/api/public/` set `TenantContext = null` and skip validation | `TenantFilter.java:34-38,45` |
| Cleanup | `TenantContext.clear()` in `finally` | `TenantFilter.java:54` |

---

## 4. Per-Tenant HikariCP Pool

Every tenant gets its own `HikariDataSource` created on first access. Config values come from the landlord DB (`TenantDbConfiguration`), with hard-coded defaults and several hard-coded constants that **cannot be overridden per-tenant**.

### 4.1 From landlord DB config (per-tenant, with defaults)

| HikariCP setting | Default if null | Source field | Comment |
|---|---|---|---|
| `maximumPoolSize` | **5** | `TenantDbConfiguration.maxPoolSize` | The dominant pool-pressure lever |
| `minimumIdle` | **1** | `TenantDbConfiguration.minIdle` | |
| `idleTimeout` | **600_000 ms** (10 min) | `TenantDbConfiguration.idleTimeoutMs` | |
| `connectionTimeout` | **30_000 ms** (30 s) | `TenantDbConfiguration.connectionTimeoutMs` | Pool-acquisition wait |
| JDBC URL / username / password / driver | — | `TenantDbConfiguration.dbUrl` / `dbUserName` / `dbPassword` / `driverClassName` | Per-tenant credentials |

### 4.2 Hard-coded (same for every tenant)

| Setting | Value | Source |
|---|---|---|
| `autoCommit` | `false` (Hibernate manages transactions) | `TenantDynamicRoutingDataSource.java:85` |
| `maxLifetime` | 1_800_000 ms (30 min) | same file |
| `leakDetectionThreshold` | 60_000 ms (60 s) | same file |
| `validationTimeout` | 5_000 ms (5 s) | same file |
| `keepaliveTime` | 300_000 ms (5 min) | same file |
| `cachePrepStmts` | `true` | same file |
| `prepStmtCacheSize` | 250 | same file |
| `prepStmtCacheSqlLimit` | 2048 | same file |
| `poolName` | `"HikariPool-" + tenantKey` | same file |

Any change to these values is a code change, not a config change.

### 4.3 Pool lifecycle

| Event | What happens |
|---|---|
| First query for tenant | `tenantPools.computeIfAbsent(key, ...)` builds the `HikariDataSource`; ~200–1000 ms latency spike on first request |
| Every subsequent query | `lastAccess.put(key, now())` — O(1) access |
| Tenant missing from cache | `TenantException` ("Database configuration not found for tenant key: …") |
| Idle > 15 min (`wms.tenant.pool.idle-ms`) | `TenantPoolEvictor` calls `removeTenant(key)` → `ds.close()` gracefully drains |
| Eviction in-flight | Connections drain; any in-progress transaction must complete before close returns |
| Next query after eviction | Pool recreated lazily — same 200–1000 ms spike |

No warm-up: there is **no** `ApplicationRunner` / `CommandLineRunner` that prewarms tenant pools at startup. `TenantConfigLoader` warms only the config cache, not the pools themselves.

---

## 5. The Landlord Side

Separate config, separate pool, separate `PlatformTransactionManager`. See §4.1–4.3 of [`wms2-transaction-osiv-boundary-map.md`](./wms2-transaction-osiv-boundary-map.md) for the transaction-manager angle.

| Fact | Value | Source |
|---|---|---|
| Bean | `landlordDataSource` (`@Primary`) | `LandlordDatabaseConfig.java:36-41` |
| Properties prefix | `landlord.datasource.*` (via `@ConfigurationProperties`) | same file |
| JDBC URL (example) | `jdbc:postgresql://dev.sbo.li:25060/landlord` | `application.properties:39` |
| `maximum-pool-size` | **2** (deliberately tiny) | `application.properties:45` |
| `minimum-idle` | 1 | `application.properties:46` |
| `connection-timeout` | 20_000 ms | `application.properties:49` |
| `idle-timeout` | 30_000 ms | `application.properties:48` |
| `auto-commit` | `false` | `application.properties:50` |
| Pool name in logs | `LandlordHikariPool` | `application.properties:47` |

The landlord pool's size of **2** is intentional — under normal load it only serves short tenant-directory reads. Exhausting it means the config loader/evictor/health paths are fighting a live request for tenant metadata. If you change it, update this doc.

---

## 6. Non-HTTP Paths

### 6.1 Scheduled jobs

`app.cron=false` by default (`application.properties:111`). When enabled, cron jobs each follow the same tenant-iteration pattern — they are **not** auto-tenant-aware.

```
@Scheduled cron triggers OrderReleaseJob.doCalculation()
    │
    ├─ advisoryLockService.tryLock(ORDER_RELEASE)     ← pg_try_advisory_lock on landlord
    │   └─ if already held by another replica → skip
    │
    ├─ for (TenantProfile profile : tenantDbConfigurationRepository.findAll()) {
    │     TenantContext.setCurrentTenant(profile);
    │     try { ... per-tenant work ... }
    │     finally { TenantContext.clear(); }
    │   }
    │
    └─ advisoryLockService.unlock(...)
```

Cron jobs present in the codebase (all follow the same shape):

| Job | File |
|---|---|
| `OrderReleaseJob` | `schedulejob/OrderReleaseJob.java` |
| `ReplenishOrderJob` | `schedulejob/ReplenishOrderJob.java` |
| `StockSummaryExportJob` | `schedulejob/StockSummaryExportJob.java` |
| `CleanUpOldMessagesJob` | `schedulejob/CleanUpOldMessagesJob.java` |
| `ReleaseExpiredPickingOrdersFromUserJob` | `schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` |

Scheduling wiring lives in `schedulejob/SchedulingConfiguration.java` (`@ConditionalOnProperty(name = "app.cron", havingValue = "true")`, line 24). Cron expressions come from `SyspropService` (system properties table in landlord DB).

### 6.2 Async / parallel code

`TenantAwareTaskDecorator` exists at `landlord/config/TenantAwareTaskDecorator.java:1-43` — it captures `TenantContext` at submit time and sets it on the worker thread inside a try/finally. **It is not registered on any `TaskExecutor` in the codebase.** Consequences:

- `@Async` methods do **not** inherit tenant context. Any `@Async` service method that touches tenant data will hit the landlord fallback or a `BOOTSTRAP` resolver result.
- `parallelStream()` does **not** propagate. Don't use it inside a tenant-scoped service.
- Virtual threads (if introduced) need `ScopedValue`, not ThreadLocal. Today's code is safe only because virtual threads are not enabled.

If you register the decorator on a `ThreadPoolTaskExecutor`, confirm every submitting path holds valid tenant context at the moment of `executor.submit(...)` — otherwise workers inherit `null` and silently use landlord.

### 6.3 Health checks

| Check | Scope | File |
|---|---|---|
| `EndpointHealthCheck implements HealthIndicator` | Reachability of Keycloak URLs (from `dns.https.urls`) | `EndpointHealthCheck.java:25` |
| `TenantHealthController` | `GET /v3/tenant/health` — manually sets `TenantContext`, triggers pool creation, tests connection | `controller/TenantHealthController.java:27` |
| Actuator `/actuator/health/{liveness,readiness}` | K8s probes — enabled via `management.endpoint.health.probes.enabled=true` | `application.properties:82` |
| Actuator `hikaricp` metrics | Per-pool gauges (active, idle, waiting, total) | `management.endpoints.web.exposure.include=health,info,metrics,hikaricp` |

---

## 7. Startup Sequence

1. Spring context builds. Landlord DS + landlord EMF + landlord TM ready.
2. `ApplicationReadyEvent` fires.
3. `TenantConfigLoader.loadTenantConfigs()` runs (`@Order(0)` — **first**): reads all rows from `TenantDbConfigurationRepository` and `TenantAuthConfigurationRepository`, populates `TenantDbConfigCache` + `TenantAuthConfigCache`. Blocks until done.
4. `SchedulingConfiguration.onApplicationReady()` runs (`@Order(1)`): waits up to 60 s for at least one tenant pool to initialize (by test query) before enabling cron triggers.
5. `TenantConfigLoader.scheduledRefresh()` begins firing every `wms.tenant.config.refresh-interval-ms` (default 300_000 = 5 min; `0` disables).
6. `TenantPoolEvictor.evictIdlePools()` begins firing every `wms.tenant.pool.evict-interval-ms` (default 5 min).

A new tenant added to the landlord DB is invisible to the app until one of:
- The next 5-min config refresh runs, **or**
- The app restarts, **or**
- Someone hits `/v3/tenant/health` for that tenant (the controller validates cache; a miss surfaces as "not found" until a refresh).

There is no push / webhook mechanism.

---

## 8. Landlord vs Tenant — side-by-side

| Aspect | Landlord | Tenant |
|---|---|---|
| DS bean | `landlordDataSource` (`@Primary`) | `tenantDynamicRoutingDataSource` (custom routing DS) |
| TM bean | `landlordTransactionManager` (`@Primary`) | `tenantTransactionManager` (not primary) |
| EMF | `landlordEntityManagerFactory` (PU `"landlord"`) | `tenantEntityManagerFactory` (PU `"tenant"`) |
| Package scanned | `net.aim_ai.wms.landlord.model` | `net.aim_ai.wms.model` |
| Repo scan | `net.aim_ai.wms.landlord.jpa` | `net.aim_ai.wms.repo.jpa` |
| Hibernate multi-tenancy | n/a | `DATABASE` + `TenantIdentifierResolver` |
| Pool count | 1 | N (one per tenant-facility) |
| Pool max size | 2 (from `application.properties`) | 5 default, per-tenant override in landlord config |
| Credentials | Plain text in `application.properties` (!) | Per-row in `TenantDbConfiguration` (landlord DB) |
| Lifecycle | Always-on | Lazy create / 15-min-idle evict |

---

## 9. Secrets Handling

Jasypt is in `pom.xml` (`jasypt-spring-boot-starter`), but **no `ENC(...)` values exist** in `application.properties`, and no `@EnableEncryptableProperties` / custom `StringEncryptor` bean is configured.

Today:

- `landlord.datasource.password` sits in plain text at `application.properties:41`.
- Per-tenant DB credentials sit in the `TenantDbConfiguration` table in plain text.

This is an unaddressed secret-handling debt — any `application.properties` leak exposes landlord access, and landlord DB access exposes every tenant. Candidate for a dedicated ADR.

---

## 10. Known Landmines

1. **ThreadLocal does not propagate.** `@Async`, `parallelStream`, raw `new Thread(...)`, `CompletableFuture.supplyAsync` — none inherit `TenantContext`. The `TenantAwareTaskDecorator` exists but isn't wired to any executor (as of 2026-04-19). If you add async, wire the decorator **and** confirm the submitting thread holds a valid context.
2. **Null context falls through to landlord.** `determineTargetDataSource` returns the landlord DS when no tenant is set (`TenantDynamicRoutingDataSource.java:44`). A bug that clears the ThreadLocal mid-request will silently route subsequent writes to landlord until a mismatch surfaces downstream.
3. **Advisory locks break under PgBouncer transaction pooling.** `AdvisoryLockService.tryLock(...)` uses `pg_try_advisory_lock` — a **session-level** construct. Under PgBouncer's `pool_mode = transaction` (the typical choice), the lock vanishes when the transaction ends. Cron jobs would then run concurrently across replicas. Mitigations: run PgBouncer in `session` mode, switch to `pg_try_advisory_xact_lock`, or move to Redis / DynamoDB distributed locking.
4. **Prepared-statement cache vs PgBouncer transaction pooling.** `prepStmtCacheSize=250` per tenant pool assumes the same physical connection is reused across statements. Under transaction pooling, cached statements must be re-prepared on every connection → wasted round-trips. Tune `prepareThreshold=0` on the PgBouncer side or disable client-side cache if you migrate.
5. **No tenant-pool prewarming.** First request per tenant after restart (or after 15 min idle) pays pool-creation latency (~200–1000 ms). A cold restart during a high-tenant-count deploy is a thundering-herd risk.
6. **Unbounded `tenantPools` map.** `ConcurrentHashMap` of tenant-key → `HikariDataSource`. Growth is bounded only by tenant count. If tenant count scales significantly, per-instance memory and total PostgreSQL connection count both grow linearly.
7. **Config refresh is async.** A new tenant in the landlord DB takes up to 5 min (default `wms.tenant.config.refresh-interval-ms`) to become routable. There is no push mechanism. For faster rollouts, decrease the interval or hit `/v3/tenant/health` for the new tenant to at least validate the config exists.
8. **`TenantFilter` lowercases both headers** (`tenantName.toLowerCase()`, `facilityCode.toLowerCase()`) before building the routing key. Any downstream code that compares against non-lowercased values breaks. The `TenantKeyBuilder` also implicitly lowercases by working on already-lowercased input.
9. **`/api/public/*` paths bypass tenant setup.** A new public endpoint that accidentally hits tenant-scoped data will fall through to landlord. Audit every new route under `/api/public/` for data-plane reach.
10. **Landlord password in plain text** (`application.properties:41`). Not a production posture; see §9.
11. **`BOOTSTRAP` tenant identifier.** `TenantIdentifierResolver` returns the literal string `"BOOTSTRAP"` when `TenantContext` is null. Queries routed to Hibernate during context-less code paths use this identifier — they may surface as "tenant not found" downstream, or (worse) succeed against the landlord schema via the `@Primary` fallback, depending on which EMF the path engages.
12. **`TenantPoolEvictor` does not check active work.** Eviction calls `HikariDataSource.close()` which drains gracefully, but a rare pathological case (very long-running single transaction ≥ 15 min idle in the middle) could interact badly with eviction. In practice transactions that long are themselves a bug, but worth keeping in mind.

---

## 11. PgBouncer / Horizontal Scaling Considerations

Relevant to the active [PgBouncer connection-pool strategy](../../1-Projects/wms2/plan/260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md) and [horizontal scaling report](../../1-Projects/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md):

| Current behavior | PgBouncer impact | Mitigation path |
|---|---|---|
| Per-tenant HikariCP client-side pool | Second layer of pooling in front of PgBouncer is fine — tune Hikari max downward since PgBouncer fans out to fewer backend connections | Lower per-tenant `maximumPoolSize`; rely on PgBouncer for backend rationing |
| `autoCommit=false` + Hibernate-managed TX | Compatible with `pool_mode = transaction` | No change |
| `prepStmtCacheSize=250` per pool | Wasted under transaction pooling (no statement persistence across txns) | Set JDBC `prepareThreshold=0` or clear client cache |
| `pg_try_advisory_lock` for cron mutex | Broken under transaction pooling | Use `pg_try_advisory_xact_lock` (tx-scoped, outlives the one tx), or switch to Redis locking |
| Per-request HTTP tenant filter | Unaffected — routing is app-layer | No change |
| `TenantDynamicRoutingDataSource.determineTargetDataSource` uses `computeIfAbsent` | Unaffected | No change |
| ThreadLocal context | Unaffected | But do not introduce virtual threads without also introducing `ScopedValue`-based context |
| Replica-to-replica cron coordination | Broken if transaction pooling (see above) | Same as above |
| Connection count at PG side | Current: `replicas × tenants × max_per_tenant` | With PgBouncer: capped by `max_server_connections` — order-of-magnitude reduction |

If PgBouncer is introduced in `transaction` mode, the four items marked "broken"/"wasted" above must all change in the same rollout — otherwise you'll silently lose cron mutual exclusion and pay latency on every statement.

---

## 12. How to use this doc

| Task | Start at |
|---|---|
| Debug "why is my tenant data appearing under landlord?" | §10 item 2, then §3.2 + §6.2 |
| Adding a new `@Async` method | §6.2 + §10 item 1 |
| Adding a new scheduled job | §6.1 + §10 item 3 |
| Adding a new tenant to production | §7 (startup sequence) + §10 item 7 |
| Sizing per-tenant Hikari pool | §4.1 + §10 item 6 |
| Planning PgBouncer migration | §11 in full |
| Investigating connection-pool exhaustion | §4.2 hard-coded values + §10 items 5–6 + [260424-connection-pool-exhaustion-fix-plan.md](../../4-Archieves/wms2/plan/260424-connection-pool-exhaustion-fix-plan.md) |
| Auditing tenant isolation for a new endpoint | §3.3 public-path bypass + §10 item 9 |

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `TenantContext`, `TenantFilter`, `TenantDynamicRoutingDataSource`, `TenantConfigLoader`, `TenantPoolEvictor`, `TenantIdentifierResolver`, `TenantAwareTaskDecorator`, `AdvisoryLockService`, all scheduled job classes, Hikari settings (per-tenant and landlord), `application.properties` lines 1–122, Jasypt usage | All counts and file:line refs confirmed against `src/main/java` + `src/main/resources` | Code read (grep-based) |

**Re-verify every 60 days.** Next due: **2026-06-18** — or sooner if the PgBouncer plan lands, since §4.2 hard-coded values and §10 items 3/4 will all change.
