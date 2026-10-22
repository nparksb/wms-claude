---
head: abc7710
base: 1b6c084
scope: git show abc7710 (wms2-web-ui worktree .claude/worktrees/wms2-web-ui/SBDEV-3873)
reviewer: independent code + security lane (not the author)
date: 2026-10-22
---

# SBDEV-3873 PR-W — re-review 2 (fix commit abc7710, L-1..L-5)

## Evidence run
- `npx jest test/store/noSdrPatchOnAdviceCyclecount.spec.js test/store/receiving/inboundNoticesSaveComment.spec.js test/components/receiving/closedNoticeDescriptionComment.spec.js`: 3 suites, 62/62 green at abc7710.
- I extracted `stripComments` from the spec and ran it over all 441 scanned `.js`/`.vue` files (scratch probe, not committed). Results: 0 files end with an unterminated string state. 0 non-comment lines containing `patch` were blanked. The only blanked lines that do not start with a comment marker are the interior of a real CSS `/* … */` block (`replenishViewTable.vue:324-328`), which is correct.
- I ran adversarial inputs through `findSdrPatches` and `findPatchCalls` (results inline below), plus the same `wmsRequest` input against the 1b6c084 matcher for comparison.
- Census pins: `store/admin/shippers.js:63` and `store/common/order.js:15` are the actual `$patch` lines.

## Stage 1: does each claimed fix resolve its finding?
| Finding | Resolved? | Note |
|---|---|---|
| L-1 capture at input time | Yes | `onCommentInput(value)` captures `id` and `value`. Vuetify 2 `VTextField` emits `input` with the new `internalValue`, the same payload `v-model` consumes, so `value` is the new text. The new spec covers a switch at 300 ms that saves `{id:7, 'fragile'}` and nothing for 8. Residuals: L-A, L-B. |
| L-2 single 403 toast | Yes | Reuses `util/authzDenied.isAuthzDenial`, the same helper `plugins/axios.js` uses. It is case-insensitive over header keys and also handles `Headers.get`. `retryCondition` runs on the first failure (`retries: 3`), so the axios toast always fires before the store sees the rejection. A header-less 403 still toasts. Both branches are tested. |
| L-3 copy | Yes | 422 now names the missing-id case. 409 no longer advises "reload". See L-C for one edge. |
| L-4 census by (file, path) | Yes | `censusDiff` is a multiset comparison and prints `unexpected file:line path` / `missing file:line path`. Renaming a variable or reformatting the call no longer fails it. See L-D. |
| L-5 comment stripping + verb arm | Partly | The quote-aware strip is sound on the real tree. Narrowing the positional arm to `cy.*` opened a blind spot that 1b6c084 did not have: see M-1. |

## Findings

### High
None.

### Medium

**M-1. The narrowed positional arm makes the exported `wmsRequest('PATCH', …)` / `omsApiRequest('PATCH', …)` helpers invisible to both instruments. This is a regression from 1b6c084.** Confidence: HIGH.
File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js` (`VERB_PATCH`)
```js
const VERB_PATCH = /method\s*:\s*(['"`])patch\1|\bcy\.(?:wms|oms|omsApi|request)\s*\(\s*(['"`])patch\2\s*,/gi
```
`cypress/support/api/http.js:32` and `:50` export `wmsRequest(method, path, opts)` and `omsApiRequest(method, path, opts)`. These are the functions `cy.wms` and `cy.oms` wrap, and `cypress/` is in `SCANNED_DIRS`, so a spec or helper can import them and call them directly. Measured results:
- At abc7710, `wmsRequest('PATCH', '/advice/' + id, { body })` gives `findSdrPatches` = 0 and `findPatchCalls` = 0. Neither the SDR scan nor the census sees it, so the miss is silent.
- At 1b6c084, the same input gave `findSdrPatches` = 1.

The author's survey is correct that no such call exists today (`commands.js` passes the `method` variable). So this is a forward blind spot, not a current miss. It is still a loss in the instrument that backs AC-W3, and the header's "not covered" paragraph does not list it.

Fix: either add `wmsRequest|omsApiRequest` to the allowlist (`\b(?:cy\.(?:wms|oms|omsApi|request)|wmsRequest|omsApiRequest)\s*\(`), or invert the rule: keep the generic positional arm and exclude only the known non-request callers (`commit|dispatch|\$emit`). Add a positive control `wmsRequest('PATCH', '/advice/' + id)`.

### Low

**L-A. Typing on notice B within 700 ms of the last keystroke on notice A cancels A's pending save.** Confidence: HIGH (by reading).
File: `components/receiving/closed/closedNoticeDescription.vue`, `onCommentInput`
```js
const id = this.noticeDetails && this.noticeDetails.id
clearTimeout(this.timeout)
```
There is one timer per component instance, and the instance outlives a notice inside the v-dialog. Sequence: type on A, close, open B, type on B, all inside 700 ms. The `clearTimeout` drops A's pending `{id: A, value}`, and A's edit is lost silently. The window is very narrow, since it needs a close, an open, the details load and a keystroke, which makes this Low. Fix: if a save is pending for a different id, dispatch it immediately before scheduling the new one. Store `this.pending = { id, comment }` and flush it when `pending.id !== id`. Alternatively, flush in the `noticeDetails` watcher before `setInitialComment()`. A test would extend the new switch spec with a `setValue('x')` on B before 700 ms, then expect saves for both 7 and 8.

**L-B. `beforeDestroy` cancels a typed edit. Now that the payload is captured, flush is the better choice.** Confidence: MEDIUM (a product-judgement call).
File: `components/receiving/closed/closedNoticeDescription.vue`
```js
beforeDestroy() {
  clearTimeout(this.timeout)
},
```
On `pages/receiving/closedNotice/_id.vue`, a user who types the last characters and clicks the breadcrumb within 700 ms loses those characters, with no toast. Before abc7710, cancel was the safe choice because the timer read `this.noticeDetails` and `this.comment` at fire time. Since L-1, the timer closure carries `{ id, comment: value }`, and `$store.dispatch` and `$axios` do not depend on the destroyed instance. A failure toast is global, so it still shows after the user navigates away. Flushing on destroy therefore has no stale-target risk and preserves user input.

Dialog close is unaffected: the v-dialog keeps the component mounted, so the pending save still fires after close, which is the desired behaviour.

Recommendation: in `beforeDestroy`, clear the timer and dispatch the pending payload if one exists. Change the spec "leaving the page before 700 ms cancels the pending save" to expect exactly one save carrying the typed text. If the team prefers cancel, document it as deliberate in the component comment, since it is a silent data-loss path.

**L-C. The 409 copy "Your text is still in the box" is wrong when the save belongs to a notice the user has already left.** Confidence: HIGH (by reading).
File: `store/receiving/inboundNotices.js`
```js
409: 'Comment not saved: the notice was changed at the same time. Your text is still in the box; edit it to save again.',
```
After L-1, a save can complete after the dialog shows another notice, and then the box holds B's comment. The toast also does not say which notice failed. This is rare. Fix (optional): pass the notice number into `saveComment` and name it in the message (for example, "Comment for IB-7 not saved: …"), or drop the "still in the box" clause.

**L-D. `targetPath` takes the first literal path anywhere in the call text, not specifically from the URL.** Confidence: HIGH.
File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js`, `targetPath`
- For a verb-form call, the text is the whole enclosing call, so `$axios({ data: { note: '/x/' }, method: 'patch', url })` pins `/x/` instead of `<dynamic>`. A dynamic URL then hides behind a literal from the body.
- An absolute URL pins its host. Measured: `'https://h/advice/'` → `/h/advice/`, and `'https://wms.example/…'` would key as `/wms`.

Both are census-only and still fail closed for a new site. Fix (optional): for verb-form calls, prefer the `url:` value when one is present, and strip a leading `scheme://host` before matching.

**L-E. Residual stripComments false negatives in the SDR scan, both caught by the census.** Confidence: HIGH (measured).
- `const re=/['"]/; this.$axios.$patch('https://h/advice/'+id,b)`: the quote in the regex desyncs the pass, and the URL's `//` is blanked. SDR = 0, census = `<dynamic>`.
- `` this.$axios.$patch(`${b ? `https://x` : ''}/advice/${id}`, body) ``: the nested backtick inside `${}` desyncs the pass. SDR = 0, census = `<dynamic>`.

Both need an absolute URL with `//` in it, and both still surface as an unexpected `<dynamic>` census entry, so the miss is not silent. The other cases I tested were handled correctly:
- escaped quotes (`'it\'s'`)
- `${"'"}` inside a template
- an inline `/*x*/`
- a regex containing a backtick on an earlier line (fails closed: the rest of the file reads as a string, so nothing is blanked)
- an unpaired backtick in Vue template text followed by `accept="image/*"`

Fix (optional): add the two inputs above to the header's "not covered" paragraph so the census entry is read with that in mind.

## Open questions
None.

## Positive observations
- L-1 is the minimal correct change: capture at input time. The new spec asserts both the box swap (`'dock 9'`) and the single save to id 7.
- L-2 reuses the shared, case-insensitive `isAuthzDenial` instead of re-planting `headers['x-authz-denied']`, and it keeps a message for a header-less gateway 403, so the user is never left without feedback.
- `stripComments` keeps offsets and newlines, so line numbers stay correct, and quote state resets at newline for `'`/`"`. Over the real 441-file tree it has zero desyncs.
- The census failure output (`unexpected|missing file:line path`) is directly actionable.

## Counts
High 0 · Medium 1 · Low 5.

## Verdict
**COMMENT.** There is no High or Critical finding. M-1 is a confirmed regression in the AC-W3 instrument, but it is forward-looking: no affected call exists in the tree today. Per house rule, fix M-1 and the Lows in the same pass. M-1 (re-cover `wmsRequest`/`omsApiRequest`) and L-B (flush rather than cancel on destroy) are the two worth doing first.
