---
name: standalone-surefire-test-reads-stale-reports
description: "Mutation loops with `mvn -q surefire:test` read the PREVIOUS run's report — every mutant \"survives\"; delete reports per run and use lifecycle `test`"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 28951ef8-23bd-4e60-ba1b-c71083a47563
  modified: 2026-11-09T13:07:55.333Z
---

On SBDEV-4080 (2026-11-09), a hand-rolled mutation loop over a YAML-reading JUnit test used
`mvn -o -q surefire:test -Dtest=X` and then grepped `target/surefire-reports/X.txt`. Every mutant and
even the known-red pre-fix file "passed" 7/7. The standalone goal did not produce a fresh report, and
`-q` plus `>/dev/null` hid that, so the loop read the last green run's file.

**Why:** a stale report file and a true green are indistinguishable. The tell was the control: the
pre-fix input had failed 5/7 minutes earlier.

**How to apply:** in any loop that reads surefire reports, `rm -f target/surefire-reports/*<Class>*`
before each run, treat a missing report as "did not run", use the lifecycle `mvn -o -q test -Dtest=...`,
and always include a known-red control row first. Related: [[selected-test-classes-is-not-the-suite]],
hub [[hub-mutation-testing]].
