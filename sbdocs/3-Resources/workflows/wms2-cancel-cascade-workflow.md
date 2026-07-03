---
title: "WMS v2 — Cancel Cascade Workflow"
type: workflow
status: active
version: v2
scope: cancel-cascade
owner: Nam Park
created: 2026-04-19
updated: 2026-05-08
last_verified: 2026-05-08
verified_by: code read of v2/wms2-api src/main + state-machine architecture doc
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ./wms2-picking-workflow.md
  - ./wms2-club-run-workflow.md
  - ../../4-Archieves/wms2/plan/260424-Cancel_Club_Parcels_Packed_State_Fix.md
  - ../../4-Archieves/wms2/plan/260424-Cancel_Order_Null_SectionId_And_Early_Return_Fix.md
  - ../../4-Archieves/wms2/plan/260424-Club_Order_Cancellation_Fix_Plan.md
  - ../../4-Archieves/wms2/plan/260424-Club_Order_Cancellation_OMS_Fix.md
  - ../../4-Archieves/wms2/plan/260424-RunClubLine_Cancelled_Order_Fix_Plan.md
tags:
  - workflow
  - cancel
  - cascade
  - wms2
---

# WMS v2 — Cancel Cascade Workflow

**Scope:** Every code path that cancels a customer order or batch in `v2/wms2-api`, plus the entities it cascades through · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-05-08

---

## 1. Overview

Cancellation is the most bug-prone flow in the v2 archive. The problem: one `cancelOrder` call can cascade through up to **4 entity types** in one transaction, plus trigger post-commit OMS callbacks and in rare cases *revert* a Pickingorder back to `PROCESSABLE` instead of cancelling it. Every archived cancel bug traces to a missed branch or a misunderstood cascade edge.

Two things to hold in mind before touching this flow:

1. **Cancellation is terminal for the Integer states** (`Customerorder`, `Pickingorder`, `PickingorderUnitload`, etc. use `CANCELED` = `800`) **but non-terminal for String states** (`Advice`, `Billoflading` use `CANCELLED` with two L's). Don't copy-paste a guard from one to the other.
2. **There is a rapid-pick side-door** where a "cancel" doesn't actually cancel the `Pickingorder` — it bounces it back to `PROCESSABLE`. Removing this branch would drop wine-club tote recycling.

---

## 2. Cancellation Entry Points

Six service-layer methods own the cancel paths. Every cancel in the codebase goes through one of these.

| Entry point | File:Line | Scope | Trigger |
|---|---|---|---|
| `CustomerorderService.cancelOrder(...)` | `service/CustomerorderService.java:588` (method) — `customerOrder.setState(CANCELED)` at line 675 | Single order | REST admin + OMS-initiated |
| `CustomerorderService.forceCancelOrder(...)` | `service/CustomerorderService.java:323` (method) — `customerOrder.setState(CANCELED)` at line 351 | Single order (force path) | Admin bypass when normal cancel is blocked |
| Rapid-pick recovery branch (inside `cancelOrder`) | guard at `service/CustomerorderService.java:639`, `pickingOrder.setState(PROCESSABLE)` at line 645 | Side-effect of `cancelOrder` on rapid-pick orders | Invoked internally when `historytote != null` and section is `RAPID_PICKING` |
| `CustomerorderBatchService.cancelBatch(...)` | `service/CustomerorderBatchService.java:221` | Entire batch (all child orders) | REST `/clubLine/...` + admin |
| `CustomerorderBatchService.finalizeBatchIfComplete(...)` | `service/CustomerorderBatchService.java:346` | Roll up to `CANCELED` if all child orders cancelled | Called post-order-cancel |
| `PickingOrderMergeService.cancelOrderIfMergeFails(...)` | `service/PickingOrderMergeService.java:127` | Picking order only | Called when merge pass fails |
| `ReplenishorderService.cancelReplenishment(...)` / `ReplenishmentOrderMaintenanceService.cancelOrder(...)` | various | Replenish order only | Background cron path |

Cancel on Advice and Billoflading (String states) goes through entity-specific methods — covered in the receiving-and-putaway and BOL workflows respectively.

---

## 3. The Core Cascade — `CustomerorderService.cancelOrder`

When a single customer order is cancelled, the cascade touches **4 entities** in one transaction:

```
cancelOrder(customerorderId)                            [CustomerorderService.java:588]
  │
  ├── Customerorder.state = CANCELED                                (line 675)
  │
  ├── for each CustomerorderPosition of this order:
  │     CustomerorderPosition.state = CANCELED                       [CustomerorderPositionService.java:133]
  │
  ├── for each Pickingorder of this order:
  │     │
  │     ├── IF historytote != null AND rapid-pick section            [guard line 639]
  │     │     Pickingorder.state = PROCESSABLE                       [CustomerorderService.java:645]  ← SIDE-DOOR
  │     │     (tote's contents are now available for other orders)
  │     │
  │     └── ELSE (forceCancel path or in-flight pick)
  │           Pickingorder.state = CANCELED                          [forceCancelOrder line 300]
  │
  ├── for each PickingorderUnitload of those picking orders:
  │     PickingorderUnitload.state = CANCELED                        (forceCancelOrder line 305 / cancelOrder line 650)
  │
  ├── OMS callback: WEBSERVICE_ORDER_BATCH_CANCELLED                 (post-commit)
  │
  └── CustomerorderBatch state check:
        if all sibling orders in the batch are now CANCELED →
          CustomerorderBatch.state = CANCELED                        [CustomerorderBatchService.java:358]
        (finalizeBatchIfComplete called from the order-cancel path)
```

**Transfer-lane release (fix `260629-transfer-lane-leak-on-cancel`, 2026-06-29).** For a *transfer* order, `cancelOrder` (and `forceCancelOrder`, §9) now also clears `transferlaneId` — a guarded direct `setTransferlaneId(null)` before the save, freeing the held transfer lane at the cancel transition. This is **defense-in-depth in addition to** the existing `finalizeBatchIfComplete` release (which only fires when every sibling order in the batch is terminal, `state ≥ FINISHED`). Both run on the same managed entity inside the one tenant TX, so the second clear is an idempotent no-op (the `if (getTransferlaneId() != null)` guard in `finalizeBatchIfComplete` short-circuits) — single flush, single `@Version` bump. The cancel paths use a **direct** clear, never `TransferOrderService.unlinkTransferLaneFromTransferOrder` (that helper resets state to `505` and would un-cancel the order). Note: because `CANCELED(800) ≥ FINISHED(700)`, a cancelled order never blocks lane availability anyway — the real lane leak is *abandonment* of orders stuck at 505/510, covered in [wms2-transfer-order-workflow.md §8](./wms2-transfer-order-workflow.md).

See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §5.1 for the full cascade map, and [wms2-picking-workflow.md](./wms2-picking-workflow.md) §6 for the side-door.

---

## 4. Cancellation Guards

The decision whether to `CANCEL` vs `forceCancel` vs refuse is controlled by state-based guards. These are copy-pasted in 5+ places; keep them consistent.

| Guard | Location | Allows |
|---|---|---|
| `state != FINISHED && state != CANCELED` | `OrderRestController:180` | Normal cancel |
| `state != PICKED` | `CustomerorderService:471` | Pack — not a cancel guard, but co-located |
| `state == PACKED OR state == PALLETIZED` | `CustomerorderService:382,554` | Blocks normal `cancelOrder` — requires `forceCancelOrder` |
| `state == CANCELED` (positive) | `CustomerorderService:550`, `CustomerorderBatchService:168,357` | Idempotency check / rollup condition |
| `state == ASSIGNED && historytote != null` | `CustomerorderService:639` | Rapid-pick cancel path — triggers §3 side-door |

**`Cancel_Club_Parcels_Packed_State_Fix`** fixed a bug where the `PACKED/PALLETIZED` guard at line 382 was missing, producing double-state application during club-order cancel. Don't remove that guard.

---

## 5. Batch Cancel — `CustomerorderBatchService.cancelBatch`

Batch cancel is NOT "cancel each child one at a time." It is a single transaction that:

```
cancelBatch(batchId, Principal)                          [CustomerorderBatchService.java:221]
  │
  ├── CustomerorderBatch.state = CANCELED                (line 279, 339)
  │
  ├── for each Customerorder in batch:
  │     cascade per §3
  │
  ├── for each Pickingorder under any child order:
  │     Pickingorder.state = CANCELED
  │
  ├── for each Unitload / Stockunit locked by the batch:
  │     release entity locks (so stock is returnable)
  │
  └── OMS callback: WEBSERVICE_ORDER_BATCH_CANCELLED     (line 265, post-commit)
        payload includes per-order breakdown
```

Contrast with `finalizeBatchIfComplete` (line 346) which is a *rollup* — it observes that all child orders are already `CANCELED` and marks the batch `CANCELED` as a consequence. It is NOT a cancel trigger, it's a cancel *consequence*.

---

## 6. Post-Commit OMS Callbacks

Cancellations fire exactly one outbound callback per atomic cancel operation:

| Cancel type | Callback | Sysprop URL key | Message type |
|---|---|---|---|
| Single order (via `cancelOrder`) | per-order POST | `WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` (activation: `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED`, default `false`) | `ORDER_BATCH_CANCELLED_FROM_WMS` |
| Batch (via `cancelBatch`) | batch-level POST | same URL key | same |

Callbacks are registered via `TransactionSynchronizationManager.registerSynchronization` and fire *after* the WMS transaction commits. If rollback happens, the callback never fires. `Club_Order_Cancellation_OMS_Fix` was the archived bug for a callback that fired *before* commit — triggering OMS to reflect a cancel that WMS later didn't persist.

---

## 7. Rapid-Pick Side-Door (Revisited)

The branch that keeps tripping up new code:

```java
// CustomerorderService.cancelOrder, approximate shape
if (order.getState() == WmsConstants.State.ASSIGNED && order.getHistorytote() != null) {
    handleRapidPickingForCancelledOrder(order);  // Pickingorder → PROCESSABLE
} else {
    // normal cascade — Pickingorder → CANCELED
}
```

Why? In wine-club / club-order flows using `RAPID_PICKING` sections, an operator may already have partial items on a tote (`historytote` is set) when OMS asks to cancel. Cancelling the `Pickingorder` would orphan the physical picks; bouncing back to `PROCESSABLE` lets another order claim the tote's contents without a re-pick.

**Don't simplify this.** `Cancel_Order_Null_SectionId_And_Early_Return_Fix` in the archive is the post-mortem for an attempt to do exactly that.

---

## 8. Transaction Boundaries

All cancel methods are `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` — the whole cascade succeeds atomically or rolls back.

No `REQUIRES_NEW` is used in the cancel path (contrast with `OrderReleaseJob` / `ReplenishOrderJob` — see [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §4). An exception mid-cascade rolls back the whole cancel, which is the desired behavior — partial cancel state would leave the batch in an unrecoverable mix.

Optimistic locking (`AbstractBaseEntity.version`) guards every entity save; `OptimisticLockRetry` is *not* automatically applied inside cancel paths. If a concurrent pick update fires a `@Version` bump mid-cancel, the cancel transaction rolls back and the caller must retry.

---

## 9. Guardrails for `forceCancelOrder`

`forceCancelOrder` at `CustomerorderService:323` (method declaration; `customerOrder.setState(CANCELED)` write at line 351; `pickingOrder.setState(PICKED)` at line 356) is the escape hatch for orders that normal cancel refuses (because they're `PACKED`, `PALLETIZED`, or already have physical work downstream). Rules for use:

1. Admin-only — never expose to operators.
2. Always writes `Customerorder.state = CANCELED` regardless of prior state.
3. Writes `Pickingorder.state = PICKED` (line 356) — a deliberately unusual choice: the physical work is done, the order is cancelled, but the pick itself stays terminal-success so downstream repack / restock flows see consistent state.
4. Does **not** unwind the `PickingorderUnitload` cascade the way `cancelOrder` does — the force path trusts the caller has reviewed child state.
5. **Releases the transfer lane** (fix `260629`, 2026-06-29): a guarded `setTransferlaneId(null)` before the final save, so a force-cancelled transfer order frees its lane. Direct clear only — never `unlinkTransferLaneFromTransferOrder` (which would reset state to `505`).

---

## 10. Known Landmines

1. **`CANCELED` vs `CANCELLED` spelling.** Integer state is `CANCELED` (one L). String state is `CANCELLED` (two). A guard `.equals("CANCELED")` on an advice always returns false. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §2.2.
2. **Rapid-pick side-door** (§7). Don't remove without reviewing `Cancel_Order_Null_SectionId_And_Early_Return_Fix`.
3. **`PACKED`/`PALLETIZED` early-return guard** (`CustomerorderService:382,554`). Blocks normal cancel so downstream physical state stays consistent. `Cancel_Club_Parcels_Packed_State_Fix` restored this after it was accidentally removed.
4. **`cancelBatch` cascades into ALL child orders in one TX.** Large batches can produce multi-second transactions; this is the hottest pessimistic-lock contention window in the cancel path.
5. **`finalizeBatchIfComplete` is a *consequence*, not a trigger.** Don't call it directly as if it were a cancel entry point.
6. **OMS callback activation is OFF by default** (`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED=false`). Customer tenants that rely on cancel notifications must flip this sysprop explicitly.
7. **`forceCancelOrder` sets `Pickingorder=PICKED`, not `CANCELED`** (§9 item 3). Queries that filter `Pickingorder.state=CANCELED` will miss force-cancelled orders.
8. **Optimistic-lock retry is NOT automatic.** Cancel transactions that race with concurrent picks simply fail and bubble up — the caller is responsible for retry. See [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8.3.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| "Order cancelled but Pickingorder still live" | §7 side-door + §10 item 2 |
| "OMS never received the cancel" | §6 + `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` sysprop + `message` table |
| "Can't cancel — 'order in PACKED state'" | §4 guard + §9 forceCancelOrder path |
| "Batch partially cancelled, children inconsistent" | §8 — check if cancel threw mid-cascade; expect rollback |
| "forceCancel left Pickingorder=PICKED" | §10 item 7 (expected) |
| "Optimistic lock during cancel" | §10 item 8 — conflict surfaces at commit → HTTP 409 (`RestExceptionHandler`); caller retries. (`OptimisticLockRetry` is NOT applicable inside cancel transactions — 260610 Phase A) |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | All 6 cancel entry points (cancelOrder / forceCancelOrder / handleRapidPickingForCancelledOrder / cancelBatch / finalizeBatchIfComplete / cancelOrderIfMergeFails); guard locations (lines 180, 382, 471, 550, 554, 639); OMS callback sysprop default | All file:line refs confirmed against `src/main/java` | Code read + state-machine architecture doc |
| 2026-05-08 | `CustomerorderService.cancelOrder` method now starts at line 588 (was cited as 300) — write of `customerOrder.setState(CANCELED)` is at line 675; `forceCancelOrder` method declaration line 323; rapid-pick guard line 639 + setState write line 645 — all updated. Group X parcel-cancel port (v1 `46130c3` → v2 `e2b82ed`) lives in `unifyScanParcelCancelMessage` user-message path — no impact to cancel-cascade map. Picking-flow follow-up commits (Group P) didn't touch the cancel cascade entry points. SBDEV-2214 changes intentionally NOT pre-documented per audit constraint. | All file:line refs updated; cascade story unchanged. | Code read + state-machine architecture doc |
| 2026-06-29 | Fix `260629-transfer-lane-leak-on-cancel`: `cancelOrder` and `forceCancelOrder` now clear `transferlaneId` for transfer orders (guarded direct `setTransferlaneId(null)` before save) — documented in §3 and §9. **Scope: transfer-lane behavior only** — the pre-existing line-number drift in this doc (cancelOrder now at 651, `setState(CANCELED)` at 750, save at 754; forceCancelOrder at 349, save at 438) was observed but NOT fully re-audited, so the frontmatter `last_verified` is left at 2026-05-08. Interaction with `finalizeBatchIfComplete` verified safe (same managed entity, one tenant TX, idempotent second clear → single flush). | Transfer-lane release confirmed by 143-test green run + code review (SHIP); full doc re-sweep still pending. | Fix `260629` implementation + code review |

**Re-verify every 60 days.** Next due: **2026-07-07** — cancel is a high-traffic fix surface; any new landed plan touching `CustomerorderService` or `CustomerorderBatchService` should trigger a re-sweep.
