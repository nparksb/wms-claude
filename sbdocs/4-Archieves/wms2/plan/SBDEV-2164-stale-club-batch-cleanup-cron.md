---
title: "v2 — Cron Cleanup for Stale Club Batches"
ticket: "SBDEV-2164"
ticket_url: "https://app.clickup.com/t/868jev5gd"
type: feature
priority: medium
status: "archived"
project: [wms2]
version: v2
requester: Joseph Gero II
created: 2026-05-03
updated: 2026-05-03
last_verified: 2026-05-03
related:
  - "[[../../../1-Projects/wms1/plan/SBDEV-2164-stale-club-batch-cleanup-cron]]"
  - "[[../../../4-Archieves/wms2/plan/SBDEV-2163-prevent-finished-club-batch-lane-reassignment]]"
  - "[[../../../3-Resources/architecture/wms2-state-machine-catalog]]"
  - "[[../../../3-Resources/architecture/wms2-transaction-osiv-boundary-map]]"
  - "[[../../../3-Resources/architecture/wms2-scheduled-jobs-catalog]]"
tags:
  - plan
  - club
  - wms2
  - port
  - cron
db_verified: false
---

# v2 — Cron Cleanup for Stale Club Batches

**Ticket:** [SBDEV-2164](https://app.clickup.com/t/868jev5gd)
**V1 source plan:** `sbdocs/1-Projects/wms1/plan/SBDEV-2164-stale-club-batch-cleanup-cron.md`
**V2 target:** `v2/wms2-api`
**Companion plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md` — the runtime guard that prevents *future* stale batches; this cron *corrects* batches that are already stranded.
**Status:** ready
**Date:** 2026-05-03

---

## 0. Affected Sites (Enumeration Before Drafting)

| # | File:line | Construct | Status | Phase |
|---|-----------|-----------|--------|-------|
| 1 | `schedulejob/StaleClubBatchCleanupJob.java` (new) | New cron shell — multi-tenant loop, advisory lock, sysprop gate | **New file** | Phase 1 |
| 2 | `service/job/StaleClubBatchCleanupJobService.java` (new) | New orchestration service — candidate fetch, per-batch finalize loop, exception isolation | **New file** | Phase 1 |
| 3 | `schedulejob/SchedulingConfiguration.java` `:49` (constructor); `:117` (`configureAllTasks`); after `:223` (new `configureStaleClubBatchCleanup`) | Constructor inject `StaleClubBatchCleanupJob`; call from `configureAllTasks`; register cron via `TaskScheduler.schedule(runnable, CronTrigger)` | **Modify** | Phase 1 |
| 4 | `service/WmsConstants.java:~1011` | Add 6 new sysprop key/default constants after the existing `CLEAN_UP_OLD_MESSAGES_*` block | **Modify** | Phase 1 |
| 5 | `service/AdvisoryLockService.java` (`JobLockId` static class) | Add `public static final long STALE_CLUB_BATCH_CLEANUP = 100006L` | **Modify** (NEW-2) | Phase 1 |
| 6 | `repo/jpa/CustomerorderBatchRepository.java` | New native query `findStaleClubBatchIds` — type=CLUB, state in [520,700), all orders ≥700 | **Modify** | Phase 1 |
| 7 | `db/migration/V2.1.08__stale_club_batch_cleanup_sysprops.sql` (new) | Seed 6 sysprop rows | **New file** | Phase 1 |
| 8 | `service/CustomerorderBatchService.java:346` | `finalizeBatchIfComplete` — add method-level `@Transactional(tenantTransactionManager, rollbackFor=...)` | **Modify** (NEW-1 CRITICAL) | Phase 1 |
| 9 | `test/unit/service/job/StaleClubBatchCleanupJobServiceUnitTest.java` (new) | Unit tests A1–A6 — orchestration, exception isolation, cap warning | **New file** | Phase 1 |
| 10 | `test/unit/schedulejob/StaleClubBatchCleanupJobUnitTest.java` (new) | Unit tests A7–A8 — advisory-lock skip, sysprop disabled skip | **New file** | Phase 1 |
| 11 | `test/repo/CustomerorderBatchRepositoryTest.java` (extend existing) | Integration tests A9–A10 — native query semantics over Testcontainers Postgres | **Modify** | Phase 1 |
| 12 | `test/unit/service/CustomerorderBatchServiceUnitTest.java` (extend existing) | Unit test A11 — reflection check that `finalizeBatchIfComplete` has `@Transactional(tenantTransactionManager)` | **Modify** | Phase 1 |

---

## 1. Problem Statement

Some club batches reach full order completion (all child orders shipped or cancelled) but their batch header state is never advanced to `FINISHED (700)`. These batches:

- Continue to appear in **Open Clubs** (the UI query filters `cb.state < 700`).
- May retain a **staging lane assignment** (`staginglane_id IS NOT NULL`) that blocks the lane from reuse.
- Require manual intervention by support to correct.

Root cause (v2 same as v1): `CustomerorderBatchService.finalizeBatchIfComplete()` is called on the normal shipping path (`closeBOL`), but edge cases (batch shipped across multiple BOLs, last BOL closed without triggering the finalization check) leave the batch header stranded in an intermediate state.

**Why this cron is needed even with SBDEV-2163 deployed:** SBDEV-2163's guard blocks *future* lane reassignments on finished batches. It does not auto-correct the batch state — intentionally, because silent state mutation without a BOL-close bypasses the standard `closeBOL` finalization path. Batches already stranded need a separate, auditable correction path.

**Stale open states for a club batch:**

| State constant | Value | Meaning |
|---|---|---|
| `ORDER_BATCH_ACTIVATED` | 520 | Activated but run not started |
| `ORDER_BATCH_STAGING_LANE_ASSIGNED` | 525 | Lane assigned, run not started |
| `ORDER_BATCH_CLUB_RUN_FINISHED` | 530 | Run complete but batch not closed |

**Terminal states (orders and batch):**

| State constant | Value |
|---|---|
| `FINISHED` | 700 |
| `CANCELED` | 800 |

A batch is "stale" when its state is in `[520, 699]` (inclusive) but **all** child `customerorder` rows have `state >= 700`.

---

## 2. Root Cause Analysis (v2-specific)

The v1 plan documents the underlying defect. v2 inherits the same defect because `CustomerorderBatchService.finalizeBatchIfComplete` is also only invoked from the `closeBOL` happy-path. There are no v2-specific code paths that auto-correct the batch header.

In v2 the defect is **slightly worse** than v1 because:

1. **NEW-1 (CRITICAL):** v2's `finalizeBatchIfComplete` (L346) has **no `@Transactional` annotation**. v2 uses method-level `@Transactional` per service method (no class-level, unlike v1). Without it, the three writes inside the method (`batch.setState`, `batch.setStaginglaneId(null)`, per-order `transferlaneId` clears) run as separate auto-commits. A partial failure mid-method leaves the batch with an updated state but a non-null `staginglane_id`, or vice versa — a corrupted half-finalize state that no other code path corrects.
2. **NEW-2 (HIGH):** v2/wms2-api runs as **multiple replicas behind a load balancer**. Every scheduled job must use `AdvisoryLockService` (Postgres advisory lock) to prevent concurrent execution across replicas. Without it, two replicas would both fetch the same candidate list and race on `finalizeBatchIfComplete`, producing `ObjectOptimisticLockingFailureException` on the loser, and (worse, given NEW-1) corrupted partial-write state.
3. **NEW-3 (HIGH):** v2 is multi-tenant via `TenantContext` + dynamic routing. A scheduled job has no inbound HTTP request, so no tenant context is set automatically. The job shell **must** iterate over `tenantDbConfigurationRepository.findAll()`, set `TenantContext.setCurrentTenant(profile)` per tenant, run the orchestration call, and `TenantContext.clear()` in `finally`. The canonical template is `CleanUpOldMessagesJob`.
4. **NEW-4 (MEDIUM):** v2 standardises on `syspropService.getSysvalue(key)` (Redis-backed cache + lookup) — not direct repository access. v1 uses `losSyspropRepository.findSysvalueBySyskey(key)`. The migration must use the v2 idiom for sysprop reads in both `StaleClubBatchCleanupJob` and `SchedulingConfiguration`.

These four NEW issues are **not optional**: they are intrinsic to v2's deployment model. Skipping any one of them produces an unsafe scheduled job.

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `schedulejob/StaleClubBatchCleanupJob.java` | new | New cron shell |
| 2 | `service/job/StaleClubBatchCleanupJobService.java` | new | New orchestration service |
| 3 | `schedulejob/SchedulingConfiguration.java` | `configureAllTasks` L117; new `configureStaleClubBatchCleanup` after L223 | Constructor inject + register CronTrigger |
| 4 | `service/WmsConstants.java` | ~1011 | 6 new constants |
| 5 | `service/AdvisoryLockService.java` | `JobLockId` static class | Add `STALE_CLUB_BATCH_CLEANUP = 100006L` constant |
| 6 | `repo/jpa/CustomerorderBatchRepository.java` | new method | `findStaleClubBatchIds` native query |
| 7 | `db/migration/V2.1.08__stale_club_batch_cleanup_sysprops.sql` | new | 6 sysprop rows |
| 8 | `service/CustomerorderBatchService.java` | 346 | Add `@Transactional(tenantTransactionManager, ...)` (NEW-1) |

---

## 3. Design / Proposed Fix

### 3.1 NEW-1 (CRITICAL) — Add `@Transactional` to `finalizeBatchIfComplete`

**Problem:** v2 `CustomerorderBatchService.finalizeBatchIfComplete(Long batchId)` at L346 has no method-level `@Transactional`. v2 has no class-level `@Transactional` (unlike v1). The three writes the method performs run as separate auto-commits. Partial failure produces an inconsistent half-finalized batch.

**Solution (method-level annotation):**

```java
// CustomerorderBatchService.java, at L346 (immediately above the existing signature)
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void finalizeBatchIfComplete(Long batchId) {
    // existing body unchanged
}
```

**Why `@Transactional(REQUIRED)` (default propagation) is safe for existing callers:**

| Caller | v2 file:line | Already in transaction? | Effect with new `@Transactional` |
|---|---|---|---|
| `PickingorderBusinessService` | `:350` | Yes — caller is `@Transactional(tenantTransactionManager)` | Joins existing transaction. Happy-path unchanged. **Failure-path change:** a `BusinessException` thrown inside `finalizeBatchIfComplete` will now mark the outer transaction rollback-only (was: auto-committed partial writes). |
| `CustomerorderService` | `:408` | Yes — caller is `@Transactional(tenantTransactionManager)` | Same failure-path change as above. |
| `CustomerorderService` | `:680` | Yes — caller is `@Transactional(tenantTransactionManager)` | Same failure-path change as above. |
| **NEW: `StaleClubBatchCleanupJobService.cleanupStaleBatches`** | new | **No** — orchestration loop has no `@Transactional` | Each call opens its own per-batch transaction (the property we need for per-batch isolation) |

The intentionally-non-transactional orchestration loop (NEW: §3.2) is what gives the cron per-batch isolation. Wrapping the loop itself in `@Transactional` would collapse all N finalizations into one transaction, so a single `ObjectOptimisticLockingFailureException` would roll back every prior correction in the same run. **Do NOT add `@Transactional` to `StaleClubBatchCleanupJobService.cleanupStaleBatches()`.**

**Files changed:** `service/CustomerorderBatchService.java`.

---

### 3.2 `StaleClubBatchCleanupJobService` (new orchestration service)

**Problem:** No service exists to fetch stale batch candidates and finalize them with per-batch exception isolation.

**Solution:**

```java
package net.aim_ai.wms.service.job;

import net.aim_ai.wms.model.CustomerorderBatch;
import net.aim_ai.wms.repo.jpa.CustomerorderBatchRepository;
import net.aim_ai.wms.service.CustomerorderBatchService;
import net.aim_ai.wms.service.WmsConstants;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class StaleClubBatchCleanupJobService {

    private static final Logger LOG = LoggerFactory.getLogger(StaleClubBatchCleanupJobService.class);

    /**
     * Safety cap: process at most this many batches per run to bound blast radius on the first run.
     * Subsequent runs will catch the remainder. Raise via sysprop later if persistently capped.
     */
    static final int MAX_CANDIDATES_PER_RUN = 500;

    private final CustomerorderBatchRepository customerorderBatchRepository;
    private final CustomerorderBatchService customerorderBatchService;

    public StaleClubBatchCleanupJobService(CustomerorderBatchRepository customerorderBatchRepository,
                                           CustomerorderBatchService customerorderBatchService) {
        this.customerorderBatchRepository = customerorderBatchRepository;
        this.customerorderBatchService = customerorderBatchService;
    }

    /**
     * Per-batch isolation is provided by {@code finalizeBatchIfComplete}'s own
     * {@code @Transactional(tenantTransactionManager)} (added in §3.1). Each call from this
     * non-transactional orchestrator opens its own transaction. Adding {@code @Transactional}
     * here would collapse all N finalizations into a single transaction — one optimistic-lock
     * failure would roll back every prior correction. Do NOT annotate this method.
     */
    public void cleanupStaleBatches() {
        LOG.info("start cleanupStaleBatches");

        List<Long> staleBatchIds = customerorderBatchRepository.findStaleClubBatchIds(
            WmsConstants.State.ORDER_BATCH_ACTIVATED,
            WmsConstants.State.FINISHED,
            MAX_CANDIDATES_PER_RUN
        );

        if (staleBatchIds.isEmpty()) {
            LOG.info("end cleanupStaleBatches — no stale club batches found");
            return;
        }

        if (staleBatchIds.size() >= MAX_CANDIDATES_PER_RUN) {
            LOG.warn("stale batch candidate list hit the cap of {} — additional batches will be processed on subsequent runs",
                MAX_CANDIDATES_PER_RUN);
        }

        LOG.info("found {} stale club batch(es) to finalize: {}", staleBatchIds.size(), staleBatchIds);

        int corrected = 0;
        int failed = 0;

        for (Long batchId : staleBatchIds) {
            try {
                CustomerorderBatch before = customerorderBatchRepository.findById(batchId).orElse(null);
                if (before == null) {
                    LOG.warn("batch id={} not found before finalization — already deleted or concurrent remove", batchId);
                    continue;
                }
                LOG.info("correcting batch id={} number={} state={} staginglaneId={}",
                    before.getId(), before.getNumber(), before.getState(), before.getStaginglaneId());

                customerorderBatchService.finalizeBatchIfComplete(batchId);

                CustomerorderBatch after = customerorderBatchRepository.findById(batchId).orElse(null);
                if (after != null) {
                    LOG.info("corrected batch id={} number={} state={} staginglaneId={}",
                        after.getId(), after.getNumber(), after.getState(), after.getStaginglaneId());
                } else {
                    LOG.warn("batch id={} disappeared after finalization — investigate", batchId);
                }
                corrected++;
            } catch (Exception e) {
                // Log and continue — one failed batch must not block the rest of the run.
                // Typical cause: ObjectOptimisticLockingFailureException from concurrent API activity.
                // The batch will be retried on the next scheduled run.
                LOG.warn("failed to finalize batch id={} — skipping, will retry on next run. cause: {}",
                    batchId, e.getMessage());
                failed++;
            }
        }

        LOG.info("end cleanupStaleBatches — corrected={} failed={} of {} candidates",
            corrected, failed, staleBatchIds.size());
    }
}
```

**Key design points (same as v1, v2 idioms):**

- **Per-batch exception isolation** via `try/catch(Exception)` per loop iteration — failure count surfaced in summary.
- **Blast-radius cap** at 500; warning fires when hit.
- **Constructor injection** (v2 style) — no `@Autowired` field injection.
- **No `@Transactional` on the loop method** (per-batch isolation comes from `finalizeBatchIfComplete`'s own annotation — see §3.1).
- **Idempotency:** `finalizeBatchIfComplete` re-reads orders on every call. A batch corrected concurrently between the SELECT and the per-batch call is a no-op.

**Files changed:** new `service/job/StaleClubBatchCleanupJobService.java`.

---

### 3.3 `StaleClubBatchCleanupJob` (new cron shell — NEW-2 + NEW-3 + NEW-4)

**Problem:** No cron-firing entry point exists; v2 requires advisory locking + multi-tenant loop + sysprop gate via `syspropService`.

**Solution (mirrors `CleanUpOldMessagesJob`):**

```java
package net.aim_ai.wms.schedulejob;

import net.aim_ai.wms.context.TenantContext;
import net.aim_ai.wms.context.TenantProfile;
import net.aim_ai.wms.repo.jpa.master.TenantDbConfigurationRepository;
import net.aim_ai.wms.service.AdvisoryLockService;
import net.aim_ai.wms.service.SyspropService;
import net.aim_ai.wms.service.WmsConstants;
import net.aim_ai.wms.service.job.StaleClubBatchCleanupJobService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class StaleClubBatchCleanupJob {

    private static final Logger LOG = LoggerFactory.getLogger(StaleClubBatchCleanupJob.class);

    private final StaleClubBatchCleanupJobService staleClubBatchCleanupJobService;
    private final SyspropService syspropService;
    private final TenantDbConfigurationRepository tenantDbConfigurationRepository;
    private final AdvisoryLockService advisoryLockService;

    public StaleClubBatchCleanupJob(StaleClubBatchCleanupJobService staleClubBatchCleanupJobService,
                                    SyspropService syspropService,
                                    TenantDbConfigurationRepository tenantDbConfigurationRepository,
                                    AdvisoryLockService advisoryLockService) {
        this.staleClubBatchCleanupJobService = staleClubBatchCleanupJobService;
        this.syspropService = syspropService;
        this.tenantDbConfigurationRepository = tenantDbConfigurationRepository;
        this.advisoryLockService = advisoryLockService;
    }

    public void doCalculation(Boolean isCronJob) {
        if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.STALE_CLUB_BATCH_CLEANUP)) {
            LOG.info("staleClubBatchCleanupJob already running on another replica, skipping");
            return;
        }
        try {
            List<TenantProfile> tenantProfiles = tenantDbConfigurationRepository.findAll().stream()
                .map(c -> new TenantProfile(c.getTenant().getName(), c.getWarehouse()))
                .toList();
            if (tenantProfiles.isEmpty()) {
                LOG.warn("No tenants configured. Skipping staleClubBatchCleanupJob.");
                return;
            }
            for (TenantProfile tenantProfile : tenantProfiles) {
                try {
                    long start = System.currentTimeMillis();
                    TenantContext.setCurrentTenant(tenantProfile);

                    if (isCronJob
                        && (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
                         || !Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY)))) {
                        LOG.info("staleClubBatchCleanupJob not activated for {} - {}",
                            tenantProfile.getTenantName(), tenantProfile.getFacilityCode());
                        continue;
                    }

                    staleClubBatchCleanupJobService.cleanupStaleBatches();
                    LOG.info("end. took {}ms for {} - {}",
                        System.currentTimeMillis() - start,
                        tenantProfile.getTenantName(), tenantProfile.getFacilityCode());
                } catch (Exception e) {
                    LOG.error("Error processing tenant {} - {}",
                        tenantProfile.getTenantName(), tenantProfile.getFacilityCode(), e);
                } finally {
                    TenantContext.clear();
                }
            }
        } finally {
            advisoryLockService.unlock(AdvisoryLockService.JobLockId.STALE_CLUB_BATCH_CLEANUP);
        }
    }
}
```

**v2-specific notes:**

- **Advisory lock first, multi-tenant loop second, sysprop gate inside the loop** — matches `CleanUpOldMessagesJob` exactly. Lock is per-job-id, not per-tenant; that prevents two replicas from both walking the tenant list in parallel.
- **`TenantContext.clear()` in `finally`** — guarantees the next iteration (or any subsequent unrelated work on the same thread, however unlikely under Spring's TaskScheduler) sees no stale tenant.
- **Activation flag check is per-tenant** (inside the loop). This matches v2 sysprop semantics — sysprops are tenant-scoped via `syspropService`.
- **`isCronJob` parameter** — kept for parity with v1 / sibling jobs to allow ad-hoc invocation that bypasses the activation flag (e.g., from a test or a manual trigger endpoint added later).
- **`unlock` in outer `finally`** — guaranteed even if the tenant fetch itself throws.

**Files changed:** new `schedulejob/StaleClubBatchCleanupJob.java`.

---

### 3.4 `SchedulingConfiguration.java` (modify — register the cron)

**Problem:** v2 `SchedulingConfiguration` uses **constructor injection** and `TaskScheduler.schedule(runnable, CronTrigger)` — different from v1's `@Autowired` + `ScheduledTaskRegistrar.addCronTask`.

**Solution (mirrors existing v2 constructor-injection pattern at L49):**

1. **Add to constructor params** (alongside other job services in the constructor at L49):
   ```java
   private final StaleClubBatchCleanupJob staleClubBatchCleanupJob;
   ```
   Add to the constructor's parameter list and the constructor body assignment.

2. **Call from `configureAllTasks` at L117**, after `configureReleaseExpiredPickingOrdersFromUser(scheduler);` (line 123):
   ```java
   configureStaleClubBatchCleanup(scheduler);
   ```

3. **Add the new private configuration method** after `configureReleaseExpiredPickingOrdersFromUser` (after L236):
   ```java
   private void configureStaleClubBatchCleanup(TaskScheduler scheduler) {
       try {
           String hours   = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_KEY);
           String minutes = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_KEY);
           boolean showLog = Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG_KEY));
           String cronjob = "0 " + minutes + " " + hours + " * * *";
           scheduler.schedule(() -> {
               if (showLog) LOG.info("Stale Club Batch Cleanup - {}", new Date());
               staleClubBatchCleanupJob.doCalculation(true);
           }, new CronTrigger(cronjob));
           LOG.info("Configured staleClubBatchCleanup with cron: {}", cronjob);
       } catch (Exception e) {
           LOG.error("Failed to configure staleClubBatchCleanup task", e);
       }
   }
   ```

**Why per-method `try/catch`:** v2 sibling configure methods catch sysprop / schedule exceptions so a malformed value in one tenant or one job does not abort the entire schedule wiring at startup.

**Schedule:** Default 03:00 daily (after `CleanUpOldMessagesJob` at 02:00). Configured via DB sysprop, so per-environment override is trivial.

**Files changed:** `schedulejob/SchedulingConfiguration.java`.

---

### 3.5 `WmsConstants.java` (modify — 6 new constants)

**Insert after the existing `CLEAN_UP_OLD_MESSAGES_*` block, around L1011:**

```java
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY            = "STALE_CLUB_BATCH_CLEANUP_ACTIVATED";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_ACTIVATED_DEFAULT_VALUE  = "false";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_KEY           = "STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_DEFAULT_VALUE = "3";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_KEY         = "STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_DEFAULT_VALUE = "0";
```

**Defaults:** disabled (`false`), 03:00 daily.

**Files changed:** `service/WmsConstants.java`.

---

### 3.6 `AdvisoryLockService` — add lock id (NEW-2)

**`JobLockId` is a `public static final class` of `public static final long` constants** (not an enum). Add one constant after `RELEASE_EXPIRED_PICKING`:

```java
// AdvisoryLockService.java — inside the existing `public static final class JobLockId`
public static final long STALE_CLUB_BATCH_CLEANUP = 100006L;    // SBDEV-2164
```

The enclosing class structure and the `tryLock(long lockId)` / `unlock(long lockId)` signatures are **unchanged**. The call sites `advisoryLockService.tryLock(AdvisoryLockService.JobLockId.STALE_CLUB_BATCH_CLEANUP)` resolve the constant to `long 100006L` exactly as sibling jobs do today (e.g. `CLEAN_UP_MESSAGES` = `long 100003L`). Do NOT convert `JobLockId` to an enum — that would change the call-site API and break the five existing sibling jobs.

**Why a unique lock id:** Postgres `pg_try_advisory_lock` is keyed by the bigint id. Reusing an existing job's id would block both jobs from running concurrently across replicas — incorrect and confusing in logs.

**Files changed:** `service/AdvisoryLockService.java`.

---

### 3.7 `CustomerorderBatchRepository.java` — `findStaleClubBatchIds`

**Add method:**

```java
@Query(value =
    "SELECT cb.id FROM customerorder_batch cb " +
    "WHERE cb.type = 'CLUB' " +
    "  AND cb.state >= :minState " +
    "  AND cb.state < :finishedState " +
    "  AND EXISTS     (SELECT 1 FROM customerorder co WHERE co.orderbatch_id = cb.id) " +
    "  AND NOT EXISTS (SELECT 1 FROM customerorder co WHERE co.orderbatch_id = cb.id AND co.state < :finishedState) " +
    "LIMIT :batchSize",
    nativeQuery = true)
List<Long> findStaleClubBatchIds(
    @Param("minState")      int minState,
    @Param("finishedState") int finishedState,
    @Param("batchSize")     int batchSize);
```

**Query semantics (identical to v1):** type=CLUB, state in `[520, 700)`, batch has at least one child order, no child order is open. `LIMIT` bounds first-run blast radius.

**Why not reuse `finalizeBatchesByIds`:** Bulk UPDATE to a fixed target state cannot distinguish FINISHED from CANCELED per-batch. `finalizeBatchIfComplete` already encodes that decision correctly.

**Files changed:** `repo/jpa/CustomerorderBatchRepository.java`.

---

### 3.8 Flyway migration `V2.1.08__stale_club_batch_cleanup_sysprops.sql`

**Latest existing migration:** `V2.1.07` → next sequential version is `V2.1.08`.

```sql
-- V2.1.08__stale_club_batch_cleanup_sysprops.sql
-- SBDEV-2164 — seed sysprops for the stale club batch cleanup cron.
-- IDs 142/143/144 continue the v2 sequence established by V2.1.02 (id=141).
-- ON CONFLICT target matches the actual composite unique constraint on los_sysprop:
--   CONSTRAINT uk8tcoe23qui9q3ancbhx662iqb UNIQUE (client_id, syskey, workstation)
-- client_id=0, workstation='DEFAULT' is the canonical platform-default seed tuple
-- per V1.0.04 and V2.1.02 precedent.

-- Enable / disable toggle (per environment); default OFF.
INSERT INTO los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent, client_id, version, hidden, workstation, entity_lock, created, modified)
VALUES (142, 'Backend',
        'STALE_CLUB_BATCH_CLEANUP_ACTIVATED', 'false',
        'Enable stale club batch cleanup cron job', 'true / false',
        0, 0, FALSE, 'DEFAULT', 0, NOW(), NOW())
ON CONFLICT (client_id, syskey, workstation) DO NOTHING;

-- Hour of day (0-23).
INSERT INTO los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent, client_id, version, hidden, workstation, entity_lock, created, modified)
VALUES (143, 'Backend',
        'STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR', '3',
        'Hour to run the stale club batch cleanup job', '0-23',
        0, 0, FALSE, 'DEFAULT', 0, NOW(), NOW())
ON CONFLICT (client_id, syskey, workstation) DO NOTHING;

-- Minute (0-59).
INSERT INTO los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent, client_id, version, hidden, workstation, entity_lock, created, modified)
VALUES (144, 'Backend',
        'STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE', '0',
        'Minute to run the stale club batch cleanup job', '0-59',
        0, 0, FALSE, 'DEFAULT', 0, NOW(), NOW())
ON CONFLICT (client_id, syskey, workstation) DO NOTHING;
```

**Differences from v1:**

- Uses **hardcoded IDs 142/143/144** — continues the v2 pattern established by `V2.1.02__add_palletized_loaded_to_truck_sysprops.sql` (last id=141). v2 does not have a `los_sysprop_seq` sequence; v1's `MAX(id)` ceremony is not needed.
- `ON CONFLICT (client_id, syskey, workstation) DO NOTHING` — matches the actual composite unique constraint `uk8tcoe23qui9q3ancbhx662iqb UNIQUE (client_id, syskey, workstation)` from `V1.0.01__wms_tables.sql:565`. Using `ON CONFLICT (syskey)` alone would fail with "no unique constraint matching the ON CONFLICT specification".
- Flyway version bumped to `V2.1.08` (next after v2's `V2.1.07`).

**Files changed:** new `db/migration/V2.1.08__stale_club_batch_cleanup_sysprops.sql`.

---

## 4. V1 → V2 Applicability Analysis

| V1 Fix | Description | V2 Verdict | Rationale |
|---|---|---|---|
| **Fix 1** — `StaleClubBatchCleanupJob.java` (new) | Cron shell, sysprop gate | **Needed (architectural translation)** | v2 requires advisory lock + multi-tenant loop + `syspropService` (NEW-2/3/4) — direct copy of v1 shell would not run safely across replicas |
| **Fix 2** — `StaleClubBatchCleanupJobService.java` (new) | Orchestration loop with per-batch isolation | **Needed (constructor injection)** | Logic identical; v2 idiom is constructor injection, no `@Autowired` fields |
| **Fix 3** — `SchedulingConfiguration.java` (modify) | Register cron | **Needed (architectural translation)** | v2 uses `TaskScheduler.schedule(runnable, CronTrigger)` not `ScheduledTaskRegistrar.addCronTask`; `syspropService` not `losSyspropRepository` |
| **Fix 4** — `WmsConstants.java` (modify) | 6 new constants | **Needed** | Same constants required; insertion point at v2 L1011 (after existing `CLEAN_UP_OLD_MESSAGES_*`) |
| **Fix 5** — `CustomerorderBatchRepository.findStaleClubBatchIds` | Native SELECT | **Needed** | Method absent in v2; SQL identical; v2 native-query support unchanged |
| **Fix 6** — Flyway migration | Seed 3 sysprop rows | **Needed (v2 idioms)** | Use `V2.1.08`, hardcoded IDs 142/143/144 (per V2.1.02 pattern), `ON CONFLICT (client_id, syskey, workstation) DO NOTHING` |

### NEW v2-only issues (not in v1)

| ID | Issue | File:Line | Severity | Description |
|---|---|---|---|---|
| **NEW-1** | `finalizeBatchIfComplete` lacks `@Transactional` | `service/CustomerorderBatchService.java:346` | **CRITICAL** | v2 has no class-level `@Transactional`; method writes 3 entities in separate auto-commits — partial failure leaves inconsistent state |
| **NEW-2** | Advisory lock id missing | `service/AdvisoryLockService.java` `JobLockId` static class | **HIGH** | Multi-replica deployment requires Postgres advisory lock; add `STALE_CLUB_BATCH_CLEANUP = 100006L` |
| **NEW-3** | Multi-tenant loop required | `schedulejob/StaleClubBatchCleanupJob.java` | **HIGH** | Scheduled jobs have no inbound HTTP request; tenant context must be set per iteration via `tenantDbConfigurationRepository.findAll()` |
| **NEW-4** | Use `syspropService` not `losSyspropRepository` | both new files | **MEDIUM** | v2 idiom; Redis-cached lookups; consistent with sibling jobs |

---

## 5. V2-Specific Adaptation Notes

1. **Transaction manager:** `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` on `finalizeBatchIfComplete` (NEW-1). Bare `@Transactional` is wrong in v2.
2. **Constructor injection:** Both new classes use constructor injection — no `@Autowired` fields. Update existing constructors when adding the dep to `SchedulingConfiguration`.
3. **`syspropService.getSysvalue(key)` vs repository:** v2 uses the Redis-cached `syspropService` for sysprop reads (NEW-4). Direct repository access bypasses the cache and is inconsistent with sibling jobs.
4. **Jakarta namespace:** All imports `jakarta.*` (none introduced here, but verify).
5. **Multi-tenant scheduling:** Mandatory tenant loop with `TenantContext.setCurrentTenant(profile)` + `TenantContext.clear()` in `finally`. Pattern from `CleanUpOldMessagesJob`.
6. **Distributed advisory lock:** Mandatory `AdvisoryLockService.tryLock(JobLockId.STALE_CLUB_BATCH_CLEANUP)` wrapping the multi-tenant loop. `unlock` in outer `finally`.
7. **SLF4J parameterized logging:** `LOG.info("end. took {}ms for {} - {}", ms, tenant, facility)` — no string concatenation.
8. **Mockito 5.x:** v2 supports `mockStatic` and constructor-injected mocks. Tests can use `@ExtendWith(MockitoExtension.class)` + `@Mock` parameters in `@BeforeEach` constructor-style setup.
9. **Flyway sequence:** `V2.1.07` is current latest → use `V2.1.08`.
10. **Sysprop seed pattern:** hardcoded IDs 142/143/144 (continues V2.1.02's last id=141); `ON CONFLICT (client_id, syskey, workstation) DO NOTHING` matching the composite unique constraint `uk8tcoe23qui9q3ancbhx662iqb` from `V1.0.01__wms_tables.sql:565`. `los_sysprop_seq` does NOT exist in v2.

---

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state — Flyway baseline | `V2.1.07` applied. **No `los_sysprop_seq` exists in v2** (IDs hardcoded). Unique constraint is composite `(client_id, syskey, workstation)` — confirmed `V1.0.01__wms_tables.sql:565`. | DBA | Confirm V2.1.07 is baseline; V2.1.08 uses hardcoded IDs 142/143/144 and `ON CONFLICT (client_id, syskey, workstation)` |
| 2 | Feature flag default | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED = 'false'` per tenant | platform | Inserted by V2.1.08; verify per tenant after migration |
| 3 | New cron job activation flag | `NEW_CRON_JOB_ACTIVATED = 'true'` per tenant where the job should ever run | platform | This is the global gate sibling jobs already check — required for the inner sysprop check to enable the run |
| 4 | Config / env changes | None | — | Cron times stored in `los_sysprop`, not application properties |
| 5 | Deploy-order dependency | None — single service change | — | OMS / UI not affected; `finalizeBatchIfComplete` does NOT call OMS webhooks |
| 6 | Data migration / backfill | Run candidate-count SQL (§6 SQL helper) per env BEFORE flipping `_ACTIVATED='true'` to estimate first-run blast radius | platform | First-run cap is 500 batches; gauge backlog beforehand |
| 7 | External systems | None | — | No external HTTP / message in cleanup path |
| 8 | Access / permissions | None | — | No new endpoint authority; no Keycloak realm change |
| 9 | Monitoring | Add Grafana log panel for `staleClubBatchCleanupJob` showing `corrected=` and `failed=` counts (LokI / log-based metric) | ops | Track first-week metrics in prod |

---

### 5.2 Implementation Checklist

- [ ] Apply NEW-1 — add method-level `@Transactional` on `CustomerorderBatchService.finalizeBatchIfComplete` (§3.1)
- [ ] Add constants to `WmsConstants.java` (§3.5)
- [ ] Add `STALE_CLUB_BATCH_CLEANUP = 100006L` to `AdvisoryLockService.JobLockId` (§3.6)
- [ ] Add `findStaleClubBatchIds` to `CustomerorderBatchRepository` (§3.7)
- [ ] Create `service/job/StaleClubBatchCleanupJobService.java` (§3.2)
- [ ] Create `schedulejob/StaleClubBatchCleanupJob.java` (§3.3)
- [ ] Modify `SchedulingConfiguration` constructor + `configureStaleClubBatchCleanup` (§3.4)
- [ ] Create `db/migration/V2.1.08__stale_club_batch_cleanup_sysprops.sql` (§3.8)
- [ ] Add unit tests A1–A6 (`StaleClubBatchCleanupJobServiceUnitTest`)
- [ ] Add unit tests A7–A8 (`StaleClubBatchCleanupJobUnitTest`)
- [ ] Extend repository test A9–A10 (`CustomerorderBatchRepositoryTest`)
- [ ] Add reflection test A11 (`CustomerorderBatchServiceUnitTest` — verify `@Transactional` annotation on `finalizeBatchIfComplete`)
- [ ] `mvn test -Dtest=StaleClubBatchCleanupJobServiceUnitTest` — all pass
- [ ] `mvn test -Dtest=StaleClubBatchCleanupJobUnitTest` — all pass
- [ ] `mvn verify` — Testcontainers integration tests including A9/A10 pass
- [ ] Code review completed
- [ ] Deploy to dev; flip `STALE_CLUB_BATCH_CLEANUP_ACTIVATED=true` per tenant; observe first-run logs
- [ ] Promote to qa, then prod (sysprop default `false` per tenant; explicit enable per env)

### 5.3 Rollback Procedure

| Component | Rollback action | Notes |
|---|---|---|
| **Cron job (job + service + scheduler)** | Revert code commit; redeploy | Job is off-by-default (`_ACTIVATED=false`); can also just leave disabled if revert is too risky |
| **`finalizeBatchIfComplete` `@Transactional` (NEW-1)** | Code rollback required — this is a code change, not a sysprop | Removing the annotation reverts failure-path semantics for existing callers to pre-fix auto-commit behaviour |
| **`WmsConstants` constants** | Revert code commit | Unused constants cause no runtime harm |
| **`AdvisoryLockService.JobLockId`** | Revert code commit | Unused constant in the static class causes no runtime harm |
| **`CustomerorderBatchRepository.findStaleClubBatchIds`** | Revert code commit | Unused query causes no runtime harm |
| **V2.1.08 Flyway migration** | **Cannot be rolled back automatically.** Flyway marks it as applied. Manual rollback: `DELETE FROM los_sysprop WHERE id IN (142, 143, 144)` per tenant DB, then remove the migration file and reset Flyway checksum. | Only needed if migration produced incorrect rows. Prefer leaving rows (job stays disabled via `_ACTIVATED=false`). |


---

## 6. Test Plan

### 6.1 Unit — `StaleClubBatchCleanupJobServiceUnitTest` (new)

`@ExtendWith(MockitoExtension.class)`, constructor-injected mocks. v2 supports modern Mockito.

| ID | Test | Setup | Asserts |
|---|---|---|---|
| **A1** | `cleanupStaleBatches_shouldSkip_whenNoBatchesFound` | `findStaleClubBatchIds(...)` returns empty list | `finalizeBatchIfComplete` never called; logs "no stale club batches found" |
| **A2** | `cleanupStaleBatches_shouldFinalizeSingleBatch_whenOneStaleBatchFound` | Returns `[42L]`; `findById(42L)` → present batch | `finalizeBatchIfComplete(42L)` called once |
| **A3** | `cleanupStaleBatches_shouldFinalizeAllBatches_whenMultipleStaleBatchesFound` | Returns `[1L, 2L, 3L]` | `finalizeBatchIfComplete` called for each id in order |
| **A4** | `cleanupStaleBatches_shouldSkipBatch_whenBatchDisappearsBeforeFinalization` | Returns `[10L, 11L]`; `findById(10L)` → empty, `findById(11L)` → present | `finalizeBatchIfComplete` called only for `11L`; warn logged for `10L` |
| **A5** | `cleanupStaleBatches_shouldContinueProcessing_whenOneBatchThrowsException` | Returns `[20L, 21L]`; `finalizeBatchIfComplete(20L)` throws `ObjectOptimisticLockingFailureException`; `finalizeBatchIfComplete(21L)` succeeds | Both calls executed; no exception propagates; `failed=1`, `corrected=1` in summary |
| **A6** | `cleanupStaleBatches_shouldLogWarning_whenCandidateCountHitsCap` | Returns exactly `MAX_CANDIDATES_PER_RUN` ids | WARN log line containing `"cap"` is emitted; processing proceeds |

### 6.2 Unit — `StaleClubBatchCleanupJobUnitTest` (new)

| ID | Test | Setup | Asserts |
|---|---|---|---|
| **A7** | `doCalculation_shouldSkip_whenAdvisoryLockNotAcquired` | `advisoryLockService.tryLock(STALE_CLUB_BATCH_CLEANUP)` → `false` | `staleClubBatchCleanupJobService.cleanupStaleBatches()` never called; `unlock` not called (since lock not held); no tenant iteration |
| **A8** | `doCalculation_shouldSkip_whenActivationFlagDisabled` | `tryLock` → true; one tenant; `syspropService.getSysvalue(STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY)` → `"false"` | `cleanupStaleBatches()` never called for that tenant; `unlock` IS called |

### 6.3 Integration — `CustomerorderBatchRepositoryTest` (extend)

Testcontainers Postgres via `BaseRepositoryTest` + `AppPostgresDBSetupExtension`.

| ID | Test | Seeded data | Expected |
|---|---|---|---|
| **A9** | `findStaleClubBatchIds_shouldReturnBatch_whenAllOrdersTerminal` | Batch type=CLUB, state=530; two child orders both at state=700 | Result list contains the batch id |
| **A10** | `findStaleClubBatchIds_shouldExcludeActiveBatch_whenOneOrderStillOpen` | Batch type=CLUB, state=530; orders one=700 + one=650 (PACKED) | Result list does NOT contain the batch id |

> Critical because `nativeQuery=true` bypasses JPQL validation. Without these tests, a typo in the SQL ships silently.

#### A11 — annotation reflection test (unit, NOT Testcontainers)

**File:** `unit/service/CustomerorderBatchServiceUnitTest` (extend existing class)

| ID | Test method | Asserts |
|---|---|---|
| **A11** | `finalizeBatchIfComplete_annotatedWithTenantTransactionManager` | Reflection on `CustomerorderBatchService.finalizeBatchIfComplete` — method has `@Transactional` with `value="tenantTransactionManager"` and `rollbackFor` including `BusinessException.class`. Guards against accidental annotation removal. |

> A11 is a Mockito unit test, NOT a Testcontainers test — it has no DB dependency. Runs with `mvn test -Dtest=CustomerorderBatchServiceUnitTest`.

**Optional follow-on integration tests (not required for sign-off but improve coverage):**

- Already-finished batch (state 700) → excluded.
- Orphan batch (no child orders) → excluded.
- Non-CLUB type → excluded.
- LIMIT respected (seed 600, expect 500).

### 6.4 Manual test plan

| # | Scenario | Environment | Steps | Expected |
|---|----------|-------------|-------|----------|
| M1 | Dry run — no stale batches | dev | Enable sysprop on a tenant with no candidates | Log line: `no stale club batches found` |
| M2 | Correct one stale batch | dev | Manually set a club batch to state=530, all orders state=700; call `staleClubBatchCleanupJob.doCalculation(false)` via test endpoint | Batch state → 700, `staginglane_id` → null, transferlaneId cleared on orders |
| M3 | Active batch not touched | dev | Club batch with one order at 650; run job | Batch unchanged |
| M4 | Exception isolation | dev | Force `ObjectOptimisticLockingFailureException` on first batch (e.g., concurrent edit) with two candidates | Second batch still processed; summary `failed=1, corrected=1` |
| M5 | Blast-radius cap | dev | Seed 600 stale batches | First run processes 500; WARN log about cap; next run picks up the rest |
| M6 | Activation flag off | dev | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED='false'` on a tenant | Job skips that tenant; logs "not activated for {tenant}" |
| M7 | Multi-replica safety | staging | Two replicas running concurrently; trigger cron on both | Only one replica acquires the advisory lock and runs; the other logs "already running on another replica" |
| M8 | Tenant isolation | dev | Run with two configured tenants; one with a candidate, one without | Per-tenant log lines distinct; only the candidate tenant emits "correcting batch ..." |
| M9 | Cross-system: OMS notification | dev | Watch OMS webhook receiver during M2 | No new OMS webhook emitted (`finalizeBatchIfComplete` only mutates local DB) |
| M10 | SQL-level sanity | dev | After deploy: `psql ...` against tenant DB executing the candidate-count SQL helper | Returns rows shaped `id, number, state, total_orders, terminal_orders` without grammar error |

**Candidate-count SQL helper (run against each v2 tenant DB before enabling):**
```sql
SELECT cb.id, cb.number, cb.state,
       COUNT(co.id)                                 AS total_orders,
       COUNT(CASE WHEN co.state >= 700 THEN 1 END)  AS terminal_orders
FROM   customerorder_batch cb
JOIN   customerorder co ON co.orderbatch_id = cb.id
WHERE  cb.type = 'CLUB'
  AND  cb.state >= 520
  AND  cb.state < 700
GROUP  BY cb.id, cb.number, cb.state
HAVING COUNT(co.id) = COUNT(CASE WHEN co.state >= 700 THEN 1 END)
ORDER  BY cb.id
LIMIT  20;
```

### 6.5 Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=StaleClubBatchCleanupJobServiceUnitTest` | — | — |
| `mvn test -Dtest=StaleClubBatchCleanupJobUnitTest` | — | — |
| `mvn test -Dtest=CustomerorderBatchRepositoryTest` | — | — |
| `mvn verify` | — | — |

### 6.6 Deliberately-skipped coverage

| What | Why |
|---|---|
| Controller test | No new endpoint introduced; cron is invoked via Spring's `TaskScheduler`, not HTTP |
| Performance test for `findStaleClubBatchIds` | Bounded by `LIMIT 500`; the existing index on `customerorder_batch(type, state)` and `customerorder(orderbatch_id, state)` is adequate; load test deferred unless first-run latency exceeds 30 seconds |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | **In-JVM state** | No | No local cache or static field. `staleBatchIds` list is local to the method invocation. |
| 2 | **Connection pool math** | No | Per-tenant per-run: ~1 SELECT + N×(`findById`+`finalizeBatchIfComplete`+`findById`) connections. Each is short-lived auto-commit (or per-batch transaction in §3.1). At 500 batches × 4 short connections = bounded. Job runs once per day per tenant; net pool impact negligible vs sibling jobs. |
| 3 | **Scheduled jobs** | **Yes** | New `@Scheduled` cron via `SchedulingConfiguration`. Mitigated by `AdvisoryLockService` Postgres advisory lock (NEW-2) — only one replica runs at a time. Pattern matches `CleanUpOldMessagesJob`. |
| 4 | **Long transactions** | No | The orchestrator method is intentionally non-transactional. Each `finalizeBatchIfComplete` opens its own short transaction (NEW-1, §3.1). Bounded by the 3 writes inside the method — no external I/O. |
| 5 | **Request affinity** | No | Cron has no request lifecycle; advisory lock provides single-replica execution semantic. |
| 6 | **Retry / idempotency** | **Yes (idempotent)** | Cron re-runs daily. `finalizeBatchIfComplete` re-checks order state on every call — already-finalized batches are no-ops. A replica dying mid-run leaves remaining batches for the next scheduled run. |
| 7 | **Tenant context** | **Yes** | Set per-iteration via `TenantContext.setCurrentTenant(profile)` + `TenantContext.clear()` in `finally`. NEW-3 explicitly captures this. |
| 8 | **Distributed lock correctness** | **Yes** | `pg_try_advisory_lock(100006)` via `AdvisoryLockService`. Lock id unique to this job (NEW-2). `unlock` in outer `finally`. |
| 9 | **Cache invalidation** | No | `customerorder_batch` is not Caffeine-cached. `syspropService` cache is read-only here (no sysprop writes). |
| 10 | **External notifications** | No | `finalizeBatchIfComplete` does NOT trigger OMS webhooks. OMS was already notified at ship time by `closeBOL`. No double-notification risk. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 3 | Cron registered via `TaskScheduler.schedule(runnable, CronTrigger)` mirroring sibling jobs | `schedulejob/SchedulingConfiguration.java` (planned) §3.4 |
| 6 | Idempotency proven by A4 (skips disappeared batch) + A5 (continues on exception) | tests planned §6.1 |
| 7 | Tenant set/clear pattern mirrors `CleanUpOldMessagesJob` | `schedulejob/StaleClubBatchCleanupJob.java` (planned) §3.3 |
| 8 | `AdvisoryLockService.JobLockId.STALE_CLUB_BATCH_CLEANUP = 100006L` unique | `service/AdvisoryLockService.java` (planned) §3.6; tested via A7 |

---

## 8. Notes

- **Companion plan:** SBDEV-2163 v2 (`SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md`) — runtime guard preventing future stale batches. Both plans coexist: the guard prevents new accumulation, the cron corrects existing.
- **Future hardening:** the long-term root-cause fix is to make `closeBOL`'s last-BOL path always invoke `finalizeBatchIfComplete`. Tracked separately as a follow-on. The cron is the safety net.
- **Verify script:** A `sbdocs/9-System/scripts/verify-SBDEV-2164.sh` script should be authored before implementation that checks (a) the new files exist, (b) `@Transactional` is present at `CustomerorderBatchService.java:346`, (c) `JobLockId.STALE_CLUB_BATCH_CLEANUP` exists, (d) `V2.1.08` migration file exists, (e) targeted `mvn test` for the new unit tests passes.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance criteria (wms-tdd-gate consumable)

| ID | Test method | File | Asserts |
|---|---|---|---|
| **A1** | `cleanupStaleBatches_shouldSkip_whenNoBatchesFound` | `service/job/StaleClubBatchCleanupJobServiceUnitTest` | Empty candidate list → no `finalizeBatchIfComplete` calls |
| **A2** | `cleanupStaleBatches_shouldFinalizeSingleBatch_whenOneStaleBatchFound` | same | One id → exactly one `finalizeBatchIfComplete(id)` call |
| **A3** | `cleanupStaleBatches_shouldFinalizeAllBatches_whenMultipleStaleBatchesFound` | same | Three ids → three calls in order |
| **A4** | `cleanupStaleBatches_shouldSkipBatch_whenBatchDisappearsBeforeFinalization` | same | Missing `findById` → no finalize for that id; warn log; siblings still processed |
| **A5** | `cleanupStaleBatches_shouldContinueProcessing_whenOneBatchThrowsException` | same | OptimisticLock on first → second still processed; `failed=1, corrected=1` |
| **A6** | `cleanupStaleBatches_shouldLogWarning_whenCandidateCountHitsCap` | same | Exactly `MAX_CANDIDATES_PER_RUN` returned → WARN log emitted |
| **A7** | `doCalculation_shouldSkip_whenAdvisoryLockNotAcquired` | `schedulejob/StaleClubBatchCleanupJobUnitTest` | `tryLock=false` → no orchestration; no `unlock` (lock not held) |
| **A8** | `doCalculation_shouldSkip_whenActivationFlagDisabled` | same | Sysprop `_ACTIVATED='false'` → `cleanupStaleBatches` never called for that tenant; `unlock` IS called |
| **A9** | `findStaleClubBatchIds_shouldReturnBatch_whenAllOrdersTerminal` | `repo/jpa/CustomerorderBatchRepositoryTest` | Seeded all-700 club batch returned by native query |
| **A10** | `findStaleClubBatchIds_shouldExcludeActiveBatch_whenOneOrderStillOpen` | same | Seeded mixed-state batch NOT returned |
| **A11** | `finalizeBatchIfComplete_annotatedWithTenantTransactionManager` | `unit/service/CustomerorderBatchServiceUnitTest` | Reflection check: method has `@Transactional(value="tenantTransactionManager")` with `rollbackFor` including `BusinessException.class` — ensures NEW-1 annotation is not accidentally removed |

### 9.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 6 fixes + 4 NEW issues across one subsystem (scheduled jobs); no cross-subsystem blast |
| **Pre-draft step** | analyst+planner (already done) → ralplan | Architect/Critic review the ported plan via `/oh-my-claudecode:ralplan --interactive` |
| **Plan-review step** | critic | NEW-1 (CRITICAL) and NEW-2 (HIGH) MUST be vetted before code begins |
| **Implementation shape** | executor | Mechanical, scope-bounded once plan is approved; verify-script-as-exit gate |
| **Verification step** | verify-script + verifier (mandatory) | `bash sbdocs/9-System/scripts/verify-SBDEV-2164.sh` after each pass |
| **Code-review step** | code-reviewer | Standard pre-commit pass |
| **Commit step** | git-master | Multiple logical commits: NEW-1 fix, sysprop seeds, cron shell, tests |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|----------|------------|
| 1 | Should RAW (0) or ASSIGNED (200) batches be included? | **Resolved — No.** `minState = ORDER_BATCH_ACTIVATED (520)`. A batch never activated has not had stock moved to staging and is not the target. (Inherited from v1.) |
| 2 | Sysprop id allocation in v2? | **Resolved — hardcoded IDs 142/143/144**, continuing V2.1.02's last id (141). v2 does NOT have a `los_sysprop_seq` sequence. `ON CONFLICT (client_id, syskey, workstation) DO NOTHING` matches the actual composite unique constraint `uk8tcoe23qui9q3ancbhx662iqb` in `V1.0.01__wms_tables.sql:565`. |
| 3 | Per-batch exception handling | **Resolved — log WARN + continue.** `try/catch(Exception)` per iteration; summary line includes `failed=N`. (Inherited from v1.) |
| 4 | First-run blast radius | **Resolved — `MAX_CANDIDATES_PER_RUN = 500` + candidate-count SQL run before enabling.** (Inherited from v1.) |
| 5 | Does `finalizeBatchIfComplete` trigger OMS webhooks? | **Resolved — No.** Only mutates local DB. (Inherited from v1.) |
| 6 | Does the v2 advisory-lock id conflict with anything? | **Resolved — `100006L` is the next free id.** Full constants in `JobLockId` static class (verified `AdvisoryLockService.java:64–68`): `ORDER_RELEASE=100001`, `REPLENISH_ORDER=100002`, `CLEAN_UP_MESSAGES=100003`, `STOCK_SUMMARY_EXPORT=100004`, `RELEASE_EXPIRED_PICKING=100005`. `100006L` is the first unused value. |
| 7 | Is `los_sysprop.syskey` truly unique in v2? | **Resolved — constraint is COMPOSITE `(client_id, syskey, workstation)`, not syskey-alone.** Confirmed `uk8tcoe23qui9q3ancbhx662iqb` at `V1.0.01__wms_tables.sql:565`. Migration uses `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. |
| 8 | Should the cron tenant loop short-circuit on `tryLock=false` per tenant, or hold one global lock? | **Resolved — one global lock per job-id, then iterate tenants inside.** Matches `CleanUpOldMessagesJob`. Per-tenant locking is unnecessary because the per-batch optimistic lock on `CustomerorderBatch` provides sub-tenant safety. |
| 9 | Does `SchedulingConfiguration` need any restart concern? | **Resolved — sysprop changes apply on next restart.** v2 reads cron times once at startup (same as sibling jobs). Documented in operator runbook (out of plan scope). |

---

## 11. Alternatives Considered

| Option | Description | Why Rejected |
|---|---|---|
| **One-shot SQL UPDATE** | Single manual UPDATE clears the backlog | Doesn't prevent future accumulation. Cron provides ongoing safety net. (Same rationale as v1.) |
| **Fix root cause in `closeBOL`** | Always invoke `finalizeBatchIfComplete` after the last BOL closes | Valid long-term fix. Does not correct stranded batches. Track as follow-on. |
| **`@TransactionEventListener` on order shipment** | React to order state changes in real time | Higher complexity, more surface area, higher regression risk. Cron is bounded. |
| **`finalizeBatchesByIds` bulk UPDATE** | Use existing bulk method | Cannot distinguish FINISHED vs CANCELED per-batch. (Same rationale as v1.) |
| **Skip advisory lock** | Single-replica deployment assumption | Rejected — v2 explicitly runs ≥2 replicas in prod; non-locked cron would race and produce duplicate `finalizeBatchIfComplete` invocations + optimistic-lock failures. |
| **Skip multi-tenant loop, run one tenant per process** | Each replica pinned to a tenant | Rejected — v2 deployment model puts all tenants behind one wms2-api set; replicas are not tenant-pinned. |
| **Bare `@Transactional` on `finalizeBatchIfComplete`** | Use default propagation/manager | Rejected — must specify `value="tenantTransactionManager"` or the wrong (master) datasource is used. |
| **Wrap orchestrator in `@Transactional`** | Make `cleanupStaleBatches` transactional | Rejected — collapses N finalizations into one transaction; one optimistic-lock failure rolls back every prior correction. Must remain non-transactional with per-batch isolation. |

---

## RALPLAN-DR Summary (consensus alignment)

### Mode

**SHORT** — port of an already-vetted v1 plan with verified v2 analysis. Risk is contained to one subsystem (scheduled jobs).

### Principles (3–5)

1. **Per-batch isolation must survive optimistic-lock failures** — orchestrator is intentionally non-transactional; finalizer is transactional; no single failure rolls back prior corrections.
2. **Multi-replica safety is non-negotiable** — every scheduled job uses `AdvisoryLockService` and a unique `JobLockId`. No exceptions.
3. **Tenant context is explicit at the job boundary** — scheduled jobs always set/clear `TenantContext` per iteration; never assume a request scope.
4. **Reuse v2 idioms over copying v1** — `syspropService` not `losSyspropRepository`; constructor injection not `@Autowired`; `TaskScheduler.schedule` not `ScheduledTaskRegistrar`.
5. **Default-off in production** — sysprop activation flag (`_ACTIVATED=false`) gates rollout per environment + per tenant; verifiable via sysprop SELECT before flipping.

### Decision Drivers (top 3)

1. **Correctness under concurrency** — NEW-1 (`@Transactional`) + NEW-2 (advisory lock) jointly prevent inconsistent batch state under multi-replica + concurrent API activity. Skipping either makes the cron actively unsafe.
2. **Operational safety / blast radius** — `MAX_CANDIDATES_PER_RUN=500` + per-batch exception isolation + per-tenant activation flag give ops the smallest reasonable footprint to enable, observe, and disable.
3. **Architectural fit with v2 sibling jobs** — every existing v2 cron (`CleanUpOldMessagesJob`, `OrderReleaseJob`, `ReplenishOrderJob`) follows the same advisory-lock + tenant-loop + `syspropService` pattern. New job inherits the pattern without invention.

### Viable Options (≥2)

| Option | Description | Pros | Cons |
|---|---|---|---|
| **A. New cron + transactional finalizer (chosen)** | Port the v1 design, add NEW-1/2/3/4 v2-only safeguards | Single safety net; idempotent; bounded; per-batch isolated; multi-replica safe; matches every sibling job | New file count (4 new + 4 modified); 10 tests required; needs DB migration |
| **B. Inline cron in `SchedulingConfiguration` (no service)** | Fold service logic into a runnable inside the configure method | Fewer files; smaller diff | Untestable in isolation (no service to mock); per-batch isolation harder to express; breaks v2 sibling-job convention; rejected |
| **C. One-shot SQL backfill, no cron** | Manual UPDATE per environment, no scheduled job | No new code; trivial deploy | Doesn't prevent future accumulation; recurring incidents stay manual; rejected |
| **D. Fix root cause in `closeBOL` only** | Make `closeBOL` always invoke `finalizeBatchIfComplete` on last BOL | Removes the source of stranded batches | Doesn't correct existing strays; needs deep audit of multi-BOL paths; tracked as follow-on; insufficient on its own |

**Result:** Option A is the only choice that simultaneously corrects the existing backlog, prevents future accumulation, and respects v2's deployment model. Options B/C/D are documented invalidations.

### ADR (Architecture Decision Record)

| Field | Value |
|---|---|
| **Decision** | Port SBDEV-2164 to v2 as a new advisory-locked, multi-tenant cron + a method-level `@Transactional` on `finalizeBatchIfComplete` (NEW-1) + a unique `JobLockId` (NEW-2) + tenant context loop (NEW-3) + `syspropService` reads (NEW-4). |
| **Drivers** | Correctness under multi-replica concurrency; operational safety / bounded blast radius; architectural consistency with v2 sibling jobs. |
| **Alternatives considered** | (A) chosen; (B) inline cron — rejected for untestability; (C) one-shot SQL — rejected for recurrence; (D) fix `closeBOL` only — rejected as insufficient on its own. |
| **Why chosen** | Only Option A satisfies all three drivers simultaneously. NEW-1 prevents partial-write corruption (CRITICAL). NEW-2 prevents replica races (HIGH). The ported v1 logic remains valid because the underlying state machine and finalization semantics are unchanged. |
| **Consequences** | Adds one daily cron per tenant (default OFF). Adds one Postgres advisory lock id. Adds one method-level `@Transactional` that joins existing transactions on three caller paths (verified safe). Requires 11 tests (A1–A11) + 1 Flyway migration. Does NOT change OMS notification, BOL flow, order state, or any controller. |
| **Follow-ups** | (i) Long-term root-cause fix in `closeBOL` last-BOL path (separate ticket). (ii) Authoring `verify-SBDEV-2164.sh` before implementation. (iii) Grafana panel for `corrected=` / `failed=` counts. (iv) Reconcile `LocationRepository.getAvailableStagingLanes` with child-order aggregate state (cross-cuts SBDEV-2163 follow-up Q7). |

---

## Implementation Status

**v2 commit:** `57ec70e` (2026-05-03) — `port v1 b746c39+38474e8 — SBDEV-2164 stale club batch cleanup cron job`

- [x] NEW-1 applied — `@Transactional(tenantTransactionManager)` on `CustomerorderBatchService.finalizeBatchIfComplete`
- [x] NEW-2 applied — `JobLockId.STALE_CLUB_BATCH_CLEANUP = 100006L` added to `AdvisoryLockService`
- [x] NEW-3 applied — multi-tenant loop in `StaleClubBatchCleanupJob` (TenantContext.set/clear)
- [x] NEW-4 applied — `syspropService.getSysvalue` used throughout
- [x] Code changes applied (§3) — all 6 fixes + 4 NEW issues
- [x] Unit tests A1–A8 passing (`StaleClubBatchCleanupJobServiceUnitTest`, `StaleClubBatchCleanupJobUnitTest`)
- [ ] Repository integration tests A9–A10 — written, `@Disabled` (class-level, SBDEV-2099 env); compile correctly
- [x] Reflection test A11 (`finalizeBatchIfComplete_annotatedWithTenantTransactionManager`) passing
- [x] `mvn test` passing — 3826 run, 0 failures, 0 errors, 67 skipped (BUILD SUCCESS 2026-05-03)
- [ ] Verify script result: pending
- [ ] Candidate-count SQL run against dev / qa / prod-replica; counts documented
- [ ] V2.1.08 migration applied per env
- [ ] Sysprop enabled per tenant in dev; first run observed
- [ ] PR merged
- [ ] Branch: develop
- [x] Commit SHA: `57ec70e`

**Test classes added/updated:**

| Class | Methods | Result |
|---|---|---|
| `StaleClubBatchCleanupJobServiceUnitTest` (new) | A1–A6 | 6 pass |
| `StaleClubBatchCleanupJobUnitTest` (new) | A7–A8 | 2 pass |
| `CustomerorderBatchServiceUnitTest` (extended) | A11 `finalizeBatchIfComplete_annotatedWithTenantTransactionManager` | 1 pass |
| `CustomerorderBatchRepositoryTest` (extended) | A9–A10 | 2 skipped (@Disabled) |

---

### Changelog

| Date | Change |
|---|---|
| 2026-05-03 | Initial v2 plan — ported from v1 `SBDEV-2164-stale-club-batch-cleanup-cron.md` with verified v2 analysis. Key v2 adaptations: NEW-1 method-level `@Transactional` on `finalizeBatchIfComplete` (CRITICAL, v2-only, failure-path semantics change for existing callers documented in §3.1); NEW-2 advisory-lock id `100006L` (first free after RELEASE_EXPIRED_PICKING=100005); NEW-3 multi-tenant loop with `TenantContext`; NEW-4 `syspropService` reads. Sysprop seed via hardcoded IDs 142/143/144 with `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. Flyway version `V2.1.08`. |
