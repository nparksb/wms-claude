---
title: "Revert Mistakenly Shipped Order Back to CANCELED — Incident Plan"
ticket: ""
ticket_url: ""
type: "Data Remediation (incident plan)"
priority: "High"
status: "archived"
project: [wms1]
version: "v1/wms-api (PostgreSQL)"
requester: "Nam Park"
created: "2026-04-23"
updated: "2026-04-25"
related:
  - "[[wms1-revert-shipped-order-to-cancelled]]"
  - "[[wms1-cancel-packed-parcel]]"
tags:
  - plan
  - data-remediation
  - cancellation
  - shipping
---

# Revert Mistakenly Shipped Order Back to CANCELED — Incident Plan

**Project:** v1/wms-api — `wms1-wineco` PostgreSQL
**Type:** Incident plan (procedure lives in the runbook)
**Status:** In progress — awaiting approval to run the runbook against production data
**Date (updated):** 2026-04-24

> This is the **incident record**. The reusable procedure (diagnosis SQL, reversal SQL, verification, options) lives in the runbook:
> **→ [2-Areas/runbooks/wms1-revert-shipped-order-to-cancelled.md](../../../2-Areas/runbooks/wms1-revert-shipped-order-to-cancelled.md)**

---

## 1. The incident

A Pick-Pack customer order was pushed from OMS to WMS, moved through OMS QA, then **cancelled by OMS**. On the WMS side, however, the order continued to be picked, packed, palletized, and **shipped** — BOL closed, parcel moved to the `Shipped` location, stockunits locked as SHIPPED. The WMS-side and OMS-side now disagree about whether the order shipped.

Requested fix:
1. Revert the WMS order to `CANCELED` (state = 800).
2. Adjust the shipped stockunits' quantities back to the pick-from locations they were drawn from (Option B in the runbook).

---

## 2. Initial framing (pre-runbook)

When first asked, the exact customer order number was not provided. This plan was drafted first against a generic template, then dry-run against two candidate orders to confirm the procedure:

| Attempt | Order | Outcome | Notes |
|---|---|---|---|
| 1 | `051612-000001` (id 25763709) | **Not applicable — never shipped.** State 800, `amountpicked = 0`, no `pickingorder`, no parcel `unitload`, no `billoflading_position`. Message log shows `IMPORT → ORDER_BATCH_ON_HOLD (reason 55 = not enough stock) → ORDER_BATCH_CANCELLED_FROM_PSD` inside 68 seconds. Clean pre-pick cancel. | Disqualified the order — nothing to reverse. |
| 2 | `051617-000001` (id 25799201) | **Matches the scenario.** State 700, `amountpicked = 6` per position, full picking chain, parcel on `Shipped` (entity_lock 405) carried by pallet `PM-015535` (which **also** carries an unrelated shipped parcel `EK1776904234859` / order `051615-000001`), BOL `OBOL116939` CLOSED. | Target order for the reversal. |

---

## 3. Current state snapshot (order `051617-000001`, as of 2026-04-24)

| Entity | Id / label | State | Notes |
|---|---|---|---|
| `customerorder` | 25799201 / `051617-000001` ext `564297` | state=**700**, entity_lock=0, `pickingconfirmationsent=true`, `markedforcancellation=false` | `parcel_id=25799252`, `parcelexternalnumber=KU1777036761068` |
| `customerorder_batch` | 25799200 / `051617` | state=**700**, type=`PICK_PACK` | |
| `customerorder_position` | 25799202, 25799203 | state=**700**, `amountpicked=6.0000` each | WINE750, TESTSKU |
| `pickingorder` | 25799216 / `PICK227131` | state=**700** | Contains **only** this order's positions — safe to cancel wholesale |
| `pickingorder_position` | 25799217 (WINE750), 25799219 (TESTSKU) | state=**600** (PICKED), `pickfromstockunit_id=NULL` | Labels retained: `TCOMPANY-01`, `TCOMPANY-04` |
| `pickingorder_unitload` | 25799222 | state=**700**, `unitload_id=NULL`, `historytote='T-0500'` | Already detached from physical tote |
| `unitload` parcel | 25799252 / `KU1777036761068` | `Shipped`, entity_lock=**405**, `carrierunitload_id=25799258` | **Shared pallet ahead** — must detach before moving |
| `unitload` pallet | 25799258 / `PM-015535` | `Shipped`, entity_lock=405, `child_count=2` | **Shared with sibling order `051615-000001` (id 25781467)** — leave the pallet alone |
| `stockunit` on parcel | 25799225 (WINE750, 6), 25799233 (TESTSKU, 6) | entity_lock=**405** | |
| `billoflading` | 25799266 / `OBOL116939` | state=`CLOSED`, shipped=2026-04-24 | Covers this order **and** the sibling |
| `billoflading_position` — ours | 25799273 (parcel-level), 25799274 (pos WINE750), 25799275 (pos TESTSKU) | `CLOSED` | Runbook flips only these three |
| `billoflading_position` — pallet + sibling | 25799270 (pallet), 25799271 (sibling parcel), 25799272 (sibling position) | `CLOSED` | **Do not touch** |
| source UL `TCOMPANY-01` | id 66251, entity_lock=0 | Healthy | Source SU 66350 amount=**9401**, reservedamount=44 |
| source UL `TCOMPANY-04` | id 600748453, entity_lock=0 | Healthy | Source SU 3226805 amount=**186**, reservedamount=45 |

**Partial prior-attempt residue:** `modified` timestamps on `customerorder`, `customerorder_position`, and the two parcel stockunits are all `2026-04-24 13:36:09.820777`, matching a `stockrecord` row with operator `db_manual_cancel:nam.park` (activitycode `CANCELLED_ORDER_FROM_WEBSERVICE`, type `STOCK_ALTERED`, Clearing→Clearing, no amounts). Essentials were not changed (state/lock/amounts unchanged) — looks like an earlier SQL touched `modified` columns but the substantive DML didn't land or was rolled back. The reversal is still needed in full.

---

## 4. Options decided for this incident

- **Option B** (return quantities to source stockunits) — requested by the operator; §4.6 of the runbook confirms both source stockunits exist and are unlocked (entity_lock=0). Expected post-run source amounts: `TCOMPANY-01` SU 66350 → 9407; `TCOMPANY-04` SU 3226805 → 192.
- **Keep `parcel_id` set** on the customer order after CANCEL (runbook default) — leaves the parcel visible in Order Monitor under its own label after Clearing.
- **BOL:** flip only our three BOL positions to `CANCELLED`; leave `OBOL116939` header, the pallet-level position, and sibling positions alone (sibling `051615-000001` is legitimately shipped).
- **Sequence name:** confirmed `seqentities` on `wms1-wineco-dev`.

---

## 5. Runbook adjustments discovered during the dry-run

The durable runbook already contains the correct generic form. The following adjustments (relative to the earlier draft) were made in response to this incident and now live in the runbook:

1. **Accept state 700 OR 800** in the §5.1 guard — the order may have had a prior partial manual flip.
2. **Resolve source stockunit by label + SKU** (not by `pickfromstockunit_id`) — the pick flow nulls that FK after a successful pick.
3. **Detach the parcel from any outbound pallet** before the Shipped→Clearing move, and never move / unlock the pallet itself. Use a recursive CTE that starts at the parcel and descends only (never up to the pallet).
4. **Never flip the BOL header** — `billoflading.state` stays `CLOSED`, only the order's BOL positions flip to `CANCELLED`.
5. **Sequence name is `seqentities`** (not `hibernate_sequence`) on this DB.
6. **§5.3.b defaults to keeping `parcel_id`** on the customer order (mirrors `CustomerorderService.forceCancelOrder` PACKED branch).
7. **Option B guard** — counts expected vs. resolved positions, aborts if any is unresolved rather than silently skipping.

---

## 6. Execution plan for this incident

1. Confirm `:ORDER_NUMBER = '051617-000001'`, `:OPERATOR = <DBA username>`.
2. Run the runbook §4 diagnostics, capture outputs into this ticket for audit.
3. Confirm this incident's decision matrix:
   - Option B (return quantities) — validated by §4.6.
   - Keep `parcel_id` set — see §4 of this plan.
   - BOL positions only, header untouched — see §4 of this plan.
4. Run the runbook §5 DML blocks (§5.1 → §5.2 → §5.3 → §5.4 → §5.5) inside a single `BEGIN…` transaction.
5. Run runbook §7 verification queries before committing. Cross-check against the snapshots in §3 of this plan.
6. `COMMIT` only if every §7 check is clean; otherwise `ROLLBACK` and escalate per runbook §6.
7. Physically pull parcel `KU1777036761068` from the Shipped lane and restock the items to `TCOMPANY-01` / `TCOMPANY-04`.
8. Coordinate with OMS on the `ORDER_BATCH_SHIPPED` message reconciliation (see runbook §8).
9. File/update the root-cause ticket (runbook §8 post-incident bullets).

---

## 7. Root-cause follow-up

WMS advanced order `051617-000001` past PACKED **after** OMS cancelled it. Likely candidates (to be investigated separately):

- `BillofladingService.closeBillOfLading(...)` bulk-updates `customerorder.state` via `customerorderRepository.updateStateByIds(FINISHED, allOrderIds)` with **no state guard** — it would overwrite a CANCELED order back to FINISHED if the parcel was still included in a BOL being closed.
- OMS cancel message may have been `RECEIVED` but not fully `PROCESSING`'d before WMS close-BOL ran.
- `markedforcancellation` was not set on this order at ship time (current value `false`) — either OMS's cancel message set it and it was cleared, or the OMS cancel path took a different route. Compare with messages in the `message` table for this batch (runbook §4.9).

A separate bug fix plan should tighten the BOL close-flow so it refuses to overwrite a CANCELED order's state, or at least raises an audit error when it encounters one in the BOL pallet tree.

---

## 8. Links

- **Runbook (procedure):** [2-Areas/runbooks/wms1-revert-shipped-order-to-cancelled.md](../../../2-Areas/runbooks/wms1-revert-shipped-order-to-cancelled.md)
- **Sibling runbook:** [2-Areas/runbooks/wms1-cancel-packed-parcel.md](../../../2-Areas/runbooks/wms1-cancel-packed-parcel.md) — for pre-ship cancellation
- **Investigation data:** the §3 snapshot above, captured against `wms1-wineco-dev` on 2026-04-24
