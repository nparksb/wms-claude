---
name: maven-failsafe-false-green-traps
description: "Three more ways the wms2-api failsafe lane reports success on tests that did not run or did fail — skipTests leaves stale XML, failsafe:integration-test never fails the build, and a full verify can run ZERO ITs yet say BUILD SUCCESS (check for two summary lines)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 0a3c8a18-078e-4915-af56-c67bd7a21d3d
  modified: 2026-09-15T19:42:29.976Z
---

Two failsafe traps, found 2026-09-15 during SBDEV-3363's AC-4 review. Both produce a **green-looking
result from a run that proved nothing**, and neither is in `v2/wms2-api/CLAUDE.md`'s existing list.

1. **`-DskipTests=true` skips failsafe too, and leaves the PREVIOUS run's XML in `target/failsafe-reports/`.**
   So a subsequent "did my IT pass?" check that reads the report files gets the *older* run's verdict.
   If you skip tests for a fast build, delete or ignore the reports; never read a `Tests run:` line
   without confirming the run that produced it.
2. **`mvn failsafe:integration-test` prints BUILD SUCCESS even with failing tests.** The goal records
   results; **`failsafe:verify` is the goal that fails the build on them.** Running the first alone and
   reading the build status is a false pass. This is a *different* trap from the one CLAUDE.md already
   documents (`failsafe:integration-test -Dit.test=<Class>` reporting `Tests run: 0` for any class,
   SBDEV-3091) — that one is about the goal being a no-op outside the lifecycle; this one is about it
   not failing when tests genuinely ran and went red.

**How to apply:** run the full `verify` phase, and read the `Tests run: N, Failures: F, Errors: E` line
rather than the BUILD status. Related: [[wms2-running-one-integration-test-locally]],
[[surefire-selector-that-matches-nothing-leaves-stale-xml]],
[[mvn-without-clean-runs-deleted-tests]], [[a-zero-scan-needs-a-positive-control]].

3. **A full `mvn clean verify -Pci` can print BUILD SUCCESS with the failsafe lane having run ZERO tests**
   (measured 2026-10-09, SBDEV-3720). The log shows `failsafe:integration-test` immediately followed by
   `failsafe:verify` with no "Using auto detected provider" / no "Tests run:" line, and
   `target/failsafe-reports/failsafe-summary.xml` reads `result="254"` `<completed>0</completed>`. Tell:
   `target/classes` and `test-classes` mtimes fell AFTER the surefire reports, i.e. something recompiled the
   worktree mid-run (jacoco also warned "Execution data ... does not match"). Cause not pinned — a concurrent
   process touching that worktree's target/ is the likely one. **Check: the verify log must contain TWO
   `Tests run: N, Failures:` summary lines (surefire + failsafe), and failsafe-summary `completed` must be
   non-zero. A single summary line is not a green.**
