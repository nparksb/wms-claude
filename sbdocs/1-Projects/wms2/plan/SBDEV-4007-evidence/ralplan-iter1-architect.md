# SBDEV-4007 ralplan iteration 1 — Architect review (transcribed by lead from the lane's reply; lane cannot write files)

Verdict: core fence (SKIP LOCKED claim + fence UPDATE first in every worker tx) is sound; lock ordering acyclic. Defects are in the surrounding paths.

| # | Sev | Finding | Fix |
|---|---|---|---|
| H1 | High | §3.2 step 4: unique-violation "re-read the winner" inside the same tx is impossible in Postgres (tx aborted; Spring marks rollback-only) | `INSERT … ON CONFLICT (orderbatch_id) WHERE state IN ('QUEUED','RUNNING') DO NOTHING RETURNING id`, then re-select |
| H2 | High | FAILED write and batch restore specified as two fenced steps; `rollbackClubLineState` swallows (`catch (Exception e) { LOG.error("Failed to rollback batch {} state: {}"`) and uses `findById`. If FAILED commits first, the restore's fence (`state='RUNNING'`) matches 0 rows → batch at 527 with no live job forever (re-creates the bug) | single `failJob(lease, err)` tx: renewLease → `findByIdForUpdate` → restore from job.original_batch_state if 527 → FAILED; no swallowing; poison guard uses it too |
| M1 | Med | `setWaitForTasksToCompleteOnShutdown(false)` → `shutdownNow()` interrupts → lands in "any other Exception → FAILED + restore"; a rolling deploy fails runs instead of resuming | FAILED only for `BusinessException`/`FacadeException`; `TransactionException`, `DataAccessResourceFailureException`, `CannotAcquireLockException`, interrupts / executor shutting down → abandon, let lease expire |
| M2 | Med | `now()` = tx start; a validate/finalize tx > lease commits with an expired lease → gap before next fence lets a poller reclaim (safe but burns an attempt; 3× trips poison guard on a healthy run). Finalize at chunk size 1 (prd) is the slow tx to measure | safety does not depend on lease length (row lock does) → lease 300 s; optionally re-renew in `beforeCommit`; count only crash-driven reclaims toward max-attempts |
| M3 | Med | P3 kick: `OutboxDispatcherJob` takes the lock BEFORE the tenant loop (`if (!advisoryLockService.tryLock(lockId))` at :103, loop :136) — the key is global, so a kick for tenant A skips every tenant's CLUB tick for up to 5 × dispatchBatch (each bounded by 15 s OMS read timeout) | cap kick at 1 iteration, or document cross-tenant delay |
| M4 | Med | Auto-resume amplifies run-induced OOM: each reclaim reproduces it on another replica; up to 3 pods die (with their in-flight requests) before the poison guard | max-attempts 2; record lease_owner per attempt; alert on attempt ≥ 2 |
| L1 | Low | `ClubRunLeaseLostException` must be unchecked — checked + `rollbackFor={Business,Facade}` would COMMIT after a failed fence | make it RuntimeException |
| L2 | Low | Old UI + new API: legacy timeout body `RUN CLUBLINE QUEUED` fails `results.message !== 'RUN CLUBLINE'` (clubRuns.js:460) → "Unrecognized club run response" → reconcileRunStatus → 527; recovers, but via the error branch | document; or keep the timeout body's `message` = `RUN CLUBLINE` with extra fields |
| L3 | Low | Kill switch '0': does the poller still claim QUEUED/RUNNING jobs? Inline path under '0' keeps the stranded-527 gap | document both |
| L4 | Low | `@Version` entity + native `version = version + 1` renews ⇒ OptimisticLock failures on any entity save | write all job state with native UPDATEs (or drop @Version) |
| L5 | Low | Executor default rejection throws `TaskRejectedException` from `afterCommit` → committed submit returns 500 | explicit DiscardPolicy + counter |

**Antithesis (steelman):** prd has never had a stranded 527; runs ~60 s, a few/day. Five new failure surfaces for a latent bug. Smaller design: async on a `TenantAwareTaskDecorator` executor with today's `runClubLine`, a `club_run_heartbeat_at` stamped per order tx, an advisory-locked reaper that rolls stale-heartbeat 527 batches back via `rollbackClubLineState`; operator re-clicks and the run resumes idempotently (§2.2). No auto-resume, human judgment after an OOM, M4 vanishes.

**Tensions:** auto-resume vs failure amplification (D3 removes the operator's judgment about *why* the pod died); lease length (short = fast recovery but burns attempts; long = slow recovery — take long, the row lock carries safety); poller-on-every-replica (scaling vs a permanent claim query on every tenant DB every 5 s for a rare event).

**Synthesis (recovered portion):** (1) ON CONFLICT submit; (2) single `failJob` tx; (3) exception split per M1; rest truncated — implied by M2–M4, L1–L5.
