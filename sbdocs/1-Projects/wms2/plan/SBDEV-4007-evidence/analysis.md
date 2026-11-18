# SBDEV-4007 — analysis bundle (async club run)

> Rebuilt in the lead context 2026-11-04 after the opus analysis lane's report was lost (harness refused its file
> write; its reply was truncated; resend stopped by a classifier). Its 9-point summary is folded in below and each
> headline claim was **re-verified** here against `origin/develop` — marked ✔ where re-checked.
> Base: wms2-api `origin/develop 68a20d76` · wms2-web-ui `8eb11fe` · wms2-mobile-ui `ee86b0a`. Code read only via
> `git show` / `git grep`. Resolved scope decisions: [resolved-decisions.md](resolved-decisions.md).

## 0. Headline findings

1. ✔ **The batch row lock does NOT span the run.** `validateClubLine` (`@Transactional(value = "tenantTransactionManager"…)`)
   takes `customerorderBatchRepository.findByIdForUpdate(orderBatchId)`, sets
   `lockedBatch.setState(WmsConstants.State.ORDER_BATCH_CLUB_RUN_IN_PROGRESS)` and commits. Phases 2–3 run with no
   batch lock; what serialises a second run is the *committed* 527, refused by validate's
   `"Cannot run club line on batch in state: "`. `wms2-club-run-workflow.md` §7 row 2 / §9.9 overstate this (doc fix).
2. ✔ **A crashed run strands the batch at 527, with no recovery path.** `rollbackClubLineState` is called only from
   `runClubLine`'s in-JVM `catch (Exception e)` and swallows its own failure (`LOG.error("Failed to rollback batch {} state: {}"`).
   Pod kill / OOM / redeploy mid-run ⇒ batch stays 527: re-run refused (validate), cancel refused
   (`CustomerorderService.clubRunCancellationBlockingState` — `boolean inProgress = state == …CLUB_RUN_IN_PROGRESS`),
   stale cleanup does not match (`findStaleBatchIds` needs every order `>= finishedState`; a mid-run batch has orders
   below it), UI shows running (`itemsTable.vue` `this.clubStateCode === 527`).
   **This disputes ticket §5 item 2 "add no new lock"** — 527 cannot distinguish a live run from an orphan, so the job
   lease must become the liveness authority and resume needs a *fenced* 527→continue path. (Escalation trigger 3; ticket is
   already T3.)
3. ✔ **`processOrder` is idempotent for a sequential re-run after a committed attempt**: `findByLabelidForUpdate(order.getParcelexternalnumber())`
   → reuse when ownership + `packageMatchesPositions` hold (`"reusing existing package unitload={} for order={} (idempotent re-run)"`),
   else `BusinessException("Package contents for order …` / `"Parcel label already in use: "`. It is **not** designed for two
   concurrent workers on the same batch; the DB backstop is the unique index on `unitload.labelid` (prd: `uq_unitload_labelid`
   **and** `uk_s2ujivixnde5dqb2stih8m2vh`, both UNIQUE — a redundant duplicate, Q2). Per-order tx is REQUIRED via the processor
   bean proxy (`@Transactional(value = "tenantTransactionManager", rollbackFor = …)` on `processOrder`).
   Note: today's failure path *already* resumes this way — catch → state back to original → operator re-clicks → validate
   → committed orders reused by label. The async job formalises that, it does not invent it.
4. **Stock snapshot is computed once in Phase 1** (`validation.stockSnapshotMap()`, `itemdataMap`, `positionsByOrderId`). A
   resumed run on a different replica must **re-run validate** (rebuild the snapshot from current DB) rather than persist the
   snapshot — the per-order reuse path makes that safe.
5. **Outbox:** no post-commit dispatch trigger exists. Dispatch starts only from `OutboxDispatcherJob`
   (`runLane(OutboxMessage.LANE_CLUB, AdvisoryLockService.JobLockId.OUTBOX_DISPATCHER_CLUB, false)` → `dispatchService.dispatchBatch(lane)`).
   `dispatchBatch` = Phase 0 `reclaimStaleInFlight` (REQUIRES_NEW) → Phase 1 `claimDueBatch` (`FOR UPDATE SKIP LOCKED`) → POST → mark.
   A second concurrent consumer is safe at the claim level (SKIP LOCKED); ordering across consumers needs checking (R-6).
6. **UI:** web UI already handles 527 and has `reconcileRunStatus` (`store/processes/clubRuns.js` `async reconcileRunStatus(context, batchid)`,
   and `runClubLine` falls back to it: `if (state === 527) {`). ✔ **Mobile UI has no club code** — `git grep -i club` over
   wms2-mobile-ui matches only fontawesome assets (the hits prove the instrument works; blind spot: a club call built from a
   non-"club" string would be missed). The cypress D.1 comment "Mirrors what the Mobile UI does" is therefore false.
7. **SBDEV-3328** (lane-summary agent claim, not re-verified here): UI half fixed on develop; API half (500 on null `orderBatchId`) open.

## A. Current architecture (runClubLine, `CustomerorderBatchService`)

| Phase | Method | Tx | Writes |
|---|---|---|---|
| 1 validate | `validateClubLine` | short tenant tx, `findByIdForUpdate` | batch → 527; refuses unless state ∈ {ACTIVATED, STAGING_LANE_ASSIGNED}; stock check `validateStockOnStagingLane`; loads non-cancelled orders; max-size guard `"exceeds maximum allowed ("` |
| 2 process | loop → `clubLineOrderProcessor.processOrder(...)` | one REQUIRED tx per order (processor proxy) | package unitload per order, stock deductions |
| 3 finalize | `finalizeClubLine` | short tx | `customerorderRepository.updateStateByIds(orderIds, PACKED)`, positions PACKED, batch → `ORDER_BATCH_CLUB_RUN_FINISHED` (530), lane release, outbox enqueue (chunked, `LANE_CLUB`) |
| fail | `rollbackClubLineState` | own tx, swallows | batch 527 → originalState |

`runClubLine` is deliberately non-transactional (`// WARNING: Do NOT add @Transactional to this method.`) and routes phases through `self.*`.
Controller: `ClubLineController` `@GetMapping(path= "/runClubLine/{orderBatchId}"` → `customerorderBatchService.runClubLine(currentOrderBatch)`.

## B. Stale cleanup interaction (SBDEV-3312)

`CustomerorderBatchRepository.findStaleBatchIds`: `cb.state < :finishedState AND EXISTS order AND NOT EXISTS order with state < :finishedState`.
A running/stranded club batch has orders at pre-PACKED states, so it is **not** matched mid-run. Window to check: after
`finalizeClubLine` commits (orders PACKED, batch 530) the job is finished anyway. **Verdict: no conflict with an in-flight job**,
provided the job never leaves orders ≥ finishedState while the batch is < finishedState and the job still intends to write. Pin with a test.

## C. Reusable primitives

| Need | Existing | Where |
|---|---|---|
| SKIP LOCKED claim + stale reclaim | `OutboxMessageRepository.findAndClaimPending`, `reclaimStaleInFlight(cutoff, lane)` | repo/jpa/OutboxMessageRepository.java |
| Tenant-context on executor threads | `TenantAwareTaskDecorator` (javadoc: "Register on any ThreadPoolTaskExecutor") | landlord/config/ |
| Precedent of decorator use | `StockSummaryExportJob` `new TenantAwareTaskDecorator().decorate(() -> {` | schedulejob/ |
| No app-wide async executor | `MessageRepository`: `// No @Async — no async task executor is configured` | repo/jpa/ |
| Per-tenant poller pattern | `OutboxDispatcherJob` → `OutboxDispatchService` | schedulejob/, service/job/ |
| Bounded-executor TODO noted elsewhere | `ReplenishmentMaintenanceTrigger` "a bounded executor with TenantAwareTaskDecorator" | service/ |
| Job metrics | `schedulejob/JobMetrics.java` | |

**Design fit:** (ii) — submit commits a job row; `afterCommit` hands the job id to a bounded, tenant-decorated executor
(fast path); a per-tenant poller claims `QUEUED` or lease-expired jobs with `FOR UPDATE SKIP LOCKED` (fallback + crash
recovery, D3). Poller needs a JobLockId only if it should run once per cluster; with SKIP LOCKED claims it can run on every
replica (that is the horizontal-scaling point). Next free JobLockId per the lane: 100013 (not re-verified).

## D. §0 Affected sites (enumeration — `git grep -P` on origin/develop)

Instrument note: first pass used `git grep -E '\b…'`; macOS git's ERE does not honour `\b` and silently returned zero
callers for `runClubLine(` — caught by the known controller call as positive control. All rows below are from the `-P` rerun.

| # | File + snippet | Construct | In scope? | Phase |
|---|---|---|---|---|
| 1 | `ClubLineController` `@GetMapping(path= "/runClubLine/{orderBatchId}"` | sync entry | yes — delegate to submit + bounded wait (D2) | P1 |
| 2 | `ClubLineController` (new) submit + status endpoints | new | yes | P1 |
| 3 | `CustomerorderBatchService.runClubLine` | orchestrator | yes — becomes the job body; split "run from job" | P1 |
| 4 | `CustomerorderBatchService.validateClubLine` | 527 set, lock | yes — accept 527 **only** when caller holds the job lease (fenced resume) | P1 |
| 5 | `CustomerorderBatchService.rollbackClubLineState` | failure reset | yes — job-aware: on terminal failure only | P1 |
| 6 | `CustomerorderBatchService.finalizeClubLine` | 530 + outbox | yes — mark job DONE in the same tx | P1 |
| 7 | `ClubLineOrderProcessor.processOrder` | per-order tx | yes — record per-order progress in same tx | P1 |
| 8 | `CustomerorderService.clubRunCancellationBlockingState` (527 refuse) | cancel guard | review — keep refusing while lease live; orphan handled by poller resume | P1 |
| 9 | `WmsConstants` `ORDER_BATCH_CLUB_RUN_IN_PROGRESS = 527` + label switch `case ORDER_BATCH_CLUB_RUN_IN_PROGRESS:` | state | no change | — |
| 10 | `StaleClubBatchCleanupJobService` / `findStaleBatchIds` | cleanup | no change; pin non-interference with a test | P1 test |
| 11 | `OutboxDispatchService.dispatchBatch(lane)` / `OutboxDispatcherJob.runLane` | dispatch | yes — post-finalize kick | P3 |
| 12 | `db/migration/V2.2.46__club_run_job.sql` | new table(s) | yes | P1 |
| 13 | web-ui `store/processes/clubRuns.js` `runClubLine` / `reconcileRunStatus` | client | yes — submit + poll | P2 |
| 14 | web-ui `components/processes/clubRuns/itemsTable.vue` (527 check, dispatch) | client | yes — progress display | P2 |
| 15 | web-ui `cypress/e2e/wms/club/club-line-order.cy.js` D.1 | e2e | yes — fix false "mobile" premise; keep GET compat | P2 |
| 16 | tests: `ClubLineRetryIntegrationTest` (10 hits), `CustomerorderBatchServiceUnitTest` (25), `ClubLineControllerUnitTest` (4), `ClubLineOrderProcessorUnitTest` | existing | must stay green; extend | P1 |
| 17 | wms2-mobile-ui | — | no — zero club code | — |
| 18 | `sbdocs/3-Resources/workflows/wms2-club-run-workflow.md` §7/§9.9 | doc | yes — correct lock claim | P1 |

## F. DB evidence

| Q | Env | Query (abridged) | Result |
|---|---|---|---|
| Q1 | dev `dev_wh01_om1` | `los_sysprop` `WMS_CLUBLINE_OMS_CHUNK_SIZE` | `100` DEFAULT, modified 2026-11-03 23:13 UTC |
| Q2 | prd wsl-wineco | same + `pg_indexes` on unitload labelid + outbox lane/status | chunk `1`; labelid UNIQUE ×2 (`uq_unitload_labelid`, `uk_s2ujivixnde5dqb2stih8m2vh`) + 2 non-unique; outbox `DEFAULT:SENT:4962, CLUB:SENT:1229` |
| Q3 | prd | CLUB batches by state | `0:2, 520:1, 525:1, 700:11938, 800:35`; **at 527: 0** |
| Q4 | prd | top CLUB batches 45 d by order count | 328 / 275 / 256 / 121 / 118, all 700 |
| Q5 | dev | CLUB batches by state | `0:13, 520:8, 525:1, 530:22, 700:10770, 800:6`; **at 527: 0** |
| Q6 | dev | runnable (520/525) CLUB batches by live orders | `41479-2` (525, 7 orders), `41078-8` (520, 5), `40875-1` (520, 1). The 1200-order `CLUB-20260910-004` is at 530 (done). **No large runnable batch on dev — a progress/resume manual test needs a seeded batch.** |

## G. Pool math

Job worker holds **one** tenant connection at a time (validate tx → per-order txs → finalize tx; none nested — runClubLine is non-tx).
Plus the per-order progress write rides in the per-order tx (no extra connection). Heartbeat: write the lease renewal inside the
per-order tx (no extra connection) or a REQUIRES_NEW every N orders (briefly 2). Cap concurrency to **1 run per tenant per replica**
(tenant Hikari max 5, per the lane — not re-verified) so a burst of submits cannot starve request threads.

## H. Risks / open design questions (ranked)

| # | Risk | Evidence | Mitigation |
|---|---|---|---|
| R-1 | Orphaned 527 after crash (exists **today**) | §0.2 | lease expiry → poller reclaims → fenced validate accepts 527 for the lease holder |
| R-2 | Two workers same batch after lease expiry while the original is merely slow (GC pause) | lease model | fencing token (job `attempt`/version) checked in each per-order tx and finalize; stale holder's writes fail |
| R-3 | Resume re-validates stock against a DB that already reflects committed orders | `validateStockOnStagingLane` runs on full order list | stock check must exclude orders already done (progress table) or tolerate reused packages — needs a test with a half-done batch |
| R-4 | Max-batch-size guard rejects at validate on resume | `"exceeds maximum allowed ("` | unchanged size ⇒ same verdict; fine, but submit should run the same guard synchronously so the user gets the error at submit, not async |
| R-5 | Sync GET bounded wait (D2) holds a request thread up to the bound | D2 | bound < ingress timeout (≥58 s known); on timeout return 202-like "still running" body the UI's `reconcileRunStatus` already tolerates |
| R-6 | P3 kick: a second dispatcher consumer may reorder per-aggregate notifications | `dispatchBatch` claims in `next_attempt_at, id` order | verify the per-aggregate gate the lane cited; otherwise kick = just trigger the existing lane run under its advisory lock (`tryLock`, skip if busy) |
| R-7 | Duplicate submit (double click / two operators) | — | unique partial index: one non-terminal job per batch; submit returns the existing job id |
| R-8 | Pod shutdown mid-run | — | graceful: stop claiming, let lease expire; no special handling needed beyond R-1 |
| R-9 | Executor saturation drops kicks | bounded queue | poller fallback picks up QUEUED rows; rejected kick is harmless |
| R-10 | Tenant context leak on executor threads | `TenantAwareTaskDecorator` | use it; test that a job runs against the submitting tenant |
| R-11 | Error visibility: async failure has no HTTP response | — | job row stores `last_error`; status endpoint returns it; UI shows it |
| R-12 | Status polling load | UI | poll 2 s with backoff; status read is a PK lookup |
| R-13 | Redundant duplicate unique index on prd unitload.labelid | Q2 | out of scope — note only (sub-T3 hygiene, not this ticket's area) |
| R-14 | Workflow doc wrong on lock span | §0.1 | correct in P1 docs |

## I. Acceptance-criteria candidates

**Phase 1 (API)**
1. `POST /v3/clubLine/runClubLine/{batch}` (submit) returns within 1 s with a job id and state `QUEUED|RUNNING`, having committed a job row; batch validated synchronously for state + size (errors returned at submit).
2. A second submit for a batch with a non-terminal job returns the **same** job id (no second row) — DB-enforced.
3. The job runs to completion: batch → 530, orders PACKED, job → `DONE`, `processed = total`.
4. Status endpoint returns `{state, processed, total, lastError}`; `processed` increases monotonically during a run.
5. Per-order progress row commits **in the same tx** as the order's package (rollback of processOrder leaves no progress row).
6. Kill simulation: a job whose lease expired with k of n orders done is reclaimed by the poller and completes; the k done orders are **not** reprocessed (no new unitloads; package reuse path not even needed) and the batch ends 530.
7. Fencing: a worker holding a superseded lease token cannot commit a per-order write or finalize (throws, no rows).
8. Validate refuses 527 for a non-holder (manual GET while a job is live gets "running" not a second run).
9. Terminal failure (BusinessException, e.g. stock shortfall) → job `FAILED` with `lastError`, batch restored to original state (current behaviour preserved).
10. Legacy `GET /runClubLine/{batch}` still returns the current success body when the run finishes within the bound, and a "still running" response (not 500) when it does not.
11. Multi-replica same-batch IT: two workers/claims against one job ⇒ exactly one runs; no duplicate unitloads (scope §5 item 6).
12. StaleClubBatchCleanup does not touch a batch with a live job (pin).

**Phase 2 (web-ui)**
13. Run Club submits and shows progress `processed/total` until DONE, then the existing finished view.
14. Reload mid-run resumes polling (state derived from the server, not component memory).
15. FAILED shows `lastError` and re-enables Run Club.
16. Cypress D.1 updated: no "call twice" premise; the false mobile-UI claim removed.

**Phase 3 (outbox kick)** — after finalize commits, the CLUB lane drains without waiting for the 3 s tick; no reordering vs cron dispatch (R-6).
