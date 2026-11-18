# SBDEV-4007 P1 — Phase 3 scoped re-review (transcribed by lead; lane cannot write files)

- **Scope:** `git diff 311e93e9..e8bb583f`, 9 fix commits.
- **Lane:** oh-my-claudecode:code-reviewer, 2026-11-05. Read only; no Maven run.

**Verdict: APPROVE.** F1–F14 and F16–F18 are done. F15 is partial.
- **2a ThreadLocal:** clean; it is removed in a finally around the poller submit only.
- **2b backoff map:** a ConcurrentHashMap bounded by the tenants ever seen.
- **2c boolean callers:** fine.
- **2d exception text:** no client path carries it.
- **2e cause chain:** bounded at depth 20; see N3.
- **2f `@MockitoSpyBean`:** resets per test.
- **Spot-checked as mutation-sensitive (by reading):** F1 step, F4 rotation, F15, F14, F11.

| # | Sev | Site | Finding | Lead ruling |
|---|---|---|---|---|
| N1 | Med | poller backoff 60 s vs `wms.tenant.pool.idle-ms=900000` | The backoff does not enable pool eviction (S7 unsolved) | **Remove F15.** Eviction is moot: OutboxDispatcherJob (*/3, two crons) touches every tenant pool every 3 s. Accept S7 with that rationale |
| N2 | Low | `ClubRunShutdownGuard` "resumes on the next poller tick" | Replica B's backoff delays the resume of a shutdown-abandoned job by up to 60 s, which is the rolling-deploy case | Resolved by removing F15 |
| N3 | Low | `ClubRunJobWorker.execute` runs `isTransient(e)` before the Business/Facade check | A BusinessException wrapping a transient error is abandoned, not failed. No producer exists today | **Fix:** Business/Facade first; test plus mutation |
| N4 | Low | `ClubRunJobService.kick` `catch (RejectedExecutionException)` | Dead in production: the rejection handler counts and does not throw | **Drop the arm**, comment that the handler is the live path, keep `kick_failed` |
| N5 | Low | `ClubRunJobItSupport` `@BeforeEach` DELETE of QUEUED/RUNNING jobs over the whole table | Concurrent runs on a reused container would wipe each other's jobs | **Comment only.** Leftover rows cannot be scoped to batch ids, and runs use `TESTCONTAINERS_REUSE_ENABLE=false` |
| N6 | Low | poller `jobMetrics.tenantSuccess` inside the per-task loop | Counted per task; skipped tenants look silent | **Fix:** once per tenant visited (the backoff is gone, so no skip counter is needed) |
| N7 | Low | `ABANDON_FAILJOB_FAILED` | The original failure appears only in the logs | Docs: STUCK runbook says grep `job=<id>` |

## Round 2: `aafc447e..d01a7825` (R1–R7, after the rebase onto develop 950a13ff). **APPROVE**

All seven fixes were done as ruled:
- R1: no leftovers.
- R3: the real `kick_rejected` path is still pinned by `ClubRunExecutorConfigTest#rejectionDiscardsAndCounts`.
- No assertion was weakened beyond the sanctioned AC-15b change and the F6 deletion.

New Lows, all fixed in `f4b05056`:
- P1: failure was emitted per task but success per tenant. Now symmetric.
- P2: the outcome key was tenant-only. Now `tenant/facility`; the metric tag is still the tenant.
- P3: the R4 comment over-claimed that container reuse is off. Reworded.

## Round 3: `d01a7825..f4b05056`. **APPROVE**, no findings

Both new tests bite: the old code makes `isZero()` fail, and makes success read 0 instead of 1.0. Tags are unchanged.

## Round 5: `e7cf64b5..d70beaaf` (after the push). **APPROVE**, no findings

Closes L1 exactly: one added `isNotNull()` precondition on `getParcelexternalnumber()`; nothing removed or loosened. Reviewed after the push, because the push checkpoint had missed it.
