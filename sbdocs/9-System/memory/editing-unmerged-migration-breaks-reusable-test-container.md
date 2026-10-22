---
name: editing-unmerged-migration-breaks-reusable-test-container
description: Editing a new V2.2.x after a local mvn verify applied it → 51 wms2 ITs fail FlywayValidate checksum mismatch on the shared reusable container
metadata:
  node_type: memory
  type: feedback
  originSessionId: d8604442-fd63-442e-8753-45c7e1cca1a5
  modified: 2026-10-05T02:39:23.386Z
---

Editing a not-yet-merged `db/migration/V2.2.x` file (even only its description text) AFTER a local `mvn verify` has run makes ~50 wms2-api IT classes fail with `FlywayValidate: Migration checksum mismatch for migration version 2.2.x`. Hit on SBDEV-3626, 2026-10-05: 51 errors, all from one line of seed-description text.

**Why:** the shared `AppPostgresDBContainer` uses Testcontainers reuse (`withReuse(true)` + `~/.testcontainers.properties`). The first run records the migration's checksum in that container's `wms_test.flyway_schema_history`, and the record survives across runs and sessions. CI uses fresh containers and never sees it, so this is a local-only false red. It looks like a broad regression.

**How to apply:**
- Before editing an unmerged migration you already ran locally, expect this.
- Repair it surgically, not with `docker rm -f`, because other sessions share that container (see [[concurrent-maven-one-worktree-false-reds]]): `docker exec <id> psql -U test -d wms_test -c "delete from flyway_schema_history where version='2.2.x'"`. This is safe only when the migration is idempotent (`WHERE NOT EXISTS` seeds are), because the next run re-applies it.
- Check with `grep 'checksum mismatch' <log>` before reading the failures as yours.
- Related: [[flyway-version-pick-sweep-all-remote-branches]].
