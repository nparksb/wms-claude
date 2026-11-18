---
title: "WMS v2 — Club Run / Club Order Processing Workflow"
type: workflow
status: active
version: v2
scope: club-run
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: code read of v2/wms2-api origin/develop @ df30fa62 (CustomerorderBatchService, ClubLineController, ClubLineOrderProcessor, ClubRunJob*, ManageOrderService, BillofladingService, TransfersController, WmsConstants)
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
**Owner:** Nam Park · **Last verified:** 2026-11-11

---

## 1. Overview

A **club run** is one execution of a recurring-delivery batch — typically wine-of-the-month — where many orders with identical content are processed as a single wave through staging → pick → pack → palletize → load → ship. Anchor entity: `CustomerorderBatch` (Integer state). The flow is orchestrated from the **desktop** web UI (no mobile path) via `/v3/clubLine/...` REST endpoints, and the heavy lifting lives in `CustomerorderBatchService.runClubLine` (`:1155`, inline path) or, with `WMS_CLUBLINE_ASYNC` on (default), in the durable club-run job of §8A, plus `ClubLineOrderProcessor.processOrder()` (`:99`).

Two load-bearing facts:

1. **Club orders use a synthetic UUID-based tote label**, not a physical tote. `ManageOrderService.buildPickedPayloadJson` (formerly `customerOrderPicked`, deleted SBDEV-3102 D2) sets `customerOrder.historytote = UUID.randomUUID().toString()` for any order where `OrderBatchType == CLUB`. `historytote != null` is one of the conditions of `cancelOrder`'s rapid-pick side-door (see [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §7). ⚠ That side-door additionally requires the client's section to be `RAPID_PICKING` and the first position's picking order to be `STARTED`, and `CustomerorderService`'s own comments call the arm dead estate-wide, so for a normal club order the UUID's live effect is the OMS payload (§6.1), not the cancel path.
2. **`runClubLine` (inline path) error-recovery reverts the batch state** via `rollbackClubLineState` (`:1121`) to `originalState`. ⚠ unverified 2026-11-11: "the **only** revert pattern in the codebase" was not re-surveyed. Don't generalize it to a reusable helper — the caller-specific context is what makes it safe. On the async path (§8A) `failJob` does this job instead.

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
         │        [ClubLineController:158 mapping]
         │      → requireNotYetActivated (refuses state ≥ 520, SBDEV-4038)
         │      → assignStagingLaneToOrderBatch  (state 525; refuses state ≥ 527; locks lane row, re-checks, saveAndFlush — SBDEV-4107 ✓ merged(SBDEV-4107: #665 fd712d7a, 2026-11-12))
         │      → activateOrderBatch             (state 520, last writer)
         │
   CustomerorderBatch.state = ORDER_BATCH_STAGING_LANE_ASSIGNED (525)  [by the lane step]
   CustomerorderBatch.state = ORDER_BATCH_ACTIVATED (520)              [final state after this call, lane stays set]
         │
         │  (optional: separate assignStagingLane / unlinkStagingLane REST calls)
         │
         ▼  REST: GET /v3/clubLine/runClubLine/{batchId}   [ClubLineController:187 mapping]
         │      → async ON (default): submit club_run_job + wait ≤ 45 s (§8A)
         │      → async OFF ('0'): CustomerorderBatchService.runClubLine()  [:1155, inline, below]
         │
  ┌──────┴───────────────────────────────────────────────────────────┐
  │  Phase 1: Validation + Lock                                      │
  │    pessimistic lock on CustomerorderBatch row                    │
  │    state guard: ACTIVATED or STAGING_LANE_ASSIGNED required      │
  │    [CustomerorderBatchService.validateClubLine :695]             │
  │    batch.state = ORDER_BATCH_CLUB_RUN_IN_PROGRESS (527)          │
  │    stock check on the staging lane                               │
  │    SIZE CAP: active-order count vs WMS_CLUBLINE_MAX_BATCH_SIZE   │
  │      → refuses the run; see §9.12                                │
  │                                                                   │
  │  Phase 2: Per-order processing                                   │
  │    for each Customerorder in batch:                              │
  │      ClubLineOrderProcessor.processOrder(...)                    │
  │        creates the package Unitload (parcel), transfers stock    │
  │        from the staging lane into it; reuses an already-built    │
  │        package on a re-run (idempotent). Creates NO Pickingorder │
  │        and sends NO OMS callback here (ClubLineOrderProcessor)   │
  │        Customerorder.historytote = UUID is set LATER, in         │
  │        finalizeClubLine via buildPickedPayloadJson (§6.1)        │
  │                                                                   │
  │  Phase 3: Finalize                                               │
  │    finalizeClubLine() [:876]                                     │
  │    each Customerorder.state → PACKED  (bulk update, :878)        │
  │    each CustomerorderPosition.state → PACKED (bulk, :879)        │
  │    batch.state = ORDER_BATCH_CLUB_RUN_FINISHED (530)  [:899]     │
  │    OMS RELEASED/STARTED/FINISHED enqueued to the outbox IN this  │
  │    tx (per order, or per chunk — §6.2a)                          │
  │                                                                   │
  │  (no Phase 4: runClubLine's Javadoc still says "Phase 4", but   │
  │   the code has none since SBDEV-2381 Fix E)                      │
  └────────────────────────────────────────────────────────────────┘
         │
         │  ON EXCEPTION in Phase 2/3:
         │    rollbackClubLineState(batchId, originalState)   [:1121]
         │    reverts CustomerorderBatch.state to pre-run value
         │
         ▼  (downstream: BOL create → palletize → load → close)
         │   see wms2-bol-truck-loading-workflow.md
         │
         │   BOL close cascade (BillofladingService.closeBOL :358):
         │      Customerorder.state → FINISHED                     [:605]
         │      CustomerorderBatch.state → FINISHED (bulk query: no order of the batch
         │        below FINISHED)                                   [:801-822]
         │      WEBSERVICE_ORDER_BATCH_SHIPPED enqueued to the outbox in the close tx
         │        (enqueueBolShippedNotification :848; chunked for REGULAR / HUB_AND_SPOKE)
         ▼
   Terminal: FINISHED (700)   or   CANCELED (800)
```

---

## 4. State Writers in `CustomerorderBatchService`

| Method | Line | Writes | Entities | OMS Callback | @Transactional |
|---|---|---|---|---|---|
| `requireNotYetActivated(CustomerorderBatch)` | 415 | writes nothing; refuses a batch already at state ≥ 520 (SBDEV-4038) | none | none | not annotated |
| `activateOrderBatch(CustomerorderBatch)` | 423 | `ORDER_BATCH_ACTIVATED` (520) | batch | none | **not annotated** (no `@Transactional` on the method; a caller's transaction, if any, applies) |
| `assignStagingLaneToOrderBatch(Location, CustomerorderBatch)` | 1246 | `ORDER_BATCH_STAGING_LANE_ASSIGNED` (525); refuses state ≥ 527, then (SBDEV-4107) **refuses a non-CLUB batch** ("not a club batch; only club batches take a staging lane"), then a batch with no active orders. **SBDEV-4107 ✓ merged(SBDEV-4107: #665 fd712d7a, 2026-11-12):** locks the lane row (`locationRepository.lockById`) before the availability query, so a request that waited on another assign sees its commit; writes with `saveAndFlush` and maps a `uq_customerorder_batch_open_staginglane` violation (partial unique index on open **CLUB** batches, `state < 530 AND type = 'CLUB'`, V2.2.51) to the same "staging lane is not available anymore" refusal | batch | none | yes, `tenantTransactionManager`, `rollbackFor={BusinessException, FacadeException}` |
| `validateClubLine(CustomerorderBatch)` / `validateClubLine(CustomerorderBatch, ClubRunLease)` | 695 / 818 | `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` (527); the lease overload also resumes a 527 recorded by the same job (§8A.3) | batch | none | yes, same attributes |
| `runClubLine(CustomerorderBatch)` | 1155 | drives Phases 1–3 via `self.*` proxy calls; **not `@Transactional` on purpose** (class comment `:1144-1152`) | batch, Customerorder, CustomerorderPosition, Unitload, Stockunit | none directly — the RELEASED/PICKING/FINISHED_PICKING outbox rows are written inside `finalizeClubLine` | no — each phase opens its own short tx. There is **no Phase 4** in the code |
| `finalizeClubLine(Long batchId, List<Customerorder>)` / `(…, ClubRunLease)` | 876 / 860 | `ORDER_BATCH_CLUB_RUN_FINISHED` (530) at `:899`; orders and positions → `PACKED` by bulk update (`:878-879`) | batch, Customerorder, CustomerorderPosition | yes — enqueues RELEASED → STARTED → FINISHED via `outboxService` in the same tx (§6.2) | yes |
| `rollbackClubLineState(Long batchId, int originalState)` | 1121 | reverts batch to `originalState`, **only if it is still at 527** | batch only | none | yes, `rollbackFor = Exception.class` — but the body catches and logs every exception, so a failed revert does not propagate |
| `finalizeBatchIfComplete(Long)` | 383 | rolls batch to `FINISHED` or `CANCELED` depending on child state (all orders ≥ FINISHED; `CANCELED` only if all are) | batch, Customerorder | none | **yes** (`@Transactional`, `:382`) — ⚠ the earlier "NOT transactional" claim was wrong. Not called by `closeBOL`, which finalizes batches with its own bulk query (`BillofladingService:801-822`) |

---

## 5. REST Endpoints — `ClubLineController`

All under `/v3/clubLine/...`, each `@RequiresFunction(WEB_UI_VIEW_CLUB_LINE)`. Desktop-only; `grep -rli clubline controller/mobile service/mobile` finds nothing (2026-11-11). The "Line" column is the mapping annotation's line in `ClubLineController.java` (the old anchors had drifted by 20-120 lines).

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `/orderBatch/{orderBatchId}` | GET | 80 | Fetch batch details |
| `/assignStagingLane/{orderBatchId}/{locationId}` | GET | 106 | Assign staging lane |
| `/unlinkStagingLane/{orderBatchId}` | GET | 133 | Remove staging lane |
| `/activateBatch/{orderBatchId}/{locationId}` | GET | 158 | `requireNotYetActivated` → assign lane (525) → activate (520); combined |
| `/runClubLine/{orderBatchId}` | GET | 187 | **Main** — execute the run (§3 Phase 1–4). ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06): with `WMS_CLUBLINE_ASYNC` on (default) it submits a job and waits up to 45 s (§8A.7); with `'0'` it runs inline as before |
| `/clubRunJobs/{orderBatchId}` | POST | 256 | ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06) submit an async run, `202 {jobId,state,batchid}` (§8A.7) |
| `/clubRunJobs/{jobId}` | GET | 274 | ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06) job status (§8A.7) |
| `/clubRunJobs/byBatch/{orderBatchId}` | GET | 287 | ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06) latest job of a batch (§8A.7) |
| `/openClubRun` | GET | 321 | List open runs (paginated) |
| `/closedClubRun` | GET | 335 | List closed runs |
| `/activeClubRun` | GET | 349 | List in-progress runs |
| `/inactiveClubRun` | GET | 363 | List `ORDER_BATCH_ACTIVATED` runs |
| `/skus` | POST | 371 | SKU inventory overview for batch |
| `/unitLoads` | POST | 380 (body flags validated, SBDEV-3328: `orderBatchId` / `onlyStagingLocation` required, a bad id is a 422) | Available unit loads for batch |
| `/parcels` | POST | 418 | Order / parcel detail list |
| `/availableStagingLanes` | GET | 428 | Staging lanes available for assignment |

Separate **transfer** endpoints for individual club-order relocations:

| Endpoint | Method | File:Line | Purpose |
|---|---|---|---|
| `/v3/transfers/transferOrder/{customerOrderId}` | GET | `TransfersController:77` | Transfer one club order (calls `BillofladingService.transferOrder()`) |
| `/v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` | GET | `TransfersController:103` | Transfer all orders in batch |

`transferOrder` is specifically for club-order movement to a transfer lane — it sets `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED` and nulls `staginglaneId` (`BillofladingService.transferOrder:910`, writes at `:1011-1012`). Since SBDEV-3311 it also enqueues the RELEASED and STARTED OMS notifications for the transfer order (deliberately **not** FINISHED_PICKING, see the comment at `:1026-1050`).

---

## 6. Club-Specific Behaviour

### 6.1 Synthetic UUID tote

When `OrderBatchType.CLUB.equals(orderBatch.getType())`, `ManageOrderService.buildPickedPayloadJson(List, ActorDto)` (`ManageOrderService.java:254`; formerly `customerOrderPicked`, deleted SBDEV-3102 D2):

```java
if (isClub) {
    String tote_label = String.valueOf(UUID.randomUUID());   // ManageOrderService:275
    orderDto.setToteLabel(tote_label);
    customerOrder.setHistorytote(tote_label);
    clubOrdersToSave.add(customerOrder);
}
```

Why: in a club run, all orders have identical content, so the physical tote identity doesn't matter — the UUID serves only to populate the OMS payload. `historytote != null` is also one of the conditions of the rapid-pick side-door **inside** `CustomerorderService.cancelOrder` (there is no `handleRapidPickingForCancelledOrder` method in `src/main`; the branch is at `CustomerorderService:984-1031`). ⚠ The side-door also needs a `RAPID_PICKING` section and a `STARTED` picking order, and is dead estate-wide per the code's own comments. See [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §7 and `Cancel_Order_Null_SectionId_And_Early_Return_Fix`.

### 6.2 OMS Callbacks in Club Flow

Four callbacks below (`HELD`, `PICKING_TOTE_ASSIGNED`, `PALLETIZED`, `LOADED_TO_TRUCK`) still fire post-commit through `omsNotificationService.sendAfterCommit` (`ManageOrderService:105, 187, 345, 385`). **As of SBDEV-2381 (2026-06-01)** the three picking-status callbacks (RELEASE / PICKING / FINISHED_PICKING) are enqueued in-tx inside `finalizeClubLine` through `outboxService`, and `WEBSERVICE_ORDER_BATCH_SHIPPED` and `…_CANCELLED` are likewise outbox rows written inside their transaction (see the SBDEV-2381 note below):

| Callback | Fired from | Line | When |
|---|---|---|---|
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `CustomerorderBatchService.finalizeClubLine` → `outboxService.enqueue` (SBDEV-2381; was `ManageOrderService.customerOrderReleaseForPicking`, retired to a no-op shim, deleted SBDEV-3102 D2) | — | Per-CO release, enqueued in-tx during finalize |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `ManageOrderService.customerOrderToteAssigned` | 148 (send at 187) | Tote assigned to order |
| `WEBSERVICE_ORDER_BATCH_PICKING` | `CustomerorderBatchService.finalizeClubLine` → `outboxService.enqueue` (SBDEV-2381; was `ManageOrderService.customerOrderPickingStarted`, retired to a no-op shim, deleted SBDEV-3102 D2) | — | Picking begins — no tote side-effect (`buildPickingStartedPayloadJson`) |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `CustomerorderBatchService.finalizeClubLine` → `outboxService.enqueue` (SBDEV-2381; was `ManageOrderService.customerOrderPicked`, retired to a no-op shim, deleted SBDEV-3102 D2) | — | Picking done — fake UUID tote label set for club orders and `historytote` populated, by `buildPickedPayloadJson` (§6.1) |
| `WEBSERVICE_ORDER_BATCH_HELD` | `ManageOrderService.customerOrderOnHold` | 61 (send at 105) | Stock shortage / hold |
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `ManageOrderService.customerOrderPalletized` | 311 (send at 345) | After palletize (downstream BOL workflow) |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `ManageOrderService.customerOrderLoadedToTruck` | 350 (send at 385) | After truck load |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `BillofladingService.closeBOL` (`:358`) → `enqueueBolShippedNotification` (`:848`, called at `:797`) — **outbox row inside the close tx**, not a post-commit send; for `REGULAR` and `HUB_AND_SPOKE` BOLs larger than the sysprop chunk size it is split into per-chunk rows on the CLUB lane (SBDEV-3672, `V2.2.40`) | 797 | On BOL close — terminal notification; skipped (with a metric) when the BOL has no positions |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `CustomerorderService.enqueueCancellationSignal` (`:839`, called from `cancelOrder` and, since SBDEV-3362, `forceCancelOrder`; one enqueue **per order**, `aggregate_type='CUSTOMER_ORDER'`, process type `ORDER_BATCH_CANCELLED_FROM_WMS`) | — | Cancel — ⚠ **no activation gate in v2**; the `…_ACTIVATED` sysprop was inert (SBDEV-3332) and is now deleted from code and data (SBDEV-3373, `V2.2.37`). ⚠ Was cited here as `CustomerorderBatchService.cancelBatch:265`; that method was deleted as unreachable dead code under **SBDEV-3354** (2026-09-14) and never emitted this callback in production. There is no batch-scoped enqueue. |

Archived bug `Club_Order_Cancellation_OMS_Fix` was a post-commit ordering issue where a callback fired before the cancel actually persisted. The original fix was `registerSynchronization`; the cancel path now uses the transactional outbox instead (`OutboxService.enqueue` is `Propagation.MANDATORY`, so the row commits or rolls back with the cancel). `CustomerorderService` no longer calls `registerSynchronization` or `sendAfterCommit`.

> **SBDEV-2381 (2026-06-01):** The three Phase-4 fire-and-forget OMS picking-status notifications (RELEASE → PICKING_STARTED → PICKING_FINISHED) are **removed from `runClubLine` Phase 4**. They are now `outboxService.enqueue(...)` **per-CO, in-transaction, inside `finalizeClubLine`** with ascending outbox ids (RELEASE < STARTED < FINISHED) so the dispatcher delivers them in order. Because enqueue now joins the finalize tenant tx, a **failed enqueue rolls back finalize** (atomic transactional outbox) rather than being swallowed. `buildPickedPayloadJson` runs once per club CO (owns the tote-label `saveAll` + historytote UUID); STARTED/RELEASE use the no-side-effect payload builder. See `architecture/wms2-oms-integration-map.md` §2.1 for the dispatcher-side ordering gate and `event_version` field.

### 6.2a Chunked picking notifications (SBDEV-3310) — **off everywhere; chunk size stays 1**

`finalizeClubLine` reads the per-tenant sysprop `WMS_CLUBLINE_OMS_CHUNK_SIZE` (`resolveClubLineOmsChunkSize`, `CustomerorderBatchService:661`) and picks the row shape (`:915-920`):

| Value | Shape | Idempotency keys |
|---|---|---|
| `1`, blank, non-numeric or `< 1` (the code default `DEFAULT_CLUB_LINE_OMS_CHUNK_SIZE` = 1, `WmsConstants.SYSTEM_PROPERTY_CLUBLINE_OMS_CHUNK_SIZE_DEFAULT_VALUE`; seeded `'1'` by `V2.2.29`) | one outbox row per order per status (`enqueueClubNotificationsPerOrder`), aggregate `CUSTOMER_ORDER/<coId>` | `CO-PICKING-RELEASED-<coId>`, `CO-PICKING-STARTED-<coId>`, `CO-PICKED-<coId>` |
| `2 … 300` (clamped at `CLUBLINE_OMS_CHUNK_SIZE_CEILING` = 300) | one row per chunk per status (`enqueueClubNotificationsChunked`, `:1048`), aggregate `CLUB_BATCH_CHUNK` on `LANE_CLUB` | `CO-PICKING-RELEASED-B<batchId>-C<i>`, `…STARTED…`, `CO-PICKED-B<batchId>-C<i>` |

**Decision: the PRD rollout of a larger value was dropped (2026-11-05); every tenant stays at 1** — `V2.2.48` rewrote the config-UI description to "Keep at 1 … larger chunks are not safe yet" and the `enqueueClubNotificationsChunked` javadoc records why (a chunk's OMS verdict is all-or-nothing; no recovery path for a terminal chunk; per-record verdict handling SBDEV-2736 Phase 2 is a prerequisite). Do **not** document or set a larger value as live. Do not change the value while any club batch is mid-finalize or queued for replay: the key namespaces differ, so the unique-key double-send guard stops working (same javadoc).

### 6.3 Error-Recovery Revert

`runClubLine` wraps its work in try-catch:

```
// Phase 1 (self.validateClubLine) runs BEFORE the try and commits 527
try {
    for each order: clubLineOrderProcessor.processOrder(...)   // Phase 2
    self.finalizeClubLine(...)                                  // Phase 3
} catch (Exception e) {
    rollbackClubLineState(batchId, originalState)     // revert batch.state only
    throw ...
}
```

`rollbackClubLineState` (`:1121`) is declared `@Transactional(rollbackFor = Exception.class)`. It is called through the `self` proxy from the non-transactional `runClubLine`, so it is its own transaction (Phase 1 had already committed the `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` change). It reverts only if the batch is still at 527, and its body catches and logs every exception, so **a failed revert is swallowed (ERROR log `Failed to rollback batch … state`) and the batch stays at 527**, requiring admin intervention. The inline path's own failure is rethrown afterwards. This is the inline path only; the async path (§8A) uses `failJob`.

⚠ unverified 2026-11-11: that this is the only codebase location that "reverts" a state transition (not re-surveyed). Do not copy this pattern elsewhere without understanding Phase-1-commits-before-Phase-2 semantics.

---

## 7. Cancellation Paths

Club runs can be cancelled at three distinct points, each with different cascade shape:

⚠ **CORRECTED 2026-09-14 (SBDEV-3354).** The first two rows of this table named
`CustomerorderBatchService.cancelBatch:221` as the before-run and during-run cancel path. **That method
had no route and no caller in any commit of this repository's history, and was deleted.** Every club cancel — before, during, or after a run —
goes through the per-order path. *Deriving method:*
`git grep -n "cancelBatch" origin/develop -- 'src/main/**/*.java'` returned only its own declaration at that date; re-run 2026-11-11 on `origin/develop` @ df30fa62: zero `src/main` hits. *Positive control (2026-09-14):* the same grep over `src/test` returned 54 occurrences across 4 classes (⚠ not re-run).

| When | Method | Cascade |
|---|---|---|
| Before run started (`ORDER_BATCH_ACTIVATED` or `ORDER_BATCH_STAGING_LANE_ASSIGNED`) | `OrderRestController.cancelPositions` → `CustomerorderService.cancelOrder` per order | **One transaction per order, not per batch** — a batch can end up partially cancelled. One `WEBSERVICE_ORDER_BATCH_CANCELLED` enqueue per order (unconditional — no activation gate). Batch row reaches `CANCELED` by rollup via `finalizeBatchIfComplete`. |
| During run (`ORDER_BATCH_CLUB_RUN_IN_PROGRESS`) | Same per-order path | ⚠ **CORRECTED ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06).** The batch row lock does NOT span the run. `CustomerorderService.clubRunCancellationBlockingState` reads the batch `findByIdForUpdate`, so a cancel waits only while a validate or finalize transaction holds that lock; it then sees state 527 and is **refused** with `"Cannot cancel order N while its club batch is in state: … Retry after the club run completes."` (`CustomerorderService.clubRunCancellationBlockingState:810`, `BusinessException` thrown at the top of `cancelOrder`; the same guard also refuses a pre-run (520/525) batch whose order already has a `parcelId`). Async run: the lock is taken in `validateClubLine(batch, lease)` and `finalizeClubLine`; the per-order transactions (`ClubRunStepService.processOrderFenced`) lock the **job** row via `renewLease`, not the batch. Legacy inline run (switch `'0'`): per §8 only Phase 1 and Phase 3 hold it |
| Post-run per-order cancel | `CustomerorderService.cancelOrder` | Single-order cascade. A PACKED/PALLETIZED club order is cancellable only when the batch is a CLUB batch (`isOmsPreQaPackedCancellationAllowed`) and goes through `forceCancelOrder`; a non-CLUB packed order is refused. The rapid-pick side-door (§6.1) only fires for a `RAPID_PICKING` section — not a normal club path |

Key archived fixes: `Club_Order_Cancellation_Fix_Plan`, `Cancel_Club_Parcels_Packed_State_Fix` (the pack-guard regression), `RunClubLine_Cancelled_Order_Fix_Plan`.

See [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §5 for the full batch-cancel flow.

---

## 8. Transaction Boundaries

- Phase 1 of `runClubLine` (state to `ORDER_BATCH_CLUB_RUN_IN_PROGRESS`) commits **independently** so Phase 2's per-order processing can be observed by readers mid-run.
- Phase 2 per-order work (`ClubLineOrderProcessor.processOrder`, `:98-99`) — per-order `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` with **default propagation** (no `REQUIRES_NEW` in that class). It is its own transaction only because `runClubLine` is non-transactional. A thrown order aborts the loop and goes to `rollbackClubLineState`; orders already committed stay committed (their packages are reused on a re-run).
- Phase 3 `finalizeClubLine` — single transaction. All orders move to `PACKED` atomically; batch to `ORDER_BATCH_CLUB_RUN_FINISHED`. **SBDEV-2381:** also performs up to 3 `outboxService.enqueue` (RELEASE/STARTED/FINISHED) per club CO (per chunk if `WMS_CLUBLINE_OMS_CHUNK_SIZE` > 1, §6.2a — not enabled anywhere) inside this same tenant tx — a failed enqueue rolls the whole finalize back.
- There is **no Phase 4** in `runClubLine`. `PALLETIZED` / `LOADED_TO_TRUCK` / `HELD` / `PICKING_TOTE_ASSIGNED` are sent by `ManageOrderService` from other flows via `sendAfterCommit` (§6.2); the RELEASE/PICKING_STARTED/PICKING_FINISHED notifications are in the Phase-3 finalize tx via the outbox (SBDEV-2381).
- **Batch cancel — one transaction PER ORDER, not one per batch.** `cancelPositions` loops `cancelOrder`; open-in-view is false so each order gets its own persistence context, and a failure on one order does not roll back its siblings. The old entry here claimed `cancelBatch` made the whole cascade atomic; that method was deleted under SBDEV-3354 (§7).
- `rollbackClubLineState` — its own transaction (`rollbackFor = Exception.class`, body swallows exceptions); runs after Phase 1 commit, before re-throwing. Inline path only.
- ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06) **With `WMS_CLUBLINE_ASYNC` on, none of the above describes the run.** The legacy bullets apply to the inline path (switch `'0'`). The async path is §8A: short fenced transactions, and `failJob` replaces `rollbackClubLineState`.

See [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §7 for the overall `REQUIRES_NEW` inventory.

---

## 8A. Async Club Run Job ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06)

Added by SBDEV-4007. With sysprop `WMS_CLUBLINE_ASYNC` on, a club run is a durable, resumable **job** instead of one inline request. Originally read from branch `feature/SBDEV-4007-club-run-async` @ `d70beaaf`; **now on `develop`** (merged 2026-11-06). Re-verified 2026-11-11 by diffing `d70beaaf..origin/develop@df30fa62` over `ClubRunJobService`, `ClubRunJobWorker`, `ClubRunJobClaimService`, `ClubRunJobRepository`, `ClubRunStepService`, `ClubRunExecutorConfig`, `ClubRunShutdownGuard`, `ClubRunJobPollerJob`, `ClubLineController` and `V2.2.47`, plus spot checks of the properties, switch semantics and metric names against `develop`. The only drift is SBDEV-4089 (run-as-requester, below) and SBDEV-3328 request validation; the numbered mechanics below were not otherwise re-read line by line. ⚠ unverified 2026-11-11: every SQL snippet and exact error string in §8A.5-§8A.8 was checked only through that diff, not re-executed.

### 8A.1 The switch `WMS_CLUBLINE_ASYNC`

- Seeded `'1'` by `V2.2.47__club_run_job.sql` (`WHERE NOT EXISTS (syskey, workstation='DEFAULT')`, so an existing row keeps its value). A missing or blank row resolves to the code default `'1'` (`ClubRunJobService.isAsyncEnabled`).
- **Only the exact value `'0'` disables.** Any other value, including `'false'`, leaves it ON.
- OFF means: no new jobs are submitted (`POST /clubRunJobs/{id}` answers `"Async club run is disabled for this warehouse (WMS_CLUBLINE_ASYNC=0)"`) and `GET /runClubLine` runs inline as in §3. **Live jobs always keep draining**, because the poller ignores the switch. While a live job exists, an inline `GET /runClubLine` is refused with `"Batch X has a club run job in progress; wait for it to finish before running inline"`.

### 8A.2 Row, claim, fence

`club_run_job` (one row per submitted run): `state`, `attempt`, `original_batch_state`, `total_orders`, `lease_owner`, `lease_expires_at`, `last_error`, `requested_by`, timestamps. A partial unique index `uq_club_run_job_live_batch` allows **one QUEUED/RUNNING job per batch**; `submit` uses `INSERT … ON CONFLICT … DO NOTHING RETURNING id`, so a second click attaches to the live job and returns it.

- **Claim**: `UPDATE club_run_job SET state='RUNNING', attempt=attempt+1, lease_expires_at=now()+lease … WHERE id=(SELECT id … WHERE state='QUEUED' OR (state='RUNNING' AND lease_expires_at < now()) ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)` (`ClubRunJobRepository.claimNext`). A job whose holder is mid-transaction holds the row lock from its fence and cannot be claimed.
- **Fence**: `attempt` is the fencing token. Every worker transaction begins with `renewLease` (`UPDATE … SET lease_expires_at=… WHERE id=:id AND attempt=:attempt AND state='RUNNING'`); 0 rows means a newer claimant owns the job, and the stale worker throws `ClubRunLeaseLostException` and stops without further writes (metric `lease_lost`).
- **Run-as-requester (SBDEV-4089, 2026-11-09):** a claimed job runs with a `SecurityContext` whose principal is the job's `requested_by` (`ClubRunJobWorker.runAsRequester`; no authorities), so stock and unit-load records written by the background run name the operator who submitted it instead of `anonymous`. A job with no requester runs unauthenticated, as before.
- **Lease**: `app.clubline.job.lease-seconds`, default **300 s**. A liveness knob, not a safety one: the safety is the fence.
- **Short transactions**: (1) `validateClubLine(batch, lease)`; (2) one `ClubRunStepService.processOrderFenced` per order; (3) `finalizeClubLine(…, lease)`, which also marks the job DONE **in the same transaction**, so a batch at 530 always has a DONE job. Each starts with the fenced `renewLease`.
- **`failJob`** is ONE transaction: `renewLease`, lock the batch, restore it from 527 to the job's `original_batch_state`, mark the job FAILED with `last_error`. It does not swallow errors; if it fails, the worker abandons instead (the job is never FAILED while the batch sits at 527 by this job's doing).

### 8A.3 States and lifecycle

| State | Meaning |
|---|---|
| `QUEUED` | submitted, not yet claimed |
| `RUNNING` | claimed (attempt >= 1); live while `lease_expires_at` is in the future |
| `DONE` | finalize committed (batch 530) |
| `FAILED` | terminal failure; `failJob` restored the batch (except the race in §8A.8) |
| `STUCK` | terminal escape: `failJob` itself kept failing; **batch is NOT touched** (§8A.6) |

- **Auto-resume**: a RUNNING job whose lease expired is claimed again (attempt+1). Validate then RESUMES a batch already at 527 **only if** this job recorded `original_batch_state`; a 527 left by a legacy inline run is never adopted (`CustomerorderBatchService.validateClubLine(batch, lease)` reads the column natively in its own transaction). Orders already packed are skipped through the existing package reuse.
- **Progress** is not stored: `processed = count(customerorder WHERE orderbatch_id=:b AND parcel_id IS NOT NULL AND state <> CANCELED)` (`countProcessedOrders`); `total` is `total_orders` (active orders at submit).
- **Max attempts** `app.clubline.job.max-attempts` = **2** (`ClubRunJobWorker.claimAndRun`): attempts 1 and 2 execute. A claim at attempt 3 or 4 does not execute; it calls `failJob` with `"abandoned after N attempts (max-attempts=2) …"`. If `failJob` keeps failing, the claim at attempt 5 (`> max-attempts + 2`) marks the job STUCK.
- **Abandon vs fail** (the job stays RUNNING on abandon; a later claim retries):
  - ABANDON when the shutdown flag is set, the thread is interrupted, or **anywhere in the cause chain** is a `TransientDataAccessException`, `DataAccessResourceFailureException`, `CannotCreateTransactionException`, or a JDBC SQLState `08*`. Note `OptimisticLockingFailureException` is a `TransientDataAccessException`, so it abandons. **Unless the top-level exception is a `BusinessException` or `FacadeException`, which always fails** (`!business && isTransient(e)`), even when it wraps a transient cause.
  - FAIL (`failJob`) for everything else: any `BusinessException`/`FacadeException` (its message becomes `last_error`) or any other exception.
- **Lease on abandon**: only shutdown and transient abandons write `lease_expires_at = now()`, so the next poller tick (`*/4`) reclaims immediately. A bare interrupt keeps the lease, and so does the abandon after a failed `failJob` (`abandon(lease, ABANDON_FAILJOB_FAILED, false)`): each such retry waits out the lease, up to 300 s.
- **Time to STUCK**: `failJob` can first fail at attempt 1 or 2 (any claim that executes can fail and call it). Each failed `failJob` keeps the lease, so attempts 3, 4 and 5 each arrive up to 300 s after the previous one: STUCK comes about 15 min after a first `failJob` failure at attempt 2 (about 20 min from attempt 1).
- **Deploys consume attempts.** Each resume increments `attempt`, including after a clean shutdown (`ClubRunShutdownGuard` raises the flag; the worker sees it at the next order boundary and abandons with the lease expired now). Two quick transient faults, or a deploy plus one fault, therefore exhaust max-attempts and the next claim fails the job even though no order was ever bad. The log line `club run RESUMED at attempt=N` (metric `resumed`, attempt >= 2) marks each one.

### 8A.4 Sizing

`app.clubline.job.workers` = **2 per JVM**, shared by **all tenants** on that replica (`ClubRunExecutorConfig`: core = max = workers, queue 0, discard-and-count when saturated). One tenant's backlog can delay another tenant's job. Accepted and documented (security finding S6); a per-tenant cap would be a design change. Each worker holds at most one tenant connection at a time. Poller details: [wms2-scheduled-jobs-catalog](../architecture/wms2-scheduled-jobs-catalog.md) §4.9.

### 8A.5 Telling a live run from an orphan

State 527 on the batch no longer answers it. Read the job:

```sql
-- the latest job of a batch (batchid = the business id, e.g. the one on the screen)
SELECT j.id, j.state, j.attempt, j.original_batch_state, j.total_orders, j.lease_owner,
       j.lease_expires_at, (j.lease_expires_at > now()) AS lease_live, j.last_error,
       j.created_at, j.started_at, j.finished_at, b.state AS batch_state
FROM club_run_job j JOIN customerorder_batch b ON b.id = j.orderbatch_id
WHERE b.batchid = :batchid ORDER BY j.id DESC LIMIT 5;
```

RUNNING with `lease_live` true: a worker is alive, wait. RUNNING with an expired lease: an orphan; the poller reclaims it on its next tick (within about 4 s). Do not touch the batch.

### 8A.6 STUCK: manual reconcile (operators)

Alert: `wms2.clubrun.job.stuck` increments and the worker logs `club run job=J batch=B attempt=N is STUCK` at ERROR. **What STUCK means:** `failJob` threw on every claim that reached it, through attempt 4 (see the earlier ERROR lines `failJob failed; abandoning so a later claim retries`, which carry the real exception). `markStuck` deliberately writes **nothing to the batch**, so the batch is still at **527** (or wherever it was), and `last_error` reads `STUCK after N attempts: failJob kept failing; batch B left at its current state for manual reconcile (original state S)`. **`original_batch_state` holds the batch's state before this job moved it to 527** (ACTIVATED or STAGING_LANE_ASSIGNED), or NULL if validate never recorded it.

1. Find the cause in the server log. `last_error` is sanitized and no longer carries the original failure, so `grep 'job=<J>'` (the job id) for the full exception. Abandons log at WARN, terminal failures at ERROR; the first ERROR with a stack trace is why `failJob` failed.
2. Inspect:
```sql
SELECT id, state, attempt, original_batch_state, last_error, finished_at FROM club_run_job WHERE id = :jobid;
SELECT id, batchid, state FROM customerorder_batch WHERE id = (SELECT orderbatch_id FROM club_run_job WHERE id = :jobid);
SELECT count(*) FILTER (WHERE parcel_id IS NOT NULL) AS packed, count(*) AS total
  FROM customerorder WHERE orderbatch_id = (SELECT orderbatch_id FROM club_run_job WHERE id = :jobid) AND state <> 800;  -- 800 = WmsConstants.State.CANCELED
```
3. **Batch state is 530**: cannot happen, because finalize marks the job DONE in the same transaction. If you see it, stop and escalate.
4. **Batch still 527 and `original_batch_state` is NOT NULL**: restore it, in one transaction, after the cause in step 1 is fixed. Packages already built are kept and reused by the next run.
```sql
BEGIN;
UPDATE customerorder_batch
   SET state = :original_batch_state, version = version + 1, modified = now()
 WHERE id = :batch_pk AND state = 527;      -- expect 1 row; version bump keeps the @Version optimistic lock honest
COMMIT;
```
   Then click Run Club again (a STUCK job is terminal, so a new job is accepted).
5. **Batch at 527 and `original_batch_state` IS NULL**: this job never moved the batch; the 527 belongs to another run (e.g. a legacy inline run). Do not restore blindly; find the owner first.
6. Leave the STUCK row as the audit trail. Never delete it while the job's `last_error` (`club_run_job`) is still needed. The screen shows STUCK until the next submit.

### 8A.7 Endpoints (all `@RequiresFunction(WEB_UI_VIEW_CLUB_LINE)`, base `/v3/clubLine`)

| Endpoint | Behaviour |
|---|---|
| `POST /clubRunJobs/{batchid}` | `202 {jobId, state, batchid}`; an existing live job returns the same body. Errors keep the screen's `200 {"errors":[…]}` shape. Pre-checks: batch exists, switch on, batch ACTIVATED or STAGING_LANE_ASSIGNED, active orders <= `WMS_CLUBLINE_MAX_BATCH_SIZE` |
| `GET /clubRunJobs/{jobId}` | `ClubRunJobStatusDto {jobId, batchid, state, processed, total, lastError, batchState, attempt, startedAt, finishedAt}` |
| `GET /clubRunJobs/byBatch/{batchid}` | the latest job, or `errors[]` `"No club run job for batch: …"` |
| `GET /runClubLine/{batch}` (legacy) | switch ON: submit, then wait up to `app.clubline.sync-wait-seconds` (**45 s**, under the >= 58 s ingress read timeout). DONE: the usual `"RUN CLUBLINE"` success. Still QUEUED/RUNNING at 45 s: `200 {field, message:"RUN CLUBLINE QUEUED"` or `"RUN CLUBLINE RUNNING", jobId, state}`. FAILED/STUCK: `errors[]` carrying `last_error`. An unexpected runtime error: `errors[]` `"Club run status unavailable (job N); see server log"`, never a 500. Switch OFF: inline run as §3 |

The pre-P2 web UI (`store/processes/clubRuns.js` at wms2-web-ui `8eb11fe`) treats any message other than `"RUN CLUBLINE"` as unrecognised and reconciles from the batch state, so the QUEUED/RUNNING answer was safe for it. After P2 the UI no longer calls this GET except as the kill-switch fallback; see §8A.9.

### 8A.8 Client-visible errors, access, metrics

- `last_error` is returned to clients (status endpoint, legacy GET), so it carries **only client-safe text**: a Business/Facade message, or fixed strings (`"Club run failed (job N); see server log"`, `"abandoned: server shutting down; will resume on another replica"`, `"abandoned: worker interrupted; will resume"`, `"abandoned: transient database error; will resume"`, `"abandoned: recording the failure failed; will retry"`). The full exception is in the **server log**: WARN for an abandon (the run resumes), ERROR for a terminal failure.
- Job ids come from `seqentities` and are sequential. Anyone holding `WEB_UI_VIEW_CLUB_LINE` can read any job in the same tenant. Accepted (S5): the screen already lists every batch, and the sensitive text was removed from `last_error`.
- **FAILED job next to a 527 batch** happens in one case only: `last_error` ends `"; batch at 527 owned by another run"`. `failJob` found the batch at 527 but the job has no `original_batch_state`, so it left the batch alone. This is the kill-switch race: a legacy inline run (switch flipped to `'0'`) holds the 527. Only a narrow check-then-act window allows it, between the controller's `hasLiveJob` check and the inline validate; a live job otherwise makes the inline GET refuse. Any other FAILED job has restored its batch.
- **Metrics** (Micrometer; no tags): `wms2.clubrun.job.submitted`, `.completed`, `.failed`, `.resumed`, `.lease_lost`, `.abandoned`, `.stuck` (alert on this), `.kick_rejected` (submit's executor kick dropped: pool full; the poller claims the row), `.kick_failed` (kick threw something other than a rejection: a bug; the poller still claims), `.poller_discarded` (a poller task dropped by a saturated pool), and the timer `.run`. The poller also emits `wms2.cron.club_run_job_poller.*` through `JobMetrics`.
- Properties: `app.clubline.job.workers` (2), `.lease-seconds` (300), `.max-attempts` (2), `app.clubline.sync-wait-seconds` (45), `app.cron.club-run-job` (`*/4 * * * * *`).

### 8A.9 Web UI (P2, wms2-web-ui) ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06)

⚠ unverified 2026-11-11: this subsection describes the `wms2-web-ui` repo, which is outside the code of record (the wms2-api `develop` worktree) for this re-verification; it was not re-read. The "not merged" wording below predates the 2026-11-06 merge.

Read from wms2-web-ui branch `SBDEV-4007` @ `3e11d3b` (`git diff 8eb11fe..3e11d3b`); not merged. It needs the wms2-api endpoints of §8A.7 and ships in the same release cut. Files: `store/processes/clubRuns.js`, `components/processes/clubRuns/itemsTable.vue`, `plugins/persistedState.client.js`.

- **Submit.** `runClubLine` now does `this.$axios.$post('/clubLine/clubRunJobs/' + batchid)` and accepts only a job body (`isClubRunJob`: integer `jobId > 0`, a known state, this `batchid`). A 202 means **accepted, not finished**: the record is stored (`setClubRunJob`) and `pollClubRunJob` starts. The "Club line run completed" toast and the list refresh now belong to the DONE poll.
- **Poll cadence.** `GET /clubLine/clubRunJobs/{jobId}` every `POLL_FAST_MS = 2000`, then `POLL_SLOW_MS = 10000` once the poller has run `POLL_BACKOFF_AFTER_MS = 60000`. The timer chain is re-armed when each timer fires; a fire while the previous request is still in flight is skipped (`if (poller.inFlight) return`), so requests never overlap. Each poll GET carries `{ timeout: POLL_TIMEOUT_MS }` = 15000, so a hung request becomes one strike. One poller per batch; a second dispatch for the same job is a no-op. A reload restarts the 60 s of fast polling.
- **Progress text** (`itemsTable.vue` `readinessMessage`): RUNNING shows `Running: {processed} / {total} orders`; QUEUED shows `Queued: the club run will start as soon as a worker is free.`; STUCK shows the fixed sentence `CLUB_RUN_STUCK_MESSAGE`; a FAILED job shows its sanitized `lastError`. The visible line carries per-poll progress; the screen-reader live region is a separate `<span class="d-sr-only" role="status">` (`liveStatusMessage`) that says only `The club run is running.` while RUNNING, otherwise the readiness sentence, so a screen reader is not re-read the progress every 2 s.
- **Terminal states.**
  - DONE: stop, clear unconfirmed flag, set the row to `Club Run Finished`, success toast, `searchClubRuns`. If only that refresh fails the toast says the run completed and **not** to re-run.
  - FAILED: stop, toast `clubRunJobFailureMessage(lastError)`, reconcile the batch state. Run Club stays enabled so the operator can fix the cause and re-run.
  - STUCK: stop, toast `CLUB_RUN_STUCK_MESSAGE` ("Do not re-run it, ask an administrator to reconcile the batch"), reconcile. The administrator uses §8A.6.
- **Give-up.** `POLL_MAX_STRIKES = 3` consecutive transport errors or malformed bodies, **or** an errors-shape answer ("job not found", never recovers, no waiting for strikes) end the poller. `reactToUnknownOutcome` first marks the record `UNKNOWN` (not live, so Run Club is not locked), then reads the batch state: 530..799 success toast; 527 "still running"; null "could not be confirmed" and the unconfirmed flag; anything else (520/525) "The club run could not be followed, and the batch is not running now. Refresh the club details before running it again." The **Check run status** button re-reads the job through byBatch, which re-follows a still-live job or replaces the stale record.
- **Resume and stop.** On mount, and when `clubRunDetails.batchid` changes, `resumeClubRunPolling` calls `GET /clubLine/clubRunJobs/byBatch/{batchid}`: a live job is stored and polled, a terminal one is stored (so a FAILED reason shows) but not polled, anything else commits nothing. `beforeDestroy` and a batch change dispatch `stopClubRunPolling`. A **stop-generation** counter per batch is captured before a submit or byBatch request and compared when it answers, so a panel destroyed mid-request starts no orphan poller and commits no record. The counter map is never pruned (one integer per batch stopped in the tab, so a stale start cannot match a reset value). No ref count: one consumer; two browser tabs are two stores, each polls and each toasts the terminal state once.
- **Not persisted.** `plugins/persistedState.client.js` strips `processes.clubRuns.clubRunJobs` (`withoutClubRunJobs`) and calls `processes/clubRuns/resetClubRunJobs` at boot to drop it from older blobs. A persisted RUNNING record would lock the panel until byBatch answers, forever if it fails.
- **Running state.** `isClubRunning` is true for batch 527, **or a QUEUED/RUNNING job** (a queued job has not moved the batch off 520/525 yet), or a pending submit.
- **Kill-switch fallback.** If the submit is refused (200 `errors[]`) with a message starting `Async club run is disabled for this warehouse (` (P1's `ClubRunJobService.KILL_SWITCH_MESSAGE`), the store runs `runClubLineLegacy`: the pre-P2 synchronous `GET /clubLine/runClubLine/{batchid}` with its original handling (a failure after a completed run is tagged `legacyCompleted`: "do NOT re-run"). Any other refusal goes through the normal sanitized-reason path. This is the per-tenant rollback, not a feature-off switch. Any failed submit (a refusal, a transport error, a malformed body or a 5xx) clears the batch's previous FAILED record, so two reasons are never shown together. The one exception is a legacy run that completed (`legacyCompleted`), which does not clear it.
- **Withheld P1 texts.** `INTERNAL_REASON_PATTERNS` withholds P1 log pointers behind the generic "did not complete" sentence: `/'club run claimed job=\d+' log lines/` (the poison guard's "abandoned after N attempts … 'club run claimed job=J' log lines") and `/;\s*see server log\b/` ("Club run failed (job N); see server log" and the controller's "…; see server log" texts), with or without P1's `; batch at 527 owned by another run` suffix. "abandoned: …" texts are already withheld by the bare-key rule. An errors-shape poll answer is never relayed at all. A business reason that merely mentions "log lines" is still relayed.
- **Cypress.** `cypress/e2e/wms/club/club-line-order.cy.js` D.1 now POSTs `/clubLine/clubRunJobs/{batchLabel}`, expects 202 with a numeric `jobId`, then polls to DONE. **Rewritten, not run locally**, and it assumes `WMS_CLUBLINE_ASYNC='1'` on the target tenant; with `'0'` the API-level test fails (the UI does not).

---

## 9. Known Landmines

1. **Phase 1 of `runClubLine` (inline path) commits state to `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` before the rest runs.** If Phase 2 or 3 throws, `rollbackClubLineState` must revert in its own transaction. Any refactor that tries to wrap all 4 phases in one `@Transactional` will lose the "observable mid-run state" property — tools like the `/activeClubRun` endpoint depend on it.
2. **`historytote = UUID` is one condition of the rapid-pick cancel side-door** — ⚠ **corrected 2026-11-11:** the side-door also requires a `RAPID_PICKING` client section and a `STARTED` picking order, and the code calls it dead estate-wide, so the old claim "removing the UUID write breaks club cancellation" is not supported by the current code. Keep the UUID anyway: `buildPickedPayloadJson` also sends it to OMS as the tote label. See [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §7.
3. **`ORDER_BATCH_CLUB_RUN_FINISHED` is NOT terminal.** The batch eventually reaches `FINISHED` (700) via BOL close. Don't treat `CLUB_RUN_FINISHED` as a stop state.
4. **~~`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` defaults to `false`~~ — WITHDRAWN 2026-09-15 (SBDEV-3332).** ⚠ **This sysprop gated NOTHING in v2** (verified 2026-09-15, SBDEV-3332) and, as of 2026-11-11, **no longer exists in code**: `git grep WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED -- src/main` finds only the `V2.2.37` migration that deletes the row (SBDEV-3373); the `WmsConstants` constant is gone. No code reads it. v2 enqueues `ORDER_BATCH_CANCELLED_FROM_WMS` **unconditionally**. Cancels are NOT silent by default, and flipping this to `true` changes nothing. (Corrected 2026-10-06, SBDEV-3373: v1 does **not** read it either — v1 `origin/develop`, verified 2026-10-06 (SBDEV-3373): declaration in `WmsConstants` plus a commented-out seed line in `UtilRestController`, no reader. The row is deleted by `V2.2.37`.)
5. **`finalizeBatchIfComplete` is NOT a cancel trigger.** It's a post-cancel rollup — don't invoke it directly to "force" batch cancel.
6. **No mobile path.** Club runs are desktop-only. Adding mobile support requires parallel mobile controllers + services; the `runClubLine` orchestration is currently web-UI-bound.
7. **The pack-guard regression pattern** (`Cancel_Club_Parcels_Packed_State_Fix`): the `isPackedOrPalletized` guard in `CustomerorderService.cancelOrder` (`:928`) blocks normal cancel when orders are already `PACKED` or `PALLETIZED`. For a CLUB-batch order `cancelOrder` itself then delegates to `forceCancelOrder` (`isOmsPreQaPackedCancellationAllowed`); for a non-CLUB order it throws. `forceCancelOrder` is package-private — there is no way to call it around the guard.
8. **Auto-release to transfer lane** (archived plan `Auto_Release_Club_Transfer_Lane_Fix`, `4-Archieves/wms2/plan/260320-…`) — the `/v3/transfers/transferOrder/{id}` path writes `CustomerorderBatch.state = ORDER_BATCH_CLUB_RUN_FINISHED` and nulls `staginglaneId` on each transfer. Bulk-transfer-by-batch (`/transferOrderByOrderBatchId`) must iterate — there is no single-query bulk version.
9. **Pessimistic batch lock during `runClubLine`** — ⚠ **CORRECTED ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06): it does not span the run.** A cancel on a running batch takes the batch lock only after any in-flight validate/finalize transaction commits, then is **refused** (not queued) while the batch is at 527 (§7 row 2). "Cancel hung" therefore means a validate or finalize transaction is slow (a large batch's finalize does ~3,885 rows, §9.13), not that the whole run is holding the lock. After a refusal the admin must retry once the job is DONE or FAILED (§8A).
10. **`OrderBatchType` matters**. Only `CLUB`-typed batches go through the club flow. Non-CLUB batches follow a different path even through the same entry points. Check `orderBatch.getType()` before assuming club semantics.
11. **⚠ `ClubLineSkuDto.amountAvailable` GATES the "Run Club Line" button — it is not a display value.** `CustomerorderBatchService.getClubLineSKUOverview` (`:1594`) fills it from `StockunitRepository.getAmountAvailable(staginglaneId, itemdataId)`, a **single-location** query, and `clubRuns/itemsTable.vue`'s `disableRun` computed blocks the button while **any** line has `amountAvailable < amountRequired`. ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06) `disableRun` also blocks while `isClubRunning`, which P2 widened to include a QUEUED/RUNNING job (§8A.9); the stock gate itself is unchanged, and a FAILED job does not disable the button. **Repointing it at a warehouse-wide figure enables the run against an EMPTY lane.** ⚠ Its `else` arm is also load-bearing: leaving `amountAvailable` null makes `null < required` **false** in JavaScript, so `disableRun` returns false and the button enables — the same regression by a side door. SBDEV-2951 therefore added a **separate additive** `amountOnHand` field and an "On hand" column, kept the `Total at Lane` header, and left every gate untouched. This flow shares that DTO and both SKU-overview shapes with the transfer flow, so **a change to one must be made to both** — they have drifted before (the club copy carried a dead `amount != 0` branch the transfer copy lacked, collapsed by SBDEV-2951). See [wms2-transfer-order-workflow.md](./wms2-transfer-order-workflow.md) §10 item 12 and plan `SBDEV-2951-transfer-club-available-counts-lane-only`.

12. **⚠ A club run is refused above `WMS_CLUBLINE_MAX_BATCH_SIZE` active orders, and the cap has ONE surface — the sysprop.** Checked in `validateClubLine` (grep `"exceeds maximum allowed ("`), *after* the pessimistic lock and the staging-lane stock check, so an over-cap run still takes the lock and runs the O(n) stock validation before rejecting. Seeded at **5000** by `V2.2.27` (SBDEV-3304); a tenant with no row falls back to `CustomerorderBatchService.DEFAULT_MAX_CLUB_LINE_BATCH_SIZE`, which reads the same constant, so seeded and unseeded resolve identically. Non-numeric, blank or `< 1` falls back and logs — a `0` row would otherwise reject **every** club run in that tenant, including single-order ones — and a value above `CLUBLINE_MAX_BATCH_SIZE_CEILING` (10 000) clamps, as a typo guard rather than a throughput statement.

    **The history is the landmine.** Until SBDEV-3304 the cap came from a Spring property `wms.clubline.max-batch-size`, whose **env-var spelling is byte-identical to the sysprop key**. It was set in no properties file, so it configured nothing, while an operator who set "it" could not tell which of the two they had set — and the two behave completely differently (the sysprop is per tenant and effective on the next run; the property was process-wide, because wms2-api is deployed once per *environment*, not once per warehouse). **That property has been deleted.** If you are debugging "I raised the limit and nothing changed", establish which surface was touched — and do not reintroduce a property here.

13. **⚠ Raising the cap does not make a large club run finish inside the request.** `runClubLine` is a synchronous `GET` with a one-transaction-per-order Phase 2, and `finalizeClubLine` does 3 outbox enqueues **plus** a tote `saveAll` per order inside a single transaction (~3,885 rows for a 1295-order batch). The only measurement available is from **v1** — every club batch on every reachable tenant predates its tenant's own `V2.2.00` baseline, so **the v2 club path has never been observed running at any size**. On that v1 run (441 orders) per-order cost grew **9.1× within the single run**, i.e. quadratic, extrapolating to **45–70 minutes** for 1295 orders. ⚠ **Status update 2026-11-11:** SBDEV-3310 shipped the OMS-notification chunking behind `WMS_CLUBLINE_OMS_CHUNK_SIZE` (§6.2a) but its rollout was dropped and the value stays at 1 everywhere; chunking addresses OMS drain time, not this synchronous-request cost. The request-length problem itself was addressed on a different axis by the async club-run job (SBDEV-4007, §8A: the legacy GET now waits at most `app.clubline.sync-wait-seconds` = 45 s). ⚠ unverified 2026-11-11: the v1-derived 9.1× / 45-70 min extrapolation was not re-measured; no v2 club run at scale has been observed in this pass.

---

## 10. How to debug

| Symptom | Start here |
|---|---|
| "Club run stuck in `ORDER_BATCH_CLUB_RUN_IN_PROGRESS`" | §6.3 — was an exception thrown mid-run? Check logs for `rollbackClubLineState` invocation. ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06): state 527 alone no longer tells a live run from an orphan — read the job row (§8A.5); the lease is the authority. Job in `STUCK` → §8A.6 |
| "Cancel hangs on a running batch" | §9 item 9 — pessimistic lock held by `runClubLine` |
| "OMS never got club-run notifications" | §6.2 + `outbox_message` + `message` table. ⚠ Not `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED`: it gates nothing (see §9 item 4) |
| "Club order cancel left Pickingorder in PROCESSABLE, not CANCELED" | [wms2-cancel-cascade-workflow.md](./wms2-cancel-cascade-workflow.md) §7 — that is the rapid-pick side-door, which needs a `RAPID_PICKING` section; ⚠ not expected for a normal club order — check the client's section first |
| "Can't cancel a club batch in PACKED state" | §9 item 7 — `isPackedOrPalletized` guard at `CustomerorderService:928`; a CLUB-batch order is delegated to `forceCancelOrder` automatically, a non-CLUB one is refused |
| "Transfer lane reassignment silently changed batch state to CLUB_RUN_FINISHED" | §5 — `transferOrder` intentionally writes this state + nulls `staginglaneId` |
| "Batch FINISHED but one child order still LOADED_TO_TRUCK" | `closeBOL` finalizes batches with its own bulk query (`BillofladingService:801-822`, only batches whose orders are all ≥ FINISHED), **not** `finalizeBatchIfComplete` (the earlier row said otherwise). If the close did not fully commit the rollup skipped. Verify the `closeBOL` transaction committed fully |

---

## 11. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `CustomerorderBatchService` methods (activateOrderBatch, assignStagingLaneToOrderBatch, runClubLine, finalizeClubLine, rollbackClubLineState, cancelBatch, finalizeBatchIfComplete); `ClubLineController` all endpoints; `TransfersController` endpoints; `BillofladingService.transferOrder` + `closeBOL` batch-cascade; `ManageOrderService` club-specific UUID path; OMS callback wiring | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-06-01 | SBDEV-2381: Phase-4 fire-and-forget RELEASE/PICKING_STARTED/PICKING_FINISHED removed from `runClubLine`; now `outboxService.enqueue` per CO in-tx inside `finalizeClubLine` (ascending ids, failed enqueue rolls back finalize). `ManageOrderService.customerOrderReleaseForPicking/customerOrderPickingStarted/customerOrderPicked` retired to no-op shims. §6.2 table + §8 Phase-3/4 boundaries updated. | Confirmed against `CustomerorderBatchService.finalizeClubLine` / `runClubLine` and `ManageOrderService` shims (PR #35, commits 567fba3 + 41ad7d3) | Code read (grep-based) |

| 2026-09-10 | **SBDEV-3304 — club-line size cap.** Added the Phase-1 size-cap step (§3), landmines §9.12 (the cap and its single surface) and §9.13 (why raising it does not shorten a run). Replaced two stale line citations — the doc pointed at `CustomerorderBatchService:606` and `:689`, which are now a blank line and `return sb.toString();` respectively — with method names, which relocate themselves. **Scope note: this was NOT a full re-verification of the document**, so `last_verified` is deliberately left at 2026-06-01 and the doc remains overdue. Only the cap path was read. | §3, §9 updated; the rest unverified since 2026-06-01 | Claude (SBDEV-3304), on Nam's request |
| 2026-09-14 | **SBDEV-3354 — `cancelBatch` deleted.** Four claims in this doc named `CustomerorderBatchService.cancelBatch` as the club batch-cancel path: the §6 method table row, the §6 OMS callback table, the §7 cancellation-paths table (two of its three rows) and the §8 transaction-boundary bullet asserting batch-atomicity. The method had no route, no caller and no production message; it was deleted. All four now describe the real path — `OrderRestController.cancelPositions` looping `cancelOrder`, one transaction per order, partial success possible. **Scope: the `cancelBatch` claims only** — `last_verified` stays at 2026-06-01 and the doc remains overdue. | `git grep` on `origin/develop` (1 `src/main` occurrence → 0; positive control 54 in `src/test`) plus Hydra PRD `outbox_message`: 0 rows of the pair only `cancelBatch` wrote, against a positive control of 3 rows of the same `process_type` under `aggregate_type='CUSTOMER_ORDER'`. | SBDEV-3354 implementation |
| 2026-10-21 | **SBDEV-3102 slice D2 — the three retired `ManageOrderService` dispatcher shims deleted.** §1 and §6.1 now name `buildPickedPayloadJson` as the owner of the club UUID tote label; the three §6.2 rows say the shims are deleted; and (review L4) the UUID-tote side-effect moved from the PICKING row to the FINISHED_PICKING row, verified against `buildPickedPayloadJson` (sets `historytote` + `saveAll` for CLUB) and `buildPickingStartedPayloadJson` (no tote write). **Scope: those claims only** — `last_verified` stays at 2026-06-01. | `git grep -nw` of each name in `src/main`: only the shim definitions and comments, no caller | SBDEV-3102 D2 |
| 2026-11-05 | **SBDEV-4007 — async club run job.** Added §8A; corrected §7 row 2 and §9.9 (the batch lock does not span a run; a cancel waits only for validate/finalize and is then refused at 527); pointers in §5, §8, §10. All new text marked ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06). **Scope: those claims only** — `last_verified` NOT bumped. | Code read of branch `feature/SBDEV-4007-club-run-async` @ `d70beaaf`: `ClubRunJobService`, `ClubRunJobWorker`, `ClubRunJobClaimService`, `ClubRunJobRepository`, `ClubRunStepService`, `ClubRunExecutorConfig`, `ClubRunShutdownGuard`, `ClubLineController`, `CustomerorderBatchService` fenced overloads, `V2.2.47`, `CustomerorderService:760-870`. No tests or Maven run. | SBDEV-4007 docs lane |

| 2026-11-06 | **SBDEV-4007 P2 (web UI).** Added §8A.9; §8A.7's last paragraph now names the pre-P2 UI and points to it; §9 item 11 notes the widened `isClubRunning`. All new text marked ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06). **Scope: those claims only** — `last_verified` NOT bumped. | Code read of wms2-web-ui branch `SBDEV-4007` @ `3e11d3b`: `store/processes/clubRuns.js`, `itemsTable.vue`, `plugins/persistedState.client.js`, `club-line-order.cy.js` (diff `8eb11fe..3e11d3b`). No Jest, no Cypress run. | SBDEV-4007 docs lane |

| 2026-11-11 | **Full re-verification** against `origin/develop` @ df30fa62 (detached worktree). Corrected: §1 and §3 anchors (`runClubLine` :1155, `rollbackClubLineState` :1121, controller mappings), §3 activate sequence (assign 525 then activate 520, final 520; `requireNotYetActivated`, SBDEV-4038), §3 Phase 2 (creates a package Unitload, no Pickingorder, no OMS callbacks) and the nonexistent Phase 4, §4 table (all line numbers; `activateOrderBatch` not `@Transactional`; `finalizeBatchIfComplete` IS `@Transactional`; `rollbackClubLineState` swallows exceptions), §5 endpoint lines + TransfersController lines + `transferOrder` now notifies OMS (SBDEV-3311), §6.1 (no `handleRapidPickingForCancelledOrder`; side-door needs RAPID_PICKING), §6.2 (`sendAfterCommit` only for four callbacks; SHIPPED and CANCELLED are outbox), new §6.2a (SBDEV-3310 chunking, chunk size 1 everywhere), §7, §8 (no `REQUIRES_NEW` on `processOrder`), §8A (now merged; SBDEV-4089 run-as-requester), §9 items 2/4/7/8/13, §10 rows. **Not re-read:** §8A.9 (wms2-web-ui repo), the v1-derived measurements in §9.13, the OMS-side claims. `last_verified` advanced. | Code read; every anchor re-derived by grep; §8A checked by diff from `d70beaaf` | Doc re-verification |

**Re-verify every 60 days.** Next due: **2027-01-10** — club-run area has multiple active and recently archived plans; high rate of change (`CustomerorderBatchService` had 43 commits between 2026-06-01 and 2026-11-11) warrants more frequent re-verification than typical workflows.
