---
title: "SBDEV-2514 — WineCo post-release (v1.26.43) issues: Reserved-Out unit-load movement block + Replen Monitor QTY accuracy"
type: investigation
status: draft
version: v1
scope: "WMS v1 (wms-api) — pick-line move guard (SBDEV-2481) + replenishment_monitor_view accuracy (SBDEV-2384)"
owner: Nam Park
created: 2026-07-02
updated: 2026-07-02
last_verified: 2026-07-02
verified_by: Nam Park
related:
  - "SBDEV-2481-stale-pick-line-realignment-on-stock-move.md"
  - "SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md"
  - "260626-restore-replenishment-triggers-on-lock-state-changes.md"
  - "260630-sbdev-2501-replenishment-monitor-completed-replen-still-showing.md"
  - "../workflows/wms1-move-stock-unitload-workflow.md"
  - "../workflows/wms1-replenish-workflow.md"
tags:
  - investigation
  - report
  - replenishment
  - reservation
  - move-stock
  - regression
  - wms1
---

# SBDEV-2514 — WineCo post-release (v1.26.43) issues: Reserved-Out unit-load movement block + Replen Monitor QTY accuracy

**Topic:** WMS v1 (wms-api) — pick-line move guard (SBDEV-2481) + `replenishment_monitor_view` accuracy (SBDEV-2384) | **Version:** v1
**Started:** 2026-07-02 | **Investigator:** Nam Park
**Status:** open

> **Ticket:** [SBDEV-2514](https://app.clickup.com/t/868k7t74r) (ST#1028, Urgent) — "New Release WMS Issues: Reserved Out Unit Load Release and Replen Monitor Quantity Accuracy."
> **DB validation:** all queries run against the live `wms1-wineco` tenant DB on 2026-07-02.
> The ticket's own internal note anticipates a split into two child tickets after evidence review. This report supports that split.

---

## 1. Context & Trigger

WineCo reported two problems **after the `v1.26.43` production release** (tag dated 2026-06-26; prior baseline `v1.26.38`, 2026-06-15):

1. **Reserved-Out / unit-load movement.** Operator **Adam** uses **Move Stock** / **Move Unit Load** during replenishment work; reserved quantities appear to remain tied to unit loads in a way that prevents or complicates movement. The client wants a way to release the reserved-out amounts so the unit loads can move.
2. **Replen Monitor / parcel / QTY-needed accuracy.** Reported as affecting **Ackley Brands** and **Cristom** (Cristom Vineyards) "today."

Screenshots and a Stock Unit Record for Adam were promised but not yet attached at time of writing. This report establishes the mechanism and the suspect commits from code + DB, and scopes what evidence is still needed.

Commits new in `v1.26.43` (since `v1.26.38`), replenishment/movement-relevant:

| Commit | Ticket | Change |
|--------|--------|--------|
| `7c47a2b` | **SBDEV-2481** | New guard: realign/block stale pick lines on stock & unit-load moves |
| `f3c0cae` + view migration | **SBDEV-2384** | Reclassify replenishable/available stock by `useforreplenish` flag; add `ro_id` to `replenishment_monitor_view` |
| `d3f5ce1` | **SBDEV-2033** | Restore 3 lock-state replenishment recalc triggers |
| `e0ff548` | SBDEV-2492 | Sync replen-order source location on unit-load move |
| `b39b44d` / `c46688e` | SBDEV-2488 / — | Relocation moved-amount + stock-unit history |

---

## 2. Questions

1. Is the "reserved-out won't release / can't move the unit load" symptom caused by a `v1.26.43` change, and if so which one?
2. Does the new move guard incorrectly block moves for stock tied to **completed** (not active) picking work?
3. Is the "Replen Monitor / QTY-needed inaccuracy" for Ackley Brands and Cristom a regression, a data-state artifact, or expected (by-design) behavior?
4. What evidence is still required from the client to confirm each verdict?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| H1 | SBDEV-2481's new move guard blocks Move Stock/Move Unit Load because its `isActive` threshold is an open-ended `state >= STARTED(500)`, which also catches FINISHED(700)/CANCELED(800) orders carrying stale pick lines | **high (mechanism)** | New code shipped this release; threshold is `>=`; WineCo has 271k terminal orders |
| H2 | SBDEV-2384's replenishable-stock reclassification changed `available_amount`, so QTY-needed numbers shifted → perceived "inaccuracy" | medium | Deployed view uses new flag-based classification; the ticket's own example moved 655→588 |
| H3 | **Nothing is actually wrong** with the missing Ackley/Cristom rows — they are absent by the view's design filters (no open pick_pack demand / intracompany-only demand) | medium-high | View requires `cob.type='PICK_PACK'` and open `cop.state<200` demand |
| H4 | SBDEV-2033 restored recalc triggers shifting reserved/available inputs into the monitor | low-medium | Feeds `available_amount`/`reservedamount`; same release |
| H5 | "parcel data" refers to a different view (Parcel/Outbound-Parcel monitor), conflated by the client | low | `replenishment_monitor_view` has no parcel column |

---

## 4. Method

- **Code read** (release-equivalent working tree; SBDEV-2481 merged to `develop` → `release`): `PickLineRealignmentService`, `PickLineActivityCodeClassifier`, `WmsConstants.State`, `StockunitService`, `MobileMoveUnitloadService`.
- **Git**: release tag dates + commit set `v1.26.38..v1.26.43`.
- **DB queries** (`wms1-wineco`, 2026-07-02): `replenishment_monitor_view` definition + columns; `pickingorder.state` distribution; pick lines on orders `state>=500`; open demand for Ackley/Cristom by batch type; `replenishorder` schema.
- **Prior reports**: SBDEV-2481 plan, SBDEV-2384 plan, SBDEV-2033 plan, SBDEV-2501 report (replen-monitor semantics).

---

## 3.5 Sources In Scope

| Source | Role |
|--------|------|
| `service/PickLineRealignmentService.java:70-94` | `isActive` threshold + block sites (Cluster 1) |
| `service/PickLineActivityCodeClassifier.java:41-47` | `BLOCK_REALIGN_CODES` = {MANUAL_TRANSFER, TRANSFER, ON_HOLD} |
| `service/WmsConstants.java:44-109` | State ladder (PROCESSABLE 300 … FINISHED 700, CANCELED 800) |
| `service/StockunitService.java:188` | Web Move Stock whole-UL relocation → `CODE_MANUAL_TRANSFER` |
| `service/mobile/MobileMoveUnitloadService.java:252` | Move Unit Load → `CODE_TRANSFER` |
| `replenishment_monitor_view` (DB) | Cluster 2 demand/availability computation |
| `repo/jpa/ReplenishmentMonitorViewRepository.java` | SBDEV-2384 inline query counterpart |
| SBDEV-2481 / SBDEV-2384 / SBDEV-2033 plans; SBDEV-2501 report | Prior analysis, coordinate/supersede |

---

## 5. Evidence

### 5.1 The deployed release contains a brand-new move guard (SBDEV-2481)

**Source:** `git log v1.26.38..v1.26.43`; `service/PickLineRealignmentService.java:46-47`
**Observation:** `v1.26.43` introduces `PickLineRealignmentService`, which throws on blocked moves:
```
"This stock is currently tied to active picking work. Please wait till picking is complete before moving this stock…"  (ACTIVE_PICK_MESSAGE)
```
**Supports:** H1.

### 5.2 Adam's two actions route into the BLOCK_REALIGN bucket

**Source:** `PickLineActivityCodeClassifier.java:41-47`; `MobileMoveUnitloadService.java:252`; `StockunitService.java:188`
**Observation:** `BLOCK_REALIGN_CODES = {CODE_MANUAL_TRANSFER, CODE_TRANSFER, CODE_ON_HOLD}`. **Move Unit Load** (mobile) calls `transferUnitLoadToLocation(..., CODE_TRANSFER, ...)`; **Move Stock** (web) whole-unit-load relocation calls `transferUnitLoadToLocation(..., CODE_MANUAL_TRANSFER, ...)`. Both land in BLOCK_REALIGN → the guard runs. (Web stock **split** uses `CODE_MANUAL_SPLIT` = PASS_THROUGH, so splits are *not* blocked.)
**Supports:** H1 — the guard fires on exactly the actions the client named.

### 5.3 The `isActive` threshold is an open-ended `>=` that sweeps in terminal states

**Source:** `PickLineRealignmentService.java:70-74`; `WmsConstants.java:44-109`
**Observation:**
```java
// isActive():
owningOrder.get().getState() >= WmsConstants.State.STARTED;   // STARTED = 500
```
State ladder: `PROCESSABLE 300 · RESERVED 400 · STARTED 500 · PICKED 600 · PACKED 650 · PALLETIZED 670 · FINISHED 700 · CANCELED 800`. Because the comparison is `>= 500` with **no upper bound**, a pick line whose owning order is **FINISHED (700)** or **CANCELED (800)** is treated as "active picking work" and blocks the move.
**Supports:** H1. **Inference:** a stale/dangling pick line on a completed or canceled order — precisely the artifact SBDEV-2481 was written to clean up (and whose §7.3 backfill was *deferred / DBA-gated*) — becomes a **permanent false move-blocker**.

### 5.4 WineCo carries a large terminal-order pool, and stale pick lines exist on it

**Source:** `wms1-wineco` DB, 2026-07-02
**Observation:** `pickingorder.state` distribution:

| state | meaning | orders |
|-------|---------|--------|
| 300 | PROCESSABLE | 2 |
| 600 | PICKED | 3 |
| **700** | **FINISHED** | **65,412** |
| **800** | **CANCELED** | **206,413** |

Pick lines currently on an order with `state >= 500`: **3 lines, all on FINISHED order `PICK234816`** (finished **2025-08-13**), SKUs `24PGR` / `22PNR` / `24ROSE`. Two of the three backing stock units are emptied at location **Nirwana** (`amount=0`). These are textbook stale pick lines on a long-finished order — and each would block a move of its stock unit under the `>=500` rule.
**Supports:** H1 (mechanism + real terminal-order pool). 

### 5.5 …but the *current* live blast radius is small (null-ish result — tempering)

**Source:** `wms1-wineco` DB, 2026-07-02
**Observation:** Restricting to terminal orders (600/700/800) with backing stock still present: `stale_pick_lines = 3`, `with_stock_amount > 0 = 0`, `movable_real_stock = 0`. So **right now** no stale pick line on a terminal order points at a unit load that holds real, movable stock.
**Contradicts (partially):** the claim that Adam is *currently* blocked by these specific rows. **Inference:** Adam's block was most likely transient (during genuinely active STARTED/PICKED orders) or on a specific UL not in the current snapshot. The threshold defect is real regardless, but confirming *Adam's exact* block needs his UL/SKU. This is why the ticket flags screenshots pending.

### 5.6 `replenishment_monitor_view` is demand-driven, gated on PICK_PACK + shortage

**Source:** `pg_get_viewdef('replenishment_monitor_view')`, 2026-07-02
**Observation:** the driving demand subquery (`t1`) filters:
```sql
WHERE cop.state < 200 AND co.pickingdate <= CURRENT_DATE AND cob.type = 'PICK_PACK'
```
and the whole view keeps a row only when `HAVING (bottles_needed - available_amount) > 0`, where `available_amount` counts unreserved stock on `useforpicking = true AND useforreplenish = false` locations with all `entity_lock = 0`. `ro_id` **is present** in the view → SBDEV-2384's view migration is deployed.
**Supports:** H2, H3.

### 5.7 Both named brands are absent by design filter, not by corruption

**Source:** `wms1-wineco` DB, 2026-07-02
**Observation:**
- `client`: **Ackley Brands** = id `700112951`; **Cristom Vineyards** = id `80000`.
- `replenishment_monitor_view` rows for either brand: **0**. (Other clients do appear — Bluebird Hill Cellars 6, Lange Winery 1, Shea Wine Cellars 1.)
- Open demand (`cop.state < 200`) for the two brands, by batch type:
  - **Ackley Brands:** *no open positions at all* → correctly absent.
  - **Cristom Vineyards:** **8 open positions / 174 bottles, due today**, but batch type **`TRANSFER_INTRACOMPANY`** — excluded by the view's `cob.type = 'PICK_PACK'` filter.

**Supports:** H3 strongly. **Inference:** the "monitor shows nothing for Ackley/Cristom" observation is explained by the view's design filters. Whether that is *wrong* depends on client expectation (should intracompany-transfer demand drive replenishment?).

### 5.8 SBDEV-2384 deliberately changed the availability/replenishable classification

**Source:** `SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md` §0–§1
**Observation:** SBDEV-2384 changed `on_replenishable_location` / availability from an **area-name** list to the `useforreplenish` **flag**, in both the inline repository query and the deployed view (new migration). Its worked example: a SKU's `on_replenishable_location` corrected from **655 → 588**.
**Supports:** H2. **Inference:** QTY-needed / replenishable numbers legitimately *changed* with this release; clients comparing against pre-release memory will see different values and may report them as "inaccurate."

### 5.9 Prior report already established the monitor's persistence semantics

**Source:** `260630-sbdev-2501-replenishment-monitor-completed-replen-still-showing.md` §3 (H2, high confidence)
**Observation:** the monitor is **demand-driven**, not `replenishorder`-driven (`replenishorder` is only a LEFT JOIN); a row persists while open demand exceeds pickable stock. "Completed replen still showing" is often genuine persistent demand, not a bug.
**Supports:** H3 — reinforces that "monitor looks wrong" complaints frequently reflect real demand semantics rather than corruption.

### 5.10 "Parcel data" is not part of this view

**Source:** view columns (2026-07-02): `client_*, sku_*, bottles_needed, order_hold, prio_*, fix_assignment_location_name, bottles_on_location, bottles_reserved_on_location, on_(non_)replenishable_location, ro_*`
**Observation:** there is no parcel column. Parcel/QTY concerns belong to the Parcel / Outbound-Parcel monitor (`ParcelMonitorView`), a separate surface (SBDEV-2099 / SBDEV-2507 territory).
**Supports:** H5 — likely a conflated concern needing clarification.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H1 | SBDEV-2481 `>=500` threshold false-blocks moves on stale pick lines of FINISHED/CANCELED orders | **High on mechanism; Medium that it is Adam's exact block** | 5.1–5.5: new guard, correct routing, open-ended threshold, 271k terminal orders; but current live blast radius = 3 empty lines |
| H2 | SBDEV-2384 reclassification shifted QTY-needed numbers → perceived inaccuracy | **Medium** | 5.6, 5.8: deployed flag-based classification, intentional numeric change |
| H3 | Ackley/Cristom empty rows are by-design filter behavior ("nothing wrong") | **Medium-high** | 5.7: Ackley no demand; Cristom is TRANSFER_INTRACOMPANY, excluded by PICK_PACK filter |
| H4 | SBDEV-2033 recalc triggers as secondary contributor | **Low-medium** | 5.6 inputs; no direct WineCo evidence yet |
| H5 | "parcel data" is a different view, conflated | **Low-medium** | 5.10 |

---

## 7. Verdict

**These are two independent issues and must be triaged separately.**

**Cluster 1 (Reserved-Out / movement blocked) — a real code defect.** `v1.26.43` shipped a new move guard (SBDEV-2481) that fires on exactly Move Stock and Move Unit Load, and its `isActive` test uses an **open-ended `state >= STARTED(500)`**. Because FINISHED(700) and CANCELED(800) sit above the threshold, any stale/dangling pick line on a completed or canceled order will **falsely block** the move with the "tied to active picking work" message — matching the client's "reserved won't release, can't move the unit load" description. The mechanism is confirmed in code and the terminal-order pool is large (271k). What is *not* yet confirmed is that this is the specific block Adam hit: the current DB snapshot shows only 3 such stale lines, all with emptied stock — so his block was likely on transient active orders or on a UL not in the snapshot. **Confidence: high on the defect, medium that it is the reported instance — pending Adam's UL/SKU/error text.**

**Cluster 2 (Replen Monitor / QTY accuracy) — most likely by-design shift + design-filter absence, not corruption.** SBDEV-2384 deliberately changed the replenishable/available classification this release, so QTY-needed values legitimately moved. For the two named brands, the monitor is empty **by the view's own filters**: Ackley has no open pick_pack demand, and Cristom's open demand (8 positions / 174 bottles due today) is `TRANSFER_INTRACOMPANY`, which the `cob.type='PICK_PACK'` filter excludes. Nothing in the DB indicates state corruption for these two. The likeliest real complaint is "the numbers changed" and/or an expectation that intracompany-transfer demand should drive replenishment. **Confidence: medium — direction of the discrepancy must be confirmed with the client before calling it a regression.**

**Overall confidence:** Medium-high.

---

## 8. Recommendation

Split SBDEV-2514 into two child tickets (per the ticket's internal note):

- [x] **Cluster 1 — Fix now.** Draft a fix plan via **`wms-bugfix-plan`** (v1/wms-api). Likely direction: bound `isActive` to genuinely-active states (e.g. `STARTED(500) ≤ state < FINISHED(700)`, excluding FINISHED/CANCELED), **and** run the deferred SBDEV-2481 §7.3 stale-line backfill on WineCo prod so dangling terminal-order lines stop blocking. Needs architect review of the exact upper bound (PACKED/PALLETIZED handling). **The downstream plan MUST ship `sbdocs/9-System/scripts/verify-<plan-id>.sh`.** Gate before plan finalization on Adam's exact UL/SKU/error text (then query that stock unit's referencing pick lines + owning order states to prove the instance).
- [x] **Cluster 2 — Investigate further.** Do **not** open a fix plan yet. Confirm with the client whether rows are *missing* or *numbers are wrong*, and whether `TRANSFER_INTRACOMPANY` demand is expected to drive replenishment. DB evidence currently says both brands are empty *by design*. If the client confirms numbers-wrong on a SKU that *does* appear, capture that SKU and re-open as a targeted bugfix.

---

## 9. Open Questions

- **Adam's exact block:** which UL / SKU / source+destination, and the exact on-screen error? Needed to bind H1 to the reported instance. (Screenshots pending per ticket.)
- **Terminal-order backfill state on WineCo prod:** was the SBDEV-2481 §7.3 backfill ever run here? If not, how many stale pick lines sit on FINISHED/CANCELED orders over time (snapshot today = 3, all empty; needs monitoring, not a one-shot).
- **Cluster 2 direction:** is the client seeing missing rows or wrong numbers? For which SKUs?
- **Intracompany transfers:** should `TRANSFER_INTRACOMPANY` demand appear on the Replen Monitor for WineCo, or is PICK_PACK-only correct?
- **"Parcel data":** does the client mean the Parcel / Outbound-Parcel monitor (`ParcelMonitorView`), not `replenishment_monitor_view`? (H5.)

---

## 10. References

- **Related plans:** `sbdocs/1-Projects/wms1/plan/SBDEV-2481-stale-pick-line-realignment-on-stock-move.md`; `.../SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md`; `.../260626-restore-replenishment-triggers-on-lock-state-changes.md`
- **Related reports:** `sbdocs/3-Resources/reports/260630-sbdev-2501-replenishment-monitor-completed-replen-still-showing.md`
- **Workflows:** `sbdocs/3-Resources/workflows/wms1-move-stock-unitload-workflow.md`; `.../wms1-replenish-workflow.md`
- **Commits / PRs:** `7c47a2b` (SBDEV-2481, PR #176), `f3c0cae` + view migration (SBDEV-2384), `d3f5ce1` (SBDEV-2033, PR #185); release tag `v1.26.43`
- **Tickets:** [SBDEV-2514](https://app.clickup.com/t/868k7t74r) (parent); children to be created (see §8)
- **Logs / queries (preserved):** state distribution; pick lines on `state>=500` (order `PICK234816`); Ackley/Cristom open-demand-by-batch-type; view definition — all `wms1-wineco`, 2026-07-02

---

## 11. Verification Log

| Date | What was re-checked | Result | Checked by |
|------|---------------------|--------|------------|
| 2026-07-02 | Initial investigation; code + `wms1-wineco` DB | Cluster 1 defect confirmed (mechanism); Cluster 2 empty-by-design | Nam Park |
