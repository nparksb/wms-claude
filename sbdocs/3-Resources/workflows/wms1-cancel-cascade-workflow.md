---
title: "WMS v1 — Cancel Cascade Workflow"
type: workflow
status: active
system: wms1
version: v1
scope: cancel-cascade
owner: Nam Park
created: 2026-04-27
updated: 2026-04-27
last_verified: 2026-04-27
verified_by: code read of v1/wms-api src/main — CustomerorderService, CustomerorderBatchService, CustomerorderPositionService, PickingorderBusinessService, OrderRestController, UtilRestController
related:
  - ./wms2-cancel-cascade-workflow.md
tags:
  - workflow
  - cancel
  - cascade
  - wms1
---

## TL;DR

- Describes every cancellation code path in `v1/wms-api`: OMS-initiated (`cancelOrder(order, false)` via `POST /rest/order/cancelPositions`) and WMS-initiated batch (`cancelBatch`), plus the deferred path (`cleanUpCancelledOrder`) and force path (`forceCancelOrder`).
- Cascade order: `PickingorderPosition → Pickingorder → CustomerorderPosition → Customerorder → CustomerorderBatch`; stock reservations are released via `changeReservedAmount` at the `PickingorderPosition` level.
- Terminal states block cancellation: `state >= FINISHED` (excluding `CANCELED`) or `entityLock == SHIPPED` on any parcel/stockunit throws `BusinessException`.
- `cancellationFromWithinWMS=true` is dead code in v1 — no caller passes it; the OMS callback block inside `cancelOrder` never fires. The only live OMS callback for order cancels is through `cancelBatch`.
- Deferred cancel: when an in-flight picking order prevents immediate cancellation, `markedforcancellation=true` is set; `cleanUpCancelledOrder` completes the job when the picking order finishes.
- `forceCancelOrder` is the escape hatch for PACKED/PALLETIZED orders; only reachable for CLUB-type batches via the OMS path in v1.
- Read this doc before touching any cancel endpoint, reservation-release logic, or any bug where orders get stuck in a non-terminal state after cancellation.

# WMS v1 — Cancel Cascade Workflow

**Scope:** Every code path that cancels a customer order in `v1/wms-api`, plus the entities it cascades through · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-27

---

## 1. Overview

Two things initiate cancellation in v1:

1. **OMS-initiated** — OMS calls `POST /rest/order/cancelPositions` to cancel one or more orders by external ID. Passes `cancellationFromWithinWMS=false`. No OMS callback fires from `cancelOrder` (the callback block is gated on `cancellationFromWithinWMS=true`, which is never passed by any caller in v1).
2. **WMS-initiated (batch)** — A WMS user or admin calls `CustomerorderBatchService.cancelBatch(...)`. This path has its own inline cascade and always fires the OMS callback unconditionally (no activation flag check at the batch level).

Key v1 difference from v2: **`cancellationFromWithinWMS=true` is never used in any v1 call site.** Every call to `cancelOrder` passes `false`. The OMS callback block inside `cancelOrder` (lines 664–723) is therefore dead code in v1. The only live OMS callback path for order-level cancels is through `cancelBatch`.

A second v1-specific wrinkle: when an in-flight picking order prevents normal cancellation, the order is **marked for deferred cancellation** (`markedforcancellation=true`) rather than immediately cancelled. Completion of the picking order then triggers `cleanUpCancelledOrder` to finish the job.

---

## 2. Cancellation Entry Points

| Entry point | File:Line | Scope | Trigger |
|---|---|---|---|
| `CustomerorderService.cancelOrder(order, false)` | `CustomerorderService.java:562` | Single order | OMS REST (`POST /rest/order/cancelPositions`) or internal utility |
| `CustomerorderService.forceCancelOrder(order)` | `CustomerorderService.java:284` | Single order (force path) | Delegated from `cancelOrder` when order is PACKED/PALLETIZED |
| `CustomerorderService.cleanUpCancelledOrder(order)` | `CustomerorderService.java:729` | Deferred single-order cancel | Called from `PickingorderBusinessService.finishPickingOrder` when `markedforcancellation=true` |
| `CustomerorderBatchService.cancelBatch(batch, principal)` | `CustomerorderBatchService.java:183` | Entire batch (all child orders) | Declared, no live controller caller in v1 yet — prepared infrastructure |
| `CustomerorderBatchService.finalizeBatchIfComplete(batchId)` | `CustomerorderBatchService.java:337` | Batch rollup | Consequence of `cancelOrder` completing; not a cancel trigger |
| `OrderRestController.cancelPositions(...)` | `OrderRestController.java:675` | HTTP entry — iterates orders, calls `cancelOrder(order, false)` per order | OMS POST `cancelPositions` |

---

## 3. Cancellation Guards

Guards are evaluated in order inside `cancelOrder` (lines 562–662). First failing guard short-circuits.

| Guard | Location | Effect |
|---|---|---|
| `state == CANCELED` | `CustomerorderService.java:567` | Idempotent return — no-op |
| `state >= FINISHED && state != CANCELED` OR parcel/stockunit entityLock == SHIPPED | `CustomerorderService.java:572` | Throws `BusinessException` — order already shipped or past QA |
| `state == PACKED \|\| state == PALLETIZED` AND `cancellationFromWithinWMS=false` AND NOT a CLUB-type batch | `CustomerorderService.java:576–584` | Throws `BusinessException` — requires force path |
| `state == PACKED \|\| state == PALLETIZED` AND (`cancellationFromWithinWMS=true` OR CLUB-type batch) | `CustomerorderService.java:577–581` | Delegates to `forceCancelOrder` → `finalizeBatchIfComplete`, returns |
| Any `CustomerorderPosition.state >= PACKED && < CANCELED` | `CustomerorderService.java:588` | Throws `BusinessException` — position past PACKED |
| `canOrderPositionBeCancelled` returns false for any position | `CustomerorderService.java:594–598` | Falls into deferred path (`markedforcancellation=true`) |

**`isOmsPreQaPackedCancellationAllowed`** (line 553): allows OMS to force-cancel a PACKED/PALLETIZED order only if the order belongs to a `CLUB`-type batch. Non-club packed orders can only be force-cancelled with `cancellationFromWithinWMS=true`, which no v1 caller currently uses.

---

## 4. `canOrderPositionBeCancelled` — Position-Level Gate

`CustomerorderPositionService.canOrderPositionBeCancelled` (`CustomerorderPositionService.java:43`) controls whether the normal cascade proceeds or falls into deferred-cancel. Returns `false` (blocking cancel) if:

**Regular picking path** (default):
- Any linked `Pickingorder.state >= RESERVED && < FINISHED` — picking order is active
- Any linked `PickingorderPosition.state >= RESERVED && < FINISHED` — individual pick position is active

**Rapid-pick path** (only when `section.sectionpickingtype == RAPID_PICKING` AND `order.state == ASSIGNED` AND `order.historytote != null`):
- Any `PickingorderPosition` with `pickingOrder.state < STARTED` is skipped (not yet active)
- Returns `false` if `pickingOrder.state == STARTED` AND `pickingPositionState > PROCESSABLE && < FINISHED` — operator mid-pick
- Returns `false` if `pickingOrder.state > STARTED && < FINISHED` — order between started and done

---

## 5. OMS-Initiated Cancel Cascade — `cancelOrder(order, false)`

Called by `OrderRestController.cancelPositions` iterating each order in the OMS request payload. One `cancelOrder` call per order; errors are collected and returned as partial failures (HTTP 400 with error map) rather than aborting the whole batch.

```
POST /rest/order/cancelPositions                         [OrderRestController.java:675]
  │
  └── for each order in request payload:
        customerorderService.cancelOrder(customerOrder, false)   [line 720]
          │
          ├── [Guard] isAlreadyCancelled? → return (idempotent)
          ├── [Guard] isShippedOrPastCancellationBoundary? → throw BusinessException
          ├── [Guard] isPackedOrPalletized?
          │     └── if CLUB-type batch → forceCancelOrder(order) + finalizeBatchIfComplete
          │         else → throw BusinessException (use force path)
          │
          ├── [Guard] any position.state >= PACKED && < CANCELED? → throw BusinessException
          │
          ├── canOrderPositionBeCancelled for each position?
          │     ├── ALL true → normal cascade (§5a)
          │     └── ANY false → deferred cancel (§5b)
          │
          └── [NO OMS callback — cancellationFromWithinWMS=false]
```

### 5a. Normal cascade (all positions cancellable)

```
cancelOrder — normal path                                [CustomerorderService.java:601]
  │
  ├── [RAPID-PICK side-door] if order.state==ASSIGNED && order.historytote!=null
  │     && section.type==RAPID_PICKING && pickingOrder.state==STARTED:
  │       Pickingorder.state = PROCESSABLE                        (line 612)
  │       for each PickingorderPosition of that picking order:
  │         PickingorderUnitload.state = CANCELED                 (line 618)
  │       if order.pickingtoteId != null:
  │         assert tote is empty, then sendToNirvana(tote)        (line 633)
  │         order.pickingtoteId = null
  │
  ├── for each CustomerorderPosition:
  │     customerorderPositionService.cancelOrderPosition(position) (line 642)
  │       │
  │       ├── [Guard] position.state >= PACKED → throw
  │       ├── [Guard] any PickingorderPosition in-flight → throw
  │       ├── for each PickingorderPosition with state < RESERVED:
  │       │     stockunitBusinessService.changeReservedAmount(
  │       │       pickFromStockUnit, amount.negate(), zeroIfNeg=true,
  │       │       CODE_CANCELLED_ORDER_FROM_WEBSERVICE)            [StockunitBusinessService.java:331]
  │       │     PickingorderPosition.pickfromstockunitId = null
  │       │     PickingorderPosition.state = CANCELED
  │       │     if all PickingorderPositions now >= FINISHED:
  │       │       Pickingorder.state = FINISHED
  │       └── CustomerorderPosition.state = CANCELED
  │
  ├── Customerorder.state = CANCELED                              (line 645)
  ├── all CustomerorderPositions.state = CANCELED (redundant save) (line 646)
  ├── customerorderRepository.save(customerOrder)                 (line 652)
  │
  └── customerorderBatchService.finalizeBatchIfComplete(batchId)  (line 653)
        if all sibling orders in batch >= FINISHED:
          if all == CANCELED → CustomerorderBatch.state = CANCELED
          else               → CustomerorderBatch.state = FINISHED
```

### 5b. Deferred cancel (picking order in flight)

When `canOrderPositionBeCancelled` returns `false` for any position and the order has already sent a picking confirmation (`pickingconfirmationsent=true`), `cleanUpCancelledOrder` is called immediately. Otherwise the order is flagged for deferred cancellation.

```
cancelOrder — deferred path                              [CustomerorderService.java:654]
  │
  ├── if order.pickingconfirmationsent == true:
  │     → cleanUpCancelledOrder(order)                   (see §7)
  └── else:
        order.markedforcancellation = true
        customerorderRepository.save(order)
        (cancel completes later when picking order finishes — §7)
```

---

## 6. WMS-Initiated Batch Cancel Cascade — `cancelBatch`

`CustomerorderBatchService.cancelBatch` (`CustomerorderBatchService.java:183`) is a single-transaction cascade over the entire batch. Unlike the OMS path, it does NOT call `cancelOrder` per child — it implements its own inline cascade. It always fires the OMS callback (no `cancellationFromWithinWMS` gate).

> **Note:** As of last verification, `cancelBatch` has no live controller caller in v1. It is declared and fully implemented but not yet wired to a REST or web-UI endpoint. Any WMS-user batch cancel currently goes through the Spring Data REST auto-exposure of the batch repository or a direct admin action — not this method.

```
CustomerorderBatchService.cancelBatch(batch, principal) [CustomerorderBatchService.java:183]
  │
  ├── [Guard] batch.state >= FINISHED → throw BusinessException
  ├── [Guard] any child order.state >= FINISHED && < CANCELED → throw BusinessException
  │
  ├── Build OMS cancel payload (exclude already-CANCELED orders)
  │
  ├── OmsNotificationHelper.deferToCommit(...)            (line 227)
  │     POST SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY
  │     after TX commit — fires regardless of cancellationFromWithinWMS
  │
  ├── for each active child Customerorder:
  │     for each CustomerorderPosition:
  │       for each PickingorderPosition:
  │         if poPosition.state < PICKED && pickfromstockunitId != null:
  │           stockunitBusinessService.changeReservedAmount(
  │             stockUnit, amount.negate(), zeroIfNeg=true,
  │             CODE_CANCELLED_ORDER_FROM_WEBSERVICE)       (line 272)
  │           poPosition.pickfromstockunitId = null
  │         PickingorderPosition.state = CANCELED           (line 276)
  │         if all PickingorderPositions of that Pickingorder >= FINISHED:
  │           if all == CANCELED → Pickingorder.state = CANCELED  (line 285)
  │           else               → Pickingorder.state = FINISHED  (line 287)
  │       CustomerorderPosition.state = CANCELED            (line 292)
  │     if order.pickingtoteId != null:
  │       tote.entityLock = NOT_LOCKED
  │       order.historytote = tote.labelId
  │       order.pickingtoteId = null
  │     if order.parcelId != null:
  │       parcel.entityLock = NOT_LOCKED
  │       parcel stockunits.entityLock = NOT_LOCKED
  │     Customerorder.state = CANCELED                      (line 321)
  │
  ├── CustomerorderBatch.state = CANCELED                   (line 326)
  └── CustomerorderBatch.staginglaneId = null
```

---

## 7. Deferred Cancel — `cleanUpCancelledOrder`

Called in two situations:
1. From `PickingorderBusinessService.finishPickingOrder` (line 137) when it notices `order.markedforcancellation=true` while finishing a pick.
2. From `cancelOrder` directly (line 657) when `pickingconfirmationsent=true` and `canOrderPositionBeCancelled` is false.

```
CustomerorderService.cleanUpCancelledOrder(order)        [CustomerorderService.java:729]
  │
  ├── if order.pickingtoteId != null:
  │     unitloadBusinessService.sendToClearing(tote, CODE_TRANSFER)
  │     tote's stockunits.entityLock = NOT_LOCKED
  │     order.historytote = tote.labelId
  │     order.pickingtoteId = null
  │
  ├── Customerorder.state = CANCELED                       (line 749)
  ├── all CustomerorderPositions.state = CANCELED
  │
  ├── if all sibling orders in batch >= FINISHED:
  │     CustomerorderBatch.state = FINISHED  ← NOTE: sets FINISHED, not CANCELED
  │
  └── if tote != null:
        PickingorderUnitload matching tote.labelId:
          pickingUnitLoad.historytote = tote.labelId
          pickingUnitLoad.unitloadId = null
          pickingUnitLoad.state = CANCELED
```

**Note:** `cleanUpCancelledOrder` sets the batch to `FINISHED` (not `CANCELED`) if all orders are complete. This diverges from `finalizeBatchIfComplete`, which correctly distinguishes all-CANCELED vs mixed. This is a v1 quirk — a batch finalized via `cleanUpCancelledOrder` may read as FINISHED even if all child orders were cancelled.

---

## 8. `forceCancelOrder` — PACKED/PALLETIZED Escape Hatch

`CustomerorderService.forceCancelOrder` (`CustomerorderService.java:284`) handles two sub-cases based on current order state.

**Sub-case A: order.state < PACKED** (order was pre-pack when force-cancel called):

```
forceCancelOrder — pre-PACKED                           [CustomerorderService.java:287]
  │
  ├── for each CustomerorderPosition → PickingorderPosition:
  │     if coPosition.state < PICKED && poPosition.state < PICKED:
  │       stockunitBusinessService.changeReservedAmount(
  │         pickFromStockUnit, amount.negate(), zeroIfNeg=true,
  │         CODE_CANCELLED_ORDER_FROM_WEBSERVICE)           (line 298)
  │       poPosition.pickfromstockunitId = null
  │     PickingorderPosition.state = CANCELED
  │   CustomerorderPosition.state = CANCELED
  │
  ├── Customerorder.state = CANCELED
  │
  ├── if all PickingorderPositions of the picking order >= FINISHED:
  │     Pickingorder.state = PICKED
  │     pickingorderBusinessService.finishPickingOrder(pickingOrder)  (line 319)
  │
  └── if order.pickingtoteId != null:
        if tote.entityLock != GOING_TO_DELETE:
          tote.entityLock = NOT_LOCKED
          tote's stockunits.entityLock = NOT_LOCKED
          unitloadBusinessService.sendToClearing(tote, CODE_TRANSFER)
        order.historytote = tote.labelId
        order.pickingtoteId = null
```

**Sub-case B: order.state == PACKED or PALLETIZED** (order already packed):

```
forceCancelOrder — PACKED/PALLETIZED                    [CustomerorderService.java:343]
  │
  ├── all CustomerorderPositions.state = CANCELED
  ├── Customerorder.state = CANCELED
  ├── parcel.entityLock = NOT_LOCKED
  ├── parcel's stockunits.entityLock = NOT_LOCKED
  └── unitloadBusinessService.sendToClearing(parcel, CODE_TRANSFER)
      (TODO comment: BOL position for parcel not yet handled)
```

**Key v1 difference from v2:** In v1, `forceCancelOrder` sub-case A sets `Pickingorder.state = PICKED` (not CANCELED) when all positions are done — identical to v2. Sub-case B does not touch Pickingorder state at all (parcel is the relevant entity by PACKED stage).

---

## 9. Stock Reservation Release

Stock reservations (`Stockunit.reservedamount`) are released in three places:

| Where | Condition | Method |
|---|---|---|
| `CustomerorderPositionService.cancelOrderPosition` (line 136) | `PickingorderPosition.state < RESERVED` | `changeReservedAmount(stockUnit, amount.negate(), zeroIfNeg=true, CODE_CANCELLED_ORDER_FROM_WEBSERVICE)` |
| `CustomerorderService.forceCancelOrder` (line 298) | `coPosition.state < PICKED && poPosition.state < PICKED` | Same call |
| `CustomerorderBatchService.cancelBatch` (line 272) | `poPosition.state < PICKED && pickfromstockunitId != null` | Same call |

`zeroIfNeg=true` means if the computed new `reservedamount` would go negative (e.g. due to concurrent changes), it is floored to zero rather than going negative. Activity code `CODE_CANCELLED_ORDER_FROM_WEBSERVICE` is used in all cancel paths.

Reservations are **not** released in the deferred cancel path (`cleanUpCancelledOrder`) — by the time `cleanUpCancelledOrder` fires, the picking order has finished, meaning picks were already consumed and reservations were already decremented by the pick completion flow.

---

## 10. OMS Callback Behavior

### `cancelOrder` (OMS-initiated, `cancellationFromWithinWMS=false`)

No OMS callback fires. The callback block at `CustomerorderService.java:664–723` is gated on `cancellationFromWithinWMS=true`, which no v1 caller ever passes. The inbound cancel from OMS is logged in the `message` table by `OrderRestController` (line 735–743) with type `ORDER_BATCH_CANCELLED_FROM_PSD`.

### `cancelBatch` (WMS-initiated)

Always fires one outbound callback per batch cancel, deferred to post-commit:

| Property | Value |
|---|---|
| URL sysprop key | `WEBSERVICE_ORDER_BATCH_CANCELLED` (`WmsConstants.java:885`) |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/cancelPosition` |
| Activation flag | `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` — **but not checked in `cancelBatch`** (unlike v2, no activation gate in the batch path) |
| Message type | `ORDER_BATCH_CANCELLED_FROM_WMS` |
| Timing | `OmsNotificationHelper.deferToCommit(...)` — fires after TX commit, never on rollback |
| Payload | `OrderBatchDto` with `facilityCode`, `batchId`, and list of active (non-already-cancelled) orders with their positions and SKU IDs |

If the HTTP POST fails (IOException), a `Message` record is created with `status=FAILED` and `code=503`. The WMS transaction is already committed at that point — the callback failure does not roll back the cancel.

---

## 11. Entities Affected and Final States

| Entity | Normal cancel | Force cancel (pre-PACKED) | Force cancel (PACKED) | Batch cancel | Deferred cancel |
|---|---|---|---|---|---|
| `Customerorder` | CANCELED | CANCELED | CANCELED | CANCELED | CANCELED |
| `CustomerorderPosition` | CANCELED | CANCELED | CANCELED | CANCELED | CANCELED |
| `PickingorderPosition` | CANCELED (if state < RESERVED) | CANCELED | not touched | CANCELED | not touched (already picked) |
| `Pickingorder` | FINISHED (if all positions done) | PICKED then finishPickingOrder | not touched | CANCELED (if all positions CANCELED) or FINISHED | not directly set |
| `PickingorderUnitload` | CANCELED (rapid-pick side-door only) | not touched | not touched | not touched | CANCELED (if tote exists) |
| `Stockunit.reservedamount` | decremented (if position < RESERVED) | decremented (if position < PICKED) | not touched | decremented (if position < PICKED) | not touched |
| `Unitload` (tote) | sendToNirvana (rapid-pick) | sendToClearing | not touched | entityLock = NOT_LOCKED | sendToClearing |
| `Unitload` (parcel) | not touched | not touched | sendToClearing + NOT_LOCKED | entityLock = NOT_LOCKED | not touched |
| `CustomerorderBatch` | via finalizeBatchIfComplete | via finalizeBatchIfComplete | via finalizeBatchIfComplete | CANCELED directly | FINISHED (all orders done) |

---

## 12. Known Failure Modes

1. **Stuck in `markedforcancellation=true`**: If a picking order never finishes (operator abandons a tote, device dies), the order stays flagged but never reaches `cleanUpCancelledOrder`. The order appears live in OMS but CANCEL-flagged in WMS. Resolution: admin must manually finish or forcibly cancel the picking order.

2. **Partial cancel from `cancelPositions`**: `OrderRestController.cancelPositions` collects per-order errors and returns HTTP 400 with an error map rather than rolling back successful cancels. A batch of 10 orders where 3 fail leaves 7 cancelled and 3 unchanged. OMS must reconcile from the error map response — WMS does not retry failed orders automatically.

3. **`cleanUpCancelledOrder` sets batch to FINISHED, not CANCELED**: When the deferred path finalises a batch where every order was cancelled, `cleanUpCancelledOrder` calls `orderBatch.setState(FINISHED)` rather than `CANCELED`. Queries filtering for `batch.state==CANCELED` will miss these batches.

4. **OMS never receives cancel notification for OMS-initiated cancels**: Because `cancellationFromWithinWMS=false` for all OMS-REST callers, the `cancelOrder` OMS callback block never fires. OMS initiated the cancel so it owns the state change — the WMS assumes OMS already knows. If OMS relies on a WMS echo for state sync, it won't receive one via this path.

5. **`cancelBatch` has no live endpoint in v1**: The method exists and is fully implemented but no controller calls it. WMS-user-initiated batch cancellation is not available via a dedicated API endpoint in v1.

6. **`forceCancelOrder` PACKED sub-case has an open TODO**: BOL position cleanup for the parcel is not implemented (`CustomerorderService.java:365` TODO comment). Force-cancelling a PACKED order may leave orphaned BOL position references.

7. **CLUB-batch PACKED orders can be OMS-force-cancelled**: `isOmsPreQaPackedCancellationAllowed` returns true for CLUB-type batches with PACKED orders, allowing OMS to trigger `forceCancelOrder` via a normal `cancelPositions` call. For non-CLUB batches, packed orders are blocked to OMS.

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-27 | All cancel entry points (cancelOrder / forceCancelOrder / cleanUpCancelledOrder / cancelBatch / finalizeBatchIfComplete); `cancellationFromWithinWMS` call sites (all pass `false`); OMS callback sysprop keys; `changeReservedAmount` call sites in cancel paths; `canOrderPositionBeCancelled` guard logic; `cancelBatch` caller scan (none found); `cleanUpCancelledOrder` batch-state quirk | All file:line refs confirmed against `v1/wms-api/src/main/java` | Code read — CustomerorderService (781 lines), CustomerorderBatchService (1247 lines), CustomerorderPositionService, PickingorderBusinessService, OrderRestController, UtilRestController |

**Re-verify every 60 days.** Next due: **2026-06-26** — any change to `CustomerorderService`, `CustomerorderBatchService`, or `CustomerorderPositionService` should trigger a re-sweep.
