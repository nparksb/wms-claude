---
title: "WMS v2 — Scheduled Jobs Catalog"
type: architecture
status: active
version: v2
scope: scheduled-jobs
owner: Nam Park
created: 2026-04-19
updated: 2026-06-01
last_verified: 2026-06-01
verified_by: code read of v2/wms2-api src/main at commit HEAD (incl. SBDEV-2228 paginated ReplenishOrderJob, streaming OrderReleaseJob, bulk+decoupled StockSummaryExportJob; SBDEV-2381 OutboxDispatcher ordering gate)
related:
  - ./wms2-transaction-osiv-boundary-map.md
  - ./wms2-state-machine-catalog.md
  - ./wms2-tenant-routing-datasource-topology.md
  - ../../1-Projects/wms2/plan/260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md
  - ../../4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md
  - ../../4-Archieves/wms2/plan/260331-cron-job-autoflush-optimistic-lock-debug-plan.md
  - ../../4-Archieves/wms2/plan/260424-connection-pool-exhaustion-fix-plan.md
tags:
  - architecture
  - scheduled-jobs
  - cron
  - advisory-lock
  - wms2
---

# WMS v2 — Scheduled Jobs Catalog

**Scope:** Every `@Scheduled` method and business cron job in `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-05-08

---

## 1. Overview

`wms2-api` runs nine recurring workloads in-process: **seven business cron jobs** gated by `app.cron=true` (disabled by default) and **two infrastructure `@Scheduled` methods** that always run. (Sixth business job — `StaleClubBatchCleanupJob` — was added by SBDEV-2164; seventh — `OutboxDispatcherJob` — was added by SBDEV-2221.) Cross-replica mutual exclusion for the business jobs is enforced by PostgreSQL **advisory locks** (`pg_try_advisory_lock`), each job holding a fixed integer lock ID for the duration of its run. Tenant context is set manually inside every business job — scheduler threads do not inherit ThreadLocal from the request path.

Three load-bearing facts:

1. **Advisory locks are session-level and will break under PgBouncer transaction pooling.** Every business job will lose mutual exclusion across replicas if PgBouncer is introduced in `pool_mode=transaction` without a lock-strategy change. See §7.
2. **Business jobs are off by default.** `app.cron=false` at `application.properties:111`. Infrastructure jobs (`TenantConfigLoader`, `TenantPoolEvictor`) run regardless — they are wired from a separate config class.
3. **One scheduler, pool size 10.** `ThreadPoolTaskScheduler` with a single pool handles business + infrastructure jobs. No `TaskDecorator` is registered, so tenant context is NEVER automatic on scheduler threads. Every business job sets/clears `TenantContext` manually inside its per-tenant loop.

---

## 2. Advisory Lock IDs

Defined at `net/aim_ai/wms/service/AdvisoryLockService.java:63-71`. These integers are the cross-replica mutex keys. Never reuse, never change — a change is a silent breaker because replicas on old code will hold the old ID.

| Constant | Value | Job |
|---|---|---|
| `JobLockId.ORDER_RELEASE` | `100001L` | `OrderReleaseJob` |
| `JobLockId.REPLENISH_ORDER` | `100002L` | `ReplenishOrderJob` |
| `JobLockId.CLEAN_UP_MESSAGES` | `100003L` | `CleanUpOldMessagesJob` |
| `JobLockId.STOCK_SUMMARY_EXPORT` | `100004L` | `StockSummaryExportJob` |
| `JobLockId.RELEASE_EXPIRED_PICKING` | `100005L` | `ReleaseExpiredPickingOrdersFromUserJob` |
| `JobLockId.STALE_CLUB_BATCH_CLEANUP` | `100006L` | `StaleClubBatchCleanupJob` (SBDEV-2164) |
| `JobLockId.CLEANUP_REST_IDEMPOTENCY` | `100007L` | `RestIdempotencyCleanupJob` (SBDEV-2222) |
| `JobLockId.OUTBOX_DISPATCHER` | `100008L` | `OutboxDispatcherJob` (SBDEV-2221) |

Infrastructure jobs (`TenantConfigLoader`, `TenantPoolEvictor`) do **not** take advisory locks — they are idempotent cache refreshers and safe to run concurrently on every replica.

---

## 3. Scheduling Infrastructure

### 3.1 Enablement split

Two `@Configuration` classes deliberately separate "always-on" scheduling from "business" scheduling:

| File | Role | Gate |
|---|---|---|
| `config/SchedulingEnablementConfig.java` | `@EnableScheduling` — activates `@Scheduled` annotation processing everywhere | unconditional |
| `schedulejob/SchedulingConfiguration.java` | Registers business cron jobs on `TaskScheduler` with `CronTrigger`s | `@ConditionalOnProperty(name = "app.cron", havingValue = "true")` |

Consequence: `TenantConfigLoader` and `TenantPoolEvictor` always run. `OrderReleaseJob` etc. require `app.cron=true` **and** the per-job activation sysprop.

### 3.2 `TaskScheduler` bean

`schedulejob/SchedulingConfiguration.java:69-78`:

```java
@Bean @Primary
public TaskScheduler taskScheduler() {
    ThreadPoolTaskScheduler scheduler = new ThreadPoolTaskScheduler();
    scheduler.setPoolSize(POOL_SIZE);           // 10
    scheduler.setThreadNamePrefix("scheduled-task-pool-");
    scheduler.setWaitForTasksToCompleteOnShutdown(true);
    scheduler.setAwaitTerminationSeconds(60);
    return scheduler;
}
```

- **Pool size: 10** (hard-coded at `SchedulingConfiguration.java:30`). Shared across business + infrastructure jobs. If a long-running job hogs a thread, other schedules wait.
- **No `TaskDecorator`.** See §6 of [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md) — `TenantAwareTaskDecorator` exists but is never wired. Every business job compensates by setting `TenantContext` manually.
- **60-second drain on shutdown.** Running jobs get up to a minute; after that, kill.

### 3.3 Startup gate

`SchedulingConfiguration.onApplicationReady()` (`@EventListener(ApplicationReadyEvent.class)`, lines 80–114) defers business-job wiring until tenant DBs are reachable:

1. Waits 5 s after `ApplicationReadyEvent` before polling.
2. Polls `isTenantDatabaseInitialized()` up to 60 times with 1 s sleep (lines 93, 118–145).
3. Each poll sets a tenant context, calls `tenantDynamicRoutingDataSource.determineTargetDataSource()` to trigger pool creation, then clears the context (lines 135, 137, 143).
4. Once connected, configures all five business cron jobs (line 100). If 60 iterations elapse, business jobs are never wired on this replica.

### 3.4 Global gates (sysprops in landlord DB)

| Key | Default | Role |
|---|---|---|
| `app.cron` (`application.properties:111`) | `false` | Class-level gate on `SchedulingConfiguration` |
| `NEW_CRON_JOB_ACTIVATED_KEY` | `true` | Per-job top-level gate, checked inside each job method |
| `CRON_JOB_SHOW_LOG_KEY` | `false` | Verbose debug logging across all business jobs |

Every business job also reads its own `*_ACTIVATED_KEY` before doing work. Turning `app.cron=true` alone does not start any job — each needs its own activation flag too.

---

## 4. Business Cron Jobs

All five share the same skeletal shape:

```java
if (!globallyActivated || !thisJobActivated) return;
if (!advisoryLockService.tryLock(JobLockId.X)) {
    LOG.info("...already running on another replica, skipping");
    return;
}
try {
    for (TenantProfile profile : allTenants) {
        TenantContext.setCurrentTenant(profile);
        try { /* per-tenant work */ }
        catch (Exception e) { LOG.error(...); /* continue */ }
        finally { TenantContext.clear(); }
    }
} finally {
    advisoryLockService.unlock(JobLockId.X);
}
```

### 4.1 `OrderReleaseJob`

| | |
|---|---|
| **File** | `schedulejob/OrderReleaseJob.java` |
| **Wired** | `SchedulingConfiguration.configureOrderRelease()` (lines 166–183) |
| **Lock ID** | `JobLockId.ORDER_RELEASE` (100001L) |
| **Cron** | `0 {ORDER_TIMER_MINUTE} {ORDER_TIMER_HOUR} * * *` (defaults `*`/`*` → every minute) |
| **Activation sysprop** | `ORDER_TIMER_ACTIVATED_KEY` (default `true`) |
| **Tunables** | `FIX_LOCATION_PAGE_SIZE` (default 2000), `FIX_LOCATION_PAGE_LIMIT` (default 100) — cap fix-location prefetch pages per run |
| **Reads** | **SBDEV-2228 Fix A:** stream-cursored `customerorderposition` via `ReleaseOrderJobService.streamOrderPositionsForEach(readOnly=true)` — replaces unbounded `List<OrderReleaseInfoView>` + in-heap bucketing. `@QueryHints(fetchSize=500)`, `ORDER BY co.prio DESC, co.created ASC, co.id ASC, cop.number ASC`. `fixlocationassignment` prefetched via `FIX_LOCATION_PAGE_LIMIT` pages of `FIX_LOCATION_PAGE_SIZE`; warehouse TZ sysprop. |
| **Writes** | `customerorder` state transitions; `pickingorder` rows (creation); `customerorderposition` state |
| **Per-step TX** | Outer cursor via `ReleaseOrderJobService.streamOrderPositionsForEach(@Transactional readOnly=true)` — SBDEV-2228 Fix A keeps JDBC cursor alive. Per-order commits via `releaseOrder(REQUIRES_NEW)` suspend the outer tx; one TX per order. |
| **Error resilience** | Per-order try-catch (`OptimisticLockException` / `FacadeException` / `BusinessException`) at line 286 — one order failure does not abort the run |

**Work:** Walks all `ASSIGNED` customer order positions grouped by customer order, evaluates fixed-location and overstock availability per item, and releases orders that can now be fulfilled. This is the hottest transaction site in the app — ~70 setState calls across hold/release logic. See §7 of [wms2-state-machine-catalog.md](./wms2-state-machine-catalog.md) for the state transitions fired here.

### 4.2 `ReplenishOrderJob`

| | |
|---|---|
| **File** | `schedulejob/ReplenishOrderJob.java` |
| **Wired** | `SchedulingConfiguration.configureReplenish()` (lines 185–202) |
| **Lock ID** | `JobLockId.REPLENISH_ORDER` (100002L) |
| **Extra guard** | JVM-local `AtomicBoolean RUNNING` at line 26 (defense-in-depth if advisory lock somehow acquired twice on one replica) |
| **Cron** | `20 {REPLENISHMENT_TIMER_MINUTE} {REPLENISHMENT_TIMER_HOUR} * * *` (defaults `*`/`*` → every minute at :20) |
| **Activation sysprop** | `REPLENISHMENT_TIMER_ACTIVATED_KEY` |
| **Sub-feature gates** | `MERGE_PICKING_ORDERS_KEY`, `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY_KEY` (sic — typo preserved in code) |
| **Tunables** | `PICKING_BOX_PER_CART_KEY`, `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY`, `REPLENISHMENT_PAGE_SIZE` (default 1000), `REPLENISHMENT_PAGE_LIMIT` (default 100) |

**Six sub-operations per run:**

1. `mergePickingOrders()` — merge totes-on-cart picking orders (gated on `MERGE_PICKING_ORDERS_KEY`)
2. `deleteEmptyFixAssignmentWithoutStockToReplenish()` — clean up empty fixed locations
3. `cancelUnreachableReplenishment()` — cancel orders for unreachable locations
4. `cancelReplenishmentIfFlowbinIsFull()` — cancel orders if flowbin full
5. `generateReplenishmentForItemDataWithoutFixedAssignment()` — create new replenish orders
6. `triggerRegularReplenishment()` + `updateReplenishmentOrderPriority()` + `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` — refill / recalc

**Per-step TX** — all inner service methods are `@Transactional(value="tenantTransactionManager", propagation=REQUIRES_NEW)`. **SBDEV-2228 Fix B:** each of the 6 sub-ops now uses drain-queue pagination (`PageRequest.of(0, pageSize)` — always page 0) including sub-op 6a (`updateReplenishmentOrderPriority`): the query hardcodes `AND replenishmentOrder.prio != 0` so processed rows leave the result set, making drain-queue safe. Sub-op page size / limit controlled by `REPLENISHMENT_PAGE_SIZE` / `REPLENISHMENT_PAGE_LIMIT` sysprops. See §7 of [wms2-transaction-osiv-boundary-map.md](./wms2-transaction-osiv-boundary-map.md) — this job remains the dominant driver of per-tenant connection-pool pressure during replenish bursts.

**Error resilience** — per-item try-catch for `OptimisticLockException` / `OptimisticLockingFailureException` / generic `Exception` (lines 155–159, 251–258). Per-tenant try-catch (lines 166–169). Job aborts only if advisory lock release fails.

### 4.3 `StockSummaryExportJob`

| | |
|---|---|
| **File** | `schedulejob/StockSummaryExportJob.java` |
| **Wired** | `SchedulingConfiguration.configureStockSummaryExport()` (lines 204–221) |
| **Lock ID** | `JobLockId.STOCK_SUMMARY_EXPORT` (100004L) |
| **Cron** | `0 {STOCK_SUMMARY_EXPORT_TIMER_MINUTE:0} {STOCK_SUMMARY_EXPORT_TIMER_HOUR:3} * * *` (default 03:00 daily) |
| **Activation sysprop** | `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED_KEY` |
| **Batching** | Gated on `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED_KEY`, batch size `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH_KEY`. **SBDEV-2219:** when split-flag is OFF, a hard ceiling `STOCK_SUMMARY_EXPORT_NO_SPLIT_MAX_CHUNK = 10_000` (constant, not sysprop) is enforced to prevent O(rows) heap regression — operator-visible `LOG.warn` cites the safety net. |
| **Endpoints** | `WEBSERVICE_STOCK_COUNT_URL_KEY` (OMS stock-count receiver), `WMS_INSTANCE_NAME`, `OMS_INSTANCE_NAME` |
| **Tunables** | `OMS_EXPORT_CONSUMER_TIMEOUT_S` (default 120s) — controls BlockingQueue offer timeout, POISON_PILL drain timeout, and consumer thread join deadline. **SBDEV-2228 Fix C:** OMS HTTP POSTs run in a daemon consumer thread decoupled from the Hibernate cursor; this sysprop is the single knob for all three bounded-wait operations. |
| **Reads** | **SBDEV-2219:** stream-cursored `stockcount` via `warehouseStockReportService.streamStockCount(Consumer<StockCountDto>)`. Replaces the legacy `getStockCount()` (now a `@Deprecated` shim that throws `UnsupportedOperationException`). The streaming path is wrapped in `@Transactional(value="tenantTransactionManager", readOnly=true)` and uses `Stream<StockView>` with `@QueryHints(HINT_FETCH_SIZE=500)` + `try-with-resources` close semantics. Hard cap: `count()` first; throws `BusinessException("BusinessException.StockCountTooLarge")` if `> SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY` (default 1,000,000) and increments Micrometer counter `stock_summary_export_aborted_total`. |
| **Rollback toggle** | **SBDEV-2219:** `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED_KEY` (default `true`). When `false`, `streamStockCount` delegates to a private `legacyGetStockCount()` bridge that calls the original unbounded `findAll()` — preserved as an emergency rollback only; the public no-arg method is hard-fail. |
| **Writes** | `inventoryrecord` (one row per batch) via `inventoryRecordService.createEntitiesBulk(REQUIRES_NEW)` — **SBDEV-2228 Fix C:** replaces per-row `createEntity`. `InventoryRecord` objects buffered inside the stream lambda; bulk-insert triggered at `batchSize` boundary. OMS HTTP POSTs (`sendList`) deferred until AFTER `streamStockCount` returns (cursor tx committed, DB connection released). `message` / `message_archive` (audit); `messageService.createMessage` failures wrapped locally per SBDEV-2217. |
| **Per-step TX** | No job-level `@Transactional`; bulk record creation uses `REQUIRES_NEW` (escapes outer `readOnly=true`); cursor tx closes before OMS HTTP calls (SBDEV-2228 Fix C). |
| **Error resilience** | Per-tenant try-catch (lines 102–103); HTTP `IOException` caught and logged as HTTP-503 in `message`; **SBDEV-2219:** `BusinessException` from cap-trip is caught at the per-tenant boundary so one tenant's runaway data does not abort other-tenant exports |

### 4.4 `CleanUpOldMessagesJob`

| | |
|---|---|
| **File** | `schedulejob/CleanUpOldMessagesJob.java` |
| **Wired** | `SchedulingConfiguration.configureCleanUpOldMessages()` (lines 147–164) |
| **Lock ID** | `JobLockId.CLEAN_UP_MESSAGES` (100003L) |
| **Cron** | `0 {CLEAN_UP_OLD_MESSAGES_TIMER_MINUTE:55} {CLEAN_UP_OLD_MESSAGES_TIMER_HOUR:2} * * *` (default 02:55 daily) |
| **Activation sysprop** | `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY` (default **`false`** — the only business job off by default beyond the global gate) |
| **Retention** | `CLEAN_UP_OLD_MESSAGES_PERIOD_KEY` — days. Parsed via `Integer.parseInt`; malformed value surfaces as `BusinessException.INVALID_SYSPROP_VALUE` (SBDEV-2220 — replaces raw `NumberFormatException`); `null`/blank falls back to default. |
| **Batch cap** | `CLEAN_UP_OLD_MESSAGES_BATCH_SIZE_KEY` — DELETE batch size, default 1000, clamped to [1, 100000] (SBDEV-2220). |
| **Throttle** | `CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS_KEY` — optional inter-batch sleep in ms, default 0 (off), clamped to [0, 5000]. Injected via `Sleeper` functional interface (`service/job/Sleeper.java` + `MessageCleanupConfig.java`) for unit-test substitution (SBDEV-2220). |
| **Reads** | `message` rows older than `today - period_days` |
| **Writes** | `message_archive` (archive via `messageCleanupBatchService.archiveOnce(refDate)`), then batched delete via `messageCleanupBatchService.deleteOnce(refDate, batchSize)` until returned count < batchSize. |
| **Per-step TX** | **Per-batch `REQUIRES_NEW` on tenant TM** (SBDEV-2220) — `MessageCleanupBatchService.{archiveOnce, deleteOnce}` are annotated `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = BusinessException.class)`. Each batch commits independently; a failure mid-loop leaves prior batches durable. Replaces the prior pattern of bare `@Transactional` on `MessageRepository` methods (which silently bound to the landlord TM). |
| **HAL exposure** | `MessageRepository.{archiveMessages, deleteMessages}` are now `@RestResource(exported = false)` (SBDEV-2220) — previously exposed as `POST /api/message/search/{archiveMessages, deleteMessages}` with no auth check beyond tenant JWT. |
| **Error resilience** | Per-tenant try-catch (lines 72–74); `BusinessException` from a malformed sysprop on one tenant is logged and the next tenant proceeds. |

### 4.5 `ReleaseExpiredPickingOrdersFromUserJob`

| | |
|---|---|
| **File** | `schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` |
| **Wired** | `SchedulingConfiguration.configureReleaseExpiredPickingOrdersFromUser()` (lines 223–238) |
| **Lock ID** | `JobLockId.RELEASE_EXPIRED_PICKING` (100005L) |
| **Cron** | **Hard-coded** `40 * * * * *` — every minute at :40 (no sysprop override) |
| **Activation sysprop** | `PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY` (default **`false`**) |
| **Timeout** | `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY` — seconds, default 40 |
| **Reads** | `pickingorder` rows in state `PICKED`, section picking type `RAPID_PICKING`, `locked_to_operator` timestamp older than threshold |
| **Writes** | `pickingorder` — clears `operator_id`, sets `locked_to_operator = false` (releases back to pool) |
| **Per-step TX** | Repository `save()` auto-TX |
| **Error resilience** | Per-tenant try-catch (lines 81–85) |

### 4.6 `StaleClubBatchCleanupJob` (SBDEV-2164)

| | |
|---|---|
| **File** | `schedulejob/StaleClubBatchCleanupJob.java` |
| **Wired** | `SchedulingConfiguration.configureStaleClubBatchCleanup()` (line 245+) |
| **Lock ID** | `JobLockId.STALE_CLUB_BATCH_CLEANUP` (100006L — added by SBDEV-2164 / commit 57ec70e, port of v1 `b746c39`+`38474e8`) |
| **Cron** | `0 {STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE} {STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR} * * *` — sysprop driven |
| **Activation sysprop** | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY` (per-job gate) |
| **Reads** | `customerorderbatch` rows representing club batches stale beyond a threshold via `customerorderBatchRepository.findStaleClubBatchIds(...)` |
| **Writes** | Cleanup of stale club batches via `StaleClubBatchCleanupJobService.cleanupStaleBatches()` (delegates per-batch through its own `@Transactional(value="tenantTransactionManager")`); orchestrator itself has no class-level @Transactional |
| **Per-step TX** | Per-batch transaction inside `cleanupStaleBatches()` — opening a fresh TX per stale batch ID |
| **Error resilience** | Per-tenant try-catch with `TenantContext.clear()` in `finally` (lines 50–71) |

---

### 4.7 `RestIdempotencyCleanupJob` (SBDEV-2222)

| | |
|---|---|
| **File** | `schedulejob/RestIdempotencyCleanupJob.java` |
| **Wired** | `@Scheduled(cron = "${app.cron.cleanup-rest-idempotency}")` — Spring `@Value` driven (not a DB sysprop) |
| **Lock ID** | `JobLockId.CLEANUP_REST_IDEMPOTENCY` (100007L — added by SBDEV-2222) |
| **Cron** | `app.cron.cleanup-rest-idempotency=0 0 2 * * *` (hard default: 02:00 daily) |
| **Activation** | No per-job sysprop gate — controlled by `app.cron` (class-level Spring guard) only |
| **Reads** | `rest_idempotency` rows; deletes those with `created_at < NOW() - 7 days` |
| **Writes** | `RestIdempotencyRepository.deleteOlderThan(Instant)` — bulk DELETE via JPQL |
| **Per-step TX** | Single `@Transactional("tenantTransactionManager")` DELETE per tenant — no inner REQUIRES_NEW |
| **Error resilience** | Per-tenant try-catch with `TenantContext.clear()` in `finally`; advisory lock released in outer `finally` |

---

### 4.8 `OutboxDispatcherJob` (SBDEV-2221)

| | |
|---|---|
| **File** | `schedulejob/OutboxDispatcherJob.java` |
| **Wired** | `@Scheduled(cron = "${app.cron.outbox-dispatcher:*/15 * * * * *}")` — Spring `@Value` driven (not a DB sysprop) |
| **Lock ID** | `JobLockId.OUTBOX_DISPATCHER` (100008L — added by SBDEV-2221) |
| **Cron** | `app.cron.outbox-dispatcher=*/15 * * * * *` (every 15 s) |
| **Activation** | No per-job sysprop gate — controlled by `app.cron` only |
| **Reads** | `outbox_message` rows with `status IN ('PENDING','FAILED_RETRY')` and `next_attempt_at <= NOW()` |
| **Writes** | Per-row: flips row to `IN_FLIGHT` (claim), then to `SENT` / `FAILED_RETRY` / `FAILED_TERMINAL` depending on OMS HTTP response; deletes `SENT` rows older than 7 days at end of tick |
| **Dispatch phases** | Phase 0 (REQUIRES_NEW via `OutboxService.reclaimStaleInFlight`): recover crashed `IN_FLIGHT` rows older than 5 min back to `FAILED_RETRY`. Phase 1 (REQUIRES_NEW via `OutboxService.claimDueBatch` → `OutboxMessageRepository.findAndClaimPending`): atomically flip PENDING/FAILED_RETRY → IN_FLIGHT, release row locks. **SBDEV-2381:** the claim query now `ORDER BY next_attempt_at, id` and applies a **fail-closed cross-tick `NOT EXISTS` gate** — a row is not claimed while a lower-`id` sibling of the same aggregate is still PENDING/FAILED_RETRY/IN_FLIGHT/FAILED_TERMINAL (prevents FINISHED-without-STARTED). Phase 2 (no tx held): **SBDEV-2381:** the claimed batch is sorted in Java by `(nextAttemptAt, aggregateType, aggregateId, id)` before a sequential HTTP POST loop (no `parallelStream`); each POST goes via `HttpRestService.postWithIdempotencyKey`, each outcome committed independently via `OutboxService.mark*` (REQUIRES_NEW). |
| **Ordering (SBDEV-2381)** | Backed by index `outbox_message (aggregate_type, aggregate_id, id, status)` from migration `V2.1.14__add_outbox_aggregate_order_index.sql`. Dispatch posts events in strict per-aggregate `id` order; each POST body carries `event_version = outbox row id` for OMS-side stale-event rejection. See `architecture/wms2-oms-integration-map.md` §2.1. |
| **Per-step TX** | Each `OutboxService.mark*` call is REQUIRES_NEW — no transaction held across the OMS HTTP round-trip |
| **Metrics** | `wms2.outbox.dispatched{outcome=sent|retry|terminal}` (Micrometer counter); `wms2.outbox.tick_duration` (Timer wrapping the full tenant loop) |
| **Retry policy** | Exponential backoff: `nextAttemptAt = now + min(60s × 2^attempts, 1h)`. Max attempts: `app.outbox.dispatcher.max-attempts=5`. |
| **Terminal failures** | 400/404/422 or attempts ≥ max — logged at ERROR with aggregate_type + aggregate_id + idempotency_key |
| **Error resilience** | Per-tenant try-catch with `TenantContext.clear()` in `finally`; advisory lock + tick timer released in outer `finally` |
| **Landlord connection note** | The advisory lock pins a raw landlord JDBC connection for the full tick duration. With N tenants × 15 s OMS read-timeout, worst-case pin = N × 15 s. Monitor `wms2.outbox.tick_duration` to detect landlord-pool saturation. |

---

## 5. Infrastructure `@Scheduled` methods

These run on every replica unconditionally. They do **not** take advisory locks — idempotent cache refreshers and safe to overlap.

### 5.1 `TenantConfigLoader.scheduledRefresh()`

| | |
|---|---|
| **File** | `landlord/config/TenantConfigLoader.java:57-65` |
| **Schedule** | `@Scheduled(fixedDelayString = "${wms.tenant.config.refresh-interval-ms:300000}", initialDelayString = ...)` — every 5 min; `0` disables |
| **Work** | Loads all `TenantDbConfiguration` + `TenantAuthConfiguration` from landlord DB; repopulates `TenantDbConfigCache` + `TenantAuthConfigCache` |
| **Tenant context** | Never sets one; landlord-only queries via `unitName = "landlord"` |
| **Error behavior** | Exception caught at line 94 and logged; caches retain previous state; next interval retries |

Also runs **once at startup** via `@EventListener(ApplicationReadyEvent.class) @Order(0)` (line 43), blocking application readiness until the initial load completes.

### 5.2 `TenantPoolEvictor.evictIdlePools()`

| | |
|---|---|
| **File** | `landlord/config/TenantPoolEvictor.java:30-41` |
| **Schedule** | `@Scheduled(fixedDelayString = "${wms.tenant.pool.evict-interval-ms:300000}")` — every 5 min |
| **Idle threshold** | `wms.tenant.pool.idle-ms` (default `900000` — 15 min) |
| **Work** | Walks `routingDataSource.getLastAccessMap()`; for any entry where `now - lastAccess > idle-ms`, calls `routingDataSource.removeTenant(tenantKey)` → `HikariDataSource.close()` |
| **Active-connection guard** | None — `removeTenant` is called regardless; Hikari's `close()` drains gracefully |

See §4 of [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md) for the full pool-lifecycle view.

---

## 6. Summary Table

| Job | Lock ID | Default schedule | Top-level gate | Extra gate | Per-step TX | Error scope |
|---|---|---|---|---|---|---|
| `OrderReleaseJob` | 100001L | every min (`0 * * * * *`) | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `ORDER_TIMER_ACTIVATED_KEY` | REQUIRES_NEW per order | per-order, per-tenant |
| `ReplenishOrderJob` | 100002L | every min at :20 | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `REPLENISHMENT_TIMER_ACTIVATED_KEY` + 6 sub-gates | REQUIRES_NEW per item/sub-op | per-item, per-tenant, JVM-local RUNNING |
| `StockSummaryExportJob` | 100004L | 03:00 daily | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED_KEY` | per-service | per-tenant, HTTP 503 capture |
| `CleanUpOldMessagesJob` | 100003L | 02:55 daily | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY` (default **false**) | per-batch | per-tenant |
| `ReleaseExpiredPickingOrdersFromUserJob` | 100005L | every min at :40 (hard-coded) | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY` (default **false**) | per-save | per-tenant |
| `StaleClubBatchCleanupJob` (SBDEV-2164) | 100006L | sysprop-driven cron | `app.cron` + `NEW_CRON_JOB_ACTIVATED_KEY` | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY` | per-batch TX inside `cleanupStaleBatches()` | per-tenant |
| `RestIdempotencyCleanupJob` (SBDEV-2222) | 100007L | `0 0 2 * * *` (app.properties) | `app.cron` only | none (no DB sysprop gate) | single DELETE per tenant | per-tenant |
| `OutboxDispatcherJob` (SBDEV-2221) | 100008L | `*/15 * * * * *` (app.properties) | `app.cron` only | none (no DB sysprop gate) | REQUIRES_NEW per phase (claim, mark*, cleanup) | per-tenant |
| `TenantConfigLoader.scheduledRefresh` | — | fixed delay 5m | unconditional | — | read-only | exception logged, cache held |
| `TenantPoolEvictor.evictIdlePools` | — | fixed delay 5m | unconditional | — | none (no DB TX) | n/a |

---

## 7. Known Landmines

1. **Advisory locks break under PgBouncer transaction pooling.** All five business jobs hold `pg_try_advisory_lock()` for their entire run, which is a **session-level** lock. Under PgBouncer `pool_mode=transaction`, the lock is released at transaction boundary — which, for a job that spans many transactions, means every replica's retry window sees a free lock and can enter. Either switch to `pool_mode=session` for the landlord DB, rewrite to `pg_try_advisory_xact_lock` with the lock taken at the start of each iteration (incompatible with "hold for entire run" semantics), or move the mutex to Redis. See `PgBouncer_Connection_Pool_Strategy_2026-04-05` for the full rollout.

2. **Scheduler thread pool is size 10, shared with infrastructure jobs.** A single hung tenant in `OrderReleaseJob` or `ReplenishOrderJob` ties up a scheduler thread. If multiple long runs pile up, `TenantConfigLoader` and `TenantPoolEvictor` fail to fire on schedule — which in turn starves new-tenant discovery and stops pool eviction. No alerting on this today.

3. **Two jobs ignore sysprop cron settings.** `ReleaseExpiredPickingOrdersFromUserJob` has `40 * * * * *` hard-coded (line 223 region of `SchedulingConfiguration`). `StockSummaryExportJob`'s seconds field is hard-coded `0`. Changing cadence means a code change + deploy, not a sysprop update.

4. **Per-job activation defaults are inconsistent.** `ORDER_TIMER_ACTIVATED_KEY` and `REPLENISHMENT_TIMER_ACTIVATED_KEY` default to `true`; `CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY` and `PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY` default to `false`. Easy to miss when enabling `app.cron=true` in a new environment.

5. **Tenant context is manual everywhere in jobs.** Each business job sets/clears `TenantContext` in a per-tenant try/finally. A refactor that accidentally drops the `finally { TenantContext.clear(); }` would leak context across iterations — the next tenant's work would silently run against the previous tenant's DB.

6. **~~No Micrometer timers on any job.~~** ✅ **Resolved by SBDEV-2238-4.5 (2026-05-18).** All five business cron jobs (`OrderReleaseJob`, `ReplenishOrderJob`, `StockSummaryExportJob`, `CleanUpOldMessagesJob`, `ReleaseExpiredPickingOrdersFromUserJob`) now emit Micrometer metrics via the new `JobMetrics` helper class (`schedulejob/JobMetrics.java`). Metrics per job: `wms2.cron.<job>.duration` (full-run Timer), `wms2.cron.<job>.tenant_duration{tenant}` (per-tenant Timer), `wms2.cron.<job>.success{tenant}`, `wms2.cron.<job>.failure{tenant,reason}`, `wms2.cron.<job>.skipped_lock_busy`, `wms2.cron.<job>.skipped_not_activated{tenant}`, `wms2.cron.<job>.rows_processed{tenant}`, `wms2.cron.<job>.last_run_epoch_seconds` and `last_success_epoch_seconds` gauges. `micrometer-registry-prometheus` added to `pom.xml`; `prometheus` added to `management.endpoints.web.exposure.include`. `OutboxDispatcherJob` already had its own Micrometer counters from SBDEV-2221. `StaleClubBatchCleanupJob` and `RestIdempotencyCleanupJob` are a **parity gap** — not instrumented in this ticket.

7. **~~`CleanUpOldMessagesJob` batched delete loop is unbounded.~~** ✅ **Resolved by SBDEV-2220 (2026-05-10).** Batch size is now sysprop-driven (`CLEAN_UP_OLD_MESSAGES_BATCH_SIZE`, default 1000, clamped [1, 100000]), each batch runs in its own REQUIRES_NEW tx, and an optional inter-batch sleep is available via `CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS`. The loop terminates when a batch returns fewer than batchSize rows.

8. **`ReplenishOrderJob.RUNNING` guard is JVM-local.** It protects against two timer fires on the same replica; it does **not** protect across replicas (that's the advisory lock's job). If the lock breaks (landmine #1), the AtomicBoolean is not a safety net.

9. **No retry beyond per-item continue.** When a tenant fails, it's logged and skipped. The next scheduled tick retries the whole tenant from scratch — fine for idempotent sub-ops, but a long-lived stuck state (e.g. a tenant that always throws `OptimisticLockException` on the same row) will spin silently forever.

10. **Infrastructure jobs share the same scheduler pool.** If every business cron job is live and one hogs the pool, `TenantConfigLoader.scheduledRefresh` will delay too, and new tenants will take longer than 5 min to become routable.

---

## 8. Operational Runbook Hooks

Not a runbook, but cross-referenced:

| If you see… | Start at |
|---|---|
| "Job X ran twice, wrote double state transitions" | §2 (lock ID present?), §7 item 1 (PgBouncer?) |
| "Cron job on replica A runs fine, replica B never fires" | §3.3 (did the 60 s startup gate timeout?), §7 item 10 (pool starved?) |
| "ReplenishOrderJob tenant failures in logs" | §4.2 error resilience, then `260424-connection-pool-exhaustion-fix-plan.md` and the replenish debug plans |
| "New tenant not appearing after config row inserted" | §5.1 (5 min refresh) or hit `/v3/tenant/health` for the tenant |
| "Cron should fire every minute but fires erratically" | §3.2 pool size 10 — is another job blocking threads? |
| "OMS isn't getting stock summary at 3am" | §4.3 — check `WEBSERVICE_STOCK_COUNT_URL_KEY` + `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED_KEY` + `message` table for 503s |
| "Picking orders staying locked to operator after crash" | §4.5 — but only activates if `PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY=true` (default false) |

---

## 9. How to use this doc

| Task | Start at |
|---|---|
| Add a new cron job | §2 (reserve next lock ID, e.g. `100006L`), §4 (copy the skeleton), §3.1 (wire in `SchedulingConfiguration`), §7 items 1/4/5 |
| Enable cron in a new environment | §3.4 (`app.cron=true` + per-job activation sysprops) |
| Plan PgBouncer migration | §7 item 1 in full + `260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md` |
| Tune a job's cadence | §4.x (find the sysprop key in the relevant job's table), then update landlord sysprop — except for the two hard-coded in §7 item 3 |
| Diagnose "cron silently not running" | §3.3 startup gate, §3.4 gates, §6 summary table |

---

## 10. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | All `@Scheduled` annotations under `src/main/java`, `AdvisoryLockService.JobLockId` constants, `SchedulingConfiguration` wiring, per-job activation/cron sysprop keys, error-handling shape, TX annotations on each inner service method, `TaskScheduler` bean definition, `SchedulingEnablementConfig` | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-08 | `service/job/*` directory contents (CleanUpOldMessageJobService, ReleaseOrderJobService, ReplenishOrderJobService, **StaleClubBatchCleanupJobService** — added by SBDEV-2164). `schedulejob/` contains 6 business jobs + 1 SchedulingConfiguration. `JobLockId` enum has 6 entries (added `STALE_CLUB_BATCH_CLEANUP = 100006L`). §1 overview, §2 lock-id table, §6 summary, §4.6 added. Group C resolutions (commits in `OrderReleaseJobService` / `ReplenishOrderJobService` re: optimistic-lock catches) confirmed: 9 sites of `OptimisticLockingFailureException` / `OptimisticLockException` catches across these two services per current source tree. | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-12 | SBDEV-2222: `RestIdempotencyCleanupJob.java` added to `schedulejob/`; `JobLockId.CLEANUP_REST_IDEMPOTENCY = 100007L` added to `AdvisoryLockService`; cron driven by `app.cron.cleanup-rest-idempotency=0 0 2 * * *` (no DB sysprop gate). §2 lock-id table, §4.7 detail block, §6 summary updated. `schedulejob/` now contains 7 business jobs. | §2 +1 row, §4.7 added, §6 +1 row confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-17 | SBDEV-2221: `OutboxDispatcherJob.java` added to `schedulejob/`; `OutboxDispatchService.java` added to `service/job/`; `JobLockId.OUTBOX_DISPATCHER = 100008L` added to `AdvisoryLockService`; cron every 15 s (`app.cron.outbox-dispatcher=*/15 * * * * *`, no DB sysprop gate). §1 overview updated (7 business jobs), §2 lock-id table +1 row, §4.8 detail block added, §6 summary +1 row. `schedulejob/` now contains 8 business jobs. | §2 +1 row, §4.8 added, §6 +1 row confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-18 | SBDEV-2238-4.5: `JobMetrics.java` helper added to `schedulejob/`; all 5 existing business cron jobs instrumented (`OrderReleaseJob`, `ReplenishOrderJob`, `StockSummaryExportJob`, `CleanUpOldMessagesJob`, `ReleaseExpiredPickingOrdersFromUserJob`). `micrometer-registry-prometheus` added to `pom.xml`; `prometheus` added to `management.endpoints.web.exposure.include`. §7.6 landmine resolved (was "No Micrometer timers on any job"). Parity gap: `StaleClubBatchCleanupJob` (100006L) and `RestIdempotencyCleanupJob` (100007L) not yet instrumented. | §7.6 resolved, verification log updated | Code read (grep-based) |
| 2026-06-01 | SBDEV-2381: `OutboxDispatchService` / `OutboxMessageRepository.findAndClaimPending` — claim query gained `ORDER BY next_attempt_at, id` + fail-closed cross-tick `NOT EXISTS` ordering gate; `dispatchBatch` sorts the claimed batch by `(nextAttemptAt, aggregateType, aggregateId, id)` before a sequential POST loop; each POST body carries `event_version = outbox id`. New index migration `V2.1.14`. Advisory lock 100008L and `*/15 * * * * *` cadence unchanged. §4.8 Dispatch-phases row + new Ordering row added. | §4.8 updated; ordering confirmed against `OutboxMessageRepository.findAndClaimPending` + `OutboxDispatchService.dispatchBatch/dispatchOne` (PR #35, commits 567fba3 + 41ad7d3) | Code read (grep-based) |

**Re-verify every 60 days.** Next due: **2026-07-31** — or sooner if `app.cron` is enabled in production, new jobs added, or PgBouncer migration lands (items in §7 will change).
