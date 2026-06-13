# Auto-Release Club & Transfer Lane When Batch Reaches Final State

- **Date:** 2026-03-20 (Updated: 2026-03-21 — V2 implementation complete; Archived: 2026-05-21 — all commits confirmed on develop, 8/11 fixes applied, 3 deferred by design)
- **Status:** V2 Implemented — Fixes #1-#4, #6-#9, NEW-1 applied (8 fixes). 11 new tests added, 3739 tests pass (0 failures, 38 pre-existing H2/integration errors). Fix #5, NEW-2, NEW-3 deferred as follow-up.
- **Priority:** Critical
- **V1 Source:** Original plan implemented in v1; v2 codebase has none of these changes.

---

## V2 Analysis Summary

Deep code analysis confirmed that **none of the 9 fixes from the v1 plan have been applied to the v2 codebase**. The plan's "Done" status reflects v1 implementation only.

**Partial good news:** The v2 inline batch-check code in `cancelOrder()` (lines 590-597) and `cleanUpCancelledOrder()` (lines 690-697) already includes `staginglaneId(null)` clearing and CANCELED/FINISHED distinction — better than the v1 bug description. However, the architectural refactor to a shared method, child entity cleanup, force-cancel delegation, and transfer lane cleanup are all missing.

**3 new issues discovered:**
1. `PickingorderBusinessService.java:332-339` — 4th copy of inline batch finalization (not in original plan)
2. `BillofladingService.closeBOL()` — Bulk batch finalization doesn't distinguish CANCELED vs FINISHED
3. `BillofladingService.transferOrder():762-765` — Unconditionally sets batch to ORDER_BATCH_CLUB_RUN_FINISHED for a single order (premature finalization)

---

## Post-Deployment Issue (from v1)

**Problem:** After club/transfer orders are cancelled, lanes are STILL not released. Order batches remain in state "Activated" (520) holding the staging lane.

**Root cause:** The `finalizeBatchIfComplete()` method doesn't exist. Batch finalization logic is copy-pasted across 4+ code paths with inconsistent behavior. Three specific gaps:

1. **`cancelBatch()` is incomplete** — sets `Customerorder.state = CANCELED` but does NOT cancel `CustomerorderPosition`, `PickingorderPosition`, `Pickingorder`, or `PickingorderUnitload`. Leaves orphaned child entities.

2. **`cancelOrder()` cannot cancel PACKED club orders** — after `runClubLine()` sets positions to PACKED (650), the guard at line 528 throws. Orders go down `markedforcancellation` path where state is never set to CANCELED, blocking batch finalization.

3. **`cancelBatch()` is blocked post-club-run** — the guard at line 217 (`state >= PACKED && < CANCELED`) rejects the entire batch.

---

## V2-Specific Adaptation Notes

1. **Transaction manager:** `@Transactional(value = "tenantTransactionManager", ...)` — never bare `@Transactional`
2. **Constructor injection:** Add new dependencies as constructor parameters, not `@Autowired` fields
3. **`orElseThrow` pattern:** Use `.orElseThrow(() -> new EntityNotFoundException(...))` instead of `.get()`
4. **SLF4J parameterized logging:** `LOG.debug("message={}", var)` — not string concatenation
5. **`cancelOrder` parameter:** v2 uses `cancellationFromWithinWMS` boolean (not `force`) — Fix #8 must use this parameter

---

## Data Model

- **`CustomerorderBatch.staginglaneId`** (Long) — points to a `Location` flagged as `staginglane=true`
- **`Customerorder.transferlaneId`** (Long) — points to a `Location` flagged as `transferlane=true`
- **Staging lane availability** (`LocationRepository.getAvailableStagingLanes`) — lane is "occupied" if any batch with `state < 530` points to it. **This is the operational blocker.**
- **Transfer lane availability** (`LocationRepository.getAvailableTransferLanes`) — lane is "occupied" if any order with `state < FINISHED (700)` points to it. Stale references don't block availability.

---

## Duplicated Batch Finalization Code (4 locations + 1 bulk)

| # | File:Lines | Method | Pattern | Missing Pieces |
|---|-----------|--------|---------|----------------|
| 1 | `CustomerorderService.java:590-597` | `cancelOrder()` | Individual | No transferlaneId cleanup, inline |
| 2 | `CustomerorderService.java:690-697` | `cleanUpCancelledOrder()` | Individual | No transferlaneId cleanup, inline |
| 3 | `PickingorderBusinessService.java:332-339` | `cleanUpCancelledOrder()` | Individual | No transferlaneId cleanup, inline (**NEW — not in v1 plan**) |
| 4 | `BillofladingService.java:677-707` | `closeBOL()` | Bulk JPQL | No CANCELED distinction, no transferlaneId cleanup |
| 5 | `CustomerorderBatchService.java:280-288` | `cancelBatch()` | Direct set | No transferlaneId, no child entity cleanup |

---

## Fix Plan (V2)

### Fix #1 — Extract shared `finalizeBatchIfComplete(Long batchId)` method (Critical — prerequisite)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`

Add a new public method. `CustomerorderRepository` is already injected.

```java
/**
 * Checks if all orders in the batch have reached a final state (FINISHED or CANCELED).
 * If so, sets batch to CANCELED (if all canceled) or FINISHED (if any completed),
 * releases the staging lane, clears transfer lanes on orders, and saves.
 * Reloads batch from DB to avoid stale entity issues.
 */
public void finalizeBatchIfComplete(Long batchId) {
    CustomerorderBatch batch = customerorderBatchRepository.findById(batchId).orElse(null);
    if (batch == null) {
        return;
    }
    List<Customerorder> orders = customerorderRepository.findByOrderbatchId(batchId);
    if (orders.isEmpty()) {
        return;
    }
    boolean allFinal = orders.stream().allMatch(o -> o.getState() >= WmsConstants.State.FINISHED);
    if (allFinal) {
        boolean allCanceled = orders.stream().allMatch(o -> o.getState() == WmsConstants.State.CANCELED);
        batch.setState(allCanceled ? WmsConstants.State.CANCELED : WmsConstants.State.FINISHED);
        batch.setStaginglaneId(null);
        customerorderBatchRepository.save(batch);

        for (Customerorder order : orders) {
            if (order.getTransferlaneId() != null) {
                order.setTransferlaneId(null);
                customerorderRepository.save(order);
            }
        }
    }
}
```

---

### Fix #2 — Fix `cleanUpCancelledOrder()` in CustomerorderService (Critical)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Location:** Lines 690-697

**Prerequisite:** Inject `CustomerorderBatchService` via constructor (no circular dependency — verified).

Replace inline batch check:
```java
// CURRENT (lines 690-697):
CustomerorderBatch orderBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId()).orElseThrow(...);
List<Customerorder> orders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
if (orders.stream().allMatch(o -> o.getState() >= WmsConstants.State.FINISHED)) {
    boolean allCanceled = orders.stream().allMatch(o -> o.getState() == WmsConstants.State.CANCELED);
    orderBatch.setState(allCanceled ? WmsConstants.State.CANCELED : WmsConstants.State.FINISHED);
    orderBatch.setStaginglaneId(null);
    customerorderBatchRepository.save(orderBatch);
}

// FIXED:
customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
```

---

### Fix #3 — Refactor `cancelOrder()` in CustomerorderService (Critical)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Location:** Lines 590-597

Replace inline batch check with:
```java
customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
```

---

### Fix #4 — Add transfer lane cleanup to `cancelBatch()` (High)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
**Location:** Lines 280-283 (inside the order cancellation loop)

**Note:** Fix #7 subsumes this — if Fix #7 is implemented, `setTransferlaneId(null)` is included in its code block.

```java
// CURRENT:
for (Customerorder customerOrder : batchOrders) {
    customerOrder.setState(WmsConstants.State.CANCELED);
    customerorderRepository.save(customerOrder);
}

// FIXED (minimal — or subsumed by Fix #7):
for (Customerorder customerOrder : batchOrders) {
    customerOrder.setState(WmsConstants.State.CANCELED);
    customerOrder.setTransferlaneId(null);
    customerorderRepository.save(customerOrder);
}
```

---

### Fix #5 — Refactor `closeBOL()` batch finalization (Recommended — follow-up)

**File:** `src/main/java/net/aim_ai/wms/service/BillofladingService.java`
**Location:** Lines 677-707

**Current behavior:** Bulk JPQL update that always sets batch to FINISHED. Missing CANCELED distinction and transferlaneId cleanup.

**Options:**
- **A:** Replace with per-batch calls to `finalizeBatchIfComplete()` (simpler, consistent, but loses bulk optimization)
- **B:** Keep bulk approach but add CANCELED distinction and transferlaneId cleanup in JPQL
- **C:** Leave as-is (follow-up)

**Recommendation:** Option A for correctness. Batch sizes are small (4-20 orders), so the performance difference is negligible.

**Prerequisite:** Inject `CustomerorderBatchService` into `BillofladingService` (not currently present). Check for circular dependency first.

---

### Fix #6 — Add batch check to `forceCancelOrder()` (Defensive → Critical with Fix #8)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Location:** After line 393 (`customerorderRepository.save(customerOrder)`)

```java
if (customerOrder.getOrderbatchId() != null) {
    customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
}
```

**Note:** Once Fix #8 makes `forceCancelOrder()` reachable from `cancelOrder()`, this becomes critical — without it, PACKED orders cancelled via force path won't trigger batch finalization.

---

### Fix #7 — Make `cancelBatch()` cancel all child entities (Critical)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
**Location:** Replace lines 280-283

**Missing dependencies to add via constructor:**
- `PickingorderUnitloadService` — NOT currently injected
- `PickingorderUnitloadRepository` — NOT currently injected

**Already injected:** `PickingorderPositionRepository` (line 39), `PickingorderRepository` (line 41), `StockunitRepository` (line 53), `StockunitBusinessService` (line 59), `UnitloadRepository` (line 51)

Replace the simple order cancellation loop with comprehensive child entity cleanup:

```java
for (Customerorder customerOrder : batchOrders) {
    customerOrder.setState(WmsConstants.State.CANCELED);
    customerOrder.setTransferlaneId(null);
    customerorderRepository.save(customerOrder);

    // Cancel all order positions
    List<CustomerorderPosition> coPositions = customerorderPositionRepository.findByOrderId(customerOrder.getId());
    for (CustomerorderPosition position : coPositions) {
        position.setState(WmsConstants.State.CANCELED);
        customerorderPositionRepository.save(position);

        // Cancel associated picking positions and release reserved stock
        List<PickingorderPosition> pickPositions = pickingorderPositionRepository.findByCustomerorderpositionId(position.getId());
        for (PickingorderPosition pickPos : pickPositions) {
            if (pickPos.getState() < WmsConstants.State.PICKED && pickPos.getPickfromstockunitId() != null) {
                Stockunit stockUnit = stockunitRepository.findById(pickPos.getPickfromstockunitId()).orElse(null);
                if (stockUnit != null) {
                    stockunitBusinessService.changeReservedAmount(stockUnit, pickPos.getAmount().negate(),
                        true, WmsConstants.CODE_CANCELLED_ORDER_FROM_WEBSERVICE, pickPos.getNumber(), null);
                }
                pickPos.setPickfromstockunitId(null);
            }
            pickPos.setState(WmsConstants.State.CANCELED);
            pickingorderPositionRepository.save(pickPos);
        }
    }

    // Cancel picking orders that have all positions canceled
    Set<Long> pickingorderIds = new HashSet<>();
    for (CustomerorderPosition position : coPositions) {
        for (PickingorderPosition pp : pickingorderPositionRepository.findByCustomerorderpositionId(position.getId())) {
            pickingorderIds.add(pp.getPickingorderId());
        }
    }
    for (Long poId : pickingorderIds) {
        Pickingorder po = pickingorderRepository.findById(poId).orElse(null);
        if (po != null && po.getState() < WmsConstants.State.FINISHED) {
            List<PickingorderPosition> remaining = pickingorderPositionRepository.findByPickingorderId(poId);
            if (remaining.stream().allMatch(p -> p.getState() >= WmsConstants.State.FINISHED)) {
                po.setState(WmsConstants.State.CANCELED);
                pickingorderRepository.save(po);
            }
        }
    }

    // Cancel picking unitloads and release totes
    if (customerOrder.getPickingtoteId() != null) {
        Unitload tote = unitloadRepository.findById(customerOrder.getPickingtoteId()).orElse(null);
        if (tote != null) {
            PickingorderUnitload pul = pickingorderUnitloadService.getByLabel(tote.getLabelid());
            if (pul != null) {
                pul.setHistorytote(tote.getLabelid());
                pul.setUnitloadId(null);
                pul.setState(WmsConstants.State.CANCELED);
                pickingorderUnitloadRepository.save(pul);
            }
            customerOrder.setHistorytote(tote.getLabelid());
            customerOrder.setPickingtoteId(null);
            customerorderRepository.save(customerOrder);
        }
    }
}
```

---

### Fix #8 — Enable `cancelOrder()` to handle PACKED club orders (Critical)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Location:** Before line 528 (the PACKED guard)

**V2 adaptation:** Method uses `cancellationFromWithinWMS` (not `force`). Change `forceCancelOrder()` from `private` (line 315) to package-private.

```java
// ADD before line 528:
if (customerOrder.getState() >= WmsConstants.State.PACKED && cancellationFromWithinWMS) {
    forceCancelOrder(customerOrder);
    customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
    return;
}

// EXISTING (line 528 — unchanged, now only reached when cancellationFromWithinWMS=false):
if (customerOrder.getState() >= WmsConstants.State.PACKED) {
    LOG.debug("PACKED: {}", WmsConstants.State.PACKED);
    throw new BusinessException("order is beyond status PACKED. can not be cancelled anymore");
}
```

Also change `forceCancelOrder` visibility at line 315:
```java
// CURRENT:
private void forceCancelOrder(Customerorder customerOrder) throws BusinessException, FacadeException {

// FIXED:
void forceCancelOrder(Customerorder customerOrder) throws BusinessException, FacadeException {
```

---

### Fix #9 — Adjust `cancelBatch()` guard for PACKED orders (High)

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`
**Location:** Line 217

```java
// CURRENT (blocks PACKED orders):
if (batchOrders.stream().anyMatch(customerOrder -> customerOrder.getState() >= WmsConstants.State.PACKED && customerOrder.getState() < WmsConstants.State.CANCELED)) {

// FIXED (only blocks FINISHED orders, allows PACKED):
if (batchOrders.stream().anyMatch(customerOrder -> customerOrder.getState() >= WmsConstants.State.FINISHED && customerOrder.getState() < WmsConstants.State.CANCELED)) {
```

---

### NEW-1 — Refactor `cleanUpCancelledOrder()` in PickingorderBusinessService (Medium)

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
**Location:** Lines 332-339

**Not in the original plan.** This is a 4th copy of the inline batch finalization pattern. Should also be refactored to use `finalizeBatchIfComplete()`.

**Prerequisite:** Inject `CustomerorderBatchService` into `PickingorderBusinessService`. Check for circular dependency.

Replace lines 332-339 with:
```java
customerorderBatchService.finalizeBatchIfComplete(orderBatch.getId());
```

---

### NEW-2 — Fix `closeBOL()` missing CANCELED distinction (Low)

**File:** `src/main/java/net/aim_ai/wms/service/BillofladingService.java`
**Location:** Lines 694-699

The bulk JPQL always sets batch to FINISHED. If all orders in a batch were cancelled, batch should be CANCELED.

**Fix as part of Fix #5** or as standalone JPQL enhancement.

---

### NEW-3 — Investigate `transferOrder()` premature batch finalization (Medium)

**File:** `src/main/java/net/aim_ai/wms/service/BillofladingService.java`
**Location:** Lines 762-765

`transferOrder()` unconditionally sets batch to `ORDER_BATCH_CLUB_RUN_FINISHED` and clears staging lane after a single order transfer — without checking if other orders in the batch are still active. This could prematurely finalize a batch.

**Recommendation:** Replace with `finalizeBatchIfComplete()` call, or add a check for all orders being final before setting batch state.

---

## Implementation Priority (V2)

### Phase 1 — Prerequisites & Critical (implement together)

| # | Fix | File | Description | Effort |
|---|-----|------|-------------|--------|
| #1 | `finalizeBatchIfComplete()` | `CustomerorderBatchService` | New shared method | Medium |
| #9 | PACKED guard adjustment | `CustomerorderBatchService:217` | Single-line threshold change | Low |
| #7 | Child entity cleanup in cancelBatch | `CustomerorderBatchService:280` | Replace loop + add 2 deps | High |

### Phase 2 — Callers refactored to use shared method

| # | Fix | File | Description | Effort |
|---|-----|------|-------------|--------|
| #2 | cleanUpCancelledOrder | `CustomerorderService:690` | Replace inline with method call | Low |
| #3 | cancelOrder | `CustomerorderService:590` | Replace inline with method call | Low |
| #6 | forceCancelOrder | `CustomerorderService:393` | Add finalize call | Low |
| #8 | PACKED force-cancel | `CustomerorderService:528` | Add branch + change visibility | Medium |
| NEW-1 | PickingorderBusinessService | `PickingorderBusinessService:332` | Replace inline with method call | Low |

### Phase 3 — Follow-up

| # | Fix | File | Description | Effort |
|---|-----|------|-------------|--------|
| #5 | closeBOL refactor | `BillofladingService:677` | Replace bulk JPQL with shared method | Medium |
| NEW-2 | CANCELED distinction in closeBOL | `BillofladingService:694` | JPQL or method fix | Low |
| NEW-3 | transferOrder premature finalization | `BillofladingService:762` | Replace with finalize check | Low |

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Circular dependency when injecting CustomerorderBatchService | Low | High | Verified: CustomerorderBatchService does NOT depend on CustomerorderService |
| Fix #7 child cleanup misses edge cases | Medium | Medium | Use `forceCancelOrder()` pattern as reference — it handles the same entities |
| Fix #8 force-cancel path doesn't release stock correctly | Low | High | `forceCancelOrder()` already handles stock release at lines 320-341 |
| Fix #9 allows cancelling batches with FINISHED orders | Low | Medium | Guard still blocks FINISHED (700) orders — only PACKED (650) is unblocked |
| Constructor widening in CustomerorderBatchService (Fix #7) | Low | Low | Already 22 params — consider extracting a helper service in future |
| closeBOL bulk optimization lost (Fix #5 Option A) | Low | Low | Batch sizes 4-20 orders — negligible perf difference |

---

## Testing Plan

### Unit Tests

**`CustomerorderBatchServiceUnitTest`:**
- `finalizeBatchIfComplete_allFinished_setsBatchFinished_clearsLanes`
- `finalizeBatchIfComplete_allCanceled_setsBatchCanceled_clearsLanes`
- `finalizeBatchIfComplete_mixedFinal_setsBatchFinished_clearsLanes`
- `finalizeBatchIfComplete_notAllFinal_doesNothing`
- `finalizeBatchIfComplete_clearsTransferLaneOnOrders`
- `finalizeBatchIfComplete_batchNotFound_doesNothing`
- `cancelBatch_cancelsAllChildEntities` (Fix #7)
- `cancelBatch_releasesReservedStock` (Fix #7)
- `cancelBatch_allowsPackedOrders` (Fix #9)
- `cancelBatch_clearsTransferLanesOnOrders` (Fix #4)

**`CustomerorderServiceUnitTest`:**
- `cleanUpCancelledOrder_callsFinalizeBatchIfComplete` (Fix #2)
- `cancelOrder_callsFinalizeBatchIfComplete` (Fix #3)
- `cancelOrder_packedOrder_withWmsCancel_delegatesToForceCancel` (Fix #8)
- `cancelOrder_packedOrder_withoutWmsCancel_throws` (Fix #8)
- `forceCancelOrder_callsFinalizeBatchIfComplete` (Fix #6)

### Manual QA

- [ ] Cancel all orders in a club batch → batch state = CANCELED, `staginglaneId` = null, lane available
- [ ] Complete all orders in a club batch via BOL → batch state = FINISHED, `staginglaneId` = null
- [ ] Cancel a post-club-run batch (PACKED orders) → succeeds, all child entities cancelled
- [ ] Cancel individual PACKED club order via WMS → `forceCancelOrder` path, batch finalizes if all done
- [ ] Query `getAvailableStagingLanes` — previously blocked lanes should now be available
