---
name: wms2-estate-all-users-system-sdr-guard-off
description: "Measured 2026-10-30 — every v2 tenant DB (DEV, 4 UAT, 4 PRD) has 0 non-System users; WMS2_SDR_READ_GUARD_MODE is OFF on all UAT/PRD (SHADOW on DEV). Object-level client scoping is pre-emptive today; SDR reads are unguarded"
metadata:
  node_type: memory
  type: project
  originSessionId: 7b155671-54ac-4689-8213-a9af450d48d6
  modified: 2026-10-30T12:58:30.688Z
---

Measured 2026-10-30 for SBDEV-3668 P-1, on all 8 v2 UAT/PRD tenant DBs plus DEV: WineCo `wh01_om1_v2`, Hydra `wh01_hydra_v2`, ShipItEZ `wh01_shipitez_v2` (LA) and `wh02_shipitez_v2` (NY). Each DB was schema-checked as v2 first.

- **0 non-System users** (users whose client's `cl_nr` is not `System`) everywhere. Control: System users = all users, and 0 users point at a missing client. Users: WineCo 94, Hydra 9 PRD / 20 UAT, ShipItEZ 37 LA / 11 NY.
- **Multi-client warehouses do exist:** `replenishorder` spans up to 124 clients (WineCo PRD) and 90 (ShipItEZ LA PRD).
- **`WMS2_SDR_READ_GUARD_MODE` = OFF on every UAT/PRD DB.** It is SHADOW on DEV `dev_wh01_om1`.

**Why:** any cross-client authorization finding (a client-A user touching client-B rows) has zero live exposure today, because everyone is a System user. But the first non-System user onboarded is exposed immediately, and the SDR read guard gives no protection anywhere outside DEV.

**How to apply:**
- Frame client-scoping fixes as pre-emptive with an onboarding gate, not as live incidents.
- Re-measure before trusting this: user rows change. Use the per-DB query from the SBDEV-3668 plan's §1 plus the System = all control.
- Do not cite DEV's SHADOW guard mode as the production state.
- Onboarding gate: P31 (SDR + web by-id replenish scoping) before any non-System user. Related: [[wms2-estate-census-is-six-tenant-dbs]], [[wineco-is-a-v2-client-prd-mcp-is-wms1-wineco]].
