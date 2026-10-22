---
head: 61366313
base: 76f60dc2
lane: scoped re-review (code + security) of the review-fix commit
date: 2026-10-22
verdict: APPROVE
---

head: 61366313

# SBDEV-3873 PR 1: re-review of the review-fix commit 61366313

**Verdict: APPROVE.** 0 High, 0 Medium, 2 Low, 1 Info. Every claimed fix resolves its finding. One test-editing slip
(Low F1) moved an existing assertion into the wrong test. It should be fixed in this pass, per the "fix Low findings too" rule.

## Evidence
- Scope: `git show 61366313` in `.claude/worktrees/wms2-api/SBDEV-3873`. The stale main checkout was not consulted.
- I ran `mvn -o -q test -Dtest='AdviceSetCommentContextTest,SdrPatchFieldFenceContextTest,AdviceServiceUnitTest'` and it exited 0.
  The surefire reports were written at 14:03:23, during this run:
  - AdviceSetCommentContextTest: 14 tests, 0 failures, 0 errors, 0 skipped.
  - SdrPatchFieldFenceContextTest: 4 tests, 0 failures, 0 errors, 0 skipped.
  - AdviceServiceUnitTest: 63 tests across its 20 nested classes, all passing. `$SetComment` has 4 tests.
- The 422 body shape comes from `ApiInvalidParameterException(message, field)`, which builds `new ApiParameterErrorMessage(field, message)`.
  That produces `parameterErrors: [{<field>: <message>}]`, and `RestExceptionHandler:60` serves it.
- The 409 claim was checked against `RestExceptionHandler:384-390`, where `ObjectOptimisticLockingFailureException` maps to `HttpStatus.CONFLICT`.

## Finding-by-finding

| Finding | Resolved? | Note |
|---|---|---|
| code L1 (PR-W described as shipped) | Yes | Advice.java, Cyclecount.java (both blocks), AdviceStateReadOnlyContextTest and the Sbdev3017 row now use future or conditional tense ("moves to … in the web PR", "calls it once the web PR ships", "Until the web PR removes it … still echoes a PATCH, which now binds nothing"). I grepped `src/main` and `src/test` for "PR-W" and "web PR" and found no remaining present-tense claim. |
| code L2 ("read only by SDR's web binding") | Yes | The comment now names the `/v3/profile` JSON schema as a second SDR consumer, so the "only" is scoped to Spring Data REST. |
| code L3 ("for any caller") | Yes | The text now says "any wms_user while the tenant's SDR guard mode is below ENFORCE_RULED". The parenthetical "every tenant at the time" is a point-in-time fact, and I did not re-verify it against the landlord DBs because the MCPs were down. It is not counted. |
| code L4 (422 status-only) | Yes | AC-4 and AC-10 now assert `rejectedParameters(response)` with `containsExactly("comment")` and `containsExactly("id")`. |
| code L5 (JSON-Patch 400, no positive control) | Yes | `adviceJsonPatch_shouldReturn2xxAndWriteComment_whenReplacingComment` uses the same media type and patch shape, expects 2xx and checks that the DB shows `"jp"`. That proves the 400 is caused by `/externalid`. |
| code L6 (Jackson id coercion) | Declined; see F2 | |
| code L7 (UTF-16 vs code points) | Yes | The constant javadoc now says UTF-16 units, conservative relative to varchar, matching the browser maxlength. |
| code L8 (hygiene) | Yes | Added `@throws` for the 409 (accurate, see Evidence), moved the constant up, sorted the imports, and replaced the inline fully-qualified names with an import. |
| code L9 (TDD tense) | Yes | Now reads "were written before the handler … existed". |
| sec L3 (NUL gives 500) | Yes | `comment.indexOf('\0') >= 0`. In Java, `'\0'` is an octal escape for U+0000, so it is equivalent to `'\u0000'`. The check is null-guarded and runs before the load, after the length check; NUL plus over-length returns the length 422, which is fine. A unit test and an HTTP test cover it, and mutant m11 is killed by both. |
| sec L1, L2, I1 (PR description) | Sound disposition | These are residuals or documentation-only, and PR 2 closes them. Code changes in PR 1 would contradict the D5 stop-gap. They are only satisfied if the PR body actually states them, and that cannot be checked until the PR exists. |
| sec I2, I3 | No action needed | |

`rejectedParameters` does not pass vacuously. A body with no `parameterErrors` (or a non-list value) returns an empty
list, and `containsExactly("comment")` fails on an empty list. A ProblemDetail-shaped 422 would therefore fail the
assertion, which is the intended behaviour. A non-map list element would throw `ClassCastException`, which also fails the test. A non-JSON or empty body throws from `readValue`, which fails too.

## Findings

### [LOW] F1: the AC-10 test lost its "DB unchanged" assertion, and that assertion now sits in the NUL test with the wrong message
Confidence: HIGH. File: `src/test/java/net/aim_ai/wms/security/AdviceSetCommentContextTest.java`, in `setComment_shouldReturn422_whenCommentContainsNul`:
```java
        assertThat(reload().getComment()).as("Advice.comment must be unchanged after a rejected NUL write")
                .isEqualTo(SEEDED_COMMENT);
        assertThat(reload().getComment()).as("Advice.comment must be unchanged when the id is missing")
                .isEqualTo(SEEDED_COMMENT);
```
The new test was inserted inside the closing lines of `setComment_shouldReturn422_whenIdIsMissing`. That method now ends at
`containsExactly("id");` and no longer checks the DB. The NUL test gained a duplicate reload whose message describes a
different scenario. If it fails, it would report "when the id is missing" for a NUL failure.
Impact is small: a body with no id cannot address a row, so the dropped assertion guarded little. But it is a silent loss of
a pre-existing assertion plus a misleading failure message.
Fix: move the second `assertThat(reload()…"when the id is missing")` back to the end of `setComment_shouldReturn422_whenIdIsMissing`,
after the `rejectedParameters` assertion.

### [LOW] F2: the L6 decline is sound, but the stated reason is inaccurate
Confidence: HIGH (that the rationale is inaccurate). The code review's suggested fix was local, not global: `@JsonFormat(shape = NUMBER_INT)` on the record
component, or a service-side integrality check. So "changing coercion is global ObjectMapper config affecting every typed
DTO" is not the real trade-off. The decline still holds on the other grounds given: the code review rated L6 at LOW confidence, the route is
gated, the truncated id is one the caller could send directly, and no authz or integrity consequence follows.
Fix: in the PR description or decision log, restate the reason as "a local fix exists (`@JsonFormat` on the record), and it was
declined because there is no exploit; the caller could send the integer id directly." No code change.

### [INFO] I1: the NUL unit test checks only the exception type
`AdviceServiceUnitTest.setComment_shouldRejectBeforeLoading_whenCommentContainsNul` does not check `getFieldName()`. The HTTP
twin pins `"comment"`, so the guarantee is still covered. Optional: add `.extracting("fieldName").isEqualTo("comment")`.

## No new defects found in
- The NUL check (char literal, null guard, ordering before `findById`).
- The javadoc on the 409 (`@throws` on a `@Transactional` method surfaces at the proxy commit, and `RestExceptionHandler` maps it to 409).
- The JSON-Patch control: it writes "jp" and commits through the non-rollback base, and the class `@AfterEach` deletes by id, so the change is not leaked.
- No security regression: the change adds input rejection only and no new route, gate or logging. The 422 message is fixed text and does not echo the input.

## Counts
High 0 · Medium 0 · Low 2 (F1, F2) · Info 1. **APPROVE.** F1 should be fixed before the PR. F2 needs only a wording change in the PR description.
