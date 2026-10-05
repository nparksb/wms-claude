---
name: surefire-xml-tally-must-subtract-skipped
description: A tally of <testcase> elements that checks only <failure>/<error> reports @Disabled cases as passing; a class-level @Disabled IT reads as a green 11/0
metadata:
  node_type: memory
  type: feedback
  originSessionId: ffd93f1b-3f2e-47c8-9ee4-eb0786bdfb64
  modified: 2026-09-27T00:16:47.725Z
---

On SBDEV-3549 (2026-09-27) I tallied failsafe XML per class and reported "69 tests, 0 failures" for the ITs
over the changed queries. `ReplenishorderRepositoryIntegrationTest` is `@Disabled` at **class** level: its 11
`<testcase>` elements all carried `<skipped/>`, and my script only looked for `<failure>` and `<error>`. So a
test that never ran was published in a PR body as passing coverage. Two nested classes elsewhere (`ArchiveMessages`,
`NativeSqlWithJoins`) were also `@Disabled`. A review lane caught it in round 5, not me.

**Why:** a skipped case is the most dangerous false green. It looks exactly like a pass in a count, and it
drops out of coverage silently. The changed Replenishorder queries turned out to have no executed IT at all.

**How to apply:** any XML tally must count `<skipped>` separately and report run / skipped / failed per class.
Before claiming a test covers a change, confirm from the SOURCE that the test class and its nested class are
not `@Disabled` and that they call the changed method. Related: [[green-tests-that-prove-nothing]],
[[a-zero-scan-needs-a-positive-control]].
