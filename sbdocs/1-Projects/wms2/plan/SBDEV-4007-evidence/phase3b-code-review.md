# SBDEV-4007 P1 — Phase 3b code review (transcribed by lead; lane cannot write files)

- **Reviewed:** `git diff 68a20d76..311e93e9`, 34 files, every main-source file read in full.
- **Lane:** oh-my-claudecode:code-reviewer, 2026-11-04.
- **Method:** shutdown and commit claims were checked against the spring-context 6.2.15 and spring-orm sources in ~/.m2. No tests were run.

**Verdict: APPROVE.** 3 Med, 10 Low.
- **Fencing:** no unfenced write. Every write follows an attempt-fenced `renewLease` in the same tx; `abandon` and `markStuck` are fenced too.
- **Transaction annotations:** all compliant. `failJob` is atomic.
- **Accepted trade-off:** two quick transient faults use up `max-attempts=2` (plan C-L2). Add a line to the workflow doc.

| # | Sev | Site | Defect / scenario | Fix |
|---|---|---|---|---|
| 1 | Med | `ClubRunJobWorkerIT` AC-7 `worker.execute(stale)` | The only stale-attempt test loses the lease at validate. Deleting the fence in `processOrderFenced`, fenced `finalizeClubLine` (`renewLease` / `markDone==0`) or `failJob` (`renewLease` / `markFailed==0`) stays green. | AC-7 variants (a) step, (b) finalize, (c) failJob; mutation-check each |
| 2 | Med | `ClubRunJobService.failJob` `LOG.warn("... no original_batch_state; batch left as is")` | FAILED with the batch at 527 contradicts AC-9b. The branch is untested. Reachable only via the kill-switch race (legacy GET `hasLiveJob` then inline `runClubLine`, with no lock between them). The job itself cannot strand a batch, because validate writes the original state and the 527 in one tx. | Unit test for the null-original branch; restate AC-9b; distinct `last_error` suffix "batch at 527 owned by another run" |
| 3 | Med | `ClubRunJobPollerJob` `int free = Math.max(0, workers - clubRunExecutor.getActiveCount());` | Recomputed per tenant, so tenants 2..N over-offer. The discard handler fires on nearly every tick with ≥2 tenants, so `kick_rejected` is noise. The unit test pins this by mocking a constant active count. | Compute `free` once per tick and spend it across tenants; separate `poller_discarded` counter |
| 4 | Low | `ClubRunJobWorker.execute` `e instanceof TransientDataAccessException \|\| …` | Checks the top-level type only. Reachable via `JpaTransactionManager.doCommit` → `TransactionSystemException("Could not commit JPA transaction")`. The result is FAILED where it should be abandon; low harm because failJob is fenced and a resubmit resumes. | Walk the cause chain; treat a TSE whose root SQLException has SQLState 08* as transient |
| 5 | Low | same catch: `\|\| e instanceof InterruptedException` | Dead code: nothing declares it | Remove |
| 6 | Low | `ClubRunJobService.kick()` `catch (RuntimeException e) { … METRIC_KICK_REJECTED …; LOG.warn` | The discard handler never throws, so real rejections never reach this catch. Decorator or init bugs get counted as "rejected" at WARN, and the poller masks them. | `TaskRejectedException` → rejected; everything else → ERROR with stack trace + `kick_failed` |
| 7 | Low | worker `abandon(lease, "abandoned: JVM shutting down …", false)` | A clean shutdown keeps the lease for up to 300 s, so a rolling deploy idles the run for 5 min. Each shutdown also uses one attempt. | `expireNow=true` when the shutdown flag is set; document that deploys consume attempts |
| 8 | Low | `ClubRunShutdownGuard` javadoc | Ordering is correct, reason is wrong. Spring 6.2.15 with waitForTasks=false: (1) on ContextClosedEvent, `initiateShutdown()` calls `shutdown()`, which does not interrupt; (2) lifecycle stop runs the guard at phase MAX_VALUE before the executor at DEFAULT_PHASE; (3) only `destroy()` calls `shutdownNow()`, which interrupts | Rewrite the javadoc with those three steps |
| 9 | Low | `ClubLineController.runClubLine` `"RUN CLUBLINE QUEUED"` | A RUNNING job at timeout is reported as QUEUED. There is no `errors` key, so the pre-P2 UI shows success for an unfinished run. HTTP stays 200 (legacy contract). | Derive the message from the state; timeout-while-RUNNING test; ship P1 and P2 in the same cut |
| 10 | Low | `ClubRunJobItSupport` + `claimNext ORDER BY id LIMIT 1` | Uses the reused container. A stray QUEUED/RUNNING row from an aborted run gets claimed instead of the test's own job. | `@BeforeEach` clears or asserts there are no live rows |
| 11 | Low | `ClubRunJobItSupport.dropFixture` (one try around every DELETE) | Coverage is complete, but the first failing DELETE skips the rest and leaks master data | Wrap each DELETE on its own; collect the failures and throw at the end |
| 12 | Low | `ClubRunMultiWorkerIT` AC-11 | Passes without SKIP LOCKED | Hold the row lock in a 2nd tx; `claimNext()` must return empty immediately |
| 13 | Low | `ClubRunJobService.awaitTerminal` `current = status(jobId);` | Self-invocation bypasses `@Transactional(readOnly)`; the javadoc is inaccurate | Fix the javadoc or call through the proxy |
