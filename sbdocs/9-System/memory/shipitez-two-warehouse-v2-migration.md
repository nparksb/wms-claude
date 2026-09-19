---
name: shipitez-two-warehouse-v2-migration
description: "ShipItEZ v1→v2 UTC migration — two warehouses (NY=wh02, LA=wh01), readiness state and gotchas"
metadata: 
  node_type: memory
  type: project
  originSessionId: 59a49d44-d682-4314-8d9a-169d017b6ca6
---

ShipItEZ has **two warehouse DBs**, each its own v1→v2 UTC migration run (one source write-TZ each):
- **NY** — MCP `nywh-shipitez-uat`, facility `nywh`, DB `wh02_shipitez_v2`, `System Time Zone`=America/New_York, 201 MB.
- **LA** — MCP `c1wh-shipitez-uat`, facility `c1wh`, DB `wh01_shipitez_v2`, `System Time Zone`=America/Los_Angeles, 1,872 MB.

⚠️ **Numbering is inverted: NY=wh02, LA=wh01** — pin each track by name, never pair facility↔DB-number by intuition.

App roles (from onboarding doc + MCP): NY DB `wh02_shipitez_v2` = `wh05_om1`; LA DB `wh01_shipitez_v2` = `wh04_om1`. **Both DBs owned by `postgres`** (not the app role) → likely need a WineCo §3.5 ownership pre-fix before the bridge. C1WH = Santa Rosa, CA warehouse; NYWH = New York.

As of 2026-06-28 both DBs are **clean pre-bridge v1** (0 timestamptz / 91 wtz cols, 11 views, no bridge tables/syskey; syskey ids 140–143 free, 139=OMS_TENANT_ID). Readiness GREEN; **nothing executed**.

**PREP-1 CLOSED 2026-06-28**: deployed v1 props confirm `hibernate.jdbc.time_zone` = America/New_York (NY, `application-shipitez_wh2.properties`) and America/Los_Angeles (LA, `application-shipitez_wh1.properties`). (`user.timezone=LA` in both is JVM default, ignore.) Env files `migration.env.shipitez-ny`/`-la` (gitignored) now validated & correct.

**LA seqentities multi-island** (per [[wms2-seqentities-dual-island-id-space]]): `last_value`=5,381,225 but 874,846 stockrecord rows above it (to 119,945,117). **Likely inherited Hydra seed data** — onboarding doc loads LA UAT from `wh02_hydra`. Re-check on real prod DB; NOT a UTC blocker. NY is clean single island.

**Backups remote (DBA/host)** — env `EXTERNAL_BACKUP_DUMP` points at local `…/shipitez/backups/` paths that don't exist; `00-restore.sh` unavailable as configured. Before Phase F: scp host dump local, OR set RUNTIME_BACKUP=true (DBs small: 201MB/1.87GB), OR accept DBA-procedure recovery.

⚠️ **2026-09-09 — LA UAT WAS RELOADED FROM v1 PROD, discarding the 06-28 conversion; re-completed same day.**
A partial re-migration ran at 04:52 (not via the toolkit — no logs anywhere) leaving TWO gaps, both found
by read-only probe and both fixed 13:27–13:30Z:
1. **`V1.2.05` aborted on `stock_history2` AGAIN** — the reload restored the client-custom fn; its
   `specific_name` is `stock_history2_<oid>`, which MATCHES V1.2.05's own assertion pattern
   `LIKE 'stock_history%'` → raise → atomic rollback → **all 4** fns left naive. Will recur on EVERY
   reload. This time **converted** it to timestamptz rather than dropping (its `sr.modified > $1` with a
   naive param forces an implicit cast through the SESSION TimeZone — a real silent bug; dropping just
   re-arms the abort).
2. **`backfill-flyway-history.sh` run WITHOUT `--up-to`** → all 24 rows V2.2.00–23 stamped the IDENTICAL
   microsecond, recording 23 UNAPPLIED deltas as SUCCESS. With runtime Flyway default-ON
   ([[sbdev-2801-runtime-flyway-default-on]]) the app finds nothing pending and the tenant freezes at the
   bridge watermark **forever**. Applied all 23 for real, then corrected `installed_on`.
**Detection heuristic worth keeping: every `installed_on` sharing one microsecond ⇒ a backfill, not a run.**
Result: 27/27 verify PASS, `flyway validate` 24 valid / schema 2.2.23 / 0 pending, all 6 data tables +0 rows
(only seed tables grew: los_sysprop +17, mywms_function +2, mywms_role_mywms_function +29). Conversion math
re-verified: v1 id 121606688 `2026-09-08 11:49:01.982` naive-LA → `18:49:01.982+00` = +7h PDT.
Rewind now REAL: `EXTERNAL_BACKUP_DUMP` → `shipitez_c1wh_pre_completion_20260909_1320.dump` (315 MB).
**NY (`wh02_shipitez_v2`) was NOT reloaded — still fine from 06-28, and it served as the positive control
(4/4 V2.2.x markers present where LA had 0/4).** LA remaining = human G–K.

**LA (Track B) Phases A–F COMPLETE 2026-06-28 (UAT)** — DB fully UTC-converted + bridged to V2.1.16, row-counts==baseline, LA math verified (+7h PDT). Flipped RUNTIME_BACKUP=true; rewind `./00-restore.sh 20260628_1900` (256MB dump). Gotchas hit: 02-backup needs `backup_stamp` file (no Date.now under agent) + the `backups/` dir pre-created. **Phase F aborted on client-custom fn `stock_history2`** (see [[wms2-utc-v1205-hardcoded-function-list]]) — dropped it (0 deps, operator OK'd) + re-ran V1.2.05. Remaining = human Phases G/H/I/J/K.

**NY (Track A) Phases A–F COMPLETE 2026-06-28 (UAT)** — clean, no stock_history2 (only 3 std fns). +5h EST math verified, row-counts==baseline, API_TIMESTAMP_FORMAT=LEGACY. Ran with **isolated WORK_DIR `shipitez-nywh-utc-migration`** + fresh stamp `20260628_1917` (rewind `./00-restore.sh 20260628_1917`, 39MB dump) so shared CLIENT_NAME=shipitez state/dumps didn't clobber LA's `1900` dump. **Gotcha for same-client multi-warehouse: isolate WORK_DIR + use distinct backup stamp per track** (CLIENT_NAME is shared, so WORK_DIR/BACKUP_DIR collide). Both tracks now at human Phases G–K.

Runbook: `sbdocs/1-Projects/wms2/plan/260628-shipitez-v1-to-v2-migration-runbook.md`. Procedure SOP: `sbdocs/2-Areas/wms-utc-timezone-migration/README.md`. Mirrors [[wineco-wsl-v1-v2-migration-status]] (LA) and the Hydra NY runbook.
