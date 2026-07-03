---
title: "WMS v2 — Transfer Order Workflow"
type: workflow
status: active
version: v2
scope: transfer-order
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-08
verified_by: code read of v2/wms2-api TransferOrderService + TransfersController + BillofladingService.transferOrder/finishTransfer + AdviceService.acceptTransferAdvice
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
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

A transfer order moves inventory between two facilities of the same or affiliated tenants. It's a subset of the customer-order lifecycle with **distinct state transitions** (`CUSTOMER_ORDER_ACTIVATED` → `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`) and a **distinct BOL type** (`TRANSFER_INTRACOMPANY`), which causes the BOL to pass through a `TRANSFER` state instead of going directly `TRUCK_LOADING → CLOSED`. The destination warehouse receives an `Advice` and fires a different OMS callback (`WEBSERVICE_ACCEPT_TRANSFER` instead of `SHIPPED`).

Two things to keep in mind:

1. **Transfer orders use the same `Customerorder` entity** as normal orders but follow a different state track. Integer states 505 (`CUSTOMER_ORDER_ACTIVATED`) and 510 (`CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`) are transfer-specific branches; don't confuse them with the "activated" / "staging lane" states 520/525 used by customer batches.
2. **`TRANSFER_INTRACOMPANY` BOL type** splits `closeBOL` into two operations — the source facility calls `closeBOL` to put the BOL in `TRANSFER` state; the destination facility calls `finishTransfer` after receiving to move `TRANSFER → CLOSED`. Don't call `closeBOL` a second time on a transfer BOL — it'll refuse.

---

## 2. Entity Cast

| Entity | State track | Role |
|---|---|---|
| `Customerorder` | `RAW → CUSTOMER_ORDER_ACTIVATED (505) → CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED (510) → PACKED (650) → FINISHED (700)` | The transfer order |
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
  │       [TransfersController → TransferOrderService.activateTransferOrder]
  │
  ▼   Customerorder.state = CUSTOMER_ORDER_ACTIVATED (505)
  │   Customerorder.transferlaneId = locationId
  │
  │   Web UI: /v3/transfers/assignTransferLane/{customerOrderId}/{locationId}
  │       (called implicitly as part of activate, or explicitly to change lane)
  │       [TransferOrderService.assignTransferLaneToTransferOrder]
  │
  ▼   Customerorder.state = CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED (510)
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
  ▼   BillofladingService.transferOrder() [line 702]
  │   ├── Validate: transferOrderService.isEnoughStockOnTransferLane(customerOrder)
  │   ├── Create pallet Unitload at transferlane (CODE_PACKAGING)
  │   ├── Create parcel Unitload at transferlane with customerOrder.parcelexternalnumber
  │   ├── parcel.carrierunitloadId = pallet.id
  │   ├── combineStock(...) for every existing unitload on the lane
  │   │     moves stock into parcel, empties then deletes source ULs
  │   ├── Customerorder.state = PACKED (650)                            [line 744]
  │   └── CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED (530) [line 749]
  │
  ▼   Outbound BOL created (type = TRANSFER_INTRACOMPANY) — see wms2-bol-truck-loading-workflow §3
  │
  │   Web UI: truck load + BOL close (standard flow)
  │       Web UI: /v3/billOfLading/closeOutboundBol/{id}
  │       [BillofladingService.closeBOL → state = TRANSFER (not CLOSED, due to BOL type)]
  │       Post-commit: WEBSERVICE_ORDER_BATCH_SHIPPED fires to OMS
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
  │       POST /rest/advice/createTransfer     [AdviceRestController]
  │       [AdviceService → creates Advice.state = OPEN]
  │
  │   Destination operator accepts the advice
  │       POST /rest/advice/acceptTransfer or admin accept
  │       [AdviceService.acceptTransferAdvice, line 356]
  │
  ▼   Advice.state = CREATED/OPEN → FINISHED
  │   Positions bulk-updated to FINISHED
  │   Post-commit: WEBSERVICE_ACCEPT_TRANSFER fires to OMS (line 406)
  │
  │   Source warehouse closes the intracompany BOL
  │       Web UI: /v3/billOfLading/closeIntraCompanyTransfer/{transferId}
  │       [BillofladingService.finishTransfer, line 898]
  │
  ▼   BillofladingService.finishTransfer()
  │   ├── Pessimistic lock on BOL row
  │   ├── Guard: BOL.type == TRANSFER_INTRACOMPANY
  │   ├── BOL.state = TRANSFER → CLOSED                          [line 920]
  │   ├── Bulk JPQL: all BillofladingPosition.state = CLOSED      [line 929]
  │   └── Bulk transfer pallet Unitloads to SHIPPED location + Stockunit.entityLock = SHIPPED
  │
  ▼   Terminal: BOL.state = CLOSED; transfer complete
```

---

## 4. State Writers

### 4.1 Source side — `TransferOrderService`

At `service/TransferOrderService.java`:

| Method | Line | Writes | TM |
|---|---|---|---|
| `activateTransferOrder(Location lane, Customerorder co)` | 111 | `co.state = CUSTOMER_ORDER_ACTIVATED` (505) | `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` |
| `assignTransferLaneToTransferOrder(Location lane, Customerorder co)` | 86 | `co.state = CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` (510); sets `transferlaneId` | same |
| `assignTransferLane(Customerorder co)` | 125 | `co.state = 510` (variant without location arg) | none |
| `unlinkTransferLaneFromTransferOrder(Customerorder co)` | 104 | clears `transferlaneId` — no state change | `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` *(added 2026-06-29, fix `260629-transfer-lane-leak-on-cancel`; previously **none** → ran on the `@Primary` landlord TM in auto-commit)* |
| `isEnoughStockOnTransferLane(Customerorder co)` | 132 | validation only; returns error string or null | none |

### 4.2 Pack step — `BillofladingService.transferOrder()`

At `service/BillofladingService.java:702`. `@Transactional("tenantTransactionManager")`.

Writes (in order inside one transaction):
1. New pallet `Unitload` at transferlane (code `CODE_PACKAGING`).
2. New parcel `Unitload` with `customerOrder.parcelexternalnumber`, `carrierunitloadId = pallet.id`.
3. `combineStock(...)` per source UL on the lane — moves stock into parcel, empties source.
4. `Customerorder.state = PACKED` (650) — line 744.
5. `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED` (530) — line 749.

Note the `ORDER_BATCH_CLUB_RUN_FINISHED` write on a transfer batch — it reuses the "batch ready for shipping" state semantic. Don't confuse with actual club-run finalization. See [wms2-club-run-workflow §5](./wms2-club-run-workflow.md).

### 4.3 Close step — `BillofladingService.finishTransfer()`

At `service/BillofladingService.java:898`. `@Transactional("tenantTransactionManager")`.

| Write | Line |
|---|---|
| Guard: BOL type must be `TRANSFER_INTRACOMPANY` | 911 |
| `BillOfLading.state = CLOSED` (TRANSFER → CLOSED) | 920 |
| Bulk JPQL: every `BillofladingPosition.state = CLOSED` | 929–934 |
| Bulk transfer pallet `Unitload`s to `SHIPPED` location; `entityLock = SHIPPED` | 947+ |

### 4.4 Destination side — `AdviceService.acceptTransferAdvice()`

At `service/AdviceService.java:356`. `@Transactional("tenantTransactionManager")`.

Writes:
1. `Advice.state = FINISHED` (from `CREATED` or `OPEN`).
2. Bulk position update: `Adviceposition.state = FINISHED`.
3. Post-commit hook fires `WEBSERVICE_ACCEPT_TRANSFER` (line 406).

---

## 5. REST Endpoints

### 5.1 Source-side (web UI + mobile)

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `/v3/transfers/transferOrder/{customerOrderId}` | GET | `TransfersController` | Retrieve transfer-order detail |
| `/v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` | GET | same | Detail by batch ID |
| `/v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}` | GET | same | Change the assigned lane |
| `/v3/transfers/unlinkTransferLane/{customerOrderId}` | GET | same | Unlink the lane (clears transferlaneId) |
| `/v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}` | GET | same | Activate + assign lane in one call |
| `/v3/transfers/assignTransferLane/{customerOrderId}/{locationId}` | GET | same | Assign lane only |
| `/v3/transfers/runTransfer/{orderId}` | GET | same | **Execute pack** (calls `BillofladingService.transferOrder`) |
| `/v3/transfers/openTransfer` | GET | same | List open transfer orders (paginated) |
| `/v3/transfers/allOpenTransfer` | GET | same | All open transfers (no pagination) |
| `/v3/transfers/activeTransfer` | GET | same | Active transfers |
| `/v3/transfers/closedTransfer` | GET | same | Closed transfers |
| `/v3/transfers/inactiveTransfer` | GET | same | `ACTIVATED` state orders (OFFSITE + INTRACOMPANY types) |
| `/v3/transfers/skus` | GET | same | SKU overview for a batch |
| `/v3/transfers/unitLoads` | POST | same | Pallet/parcel detail |

### 5.2 BOL close (source side, after transport)

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `/v3/billOfLading/closeOutboundBol/{id}` | GET | `BillOfLadingController` | Normal close → puts transfer BOL in `TRANSFER` state |
| `/v3/billOfLading/closeIntraCompanyTransfer/{transferId}` | GET | `BillOfLadingController:291` | **Finish transfer** (calls `finishTransfer`) — TRANSFER → CLOSED |

### 5.3 Destination-side

| Endpoint | Method | Controller | Purpose |
|---|---|---|---|
| `/rest/advice/createTransfer` | PUT | `AdviceRestController` | OMS pushes TRANSFER-type advice |
| `/rest/advice/acceptTransfer` (or admin accept) | varies | same | Accept advice → fire `WEBSERVICE_ACCEPT_TRANSFER` |

---

## 6. OrderBatchType Semantics

From `service/WmsConstants.java:495–505`:

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
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `BillofladingService.closeBOL` (line 653) | Source — after BOL enters `TRANSFER` state |
| `WEBSERVICE_ACCEPT_TRANSFER` | `AdviceService.acceptTransferAdvice` (line 406) | Destination — when receiving advice is accepted |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `AdviceService.acceptHubAndSpokeAdvice` (line 251) | Destination — for HUB_AND_SPOKE type only (distinct flow) |

All post-commit via `omsNotificationService.sendAfterCommit(...)` or `TransactionSynchronizationManager.registerSynchronization`. See [wms2-end-to-end-request-journey.md §5](../architecture/wms2-end-to-end-request-journey.md).

---

## 8. Transaction Boundaries

- `activateTransferOrder`, `assignTransferLaneToTransferOrder`, `transferOrder`, `finishTransfer`, `acceptTransferAdvice` — each is one atomic `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`.
- **Pessimistic lock on BOL row** during `finishTransfer` via `findByIdForUpdate` — prevents concurrent `closeBOL` + `finishTransfer` on the same BOL.
- `TransfersController.activateTransferOrder` (line 159) calls both `activateTransferOrder()` and `assignTransferLaneToTransferOrder()` — two separate transactions. If activate succeeds but lane assign fails, the order sits in state 505 without a lane. Recover via `assignTransferLane` or `unlinkTransferLane` admin paths.
- Bulk JPQL in `finishTransfer` (position state, unitload relocation) — one SQL statement per entity type. See [wms2-bol-truck-loading-workflow §6.3](./wms2-bol-truck-loading-workflow.md).
- **Lane release on cancel (fix `260629-transfer-lane-leak-on-cancel`, 2026-06-29).** `CustomerorderService.cancelOrder` and `forceCancelOrder` now clear `transferlaneId` (guarded direct `setTransferlaneId(null)`) at the cancel transition, in addition to the existing `finalizeBatchIfComplete` release. Cancel paths use a **direct** clear, *not* `unlinkTransferLaneFromTransferOrder` (that helper resets state to `505` and would un-cancel). The lane-availability gate (`LocationRepository.getAvailableTransferLanes`) only excludes lanes held by orders with `state < FINISHED(700)`; since `CANCELED(800) ≥ 700`, the **real leak is abandonment** — a transfer order activated to 505/510 but never run *or* cancelled holds its lane forever. Operator recovery for a stuck order: `GET /v3/transfers/unlinkTransferLane/{customerOrderId}`. The activate→assign two-transaction split (above) that strands orders at 505-with-lane is tracked as follow-up `260629-activate-transfer-atomicity`.

---

## 9. Mobile Transfer Process

Mobile page `/mobile/transfer-order` — role gate is `WEB_UI_VIEW_TRANSFER_ORDER` (see [wms2-keycloak-role-matrix §3.8](../architecture/wms2-keycloak-role-matrix.md) — the known naming oversight).

- Backed by `MobileTransferOrderService`.
- `updateOrderList()` queries `customerorderRepository.findByState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED)` (state 510) — only activated-and-lane-assigned orders appear on the mobile.
- Operator workflow is read-heavy; the actual pick fires through standard picking endpoints once the transfer lane has been assigned.

---

## 10. Known Landmines

1. **Two transactions to activate.** Calling `/activateTransferOrder/{id}/{loc}` runs `activateTransferOrder` and `assignTransferLaneToTransferOrder` in sequence — not one transaction. Partial failure leaves the order in state 505 with no lane. Detect via state-505-but-null-transferlaneId query; recover via explicit assign.
2. **`closeBOL` does NOT terminate an intracompany transfer.** Source-side close leaves BOL in `TRANSFER`. Operators who expect the order "shipped" at this point are wrong — it's still in-flight. Only `finishTransfer` at the destination finalizes.
3. **`finishTransfer` requires BOL type `TRANSFER_INTRACOMPANY`.** Invoking it on a non-transfer BOL throws `BusinessException`. Don't copy the endpoint pattern for other BOL types.
4. **`BillofladingService.transferOrder` sets `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED`** even for non-club batches (line 749). This state name is misleading — it means "batch is packed and ready to ship," not "club run finished." Don't narrow the semantic on a refactor.
5. **`TRANSFER_OFFSITE` behaves differently from `TRANSFER_INTRACOMPANY`.** Offsite BOLs skip the `TRANSFER` state and close directly. If you generalize "transfer" logic, the `type` field branches are load-bearing.
6. **`WEBSERVICE_ACCEPT_TRANSFER` fires at destination, NOT at source.** Source-side `WEBSERVICE_ORDER_BATCH_SHIPPED` fires at `closeBOL`. OMS needs both to close the round-trip — if destination never accepts, the transfer sits in `TRANSFER` state indefinitely.
7. **Entity locks persist during in-flight phase.** `Unitload.entityLock = TRANSFER` + `Stockunit.entityLock = TRANSFER` prevent accidental re-use of the stock at source. Clearing these via SQL to "recover" a stuck transfer is the wrong fix — invoke `finishTransfer` with the correct `transferId`.
8. **No reopen for a finished transfer.** Once `Advice.state = FINISHED` at destination and BOL closes, there's no rollback path. A bad transfer needs a brand-new return / adjustment cycle.
9. **Mobile uses `WEB_UI_*` role.** The mobile transfer-order page is gated by `WEB_UI_VIEW_TRANSFER_ORDER`, not a `MOBILE_UI_*` role. A Keycloak realm that strictly separates web and mobile role sets will block mobile operators. Document this in tenant onboarding.
10. **`isEnoughStockOnTransferLane` validation is advisory.** It returns an error string the caller must check — it doesn't throw. A caller that ignores the return value will happily proceed with insufficient stock and produce an inconsistent pack.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| Transfer order stuck in state 505 without a lane | §10 item 1 — activate-then-assign split; recover via `/assignTransferLane` |
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

**Re-verify every 90 days.** Next due: **2026-07-18** — transfer flow is stable but any new `OrderBatchType` value invalidates §6.
