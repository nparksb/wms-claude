---
ticket: SBDEV-3470
pr: SiteBossInc/wms2-api#406
commit: ca46c03f026494809936d31244b57817d1616e2c
reviewer: independent code-reviewer lane (read-only; no Maven / no shared container)
date: 2026-09-23
subject: lock-order probes' stale blocked-statement race (test-only)
---

# Review: SBDEV-3470 probe race fix (`ca46c03f`)

Scope: `git show HEAD` in `.claude/worktrees/wms2-api/SBDEV-3470`. It changes three files, +102 lines, all test code:

- `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingLockOrderProbeIT.java`
- `src/test/java/net/aim_ai/wms/integration/service/ClosebolLockOrderProbeIT.java`
- `src/test/java/net/aim_ai/wms/integration/service/PalletizeLockOrderProbeIT.java`

Method: I read the code and reasoned about it. I did not run Maven or Testcontainers, as instructed. I did run one independent check on a throwaway `postgres:14-alpine` (PostgreSQL 14.24) under a container named `sbdev3470-review-pg`, and removed it afterwards. It had no connection to the shared IT container.

## Independent measurement (PostgreSQL 14.24)

Setup: a holder takes `select id from t where id=1 for update` in an open transaction. A worker opens a transaction and runs `select 'worker-previous-statement'`. The observer then reads the worker's row. After that the worker runs the same `FOR UPDATE` and blocks.

```
T1               |select 'worker-previous-statement';|{}   |idle in transaction|Client   <- observer BEGIN, primes status snapshot
T2-same-tx       |select 'worker-previous-statement';|{124}|idle in transaction|Lock     <- same observer tx, worker now blocked
T3-autocommit    |select id from t where id=1 for update;|{124}|Lock                   <- fresh autocommit statement
T4 (tx, after pg_stat_clear_snapshot) -> for-update text
```

T2 shows the defect exactly as described: in one row, `query` and `state` are stale, while `pg_blocking_pids()` (`{124}`) is live and so is `wait_event_type` (`Lock`). T3 confirms that a fresh autocommit statement sees the current text.

## Answers to the six questions

### 1. Is the diagnosis correct? Yes (HIGH confidence), with one refinement

- **Source mechanism (PG14).** `pg_stat_get_activity` builds its rows from `pgstat_read_current_status()`. That function copies every `PgBackendStatus` into `localBackendStatusTable` and keeps the copy until `pgstat_clear_snapshot()` runs, either at end of transaction (`AtEOXact_PgStat`) or when called explicitly. `query`, `state` and `backend_xid` all come from that copy. Two things do not: `wait_event*` is read live from `PGPROC` when the SRF runs, and `pg_blocking_pids()` reads the lock manager live every time it is called. The T2 row above demonstrates all of this.
- **Refinement.** The javadoc and the commit message frame the problem as "a snapshot taken once per transaction". That is true, but the observer runs in autocommit, so for the probes the window is *inside one statement*. `pg_stat_get_activity` is a materialized SRF, so every row's status is copied first. Only then does the pushed-down qual `<holder> = ANY(pg_blocking_pids(pid))` run, row by row. The window is microseconds to milliseconds wide, which matches a flake that is rare but real. This does not change the fix. It is why the race exists even with no multi-statement observer transaction (see F-5).
- **Alternative A: the text is not updated when the extended-protocol Execute starts.** Rejected. In PG14, `exec_parse_message`, `exec_bind_message` and `exec_execute_message` each call `pgstat_report_activity(STATE_RUNNING, <source text>)` before planning or `PortalRun`. The text is therefore published before the executor ever reaches `LockTuple`/`XactLockTableWait`. This holds for pgjdbc's reused server-prepared statements too (no Parse, but Bind and Execute still report). It also holds for batched UPDATEs, which matters for Closebol, whose blocking statement is a flush `UPDATE`. I did not measure this over the extended protocol (psql 14 has no `\bind`), so the evidence here is the source, not a measurement.
- **Alternative B: the worker really is blocked by the holder at B6.** Rejected. B6 is `customerorderPositionRepository.findByOrderId(orderId)` (`MobileTruckLoadingWriteService.java:344`), a plain SELECT that takes only `AccessShareLock`. In AC-2c the holder holds a row lock on `location` (RowShareLock plus its own xid). Nothing in that set conflicts with an `AccessShareLock` on `customerorder_position`, and plain SELECTs never wait on row locks. `pg_blocking_pids` can only name the holder if the worker is waiting on the holder's xid or tuple lock, which means the gate `location` row.
- **Alternative C: `SET LOCAL lock_timeout` is the statement just before the lock.** It is not. `LockTimeoutHibernateJpaDialect` issues it once, at transaction begin (`:213`), not per acquisition, so it cannot sit between B6 and PHASE D.
- **Why B6 and not something later.** Between B6 and the gate lock, PHASE C is predicate-only. PHASE D0 (`handleTruckOffLoadingNoClear`) issues no SQL on this fixture, because `PREFIX` matches neither outbound pattern (`AbstractTruckLoadingPgFixture.java:86-91`). The one exception is a `los_sysprop` read on a `SyspropService` cache miss. `billofladingRepository.save(bol)` on a managed entity emits nothing until a flush, and `findByIdForUpdate` on `location` does not overlap `billoflading`. So B6 is the last statement the worker plausibly reports before blocking on the gate, and it is exactly the text a stale snapshot would carry. The evidence is consistent with the diagnosis.

### 2. Is the second read guaranteed stable? Yes, apart from one sub-millisecond coincidence (LOW)

- **Observer is autocommit.** `open()` is `DriverManager.getConnection(...)`, and pgjdbc defaults to autocommit=true. In all three files, `setAutoCommit(false)` is called only on `holder` (Mobile `:284`, Closebol `:328`, Palletize `:374`). Every observer use is a single `createStatement().executeQuery(...)` inside try-with-resources, and nothing issues `BEGIN`. Each statement is therefore its own implicit transaction, and `AtEOXact_PgStat` discards the status copy between statements. T3 confirms this empirically.
- **Ordering argument.** Let t0 be the moment the worker publishes the blocking statement's text, t1 the first read's `pg_blocking_pids` evaluation (blocked), t2 the second read's status copy, and t3 its `pg_blocking_pids` evaluation. Then t0 < t1 < t2 < t3, and t1→t2 is strictly ordered because the reads are sequential statements on one connection. If the worker stays in the same wait from t1 to t3, the text copied at t2 is the blocking statement's text. The holder's lock set cannot change during this: its only lock is taken before the worker is submitted, and it is released only in the `finally` after `awaitBlockedBackend` returns.
- **Residual window (LOW).** The worker leaves the wait at t1 < x < t3, through lock_timeout (10 s in this lane), a deadlock abort or a cancel, and then re-blocks on the holder before t3 with a new text. None of `scanGate`, `closeBOL` or `scanPallet` has a retry loop (grep found no `@Retryable`/`RetryTemplate`, and `OptimisticLockRetry` was removed from palletize, `MobilePalletizeWriteService.java:655`). A re-block would need a new request to run the path back to the held row within milliseconds. In practice this is unreachable.
- **"The text is updated after the lock wait begins".** Rejected; see alternative A in question 1.

### 3. Loop behaviour on a null return: it is bounded, but the timeout message can be wrong (LOW)

It cannot spin forever: `continue` goes back to `while (System.currentTimeMillis() < deadline)`, and the `Thread.sleep(100)` before it prevents a hot loop. It also cannot turn a real failure into a pass, because the only exit that returns a `Snapshot` is a confirmed row. However, if a worker is seen blocked and later leaves the wait (for example on lock_timeout), the loop ends in the existing message: `"no backend was ever blocked BY THIS TEST'S HOLDER …"`. For that path the message is false (see F-2).

### 4. Palletize: the order is right, and `snapshot()` is not stale

- `hasSize(1)` checks set *membership*. Membership comes from the live `pg_blocking_pids` filter, which the race does not affect; the race affects only the text column. Asserting "exactly one blocked backend" before confirming that backend's text is the correct order. If the confirmation ran first and returned null, a genuine two-backend anomaly could be retried and hidden.
- **`snapshot()` (`PalletizeLockOrderProbeIT.java:533-565`).** `backend_xid` does come from the same per-transaction status copy. `snapshot()` is a fresh autocommit statement taken *after* the confirmation, though. The worker's xid is assigned at its first `FOR UPDATE`, well before it blocks on its second lock, and it stays fixed while the worker is blocked. The `xmax` reads are ordinary heap reads of rows whose locker is blocked, so they are stable too. The uncorrelated scalar subqueries become InitPlans evaluated once, but every value is fixed while the worker is blocked. The same staleness does not apply. The only remaining failure is the one from question 2: lock_timeout fires between the confirmation and `snapshot()`. That produces a NULL or wrong `blocked_xid`, which `assertPreconditions` rejects loudly (`isNotNull().isNotBlank().isNotEqualTo(UNLOCKED)`). It is a false red, not a false green.
- The same reasoning covers Mobile and Closebol, whose follow-up read is live `pg_locks`.

### 5. Sibling sweep: nothing missed

`git grep -n -l "pg_stat_activity\|pg_blocking_pids\|wait_event\|pg_locks" -- src/test src/main` returns 11 files. Only the three patched probes read `pg_stat_activity.query` next to a live blocker check. The others are:

- `ReplenishmentStaleVersionAtLockReadIntegrationTest.java:212` — `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database())`. It reads no text and no `pg_blocking_pids`. `wait_event_type` is read live from `PGPROC` (measured above: `Lock` at T2 next to a stale `state`), so this race does not apply. Its "any session in this DB" blind spot is pre-existing and already stated in its javadoc (`:203-206`). Out of scope for this change.
- `AbstractTruckLoadingPgFixture`, `TestClassTransactionManagerArchTest`, `MobilePalletizeFirstTouchInvariantUnitTest`, `ParcelMonitorViewServiceUnitTest`, and the three `src/main` hits mention these names only in comments, javadoc or production logic. None of them polls both a status column and a lock-manager function.

Positive control: the grep did find all three patched files, so this is not a false-zero scan.

### 6. Are the javadoc and commit message accurate? Substantially yes, with three imprecisions (LOW)

See F-3, F-4 and F-5.

## Findings

### [LOW] F-1: dead null-guards left behind by the fix
- **Files:** `MobileTruckLoadingLockOrderProbeIT.java:447`, `ClosebolLockOrderProbeIT.java` (the `return new Snapshot(...)` in `awaitBlockedBackend`), `PalletizeLockOrderProbeIT.java:553`
- **Confidence:** HIGH
- **Snippet:** `return new Snapshot(blockedStatement == null ? "" : blockedStatement, locked);` and `blockedStatement == null ? "" : blockedStatement,`
- **Issue:** Since the fix, `blockedStatement` is non-null whenever these lines run (a null means `continue`). The ternaries now suggest a state that cannot happen. The one exception is `rs.getString("query")` returning SQL NULL for a row that exists, which happens only for another role's backend without `pg_read_all_stats`, and in that case `""` would hide a privilege problem as a regex miss.
- **Fix:** Drop the ternary. Alternatively, make `confirmedBlockedStatement` return `Optional<String>` and treat a present-but-null `query` as an explicit failure ("query hidden, observer lacks pg_read_all_stats").

### [LOW] F-2: the 30 s timeout message lies on the "blocked, then no longer" path
- **Files:** Mobile `:451-454`, Closebol (`throw new IllegalStateException("no backend was ever blocked …`), Palletize `:489-496`
- **Confidence:** HIGH
- **Snippet:** `"no backend was ever blocked BY THIS TEST'S HOLDER — scanGate never reached the held row, …"`
- **Issue:** The fix adds a path where a backend *was* seen blocked by the holder but was not confirmed, for example because lock_timeout fired between the two reads, and nothing blocked again before the deadline. The loop then says "never blocked" and sends the investigation to the fixture or PHASE C guards, which is the wrong place. It is rare, but this is the one new diagnostic path the change creates.
- **Fix:** Record `Integer lastUnconfirmedPid` (and the first read's text) when `confirmedBlockedStatement` returns null. If it is set when the deadline expires, throw a different message: "backend N was blocked by the holder but left the wait before confirmation (lock_timeout?)".

### [LOW] F-3: "its PREVIOUS statement's text" is slightly imprecise
- **Files:** commit message body; the javadoc in all three files (`"is returned as blocked while carrying its PREVIOUS statement's text"`)
- **Confidence:** MEDIUM
- **Issue:** The stale text is whatever the backend had published when the status copy was taken. That can be any earlier statement in the window, not necessarily the one immediately before the block. For AC-2c it happens to be B6 (see question 1). On a `SyspropService` cache miss in D0 it would have been a `los_sysprop` read. Nothing depends on the distinction, but the wording states more than the mechanism guarantees.
- **Fix:** Use "an EARLIER statement's text (whatever it was running when the status snapshot was taken)".

### [LOW] F-4: "Reproduced" describes a model of the race, not the CI incident
- **Files:** javadoc in all three files and the commit message: `"Reproduced on postgres:14-alpine: within one transaction the stale text and a live blocker count of 1 appear in the same row."`
- **Confidence:** MEDIUM
- **Issue:** The phrase "within one transaction" shows that the reproduction widened the window with an explicit observer transaction, as my T1/T2 measurement does. The probes' observer is autocommit, where the window is intra-statement (see F-5). The claim is true as written, but a reader could take it to mean the autocommit poll itself was reproduced going stale. It was not; it was reasoned about.
- **Fix:** Add "(the window widened with an explicit observer transaction; in the autocommit poll it is the gap between the SRF's status copy and the per-row pg_blocking_pids call)".

### [LOW] F-5: the javadoc implies autocommit fully protects the second read, without saying why the first read is still exposed
- **Files:** javadoc paragraph 2, all three files: `"That relies on the observer being in autocommit (one transaction per statement)…"`
- **Confidence:** MEDIUM
- **Issue:** Paragraph 1 says the snapshot is "taken once per transaction". Paragraph 2 says autocommit (one transaction per statement) is what makes the second read safe. A reader can reasonably ask why the first read is not equally safe, since it is also autocommit. The answer is that the first read's window is inside the statement, and the second read is safe because it is ordered after an observation of the block, not because it runs in autocommit. The logic is correct, but that key step is missing from the text.
- **Fix:** Add one sentence: "The window exists even in autocommit: `pg_stat_get_activity` materializes every row's status before the filter's `pg_blocking_pids()` runs per row. The second read is safe because it starts after a read that already saw the block, not merely because it is a new transaction."

### [LOW] F-6: the helper and its 17-line javadoc are copied verbatim three times
- **Files:** Mobile `:355-381`, Closebol `:364-390`, Palletize `:410-436`
- **Confidence:** HIGH
- **Issue:** The three copies must now be kept in step, and fixing the javadoc for F-3, F-4 or F-5 means three edits. The classes do not share a base class (`AbstractTruckLoadingPgFixture` versus `BasePostgresIntegrationTest`). The existing `open()` is already duplicated, so this follows local precedent.
- **Fix (optional):** Move `confirmedBlockedStatement` and `open()` into a small static `LockProbeSupport` under `integration/service/` and keep one javadoc there. This is acceptable to defer.

### [LOW] F-7: nothing records that the race recurred and was absorbed
- **Files:** all three `awaitBlockedBackend` loops
- **Confidence:** MEDIUM
- **Issue:** When the first read's text differs from the confirmed text, the fix silently takes the confirmed one. That is correct behaviour, but CI then gives no trace of how often the race occurs, and no evidence that this code path ever ran. A test-only change like this one has no failing test demonstrating the fix, so a log line is the cheapest available evidence.
- **Fix:** `if (!Objects.equals(firstText, confirmed)) log.info("SBDEV-3470: stale pg_stat_activity text corrected pid={} was='{}'", …)`.

## Open questions (low-confidence, non-blocking)

- None at CRITICAL or HIGH. The only unmeasured step is alternative A: text publication happening before the lock wait under pgjdbc's extended protocol. The PG14 source is unambiguous, so I rate the diagnosis HIGH, but this link was not measured over the extended protocol.

## Positive observations

- The diagnosis is correct, and it is the non-obvious cause: a mix of snapshot and live reads, not a lock-order regression. The fix is confined to the observer and leaves the lock-order assertions alone. It does not weaken them. A stale-text race could only ever cause a false red on these pins, never a false green.
- The confirmation re-applies the `pg_blocking_pids` predicate instead of just re-reading the text. That is exactly what makes the ordering argument hold.
- The fix went to all three probes, not only the one that failed. That is the right sibling sweep, and the grep confirms it is complete.
- Palletize keeps its `hasSize(1)` anomaly check ahead of the retry, so a real two-backend contention still fails loudly.
- The javadoc names its own precondition (autocommit) and says what to do if it changes (`pg_stat_clear_snapshot()`). My T4 measurement confirms that remedy works.

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| LOW | 7 (F-1 … F-7) |

The diagnosis is correct and the fix closes the race, apart from a sub-millisecond lock_timeout coincidence that has no production-relevant trigger. None of the findings blocks the merge. F-2 (misleading timeout message) and F-3/F-5 (javadoc precision) are the ones worth fixing in the same pass, per the "address Low findings too" standing rule.

APPROVE
