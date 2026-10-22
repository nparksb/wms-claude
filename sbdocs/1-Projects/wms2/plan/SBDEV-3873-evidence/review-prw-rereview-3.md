---
head: 35555dc
base: abc7710
scope: git show 35555dc (wms2-web-ui worktree .claude/worktrees/wms2-web-ui/SBDEV-3873)
reviewer: independent code + security lane (not the author)
date: 2026-10-22
---

# SBDEV-3873 PR-W — re-review 3 (fix commit 35555dc, M-1 + L-A..L-E)

## Evidence run
- `npx jest` on the 3 touched specs (`noSdrPatchOnAdviceCyclecount`, `inboundNoticesSaveComment`, `closedNoticeDescriptionComment`): 3 suites, 72/72 green at 35555dc.
- I extracted the spec's matcher code (lines 53-211) into a scratch probe and ran it over the real tree: 441 files. The census is exactly `store/admin/shippers.js:63 direct /client/` and `store/common/order.js:15 direct /customerorder/`. That is unchanged, and there are 0 SDR hits. A raw grep for `\w*\s*\(\s*['"`]patch['"`]\s*,` (with no callee exclusion at all) finds 0 occurrences in the scanned tree. So the inverted rule has no false positives on real code today.
- I also ran adversarial probes through `findSdrPatches` / `findPatchCalls` (results below).

## Stage 1: are the fixes correct and complete?
| Finding | Resolved? | Note |
|---|---|---|
| M-1 | Yes | `wmsRequest('PATCH', …)`, a multi-line `wmsRequest(\n 'PATCH',\n …)` and `cy.wms('PATCH', …)` all give SDR = 1. `enclosingCall(text, m.index)` now starts *at* the `(` and takes it as `open` at depth 0, so removing `verbAnchor` is correct. `store.commit ('patch', …)` (with a space), `dispatch` and `$emit` are excluded. The `\b` before `emit` holds after `$`. False positives on hypothetical code all fail closed as census or SDR entries: `recommit(`, `x.includes('patch', 1)`, `$t('patch', …)`, and a parenthesised comma expression. None of these exist in the tree. |
| L-A | Yes | `flushComment` clears the timer, nulls `pendingComment`, then dispatches. Typing on B with a different id flushes A first. After the flush, A's original timer is cleared, so A is not saved twice. |
| L-B | Yes | `beforeDestroy` → `flushComment()`. `this.$store` is fully usable in `beforeDestroy`, because teardown has not started. The payload is captured, so nothing reads the dying instance. With no pending edit nothing is sent (spec covers this). A failed save is not re-queued, because `pendingComment` is nulled before the dispatch, so nothing retries. The toast is global and still shows. |
| L-C | Yes | The 409 copy no longer claims the text is in the box. |
| L-D | Mostly | A `url:` value is preferred, a shorthand gives `<dynamic>`, and the host is stripped. One residual in the new `url:` extraction: see L-F. |
| L-E | Yes | The header lists both desyncs and says they surface as `<dynamic>`. |

Ordering of A then B: A's dispatch starts before B's timer is armed. The two requests are for different ids, so it does not matter which one completes first. Same-id reordering (two in-flight saves to one notice that land out of order) is debounce behaviour that predates this commit, so it is not counted here.

`pendingComment` and `timeout` are non-reactive instance properties and are not declared in `data()`. That is fine and intentional: `timeout` already worked this way.

## Findings

### High
None.

### Medium
None.

### Low

**L-F. `targetPath`'s `url:` capture `[^,}\n]*` stops at the first `}`, which includes the `}` that closes a `${…}`. It also takes the first `url:` anywhere in the call, including one nested in the body.** Confidence: HIGH (measured). This affects the census only. The SDR scan tests the whole call text, so it is unaffected.
File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js`, `targetPath`
```js
const option = /\burl\s*:\s*([^,}\n]*)/.exec(text)
if (option) text = option[1]
```
Measured:
- ``$axios({ method: 'patch', url: `${base}/client/${id}` })`` keys as `<dynamic>`. At abc7710 it keyed `/client/`. The captured text is ``"`${base"``, so the URL path is lost. A prefixed template URL is the most common shape in this repo.
- `$axios({ data: { url: '/x/' }, method: 'patch', url: '/client/' + id })` keys as `/x/`. This is the L-D case ("a body literal mistaken for the URL") again, now through a body key named `url`. If the real `url` is a variable, the call pins `/x/` instead of `<dynamic>`.

Neither case exists in the tree, and both still produce a census entry, so neither causes a silent miss in SDR detection. The cost is mis-keyed or less specific census rows.

Fix: run the `${…}` → `{}` replace *before* extracting `url:`. Prefer a `url:` at the call's top-level object depth, or the last one, over the first match. Add the two inputs above as keying controls.

## Not findings (checked)
- 409 text "Please enter the comment again." does not name the notice. That was an optional suggestion in L-C, and the author's reason for dropping it holds: the store posts `{id, comment}` only.
- Security: there are no new inputs, sinks or authz paths. `flushComment` dispatches the same `{id, comment}` payload as before, through the same `$post('/advice/setComment')`.

## Open questions
None.

## Positive observations
- `flushComment` is a single choke point. Its clear-then-null-then-dispatch order makes it idempotent across the timer, a switch and destroy.
- The new component specs assert both the immediate flush and that nothing repeats afterwards (`advanceTimersByTime(700)` after destroy).
- The default-catch control `myHttp('PATCH', url, body)` pins the inverted rule's intent.

## Counts
High 0 · Medium 0 · Low 1.

## Verdict
**APPROVE.** M-1 and L-A..L-E are resolved, and the real-tree census is unchanged. L-F is a census-keying refinement with no silent-miss path. Per house rule, fix it in the same pass if convenient.
