---
title: "SBDEV-2501 — Replenishment completed but still showing on Replenishment Monitor (WineCo / ST#1021)"
type: investigation
status: concluded
version: "v1 (wms-api)"
scope: "WMS v1 Replenishment Monitor — replenishment_monitor_view demand vs. pickable-availability semantics"
owner: "Nam Park"
created: 2026-06-30
updated: 2026-06-30
last_verified: 2026-06-30
verified_by: "wms1-wineco DB MCP (live UAT/prod data)"
related:
  - "../workflows/wms1-replenish-workflow.md"
  - "../architecture/wms1-state-machine-catalog.md"
tags:
  - investigation
  - report
  - wms1
  - replenishment
  - data-state
---

# SBDEV-2501 — Replenishment completed but still showing on Replenishment Monitor (WineCo / ST#1021)

**Topic:** WMS v1 Replenishment Monitor — `replenishment_monitor_view` semantics | **Version:** v1 (wms-api)
**Started:** 2026-06-30 | **Investigator:** Nam Park
**Status:** concluded

---

## 1. Context & Trigger

Support ticket **ST#1021** (Adam Petersen / WineCo) → **SBDEV-2501**. Client reports:

> "I have completed the following replen but it isn't showing that it is completed on the monitor therefore not allowing it be picked."

Affected example: SKU **24WV** (2024 Willamette Valley Pinot Noir 750 ml), shipper **Broadley Vineyards / BRV**, monitor row Repl From **52-YB04** → Repl To **52-A01**, Qty Req **12**, Zone_H. Location report shows 52-A01 holding **29** with **24 reserved**.

The ticket is triaged as "Bug / Data-State Accuracy in WMS Replenishment / Movement." This report determines whether the monitor / replenishment state is actually corrupt, or whether the monitor is reflecting genuine demand.

---

## 2. Questions

1. Is the replenishment the client completed actually closed in the backend, or is it stuck in an intermediate state?
2. Why does a replenishment row for 24WV → 52-A01 still appear on the Replenishment Monitor after a replen was completed?
3. Is the 52-A01 inventory/reservation state correct, or is there a stale/leaked reservation suppressing availability?
4. Why can the SKU "not be picked"?
5. Is this a software defect, or correct-but-confusing behavior — and how is it resolved?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| H1 | The completed replenishorder failed to transition to a terminal state (stuck STARTED/PROCESSABLE) and so still drives the monitor row | medium | Classic "completion didn't take" symptom |
| H2 | The monitor is **demand-driven**, not replenishorder-driven; the row persists because open demand still exceeds *pickable* (unreserved) stock — completing one replen doesn't clear it | high | View `HAVING bottles_needed − available_amount > 0`; `replenishorder` is only a LEFT JOIN |
| H3 | A **stale/leaked reservation** at 52-A01 suppresses available stock (24 reserved of 29), creating a phantom shortfall | medium | Reserved 24 looks high vs. one visible order of 12 |
| H4 | **Demand double-counting** — a customer-order line already allocated to a picking order is also counted as open demand (`cop.state < 200`), inflating the shortfall | medium | Would produce a self-perpetuating monitor row |
| H5 | Nothing is wrong — genuine shortfall; the monitor and replenishment subsystem are functioning as designed | medium | Must be tested explicitly |

---

## 4. Method

- **Code read** — `replenishment_monitor_view` definition (Flyway migrations `V1.26.29` and `V1.26.30`), `MobileReplenishService` (finish/start/cancel state transitions), `wms1-replenish-workflow.md`.
- **Live DB queries** via `wms1-wineco` MCP (read-only). Reconstructed every component of the view (`t1` demand, `t2` pickable availability, `t4` replenishorder) for item 24WV/BRV and reconciled against the rendered monitor row.
- **Reservation tracing** — mapped `stockunit.reservedamount` at 52-A01 to the picking positions that hold it; confirmed reservation integrity.
- **State-distribution sweep** — global `replenishorder.state` histogram to interpret what state 800 means in this deployment.

DB instance is at migration **V1.26.29** (monitor view has no `ro_id` column; the `V1.26.30` ro_id addition is not yet applied here).

---

## 3.5 Sources In Scope

| Source | Role in investigation |
|---|---|
| `src/main/resources/db/migration/V1.26.29__replenishment_monitor_view_flag_based_classification.sql` | Live monitor view definition on this DB |
| `src/main/resources/db/migration/V1.26.30__replenishment_monitor_view_add_ro_id.sql` | Next view revision (not yet applied here) |
| `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java:419,476` | `finishReplenishmentOrder` sets state FINISHED (700) |
| `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:57-88` | Recalc cancel-and-regenerate pipeline |
| `sbdocs/3-Resources/workflows/wms1-replenish-workflow.md` | Workflow narrative |
| `wms1-wineco` live tables: `replenishorder`, `replenishment_monitor_view`, `stockunit`, `unitload`, `location`, `location_area`, `pickingorder(_position)`, `customerorder(_position/_batch)` | Primary evidence |

---

## 5. Evidence

### 5.1 The monitor is demand-driven, not replenishorder-driven

**Source:** `V1.26.29__…sql` (view body)
**Observation:** The driving sub-select `t1` computes `bottles_needed` from **open customer-order positions** (`cop.state < 200 AND co.pickingDate <= current_date AND cob.type = 'PICK_PACK'`). Row visibility is gated by:

```sql
HAVING t1.bottles_needed - t2.available_amount > 0
```

The `replenishorder` (`t4`) is a **LEFT JOIN filtered `ro.state < 600`** — it only supplies the display columns (Repl From / Qty Req / RO number). It does **not** control whether a row appears. Therefore completing or closing a replenishorder cannot, by itself, remove a monitor row.
**Supports:** H2 · **Contradicts:** H1

### 5.2 The replen the client "completed" is closed; the monitor row points at a *different*, newer replen

**Source:** `replenishorder` rows for item 22647829 (24WV/BRV)
**Observation:**

| RO number | id | qty | state | created | modified | operator_id |
|---|---|---|---|---|---|---|
| **REPL059389** (ticket's qty-12 row) | 31661207 | 12 | **800 (CANCELED)** | 2026-04-03 | 2026-04-06 07:56:30 | **NULL** |
| **REPL059408** (current monitor row) | 31713015 | 7 | **300 (PROCESSABLE)** | 2026-04-06 07:57:04 | NULL |

The qty-12 replen the client references is **closed** (state 800, ≥600 → filtered out of the view). The row now on the monitor is **REPL059408**, a *different* order auto-generated **34 seconds later**. To the operator it looks identical (same SKU, same 52-YB04→52-A01), so it reads as "my completed replen is still here."
**Supports:** H2 · **Contradicts:** H1

### 5.3 The arithmetic of the monitor row reconciles exactly

**Source:** Reconstructed view components for item 22647829
**Observation:**
- `t1.bottles_needed` (raw open demand, `cop.state<200`) = **12** (`order_hold = 1`)
- `t2.available_amount` (pickable = unreserved stock on `useforpicking=TRUE AND useforreplenish=FALSE` locations) = **5**
- Displayed `bottles_needed` = 12 − 5 = **7** ✓ (matches the live monitor row, which now reads 7)
- `HAVING 7 > 0` → row stays. The recalc job keeps an open replen (REPL059408, qty **7**) alive to cover exactly this shortfall.

Every rendered field matches the underlying tables. The monitor is **not stale** — it reflects a current 7-bottle shortfall.
**Supports:** H2, H5 · **Contradicts:** H1

### 5.4 52-A01 is correctly flagged; only its **unreserved** portion counts as pickable

**Source:** `location_area` for 52-A01 / 52-YB04; `stockunit` at 52-A01
**Observation:**
- 52-A01 → area "Storage and Picking": `useforpicking=TRUE`, `useforreplenish=FALSE` → its stock **does** count toward pickable availability.
- 52-YB04 → area "Storage and Replenish": `useforpicking=FALSE`, `useforreplenish=TRUE` → a valid replen **source**.
- Stockunit 23101824 @ 52-A01: amount **29**, reserved **24** → only **5** unreserved → that 5 is the entire `t2.available_amount`.

The pick face is *physically* near-full (29) but *pickably* almost empty (5) because most of it is committed to active picks.
**Supports:** H2, H5 · **Contradicts:** H3 (flag misconfig)

### 5.5 The 24 reservation is live and legitimate — no leak

**Source:** `pickingorder_position` where `pickfromstockunit_id = 23101824`
**Observation:** Two positions of **PICK272728** (state 300) pick from this stockunit:

| Position | qty | state | cop_id |
|---|---|---|---|
| 927709 | 12 | 300 | 33768996 |
| 927710 | 12 | 300 | 33769835 |

12 + 12 = **24**, exactly the `reservedamount`. Both belong to one active picking order created today. The reservation maps 1:1 to live, unpicked work — **not a leak**.
**Supports:** H5 · **Contradicts:** H3

### 5.6 No demand double-counting — three distinct order lines

**Source:** `customerorder_position` for item 22647829, picking date 2026-06-30
**Observation:**

| Order | cop_id | qty | cop.state | Disposition |
|---|---|---|---|---|
| 061108-000001 | 33768996 | 12 | 200 (assigned) | allocated → PICK272728 (reserves 12 @ 52-A01) |
| 061113-000001 | 33769835 | 12 | 200 (assigned) | allocated → PICK272728 (reserves 12 @ 52-A01) |
| 061113-000002 | 33769837 | 12 | **55 (raw, <200)** | **unallocated → the monitor's demand of 12** |

The monitor's demand line (cop 33769837) is a **third, distinct order**, not one of the two already reserved. No double-counting. Total real demand = 36; pick face = 29; 24 reserved; 5 free; the third order is 7 short → REPL059408 (qty 7).
**Supports:** H5 · **Contradicts:** H4

### 5.7 State 800 here means "auto-canceled by recalc," not "operator-finished"

**Source:** global `replenishorder.state` histogram; `MobileReplenishService.finishReplenishmentOrder` (`:476`)
**Observation:** `setState(WmsConstants.State.FINISHED)` (700) is the operator-completion terminal state. Global distribution: **300 → 621, 700 → 554, 800 → 59,885.** Operator completions land at 700 and do exist (554). The overwhelming 800 bucket is the `ReplenishOrderJob` cancel-and-regenerate pipeline (`ReplenishOrderJob.java:57-88`): each cycle it cancels open orders and regenerates them with recomputed quantities.

REPL059389 is **state 800 with `operator_id = NULL`** → it was **auto-canceled and never started/finished by any operator**. The qty change 12→7 between REPL059389 and REPL059408 (34 s apart) is the recalc reducing the requested amount, not a partial pick.

**Inference (not fact):** the specific order the client believes they "completed" was auto-canceled by the recalc cycle before/instead of being executed; for this item, recent replens were all auto-canceled (no 700 in the last 20), i.e. **no operator has actually executed a replen to 52-A01 recently** — the orders churn open→canceled→regenerated without anyone running them.
**Supports:** H2, H5

### 5.8 The fix source has stock; the open replen is executable

**Source:** per-location aggregate for item 22647829
**Observation:** 52-YB04 holds **36** (7 reserved → **29 free**). REPL059408 needs only **7**. The outstanding replen is fully fulfillable — executing it raises 52-A01 free stock to ~12, enough to allocate and pick the pending order 061113-000002.
**Supports:** H5

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H2 | Monitor is demand-driven; row persists because demand > pickable stock | **high (confirmed)** | §5.1, §5.2, §5.3 |
| H5 | Nothing is corrupt — genuine shortfall, working as designed | **high (confirmed)** | §5.3–§5.8 |
| H1 | Completed replen stuck in intermediate state | **rejected** | §5.2 (closed, state 800) |
| H3 | Stale/leaked reservation / flag misconfig | **rejected** | §5.4, §5.5 (reservation = live picks) |
| H4 | Demand double-counting | **rejected** | §5.6 (three distinct cops) |

---

## 7. Verdict

**This is correct, by-design behavior — not a data-state defect.** The Replenishment Monitor is a **demand-vs-pickable-availability** view, not a list of open replenishment orders. A row for 24WV → 52-A01 appears whenever *open demand* exceeds the *unreserved* stock at the pick face, and it is gated solely by `HAVING bottles_needed − available_amount > 0`. Completing or closing any single replenishorder does not clear the row.

For 24WV right now there is a **genuine 7-bottle shortfall**: pick face 52-A01 holds 29 bottles, but 24 are reserved by a live picking order (PICK272728, two lines of 12), leaving only 5 pickable, while a third, still-unallocated order needs 12. The replen the client points to (REPL059389, qty 12) is correctly closed; the row they see is a *new* auto-generated replen (REPL059408, qty 7). The SKU "can't be picked" because the unallocated order is short until that outstanding replen is **executed** — and the evidence (state 800 + `operator_id = NULL`, no recent 700 for this item) indicates the open replens have been churning through the recalc cycle **without an operator actually running one**.

Reservation integrity, location flags, and demand counting all check out. No inventory or state corruption was found.

**Confidence:** high

---

## 8. Recommendation

- [x] **Do NOT fix (code)** — the backend is behaving correctly; there is no data corruption, stuck state, or leaked reservation. The monitor row is a true, current shortfall.
- [x] **Operational resolution** — **execute the outstanding replen REPL059408** (52-YB04 → 52-A01, qty 7; source has 29 free). That raises 52-A01 pickable stock enough to release/pick order 061113-000002, after which the monitor row clears once `demand ≤ free stock`. Communicate to WineCo that the monitor reflects *net pickable demand*, not "did my last replen save" — completing one replen will not remove the row while orders reserve the pick face faster than it is topped up, and each cycle shows a **new** RO number for the same SKU/lane.
- [ ] **Investigate further (separate, lower-priority ticket)** — two product/UX concerns surfaced that are *not* SBDEV-2501 bugs but are the root of the recurring confusion:
  1. **Monitor UX** — a closed replen being replaced by a new same-looking row (different RO number) reads as "my completion didn't take." The monitor could surface the open RO's state ("replen in progress / processable") or distinguish "needs new replen" from "replen already queued."
  2. **Recalc churn / race window** — 59,885 canceled vs. 554 finished. The cancel-and-regenerate cycle (`ReplenishOrderJob`) can cancel a PROCESSABLE order beneath an operator who is mid-task, so completions don't always land (and for 24WV, recent replens never reached state 700). Worth a focused investigation into whether operators are losing in-progress replens to the recalc cycle.

No downstream `wms-bugfix-plan` is warranted for SBDEV-2501 itself (recommendation is Do-Not-Fix). If concern (2) is taken up, that follow-up plan must ship a `sbdocs/9-System/scripts/verify-<plan-id>.sh`.

---

## 9. Open Questions

- **Did the client ever actually execute a replen to 52-A01, or only believe they did?** Evidence shows no recent state-700 finish for this item (`operator_id` NULL on the canceled orders). A mobile-side log/trace for the operator's session would confirm whether a finish call was attempted and failed, vs. never made.
- **Is the recalc cancel-and-regenerate cadence racing operators out of in-progress orders?** Needs the cron interval for `ReplenishOrderJob` on WineCo and a sample of canceled orders that had `operator_id` set / state ≥ STARTED at cancel time. (For 24WV the canceled orders had no operator, so no race was observed *here* — but the global 800 count warrants a look.)
- **Snapshot drift:** the ticket screenshots show qty 12; the live row is qty 7. Confirm with the client which moment they captured, in case demand has since partially cleared.

---

## 10. References

- **Ticket:** SBDEV-2501 (ClickUp `868k6xc0q`) / Support ST#1021 — WineCo, Adam Petersen
- **Code:** `V1.26.29__replenishment_monitor_view_flag_based_classification.sql`, `V1.26.30__replenishment_monitor_view_add_ro_id.sql`, `MobileReplenishService.java:419,476`, `ReplenishOrderJob.java:57-88`
- **Docs:** `sbdocs/3-Resources/workflows/wms1-replenish-workflow.md`, `sbdocs/3-Resources/architecture/wms1-state-machine-catalog.md`
- **Logs / queries (preserved):** live `wms1-wineco` queries for item 22647829 — replenishorder history, monitor-view row, `t1`/`t2` reconstruction, stockunit @ 52-A01, PICK272728 positions, three-cop demand breakdown, state histogram.

---

## 11. Verification Log

| Date | What was re-checked | Result | Checked by |
|------|---------------------|--------|------------|
| 2026-06-30 | Full reconstruction of monitor row for 24WV against live tables | Row arithmetic reconciles (12 − 5 = 7); no corruption | wms1-wineco DB MCP |

---

## Appendix A — How the v1 replen process identifies the SKU (ruled-out finding)

**Why this was checked:** `item_nr` is **not unique** — `24WV` exists for two clients: Broadley Vineyards/BRV (`itemdata.id = 22647829`) and Ayres Vineyard/AYV (`itemdata.id = 30914326`). Confirmed on live data that `item_nr` alone duplicates (2 rows / 2 clients) while `(client_id, item_nr)` is unique. So the question was whether the replenishment pipeline could conflate the two `24WV` items.

**Finding:** The authoritative key everywhere that moves stock or drives the monitor is the surrogate PK **`itemdata.id`**. Operator-entered input is resolved via the natural key **`(client_id + item_nr)`** and then pinned to that id. Only one display-only helper matches on `item_nr` alone, and it is client-scoped for normal users.

| Stage | Identifier used | Evidence |
|---|---|---|
| Replen generation / recalc (`calculateOrder`, `refillFixedLocations`) | **`itemdata.id`** — from `fix_location_assignment.itemdata_id`; replenishorder stores `itemdata_id` + `client_id` (client derived from the item) | `ReplenishGeneratorService.java:65,88,142-143` |
| Source-stock selection | **`itemdata.id`** — `WHERE su.itemdata_id = :itemDataId` | `StockunitRepository.java:110` |
| Mobile operator request (`requestReplenish`) | **`(client_id + item_nr)`** → `findByClientIdAndItemNr` | `MobileReplenishService.java:575` |
| `checkDestination` (flow-bin assign) | **`(client_id + item_nr)`** → `findByClientIdAndItemNr` | `MobileReplenishService.java:345` |
| `checkSource` (scan / pick-any switch) | **`itemdata.id`** → `stockUnit_new.getItemdataId().equals(replenishOrder.getItemdataId())` | `MobileReplenishService.java:289` |
| `checkSource` (exact match) | unit-load label / location; item already pinned by loaded replenishorder | `MobileReplenishService.java:232,241` |
| `setAmountDestination` (display helper) | **`item_nr` string only** — but stock list is pre-filtered by `callerClient.getId()` for non-system users | `MobileReplenishService.java:694-705` |

**Conclusion:** Item identity is **not** a contributing factor to SBDEV-2501. The two `24WV` items are distinct PKs; the Broadley replen, REPL059408, the monitor row, and the 52-A01 reservations are all correctly bound to `22647829`. The only theoretical `item_nr`-only conflation is cosmetic (a **system-client** operator viewing a destination that physically holds the same `item_nr` from two clients) and affects a displayed "amount at destination" figure, not the actual move or reservation. Worth a low-priority hardening note but unrelated to this ticket.
