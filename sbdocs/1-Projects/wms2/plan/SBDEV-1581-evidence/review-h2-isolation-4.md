---
title: SBDEV-1581 — review 4 of c74829cf (past tense, base javadoc, wrap; L-1..L-3 of review 3)
date: 2026-10-19
reviewer: code-reviewer lane (read-only, no mvn run)
commit: c74829cff8ebbc6b312ef4199f68f8ee6c358efe
prior-review: review-h2-isolation-3.md
worktree: .claude/worktrees/wms2-api/SBDEV-1581-h2
verdict: COMMENT (0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW; none blocking)
---

# Review 4 — c74829cf

**Verdict: COMMENT.** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW. No behaviour change; the reworded javadoc is accurate.
L-1 is only partly addressed and L-2 is partly addressed.

Method: `git show c74829cf` (4 files, 21+/17-), then a programmatic comparison of every `.as(...)` message in
`BaseRollbackIntegrationTestDatabaseNamePinTest.java` before and after the commit (literal fragments joined in
order), a line-length scan of the added lines, and greps over `src/main` and `src/test` for the javadoc claims.
No Maven run.

## (1) No behaviour change — PASS

- Every `.as(...)` message, joined from its literal fragments, is byte-identical before and after
  (`old == new` across all 8 messages in `BaseRollbackIntegrationTestDatabaseNamePinTest`). The two multi-line splits
  (`"...@ContextConfiguration(" + "initializers = ...)"` and `"...resolves to nothing " + "and all contexts..."`) keep
  their space at the split point. The third split (`.as(` ... `key, placeholder)`) only moves the argument list.
- The Cancel-override and Base/Initializer changes are comment-only (`/** */` and `//`-free javadoc). No annotation
  value or code line changed. The diff hunks confirm this.

## (2) Accuracy of reworded comments

Verified against source:

- `RollbackDatabaseNameInitializer` paragraph 2 (the one you asked about):
  - `StartApplication.java:42-43` excludes `DataSourceAutoConfiguration`. TRUE.
  - `spring.datasource.url` is not read by any `src/main` code (`git grep 'spring\.datasource' -- src/main` returns nothing). TRUE.
  - `TestDatabaseConfig.tenantDynamicRoutingDataSource` (`@Bean @Primary`) returns a Mockito mock whose
    `getConnection()` and `getConnection(String,String)` both answer `landlordDataSource.getConnection()`. TRUE.
    So tenant entities land in the landlord H2 database. TRUE.
  - `landlord.datasource.jdbc-url` is bound by `LandlordDatabaseConfig.java:37` (`@ConfigurationProperties("landlord.datasource")`).
    This is the only live pool in the lane. TRUE.
- `BaseRollbackIntegrationTest` class javadoc (L-3 target): now says "Supplies H2 datasource properties", names
  `landlord.datasource.jdbc-url` as the pool source, routes tenant connections through the mock, and states that
  `spring.datasource.url` is "declared but not read". All TRUE. The old "for both landlord and tenant" pool
  implication is gone.
- `CancelOrderAlreadyCancelledPositionIntegrationTest` header: "would merge with ... AdviceServiceRollbackIntegrationTest's,
  and so would DeferredCancelTerminalPathIntegrationTest's if its override went" is TRUE. Deferred's `@MockitoBean` set
  (`HttpRestService`, `SyspropService`, `MessageService`) is identical to Cancel's. Its property overrides are the only
  difference, and those are removed when the override is removed, so the two would share a context.
  Not checked: the Advice class's own `@MockitoBean` set. The `grep` I ran did not match it, so the Advice half of
  that sentence was not re-verified in this pass. It is pre-existing text.
- "the other subclasses" (was "the other ~30 subclasses") is accurate. The count was dropped rather than kept stale.

No false statement found in the lines this commit touched.

## (3) Review-3 findings — status

| Finding | Status |
|---|---|
| L-1 Cancel header: present-tense "Every subclass shares ... NOT a Spring context" | FIXED ("shared"). |
| L-1 Cancel header: "They do NOT fix the shared-state problem" | NOT changed. Still present tense. Only the "~30" count was removed. See N-1. |
| L-1 Cancel header: Deferred omission | FIXED ("and so would DeferredCancelTerminalPathIntegrationTest's if its override went"). |
| L-2 `BaseRollbackIntegrationTestDatabaseNamePinTest:48` at 125 cols | FIXED (`.as(` message split across two lines). |
| L-2 `RollbackDatabaseNameInitializer` paragraph raggedness | FIXED (paragraph rewrapped). |
| L-2 the new Cancel-header line | INTRODUCED a new over-length line. See N-2. |
| L-3 base javadoc "for both landlord and tenant" | FIXED. |

## Findings

### [LOW] N-1 — L-1 only half applied: "They do NOT fix" still present tense
File: `src/test/java/net/aim_ai/wms/integration/CancelOrderAlreadyCancelledPositionIntegrationTest.java`, header
paragraph beginning "Private database names keep this class's create-drop confined...", around line 95.
Confidence: MEDIUM.
The sentence "They do NOT fix the shared-state problem for the other subclasses; the real fix is per-context names on the
base, which SBDEV-1581 made" is inside the pre-SBDEV-1581 history block, so the surrounding framing makes it readable. Read
alone, however, it describes the shared-state problem in present tense even though SBDEV-1581 has fixed it. Review 3 asked
for "did not fix". Fix: "They did NOT fix the shared-state problem for the other subclasses; the real fix was per-context
names on the base, which SBDEV-1581 made." Cosmetic; no test or runtime impact.

### [LOW] N-2 — new over-length line in the Cancel header
File: `src/test/java/net/aim_ai/wms/integration/CancelOrderAlreadyCancelledPositionIntegrationTest.java`, the header line
" * if its override went), so treat that as its own change with a full-suite run. The text below records why the override was added (pre-SBDEV-1581)."
Confidence: HIGH.
About 148 columns. This commit added it, and it is the only added line over 120 columns in the commit (the scan of all
`+` lines found no other). Fix: rewrap the paragraph at about 120 columns, e.g. break after "full-suite run." and
continue the "The text below records..." sentence on a new line.

## Open questions
- None blocking. The Advice half of the Cancel-header sentence (its `@MockitoBean` set matching Cancel's) was not re-read in
  this pass. It is pre-existing text, unchanged by c74829cf.

## Positive observations
- Assertion-message wrapping is verifiably text-preserving (every message is byte-identical after joining its literals).
- The Initializer javadoc now separates "a fact about this test lane" from "a fact about the application", and each clause
  checks against source.
- The base javadoc no longer claims a live tenant pool, which the review-3 L-3 pointed out as contradicting the initializer.

## Recommendation
**COMMENT.** Nothing blocks. Optionally fix N-1 and N-2 in the same push (both are comment-only), then the commit can be
treated as final for the SBDEV-1581 review lane.
