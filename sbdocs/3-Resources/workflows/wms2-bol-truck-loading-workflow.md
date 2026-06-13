---
title: "WMS v2 — BOL / Truck Loading / Shipping Workflow"
type: workflow
status: active
version: v2
scope: bol-truck-loading
owner: Nam Park
created: 2026-04-19
updated: 2026-05-19
last_verified: 2026-05-19
verified_by: code read of v2/wms2-api BillofladingService + ParcelMonitorViewService + MobileTruckLoadingService
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ./wms2-picking-workflow.md
  - ./wms2-club-run-workflow.md
  - ./wms2-cancel-cascade-workflow.md
  - ../../4-Archieves/wms2/plan/260424-CLOSE_BOL_FURTHER_IMPROVEMENTS.md
  - ../../4-Archieves/wms2/plan/260424-oms-palletized-loaded-to-truck-notifications-plan.md
  - ../../4-Archieves/wms2/plan/260424-ORDER_LOADED_TO_TRUCK_DASHBOARD_PLAN.md
tags:
  - workflow
  - bol
  - truck-loading
  - shipping
  - wms2
---

# WMS v2 — BOL / Truck Loading / Shipping Workflow

**Scope:** From `PALLETIZED` customer orders through BOL open / truck loading / close in `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-05-08

---

## 1. Overview

The BOL (Bill of Lading) flow is how picked+packed orders leave the warehouse. It spans a desktop path (`ParcelMonitorViewService`) and a mobile path (`MobileTruckLoadingService`) that converge on the same `Billoflading` state machine. Closing the BOL (`BillofladingService.closeBOL`) is the single most expensive state transition in the codebase — it:

- Acquires a pessimistic lock on the BOL row + an in-memory `bolToClose` set (double-guard against concurrent closes).
- Bulk-updates all `BillofladingPosition` rows via JPQL (one query instead of N).
- Bulk-finalizes all `Customerorder` + `CustomerorderPosition` rows in the BOL to `FINISHED` (JPQL).
- Bulk-transfers every `Unitload` on the BOL to the SHIPPED location + sets entity locks.
- Fires the `WEBSERVICE_ORDER_BATCH_SHIPPED` OMS callback post-commit.

BOL state machine (String — two-L `CANCELLED`):

```
CREATED → OPEN → TRUCK_LOADING → CLOSED
                               └─► TRANSFER   (for TRANSFER_INTRACOMPANY type only)
          └────► CANCELLED
```

---

## 2. Entity Cast

| Entity | Role | State |
|---|---|---|
| `Billoflading` | BOL header | String `state` (`BillOfLadingState.*`) |
| `BillofladingPosition` | Position tree (pallet → parcel → stock) | String `state` |
| `Customerorder` | Order being shipped | Integer `state` |
| `CustomerorderBatch` | Batch rollup | Integer `state` |
| `Unitload` | Pallet / parcel / stock carrier | — (location-based lifecycle) |
| `Stockunit` | Stock on the carriers | — |

BOL state constants live at `service/WmsConstants.java:244-253`. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §4.9 for the full state map and §9 for the two-L spelling gotcha.

---

## 3. Lifecycle

```
Customerorder.state = PALLETIZED
 (set by ParcelMonitorViewService.palletise   [line 103-230]
   or   MobilePalletizingService.palletizeOrder   [line 220])
            │
            │  REST /v3/billOfLading/create    [BillOfLadingController:69]
            ▼
   Billoflading.state = OPEN                       [BillofladingService.createEntity:229]
            │
            │  ┌────────────────────────────────────────────────┐
            │  │ Two paths to loading — desktop or mobile        │
            │  └────────────────────────────────────────────────┘
            │
            ├─► Desktop:  REST /v3/billOfLading/palletize   [BillOfLadingController:316]
            │             → ParcelMonitorViewService.palletiseAndTruckLoad()  [line 232-470]
            │
            └─► Mobile:   REST /mobile/truckLoading/scanGate   [TruckLoadingController:110]
                          → MobileTruckLoadingService.scanGate()     [line 178-325]
            │
            ▼
   Billoflading.state = TRUCK_LOADING              (waterfall from CREATED / OPEN)
   Customerorder.state = LOADED_TO_TRUCK           (via order-level save)
   BOL position tree created: pallet → parcels → stock
            │
            │  post-commit: WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK
            │
            ▼
   REST /v3/billOfLading/closeOutboundBol/{id}   [BillOfLadingController:207]
            │
            ▼  BillofladingService.closeBOL(bolId)            [line 277-699]
            │  (pessimistic row lock + in-memory guard)
            │
            ├─► Billoflading.state = CLOSED    (regular)
            │                    or TRANSFER  (TRANSFER_INTRACOMPANY type)
            ├─► BillofladingPosition.state = CLOSED (or TRANSFER) — BULK JPQL UPDATE
            ├─► Customerorder.state = FINISHED — bulk
            ├─► CustomerorderPosition.state = FINISHED — bulk
            ├─► Unitload storagelocation → SHIPPED, entityLock → SHIPPED (or TRANSFER)
            ├─► Stockunit entityLock → SHIPPED (or TRANSFER)
            └─► CustomerorderBatch.state = FINISHED   (if all child orders FINISHED)
            │
            │  post-commit: WEBSERVICE_ORDER_BATCH_SHIPPED
            ▼
   BOL terminal state: CLOSED / TRANSFER

   Sidebar: TRANSFER_INTRACOMPANY type
            │
            ▼  REST /v3/billOfLading/closeIntraCompanyTransfer/{id}   [BillOfLadingController:291]
            │
            └─► BillofladingService.finishTransfer()    [line 898]
                  Billoflading.state = TRANSFER → CLOSED
                  BillofladingPosition → CLOSED (bulk JPQL)
                  Unitloads → SHIPPED location
```

---

## 4. Palletize — Desktop Path

`ParcelMonitorViewService.palletise` at line 103-230 handles the pack → pallet assignment without immediately starting truck load. It:

1. Locates the pallet unit load (creating one if `createPalletBySystem=true`).
2. Finds location `STORAGE_LOCATION_PALLETISING`.
3. For each customer order with `state < PALLETIZED`: sets `state = PALLETIZED`, transfers the parcel unit load onto the pallet carrier with activity code `CODE_PALLETISING`.
4. Registers a post-commit hook → `ManageOrderService.customerOrderPalletized(...)` which fires `WEBSERVICE_ORDER_BATCH_PALLETIZED`.

Guard: `state < PALLETIZED` prevents double-apply (matches the `state == PACKED OR PALLETIZED` check in `CustomerorderService:382` — see `Cancel_Club_Parcels_Packed_State_Fix`).

`palletiseAndTruckLoad` at line 232-470 does palletize **and** truck-load in one transaction. BOL state rolls `CREATED`/`OPEN → TRUCK_LOADING`. BOL position tree (pallet → parcels → stock) is created inline. Two post-commit callbacks fire: PALLETIZED then LOADED_TO_TRUCK.

---

## 5. Truck Loading — Mobile Path

`MobileTruckLoadingService.scanGate` at line 178-325 is the mobile operator's primary action. Flow:

1. Lookup pallet + BOL + gate location.
2. BOL state guard — only `CREATED`, `OPEN`, or `TRUCK_LOADING` allowed. Waterfall from CREATED/OPEN to TRUCK_LOADING. Reject TRANSFER / CLOSED / CANCELLED with `BusinessException`.
3. Transfer the pallet to the gate location via `unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false, CODE_TRUCK_LOADING, bolNumber, null)`.
4. Offload via `mobileTransferService.handleTruckOffLoading(palletName)`.
5. Build BOL position tree: create `BillofladingPosition` for the pallet, then for each parcel on the pallet, then for each stock unit under each parcel. All positions are created with `state = TRUCK_LOADING`.
6. For each customer order in the pallet's parcels: if `state < LOADED_TO_TRUCK`, set `state = LOADED_TO_TRUCK`.
7. Post-commit: `ManageOrderService.customerOrderLoadedToTruck(...)` → fires `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK`.

Related mobile endpoints:

| Endpoint | Method | File:Line | Purpose |
|---|---|---|---|
| `/mobile/truckLoading/orderList` | GET | `TruckLoadingController:46` | Pending orders for truck loading |
| `/mobile/truckLoading/truckLoadingInfo/{bolName}` | GET | `TruckLoadingController:60` | BOL manifest locations |
| `/mobile/truckLoading/loadOrder` | POST | `TruckLoadingController:67` | Lookup BOL, fetch gate/truck/courier |
| `/mobile/truckLoading/scanPallet` | POST | `TruckLoadingController:89` | Validate pallet label + state |
| `/mobile/truckLoading/scanGate` | POST | `TruckLoadingController:110` | **Main** — loads pallet, BOL state → TRUCK_LOADING |

Open TODOs in the code (worth noting):

- `loadOrder:104` — "TODO check BOL state"
- `loadOrder:104` — "TODO check order state"
- `scanGate:213` — "TODO check that gate is a correct location"
- `scanGate:225` — "TODO should not be allowed" (re: CREATED state in truck loading)

---

## 6. Close BOL — `BillofladingService.closeBOL`

The most complex method in the shipping path. The single-arg overload (`closeBOL(Billoflading)`) is at `BillofladingService.java:273`; the long-form `closeBOL(Long bolId)` runs from line 278 through ~699.

### 6.1 Concurrency guards

```java
// In-memory set — atomic contains-and-add
if (!bolToClose.add(bolId)) {
    throw new BusinessException("BOL is currently in process.");
}

// DB-level pessimistic lock
Billoflading bol = billofladingRepository.findByIdForUpdate(bolId)
    .orElseThrow(() -> new BusinessException("BOL not found: " + bolId));
```

Both layers exist because `bolToClose` is JVM-local (one replica) and the DB lock crosses replicas. Without both, concurrent closes on different replicas could both pass the add() check on their own JVMs.

### 6.2 State validation

| Source state | Target state | Result |
|---|---|---|
| `CREATED` | — | waterfall to OPEN path |
| `OPEN` | — | waterfall to TRUCK_LOADING path |
| `TRUCK_LOADING` | `CLOSED` / `TRANSFER` | proceed |
| `TRANSFER` | — | reject — "Can not close BOL. BOL is in transfer!" |
| `CLOSED` / `CANCELLED` | — | reject — "Can not close BOL. BOL already closed!" |
| anything else | — | `RuntimeException("unknown state=...")` |

Target state depends on BOL `type`:
- `type == "TRANSFER_INTRACOMPANY"` → `TRANSFER`
- anything else → `CLOSED`

### 6.3 Bulk optimizations

Three ways `closeBOL` avoids N+1 queries (documented inline at lines 345-347, 661-685):

1. **Pre-load positions** — one query loads all positions for the BOL, then an in-memory tree is built. Eliminates per-position carrier-check queries.
2. **Bulk position update** — one JPQL UPDATE sets every BillofladingPosition to the target state. Replaces N saves.
3. **Bulk order finalization** — two JPQL queries finalize all Customerorder + CustomerorderPosition rows on the BOL. Replaces ~2N-3N queries.

### 6.4 Entity-lock writes

At `closeBOL:596-611`:

```
UPDATE Unitload u SET u.storagelocationId = :shippedLocationId, u.entityLock = :lock
UPDATE Stockunit  s SET s.entityLock = :lock
```

Entity lock value:
- `BusinessObjectLockState.SHIPPED` for CLOSED path
- `BusinessObjectLockState.TRANSFER` for TRANSFER path

Stock under shipped unit loads is locked from further edits until the receiving end (other warehouse) acknowledges.

### 6.5 Post-commit OMS callback

```java
String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY);
String payload = MAPPER.writeValueAsString(billOfLadingWebServiceDto);
omsNotificationService.sendAfterCommit(urlPath, payload,
    WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED);
```

Fires only after commit; rollback drops the callback.

---

## 7. OMS Callbacks

| Callback | Fired from | Sysprop URL key |
|---|---|---|
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `ManageOrderService.customerOrderPalletized` (line 413) | `…PALLETIZED_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `ManageOrderService.customerOrderLoadedToTruck` (line 474) | `…LOADED_TO_TRUCK_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `BillofladingService.closeBOL` (line 653) | `…SHIPPED_URL_KEY` |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `AdviceService` (line 251) | `…ACCEPT_HUB_AND_SPOKE_URL_KEY` |

All use `TransactionSynchronizationManager.registerSynchronization(...)` or the `omsNotificationService.sendAfterCommit(...)` wrapper — post-commit only.

---

## 8. Transfer Flow (TRANSFER_INTRACOMPANY)

BOLs of type `TRANSFER_INTRACOMPANY` go through a two-step close instead of one:

1. `closeBOL(bolId)` — BOL state `TRUCK_LOADING → TRANSFER`. Positions move to TRANSFER state. Unit loads go to SHIPPED location with `entityLock = TRANSFER`.
2. Receiving warehouse accepts: `finishTransfer(transferId)` at `BillofladingService.java:898` — BOL state `TRANSFER → CLOSED`. Positions to CLOSED via JPQL. Unit loads transferred to the receiving WH's storage area.

Why two steps? TRANSFER marks "in flight between warehouses" — neither side has operational access to the stock, which is why the `entityLock` is set. Normal shipments skip this and go straight to CLOSED.

---

## 9. REST Endpoints — Desktop

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `POST /v3/billOfLading/create` | POST | 69 | Create BOL (state = OPEN) |
| `GET /v3/billOfLading/nameExists/{name}` | GET | 108 | Name uniqueness check |
| `POST /v3/billOfLading/setTrackingDeviceID` | POST | 119 | Set tracking device (guarded: rejects TRANSFER/CLOSED/CANCELLED) |
| `POST /v3/billOfLading/setDestinationFacility` | POST | 179 | Set destination |
| `GET /v3/billOfLading/closeOutboundBol/{id}` | GET | 207 | Single close → `closeBOL` |
| `POST /v3/billOfLading/closeOutboundBols` | POST | 233 | Batch close |
| `POST /v3/billOfLading/exportOutboundBol` | POST | 265 | Export BOL as file / HTTP response |
| `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}` | GET | 291 | Finish transfer → `finishTransfer` |
| `POST /v3/billOfLading/palletize` | POST | 316 | Palletize orders → `palletise` / `palletiseAndTruckLoad` |
| `GET /v3/billOfLading/openBol` | GET | 355 | List open BOLs |
| `GET /v3/billOfLading/closedBol` | GET | 381 | List closed BOLs |
| `GET /v3/billOfLading/bolDetailsById/{id}` | GET | 405 | BOL details |

---

## 10. Transaction Boundaries

- `palletise`, `palletiseAndTruckLoad`, `scanGate`, `closeBOL`, `finishTransfer`: all `@Transactional(value="tenantTransactionManager", rollbackFor=Exception.class)`. One atomic unit per call.
- **Pessimistic lock on BOL row** during close — `findByIdForUpdate` (see [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8.2).
- **Bulk JPQL updates inside `closeBOL`** avoid the N+1 that plagued earlier implementations — see `CLOSE_BOL_FURTHER_IMPROVEMENTS` archive.
- Post-commit hooks for label printing, OMS callbacks.

---

## 11. Known Landmines

1. **String state — `CANCELLED` with two L's.** BOL uses `BillOfLadingState.CANCELLED`, not `State.CANCELED`. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §9.
2. **`closeBOL` is long and bulk-heavy.** The 3 bulk optimizations at §6.3 are correctness-critical. Refactoring any of them back to save-per-row reintroduces the performance cliff documented in `CLOSE_BOL_FURTHER_IMPROVEMENTS`.
3. **Dual concurrency guard (in-memory `bolToClose` + DB pessimistic lock)**. The in-memory set only protects against double-submit on the same JVM; the DB lock crosses replicas. Remove either and you have a race.
4. **TRANSFER vs CLOSED branching lives in `closeBOL`.** The target state depends on BOL `type` field, checked twice (state + entity lock). A third path added for a new BOL type needs both checks updated.
5. **Mobile `scanGate` has open TODOs** (§5). BOL-state + gate-location validation are marked incomplete. An operator scanning the wrong gate does not error at the API level today.
6. **BOL positions created with `state = TRUCK_LOADING`** (hardcoded in `BillofladingPositionService.createEntity:44`). Subsequent transitions via bulk JPQL. Don't override at creation time.
7. **Entity locks on Unitload + Stockunit during TRANSFER** prevent intra-facility moves of in-flight stock. Clearing these locks manually (e.g. via SQL) during a stuck transfer is the wrong fix — invoke `finishTransfer` with the right transferId.
8. **Palletize guard `state < PALLETIZED`**. Only advances; never regresses. Force-paths in cancel (`forceCancelOrder`) bypass this. A custom admin flow that tries to "un-palletize" must also clear the pallet unit load linkage, or state and physical reality diverge.
9. **Palletize's post-commit hook must capture the order list + pallet *before* commit.** The closure variable `capturedOrders` / `capturedPallet` in `palletise` is there for a reason — reading these from the EMF after commit can return stale state under OSIV-disabled config.
10. **`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` default is `false`** (tenant routing §11 table). Cancels mid-BOL-flow don't notify OMS by default; enable the sysprop per-tenant.

---

## 12. How to debug

| Symptom | Start here |
|---|---|
| "BOL stuck in TRUCK_LOADING, close rejects" | §6.2 state guards + confirm `bolToClose` set isn't poisoned (JVM restart clears) |
| "Concurrent close on two replicas produced partial state" | §6.1 dual guard — check that DB pessimistic lock actually fired (DB-side pg_stat_activity during the window) |
| "OMS didn't get SHIPPED callback" | §7 + `message` / `message_archived` tables + check for rollback between state write and commit |
| "Intracompany transfer stuck in TRANSFER" | §8 — `finishTransfer` wasn't invoked on the receiving side |
| "Performance regression during close" | §6.3 — verify bulk JPQL paths still active |
| "Mobile operator scanned wrong gate — no error" | §5 open TODOs |
| "Order shipped but batch still ORDER_BATCH_CLUB_RUN_FINISHED" | §6.3 — batch rollup is part of close; absence means close didn't commit |

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `BillofladingService` (closeBOL, finishTransfer, createEntity, setTrackingDeviceID, transferOrder); `ParcelMonitorViewService.palletise` + `palletiseAndTruckLoad`; `MobileTruckLoadingService.scanGate`; `BillofladingPositionService`; all REST + mobile endpoints; OMS callback wiring | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-08 | Group B (BOL/palletize) ports verified live: v1 `98fce54` → v2 `cd73716` (new BOL no shipped date — confirmed via commit log); v1 `8957b9a` → v2 `a8af84f` (empty BOL export no SKU rows); v1 `83dddd8` palletize filter → v2 `ReportController` palletize filter routes via `/parcelMonitorView` GET (line 366) + ViewDtoService at the cited 1334-1338 region. `closeBOL` Phase 8 (Customerorder + Position FINISHED bulk) writes at lines 481 / 524; Phase 9 (post-commit OMS callback registration) per §6.5 — both confirmed. `finishTransfer` declaration shifted from cited 898 → actual line 899 (within tolerance, not edited). `BillOfLadingController` REST endpoint table re-confirmed against current source. | All claims still accurate; closeBOL header range expanded to reflect 273/278 method overloads. | Code read (grep-based) |
| 2026-05-19 | SBDEV-2232: `ParcelMonitorViewService.palletise` pessimistic-lock refactor shifted `palletiseAndTruckLoad` start from 210 → 232 (end of file: 470). `palletise` body end shifted from 207 → 230. Updated §3 diagram, §4 narrative, §4 `palletiseAndTruckLoad` line refs. Narrative and transaction shape unchanged — only `SELECT FOR UPDATE` guard added at top of `palletise`. | Line refs confirmed by grep against `src/main/java` | Code read (grep-based) |

**Re-verify every 90 days.** Next due: **2026-08-06** — close BOL is stable but mobile truck-loading open TODOs invite future change.
