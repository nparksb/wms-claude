---
ticket: SBDEV-3490
lane: independent RE-REVIEW of the review-fix commit (second pass)
reviewer: oh-my-claudecode:code-reviewer
date: 2026-09-24
worktree: .claude/worktrees/wms2-api/SBDEV-3490
branch: bugfix/SBDEV-3490-shipped-source-guard
scope: cd7b7b72 (on top of 01225d91, 06503426, already approved in code-review.md)
remote_head: cd7b7b72 (git ls-remote and PR #413 headRefOid agree)
verdict: APPROVE
---

# SBDEV-3490: re-review of cd7b7b72

This was a read-only pass, and no file in the worktree was touched. `git status --short` was clean before and after.

**Evidence collected in this pass**
- `pgrep` found no Maven or surefire process running. I then ran `mvn -o -q test -Dtest=MobileMoveUnitloadServiceUnitTest` at HEAD `cd7b7b72`: 57 tests in 9 nested classes, 0 failures, 0 errors. `$ScanDestination` ran 9 tests. The surefire XML lists `scanDestination_shouldReportShipped_whenShippedSourceIsAlsoOnHold` and `scanDestination_shouldRefuse_whenSourceIsAFixedAssignedUnitLoad`, so the new test really ran. I did not rely on the outer class's `Tests run: 0` report for this.
- dev DB (`wms2-wineco-dev`), queried again to match the repository's own label join. Results under item 4.
- I did not mutate any files (not allowed). The two mutant kills below are checked by reading the code, not by running the mutants.

## Summary
**Files reviewed:** 3 (1 main comment, 1 IT javadoc and display name, 1 unit test)
**Findings:** High 0 · Medium 0 · Low 5

## 1. Does each change resolve the finding it claims?

| code-review.md finding | review-fixes.md action | What the diff does | Verdict |
|---|---|---|---|
| Medium: shipped unit load as container destination | Disproved on dev, not proposed | No code change | Holds. See item 4 |
| L1: stale SBDEV-2995 sentinel comment, dead `:NNN` refs | Rewritten as history | Refs removed. The comment is now past tense and names SBDEV-3490 | Resolved. One ambiguity, see R-L3 |
| L2: AC-6a javadoc contradicted itself; display name said "rolls back" | Javadoc past-tensed, display name changed, method name kept | Matches | Resolved. Method name, see R-L4 |
| L3: `handleTruckOffLoading` comment said "rolls the move back out of Shipped" | "rolls that move back" | `MobileMoveUnitloadService.java:512-513` matches. Lines 516-518 still correctly say a Shipped pallet is refused earlier | Resolved, and now accurate |
| L4: fixed-assignment check not pinned before the branches | `verify(locationRepository, never()).findByName("PALLET-9")` | `MobileMoveUnitloadServiceUnitTest.java:680` | Resolved. See item 2 |
| L5: nothing pinned "Shipped before ON_HOLD" | New test | `:684-691` | Resolved. See item 2 |
| L6: Nirwana case covers only the location branch | No change | None | Matches the reviewer's "Fix: none required". The stated rationale is slightly inaccurate, see R-L5 |
| L7: message exposes `Location.toString()` | No change | None | Matches the reviewer's "none in this ticket" |
| L8: guard block duplicated | Declined, with reason | None | The reason is sound: the order differs and `scanUnitLoad` does not need to change |

No finding was silently dropped. All 9 findings have a disposition, and every disposition matches the diff.

## 2. The new and changed assertions

**`verify(locationRepository, never()).findByName("PALLET-9")`** (`:680`) kills the mutant and is not vacuous.
- The resolver is a pass-through (`@BeforeEach sbdev3134_resolverPassesIdentifiersThrough`, `:127-132`). So `scanDestination:342` calls `locationRepository.findByName(dto.getDestinationLabel())` with exactly `"PALLET-9"` on every path that gets past `:336`. In the unmutated flow that call really happens, which is the positive control.
- The mutant moves the check into the container `else` arm, just before `:459`/`:472`. It must run after `:342`, so `findByName("PALLET-9")` is invoked and `never()` fails with `NeverWantedButInvoked`. That matches the author's reported kill message.
- On brittleness: it pins "before the destination is resolved", which is stricter than "before every mutating branch". A later refactor that legitimately hoists the destination lookup above `:336` would turn it red even though the guard would still be correct. The comment at `:678-679` states that intent, so this is acceptable. See R-L2.

**`scanDestination_shouldReportShipped_whenShippedSourceIsAlsoOnHold`** (`:684-691`) is sound and attributable.
- Same object: `sbdev3490Fixture` stubs `when(unitloadRepository.findByLabelid("CASE-1")).thenReturn(Optional.of(source))` (`:596`). `thenReturn` hands back the same `Optional` instance each time. So the test's call returns the very `source` that `scanDestination:301` will later receive, and `setEntityLock(ON_HOLD)` overwrites the fixture's SHIPPED (405) lock on that object. The source location stays `SHIPPED_LOCATION_ID`.
- Discriminating: all three pre-existing Shipped cases use lock 405, so none of them can reach the ON_HOLD branch. This test is the only one that separates the two orders.
- Mutant (location checks moved below `:324-326`): the ON_HOLD check fires first with `"Unit load is locked on hold!"`, and `assertRefusedBeforeAnyWork`'s `hasMessageContaining("Can not move unit load from")` fails. The failure is attributable, as the author reported.
- The remaining fences (`never(findByUnitloadId)`, `never(doesUserHaveAccess)`, `verifyNoInteractions(...)`) also hold, because both orders throw before the stock load.
- On style: the test calls a stubbed method on the mock from test code. That is legal, but the call is recorded as an invocation on the mock. It would inflate any later `verify(unitloadRepository, times(1)).findByLabelid(...)`, and under STRICT_STUBS it marks the `:596` stub as used even if the service stopped calling it. Neither applies today. See R-L1.

## 3. Rewritten comments, javadoc and display name
- `MobileMoveUnitloadService.java:511-518` is accurate now, and nothing in it is false.
- IT javadoc (`MobileMoveUnitloadClosedBolPurgeIT.java:130-138`): "Originally the Fix C throw rolled the move back out of Shipped; see the SBDEV-3490 note". This is accurate and no longer contradicts the next paragraph. The display name "is rejected before the move" is accurate.
- The method name `selectDestinationOfShippedPalletIsRejectedAndRollsBack` was kept so that SBDEV-3487 citations stay stable. That is acceptable, because a rename would silently break `-Dtest=` citations and evidence greps. It does now say "RollsBack" while the display name says the opposite. See R-L4.
- Sentinel test comment (`MobileMoveUnitloadServiceUnitTest.java:402-406`): see R-L3.

## 4. The disproof of the Medium: it holds (dev only)
- `BillofladingPositionService.assertPalletNotAssignedToGate(label)` → `BillofladingPositionRepository.getBySourceUnitLoadLabelId` (`BillofladingPositionRepository.java:44-48`):
  `select bp.* from billoflading_position bp left join unitload u on bp.source_id = u.id where u.labelid = :labelId`.
  So it matches every position whose **source unit load has that label**. The author's `bp.source_id = u.id` probe is a sufficient condition: if the unit load itself is a position's source, its own label matches. Because `unitload.labelid` is not unique (tote reuse), the label match can only refuse *more* destinations than the id match, never fewer. The disproof's direction is therefore safe.
- I re-measured the same population with the repository's label semantics on `wms2-wineco-dev`, 2026-09-24:
  `total_on_shipped 411896 · no_pos_by_label 0 · null_label 0`.
  So every unit load on Shipped, parents and children alike, would be refused by `assertPalletNotAssignedToGate` as a container destination. It checks positions in any state, not only CLOSED.
- Caveat (carried from review-fixes.md): this was measured on dev only. The Hydra prd count was not taken. A tenant that moves unit loads to Shipped without creating a BOL position would reopen the question. That limitation is honest and already recorded, so it is not a blocker.

## 5. PR #413 body
- "Independent code review: APPROVE" is a mild overclaim. That verdict covered `01225d91..06503426`. The PR head is `cd7b7b72`, whose added assertions had not been reviewed until this pass. See R-L5b; after this report it is true in substance, but the body should say so.
- "Full `mvn clean verify`: unit tests 7,028 run / 0 failed; ITs 514". `full-verify-run2.txt` agrees, and run 1 had 7,027. The +1 is consistent with the new ON_HOLD test being present in the working tree during run 2, before it was committed at 13:29. However, the body does not say which SHA the suite ran on, and no suite run is recorded against the committed `cd7b7b72`. The commit changes only comments, a display name and unit-test code, all re-run green in this pass, so the risk is negligible.
- "Hand mutants … fixed-assignment check moved into one branch; location checks moved below ON_HOLD, all killed". This is consistent with item 2, but true only as of `cd7b7b72`.
- "was disproved on dev … so `assertPalletNotAssignedToGate` already refuses them". Accurate for dev. It drops review-fixes.md's "prd not measured" caveat. Minor.
- Everything else I checked in the body matches the code: the three source checks, their placement, the reuse of lookups, and the AC-6a/6b coupling.

## Findings

[LOW] R-L1. Test mutates the fixture by calling the stubbed mock from test code
File: `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileMoveUnitloadServiceUnitTest.java:688-689`
Confidence: HIGH
Issue: this works and is correct today. But it records an extra `findByLabelid("CASE-1")` invocation on the mock, and it satisfies the strict stub at `:596` from test code, which would hide an unused-stub signal.
Fix (optional): have `sbdev3490Fixture` expose the source `Unitload` (return a small record, or add a `sourceLock` parameter), and set the lock on that reference.

[LOW] R-L2. `never(findByName("PALLET-9"))` pins more than the invariant
File: `MobileMoveUnitloadServiceUnitTest.java:680`
Confidence: MEDIUM
Issue: the invariant is "refused before any mutating branch". The assertion pins "before destination resolution". A harmless hoist of `:342` would turn it red.
Fix: none needed. The comment states the intent, and the stricter pin is cheap insurance. Parameterizing over `AISLE-01 / FLOW-01 / PALLET-9` would pin the real invariant, if ever wanted.

[LOW] R-L3. Rewritten sentinel comment still implies reservations were checked before the stock load
File: `MobileMoveUnitloadServiceUnitTest.java:404-405`
Confidence: MEDIUM
Issue: "checked only ON_HOLD and reservations before stockunitRepository.findByUnitloadId(...)". `checkReservedStock` runs after the stock load (`MobileMoveUnitloadService.java:340` vs `:328`), and the same comment says so a few lines down ("which checkReservedStock then walks a second time"). The ambiguity is inherited from the original, but the rewrite was the moment to remove it.
Fix: "…checked only the unit load's ON_HOLD before loading its stock (findByUnitloadId), then stock ON_HOLD and reservations over that list."

[LOW] R-L4. IT method name contradicts its display name
File: `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileMoveUnitloadClosedBolPurgeIT.java:141`
Confidence: HIGH
Issue: `…IsRejectedAndRollsBack` versus "is rejected before the move". Keeping the name for citation stability is a valid trade-off, and I accept it.
Fix (optional): add a one-line comment above the method, "name kept for SBDEV-3487 citations; nothing rolls back since SBDEV-3490", so the next reader does not "fix" it.

[LOW] R-L5. Evidence and PR wording
Files: `sbdocs/.../SBDEV-3490-evidence/review-fixes.md` (L6 row); PR #413 body, "Evidence" section
Confidence: HIGH
Issue:
- (a) review-fixes.md L6 says the Nirwana check "is the same code line as the Shipped check". They are two adjacent `if` blocks (`MobileMoveUnitloadService.java:316-318` and `:320-322`), not one line. The conclusion still stands because the block is straight-line and ahead of every branch.
- (b) The PR body's "Independent code review: APPROVE" refers to a review of the pre-fix head. It does not name the SHA the full suite ran on, and it omits the prd-not-measured caveat.
Fix: amend the PR body's review line, e.g. "code review of 01225d91..06503426: APPROVE; re-review of review-fix cd7b7b72: APPROVE (re-review.md)". Add "full suite on working tree = cd7b7b72 content" (or re-run on the SHA) and "(dev only; prd not measured)". Fix the L6 wording in review-fixes.md.

## Open questions (non-blocking)
- None at CRITICAL or HIGH.

## Positive observations
- Both new assertions discriminate. Each is the only thing that kills its mutant, and each fails with a message that names the cause, not with a wrong-reason throw.
- The fixed-assignment pin uses an existing, unconditional call site (`:342`) as the ordering witness. That is cheaper and more robust than parameterizing three fixtures.
- The comment fixes are exact: each stale premise is removed, and none is replaced with a new overclaim, apart from the inherited ambiguity in R-L3.
- The Medium disposition used a positive control (411,896/411,896) and recorded its own dev-only limit.

## Recommendation
**APPROVE.** There are no High or Medium findings. All five findings are Low: R-L3 and R-L5 are worth a quick touch-up under the address-Lows rule, while R-L1, R-L2 and R-L4 are optional.
