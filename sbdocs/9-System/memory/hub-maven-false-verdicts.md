---
name: hub-maven-false-verdicts
description: Ways mvn/surefire/failsafe report a pass or count that is false. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Maven/surefire/failsafe false verdicts**. Moved out of MEMORY.md on 2026-10-15 to keep the index under its size limit; each line links the member memory.

- [[mvn-without-clean-runs-deleted-tests]]: mvn test runs DELETED test classes
- [[surefire-does-not-propagate-user-locale-props]]: surefire ignores -Duser.language
- [[maven-it-test-exclusion-discards-includes]]: -Dit.test='!X' drops pom includes
- [[surefire-selector-that-matches-nothing-leaves-stale-xml]]: No-match -Dtest leaves stale XML
- [[maven-failsafe-false-green-traps]]: Three more failsafe false-greens incl. zero-IT BUILD SUCCESS
- [[failsafe-without-compile-runs-stale-classes]]: failsafe w/o compile = stale classes
- [[surefire-xml-tally-must-subtract-skipped]]: XML tally must subtract skipped
- [[selected-test-classes-is-not-the-suite]]: Selected -Dtest run ≠ the suite
- [[mvn-test-cannot-see-the-integration-lane]]: mvn test can't see integration lane
- [Full suite must follow the LAST edit](full-suite-must-follow-the-last-test-edit.md) — a test added after the clean run is graded only by its class; repo-wide arch rails miss it and CI reds
- [[test-only-commits-still-need-the-archunit-rails]]: ArchUnit rails scan test code; re-run *ArchTest after test-only commits
- [[standalone-surefire-test-reads-stale-reports]]: `mvn -q surefire:test` in a loop read the previous report — delete reports per run, known-red control first
- [[signature-change-leaves-test-classes-stale]]: main signature change → incremental test-compile exits 0 on stale tests; clean first
