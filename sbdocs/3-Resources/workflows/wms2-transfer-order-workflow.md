---
title: "WMS v2 — Transfer Order Workflow"
type: workflow
status: active
version: v2
scope: transfer-order
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: code read of v2/wms2-api origin/develop df30fa62 — TransferOrderService + TransfersController + BillofladingService.transferOrder/finishTransfer + AdviceService.acceptTransferAdvice + AdviceController accept routes + OrderRestController.finishedTransfer; SBDEV-1762 partial-depletion toggle (see plan SBDEV-1762-transfer-lane-club-like-depletion)
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ./wms2-bol-truck-loading-workflow.md
  - ./wms2-club-run-workflow.md
  - ./wms2-receiving-putaway-workflow.md
tags:
  - workflow
  - transfer-order
  - transfer
  - wms2
---

# WMS v2 — Transfer Order Workflow

**Scope:** Inter-facility / intra-company order movement from source warehouse activation through destination receipt · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-11-11

---

## 1. Overview

A transfer order moves inventory between two facilities of the same or affiliated tenants. It's a subset of the customer-order lifecycle with **distinct state transitions** (activation lands directly on `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`; `CUSTOMER_ORDER_ACTIVATED` is only re-entered by an unlink, §4.1) and a **distinct BOL type** (`TRANSFER_INTRACOMPANY`), which causes the BOL to pass through a `TRANSFER` state instead of going directly `TRUCK_LOADING → CLOSED`. The destination warehouse receives an `Advice` and fires a different OMS callback (`WEBSERVICE_ACCEPT_TRANSFER` instead of `SHIPPED`).

Two things to keep in mind:

1. **Transfer orders use the same `Customerorder` entity** as normal orders but follow a different state track. Integer states 505 (`CUSTOMER_ORDER_ACTIVATED`) and 510 (`CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`) are transfer-specific branches; don't confuse them with the "activated" / "staging lane" states 520/525 (`ORDER_BATCH_ACTIVATED`, `ORDER_BATCH_STAGING_LANE_ASSIGNED`) used by customer batches. **505 has exactly one writer in `src/main`: `TransferOrderService.unlinkTransferLaneFromTransferOrder`** (`TransferOrderService.java:124`; `grep -rn CUSTOMER_ORDER_ACTIVATED src/main/java` finds no other `setState`). Activation does not persist 505 at all.
2. **`TRANSFER_INTRACOMPANY` BOL type** splits `closeBOL` into two operations — the source facility calls `closeBOL` to put the BOL in `TRANSFER` state; the destination facility's acceptance leads OMS to call `finishTransfer` (via `PUT /rest/order/finishedTransfer`) to move `TRANSFER → CLOSED`. Don't call `closeBOL` a second time on a transfer BOL — it refuses with "Can not close BOL. BOL is in transfer!" (`BillofladingService.java:385-386`).

---

## 2. Entity Cast

| Entity | State track | Role |
|---|---|---|
| `Customerorder` | `RAW → CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED (510) → PACKED (650) → FINISHED (700)` (or `CANCELED (800)`); 505 only after an unlink (§4.1) | The transfer order |
| `CustomerorderBatch` | may reach `ORDER_BATCH_CLUB_RUN_FINISHED (530)` via transfer cascade (see §5) | Batch rollup when transfers are per-batch |
| `Billoflading` | `CREATED → OPEN → TRUCK_LOADING → TRANSFER → CLOSED` (for type `TRANSFER_INTRACOMPANY`) | Shipping manifest |
| `BillofladingPosition` | `TRUCK_LOADING → CLOSED` via bulk JPQL | BOL line items |
| `Advice` | `CREATED/OPEN → FINISHED` via `acceptTransferAdvice` | Destination-side receipt notice |
| `Unitload` / `Stockunit` | no state; `entityLock` set to `TRANSFER` during in-flight phase | The actual shipped inventory |

---

## 3. Lifecycle

```
Source warehouse
  │
  │   OMS creates transfer order → Customerorder.state = RAW
  │
  ▼   Web UI: /v3/transfers/openTransfer, /allOpenTransfer (browse candidates)
  │
  │   Web UI: /v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}
  │       [TransfersController → TransferOrderService.activateAndAssignTransferLane]
  │       ONE transaction; 505 is never persisted. Refuses an order already at >= 510 (SBDEV-4038).
  │
  ▼   Customerorder.transferlaneId = locationId
  │   Customerorder.state = CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED (510)
  │
  │   Web UI: /v3/transfers/assignTransferLane/{customerOrderId}/{locationId}  (or /reassignTransferLane/…)
  │       (explicit lane change while still below PACKED — both routes call
  │        TransferOrderService.assignTransferLaneToTransferOrder, which refuses state > 510)
  │
  │   Web UI: /v3/transfers/unlinkTransferLane/{customerOrderId}
  │       [TransferOrderService.unlinkTransferLaneFromTransferOrder → lane cleared, state = 505]
  │       (the only writer of 505; re-activate to land 510 again)
  │
  │   Mobile pickers pick into the transfer lane
  │       Mobile UI: /mobile/transfer-order (role WEB_UI_VIEW_TRANSFER_ORDER)
  │       [MobileTransferOrderService.updateOrderList → queries state=510]
  │
  ▼   Stock lands on transferlane; CustomerorderPositions advance through PICKED (600)
  │
  │   Web UI: /v3/transfers/runTransfer/{orderId}
  │       [TransfersController → BillofladingService.transferOrder(customerOrderId)]
  │
  ▼   BillofladingService.transferOrder() [line 910]
  │   ├── Guard: refuses customerOrder.state >= PACKED (650) — "already been transferred" (SBDEV-3311 M-A)
  │   ├── Validate: transferOrderService.isEnoughStockOnTransferLane(customerOrder, partial)
  │   ├── Create pallet Unitload at transferlane (CODE_PACKAGING)
  │   ├── Create parcel Unitload at transferlane with customerOrder.parcelexternalnumber
  │   ├── parcel.carrierunitloadId = pallet.id
  │   ├── combineStock(...) for every existing unitload on the lane
  │   │     moves stock into parcel, empties then deletes source ULs
  │   ├── Customerorder.state = PACKED (650), parcelId = parcel.id       [line 1006]
  │   ├── CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED (530) [line 1011]
  │   └── if WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED (default OFF):
  │         outbox RELEASED + STARTED notifications (never FINISHED)     [line 1092+]
  │
  ▼   Outbound BOL created (type = TRANSFER_INTRACOMPANY) — see wms2-bol-truck-loading-workflow §3
  │
  │   Web UI: truck load + BOL close (standard flow)
  │       Web UI: /v3/billOfLading/closeOutboundBol/{id}
  │       [BillofladingService.closeBOL → state = TRANSFER (not CLOSED, due to BOL type)]
  │       In-tx outbox enqueue: ORDER_BATCH_SHIPPED → OMS (single row; transfers are never chunked)
  │
  ▼   BOL.state = TRANSFER; Unitload.entityLock = TRANSFER; stock "in flight"
  │
  ╔═══════════════════════════════════════════════════════════════════
  ║  Physical truck transports the pallet to destination warehouse
  ╚═══════════════════════════════════════════════════════════════════
  │
  ▼   Destination warehouse receives
  │
  │   Destination OMS pushes an Advice of type TRANSFER → wms2-api
  │       PUT /rest/advice/createTransfer      [AdviceRestController.createTransfer]
  │       [creates Advice.state = OPEN]
  │
  │   Destination operator accepts the advice (web UI)
  │       POST /v3/advice/closeInboundBol  or  GET /v3/advice/closeInboundBol/{id}
  │       [AdviceController → AdviceService.acceptTransferAdvice, line 400]
  │
  ▼   Advice.state = CREATED/OPEN → FINISHED
  │   Positions bulk-updated to FINISHED
  │   Outbox-enqueued in-tx: WEBSERVICE_ACCEPT_TRANSFER → OMS (see §7)
  │
  │   Source warehouse closes the intracompany BOL — normally OMS, best-effort, after the destination accepted:
  │       PUT /rest/order/finishedTransfer     [OrderRestController.finishedTransfer]
  │       or the admin route GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}
  │       [BillofladingService.finishTransfer(String), line 1586]
  │
  ▼   BillofladingService.finishTransfer()
  │   ├── Pessimistic lock on BOL row
  │   ├── Guard: BOL.type == TRANSFER_INTRACOMPANY                [line 1599]
  │   ├── CANCELLED → refused; CLOSED → no-op; CREATED/OPEN/TRUCK_LOADING → runShippingPhase first (§4.3)
  │   ├── BOL.state = CLOSED                                      [line 1667]
  │   ├── Bulk JPQL: all BillofladingPosition.state = CLOSED      [line 1700]
  │   └── Bulk transfer pallet Unitloads to SHIPPED location + Stockunit.entityLock = SHIPPED  [line 1771+]
  │
  ▼   Terminal: BOL.state = CLOSED; transfer complete
```

---

## 4. State Writers

### 4.1 Source side — `TransferOrderService`

At `service/TransferOrderService.java`:

| Method | Line | Writes | TM |
|---|---|---|---|
| `activateAndAssignTransferLane(Location lane, Customerorder co)` | 130 | `co.state = CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` (510) and `transferlaneId`, in ONE transaction (505 is never persisted); **refuses an order already at `>= 510`** ("is already active", SBDEV-4038); refuses a lane another open order holds (`getAvailableTransferLanesForUpdate`, `PESSIMISTIC_WRITE`). **SBDEV-4107 ✓ merged(SBDEV-4107: #665 fd712d7a, 2026-11-12):** after that locked read it re-runs `getAvailableTransferLanes` as a second statement, so a request that waited on the lane lock sees the other order's commit; it writes with `saveAndFlush` and maps a `uq_customerorder_open_transferlane` violation to the same refusal. See landmine 13. Called by the activate route (`TransfersController.activateTransferOrder`). *(260629-activate-transfer-atomicity)* | `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` |
| ~~`activateTransferOrder(Location lane, Customerorder co)`~~ | — | **Deleted under SBDEV-3183 (2026-10-20).** It had no caller in `src/main` and saved `505` with a lane held, the stranded shape 260629 removed. The controller handler of the same name is unaffected. | — |
| `assignTransferLaneToTransferOrder(Location lane, Customerorder co)` | 90 | `co.state = CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` (510); sets `transferlaneId`. **Refuses an order already past 510** (`state > 510`: "has already run … so its transfer lane can't change", SBDEV-4038), because Run Transfer leaves the order at PACKED 650 and re-setting 510 would put it back on the handheld list and past the run guard. Same post-lock re-check and index backstop as activate (SBDEV-4107 ✓ merged(SBDEV-4107: #665 fd712d7a, 2026-11-12)). Called by `/assignTransferLane` and `/reassignTransferLane` | same |
| `assignTransferLane(Customerorder co)` | 161 | `co.state = 510` (variant without location arg). ⚠ **No caller in `src/main`** (`grep -rn '\.assignTransferLane(' src/main/java` → no hits): dead code with no state guard | none |
| `unlinkTransferLaneFromTransferOrder(Customerorder co)` | 118 | clears `transferlaneId` **and sets `co.state = CUSTOMER_ORDER_ACTIVATED` (505)** — the only writer of 505 (`:124`; the old "no state change" cell was wrong, the reset was added to stop 510-without-lane rows NPE-ing `MobileTransferOrderService`). ⚠ **Unlike assign/activate it has no state guard** (§10 item 14) | `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` *(added 2026-06-29, fix `260629-transfer-lane-leak-on-cancel`; previously **none** → ran on the `@Primary` landlord TM in auto-commit)* |
| `isEnoughStockOnTransferLane(Customerorder co)` | 169 | validation only; returns error string or null | none |
| `isEnoughStockOnTransferLane(Customerorder co, boolean partial)` | 178 | **SBDEV-1762** overload. `partial=false` (default/OFF) delegates to the single-arg exact-match gate (byte-identical). `partial=true` (per-tenant opt-in) uses **reserved-adjusted** availability (`amount − reservedamount`), keeps only the "not enough" block, and DROPS the "too much" + foreign-SKU rejects so mixed/excess stock can share the lane. | none |

### 4.2 Pack step — `BillofladingService.transferOrder()`

At `service/BillofladingService.java:910`. `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`.

Entry guard (SBDEV-3311 M-A, `:935`): a customer order whose `state >= PACKED` (650) is refused ("has already been transferred"). `runTransfer` is a mutating GET with no idempotency, and `isEnoughStockOnTransferLane` does not stop a second run (the first run's pallet sits on the same lane holding the stock). A null state falls through unrefused.

Writes (in order inside one transaction):
1. New pallet `Unitload` at transferlane (code `CODE_PACKAGING`).
2. New parcel `Unitload` with `customerOrder.parcelexternalnumber`, `carrierunitloadId = pallet.id`.
3. `combineStock(...)` per source UL on the lane — moves stock into parcel, empties source.
4. `Customerorder.state = PACKED` (650) and `parcelId = parcel.id` — line 1006.
5. `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED` (530), `staginglaneId = null` — line 1011.
6. SBDEV-1762 only when the partial-depletion sysprop is ON: throws "Transfer under-delivered" (rolling everything back) if a required SKU is unmet.
7. SBDEV-3311, only when `WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED` is true (absent = OFF, ships dark): enqueues `ORDER_BATCH_PICKING_RELEASED` then `ORDER_BATCH_PICKING_STARTED` on the outbox (`BillofladingService.java:1092+`). `ORDER_BATCH_PICKING_FINISHED` is deliberately never sent for a transfer (owner decision 2026-09-10; see the comment above the gate).

`ORDER_BATCH_CLUB_RUN_FINISHED` has exactly two writers in `src/main`: this method (`:1011`) and `CustomerorderBatchService.finalizeClubLine` (`:899`).

Note the `ORDER_BATCH_CLUB_RUN_FINISHED` write on a transfer batch — it reuses the "batch ready for shipping" state semantic. Don't confuse with actual club-run finalization. See [wms2-club-run-workflow §5](./wms2-club-run-workflow.md).

### 4.3 Close step — `BillofladingService.finishTransfer()`

At `service/BillofladingService.java:1586` (public `finishTransfer(String transferId)`, with the private `finishTransfer(Billoflading, boolean)` doing the close). `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`.

| Write | Line |
|---|---|
| Guard: BOL type must be `TRANSFER_INTRACOMPANY` | 1599 |
| `BillOfLading.state = CLOSED` (TRANSFER → CLOSED) | 1667 |
| Bulk JPQL: every `BillofladingPosition.state = CLOSED` | 1700 |
| Bulk transfer pallet `Unitload`s to `SHIPPED` location; `entityLock = SHIPPED` | 1771+ |

**From which states (SBDEV-3286 Phase 3, SBDEV-3728).** `finishTransfer` finishes a BOL from any non-terminal state, not only `TRANSFER`, because OMS calls it best-effort and completes the transfer whatever WMS answers. `CLOSED` is a no-op; `CANCELLED` is refused, and the refusal reason is returned as the 400 `description` and stored as the FAILED message row's `answer`. A BOL still at `CREATED` / `OPEN` / `TRUCK_LOADING` first runs closeBOL's shipping phase (`runShippingPhase` — orders and order positions `FINISHED`, batches finalised and their staging lane released, `shipped` date, `TRANSFER_IN_SHIPPING` audit, `ORDER_BATCH_SHIPPED` enqueued), then the close above. That notification reaches OMS after it completed the transfer; OMS treats it as a replay (`LegacyTransferShipService`: destination `createTransfer` answers "already exists", the parcel is already `DELIVERED`). The line numbers in this table were refreshed 2026-11-11 against `df30fa62` and will drift again; grep the quoted writes.

### 4.4 Destination side — `AdviceService.acceptTransferAdvice()`

At `service/AdviceService.java:400`. `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`. Reached from `AdviceController` (`POST /v3/advice/closeInboundBol` and `GET /v3/advice/closeInboundBol/{id}`, TRANSFER-type advices only).

Guards: advice type must be `TRANSFER`; state must be `CREATED` or `OPEN`; unless `allowshortdelivery`, every position must be fully received ("Not all notified amount received").

Writes:
1. `Advice.state = FINISHED` (from `CREATED` or `OPEN`).
2. Bulk position update: `Adviceposition.state = FINISHED`.
3. In-tx outbox enqueue of `ADVICE_ACCEPT_TRANSFER` (`WEBSERVICE_ACCEPT_TRANSFER`; line 452) — not a post-commit hook. A serialisation failure throws `FacadeException` and rolls back the accept.

---

## 5. REST Endpoints

### 5.1 Source-side (web UI + mobile)

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `/v3/transfers/transferOrder/{customerOrderId}` | GET | `TransfersController` | Retrieve transfer-order detail |
| `/v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` | GET | same | Detail by batch ID |
| `/v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}` | GET | same | Change the assigned lane |
| `/v3/transfers/unlinkTransferLane/{customerOrderId}` | GET | same | Unlink the lane (clears transferlaneId) |
| `/v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}` | GET | same | Activate + assign lane in one call → `TransferOrderService.activateAndAssignTransferLane` (one transaction; lands 510) |
| `/v3/transfers/assignTransferLane/{customerOrderId}/{locationId}` | GET | same | Assign lane only → `assignTransferLaneToTransferOrder` (same service call as `reassignTransferLane`) |
| `/v3/transfers/runTransfer/{orderId}` | GET | same | **Execute pack** (calls `BillofladingService.transferOrder`) |
| `/v3/transfers/openTransfer` | GET | same | List open transfer orders (paginated) |
| `/v3/transfers/allOpenTransfer` | GET | same | All open transfers (no pagination). Feeds the Create Outbound BOL → Transfer dropdown; since SBDEV-3930 each row carries `bolRefusal` (null = a Transfer BOL is allowed, same rule as the create guard — `TransferBolPolicy`, SBDEV-3915) and `existingBolName`, and the UI disables refused rows |
| `/v3/transfers/activeTransfer` | GET | same | Active transfers |
| `/v3/transfers/closedTransfer` | GET | same | Closed transfers |
| `/v3/transfers/inactiveTransfer` | GET | same | `ACTIVATED` state orders (OFFSITE + INTRACOMPANY types) |
| `/v3/transfers/skus` | GET | same | SKU overview for a batch |
| `/v3/transfers/unitLoads` | POST | same | Pallet/parcel detail; body requires `orderBatchId` and `onlyTransferLocation` (SBDEV-3328: 422 on a bad flag, `[]` for an unknown/orderless batch) |
| `/v3/transfers/parcels` | POST | same | Order/parcel detail for a batch (`orderBatchId` required) |
| `/v3/transfers/availableTransferLanes` | POST | same | Free transfer lanes for the batch's first order; `[]` when the batch has no order |

**Enumeration (2026-11-11, `df30fa62`):** `grep -nE '@GetMapping|@PostMapping|@RequestMapping\(value' controller/TransfersController.java | grep -v '^[0-9]*://'` → **16** live routes (the commented-out `shipTransferOrder` and `activeBatch` are excluded). All carry `@RequiresFunction(WEB_UI_VIEW_TRANSFER_ORDER)`; `/allOpenTransfer` is ANY-of with `WEB_UI_VIEW_BILL_OF_LADING` (its only caller is the BOL-create form). Every state-changing route here (`reassign`, `unlink`, `activate`, `assign`, `runTransfer`) is a mutating `GET`.

### 5.2 BOL close (source side, after transport)

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `/v3/billOfLading/closeOutboundBol/{id}` | GET | `BillOfLadingController:269` | Normal close → puts transfer BOL in `TRANSFER` state |
| `/v3/billOfLading/closeIntraCompanyTransfer/{transferId}` | GET | `BillOfLadingController:504` (handler `closeIntracompanyTransfer`, lowercase c; gated `WEB_UI_VIEW_TRANSFER_ORDER`) | **Finish transfer** (calls `finishTransfer`) — admin/manual route; zero UI callers |
| `/rest/order/finishedTransfer` | PUT | `OrderRestController:1077` | **OMS → WMS finish transfer** (body `AcceptTransferDto{transferId}`; calls the same `finishTransfer`; 204, or 400 with the service's refusal reason in `description`; no `facility_code` check). OMS calls it best-effort on the destination's acceptance and completes the transfer in OMS whatever WMS answers |

### 5.3 Destination-side

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `/rest/advice/createTransfer` | PUT | `AdviceRestController` | OMS pushes TRANSFER-type advice |
| `/v3/advice/closeInboundBol` | POST | `AdviceController:193` | Accept one or many inbound advices; TRANSFER-type → `acceptTransferAdvice` → outbox `WEBSERVICE_ACCEPT_TRANSFER` |
| `/v3/advice/closeInboundBol/{id}` | GET | `AdviceController:244` | Same, single advice |

⚠ Corrected 2026-11-11: this table previously listed `/rest/advice/acceptTransfer`; no such route exists (`grep -rn acceptTransfer controller` finds only the commented-out `/acceptTransferBol/{id}` and the service calls above).

---

## 6. OrderBatchType Semantics

From `service/WmsConstants.java:704–714` (`OrderBatchType`):

| Type | Purpose |
|---|---|
| `REGULAR` | Pick-pack, non-club, also used for `TRANSFER_OFFSITE` outbound BOLs |
| `CLUB` | Club-order batch (`wms2-club-run-workflow`) |
| `PICK_PACK` | Standard winery pick orders |
| `TRANSFER_OFFSITE` | External third-party transfer (no reciprocal advice flow) |
| `TRANSFER_INTRACOMPANY` | Inter-warehouse, same company — THIS flow |
| `HUB_AND_SPOKE` | Cross-docking (different callback: `WEBSERVICE_ACCEPT_HUB_AND_SPOKE`) |

The `TRANSFER_INTRACOMPANY` type is the only one that triggers the two-step close (`closeBOL` → `TRANSFER`, then `finishTransfer` → `CLOSED`). `TRANSFER_OFFSITE` goes direct to `CLOSED` like a normal shipment.

---

## 7. OMS Callbacks

| Callback | Fired from | Source-side or destination-side |
|---|---|---|
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `BillofladingService.closeBOL` (and `finishTransfer`'s shipping phase for a BOL still below TRANSFER) | Source — after BOL enters `TRANSFER` state; a transfer is never chunked (`WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` applies to REGULAR / HUB_AND_SPOKE only) |
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING`, `WEBSERVICE_ORDER_BATCH_PICKING` | `BillofladingService.transferOrder` (outbox) | Source — only when `WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED` is true (default OFF); FINISHED is never sent |
| `WEBSERVICE_ACCEPT_TRANSFER` | `AdviceService.acceptTransferAdvice` | Destination — when receiving advice is accepted |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `AdviceService.acceptHubAndSpokeAdvice` | Destination — for HUB_AND_SPOKE type only (distinct flow) |

⚠ **Corrected 2026-09-10 (SBDEV-3311).** This paragraph previously read *"All post-commit via
`omsNotificationService.sendAfterCommit(...)` or `TransactionSynchronizationManager.registerSynchronization`"*.
That has been **false since SBDEV-2238 Phase 2** and it contradicted
[wms2-oms-integration-map.md](../architecture/wms2-oms-integration-map.md). All three callbacks above go through
the **transactional outbox** — `outboxService.enqueue(OutboxMessage.builder()…)` inside the caller's tenant
transaction, dispatched later by `OutboxDispatcherJob`. Verified on `origin/develop` @ `22d19474`:
`AdviceService.acceptTransferAdvice` ends with `outboxService.enqueue(… .processType(WmsConstants.MessageProcessType.ADVICE_ACCEPT_TRANSFER) …)`
and contains no `sendAfterCommit` call.

The distinction is load-bearing, not cosmetic: `enqueue` is `Propagation.MANDATORY`, so the notification row
commits atomically with the state change and is retried by the dispatcher; `sendAfterCommit` is fire-and-forget
with no retry **and its guard is inverted** (SBDEV-3267 — `isActualTransactionActive()` is `true` inside
`afterCommit`, so nested call sites silently drop the POST, the `message` row and the metric). Anyone reasoning
about delivery guarantees from the old sentence would have reached the opposite conclusion about whether a
transfer callback can be lost.

⚠ Line numbers in §3, §4.2–§4.4 were refreshed 2026-11-11 against `df30fa62`; the 2026-09-10 note that they were
stale by ~420 lines is superseded. They will drift again — grep the quoted symbol first.

See [wms2-end-to-end-request-journey.md §5](../architecture/wms2-end-to-end-request-journey.md).

---

## 8. Transaction Boundaries

- `activateAndAssignTransferLane`, `assignTransferLaneToTransferOrder`, `unlinkTransferLaneFromTransferOrder`, `transferOrder`, `finishTransfer`, `acceptTransferAdvice` — each is one atomic `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`.
- **Pessimistic lock on BOL row** during `finishTransfer` via `findByIdForUpdate` — prevents concurrent `closeBOL` + `finishTransfer` on the same BOL.
- **The BOL lock does not fence a re-scan OFF the BOL (SBDEV-3491) ✓ merged(SBDEV-3491: #593 f7e747c9, 2026-10-31).** A TRANSFER BOL's pallet stays re-scannable at the gate. `scanGate` locks the BOL it loads onto and the pallet, never the BOL the pallet leaves, and its D0 purge deletes the pallet's positions there. `finishTransfer` therefore locks the pallets (`lockPalletsThenChildren`) **before** its bulk position UPDATE and reads the positions again under those locks. It ships only the pallets still on the BOL; a pallet that left is logged at WARN (`SBDEV-3491: finishTransfer bol=… closes without unit load(s) …`) and the BOL closes without it. Before the fix the pallet was shipped to Shipped/405 while it sat on the open BOL. **Exception, accepted 2026-10-31:** a BOL still *below* TRANSFER goes through closeBOL's `runShippingPhase` first, which has no re-read. There the same race rolls the call back on an optimistic-lock failure: nothing ships and the BOL stays open. Nothing retries it (OMS does not retry a 5xx): the signal is the FAILED message row and OMS's warning, and recovery is a manual call of the admin `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}`. Both outcomes are pinned by `FinishTransferRescanRaceIT`.
- `TransfersController.activateTransferOrder` (`TransfersController.java:162`) makes ONE call, `TransferOrderService.activateAndAssignTransferLane`, which lands state 510 + `transferlaneId` in one transaction (260629-activate-transfer-atomicity). The old two-transaction split (activate to 505, then assign) no longer exists; the `activateTransferOrder` service method that caused it was deleted under SBDEV-3183. An order is now at 505 only after an `unlinkTransferLane` (state 505, lane cleared) — recover it by activating again.
- Bulk JPQL in `finishTransfer` (position state, unitload relocation) — one SQL statement per entity type. See [wms2-bol-truck-loading-workflow §6.3](./wms2-bol-truck-loading-workflow.md).
- **Lane release on cancel (fix `260629-transfer-lane-leak-on-cancel`, 2026-06-29).** `CustomerorderService.cancelOrder` and `forceCancelOrder` now clear `transferlaneId` (guarded direct `setTransferlaneId(null)`) at the cancel transition, in addition to the existing `finalizeBatchIfComplete` release. Cancel paths use a **direct** clear, *not* `unlinkTransferLaneFromTransferOrder` (that helper resets state to `505` and would un-cancel). The lane-availability gate (`LocationRepository.getAvailableTransferLanes`) only excludes lanes held by orders with `state < FINISHED(700)`; since `CANCELED(800) ≥ 700`, the **real leak is abandonment** — a transfer order activated to 505/510 but never run *or* cancelled holds its lane forever. Operator recovery for a stuck order: `GET /v3/transfers/unlinkTransferLane/{customerOrderId}`. The activate→assign two-transaction split that stranded orders at 505-with-lane was closed by `260629-activate-transfer-atomicity` (above).

---

## 9. Mobile Transfer Process

Mobile page `/mobile/transfer-order` — role gate is `WEB_UI_VIEW_TRANSFER_ORDER` (see [wms2-keycloak-role-matrix §3.8](../architecture/wms2-keycloak-role-matrix.md) — the known naming oversight).

- Backed by `MobileTransferOrderService`.
- `updateOrderList()` queries `customerorderRepository.findByState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED)` (state 510) — only activated-and-lane-assigned orders appear on the mobile.
- Operator workflow is read-heavy; the actual pick fires through standard picking endpoints once the transfer lane has been assigned.

---

## 10. Known Landmines

1. **~~Two transactions to activate~~ — resolved.** `/activateTransferOrder/{id}/{loc}` is one transaction (`activateAndAssignTransferLane`); an order can no longer be stranded at 505-with-lane by activation. What remains: state 505 now means "unlinked" (lane cleared by `/unlinkTransferLane`), so a 505 order with a null lane is expected, not a defect; re-activate it. A **510 order with a null lane** is the invariant violation (`MobileTransferOrderService.updateOrderList` logs and skips it, `:122`).
2. **`closeBOL` does NOT terminate an intracompany transfer.** Source-side close leaves BOL in `TRANSFER`. Operators who expect the order "shipped" at this point are wrong — it's still in-flight. Only `finishTransfer` at the destination finalizes.
3. **`finishTransfer` requires BOL type `TRANSFER_INTRACOMPANY`.** Invoking it on a non-transfer BOL throws `BusinessException`. Don't copy the endpoint pattern for other BOL types.
4. **`BillofladingService.transferOrder` sets `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED`** even for non-club batches (`BillofladingService.java:1011`). This state name is misleading — it means "batch is packed and ready to ship," not "club run finished." Don't narrow the semantic on a refactor.
5. **`TRANSFER_OFFSITE` behaves differently from `TRANSFER_INTRACOMPANY`.** Offsite BOLs skip the `TRANSFER` state and close directly. If you generalize "transfer" logic, the `type` field branches are load-bearing.
6. **`WEBSERVICE_ACCEPT_TRANSFER` fires at destination, NOT at source.** Source-side `WEBSERVICE_ORDER_BATCH_SHIPPED` fires at `closeBOL`. OMS needs both to close the round-trip — if destination never accepts, the transfer sits in `TRANSFER` state indefinitely.
7. **Entity locks persist during in-flight phase.** `Unitload.entityLock = TRANSFER` + `Stockunit.entityLock = TRANSFER` prevent accidental re-use of the stock at source. Clearing these via SQL to "recover" a stuck transfer is the wrong fix — invoke `finishTransfer` with the correct `transferId`.
8. **No reopen for a finished transfer.** Once `Advice.state = FINISHED` at destination and BOL closes, there's no rollback path. A bad transfer needs a brand-new return / adjustment cycle.
9. **Mobile uses `WEB_UI_*` role.** The mobile transfer-order page is gated by `WEB_UI_VIEW_TRANSFER_ORDER`, not a `MOBILE_UI_*` role. A Keycloak realm that strictly separates web and mobile role sets will block mobile operators. Document this in tenant onboarding.
10. **`isEnoughStockOnTransferLane` validation is advisory.** It returns an error string the caller must check — it doesn't throw. A caller that ignores the return value will happily proceed with insufficient stock and produce an inconsistent pack.
11. **SBDEV-1762 — club-like partial depletion (per-tenant opt-in, default OFF).** Sysprop `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` (`WmsConstants.SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_KEY`, read once at the top of `transferOrder`). When ON, `transferOrder` depletes only the order's required SKUs/quantities (`min(needed, amount − reservedamount)`), leaves foreign SKUs / same-SKU excess / reserved stock on the lane, walks lane ULs + leaf SUs in ascending id order (deterministic lock acquisition), and fails loud (`BusinessException "Transfer under-delivered…"`) if any required SKU is unmet. OFF is byte-identical to the exact-match sweep above. Concurrency: the ON path stays on the canonical SU→UL→Location lock order (no cross-caller inversion); a rare same-lane concurrent-transfer 40P01 is an accepted atomic-rollback fail-fast (a deadlock-retry / primitive Location-first reorder is deferred to a follow-up). Carrier-staged lanes: ON only relocates a carrier UL to Nirvana if it is genuinely empty after depletion (else `relocateEmptiedContainer` would throw "is carrier!"). Full design: plan `SBDEV-1762-transfer-lane-club-like-depletion`.
12. **⚠ `ClubLineSkuDto.amountAvailable` is NOT a display value — it GATES the "Run Transfer" and "Run Club Line" buttons.** It is lane-scoped on purpose: `TransferOrderService.getSKUOverview` fills it from `StockunitRepository.getAmountAvailable(transferLaneId, itemdataId)`, a **single-location** query, and the web UI compares it to `amountRequired` in `showBadge()` → `readyToMove()` (transfer) / `disableRun` (club) → the buttons' `:disabled`. **Repointing it at a warehouse-wide figure enables the run against an EMPTY lane.** The on-screen subtitle *"Still waiting for all inventory to be moved to {lane}"* is the design intent in plain English. SBDEV-2951 therefore added a **separate additive** `amountOnHand` field and a separate "On hand" column rather than widening this one — and left `Qty at Lane` / `Total at Lane` labelled as they were, because those headers are accurate. Two further traps recorded there: (a) the club branch's `else` arm must stay, since `amountAvailable = null` makes `null < required` **false** in JavaScript and re-enables the run; (b) any warehouse-wide stock sum **must** exclude the `Shipped` and `Nirwana` sink locations — `Shipped` alone held 2,856,635 units / 87% of all stock rows on `dev_wh01_om1` (measured 2026-08-13), and one SKU's on-hand read 39 with the guard versus 26,911 without it. Full design: plan `SBDEV-2951-transfer-club-available-counts-lane-only`.
13. **The transfer-lane lock alone did not prevent double assignment. Fixed by [SBDEV-4107](https://app.clickup.com/t/868mv915q) ✓ merged(SBDEV-4107: #665 fd712d7a, 2026-11-12).**
    - **The defect.** `LocationRepository.getAvailableTransferLanesForUpdate` locks the **`location`** rows, but the
      assignment writes **`customerorder.transferlane_id`**, so the lane row never changed. Under READ COMMITTED, a
      request that waited on the lane lock resumed its statement on the original snapshot (EvalPlanQual re-checks only
      the locked row), so its `NOT EXISTS` still saw the lane as free. `TransferLaneRaceIT` reproduced this in the
      harness's strict mode: the subject was observed blocked by the holder's lane lock and still assigned lane A.
    - **The fix, in two layers.**
      - The assign and activate paths re-run `getAvailableTransferLanes` as a **second statement** after the lock, which
        takes a fresh snapshot. That is the normal refusal path.
      - V2.2.51 adds the partial unique index `uq_customerorder_open_transferlane ON customerorder(transferlane_id) WHERE
        transferlane_id IS NOT NULL AND state < 700` as the guarantee against any writer. Its violation is mapped to the
        same "transfer lane is not available anymore" refusal, not a 500.
    - **Remaining behaviour.**
      - Finished transfers keep their lane (WineCo PRD: 655 rows at 700 on 20 lanes), so the predicate stops at 700.
      - A path that rewound a lane-holding order from ≥700 back below 700 would now fail with 23505. None exists today;
        `TransferLanePredicateReentryIT` pins that fail-closed behaviour.
      - If the transaction holding the lane runs longer than 3 s, the waiting request gets 55P03 → 409 instead of the refusal.
    - **Exposure before the fix** (WineCo PRD, 2026-11-11): 0 shared lanes across 7 open transfer orders. The census found 0 duplicates on all 4 PRD tenants, all 4 UAT tenants and dev.
14. **⚠ `unlinkTransferLane` has no state guard and can regress a shipped order to 505 (found 2026-11-11; fixed by SBDEV-4113, which refuses `> 510` like the 4038 sibling ✓ merged(SBDEV-4113: #663 6854b216, 2026-11-12)).** PRD wsl-wineco 2026-11-11: 655 FINISHED transfer orders still hold a lane and were exposed. SBDEV-4038 added state guards to `activateAndAssignTransferLane` (refuses `>= 510`) and `assignTransferLaneToTransferOrder` (refuses `> 510`), but `unlinkTransferLaneFromTransferOrder` (`TransferOrderService.java:118-127`) unconditionally sets `transferlaneId = null` and `state = CUSTOMER_ORDER_ACTIVATED (505)`, and `GET /v3/transfers/unlinkTransferLane/{id}` (`TransfersController.java:137`) does not check state either. Run against an order already PACKED (650) or FINISHED (700) it rewrites the state back to 505 — the Open list offers lane actions on rows up to 670 (see the comment at `assignTransferLaneToTransferOrder`). By the guard's own reasoning (`BillofladingService.java:911-925`) the `>= PACKED` fence in `transferOrder` would then no longer refuse a second run once the order is re-activated; ⚠ unverified 2026-11-11: this consequence was inferred from the code, not reproduced. No test pins a refusal (`grep -rn unlinkTransferLane src/test` shows no PACKED/refusal case). Decided: same `> 510` refusal (SBDEV-4113). The text above describes develop `df30fa62`, before that merge.
15. **`TransferOrderService.assignTransferLane(Customerorder)` is dead code.** No caller in `src/main`, and it sets 510 with no guard; do not call it from new code.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| Transfer order at state 505 | §10 item 1 — 505 is the post-unlink state; re-activate via `/activateTransferOrder`. If it was already PACKED/FINISHED before it fell to 505, see §10 item 14 |
| BOL stuck in `TRANSFER` for days | §10 item 2 — destination never accepted advice; check destination's `Advice` state |
| "Cannot close BOL. BOL is in transfer!" | §3 + §10 item 3 — you want `finishTransfer`, not `closeBOL` |
| OMS shows transfer as shipped but not received | §7 — `WEBSERVICE_ORDER_BATCH_SHIPPED` fired; `WEBSERVICE_ACCEPT_TRANSFER` didn't. Check `message` table at destination |
| Non-club batch ended up in `ORDER_BATCH_CLUB_RUN_FINISHED` state | §10 item 4 — expected behavior for transfer packs |
| Stuck stock at source — can't move | §10 item 7 — `entityLock = TRANSFER` pending; don't clear via SQL |
| Mobile operator can't see transfer page | §9 + §10 item 9 — confirm Keycloak role |
| `runTransfer` rejects with "Not enough stock on transfer lane" | §10 item 10 — upstream picks didn't complete; check `CustomerorderPosition` states |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `TransferOrderService` (6 methods), `TransfersController` (14 endpoints), `BillofladingService.transferOrder` (line 702), `BillofladingService.finishTransfer` (line 898), `AdviceService.acceptTransferAdvice` (line 356), `OrderBatchType` constants, `MobileTransferOrderService`, OMS callback wiring | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-07-23 | SBDEV-1762 implemented on `feature/SBDEV-1762-transfer-lane-club-like-depletion`: `TransferOrderService.isEnoughStockOnTransferLane(co, boolean)` reserved-adjusted overload; `BillofladingService.transferOrder`/`combineStock` partial-depletion behind the `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` sysprop (default OFF); §4.1 + §10 item 11 added. States unchanged (CO→PACKED, batch→ORDER_BATCH_CLUB_RUN_FINISHED). 14 unit tests + verify script green. | §4.1/§10 updated; OFF byte-identical confirmed | Code read + unit suite |
| 2026-11-11 | Re-verified against wms2-api `origin/develop` `df30fa62`: `TransferOrderService` (activate/assign/unlink state guards, 505 single writer, dead `assignTransferLane`), `TransfersController` (16 live routes; +`/parcels`, `/availableTransferLanes`), `BillofladingService.transferOrder` (>= PACKED guard, SBDEV-3311 gated notifications, anchors 910/1006/1011), `finishTransfer` (anchors 1586/1599/1667/1700/1771; any-non-terminal acceptance per SBDEV-3286/3728/3491 confirmed), `AdviceService.acceptTransferAdvice` (400; outbox at 452), accept routes (`/v3/advice/closeInboundBol`, not `/rest/advice/acceptTransfer`), `OrderRestController.finishedTransfer`. Corrected §1–§5, §7, §8, §10 item 1/4, §11; added §10 items 14–15. Not re-verified: §10 items 11–13 prose beyond the sysprop name, `under-delivered` text and the open SBDEV-4107 claim (code unchanged: no partial unique index in `db/migration`); ClickUp state of SBDEV-4107 not checked. | See corrections | Code read (grep-based) |

**Re-verify every 90 days.** Next due: **2027-02-09** — transfer flow is stable; any new `OrderBatchType` value invalidates §6, and any change to the SBDEV-1762 partial-depletion path invalidates §10 item 11.
