---
title: "WineCo Replenishment — Pick-Pack Locations Counted as Replenishable & Inaccurate Order Counts"
type: investigation
status: concluded
version: "v1/wms-api @ release (0d6f989)"
scope: "v1/wms-api replenishment subsystem — ReplenishmentMonitorView, ReplenishGeneratorService, source-stock selection"
owner: "Nam Park"
created: 2026-06-01
updated: 2026-06-01
last_verified: 2026-06-01
verified_by: "wms1-wineco production DB (read-only), release branch code read"
related:
  - "[[wms1-replenish-order-creation]]"
  - "[[wms1-replenish-workflow]]"
tags:
  - investigation
  - report
  - wms1
  - replenish
---

# WineCo Replenishment — Pick-Pack Locations Counted as Replenishable & Inaccurate Order Counts

**Topic:** v1/wms-api replenishment subsystem | **Version:** release branch, HEAD `0d6f989`
**Started:** 2026-06-01 | **Investigator:** Nam Park
**Status:** concluded

> ⚠️ **Production, read-only.** All evidence below was gathered from the live `wms1-wineco` database via read-only queries. No INSERT/UPDATE/DELETE was issued. The "immediate recovery" step in §8 is an operational recommendation, not something performed during this investigation.

---

## 1. Context & Trigger

WineCo (operations) reported two replenishment problems blocking a same-day shipment:

1. **"System still is using Pick Pack Locations as valid replenishment."**
2. **"Issue with the number of orders not being accurate in the Replenishment [Monitor]."**

Evidence supplied by the client:

- **Parcel 279233 / Brooks Winery / status On Hold / batch 46954-16 / WMS parcel `VN1779810411125`.** Item **BW23CPN** shows *"Not enough stock on location"* on the parcel detail, but the SKU Location Report shows BW23CPN at **10-B01** with **Total Qty 11 / Reserved Qty 11**.
- **Replenishment Monitor** for **Cristom** shows Qty Req / Parcels / Priority counts that do not visually reconcile, e.g. **25GNEAH750** with **Qty Req 19** while SKU evidence shows available stock at **45-C02**.

Production runs the **`release`** branch; this investigation reads code from the local `release` checkout (HEAD `0d6f989`, no uncommitted drift on the implicated files) and validates against the live deployed schema/view.

---

## 2. Questions

1. Does the system treat **Pick-Pack (picking) locations as valid replenishment** — either as replenishment **sources**, or as **"replenishable" supply** in the monitor?
2. Why is the **order count** ("Parcels"/Qty Hold) in the Replenishment Monitor inaccurate / not reconciling?
3. Why is **BW23CPN** blocked ("Not enough stock on location") when the SKU report shows 11 on 10-B01, and why does replenishment not resolve it?
4. Are these defects in the **deployed production** code/schema (release branch), and are they currently firing?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| H1 | Replenishment **source selection** grabs stock from pick-pack locations | medium | `calculateOrder` filters source stock only by `area.useForReplenish` |
| H2 | The **Replenishment Monitor** miscounts pick-face stock as "replenishable" | medium | Monitor view classifies areas by name, not by flag |
| H3 | Order count ("Parcels") is inflated by a **join fan-out** and/or `count(co.*)` | medium | Monitor view LEFT-JOINs multi-row subqueries then groups |
| H4 | BW23CPN block is a **reservation/inventory** problem, not a replenishment-logic problem (i.e. "nothing wrong" with replenish code per se) | medium | 11/11 reserved on a pick face with no reserve stock would legitimately block both picking and replenish |
| H5 | Nothing is actually wrong — the monitor is correct and operators are misreading it | low | Possible, but the client's wording points at a concrete miscount |

---

## 4. Method

- **Code read (release branch):** `ReplenishGeneratorService.calculateOrder`, `StockunitRepository` source queries, `ReplenishmentMonitorViewRepository.getReplenishViewSummary`, `ReplenishmentMonitorView` entity, `ViewDtoService.getReplenishMonitorViewSummary`, `LocationArea` model.
- **Deployed-schema validation:** `pg_get_viewdef('replenishment_monitor_view')` to confirm the *running* view matches the Java query's logic.
- **Live data (read-only):** `location_area` flag/name config; BW23CPN & 25GNEAH750 stock by location/area; open replenish orders by source-area; PICK_PACK demand by section; fan-out multiplier check; reservation provenance for the BW23CPN stockunit.
- **Branch hygiene:** confirmed local checkout is `release` @ `0d6f989` with no uncommitted changes to the implicated files.

---

## 3.5 Sources In Scope

| Source | Location | Role |
|---|---|---|
| `ReplenishGeneratorService.calculateOrder` | `service/ReplenishGeneratorService.java:87-162` | Replenish order creation + source selection |
| `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` | `repo/jpa/StockunitRepository.java:101-116` | Source-stock query used by `calculateOrder` |
| `getReplenishViewSummary` | `repo/jpa/ReplenishmentMonitorViewRepository.java:20-121` | The query the Monitor UI actually calls |
| `ReplenishmentMonitorView` (entity + embedded view DDL) | `model/ReplenishmentMonitorView.java:12-99` | Legacy DB view definition |
| `getReplenishMonitorViewSummary` | `service/ViewDtoService.java:1148-1189` | Maps rows → DTOs (1 DTO per row, no dedup) |
| `LocationArea` | `model/LocationArea.java:31-37` | Area capability flags |
| Deployed view | `pg_get_viewdef('public.replenishment_monitor_view')` | Production source of truth |
| `location_area` rows | wms1-wineco | Actual WineCo area configuration |

---

## 5. Evidence

### 5.1 WineCo area configuration — one dual-purpose area exists but is unused

**Source:** `location_area` (live)

| id | name | picking | replenish | storage | deepstorage | #locations |
|---|---|---|---|---|---|---|
| 51551 | Storage and Replenish | false | **true** | true | false | **472** |
| 51552 | Storage Picking and Replenish (from) | **true** | **true** | true | false | **0** |
| 51553 | Storage and Picking | **true** | false | true | false | **2219** |
| 51557 | Deep Storage | false | false | false | false | — |
| 51554/51556/51550/51555 | Inbound / Outbound / Default / users | false | false | … | … | — |

**Observation:** The only area that is *both* picking and replenish (51552) currently has **0 locations**. Pure pick faces live in 51553 (`useforreplenish=false`); reserve stock lives in 51551 (`useforreplenish=true`).
**Supports:** H4 (no pick-pack source can currently fire). **Contradicts:** H1 (as a *currently-firing* source bug).

### 5.2 Replenishment source selection does not exclude pick-pack areas — latent, not currently firing

**Source:** `StockunitRepository.java:101-116`
```sql
... JOIN location_area area ON location.area_id = area.id
WHERE ... AND area.useForReplenish = true
  AND area.useForDeepStorage = :useForDeepStorage ...
```
**Observation:** The source query filters **only** on `useForReplenish = true`. It does **not** exclude `useforpicking = true`. If a location belonged to area 51552 (pick **and** replenish), its unreserved pick-face stock would be a valid replenishment **source** — i.e. robbing one pick face to fill another. However, 51552 has 0 locations (§5.1), and **all 621 open replenish orders currently source from "Storage and Replenish"** (pick=false):

| source area | picking | replenish | open replenish orders |
|---|---|---|---|
| Storage and Replenish | false | true | **621** |

**Supports:** H1 as a **latent** defect; **Contradicts** H1 as the current cause.
**Inference:** Worth hardening (add `AND area.useforpicking = false`, or gate on a "from" semantic), but it is **not** what WineCo is seeing today.

### 5.3 The Monitor counts pure pick-face stock as "replenishable" — CONFIRMED, currently firing

**Source:** deployed `replenishment_monitor_view` (verified via `pg_get_viewdef`) and `ReplenishmentMonitorViewRepository.java:96-103`:
```sql
on_replenishable_location = round(sum(CASE
  WHEN loc_area.name = ANY (ARRAY[
        'Storage and Replenish','Deep Storage',
        'Storage, Picking and Replenish (from)','Storage and Picking'])  -- ← pick-only area included
  THEN su.amount ELSE 0 END))
```
The "replenishable" bucket is classified by a **hardcoded area-name list** that includes **`'Storage and Picking'`** — a pick-only area (`useforpicking=true`, `useforreplenish=false`).

**Live validation:**

| SKU | `on_replenishable` as view computes | truly replenishable (by `useforreplenish` flag) | areas present |
|---|---|---|---|
| **BW23CPN** | **11** | **0** | Storage and Picking (repl=false) |
| **25GNEAH750** | **655** | **588** | Storage and Picking (repl=false, 67) + Storage and Replenish (repl=true, 588) |

**Observation:** For BW23CPN the monitor reports **11 bottles "on replenishable location"** when the true figure is **0** — the 11 sit on pick face 10-B01 (pick-only). For 25GNEAH750 the monitor over-reports replenishable supply by the 67 bottles on pick face 45-C02.
**Supports:** **H2 (confirmed).** This is the precise mechanism behind *"system still uses Pick Pack Locations as valid replenishment"* — the monitor presents pick-pack stock as replenishable supply.

**Secondary defect (latent):** the same list contains `'Storage, Picking and Replenish (from)'` (with comma) while the real area name is `'Storage Picking and Replenish (from)'` (no comma) — a name mismatch that would silently mis-bucket that area's stock. Harmless today (0 locations), but confirms the classification is fragile by-name rather than by-flag.

### 5.4 Order count: `count(co.*)` + uncontrolled fan-out — real defects, not firing on current data

**Source:** `ReplenishmentMonitorViewRepository.java:20-121`, mapped 1:1 to DTOs at `ViewDtoService.java:1148-1189`.

Two independent defects in the per-SKU **order_hold** ("Parcels"/Qty Hold) value:

1. **`order_hold = count(co.*)`** (line 56). This counts `customerorder_position` rows for the SKU, not distinct orders. If one order has ≥2 positions of the same SKU it is counted twice. Should be `count(DISTINCT co.id)`.
2. **Row fan-out.** The outer query LEFT-JOINs `t4` (open replenish orders, `state < 600`, multi-row per SKU) and `t5` (`fix_location_assignment → unitload → stockunit`, multi-row per SKU) and then `GROUP BY` includes `t4.ro_number` (and `ro_id`). A SKU with *N* open replenish orders × *M* fixed-assignment stockunits emits **N×M rows**, each repeating the same `bottles_needed`, `order_hold`, `prio_high`, `prio_urgent`. `ViewDtoService` emits **one DTO per row with no dedup**, so the Monitor shows the **same SKU on several lines with identical counts** → "doesn't reconcile."

**Live validation (current snapshot):**
- No SKU in PICK_PACK demand currently has `count(co.*) ≠ count(DISTINCT co.id)` (mechanism 1 not firing now).
- No demanded SKU currently has `open_replenish_orders × fix_assignment_stockunits > 1` (mechanism 2 not firing now).

**Observation:** Both are genuine code defects in the deployed query, but **neither reproduces on WineCo's data as of 2026-06-01**. They fire **intermittently** — whenever a demanded SKU has ≥2 open replenish orders, ≥2 FA stockunits, or an order carries ≥2 same-SKU positions (all transient conditions the client likely hit at report time, consistent with the Cristom screenshot — note Cristom currently has **no** open PICK_PACK demand).
**Supports:** H3 (mechanism confirmed; current firing not reproduced).

### 5.5 BW23CPN shipment blocker — leaked reservation on a pick face + no reserve stock

**Source:** live queries on BW23CPN / stockunit 985079706 / pickingorder_position.

- BW23CPN has exactly **one active stockunit**: **985079706 @ 10-B01**, area "Storage and Picking" (pick-only), **amount 11 / reserved 11 / available 0**. **No BW23CPN stock exists in any `useforreplenish` area** (no reserve, no deep storage).
- **Live demand** for BW23CPN is essentially one open order: **060554-000002** (order_state 50, position_state 55, **needs 2**, pickingdate 2026-06-01). Every other BW23CPN order is state **700 (finished)**.
- **Zero `pickingorder_position` rows reference stockunit 985079706** (no open *or* historical pick points at it) — yet 11 bottles are reserved on it.

**Observation:** The 11-bottle reservation is **orphaned** — there is no picking order consuming it, and live demand is only 2 bottles. Picking parcel `VN1779810411125`/BW23CPN fails with *"Not enough stock on location"* because **available = amount − reserved = 0**. Replenishment cannot help because `calculateOrder` finds **no stock in any replenishable area** for BW23CPN and throws *"No replenish stock available"* (`ReplenishGeneratorService.java:102-111`). Meanwhile the Monitor (§5.3) shows BW23CPN with **11 "on replenishable location,"** misleading the operator into expecting replenishment to fix it.
**Supports:** H4 (the block is a reservation/inventory state, not a replenish-logic miscalculation) **and** H2 (the monitor's misclassification is what set the wrong expectation).

**Portfolio note:** across all pick faces ("Storage and Picking"), **11 of 1,586** stockunits are fully reserved and **120** carry some reservation — orphaned reservations are not unique to this SKU but are not yet quantified as systemic here (see §9).

### 5.6 Deployed code == release code

**Source:** `git` + `pg_get_viewdef`.
**Observation:** Local checkout is `release` @ `0d6f989`, no uncommitted changes on the implicated files; the deployed `replenishment_monitor_view` DDL matches the Java query's classification logic. Findings reflect what is **running in production**.
**Supports:** Q4 — defects are in the deployed release.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H2 | Monitor counts pick-face stock as "replenishable" | **High (confirmed, firing)** | §5.3 — BW23CPN 11 vs 0; 25GNEAH750 655 vs 588; deployed view + repo query |
| H4 | BW23CPN block is reservation/inventory state, not replenish-logic | **High** | §5.5 — orphaned 11/11 reservation, no reserve stock, no pick order references SU |
| H3 | Order count inflated by `count(co.*)` + row fan-out | **Medium-high (mechanism confirmed; not firing now)** | §5.4 — defects present in deployed query; current snapshot does not reproduce |
| H1 | Replenish **source** grabs pick-pack stock | **Low now / Medium latent** | §5.1–5.2 — query lacks `useforpicking=false`, but area 51552 empty; all 621 ROs source from reserve |
| H5 | Nothing wrong; operator misreading | **Rejected** | §5.3 — the miscount is real and quantified |

---

## 7. Verdict

**The client's report is substantially correct, with one important reframing.**

1. **"System uses Pick-Pack locations as valid replenishment" — CONFIRMED, but in the Monitor's *reporting*, not in the replenish *engine*.** The Replenishment Monitor's `on_replenishable_location` column buckets stock by a hardcoded **area-name** list that wrongly includes the pick-only area **"Storage and Picking"**. It should classify by the `useforreplenish` **flag**. This makes pick-face stock (e.g. BW23CPN's 11 bottles on 10-B01) appear as replenishable supply when it is not. The replenish *engine* (`calculateOrder`) does **not** currently source from pick-pack locations — the only dual-purpose area (51552) has zero locations and all 621 open orders source from the proper "Storage and Replenish" reserve — but the source query is missing a `useforpicking = false` guard and is a **latent** risk worth closing.

2. **"Order count not accurate" — CONFIRMED as a code defect, not reproduced on today's data.** The Monitor query uses `count(co.*)` (should be `count(DISTINCT co.id)`) and, more importantly, fans each SKU into one row **per open replenish order × per fixed-assignment stockunit**, repeating the same Qty Req / Parcels / Priority on each line with no dedup in the DTO mapping. This intermittently shows duplicated/inflated SKU lines that "don't reconcile." It is not firing on the 2026-06-01 snapshot (and Cristom has no open demand right now), so the original screenshot reflects a transient state.

3. **The BW23CPN shipment block is an orphaned reservation, not a replenishment miscalculation.** Stockunit 985079706 holds 11/11 reserved with **no picking order referencing it** and only 2 bottles of live demand, and there is **no reserve stock anywhere** for BW23CPN — so picking shows "not enough stock" and replenishment legitimately cannot generate an order. The monitor's §5.3 misclassification is what made operators expect replenishment to fix it.

**Overall confidence:** **High** for the monitor classification defect (H2) and the BW23CPN diagnosis (H4); **Medium-high** for the order-count defects (H3, mechanism confirmed but not currently reproducible); the source-query gap (H1) is a confirmed **latent** defect.

---

## 8. Recommendation

**Mixed: one immediate operational recovery + Fix now (monitor) + Fix later (engine hardening & counts).**

- **(Operational, to get today's shipment out — NOT a code change):** Investigate and clear the **orphaned reservation on stockunit 985079706** (BW23CPN @ 10-B01) so its 11 physical bottles become pickable, or add/transfer BW23CPN reserve stock. This is the actual blocker for parcel `VN1779810411125`. *Read-only DB access here means this was diagnosed, not performed.*

- [x] **Fix now** — **Monitor area classification.** Replace the hardcoded area-**name** lists in `getReplenishViewSummary` (and the deployed `replenishment_monitor_view`) with the `location_area.useforreplenish` / `useforpicking` **flags**, so pick-only stock is never reported as replenishable. Draft via **`wms-bugfix-plan`** for v1. The downstream plan **must** ship `sbdocs/9-System/scripts/verify-<plan-id>.sh`.

- [x] **Fix later** — **Order-count accuracy.** Change `count(co.*)` → `count(DISTINCT co.id)` and eliminate the `t4`/`t5` row fan-out (aggregate replenish-order and fixed-assignment data per SKU, or dedup in `ViewDtoService`). Same `wms-bugfix-plan` or a follow-up; ship a verify script.

- [x] **Fix later** — **Source-query hardening.** Add `AND area.useforpicking = false` (or an explicit "replenish-from" semantic) to `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` so pick faces can never be chosen as replenishment sources even if a dual-purpose area is later populated.

- [ ] **Monitor** — orphaned-reservation prevalence on pick faces (120 stockunits carry reservations; 11 fully reserved). If this recurs, escalate to a reservation-leak investigation (see §9 and related archives).

Because §8 includes "Fix now"/"Fix later," each downstream `wms-bugfix-plan` is required to ship a `verify-<plan-id>.sh` acceptance script.

---

## 9. Open Questions

- **What created the orphaned 11-bottle reservation on stockunit 985079706?** No `pickingorder_position` references it. Likely a finished/cancelled pick or a `changeReservedAmount` that did not net to zero — relates to prior reservation-leak work ([[260424-Reservation_Leak_Analysis]], `260522-sbdev-2033-reserve-amount-adjust-not-sticking`). Needs a transaction-history trace, out of scope here.
- **How systemic are orphaned pick-face reservations?** 120 reserved / 11 fully-reserved stockunits in "Storage and Picking" — is this normal in-flight picking, or accumulated leak? Needs a reservation-vs-open-demand reconciliation across all SKUs.
- **What was the exact Cristom screenshot state?** Cristom has no open PICK_PACK demand as of 2026-06-01, so the original duplicate-row example could not be replayed. A captured copy of the screenshot's underlying rows would let us confirm the fan-out multiplier that day.
- **batch 46954-16 / OMS parcel 279233** did not resolve to a current WMS `customerorder.number` — confirm whether it was re-batched (now 060554) or is an OMS-side identifier.

---

## 10. References

- **Related workflows:** `sbdocs/3-Resources/workflows/wms1-replenish-order-creation.md`, `wms1-replenish-workflow.md`
- **Related reports:** `sbdocs/3-Resources/reports/260522-sbdev-2033-reserve-amount-adjust-not-sticking.md`; `sbdocs/4-Archieves/wms2/plan/Reservation_Leak_Analysis.md`
- **Code (release @ `0d6f989`):**
  - `v1/wms-api/src/main/java/net/aim_ai/wms/repo/jpa/ReplenishmentMonitorViewRepository.java:20-121`
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/ViewDtoService.java:1148-1189`
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java:87-162`
  - `v1/wms-api/src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java:101-116`
  - `v1/wms-api/src/main/java/net/aim_ai/wms/model/LocationArea.java:31-37`
- **Deployed schema:** `pg_get_viewdef('public.replenishment_monitor_view')` (verified 2026-06-01)
- **Preserved queries:** area config; BW23CPN & 25GNEAH750 stock-by-area; open-RO source areas; PICK_PACK demand by section; fan-out multiplier check; reservation provenance for SU 985079706 (all read-only, run against wms1-wineco 2026-06-01).

---

## 11. Verification Log

| Date | What was re-checked | Result | Checked by |
|------|---------------------|--------|------------|
| 2026-06-01 | Area config, monitor `on_replenishable` miscount (BW23CPN/25GNEAH750), open-RO source areas, fan-out multipliers, SU 985079706 reservation provenance, deployed view DDL, release branch hygiene | All findings confirmed against live wms1-wineco (read-only) | Nam Park |
