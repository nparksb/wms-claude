# SBDEV-3873 PR-W conformance review (independent lane)

Worktree .claude/worktrees/wms2-web-ui/SBDEV-3873, bcd9c29 over d11d28c, base 98accaf.

## Verdict: PASS (confidence high). Blockers 0.

## Evidence (run fresh)
- 3 PR-W specs: 3 suites, 17/17 pass.
- Full `npx jest --coverage=false`: 138 suites, 2465 tests pass (report baseline 135/2448 + 3/17 new).
- Grep after change: no `$patch`/patchAdvice/patchCycleCount on /advice/ or /cyclecount/ in store, components, pages, plugins, mixins, cypress. Only remaining /advice/ item call is `$delete` at inboundNotices.js:197 (S9, out of scope).
- Only remaining `saveComment` dispatcher is closedNoticeDescription.vue:243 -> receiving/inboundNotices/saveComment.

## Rows
| Row | Status | Evidence |
|---|---|---|
| S1 inboundNotices.saveComment -> POST /advice/setComment {id, comment} | VERIFIED | diff store/receiving/inboundNotices.js: `$post('/advice/setComment', { id: data.id, comment: data.comment })` |
| S2 delete cycleCount.saveComment + comment watcher | VERIFIED | diff removes both; cycleCountItem watcher, mounted, setInitialComment kept; textarea still readonly (line 57) |
| S3 delete patchAdvice | VERIFIED | removed from wmsHelpers.js; unused import removed from inbound-receiving.cy.js; grep finds none |
| S4 delete patchCycleCount + P1.5 PATCH step | VERIFIED | removed; P1.5 now GET detail only; header line removed. Cypress not run (out of scope), parse-check claimed only |
| Fix B maxlength="255" on closed-notice textarea | VERIFIED (by diff) | closedNoticeDescription.vue:101. No Jest asserts it (plan lists it under Fix B, not an AC) |
| AC-W1 | VERIFIED | inboundNoticesSaveComment.spec: POST called once with exact args, $patch never, extra fields not forwarded, error toast kept |
| AC-W2 | VERIFIED | plannedCycleCountDescription.spec: mount, await $nextTick, advance 700 ms, dispatch not called; module exports no saveComment |
| AC-W3 | VERIFIED | noSdrPatchOnAdviceCyclecount.spec: fs walk of store/components/pages/plugins/mixins/layouts/middleware/util (superset of plan's store+components), template literal, + concat, next-line, /v3 forms, 6 positive and 3 negative controls, walk-reach check; scan empty |
| Mutant w1 (restore $patch) | VERIFIED (report, not re-run) | report: AC-W1 x3 and AC-W3 red. Not re-run here (no-edit rule); the red-on-unfixed commit d11d28c result in the report is consistent with the spec content |
| Mutant w2 (restore watcher) | VERIFIED (report, not re-run) | report: AC-W2 (1)(2) red. Spec asserts dispatch not called after 700 ms, so the mutant is structurally caught |

## Gaps
- Low: maxlength has no automated assertion (plan has none either).
- Low: w1/w2 kill results are the implementer's claims; I did not re-run mutants (editing forbidden). Spec logic makes them credible.
- Note (not a defect): gate P1 (PR 1 served on PRD) must hold before merging PR-W; outside this lane.
- Note: closed-notice open still echoes a save (accepted by plan, AC-2b on API side).

## Recommendation: APPROVE
