---
ticket: SBDEV-3470
kind: final review of the M1 + L1–L6 fix round (commit a5c46725, the rewritten PR body, the SBDEV-3418 plan edit at :301)
reviewer: code-reviewer lane (separate from the authoring pass and from review.md, rereview.md, final-round-review.md, closing-review.md)
date: 2026-09-23
worktree: .claude/worktrees/wms2-api/SBDEV-3470 @ a5c46725 (clean, even with origin/bugfix/SBDEV-3470-correct-truck-loading-fanout-figure)
pr: SiteBossInc/wms2-api#406, OPEN, head a5c46725, 3 commits, MERGEABLE (CI `test` pending at review time)
prior: closing-review.md (CHANGES REQUESTED: M1 + L1–L6)
---

# SBDEV-3470: final review

## 0. Mechanical checks on a5c46725
| Check | Evidence | Result |
|---|---|---|
| Javadoc-only | `git show a5c46725 -U0 \| grep '^[+-]' \| grep -vE '^(\+\+\+\|---)' \| grep -vE '^[+-] +\*'` gives no output (exit 1). 1 file, +9/-7, all inside the class javadoc's "Fan-out" `<li>` | PASS |
| `{@code …}` intact | The removed and added hunks carry the same inline tags, each opened and closed on one line: `{@code Case}`, `{@code ORDER BY id}`, `{@code FOR UPDATE}`. Added lines with an unclosed `{@code` = 0. The `<li>` still closes at "…SBDEV-3419 closed.</li>" | PASS |
| Compile safety | Added lines containing `*/` or `\u` = 0, so the comment cannot close early and no unicode escape is introduced. The PR's "`mvn test-compile` is clean" therefore still holds | PASS |
| Wrapping | Rewrapped to the paragraph's existing width. The longest changed line is 100 chars. The file already has lines up to 168 chars, so no project limit is newly exceeded | PASS |
| Branch state | HEAD = a5c46725 = PR head. origin/develop has moved (#405, SBDEV-3471) but touches none of the three files. GitHub reports MERGEABLE | PASS |
| Commit message | See §3 | accurate |

## 1. M1 and L1–L6: resolved?
| Prior | As shipped | Verdict |
|---|---|---|
| M1: plan :301 said the ~142 "summed 70 children … with 88 stockunits" | :301 now reads *"the ~142 figure was 1 + 1 + 70 children + up to 70 orders, but the 70-child pallets are inbound with no orders, so on them the scan takes 72 acquisitions and PHASE C rejects it; the 88 stockunits quoted alongside belong to a different pallet, were not part of the sum, and are not locked; see item 6"*. Matches `SBDEV-3418-evidence/arch-target-sequence.md:202` (`1 + 1 + 70 + (≤70 orders) ≈ 142`) and :199-200, where the 88 is quoted in the sentence before the sum and never added into it. Item 6 (:665) is consistent. No other copy of "summed" / "70 + 88" in the plan | RESOLVED |
| M1 sibling in the javadoc (extended by the author) | a5c46725 replaces c127c8fc's "wrong three ways" (which listed "stockunits are not locked" as a reason the figure was wrong, and so implied they were counted) with *"The ~142 was 1 + 1 + 70 children + up to 70 orders … The 88 stockunits were quoted alongside, not summed in."* | RESOLVED, and a correct sibling sweep |
| L1: "the only check that rejects" had no scope | *"**On the truck-loading path**, the only check that *rejects* a non-outbound label is `checkPallet`"* | RESOLVED |
| L2: bare `POST /scanPallet` | `POST /v3/truckLoading/scanPallet` (TruckLoadingController `@RequestMapping("/v3/truckLoading")` + `@PostMapping("/scanPallet")`) | RESOLVED |
| L3: "32 statements" had no unit | *"The gate row is locked twice, so it is 32 `FOR UPDATE` statements."* | RESOLVED |
| L4: "the pattern" singular, no antecedent | *"matches the label against the same two outbound-pallet patterns"*. Checked: `checkPallet` (MobileTruckLoadingService:91-92) and D0 (MobileMoveUnitloadService:534-535) read the same two sysprops, `SYSTEM_PROPERTY_STRING_PATTERN_OUTBOUND_PALLET_KEY` and `SYSTEM_PROPERTY_PRINTING_PATTERN_OUTBOUND_PALLET_LABEL_KEY`, so "same" is true | RESOLVED |
| L5: the WriteService quote in "What" was not verbatim | Now *"measured at 70 parcels, 88 stockunits — takes up to ~142 acquisitions"*. See §2 | RESOLVED |
| L6: "Every number was re-derived against Hydra prd" | Now *"The prd figures (43 / 14 / 28 / 4.9, and the inbound nature of the 70-child pallets) were re-derived against Hydra prd by the reviewers. The 31, 32 and 72 were counted from the code."* The last sentence is updated: *"`a5c46725` and this final description are under a last review pass as of writing."* | RESOLVED |

## 2. PR "What": each old-figure quote against `git show origin/develop:<path>`
| File | PR quote | origin/develop text | Verdict |
|---|---|---|---|
| `MobileTruckLoadingWriteService.java` | "measured at 70 parcels, 88 stockunits — takes up to ~142 acquisitions" | :138-139 `measured at <b>70 parcels, 88` / `stockunits</b> — takes up to ~142 acquisitions` | Word for word. Only the `<b>` markup and the line break are dropped |
| `MobileTruckLoadingRaceIT.java` | "3 of them 70 parcels each. A 70-parcel pallet drives roughly 142 lock acquisitions" | :117-118 `3 of` / `them 70 parcels each. A 70-parcel pallet drives roughly 142 lock acquisitions` | Word for word (joined across a line break) |
| `MobileTruckLoadingLockOrderProbeIT.java` | "the real distribution is bimodal … and 3 at 70" | :119-120 `the real distribution is bimodal — 46 pallets …, 31 of them 6 or fewer,` / `and 3 at 70` | Word for word, with an ellipsis |

## 3. Every other factual claim in (a), (b) and (c)
| Claim | Evidence | Verdict |
|---|---|---|
| ~142 = "1 (BOL) + 1 (pallet) + 70 children + up to 70 orders" | arch-target-sequence.md:202 `1 + 1 + 70 + (≤70 orders) ≈ 142`. The source does not label the two 1s, but in the design they are B1 (Billoflading, WriteService:286) and B2 (pallet, :290) | true |
| "The one error in it: the 70-child pallets are inbound" | `max_parcels_per_pallet` (arch-target-sequence.md:451) counted every carrier, and the 70 came from `IN-000020/21/22` (review.md:36, rereview.md:19). With no orders the "+70" term is 0. The 88 was never a term. The derivation does not include the PHASE D gate lock, but the "≈" absorbs that | true |
| "On those pallets the scan takes 72 acquisitions and then PHASE C rejects it" | B1 :286 + B2 :290 + 70 × B3 :299. B5 :335 locks 0 orders. PHASE C (:347, throw at :396) runs before D0 (:401) and before the gate lock (:455). This matches the re-derivations at rereview.md:26 and final-round-review.md:39 | true |
| "The 88 … belong to a different pallet (`OUT-100059`, 14 parcels), and B4 reads stockunits unlocked" | review.md:30, :37. B4 (:303) is marked unlocked. The only `ForUpdate` sites are :286, :290, :299, :335 and :455 | true |
| 43 / 14 / 28 / 4.9, and "31 rows locked … 32 `FOR UPDATE` statements" | review.md:25-37, rereview.md:18-20, closing-review §2 (31 distinct rows; the gate is locked twice; the refresh is downgraded to READ) | true |
| "The 31, 32 and 72 were counted from the code" | 31 and 72: rereview.md:26, final-round-review.md:39. 32: closing-review §2 | true |
| a5c46725 message: "the retired figure was 1 + 1 + 70 children + up to 70 orders"; "70 + 88 = 158"; c127c8fc's "wrong three ways" wording and its commit message's list of reasons "implied the stockunits had been counted"; "the one real error is that the 70-child pallets are inbound…72 acquisitions and PHASE C rejects it" | c127c8fc's message lists "stockunits (B4) are read unlocked and add no acquisitions" as one of three reasons the figure was wrong. That reason only makes sense if stockunits were in the count, so "implied" is exact. The rest matches arch-target-sequence.md:202 and the code rows above | accurate |
| PR review history, pass 1: "Requested changes: 1 High, 1 Medium, 3 Low." | review.md:150, :154 | true |
| Pass 2: "Reviewed the fixes as an **uncommitted** tree; approved with 4 Lows." | rereview.md frontmatter ("uncommitted"), :93, :97 | true |
| Pass 3: "Reviewed `c127c8fc` as committed; approved with wording findings, 1 Medium and 4 Low. Fixed in `0385577a` and this description." | final-round-review.md frontmatter (head c127c8fc), :95, :100. For the "Fixed in" clause, see F1 | counts true; fix sites incomplete (F1) |
| Pass 4: "requested changes. The Medium was that the ~142 had been misdescribed as including the 88 stockunits, a claim `c127c8fc`'s commit message also makes. Fixed in `a5c46725`, the SBDEV-3418 plan, and this description." | closing-review.md M1 and verdict (CHANGES REQUESTED). The commit-message point is the author's own finding and holds (row above). The six Lows go unmentioned, which is an omission and does not make anything false | true |
| "four independent passes" | review.md, rereview.md, final-round-review.md, closing-review.md, each with a different reviewer lane per its frontmatter | true (this review is a fifth, which the closing sentence anticipates) |
| "`a5c46725` and this final description are under a last review pass as of writing" | this report | true |

## 4. Findings

### [LOW] F1: Pass 3's "Fixed in" line leaves out the SBDEV-3418 plan edit, which is where N3 was fixed
Confidence: MEDIUM
Location: PR #406 body, Verification → Review history, item 3
Snippet: *"Reviewed `c127c8fc` as committed; approved with wording findings, 1 Medium and 4 Low. Fixed in `0385577a` and this description."*
Issue: final-round-review's N3 was about `SBDEV-3418-…transaction-boundary.md:301`, and its fix went into that sbdocs plan, not into 0385577a or the PR body. Read as a complete list, the sentence names the wrong fix sites for one of the five findings. That fix is also the one that failed (closing-review M1). Item 4 does name the plan as a fix site and says what went wrong, so a careful reader can piece it together, and nothing false is asserted about code. That keeps this LOW.
Fix: *"Fixed in `0385577a`, the SBDEV-3418 plan (N3) and this description."* This is a PR-body edit, with no commit and no re-review needed.

## Non-findings (checked, deliberately not raised)
- WriteService:150-151 still quotes the old figure as *"70 parcels, 88 stockunits, ~142 acquisitions"* after *"An earlier revision said a successful scan could reach"*. It is a condensed quote rather than a verbatim one, and it is unchanged from c127c8fc (three passes have seen it). The meaning is right, and a5c46725 now states the derivation right after it, so it does not mislead. closing-review L5 raised the same point only for the PR body, at LOW confidence.
- WriteService:107 *"~88+N extra"* is on origin/develop, sits in a different bullet (the refresh cost, not lock fan-out) and is not touched by this PR. The 88 there is the real max stockunits on an order-bearing pallet (OUT-100059), so it is not an instance of the corrected error.
- The a5c46725 message says "Per the closing review (M1)", although M1 named only the plan line. The javadoc edit applies M1's derivation to a sibling copy, which is the sibling sweep M1 asked for. That is accurate attribution.

## Open questions
None.

## Positive observations
- The author extended the M1 fix from the one sbdocs line the review named to the javadoc and to c127c8fc's commit-message reasoning, both of which carried the same implication. That is a real sibling sweep, not a single-instance patch.
- a5c46725 is minimal and safe: one `<li>`, the tags survive, nothing can close the comment, and the message cites its source (arch-target-sequence.md) and shows the arithmetic (70 + 88 = 158).
- The PR's three old-figure quotes are now all verbatim, and L4's "same two patterns" was written to be true. I checked it against both call sites.
- The review history openly says pass 4 requested changes and that this last pass had not yet reported. That keeps the record honest.

## Summary
CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 1 (F1, PR-body wording, confidence MEDIUM).
M1 and L1–L6 are all resolved. a5c46725 is javadoc-only, keeps every `{@code …}` intact and wrapped, and its commit message is accurate. The three old-figure quotes match origin/develop word for word, and the ~142 derivation matches arch-target-sequence.md:202. The "72 acquisitions" figure and the pass-by-pass review history match the four evidence reports. The one finding is an incomplete fix-site list in the history, not a false figure, and it can be fixed in the PR body without a commit.

APPROVE
