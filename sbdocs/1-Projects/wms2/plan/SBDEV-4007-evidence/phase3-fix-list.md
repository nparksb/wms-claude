# SBDEV-4007 P1 — merged Phase 3 fix list (lead, 2026-11-05)

Sources:
- V = `phase3a-conformance-verifier.md`
- CR = `phase3b-code-review.md`
- S = `phase3b-security-review.md`

Base for every fix: 311e93e9.

## Fix in code (impl lane)

| F | From | Change | Test / proof |
|---|---|---|---|
| F1 | V1 + CR1 (High) | none; tests only | Three AC-7 ITs in `ClubRunJobWorkerIT`, each with a spy that ages the lease and re-claims (`claimNext`) at the point named. (a) In the 2nd `processOrderFenced`: the stale call throws `ClubRunLeaseLostException`, that order has no parcel, and the job row is unchanged by the stale attempt. (b) Before fenced finalize: batch ≠ 530, job ≠ DONE, no outbox rows from the stale attempt. (c) `failJob(stale)`: LeaseLost is thrown and the batch stays 527. **Mutation-check each:** delete the `renewLease` (and the `markDone==0` / `markFailed==0` check) it guards and see it go red with a message naming the fence. |
| F2 | S1 + S2 (Med) | Clients must never see raw exception text. `last_error` stores only client-safe text: the Business/Facade message, or `"Club run failed (job <id>); see server log"`. The abandon path writes `"abandoned: transient database error; will resume"` (or the shutdown text), never `e.toString()`. The full exception is logged at ERROR with the job id. The legacy GET's async-branch `catch (RuntimeException e)` returns a fixed message plus the job id. | Update the AC-9c test to the new text (sanctioned contract change: the plan's AC-9c is reworded by lead). Add a test that an SQL-bearing RuntimeException produces a `lastError` without "SQL"/"constraint"/a class name. Mutation-check. |
| F3 | CR2 + V10 (Med) | `failJob` null-original branch: `last_error` gets the suffix `"; batch at 527 owned by another run"`. | Unit test: batch at 527, no original → batch untouched (no save/state change), job FAILED, suffix present. Mutation-check. |
| F4 | CR3 + V11 (Med) | Poller computes `free` once per tick and spends it across tenants in rotation order. Poller discards get their own counter `wms2.clubrun.job.poller_discarded`; `kick_rejected` is for submit kicks only. | Fix the unit test that mocks a constant active count: two tenants, 1 free → exactly 1 task total. Mutation-check. |
| F5 | CR4, CR5 | Abandon-vs-fail walks the cause chain. A `TransactionSystemException` whose root `SQLException` has SQLState `08*` counts as transient. Remove the dead `InterruptedException` arm. | Unit test: TSE wrapping SQLException("08006") → abandon, not failJob. Mutation-check. |
| F6 | CR6 | `kick()`: `TaskRejectedException` → `kick_rejected` at WARN; any other RuntimeException → `kick_failed` at ERROR with the stack trace. Still swallowed. | Unit test for each arm. |
| F7 | CR7 | When the shutdown flag is set, abandon with `expireNow=true`. Keep `false` only for an interrupt without the flag. | Unit/IT: shutdown flag → lease_until ≤ now. Mutation-check. |
| F8 | CR8 + V5 | Rewrite the `ClubRunShutdownGuard` javadoc with the Spring 6.2.15 sequence: (1) ContextClosedEvent → `initiateShutdown()` → `shutdown()`, no interrupt; (2) lifecycle stop: guard at phase MAX_VALUE before the executor at DEFAULT_PHASE, and `stop(callback)` waits; (3) `destroy()` → `shutdownNow()` interrupts. | — |
| F9 | CR9 | Legacy GET timeout: the message comes from the state: `"RUN CLUBLINE QUEUED"` / `"RUN CLUBLINE RUNNING"`. The pre-P2 web UI (`store/processes/clubRuns.js:460`) treats any message ≠ `"RUN CLUBLINE"` as unrecognized and reconciles via the batch state, so this is safe (lead checked the reviewer's claim that "the pre-P2 UI shows success": it is false). | Controller unit test: timeout while RUNNING → "RUN CLUBLINE RUNNING". |
| F10 | CR10, CR11 | `ClubRunJobItSupport`: `@BeforeEach` deletes stray QUEUED/RUNNING `club_run_job` rows (they are leftovers from aborted runs). In `dropFixture` each DELETE runs on its own; collect the failures and throw at the end. | — |
| F11 | CR12 | none | New IT: hold the job row's lock with `FOR UPDATE` in a 2nd tx; `claimNext()` returns empty without blocking (use a statement or lock timeout guard so a regression fails instead of hanging). Mutation-check by dropping `SKIP LOCKED` in a /tmp copy or via PIT if reachable; otherwise state how it was killed. |
| F12 | CR13 | Fix the `awaitTerminal` javadoc (self-invocation, so the reads autocommit), or call through the proxy. | — |
| F13 | S3 | `awaitTerminal` polls only the job state (one cheap query) and builds the full status DTO (with `processed`) once, on the final read. | Existing AC-10 tests stay green. |
| F14 | S4 | `submit`: look up the live job first (`findLiveByOrderbatchId`) and return early before loading the orders. ON CONFLICT stays as the race guard. | Unit test: live job present → `customerorderRepository` never touched. Mutation-check. |
| F15 | S7 | Poller per-tenant backoff: after an empty claim, skip that tenant for `app.clubline.job.idle-tenant-backoff-seconds` (default 60) on this replica. Submit kicks are unaffected. First check `TenantPoolEvictor`'s idle threshold and say whether 60 s lets idle pools evict. | Unit test: empty claim → tenant skipped on the next tick, revisited after the backoff. |
| F16 | V6 | none | AC-8 test: lease `originalBatchState` null, native `findOriginalBatchState` = 525 → resume. Mutation-check. |
| F17 | V8 | none | AC-9e: seed so the failJob-failure loop is actually exercised (failJob throws on attempts below max, then STUCK). Mutation-check. |
| F18 | V9 | none | AC-2: hold T1's transaction open after its insert so T2 blocks on the unique index, then release; still one job and one row. |

## Accepted, no code change (lead documents)

- **S5:** job ids are sequential, so a user can read any job in the same tenant. The screen already lists every batch, and F2 removes the sensitive part.
- **S6:** 2 workers per JVM shared by all tenants. Documented in the workflow doc along with sizing. A per-tenant cap is a design change; propose it if needed.
- **V12:** the new routes send non-Business errors to RestExceptionHandler, which gives a generic 500 that leaks nothing. Accepted.

## Lead plan/doc edits

- Plan: cron `*/4` (V3); poison-guard deviation (V4); reword AC-9b to "FAILED ⇒ batch ≠ 527, or the job never recorded an original state (owned by another run)"; reword AC-9c for the sanitized text; narrow AC-15b to the swallow plus counter, with AC-14b covering the pickup (V7); C-L2 note.
- Phase 4 docs (V2): `wms2-club-run-workflow.md` §7/§9.9 correction, STUCK reconcile procedure, the fact that deploys consume attempts, worker sizing (S6); `ClubRunJobPollerJob` in the scheduled-jobs catalog.
