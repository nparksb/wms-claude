---
name: selected-test-classes-is-not-the-suite
description: "Reporting a -Dtest= selected run as 'the suite is green' hid 3 red tests on one PR and 4 on another; only mvn clean test with no -Dtest counts"
metadata:
  node_type: memory
  type: feedback
---

On 2026-09-13, across wms2-api PRs #352 and #353, I twice reported "N tests green" from a
`-Dtest='ClassA,ClassB,...'` run and presented it as the suite being green. Both were false:
#352 carried **3 red tests** (attribution measured per ref: develop 0, #351 0, #352 3) and #353
added a 4th. An independent review lane running `mvn -o clean test` with NO selector found them
immediately.

The reds were exactly the kind a targeted run cannot reach: repo-wide **ArchUnit rails** and
**source-text pins** in unrelated packages (`NeverMatcherNullBlindnessArchTest`,
`SchedulingReconcileIdempotencyUnitTest`, `AdvisoryLockServicePerTenantLockUnitTest`). A change to
`application.properties` or a job's method signature reddens a rail three packages away, and a
selector chosen from "classes I edited" can never include it.

**Also false by construction:** "clean `mvn clean verify`" when surefire fails — failsafe never runs,
so any IT count quoted from that invocation was never observed.

**How to apply:** before claiming a suite result, run `mvn -o clean test` with no `-Dtest`, and quote
that number. A targeted run is fine for the inner loop, but say "the 4 affected classes are green",
never "the suite is green". Capture maven's exit status directly (`MVN_EXIT=$?` on the line after the
command, never after a pipe into grep/tail — that reports the pipe's status and reads as success).
Related: [[mvn-without-clean-runs-deleted-tests]], [[concurrent-maven-one-worktree-false-reds]],
[[green-tests-that-prove-nothing]].
