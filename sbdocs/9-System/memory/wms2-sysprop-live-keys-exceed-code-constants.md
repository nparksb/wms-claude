---
name: wms2-sysprop-live-keys-exceed-code-constants
description: "v2 los_sysprop holds 146 live keys vs 124 Java constants; most of the gap is UI-managed config read via findByGroupname, not debt. Plus 4 orphans, 2 plaintext secrets, and a VERSION-1.0-ONLY placeholder tenant."
metadata: 
  node_type: memory
  type: project
  originSessionId: 23a3cf05-8405-4cd0-9d02-3604e4b4ee5f
  modified: 2026-07-30T12:30:48.685Z
---

Census of all 5 active DEV+UAT tenants, 2026-07-30 →
`sbdocs/3-Resources/reports/260730-wms2-sysprop-current-value-census.md`.

**Don't treat "key in DB but not in `WmsConstants`" as debt.** The Admin → *Parameters & Configuration*
screen fetches `GET /sysprop/search/findByGroupname?groupname=…` (`wms2-web-ui store/admin/configuration.js`)
and renders whatever comes back, so ~20 keys are legitimately UI-managed with no Java constant
(`Warehouse Details`, `Operation Options`, `System Settings`, `System Info` groups).

Counts: **146 live keys vs 124 constants** (123 `SYSTEM_PROPERTY_*_KEY` + the nested
`LocationAreaService.PROPERTY_KEY_AREA_DEFAULT` — **a `SYSTEM_PROPERTY_` grep misses AREA_DEFAULT**).
Only 80 of the 124 have a `*_DEFAULT_VALUE` companion. 9 constants have no row on any tenant.

**LANDMINE — `V2.2.05` was AMENDED *and RENAMED* on 2026-07-30 after already being applied.**
It is now `V2.2.05__seed_outbox_sysprop_toggles.sql` (was `…__seed_outbox_reject_on_error_sysprop.sql`) and
seeds two rows, not one: `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` **and** `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` (the latter
is read at `OutboxDispatchService:317` but was never seeded, so the toggle existed nowhere an operator could
find it). Checksum went `2141461053` → `-382893208`. If you hit "checksum mismatch for migration version
2.2.05" **or** "description mismatch for migration version 2.2.05" (the rename produces the latter — Flyway
derives the description from the filename, and the content checksum was unchanged across it): **do not
`flyway repair`** for the content change — it realigns the checksum without re-executing, so the second INSERT
silently never runs. Instead `DELETE FROM flyway_schema_history WHERE version='2.2.05';` then migrate. Safe
only because every statement is `INSERT … WHERE NOT EXISTS`. Was OK to amend because only `dev_wh01_om1` had
it applied (UAT was still at `2.2.04`, i.e. pending, so no checksum was recorded there).

**Genuinely orphaned (4)** — zero Java refs, zero UI refs, **and `groupname IS NULL`** so `findByGroupname`
never surfaces them either: `QUICKSEARCH_FIELD_CONFIG_BOXTYPE`, `QUICKSEARCH_FIELD_CONFIG_CUSTOMERORDER`,
`STOCK_SUMMARY_EXPORT_SUPPRESS_ARCHIVED`, `UI_EMPTY_ON_LOAD`. Setting them does nothing.

**LANDMINE — `los_sysprop` is secret-bearing.** `WMS_LOGIN_SECRET` and `CUPS_SERVER_ADDRESS_PASSWORD` are
plaintext on all tenants and reachable via the Spring Data REST `/sysprop` resource. The CUPS one also ships a
hardcoded credential as its `*_DEFAULT_VALUE` at `WmsConstants.java:955` — it's in every clone's git history.
Redact both in any export or support bundle.

**LANDMINE — UAT `wh01_om1_v2` (wsl/WineCo) has 13 keys set to the literal string `VERSION-1.0-ONLY`**,
including all 8 Keycloak keys and `OLD_CRON_JOB_ACTIVATED` (which is parsed as a boolean elsewhere). Consistent
with the incomplete v1→v2 migration — see [[wineco-wsl-v1-v2-migration-status]], human steps G–K outstanding.
Don't expect that tenant to authenticate against v2 Keycloak as-is.

DEV carries 7 junk rows no UAT tenant has: `test`/`test2`/`test3`, `OPTION-ARDEN`, `PATTERN-ARDEN`, and
`cy_probe_*` rows created by `wms2-web-ui/cypress/e2e/wms/admin/admin.cy.js:243`
(`key: 'cy_probe_' + Date.now()`) — the gated admin write test adds one per run and doesn't clean up.

Fleet is clean otherwise: zero `CHANGE-ME-FOR-NEW-CLIENT`/`oms-XXXXX` placeholders, zero NULL-valued rows,
and no `workstation`/`client_id` row variants anywhere (all `DEFAULT`/`0`).

Related: [[wms2-outbox-dispatcher-status-blind-silent-loss]] (the `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED`
row is DEV-only and deliberately constant-less until Phase 2).
