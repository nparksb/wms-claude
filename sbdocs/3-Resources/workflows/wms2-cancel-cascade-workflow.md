---
title: "WMS v2 — Cancel Cascade Workflow"
type: workflow
status: active
version: v2
scope: cancel-cascade
owner: Nam Park
created: 2026-04-19
updated: 2026-09-15
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

The service-layer methods below own the cancel paths worth knowing. **Treat this as a reading list, not a closed set** — the table has always carried more rows than the count in this sentence claimed, and `cancelBatch` sat in it for months as an entry point with no entry. *Deriving method:* `git grep -n 'setState(WmsConstants.State.CANCELED)' -- 'src/main/**/*.java'` returns **20 lines across 7 files** on the SBDEV-3354 branch, and **26 across 8** on `origin/develop` before that deletion merges (both measured 2026-09-14). That grep's blind spots — ternaries, local variables, `@Modifying` bulk updates, `setMarkedforcancellation`, native SQL — are enumerated in the javadoc on `PickingorderBusinessServiceUnitTest.ConfirmPickCancellationGuard`. Do not read either number as an inventory.

| Entry point | File:Line | Scope | Trigger |
|---|---|---|---|
| `CustomerorderService.cancelOrder(...)` | `service/CustomerorderService.java:588` (method) — `customerOrder.setState(CANCELED)` at line 675 | Single order | REST admin + OMS-initiated |
| `CustomerorderService.forceCancelOrder(...)` | `service/CustomerorderService.java:323` (method) — `customerOrder.setState(CANCELED)` at line 351 | Single order (force path) | Admin bypass when normal cancel is blocked |
| Rapid-pick recovery branch (inside `cancelOrder`) | guard at `service/CustomerorderService.java:639`, `pickingOrder.setState(PROCESSABLE)` at line 645 | Side-effect of `cancelOrder` on rapid-pick orders | Invoked internally when `historytote != null` and section is `RAPID_PICKING` |
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
          CustomerorderBatch.state = CANCELED                        [CustomerorderBatchService, finalizeBatchIfComplete:
                                                                      `batch.setState(allCanceled ? ... CANCELED : ... FINISHED)`]
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
| `state == CANCELED` (positive) | `CustomerorderService:550`; `CustomerorderBatchService`, `finalizeBatchIfComplete`: `boolean allCanceled = orders.stream().allMatch(o -> o.getState() == WmsConstants.State.CANCELED)` | Idempotency check / rollup condition |
| `state == ASSIGNED && historytote != null` | `CustomerorderService:639` | Rapid-pick cancel path — triggers §3 side-door |

**`Cancel_Club_Parcels_Packed_State_Fix`** fixed a bug where the `PACKED/PALLETIZED` guard at line 382 was missing, producing double-state application during club-order cancel. Don't remove that guard.

### 4.1 `CANCELED` is not "beyond PACKED" (SBDEV-3363, 2026-09-15)

The guards above answer *"is it too late to cancel?"*. **`CANCELED(800)` must not count as a yes** — a
position that is already cancelled does not block cancelling its order, and `cleanUpCancelledOrder` sets every
position to CANCELED anyway. Four sites express this rule and **two of them get it wrong**:

| Site | Guard | Excludes `CANCELED`? |
|---|---|---|
| `CustomerorderService.isShippedOrPastCancellationBoundary` | `state >= FINISHED && state != CANCELED` | ✅ |
| `CustomerorderService.cancelOrder`, inline | `state >= PACKED && state < CANCELED` | ✅ |
| `CustomerorderPositionService.canOrderPositionBeCancelled` | `state >= PACKED` | ❌ |
| `CustomerorderPositionService.cancelOrderPosition` | `state >= PACKED` | ❌ (and it **throws**) |

**SBDEV-3363 did NOT change the two wrong ones.** It makes `cancelOrder` **skip** already-CANCELED positions
in both of its `coPositions` loops, so neither helper is consulted for one. Relaxing the helpers instead was
implemented, reviewed and **rejected**: `cancelOrderPosition`'s work body is bounded `state < PACKED`, which is
*wider* than `cancelOpenPickLines`' `state < PICKED`, so an already-cancelled position carrying a `PICKED(600)`
pick line would have that line flipped to CANCELED and its picking order demoted — the outcome
`cancelOpenPickLines`' javadoc exists to prevent (*"flipping it to CANCELED would make the tote's contents
unattributable"*). CO `585000351` on wms2-wineco-dev has exactly that shape.

⚠ So the two ❌ rows above are **still live** and are still the wrong answer if consulted from a new call site.
`cancelOrder` is the only caller of either today.

`BillofladingService`'s `state >= PACKED` (*"has already been transferred"*) is **correctly** open-ended — its
question is *"is this order terminal?"*, where CANCELED is a yes. Same literal, opposite right answer.

---

## 5. Batch Cancel — there is no batch-cancel method

**`CustomerorderBatchService.cancelBatch` was deleted 2026-09-14 under SBDEV-3354.** It had no route
and no caller in `src/main` — and on a whole-history pickaxe rather than a snapshot grep, it never had
one: `git log --all -S "cancelBatch" -- 'src/main/**/*.java'` returns **only the initial check-in and
this deletion** — nothing in between — so across 1854 commits and 282 fetched remote refs no `src/main`
file other than its own declaring class has ever contained the token. *Positive control:* the same pickaxe for
`finalizeBatchIfComplete` returns 4 commits. A method with no caller in any commit cannot have run, so
it emitted nothing to OMS in any era — a stronger and more time-complete statement than the outbox
evidence below can make on its own. Earlier revisions of this section documented its cascade as if it ran, and the
2026-09-14 (SBDEV-3339) correction below had to walk back two claims that between them told a reader
the tote-stranding defect was already handled here. Deleting the method removes that whole class of
error rather than re-describing it.

*Snapshot cross-check:* `git grep -n "cancelBatch" origin/develop -- 'src/main/**/*.java'` returned
only its own declaration; *positive control:* the same grep over `src/test` returned 54 occurrences
across 4 classes, so the search worked. The **caller-side** sweep that mattered is the OMS, not the
UIs — a routeless `@Service` method is structurally unreachable from a browser, so five zero UI repos
were close to uninformative. `v2/oms-laravel-api@origin/develop` has **zero** `cancelBatch` and 25
`cancelPositions` hits, including `config/wms.php` →
`'order_cancel_positions' => env('WMS_ORDER_CANCEL_POSITIONS_ENDPOINT', 'rest/order/cancelPositions')`.
That is both the stronger negative and independent corroboration of the real path below.
*Runtime corroboration:*
`cancelBatch` was the only `src/main` writer of the outbox pair
`aggregate_type='CUSTOMER_ORDER_BATCH'` + `process_type='ORDER_BATCH_CANCELLED_FROM_WMS'` — the other
two writers of that process type use `aggregate_type='CUSTOMER_ORDER'`. Hydra PRD holds **zero** rows
of that pair; *positive control:* the same table holds 3 rows of the same process type under
`CUSTOMER_ORDER`, and 84 outbox rows overall. Hydra is the only tenant the prd landlord routes, so
"PRD" means that one tenant.

*Blind spot — larger than a retention window:* `cancelBatch` only began writing outbox rows at
`b15522bf` (2026-05-19, SBDEV-2238); before that it notified via `sendAfterCommit`, and earlier still
by inline HTTP, neither of which persists a row. Hydra PRD's `outbox_message` additionally only retains
from 2026-07-13, and `cancelBatch` wrote no `message` service-log row, so no second table reaches
further back. This check therefore covers one tenant over the retained outbox era only — it is
corroboration for the whole-history argument above, not a substitute for it. *Known gap:* no
instrument here can see reflective or SpEL invocation; nothing in the repo builds the name
dynamically, but that is an argument from absence.

### What actually cancels a batch

`OrderRestController.cancelPositions` — `POST /rest/order/cancelPositions`
(`controller/rest/OrderRestController.java`, `@PostMapping(value = "/cancelPositions"`). It is
OMS-driven and **loops the single-order path**; there is no batch-scoped transaction:

```
POST /rest/order/cancelPositions   [List<OrderBatchDto>]
  │
  ├── per batch:  validateWarehouse → resolve CustomerorderBatch by batchid
  │
  └── per order in the batch:
        resolve Customerorder by externalnumber
        customerorderService.cancelOrder(order, false)      ← the §3 cascade, one TX per order
          │
          ├── ToteTeardownException  → log, record in `errors`, CONTINUE with the rest of the batch
          │                            (SBDEV-3339; that order rolls back whole, not half-cancelled)
          ├── BusinessException      → abort the whole call, 400 WRONG_STATE
          ├── FacadeException        → abort the whole call, GENERIC_ERROR
          ├── Exception (any other)  → abort the whole call, GENERIC_ERROR
          └── every abort arm first calls logDiscardedTeardownFailures(...), re-logging
              teardown failures accumulated earlier in the batch — the 400/500 response
              body never carries them, only the success exit returns the `errors` map
```

Consequences that differ from the deleted batch method, and that a reader coming from the old text
will get wrong:

- **One transaction per order, not one per batch.** A batch cancel is not atomic across orders. Open-in-view
  is false, so each `cancelOrder` gets its own persistence context.
- **Partial success is a real outcome.** A tote-teardown failure on one order leaves that order
  uncancelled while its siblings cancel; the response carries the per-order `errors` map.
- **The OMS callback is per order** (`aggregate_type='CUSTOMER_ORDER'`), not one batch-level POST — see §6.
- **The batch row reaches `CANCELED` by rollup**, via `finalizeBatchIfComplete`, not by direct write.

Contrast with `finalizeBatchIfComplete` — it is a *rollup*: it observes that all child orders are
already `CANCELED` and marks the batch `CANCELED` as a consequence. It is NOT a cancel trigger.

---

## 6. Post-Commit OMS Callbacks

Cancellations fire at most one outbound callback per atomic cancel operation — **and `forceCancelOrder` fires none at all** (§9 item 7, §10 landmine 7b). Since SBDEV-3332 the two real emitters share the idempotency key `CO-CANCELLED-<customerorderId>`, so they cannot both land for one order:

| Cancel type | Callback | Sysprop URL key | Message type |
|---|---|---|---|
| Single order (via `cancelOrder`) | per-order enqueue, `aggregate_type='CUSTOMER_ORDER'` | `WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` (⚠ no activation gate in v2 — see §10 item 6) | `ORDER_BATCH_CANCELLED_FROM_WMS` |
| Batch (via `cancelPositions`) | **N per-order enqueues — there is no batch-level POST.** The batch-scoped variant (`aggregate_type='CUSTOMER_ORDER_BATCH'`) died with `cancelBatch`, SBDEV-3354 | same URL key | same |
| Deferred cancel (via `PickingorderBusinessService`) | per-order enqueue, `aggregate_type='CUSTOMER_ORDER'` | same URL key | same |

⚠ **`ORDER_BATCH_CANCELLED_FROM_WMS` has two producers, and `process_type` alone does not tell them apart** — both write the same value, so the discriminator is `aggregate_type`, and both surviving producers write `'CUSTOMER_ORDER'`. There was a third: `cancelBatch`, the only writer of `aggregate_type='CUSTOMER_ORDER_BATCH'` with this process type, deleted under SBDEV-3354. *Deriving method:* `git grep -n "ORDER_BATCH_CANCELLED_FROM_WMS" -- 'src/main/**'` on the SBDEV-3354 branch, discounting the `WmsConstants` declaration (2026-09-14); the same grep on `origin/develop` returns three.

Both producers write an `outbox_message` row **inside** the cancel transaction (`OutboxService.enqueue` is `@Transactional(propagation = Propagation.MANDATORY)`, ending in `repo.save(msg)`); `OutboxDispatchService` POSTs it afterwards. If the cancel rolls back, the row rolls back with it and OMS is never told — the same guarantee the older `TransactionSynchronizationManager.registerSynchronization` callbacks gave, now enforced by the transaction rather than by a callback. Neither `CustomerorderService` nor `PickingorderBusinessService` still calls `registerSynchronization` or `sendAfterCommit` on this path; *positive control:* 7 other `src/main` services do use `registerSynchronization`, so the grep works. `Club_Order_Cancellation_OMS_Fix` is the archived bug from the pre-outbox era, where a callback fired *before* commit and made OMS reflect a cancel WMS later did not persist.

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

All cancel *service* methods are `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` — one order's cascade succeeds atomically or rolls back. **The transaction boundary is the order, not the batch.** `OrderRestController.cancelPositions` carries no `@Transactional` of its own; it loops `cancelOrder`, so an N-order batch is N independent transactions (§5).

No `REQUIRES_NEW` is used in the cancel path (contrast with `OrderReleaseJob` / `ReplenishOrderJob` — see [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §4). An exception mid-cascade rolls back **that order's** cancel whole, so no single order is ever left half-cancelled. It does **not** roll back the batch: since SBDEV-3339 a `ToteTeardownException` is contained to its own order and the loop continues, so a partially-cancelled batch is an expected outcome rather than corruption — the uncancelled orders are simply still cancellable. See §5 and §10 item 4.

Optimistic locking (`AbstractBaseEntity.version`) guards every entity save; there is **no** automatic retry inside cancel paths — and as of SBDEV-3398 (2026-09-17) there is no retry utility in the codebase at all, `OptimisticLockRetry` having been deleted. If a concurrent pick update fires a `@Version` bump mid-cancel, the cancel transaction rolls back and the caller must retry.

---

## 9. Guardrails for `forceCancelOrder`

`forceCancelOrder` at `CustomerorderService:323` (method declaration; `customerOrder.setState(CANCELED)` write at line 351; `pickingOrder.setState(PICKED)` at line 356) is the escape hatch for orders that normal cancel refuses (because they're `PACKED`, `PALLETIZED`, or already have physical work downstream). Rules for use:

1. Admin-only — never expose to operators.
2. Always writes `Customerorder.state = CANCELED` regardless of prior state.
3. Writes `Pickingorder.state = PICKED` (line 356) — a deliberately unusual choice: the physical work is done, the order is cancelled, but the pick itself stays terminal-success so downstream repack / restock flows see consistent state.
4. Does **not** unwind the `PickingorderUnitload` cascade the way `cancelOrder` does — the force path trusts the caller has reviewed child state.
5. **Releases the transfer lane** (fix `260629`, 2026-06-29): a guarded `setTransferlaneId(null)` before the final save, so a force-cancelled transfer order frees its lane. Direct clear only — never `unlinkTransferLaneFromTransferOrder` (which would reset state to `505`).
6. **Clears `markedforcancellation`** (SBDEV-3332, 2026-09-15): `customerOrder.setMarkedforcancellation(false)` beside each `setState(CANCELED)`. Before this, `forceCancelOrder` was a live producer of orders that are cancelled *and* still flagged — residue that reads as "a cancel is pending" forever. Both branches carry the line, the dead `< PACKED` one included, so the invariant holds by construction rather than by which arm runs.
7. ⚠ **It notifies OMS of NOTHING.** `git grep -n "ORDER_BATCH_CANCELLED_FROM_WMS" -- src/main` (2026-09-15) returns exactly two enqueue sites — `CustomerorderService.cancelOrder` and `PickingorderBusinessService.cleanUpCancelledOrder` — and `forceCancelOrder` is neither: it sets `CANCELED`, saves, and never touches the outbox. So for a **force-cancelled order the cancellation signal count is zero**, not one. This is pre-existing and long-standing, and it is the single largest hole in the cancellation-signal story: an OMS reconciliation will show these orders open on the OMS side indefinitely. Proposed as its own ticket under SBDEV-3332; not fixed there.

⚠ The `CustomerorderService:323 / 351 / 356` citations above have **drifted** — the method now declares at `:408` and the two writes sit in the two `else if` arms. Grep the method name, not the line.

---

## 10. Known Landmines

1. **`CANCELED` vs `CANCELLED` spelling.** Integer state is `CANCELED` (one L). String state is `CANCELLED` (two). A guard `.equals("CANCELED")` on an advice always returns false. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §2.2.
2. **Rapid-pick side-door** (§7). Don't remove without reviewing `Cancel_Order_Null_SectionId_And_Early_Return_Fix`.
3. **`PACKED`/`PALLETIZED` early-return guard** (`CustomerorderService:382,554`). Blocks normal cancel so downstream physical state stays consistent. `Cancel_Club_Parcels_Packed_State_Fix` restored this after it was accidentally removed.
4. **A batch cancel is NOT atomic across its orders.** `cancelPositions` opens one transaction *per order*, so a batch can end up partially cancelled — by design since SBDEV-3339, which contains a tote-teardown failure to the one order that hit it. Do not carry over the old assumption that a batch cancel is all-or-nothing; that came from `cancelBatch`, which was deleted under SBDEV-3354 and, on a whole-history caller search, never ran at all. See §5.
5. **`finalizeBatchIfComplete` is a *consequence*, not a trigger.** Don't call it directly as if it were a cancel entry point.
6. **~~OMS callback activation is OFF by default~~ — WITHDRAWN 2026-09-15 (SBDEV-3332).** ⚠ **This sysprop gates NOTHING in v2** (verified 2026-09-15, SBDEV-3332): `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED_KEY` has exactly two references in `src/main` — its own declaration in `WmsConstants` and a **commented-out** seed line in `UtilRestController` — so no code reads it. v2 enqueues `ORDER_BATCH_CANCELLED_FROM_WMS` **unconditionally**. Cancels are NOT silent by default, and flipping this to `true` changes nothing. (v1 does read it; do not carry the v1 behaviour across.)
7. **`forceCancelOrder` sets `Pickingorder=PICKED`, not `CANCELED`** (§9 item 3). Queries that filter `Pickingorder.state=CANCELED` will miss force-cancelled orders.
8. **`forceCancelOrder` sends OMS no cancellation at all** (§9 item 7). A reconciliation counting `ORDER_BATCH_CANCELLED_FROM_WMS` against cancelled orders will find force-cancelled ones missing, and the cause is not a lost message — none was ever produced.
9. **`ORDER_BATCH_CANCELLED_FROM_WMS` is deduplicated per order, for 7 days — but only for SENT rows** (SBDEV-3332). Both real emitters key it `CO-CANCELLED-<customerorderId>` and `outbox_message.idempotency_key` is UNIQUE, so a second row is refused — but the purge is `WHERE status = 'SENT'`, so the key is freed after 7 days only for a cancel that SUCCEEDED — a row left `FAILED_TERMINAL` (never auto-deleted) or stalled in `PENDING`/`FAILED_RETRY` holds the key until an operator clears it, and every later cancel of that order then rolls back on the constraint. Do not read the key as a permanent ledger of "was this order's cancel ever sent".
10. **Optimistic-lock retry is NOT automatic.** Cancel transactions that race with concurrent picks simply fail and bubble up — the caller is responsible for retry. See [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8.3.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| "Order cancelled but Pickingorder still live" | §7 side-door + §10 item 2 |
| "OMS never received the cancel" | §6 + `outbox_message` rows keyed `CO-CANCELLED-<id>` + §10 items 6/8/9. ⚠ Do NOT chase the `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` sysprop — it is inert in v2. If the order was force-cancelled, no message was ever produced (§9 item 7). |
| "Can't cancel — 'order in PACKED state'" | §4 guard + §9 forceCancelOrder path |
| "Batch partially cancelled, some orders still active" | §5 + §10 item 4 — **expected since SBDEV-3339, not corruption.** The response's per-order `errors` map and the `cancelPositions: tote teardown failed for order=...` ERROR log name the orders that did not cancel; re-issue `cancelPositions` for those. §8 is the right section only if a *single order* is internally inconsistent. |
| "forceCancel left Pickingorder=PICKED" | §10 item 7 (expected) |
| "Optimistic lock during cancel" | §10 item 8 — conflict surfaces at commit → HTTP 409 (`RestExceptionHandler`); caller retries. (Retry is never applicable inside a transaction — the exception fires at the outer commit, outside any retry loop. The `OptimisticLockRetry` utility this row used to name was deleted by SBDEV-3398.) |

---

## 12. Verification Log

| Date | By | Scope | Result |
|---|---|---|---|
| 2026-09-15 | SBDEV-3332 | `cancelOrder` / `forceCancelOrder` / `cleanUpCancelledOrder` flag lifecycle + the OMS cancel emitters | §9 gained items 6–7; §10 items 6, 8, 9 added or withdrawn. Corrected: the activation sysprop is inert in v2 (2 refs, one commented out); `forceCancelOrder` emits no OMS cancellation; the two real emitters now share `CO-CANCELLED-<id>`. ⚠ §9's `CustomerorderService:323/351/356` citations are drifted — grep the method name. |

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | All 6 cancel entry points (cancelOrder / forceCancelOrder / handleRapidPickingForCancelledOrder / cancelBatch / finalizeBatchIfComplete / cancelOrderIfMergeFails); guard locations (lines 180, 382, 471, 550, 554, 639); OMS callback sysprop default. *(2026-09-14, SBDEV-3354: the "6 entry points" framing was never accurate — see §2 — and `cancelBatch` in this list had no caller even on the date of this row.)* | All file:line refs confirmed against `src/main/java` | Code read + state-machine architecture doc |
| 2026-05-08 | `CustomerorderService.cancelOrder` method now starts at line 588 (was cited as 300) — write of `customerOrder.setState(CANCELED)` is at line 675; `forceCancelOrder` method declaration line 323; rapid-pick guard line 639 + setState write line 645 — all updated. Group X parcel-cancel port (v1 `46130c3` → v2 `e2b82ed`) lives in `unifyScanParcelCancelMessage` user-message path — no impact to cancel-cascade map. Picking-flow follow-up commits (Group P) didn't touch the cancel cascade entry points. SBDEV-2214 changes intentionally NOT pre-documented per audit constraint. | All file:line refs updated; cascade story unchanged. | Code read + state-machine architecture doc |
| 2026-09-14 | **SBDEV-3339.** Two false claims corrected: §5's batch diagram said `cancelBatch` *"release[s] entity locks (so stock is returnable)"* — it releases none; and §2's entry-point table gave `cancelBatch` a trigger of *"REST `/clubLine/...` + admin"* — it has no route and no caller at all. Both mattered because together they told a reader the SBDEV-3339 stranding defect was already handled. **Scope: these two claims only.** Six further inaccuracies (D-3…D-8, catalogued in that ticket's evidence) are real but do not assert the defect fixed, and the pervasive line-number drift noted in the 2026-06-29 row is still unaudited — so `last_verified` stays at 2026-05-08 rather than implying a full re-sweep. | `git grep` on `origin/develop` with positive controls (0 `setEntityLock` in `CustomerorderBatchService` vs 4 in `CustomerorderService`; 1 `src/main` vs 54 `src/test` occurrences of `cancelBatch`) | SBDEV-3339 implementation |
| 2026-09-15 | **SBDEV-3363.** New §4.1: `CANCELED(800)` must not count as "beyond PACKED" when asking whether a position blocks its order's cancel. Four sites express that rule; two (`canOrderPositionBeCancelled`, `cancelOrderPosition`) get it wrong and are **deliberately left wrong** — the fix skips already-CANCELED positions in `cancelOrder`'s two loops instead, because relaxing the helpers routes a `PICKED(600)` pick line into `cancelOrderPosition`'s wider `< PACKED` bound and flips it. **Scope: §4.1 only** — the guard table above it is unchanged and the line-number drift flagged in the 2026-06-29 row is still unaudited, so `last_verified` stays at 2026-05-08. | Estate census over all six v2 tenant DBs (3 orders at `co.state <> 800` owning a CANCELED position, all on wms2-wineco-dev, zero elsewhere each with a positive control); the rejected design measured red on exactly one of three test fixtures | SBDEV-3363 implementation |
| 2026-09-14 | **SBDEV-3354.** `CustomerorderBatchService.cancelBatch` deleted as unreachable dead code, so §2's entry-point row, §5 in full, §6's batch-callback row and §10 item 4 are rewritten rather than re-corrected. §2's "six methods" count replaced with a derivation rule — the table had seven rows the whole time. **Scope: the `cancelBatch` claims and the §6 producer discriminator only.** The line-number drift flagged in the 2026-06-29 row is still unaudited, so `last_verified` stays at 2026-05-08. ⚠ Note this change is **itself** a new drift source for one file: deleting 134 lines at `:398` shifts every `CustomerorderBatchService` citation below it by −134. §3's and §4's two references to that file were re-derived here and converted to quoted snippets so they relocate themselves; no other file is affected. | `git grep` on `origin/develop` (1 `src/main` occurrence → 0; 54 `src/test` → 0) plus a runtime check: Hydra PRD `outbox_message` holds 0 rows of `aggregate_type='CUSTOMER_ORDER_BATCH'` + `process_type='ORDER_BATCH_CANCELLED_FROM_WMS'`, the pair only `cancelBatch` wrote; positive control 3 rows of the same process type under `CUSTOMER_ORDER`, 84 rows in the table. Blind spot: that table only reaches back to 2026-07-13. | SBDEV-3354 implementation |
| 2026-06-29 | Fix `260629-transfer-lane-leak-on-cancel`: `cancelOrder` and `forceCancelOrder` now clear `transferlaneId` for transfer orders (guarded direct `setTransferlaneId(null)` before save) — documented in §3 and §9. **Scope: transfer-lane behavior only** — the pre-existing line-number drift in this doc (cancelOrder now at 651, `setState(CANCELED)` at 750, save at 754; forceCancelOrder at 349, save at 438) was observed but NOT fully re-audited, so the frontmatter `last_verified` is left at 2026-05-08. Interaction with `finalizeBatchIfComplete` verified safe (same managed entity, one tenant TX, idempotent second clear → single flush). | Transfer-lane release confirmed by 143-test green run + code review (SHIP); full doc re-sweep still pending. | Fix `260629` implementation + code review |

**Re-verify every 60 days.** Next due: **2026-07-07** — cancel is a high-traffic fix surface; any new landed plan touching `CustomerorderService` or `CustomerorderBatchService` should trigger a re-sweep.
