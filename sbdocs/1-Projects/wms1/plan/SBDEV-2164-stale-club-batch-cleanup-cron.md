---
ticket: SBDEV-2164
title: "WMS: Add a Cron Cleanup for Finished Club Batches with Stale Status"
status: Planning
type: feature
project: wms1/wms-api
created: 2026-04-30
updated: 2026-04-30
author: Nam Park
related:
  - "../../../1-Projects/wms1/plan/SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md"
  - "../../../3-Resources/workflows/wms1-club-order-processing.md"
tags:
  - plan
  - club
  - wms1
---

# SBDEV-2164 — Cron Cleanup for Stale Club Batches

**Ticket:** SBDEV-2164
**Related plan:** [SBDEV-2163](SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md) — the guard that blocks future re-assignment; this cron corrects batches that are already stranded.
**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2164.sh`

---

## 0. Affected Sites (Enumeration Before Drafting)

| # | File:line | Construct | In-scope? | Phase |
|---|-----------|-----------|-----------|-------|
| 1 | `schedulejob/StaleClubBatchCleanupJob.java` | New cron shell | Yes — new file | Phase 1 |
| 2 | `service/job/StaleClubBatchCleanupJobService.java` | New orchestration service | Yes — new file | Phase 1 |
| 3 | `schedulejob/SchedulingConfiguration.java:46` | Inject + register cron | Yes — modify | Phase 1 |
| 4 | `service/WmsConstants.java:~1008` | 3 new sysprop key constants | Yes — modify | Phase 1 |
| 5 | `repo/jpa/CustomerorderBatchRepository.java` | `findStaleClubBatchIds` native query | Yes — new method | Phase 1 |
| 6 | `db/migration/V1.1.06__wms_updates.sql` | 3 sysprop rows | Yes — new file | Phase 1 |
| 7 | `service/CustomerorderBatchService.java:325` | `finalizeBatchIfComplete` — **reused as-is** | Yes — no code change, reused | — |
| 8 | `test/unit/service/StaleClubBatchCleanupJobServiceUnitTest.java` | Unit tests (orchestration + exception isolation) | Yes — new file | Phase 1 |
| 9 | `test/repo/CustomerorderBatchRepositoryTest.java` (or new) | Integration test for native query | Yes — new or extend | Phase 1 |

---

## 1. Problem Statement

Some club batches reach full order completion (all child orders shipped or cancelled) but their batch header state is never advanced to `FINISHED (700)`. These batches:

- Continue to appear in **Open Clubs** (the UI query filters `cb.state < 700`)
- May retain a **staging lane assignment** (`staginglane_id IS NOT NULL`) that blocks the lane
- Require manual intervention by support to correct

Root cause: `CustomerorderBatchService.finalizeBatchIfComplete()` is called on the normal shipping path (`closeBOL`), but edge cases (e.g., a batch shipped across multiple BOLs, with the last BOL closed without triggering the finalization check) leave the batch header stranded in an intermediate state.

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

## 2. Existing Code Leverage

`CustomerorderBatchService.finalizeBatchIfComplete(Long orderBatchId)` already contains the correct finalization logic:

```java
// CustomerorderBatchService.java:325-348
if (orders.stream().allMatch(o -> o.getState() >= WmsConstants.State.FINISHED)) {
    boolean allCanceled = orders.stream().allMatch(o -> o.getState() == WmsConstants.State.CANCELED);
    orderBatch.setState(allCanceled ? WmsConstants.State.CANCELED : WmsConstants.State.FINISHED);
    orderBatch.setStaginglaneId(null);
    customerorderBatchRepository.save(orderBatch);
    // clears transferlaneId on individual orders too
}
```

`CustomerorderBatchService` has a **class-level `@Transactional`** (line 28). Every call to `finalizeBatchIfComplete(batchId)` from a non-transactional caller opens its own transaction — giving per-batch isolation automatically.

The cron job reuses this method directly — no duplication of business logic.

---

## 3. Detailed Changes

### 3.1 `StaleClubBatchCleanupJob.java` (new)

Pattern: mirrors `CleanUpOldMessagesJob` exactly.

```java
package net.aim_ai.wms.schedulejob;

import net.aim_ai.wms.repo.jpa.LosSyspropRepository;
import net.aim_ai.wms.service.WmsConstants;
import net.aim_ai.wms.service.job.StaleClubBatchCleanupJobService;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

@Service
public class StaleClubBatchCleanupJob {

    private static final org.slf4j.Logger LOG = LoggerFactory.getLogger(StaleClubBatchCleanupJob.class);

    @Autowired
    private StaleClubBatchCleanupJobService staleClubBatchCleanupJobService;

    @Autowired
    private LosSyspropRepository losSyspropRepository;

    public void doCalculation(Boolean isCronJob) {
        LOG.info("start");

        if (isCronJob)
            if (!Boolean.parseBoolean(losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
                || !Boolean.parseBoolean(losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY))) {
                LOG.info("end   (not activated)");
                return;
            }

        long start = System.currentTimeMillis();
        staleClubBatchCleanupJobService.cleanupStaleBatches();
        LOG.info("end. took " + (System.currentTimeMillis() - start) + "ms");
    }
}
```

---

### 3.2 `StaleClubBatchCleanupJobService.java` (new)

```java
package net.aim_ai.wms.service.job;

import net.aim_ai.wms.model.CustomerorderBatch;
import net.aim_ai.wms.repo.jpa.CustomerorderBatchRepository;
import net.aim_ai.wms.service.CustomerorderBatchService;
import net.aim_ai.wms.service.WmsConstants;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class StaleClubBatchCleanupJobService {

    private static final Logger LOG = LoggerFactory.getLogger(StaleClubBatchCleanupJobService.class);

    // Safety cap: process at most this many batches per run to bound blast radius on first run.
    // Subsequent runs will catch the remainder. Raise via sysprop if needed.
    static final int MAX_CANDIDATES_PER_RUN = 500;

    @Autowired
    private CustomerorderBatchRepository customerorderBatchRepository;

    @Autowired
    private CustomerorderBatchService customerorderBatchService;

    // Do NOT add @Transactional here.
    // Per-batch isolation is provided by the class-level @Transactional on CustomerorderBatchService
    // (CustomerorderBatchService.java:28). Each finalizeBatchIfComplete() call opens its own
    // transaction because this caller has no active transaction. Adding @Transactional here would
    // collapse all N finalization calls into one transaction, causing a single
    // ObjectOptimisticLockingFailureException to roll back all prior corrections in the same run.
    public void cleanupStaleBatches() {
        LOG.info("start cleanupStaleBatches");

        List<Long> staleBatchIds = customerorderBatchRepository.findStaleClubBatchIds(
            WmsConstants.State.ORDER_BATCH_ACTIVATED,
            WmsConstants.State.FINISHED,
            MAX_CANDIDATES_PER_RUN
        );

        if (staleBatchIds.isEmpty()) {
            LOG.info("end   cleanupStaleBatches — no stale club batches found");
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
                    LOG.info("corrected  batch id={} number={} state={} staginglaneId={}",
                        after.getId(), after.getNumber(), after.getState(), after.getStaginglaneId());
                } else {
                    LOG.warn("batch id={} disappeared after finalization — investigate", batchId);
                }
                corrected++;

            } catch (Exception e) {
                // Log and continue — one failed batch must not block the remaining candidates.
                // Typical cause: ObjectOptimisticLockingFailureException from concurrent API activity.
                // The batch will be re-attempted on the next scheduled run.
                LOG.warn("failed to finalize batch id={} — skipping, will retry on next run. cause: {}",
                    batchId, e.getMessage());
                failed++;
            }
        }

        LOG.info("end   cleanupStaleBatches — corrected={} failed={} of {} candidates",
            corrected, failed, staleBatchIds.size());
    }
}
```

**Key design points:**
- **Per-batch exception isolation**: `try/catch(Exception)` per loop iteration. One `ObjectOptimisticLockingFailureException` logs a WARN and continues — remaining batches are not skipped.
- **Failure count surfaced**: summary log line includes `failed=N` so ops/support can detect problems without grepping individual warn lines.
- **Blast-radius cap**: `MAX_CANDIDATES_PER_RUN = 500` limits first-run exposure. A warning fires if the cap is hit, signalling a backlog.
- **Transaction isolation**: per-batch isolation is automatic — see the comment above `cleanupStaleBatches()`. Do NOT add `@Transactional` to this method.
- **Idempotency**: `finalizeBatchIfComplete` re-reads orders on every call. If a batch was already corrected between the candidate query and the per-batch call, it is a no-op. Safe to run twice.

---

### 3.3 `SchedulingConfiguration.java` (modify)

**Add injection** (alongside existing jobs, around line 46):

```java
@Autowired
private StaleClubBatchCleanupJob staleClubBatchCleanupJob;
```

**Call from `configureTasks()`** (after `releaseExpiredPickingOrdersFromUser(scheduledTaskRegistrar);`):

```java
staleClubBatchCleanup(scheduledTaskRegistrar);
```

**Add private scheduler method** (at the end of the existing private methods):

```java
private void staleClubBatchCleanup(ScheduledTaskRegistrar scheduledTaskRegistrar) {
    String hours = losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_KEY);
    String minutes = losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_KEY);
    String cronjob = "0 " + minutes + " " + hours + " * * *";
    scheduledTaskRegistrar.addCronTask(() -> {
        if (basicService.showLog())
            LOG.info("Stale Club Batch Cleanup - " + new Date());
        staleClubBatchCleanupJob.doCalculation(true);
    }, cronjob);
}
```

---

### 3.4 `WmsConstants.java` (modify)

Add six constants after the existing `CLEAN_UP_OLD_MESSAGES_*` block (~line 1008):

```java
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY          = "STALE_CLUB_BATCH_CLEANUP_ACTIVATED";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_ACTIVATED_DEFAULT_VALUE = "false";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_KEY          = "STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_DEFAULT_VALUE = "3";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_KEY        = "STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE";
public static final String SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_DEFAULT_VALUE = "0";
```

**Defaults**: daily at 03:00, disabled by default (`false`). Must be explicitly enabled per environment via the DB sysprop `STALE_CLUB_BATCH_CLEANUP_ACTIVATED = true`.

**03:00 rationale**: warehouse operations are lowest-traffic in the early morning. Existing cleanup jobs run at 02:00 (`CleanUpOldMessagesJob`) — 03:00 provides separation. Confirm against `SchedulingConfiguration` cron schedule at startup to avoid overlap.

---

### 3.5 `CustomerorderBatchRepository.java` (modify)

Add the following query:

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

**Query logic:**
- `type = 'CLUB'` — club batches only.
- `state >= 520 AND state < 700` — has been activated; not yet in a terminal batch state. States 520/525/530 are the only values in this range for club batches (verified from `WmsConstants.State.getCodeText` switch). RAW (0) and ASSIGNED (200) batches are excluded — a batch that never reached activation has no completed orders to correct.
- `EXISTS (child orders)` — excludes orphaned/empty batches.
- `NOT EXISTS (incomplete order)` — all child orders are terminal (state ≥ 700). Any single active order blocks the batch from appearing.
- `LIMIT :batchSize` — bounds first-run blast radius. Subsequent runs process the remainder.

**Why not reuse `finalizeBatchesByIds`?** That method performs a bulk UPDATE to a single target state and cannot distinguish FINISHED vs CANCELED per-batch. Using a separate SELECT + `finalizeBatchIfComplete` reuses tested per-batch logic that already handles the FINISHED/CANCELED distinction.

---

### 3.6 `V1.1.06__wms_updates.sql` (new migration)

> **Critical prerequisite**: sysprop IDs are managed manually by the team (confirmed as handled outside this plan). Verify `SELECT MAX(id) FROM los_sysprop` against each environment before applying.

```sql
insert into los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent, client_id, version, hidden, workstation, entity_lock, created, modified)
values (140, 'Backend', 'STALE_CLUB_BATCH_CLEANUP_ACTIVATED', 'false', 'Enable stale club batch cleanup cron job', 'true / false', 0, 0, FALSE, 'DEFAULT', 0, now(), now());

insert into los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent, client_id, version, hidden, workstation, entity_lock, created, modified)
values (141, 'Backend', 'STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR', '3', 'Hour to run the stale club batch cleanup job (0-23)', '0-23', 0, 0, FALSE, 'DEFAULT', 0, now(), now());

insert into los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent, client_id, version, hidden, workstation, entity_lock, created, modified)
values (142, 'Backend', 'STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE', '0', 'Minute to run the stale club batch cleanup job (0-59)', '0-59', 0, 0, FALSE, 'DEFAULT', 0, now(), now());
```

---

## 4. Testing Strategy

### 4.1 Unit Tests — `StaleClubBatchCleanupJobServiceUnitTest.java`

Follow `CleanUpOldMessageJobServiceUnitTest` style: `@ExtendWith(MockitoExtension.class)`, `@InjectMocks`, `@Mock`. No `mockStatic()` (Mockito 3.3.3 constraint).

Tests focus on **orchestration** (call counts, exception handling, logging). Finalization-decision logic lives in `CustomerorderBatchService` and is tested there separately.

| Test | Setup | Asserts |
|---|---|---|
| `whenNoStaleBatches_thenNothingFinalized` | `findStaleClubBatchIds` returns empty | `finalizeBatchIfComplete` never called |
| `whenOneStaleBatch_thenFinalizeCalledOnce` | One stale batch ID returned | `finalizeBatchIfComplete` called once with that ID |
| `whenMultipleStaleBatches_thenEachFinalizedIndependently` | Two stale batch IDs | `finalizeBatchIfComplete` called twice; both IDs seen |
| `whenBatchDisappearsBeforeFinalization_thenSkipped` | `findById` returns empty | Job does not call `finalizeBatchIfComplete`; no exception |
| `whenActivationFlagDisabled_thenNoOp` | Tested at `StaleClubBatchCleanupJob` level: sysprop returns `"false"` | `staleClubBatchCleanupJobService.cleanupStaleBatches()` never called |
| **`whenOneBatchThrowsException_remainingBatchesStillProcessed`** | Two batch IDs; `finalizeBatchIfComplete(id1)` throws `ObjectOptimisticLockingFailureException`; `finalizeBatchIfComplete(id2)` succeeds | `finalizeBatchIfComplete` called for **both** IDs; no exception propagates; failure count = 1 |
| `whenCandidateCountHitsCap_warningLogged` | `findStaleClubBatchIds` returns exactly `MAX_CANDIDATES_PER_RUN` entries | WARN log containing "cap" is emitted |

### 4.2 Repository Integration Test — `CustomerorderBatchRepositoryTest`

Add a Testcontainers test (extend `BaseRepositoryTest` / `AppPostgresDBSetupExtension`) that seeds data and verifies the native query:

| Scenario | Seeded data | Expected result |
|---|---|---|
| **Stale batch — all orders finished** | Batch: type=CLUB, state=530. Orders: both state=700 | Batch ID returned |
| **Active batch — one order still open** | Batch: type=CLUB, state=530. Orders: one=700, one=650 | Batch ID NOT returned |
| **Already finished batch** | Batch: type=CLUB, state=700. Orders: both state=700 | Batch ID NOT returned (state >= 700 excluded) |
| **Orphaned batch (no orders)** | Batch: type=CLUB, state=530. No child orders | Batch ID NOT returned (EXISTS guard) |
| **Non-club batch** | Batch: type=PICK_PACK, state=530. Orders: both state=700 | Batch ID NOT returned |
| **LIMIT respected** | 600 stale batches seeded | Only 500 returned |

> This is the critical test: `nativeQuery=true` bypasses JPQL validation. Without this test, a typo in the SQL ships silently.

### 4.3 Manual Test Plan

| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| M1 | Dry run — no stale batches | Enable sysprop in dev with no stale batches present | Log: `no stale club batches found` |
| M2 | Correct one stale batch | Manually set a club batch to state=530 with all orders at 700; trigger job via `doCalculation(false)` | Batch state → 700, staginglane_id → null; log shows before/after |
| M3 | Active batch not touched | Club batch with one order at 650 (PACKED) | Job does not finalize; batch state unchanged |
| M4 | Exception isolation | Mock/force one batch to throw during finalization | Job processes remaining batches; summary log shows `failed=1` |
| M5 | Blast-radius cap | Seed 600 stale batches in dev | Only 500 processed; WARN log about cap |
| M6 | Activation flag off | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED = false` | Job exits immediately; no finalization |

**DB helper — find current stale candidates (run against wms1-wineco-dev):**
```sql
SELECT cb.id, cb.number, cb.state,
       COUNT(co.id)                                             AS total_orders,
       COUNT(CASE WHEN co.state >= 700 THEN 1 END)             AS terminal_orders
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

Run this against dev/qa before enabling the sysprop to estimate the initial blast radius.

---

## 5. Backward Compatibility

| Aspect | Before | After | Impact |
|--------|--------|-------|--------|
| Open Clubs UI query | Stale finished batches appear (state < 700) | Corrected batches disappear after next cron run | Intended — fewer phantom entries |
| `customerorder_batch.state` — stale batch | Stuck at 520/525/530 | Advanced to 700 or 800 | Corrective; no API contract change |
| `staginglane_id` — stale batch | May be non-null (blocking lane) | Cleared to null | Corrective; frees the lane |
| `findByStateAndType` queries | Return stale batches | Return fewer results after correction | Intended |
| OMS notification | Not sent on cron correction | Not sent | `finalizeBatchIfComplete` does NOT trigger OMS webhooks — it only updates local DB state. OMS was already notified at ship time by `closeBOL`. No double-notification risk. |
| BOL / shipping data | Unchanged | Unchanged | Cron only corrects batch header; no BOL positions touched |

**What does NOT change:**
- `closeBOL` flow (normal finalization path)
- Any order state transitions
- `CustomerorderBatchService.finalizeBatchIfComplete` logic
- SBDEV-2163 guard (complementary; both plans coexist)
- Any API endpoint contracts

---

## 6. Phased Implementation Plan

### 6.1 Prerequisites

| Prerequisite | Status | Notes |
|---|---|---|
| SBDEV-2163 guard deployed | Recommended first | Prevents new stale batches; this cron cleans up existing ones |
| DB sysprop IDs verified | Required | Run `SELECT MAX(id) FROM los_sysprop` per environment; handled manually per team process |
| Blast-radius estimate | Required before enabling sysprop | Run candidate-count SQL from §4.3 against dev/qa/prod-replica before turning on |
| V1.1.06 migration clean | Required | `flyway:migrate` confirms no conflicts |

### 6.2 Phase 1 — Implement + test (single PR)

**Branch:** `task/SBDEV-2164`
**Merge target:** `main`
**Estimated effort:** 2–3 hours

1. Create `StaleClubBatchCleanupJob.java` (§3.1)
2. Create `StaleClubBatchCleanupJobService.java` (§3.2)
3. Modify `SchedulingConfiguration.java` (§3.3)
4. Modify `WmsConstants.java` (§3.4)
5. Modify `CustomerorderBatchRepository.java` — add `findStaleClubBatchIds` (§3.5)
6. Create `V1.1.06__wms_updates.sql` (§3.6)
7. Add unit tests (§4.1) — `mvn test -Dtest=StaleClubBatchCleanupJobServiceUnitTest`
8. Add repo integration test (§4.2) — `mvn verify`
9. Run `bash sbdocs/9-System/scripts/verify-SBDEV-2164.sh` — must report `Result: N pass, 0 fail`
10. PR review; merge

### 6.3 Phase 2 — Enable per environment

| Environment | Action | Notes |
|---|---|---|
| dev | `UPDATE los_sysprop SET sysvalue='true' WHERE syskey='STALE_CLUB_BATCH_CLEANUP_ACTIVATED'` + restart | Observe logs for first run; check candidate count |
| qa | Same, after dev confirmed | Confirm no active-batch false positives |
| prod | Same, after qa confirmed | Monitor `corrected=` and `failed=` counts in first week |

**Kill switch:** `UPDATE los_sysprop SET sysvalue='false' WHERE syskey='STALE_CLUB_BATCH_CLEANUP_ACTIVATED'` + restart. Takes effect on next scheduled run (in-progress run completes its current loop).

---

## 7. Alternatives Considered

| Option | Description | Why Rejected |
|--------|-------------|--------------|
| **Auto-fix at lane-assignment time (SBDEV-2163)** | When blocking a finished batch's lane assignment, also auto-advance batch state | Rejected in SBDEV-2163 §9: silent state mutation without BOL-close bypasses the normal finalization audit trail. That plan blocks; this plan corrects via an explicit, logged, auditable job. |
| **One-shot SQL script, no cron** | Run a manual UPDATE once to clear the backlog | Rejected: doesn't prevent future accumulation. New stale batches can appear if the root-cause edge case recurs. A cron provides an ongoing safety net. |
| **Fix root cause in `closeBOL`** | Ensure `finalizeBatchIfComplete` is always called correctly after the last BOL closes | Valid long-term fix. Does not correct already-stranded batches. Should be investigated as a follow-on; this cron provides a safety net in the meantime. |
| **Fire finalization from `@TransactionEventListener` on order shipment** | React to order state changes in real time | More complex, touches more code paths, higher risk. The cron approach is lower-risk and bounded. |
| **`finalizeBatchesByIds` bulk UPDATE** | Use existing `CustomerorderBatchRepository.finalizeBatchesByIds` for a single-query correction | Rejected: that method takes a fixed target state and cannot distinguish FINISHED vs CANCELED per-batch. `finalizeBatchIfComplete` already handles this correctly and is the canonical path. |

---

## 8. Rollout Plan

| Step | Action |
|------|--------|
| 1 | Branch `task/SBDEV-2164` off `main` |
| 2 | Implement all changes (§3) |
| 3 | `mvn test -Dtest=StaleClubBatchCleanupJobServiceUnitTest` — all pass |
| 4 | `mvn verify` — full suite including repo integration test passes |
| 5 | Run `bash sbdocs/9-System/scripts/verify-SBDEV-2164.sh` — `Result: N pass, 0 fail` |
| 6 | PR to `main`; peer review |
| 7 | Merge and deploy (sysprop defaults to `false` — no immediate execution) |
| 8 | Run candidate-count SQL (§4.3) against each environment; document counts in this plan |
| 9 | Enable in dev (`sysvalue='true'`, restart); verify first-run log output |
| 10 | Enable in qa; verify |
| 11 | Enable in prod; monitor `corrected=` and `failed=` for 7 days |

---

## 9. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|----------|------------|
| 1 | Should RAW (0) or ASSIGNED (200) batches be included? | **Resolved — No.** `minState = ORDER_BATCH_ACTIVATED (520)`. A batch that never reached activation has not had stock moved to a staging lane and cannot be in the "stale but effectively done" state the ticket targets. |
| 2 | Sysprop IDs 140–142 conflict? | **Resolved — handled manually.** Team process verifies `MAX(id)` per environment before migration apply. Not tracked in this plan. |
| 3 | Silently swallow or surface per-batch exception? | **Resolved — log WARN + continue.** `try/catch(Exception)` per iteration logs cause and increments `failed` counter. Summary line reports `failed=N`. This ensures one concurrent modification doesn't stop the rest of the run, and failures are visible in logs without being fatal. See `StaleClubBatchCleanupJobService.java` §3.2. |
| 4 | First-run blast radius? | **Resolved — capped at 500 per run + candidate-count SQL must be run before enabling in each env (§6.3).** |
| 5 | Does `finalizeBatchIfComplete` trigger OMS webhooks? | **Resolved — No.** `finalizeBatchIfComplete` (line 325-348) only updates `CustomerorderBatch.state` and clears `staginglaneId`. OMS was already notified at ship time by `closeBOL`. No double-notification risk. |
| 6 | v2 port needed? | **Deferred.** v2/wms2-api has the same club line flow. Track as a follow-on via `wms-v2-migrate`. |
| 7 | Idempotency | **Confirmed safe.** `finalizeBatchIfComplete` re-reads orders on every call. If a batch was already corrected between the candidate SELECT and the per-batch call, the stream check is a no-op and no write occurs. |

---

## Implementation Status

*To be filled in after implementation.*

- [ ] Code changes applied (§3)
- [ ] Unit tests added and passing
- [ ] Repository integration test added and passing
- [ ] `mvn verify` passing
- [ ] Verify script result: `Result: _ pass, 0 fail`
- [ ] Candidate-count SQL run against dev / qa / prod-replica; counts documented
- [ ] Sysprop enabled in dev; first run observed
- [ ] PR merged
- [ ] Branch: —
- [ ] Commit SHA: —
