---
ticket: SBDEV-3672
repo: v2/wms2-web-ui
kind: impl-report
head: 63b0a89
created: 2026-10-16
---

# SBDEV-3672: wms2-web-ui implementation report (executor, no ralph)

- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-web-ui/SBDEV-3672`
- **Branch:** `fix/SBDEV-3672-bol-oms-notification-status`, based on origin/develop `add0628`. Not pushed, no PR.

## Commits

| SHA | Subject |
|---|---|
| `36e93c8` | TDD gate: failing specs (unchanged by this pass) |
| `39591fa` | BOL OMS notification status row, requeue and Service Log deep link |

Files in `39591fa`: `components/outbound/bol/outboundBolDetails.vue`, `store/outbound/outboundBols.js`, `components/admin/serviceLog/serviceLog.vue`. No spec file was touched.

## What landed

- **Store (U2).** `getBolOmsStatus({id})` calls `$axios.$get('/billOfLading/omsNotificationStatus/' + id)`. A 404 resolves `null` with no toast. Any other error gets the file's standard error toast and resolves `null`. `requeueBolOms({id})` calls `$axios.$post('/billOfLading/requeueOmsNotification/' + id)`. A 409 resolves `{ conflict: true }` with no toast. Any other error gets the standard toast and resolves `null`.
- **BOL detail (U1).** The "OMS notification" row sits in the middle column after Manifest Location(s), which is plan `:73`.
  - **Fetching.** A computed `outboundBolId` is watched with `immediate: true`. Each id change first clears the status, the requeue message and the confirm dialog, then fetches. A sequence counter drops any late response, whether for an earlier BOL or an earlier fetch of the same one. A rejected dispatch hides the row and shows no toast.
  - **When the row shows.** It is hidden when the status is null (404) or `NOT_SHIPPED`.
  - **Summary text.**
    - Normal: `confirmed/chunkCount delivered · N pending · N failed`.
    - Legacy: `1 legacy notification (1,528 parcels)`, formatted with `toLocaleString('en-US')`.
    - NO_RECORD: `EMPTY_BOL` gives "None sent: empty BOL, no pallets to notify". `PURGED` gives "Record purged (outbox retention N days)". Any other reason gives "No record found (unknown)".
    - When `resendConfirmed > 0`, an extra line says "N delivered via manual resend (of the latest linked message)".
    - A caption "Delivered = HTTP 2xx" shows unless the state is NO_RECORD.
  - **Failed-chunk list.** Each entry shows `Chunk i+1 of N` (or "Single notification"), the attempts and `lastError`. It has an `<a>Service Log</a>` only when `functions` includes `WEB_UI_VIEW_MESSAGES` **and** `messagePresent` is true. Clicking the link commits `admin/setParentTab` 6, then pushes `{path:'/admin', query:{messageId}}`.
  - **Requeue.**
    - The "Requeue failed OMS notification" button shows only when `failed > 0`. It is disabled while a requeue is in flight.
    - It opens a `v-dialog` in the `closeBolPop.vue` idiom: "Requeue N failed OMS notification(s) for this BOL?" with Cancel and Requeue buttons.
    - After Requeue, the result is handled by mode:
      - `REQUEUE`: success toast.
      - `NONE`: shows `reason` inline.
      - Conflict: shows "Another requeue is in progress — refresh and retry" inline, with no error toast.
    - Then the status is fetched again.
- **Service Log (U3).** At the end of `mounted()`, `showDetails({ id: Number(messageId) })` is called only when `$route.query.messageId` is a string that matches `^\d+$`.

## Gate specs before / after (35 tests)

| Run | Suites | Tests |
|---|---|---|
| Gate commit `36e93c8` | 3 failed | 30 failed, 5 passed |
| `39591fa`, coverage off | 3 passed | **35 passed** |
| `39591fa`, inside `yarn test` (coverage on) | 3 passed | 35 passed |

## Mutation table (coverage OFF, `npx jest --coverage=false`)

Each mutant was applied to a copy, the named spec was run, and the file was restored from a scratchpad copy. `git status` stayed clean apart from the three intended files. Driver script: `/tmp/claude-1000/-home-nampark-dev-wms-claude/6b83b798-a844-4039-9485-7c3ea8c657fa/scratchpad/3672ui/mutate.py`.

| # | Mutant | Verdict | Red test(s) |
|---|---|---|---|
| M1 | link gate drops `canViewMessages` | KILLED | J3 no link without WEB_UI_VIEW_MESSAGES |
| M2 | link gate drops `messagePresent` | KILLED | J3 no link when messagePresent is false |
| M3 | Requeue button `v-if="true"` | KILLED | J2 hides when failed = 0 (CONFIRMED, PENDING) |
| M4 | button dispatches without confirm | KILLED | J2 ×4 (confirm-first, confirm→dispatch, NONE, 409) |
| M5 | NONE ignores `reason` | KILLED | J2 shows server reason on NONE |
| M6 | 409 turns into an error toast | KILLED | J2 on 409 … no error toast |
| M7 | rejected 404 dispatch toasts | KILLED | J1 hides row on 404 (rejected dispatch) |
| M8 | NOT_SHIPPED shown | KILLED | J1 hides the row for NOT_SHIPPED |
| M9 | no status reset on id change | KILLED | J1 clears while next fetch in flight |
| M10 | sequence guard removed | KILLED | J1 ignores late response (out-of-order) |
| M11 | watch not immediate | KILLED | 23 tests (J1–J3) |
| M12 | no re-fetch after requeue | KILLED | J2 on confirm … re-fetches |
| M13 | `setParentTab` 5 instead of 6 | KILLED | J3 click commits setParentTab 6 |
| M14 | legacy label dropped | KILLED | J1 legacy oversized row |
| M15 | manual-resend label dropped | KILLED | J1 delivered via manual resend |
| M16 | PURGED omits retentionDays | KILLED | J1 distinct NO_RECORD text |
| M17 | confirm dialog omits the count | KILLED | J2 asks for confirmation naming the count |
| M18 | any `messageId` accepted | KILLED | J4 non-numeric "abc", "901abc", "-1; DROP" (`""` is falsy, so it cannot tell the mutant apart, as the gate noted) |
| M19 | deep link never opens | KILLED | J4 numeric messageId |
| M20 | GET path `/v3`-prefixed | KILLED | J5 GET path |
| M21 | POST path `/v3`-prefixed | KILLED | J5 POST path |
| M22 | store 404 branch removed (toasts) | KILLED | J5 404 resolves null without toast |
| M23 | store 409 branch removed | KILLED | J5 409 resolves {conflict:true} |

**23/23 killed, 0 survived.**

## Full suite (`yarn test`, coverage on)

| Run | Suites | Tests | Failing files |
|---|---|---|---|
| Gate commit `36e93c8` (untouched) | 3 failed, 131 passed / 134 | 30 failed, 2372 passed / 2402 | `outboundBolOmsStatus.spec.js`, `outboundBolsOmsStatus.spec.js`, `serviceLogDeepLink.spec.js` (the 30 gate failures) |
| Final `39591fa` | **134 passed / 134** | **2402 passed / 2402** | none |

The totals are higher than the gate doc's 131/2274 because develop moved from `9e31726` to `add0628`. The pre-fix failures are exactly the 30 gate failures, and develop contributed none.

ESLint on the three files: 0 errors and 53 warnings. All the warnings are `no-console` and similar, matching the files' existing `console.log` idiom. The new store actions add two `console.log(error)` lines in the same pattern as their neighbours.

## Scaffolding edits

None. The specs, jest config and mocks are unchanged.

## Contract mismatches vs the lead's field list

- None blocking. The specs read `state`, `noRecordReason`, `chunkCount`, `confirmed`, `pending`, `failed`, `resendConfirmed`, `retentionDays`, `legacy`, `legacyParcels`, and the `failedChunks[]` fields `outboxId`, `chunkIndex`, `chunkCount`, `attempts`, `nextAttemptAt`, `lastError`, `lastMessageId`, `messagePresent`. That is exactly the list.
- The legacy fixture also puts `legacy`/`legacyParcels` on the **failedChunks entry**. Those fields are not in the API list, and the component does not read them. It uses the top-level `legacy`/`legacyParcels`, so this is harmless either way.
- The plan's Fix B-3 "Response:" line omits the top-level `legacy`/`legacyParcels`. The "Legacy row (A-L6)" bullet two lines above it does name them. The API PR must emit them at the **top level** or the legacy label never renders. Worth checking against api-impl-3672.
- `noRecordReason` values: the UI treats anything other than `EMPTY_BOL`/`PURGED` as unknown.

## Deviations

- **"Delivered (HTTP 2xx)" label (Fix B-3).** It is rendered as a caption "Delivered = HTTP 2xx" under the summary, not as a renamed column. The summary keeps "N/M delivered", which the specs pin.
- **i18n.** None. The three files and their neighbours hardcode English, with no `$t`, so no locale keys were added.
- **Non-404/409 store errors** toast with the file's standard message and resolve `null`. For status, null hides the row. For requeue, null leaves the message unchanged and the status is fetched again. The plan does not specify this case.
- **NO_RECORD wording** was the implementer's choice. The plan left it open, and the specs pin only keyword families and distinctness.
- **Not done:** the manual E2E table from plan §8 (dev only, after the API PR merges), the code review lane, and the PR. All are out of this brief.

## Review round 1 fixes (head `2678b94`)

The review is `review-ui-code.md` (REQUEST CHANGES: 0 High, 5 Medium, 8 Low). All 13 findings are fixed in a single commit, `2678b94` "SBDEV-3672: review fixes — …". None of the findings disputes the plan's design, so nothing was escalated. Q1 (top-level `legacy`/`legacyParcels`) went to the API executor through the lead.

### Finding → fix → spec → mutant

| Finding | Fix | Spec (new unless noted) | Mutant(s) → verdict |
|---|---|---|---|
| **M1** double requeue | `confirmRequeue` refuses re-entry. The dialog stays open with its Requeue button `:loading`/`:disabled` until the POST settles (the `closeBolPop` idiom). Both Requeue buttons stay disabled until the re-fetched status has landed, because the re-fetch is awaited inside the `try` and the flag is released in `finally`. | "a double click on the dialog Requeue button dispatches requeueBolOms once" and "keeps both Requeue buttons disabled until the post-requeue re-fetch has landed" | R1 guard dropped, R2 dialog button not disabled, R3 flag released before re-fetch, X2a outer button not disabled → all KILLED |
| **M2** status GET toasts | `getBolOmsStatus` is silent on every failure: it calls `logApiFailure` and returns `null`, with no toast. A requeue POST that fails with anything other than 409 still toasts. | Store: 500/503/403 and a network error resolve null with no toast. Component: "hides the row without any toast when the status request fails with a 500" | R17 status 500 toasts, M22 (adapted) → KILLED |
| **M3** deep-link unhandled rejection | `getLogDetail` is now `async` with `return await`, so its existing catch runs. A 404 toasts "Service log message N not found", anything else toasts the generic text, and it resolves null. This also fixes the eye icon. `showDetails` opens the dialog only when it got details. The deep-link call has a `.catch` that logs and toasts as a backstop. | `serviceLogsGetLogDetail.spec.js` (3 tests), plus J4 "a rejected detail fetch is caught: error toast, no dialog" and "a detail fetch that resolves null … opens no empty dialog" | R20 un-awaited again, R13 catch dropped, R14 empty dialog → KILLED |
| **M4** R-9 tooltip | A `v-tooltip` (the `openRequest.vue` activator idiom, using the `mdi-information-outline` icon) sits next to the summary when `failed > 0` or `resendConfirmed > 0`. Its text: "A manual Service Log resend is recognised only when it resends the latest attempt linked here. Resending an earlier attempt still reads as failed; use Requeue instead." | "explains the R-9 reconciliation limit …" (present when failed, present on manual resend, absent on a clean CONFIRMED) | R8 never shown, R9 always shown → KILLED |
| **M5** surviving mutants X1–X8 | No code change of its own. Specs were added; X3/X5 were also touched by L2. | "a %s requeue result for the previous BOL is not shown on the next BOL …" (×3: conflict/NONE/REQUEUE), "drops the previous BOL's requeue message and open confirm dialog …", "labels a failed chunk 1-based …", "labels delivery as Delivered (HTTP 2xx)", "a REQUEUE result toasts the requeued count", "a late status response is ignored after switching to a BOL that needs no fetch" | X1, X2a, X3, X4a, X4b, X5, X6, X7 (control), X8 → all KILLED |
| **L1** `?messageId` stays in the URL | `openDeepLinkedMessage()` calls `$router.replace` with the query minus `messageId`/`facility` (other keys kept) whenever `messageId` is present, numeric or not. A rejected replace promise is swallowed. | J4 "drops messageId (and facility) from the URL once read …" and "also drops a non-numeric messageId" | R15 → KILLED |
| **L2** label wording | The caption now reads "Delivered (HTTP 2xx)", matching plan Fix B-3. | X5 spec | X5 → KILLED |
| **L3** stale `requeueMessage` | `confirmRequeue` clears `requeueMessage` when a new requeue starts. | "clears an earlier requeue message when a new requeue starts" | R5 → KILLED |
| **L4** component-wide flag | `requeueingId`, with the computed `requeueing = requeueingId === outboundBolId`. | Covered by the X1 spec: the next BOL's button is enabled while BOL 1's POST is in flight. | R4 → KILLED |
| **L5** wasted GET on open BOLs | The watch key is `omsStatusBolId`: the id when `state ∈ {CLOSED, TRANSFER}` (plan Fix B-3's NOT_SHIPPED predicate), else null. A BOL that becomes shipped therefore fetches, and the server's NOT_SHIPPED stays the backstop. | "sends no status request for a BOL that is not shipped, and fetches once it becomes CLOSED", "fetches for a TRANSFER BOL", and a **new backstop** "hides the row when a CLOSED-looking BOL is answered NOT_SHIPPED by the server" | R6, R7, M8 → KILLED |
| **L6** store error idiom | Both actions use `logApiFailure`. Non-409 requeue failures toast `adminWriteError(error).message`, so a 4xx ProblemDetail `detail` is quoted and a 5xx gets the generic text. | Store: "requeueBolOms: a 500 … generic error toast" and "a 4xx ProblemDetail toasts the server detail" | R18, R19 → KILLED |
| **L7** `href="#"` | The link is `<a :href="/admin?messageId=…&facility=…" @click.prevent=…>`, so open-in-new-tab lands on the admin page with the query. A left click still commits tab 6 and pushes. | "the Service Log link has a real href and carries the selected warehouse" | R10 → KILLED |
| **L8** link not warehouse-scoped | The link carries `facility` = `selectedWarehouse` when one is set. `serviceLog.vue` ignores a link whose `facility` differs from the selected warehouse and toasts which warehouse it belongs to. A link without `facility` is still honoured, so the original J4 cases are unchanged. | J4 "ignores a link made in another warehouse, with a toast" and "opens a link made in the selected warehouse" | R16, R11 → KILLED |

**Why the M8 backstop spec was needed.** After L5, an OPEN BOL never fetches. The gate's "hides the row for NOT_SHIPPED (open BOL)" test still passes, but it no longer reaches the server-side NOT_SHIPPED branch. The new backstop test does reach it.

### Mutation run (coverage OFF), 53 mutants

The driver is `/tmp/claude-1000/-home-nampark-dev-wms-claude/6b83b798-a844-4039-9485-7c3ea8c657fa/scratchpad/3672ui/mutate2.py` and its output is `mutation2.txt` in the same directory. Each mutant was applied to the worktree file, the named spec was run with `npx jest --coverage=false`, and the file was restored from a scratchpad copy. `git status` was clean afterwards.

- **The 23 original mutants (M1–M23)** were re-run against the new code, with match strings updated where the code moved. M7 is now "the component toasts on a failed status fetch" and M22 is "the store toasts on a non-404 status failure". **23/23 KILLED.**
- **The reviewer's X1–X8**, with X2 and X4 each split into two: **9/9 KILLED**, including X7, the reviewer's control.
- **The round-1 targets R1–R21: 21/21 KILLED.**

**Total: 53 KILLED, 0 SURVIVED.**

### Spec and suite counts

| Run | Suites | Tests |
|---|---|---|
| SBDEV-3672 specs at `39591fa` | 3 | 35 |
| SBDEV-3672 specs at `2678b94` (coverage off) | 4 | **67 passed** (`outboundBolOmsStatus` 42, `serviceLogDeepLink` 12, `outboundBolsOmsStatus` 10, `serviceLogsGetLogDetail` 3) |
| `yarn test` at `39591fa` | 134/134 | 2402/2402 |
| `yarn test` at `2678b94` | **135/135** | **2436/2436** |

The suite grew by 34 tests. 32 are the new SBDEV-3672 tests. The other 2 come from `test/store/adminReadLoggingSweep.spec.js` (49 → 51), which automatically enrols any file that calls `logApiFailure`, and `serviceLog.vue` now does. Its two new rows ("every logApiFailure label matches its enclosing action" and "logs no raw axios error" for `serviceLog.vue`) pass. A per-file diff of jest `--json` output between the two heads shows no other file changing count. The `39591fa` side was produced in a temporary detached worktree, since removed.

ESLint on the 4 touched source files shows 0 errors. Warnings per file, before → after:
- `outboundBolDetails.vue`: 8 → 8
- `serviceLog.vue`: 16 → 16
- `outboundBols.js`: 34 → 32
- `serviceLogs.js`: 8 → 8

### Deviations / notes from round 1

- **L8** was optional in the review, and the reviewer's fix line reads "none required beyond M3". It is implemented anyway under the fix-every-finding rule, and it is backward compatible: a link with no `facility` still opens.
- **L7 caveat.** Open-in-new-tab reaches `/admin?messageId=…`, but `admin.vue` opens whichever tab was persisted, because the tab-6 commit happens only on a left click. The message dialog opens once the Service Log pane mounts. Changing `admin.vue` to select a tab from the query is outside the plan's §6 file list, so it was not done.
- **Spec files.** The original 35 gate tests are unchanged. All additions are new `describe` blocks appended to the three gate spec files, plus the new file `test/store/serviceLogsGetLogDetail.spec.js`.

## Review round 2 fixes (head `00a4634`)

Round 2 on `2678b94` was **APPROVE**, with two new Lows. Both are fixed in a single commit, `00a4634` "SBDEV-3672: review round 2 — …".

| Finding | Fix | Spec | Mutant(s) → verdict |
|---|---|---|---|
| **N1:** a hung requeue POST traps the operator in the persistent dialog | The dialog's Cancel button is no longer `:disabled="requeueing"`. The Requeue button stays `:loading`/`:disabled`, and the outer button stays disabled until the request and the re-fetch settle. If the operator cancels mid-flight, `confirmRequeue` still applies the late result (toast or message), re-fetches the status, and leaves the dialog closed. | New: "Cancel stays usable while the requeue is in flight, and a late result still lands without reopening the dialog" | N1a (Cancel disabled again) and N1b (a late result reopens the dialog): KILLED |
| **N2:** `$router.replace` can drop the `search` param that `SearchUrlSync` wrote | `openDeepLinkedMessage` now strips `messageId`/`facility` with `window.history.replaceState` on `new URL(window.location.href)`, the same mechanism the mixin uses. It no longer calls `$router.replace`, which rebuilt the URL from `$route.query` and never saw the mixin's writes. A clean fix inside `serviceLog.vue` was available, so it was taken rather than documented. | Round-1 L1 specs rewritten to assert on `window.location` (and that `$router.replace` is not called). New: "keeps a search param that SearchUrlSync wrote outside vue-router ($route.query lacks it)" | R15 (strip removed), N2a (`facility` left in the URL), N2b (back to `$router.replace` from `$route.query`): KILLED |

**Side effect of N2.** vue-router's in-memory `$route.query` still holds `messageId` after the strip, because the strip bypasses the router. This is harmless: `openDeepLinkedMessage` runs once per mount, and a refresh or back-navigation reads the cleaned address bar.

**Spec edit, recorded.** The two round-1 L1 tests asserted `router.replace` calls. They are my own round-1 specs, not gate contract. They now assert the address bar instead, because the mechanism changed. None of the 35 gate tests were touched.

### Mutation run (coverage OFF), 57 mutants

- The driver is `/tmp/claude-1000/-home-nampark-dev-wms-claude/6b83b798-a844-4039-9485-7c3ea8c657fa/scratchpad/3672ui/mutate3.py` and its output is `mutation3.txt` in the same directory.
- The set is the round-1 set of 53, with R15 retargeted to the `replaceState` line, plus N1a, N1b, N2a and N2b. **57/57 KILLED, 0 survived.**
- `git status` was clean apart from the intended edits.

### Counts

| Run | Suites | Tests |
|---|---|---|
| SBDEV-3672 specs at `00a4634` (coverage off) | 4 | **69 passed**: the 67 from round 1, plus the N1 spec, plus the N2 search-keep spec |
| `yarn test` at `00a4634` | **135/135** | **2438/2438** (+2 over `2678b94`) |

ESLint on `outboundBolDetails.vue` and `serviceLog.vue` reports 0 errors and 20 warnings, all pre-existing in kind. The same two files had 24 warnings at `2678b94`.

## Review round 3 fixes (head `938247a`)

Round 3 on `00a4634` approved the work and raised three Lows. All three are fixed in a single commit, `938247a` "SBDEV-3672: review round 3 — …".

| Finding | Fix | Spec | Mutant(s) → verdict |
|---|---|---|---|
| **R3-L1:** the comment undersold the `$route` divergence | The `replaceState` site in `serviceLog.vue` now has a comment covering four points. Unlike `SearchUrlSync`, which adds a key, this strip removes keys that vue-router knows. `$route.query` still carries `messageId`/`facility` afterwards. That is safe only because nothing on `/admin` reads them after `mounted`. Nobody should rebuild `/admin` URLs from `$route.query`. It also says why `window.history.state` is passed through. | — (comment only) | — |
| **R3-L2:** `history.state` preservation was unpinned (U5 survived) | No code change; the code was already correct. | New J4: "preserves vue-router's history.state while stripping the params" seeds `{ key: 'k1' }` and asserts it survives. | U5 (`replaceState({}, …)`): **KILLED** |
| **R3-L3:** the single-slot `requeueingId` allowed a second POST in the A→B→requeue B→A edge | The guard can be keyed by BOL id in a few lines, so the fix was taken rather than declined. `requeueingId` became `requeueingIds` (BOL id → true). `confirmRequeue` does `$set(requeueingIds, id, true)` and, in `finally`, `$delete(requeueingIds, id)`, and the computed is `requeueing = !!requeueingIds[outboundBolId]`. | New J2: "returning to a BOL whose requeue is still in flight keeps its button disabled, even after another BOL's requeue started". It requeues A, switches to B and requeues B, then returns to A: A's button is disabled and clicking it opens no dialog. B settling does not release A, A settling does, and there are exactly 2 POSTs. | R3L3a (single-slot map) and R3L3b (settling clears every BOL): **KILLED**. R4 (guard component-wide) was re-targeted: **KILLED** |

### Mutation run (coverage OFF): 60 mutants

The driver is `/tmp/claude-1000/-home-nampark-dev-wms-claude/6b83b798-a844-4039-9485-7c3ea8c657fa/scratchpad/3672ui/mutate4.py` and its output is `mutation4.txt` in the same directory. It runs the round-2 set of 57 with R1, R3 and R4 re-targeted to `requeueingIds`, plus U5, R3L3a and R3L3b. **Result: 60/60 KILLED, 0 survived.** `git status` was clean apart from the intended edits.

### Counts

| Run | Suites | Tests |
|---|---|---|
| SBDEV-3672 specs at `938247a` (coverage off) | 4 | **71 passed**: the 69 from round 2 plus the R3-L2 and R3-L3 specs |
| `yarn test` at `938247a` | **135/135** | **2440/2440** (+2 over `00a4634`) |

ESLint on the two touched source files: 0 errors and 20 warnings, the same count as at `00a4634`.

## Review round 4 fixes (head `af44fcc`)

Round 4 on `938247a` was **APPROVE**, with one test-only Low, R4-L1. It is fixed in `af44fcc` "SBDEV-3672: review round 4 — pin in-flight release on error and BOL switch". **No production code changed.**

| Spec added to `outboundBolOmsStatus.spec.js` | What it does | Kills |
|---|---|---|
| "re-enables the Requeue button after a requeue that failed (store resolves null)" | The requeue result is `null`, which is what the store returns for a non-409 error. After it settles, the Requeue button is enabled. | V11 (release only on a non-null result) |
| "re-enables a BOL's Requeue button when its result landed while another BOL was shown" | Requeue A, switch to B, then resolve A's POST while B is on screen. Switching back to A re-fetches A's status once more, and A's button is enabled. | V4 (release moved from `finally` to the end of `try`) and V10 (release only while that BOL is on screen) |

### Mutation results (coverage OFF)

- **The reviewer's 3 survivors.** I reproduced them in `/tmp/claude-1000/-home-nampark-dev-wms-claude/6b83b798-a844-4039-9485-7c3ea8c657fa/scratchpad/3672ui/mutate_r4.py`, which supports multi-edit mutants because V11 needs `result` hoisted out of the `try`. The output is in `mutation_r4.txt`. **V4, V10 and V11 are all KILLED** (1 red test each, as listed above).
- **Regression check.** The full round-3 set of 60 was re-run (`mutate4.py`, output in `mutation4b.txt`): **60/60 KILLED**.
- `git status` was clean apart from the spec edit.

### Counts

| Run | Suites | Tests |
|---|---|---|
| SBDEV-3672 specs at `af44fcc` (coverage off) | 4 | **73 passed** (71 + 2) |
| `yarn test` at `af44fcc` | **135/135** | **2442/2442** (+2 over `938247a`) |

## Security lane L5 fix (head `63b0a89`)

**Finding.** `review-api-security.md` L5: the deep link's `facility` query param was reflected unvalidated into the warehouse-mismatch toast. That is content spoofing; it is not XSS, because `plugins/toast.js` escapes the value. The fix is the single commit `63b0a89` "SBDEV-3672: security L5 — validate the deep link facility param".

**Fix.** In `serviceLog.vue` `openDeepLinkedMessage`, a present `facility` is accepted only if both conditions hold:
- **Known:** it is `selectedWarehouse`, or it is in `state.warehouses`. That list holds the user's facility code strings (`pages/index.vue` `setWarehouses`).
- **Well-formed:** it matches `^[A-Za-z0-9_-]{1,10}$`, since `facility_code` is `varchar(10)`.

Anything else voids the link silently: no detail fetch and no toast. The mismatch toast can therefore only name a validated warehouse code that belongs to the user.

- **Arrays.** A repeated `facility=a&facility=b` arrives as an array, and `===` and `includes` never match an array. I dropped the explicit `typeof` clause from the reviewer's suggested code. It was an equivalent mutant (L5d survived) because the membership check already rejects arrays. The array case is pinned by a spec.
- **Why the pattern stays.** It is the guard for a corrupt or tampered persisted `warehouses` list.

**Specs** (`serviceLogDeepLink.spec.js`):
- The existing "ignores a link made in another warehouse, with a toast" now seeds `warehouses: ['wh01','wh02']`. This is my own round-1 spec; the gate tests are untouched.
- New: `it.each` "ignores a facility that is …" covers spoofed text, a well-formed code the user does not have (`wh99`), an over-long code and a repeated param (array). Each asserts no detail fetch and `toast.error` not called.
- New: `it.each` "ignores malformed facility … even when a corrupt persisted warehouse list contains it" covers `<b>Call 555-0100</b>` and `abcdefghijk`.

**Mutants** (coverage OFF; `mutate5.py`, output in `mutation5.txt`):

| Mutant | Result |
|---|---|
| L5a validation line removed | KILLED (6 red) |
| L5b membership check dropped (pattern only) | KILLED |
| L5c pattern dropped (membership only) | KILLED (2 red) |
| L5e length bound loosened to `+` | KILLED |
| L5d `typeof` dropped | equivalent mutant; the clause was removed instead (see above) |

- Re-run of the earlier set, with R16 re-targeted: 64/64 KILLED in `mutate5.py`.
- The round-4 leak mutants V4, V10 and V11 were re-run with `mutate_r4.py`: all KILLED.

**Counts.**
- SBDEV-3672 specs: 79 passed (73 + 6).
- `yarn test` at `63b0a89`: 135/135 suites, 2448/2448 tests.
- ESLint on `serviceLog.vue`: 0 errors.
