---
ticket: SBDEV-3470
kind: closing review of the N1–N5 fix round (commit 0385577a, the rewritten PR body, the SBDEV-3418 plan edit)
reviewer: code-reviewer lane (separate from the authoring pass and from review.md, rereview.md and final-round-review.md)
date: 2026-09-23
worktree: .claude/worktrees/wms2-api/SBDEV-3470 @ 0385577a (clean, even with origin/bugfix/SBDEV-3470-correct-truck-loading-fanout-figure)
pr: SiteBossInc/wms2-api#406, OPEN, head 0385577a, 2 commits
prior: review.md (CHANGES REQUESTED), rereview.md (APPROVE + L1–L4), final-round-review.md (APPROVE + N1–N5)
---

# SBDEV-3470: closing review

## 0. Mechanical checks on 0385577a
| Check | Evidence | Result |
|---|---|---|
| Javadoc-only | `git show 0385577a -U0 \| grep '^[+-]' \| grep -vE '^(\+\+\+\|---)' \| grep -vE '^[+-] +\*'` gives no output (exit 1). 1 file, +2/-2, both lines inside the class javadoc | PASS |
| Wrap / `{@code}` intact | The new lines are `parcels, so max 28 for B3+B5 (31 rows locked by explicit FOR UPDATE in` and `total); mean 4.9 parcels / 9.8 B3+B5 acquisitions.`. They contain no `{`, `}`, `<`, `>` or `*/`, so no inline tag is split and the comment cannot close early. The `<li>` still closes at "…SBDEV-3419 closed.</li>" (WriteService:157) | PASS |
| Branch state | HEAD = 0385577a = PR headRefOid. Working tree clean | PASS |

## 1. N1–N5: resolved?
| Prior | Fix as shipped | Verdict |
|---|---|---|
| N1 "31 explicit FOR UPDATE" read as a statement count | WriteService:142-143 *"(31 rows locked by explicit FOR UPDATE in total)"*. The PR body adds *"The gate row is locked twice, so it is 32 statements."* | RESOLVED (small wording nit L3 on the PR sentence) |
| N2 "label-pattern check exists only in … checkPallet" | PR: *"The only check that *rejects* a non-outbound label is `checkPallet`, the server-side check behind `POST /scanPallet` … (PHASE D0's stale-position purge also matches the label against the pattern, but only to decide whether to purge, never to reject.)"* | RESOLVED in substance: it names rejection, calls it server-side and adds the D0 caveat. The fix drops the "on this path" scope the suggested wording had (L1), and the path and "the pattern" are loose (L2, L4) |
| N3 plan :301 put all of ~142 on inbound pallets | :301 now reads *"the ~142 figure summed 70 children from inbound pallets with 88 stockunits from a different, order-bearing pallet"* | **NOT RESOLVED. The fix replaces the claim with a new false one (M1)** |
| N4 "quoted in three javadocs" | PR "What" lists each file's own version | RESOLVED (quotes checked in §2) |
| N5 review history | PR describes three passes with severity counts, says round 2 reviewed an uncommitted tree, and says 0385577a and the body were unreviewed | RESOLVED (checked in §2) |

## 2. Every factual and closed-set statement in the PR body
| Claim | Evidence | Verdict |
|---|---|---|
| "Comment-only fix" / "javadoc lines only; no behaviour change" | §0 on 0385577a. c127c8fc was checked in final-round-review §0 | true |
| WriteService carried *"the full "70 parcels, 88 stockunits, ~142 acquisitions""* | c127c8fc removed: *"measured at <b>70 parcels, 88 stockunits</b> — takes up to ~142 acquisitions"*. The content is right but the quoted string is not verbatim (L5) | true in substance |
| RaceIT: *"3 of them 70 parcels each … roughly 142 lock acquisitions"* | removed: *"3 of them 70 parcels each. A 70-parcel pallet drives roughly 142 lock acquisitions"* | verbatim with an ellipsis |
| ProbeIT: *"bimodal … 3 at 70"* | removed: *"the real distribution is bimodal — 46 pallets …, 31 of them 6 or fewer, and 3 at 70"* | verbatim with an ellipsis |
| IN-000020/21/22: 70 `Case` children, `PutAwayLane`, no orders. 88 stockunits on OUT-100059 (14 parcels). 43 / 14 / 28 / 4.9 | re-derived on Hydra prd in review.md:30-37 and rereview.md:18-19. I did not re-query | supported |
| "Stockunits add no locks. B4 reads them unlocked." | WriteService B4 `stockunitRepository.findByUnitloadId`. The only `ForUpdate` sites in the file are :284, :288, :297, :333, :453 | true |
| "31 rows locked by explicit `FOR UPDATE` in total" | B1 :284 + B2 :288 + B3/B5 max 28 (:297, :333) + gate :453 = 31 distinct rows. There are no other explicit locks on the success path: `transferUnitLoadToLocation`'s BLOCK_REALIGN pre-walk and `processTransfer`'s realign loop are both gated on BLOCK_REALIGN, and `CODE_TRUCK_LOADING` is in `PASS_THROUGH_CODES` (PickLineActivityCodeClassifier:41-45). `processTransfer` uses `findById` / `findByCarrierunitloadId` only. `UnitloadRecordService`, `BillofladingPositionService` and `BasicService` contain no `ForUpdate` or `PESSIMISTIC`. UBS:904/:950 are in `recoverPalletFromNirvana` / label mint, off this path. D0 runs scalar reads and two DELETEs | true |
| "The gate row is locked twice, so it is 32 statements." | PHASE D :453 `locationRepository.findByIdForUpdate(resolvedGateId)`, then `transferUnitLoadToLocation(pallet, gate, false, …)` (:455) runs UBS:243-247 `if (!ignoreLock) { … locationRepository.findByIdForUpdate(destinationLocationId) … entityManager.refresh(destinationLocation); }`. I checked the `refresh`: in Hibernate 6.6.39 (the Boot 3.5.9 BOM) `DefaultRefreshEventListener.doRefresh`:250-266 sees the entry at PESSIMISTIC_WRITE and **downgrades the reload to `LockMode.READ`**, so the refresh is a plain SELECT, not a third `FOR UPDATE`. `lock_timeout` is set once per transaction by `LockTimeoutHibernateJpaDialect`, not per statement | true as a count of `FOR UPDATE` statements (see L3 for wording) |
| "`scanGate` checks only that the pallet label exists" | PHASE A :252 `existsByLabelid`. No pattern check anywhere in `MobileTruckLoadingWriteService` | true |
| "B3 then locks every child before PHASE C rejects a pallet with no orders" | B3 :293-298 has no filter. The order guard `unexpectedUnitLoadDoesNotHaveOrder` is at :394, in PHASE C | true |
| "The only check that *rejects* a non-outbound label is `checkPallet`" | On the truck-loading path, true: `MobileTruckLoadingService.checkPallet`:91-98 throws `noValidString`. scanGate and D0 never reject on pattern. Globally it is false: `MobilePalletizeWriteService`:244, :283, :437, :468 throw the same `noValidString` on the same pair of patterns | true only if read in scope (L1) |
| "the server-side check behind `POST /scanPallet`" | `TruckLoadingController` is `@RequestMapping("/v3/truckLoading")` (:30), and `@PostMapping("/scanPallet")` (:91) calls `checkPallet` (:98). The mobile UI posts `/truckLoading/scanPallet` (wms2-mobile-ui origin/develop `store/truckLoading.js:94`). `/palletizing/scanPallet` also exists | true but truncated (L2) |
| "which the UI calls in the step before `scanGate`. A direct `scanGate` call skips it." | `pages/truck-loading.vue:11-12` imports ScanPallet, then ScanGate. `MobileTruckLoadingService.scanGate` (:166-174) calls the write service directly and never calls `checkPallet` | true |
| "PHASE D0's stale-position purge also matches the label against the pattern, but only to decide whether to purge, never to reject" | `MobileMoveUnitloadService.handleTruckOffLoadingNoClear`:532-570 matches against **two** patterns (the outbound-pallet pattern OR the converted printing pattern), gates only the DELETEs on the result, and has no `throw`. The unconfigured case logs a WARN and returns | true; "the pattern" is singular and has no antecedent (L4) |
| "That gap is recorded on SBDEV-3470 as a separate T1 finding and is not changed here" | final-round-review §4 (ClickUp comment 90110272365251). The diff does not touch logic | supported |
| multi-row finder: no fewer locks, no shorter per-acquisition timeout, needs `ORDER BY id` | rereview.md §2 | supported |
| "`mvn test-compile` is clean" | final-round-review re-ran it at c127c8fc. 0385577a changes two comment lines and adds no `*/`, so compile cannot change | supported |
| Review history: "three independent passes" | review.md, rereview.md, final-round-review.md | true |
| "The first requested changes: 1 High, 1 Medium, 3 Low." | review.md:59, :91, :105, :112, :122. Verdict CHANGES REQUESTED (:154) | true |
| "The second reviewed the fixes as an **uncommitted** tree and approved with 4 Lows." | rereview.md frontmatter "uncommitted". L1–L4 at :52-73. APPROVE (:97) | true. Round 1 was also uncommitted (review.md frontmatter), which the body does not say. That omission does not make anything false |
| "The third reviewed `c127c8fc` as committed, including the fixes for those 4 Lows, and approved with wording-only findings (1 Medium, 4 Low)." | final-round-review frontmatter and summary: MEDIUM 1 (N5), LOW 4 (N1–N4), APPROVE | true |
| "Every number was re-derived against Hydra prd by a reviewer rather than taken from the author." | The data figures (70, 88, 14, 43, 28, 4.9) were re-derived on prd. The lock counts (31, 32, 72) come from the code, not prd, and "32" had not been reviewed at all until now | overreach (L6) |
| "The fixes for the third pass are `0385577a` … and this PR description. **Neither has been reviewed itself.**" | true when written. It is also the only mention of the fix round. The SBDEV-3418 plan edit (N3) is not in the PR, which is acceptable because sbdocs is outside git | true (goes stale once this review lands) |

## 3. Findings

### [MEDIUM] M1: the N3 fix introduces a new false claim, because the ~142 figure did not sum the 88 stockunits
Confidence: HIGH
File: `sbdocs/1-Projects/wms2/plan/SBDEV-3418-mobile-truck-loading-transaction-boundary.md:301`
Snippet: *"the ~142 figure summed 70 children from inbound pallets with 88 stockunits from a different, order-bearing pallet, and stockunits are not locked"*
Issue: 70 + 88 = 158, not 142. The figure's actual derivation is on record at `SBDEV-3418-evidence/arch-target-sequence.md:202`: *"`1 + 1 + 70 + (≤70 orders) ≈ 142` acquisitions"*. That is B1 + B2 + 70 parcels + up to 70 orders (one order per parcel assumed). The 88 stockunits were quoted beside the figure but never added into it. So the sentence swaps "all of ~142 came from inbound pallets" (N3) for a wrong arithmetic story. The real errors in ~142 were (a) the 70-child pallets are inbound and have no orders, so the ≤70 order term is 0 and the scan is rejected at 72, and (b) the 88 stockunits (a different pallet, and unlocked) were cited as though they bore on the count. Part of the blame sits with the prior lane: final-round-review's suggested N3 fix, *"combined an inbound pallet's 70 children with another pallet's 88 (unlocked) stockunits"*, was already loose, and "summed" hardened it into a false claim. Item 6 at :665 does not make this mistake. It says only that the 88 "belong to a different pallet, and stockunits are not locked".
Fix: *"the ~142 figure was B1 + B2 + 70 children + up to 70 orders (arch-target-sequence.md:202), but the 70-child pallets are inbound with no orders (72 acquisitions, then rejected in PHASE C), and the 88 stockunits quoted beside it belong to a different, 14-parcel pallet and are not locked; see item 6"*. It is sbdocs, so a plain edit with no commit. Sibling sweep: `grep -rn "summed\|70 + 88\|70 children" sbdocs/` should find no other copy (this lane found only :301 and :665).

### [LOW] L1: "The only check that rejects a non-outbound label" lost its scope
Confidence: MEDIUM
File: PR #406 body, section "What the comments now say…"
Snippet: *"The only check that *rejects* a non-outbound label is `checkPallet`"*
Issue: This is a closed-set word with no scope. `MobilePalletizeWriteService`:244/:283/:437/:468 reject non-matching pallet labels with the same `noValidString`. `checkPallet`'s own comment says it matches "the palletizing sites" (MobileTruckLoadingService:96). The suggested N2 wording was *"on this path"*, and the shipped text dropped it. The surrounding bullet makes truck-loading the likely reading, which is why this is LOW.
Fix: *"On the truck-loading path, the only check that rejects a non-outbound label is `checkPallet` …"*

### [LOW] L2: "POST /scanPallet" is truncated and ambiguous
Confidence: HIGH
File: PR #406 body, same bullet
Snippet: *"the server-side check behind `POST /scanPallet`"*
Issue: The mapping is `/v3/truckLoading/scanPallet` (TruckLoadingController:30 + :91). `/palletizing/scanPallet` also exists, so the bare suffix does not identify the endpoint. (final-round-review N2 wrote `/mobile/truckLoading/scanPallet`, which is also wrong.)
Fix: `POST /v3/truckLoading/scanPallet`.

### [LOW] L3: "so it is 32 statements" leaves out the unit it is counting
Confidence: MEDIUM
File: PR #406 body, "Why the old figure was wrong"
Snippet: *"The gate row is locked twice, so it is 32 statements."*
Issue: The count is correct for `FOR UPDATE` statements (§2). But the same inner call also issues a third SELECT on the gate (`entityManager.refresh`, UBS:247, downgraded to READ by Hibernate 6.6.39), and the transaction runs other SQL too, so "32 statements" read literally is not a total of anything. This repeats N1's missing-noun problem one sentence later.
Fix: *"The gate row is locked twice (PHASE D, then again inside `transferUnitLoadToLocation`), so it is 32 `FOR UPDATE` statements."*

### [LOW] L4: "against the pattern" is singular and has no antecedent
Confidence: MEDIUM
File: PR #406 body, the parenthetical about D0
Snippet: *"PHASE D0's stale-position purge also matches the label against the pattern"*
Issue: No "pattern" has been introduced at that point. D0, like `checkPallet`, tests two patterns (`STRING_PATTERN_OUTBOUND_PALLET` OR the converted `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL`, MobileMoveUnitloadService:534-563).
Fix: *"…also matches the label against the same two outbound-pallet patterns, but only to decide whether to purge, never to reject."*

### [LOW] L5: the WriteService "quote" in "What" is not verbatim
Confidence: LOW
File: PR #406 body, "What"
Snippet: *"`MobileTruckLoadingWriteService` (class javadoc): the full "70 parcels, 88 stockunits, ~142 acquisitions"."*
Issue: The removed text was *"measured at <b>70 parcels, 88 stockunits</b> — takes up to ~142 acquisitions"*. The other two bullets quote verbatim with ellipses, so the three do not match. The meaning is right, and the corrected javadoc (WriteService:150-151) uses the same condensed form.
Fix: optional. Either `"70 parcels, 88 stockunits — … ~142 acquisitions"` or drop the quotation marks.

### [LOW] L6: "Every number was re-derived against Hydra prd" overreaches
Confidence: MEDIUM
File: PR #406 body, Verification
Snippet: *"Every number was re-derived against Hydra prd by a reviewer rather than taken from the author."*
Issue: 31, 32 and 72 are code-path counts, not prd data. 32 was added in this round and had not been reviewed until now.
Fix: *"Every data figure was re-derived against Hydra prd by a reviewer, and the lock counts (31 / 32 / 72) were re-derived from the code."* Once this review lands, also update the last sentence: *"0385577a and this description were reviewed in a fourth pass (closing-review.md)."*

## Open questions
None. The one item I would have held back as low-confidence, whether `entityManager.refresh` on the gate emits a third `FOR UPDATE`, was settled from the Hibernate 6.6.39 source (it does not).

## Positive observations
- 0385577a is the minimal N1 fix: two comment lines, a named unit, no tag damage. Its commit message states the 31-versus-32 distinction correctly.
- The rewritten PR body fixes N4 properly. It lists each javadoc's own version of the old figure, and the RaceIT and ProbeIT quotes are verbatim.
- The N5 history is accurate down to the severity counts. It also says, unprompted, that the fix round itself is unreviewed, which is exactly the disclosure the "review rounds leave their own fix commits unreviewed" pattern calls for.
- The new N2 text makes three separate claims (rejection is only in `checkPallet`, the check is server-side and reached through the UI's prior step, D0 matches but never rejects), and all three hold against the code.

## Summary
CRITICAL 0 · HIGH 0 · MEDIUM 1 (M1, sbdocs) · LOW 6 (L1–L6, PR-body wording).
N1, N2, N4 and N5 are resolved. 0385577a is javadoc-only and intact. Every statement in the PR body is true, apart from the scoping and wording nits L1–L6.
N3 is not resolved: its fix introduced a new false claim (M1), which this round was asked to rule out. None of the items needs a new commit. M1 is a plain sbdocs edit and L1–L6 are PR-body edits.

CHANGES REQUESTED
