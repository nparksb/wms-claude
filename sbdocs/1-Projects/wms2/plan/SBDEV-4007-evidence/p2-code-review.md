# SBDEV-4007 P2 code review (wms2-web-ui), transcribed by the lead because the review lane is read-only

- **Lane:** oh-my-claudecode:code-reviewer (sbdev4007-review), 2026-11-06.
- **Scope:** `git diff 8eb11fe..759f54b`.
- **Method:** the reviewer read the code only. It did not run Jest.

**Verdict: REQUEST_CHANGES.**
- **What blocks:** one High (#1) and four Mediums (#2 to #5).
- **What passed:**
  - The test edits stay in their sanctioned scope.
  - No toast is shown twice.
  - The Cypress test matches the P1 API.
  - The Vue patterns are sound.
  - No new console noise was added.

| # | Sev | Site | Failure scenario | Fix / ruling |
|---|---|---|---|---|
| 1 | High | `clubRuns.js` `reactToUnknownOutcome`, and the poll's errors-shape branch | The poller can give up, after 3 strikes or on "job not found". When it does, the stored job stays QUEUED/RUNNING. The Run button then stays disabled and the progress line stays frozen, even after reconcile reads the batch at 525 or 530. "Check run status" never refreshes the job | Lead: on give-up, mark the record non-live. `checkRunStatus` also dispatches `resumeClubRunPolling`. Add a test for each give-up path |
| 2 | Med | `plugins/persistedState.client.js` reducer persists `processes.clubRuns.clubRunJobs` | 1. After a reload, the stale RUNNING record locks the screen. 2. If byBatch fails, the lock never clears. 3. The map grows without bound | Lead: exclude `clubRunJobs` from persistence, and heal it on boot |
| 3 | Med | `itemsTable.vue` `beforeDestroy`, and the poll dispatched from `runClubLine`/resume | Navigating away before the 202 or the byBatch answer arrives orphans a poller. It then polls for hours and shows toasts on other pages | Lead: a stop-generation guard per batch. Add a test that destroys the component while the request is pending |
| 4 | Med | `fire = () => { … schedule(); pollOnce(++poller.issued) }` | With a slow or hung API, a new GET goes out on every tick. A hung request never counts as a strike | Lead: skip a fire while a request is in flight. Keep the stale-answer drop |
| 5 | Med | `runClubLine` always POSTs | With kill switch `'0'`, every Run is refused. The per-tenant rollback then disables the feature outright | **Nam (2026-11-06): fall back to the legacy GET** when the refusal is P1's `KILL_SWITCH_MESSAGE` ("Async club run is disabled for this warehouse (") |
| 6 | Low | P1's "abandoned after N attempts (max-attempts=2); … 'club run claimed job=…' log lines" passes `isRelayableReason` | The operator sees log text | Lead: withhold it, via `/^abandoned\b/` and `/log lines/`. Add a test |
| 7 | Low | P1's "Club run failed (job N); see server log" | The toast reads "Failed to run club: Club run failed …" | Lead: withhold `/see server log$/` and use the existing server-log sentence |
| 8 | Low | `reactToUnknownOutcome` else-branch at 520/525 | It says "could not be confirmed" while Run is still locked. No test covers it | Lead: fix it together with #1. Add an `it.each` row for 525 |
| 9 | Low | `readinessMessage` C3 | When a re-submit after a FAILED run is refused, the screen shows two different reasons | Lead: clear the batch's FAILED record when a submit is refused |
| 10 | Low | cypress D.1 `expect(submit.status).to.equal(202)` | When the submit is refused, the API's reason is lost. The test assumes `WMS_CLUBLINE_ASYNC='1'` | Lead: put the body in the assertion message and add a comment on the sysprop. The legacy helper is dead now: delete it. The #5 fallback lives in the store, not in Cypress |
| 11 | Low | `itemsTable.vue` `role="status"` subtitle | A screen reader re-reads the progress every 2 s | Lead: keep the progress text outside the live region, and announce only state changes |
| 12 | Info | `stopClubRunPolling` has no ref count | Two tabs each poll and each show a toast. Only one component consumes this today | Lead: document it in a code comment, no ref count |
| 13 | Info | backoff counts from `startedAt` of the poller | A reload restarts the 60 s of 2 s polling | No change |

## Re-review round 1: `759f54b..c7b4913` (lane sbdev4007-rereview, 2026-11-06, read-only, jest not run). **APPROVE**

#1–#12 fixed as ruled. #5 match exact enough and the legacy path is identical to 8eb11fe. #3 generation guard covers every destroy order. #2 exclusion and the boot heal are correct. No assertion weakened beyond the two sanctioned shape changes (gate #10 2 s steps; d1a56ff rewrite).

| # | Sev | Site | Scenario | Lead ruling |
|---|---|---|---|---|
| M1 | Med | pollOnce `$get('/clubLine/clubRunJobs/'+jobId)` + `inFlight` skip | axios has no request timeout, so a black-holed GET leaves `inFlight` true forever: no polls, no strikes, frozen progress, and Check run status can't rescue it | Fix: `{ timeout: 15000 }` on the poll GET so a hang becomes a strike. Test: assert the option is passed, and that a timeout rejection counts toward the 3 strikes |
| L1 | Low | `runClubLine` stale-generation branch commits a live record with no poller | Leave and return during a slow submit → "Queued" with no poller | Fix: on a stale generation, commit nothing (a re-click attaches to the live job) |
| L2 | Low | `NOT_RUNNING_MESSAGE` "Check run status…" | At 520/525 after a give-up the button is hidden | Fix: reword it to "Refresh the club details before running it again." |
| L3 | Low | `registry.stops` Map grows by one entry per batch stopped | Tiny, per-tab | **Accepted with rationale:** pruning would reset a batch's generation and could let a stale start match again. Code comment states the bound |
| L4 | Low | `/log lines/` unanchored | A business reason containing "log lines" would be withheld | Fix: anchor it to the P1 text ending |

## Re-review round 2: `c7b4913..e080498` (sbdev4007-rereview, read-only). **APPROVE**

M1 and L1–L4 are fixed as ruled.
- **M1:** confirmed against `plugins/axios.js` `retryCondition`, which returns false when there is no `error.response`. A timeout is therefore never retried and counts as one strike.
- **Removed test:** the synthetic "#6 log-lines pointer" row was removed legitimately, because it pinned the mid-sentence match that L4 deliberately drops. The real P1 text is still withheld, pinned by the "#6 poison guard" row.

| # | Sev | Site | Scenario | Lead ruling |
|---|---|---|---|---|
| N1 | Low | `/log lines$/`, `/see server log$/` | When P1 `failJob` appends `NOT_OUR_527_SUFFIX` ("; batch at 527 owned by another run"), both anchored patterns miss and the log text is relayed. The lead also found two controller texts on the errors path: "Club run status unavailable (job N); see server log" and "Club run could not be submitted; see server log" | Fix: use `/;\s*see server log\b/` and `/'club run claimed job=\d+' log lines/`. Add withheld rows for every P1 form, with and without the suffix, and keep L4's relay row |

## Re-review round 3: `e080498..3e11d3b` (sbdev4007-rereview, read only). **APPROVE, no findings**

- **All four P1 server-log texts are withheld**, as found by a grep of wms2-api main:
  - the worker's "Club run failed (job N)", with and without the suffix;
  - the worker's poison guard, with and without the suffix;
  - the two controller legacy-async texts.
- **The other relay rows are unchanged:** L4's relay row and the #6/#7 rows.
- **The relay-without-"; " choice is sound.**

**Coverage:** the review rounds together cover every commit from `8eb11fe` to `3e11d3b`, in contiguous ranges:
- `..759f54b` (initial review)
- `..c7b4913` (round 1)
- `..e080498` (round 2)
- `..3e11d3b` (round 3)
