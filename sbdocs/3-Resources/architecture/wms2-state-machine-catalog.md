---
title: "WMS v2 — State Machine Catalog"
type: architecture
status: active
version: v2
scope: state-machines
owner: Nam Park
created: 2026-04-19
updated: 2026-08-14
last_verified: 2026-05-08
verified_by: code read of v2/wms2-api src/main at commit HEAD
related:
  - ./wms2-transaction-osiv-boundary-map.md
  - ../workflows/wms2-replenish-workflow.md
  - ../workflows/wms2-replenish-order-creation.md
  - ../../4-Archieves/wms2/plan/260320-Auto_Release_Club_Transfer_Lane_Fix.md
  - ../../4-Archieves/wms2/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md
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
| `CLIENT_HAS_NO_SECTION` | 45 | Blocked — the **order's client** (`co.client_id`) has no Section configured, so no `Pickingorder` can be created. **Writer:** `OrderReleaseJob.processOrderGroup` → `ReleaseOrderJobService.markClientHasNoSection` (SBDEV-2961, 2026-08-14). ⚠ Before that ticket this state had **no writer at all** and was structurally unreachable, so any doc, diagram or code branch predating it that treats 45 as a live state was describing an intent, not behaviour |
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
            CLIENT_HAS_NO_SECTION(45) ◄──── no Section on client  │
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
| `service/CustomerorderService.java:285,290-291` (`setPickingDate`, declared :246) | → `RAW` / `FUTURE_PICKING_DATE` |
| `service/job/ReleaseOrderJobService.java:196,395,440,454` / `:723` (`releaseOrder`, declared :121) | → `ASSIGNED` / `STARTED` |
| `service/TransferOrderService.java:100,155,163` / `:115` / `:132` | → `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` (`assignTransferLaneToTransferOrder` :90, `activateAndAssignTransferLane` :139, `assignTransferLane` :161) / `CUSTOMER_ORDER_ACTIVATED` (`activateTransferOrder` :124); `:115` is `unlinkTransferLaneFromTransferOrder` (Group T port v1 5ada0b0 / v2 24280b0): when a transfer lane is unlinked, state is reset to `CUSTOMER_ORDER_ACTIVATED` (not left in `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`) |
| `service/PickingorderBusinessService.java:249,252` (`finishPickingOrder` :148) / `:419` (`cleanUpCancelledOrder` :401) / `:594` (`confirmPick` :491) | → `PENDING` / `PICKED` / `CANCELED` / `STARTED` |
| `service/CustomerorderService.java:557` (`packageOrder`, declared :541) | → `PACKED` |
| `service/ParcelMonitorViewService.java:193` (`palletise` :103) / `:345` (`palletiseAndTruckLoad` :249) | → `PALLETIZED` |
| `service/mobile/MobilePalletizingService.java:269` (`scanPallet` :159) / `:421` (`scanParcelBulk` :362) | → `PALLETIZED` |
| `service/ParcelMonitorViewService.java:465` (`palletiseAndTruckLoad` :249) | → `LOADED_TO_TRUCK` |
| `service/mobile/MobileTruckLoadingService.java:306` (`scanGate` :180) | → `LOADED_TO_TRUCK` |
| `service/BillofladingService.java:503,546` (`closeBOL` :298) | → `FINISHED` |
| `service/CustomerorderService.java:356,361` (`checkAndCleanUpPickingOrderPositions` :299) / `:408,415` (`updateOrderPositions` :370); the public entry point is `cancelOrder` at **:690** | → `CANCELED` |
| `controller/rest/UtilRestController.java:1092,1095,1099` (`resetOrdersInReleasedStatus` :1080) | → `RAW` |

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
| `service/CustomerorderBatchService.java:474` (`activateOrderBatch`, declared :468) | → `ORDER_BATCH_ACTIVATED` |
| `service/CustomerorderBatchService.java:479` (`assignStagingLane`) | → `ORDER_BATCH_STAGING_LANE_ASSIGNED` |
| `service/CustomerorderBatchService.java:628` (`validateClubLine`, declared :610) | → `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` |
| `service/CustomerorderBatchService.java:716` (`finalizeClubLine`, declared :693) | → `ORDER_BATCH_CLUB_RUN_FINISHED` |
| `service/CustomerorderBatchService.java:709` (error recovery) | → `originalState` (rollback from club run) |
| `service/CustomerorderBatchService.java:260` (`cancelBatch`) | → `CANCELED` |
| `service/CustomerorderBatchService.java:393` (`finalizeBatchIfComplete`) | → `CANCELED` or `FINISHED` depending on child orders |

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
| `service/PickingorderBusinessService.java:121` (`startPickingOrder`) | → `STARTED` |
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

**Unstick endpoint:** `controller/rest/AdviceRestController.java:732` (`reopen`, re-checked 2026-08-06; was documented as :648) — moves an Advice back from `FINISHED`/`CLOSED` to `OPEN`. **Only explicit reopener in the catalog**.

### 4.8 `Adviceposition` — String state

Same `AdviceState` values as Advice. Write sites: `ReceivingService:240,292`, `AdviceService:220`, `AdviceRestController:276,448,606`, `FileImportController:465`, and **`ReturnAdviceAutoReceiveService.markFinished` (SBDEV-2778)**.

> **SBDEV-2778 — a RETURN advice can reach FINISHED without a dock scan.** `markFinished` flips both
> `Adviceposition` and `Advice` to `FINISHED` in ONE `tenantTransactionManager` transaction, from the
> `/rest/advice/create` request thread, gated on the default-ON `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`
> sysprop. Both flips are bulk `WHERE advice_id = ?` (`AdvicepositionRepository:31`,
> `AdviceRepository:30`), so they cannot distinguish received from unreceived positions — which is why
> the caller refuses to build a plan whose line count differs from the persisted position count.
> They run only after every position's `receiveGoods` succeeded. This supersedes SBDEV-2236, which had
> removed the behavior; see 📕 [wms2-receiving-putaway-workflow §3.5](../workflows/wms2-receiving-putaway-workflow.md).

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

> ⚠️ **Anchors in §5 were re-checked 2026-08-06 and MOST WERE WRONG.** Every method
> name and line number below has been re-derived against `origin/develop` (`169065c`)
> except where explicitly marked unresolved. **Do not trust any §5 line number that
> predates this note.** The catalog's `last_verified` is 2026-05-08 and this was a
> scoped anchor sweep, not a full content re-verification — the *behavioural* claims
> below (which states cascade to what) were **not** re-derived and may also have drifted.

### 5.1 `CustomerorderService.cancelOrder()` — **:655** (was documented as line 300)
Cascades `CANCELED` to:
- `Customerorder.state` (**:754**)
- `Pickingorder.state` (via position linkage) — note **:724** sets `PROCESSABLE`, not `CANCELED`
- `PickingorderUnitload.state` (**:729**, was documented as line 305)

⚠️ `handleRapidPickingForCancelledOrder` — **no longer exists under that name**; the
rapid-picking release is now inline in the `cancelOrder` body around :724. The old
reference (`CustomerorderService:645`) resolves to `clubRunCancellationBlockingState`
(:636) / its call site (:671), which is a different concern entirely.
See `Cancel_Order_Null_SectionId_And_Early_Return_Fix` for why the null-check matters.

### 5.2 `CustomerorderService.packageOrder()` — **:506** (was documented as `pack()` at line 485)
The method was **renamed**; `pack(` does not exist anywhere in v2.
Sets `Customerorder → PACKED`. The `PACKED`/`PALLETIZED` double-apply guard that was the
root cause of `Cancel_Club_Parcels_Packed_State_Fix` is at **:415** (was documented as :382).
⚠️ The "via line 517 → `PickingorderUnitload → FINISHED`" claim was **not** re-verified.

### 5.3 `ParcelMonitorViewService.palletise()` — **:103**, and `palletiseAndTruckLoad()` — **:235**
(was documented as `palletizeOrders()` at lines 156, 283)
⚠️ **The code uses the British spelling `palletise`.** That is why the documented name
never resolved — and why a `grep palletize` returns nothing and reads as "this was deleted".
Sets `Customerorder → PALLETIZED`. Followed by the post-commit hook in the same file to
notify OMS (§6 in the [transaction boundary map](./wms2-transaction-osiv-boundary-map.md)).

### 5.4 ~~`BillofladingService.finishClubRun()` (lines 744, 749)~~ — **METHOD DOES NOT EXIST**

⚠️ **UNRESOLVED — needs re-derivation before this section is trusted.** As of 2026-08-06,
`finishClubRun` appears **nowhere in v2, and nowhere in v1 either** (`grep -rn finishClub`
over both `src/` trees returns zero hits, in main *and* test). The nearest surviving method
on `BillofladingService` is `finishTransfer` (:1272), which is a different flow.

Club-run finishing was refactored out of `BillofladingService`: the live path is
`CustomerorderBatchService.runClubLine` → `ClubLineOrderProcessor` (extracted per that
class's header comment; see also SBDEV-2381 in the
[transaction boundary map](./wms2-transaction-osiv-boundary-map.md) §7, which documents up to
three per-CO `outboxService.enqueue` calls in `finalizeClubLine`).

The behavioural claim below may still hold at the new location, but **it was written against
a method that no longer exists and has not been re-confirmed**:

> Sets `Customerorder → PACKED` **and** `CustomerorderBatch → ORDER_BATCH_CLUB_RUN_FINISHED`
> in the same transaction. Notable because it sets `PACKED` on the order even though the order
> itself wasn't packed in this method — the batch-level finish is a claim about all children.

Whoever next touches club-run state should re-derive this section against
`ClubLineOrderProcessor` + `CustomerorderBatchService` and replace this block.

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
| Club-run error recovery | `service/CustomerorderBatchService.java:709` | Rolls back from `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` to `originalState` on exception |

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
10. **`CustomerorderBatchService:709` revert-to-originalState.** The only "revert" pattern in the codebase. It's narrowly scoped to club-run failures. Do not generalize it to a reusable helper — the caller-specific context is what makes it safe.

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
| 2026-08-29 | **PARTIAL — §4.1 and §4.2 write-site tables fully rebased; the rest of the doc NOT re-verified.** Extracted all 74 citations and machine-checked them against `origin/develop` at `e5daa8ca`. | ⚠ **Read this before trusting any anchor here: this doc's parenthetical names are sometimes DESCRIPTIVE LABELS, not declared methods.** `PickingOrderMergeService` has taken **0 commits** since the last verification yet cites `:127` (`cancelOrderIfMergeFails`) and `:161` (`mergeOrders`), neither of which is a declared method — both are lines *inside* `mergePickingOrders` (:46). Four successive automated checks each mis-read that convention as "method deleted", so the untouched citations below **cannot be machine-swept** and need per-citation reading. **Rebased and re-verified against code (24 anchors):** `CustomerorderService` `239-244 (createForRelease)`→**285,290-291 (`setPickingDate`)** (`createForRelease` does not exist; `:239` is an unrelated method), `485 (pack)`→**557 (`packageOrder`)**, `351/675 (cancel)`→**356,361 (`checkAndCleanUpPickingOrderPositions`) / 408,415 (`updateOrderPositions`)** with the public entry `cancelOrder` at **:690**; `ReleaseOrderJobService` `643,647 (releaseOrderAndPosition)`→**196,395,440,454 / 723 (`releaseOrder`)** — that method name does not exist either; `TransferOrderService` `96,110,124,132`→**100,155,163 / 115 / 132** with all four enclosing methods named; `PickingorderBusinessService` `238,241,343,502`→**249,252 (`finishPickingOrder`) / 419 (`cleanUpCancelledOrder`) / 594 (`confirmPick`)**; `ParcelMonitorViewService` `156,283 / 401`→**193,345 / 465**; `MobilePalletizingService` `220`→**269,421**; `MobileTruckLoadingService` `304`→**306 (`scanGate`)**; `BillofladingService` `481`→**503,546 (`closeBOL`)**; `UtilRestController` `960`→**1092,1095,1099 (`resetOrdersInReleasedStatus`)**; `CustomerorderBatchService` `427`→**474 (`activateOrderBatch`)**, `606`→**628 (`validateClubLine`)**, `689`→**716 (`finalizeClubLine`)**, `434`→**479**, `279,339`→**260**, `358`→**393**; and `startPicking`→**`startPickingOrder`**. Every rewritten anchor re-verified to contain the state token the row claims. **STILL STALE, not fixed:** §4.1's four guard citations (`OrderRestController:180`, `CustomerorderService:471`, `:382,554`, `:639`) — these are interpretive prose claims, not state writes, and need a human read; and §4.3 onward plus §5's cascades were not audited at all. **`last_verified` deliberately NOT bumped — it stays at 2026-05-08.** | Code read on `origin/develop` + machine citation sweep, every replacement re-verified |
| 2026-04-19 | All state field declarations, `WmsConstants.State` + `AdviceState` + `BillOfLadingState` + `CycleCountState` values, write-site inventories (~160 total), primary guards, cascade methods, recovery endpoints | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-08 | Group T (transfer-order) churn — `TransferOrderService.unlinkTransferLaneFromTransferOrder` resets state to `CUSTOMER_ORDER_ACTIVATED` on lane unlink (commit 24280b0); Group P picking lines shifted +1 (`finalizePicking` now 238–569; cascade table updated); rapid-pick recovery cite confirmed at line 645 (guard at 639); SBDEV-2164 stale club batch cleanup adds JobLockId.STALE_CLUB_BATCH_CLEANUP but does not introduce new state values for `CustomerorderBatch` (cancel transitions remain through `cancelBatch`); §4.6 Replenishorder unaffected; receiving repository `findByStateAndItemdataId` confirmed live in `ReplenishorderRepository.java:46` (only used by job paths, no new state added). | All write-site lines re-confirmed; minor +1 drift in `PickingorderBusinessService` updated. | Code read (grep-based) |
| 2026-08-03 | §4.8 `Adviceposition` write sites: added `ReturnAdviceAutoReceiveService.markFinished` (SBDEV-2778) + the RETURN-reaches-FINISHED-without-a-dock-scan note | Only §4.7/§4.8 re-verified; the ~160-site inventory elsewhere was **not** re-counted, so `last_verified` stays at 2026-05-08 | Code read (SBDEV-2778 diff) |

| 2026-08-06 | **§5 cross-entity cascade anchors + §4.7 reopen endpoint.** Cadence sweep prompted by SBDEV-2731 (which touches none of this surface — its diff contains zero `setState`/`AdviceState`). **Most §5 anchors were wrong**, including three where the documented *method name* no longer resolves at all. | Corrected against `origin/develop` (`169065c`): §5.1 `cancelOrder` 300→**655** (child writes :724/:729/:754; `handleRapidPickingForCancelledOrder` no longer exists — now inline, and the old :645 cite now lands on unrelated club-run code); §5.2 `pack()`→**`packageOrder()` :506**, guard :382→**:415**; §5.3 `palletizeOrders()`→**`palletise()` :103 / `palletiseAndTruckLoad()` :235** — the code uses the **British spelling**, which is why the old name read as deleted; §4.7 `reopen` :648→**:732**. §5.4 `finishClubRun` **exists in neither v1 nor v2** and is flagged UNRESOLVED in place. **Anchors only — the ~160-site write inventory and every behavioural claim were NOT re-derived, so `last_verified` stays at 2026-05-08.** | Code read (grep-based, SBDEV-2731 doc sweep) |

| 2026-08-14 | **`CLIENT_HAS_NO_SECTION (45)` acquired its first writer** (SBDEV-2961, branch `feature/SBDEV-2961-order-release-silent-section-exclusion`). Corrected §2's table row and the §3 diagram, both of which described 45 as a live "stuck" state. It was not: `git log -S CLIENT_HAS_NO_SECTION` returns only the initial check-in (constant, **no writer**) and SBDEV-1656 `d6f28cbf`, which *added two reads* of a structurally unreachable state — so that half of SBDEV-1656 has been dead code since 2025-10-28 and is reachable for the first time now. New writer: `OrderReleaseJob.processOrderGroup` → `ReleaseOrderJobService.markClientHasNoSection` (a `@Modifying` CAS in a `REQUIRES_NEW` tx; the allow-list `state IN (RAW, FUTURE_PICKING_DATE)` means 45 can overwrite only those two, deliberately **not** hold states 50/55-58). Also note `OrderReleaseJob:188`'s pre-round gate now excludes 45. **Scoped touch only** — §2 row, §3 diagram and this entry were verified against the branch; the ~160-site write inventory and every other behavioural claim were **NOT** re-derived, so `last_verified` deliberately stays at 2026-05-08. | §2 state row + §3 diagram corrected against the SBDEV-2961 branch | Code read + `git log -S` archaeology |

**Re-verify every 60 days** — state surface drifts quickly. Next due: 2026-07-07. 🔴 **30 days overdue as of 2026-08-06, and the 2026-08-06 anchor sweep found §5 substantially rotted** — three of five cascade methods had names that no longer resolve. Treat a full re-derivation of §5 and the ~160-site inventory as owed work, not optional; the two scoped touches since 2026-05-08 do not substitute for it.
