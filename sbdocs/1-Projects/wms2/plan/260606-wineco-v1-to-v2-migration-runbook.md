---
title: "WineCo v1 → v2 UTC Migration — Run Record (wh01_om1, LA)"
type: plan
status: in-progress
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-06
updated: 2026-06-11
db_verified: true
related:
  - ../../../2-Areas/wms-utc-timezone-migration/README.md
  - ./260523-UTC-TIMEZONE-MIGRATION.md
  - ./260527-hydra-v1-to-v2-migration-runbook.md
  - ../../../3-Resources/reports/260526-utc-migration-code-changes-reference.md
  - ../../../3-Resources/reports/260527-wms-v1-v2-db-migration-script-comparison.md
tags: [plan, wms2, utc, migration, run-record]
---

# WineCo v1 → v2 UTC Migration — Run Record (wh01_om1, LA)

> **This is a per-client run record, not the procedure.** The canonical, client-agnostic procedure —
> phases, gates, scripts, rollback matrix, and validated facts — lives in the SOP:
> [**2-Areas/wms-utc-timezone-migration/README.md**](../../../2-Areas/wms-utc-timezone-migration/README.md).
> This document holds **WineCo's** specifics and the results of each execution against that SOP.

**Client:** WineCo · **This run targets:** `wh01_om1_v2` (warehouse `wsl`, source write-TZ `America/Los_Angeles`).
**Scope note:** A single warehouse DB with one uniform LA source write-TZ — so `CLIENT_HIBERNATE_TZ=America/Los_Angeles`
selects the **`db/migration` LA originals** (no `_America_New_York` variant). Unlike Hydra, WineCo's only
real obstacle was **table ownership**, not the conversion math (see §3.5).

---

## 1. Client facts

1. **Source write-TZ = `America/Los_Angeles`** — WineCo's v1 instance wrote all timestamps as LA wall-clock
   (deployed `hibernate.jdbc.time_zone`, **not** the warehouse location). This selects the `db/migration` +
   `db/rollback` originals. PREP-1 is the hard gate; data cross-check confirmed LA (13:52 LA → 20:52 UTC).
2. **Syskey ids 140–143 free** — confirmed at pre-flight; the bridge's re-id'd V2.1.08/09 insert cleanly.

---

## 2. `migration.env` snapshot (non-secret)

```
CLIENT_NAME            = wineco
CLIENT_HIBERNATE_TZ    = America/Los_Angeles       # source write-TZ → selects LA originals (db/migration)
TENANT_DISCOVERY_TZ    = America/Los_Angeles         # frontend display TZ (landlord)
TENANT_NAME            = wineco
CLIENT_FACILITY_CODE   = wsl
TENANT_DISCOVERY_KEY   = wsl-wineco
OMS_BASE_HOST          = api-oms-dev.siteboss.net    # (dev/rehearsal target)
TENANT_DB              = wh01_om1@localhost:25062/wh01_om1_v2
LANDLORD_DB            = wms_landlord@localhost:25060/dev_landlord
V1_DEPLOYED_PROPERTIES = …/application-wineco.properties             # LA; backs the PREP-1 gate
WORK_DIR               = /home/nampark/data/migration/tmp/wineco-utc-migration
BACKUP_DIR             = /home/nampark/data/migration/wineco/backups
```
> `migration.env` is identical to the committed `migration.env.wineco`. All ad-hoc data validation went
> through the `wms2-wineco-uat` MCP (connects as `wh01_om1` to this same DB).

---

## 3. Pre-flight findings (`01-preflight.sh`, 2026-06-05)

| Check | Result |
|---|---|
| **PREP-1** deployed v1 TZ == `CLIENT_HIBERNATE_TZ` (HARD GATE) | ✅ `America/Los_Angeles` both; data cross-check confirms LA wall-clock |
| **PREP-2** `System Time Zone` sysprop | ✅ `America/Los_Angeles` |
| **PREP-3** syskey ids 140–143 | ✅ **0 rows (free)** → V2.1.08/09 insert cleanly, no collision |
| **PREP-4** stuck transfer orders | ✅ 0 |
| **PREP-6** disk ≥ DB size (HARD GATE) | ✅ ~9.9 GB DB vs 385 GB free |
| **Baseline row-counts** (Phase F compares) | stockrecord 6,966,086 · unitload_record 5,637,625 · inventory_record 12,425,015 · pickingorder_position 879,803 (DB ≈ 9.5 GB) |

---

## 3.5 The blocker — table ownership (WineCo-specific)

Phase C **stalled on 2026-06-05**: `04-schema-bridge.sh` aborted on `V2.1.01` with
`ERROR: must be owner of table unitload`. Failed atomically (`ON_ERROR_STOP`) — **DB left clean V1, nothing applied**.

**Root cause:** all 53 `public` tables/seqs/views/functions were owned by `postgres`. The app role `wh01_om1`
has only DML, is not superuser, has `rolinherit=false`, cannot assume `postgres`, and lacked `CREATE` on schema
`public`. Contrast Hydra, whose app role `wh03_om1` already **owns** its objects — which is why Hydra's bridge
ran without this step. On this cluster `postgres` is the **only** privileged login role.

**Fix (2026-06-06, run as `postgres` — the only role that can):** a **scoped** `DO`-block of
`ALTER … OWNER TO wh01_om1` over `public` tables/sequences/views/functions/domains + `ALTER DATABASE wh01_om1_v2
OWNER TO wh01_om1`. Deliberately **NOT** `REASSIGN OWNED BY postgres` — that also reassigns shared/cluster
objects (other databases) owned by `postgres`.

**Post-fix parity (verified):** 53 tables, 11 views, 1 sequence, 168 indexes, 3 functions all owned by
`wh01_om1`; DB owner = `wh01_om1`; `CREATE` + `USAGE` on `public` = **true** (db-owner ⇒ implicit
`pg_database_owner`). `rolinherit` is still `false` but now irrelevant — the role owns the objects directly.
Schema `public` left owned by `pg_database_owner` (deliberate, the modern PG default). No standalone
domains/enums existed (the 64 `pg_type` rows were all table rowtypes, moved with their tables).

---

## 4. Execution results

### 4.1 Phases A–C — backup/gen 2026-06-05; bridge 2026-06-06 (real, `wh01_om1_v2`)
| Step | Result |
|---|---|
| A `02-backup` | ✅ `wineco_pre_utc_20260605_2109.dump` (1.2 GB), `pg_restore --list` verified; stamp `20260605_2109` |
| A `03-gen-scripts` | ✅ LA originals selected; OMS host → `api-oms-dev.siteboss.net` in V2.1.02/13 |
| C `04-schema-bridge` | ✅ (after ownership fix) Step A (0 stuck) + V2.1.01→V2.1.14 applied in order (**~13 s**) — this run **predated `V2.1.15`** (`API_TIMESTAMP_FORMAT` seed) and shipped without it (SOP §4); the bridge now ends at V2.1.16, so this DB was **missing the `API_TIMESTAMP_FORMAT` sysprop** until V2.1.15 was applied — **[2026-06-11 audit: row now PRESENT, but sysvalue = `ISO8601_UTC`, not the LEGACY seed default — see §5]** |
| C `05-verify-bridge` | ✅ **ALL 8 PASS** (3 tables, 6 syskeys, cancellation fn, 3 timestamptz cols, 0 stuck, valid aggregate_order idx, transaction_detail amount!=0, reversal URL = client host) |

### 4.2 Phase E/F/H cutover — **real run**, 2026-06-06 (app confirmed quiesced)
| Step | Result |
|---|---|
| E `06-drain` | ✅ outbox 0 immediately; `rest_idempotency` → `rest_idempotency_predrain` snapshot, then cleared |
| F `07-utc-migrate` | ✅ V1.2.01–05 clean — see RTO below |
| F `08-verify-utc` | ✅ **ALL PASS** — large-table cols `timestamptz`, fn signatures `timestamptz`, all 11 views recreated, outbox dispatch index, **row counts == baseline**, ANALYZE done |
| H `09-smoke` | ⚠️ 1 line FAIL `SHOW timezone=UTC` — **expected artifact, not a defect** (see §4.4); other checks PASS |

**LA conversion math validated on real data:**
```
advice 31098677:  13:52:19.842 (naive LA, before) → 20:52:19.842+00 UTC (after, +7h PDT)
                  reads back AT TIME ZONE 'America/Los_Angeles' → 13:52:19.842   ← original wall-clock preserved
```

### 4.3 RTO — forward `07` (the real production-scale data point; feeds SOP **B3**)
| Step | Duration |
|---|---|
| V1.2.01 standard tables (~92 ALTER, drop 11 views) | **2 m 27 s** |
| **V1.2.02 large tables** | **2 m 41 s** (stockrecord 6.97 M + unitload_record 5.64 M + inventory_record 12.43 M + pickingorder_position 0.88 M ≈ 25.9 M rows) |
| V1.2.03 / V1.2.04 / V1.2.05 | ~1 / ~3 / ~1 s |
| **Forward total (`07`)** | **≈ 5 m 13 s** |

> 9.5 GB DB / ~25.9 M large-table rows in ~5 m13 s ⇒ ≈ **0.3–0.4 s per 100 k large-table rows**. This is the
> first large *real* (non-dev-rehearsal) RTO point — recorded in SOP §7 B3 for window sizing.

### 4.4 The 09-smoke `SHOW timezone` artifact
`09-smoke` ran over a **raw psql** connection, which never executes the app's HikariCP `connectionInitSql` /
`resolveWarehouseTz()` — so the session reports the server default `UTC` rather than `America/Los_Angeles`.
Proven harmless: **Hydra (already live) shows the identical raw-connection state** — sysprop = its TZ but
`SHOW timezone = UTC`, with only `search_path` in `pg_db_role_setting` (no `ALTER DATABASE/ROLE SET timezone`).
WineCo's `System Time Zone` sysprop is correctly `America/Los_Angeles`. **Real validation = re-check
`SHOW timezone` through the wms2 app once it reconnects.**

---

### 4.5 Post-migration defect — `order_detail_monitor_view` lost `sku_id` (found 2026-06-08)

**Symptom:** running `feature/utc-timezone` against the migrated DB threw
`PSQLException: column odmv1_0.sku_id does not exist` from the **Parcel Picking Report**
(`ViewDtoService.getParcelPickingReportViewByKeyword` → `OrderDetailMonitorView` entity).

**Root cause — NOT a missed script.** The migration ran correctly (tables are `timestamptz`, all 11
views recreated). The bug was a **stale view body inside `V1.2.04__utc_recreate_views.sql`**: its
`order_detail_monitor_view` recreate was snapshotted from a pre-`V1.1.05` version and omitted the
`sku_id` column (added by develop `V1.1.05` / SBDEV-1637, and required by the entity). `V1.2.04`
`DROP`+recreated the view without `sku_id`, so the report broke at **runtime**, not at recreate time.
The other 10 views were verified correct — `order_monitor_view` carries the V2.1.03 dashboard columns
~~and `replenishment_monitor_view` the V1.26.29 flag-based logic~~ **[claim refuted 2026-06-11 — see §4.6:
`replenishment_monitor_view` was recreated by V1.2.04 with the OLD area-name list, not the V1.26.29
flag-based predicate]**.

**Scope:** every UTC-migrated DB (defect is in the shared script, not per-DB). Confirmed missing on
wineco `wh01_om1_v2` (dev2 @10.0.0.16 + uat @10.0.0.6) **and Hydra**.

**Fix (2026-06-08):**
- Patched 3 scripts to restore `sku_id` (+`JOIN itemdata i`), matching develop `V1.1.05` verbatim
  (no TZ change — view has no timestamp output columns):
  `V1.2.04__utc_recreate_views.sql`, `db/rollback/V1.2.99__rollback_utc_migration.sql`,
  `db/onboarding-tz-variants/V1.2.99__rollback_utc_migration_America_New_York.sql`.
- Hotfixed all 3 live DBs via `CREATE OR REPLACE VIEW` (adds trailing column, no DROP); verified
  `sku_id` present and the report query returns values.
- Hardened `08-verify-utc.sh` with a column-level assertion (`VIEWCOLS`) so present-but-stale view
  bodies fail the gate (the old "11 views exist" count could not catch this).

### 4.6 Post-migration defect #2 — `replenishment_monitor_view` reverted to the name-list bucket (found 2026-06-11)

**Same failure mode as §4.5, second instance:** `V1.2.04`'s `replenishment_monitor_view` body was
snapshotted **before** v1's `V1.26.29` (SBDEV-2384) flag-based fix, so Phase F recreated the view with the
old hardcoded `on_replenishable_location` area-name list (which wrongly includes the pick-only
`'Storage and Picking'`). The §4.5 verification statement that this view carried "the V1.26.29 flag-based
logic" was **wrong** — refuted live 2026-06-11 (`pg_get_viewdef` still contained the name list on
`wh01_om1_v2` and `dev_wh01_om1`). v2's Java read path (`ReplenishmentMonitorViewRepository:92,96`) had the
same defect.

**Fix (2026-06-11, wms2-api `143fa65` on `feature/utc-timezone`):** both Java predicates →
`useforreplenish = true`; new **`V2.1.16`** (CREATE OR REPLACE of the view, flag-based; bridge watermark
now V2.1.01→V2.1.16); `V1.2.04` + both `V1.2.99` rollbacks swapped; `05-verify-bridge.sh` gained a viewdef
assertion (a `LIKE '%useforreplenish = true%'` check — the §4.5 `VIEWCOLS` column-shape gate could not catch a
predicate-only drift). Hotfixed live via `V2.1.16`: `wh01_om1_v2` (dev2 MCP, 4 monitor rows) and
`dev_wh01_om1` (12 rows), both verified flag-based. **The uat copy of `wh01_om1_v2` (@10.0.0.6) was not
reachable from this session — apply `V2.1.16` there too** (open item below).

---

## 5. Open items for WineCo

- **Apply `V2.1.16` to `wh01_om1_v2` on uat (@10.0.0.6)** — the dev2 (@10.0.0.16) copy and `dev_wh01_om1`
  were patched 2026-06-11 (§4.6); the uat instance still carries the name-list view.

- **App-path session-TZ check** — bring wms2 up against `wh01_om1_v2` and confirm `SHOW timezone =
  America/Los_Angeles` via the app connection (the only un-greened `09` line; §4.4).
- **Phase J reader/flag** — flip `API_TIMESTAMP_FORMAT` → `ISO8601_UTC` sysprop **only after** the wms2
  frontends that parse ISO-8601 ship (flipping early breaks the old frontend; `09` guards this).
  **[2026-06-11 audit: the row is present and ALREADY `ISO8601_UTC` on `wh01_om1_v2` (dev2 MCP) — seeded
  and flipped sometime after 2026-06-06, by whom/why not recorded here. If this DB serves an old-format
  frontend, that's the early-flip hazard the SOP warns about; if it's deliberately testing the Phase-4
  dual-format frontends, record that decision here.]**
- **Human phases D / G / H / I / J / K** — Deploy-1/2/3, scale-to-0/up, maintenance toggle, go/no-go, flag
  flip, cleanup (incl. dropping the `rest_idempotency_predrain` snapshot left by the drain step).
- **PREP-6 on the DB host** — pre-flight measured the local box; re-verify free disk on the actual DB host
  (≥ ~2× the large tables) before any production-targeted re-run.

---

## 6. Artifacts
- Backup: `/home/nampark/data/migration/wineco/backups/wineco_pre_utc_20260605_2109.dump`
- Logs/reports: `/home/nampark/data/migration/tmp/wineco-utc-migration/` (`migration.log`, `preflight-report.txt`, `baseline_rowcounts.csv`, `post_rowcounts.csv`)
- Pre-drain idempotency snapshot: table `rest_idempotency_predrain` (drop during Phase K cleanup)
- Rollback assets: `99-rollback.sh` (LA V1.2.99 variant) or `00-restore.sh` from the Phase-A dump
- Toolkit + SQL (source of truth): `v2/wms2-api/src/main/resources/db/onboarding-tz-variants/scripts/` + `db/migration/` + `db/rollback/`
