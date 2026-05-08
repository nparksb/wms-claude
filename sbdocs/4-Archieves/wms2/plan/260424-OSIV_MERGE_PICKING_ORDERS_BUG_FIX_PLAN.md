# Fix Plan: PickingOrderMergeService.mergePickingOrders — Leftover CANCELED Orders Not Explicitly Saved

**Date:** 2026-03-15
**Status:** Implemented (pending review)
**Priority:** Low (defensive fix — dirty-checking covers this, but explicit save is safer)
**Source:** [OSIV Disabled Audit](260424-WMS_OSIV_Disabled_Audit.md) — Pass 2 Bug Finding
**File:** `src/main/java/net/aim_ai/wms/service/PickingOrderMergeService.java`
**Method:** `mergePickingOrders(List<Pickingorder>, long, Section)` (line 46)

---

## Original Bug (V1 — now partially fixed)

The original plan identified two compounding issues in `ReplenishOrderJob.mergePickingOrders`:

1. **Detached entities** — picking orders fetched outside the `REQUIRES_NEW` transaction were mutated but changes couldn't flush.
2. **Missing save for leftovers** — leftover CANCELED picking orders were never explicitly saved.

## Current State (V2 — refactored into PickingOrderMergeService)

The merge logic was extracted into `PickingOrderMergeService.java`. Here's what changed:

| Issue | Original (V1) | Current (V2) | Status |
|-------|---------------|---------------|--------|
| Detached entities | Entities fetched outside transaction, passed in detached | Re-fetched as managed at line 58 via `findAllById()` | **FIXED** |
| `@Transactional` manager | Not verified | Correctly uses `tenantTransactionManager` (line 45) | **FIXED** |
| Leftover save | No explicit save | Still no explicit save — relies on JPA dirty-checking | **NOT FIXED (but mitigated)** |

### Why dirty-checking works (for now)

Since entities are re-fetched as **managed** at line 58, JPA dirty-checking will detect the state changes (CANCELED, null customerordernumber, null sectionId) set at lines 127-129 and flush them automatically when the `REQUIRES_NEW` transaction commits at line 194.

### Why an explicit save is still recommended

- **Fragility**: Any future change to flush mode, a `clear()` call, or entity detachment would silently break the implicit save
- **Inconsistency**: Reused orders get an explicit `save()` at line 163, but leftovers don't — this is confusing to maintainers
- **Defensive coding**: Explicit saves make intent clear and protect against JPA configuration changes

---

## Code Trace (Current — PickingOrderMergeService.java)

```
Line 45:  @Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
Line 46:  public void mergePickingOrders(List<Pickingorder> pickingOrders, long boxesPerCart, Section section) {
Line 54-58: Re-fetch picking orders by ID → managed entities in currentOrderMap     ✅ (fixes detached issue)
Line 62-68: Filter eligible orders → eligibleOrders list (managed entities)

Line 127:  pickingOrder.setState(CANCELED);          // set on MANAGED entity
Line 128:  pickingOrder.setCustomerordernumber(null);
Line 129:  pickingOrder.setSectionId(null);
Line 131:  pickingOrderList.add(pickingOrder);        // added to list

Line 157:  pickingOrder = pickingOrderList.removeFirst();  // some are reused...
Line 161:  pickingOrder.setState(PROCESSABLE);
Line 163:  pickingorderRepository.save(pickingOrder);      // ...and saved explicitly ✅

Line 187:  // loop ends — remaining pickingOrderList items have NO explicit save ⚠️
Line 190:  pickingorderPositionRepository.saveAll(positionsToSave);  // positions saved
Line 194:  // method returns, transaction commits, dirty-checking flushes CANCELED state (implicit)
```

### Calling context (ReplenishOrderJob.java)

```
Line 166-225: Private mergePickingOrders() orchestrator (no @Transactional)
Line 206:     pickingOrders = pickingorderRepository.findByState...(RESERVED, ...)  // auto-commit, entities detached after
Line 217:     pickingOrderMergeService.mergePickingOrders(pickingOrders, ...)       // REQUIRES_NEW starts, re-fetches inside
```

---

## Fix

### Approach: Explicit saveAll for leftover picking orders

Add a `saveAll()` call after the priorities loop (line 187) to explicitly persist any remaining picking orders in `pickingOrderList`. These have their CANCELED state from line 127 but were not consumed by the merge loop.

### Changes

**File:** `src/main/java/net/aim_ai/wms/service/PickingOrderMergeService.java`

**After line 187** (after the priorities loop ends), **before line 189** (the batch position save), add:

```java
// Explicitly save leftover picking orders that were not reused in the merge.
// Their CANCELED state (set at line 127) is tracked by dirty-checking on managed
// entities, but an explicit save makes intent clear and guards against future changes.
if (!pickingOrderList.isEmpty()) {
    pickingorderRepository.saveAll(pickingOrderList);
}
```

### Why not save immediately at line 129?

Orders that get reused (`removeFirst()` at line 157) would be saved twice — once as CANCELED, then again as PROCESSABLE. Saving leftovers at the end means each order is saved exactly once.

---

## Testing

### Existing Coverage

| Test File | What it covers | Covers leftover bug? |
|-----------|---------------|---------------------|
| `ReplenishOrderJobTest.MergePickingOrdersTests` (6 tests) | Job orchestration — verifies delegation to service | No (service is mocked) |
| `PickingOrderMergeServiceUnitTest.MergePickingOrders` (4 tests) | Merge logic — empty list, skip reserved, merge with positions, group by priority | **No** — no test with leftover scenario |

### New Test Required

**File:** `src/test/java/net/aim_ai/wms/unit/service/PickingOrderMergeServiceUnitTest.java`

Add a test inside the `MergePickingOrders` nested class:

**Test: `shouldSaveLeftoverPickingOrdersAsCanceled`**

Setup:
- 5 picking orders in PROCESSABLE state (eligible for merge)
- `boxesPerCart = 2`
- Each picking order has 1 position linked to a unique customer order
- 5 customer orders with the same priority

Expected:
- 3 picking orders reused as merge containers → saved as PROCESSABLE (via explicit `save()` at line 163)
- 2 leftover picking orders → saved as CANCELED (via the new `saveAll()`)
- `pickingorderRepository.save()` called 3 times (reused orders)
- `pickingorderRepository.saveAll()` called 1 time with 2 CANCELED orders
- All 5 picking order positions reassigned to the 3 merge containers

---

## Risk Assessment

| Factor | Assessment |
|--------|-----------|
| Change size | 4 lines added (1 comment + if-block) |
| Blast radius | Only affects `mergePickingOrders` scheduled job path |
| Regression risk | Very low — adds explicit save where dirty-checking already handles it |
| Data integrity | Defensive improvement — prevents silent breakage if JPA flush behavior changes |
| Performance | Negligible — saves only leftover orders (typically 0-few per batch) |
| Urgency | Low — dirty-checking covers this today; fix is preventive |
