---
title: "WMS v2 — State Machine Catalog"
type: architecture
status: active
version: v2
scope: state-machines
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: code read of v2/wms2-api src/main at origin/develop df30fa62 (full re-derivation, 2026-11-11)
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
**Owner:** Nam Park · **Last verified:** 2026-11-11 (code read against `src/main/java` at `origin/develop` `df30fa62`)

---

## 1. Overview

`wms2-api` has **no Spring StateMachine and no custom state-machine framework** — every entity's lifecycle is a plain Integer or String field on the entity, mutated by `setState(...)` calls scattered across ~160 write sites in ~30 services (re-counted 2026-11-11: **161** non-comment `.setState(` lines in **32** files under `src/main/java`, of which 2 are DTO setters — `ViewDtoService:474`, `MobileInfoService:259` — plus a handful of bulk JPQL `UPDATE … SET state` queries such as `CustomerorderRepository.updateStateByIds` / `markClientHasNoSection` / `releaseDueFutureTransferOrders`). Transition legality is enforced only by ad-hoc guards (`if (order.getState() == X)`) at each call site, so the same guard is typically repeated 3–6 times, and drift between copies is the root cause of half the "stuck state" / "cancel in wrong state" bugs in the archive.

This doc is the authoritative map: every entity with a lifecycle field, every state value it can take, where transitions are written, and which guards protect each transition. Use it to avoid adding the N+1 copy of an existing guard.

---

## 2. The Two Type Systems

### 2.1 Integer states — `WmsConstants.State.*`

Defined at `net/aim_ai/wms/service/WmsConstants.java:40-205` (class `State`; constants :48-147, `getCodeText` below them). All 25 values in the table below re-checked 2026-11-11 — unchanged. Numeric values are **ordered** — the code uses `>=` / `<` comparisons as a monotonic-progress check (e.g. "position must have progressed past `RESERVED`"), which makes the numeric spacing a hidden contract. **Do not renumber constants**; add new states in gaps.

| Constant | Value | Meaning |
|---|---|---|
| `RAW` | 0 | Initial / unprocessed |
| `CLIENT_HAS_NO_SECTION` | 45 | Blocked — the **order's client** (`co.client_id`) has no Section configured, so no `Pickingorder` can be created. **Writer:** `OrderReleaseJob.processOrderGroup` → `ReleaseOrderJobService.markClientHasNoSection` (:970; bulk CAS `CustomerorderRepository.markClientHasNoSection` :285, allow-list `RAW`/`FUTURE_PICKING_DATE`) (SBDEV-2961, 2026-08-14). **Exit:** `ReleaseOrderJobService.releaseOrder` accepts 45 alongside `RAW`/`FUTURE_PICKING_DATE` and moves it to `RAW_ON_HOLD` (:257-260, :605-606) or onward to `ASSIGNED` (re-checked 2026-11-11). ⚠ Before that ticket this state had **no writer at all** and was structurally unreachable, so any doc, diagram or code branch predating it that treats 45 as a live state was describing an intent, not behaviour |
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

String states are stored as plain `String` columns (no enum, no DB-level constraint — re-checked 2026-11-11: no `CHECK` on any `state` column under `src/main/resources/db/`). Nothing prevents a typo from being persisted.

Two string values have **no Java writer at all** (re-checked 2026-11-11): `BillOfLadingState.CANCELLED` (read in guards at `BillofladingService:1623`, `BillofladingPositionService:173`, `MobileTruckLoadingWriteService:528`, `MobileTruckLoadingService:107`, but never `setState`) and `CycleCountState.STARTED` (read at `CyclecountService:139,155` and `MobileCycleCountService:362,382,458,557`, never written). Rows in those states can only come from SDR/REST writes, SQL, or v1-era data — ⚠ unverified 2026-11-11 which of those, if any, actually produces them.

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

  Terminal:       CANCELED(800)  ← reachable only through cancelOrder's guards (see caveats)
```

**Diagram caveats (re-derived 2026-11-11 at `df30fa62`):**
- `55/56/57/58` are **`CustomerorderPosition`** hold reasons only (`ReleaseOrderJobService.releaseOrder` :209-583). A `Customerorder` itself goes only to `RAW_ON_HOLD(50)` (:260, :606), from `RAW`, `FUTURE_PICKING_DATE` or `CLIENT_HAS_NO_SECTION`.
- `FUTURE_PICKING_DATE → RAW` also happens in bulk for transfer orders: `ReleaseOrderJobService.releaseDueFutureTransferOrders` (:993) → `CustomerorderRepository.releaseDueFutureTransferOrders` (:313) and the position twin (`CustomerorderPositionRepository:152`).
- `CUSTOMER_ORDER_ACTIVATED(505)` is **no longer an entry state**. `activateTransferOrder` was deleted (SBDEV-3183, `2910a9aa`), and `activateAndAssignTransferLane` goes straight to 510 in one save (`TransferOrderService:155`). 505 is written only by `unlinkTransferLaneFromTransferOrder` (:124), as a 510 → 505 step back.
- `CANCELED` is **not** reachable from every non-terminal state. `CustomerorderService.cancelOrder` refuses orders at `FINISHED` or beyond (`isShippedOrPastCancellationBoundary` :769), refuses `PACKED`/`PALLETIZED` unless WMS-initiated or a pre-QA CLUB order (:928-937), and refuses CLUB batches mid-run (`clubRunCancellationBlockingState` :810). ⚠ unverified 2026-11-11: whether a `LOADED_TO_TRUCK(680)` order can be cancelled. It passes all three order-state guards above, so the outcome depends on its positions' states (:941 refuses any position at `PACKED` or beyond) and on `canOrderPositionBeCancelled`, which were not traced.

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
| **Field** | `state` (Integer, `@NotNull`, **no initializer**: the field is `private Integer state;` at :20, unlike every other Integer-state entity, so creators must set it explicitly, e.g. `OrderBatchCreationService:123,139`. Corrected 2026-11-11; this row said "default `RAW`") |
| **States reachable** | `RAW`, `CLIENT_HAS_NO_SECTION`, `RAW_ON_HOLD`, `FUTURE_PICKING_DATE`, `ASSIGNED`, `STARTED`, `CUSTOMER_ORDER_ACTIVATED`, `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`, `PENDING`, `PICKED`, `PACKED`, `PALLETIZED`, `LOADED_TO_TRUCK`, `FINISHED`, `CANCELED`. (2026-11-11: added 45 and 50, which have writers. ⚠ `PROCESSABLE` and `RESERVED` have **no `Customerorder` writer** in `src/main` and were removed from this list; those are `Pickingorder` states) |
| **Write sites** | ~28 `setState` calls plus 3 bulk JPQL updates (2026-11-11). Writers: `CustomerorderService`, `PickingorderBusinessService`, `ReleaseOrderJobService`, `TransferOrderService`, `BillofladingService`, `OrderBatchCreationService`, `ParcelMonitorViewService`, `MobilePalletizeWriteService`, `MobileTruckLoadingWriteService`, `AdviceService` (hub-and-spoke creation), `UtilRestController`, `CustomerorderBatchService` (bulk) |
| **Cascade on cancel** | Yes — see §5.1 |

**Key write sites:**

*(All rows re-derived 2026-11-11 at `origin/develop` `df30fa62`; line numbers churn, so trust the method name over the line.)*

| Location | Transition |
|---|---|
| `service/CustomerorderService.java:348,353` (`setPickingDate`, declared :309; routes `POST /v3/customerOrder/setPickingDate` and `/pickingDateBatchUpdate` via `batchUpdatePickingDate` :269) | → `RAW` / `FUTURE_PICKING_DATE` |
| `service/OrderBatchCreationService.java:123,139` (order creation) | initial `RAW` / `FUTURE_PICKING_DATE` |
| `service/job/ReleaseOrderJobService.java:260,606` / `:754` (`releaseOrder`, declared :134) | → `RAW_ON_HOLD` / `ASSIGNED`. (Corrected 2026-11-11: the `STARTED` write in this method, :758, is on the **`CustomerorderBatch`**, not the order. The old anchors 196/395/440/454 were `CustomerorderPosition` writes) |
| `service/job/ReleaseOrderJobService.java:970` (`markClientHasNoSection`) / `:993` (`releaseDueFutureTransferOrders`); both bulk JPQL, `REQUIRES_NEW` | → `CLIENT_HAS_NO_SECTION` / `FUTURE_PICKING_DATE → RAW` |
| `service/TransferOrderService.java:109,155,163` / `:124` | → `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` (`assignTransferLaneToTransferOrder` :90, `activateAndAssignTransferLane` :130, `assignTransferLane` :161) / `CUSTOMER_ORDER_ACTIVATED` (`unlinkTransferLaneFromTransferOrder` :118; Group T port v1 5ada0b0 / v2 24280b0: unlinking a lane resets 510 → 505). **`activateTransferOrder` was deleted** (SBDEV-3183 AC-6, `2910a9aa`); `activateAndAssignTransferLane` now lands 510 directly and never persists 505 |
| `service/PickingorderBusinessService.java:380,383` (`finishPickingOrder` :166) / `:857` (`cleanUpCancelledOrder` :758) / `:1437`, `:1488,1491` (`confirmPick` :1213) | → `PENDING` / `PICKED` / `CANCELED` / `STARTED`, then `PENDING`/`PICKED` |
| `service/CustomerorderService.java:696` (`packageOrder`, declared :680) | → `PACKED` |
| `service/BillofladingService.java:1006` (`transferOrder` :910, route `GET /runTransfer/{orderId}` in `TransfersController:255`) | → `PACKED` (see §5.4) |
| `service/CustomerorderBatchService.java:878` (`finalizeClubLine` :876); bulk `updateStateByIds`, skips `CANCELED` | → `PACKED` (club run, see §5.4) |
| `service/ParcelMonitorViewService.java:327` (`palletise` :77) | → `PALLETIZED`. **`palletiseAndTruckLoad` was deleted** (SBDEV-2620, `fd87a502`, "dead since the initial v2 check-in") |
| `service/mobile/MobilePalletizeWriteService.java:664` (`advanceOrderToPalletized` :662, called from `scanPallet` :392 and `scanParcelBulk` :580); only when `state < PALLETIZED` | → `PALLETIZED`. **Moved out of `MobilePalletizingService` by SBDEV-3398** (`f7032ac4`); `MobilePalletizingService` no longer writes state |
| `service/AdviceService.java:262` (`acceptHubAndSpokeAdvice` :173) | creates a `Customerorder` **directly at** `PALLETIZED` (hub-and-spoke inbound) |
| `service/mobile/MobileTruckLoadingWriteService.java:708` (`scanGate` :371); only when `state < LOADED_TO_TRUCK`. **Moved out of `MobileTruckLoadingService` by SBDEV-3418**, which split the method into a non-transactional outer service and this `@Transactional` write half. Since `palletiseAndTruckLoad` was deleted, this is the **only** `LOADED_TO_TRUCK` writer | → `LOADED_TO_TRUCK` |
| `service/BillofladingService.java:605` (`runShippingPhase` :450, called from `closeBOL` :348/:358) | → `FINISHED` |
| `service/CustomerorderService.java:1132` (`cancelOrder` :899, direct branch) / `:502,561` (`forceCancelOrder` :462, PACKED/PALLETIZED branch) / `service/PickingorderBusinessService.java:857` (`cleanUpCancelledOrder`) | → `CANCELED`. (Corrected 2026-11-11: `checkAndCleanUpPickingOrderPositions` (:367) writes `Pickingorder`/`PickingorderUnitload`, not the order, and runs on **picking-date change**, not cancel. `updateOrderPositions` (:448) writes `CustomerorderPosition`) |
| `controller/rest/UtilRestController.java:1116` (`resetOrdersInReleasedStatus` :1104; also resets the batch :1119 and positions :1123) | `ASSIGNED` → `RAW` |

**Key guards:**
*(Re-derived 2026-11-11. The old `OrderRestController:180` cancel guard no longer exists: `cancelPositions` (:606) delegates straight to `cancelOrder` (:647), and the cancel gating now lives entirely in `CustomerorderService`. `OrderRestController:197-198` is now an unrelated transfer-id re-import check, `existsByTransferidAndStateNotIn(…, [FINISHED, CANCELED])`.)*
- `CustomerorderService.cancelOrder` (:899), in order: `isAlreadyCancelled` (:905) **returns silently** (idempotent) → `clubRunCancellationBlockingState` (:915) throws for a CLUB batch at 527, or at 520/525 with a parcel → `isShippedOrPastCancellationBoundary` (:923, helper :769) throws if `state >= FINISHED && != CANCELED`, or if the parcel or its stock is at lock 405 → `isPackedOrPalletized` (:928, helper :764) routes 650/670 to `forceCancelOrder` when WMS-initiated or a pre-QA CLUB order, else throws → any position `>= PACKED && < CANCELED` throws (:941).
- `CustomerorderService.packageOrder:682`: **throws unless `state == PICKED`**. The code is `if (getState() != PICKED) throw …`, so "pack only if PICKED" is the right reading; the old "pack only if `!= PICKED`" text described the throw condition. ⚠ The exception message ("Order is not in status PACKED. can not be cancelled anymore") is wrong for a pack operation, so don't grep by it.
- `CustomerorderService:764` (`isPackedOrPalletized`): the packed/palletized check used to divert cancel, see `Cancel_Club_Parcels_Packed_State_Fix` (was cited as :382,554).
- `CustomerorderService:984`: the rapid-pick path fires iff the section is `RAPID_PICKING` `&& state == ASSIGNED && historytote != null` (was cited as :639). The in-code comment calls this arm "dead estate-wide" (no RAPID_PICKING section carries orders), but it is data-armed.

### 4.2 `CustomerorderBatch` — Integer state

| | |
|---|---|
| **Entity** | `model/CustomerorderBatch.java:22` |
| **States reachable** | `RAW`, `STARTED`, `ORDER_BATCH_ACTIVATED`, `ORDER_BATCH_STAGING_LANE_ASSIGNED`, `ORDER_BATCH_CLUB_RUN_IN_PROGRESS`, `ORDER_BATCH_CLUB_RUN_FINISHED`, `FINISHED`, `CANCELED` |
| **Write sites** | 14 `setState` calls (2026-11-11): 8 in `CustomerorderBatchService`, plus `ClubRunJobService:224`, `BillofladingService:1011`, `ReleaseOrderJobService:758`, `AdviceService:228`, `OrderBatchCreationService:74`, `UtilRestController:1119`. **`OrderRestController` writes no batch state** (corrected; it was listed here) |

**Key transitions** (re-derived 2026-11-11 at `df30fa62`):

| Location | Transition |
|---|---|
| `service/OrderBatchCreationService.java:74` | initial `RAW` |
| `service/job/ReleaseOrderJobService.java:758` (`releaseOrder` :134) / `service/AdviceService.java:228` (`acceptHubAndSpokeAdvice`) | → `STARTED` |
| `service/CustomerorderBatchService.java:429` (`activateOrderBatch`, declared :423; refuses when already `>= ORDER_BATCH_ACTIVATED`, :417) | → `ORDER_BATCH_ACTIVATED` |
| `service/CustomerorderBatchService.java:436` (`assignStagingLane` :434) / `:1270` (`assignStagingLaneToOrderBatch` :1246) | → `ORDER_BATCH_STAGING_LANE_ASSIGNED` |
| `service/CustomerorderBatchService.java:713` (`validateClubLine` :695) / `:839` (the lease-taking `validateClubLine` overload :818, used by the club-run job worker) | → `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` |
| `service/CustomerorderBatchService.java:899` (`finalizeClubLine` :876; lease wrapper :860) | → `ORDER_BATCH_CLUB_RUN_FINISHED` |
| `service/BillofladingService.java:1011` (`transferOrder` :910) | → `ORDER_BATCH_CLUB_RUN_FINISHED` (transfer run, see §5.4) |
| `service/CustomerorderBatchService.java:1126` (`rollbackClubLineState` :1121, only if still at 527) | → `originalState` (rollback from an inline club run) |
| `service/ClubRunJobService.java:224` (`failJob` :212, only if still at 527) | → the job's `original_batch_state` (rollback from a **job-driven** club run; added since the last verify) |
| `service/CustomerorderBatchService.java:395` (`finalizeBatchIfComplete` :383; called from `CustomerorderService:602,1153`, `PickingorderBusinessService:885`, `StaleClubBatchCleanupJobService:78`) | → `CANCELED` if all children are cancelled, else `FINISHED` |
| `controller/rest/UtilRestController.java:1119` (`resetOrdersInReleasedStatus`) | → `RAW` |

⚠ **`CustomerorderBatch` has no direct cancel write any more (SBDEV-3354, 2026-09-14).** This table
carried a row `CustomerorderBatchService.java:260` (`cancelBatch`) → `CANCELED`; that method had no
route and no caller and was deleted. A batch now reaches `CANCELED` **only by rollup** — every order
is cancelled individually via `OrderRestController.cancelPositions` → `CustomerorderService.cancelOrder`,
and `finalizeBatchIfComplete` then observes that all children are terminal. Consequence for anyone
reasoning about this state machine: **the batch transition is not atomic with its orders**, and a
partially-cancelled batch is a reachable intermediate state.

**Guard:** `CustomerorderBatchService:700-701` (in `validateClubLine` :695) and `:831-832` (overload :818): club run start requires `ORDER_BATCH_ACTIVATED` OR `ORDER_BATCH_STAGING_LANE_ASSIGNED` (was cited as :557; re-checked 2026-11-11). `cancelBatch` is still absent (0 hits in `src/main`).

### 4.3 `Pickingorder` — Integer state

| | |
|---|---|
| **Entity** | `model/Pickingorder.java:23` |
| **States reachable** | `RAW`, `PROCESSABLE`, `RESERVED`, `STARTED`, `PICKED`, `FINISHED`, `CANCELED` |
| **Write sites** | 24 (2026-11-11): `MobilePickingService` 12, `PickingorderBusinessService` 4, `CustomerorderService` 3, `PickingOrderMergeService` 2, `ReleaseOrderJobService` 1, `CustomerorderPositionService` 1, `OrderMonitorViewService` 1 |

**Key transitions:**

| Location | Transition |
|---|---|
*(Re-derived 2026-11-11 at `df30fa62`. Parenthesised names are **declared methods** unless marked "label".)*

| Location | Transition |
|---|---|
| `service/job/ReleaseOrderJobService.java:637` (`releaseOrder` :134; `releaseOrderAndPosition` never existed under that name) | → `PROCESSABLE` |
| `service/PickingOrderMergeService.java:161` (label "merge"; inside `mergePickingOrders` :46) | → `PROCESSABLE` |
| `service/mobile/MobilePickingService.java:404` (`claimPickingOrderAtomically` :392; was `reserveOrder`) / `:448` (`releaseClaimQuietly` :441, `RESERVED` → `PROCESSABLE` for the claimant) | → `RESERVED` / `PROCESSABLE` |
| `service/PickingorderBusinessService.java:150` (`startPickingOrder` :139) / `service/mobile/MobilePickingService.java:1361` (`rapidPickingConnectPackageAndType` :1283) / `service/OrderMonitorViewService.java:227` | → `STARTED` |
| `service/mobile/MobilePickingService.java:275,338,342,347` (`releasePickingOrder` :265; the old label `finishPicking` does not resolve) | → `PICKED` / `FINISHED` / `PROCESSABLE` / `CANCELED` |
| `service/mobile/MobilePickingService.java:247` (`resumePickingOrderIfExists` :208), `:371` (`startPickingOrder` :356), `:423` (`finalizePickingOrderForStart` :413), `:814` / `:863` (`releaseRegularPickingOrder` :766) | → `PICKED` when all picks are finished / `PROCESSABLE` (:863) |
| `service/PickingorderBusinessService.java:491` (`finishPickingOrder` :166; the old label `finalizePicking` does not resolve) | → `orderState`, a local seeded `CANCELED` (:214) and promoted to `FINISHED` (:305) if any line was picked |
| `service/PickingorderBusinessService.java:1531` (`confirmPick` :1213) | → `PICKED` when complete |
| `service/PickingorderBusinessService.java:745` (`finalizePickingOrderIfTerminal` :739) / `service/CustomerorderPositionService.java:208` | → `CANCELED` if all lines are cancelled, else `FINISHED` |
| `service/PickingOrderMergeService.java:127` (label "cancel if merge fails"; inside `mergePickingOrders` :46) | → `CANCELED` |
| `service/CustomerorderService.java:434` (`checkAndCleanUpPickingOrderPositions` :367; **picking-date change** clean-up of an order left with no lines) / `:519` (`forceCancelOrder` :462, unreachable `< PACKED` arm) / `:1032` (`cancelOrder` :899, rapid-pick side-door, `STARTED → PROCESSABLE`) | → `CANCELED` / `PICKED` / `PROCESSABLE`. (Corrected 2026-11-11: the old row placed the `CANCELED` write in `forceCancelOrder`; that write is not there) |

**Guards (hottest):**
- `MobilePickingService` operator-flow gates (2026-11-11): `claimPickingOrderAtomically:398,400` (`< RESERVED`, then `>= PICKED` throws `PICK_ALREADY_STARTED`); `releasePickingOrder:274,287,293,299` (`<= PICKED`, `== PICKED`, `> PICKED`, pick `== PICKED` throws); `releaseClaimQuietly:446` (`== RESERVED`). The same `<= / == / > PICKED` triple is repeated in `resumePickingOrderIfExists:246-254`, `startPickingOrder:370-380` and `finalizePickingOrderForStart:422-429`.
- `AdminActionController.finishStuckPickingOrder` (`GET …/finishStuckPickingOrder/{number}`, :269): requires `Pickingorder == PICKED` (:285) and at least one `PickingorderUnitload == STARTED` (:296), then calls `finishPickingOrder`. (Was cited as `:182,193` "admin reset gates")

### 4.4 `PickingorderPosition` — Integer state

| | |
|---|---|
| **Entity** | `model/PickingorderPosition.java:28` |
| **States reachable** | Written in Java (2026-11-11): `RAW` (field default), `PROCESSABLE`, `PICKED`, `CANCELED`. ⚠ unverified 2026-11-11: `ASSIGNED`, `STARTED`, `PENDING`, which were listed here, have **no `PickingorderPosition` writer** in `src/main`. They may be historical or v1-era values; no data query was run |
| **Write sites** | 6 (2026-11-11): `PickingorderPositionService:79` (create → `PROCESSABLE`), `MobilePickingService:329` (`releasePickingOrder`, reset → `PROCESSABLE`), `PickingorderBusinessService:1386` (`confirmPick` → `PICKED`), `:708` (`cancelOpenPickLines` → `CANCELED`), `CustomerorderService:491` (`forceCancelOrder` → `CANCELED`), `CustomerorderPositionService:201` (→ `CANCELED`) |

Notable (corrected 2026-11-11): the three-way branch that writes `PICKED` / `STARTED` / `PENDING` is on **`CustomerorderPosition`**, not `PickingorderPosition`. It is in `PickingorderBusinessService.confirmPick` at :1410 / :1416 / :1418: `PICKED` when the picked amount covers the line, else `STARTED` if open picks remain, else `PENDING`. The method `finalizePicking` (cited here before) does not exist. Read `confirmPick` carefully before modifying it.

### 4.5 `PickingorderUnitload` — Integer state

| | |
|---|---|
| **Entity** | `model/PickingorderUnitload.java:21` |
| **States reachable** | `RAW`, `STARTED`, `PICKED`, `FINISHED`, `CANCELED` (re-checked 2026-11-11) |
| **Write sites** | 7 (2026-11-11): `PickingorderBusinessService:1502` (`confirmPick` → `STARTED`), `:449` (`finishPickingOrder` → `PICKED`), `:947` (`cleanUpCancelledOrder` → `CANCELED`); `CustomerorderService:728` (`packageOrder` → `FINISHED`), `:439` (`checkAndCleanUpPickingOrderPositions` → `CANCELED`), `:1037` (`cancelOrder` rapid-pick → `CANCELED`), `:1113` (`cancelOrder` tote teardown → `CANCELED`). Created by `PickingorderUnitloadService:31` and `OrderMonitorViewService:203` |

Cancel cascade from `Customerorder` goes through this entity — see §5.1.

### 4.6 `Replenishorder` — Integer state

| | |
|---|---|
| **Entity** | `model/Replenishorder.java:25` |
| **States reachable** | `RAW`, `PROCESSABLE`, `STARTED`, `FINISHED`, `CANCELED` |
| **Write sites** | 7 entity writes (2026-11-11) in `ReplenishGeneratorService` (2), `MobileReplenishService` (3), `ReplenishOrderJobService` (1) and `ReplenishmentOrderMaintenanceService` (1). `MobileReplenishService:541` is a DTO copy, not a write. **`ReplenishorderService` no longer writes state directly**; it delegates to `markCancelled` |

**Key transitions** (re-derived 2026-11-11 at `df30fa62`):

| Location | Transition |
|---|---|
| `service/ReplenishGeneratorService.java:319` (`calculateOrder` :228) / `:371` (`createOrderFromTemplate` :344); `generateReplenish` no longer resolves | → `PROCESSABLE` |
| `service/mobile/MobileReplenishService.java:601` (`startOrder(Long)` :581) / `:650` (`resetOrder(Long)` :635). **SBDEV-3626 is merged** (PR #454, merge `74a07a34`); the DTO-based `startOrder`/`resetOrder` were deleted by SBDEV-3608 | `PROCESSABLE` → `STARTED` (handheld claim, `operator_id` = caller) / `STARTED` → `PROCESSABLE` (holder release) |
| `service/job/ReplenishOrderJobService.java:298` (`releaseExpiredClaim` :289); SBDEV-3626, merged | `STARTED` → `PROCESSABLE` (claim not stamped for `REPLENISHMENT_CLAIM_TIMEOUT_SECONDS`) |
| `service/mobile/MobileReplenishService.java:344` (`finishReplenishmentOrderWithoutRefill` :223, private; called only from `fulfillMultipleUnitLoadsTx` :1025,1042, reached by `POST /v3/replenish/multi-unitloads`, `ReplenishController:256`) | → `FINISHED` |
| `service/ReplenishmentOrderMaintenanceService.java:960` (`markCancelled` :959). Callers: `ReplenishmentOrderMaintenanceService.cancelOrder` (:945), `ReplenishorderService.cancelReplenishmentOrder` (:417), and `StockunitService.applyCut` (:1354, a reservation-cut cancel) | → `CANCELED` |

### 4.7 `Advice` — **String state** (landmine)

| | |
|---|---|
| **Entity** | `model/Advice.java:54` (field; class at :10) |
| **Field type** | `String` (default `AdviceState.CREATED`) |
| **States reachable** | Written in Java (2026-11-11): `CREATED` (default), `OPEN`, `FINISHED`. ⚠ unverified 2026-11-11: `PROCESSING`, `CLOSED` and `CANCELLED` have **no `Advice` writer** in `src/main` |
| **Write sites** | 10 (2026-11-11): → `OPEN` in `ReceivingService:238` (`createAdviceWithPositions`), `AdviceRestController:299` (`create`), `:740` (`createTransfer`), `:876` (`createHubAndSpoke`) and `FileImportController:495` (`importInboundBols`); → `FINISHED` in `AdviceService:275` (`acceptHubAndSpokeAdvice`), `:326` (`close`), `:440` (`acceptTransferAdvice`), `ReceivingService:925` (`finishReturnAdviceIfComplete`) and `ReturnAdviceAutoReceiveService:1014` (`markFinished`) |

**~~Unstick endpoint~~ — corrected 2026-11-11: there is NO Advice reopener.** `controller/rest/AdviceRestController.java:992` (`reopen`, `POST …/reopen`) is a stub whose body is `throw new RuntimeException("method not supported"); // TODO`, and it has been unchanged since the initial check-in (`a685e07b`, 2024-07-16). Earlier versions of this doc called it "the only explicit reopener, `FINISHED`/`CLOSED` → `OPEN`". That was never true of v2. A finished advice has no sanctioned way back to `OPEN`.

### 4.8 `Adviceposition` — String state

Same `AdviceState` values as Advice (entity field `model/Adviceposition.java:46`). Write sites re-derived 2026-11-11: → `OPEN` at `ReceivingService:271,323` (`createAdviceWithPositions` / `updateAdviceWithPositions`), `AdviceRestController:551,771,938` (`create` / `createTransfer` / `createHubAndSpoke`) and `FileImportController:522`; → `FINISHED` at `AdviceService:248` (`acceptHubAndSpokeAdvice`) and `ReceivingService:922` (`finishReturnAdviceIfComplete`), plus the bulk `AdvicepositionRepository.updateAdvicepositionToStateByAdviceId` (:43) called from `AdviceService:330` (`close`), `:444` (`acceptTransferAdvice`) and **`ReturnAdviceAutoReceiveService.markFinished` :1016 (SBDEV-2778)**.

> **SBDEV-2778 — a RETURN advice can reach FINISHED without a dock scan.** `markFinished` flips both
> `Adviceposition` and `Advice` to `FINISHED` in ONE `tenantTransactionManager` transaction, from the
> `/rest/advice/create` request thread, gated on the default-ON `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`
> sysprop. The position flip is bulk `WHERE advice_id = ?` (`AdvicepositionRepository:43`); the advice
> flip was bulk too (`AdviceRepository.updateAdviceToStateById`, now :43, **0 callers** and
> `exported = false`) until SBDEV-3736 made it an entity save, see below. Re-checked 2026-11-11. The bulk position flip cannot distinguish received from unreceived positions — which is why
> the caller refuses to build a plan whose line count differs from the persisted position count.
> They run only after every position's `receiveGoods` succeeded. This supersedes SBDEV-2236, which had
> removed the behavior; see 📕 [wms2-receiving-putaway-workflow §3.5](../workflows/wms2-receiving-putaway-workflow.md).

> **SBDEV-3736 — **MERGED** to develop 2026-10-15 (PR #518, merge `a05e8998`, PR head `f6445546`; on dev).**
>
> - **`markFinished` now saves the Advice as an entity.** `advice.setState(AdviceState.FINISHED); adviceRepository.saveAndFlush(advice);`
>   so `advice.modified` bumps (the bulk JPQL it replaced left `modified = created`). The position flip is
>   unchanged: `advicepositionRepository.updateAdvicepositionToStateByAdviceId(AdviceState.FINISHED, adviceId)`.
> - **New write sites: `ReceivingService.finishReturnAdviceIfComplete(Advice)`** (public, `@Transactional`, joins the
>   caller's tx). Writes `position.setState(AdviceState.FINISHED); advicepositionRepository.save(position);` per
>   still-OPEN position, then `advice.setState(AdviceState.FINISHED); adviceRepository.save(advice);` — entity saves,
>   not bulk. Callers: end of `receiveGoods` (`finishReturnAdviceIfComplete(advice);` before the label print) and
>   `GoodsReceiptPositionService.adjust` / `.delete` (last statement of each).
> - **Rule: exact match.** Guard is `AdviceType.RETURN.equals(advice.getType())`, at least one position, and for **every**
>   position `receivedTotal.compareTo(notifiedamount) == 0` (null `notifiedamount` fails). Over-keyed stays OPEN, because
>   RETURN advices have `allowoverdelivery=true` and the advice must remain correctable.
> - **Consequence: a dock-received or adjusted RETURN advice can now reach FINISHED** — not only via `/rest/advice/create`
>   auto-receive. An over-key corrected down to exactly the notified amount (adjust or delete) finishes it.
> - **Locking:** OPEN sibling positions locked in ascending id order (`LockReads.forUpdate(... advicepositionRepository::findByIdForUpdate)`),
>   then totals re-read via `LockReads.reconcileLocked(...)`. A locked sibling that is FINISHED or missing throws
>   `ObjectOptimisticLockingFailureException` (rolls the caller back).
> - **Residual windows (per the method javadoc):** an adjust/delete of a sibling receipt that commits after the re-read
>   (adjust/delete take no position lock) can leave a FINISHED advice with a position off its notified amount; and two
>   receives into the **same put-away location** can deadlock (40P01, one aborted, operator retries).
> - **SBDEV-4107 ✓ merged(SBDEV-4107: #665 fd712d7a, 2026-11-12): the finisher now takes the ADVICE row lock first.**
>   `LockReads.forUpdate(entityManager, Advice.class, …, adviceRepository::findByIdForUpdate)` runs right after the RETURN
>   check, before the first completeness read. `receiveGoods` already holds that lock, because it locks the advice before
>   its position, so from a receive the call does not wait. Effects:
>   - Receives of one advice serialize, so the shared-location 40P01 above no longer happens *between receives of the same advice*.
>   - The "lost finish" (each of two concurrent completers misses the other's uncommitted line, and the advice stays OPEN
>     with every position exact) is closed for receive vs receive, receive vs correction, and correction vs correction.
>     Tests: `ReturnAdviceFinishRaceIT`, `ReturnAdviceCorrectionFinishRaceIT`.
>   - **Fails closed:** once it holds the advice lock, the finisher throws `ObjectOptimisticLockingFailureException` if the
>     locked advice is already FINISHED (or gone). A correction whose earlier OPEN check went stale therefore rolls back
>     instead of committing against a FINISHED advice. This closes the first bullet's stale-finish window for every write that
>     goes through the finisher; only a write that bypasses it (raw SQL) is not covered. Test: `ReturnAdviceStaleCorrectionRaceIT`.
>     A receive cannot trip this, because `receiveGoods` checks that the advice is OPEN under the same lock.
> - **No reopen path for RETURN:** `AdviceService.close` handles REGULAR only and adjust/delete require OPEN. (Corrected 2026-11-11: there is no reopen path for **any** advice type. `AdviceRestController.reopen` throws "method not supported", see §4.7.) "`close` handles REGULAR only" re-confirmed: `AdviceService:322-323` throws for any other type.
> - *Re-verified on `origin/develop` `df30fa62`, 2026-11-11:* `markFinished` (:1011) does `saveAndFlush` on the advice, then the bulk position update; `finishReturnAdviceIfComplete` is at `ReceivingService:881`, with callers `ReceivingService:642` (`receiveGoods`) and `GoodsReceiptPositionService:133,141`. The lock is `LockReads.forUpdate(entityManager, Adviceposition.class, id, advicepositionRepository::findByIdForUpdate)` over the **not-yet-FINISHED** positions in id order (:901), then `LockReads.reconcileLocked` over the `Goodsreceiptposition` rows (:908). That matches the note above.

### 4.9 `Billoflading` + `BillofladingPosition` — String state

| | |
|---|---|
| **Entity** | `model/Billoflading.java:24` / `model/BillofladingPosition.java:17` (fields) |
| **States reachable** | `CREATED` (default), `OPEN`, `TRUCK_LOADING`, `TRANSFER`, `CLOSED`. ⚠ `CANCELLED` is checked in guards but has **no Java writer** (see §2.2) |
| **Primary writer** | `service/BillofladingService.java` (re-derived 2026-11-11): `createEntity` :281 → BOL `OPEN` (:301); `runShippingPhase` :450 (from `closeBOL` :348/:358) → BOL positions `TRANSFER`/`CLOSED` (:589 pallet, :598 parcel, :645 stock position) and BOL (:775), where `bolState` is `TRANSFER` for `TRANSFER_INTRACOMPANY`, else `CLOSED` (:454); private `finishTransfer` :1658 → BOL `CLOSED` (:1667) plus a bulk position update to `CLOSED` (:1697-1702). **None of the previously cited methods (`openBillOfLading`, `updateBillOfLading`, `finalizeBillOfLading`, `finishClubRun`) exist** (0 hits each) |
| **Cross-writer** | `MobileTruckLoadingWriteService:589` (`scanGate` :371; SBDEV-3418 moved this write out of `MobileTruckLoadingService`; the state is decided as a `pendingState` predicate in PHASE C, :514/:520 → `TRUCK_LOADING`, and applied in PHASE D, :588-589, so the decision and the write are at different lines), `BillofladingPositionService:153` (`createEntity` :140 → position `TRUCK_LOADING`). **`ParcelMonitorViewService` no longer writes BOL state** (removed 2026-11-11; its only `setState` is the order → `PALLETIZED` at :327) |

#### 4.9.1 What counts as "shipped": several predicates, deliberately different (SBDEV-3494)

*(2026-11-11, partial re-check at `df30fa62`. Every named symbol below still resolves: `assertPalletNotShipped`, `assertParcelCarrierNotShipped`, `NOT_CLOSED_PREDICATE`, `gatedViolationReason`/`REASON_ALREADY_SHIPPED`, `removeBOLPositionIfExists`, `checkPallet`, `SCAN_GATE_FACADE`, `ShippedGuardSite`, `ReservationCut`/`REFUSE_LOCKED`, `SINK_LOCATIONS`, `CancellationReversalService`, `handleTruckOffLoading`. The `closeBOL` type switch (`BillofladingService:397-414`), the TRANSFER/CLOSED + 404/405 choice (:454-459) and `isShippedOrPastCancellationBoundary` (`CustomerorderService:769`) were re-read and match. The per-site predicate semantics and the data check were **not** re-derived.)*

**Read this before writing a new "is it shipped?" guard.** Choose the predicate from this table and name it in the guard's javadoc. There is no single `isShipped` helper, and that is on purpose. Unifying the guards would reverse SBDEV-3487 decision 2; Nam chose doc-only on 2026-10-06. (The only `isShipped*` method is the private `CustomerorderService.isShippedOrPastCancellationBoundary`.)

**How the states are written.**
- `BillofladingService.closeBOL` accepts REGULAR, TRANSFER_OFFSITE, HUB_AND_SPOKE and TRANSFER_INTRACOMPANY BOLs; it rejects CLUB and PICK_PACK.
- For a `TRANSFER_INTRACOMPANY` BOL it sets the BOL and its positions to `TRANSFER`. For the other accepted types it sets them to `CLOSED`.
- Both branches move the pallets and their child unit loads to the `Shipped` location and give them entity lock **404** (`TRANSFER`) or **405** (`SHIPPED`).
- The stock-unit lock update reaches only stock on the pallet's **child** unit loads (`WHERE s.unitloadId IN (SELECT u.id … WHERE u.carrierunitloadId IN :palletIds)`). Stock sitting directly on the pallet keeps its lock.
- Both branches set every order on the BOL to `FINISHED`.
- `finishTransfer` later rewrites a TRANSFER BOL to `CLOSED`, with lock 405 on the same rows.

The resulting nesting, **Shipped location ⇔ position CLOSED or TRANSFER** and **position CLOSED ⇔ lock 405**, is **observed in data, not enforced by code**. See the data check below.

**Guards (they refuse an action):**

| # | Predicate | TRANSFER counts? | Sites (origin/develop @ `69d6126a`) | Why it differs |
|---|---|---|---|---|
| P1 | pallet has a BOL position in `CLOSED` | **no** | `MobileTruckLoadingService.checkPallet` (`case …CLOSED: throw`); `BillofladingPositionService.assertPalletNotShipped`, called from the scanGate facade (`SCAN_GATE_FACADE`) and the four D0 backstops in `MobileMoveUnitloadService` (`ShippedGuardSite` `SCAN_GATE_D0*` and `MOVE_UNITLOAD_D0*`). Enforced at delete time by `BillofladingPositionRepository.NOT_CLOSED_PREDICATE`, which fences the D0 delete queries | SBDEV-3487 decision 2: a TRANSFER pallet stays **re-scannable at the gate**. The consequence: re-scanning a TRANSFER pallet onto another BOL lets D0 purge its TRANSFER position tree, because `NOT_CLOSED_PREDICATE` makes TRANSFER rows deletable (SBDEV-3487 §2.1, "purged legitimately") |
| P2 | a position in `CLOSED` **or** `TRANSFER` | **yes** | `BillofladingPositionService.assertParcelCarrierNotShipped` (parcel's carrier pallet), called from `ParcelMonitorViewService` (SBDEV-2507 Fix A), `MobilePalletizeWriteService` (2 sites) and `MobileMoveUnitloadService` (source-carrier check). Also `BillofladingPositionService.removeBOLPositionIfExists` (the parcel's own position): CLOSED throws `"already shipped!"`, while TRANSFER falls to `default:` and throws `"Unexpected status=TRANSFER found!"`, so it is rejected with a misleading message | Taking a parcel *off* a pallet. Once a pallet has left on a transfer, its contents are frozen, the same as for a closed BOL |
| P3 | unit load stands on the `Shipped` location | **yes** (both `closeBOL` branches move there) | `MobileMoveUnitloadService` source checks (`"Can not move unit load from "`, scanUnitLoad and scanDestination; SBDEV-3490) and destination check (`"Can not move unit load to shipped location:"`); `MobileMoveStockService`. Non-refusing P3 consumers (they filter or display, never reject): `StockUnitController` (Shipped excluded from the destination dropdown) and `MobileInfoService` (Shipped/Nirvana display) | The strongest physical test. On move-unitload, scanDestination's Shipped-source check runs **before** the only path to the `MOVE_UNITLOAD_D0` backstop (`handleTruckOffLoading`). So P1's TRANSFER exemption never opens a move out of Shipped |
| P3+ | destination's lock is not `NOT_LOCKED`, **then** the location is `Shipped` | **yes** (404 is a non-zero lock) | `DestinationEligibilityService.gatedViolationReason` (`REASON_ALREADY_SHIPPED`) | Rejects any lock first, so both 404 and 405 are refused before the location test runs |
| P4 | order state ≥ `FINISHED`, **or** parcel/stock lock == 405 | **yes**, through the order-state arm (`closeBOL` sets `FINISHED` in both branches) | `CustomerorderService.isShippedOrPastCancellationBoundary` | Behaves like P3 for any order that went through `closeBOL`. The lock-405 arm decides only orders still below `FINISHED` |
| P5 | stock-unit lock == **405** | **no** (404 passes) | `StockunitService` adjust-amount and adjust-reserved-amount guards; `ReservationCut.decide` (`REFUSE_LOCKED`); `CancellationReversalService` (the lock arm only: the same expression still refuses a stock unit holding stock whose container is not `OFF`). By contrast, `setLockDamaged` and remove-lock reject 404 through their `default:` arms | Not designed against TRANSFER. Exposure measured 2026-10-06: **1** stock unit at 404 on WineCo dev (`dev_wh01_om1`), **0** on Hydra PRD. ShipItEZ PRD not measured (the MCP role lacks the grant). Not filed; revisit if TRANSFER volume grows |

**Inventory and reporting (they count or hide stock; they do not refuse).** These split on TRANSFER stock, so the same 404 stock unit appears in some views and not others:

| Treats TRANSFER as… | Sites |
|---|---|
| **on hand / visible** (lock-405 exclusion only) | `stock_view.total_stock` (`V2.2.00__base_v2_schema.sql`, `entity_lock <> ALL (ARRAY[405, 2])`; the view also reports it in a separate `transfer` column); the lock report (`V2.2.02__lock_report_exclude_shipped.sql`, `<> 405`); the SBDEV-3500 grids (`StockunitRepository`, `entity_lock != 405`; `UnitloadRepository`, the container-popup query `NOT IN (405, 2)` and the grid query `!= 405`. In the two grid queries (`StockunitRepository` and the `UnitloadRepository` grid) the lock-2 half is lifted when "Show To Delete" is on; the popup has no toggle. The 405 half always applies); cycle-count candidates (`StockunitRepository.getStockUnitsBySkuSetAndAreaSetAndStates`, `NOT IN (:stateShipped, :stateDeleted)`) |
| **gone** (Shipped location excluded) | `OnHandQuantityService` (`SINK_LOCATIONS`); `ViewWarehouseLocationReportRepository` (`loc.name NOT IN ('Nirwana','Shipped')`) and the DB view `view_warehouse_location_report` (`V2.2.00`); `ReplenishOrderJob` (stock on Shipped does not count as stock to replenish) |
| **not yet shipped** (`bp.state = 'CLOSED'` only) | the stored functions `stock_history` (`V2.2.07`), `transaction_detail` (`V2.2.25`, earlier `V2.2.08`/`V2.2.12`) and `transaction_summary` (`V2.2.00`). A TRANSFER pallet is reported as shipped only after `finishTransfer` |

**BOL-level checks treat TRANSFER as closed:**
- `MobileTruckLoadingWriteService` PHASE C rejects a target BOL in TRANSFER, CLOSED or CANCELLED.
- `BillofladingService.setTrackingDeviceID` rejects TRANSFER and CLOSED.
- `closeBOL` rejects a BOL already in TRANSFER.
- The BOL export uses the CLOSED-only detail query, so a TRANSFER BOL exports the not-closed shape.

**How the sites were found.**
- `git grep` over `src/main` for `assertPalletNotShipped`, `assertParcelCarrierNotShipped`, `BillOfLadingState.(TRANSFER|CLOSED)`, `STORAGE_LOCATION_SHIPPED` and `BusinessObjectLockState.(SHIPPED|TRANSFER)`.
- `git grep` for raw `405`/`404` literals in the repositories and migrations.
- An independent review lane re-swept and added the reporting group, `DestinationEligibilityService`, `NOT_CLOSED_PREDICATE` and `removeBOLPositionIfExists`.
- **Remaining blind spots:** `"Shipped"` spelled as a bare string literal outside the queries above, and the `db/v1-to-v2-onboarding` views (`V1.0.02`/`V1.2.04`), which were not enumerated. Treat the lists as near-complete, not closed.

**Data check (2026-10-06):**
- **WineCo dev:** every CLOSED pallet position is on Shipped at 405 (15,887 pallets, 396,008 children). The single TRANSFER pallet is on Shipped at 404. TRUCK_LOADING positions are off Shipped at lock 0.
- **Hydra PRD:** all 52 CLOSED pallets are on Shipped at 405, and there are no TRANSFER rows.
- **Result:** among the guards (P1–P5) the predicates disagree only where the table says they should. The inventory/reporting group does disagree on 404 stock, as tabled above.

### 4.10 `Cyclecount` / `CyclecountPosition` — String state

Smaller lifecycle (`CREATED`, `STARTED`, `FINISHED`, `CANCELLED`). Not fully enumerated; treat as a follow-up if a bug in cycle-count flow surfaces. Write-site census (2026-11-11): `CyclecountService:94,118` (→ `CREATED`), `:157,169` (→ `CANCELLED`); `CyclecountPositionService:51` (→ `CREATED`); `MobileCycleCountService:190,247,451,470,528,577` (→ `FINISHED`). Fields: `model/Cyclecount.java:45`, `model/CyclecountPosition.java:24`, both with **no default**. ⚠ `STARTED` is never written (see §2.2).

### 4.11 Entities with NO state field

Explicitly verified absent — **do not add a state field without a design review**:

- `Stockunit` (`model/Stockunit.java`) has no `state`. It tracks `amount` + `reservedamount`, **plus `entityLock`** (`entity_lock`, :12-13). That lock column behaves as a lifecycle in practice (e.g. 404 `TRANSFER`, 405 `SHIPPED`, `PICKED_FOR_GOODSOUT`; see §4.9.1). Corrected 2026-11-11: this line said "only".
- `Unitload` (`model/Unitload.java`) is structural (label, type, storage location) **plus a nullable `entityLock`** (:12) with the same lock-state semantics.

---

## 5. Cross-Entity Cascades

State changes on a parent routinely mutate children in the same transaction. These cascades are manual and easy to miss when adding new cases.

> **§5 fully re-derived 2026-11-11 against `origin/develop` `df30fa62`, behaviour and anchors both.** This replaces the 2026-08-06 anchor-only sweep (`169065c`), whose
> banner warned that the behavioural claims were unverified. §5.4 is now resolved, not unresolved. Line numbers churn; trust the method names.

### 5.1 `CustomerorderService.cancelOrder()` — **:899** (was :655 on 2026-08-06, :300 originally)
Gate sequence: see §4.1 "Key guards". Then, for an order below `PACKED`, every non-cancelled position is tested with `canOrderPositionBeCancelled` (:963). If **any** position refuses, the order is **not** cancelled now (else-branch :1158): `cleanUpCancelledOrder` runs immediately if picking confirmation was already sent (:1161), otherwise the order is flagged `markedforcancellation = true` (:1163-1164) and cancelled later when its picking order finishes. If every position allows it, the **direct branch** (:975) cascades:
- `CustomerorderPosition` → `CANCELED`, via `customerorderPositionService.cancelOrderPosition` per open position (:1064-1068). That method also cancels the position's pick lines and settles a picking order whose lines are all terminal (`CustomerorderPositionService:201,208`)
- Rapid-pick side-door (:984, only for a `RAPID_PICKING` section `&& state == ASSIGNED && historytote != null`): the first position's `Pickingorder`, if `STARTED`, goes → **`PROCESSABLE`** (:1032), not `CANCELED`, and its pick-to `PickingorderUnitload`s → `CANCELED` (:1037)
- Tote teardown (SBDEV-3339, only when `pickingtote_id` is set): `PickingorderUnitload` → `CANCELED` (:1113) for every assignment `resolveAssignments` finds for this order on that tote; a failure throws `ToteTeardownException` (:1127)
- `Customerorder.state` → `CANCELED` (:1132); transfer lane cleared (:1147-1148)
- Batch rollup: `finalizeBatchIfComplete` (:1153), see §4.2; then one OMS cancellation signal (`enqueueCancellationSignal`, :1157)

The **PACKED/PALLETIZED branch** delegates to `forceCancelOrder` (:462). Its reachable arm (:555-561) cancels positions and the order and does not touch picking entities. Its `< PACKED` arm (:473-553) is commented in-code as unreachable from its sole caller.

✓ `handleRapidPickingForCancelledOrder` still does not exist; the rapid-pick release is inline at :984-1040. `clubRunCancellationBlockingState` is now at :810, called from :915.
See `Cancel_Order_Null_SectionId_And_Early_Return_Fix` for why the null-check matters (the section null-check is now at :980).

### 5.2 `CustomerorderService.packageOrder()` — **:680** (was :506 on 2026-08-06; documented as `pack()` at line 485 originally)
The method was **renamed**; `pack(` does not exist anywhere in v2.
Guards (2026-11-11): throws unless `state == PICKED` (:682) and refuses CLUB batches (:687-688). Sets `Customerorder → PACKED` (:696), moves the tote's stock onto a new package unit load, and sets every `PickingorderUnitload` that `resolveAssignments` returns for that tote and order → **`FINISHED`** (:728). That cascade is now verified; it was "not re-verified" before. The `PACKED`/`PALLETIZED` check that was the root cause of `Cancel_Club_Parcels_Packed_State_Fix` is now `isPackedOrPalletized` (:764), used by `cancelOrder` at :928 (was cited as :415 / :382).

### 5.3 `ParcelMonitorViewService.palletise()` — **:77** (was :103 on 2026-08-06; documented as `palletizeOrders()` at lines 156, 283 originally)
⚠️ **The code uses the British spelling `palletise`.** That is why the documented name
never resolved — and why a `grep palletize` returns nothing and reads as "this was deleted".
Sets `Customerorder → PALLETIZED` (:327). The OMS notification is a direct `manageOrderService.customerOrderPalletized(...)` call inside a try/catch (:368-369); that method ends in `omsNotificationService.sendAfterCommit` (`ManageOrderService:345`), so it is deferred to after commit (§6 in the [transaction boundary map](./wms2-transaction-osiv-boundary-map.md)).
**`palletiseAndTruckLoad()` (cited here as :235) was deleted** by SBDEV-2620 (`fd87a502`, "dead since the initial v2 check-in"). The mobile counterpart is now `MobilePalletizeWriteService.advanceOrderToPalletized` (:662, SBDEV-3398).

### 5.4 "Order → PACKED on behalf of the batch": RESOLVED 2026-11-11, two live sites

`BillofladingService.finishClubRun()` (formerly cited at lines 744, 749) **does not exist** and has 0 hits in `src/main`. The behaviour it described is live at two places, re-derived at `df30fa62`:

1. **Transfer run: `BillofladingService.transferOrder(Long)`** (:910, `@Transactional` on the tenant tx manager; route `GET /runTransfer/{orderId}`, `TransfersController:255`). In **one transaction** it sets `Customerorder → PACKED` (:1006) and the order's `CustomerorderBatch → ORDER_BATCH_CLUB_RUN_FINISHED` (:1011, also clearing the staging lane). It refuses orders already at `PACKED` or beyond (:935). This is a precise match for the old claim, down to the adjacent PACKED/530 pair, so it is very likely what "`finishClubRun` 744, 749" referred to. ⚠ The identification is by behaviour; no commit links the two names.
2. **Club run: `CustomerorderBatchService.finalizeClubLine`** (:876, `@Transactional`; lease wrapper :860 used by `ClubRunJobWorker:205`, inline path via `runClubLine` → `self.finalizeClubLine` :1198). In one short transaction it bulk-sets every order → `PACKED` (`updateStateByIds` :878, which skips `CANCELED`), every position → `PACKED` (:879), and the batch → `ORDER_BATCH_CLUB_RUN_FINISHED` (:899). Per-order processing (parcel creation) happens earlier in `ClubLineOrderProcessor.processOrder`, which is `@Transactional` (:98-99). On the inline path that gives one transaction per order, because `runClubLine` is deliberately non-transactional (comment at `CustomerorderBatchService:1145`).

Both are notable for the same reason: the order is set to `PACKED` without passing through `packageOrder`'s `PICKED` gate. The batch-level finish is a claim about all its children. On failure of an inline club run, `rollbackClubLineState` (:1121) puts the batch back from 527 to its original state; a job-driven run does the same through `ClubRunJobService.failJob` (:212).

### 5.5 The pick path: `PickingorderBusinessService.finishPickingOrder()` (:166) + `confirmPick()` (:1213)
**Corrected 2026-11-11.** `finalizePicking()` **does not exist** (0 hits). The old line set (238–569) mixed writes from what are now two methods, and the "5 entities in one call" framing was not accurate for either.

`finishPickingOrder` (:166–:495) writes:
- `Pickingorder.state` → `orderState` (:491). The local is seeded `CANCELED` (:214) and promoted to `FINISHED` (:305) if any line was picked; the method throws `ORDER_ALREADY_FINISHED` if the picking order is already `>= FINISHED` (:206)
- `Customerorder.state` → `PENDING` / `PICKED` (:380 / :383), or → `CANCELED` by delegating to `cleanUpCancelledOrder` (:352) for orders flagged `markedforcancellation`
- `PickingorderUnitload.state` → `PICKED` (:449)
- `PickingorderPosition` → `CANCELED` only on the cancel branch: `cleanUpCancelledOrder` (:352) → `cancelOpenPickLines` (:883) → write at :708. No `PickingorderPosition` writes on the normal finish path

`confirmPick` (:1213–~1535) writes, per confirmed pick:
- `PickingorderPosition` → `PICKED` (:1386)
- `CustomerorderPosition` → `PICKED` / `STARTED` / `PENDING` (:1410 / :1416 / :1418)
- `Customerorder` → `STARTED` (:1437, when still below `STARTED`), then `PENDING` / `PICKED` (:1488 / :1491)
- `PickingorderUnitload` → `STARTED` (:1502)
- `Pickingorder` → `PICKED` when complete (:1531)

So `confirmPick` touches five entity types and is the bigger state mutator. Read both methods as a unit before editing anything in the pick-finalize path.

---

## 6. Recovery / Unstick Mechanisms

State drift is a known operational hazard; these are the sanctioned fixes:

| Mechanism | Location | What it does |
|---|---|---|
| Admin state reset | `controller/rest/UtilRestController.java:1104` (`resetOrdersInReleasedStatus`, `GET`; writes :1116/:1119/:1123) | Every `Customerorder` in `ASSIGNED`, with its batch and positions, goes back to `RAW` for re-release |
| Picking-date reset | `service/CustomerorderService.java:309` (`setPickingDate`), routes `POST /v3/customerOrder/setPickingDate` and `/pickingDateBatchUpdate` (`CustomerOrderController:62,96`) | Sets `Customerorder` (and its non-cancelled positions) → `RAW` or `FUTURE_PICKING_DATE`. Refused once the order is past `RESERVED`; deletes already-built pick lines. (Corrected 2026-11-11: the cited `OrderRestController:416,429` contains no such writes) |
| ~~Batch reset~~ | (none) | Corrected 2026-11-11: `OrderRestController:350` writes no batch state, and the **only** batch → `RAW` writes are creation (`OrderBatchCreationService:74`) and the admin reset above |
| ~~Advice reopen~~ | `controller/rest/AdviceRestController.java:992` | **Not a mechanism.** `reopen` throws "method not supported" and always has (see §4.7). Removed by SBDEV-4115 ✓ merged(SBDEV-4115: #664 938c9fe2, 2026-11-11) |
| Stuck picking-order finish | `controller/AdminActionController.java:269` (`finishStuckPickingOrder`, `GET …/finishStuckPickingOrder/{number}`) | For a `Pickingorder == PICKED` with at least one `PickingorderUnitload == STARTED`, calls `finishPickingOrder` (added 2026-11-11) |
| Release job | `service/job/ReleaseOrderJobService.java` (`releaseOrder` :134, `REQUIRES_NEW` per order) | Scheduled re-evaluation of `RAW` / `FUTURE_PICKING_DATE` / `CLIENT_HAS_NO_SECTION` orders, with position-level `RAW_ON_HOLD_*` reasons; **29** `setState` calls in the class (2026-11-11; was "~70") |
| Club-run error recovery | `service/CustomerorderBatchService.java:1121` (`rollbackClubLineState`, inline runs) / `service/ClubRunJobService.java:212` (`failJob`, job runs) | Rolls the batch back from `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` to its original state on failure |

Outside these paths, there is no safe way to "fix" a stuck state — direct SQL updates bypass all cascades and will desync children.

---

## 7. Known Landmines

1. **No Spring StateMachine, no validator.** Any `setState(X)` call is legal at the JVM level. Legality is enforced only by the guards around that call site. When adding a new transition, grep for every prior call site against the same entity and confirm your path isn't already covered.
2. **`CANCELED` (Integer) vs `CANCELLED` (String).** Different spellings for different type systems. Don't copy-paste a guard from one entity to another without checking.
3. **String states have no DB-level constraint.** A typo like `"CLOSEDD"` persists. Consider the String-typed entities (`Advice`, `Billoflading`, `Cyclecount`, and their positions) suspect first when a state-related bug surfaces.
4. **Numeric ordering is a hidden contract.** Code uses `>= PICKED`, `< RESERVED`, `>= RESERVED`. Renumbering any `WmsConstants.State` constant is a silent breaking change. Add new states in gaps. (Re-checked 2026-11-11: 45, 55–58 and 505–530 are values already placed in gaps. Free gaps remain, e.g. 1–44, 59–79, 81–199, 531–549, 681–699. ⚠ unverified: the original claim that these gaps "exist precisely for this", and what "the 5" referred to.)
5. **The pick path, `PickingorderBusinessService.confirmPick` + `finishPickingOrder`, mutates up to 5 entity types.** (Corrected 2026-11-11: `finalizePicking` does not exist.) Any change there must respect the full cascade in §5.5. That is where the "picking completes but order stays STARTED" class of bug comes from.
6. **`cancelOrder` has a rapid-pick side-door.** For a `RAPID_PICKING` section `&& state == ASSIGNED && historytote != null`, it bounces a `STARTED` `Pickingorder → PROCESSABLE` (`CustomerorderService:1032`, guard :984; was cited as line 645) instead of cancelling it. The original bug it was patching is documented in `Cancel_Order_Null_SectionId_And_Early_Return_Fix`. The in-code comment notes the arm is dead estate-wide today but re-armable by a single `sectionpickingtype` data edit. Don't "simplify" that branch.
7. **Scheduled `ReleaseOrderJobService` is the densest state writer** (29 `setState` calls in the class, 2026-11-11; this said "~70"). `releaseOrder` runs `@Transactional(REQUIRES_NEW)` per order (:132-134), which makes it the hottest optimistic-lock site in the app (see `WMS_V2_Horizontal_Scaling_Concurrency_Report`).
8. **`Customerorder → PACKED` is asserted on behalf of a batch in two places**: `BillofladingService.transferOrder` (:1006, together with batch → 530 at :1011) and `CustomerorderBatchService.finalizeClubLine` (bulk, :878). (Corrected 2026-11-11: `finishClubRun` does not exist; see §5.4.) Neither goes through `packageOrder`'s `PICKED` gate. If you change the order state machine, audit both.
9. ~~**No Pickingorder terminal `FINISHED` writer outside mobile.**~~ **False as of 2026-11-11.** Besides `MobilePickingService.releasePickingOrder:338`, `Pickingorder → FINISHED` is written by `PickingorderBusinessService.finishPickingOrder:491` (via `orderState`), `PickingorderBusinessService.finalizePickingOrderIfTerminal:745` and `CustomerorderPositionService:208`. The refactoring concern flagged in `WMS_API_Problem_Areas_Analysis_And_Refactoring_Plan` no longer applies as stated.
10. **Revert-to-original-state appears twice, both scoped to club-run failure**: `CustomerorderBatchService.rollbackClubLineState` (:1121, inline runs) and `ClubRunJobService.failJob` (:212, job runs, restoring the job's recorded `original_batch_state`). (Corrected 2026-11-11: this said "the only revert pattern", at :709.) Both act only if the batch is still at 527. Do not generalize them into a reusable helper; the caller-specific context is what makes them safe.

---

## 8. How to use this doc

| Task | Start at |
|---|---|
| "Why is this order stuck in state X?" | §4 (entity catalog) → find every writer of state X → check guards in §4 → check cascades in §5 |
| Adding a new lifecycle state | §2.1 (pick a gap value) → §3 (place it in the DAG) → §5 (decide cascade semantics) → §7 #4 |
| Adding a new `setState` call | §4 (find siblings) → §5 (confirm cascade obligations) → §6 (is this an unstick path?) |
| Debugging a `CANCELED` vs `CANCELLED` bug | §2.2 + §7 #2 |
| Auditing a cross-entity bulk transition | §5 (cascade map) |
| Reviewing a PR that touches `finishPickingOrder` / `confirmPick` / `packageOrder` / `cancelOrder` / `transferOrder` / `finalizeClubLine` | §5.1–5.5 in full |

---

## 9. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-11-11 | **FULL re-verification, all sections**, against `origin/develop` `df30fa62`: §2 constants and values, every §4 entity's field, states and write sites (setState census: 161 lines, 32 files), every §4.1/§4.3 guard, all of §5 (behaviour as well as anchors), §6, §7. §4.9.1 was re-checked for symbol existence only. | **`last_verified` bumped to 2026-11-11.** Main corrections: (1) **Advice `reopen` is a stub that throws "method not supported"** (since `a685e07b`), so the doc's "only explicit reopener" never existed (§4.7, §4.8, §6). (2) §5.4 resolved: the `finishClubRun` behaviour lives in `BillofladingService.transferOrder` (:1006/:1011) and `CustomerorderBatchService.finalizeClubLine` (:878/:899). (3) `finalizePicking` does not exist; §5.5 re-derived as `finishPickingOrder` + `confirmPick`, and §4.4's three-way branch is on `CustomerorderPosition`. (4) Deleted methods removed: `palletiseAndTruckLoad` (SBDEV-2620), `activateTransferOrder` (SBDEV-3183), the `MobilePalletizingService` writes (moved to `MobilePalletizeWriteService`, SBDEV-3398), and the BOL method names `openBillOfLading`/`updateBillOfLading`/`finalizeBillOfLading`. (5) §7 #9 is false (non-mobile `Pickingorder → FINISHED` writers exist) and #10 is wrong (`ClubRunJobService.failJob` is a second revert). (6) §6's `OrderRestController` order/batch reset rows had no such code; replaced with `setPickingDate`, and `finishStuckPickingOrder` added. (7) `Customerorder.state` has no `RAW` default; Customerorder's reachable states gained 45/50 and lost 300/400. (8) SBDEV-3626 is merged (PR #454). (9) `CANCELLED` (BOL) and `STARTED` (cycle count) have no Java writer. Items left marked ⚠ unverified: PickingorderPosition 200/500/550, Advice PROCESSING/CLOSED/CANCELLED, cancel from 680, the intent behind the §7 #4 gaps, and the transferOrder↔finishClubRun identification. Full change list: scratchpad report `verify/state-machine.md` (session db6890ae). | Code read (grep + targeted reads) at `df30fa62`; no DB queries |
| 2026-10-15 | **SBDEV-3736 — **MERGED** to develop 2026-10-15 (PR #518, merge `a05e8998`, PR head `f6445546`; on dev).** §4.8 SBDEV-2778 note extended: `markFinished` saves the Advice as an entity; new `ReceivingService.finishReturnAdviceIfComplete` write sites (exact-match rule, lock order, residual windows); a dock-received/adjusted RETURN advice can now reach FINISHED. **Scope: §4.7/§4.8 only** — `last_verified` unchanged. | Code read of branch `feature/SBDEV-3736-returns-audit-linkage` @ `b002934f` (`ReceivingService`, `GoodsReceiptPositionService`, `ReturnAdviceAutoReceiveService`). Not merged; re-verify against `origin/develop` after merge. | Code read (SBDEV-3736 branch) |
| 2026-10-06 | **SBDEV-3494: added §4.9.1, "what counts as shipped".** Scope: that section only. The rest of the document was not re-verified, and `last_verified` is unchanged. Note: the §4.9 header row still lists `finishClubRun`, which §5.4 says does not exist; left as found. | `git grep` sweep on `origin/develop` @ `69d6126a` (patterns and blind spots listed in §4.9.1), an independent re-sweep by a review lane, and DB queries on WineCo dev and Hydra PRD. | SBDEV-3494 |
| 2026-09-22 | **SBDEV-3418 — `scanGate` split into two classes.** §4.2's key-transition row and §4.9's `Billoflading` cross-writer row both cited `MobileTruckLoadingService`; the state writes now live in the new `MobileTruckLoadingWriteService`, which is the `@Transactional` half. Note the BOL-state row is no longer a single site: PHASE C decides `pendingState` (:334) and PHASE D applies it (:394), because PHASE C is predicate-only by construction. **Scope: those two rows only**; the rest of the document was not re-verified and `last_verified` is unchanged. | `grep -n "LOADED_TO_TRUCK\|setState(pendingState)"` on the SBDEV-3418 branch; positive control: the same grep against `origin/develop` returns the old in-place sites. | SBDEV-3418 implementation |
| 2026-08-29 | **PARTIAL — §4.1 and §4.2 write-site tables fully rebased; the rest of the doc NOT re-verified.** Extracted all 74 citations and machine-checked them against `origin/develop` at `e5daa8ca`. | ⚠ **Read this before trusting any anchor here: this doc's parenthetical names are sometimes DESCRIPTIVE LABELS, not declared methods.** `PickingOrderMergeService` has taken **0 commits** since the last verification yet cites `:127` (`cancelOrderIfMergeFails`) and `:161` (`mergeOrders`), neither of which is a declared method — both are lines *inside* `mergePickingOrders` (:46). Four successive automated checks each mis-read that convention as "method deleted", so the untouched citations below **cannot be machine-swept** and need per-citation reading. **Rebased and re-verified against code (24 anchors):** `CustomerorderService` `239-244 (createForRelease)`→**285,290-291 (`setPickingDate`)** (`createForRelease` does not exist; `:239` is an unrelated method), `485 (pack)`→**557 (`packageOrder`)**, `351/675 (cancel)`→**356,361 (`checkAndCleanUpPickingOrderPositions`) / 408,415 (`updateOrderPositions`)** with the public entry `cancelOrder` at **:690**; `ReleaseOrderJobService` `643,647 (releaseOrderAndPosition)`→**196,395,440,454 / 723 (`releaseOrder`)** — that method name does not exist either; `TransferOrderService` `96,110,124,132`→**100,155,163 / 115 / 132** with all four enclosing methods named; `PickingorderBusinessService` `238,241,343,502`→**249,252 (`finishPickingOrder`) / 419 (`cleanUpCancelledOrder`) / 594 (`confirmPick`)**; `ParcelMonitorViewService` `156,283 / 401`→**193,345 / 465**; `MobilePalletizingService` `220`→**269,421**; `MobileTruckLoadingService` `304`→**306 (`scanGate`)**; `BillofladingService` `481`→**503,546 (`closeBOL`)**; `UtilRestController` `960`→**1092,1095,1099 (`resetOrdersInReleasedStatus`)**; `CustomerorderBatchService` `427`→**474 (`activateOrderBatch`)**, `606`→**628 (`validateClubLine`)**, `689`→**716 (`finalizeClubLine`)**, `434`→**479**, `279,339`→**260**, `358`→**393**; and `startPicking`→**`startPickingOrder`**. Every rewritten anchor re-verified to contain the state token the row claims. **STILL STALE, not fixed:** §4.1's four guard citations (`OrderRestController:180`, `CustomerorderService:471`, `:382,554`, `:639`) — these are interpretive prose claims, not state writes, and need a human read; and §4.3 onward plus §5's cascades were not audited at all. **`last_verified` deliberately NOT bumped — it stays at 2026-05-08.** | Code read on `origin/develop` + machine citation sweep, every replacement re-verified |
| 2026-04-19 | All state field declarations, `WmsConstants.State` + `AdviceState` + `BillOfLadingState` + `CycleCountState` values, write-site inventories (~160 total), primary guards, cascade methods, recovery endpoints | All counts and file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-08 | Group T (transfer-order) churn — `TransferOrderService.unlinkTransferLaneFromTransferOrder` resets state to `CUSTOMER_ORDER_ACTIVATED` on lane unlink (commit 24280b0); Group P picking lines shifted +1 (`finalizePicking` now 238–569; cascade table updated); rapid-pick recovery cite confirmed at line 645 (guard at 639); SBDEV-2164 stale club batch cleanup adds JobLockId.STALE_CLUB_BATCH_CLEANUP but does not introduce new state values for `CustomerorderBatch` (cancel transitions remain through `cancelBatch`); §4.6 Replenishorder unaffected; receiving repository `findByStateAndItemdataId` confirmed live in `ReplenishorderRepository.java:46` (only used by job paths, no new state added). | All write-site lines re-confirmed; minor +1 drift in `PickingorderBusinessService` updated. | Code read (grep-based) |
| 2026-09-14 | **SBDEV-3354 — `cancelBatch` deleted.** §4.2's key-transition table listed `CustomerorderBatchService.java:260` (`cancelBatch`) → `CANCELED`. That method had no route and no caller and was deleted, so `CustomerorderBatch` now reaches `CANCELED` only by rollup through `finalizeBatchIfComplete` — which makes a partially-cancelled batch a reachable intermediate state. Note this supersedes the `cancel transitions remain through cancelBatch` clause in the 2026-05-08 row above. **Scope: that one transition row only** — the rest of the document was not re-verified and `last_verified` is unchanged. | `git grep -n "cancelBatch" origin/develop -- 'src/main/**/*.java'` → 0 after deletion; positive control: 54 occurrences in `src/test` before it. | SBDEV-3354 implementation |
| 2026-08-03 | §4.8 `Adviceposition` write sites: added `ReturnAdviceAutoReceiveService.markFinished` (SBDEV-2778) + the RETURN-reaches-FINISHED-without-a-dock-scan note | Only §4.7/§4.8 re-verified; the ~160-site inventory elsewhere was **not** re-counted, so `last_verified` stays at 2026-05-08 | Code read (SBDEV-2778 diff) |

| 2026-08-06 | **§5 cross-entity cascade anchors + §4.7 reopen endpoint.** Cadence sweep prompted by SBDEV-2731 (which touches none of this surface — its diff contains zero `setState`/`AdviceState`). **Most §5 anchors were wrong**, including three where the documented *method name* no longer resolves at all. | Corrected against `origin/develop` (`169065c`): §5.1 `cancelOrder` 300→**655** (child writes :724/:729/:754; `handleRapidPickingForCancelledOrder` no longer exists — now inline, and the old :645 cite now lands on unrelated club-run code); §5.2 `pack()`→**`packageOrder()` :506**, guard :382→**:415**; §5.3 `palletizeOrders()`→**`palletise()` :103 / `palletiseAndTruckLoad()` :235** — the code uses the **British spelling**, which is why the old name read as deleted; §4.7 `reopen` :648→**:732**. §5.4 `finishClubRun` **exists in neither v1 nor v2** and is flagged UNRESOLVED in place. **Anchors only — the ~160-site write inventory and every behavioural claim were NOT re-derived, so `last_verified` stays at 2026-05-08.** | Code read (grep-based, SBDEV-2731 doc sweep) |

| 2026-08-14 | **`CLIENT_HAS_NO_SECTION (45)` acquired its first writer** (SBDEV-2961, branch `feature/SBDEV-2961-order-release-silent-section-exclusion`). Corrected §2's table row and the §3 diagram, both of which described 45 as a live "stuck" state. It was not: `git log -S CLIENT_HAS_NO_SECTION` returns only the initial check-in (constant, **no writer**) and SBDEV-1656 `d6f28cbf`, which *added two reads* of a structurally unreachable state — so that half of SBDEV-1656 has been dead code since 2025-10-28 and is reachable for the first time now. New writer: `OrderReleaseJob.processOrderGroup` → `ReleaseOrderJobService.markClientHasNoSection` (a `@Modifying` CAS in a `REQUIRES_NEW` tx; the allow-list `state IN (RAW, FUTURE_PICKING_DATE)` means 45 can overwrite only those two, deliberately **not** hold states 50/55-58). Also note `OrderReleaseJob:188`'s pre-round gate now excludes 45. **Scoped touch only** — §2 row, §3 diagram and this entry were verified against the branch; the ~160-site write inventory and every other behavioural claim were **NOT** re-derived, so `last_verified` deliberately stays at 2026-05-08. | §2 state row + §3 diagram corrected against the SBDEV-2961 branch | Code read + `git log -S` archaeology |

**Re-verify every 60 days** — state surface drifts quickly. Next due: 2027-01-10. (The full re-derivation of §5 and the ~160-site inventory owed since 2026-08-06 was done on 2026-11-11.)
