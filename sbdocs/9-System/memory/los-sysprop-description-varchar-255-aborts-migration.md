---
name: los-sysprop-description-varchar-255-aborts-migration
description: "los_sysprop.description is varchar(255) — an over-long seed description does NOT truncate, it aborts the entire Flyway migration and leaves the tenant's chain failed"
metadata: 
  node_type: memory
  type: project
  originSessionId: b888d88f-6fe1-4dc3-9d9f-730e9b89fd91
  modified: 2026-08-04T12:44:14.263Z
---

`los_sysprop.description` is `character varying(255)` (`V2.2.00__base_v2_schema.sql:1376`, confirmed
live on `wsl-wineco-uat`). So are `syskey`, `workstation` and `groupname`. Only `sysvalue` and
`additionalcontent` are `text`.

**Why:** every `V2.2.x` sysprop seed writes a long human-readable `description` for the config UI, and
these descriptions have been growing (V2.2.04 ≈ 186 chars, V2.2.05 ≈ 205, V2.2.06 ≈ 208). SBDEV-2778's
first cut shipped **268** and was caught only by an independent PR reviewer. Postgres does **not**
truncate an over-long varchar — it raises `22001` — and Flyway wraps each migration in a transaction,
so one over-long description aborts the **whole file**: every row in it goes unseeded *and* the tenant
is left with a failed migration that blocks every later `V2.2.x`. The failure mode is a blocked
operator upgrade, not a silently shortened string.

**How to apply:** when writing any `los_sysprop` seed, measure the description (remember `''` counts
as one char) and keep it under 255 — put the long rationale in SQL comments, which cost nothing.
`SyspropMigrationDescriptionWidthTest` (added by SBDEV-2778, `unit/db/`) now guards this: it parses
`db/migration/*.sql` as text, aligns each `INSERT ... (cols) SELECT` positionally and checks every
varchar column. It excludes `V2.2.00__base_v2_schema.sql` because that file's rows are a `pg_dump` of
an already-`varchar(255)` column and use the column-less `INSERT ... VALUES` form.

**No other lane can catch this.** Every test that runs migrations against a real Postgres is in the
`@Disabled` Testcontainers lane ([[wms2-it-harness-broken-sbdev-2217]]), the app doesn't run Flyway at
runtime, and verify-script migration checks are name-only greps. Assume an unmeasured description
reaches the operator unchallenged.

See [[negative-test-verify-scripts-before-trusting-them]],
[[flyway-runbook-covers-dev-and-uat-via-env-flag]],
[[wms2-sysprop-live-keys-exceed-code-constants]].
