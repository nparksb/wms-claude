---
title: SBDEV-3183 r15 — scoped re-review #3 (commit a03b5ad4, fixes N1–N6)
date: 2026-10-21
ticket: SBDEV-3183
kind: evidence (review lane, read-only)
worktree: .claude/worktrees/wms2-api/SBDEV-3183-r15
range: a03b5ad4 only
verdict: COMMENT (no blocking finding; 3 Low)
---

# SBDEV-3183 r15: re-review of a03b5ad4

**Verdict: COMMENT.** N1 through N6 are all addressed, and the commit changes no production behaviour: it touches javadoc, test wording and one import. I found 3 new findings, all Low, and none of them blocks. I did not run Maven and did not edit the worktree. I took the author's results as given: SdrFunctionRulesUnitTest 55/0, CustomerorderForceCancelOutboxIntegrationTest 2/0, and the counter-mutant going red.

## How I checked it
- I read `git show a03b5ad4` in full: 4 files, +18/−15.
- **Named-query claim:** `git grep -E "@NamedQuery|@NamedQueries|@NamedNativeQuery|jpa-named-queries"` over `src/main` at a03b5ad4 found 0 hits. The same grep at 923a213e also found 0. `git ls-tree` shows no `jpa-named-queries.properties` and no `orm.xml`.
- **Null-parameter claim:** I read `ReceivingDtoViewRepository.java:23-27` at a03b5ad4.
- **Lifecycle:** `git grep TestInstance` over `src/test` found 0 hits. There is no `junit-platform.properties`, and the pom has no `configurationParameters` or lifecycle default. `BaseRollbackIntegrationTest` (`:36-63`) has no `@TestInstance` and extends nothing. The IT has no `@Nested`.
- **Widths:** I measured in characters with Python, not bytes, because the javadoc contains em-dashes.
- **Merge overlap:** `git diff --name-only` on both ranges, intersected with `comm -12`.

## 1. Is each of N1–N6 addressed?

| Prior | Addressed? | Evidence |
|---|---|---|
| N1 javadoc over-run | **Yes** | `FunctionGuardInterceptor.java:95-98` and `RequiresFunction.java:61-63` are reflowed. The words are identical to before; only the line breaks moved. The orphan line ` * when the tenant's` is gone. Every changed line is ≤120 characters; the longest is 117. |
| N2 "narrowing arms" wrong reason | **Yes** | "The WHERE arms are not pinned: a caller passing null parameters already reaches every row of the entity, so no edit to the WHERE clause can widen what a holder reads." The over-generalisation is covered in L1. |
| N3 named-query route | **Yes (disclosed)** | "Not covered: a JPA named query (`Printer.findByType` in `@NamedQuery` or `jpa-named-queries.properties`) also replaces derivation …; neither exists in `src/main` today." The grep confirms this is TRUE. Spring Data's named-query key is `<domain simple name>.<method>`, so `Printer.findByType` is the right name. The list is incomplete; see L2. |
| N4 subquery after WHERE | **Yes (disclosed)** | "a JOIN or a second entity in FROM is red (a subquery after WHERE is not)." This is TRUE. The prefix `SELECT p FROM ReceivingDtoView p WHERE ` fixes only the text up to WHERE. |
| N5 non-whitespace reformat | **Yes (disclosed)** | "A non-whitespace reformat (lower-case keywords, a renamed alias) goes red; re-pin after checking." This is TRUE, because `startsWith` is case-sensitive and alias-exact. |
| N6.1 message | **Yes, mostly** | `:190` now reads "control: UnitloadRepository.save must reach the stubbed answer, not the real repository". See L3 for one gap. |
| N6.2 FQN | **Yes** | `import java.util.concurrent.atomic.AtomicInteger;` is at `:35`, and the field at `:114` is now short. The FQNs in `SdrFunctionRulesUnitTest` (`AnnotatedElementUtils`, `Query`) remain. The prior review marked those as optional and outside N6.2. |
| N6.3 redundant reset | **Yes (dropped)** | This is safe today; see §2. |

## 2. The specific checks

- **"neither exists in src/main today": TRUE.** No `@NamedQuery`, `@NamedQueries`, `@NamedNativeQuery` or `jpa-named-queries.properties` exists, and there is no `orm.xml` either. This holds at a03b5ad4 and at the merge 923a213e.
- **"a caller passing null parameters already reaches every row": TRUE for the one entry it covers today**, `ReceivingDtoView/findByKeyword`.
  - With `:keyword` null, `or :keyword IS NULL` is true.
  - With `:clientNumber` null, `OR :clientNumber IS NULL` is true.
  - So every `ReceivingDtoView` row is returned, paged. Over SDR, omitting the query param binds null.
  - It is not a property of the `ReviewedOverride` record in general. See L1.
- **"a subquery after WHERE is not [red]": TRUE.** `startsWith` cannot see anything after the prefix.
- **Is removing the per-test `set(0)` safe? Yes, under the default per-method lifecycle.**
  - Nothing in the class, its base `BaseRollbackIntegrationTest`, `src/test` or the build config selects `PER_CLASS`.
  - Each of the 2 tests therefore gets a fresh instance, and with it a fresh `AtomicInteger`.
  - `@MockitoSpyBean` resets the spy after each test, and `@BeforeEach` reinstalls the `doAnswer`.
  - The one residual fragility, a future `PER_CLASS`, is noted under Open Questions.
- **Javadoc line widths: every line this commit changed is ≤120 characters.**
  - The longest line in the new `ReviewedOverride` block is 117 (`:388`).
  - Some lines over 120 already exist outside the changed hunks: `SdrFunctionRulesUnitTest.java:312,368,398,544` and `CustomerorderForceCancelOutboxIntegrationTest.java:59,188`. They come from earlier commits (for example, `:398` is from 6c2a39ef0). They are out of scope and not counted.
- **Merge 923a213e (origin/develop → branch): it touched NO file this branch changes.**
  - The parents of 923a213e are a03b5ad4 and 6a9312aa.
  - `git diff --name-only a03b5ad4 923a213e` lists 19 files: schedulejob tests, `MockitoTestConventionArchTest`, `NeverMatcherNullBlindnessArchTest`, `ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest`, `ReplenishOrderJobClaimIT`, `docs/plan/sbdev-2945-…`, and `tools/fix_test_constructors.py`.
  - `git diff --name-only a49e6ebd a03b5ad4` lists 11 files: the `security/*` main sources plus the Sdr* tests and the force-cancel IT.
  - The intersection (`comm -12`) is **empty**.
  - Note that the merge does bring in two ArchTests that scan *all* test classes, `MockitoTestConventionArchTest` and `NeverMatcherNullBlindnessArchTest`. They could flag the branch's test files even though no file overlaps. The full suite running in the worktree will settle that.

## 3. Findings (all Low)

### [Low] L1. The WHERE-arm rationale over-generalises, and it slightly contradicts the subquery disclosure two lines above it
Confidence: MEDIUM.

`SdrFunctionRulesUnitTest.java:390-391`:
> "The WHERE arms are not pinned: a caller passing null parameters already reaches every row of the entity, so no edit to the WHERE clause can widen what a holder reads."

There are two problems with this sentence.
1. **It is written as a property of every `ReviewedOverride`, but it is a fact about one query.** It holds for `findByKeyword`, whose every filter has an `IS NULL` bypass. A future entry whose reviewed query has a mandatory filter, such as `WHERE p.clientid = :c` with no bypass, would not satisfy it. That entry would then inherit an unpinned WHERE under a rationale that is false for it.
2. **"no edit to the WHERE clause can widen what a holder reads" is too strong.** Line 389 itself discloses that a subquery after WHERE is not caught. A `WHERE EXISTS (SELECT u FROM OtherEntity u WHERE … :keyword …)` edit does not widen the *rows* returned, but it lets a holder learn about `OtherEntity` as a boolean oracle. That is the N4 case.

**Fix:** reword as "…not pinned: for the reviewed `findByKeyword`, null parameters already return every `ReceivingDtoView` row, so a WHERE edit cannot widen the *rows* returned (it can still add a subquery, above). A new entry whose query has a mandatory filter needs its WHERE pinned."

### [Low] L2. The named-query disclosure lists two of the four sources
Confidence: HIGH that it is incomplete; impact is trivial.

`SdrFunctionRulesUnitTest.java:386`:
> "({@code Printer.findByType} in {@code @NamedQuery} or {@code jpa-named-queries.properties})"

`@NamedNativeQuery` on the entity and `<named-query>` in `META-INF/orm.xml` also resolve under the same name and also replace derivation. Both are absent today (verified), so "neither exists" stays true. The list just under-states the route.

**Fix:** write "in `@NamedQuery`/`@NamedNativeQuery`, `orm.xml` or `jpa-named-queries.properties`", and make "neither" read "none".

### [Low] L3. The new counter message names one cause, but the author's own counter-mutant fails it for a different cause
Confidence: MEDIUM.

`CustomerorderForceCancelOutboxIntegrationTest.java:190`:
> `.as("control: UnitloadRepository.save must reach the stubbed answer, not the real repository")`

The mutant the author used to prove this assertion removes the `incrementAndGet()` from the `doAnswer`. In that mutant the stub *did* run and the real repository was *not* reached, yet the message says "not the real repository". As N6.1 established, the realistic real-repository case (no stub at all) throws before this line. So the message describes the case it rarely sees and misdescribes the one used to validate it. "must reach the stubbed answer" is correct; only the elaboration is off.

**Fix:** use `"control: UnitloadRepository.save must run the counting stub (0 => stub not matched, bypassed, or its body changed)"`.

## Open questions (surfaced, not blocking)
- **[Low] Dropped reset vs a future `PER_CLASS`.** Confidence: LOW that it matters.
  - Without `set(0)`, a class-level `@TestInstance(PER_CLASS)` or a `junit-platform.properties` lifecycle default would let the second test's `isPositive()` pass on the first test's count.
  - Nothing selects `PER_CLASS` today, and the previous review said either choice was acceptable.
  - **Fix, only if wanted:** restore `stubbedParcelSaves.set(0)` in `@BeforeEach`, or assert `isEqualTo(1)`.

## Positive observations
- N1 is a pure reflow. The words are identical and only the breaks moved, which is the right way to fix a width finding without re-review risk.
- N3, N4 and N5 are all disclosed, and every disclosure is TRUE as written. "neither exists in src/main today" is a dated, checkable claim, not a promise.
- N2 now gives the real reason the WHERE clause is safe to leave unpinned (the null-parameter bypass), not the inverted "narrowing" claim.
- The commit carries no production-behaviour change, and the merge from develop touches none of the branch's files.

## Recommendation
**COMMENT.** Nothing blocks. Under the fix-every-Low rule, L1, L2 and L3 are each a one-line comment or message edit, with no test or behaviour change. The open question is optional.
