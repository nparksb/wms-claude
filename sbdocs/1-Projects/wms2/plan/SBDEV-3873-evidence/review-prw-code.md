---
head: bcd9c29
reviewer: independent code-review lane (did not author)
date: 2026-10-22
scope: SBDEV-3873 PR-W (wms2-web-ui) — plan §5 Fix B, §8 AC-W1..W3
verdict: APPROVE
---
# SBDEV-3873 PR-W — code review

head: bcd9c29 (d11d28c tests, bcd9c29 change), diff `origin/develop...HEAD`, 10 files, +224/−59.
Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-web-ui/SBDEV-3873`.

## Evidence collected by this lane
- The 3 new specs: 3 suites and 17 tests pass (`npx jest --coverage=false`).
- Full suite at bcd9c29: **138 suites / 2465 tests, all pass.** That matches the implementer's final number; the baseline was 135 / 2448, so the difference is exactly the 3 new suites and 17 new tests.
- Independent mutation run, on a scratch copy with `node_modules` symlinked (the worktree was not touched):

| Mutant | Result |
|---|---|
| `inboundNotices.saveComment` restored to `$patch(`/advice/${data.id}`, data)` | KILLED: AC-W1 and AC-W3 fail (4 tests) |
| `$post('/advice/setComment', data)`, sending the whole body | KILLED: AC-W1 "sends only id and comment" |
| `toast.error` removed from the catch | KILLED: AC-W1 "still toasts" |
| `plannedCycleCountDescription.vue` restored from origin/develop (watcher back) | KILLED: AC-W2 (1) and (2) |
| watcher restored, but dispatching a different action (no PATCH anywhere) | KILLED: AC-W2 (1) and (2). The test pins "no dispatch", not just "no PATCH" |
| `store/internalOps/cycleCount.js` restored from origin/develop | KILLED: AC-W2 (3) and AC-W3 |
| `setInitialComment()` removed from `mounted` | KILLED: AC-W2 (1) display assertion |

## Stage 1: spec compliance (Fix B / AC-W1..W3)
Every Fix B bullet is implemented, and nothing outside it changed:
- `inboundNotices.saveComment` now calls `$post('/advice/setComment', { id: data.id, comment: data.comment })`.
- `maxlength="255"` is on the closed-notice textarea. That one component serves **both** mounts: `pages/receiving/closedNotice/_id.vue` and `closedNoticeDetails.vue`, the dialog. `git grep` finds no other textarea that dispatches `saveComment`.
- `cycleCount.saveComment` and the `comment` watcher are deleted. The textarea keeps `readonly`, and the `cycleCountItem` watcher plus `mounted → setInitialComment` still populate it.
- `patchAdvice` and `patchCycleCount` are deleted, the P1.5 PATCH step is dropped, and the unused import in `inbound-receiving.cy.js` is removed. `git grep` finds no remaining reference to either helper anywhere in the repo.
- AC-W1, AC-W2 and AC-W3 are each present and mutation-proven (table above). AC-W2 awaits `$nextTick()` before `advanceTimersByTime(700)`, which matches the plan.

## Stage 2: findings

### High
None.

### Medium
**M1. The AC-W3 spec's header promises a census that does not exist.** File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js:14-16`. Confidence: HIGH.
> `Not covered: a path held in a variable (\`$patch(url, …)\`) or the \`$axios({ method: 'patch' })\` form. Neither exists in the tree today; the call-site census below lists every \`patch(\` call so a reviewer sees them.`

No census follows: the file has only the matcher-controls `describe` and the scan `describe`, and `grep census` hits only this comment. The comment is how the spec answers its own blind spots, and the answer is false. The failure scenario: a future `const url = '/advice/' + id; this.$axios.$patch(url, body)` passes AC-W3 silently, and a reader trusts that "the census" would have shown it.

Fix, either of:
- Add the census: list every `$patch(` / `.patch(` / `method: 'patch'` call site in the scanned dirs and pin it with `toEqual([...])`. Today that is `store/admin/shippers.js:63` (`/client/`) and `store/common/order.js:15` (`/customerorder/`). A new PATCH caller of any shape then fails until a reviewer adds it.
- Or reword the comment so it no longer claims a census.

The first option also closes the variable-path blind spot (L4).

### Low
**L1. The AC-W2 spec floods the run with ~68 `[Vue warn]: Unknown custom element` errors.** File: `test/components/internalOps/plannedCycleCountDescription.spec.js:15` (`shallowMount(... mocks: {...})`). Confidence: HIGH.

There is no Vuetify instance and no `stubs`, so `<v-card>`, `<v-textarea>` and the rest print `console.error`. The tests still pass. The cost is that a genuine warning (for example a render error after the details object changes) is buried in the noise. Fix: pass `stubs: ['v-card', 'v-card-title', 'v-row', 'v-col', 'v-list', 'v-list-item', 'v-list-item-content', 'v-textarea']`, or install Vuetify the way other `test/components/**` specs do. `opsDialogRefusalSweep.spec.js` and `returnsAuditReport.spec.js` use stubs or Vuetify.

**L2. AC-W2 never tests "still displays the comment after the details object changes".** Same file, `mountWith`. Confidence: HIGH.

`$store` is a plain mock object, not reactive, so replacing `cycleCountFullDetails` would not fire the `cycleCountItem` watcher. Only the first load is covered. The production code for this path is unchanged (`cycleCountItem(newVal) { this.setInitialComment() }`), so the risk is low. Fix: use a real `Vuex.Store` (or `Vue.observable` state), replace the details with `{id: 6, comment: 'x'}`, `await $nextTick()`, then assert `vm.comment === 'x'` and still no dispatch after 700 ms.

**L3. The error toast is still the generic "network or server issue" for 422, 404, 403 and 409.** File: `store/receiving/inboundNotices.js:414` (`this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')`). Confidence: HIGH.

The toast does still surface on every rejection: `$post` rejects on any non-2xx, which the catch handles, and a spec pins it. The text is wrong for the new contract's specific errors:
- 422 for a pasted NUL character, or anything that gets past `maxlength`;
- 409 on a concurrent save (see L5).

The user is told to retry, but a retry of a 422 fails the same way. This is behaviour carried over, not a regression. Fix (optional, could be a follow-up on this ticket): branch on `error.response?.status`. For 422, show `parameterErrors[0]`'s message; for 409, show "Comment changed elsewhere, reload."

On response shape: the old code only `console.log`ged the PATCH result, and no caller reads the action's return value. The single dispatch site at `closedNoticeDescription.vue:243` ignores it. So the new response `{id, comment}` (with `comment` omitted when null) breaks nothing. No finding.

**L4. AC-W3 scanner blind spots beyond the ones it lists.** File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js:28` (`SDR_PATCH`) and `:24` (`SCANNED_DIRS`). Confidence: HIGH.
- (a) The base is interpolated or concatenated before the resource, e.g. `` $patch(`${base}/advice/${id}`) `` or `$patch(API + '/advice/' + id)`. The regex requires the quote to be immediately followed by `/advice/`.
- (b) `$axios.$request({ method: 'patch', url })` and `fetch(..., { method: 'PATCH' })`.
- (c) `cypress/` is not scanned. A `cy.wms('PATCH', '/advice/' + id)` helper was one of the plan's four callers (S3 and S4), and it could come back unseen. AC-W3's stated scope is `store/**` and `components/**`, so this is outside the AC.
- (d) The `/i` flag also matches `/cycleCount/`, the camel-case controller path, so a legitimate PATCH there would false-positive. That is harmless today, because no such call exists.

None of these forms exists in the tree today. The census fix in M1 covers (a) and (b), and adding `'cypress'` to `SCANNED_DIRS` together with a `cy.wms\(\s*['"]PATCH['"]\s*,\s*['"\`](?:\/v3)?\/(?:advice|cyclecount)\/` arm covers (c).

**L5. Pre-existing: the debounce in `closedNoticeDescription.vue` loses its timer handle when the new value is empty, which can now produce a spurious 409 toast.** File: `components/receiving/closed/closedNoticeDescription.vue:236-241`, the `comment(newVal)` watcher. Confidence: MEDIUM.
```js
if (!newVal || newVal.trim() === '') {
  this.timeout = null        // drops the handle…
}
clearTimeout(this.timeout)   // …so the pending save is NOT cleared
```
Failure scenario:
1. The user types, which schedules T1.
2. Within 700 ms they select all and delete, which schedules T2 without clearing T1.
3. T1 and T2 both fire. Both read `this.comment` at fire time, so the body is the same, and they fire close together.

With the new endpoint's optimistic locking (409 on a concurrent save), the second POST can load the row before the first commits. It then sees a dirty value and gets a 409, which shows the generic toast even though the save succeeded. The same bug exists in `plannedCycleCount.vue:251`, `closedCycleCount.vue:234` and `closedReplenishmentRequests.vue:249` (search debounces, which are harmless there). The code is unchanged by this PR, so this is not blocking. Fix: delete the `this.timeout = null` branch and always call `clearTimeout(this.timeout)`, in this component at least. One line, the same file the PR already touches.

**L6. The cycle-count textarea keeps `counter maxlength="250"` while the API limit is 255.** File: `components/internalOps/cycleCount/planned/plannedCycleCountDescription.vue` (`maxlength="250"`). Confidence: HIGH.

The box is `readonly` and now has no save path, so the attribute is inert and misleading. Note for consistency only; no change required.

**L7. The P1.5 Cypress row lost its HTTP status assertion.** File: `cypress/e2e/wms/cycle-count/cycle-count.cy.js:310-331`. Confidence: MEDIUM.

The old step asserted `expect(patchResp.status).to.equal(200)`. The new step only `recordApi`s the GET with `expectedStatus: 200` and reports `INFO` for Location # = 0. It is still meaningful: the GET and the Location # check were the substance of the step, and the PATCH with `{id}` alone was a no-op "activate". But a 4xx or 5xx on the GET now produces an INFO row (`locCount` 0), not a failure, unless `recordApi` enforces `expectedStatus`. Fix (optional): add `expect(detResp.status).to.equal(200)`.

## Open questions (low confidence, not blocking)
- None at High/Critical. One gating item is a merge precondition, not a code finding. The echo-on-open still POSTs on every closed-notice open, so PR-W must not reach any environment before PR 1 (gate G1), or every open toasts a 404/405. That is already the plan's P1 gate.

## Positive observations
- The body is explicitly whitelisted, `{ id: data.id, comment: data.comment }`, not passed through as `data`, and a dedicated test with `externalid: 'EVIL', state: 'OPEN'` pins it. This closes the exact over-binding class the ticket is about.
- AC-W3 reads source with `fs`, so coverage instrumentation (`collectCoverage: true` in `jest.config.js`) cannot defeat it. It walks the filesystem, so `.gitignore` hides nothing. It has both positive controls (literal origin/develop lines) and negative controls, plus a guard that the walk actually reached the former callers (`toContain` of 3 paths and `> 100` files).
- AC-W2 asserts *no dispatch at all* rather than *no PATCH*, so a watcher re-added under another action name still fails (my mutant w2b).
- The removal is complete: no orphan references, the Cypress header endpoint list was updated, and there are no stale PATCH mentions in `docs/`, `README.md` or `CLAUDE.md`.
- The full suite was re-run independently: 138 / 2465 green, exactly the baseline plus the new tests.

## Counts
- CRITICAL 0 · HIGH 0 · MEDIUM 1 · LOW 7.

## Verdict
**APPROVE.** No High or Critical finding at any confidence. Per house rule, fix every finding including the Lows in the same pass. M1 (false census claim) and L5 (one-line debounce fix in a file already touched) are the two worth doing before the PR opens.
