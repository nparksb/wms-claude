---
ticket: SBDEV-3672
repo: v2/wms2-web-ui
kind: review
lane: ui-code
head: af44fcc
created: 2026-10-16
verdict: APPROVE (round 5; no open findings)
---

# SBDEV-3672: wms2-web-ui code review (independent lane)

Worktree `.claude/worktrees/wms2-web-ui/SBDEV-3672` at `39591fa`. Diff is `origin/develop...HEAD`: 3 source files and 3 specs. The reviewer did not author this code. Mutant probes ran on a scratchpad copy (`scratchpad/review-ui/repo`, `node_modules` symlinked). The worktree was not written to.

## Evidence collected

- The 3 specs are green on the copy (35/35, `npx jest --coverage=false`). ESLint on the 3 changed files: 0 errors and 53 warnings, the file-local `no-console` idiom. This matches the executor's claim.
- Of the executor's 23 mutants, M1–M23 were not re-run. 8 additional mutants were run against `outboundBolOmsStatus.spec.js`, and **7 survived** (table in finding M5).
- The API half has not landed yet. `wms2-api` worktree HEAD `150e42d8` contains Fix A only. There is no status DTO, no `legacy`/`legacyParcels`, and no `reason` strings to check the UI against (Open Question Q1).

## Stage 1: plan conformance (Fix B-5, Fix D-6, §8 J1–J5)

| Plan item | Status |
|---|---|
| Row after Manifest Location(s) (`:73`), "38/39 delivered · 1 failed", legacy text, NO_RECORD text by reason | Done (`outboundBolDetails.vue:77-89`, `omsSummary`) |
| Link only if `WEB_UI_VIEW_MESSAGES` **and** `messagePresent` | Done (`:92`). M1/M2 killed |
| Link commits `admin/setParentTab` 6 and pushes `/admin?messageId=<id>` | Done (`:264-268`) |
| `serviceLog.vue` `mounted()` calls `showDetails` only for a numeric id | Done (`serviceLog.vue:307-312`). Purged/failed-fetch handling is missing (M3) |
| Fetched from a `watch` on `outboundBol.id`; a 404 hides the row; NOT_SHIPPED hides the row | Done (`:211-221`, `:182-184`) |
| Requeue only when `failed>0`, confirm names the count, dispatch, re-fetch, NONE shows `reason`, 409 shows inline text without a toast | Done. The double-submit window is open (M1) |
| "Delivered (HTTP 2xx)" label (Fix B-3) | Deviates: a caption reading "Delivered = HTTP 2xx" (L2) |
| R-9 gaps "documented in the UI tooltip" (plan §9 R-9) | **Missing.** No tooltip exists. The only text is "(of the latest linked message)", which appears only when `resendConfirmed > 0` (M4) |
| J5 paths relative to `/v3` | Done |

Stage 1 passes, apart from the R-9 tooltip (M4) and the label wording (L2).

## Issues

### By severity
- HIGH: 0
- MEDIUM: 5
- LOW: 8

### [MEDIUM] M1: a requeue can be submitted twice from the UI
File: `components/outbound/bol/outboundBolDetails.vue:147`, `:239-258`, `:103`
Confidence: HIGH for path (b), MEDIUM for path (a)

There are two windows:

- **(a)** `confirmRequeue` closes the dialog on its first line. The dialog's own Requeue button (`:147`) has no `:disabled`/`:loading`. Vuetify keeps the dialog content in the DOM during its leave transition, so a fast double-click on "Requeue" in the dialog can call `confirmRequeue` twice, which sends two POSTs.
- **(b)** `requeueing` is reset in `finally` (`:247`) **before** the re-fetch (`:258`, not awaited). Until the re-fetch lands, the old status (`failed > 0`) is still on screen, so the "Requeue failed OMS notification" button is visible and enabled again. A second click and confirm sends a second POST.

The server makes this harmless: the second call gets `NONE` "nothing failed", or a 409 if it waited >3 s. The operator, though, sees a success toast followed by "nothing failed" inline, which contradicts the toast. This is the confusion the plan's E2E "Double click" row tries to bound.

Note: `closeBolPop.vue:39-40,74-96`, the idiom this dialog copies, keeps the dialog open with `:loading` on the confirm button until the dispatch settles.

**Fix:**
1. Add `if (this.requeueing) return` as the first line of `confirmRequeue`.
2. Keep `requeueing = true` until `await this.fetchOmsStatus(id)` resolves, with the fetch inside the `try`.
3. Optionally follow `closeBolPop`: bind `:loading="requeueing"` on the dialog's Requeue button and close the dialog after the dispatch.

### [MEDIUM] M2: the informational status GET raises an error toast on every BOL detail view when the endpoint fails
File: `store/outbound/outboundBols.js:175-186` (toast at `:183`), triggered by `outboundBolDetails.vue:211-221`
Confidence: HIGH

`getBolOmsStatus` toasts "Request failed due to a network or server issue" for any non-404 error. The watch fires for **every** BOL detail view, **open BOLs included**: `pages/outbound/outbound-bol/{open,closed}/_id.vue` share this component, and an open BOL can only ever yield NOT_SHIPPED, which is hidden.

Plan §7 pre-mortem 1 names the failure mode: V2.2.40 failed on one tenant, so the "status endpoint 500s on that tenant only". In that case every open- and closed-BOL detail view on that tenant shows a red error toast for a row the operator did not ask for, and on an open BOL the row would be hidden even on success. This is a regression on a core outbound screen, caused by a purely informational read. The component's own comment (`:229-230`) already treats any failure as "just hide the row".

**Fix:** make the status GET silent. Hide the row on every error, and log with `logApiFailure` (or `console.log`) without a toast. Also skip the dispatch when `outboundBol.state` is not a shipped state (see L5).

### [MEDIUM] M3: the Service Log deep link has an unhandled rejection and fails silently on a missing message
File: `components/admin/serviceLog/serviceLog.vue:307-312`. Root cause in `store/admin/serviceLogs.js:97-104`, which predates this change.
Confidence: HIGH

`getLogDetail` is not `async` and returns `this.$axios.$get(...)` without awaiting it. Its `try/catch` therefore never sees a rejection, and the rejected promise flows into `showDetails`. There, `await` throws, and the new `mounted()` call site neither awaits nor catches it. The result is an unhandled promise rejection: no toast, no dialog, and a blank-looking landing.

`messagePresent` gates only the in-app link at render time. The `?messageId=` URL is still reachable in four ways:

- a bookmark or shared URL;
- browser refresh or back-navigation (see L1);
- a message purged between the status read and the click;
- a non-existent numeric id typed by hand.

The plan (C-L5) says outright that this rejection exists. The new code adds a URL-reachable caller without guarding it.

**Fix:** in `serviceLog.vue` `mounted`, use `this.showDetails(...).catch(() => this.$toast.error('Message ' + messageId + ' not found'))`, or wrap it in try/catch inside an async helper. Preferably also make `getLogDetail` `async` with `return await ...`, so its existing catch works for the table's eye icon too. That is a pre-existing defect, and it is in scope here because this ticket adds a caller.

### [MEDIUM] M4: the R-9 limitation tooltip that the plan relies on is absent
File: `components/outbound/bol/outboundBolDetails.vue:80-88`
Confidence: HIGH

Plan §9 R-9 accepts two reconciliation gaps on the condition that they are "documented in the UI tooltip and `wms2-bol-truck-loading-workflow.md`". The gaps are:

1. a Service Log resend of an *earlier* attempt's row is not reconciled;
2. after a failed final link, a resend of the truly latest row is not reconciled.

There is no `v-tooltip` in the diff. The only related text, "(of the latest linked message)" (`:85`), renders only when `resendConfirmed > 0`. That is the reconciled case, not the gap. An operator who resent an earlier attempt from the Service Log sees the chunk still "failed" and gets no explanation. The executor's report does not list this as a deviation.

**Fix:** add a `v-tooltip` (the spec already stubs `v-tooltip` as passthrough) on the failed-chunk list or the "N failed" summary. Suggested text: "A manual Service Log resend is recognised only when it resends the latest attempt shown here. Resending an earlier attempt still reads as failed; use Requeue." Add one assertion for it, and record it in the evidence.

### [MEDIUM] M5: the specs leave 7 behaviours unpinned (surviving mutants)
File: `test/components/outbound/outboundBolOmsStatus.spec.js`. Mutated lines are in `outboundBolDetails.vue`.
Confidence: HIGH (run on a copy, `npx jest --coverage=false`)

| # | Mutant | Result |
|---|---|---|
| X1 | delete `if (id !== this.outboundBolId) return` (`:249`) | **survived** (25/25). A requeue result for BOL A would write `requeueMessage` and toast on BOL B |
| X2 | delete `:disabled="requeueing"` (`:103`) | **survived** |
| X3 | `chunkIndex + 1` → `chunkIndex` (`:262`) | **survived**. An off-by-one "Chunk 12 of 39" for index 12 is invisible to the tests |
| X4 | drop the `requeueMessage = ''` / `showRequeueConfirm = false` resets in the id watcher (`:218-219`) | **survived**. BOL A's "Another requeue is in progress" text, or its open confirm dialog, would carry over to BOL B |
| X5 | drop the "Delivered = HTTP 2xx" caption (`:87`) | **survived** |
| X6 | drop the success toast (`:256`) | **survived** |
| X7 | link passes `outboxId` instead of `lastMessageId` | killed (control) |
| X8 | move `++omsStatusSeq` after `if (!id) return` (`:226-227`) | **survived**. When `bolDetails` is cleared to null mid-fetch (the closed/_id page does this at `created`), the late response is no longer invalidated |

The executor's "23/23 killed" is true of the 23 mutants that were chosen. It does not show that every behaviour in the diff is pinned.

**Fix:**
- One J2 case: switch BOL while the requeue promise is pending, resolve it with `{conflict:true}`, and assert the new BOL shows no conflict text and no toast. This kills X1.
- One case asserting the button is disabled while the requeue is pending. This kills X2.
- Assert the rendered "Chunk 13 of 39" for `chunkIndex: 12`, and "Single notification" for null. This kills X3.
- A watcher case with a conflict message, then a BOL switch, asserting the text is gone. This kills X4.
- Assert the HTTP 2xx caption (X5) and the success toast text (X6).
- Set `bolDetails = null` while BOL 1's fetch is pending, resolve it, and assert no row. This kills X8.

Also add a store case for the non-404/non-409 branch (resolves null plus the toast, or no toast if M2 is taken). Add a J4 case where `getLogDetail` rejects, asserting a handled toast. This depends on M3.

### [LOW] L1: `?messageId` stays in the URL
File: `components/admin/serviceLog/serviceLog.vue:307-312`
Confidence: HIGH

After the operator closes the detail overlay, `/admin?messageId=901` remains. A browser refresh, or a later back-navigation to this history entry, reopens the dialog. Together with M3, a refresh after the message is purged gives a silent failure.

**Fix:** once the query has been read, `this.$router.replace({ query: { ...this.$route.query, messageId: undefined } })`. Alternatively, clear it in `closeDetails`.

### [LOW] L2: the label wording deviates from the plan
File: `outboundBolDetails.vue:87`
Confidence: HIGH

The plan (Fix B-3) says: UI label "Delivered (HTTP 2xx)". The diff renders the caption "Delivered = HTTP 2xx". The executor documents this as a deviation, and it is harmless, but the plan text and the UI should agree.

**Fix:** render "Delivered (HTTP 2xx)", or amend the plan.

### [LOW] L3: stale `requeueMessage` on the generic-error path
File: `outboundBolDetails.vue:249-257`
Confidence: HIGH

When `result` is null (a non-409 failure, toasted by the store), `requeueMessage` keeps its previous value. For example, an earlier "Another requeue is in progress" text stays next to the new error toast. Similarly, a NONE reason stays visible after a later successful re-fetch shows the BOL as fully delivered, until the next requeue or BOL switch.

**Fix:** clear `requeueMessage` at the start of `confirmRequeue`.

### [LOW] L4: the `requeueing` flag is component-wide, not per-BOL
File: `outboundBolDetails.vue:242-248`
Confidence: MEDIUM. It depends on a BOL switch while the component stays mounted, which is the case the watch is designed for.

If the BOL switches while a requeue is in flight, the new BOL's Requeue button stays disabled until the old POST resolves.

**Fix:** track `requeueingId` and compute `requeueing = requeueingId === outboundBolId`.

### [LOW] L5: a wasted status GET on every open-BOL view
File: `outboundBolDetails.vue:211-221`
Confidence: HIGH

An open BOL always returns NOT_SHIPPED, which is hidden, so the component sends one extra request per open-BOL detail view. On its own this is cost only; with M2 it is also noise.

**Fix:** skip the dispatch unless `outboundBol.state` is a shipped state (CLOSED/TRANSFER, per Fix B-3's NOT_SHIPPED predicate). Keep the server's NOT_SHIPPED handling as the backstop.

### [LOW] L6: the store error idiom predates the newer helpers
File: `store/outbound/outboundBols.js:182,197`
Confidence: LOW. This is a style judgement, and the file-local idiom is `console.log(error)`.

Newer store code uses `util/apiError.js` `logApiFailure`, which `store/admin/serviceLogs.js` already uses. It also uses `adminWriteError(error)` for ProblemDetail messages. The `plugins/axios.js` hook redacts the token, so `console.log(error)` no longer leaks it. However, on the requeue POST, a ProblemDetail `detail` from the server, for example a 400, is discarded in favour of the generic text.

**Fix:** use `logApiFailure`, and surface the ProblemDetail `detail` for non-409 requeue errors.

### [LOW] L7: no accessible affordance on the Service Log link
File: `outboundBolDetails.vue:92`
Confidence: LOW

`<a href="#" @click.prevent>` works, but the surrounding screens use `v-btn text`/`NuxtLink` for navigation. Middle-click or "open in new tab" opens `#` on the BOL page instead of the Service Log.

**Fix:** use `<nuxt-link :to="{ path: '/admin', query: { messageId } }" @click.native="$store.commit('admin/setParentTab', 6)">`. Another option is a `v-btn text x-small`.

### [LOW] L8: the deep link is not scoped to the warehouse
File: `serviceLog.vue:307-312`
Confidence: LOW

A `?messageId=` URL copied or bookmarked under one facility and opened while another warehouse is selected resolves the same numeric id in that warehouse's tenant DB. It shows an unrelated message, or hits M3. This is rare, and the link is not designed to be shared.

**Fix:** none required beyond M3. Optionally carry `facility` in the query and ignore the id on a mismatch.

## Open Questions (low-confidence or not yet checkable)

- **Q1 [MEDIUM]: the response contract is not verifiable yet.** The API Fix B has not landed (`wms2-api` worktree `150e42d8`). Four things need checking when it does:
  1. That `legacy`/`legacyParcels` are emitted at the top level. If they are not, the legacy label never renders. The executor flagged this too.
  2. That null fields are not dropped by `@JsonInclude(NON_NULL)`. The UI tolerates a missing `noRecordReason`, which falls to "unknown", but a missing `failedChunks` or `resendConfirmed` is also tolerated, so a contract break there would be silent.
  3. The exact `reason` strings ("in flight, nothing to requeue", "nothing failed").
  4. That the lock-timeout response is really 409.

  Check the UI fixtures against the API's serialized DTO before the UI PR is opened.
- **Q2 [LOW]: a possible double toast on an authz 403.** `plugins/axios.js` toasts an `X-Authz-Denied` 403, and both new store actions toast again in their catch. This is unreachable in practice, because the endpoints and the page share `WEB_UI_VIEW_BILL_OF_LADING`.

## Positive observations

- The sequence guard, the clear-on-id-change and the immediate watch are correct and well pinned (M9–M11). The spec's positive controls before every "hidden" assertion avoid vacuous passes.
- Numeric-only `messageId` is enforced with an anchored regex and a `typeof` check, and is pinned against `"901abc"` and `"-1; DROP"`.
- `canonical` tab 6 is used, consistent with the `admin.vue` ADMIN_TABS contract.
- The 404 and 409 branches are handled in the store, so the component never has to parse HTTP errors.
- The store paths are relative to the `/v3` baseURL, and J5 pins this.

## Recommendation

**REQUEST CHANGES.** There is no High finding. M1–M5 are Medium at HIGH confidence, and per Nam's rule the Lows are fixed in the same pass. The minimum set is:

- **M2:** silence the status GET.
- **M3:** catch the deep-link rejection.
- **M1:** guard against double submission.
- **M4:** add the R-9 tooltip.
- **M5:** add the spec cases that kill X1–X6 and X8.
- **L1–L8.**

---

## Round 2 (scoped, head 2678b94)

Scope: `git diff 39591fa..2678b94`, a single commit `2678b94` touching 4 source files and 4 specs. Probes ran on a `git archive 2678b94` copy (`scratchpad/review-ui/repo2`, `node_modules` symlinked). The worktree was not written to; HEAD is `2678b94` and the tree is clean.

### Evidence
- The SBDEV-3672 specs pass: **67/67** across 4 suites. The new `serviceLogsGetLogDetail.spec.js` is included.
- The full Jest suite passes with coverage off: **135/135 suites, 2436/2436 tests**.
- ESLint on the 4 changed source files: 0 errors.
- Re-ran my 8 round-1 mutants plus 18 new ones, using `--coverage=false` and the matching spec. **26/26 were killed.**

| Mutant | Result |
|---|---|
| X1 BOL-switch guard removed | killed (3 red) |
| X2 outer button `:disabled` removed / X2b dialog button `:loading`+`:disabled` removed / X2c re-entry guard removed / X2d re-fetch not awaited | killed ×4 |
| X3 chunk off-by-one | killed |
| X4 watcher message/dialog reset removed | killed |
| X5 HTTP 2xx caption removed | killed |
| X6 success toast removed | killed |
| X7 `outboxId` passed instead of `lastMessageId` | killed (control) |
| X8 seq increment moved after the null-id return | killed |
| X9 gate drops TRANSFER / X10 gate removed | killed ×2 |
| X11 tooltip never shown | killed |
| X12 `requeueing` made global | killed (3 red) |
| X13 message not cleared at requeue start | killed |
| X14 `facility` not put on the link | killed |
| D1 `$router.replace` removed / D5 replace drops the other query keys | killed ×2 |
| D2 facility check disabled | killed |
| D3 dialog opens on null details | killed |
| D4 numeric check removed | killed (4 red) |
| S1 `getLogDetail` un-awaited again | killed |
| S2 404 "not found" text dropped | killed |
| S3 status GET toasts again | killed (5 red) |
| S4 requeue 4xx detail not quoted | killed |

### Per-finding verdicts

| Finding | Verdict | Note |
|---|---|---|
| M1 double requeue | **FIXED** | `confirmRequeue` refuses re-entry (`requeueing` check). The dialog's Requeue button is `:loading`/`:disabled`. The dialog closes only after the POST settles. The re-fetch is awaited inside `try`, and the flag is released in `finally`, so the stale `failed>0` status can no longer re-offer the button. X2/X2b/X2c/X2d are all killed |
| M2 status GET toasts | **FIXED** | `getBolOmsStatus` is silent on every failure (`logApiFailure`, returns null). S3 is killed |
| M3 deep-link unhandled rejection | **FIXED** | See "M3 blast radius" below |
| M4 R-9 tooltip | **FIXED** | It shows when `failed>0 \|\| resendConfirmed>0`, and the text covers gap (1). Gap (2), a failed final link, is not named separately, but the text's operational advice ("still reads as failed; use Requeue") applies to it too. Acceptable |
| M5 unpinned behaviours | **FIXED** | All 7 round-1 survivors are now killed |
| L1 `?messageId` persists | **FIXED** | `$router.replace` keeps the other query keys (D5 is killed) and swallows a rejected replace |
| L2 label wording | **FIXED** | Now "Delivered (HTTP 2xx)" |
| L3 stale `requeueMessage` | **FIXED** | |
| L4 component-wide flag | **FIXED** | `requeueingId` plus a per-BOL computed. X12 is killed |
| L5 wasted GET on open BOLs | **FIXED** | See "L5 predicate" below |
| L6 store error idiom | **FIXED** | `logApiFailure` + `adminWriteError(error).message` for non-409 requeue failures. `vue-toasted`'s `innerHTML` sink is escaped centrally in `plugins/toast.js` (SBDEV-3207), so quoting the server's text is safe |
| L7 `href="#"` | **PARTIAL (accepted)** | A real `href` now exists. But an open-in-new-tab click never commits tab 6, so `admin.vue` opens the persisted tab. `v-tab-item` is lazy, so the Service Log pane mounts only when the operator selects it. At that point the query is still present and the dialog opens. The fixer documents this, and fixing it properly would mean changing `admin.vue`, which is outside plan §6. I am not blocking on it |
| L8 not warehouse-scoped | **FIXED** | See "L8 facility param" below |

### Specific checks requested

**M3 blast radius (`store/admin/serviceLogs.js` `getLogDetail` → `async`/`return await`).**
- The only production caller is `serviceLog.vue` `showDetails` (`git grep getLogDetail`, excluding tests and cypress). That function serves both the table's "Show Details" eye icon and the new deep link. No other component, store or plugin dispatches it.
- Eye-icon behaviour change. Before, a failing GET was an unhandled rejection: no toast, and the dialog stayed shut because the `await` threw. Now it shows a toast ("Service log message N not found" on a 404, the generic text otherwise) and no dialog. That is strictly better.
- Success behaviour is unchanged. `MessageService.getMessageDetails` (origin/develop `:243-244`) throws `EntityNotFoundException` for an unknown id and otherwise always returns a non-empty map. So the new `showFullDetails = !!this.details` can only suppress the dialog on the failure path, never on a 200.
- `adminWriteError` sets `gone` only for a 404 (`util/apiError.js:178`), so the "not found" text cannot appear on a 401/403/5xx.
- The deep link's `.catch` on `showDetails` is now effectively unreachable, because `getLogDetail` never rejects. It is a harmless backstop and cannot produce a double toast.

**L5 predicate (CLOSED/TRANSFER gate).**
- It matches the backend. `WmsConstants.BillOfLadingState` (origin/develop `:270-275`) is `CREATED, OPEN, TRUCK_LOADING, TRANSFER, CLOSED, CANCELLED`. `runShippingPhase` (`BillofladingService.java:448-450`) sets `TRANSFER` for `TRANSFER_INTRACOMPANY` and `CLOSED` otherwise, and `:1596` later moves TRANSFER → CLOSED on acceptance.
- `getBolDetails` emits `details.put("state", bol.getState())` (`:234`), the same raw strings the gate compares.
- The gate is the plan's Fix B-3 predicate, "NOT_SHIPPED (BOL not CLOSED/TRANSFER)", exactly. CANCELLED, CREATED, OPEN and TRUCK_LOADING never fetch.
- Note: `TRANSFER` BOLs appear in the **open** list (`BillOfLadingController:571-575`), so `pages/outbound/outbound-bol/open/_id.vue` does fetch for them. That is correct, because a TRANSFER BOL has sent its notification.
- The fixer's backstop spec ("CLOSED-looking BOL answered NOT_SHIPPED → hidden") keeps the server-side branch reachable. Good catch on their part.

**L8 `facility` query param.**
- Nothing else in the app reads `$route.query.facility`. `git grep` over components, pages, layouts, middleware, plugins, mixins, store and util finds only the new writer at `outboundBolDetails.vue:311`, plus an unrelated request-body field in `inboundBolUpload.vue:153`.
- The warehouse switcher reads only the store and localStorage (`store/index.js:69,331`), never the query, so the param **cannot switch the user's facility**. It is only compared against `$store.state.selectedWarehouse`, the same string written into the link.
- No other `/admin` deep link exists to be consistent with. This is the first one.
- The mismatch toast interpolates the URL-supplied `facility`, which passes through the escaping `$toast` wrapper, so there is no HTML sink.
- A link without `facility` is still honoured, which is backward compatible.

### New findings (round 2)

#### [LOW] N1: a hung requeue POST traps the operator in the persistent dialog
File: `components/outbound/bol/outboundBolDetails.vue:159-169`
Confidence: MEDIUM

The dialog is `persistent`, and both Cancel and Requeue are now `:disabled="requeueing"` until the POST *and* the re-fetch settle. No axios request timeout is configured (`nuxt.config.js` and `plugins/axios.js` have none apart from the Keycloak ready barrier). If the API hangs, for example a requeue UPDATE stuck behind a lock with no `lock_timeout`, the modal cannot be dismissed until the browser's socket timeout fires. Browser back and reload still work.

`closeBolPop` has the same shape, and its close icon at `:15` is not disabled, which is the difference.

**Fix (optional):** leave Cancel enabled. With the re-entry guard and the per-BOL `requeueingId`, closing the dialog mid-flight is safe, and the result handler already tolerates it. Alternatively, pass `{ timeout: 30000 }` on the requeue `$post`.

#### [LOW] N2: `$router.replace` can briefly drop the `search` param written by `SearchUrlSync`
File: `components/admin/serviceLog/serviceLog.vue` (`openDeepLinkedMessage`)
Confidence: LOW

`mixins/searchUrlSync.js` writes `?search=` with `window.history.replaceState`, which bypasses vue-router, so `$route.query` does not contain it. The `$router.replace({ query: rest })` therefore rewrites the URL without `search`. The keyword watcher's 300 ms debounce normally re-adds it after `initList` assigns the keyword, and the table's filter comes from the store, not the URL. The effect is cosmetic at most.

**Fix:** none needed. Optionally, build `rest` from `new URL(window.location.href).searchParams`.

### Round 2 counts
- Round-1 findings: 12 FIXED, 1 PARTIAL (L7, documented and accepted), 0 NOT FIXED.
- New: 0 High, 0 Medium, 2 Low (N1 MEDIUM confidence, N2 LOW confidence).

### Round 2 recommendation
**APPROVE.** There are no High or Medium findings. Under Nam's fix-every-Low rule, N1 is a two-attribute change, dropping `:disabled` from Cancel, and can go in the same pass. N2 needs no change. L7's remainder needs `admin.vue` to read a tab from the query, which is outside this ticket's file list and a candidate follow-up if new-tab use matters.

---

## Round 3 (scoped, head 00a4634)

Scope: `git diff 2678b94..00a4634`, a single commit touching `serviceLog.vue`, `outboundBolDetails.vue` and 2 specs. Probes ran on a `git archive 00a4634` copy (`scratchpad/review-ui/repo3`). The worktree was not written to; HEAD is `00a4634` and the tree is clean.

### Evidence
- The 2 touched specs pass (56/56).
- The full Jest suite passes with coverage off: **135/135 suites, 2438/2438 tests**.
- vue-router in the tree is **3.6.5**.
- 10 new mutants were run, and **9 were killed**:

| Mutant | Result |
|---|---|
| U1 replaceState removed (nothing stripped) | killed (3 red) |
| U2 `facility` not stripped | killed |
| U3 reverted to `$router.replace({query:{}})` | killed (3 red) |
| U4 strip moved after the numeric check (non-numeric id left in the URL) | killed |
| **U5 `replaceState(window.history.state, …)` → `replaceState({}, …)`** | **survived**, see R3-L2 |
| U6 strip *all* params (`url.search = ''`) | killed (2 red). The `search` survival is pinned |
| U7 facility mismatch check disabled | killed |
| N1a Cancel `:disabled="requeueing"` restored | killed |
| N1b late result re-opens the dialog | killed |
| N1c late result dropped when the dialog was cancelled | killed |

### Q1: are N1 and N2 fixed?

- **N1: FIXED.** Cancel no longer has `:disabled`. The dialog's Requeue button stays `:loading`/`:disabled`, and the outer Requeue button stays disabled while `requeueingId` is set, so cancelling cannot lead to a second POST. The late result still lands: a toast or inline message, then a re-fetch. The dialog is not reopened (N1b killed). The new spec pins all of this: Cancel enabled, confirm disabled, dialog gone after Cancel, outer button still disabled, one success toast and exactly 2 status fetches after the result.
- **N2: FIXED.** `search` written by `SearchUrlSync` outside vue-router now survives (U6 killed).

### Q2: `history.replaceState` leaves `$route` out of sync with the address bar

It does. After the strip, `$route.query` (and `$route.fullPath`) still hold `messageId`/`facility`, while the address bar does not. I checked whether that matters today:

- **Can anything put `messageId` back in the URL or reopen the dialog?**
  - The only consumer of `messageId` is `openDeepLinkedMessage()`, which runs once in `mounted`. A `git grep` for `route.query`, `fullPath`, `router.replace/push`, `router.go` and `location.reload` over components, layouts, store, plugins and pages finds no consumer on the `/admin` path apart from this one. The only other hit is `require-function` middleware's `route.path || route.fullPath`, which reads the path for authorization only.
  - A **tab switch** inside `/admin` does not remount ServiceLog: a `v-tab-item` stays alive once booted, and `admin.vue` never reads or writes the query.
  - `SearchUrlSync` builds its URL from `window.location`, not `$route`, so its debounced writes keep the stripped URL.
  - An **in-app navigation** to `/admin` from the menu while already there is a different route from vue-router's view (its query differs), so a navigation happens to plain `/admin`. The page component is reused (no `watchQuery`), so there is no remount and no reopen.
  - A navigation to any other page leaves `/admin` entirely.

  Verdict: there is no reintroduction path today. The divergence becomes a defect only if a future `/admin` component rebuilds the URL from `$route.query`, for example `$router.replace({ query: { ...this.$route.query, x } })`. That would put `messageId` back in the address bar, so a refresh would reopen the dialog.
- **Back/Forward behave sanely.** `replaceState` rewrites the *current* history entry in place. The stack is `[BOL detail, /admin(stripped)]`. Back goes to the BOL detail. Forward pops to `/admin`, vue-router's popstate handler resolves the location from `window.location` (no query), and ServiceLog mounts with no `messageId`, so the dialog does not reopen. Refresh also lands on the stripped URL.
- **Is the `SearchUrlSync` precedent really the same?** Only half. `SearchUrlSync` *adds* a key vue-router does not know about, so `$route` under-reports. This change *removes* keys vue-router does know about, so `$route` over-reports. That direction is the riskier one, because code that trusts `$route.query` will see stale values. Today nothing on `/admin` reads them after `mounted`, so it is benign, but the comment's claim of "the same mechanism" undersells the difference. See R3-L1.

### Q3: are the rewritten round-1 URL specs weaker?

No. They are stronger. Round 1 asserted a mechanism: a mocked `router.replace` was called with `{query:{search:'abc'}}`. The mock never touched the URL, so a correct call with wrong effects would still pass. The rewritten specs:

- seed the real jsdom URL first (`setUrl`) and assert the resulting `window.location`;
- reset the URL in `afterEach`, so tests do not leak state into each other;
- assert `router.replace` is **not** called.

None is vacuous. U1 turns all three red. U2 and U6 kill the `facility` and `search` pieces. U4 kills "strip the non-numeric id too". The "keeps search" spec on its own would pass under a `$router.replace` mock, but it also asserts `toBe('?search=xyz')`, and U3 leaves `messageId` behind, so it goes red.

One gap: U5 survives. The specs do not pin that vue-router's `history.state` is preserved (R3-L2).

### Q4: does N1's late-result handling race?

Traced with `requeueingId` and the `id !== this.outboundBolId` guard:

| Sequence | Outcome |
|---|---|
| Cancel → result lands (same BOL) | The dialog stays closed (the assignment is already `false`), then message or toast, then re-fetch. Pinned by the new spec and N1b/N1c |
| Cancel → switch to B → A's result lands | The watcher already cleared the message and dialog and started fetching B. A's handler returns at the id guard, and `finally` clears `requeueingId` only if it is still A. Nothing leaks onto B. The same code path is pinned by the round-1 X1 specs (×3) |
| Cancel → switch to B → requeue B → A lands → B lands | B's confirm sets `requeueingId = B`. A's `finally` leaves it alone (≠ A), and B's `finally` clears it. Correct |
| Cancel → switch to B → back to A while A's POST is in flight | `requeueing` is true again for A, so the button is disabled. A's result applies to A, and the sequence guard orders it against the watcher's own re-fetch. Correct |
| A in flight → switch to B → **requeue B** → back to A while A's POST is still in flight | `requeueingId` is now B, so A's button is **enabled** and a second POST for A is possible. The server is idempotent (`NONE` "nothing failed"). This window exists only because `requeueingId` holds one id. It is not introduced by N1, since a BOL switch closed the dialog in round 2 too |

There is no race that matters. The last row is the edge noted as R3-L3.

### New findings (round 3)

#### [LOW] R3-L1: the comment says "same mechanism" as `SearchUrlSync` but not why the divergence is safe
File: `components/admin/serviceLog/serviceLog.vue:288-291`
Confidence: MEDIUM

After the strip, `$route.query` keeps `messageId`/`facility`. Nothing reads them after `mounted` today, but a future `/admin` change that does `$router.replace({ query: { ...this.$route.query, … } })` would write `messageId` back to the address bar, and a refresh would then reopen the dialog.

**Fix:** extend the comment along these lines: "`$route.query` still carries messageId/facility after this; nothing on /admin reads them past mounted — do not rebuild /admin URLs from `$route.query`." A code alternative is to build the new query from `window.location` and pass it to `$router.replace`, which would keep both views in sync.

#### [LOW] R3-L2: preserving vue-router's `history.state` is unpinned
File: `components/admin/serviceLog/serviceLog.vue:299`, `test/components/admin/serviceLogDeepLink.spec.js`
Confidence: MEDIUM

Passing `window.history.state` is correct. vue-router 3.6.5 keeps its scroll-restoration `key` in `history.state`, while `SearchUrlSync` passes `{}`, which drops that key (a pre-existing issue). However, mutant U5 (`{}`) survives.

**Fix:** in the L1 spec, `window.history.replaceState({ key: 'k1' }, '', …)` before mounting, then assert `window.history.state` equals `{ key: 'k1' }` afterwards.

#### [LOW] R3-L3: the single-slot `requeueingId` allows a second POST in the A→B→requeue-B→A edge
File: `components/outbound/bol/outboundBolDetails.vue` (`requeueingId`, `requeueing`)
Confidence: LOW

This needs three navigations within one in-flight request. The server answers `NONE`, so it is harmless.

**Fix (optional):** track in-flight ids in an object/Set (`this.$set(this.inflight, id, true)` / `this.$delete`) and compute `requeueing = !!this.inflight[this.outboundBolId]`. Acceptable to decline with a one-line rationale.

### Round 3 counts
- N1 FIXED, N2 FIXED.
- New: 0 High, 0 Medium, 3 Low (R3-L1 MEDIUM confidence, R3-L2 MEDIUM, R3-L3 LOW).

### Round 3 recommendation
**APPROVE.** There are no High or Medium findings. Per Nam's fix-every-Low rule, two quick fixes remain: R3-L1 is a comment and R3-L2 is one assertion. R3-L3 can be fixed or explicitly declined.

---

## Round 4 (scoped, head 938247a)

Scope: `git diff 00a4634..938247a`. It touches `serviceLog.vue` (a comment only), `outboundBolDetails.vue` (the in-flight map) and 2 specs. Probes ran on a `git archive 938247a` copy (`scratchpad/review-ui/repo4`). The worktree was not written to; HEAD is `938247a` and the tree is clean.

### Evidence
- The 2 touched specs pass (58/58).
- The full Jest suite passes with coverage off: **135/135 suites, 2440/2440 tests**.
- ESLint on the 2 changed source files: 0 errors.

### Per-finding verdicts

| Finding | Verdict | Note |
|---|---|---|
| R3-L1 comment on the route/URL divergence | **FIXED** | It states the add-vs-remove difference, that `$route.query` keeps `messageId`/`facility`, the "do not rebuild /admin URLs from `$route.query`" rule, and why `history.state` is passed through |
| R3-L2 `history.state` unpinned | **FIXED** | New spec seeds `{key:'k1'}` and asserts it survives the strip. U5 (`{}`) is now **killed** |
| R3-L3 single-slot in-flight guard | **FIXED** | `requeueingIds` map keyed by BOL id. The new spec walks A → B → requeue B → back to A: A stays disabled, B settling does not release A, and A settling does. V6 ("any key in flight") is killed |

### In-flight map checks

- **Vue 2 reactivity.** The map is declared in `data()` as `{}`, so it is reactive. Writes go through `this.$set(this.requeueingIds, id, true)` and removals through `this.$delete(this.requeueingIds, id)`. Both add or remove the key reactively, so the `requeueing` computed (`!!this.requeueingIds[this.outboundBolId]`) re-evaluates. Mutants V1 (`this.requeueingIds[id] = true`) and V3 (`delete this.requeueingIds[id]`) are both **killed** (3 red each), so the specs do catch the non-reactive forms. When `outboundBolId` is undefined, the lookup is `undefined → false`, which is harmless.
- **Release on every path.** The `$delete` is the only statement in `finally` and is unconditional, so it runs on success, `NONE`, a 409 `{conflict:true}`, a non-409 error (the store resolves `null`), the early `return` when the operator has switched BOL, and a thrown dispatch or re-fetch. The re-entry guard (`if (this.requeueing) return`) allows at most one in-flight entry per id, so an unconditional delete cannot release someone else's request early.
- **Leaks.** A leak is impossible by construction while the delete stays in `finally`. If the component is destroyed mid-flight, the map goes with the instance. A hung POST keeps only that BOL's button disabled, which is intended, and Cancel stays enabled (N1).

### Mutants (round 4)

| Mutant | Result |
|---|---|
| V1 `$set` → plain assign (non-reactive add) | killed (3 red) |
| V2 `$delete` removed (leak) | killed (3 red) |
| V3 `$delete` → `delete` (non-reactive remove) | killed (3 red) |
| V5 release only on the REQUEUE success branch | killed |
| V6 `requeueing` true if *any* BOL is in flight | killed (4 red) |
| V7 `finally` clears the whole map | killed |
| V8 release skipped when a 409/NONE message was set | killed ("clears an earlier requeue message…") |
| U5 `history.state` → `{}` | killed (R3-L2) |
| **V4** release moved from `finally` to the end of `try` | **survived** |
| **V10** release only `if (id === this.outboundBolId)` | **survived** |
| **V11** release only `if (result)`, so a non-409 error (store resolves `null`) leaks | **survived** |

(Two earlier drafts, V9 and V9b, were no-op mutants that did not actually leak. They are discarded and replaced by V11.)

### New finding (round 4)

#### [LOW] R4-L1: release after an error, or after switching away, is correct but unpinned
File: `test/components/outbound/outboundBolOmsStatus.spec.js` (code under test: `outboundBolDetails.vue` `confirmRequeue` `finally`)
Confidence: HIGH

The production code is correct: the `finally` delete is unconditional. But three refactors that would leak an id, and so leave a BOL's Requeue button **disabled until page reload**, all stay green:

- V4: moving the release into `try`;
- V10: guarding it on the BOL still being on screen;
- V11: guarding it on a non-null result.

The concrete failure each mutant represents:

- A requeue that hits a 500 leaves that BOL's button permanently disabled.
- Requeue A, switch to B before A answers, then return to A: A's button is permanently disabled.

The new R3-L3 spec resolves A only while A is on screen, and no spec re-enables after a `null` result.

**Fix (tests only):**
- **(a)** Requeue resolving `null` (the store's non-409 error result): assert the Requeue button is enabled afterwards. This kills V11.
- **(b)** Requeue A, switch to B, resolve A's request while B is shown, switch back to A: assert A's button is enabled and A's status is re-fetched. This kills V4 and V10.

### Round 4 counts
- R3-L1 FIXED, R3-L2 FIXED, R3-L3 FIXED.
- In-flight map: reactive (`$set`/`$delete`), released on every path, no leak.
- New: 0 High, 0 Medium, 1 Low (R4-L1, test-only, HIGH confidence).

### Round 4 recommendation
**APPROVE.** The production code is correct. Under Nam's fix-every-Low rule, R4-L1 is two small spec cases with no code change.

---

## Round 5 (scoped, head af44fcc)

Scope: `git diff 938247a..af44fcc`. **Test-only**: one file, `test/components/outbound/outboundBolOmsStatus.spec.js`, +28 lines. `git diff --quiet 938247a..af44fcc -- components store pages util plugins mixins layouts middleware` exits 0, so there is **no production change**. Probes ran on a `git archive af44fcc` copy (`scratchpad/review-ui/repo5`). The worktree was not written to; HEAD is `af44fcc` and the tree is clean.

- The spec passes at baseline: 46/46.
- **R4-L1: FIXED.** The three surviving mutants from round 4 are now each killed by exactly one new spec:

| Mutant | Result | Killed by |
|---|---|---|
| V4 release moved from `finally` to the end of `try` | killed | "re-enables a BOL's Requeue button when its result landed while another BOL was shown" |
| V10 release only `if (id === this.outboundBolId)` | killed | same |
| V11 release only `if (result)` (leaks on a `null` error result) | killed | "re-enables the Requeue button after a requeue that failed (store resolves null)" |

- **Vacuity: none.** In both specs the button must exist for the test to pass at all: `requeueBtn(...).attributes` throws if the button is missing, and the re-fetched status is `FAILED_38_OF_39`, so the button is rendered.
  - **The `null` spec** also asserts exactly one requeue dispatch.
  - **The switch-away spec** checks four things:
    1. A's result lands while B is shown, which is the early-return path.
    2. Returning to A triggers exactly one new status fetch for A.
    3. The row is rendered.
    4. The button is enabled.
- **Round 5 counts:** 0 High, 0 Medium, 0 Low. No open findings.
- **Recommendation: APPROVE.**
