---
title: "WMS v2 — Transaction & OSIV Boundary Map"
type: architecture
status: active
version: v2
scope: transactions
owner: Nam Park
created: 2026-04-19
updated: 2026-08-14
last_verified: 2026-06-01
verified_by: code read of v2/wms2-api src/main at commit HEAD
related:
  - ../workflows/wms2-replenish-workflow.md
  - ../../4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md
  - ../../1-Projects/wms2/plan/260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md
  - ../../4-Archieves/wms2/plan/260424-WMS_OSIV_Disabled_Audit.md
  - ../../4-Archieves/wms2/plan/260424-CONCURRENCY_FIX_PLAN.md
  - ../../4-Archieves/wms2/plan/260424-TRANSACTION_MANAGER_FIX_PLAN.md
  - ../../4-Archieves/wms2/plan/260401-replenish-stockunit-optimistic-lock-debug-plan.md
  - ../../4-Archieves/wms2/plan/260331-recalculate-orders-stale-entity-debug-plan.md
  - ../../4-Archieves/wms2/plan/260331-cron-job-autoflush-optimistic-lock-debug-plan.md
  - ../../4-Archieves/wms2/plan/260424-connection-pool-exhaustion-fix-plan.md
tags:
  - architecture
  - transactions
  - osiv
  - multi-tenancy
  - concurrency
  - wms2
---

# WMS v2 — Transaction & OSIV Boundary Map

**Scope:** Cross-cutting transaction & locking behavior in `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19 (code read against `src/main/java`)

---

## 1. Overview

`wms2-api` runs with OSIV **disabled** and uses **two JPA transaction managers** — one per logical datasource. The landlord manager is marked `@Primary`, which makes it the default for any bare `@Transactional` and creates the single biggest landmine in the codebase: a tenant-data operation without an explicit manager qualifier will silently route to the wrong DB. Retries on optimistic-lock collisions are handled by a hand-rolled utility (`OptimisticLockRetry`), not Spring's `@Retryable`. This doc is the authoritative map of those boundaries so every optimistic-lock / stuck-state / connection-pool debug can start from shared ground.

---

## 2. Topology

```
                             HTTP request
                                  ↓
                      TenantInterceptor sets
                      TenantContext (ThreadLocal)
                                  ↓
  ┌───────────────────────────────────────────────────────────────┐
  │  Controller (no @Transactional)                               │
  │      ↓                                                        │
  │  Service (@Transactional("tenantTransactionManager")          │
  │                or @TenantTransactional meta-annotation)       │
  │      ↓                                                        │
  │  tenantTransactionManager  ──→  tenantEntityManagerFactory    │
  │                                         ↓                     │
  │                           TenantDynamicRoutingDataSource       │
  │                                         ↓                     │
  │                  TenantContext.getCurrentTenant() →            │
  │                  TenantKeyBuilder.buildKey(profile) (4 chars)  │
  │                                         ↓                     │
  │                        per-tenant HikariCP pool               │
  │                                         ↓                     │
  │                          PostgreSQL (tenant DB)               │
  └───────────────────────────────────────────────────────────────┘

  Landlord path (landlordTransactionManager, @Primary):
    Admin / config / tenant-directory operations → landlordDataSource → PostgreSQL (landlord DB)

  Scheduled jobs (TenantConfigLoader, TenantPoolEvictor):
    NOT @Transactional. Run without TenantContext — they must operate on landlord only.

  Post-commit hooks:
    TransactionSynchronizationManager.registerSynchronization(...) fires after the
    enclosing tenant tx commits (OMS notifications, audits, external dispatch).
```

---

## 3. Configuration Facts

| Fact | Value | Source |
|---|---|---|
| OSIV | **disabled** (`spring.jpa.open-in-view=false`) | `src/main/resources/application.properties:54` |
| `@Primary` manager | **`landlordTransactionManager`** | `net/aim_ai/wms/landlord/config/LandlordDatabaseConfig.java:62-64` |
| Tenant manager | `tenantTransactionManager` (not primary) | `net/aim_ai/wms/landlord/config/TenantDatabaseConfig.java:75-77` |
| Routing DS | `TenantDynamicRoutingDataSource extends AbstractRoutingDataSource` | `net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java:35-45` |
| Tenant key | 4 chars = 2-char tenant + 2-char facility, via `TenantKeyBuilder.buildKey(profile)` | same file |
| Tenant context | **ThreadLocal** — not request-scoped | `TenantContext.getCurrentTenant()` |
| Fallback when no tenant ctx | routes to **landlord DS** | `TenantDynamicRoutingDataSource:40` |

### OSIV-disabled consequence

Lazy associations cannot be resolved in the controller or view layer. Any fetch must happen inside the `@Transactional` service method. Related debt is tracked under `4-Archieves/wms2/plan/260424-WMS_OSIV_Disabled_Audit.md`.

### The `@Primary` landmine

`landlordTransactionManager` is `@Primary`. That means:

- A bare `@Transactional` picks **landlord** — not tenant.
- 16 of 132 `@Transactional` sites in the codebase have no explicit qualifier and no `@TenantTransactional` meta-annotation. Those sites are suspect and must be reviewed on sight.
- Any **new service method** that touches tenant data MUST use `@Transactional("tenantTransactionManager")` or a meta-annotation (`@TenantTransactional`, `@TenantTransactionalReadOnly`). Default `@Transactional` is forbidden on tenant code paths.

---

## 4. Transaction Manager Beans

### 4.1 `landlordTransactionManager` (@Primary)

- **File:** `net/aim_ai/wms/landlord/config/LandlordDatabaseConfig.java:62-64`
- **Wraps:** `landlordEntityManagerFactory` → `landlordDataSource`
- **Used by:** tenant directory, system config, public `/api/public/authConfig`, admin endpoints
- **NEVER use for:** anything with tenant-scoped entities (orders, unitloads, picking, replenishment, etc.)

### 4.2 `tenantTransactionManager`

- **File:** `net/aim_ai/wms/landlord/config/TenantDatabaseConfig.java:75-77`
- **Wraps:** `tenantEntityManagerFactory` → `TenantDynamicRoutingDataSource`
- **Invoked via:** `@Transactional("tenantTransactionManager")` OR `@TenantTransactional` / `@TenantTransactionalReadOnly` meta-annotations (`net/aim_ai/wms/config/TenantTransactionalReadOnly.java:16`).
- **Used by:** all business services — **163 sites** counted 2026-08-06 (`@Transactional` lines naming `tenantTransactionManager`; 221 `@Transactional` annotations exist in `src/main/java` in total, the remainder being landlord/repository). The former figure was `~116`.

### 4.3 No `ChainedTransactionManager`

There is no chained / multi-DS transaction manager. Operations that need both DBs must use **post-commit hooks** (§6), not a shared transaction.

---

## 5. Boundary Rules (operational playbook)

### Rule 1 — Pick the manager explicitly
```java
@Transactional("tenantTransactionManager")   // tenant data
// or
@Transactional("landlordTransactionManager") // landlord data
// or (preferred)
@TenantTransactional                          // tenant meta-annotation
```
Bare `@Transactional` on tenant code is a bug.

### Rule 2 — `REQUIRES_NEW` for job-step isolation
Use `REQUIRES_NEW` only when each step of a batch must commit independently so the next step sees it (the replenish/release job pattern). All **29** current `REQUIRES_NEW` sites follow this pattern; see §7. (Re-counted 2026-08-06 — this line and §9 item 5 had drifted to `20` while §7's own header already said 28.)

### Rule 3 — Never open `@Transactional` on a controller
Controllers in `wms2-api` do not open transactions. Exception-handling at the controller layer (see `PickingController`) is the one acceptable reason the annotation appears there — no method-level `@Transactional` on any current controller.

### Rule 4 — `readOnly = true` for pure-query service methods
**29 sites** as of 2026-08-06 (was documented as 16). This matters more under PgBouncer (transaction pooling mode cannot piggyback prepared statements across autocommit connections), so spreading `readOnly = true` to more query paths is a pending optimization lever.

### Rule 5 — Post-commit side effects go through `TransactionSynchronizationManager`
Never fire an external call (OMS, Keycloak, printer, broker) inside the tenant transaction. Register a post-commit synchronization; see §6 and the `ParcelMonitorViewService` / `OmsNotificationService` patterns.

### Rule 6 — Scheduled jobs have NO tenant context
`@Scheduled` methods run on a dedicated scheduler thread. `TenantContext` is ThreadLocal — it's null there. Current scheduled methods deliberately touch only landlord state (config refresh, pool eviction). **If a new cron must operate on tenant data, it must iterate known tenants and set `TenantContext` per iteration.** This is the root cause pattern of `260331-cron-job-autoflush-optimistic-lock-debug-plan.md`.

### Rule 7 — `@Primary` means landlord wins by default
Spot-fix rule: when reviewing a PR, grep it for `@Transactional` with no argument. If it touches anything under `net/aim_ai/wms/service/`, `net/aim_ai/wms/service/mobile/`, or `net/aim_ai/wms/service/job/`, it's almost certainly wrong.

---

## 6. Post-commit Hooks

`TransactionSynchronizationManager.registerSynchronization(...)` is the canonical way to fire side-effects after the enclosing tenant transaction commits. Representative sites:

| File | Purpose |
|---|---|
| `service/ParcelMonitorViewService.java:213,367,454` | Parcel shipped/packed OMS notifications (SBDEV-2232: lines shifted after pessimistic lock refactor) |
| `service/OmsNotificationService.java:55` | Parcel-ready OMS notification |
| `service/ReceivingService.java:532` | Post-commit audit of receiving advice |
| `service/PickingorderBusinessService.java:256,505` | Pick event propagation |
| `service/mobile/MobilePickingService.java:478,986` | Mobile pick post-commit actions |
| `service/mobile/MobilePalletizingService.java:230,380` | Palletizing post-commit |
| `service/mobile/MobileTruckLoadingService.java:308` | Truck loading post-commit |

Neither `TransactionTemplate` nor direct `PlatformTransactionManager.getTransaction()` is used anywhere in application code.

---

## 7. `REQUIRES_NEW` Inventory (29 sites)

Every `REQUIRES_NEW` site lives in a scheduled-job service, the message service, the sequence-transaction service, the inventory-record service (escapes the `readOnly=true` outer transaction in `WarehouseStockReportService.streamStockCount` per SBDEV-2219), the message-cleanup batch service (per-batch tx boundary for the daily message-cleanup loop — SBDEV-2220), the idempotency service (SBDEV-2222 — `persistResponse` commits the dedup row independently so a handler rollback doesn't wipe the stored response), the outbox service (SBDEV-2221 — each `mark*` / claim / reclaim phase commits independently so no row lock is held across the OMS HTTP round-trip), or — as of SBDEV-2237 — `MobilePickingService.releaseClaimQuietly` (compensating RESERVED→PROCESSABLE reset after a fresh Tx-1 claim followed by Tx-2 failure). The pattern is: the outer loop wants to survive a failure of one inner step, and each inner step must commit independently so downstream steps see it.

> **SBDEV-2381 (2026-06-01) — MANDATORY enqueue sites (NOT REQUIRES_NEW, so not in the table below):** `CustomerorderBatchService.finalizeClubLine` (`@Transactional("tenantTransactionManager")`, invoked via the `self.*` CGLIB proxy per the 2026-05-21 self-invocation fix) now performs **up to 3 `outboxService.enqueue` calls per club CO** (RELEASE/STARTED/FINISHED) inside its own tenant transaction. `OutboxService.enqueue` uses MANDATORY propagation, so it **joins** the finalize tx — a failed enqueue rolls the whole finalize back (atomic transactional outbox). These are new in-tx write sites; the former non-transactional Phase-4 fire-and-forget OMS calls in `runClubLine` are gone. (Same MANDATORY-join semantics as `BillofladingService.closeBOL`'s enqueue.) REQUIRES_NEW count is unchanged.

| File | Line | Method | Extra attributes |
|---|---|---|---|
| `service/ReplenishGeneratorService.java` | 95 | `createReplenishOrdersByLocation` | `rollbackFor = FacadeException` |
| `service/ReplenishGeneratorService.java` | 117 | `createReplenishOrderForSingleItem` | `rollbackFor = FacadeException` |
| `service/ReplenishGeneratorService.java` | 209 | `createReplenishOrderByReplenishTask` | `rollbackFor = FacadeException` |
| `service/PickingOrderMergeService.java` | 45 | `mergeOrders` | — |
| `service/job/ReleaseOrderJobService.java` | 99 | `releaseOrder` | — |
| `service/job/ReplenishOrderJobService.java` | 74, 92, 106 | `processReplenishOrderRequest` | — |
| `service/job/ReplenishOrderJobService.java` | 203, 231, 250 | `processReplenishOrder` | — |
| `service/job/ReplenishOrderJobService.java` | 242, 269 | `callReceiveDispatch` | — |
| `service/job/ReplenishOrderJobService.java` | 264 | `executeReplenishTask` | `rollbackFor = FacadeException` |
| `service/MessageService.java` | 67 | `sendMessage` | — |
| `service/SequenceTransactionService.java` | 23 | `getNextSequenceNumber` | — |
| `service/InventoryRecordService.java` | 29 | `createEntity` | SBDEV-2219 — escapes outer `readOnly=true` tx in `WarehouseStockReportService.streamStockCount`; without REQUIRES_NEW, Postgres rejects every per-row INSERT |
| `service/InventoryRecordService.java` | — | `createEntitiesBulk` | SBDEV-2228 Fix C — bulk-insert variant replacing per-row `createEntity`; same REQUIRES_NEW rationale; called after cursor tx closes (OMS HTTP calls also deferred post-cursor) |
| `service/job/ReleaseOrderJobService.java` | — | `streamOrderPositionsForEach` | SBDEV-2228 Fix A — `readOnly=true` outer tx that keeps the JDBC cursor alive during streaming iteration; per-order commits via `releaseOrder` (REQUIRES_NEW) suspend this tx |
| `service/job/ReleaseOrderJobService.java` | — | `markClientHasNoSection` | SBDEV-2961 — **second** inner committer under `streamOrderPositionsForEach`'s `readOnly=true` cursor tx. Called from `OrderReleaseJob.processOrderGroup`, i.e. from inside the consumer, so a `REQUIRED` write would join the read-only tx: an entity `save` vanishes unflushed with no error, and the bulk JPQL CAS used here raises Postgres `25006`. Delegates to a `@Modifying` CAS on `CustomerorderRepository`. |
| `service/job/MessageCleanupBatchService.java` | 41 | `archiveOnce` | SBDEV-2220 — per-batch tx boundary for daily message cleanup (was previously a bare `@Transactional` on `MessageRepository.archiveMessages` binding to landlord TM) |
| `service/job/MessageCleanupBatchService.java` | 53 | `deleteOnce` | SBDEV-2220 — per-batch tx boundary releases row locks between iterations so concurrent inserts on `message` are not blocked across the entire cleanup run (AC-2/AC-3) |
| `service/RestIdempotencyService.java` | — | `persistResponse` | SBDEV-2222 — commits the dedup row (status + body) independently so a handler rollback does not delete the stored response; OMS replays must get the cached 2xx, not re-execute |
| `service/mobile/MobilePickingService.java` | — | `releaseClaimQuietly` | SBDEV-2237 — compensating RESERVED→PROCESSABLE reset after fresh Tx-1 claim + Tx-2 failure; guard: `claimantUserId == operatorId AND state == RESERVED` before resetting (concurrent-claim safety) |
| `service/OutboxService.java` | — | `reclaimStaleInFlight` | SBDEV-2221 — Phase 0: recover crashed `IN_FLIGHT` rows back to `FAILED_RETRY`; short independent tx so the next claimDueBatch sees them immediately |
| `service/OutboxService.java` | — | `claimDueBatch` | SBDEV-2221 — Phase 1: atomically flip PENDING/FAILED_RETRY → IN_FLIGHT (`FOR UPDATE SKIP LOCKED`); commits immediately so row locks are released before Phase 2 HTTP POST begins |
| `service/OutboxService.java` | — | `markSent` | SBDEV-2221 — per-row outcome commit; independent of other rows so one OMS 2xx does not wait for adjacent rows to complete |
| `service/OutboxService.java` | — | `markRetry` | SBDEV-2221 — per-row retry commit with exponential backoff (`nextAttemptAt = now + min(60s × 2^attempts, 1h)`); independent of other rows |
| `service/OutboxService.java` | — | `markTerminal` | SBDEV-2221 — per-row terminal-failure commit; independent of other rows |
| `service/job/OutboxDispatchService.java` | — | `cleanupSent` | SBDEV-2221 — per-tenant bulk DELETE of `SENT` rows older than retention window; called at end of each tick from `OutboxDispatcherJob` (via Spring proxy — not via `this.`) |

None uses a non-default isolation level — everything relies on PostgreSQL's `READ_COMMITTED`.

---

> **SBDEV-2732 (2026-08-10, wms2-api PR #139 — MERGED 2026-08-11) — two more MANDATORY sites, and
> `REQUIRES_NEW` is UNCHANGED at 28.** Verified: the branch adds zero `REQUIRES_NEW` (the only match in
> the diff is prose describing MANDATORY as the anti-`REQUIRES_NEW` device).
>
> - **`PutawayDestinationResolver.resolve`** — `@Transactional("tenantTransactionManager", propagation = MANDATORY)`.
>   Deliberately structural rather than defensive: it makes it *impossible* to call the resolver outside
>   a caller's transaction, so no future caller can reach for `REQUIRES_NEW` and reintroduce the
>   SBDEV-2232 deadlock class. The consequence is that **no controller may call it** — there is zero
>   `@Transactional` under `controller/`, so a direct call raises `IllegalTransactionStateException` (a
>   bare `RuntimeException`) on **every** request. Controllers go through
>   `PutawayDestinationQueryService`, a `readOnly = true` facade that supplies the transaction.
> - **`PutawayConfigAuditService.record`** — MANDATORY, copied from `CancellationLogService.recordCancellation`:
>   the audit row commits with the configuration change or not at all.
>
> Consequence worth knowing: MANDATORY **cannot be called from a Spring Data REST `@HandleBefore*`
> method**, which fires outside any transaction. That is why the HAL channel splits — `Before`
> validates, `After` audits — and why the audit there does *not* get the atomic guarantee the typed
> writers have (the SDR save has already committed by then).

---

## 8. Locking Strategy

### 8.1 Optimistic — `@Version` fields (2)

- **`AbstractBaseEntity.version`** — `net/aim_ai/wms/model/AbstractBaseEntity.java` (MappedSuperclass). **Every tenant entity inherits this**, so every row check participates in optimistic locking.
- **`LosSequencenumber.version`** — standalone; combined with pessimistic lock below.

### 8.2 Pessimistic — `@Lock(PESSIMISTIC_WRITE)` repository methods (12)

| Repository | Line | Entity |
|---|---|---|
| `StockunitRepository` | 27 | `Stockunit` |
| `AdvicepositionRepository` | 21 | `Adviceposition` |
| `ReplenishorderRepository` | 27 | `Replenishorder` |
| `UnitloadRepository` | 29 | `Unitload` |
| `LocationRepository` | 49 | `Location` |
| `PickingorderRepository` | 22, 26 | `Pickingorder` (single + batch) — **1s `jakarta.persistence.lock.timeout` hint** on `findByIdForUpdate` (SBDEV-2237) |
| `LosSequencenumberRepository` | 21 | `LosSequencenumber` |
| `CustomerorderRepository` | 25 | `Customerorder` |
| `CustomerorderBatchRepository` | 26 | `CustomerorderBatch` — **5s `jakarta.persistence.lock.timeout` hint** |
| `BillofladingRepository` | 26 | `Billoflading` — **5s `jakarta.persistence.lock.timeout` hint** |
| `CustomerorderPositionRepository` | 24 | `CustomerorderPosition` (sibling-read lock in `confirmPick`/`finishPickingOrder` — SBDEV-2223) |

No `PESSIMISTIC_READ` anywhere — all pessimistic sites take a write lock. `CustomerorderBatch` and `Billoflading` bound their wait to 5s; `PickingorderRepository.findByIdForUpdate` bounds to 1s (SBDEV-2237, interactive pick-claim path).

### 8.3 Retry — `OptimisticLockRetry` utility

- **File:** `net/aim_ai/wms/util/OptimisticLockRetry.java`
- **Catches:** `ObjectOptimisticLockingFailureException | StaleObjectStateException` (line 83)
- **Policy:** up to 3 retries, exponential backoff `100ms × attempt`
- **Throws on give-up:** `OptimisticLockRetryException`
- **Call shape:**
  ```java
  optimisticLockRetry.executeWithRetry(() -> {
      Stockunit fresh = stockunitRepository.findById(id).orElseThrow();
      fresh.setAmount(newAmount);
      return stockunitRepository.save(fresh);
  }, "updateStockunitAmount");
  ```
- **Re-read inside the lambda is mandatory** — that's what makes the retry actually resolve the stale-state error. `BasicService.java:117-127` has an older inline version of the same pattern.
- **Consumers (as of 2026-06-10, plan 260610 Phase A):** exactly ONE — `MobilePalletizingService.scanPallet:217` (non-transactional/auto-commit, where the catch genuinely fires). The former call sites in `PickingorderBusinessService.confirmPick` and `UnitloadBusinessService.transferUnitLoadToLocation` were **removed as inert** (they ran inside an open `@Transactional`, where the optimistic-lock exception only surfaces at the outer commit — outside the retry loop); `MobileReplenishService`'s injection was dead and removed. The retry is only meaningful OUTSIDE an open transaction — do not wrap in-transaction mutations with it. Scope is pinned by `unit/service/OptimisticLockRetryScopeTest`.

Not used: `@Retryable` / `@Recover` from Spring Retry. Keep retries in the utility for uniform telemetry.

### 8.4 Controller-layer handling

- `PickingController` (`controller/mobile/PickingController.java:72-75`) catches both `ObjectOptimisticLockingFailureException` and `PessimisticLockingFailureException` per-endpoint and returns a "please try again" error.
- Global fallback: `exceptions/RestExceptionHandler.java:125` maps `ObjectOptimisticLockingFailureException` to a `ProblemDetail` response.

---

## 9. Scheduled Jobs

Only 2 `@Scheduled` methods exist — both are infrastructure on the landlord side.

| File | Method | Schedule | `@Transactional`? |
|---|---|---|---|
| `landlord/config/TenantConfigLoader.java:57` | `scheduledRefresh` | `fixedDelayString = "${wms.tenant.config.refresh-interval-ms:300000}"` (5 min; 0 disables) | No |
| `landlord/config/TenantPoolEvictor.java` | `evictIdlePools` | `fixedDelayString = "${wms.tenant.pool.evict-interval-ms:300000}"` (5 min) | No |

No business-logic scheduler runs in-process. Replenish / release / cron-autoflush jobs are triggered by external calls that arrive with tenant context set by the interceptor.

---

## 10. Known Landmines

1. **Bare `@Transactional` silently uses landlord.** The `@Primary` marker on `landlordTransactionManager` means a tenant-data write without an explicit qualifier commits to the wrong DB — or throws "entity not managed" if the entity type isn't mapped on that EMF. Always qualify on tenant code.
2. **Scheduled methods see no tenant.** `TenantContext` is ThreadLocal; the scheduler thread never had it set. New cron jobs that need tenant data must enumerate tenants and `set` the context per iteration. Root-cause pattern of `260331-cron-job-autoflush-optimistic-lock-debug-plan.md`.
3. **`LosSequencenumber` has both `@Version` AND `PESSIMISTIC_WRITE`.** The `@Version` is defensive — the pessimistic lock is the primary mechanism. Don't remove the version field without verifying all call sites route through `findByIdForUpdate()`.
4. **Most pessimistic locks have no timeout.** `CustomerorderBatch` and `Billoflading` use a 5s `jakarta.persistence.lock.timeout`; `PickingorderRepository.findByIdForUpdate` uses 1s (SBDEV-2237, interactive pick-claim). The rest will wait for the full Hikari connection-acquire window under row contention, contributing to pool-exhaustion incidents (see `260424-connection-pool-exhaustion-fix-plan.md`).
5. **`REQUIRES_NEW` ×29 = 29 connections held briefly per outer loop iteration.** Under the current per-tenant pool sizing this is a dominant factor in pool pressure during replenish bursts. See `260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md`.
6. **`TenantDynamicRoutingDataSource` falls back to landlord when no context is set** (line 40). A bug that clears the ThreadLocal mid-request would route subsequent writes to landlord without an error until a schema mismatch surfaces downstream.
7. **Post-commit hooks can silently no-op.** If `TransactionSynchronizationManager.isSynchronizationActive()` is `false` at the call site, the sync is never registered. When a service method that uses `registerSynchronization` is invoked outside a transaction (e.g. from a test or an unusual caller), the side-effect simply drops.

---

## 11. Related ADRs

None recorded yet. Candidates that should be written up:

- **ADR — Why landlord is `@Primary` and the mitigation via `@TenantTransactional`** (the current convention is code-enforced only).
- **ADR — No `@Retryable`; use `OptimisticLockRetry`** (why hand-rolled vs Spring Retry).
- **ADR — Post-commit side-effects only via `TransactionSynchronizationManager`** (ban direct external calls inside `@Transactional`).

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | OSIV value, both TM beans, routing DS, `@Transactional` / `@Version` / `@Lock` inventories, scheduled methods, retry utility | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-12 | §8.2 pessimistic count updated 11→12: added `CustomerorderPositionRepository.findByOrderIdForUpdate` (SBDEV-2223 — sibling-read lock for `confirmPick`/`finishPickingOrder` last-pick detection race) | Count confirmed by grep; `@RestResource(exported=false)` guard added | SBDEV-2223 fix review |
| 2026-05-15 | SBDEV-2234: `ReplenishmentOrderMaintenanceService.recalculateForItem(Long)` now `@Transactional(tenantTransactionManager)` (previously non-transactional). `SyspropService.setSysvalue(String,String)` added as `@Transactional(tenantTransactionManager)` + `@CacheEvict`. `recalculateOpenOrders(boolean)` intentionally remains NON-transactional (260331 decision). `ReplenishorderRepository.findByIdForUpdate` (§8.2 — already counted) is now actively called by `recalculateOrder`. | All annotations confirmed by grep | SBDEV-2234 fix review |
| 2026-05-15 | SBDEV-2235: New `SkuBatchCreateUpdateService.upsertAll(...)` added as `@Transactional(value="tenantTransactionManager", rollbackFor={WebserviceBusinessExceptionClientSide.class, BusinessException.class})`. `SkuRestController.create()` and `.update()` refactored to two-phase: Phase 1 validates all inputs + resolves all lookups (no writes), Phase 2 delegates to `upsertAll`. Self-recursion `this.create(createList)` inside `update()` DELETED (bypassed CGLIB proxy). `/create` and `/update` validation-failure status changed 400 → 422; `/delete` unchanged at 400. `@CacheEvict(value="itemdata", allEntries=true)` retained on both controller methods. No new lock sites. | All annotations confirmed by grep + verify script 23/24 pass (AC21 = pre-existing SBDEV-2230 incomplete) | SBDEV-2235 fix review |
| 2026-05-15 | SBDEV-2237: `MobilePickingService.selectAndReservePickingOrder` — `@Transactional` removed; replaced with two programmatic `TransactionTemplate` TXs (Tx-1 `claimPickingOrderAtomically` acquires `SELECT FOR UPDATE` + reserves; Tx-2 `finalizePickingOrderForStart` re-reads entity + handles RAPID_PICKING/finish). New `releaseClaimQuietly` compensating method added with `PROPAGATION_REQUIRES_NEW` (§7 count 21→22). `PickingorderRepository.findByIdForUpdate` gains 1s `jakarta.persistence.lock.timeout` hint (§8.2 updated). `processPickingOrderForStart` deleted; residual subset inlined into `resumePickingOrderIfExists`. | All changes confirmed by verify script (21 pass, 1 fail = pre-existing mvn failures) | SBDEV-2237 lock-split fix review |
| 2026-05-17 | SBDEV-2221: 6 new REQUIRES_NEW sites added (§7 count 22→28): `OutboxService.reclaimStaleInFlight`, `OutboxService.claimDueBatch`, `OutboxService.markSent`, `OutboxService.markRetry`, `OutboxService.markTerminal`, `OutboxDispatchService.cleanupSent`. Pattern: claim-then-release — Phase 1 commits (releasing `FOR UPDATE SKIP LOCKED` row locks) before Phase 2 HTTP POST begins; each per-row outcome commits independently so no tenant-pool connection is held across the OMS round-trip. `BillofladingService.closeBOL` enqueue method is MANDATORY (joins caller's tx), not REQUIRES_NEW. | All 6 new sites confirmed by grep; TDD gate tests pass (5/5) | SBDEV-2221 outbox pilot implementation |
| 2026-08-10 | SBDEV-2732 (PR #139, MERGED 2026-08-11): 13 new `@Transactional` sites, all on `tenantTransactionManager`; **`REQUIRES_NEW` count unchanged at 28** (verified — zero added by the diff). Two new **MANDATORY** sites recorded in §7: `PutawayDestinationResolver.resolve` and `PutawayConfigAuditService.record`. | Confirmed by diff read at `aff434e`. **Described unmerged behaviour when written; PR #139 MERGED 2026-08-11, so this now describes shipped code** (status corrected 2026-08-25). Scoped check — the rest of the doc was NOT re-verified, and it is past its 2026-07-31 due date. | Code read (SBDEV-2732 diff) |
| 2026-05-20 | 260520 fix: New REQUIRED site — `ReplenishmentOrderMaintenanceService.recalculateOrder(Replenishorder, RecalcContext)` now `@Transactional(tenantTransactionManager, REQUIRED)`. REQUIRES_NEW count unchanged (§7 = 28). Self-injection (`@Lazy @Autowired self`) added to service so `recalculateOpenOrders(boolean)` sweep loop can route each order through the CGLIB proxy. 2026-05-15 entry note updated: "recalculateOrder itself also remains non-transactional" is now **superseded** — it IS transactional as of this fix. §5.4 WARNING: `recalculateForItem`'s inner loop deliberately remains `this.recalculateOrder` to avoid poisoning the shared REQUIRED outer tx via proxy-intercepted rollbackFor. | Annotation confirmed by grep + 44-test TDD gate pass | 260520 replenishment open-orders missing-tx fix |
| 2026-05-21 | 260521 fix: No new `@Transactional` sites added. `CustomerorderBatchService.validateClubLine` (line 606), `finalizeClubLine` (line 689), and `rollbackClubLineState` (line 709) were always correctly annotated `@Transactional(tenantTransactionManager)` but were being called via `this.*` from `runClubLine` — bypassing the CGLIB proxy so all three annotations were inert. REQUIRED count and REQUIRES_NEW count unchanged (§7 = 28). Self-injection (`@Lazy @Autowired self`) added to `CustomerorderBatchService` so `runClubLine` routes all three phase calls through `self.*`. `runClubLine` itself remains non-transactional (Rule 5 — Phase 4 OMS HTTP must run outside JPA tx). Additional bug fixed: `validateClubLine` was capturing `originalState` after `setState(IN_PROGRESS)` — always recording the mutated state; now captured before mutation so `rollbackClubLineState` correctly restores the original `ACTIVATED`/`STAGING_LANE_ASSIGNED` state on failure. | Annotation confirmed by verify script (19 pass, 0 fail, 1 skip) + 5 test suites green | 260521 runClubLine self-invocation TX fix |

| 2026-06-01 | SBDEV-2381: `CustomerorderBatchService.finalizeClubLine` gained up to 3 per-CO `outboxService.enqueue` (RELEASE/STARTED/FINISHED) inside its tenant tx; `OutboxService.enqueue` is MANDATORY propagation (joins finalize tx — failed enqueue rolls finalize back). Former non-tx Phase-4 OMS calls in `runClubLine` removed. §7 intro note added; REQUIRES_NEW count (28) unchanged. | Confirmed against `CustomerorderBatchService.finalizeClubLine` + `OutboxService.enqueue` (PR #35, commits 567fba3 + 41ad7d3) | Code read (grep-based) |
| 2026-06-10 | 260610 hardening Phase A: §8.3 consumer inventory updated — inert `OptimisticLockRetry` call sites removed from `PickingorderBusinessService.confirmPick` and `UnitloadBusinessService.transferUnitLoadToLocation` (both wrapped in-transaction mutations where the catch can never fire); dead injection removed from `MobileReplenishService`. Sole remaining consumer: `MobilePalletizingService.scanPallet` (non-tx). Scope pinned by new `OptimisticLockRetryScopeTest`. No `@Transactional` site added/removed; §7 REQUIRES_NEW count unchanged (28). NOTE: §9 "only 2 @Scheduled methods" is stale (8 business + 2 infra exist) — full-map refresh tracked by 260610 audit backlog item 7. | Verify script Phase A 9/9 + suites green | 260610 Phase A implementation |
| 2026-06-29 | Fix `260629-transfer-lane-leak-on-cancel`: new REQUIRED tenant-TM site — `TransferOrderService.unlinkTransferLaneFromTransferOrder` now `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` (previously **none** → ran on the `@Primary` landlord TM in auto-commit; same latent-bug class as the 2026-05-15 `ReplenishmentOrderMaintenanceService.recalculateForItem` entry). Sole caller `TransfersController.unlinkTransferLane` is non-transactional, so this opens a fresh tenant TX (REQUIRED, no propagation join) — no nested-tx hazard. `CustomerorderService.cancelOrder`/`forceCancelOrder` gained a guarded `setTransferlaneId(null)` but **no** new annotation (already tenant-TM). REQUIRES_NEW count unchanged (28; this is a REQUIRED site). | Annotation confirmed by grep + verify script (12 pass, 0 fail) + 143-test green run + code review (SHIP) | Fix `260629` implementation + code review |

| 2026-08-06 | Cadence sweep of the doc's **countable** claims (prompted by SBDEV-2731, which itself touches none of this surface — its diff contains zero `@Transactional` and zero state transitions). Three counts were stale and one was internally contradictory: §4.2 tenant-TM sites `~116` → **163**; Rule 2 `REQUIRES_NEW` `20` → **28**, which §7's own header already stated correctly, and §9 item 5 carried the same stale 20; Rule 4 `readOnly = true` `16` → **29**. | Corrected. Counts are `grep -rn` over `src/main/java` at `origin/develop` (`169065c`): `Propagation.REQUIRES_NEW` = 28, `readOnly = true` = 29, `@Transactional` lines naming `tenantTransactionManager` = 163 (221 `@Transactional` annotations total). **Counts only — the narrative sections, §7's per-site table and §8's lock analysis were NOT re-verified, so `last_verified` stays at 2026-06-01.** | Code read (grep-based, SBDEV-2731 doc sweep) |
| 2026-08-14 | SBDEV-2961 (branch `feature/SBDEV-2961-order-release-silent-section-exclusion`, **unmerged**): one new `REQUIRES_NEW` site — `ReleaseOrderJobService.markClientHasNoSection`. Counts corrected **28 → 29** in all three live places (Rule 2, §7 header, §9 item 5) and the site added to §7's table. It is the **second** inner committer under `streamOrderPositionsForEach`'s `readOnly=true` cursor tx, which is the whole reason it needs the annotation: an earlier revision of this fix used a `REQUIRED` entity `save` from inside the stream consumer, which joins the read-only tx and is **discarded unflushed with no error** — and because the job processes its last buffered group *outside* that tx, exactly one order per tick would have been written. Worth reading §7 before adding any writer on this path. | Counts + one §7 row only; **describes UNMERGED behaviour**. The narrative sections, §8's lock analysis and the rest of §7 were NOT re-verified, so `last_verified` stays at 2026-06-01 — and the doc is past its 2026-07-31 due date. | Code read of the branch diff + `mvn` verification (gate tests 5/5, verify script 44/0) |

**Re-verify every 60 days** — concurrency surface changes fast. Next due: 2026-07-31. ⚠️ **Overdue as of 2026-08-06.** The 2026-08-06 sweep corrected countable claims only; a full pass over §7's site table and §8's lock analysis is still owed.

---

## 13. How to use this doc

| Task | Section to start in |
|---|---|
| Debug an optimistic-lock exception | §8.1–8.3, then §10 |
| Debug a pool-exhaustion incident | §7 (REQUIRES_NEW), §8.2 (lock timeouts), §10 items 4–5 |
| Debug "why did this write go to the wrong DB?" | §3 (OSIV + `@Primary`), §5 (Rule 1 & Rule 7), §10 item 1 |
| Add a new cron job | §9, §5 Rule 6, §10 item 2 |
| Add a post-commit side-effect | §6, §5 Rule 5, §10 item 7 |
| Spike PgBouncer / horizontal scaling work | §4 (2 managers × per-tenant pools), §7, §10 items 4–5 |
