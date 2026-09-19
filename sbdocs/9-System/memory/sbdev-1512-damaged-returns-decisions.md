---
name: sbdev-1512-damaged-returns-decisions
description: "SBDEV-1512 damaged-from-returns — Nam's settled decisions D1-D8, the entity_lock-not-location reframe, and the E7->E8 reversal that moved the real defect into the OMS"
metadata: 
  node_type: memory
  type: project
  originSessionId: 75060194-ee15-400f-bfc3-b3e78707041b
  modified: 2026-09-15T18:46:27.438Z
---

**SBDEV-1512 (WMS/QA: Receive Damaged from Returns), planned 2026-09-15 as T3.** Plan at
`sbdocs/1-Projects/wms2/plan/SBDEV-1512-receive-damaged-from-returns.md` (~2077 lines); evidence
E0-E8 + 4 review lanes in `SBDEV-1512-evidence/`.

The QA station drops the damaged quantity — `v1/qa-api` `flask_app/common_util/wms_api.py`,
`"amount_of_bottles = returned_items[item.item_id]['qty_undamaged']"`. The WMS advice schema has no
field to receive it into. Net-new capability; four probes with positive controls confirm no v2 path
receives stock into a damaged state.

**THE REFRAME — "damaged inventory" is a LOCK CODE, not the Damaged location.** `stock_view.damaged`
is `sum(CASE WHEN su.entity_lock = 103 OR ul.entity_lock = 103 ...)` and never references
`location.name = 'Damaged'`. The ticket's wording ("placed in the Damage location") is **not**
sufficient — a fix that only moves stock there leaves the client's report as empty as before, which
is the exact complaint that opened the ticket. **Grade the lock, never location membership.**

**Settled decisions (Nam, 2026-09-15).** D1 receive the full quantity then reuse
`StockunitService.setLockDamaged` (applies lock 103 + moves to `Damaged` + writes
`activitycode='DAMAGED'`, so it covers all reporting surfaces). D2 additive, unconditional
`amount_of_bottles_damaged` on the advice position; v2 consumes, v1 ignores; v1 not fixed.
D3 receive-then-split, two unit loads per mixed line, label on the good one. D4 the
`/rest/advice/create` permitAll + ungated `setLockDamaged` exposure knowingly accepted per the
2026-08-27 "/rest/** is internal-only" decision. D5 two `StockChangeDto` messages, no DTO change.
D6-A `notifiedamount = undamaged + damaged`. D6-B two nullable columns in one `V2.2.31` migration —
`notifieddamagedamount` + `damageappliedat` — worklist is
`notifieddamagedamount > 0 AND damageappliedat IS NULL`. D7 qa-api reads `data.get('warning')` on a
200. **D8 was decided and then WITHDRAWN — see below.**

## ⚠ The E7 -> E8 reversal. Do not re-derive E7.

E7 concluded that three WMS sites (`setLockDamaged`, `transferStock`, `MobileMoveUnitloadService`)
wrongly send `normal = 0` where the OMS needs `normal = -N`, and D8 was decided on it. **That was
backwards.** `normal` is a **GROSS physical delta**; the OMS derives sellable by netting at
ingestion. All the WMS sites are correct and match v1's Zend OMS unchanged.

The real defect is `oms-laravel-api` commit **`dd17b84f` (2026-07-31, SBDEV-2671)**, which changed
`if (array_key_exists('quantity_on_hand', $quantities))` to
`if (!$addToExisting && array_key_exists(...))` — disabling netting on the incremental path, which
is the one the WMS uses. Filed as **SBDEV-3366** (Urgent). Fix is one condition in one PHP file.

Measured on live v1 prod `wh01_shipitez`, `message` table: **173** rows of `normal:0, damaged:+N`,
**0** of `normal:-N, damaged:+N`, 2022-07-31 -> 2026-09-15. Positive control: the same matcher finds
`"normal": -N` **1,634** times overall — the WMS emits negative `normal` routinely, just never in
that pairing. The tuple `dd17b84f` assumed has never existed.

**Why E7 failed, and this is the reusable part:** it read the **consumer's own code comment** as the
contract and never checked it against **producer traffic** — and that comment was written by the
change that introduced the regression. See [[verify-a-contract-against-the-wire-not-the-comment]].

## How to apply

- `v1/qa-api` and `v1/qa-ui` are the QA station (Python Flask + Nuxt 2) and are **not listed in the
  root CLAUDE.md**. `qa-api` is **shared** across v1 and v2 clients, routing by `wms_url` per
  facility (`wms_url_lut`), so a change there hits live v1 production the day it deploys.
- ShipItEZ runs **v1 in production**; their v2 DBs are provisioned and schema-current **ahead of**
  cutover (both at `V2.2.30`, 0 failed). Client traffic not cut over != v2 schema not provisioned —
  see [[review-lanes-under-audit-prerequisite-tables]].
- **SBDEV-3366 is a correctness gate at ShipItEZ cutover, not at merge.** SBDEV-1512 is safe to ship
  to dev/UAT/Hydra (Hydra has 1 RETURN advice ever); ShipItEZ brings ~250 returns/year.
- Open, all needing an OMS/QA MySQL MCP that does not exist: true damaged-quantity exposure;
  whether ShipItEZ's `ship_return_management` is set to restock (Defect A bites **only** where the
  config is correct); any real OMS-vs-WMS inventory reconciliation.

Related: [[wms2-rts-roadmap-decisions]] (names R3 damaged-at-receipt as this ticket's),
[[a-zero-scan-needs-a-positive-control]], [[shipitez-two-warehouse-v2-migration]].
