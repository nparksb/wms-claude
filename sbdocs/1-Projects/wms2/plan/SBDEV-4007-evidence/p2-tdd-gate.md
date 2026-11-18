---
title: "SBDEV-4007 P2 (wms2-web-ui) TDD gate — submit-and-poll"
ticket: SBDEV-4007
phase: P2
created: 2026-11-06
worktree: .claude/worktrees/wms2-web-ui/SBDEV-4007
branch: feature/SBDEV-4007-club-run-async
base: origin/develop 8eb11fe
commit: 0df9f5a
---

# SBDEV-4007 P2 TDD gate — wms2-web-ui submit-and-poll

**Verdict:** I wrote 32 new Jest tests and all of them **fail at an assertion**. None fails with a TypeError, "not a function" or an unknown action. All 2783 baseline tests still pass, and the two existing clubRuns suites (29 tests) are green.

**Commit:** `0df9f5a` is local on `feature/SBDEV-4007-club-run-async` and has not been pushed.

**Production change:** the only change is a set of no-op stubs in `store/processes/clubRuns.js`. The stubs are the `clubRunJobs: {}` state, the `setClubRunJob` mutation, and the `pollClubRunJob`, `stopClubRunPolling` and `resumeClubRunPolling` actions. `itemsTable.vue` needed no stub, because every component test already fails at an assertion.

## Toolchain (how the numbers were produced)

- **Node:** the lead's `yarn install` recipe failed on Node 18, because `cypress@15.21.1` requires Node `^20.1 || ^22 || >=24`. I installed with **Node 20.17.0**, using `CYPRESS_INSTALL_BINARY=0 yarn install --frozen-lockfile --ignore-scripts`, and the install exited 0. The worktree therefore has its own complete `node_modules`, not the main checkout's symlink farm with missing packages.
- **Command:** `node_modules/.bin/jest --coverage=false [paths]`. `yarn test` maps to `jest` (package.json `"test": "jest"`). I passed `--coverage=false` so coverage instrumentation doesn't interfere.

## Baseline, before any Jest-visible edit

The baseline is `node_modules/.bin/jest --coverage=false`, run on a clean tree plus the cypress-only edits, which Jest does not load:

```
Test Suites: 150 passed, 150 total
Tests:       2783 passed, 2783 total
```

After the gate:

```
Test Suites: 2 failed, 150 passed, 152 total
Tests:       32 failed, 2783 passed, 2815 total
FAIL test/store/processes/clubRunJobPolling.spec.js
FAIL test/components/processes/clubRuns/itemsTableClubRunJob.spec.js
```

Existing clubRuns tests after the gate: `test/store/processes/clubRuns.spec.js` + `test/components/processes/clubRuns/itemsTableRunClubToast.spec.js` → `Tests: 29 passed, 29 total`.

## Tests

`S` = `test/store/processes/clubRunJobPolling.spec.js`, `C` = `test/components/processes/clubRuns/itemsTableClubRunJob.spec.js`.
Every row is a **correct failure** (assertion failure, behaviour absent).

| # | File | `it` | AC / criterion | Failure excerpt |
|---|---|---|---|---|
| 1 | S | POSTs to /clubLine/clubRunJobs/<encoded batchid> and never calls the legacy runClubLine GET | AC-16 / S1 | `toHaveBeenCalledWith` Expected `"/clubLine/clubRunJobs/CLUB%202026%2F11%20%231"`, Number of calls: 0 |
| 2 | S | an accepted submit stores the job, starts polling, resolves at once and raises no "completed" toast | AC-16 / S1 | `toBeUndefined` Received `[Error: Unrecognized club run response]` |
| 3 | S | an errors-shape refusal is toasted with the sanitized server reason and stores no job | AC-16 / S1 | `$post` expected ≥ 1 call, received 0 |
| 4–7 | S | `it.each`: a non-numeric jobId / an unknown state / a different batchid / the legacy GET body is not a valid submit answer — reconcile, store no job, start no poller | AC-16 / S1 | `$post` Expected `"/clubLine/clubRunJobs/CLUB-20261104-001"`, Number of calls: 0 |
| 8 | S | polls the job every 2000 ms, backing off to 10000 ms once 60 s have passed | AC-16 / S2 | `toBeGreaterThan` Expected > 0, Received 0 (no polls) |
| 9 | S | each poll answer commits processed/total/state for the batch | AC-16 / S2 | Expected `ObjectContaining {processed: 2, state: "RUNNING", total: 10}`, Received `undefined` |
| 10 | S | a second pollClubRunJob for the same batch starts no second poller | single-poller guard / S2 | Expected ≥ 4 polls, Received 0 |
| 11 | S | stopClubRunPolling cancels the pending timer — no further polls | S2 | Expected > 0 polls before stop, Received 0 |
| 12 | S | DONE marks the batch "Club Run Finished", toasts completion, refreshes the list and stops polling | AC-16 / S3 | Expected `["updateClubRunState", {batchid, status: "Club Run Finished"}]`, Received array `[]` |
| 13 | S | FAILED toasts the run failure with the lastError, reconciles the batch, keeps lastError and stops polling | AC-18 / S4 | Expected substring `"Not enough stock on staging lane for SKU WINE-123…"`, Received `""` |
| 14 | S | a machine-shaped FAILED lastError is withheld exactly as the existing sanitizer withholds it | AC-18 / S4 | Expected pattern `/did not complete/i`, Received `""` |
| 15 | S | STUCK tells the operator to contact an administrator, reconciles and stops polling | S4 (STUCK) | Expected `StringMatching /administrator/i`, Number of calls: 0 |
| 16 | S | transport errors and errors-shape answers keep polling at 2 s; the 3rd consecutive failure stops and flags the outcome unconfirmed | S5 | Expected 2 polls, Received 0 |
| 17 | S | a successful poll resets the failure count — failures must be CONSECUTIVE to stop | S5 | Expected 6 polls, Received 0 |
| 18 | S | a live (RUNNING) job from byBatch is stored and polling resumes | AC-17 / S6 | Expected `$get("/clubLine/clubRunJobs/byBatch/CLUB-20261104-001")`, Number of calls: 0 |
| 19 | S | a QUEUED job from byBatch also resumes polling | AC-17 / S6 | Expected `["pollClubRunJob", {batchid, jobId: 7}]`, Received `[["resumeClubRunPolling", …]]` |
| 20–22 | S | `it.each`: a terminal DONE / FAILED / STUCK job is stored (lastError kept) but NOT polled | AC-17 / S6 | Expected `$get(byBatch URL)`, Number of calls: 0 |
| 23 | S | the errors shape (batch has no job) commits nothing and polls nothing | AC-17 / S6 | Expected `$get(byBatch URL)`, Number of calls: 0 |
| 24–25 | C | `it.each`: a QUEUED / RUNNING job for this batch counts as running while the batch is still 525 | AC-16 / C1 | `isClubRunning` `toBeTruthy` Received `null` |
| 26 | C | while RUNNING the readiness line shows "Running: <processed> / <total> orders" | AC-16 / C2 | Expected `"Running: 3 / 10 orders"`, Received `"The club is running on the server."` |
| 27 | C | while QUEUED the readiness line says the run is queued | AC-16 / C2 | Expected `/queued/i`, Received `""` |
| 28 | C | a FAILED job on a restored batch (525) shows its lastError and re-enables Run Club | AC-18 / C3 | Expected substring `"Not enough stock on staging lane…"`, Received `""` |
| 29 | C | a machine-shaped lastError is withheld on screen, as the store sanitizer withholds it | AC-18 / C3 | Expected `/did not complete/i`, Received `""` |
| 30 | C | on mount it dispatches resumeClubRunPolling for the batch on screen | AC-17 / C4 | Expected `("processes/clubRuns/resumeClubRunPolling", "CLUB-20261104-001")`, Number of calls: 0 |
| 31 | C | when clubRunDetails switches to another batch it resumes polling for the new one | AC-17 / C4 | Expected `(…/resumeClubRunPolling, "CLUB-20261104-002")`, Number of calls: 0 |
| 32 | C | beforeDestroy dispatches stopClubRunPolling for the batch | AC-17 / C4 | Expected `("processes/clubRuns/stopClubRunPolling", "CLUB-20261104-001")`, Number of calls: 0 |

**Not run: AC-19, the cypress D.1 rewrite.** `cypress/e2e/wms/club/club-line-order.cy.js` D.1 now POSTs `/clubLine/clubRunJobs/{batchLabel}`, expects 202 with a numeric `jobId` and the requested `batchid`, and then polls `GET /clubLine/clubRunJobs/{jobId}` every 2 s, up to 60 times, until the job is terminal. It asserts `DONE` and `processed === total`. The rewrite removes the "call twice" premise and the "Mirrors what the Mobile UI does" claim, and updates the stage-D header comment. It adds the helpers `submitClubRunJob` and `getClubRunJob` to `cypress/support/helpers/wmsHelpers.js` and keeps `runClubLine`. The gate cannot execute cypress, so these changes are syntax-unverified beyond a review.

### Test design notes (why these will catch real defects)
- **Cadence (#8).** This test measures gaps on fake time with `Date` mocked, by recording `Date.now()` at every poll. The gaps from polls that start before 58 s must all be exactly 2000 ms (at least 25 of them). The gaps from polls that start after 62 s must all be exactly 10000 ms (at least 4). A poller that keeps the 2 s cadence, backs off at the wrong time, or uses `setInterval` drift fails.
- **Single poller (#10).** Two dispatches over 10 s must yield 4–6 polls. Two pollers would produce about 10.
- **S1 invalid answers (#4–7).** Each test also asserts that `$post` was called with the job URL. Without that, the old GET code would pass this test, because a `$get` body without `RUN CLUBLINE` already reconciles. The extra assertion is what makes the test red on develop.
- **Rejections.** Every store call that the stubbed code might reject is wrapped in `settle()`, so a test cannot error at an `await` before it reaches its assertion.

## Existing tests at risk when `runClubLine` moves to POST (DO NOT edit at the gate)

I left all of these unchanged. All pass today.

### A. The mock must move `$get` → `$post`, and the meaning stays the same
In `test/store/processes/clubRuns.spec.js`, the harness at `:77-82` gives `$axios: { $get: getImpl }` and no `$post`. Every test below builds its `runClubLine` answer through it. The cleanest fix is to change the harness to `{ $post: impl, $get: jest.fn() }`.
- `:84` toasts the business reason the API returned
- `:96` does NOT claim a network/server issue
- `:107` still falls back to the generic message when there is no reason
- `:120` prefers the SERVER body of a real HTTP rejection
- `:136` authors the permission sentence for a 403
- `:154` sends a genuine transport failure to the generic message
- `:170` does not put Hibernate internals in front of an operator
- `:197` fails CLOSED on a malformed errors payload
- `:215` does not claim success for a 200 that is not a JSON object
- `:233` never shows a raw JavaScript error
- `:249` prefixes the relayed reason
- `:261` 401 vs 403 (two harnesses, `:269` and `:276`)
- `:283` never puts the `field` token on screen
- `:299` never relays a bare HTTP reason phrase
- `:316` still relays a genuinely authored 4xx/5xx sentence
- `:330` withholds every measured Java-internal shape

In `test/components/processes/clubRuns/clubRunDetails.spec.js`, `setup()` at `:19-23` wires `store.$axios = { $get, $post }`, where the default `$post` returns SKU rows. These `runClubLine` tests drive the run through `get`:
- `:137` `it.each` reconciles timeout against authoritative run state 527/530: the first `$get` rejects and the second is the reconcile read. The first call must move to `post`.
- `:149` keeps an unconfirmed timeout unavailable until a read-only status check succeeds
- `:162` submits a repeated click only once while the first request is outstanding. This one asserts `get` was called once, so it must assert `post` instead.
- `:174` `it.each`: an unrecognized response %p is not evidence of club completion

### B. The meaning changes, so these need a rewrite rather than a mock swap (contract S1 vs SBDEV-3304 pins)
These encode the synchronous contract, where a 200 means the run finished. Under S1, an accepted submit raises **no** completion toast and does **not** refetch. Completion moves to the DONE poll handler (S3).
- `clubRuns.spec.js:187` "treats an EMPTY errors array as success". It expects `toast.success('Club line run completed')` at submit time. The intent, that an empty `errors: []` is not a refusal, survives: an empty array on a valid `{jobId, state, batchid}` body should be accepted. The success-toast expectation does not survive.
- `clubRuns.spec.js:365` "does not tell the operator to retry a club run that already completed". The post-success refetch now happens only on DONE (S3), so this pin belongs on the DONE handler: a `searchClubRuns` failure after DONE must not advise a re-run.
- `clubRuns.spec.js:382` "leaves the success path alone". It expects a success toast and `searchClubRuns` at submit. Rewrite it as: submit commits the job and dispatches `pollClubRunJob`, and DONE toasts and refetches.
- `clubRunDetails.spec.js:162`. Besides the `$get` → `$post` swap, its final `expect(store.$toast.success).toHaveBeenCalledTimes(1)` assumes a completion toast at submit. It should assert one submit and one `setClubRunJob` instead.

### C. Component mounts that will hit C4's new `mounted`/`beforeDestroy` dispatches
- `test/components/processes/clubRuns/itemsTableOnHand.spec.js:39-67`. `mountWith` mocks `$store` with **no `dispatch`**, so a C4 `mounted()` dispatch would throw `this.$store.dispatch is not a function` and redden all 6 tests in the file. Its mock needs `dispatch: jest.fn()`, or the component must guard the call. I recommend the mock fix.
- `test/components/processes/clubRuns/itemsTableRunClubToast.spec.js:16-37`. Its `dispatch` is `mockRejectedValue(...)` for every call, so the C4 mount dispatch will also reject. The assertions at `:46`, `:48`, `:59` and `:67` keep their meaning, but an un-awaited rejected `mounted` dispatch becomes an unhandled rejection. The component should `.catch()` it, or the test should answer the resume dispatch with a resolved value.
- `clubRunDetails.spec.js:115` and `:183` mount `ItemsTable` on a real Vuex store whose default `$get` answers every URL with a club-details object. A real `resumeClubRunPolling` will receive that object for the `byBatch` URL, so it must treat a body with no valid `jobId`/`state` as "no job" (commit nothing, poll nothing). Otherwise these tests start a poller during the test.
- The state fixtures in the existing component specs have no `clubRunJobs` key. Components must therefore read `(clubRuns.clubRunJobs || {})[batchid]`.

## Contract points I dispute or want confirmed

1. **The S4 toast wording for a business lastError is unpinned.** The tests require that the toast contain the lastError and match `/fail/i`. I recommend reusing `clubRunFailureMessage`, i.e. the `'Failed to run club: ' + reason` and `did not complete` sentences, so the FAILED path and the submit path speak one vocabulary. Test #14 already assumes the `did not complete` sentence for the withheld case. **Please confirm.**
2. **The backend `failJob` prefix collides with the sanitizer, and this is probably intended.** P1 AC-9c writes non-business failures to `lastError` as `"Club line processing failed: …"`, and `INTERNAL_REASON_PATTERNS` withholds exactly that prefix. Every non-business FAILED job will therefore show "did not complete", which is right for a NPE. A business failure such as a shortfall, label conflict or size cap relays verbatim. I'm flagging this so nobody "fixes" the sanitizer to unwrap the prefix.
3. **What counts as a poll failure (S5).** The contract counts both a transport error and an errors-shape answer as failures. For `GET /clubRunJobs/{jobId}`, an errors shape most likely means "job not found", e.g. a deleted row. That will never recover, so the run waits 3 polls (about 6 s) before the "could not be confirmed" toast. This is acceptable. One alternative is to stop at once on an errors shape and reconcile. I encoded the lead default.
4. **The S5 toast and STUCK reconcile.** At 3 strikes the contract sets `runUnconfirmedBatchId` and shows today's toast, but does not dispatch `reconcileRunStatus`. Today's unknown-outcome path in `runClubLine` reconciles first. I recommend the poller do the same. It is cheap, and if the job actually finished it avoids a false "could not be confirmed". My test does not forbid this.
5. **The 60 s backoff boundary is measured from when polling started, not from submit.** After a reload, `resumeClubRunPolling` restarts the clock, so a resumed long run polls at 2 s for another 60 s. That is fine. I'm noting it because a "from job `startedAt`" reading would change test #8.
6. **The C2 RUNNING message replaces "The club is running on the server."** for a batch at 527 that has a store job. When there is no store job (a 527 batch from the legacy inline path, or before `resume` answers), the old sentence should remain. No test pins either fallback, so the implementer should keep it.

## Commands run

```bash
# install (Node 20; Node 18 fails cypress's engine check)
CYPRESS_INSTALL_BINARY=0 yarn install --frozen-lockfile --ignore-scripts          # EXIT 0
# baseline
node_modules/.bin/jest --coverage=false                                          # 150/150 suites, 2783/2783
# new tests
node_modules/.bin/jest --coverage=false test/store/processes/clubRunJobPolling.spec.js                    # 23 failed / 23
node_modules/.bin/jest --coverage=false test/components/processes/clubRuns/itemsTableClubRunJob.spec.js   # 9 failed / 9
# existing clubRuns tests
node_modules/.bin/jest --coverage=false test/store/processes/clubRuns.spec.js test/components/processes/clubRuns/itemsTableRunClubToast.spec.js  # 29/29 pass
# full suite after
node_modules/.bin/jest --coverage=false                                          # 2815 total: 32 failed (all new), 2783 passed
```

Classification: 32 correct failures, 0 setup problems, 0 unexpected passes.
