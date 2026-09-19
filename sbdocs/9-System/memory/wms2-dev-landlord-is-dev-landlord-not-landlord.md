---
name: wms2-dev-landlord-is-dev-landlord-not-landlord
description: v2 dev has TWO landlord DBs on dev.sbo.li:25060 — `landlord` is for LOCAL testing, `dev_landlord` is what WineCo's deployed dev app uses
metadata:
  type: reference
---

On `dev.sbo.li:25060` there are two landlord databases and they are **both legitimate**, serving
different purposes (confirmed by Nam 2026-08-21):

- **`landlord`** — for **local testing**. This is what `v2/wms2-api/src/main/resources/application.properties`
  ships pointing at (`landlord.datasource.jdbc-url`), which is correct for running the app on your machine.
- **`dev_landlord`** — what **WineCo's deployed dev app** actually uses. 4 tenants, only `wsl-wineco` active
  (realm `wineco`, client `om1`, `https://kc2.dev.sbo.li`) → `tenant_db_configuration` routes
  `wineco`/`wsl` to `jdbc:postgresql://dev.sbo.li:25060/dev_wh01_om1`, user `wh01_om1`.

**So to reproduce the deployed dev environment locally, override the landlord URL to `dev_landlord`:**
`-Dlandlord.datasource.jdbc-url=jdbc:postgresql://dev.sbo.li:25060/dev_landlord`. Leaving the default
gives you the local-testing landlord, whose tenant list is a different (also valid) set — so a query that
"works" against the wrong one answers about the wrong environment rather than erroring.

⚠️ Earlier note in this memory said `landlord` was a STALE copy sitting beside the real one. That framing
was wrong — it is not stale, it is the local-testing landlord. The operational advice is unchanged though:
confirm which one you are on (`SELECT current_database()`) before trusting a tenant list, because both
answer plausibly.

⚠️ Booting the API locally runs `StartupFlywayMigrator` against the landlord **and every active tenant DB**
(`app.flyway.migrate-on-startup=true` by default, [[sbdev-2801-runtime-flyway-default-on]]). Pass
`-Dapp.flyway.migrate-on-startup=false` for a read-only local run, or you will apply pending migrations to
shared dev databases from your machine. Related: [[wineco-dev-db-is-dev-wh01-om1-not-the-migration-env-target]].
