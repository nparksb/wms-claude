# WMS V1 - Unable to Adjust Reserved Amount - Analysis & Fix Plan

**Date**: 2026-03-23
**Branch**: release (production code as of pre-March 1st 2026, commit `1836861`)
**Reported Issue**: Users can't clear stock unit reserved amounts via the handling units UI. The adjustment says "success" but the reservation reappears on refresh.
**Environment**: Production only — not reproducible on dev.

---

## Root Cause

### The Replenishment Maintenance Trigger Undoes the User's Adjustment

Commit `fd13cd2` (2026-02-13, "feat: add replenishment order maintenance service (SBDEV-1742)") added `triggerReplenishmentMaintenance()` calls after every stock-modifying operation in `StockunitService`, including `adjustReservedAmount()`.

**The exact failure sequence:**

```
1. User clicks "Adjust Reserved Amount" → sets to 0
2. Controller: StockUnitController.adjustReservedAmount()
   → StockunitService.adjustReservedAmount()
     → StockunitBusinessService.changeReservedAmount()
       → findByIdForUpdate() → sets reservedamount = 0 → save() → COMMIT ✓
     → triggerReplenishmentMaintenance(itemDataId)           ← THE PROBLEM
       → ReplenishmentOrderMaintenanceService.recalculateForItem()
         → finds open replenishment orders for this item
         → sees the stock unit now has MORE availability (reservation was just cleared)
         → RE-RESERVES the same stock for the existing replenishment order (line 348)
         → changeReservedAmount(source, delta, ...) → save() → COMMIT ✓
3. Controller returns success (HTTP 200) → UI shows "Reserved Amount adjusted"
4. User refreshes → reservation is back (re-created by replenishment recalculation)
```

**File**: `StockunitService.java:416` (release branch)
```java
Stockunit newStockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, amount, ...);
triggerReplenishmentMaintenance(stockUnit.getItemdataId());  // ← re-reserves immediately
```

**File**: `ReplenishmentOrderMaintenanceService.java:348` (release branch)
```java
stockunitBusinessService.changeReservedAmount(source, delta, true, WmsConstants.CODE_REPLENISHMENT, order.getNumber(), null);
```

### Why It Was Working Previously

Before commit `fd13cd2` (2026-02-13), `adjustReservedAmount()` did NOT call `triggerReplenishmentMaintenance()`. The reservation was cleared and stayed cleared. The replenishment trigger was added as part of SBDEV-1742 to auto-recalculate replenishment after stock changes, but the interaction with manual reservation clearing was not considered.

### Why Dev Can't Reproduce

The dev environment likely has:
- No open (active) replenishment orders for the tested stock items, OR
- Different replenishment configuration (thresholds, item assignments), OR
- Different stock levels that don't trigger re-reservation during recalculation

The bug only manifests when there is an **active replenishment order** whose source stock is the one the user is trying to clear.

### Is This Already Fixed in the Current Codebase?

**No.** The develop-arden branch has the same `triggerReplenishmentMaintenance()` call after `adjustReservedAmount()` (with an additional duplicate call at the same location). The issue exists on all branches.

---

## Proposed Fix

### Option A: Remove the Trigger from `adjustReservedAmount()` (Recommended)

**Rationale**: `triggerReplenishmentMaintenance()` makes sense after operations that change stock *availability* (e.g., `adjustAmount`, `setLockDamaged`, `transferStock`) because those affect whether replenishment is needed. But after `adjustReservedAmount()`, the user is *intentionally* changing the reservation — re-triggering the system that created the reservation immediately undoes their action.

**File**: `src/main/java/net/aim_ai/wms/service/StockunitService.java`

```java
// BEFORE (line ~416):
Stockunit newStockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, amount, true, WmsConstants.CODE_MANUAL_ADJUSTMENT, null, comment);
triggerReplenishmentMaintenance(stockUnit.getItemdataId());  // remove this line

// AFTER:
Stockunit newStockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, amount, true, WmsConstants.CODE_MANUAL_ADJUSTMENT, null, comment);
// Note: intentionally NOT triggering replenishment maintenance here.
// Manual reservation adjustment is a deliberate user action; re-triggering
// replenishment would immediately re-reserve the stock the user just released.
```

**Impact**: Low risk. The replenishment job runs on a cron schedule anyway (`ReplenishOrderJob`), so replenishment will naturally recalculate on the next cycle. The user needs the immediate window to move the stock to Damaged before replenishment re-reserves it.

### Option B: Cancel the Replenishment Order Before Clearing Reservation

**Rationale**: If the user is clearing a reservation that belongs to a replenishment order, the replenishment order itself should be addressed — otherwise any recalculation (even the scheduled job) will re-reserve.

This is a more comprehensive fix but requires:
1. Identifying which replenishment order holds the reservation
2. Cancelling or suspending that order
3. Then clearing the reservation

**Effort**: Higher. Requires new lookup logic to match reservation → replenishment order.

### Option C: Add a Flag to Skip Recalculation

Add a boolean parameter to `triggerReplenishmentMaintenance()` or `recalculateForItem()` to skip re-reservation when called from a manual adjustment context.

**Effort**: Medium. Requires threading a parameter through the call chain.

---

## Recommendation

**Implement Option A** (remove the trigger) as the immediate fix. It's the simplest, lowest-risk change that directly addresses the symptom. The scheduled replenishment job provides a natural backstop.

If the business also wants the replenishment order itself cancelled when a user clears its reservation, that can be addressed as a separate enhancement (Option B).

---

## Implementation -- DONE

### Code Change -- DONE

**Status**: IMPLEMENTED
**File**: `src/main/java/net/aim_ai/wms/service/StockunitService.java`

Removed both `triggerReplenishmentMaintenance()` calls from `adjustReservedAmount()` (line 421 original + duplicate at line 424). Added explanatory comment.

### Test Update -- DONE

**Status**: IMPLEMENTED
**File**: `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceUnitTest.java`

Added test: `adjustReservedAmount_doesNotTriggerReplenishmentMaintenance()`
- Clears reservation from 20 to 0
- Verifies `replenishmentOrderMaintenanceService.recalculateForItem()` is NEVER called
- All 51 StockunitServiceUnitTest tests pass

### Deployment Note

This fix should be deployed to production (release branch). Since dev can't reproduce the issue (different replenishment data), testing should focus on:
1. Find a stock unit with an active replenishment reservation
2. Clear the reservation via handling units UI
3. Verify the reservation stays cleared after page refresh
4. Verify the replenishment scheduled job eventually re-evaluates (if needed)

---

## Additional Findings

### Missing `@Transactional` on `StockunitService.adjustReservedAmount()`

The `adjustReservedAmount()` method has no `@Transactional` annotation. The picking-position check (line 411) and the `changeReservedAmount()` call run in separate transaction scopes. This is a TOCTOU (time-of-check-to-time-of-use) gap — another thread could start picking between the check and the reservation change. Adding `@Transactional` would wrap the entire check-then-act sequence.

**Note**: This is not the cause of the current bug (the save itself works), but it's a latent concurrency issue worth fixing alongside.

### Other Methods With the Same Pattern

The `triggerReplenishmentMaintenance()` trigger is appropriate for these operations (stock availability changes):
- `transferStock()` — stock moved between locations ✓
- `setLockOnHold()` — stock locked, unavailable ✓
- `setLockDamaged()` — stock locked, unavailable ✓
- `adjustAmount()` — stock quantity changed ✓
- `removeLock()` — stock unlocked, available again ✓

But NOT for:
- `adjustReservedAmount()` — user intentionally changing reservation ✗ (this fix)

---

## Summary

| Item | Detail |
|------|--------|
| Root cause | `triggerReplenishmentMaintenance()` after `adjustReservedAmount()` re-reserves stock that was just manually cleared |
| Introduced in | Commit `fd13cd2` (2026-02-13, SBDEV-1742) |
| Why dev can't reproduce | Different replenishment data — no active replenishment orders for tested items |
| Already fixed in current code? | **No** — present on all branches |
| Recommended fix | Remove `triggerReplenishmentMaintenance()` from `adjustReservedAmount()` |
| Risk | Low — scheduled replenishment job provides backstop |
