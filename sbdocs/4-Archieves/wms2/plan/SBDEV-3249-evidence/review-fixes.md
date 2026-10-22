---
ticket: SBDEV-3249
lane: independent re-review of the fixes to review-code.md (read-only)
reviewer: oh-my-claudecode:code-reviewer
date: 2026-10-09
worktree: .claude/worktrees/wms2-api/SBDEV-3249, commit 82e92f7f (base origin/develop 0e9d6f46)
verdict: COMMENT (8 of 9 resolved; one rewritten comment still carries a false claim; a stale-comment sweep was missed)
---

# SBDEV-3249 — re-review of the 9 fixes

Read-only. Nothing compiled and no tests run. Evidence is `git show 82e92f7f` plus targeted reads of the worktree.
Paths are relative to `src/test/java/net/aim_ai/wms/` unless they start with `src/main`.

## Per-finding verdict

| # | Original finding | Verdict | Evidence |
|---|---|---|---|
| 1 | Medium: MobilePutaway comment and `@Disabled` blame 3249 | Resolved | `integration/service/mobile/MobilePutawayServiceIntegrationTest.java:17-28`. The reason now names only the fixture. See N4 for a residual stale cross-reference elsewhere. |
| 2 | Medium: MobileReplenish says the FLA query is H2-incompatible | Partially resolved | `MobileReplenishServiceIntegrationTest.java:208-213`. The "H2 rejects it" claim is gone, but the rewrite repeats the false `sendToNirvana` attribution (N1) and adds an unsupported fixture claim (N2). |
| 3 | Low: Printer `setUp` count and leak-blindness | Resolved | `PrinterRepositoryIntegrationTest.java:46-48`. Residual wording in N5. |
| 4 | Low: LocationRepository "unchanged / untouched" | Resolved | `src/main/.../LocationRepository.java:187-189` and `:207-208`. Both javadocs now say "unchanged in behaviour" and name the respelling. |
| 5 | Low: detector undisclosed false negatives | Resolved | `unit/repo/QueryBooleanStringLiteralArchTest.java:35-51`. All four items are listed and accurate (see below). I did not widen `BOOL_LITERAL`; the author gave a reason. |
| 6 | Low: loud false positives too narrow | Resolved | `QueryBooleanStringLiteralArchTest.java:48-51` now names `'T'`/`'F'` and `'true'::boolean`. |
| 7 | Low: `IS 'true'` is not valid SQL | Resolved | The javadoc now lists `IS [NOT] DISTINCT FROM 'true'` (:45). |
| 8 | Low: no countQuery anchor | Resolved | `scanned` gets `label + " countQuery"` and the anchor `ItemdataRepository#getIdsForItemDataWithoutFixedAssignmentPage countQuery` is asserted. `ItemdataRepository.java:88` confirms that method has a `countQuery`. |
| 9 | Low: `QueryTextSanitizer` javadoc lists two users | Resolved | `unit/repo/QueryTextSanitizer.java:3-6` lists all three. It still enumerates users, so it can go stale again (the review offered "state the rule" as the better fix). That is optional. |

## New or remaining problems

### [LOW] N1. MobileReplenish comment still attributes the FLA-candidate query to `sendToNirvana` (false)
File: `integration/service/mobile/MobileReplenishServiceIntegrationTest.java:208-213`
Confidence: HIGH
Issue: The rewrite says a non-reusable type routes through `UnitloadBusinessService.sendToNirvana`'s "FLA-candidate-search
query", and that "runs since SBDEV-3249". `sendToNirvana` (`src/main/.../UnitloadBusinessService.java:563-590`) makes no
FixLocationAssignment query at all. It checks stock and carrier children, moves the unit load to nirvana, then sets the
lock and label. The only FLA call in that class is the derived `findByAssignedlocationId` at :256, which is not boolean
SQL. The `fla.active = true` native query (`FixLocationAssignmentRepository.REFILL_ELIGIBILITY_FROM_WHERE`, :167-204) is
reached from `ReplenishGeneratorService:93` and `ReplenishOrderJobService:216`, the replenish cron. Review finding 2
raised this attribution as doubtful, and the fix kept it and added "runs since SBDEV-3249" on top. This is the very kind
of new false claim you asked me to look for.
Fix: Drop the clause about the BOX path and the FLA query. Say only: "Tote takes the relocate-to-EmptyTotes branch of
relocateEmptiedContainer; a non-reusable type would retire the unit load via sendToNirvana." Then there is nothing
about SBDEV-3249 to assert here.

### [LOW] N2. "this test's fixture seeds no fix-location assignments" is literally true but misleading, and irrelevant
File: `MobileReplenishServiceIntegrationTest.java:211-213`
Confidence: MEDIUM
Issue: I read the fixture. It never calls a FixLocationAssignment repository. But its own comment at :132-136 and :150
says the service creates the destination's FLA at runtime (`MobileReplenishService:607`,
`fixLocationAssignmentService.createFixedLocationAssignment`), and the flowbin finish path then deposits stock on that FLA's
virtual unit load (:155-157). So FLAs do exist during the test. Since the boolean query is not on the `sendToNirvana`
path (N1), "no seeded FLAs" is not the reason Tote is enough. The sentence is true as worded and wrong in what it
implies.
Fix: Remove it together with N1.

### [LOW] N3. Detector javadoc "Why" paragraph overstates what the incompatibility blocked
File: `unit/repo/QueryBooleanStringLiteralArchTest.java:23-27`
Confidence: MEDIUM
Issue: It says the incompatibility "is what kept `PrinterRepositoryIntegrationTest` and
`MobilePutawayServiceIntegrationTest` `@Disabled`". For Printer that was only the native class. The JPQL class's reason
"was never true", as the commit's own comment at `PrinterRepositoryIntegrationTest.java:170` says. For Putaway it was
true historically, but that class is still disabled and now for a different reason. This was not in the original 9
findings; the passage was left alone.
Fix: Say "kept the native `findByTypeAndProcessdefaultTrue` test class and the putaway class disabled", or drop the
test names.

### [LOW] N4. Stale references to SBDEV-3249 as an open H2 blocker, outside the commit
Confidence: HIGH
- `unit/service/mobile/MobilePutAwayServiceUnitTest.java:1911-1912`: "see SBDEV-3249, which is the reason
  MobilePutawayServiceIntegrationTest still cannot run it on H2". After this commit that is false; the query runs on H2.
  The integration test is disabled only for its fixture.
- `unit/config/TestClassTransactionManagerArchTest.java:173-175`: "still @Disabled for an unrelated reason — a genuine H2
  SQL incompatibility in production LocationRepository code, SBDEV-3249". Same staleness. (`:636-637` "re-enabling that
  class for SBDEV-3249" is only a ticket-as-name use; mild.)
- `integration/query/ReplenishMonitorVisibilityIntegrationTest.java:233` quotes
  `StockunitRepository.getStockUnitsByItemDataId`'s predicate as `useforpicking = 'true'`. The quoted predicate was
  respelled by this commit.
Fix: These are the same defect class review finding 1 flagged, so sweep them in the same pass. Reword each to "SBDEV-3249
removed the query blocker; the class needs a fixture" and `useforpicking = true`.

### [LOW] N5. Printer comment: its first sentence is now partly contradicted
File: `integration/repository/PrinterRepositoryIntegrationTest.java:41-48`
Confidence: MEDIUM
Issue: The new parenthetical is accurate. I counted 12 `@Test` methods, 4 of them in the two re-enabled nested classes
(8 before, which matches the old count). Of those, the `isEmpty()` at :164 and :206 can see a default LABEL printer
leaked from a sibling test (:146, :177, :185, :200). But the unchanged text above it still reads "Its assertions cannot see
a leaked row ... the isEmpty() ones are over a type nothing else writes", so the paragraph now argues both ways. "Not
re-measured" is honest.
Fix: Edit the original sentences ("cannot see" becomes "could not see before SBDEV-3249") instead of appending a
correction. Optionally re-run the broken-rollback measurement.

### [LOW] N6. Putaway comment says the query "now runs on H2", which no test shows
File: `integration/service/mobile/MobilePutawayServiceIntegrationTest.java:19-22`
Confidence: LOW
Issue: The only H2 end-to-end evidence in this change is the Printer native query. `getPutAwayCandidateLocations` also
uses `UNION`, `DISTINCT(l.*)` and `CAST(:configuredLocationId AS bigint)`. It may or may not prepare on H2, and its test
class is disabled. The commit message does not say it was run either. The claim is likely true but is stated as fact.
Fix: "no longer fails on the boolean literal", or run the query once on H2.

## Check results you asked for

- **MobileReplenish "seeds no fix-location assignments":** true for repository seeding, misleading as a reason (N2). The
  surrounding claim about `sendToNirvana` is false (N1).
- **QueryBooleanStringLiteralArchTest javadoc blind spots, each against its regex and logic:**
  - `getAnnotation(Query.class)` does not read meta-annotations, so the `@NativeQuery` claim is accurate. `src/main` has
    no `@NativeQuery`; my grep found none.
  - Padded `' true'` and prefixes such as `'tr'` are not matched, because the regex needs the quoted content to be exactly
    one of `true|false|t|f`. Accurate.
  - `'yes'`, `'1'`, `'y'` are not matched. Accurate.
  - `IN ('true')` and `IS [NOT] DISTINCT FROM 'true'` have no `=`, `<>` or `!=`, so they are not matched. Accurate.
  - E-strings, dollar quoting and nested block comments: `QueryTextSanitizer` handles only `'..'`, `--` and a
    non-nested `/* */`. A nested comment ends at the first `*/`. Accurate.
  - Loud false positives: `CASE_INSENSITIVE` makes `'T'` and `'F'` match, and `= 'true'::boolean` matches on the `=`.
    Accurate. I also checked that `src/main/java` has no `= 't'` or `= 'f'` form today.
  - One gap: the paragraph only says what is not seen. The reversed `'x' = col` form is covered by a fixture, so no
    problem there.
- **PrinterRepositoryIntegrationTest `setUp` comment:** the "4 more tests" figure is correct; see N5 for the wording.
- **LocationRepository javadocs:** accurate. One long line (:187-189) breaks the file's wrapping; cosmetic.
- **Regex and fixtures:** unchanged from the first review. I re-verified the comment-skip logic against the sanitizer
  source and it holds.

## Still open from the first review
The Open Question (a full H2 suite compared with the develop baseline, test by test) is outside this read-only lane and
is still unanswered.

## Summary
Medium: 0. Low: 6 (N1-N6). Everything else is resolved.
Recommendation: **COMMENT**. Remove the `sendToNirvana`/FLA sentence in `MobileReplenishServiceIntegrationTest` (N1/N2),
since it is a fresh false claim, and sweep the three stale 3249 references (N4) before the PR.
