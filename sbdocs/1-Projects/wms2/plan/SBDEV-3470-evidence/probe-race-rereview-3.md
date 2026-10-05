---
ticket: SBDEV-3470
pr: SiteBossInc/wms2-api#406
commit: 0422d12352cecf9631cba1f7340edba05c28aa4d (local, unpushed; amends 1a14be66)
parent: 7a71fba8 (= origin branch head; branch is "ahead 1")
reviewer: independent code-reviewer lane (read-only; no tests run; `mvn -o -q test-compile` exit 0, no output)
date: 2026-09-23
subject: third re-review. Covers only the M-1 and L-1 fixes from probe-race-rereview-2.md
---

# Re-review 3: SBDEV-3470, `0422d123` versus `1a14be66`

## Scope check (item 4): what changed between 1a14be66 and 0422d123

- Both commits have the same parent, `7a71fba8`.
- `git diff 1a14be66 0422d123 --name-only` lists one file: `src/test/java/net/aim_ai/wms/common/fixtures/BlockedBackendReads.java` (+17/-11).
- A diff of every other path is empty (0 lines). The three `*LockOrderProbeIT` classes are byte-identical to 1a14be66.
- The only lines that changed are the constant's javadoc, the constant's text, and the "Why this second read is stable" paragraph. Code and SQL are unchanged.
- `1a14be66` is on no remote branch. Amending it therefore rewrites nothing that was pushed, which is consistent with the R-6 rationale.

**Result: nothing changed beyond M-1 and L-1.**

## Item 1: the new constant and its javadoc

### Branch reachability ("every time it was re-read it was no longer blocked by it")

I read all three loops: Closebol `:379-434`, Palletize `:425-476` and Mobile `:384-436`.

- In every probe, a confirmed re-read `return`s straight out of the loop.
- An unconfirmed re-read sets `sawBlockedButUnconfirmed = true`, sleeps and continues.
- An SQL error in the re-read propagates. It does not reach the branch.
- In Palletize, a sighting with two or more pids fails `hasSize(1)` before any re-read happens. So every re-read that reaches the branch had exactly one candidate.

The throw is therefore reachable only when at least one sighting happened and every sighting's re-read returned `null` before the deadline. That holds in all three probes. The javadoc wording "on every sighting until the deadline" is exact. The constant's wording "every time it was re-read" is true as a statement about the re-reads. One nuance about pid identity is noted as L-A below.

### "10 s lock timeout against a 100 ms poll"

- All three probes extend `BasePostgresIntegrationTest`. Mobile does so through `AbstractTruckLoadingPgFixture`, and the base class carries `@ActiveProfiles("postgres-integration")` (`BasePostgresIntegrationTest.java:47`).
- `src/test/resources/application-postgres-integration.properties:187` sets `wms.tenant.lock-timeout-ms=10000`.
- None of the three classes overrides it: no `@TestPropertySource` and no `properties=`.
- Each loop sleeps `Thread.sleep(100)`.

**Result: accurate.** Production uses 3000 (`src/main/resources/application.properties:119`), but the sentence says "this lane's", so it is correct.

### No new cause claimed

- The constant no longer attributes the failure to `lock_timeout`, to the worker, or to the fixture being correct. It says explicitly that the poll does not check identity. **M-1's three points are addressed:** no identity claim, no "most likely lock_timeout", and no worker-blame text that `workerOutcome` could contradict.
- The javadoc's "here something did reach the held row" follows from "blocked by the holder", because the holder takes one `FOR UPDATE` row lock. The exception would be a waiter for a table-level `ACCESS EXCLUSIVE` lock, which the holder's `RowShareLock` also blocks. I could not find such a waiter on these tables, so I am not raising it.

However, the constant also adds an instruction that repeats the defect R-1 was raised to remove. See M-A.

## Item 2: the L-1 sentence

> "That needs something to re-block on that pid. One way is the service path retrying the lock after a timeout, which none of the three probed paths does ... The other, in principle, is another borrower of the same pooled connection blocking on the holder within one round trip, which nothing in these probes does."

This is accurate and resolves L-1. "Needs something to re-block on that pid" is the correct necessary condition, because the re-read keys on the pid. The retry claim was verified in rereview-2 §3, and this commit leaves it unchanged. One qualification: "Nothing in these probes does" is true of the probes' own code. A pooled borrower in the application context, such as a scheduled job, is outside the probes. The sentence scopes itself to "these probes" and already says "in principle", so it does not overclaim.

## Item 3: the amended commit message

- The R-3 bullet addition ("notes that a pooled connection's pid could in principle be re-blocked by another borrower (L-1)") is accurate.
- The M-1 history is accurate:
  - The quoted first replacement text ("most likely because the worker hit lock_timeout ... the worker, not the fixture, is what failed") matches 1a14be66's constant, with the ellipsis.
  - "the poll never checks that the blocked backend is the worker" and "a worker timeout is the unlikely explanation" match rereview-2 M-1 points 1 and 2.
  - "A second review of this round" is a fair description of rereview-2.
- "Palletize appends workerOutcome(worker), as its sibling message does" is true (`PalletizeLockOrderProbeIT.java:470-472`).
- "Test-only" is true.
- **One problem:** the R-1 bullet names the defect ("told the reader to check the worker's outcome, which no probe reported on that path") and presents it as fixed. The new constant still tells the reader to "check the worker's outcome", in all three probes. So the message describes a fix that the text does not deliver for two of the three probes. See M-A.

## Findings

### [MEDIUM] M-A: the new constant repeats R-1's defect. It says "check the worker's outcome" in two probes that never report it, and the commit message says that defect is fixed
- **File:** `src/test/java/net/aim_ai/wms/common/fixtures/BlockedBackendReads.java:23-27`. It surfaces at `ClosebolLockOrderProbeIT.java:427-428` and `MobileTruckLoadingLockOrderProbeIT.java:432-433`.
- **Confidence:** HIGH
- **Snippet:**
  ```java
  + "so check the worker's outcome and any other session touching the fixture rows";
  ```
- **Issue:** R-1 (probe-race-rereview.md) was exactly this instruction. rereview-2 accepted that Mobile and Closebol do not show the worker's Throwable "because their text no longer tells the reader to look for it". The instruction is now back in the shared constant:
  - **Closebol** (`:339-357`): the worker's returned `Throwable` from `worker.get(90, …)` is discarded, and nothing logs it.
  - **Mobile** (`:295-340`): `workerFailure` is recorded in the `finally`, but it is asserted only after the try/finally, on the normal path. When `awaitBlockedBackend` throws this message, the worker's outcome is never shown.
  - **Palletize** is fine. It appends `workerOutcome(worker)`.

  A reader of the Closebol or Mobile failure is told to check something the failure output does not contain. The amended commit message's R-1 bullet describes this very defect and implies the new text removes it.
- **Fix (either option):**
  - **(a)** Drop the worker half of the instruction from the shared constant, for example `"... (a stray waiter would look the same). Check any other session touching the fixture rows"`. Keep Palletize's appended `workerOutcome(worker)`, which provides the worker half where it exists.
  - **(b)** Make the instruction true everywhere. Pass the `Future` into Closebol's and Mobile's `awaitBlockedBackend` and append a non-blocking outcome, as Palletize's `workerOutcome` does with its `isDone()` guard.

  Option (a) is the smaller change. After either fix, the R-1 bullet in the commit message becomes accurate as written.

### [LOW] L-A: "every time it was re-read it was no longer blocked by it" implies one backend, but sightings across iterations may be different pids
- **File:** `BlockedBackendReads.java:24-25`
- **Confidence:** MEDIUM
- **Issue:** Each iteration re-polls, and each sighting can name a different pid, for example the worker once and an `OutboxDispatcherJob` backend later. The branch guarantees that every sighting's re-read was empty. It does not guarantee that there was one backend. The singular "it" is harmless as a diagnosis, but it reads as "the same backend kept leaving the wait". The javadoc phrasing ("on every sighting") is already exact.
- **Fix (optional, fold into M-A's edit):** `"a backend was seen blocked by this test's holder, but on every sighting it was no longer blocked by it when re-read, so no statement was confirmed. ..."`

## Open questions (low confidence, non-blocking)

- None.

## Positive observations

- M-1 is addressed at the root. The constant and its javadoc no longer claim identity or cause, and the javadoc gives the reason (no identity check, 10 s against 100 ms), which checks out against the test resources.
- The L-1 paragraph now states the true necessary condition (a re-block on the same pid) and lists both routes with the correct scope.
- The amend touched only the one file M-1 and L-1 named. Probe code and SQL are untouched, and it compiles.
- The commit message keeps the M-1 history honest instead of silently replacing the text.

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 1 (M-A) |
| LOW | 1 (L-A) |

- M-1 and L-1 are resolved.
- The branch-reachability and "10 s / 100 ms" claims are accurate.
- Nothing outside BlockedBackendReads.java changed.
- The new constant's closing instruction brings back R-1: two of the three probes say "check the worker's outcome" but never report it, and the commit message says that defect is fixed. The fix is a one-clause edit to the constant.

CHANGES REQUESTED
