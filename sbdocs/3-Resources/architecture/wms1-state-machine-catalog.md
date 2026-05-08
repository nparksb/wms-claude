---
title: "WMS v1 — State Machine Catalog"
type: architecture
status: active
version: v1
scope: state-machines
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-04-26
verified_by: code read of v1/wms-api src/main at commit HEAD
related:
  - ./wms2-state-machine-catalog.md
tags:
  - architecture
  - state-machine
  - order-lifecycle
  - wms1
---

## TL;DR
- Catalogs every entity lifecycle in `v1/wms-api` — no framework, just Integer or String fields mutated by ~110 `setState(...)` call sites across ~20 services; transition legality is enforced only by ad-hoc guards at each site.
- Integer states (`WmsConstants.State.*`) are numerically ordered and used with `>=`/`<` comparisons; key flow: `RAW(0)` → `ASSIGNED(200)` → `PROCESSABLE(300)` → `STARTED(500)` → `PICKED(600)` → `PACKED(650)` → `PALLETIZED(670)` → `FINISHED(700)`; `CANCELED(800)` is reachable from most non-terminal states.
- String states (`AdviceState`, `BillOfLadingState`, `CycleCountState`) are plain String columns — a typo silently persists; note `CANCELLED` (two L's) vs `CANCELED` (one L) is a known bug-magnet.
- v1 has no `LOADED_TO_TRUCK(680)` state — `closeBOL` bulk-sets orders directly to `FINISHED`; v2 adds that intermediate step.
- Terminal states: `FINISHED(700)` and `CANCELED(800)` for Integer entities; `FINISHED`/`CANCELLED` for String entities.
- Primary write services: `CustomerorderService`, `PickingorderBusinessService`, `BillofladingService` (`closeBOL` → bulk `FINISHED`), `ReleaseOrderJobService`, `TransferOrderService`, mobile services.
- Read this doc for: any order/picking/BOL stuck-state bug, unexpected state transition, cancel/finish race condition, or feature that adds or guards on a state value.

# WMS v1 — State Machine Catalog

**Scope:** Lifecycle states and transition sites in `v1/wms-api` · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26 (code read against `src/main/java`)

---

## 1. Overview

`wms-api` has **no Spring StateMachine and no custom state-machine framework** — every entity's lifecycle is a plain Integer or String field on the entity, mutated by `setState(...)` calls scattered across ~110 write sites in ~20 services. Transition legality is enforced only by ad-hoc guards (`if (order.getState() == X)`) at each call site. Drift between guard copies is the primary root cause of stuck-state bugs.

**Key structural difference from v2:** v1 has no `LOADED_TO_TRUCK` state (680). The outbound flow goes `PACKED → PALLETIZED → FINISHED` (via `closeBOL`). The BOL tracks truck loading separately via its own `TRUCK_LOADING` string state.

---

## 2. The Two Type Systems

### 2.1 Integer states — `WmsConstants.State.*`

Defined at `net/aim_ai/wms/service/WmsConstants.java:12-163`. Numeric values are **ordered** — code uses `>=` / `<` comparisons as monotonic-progress checks. **Do not renumber constants.**

| Constant | Value | UI Label | Meaning |
|---|---|---|---|
| `RAW` | 0 | "Created" | Initial / unprocessed |
| `CLIENT_HAS_NO_SECTION` | 45 | "No Section" | Blocked — tenant has no section configured |
| `RAW_ON_HOLD` | 50 | "On Hold" | Temp hold during release evaluation |
| `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` | 55 | "Not enough stock on location" | Hold sub-reason |
| `RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION` | 56 | "No fixed assigned location" | Hold sub-reason |
| `RAW_ON_HOLD_PROBLEM_WITH_FIXED_ASSIGNED_LOCATION` | 57 | "Problem with fixed assigned location" | Hold sub-reason |
| `RAW_ON_HOLD_FIX_ASSIGNMENT_IS_INACTIVE` | 58 | "Fixed assignment is inactive" | Hold sub-reason |
| `FUTURE_PICKING_DATE` | 80 | "Future Picking Date" | Future-dated, not yet releasable |
| `ASSIGNED` | 200 | "Released" | Position assigned to a picking order |
| `PROCESSABLE` | 300 | "Processable" | Released; ready for operator to claim |
| `RESERVED` | 400 | "Reserved" | Operator has claimed it |
| `STARTED` | 500 | "Started" | Picking in progress |
| `CUSTOMER_ORDER_ACTIVATED` | 505 | "Transfer Activated" | Transfer flow — order activated |
| `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` | 510 | "Transfer Lane Assigned" | Transfer flow — lane set |
| `ORDER_BATCH_ACTIVATED` | 520 | "Activated" | Club/batch flow — activated |
| `ORDER_BATCH_STAGING_LANE_ASSIGNED` | 525 | "Lane Assigned" | Club/batch flow — lane set |
| `ORDER_BATCH_CLUB_RUN_FINISHED` | 530 | "Club Run Finished" | Club run done |
| `PENDING` | 550 | "Pending" | Mid-flow wait |
| `PICKED` | 600 | "Picked" | Picking complete, awaiting pack |
| `PACKED` | 650 | "Packed" | Pack complete |
| `PALLETIZED` | 670 | "Palletized" | Palletized |
| `FINISHED` | 700 | "Finished" | Terminal success |
| `CANCELED` | 800 | "Cancelled" | Terminal cancel (valid from most non-terminal states) |

> **v1 vs v2 delta:** v1 is missing `LOADED_TO_TRUCK` (680). In v2 the outbound flow has an extra `LOADED_TO_TRUCK` step between `PALLETIZED` and `FINISHED`. In v1 `closeBOL` bulk-sets orders directly to `FINISHED` without a loaded state.

### 2.2 String states — LANDMINE

Three separate constant classes, all in `WmsConstants`:

| Constant class | Used by | Values |
|---|---|---|
| `WmsConstants.AdviceState` | `Advice`, `Adviceposition` | `CREATED`, `OPEN`, `PROCESSING`, `CLOSED`, `FINISHED`, `CANCELLED` |
| `WmsConstants.BillOfLadingState` | `Billoflading`, `BillofladingPosition` | `CREATED`, `OPEN`, `TRUCK_LOADING`, `TRANSFER`, `CLOSED`, `CANCELLED` |
| `WmsConstants.CycleCountState` | `Cyclecount`, `CyclecountPosition` | `CREATED`, `STARTED`, `FINISHED`, `CANCELLED` |

> **Note the spelling: `CANCELLED` (two L's) for String states, `CANCELED` (one L) for the Integer state.** This inconsistency is a bug-magnet — `.equals("CANCELED")` on an advice will always return false.

String states are stored as plain `String` columns (no enum, no DB-level constraint). A typo persists silently.

### 2.3 Lock states — `WmsConstants.BusinessObjectLockState.*`

Applied to `Stockunit`, `Unitload`, `Location`, and `Pickingorder` via the `entityLock` field (Integer).

| Constant | Value | Meaning |
|---|---|---|
| `NOT_LOCKED` | 0 | Normal — operations allowed |
| `GOING_TO_DELETE` | 2 | Marked for deletion |
| `PICKED_FOR_GOODSOUT` | 100 | Committed to outbound picking |
| `QUALITY_FAULT` | 103 | Damaged / quarantined |
| `ON_HOLD` | 104 | Administrative hold |
| `NOT_FOUND` | 403 | Lost in cycle count |
| `TRANSFER` | 404 | In transit to another facility |
| `SHIPPED` | 405 | Shipped — terminal lock |

Lock state is not a lifecycle state machine — it is an access-control flag that gates operations on the entity. See §4.10 for write sites.

---

## 3. The Integer State DAG

```
              RAW(0) ──► FUTURE_PICKING_DATE(80)
                │
                │   RAW_ON_HOLD(50) ──┬─► 55/56/57/58
                │     ▲               │
                │     └───────────────┘ (re-evaluated each release cycle)
                │
                ├──► CLIENT_HAS_NO_SECTION(45) ◄──── stuck
                │
                ▼
            ASSIGNED(200) ──► PROCESSABLE(300) ──► RESERVED(400)
                                     │
                                     ▼
                              STARTED(500) ──► PICKED(600)
                                                   │
                                                   ▼
                                              PACKED(650)
                                                   │
                                                   ▼
                                            PALLETIZED(670)
                                                   │
                                                   ▼
                                             FINISHED(700)  ◄── set by closeBOL

  Transfer flow:   CUSTOMER_ORDER_ACTIVATED(505) ──►
                   CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED(510)

  Batch flow:      ORDER_BATCH_ACTIVATED(520) ──►
                   ORDER_BATCH_STAGING_LANE_ASSIGNED(525) ──►
                   ORDER_BATCH_CLUB_RUN_FINISHED(530)

  Wait:            PENDING(550) (mid-pick hold, resolved by finishPickingOrder)

  Terminal:        CANCELED(800) ← reachable from most non-terminal states
```

Common numeric-order guards in the code:
- `state >= WmsConstants.State.RESERVED` — "has been claimed or beyond"
- `state >= WmsConstants.State.PICKED` — "in post-pick phase"
- `state < WmsConstants.State.PACKED` — "not yet packed"
- `state >= WmsConstants.State.FINISHED && state != WmsConstants.State.CANCELED` — "finished but not cancelled"

---

## 4. Per-Entity Catalog

### 4.1 `Customerorder` — Integer state

| | |
|---|---|
| **Entity** | `model/Customerorder.java` |
| **Field** | `state` (Integer) |
| **States reachable** | `RAW`, `FUTURE_PICKING_DATE`, `RAW_ON_HOLD*`, `CLIENT_HAS_NO_SECTION`, `ASSIGNED`, `PROCESSABLE`, `RESERVED`, `STARTED`, `CUSTOMER_ORDER_ACTIVATED`, `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`, `PENDING`, `PICKED`, `PACKED`, `PALLETIZED`, `FINISHED`, `CANCELED` |
| **Write sites** | 25+ — primary in `CustomerorderService`, `PickingorderBusinessService`, `ParcelMonitorViewService`, `BillofladingService`, `TransferOrderService`, `ReleaseOrderJobService`, mobile services |

**Key write sites:**

| Location | Transition | Event |
|---|---|---|
| `service/job/ReleaseOrderJobService.java:547` | → `ASSIGNED` | Release job assigns picking order |
| `service/job/ReleaseOrderJobService.java:551` | `CustomerorderBatch` → `STARTED` | Side-effect of order release |
| `service/TransferOrderService.java:85` | → `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` | Transfer lane assigned |
| `service/TransferOrderService.java:114` | → `CUSTOMER_ORDER_ACTIVATED` | Transfer order activated |
| `service/TransferOrderService.java:122` | → `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` | Transfer lane re-assigned |
| `service/PickingorderBusinessService.java:342` | → `STARTED` | First pick position picked |
| `service/PickingorderBusinessService.java:381,384` | → `PENDING` / `PICKED` | finishPickingOrder sub-path |
| `service/CustomerorderService.java:447` | → `PACKED` | `packageOrder()` — normal pick-pack path |
| `service/CustomerorderBatchService.java:720` | → `PACKED` | `finishClubRun()` — club run close |
| `service/BillofladingService.java:977` | → `PACKED` | Transfer BOL club run close |
| `service/ParcelMonitorViewService.java:129,242` | → `PALLETIZED` | Web UI palletize action |
| `service/mobile/MobilePalletizingService.java:206,350` | → `PALLETIZED` | Mobile palletize action |
| `service/AdviceService.java:216` | → `PALLETIZED` | Hub-and-spoke accept |
| `service/BillofladingService.java:513` (bulk) | → `FINISHED` | `closeBOL()` Phase 5 bulk update |
| `service/CustomerorderService.java:314,350,645` | → `CANCELED` | `cancelOrder()` / `forceCancelOrder()` |
| `controller/rest/OrderRestController.java:395,409` | → `RAW` / `FUTURE_PICKING_DATE` | OMS-initiated reset |
| `controller/rest/UtilRestController.java:997` | → `RAW` | Admin reset of ASSIGNED orders |

**Key guards:**
- `CustomerorderService:562` — `cancelOrder` blocks if `state >= FINISHED && state != CANCELED`
- `CustomerorderService:587-589` — blocks cancel if any position is `>= PACKED && < CANCELED`
- `CustomerorderService:343` — `forceCancelOrder` path for `PACKED` or `PALLETIZED` orders (WMS-originated cancel)
- `CustomerorderService:604` — rapid-pick side-door: if `state == ASSIGNED && historytote != null`, bounces `Pickingorder → PROCESSABLE` instead of `CANCELED`

### 4.2 `CustomerorderBatch` — Integer state

| | |
|---|---|
| **Entity** | `model/CustomerorderBatch.java` |
| **States reachable** | `RAW`, `STARTED`, `ORDER_BATCH_ACTIVATED`, `ORDER_BATCH_STAGING_LANE_ASSIGNED`, `ORDER_BATCH_CLUB_RUN_FINISHED`, `FINISHED`, `CANCELED` |
| **Write sites** | 12+ in `CustomerorderBatchService`, `BillofladingService`, `ReleaseOrderJobService`, `OrderRestController` |

**Key write sites:**

| Location | Transition | Event |
|---|---|---|
| `service/job/ReleaseOrderJobService.java:551` | → `STARTED` | First order in batch released |
| `service/CustomerorderBatchService.java:416` | → `ORDER_BATCH_ACTIVATED` | `activateBatch()` |
| `service/CustomerorderBatchService.java:423` | → `ORDER_BATCH_STAGING_LANE_ASSIGNED` | `assignStagingLane()` |
| `service/CustomerorderBatchService.java:789` | → `ORDER_BATCH_STAGING_LANE_ASSIGNED` | Error-rollback from club run |
| `service/CustomerorderBatchService.java:732` | → `ORDER_BATCH_CLUB_RUN_FINISHED` | `finishClubRun()` |
| `service/BillofladingService.java:983` | → `ORDER_BATCH_CLUB_RUN_FINISHED` | Transfer BOL club run close |
| `service/CustomerorderBatchService.java:345,347` | → `CANCELED` or `FINISHED` | `finalizeBatchIfComplete()` |
| `service/CustomerorderBatchService.java:326` | → `CANCELED` | `cancelBatch()` |
| `controller/rest/OrderRestController.java:328` | → `RAW` | OMS-initiated batch reset |
| `service/CustomerorderService.java:762` | → `FINISHED` | Last order in batch finishes |

**Guard:** `CustomerorderBatchService:571–572` — club run requires `ORDER_BATCH_ACTIVATED` OR `ORDER_BATCH_STAGING_LANE_ASSIGNED`.

**`finalizeBatchIfComplete` logic** (`CustomerorderBatchService:342–347`): if all child orders are `>= FINISHED`, batch becomes `CANCELED` if all are `CANCELED`, else `FINISHED`.

### 4.3 `Pickingorder` — Integer state

| | |
|---|---|
| **Entity** | `model/Pickingorder.java` |
| **States reachable** | `RAW`, `PROCESSABLE`, `RESERVED`, `STARTED`, `PICKED`, `FINISHED`, `CANCELED` |
| **Write sites** | 15+ in `PickingorderBusinessService`, `MobilePickingService`, `CustomerorderService`, `ReleaseOrderJobService`, `CustomerorderBatchService` |

**Key write sites:**

| Location | Transition | Event |
|---|---|---|
| `service/job/ReleaseOrderJobService.java:465` | → `PROCESSABLE` | Release job creates picking order |
| `service/mobile/MobilePickingService.java:303` | → `RESERVED` | Mobile operator claims order |
| `service/PickingorderBusinessService.java:86` | → `STARTED` | `startPickingOrder()` — first pick |
| `service/mobile/MobilePickingService.java:184,262,314` | → `PICKED` | Mobile picking complete paths |
| `service/PickingorderBusinessService.java:403` | → `PICKED` | All positions done in `finishPickingOrder` |
| `service/PickingorderBusinessService.java:207` | → `orderState` param (`FINISHED` or `CANCELED`) | `finishPickingOrder()` result |
| `service/mobile/MobilePickingService.java:225` | → `FINISHED` | Mobile finish when all positions done |
| `service/mobile/MobilePickingService.java:229` | → `PROCESSABLE` | Mobile reset (re-release) |
| `service/mobile/MobilePickingService.java:234` | → `CANCELED` | Mobile cancel |
| `service/mobile/MobilePickingService.java:591` | → `PROCESSABLE` | `releaseRegularPickingOrder()` |
| `service/CustomerorderService.java:265` | → `CANCELED` | Cascade from `cancelOrder` |
| `service/CustomerorderService.java:612` | → `PROCESSABLE` | Rapid-pick side-door on cancel |
| `service/CustomerorderBatchService.java:285,287` | → `CANCELED` or `FINISHED` | Batch cancel cascade |
| `controller/OrderMonitorViewService.java:180` | → `STARTED` | Admin re-start from order monitor |
| `service/CustomerorderPositionService.java:145` | → `FINISHED` | All positions finished → picking order finishes |

**Guards:**
- `PickingorderBusinessService:77` — `startPickingOrder` rejects if `state >= PICKED`
- `PickingorderBusinessService:104` — `finishPickingOrder` rejects if `state >= FINISHED`
- `MobilePickingService:303` — `RESERVED` only if `< RESERVED` (not already claimed)

### 4.4 `PickingorderPosition` — Integer state

| | |
|---|---|
| **Entity** | `model/PickingorderPosition.java` |
| **States reachable** | `RAW`, `PROCESSABLE`, `STARTED`, `PENDING`, `PICKED`, `CANCELED` |
| **Write sites** | 10+ in `PickingorderBusinessService`, `PickingorderPositionService`, `CustomerorderPositionService`, `CustomerorderBatchService` |

**Key write sites:**

| Location | Transition | Event |
|---|---|---|
| `service/PickingorderPositionService.java:68` | → `PROCESSABLE` | Position created for release |
| `service/job/ReleaseOrderJobService.java:480,500,516` | → `ASSIGNED` | Position assigned during release |
| `service/PickingorderBusinessService.java:303` | → `PICKED` | Single pick position finished |
| `service/PickingorderBusinessService.java:323` | → `PICKED` | Customer order position marks as picked |
| `service/PickingorderBusinessService.java:329` | → `STARTED` | Partial pick in progress |
| `service/PickingorderBusinessService.java:331` | → `PENDING` | Waiting for more stock |
| `service/CustomerorderPositionService.java:138` | → `CANCELED` | Position cancel (if `< RESERVED`) |
| `service/CustomerorderBatchService.java:276` | → `CANCELED` | Batch cancel cascade |

**Notable:** `PickingorderBusinessService:317–331` writes three different states (`PICKED`, `STARTED`, `PENDING`) depending on whether all positions for the customer order position are done.

### 4.5 `PickingorderUnitload` — Integer state

| | |
|---|---|
| **Entity** | `model/PickingorderUnitload.java` |
| **States reachable** | `RAW`, `STARTED`, `PICKED`, `FINISHED`, `CANCELED` |
| **Write sites** | 6 in `PickingorderBusinessService`, `CustomerorderService` |

| Location | Transition | Event |
|---|---|---|
| `service/PickingorderBusinessService.java:396` | → `STARTED` | First item picked onto tote |
| `service/PickingorderBusinessService.java:196` | → `PICKED` | Unit load picked during finishPickingOrder |
| `service/CustomerorderService.java:482` | → `FINISHED` | `packageOrder()` completes |
| `service/CustomerorderService.java:260,618,773` | → `CANCELED` | Cancel cascades |

### 4.6 `Replenishorder` — Integer state

| | |
|---|---|
| **Entity** | `model/Replenishorder.java` |
| **States reachable** | `RAW`, `PROCESSABLE`, `STARTED`, `FINISHED`, `CANCELED` |
| **Write sites** | 8+ in `ReplenishGeneratorService`, `ReplenishorderService`, `ReplenishmentOrderMaintenanceService`, `MobileReplenishService` |

**Key write sites:**

| Location | Transition | Event |
|---|---|---|
| `service/ReplenishGeneratorService.java:148,202` | → `PROCESSABLE` | Generator creates replenish order |
| `service/mobile/MobileReplenishService.java:209` | → `STARTED` | Mobile operator starts replenish |
| `service/mobile/MobileReplenishService.java:225` | → `PROCESSABLE` | Mobile retry/re-release path |
| `service/mobile/MobileReplenishService.java:476` | → `FINISHED` | Mobile operator completes replenish |
| `service/ReplenishorderService.java:202` | → `CANCELED` | Cancel path |
| `service/ReplenishmentOrderMaintenanceService.java:365` | → `CANCELED` | Maintenance cancel |

**Guards (`ReplenishorderService`):**
- `:188` — logs warning if `> FINISHED` (already terminal)
- `:192` — early-return if already `FINISHED`
- Open orders filter: `findByStateLessThan(FINISHED)` — treats `CANCELED` (800) as not-open

### 4.7 `Advice` — **String state** (landmine)

| | |
|---|---|
| **Entity** | `model/Advice.java` |
| **Field type** | `String` (default `AdviceState.CREATED`) |
| **States reachable** | `CREATED`, `OPEN`, `PROCESSING`, `CLOSED`, `FINISHED`, `CANCELLED` |
| **Write sites** | 10+ in `ReceivingService`, `AdviceService`, `FileImportController`, `AdviceRestController` |

**Key write sites:**

| Location | Transition | Event |
|---|---|---|
| `controller/rest/AdviceRestController.java:177` | → `OPEN` | OMS import creates advice |
| `controller/rest/AdviceRestController.java:399,525` | → `OPEN` | Transfer / hub-and-spoke advice import |
| `controller/FileImportController.java:427` | → `OPEN` | CSV file import |
| `service/ReceivingService.java:212` | → `OPEN` | Create advice with positions |
| `service/AdviceService.java:296` | → `FINISHED` | `close()` — REGULAR advice close |
| `service/AdviceService.java:229` | → `FINISHED` | `acceptHubAndSpokeAdvice()` |
| `service/AdviceService.java:422` | → `FINISHED` | `acceptTransferAdvice()` |
| `controller/rest/AdviceRestController.java:316,317` | → `FINISHED` (bulk) | Batch close via repository |

**Allowed states for `close()`** (`AdviceService:275–292`): only `OPEN` or `PROCESSING`. `CREATED`, `CLOSED`, `FINISHED`, `CANCELLED` all throw `BusinessException`.

**Note:** No `PROCESSING` or `CLOSED` writer found in service layer for the regular advice flow — those states appear to be set by receiving-related flows not captured in the main service. `CLOSED` is also reachable in theory (as a `BillOfLadingState` member) but as an `AdviceState` it does not have an explicit active writer in the catalog; treat it as legacy/unused in current flows.

### 4.8 `Adviceposition` — String state

Same `AdviceState` values as `Advice`. Write sites: `ReceivingService:246,298`, `AdviceService:201,301,426`, `AdviceRestController:261,589`, `FileImportController:456`.

The receiving position guard (`ReceivingService:356,394`) requires `OPEN` for both position and parent advice before allowing goods receipt.

### 4.9 `Billoflading` + `BillofladingPosition` — String state

| | |
|---|---|
| **Entities** | `model/Billoflading.java` / `model/BillofladingPosition.java` |
| **States reachable** | `CREATED`, `OPEN`, `TRUCK_LOADING`, `TRANSFER`, `CLOSED`, `CANCELLED` |

**Key write sites:**

| Location | Transition | Event |
|---|---|---|
| `service/BillofladingService.java:211` | → `OPEN` | `createBOL()` — BOL created |
| `service/mobile/MobileTruckLoadingService.java:203` | → `TRUCK_LOADING` | Mobile scans first gate |
| `service/ParcelMonitorViewService.java:175` | → `TRUCK_LOADING` | Web UI starts truck loading |
| `service/BillofladingPositionService.java:41` | → `TRUCK_LOADING` | BOL position opened for loading |
| `service/BillofladingService.java:315–316` (closeBOL) | → `TRANSFER` (if TRANSFER_INTRACOMPANY) or `CLOSED` | `closeBOL()` Phase 7 |
| `service/BillofladingService.java:553` (closeBOL) | → `bolState` (TRANSFER or CLOSED) | `closeBOL()` save |
| `service/BillofladingService.java:1139` (acceptTransfer) | → `CLOSED` | `acceptTransferBOL()` |
| `service/BillofladingService.java:1148,1152,1156` | → `CLOSED` (positions) | Same method, cascades to positions |

**`closeBOL` state routing** (`BillofladingService:275–289`): `CREATED` and `OPEN` → proceed; `TRUCK_LOADING` → proceed; `TRANSFER`, `CLOSED`, `CANCELLED` → throw `BusinessException`.

**Output state:** `TRANSFER` for `TRANSFER_INTRACOMPANY` batch type; `CLOSED` for all others.

**`closeBOL` also bulk-sets all child `Customerorder` → `FINISHED`** via `updateStateByIds` (line 513).

### 4.10 `Cyclecount` / `CyclecountPosition` — String state

| | |
|---|---|
| **States** | `CREATED`, `STARTED`, `FINISHED`, `CANCELLED` |
| **Write sites** | `CyclecountService`, `CyclecountPositionService`, `MobileCycleCountService` |

**Key write sites:**

| Location | Transition | Event |
|---|---|---|
| `service/CyclecountService.java:61` | → `CREATED` | `createEntity()` |
| `service/CyclecountPositionService.java:43` | → `CREATED` | Position created |
| `service/CyclecountService.java:87` | → `CREATED` | Position added to count |
| `service/mobile/MobileCycleCountService.java:153,201,350,425` | → `FINISHED` | Mobile counts a position |
| `service/mobile/MobileCycleCountService.java:369,475` | → `FINISHED` | Cycle count completed |
| `service/CyclecountService.java:126,138` | → `CANCELLED` | Cancel count or position |

**Mobile position finish logic** (`MobileCycleCountService:354–369`): once a position reaches `FINISHED`, checks all sibling positions — if all are `FINISHED` or `CANCELLED`, marks the parent `Cyclecount → FINISHED`.

### 4.11 `Stockunit` / `Unitload` / `Location` — Lock state only

These entities carry an `entityLock` (Integer) field from `WmsConstants.BusinessObjectLockState`, not a lifecycle state. They do not have a `state` field.

**`Stockunit` lock write sites (`StockunitService`):**

| Location | Lock set | Event |
|---|---|---|
| `StockunitService.java:309` | → `ON_HOLD` | `setLockOnHold()` |
| `StockunitService.java:367` | → `QUALITY_FAULT` | `setLockDamaged()` |
| `StockunitService.java:211` | → `QUALITY_FAULT` | Transfer to Damaged location |
| `StockunitBusinessService.java:295` | → `GOING_TO_DELETE` | Mark for nirvana |
| `StockunitBusinessService.java:85–86` | → `NOT_LOCKED` (0) | Stock created / transferred clean |
| `BillofladingService.java` (bulk) | → `SHIPPED` (405) | `closeBOL` Phase 6 bulk lock update |
| `BillofladingService.java:1176` | → `SHIPPED` | `acceptTransferBOL` |

**Guard pattern:** Nearly every operation on `Stockunit` first checks `entityLock != NOT_LOCKED` and throws `BusinessException` (cycle count, replenish, pack, transfer).

---

## 5. Cross-Entity Cascades

### 5.1 `CustomerorderService.cancelOrder()` (line 562) / `forceCancelOrder()` (line 284)

**`cancelOrder` path** (pre-PACKED): cascades `CANCELED` to:
- `Customerorder.state` (line 645)
- `CustomerorderPosition.state` (via `cancelOrderPosition`, line 642)
- `PickingorderPosition.state` (line 302 — if `< RESERVED`)
- `PickingorderUnitload.state` (line 260, 618)

**Rapid-pick side-door** (`cancelOrder:604`): if `state == ASSIGNED && historytote != null`, the `Pickingorder` is bounced to `PROCESSABLE` (line 612) instead of `CANCELED`. The tote unit load is set to `CANCELED` (line 618). This is a pick-recovery path, not a cancellation.

**`forceCancelOrder` path** (PACKED/PALLETIZED): directly sets `Customerorder → CANCELED` and position states, bypassing the picking-order cascade. Called only from `cancelOrder` when `cancellationFromWithinWMS = true`.

### 5.2 `CustomerorderService.packageOrder()` (line 430)

Sets `Customerorder → PACKED` AND cascades `PickingorderUnitload → FINISHED` (line 482). Requires `state == PICKED` guard (line 433). Creates the `packageUnitLoad` entity and moves stock onto it.

### 5.3 `CustomerorderBatchService.finishClubRun()` (line ~700)

Sets **all non-cancelled child orders** `Customerorder → PACKED` (line 720) and their positions `→ PACKED` (line 728). Sets `CustomerorderBatch → ORDER_BATCH_CLUB_RUN_FINISHED` (line 732). This claims `PACKED` state on behalf of children without the normal `packageOrder` flow — the batch close is the authoritative signal.

**Error-rollback path** (`CustomerorderBatchService:789`): on exception during club run, `CustomerorderBatch → ORDER_BATCH_STAGING_LANE_ASSIGNED` (reverts to pre-run state).

### 5.4 `BillofladingService.closeBOL()` (line 263)

The largest single cross-entity mutation:
1. Phase 4: bulk transfer pallet trees to `SHIPPED` location
2. Phase 5: bulk `Customerorder → FINISHED` and `CustomerorderPosition → FINISHED` via repository (lines 513, 518)
3. Phase 6: bulk `Unitload.entityLock → SHIPPED` and `Stockunit.entityLock → SHIPPED` (lines 542, 547)
4. Phase 7: `Billoflading.state → CLOSED` (or `TRANSFER`) (line 553)

**Read this method as a unit before modifying any outbound completion path.**

### 5.5 `PickingorderBusinessService.finishPickingOrder()` (line 101)

Mutates 4 entity types in one call:
- `PickingorderUnitload.state` → `PICKED` (line 196)
- `PickingorderPosition.state` — evaluated per-position; some stay `PICKED`, some stay as-is
- `Customerorder.state` → `STARTED` (line 342, first pick), `PENDING` (line 381), or `PICKED` (line 384)
- `Pickingorder.state` → `FINISHED` or `CANCELED` based on computed `orderState` (line 207)

### 5.6 `CustomerorderService.cancelOrder()` batch path (line ~649)

When `cancellationFromWithinWMS = false` (OMS-originated) and order is beyond `PICKED`, the cancel is blocked. When `cancellationFromWithinWMS = true` and order is `PACKED`/`PALLETIZED`, delegates to `forceCancelOrder()`.

---

## 6. Recovery / Unstick Mechanisms

| Mechanism | Location | What it does |
|---|---|---|
| Batch reset | `controller/rest/OrderRestController.java:328` | Sets `CustomerorderBatch → RAW` (OMS-originated) |
| Order reset | `controller/rest/OrderRestController.java:395,409` | Sets `Customerorder → RAW` or `FUTURE_PICKING_DATE` (OMS-originated) |
| Admin ASSIGNED reset | `controller/rest/UtilRestController.java:989–1004` (`/resetOrdersInReleasedStatus`) | Bulk resets all `ASSIGNED` orders + their batches + positions back to `RAW` |
| Mobile picking reset | `controller/mobile/PickingController.java:183` (`/resetPickingOrder`) | Calls `MobilePickingService.resetPickingOrder()` — releases a stuck pick |
| Mobile re-release | `service/mobile/MobilePickingService.java:591` (`releaseRegularPickingOrder`) | Sets `Pickingorder → PROCESSABLE` |
| Release job | `service/job/ReleaseOrderJobService.java` | Scheduled re-evaluation of `RAW` / `FUTURE_PICKING_DATE` / `RAW_ON_HOLD_*` / `CLIENT_HAS_NO_SECTION` orders |
| Club-run error rollback | `service/CustomerorderBatchService.java:789` | Reverts `CustomerorderBatch → ORDER_BATCH_STAGING_LANE_ASSIGNED` on exception |
| Picking date update | `service/CustomerorderService.java:179` (`setPickingDate`) | Re-evaluates `RAW` vs `FUTURE_PICKING_DATE` for orders `> RAW && < RESERVED` |

Outside these paths, there is no safe way to fix a stuck state — direct SQL updates bypass all cascades and will desync child entities.

---

## 7. Known Landmines

1. **No Spring StateMachine, no validator.** Any `setState(X)` call is legal at the JVM level. When adding a transition, grep every prior write site against the same entity and confirm the path isn't already covered.
2. **`CANCELED` (Integer 800) vs `CANCELLED` (String).** Different spellings for different type systems. Copying a guard from one entity to another without checking the type will silently fail.
3. **String states have no DB-level constraint.** `Advice`, `Billoflading`, `Cyclecount`, and their position entities store state as plain VARCHAR. A typo persists.
4. **No `LOADED_TO_TRUCK` in v1.** The v2 `LOADED_TO_TRUCK` (680) state does not exist in v1. The v1 outbound flow goes `PALLETIZED → FINISHED` (via `closeBOL` bulk update). Do not port v2 truck-loading logic to v1 without accounting for this gap.
5. **`closeBOL` Phase 5 uses bulk native repository updates.** `customerorderRepository.updateStateByIds()` and `customerorderPositionRepository.updateStateByOrderIds()` are `nativeQuery=true`. They bypass JPA first-level cache. After `closeBOL`, do not rely on in-memory entity state for any order that was in the BOL — refetch from DB.
6. **`finishPickingOrder` mutates 4 entities.** Any change in the pick-finalize path must respect the full cascade in §5.5. "Picking completes but order stays STARTED" bugs originate here.
7. **`cancelOrder` has a rapid-pick side-door.** If `historytote != null`, it bounces `Pickingorder → PROCESSABLE` instead of `CANCELED`. Do not "simplify" that branch without reading the guard at `CustomerorderService:604`.
8. **`finishClubRun` sets `Customerorder → PACKED` on behalf of the batch.** Order may not have been packed via the normal `packageOrder` flow. If you change the order state machine, audit `CustomerorderBatchService.finishClubRun` and `BillofladingService.java:977`.
9. **`CustomerorderBatchService:789` reverts to `ORDER_BATCH_STAGING_LANE_ASSIGNED`, not to `originalState`.** It hardcodes the rollback target rather than saving the prior state. If future states are added between `ORDER_BATCH_ACTIVATED` and `ORDER_BATCH_STAGING_LANE_ASSIGNED`, this rollback logic needs updating.
10. **`ReceivingService.receiveGoods()` requires `adviceposition.state == OPEN`.** If an advice position is stuck in `CREATED` (never transitioned to `OPEN`), receiving will fail with `unexpectedStateFound`. The fix is to re-import or manually advance via the OMS.
11. **`Stockunit.entityLock` is checked pervasively.** Before adding any operation that reads or modifies stock, add the `entityLock != NOT_LOCKED` guard. Its absence is the pattern that caused the `SBDEV-2102` class of bugs.

---

## 8. How to use this doc

| Task | Start at |
|---|---|
| "Why is this order stuck in state X?" | §4 (entity catalog) → find every writer of state X → check guards in §4 → check cascades in §5 |
| Adding a new lifecycle state | §2.1 (pick a gap value) → §3 (place in DAG) → §5 (decide cascade semantics) → §7 #4 |
| Adding a new `setState` call | §4 (find siblings) → §5 (confirm cascade obligations) → §6 (is this an unstick path?) |
| Debugging a `CANCELED` vs `CANCELLED` bug | §2.2 + §7 #2 |
| Auditing a cross-entity bulk transition | §5 (cascade map) |
| Reviewing a PR touching `finishPickingOrder` / `packageOrder` / `cancelOrder` / `finishClubRun` / `closeBOL` | §5 in full |
| Porting a v1 fix to v2 | Check §2.1 for `LOADED_TO_TRUCK` delta; check `closeBOL` phase numbering may differ |

---

## 9. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | All state field declarations, `WmsConstants.State` + `AdviceState` + `BillOfLadingState` + `CycleCountState` + `BusinessObjectLockState` values, write-site inventories (~110 total), primary guards, cascade methods, recovery endpoints | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |

**Re-verify every 60 days** — state surface drifts quickly. Next due: 2026-06-25.
