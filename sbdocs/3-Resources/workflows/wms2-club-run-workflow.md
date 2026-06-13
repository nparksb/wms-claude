---
title: "WMS v2 — Club Run / Club Order Processing Workflow"
type: workflow
status: active
version: v2
scope: club-run
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-06-01
verified_by: code read of v2/wms2-api CustomerorderBatchService + ClubLineController + BillofladingService
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ./wms1-club-order-processing.md
  - ./wms2-picking-workflow.md
  - ./wms2-bol-truck-loading-workflow.md
  - ./wms2-cancel-cascade-workflow.md
  - ../../4-Archieves/wms2/plan/260320-Auto_Release_Club_Transfer_Lane_Fix.md
  - ../../4-Archieves/wms2/plan/260424-Club_Order_Cancellation_Fix_Plan.md
  - ../../4-Archieves/wms2/plan/260424-Club_Order_Cancellation_OMS_Fix.md
  - ../../4-Archieves/wms2/plan/260424-CLUB_ORDER_PROCESSING_PERFORMANCE_PLAN.md
  - ../../4-Archieves/wms2/plan/260424-Cancel_Club_Parcels_Packed_State_Fix.md
  - ../../4-Archieves/wms2/plan/260424-RunClubLine_Cancelled_Order_Fix_Plan.md
  - ../../4-Archieves/wms2/plan/260424-club-location-replenish-fix.md
tags:
  - workflow
  - club-run
  - club-order
  - wms2
---

# WMS v2 — Club Run / Club Order Processing Workflow

**Scope:** Batch-based processing of subscription-style ("club") orders in `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

A **club run** is one execution of a recurring-delivery batch — typically wine-of-the-month — where many orders with identical content are processed as a single wave through staging → pick → pack → palletize → load → ship. Anchor entity: `CustomerorderBatch` (Integer state). The flow is orchestrated from the **desktop** web UI (no mobile path) via `/v3/clubLine/...` REST endpoints, and the heavy lifting lives in `CustomerorderBatchService.runClubLine` (line 743) + `ClubLineOrderProcessor.processOrder()`.

Two load-bearing facts:

1. **Club orders use a synthetic UUID-based tote label**, not a physical tote. `ManageOrderService.customerOrderPicked` (line 328–346) sets `customerOrder.historytote = UUID.randomUUID().toString()` for any order where `OrderBatchType == CLUB`. This is what `cancelOrder`'s rapid-pick side-door keys on (see [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §7).
2. **`runClubLine` error-recovery reverts the batch state** via `rollbackClubLineState` (line 709) to `originalState`. This is the **only** revert pattern in the codebase. Don't generalize it to a reusable helper — the caller-specific context is what makes it safe.

The v1 equivalent is [wms1-club-order-processing.md](./wms1-club-order-processing.md); this doc is the v2 companion.

---

## 2. Entity Cast

| Entity | Role | State |
|---|---|---|
| `CustomerorderBatch` | Batch / wave — anchor entity | Integer `state` |
| `Customerorder` | Individual club order | Integer `state` |
| `CustomerorderPosition` | Order line | Integer `state` |
| `Pickingorder` | Work package per order | Integer `state` |
| `Unitload` | Parcel / pallet carrier | — |
| `Stockunit` | Stock on carriers | — |
| `Billoflading` | Outbound manifest | String `state` |

Batch state track (from [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §2.1):

```
RAW (0) → ORDER_BATCH_ACTIVATED (520)
       → ORDER_BATCH_STAGING_LANE_ASSIGNED (525)
       → ORDER_BATCH_CLUB_RUN_IN_PROGRESS (527)
       → ORDER_BATCH_CLUB_RUN_FINISHED (530)
       → FINISHED (700)   or   CANCELED (800)
```

---

## 3. Lifecycle

```
(orders arrive pre-grouped into a CustomerorderBatch of type CLUB)
         │
         ▼  REST: POST /v3/clubLine/activateBatch/{batchId}/{locationId}
         │        [ClubLineController:133]
         │      → CustomerorderBatchService.activateOrderBatch + assignStagingLaneToOrderBatch
         │
   CustomerorderBatch.state = ORDER_BATCH_ACTIVATED (520)
   CustomerorderBatch.state = ORDER_BATCH_STAGING_LANE_ASSIGNED (525)  [if lane assigned]
         │
         │  (optional: separate assignStagingLane / unlinkStagingLane REST calls)
         │
         ▼  REST: GET /v3/clubLine/runClubLine/{batchId}   [ClubLineController:160]
         │      → CustomerorderBatchService.runClubLine()    [line 743]
         │
  ┌──────┴───────────────────────────────────────────────────────────┐
  │  Phase 1: Validation + Lock                                      │
  │    pessimistic lock on CustomerorderBatch row                    │
  │    state guard: ACTIVATED or STAGING_LANE_ASSIGNED required      │
  │    [CustomerorderBatchService:606]                               │
  │    batch.state = ORDER_BATCH_CLUB_RUN_IN_PROGRESS (527)          │
  │                                                                   │
  │  Phase 2: Per-order processing                                   │
  │    for each Customerorder in batch:                              │
  │      ClubLineOrderProcessor.processOrder(...)                    │
  │        creates Pickingorder, tote unit load, stockunits          │
  │        OMS callbacks: releaseForPicking, pickingStarted, picked  │
  │        Customerorder.historytote = UUID (synthetic tote)         │
  │                                                                   │
  │  Phase 3: Finalize                                               │
  │    finalizeClubLine()  [line 689]                                │
  │    each Customerorder.state → PACKED                             │
  │    each CustomerorderPosition.state → PACKED                     │
  │    batch.state = ORDER_BATCH_CLUB_RUN_FINISHED (530)             │
  │                                                                   │
  │  Phase 4 (fire-and-forget)                                       │
  │    post-commit OMS callbacks                                     │
  └────────────────────────────────────────────────────────────────┘
         │
         │  ON EXCEPTION in Phase 2/3:
         │    rollbackClubLineState(batchId, originalState)   [line 709]
         │    reverts CustomerorderBatch.state to pre-run value
         │
         ▼  (downstream: BOL create → palletize → load → close)
         │   see wms2-bol-truck-loading-workflow.md
         │
         │   BOL close cascade (BillofladingService.closeBOL):
         │      Customerorder.state → FINISHED
         │      CustomerorderBatch.state → FINISHED (if all orders FINISHED)
         │      post-commit: WEBSERVICE_ORDER_BATCH_SHIPPED
         ▼
   Terminal: FINISHED (700)   or   CANCELED (800)
```

---

## 4. State Writers in `CustomerorderBatchService`

| Method | Line | Writes | Entities | OMS Callback | @Transactional |
|---|---|---|---|---|---|
| `activateOrderBatch(CustomerorderBatch)` | 421 | `ORDER_BATCH_ACTIVATED` (520) | batch | none | yes, `tenantTransactionManager`, `rollbackFor={BusinessException, FacadeException}` |
| `assignStagingLaneToOrderBatch(Location, CustomerorderBatch)` | 769 | `ORDER_BATCH_STAGING_LANE_ASSIGNED` (525) | batch, Location | none | yes |
| `runClubLine(CustomerorderBatch)` | 679 | `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` → `FINISHED` via `finalizeClubLine` | batch, Customerorder, CustomerorderPosition, Pickingorder, Stockunit, Unitload | RELEASED_FOR_PICKING, PICKING_STARTED, PICKING_FINISHED (via `ClubLineOrderProcessor` + `ManageOrderService`) | Multi-phase — Phases 1–3 transactional; Phase 4 fire-and-forget |
| `finalizeClubLine(Long batchId, List<Customerorder>)` | 632 | `ORDER_BATCH_CLUB_RUN_FINISHED` (530); orders → `PACKED` | batch, Customerorder, CustomerorderPosition | none (callbacks fire from `runClubLine` parent) | yes |
| `rollbackClubLineState(Long batchId, int originalState)` | 656 | reverts batch to `originalState` | batch only | none | yes, `rollbackFor = Exception.class` (broad — intentional) |
| `cancelBatch(CustomerorderBatch, Principal)` | 221 | `CANCELED` (800) | batch, Customerorder, CustomerorderPosition, Pickingorder, Unitload, Stockunit | `WEBSERVICE_ORDER_BATCH_CANCELLED` (line 265) | yes |
| `finalizeBatchIfComplete(Long)` | 346 | rolls batch to `FINISHED` or `CANCELED` depending on child state | batch, Customerorder | none | **NOT transactional** — rollup only |

---

## 5. REST Endpoints — `ClubLineController`

All under `/v3/clubLine/...`. Desktop-only; no mobile endpoints reference club runs.

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `/orderBatch/{orderBatchId}` | GET | 58 | Fetch batch details |
| `/assignStagingLane/{orderBatchId}/{locationId}` | GET | 83 | Assign staging lane |
| `/unlinkStagingLane/{orderBatchId}` | GET | 109 | Remove staging lane |
| `/activateBatch/{orderBatchId}/{locationId}` | GET | 133 | Assign lane + activate (combined) |
| `/runClubLine/{orderBatchId}` | GET | 160 | **Main** — execute the run (§3 Phase 1–4) |
| `/openClubRun` | GET | 191 | List open runs (paginated) |
| `/closedClubRun` | GET | 210 | List closed runs |
| `/activeClubRun` | GET | 229 | List in-progress runs |
| `/inactiveClubRun` | GET | 248 | List `ORDER_BATCH_ACTIVATED` runs |
| `/skus` | POST | 255 | SKU inventory overview for batch |
| `/unitLoads` | POST | 262 | Available unit loads for batch |
| `/parcels` | POST | 298 | Order / parcel detail list |
| `/availableStagingLanes` | GET | 306 | Staging lanes available for assignment |

Separate **transfer** endpoints for individual club-order relocations:

| Endpoint | Method | File:Line | Purpose |
|---|---|---|---|
| `/v3/transfers/transferOrder/{customerOrderId}` | GET | `TransfersController:69` | Transfer one club order (calls `BillofladingService.transferOrder()`) |
| `/v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` | GET | `TransfersController:92` | Transfer all orders in batch |

`transferOrder` is specifically for club-order movement to a transfer lane — it sets `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED` and nulls `staginglaneId` (`BillofladingService:748–751`).

---

## 6. Club-Specific Behaviour

### 6.1 Synthetic UUID tote

When `OrderBatchType.CLUB.equals(orderBatch.getType())`, `ManageOrderService.customerOrderPicked` (line 328–346):

```java
if (isClub) {
    String tote_label = UUID.randomUUID().toString();
    orderDto.setToteLabel(tote_label);
    customerOrder.setHistorytote(tote_label);
    clubOrdersToSave.add(customerOrder);
}
```

Why: in a club run, all orders have identical content, so the physical tote identity doesn't matter — the UUID serves only to populate the OMS payload. But `historytote != null` is exactly the flag that triggers the rapid-pick side-door in `CustomerorderService.handleRapidPickingForCancelledOrder`. See [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §7 and `Cancel_Order_Null_SectionId_And_Early_Return_Fix`.

### 6.2 OMS Callbacks in Club Flow

Most callbacks below fire post-commit via `TransactionSynchronizationManager.registerSynchronization` or `omsNotificationService.sendAfterCommit`. **As of SBDEV-2381 (2026-06-01)** the three picking-status callbacks (RELEASE / PICKING / FINISHED_PICKING) are no longer fired this way — they are enqueued in-tx per CO inside `finalizeClubLine` (see the SBDEV-2381 note below):

| Callback | Fired from | Line | When |
|---|---|---|---|
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `CustomerorderBatchService.finalizeClubLine` → `outboxService.enqueue` (SBDEV-2381; was `ManageOrderService.customerOrderReleaseForPicking`, now retired no-op shim) | — | Per-CO release, enqueued in-tx during finalize |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `ManageOrderService.customerOrderToteAssigned` | 223 | Tote assigned to order |
| `WEBSERVICE_ORDER_BATCH_PICKING` | `CustomerorderBatchService.finalizeClubLine` → `outboxService.enqueue` (SBDEV-2381; was `ManageOrderService.customerOrderPickingStarted`, now retired no-op shim) | — | Picking begins — fake UUID tote label set for club orders |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `CustomerorderBatchService.finalizeClubLine` → `outboxService.enqueue` (SBDEV-2381; was `ManageOrderService.customerOrderPicked`, now retired no-op shim) | — | Picking done — `historytote` populated |
| `WEBSERVICE_ORDER_BATCH_HELD` | `ManageOrderService.customerOrderOnHold` | 95 | Stock shortage / hold |
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `ManageOrderService.customerOrderPalletized` | 413 | After palletize (downstream BOL workflow) |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `ManageOrderService.customerOrderLoadedToTruck` | 474 | After truck load |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `BillofladingService.closeBOL` | 653 | On BOL close — terminal notification |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `CustomerorderBatchService.cancelBatch` | 265 | Batch cancel — **activation gated by `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` (default `false`)** |

Archived bug `Club_Order_Cancellation_OMS_Fix` was a post-commit ordering issue where a callback fired before the cancel actually persisted. The fix: never fire callbacks inside `@Transactional` — always via `registerSynchronization`.

> **SBDEV-2381 (2026-06-01):** The three Phase-4 fire-and-forget OMS picking-status notifications (RELEASE → PICKING_STARTED → PICKING_FINISHED) are **removed from `runClubLine` Phase 4**. They are now `outboxService.enqueue(...)` **per-CO, in-transaction, inside `finalizeClubLine`** with ascending outbox ids (RELEASE < STARTED < FINISHED) so the dispatcher delivers them in order. Because enqueue now joins the finalize tenant tx, a **failed enqueue rolls back finalize** (atomic transactional outbox) rather than being swallowed. `buildPickedPayloadJson` runs once per club CO (owns the tote-label `saveAll` + historytote UUID); STARTED/RELEASE use the no-side-effect payload builder. See `architecture/wms2-oms-integration-map.md` §2.1 for the dispatcher-side ordering gate and `event_version` field.

### 6.3 Error-Recovery Revert

`runClubLine` wraps its work in try-catch:

```
try {
    batch.state = ORDER_BATCH_CLUB_RUN_IN_PROGRESS    // commit in Phase 1
    processOrders(...)                                // Phase 2
    finalizeClubLine(...)                             // Phase 3
} catch (Exception e) {
    rollbackClubLineState(batchId, originalState)     // revert batch.state only
    throw ...
}
```

`rollbackClubLineState` at line 709 is declared `@Transactional(rollbackFor = Exception.class)` — the broad rollback is intentional. It runs as a **new transaction** (the enclosing one has already committed the `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` change) to write the revert. If the revert itself fails, the batch is stuck mid-run and requires admin intervention.

This is the only codebase location that "reverts" a state transition. Do not copy this pattern elsewhere without understanding Phase-1-commits-before-Phase-2 semantics.

---

## 7. Cancellation Paths

Club runs can be cancelled at three distinct points, each with different cascade shape:

| When | Method | Cascade |
|---|---|---|
| Before run started (`ORDER_BATCH_ACTIVATED` or `ORDER_BATCH_STAGING_LANE_ASSIGNED`) | `CustomerorderBatchService.cancelBatch:221` | Full cascade — batch + all orders + all pickingorders + all unitloads. Fires `WEBSERVICE_ORDER_BATCH_CANCELLED` (if activated). |
| During run (`ORDER_BATCH_CLUB_RUN_IN_PROGRESS`) | Same `cancelBatch` — same cascade; rolls back any in-progress picks | Relies on pessimistic batch lock — can't cancel while `runClubLine` holds the row lock |
| Post-run per-order cancel (single `CustomerorderService.cancelOrder`) | `CustomerorderService:300` | Single-order cascade; if `historytote != null` triggers rapid-pick side-door (§6.1) |

Key archived fixes: `Club_Order_Cancellation_Fix_Plan`, `Cancel_Club_Parcels_Packed_State_Fix` (the pack-guard regression), `RunClubLine_Cancelled_Order_Fix_Plan`.

See [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §5 for the full batch-cancel flow.

---

## 8. Transaction Boundaries

- Phase 1 of `runClubLine` (state to `ORDER_BATCH_CLUB_RUN_IN_PROGRESS`) commits **independently** so Phase 2's per-order processing can be observed by readers mid-run.
- Phase 2 per-order work (`ClubLineOrderProcessor.processOrder`) — per-order `@Transactional("tenantTransactionManager")`, typically with `REQUIRES_NEW` so one bad order doesn't abort the run.
- Phase 3 `finalizeClubLine` — single transaction. All orders move to `PACKED` atomically; batch to `ORDER_BATCH_CLUB_RUN_FINISHED`. **SBDEV-2381:** also performs up to 3 `outboxService.enqueue` (RELEASE/STARTED/FINISHED) per club CO inside this same tenant tx — a failed enqueue rolls the whole finalize back.
- Phase 4 callbacks — `PALLETIZED` / `LOADED_TO_TRUCK` remain post-commit fire-and-forget. The RELEASE/PICKING_STARTED/PICKING_FINISHED notifications are **no longer here** (SBDEV-2381 moved them into the Phase-3 finalize tx via the outbox).
- `cancelBatch` — single transaction. Entire cascade succeeds atomically or rolls back.
- `rollbackClubLineState` — new transaction (`rollbackFor = Exception.class`); runs after Phase 1 commit, before re-throwing.

See [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §7 for the overall `REQUIRES_NEW` inventory.

---

## 9. Known Landmines

1. **Phase 1 of `runClubLine` commits state to `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` before the rest runs.** If Phase 2 or 3 throws, `rollbackClubLineState` must revert in its own transaction. Any refactor that tries to wrap all 4 phases in one `@Transactional` will lose the "observable mid-run state" property — tools like the `/activeClubRun` endpoint depend on it.
2. **`historytote = UUID` drives the rapid-pick cancel side-door.** Removing the UUID write breaks club cancellation (order stays stuck in picking instead of returning to pool). See [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §7.
3. **`ORDER_BATCH_CLUB_RUN_FINISHED` is NOT terminal.** The batch eventually reaches `FINISHED` (700) via BOL close. Don't treat `CLUB_RUN_FINISHED` as a stop state.
4. **`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` defaults to `false`.** Tenants that want OMS cancel notifications must flip it explicitly. Otherwise cancels are silent to OMS.
5. **`finalizeBatchIfComplete` is NOT a cancel trigger.** It's a post-cancel rollup — don't invoke it directly to "force" batch cancel.
6. **No mobile path.** Club runs are desktop-only. Adding mobile support requires parallel mobile controllers + services; the `runClubLine` orchestration is currently web-UI-bound.
7. **The pack-guard regression pattern** (`Cancel_Club_Parcels_Packed_State_Fix`): guards at `CustomerorderService:382, 554` block normal cancel when orders are already `PACKED` or `PALLETIZED`. The force path (`forceCancelOrder`) bypasses this — but a plain `cancelOrder` on a club-run-finished order must get through the guard first.
8. **Auto-release to transfer lane** (active plan `Auto_Release_Club_Transfer_Lane_Fix`) — the `/v3/transfers/transferOrder/{id}` path writes `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED` and nulls `staginglaneId` on each transfer. Bulk-transfer-by-batch (`/transferOrderByOrderBatchId`) must iterate — there is no single-query bulk version.
9. **Pessimistic batch lock during `runClubLine`** prevents concurrent cancel. A cancel request on a running batch will block until the run completes or fails — admins may see "cancel hung" when they're actually waiting on the lock.
10. **`OrderBatchType` matters**. Only `CLUB`-typed batches go through the club flow. Non-CLUB batches follow a different path even through the same entry points. Check `orderBatch.getType()` before assuming club semantics.

---

## 10. How to debug

| Symptom | Start here |
|---|---|
| "Club run stuck in `ORDER_BATCH_CLUB_RUN_IN_PROGRESS`" | §6.3 — was an exception thrown mid-run? Check logs for `rollbackClubLineState` invocation |
| "Cancel hangs on a running batch" | §9 item 9 — pessimistic lock held by `runClubLine` |
| "OMS never got club-run notifications" | §6.2 + `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` + `message` table |
| "Club order cancel left Pickingorder in PROCESSABLE, not CANCELED" | §6.1 + [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §7 — expected behavior |
| "Can't cancel a club batch in PACKED state" | §9 item 7 — guard at `CustomerorderService:382`. Use `forceCancelOrder` |
| "Transfer lane reassignment silently changed batch state to CLUB_RUN_FINISHED" | §5 — `transferOrder` intentionally writes this state + nulls `staginglaneId` |
| "Batch FINISHED but one child order still LOADED_TO_TRUCK" | `finalizeBatchIfComplete` (§4 line 346) is called during BOL close — if BOL close partially committed, the rollup skipped. Verify `closeBOL` transaction committed fully |

---

## 11. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `CustomerorderBatchService` methods (activateOrderBatch, assignStagingLaneToOrderBatch, runClubLine, finalizeClubLine, rollbackClubLineState, cancelBatch, finalizeBatchIfComplete); `ClubLineController` all endpoints; `TransfersController` endpoints; `BillofladingService.transferOrder` + `closeBOL` batch-cascade; `ManageOrderService` club-specific UUID path; OMS callback wiring | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-06-01 | SBDEV-2381: Phase-4 fire-and-forget RELEASE/PICKING_STARTED/PICKING_FINISHED removed from `runClubLine`; now `outboxService.enqueue` per CO in-tx inside `finalizeClubLine` (ascending ids, failed enqueue rolls back finalize). `ManageOrderService.customerOrderReleaseForPicking/customerOrderPickingStarted/customerOrderPicked` retired to no-op shims. §6.2 table + §8 Phase-3/4 boundaries updated. | Confirmed against `CustomerorderBatchService.finalizeClubLine` / `runClubLine` and `ManageOrderService` shims (PR #35, commits 567fba3 + 41ad7d3) | Code read (grep-based) |

**Re-verify every 60 days.** Next due: **2026-07-31** — club-run area has multiple active and recently archived plans; high rate of change warrants more frequent re-verification than typical workflows.
