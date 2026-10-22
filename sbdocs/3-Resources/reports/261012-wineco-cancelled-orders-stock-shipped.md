---
title: "WineCo PRD — Cancelled Orders Whose Picked Stock Shipped"
type: investigation
status: concluded
version: "v2"
scope: "WineCo PRD (wsl-wineco-prd): orders 062524-000005 and 062245-000003, cancelled after picking; their tote stock later shipped while the reversal rows stayed pending"
owner: "Nam Park"
created: "2026-10-12"
updated: "2026-10-12"
last_verified: "2026-10-12"
verified_by: "Claude (read-only queries on wsl-wineco-prd and c1wh-shipitez-prd; git on wms2-api origin/develop 60ddb320, c7e0b023, fa7f34f4; tracer lane on the cancel path)"
ticket: "SBDEV-3740, SBDEV-3741"
ticket_url: "https://app.clickup.com/t/868mgddxb, https://app.clickup.com/t/868mgde8k"
related:
  - "ClickUp SBDEV-3733 (triage surfaced this): https://app.clickup.com/t/868mg9b3k"
  - "ClickUp SBDEV-3547 (fence against hand moves), SBDEV-3381 (Waive), SBDEV-3313 (RTS roadmap)"
  - "sbdocs/3-Resources/reports/261012-c1wh-pending-reversals-waive.md"
  - "Shareable copy (Claude Docs): https://claude.ai/code/artifact/d6d9ce35-deaa-429a-aae6-0a93764cd6b9"
tags:
  - investigation
  - report
  - rts
  - cancellation
  - wineco
---

# WineCo PRD — Cancelled Orders Whose Picked Stock Shipped

**Topic:** cancelled-order stock reuse and the SBDEV-3547 fence gap | **Version:** v2
**Started:** 2026-10-12 | **Investigator:** Nam Park (Claude) | **Status:** concluded

> **Bottom line.** Nobody was mis-shipped and inventory is consistent. OMS cancelled two picked club orders and re-created each within about a minute; one re-create landed 39 s *before* its cancel. A supervisor reused the 18 picked bottles by hand-moving them from Clearing into club staging lanes. Club packing shipped them: 13 to the re-created orders, 4 to another customer who had ordered the same SKUs, and 1 is still in the lane. What is broken:
> - **(a)** 11 cancellation-reversal rows can never be closed by Return to Stock (RTS).
> - **(b)** The hand move was only possible because the SBDEV-3547 fence was **held out of the 2026-10-02 production release**. Both cancels ran on the old code, which unlocked the stock.
> - **(c)** 14 WineCo reversal rows still hold stock that was left unlocked the same way, and are exposed today. One of them is on 062524-000005; the other 13 are on three other orders.
> - **(d)** The workflow the operators were improvising has no supported path in WMS.

---

## 1. Context & Trigger

Triage of SBDEV-3733 censused pending cancellation reversals across the four v2 PRD tenant DBs. WineCo had 37 pending and 0 ever completed. 10 of those rows pointed at stock units at lock 405 (SHIPPED), on two orders that WMS shows as CANCELED (state 800). Nam asked for the true state, how it happened, and how to prevent it.

## 2. Questions

1. What is the true state of the two cancelled orders and their picked stock?
2. How did stock picked for a cancelled order end up shipped?
3. Why did the SBDEV-3547 fence, which exists to stop hand moves of cancelled stock, not stop it?
4. Is anything else exposed the same way right now?
5. What prevents a recurrence?

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|---|---|---|
| H1 | Legitimate reuse: the stock went to orders that wanted it; only the reversal bookkeeping is stale | medium | Same SKUs, WineCo club operations |
| H2 | Mis-ship: cancelled stock went to the wrong customer | low | Would require packing to ignore the order's lines |
| H3 | The fence was live but has a hole on this path | medium | The fence's code was on develop and assumed shipped |
| H4 | The fence was not in the PRD build at cancel time | low | Ancestry check said it was (later shown wrong, §5.5) |

## 4. Method

- Read-only SQL on `wsl-wineco-prd`:
  - `customerorder_cancellation_log`, `customerorder`, `customerorder_position`
  - `stockunit` (`entity_lock`, `version`, `modified`), `unitload`
  - `stockrecord` (stock moves), `unitload_record` (tote moves)
  - `flyway_schema_history` (deploy times)
- The same census on `c1wh-shipitez-prd`, `nywh-shipitez-prd` and `nywh-hydra-prd`.
- Git on `v2/wms2-api` after a fresh fetch:
  - `origin/develop` 60ddb320
  - prod promotes `c7e0b023` (v2.0.149, 2026-10-02), `fa7f34f4` (v2.0.150, 2026-10-08) and `0dfb0d4d` (v2.0.151)
- One independent `tracer` lane, which read the cancel path at `c7e0b023` (§5.5).

### 3.5 Sources in scope

- `CustomerorderService.cancelOrder`: direct branch, tote teardown.
- `CancelLockRelease.releaseUnlessGoodsOut`: SBDEV-3547 B-1, present on develop only.
- `StockunitService.transferStock` → `StockunitBusinessService.transferStockToUnitLoad(ignoreLock=false)`: the Move Stock refusal of lock 100.
- `CancellationReversalService.completeReversal` / `waiveReversal`.
- Prior report: `261012-c1wh-pending-reversals-waive.md`, the same hand-move class on ShipItEZ, pre-fence.

## 5. Evidence

### 5.1 Both cancelled orders were re-created by OMS within about a minute

**Source:** `customerorder` on wsl-wineco-prd.

| Cancelled order | Client order | Cancelled (UTC) | Re-created as | Created (UTC) | Re-created state |
|---|---|---|---|---|---|
| 062524-000005 (35841887) | 282262 | 2026-10-02 20:00:05 | 062549-000001 (35851639) | 2026-10-02 20:01:10 | 700 |
| 062245-000003 (35157490) | 254-22278:6204 | 2026-10-06 19:57:38 | 062625-000001 (35989683), `254-22278:6204-RO` | 2026-10-06 19:56:59 | 700 |

The re-created orders carry the same SKUs and quantities; 062549-000001 also has a tote bag. **Supports H1.**

### 5.2 The cancel unlocked the tote stock, inside its own transaction

**Source:** `stockunit.version` / `modified` versus `customerorder_cancellation_log.created_at`.

- Order 062524-000003 (35841873, cancelled 2026-10-02 19:51:38 UTC): all 11 pick-to units are at `entity_lock = 0`, `version = 2`.
- Their `modified` is **0.09–0.23 s after** the log row.
- No `stockrecord` touches them afterwards; they still sit at Clearing.
- So the cancel transaction itself wrote lock 0.
- `confirmPick` stamps 100 unconditionally (`PickingorderBusinessService` `pickToStock.setEntityLock(PICKED_FOR_GOODSOUT)`). On 2026-10-12, every tote unit at FinishedPicking is at 100 (168 units on 36 totes, none at 0).

**Contradicts** "the fence was live and held" (H3 as stated).

### 5.3 What the operators did: hand move into club staging lanes, then club packing

**Source:** `stockrecord`, `unitload_record`.

**Tote T-0038** (062245-000003):
- Picked 2026-09-21 22:11–22:17 by estellavasquez.
- Sat at FinishedPicking for 15 days.
- Cancel moved it to Clearing on 2026-10-06 19:57.
- 2026-10-09 01:05:22–01:05:49: mcervone moved the 4 units Clearing → **StagingLane20** with `MANUAL_SPLIT`.
- 01:06:05: `PACKAGING_CLUB` CLUB-20261006-001 packed all 4 into parcel **SY1791316604259**, the re-created `-RO` order.

**Tote T-0042** (062524-000005):
- Picked 2026-10-02 16:34–16:41. The cancel moved it to Clearing at 20:00:05.
- 2026-10-09 01:09:20–01:10:17: mcervone moved the 7 units Clearing → **StagingLane05** (`MANUAL_SPLIT`).
- 01:10:28: CLUB-20261002-002 packed 2 units (BW25PNROSE, BW24SMPN) into **HV1790971245877**, the re-created order. It also drew 5 more bottles from three of these units, recorded as `STOCK_REMOVED` (BW24JPN −3, BW24CPN −1, BW24ESPN −1).
- 2026-10-10 15:49:11: CLUB-20261008-004 moved 4 units (BW24JPN, BW24CPN, BW24PNCR, BW24WVPN) into **OJ1790960893525**. That parcel belongs to **062687-000001** (client order 288239, a different customer), whose lines include all four SKUs.
- 1 unit of BW24ESPN (stock unit 35844423) remains at StagingLane05, lock 0.

Both parcels are on pallets PM-017380, -017381 and -017394, at location Shipped, lock 405. **Supports H1; refutes H2.**

### 5.4 Why the hand move succeeded

**Source:** code at `origin/develop`, traced by the tracer lane.

Move Stock's new-container arm calls `transferStockToUnitLoad(..., ignoreLock=false)`. That refuses any non-zero source lock (`StockunitBusinessService` "Source stockUnit=… is locked=…"). The moves in §5.3 worked only because §5.2 had already set the lock to 0. The fence was in the build that ran the moves (v2.0.150, from 2026-10-08), but it acts only **at the moment of cancel**. It does not re-lock stock that an earlier build already cleared.

### 5.5 The fence was not in the 2026-10-02 production build (decisive)

**Source:** git on wms2-api, plus `flyway_schema_history` on wsl-wineco-prd.

- SBDEV-3547 PR-B (#431, 09306eed) merged to develop on 2026-09-28 22:53 UTC.
- **a3380070, 2026-10-02 13:07 UTC: "Hold SBDEV-3547 PR-B from production: revert #431 on release"** reached main as v2.0.149 (`c7e0b023`).
  - `git grep -l releaseUnlessGoodsOut c7e0b023` returns **0 files**.
  - On `origin/develop` it returns 4: 3 main sources plus `CancelLockReleaseUnitTest` (positive control).
  - In that build the cancel teardown is `toteStock.forEach(su -> su.setEntityLock(NOT_LOCKED))`.
- 61d5c2a6, 2026-10-07: "Bring SBDEV-3547 PR-B back … revert a3380070 on release". It shipped in v2.0.150 (`fa7f34f4`), and `git grep` finds the fence in the same 4 files there.
- WineCo deploys, from Flyway `installed_on` (UTC; about 15 min after each main merge, on both releases):

  | Deploy (UTC) | Version | Commit |
  |---|---|---|
  | 2026-10-02 13:33 | 2.2.35 | v2.0.149, `c7e0b023` |
  | 2026-10-08 08:06 | 2.2.37 | v2.0.150, `fa7f34f4` |

- **Window without the fence on PRD: 2026-10-02 13:33 → 2026-10-08 08:06 UTC.** Both cancels (10-02 20:00 and 10-06 19:57) fall inside it. **Confirms H4.**

⚠ An ancestry check (`git merge-base --is-ancestor 09306eed c7e0b023`) **passes** and first led to the opposite conclusion. A revert on the release branch hides a merged fix from ancestry. Grep for the fix's code at the deployed commit instead.

### 5.6 What is still exposed

**Source:** census across all four PRD tenant DBs, `reversal_required AND reversal_completed_at IS NULL`.

- **WineCo — 37 pending reversal rows:**

  | Count | State | What it needs |
  |---|---|---|
  | 13 | Drained by hand moves (lock 2, Nirwana), 2026-09-28 to 10-01, before the fence. All went back to their own source bins (§5.7) | Waive, `stockReturned=true` |
  | 10 | Shipped (§5.3) | Waive with `stockReturned=false`; `waiveReversal` refuses `stockReturned=true` for SHIPPED stock |
  | **14** | **Still holding stock at lock 0** | See below |

  The 14 still-exposed rows:
  - 11 at Clearing (062524-000003)
  - 1 at StagingLane05 (062524-000005, log id 28; the one unit from §5.3 still in the lane)
  - 2 moved Clearing → PutAwayLane by danielvalentim on **2026-10-10 16:51**, after the fence was live. This is live proof that this stock is still movable.

- **c1wh-shipitez:** 5 pending, all drained; see the c1wh report.
- **nywh-shipitez:** 0 rows.
- **nywh-hydra:** 0 pending.

### 5.7 Follow-up (same day): every WineCo row can be closed on the floor, with no data fix

**Source:** code at `origin/develop` (re-fetched); `wsl-wineco-prd` re-queried 2026-10-12 after filing SBDEV-3740.

**RTS accepts lock 0.**
- `CancellationReversalService.completeReversal` pre-validate refuses a source lock only when it is "not `NOT_LOCKED` and not `PICKED_FOR_GOODSOUT`".
- The movement loop then calls `transferStock(stockUnit, amountPicked, …, pickfromlocationname, …)` from wherever the unit sits.
- The whole call is one transaction with every check up front, so a refused order writes nothing.
- So the 14 lock-0 rows need no re-lock to be closed. Re-locking would only block movement; each row still ends in RTS or Waive.
- SBDEV-3740's lock-100 option was dropped on 2026-10-12 (Nam), and the ticket re-scoped to a T0 floor action.

**Mobile lookup.** `scanTote` finds pending rows by `tote_label_id` and opens the first row's order. Every pending tote maps to exactly one order (11 totes, 11 orders), so scanning reaches the right order.

**Per-order outcome:**

| Tote / order | Rows | Evidence | Closes with |
|---|---|---|---|
| T-0085 / 062524-000003 | 11 | All at Clearing, lock 0, unit amount = `amount_picked`, `reservedamount` 0, source flowbin's assigned SKU = unit SKU | RTS |
| T-0107 / 062524-000004, T-0006 / 062524-000006 | 1 each | fall26clubgiftbag at PutAwayLane since a MANUAL_SPLIT by danielvalentim on 10-10 16:51; source 11-A12 matches | RTS (or Waive, returned = yes, if put away meanwhile) |
| T-0042 / 062524-000005 | 7 | 6 shipped (405), and row 28 holds 1 of its 2 bottles. Pre-validate refuses SHIPPED, so RTS refuses the whole order | Waive, returned = no |
| T-0038 / 062245-000003 | 4 | All shipped | Waive, returned = no |
| T-0062, T-0087, T-0165, T-0078, T-0207, T-0025 (6 orders) | 13 | Each unit's `MANUAL_SPLIT` out of Clearing is paired, within 2 s and for the same SKU, with a `STOCK_CREATED` in that row's own `pickfromlocationname`. All 13 went back to source; by adriantorres, 2026-09-28 23:57 to 10-01 16:24 | Waive, returned = yes |

Totals: 13 RTS + 13 Waive (returned) + 11 Waive (not returned) = 37. The supervisor checklist is on SBDEV-3740.

Caveat on the "returned" pairing: it matches on time, SKU and destination bin, not on a shared id. `stockrecord` carries no move id linking the decrement to the create. All 13 pairs matched exactly one record.

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|---|---|---|
| H1 | Legitimate reuse; bookkeeping stale | **high** | §5.1, §5.3: every shipped unit matches a line on the receiving order |
| H2 | Mis-ship | **refuted** | §5.3 |
| H3 | Fence live but holed on this path | **refuted** for these orders | §5.5: fence absent from the build that ran the cancels |
| H4 | Fence not deployed at cancel time | **high** | §5.2 + §5.5: version bump inside the cancel txn; `git grep` at `c7e0b023` empty; Flyway dates |

## 7. Verdict (confidence: high)

1. **True state.**
   - Both original orders are CANCELED (800). OMS re-created both, and the re-creations shipped (700).
   - Of the 18 picked bottles (11 stock units), 13 shipped to the re-created orders, 4 shipped to another club customer who ordered them, and 1 is still in StagingLane05. Club packing drew 5 of the 13 by `STOCK_REMOVED` from units whose remainder went to the other customer, so by unit the split is 6 / 4 / 1.
   - Inventory is consistent.
   - All 11 reversal rows are pending and cannot be completed by RTS.
2. **How it happened.**
   - The SBDEV-3547 fence was held out of the 2026-10-02 release, so cancels between 10-02 13:33 and 10-08 08:06 UTC unlocked the tote stock.
   - A supervisor then reused that stock for the re-created club orders by hand-moving it into club staging lanes (2026-10-09 ~01:05 UTC).
   - Club packing draws from the lane by SKU, which is why 4 units went to a different customer.
3. **Exposure today.** 14 WineCo reversal rows still hold movable stock at lock 0, and 2 were moved on 10-10. All 37 WineCo pending rows can be closed on the floor today (§5.7): 13 by RTS and 24 by Waive.
4. **What this is not.** It is not a defect in the fence. It is a deploy gap plus a missing workflow.

## 8. Recommendation: Fix later (SBDEV-3741), plus a floor action now (SBDEV-3740)

| # | Action | Owner / ticket | Tier |
|---|---|---|---|
| 1–2 | **Close all 37 WineCo rows on the floor:** RTS for T-0085, T-0107 and T-0006; Waive with returned = yes for the 13 drained; Waive with returned = no for T-0038 and T-0042. No re-lock: RTS accepts lock 0 (§5.7). The lock-100 data fix was dropped 2026-10-12 | WineCo supervisor, using the checklist on [SBDEV-3740](https://app.clickup.com/t/868mgddxb) (in development). Dev re-runs the census to close it | T0 |
| 3 | **Support the workflow the operators improvised.** Let RTS return cancelled stock to a chosen location (club staging lane) and close the reversal; optionally offer the tote to OMS's re-created order | [SBDEV-3741](https://app.clickup.com/t/868mgde8k) | T3 (feature) |
| 4 | **Know what is deployed.** For "is fix X on PRD", grep the fix's code at the deployed commit, not merge ancestry. Release holds are done by reverts on the release branch | Process note; no ticket. SBDEV-3547's ClickUp status already tracked this correctly ("on prod" from about 10-08) | — |
| 5 | **Optional detector.** A daily query for pending reversal rows whose stock has amount > 0 and a lock other than 100/405/2. It would have flagged 062524-000003 on 10-02 | Not filed; propose if wanted | T1 |

**Effect on SBDEV-3733:**
- Its Part B (fall back to putaway when the source bin refuses) has zero measured PRD demand.
- SBDEV-3741 is the destination flexibility that is actually being used on the floor.
- Decide 3733 with 3741 in view.

Any plan drafted from SBDEV-3741 goes through `wms-feature-plan` / `wms-bugfix-plan` at T3. That includes their verify-script rules.

## 9. Open Questions

- **OMS side:** not checked; there is no OMS DB access from this investigation. What did OMS record for the two cancels and their re-creates? Did it receive any reversal signal?
- **Why OMS cancels and re-creates:** is this WineCo's "edit order" behaviour? If so, how often? It determines the size of SBDEV-3741.
- **Who decided to hold PR-B on 10-02, and why?** Any other merged ticket held the same way would have the same exposure window.
- **The running build was not confirmed** through `/actuator/info`. Deploy times come from Flyway `installed_on` matched to the max migration version per commit. That is consistent on two releases, but it is one instrument.

## 10. References

- Tickets:
  - [SBDEV-3740](https://app.clickup.com/t/868mgddxb) (close the 37 WineCo rows on the floor; re-scoped from re-protect)
  - [SBDEV-3741](https://app.clickup.com/t/868mgde8k) (RTS to a chosen location)
  - [SBDEV-3733](https://app.clickup.com/t/868mg9b3k) (triage comment)
  - SBDEV-3547, SBDEV-3381, SBDEV-3313
- Commits:
  - wms2-api a3380070 (hold), 61d5c2a6 (restore), 09306eed (PR-B)
  - Prod promotes c7e0b023 / fa7f34f4 / 0dfb0d4d
- Prior report: `sbdocs/3-Resources/reports/261012-c1wh-pending-reversals-waive.md`
- Tracer lane output: session scratchpad `trace-cancel-lock.md` (not retained)
