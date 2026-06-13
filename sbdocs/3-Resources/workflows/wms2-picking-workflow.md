---
title: "WMS v2 — Picking Workflow"
type: workflow
status: active
version: v2
scope: picking
owner: Nam Park
created: 2026-04-19
updated: 2026-06-01
last_verified: 2026-06-01
verified_by: code read of v2/wms2-api src/main + state-machine + transaction architecture docs
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ../architecture/wms2-scheduled-jobs-catalog.md
  - ./wms2-replenish-workflow.md
  - ../../4-Archieves/wms2/plan/260424-V2_Consolidated_Picking_Fixes_Port.md
  - ../../4-Archieves/wms2/plan/260424-OSIV_MERGE_PICKING_ORDERS_BUG_FIX_PLAN.md
  - ../../4-Archieves/wms2/plan/260424-picking-notification-drop.md
  - ../../4-Archieves/wms2/plan/260424-picking-oms-status-race-condition-fix.md
  - ../../4-Archieves/wms2/plan/260424-PICKING_PERFORMANCE_PLAN.md
tags:
  - workflow
  - picking
  - wms2
---

# WMS v2 — Picking Workflow

**Scope:** End-to-end picking flow in `v2/wms2-api` — from a released customer order to finalized pick cascade · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-05-08

---

## 1. Overview

Picking is the single hottest state-transition surface in `wms2-api`. One finalize call (`PickingorderBusinessService.finalizePicking`) mutates five entities in one transaction: `Customerorder`, `Pickingorder`, `PickingorderPosition`, `PickingorderUnitload`, and indirectly `Stockunit`. Roughly half the archived v2 bug plans touch this flow (OSIV, merge, notification, race conditions, performance).

Two entry points trigger picking work:

- **Scheduled release**: `OrderReleaseJob` (cron, gated by `app.cron=true` + `ORDER_TIMER_ACTIVATED`) walks `ASSIGNED` customer-order positions and creates picking orders for any whose fixed-location / overstock math now allows release.
- **On-demand**: REST endpoints `/v3/clubLine/runClubLine/{batchId}` (for club runs) and `/v3/orders/*` (individual releases) produce the same downstream work synchronously.

Both paths converge on `ReleaseOrderJobService.releaseOrder(...)` and thereafter through the mobile pick flow.

---

## 2. Entity Cast

| Entity | Role | State field |
|---|---|---|
| `Customerorder` | Order we're fulfilling | Integer `state` |
| `CustomerorderPosition` | Order line | Integer `state` |
| `CustomerorderBatch` | Batch / club wave (optional) | Integer `state` |
| `Pickingorder` | Work package for an operator | Integer `state` |
| `PickingorderPosition` | One line of work | Integer `state` |
| `PickingorderUnitload` | Tote / carton being filled | Integer `state` |
| `Stockunit` | Amount + reserved amount at a location | — (no state) |
| `Unitload` | Physical pallet / tote holding stock | — (no state) |

For full state-value enumeration see [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §2.1. This doc assumes those constants.

---

## 3. Lifecycle

```
(customer order arrives, via OMS REST or file import)
         │
         ▼
   Customerorder.state = RAW (or FUTURE_PICKING_DATE)
         │
         ▼  CustomerorderService.createForRelease() (lines 239-244)
         │
  ┌──────┴────────┐
  │ scheduled?    │
  └──┬────────┬───┘
     │        │
     │ no     │ yes
     │        ▼
     │   OrderReleaseJob.doCalculation()
     │   ├─ advisory lock JobLockId.ORDER_RELEASE (100001L)
     │   ├─ per-tenant: set TenantContext
     │   └─ for each order in ASSIGNED state:
     │        ReleaseOrderJobService.releaseOrder(...)   [@Transactional REQUIRES_NEW]
     │             ├─ Customerorder.state → ASSIGNED / STARTED
     │             ├─ CustomerorderPosition.state → PROCESSABLE
     │             └─ Pickingorder created, state = PROCESSABLE
     │
     ▼
   Pickingorder.state = PROCESSABLE
         │
         │  optional: ReplenishOrderJob.mergePickingOrders()
         │           ├─ for TOTES_ON_CART sections
         │           └─ Pickingorder.state stays PROCESSABLE
         │
         ▼
   [ Mobile operator flow ]
         │
         │ MobilePickingService.reserveOrder()       [line 341]
         ▼
   Pickingorder.state = RESERVED
         │
         │ PickingorderBusinessService.startPicking()  [line 121]
         ▼
   Pickingorder.state = STARTED
         │
         │ … operator scans items, fills totes …
         │
         │ MobilePickingService.finishPicking()        [state writes at lines 222, 267, 271, 276]
         │
         ├──► PickingorderBusinessService.finalizePicking()  [lines 238-568]
         │    {5-entity cascade — see §4}
         │
         ▼
   Customerorder.state = PICKED   (or PENDING or STARTED)
   Pickingorder.state = FINISHED  (or PICKED, PROCESSABLE, CANCELED)
   PickingorderPosition.state = PICKED / STARTED / PENDING
   PickingorderUnitload.state = PICKED / STARTED
         │
         │  downstream: pack → palletize → load-to-truck → BOL close
         │  (see wms2-bol-truck-loading-workflow.md)
         ▼
   Customerorder.state = FINISHED

   Sidebar: RapidPicking releases stale picks
         │
         ▼  ReleaseExpiredPickingOrdersFromUserJob (every :40s, gated by PICK_TIME_OUT_SYSTEM_ACTIVATED)
         │
         └─ if Pickingorder.state=PICKED && section.type=RAPID_PICKING && lockedMs > PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE
              → clear operatorId, locked_to_operator=false
              (state unchanged — the order goes back to the pool for another picker)
```

---

## 4. The `finalizePicking` Cascade

`PickingorderBusinessService.finalizePicking()` is the single most dangerous method in the picking path. One call writes five entities across ~300 lines. Read the entire method before changing any part of it.

| Write site | Line | Entity | Target state |
|---|---|---|---|
| line 238 | Customerorder | `PENDING` |
| line 241 | Customerorder | `PICKED` |
| line 318 | Pickingorder | `orderState` (parameter — typically `FINISHED` or `CANCELED`) |
| line 343 | Customerorder | `CANCELED` (via `cancelOrderByOperator`) |
| line 359 | PickingorderUnitload | `CANCELED` |
| line 451, 464, 485 | PickingorderPosition | `PICKED` |
| line 491 | PickingorderPosition | `STARTED` |
| line 493 | PickingorderPosition | `PENDING` |
| line 502 | Customerorder | `STARTED` |
| line 563 | PickingorderUnitload | `STARTED` |
| line 569 | Pickingorder | `PICKED` |

**Why three terminal states for one PickingorderPosition?** `PICKED` is the happy path; `STARTED` means the position is only partially filled and the order continues; `PENDING` means the position is blocked waiting for downstream allocation. Missing one of the three branches when you modify the method produces stuck state.

For the full cascade map see [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §5.5.

---

## 5. Mobile Operator Flow

Mobile UI (`v2/wms2-mobile-ui`) drives the operator side. Each screen action maps to a REST call on `MobilePickingService`.

| Screen action | REST → service method | State change |
|---|---|---|
| Scan picking order barcode | `reserveOrder` (line 341) | Pickingorder `PROCESSABLE` → `RESERVED` |
| Claim the order | `startPicking` (`PickingorderBusinessService:121`) | Pickingorder `RESERVED` → `STARTED` |
| Scan item, enter quantity | no state change; updates `Pickingorderposition.amount` | — |
| Complete the pick | `finishPicking` (state writes at lines 222, 267, 271, 276) → `finalizePicking` | 5-entity cascade (§4) |
| Abort | routed through `cancelOrderByOperator` | Customerorder → `CANCELED` |

> Picking-position sort order (VERTICAL = column-first, HORIZONTAL = row-first) is controlled by the `PICK_PATH_DIRECTION` sysprop via `PickPathConfig` → `DefaultStrategy`.

Per-operator guards in `MobilePickingService`:

| Line | Guard |
|---|---|
| 222 | `== PICKED` — can only finish an already-completed pick |
| 303 | `== PICKED` — before claim |
| 328 | `>= PICKED` — progression check |
| 333 | `>= RESERVED` — only claimed picks can advance |
| 340 | `< RESERVED` — not yet claimed |

---

## 6. Rapid Pick Side-Door

`RAPID_PICKING` sections behave differently. When a customer order is cancelled AND the tote was already rapid-picked, the rapid-pick branch in `CustomerorderService.cancelOrder` (guard at line 639, `Pickingorder.setState(PROCESSABLE)` at line 645) bounces the `Pickingorder` **back to `PROCESSABLE`** instead of `CANCELED`, so the tote's contents can be redistributed to other orders.

```
cancelOrder() on an order with historytote != null
     │
     ├── Customerorder.state = CANCELED
     │
     └── handleRapidPickingForCancelledOrder()
           └── Pickingorder.state = PROCESSABLE  ← NOT CANCELED
```

Don't "simplify" the `historytote != null` branch — see `Cancel_Order_Null_SectionId_And_Early_Return_Fix` for the original incident.

`ReleaseExpiredPickingOrdersFromUserJob` also only fires on `RAPID_PICKING` sections. See [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §4.5.

---

## 7. Merge Pass

`ReplenishOrderJob.mergePickingOrders()` runs before each replenish pass (gated by sysprop `MERGE_PICKING_ORDERS=true`, default `true`). For sections with picking type `TOTES_ON_CART`, it groups compatible picking orders into a single cart-sized work unit respecting `PICKING_BOX_PER_CART` (default `6`).

- Sets `Pickingorder.state = PROCESSABLE` for the merged group at `PickingOrderMergeService.java:161`.
- If merge fails for any reason, the affected `Pickingorder` is explicitly cancelled at `PickingOrderMergeService.java:127` (state → `CANCELED`).

Merge is a silent optimization — an operator never sees it. But it means: when a new pick order appears unexpectedly, check whether merge produced it before treating it as anomalous.

---

## 8. OMS Callback Touchpoints

Picking-lifecycle OMS callbacks use **two delivery mechanisms** depending on the call-site (see `wms2-oms-integration-map.md` §2.1):

| OMS callback | Fired from | Delivery | Sysprop URL key |
|---|---|---|---|
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `ManageOrderService.customerOrderReleaseForPicking()` | `sendAfterCommit` | `…RELEASED_FOR_PICKING_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `ManageOrderService.customerOrderToteAssigned()` | `sendAfterCommit` | `…PICKING_TOTE_ASSIGNED_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_PICKING` | `PickingorderBusinessService.confirmPick()` | **outbox** ¹ | `…PICKING_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `PickingorderBusinessService.finishPickingOrder()` | **outbox** ¹ | `…FINISHED_PICKING_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_HELD` | `ManageOrderService.customerOrderOnHold()` | `sendAfterCommit` | `…HELD_URL_KEY` |

> ¹ **2026-05-20 (picking-finished fix):** `PICKING_STARTED` and `PICKING_FINISHED` were previously routed through `ManageOrderService.customerOrderPickingStarted/Picked` via a nested `registerSynchronization` call inside `sendAfterCommit`, which Spring silently discarded (double-afterCommit bug — see investigation report `260520-wms2-picking-finished-oms-notification-dropped.md`). Both call-sites in `PickingorderBusinessService` now call `outboxService.enqueue(OutboxMessage)` directly inside the still-open `@Transactional("tenantTransactionManager")` boundary — the outbox row commits atomically with the state change. `OutboxDispatcherJob` delivers with at-least-once retry. `ManageOrderService.customerOrderPickingStarted()` and `customerOrderPicked()` are retained (`@Deprecated`) for `CustomerorderBatchService` callers.
>
> **Safety net:** `MobilePickingService.releaseRegularPickingOrder` Case 1 (already-finished early exit) now calls `PickingorderBusinessService.reenqueuePickingFinishedIfMissing(pickingOrder)` before returning, to recover any CO with `state≥PICKED` AND `pickingconfirmationsent=false` stranded by the pre-fix bug.

> **SBDEV-2381 (2026-06-01) — backward-STARTED guard:** `confirmPick` now **skips the `PICKING_STARTED` outbox enqueue when the CO has already advanced** — `state ≥ PICKED` OR `pickingconfirmationsent == true` (snapshot taken before `setState(STARTED)`). This is the primary defense against emitting a backward `STARTED` after a parcel has reached Ready-to-QA. It complements the dispatcher-side ordering gate + `event_version` field added in the same ticket — see `architecture/wms2-oms-integration-map.md` §2.1.

`sendAfterCommit`-based callbacks fire **after the WMS transaction commits**. A WMS rollback silently drops the callback. If OMS claims it never heard about a non-outbox callback, check the `message` / `message_archived` tables for a matching row — absence means the commit itself never happened or the nested-afterCommit bug fired. For outbox-based callbacks, check `outbox_message WHERE process_type IN ('ORDER_BATCH_PICKING_FINISHED','ORDER_BATCH_PICKING_STARTED')`.

---

## 9. Transaction Boundaries

- `OrderReleaseJob` → `ReleaseOrderJobService.releaseOrder(...)` — each order release is `@Transactional(propagation=REQUIRES_NEW, value="tenantTransactionManager")`. A single order failure does not abort the rest of the tenant's run.
- `finalizePicking` runs under a single `@Transactional("tenantTransactionManager")` — all 5 entity writes succeed or all roll back atomically. No cascade is "halfway through" on an exception.
- Optimistic locking on `AbstractBaseEntity.version` guards every save; retries are NOT automatic inside the picking transactions — a conflict surfaces at commit and is mapped to HTTP 409 (`RestExceptionHandler`) for the operator to retry. The former `OptimisticLockRetry` wrapper inside `confirmPick` was removed as inert (260610 Phase A: inside an open `@Transactional` the optimistic-lock exception only fires at the outer commit, outside the retry loop); the path is serialized by the CO/PO `findByIdForUpdate` locks taken at method entry.
- OMS POSTs use either `omsNotificationService.sendAfterCommit(...)` (fire-and-forget, no retry) or `outboxService.enqueue(...)` (at-least-once, retried by `OutboxDispatcherJob`) — see §8 table. Never block the TX on network I/O.

For the full transaction + locking picture see [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §5 and §8.

---

## 10. Known Landmines

1. **`finalizePicking` writes 5 entities in one TX.** Read §4 in full before modifying any branch. Missing one case produces stuck state (e.g. `Pickingorder=FINISHED` but `Customerorder=STARTED`).
2. **`RAPID_PICKING` cancellation side-door** (§6). Cancelling an order with `historytote != null` leaves the `Pickingorder` in `PROCESSABLE`, not `CANCELED`. Archive: `Cancel_Order_Null_SectionId_And_Early_Return_Fix`.
3. **Only mobile writes `Pickingorder=FINISHED`.** `MobilePickingService:267` is the only terminal-state writer. Any non-mobile path that believes it's "finished picking" must route through the mobile service or a refactor — flagged in `WMS_API_Problem_Areas_Analysis_And_Refactoring_Plan`.
4. **`Pickingorder=PICKED` vs `FINISHED`**. `PICKED` means the physical work is done but the `Customerorder` hasn't rolled up yet. `FINISHED` is the terminal tenant-DB state. Treat them as distinct in queries.
5. **Merge pass runs quietly.** A new `Pickingorder` can materialize between two scheduler ticks due to `ReplenishOrderJob.mergePickingOrders`. Don't treat unexpected picks as anomalies without checking §7.
6. **OMS callbacks drop silently on rollback.** Use `message` table to verify delivery — see `picking-notification-drop` archive.
7. **`ReleaseExpiredPickingOrdersFromUserJob` is off by default.** `PICK_TIME_OUT_SYSTEM_ACTIVATED=false` ships in every environment. Enable it explicitly or rapid-pick orders abandoned mid-flight stay locked indefinitely.
8. **`Pickingorder.locked_to_operator` is manipulated by both the mobile flow and the release job.** The timeout release (§6) only clears operator binding, not state — it leaves `Pickingorder` in `PICKED` for another operator to claim.
9. **State-value numeric ordering is load-bearing.** `MobilePickingService` uses `>= PICKED`, `< RESERVED` comparisons. Renumbering constants in `WmsConstants.State` silently breaks these. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §7 item 4.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| "Picking order stuck in PICKED, never progresses" | §4 cascade map + §10 item 3 (non-mobile terminal writer) |
| "Order cancelled but Pickingorder still PROCESSABLE" | §6 rapid-pick side-door + §10 item 2 |
| "OMS says it never got picking notification" | §8 + `message` / `message_archived` tables + §10 item 6 |
| "Unexpected pick order appeared" | §7 merge pass |
| "Operator can't finish pick — validation error" | §5 guard table |
| "Replica A fires release, Replica B fires again" | advisory lock [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §2 |
| "Optimistic lock storm during burst picking" | [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8 + archive `260401-replenish-stockunit-optimistic-lock-debug-plan` |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `PickingorderBusinessService.finalizePicking` (lines 238-568) + all mobile guards (lines 222-340) + release job release path + merge service + rapid-pick side-door | All file:line refs confirmed against `src/main/java` | Code read + state-machine / transaction architecture docs |
| 2026-05-08 | Group P verification follow-up (commits da64cc0, 99340b0, 4430824, 892169b, 930be52, b68cbbf, d61040c). Re-confirmed `ReleaseOrderJobService.releaseOrder` pessimistic lock at line 107, `findByIdForUpdate` sites in `MobilePickingService` (4 sites incl. line 400 in `processPick` per the Group-P lock-ordering note in the file), `PickingOrderMergeService.saveAll` at lines 194/198 (state writes still at 127 / 161). `finalizePicking` write sites shifted +1 (line 451/464/485 etc.) and §4 table was rebumped to current line numbers. §6 rapid-pick guard cite updated from `645` to `639` (guard) + `645` (state write). | Code read of v2/wms2-api at HEAD |
| 2026-06-01 | SBDEV-2381: `confirmPick` now skips the `PICKING_STARTED` outbox enqueue when the CO already advanced (`state ≥ PICKED` OR `pickingconfirmationsent`), snapshot taken before `setState(STARTED)`. §8 note added. | Confirmed against `PickingorderBusinessService.confirmPick` (PR #35, commits 567fba3 + 41ad7d3) | Code read (grep-based) |

**Re-verify every 60 days.** Next due: **2026-07-31** — picking is the most change-prone surface; a single PR to `finalizePicking` invalidates §4.
