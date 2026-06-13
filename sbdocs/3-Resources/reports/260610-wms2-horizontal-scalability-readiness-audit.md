---
title: "WMS2 Horizontal Scalability Readiness Audit (June 2026)"
type: investigation
status: concluded
version: "v2"
scope: "v2/wms2-api — multi-replica readiness: concurrency locks, transaction boundaries, multi-tenant routing, JVM-local state, infra gaps"
owner: "Nam Park"
created: "2026-06-10"
updated: "2026-06-10"
last_verified: "2026-06-10"
verified_by: "Claude (Fable 5) + manual spot-checks"
related:
  - "4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md"
  - "3-Resources/architecture/wms2-transaction-osiv-boundary-map.md"
  - "3-Resources/architecture/wms2-scheduled-jobs-catalog.md"
  - "3-Resources/architecture/wms2-tenant-routing-datasource-topology.md"
  - "3-Resources/architecture/wms2-oms-integration-map.md"
  - "3-Resources/reports/260507-picking-lock-ordering-inconsistency.md"
tags:
  - investigation
  - report
  - horizontal-scaling
  - concurrency
  - multi-tenancy
---

# WMS2 Horizontal Scalability Readiness Audit (June 2026)

**Topic:** v2/wms2-api multi-replica readiness | **Version:** v2
**Started:** 2026-06-10 | **Investigator:** Nam Park (Claude-assisted)
**Status:** concluded

---

## 1. Context & Trigger

wms2-api is designed to run as **N identical replicas** behind a load balancer. Each client warehouse has a **dedicated PostgreSQL database**; a **landlord database** holds tenant directory data including per-tenant connection details; requests carry `tenant_name` + `facility_code` headers that drive dynamic datasource routing (4-char routing key). The user requested an audit of whether the codebase is well positioned for this environment, focused on concurrency locks, transaction boundaries, and multi-tenant scalability.

A prior assessment exists: [260313-WMS_V2_Horizontal_Scaling_Concurrency_Report](../../4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md) (archived 2026-05-22), which drove two implementation phases (8 + 3 code items marked DONE) and left three open items: GAP D (per-tenant pool sizing), Phase 3 (cross-replica cache), GAP F (JWT decoder cache documentation). This audit is therefore a **regression re-validation plus fresh sweep** over the ~3 months of code landed since (UTC migration, transactional outbox SBDEV-2221/2238, REST idempotency SBDEV-2222, plpgsql ports, club-batch hardening).

---

## 2. Questions

1. Are all code fixes claimed DONE in the March 2026 report still present in today's code (regression check)?
2. Is the landlord/tenant routing layer (dynamic datasource, Hikari pools, TenantContext) replica-safe, and is the connection math sound?
3. Is there remaining or newly-introduced JVM-local state (caches, statics, in-memory guards) whose correctness breaks when >1 replica serves the same tenant DB?
4. Are transaction boundaries and locking correct on the hot mutation paths (stock, order release, picking, replenishment, sequences) under multi-replica concurrency?
5. What infrastructure/deployment gaps remain before adding replicas (cron strategy, pool sizing, Redis, PgBouncer)?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| H1 | **Nothing is wrong**: all March fixes survived, no new replica-unsafe code; the app is code-ready and only deployment work remains | medium | Plans since March (outbox, idempotency, advisory locks) all *added* multi-replica safety; team has been disciplined |
| H2 | New code since March introduced replica-unsafe JVM-local state | medium | 3 months of heavy feature work (UTC migration, outbox, club batches) is a lot of surface |
| H3 | Residual transaction/locking defects exist on hot paths that only surface at multi-replica load | medium | The March report itself found late gaps (GAP A–G) on its second pass |
| H4 | The blocking gaps are infrastructure (pool sizing, cache backend, PgBouncer), not code | medium-high | GAP D and Phase 3 were explicitly deferred as deployment tasks |

---

## 3.5 Sources In Scope (enumeration)

**Code (v2/wms2-api, `src/main/java/net/aim_ai/wms/`):**

| Area | Files |
|---|---|
| Tenant routing | `landlord/config/`: TenantDynamicRoutingDataSource, TenantPoolEvictor, TenantContext, TenantFilter, TenantKeyBuilder, TenantDbConfigCache, TenantAuthConfigCache, TenantConfigLoader, MultiTenantJwtDecoder, TenantAwareTaskDecorator, LandlordDatabaseConfig, TenantDatabaseConfig |
| Scheduled jobs | `schedulejob/`: OrderReleaseJob, ReplenishOrderJob, CleanUpOldMessagesJob, StockSummaryExportJob, ReleaseExpiredPickingOrdersFromUserJob, StaleClubBatchCleanupJob, RestIdempotencyCleanupJob, OutboxDispatcherJob, SchedulingConfiguration, SchedulingEnablementConfig; `service/AdvisoryLockService` |
| Hot mutation paths | StockunitBusinessService, ReleaseOrderJobService, PickingorderBusinessService, MobilePickingService, MobilePalletizingService, MobileReplenishService, UnitloadBusinessService, ReplenishOrderJobService, ReplenishGeneratorService, CustomerorderBatchService, BillofladingService, SequenceTransactionService, BasicService |
| Caching / state | config/CacheConfig, ItemdataService, ClientService, LocationService, KeycloakService, NameTypeService |
| OMS integration | OmsNotificationService, OutboxService, OutboxDispatchService, MessageService, HttpRestService |
| Idempotency | RestIdempotencyService, IdempotencyFilter |
| Exception handling | exceptions/RestExceptionHandler |
| Config | application.properties, pom.xml |

**Docs:** wms2-transaction-osiv-boundary-map (`last_verified` 2026-06-01), wms2-scheduled-jobs-catalog (2026-06-01), wms2-tenant-routing-datasource-topology (2026-05-09), wms2-oms-integration-map; prior reports 260313 (archived), 260507 (picking lock ordering), 260522 (REST idempotency).

**Pattern greps run:** `@Transactional` (185 hits incl. javadoc), bare `@Transactional` (no manager qualifier), `REQUIRES_NEW` (28 + 1 programmatic), `@Lock(PESSIMISTIC_WRITE)` / native `FOR UPDATE` (15 + 1), `@Scheduled` (10), `@Cacheable`/`@CacheEvict`, `static.*Atomic|static.*Map|ConcurrentHashMap`, `@Async` (none), `parallelStream` (none in tenant-data paths), `new Thread` (1).

---

## 4. Method

1. Read the archived 260313 report and extracted its 13 claimed-DONE items + 3 open items as the regression baseline.
2. Four parallel specialist agents: (a) regression verification of all 13 items; (b) landlord/tenant routing layer audit; (c) JVM-local-state sweep (statics, caches, jobs, async, disk, dedup); (d) architect-level transaction-boundary and locking audit cross-checked against `wms2-transaction-osiv-boundary-map.md`.
3. **Manual spot-verification of every load-bearing or surprising agent claim** before accepting it (this pass refuted three agent findings — see §5.8; agent evidence was not taken at face value).
4. Cross-referenced architecture docs for drift (jobs catalog, boundary map, topology doc).

No DB queries or load tests were run — this is a code-and-docs audit. Load-test validation is listed in §9 Open Questions.

---

## 5. Evidence

### 5.1 All 13 March-2026 fixes are still present — no regressions

**Source:** code re-verification, spot-checked.
**Supports:** H1. **Contradicts:** —

| # | Item (March report ref) | Current evidence |
|---|---|---|
| 1 | 409 handlers for lock exceptions (GAP A) | `RestExceptionHandler.java:144-160` — `@ExceptionHandler(ObjectOptimisticLockingFailureException.class)` / `(PessimisticLockingFailureException.class)` → `HttpStatus.CONFLICT` |
| 2 | No silent `-1` on sequence exhaustion (5b) | `BasicService.java:165-171` — `throw new BusinessException("BusinessException.SequenceExhausted", …)` |
| 3 | `@EnableScheduling` unconditional (GAP E) | `SchedulingEnablementConfig.java:15-18` — separate `@Configuration @EnableScheduling`; `TenantPoolEvictor` + `TenantConfigLoader` run on **all** replicas |
| 4 | `changeAmount` locked + tenant TM (item 2) | `StockunitBusinessService.java:396` `@Transactional(value = "tenantTransactionManager"…)`, `:399 findByIdForUpdate`, `:403 entityManager.refresh` |
| 5 | Keycloak cache thread-safe (GAP B) | `KeycloakService.java:61-64` — `Caffeine.newBuilder().expireAfterWrite(15, TimeUnit.MINUTES).maximumSize(500)` |
| 6 | Cache TTLs reduced (item 7) | `CacheConfig.java:33-38` — sysprops 2 min; clients/locations/itemdata 5 min |
| 7 | TenantContext cleared in finally (item 8) | `SchedulingConfiguration.java:108-109,155-156` — `finally { TenantContext.clear(); }` |
| 8 | `bolToClose` documented; DB lock real guard (item 1) | `BillofladingService.java:154-157` comment + `:296 findByIdForUpdate(bolId)` (5 s lock timeout on `BillofladingRepository:26`) |
| 9 | Sequence pessimistic lock, maxTries 5 (item 5) | `SequenceTransactionService.java:28 findByClassnameForUpdate` + `BasicService.java:134 final int maxTries = 5` |
| 10 | Advisory locks on jobs (item C) | `AdvisoryLockService.java` — **all 8 business jobs** guarded, lock IDs 100001L–100008L (incl. 3 jobs added since March: StaleClubBatchCleanup, RestIdempotencyCleanup, OutboxDispatcher) |
| 11 | Release stock candidates locked (item 3) | `ReleaseOrderJobService.java:118 findByIdForUpdate(orderId)`; `StockunitRepository.java:110-111` native `FOR UPDATE OF stockunit` |
| 12 | Itemdata eviction tenant-scoped (NEW-2b) | `ItemdataService.java:60-65` — `@Caching(evict = …)` with per-key eviction; `allEntries=true` **gone** |
| 13 | JWT decoder limitation documented (GAP F) | ~~unbounded/never-evicted~~ **FIXED 2026-06-10** — Caffeine `expireAfterWrite(24h)` + `maximumSize(200)`, TTL-only ([PR #41](https://github.com/SiteBossInc/wms2-api/pull/41), 260610 plan Phase B) |

### 5.2 Redis cache backend now exists in code — activation is a deployment decision

**Source:** `CacheConfig.java:30` `@Profile("!redis")` Caffeine manager; `CacheConfig.java:48-66` `@Profile("redis")` `RedisCacheManager` with per-cache TTLs (sysprops 2 min, others 5 min, `GenericJackson2JsonRedisSerializer`); `pom.xml:181` `spring-boot-starter-data-redis`. Verified directly.
**Supports:** H1, H4.
**Observation:** The March report's "Phase 3: Redis cache migration" is **code-complete** — a Redis-backed `CacheManager` ships behind the `redis` Spring profile. Without `SPRING_PROFILES_ACTIVE=redis`, production replicas fall back to JVM-local Caffeine: cross-replica staleness is then bounded at 2–5 min by TTL (a deliberate March mitigation), so the failure mode is *stale reads*, not corruption — itemdata/locations writes on replica A are visible on replica B only after TTL expiry. The `clients` cache has `@Cacheable` (`ClientService.java:53,100`) but **no `@CacheEvict` anywhere** (verified by grep) — acceptable only because client rows change rarely and TTL bounds it; with Redis enabled the gap closes structurally.

### 5.3 Tenant routing layer is replica-safe; pool math (GAP D) is still the open deployment item

**Source:** `landlord/config/*`, `application.properties`. Agent-audited, key lines spot-checked.
**Supports:** H1 (code), H4 (infra).

- **Pool creation is race-safe:** `TenantDynamicRoutingDataSource.java:50` uses `tenantPools.computeIfAbsent(tenantKey, …)` — atomic per key.
- **Pool sizing:** per-tenant Hikari `maximumPoolSize = tc.getMaxPoolSize() != null ? tc.getMaxPoolSize() : 5` (`:77`), entity default `maxPoolSize = 2` (`TenantDbConfiguration.java:47`), `minIdle` 0→1, `maxLifetime` 30 min, leak detection 60 s. Landlord pool fixed at **2** (`application.properties:45`).
- **Connection math (GAP D, unchanged since March):** `total ≈ N_replicas × (2 landlord + Σ tenant maxPoolSize)`. Example 3 replicas × 5 tenants × 5 = 75 + 6 = **81** against PostgreSQL default `max_connections=100`. No PgBouncer deployed. **This remains a deployment task — no code change required, but it must be done before scaling N.**
- **Eviction runs everywhere:** `TenantPoolEvictor.java:30` `@Scheduled(fixedDelay 5 min)` evicts pools idle > 15 min (`wms.tenant.pool.idle-ms=900000`); because `@EnableScheduling` is unconditional (§5.1 item 3), this runs on every replica. Unlocked but idempotent.
- **Tenant config refresh:** `TenantConfigLoader.scheduledRefresh()` (`:57`, 5-min fixed delay, all replicas) reloads the landlord directory into `TenantDbConfigCache` (ConcurrentHashMap). New-tenant discovery latency ≤ 5 min per replica.
- **Stale pools after credential rotation (MEDIUM, operational):** rotating a tenant's DB password in the landlord DB does **not** rebuild an active pool — the old `HikariDataSource` lives until 15-min idle eviction or restart. For a busy tenant the pool may never go idle. Needs a documented rotation runbook step (evict-then-rotate or rolling restart).
- **TenantContext hygiene:** ThreadLocal (`TenantContext.java:18`); `TenantFilter.java:51-55` clears in `finally`; all 8 jobs set/clear per tenant in try/finally. **Null result:** no `@Async` usage in the codebase; `TenantAwareTaskDecorator` exists and is correctly used for the one hand-rolled thread (`StockSummaryExportJob.java:186`), but it is **not registered globally** on the scheduler/executor — a latent trap if `@Async` is ever introduced (LOW, latent).
- **Header validation is minimal:** `TenantFilter.java:40-49` only null-checks `X-Tenant-ID` + `facility_code`, lowercases, and builds the key (`TenantKeyBuilder.java:18-26`, `first4(tenant)-facilityCode`). Unknown tenants fail later at `dbConfigCache.get → TenantException`. Acceptable; not a scaling issue.

### 5.4 Scheduled jobs: all 8 business jobs cross-replica single-flight via landlord-DB advisory locks

**Source:** `AdvisoryLockService.java:46,56-59` (locks taken on a **landlord** datasource connection — a genuinely shared mutex across all replicas regardless of tenant), lock IDs 100001–100008; e.g. `OrderReleaseJob.java:67 tryLock` / `:119 unlock` in finally. Jobs catalog (`last_verified` 2026-06-01) matches code — **no drift**: 8 business jobs (advisory-locked) + 2 infra jobs (TenantConfigLoader, TenantPoolEvictor — unlocked by design, idempotent, must run on all replicas).
**Supports:** H1.
**Observation:** This resolves the March report's NEW-1 (🔴 jobs run on all replicas) *in code*, not just by the single-cron-replica deployment convention: even if `app.cron=true` were misconfigured on several replicas, `pg_try_advisory_lock` on the shared landlord DB serializes each job. `ReplenishOrderJob.java:30`'s `static AtomicBoolean RUNNING` is now only a single-JVM fast-fail layered in front of the advisory lock — harmless.
**Landmine (future):** PostgreSQL advisory locks are **session-level**. If PgBouncer is ever introduced with `pool_mode=transaction`, every advisory-lock guard breaks silently (already flagged in jobs catalog §7 item 1). PgBouncer adoption must use `pool_mode=session` or move the mutex elsewhere.

### 5.5 Hot mutation paths: pessimistic locking is consistent; no unguarded TOCTOU remains

**Source:** architect audit cross-checked against `wms2-transaction-osiv-boundary-map.md`; key sites spot-verified.
**Supports:** H1. **Contradicts:** H3 (partially).

- **Stock mutations:** `changeAmount` (`:396-428`) and `changeReservedAmount` (`:434-463`) both re-fetch under `findByIdForUpdate` + `entityManager.refresh` and validate on the locked row — the March TOCTOU (4.2/4.3) is closed. `transferStockToUnitLoad` (`:182-361`, SBDEV-2229) documents and implements a stable 6-entity lock order.
- **Order release:** cross-replica single-flight via advisory lock (§5.4); per-order `REQUIRES_NEW` tx (`ReleaseOrderJobService.java:110`) with `findByIdForUpdate(orderId)` (`:118`); overstock candidates locked via native `FOR UPDATE OF stockunit` (`:595`). The **fixed-assignment branch** still reads candidates from an unlocked pre-built map (`:280,:295,:578`), but the downstream `changeReservedAmount` re-validates under lock — worst case is a thrown `CANNOT_RESERVE_MORE_THAN_AVAILABLE` and release on a later cycle, **not** over-reservation (MEDIUM-low, behavioral not integrity).
- **Pessimistic-lock inventory:** 15 `@Lock(PESSIMISTIC_WRITE)` repository methods + 1 native `FOR UPDATE` + 1 `FOR UPDATE SKIP LOCKED` (outbox claim). **Null results:** no `PESSIMISTIC_READ` anywhere; no accidental `@Transactional` self-invocation (the `CustomerorderBatchService.runClubLine:807-818` and `ReplenishmentOrderMaintenanceService` self-proxy patterns are intentional and documented); **zero bare `@Transactional` in tenant-data services** — every one carries `value="tenantTransactionManager"` (the bare ones that exist are `LandlordService` — correct, landlord TM is `@Primary` — and repository fragments, which inherit the tenant TM from `@EnableJpaRepositories(transactionManagerRef=…)`).
- **Lock ordering:** the confirmPick (CO→PO) vs processPick (PO→implicit CO) AB/BA pair from report 260507 still exists; that report's verdict was **Monitor** by design and remains valid (deadlock detector aborts in 1 s; reachable only on multi-tote club orders). Its recommended cross-reference comment at `MobilePickingService:392` was never applied (LOW). **Null result:** no `lock_timeout` configured anywhere — non-deadlock lock waits block until Hikari's 30 s connection timeout, which under contention converts lock waits into pool pressure.
- **HTTP-inside-transaction:** SBDEV-2214/2215 are archived and verified — `CustomerorderBatchService`/`AdviceService` use `outboxService.enqueue` (in-tx, atomic with state) and `OutboxDispatchService` POSTs with **no transaction held** (`:83-85` documented); `OmsNotificationService` only fires post-commit or, in non-transactional contexts, synchronously (`OmsNotificationService.java:65-99`). ~~One residual: `MessageService.sendMessage:75` REQUIRES_NEW holding a connection across `httpRestService.post:123`~~ — **CORRECTED 2026-06-10 (same day):** this finding was wrong; the agent conflated two methods. `MessageService.java:75` is `createServiceLog` — `REQUIRES_NEW` but **persist-only, no HTTP**. The POST at `:123` is in `resendMessage` (`:114`), which carries **no** `@Transactional` — the OMS round-trip already runs with no tenant connection held (each `createMessage` audit row opens its own short REQUIRES_NEW tx). There is no `sendMessage` method. **Null result confirmed: no `httpRestService` call anywhere in wms2-api executes inside an open transaction.** The only residual value is a regression guard (test/ArchUnit rule) so this safety can't silently regress.

### 5.6 HIGH — the dominant remaining risk: REQUIRES_NEW nesting × small per-tenant pools

**Source:** verified directly. 28 annotation sites + 1 programmatic (`MobilePickingService:159`).
**Supports:** H3, H4.
**Observation:** A thread that suspends an open tenant transaction and opens a `REQUIRES_NEW` one holds **two pooled connections simultaneously**. Verified chains:

- `ReplenishOrderJobService.refillFixedLocationAssignment` (`:264`, REQUIRES_NEW) → cross-bean → `ReplenishGeneratorService.refillSingleFixedLocation` (`:96-97`, REQUIRES_NEW) — depth 2 confirmed (both proxies fire; the outer tx is suspended, not shared). `ReplenishGeneratorService.calculateOrder:118` / `createOrderFromTemplate:210` are also REQUIRES_NEW; if reached from an open tx the same multiplication applies.
- Sequence allocation: `BasicService.getNextSequenceNumber` → `SequenceTransactionService:23` (REQUIRES_NEW, pessimistic lock on `los_sequencenumber`) is called from inside open business transactions across the codebase (`BillofladingService:737`, `OrderMonitorViewService:180`, `ParcelMonitorViewService:113,268`, picking/tote paths) — i.e., **most label-generating business transactions briefly hold 2 connections**.

**The math:** with the `TenantDbConfiguration` entity default `maxPoolSize=2`, two concurrent depth-2 threads on the same tenant can each hold 1 connection while waiting for a 2nd → classic Hikari starvation deadlock that only resolves via the 30 s `connectionTimeout`. The code-side fallback default of 5 (`TenantDynamicRoutingDataSource:77`) tolerates this only up to ~4 concurrent depth-2 threads per tenant per replica. This is the March GAP D restated with a sharper mechanism: **pool sizing must account for connections-per-thread ≥ 2, not 1** — `maxPoolSize ≥ 2 × peak concurrent request/job threads per tenant per replica` (or the replenish chain flattened). Note the irony: adding replicas *reduces* per-replica thread pressure on a tenant but multiplies total connections — both ends of GAP D squeeze the same budget.

### 5.7 Replica-safe by construction: outbox, REST idempotency, exception surface

**Source:** verified.
**Supports:** H1.

- **Transactional outbox (SBDEV-2221/2238):** `OutboxService.enqueue` joins the caller's tenant tx (atomic with state change); `OutboxMessageRepository:47` claims with native `FOR UPDATE SKIP LOCKED`; dispatcher job advisory-locked (100008). This is the **textbook multi-replica design** — any replica can enqueue; exactly one dispatches; claims don't collide.
- **REST inbound idempotency (SBDEV-2222):** dedup state in the tenant DB (`rest_idempotency`, native `INSERT … ON CONFLICT DO NOTHING` via `RestIdempotencyService.tryClaim`), not in JVM memory — replays land correctly on **any** replica. Cleanup job advisory-locked (100007).
- **Lock-contention UX:** global 409 handlers (§5.1 item 1) mean increased multi-replica contention degrades to retryable 409s, not 500s.

### 5.8 Agent findings REFUTED on manual verification (recorded so they don't resurface)

**Source:** manual spot-checks. **Supports:** H1 (and method hygiene).

1. **"`scanPallet` drops the OMS palletized notification" — FALSE.** `MobilePalletizingService.java:230-245`: when no tx synchronization is active the `else` branch calls `manageOrderService.customerOrderPalletized(...)` synchronously; `OmsNotificationService.sendAfterCommit:85-99` likewise falls back to immediate `doSend`. Nothing is dropped. Residual truth: `scanPallet` is non-transactional, so order-state update (`:217`, via correctly-used OptimisticLockRetry in auto-commit) and unit-load transfer are not atomic with each other — pre-existing, LOW.
2. **"`NameTypeService` is a CRITICAL replica-unsafe singleton" — FALSE.** `NameTypeService.java:20` is `public class  NameTypeService` — a plain POJO, **no** `@Service`, instantiated via constructors; the only reference in main/test trees is its own unit test. This also closes March GAP G ("verify usage pattern") → per-instance usage, no issue; effectively dead code in main.
3. **"1 of 161 `@Transactional` is unqualified/suspect" — misleading.** All bare `@Transactional` occurrences are by-design (`LandlordService` on the `@Primary` landlord TM; repository fragments inheriting `tenantTransactionManager` from `@EnableJpaRepositories`). The boundary map's "16 of 132 unqualified" claim is **stale** — current count in tenant-data services is zero.

### 5.9 Documentation drift found

**Source:** cross-reference pass. **Supports:** — (housekeeping).

- `wms2-transaction-osiv-boundary-map.md` (§3/§10.1) still claims "16 of 132 unqualified `@Transactional`" → actual **0**; §8.2 lists 12 pessimistic-lock methods → actual **15 + 1 native + 1 SKIP LOCKED**; `OmsNotificationService.registerSynchronization` line ref shifted (55 → 72).
- Jobs catalog and tenant-topology doc: **no drift** (verified 2026-06-01 / 2026-05-09).

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H1 | Nothing is wrong in code: March fixes intact, new subsystems (outbox, idempotency) are replica-safe by construction | **high** (primary verdict) | §5.1 13/13 present; §5.4 advisory locks; §5.5 locking consistent; §5.7; three scare-findings refuted §5.8 |
| H4 | Blocking gaps are infrastructure/deployment, not code | **high** | §5.3 GAP D pool math; §5.2 Redis profile exists but needs activation; §5.4 PgBouncer landmine |
| H3 | Residual transaction/locking defects at multi-replica load | **medium** — narrowed to one HIGH mechanism + 4 MEDIUM hygiene items | §5.6 REQUIRES_NEW nesting × pool size; §5.5 MessageService HTTP-in-tx, inert OptimisticLockRetry, unlocked fixed-assignment branch |
| H2 | New code since March introduced replica-unsafe state | **low — rejected** | Sweep found none: new jobs all advisory-locked, outbox/idempotency DB-backed, no new statics/caches with correctness dependence (§5.4, §5.7; null results §5.3) |

---

## 7. Verdict

**wms2-api is well positioned for horizontal scaling — the code is multi-replica-safe for correctness, and the remaining work is one connection-budget engineering task plus deployment configuration.** All 13 fixes from the March 2026 assessment are intact with no regressions; everything built since (transactional outbox, REST idempotency, three new cron jobs) follows replica-safe patterns (DB-backed state, landlord-DB advisory locks, `FOR UPDATE SKIP LOCKED`). Hot stock/release/picking paths consistently use pessimistic re-fetch-under-lock with correct `tenantTransactionManager` boundaries; cross-replica job single-flight no longer depends on the single-cron-replica deployment convention. Data corruption from running N replicas against the same tenant database is **not** an expected failure mode.

What stands between today and confidently adding replicas is capacity, not correctness: (1) **HIGH** — `REQUIRES_NEW` nesting means hot threads hold 2 tenant connections at once, so per-tenant `maxPoolSize` (entity default **2**) must be sized as ≥ 2 × peak concurrent threads per tenant per replica, while total connections (N × Σ pools + landlord) stay under PostgreSQL `max_connections` — the March GAP D, now with a sharper mechanism; (2) production must run with `SPRING_PROFILES_ACTIVE=redis` (the Redis cache manager is code-complete) or accept 2–5 min cross-replica cache staleness; (3) three MEDIUM hygiene items (inert OptimisticLockRetry call sites, JWT-decoder unbounded cache/key-rotation, credential-rotation stale pools) and the standing PgBouncer/advisory-lock incompatibility constraint. *(A fourth item — "MessageService HTTP-in-tx" — was retracted same-day; see §5.5 correction.)*

**Confidence: high** (code-level claims spot-verified; load behavior not empirically tested — see §9).

---

## 8. Recommendation

- [x] **Fix later** — sprint-scheduled hardening; none of it blocks the first multi-replica rollout if pool sizing is done first.
- [ ] Fix now / Do NOT fix / Monitor / Investigate further

Priority-ordered backlog (items 1–2 before adding replicas; 3–7 next sprint(s)):

| # | Item | Type | Severity |
|---|------|------|----------|
| 1 | **GAP D finale:** per-tenant `maxPoolSize` sizing formula accounting for 2-connections-per-thread (§5.6), landlord `max_connections` audit, alerting on Hikari `pending` | Deployment + 1 config default | HIGH |
| 2 | Enforce `SPRING_PROFILES_ACTIVE=redis` in production manifests; startup log/probe asserting cache backend | Deployment | HIGH |
| 3 | ~~Migrate `MessageService.sendMessage` off HTTP-inside-REQUIRES_NEW~~ **Retracted 2026-06-10** (finding was wrong — `resendMessage` already POSTs with no tx held; see §5.5). Replaced by: regression guard — **Done 2026-06-10**, `HttpInTransactionArchTest` via [PR #42](https://github.com/SiteBossInc/wms2-api/pull/42) | Code (test-only) | ~~LOW~~ done |
| 4 | Remove/relocate inert `OptimisticLockRetry` calls (`confirmPick:580`, `transferUnitLoadToLocation:176`) + dead injection in `MobileReplenishService`; they mask real conflict handling | Code | MEDIUM |
| 5 | ~~`MultiTenantJwtDecoder` Caffeine TTL~~ **Done 2026-06-10** — TTL-only (rebuild-on-exception deliberately deferred, see plan §10) via [PR #41](https://github.com/SiteBossInc/wms2-api/pull/41) | Code | ~~MEDIUM~~ done |
| 6 | Credential-rotation runbook: evict tenant pool (or rolling restart) when rotating tenant DB credentials; consider config-hash check in `TenantConfigLoader` to auto-evict changed pools | Runbook (+ optional code) | MEDIUM |
| 7 | Set a PostgreSQL `lock_timeout` (per-tx or datasource-level) so lock waits fail fast instead of consuming pool slots for 30 s; refresh boundary-map stale counts (§5.9); add ArchUnit rule banning bare `@Transactional` in `net.aim_ai.wms.service.*` | Code/docs | LOW-MEDIUM |

Constraint to keep standing: **no PgBouncer in `pool_mode=transaction`** while advisory locks guard the cron jobs.

~~Draft items 3–5 via `wms-feature-plan`~~ **Done 2026-06-10:** [260610-wms2-multi-replica-hardening](../../1-Projects/wms2/plan/260610-wms2-multi-replica-hardening.md) (ralplan-approved; Phase A = item 4, Phase B = item 5, Phase C = item 3's replacement regression guard) with acceptance script `sbdocs/9-System/scripts/verify-260610-wms2-multi-replica-hardening.sh`. Items 1–2/6 are deployment/runbook work outside the plan skills.

---

## 9. Open Questions

- **Empirical load validation:** no 2-replica-same-tenant load test has been run against the current code. The March report's Phase 3 validation step is still outstanding; a soak test exercising concurrent release + picking + replenish on one tenant DB would convert §7's "high confidence" into demonstrated behavior.
- **Actual production tenant pool values:** the landlord `tenant_db_configuration` rows may override the entity defaults audited here; the GAP D sizing exercise must read the live landlord data (the `maxPoolSize=2` entity default is what ships when a row leaves it null — worth checking how many rows do).
- **Cron replica failover:** advisory locks make duplicate cron replicas safe, but if the single `app.cron=true` replica dies, jobs silently stop. Is a second cron-enabled replica (now safe thanks to advisory locks) the intended HA answer? Needs a deployment decision.
- **Redis operational readiness:** is a Redis instance provisioned per environment, and is cache-serializer compatibility (`GenericJackson2JsonRedisSerializer` vs entity classes) integration-tested? (Cached values must survive serialization round-trips — Caffeine never exercised this.)

---

## 10. References

- **Prior reports:** [260313-WMS_V2_Horizontal_Scaling_Concurrency_Report](../../4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md) (baseline, archived); [260507-picking-lock-ordering-inconsistency](260507-picking-lock-ordering-inconsistency.md) (Monitor verdict reaffirmed); [260522-wms2-rest-idempotency-without-jwt-options](260522-wms2-rest-idempotency-without-jwt-options.md)
- **Architecture docs:** wms2-transaction-osiv-boundary-map (drift noted §5.9), wms2-scheduled-jobs-catalog, wms2-tenant-routing-datasource-topology, wms2-oms-integration-map
- **Plans (archived, verified in code):** SBDEV-2214, SBDEV-2215, SBDEV-2221, SBDEV-2222, SBDEV-2228, SBDEV-2229, SBDEV-2234, SBDEV-2237, SBDEV-2238 family
- **Key code:** `landlord/config/TenantDynamicRoutingDataSource.java`, `service/AdvisoryLockService.java`, `service/StockunitBusinessService.java`, `service/job/ReleaseOrderJobService.java`, `service/OutboxService.java` / `service/job/OutboxDispatchService.java`, `service/RestIdempotencyService.java`, `config/CacheConfig.java`, `service/MessageService.java`, `landlord/config/MultiTenantJwtDecoder.java`

---

## 11. Verification Log

| Date | What was re-checked | Result | Checked by |
|------|---------------------|--------|------------|
| 2026-06-10 | All 13 March-2026 fix items against current code | 13/13 present, no regressions | Claude (4-agent audit + manual spot-checks) |
| 2026-06-10 | Three agent-reported "critical" findings (scanPallet notification, NameTypeService, unqualified @Transactional) | All three refuted on manual read (§5.8) | Nam Park / Claude |
| 2026-06-10 | Backlog item 3-replacement (HTTP-in-tx ArchUnit guard) implemented — failure demo verified | Phase C [PR #42](https://github.com/SiteBossInc/wms2-api/pull/42) commit c4a7579; verify Phase C 3/3 | Nam Park / Claude |
| 2026-06-10 | Backlog items 4 (inert OptimisticLockRetry) and 5 (JWT decoder cache) implemented | Phase A [PR #40](https://github.com/SiteBossInc/wms2-api/pull/40) commit 8864f5f; Phase B [PR #41](https://github.com/SiteBossInc/wms2-api/pull/41) commit e04ced2; verify script A 9/9 + B 8/8 | Nam Park / Claude |
| 2026-06-10 | §5.5 Finding D ("MessageService.sendMessage HTTP inside REQUIRES_NEW") during plan drafting | **Retracted** — agent conflated `createServiceLog:75` (persist-only REQUIRES_NEW) with `resendMessage:114` (non-transactional HTTP). No HTTP call in wms2-api runs inside an open tx. §5.5, §7, §8 corrected | Nam Park / Claude |

---

## Appendix — Completeness checklist (skill gate)

| # | Concern | Considered? |
|---|---|---|
| 1 | In-scope sources enumerated | ✓ §3.5 |
| 2 | "Nothing is actually wrong" hypothesis | ✓ H1 (and it won) |
| 3 | Primary evidence per hypothesis | ✓ file:line quotes throughout §5 |
| 4 | Confidence per hypothesis | ✓ §3, §6 |
| 5 | Null results documented | ✓ §5.3 (no @Async), §5.5 (no PESSIMISTIC_READ, no self-invocation bug, no lock_timeout, zero bare @Transactional in tenant services), §5.8 (refutations) |
| 6 | v1/v2 deltas | no — v1 out of scope by request; v1 baseline (1 replica/warehouse) summarized in 260313 §1 |
| 7 | Cross-references to related reports/plans | ✓ §10 |
| 8 | Open questions populated | ✓ §9 (4 items) |
| 9 | Recommendation picks exactly one | ✓ Fix later |
| 10 | Downstream verify-script expectation noted | ✓ §8 closing paragraph |
