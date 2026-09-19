---
name: maven-it-test-exclusion-discards-includes
description: -Dit.test='!Class' discards the pom's <includes> and makes failsafe run the WHOLE test tree; use -Dfailsafe.excludes
metadata:
  type: project
---

An exclusion-only `-Dit.test='!SomeClassIT'` does NOT filter the configured lane. It makes
surefire's `isSpecificTestSpecified()` true, which **discards the pom's `<includes>` entirely**, so
failsafe runs every class in the test tree minus the named one. On wms2-api that meant the whole
unit suite ran a SECOND time in the integration lane: ~484 classes instead of ~80.

Use `-Dfailsafe.excludes='**/SomeClassIT.java'` instead (a real user property in failsafe 3.1.2:
`<excludes>${failsafe.excludes}</excludes>`). It preserves `<includes>` and removes exactly one
class. An explicit empty `<excludes/>` in the pom does NOT make the property inert — measured.

**Why it survives review:** it makes CI *slower and greener at the same time*, which nobody
investigates. Live on wms2-api's develop deploy gate from `74911c8b` until `c4d920eb` (2026-09-09).

**How to detect it in any repo:** pick a class that matches NO `<includes>` pattern (a plain
`*UnitTest`) and count its occurrences in the CI log. Two occurrences = includes discarded. On
wms2-api run 34378495400, `TimezoneServiceUnitTest` appeared at both line 61715 and line 139710,
and the IT lane reported 6779 tests against the unit lane's 6398 — MORE, not fewer. After the fix:
381 in the IT lane, one occurrence, 15 min -> 11 min.

⚠ **A probe can't see this without a negative control.** A review lane cleared this exact flag using
an isolated Maven probe containing ONLY classes matching `<includes>` — where "honours includes" and
"runs everything" produce identical output. Adding one non-matching `ZetaUnitTest` separated them
immediately. See [[a-zero-scan-needs-a-positive-control]] and
[[review-lanes-must-not-share-a-worktree]].
