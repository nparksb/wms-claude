---
name: surefire-selector-that-matches-nothing-leaves-stale-xml
description: "A -Dtest selector that matches nothing leaves the PREVIOUS run's surefire XML in place, so reading the XML returns a stale verdict that looks current"
metadata: 
  node_type: memory
  type: reference
  originSessionId: c1fe6354-5fbf-4355-b025-64714fd8e3ae
  modified: 2026-09-11T12:19:14.663Z
---

`mvn -o -q test -Dtest='ClassA+ClassB'` — note the `+` — is not a valid surefire class selector
(the separator is `,`). Surefire matched **nothing**, the build exited **0**, and `-q` swallowed the
`Tests run: 0` line. Then reading `target/surefire-reports/TEST-*.xml` returned the **previous
run's** results, because a run that selects no tests **writes no XML and deletes none either**.

Measured 2026-09-11 on SBDEV-3316. I read `4 tests / 0 failures` for one class and `3 tests /
1 failure` for another and believed both. They were two *different earlier* runs — one from before
the fix, one from after. The stale failure carried a stack trace pointing at
`CancellationReversalService.java:220`, and I spent a round reading line 220 of the **edited** file,
where the line had shifted to a different statement entirely. Every artifact was internally
consistent and honest-looking; only the timestamp was wrong.

**Why it is nastier than [[mvn-without-clean-runs-deleted-tests]]:** that one inflates a count. This
one hands you a *verdict* — pass or fail, with a stack trace — for code you did not run. And the
failure mode is silent in both directions: a stale green after you broke something, or a stale red
after you fixed it.

**Practice**

- Separate classes with `,`, never `+` or a space.
- `rm -f target/surefire-reports/TEST-<the classes>.xml` before the run, then assert the files exist
  afterwards. A missing file is the signal that the selector matched nothing.
- Read the **console** `Tests run:` line as the primary result, not the XML; drop `-q` when the
  number matters. `[INFO] Tests run: N` per class plus the totals line is the cheap check.
- Add `-Dsurefire.failIfNoSpecifiedTests=false` only when you *intend* a possible no-match (see
  [[wms2-running-one-integration-test-locally]]); with it set, a typo'd selector cannot fail the
  build, which is exactly how this stays invisible.

Same family as the documented `@Nested` trap (`-Dtest='Outer#method'` matches nothing and reports
BUILD SUCCESS) — the general rule is **a selector that matches nothing must never be read as a
result**. Related: [[a-zero-scan-needs-a-positive-control]],
[[failed-regex-resolution-must-not-become-a-verdict]], [[green-tests-that-prove-nothing]].
