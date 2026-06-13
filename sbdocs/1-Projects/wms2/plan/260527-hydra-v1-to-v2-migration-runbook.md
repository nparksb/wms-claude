---
title: "Hydra v1 → v2 UTC Migration — Run Record (wh01, NY)"
type: plan
status: in-progress
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-05-27
updated: 2026-06-11
db_verified: true
related:
  - ../../../2-Areas/wms-utc-timezone-migration/README.md
  - ./260523-UTC-TIMEZONE-MIGRATION.md
  - ../../../3-Resources/reports/260526-utc-migration-code-changes-reference.md
  - ../../../3-Resources/reports/260527-wms-v1-v2-db-migration-script-comparison.md
tags: [plan, wms2, utc, migration, run-record]
---

# Hydra v1 → v2 UTC Migration — Run Record (wh01, NY)

> **This is a per-client run record, not the procedure.** The canonical, client-agnostic procedure —
> phases, gates, scripts, rollback matrix, and validated facts — lives in the SOP:
> [**2-Areas/wms-utc-timezone-migration/README.md**](../../../2-Areas/wms-utc-timezone-migration/README.md).
> This document holds **Hydra's** specifics and the results of each execution against that SOP.

**Client:** Hydra · **This run targets:** `wh01_hydra_v2` (source write-TZ `America/New_York`).
**Scope note:** Hydra has two warehouse databases with *different* source write-TZs — `wh01_hydra` (NY)
and `wh02_hydra` (LA). Each is its own DB with one uniform write-TZ; **`wh02` is a separate later run**
with `CLIENT_HIBERNATE_TZ=America/Los_Angeles` (which selects the `db/migration` LA originals). No single
DB holds both NY- and LA-written data.

---

## 1. Client facts

1. **Source write-TZ = `America/New_York`** — Hydra's `wh01_hydra` v1 instance wrote all timestamps as NY
   wall-clock (deployed `hibernate.jdbc.time_zone`, **not** the warehouse location). This selects the
   committed `_America_New_York` SQL variant. The wrong TZ would silently shift every timestamp 3 h with
   no error → PREP-1 is the hard gate (see §3).
2. **Re-id'd V2.1.08/09 no-op cleanly on a real v1 DB** — confirmed live (§3): ids 140–143 were free, so
   the bridge inserts the stale-club/pick-path syskeys with no PK collision; no v1-compat branch needed.

---

## 2. `migration.env` snapshot (non-secret)

```
CLIENT_NAME            = hydra
CLIENT_HIBERNATE_TZ    = America/New_York        # source write-TZ → selects NY variant
TENANT_DISCOVERY_TZ    = America/New_York         # frontend display TZ (landlord)
TENANT_NAME            = hydra
CLIENT_FACILITY_CODE   = nywh
TENANT_DISCOVERY_KEY   = nywh-hydra
OMS_BASE_HOST          = api-oms-dev.siteboss.net  # (dev/rehearsal target)
TENANT_DB              = wh03_om1@localhost:25062/wh01_hydra_v2   # via `dbuaton` SSH tunnel → uat.sbo.li:25060
LANDLORD_DB            = wms_landlord@localhost:25060/dev_landlord
V1_DEPLOYED_PROPERTIES = …/application-hydra_wh1.properties        # NY; backs the PREP-1 gate
WORK_DIR               = /home/nampark/data/migration/tmp/hydra-utc-migration
BACKUP_DIR             = /home/nampark/data/migration/hydra/backups
```
> Corrections applied during setup: `TENANT_DB_PORT` `26062 → 25062` (match the `dbuaton` tunnel);
> `V1_DEPLOYED_PROPERTIES` filename typo fixed. pg client upgraded to 16.14 (≥ server 16.10) for
> `pg_dump`/`pg_restore` compatibility.

---

## 3. Pre-flight findings (`01-preflight.sh`, 2026-06-05)

| Check | Result |
|---|---|
| **PREP-1** deployed v1 TZ == `CLIENT_HIBERNATE_TZ` (HARD GATE) | ✅ `America/New_York` both; data cross-check confirms NY wall-clock (06:40 NY → 11:40 UTC) |
| **PREP-2** `System Time Zone` sysprop | ✅ `America/New_York` |
| **PREP-3** syskey ids 140–143 | ✅ **0 rows (free)** → V2.1.08/09 insert cleanly, no collision |
| **PREP-4** stuck transfer orders | ✅ 0 |
| **PREP-6** disk ≥ DB size (HARD GATE) | ✅ pass — ⚠️ measured the *local* box over the tunnel, not `uat.sbo.li` (see §5) |
| **PREP-10** `flyway_schema_history` | absent → manual application (benign) |
| Landlord reachability | ✅ |
| **Baseline row-counts** (Phase F compares) | stockrecord 93,508 · unitload_record 83,621 · inventory_record 2,886,203 · pickingorder_position 16,242 (DB ~767 MB) |

---

## 4. Execution results

### 4.1 Phases A–C — 2026-06-05 (dev, `wh01_hydra_v2`)
| Step | Result |
|---|---|
| A `02-backup` | ✅ `hydra_pre_utc_20260605_rehearsal.dump` (148 MB), `pg_restore --list` verified |
| A `03-gen-scripts` | ✅ NY variants selected; OMS host → `api-oms-dev.siteboss.net` in V2.1.02/13 |
| C `04-schema-bridge` | ✅ Step A (0 stuck) + V2.1.01→V2.1.14 applied in order (9.4 s) — bridge watermark has since extended to **V2.1.15** (`API_TIMESTAMP_FORMAT` seed, added after this rehearsal); a fresh run lands V2.1.01→V2.1.15 |
| C `05-verify-bridge` | ✅ **ALL PASS** (3 tables, 6 syskeys, cancellation fn, V2.1.14 index, reversal URL = client host) |

### 4.2 Phase F (UTC conversion) — **dev rehearsal**, 2026-06-05
Ran `06-drain` (outbox already 0) → `07-utc-migrate` → `08-verify-utc`. **`08-verify-utc`: ALL PASS** — all
large-table cols `timestamptz`, all 11 views recreated, fn signatures `timestamptz`, outbox index, **row
counts == baseline**, ANALYZE done.

**NY conversion math validated on real data** (the previously-unexercised piece):
```
advice 2864620:  06:40:27 (naive NY, before) → 11:40:27+00 UTC (after, +5h EST)
                 reads back AT TIME ZONE 'America/New_York' → 06:40:27   ← original wall-clock preserved
```

**B3 RTO data point** (dev volume — **lower bound, not a production budget**):
| Step | Duration |
|---|---|
| V1.2.01 standard tables (~92 ALTER, drop 11 views) | ~12 s |
| **V1.2.02 large tables** | **~11 s** (incl. inventory_record 2.88 M rows) |
| V1.2.03 / V1.2.04 / V1.2.05 | ~1 / ~3 / ~1 s |
| **Forward total** | **~28 s** |

> Post-rehearsal decision: **left `wh01_hydra_v2` in the converted (UTC) state.** Anything reading it now
> requires the Phase-2 UTC app config. Rewind point: `00-restore.sh 20260605_rehearsal`.

### 4.3 Second rehearsal — dev2 (`wms2-hydra-dev2`), 2026-06-09
Full A→C→F re-run against a **different target DB** — a fresh v1 reload (`wh01_hydra.dump`, 2026-06-08) on
the dev2 box (DB `wh01_hydra_v2`, app role `wh03_om1`; the toolkit's `localhost:25060` and the
`wms2-hydra-dev2` MCP fingerprint to the **same** clean DB). `wh03_om1` already **owns** all 50 tables /
11 views / 1 seq / 3 fns (db owner = `wh03_om1`, `CREATE`+`USAGE` on `public` = true) → **no ownership
pre-fix** (contrast WineCo §3.5). This run lands the **complete V2.1.01→V2.1.15 bridge** (the 2026-06-05
run predated V2.1.15).

| Step | Result |
|---|---|
| A `01-preflight` | ✅ all hard gates — PREP-1 NY (deployed `application-hydra_wh1.properties` == config + data cross-check), PREP-2 NY, PREP-3 ids 140–143 free, PREP-4 0 stuck, PREP-6 759 MB vs ~356 GB free, landlord reachable, flyway absent |
| A `02-backup` | ✅ `RUNTIME_BACKUP=false`; `EXTERNAL_BACKUP_DUMP=wh01_hydra.dump` (153 MB) `pg_restore --list` verified → rewind = `./00-restore.sh` (no stamp) |
| A `03-gen-scripts` | ✅ NY variants (V1.2.01/02/99 `_America_New_York`); OMS host → `api-oms-dev.siteboss.net` at free ids 144/145 |
| C `04`/`05` | ✅ V2.1.01→**V2.1.15** in ~4 s; `05-verify-bridge` **ALL 9 PASS** (incl. V2.1.15 `API_TIMESTAMP_FORMAT` seed) |
| F `06`/`07`/`08` | ✅ drain 0 (`rest_idempotency_predrain` snapshot); forward ~30 s; `08-verify-utc` **ALL PASS** incl. **`order_detail_monitor_view.sku_id` present** (the §4.5 defect fix holds on this DB), row counts == baseline |

**RTO (dev2, 759 MB — dev lower bound, not a production budget):** V1.2.01 ~11 s · **V1.2.02 ~17 s**
(stockrecord 99,570 + unitload_record 87,958 + inventory_record 2,986,729 + pickingorder_position 17,065)
· V1.2.03–05 ~2 s · **forward total ~30 s**.

**NY math re-confirmed:** advice 3262828 `12:46:10` naive-NY → `16:46:10+00` UTC (+4h EDT) → reads back
`AT TIME ZONE 'America/New_York'` = `12:46:10`. Left in converted (UTC) state; rewind `./00-restore.sh`.

---

### 4.4 Phase A — **empty-baseline run** (new production DB), 2026-06-11

Target: `wh01_hydra_v2` @ `localhost:25061` (the **new production baseline** — intentionally empty, created
from the v1 Flyway baseline V1.0.01–V1.1.05; the `wms2-hydra-v2` MCP fingerprints to the same DB). Differs
from §4.1/§4.3: no v1 data — this run produces an empty, wms2-ready (bridge + UTC) baseline database.

Pre-conditions fixed before this run (2026-06-11): ownership transferred `wh01_om1_hmg` → `wh03_om1`
(51 tables / 11 views / 1 seq / 3 fns + DB owner; `public` → `pg_database_owner`; scoped DO-block, WineCo
§3.5 pattern); `System Time Zone` sysprop corrected from the malformed seed `America / New_York (-05:00)`
to `America/New_York`; full `GRANT` + default-ACL set for `wh03_om1` (now moot via ownership, kept).

| Step | Result |
|---|---|
| A `01-preflight` | ✅ ALL PASS — PREP-1 deployed==config `America/New_York` (data cross-check 0 rows — empty DB), PREP-2 NY, PREP-3 ids 140–150 free, PREP-4 0, PREP-6 12.9 MB vs 382 GB, landlord OK; baseline row-counts **all 0** (correct); PREP-10 flyway history **present** (10 rows, v1-Flyway-created — Phase K `TRUNCATE`) |
| A `02-backup` | ✅ `RUNTIME_BACKUP=true` (rehearsal's `EXTERNAL_BACKUP_DUMP=wh01_hydra.dump` deliberately **unset** — it is the v1 *data* dump, wrong rewind point for the empty baseline); `hydra_pre_utc_20260611_baseline.dump` (232 K), `pg_restore --list` verified; stamp `20260611_baseline` |
| A `03-gen-scripts` | ✅ NY variants (V1.2.01/02/99 `_America_New_York` — incl. the 2026-06-11 SBDEV-2384 flag-based V1.2.99); OMS host initially `api-oms-dev` (rehearsal carry-over, caught at Gate A→B) → corrected to **`api-oms-uat.siteboss.net`** and CLIENT copies regenerated before Phase C |
| C `04-schema-bridge` | ✅ Step A (0 stuck) + **V2.1.01→V2.1.16** applied in order (~2 s) — **first run of the complete V2.1.16-extended bridge** (incl. the SBDEV-2384 flag-based view) |
| C `05-verify-bridge` | ✅ **ALL 10 PASS** — 3 tables, 6 syskeys, `API_TIMESTAMP_FORMAT` seeded (V2.1.15), cancellation fn + timestamptz cols, 0 stuck, valid V2.1.14 index, `transaction_detail` amount!=0, **`replenishment_monitor_view` flag-based (V2.1.16)**, reversal URL = `api-oms-uat.siteboss.net` |
| F `06-drain` | ✅ outbox 0 immediately (freshly created); empty `rest_idempotency` → `rest_idempotency_predrain` snapshot |
| F `07-utc-migrate` | ✅ V1.2.01→05 clean in ~10 s (empty tables); fn re-signatures OK |
| F `08-verify-utc` | ✅ **ALL PASS** — large tables timestamptz, fn signatures timestamptz, 11 views recreated, `sku_id`/`order_loaded_to_truck`/`on_replenishable_location` columns present, **flag-based viewdef check (V2.1.16) — first live exercise**, outbox index, row counts == all-zero baseline, ANALYZE done; spot-checks 0 rows (empty DB, expected) |

**End state (2026-06-11):** `wh01_hydra_v2` @ `:25061` is a complete **empty wms2-ready UTC baseline** —
v1 baseline schema + V2.1.01–V2.1.16 bridge + V1.2.01–05 UTC conversion, owned by `wh03_om1`. Rewind:
`./00-restore.sh 20260611_baseline` (232 K). Not yet run: `09-smoke` (Phase H — needs the app connected
so the per-tenant `connectionInitSql` session-TZ is exercised). `flyway_schema_history` retains the 10
v1-baseline rows (accurate history; wms2 never auto-runs Flyway — `TRUNCATE` at Phase K if desired).

**⚠️ Gate A→B items:** (1) `OMS_BASE_HOST` is still the **dev** OMS (`api-oms-dev.siteboss.net`, carried
over from the rehearsal env) — if this baseline serves production, re-point `migration.env` and re-run
`03-gen-scripts.sh` before Phase C, else OMS callbacks go to dev. (2) Human PREP-9..14 sign-offs (landlord
`tenant_discovery.timezone`, PgBouncer, OMS ISO-8601, RTO rehearsal, go/no-go owner).

---

## 5. Open items for Hydra

- **Bridge watermark extended to V2.1.16 after both rehearsals** (2026-06-11, SBDEV-2384 port, wms2-api
  `143fa65`): `replenishment_monitor_view` replenishable bucket is now flag-based (`useforreplenish=TRUE`)
  — on Hydra data the old name list over-counted 18,607 vs flag-true 9,221 (9,386 bottles on pick-only
  `Storage and Picking`), and Hydra's comma-less `Storage Picking and Replenish (from)` never matched the
  list. **dev2 was patched standalone 2026-06-11** (V2.1.16 applied, viewdef verified flag-based); the
  production run lands it automatically via `04-schema-bridge.sh` + fixed `V1.2.04`.
- **Production Phase F** — the rehearsal ran against the dev copy. Re-measure forward `V1.2.02` RTO on a
  **production-sized** restore (closes **B3** for real); window budget = `total − forward_time`.
- **PREP-6 on the DB host** — the pre-flight disk check measured the local box over the tunnel. Re-verify
  free disk **on `uat`/prod** (≥ ~2× the large tables) before a production F. (SOP §7 tunnel caveat.)
- **B5** — take the authoritative backup **after** drain + scale-to-0 for a clean soft-rollback delta.
- **Phase-J reader** — the backend `API_TIMESTAMP_FORMAT`→`ISO8601_UTC` serialization switch is still
  unbuilt; build before Phase J (post-cutover, not a window blocker).
- **Human phases D / G / H / I / J / K** — Deploy-1/2/3, scale-to-0/up, maintenance toggle, go/no-go,
  flag flip, cleanup (incl. dropping the `rest_idempotency_predrain` snapshot left by the drain step).
- **`wh02_hydra` (LA)** — separate run with the LA originals.

---

## 6. Artifacts
- Backup: `/home/nampark/data/migration/hydra/backups/hydra_pre_utc_20260605_rehearsal.dump`
- Logs/reports: `/home/nampark/data/migration/tmp/hydra-utc-migration/` (`migration.log`, `preflight-report.txt`, `baseline_rowcounts.csv`, `post_rowcounts.csv`)
- Toolkit + SQL (source of truth): `v2/wms2-api/src/main/resources/db/onboarding-tz-variants/scripts/` + `db/migration/` + `db/rollback/`
