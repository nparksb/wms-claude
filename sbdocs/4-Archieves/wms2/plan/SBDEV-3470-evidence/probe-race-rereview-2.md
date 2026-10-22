---
ticket: SBDEV-3470
pr: SiteBossInc/wms2-api#406
commit: 1a14be6650bc12078474407c6dc139f53fda7898
parent: 7a71fba8 (reviewed in probe-race-rereview.md)
reviewer: independent code-reviewer lane (read-only; no Maven test run / no shared container)
date: 2026-09-23
subject: second re-review, the fix round for probe-race-rereview.md R-1..R-7
---

# Re-review 2: SBDEV-3470, `1a14be66`

Scope: `git show 1a14be66` in `.claude/worktrees/wms2-api/SBDEV-3470`. The commit touches 4 files (+36/-25), all under `src/test`: `BlockedBackendReads.java` and the three `*LockOrderProbeIT` classes.

Method: I read the full diff, the full `BlockedBackendReads.java`, Palletize's `probe()`, `awaitBlockedBackend()` and `workerOutcome()`, Mobile's `awaitBlockedBackend` javadoc, and the entry points plus catch/retry sites of `BillofladingService.closeBOL`, `MobilePalletizeWriteService.scanPallet`, `MobileTruckLoadingService.scanGate` and `MobileTruckLoadingWriteService.scanGate`. `mvn -o -q test-compile` exits 0 with no output. I ran no tests.

## 1. Are R-1 to R-7 resolved?

| # | Verdict | Evidence |
|---|---|---|
| R-1 | **Resolved, but the replacement text overclaims** (see M-1) | "Check the worker's outcome" is gone. Palletize now throws `LEFT_WAIT_BEFORE_CONFIRMED + " " + workerOutcome(worker)`. Mobile and Closebol still don't surface the worker's `Throwable` on this path. That is acceptable, because their text no longer tells the reader to look for it. |
| R-2 | Resolved | The text now reads "in a much narrower window, the gap between the status copy and the per-row `pg_blocking_pids()` call inside one statement (not measured)". |
| R-3 | Resolved | The text now reads "The remaining gap runs from the first read's `pg_blocking_pids()` to this read's, including a client round trip". That is the correct window. |
| R-4 | Resolved | One `public static final String LEFT_WAIT_BEFORE_CONFIRMED`, referenced from all three probes. The log block is still copied three times, which the original review said was acceptable. |
| R-5 | Resolved | The quoted poll now includes `datname = current_database() and`. It matches all three real polls. |
| R-6 | Left, and disclosed | The commit message says: "R-6 (a paraphrase quoted as verbatim in 7a71fba8's message) is left, to avoid rewriting a pushed commit." |
| R-7 | Resolved | `"... read for pid={}: " + "was [{}], now [{}]"` has 3 placeholders and 3 arguments in all three probes: `blockedPid` / `blockedPids.get(0)`, `blockedStatement`, `confirmed`. |

## 2. Is behaviour unchanged apart from message and log text?

Yes. The only non-text change is the extra `workerOutcome(worker)` call on Palletize's `sawBlockedButUnconfirmed` path. I read its body (`PalletizeLockOrderProbeIT.java:494-507`):

- `if (worker == null || !worker.isDone()) return " The worker has NOT finished ..."`. A running worker is never waited on.
- `worker.get()` is reached only when `isDone()` is true. On a completed `FutureTask`, `get()` reports the result without waiting, so it cannot block or throw `InterruptedException` there.
- `catch (Exception unreadable)` covers `ExecutionException` and `CancellationException`. The worker lambda catches `Throwable` and *returns* it, so `ExecutionException` is not normally possible anyway.
- The sibling "no backend was ever blocked" throw has called the same method on the same path since before this commit.

So the call cannot block, hang, or throw. The worker is still joined in `probe()`'s `finally` exactly as before. Control flow, SQL, and the sticky-flag precedence are all unchanged.

## 3. Closed-set claim: "none of the three probed paths does [retry the lock after a timeout]"

This is **true** on the worktree, and it is appropriately hedged ("going by a reading of ... during SBDEV-3470's review").

- `git grep -ln "@Retryable\|RetryTemplate\|EnableRetry" -- src/main` finds nothing. `OptimisticLockRetry` survives only in a javadoc (`MobilePalletizeWriteService.java:655`, "This replaces the `OptimisticLockRetry` wrapper").
- **closeBOL** (`BillofladingService.java:337-~800`) is one `@Transactional(tenantTransactionManager)` method. Its only `catch` is `catch (IOException e)` at `:742`, and a lock timeout is not an `IOException`. There is no retry loop. A lock timeout aborts the PG transaction, and no savepoint is used.
- **scanPallet** (`MobilePalletizeWriteService.java:217`) contains no `catch` at all (grep matches only comments). `:337-340` explicitly says it is "deliberately NOT papered over with a retry".
- **scanGate**: the probe calls `MobileTruckLoadingService.scanGate` (`:166`), which calls the write service once and maps `PessimisticLockingFailureException` to `lockContention(...)`, which throws. The write service has no `catch`. `notifyOms` runs only on success, outside the boundary.

See L-1 for a narrow caveat on the word "needs" in the surrounding sentence.

## 4. `LEFT_WAIT_BEFORE_CONFIRMED`: is "the worker, not the fixture, is what failed" justified?

No. It is an overclaim, and the lane's own timing points the other way. Details are in M-1.

## 5. Commit message

It is accurate. Every bullet matches the diff. "The message now states the conclusion directly" is true as a description. The problem is that the conclusion itself is not supported (M-1). R-6 is disclosed. "Test-only" is true: no `src/main` path is touched.

## Findings

### [MEDIUM] M-1: `LEFT_WAIT_BEFORE_CONFIRMED` asserts a diagnosis the evidence does not support, and the lane's timing makes it the unlikely one
- **File:** `src/test/java/net/aim_ai/wms/common/fixtures/BlockedBackendReads.java` (constant and its javadoc). It surfaces in all three probes.
- **Confidence:** HIGH
- **Snippet:**
  ```java
  "a backend WAS blocked by this test's holder, but it left the wait before it could be "
          + "confirmed, most likely because the worker hit lock_timeout. The fixture reached "
          + "the held row; the worker, not the fixture, is what failed"
  ```
  and the javadoc: `this one at the worker, which most likely failed on {@code lock_timeout}`.
- **Issue:** There are three problems.
  1. **Identity is never established.** Mobile and Closebol take `rs.next()`'s first row. Palletize asserts `hasSize(1)`. None of them checks that the blocked pid is the worker's backend. The probes' own javadoc (`MobileTruckLoadingLockOrderProbeIT.java:364-368`) names `OutboxDispatcherJob` and orphaned sibling workers as stray waiters. The previous revision said "a backend" for exactly this reason (see probe-race-rereview.md §3). "The fixture reached the held row" and "the worker ... is what failed" are unhedged and follow only if the blocked backend was the worker.
  2. **"Most likely lock_timeout" contradicts this lane's numbers.** `application-postgres-integration.properties:187` sets `wms.tenant.lock-timeout-ms=10000`. The observer polls every 100 ms, and the confirm read runs in the same iteration a few milliseconds after the sighting. Mobile's javadoc (`:370-375`) says so itself: "a real block is caught on the first or second poll". A worker blocked for 10 s would be sighted *and confirmed* on one of its ~100 earlier polls, and the method would return normally. For the worker's lock timeout to be what empties the confirm read, and for no later poll to confirm, the observer would have to see nothing for roughly 10 s and then land its first sighting within milliseconds of the timeout. That takes an observer stall of about the length of the lock timeout. The sticky-flag-then-deadline shape fits a waiter whose wait was shorter than one poll interval much better, and that is by construction *not* the worker at a 10 s timeout.
  3. **In Palletize the message can contradict itself.** The appended `workerOutcome(worker)` can read `"... the worker, not the fixture, is what failed  The worker COMPLETED with no error, so it ran the whole of scanPallet without ever reaching the held row."`, or `"... The worker has NOT finished — it is still running or still blocked elsewhere."`. The second is possible because the worker's 10 s timeout has usually elapsed by the 30 s deadline, but not if the stranger case applies. On the one path this message exists for, the reader gets two claims that cancel out.
- **Why it matters:** F-2 existed to stop this timeout from misdirecting whoever debugs it. The new text now tells them the fixture is fine, but a stray waiter implies nothing about the fixture, and the worker may never have reached the row.
- **Fix:** State only what was observed, and keep the hedge. For example:
  ```java
  "a backend WAS seen blocked by this test's holder, but it was no longer blocked when re-read "
      + "moments later, and no later poll saw a confirmed block. The backend was not checked to be "
      + "the worker's. With this lane's 10 s lock_timeout and a 100 ms poll, the worker timing out "
      + "in that gap needs a ~10 s observer stall, so a short-lived waiter from elsewhere is at least "
      + "as likely. This does NOT show the fixture is correct."
  ```
  Also align the constant's javadoc ("points at the worker, which most likely failed on lock_timeout"). Optionally, for a real identity check, capture `pg_backend_pid()` inside the worker lambda and compare it with the blocked pid. Once that is done, "the worker reached the held row" becomes provable.

### [LOW] L-1: "That needs the service path to retry the lock after a timeout" omits pooled-connection reuse
- **File:** `BlockedBackendReads.java`, javadoc paragraph "Why this second read is stable"
- **Confidence:** MEDIUM
- **Snippet:** `the backend would have to leave the wait (for example on {@code lock_timeout}) and block on our holder again inside it. That needs the service path to retry the lock after a timeout, and none of the three probed paths does`
- **Issue:** The confirm read keys on a **pid**, and the worker's pid is a Hikari-pooled backend. After the worker's call fails and returns its connection, any other borrower of that same backend, such as a scheduled job, could block on the holder again under the same pid. A service-path retry is therefore sufficient but not necessary. In practice the gap is one round trip, measured in milliseconds, so this is effectively unreachable. The conclusion stands and only "needs" overstates it. The retry claim itself is verified true (§3).
- **Fix:** "That needs the same backend to block on our holder again: a service path that retries after a timeout (none of the three probed paths does …), or another borrower of the same pooled connection within one round trip."

## Open questions (low-confidence, non-blocking)

- None at CRITICAL or HIGH.

## Positive observations

- The R-4 constant removes the three-copy message drift the previous review flagged. A text fix like M-1 is now a one-place edit.
- The R-3 rewrite names the correct window, and it cites its source for the retry claim instead of asserting it bare. That claim checks out against all three service paths.
- The R-7 log line has the right placeholder count everywhere and puts pid, old text and new text on one line.
- Reusing `workerOutcome(worker)` is safe on this path because of its `isDone()` guard, so it adds no hang risk.
- R-6 is honestly disclosed rather than silently dropped.

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 1 (M-1) |
| LOW | 1 (L-1) |

R-1 to R-5 and R-7 are resolved, R-6 is disclosed, and behaviour is unchanged apart from text. The fix round did introduce one new false claim. The shared timeout message says the fixture reached the held row and the worker failed on `lock_timeout`, but nothing establishes that the blocked backend is the worker, and with this lane's 10 s lock timeout and 100 ms poll, a worker timeout is the least likely way to reach this branch. The fix is a one-constant text edit.

CHANGES REQUESTED
