---
head: 8d82e014
---

# SBDEV-3128: code review r4 (r3 Low fixes)

**head: 8d82e014**. Scope: `git diff 747b9a39..HEAD`, 2 files, +6/-4 (one comment, one test method). Method: read-only (git diff, grep, targeted sed). No mvn, no checkout/restore/stash, main checkout not read. The "15 tests green" and mutant claims were checked by reading, not by running.

## Verdict: APPROVE

0 High, 0 Medium, 0 Low, 0 open questions. Both r3 Lows (L-A, L-B) are fixed as r3 asked.

## Findings vs r3
- **L-A (test asserted stripped representation):** fixed. `LocationControllerUnitTest.java:270-280` now asserts `isEqualByComparingTo("0.00005")` (value) and `scale().isGreaterThan(4)` (the invariant the service's `scale > 4` check relies on). This is the exact fix r3 proposed.
- **Rename:** `updateBoundDefaults_fiveDecimals_keepScaleAboveFour`; no stale `keepScaleFive` in src. The only remaining mention is the r3 review text itself, as history.
- **Display name:** now "a genuine fifth decimal still reaches the service above scale 4 (the service refuses it)", consistent with the body. The "service refuses it" clause describes intent; the controller test mocks the service, and the refusal is covered by FixLocationAssignmentServiceUnitTest (r3 accepted this).
- **L-B (comment overclaim):** fixed. `LocationController.java:171-172` now says "a genuine fifth decimal in Jackson's Double text still reaches the scale check and is refused there". That scopes the claim to Double-derived text, and matches the code (`scale() > 4 ? stripTrailingZeros() : parsed`).

## Checks
- **No assertion lost:** the old `scale == 5` assertion was replaced by a weaker-by-design `> 4` plus a new value assertion. The `verify(...updateLocationBoundDefaults(eq(5L), min.capture(), any(), any()))` and `status().isOk()` are untouched. Net assertions: 2 to 3. The `== 5` exactness is intentionally dropped per r3.
- **Mutant claim holds by reading:** round-to-scale-4 yields 0.0001, so the value assertion fails (and the scale is 4, so `> 4` fails). Unstripped scale 6 still passes `> 4` and the value check, which is correct because the service refuses it either way. Strip-to-wrong-digits at scale 5 now fails the value assertion (previously survived).
- **Test count:** 15 `@Test` occurrences in the class, matching the author's "15 tests".
- **API validity:** `isEqualByComparingTo(String)` exists on AssertJ `AbstractBigDecimalAssert`; `assertThat(BigDecimal)` resolves to it. assertj-core is in pom.xml.

## Ruled out
- Production behavior change: the main-code diff is comment-only (the logic lines are in context, unchanged).
- Comment inaccuracy: wording matches the logic; r3's non-Double `BigDecimal("100000.00000")` case is now outside the claim's stated scope.
- Stale references to the old test name in src.
- Diff touching anything beyond the two files and the stated hunks.
- Style nit only: fully-qualified `org.assertj.core.api.Assertions` is inline, consistent with the neighbouring lines in the same method (not a finding).

## Positive observations
- The fix keys the test on the observable invariant instead of an implementation artifact.
- Both Lows were handled in one small commit, per the house rule.

## Recommendation: APPROVE
