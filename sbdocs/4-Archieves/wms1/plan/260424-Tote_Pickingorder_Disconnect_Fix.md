# Tote / Pickingorder Disconnect Fix

- **Date:** 2026-03-18
- **Status:** Ready to Deploy
- **Priority:** High
- **Branch:** `fix/tote-pickingorder-disconnect` (based on `v1.26.23` / `origin/release`)
- **Repo:** `v1/wms-api`

---

## Problem Statement

Reported by **Brent**: Totes (`pickingorder_unitload`) in the WMS are assigned to a picking order that has **no picking order positions**, while the actual parcel and its items are linked to a **different** picking order that references the **same** `pickingorder_unitload`. This creates a data disconnect where the tote record and the pick positions are split across two picking orders.

### Symptoms in the database

| Entity                    | Points to               | Has positions? |
|---------------------------|-------------------------|----------------|
| `pickingorder_unitload`   | `pickingorder` A        | ❌ No          |
| Parcel / CO positions     | `pickingorder` B        | ✅ Yes         |
| Both reference the same `pickingorder_unitload` |

---

## Root Cause Analysis

Four bugs were identified in `MobilePickingService.processPick()` and `CustomerorderService.checkAndCleanUpPickingOrderPositions()` that combine to produce the symptoms Brent observed.

### Bug #1 — Tote assignment loop cross-contaminates picking orders

**File:** `MobilePickingService.java` — `processPick()`, tote assignment loop

The loop iterates over **all** `PickingorderPosition` records for a customer order and sets `picktounitloadId` on every one — including positions belonging to **other** picking orders (e.g. cancelled or orphaned ones). This links those stale positions to the new picking order's `pickingorder_unitload`, creating the exact split Brent described.

### Bug #2 — STARTED state check only validates one picking order

**File:** `CustomerorderService.java` — `checkAndCleanUpPickingOrderPositions()`

The old code fetched positions by `findByPickingorderId(poPositions.get(0).getPickingorderId())` — i.e. it only checked the **first** picking order's positions for STARTED state. If positions from a second, actively-picked picking order existed, they would be missed and incorrectly deleted.

### Bug #3 — No cleanup of orphaned picking orders

**File:** `CustomerorderService.java` — `checkAndCleanUpPickingOrderPositions()`

After deleting picking order positions during a picking-date change, the now-empty `Pickingorder` and its `PickingorderUnitload` records were left behind. These orphaned records accumulate in the database and participate in Bug #1's cross-contamination.

### Bug #4 — Stale `pickingtoteId` blocks tote reuse

**File:** `MobilePickingService.java` — `processPick()`, tote reuse check

When a tote was scanned, the code unconditionally threw `"belongs to different order!"` if any customer order still referenced it via `pickingtoteId`. But `pickingtoteId` is intentionally **not** cleared after picking (it's needed for downstream packing). This meant a tote from a completed order could never be reused, forcing pickers to work around it.

---

## Solution

### Fix #1 — Filter tote assignment by current picking order

Added a guard in the tote assignment loop so only positions belonging to the **current** `pickingOrder` get their `picktounitloadId` set:

```java
// BEFORE
for (PickingorderPosition pickPos : pickingorderPositionRepository.findByCustomerorderpositionId(orderPosition.getId())) {
    pickPos.setPicktounitloadId(pickingUnitLoad.getId());
    pickingorderPositionRepository.save(pickPos);
}

// AFTER
for (PickingorderPosition pickPos : pickingorderPositionRepository.findByCustomerorderpositionId(orderPosition.getId())) {
    if (pickPos.getPickingorderId().equals(pickingOrder.getId())) {
        pickPos.setPicktounitloadId(pickingUnitLoad.getId());
        pickingorderPositionRepository.save(pickPos);
    }
}
```

### Fix #2 — Check ALL positions for STARTED state

Changed the STARTED-state validation from querying a single picking order to checking all positions returned for the parcel:

```java
// BEFORE
List<PickingorderPosition> poPositionsMerged = pickingorderPositionRepository.findByPickingorderId(poPositions.get(0).getPickingorderId());
boolean hasPickingStated = poPositionsMerged.stream().anyMatch(p -> p.getState() >= WmsConstants.State.STARTED);

// AFTER
boolean hasPickingStarted = poPositions.stream().anyMatch(p -> p.getState() >= WmsConstants.State.STARTED);
```


### Fix #3 — Clean up orphaned picking orders and unitloads

After deleting positions, the code now checks each affected picking order. If it has no remaining positions, its `PickingorderUnitload` records are cancelled and the `Pickingorder` itself is set to CANCELED:

```java
// NEW — added after the position deletion loop
for (Long pickingorderId : pickingorderIds) {
    List<PickingorderPosition> remaining = pickingorderPositionRepository.findByPickingorderId(pickingorderId);
    if (remaining.isEmpty()) {
        // Cancel unitloads
        for (PickingorderUnitload pul : pickingorderUnitloadRepository.findByPickingorderId(pickingorderId)) {
            pul.setHistorytote(...);
            pul.setUnitloadId(null);
            pul.setState(WmsConstants.State.CANCELED);
            pickingorderUnitloadRepository.save(pul);
        }
        // Cancel the picking order
        pickingorderRepository.findById(pickingorderId).ifPresent(po -> {
            po.setState(WmsConstants.State.CANCELED);
            pickingorderRepository.save(po);
        });
    }
}
```

### Fix #4 — Allow tote reuse when old order has finished picking

Instead of unconditionally blocking reuse, the code now checks the old order's state. If it's PICKED or higher, the stale `pickingtoteId` is cleared and the tote can be reused:

```java
// BEFORE
if (possibleOldCustomerOrderOpt.isPresent()) {
    throw new BusinessException(toteName + " belongs to different order!");
}

// AFTER
if (possibleOldCustomerOrderOpt.isPresent()) {
    Customerorder oldOrder = possibleOldCustomerOrderOpt.get();
    if (oldOrder.getState() >= WmsConstants.State.PICKED) {
        // Old order is done picking — clear the stale reference
        oldOrder.setPickingtoteId(null);
        customerorderRepository.save(oldOrder);
    } else {
        throw new BusinessException(toteName + " belongs to different order!");
    }
}
```

---

## Files Changed

| File | Change |
|------|--------|
| `src/main/java/.../service/mobile/MobilePickingService.java` | Bug #1: Added `pickingorderId` filter in tote assignment loop. Bug #4: Added state-aware tote reuse with stale `pickingtoteId` clearing. |
| `src/main/java/.../service/CustomerorderService.java` | Bug #2: Changed STARTED check to validate all positions. Bug #3: Added orphan cleanup for empty picking orders and unitloads. |
| `src/test/.../unit/service/mobile/MobilePickingServiceUnitTest.java` | Added `pickingorderId` to two `processPick` test setups (required by Bug #1 filter). |
| `src/test/.../unit/service/CustomerorderServiceUnitTest.java` | Removed unused `findByPickingorderId` stub (Bug #2 fix no longer calls it; strict stubs would fail). |

---

## Deployment Steps

1. Merge `fix/tote-pickingorder-disconnect` into `release` branch
2. Tag as `v1.26.24` (or next available)
3. CI/CD pipeline builds and deploys
4. No database migrations required — all changes are application-level logic

---

## Testing Checklist

- [ ] `MobilePickingServiceUnitTest.processPick_PickingUnitLoadNullToteNullCreatesNewTote_Success` passes
- [ ] `MobilePickingServiceUnitTest.processPick_PickingUnitLoadNullToteExistsOnEmptyLocationWithNoStock_ReusesTote` passes
- [ ] `MobilePickingServiceUnitTest.processPick_PickingUnitLoadNullToteBelongsToDifferentOrder_ThrowsBusinessException` still throws for active orders
- [ ] `CustomerorderServiceUnitTest.setPickingDate_withPickingOrderPositions_pickingStarted_throwsBusinessException` passes
- [ ] `CustomerorderServiceUnitTest.setPickingDate_withPickingOrderPositions_notStarted_deletesPositions` passes
- [ ] Full test suite: `mvn test -Dtest=MobilePickingServiceUnitTest,CustomerorderServiceUnitTest`
- [ ] Manual QA: Pick an order, verify tote assignment only links to current picking order
- [ ] Manual QA: Reuse a tote from a completed (PICKED+) order — should succeed without error
- [ ] Manual QA: Attempt to reuse a tote from an in-progress order — should throw "belongs to different order"
- [ ] Verify no orphaned `pickingorder` records with 0 positions remain after picking-date changes

---

## How the bugs combined to produce Brent's symptoms

```
1. Order A is released for picking → pickingorder #1 created with positions
2. Picking date changed → positions deleted, but pickingorder #1 left behind (Bug #3)
3. Order A re-released → pickingorder #2 created with new positions
4. Picker scans tote → tote assignment loop links ALL positions (including
   orphaned ones from pickingorder #1) to the new tote (Bug #1)
5. Result: pickingorder_unitload points to pickingorder #1 (no positions),
   while the real picks are on pickingorder #2 — exactly what Brent reported
```

---

## Additional Notes

- The `pickingtoteId` field on `Customerorder` is intentionally NOT cleared in `finishPickingOrder` — it is still needed for downstream packing logic. The fix clears it only at the point of tote reuse (Bug #4).
- These bugs exist in both v1 and v2 codebases. This plan covers **v1 only**. A follow-up ticket should be created for v2.
- The `rapidPickingConnectPackageAndType` method (rapid picking flow) has a separate, previously identified bug with wrong ID lookups — that is a distinct issue not addressed here.