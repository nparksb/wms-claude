---
title: "WMS v2 — Tenant Routing & DataSource Topology"
type: architecture
status: active
version: v2
scope: multi-tenancy
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: "2026-11-11 full re-verification against origin/develop @ df30fa62 (wms2-api): routing key / filter / context / resolver claims, every TenantDynamicRoutingDataSource anchor (the class grew to 754 lines), landlord pool properties, job inventory, decorator usage, secrets handling, health/actuator wiring. Corrections: landlord pool is 10 not 2; landlord password is an env placeholder, Jasypt is gone from pom.xml; tenantPools -> poolHolders; resolveWarehouseTz now refuses the pool on failure; TenantAwareTaskDecorator is now registered on one TaskExecutor bean; 11 job classes not 8. NOT re-verified: live landlord/tenant DB contents, deployed env vars (e.g. LANDLORD_DATASOURCE_PASSWORD in Portainer), PgBouncer plan status. Report: scratchpad verify/authz-tenant-journey.md. Prior passes follow: SBDEV-3198 doc-drift pass 2026-09-06 — re-verified ONLY the scheduled-job entry-point claims in this doc against origin/develop d4a6ab8a (doCalculation deleted from all of src/main; runFor(TriggerSpec) / runForCurrentTenant() / deriveSpecForCurrentTenant() are the replacements; the advisory lock moved inside the per-tenant loop and takes tenant_db_configuration.id as a second key). NOTHING ELSE in this doc was re-derived on this pass — treat every other claim as carrying its previous verification date. (previous last_verified: 2026-09-02.) Prior: SBDEV-2727 landmine §10.13 added (active-flag deactivation / split-brain) — code read of landlord/service + config + schedulejob 2026-07-26; other sections carry forward the 2026-06-24 verification"
related:
  - ./wms2-transaction-osiv-boundary-map.md
  - ./wms2-state-machine-catalog.md
  - ../../1-Projects/wms2/plan/260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md
  - ../../4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md
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
**Owner:** Nam Park · **Last verified:** 2026-11-11 (code read against `origin/develop` @ df30fa62)

---

## 1. Overview

`wms2-api` runs one **landlord** PostgreSQL DB (tenant directory, Keycloak configs, system properties) and one physical PostgreSQL DB **per tenant-facility**. Connections are routed at query time by a custom `AbstractRoutingDataSource` that looks up a `TenantProfile` from a **ThreadLocal** set by a servlet filter, builds a 4-char routing key, and lazily creates a dedicated `HikariDataSource` on first access. Idle tenant pools are evicted after 15 min.

Two load-bearing facts to hold in memory:

1. **Tenant context is ThreadLocal only** — it does not propagate to `@Async`, `parallelStream`, `CompletableFuture.supplyAsync`, or raw `new Thread(...)`. A helper (`TenantAwareTaskDecorator`) exists and is **used manually in one job** (`StockSummaryExportJob:464` wraps its consumer `Runnable` with it) and is **registered on exactly one Spring `TaskExecutor` bean** (`clubRunExecutor`, `config/ClubRunExecutorConfig.java:48,58` — ⚠ corrected 2026-11-11; it used to say "not registered as a bean"), but it is **not** on any default / `@Async` executor. Any code outside the HTTP filter must carry `TenantContext` explicitly — either via this decorator or by setting it manually. Note virtual threads are enabled (`spring.threads.virtual.enabled=true`), so the manual-thread / `@Async` propagation gap is a present concern, not a hypothetical one (see §6.2).
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
                        ├─ poolHolders.computeIfAbsent(key, k -> new PoolHolder(createHikariPool(...), cfg, ...))   [map was `tenantPools` before SBDEV-3193/-3204]
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
   landlordDataSource (HikariPool, max 10 — was 2, raised 2026-09-13; §5) → landlord PostgreSQL

   Background: TenantConfigLoader (every 5m) refreshes TenantDbConfigCache + TenantAuthConfigCache from landlord.
   Background: TenantPoolEvictor (every 5m) closes tenant pools idle >15m.
```

---

## 3. Configuration Facts

### 3.1 Routing key

| Fact | Value | Source |
|---|---|---|
| Class | `TenantDynamicRoutingDataSource extends AbstractRoutingDataSource` | `net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java:22` (was `:18`; the class is now 754 lines) |
| Key format | `{first4CharsOfTenantName}-{facilityCode}` (e.g. `wine-cawh`) | `TenantKeyBuilder.java:18-26` |
| Short-name exception | If tenant name < 4 chars, use full name; if tenant name is null/empty the key is the bare `facilityCode` (`TenantKeyBuilder.java:19-21`). A separate `cacheKey(TenantProfile)` (`:52-57`) uses the **full** tenant name (`tenant:facility`, or `no-tenant`) and is for `@Cacheable` SpEL, not routing | same file |
| Fallback when no context | Returns landlord datasource (`tenantProfile == null \|\| facilityCode == null`) | `TenantDynamicRoutingDataSource.java:125-130` (was `:44`) |
| Pool creation | Lazy, via `poolHolders.computeIfAbsent(...)` on first query (hot path: `poolHolders.get` + `lastAccess.put`, `:146-149`; miss path `:157`) | `TenantDynamicRoutingDataSource.java:146-167` (was `:50`) |

### 3.2 Tenant context

| Fact | Value | Source |
|---|---|---|
| Storage | `ThreadLocal<TenantProfile>` (NOT `InheritableThreadLocal`) | `TenantContext.java:18` |
| Fields in `TenantProfile` | `tenantName`, `facilityCode` (both String) | `landlord/json/TenantProfile.java:4-5` |
| MDC correlation | `{tenantPrefix}-{facilityCode}` pushed into SLF4J MDC on set | `TenantContext.java:32` |
| Hibernate resolver | `TenantIdentifierResolver.resolveCurrentTenantIdentifier()` — returns tenant key or `"BOOTSTRAP"` when no context | `TenantIdentifierResolver.java:10-15` |
| Multi-tenancy strategy | `hibernate.multiTenancy = "DATABASE"` (one physical DB per tenant) | `TenantDatabaseConfig.java:121` (was `:60`) |

### 3.3 Request entry point

| Fact | Value | Source |
|---|---|---|
| Filter | `TenantFilter implements jakarta.servlet.Filter` (`@Order(Ordered.HIGHEST_PRECEDENCE)`) | `TenantFilter.java` |
| Headers | `X-Tenant-ID`, `facility_code` (lowercased before use; either missing ⇒ `TenantContext` set to `null`, no error) | `TenantFilter.java:23-24,40-49` |
| Public-endpoint bypass | Paths starting with `/api/public/` **return from the filter before any context is set** (`chain.doFilter` then `return`; ⚠ corrected 2026-11-11 — the doc said they "set `TenantContext = null`", which only the missing-header branch at `:45` does); the ThreadLocal is empty, so routing falls to landlord | `TenantFilter.java:34-38` |
| Cleanup | `TenantContext.clear()` in `finally` | `TenantFilter.java:53-55` |

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
| `autoCommit` | `false` (Hibernate manages transactions) | `TenantDynamicRoutingDataSource.java:206` (was `:83`; `createHikariPool` starts `:192`) |
| `maxLifetime` | 1_800_000 ms (30 min) | same file |
| `leakDetectionThreshold` | 60_000 ms (60 s) | same file |
| `validationTimeout` | 5_000 ms (5 s) | same file |
| `keepaliveTime` | 300_000 ms (5 min) | same file |
| `cachePrepStmts` | `true` | same file |
| `prepStmtCacheSize` | 250 | same file |
| `prepStmtCacheSqlLimit` | 2048 | same file |
| `poolName` | `"HikariPool-" + tenantKey` | same file |
| `connectionInitSql` | `SET timezone = '{warehouseTz}'` — set only when a warehouse IANA zone resolves (an UNSET sysprop ⇒ no init SQL + WARN; **any probe failure now refuses the pool**, see below) | `TenantDynamicRoutingDataSource.java:221-228` (was `:95-105`) |
| `connectTimeout` (pgjdbc data-source property) | `10` s, default of property `wms.tenant.pool.connect-timeout-seconds`; deliberately **no** `socketTimeout` / `loginTimeout` on the pool (SBDEV-3204) — not per-tenant, but a property rather than a literal | `:99`, `:249` |
| Micrometer binding | each pool is bound to the `MeterRegistry`; meters tagged `pool=HikariPool-<tenantKey>` (SBDEV-3193) | `:252-262` |

**UTC-migration session timezone (Phase 2.6).** Each tenant pool pins its PostgreSQL session timezone via `connectionInitSql` so that `current_date` / `current_timestamp` in views and native queries stay warehouse-local after the JVM/Hibernate switch to UTC. The zone is resolved once at pool-creation time by `resolveWarehouseTz(...)` (`TenantDynamicRoutingDataSource.java:491`; was `:118-160`), which opens a one-shot `DriverManager` connection (no Hikari pool exists yet) and reads the `System Time Zone` sysprop (`workstation = 'DEFAULT'`, lowest `client_id`). The value is validated via `ZoneId.of(...)` before being interpolated into the `SET timezone` meta-command (which cannot be parameterized). If the tenant DB hosts more than one client with differing zones, the helper logs a loud warning — one session timezone per pool cannot be correct for all of them. If the sysprop is unset/invalid, `connectionInitSql` is left unset and the session falls back to the PostgreSQL server default.

Any change to these values is a code change, not a config change.

**Failure semantics (re-verified 2026-11-11, `resolveWarehouseTz` Javadoc `:474-490`).** The probe returns `null` **only** when the `System Time Zone` sysprop has no row (the pool is then built without `connectionInitSql`, with a WARN). **Every failure throws `TenantException` and the pool is refused**, not built with a wrong zone: a probe timeout (SBDEV-3204), any other error reading `los_sysprop`, and a value that is not an IANA zone — including the provisioning placeholder `CHANGE-ME-FOR-NEW-CLIENT` (SBDEV-3872). The probe uses `wms.tenant.probe.connect-timeout-seconds` (default 5) and `wms.tenant.probe.socket-timeout-seconds` (default 10) (`:95-99`). Pools are also rebuilt when `evictChangedPools()` sees any of eight connection fields change (`dbUrl`, `dbUserName`, `dbPassword`, `driverClassName`, `maxPoolSize`, `minIdle`, `idleTimeoutMs`, `connectionTimeoutMs` — `connectionConfigEquals` `:646-655`); `PoolHolder` keeps the config the pool was built from (`:37`).

### 4.3 Pool lifecycle

| Event | What happens |
|---|---|
| First query for tenant | `poolHolders.computeIfAbsent(key, ...)` builds the `HikariDataSource`; ~200–1000 ms latency spike on first request |
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
| Bean | `landlordDataSource` (`@Primary`) | `LandlordDatabaseConfig.java:35-40` |
| Properties prefix | `landlord.datasource.*` (via `@ConfigurationProperties`) | same file |
| JDBC URL (example) | `jdbc:postgresql://dev.sbo.li:25060/landlord` | `application.properties:54` |
| `maximum-pool-size` | **10** (⚠ corrected 2026-11-11 — was documented as "**2** (deliberately tiny)"; raised 2026-09-13 after `LandlordHikariPool - Connection is not available ... (total=2, active=2, idle=0)` on the cron replica, comment at `application.properties:70-81`) | `application.properties:82` |
| `minimum-idle` | 1 | `application.properties:83` |
| `connection-timeout` | 20_000 ms | `application.properties:86` |
| `idle-timeout` | 30_000 ms | `application.properties:85` |
| `auto-commit` | `false` | `application.properties:87` |
| Pool name in logs | `LandlordHikariPool` | `application.properties:84` |

⚠ **Corrected 2026-11-11.** This paragraph used to say the pool's size of 2 "is intentional — under normal load it only serves short tenant-directory reads". The size is now **10**, and the reason is in the property comment (`application.properties:70-81`): every advisory-locked job pins **one** landlord connection for its whole run (`AdvisoryLockService` holds it in a ThreadLocal between `tryLock` and `unlock`) and needs a **second** to read the tenant list while holding it, so one job occupies 2 connections; with ten such jobs (eight business crons plus the two outbox lanes), four firing together at second 0 of each minute, size 2 starved overlapping jobs for 20 s and lost the tick. Exhausting the pool still means the config loader/evictor/health paths are fighting cron jobs for tenant metadata. ⚠ The "ten jobs" figure is the property comment's; this pass counts **eleven** job classes (§6.1) and did not re-derive how many of them lock. If you change the size, update this doc.

---

## 6. Non-HTTP Paths

### 6.1 Scheduled jobs

`app.cron=false` by default (`application.properties:196` at `df30fa62` — this cite read `:147` at `d4a6ab8a` and `:113` before that; it has drifted three times). When enabled, cron jobs each iterate tenants themselves — they are **not** auto-tenant-aware; no `TaskDecorator` is registered, so tenant context is never automatic on a scheduler thread.

```
CronTrigger fires  →  OrderReleaseJob.runFor(TriggerSpec spec)
    │                        ↑ SBDEV-3198 (2026-09-03): was doCalculation(Boolean),
    │                          which no longer exists. The lock moved INSIDE the loop.
    │
    └─ for (TenantDbConfiguration c : tenantDbConfigurationRepository.findByActiveTrue()) {
         TenantContext.setCurrentTenant(profileOf(c));
         try {
             TenantSchedule own = deriveSpecForCurrentTenant();
             if (own == null || !own.spec().equals(spec)) continue;  ← null = tenant is in NO group
                                                                      (timer sysprops absent/blank)
             if (!advisoryLockService.tryLock(ORDER_RELEASE, c.getId())) continue;
             try { ... per-tenant work ... }                 ↑ TWO-key pg_try_advisory_lock
             finally { advisoryLockService.unlock(ORDER_RELEASE, c.getId()); }
         } finally { TenantContext.clear(); }
       }
```

Cron jobs present in the codebase. ⚠ **They do NOT all follow the shape diagrammed above** — that parenthetical was true before SBDEV-3198 (every job then had a `doCalculation` loop under one fleet-wide lock) and is false now. Three of the original eight differ (⚠ re-counted 2026-11-11: there are now **eleven** job classes in `schedulejob/` — the table below adds `ClubRunJobPollerJob`, `EmptyPalletCleanupJob` and `PendingReversalReconciliationJob`; `EmptyPalletCleanupJob` follows the grouped `runFor(TriggerSpec)` shape with a two-key lock at `:247`, while `PendingReversalReconciliationJob` (`@Scheduled` `:130`, one-key lock `:132`) and `ClubRunJobPollerJob` (`@Scheduled` `:60`, no `tryLock` call in the file) are `@Scheduled`):

- `OutboxDispatcherJob:62` (plus the club lane `:83`) and `RestIdempotencyCleanupJob:105` — `@Scheduled` methods, **one-key** lock, no `TriggerSpec`, no grouping, and not `app.cron`-gated at all.
- `ReleaseExpiredPickingOrdersFromUserJob:161` (was `:143`; it also has `runForCurrentTenant()` at `:296`) — `runFor()` with **no argument**, no `deriveSpecForCurrentTenant`, a single fleet-wide trigger.

And of the original five grouped jobs (six with `EmptyPalletCleanupJob`), `CleanUpOldMessagesJob` and `StockSummaryExportJob` additionally wrap the two-key lock in a per-tenant one-key lock. Per-job shapes are tabulated in [wms2-scheduled-jobs-catalog.md](./wms2-scheduled-jobs-catalog.md) §2 and §4 — read them there rather than generalising from this diagram:

| Job | File |
|---|---|
| `OrderReleaseJob` | `schedulejob/OrderReleaseJob.java` |
| `ReplenishOrderJob` | `schedulejob/ReplenishOrderJob.java` |
| `StockSummaryExportJob` | `schedulejob/StockSummaryExportJob.java` |
| `CleanUpOldMessagesJob` | `schedulejob/CleanUpOldMessagesJob.java` |
| `ReleaseExpiredPickingOrdersFromUserJob` | `schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` |
| `OutboxDispatcherJob` | `schedulejob/OutboxDispatcherJob.java` |
| `RestIdempotencyCleanupJob` | `schedulejob/RestIdempotencyCleanupJob.java` |
| `StaleClubBatchCleanupJob` | `schedulejob/StaleClubBatchCleanupJob.java` |
| `ClubRunJobPollerJob` (added since 2026-09-06) | `schedulejob/ClubRunJobPollerJob.java` |
| `EmptyPalletCleanupJob` (added since 2026-09-06) | `schedulejob/EmptyPalletCleanupJob.java` |
| `PendingReversalReconciliationJob` (added since 2026-09-06) | `schedulejob/PendingReversalReconciliationJob.java` |

Two infra classes sit alongside the jobs (not jobs themselves): `schedulejob/JobMetrics.java` and `schedulejob/JobMetricsConfiguration.java` — shared Micrometer instrumentation (`wms2.cron.<job>.*` counters/timers) that every job calls. ⚠️ **Corrected 2026-09-06: this read "All eight jobs follow the canonical advisory-lock-first / per-tenant-iteration shape", which survived — in stronger words — the correction 12 lines above it.** It is wrong twice over. Not all eight share a shape (see the three exceptions above), and **"advisory-lock-first" is backwards** for the five grouped jobs: the lock is taken *inside* the tenant loop and *after* the spec-membership check, not before the loop (`StaleClubBatchCleanupJob:141` loop → `:158-159` spec filter → `:190` lock). Also note `JobMetrics` is **not** called by every job — `StaleClubBatchCleanupJob` has no `JobMetrics` field or reference at all.

Scheduling wiring lives in `schedulejob/SchedulingConfiguration.java` (`@ConditionalOnProperty(name = "app.cron", havingValue = "true")` at `:30` — this cite read `line 24`). ⚠️ **Two corrections, 2026-09-06.** (a) `los_sysprop` is in the **TENANT** DB, not the landlord DB — `Sysprop` is `@Table(name = "los_sysprop")` and `SyspropService` runs on `tenantTransactionManager` with a `TenantContext`-keyed cache. This matters here more than anywhere: reading a per-tenant table to build a process-wide trigger is precisely the defect SBDEV-3198 fixed (see [wms2-scheduled-jobs-catalog.md](./wms2-scheduled-jobs-catalog.md) §7.8). (b) Cron expressions come from `SyspropService` for **five** of the eight jobs only: `ReleaseExpiredPickingOrdersFromUserJob` hard-codes `"40 * * * * *"`, and `OutboxDispatcherJob` / `RestIdempotencyCleanupJob` take theirs from Spring `@Value` on `app.cron.<job>` in `application.properties` — the exact three exceptions named above.

### 6.2 Async / parallel code

`TenantAwareTaskDecorator` exists at `landlord/config/TenantAwareTaskDecorator.java:1-47` — it captures `TenantContext` at submit time and sets it on the worker thread inside a try/finally (restoring the previous value, or clearing, on exit). It is used in **two** places (⚠ corrected 2026-11-11; the doc said "exactly one place" and "not registered as a `TaskExecutor` bean"): (1) manually — `StockSummaryExportJob.java:464` wraps its OMS-consumer `Runnable` with `new TenantAwareTaskDecorator().decorate(...)` before handing it to a raw `new Thread(...)` (`:477`; was `:186`/`:199`); (2) registered — `ClubRunExecutorConfig.clubRunExecutor` (`config/ClubRunExecutorConfig.java:48`, a `ThreadPoolTaskExecutor` bean) calls `executor.setTaskDecorator(new TenantAwareTaskDecorator())` at `:58`, injected into `ClubRunJobPollerJob:49` and `ClubRunJobService:69`. It is still **not** registered on any default / `@Async` executor, so nothing else wires it automatically. Consequences:

- `@Async` methods do **not** inherit tenant context. Any `@Async` service method that touches tenant data will hit the landlord fallback or a `BOOTSTRAP` resolver result. There is no `TaskExecutor` bean carrying the decorator, so `@Async` would need it wired explicitly.
- `parallelStream()` does **not** propagate. Don't use it inside a tenant-scoped service. **SBDEV-2218 added a static guard:** `src/test/java/net/aim_ai/wms/unit/config/ParallelStreamSafetyArchTest.java` is an ArchUnit rule that fails the build if any class in `..service..`, `..controller..`, `..schedulejob..`, `..util..`, or `..repo..` calls `Collection.parallelStream()` or `BaseStream.parallel()`. Mirrors the `OptionalSafetyArchTest` (SBDEV-2116 lineage) pattern. The originating defect (`CustomerorderBatchService.calculateUnitLoadAmounts` parallelStream against Hibernate Session) is documented in commit `74f3c221`.
- Raw `new Thread(...)` does **not** propagate. `TenantContext` is a plain `ThreadLocal`, not `InheritableThreadLocal`, so a spawned thread starts with `null` context. The only manual-thread path today (`StockSummaryExportJob`) handles this correctly by wrapping its `Runnable` in the decorator before spawning. Any new manual-thread path must do the same.

**Virtual threads are enabled.** `application.properties:2` sets `spring.threads.virtual.enabled=true`, so on Spring Boot 3.5 the Tomcat request executor and Spring-managed task/scheduling executors run on virtual threads. This does **not** break the standard request path: Spring MVC processes each request top-to-bottom on a single (virtual) thread, and `TenantFilter` sets and clears `TenantContext` within that same thread's call stack — a `ThreadLocal` is still correct per-request whether the carrier thread is platform or virtual. What virtual threads do **not** change is the propagation gap: any path that hands work to *another* thread — `@Async`, `parallelStream()`, `CompletableFuture`, or a manual `new Thread(...)` — still loses `TenantContext` and must carry it explicitly (decorator or manual set/clear). `ScopedValue` would be the structured-concurrency-friendly replacement for the `ThreadLocal`, but it is not required for correctness today; the decorator covers the executor case.

If you register the decorator on a `ThreadPoolTaskExecutor`, confirm every submitting path holds valid tenant context at the moment of `executor.submit(...)` — otherwise workers inherit `null` and silently use landlord.

### 6.3 Health checks

| Check | Scope | File |
|---|---|---|
| `EndpointHealthCheck implements HealthIndicator` | Reachability of Keycloak URLs (from `dns.https.urls`) | `EndpointHealthCheck.java:25` |
| `TenantHealthController` | `GET /v3/tenant/health` — delegates to `TenantHealthService.checkTenantHealth()`, which manually sets `TenantContext`, triggers pool creation, and tests the connection. ⚠ 2026-11-11: it is now `@PublicHandler` and a member of `FunctionGuardInterceptor.GUARDED` (SBDEV-3158 slice 5) — a pre-entitlement bootstrap read, deliberately not function-gated | `controller/TenantHealthController.java:19` (class; was `:27`) |
| Actuator `/actuator/health/{liveness,readiness}` | K8s probes — enabled via `management.endpoint.health.probes.enabled=true` | `application.properties:163` (was `:85`) |
| Actuator `hikaricp` metrics | Per-pool gauges (active, idle, waiting, total) | `management.endpoints.web.exposure.include=health,info,metrics,hikaricp,prometheus` (`application.properties:165`, was `:87`; the list now also includes `tenantpool`) |

---

## 7. Startup Sequence

1. Spring context builds. Landlord DS + landlord EMF + landlord TM ready.
2. `ApplicationReadyEvent` fires.
3. `TenantConfigLoader.loadTenantConfigs()` runs (`@Order(0)` — **first**): reads all rows from `TenantDbConfigurationRepository` and `TenantAuthConfigurationRepository`, populates `TenantDbConfigCache` + `TenantAuthConfigCache`. Blocks until done.
4. `SchedulingConfiguration.onApplicationReady()` runs (`@Order(1)`): waits for at least one tenant pool to initialize (by test query) before enabling cron triggers — 60 attempts × 1 s by default (`wms.scheduling.boot-probe.max-attempts` / `retry-delay-ms`, `application.properties:44-45`; ⚠ 2026-11-11: now configurable). `onApplicationReady` is at `SchedulingConfiguration.java:275-276`.
5. `TenantConfigLoader.scheduledRefresh()` begins firing every `wms.tenant.config.refresh-interval-ms` (default 300_000 = 5 min; `0` disables).
6. `TenantPoolEvictor.evictIdlePools()` begins firing every `wms.tenant.pool.evict-interval-ms` (default 5 min).

A new tenant added to the landlord DB is invisible to the app until one of:
- The next 5-min config refresh runs, **or**
- The app restarts, **or**
- Someone hits `/v3/tenant/health` for that tenant (the controller validates cache; a miss surfaces as "not found" until a refresh).

A push path DOES exist: **`POST /actuator/tenantpool`** (`TenantPoolEndpoint`, SBDEV-2608) reloads the
fresh landlord row into the config cache and evicts the live pool, making a new tenant routable without
waiting out the refresh interval. Two caveats: it is **per-replica** — one call heals only the replica
that served it — and it **refuses** to rebuild a pool for a tenant with `active = false` (SBDEV-2727).

⚠ Corrected 2026-09-02 (SBDEV-3192). This section previously read "There is no push / webhook
mechanism." That was written before the endpoint existed and stayed wrong afterwards. Until SBDEV-3192
the endpoint also **500'd for any facility code shared by two tenants** (it resolved
`findByWarehouse(facility)` into an `Optional`, and UAT has two `nywh` rows), so the tool an operator
reaches for during onboarding failed exactly when a second tenant was being onboarded. It now keys on
`(tenantName, warehouse)`.

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
| Pool max size | 10 (from `application.properties:82`; was 2) | 5 default, per-tenant override in landlord config |
| Credentials | Env placeholder `${LANDLORD_DATASOURCE_PASSWORD}`, no default (`application.properties:68`; SBDEV-3175) — ⚠ corrected 2026-11-11, was "plain text" | Per-row in `TenantDbConfiguration` (landlord DB); read as-is by `createHikariPool` (`:197`), no decrypt step |
| Lifecycle | Always-on | Lazy create / 15-min-idle evict |

---

## 9. Secrets Handling

⚠ **Corrected 2026-11-11 — the paragraph below this one's first sentence was wrong.** Jasypt is **not** in `pom.xml`: it was removed deliberately (comment at `pom.xml:194-212`: `jasypt-spring-boot-STARTER 2.1.2` cannot auto-configure under Boot 3, so an `ENC(...)` value would have been used literally; pinned by `JasyptNotOnClasspathTest`). `grep -n 'ENC(' application.properties` → 0 hits.

Today:

- ~~`landlord.datasource.password` sits in plain text at `application.properties:41`.~~ ✅ Fixed (SBDEV-3175): `application.properties:68` is `${LANDLORD_DATASOURCE_PASSWORD}` with **no default**, so a missing value fails at startup (comment `:56-67`). ⚠ unverified 2026-11-11: that the variable is actually set as a stack-level env var on each deployment, and whether the pre-fix literal (committed 2025-12-28, `cc7cb40d` per the comment) was rotated.
- Per-tenant DB credentials sit in the `TenantDbConfiguration` table in plain text.

The per-tenant row credentials remain the open debt — landlord DB access exposes every tenant's DB password. Candidate for a dedicated ADR (the `pom.xml` comment names column/envelope encryption as the real fix).

---

## 10. Known Landmines

1. **ThreadLocal does not propagate.** `@Async`, `parallelStream`, raw `new Thread(...)`, `CompletableFuture.supplyAsync` — none inherit `TenantContext`, and virtual threads (now enabled, §6.2) don't change that. The `TenantAwareTaskDecorator` exists, is used manually in one job (`StockSummaryExportJob:464`) and is registered on exactly one `TaskExecutor` bean (`clubRunExecutor`, `ClubRunExecutorConfig:58`) — ⚠ corrected 2026-11-11 from "not registered as a bean (as of 2026-06-24)"; it is on no default / `@Async` executor. If you add async, either wire the decorator on the executor or call it manually **and** confirm the submitting thread holds a valid context at submit time.
2. **Null context falls through to landlord.** `determineTargetDataSource` returns the landlord DS when no tenant is set (`TenantDynamicRoutingDataSource.java:125-130`; was `:44`). A bug that clears the ThreadLocal mid-request will silently route subsequent writes to landlord until a mismatch surfaces downstream.
3. **Advisory locks break under PgBouncer transaction pooling.** `AdvisoryLockService.tryLock(...)` uses `pg_try_advisory_lock` — a **session-level** construct. Under PgBouncer's `pool_mode = transaction` (the typical choice), the lock vanishes when the transaction ends. Cron jobs would then run concurrently across replicas. Mitigations: run PgBouncer in `session` mode, switch to `pg_try_advisory_xact_lock`, or move to Redis / DynamoDB distributed locking.
4. **Prepared-statement cache vs PgBouncer transaction pooling.** `prepStmtCacheSize=250` per tenant pool assumes the same physical connection is reused across statements. Under transaction pooling, cached statements must be re-prepared on every connection → wasted round-trips. Tune `prepareThreshold=0` on the PgBouncer side or disable client-side cache if you migrate.
5. **No tenant-pool prewarming.** First request per tenant after restart (or after 15 min idle) pays pool-creation latency (~200–1000 ms). A cold restart during a high-tenant-count deploy is a thundering-herd risk.
6. **Unbounded `poolHolders` map** (was `tenantPools`). `ConcurrentHashMap` of tenant-key → `PoolHolder` (`HikariDataSource` + the `TenantDbConfiguration` it was built from, `:37-40`). Growth is bounded only by tenant count. If tenant count scales significantly, per-instance memory and total PostgreSQL connection count both grow linearly.
7. **Config refresh is async.** A new tenant in the landlord DB takes up to 5 min (default `wms.tenant.config.refresh-interval-ms`) to become routable. For faster rollouts, decrease the interval, or force it with `POST /actuator/tenantpool` (§7) — noting that the force-evict is **per-replica**, so a multi-replica deployment needs one call per replica. `/v3/tenant/health` validates that the config exists but does not refresh it. *(Corrected 2026-09-02, SBDEV-3192: this item used to claim "There is no push mechanism.")*
8. **`TenantFilter` lowercases both headers** (`tenantName.toLowerCase()`, `facilityCode.toLowerCase()`) before building the routing key. Any downstream code that compares against non-lowercased values breaks. The `TenantKeyBuilder` also implicitly lowercases by working on already-lowercased input.
9. **`/api/public/*` paths bypass tenant setup.** A new public endpoint that accidentally hits tenant-scoped data will fall through to landlord. Audit every new route under `/api/public/` for data-plane reach.
10. ~~**Landlord password in plain text** (`application.properties:41`).~~ ✅ Fixed 2026-11-11 reading (SBDEV-3175): env placeholder at `application.properties:68`; see §9 for what is still unverified.
11. **`BOOTSTRAP` tenant identifier.** `TenantIdentifierResolver` returns the literal string `"BOOTSTRAP"` when `TenantContext` is null. Queries routed to Hibernate during context-less code paths use this identifier — they may surface as "tenant not found" downstream, or (worse) succeed against the landlord schema via the `@Primary` fallback, depending on which EMF the path engages.
12. **`TenantPoolEvictor` does not check active work.** Eviction calls `HikariDataSource.close()` which drains gracefully, but a rare pathological case (very long-running single transaction ≥ 15 min idle in the middle) could interact badly with eviction. In practice transactions that long are themselves a bug, but worth keeping in mind.
13. **Tenant deactivation is TWO independent flags — flip BOTH or you get split-brain (SBDEV-2727).** A client is deactivated by setting `active = false`, but the flag lives on **two separate landlord tables**, each gating a different surface:
    - `tenant_discovery.active` → the **login/discovery** gate. `LandlordService.getTenantDiscoveryByKey` uses `findByKeyAndActiveTrue`, so an inactive row makes `/api/public/authConfig` return **404** → the Web/Mobile UI redirect to `/unknown-tenant` (pre-login, uncached — takes effect immediately).
    - `tenant_db_configuration.active` → the **request-path routing** gate. `getAllDbConfigurations` uses `findByActiveTrue`, so an inactive row never enters `TenantDbConfigCache` → `determineTargetDataSource` throws `TenantException` on a cache miss, and `TenantConfigLoader` calls `TenantDynamicRoutingDataSource.evictAbsentPools()` each 5-min refresh to force-close the deactivated tenant's live pool (≤1 cycle, not the 15-min idle evictor). The 8 cron jobs also enumerate via `findByActiveTrue`.

    **Split-brain if only one is flipped:** discovery-only (`tenant_discovery.active=false`) blocks *new* logins but any already-tokened session keeps routing until the db-config flag is also flipped; db-config-only blocks the API but the login page still resolves. Deactivate a client with the atomic both-table `UPDATE` in `db/landlord/L001__add_active_flag.sql`. Note the landlord schema is **not** Flyway-managed (`ddl-auto=none`) — L001 must be applied to every landlord DB before the JAR that reads `active` ships, or a fresh replica's config load fails and it serves an empty cache (all tenants 500; `TenantConfigLoader` now logs a loud startup banner for this case).

---

## 11. PgBouncer / Horizontal Scaling Considerations

Relevant to the active [PgBouncer connection-pool strategy](../../1-Projects/wms2/plan/260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md) and [horizontal scaling report](../../4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md):

| Current behavior | PgBouncer impact | Mitigation path |
|---|---|---|
| Per-tenant HikariCP client-side pool | Second layer of pooling in front of PgBouncer is fine — tune Hikari max downward since PgBouncer fans out to fewer backend connections | Lower per-tenant `maximumPoolSize`; rely on PgBouncer for backend rationing |
| `autoCommit=false` + Hibernate-managed TX | Compatible with `pool_mode = transaction` | No change |
| `prepStmtCacheSize=250` per pool | Wasted under transaction pooling (no statement persistence across txns) | Set JDBC `prepareThreshold=0` or clear client cache |
| `pg_try_advisory_lock` for cron mutex | Broken under transaction pooling | Use `pg_try_advisory_xact_lock` (tx-scoped, outlives the one tx), or switch to Redis locking |
| Per-request HTTP tenant filter | Unaffected — routing is app-layer | No change |
| `TenantDynamicRoutingDataSource.determineTargetDataSource` uses `computeIfAbsent` | Unaffected | No change |
| ThreadLocal context (virtual threads enabled) | Unaffected by PgBouncer. Virtual threads are **on** (`spring.threads.virtual.enabled=true`); the per-request `ThreadLocal` stays correct because each request runs start-to-finish on its own (virtual) carrier thread | Cross-thread paths (`@Async` / `parallelStream` / `new Thread`) still need explicit context propagation — `ScopedValue` is the structured-concurrency-friendly migration target but is not required for correctness today |
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
| 2026-07-26 | **§10.13 added — tenant `active`-flag deactivation & split-brain guard (SBDEV-2727, wms2-api PR #95)**. Verified: `LandlordService.getTenantDiscoveryByKey`→`findByKeyAndActiveTrue` and `getAllDbConfigurations`→`findByActiveTrue`; `TenantDynamicRoutingDataSource.evictAbsentPools()` + `TenantConfigLoader` call after `evictChangedPools()`; 8 cron jobs enumerate via `findByActiveTrue`; actuator `TenantPoolEndpoint` guard; manual DDL `db/landlord/L001__add_active_flag.sql`. Only §10.13 re-verified this pass. | Confirmed against `src/main/java/net/aim_ai/wms/landlord/**` + `schedulejob/**` | Code read (SBDEV-2727) |
| 2026-06-24 | **§6.2/§11 virtual-threads correction** (`application.properties:2` now `spring.threads.virtual.enabled=true` — doc previously claimed VTs off); `TenantAwareTaskDecorator` now used manually at `StockSummaryExportJob.java:186` (still not a `TaskExecutor` bean); §4.2 added `connectionInitSql` UTC session-TZ block (`TenantDynamicRoutingDataSource.java:95-105`, `resolveWarehouseTz` `:118-160`); cron table expanded to 8 jobs + `JobMetrics`/`JobMetricsConfiguration` infra; line-ref fixes: `autoCommit` `:83`, `computeIfAbsent` `:50`, `app.cron` `:113`, actuator probes `:85`, exposure list adds `prometheus` `:87`; `TenantAwareTaskDecorator.java` range `:1-47`; `TenantHealthController` delegation note. PgBouncer still NOT landed — §4.2/§10.3–4 hazards remain valid. | All edits confirmed against `src/main/java` + `src/main/resources` | Code read of v2/wms2-api src/main (SBDEV verify-docs refresh) |
| 2026-11-11 | **Full re-verification against `origin/develop` @ df30fa62 (wms2-api).** Read: `TenantFilter`, `TenantContext`, `TenantKeyBuilder`, `TenantIdentifierResolver`, `TenantDatabaseConfig`, `LandlordDatabaseConfig`, `TenantDynamicRoutingDataSource` (754 lines; all anchors re-pinned), `TenantConfigLoader`, `TenantPoolEvictor`, `TenantAwareTaskDecorator` + both usages, `SchedulingConfiguration`, all 11 `schedulejob/*Job` classes' entry points, `TenantHealthController`, `application.properties` (landlord pool, probes, cron, actuator), `pom.xml` Jasypt comment. | Standing facts confirmed (header `X-Tenant-ID` + `facility_code`; key = first4(tenant) + "-" + facility; short names use the full name). Corrected: landlord pool 2 → **10**; landlord password plain text → env placeholder; Jasypt claim (removed from pom); `tenantPools` → `poolHolders`; `/api/public/` branch does not set a null context; `resolveWarehouseTz` refuses the pool on failure; decorator now on one `TaskExecutor` bean; 8 → 11 job classes; ~40 line anchors. **Not re-verified:** live DB contents, deployed env vars, PgBouncer plan state, whether the 3 new jobs' lock shapes match the diagram beyond the entry-point greps. | Code read; Claude (executor) |

**Re-verify every 60 days.** Next due: **2027-01-10** — or sooner if the PgBouncer plan lands, since §4.2 hard-coded values and §10 items 3/4 will all change.
