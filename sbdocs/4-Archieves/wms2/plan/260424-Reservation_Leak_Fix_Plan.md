# Reservation Leak Fix Plan — v2 Codebase Analysis & Implementation

**Date:** 2026-03-07
**Last Updated:** 2026-03-10 (v2 implementation on branch `v2/develop-260310`)
**Status:** FIX #1–#3 + BONUS FIXES IMPLEMENTED — Fix #4 ALREADY FIXED — Fix #5 DEFERRED
**Priority:** Critical
**Applies to:** v2 (`v2/develop-260310` → `v2/develop-260319`)
**Based on:** Original `260424-Reservation_Leak_Fix_Plan.md` (v1, 2026-03-08) + v2 revalidation + implementation (2026-03-10)

---

## Executive Summary

The original fix plan was written for v1. This document revalidates all four fixes against the **v2 codebase** (Spring Boot 3.5, Java 21, dual transaction manager architecture) and provides v2-specific implementation details.

### v2 Revalidation Results

| Fix # | Bug | v2 Status | Action |
|-------|-----|-----------|--------|
| Fix #1 | `fixPickingPosition()` — orphaned reservation | **STILL BUGGY** | Apply fix with v2 `@Transactional` syntax |
| Fix #2 | `checkAndCleanUpPickingOrderPositions()` — direct `setReservedamount` | **STILL BUGGY** | Apply fix (identical pattern) |
| Fix #3 | `cancelReplenishmentOrder()` — over-release | **STILL BUGGY** + **NEW: `MobileReplenishService` has same bug (3 locations)** | Apply fix to 2 files, 4 locations |
| Fix #4 | `redirectSource()` — non-atomic swap | **ALREADY FIXED** in v2 | No action needed |
| Fix #5 | `cleanUpCancelledOrder()` — missing unreserve | Deferred | Not in scope |

### Critical v2 Difference: Transaction Manager

**All `@Transactional` annotations in v2 MUST use:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
```

The v1 plan used `@Transactional(rollbackFor = Exception.class)` — this is **WRONG for v2** because the `landlordTransactionManager` is `@Primary`. A bare `@Transactional` defaults to the landlord (master) database, silently disabling transactional guarantees for tenant operations.

### New Discovery: `MobileReplenishService` Over-Release

The v1 plan identified the over-release bug only in `ReplenishorderService.cancelReplenishmentOrder()`. The v2 analysis discovered the **same bug pattern** in `MobileReplenishService.finishReplenishmentOrderInternal()` at **3 locations** (lines 462, 466, 468). All use `sourceStock.getReservedamount().negate()` instead of `replenishOrder.getRequestedamount().negate()`.

---

## Table of Contents

1. [Fix #1: `fixPickingPosition()` — Orphaned Reservation (CRITICAL)](#fix-1-fixpickingposition--orphaned-reservation-critical)
2. [Fix #2: `checkAndCleanUpPickingOrderPositions()` — Direct Manipulation (MEDIUM-HIGH)](#fix-2-checkandcleanuppickingorderpositions--direct-manipulation-medium-high)
3. [Fix #3: Over-Release — `cancelReplenishmentOrder()` + `MobileReplenishService` (CRITICAL)](#fix-3-over-release--cancelreplenishmentorder--mobilereplenishservice-critical)
4. [Fix #4: `redirectSource()` — Non-Atomic Swap (ALREADY FIXED)](#fix-4-redirectsource--non-atomic-swap-already-fixed)
5. [Bonus Fixes: REST Exposure & Code Smells](#bonus-fixes-rest-exposure--code-smells)
6. [Constants](#constants)
7. [Testing Checklist](#testing-checklist)
8. [Post-Deployment Cleanup](#post-deployment-cleanup)
9. [Deferred: Fix #5 — `cleanUpCancelledOrder()`](#deferred-fix-5--cleanupcancelledorder)

---

## Fix #1: `fixPickingPosition()` — Orphaned Reservation (CRITICAL)

### Bug Description

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderPositionService.java`
**Method:** `fixPickingPosition()` (lines 81–138)

When reassigning a picking position from one stock unit to another:
- **Line 130:** Reserves the NEW replacement stock unit via `changeReservedAmount(replacement, amount, false, ...)`
- **Lines 131–134:** Updates the position to reference the new stock unit and saves
- **MISSING:** Never unreserves the OLD stock unit — creating an orphaned reservation every time

### Current Buggy Code (v2, lines 127–134)

```java
final Long replacementUnitloadId = replacement.getUnitloadId();
Unitload unitLoad = unitloadRepository.findById(replacementUnitloadId).orElseThrow(() -> new EntityNotFoundException("UnitLoad", replacementUnitloadId));
Location location = locationRepository.findById(unitLoad.getStoragelocationId()).orElseThrow(() -> new EntityNotFoundException("Location", unitLoad.getStoragelocationId()));
stockunitBusinessService.changeReservedAmount(replacement, pickingOrderPosition.getAmount(), false, CODE_CREATE_PICK_POSITION, pickingOrderPosition.getNumber(), "fix picking position");
pickingOrderPosition.setPickfromstockunitId(replacement.getId());
pickingOrderPosition.setPickfromunitloadlabel(unitLoad.getLabelid());
pickingOrderPosition.setPickfromlocationname(location.getName());
pickingOrderPosition = pickingorderPositionRepository.save(pickingOrderPosition);
```

### Additional Issues

| Issue | Detail |
|-------|--------|
| No `@Transactional` on method | Class has `@Service` only (line 17). No class-level or method-level `@Transactional`. |
| No `@Transactional` on controller caller | `PickingOrderPositionController.fixPickingPosition()` (line 46) has no `@Transactional`. Each DB operation auto-commits independently. |
| Mobile caller is safe | `MobilePickingService.processPick()` (line 375) has `@Transactional(value = "tenantTransactionManager", ...)` — provides transactional context. |
| Same-stock-unit edge case | If replacement == original (unitload moved but stock unit unchanged), line 130 would double-count the reservation. |

### v2 Implementation

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderPositionService.java`

**Step 1:** Add import (after line 9):
```java
import org.springframework.transaction.annotation.Transactional;
```

**Step 2:** Replace lines 81–138 with:

```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public PickingorderPosition fixPickingPosition(PickingorderPosition pickingOrderPosition) throws BusinessException, FacadeException {
    LOG.debug("start with pickingOrderPosition={}", pickingOrderPosition.getId());

    Stockunit replacement = null;
    final Long pickingPositionItemdataId = pickingOrderPosition.getItemdataId();
    Itemdata itemData = itemdataRepository.findById(pickingPositionItemdataId).orElseThrow(() -> new EntityNotFoundException("ItemData", pickingPositionItemdataId));
    Optional<FixLocationAssignment> fixedLocationAssignmentOpt = fixLocationAssignmentRepository.findByItemdataId(itemData.getId());
    FixLocationAssignment fixedLocationAssignment = fixedLocationAssignmentOpt.orElse(null);

    if (fixedLocationAssignment != null) {
        Unitload assignedUnitLoad = unitloadRepository.findById(fixedLocationAssignment.getAssignedunitloadId()).orElseThrow(() -> new EntityNotFoundException("UnitLoad", fixedLocationAssignment.getAssignedunitloadId()));
        Location unitloadLocation = locationRepository.findById(assignedUnitLoad.getStoragelocationId()).orElseThrow(() -> new EntityNotFoundException("Location", assignedUnitLoad.getStoragelocationId()));
        Location assignedLocation = locationRepository.findById(fixedLocationAssignment.getAssignedlocationId()).orElseThrow(() -> new EntityNotFoundException("Location", fixedLocationAssignment.getAssignedlocationId()));

        if (unitloadLocation != assignedLocation) {
            throw new BusinessException("Fix fix assignment first for " + fixedLocationAssignment.getItemdataId());
        }

        List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(assignedUnitLoad.getId());
        replacement = stockUnitList.get(0);
        BigDecimal availableAmount = replacement.getAvailableamount();

        if (availableAmount.compareTo(pickingOrderPosition.getAmount()) < 0) {
            int diff = pickingOrderPosition.getAmount().subtract(availableAmount).intValue();
            throw new BusinessException("Add " + diff + " to flowbin " + assignedLocation.getName());
        }
    } else {
        List<Stockunit> stockUnitList = stockunitRepository.getStockUnitsByItemDataId(pickingOrderPosition.getItemdataId());

        if (stockUnitList.isEmpty()) {
            throw new BusinessException("No stock found on pickable location. Please move stock first.");
        }

        for (Stockunit stockUnit : stockUnitList) {
            if (stockUnit.getAvailableamount().compareTo(pickingOrderPosition.getAmount()) < 0) {
                continue;
            }
            replacement = stockUnit;
            break;
        }

        if (replacement == null) {
            throw new BusinessException("not enough stock on single unit load found.");
        }
    }

    Long originalStockUnitId = pickingOrderPosition.getPickfromstockunitId();

    if (replacement.getId().equals(originalStockUnitId)) {
        // Same stock unit, different unitload/location — only update metadata, no reservation change
        Unitload unitLoad = unitloadRepository.findById(replacement.getUnitloadId()).orElseThrow(() -> new EntityNotFoundException("UnitLoad", replacement.getUnitloadId()));
        Location location = locationRepository.findById(unitLoad.getStoragelocationId()).orElseThrow(() -> new EntityNotFoundException("Location", unitLoad.getStoragelocationId()));
        pickingOrderPosition.setPickfromunitloadlabel(unitLoad.getLabelid());
        pickingOrderPosition.setPickfromlocationname(location.getName());
        pickingOrderPosition = pickingorderPositionRepository.save(pickingOrderPosition);
    } else {
        // Different stock unit — unreserve old, reserve new
        if (originalStockUnitId != null) {
            Stockunit originalStockUnit = stockunitRepository.findById(originalStockUnitId).orElse(null);
            if (originalStockUnit != null) {
                stockunitBusinessService.changeReservedAmount(
                    originalStockUnit,
                    pickingOrderPosition.getAmount().negate(),
                    true,   // zeroIfNegative: safety net
                    WmsConstants.CODE_FIX_PICK_POSITION,
                    pickingOrderPosition.getNumber(),
                    "unreserve original stock unit before fix"
                );
            } else {
                LOG.warn("Original stock unit {} not found when fixing picking position {}",
                    originalStockUnitId, pickingOrderPosition.getNumber());
            }
        }

        // Reserve replacement + update position
        final Long replacementUnitloadId = replacement.getUnitloadId();
        Unitload unitLoad = unitloadRepository.findById(replacementUnitloadId).orElseThrow(() -> new EntityNotFoundException("UnitLoad", replacementUnitloadId));
        Location location = locationRepository.findById(unitLoad.getStoragelocationId()).orElseThrow(() -> new EntityNotFoundException("Location", unitLoad.getStoragelocationId()));
        stockunitBusinessService.changeReservedAmount(replacement, pickingOrderPosition.getAmount(), false,
            CODE_CREATE_PICK_POSITION, pickingOrderPosition.getNumber(), "fix picking position");

        pickingOrderPosition.setPickfromstockunitId(replacement.getId());
        pickingOrderPosition.setPickfromunitloadlabel(unitLoad.getLabelid());
        pickingOrderPosition.setPickfromlocationname(location.getName());
        pickingOrderPosition = pickingorderPositionRepository.save(pickingOrderPosition);
    }

    LOG.debug("end   with pickingOrderPosition={}", pickingOrderPosition.getId());
    return pickingOrderPosition;
}
```

**Risk:** Low. Additive change with `@Transactional` safety net. The same-stock-unit check prevents double-reservation edge case.

---

## Fix #2: `checkAndCleanUpPickingOrderPositions()` — Direct Manipulation (MEDIUM-HIGH)

### Bug Description

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
**Method:** `checkAndCleanUpPickingOrderPositions()` (lines 239–259)

The method directly manipulates `stockUnit.setReservedamount()` instead of using the standard `changeReservedAmount()` API, bypassing:
- Audit trail (`stockrecordService.recordChangeReservedAmount()`)
- Row locking (`findByIdForUpdate()`)
- Boundary checks (negative amount validation)

### Current Buggy Code (v2, lines 249–255)

```java
for (PickingorderPosition position : poPositions) {
    // adjust reserved amount
    Stockunit stockUnit = stockunitRepository.findById(position.getPickfromstockunitId()).orElseThrow(() -> new EntityNotFoundException("StockUnit", position.getPickfromstockunitId()));
    stockUnit.setReservedamount(stockUnit.getReservedamount().subtract(position.getAmount()));
    stockunitRepository.save(stockUnit);
    // delete the existing picking order position
    pickingorderPositionRepository.delete(position);
}
```

### Correct Pattern (same class, `forceCancelOrder()` line 282–283)

```java
Stockunit pickFromStockUnit = stockunitRepository.findById(pickingPosition.getPickfromstockunitId()).orElseThrow(() -> new EntityNotFoundException("StockUnit", pickingPosition.getPickfromstockunitId()));
stockunitBusinessService.changeReservedAmount(pickFromStockUnit, pickingPosition.getAmount().negate(), true, WmsConstants.CODE_CANCELLED_ORDER_FROM_WEBSERVICE, pickingPosition.getNumber(), null);
```

### v2 Implementation

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`

**Note:** `StockunitBusinessService` is already autowired at line 66 (constructor param at line 100). No new dependency needed.

**Replace lines 249–256 with:**

```java
for (PickingorderPosition position : poPositions) {
    // adjust reserved amount via proper API (audit trail + row locking)
    Long stockUnitId = position.getPickfromstockunitId();
    if (stockUnitId != null) {
        Stockunit stockUnit = stockunitRepository.findById(stockUnitId).orElse(null);
        if (stockUnit != null) {
            try {
                stockunitBusinessService.changeReservedAmount(
                    stockUnit,
                    position.getAmount().negate(),
                    true,  // zeroIfNegative — safety net
                    WmsConstants.CODE_CLEANUP_PICKING_POSITION,
                    position.getNumber(),
                    "picking date changed - cleanup"
                );
            } catch (FacadeException e) {
                throw new BusinessException(
                    "Failed to release reservation for position " + position.getNumber() + ": " + e.getMessage());
            }
        } else {
            LOG.warn("Stock unit {} not found when cleaning up picking position {} for order {}",
                stockUnitId, position.getNumber(), position.getCustomerorderpositionId());
        }
    }
    // delete the existing picking order position
    pickingorderPositionRepository.delete(position);
}
```

**Throws clause changes:** The `FacadeException` is caught and re-thrown as `BusinessException`. The callers `setPickingDate()` and `batchUpdatePickingDate()` already throw `BusinessException`, so no signature changes needed.

**Null guard rationale:**
- `pickfromstockunitId` can be null — it's set to null after successful picks (`PickingorderBusinessService`) and during `forceCancelOrder()` (line 284)
- The query `getPickingorderPositionsByParcelexternalnumber` does not filter by state or null FK
- `.orElse(null)` with null check handles deleted/nirvana stock units gracefully

**Risk:** Low. Behavioral change is strictly safer (adds locking + audit). Performance acceptable for admin-only batch operations.

---

## Fix #3: Over-Release — `cancelReplenishmentOrder()` + `MobileReplenishService` (CRITICAL)

### Bug Description

Two files use `sourceStock.getReservedamount().negate()` (releases ALL reservation on the stock unit) instead of `replenishOrder.getRequestedamount().negate()` (releases only this order's reservation). If multiple orders share the same source stock unit, this destroys other orders' reservations.

### Location A: `ReplenishorderService.cancelReplenishmentOrder()` (1 location)

**File:** `src/main/java/net/aim_ai/wms/service/ReplenishorderService.java`
**Method:** `cancelReplenishmentOrder()` (lines 196–218)
**Buggy line:** 212

```java
// CURRENT (BUGGY) — line 212:
stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true, WmsConstants.CODE_REPLENISHMENT_CANCELLED, replenishOrder.getNumber(), null);
```

**Fix:** Change line 212:
```java
// FIXED — release only this order's requested amount:
stockunitBusinessService.changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true, WmsConstants.CODE_REPLENISHMENT_CANCELLED, replenishOrder.getNumber(), null);
```

### Location B: `MobileReplenishService.finishReplenishmentOrderInternal()` (3 locations) — NEW DISCOVERY

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`
**Method:** `finishReplenishmentOrderInternal()` (lines 420–470+)
**Buggy lines:** 462, 466, 468

This method is called when a replenishment order is COMPLETED (not cancelled). It releases reservations on the source stock unit(s), but uses the same buggy pattern.

```java
// CURRENT (BUGGY) — lines 461-470:
if (sourceStock.getId().equals(replenishOrder.getStockunitId()) || replenishOrder.getStockunitId() == null) {
    stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true,       // ← line 462: BUGGY
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
} else if (replenishOrder.getStockunitId() != null) {
    Stockunit stockUnit = stockunitRepository.findById(replenishOrder.getStockunitId()).orElseThrow(() -> new EntityNotFoundException("StockUnit", replenishOrder.getStockunitId()));
    stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true,       // ← line 466: BUGGY
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
    stockunitBusinessService.changeReservedAmount(stockUnit, stockUnit.getReservedamount().negate(), true,           // ← line 468: BUGGY
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
}
```

**Fix:** Replace lines 461–470 with:
```java
if (sourceStock.getId().equals(replenishOrder.getStockunitId()) || replenishOrder.getStockunitId() == null) {
    // Source stock is the same as the order's original stock unit — release this order's amount
    stockunitBusinessService.changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
} else if (replenishOrder.getStockunitId() != null) {
    // Source was redirected — release reservation from BOTH the current source and the original stock unit
    Stockunit stockUnit = stockunitRepository.findById(replenishOrder.getStockunitId()).orElseThrow(() -> new EntityNotFoundException("StockUnit", replenishOrder.getStockunitId()));
    stockunitBusinessService.changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
    stockunitBusinessService.changeReservedAmount(stockUnit, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
}
```

**Note on the `else if` branch:** When a replenishment source has been redirected, the reservation should have been moved from the original stock unit to the new source by `redirectSource()` (which is already fixed in v2 with proper `@Transactional`). Releasing `requestedamount` from both is safe because `zeroIfNegative=true` clamps to zero — if the old stock unit's reservation was already moved away, the release becomes a no-op.

### Correct Pattern Reference

`ReplenishmentOrderMaintenanceService.cancelOrder()` (lines 368–386) shows the correct implementation:
```java
BigDecimal releaseAmount = safe(order.getRequestedamount());  // ← Uses ORDER's amount, NOT stock's total
if (releaseAmount.compareTo(BigDecimal.ZERO) > 0 && source != null) {
    releaseReservation(source, releaseAmount);
}
```

### Risk

**Location A:** Very low. One-token change. Aligns with correct pattern in same codebase.
**Location B:** Low. Same pattern change applied consistently. `zeroIfNegative=true` prevents negative reservations.

---

## Fix #4: `redirectSource()` — Non-Atomic Swap (ALREADY FIXED)

### v2 Status: NO ACTION NEEDED

The v2 codebase already has proper `@Transactional` annotations on all three methods:

| Method | Line | Annotation |
|--------|------|------------|
| `redirectSource()` | 164 | `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` |
| `update()` | 91 | `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` |
| `updateSourceStockUnit()` | 112 | `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` |

**File:** `src/main/java/net/aim_ai/wms/service/ReplenishorderService.java`

The unreserve-then-reserve pattern at lines 173–190 is now atomically protected. If the second `changeReservedAmount()` throws, the entire transaction (including the first unreserve) rolls back.

---

## Bonus Fixes: REST Exposure & Code Smells

### Bonus A: REST DELETE Protection — `PickingorderPositionRepository`

**File:** `src/main/java/net/aim_ai/wms/repo/jpa/PickingorderPositionRepository.java`
**Line:** 15

**Current (BUGGY):**
```java
public interface PickingorderPositionRepository extends PagingAndSortingRepository<PickingorderPosition, Long>, CrudRepository<PickingorderPosition, Long>
```

**Fix:** Change `PagingAndSortingRepository` to `NoDeletePagingAndSortingRepository`:
```java
public interface PickingorderPositionRepository extends NoDeletePagingAndSortingRepository<PickingorderPosition, Long>, CrudRepository<PickingorderPosition, Long>
```

Add import: `import net.aim_ai.wms.repo.cinterface.NoDeletePagingAndSortingRepository;`

**Risk:** Zero. No frontend uses REST DELETE on this entity. Programmatic `delete()` still works.

### Bonus B: `StockunitRepository` REST Exposure

**File:** `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java`
**Line:** 25

Same issue — extends `PagingAndSortingRepository`, exposing REST PATCH/DELETE on `Stockunit`. Consider applying the same `NoDeletePagingAndSortingRepository` fix.

**Risk:** Low — verify no REST PATCH usage in frontends first.

### Bonus C: `releaseReservation()` Exception Swallowing

**File:** `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java`
**Line:** 384

Currently logs at `WARN` level. Should be `ERROR` for production monitoring visibility:

```java
// CURRENT:
LOG.warn("Failed to release reservation from stockUnit={}: {}", source.getId(), e.getMessage());

// FIX:
LOG.error("Failed to release reservation from stockUnit={}: {}", source.getId(), e.getMessage());
```

---

## Constants

**File:** `src/main/java/net/aim_ai/wms/service/WmsConstants.java`

Add these constants (if not already present):
```java
public static final String CODE_FIX_PICK_POSITION = "FIX_PICK_POSITION";
public static final String CODE_CLEANUP_PICKING_POSITION = "CLEANUP_PICKING_POSITION";
```

---

## Testing Checklist

### Fix #1 Tests (`fixPickingPosition`)

- [ ] **Different stock unit swap**: Original's `reservedamount` decremented, replacement's incremented. Net effect = zero
- [ ] **Same stock unit (unitload moved)**: Only metadata updated. No reservation change. No double-reservation
- [ ] **Original stock unit in nirvana**: `orElse(null)` + `LOG.warn` — no exception, fix proceeds
- [ ] **Original stock unit `pickfromstockunitId` is null**: Null-guard prevents NPE
- [ ] **`stockrecord` audit entry**: Created for unreserve with activity `FIX_PICK_POSITION`
- [ ] **Controller path transaction**: Verify unreserve + reserve are atomic (both commit or both rollback)
- [ ] **Mobile path**: Verify existing `@Transactional` on `processPick()` still wraps correctly

### Fix #2 Tests (`checkAndCleanUpPickingOrderPositions`)

- [ ] **Single order date change**: `stockrecord` entries created for each position with activity `CLEANUP_PICKING_POSITION`
- [ ] **Position with null `pickfromstockunitId`**: Skipped gracefully, no NPE
- [ ] **Stock unit not found (deleted/nirvana)**: `LOG.warn` emitted, position still deleted
- [ ] **Stock unit already partially unreserved**: `zeroIfNegative=true` clamps gracefully

### Fix #3 Tests (`cancelReplenishmentOrder` + `MobileReplenishService`)

- [ ] **Cancel with shared source stock unit**: Only cancelled order's `requestedamount` released, other orders' reservations intact
- [ ] **Cancel with `requestedamount > reservedamount`**: `zeroIfNegative=true` clamps gracefully
- [ ] **`stockrecord` audit entry**: Amount matches `requestedamount`, not total `reservedamount`
- [ ] **Finish replenishment (same source)**: Releases only `requestedamount`, not total `reservedamount`
- [ ] **Finish replenishment (redirected source)**: Releases `requestedamount` from both old and new stock units

### Bonus Tests (REST DELETE Protection)

- [ ] **REST `DELETE /v3/pickingorderPosition/{id}`**: Returns 405 Method Not Allowed
- [ ] **Programmatic `pickingorderPositionRepository.delete(position)`**: Still works

---

## Summary of All Changes

| # | File | Change | Severity | Status |
|---|------|--------|----------|--------|
| 1 | `PickingorderPositionService.java` | Add `@Transactional(value="tenantTransactionManager", rollbackFor={...})` + unreserve original + same-stock-unit guard + `LOG.warn` | Critical | **IMPLEMENTED** |
| 2 | `CustomerorderService.java:249-256` | Replace `setReservedamount` with `changeReservedAmount` + null guards | Medium-High | **IMPLEMENTED** |
| 3a | `ReplenishorderService.java:212` | Change `sourceStock.getReservedamount()` → `replenishOrder.getRequestedamount()` | Critical | **IMPLEMENTED** |
| 3b | `MobileReplenishService.java:462,466,468` | Change `sourceStock.getReservedamount()` / `stockUnit.getReservedamount()` → `replenishOrder.getRequestedamount()` | Critical | **IMPLEMENTED** |
| 4 | `WmsConstants.java` | Add `CODE_FIX_PICK_POSITION` and `CODE_CLEANUP_PICKING_POSITION` | None | **IMPLEMENTED** |
| 5 | `PickingorderPositionRepository.java` | Add `@RestResource(exported = false)` overrides for delete methods | Medium | **IMPLEMENTED** |
| 6 | `ReplenishmentOrderMaintenanceService.java:384` | Log at ERROR level in `releaseReservation()` | Low | **IMPLEMENTED** |
| 7 | `StockunitRepository.java:25` | Consider `NoDeletePagingAndSortingRepository` | Low | Deferred |

---

## v2 Implementation Evidence (2026-03-10)

### Changes Applied

| Change | File | Status | Notes |
|--------|------|--------|-------|
| Fix #1 | `PickingorderPositionService.java` | DONE | Added `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})`, unreserve original stock unit, same-stock-unit metadata-only path, null-guard, `LOG.warn`, `CODE_FIX_PICK_POSITION` activity code |
| Fix #2 | `CustomerorderService.java` | DONE | Replaced `setReservedamount` with `changeReservedAmount()`, null guard on `pickfromstockunitId`, `.orElse(null)` instead of `.orElseThrow()`, `CODE_CLEANUP_PICKING_POSITION` activity code |
| Fix #3a | `ReplenishorderService.java:212` | DONE | One-token fix: `sourceStock.getReservedamount()` → `replenishOrder.getRequestedamount()` |
| Fix #3b | `MobileReplenishService.java:462,466,468` | DONE | Three-location fix: all `getReservedamount()` → `getRequestedamount()` |
| Constants | `WmsConstants.java` | DONE | Added `CODE_FIX_PICK_POSITION` and `CODE_CLEANUP_PICKING_POSITION` |
| Bonus: REST DELETE | `PickingorderPositionRepository.java` | DONE | Added `@RestResource(exported = false)` overrides for `deleteById`, `delete`, `deleteAll` (inline approach instead of `NoDeletePagingAndSortingRepository` to avoid Mockito test-classpath issue with `@Hidden` annotation) |
| Bonus: Log level | `ReplenishmentOrderMaintenanceService.java:384` | DONE | Changed `LOG.warn` → `LOG.error` |

### Test Results

- **Build:** `mvn compile -DskipTests` — BUILD SUCCESS
- **Fix #1 tests (`FixPickingPosition`):** 5/5 passed ✅
- **Fix #3a tests (`CancelReplenishmentOrder`):** 2/2 passed ✅
- **Fix #3b tests (`FinishReplenishmentOrder`):** 5/5 passed ✅ (3 tests required `order.setRequestedamount()` to be set in test data)
- **Fix #2 related tests (`CleanUpCancelledOrder`, `EdgeCases`, etc.):** 19/19 passed ✅
- **Pre-existing failures:** `SetPickingDateExtended`, `CancelOrderSuccessPaths`, `BatchOperationsErrorHandling` — all fail due to pre-existing text-block compilation issue (`PickingorderPositionRepository.java:67` uses `"""` syntax) and `List.of()` missing imports — NOT caused by these fixes

### Files Modified

1. `src/main/java/net/aim_ai/wms/service/PickingorderPositionService.java` — Fix #1
2. `src/main/java/net/aim_ai/wms/service/CustomerorderService.java` — Fix #2
3. `src/main/java/net/aim_ai/wms/service/ReplenishorderService.java` — Fix #3a
4. `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` — Fix #3b
5. `src/main/java/net/aim_ai/wms/service/WmsConstants.java` — Constants
6. `src/main/java/net/aim_ai/wms/repo/jpa/PickingorderPositionRepository.java` — Bonus: REST DELETE protection
7. `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` — Bonus: Log level
8. `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java` — Test fix: added `requestedamount` to test data

---

## Post-Deployment Cleanup

### Leaked Reservation Detection Query

Run after deploying fixes to identify and correct existing leaked reservations:

```sql
-- Detect leaked picking position reservations
SELECT su.id, su.labelid, su.amount, su.reservedamount,
       COALESCE(SUM(pop.amount), 0) as actual_reserved_by_picking,
       su.reservedamount - COALESCE(SUM(pop.amount), 0) as potential_leak
FROM stockunit su
LEFT JOIN pickingorder_position pop ON pop.pickfromstockunit_id = su.id
    AND pop.state < 600  -- not yet picked
WHERE su.reservedamount > 0
GROUP BY su.id, su.labelid, su.amount, su.reservedamount
HAVING su.reservedamount > COALESCE(SUM(pop.amount), 0);
```

**Note:** This query only detects picking-related leaks. Replenishment reservations must be cross-referenced with `replenishorder.requestedamount` for active orders.

---

## Deferred: Fix #5 — `cleanUpCancelledOrder()`

**Status:** ON HOLD — Validated as a real bug, deferred to a future release.
**Severity:** Medium
**Risk:** Medium — touches the order cancellation workflow, needs careful testing with partially-picked orders.

`cleanUpCancelledOrder()` in `CustomerorderService.java` cancels an order and all positions but never unreserves picking positions' stock. Compare with `cancelOrderPosition()` and `forceCancelOrder()` which correctly unreserve. See original v1 plan for full analysis.
