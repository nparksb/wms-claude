---
ticket: SBDEV-3249
lane: independent code review (read-only)
reviewer: oh-my-claudecode:code-reviewer
date: 2026-10-09
worktree: .claude/worktrees/wms2-api/SBDEV-3249 (feature/SBDEV-3249-native-boolean-literals, base origin/develop 0e9d6f46)
verdict: COMMENT (approve after the three stale-comment fixes; no blocking defects)
---

# SBDEV-3249 — code review

## Code Review Summary

**Files reviewed:** 10 (8 repositories, `PrinterRepositoryIntegrationTest`, new `QueryBooleanStringLiteralArchTest`),
plus the siblings `QueryTextSanitizer`, `OptionalStringFilterEmptyArmArchTest`, `MobilePutawayServiceIntegrationTest`,
`MobileReplenishServiceIntegrationTest`, `BaseRepositoryIntegrationTest`, and the entities.
**Total findings:** 9 (0 High, 2 Medium, 7 Low)

Not run, as instructed: Maven, so I did not compile anything or run any tests. LSP diagnostics were not run either.
Everything below comes from reading the code and from one DB query.

## Stage 1 — Spec compliance: PASS

The SQL edits are correct. I checked them two independent ways:

- **Entities:** every compared column is a `Boolean` field. `LocationArea.useforpicking/useforreplenish/useforstorage`
  (:21/:23/:25), `Customerorder.markasvisited` (:53), `FixLocationAssignment.active` (:16) and `Printer.processdefault`
  (:20). None of them has an `@Convert` or a `columnDefinition` override.
- **Live DB** (`wms2-wineco-dev`, information_schema): all six columns are `boolean`. Only
  `fix_location_assignment.active` is nullable, which matches the author's claim. `NULL = 'true'` and `NULL = true`
  both evaluate to NULL, so no row changes.
- **Edit count:** on the base, `git grep -iE "(=|<>|!=)\s*'(true|false|t|f)'" 0e9d6f46 -- src/main/java` returns 26
  lines. The diff changes 26 lines (25 SQL + 1 comment). The same grep on the worktree returns 0, and the base count
  serves as the positive control for that zero. The edits did not touch any varchar column, JPQL query, sysprop
  value, `"true".equals` or `IS DISTINCT FROM '<const>'` fragment.
- **SDR-exported searches:** `getStorageLocationsForPutAwayItemData`, `getStorageLocationsForStockUnitItemData`,
  `findByTypeAndProcessdefaultTrue` and `getRefillFixedLocations` keep their exact semantics. Their signatures do not
  change, so there is no contract change.
- **SQL resources:** `src/main/resources` (Flyway, views, report functions) and `src/test/resources` contain no
  non-comment string-boolean comparisons. The three hits in migrations are all `--` comments about sysprop values.
- **JdbcTemplate SQL:** only `PutawayConfigService` and `EndpointHealthCheck` build JDBC SQL, and neither compares a
  boolean. No `@NativeQuery`, `@NamedNativeQuery`, `@Formula`, `@SQLRestriction`, `orm.xml` or
  `jpa-named-queries.properties` is in use.

## Issues

### [MEDIUM] `MobilePutawayServiceIntegrationTest` still blames SBDEV-3249 in present tense
File: `src/test/java/net/aim_ai/wms/integration/service/mobile/MobilePutawayServiceIntegrationTest.java:17-35` (comment block and `@Disabled` reason)
Confidence: HIGH

**Issue:** The `@Disabled` reason says `getPutAwayCandidateLocations` "compares a boolean column to the string literal
'true', which H2 rejects… Once that lands…". After this change the query no longer does that. The comment at :19-24
says the same thing and adds "Tracked as SBDEV-3249".

**Failure scenario:** Someone triaging the skipped tests reads the reason, sees an open-sounding H2 blocker, and
leaves the class disabled. The fixture rebuild is now the only blocker, but the text hides that.

**Fix:** Rewrite the reason so it names the fixture rebuild as the only remaining blocker, for example: "SBDEV-3249
removed the H2 query blocker; the class still needs its fixture rebuilt as direct entity construction (the @Sql script
was removed, not ported)." Update the comment at :19-24 the same way.

### [MEDIUM] `MobileReplenishServiceIntegrationTest` still says the FLA query is H2-incompatible
File: `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileReplenishServiceIntegrationTest.java:207-212`
Confidence: HIGH

**Issue:** The comment says the non-Tote path "uses Postgres-only boolean-vs-string SQL ("fla.active = 'true'") that
H2 rejects even in MODE=PostgreSQL… a genuine H2/production incompatibility". The only `fla.active = 'true'` in
`src/main` was `FixLocationAssignmentRepository.REFILL_ELIGIBILITY_FROM_WHERE`, and this change fixed it. So the
comment now describes a constraint that no longer exists, and the fixture choice it justifies ("Tote") rests on that
constraint.

**Failure scenario:** A future author avoids the BOX path on H2 because of this comment, and the BOX path stays untested
for no reason. Separately, the comment's attribution was already doubtful: it names `sendToNirvana`, but the only
FixLocationAssignment call in `UnitloadBusinessService` is the derived `findByAssignedlocationId` (:256).

**Fix:** Replace the comment with "Tote is used for the simpler relocate-to-EmptyTotes branch". Optionally note that
since SBDEV-3249 the FLA query also runs on H2.

### [LOW] Printer test `setUp` comment now gives the wrong test count and leak-blindness claim
File: `src/test/java/net/aim_ai/wms/integration/repository/PrinterRepositoryIntegrationTest.java:41-45`
Confidence: HIGH

**Issue:** The comment says "Its assertions cannot see a leaked row… the isEmpty() ones are over a type nothing else
writes… Measured with the rollback deliberately broken: 8 tests, 0 red." Two things changed with the re-enabled
classes:

- The class now has 12 tests, not 8.
- `shouldReturnEmptyWhenNoDefaultPrinter` (:161) and `shouldReturnEmptyWhenOnlyOneDefaultExists` (:203) call
  `isEmpty()` on LABEL + `processdefault=true`. Sibling tests in the same class write exactly that row (:143, :174,
  :182, :197).

With rollback broken, these two tests would go red depending on run order.

**Fix:** Update the paragraph. The re-enabled `isEmpty()` assertions are now real leak sentinels for this class, which
is a net improvement worth saying. Optionally re-run the broken-rollback measurement and record the new number.

### [LOW] `LocationRepository` javadoc says the query is "deliberately unchanged / left untouched", but its text changed
File: `src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java:186` and `:205`
Confidence: MEDIUM

**Issue:** The query's contract is unchanged, but its text changed (`= 'true'` became `= true`). A reader who diffs the
query against the claim will wonder whether the claim was violated.

**Fix:** Add a short qualifier, such as "(contract unchanged; SBDEV-3249 only re-spelled the boolean literal)", or
leave the text as it is and accept the nit.

### [LOW] Detector: false negatives the javadoc does not disclose
File: `src/test/java/net/aim_ai/wms/unit/repo/QueryBooleanStringLiteralArchTest.java:35-43` (Blind spots), `:51-54` (regex)
Confidence: HIGH

**Issue:** None of these exist in `src/main` today, but the javadoc's blind-spot list is the contract, and it omits
them:

1. **Other spellings PostgreSQL accepts as boolean input.** `'yes'`/`'no'`, `'on'`/`'off'`, `'1'`/`'0'`, `'y'`/`'n'`,
   unique prefixes (`'tr'`, `'fal'`) and padded forms (`' true '`). H2 rejects these the same way. Example:
   `a.useforstorage = 'yes'` passes the detector.
2. **Composed annotations.** `m.getAnnotation(Query.class)` (:68, :121) does not see `@NativeQuery`. Spring Data JPA
   3.4+ (Boot 3.5) ships `@NativeQuery`, which is meta-annotated with `@Query`, so a native query written with it is
   not scanned.
3. **Sanitizer misreads.** A misread blanks a real hit and silently drops it. This includes PostgreSQL `E'...'`
   strings, dollar-quoting, and nested block comments, which end at the first `*/`. The sibling
   `OptionalStringFilterEmptyArmArchTest` discloses its version of this; this test does not.
4. **`IS DISTINCT FROM 'true'`** (and `IS NOT DISTINCT FROM`). This is a real PostgreSQL spelling that H2 would also
   reject, and it is not matched.

**Fix:** Add items 1–4 to "Not seen". Optionally widen `BOOL_LITERAL` to
`'\s*(?:true|false|t|f|yes|no|y|n|on|off|1|0)\s*'`. Note that `'1'`/`'0'`/`'y'`/`'n'` would raise the
loud-false-positive rate on varchar columns. Alternatively, look up `@NativeQuery` via
`AnnotatedElementUtils.findMergedAnnotation(m, Query.class)` and add a fixture for it.

### [LOW] Detector: loud false positives broader than "a sysprop value"
File: `QueryBooleanStringLiteralArchTest.java:40-42`, `:51-54`
Confidence: HIGH

**Issue:** The match is case-insensitive on `'t'`/`'f'`, so any varchar or char code column compared to `'T'`/`'F'`
(type codes, flags, gender) is flagged. So is `= 'true'::boolean`, which is valid on H2 in PG mode. The javadoc only
mentions "a varchar column legitimately holding the text 'true'". A one-letter code compare is a more likely future
trip than a sysprop.

**Fix:** Mention single-letter `'T'`/`'F'` code columns and `'true'::boolean` in the "Reported although safe" bullet.

### [LOW] Javadoc lists `IS 'true'` as an undetected spelling, but it is not valid PostgreSQL
File: `QueryBooleanStringLiteralArchTest.java:38`
Confidence: MEDIUM

**Issue:** PostgreSQL only allows `IS TRUE`, `IS FALSE`, `IS UNKNOWN` and `IS [NOT] DISTINCT FROM`. `x IS 'true'` is a
syntax error on both engines, so it can never be a live defect, and listing it is misleading.

**Fix:** Replace it with `IS [NOT] DISTINCT FROM 'true'`, which is the real spelling the detector misses.

### [LOW] Non-vacuity anchors do not show a real `countQuery` is reached
File: `QueryBooleanStringLiteralArchTest.java:75-80`
Confidence: MEDIUM

**Issue:** The three anchors prove the importer reaches repository interfaces and their `@Query`. `scanned` is filled
from the same `getAnnotation` call that `violations()` uses, so that part is meaningful. But no anchor proves the
countQuery path on a real repository; only the `inCountQuery` fixture covers it. The sibling test anchors its
countQuery explicitly (`LocationRepository#findLabelCandidatesByKeyword countQuery`). This ticket also fixed two
`countQuery` texts in `ItemdataRepository#getIdsForItemDataWithoutFixedAssignmentPage`.

**Fix:** Track `label + " countQuery"` whenever `q.countQuery()` is non-empty, and add
`"ItemdataRepository#getIdsForItemDataWithoutFixedAssignmentPage countQuery"` to the anchors.

### [LOW] `QueryTextSanitizer` class javadoc no longer lists all its users
File: `src/test/java/net/aim_ai/wms/unit/repo/QueryTextSanitizer.java:4-5`
Confidence: HIGH

**Issue:** The javadoc says it is shared by `OptionalStringFilterEmptyArmArchTest` and
`JpqlConcatNullSafeOperandArchTest`. The new arch test is a third consumer, so a change to comment or literal handling
now affects this test as well.

**Fix:** Add `{@link QueryBooleanStringLiteralArchTest}` to the list. Better: state the rule ("every `@Query` arch test
in this package") so the list cannot go stale again.

## Detector soundness (question 2) — what I checked and found correct

- **Comment-skip offset logic (:138-151).** For the `=\s*'…'` alternative, `sql.indexOf('\'', mm.start())` lands on
  the literal's opening quote. For the reversed alternative, the match begins at the quote. The sanitizer preserves
  offsets, keeps the quotes of real literals, and blanks the quotes inside comments. So the check reads "this quote is
  code, not comment", which is correct.
- **Hits inside a string literal.** These are also rejected correctly, because inner doubled quotes get blanked. A
  `''true''` inside a literal can never match the regex anyway: `=\s*'` must be followed directly by `true`.
- **`find()` loop.** It continues after a comment hit, so a real hit after a commented one is still found. The
  `inLineComment`/`inBlockComment` fixtures pin the negative side.
- **Operators.** `<=` and `>=` are caught through their `=` (fine). `!=` and `<>` are covered by fixtures.
- **Control test.** It is a real mutation guard: 7 positive spellings, including countQuery and JPQL, plus 4
  negatives. The `Fixtures` interface does not extend `Repository`, and `DO_NOT_INCLUDE_TESTS` keeps it out of the
  main scan.
- **Compile-time constants.** Constants concatenated into the annotation (`REFILL_ELIGIBILITY_FROM_WHERE`,
  `MANUAL_CUT_COOLDOWN_EXCLUSION`) are inlined into the annotation value, so the scan sees them.

## Re-enabled Printer tests (question 4)

- **Isolation within the H2 DB.** `BaseRepositoryIntegrationTest` is `@Transactional("tenantTransactionManager")`
  (:39), and the rollback is real since SBDEV-3242. No other H2 test writes a `printer` row: `TestDataFactory.printer()`
  only builds in memory, and `processdefault(true)` appears only in unit tests with mocks. The one IT that inserts
  printers, `ReturnAdviceAutoReceiveIntegrationTest`, is `BasePostgresIntegrationTest` and cleans up after itself
  (:621). I see no leak or conflict with sibling tests.
- **`limit 1` without `ORDER BY`.** `findByTypeAndProcessdefaultTrue` (PrinterRepository:17) has no `ORDER BY`. That is
  harmless here, because `shouldFindDefaultPrinterForType` asserts only type and flag, not identity.
- **The comment at :167-168 is correct.** `findAllTypeAndProcessdefaultTrue` is JPQL `p.processdefault = true`
  (PrinterRepository:21), so its old `@Disabled` reason was never true.

## Open Questions (low-confidence — surfaced, not blocking)

### [MEDIUM] H2 behaviour change for tests that used to hit a swallowed SQL error
Confidence: LOW

On H2, every query in this diff used to throw at prepare time. Any H2 test whose code path reached one of them behind
a catch-and-log (the arch javadoc names the refill-eligibility caller) ran the "query failed" branch. That branch now
runs the real query. A test that was green because of the swallowed error could now take a different branch:

- it could go red, or
- it could stay green while no longer exercising what its name says.

The 26 edited lines cover the replenish cron, the Pick&Pack eligibility reads, putaway and the printer default
queries. **Fix:** compare the full H2 suite (`mvn clean verify`) against the develop baseline, test by test and not
just by totals. Check especially any test touching `refillFixedLocations` or `getIdsForItemDataWithoutFixedAssignment*`
on H2. The author's running build should answer this; I could not run it.

## Style (question 5)

The new test matches `OptionalStringFilterEmptyArmArchTest` closely: same importer and `SCANNED_PACKAGE`,
interface-only scan, non-vacuity on the SCANNED set, a detector-control test with a nested `Fixtures` interface,
`@DisplayName` with the ticket prefix, and a javadoc with Why / What / Blind spots. It also reuses `QueryTextSanitizer`
instead of copying it.

One nit: the javadoc and failure message say `= TRUE` / `= FALSE` (upper case), while all 25 edited lines and the
surrounding code use lower case `= true`. Either is fine; it could say "TRUE/true".

## Positive Observations

- The fix has the smallest possible scope, and the edit count was checked against a base positive control: 26 lines
  before, 26 lines in the diff.
- The rule now covers the whole class of defect (an arch test) rather than only these instances. Its control fixtures
  include countQuery, JPQL, the reversed operand order and comments.
- The Printer re-enable comment is honest about the class whose `@Disabled` reason was never true, instead of
  claiming the fix rescued it.
- Exported SDR searches keep their semantics exactly, and the ReplenishmentMonitorView comment was updated together
  with the query it quotes.

## Recommendation

**COMMENT.** There are no CRITICAL or HIGH findings. The SQL change is correct and verified independently (entities
plus a live `information_schema` query). Before the PR, fix the two Medium stale-comment findings
(MobilePutaway and MobileReplenish) and the Printer `setUp` comment. The remaining Low javadoc and detector findings can
go in the same pass. Settle the open question with the full-suite baseline comparison.
