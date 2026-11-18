---
title: "SBDEV-4007 P2 (wms2-web-ui) implementation — submit-and-poll"
ticket: SBDEV-4007
phase: P2
created: 2026-11-06
worktree: .claude/worktrees/wms2-web-ui/SBDEV-4007
branch: feature/SBDEV-4007-club-run-async
base: origin/develop 8eb11fe
---

# SBDEV-4007 P2 implementation — wms2-web-ui submit-and-poll

**Verdict:** the gate tests and amendments A1–A4 are all green. The full Jest suite is **2826 passed, 0 failed**: the 2783 baseline, 32 gate tests, 8 amendment tests and 3 tests added during the mutation pass. **37 mutants, 37 killed.** The 2 that survived the first pass got new tests, and those tests kill them. Lint adds no new findings. All commits are local and nothing is pushed.

## Commits (on 8eb11fe, after the gate 0df9f5a)

| SHA | What |
|---|---|
| `8fdefc0` | Gate amendments A1–A4 (Nam). Tests only, confirmed red at an assertion before implementation (39 red, 1 green = the A4 pin, which passes on today's code by design) |
| `e063028` | Existing runClubLine tests moved to the POST submit: scaffolding plus the 4 sanctioned rewrites |
| `8c34858` | Implementation: `store/processes/clubRuns.js`, `components/processes/clubRuns/itemsTable.vue` |
| `d1a56ff` | New test: a stale (overtaken) poll answer cannot move progress backwards |
| `759f54b` | New tests: a re-dispatch does not restart the poller; stop leaves no pending timer (they kill the 2 first-pass survivors) |

## Amendments (8fdefc0)
- **A1.** The FAILED toast must equal `'Failed to run club: ' + lastError`. In the withheld case it must equal `clubRunFailureMessage`'s sentence `"Failed to run club: the run did not complete. Re-check the batch, then try again — the details are in the server log."`.
- **A2.** The harness's `reconcileRunStatus` now answers a configurable state code and is a `jest.fn`, so a test can check call order. The 3-strike S5 test now asserts that reconcile ran before the toast. New `it.each` 530/600/799 → `"The server confirms the club run completed."`. New 527 → the `"still running"` info toast. Neither of those flags the batch unconfirmed.
- **A3.** The S5 3-strike test now uses transport errors plus a malformed body. Its old middle answer was the errors shape, which is now an immediate stop. New `it.each`: an errors-shape poll answer stops after exactly 1 poll, reconciles, and reacts to null, 530 and 527.
- **A4.** New pin: a batch at 527 with no stored job keeps `"The club is running on the server."`.

## Existing tests (e063028)
- **Scaffolding, meaning unchanged.** In `clubRuns.spec.js`, `harness()` now answers through `$post`, with `$get` as a bare mock; this covers every runClubLine test in the file. In `clubRunDetails.spec.js` the 527/530 timeout reconcile, the unconfirmed-offline and the unrecognized-response tests now drive the POST. `itemsTableOnHand.spec.js` gets a `dispatch` stub. `itemsTableRunClubToast.spec.js` needed no change, because the component wraps its lifecycle dispatches in `.catch`.
- **Sanctioned rewrites.** Completion moved from the submit to the DONE poll (S1/S3):
  1. `clubRuns.spec` "treats an EMPTY errors array …": an accepted job with `errors: []` is stored and polled, and raises no submit-time toast.
  2. `clubRuns.spec` "does not tell the operator to retry a club run that already completed": the pin now lives on the DONE handler. A failing `searchClubRuns` after DONE still says "do NOT re-run".
  3. `clubRuns.spec` "leaves the success path alone": the submit stores the job and dispatches `pollClubRunJob` without a toast; DONE then toasts and dispatches `searchClubRuns`.
  4. `clubRunDetails.spec` "submits a repeated click only once …": one `$post` and one `setClubRunJob` commit, instead of one success toast.

## Design notes for review
- **Poll timer.** It is a `setTimeout` chain that re-arms when each timer fires, before the request goes out. The cadence is therefore independent of response latency, which gate test #10 requires: 4–6 polls in one 10 s advance. Responses are applied in issue order, and an answer overtaken by a later one is dropped (pinned by `d1a56ff`). The cadence is 2 s, switching to 10 s once the poller has run for 60 s, measured from when polling starts (gate note 5).
- **Poller registry.** It lives outside Vuex state, in a `WeakMap` keyed by the module's state object. A timer handle is not serialisable, and `persistedState` writes this module to localStorage. Keying by state also stops two stores (test harnesses) from sharing a poller.
- **A2's "other" batch state.** A batch that is readable but at neither 527 nor 530–799 (e.g. restored to 525) gets the "could not be confirmed" toast without the unconfirmed flag. The button already reflects the batch state. Nothing in the amendments pins this branch.
- **Persistence (note, no change).** `clubRunJobs` is persisted along with the rest of `processes.clubRuns`, just as `runPendingBatchId` already is. On mount, `resumeClubRunPolling` overwrites it from `byBatch`. If that read fails after a reload, a stale RUNNING job keeps the button disabled, but "Check run status" stays available. Excluding the key from the blob would be a one-line change to `plugins/persistedState.client.js` if wanted.
- **Backend prefix (gate dispute 2).** A non-business FAILED `lastError` shows "did not complete", because the sanitizer withholds `Club line processing failed:`. Since P1 F2 the API writes `"Club run failed (job N); see server log"` for those instead. That is a full sentence starting with a capital letter, so it **relays** as `"Failed to run club: Club run failed (job N); see server log"`. It is client-safe, but it reads twice. Change it only if you want to.

## Mutation table
Method: copy both production files to `/tmp/sbdev4007-p2-orig`, apply one mutant, run the 4 club-run specs, record the killing test and its message, then restore from the `/tmp` copy (never git). The tree was clean after every batch.

| # | Mutant | Killing test (first) | Message excerpt |
|---|---|---|---|
| M01 | submit uses `$get`, not `$post` | S1 POSTs to /clubLine/clubRunJobs/<encoded batchid> (+19) | `Expected: "/clubLine/clubRunJobs/CLUB%202026%2F11%20%231" / Number of calls: 0` |
| M02 | fast cadence 2000 → 3000 | S2 polls every 2000 ms … (+18) | (S2 cadence and DONE-path timing tests) |
| M03 | slow cadence 10000 → 5000 | S2 polls every 2000 ms, backing off to 10000 ms | `toEqual … Expected -1 / Received +1` (late gap set {5000}) |
| M04 | backoff switch 60 s → 30 s | S2 polls every 2000 ms … | `Expected: >= 25 / Received: 17` early gaps |
| M05 | single-poller guard removed | S2 a second pollClubRunJob for the same job does not RESTART the poller (759f54b) | `Expected: 1 / Received: 0` |
| M06 | `stopClubRunPolling` is a no-op | S2 stopClubRunPolling cancels the pending timer | `Expected: 2 / Received: 17` |
| M07 | stop keeps its timer (only `clearTimeout` removed) | S2 stopClubRunPolling leaves no pending timer behind (759f54b) | `Expected: 0 / Received: 1` |
| M08 | DONE does not mark the batch finished | S3 DONE marks the batch "Club Run Finished" … | `Expected value: ["updateClubRunState", {… "Club Run Finished"}]` |
| M09 | DONE raises no completion toast | "leaves the success path alone" (+S3) | `Expected: "Club line run completed" / Number of calls: 0` |
| M10 | DONE keeps polling | S3 DONE … stops polling | `Expected: 1 / Received: 16` |
| M11 | FAILED toasts the raw lastError | S4 FAILED toasts … (+machine-shaped) | `Expected pattern: /fail/i / Received: "Not enough stock …"` |
| M12 | FAILED does not reconcile | S4 FAILED … reconciles the batch | `Expected value: ["reconcileRunStatus", "CLUB-20261104-001"]` |
| M13 | FAILED keeps polling | S4 FAILED … stops polling | `Expected: 1 / Received: 16` |
| M14 | STUCK toast is the generic failure text | S4 STUCK tells the operator to contact an administrator | `Expected: StringMatching /administrator/i / Received: "Failed to run club: failJob kept failing"` |
| M15 | STUCK keeps polling | S4 STUCK … stops polling | `Expected: 1 / Received: 16` |
| M16 | 3-strike threshold 3 → 4 | S5/A2 … the 3rd consecutive failure reconciles (+3) | `Expected: 3 / Received: 18` |
| M17 | A2: no reconcile before reacting | S5/A2 3-strike (+7) | `reconcileSpy … Expected: "CLUB-20261104-001" / Number of calls: 0` |
| M18 | A2: 530–799 not told it completed | A2 3 strikes, reconcile answers 530 (+3) | `Expected: "The server confirms the club run completed." / Number of calls: 0` |
| M19 | A2: 527 not told it is still running | A2 3 strikes, reconcile answers 527 (+A3 527) | `Expected: "The club is still running on the server. …" / Number of calls: 0` |
| M20 | A3: errors shape counted as a strike | A3 errors-shape poll answer stops at once (null/530/527) | `Expected: 1 / Received: 16` |
| M21 | S5: a success does not reset the strikes | S5 a successful poll resets the failure count | `Expected: 6 / Received: 4` |
| M22 | an overtaken answer is applied | S2 an answer overtaken by a later one is dropped (d1a56ff) | `toEqual … processed 2 vs 6` |
| M23 | S6: resume never polls a live job | S6 a live (RUNNING) job … polling resumes (+QUEUED) | `Expected: 1 / Received: 0` |
| M24 | S6: resume polls a terminal job too | S6 a terminal DONE/FAILED/STUCK job is NOT polled (×3) | `Expected: 0 / Received: 5` |
| M25 | S1: a submit answer for another batch is accepted | S1 a different batchid is not a valid submit answer | `Expected value: ["reconcileRunStatus", …] / Received: [["pollClubRunJob", …]]` |
| M26 | S1: an accepted submit starts no poller | S1 an accepted submit … starts polling (+2) | `Expected value: ["pollClubRunJob", {batchid, jobId: 7}] / Received array: []` |
| M27 | `setClubRunJob` is a no-op | S1 an accepted submit stores the job (+8) | `Expected: ObjectContaining {"jobId": 7, "state": "QUEUED"} / Received: undefined` |
| M28 | C1: a live job is not counted as running | C1 a QUEUED / RUNNING job counts as running (×2) | `toBeTruthy / Received: null` |
| M29 | C2: progress text drops processed | C2 while RUNNING … "Running: <processed> / <total> orders" | `Expected: "Running: 3 / 10 orders" / Received: "Running: 10 orders"` |
| M30 | C2: the queued line loses "queued" | C2 while QUEUED … says the run is queued | `Expected pattern: /queued/i / Received: "Waiting for a worker."` |
| M31 | C3: FAILED shows the raw lastError | C3 a machine-shaped lastError is withheld on screen | `Expected pattern: /did not complete/i / Received: "Club line processing failed: …"` |
| M32 | C3: FAILED keeps Run Club disabled | C3 a FAILED job … re-enables Run Club (×2) | `Expected: false / Received: true` |
| M33 | C4: no resume on mount | C4 on mount it dispatches resumeClubRunPolling | `Expected: "processes/clubRuns/resumeClubRunPolling", … / Received: "noop", …` |
| M34 | C4: no resume on batch change | C4 when clubRunDetails switches … resumes for the new one | `Expected: … "CLUB-20261104-002"` |
| M35 | C4: no stop on beforeDestroy | C4 beforeDestroy dispatches stopClubRunPolling | `Expected: "processes/clubRuns/stopClubRunPolling", …` |
| M36 | A4: the generic 527 sentence is changed | A4 a batch at 527 with NO job … keeps the server-running sentence | `Expected: "The club is running on the server." / Received: "Running."` |
| M37 | the DONE refresh failure advises nothing | "does not tell the operator to retry a club run that already completed" | `Expected pattern: /do NOT re-run/i / Received: ""` |

First pass: 34 of 36 killed. **M05** survived: without the guard, a second dispatch replaces the poller, so there was still exactly one poller and gate #10 could not tell. The guard's real job is not restarting the 60 s clock on a remount. **M07** survived because the orphan timer fires into the `live()` check and does nothing. Both are now killed by the tests in `759f54b`. M37 was added after the first pass for the moved DONE "do NOT re-run" pin.

## Test counts
- Baseline (gate report): 2783 / 2783.
- Final, `node_modules/.bin/jest --coverage=false` on 759f54b with a clean tree: **Test Suites: 152 passed, 152 total — Tests: 2826 passed, 2826 total**.
- Club-run specs only: 103 passed after `8c34858`, before the 3 extra tests were added.
- ⚠ One earlier full run (after 8c34858) had **1 red in `test/components/admin/serviceLogDeepLink.spec.js`**. That suite is unrelated to club runs. It passed alone (20/20) and in the next two full runs. I treat it as a load-sensitive flake, but I did not diagnose it.

## Lint
`yarn lint` runs `eslint .` plus `prettier --check .` repo-wide. I graded the changed files against develop `8eb11fe` via `eslint --stdin --stdin-filename`.
- **ESLint:** 0 errors in all changed files. The 4 modified files have warning sets **identical to develop**, compared with line numbers stripped: `no-console` ×14, plus vue `attribute-hyphenation`, `attributes-order` and `v-slot-style` in itemsTable.vue. Both new spec files are clean.
- **Prettier:** `--check` flags all 7 touched files. The 5 pre-existing ones are **already not Prettier-clean on develop** (verified per file via `--stdin-filepath`), so the repo does not enforce Prettier. The 2 gate spec files from 0df9f5a were not reformatted.

## Sibling sweep: callers of the club-run endpoints (`git grep`)
| Location | What | In scope? |
|---|---|---|
| `store/processes/clubRuns.js` `runClubLine` | the only UI caller of the legacy GET; now POSTs `clubRunJobs` | yes, done |
| `components/processes/clubRuns/itemsTable.vue:runClub` | dispatches `runClubLine` | yes, done |
| `components/processes/clubRuns/tabTables/inventoryOnLaneTable.vue:175` | a comment mentioning runClubLine | no (comment only) |
| `cypress/e2e/wms/club/club-line-order.cy.js` D.1 | rewritten at the gate to POST + poll | yes (gate; not executed) |
| `cypress/support/helpers/wmsHelpers.js:597` `runClubLine()` | legacy GET helper; **no remaining caller** in cypress (`git grep "runClubLine("`) | no; kept by the gate, could be deleted |
| wms2-mobile-ui | no club code (P1 §0 row 17) | no |

## Review fixes (p2-code-review.md, REQUEST_CHANGES → #1–#12)

**Result:** all 12 findings are fixed, with a failing test written before each behavioural fix. The full Jest suite is **2866 passed / 2866** (153 suites). Lint adds no new findings. **Mutation:** I re-ran 56 mutants: the 37 earlier ones (M22 retired, see below), M05b, and 19 new review-fix mutants. All are killed except **R13**, an equivalent mutant; its pattern was then removed as redundant in `c7b4913` (see #6), so every remaining mutant is killed. All commits are local and nothing is pushed.

### Commits (on 759f54b)
| SHA | What |
|---|---|
| `d559fb4` | Failing tests for #1–#9 and #11. 27 red at assertions, none from a TypeError. The pins and controls (UNKNOWN consumer rows, #3/#9 controls, #5 no-fallback rows, #11 state-change row) are green by design |
| `b6e614d` | The sanctioned #4 test-shape changes (below) plus the progress-monotonicity test |
| `3dc5bc4` | Fixes #1–#9, #11, #12 (`store/processes/clubRuns.js`, `itemsTable.vue`, `plugins/persistedState.client.js`) |
| `df51f5a` | #10: Cypress D.1 puts the refusal body in the assertion message, adds the sysprop comment, and deletes the dead legacy helper |
| `df87440` | Lint: names the promise executor parameter `resolve` (a new `promise/param-names` error in my test) |
| `e01d31b`, `cfa5f49` | A #6 row for P1's `ABANDON_INTERRUPTED` text. The `e01d31b` subject overstates it; `cfa5f49` corrects the comment (see R13) |
| `c7b4913` | Drops the redundant `/^abandoned\b/` pattern (R13), per the lead's follow-up. Store specs 85/85; R14 still killed |

### Test-shape changes (sanctioned by the lead, 2026-11-06)
1. **Gate #10** ("a second pollClubRunJob … starts no second poller") now advances in five `tick(2000)` steps instead of one `tick(10000)`. **Why:** #4 skips a fire while a request is in flight. Jest's modern fake timers run every fire inside a single `advanceTimersByTime`, before any answer settles, so a single 10 s advance can only ever see 1 poll. The bounds are unchanged (≥ 4, ≤ 6). **Proof it still discriminates:** M05b, two genuine pollers, dies at `Expected: <= 6 / Received: 10`. M05 alone (guard removed) still dies, but via the `759f54b` no-restart test (`Expected: 1 / Received: 0`). M05 never had two pollers to begin with: the replace path stops the old one.
2. **d1a56ff's "overtaken answer is dropped" test is replaced** by "a slow answer holds the next poll, and an answer landing after a stop is ignored". **Why:** with the in-flight skip, requests are strictly sequential, so the issue-order guard (`seq < poller.applied`) was dead code and was removed (M22 retired). The only stale answer left is one that lands after a stop or a replacement poller, and `live()` drops it. **R09** (`live()` drop removed) dies: `Received: {… "processed": 10, "state": "DONE" …}`, i.e. a post-stop DONE was applied. A new sequence test pins "progress never goes backwards": slow 3, then 5, then 7. It dies under R08.

### Finding → fix → test → mutant
| # | Fix | Test(s) | Mutant → red |
|---|---|---|---|
| 1 | On give-up (3 strikes or job not found) the record becomes `UNKNOWN`, which is not live, before reconciling. `checkRunStatus` also dispatches `resumeClubRunPolling` | store `#1: %s with the batch at %p → … UNKNOWN` (8 rows: 3 strikes / job-not-found × 525/527/530/null). Component `#1: an UNKNOWN job with the batch at …` (520/525 → enabled with an empty line, 527 → running, unconfirmed → locked, 530 → Club Already Run). `#1: Check run status … resumes` | R01 record stays live → `toEqual` (8 rows). R02 no resume → `Expected: "processes/clubRuns/resumeClubRunPolling", "CLUB-20261104-001"` |
| 2 | Reducer `withoutClubRunJobs`; boot commits `processes/clubRuns/resetClubRunJobs` | `test/plugins/persistedStateClubRunJobs.spec.js` (drops the key, keeps siblings, does not mutate live state, boot heals) | R03 → `Expected path: not "clubRunJobs"`. R04 → `Expected: "processes/clubRuns/resetClubRunJobs"` |
| 3 | Per-batch stop generation: `stopClubRunPolling` bumps it; the submit and byBatch start a poller only if it is unchanged | store: stop during the submit / during byBatch, plus a control. Component (real store, fake time): destroyed while byBatch is pending; destroyed while the submit is pending | R05 / R06 → `Expected value: not "pollClubRunJob"`. R07 → `Expected: 0 / Received: 1` (component destroy test) |
| 4 | Skip a fire while a request is in flight (the timer keeps its cadence) | `#4: a hung poll request → later fires send nothing` (never-resolving), the slow-answer test, the monotonicity test | **R08** skip removed → `#4 … Expected: 1 / Received: 5`; slow-answer `Expected: 1 / Received: 2`; monotonic `toEqual` |
| 5 | Refusal starting `"Async club run is disabled for this warehouse ("` → `runClubLineLegacy`, the 8eb11fe try body unchanged. A refresh failure after a legacy run is tagged `legacyCompleted`, so the catch says "do NOT re-run" | `clubRuns.spec`: falls back and RUN CLUBLINE finishes; the legacy refusal is toasted; the legacy refresh failure says do NOT re-run; a business refusal / an "Async…"-but-not-the-kill-switch refusal do NOT fall back | R10 → the kill-switch message surfaces as an error. R11 (startsWith 'Async') → `Expected number of calls: 0 / Received: 1`. R12 → `Expected: StringMatching /do NOT re-run/i / Number of calls: 0` |
| 6 | `INTERNAL_REASON_PATTERNS` += `/log lines/` | `#6 poison guard`, `#6 log-lines pointer`, `#6 abandon text` | R14 → `Expected: "Failed to run club: the run did not complete…"` (kills both log-lines rows; re-run after `c7b4913`). **R13 → removed as redundant** (`c7b4913`, the lead's follow-up). `/^abandoned\b/` was an equivalent mutant: every real P1 abandon text is already withheld, the poison guard by `/log lines/` and the `abandoned: …` texts by the existing bare-key rule `/^[a-z][A-Za-z0-9]*([,:]|$)/`. The `#6 abandon text` row stays and passes via that rule |
| 7 | += `/see server log$/` | `#7 generic runtime failure` | R15 → `Expected: "Failed to run club: the run did not complete…"` |
| 8 | 520/525 after a give-up → `"The club run could not be followed, and the batch is not running now. Check run status before running it again."` (not flagged unconfirmed) | `#8: 520 / 525 after giving up` | R16 → `Expected: StringMatching /not running/i / Received: "The club outcome could not be co…"` |
| 9 | A refused submit clears the batch's FAILED record (`clearClubRunJob`) | `#9: refusal after a FAILED run`, plus a control (a DONE record is kept) | R17 → `Received: {… "state": "FAILED" …}`. R18 (clears any record) → the control's `toEqual` |
| 10 | Cypress D.1 `expect(submit.status, 'submit body=' + JSON.stringify(submit.body))` plus a sysprop comment. The legacy `runClubLine()` helper is deleted (0 callers, `git grep`) | n/a (cypress is not executed) | n/a. ESLint on both cypress files: the same pre-existing `no-undef cy/Cypress` set, one fewer with the helper gone |
| 11 | The visible subtitle loses `role="status"`. A `d-sr-only` `role="status"` span carries `liveStatusMessage`, which is constant (`"The club run is running."`) while RUNNING | `#11: … does not carry the per-poll counts, and stays put`, plus `#11: … DOES change when the run changes state` | R19 → `Expected pattern: not /\d+ \/ \d+/ / Received: "Running: 3 / 10 orders"` |
| 12 | A comment on `stopClubRunPolling`: no ref count, one consumer, two tabs = two stores | n/a | n/a |

### Earlier 37-mutant table, re-run on the review code
All killed, with anchors re-checked against the new code. **M06/M07** were re-anchored to the rewritten `stopClubRunPolling` and both still die: M06 via the slow-answer test (a post-stop answer applied), M07 via `no pending timer` (`Expected: 0 / Received: 1`). **M22** is retired, because its guard was removed by sanction. M10/M13/M15/M20/M24 now show `Received: 2` / `1` instead of 16/5: with the in-flight skip, a broken stop leaks one extra poll, not a flood. They are still killed.

### Counts and lint
- Full Jest at `cfa5f49`, clean tree: **Test Suites 153 passed / 153; Tests 2866 passed / 2866**.
- ESLint, graded against develop `8eb11fe` with line numbers stripped: `store/processes/clubRuns.js`, `itemsTable.vue`, `plugins/persistedState.client.js`, `clubRuns.spec.js`, `itemsTableClubRunJob.spec.js`, `clubRunDetails.spec.js` and `persistedStateClubRunJobs.spec.js` have finding sets **identical to develop**. `clubRunJobPolling.spec.js` has 0 errors after `df87440`.

### Re-review round 1 (APPROVE + M1, L1–L4)
Commits: `dffd65b` (tests first: 6 red at assertions; the M1 3-timeouts test is a pin, green on the old code) · `e080498` (fixes). Full Jest: **153 suites / 2868 passed / 2868**. That is 2866 − 1 removed synthetic row + 3 new. ESLint: 0 errors, finding sets identical to develop on the changed files.

**axios-retry and a timeout.** `plugins/axios.js` `retryCondition` returns `false` whenever `error.response` is absent. An `ECONNABORTED` timeout has no response, so it is **not retried**: one rejection after 15 s, which is one strike. Three timeouts therefore take ~45 s plus the 2 s fire gaps before the give-up path runs.

| # | Fix | Test | Mutant → red |
|---|---|---|---|
| M1 | The poll GET (only) carries `{ timeout: POLL_TIMEOUT_MS }` = 15000 | `M1: the poll GET is sent with { timeout: 15000 }`; `M1: three timeout rejections (ECONNABORTED) are 3 strikes → UNKNOWN record and the reconcile path` | Q01 option removed → `Expected: "/clubLine/clubRunJobs/7", {"timeout": 15000}`. Q02 timeouts exempted from strikes → `Expected: 3 / Received: 4` |
| L1 | A stale-generation submit commits **no** record (and starts no poller); `setRunUnconfirmedBatchId(null)` still runs | store `#3/L1: stopClubRunPolling during the submit → … neither stored nor polled`; component `#3: destroyed while the submit is pending` now also asserts no record | Q03 record committed anyway → `toBeUndefined / Received: {… "jobId": 7 …}` (both tests) |
| L2 | `NOT_RUNNING_MESSAGE` → "…Refresh the club details before running it again." | `#8: 520/525 after giving up` now pins the exact sentence (was `/not running/`) | Q04 old wording → `Expected: "The club run could not be followed, … Refresh t…"` |
| L3 | Comment by `registry.stops`: one integer per batch stopped in this tab, never pruned (a delete would reset the generation to 0 and let a stale start match) | — (accepted with rationale) | — |
| L4 | `/log lines$/`, anchored to the end of P1's poison-guard text | `L4: a business reason that mentions "log lines" mid-sentence is relayed`. **Removed:** my synthetic row `#6 log-lines pointer` ("Run stopped; see the club run claimed log lines for each owner"), which pinned exactly the unanchored behaviour L4 removes | Q05 unanchored → `Expected: "Failed to run club: Pallet labels must match the club log lines…"`. R14b pattern removed → the `#6 poison guard` row reds |

### Re-review round 2 (APPROVE + N1)
Commits: `6b32f50` (tests first: the 2 suffix rows red; the other rows are pins) · `3e11d3b` (fix). Full Jest: **153 suites / 2875 passed / 2875** (+7). ESLint: 0 errors; `store/processes/clubRuns.js` findings identical to develop.

**N1.** P1 `failJob` may append `"; batch at 527 owned by another run"`, which slipped past both end-anchored patterns. They are replaced by `/'club run claimed job=\d+' log lines/` (P1's poison-guard pointer, still not any "log lines": L4's relay row stays green) and `/;\s*see server log\b/` (P1's "<what>; see server log" join, used by the worker and both controller texts).

**Rows added (`re-review N1` describe):** withheld are the worker's "Club run failed (job 9); see server log" with and without the suffix, the poison guard with and without the suffix, and the controller's "Club run could not be submitted; see server log" on the submit path. On the poll, "Club run status unavailable (job 9); see server log" **never reaches a toast**. That row pins A3: an errors-shape poll answer is never relayed, so no pattern mutant can reach it.

**Choice for "see server log" without the "; " prefix: RELAYED.** "Please see server log entries from the night shift before re-running this club" reads as an authored sentence, P1 never writes that shape, and the sanitizer relays authored sentences. Only P1's own `; see server log` pointer is withheld. This is pinned by the `N1 (choice)` row.

| Mutant | Red |
|---|---|
| N01 claimed-job pattern removed | `#6 poison guard`, `N1 poison guard`, `N1 poison guard + suffix` (3) |
| N02 loosened to `/log lines/` | `L4: … "log lines" mid-sentence is relayed` |
| N03 back to `/log lines$/` | `N1 poison guard + failJob suffix` |
| N04 see-server-log pattern removed | `#7 generic runtime failure`, `N1 worker` ×2, `N1 controller submit text` (4) |
| N05 loosened to `/see server log\b/` | `N1 (choice) … RELAYED` |
| N06 back to `/see server log$/` | `N1 worker runtime failure + failJob suffix` |
