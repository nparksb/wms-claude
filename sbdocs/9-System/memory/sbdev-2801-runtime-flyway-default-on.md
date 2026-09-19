---
name: sbdev-2801-runtime-flyway-default-on
description: "SBDEV-2801 merged 2026-08-04 — transaction report NULL-amount fix (V2.2.08) AND runtime Flyway on every boot, default-ON in every env"
metadata: 
  node_type: memory
  type: project
  originSessionId: 7aa9df7a-3ea4-4701-8e99-de5b79a3c5e8
  modified: 2026-08-04T12:34:27.478Z
---

wms2-api **PR #120 merged into `develop` 2026-08-04** (merge `27a1878`), ClickUp SBDEV-2801 → `on dev`.
Two unrelated changes rode together — remember the second one, it is the consequential half.

## 1. Transaction detailed report 500 (the actual ticket)

`/rest/report/getTransactionDetailedReport` returned an opaque `500 retryable:false` for any window
containing **one** row with a NULL source amount. `transaction_detail()` emitted NULL in
`received`/`returned` (**single-argument `coalesce` — a no-op**, unlike every sibling column) and in
`shipped`/`net_change` (raw nullable `bp.amount`). The `RECEIVING`/`RETURN` WHERE arms carry **no `type`
qualifier**, so rows whose writers only populate `amountstock` (`recordCounting` STOCK_COUNTED rows,
v1-era history) enter the report with NULL amounts; the controller then NPE'd on unguarded
`.longValue()`. Fixed at both layers: `V2.2.08` (CREATE OR REPLACE, six coalesces, same signature) plus a
null-safe `nz()` in the controller so a tenant DB still on the old function degrades to zeroed cells.
Same shape as [[sbdev-2777-stock-history-client-id-blind]] — the reporting SQL functions are a family of
near-identical bodies where one column diverges; when fixing one, diff the sibling columns.

## 2. ⚠️ Runtime Flyway is now DEFAULT-ON everywhere

`StartupFlywayMigrator` + `StartupFlywayMigrationRunner` run migrations in an `ApplicationRunner` on
**every startup, in every environment**: landlord first (`db/landlord-migration/`, ships empty, existing
schema baselined at version 0), then every active tenant DB from `tenant_db_configuration` (deduped per
database) against `db/migration/`. In-app rather than a shell entrypoint because tenant credentials live
in the landlord DB. This **deliberately supersedes** the UTC-migration-plan §0.5 "no runtime Flyway"
posture and removes the manual operator round — so it partly invalidates
[[flyway-runbook-covers-dev-and-uat-via-env-flag]].

Landmines:

- **Opt-out must precede the image.** `APP_FLYWAY_MIGRATE_ON_STARTUP=false` has to be set on a stack
  *before* this build reaches it (the OMS `SKIP_MIGRATIONS=true` analogue). DEV auto-deploys on push, so
  DEV got this the moment #120 merged, with no window.
- **Legacy psql-provisioned tenant DBs are SKIPPED, never auto-baselined** (a populated schema with no
  `flyway_schema_history` → ERROR log pointing at `db/backfill-flyway-history.sh`), because only the
  operator knows the true watermark and V2.2.03 is not replay-safe. Those DBs **keep drifting and do not
  get V2.2.08**. This hits the migrated DEV copies (wineco-dev, hydra-dev2) — expect per-boot ERROR
  lines there that are working-as-designed, not a regression.
- **`spring.flyway.enabled=false` is now explicit and must stay** — Boot's auto-config would otherwise
  run the *tenant* migrations against the primary (landlord) DataSource.
- **Failure posture is lenient**: one tenant's failure is logged, counted, skipped; the app still boots
  and that tenant runs on a stale schema. Tenant *enumeration* failure was a Codex P1 (it escaped both
  catch blocks and would have killed the boot) — fixed in `b132fb60a`.
- The app's DB roles now execute DDL. Fine under the v2t owner model; any tenant DB where the app role
  doesn't own the schema logs per-boot failures forever.

Boot log line to grep for: `Flyway startup migration finished: N database(s), …, 0 failure(s)`.

Still open after the merge: UAT hydra/NYWH has **not** been confirmed on V2.2.08, and UAT was behind on
migrations, so the backfill/watermark question applies there first.

V2.2.08 is now consumed on `develop`; SBDEV-2778 holds V2.2.09 — per
[[flyway-version-pick-sweep-all-remote-branches]], re-sweep all remote branches before picking the next.
