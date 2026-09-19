---
name: failsafe-without-compile-runs-stale-classes
description: mvn failsafe:integration-test with no compile phase runs stale target/classes — every mutant silently SURVIVES, which reads as clean evidence
metadata:
  type: reference
---

`mvn -o jacoco:prepare-agent failsafe:integration-test -Dit.test=<Class>` executes, reports real test
counts, and runs the **previously compiled** `target/classes`. Neither goal compiles. So after editing
a source file the run grades the OLD bytecode.

**The dangerous direction is mutation testing.** Every mutant comes back `SURVIVED`, with honest-looking
counts and no error — indistinguishable from a genuine survival, and it agrees with "the code is fine",
which is usually what you were hoping. Measured on SBDEV-2371 (2026-09-17): a review lane's first three
mutant runs all reported SURVIVED and were all invalid; prepending `test-compile` flipped the control
to KILLED.

Always: `mvn -o test-compile jacoco:prepare-agent failsafe:integration-test -Dit.test=<Class> -DfailIfNoTests=false`
— or, better, the repo's own recipe from `v2/wms2-api/CLAUDE.md`, which goes through the lifecycle and
compiles on its own:
`mvn verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`

⚠ `jacoco:prepare-agent` is separately **required** with the standalone goal: without it failsafe's
`@{argLine}` is never substituted and the fork dies with *"The forked VM terminated without properly
saying goodbye"*. That one is loud. The stale-bytecode failure is silent, which is why it matters more.

This is a THIRD failure mode of the standalone goal, on top of the one `v2/wms2-api/CLAUDE.md` already
records (SBDEV-3091: `Tests run: 0` + BUILD SUCCESS for any class outside the lifecycle).
Related: [[mutation-harness-traps]], [[a-zero-scan-needs-a-positive-control]],
[[surefire-selector-that-matches-nothing-leaves-stale-xml]], [[mvn-without-clean-runs-deleted-tests]].
