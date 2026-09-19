---
name: wms2-utc-v1205-hardcoded-function-list
description: UTC migration V1.2.05 hard-codes 3 functions + global sanity check → aborts on any client-custom timestamp function
metadata: 
  node_type: memory
  type: reference
  originSessionId: 59a49d44-d682-4314-8d9a-169d017b6ca6
  modified: 2026-07-30T12:56:04.056Z
---

The UTC-migration script `V1.2.05__utc_update_functions.sql` (v2/wms2-api `db/migration/`) recreates a **hard-coded list of 3 standard functions** (`stock_history`, `transaction_detail`, `transaction_summary`) with `timestamptz` signatures, then runs a **global** `DO`-block that ABORTs if *any* `public` function parameter is still `timestamp without time zone`.

**Consequence:** any client-custom/extra `public` function with a `timestamp` param that isn't in the list will abort Phase F at V1.2.05 (`ERROR: ABORT: N function parameter(s) still timestamp without time zone`). V1.2.05 runs in one tx, so it rolls back atomically — leaving tables+views converted (committed by V1.2.01–04) but all functions back to `timestamp` (mixed state). The rest of `07-utc-migrate` already ran.

**First hit:** ShipItEZ LA `wh01_shipitez_v2` 2026-06-28 — carried a 4th fn `stock_history2` (a `stock_history` variant, inherited from the `wh02_hydra` UAT seed). Resolved by `DROP FUNCTION stock_history2(...)` (0 view/fn dependents) then re-running just V1.2.05 (`psql -f`, individually re-runnable per SOP §2).

**⚠️ SECOND, QUIETER FAILURE MODE — hand-MODIFIED standard functions are silently OVERWRITTEN.** The abort
above only catches *extra* functions. For the 3 in the list, V1.2.05 does `DROP FUNCTION` + `CREATE OR REPLACE`
with a **hard-coded body**, so any out-of-band edit a client made to `stock_history` /`transaction_detail` /
`transaction_summary` on their v1 DB is discarded with no error and no warning.

**Confirmed 2026-07-30, WineCo:** live v1 `wms1-wineco` `stock_history` carries 4 changes that exist in **no
migration script in either repo and in neither repo's git history** (`git log -S` clean) — hand-applied to the
v1 DB:
- `sr.client_id` in the received_recordset subquery SELECT
- `GROUP BY sr.itemdata, sr.client_id` (repo/v2: `GROUP BY sr.itemdata` only)
- join `AND received_recordset.client_id = sv.client_id` (repo/v2: on `itemdata` only)
- `OR (STOCK_REMOVED AND STOCK_ALTERED)` in `received`, `OR (MANUAL_REMOVAL AND STOCK_ALTERED)` in `adjustments`

The client_id ones are a real correctness bug in v2: without them every client's `stock_view` row joins the
**all-clients** stockrecord aggregate. Proven on `dev_wh01_om1` — SKU `PNRO23`, client 146701 true received
1,074, function returns 8,322. Propagates: `stock_history` is called 4× by `transaction_detail`
(BEGINNING/ENDING rows) and `transaction_summary` (beginning/ending_inventory, net_change). v2 is also
internally inconsistent — its own `transaction_detail`/`transaction_summary` DO count the two extra
activitycode pairs; only `stock_history` doesn't. **All 5 v2 tenants lack it** (repo baseline), actively wrong
where SKUs are shared across clients: wsl/wh01_om1_v2 135 SKUs, dev_wh01_om1 43, c1wh 13, nywh-hydra 7,
nywh-shipitez 0 (latent).

**Before any Phase F, also DIFF the 3 standard functions** on the source v1 DB against
`db/v1-to-v2-onboarding/schema/V1.0.03__wms_functions.sql`, not just count them — a client may have hand-fixed
a body years ago. `md5(pg_get_functiondef(oid))` per function is enough to spot it.

**Before any Phase F:** enumerate `SELECT proname, pg_get_function_arguments(oid) FROM pg_proc WHERE pronamespace='public'::regnamespace;` — if >3, decide per extra fn: convert (recreate with timestamptz param) or drop (if 0 deps + unused). **Toolkit fix candidate:** `01-preflight` should flag non-standard public functions, or V1.2.05 should convert all dynamically instead of a fixed list. Related: [[shipitez-two-warehouse-v2-migration]].

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

Phase F aborts on any client-custom timestamp fn (e.g. ShipItEZ stock_history2); enumerate public fns before Phase F, convert-or-drop extras. QUIETER MODE: it DROP+CREATEs the 3 standard fns from hard-coded bodies, silently discarding hand-edits — WineCo v1 stock_history has client_id grouping (never in any repo/git) that all 5 v2 tenants lack, a live mis-aggregation bug; DIFF the 3 fn bodies pre-Phase-F, don't just count them
