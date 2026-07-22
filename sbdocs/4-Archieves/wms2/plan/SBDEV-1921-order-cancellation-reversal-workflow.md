---
id: SBDEV-1921-order-cancellation-reversal-workflow
title: "Order Cancellation & Reversal Workflow"
ticket: "SBDEV-1921"
ticket_url: ""
type: feature
priority: high
status: archived
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-05-23
updated: "2026-07-15"
author: Claude Sonnet 4.6
db_verified: true
related:
  - "[[SBDEV-1921-oms-batch-reversal-completed-endpoint]]"
  - sbdocs/3-Resources/architecture/wms2-oms-integration-map.md
  - sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
  - sbdocs/4-Archieves/wms2/plan/260424-phase7-cancel-orchestrator-plan.md
tags: [cancellation, reversal, picking, mobile-ui, oms-integration, plan]
---

# Order Cancellation & Reversal Workflow

> **Review status:** Revised after Architect + Critic review (2026-05-28). Round 14: 13 required changes applied — Flyway collision fixed (V2.1.12), inner guard gap fixed (Change C), DDL TIMESTAMPTZ, source-location field corrected, outbox-guard placement corrected, deferred-path test added.
> **Implementation status (merged to develop — 2026-05-28):** All 4 phases implemented, code-reviewed, and merged. wms2-api develop: `bf14f6d` (24 files, +1728/-36). wms2-mobile-ui develop: `c7f50bb` (7 files, +405). 164 tests, 0 failures. Pending: OMS team must implement `POST /services/call/batchReversalCompleted`; update `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` sysprop URL per environment.

**Project:** wms2 | **Version:** v2 | **Type:** feature + bug-fix
**Priority:** high
**Status:** archived 2026-07-15 — WMS implementation complete and **merged directly to `develop` (no PR)**: wms2-api `bf14f6d` (merge of `tasks/SBDEV-1921`, verified on `origin/develop`) + `27c2cc7`; wms2-mobile-ui `c7f50bb`/`1cbfadd` (verified on `origin/develop`). The remaining OMS-endpoint closure dependency (Q2/F1) is **not** part of this WMS plan and continues to be tracked by the still-active paired stub [[SBDEV-1921-oms-batch-reversal-completed-endpoint]] (+ per-env `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` sysprop URL). Archived because the WMS work this plan owns is implemented and on `develop`; the ticket is closed out once the OMS stub ships.
**Date:** 2026-05-23

---

## §0. Affected Sites

| # | File:line | Construct | In-scope? | Phase |
|---|-----------|-----------|-----------|-------|
| 1 | `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/OrderRestController.java:534-630` | `/cancelPositions` POST — OMS entry | Yes | Phase 2 |
| 2 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java:600-750` | `cancelOrder()` orchestrator | Yes | Phase 2 |
| 3 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java:336-425` | `forceCancelOrder()` CLUB/PACKED force path | Yes | Phase 2 |
| 4 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java:53-109` | `canOrderPositionBeCancelled()` guard | Yes | Phase 2 |
| 5 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java:111-148` | `cancelOrderPosition()` | Yes | Phase 2 |
| 6 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java:395-436` | `cleanUpCancelledOrder()` | Yes | Phase 2 |
| 7 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java:143-284` | `finishPickingOrder()` | Yes | Phase 2 |
| 8 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java:255-386` | `cancelBatch()` | Yes (audit) | Phase 2 |
| 9 | `v2/wms2-api/src/main/java/net/aim_ai/wms/util/WmsConstants.java:440-457` | `MessageProcessType` — add `ORDER_BATCH_REVERSAL_COMPLETED` only | Yes | Phase 3 |
| 10 | `v2/wms2-api/src/main/java/net/aim_ai/wms/entity/AbstractBaseEntity.java:34-35` | `@Version` optimistic lock | Yes (review) | Phase 2 |
| 11 | `v2/wms2-api/src/main/java/net/aim_ai/wms/repository/PickingorderRepository.java:24-27` | `findByIdForUpdate` 1s timeout | Yes (review) | Phase 2 |
| 12 | `v2/wms2-api/src/main/java/net/aim_ai/wms/entity/Customerorder.java:39` | `markedforcancellation` flag | Yes (extend) | Phase 2 |
| 13 | `v2/wms2-api/src/main/java/net/aim_ai/wms/entity/CustomerorderCancellationLog.java` (NEW) | New entity for reversal tracking | Yes | Phase 1 |
| 14 | `v2/wms2-api/src/main/resources/db/migration/V2.1.12__add_cancellation_reversal_log_and_grant.sql` (NEW) | Flyway migration — creates the `customerorder_cancellation_log` table (operator columns declared directly as `VARCHAR(255)`) + 2 indexes, then idempotently grants `MOBILE_UI_VIEW_CANCELLATION` to roles. Consolidated from earlier per-step migrations (table + operator-id `VARCHAR` ALTER + role grant) into this single file. V1.1.17 is taken by `v1-onboarding/V1.1.17__oms_endpoint_sysprops_v1client.sql`; V1.1.18 reserved for v1-onboarding use | Yes | Phase 1 |
| 15 | `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/OrderCancellationController.java` (NEW) | Mobile reversal endpoints | Yes | Phase 3 |
| 16 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CancellationReversalService.java` (NEW) | Stock-return orchestration | Yes | Phase 3 |
| 17 | `v2/wms2-mobile-ui/store/home.js:22-93` | Mobile menu registry | Yes | Phase 4 |
| 18 | `v2/wms2-mobile-ui/pages/cancellation.vue` (NEW) | New page | Yes | Phase 4 |
| 19 | `v2/wms2-mobile-ui/components/cancellation/*.vue` (NEW) | Step components | Yes | Phase 4 |
| 20 | `v2/wms2-mobile-ui/store/cancellation.js` (NEW) | Vuex module | Yes | Phase 4 |

---

## §1. Problem Statement

OMS can push a cancellation request to WMS today, but the current code path has several functional gaps and at least one intermittent defect:

1. **Over-restrictive guard.** `CustomerorderService.cancelOrder()` and `CustomerorderPositionService.canOrderPositionBeCancelled()` reject cancellation for any picking position whose state is in `[RESERVED, FINISHED)` — i.e. `STARTED (500)` and `PICKED (600)` orders cannot be cancelled. Business has confirmed cancellation should be permitted whenever the order is **strictly below PACKED (650)**. The OMS UI displays the order as "cancel pending" and the WMS never resolves it.
2. **No stock-to-source reversal.** When cancellation does succeed for an order that already reached `PICKED`, the picked stock has already been physically placed in a tote. The current code nulls `pickfromstockunit_id` on the position, then sends the tote to "clearing". The source location is permanently lost. There is no audit trail, no operator workflow, and no way to put the stock back in its proper bin.
3. **Intermittent header bug.** `cancelOrderPosition()` promotes the parent `Pickingorder` header to `FINISHED` only when `allMatch(state >= FINISHED)`. The `CANCELED (800)` state passes that test numerically (`800 >= 700`), so when **all** positions are `CANCELED`, the predicate fires and the header IS promoted — but to `FINISHED (700)` instead of `CANCELED (800)`. This leaves the picking order in `FINISHED` state with `lockedtooperator=true` and `operator_id` still set — the picker's session is leaked. For shared picking orders where one CO is cancelled and another is still `STARTED`, the predicate is not satisfied and the header correctly stays at `STARTED` until the surviving CO completes. Pickers cannot complete the surviving CO; mobile UI shows the order "stuck".
4. **No OMS confirmation outbox.** `cancelOrder()` wraps the outbox enqueue in `if (cancellationFromWithinWMS)`, so when the cancellation originates from OMS the notification block is skipped entirely. OMS has no confirmation that WMS processed the request. Reconciliation is manual.
5. **No mobile reversal workflow.** Warehouse operators have no UI to view pending reversals, scan the tote, see source-location instructions, or confirm that stock was physically returned.

### Symptoms reported by operations

- Operators occasionally see picking orders in `STARTED` state with no remaining positions to pick (cancelled-CO ghost headers).
- OMS dashboards show "cancel pending" indefinitely on orders the warehouse has already moved on from.
- Cancelled-but-already-picked stock accumulates in clearing totes without paper trail; manual reconciliation each month.

---

## §2. Current Architecture

### 2.1 `/cancelPositions` controller flow

| Layer | File:line | Behavior |
|---|---|---|
| Controller | `OrderRestController.java:534-630` | Accepts OMS POST `{customerorderId, positionIds[]}`. Maps to `cancelOrder(co, cancellationFromWithinWMS=false)`. Returns `200 OK` on success, `400` on `BusinessException`. |
| Service | `CustomerorderService.cancelOrder():600-750` | Orchestrates state-guard tree below. |
| Service | `CustomerorderService.forceCancelOrder():336-425` | Used by CLUB/PACKED override path (internal). |
| Service | `CustomerorderPositionService.canOrderPositionBeCancelled():53-109` | Per-position predicate. Currently rejects when *any* sibling position has state ∈ `[RESERVED, FINISHED)` or the parent Pickingorder is in `[RESERVED, FINISHED)`. |
| Service | `CustomerorderPositionService.cancelOrderPosition():111-148` | Releases reservation, nulls `pickfromstockunit_id`, sets position state to `CANCELED (800)`, promotes Pickingorder header. |
| Service | `PickingorderBusinessService.cleanUpCancelledOrder():395-436` | Deferred path when `pickingconfirmationsent=true` — sends tote to clearing, finalises batch. |

### 2.2 State guard tree (ASCII)

```
/cancelPositions (OMS)
    │
    ▼
cancelOrder(co, cancellationFromWithinWMS=false)
    │
    ├── [state == CANCELED] → idempotent return ✓
    ├── [state >= SHIPPED] → BusinessException ✗
    ├── [state >= PACKED(650)] → BusinessException ✗ ← CURRENT HARD BLOCK
    ├── [any position state >= PACKED] → BusinessException ✗
    │
    ├── [can cancel all positions] →
    │       cancelOrderPosition() × N
    │           ├── release reservation (changeReservedAmount)
    │           ├── null pickfromstockunit_id  ← source location LOST here
    │           ├── set position.state = CANCELED
    │           └── promote Pickingorder header: allMatch(≥ FINISHED) → FINISHED
    │                   ← BUG: never set to CANCELED; shared-order header stays at STARTED
    │
    ├── [pickingconfirmationsent=true, can't cancel] →
    │       cleanUpCancelledOrder()
    │           ├── send tote to clearing ← NO stock-to-source rollback
    │           ├── set CO + positions → CANCELED
    │           └── finalize batch
    │
    └── else → markedforcancellation=true
```

### 2.3 State constants

| State | Value | Meaning |
|---|---|---|
| RESERVED | 400 | Stock allocated, not yet picked |
| STARTED | 500 | Picking in progress |
| PICKED | 600 | Picked into tote |
| PACKED | 650 | Packed for shipment ← cancel cut-off |
| PALLETIZED | 670 | On pallet |
| LOADED_TO_TRUCK | 680 | Loaded |
| FINISHED | 700 | Picking complete (no shipment yet) |
| CANCELED | 800 | Terminal cancel |

### 2.4 Affected DB tables (current)

| Table | Relevant columns |
|---|---|
| `customerorder` | `id`, `state`, `markedforcancellation`, `version` |
| `customerorder_position` | `id`, `customerorder_id`, `pickingorder_position_id`, `state`, `version` |
| `pickingorder` | `id`, `state`, `lockedtooperator`, `operator_id`, `pickinginprogress`, `pickingconfirmationsent`, `version` |
| `pickingorder_position` | `id`, `pickingorder_id`, `pickfromstockunit_id`, `state`, `version` |
| `stockunit` | `id`, `stocklocation_id`, `amount`, `reservedamount` |

### 2.5 Mobile UI structure (current)

`v2/wms2-mobile-ui/store/home.js:22-93` — two menu pages:

- **PAGE ONE** (items 1–6): Picking, Putaway, Tote Operations, Move Stock, Move Pallet, Palletize
- **PAGE TWO** (items 7–11): Truck Loading, Cycle Count, Replenish Process, Replenish Request, Transfer Process

There is no "Cancellation Process" entry. Each menu item gates on a Keycloak role and a single page route. Page navigation follows the `selectOrder.vue:11,36-40` pattern: `refreshMenus()` then `router.push('/')`.

---

## §3. Design

### 3.1 Guard relaxation

**Goal:** Allow cancellation when CO state and every relevant position state is strictly below `PACKED (650)`.

**Files changed:** `CustomerorderPositionService.java` — both `canOrderPositionBeCancelled()` (outer guard) and `cancelOrderPosition()` (inner work body).

#### Change A — outer guard (`canOrderPositionBeCancelled()`, lines 53–109)

Change the blocking range for sibling positions from `[RESERVED, FINISHED)` to `[PACKED, FINISHED)`:

| Position state | Before | After |
|---|---|---|
| RESERVED (400) | block | allow |
| STARTED (500) | block | allow |
| PICKED (600) | block | allow |
| PACKED (650) | block | block |
| PALLETIZED (670) | block | block |
| FINISHED (700) | allow | allow |
| CANCELED (800) | allow | allow |

#### Change B — inner work body (`cancelOrderPosition()`, line 130)

The existing code at line 130 is:
```java
if (pickingPosition.getState() < WmsConstants.State.RESERVED) {
    // release reservation, null pickfromstockunit_id, set position state …
}
```

This gate must be widened to include the newly-allowed states. Replace with:
```java
if (pickingPosition.getState() < WmsConstants.State.PACKED) {
    // Phase 1 change: allow RESERVED (400), STARTED (500), PICKED (600) in addition to PROCESSABLE states
    // Note: for PICKED (600), reservation amount may be zero (stock already physically moved to tote);
    // changeReservedAmount handles amount=0 as a no-op via the existing zeroIfNegative guard.
    // ... release reservation, null pickfromstockunit_id, set position state CANCELED …
}
```

The order-level guard in `cancelOrder()` remains `state >= PACKED → BusinessException`. The `cleanUpCancelledOrder()` deferred path stays intact for `pickingconfirmationsent=true` scenarios.

#### Change C — inner pre-check guards (`cancelOrderPosition()`, lines 121–126) `[Review fix — CRITICAL]`

`canOrderPositionBeCancelled()` (Change A) is the outer guard. But `cancelOrderPosition()` has its own inner pre-check at lines 121–126 that throws `BusinessException` before the inner-body gate of Change B is ever reached. **Without this fix, Change A and Change B are silently negated** — the outer guard allows the call through, then the inner guards abort it.

Current code at lines 121–126:
```java
if (pickingOrder.getState() >= WmsConstants.State.RESERVED && pickingOrder.getState() < WmsConstants.State.FINISHED) {
    throw new BusinessException("order has references to not finished picking positions part of started picking order.");
}
if (pickingPosition.getState() >= WmsConstants.State.RESERVED && pickingPosition.getState() < WmsConstants.State.FINISHED) {
    throw new BusinessException("order has references to not finished but started picking positions. cancel them first.");
}
```

Replace with (matching Change A's `PACKED` cutoff):
```java
if (pickingOrder.getState() >= WmsConstants.State.PACKED && pickingOrder.getState() < WmsConstants.State.FINISHED) {
    throw new BusinessException("cancel not permitted — picking order is already packed.");
}
if (pickingPosition.getState() >= WmsConstants.State.PACKED && pickingPosition.getState() < WmsConstants.State.FINISHED) {
    throw new BusinessException("cancel not permitted — picking position is already packed.");
}
```

Add to §5.2 tests: `cancelOrderPosition_state500_doesNotThrow()` and `cancelOrderPosition_state600_doesNotThrow()` — drive `cancelOrderPosition()` directly (not via `cancelOrder()`) with `pickingOrder.state=STARTED (500)` and `pickingPosition.state=PICKED (600)` and assert no exception is thrown. These directly verify that Change C does not regress when Change B is applied.

**STARTED-state reservation note:** For positions cancelled at `PICKED (600)`, the source stockunit's `reservedamount` is already 0 (consumed during the pick). Calling `changeReservedAmount(-amount)` hits the existing `zeroIfNegative` guard in `StockunitBusinessService` — safe no-op. For `STARTED (500)` positions, reservation is still held at the source and the release is correct. A future refactor (Phase 5) may split the inner body by state to make this explicit.

### 3.2 Pickingorder header bug fix

In `cancelOrderPosition()`, after setting position state to `CANCELED`, change the promotion predicate so the parent picking-order header is correctly promoted to either `FINISHED` (mixed terminal) or `CANCELED` (all-cancelled):

```java
// BEFORE (buggy):
if (poPositions.stream().allMatch(p -> p.getState() >= WmsConstants.State.FINISHED)) {
    pickingOrder.setState(WmsConstants.State.FINISHED);
}

// AFTER (fixed):
boolean allTerminal = poPositions.stream().allMatch(p ->
    p.getState() >= WmsConstants.State.FINISHED
    || p.getState() == WmsConstants.State.CANCELED);
if (allTerminal) {
    boolean allCanceled = poPositions.stream()
        .allMatch(p -> p.getState() == WmsConstants.State.CANCELED);
    pickingOrder.setState(allCanceled
        ? WmsConstants.State.CANCELED
        : WmsConstants.State.FINISHED);
    pickingOrder.setLockedtooperator(false);
    pickingOrder.setOperatorId(null);
    pickingOrder.setPickinginprogress(false);
}
```

This also resolves the secondary observation that `operator_id` is not cleared on the OMS-initiated cancel path, so a cancelled CO no longer holds the picker's session.

### 3.3 Reversal log schema

New table `customerorder_cancellation_log`. Flyway file `V2.1.12__add_cancellation_reversal_log_and_grant.sql` — this single migration creates the table (with the `reversal_initiated_by` / `reversal_completed_by` operator columns declared directly as `VARCHAR(255)`) plus its 2 indexes, then idempotently grants `MOBILE_UI_VIEW_CANCELLATION` to roles. It is consolidated from earlier per-step migrations — the standalone table migration and the operator-id `VARCHAR(255)` ALTER — into one file together with the role grant. (V1.1.17 taken by `v1-onboarding/V1.1.17__oms_endpoint_sysprops_v1client.sql`; V1.1.18 reserved for v1-onboarding):

```sql
CREATE TABLE customerorder_cancellation_log (
    id BIGSERIAL PRIMARY KEY,
    version INTEGER NOT NULL DEFAULT 0,
    tenant_name VARCHAR(50) NOT NULL,
    facility_code VARCHAR(10) NOT NULL,
    customerorder_id BIGINT NOT NULL REFERENCES customerorder(id),
    customerorder_position_id BIGINT NOT NULL REFERENCES customerorder_position(id),
    pickingorder_id BIGINT,
    -- Snapshot at time of cancellation
    order_state_at_cancel INTEGER NOT NULL,
    position_state_at_cancel INTEGER NOT NULL,
    pickfromstockunit_id BIGINT,   -- preserved BEFORE nulling
    pickfromlocationname VARCHAR(255),  -- denormalized from PickingorderPosition.pickfromlocationname (no FK — avoids multi-hop derive at cancel time; used as locationName arg to StockunitService.transferStock)
    picktounitload_id BIGINT,      -- tote unitload at time of cancel
    picktostockunit_id BIGINT,     -- specific stockunit on the tote for this SKU (avoids .get(0) on mixed totes)
    amount_picked NUMERIC(17,4),
    tote_label_id VARCHAR(255),    -- historytote snapshot
    -- Reversal tracking
    reversal_required BOOLEAN NOT NULL DEFAULT true,
    reversal_initiated_at TIMESTAMP WITH TIME ZONE,
    reversal_initiated_by BIGINT,  -- operator user_id
    reversal_completed_at TIMESTAMP WITH TIME ZONE,
    reversal_completed_by BIGINT,
    reversal_notes TEXT,
    -- Audit (TIMESTAMP WITH TIME ZONE: compatible with active UTC migration V1.2.x)
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    created_by VARCHAR(255)
);

CREATE INDEX idx_cancel_log_order
    ON customerorder_cancellation_log(customerorder_id);

CREATE INDEX idx_cancel_log_reversal_pending
    ON customerorder_cancellation_log(tenant_name, facility_code, reversal_required, reversal_completed_at)
    WHERE reversal_required = true AND reversal_completed_at IS NULL;
```

JPA entity `CustomerorderCancellationLog` mirrors the columns one-to-one; uses `@Version` on the `version` column to preserve optimistic locking semantics consistent with `AbstractBaseEntity`.

### 3.4 Reversal log population

In `CustomerorderPositionService.cancelOrderPosition()`, **before** nulling `pickfromstockunit_id`, call:

```java
cancellationLogService.recordCancellation(position, pickingOrder, stockUnit, sourceLocationId);
```

Capture, in order:

1. `pickfromstockunit_id` (from the position, before reset)
2. `pickingPosition.getPickfromlocationname()` — the denormalized source location name directly on `PickingorderPosition` (field `pickfromlocationname`; eagerly loaded, no additional query needed). `PickingorderPosition` has no `stocklocation_id` field; `pickfromlocationname` is the codebase's established pattern for the source location. Stored as `pickfromlocationname VARCHAR(255)` in the log table.
3. `amount_picked` (from the position's allocated/picked amount)
4. `tote_label_id` (from historytote if PICKED, else null)
5. `order_state_at_cancel` and `position_state_at_cancel` (current entity states)
6. `picktounitload_id` (from `pickingPosition.picktounitloadId`; populated when `position_state_at_cancel >= PICKED (600)`, else `null`)
7. `picktostockunit_id` — the specific stockunit deposited on the tote for this position's SKU. Captured as:
   ```java
   stockunitRepository.findByUnitloadId(pickingPosition.getPicktounitloadId())
       .stream()
       .filter(su -> su.getItemdataId().equals(pickingPosition.getItemdataId()))
       .findFirst()
       .orElse(null)
   ```
   Populated when `position_state_at_cancel >= PICKED (600)`, else `null`. This direct handle avoids `.get(0)` ambiguity when the tote carries multiple SKUs from different orders.

Set `reversal_required = true` **iff** `position_state_at_cancel >= PICKED (600)`. For positions cancelled at `RESERVED` or `STARTED`, no physical stock movement happened — the reservation release on the stockunit is sufficient.

The deferred path `PickingorderBusinessService.cleanUpCancelledOrder()` also creates log entries (with `reversal_required = true` since by definition `pickingconfirmationsent=true` implies stock has reached PICKED).

### 3.5 OMS outbox notification

#### 3.5.1 Cancellation completion (Phase 1)

**Fix:** Remove the `if (cancellationFromWithinWMS)` guard in `CustomerorderService.cancelOrder()` so the existing outbox enqueue fires on **both** WMS-initiated and OMS-initiated cancellations.

No new `MessageProcessType` constant is needed. The existing `ORDER_BATCH_CANCELLED_FROM_WMS` type is reused, delivered to the same `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` destination (`/services/call/cancelPosition` on OMS). The payload construction is identical to the current WMS-initiated path.

```java
// BEFORE — OMS-initiated cancels never reach this block; enqueue lives after the
// if (orderCanBeCancelled) block, inside a standalone if (cancellationFromWithinWMS) guard:
if (cancellationFromWithinWMS) {
    // ... build orderBatchDto ...
    outboxService.enqueue(OutboxMessage.builder()
        .processType(WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS)
        .destinationUrl(urlPath)
        .payload(payload)
        .build());
}

// AFTER — move the enqueue INSIDE the if (orderCanBeCancelled) true-branch (lines ~643-693),
// just after the cancelOrderPosition loop. Do NOT place it on the markedforcancellation path
// (lines ~699-700) — no actual cancel happened there, so OMS must not receive a callback.
// Remove the standalone if (cancellationFromWithinWMS) guard entirely.
//
// Pseudocode showing the correct placement:
if (orderCanBeCancelled) {
    for (CustomerorderPosition coPosition : coPositions) {
        cancelOrderPosition(pickingOrder, coPosition);  // existing loop
    }
    finalizeBatchIfComplete(customerOrder);  // existing call
    // NEW: unconditional outbox — fires for both WMS- and OMS-initiated cancels,
    // but ONLY when the order actually changed state to CANCELED.
    outboxService.enqueue(OutboxMessage.builder()
        .processType(WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS)
        .destinationUrl(urlPath)
        .payload(payload)
        .build());
} else if (pickingconfirmationsent) {
    cleanUpCancelledOrder(customerOrder);  // deferred path — has its own enqueue (§4 row 6a)
} else {
    customerOrder.setMarkedforcancellation(true);  // NO outbox — cancel not yet processed
}
```

> ⚠️ **`ORDER_BATCH_CANCELLED_FROM_PSD` vs `ORDER_BATCH_CANCELLED_FROM_WMS`**: `OrderRestController.java:597,614` emits `ORDER_BATCH_CANCELLED_FROM_PSD` (a distinct constant at `WmsConstants.java:457`). Phase 2 must confirm whether the controller-level PSD emit and the new unconditional WMS emit would both fire for the same cancel request — producing two OMS callbacks. Audit `OrderRestController.java:534-630` before Phase 2 ships: if PSD fires unconditionally at the controller level, the service-level WMS enqueue creates a double-callback. Resolution: either suppress the controller-level PSD emit on the `/cancelPositions` path or confirm OMS's `/services/call/cancelPosition` is fully idempotent for duplicate calls.

**Why this is safe:** OMS's `/services/call/cancelPosition` handler calls `LegacyPositionCancelService.cancelPositions()` which finds and cancels the parcel. For OMS-initiated cancels OMS already knows the parcel is being cancelled — re-confirming via the same endpoint is idempotent (cancel of an already-cancelled parcel is a no-op on the OMS side). OMS gains a reliable delivery signal via the transactional outbox (up to 5 retry attempts via `OutboxDispatchService`).

**OMS inventory double-count risk (must confirm before Phase 2 ships):** This design assumes OMS does NOT pre-cancel its own parcel inventory when it sends `/cancelPositions` to WMS — i.e., OMS's `returnInventoryToAvailable()` fires only when it receives WMS's callback, not when it initiates the request. If OMS pre-cancels inventory on its side before calling WMS, the callback would double-increment `quantity_available`. Verify this with the OMS team — check whether any OMS code reduces `quantity_allocated` at the point of sending the cancel request. The current WMS-initiated cancel flow works correctly in production (implying OMS is callback-only), but this must be explicitly confirmed before Phase 2 deploys.

**Payload (unchanged `OrderBatchDto` shape):**
```json
{
  "batch_id": "BATCH-001",
  "facility_code": "WC01",
  "positions": [
    {
      "unique_id": "EXT-CO-123",
      "positions": [
        { "unique_id": "EXT-POS-456", "amount": 6, "number": 1, "sku_id": "SKU-123" }
      ]
    }
  ]
}
```

OMS's validator only reads `batch_id` and `positions[*].unique_id`; the nested position fields are ignored.

#### 3.5.2 Reversal completion (Phase 3)

**Why a separate OMS endpoint is required (not `/services/call/cancelPosition`):**

OMS's `/services/call/cancelPosition` handler unconditionally calls `returnInventoryToAvailable()` (in `LegacyPositionCancelService:192-205`), which increments `product_inventory.quantity_available` by the cancelled quantity. That adjustment already fired when `ORDER_BATCH_CANCELLED_FROM_WMS` was delivered (Phase 1). If WMS reused the same URL for the reversal completion, OMS would call `returnInventoryToAvailable()` a second time and **double-count available stock**. A dedicated endpoint is the only safe option.

**WMS changes:**

Add one new constant and one new sysprop to `WmsConstants`:

```java
// MessageProcessType
public static final String ORDER_BATCH_REVERSAL_COMPLETED = "ORDER_BATCH_REVERSAL_COMPLETED";

// Sysprop key / default
public static final String SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED_URL_KEY =
    "WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED";
public static final String SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED_URL_DEFAULT_VALUE =
    "https://oms-XXXXX.siteboss.net/services/call/batchReversalCompleted";
```

In `CancellationReversalService.completeReversal()`, after all positions on a CO are marked reversed, enqueue via `OutboxService`:

```java
String urlPath = syspropService.getSysvalue(
    WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED_URL_KEY);
outboxService.enqueue(OutboxMessage.builder()
    .aggregateType("CUSTOMER_ORDER")
    .aggregateId(customerOrder.getId())
    .processType(WmsConstants.MessageProcessType.ORDER_BATCH_REVERSAL_COMPLETED)
    .destinationUrl(urlPath)
    .payload(buildReversalPayload(customerOrder, orderBatch, positions))
    .build());
```

**Payload — reuses `OrderBatchDto` shape:**

```json
{
  "batch_id": "BATCH-001",
  "facility_code": "WC01",
  "positions": [
    {
      "unique_id": "EXT-CO-123",
      "positions": [
        { "unique_id": "EXT-POS-456", "amount": 6, "sku_id": "SKU-123" }
      ]
    }
  ]
}
```

Same DTO, same parsing code — OMS only needs `batch_id` and `positions[*].unique_id` to identify the parcel.

**OMS changes required (for OMS team — Phase 3 prerequisite):**

New route in `LegacyWmsController`: `POST /services/call/batchReversalCompleted`

```php
// What this handler MUST do:
// 1. Validate: batch_id (required), positions[].unique_id (required)
// 2. Find Parcel by unique_id within the batch
// 3. Update parcel status to 'REVERSAL_COMPLETED' (or set reversal_completed_at timestamp)
// 4. Write audit log row
// 5. Return { "Status": "Success" }
//
// What this handler MUST NOT do:
// ✗ Do NOT call returnInventoryToAvailable() — inventory was already restored by /cancelPosition
// ✗ Do NOT update product_inventory quantities
```

This is a thin handler — no `ProductInventory` writes, no allocation changes. It is purely an audit/status update. OMS team effort: low.

**Delivery guarantee:** same `OutboxDispatchService` (up to 5 retry attempts, idempotency key on HTTP POST). If OMS does not have the endpoint deployed, outbox messages accumulate and retry — no data loss.

### 3.6 New mobile API endpoints — `OrderCancellationController`

Base path: `/v3/cancellation`. All endpoints require `@PreAuthorize("hasAuthority('MOBILE_UI_VIEW_CANCELLATION')")`. All controller methods extend the existing `BaseControllerTest` test pattern.

| Method | Path | Role | Description |
|---|---|---|---|
| GET | `/v3/cancellation/list` | `MOBILE_UI_VIEW_CANCELLATION` | Returns `List<CancellationListDto>` — orders with `reversal_required=true, reversal_completed_at=null`. |
| GET | `/v3/cancellation/{customerOrderId}/detail` | `MOBILE_UI_VIEW_CANCELLATION` | Returns `CancellationDetailDto` — order header + positions + log entries + source locations. |
| POST | `/v3/cancellation/scan-tote` | `MOBILE_UI_VIEW_CANCELLATION` | Body `{ toteLabel }` → returns `CancellationDetailDto` for the pending CO on that tote (query: `tote_label_id = :toteLabel AND reversal_required = true AND reversal_completed_at IS NULL`). One tote always maps to exactly one CO (enforced by `Customerorder.pickingtoteId` singular field and the empty-tote check in `MobilePickingService`). Returns 404 with `"No pending reversals for tote {label}"` when the CO on this tote is already reversed or not cancelled. |
| POST | `/v3/cancellation/{customerOrderId}/initiate` | `MOBILE_UI_VIEW_CANCELLATION` | Body `{ operatorId, notes }`. Sets `reversal_initiated_at/by`. Returns updated detail. |
| POST | `/v3/cancellation/{customerOrderId}/complete` | `MOBILE_UI_VIEW_CANCELLATION` | Body `{ operatorId, notes, positionIds[] }`. Sets `reversal_completed_at/by`, calls stock-move service, enqueues `ORDER_BATCH_REVERSAL_COMPLETED` (Phase 3 new type). **Must be idempotent** — `reversal_completed_at IS NULL` guard. |

**DTOs (new):**

- `CancellationListDto`: `customerorderId`, `customerorderNumber`, `customerName`, `cancelledAt`, `pendingPositionCount`, `reversalInitiated`, `initiatedBy`.
- `CancellationDetailDto`: `header` (order summary) + `positions: List<CancellationLogEntryDto>`.
- `CancellationLogEntryDto`: `logId`, `positionId`, `sku`, `skuDescription`, `amount`, `toteLabel`, `sourceStockLocation` (code + path), `reversalCompletedAt`, `reversalCompletedBy`.

**Service:** `CancellationReversalService`

```java
@Service
public class CancellationReversalService {
    @Transactional(transactionManager = "tenantTransactionManager")
    public CancellationDetailDto initiateReversal(Long coId, Long operatorId, String notes) { ... }

    @Transactional(transactionManager = "tenantTransactionManager")
    public CancellationDetailDto completeReversal(Long coId, Long operatorId, String notes, List<Long> positionIds) {
        // 1. Load log entries with FOR UPDATE
        // 2. For each: guard reversal_completed_at IS NULL (idempotent)
        // 3. Resolve stockunit: stockunitRepository.findById(log.getPicktostockunitId())
        //    Note: one CO = one tote; tote may have multiple stockunits (one per SKU/position).
        //    picktostockunit_id captured at cancel time identifies the exact stockunit per position.
        // 4. Move stockunit back to source location via StockunitService.transferStock (isTransferToExistingContainer=false)
        // 5. Set reversal_completed_at/by/notes
        // 6. When all log entries for this CO are complete → enqueue ORDER_BATCH_REVERSAL_COMPLETED outbox (new type, Phase 3)
        // 7. Return refreshed CancellationDetailDto
    }

    @Transactional(transactionManager = "tenantTransactionManager", readOnly = true)
    public List<CancellationListDto> listPendingReversals() { ... }

    @Transactional(transactionManager = "tenantTransactionManager", readOnly = true)
    public CancellationDetailDto detail(Long coId) { ... }

    @Transactional(transactionManager = "tenantTransactionManager", readOnly = true)
    public CancellationDetailDto scanTote(String toteLabel) { ... }
}
```

Stock-move integration: `CancellationReversalService.completeReversal()` calls `StockunitService.transferStock()` at `StockunitService.java:145`.

**Actual signature:**
```java
void transferStock(
    Stockunit stockUnit,                   // the stockunit to move (on the tote)
    BigDecimal amountToTransfer,           // amount_picked from the log row
    Boolean isTransferToExistingContainer, // false = move to a named location
    String locationName,                   // destination location name (used when false)
    String unitLoadLabelId,                // existing unitload label (used when true; null otherwise)
    String comment,
    Boolean printLabel
)
```

**Branch decision: `isTransferToExistingContainer = false`** (transfer to source location by name, not to a specific unitload label). Rationale: we have the source location name (derivable from `pickfromstocklocation_id`), not the original source unitload label — and the original unitload may have been moved or disposed since the pick. The `false` branch handles all location types: for flowbin locations it uses the fixed-location assignment; for normal bins, when the full tote amount equals the transfer amount and no other stockunits share the tote, `transferStock` moves the whole unitload atomically to the source location (zero overhead); otherwise it creates a new unitload at the source location.

**Argument mapping:**
- `stockUnit` — resolved directly from the log: `stockunitRepository.findById(log.getPicktostockunitId())`. Using `picktostockunit_id` (captured at cancel time, see §3.4 item 7) avoids the `.get(0)` ambiguity when the tote carries multiple SKUs from different orders.
- `amountToTransfer` — `amount_picked` from the log row (as `BigDecimal`)
- `isTransferToExistingContainer` — `false`
- `locationName` — `log.getPickfromlocationname()` — the source location name stored in the cancellation log row at cancel time (see §3.4 item 2). No repository lookup needed; the denormalized string is already in the log. `StockunitService.transferStock()` uses `locationRepository.findByName(locationName)` internally — verified at `StockunitService.java:173`.
- `unitLoadLabelId` — `null` (ignored when `isTransferToExistingContainer=false`)
- `comment` — `"CANCELLATION_REVERSAL"`
- `printLabel` — `false`

If `pickfromstocklocation_id` is full or the flowbin is assigned to a different SKU, `transferStock` throws `BusinessException` — propagate as HTTP 409 from the `/complete` endpoint with message "Source location unavailable for position {positionId} — manual intervention required". The `/complete` endpoint is idempotent so the operator can retry after manual relocation. A staging-location fallback is deferred to follow-up F3.

### 3.7 Mobile UI — Cancellation Process flow

**Menu registry update** — `v2/wms2-mobile-ui/store/home.js`. Insert as item 12, after "Transfer Process":

```js
{
  title: "Cancellation Process",
  link: "/cancellation",
  icon: "mdi-cancel",
  role: "MOBILE_UI_VIEW_CANCELLATION"
}
```

Role `MOBILE_UI_VIEW_CANCELLATION` follows the established `MOBILE_UI_VIEW_*` pattern: seeded in `mywms_function` via `V2.1.12` migration (Phase 1), returned by `GET /user/getAllRoles/{username}`, filtered by `results.includes(menu.role)` in `store/home.js:104`. No Keycloak realm changes needed — functions are managed in the WMS database, not in Keycloak.

The 4×3 PAGE TWO grid becomes 4×3 with 6 items: Truck Loading, Cycle Count, Replenish Process, Replenish Request, Transfer Process, **Cancellation Process**.

**Page `pages/cancellation.vue`:**

```vue
<template>
  <div>
    <cancellationScan   v-if="process === '0_scan'" />
    <cancellationList   v-if="process === '0_list'" />
    <cancellationDetail v-if="process === '1_detail'" />
    <cancellationAction v-if="process === '2_action'" />
  </div>
</template>

<script>
export default {
  // Reset state every time the page is entered (covers Android back-button re-entry)
  created() {
    this.$store.commit('cancellation/RESET');
  }
}
</script>
```

**Vuex module `store/cancellation.js`:**

```js
export const state = () => ({
  process: '0_scan',
  selectedOrder: null,
  sourceFlow: null   // '0_scan' | '0_list' — for back navigation
});

export const mutations = {
  SET_PROCESS(state, p) { state.process = p; },
  SET_SELECTED_ORDER(state, o) { state.selectedOrder = o; },
  SET_SOURCE_FLOW(state, f) { state.sourceFlow = f; },
  RESET(state) { state.process = '0_scan'; state.selectedOrder = null; state.sourceFlow = null; }
};

export const actions = {
  async scanTote({ commit }, toteLabel) { /* POST /v3/cancellation/scan-tote */ },
  async fetchList({ commit }) { /* GET /v3/cancellation/list */ },
  async fetchDetail({ commit }, coId) { /* GET /v3/cancellation/{id}/detail */ },
  async initiateReversal({ commit }, payload) { /* POST .../initiate */ },
  async completeReversal({ commit }, payload) { /* POST .../complete */ }
};
```

**Step components (under `components/cancellation/`):**

| Step | Component | Behavior |
|---|---|---|
| 0_scan | `cancellationScan.vue` | Barcode/text input for tote label. On scan → `scanTote(label)`. If found, `SET_SOURCE_FLOW('0_scan')`, `SET_SELECTED_ORDER(dto)`, `SET_PROCESS('1_detail')`. "View List" → `SET_PROCESS('0_list')`. "Main Menu" → `goBack()`. Show last-scanned feedback (success/not-found). |
| 0_list | `cancellationList.vue` | v-list of pending reversal orders: order#, customer, date, # items, status chip. On tap → `SET_SOURCE_FLOW('0_list')`, `SET_SELECTED_ORDER`, `SET_PROCESS('1_detail')`. "Scan Tote" → `SET_PROCESS('0_scan')`. "Main Menu" → `goBack()`. Pull-to-refresh hits `fetchList()`. |
| 1_detail | `cancellationDetail.vue` | Order header card (order#, customer, cancelled date, operator). Item list with per-position reversal status (source location, qty, done?). "Start Reversal" → `initiateReversal()` → `SET_PROCESS('2_action')`. "Back" → returns to `sourceFlow`. "Main Menu" → `goBack()`. |
| 2_action | `cancellationAction.vue` | Per-item checklist: "Return [qty] of [SKU] from [tote] to [location]". Each row has checkbox. "Complete Reversal" enabled when all checked → `completeReversal({ positionIds })` → show snackbar "Reversal complete." → return to `sourceFlow`. "Back" → `SET_PROCESS('1_detail')`. "Main Menu" → `goBack()`. |

`goBack()` follows the `selectOrder.vue:11,36-40` pattern: `refreshMenus()` + `router.push('/')`.

### 3.8 Mobile UI — visual placement

- PAGE TWO grid (with new item 12):

```
[ 7  Truck Loading      ]  [ 8  Cycle Count        ]  [ 9  Replenish Process  ]
[ 10 Replenish Request  ]  [ 11 Transfer Process   ]  [ 12 Cancellation Proc. ]
```

---

## §4. File Change Summary

| # | File | Action | Phase | Description |
|---|------|--------|-------|-------------|
| 1 | `OrderRestController.java` | Modify | 2 | (Indirect) None — `/cancelPositions` semantics unchanged. Audit only. |
| 2 | `CustomerorderService.java` | Modify | 2 | `cancelOrder()` — remove `if (cancellationFromWithinWMS)` guard so `ORDER_BATCH_CANCELLED_FROM_WMS` outbox fires for both WMS- and OMS-initiated cancels. |
| 3 | `CustomerorderService.java` | Modify | 2 | `forceCancelOrder()` — invoke `CancellationLogService` for force-cancel path. |
| 4 | `CustomerorderPositionService.java` | Modify | 2 | `canOrderPositionBeCancelled()` — change blocking range from `[RESERVED, FINISHED)` to `[PACKED, FINISHED)`. |
| 5 | `CustomerorderPositionService.java` | Modify | 2 | `cancelOrderPosition()` — (a) record cancellation log before null; (b) relax inner pre-check guards at lines 121-126 from `[RESERVED, FINISHED)` to `[PACKED, FINISHED)` (Change C — required for Change A/B to take effect); (c) fix header promotion predicate; (d) clear operator fields. |
| 6 | `PickingorderBusinessService.java` | Modify | 2 | `cleanUpCancelledOrder()` — create log entries for deferred path. |
| 6a | `PickingorderBusinessService.java` | Modify | 2 | `cleanUpCancelledOrder()` — add outbox enqueue for deferred-path OMS notification. |
| 7 | `PickingorderBusinessService.java` | Audit | 2 | `finishPickingOrder()` — verify "ORDER_ALREADY_FINISHED" path doesn't conflict with new state transitions. |
| 8 | `CustomerorderBatchService.java` | Audit | 2 | `cancelBatch()` — confirm batch-level cancel still works after header bug fix. |
| 9 | `WmsConstants.java` | Modify | 3 | Add `ORDER_BATCH_REVERSAL_COMPLETED` (MessageProcessType) + `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED_URL_KEY` / `…_DEFAULT_VALUE` (sysprop). No change in Phase 2. |
| 9a | `WmsConstants.java` | Modify | 1 | Add `MOBILE_UI_VIEW_CANCELLATION` constant to `FunctionEnum` inner class (after `MOBILE_UI_VIEW_LPN_ASSOCIATION` at line 421). |
| 10 | `AbstractBaseEntity.java` | Audit | 2 | Confirm `@Version` annotation present; no change. |
| 11 | `PickingorderRepository.java` | Audit | 2 | Confirm 1s pessimistic-lock timeout is still appropriate for cancel + concurrent pick. |
| 12 | `Customerorder.java` | Modify | 2 | Add `@OneToMany` relation to `CustomerorderCancellationLog` (optional, can use lazy fetch via repository). |
| 13 | `CustomerorderCancellationLog.java` | Add | 1 | New JPA entity. |
| 14 | `V2.1.12__add_cancellation_reversal_log_and_grant.sql` | Add | 1 | Flyway migration — first seeds the `MOBILE_UI_VIEW_CANCELLATION` function into `mywms_function` (INSERT using `SELECT MAX(id)+1`; idempotent via `ON CONFLICT (function) DO NOTHING` — unique constraint is on `function`, not `name`), then creates `customerorder_cancellation_log` (operator columns as `VARCHAR(255)`) + 2 indexes + idempotent role grant. Consolidated from earlier per-step migrations (function-seed, table, operator-id `VARCHAR` ALTER) plus the role grant into one file (renamed from V1.1.17 to avoid collision with v1-onboarding OMS sysprops file). |
| 15 | `OrderCancellationController.java` | Add | 3 | New REST controller with 5 endpoints. |
| 16 | `CancellationReversalService.java` | Add | 3 | New service for reversal orchestration. |
| 17 | `CustomerorderCancellationLogRepository.java` | Add | 1 | New Spring Data JPA repository. |
| 18 | `CancellationLogService.java` | Add | 1 | New service — single responsibility: write log entries. |
| 19 | `CancellationListDto.java`, `CancellationDetailDto.java`, `CancellationLogEntryDto.java` | Add | 3 | New DTOs. |
| 20 | `wms2-mobile-ui/store/home.js` | Modify | 4 | Add menu item 12. |
| 21 | `wms2-mobile-ui/pages/cancellation.vue` | Add | 4 | New page. |
| 22 | `wms2-mobile-ui/components/cancellation/cancellationScan.vue` | Add | 4 | Step 0_scan. |
| 23 | `wms2-mobile-ui/components/cancellation/cancellationList.vue` | Add | 4 | Step 0_list. |
| 24 | `wms2-mobile-ui/components/cancellation/cancellationDetail.vue` | Add | 4 | Step 1_detail. |
| 25 | `wms2-mobile-ui/components/cancellation/cancellationAction.vue` | Add | 4 | Step 2_action. |
| 26 | `wms2-mobile-ui/store/cancellation.js` | Add | 4 | New Vuex module. |
| 27 | Unit + integration tests | Add | 1–3 | One test class per new service / controller. |

---

## §5. Phased Implementation Plan

### §5.0 Prerequisites

- DB target `wms2-wineco-dev` is reachable for migration smoke test.
- No in-flight PRs touching `CustomerorderPositionService`, `CustomerorderService.cancelOrder`, `PickingorderBusinessService.cleanUpCancelledOrder` — confirmed via `git log --since=14days` on the wms2-api repo.
- The cancellation feature occupies contiguous Flyway versions `V2.1.12` (the `MOBILE_UI_VIEW_CANCELLATION` function seed + the `customerorder_cancellation_log` table + operator-id `VARCHAR(255)` columns + role grant, all consolidated into one file) and `V2.1.13` (the reversal-completed sysprop). The v2 sequence `V2.1.01…V2.1.13` is contiguous — no gaps; the per-step migrations were consolidated into these two files. `V1.1.17` is **already taken** by `db/migration/v1-onboarding/V1.1.17__oms_endpoint_sysprops_v1client.sql` (shipped 2026-05-27). `V1.1.18` is reserved for future v1-onboarding use. Verify by running: `find v2/wms2-api/src/main/resources/db/migration -name "V1.1.1*.sql" | sort` and confirming no clashing top-level files exist.
- Phase 1 ships `V2.1.12` (function seed + table + grant).
- `MOBILE_UI_VIEW_CANCELLATION` function does NOT yet exist in `mywms_function` — confirmed by DB query on wineco-dev (2026-05-23): highest MOBILE_UI_VIEW_* id is 51775. `V2.1.12` seeds it using `SELECT MAX(id)+1` with `ON CONFLICT (function) DO NOTHING` (atomic; no hardcoded ID — table has no sequence).
- Confirm with OMS team that OMS does NOT pre-cancel parcel inventory before calling WMS /cancelPositions (R8 — see §3.5.1).
- The existing `OutboxMessageService` / outbox publisher job is healthy (no pending messages older than SLA) — check Grafana dashboard before Phase 1 rollout.
- Mobile UI build pipeline for `wms2-mobile-ui` is green on `develop`.

---

### §5.1 Phase 1 — Reversal Tracking Schema

**Goal:** Persist cancellation context (source location, amount, tote) before destructive null.

**Branch:** `feature/cancellation-reversal-tracking`

**Changes:**

1. `V2.1.12__add_cancellation_reversal_log_and_grant.sql` — single Flyway migration that first seeds `MOBILE_UI_VIEW_CANCELLATION` into `mywms_function`, then creates the `customerorder_cancellation_log` table (operator columns declared directly as `VARCHAR(255)`) + 2 indexes, then idempotently grants `MOBILE_UI_VIEW_CANCELLATION` to roles. Consolidated from earlier per-step migrations — the standalone function-seed, the original table migration, the operator-id `VARCHAR` ALTER — plus the role grant into one file (renamed from V1.1.17 to avoid collision with v1-onboarding). The function-seed INSERT runs first:
   ```sql
   INSERT INTO mywms_function (id, created, modified, name, number, version, function, client_id)
   SELECT (SELECT MAX(id) FROM mywms_function) + 1,
          NOW(), NOW(),
          'MOBILE_UI_VIEW_CANCELLATION', 'MOBILE_UI_VIEW_CANCELLATION',
          0, 'MOBILE_UI_VIEW_CANCELLATION', 0
   ON CONFLICT (function) DO NOTHING;
   -- Note: unique constraint is on `function` column (not `name`) per V1.0.01__wms_tables.sql:612.
   -- ON CONFLICT is atomic; avoids MAX(id)+1 race in concurrent deployments.
   ```
2. `WmsConstants.java` — add `MOBILE_UI_VIEW_CANCELLATION` constant to `FunctionEnum` (after line 421):
   ```java
   public static final String MOBILE_UI_VIEW_CANCELLATION = "MOBILE_UI_VIEW_CANCELLATION";
   ```
3. `CustomerorderCancellationLog.java` — new JPA entity.
4. `CustomerorderCancellationLogRepository.java` — Spring Data repository with finders `findByCustomerorderId`, `findPendingReversals(tenant, facility)`, `findByToteLabelId`.
5. `CancellationLogService.java` — single-responsibility log writer.
6. `CustomerorderPositionService.cancelOrderPosition()` — call `cancellationLogService.recordCancellation(...)` before nulling `pickfromstockunit_id`.
7. `PickingorderBusinessService.cleanUpCancelledOrder()` — call `cancellationLogService.recordCancellation(...)` for each cancelled position in the deferred path.
8. `CustomerorderService.forceCancelOrder()` — also write log entries.

**Acceptance criteria:**

- Migration runs cleanly on PG 15 (dev) and H2 (Testcontainers).
- Cancelling a `PICKED` order produces one log row per position with: `reversal_required=true`, populated `pickfromstockunit_id`, `pickfromstocklocation_id`, `amount_picked`, `tote_label_id`.
- Cancelling a `STARTED` order produces log rows with `reversal_required=false` (no physical movement).
- Cancelling via the deferred path (`pickingconfirmationsent=true`) also produces log rows.
- Log write participates in the same tenant transaction as the cancel. If the log write fails (e.g., constraint violation, transient DB error), the cancel transaction rolls back and the caller receives a BusinessException. This is intentional: a cancelled-but-unlogged PICKED order creates an irrecoverable orphan tote. The caller (OMS) will retry the cancel and the log write will succeed on the next attempt.
- The `idx_cancel_log_reversal_pending` partial index is created.

**Tests:**

- `CancellationLogServiceTest.recordCancellation_capturesSnapshotBeforeNull()`
- `CancellationLogServiceTest.recordCancellation_setsReversalRequiredFalseForReserved()`
- `CancellationLogServiceTest.recordCancellation_setsReversalRequiredTrueForPicked()`
- Testcontainers: `CancellationLogIT` — full cancel flow asserts log row exists with correct fields.
- Repository test: `findPendingReversals` returns only `reversal_required=true AND reversal_completed_at IS NULL`.

**Risk:** Low — additive schema, additive service.

---

### §5.2 Phase 2 — Bug Fixes (Pickingorder header + guard relaxation)

**Goal:** Fix the intermittent header bug and allow cancellation of `STARTED (500)` / `PICKED (600)` orders.

**Branch:** `feature/cancel-picked-order-support`

**Changes:**

1. `CustomerorderPositionService.canOrderPositionBeCancelled()` — change blocking range from `[RESERVED, FINISHED)` to `[PACKED, FINISHED)`.
2. `CustomerorderPositionService.cancelOrderPosition()` — fix `allMatch(>= FINISHED)` predicate to handle `CANCELED` correctly; promote header to `CANCELED` when all positions are cancelled; clear `lockedtooperator`, `operator_id`, `pickinginprogress` on terminal state.
3. `CustomerorderService.cancelOrder()` — remove the `if (cancellationFromWithinWMS)` guard so the existing `ORDER_BATCH_CANCELLED_FROM_WMS` outbox fires unconditionally on cancel success (no new constant needed).
4. `PickingorderBusinessService.cleanUpCancelledOrder()` — add outbox enqueue for `ORDER_BATCH_CANCELLED_FROM_WMS` at the end of the method (after finalizeBatchIfComplete), using the same builder pattern as `CustomerorderService.java:733–739`. This closes the gap where OMS-initiated cancels that go through the deferred path (pickingconfirmationsent=true) never notify OMS.

**Acceptance criteria:**

- Cancelling a CO in `STARTED (500)` state succeeds; reservation released; position state = `CANCELED`.
- Cancelling a CO in `PICKED (600)` state succeeds; position state = `CANCELED`; `pickfromstockunit_id` is nulled (still — Phase 1 adds the log first).
- Cancelling a CO in `PACKED (650)` state still throws `BusinessException` ("order already packed").
- For a shared picking order, cancelling one CO promotes the PO header to `FINISHED` only if other CO positions are already `>= FINISHED`; if all are `CANCELED`, the PO header is `CANCELED`. Otherwise the PO header is unchanged.
- After full cancel, `pickingorder.lockedtooperator=false`, `operator_id=null`, `pickinginprogress=false`.
- Existing tests for `cancelOrder` continue to pass.
- One outbox row of type `ORDER_BATCH_CANCELLED_FROM_WMS` is produced per cancel (regardless of whether OMS or WMS initiated it). Payload: `batch_id` + `positions[].unique_id` populated.
- An order that is cancelled via the deferred path (pickingconfirmationsent=true, enters cleanUpCancelledOrder) also produces one ORDER_BATCH_CANCELLED_FROM_WMS outbox row.

**Tests:**

- `CustomerorderPositionServiceTest.cancelOrderPosition_setsHeaderCanceledWhenAllCanceled()`
- `CustomerorderPositionServiceTest.cancelOrderPosition_setsHeaderFinishedWhenMixedTerminal()`
- `CustomerorderPositionServiceTest.cancelOrderPosition_clearsOperatorFieldsOnTerminal()`
- `CustomerorderPositionServiceTest.canOrderPositionBeCancelled_allowsStartedAndPicked()`
- `CustomerorderServiceTest.cancelOrder_state600_succeeds()`
- `CustomerorderServiceTest.cancelOrder_state650_throws()`
- `CustomerorderServiceTest.cancelOrder_omsInitiated_directPath_enqueuesOrderBatchCancelledFromWmsOutbox()` — OMS-initiated cancel on the `orderCanBeCancelled=true` path; asserts one outbox row of type `ORDER_BATCH_CANCELLED_FROM_WMS`.
- `CustomerorderServiceTest.cancelOrder_omsInitiated_markedForCancellationPath_doesNotEnqueueOutbox()` — order is `markedforcancellation=true` path (`orderCanBeCancelled=false`, `pickingconfirmationsent=false`); asserts zero outbox rows.
- `CustomerorderPositionServiceTest.cancelOrderPosition_state500_doesNotThrow()` — drives `cancelOrderPosition()` directly with `pickingOrder.state=STARTED (500)` and `pickingPosition.state=STARTED (500)`; asserts no `BusinessException` (verifies Change C inner guard).
- `CustomerorderPositionServiceTest.cancelOrderPosition_state600_doesNotThrow()` — drives `cancelOrderPosition()` directly with `pickingPosition.state=PICKED (600)`; asserts no `BusinessException` (verifies Change C inner guard).
- `PickingorderBusinessServiceTest.cleanUpCancelledOrder_enqueuesOrderBatchCancelledFromWmsOutbox()` — exercises the deferred path (`pickingconfirmationsent=true`) directly; asserts one outbox row of type `ORDER_BATCH_CANCELLED_FROM_WMS` with payload containing `batch_id` + `positions[].unique_id`. This is the missing coverage for §4 row 6a.
- `PickingorderBusinessServiceTest.cleanUpCancelledOrder_omsInitiated_alsoEnqueuesOutbox()` — OMS-initiated cancel that takes the deferred path; asserts one outbox row.
- Testcontainers: `ConcurrentCancelPickIT` — start picking + cancel in parallel; assert no orphaned state; assert exception at controller boundary is `BusinessException → 400` (not `PessimisticLockingException → 500`).

**Risk:** Medium — touches core picking state machine. Mitigated by precise unit tests + Testcontainers integration test + staged rollout to wineco-dev → wineco-qa.

---

### §5.3 Phase 3 — Mobile API Endpoints

**Goal:** Expose reversal list / detail / initiate / complete via REST.

**Branch:** `feature/cancellation-mobile-api`

**Changes:**

1. `OrderCancellationController.java` — new controller, 5 endpoints, `@PreAuthorize("hasAuthority('MOBILE_UI_VIEW_CANCELLATION')")`.
2. `CancellationReversalService.java` — business logic.
3. `CancellationListDto.java`, `CancellationDetailDto.java`, `CancellationLogEntryDto.java`.
4. Integration with `StockunitService.transferStock()` for the `complete` endpoint's stock-move action.
5. Add `ORDER_BATCH_REVERSAL_COMPLETED` constant to `WmsConstants.MessageProcessType` + new sysprop `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED_URL_KEY`. Emit outbox on reversal complete.

**Acceptance criteria:**

- `GET /v3/cancellation/list` returns all orders with pending reversals scoped by tenant + facility headers.
- `GET /v3/cancellation/{id}/detail` returns full reversal context for one CO.
- `POST /v3/cancellation/scan-tote` resolves a tote barcode to the pending CO on that tote (one tote = one CO, enforced by `Customerorder.pickingtoteId`); returns 404 when the CO is already reversed or the tote label has no pending cancellation log entry.
- **Multi-SKU same-CO tote:** when CO-1 has positions for SKU-A (→ BIN-A) and SKU-B (→ BIN-B), both picked into TOTE-001, completing the reversal moves StockUnit-A to BIN-A and StockUnit-B to BIN-B independently using `picktostockunit_id` per position. No cross-contamination between positions. `ORDER_BATCH_REVERSAL_COMPLETED` is enqueued once when all positions of CO-1 are reversed.
- `POST /v3/cancellation/{id}/initiate` is non-blocking and idempotent (re-initiating updates `notes` only).
- `POST /v3/cancellation/{id}/complete` is **idempotent** — calling twice does not double-move stock; guard on `reversal_completed_at IS NULL` with FOR UPDATE.
- Stock is physically moved back to source location (or to a configured "reversal staging" location if source is now full — Phase 3 scope: error and require manual intervention if blocked).
- One `ORDER_BATCH_REVERSAL_COMPLETED` outbox row per CO when **all** positions on that CO are reversed.
- 403 for callers without `MOBILE_UI_VIEW_CANCELLATION`.
- All endpoints respect `tenant_name` + `facility_code` headers via existing `TenantContext`.
- If source location is full, `/complete` returns 409 with error message "Source location unavailable for position {id} — manual intervention required". No partial stock movement occurs (transaction-scoped).

**Tests:**

- `OrderCancellationControllerTest extends BaseControllerTest` — one method per endpoint, happy + auth-denied + tenant-mismatch paths.
- `CancellationReversalServiceTest.completeReversal_isIdempotent()`
- `CancellationReversalServiceTest.completeReversal_enqueuesOutboxWhenAllPositionsReversed()`
- Testcontainers: `CancellationReversalIT` — full E2E: cancel CO via `/cancelPositions` → list shows it → scan tote → initiate → complete → outbox row exists → stockunit moved.

**Risk:** Low — additive new endpoints, gated on a role already present in production.

---

### §5.4 Phase 4 — Mobile UI

**Goal:** Add Cancellation Process menu + 4-screen flow.

**Branch:** `feature/cancellation-mobile-ui`

**Changes:**

1. `store/home.js` — add menu item 12.
2. `pages/cancellation.vue` — page wrapper with conditional step components.
3. `components/cancellation/cancellationScan.vue`
4. `components/cancellation/cancellationList.vue`
5. `components/cancellation/cancellationDetail.vue`
6. `components/cancellation/cancellationAction.vue`
7. `store/cancellation.js` — new Vuex module.

**Acceptance criteria:**

- Menu item "Cancellation Process" appears as item 12 on PAGE TWO of the home grid, only for users with `MOBILE_UI_VIEW_CANCELLATION` role.
- Scan flow: scanning a tote linked to a cancelled order opens the detail screen for that order.
- List flow: tapping an item on the list opens the same detail screen; "Back" returns to the source flow that opened it.
- Detail flow: "Start Reversal" calls `/initiate` and transitions to action step.
- Action flow: "Complete Reversal" is enabled only when all items are checked; calls `/complete`; on success returns to the source flow with a snackbar.
- Every step component has a "Main Menu" button that routes to `/` via the existing `selectOrder.vue` pattern.
- Pull-to-refresh works on the list view.
- 401/403 responses surface a non-cryptic error toast.

**Tests:**

- Jest snapshot tests for each step component.
- Manual smoke test on Android tablet + iOS tablet (warehouse devices) — see §7 Manual Test Plan.

**Risk:** Low — UI only; no backend changes.

---

## §6. Backward Compatibility

| Surface | Impact |
|---|---|
| `/cancelPositions` REST contract | **Unchanged** — same request/response schema. Existing OMS callers unaffected. |
| Orders already in `CANCELED (800)` state | **Unchanged** — idempotent path preserved. |
| Orders in `PACKED (650)` and above | **Unchanged** — still blocked by existing guard. |
| Orders in `STARTED (500)` / `PICKED (600)` | **NEW behavior** — now cancellable. Existing OMS callers that previously received `400 BusinessException` will now receive `200 OK`. This is the intentional feature change; OMS expects the new behavior. |
| `customerorder_cancellation_log` table | **Net-new additive schema.** No existing queries reference it. |
| Mobile menu | **Additive.** One new item; no existing items moved or removed. |
| `MOBILE_UI_VIEW_CANCELLATION` function | **New** — seeded by `V2.1.12` migration (Phase 1). Follows established `MOBILE_UI_VIEW_*` pattern; no Keycloak change needed. |
| Outbox `MessageProcessType` — Phase 1 | **No new constant.** `ORDER_BATCH_CANCELLED_FROM_WMS` is now emitted for OMS-initiated cancels too. OMS's existing `/services/call/cancelPosition` handler is idempotent — no OMS code change needed for Phase 1. |
| Outbox `MessageProcessType` — Phase 3 | **One new constant** `ORDER_BATCH_REVERSAL_COMPLETED`. OMS must add a handler before reversal notifications are meaningful; until then, messages accumulate in `outbox_message` and the publisher retries gracefully. |
| Existing outbox messages | **Unchanged.** No existing constants renamed or removed. |
| `pickingorder.operator_id` clearing | **NEW behavior** — was leaked before, now cleared. Audit query: confirm no downstream consumer relies on a stale `operator_id` after CANCELED state. |

---

## §7. Testing Strategy

### 7.1 Unit tests

- `CustomerorderPositionServiceTest` — cancelOrderPosition fixes (all-CANCELED, mixed terminal, operator clearing).
- `CustomerorderServiceTest` — cancelOrder for state 600 succeeds; state 650 blocked; outbox enqueued.
- `CancellationLogServiceTest` — snapshot captured before null; `reversal_required` correctness per state.
- `CancellationReversalServiceTest` — initiate, complete (idempotent), list, scan-tote, outbox emission.
- `OrderCancellationControllerTest extends BaseControllerTest` — all 5 endpoints × happy / auth-denied / tenant-mismatch.

### 7.2 Integration tests (Testcontainers, PostgreSQL)

- `ConcurrentCancelPickIT` — fork a picker thread and a cancel thread on the same shared picking order; assert no `ObjectOptimisticLockingFailureException` reaches the controller (retry handled or propagated cleanly), no orphan state.
- `CancellationLogIT` — full cancel flow asserts log row created with correct snapshot.
- `CancellationReversalIT` — full E2E: cancel → list → scan → initiate → complete → outbox.
- `SharedPickingOrderCancelIT` — multi-CO PO; cancel one CO, assert PO header stays at `STARTED`; cancel the other, assert PO header transitions correctly.

### 7.3 Manual test plan

| # | Scenario | Environment | Steps | Expected |
|---|---|---|---|---|
| 1 | Cancel order in `STARTED` state | wineco-dev | (a) Start picking order; (b) `POST /cancelPositions`; (c) check CO state | CO=`CANCELED`, PO=`CANCELED`, reservation released, log row exists with `reversal_required=false` |
| 2 | Cancel order in `PICKED` state | wineco-dev | (a) Complete picking (tote labeled); (b) `POST /cancelPositions`; (c) check CO + log table | CO=`CANCELED`, log entry with source location populated, `reversal_required=true` |
| 3 | Cancel `PACKED` order | wineco-dev | (a) Pack order; (b) `POST /cancelPositions` | `400 BusinessException` ("order already packed"), no state change |
| 4 | Shared PO — cancel one CO | wineco-dev | (a) Two COs share one PO, both at `STARTED`; (b) cancel CO-A; (c) check PO header | PO header remains at `STARTED`; CO-A=`CANCELED`; CO-B unchanged |
| 5 | Shared PO — cancel both COs | wineco-dev | continue from (4); cancel CO-B | PO header=`CANCELED`; both COs=`CANCELED`; operator fields cleared |
| 6 | Mobile — scan tote → reversal | wineco-dev mobile | (a) Operator opens Cancellation Process; (b) scans tote of cancelled order; (c) verifies detail; (d) initiates; (e) completes | Detail correct, `/initiate` succeeds, `/complete` succeeds, stock returned to source location, outbox row of type `ORDER_BATCH_REVERSAL_COMPLETED` |
| 7 | Mobile — list flow | wineco-dev mobile | (a) Cancellation Process → View List; (b) tap an order; (c) Back | Detail screen opens; Back returns to list |
| 8 | Mobile — Main Menu button on every screen | wineco-dev mobile | Navigate to each of scan / list / detail / action; tap Main Menu | Returns to home page |
| 9 | Idempotency — double-tap Complete Reversal | wineco-dev mobile | On action screen, tap Complete Reversal twice rapidly | First call succeeds; second is a no-op (logs WARN, returns 200); no double stock movement |
| 10 | RBAC — non-admin user | wineco-dev mobile | Sign in as a picker (no `MOBILE_UI_VIEW_CANCELLATION`); confirm menu | "Cancellation Process" item is not visible; direct API call returns 403 |
| 11 | OMS outbox confirmation | wineco-dev | (a) OMS pushes cancel; (b) WMS completes; (c) check `outbox_message` table | Row of type `ORDER_BATCH_CANCELLED_FROM_WMS` present (same type as WMS-initiated path); `OutboxDispatchService` delivers to OMS `/services/call/cancelPosition` within SLA |
| 12 | Concurrent picker + cancel | wineco-dev | (a) Picker scans next item on PO-X; (b) simultaneously OMS pushes cancel for CO on PO-X | One of: (a) picker finishes the item and cancel happens after; (b) cancel happens first and picker gets BusinessException on next scan. No silent rollback. |

### 7.4 Performance / load

- Measure `cancelOrder` p95 latency before and after Phase 2 (additional log write). Budget: +30 ms acceptable. Run with `wrk` against `/cancelPositions` at 50 rps on dev for 60 s.
- `GET /v3/cancellation/list` should return in <500 ms with up to 1,000 pending orders thanks to the partial index `idx_cancel_log_reversal_pending`.

---

## §8. Rollout Plan

| Step | Action | Owner | Gate |
|---|---|---|---|
| 1 | Land Phase 1 PR on `develop`; deploy to wineco-dev | API team | Migration succeeds, log writer tests green |
| 2 | Smoke test #2, #6 (without mobile UI — use Postman) | QA | All pass |
| 3 | Verify `customerorder_cancellation_log` table and partial index created on wineco-dev | API team | DDL present |
| 4 | Confirm log rows produced on existing cancel paths (RESERVED/STARTED only — guard still blocks PICKED) | QA | Log rows visible |
| 5 | Land Phase 2 PR; deploy to wineco-dev | API team | Phase 2 unit + IT green |
| 6 | Smoke test #1, #3, #4, #5, #11, #12 on wineco-dev | QA | All pass |
| 7 | Land Phase 3 PR; deploy to wineco-dev | API team | Controller + service tests green |
| 8 | Manual scan-tote / initiate / complete via Postman | QA | All pass |
| 9 | Land Phase 4 PR; deploy mobile UI | UI team | Snapshot tests green |
| 10 | Full manual test plan (1–12) on wineco-dev mobile | QA | All pass |
| 11 | Promote to wineco-qa; run manual plan #1–#12 | QA | All pass |
| 12 | Promote to wineco-ua | DevOps | Sign-off from product |
| 13 | Production rollout | DevOps | Final go from PM |
| 14 | Post-deploy: enable Grafana alert on `outbox_message` lag for `ORDER_BATCH_CANCELLED_FROM_WMS` (now higher volume) and new `ORDER_BATCH_REVERSAL_COMPLETED` (Phase 3) | DevOps | Dashboard configured |

Each phase is an **independent PR** mergeable to `develop`. Phases are strictly sequential: Phase 1 must merge before Phase 2; Phase 2 must merge before Phase 3; Phase 3 must merge before Phase 4. Phases 1–3 are in `v2/wms2-api`, Phase 4 is in `v2/wms2-mobile-ui`.

Rollback: each phase is reversible.
- Phase 1: revert PR; the table remains (no harm) — orphan log rows ignored.
- Phase 2: revert PR; the relaxed guard is a logic-only change.
- Phase 3: revert PR; endpoints disappear; mobile UI in Phase 4 will fail gracefully (toast error).
- Phase 4: revert PR; menu item disappears.

---

## §9. Alternatives Considered

1. **Extending `/cancelPositions` with `reversal=true` flag** — *Rejected.* Conflates two operations with different timing (cancel is OMS-driven and immediate; reversal is operator-driven and may happen hours later). A separate endpoint preserves single-responsibility and lets OMS initiate cancel without triggering an automatic physical reversal.
2. **New `ORDER_BATCH_CANCELLATION_COMPLETED` outbox type vs. reusing `ORDER_BATCH_CANCELLED_FROM_WMS`** — *Reuse existing type (Option A).* The OMS `/services/call/cancelPosition` handler already parses `OrderBatchDto` and cancels the parcel idempotently. Using the same type and URL requires zero OMS code changes for Phase 1. A distinct type (Option B) was considered for cases where OMS needs to route the two messages differently, but that is deferred until OMS signals a concrete need. The reversal completion (Phase 3) still uses a new `ORDER_BATCH_REVERSAL_COMPLETED` type because it carries different semantics and OMS will need a separate handler.
3. **New function `MOBILE_UI_VIEW_CANCELLATION`** — *Chosen.* Follows the established `MOBILE_UI_VIEW_*` pattern used by all other mobile menu items (seeded in `mywms_function`, returned by `GET /user/getAllRoles/{username}`, filtered in `store/home.js:104`). Requires one Flyway migration (`V2.1.12`) to seed the function row — no Keycloak realm changes. `wms_admin` (the original candidate) was rejected because it is a Keycloak role that does not flow through the `mywms_function`→`getAllRoles` path consumed by the mobile menu filter.
4. **In-memory reversal tracking** — *Rejected.* Cannot survive server restart or multi-replica deployment. DB table provides persistent audit trail satisfying §8 SOC2 retention requirements.
5. **Automatic stock return** — *Rejected.* Could conflict with concurrent stock operations (another order may have already reserved the same source location). Human-assisted reversal matches the warehouse operational model — operator physically moves stock, then confirms on the mobile device.
6. **Single big-bang PR for all 4 phases** — *Rejected.* Too risky: state-machine bug fix + schema change + new endpoints + new UI on one PR is difficult to bisect on regression. Four staged PRs preserve clean rollback.
7. **Storing reversal data on the `customerorder_position` entity** — *Rejected.* Inflates a frequently-queried hot table with rarely-used audit fields; partial index on a dedicated table is more efficient for "find pending reversals".

---

## §10. Open Questions / Resolved Decisions

### Resolved

- **Guard threshold:** `< PACKED (650)` is cancellable. ✓
- **Operator role:** `MOBILE_UI_VIEW_CANCELLATION` function, seeded by `V2.1.12` migration. Follows `MOBILE_UI_VIEW_*` pattern. ✓
- **Stock source preservation:** snapshot in `customerorder_cancellation_log` before null. ✓
- **Reversal execution model:** human-assisted (scan, view, physically move, confirm). ✓
- **OMS cancellation notification (Phase 1):** reuse existing `ORDER_BATCH_CANCELLED_FROM_WMS` type + URL; remove `if (cancellationFromWithinWMS)` guard. No OMS code change needed. ✓
- **OMS reversal notification (Phase 3):** new `ORDER_BATCH_REVERSAL_COMPLETED` type + new sysprop URL. OMS must add a handler. ✓
- **Stock move on reversal (Q3):** `CancellationReversalService.completeReversal()` calls `StockunitService.transferStock()` to physically move stock back to source location. This is an automatic WMS stock movement, not a pure acknowledgment. Confirmed. ✓
- **Source location unavailability (Q4):** `StockunitService.transferStock()` throws `BusinessException` when the source location is full or the flowbin is assigned to a different SKU. `CancellationReversalService.completeReversal()` propagates this as HTTP 409 with message "Source location unavailable for position {positionId} — manual intervention required". The `/complete` endpoint is idempotent so the operator can retry after manual relocation. Staging-location fallback deferred to F3. ✓

### Open

| # | Question | Why it matters | Tentative answer |
|---|---|---|---|
| Q2 | OMS must implement `POST /services/call/batchReversalCompleted` before Phase 3 ships. | Handler must NOT call `returnInventoryToAvailable()` — inventory already restored on cancel. Audit/status update only. | Design in §3.5.2. OMS team effort: low. Confirm endpoint name and parcel status value (`REVERSAL_COMPLETED` vs a timestamp field) before Phase 3 ships. |
| Q5 | Should the `cancellationAction.vue` reversal require a tote rescan as confirmation, or trust the operator's checkboxes? | UX vs safety trade-off. | Plan position: checkboxes only in v1. Reconsider after one month of production usage. |

All open questions appended to `.omc/plans/open-questions.md` per Planner protocol.

### Closure checklist (what remains before this plan can be archived)

WMS (Phases 1–4) is implemented and merged to `develop`; the items below gate **closure**, not implementation.

- [ ] **OMS endpoint** `POST /services/call/batchReversalCompleted` implemented & deployed (Q2/F1). Tracked in [[SBDEV-1921-oms-batch-reversal-completed-endpoint]]. **Verified absent in `oms-laravel-api` as of 2026-06-16** — `ORDER_BATCH_REVERSAL_COMPLETED` outbox rows will retry against a missing handler until this ships.
- [ ] **Sysprop URL set per environment** — replace the `oms-XXXXX.siteboss.net` placeholder default (`WmsConstants.java:922`) with the real per-env URL for `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` (wineco-dev/qa/ua/prod). Depends on the endpoint above.
- [ ] **Prod rollout recorded** — §8 promotion gates beyond `develop` (qa → ua → prod) + post-deploy Grafana outbox-lag alert (step 14) executed and noted here.
- [x] **Verify script created** — `sbdocs/9-System/scripts/verify-SBDEV-1921-order-cancellation-reversal-workflow.sh` (regression-guards the merged WMS contract; see §14).
- [x] **Status reconciled** — frontmatter + body header both say `implemented`; closure gated on the OMS dependency above (2026-06-16).

Deferred follow-ups (F2–F5, Q5) do **not** gate closure — carry them in the archive note.

---

## §11. Horizontal Scalability Validation (10-row)

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | No | No new static / `ThreadLocal` state introduced. |
| 2 | Connection pool math | No | Two new service methods reuse existing pools. No new datasources. |
| 3 | Scheduled jobs | No | No new scheduler. (OutboxPublisherJob is pre-existing.) |
| 4 | Long transactions | Yes — review | `cancelOrder` + log write share one transaction. Measure end-to-end time for a 50-position order. Budget +30 ms. |
| 5 | Request affinity | No | All state in DB; safe for round-robin LB. |
| 6 | Retry / idempotency | Yes | Reversal `complete` endpoint MUST be idempotent (mobile double-tap likely). Implementation guards on `reversal_completed_at IS NULL` under `SELECT … FOR UPDATE`. |
| 7 | Tenant context | No | All new queries use `tenantTransactionManager` and read `TenantContext` headers. |
| 8 | Distributed lock | No | Existing `findByIdForUpdate` PESSIMISTIC_WRITE preserved; no new advisory locks. |
| 9 | Cache invalidation | N/A | No Caffeine cache entries touched. |
| 10 | External notifications | Yes | Phase 1: `ORDER_BATCH_CANCELLED_FROM_WMS` volume increases (now fires for OMS-initiated cancels too). Confirm `OutboxDispatchService` throughput is sufficient on dev before promotion. Phase 3: new `ORDER_BATCH_REVERSAL_COMPLETED` type — confirm publisher picks it up within SLA. |

---

## §12. v2-only Constraint Checklist (8-row)

| # | Constraint | Status | Note |
|---|---|---|---|
| 1 | OSIV disabled — all service methods `@Transactional` | ✓ | New services explicitly annotated. |
| 2 | `tenantTransactionManager` on tenant-scoped methods | ✓ | New service methods use it. |
| 3 | `readOnly = true` on GET-style endpoints | ✓ | List/detail/scan-tote service methods are read-only. |
| 4 | No new Caffeine cache | ✓ | None added. |
| 5 | No new Micrometer counter on this path | ✓ | Low-frequency admin flow; rely on outbox/log table for observability. |
| 6 | Jakarta namespace | ✓ | New entity uses `jakarta.persistence.*`. |
| 7 | H2-compatible DDL | ✓ | Partial index → DDL uses `WHERE`; H2 supports filtered indexes since 2.x. Verified by Testcontainers H2 fallback in CI. |
| 8 | `BaseControllerTest` for new endpoints | ✓ | All 5 endpoints have controller tests extending the base. |

---

## §13. Pre-Implementation Checklist

- [ ] Read `sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md` for current state diagrams.
- [ ] Read `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` for OMS contract.
- [ ] Read `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` for transaction conventions.
- [ ] Confirm Flyway version `V2.1.12` is unused (run `find v2/wms2-api/src/main/resources/db/migration -name "V1.1.1*.sql" | sort` to verify).
- [ ] Confirm `V2.1.12` migration seeds `MOBILE_UI_VIEW_CANCELLATION` into `mywms_function` on all target tenant DBs (wineco-dev, wineco-qa, wineco-ua, wineco-prod) before Phase 4 deploys.
- [ ] Confirm no in-flight PRs on `CustomerorderPositionService` / `CustomerorderService.cancelOrder` / `PickingorderBusinessService.cleanUpCancelledOrder`.
- [ ] Confirm `OutboxPublisherJob` healthy (no backlog).
- [ ] Confirm CI pipeline green on `develop` for both `wms2-api` and `wms2-mobile-ui`.
- [ ] Confirm `OutboxDispatchService` throughput is sufficient for increased `ORDER_BATCH_CANCELLED_FROM_WMS` volume after Phase 1.
- [ ] Confirm OMS team is aware of the new `ORDER_BATCH_REVERSAL_COMPLETED` type and agrees on the endpoint/payload schema before Phase 3 ships (Q2).

---

## §14. Verify-script

**Created:** `sbdocs/9-System/scripts/verify-SBDEV-1921-order-cancellation-reversal-workflow.sh` (2026-06-16). Because the WMS code is already merged, the script acts as a **regression guard** — it asserts the merged contract (constants, migration, entity, service, controller, mobile-UI artifacts) is still in place. The dynamic DB/curl probes below (steps 5–13) remain a manual/CI-env outline; the committed script runs the static structural checks plus the targeted Maven test suites.

Outline (the script implements the static checks; the live-env probes stay manual):

1. `cd v2/wms2-api`
2. `mvn -DskipITs=false -DfailIfNoTests=false test -Dtest=CustomerorderPositionServiceTest,CustomerorderServiceTest,CancellationLogServiceTest,CancellationReversalServiceTest,OrderCancellationControllerTest`
3. `mvn -DskipTests=false -DskipITs=false verify -Dit.test=ConcurrentCancelPickIT,CancellationLogIT,CancellationReversalIT,SharedPickingOrderCancelIT`
4. Assert exit code 0.
5. Connect to `wms2-wineco-dev`; `SELECT count(*) FROM information_schema.tables WHERE table_name = 'customerorder_cancellation_log';` → expect 1.
6. `SELECT count(*) FROM pg_indexes WHERE indexname = 'idx_cancel_log_reversal_pending';` → expect 1.
7. `curl -s -X POST $HOST/v3/cancellation/scan-tote -H "Authorization: Bearer $NON_ADMIN_TOKEN" -d '{"toteLabel":"X"}'` → expect 403.
8. `cd ../wms2-mobile-ui && yarn install && yarn test`
9. Assert all green.
10. Assert no orphan cancel rows (post-Phase 1 / Phase 2): 
    `SELECT count(*) FROM customerorder_position cop 
     LEFT JOIN customerorder_cancellation_log ccl ON ccl.customerorder_position_id = cop.id 
     WHERE cop.state = 800 AND ccl.id IS NULL AND cop.updated_at > $PHASE1_DEPLOY_TS;`
    → expect 0 (orphan CANCELED positions with no log row)

11. DB function row probe (after Phase 1 deploy):
    ```sql
    SELECT id, name FROM mywms_function WHERE name = 'MOBILE_UI_VIEW_CANCELLATION';
    ```
    → expect 1 row

12. Role-binding probe:
    `curl -s -X GET $HOST/v3/cancellation/list \
       -H "Authorization: Bearer $CANCELLATION_ROLE_TOKEN" \
       -H "tenant_name: wineco" -H "facility_code: WC01"` → expect 200 (not 403)
    `curl -s -X GET $HOST/v3/cancellation/list \
       -H "Authorization: Bearer $PICKER_ONLY_TOKEN" \
       -H "tenant_name: wineco" -H "facility_code: WC01"` → expect 403
    (`$CANCELLATION_ROLE_TOKEN` = JWT for a user who has been assigned the `MOBILE_UI_VIEW_CANCELLATION` function via `mywms_role_function`)

13. Concurrent cancel + pick thread outline (for `ConcurrentCancelPickIT`):
    Thread A: acquire PO via MobilePickingService (set state=STARTED), hold for 200ms
    Thread B: immediately call cancelOrder() on the same CO
    Assert: exactly one of (a) cancel succeeds + pick fails with BusinessException, 
            or (b) pick completes + cancel retried/succeeds after; 
    Assert: NO row in customerorder_position with state=STARTED and no matching cancellation_log 
            after both threads complete.

---

## §15. ADR (Consensus Mode)

**Decision:** Implement a 4-phase, additive cancellation + reversal workflow:
1. Add `customerorder_cancellation_log` schema + `CancellationLogService` that snapshots source data before destructive null.
2. Relax `canOrderPositionBeCancelled` to permit `STARTED`/`PICKED` orders + fix `Pickingorder` header promotion bug + remove `if (cancellationFromWithinWMS)` guard so `ORDER_BATCH_CANCELLED_FROM_WMS` fires unconditionally (no new constant).
3. Add `OrderCancellationController` (5 endpoints, gated on `MOBILE_UI_VIEW_CANCELLATION`) + `CancellationReversalService` that drives human-assisted reversal and emits `ORDER_BATCH_REVERSAL_COMPLETED`.
4. Add Cancellation Process menu + 4-screen flow (scan / list / detail / action) on `wms2-mobile-ui`.

**Decision Drivers:**

1. Stock-to-source rollback is impossible without preserving `pickfromstockunit_id` — must log before nulling.
2. `MOBILE_UI_VIEW_CANCELLATION` follows the established `MOBILE_UI_VIEW_*` pattern — consistent with all other mobile menu items, no Keycloak changes needed.
3. The `allMatch(>= FINISHED)` predicate bug causes ghost picking orders in shared-PO scenarios — must be fixed first.

**Alternatives considered:** see §9.

**Why chosen:**

- 4-phase decomposition matches the natural dependency graph (bug fix → schema → API → UI) and gives each phase an independent, bisectable PR.
- Additive schema + additive endpoints preserve full backward compatibility for OMS.
- Human-assisted reversal matches operational reality and avoids race conditions with concurrent stock operations.
- `MOBILE_UI_VIEW_CANCELLATION` follows the `MOBILE_UI_VIEW_*` pattern — consistent with all other mobile menu items; one `V2.1.12` Flyway migration seeds the function row across all tenants automatically.

**Consequences:**

- OMS now receives `ORDER_BATCH_CANCELLED_FROM_WMS` confirmation for all cancels (including OMS-initiated) — manual reconciliation eliminated. No OMS code change needed for Phase 1.
- Cancellation of `STARTED`/`PICKED` orders is enabled — previously-blocked OMS calls now succeed.
- New audit trail: every cancellation that involves physical stock is logged with source location and tote.
- New operator burden: warehouse operators must actively reverse `PICKED`-state cancellations on the mobile device; this is the explicit business decision.
- `ORDER_BATCH_CANCELLED_FROM_WMS` volume increases — OMS `/services/call/cancelPosition` now receives a callback for every cancel, including OMS-initiated ones (idempotent). One new type (`ORDER_BATCH_REVERSAL_COMPLETED`) added in Phase 3; OMS must add a handler for it.
- One new DB table per tenant; `picktounitload_id` column added to `customerorder_cancellation_log` (see B3).
- Phase 1 changes the state-machine behavior — risk mitigated by precise unit tests, Testcontainers concurrency test, and staged rollout.

**Follow-ups:**

- F1: OMS team agrees on endpoint + payload schema for `ORDER_BATCH_REVERSAL_COMPLETED` before Phase 3 ships (Q2).
- F2: After one month of production usage, review whether `cancellationAction.vue` needs a tote-rescan safety step (Q5).
- F3: After three months, review whether automatic source-location fallback (staging) is warranted (Q4).
- F4: Add Grafana dashboard panel for pending reversal count per tenant.
- F5: Consider a daily reconciliation job that emails ops if pending reversals are >24 h old.

---

*End of plan.*
