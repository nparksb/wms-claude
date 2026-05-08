# Fix Plan: ReplenishOrderJob.mergePickingOrders — CANCELED State Not Persisted

**Date:** 2026-03-15
**Status:** Implemented (pending review)
**Priority:** Medium
**Source:** [OSIV Disabled Audit](260424-WMS_OSIV_Disabled_Audit.md) — Pass 2 Bug Finding
**File:** `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java`
**Method:** `mergePickingOrders(List<Pickingorder>, long, Section)` (line 388)

---

## Problem

The `mergePickingOrders` method consolidates multiple single-order picking orders into multi-order picking orders (totes-on-cart). During this process, all original picking orders are set to `CANCELED` (line 429), then some are reused as containers for the merged result and saved as `PROCESSABLE` (line 463). **Leftover picking orders that aren't reused are never saved** — their `CANCELED` state is silently lost.

### Root Cause

Two compounding issues:

1. **Detached entities**: The `List<Pickingorder>` parameter is fetched at line 139 (private `mergePickingOrders()`) **outside** any transaction. The public method at line 388 opens a `REQUIRES_NEW` transaction, so the passed-in entities are **detached** in the new persistence context. Dirty checking cannot flush changes to detached entities.

2. **Missing `.save()` for leftovers**: After the merge loop (line 488), any picking orders remaining in `pickingOrderList` are never explicitly saved. Only picking orders that are `.remove(0)`'d and reassigned get saved at line 463.

### Impact

- Picking orders that should be canceled after merge remain in `RESERVED` state
- This could cause **duplicate picking** (the same order positions exist on both the old picking order and the new merged one)
- Stale picking orders may appear in the mobile picking queue
- Severity is mitigated by the fact that this only affects warehouses using the "totes on cart" picking type with `boxesPerCart > 1`

### Code Trace

```
Line 139: pickingOrders = pickingorderRepository.findByState...(RESERVED, ...)  // NO transaction
Line 150: self.mergePickingOrders(pickingOrders, ...)                           // REQUIRES_NEW starts
Line 402:   poCurrent = pickingorderRepository.findById(...)                    // re-fetched (managed)
Line 403:   if (poCurrent.getState() >= RESERVED) continue;                    // state check on managed copy
Line 429:   pickingOrder.setState(CANCELED);         // set on DETACHED original
Line 430:   pickingOrder.setCustomerordernumber(null);
Line 431:   pickingOrder.setSectionId(null);
Line 433:   pickingOrderList.add(pickingOrder);      // added to list

Line 457:   pickingOrder = pickingOrderList.remove(0);  // some are reused...
Line 461:   pickingOrder.setState(PROCESSABLE);
Line 463:   pickingorderRepository.save(pickingOrder);  // ...and saved ✅

Line 488: // loop ends — remaining pickingOrderList items are NEVER saved ❌
```

---

## Fix

### Approach: Save leftovers after the merge loop

Add a loop after line 488 to save any remaining picking orders in `pickingOrderList` that were not reused. These still have their `CANCELED` state from line 429 and need to be persisted.

### Changes

**File:** `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java`

**After line 488** (after the priorities loop ends, before the log statement at line 490), add:

```java
// Save any leftover picking orders that were not reused — their CANCELED state
// was set at line 429 but never persisted since they are detached entities
for (Pickingorder leftover : pickingOrderList) {
    pickingorderRepository.save(leftover);
}
```

This is the minimal fix. The `.save()` call on a detached entity will trigger a merge operation in the `REQUIRES_NEW` transaction context, persisting the `CANCELED` state, null `customerordernumber`, and null `sectionId`.

### Alternative Considered: Save immediately at line 431

```java
pickingOrder.setState(WmsConstants.State.CANCELED);
pickingOrder.setCustomerordernumber(null);
pickingOrder.setSectionId(null);
pickingorderRepository.save(pickingOrder);  // save immediately
pickingOrderList.add(pickingOrder);
```

**Rejected** because:
- Orders that get reused (`.remove(0)` at line 457) would be saved twice — once as CANCELED, then again as PROCESSABLE
- The double save is wasteful and could cause confusion in audit logs
- The "save leftovers at the end" approach is cleaner: each picking order is saved exactly once

### Also considered: Refactor to use ID-based pattern

Passing `List<Long>` instead of `List<Pickingorder>` would align with the pattern used by every other `REQUIRES_NEW` method in the codebase. However, this would be a larger refactor for no additional benefit since the fix above is sufficient and contained.

---

## Testing

### Unit Test

Add a test to `ReplenishOrderJobTest` (or create one if it doesn't exist) that verifies:

1. **Leftover picking orders are saved as CANCELED**: Set up 5 picking orders and `boxesPerCart=2`. After merge, 2 picking orders should be reused (saved as PROCESSABLE), and 3 should be saved as CANCELED.
2. **All positions are reassigned**: Verify picking order positions point to the new merged picking orders.
3. **No picking orders left unsaved**: Verify `pickingorderRepository.save()` is called for every input picking order.

### Manual Verification

1. Ensure the merge picking orders system property is enabled (`SYSTEM_PROPERTY_MERGE_PICKING_ORDERS_KEY = true`)
2. Create multiple single-order picking orders in RESERVED state for a totes-on-cart section
3. Trigger the replenishment job
4. Verify that leftover picking orders are in CANCELED state (not still RESERVED)

---

## Risk Assessment

| Factor | Assessment |
|--------|-----------|
| Change size | 3 lines added |
| Blast radius | Only affects `mergePickingOrders` scheduled job path |
| Regression risk | Low — adding a save where one was missing |
| Data integrity | Improves — prevents orphaned RESERVED picking orders |
| Performance | Negligible — saves only leftover orders (typically 0-few) |
