---
ticket: SBDEV-3470
pr: SiteBossInc/wms2-api#406
commit: 7a71fba81f4373d5ace2b01855db9db6259d99d9
parent: ca46c03f (reviewed in probe-race-review.md)
reviewer: independent code-reviewer lane (read-only; no Maven test run / no shared container)
date: 2026-09-23
subject: re-review of the fix round for probe-race-review.md F-1..F-7
---

# Re-review: SBDEV-3470 Lows fix round (`7a71fba8`)

Scope: `git show 7a71fba8` in `.claude/worktrees/wms2-api/SBDEV-3470`. It touches 4 files (+108/-96), all under `src/test`:

- NEW `src/test/java/net/aim_ai/wms/common/fixtures/BlockedBackendReads.java`
- `src/test/java/net/aim_ai/wms/integration/service/ClosebolLockOrderProbeIT.java`
- `src/test/java/net/aim_ai/wms/integration/service/PalletizeLockOrderProbeIT.java`
- `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingLockOrderProbeIT.java`

Method: I read the diff and the three `awaitBlockedBackend` loops plus their callers in full. I did not run any tests. I ran `mvn -o -q test-compile`, which passed with no output. `javap -p` on the three compiled probe classes finds no `confirmedBlockedStatement` member. As a positive control, the same `javap` does find `awaitBlockedBackend`.

## 1. Is each of F-1 to F-7 resolved?

| # | Verdict | Evidence |
|---|---|---|
| F-1 dead null-guards | **Resolved** | All three now read `return new Snapshot(blockedStatement, locked);` (Mobile, Closebol) and `Snapshot snap = new Snapshot(blockedStatement, ...` (Palletize). `blockedStatement = confirmed;` runs only after the `confirmed == null → continue` exit, so it is non-null. The caveat in the first review (a SQL-NULL `query` hiding a privilege problem) does not arise in practice. In PG14, `pg_stat_get_activity` emits the *string* `<insufficient privilege>` for `query` when the caller lacks privilege; it is not NULL. Every connection here also uses the same role. Dropping the ternary is therefore safe. (MEDIUM confidence on the PG source detail. It was read from memory of `pgstatfuncs.c`, not re-checked.) |
| F-2 misleading timeout | **Resolved, with one gap** (see R-1) | `sawBlockedButUnconfirmed` and a separate `IllegalStateException` were added in all three loops. |
| F-3 "PREVIOUS statement" | **Resolved** | Javadoc now says "carrying the text of an earlier statement". |
| F-4 "Reproduced" scope | **Resolved** | "reproduced on `postgres:14-alpine` in a widened form: an observer holding ONE explicit transaction open …". |
| F-5 why the first read is exposed | **Resolved** | "Even in autocommit, that single statement first copies every backend's status … and only then evaluates `pg_blocking_pids()` row by row". The second read's safety is now grounded in "taken after the first read saw the backend blocked". |
| F-6 triplicated helper | **Resolved** (optional `open()` move not taken; acceptable) | One `BlockedBackendReads.confirmedBlockedStatement`. `git grep` finds exactly three callers. |
| F-7 no trace of the race | **Resolved** | `log.info("SBDEV-3470 probe: corrected a stale blocked-statement read (was: {})", blockedStatement)`. It is emitted at INFO: `application-postgres-integration.properties:214` sets `logging.level.net.aim_ai=INFO`, and the logger is `getClass()` under `net.aim_ai.wms.integration…`. |

## 2. Does the refactor preserve behaviour exactly?

- **Same SQL.** The helper's string is byte-identical to the removed private method's: `"select query from pg_stat_activity where pid = " + blockedPid + "   and " + holderPid + " = ANY(pg_blocking_pids(pid))"`, including the three-space `"   and "`.
- **Same null handling.** `return rs.next() ? rs.getString("query") : null;` is unchanged. try-with-resources closes the Statement and ResultSet on the caller-supplied connection and does not close the connection. That also matches the original.
- **Same loop.** The old `blockedStatement = confirm(...); if (null) { sleep; continue; }` became `String confirmed = confirm(...); if (null) { flag = true; sleep; continue; } … blockedStatement = confirmed;`. Control flow is identical, and the only additions are the flag and the log. `blockedStatement` is a loop-local, re-initialised to `null` at the top of each iteration, so the post-`continue` state is unchanged.
- **Palletize `hasSize(1)` ordering is unchanged.** The `assertThat(blockedPids)…hasSize(1)` still comes before `BlockedBackendReads.confirmedBlockedStatement(observer, blockedPids.get(0), holderPid)`, and each retry iteration re-asserts it.
- **`log` resolves to an inherited field in all three.** `BasePostgresIntegrationTest.java:85` has `protected final Logger log = LoggerFactory.getLogger(getClass());`. Closebol and Palletize extend it directly. Mobile extends `AbstractTruckLoadingPgFixture`, which `extends BasePostgresIntegrationTest` (`AbstractTruckLoadingPgFixture.java:106`) and declares no `log` of its own. Each loop already used `log.info` a few lines later (`SBDEV-3419 probe`, `SBDEV-3465 AC-2 probe`), and the compile passed.
- **Static helper vs static private method.** The helper takes the observer `Connection` explicitly and touches no instance state, so moving it to a final utility class changes nothing.

## 3. Is the F-2 branch correct?

- **It is set on the right path.** `sawBlockedButUnconfirmed = true` is reachable only inside `if (blockedPid != null)` (Palletize: `if (!blockedPids.isEmpty())`, after `hasSize(1)` passes). That requires the first read's live `pg_blocking_pids` to have named the holder, and then the confirm read to have found it no longer blocked by the holder.
- **It cannot fire when nothing was ever blocked.** If no poll ever returns a row, the flag stays `false` and the original "no backend was ever blocked" message is thrown. `pg_blocking_pids` reads the lock manager live, so a positive first read is real evidence of a block at that instant. A stale-snapshot false positive is impossible here, because the staleness affects only `query`, `state` and `backend_xid`, never the membership predicate. In Mobile and Closebol the blocked backend could in principle be a stranger that is not our worker (they take `rs.next()`'s first row). The message says "a backend", so it stays accurate in that case too.
- **Precedence.** The flag is sticky. If the backend is later seen blocked *and* confirmed, the method returns normally, which is correct. If the deadline expires after an unconfirmed sighting, the new message wins over the old one. That is the intended ordering.
- **Palletize's `hasSize(1)` still comes first.** A two-backend anomaly fails the assertion before the flag can be set, so the new branch cannot mask it.

## 4. Is every claim in the new javadoc true?

- "Shared by the three lock-order probes (…)" is a closed set, and it is true: `git grep BlockedBackendReads -- src` shows exactly those three callers.
- "which all find … with the same `pg_stat_activity` poll" is true. All three polls are textually identical (`select pid, query from pg_stat_activity where datname = current_database() and <holder> = ANY(pg_blocking_pids(pid))`). The javadoc's rendering of the poll omits the `datname` predicate (R-5).
- "first copies every backend's status (which includes `query`) and only then evaluates `pg_blocking_pids()` row by row against the live lock manager" matches the first review's PG14 source analysis (materialized SRF, then qual evaluated per row).
- "a blocked backend cannot advance to another statement" is true while it stays in the wait.
- **"a window of well under a millisecond"** is an unmeasured quantitative claim, and it is narrower than the first review's "microseconds to milliseconds" (R-2).
- **"block again within that sub-millisecond window"** names the wrong window (R-3).
- "If an observer is ever put in a transaction, call `pg_stat_clear_snapshot()` before this read" is correct. The first review's T4 measurement confirms it.

## 5. Is the commit message accurate?

It is substantially accurate. Every bullet matches the diff. The F-7 claim "so CI shows how often it happens" holds because the level is INFO in the `postgres-integration` profile. There is one nit: the bullet quotes `"an earlier statement's text"`, but the javadoc actually says "the text of an earlier statement" (R-6). The commit message does not mention that the new F-2 branch in Palletize drops `workerOutcome(worker)` (R-1).

## 6. Are any references to the removed method, or any imports, left over?

- `git grep -n "confirmedBlockedStatement"` across `src` finds only the helper's definition and the three `BlockedBackendReads.` call sites. The old `// See confirmedBlockedStatement` comments now read `// See BlockedBackendReads`. No `{@link #confirmedBlockedStatement}` remains. `git grep "PREVIOUS statement"` returns nothing.
- **Imports.** `Connection`, `DriverManager`, `ResultSet`, `SQLException` and `Statement` are all still used in each probe, by `open()` (which `throws SQLException`) and by the poll and `pg_locks` reads in `awaitBlockedBackend`. The new helper imports exactly those four `java.sql` types, and all of them are used. There are no orphans. The new `BlockedBackendReads` import is used in each file.

## Findings

### [LOW] R-1: the new F-2 message says "check the worker's outcome", but no probe reports it, and Palletize drops the `workerOutcome` it already had
- **Files:** `PalletizeLockOrderProbeIT.java` (the new `if (sawBlockedButUnconfirmed)` throw, just above the `"no backend was ever blocked BY THIS TEST'S HOLDER -- scanPallet …" + workerOutcome(worker)` throw). The same message appears in `ClosebolLockOrderProbeIT.java` and `MobileTruckLoadingLockOrderProbeIT.java`.
- **Confidence:** HIGH
- **Snippet:**
  ```java
  if (sawBlockedButUnconfirmed) {
      throw new IllegalStateException(
              "a backend WAS blocked by this test's holder, but it left the wait before it "
                      + "could be confirmed, most likely on lock_timeout. Check the worker's "
                      + "outcome, not the fixture");
  }
  ```
- **Issue:** On this path the worker's `Throwable` is the key evidence: a lock-timeout `BusinessException` confirms the diagnosis, and anything else refutes it. Palletize has `workerOutcome(worker)`, and its own javadoc says the worker's failure "must never be swallowed". The old message appends it, but the new one does not. So on exactly the path where the text says "check the worker's outcome", Palletize now withholds the outcome. In Mobile, `workerFailure` is joined in the `finally` but asserted only on the normal path, so it is never shown when `awaitBlockedBackend` throws. In Closebol, the worker's result is discarded (`worker.get(90, …)` return value unused). A reader told to "check the worker's outcome" has nowhere to look.
- **Fix:** In Palletize, append `+ workerOutcome(worker)` to the new message, as the sibling throw does. In Mobile and Closebol, either pass the `Future` in and surface its result the same way, or reword to "the worker's outcome is not captured on this path; rerun with …". The minimal fix is to drop "Check the worker's outcome".

### [LOW] R-2: "well under a millisecond" is an unmeasured figure
- **File:** `BlockedBackendReads.java` javadoc, paragraph 3
- **Confidence:** MEDIUM
- **Snippet:** `The autocommit poll has the same mechanism with a window of well under a millisecond, which is why it flakes rarely rather than always.`
- **Issue:** Nobody measured the intra-statement window. It runs from the status copy to the `pg_blocking_pids()` evaluation for the worker's row. Rows are visited in backend-slot order, and each earlier row pays its own `pg_blocking_pids()` call, which takes every lock-partition LWLock. The shared IT container hosts Hikari pools from several cached Spring contexts, and the CI runner can deschedule the observer mid-statement. So the window can plausibly reach the low milliseconds. The first review deliberately said "microseconds to milliseconds". The javadoc turns that range into a confident, narrower number. The same figure is reused in paragraph 4 (R-3).
- **Fix:** "a window of microseconds to low milliseconds (the gap inside one statement; not measured)". Alternatively, drop the number: "a window far narrower than a transaction".

### [LOW] R-3: the residual-gap sentence names the wrong window
- **File:** `BlockedBackendReads.java` javadoc, paragraph 4
- **Confidence:** HIGH
- **Snippet:** `The only remaining gap would need the backend to leave the wait (for example on {@code lock_timeout}) and block again within that sub-millisecond window.`
- **Issue:** "that sub-millisecond window" refers back to paragraph 3's intra-statement window of the *first* read. The residual gap for the *second* read is different. The backend would have to leave the wait after the first read's `pg_blocking_pids` (t1), publish a new statement before the second read's status copy (t2), and be blocked by the holder again at the second read's `pg_blocking_pids` (t3). The t1→t3 span includes the end of the first statement, a client round trip, and the start of the second statement. It is a different window, and it is not sub-millisecond by construction. The conclusion (practically unreachable, since nothing in these paths retries) is still right. The stated reason is wrong.
- **Fix:** "…and block on the holder again before this read's `pg_blocking_pids()` runs, within one observer round trip. None of `scanGate`, `closeBOL` or `scanPallet` retries, so this needs a new request."

### [LOW] R-4: the fix round re-triplicated code while removing the F-6 triplication
- **Files:** all three `awaitBlockedBackend` loops
- **Confidence:** HIGH
- **Snippet:** the 5-line `if (!confirmed.equals(blockedStatement)) { log.info("SBDEV-3470 probe: corrected …") }` block and the 5-line `if (sawBlockedButUnconfirmed) throw new IllegalStateException("a backend WAS blocked …")` block, copied verbatim three times
- **Issue:** F-6 moved one read into a shared helper, and the same commit adds about 10 identical lines to each of the three probes. The first review accepted the triplication as local precedent. This note only records that the F-2 and F-7 logic now has to be kept in step three times, and R-1's fix would be a three-place edit.
- **Fix (optional):** Fold both into the helper, for example `BlockedBackendReads.confirm(observer, pid, holderPid, firstText, log)` returning `Optional<String>`, plus a static `leftTheWaitBeforeConfirmation()` message factory. Deferring this is acceptable.

### [LOW] R-5: the javadoc's rendering of the poll omits its `datname` predicate
- **File:** `BlockedBackendReads.java` javadoc, paragraph 2
- **Confidence:** HIGH
- **Snippet:** `The poll is {@code select pid, query from pg_stat_activity where <holder> = ANY(pg_blocking_pids(pid))}.`
- **Issue:** All three real polls also have `where datname = current_database()`. The mechanism is unaffected, but the sentence opens with "The poll is", which presents it as the exact text. Someone searching the code for that literal will not find it.
- **Fix:** Add `datname = current_database() and`, or change "The poll is" to "The poll is essentially".

### [LOW] R-6: the commit message quotes a phrase that is not in the javadoc
- **File:** commit message, F-3/F-4/F-5 bullet
- **Confidence:** HIGH
- **Snippet:** `its javadoc now says "an earlier statement's text"`
- **Issue:** The javadoc says "carrying the text of an earlier statement". The meaning is the same, but the quotation marks claim verbatim text.
- **Fix:** Nothing, unless the commit is amended anyway. Do not rewrite a pushed commit for this.

### [LOW] R-7: the F-7 log does not name the pid or the corrected text on the same line
- **Files:** the three `log.info("SBDEV-3470 probe: corrected a stale blocked-statement read (was: {})", blockedStatement)` sites
- **Confidence:** MEDIUM
- **Issue:** The corrected text and pid do appear in the next log line of each probe (`SBDEV-3419 probe: blocked pid=… stmt=…`, `SBDEV-3465 AC-2 probe: …`, and `SBDEV-3438 probe: blockedPid=… stmt=…` inside Palletize's `snapshot()`). With parallel test output interleaved, though, the two lines can separate. The first review's suggestion included the pid.
- **Fix:** `log.info("SBDEV-3470 probe: corrected a stale blocked-statement read pid={} was='{}' now='{}'", pid, blockedStatement, confirmed)`.

## Open questions (low-confidence, non-blocking)

- None at CRITICAL or HIGH.
- In the F-1 row, the claim that PG14 emits the string `<insufficient privilege>` rather than NULL for a hidden `query` comes from memory of the source. If it is wrong, a hidden `query` would now read as "left the wait" (R-1 path) instead of `""`. This cannot happen in this lane, because every connection uses the same role.

## Positive observations

- The extraction is behaviour-preserving to the byte: same SQL, same null contract, same connection ownership. Palletize's `hasSize(1)` guard still precedes the confirm, so a two-backend anomaly still fails loudly and cannot be retried away.
- The F-2 flag is set only after a live `pg_blocking_pids` sighting, so the new message cannot be produced for a run that never blocked. Precedence is correct, so a later confirmed sighting still returns normally.
- The rewritten javadoc now carries the key reasoning step the first review found missing: the second read is safe because it is *ordered after an observed block*, not merely because it runs in a new transaction. It also keeps the `pg_stat_clear_snapshot()` escape hatch.
- The F-7 log is actually visible in this lane (INFO under `net.aim_ai`), so the commit's "CI shows how often it happens" claim holds.
- The fix round has no orphaned imports and no stale references, and `test-compile` is clean.

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| LOW | 7 (R-1 … R-7) |

All seven original findings are addressed, and the refactor is behaviour-preserving. R-1 is the one finding worth fixing before merge under the standing "address Lows too" rule. The new F-2 message points the reader at evidence that none of the probes surfaces, and Palletize dropped the `workerOutcome(worker)` it already had. R-2 and R-3 are javadoc precision fixes (an unmeasured figure, and the wrong window named) and can go in the same small edit. R-4 to R-7 are optional.

APPROVE
