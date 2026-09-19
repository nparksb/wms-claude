---
name: wms2-testcontainers-reuse-breaks-an-it
description: Enabling testcontainers.reuse.enable (as wms2-api CLAUDE.md instructs) makes ParcelMonitorViewServiceConcurrencyIT fail on accumulated rows — a false red that looks like your change
metadata: 
  node_type: memory
  type: project
  originSessionId: 0a3c8a18-078e-4915-af56-c67bd7a21d3d
  modified: 2026-09-15T17:41:29.131Z
---

`v2/wms2-api/CLAUDE.md` says *"Turn container reuse on once per machine"*
(`echo 'testcontainers.reuse.enable=true' >> ~/.testcontainers.properties`). **Doing so makes the IT lane go
red on a test that has nothing to do with your change.**

Measured 2026-09-15 (SBDEV-3363), on a worktree off `origin/develop` `9e294d4b`:

- With reuse on and a container up ~1h: `mvn clean verify` → surefire `6629/0/0/1` (clean), failsafe
  `412 run, 0 failures, 1 error`, **BUILD FAILURE**. The error:
  `ParcelMonitorViewServiceConcurrencyIT.concurrentFindByIdForUpdate_secondThreadSeesCommittedState_noRedundantWrite`
  → `DataIntegrityViolationException: duplicate key value violates unique constraint
  "index_customerorder_externalnumber"`.
- `docker rm -f` every `org.testcontainers=true` container, re-run that IT alone → **passes, 25s**.

So it is accumulated rows in the reused Postgres, not a code defect. CLAUDE.md documents the *class* of
hazard ("a test that assumes an empty table must clean up after itself… if a lane starts failing in a way
that a `docker rm -f` fixes, suspect accumulated state") but names no casualty, so the first time you hit it
the obvious reading is that you broke something.

**How to apply:**
- Before attributing any IT-lane red to your diff, check whether the test references your changed symbols at
  all (`grep -c` for them in the test), then clear containers and re-run that IT alone. Both steps are cheap.
- A **baseline captured with a cold container and a comparison run against a warm one are not comparable.**
  Clear containers before the comparison run, or keep reuse off for baseline work.
- The reuse win here is small anyway: only the shared `AppPostgresDBContainer` honours the flag, and Docker
  is ~9% of suite wall-clock. Related: [[wms2-test-suite-baseline-and-h2-verdict]],
  [[outbox-concurrent-enqueue-it-is-timing-flaky]], [[concurrent-maven-one-worktree-false-reds]].
