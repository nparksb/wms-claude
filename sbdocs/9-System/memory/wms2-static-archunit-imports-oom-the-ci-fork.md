---
name: wms2-static-archunit-imports-oom-the-ci-fork
description: "A static JavaClasses field in a wms2 arch test stays on the heap for the whole surefire fork; 17 of them OOM'd CI and stopped develop deploying — release in @AfterAll (rail enforces it)"
metadata:
  node_type: memory
  type: feedback
  originSessionId: d3676c74-2bd7-4023-b57c-1ddb9e27814c
  modified: 2026-10-08T23:26:23.131Z
---

In wms2-api, surefire runs the whole unit lane in ONE forked JVM and keeps every test class loaded, so a
`static JavaClasses` (or static `List<JavaMethod>` etc.) assigned in `@BeforeAll` stays reachable for every
later test. On 2026-10-08 the merge of SBDEV-3292 PR #480 added the 17th such holder and develop's push run
died with `Java heap space` after 6749 of ~8000 unit tests — `test` failed, `build` skipped, develop stopped
deploying. Fixed by PR #482 (`0e9d6f46`): every holder nulls its field in `@AfterAll`, and
`ArchUnitImportReleaseRuleTest` fails the build for any static ArchUnit-domain field not written by an
`@AfterAll`.

**Why:** each PR passed its own CI; only the combination crossed the line, and the margin was already thin
(develop BEFORE #480 also OOM'd locally at the CI-default heap). The red showed up as a surefire fork error
with "Tests run: N, Failures: 0" — easy to misread as flaky.

**How to apply:**
- New arch test: assign the import in `@BeforeAll`, null it in `@AfterAll` — never `static final`.
- Diagnosing a fork OOM: CI sets no `-Xmx`; ubuntu-latest private = 7 GB RAM → ~1.75 GB default heap, which
  reproduces locally with `_JAVA_OPTIONS=-Xmx1750m mvn -o clean test`. Measure with
  `jcmd <pid> GC.class_histogram` — find the pid with `jcmd -l | awk '/surefirebooter/'`; `pgrep -f
  surefirebooter` matches your own polling shell and silently samples nothing.
- After the fix, 8014 tests pass at 1200m. Next likely pressure: the Spring test-context cache (73 classes,
  cache max 32). Pinning `-Xmx` + `HeapDumpOnOutOfMemoryError` was proposed, not done.

Related: [[wms2-no-pipeline-runs-tests]], [[wms2-ui-develop-tag-race-deploys-older-code]].
