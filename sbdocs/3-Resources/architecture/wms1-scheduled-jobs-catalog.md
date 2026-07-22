---
title: "WMS v1 — Scheduled Jobs Catalog"
type: architecture
status: active
version: v1
scope: scheduled-jobs
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-07-09
verified_by: code read of v1/wms-api src/main at commit HEAD
related:
  - ./wms2-scheduled-jobs-catalog.md
tags:
  - architecture
  - scheduled-jobs
  - cron
  - wms1
---

# WMS v1 — Scheduled Jobs Catalog

**Scope:** Every scheduled job in `v1/wms-api` · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26

---

## 1. Overview

`wms-api` runs six recurring cron jobs in-process, all gated behind `app.cron=true` (`application.properties:94`, default `false`). Historically there was no advisory-lock mechanism — **v1 assumed a single-replica deployment**, and running multiple replicas with `app.cron=true` would cause duplicate job execution with no mutual exclusion. As of plan `260709` (duplicate-replenishment guard), **`ReplenishOrderJob` is now the exception**: its generation pass runs under a transaction-scoped PostgreSQL advisory lock (`pg_try_advisory_xact_lock`, `WmsConstants.ADVISORY_CLASS_REPLENISH_RUN`) and skips if another run already holds it (see §3.2). The other five jobs remain unguarded.

Three load-bearing facts:

1. **No cross-replica lock (except `ReplenishOrderJob`).** Historically v1 had no equivalent of v2's `pg_try_advisory_lock`; mutual exclusion was assumed by architecture (one node runs cron). Since plan `260709`, `ReplenishOrderJob.doCalculation` acquires a run-level `pg_try_advisory_xact_lock` (cross-replica safe, per-tenant DB), so overlapping replenishment generations no longer duplicate. The remaining five jobs still rely on single-node deployment.
2. **Cron schedules are read from the DB at startup, not dynamically.** `SchedulingConfiguration.configureTasks()` reads `LosSysprop` once when the application starts and wires fixed `CronTrigger`s. Changing a schedule sysprop at runtime has no effect until the next restart.
3. **`ReleaseExpiredPickingOrdersFromUserJob` has a hard-coded cron.** Its schedule `0 * * * * *` (every minute at :00) is not driven by any sysprop. All other jobs read their hour/minute from the DB.

---

## 2. Scheduling Infrastructure

### 2.1 Enablement gate

`SchedulingConfiguration` (`schedulejob/SchedulingConfiguration.java`) is annotated:

```java
@Configuration
@EnableScheduling
@ConditionalOnProperty(name = "scheduling.enabled", matchIfMissing = true)
```

The class-level gate is `scheduling.enabled` (defaults to `true` if absent). The *business* gate is checked at runtime inside `configureTasks()` via `basicService.isCron()`, which reads `@Value("${app.cron}")`. Both must be satisfied for jobs to be wired.

| Property | Default | Where |
|---|---|---|
| `scheduling.enabled` | `true` (missing = true) | `application.properties` / JVM arg |
| `app.cron` | `false` | `application.properties:94` |

When `app.cron=false`, `configureTasks()` logs `"Started WMS-API only without CRON"` and returns without registering any cron tasks. No jobs run.

### 2.2 `TaskScheduler` bean

`SchedulingConfiguration.java:58-64`:

```java
ThreadPoolTaskScheduler threadPoolTaskScheduler = new ThreadPoolTaskScheduler();
threadPoolTaskScheduler.setPoolSize(POOL_SIZE);   // 10
threadPoolTaskScheduler.setThreadNamePrefix("my-scheduled-task-pool-");
threadPoolTaskScheduler.initialize();
scheduledTaskRegistrar.setTaskScheduler(threadPoolTaskScheduler);
```

- **Pool size: 10** (constant at line 30). Shared across all five jobs.
- **No startup delay / readiness gate.** Schedules are wired synchronously inside `configureTasks()` which runs at Spring context refresh. If the DB is not reachable at startup, schedule reading fails.

### 2.3 Schedule wiring — startup-time DB read

All cron expressions except `ReleaseExpiredPickingOrdersFromUserJob` are assembled from two sysprops read at startup:

```java
String hours   = losSyspropRepository.findSysvalueBySyskey(SYSTEM_PROPERTY_*_HOUR_KEY);
String minutes = losSyspropRepository.findSysvalueBySyskey(SYSTEM_PROPERTY_*_MINUTE_KEY);
String cronjob = "0 " + minutes + " " + hours + " * * *";
```

This means all five "configurable" jobs fire at most once per hour at the configured minute. Defaults (from `WmsConstants`) produce `"0 * * * * *"` (every minute) for order-release and replenishment, `"0 55 2 * * *"` for clean-up, and `"0 0 3 * * *"` for stock export.

### 2.4 Global gates (sysprops in `LosSysprop` table)

| Key | Java Constant | Default | Role |
|---|---|---|---|
| `NEW_CRON_JOB_ACTIVATED` | `SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` | `"true"` | Top-level gate, checked first in every job |
| `CRON_JOB_SHOW_LOG` | `SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG_KEY` | `"false"` | Verbose debug logging across all jobs (TTL-cached) |

Every job checks both `NEW_CRON_JOB_ACTIVATED` and its own `*_ACTIVATED` key before doing any work. `app.cron=true` alone does not start any job — each needs its own activation flag too.

---

## 3. Business Cron Jobs

All five share the same skeleton:

```java
public void doCalculation(Boolean isCronJob) {
    if (isCronJob)
        if (!parseBoolean(losSyspropRepository.findSysvalueBySyskey(NEW_CRON_JOB_ACTIVATED_KEY))
            || !parseBoolean(losSyspropRepository.findSysvalueBySyskey(THIS_JOB_ACTIVATED_KEY))) {
            return;
        }
    // ... do work
}
```

No v1 job uses a JVM-local `AtomicBoolean` RUNNING guard (unlike v2's `ReplenishOrderJob`). `ReplenishOrderJob` instead uses a **DB-level** transaction-scoped advisory lock (cross-replica, not JVM-local) since plan `260709` — see §3.2.

---

### 3.1 `OrderReleaseJob`

| | |
|---|---|
| **Scheduler class** | `schedulejob/OrderReleaseJob.java` |
| **Backing service** | `service/job/ReleaseOrderJobService.java` |
| **Wired in** | `SchedulingConfiguration.orderRelease()` (lines 97–108) |
| **Cron schedule** | `"0 {ORDER_TIMER_MINUTE} {ORDER_TIMER_HOUR} * * *"` — read from DB at startup |
| **DB property keys** | `ORDER_TIMER_MINUTE` (default `"*"`), `ORDER_TIMER_HOUR` (default `"*"`) → effective default: every minute |
| **Activation keys** | `NEW_CRON_JOB_ACTIVATED` (default `true`) + `ORDER_TIMER_ACTIVATED` (default `true`) |
| **Reads** | `customerorderposition` in state `< ASSIGNED` with type `PICK_PACK` and `pickingdate <= today`; `fixlocationassignment`; warehouse timezone sysprop; `stockunit.availableamount` per fix assignment |
| **Mutates** | `customerorderposition.state`, `customerorder.state`, `customerorderbatch.state`, `pickingorder` (created), `pickingorderposition` (created), `stockunit.reservedamount` |
| **Transaction strategy** | `ReleaseOrderJobService.releaseOrder()` is `@Transactional(propagation = REQUIRES_NEW)` — one independent TX per order |
| **Error behavior** | Per-order try-catch (`OptimisticLockException` / `OptimisticLockingFailureException` / `FacadeException` / `BusinessException`) in `OrderReleaseJob.java:240`. One order failure is logged as WARN and skipped; the run continues. |

**What it does — step by step:**

1. Reads warehouse timezone from sysprop; formats today's date in warehouse local time.
2. Queries `customerorderposition` for all `ASSIGNED`-or-below PICK_PACK positions with `pickingdate <= today`, grouped implicitly by order. Exits early if empty.
3. Loads all `fixlocationassignment` rows and builds two in-memory maps: `itemDataFixAssignmentMap` (item → fix-assignment data cached across orders) and `itemDataAvailableAmountMap` (item → available units, updated per order).
4. **Pre-round per order** (cheapest path — avoids entering `REQUIRES_NEW` TX if not needed): walks cached maps to determine whether anything has changed since the last iteration. Skips orders whose positions all look unchanged (no stock delta, no status drift).
5. **Release round** (inside `REQUIRES_NEW` TX): for each unresolved position, checks fix-assignment validity (unitload present, correct SKU, on correct location, assignment active) and stock sufficiency. Positions that fail are set to the appropriate `RAW_ON_HOLD_*` state and saved. If all positions satisfy their supply, proceeds to picking-order creation.
6. Creates one `pickingorder` (state `PROCESSABLE`) per customer order; creates `pickingorderposition` rows linking positions to stock units; reserves stock via `stockunitBusinessService.changeReservedAmount()`.
7. Sets `customerorderposition.state = ASSIGNED`, `customerorder.state = ASSIGNED`, `customerorderbatch.state = STARTED` (if not already).
8. Defers OMS notification (`manageOrderService.customerOrderReleaseForPicking`) via `OmsNotificationHelper.deferToCommit()` — fires after the TX commits.
9. On hold path: if any position is unsatisfied, sets `customerorder.state = RAW_ON_HOLD` and defers `manageOrderService.customerOrderOnHold()`.
10. Returns updated `itemDataAvailableAmountUpdateMap` so the caller can fold new stock readings back into the cross-order cache.

**State transitions fired:**

| Entity | From | To | Condition |
|---|---|---|---|
| `customerorderposition` | any `< ASSIGNED` | `RAW` | healing (position was on-hold, stock now available) |
| `customerorderposition` | any | `RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION` | no fix assignment, no overstock |
| `customerorderposition` | any | `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` | fix assignment exists, stock below required |
| `customerorderposition` | any | `RAW_ON_HOLD_PROBLEM_WITH_FIXED_ASSIGNED_LOCATION` | fix assignment invalid (wrong SKU, wrong location, no unitload, label mismatch) |
| `customerorderposition` | any | `RAW_ON_HOLD_FIX_ASSIGNMENT_IS_INACTIVE` | fix assignment inactive flag |
| `customerorderposition` | `RAW` | `ASSIGNED` | all positions satisfiable |
| `customerorder` | `RAW` / `FUTURE_PICKING_DATE` / `CLIENT_HAS_NO_SECTION` | `RAW_ON_HOLD` | any position unsatisfied |
| `customerorder` | `< ASSIGNED` | `ASSIGNED` | all positions assigned |
| `customerorderbatch` | `< STARTED` | `STARTED` | first order in batch assigned |
| `pickingorder` | (new) | `PROCESSABLE` | created on successful release |

**Note — `ReleaseOrderJobService` is the 2nd hottest file in the codebase (33 touches).** It contains the full stock-satisfaction logic with six distinct `RAW_ON_HOLD_*` failure paths and the two-list (fix-assignment vs overstock) picking-position creation logic. Any service that manages `fixlocationassignment`, `stockunit`, `customerorderposition`, or `pickingorder` is in this job's blast radius.

---

### 3.2 `ReplenishOrderJob`

| | |
|---|---|
| **Scheduler class** | `schedulejob/ReplenishOrderJob.java` |
| **Backing service** | `service/job/ReplenishOrderJobService.java` |
| **Wired in** | `SchedulingConfiguration.replenish()` (lines 114–125) |
| **Cron schedule** | `"0 {REPLENISHMENT_TIMER_MINUTE} {REPLENISHMENT_TIMER_HOUR} * * *"` — read from DB at startup |
| **DB property keys** | `REPLENISHMENT_TIMER_MINUTE` (default `"*"`), `REPLENISHMENT_TIMER_HOUR` (default `"*"`) → effective default: every minute |
| **Activation keys** | `NEW_CRON_JOB_ACTIVATED` + `REPLENISHMENT_TIMER_ACTIVATED` (default `true`) |
| **Sub-feature gates** | `MERGE_PICKING_ORDERS` (default `true`), `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` (default `false` — note: typo preserved) |
| **Tunables** | `PICKING_BOX_PER_CART` (default `6`), `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` (default `84`) |

**Run serialization (plan `260709`):** `doCalculation` delegates to `@Transactional doCalculationGuarded()` (via the `self` proxy). Its first statement acquires a non-blocking transaction-scoped advisory lock `pg_try_advisory_xact_lock(ADVISORY_CLASS_REPLENISH_RUN, 0)` (`AdvisoryLockRepository`); if another run/replica already holds it, this run logs and skips. The lock is held for the whole run (the `REQUIRES_NEW` sub-steps only suspend the outer transaction) and auto-releases at run end — no session lock, no explicit unlock. This closes the concurrent-double-run that generated duplicate replenishment orders. Note: the outer transaction now pins one connection for the run (peak 3 of `maximumPoolSize=5` with the nested `REQUIRES_NEW` steps), and `recalculateReplenishmentOrderWithoutFixedLocationAssignment` / `recalculateOpenOrders` now participate in the run transaction (idempotent; self-heals next run).

**Nine sub-operations per run (in order):**

1. **`mergePickingOrders()`** — gated on `MERGE_PICKING_ORDERS`. Finds sections with `TOTES_ON_CART` picking type; queries `pickingorder` rows in state `RESERVED` with `boxesPerCart` capacity; merges multiple small picking orders into fewer larger ones up to `boxesPerCart` totes. Uses `@Transactional(REQUIRES_NEW)` via `self.mergePickingOrders()` self-invocation through Spring proxy.
2. **`deleteEmptyFixAssignmentWithoutStockToReplenish()`** — gated on `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY`. Finds fix assignments with no stock left (shipped/cancelled/finished states). Calls `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish()` (`REQUIRES_NEW` per ID).
3. **`cancelUnreachableReplenishment()`** — queries replenish orders in `PROCESSABLE` state for unreachable locations. Calls `ReplenishOrderJobService.cancelReplenishmentOrder()` (`REQUIRES_NEW` per ID).
4. **`cancelReplenishmentIfFlowbinIsFull()`** — queries replenish orders for flowbins already at capacity. Calls `cancelReplenishmentOrder()` (`REQUIRES_NEW` per ID).
5. **`generateReplenishmentForItemDataWithoutFixedAssignment()`** — finds item data with `RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION` positions. Creates replenishment orders via `replenishGeneratorService.calculateOrder()` (`REQUIRES_NEW` per itemDataId, upper-bound from `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND`).
6. **`generateReplenishmentForItemDataWithFixedAssignmentWithOrders()`** — finds fix assignments where stock is below `middlebound` and pending orders exist. Creates replenishment orders (`REQUIRES_NEW` per fixAssignmentId).
7. **`triggerRegularReplenishment()`** — finds fix assignments with `FINISHED` stock (fully depleted). Calls `ReplenishOrderJobService.refillFixedLocationAssignment()` (`REQUIRES_NEW` per flaId, `rollbackFor = FacadeException.class`).
8. **`updateReplenishmentOrderPriority()`** — finds replenish orders in `STARTED`/`ASSIGNED` state without linked customer orders → sets priority `PRIORITY_VERY_LOW`. Then iterates all customer-order priority levels and aligns replenish-order priority (`REQUIRES_NEW` per replenishOrderId).
9. **`recalculateReplenishmentOrderWithoutFixedLocationAssignment()`** — recalculates open overstock replenishment orders (`REQUIRES_NEW`).
10. **`replenishmentOrderMaintenanceService.recalculateOpenOrders(true)`** — called directly on the maintenance service (no job-service wrapper); uses that service's own TX scope.

**Entities mutated:** `fixlocationassignment`, `replenishorder`, `pickingorder`, `pickingorderposition`, `stockunit`, `unitload`

**Transaction strategy:** Every sub-operation in `ReplenishOrderJobService` is `@Transactional(propagation = REQUIRES_NEW)` — each item/fix-assignment gets an independent TX. `mergePickingOrders()` is `REQUIRES_NEW` on the `ReplenishOrderJob` itself (self-proxy pattern via `@Autowired private ReplenishOrderJob self`).

**Error behavior:** Per-item try-catch for `OptimisticLockException` / `OptimisticLockingFailureException` in sub-operations 2, 5, 6, 7, 8, 9. `cancelReplenishmentOrder` swallows `FacadeException` internally. No per-run guard (`AtomicBoolean`) — unlike v2.

**Notable bug in sub-operation 2:** `deleteEmptyFixAssignmentWithoutStockToReplenish()` checks `WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY_KEY` directly (the constant's string value `"false"`) rather than reading it from the DB — the gate is permanently `false` regardless of the sysprop's DB value (`ReplenishOrderJob.java:200`).

---

### 3.3 `StockSummaryExportJob`

| | |
|---|---|
| **Scheduler class** | `schedulejob/StockSummaryExportJob.java` |
| **Backing service** | none (all logic inline) |
| **Wired in** | `SchedulingConfiguration.stockSummaryExport()` (lines 131–142) |
| **Cron schedule** | `"0 {STOCK_SUMMARY_EXPORT_TIMER_MINUTE} {STOCK_SUMMARY_EXPORT_TIMER_HOUR} * * *"` — read from DB at startup |
| **DB property keys** | `STOCK_SUMMARY_EXPORT_TIMER_MINUTE` (default `"0"`), `STOCK_SUMMARY_EXPORT_TIMER_HOUR` (default `"3"`) → effective default: 03:00 daily |
| **Activation keys** | `NEW_CRON_JOB_ACTIVATED` + `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED` (default `true`) |
| **Batching** | `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED` (default `true`), `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH` (default `250`) |
| **Endpoint** | `WEBSERVICE_STOCK_COUNT` (default: `https://oms-XXXXX.siteboss.net/call/inventory/stockCountExport`) |
| **Reads** | Aggregated stock counts via `warehouseStockReportService.getStockCount()` |
| **Mutates** | `inventoryrecord` (one row per SKU via `inventoryRecordService.createEntity()`); `message` / `message_archive` (audit of each HTTP POST) |
| **Transaction strategy** | No job-level `@Transactional`; `inventoryRecordService` and `messageService` carry their own TX |
| **Error behavior** | `IOException` from HTTP POST caught per batch; writes a `FAILED` message row with HTTP code `"503"` and logs error. `BusinessException` from message persistence caught separately and logged. Per-batch failure does not abort the run. |

**What it does:**

1. Calls `warehouseStockReportService.getStockCount()` for a full warehouse stock snapshot.
2. Determines `inventoryRecordType`: `AUTOMATIC` if running as anonymous user (cron context), `MANUAL` otherwise.
3. Creates one `inventoryrecord` row per SKU.
4. If `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED=true`: splits the stock list into batches of `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH` and POSTs each batch to OMS. Otherwise POSTs the full list in one call.
5. Each POST result (success or failure) is persisted as a `message` row with status `SENT` or `FAILED`.

---

### 3.4 `CleanUpOldMessagesJob`

| | |
|---|---|
| **Scheduler class** | `schedulejob/CleanUpOldMessagesJob.java` |
| **Backing service** | `service/job/CleanUpOldMessageJobService.java` |
| **Wired in** | `SchedulingConfiguration.cleanUpOldMessages()` (lines 80–91) |
| **Cron schedule** | `"0 {CLEAN_UP_OLD_MESSAGES_TIMER_MINUTE} {CLEAN_UP_OLD_MESSAGES_TIMER_HOUR} * * *"` — read from DB at startup |
| **DB property keys** | `CLEAN_UP_OLD_MESSAGES_TIMER_MINUTE` (default `"55"`), `CLEAN_UP_OLD_MESSAGES_TIMER_HOUR` (default `"2"`) → effective default: 02:55 daily |
| **Activation keys** | `NEW_CRON_JOB_ACTIVATED` + `CLEAN_UP_OLD_MESSAGES_ACTIVATED` (default **`false`** — the only job off by default beyond the global gate) |
| **Retention** | `CLEAN_UP_OLD_MESSAGES_PERIOD` (default `"365"` days) |
| **Reads** | `message` rows older than `today - period_days` |
| **Mutates** | `message_archive` (insert via `messageRepository.archiveMessages(refDate)`); `message` (batched delete via `messageRepository.deleteMessages(refDate)`) |
| **Transaction strategy** | Repository-level TX per batch delete; each `deleteMessages()` call commits independently |
| **Error behavior** | No try-catch in `archiveMessage()` — any exception propagates and aborts the run for this invocation. No per-tenant loop (single-tenant in v1). |

**What it does:**

1. Reads `CLEAN_UP_OLD_MESSAGES_PERIOD` from DB; computes `refDate = today - period days`.
2. Calls `messageRepository.archiveMessages(refDate)` — bulk INSERT INTO `message_archive` SELECT from `message WHERE created_at < refDate`.
3. Calls `messageRepository.deleteMessages(refDate)` in a `do...while` loop until zero rows deleted — batched delete to avoid one giant transaction.

**Landmine:** The batched delete loop is unbounded. On a first run against a large old `message` table this can execute for hours. No row-count cap.

---

### 3.5 `ReleaseExpiredPickingOrdersFromUserJob`

| | |
|---|---|
| **Scheduler class** | `schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` |
| **Backing service** | none (all logic inline) |
| **Wired in** | `SchedulingConfiguration.releaseExpiredPickingOrdersFromUser()` (lines 148–157) |
| **Cron schedule** | **Hard-coded** `"0 * * * * *"` — every minute at :00 (no sysprop; changing cadence requires a code change + deploy) |
| **Activation keys** | `NEW_CRON_JOB_ACTIVATED` + `PICK_TIME_OUT_SYSTEM_ACTIVATED` (default **`false`**) |
| **Timeout** | `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` (default `"40"` seconds) |
| **Reads** | `pickingorder` rows in state `PICKED`, section picking type `RAPID_PICKING`, `locked_to_operator` timestamp older than `now - timeout_seconds` |
| **Mutates** | `pickingorder.operator_id = null`, `pickingorder.lockedtooperator = false` |
| **Transaction strategy** | `pickingorderRepository.save()` auto-TX per row |
| **Error behavior** | No try-catch; any exception propagates. Single-tenant — no per-tenant loop. |

**What it does:**

1. Reads `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE`; computes threshold = `LocalDateTime.now() - timeout_seconds`.
2. Queries `pickingorderRepository.getPickingOrdersToReleaseExpiredPickingOrders(PICKED, RAPID_PICKING, threshold)` for picking orders locked to an operator longer than the threshold.
3. For each result: clears `operatorId` (null) and sets `lockedtooperator = false`, saves.

### 3.6 `StaleClubBatchCleanupJob`

| | |
|---|---|
| **Scheduler class** | `schedulejob/StaleClubBatchCleanupJob.java` |
| **Backing service** | `service/job/StaleClubBatchCleanupJobService.java` |
| **Wired in** | `SchedulingConfiguration.staleClubBatchCleanup()` (line 163) |
| **Cron schedule** | Daily — assembled from sysprops `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` (default `"3"`) + `STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE` (default `"0"`) → fires at 03:00 by default |
| **Activation keys** | `NEW_CRON_JOB_ACTIVATED` + `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` (default **`false`**) |
| **Reads** | `customerorder_batch` rows in `ORDER_BATCH_ACTIVATED` state where all child `customerorder` rows are `>= FINISHED` — via `CustomerorderBatchRepository.findStaleClubBatchIds()` |
| **Mutates** | Calls `CustomerorderBatchService.finalizeBatchIfComplete()` per batch — drives stuck batches to their correct terminal state |
| **Transaction strategy** | **No `@Transactional` on service** — each `finalizeBatchIfComplete()` runs in its own TX via `CustomerorderBatchService`'s class-level `@Transactional`. Intentional: prevents a single `OptimisticLockException` from rolling back all prior corrections in the same run |
| **Safety cap** | 500 candidates per run (`MAX_CANDIDATES_PER_RUN`); batches beyond the cap are deferred to the next tick |
| **Error behavior** | Per-batch try-catch; one failure logs WARN and continues — stale batch is retried next run |

**What it does:**

This is a **corrective job**, not a primary flow driver. Club batches can get stuck in `ORDER_BATCH_ACTIVATED` state when all child orders complete individually but the batch finalization step was missed (e.g., concurrent `OptimisticLockException` or process crash). The job detects these and drives them to their correct terminal state.

1. Queries `customerorder_batch` in `ORDER_BATCH_ACTIVATED` where all orders are `>= FINISHED`, limited to 500.
2. For each candidate: loads the batch, calls `finalizeBatchIfComplete()`, logs before/after state.
3. Logs corrected/failed counts at completion. Warns if candidate list hit the cap (more remain for next run).

---

## 4. Summary Table

| Job | Default schedule | Activation gate | Extra gate | Per-step TX | Error scope |
|---|---|---|---|---|---|
| `OrderReleaseJob` | every min (`0 * * * * *`) | `app.cron` + `NEW_CRON_JOB_ACTIVATED` (default `true`) | `ORDER_TIMER_ACTIVATED` (default `true`) | `REQUIRES_NEW` per order | per-order try-catch |
| `ReplenishOrderJob` | every min (`0 * * * * *`) | `app.cron` + `NEW_CRON_JOB_ACTIVATED` (default `true`) | `REPLENISHMENT_TIMER_ACTIVATED` (default `true`) + 2 sub-gates | `REQUIRES_NEW` per item/fix/merge | per-item try-catch |
| `StockSummaryExportJob` | 03:00 daily | `app.cron` + `NEW_CRON_JOB_ACTIVATED` (default `true`) | `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED` (default `true`) | per-service | per-batch HTTP IOException |
| `CleanUpOldMessagesJob` | 02:55 daily | `app.cron` + `NEW_CRON_JOB_ACTIVATED` (default `true`) | `CLEAN_UP_OLD_MESSAGES_ACTIVATED` (default **`false`**) | per-batch delete | none — propagates |
| `ReleaseExpiredPickingOrdersFromUserJob` | every min at :00 (hard-coded) | `app.cron` + `NEW_CRON_JOB_ACTIVATED` (default `true`) | `PICK_TIME_OUT_SYSTEM_ACTIVATED` (default **`false`**) | per `save()` | none — propagates |
| `StaleClubBatchCleanupJob` | 03:00 daily (default) | `app.cron` + `NEW_CRON_JOB_ACTIVATED` (default `true`) | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` (default **`false`**) | per `finalizeBatchIfComplete()` via callee TX | per-batch try-catch |

---

## 5. Key Differences from v2

| Concern | v1 | v2 |
|---|---|---|
| Cross-replica mutual exclusion | None — single-replica assumed | PostgreSQL advisory locks (`pg_try_advisory_lock`) per job |
| Schedule source | DB read **once at startup** — restart required to pick up changes | DB read per-trigger (dynamic `CronTrigger` re-evaluated each fire) |
| `ReplenishOrderJob` JVM guard | None | JVM-local `AtomicBoolean RUNNING` |
| Startup gate | Immediate wiring at `configureTasks()` | Polls tenant DB readiness up to 60 s before wiring |
| Tenant loop | No — single tenant per instance | Yes — per-`TenantProfile` loop with manual `TenantContext` set/clear |
| Observability | `System.currentTimeMillis()` deltas in logs | Same (no Micrometer timers on jobs in either version) |
| `ReleaseExpiredPickingOrdersFromUserJob` cron | `0 * * * * *` (hard-coded, fires at :00) | `40 * * * * *` (hard-coded, fires at :40) |

---

## 6. Known Landmines

1. **No cross-replica lock.** If `app.cron=true` on more than one replica simultaneously, all six jobs run in parallel on every replica — no advisory lock, no guard. Double state transitions will occur. This is the most critical operational constraint in v1.

2. **Cron schedules are startup-time snapshots.** Updating `ORDER_TIMER_HOUR` or any other schedule sysprop in the DB has zero effect until the app restarts. This is easy to miss when tuning cadence in production.

3. **`ReleaseExpiredPickingOrdersFromUserJob` has a hard-coded cron.** `"0 * * * * *"` is in source code (`SchedulingConfiguration.java:149`). No sysprop controls it. To change cadence: code change + deploy.

4. **`deleteEmptyFixAssignmentWithoutStockToReplenish` gate is broken.** `ReplenishOrderJob.java:200` checks `Boolean.parseBoolean(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY_KEY)` — it evaluates the constant's string value `"FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY"` (not its DB value), which always parses as `false`. The sub-operation never runs regardless of the DB sysprop.

5. **`CleanUpOldMessagesJob` unbounded delete loop.** `do { deleteMessages(refDate) } while (count > 0)` has no safety cap. First run on a large table can lock the scheduler thread for hours, starving other jobs.

6. **Per-job activation defaults are inconsistent.** `ORDER_TIMER_ACTIVATED` and `REPLENISHMENT_TIMER_ACTIVATED` default to `true`; `CLEAN_UP_OLD_MESSAGES_ACTIVATED` and `PICK_TIME_OUT_SYSTEM_ACTIVATED` default to `false`. Turning on `app.cron=true` in a new environment immediately starts order-release and replenishment.

7. **`StockSummaryExportJob` has no `@Transactional`.** `inventoryrecord` rows are created before the HTTP POST. If the POST partially fails across batches, `inventoryrecord` rows for sent batches persist but no compensating logic rolls them back.

8. **`ReleaseOrderJobService` `in-memory maps persist across orders within a single run.** `itemDataFixAssignmentMap` and `itemDataAvailableAmountMap` are built outside the per-order `REQUIRES_NEW` TX and mutated inside it. If a TX rolls back, the map entries written inside it are not rolled back — subsequent orders in the same run may use stale stock availability data.

9. **No retry beyond per-item continue.** Failed items are skipped and retried from scratch on the next scheduled tick. A row that permanently throws `OptimisticLockException` will spin in logs indefinitely without alerting.

---

## 7. Operational Runbook Hooks

| If you see… | Start at |
|---|---|
| "Order-release job ran twice, double picking orders created" | §6 item 1 (multiple replicas with `app.cron=true`?) |
| "Changed schedule sysprop, job still fires at old time" | §2.3 (startup snapshot — restart required) |
| "Replenishment deleting empty fix assignments not working" | §5, §6 item 4 (broken gate — always false) |
| "Clean-up job runs for hours" | §3.4 (unbounded delete loop) |
| "Picking order locked to operator after operator crash" | §3.5 — only activates if `PICK_TIME_OUT_SYSTEM_ACTIVATED=true` (default false) |
| "OMS not getting stock summary" | §3.3 — check `WEBSERVICE_STOCK_COUNT` sysprop + `message` table for FAILED rows |
| "Cron should fire every minute but never fires" | §2.1 (`app.cron=false`?), §2.4 (`NEW_CRON_JOB_ACTIVATED=false`?), §3.x per-job activation key |
| "Replenishment orders not being generated for overstock items" | §3.2 sub-op 5 — check `RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION` positions exist |
| "`ReleaseOrderJobService` exception for order X" | §3.1 error behavior — per-order WARN log, check fix-assignment validity for that order's SKUs |

---

## 8. How to Use This Doc

| Task | Start at |
|---|---|
| Add a new cron job | §3 (copy skeleton with double gate check), §2.2 (wire in `SchedulingConfiguration`), §2.4 (add activation sysprop), §6 item 1 (single-replica warning) |
| Enable cron in a new environment | §2.1 (`app.cron=true`), §2.4 (check `NEW_CRON_JOB_ACTIVATED`), §4 summary table (per-job activation defaults) |
| Tune a job's cadence | §2.3 (sysprop key) + **restart required** — except `ReleaseExpiredPickingOrdersFromUserJob` (§6 item 3) |
| Diagnose "cron silently not running" | §2.1 gate, §2.4 gates, §4 summary table defaults |
| Modify a service `OrderReleaseJob` depends on | §3.1 entities-mutated table + state transitions; check `fixlocationassignment`, `stockunit`, `customerorderposition`, `pickingorder` write paths |
| Understand replenishment job blast radius | §3.2 all nine sub-operations; any change to `fixlocationassignment`, `replenishorder`, `stockunit`, or `pickingorder` may interact |
| Compare v1 vs v2 job behavior | §5 differences table |

---

## 9. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | All files in `schedulejob/`, all files in `service/job/`, `SchedulingConfiguration.java`, `WmsConstants.java` (SYSTEM_PROPERTY_* keys for all jobs), `BasicService.java` (`isCron`/`showLog`), `application.properties:94` (`app.cron` default) | All counts, sysprop keys, default values, cron expressions, TX annotations, error-handling shapes confirmed against source | Code read (grep + targeted Read) |
| 2026-05-06 | `SchedulingConfiguration.java` §3.6 `StaleClubBatchCleanupJob` entry confirmed accurate; `WmsConstants.java:1009-1014` sysprop constant names and defaults verified; sysprop-catalog §4.6 added to cover `STALE_CLUB_BATCH_CLEANUP_*` keys | §3.6 confirmed correct; six-job claim accurate; pool-size 10 accurate | Code grep |

**Re-verify when:** `app.cron` is enabled in production, a new job is added, any file in `schedulejob/` or `service/job/` is modified, or schema changes affect `customerorderposition`, `pickingorder`, `replenishorder`, `fixlocationassignment`, or `message` tables.
