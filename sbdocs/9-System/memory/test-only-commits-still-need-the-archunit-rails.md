---
name: test-only-commits-still-need-the-archunit-rails
description: "wms2-api ArchUnit rails scan TEST code (never() matchers, test tx managers, etc.) — after any test-only commit, re-run *ArchTest, not just the edited class"
metadata:
  node_type: memory
  type: feedback
  originSessionId: f2a9488c-7592-4763-ae7c-34861c76dc41
  modified: 2026-11-05T14:10:25.330Z
---

On SBDEV-2045 (2026-11-05), PR #621's CI went red on `NeverMatcherNullBlindnessArchTest`. A late "test-only" commit had added `never().delete(any(PickingorderPosition.class))`. I had graded that commit by re-running only `CustomerorderServiceUnitTest`. The full local verify had run one commit earlier, so nothing ran the rails on the change.

**Why:** several wms2-api ArchUnit tests inspect test sources:
- `NeverMatcherNullBlindnessArchTest`: bare `any()` inside `never()`, plus a primitive-matcher count inventory;
- `TestClassTransactionManagerArchTest`: NOT_SUPPORTED classes must be listed in `EXEMPT_NON_TRANSACTIONAL`;
- `JUnitTagWiringArchTest`.

A test-only edit can fail any of these. The edited class going green says nothing about them.

**How to apply:**
- After ANY commit that touches `src/test`, run `mvn -o test -Dtest='*ArchTest,<EditedClass>'` before pushing, or the full unit lane.
- Grade what CI grades: CI tests the PR merged onto current develop. Use a detached scratch worktree with `git merge origin/develop` and run `mvn -Pci test` there. That reproduced CI's exact test count, 9712.
- Related: [[hub-maven-false-verdicts]].
