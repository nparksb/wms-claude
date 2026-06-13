# WMS v1 vs v2 — DB Migration Script Comparison Report

---
title: WMS v1 vs v2 DB Migration Script Comparison
created: 2026-05-27
status: reference
tags: [wms1, wms2, flyway, migration, database, schema]
---

> **Directories compared:**
> - v1: `v1/wms-api/src/main/resources/db/migration/` (13 scripts)
> - v2: `v2/wms2-api/src/main/resources/db/migration/` (13 scripts as of 2026-05-30; the v2-specific sequence is contiguous V2.1.01–V2.1.13, **all in the main migration folder**. SBDEV-1921's cancellation feature ships as V2.1.12 + V2.1.13. The former `v1-onboarding/` subdirectory and its two scripts were **deleted** in the Round-14 simplification — see §8.)
>
> **⚠️ Round 14 update (2026-05-30):** This report originally documented a sysprop **id collision** that made V2.1.08 fail on v1 DBs and required a v1-compat variant. That is **obsolete** — the v2 sysprop scripts were re-id'd to align with the v1 baseline (V2.1.08 → 140/141/142, V2.1.09 → 143, V2.1.02 → free 144/145), so the standard scripts no-op cleanly on v1. §4, §7, §8, §10 below are corrected accordingly; struck-through text is retained as history.
> **Verification:** All MD5 hashes confirmed by direct file comparison.

---

## 1. Executive Summary

v1 and v2 share a byte-for-byte identical database schema baseline (V1.0.01–V1.1.05, 10 scripts). They **diverged after V1.1.05** — v1 continued numbering its own migrations as V1.1.06 onwards, while v2's post-baseline migrations were renamed into the **V2.1.x namespace** (v1's V1.1.06–V1.1.09 equivalents are now v2's V2.1.01–V2.1.04). Because v2 no longer reuses v1's V1.1.x version numbers, there is **no longer any version-number overlap** between the two codebases past the baseline. v2 has evolved 9 additional scripts (V2.1.05–V2.1.13) that have no v1 counterpart.

**Critical finding for v1→v2 client migration `[updated 2026-05-30 — Round 14]`:** Earlier revisions of this report warned that V2.1.08 would **fail with a PRIMARY KEY violation** on v1 DBs. **That is no longer true.** V2.1.08 was re-id'd to seed `STALE_CLUB_BATCH_CLEANUP_*` at ids **140/141/142** — the exact ids/syskeys v1 already holds (v1 V1.1.07) — so on a v1 DB it cleanly **NO-OPS** via its composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. Likewise V2.1.09 seeds `PICK_PATH_DIRECTION` at id **143** (v1's existing id) and V2.1.02 seeds the new OMS sysprops at the **free** ids 144/145. A live simulation on `wms1-wineco-dev` (2026-05-30) confirmed the full V2.1.01–V2.1.13 sequence applies cleanly, in order. The §0.6 runbook is now a **single linear apply** — the v1-compat variant and the `v1-onboarding/` subdirectory have been deleted.

---

## 2. Shared Baseline — Byte-Identical (V1.0.01–V1.1.05)

All 10 scripts in this range are **MD5-identical** between v1 and v2.

| Script | Size | Content |
|--------|------|---------|
| `V1.0.01__wms_tables.sql` | 56,240 B | 177 `CREATE TABLE` operations — complete WMS schema |
| `V1.0.02__wms_views.sql` | 22,079 B | 12 `CREATE VIEW` operations |
| `V1.0.03__wms_functions.sql` | 25,300 B | 3 `CREATE FUNCTION`: `stock_history`, `transaction_detail`, `transaction_summary` |
| `V1.0.04__wms_init_data.sql` | 42,574 B | `INSERT` seed data: clients, users, `los_sysprop` rows up to id ≈ 139 |
| `V1.0.05__wms_indexes.sql` | 7,495 B | 87 `CREATE INDEX` |
| `V1.1.01__wms_views.sql` | 9,487 B | 6 `CREATE OR REPLACE VIEW` |
| `V1.1.02__wms_data.sql` | 63,200 B | `INSERT` location, unitload, boxtype seed data |
| `V1.1.03__wms_updates.sql` | 5,596 B | `UPDATE los_sysprop` + `ALTER TABLE advice` |
| `V1.1.04__wms_functions.sql` | 24,038 B | `DROP/CREATE` `transaction_detail` and `transaction_summary` (first overhaul) |
| `V1.1.05__wms_updates.sql` | 2,092 B | `CREATE OR REPLACE VIEW order_detail_monitor_view` |

**Implication:** Any v1 client DB that has successfully run through V1.1.05 has an identical schema foundation to wms2. This is the safe anchor point for migration.

---

## 3. Divergence Map — Post-Baseline (v1 V1.1.06+ / v2 V2.1.x)

After the shared baseline, the two codebases use **separate version namespaces**: v1 continued as V1.1.06 onwards, while v2's post-baseline migrations now live in the **V2.1.x namespace**. The table below pairs each v1 script against the v2 script that occupies the equivalent position. Never attempt to run a v1 script in place of its paired v2 counterpart (or vice versa) — they have different filenames and content.

| v1 version | v1 script | v1 purpose | v2 version | v2 script | v2 purpose |
|------------|-----------|-----------|------------|-----------|-----------|
| **V1.1.06** | `V1.1.06__transfer_order_state_fix.sql` | **Data fix:** reset stuck `customerorder.state` 510 → 505 where `transferlane_id IS NULL` (SBDEV hotfix 2026-05-04) | **V2.1.01** | `V2.1.01__add_unique_constraint_unitload_labelid.sql` | **Schema fix:** `ALTER TABLE unitload ADD CONSTRAINT uq_unitload_labelid UNIQUE (labelid)` — TOCTOU race protection |
| **V1.1.07** | `V1.1.07__wms_updates.sql` | `INSERT los_sysprop` ids **140, 141, 142** = `STALE_CLUB_BATCH_CLEANUP_ACTIVATED/TIMER_HOUR/TIMER_MINUTE` | **V2.1.02** | `V2.1.02__add_palletized_loaded_to_truck_sysprops.sql` | `INSERT los_sysprop` ids **144, 145** = `WEBSERVICE_ORDER_BATCH_PALLETIZED/LOADED_TO_TRUCK` OMS endpoint URLs (free on v1; composite `ON CONFLICT DO NOTHING`) |
| **V1.1.08** | `V1.1.08__wms_functions.sql` | `CREATE OR REPLACE FUNCTION transaction_detail` (second overhaul) | **V2.1.03** | `V2.1.03__update_dashboard_summary_view.sql` | `DROP/CREATE VIEW order_monitor_view` (significant rewrite with `PICK_PACK` filter + new state columns) |
| **V1.1.09** | `V1.1.09__pick_path_direction.sql` | `INSERT los_sysprop` id **143** = `PICK_PATH_DIRECTION` (ON CONFLICT DO NOTHING) | **V2.1.04** | `V2.1.04__replenishorder_performance_indexes.sql` | `CREATE INDEX` — 8 replenishment performance indexes (state, composite, partial unique) |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.05 | `V2.1.05__add_critical_missing_indexes.sql` | `CREATE INDEX IF NOT EXISTS` — state + FK indexes on `pickingorder`, `billoflading`, `advice`, `customerorder_batch`, `goodsreceiptposition`, etc. |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.06 | `V2.1.06__add_composite_indexes.sql` | `CREATE INDEX` composite indexes: `pickingorder (state, section_id)`, `stockunit (itemdata_id, entitylock)`, etc. |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.07 | `V2.1.07__update_transaction_detail_pick_amount_filter.sql` | `CREATE OR REPLACE FUNCTION transaction_detail` — adds `AND sr.amount != 0` filter for PICKING branch (bug fix for zero-amount rows polluting transaction reports) |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.08 | `V2.1.08__stale_club_batch_cleanup_sysprops.sql` | `INSERT los_sysprop` ids **140, 141, 142** = `STALE_CLUB_BATCH_CLEANUP_*` with `ON CONFLICT (client_id, syskey, workstation) DO NOTHING` — re-id'd to match v1's V1.1.07, so it NO-OPS on v1 DBs |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.09 | `V2.1.09__add_pick_path_direction_sysprop.sql` | `INSERT los_sysprop` id **143** = `PICK_PATH_DIRECTION` with `ON CONFLICT DO NOTHING` — matches v1's V1.1.09 id, so it NO-OPS on v1 DBs |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.10 | `V2.1.10__add_rest_idempotency.sql` | `CREATE TABLE rest_idempotency` (SBDEV-2222) |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.11 | `V2.1.11__add_outbox_message.sql` | `CREATE TABLE outbox_message` (SBDEV-2221 transactional outbox) |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.12 | `V2.1.12__add_cancellation_reversal_log_and_grant.sql` | First seeds `MOBILE_UI_VIEW_CANCELLATION` into `mywms_function`, then `CREATE TABLE customerorder_cancellation_log` + 2 indexes, with `reversal_initiated_by`/`reversal_completed_by` declared directly as `VARCHAR(255)` (Keycloak UUID operator IDs) baked into the DDL — no separate `ALTER` step; finally idempotently grants `MOBILE_UI_VIEW_CANCELLATION` to `outbound-manager`, `outbound-worker`, `super-admin` roles (function seeded before the grant). All timestamp columns already `TIMESTAMP WITH TIME ZONE` — no V1.2.x conversion needed. (SBDEV-1921; consolidated from several earlier per-step migrations into this single script) |
| ❌ not in v1 | ❌ not in v1 | — | V2.1.13 | `V2.1.13__add_reversal_completed_sysprop.sql` | Seeds `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` sysprop URL (SBDEV-1921); required to prevent NPE in `CancellationReversalService.completeReversal()` |

---

## 4. Sysprop ID Alignment Map `[updated 2026-05-30 — Round 14]`

`los_sysprop` has **two constraints**: `PRIMARY KEY (id)` AND `UNIQUE (client_id, syskey, workstation)`. Earlier revisions of this report documented an **id collision** here — v2 originally seeded `STALE_CLUB_BATCH_CLEANUP_*` at 142/143/144 and `PICK_PATH_DIRECTION` at 145, which PK-collided with v1's 140-143. **That has been deliberately fixed:** the v2 sysprop scripts were re-id'd to *align with the v1 baseline*. There is no longer any id collision.

| sysprop id | v1 value (after V1.1.09) | v2 value (after V2.1.09) | Result on a v1 DB |
|-----------|--------------------------|--------------------------|-------------------|
| 140 | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` (V2.1.08) | ✅ identical → V2.1.08 NO-OPS |
| 141 | `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` | `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` (V2.1.08) | ✅ identical → NO-OP |
| 142 | `STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE` | `STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE` (V2.1.08) | ✅ identical → NO-OP |
| 143 | `PICK_PATH_DIRECTION` | `PICK_PATH_DIRECTION` (V2.1.09) | ✅ identical → V2.1.09 NO-OPS |
| 144 | *(free in v1)* | `WEBSERVICE_ORDER_BATCH_PALLETIZED` (V2.1.02) | ✅ free → clean insert |
| 145 | *(free in v1)* | `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` (V2.1.02) | ✅ free → clean insert |

### Consequence: V2.1.08 is now safe on any v1 DB

V2.1.08 attempts `INSERT los_sysprop (id=140, syskey='STALE_CLUB_BATCH_CLEANUP_ACTIVATED', ...)` (and 141/142) with `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. On a v1 DB those exact `(id, syskey)` tuples already exist (v1 V1.1.07), so **both the PK and the unique constraint are satisfied by the existing rows** — the insert is a clean no-op. No `los_sysprop_pkey` violation occurs. Validated by a live double-apply against `wms1-wineco-dev` (2026-05-30). The §0.6 runbook applies the standard V2.1.08 directly; **no v1-compat variant is needed.**

---

## 5. What v1 Is Missing (v2-Only Scripts)

These features exist in v2 production but have never been applied to v1:

| Script | What v1 lacks | Impact if running v1 client on wms2 |
|--------|--------------|-------------------------------------|
| `V2.1.01` (v2) | `unitload.labelid UNIQUE` constraint | Duplicate label IDs possible under concurrency; wms2 relies on this constraint for idempotency in label generation |
| `V2.1.02` (v2) | `WEBSERVICE_ORDER_BATCH_PALLETIZED/LOADED_TO_TRUCK` OMS sysprops | wms2-api reads these endpoints to notify OMS on palletize/load events; missing rows mean OMS never gets those callbacks |
| `V2.1.03` (v2) | Rewritten `order_monitor_view` | v1 has an older view; wms2-web-ui queries the new schema — missing columns will cause UI errors |
| `V2.1.04` (v2) | 8 replenishment performance indexes | Severe query slowdowns on any warehouse with active replenishment; queries that are instant in wms2 will full-scan in a migrated v1 DB |
| `V2.1.05` | Critical state + FK indexes on 6 tables | `pickingorder`, `billoflading`, `advice` state queries do full scans — visible in picking, receiving, BOL workflows |
| `V2.1.06` | Composite indexes (`pickingorder`, `stockunit`, `customerorder_batch`) | Slow mobile picking and replenishment queries |
| `V2.1.07` | `transaction_detail` with `amount != 0` filter | Financial reports include spurious zero-amount PICKING rows; incorrect totals visible in transaction summary/detail screens |
| `V2.1.08` | `STALE_CLUB_BATCH_CLEANUP` sysprops | v1 already has these at ids 140-142; v2 seeds the **same** ids → V2.1.08 no-ops on v1. (On a fresh wms2 DB it enables operator config of the cleanup cron.) |
| `V2.1.09` | `PICK_PATH_DIRECTION` sysprop | v1 already has this at id=143; v2 now seeds the **same** id=143 → V2.1.09 no-ops on v1 |
| `V2.1.10` | `rest_idempotency` table | wms2-api requires this table to start — app will crash on boot without it |
| `V2.1.11` | `outbox_message` table | wms2-api requires this table to start — app will crash on boot without it |
| `V2.1.12` | `MOBILE_UI_VIEW_CANCELLATION` function seed **and** `customerorder_cancellation_log` table + 2 indexes (with `reversal_initiated_by`/`reversal_completed_by` created directly as `VARCHAR(255)`, no ALTER) **and** role grants for `MOBILE_UI_VIEW_CANCELLATION` | Cancellation Process menu item invisible in mobile UI without the function seed; required for all cancellation logging (`CancellationLogService.recordCancellation()` throws table-not-found on first order cancellation without it); Keycloak UUID operator IDs need the `VARCHAR(255)` columns; and operators in `outbound-manager`/`outbound-worker` roles cannot access the cancellation workflow without the grant |
| `V2.1.13` | `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` sysprop | `CancellationReversalService.completeReversal()` reads this sysprop for the OMS callback URL; missing row → NPE |

---

## 6. What v2 Is Missing from v1 (v1-Only Scripts)

| Script | Content | v2 status |
|--------|---------|-----------|
| `V1.1.06__transfer_order_state_fix.sql` | One-time data fix: `UPDATE customerorder SET state=505 WHERE state=510 AND transferlane_id IS NULL` | Not needed in v2 — the companion code fix (`TransferOrderService.java`) is already in wms2; only v1 DBs accumulated stuck rows. Run this on v1 DBs **before** migration, not after. |
| `V1.1.07__wms_updates.sql` | `STALE_CLUB_BATCH_CLEANUP_*` sysprops at ids 140-142 | v2 has these at the **same** ids 140-142 (V2.1.08, re-id'd to align with v1). On a v1 DB, V2.1.08 no-ops via composite `ON CONFLICT`. |
| `V1.1.08__wms_functions.sql` | `transaction_detail` function update | v2 has a newer version in V2.1.07 with the `amount != 0` fix. The v1 V1.1.08 version is **superseded** by V2.1.07. |
| `V1.1.09__pick_path_direction.sql` | `PICK_PATH_DIRECTION` sysprop at id=143 | v2 has this at the **same** id=143 (V2.1.09). v1 client DBs already have it → V2.1.09 no-ops. |

**Summary:** None of the v1-only scripts represent features that v2 lacks. All are either one-time data fixes already handled in v2 code, or sysprop seeds already present under different IDs in v1 DBs.

---

## 7. v1→v2 Migration Script Adjustments Required

The §0.6 runbook in `260523-UTC-TIMEZONE-MIGRATION.md` Step 3 applies the full contiguous `V2.1.01–V2.1.13` sequence on v1 DBs, in order. V2.1.01–V2.1.04 are detailed in §3; the per-script status of the v2-only additions (V2.1.05 onward) is below — **all are safe** (idempotent, or aligned with the v1 baseline):

| Script | Safe to run on v1 DB as-is? | Action required |
|--------|----------------------------|-----------------|
| `V2.1.05__add_critical_missing_indexes.sql` | ✅ Yes | `CREATE INDEX IF NOT EXISTS` — fully idempotent |
| `V2.1.06__add_composite_indexes.sql` | ✅ Yes | `CREATE INDEX` — safe (indexes don't exist in v1) |
| `V2.1.07__update_transaction_detail_pick_amount_filter.sql` | ✅ Yes | `CREATE OR REPLACE FUNCTION` — replaces v1's older V1.1.08 version |
| `V2.1.08__stale_club_batch_cleanup_sysprops.sql` | ✅ Yes | Re-id'd to 140/141/142 (= v1's ids); composite `ON CONFLICT DO NOTHING` no-ops on v1. No v1-compat variant needed. |
| `V2.1.09__add_pick_path_direction_sysprop.sql` | ✅ Yes | Inserts at id=143 (= v1's id) with composite `ON CONFLICT DO NOTHING` → no-ops on v1 |
| `V2.1.10__add_rest_idempotency.sql` | ✅ Yes | `CREATE TABLE` — safe if not exists check recommended |
| `V2.1.11__add_outbox_message.sql` | ✅ Yes | `CREATE TABLE` — safe |
| `V2.1.12__add_cancellation_reversal_log_and_grant.sql` | ✅ Yes | Seeds `MOBILE_UI_VIEW_CANCELLATION` (`INSERT ... ON CONFLICT (function) DO NOTHING`), then `CREATE TABLE` + 2 indexes (with `reversal_initiated_by`/`reversal_completed_by` declared directly as `VARCHAR(255)` — no ALTER step) **and** `INSERT ... ON CONFLICT DO NOTHING` role grant — safe; function seed and grant are idempotent and the table is new to wms2 |
| `V2.1.13__add_reversal_completed_sysprop.sql` | ✅ Yes | `INSERT ... WHERE NOT EXISTS` — idempotent; **edit the placeholder OMS URL for each client before running** |

### ~~Fix for V1.1.13: v1-compatible variant~~ — REMOVED (Round 14, 2026-05-30)

Earlier revisions required a `V1.1.13__stale_club_batch_cleanup_sysprops_v1compat.sql` variant (in `db/migration/v1-onboarding/`) because the *old* V2.1.08 seeded ids 142/143/144 and PK-collided on every v1 DB. **This is obsolete.** V2.1.08 was re-id'd to **140/141/142** to match the v1 baseline, so the standard V2.1.08 no-ops cleanly on v1 via its composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. The v1-compat variant and the entire `v1-onboarding/` subdirectory have been **deleted** from the repo. Use the standard V2.1.08 everywhere.

### Pre-flight: run the v1 stuck-order fix first

Before running any of the V2.1.05–V2.1.11 scripts, check and fix stuck transfer orders on the v1 DB. This is equivalent to what V1.1.06 in v1 does:

```sql
-- Pre-migration check: identify stuck orders (should be zero on a healthy v1 DB)
SELECT id, clientordernumber, state, transferlane_id
FROM customerorder
WHERE state = 510 AND transferlane_id IS NULL;

-- If any rows found, fix them:
UPDATE customerorder
SET state = 505, modified = now()
WHERE state = 510 AND transferlane_id IS NULL;
```

### OMS endpoint sysprops — now handled by V2.1.02 (no separate step)

Earlier revisions added `WEBSERVICE_ORDER_BATCH_PALLETIZED` / `..._LOADED_TO_TRUCK` via a manual INSERT during the pre-flight. **This is now part of the standard sequence:** `V2.1.02__add_palletized_loaded_to_truck_sysprops.sql` seeds both at the **free ids 144/145** with composite `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`. The only per-client action is to substitute the OMS host placeholder (`oms-XXXXX.siteboss.net`) in V2.1.02 — and in V2.1.13 — before running (see §0.6 pre-flight 2).

---

## 8. §0.6 Step 3 Script Execution Order `[updated 2026-05-30 — Round 14: single linear apply]`

The §0.6 runbook applies the standard V2.1.x scripts **in order, in a single loop** — no v1-compat branching, no separate onboarding step. Per-client pre-flight: (1) fix stuck transfer orders, (2) substitute the OMS host in V2.1.02 and V2.1.13. This mirrors §0.6 Step 3 of `260523-UTC-TIMEZONE-MIGRATION.md`.

```bash
# Pre-flight 1: Fix stuck transfer orders (v1 hotfix equivalent; idempotent)
PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <client_db> \
  -c "UPDATE customerorder SET state=505, modified=now() WHERE state=510 AND transferlane_id IS NULL;"

# Pre-flight 2: Substitute the OMS host placeholder in V2.1.02 and V2.1.13 for THIS client
#   sed -i "s/oms-XXXXX\.siteboss\.net/oms-<client>.siteboss.net/g" \
#     v2/wms2-api/src/main/resources/db/migration/V2.1.02__*.sql \
#     v2/wms2-api/src/main/resources/db/migration/V2.1.13__*.sql

# Apply the contiguous V2.1.01–V2.1.13 sequence in order
for script in V2.1.01__add_unique_constraint_unitload_labelid.sql \
              V2.1.02__add_palletized_loaded_to_truck_sysprops.sql \
              V2.1.03__update_dashboard_summary_view.sql \
              V2.1.04__replenishorder_performance_indexes.sql \
              V2.1.05__add_critical_missing_indexes.sql \
              V2.1.06__add_composite_indexes.sql \
              V2.1.07__update_transaction_detail_pick_amount_filter.sql \
              V2.1.08__stale_club_batch_cleanup_sysprops.sql \
              V2.1.09__add_pick_path_direction_sysprop.sql \
              V2.1.10__add_rest_idempotency.sql \
              V2.1.11__add_outbox_message.sql \
              V2.1.12__add_cancellation_reversal_log_and_grant.sql \
              V2.1.13__add_reversal_completed_sysprop.sql; do
  echo "Applying $script..."
  [ -f "v2/wms2-api/src/main/resources/db/migration/$script" ] \
    || { echo "ABORT: $script not found on disk"; exit 1; }
  PGPASSWORD=<pwd> psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <client_db> \
    -f v2/wms2-api/src/main/resources/db/migration/$script \
    || { echo "ABORT: $script failed"; exit 1; }
done
```

> **Why every script is safe on a v1 DB:** V2.1.01 (0 dup labelids → constraint succeeds), V2.1.02 (free ids 144/145), V2.1.03 (`CREATE OR REPLACE VIEW`), V2.1.04–V2.1.06 (`CREATE INDEX IF NOT EXISTS`), V2.1.07 (`CREATE OR REPLACE FUNCTION`, identical to v1's), V2.1.08/V2.1.09 (re-id'd to 140-143 → no-op via composite `ON CONFLICT`), V2.1.10/V2.1.11 (new tables), V2.1.12 (new table + idempotent function seed/grant), V2.1.13 (copies the existing `WEBSERVICE_ORDER_BATCH_CANCELLED` row — **verify it's present per client**). Validated live on `wms1-wineco-dev` 2026-05-30.

---

## 9. Recommendations for Smooth v1→v2 Client Migration

### Schema & Data

1. **~~Create and version-control `V1.1.13_v1compat`~~** — OBSOLETE (Round 14). V2.1.08 was re-id'd to 140/141/142 to align with the v1 baseline, so the standard script no-ops on v1 via composite `ON CONFLICT`. The v1-compat variant and the `v1-onboarding/` subdirectory were deleted. Use the standard V2.1.08 everywhere.

2. **Run the stuck-order fix first on every v1 DB** — `SELECT COUNT(*) FROM customerorder WHERE state=510 AND transferlane_id IS NULL` before any migration. Non-zero counts need the state reset before wms2 starts serving that client (wms2 code does not re-run this fix).

3. **Add the `unitload.labelid` UNIQUE constraint (v2 V2.1.01) to v1** — this is a schema fix that v1 is missing entirely. Under wms2's concurrency patterns, the absence of this constraint creates a silent race condition on label generation. Backport it to v1 production now, before migration begins, to reduce risk.

4. **Backport V2.1.07 `transaction_detail` fix to v1 now** — v1 V1.1.08 reports include zero-amount PICKING rows in transaction summaries. V2.1.07 fixes this with `AND sr.amount != 0`. This is a pure bug fix that is safe to apply to v1 production immediately regardless of migration timing.

5. **Apply V2.1.04–V2.1.06 performance indexes to v1 now** — the replenishment and state-query indexes in these v2-only scripts are pure additions with no behavioral side-effects. Applying them to v1 production reduces query times in both v1 (before migration) and v2 (after migration).

### Sysprops

6. **Audit sysprop IDs 140-145 on every v1 client DB before migration** — run:
   ```sql
   SELECT id, syskey, sysvalue FROM los_sysprop WHERE id BETWEEN 140 AND 150 ORDER BY id;
   ```
   Verify the expected v1 values (140-142 = STALE_CLUB_BATCH_CLEANUP_*, 143 = PICK_PATH_DIRECTION). Any deviation means that v1 instance received custom configuration that must be preserved.

7. **Sysprop IDs are now aligned (no divergence)** — after the Round-14 re-id, ids 140-143 hold the **same** syskeys on v1 client DBs and fresh wms2 DBs (`STALE_CLUB_BATCH_CLEANUP_*` at 140-142, `PICK_PATH_DIRECTION` at 143); the new OMS sysprops occupy the free ids 144/145. No id divergence remains to document.

### Process

8. **Always run §0.6 pre-flight on a clone first** — restore the v1 client DB to a staging clone, run the full §0.6 → §0.5 sequence, start wms2 against it, run smoke tests. Only proceed to production after staging is clean.

9. **Add a post-migration sysprop verification query** to the smoke test checklist:
   ```sql
   SELECT syskey, sysvalue FROM los_sysprop
   WHERE syskey IN (
     'System Time Zone',
     'WEBSERVICE_ORDER_BATCH_PALLETIZED',
     'WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK',
     'STALE_CLUB_BATCH_CLEANUP_ACTIVATED',
     'PICK_PATH_DIRECTION'
   ) ORDER BY syskey;
   -- All 5 rows must be present with correct values
   ```

10. ~~Update §0.6 Step 3 to reference the v1-compat variant of V1.1.13 and add the stuck-order fix step.~~ **Superseded by Round 14 (2026-05-30):** the v1-compat approach was abandoned. V2.1.08 was re-id'd to 140/141/142 (aligning with v1), the `v1-onboarding/` scripts were deleted, and §0.6 Step 3 is now a single linear apply of V2.1.01–V2.1.13. The PK-collision risk row in the plan is marked RESOLVED.

---

## 10. Files to Create / Add to wms2-api Repo

| File | Location | Status |
|------|----------|--------|
| `V1.1.13__stale_club_batch_cleanup_sysprops_v1compat.sql` | ~~`db/migration/v1-onboarding/`~~ | ❌ **DELETED 2026-05-30** — obsolete after V2.1.08 re-id; standard V2.1.08 no-ops on v1 |
| `V1.1.17__oms_endpoint_sysprops_v1client.sql` (template) | ~~`db/migration/v1-onboarding/`~~ | ❌ **DELETED 2026-05-30** — OMS sysprops now seeded by the standard V2.1.02 (ids 144/145) |
| `V1.1.00__pre_migration_fixes.sql` (optional) | — | Not created — the stuck-order fix is pre-flight 1 of the §0.6 runbook (inline `psql -c`); a separate file is not required |
| `V2.1.12__add_cancellation_reversal_log_and_grant.sql` | `src/main/resources/db/migration/` (main) | ✅ Created 2026-05-28 (SBDEV-1921) — seeds `MOBILE_UI_VIEW_CANCELLATION` function (idempotent), then `CREATE TABLE` + 2 indexes (with `reversal_initiated_by`/`reversal_completed_by` directly `VARCHAR(255)`, no ALTER) **and** idempotent role grant; safe to run on v1 client DBs. Consolidated from several earlier per-step migrations into this single script |
| `V2.1.13__add_reversal_completed_sysprop.sql` | `src/main/resources/db/migration/` (main) | ✅ Created 2026-05-28 (SBDEV-1921) — **edit placeholder OMS URL per client before running** |

**The `v1-onboarding/` subdirectory no longer exists** (deleted Round 14, 2026-05-30). All migrations now live in the main `db/migration/` folder and run as the single linear §0.6 sequence (§8). None are auto-run by Flyway — `flyway-core` is `test`-scope in wms2-api, so production migration is manual psql only.
