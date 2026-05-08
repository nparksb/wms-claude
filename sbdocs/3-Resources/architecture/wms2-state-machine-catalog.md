---
title: "WMS v2 — State Machine Catalog"
type: architecture
status: active
version: v2
scope: state-machines
owner: Nam Park
created: 2026-04-19
updated: 2026-05-08
last_verified: 2026-05-08
verified_by: code read of v2/wms2-api src/main at commit HEAD
related:
  - ./wms2-transaction-osiv-boundary-map.md
  - ../workflows/wms2-replenish-workflow.md
  - ../workflows/wms2-replenish-order-creation.md
  - ../../1-Projects/wms2/plan/260320-Auto_Release_Club_Transfer_Lane_Fix.md
  - ../../1-Projects/wms2/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md
  - ../../4-Archieves/wms2/plan/260424-Cancel_Club_Parcels_Packed_State_Fix.md
  - ../../4-Archieves/wms2/plan/260424-Cancel_Order_Null_SectionId_And_Early_Return_Fix.md
  - ../../4-Archieves/wms2/plan/260424-RunClubLine_Cancelled_Order_Fix_Plan.md
  - ../../4-Archieves/wms2/plan/260424-oms-palletized-loaded-to-truck-notifications-plan.md
  - ../../4-Archieves/wms2/plan/260424-club-location-replenish-fix.md
tags:
  - architecture
  - state-machine
  - order-lifecycle
  - wms2
---

# WMS v2 — State Machine Catalog

**Scope:** Lifecycle states and transition sites in `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-05-08 (code read against `src/main/java`)

---

## 1. Overview

`wms2-api` has **no Spring StateMachine and no custom state-machine framework** — every entity's lifecycle is a plain Integer or String field on the entity, mutated by `setState(...)` calls scattered across ~160 write sites in ~30 services. Transition legality is enforced only by ad-hoc guards (`if (order.getState() == X)`) at each call site, so the same guard is typically repeated 3–6 times, and drift between copies is the root cause of half the "stuck state" / "cancel in wrong state" bugs in the archive.

This doc is the authoritative map: every entity with a lifecycle field, every state value it can take, where transitions are written, and which guards protect each transition. Use it to avoid adding the N+1 copy of an existing guard.

---

## 2. The Two Type Systems

### 2.1 Integer states — `WmsConstants.State.*`

Defined at `net/aim_ai/wms/service/WmsConstants.java:14-179`. Numeric values are **ordered** — the code uses `>=` / `<` comparisons as a monotonic-progress check (e.g. "position must have progressed past `RESERVED`"), which makes the numeric spacing a hidden contract. **Do not renumber constants**; add new states in gaps.

| Constant | Value | Meaning |
|---|---|---|
| `RAW` | 0 | Initial / unprocessed |
| `CLIENT_HAS_NO_SECTION` | 45 | Blocked — tenant has no section configured |
| `RAW_ON_HOLD` | 50 | Temp hold during allocation |
| `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` | 55 | Hold sub-reason |
| `RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION` | 56 | Hold sub-reason |
| `RAW_ON_HOLD_PROBLEM_WITH_FIXED_ASSIGNED_LOCATION` | 57 | Hold sub-reason |
| `RAW_ON_HOLD_FIX_ASSIGNMENT_IS_INACTIVE` | 58 | Hold sub-reason |
| `FUTURE_PICKING_DATE` | 80 | Future-dated, not yet releasable |
| `ASSIGNED` | 200 | Position assigned to a picking order |
| `PROCESSABLE` | 300 | Released; ready to pick |
| `RESERVED` | 400 | Operator has claimed it |
| `STARTED` | 500 | Picking in progress |
| `CUSTOMER_ORDER_ACTIVATED` | 505 | Transfer flow — order activated |
| `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` | 510 | Transfer flow — lane set |
| `ORDER_BATCH_ACTIVATED` | 520 | Batch flow — activated |
| `ORDER_BATCH_STAGING_LANE_ASSIGNED` | 525 | Batch flow — lane set |
| `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` | 527 | Club run running |
| `ORDER_BATCH_CLUB_RUN_FINISHED` | 530 | Club run done |
| `PENDING` | 550 | Mid-flow wait |
| `PICKED` | 600 | Picking complete, awaiting pack |
| `PACKED` | 650 | Pack complete |
| `PALLETIZED` | 670 | Palletized |
| `LOADED_TO_TRUCK` | 680 | Loaded |
| `FINISHED` | 700 | Terminal success |
| `CANCELED` | 800 | Terminal cancel (valid from any non-terminal) |

### 2.2 String states — LANDMINE

Three separate constant classes, all in `WmsConstants`:

| Constant class | Used by | Values |
|---|---|---|
| `WmsConstants.AdviceState` | `Advice`, `Adviceposition` | `CREATED`, `OPEN`, `PROCESSING`, `CLOSED`, `FINISHED`, `CANCELLED` |
| `WmsConstants.BillOfLadingState` | `Billoflading`, `BillofladingPosition` | `CREATED`, `OPEN`, `TRUCK_LOADING`, `TRANSFER`, `CLOSED`, `CANCELLED` |
| `WmsConstants.CycleCountState` | `Cyclecount`, `CyclecountPosition` | `CREATED`, `STARTED`, `FINISHED`, `CANCELLED` |

> **Note the spelling: `CANCELLED` (two L's) for String states, `CANCELED` (one L) for the Integer state.** This inconsistency is a bug-magnet — a typo in either direction silently falls through every guard because `.equals("CANCELED")` on an advice will always return false.

String states are stored as plain `String` columns (no enum, no DB-level constraint). Nothing prevents a typo from being persisted.

---

## 3. The Integer State DAG

Not every state transitions to every other. The numeric values encode this DAG:

```
                                    ┌─────────────────────────────┐
                                    ▼                             │
              RAW(0) ──► FUTURE_PICKING_DATE(80)                  │
                │                                                 │
                │        RAW_ON_HOLD(50) ──┬─► 55/56/57/58        │  release
                │          ▲               │                      │  job
                ▼          └───────────────┘                      │
            CLIENT_HAS_NO_SECTION(45) ◄──── stuck                 │
                │                                                 │
                ▼                                                 │
            ASSIGNED(200) ──► PROCESSABLE(300) ──► RESERVED(400) ─┤
                                     │                            │
                                     ▼                            │
                              STARTED(500) ──► PICKED(600)        │
                                                   │              │
                                                   ▼              │
                                              PACKED(650)         │
                                                   │              │
                                                   ▼              │
                                            PALLETIZED(670)       │
                                                   │              │
                                                   ▼              │
                                        LOADED_TO_TRUCK(680)      │
                                                   │              │
                                                   ▼              │
                                              FINISHED(700)       │
                                                                  │
  Transfer flow:  CUSTOMER_ORDER_ACTIVATED(505) ──►               │
                  CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED(510)      │
                                                                  │
  Batch flow:     ORDER_BATCH_ACTIVATED(520) ──►                  │
                  ORDER_BATCH_STAGING_LANE_ASSIGNED(525) ──►      │
                  ORDER_BATCH_CLUB_RUN_IN_PROGRESS(527) ──►       │
                  ORDER_BATCH_CLUB_RUN_FINISHED(530)              │
                                                                  │
  Wait:           PENDING(550) ───────────────────────────────────┘

  Terminal:       CANCELED(800)  ← reachable from any non-terminal state
```

Common numeric-order guards you'll see in code:
- `state >= WmsConstants.State.RESERVED` — "has been claimed or beyond"
- `state >= WmsConstants.State.PICKED && state != WmsConstants.State.CANCELED` — "in post-pick phase"
- `state < WmsConstants.State.RESERVED` — "not yet claimed"

---

## 4. Per-Entity Catalog

### 4.1 `Customerorder` — Integer state (the big one)

| | |
|---|---|
| **Entity** | `model/Customerorder.java:20` |
| **Field** | `state` (Integer, `@NotNull`, default `RAW`) |
| **States reachable** | `RAW`, `FUTURE_PICKING_DATE`, `ASSIGNED`, `PROCESSABLE`, `RESERVED`, `STARTED`, `CUSTOMER_ORDER_ACTIVATED`, `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`, `PENDING`, `PICKED`, `PACKED`, `PALLETIZED`, `LOADED_TO_TRUCK`, `FINISHED`, `CANCELED` |
| **Write sites** | 30+ — primary in `CustomerorderService`, `PickingorderBusinessService`, `ParcelMonitorViewService`, `BillofladingService`, `TransferOrderService`, `ReleaseOrderJobService`, mobile services |
| **Cascade on cancel** | Yes — see §5.1 |

**Key write sites:**

| Location | Transition |
|---|---|
| `service/CustomerorderService.java:239-244` (`createForRelease`) | → `RAW` / `FUTURE_PICKING_DATE` |
| `service/job/ReleaseOrderJobService.java:643,647` (`releaseOrderAndPosition`) | → `ASSIGNED` / `STARTED` |
| `service/TransferOrderService.java:96,110,124,132` | → `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` / `CUSTOMER_ORDER_ACTIVATED`; line 110 is `unlinkTransferLaneFromTransferOrder` (Group T port v1 5ada0b0 / v2 24280b0): when a transfer lane is unlinked, state is reset to `CUSTOMER_ORDER_ACTIVATED` (not left in `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`) |
| `service/PickingorderBusinessService.java:238,241,343,502` | → `PENDING` / `PICKED` / `CANCELED` / `STARTED` |
| `service/CustomerorderService.java:485` (`pack`) | → `PACKED` |
| `service/ParcelMonitorViewService.java:156,283` (`palletizeOrders`) | → `PALLETIZED` |
| `service/mobile/MobilePalletizingService.java:220` (`palletizeOrder`) | → `PALLETIZED` |
| `service/ParcelMonitorViewService.java:401` (`loadTruck`) | → `LOADED_TO_TRUCK` |
| `service/mobile/MobileTruckLoadingService.java:304` (`finishLoadingTruck`) | → `LOADED_TO_TRUCK` |
| `service/BillofladingService.java:481` (`finishOrdersOnBol`) | → `FINISHED` |
| `service/CustomerorderService.java:351` (`forceCancelOrder` Customerorder write) / `:675` (`cancelOrder` Customerorder write) | → `CANCELED` |
| `controller/rest/UtilRestController.java:960` (admin reset) | → `RAW` |

**Key guards:**
- `OrderRestController:180` — "can cancel iff `!= FINISHED && != CANCELED`"
- `CustomerorderService:471` — "pack only if `!= PICKED`" (actually guard inversion — watch direction carefully)
- `CustomerorderService:382,554` — "already packed/palletized check" (used to early-return cancel, see `Cancel_Club_Parcels_Packed_State_Fix`)
- `CustomerorderService:639` — "rapid-pick path iff `== ASSIGNED && historytote != null`"

### 4.2 `CustomerorderBatch` — Integer state

| | |
|---|---|
| **Entity** | `model/CustomerorderBatch.java:22` |
| **States reachable** | `RAW`, `STARTED`, `ORDER_BATCH_ACTIVATED`, `ORDER_BATCH_STAGING_LANE_ASSIGNED`, `ORDER_BATCH_CLUB_RUN_IN_PROGRESS`, `ORDER_BATCH_CLUB_RUN_FINISHED`, `FINISHED`, `CANCELED` |
| **Write sites** | 15+ in `CustomerorderBatchService`, `BillofladingService`, `OrderRestController` |

**Key transitions:**

| Location | Transition |
|---|---|
| `service/CustomerorderBatchService.java:427` (`activateBatch`) | → `ORDER_BATCH_ACTIVATED` |
| `service/CustomerorderBatchService.java:434` (`assignStagingLane`) | → `ORDER_BATCH_STAGING_LANE_ASSIGNED` |
| `service/CustomerorderBatchService.java:565` (`startClubRun`) | → `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` |
| `service/CustomerorderBatchService.java:639` (`finishClubRun`) | → `ORDER_BATCH_CLUB_RUN_FINISHED` |
| `service/CustomerorderBatchService.java:661` (error recovery) | → `originalState` (rollback from club run) |
| `service/CustomerorderBatchService.java:279,339` (`cancelBatch`) | → `CANCELED` |
| `service/CustomerorderBatchService.java:358` (`finalizeBatchIfComplete`) | → `CANCELED` or `FINISHED` depending on child orders |

**Guard:** `CustomerorderBatchService:557` — club run start requires `ORDER_BATCH_ACTIVATED` OR `ORDER_BATCH_STAGING_LANE_ASSIGNED`.

### 4.3 `Pickingorder` — Integer state

| | |
|---|---|
| **Entity** | `model/Pickingorder.java:23` |
| **States reachable** | `RAW`, `PROCESSABLE`, `RESERVED`, `STARTED`, `PICKED`, `FINISHED`, `CANCELED` |
| **Write sites** | 20+ — primary in `PickingorderBusinessService`, `MobilePickingService`, `CustomerorderService`, `PickingOrderMergeService`, `ReleaseOrderJobService` |

**Key transitions:**

| Location | Transition |
|---|---|
| `service/job/ReleaseOrderJobService.java:557` (`releaseOrderAndPosition`) | → `PROCESSABLE` |
| `service/PickingOrderMergeService.java:161` (`mergeOrders`) | → `PROCESSABLE` |
| `service/mobile/MobilePickingService.java:341` (`reserveOrder`) | → `RESERVED` |
| `service/PickingorderBusinessService.java:121` (`startPicking`) | → `STARTED` |
| `service/mobile/MobilePickingService.java:222,267,271,276` (`finishPicking`) | → `PICKED` / `FINISHED` / `PROCESSABLE` / `CANCELED` |
| `service/PickingorderBusinessService.java:318` (`finalizePicking`) | → `orderState` (parameter) |
| `service/PickingOrderMergeService.java:127` (`cancelOrderIfMergeFails`) | → `CANCELED` |
| `service/CustomerorderService.java:300,356,645` (cancel cascade — `300` Pickingorder→CANCELED in `forceCancelOrder`; `356` Pickingorder→PICKED in force path; `645` rapid-pick recovery → PROCESSABLE) | → `CANCELED` / `PICKED` / `PROCESSABLE` (rapid-pick recovery path) |

**Guards (hottest):**
- `MobilePickingService:222,303,328,333,340` — operator-flow gates: `== PICKED`, `>= PICKED`, `>= RESERVED`, `< RESERVED`
- `AdminActionController:182,193` — admin reset gates

### 4.4 `PickingorderPosition` — Integer state

| | |
|---|---|
| **Entity** | `model/PickingorderPosition.java:28` |
| **States reachable** | `RAW`, `ASSIGNED`, `PROCESSABLE`, `STARTED`, `PENDING`, `PICKED`, `CANCELED` |
| **Write sites** | 10+ in `PickingorderBusinessService`, `PickingorderPositionService`, `CustomerorderPositionService` |

Notable: `PickingorderBusinessService:484,490,492` (`finalizePicking`) writes three different terminal states depending on branch — `PICKED` / `STARTED` / `PENDING`. Read carefully before modifying that method.

### 4.5 `PickingorderUnitload` — Integer state

| | |
|---|---|
| **Entity** | `model/PickingorderUnitload.java:21` |
| **States reachable** | `RAW`, `STARTED`, `PICKED`, `FINISHED`, `CANCELED` |
| **Write sites** | 6 across `PickingorderBusinessService` and `CustomerorderService` |

Cancel cascade from `Customerorder` goes through this entity — see §5.1.

### 4.6 `Replenishorder` — Integer state

| | |
|---|---|
| **Entity** | `model/Replenishorder.java:25` |
| **States reachable** | `RAW`, `PROCESSABLE`, `STARTED`, `FINISHED`, `CANCELED` |
| **Write sites** | 10+ in `ReplenishGeneratorService`, `ReplenishorderService`, `ReplenishmentOrderMaintenanceService`, `MobileReplenishService` |

**Key transitions:**

| Location | Transition |
|---|---|
| `service/ReplenishGeneratorService.java:188,237` (`generateReplenish`) | → `PROCESSABLE` |
| `service/mobile/MobileReplenishService.java:234,245,263` (`startReplenish`) | → `STARTED` or `PROCESSABLE` (retry path) |
| `service/mobile/MobileReplenishService.java:499` (`finishReplenish`) | → `FINISHED` |
| `service/ReplenishmentOrderMaintenanceService.java:375` / `service/ReplenishorderService.java:219` (cancel paths) | → `CANCELED` |

### 4.7 `Advice` — **String state** (landmine)

| | |
|---|---|
| **Entity** | `model/Advice.java:22` |
| **Field type** | `String` (default `AdviceState.CREATED`) |
| **States reachable** | `CREATED`, `OPEN`, `PROCESSING`, `CLOSED`, `FINISHED`, `CANCELLED` |
| **Write sites** | 10+ in `ReceivingService`, `AdviceService`, `FileImportController`, `AdviceRestController` |

**Unstick endpoint:** `controller/rest/AdviceRestController.java:648` (`reopen`) — moves an Advice back from `FINISHED`/`CLOSED` to `OPEN`. **Only explicit reopener in the catalog**.

### 4.8 `Adviceposition` — String state

Same `AdviceState` values as Advice. Write sites: `ReceivingService:240,292`, `AdviceService:220`, `AdviceRestController:276,448,606`, `FileImportController:465`.

### 4.9 `Billoflading` + `BillofladingPosition` — String state

| | |
|---|---|
| **Entity** | `model/Billoflading.java:22` / `model/BillofladingPosition.java:17` |
| **States reachable** | `CREATED`, `OPEN`, `TRUCK_LOADING`, `TRANSFER`, `CLOSED`, `CANCELLED` |
| **Primary writer** | `service/BillofladingService.java` (`openBillOfLading:229`, `updateBillOfLading:646,464,473,520`, `finalizeBillOfLading:920`, `finishClubRun:744,749`) |
| **Cross-writer** | `ParcelMonitorViewService:220`, `MobileTruckLoadingService:228`, `BillofladingPositionService:44` |

### 4.10 `Cyclecount` / `CyclecountPosition` — String state

Smaller lifecycle (`CREATED`, `STARTED`, `FINISHED`, `CANCELLED`) — not enumerated here; treat as a follow-up if a bug in cycle-count flow surfaces.

### 4.11 Entities with NO state field

Explicitly verified absent — **do not add a state field without a design review**:

- `Stockunit` (`model/Stockunit.java`) — tracks `amount` + `reservedamount` only.
- `Unitload` (`model/Unitload.java`) — structural: label, type, storage location.

---

## 5. Cross-Entity Cascades

State changes on a parent routinely mutate children in the same transaction. These cascades are manual and easy to miss when adding new cases.

### 5.1 `CustomerorderService.cancelOrder()` (line 300)
Cascades `CANCELED` to:
- `Customerorder.state`
- `Pickingorder.state` (via position linkage)
- `PickingorderUnitload.state` (line 305)
Plus: `handleRapidPickingForCancelledOrder` (`CustomerorderService:645`) may bounce a `Pickingorder` back to `PROCESSABLE` if a rapid-pick tote must be released. See `Cancel_Order_Null_SectionId_And_Early_Return_Fix` for why the null-check there matters.

### 5.2 `CustomerorderService.pack()` (line 485)
Sets `Customerorder → PACKED` AND (via line 517) `PickingorderUnitload → FINISHED`.
Guard at line 382 prevents the `PACKED`/`PALLETIZED` double-apply that was the root cause of `Cancel_Club_Parcels_Packed_State_Fix`.

### 5.3 `ParcelMonitorViewService.palletizeOrders()` (lines 156, 283)
Sets `Customerorder → PALLETIZED`. Followed by the post-commit hook in the same file to notify OMS (§6 in the [transaction boundary map](./wms2-transaction-osiv-boundary-map.md)).

### 5.4 `BillofladingService.finishClubRun()` (lines 744, 749)
Sets `Customerorder → PACKED` **and** `CustomerorderBatch → ORDER_BATCH_CLUB_RUN_FINISHED` in the same transaction. Notable because it sets `PACKED` on the order even though the order itself wasn't packed in this method — the batch-level finish is a claim about all children.

### 5.5 `PickingorderBusinessService.finalizePicking()` (lines 238–569)
The single largest state-mutating method in the codebase — across one call it writes:
- `Customerorder.state` (238, 241, 502)
- `Pickingorder.state` (318, 569)
- `PickingorderPosition.state` (451, 464, 485, 491, 493)
- `PickingorderUnitload.state` (310, 563)

Read this method as a unit before editing anything in the pick-finalize path.

---

## 6. Recovery / Unstick Mechanisms

State drift is a known operational hazard; these are the sanctioned fixes:

| Mechanism | Location | What it does |
|---|---|---|
| Admin state reset | `controller/rest/UtilRestController.java:960-967` | Resets `Customerorder`, `CustomerorderBatch`, `CustomerorderPosition` back to `RAW` for re-release |
| Order-level reset | `controller/rest/OrderRestController.java:416,429` | Sets `Customerorder` → `RAW` or `FUTURE_PICKING_DATE` |
| Batch reset | `controller/rest/OrderRestController.java:350` | Sets `CustomerorderBatch` → `RAW` |
| Advice reopen | `controller/rest/AdviceRestController.java:648` | `FINISHED`/`CLOSED` → `OPEN` |
| Release job | `service/job/ReleaseOrderJobService.java` | Scheduled re-evaluation of `RAW` / `FUTURE_PICKING_DATE` / `RAW_ON_HOLD_*` / `CLIENT_HAS_NO_SECTION` orders; ~70 setState calls across hold/release logic |
| Club-run error recovery | `service/CustomerorderBatchService.java:661` | Rolls back from `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` to `originalState` on exception |

Outside these paths, there is no safe way to "fix" a stuck state — direct SQL updates bypass all cascades and will desync children.

---

## 7. Known Landmines

1. **No Spring StateMachine, no validator.** Any `setState(X)` call is legal at the JVM level. Legality is enforced only by the guards around that call site. When adding a new transition, grep for every prior call site against the same entity and confirm your path isn't already covered.
2. **`CANCELED` (Integer) vs `CANCELLED` (String).** Different spellings for different type systems. Don't copy-paste a guard from one entity to another without checking.
3. **String states have no DB-level constraint.** A typo like `"CLOSEDD"` persists. Consider the String-typed entities (`Advice`, `Billoflading`, `Cyclecount`, and their positions) suspect first when a state-related bug surfaces.
4. **Numeric ordering is a hidden contract.** Code uses `>= PICKED`, `< RESERVED`, `>= RESERVED`. Renumbering any `WmsConstants.State` constant is a silent breaking change. Add new states in gaps (the 5, 55–58, 505–530 gaps exist precisely for this).
5. **`PickingorderBusinessService.finalizePicking` mutates 5 entities.** Any change there must respect the full cascade in §5.5 — that's where the "picking completes but order stays STARTED" class of bug comes from.
6. **`cancelOrder` has a rapid-pick side-door.** If `historytote != null`, it bounces `Pickingorder → PROCESSABLE` (line 645) instead of `CANCELED`. The original bug it was patching is documented in `Cancel_Order_Null_SectionId_And_Early_Return_Fix`. Don't "simplify" that branch.
7. **Scheduled `ReleaseOrderJobService` writes ~70 state mutations.** Combined with `@Transactional(REQUIRES_NEW)` per step, this is the hottest optimistic-lock site in the app (see `WMS_V2_Horizontal_Scaling_Concurrency_Report`).
8. **`BillofladingService.finishClubRun` sets `Customerorder → PACKED` on behalf of the batch.** Order may not actually have been packed via normal flow; the batch-close method is asserting state on children. If you change the order state machine, audit this path.
9. **No Pickingorder terminal `FINISHED` writer outside mobile.** `MobilePickingService:267` is the only writer that sets `Pickingorder → FINISHED`. If a non-mobile codepath needs to reach `FINISHED`, you currently have to route through mobile-owned logic — a factoring problem flagged in `WMS_API_Problem_Areas_Analysis_And_Refactoring_Plan`.
10. **`CustomerorderBatchService:661` revert-to-originalState.** The only "revert" pattern in the codebase. It's narrowly scoped to club-run failures. Do not generalize it to a reusable helper — the caller-specific context is what makes it safe.

---

## 8. How to use this doc

| Task | Start at |
|---|---|
| "Why is this order stuck in state X?" | §4 (entity catalog) → find every writer of state X → check guards in §4 → check cascades in §5 |
| Adding a new lifecycle state | §2.1 (pick a gap value) → §3 (place it in the DAG) → §5 (decide cascade semantics) → §7 #4 |
| Adding a new `setState` call | §4 (find siblings) → §5 (confirm cascade obligations) → §6 (is this an unstick path?) |
| Debugging a `CANCELED` vs `CANCELLED` bug | §2.2 + §7 #2 |
| Auditing a cross-entity bulk transition | §5 (cascade map) |
| Reviewing a PR that touches `finalizePicking` / `pack` / `cancelOrder` / `finishClubRun` | §5.1–5.5 in full |

---

## 9. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | All state field declarations, `WmsConstants.State` + `AdviceState` + `BillOfLadingState` + `CycleCountState` values, write-site inventories (~160 total), primary guards, cascade methods, recovery endpoints | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-08 | Group T (transfer-order) churn — `TransferOrderService.unlinkTransferLaneFromTransferOrder` resets state to `CUSTOMER_ORDER_ACTIVATED` on lane unlink (commit 24280b0); Group P picking lines shifted +1 (`finalizePicking` now 238–569; cascade table updated); rapid-pick recovery cite confirmed at line 645 (guard at 639); SBDEV-2164 stale club batch cleanup adds JobLockId.STALE_CLUB_BATCH_CLEANUP but does not introduce new state values for `CustomerorderBatch` (cancel transitions remain through `cancelBatch`); §4.6 Replenishorder unaffected; receiving repository `findByStateAndItemdataId` confirmed live in `ReplenishorderRepository.java:46` (only used by job paths, no new state added). | All write-site lines re-confirmed; minor +1 drift in `PickingorderBusinessService` updated. | Code read (grep-based) |

**Re-verify every 60 days** — state surface drifts quickly. Next due: 2026-07-07.
