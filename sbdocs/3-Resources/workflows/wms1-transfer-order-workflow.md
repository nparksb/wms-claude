---
title: "WMS v1 — Transfer Order Workflow"
type: workflow
status: active
version: v1
scope: transfer-order
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-04-26
verified_by: code read of v1/wms-api TransferOrderService + TransfersController + BillofladingService.transferOrder/finishTransfer/closeBOL + MobileTransferOrderService + AdviceRestController + OrderRestController
related:
  - ./wms1-bol-truck-loading-workflow.md
  - ./wms2-transfer-order-workflow.md
tags:
  - workflow
  - transfer-order
  - transfer
  - wms1
---

# WMS v1 — Transfer Order Workflow

**Scope:** Inter-facility / intra-company order movement from source warehouse activation through destination receipt · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26

---

## 1. Overview

A transfer order moves inventory between two facilities of the same or affiliated tenants. It uses the same `Customerorder` entity as normal orders but follows a dedicated state track, and the `CustomerorderBatch` must carry a `TRANSFER_INTRACOMPANY` or `TRANSFER_OFFSITE` batch type.

Two facility modes exist:

| Mode | `OrderBatchType` | BOL close behaviour | OMS callback at close |
|---|---|---|---|
| **Intra-facility ("offsite")** | `TRANSFER_OFFSITE` | `closeBOL` → `CLOSED` directly (same as regular shipment) | `WEBSERVICE_ORDER_BATCH_SHIPPED` |
| **Inter-facility / intracompany** | `TRANSFER_INTRACOMPANY` | `closeBOL` → `TRANSFER` (in-flight); `finishTransfer` → `CLOSED` | `WEBSERVICE_ORDER_BATCH_SHIPPED` at source + `WEBSERVICE_ACCEPT_TRANSFER` at destination |

This document covers both paths but focuses on the **`TRANSFER_INTRACOMPANY` path**, which is the more complex two-step close.

Two critical facts to keep in mind:

1. **Transfer orders use the same `Customerorder` entity** as normal orders but branch at states 505 (`CUSTOMER_ORDER_ACTIVATED`) and 510 (`CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`). These are transfer-specific; don't confuse them with states 520/525 used by club-order batches.
2. **`TRANSFER_INTRACOMPANY` BOL type splits `closeBOL` into two operations.** `closeBOL` puts the BOL in `TRANSFER` state; `finishTransfer` moves it `TRANSFER → CLOSED`. Never call `closeBOL` a second time on a transfer BOL — it throws `"Can not close BOL. BOL is in transfer!"`.

---

## 2. Actors

| Actor | Role |
|---|---|
| OMS | Creates transfer order advice and transfer customer orders; receives shipped/accepted callbacks |
| Web UI operator (source) | Activates order, assigns transfer lane, monitors stock, triggers pack (`runTransfer`) |
| Mobile operator (source) | Picks stock from storage into the assigned transfer lane |
| WMS BOL process (source) | Standard truck-load + `closeOutboundBol` puts BOL in `TRANSFER` state |
| Web UI operator (source) | After destination confirms receipt: `closeIntraCompanyTransfer` to finalize BOL |
| OMS / WMS (destination) | Pushes `Advice` of type `TRANSFER`; destination operator accepts the advice |

---

## 3. Entity Cast

| Entity | State track | Role |
|---|---|---|
| `Customerorder` | `RAW → CUSTOMER_ORDER_ACTIVATED (505) → CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED (510) → PACKED (650) → FINISHED (700)` | The transfer order |
| `CustomerorderBatch` | advances to `ORDER_BATCH_CLUB_RUN_FINISHED (530)` via `transferOrder()` pack step | Batch rollup |
| `Billoflading` | `CREATED → OPEN → TRUCK_LOADING → TRANSFER → CLOSED` (intracompany) | Shipping manifest |
| `BillofladingPosition` | `TRUCK_LOADING → CLOSED` (row-by-row in v1 `finishTransfer`) | BOL line items |
| `Advice` (destination) | `OPEN → FINISHED` via OMS `acceptTransfer` REST call | Destination receipt notice |
| `Unitload` / `Stockunit` | `entityLock` set to `TRANSFER (404)` during in-flight phase, then `SHIPPED` after `finishTransfer` | The actual shipped inventory |

---

## 4. Transfer Order Creation

### 4.1 From OMS advice (inbound transfer advice)

OMS pushes a transfer-type advice to the **destination** WMS via:

```
PUT /rest/advice/createTransfer
```

`AdviceRestController:355` (`AdviceRestController.java`) creates an `Advice` entity of type `TRANSFER` in state `OPEN`. Positions are stored in `AdvicePosition`. A `MessageProcessType.ADVICE_TRANSFER_IMPORT` service-log entry is written on success or failure.

Constraints enforced at creation:
- Positions list must be non-empty (`WmsConstants.NO_POSITION`).
- Only one order per batch is allowed (`WmsConstants.TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH`).
- `transfer_id` must be unique — duplicate `transferId` throws `ENTITY_ALREADY_EXITS`.

### 4.2 From OMS order import (source side)

The **source** WMS receives the customer order batch via `OrderRestController`. For `TRANSFER_INTRACOMPANY` and `TRANSFER_OFFSITE` batch types (`OrderRestController.java:146–160`):

- Exactly one order per batch is enforced.
- `transfer_id` must be set on the batch and must be unique across `CustomerorderBatch`.
- The batch `transferId` is stored on `CustomerorderBatch.transferid` and propagated to the outbound `Billoflading.transferId` at BOL creation time.

### 4.3 Manual activation (web UI)

Web UI operators browse open transfer orders via `/v3/transfers/openTransfer` or `/v3/transfers/allOpenTransfer` (`TransfersController.java`), then activate the order to begin the staging workflow.

---

## 5. Stock Movement and Unit Load Transfer

### 5.1 Activate and assign transfer lane

```
GET /v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}
```

`TransfersController:153` calls two service methods in sequence (two separate transactions):

1. `TransferOrderService.activateTransferOrder(locationId, customerOrderId)` (`TransferOrderService.java:101`)
   - Pessimistic lock: `customerorderRepository.findByIdForUpdate`
   - Validates the lane is still available via `getAvailableTransferLanes`
   - Sets `Customerorder.transferlaneId = locationId`
   - Sets `Customerorder.state = CUSTOMER_ORDER_ACTIVATED` (505)

2. `TransferOrderService.assignTransferLaneToTransferOrder(locationId, customerOrderId)` (`TransferOrderService.java:71`)
   - Pessimistic lock on the order again
   - Re-validates lane availability
   - Sets `Customerorder.state = CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` (510)

**Warning:** These are two separate transactions. If step 1 commits but step 2 fails, the order sits in state 505 with a `transferlaneId` set but state not yet 510. Mobile operators won't see it (they query state 510 only). Recover via `GET /v3/transfers/assignTransferLane/{customerOrderId}/{locationId}` or `GET /v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}`.

Lane assignment can be changed later:
- `GET /v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}` — calls `assignTransferLaneToTransferOrder` again
- `GET /v3/transfers/unlinkTransferLane/{customerOrderId}` — clears `transferlaneId` only (no state change)

### 5.2 Mobile picking to transfer lane

Once state = 510, the order appears on the mobile transfer page:

```
/mobile/transfer-order   (role gate: WEB_UI_VIEW_TRANSFER_ORDER)
```

`MobileTransferOrderService.updateOrderList()` (`MobileTransferOrderService.java:73`) queries `customerorderRepository.findByState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED)` (state 510). Only orders at state 510 appear.

For each order position, the service calculates how much stock is **already on the transfer lane** via `calculateStockOnStagingLane()` (line 320) — iterates all unit loads at the lane location and sums stock units by SKU. The delta between required and present is the outstanding pick quantity (`updateOrder`, line 105).

Pick source resolution (`updateOrderPositionPickSources`, line 174):

1. Queries all unlocked stock units for the target SKU (`BusinessObjectLockState.NOT_LOCKED`).
2. Prioritises deep-storage locations first, then non-flowbin, then flowbin.
3. Returns a `TransferOrderPositionPickSourceDto` list.

When a mobile operator scans a unit-load label, `validateUnitByUnitLoadInput` (line 239) matches it against the source list. `transferStock` (line 257) then:
- If `stockUnit.availableAmount <= amountLeft` and not reserved: moves the whole unit load to the transfer lane via `unitloadBusinessService.transferUnitLoadToLocation`.
- If reserved: splits the available amount into a new unit load at the transfer lane via `stockunitBusinessService.transferStockToUnitLoad`.
- If `stockUnit.availableAmount > amountLeft`: splits exactly `amountLeft` into a new unit load.

### 5.3 Stock validation

`TransferOrderService.isEnoughStockOnTransferLane(customerOrder)` (`TransferOrderService.java:127`) returns `null` if the lane has exactly the right quantities, or an error string if any SKU is missing, over-supplied, or unrecognised. This is advisory — the caller (`transferOrder`) enforces it as a hard gate (`if (enoughStockOnTransferLane != null) throw new BusinessException(...)`).

SKU overview is available via:
```
GET /v3/transfers/skus?orderBatchId={id}
```
(`TransferOrderService.getSKUOverview`, line 196)

Unit load detail (what's on the lane vs. in storage):
```
POST /v3/transfers/unitLoads
```
(`TransferOrderService.getTransferLineUnitLoads`, line 230) — queries across `AREA_INBOUND`, `AREA_STORAGE_PICKING`, `AREA_STORAGE_PICKING_REPLENISH`, `AREA_STORAGE_REPLENISH`, `AREA_DEEP_STORAGE`, `AREA_USERS`.

---

## 6. Intracompany BOL Path

### 6.1 Pack step — `BillofladingService.transferOrder()`

```
GET /v3/transfers/runTransfer/{orderId}
```

`TransfersController:250` → `BillofladingService.transferOrder(customerOrderId)` (`BillofladingService.java:936`). One `@Transactional` boundary.

Writes in order:
1. `isEnoughStockOnTransferLane` — hard gate; throws on insufficient stock (line 944).
2. New pallet `Unitload` at `transferLane` (type `PALLET`, code `CODE_PACKAGING`, label from `PRINTING_SEQUENCE_NAME_DEFAULT_OUTBOUND_PALLET_LABEL`) — line 958.
3. New parcel `Unitload` at `transferLane` (type `PACKAGE`, label = `customerOrder.parcelexternalnumber`) — line 959.
4. `parcel.carrierunitloadId = pallet.id` — line 961.
5. `combineStock(...)` for every unit load currently at the transfer lane — moves stock into the parcel, queues source unit loads for deletion (line 968–975).
6. Source unit loads sent to nirvana (`sendToNirvana`, code `CODE_SEND_TO_NIRVANA`) — line 973–975.
7. `Customerorder.state = PACKED` (650); `customerOrder.parcelId = parcel.id` — line 977–979.
8. `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED` (530); `coOrderBatch.staginglaneId = null` — lines 983–985.

Note: `ORDER_BATCH_CLUB_RUN_FINISHED` is reused here for "batch packed and ready to ship" — it does not mean a club run finished. See §11 item 4.

### 6.2 Outbound BOL creation and truck load

Standard BOL truck-loading flow applies. At BOL creation, `BillOfLadingController` stamps `billOfLading.transferId` from `orderBatch.transferid` (or a new UUID if not set) — `BillOfLadingController.java:84–95`.

### 6.3 Source close — `BillofladingService.closeBOL()`

```
GET /v3/billOfLading/closeOutboundBol/{id}
```

`BillofladingService.closeBOL` (`BillofladingService.java:263`) — the TRANSFER_INTRACOMPANY branch:

- Guard: BOL state must be `CREATED`, `OPEN`, or `TRUCK_LOADING` — state `TRANSFER` throws `"Can not close BOL. BOL is in transfer!"` (line 283).
- For type `TRANSFER_INTRACOMPANY`:
  - `bolState = BillOfLadingState.TRANSFER` (not `CLOSED`) — line 315–317.
  - `entityLock = BusinessObjectLockState.TRANSFER` (404) — line 318–320.
  - `activityCode = CODE_TRANSFER_TRANSFER_IN_SHIPPING` — line 321–323.
- After all positions and unit loads are processed, OMS is notified via `OmsNotificationHelper.deferToCommit` (after-commit hook) posting to `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY` — line 579–594.

Post-close state: `BOL.state = TRANSFER`; all pallet/parcel `Unitload.entityLock = TRANSFER`; stock `Stockunit.entityLock = TRANSFER`. Stock is "in flight" and locked at source.

### 6.4 Destination receipt

OMS pushes an advice at the destination WMS:

```
PUT /rest/advice/createTransfer
```

This creates an `Advice` of type `TRANSFER`, state `OPEN` with positions from the BOL payload.

Destination operator or OMS accepts the advice via:

```
PUT /rest/order/finishedTransfer
```

`OrderRestController:907` → `BillofladingService.finishTransfer(acceptTransferDTO.getTransferId())`.

The `finishTransfer` path in v1 also fires the OMS `WEBSERVICE_ACCEPT_TRANSFER` callback (see `OrderRestController.java:920–946`, which logs the call via `MessageProcessType.ORDER_BATCH_FINISHED_TRANSFER`).

### 6.5 Intracompany BOL finalization — `BillofladingService.finishTransfer()`

Triggered by the OMS callback landing at the **source** WMS (or manually):

```
GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}
```

`BillOfLadingController:291` → `BillofladingService.finishTransfer(transferId)` (`BillofladingService.java:1119`).

Lookup: `billofladingRepository.findByTransferId(transferId)` — uses `transferId` string, not BOL primary key.

`finishTransfer(Billoflading)` (line 1129) — **no class-level `@Transactional`** on this private path; transaction boundary is the calling public method:

1. Guard: `BOL.type` must be `TRANSFER_INTRACOMPANY` — throws otherwise (line 1132).
2. `BOL.state = CLOSED` — line 1139.
3. Walk all `BillofladingPosition`s row-by-row (not bulk JPQL as in v2):
   - Skip positions where `carrierId != null` (non-pallet top-level positions).
   - Set pallet `BillofladingPosition.state = CLOSED`.
   - Set all child parcel `BillofladingPosition.state = CLOSED`.
   - Set all grandchild position `BillofladingPosition.state = CLOSED`.
4. For each pallet `BillofladingPosition`:
   - Move pallet `Unitload` to `STORAGE_LOCATION_SHIPPED` via `unitloadBusinessService.transferUnitLoadToLocation(pallet, shippedLocation, true, CODE_SHIPPING, bol.number, null)` — line 1163.
   - `pallet.entityLock = BusinessObjectLockState.SHIPPED` — line 1166.
   - For each child parcel `Unitload`: `parcel.entityLock = SHIPPED` — line 1171.
   - For each `Stockunit` on each parcel: `stockUnit.entityLock = SHIPPED` — line 1176.

Terminal state: `BOL.state = CLOSED`; all unit loads at `SHIPPED` location; `entityLock = SHIPPED`.

---

## 7. Receiving at Destination Facility

The destination-side flow uses the standard advice-receiving workflow:

1. `PUT /rest/advice/createTransfer` — creates `Advice.type = TRANSFER`, state `OPEN`.
2. Destination operators use the web UI to accept and process the advice.
3. `PUT /rest/order/finishedTransfer` (`OrderRestController:907`) — calls `BillofladingService.finishTransfer(transferId)` at the **source** WMS (the OMS orchestrates the cross-facility callback), and logs `ORDER_BATCH_FINISHED_TRANSFER` to the message table.

The destination putaway follows the standard receiving/putaway workflow. See `wms1-bol-truck-loading-workflow.md` for the standard advice-receipt path.

---

## 8. State Transitions

### 8.1 `Customerorder` states

| State | Value | Written by | Service:Line |
|---|---|---|---|
| `RAW` | 0 | OMS order import | `OrderRestController` |
| `CUSTOMER_ORDER_ACTIVATED` | 505 | Activate order | `TransferOrderService.activateTransferOrder:114` |
| `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` | 510 | Assign lane | `TransferOrderService.assignTransferLaneToTransferOrder:85` |
| `PACKED` | 650 | Run transfer (pack) | `BillofladingService.transferOrder:977` |
| `FINISHED` | 700 | Standard finish | downstream |

### 8.2 `Billoflading` states (TRANSFER_INTRACOMPANY type)

| State | Written by | Service:Line |
|---|---|---|
| `CREATED` | BOL creation | `BillOfLadingController` |
| `OPEN` | Open BOL | standard |
| `TRUCK_LOADING` | Truck load start | standard |
| `TRANSFER` | `closeBOL` (intracompany branch) | `BillofladingService.closeBOL:315` |
| `CLOSED` | `finishTransfer` | `BillofladingService.finishTransfer:1139` |

### 8.3 `CustomerorderBatch` states

| State | Value | Written by | Service:Line |
|---|---|---|---|
| `ORDER_BATCH_CLUB_RUN_FINISHED` | 530 | Pack step | `BillofladingService.transferOrder:983` |

### 8.4 `Unitload` / `Stockunit` entity locks

| Lock | Value | Set at | Cleared at |
|---|---|---|---|
| `TRANSFER` | 404 | `closeBOL` (TRANSFER_INTRACOMPANY branch) | `finishTransfer` (replaced by `SHIPPED`) |
| `SHIPPED` | (see constants) | `finishTransfer` | N/A (terminal) |

---

## 9. REST Endpoints

### 9.1 Source-side (web UI)

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `GET /v3/transfers/transferOrder/{customerOrderId}` | GET | `TransfersController:69` | Retrieve transfer-order detail |
| `GET /v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` | GET | `TransfersController:93` | Detail by batch ID |
| `GET /v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}` | GET | `TransfersController:153` | Activate + assign lane (2 transactions) |
| `GET /v3/transfers/assignTransferLane/{customerOrderId}/{locationId}` | GET | `TransfersController:184` | Assign lane only |
| `GET /v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}` | GET | `TransfersController:99` | Change the assigned lane |
| `GET /v3/transfers/unlinkTransferLane/{customerOrderId}` | GET | `TransfersController:127` | Unlink the lane (clears `transferlaneId`) |
| `GET /v3/transfers/runTransfer/{orderId}` | GET | `TransfersController:250` | Execute pack (calls `BillofladingService.transferOrder`) |
| `GET /v3/transfers/openTransfer` | GET | `TransfersController:277` | List open transfer orders (paginated) |
| `GET /v3/transfers/allOpenTransfer` | GET | `TransfersController:296` | All open transfers |
| `GET /v3/transfers/activeTransfer` | GET | `TransfersController:301` | Active transfers |
| `GET /v3/transfers/closedTransfer` | GET | `TransfersController:320` | Closed transfers |
| `GET /v3/transfers/inactiveTransfer` | GET | `TransfersController:339` | `ACTIVATED`-state orders (OFFSITE + INTRACOMPANY) |
| `GET /v3/transfers/skus` | GET | `TransfersController` | SKU overview for a batch |
| `POST /v3/transfers/unitLoads` | POST | `TransfersController` | Unit load detail for lane/storage |
| `POST /v3/transfers/availableTransferLanes` | POST | `TransfersController:381` | Available lanes for an order batch |

### 9.2 BOL close (source side)

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `GET /v3/billOfLading/closeOutboundBol/{id}` | GET | `BillOfLadingController:205` | Normal close — puts INTRACOMPANY BOL in `TRANSFER` state |
| `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}` | GET | `BillOfLadingController:291` | Finalize transfer — `TRANSFER → CLOSED` |

### 9.3 Destination-side (unauthenticated `/rest/` endpoints)

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `PUT /rest/advice/createTransfer` | PUT | `AdviceRestController:355` | OMS pushes TRANSFER-type advice |
| `PUT /rest/order/finishedTransfer` | PUT | `OrderRestController:907` | OMS signals destination received; fires `finishTransfer` at source |

---

## 10. OMS Callbacks

| Callback | Fired from | Side |
|---|---|---|
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `BillofladingService.closeBOL` — `OmsNotificationHelper.deferToCommit` (line 593) | Source — after BOL enters `TRANSFER` state |
| `ORDER_BATCH_FINISHED_TRANSFER` (message log) | `OrderRestController.finishedTransfer` (line 924) | Destination/OMS — when `finishedTransfer` endpoint is called |

Note: In v1, the `WEBSERVICE_ACCEPT_TRANSFER` post-commit callback is not wired in `AdviceRestController.createTransfer` — the callback flow runs through `OrderRestController.finishedTransfer` instead. This differs from v2 where it fires from `AdviceService.acceptTransferAdvice`.

---

## 11. v1 vs. v2 Differences

| Aspect | v1 | v2 |
|---|---|---|
| `TransferOrderService` package | `service/` (same level as all services) | `service/` (same) |
| `activateTransferOrder` signature | `(Long locationId, Long customerOrderId)` — IDs only | `(Location lane, Customerorder co)` — entity objects |
| `finishTransfer` position close | Row-by-row saves in a nested loop (`finishTransfer:1142–1158`) | Bulk JPQL update (one SQL per entity type) |
| `finishTransfer` unitload lock | Row-by-row `entityLock = SHIPPED` per pallet/parcel/stockunit | Bulk JPQL |
| Accept-transfer callback | `OrderRestController.finishedTransfer` → `billofladingService.finishTransfer` + message log | `AdviceService.acceptTransferAdvice` → `omsNotificationService.sendAfterCommit(WEBSERVICE_ACCEPT_TRANSFER)` |
| Destination advice acceptance | Triggered by OMS via `PUT /rest/order/finishedTransfer` | Triggered by `AdviceRestController.acceptTransfer` or admin accept |
| Mobile transfer service | `MobileTransferOrderService` — full pick-source logic present | Same class, same logic |
| `buildStock` test helper | Present (`TransferOrderService.buildStock:282`) — creates test unit loads | Not present in v2 |
| Transaction annotation | Class-level `@Transactional` on `TransferOrderService` | Method-level with explicit rollback specs |
| `closeBOL` type check | String comparison `.equals("TRANSFER_INTRACOMPANY")` (line 315) | Constant reference |

---

## 12. Common Failure Modes

| Symptom | Root cause | Fix |
|---|---|---|
| Order stuck in state 505, no lane | `activateTransferOrder` committed but `assignTransferLaneToTransferOrder` failed (two-transaction split) | Re-call `GET /v3/transfers/assignTransferLane/{orderId}/{laneId}` |
| Order at state 510 but not visible on mobile | `transferlaneId` is null despite state 510 | Assign lane first; `MobileTransferOrderService.updateOrderList` will throw on null lane |
| `runTransfer` fails with "Not enough stock on transfer lane" | Picks not complete; `isEnoughStockOnTransferLane` returned non-null | Check `CustomerorderPosition` amounts vs. stock on lane; complete remaining picks |
| `runTransfer` fails with "Too much stock for SKU=X" | Over-pick; more stock on lane than order requires | Remove excess stock from lane, then retry |
| `closeOutboundBol` throws "Can not close BOL. BOL is in transfer!" | BOL already in `TRANSFER` state; operator is trying to close again | The correct endpoint is `closeIntraCompanyTransfer/{transferId}`, not `closeOutboundBol` |
| BOL stuck in `TRANSFER` state indefinitely | Destination never called `PUT /rest/order/finishedTransfer`; OMS cross-facility callback never fired | Check `message` table at source for `ORDER_BATCH_FINISHED_TRANSFER` entries; check OMS for delivery status; manually trigger `closeIntraCompanyTransfer/{transferId}` if confirmed received |
| Stock locked as `TRANSFER (404)` at source, can't pick for other orders | `finishTransfer` never ran; stock is correctly in-flight | Do not clear `entityLock` via SQL; trigger `finishTransfer` via the BOL close endpoint |
| `finishTransfer` throws "Found outbound BOL type: REGULAR expected TRANSFER_INTRACOMPANY" | Wrong BOL looked up; `findByTransferId` matched a non-transfer BOL | Verify `transferId` value; check for `Billoflading.transferId` duplicates |
| `CustomerorderBatch` in `ORDER_BATCH_CLUB_RUN_FINISHED` but not a club order | Expected — `BillofladingService.transferOrder:983` sets this state for all transfer pack steps | Not a bug; state means "packed and ready to ship" in transfer context |
| Mobile operator can't see transfer page | Missing `WEB_UI_VIEW_TRANSFER_ORDER` Keycloak role (page uses web-UI role, not mobile-UI role) | Grant `WEB_UI_VIEW_TRANSFER_ORDER` role in Keycloak; note v1 naming convention uses `WEB_UI_*` for mobile pages too |

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | `TransferOrderService` (6 methods), `TransfersController` (14 endpoints), `BillofladingService.transferOrder` (line 936), `BillofladingService.closeBOL` TRANSFER_INTRACOMPANY branch (line 315), `BillofladingService.finishTransfer` (line 1119/1129), `MobileTransferOrderService` (full), `AdviceRestController.createTransfer` (line 355), `OrderRestController.finishedTransfer` (line 907), `WmsConstants` transfer constants, `BillOfLadingController.closeIntracompanyTransfer` (line 291) | All file:line refs confirmed against `src/main/java` | Code read (grep + targeted Read) |

**Re-verify every 90 days.** Next due: **2026-07-25** — transfer flow is stable but any new `OrderBatchType` value or refactor to `finishTransfer` invalidates §8 and §6.5.
