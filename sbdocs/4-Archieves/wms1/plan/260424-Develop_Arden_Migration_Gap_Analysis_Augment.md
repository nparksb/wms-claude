# Develop-Arden Migration Gap Analysis — Augment Review

**Date**: 2026-03-25  
**Current Branch**: `tmp/np05-cancel-club-to-packed--state`  
**Source Branch**: `tmp/np03-develop-arden-migration`

---

## Executive Verdict

The original plan is **directionally correct**: the current branch is still missing important behavior from `tmp/np03-develop-arden-migration`, and **manual phased porting** is the right approach.

However, the plan needs several important corrections before it is used as an implementation checklist:

1. **The scope is 11 commits, not 10.** The source branch has an omitted commit: `a5af9fa`.
2. **`31b57d6` is not “missing entirely”.** Parts of its low-level cleanup logic are already present on the current branch, but the feature is still **critically incomplete** because the packed-order cancel path is not wired in and batch cancellation is still shallow.
3. **`7b4b258` is only partially missing.** The `runClubLine` batch-state guard is already present on the current branch; the missing pieces are the **save-ordering fix** and the **OMS payload filter** in `cancelBatch()`.
4. **The BOL “modified sort” item is partially present.** The repository native query already orders by `b.modified desc`, but the controller default still uses `created` when no sort is specified.
5. **`a5af9fa` does not create a new major porting phase.** Its substantive fixes are already present in the current branch’s `CustomerorderBatchService` / `ManageOrderService` logic.

Bottom line: the plan is useful, but its **commit statuses and porting order should be corrected** before implementation starts.

---

## Corrected Commit Status Table

| Commit | Description | Corrected Status | Review Action |
|---|---|---|---|
| `a5af9fa` | Partial-cancel / runClubLine bug fixes | **Omitted from original list; mostly already present** | Track in review, but no separate port phase needed unless a residual diff is found |
| `eee8988` | Cancelled-order filtering | **Partially reimplemented** | Port missing repository SQL filters |
| `83cd541` | Review doc only | **Skip** | No action |
| `388e78b` | Tote/pickingorder disconnect fix | **Already ported** | No action |
| `660b9d6` | Mobile picking transactional + pessimistic locking | **Missing** | Port |
| `2a0eda3` | Finalize batch / auto release lane logic | **Partially present inline** | Extract and reuse `finalizeBatchIfComplete()` |
| `26a0a26` | Follow-up merge race fixes | **Missing** | Port with `660b9d6` |
| `31b57d6` | Cancel PACKED orders + child cleanup | **Partially ported, still critical** | Port remaining wiring and batch cleanup |
| `7b4b258` | Save ordering + relaxed batch guard + OMS filter | **Partially ported** | Port remaining save-ordering and OMS filter only |
| `a8c617f` | Develop/develop-arden feature migration | **Partially present** | Port selected missing features |
| `5076baf` | Additional develop-arden fixes | **Partially present** | Port selected missing features |

---

## Code-Backed Findings

### 1) Cancelled-order filtering: service layer is ahead of repository layer

The original plan is correct that the current branch already contains **service-layer filtering** in club-line related flows.

Confirmed current-branch evidence:

- `CustomerorderBatchService` already filters cancelled orders in club-line related methods.
- `ManageOrderService.customerOrderReleaseForPicking()`, `customerOrderPickingStarted()`, and `customerOrderPicked()` already remove cancelled orders before building OMS messages.

But the plan is also correct that the **SQL layer is still incomplete**. The current branch still lacks cancelled-order filters in these repository queries:

- `CustomerorderBatchRepository.getActiveClubBatch()`
- `CustomerorderBatchRepository.findByStateAndType()`
- `CustomerorderBatchRepository.findByStateAndTypeAndKeywordPage()`
- `CustomerorderBatchRepository.getOrderContentsByBatchId()`
- `CustomerorderPositionRepository.findByOrderBatchId()` (the `MIN(c.id)` subquery still ignores cancelled orders)
- `CustomerorderRepository.getOrderViewsByBatchId()`

### Review conclusion

This part of the plan is **approved**. The current branch needs the repository/query-level ports from `eee8988` to avoid incorrect counts, ghost rows in views, and order-detail mismatches.

---

### 2) Cancel-PACKED-order feature: partially ported, but still not usable end-to-end

This is the most important correction to the original plan.

The current branch already contains a **PACKED/PALLETIZED branch inside** `CustomerorderService.forceCancelOrder()`. That branch unlocks the parcel-side unitload/stock and sends the parcel to clearing. So the low-level cleanup logic is **not absent**.

But the feature is still incomplete in the places that matter operationally:

- `CustomerorderService.forceCancelOrder()` is still **`private`**.
- `CustomerorderService.cancelOrder()` still throws for any order with `state >= PACKED`; it does **not** delegate to `forceCancelOrder()` for WMS-originated cancellations.
- `CustomerorderBatchService.cancelBatch()` still rejects batches containing orders in `PACKED..CANCELED-1`.
- `CustomerorderBatchService.cancelBatch()` still performs only **shallow parent-state cancellation**; it does not cancel:
  - `CustomerorderPosition`
  - `PickingorderPosition`
  - `Pickingorder`
  - `PickingorderUnitload`
  - tote links / history / reservation cleanup

### Review conclusion

The plan’s **priority** is correct, but the **status wording is wrong**. `31b57d6` should be treated as **partially ported / critically incomplete**, not “missing entirely”.

---

### 3) Batch finalization and lane release are still fragmented

The current branch still uses **inline batch finalization logic** inside `CustomerorderService.cancelOrder()`.

Missing pieces from the source branch family (`2a0eda3` + `7b4b258`):

- no reusable `CustomerorderBatchService.finalizeBatchIfComplete()` method
- no reuse from `cancelBatch()` / packed-order force cancel path
- no `transferlaneId` cleanup in the shared finalization path
- the order is still saved **after** the inline “all orders finished?” re-read, so the current code still carries the save-ordering bug fixed by `7b4b258`
- `cancelBatch()` still includes already-cancelled orders in the OMS cancel payload

One correction to the original plan: the current branch’s `runClubLine()` already accepts both:

- `ORDER_BATCH_ACTIVATED (520)`
- `ORDER_BATCH_STAGING_LANE_ASSIGNED (525)`

So that part of `7b4b258` is already present and does **not** need re-porting.

### Review conclusion

The structural recommendation to extract batch finalization is **strongly approved**. This should be implemented together with the remaining `31b57d6` / `7b4b258` ports.

---

### 4) Merge/picker race condition ports are still missing

The current branch has complementary locking in `PickingorderBusinessService.confirmPick()`, but the source-branch protections around **selection / merge / controller retry behavior** are still absent.

Confirmed current-branch gaps:

- `PickingorderRepository.findByIdForUpdate()` exists, but `MobilePickingService.selectAndReservePickingOrder()` still uses plain `findById()`.
- `MobilePickingService.processPick()` is transactional, but the broader source-branch locking pattern is not fully ported.
- `PickingController` still catches `BusinessException` / `FacadeException` only; it does not handle optimistic/pessimistic locking failures from the source branch.
- `ReplenishOrderJob.mergePickingOrders()` still uses plain `pickingorderRepository.findById()`.
- `ReplenishorderRepository` does not contain the follow-up locking support expected by the source review commit.

### Review conclusion

The plan is **correct** to keep both approaches:

- current-branch `confirmPick()` locking for the **completion race**, and
- source-branch `MobilePickingService` / merge locking for the **assignment / merge race**.

These are complementary, not redundant.

---

### 5) Omitted commit `a5af9fa`: important to track, but largely already absorbed

The original plan missed `a5af9fa` completely.

I reviewed its diffs and compared them to the current branch. Its substantive fixes are already present on the current branch, including:

- filtering cancelled orders before stock calculations / OMS batch messages
- `@Transactional` on `runClubLine()`
- zeroing `requiredAmount` after exact/greater-than stock transfer branches
- throwing when a club-line position remains partially unfulfilled
- re-checking reloaded order state before promoting to `PACKED`
- skipping cancelled positions during final state promotion

### Review conclusion

The plan should mention `a5af9fa`, but it does **not** require a separate implementation phase. Treat it as **already substantially reimplemented**.

---

### 6) Develop-branch migration bundle (`a8c617f` + `5076baf`): keep, but correct a few statuses

I spot-checked the higher-signal items from the grouped migration commits.

Confirmed missing or still incomplete on the current branch:

- `LocationController` is still **read-only** (`detailView`, `locationDetailsById`) — no create/update endpoints.
- `MobilePalletizingService` still treats `state >= FINISHED` as a generic “already finished” block; it does not have the refined cancelled-parcel validation from the source branch.
- `ParcelMonitorViewRepository` / `ReportController.parcelMonitorView()` still have no palletized/unpalletized filter parameter.
- `UserController` still has create/update/import endpoints, but no bulk user edit endpoint matching the source migration.
- `StockunitService` still has duplicate `triggerReplenishmentMaintenance()` calls in multiple methods.

One important correction:

- `BillofladingRepository.findByStatesAndKeyword()` already has `order by b.modified desc`, so the BOL sort change is **not fully missing**.
- But `BillOfLadingController.openBol()` / `closedBol()` still default to `Sort.Order.desc("created")` when no sort is provided.

### Review conclusion

Keep the migration bundle in the plan, but mark the BOL sort item as **partial**, not fully missing.

---

## Revised Porting Order

### Phase 1 — Club cancellation correctness (highest priority)

Implement these together because they are tightly coupled:

1. Port the missing repository SQL filters from `eee8988`
2. Port the **remaining** `31b57d6` behavior:
   - make `forceCancelOrder()` reusable
   - delegate from `cancelOrder()` for WMS-originated packed-order cancellation
   - relax `cancelBatch()` guard to `>= FINISHED`
   - add full child-entity cleanup in `cancelBatch()`
3. Port the `2a0eda3` structural extraction:
   - introduce `finalizeBatchIfComplete()`
   - clear both `staginglaneId` and `transferlaneId` in the shared finalization path
4. Port the remaining `7b4b258` fixes:
   - save the order before batch-finalization re-read
   - exclude already-cancelled orders from OMS batch-cancel payloads

### Phase 2 — Merge/picker race protections

Port `660b9d6` + `26a0a26` together:

1. `@Transactional` and `findByIdForUpdate` usage in `MobilePickingService`
2. lock-failure handling in `PickingController`
3. merge-loop locking updates in `ReplenishOrderJob` / related repository code

### Phase 3 — Additive feature migrations

Then port the additive UI/service features from `a8c617f` + `5076baf`:

- Location CRUD
- palletizing validation refinements
- parcel monitor filter
- user bulk edit
- remaining replenishment / advice / view-layer improvements
- cleanup of duplicate replenishment-maintenance triggers

---

## Recommended Test Gates

Before considering the migration complete, add or port tests for these exact behaviors:

1. **Packed order cancellation from within WMS**
   - `cancelOrder(..., true)` on a `PACKED` club order succeeds
   - child entities are cleaned up
   - batch finalization releases lanes

2. **Batch cancellation with mixed active/cancelled orders**
   - OMS payload excludes already-cancelled orders
   - remaining orders and child entities are fully cancelled

3. **Partial-cancel club run**
   - cancelled orders do not create ghost parcels
   - cancelled positions are not promoted to `PACKED`
   - insufficient stock fails fast

4. **Merge/picker concurrency regression**
   - concurrent reserve/merge paths do not double-assign or corrupt state

5. **Repository integration tests for cancelled-order filtering**
   - batch counts, detail views, and batch-content queries exclude cancelled orders where intended

---

## Final Assessment

Use the original document as a **starting point**, not as the final implementation checklist.

The most important corrections are:

- count **11** source commits, not 10
- treat `31b57d6` as **partially ported but still critical**
- treat `7b4b258` as **partially ported**
- record `a5af9fa` as **omitted but largely already absorbed**
- mark the BOL modified-sort change as **partial**, not fully missing

With those corrections, the plan becomes a solid basis for phased manual porting.