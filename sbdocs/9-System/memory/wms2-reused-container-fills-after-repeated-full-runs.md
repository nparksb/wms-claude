---
name: wms2-reused-container-fills-after-repeated-full-runs
description: "2-3 back-to-back `mvn clean verify -Pci` runs on the reused Testcontainers Postgres push sequences into the fixed-id band and residue into paged queries → false IT reds; drop the container before the FINAL run"
metadata:
  node_type: memory
  type: project
  originSessionId: 31d6bf5b-4743-4082-92c0-bd0709d52faa
  modified: 2026-10-25T01:56:14.352Z
---

This was measured twice on 2026-10-24/25 (SBDEV-3862 and SBDEV-3908). After two or three consecutive full runs against the reused `postgres:14-alpine` container (`testcontainers.reuse.enable=true`), the failsafe lane goes red in tests that have nothing to do with the change.

**The usual red set:**
- `OrderReleaseSectionQueryIT` (4 tests): its own guard says "seqentities has climbed into the reserved fixed-id band (9001-9983) … drop it (`docker rm -f`)".
- `MessageRepositoryNativeSearchIT` (1-3 tests): the first 50-row page is filled with residue rows, so the test's own ids are not on it.
- `CustomerorderBatchServiceParallelStreamRegressionIT`: `duplicate key … unitload_pkey Key (id)=(98xx)`. The sequence has reached ids that tests seed by hand.

After `docker rm -f <container>`, a fresh run comes back fully green (SBDEV-3862: 8801/0 unit, 1000/0 IT).

**Why it matters:** it looks exactly like a regression on the branch under test, and it costs a full re-run plus an investigation every time.

**How to apply:**
- Before the FINAL full-suite run of a ticket (the one that grades the PR), check that no other Maven is running (`pgrep -f '[j]ava.*plexus-classworlds'`) and that only your lease is active. Then drop the reused container (`docker ps` → the `postgres:14-alpine` one; `docker rm -f`).
- If the reds above show up mid-ticket, read the guard message before debugging anything.
- **When another lease is live** (e.g. a peer's `wms-merge`, which runs full suites on the same container), do NOT
  `docker rm -f` it. Run your grading suite with `TESTCONTAINERS_REUSE_ENABLE=false mvn -B -o clean verify -Pci`
  instead. You get a fresh throwaway Postgres (Ryuk removes it afterwards) and the shared one is untouched.
  SBDEV-3591, 2026-10-29: 9200/0 unit, 1087/0 IT, where the reused container had given 7 false IT reds.

Related: [[concurrent-maven-one-worktree-false-reds]].

**Also for mutation-checking a NEW migration (SBDEV-3552, 2026-10-31):** once the real `V2.2.x` has applied on the reused container, editing that file to a mutant reds as `FlywayValidate: Migrations have failed validation` (checksum) — a red, not an attributable kill. Run the mutant with `TESTCONTAINERS_REUSE_ENABLE=false` so it migrates fresh. The same env var also isolates you from a peer session's concurrent ITs on the shared container (that day: 176 errors across 25 unrelated classes → 0 on an isolated run).
- **When peer sessions are busy, do NOT drop the shared container.** Run the graded IT lane on a private fresh one instead: `TESTCONTAINERS_REUSE_ENABLE=false mvn verify -Pci -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` (Ryuk cleans it up). SBDEV-3982, 2026-11-01: 17 reds in the reused container (`PickPackReachableColumnIT` x10 joins the usual set), then 1163/0 on the private one while three peers' test JVMs kept using the shared one.
