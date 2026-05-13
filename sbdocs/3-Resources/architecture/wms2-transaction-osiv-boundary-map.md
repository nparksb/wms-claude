---
title: "WMS v2 — Transaction & OSIV Boundary Map"
type: architecture
status: active
version: v2
scope: transactions
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-13
verified_by: code read of v2/wms2-api src/main at commit HEAD
related:
  - ../workflows/wms2-replenish-workflow.md
  - ../../1-Projects/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md
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
- **Used by:** all business services (~116 sites).

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
Use `REQUIRES_NEW` only when each step of a batch must commit independently so the next step sees it (the replenish/release job pattern). All 20 current `REQUIRES_NEW` sites follow this pattern; see §7.

### Rule 3 — Never open `@Transactional` on a controller
Controllers in `wms2-api` do not open transactions. Exception-handling at the controller layer (see `PickingController`) is the one acceptable reason the annotation appears there — no method-level `@Transactional` on any current controller.

### Rule 4 — `readOnly = true` for pure-query service methods
16 sites currently. This matters more under PgBouncer (transaction pooling mode cannot piggyback prepared statements across autocommit connections), so spreading `readOnly = true` to more query paths is a pending optimization lever.

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
| `service/ParcelMonitorViewService.java:188,191,319,405` | Parcel shipped/packed OMS notifications |
| `service/OmsNotificationService.java:55` | Parcel-ready OMS notification |
| `service/ReceivingService.java:532` | Post-commit audit of receiving advice |
| `service/PickingorderBusinessService.java:256,505` | Pick event propagation |
| `service/mobile/MobilePickingService.java:478,986` | Mobile pick post-commit actions |
| `service/mobile/MobilePalletizingService.java:230,380` | Palletizing post-commit |
| `service/mobile/MobileTruckLoadingService.java:308` | Truck loading post-commit |

Neither `TransactionTemplate` nor direct `PlatformTransactionManager.getTransaction()` is used anywhere in application code.

---

## 7. `REQUIRES_NEW` Inventory (21 sites)

Every `REQUIRES_NEW` site lives in a scheduled-job service, the message service, the sequence-transaction service, the inventory-record service (escapes the `readOnly=true` outer transaction in `WarehouseStockReportService.streamStockCount` per SBDEV-2219), the message-cleanup batch service (per-batch tx boundary for the daily message-cleanup loop — SBDEV-2220), or — as of SBDEV-2222 — the idempotency service (`persistResponse` commits the dedup row independently so a handler rollback doesn't wipe the stored response). The pattern is: the outer loop wants to survive a failure of one inner step, and each inner step must commit independently so downstream steps see it.

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
| `service/job/MessageCleanupBatchService.java` | 41 | `archiveOnce` | SBDEV-2220 — per-batch tx boundary for daily message cleanup (was previously a bare `@Transactional` on `MessageRepository.archiveMessages` binding to landlord TM) |
| `service/job/MessageCleanupBatchService.java` | 53 | `deleteOnce` | SBDEV-2220 — per-batch tx boundary releases row locks between iterations so concurrent inserts on `message` are not blocked across the entire cleanup run (AC-2/AC-3) |
| `service/RestIdempotencyService.java` | — | `persistResponse` | SBDEV-2222 — commits the dedup row (status + body) independently so a handler rollback does not delete the stored response; OMS replays must get the cached 2xx, not re-execute |

None uses a non-default isolation level — everything relies on PostgreSQL's `READ_COMMITTED`.

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
| `PickingorderRepository` | 22, 26 | `Pickingorder` (single + batch) |
| `LosSequencenumberRepository` | 21 | `LosSequencenumber` |
| `CustomerorderRepository` | 25 | `Customerorder` |
| `CustomerorderBatchRepository` | 26 | `CustomerorderBatch` — **5s `jakarta.persistence.lock.timeout` hint** |
| `BillofladingRepository` | 26 | `Billoflading` — **5s `jakarta.persistence.lock.timeout` hint** |
| `CustomerorderPositionRepository` | 24 | `CustomerorderPosition` (sibling-read lock in `confirmPick`/`finishPickingOrder` — SBDEV-2223) |

No `PESSIMISTIC_READ` anywhere — all pessimistic sites take a write lock. Only `CustomerorderBatch` and `Billoflading` bound their wait.

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
4. **Most pessimistic locks have no timeout.** Only `CustomerorderBatch` and `Billoflading` use a 5s `jakarta.persistence.lock.timeout`. Under row contention the others will wait for the full Hikari connection-acquire window, which contributes to pool-exhaustion incidents (see `260424-connection-pool-exhaustion-fix-plan.md`).
5. **`REQUIRES_NEW` ×20 = 20 connections held briefly per outer loop iteration.** Under the current per-tenant pool sizing this is a dominant factor in pool pressure during replenish bursts. See `260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md`.
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

**Re-verify every 60 days** — concurrency surface changes fast. Next due: 2026-07-11.

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
