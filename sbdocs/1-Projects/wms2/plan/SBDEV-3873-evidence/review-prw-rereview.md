---
head: 1b6c084
base: bcd9c29
lane: independent re-review (code + security) of the PR-W fix commit
date: 2026-10-22
---
head: 1b6c084

# SBDEV-3873 PR-W — re-review of fix commit 1b6c084

Worktree: `.claude/worktrees/wms2-web-ui/SBDEV-3873`. Scope: `git show 1b6c084`, 8 files, +339/−39.

## Evidence
- `npx jest --coverage=false` (full): **139 suites / 2495 tests passed**, 0 failed.
- The 4 touched specs: 47/47 pass, with **0** `[Vue warn]` lines (L1 fixed).
- `eslint` on the 7 touched source/spec files: 0 errors (42 pre-existing `no-console` warnings in the store module; the watcher's `console.log` is gone).
- Vuetify 2.7.2 source read: `VInput.internalValue` setter is the only path that does `$emit('input')` (VTextField.js:117-124). It runs from `onInput` (native input, so typing, paste and post-composition IME) and from `clearableCallback` (VTextField.js:241-243, which emits `null`). `watch.value` only assigns `lazyValue` (VTextField.js:188, VInput.js:121), so a programmatic `setInitialComment` **does not** emit `input`. The core claim of the redesign holds.
- Server contract read at wms2-api worktree `610fda68`: `AdviceService.setComment` throws 422 for a missing id, >255 or NUL; 404 `EntityNotFoundException`; 409 from `RestExceptionHandler` for optimistic **and pessimistic** lock failures; 403 from `FunctionGuardInterceptor` (`@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL)`).
- Author's mutant table (report §Mutation floor) spot-read against the specs: every listed mutant maps to an assertion that would go red as described.

## Finding-by-finding verification
| Prior finding | Verdict |
|---|---|
| code M1: census claimed, absent | **RESOLVED.** `findPatchCalls` and the `toEqual` census are present, and the header now describes it accurately, including the remaining blind spots. |
| code L1: Vue-warn flood | **RESOLVED.** Stubs added; 0 warnings. |
| code L2: reload untested | **RESOLVED.** `Vue.observable` state, plus a reload test that asserts both `vm.comment` and the rendered value. |
| code L3: generic toast | **RESOLVED** (static per-status messages rather than `parameterErrors[0]`; acceptable). |
| code L4 / security L3: scanner blind spots | **RESOLVED** for (a) to (d), each backed by a positive or negative control. |
| code L5 / security L1: save on open, dropped timer | **RESOLVED.** Watcher removed, saves are `@input`-driven, `clearTimeout` is unconditional, and `beforeDestroy` clears the timer. |
| code L6: inert maxlength=250 | **RESOLVED.** Removed. |
| code L7: Cypress status | **RESOLVED.** `expect(detResp.status).to.equal(200)` after `recordApi` (not run; needs dev + KC). |
| conformance: maxlength unasserted | **RESOLVED.** `attributes('maxlength') === '255'` (falls through the stub's `$attrs`, the same way Vuetify forwards `attrs$` to the native input). |

## Path checks requested
- **Event ordering (v-model vs @input):** not a concern. The handler ignores its argument and reads `this.comment` 700 ms later. Vue 2 also puts the v-model callback ahead of the user listener in the merged `on.input`.
- **Latest value:** read at fire time, so the last edit wins. Covered by the "two edits" test.
- **Paste / IME:** both reach the native `input` handler, then `internalValue`, then `input`. Covered.
- **Programmatic load:** emits nothing (see Evidence). Covered by the open and reload tests. The stub mirrors this, since it emits only on a native input.
- **Clearable icon:** the textarea is **not** `clearable`, so there is no icon. If one were added, Vuetify emits `null` (not `""`) on `$nextTick`. The handler would still fire and save `comment: null`, which the server accepts (`setComment` null-guards both checks and stores NULL). No defect today.
- **beforeDestroy:** correct. `clearTimeout(undefined)` is a no-op. But see L-1: the component is **not destroyed** when the dialog closes.
- **Toast status read:** `error && error.response ? error.response.status : undefined` is safe with no response. The test covers the "Network Error" case.
- **Census:** excludes `test/` (`test/` is not in SCANNED_DIRS). It fails with a `toEqual` diff naming `file target`. See L-3/L-4.
- **Cypress:** see above.

## Findings

### High
None.

### Medium
None.

### Low

**L-1. The pending save reads `noticeDetails.id` and `comment` at fire time. In the dialog host, which outlives a notice, a quick switch to another notice can lose the edit and re-write the new notice's stored comment.** Confidence: MEDIUM.
File: `components/receiving/closed/closedNoticeDescription.vue` (onCommentInput)
```js
this.timeout = setTimeout(() => {
  this.$store.dispatch('receiving/inboundNotices/saveComment', { id: this.noticeDetails.id, comment: this.comment })
}, 700)
```
`closedNoticeDetails.vue` hosts this component inside a `v-dialog`. A Vuetify 2 dialog keeps its content mounted after the first open, so closing the dialog does not run `beforeDestroy`. Scenario: the user types on notice A, closes, and opens notice B within 700 ms, and `getInboundNoticeDetails(B)` resolves inside that window. The `noticeDetails` watcher then runs `setInitialComment()` and sets `comment = B.comment`, and the timer fires `{id: B.id, comment: B.comment}`. A's edit is silently lost, and B receives an echo write: the "write without an edit" this fix exists to stop. The window is narrow, and the same loss existed before. Fix: capture at input time with `onCommentInput(value) { const id = this.noticeDetails && this.noticeDetails.id; clearTimeout(this.timeout); this.timeout = setTimeout(() => this.$store.dispatch(SAVE, { id, comment: value }), 700) }`. Alternatively, flush the pending save (with its captured id) in the `noticeDetails` watcher before `setInitialComment`. Add a test: edit, swap `inboundNoticeDetails` to id 8, advance 700, then expect the save to carry `{id: 7, comment: <typed>}` and no save for id 8. The same capture also removes a latent `TypeError` if `noticeDetails` were ever null when the timer fires.

**L-2. A 403 produces two toasts.** Confidence: HIGH (by reading; not run).
Files: `plugins/axios.js:114-120` and `store/receiving/inboundNotices.js` (the 403 entry)
The axios `retryCondition` already shows `You do not have permission for this action (<fn>)…` for a 403 carrying `X-Authz-Denied`. The rejection then reaches `saveComment`, which adds `"Comment not saved: you don't have permission…"`. The double toast existed before (generic + permission), so this is not a regression, but the new branch makes it read as duplicated. It is also practically unreachable, since a user without `WEB_UI_VIEW_INBOUND_BOL` cannot open the screen; it requires a mid-session revoke. Fix (optional): when `error.response.headers['x-authz-denied']` is present, skip the store toast, or leave as is.

**L-3. The 422 and 409 copy is slightly broader than the API.** Confidence: HIGH.
File: `store/receiving/inboundNotices.js`
```js
422: 'Comment not saved: it is too long or contains an invalid character.',
409: 'Comment not saved: the notice was changed by someone else. Reload and retry.',
```
422 also covers `id is required` (only reachable if `noticeDetails.id` is absent). 409 also covers `PessimisticLockingFailureException` ("currently locked by another operation"). Both are rare and the wording is still actionable. "Reload and retry" discards the user's typed text, because reload re-runs `setInitialComment`. Fix (optional): for 422, prefer the server's message (`error.response.data.parameterErrors?.[0]?.message`), falling back to the static text; for 409, say "Please retry." rather than "Reload".

**L-4. The census key is the call's argument text, not just the file. Benign refactors (renaming `payload`, or reformatting a verb-form call, whose target is the first 120 chars of the squashed enclosing call) fail it.** Confidence: HIGH.
File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js`, in `findPatchCalls` / the census expectation (`'store/admin/shippers.js \`/client/${payload.id}\`'`)
This is intentional, since it forces a re-read, and the failure diff names file plus target. It lacks the line number, so a reviewer has to grep. Fix (optional): include `:line` in the failure output only (for example, a custom message listing `file:line target` for the unexpected entries), keeping the pinned key line-free.

**L-5. Scanner heuristics: limits on the comment filter and the verb arm.** Confidence: HIGH. All fail closed or are documented.
File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js`, `isCommentLine`, `VERB_PATCH`
- `isCommentLine` only skips a match whose line begins with `//`, `/*` or `*`. A trailing `// this.$axios.$patch('/advice/'+id)` after code, or a block-comment interior line without a leading `*`, is still reported. That is a false positive, fail-closed.
- The positional arm `\(\s*(['"\`])patch\2\s*,`/i matches any call whose first argument is the string `'patch'`, e.g. `commit('PATCH', …)` or `$emit('patch', …)`. Such a call lands in the census and needs a manual add. Nothing like it exists today.
- `.patch(` also matches third-party APIs (`jsondiffpatch.patch(`). Census only.
No change needed. Optionally, list the first bullet in the header's "not covered" paragraph.

## Open questions
None.

## Positive observations
- The redesign removes the root cause (the save is now keyed on the user's input, not on model state) instead of special-casing the load, and the Vuetify emit semantics back it up.
- The new component spec is tight: it asserts the absence of a save at 699 ms and its presence at 700, and it filters saves by action name, so unrelated dispatches cannot mask a result.
- The scanner now separates *detection* (the SDR scan) from *inventory* (the census), and the header states honestly what each misses. Its negative controls include the case-sensitivity trap (`/cycleCount/`).
- The mutation table covers every new branch, including census add, removal and expectation-edit mutants.
- The full suite stays green (2495/2495), with no warning noise.

## Counts
High 0 · Medium 0 · Low 5 (L-1 MEDIUM confidence; the rest HIGH).

## Verdict
**APPROVE** (no High/Critical). Every prior finding the commit claims to fix is resolved. Per house rule, address the Lows. L-1 is the one worth doing: capture `id` and the value at input time, plus one test.
