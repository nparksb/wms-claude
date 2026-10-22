---
ticket: SBDEV-3470
kind: independent review of the final fix round (L1–L4 plus rewraps), committed as c127c8fc
reviewer: code-reviewer lane (separate from the authoring pass, review.md and rereview.md)
date: 2026-09-23
worktree: .claude/worktrees/wms2-api/SBDEV-3470 @ c127c8fc (clean, even with origin/bugfix/SBDEV-3470-correct-truck-loading-fanout-figure)
pr: SiteBossInc/wms2-api#406, OPEN, base develop, head c127c8fc, 1 commit
prior: review.md (CHANGES REQUESTED), rereview.md (APPROVE, with Lows L1–L4)
---

# SBDEV-3470: review of the final round

## 0. Mechanical checks
| Check | Evidence | Result |
|---|---|---|
| Javadoc-only | `git show c127c8fc -U0 \| grep '^[+-]' \| grep -vE '^(\+\+\+\|---)' \| grep -vE '^[+-] \*'` returns nothing (exit 1). 3 files, +36/-16 (rereview saw +34/-16, so the delta is the L1/L3 edits and the rewraps) | PASS |
| Compiles | `mvn -o -q test-compile` in the worktree, exit 0 (the concurrent Maven was PIT in the SBDEV-3361 worktree, which uses a separate `target/`) | PASS |
| Rewraps did not break the javadoc | Every added line balances `{`/`}`, so no `{@code …}` is split across lines. `<b>…</b>` pairs sit on single lines. The one `<li>`…`</li>` spans the bullet and is closed at "…SBDEV-3419 closed.</li>" | PASS |
| Branch state | HEAD = c127c8fc = PR head. Working tree is clean | PASS |

## 1. L1–L4: resolved?
| Prior | Committed text | Verdict |
|---|---|---|
| L1 broken sentence | WriteService: *"⚠ An earlier revision said a successful scan could reach "70 parcels, 88 stockunits, ~142 acquisitions". That was wrong three ways: …"* This is the suggested fix, word for word, and it parses | RESOLVED |
| L2 "(31 in total)" unscoped | *"so max 28 for B3+B5 (31 explicit FOR UPDATE in total)"*. The "explicit" qualifier excludes D0/PHASE D implicit row locks, which was the point of the finding. The author did not name the implicit locks (the fix offered that as an option), which is acceptable. See N1 for a residual counting ambiguity | RESOLVED (N1 is a new nit) |
| L3 ProbeIT had no lock caveat | *"Those three were inbound receiving pallets with no orders. scanGate rejects them, but only after B3 has locked all 70 children (see the "Fan-out" note in {@code MobileTruckLoadingWriteService})."* | RESOLVED |
| L4 SBDEV-3418 plan remedy | :665 adds *"The remedy below is corrected too: a multi-row locked finder does not reduce the lock count or the per-acquisition timeout (it saves only round trips), and it would need `ORDER BY id` inside its query."* :301 adds *"today … a property of the data, not a bound"* | RESOLVED (N3 is a new nit at :301) |

## 2. New wording, closed-set words checked against the code
| Claim | Code | Verdict |
|---|---|---|
| "B3 takes one acquisition per child … B5 one per distinct order" | WriteService:293-298 loops `findByIdForUpdate` over `findIdsByCarrierunitloadIdOrderById` (no filter). :310-334 builds a `TreeSet` of order ids, then loops `customerorderRepository.findByIdForUpdate` | true |
| "On top of those come B1 (BOL), B2 (pallet) and PHASE D (gate)" | :283 `billofladingRepository.findByIdForUpdate`, :287 `unitloadRepository.findByLabelidForUpdate`, :452 `locationRepository.findByIdForUpdate(resolvedGateId)` | true |
| "31 explicit FOR UPDATE in total" (max) | 1+1+28+1 distinct rows. I checked for other explicit locks on the success path: `transferUnitLoadToLocation` (UnitloadBusinessService:221-341) locks only the gate again at :245 (ignoreLock=false). The BLOCK_REALIGN pre-walk lock is unreachable because `CODE_TRUCK_LOADING` is in `PASS_THROUGH_CODES` (PickLineActivityCodeClassifier:45). `processTransfer` (:522-) uses `findById` / `findByCarrierunitloadId` only. `BillofladingPositionService.createEntity` does no locking. `BasicService.generatePositionNumber` is a pure `String.format`. D0 `handleTruckOffLoadingNoClear` (MobileMoveUnitloadService:532-570) does scalar reads and two DELETEs (implicit locks, which "explicit" excludes) | true as a count of distinct rows locked. As a count of statements it is 32 (N1) |
| "B4 and B6 are unlocked" | B4 `stockunitRepository.findByUnitloadId` (:306), B6 `customerorderPositionRepository.findByOrderId` (:341) | true |
| "B3 locks EVERY child before PHASE C looks at orders" | B3 :293-298, PHASE C order check :385-396 | true |
| "this method checks only that the pallet label exists" | PHASE A :251 `existsByLabelid`. There is no pattern rejection in scanGate. D0 pattern-matches the label, but only to decide whether to purge, and it never rejects | true in context (the pallet-acceptance gate) |
| ProbeIT "only after B3 has locked all 70 children" | PHASE A checks only that the label, BOL and gate exist. The gate-mismatch and BOL-state guards are both in PHASE C (:346-379), which comes after B3. So with any existing BOL and gate, all children are locked first. Each IN- pallet has exactly 70 children (review.md:36; rereview: max 70, three ≥70) | true |
| "a 70-case inbound pallet: 72 acquisitions" | B1+B2+70. B5 = 0 because there are no orders. The throw at :393 comes before D0/D | true (unchanged, and rereview checked it) |
| "43 pallets, max 14, mean 4.9 / 9.8" | re-derived from prd in both review.md and rereview.md (46 / 43 / 14 / 28 / 4.88 / 9.77) | supported |

No new false quantitative claim.

## 3. Findings (all new, all LOW)

### [LOW] N1: "31 explicit FOR UPDATE" drops its noun, so it can be read as a statement count, which is 32
Confidence: MEDIUM
File: `src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingWriteService.java` Fan-out bullet: *"so max 28 for B3+B5 (31 explicit FOR UPDATE in total)"*. The same wording appears in the commit message ("(31 explicit FOR UPDATE)") and the PR body ("(31 explicit `FOR UPDATE`)").
Issue: The javadoc counts *acquisitions* (distinct rows), and read that way 31 is right. But a reader who counts `FOR UPDATE` *statements* (the natural reading of "31 explicit FOR UPDATE") gets 32, because `transferUnitLoadToLocation(..., false, ...)` re-issues `findByIdForUpdate` on the gate (UnitloadBusinessService:245). That re-lock cannot block, since the row is already held (the javadoc at WriteService:447-450 says so), so nothing is unsafe. Only the phrase is ambiguous. RaceIT's wording ("31 counting B1, B2 and the gate") avoids this.
Fix: *"(31 explicit `FOR UPDATE` row acquisitions in all; the gate's re-lock inside `transferUnitLoadToLocation` holds a row already taken)"*, or just *"31 row locks counting B1, B2 and the gate"*. Leave the commit message alone, since it is pushed. The PR body can be edited.

### [LOW] N2: "the label-pattern check lives/exists only in … checkPallet" overstates slightly
Confidence: MEDIUM
Files: commit message *"the label-pattern check lives only in the UI flow's checkPallet"*; PR body *"The label-pattern check exists only in the UI flow's `checkPallet`."*
Issue: "only" is a closed-set word. On this same path, D0 (`MobileMoveUnitloadService.handleTruckOffLoadingNoClear`:534-563) also matches the pallet label against `STRING_PATTERN_OUTBOUND_PALLET` / the printing pattern. It uses the result to decide whether to purge, never to reject. Also, `checkPallet` is a server method (`MobileTruckLoadingService`:83-98, behind `POST /mobile/truckLoading/scanPallet`) that the UI flow calls. It is not UI code. The javadoc itself says it correctly (*"What keeps inbound pallets away in practice is the UI flow's {@code checkPallet} label-pattern check"*). Only the commit and PR summaries widen it to "only".
Fix: in the PR body, write *"The only label-pattern **rejection** on this path is `MobileTruckLoadingService.checkPallet`, reached through the UI's scanPallet step. scanGate itself never rejects on pattern."* Do not amend the commit.

### [LOW] N3: SBDEV-3418 plan :301 attributes all of ~142 to inbound pallets
Confidence: HIGH
File: `sbdocs/1-Projects/wms2/plan/SBDEV-3418-mobile-truck-loading-transaction-boundary.md:301`: *"the ~142 figure came from inbound pallets, see item 6"*
Issue: Only the 70 came from an inbound pallet. The 88 stockunits came from `OUT-100059`, an order-bearing 14-parcel pallet, and stockunits are not locked at all. Item 6 (:665) says this correctly, so :301 now contradicts its own pointer.
Fix: *"the ~142 figure combined an inbound pallet's 70 children with another pallet's 88 (unlocked) stockunits; see item 6"*. It is sbdocs, so a plain edit.

### [LOW] N4: Commit message and PR body say all three javadocs "quoted" the 70/88/~142 figure
Confidence: HIGH
Files: commit message *"The "70 parcels, 88 stockunits, ~142 acquisitions" worst case quoted in MobileTruckLoadingWriteService, MobileTruckLoadingRaceIT and MobileTruckLoadingLockOrderProbeIT"*; PR body *"Corrects the "70 parcels, 88 stockunits, ~142 acquisitions" worst-case lock fan-out quoted in three javadocs"*
Issue: The removed lines show that ProbeIT quoted *"bimodal — 46 pallets …, 31 of them 6 or fewer, and 3 at 70"*, with no 88 and no ~142. RaceIT quoted *"3 of them 70 parcels each … roughly 142"*, with no 88. Only WriteService carried the full triple. All three were wrong and needed the correction, so the scope is right, but "quoted in" three places is not literally true.
Fix: in the PR body, write *"…the false fan-out figure (70 / 88 / ~142, or '3 at 70, bimodal') quoted in three javadocs"*. Do not amend the commit.

### [MEDIUM] N5: PR body's review history leaves out that the approval predates the committed text
Confidence: HIGH
File: PR #406 body, Verification: *"Review: two independent review passes, the first requesting changes and the second approving."*
Issue: rereview.md reviewed an **uncommitted** working tree (its frontmatter says "uncommitted"). It approved *with four Lows*, and the author then edited the text to address them (L1–L4 plus two rewraps) before committing c127c8fc. When the PR was opened, the text actually in the PR had not been reviewed by anyone, so the sentence implies a review of the PR's content that had not happened. This is the "review rounds leave their own fix commits unreviewed" pattern. It is not a code defect, but it is a claim the review evidence did not support. (The other half, *"Every number was re-derived against Hydra prd by the reviewer"*, is supported: review.md:30-37 and rereview.md:18-19.)
Fix: *"Review: three independent passes. Round 1 requested changes (1 High, 1 Medium, 3 Low). Round 2 approved an uncommitted tree with 4 Lows. Round 3 reviewed c127c8fc (the Low fixes) and approved with 4 wording Lows (N1–N4) plus this note."* Update it again if N1–N4 lead to a new commit.

## 4. Other PR-body claims checked
| Claim | Evidence | Verdict |
|---|---|---|
| `IN-000020/21/22` each hold 70 `Case` children, sit in `PutAwayLane`, no orders | review.md:36 | supported |
| 88 stockunits belong to `OUT-100059`, 14 parcels | review.md:30,37 | supported |
| "B4 reads them unlocked" | WriteService:306 | true |
| "43 pallets, max 14, max 28, mean 4.9" | review.md + rereview.md prd queries | supported |
| gap "recorded on SBDEV-3470 as a separate T1 finding and is not changed here" | ClickUp SBDEV-3470 comment 90110272365251: *"Added finding (from the review lane). Sub-T3 … T1 … NOT implemented under this re-scope"*. The diff does not touch scanGate's logic | true |
| multi-row finder / `ORDER BY id` / plan order | rereview.md §2 (Postgres LockRows above Sort) | supported |
| "`mvn test-compile` is clean" | re-run here, exit 0 | true |
| "javadoc lines only; no behaviour change" | §0 | true |

## Positive observations
- All four Lows were fixed as asked. L1 and L3 use the suggested wording verbatim, and L3's new caveat is accurate: every guard that could reject before B3 (gate mismatch, BOL state) is actually in PHASE C.
- The "explicit" qualifier on 31 is the right, minimal scoping. I traced the whole success path (D0, `transferUnitLoadToLocation`, `processTransfer`, `createEntity`) and found no explicit lock beyond the 31 rows.
- The rewraps are clean: no split inline tags, and the diff stays comment-only.
- The sbdocs correction at :665 now covers the remedy as well as the figures, and keeps the original text flagged as history.

## Summary
CRITICAL 0 · HIGH 0 · MEDIUM 1 (N5, PR-body wording only) · LOW 4 (N1–N4, wording).
L1–L4 are all resolved. The commit is javadoc-only, compiles, and adds no false claim to the code. The remaining items are in the
PR body (N2, N4, N5; editable without a commit), one javadoc phrase (N1, optional) and one sbdocs line (N3, plain edit).
None blocks the code. By standing policy, fix N1–N5 in the same pass. Only N1 needs a commit, and N5's wording should then be updated.

APPROVE
