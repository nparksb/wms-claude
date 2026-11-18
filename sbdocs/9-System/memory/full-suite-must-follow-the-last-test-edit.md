---
name: full-suite-must-follow-the-last-test-edit
description: "A test added after the clean full suite is graded only by its own class; repo-wide arch rails (NeverMatcher, etc.) never see it, so CI reds"
metadata:
  type: feedback
---

On 2026-11-02 (SBDEV-3993, wms2-api PR #609) I ran a clean full suite (9579 run / 0 failures), then
added one more test to address a review Nit, and re-ran **only its own class** before committing.
That test used `verify(repo, never()).save(any(Adviceposition.class))`. CI then went red on
`NeverMatcherNullBlindnessArchTest`, a **repo-wide source-scanning rail** that a class-scoped run
never executes. The local "full suite passed" claim was true, but about an older tree.

**Why:** wms2-api has many ArchUnit or source-scan rails in `unit/config/` that grade **other** files
(NeverMatcher, Mockito `never()`/varargs, OptionalStringFilter, PublicHandler contract, JUnit tag wiring).
A scoped `-Dtest=<MyClass>` run cannot see them. Any edit, test-only ones included, can trip one.

**How to apply:** the full suite must be the LAST thing run before a commit or push. After any edit
that follows it, even a single test-only line, run the full suite again (about 6 min), or at minimum
`-Dtest='*ArchTest,<MyClass>'` plus the relevant `unit/config` rails. Then the full suite before push.
When writing `verify(x, never())`, use bare `any()` for a single reference parameter. Keep
`any(X[].class)` for varargs and `anyInt()` etc. for primitives (see the rule's message). Related:
[[hub-wms2-test-harness]], [[hub-maven-false-verdicts]].
