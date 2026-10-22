head: 610fda68

# SBDEV-3873 PR 1: second re-review (scoped to commit 610fda68)

Reviewer: an independent code-reviewer lane (not the author). Scope: `git show 610fda68` in `.claude/worktrees/wms2-api/SBDEV-3873`.
I checked it against F1 and I1 in `review-pr1-rereview.md`.

## Verdict
**APPROVE.** F1 and I1 are both fixed correctly and completely. I found no new findings: High 0 · Medium 0 · Low 0 · Info 0.

## Scope check
- `git diff 61366313 610fda68 --stat` touches only two files, both tests, with 6 insertions and 3 deletions:
  - `src/test/java/net/aim_ai/wms/security/AdviceSetCommentContextTest.java` (+2/-2)
  - `src/test/java/net/aim_ai/wms/unit/service/AdviceServiceUnitTest.java` (+4/-1)
- No `src/main` file changed and nothing else changed. The worktree is clean.

## F1: the "DB unchanged" assertion is back in the missing-id test
- `setComment_shouldReturn422_whenIdIsMissing` (lines ~361-374) now ends with these three checks in order:
  1. the status assertion (`isEqualTo(422)`)
  2. `rejectedParameters` with `containsExactly("id")`
  3. `reload().getComment()` with `isEqualTo(SEEDED_COMMENT)` and the message "when the id is missing"

  This matches the fix that F1 prescribed.
- `setComment_shouldReturn422_whenCommentContainsNul` keeps its own three assertions: status 422, `containsExactly("comment")`, and one DB-unchanged reload with the "after a rejected NUL write" message. The duplicate reload with the wrong message is gone.
- No assertion was lost or duplicated. The diff moves the identical two-line assertion from one method to the other, and its text is unchanged. `grep -c 'when the id is missing'` returns 1.

## I1: the NUL unit test pins the field name
- `setComment_shouldRejectBeforeLoading_whenCommentContainsNul` now chains `.isInstanceOf(ApiInvalidParameterException.class).extracting(e -> ((ApiInvalidParameterException) e).getFieldName()).as(...).isEqualTo("comment")`.
- The cast is safe because `isInstanceOf` runs first, so a wrong type fails before `extracting`.
- `getFieldName()` exists at `ApiInvalidParameterException.java:41`.
- `verifyNoInteractions(adviceRepository)` is kept.
- The mutation evidence agrees. `mutation-pr1.md` § "Re-review fix (head 610fda68)" reports that m11b (NUL thrown without its field name) is killed by both the context test and the unit test, for 18/18 killed overall. I did not re-run the mutant. The new assertion is a direct equality on the field name that m11b removes, so the claimed kill is consistent with the code.

## Test run (this lane)
I ran `mvn -o -q test -Dtest='AdviceSetCommentContextTest,AdviceServiceUnitTest'` at 14:06 on 2026-10-22 and it exited 0. The surefire XMLs are timestamped 14:06:33-14:06:36, so they come from this run.
- AdviceSetCommentContextTest: 14 tests, 0 failures, 0 errors, 0 skipped.
- AdviceServiceUnitTest: 63 tests across 20 nested classes, 0 failures, 0 errors, 0 skipped. `$SetComment` has 4 tests.
- Both counts are the same as at 61366313, which is expected for a change that only adds assertions.

## Outstanding from the prior round (not code)
- F2 needs only a wording change, and it belongs in the PR description or the decision log. This commit does not address it and was not expected to.

## Positive observations
- The fix is minimal and does exactly what F1 prescribed.
- The unit-level field-name pin means the guarantee is now covered at both the HTTP layer and the service layer.
