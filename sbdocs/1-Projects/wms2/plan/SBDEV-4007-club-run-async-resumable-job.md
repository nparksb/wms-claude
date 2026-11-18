---
title: "SBDEV-4007 — Club Run async: claimed, resumable club-run job + submit-and-poll UI"
ticket: "SBDEV-4007"
ticket_url: "https://app.clickup.com/t/868mrmhn7"
type: feature
priority: normal
status: "on dev — wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845 (2026-11-06); P3 dropped; dev manual test done 2026-11-06 (M2/M3/M5 pass; M1/M4 deferred to UAT); §5.1 ingress timeout open; chunk size stays 1 (rollout dropped 2026-11-05)"
tier: T3
project: [wms2]
version: v2
requester: "Nam Park (split from SBDEV-3310; standup decision 2026-09-11)"
created: 2026-11-04
updated: 2026-11-07
db_verified: true
related:
  - "SBDEV-3310 (parent; outbox chunking shipped PR #351)"
  - "SBDEV-3312 (stale-batch cleanup, any type)"
  - "SBDEV-3328 (Run Club greyed out)"
  - "../../../3-Resources/workflows/wms2-club-run-workflow.md"
  - "SBDEV-4007-evidence/analysis.md"
  - "SBDEV-4007-evidence/resolved-decisions.md"
  - "SBDEV-4007-evidence/ralplan-iter1-architect.md"
  - "SBDEV-4007-evidence/ralplan-iter1-critic.md"
tags:
  - plan
  - club-run
  - async
  - flyway
---

# SBDEV-4007 — Club Run async: claimed, resumable club-run job + submit-and-poll UI

**Ticket:** [SBDEV-4007](https://app.clickup.com/t/868mrmhn7) · **Tier:** T3 (new Flyway table, claim/lease on club fulfilment, two repos)
**Status:** pending approval · **Base:** wms2-api `origin/develop 68a20d76`, wms2-web-ui `8eb11fe`
**Evidence:** [analysis.md](SBDEV-4007-evidence/analysis.md) · **Decisions:** [resolved-decisions.md](SBDEV-4007-evidence/resolved-decisions.md) ·
**Reviews:** [iter-1 Architect](SBDEV-4007-evidence/ralplan-iter1-architect.md), [iter-1 Critic](SBDEV-4007-evidence/ralplan-iter1-critic.md)

> **Iteration 2 changes:** one non-swallowing terminal transaction (`failJob`) (A-H2/C-H2) · shutdown/infra errors abandon the
> lease instead of failing the run (A-M1/C-H1) · `INSERT … ON CONFLICT` submit (A-H1/C-H3) · `rollbackFor` on every new tx and an
> unchecked lease-lost exception (C-M4/A-L1) · 300 s lease, max-attempts 2 + alert (A-M2/A-M4) · poller hands off on the executor
> thread with a capacity check (C-M8) · kill switch scope (C-M7/A-L3) · P3 kick capped at one iteration (A-M3/C-L15) · native job
> writes, no `@Version` (A-L4/C-L11) · explicit discard policy (A-L5) · legacy-GET P1→P2 gap documented, P1+P2 ship in one release
> (C-M6/A-L2) · TDD-gate skeleton strategy (C-M5) · manual plan with per-scenario data and restore (C-M9) · Architect's smaller design
> recorded in §9 as Alternative 0 (C asked for a fair hearing; A steelmanned it).
>
> **Iteration 3 changes:** standalone read-only entity + native insert with `nextval('seqentities')` — the AbstractBaseEntity claim was
> wrong against the DDL (C-N1) · poller submits a bounded `workers − activeCount` tasks per tenant per tick, no loop (A-N1/C-N2) ·
> abandon only on shutdown/interrupt/transient DB errors; every other exception → `failJob` (A-N2) · kill switch `'0'` no longer stops
> the poller, so live jobs always drain (A-N3/C-N3) · terminal `STUCK` escape when `failJob` itself keeps failing (A-N4) · abandon
> persists a sanitized abandon reason into `last_error` (C-N4, amended by Phase 3 S1: the raw exception goes to the WARN log, never to a client-readable column).
>
> **Iteration-3 Lows folded in (no re-review needed per both lanes):** transient abandon expires the lease immediately (A-L-a) ·
> `failJob` takes `original_batch_state` from the lease / a native read, never the cached entity (A-L-b) · poller rotates the starting
> tenant per tick (A-L-c) · kill switch does not stop worker code — named in §8 (C-L1) · `OptimisticLockingFailureException` is a
> `TransientDataAccessException` and therefore abandons — named in §3.4 (C-L2) · STUCK manual reconcile procedure in the workflow doc (C-L3).

---

## 0. Affected sites (enumeration before drafting)

Method: `git grep -P` on `origin/develop` for `runClubLine(`, `finalizeClubLine(`, `validateClubLine(`, `rollbackClubLineState(`,
`clubRunCancellationBlockingState(`, `processOrder(`, `ORDER_BATCH_CLUB_RUN_IN_PROGRESS`, `dispatchBatch(`, `LANE_CLUB`, across
`src/main`, `src/test`, wms2-web-ui and wms2-mobile-ui. Blind spot: reflection / string-built URLs. A first pass with `-E '\b'`
returned zero callers (macOS ERE ignores `\b`) and was discarded on the positive control (the known controller call).

| # | File + snippet | Construct | In scope? | Phase |
|---|---|---|---|---|
| 1 | `ClubLineController` `@GetMapping(path= "/runClubLine/{orderBatchId}"` | sync entry | yes — delegates to submit + bounded wait (D2) | P1 |
| 2 | `ClubLineController` — new `POST /clubRunJobs/{batchid}`, `GET /clubRunJobs/{jobId}`, `GET /clubRunJobs/byBatch/{batchid}` | new | yes | P1 |
| 3 | `CustomerorderBatchService.runClubLine` (`// WARNING: Do NOT add @Transactional to this method.`) | orchestrator | kept unchanged for the kill-switch path; the worker mirrors it | P1 |
| 4 | `CustomerorderBatchService.validateClubLine` (`findByIdForUpdate`, `setState(…CLUB_RUN_IN_PROGRESS)`) | 527 set | yes — new fenced overload; legacy signature unchanged | P1 |
| 5 | `CustomerorderBatchService.rollbackClubLineState` (`LOG.error("Failed to rollback batch {} state: {}"`) | failure reset | **not used by the job path** — replaced there by the non-swallowing `failJob` (§3.4); legacy unchanged | P1 |
| 6 | `CustomerorderBatchService.finalizeClubLine` (`batch.setState(…ORDER_BATCH_CLUB_RUN_FINISHED)`) | 530 + outbox | yes — fenced overload, job DONE in the same tx | P1 |
| 7 | `ClubLineOrderProcessor.processOrder` (`findByLabelidForUpdate`, `order.setParcelId(packageUnitLoad.getId())`) | per-order tx | no code change — joined by a fenced step | P1 |
| 8 | `CustomerorderService.clubRunCancellationBlockingState` (`boolean inProgress = state == …CLUB_RUN_IN_PROGRESS`) | cancel guard | no change | — |
| 9 | `WmsConstants` `ORDER_BATCH_CLUB_RUN_IN_PROGRESS = 527` | state | no change | — |
| 10 | `StaleClubBatchCleanupJobService` / `CustomerorderBatchRepository.findStaleBatchIds` | cleanup | no change — regression pin (AC-12) | P1 test |
| 11 | `OutboxDispatchService.dispatchBatch(lane)`; `OutboxDispatcherJob` `runLane(OutboxMessage.LANE_CLUB, …OUTBOX_DISPATCHER_CLUB, false)` | dispatch | yes — post-finalize kick | P3 |
| 12 | `db/migration/V2.2.47__club_run_job.sql` | new table | yes | P1 |
| 13 | web-ui `store/processes/clubRuns.js` `async runClubLine(context, data)` (`message !== 'RUN CLUBLINE'` check), `reconcileRunStatus` | client | yes — submit + poll | P2 |
| 14 | web-ui `components/processes/clubRuns/itemsTable.vue` (`this.clubStateCode === 527`, dispatch) | client | yes — progress | P2 |
| 15 | web-ui `cypress/e2e/wms/club/club-line-order.cy.js` D.1 (`call twice`; "Mirrors what the Mobile UI does") | e2e | yes — rewrite premise | P2 |
| 16 | tests `ClubLineRetryIntegrationTest`, `CustomerorderBatchServiceUnitTest`, `ClubLineControllerUnitTest`, `ClubLineOrderProcessorUnitTest` | existing | must stay green; extend | P1 |
| 17 | wms2-mobile-ui | — | no — `git grep -i club` hits only fontawesome assets | — |
| 18 | `wms2-club-run-workflow.md` §7 row 2, §9.9 (claim the batch lock spans the run) | doc | yes — correct | P1 |

---

## 1. Problem Statement

`GET /v3/clubLine/runClubLine/{batch}` runs the whole club synchronously on the request thread. Standup 2026-09-11 (Scott, on
SBDEV-3310) decided club processing must be **asynchronous**: the request returns immediately and work continues on its own,
regardless of the 57.8 s / 1,200-order dev timing. Ingress read timeout is known only as ≥ 58 s; a 1,295-order run projects to ~62 s.

A second, present-day defect sharpens this (analysis §0.2, re-verified, confirmed by both reviewers): **a run killed mid-flight
strands its batch at 527.** `rollbackClubLineState` runs only from `runClubLine`'s in-JVM `catch`, and swallows its own failure, so
a pod kill / OOM / redeploy leaves 527 — re-run refused (`"Cannot run club line on batch in state: "`), cancel refused, stale cleanup
not matching, UI "running" forever. Today 0 such batches on dev and prd (Q3, Q5): latent, and async background work plus rolling
deploys make it likelier.

**Ticket correction (needs Nam's ack, Q1).** Ticket §5 item 2 says "same-batch safety is already handled … add no new lock". The
batch row lock covers only Phase 1; the committed 527 serialises runs and cannot tell live from orphaned. This plan adds **no lock on
the batch**; the **job row's lease + `attempt` fence** becomes the liveness authority (§3.3).

---

## 2. Current Architecture

### 2.1 Run path (`CustomerorderBatchService`, origin/develop)

```
GET /runClubLine/{batchid}  (ClubLineController, @RequiresFunction(WEB_UI_VIEW_CLUB_LINE))
  └─ runClubLine(batch)                         non-transactional orchestrator
       ├─ P1 self.validateClubLine(batch)        tx: findByIdForUpdate → state∈{ACTIVATED,STAGING_LANE_ASSIGNED}
       │                                             → 527 → stock check → size guard ("exceeds maximum allowed (", thrown after 527 ⇒ rolled back)
       ├─ P2 for order: clubLineOrderProcessor.processOrder(...)   one REQUIRED tx per order
       │       label lock (findByLabelidForUpdate) → reuse matching package | build package → order.setParcelId + save
       ├─ P3 self.finalizeClubLine(id, orders)   tx: orders+positions PACKED, batch 530, lane release, outbox (LANE_CLUB, chunked)
       └─ catch → self.rollbackClubLineState(id, originalState)   (findById, catch-all, swallows)
```

### 2.2 Resume is already latent in the code (R-3 settled)

- `clubRequirements(batchId, true)` counts orders with `getParcelId() != null` as **packed** (subtracted in `validateStockOnStagingLane`)
  and refuses unless the package is still in packaging and `clubLineOrderProcessor.hasReusablePackage(...)`.
- `processOrder` reuses a matching package (`"reusing existing package unitload={} for order={} (idempotent re-run)"`).
- DB (Q7, dev): all 9 runnable CLUB batches (520/525) have `parcel_id` NULL on every order and a staging lane — so
  `count(parcel_id IS NOT NULL)` is a truthful progress counter for a run.

### 2.3 Outbox ordering (R-6 settled)

`OutboxMessageRepository.findAndClaimPending` claims `FOR UPDATE SKIP LOCKED` gated by `NOT EXISTS (… e.aggregate_type = o.aggregate_type
AND e.aggregate_id = o.aggregate_id AND e.id < o.id AND e.status IN ('PENDING','FAILED_RETRY','IN_FLIGHT','FAILED_TERMINAL'))`: a
second consumer cannot overtake an aggregate's head. CLUB lane cron `*/3` under advisory lock `OUTBOX_DISPATCHER_CLUB` (100009),
taken **before** the tenant loop (`OutboxDispatcherJob` `if (!advisoryLockService.tryLock(lockId))`) — i.e. **global across tenants**.

### 2.4 DB facts (full log: analysis §F)

| Fact | dev `dev_wh01_om1` | prd `wsl-wineco-prd` |
|---|---|---|
| CLUB batches at 527 | 0 | 0 |
| CLUB states | 0:13, 520:8, 525:1, 530:22, 700:10770, 800:6 | 0:2, 520:1, 525:1, 700:11938, 800:35 |
| Runnable CLUB batches (520/525, lane set, no parcel) | 9 — `41479-2` (7 orders), `41078-8` (5), seven with 1 order | — |
| `WMS_CLUBLINE_OMS_CHUNK_SIZE` | 100 (2026-11-03 23:13 UTC; restored to 1 on 2026-11-05) | 1 |
| `unitload.labelid` unique | yes (lane) | yes — `uq_unitload_labelid` + duplicate `uk_s2ujivixnde5dqb2stih8m2vh` |
| Largest club, 45 d | 1,200 (done) | 328 |
| Highest Flyway / V2.2.47 claimed? | V2.2.45 / no (`git ls-tree` over every remote branch; `git log --all -- '*V2.2.47*'` empty) | — |

---

## 3. Design

### 3.1 Data model — `V2.2.47__club_run_job.sql`

```sql
CREATE TABLE IF NOT EXISTS public.club_run_job (
  id                   bigint PRIMARY KEY,               -- nextval('seqentities') in the native insert (V2.2.18 precedent)
  orderbatch_id        bigint NOT NULL REFERENCES public.customerorder_batch(id),
  state                varchar(16) NOT NULL,             -- QUEUED | RUNNING | DONE | FAILED | STUCK
  attempt              integer NOT NULL DEFAULT 0,       -- fencing token; +1 on every claim
  original_batch_state integer,                          -- set by the first validate; restore target for failJob
  total_orders         integer,
  lease_owner          varchar(128),                     -- host:uuid of the claimant (diagnostics; logged per attempt)
  lease_expires_at     timestamptz,
  last_error           text,
  requested_by         varchar(255),
  created_at           timestamptz NOT NULL DEFAULT now(),
  started_at           timestamptz,
  finished_at          timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_club_run_job_live_batch
  ON public.club_run_job (orderbatch_id) WHERE state IN ('QUEUED','RUNNING');
CREATE INDEX IF NOT EXISTS ix_club_run_job_claim ON public.club_run_job (state, lease_expires_at, id);
```

- No `GRANT` (matches V2.2.42's convention); seeds sysprop `WMS_CLUBLINE_ASYNC='1'` with the V2.2.29 `(syskey, workstation='DEFAULT')`
  guard; a missing row is covered by the code default `'1'` (`SYSTEM_PROPERTY_CLUBLINE_ASYNC_DEFAULT_VALUE`).
- **`ClubRunJob` is a standalone `@Entity @Immutable` mapped to exactly the columns above — it does NOT extend `AbstractBaseEntity`**,
  which maps `created`, `modified` and `@Version Integer version` (`AbstractBaseEntity.java`) that this table does not have; under
  `ddl-auto=none` that mismatch would boot cleanly and fail every read with 42703 (C-N1). **Every write is native:** the insert
  (`nextval('seqentities')`), then `UPDATE … WHERE id = :id AND attempt = :attempt` (A-L4/C-L11). JPA is used for reads only.
- **No per-order progress table:** progress = `count(non-CANCELED orders of the batch with parcel_id IS NOT NULL)` (§2.2). This is how
  the plan meets D1's "per-order progress" — see Q1.

### 3.2 Submit (request thread) — `ClubRunJobService.submit(batchid, user)`

`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`:
1. Load batch (`findByBatchid`; not found → existing error shape).
2. Kill switch `'0'` → BusinessException `"Async club run is disabled for this warehouse (WMS_CLUBLINE_ASYNC=0)"`.
3. Synchronous pre-checks so obvious errors return on the click: state ∈ {ACTIVATED, STAGING_LANE_ASSIGNED} **or** a live job exists;
   order count ≤ the max-batch-size guard (same `"exceeds maximum allowed ("` prefix). The worker's validate re-checks authoritatively.
4. Native `INSERT INTO club_run_job (id, …) VALUES (nextval('seqentities'), …) ON CONFLICT (orderbatch_id) WHERE state IN ('QUEUED','RUNNING') DO NOTHING RETURNING id`; nothing returned →
   `SELECT` the live row and return it. No exception path, so the tx never aborts (A-H1/C-H3).
5. `afterCommit` → `clubRunExecutor.execute(claimAndRunTask(tenant))`; the executor's rejection policy is explicit discard + counter
   (A-L5), so a committed submit can never surface a 500; the poller picks the row up.

### 3.3 Claim, lease, fence — the liveness authority

**Claim** (`ClubRunJobRepository.claimNext`, native, in `ClubRunJobClaimService` REQUIRES_NEW, executed **on the executor thread**):
```sql
UPDATE club_run_job
   SET state='RUNNING', attempt = attempt + 1, lease_owner = :owner,
       lease_expires_at = now() + make_interval(secs => :leaseSecs), started_at = COALESCE(started_at, now())
 WHERE id = (SELECT id FROM club_run_job
              WHERE state = 'QUEUED' OR (state = 'RUNNING' AND lease_expires_at < now())
              ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING id, orderbatch_id, attempt, original_batch_state;
```

**Fence + heartbeat** (`ClubRunJobRepository.renewLease`) — the **first statement** of each of the four worker transactions:
`validateClubLine(batch, lease)`, `ClubRunStepService.processOrderFenced`, `finalizeClubLine(…, lease)`, `ClubRunJobService.failJob`:
```sql
UPDATE club_run_job SET lease_expires_at = now() + make_interval(secs => :leaseSecs)
 WHERE id = :jobId AND attempt = :attempt AND state = 'RUNNING'
```
`0 rows` ⇒ `ClubRunLeaseLostException` (**unchecked**, so every `rollbackFor` variant rolls back — A-L1) ⇒ that tx rolls back; the
worker stops and touches nothing else.

**Why it is safe across replicas.** The fence UPDATE row-locks the job row until the worker tx commits; a claim uses `SKIP LOCKED` and
cannot claim a job whose holder is mid-transaction. Between transactions the holder holds nothing, so a reclaimer that wins is the only
writer from then on; the superseded holder's next fence finds `attempt` changed and rolls back. Lock order inside a worker tx is always
job row → batch row (validate/finalize/failJob) or job row → label row (processOrder): acyclic (Architect confirmed).
**Lease length is a liveness knob, not a safety knob** (safety comes from the row lock), so it is long: `app.clubline.job.lease-seconds=300`
— a validate or finalize at prd chunk size 1 cannot outlive it and burn an attempt (A-M2). Recovery after a crash therefore takes ≤ 5 min.

**Fenced validate** `validateClubLine(batch, ClubRunLease lease)`: renewLease → `findByIdForUpdate` →
- state ∈ {ACTIVATED, STAGING_LANE_ASSIGNED}: record `original_batch_state` on the job (native, fenced), set 527 — as today;
- state == 527 **and** the job's `original_batch_state` is non-null (this job moved it): **resume** — keep 527;
- otherwise BusinessException as today. The no-lease overload keeps today's behaviour byte-for-byte (527 refused).

### 3.4 Worker — `ClubRunJobWorker.execute(ClubRunLease)`

Non-transactional orchestrator mirroring `runClubLine` (same `self.*` proxy rule). Every new `@Transactional` is
`(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` so a joined `processOrder`
failure surfaces its real message, not `UnexpectedRollbackException` (C-M4; 260520 §5.4).
1. `validateClubLine(batch, lease)` → orders, snapshot — rebuilt from the DB every attempt, never persisted.
2. Per order: `ClubRunStepService.processOrderFenced(lease, …)` (REQUIRED): renewLease → `clubLineOrderProcessor.processOrder(...)` (joins).
   Orders with a reusable package take the cheap reuse path.
3. `finalizeClubLine(id, orders, lease)`: renewLease → today's body → job `DONE` + `finished_at` in the **same tx**.
4. P3 hook (§3.7) after the finalize commit.

**Failure classification** (A-M1/C-H1/A-H2/C-H2):

| Throwable | Action | Job | Batch |
|---|---|---|---|
| `ClubRunLeaseLostException` | stop | owned by the new holder | untouched |
| **transient / shutdown only:** shutdown flag (`ClubRunShutdownGuard` — `SmartLifecycle.stop()`), `InterruptedException` / interrupt flag, `TransientDataAccessException` (covers lock-acquisition and query-timeout subtypes), `DataAccessResourceFailureException`, `CannotCreateTransactionException`, **matched anywhere in the cause chain** (Phase 3 F5; a `TransactionSystemException` whose root SQLException has SQLState `08*` counts), **unless the top-level exception is a `BusinessException`/`FacadeException`, which always fails** (re-review N3/R2) | **abandon** — best-effort fenced native write of a sanitized abandon reason into `last_error` (C-N4 as amended by S1; full exception logged at WARN with job id + attempt); for a transient error **and for the shutdown flag** (Phase 3 F7) the same write sets `lease_expires_at = now()`, so the next poller tick reclaims instead of waiting 300 s (A-L-a); a bare interrupt without the flag, and an abandon after `failJob` itself failed, keep the lease, so each retry waits up to `lease-seconds`; then return. ⚠ Spring's `TransientDataAccessException` includes `OptimisticLockingFailureException` (via `ConcurrencyFailureException`), so a version-skew bug abandons and retries rather than failing fast — bounded by the poison guard (C-L2) | RUNNING; resumes on the next tick (transient error, or shutdown flag — F7) or after lease expiry (bare interrupt, failJob-failed abandon, or JVM death) (D3) | 527 |
| **everything else** — `BusinessException`, `FacadeException` (shortfall, label conflict, package mismatch, size) **and** any other exception (`EntityNotFoundException`, `DataIntegrityViolationException`, NPE …) (A-N2) | `failJob(lease, msg)` — **one** tx: renewLease → `findByIdForUpdate(batch)` → if 527, restore to `original_batch_state` (taken from the lease the claim returned, or a native read in this tx — never the `@Immutable` entity's first-level-cache copy, A-L-b) → job `FAILED` + `last_error`. **No catch-all.** Non-business exceptions keep today's `"Club line processing failed: "` prefix | FAILED | restored (or untouched if validate never set 527) |
| `failJob` itself throws | log + abandon | stays RUNNING → lease expiry → reclaim → re-run → `failJob` retried | 527 until then; never FAILED-with-527 |
| `failJob` keeps failing (claim with `attempt > max-attempts + 2`) | **terminal escape** (A-N4): native fenced `UPDATE … SET state='STUCK', last_error=…` with **no batch write**; ERROR log + alert `wms2.clubrun.job.stuck` | STUCK (terminal, not live) | 527 — manual reconcile (procedure in `wms2-club-run-workflow.md`, added in P1: inspect the job's `last_error`; restore the batch with `UPDATE customerorder_batch SET state = <job.original_batch_state> WHERE id = <id> AND state = 527`; resubmit — the run resumes via package reuse) (C-L3) |
| process death | — | RUNNING; resumes after lease expiry | 527 |

Invariant pinned by AC-9b: **`job.state = FAILED ⇒ batch.state ≠ 527`, unless the job never recorded an `original_batch_state`** — i.e. the 527 was set by a *different* run (the kill-switch race: legacy GET's `hasLiveJob()` then inline `runClubLine`, no lock between). That job cannot have caused the 527, since validate writes `original_batch_state` and 527 in one tx; `failJob` leaves the batch untouched and suffixes `last_error` with `"; batch at 527 owned by another run"` (Phase 3 CR2/V10). Apart from that, the only job state that may coexist with a 527 batch and no
live job is `STUCK`, which always alerts.

**Poison guard (A-M4):** on claim, `attempt > app.clubline.job.max-attempts` (default **2**) ⇒ `failJob(lease, "abandoned after N attempts") — *implementation deviation (V4): no "last owner", because the claim has already overwritten `lease_owner`; prior owners are in the worker log lines*`
instead of running. Each claim logs `lease_owner` and `attempt`; metric `wms2.clubrun.job.resumed` + alert on `attempt ≥ 2`. A run that OOMs
its JVM therefore costs at most two pods, and the operator gets the batch back with an explanation.

### 3.5 Executor, poller, shutdown

- `clubRunExecutor`: `ThreadPoolTaskExecutor` core=max=`app.clubline.job.workers` (default 2), queue 0 (direct hand-off),
  `setTaskDecorator(new TenantAwareTaskDecorator())`, `DiscardPolicy` + counter `wms2.clubrun.job.kick_rejected`.
  `setWaitForTasksToCompleteOnShutdown(false)` stays — an interrupted run now **abandons** (§3.4) and resumes elsewhere, which is what D3 wants for a rolling deploy.
- `ClubRunJobPollerJob` `@Scheduled(cron = "${app.cron.club-run-job:*/4 * * * * *}")` (*`*/4`, not `*/5`: `*/5` fires at second 50, which `RECONCILE_CRON` owns — implementation deviation V3*): for each tenant (OutboxDispatcherJob pattern,
  sets/clears `TenantContext`; the starting tenant rotates each tick so a backlogged tenant cannot starve the rest — A-L-c), submits `claimAndRunTask(tenant)` tasks from **one per-tick budget `max(0, workers − executor.getActiveCount())`, computed once and spent across tenants in rotation order** (Phase 3 CR3 — per-tenant recomputation over-offered and made the rejection metric noise), once,
  with no loop** (A-N1/C-N2) — an empty claim returns in milliseconds and the next tick tries again; an over-submission is discarded
  harmlessly. **The claim happens on the executor thread**, so a rejected task never strands a fresh RUNNING lease and no job runs on the
  shared scheduler pool (C-M8). The poller **ignores the kill switch** — live jobs must always drain (§3.6). No advisory lock by design: SKIP LOCKED is the coordination and every replica
  should poll (CLAUDE.md's advisory-lock rule targets non-claiming jobs). JobMetrics `startTimer/completed/failed`.
- Cost of polling: one indexed `UPDATE … WHERE id = (SELECT … SKIP LOCKED LIMIT 1)` per tenant per replica per 4 s (Phase 3 S7 accepted: an idle backoff was tried as F15 and removed — tenant pools never idle-evict anyway because OutboxDispatcherJob touches every tenant every 3 s, and the backoff delayed rolling-deploy resume by up to 60 s), usually a no-op (Architect tension 3, accepted).

### 3.6 Endpoints

All `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_CLUB_LINE)` — the function the screen's existing run route carries.
Error shape unchanged: `200 {"errors":[{"field":"Runtime Error","message":…}]}`.

| Method + path | Returns |
|---|---|
| `POST /v3/clubLine/clubRunJobs/{batchid}` | `202 {jobId, state, batchid}`; existing live job → same body |
| `GET /v3/clubLine/clubRunJobs/{jobId}` | `{jobId, state, processed, total, lastError, batchState, attempt, startedAt, finishedAt}` (`readOnly = true`) |
| `GET /v3/clubLine/clubRunJobs/byBatch/{batchid}` | latest job for the batch, or the errors shape |
| `GET /v3/clubLine/runClubLine/{batchid}` (legacy, D2) | `'0'` → today's inline `runClubLine`, but refused if the batch has a live job (C-M7). `'1'` → submit, then poll the job row every 500 ms up to `app.clubline.sync-wait-seconds` (default 45, < the ≥ 58 s floor). DONE → today's `"RUN CLUBLINE"` body; FAILED → today's errors shape with `lastError`; timeout → `200 {message:"RUN CLUBLINE QUEUED", jobId, state}` |

**Legacy-GET contract change (C-M6/A-L2/C-L16), stated plainly:**
- The *current* web UI treats any `message !== 'RUN CLUBLINE'` as "Unrecognized club run response" → `reconcileRunStatus`. On a
  timeout with the batch at 527 it recovers the right state; if the job is still **QUEUED** (both workers busy) the batch is 520/525 and the
  operator sees an error toast for a run that will still happen. **Mitigation:** P1 and P2 ship in the **same release** (§8); the window
  exists only on dev between the two merges. WineCo prd runs (≤ 328 orders ≈ 15 s) finish well within 45 s.
- A second legacy GET during a live run used to be refused at 527; now it attaches to the live job and waits. Behaviour change, benign.
- The bounded wait holds a request thread but no DB connection (`spring.jpa.open-in-view=false`; each poll is a short read).

**Kill switch `WMS_CLUBLINE_ASYNC` (per tenant):** `'0'` ⇒ **no new jobs** — submit refuses and the legacy GET runs inline as today (and keeps
today's stranded-527 exposure — documented, A-L3); the legacy GET refuses a batch that still has a live job. **The poller keeps running**, so
QUEUED jobs run and expired RUNNING jobs are reclaimed and finish (A-N3/C-N3): flipping the switch never strands a batch.

### 3.7 P3 — kick the CLUB outbox lane when a run finishes

> **Dropped 2026-11-06 (Nam):** a PRD measurement showed the kick saves at most one cron tick (~2 s of a ~48 s drain). See §11, "P3 decision". The design below is kept for the record and is not implemented.

After `finalizeClubLine` commits, on the worker thread: `advisoryLockService.tryLock(OUTBOX_DISPATCHER_CLUB)`; if acquired, set the
tenant context and run **one** `dispatchBatch(LANE_CLUB)` (≤ 25 rows), release in `finally`; if busy, return. One iteration bounds the
cross-tenant stall of the global lane lock to a single batch (A-M3/C-L15); the remaining rows drain on the next 3 s tick. With chunk size
100, a 1,200-order club is 36 rows — two kicks' worth. No HTTP inside any tx.

---

## 4. File Change Summary

| File | Change | Phase |
|---|---|---|
| `db/migration/V2.2.47__club_run_job.sql` | Add — table, 2 indexes, `WMS_CLUBLINE_ASYNC` seed | P1 |
| `model/ClubRunJob.java` | Add — standalone `@Entity @Immutable` (not `AbstractBaseEntity`), reads only + `State` enum | P1 |
| `repo/jpa/ClubRunJobRepository.java` | Add — native `insertIfNoLive`, `claimNext`, `renewLease`, `markDone`, `markFailed`, `setOriginalState`, finders; `@RestResource(exported = false)` | P1 |
| `service/ClubRunJobService.java` | Add — submit, status, `failJob` | P1 |
| `service/ClubRunJobClaimService.java`, `ClubRunJobWorker.java`, `ClubRunStepService.java`, `ClubRunLease.java`, `ClubRunShutdownGuard.java`, `exceptions/ClubRunLeaseLostException.java` | Add | P1 |
| `config/ClubRunExecutorConfig.java` | Add | P1 |
| `schedulejob/ClubRunJobPollerJob.java` | Add | P1 |
| `service/CustomerorderBatchService.java` | Modify — fenced `validateClubLine`/`finalizeClubLine` overloads; legacy signatures and `rollbackClubLineState` unchanged | P1 |
| `controller/ClubLineController.java` | Modify — 3 mappings; legacy GET delegates (D2) | P1 |
| `service/WmsConstants.java` | Modify — `SYSTEM_PROPERTY_CLUBLINE_ASYNC_KEY/_DEFAULT_VALUE` | P1 |
| `application.properties` | Modify — `app.clubline.job.{workers,lease-seconds,max-attempts}`, `app.clubline.sync-wait-seconds`, `app.cron.club-run-job`; add the cron to the enumerated task list (comment: "This enumeration has rotted three times") | P1 |
| `service/OutboxLaneKicker.java` | Add | P3 |
| web-ui `store/processes/clubRuns.js`, `components/processes/clubRuns/itemsTable.vue`, `cypress/e2e/wms/club/club-line-order.cy.js` | Modify | P2 |
| `sbdocs/…/wms2-club-run-workflow.md`, `wms2-scheduled-jobs-catalog.md`, `wms2-rest-api-reference.md`, `wms2-function-to-docs-map.md` §9, `wms2-sysprop-catalog.md` | Modify — docs | P1/P3 |

---

## 5. Phased Implementation Plan

### 5.1 Prerequisites

| # | Area | Requirement | Owner | Status |
|---|---|---|---|---|
| 1 | Database state | Flyway at V2.2.45 on develop; **renumbered V2.2.46 → V2.2.47 on 2026-11-04 (Nam)** because SBDEV-4002 (peer session, unpushed local commit) took V2.2.46. The plan-time check swept **remote** branches only and could not see a peer's local commit — use `src/main/resources/db/check-migration-version-collision.sh V2.2.47` and re-check at merge per `wms-merge` | implementer | renumbered |
| 2 | Feature flags / sysprops | `WMS_CLUBLINE_ASYNC` seeded `'1'`. ~~**Separate config step (D4):** `WMS_CLUBLINE_OMS_CHUNK_SIZE` → `100` per tenant~~ | Nam | **closed — rollout DROPPED (Nam, 2026-11-05, on SBDEV-3310)**: stays `1` on every tenant. Chunking would save ~2 min and brings in Joe's two failure modes (a terminal 400 strands a 100-order chunk; a partial OMS 200 with `failed_records` is marked SENT). Raise it only after 3 prerequisites: per-record `failed_records` handling (SBDEV-2736 Ph2), recovery for stuck club chunks, and OMS accepting a repeated status. V2.2.48 (#623) rewrote the sysprop description to "Keep at 1" |
| 3 | Config / env | defaults in `application.properties` only | — | N/A |
| 4 | Deploy order | P1 (wms2-api) and P2 (wms2-web-ui) **in the same release cut** (§3.6 legacy-GET gap) | release owner | — |
| 5 | Data migration | none — a pre-deploy orphan at 527 (0 on dev/prd today) has no job and stays manual | — | N/A |
| 6 | External systems | **Measure the real ingress read timeout** (dev/UAT/prd; Portainer stack or a deliberate slow endpoint) → sets `app.clubline.sync-wait-seconds` (D4) | Nam / DevOps | open |
| 7 | Access | no new function — `WEB_UI_VIEW_CLUB_LINE` | — | N/A |
| 8 | Monitoring | `wms2.clubrun.job.{submitted,completed,failed,resumed,lease_lost,abandoned,kick_rejected,stuck}` + run timer; Grafana panel; alert on `resumed` (attempt ≥ 2) and on any `stuck` | implementer | P1 |

### 5.2 Phases

| Phase | Goal | Branch | Risk | Effort |
|---|---|---|---|---|
| **P1** API | table, claim/lease/fence, worker, poller, endpoints, legacy delegation, kill switch, ITs | `feature/SBDEV-4007-club-run-async` (wms2-api, off `origin/develop`) | High (data integrity) | 2–3 d |
| **P2** web-ui | submit + poll (2 s, backoff to 10 s after 60 s) + progress, reload-safe, FAILED display, cypress D.1 | `feature/SBDEV-4007-club-run-async` (wms2-web-ui) | Low | 1 d |
| **P3** outbox kick | `OutboxLaneKicker` | commit on the P1 branch if still open, else `feature/SBDEV-4007-p3-outbox-kick` | Low | ½ d |

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| `GET /runClubLine/{batch}` | inline; `"RUN CLUBLINE"` or errors | same bodies within 45 s; `"RUN CLUBLINE QUEUED"` + jobId on timeout; a concurrent second GET now waits instead of being refused | additive variant; current UI hits its error branch on the QUEUED variant — closed by shipping P2 together (§3.6) |
| Batch states | 520/525 → 527 → 530 | unchanged | none |
| Crash / redeploy mid-run | stranded 527 | resume within one lease (≤ 5 min) | fix |
| Business failure | batch restored via a swallowing rollback | batch restored in the same tx as job FAILED; never FAILED-with-527 | stricter |
| Schema | — | new table + sysprop row | additive |
| Outbox | cron-only | + one-batch kick under the same lane lock | none |

**What does NOT change:** `processOrder`, `clubRequirements`, stock validation, batch state codes, cancel guard, stale cleanup, outbox
enqueue/chunking, function gating, error-response shape, the legacy `runClubLine`/`validateClubLine`/`rollbackClubLineState` signatures,
mobile UI (no club code).

---

## 7. Testing Strategy

**TDD-gate strategy (C-M5).** The gate commits **skeletons** of every new production type — `ClubRunJob`, `ClubRunJobRepository` (native
queries present), `ClubRunJobService`, `ClubRunJobClaimService`, `ClubRunJobWorker`, `ClubRunStepService`, `ClubRunLease`,
`ClubRunLeaseLostException`, the controller mappings — whose method bodies `throw new UnsupportedOperationException("SBDEV-4007")`, plus
V2.2.47 itself. Every behavioural test then compiles and fails at an **assertion** (or with that named exception, which the gate counts as
the right reason only where the AC asserts behaviour of the stubbed method). Claim/lease tests are **Testcontainers** (H2 has no
`SKIP LOCKED` / `make_interval`). Seams for crash simulation are a Mockito spy on `ClubRunStepService` (throw after k orders) and direct
aging of `lease_expires_at` — no production test flags (C-L14).

| AC | Observable | Test (class#method) | Kind |
|---|---|---|---|
| AC-1 | submit returns a QUEUED job; wrong state / oversize rejected synchronously with today's messages | `ClubRunJobServiceUnitTest#submit_*`, `ClubLineControllerUnitTest#submitClubRun_*` | unit |
| AC-2 | two concurrent submits (2 threads, latch) → one job id, no exception, one row | `ClubRunJobServiceIT#submit_shouldReturnOneJobAndOneRow_whenTwoThreadsSubmitConcurrently` | IT |
| AC-3 | run to completion: batch 530, orders PACKED, job DONE | `ClubRunJobWorkerIT#claimAndRun_shouldRunToDone_whenJobQueued` | IT |
| AC-4 | status `processed` = count of orders with parcel_id; monotonic during a run | `ClubRunJobWorkerIT#status_shouldReportProgressFromParcelIds_whenRunAdvances` | IT |
| AC-5 | a rolled-back order leaves no progress (parcel_id null) | `ClubRunJobWorkerIT#claimAndRun_shouldLeaveNoProgressForRolledBackOrder_whenOrderFails` | IT |
| AC-6 | spy aborts after k of n (abandon), lease aged → reclaim → DONE; unitload count = n (no duplicates) | `ClubRunJobWorkerIT#claimAndRun_shouldResumeAfterLeaseExpiry_whenPreviousAttemptAbandoned` | IT |
| AC-6b | worker interrupted mid-run → job stays RUNNING, batch untouched → reclaim → DONE | `ClubRunJobWorkerIT#claimAndRun_shouldAbandonAndResume_whenWorkerInterrupted` | IT |
| AC-7 | superseded attempt writes **zero** rows (orders, unitloads, job, batch) | `ClubRunJobWorkerIT#execute_shouldWriteNothing_whenAttemptSuperseded` (+ step/finalize/failJob variants `processOrderFenced_shouldRefuseStaleAttempt_whenReclaimedMidRun`, `finalizeClubLine_shouldRefuseStaleAttempt_whenReclaimedBeforeFinalize`, `failJob_shouldRefuseStaleAttempt_whenReclaimed`, F1) | IT |
| AC-8 | fenced validate: refuses 527 without matching lease; accepts the holder's resume; legacy overload unchanged | `CustomerorderBatchServiceUnitTest#validate_fenced_*` | unit |
| AC-9 | BusinessException (stock shortfall) → job FAILED with `lastError` **equal to** the shortfall message; batch back to original | `ClubRunJobWorkerIT#claimAndRun_shouldFailWithShortfallMessageAndRestoreBatch_whenStockShort` | IT |
| AC-9b | invariant `FAILED ⇒ batch ≠ 527` (or no recorded original state → batch untouched, suffix "owned by another run"), incl. `failJob` failure injected (job stays RUNNING) | `ClubRunJobWorkerIT#claimAndRun_shouldNeverLeaveFailedJobOn527_evenWhenFailJobFails` | IT |
| AC-9c | a non-business runtime error (spy throws `IllegalStateException` mid-run) → `failJob` immediately: FAILED, batch restored, `lastError` is the sanitized client-safe text (no raw exception text — Phase 3 S1/S2; full exception at ERROR in the log) — **not** abandoned | `ClubRunJobWorkerIT#claimAndRun_shouldFailNotAbandon_whenRuntimeErrorMidRun` | IT |
| AC-9d | transient error (spy throws `CannotAcquireLockException`) → abandon: job RUNNING with `lastError` = the sanitized abandon text and **not** containing the exception message; batch 527 | `ClubRunJobWorkerIT#claimAndRun_shouldAbandonWithLastError_whenTransientError` | IT |
| AC-9e | `failJob` failing on every attempt → claim with attempt > max+2 → `STUCK`, batch untouched, stuck counter incremented | `ClubRunJobWorkerIT#claimAndRun_shouldEndStuck_whenFailJobKeepsFailing` (+ `claimAndRun_shouldEndStuck_afterFailJobFailsOnEveryAttempt`, F17) | IT |
| AC-10 | legacy GET: DONE body within bound; QUEUED-at-timeout body (no worker free); FAILED body; never 500 | `ClubLineControllerUnitTest#legacyRun_*` | unit |
| AC-11 | two worker threads, one job → one execution (kept as a smoke test; AC-7 is the real two-writer test) | `ClubRunMultiWorkerIT#twoWorkersOneBatch` | IT |
| AC-12 | **regression pin** (passes on pre-change code by design): stale cleanup ignores a batch with a live job | `StaleClubBatchCleanupJobServiceIT#ignoresRunningClub` | IT |
| AC-13 | claim with attempt > 2 → FAILED "abandoned after", batch restored | `ClubRunJobWorkerIT#claimAndRun_shouldFailAbandonedAfterMaxAttempts_whenAttemptExceedsMax` | IT |
| AC-14 | kill switch `'0'`: submit refuses; legacy GET inline; legacy GET refuses a batch with a live job; **a QUEUED job and an expired RUNNING job still run to DONE** | `ClubLineControllerUnitTest#killSwitch_*`, `ClubRunJobWorkerIT#claimAndRun_shouldDrainLiveJobs_whenKillSwitchOff` | unit + IT |
| AC-14b | poller with nothing claimable submits at most `workers − active` tasks per tenant per tick (no spin) | `ClubRunJobPollerJobUnitTest#boundedSubmissionsWhenNothingClaimable` | unit |
| AC-14c | `ClubRunJob` entity maps the V2.2.47 table (read after native insert succeeds; no 42703) | covered by AC-2/AC-3 on Testcontainers | IT |
| AC-15 | job runs against the submitting tenant | `ClubRunExecutorConfigTest#decoratorPropagatesTenant` | unit |
| AC-15b | executor rejection after commit → no exception to the caller, a real rejection never throws (the executor's discard handler counts `kick_rejected` — pinned by `ClubRunExecutorConfigTest#rejectionDiscardsAndCounts`); any exception escaping `execute` in the after-commit kick is swallowed and counted `kick_failed` at ERROR (Phase 3 re-review N4/R3); the later pickup is AC-14b's | `ClubRunJobServiceUnitTest#kickThrowingAfterCommitIsHarmless` | unit |
| P2 AC-16 | submit + poll at 2 s with backoff; progress `processed/total` | Jest `clubRuns.spec.js` | Jest |
| P2 AC-17 | reload mid-run resumes polling from `byBatch` | Jest | Jest |
| P2 AC-18 | FAILED shows `lastError`, re-enables Run Club | Jest | Jest |
| P2 AC-19 | cypress D.1 rewritten (no "call twice", no mobile claim) | cypress | e2e |
| ~~P3 AC-20~~ (dropped, §11) | after finalize: one `dispatchBatch(LANE_CLUB)` when the lock is free; none when busy; lock always released | `OutboxLaneKickerUnitTest` | unit |

Existing `ClubLineRetryIntegrationTest`, `CustomerorderBatchServiceUnitTest`, `ClubLineOrderProcessorUnitTest` stay green unchanged.
PIT scoped to `ClubRunJobService`, `ClubRunJobWorker`, `ClubRunStepService`, `ClubRunJobClaimService` per the floor.

### Manual Test Plan

Each scenario uses **its own batch**, takes a `wms-dev-probe` `snapshot.sh` before and proves restore after (runs move stock and set 530).
Precondition for every row: batch state 520/525, `staginglane_id IS NOT NULL`, no order with `parcel_id`, and the club SKU overview
(`/clubLine/skus`) shows on-lane ≥ required for every SKU.

| Scenario | Precondition query → dev count (2026-11-04) | Batch | Steps | Expected | P/F |
|---|---|---|---|---|---|
| M1 run via UI (after P2) | `select count(*) from customerorder_batch b where type='CLUB' and state in (520,525) and staginglane_id is not null and not exists (select 1 from customerorder o where o.orderbatch_id=b.id and o.parcel_id is not null)` → **9** | `41078-8` (5 orders) | Run Club | QUEUED→RUNNING→DONE; progress to 5/5; batch 530 | |
| M2 legacy GET | same → 9 | `41479-2` (7) | `wms-dev-probe` `GET /clubLine/runClubLine/41479-2` | 200 `"RUN CLUBLINE"` | |
| M3 double submit | same → 9 | `40875-1` (1) | two `POST /clubRunJobs/40875-1` in parallel | one jobId | |
| M4 kill mid-run → resume | runnable batch with ≥ 200 orders → **0** | seeded via `wms-dev-probe` (out-of-band ids) | kill the pod while RUNNING | job resumes ≤ 5 min on another replica; batch 530; unitloads = orders | |
| M5 kill switch | same → 9 | `41428-1` (1) | set `WMS_CLUBLINE_ASYNC='0'`, legacy GET, restore `'1'` | inline run as today; submit refused while `'0'` | |
| M6 OMS side (P3) | — | M1's batch | `outbox_message where lane='CLUB'` | rows SENT within seconds | |

M4 is **dev-infeasible without seeding** — the only large club (`CLUB-20260910-004`, 1,200 orders) is already 530.

---

## 7b. Horizontal Scalability Validation

| # | Concern | Verdict | Evidence / mitigation |
|---|---|---|---|
| 1 | In-JVM state | No | job state in `club_run_job`; executor holds no queue (direct hand-off), poller is the fallback |
| 2 | Pool math | Yes | worker holds ≤ 1 tenant connection (sequential short txs); ≤ `workers` (2) per replica across all tenants; bounded wait holds none |
| 3 | Scheduled jobs | Yes | poller on every replica, SKIP LOCKED claim (no advisory lock, §3.5); P3 uses the existing lane lock, one batch |
| 4 | Long transactions | No | per-order txs as today; no tx spans HTTP; lease 300 s ≫ longest tx |
| 5 | Request affinity | No | status from DB; any replica answers |
| 6 | Retry / idempotency | Yes | resume via parcel_id + package reuse; `attempt` fence; ON CONFLICT submit |
| 7 | Tenant context | Yes | `TenantAwareTaskDecorator`; poller sets/clears per tenant (AC-15) |
| 8 | Distributed lock correctness | Yes | job-row fence in the four worker txs (§3.3); `findByIdForUpdate` stays inside `@Transactional(tenantTransactionManager)` |
| 9 | Cache invalidation | N/A | no cached entity written |
| 10 | External notifications | No | outbox unchanged; P3 dispatch outside any tx |

### v2 constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | Yes — worker non-tx; each step its own tx; status uses a projection |
| 2 | Tenant TM | Yes — every new `@Transactional` names `tenantTransactionManager` **and** `rollbackFor = {BusinessException, FacadeException}` |
| 3 | readOnly reads | Yes — status / byBatch |
| 4 | Caffeine | N/A |
| 5 | Micrometer | Yes — §5.1 row 8 |
| 6 | Jakarta | Yes |
| 7 | H2 SQL | Yes — claim/fence/ON CONFLICT on Testcontainers only |
| 8 | Controller tests | Yes — `ClubLineControllerUnitTest` extended |

---

## 8. Rollout Plan

P1 PR → `develop` (wms2-api) → on dev → M2, M3, M5 → P2 PR → `develop` (web-ui) → M1 → P3 → M6 → M4 (seeded). P1 and P2 are promoted
in the **same release** (§5.1 row 4). Per-tenant rollback: `WMS_CLUBLINE_ASYNC='0'` — stops **new** jobs only; live jobs still drain through
the worker, so if the worker code itself is faulty the only full stop is a code revert (C-L1). Code rollback: revert; the table is additive and inert.
Release/main promotion is DevOps (merge only to develop).

---

## 9. Alternatives Considered

| Option | Why rejected |
|---|---|
| **0 — Architect's steelman:** async on a `TenantAwareTaskDecorator` executor running today's `runClubLine` unchanged; a `club_run_heartbeat_at` column stamped per order tx; an advisory-locked reaper that sends stale-heartbeat 527 batches through `rollbackClubLineState`; operator re-clicks and the run resumes idempotently (§2.2). Fewer surfaces, keeps a human after an OOM | Rejected on **D3** (Nam chose auto-resume) and on visibility: no job row means no cross-replica status for submit-and-poll (the UI would poll batch state only, with no progress, no `lastError` for an async failure), and the reaper re-introduces "is it slow or dead?" judged by a heartbeat — the same lease, without fencing. **Kept as the fallback** if Nam reverses D3: it reuses this plan's executor and V2.2.47 with the claim/fence removed. The OOM-amplification point it raises is answered by max-attempts 2 + alert (§3.4). |
| `app.cron` job runs queued clubs | 3310 §4: no horizontal scaling |
| Session advisory lock held for the run | 3310 §4: pins a landlord connection; proves nothing about progress |
| 527 as the lock + time-based stuck-527 sweeper | cannot tell slow from dead without a heartbeat; that heartbeat is the lease |
| Per-order progress table | duplicates `customerorder.parcel_id`, which already commits with the order and drives resume |
| Persist the Phase-1 snapshot | stale after a crash; re-validate is already correct (§2.2) |
| `@Async` without a job row | lost on crash; no status across replicas |
| Remove the legacy GET | breaks cypress and un-upgraded clients |

---

## 10. Open Questions / Resolved Decisions

| # | Item | Resolution |
|---|---|---|
| D1–D4 | phasing, legacy GET, recovery, side items | Nam 2026-11-04 — [resolved-decisions.md](SBDEV-4007-evidence/resolved-decisions.md) |
| Q1 | (a) ticket item 2 "add no new lock" → no batch lock, job-row fence is the liveness authority; (b) D1's "per-order progress" met by deriving from `customerorder.parcel_id`, no progress table | **resolved — Nam accepted both, 2026-11-04** |
| Q2 | R-3 resume stock check | resolved (§2.2) |
| Q3 | R-6 kick ordering | resolved — lane lock, one batch (§3.7); claim gate as backstop (§2.3) |
| Q4 | `sync-wait-seconds` final value | 45 default; finalised after §5.1 row 6 |
| Q5 | Is 1,000+ a recurring volume? | open — does not change the design |
| Q6 | prd duplicate unique index on `unitload.labelid` | out of scope; noted |
| Q7 | SBDEV-3328 API half (500 on null orderBatchId; lane claim, not re-verified) | out of scope; belongs on 3328 |
| Q8 | Auto-resume vs Alternative 0 (Architect tension: auto-resume removes the operator's judgment after an OOM) | **resolved — Nam kept auto-resume (D3), 2026-11-04**; max-attempts 2 + alert; Alternative 0 stays the documented fallback |

### Layer-2 completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | Callsites | ✓ §0 (18 rows) — each covered in §3/§4 or excluded |
| 2 | Adjacent shapes | ✓ outbox claim pattern reused (§3.3); stale cleanup pinned (AC-12) |
| 3 | Back-compat | ✓ §6 incl. "What does NOT change"; legacy-GET contract change stated (§3.6) |
| 4 | Concurrency | ✓ §3.3, AC-2/6/6b/7/11 |
| 5 | Multi-tenant | ✓ §3.5, AC-15; global lane lock bounded (§3.7) |
| 6 | Error handling | ✓ §3.4 classification table; error shape unchanged |
| 7 | DB verified | ✓ §2.4, analysis §F |
| 7b | Observability | ✓ §5.1 row 8 |
| 8 | Rollout / migration | ✓ V2.2.47 additive, kill switch, same-release P1+P2 |
| 9 | Test coverage | ✓ §7 AC→test map, skeleton strategy, manual plan with restore |
| 10 | v1↔v2 | no — v1 is reference-only (no client on v1 since 2026-10-02) |
| 11 | Alternatives | ✓ §9, 8 options incl. the Architect's steelman |

### 9.1 Acceptance script

None. Every API acceptance criterion is a JUnit / Testcontainers test and every UI one a Jest or cypress test (§7); no cross-file invariant needs a grep row.

### ADR

- **Decision:** a DB-backed `club_run_job` claimed with `FOR UPDATE SKIP LOCKED` on the executor thread, fenced by an `attempt` token renewed
  as the first statement of the four worker transactions, terminal failure in one non-swallowing transaction, infra/shutdown errors abandoning
  the lease for auto-resume, a claim-based poller on every replica, and a per-tenant kill switch.
- **Drivers:** survive pod death and rolling deploys mid-run (data integrity); scale horizontally; reuse the existing resume semantics.
- **Alternatives:** §9 (incl. the Architect's heartbeat-reaper design, kept as fallback).
- **Why chosen:** the only option that makes liveness observable across replicas without pinning a connection, and gives the UI real progress and errors.
- **Consequences:** new table + poller; legacy GET becomes submit-and-wait (bounded); P1 and P2 must ship together; a crashed run self-heals within one lease (≤ 5 min), at most twice.
- **Follow-ups:** §5.1 rows 2 and 6 (Nam); Q1 ack; Q5; 3328 API half.

## 11. Implementation status

| Phase | State | Branch / PR | Evidence |
|---|---|---|---|
| P1 API | **PR submitted 2026-11-05**: https://github.com/SiteBossInc/wms2-api/pull/622 | `feature/SBDEV-4007-club-run-async`, tip `bf774d0c`, 24 commits on develop `950a13ff` | see below |
| P2 wms2-web-ui submit-and-poll | **PR submitted 2026-11-06**: https://github.com/SiteBossInc/wms2-web-ui/pull/197. **Ship in the same release cut as P1** | `feature/SBDEV-4007-club-run-async`, tip `2b4c8f4`, 19 commits on develop `8eb11fe` (develop has since moved to `734deac`, which merges clean with no overlapping files) | see below |
| P3 outbox kick | **Dropped 2026-11-06 (Nam)**. A PRD measurement showed it saves at most one 3 s tick; see "P3 decision" below | — | `wsl-wineco-prd` `outbox_message` queries, 2026-11-06 |

P1 evidence:
- **Full CI check:** `mvn clean verify -Pci` on `e7cf64b5` gave surefire 9735/0/0/1 skipped and failsafe 1219/0/0/23 skipped. `d70beaaf` (+1 assertion) gave ClubRunJobWorkerIT 20/0/0; PR CI `test` passed on it. `bf774d0c` changes only one `@DisplayName`. Phase 4 docs review (after the push, at Nam's question): `SBDEV-4007-evidence/phase4-docs-review.md`. Develop CI at 950a13ff is green.
- **Reviews:** all saved in `SBDEV-4007-evidence/`: `phase3a-conformance-verifier.md`, `phase3b-code-review.md`, `phase3b-security-review.md`, `phase3-fix-list.md` (F1–F18) and `phase3-rereview.md` (N1–N7, R1–R7, P1–P3, rounds 2–4).
- **Sanctioned assertion changes:** AC-9c and AC-9d (sanitized text), AC-15b (`kick_failed`), poller test times(2) → times(1) (F4), and the NeverMatcher inventory entry 2 → 4.
- **F15 (idle backoff): tried, then removed.** S7 accepted: pools never idle-evict because of OutboxDispatcherJob.
- **Order-assumption flake fixed in ITs (`e7cf64b5`):** the worker's order processing order is unspecified (`findByOrderbatchId` has no ORDER BY). Tests identify orders through the step spy.
- **Docs, all with `✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06)` markers:** `wms2-club-run-workflow.md` §7/§8A/§9.9, `wms2-scheduled-jobs-catalog.md` §3.2/§4.9, `wms2-rest-api-reference.md` §9, `wms2-sysprop-catalog.md` §11, and `wms2-function-to-docs-map.md` §9.
- **Filed as SBDEV-4071 (on dev, fix `142c21a5`):** `BusinessException(String, Throwable)` left the message null. Our path is guarded by R7 regardless.
- **§5.1 prerequisites still open for Nam:** ingress timeout. (`WMS_CLUBLINE_OMS_CHUNK_SIZE` was closed 2026-11-05: rollout dropped, stays 1; see §5.1 row 2.)

P2 evidence:
- **Gate and implementation:** the gate (`0df9f5a`, 32 red) and Nam's amendments A1–A4 are in `SBDEV-4007-evidence/p2-tdd-gate.md`. The implementation, the hand-run mutation tables and the counts are in `p2-implementation.md`.
- **Jest:** 2875/2875, 153 suites, re-run by the lead at `3e11d3b` and `2b4c8f4`. Develop's baseline is 2783. ESLint shows no new findings against develop.
- **Prettier:** the three new specs are formatted in `2b4c8f4`, which is byte-identical to prettier's output on the reviewed versions. The modified files were already prettier-unclean on develop.
- **Reviews:** all in `p2-code-review.md`. The initial review was REQUEST_CHANGES (#1–#13). Re-review rounds 1–3 were each APPROVE (M1, L1–L4, N1). That makes 19 findings, all resolved; L3 was accepted with a rationale.
- **Nam's decision on #5:** with the kill switch `'0'`, the UI falls back to the legacy GET when it sees P1's `KILL_SWITCH_MESSAGE` refusal.
- **Sanctioned test-shape changes:** gate #10 now advances in 2 s ticks, and the `d1a56ff` test was rewritten because the issue-order guard it covered became dead code under the in-flight skip. Four "completed at submit" tests now expect the toast on DONE.
- **Not run:** Cypress D.1. It was rewritten for submit + poll and assumes `WMS_CLUBLINE_ASYNC='1'`.
- **Docs:** `wms2-club-run-workflow.md` §8A.9, the line-372 note and §9 item 11; plus pointers in `wms2-function-to-docs-map.md` and `wms2-rest-api-reference.md` §9. All carry `✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06)`. They were reviewed twice and the findings fixed.

P3 decision (2026-11-06, Nam: "Drop P3, record why"):
- **What was measured:** `wsl-wineco-prd` `outbox_message`, `lane='CLUB'`, `status='SENT'`, last 30 days. 422 rows: average 23.6 s from `created_at` to `sent_at`, max 86.5 s, 401 of them over 3 s.
- **The one real club-run burst** (2026-10-30 23:36 UTC, 357 rows, chunk size 1): the first row went out after 2.2 s and the burst drained in 48.5 s. The lane sends one row at a time, about 135 ms per row.
- **Why the kick doesn't help:** §3.7's kick runs one `dispatchBatch` after finalize, so it can save at most one 3 s tick, about 2 s of a ~48 s drain.
- **The worst delays are not club runs:** they are `BILL_OF_LADING_CHUNK` / `ORDER_BATCH_SHIPPED` rows (for example 2026-11-03 02:22 UTC: 12 rows, each sent about 7 s after the previous one, so each OMS call takes about 7 s). The kick cannot help those either.
- **Ticket line not met:** the ticket's scope item 7 ("start the outbox dispatch when a workflow finishes") is not done, by decision. The lane's throughput is limited by sequential HTTP to the OMS, not by when dispatch starts.
- **Follow-up:** CLUB-lane send throughput, i.e. why a BOL-chunk send takes about 7 s, is **SBDEV-4073** (filed elsewhere 2026-11-08: 40-parcel chunks sit under the OMS async threshold of 50, so each runs synchronously). The `BusinessException(String, Throwable)` null-message bug is **SBDEV-4071** (on dev).

Merge to develop (2026-11-06, wms-merge):
- **wms2-api #622:**
  - Two develop merges into the branch. The first, `5c96f338`, went stale when develop moved. The second, `5e326cd0`, merged `3a5db40f`. Neither had a textual conflict. Develop's overlapping files were `CustomerorderBatchService`, the two arch tests and the collision script.
  - Local overlap tests: 232/0, then 262/0. The collision check was clear.
  - PR CI `test` passed on `5e326cd0` (run 42203469198).
  - Merged with `merge-one.sh`, pinned to that head, as merge commit `57147d50`.
  - `post-merge-verify`: ALL PROVEN. Develop CI 42206425391 passed test and build. Dev serves `develop-57147d50`.
  - Dev DB: V2.2.47 is applied (it ran out of order, below V2.2.48). `WMS_CLUBLINE_ASYNC='1'`, and `club_run_job` is empty.
- **wms2-web-ui #197:**
  - Develop `734deac5` was merged into the branch as `cde6a7d`, with no conflict.
  - Full jest on that merge: 2923/2923, 156 suites.
  - Merged with `merge-one.sh --no-pr-check` (graded base `734deac5`) as merge commit `9d9d3845`.
  - `post-merge-verify --wait-run`: ALL PROVEN, Docker Image CI 42209338881.
  - Deploy checked by hand: dev's served entry bundle (last-modified 11:21:51Z) contains the P2-only strings `clubRunJobs/byBatch` and `Async club run is disabled for this warehouse`. Run 42209338881 was the last develop build, so the tag race did not apply.
- **Doc markers:** 25 standard markers flipped to `✓ merged`, plus one variant in the function map flipped by hand. Zero `⏳ pending-merge(SBDEV-4007` markers remain.


Manual dev test (2026-11-06):
- **Passed:** M2 (failure variant), M3 and M5, plus the M5 restore control.
- **Not run (dev-infeasible):** M1 and M4. No club batch on dev has enough stock on its lane, and Nam declined moving stock, which cannot be undone.
- **Restore:** proven with 4 snapshots. 0 outbox and 0 stockrecord side effects.
- **Evidence:** `SBDEV-4007-evidence/manual-dev-test.md`.

Status re-check (2026-11-07):
- **Deploy:** DEV serves `develop-2fac7d4b`, which contains `57147d50`. The web-ui merge `9d9d3845` is on develop.
- **PRD:** V2.2.47 is not applied on c1wh-shipitez-prd, nywh-shipitez-prd or nywh-hydra-prd (all at 2.2.45). WSL PRD and the UAT DBs were unreachable. **#622 and #197 must ship in the same release cut.**
- **M1 and M4 are deferred to UAT.** On dev they would need stock moved onto a lane, which can't be undone and which Nam declined on 2026-11-06. Run them on UAT after the release cut, before PRD.
- **Still open for Nam:** §5.1 ingress read timeout (dev/UAT/PRD). `WMS_CLUBLINE_OMS_CHUNK_SIZE` is **not** open: the rollout was dropped on 2026-11-05 (SBDEV-3310). Re-checked 2026-11-07: `1` on dev, c1wh, nywh-shipitez and nywh-hydra PRD. Two proposals are unfiled, now in the proposals register as **P77** (`BusinessException(String, Throwable)` null message, T1) and **P78** (BOL-shipped chunks hold the CLUB lane ~8 s each, T2, investigate the OMS handler first).

- UI check in a headless browser (2026-11-09): U1 (async submit → queued → polled → FAILED shown inline and as a toast, and resumed after a reload) and U2 (switch off → legacy GET fallback) pass. The Run Club gate was opened by rewriting the browser's copy of the stock response; restore proven with 4 snapshots, and 0 outbox/stockrecord rows. Evidence: same file, section "UI check in a headless browser".
