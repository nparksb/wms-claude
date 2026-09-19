---
name: wms2-flyway-migration-facts-corrected
description: "Three claims in shipped wms2 migration headers are FALSE and cannot be edited (Flyway checksums comments): tests DO run db/migration, PRD DOES have the join-table PK, and a deleted applied migration breaks boot"
metadata:
  node_type: memory
  type: project
---

Measured 2026-09-01 on SBDEV-3154 by an adversarial migration lane. **Each of these contradicts a
comment in a shipped migration file, and those files cannot be corrected** — Flyway checksums the
whole file including comments, so editing an applied migration throws `FlywayValidateException` on
every database that ran it. The corrections have to live outside the files.

1. **"No test executes SQL" (V2.2.19 header) is FALSE.** **Eight `*IntegrationTest` classes** run
   `Flyway…locations("classpath:db/migration").migrate()` against Testcontainers in the **failsafe**
   lane (surefire excludes them at `pom.xml:518`, failsafe includes at `:663`). The base dump seeds
   `client` 0, ~80 functions and `super-admin`, so a new migration is **exercisable end-to-end for
   free** — it would catch a 23502, a 23503, a same-id 23505, and the copy-paste hazard where
   statement 2 guards on constant A and silently never inserts B. Use it.
2. **"Production has NEITHER a PK nor a unique index on `mywms_role_mywms_function`" (V2.2.21 header)
   is STALE.** `V2.2.20` gave that table a PK on **all six** tenants, PRD included
   (`mywms_role_mywms_function_pkey`). The comment also conflates it with `mywms_function`, which has
   always had PK(id) + UNIQUE(function) — so the "silent double insert" it warns about would in fact
   be a visible 23505. The two-separate-INSERTs rule is still right; its stated reason is not.
3. **There is no revert path.** `validateOnMigrate` is on with `ignoreMigrationPatterns=*:future`
   (`StartupFlywayMigrator:39-40`), which does **not** cover a *deleted* applied migration — so
   removing the file after dev applies it fails boot validation, silently, with no `success=false`
   row to show it. Plan the version as one-way.

Also confirmed (and it contradicts what I assumed): **out-of-order IS genuinely enabled for tenant
datasources** (`StartupFlywayMigrator:295`, inside the per-tenant loop) and is empirically live —
Hydra PRD applied `2.2.11` at rank 17, after `2.2.16`. But note it is **not** engaged when one image
carries both versions: they simply apply in ascending order in one run.

Version picking: `check-migration-version-collision.sh` lives at **`src/main/resources/db/`**, not in
`sbdocs/9-System/scripts/`. Run it before naming a file **and again right before merge** — SBDEV-3154's
own ticket asserted `V2.2.22` was free and it had been taken in the interim.
Related: [[flyway-version-pick-sweep-all-remote-branches]], [[a-flyway-sweep-cant-catch-a-branch-pushed-later]].
