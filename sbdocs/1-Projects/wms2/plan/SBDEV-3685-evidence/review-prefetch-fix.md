---
ticket: SBDEV-3685
type: code-review
reviewer: cr-3685 (independent lane, read-only)
date: 2026-10-13
subject: bc37ad62 "wip" on fix/SBDEV-3685-prefetch-assigned-locations (base origin/develop a4fd6490)
verdict: APPROVE WITH FIXES
---

# SBDEV-3685 code review: query unit loads by assigned location only in the release pre-fetch

**Verdict: APPROVE WITH FIXES.** Findings: 0 High, 0 Medium, 4 Low. None of them blocks the merge. The behaviour change is provably zero, and the query argument shrinks as intended.

I ran no Maven or LSP in the worktree, as the lead asked: a suite is running there. The change only passes a `Set<Long>` to a `Collection<Long>` parameter, so it carries no type risk. Compiling and running the test is left to the suite that is already running.

## 1. Readers of `unitloadsByLocationMap`: the change has no behavioural effect

- Two places touch the map in `ReleaseOrderJobService.java`. Line 328 copies it to the `final` variable, and line 511 reads it: `unitloadsByLocationMapFinal.getOrDefault(assignedLocation.getId(), Collections.emptyList())`. No lambda, helper or other method receives it (grep for `unitloadsByLocationMap`: lines 279, 318, 328 and 511 only).
- The value of `assignedLocation` is `locationMapFinal.get(fix.getAssignedlocationId())`, from line 494. The code throws at line 495 if that is null. So the key read is always a non-null `fix.getAssignedlocationId()` for some fix in `allFixes`, which means it is a member of `assignedLocationIds`.
- `groupingBy(Unitload::getStoragelocationId)` over `WHERE storagelocation_id IN S` gives the same list for every key in S, whether or not S is wrapped in a larger set. Each unit load falls into exactly one group, keyed by its own location. Narrowing S from `allLocationIds` to `assignedLocationIds` therefore leaves every key that line 511 can read unchanged. That covers a fix whose unit load sits at a different fix's assigned location: that location is in `assignedLocationIds` anyway.
- **All the state-57 causes are unchanged:**
  - no stock unit (from `stockunitsByUnitload`, not touched);
  - too many stock units;
  - wrong item;
  - wrong location (`locationMap` still built from `allLocationIds`, lines 302-305);
  - no unit load on the location;
  - more than one unit load on the location;
  - a label that does not match the location name.

  The last three read the map, and only by the assigned key.
- One consequence worth recording: whenever the unit load's current location differs from its assigned location, the wrong-location check at line 498 `continue`s before line 511. So the extra ids the old code added could never have been read by that fix. Their only effect was the cost of the query.

## 2. Edge cases

- **FLA with null assigned location and non-null UL.** Before the fix, the UL's location went into `allLocationIds` and was queried. Now it is not queried. In both versions line 494 does `locationMap.get(null)`, gets null, and line 495 throws `EntityNotFoundException`. Behaviour is identical, and on PRD it cannot happen: 0 of 1,555 FLAs have a null `assignedlocation_id` with a non-null UL (query below).
- **Empty sets.** If `assignedLocationIds` is empty, the code skips the query and the map stays `emptyMap()`, then line 495 throws before line 511. Before the fix, `allLocationIds` could be non-empty in that case, but line 495 still threw first. Identical. Skipping an empty `IN ()` is correct.
- **Assigned location equal to the UL's current location.** The two sets are equal, so the query and map are identical to before. This is the common case: 1,552 of 1,555 FLAs on PRD.

## 3. Test quality

- **The new test pins the regression.** On the pre-fix code, `findByStoragelocationIdIn` receives `{1, 0}`, so `containsExactlyInAnyOrder(1L)` goes red. The second assertion, `findAllById` gets `{1, 0}`, kills the tempting over-correction of dropping the current location from `allLocationIds`. The state-57 assertion kills it as well. The test answers `findAllById` by requested id, which is the SBDEV-3678 lesson. The `lenient()` stubs in the nested `setUp` (lines 413-417) do not mask anything here. `findAllById` on locations is overridden with a strict `when`. The `findByStoragelocationIdIn` stub's return value does not matter, because the position holds at the wrong-location check before line 511 (see §1), and the assertion is made on the captured argument.
- **[Low] L1: one instance, not the invariant.** File: `ReleaseOrderJobServiceUnitTest.java:774-812`. Confidence: MEDIUM. The invariant is "the location ids queried for unit loads ⊆ the assigned locations of the order's fixes". The test checks a single fix and a single position. A future regression that rebuilds the set from a union across fixes would not be caught, for example re-adding `ul.getStoragelocationId()` only when it differs from some other fix's assigned id. Fix (optional): add a second position or FLA whose UL sits at location 2, with that FLA assigned to location 3, and assert `{1, 3}`. Cheap, but a judgement call at T1.
- **SBDEV-3678 test (line 527, `{1}`) is consistent.** That fixture's UL sits on its assigned location 1, so the old and new sets are both `{1}`. That is also why it never caught this defect: it only has the "equal" case. Its `.as()` text at line 521, "FLA 1's assigned location and its unit load's location", is still accurate for `findAllById`.

## 4. Comment accuracy

PRD facts, checked on `wsl-wineco-prd` on 2026-10-13:

| Claim | Measured |
|---|---|
| Location 0 is Nirwana | `location.id=0` → `Nirwana` |
| ~370k unit loads in Nirwana | **371,235** |
| Three FLAs point at a UL now in Nirwana | **3**. These are also the only 3 of 1,555 FLAs whose UL is anywhere other than its assigned location |
| "a Shipped one would flip to a seq scan" | `Shipped` is id 51611 with 495,977 ULs. `EXPLAIN ... IN (0, 51611, 1234)` → **Seq Scan**, rows 865,013. `IN (0, 1234)` → Index Scan, rows 371,045 |

The code comment's claim that the map is read "by assignedLocation.getId() alone" is true (line 511). Comment density and style match the surrounding SBDEV-3678 comments.

- **[Low] L2: "every release" overstates the scope on develop.** File: test javadoc at `ReleaseOrderJobServiceUnitTest.java:767-768`, "so every release pulled ~370k Nirwana unit loads". Code comment at `ReleaseOrderJobService.java:315`, "~370k unit loads per release". Confidence: HIGH. On origin/main (PRD) that is true: the pre-fetch iterates `itemDataFixAssignmentMap.values()`, i.e. every FLA in the warehouse, on every `releaseOrder` call (see §6). On develop, SBDEV-3678 already narrowed the pre-fetch to the order's own items. There the cost lands only on releases of orders that contain one of the 3 affected items. Fix: in the javadoc, write "every release on PRD (pre-SBDEV-3678); on develop, every release of an order containing one of those three items". In the code comment, write "per release that touches one of them".
- **[Low] L3: the seq-scan clause is hypothetical, and the comment does not say what triggers it.** File: `ReleaseOrderJobService.java:315`. Confidence: MEDIUM. The comment reads "and a Shipped one would flip to a seq scan". No FLA UL is in Shipped on PRD today. The claim holds as a conditional (EXPLAIN above), but a reader might take it as observed. Fix: "and one in Shipped (496k ULs) would flip the query to a seq scan (EXPLAIN, PRD 2026-10-13)".

## 5. Sibling sweep

- `findByStoragelocationIdIn` has exactly one caller in `src/main`, `ReleaseOrderJobService.java:317`, declared at `UnitloadRepository.java:309-310`. No other code builds a location set from FLA unit loads' current locations and queries unit loads with it.
- No `src/main` hit for `unitloadRepository.(findBy|countBy|existsBy)Storagelocation*(... getStoragelocationId ...)`. The other `getAssignedunitloadId` readers (`FixLocationAssignmentService`, `UnitloadService:560`, `StockunitService:414/426`, `PickingorderPositionService:98`, `ReplenishGeneratorService:97/120`, `ReplenishOrderJobService:117/136`, `MobileMoveUnitloadService:530`) all do `findById` on the UL itself. None of them fans out to unit loads by location.
- **[Low] L4: the cause has no test-level guard.** File: n/a, residual. Confidence: LOW. Three FLAs pointing at a UL in Nirwana is itself data drift: the UL was moved off its fix location or deleted. This fix stops the cost, but those 3 positions still hold at 57 on every tick. Fix: none needed in this ticket. Record the 3 FLA ids on the ticket so the data can be repaired; that is a data task, not a T3 code finding.

## 6. Does the patch apply to origin/main (PRD)?

**Yes, textually and semantically.** On origin/main (`0dfb0d4d`), the `allLocationIds` block is identical: lines 283-308, with `findByStoragelocationIdIn(allLocationIds)` at :307 and the map read at :501. The only differences in the region are SBDEV-3678's: the comment, and main's `for (Object[] fixArr : itemDataFixAssignmentMap.values())` against develop's per-position loop.

On main the fix matters more: every `releaseOrder` call pre-fetches all ~1,555 FLAs, so all 3 Nirwana FLAs are in every call's `allLocationIds`. A cherry-pick of the main-code hunk applies cleanly.

The test hunk does not. origin/main's test file has no SBDEV-3678 test, so the test's context (inserted after the 3678-modified `shouldHandleUnitloadOnWrongLocation` with its answer-by-id stub) will conflict. A main backport needs the new test hand-placed. Its `findAllById` answer-by-id stub keeps it self-contained.

## Positive observations

- The fix uses the smallest correct seam: a separate `assignedLocationIds` set. It does not mutate `allLocationIds`, which would have broken the wrong-location check.
- The test asserts both sides: what must shrink and what must not. It also asserts the state-57 outcome. The negative space is pinned.
- The comments name the reason the current location stays in `locationMap`, which stops a future "cleanup" from regressing it.

## Evidence queries (wsl-wineco-prd, read-only)

```sql
select (select name from location where id=0), (select count(*) from unitload where storagelocation_id=0),
 (select count(*) from fix_location_assignment f join unitload u on u.id=f.assignedunitload_id where u.storagelocation_id=0),
 (select count(*) from fix_location_assignment f join unitload u on u.id=f.assignedunitload_id where u.storagelocation_id<>f.assignedlocation_id),
 (select count(*) from fix_location_assignment where assignedlocation_id is null and assignedunitload_id is not null),
 (select count(*) from fix_location_assignment);
-- Nirwana | 371235 | 3 | 3 | 0 | 1555
EXPLAIN SELECT * FROM unitload u WHERE u.storagelocation_id IN (0, 51611, 1234);  -- Seq Scan, 865013 rows
EXPLAIN SELECT * FROM unitload u WHERE u.storagelocation_id IN (0, 1234);         -- Index Scan, 371045 rows
```

## Re-review (delta)

**Scope:** `git diff bc37ad62 826530a3`. bc37ad62 was still reachable. I ran no Maven. HEAD is 826530a3, a single commit on a4fd6490.

**Verdict: APPROVE WITH FIXES.** The delta has 0 High, 1 Medium and 1 Low finding. L1, L2 and L3 are resolved. L4 stays a ticket note, as agreed.

### Are the {1,3} and {1,3,0,2} assertions vacuous?

No. Both arguments are built in the pre-fetch block (`ReleaseOrderJobService.java:281-320`), which runs before the position loop. So they do not depend on how far position 2 gets.

- `prefetchFixIds` is `{1, 2}`, from both positions' item ids.
- `assignedLocationIds` is `{1, 3}`.
- `allLocationIds` is `{1, 3}` plus the UL locations `{0, 2}`.

Mutation reasoning:

| Mutant | What fails |
|---|---|
| Revert to `findByStoragelocationIdIn(allLocationIds)` | Argument becomes `{0, 1, 2, 3}`, so the first assertion goes red |
| Drop `allLocationIds.add(ul.getStoragelocationId())` | Argument becomes `{1, 3}`, so the second assertion goes red. Position 1 then throws `EntityNotFoundException("Location", 0)` at :493 |

The across-fixes invariant is now pinned. L1 is resolved.

### [MEDIUM] M1: `secondPosition` holds at 57 for the wrong reason

File: `ReleaseOrderJobServiceUnitTest.java`, at the assertion `assertThat(secondPosition.getState()).isEqualTo(RAW_ON_HOLD_PROBLEM_WITH_FIXED_ASSIGNED_LOCATION)`. Confidence: HIGH.

The test does not override `stockunitRepository.findByUnitloadIdIn`. So the nested `setUp` stub applies (`:416`): `lenient().when(stockunitRepository.findByUnitloadIdIn(any())).thenReturn(Collections.singletonList(testStockunit))`. In the outer `setUp`, `testStockunit` has `setUnitloadId(1L)` (`:145`). That makes `stockunitsByUnitload` equal to `{1: [su1]}`, with nothing for UL 2. Position 2 therefore stops at the **"no stockUnit"** branch (`ReleaseOrderJobService.java:448-456`). It never reaches the wrong-location check at :492-506.

The assertion passes, but not on the path the javadoc describes ("its unit load on 2", i.e. the wrong-location hold). It is also blind to the one mutant it could catch: dropping UL 2's current location from `locationMap`. With the stock unit present, that mutant would throw at :493. Without it, position 2 never reads `locationMap`, so it stays green.

Position 1 is fine. `testStockunit` covers UL 1. `itemdataRepository.findById` is unstubbed and returns `Optional.empty()`, which skips the item check. So position 1 reaches the wrong-location hold, as before.

**Fix:** give UL 2 a stock unit so position 2 gets past the stock-unit checks, for example:

```java
Stockunit secondStockunit = new Stockunit();
secondStockunit.setId(2L);
secondStockunit.setUnitloadId(2L);
secondStockunit.setItemdataId(2L);
secondStockunit.setAmount(BigDecimal.valueOf(100));
secondStockunit.setReservedamount(BigDecimal.ZERO);
when(stockunitRepository.findByUnitloadIdIn(any())).thenReturn(List.of(testStockunit, secondStockunit));
```

`itemdataRepository.findById(2L)` stays unstubbed and returns empty, which skips the item check. Position 2 then reaches :498, where 2 ≠ 3, and holds at 57 on the intended path. Mutation-check after the change: delete `allLocationIds.add(ul.getStoragelocationId())` and confirm the test goes red.

All hold causes set the same state 57, so the state assertion alone can never tell them apart. That is acceptable once the fixture makes the wrong-location branch the only reachable one.

### [LOW] L5: the fix-assignment stub ignores the requested ids

File: same test, `when(fixLocationAssignmentRepository.findAllById(any())).thenReturn(List.of(testFixAssignment, secondFix))`. Confidence: MEDIUM.

The stub returns both fixes whatever is requested. That is harmless here, because both positions' items request `{1, 2}`. But it breaks the answer-by-requested-id convention this file adopted under SBDEV-3678 (`:495-499`, `:740-745`). It would also hide a pre-fetch that loads fixes the order does not need.

**Fix (optional):** answer by requested id, as the `locationRepository.findAllById` stub in the same test already does. Do the same for `unitloadRepository.findAllById`.

### Comment accuracy (delta)

- **Code comment** (`ReleaseOrderJobService.java:314-316`): true. On develop, the cost lands on a release that touches the 3 FLAs' items. The 3 FLAs and the ~370k figure (371,235) are dated to the 2026-10-13 measurement. The Shipped clause is now a conditional backed by EXPLAIN (Seq Scan on `IN (0, 51611, x)`). L2 and L3 are resolved.
- **Test javadoc:** "every release on main, which lacks SBDEV-3678's narrowing" is true. origin/main iterates `itemDataFixAssignmentMap.values()` (checked in §6). The sentence "A second fix (assigned to 3, its unit load on 2) checks the rule across fixes" is true for the pre-fetch assertions. The implied claim that position 2 holds via wrong-location is false until M1 is fixed.
- **The two `.as()` messages:** accurate.

### Other delta notes

- Making the `itemdataService.getById` stubs `lenient()` is unnecessary but harmless. Both are called, at :338 for each position.
- `secondItem` has no `itemNr`, so the log string `s` concatenates `"null"`. Harmless.

## Re-review 2 (delta 826530a3 → e0c3033a, test-only)

- **M1 resolved.** `secondStockunit` (UL 2, item 2) and a strict `findByUnitloadIdIn` stub returning `[su1, su2]` give `stockunitsByUnitload` = `{1: [su1], 2: [su2]}`. Traced position 2 through `ReleaseOrderJobService.java:412-506`:
  - `lastStatus` is null, and 100 ≥ 10.
  - Fix 2 and UL 2 are both found.
  - It has exactly one stock unit.
  - `itemdataRepository.findById(2L)` is unstubbed and returns `Optional.empty()`, so the item check is skipped.
  - `locationMap.get(2)` = LOC-002, which ≠ `locationMap.get(3)` = LOC-003, so the position holds at 57 on the **wrong-location** branch (:498).

  The lead's experiment confirms this independently: with only `secondPosition` in the order, plus the mutant that deletes `allLocationIds.add(ul.getStoragelocationId())`, the run throws `EntityNotFound Location ... id: 2` at :493. Isolating position 2 was needed, because in the full order position 1 throws first under that mutant, on location 0.
- **L5 resolved.** The fix-assignment and unit-load `findAllById` stubs now answer by requested id, which matches the SBDEV-3678 convention in this file.
- The new comment ("Without a stock unit on UL 2 … for the wrong reason") is accurate.
- The test run (42 passed, 0 failed) is the lead's. I did not observe it: no Maven in the worktree, by instruction.

**Final verdict: APPROVE.** No open findings at any severity. L4 (the 3 drifted FLAs on PRD) is carried as a ticket note.
