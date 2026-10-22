---
ticket: SBDEV-3560
tier: T2 (scope widened by Nam 2026-09-28: the whole family, one PR)
reviewed_commit: 46f2a12 (wms2-web-ui)
date: 2026-09-28
---

# SBDEV-3560: review lanes, round 2 (whole diff)

The lanes could not write files, so the author records their reports here.

## Lane 1: code-reviewer (opus). Verdict: REQUEST CHANGES

**Test teeth.** Every changed component and store file was restored to origin/develop in a scratch copy, then the specs were run against them: 154 of 188 fail. The 34 that still pass are success-path or not-closed-early checks. No refusal assertion passes on unfixed code.

| Sev | Finding | Disposition |
|---|---|---|
| High H1 | `store/admin/user.js#importUser` ignored a 200-with-`errors` body. `UserController.importUser` answers `ResponseEntity.ok(errorMap)` on `ApiMissingUserException`, so the dialog still closed on a refusal | **Fixed** in 34fcbaa. The test was red on 46f2a12 ("Expected: false, Received: true") |
| High H2 | The commit said "the rest of the family", but 7 sites were left: createReplenishmentRequest, updatePriorityPop, updateStockUnitPop, createCycleCount, cancelCycleCountPop, createBol, closeBolPop | Scope is already authorized (whole family). Being fixed in round 3, lanes D/E |
| Medium M1 | A partial batch success left the dialog listing rows that had already been processed. Retrying can never succeed, because the server refuses those rows (close/accept: "Not allowed in state=FINISHED"; cancel replenishment: "Cannot remove active order"; SDR delete: 404). Nothing gets double-processed | **Nam decided 2026-09-28:** stay open only when nothing was applied. If anything was applied, close as on success. For the multi-id `closeInboundBol`, "applied" means errors.length < ids.length. Round 3, lanes D/F |
| Medium M2 | resendConfirmation and createPallet now wait for the server with no spinner, which opens a double-submit window. Resend is not idempotent | **Fixed** in 34fcbaa: spinner in a `finally`. Tests are red on 46f2a12 |
| Medium M3 | The cancelRequestPop partial test only refuses the last item, so a mutant that keeps only the last result survives | Round 3, lane D. The tests now cover first-refused and last-refused |
| Low L1 | A refused transfer activation no longer refreshes the table | No change. It is consistent with club `activateBatch`; it gets a note in the PR |
| Low L2 | Comment density differs by lane: 3–6 line blocks, and one comment spills a single word onto its own line | Round 3, lanes D/E/F: one line per site |
| Low L3 | Three return idioms. The early-return re-indents are diff noise | Round 3 sites use the flag idiom. Sites already reviewed and mutation-checked are left alone: they behave the same, and rewriting them carries risk for no behavioural gain |
| Low L4 | `results.errors` vs `results && results.errors && results.errors.length` | No change. Every controller involved adds `errors` only when there is at least one error |

The reviewer also confirmed which endpoints can answer 200-with-errors: createInboundBol, updateInboundBol, activateTransferOrder, resend, replenish update/cancel, goodsReceiptPosition adjust/delete, section/boxType/client create. The SDR PATCH and DELETE endpoints cannot.

## Lane 2: verifier (sonnet). Verdict: INCOMPLETE (scope), PASS on quality

- All 25 in-scope sites were verified against AC1–AC4. The verifier ran 5 of its own mutants plus corroborating kills from its sub-reviewers, and none survived. Full suite: 1825 pass. The "uncommitted drift" it reported was the author's in-progress H1/M2 work, committed as 34fcbaa.
- The completeness sweep covered components/, pages/, layouts/, mixins/ and store-owned dialog flags. Beyond the reviewer's H2 list it found: gpsTrackerPop, changeLanePop, reprintToteLabel (which also double-toasts), palletizeOutboundParcel (`$emit('clear')` wipes the parent selection on a refusal), and transferPicking/itemsTable runTransfer. It also found that **updateStockUnitPop dispatches `internalOps/replenishments/updateStockUnit`, which does not exist**, so the write never happens at all.
- SAFE / INTENDED: actionConfirmation (background triggers), the export popups, the select-lane/batch reads, the upload popups (their callBack only fires on success), and the store-owned close commits in the success branches of pickPack, fixedLocation and club.
- Blind spots it named: `pages/` was spot-checked rather than exhaustively read; `$refs` composition and dynamically computed action names were not checked.

## Instrument note (carried from round 1)

Rounds 1 and 2 used different instruments and each found sites the other missed. The round-1 hand sweep said it was "not exhaustive" and turned out to be right. Round 3 is fixing the union of both rounds.
