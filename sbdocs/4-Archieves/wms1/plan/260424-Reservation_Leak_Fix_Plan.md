# Reservation Leak Fix Plan — Comprehensive Analysis & Implementation

**Date:** 2026-03-07
**Last Updated:** 2026-03-08 (Fix #1–#4 implemented, Fix #5 deferred)
**Status:** FIX #1–#4 IMPLEMENTED — Fix #5 DEFERRED
**Priority:** Critical
**Applies to:** v1 (all versions) and v2 (feature/multi-clients-j21)
**Based on:** `260424-Reservation_Leak_Analysis.md` (2026-03-06) + deep codebase-wide validation + external review (`260424-Reservation_Leak_Fix_Plan_Review.md`)

---

## Executive Summary

Four Opus-tier agents independently validated the original `260424-Reservation_Leak_Analysis.md` and performed a codebase-wide sweep. An external review (`260424-Reservation_Leak_Fix_Plan_Review.md`) was then conducted, and its findings were re-validated against the codebase.

| Category | Count | Details |
|----------|-------|---------|
| Original bugs confirmed REAL | 2 | Bug #1 (`fixPickingPosition`), Bug #2 (`checkAndCleanUpPickingOrderPositions`) |
| Original plan corrections needed | 3 | Missing `@Transactional`, incorrect dependency claim, overstated race condition severity |
| **NEW leaks discovered** | **3** | Replenishment cancel over-release, replenishment redirect non-atomic, cancelled order missing unreserve |
| Code smells found | 2 | Swallowed exceptions, REST PATCH exposure on `StockunitRepository` |
| Bonus fix confirmed | 1 | REST DELETE on `PickingorderPositionRepository` |

**The most critical new finding**: `ReplenishorderService.cancelReplenishmentOrder()` releases the **entire** stock unit reservation (all orders' amounts) instead of just the cancelled order's amount. This is a one-line bug that can destroy reservations belonging to other active orders.

### Review Validation Summary

| Fix # | Review Verdict | Re-Validation Result | Action |
|-------|---------------|---------------------|--------|
| Fix #1 | Needs revision (null check, orElseThrow, propagation) | **Plan already handles all 3 concerns.** Review evaluated simplified pseudo-code, not actual Change 1. Review's revised method signature is wrong (breaks callers). | Keep plan as-is. Add `LOG.warn` for missing stock unit. |
| Fix #2 | Partially valid (2a valid, 2b overstated, 2c invalid) | **Review's sub-verdicts confirmed correct.** Plan's Change 2 needs null guard on `pickfromstockunitId` + use `.orElse(null)` instead of `.get()`. | Revise Change 2 code. |
| Fix #3 | Valid & Critical | **Confirmed.** No changes needed. | Keep plan as-is. |
| Fix #4 | Valid, proposes REQUIRES_NEW + pessimistic locking + lock ordering | **Review over-engineers the fix.** `changeReservedAmount()` already uses `findByIdForUpdate()` internally. `REQUIRES_NEW` is wrong (prevents joining outer transactions). Plan's simple `@Transactional` is correct. | Keep plan as-is. Add `@Transactional` to callers too. |
| Fix #5 | INVALID — claims "soft cancel" | **Review is WRONG. Plan is correct.** `cleanUpCancelledOrder()` is terminal (sets CANCELED state) but never unreserves. "Soft cancel" theory has no code support. Three cancel paths exist; this one is simply missing unreserve logic. | Keep Bug #5. **ON HOLD** — deferred to future release (see [Deferred Section](#8-deferred-fix-5--cleanupCancelledorder-missing-unreserve)). |

---

## Table of Contents

1. [Validated Original Bugs](#1-validated-original-bugs)
2. [Corrections to Original Plan](#2-corrections-to-original-plan)
3. [Newly Discovered Leaks](#3-newly-discovered-leaks)
4. [Code Smells & Hardening](#4-code-smells--hardening)
5. [Implementation Plan](#5-implementation-plan)
6. [Business Logic Impact Assessment](#6-business-logic-impact-assessment)
7. [Testing Checklist](#7-testing-checklist)
8. [Deferred: Fix #5 — `cleanUpCancelledOrder()` Missing Unreserve](#8-deferred-fix-5--cleanupCancelledorder-missing-unreserve)

---

## 1. Validated Original Bugs

### Bug #1: `fixPickingPosition()` — CONFIRMED REAL (Critical)

**File:** `PickingorderPositionService.java:73-128`
**Verdict:** The bug is unambiguous. Every call creates an orphaned reservation.

**Evidence:**
- Line 120: `changeReservedAmount(replacement, amount, false, ...)` — reserves replacement
- Line 121: `setPickfromstockunitId(replacement.getId())` — overwrites the original stock unit reference
- Line 124: `save(pickingOrderPosition)` — persists the change
- **No unreserve call exists anywhere in the method for the original stock unit**

**Neither caller compensates:**
- `PickingOrderPositionController.fixPickingPosition()` (line 59) — no unreserve before/after, no `@Transactional`
- `MobilePickingService.processPick()` (line 358) — no unreserve before/after, but has `@Transactional` (line 338)

**Correct pattern exists at:** `ReplenishorderService.redirectSource()` lines 149+166 (unreserve old → reserve new)

**Additional edge case the original plan missed:**
- If replacement stock unit == original stock unit (unitload moved but stock unit unchanged), the reserve at line 120 would **double-count** the reservation. The fix must check for this.

**Review validation (2026-03-08):**
- Review claimed 3 issues (null check, orElseThrow, propagation) — **all already addressed in Change 1 code.** Review evaluated a simplified pseudo-code snippet, not the actual implementation plan.
- Review's revised method signature `void fixPickingPosition(PickingorderPosition pos, Stockunit replacement)` is **incorrect** — actual signature is `PickingorderPosition fixPickingPosition(PickingorderPosition)` (takes 1 param, returns PickingorderPosition). The review's signature would break both callers.
- `Propagation.REQUIRED` is Spring's default — specifying it is unnecessary and inconsistent with codebase convention (zero uses of explicit `Propagation.REQUIRED` in codebase).
- `orElse(null)` with null check is preferred over `orElseThrow()` — original stock unit may be in nirvana state (`entityLock=GOING_TO_DELETE` but row persists); failing the fix operation because a deleted stock unit can't be unreserved would be worse than skipping.
- **Accepted improvement:** Add `LOG.warn` when original stock unit not found for observability.

### Bug #2: `checkAndCleanUpPickingOrderPositions()` — CONFIRMED REAL (Medium-High)

**File:** `CustomerorderService.java:214-234`

| Sub-issue | Verdict | Severity | Notes |
|-----------|---------|----------|-------|
| 2a: No audit trail | **REAL** | Medium-High | Only place in service layer that modifies `reservedamount` outside the standard API on a live stock unit |
| 2b: No row lock | **REAL** but overstated | Low in practice | `Stockunit` has `@Version` (line 43-44) which prevents silent lost updates. Race results in `OptimisticLockException`, not silent corruption. `changeReservedAmount()` adds pessimistic lock via `findByIdForUpdate()` internally. |
| 2c: Physical deletion | Partial-failure claim **INVALID** | N/A | Class-level `@Transactional` (line 27) ensures atomicity. The audit trail concern (2a) is valid. |

**Telling inconsistency:** `forceCancelOrder()` at line 258 in the **same class** correctly uses `changeReservedAmount()` for the same conceptual operation (releasing reservations when cleaning up picking positions).

**Review validation (2026-03-08):** Review's sub-verdicts confirmed correct. Plan Change 2 needs revision — see Change 2 below.

### Bonus: REST DELETE Exposure — CONFIRMED REAL (Medium)

**File:** `PickingorderPositionRepository.java:16-17`
- Extends `PagingAndSortingRepository` → REST DELETE exposed at `/v3/pickingorderPosition/{id}`
- **Zero frontend usage** confirmed (searched both `wms-web-ui` and `wms-mobile-ui`)
- `NoDeletePagingAndSortingRepository` exists at `repo/cinterface/` and is the correct fix pattern

---

## 2. Corrections to Original Plan

### Correction 1: Missing `@Transactional` on Fix #1 (CRITICAL)

The original plan does not mention transactional boundaries. This is dangerous:

- `PickingorderPositionService` has **no** `@Transactional` (class or method level)
- **Controller path** (`PickingOrderPositionController.fixPickingPosition()` line 59): No `@Transactional` on controller either. Each `changeReservedAmount()` call has its own `@Transactional` and commits independently
- If the unreserve (on original) commits successfully but the reserve (on replacement) fails → **both** stock units lose reservation — **worse than the current bug**
- **Mobile path** (`MobilePickingService.processPick()` line 338): Has `@Transactional` — safe

**Required:** Add `@Transactional(rollbackFor = Exception.class)` to `fixPickingPosition()` method.

**Note:** `Propagation.REQUIRED` is Spring's default — no need to specify explicitly. The codebase has zero uses of explicit propagation. With `REQUIRED`, the method creates a new transaction when called from the controller (no outer tx) and joins the existing transaction when called from `processPick()` (has `@Transactional`).

### Correction 2: `StockunitBusinessService` Already Autowired

The original plan states:
> **New dependency required** in `CustomerorderService`:
> `@Autowired private StockunitBusinessService stockunitBusinessService;`

**This is incorrect.** `CustomerorderService.java:87-88` already has:
```java
@Autowired
private StockunitBusinessService stockunitBusinessService;
```

No new dependency is needed.

### Correction 3: Race Condition Severity Overstated

The original plan claims Issue 2b can cause "one update to overwrite the other, leaving the reservation permanently incorrect." This is overstated because `Stockunit` has `@Version` (optimistic locking). The race results in `OptimisticLockException`, not silent corruption. Additionally, `changeReservedAmount()` already uses `findByIdForUpdate()` (pessimistic lock) internally, providing even stronger protection. The fix is still warranted (adds audit trail), but the race severity is Low, not High.

---

## 3. Newly Discovered Leaks

### Bug #3: `ReplenishorderService.cancelReplenishmentOrder()` — Over-Release (CRITICAL)

**File:** `ReplenishorderService.java:172-193`
**Line:** 187

```java
// CURRENT (BUGGY): Releases ALL reservation on the stock unit
stockunitBusinessService.changeReservedAmount(
    sourceStock,
    sourceStock.getReservedamount().negate(),  // ← WRONG: releases ALL, not just this order's
    true,
    WmsConstants.CODE_REPLENISHMENT_CANCELLED,
    replenishOrder.getNumber(),
    null
);
```

**The bug:** Uses `sourceStock.getReservedamount().negate()` instead of `replenishOrder.getRequestedamount().negate()`. If multiple replenishment orders share the same source stock unit, canceling ONE order wipes out ALL reservations on that stock unit.

**Example:**
- StockUnit has `reservedamount=30` (10 from OrderA, 20 from OrderB)
- Cancel OrderA: `changeReservedAmount(stockUnit, -30, ...)` — releases 30 instead of 10
- StockUnit now has `reservedamount=0` — OrderB's 20-unit reservation is destroyed

**Correct pattern at:** `ReplenishmentOrderMaintenanceService.cancelOrder()` line 356-366 correctly uses `safe(order.getRequestedamount())`.

**Fix:** One-line change:
```java
// FIXED: Release only this order's requested amount
stockunitBusinessService.changeReservedAmount(
    sourceStock,
    replenishOrder.getRequestedamount().negate(),  // ← Only this order's amount
    true,  // zeroIfNegative for safety
    WmsConstants.CODE_REPLENISHMENT_CANCELLED,
    replenishOrder.getNumber(),
    null
);
```

**Review validation (2026-03-08):** Review confirmed CRITICAL. Second verification complete with full evidence chain through `StockunitBusinessService.changeReservedAmount()` arithmetic.

### Bug #4: `ReplenishorderService.redirectSource()` — Non-Atomic Swap (HIGH)

**File:** `ReplenishorderService.java:141-170`

```java
// Line 149: Unreserve old source — commits if no outer @Transactional
stockunitBusinessService.changeReservedAmount(source_old,
    replenishOrder.getRequestedamount().negate(), true, ...);

// Lines 155-164: Update order, save...
replenishorderRepository.save(replenishOrder);

// Line 166: Reserve new source — if this THROWS, old is already unreserved
stockunitBusinessService.changeReservedAmount(stockUnit,
    replenishOrder.getRequestedamount(), false, ...);
```

**The bug:** `ReplenishorderService` is a `@Service` with **no class-level `@Transactional`**. `redirectSource()` has **no method-level `@Transactional`**. If the second `changeReservedAmount` at line 166 throws, the first unreserve has already committed via its own `@Transactional`, the order is saved pointing to the new stock unit, but the new stock unit has no reservation.

**Fix:** Add `@Transactional(rollbackFor = Exception.class)` to `redirectSource()`.

**Review validation (2026-03-08):**
- Review proposed `REQUIRES_NEW` + pessimistic locking + lock ordering — **over-engineered and partially wrong:**
  - `REQUIRES_NEW` is **incorrect** — it suspends the outer transaction, preventing composability. The correct default `REQUIRED` propagation joins any existing transaction or creates a new one.
  - Pessimistic locking at caller level is **redundant** — `changeReservedAmount()` at `StockunitBusinessService.java:314` already calls `findByIdForUpdate()` (pessimistic `PESSIMISTIC_WRITE` lock) internally.
  - Lock ordering is **unnecessary** — redirect operations are low-frequency admin actions; deadlock between two concurrent redirects on the same pair of stock units is near-impossible.
- Plan's simple `@Transactional(rollbackFor = Exception.class)` is correct and sufficient. With this wrapper, both inner `changeReservedAmount()` calls (which have `@Transactional(REQUIRED)`) join the outer transaction — all operations commit or roll back atomically.
- **Additional improvement:** Also add `@Transactional(rollbackFor = Exception.class)` to callers `update()` (line 73) and `updateSourceStockUnit()` (line 93) to wrap the full unit of work.

### Bug #5: `CustomerorderService.cleanUpCancelledOrder()` — Missing Unreserve (MEDIUM)

**File:** `CustomerorderService.java:593-633`

This method cancels an order, moves the tote to clearing, and cancels all positions — but **never unreserves picking positions' stock**. Compare with `cancelOrderPosition()` in `CustomerorderPositionService.java:115-121` which properly calls `changeReservedAmount(...negate())`.

**When triggered:**
1. `PickingorderBusinessService.finishPickingOrder()` line 134 — when `markedforcancellation` is true
2. `CustomerorderService.cancelOrder()` line 526 — when order has `pickingconfirmationsent=true`

**Impact:** For partially-picked orders (some positions PICKED, others still PROCESSABLE/STARTED), the un-picked positions still have active reservations that are never released.

**Fix:** Before canceling, find unpicked `PickingorderPosition` records and call `changeReservedAmount(...negate())` for each.

**Review validation (2026-03-08):**
- Review claimed this is INVALID — asserting a "soft cancel" mode that intentionally holds reservations. **This is incorrect.** Code analysis confirms:
  - `cleanUpCancelledOrder()` sets order state to `CANCELED` (line 606) — this is a **terminal state**, not a "hold"
  - All order positions are set to `CANCELED` (line 612) — terminal
  - The method never iterates over `PickingorderPosition` records and never calls `changeReservedAmount()` — this is an **omission**, not intentional design
  - Three cancellation paths exist in `CustomerorderService`:
    1. `cancelOrder()` when `canOrderPositionBeCancelled=true` → calls `cancelOrderPosition()` → **correctly unreserves**
    2. `forceCancelOrder()` → directly calls `changeReservedAmount()` → **correctly unreserves**
    3. `cleanUpCancelledOrder()` → sets state to CANCELED but **never unreserves** — the bug
  - The `markedforcancellation` flag is a **deferral mechanism** (defer cancellation until picking finishes), not a "soft cancel mode"
  - No subsequent processing step exists to release reservations after `cleanUpCancelledOrder()` completes
- **Verdict: Bug #5 is VALID.** Implementation deferred — see [Deferred Section](#8-deferred-fix-5--cleanupCancelledorder-missing-unreserve).

---

## 4. Code Smells & Hardening

### 4a: `ReplenishmentOrderMaintenanceService.releaseReservation()` Swallows Exceptions (LOW)

**File:** `ReplenishmentOrderMaintenanceService.java:368-373`

```java
private void releaseReservation(Stockunit source, BigDecimal releaseAmount) {
    try {
        stockunitBusinessService.changeReservedAmount(source, releaseAmount.negate(), true, ...);
    } catch (FacadeException e) {
        LOG.warn("Failed to release reservation...");  // Silently swallowed
    }
}
```

If the release fails, the caller proceeds as if it succeeded. In `cancelOrder()` path, the order is set to CANCELED regardless, orphaning the reservation.

**Fix:** Log at ERROR level. Consider propagating the exception in critical paths.

### 4b: `StockunitRepository` REST PATCH Exposure (LOW)

`StockunitRepository.java:25` extends `PagingAndSortingRepository`, exposing `PATCH /v3/stockunit/{id}` which allows direct modification of `reservedamount` without audit trail, row locking, or boundary checks. Requires authenticated user.

**Fix:** Consider extending `NoDeletePagingAndSortingRepository` or creating a `NoModifyPagingAndSortingRepository` that also hides save operations from REST.

### 4c: Codebase-Wide `@Transactional` Rollback Gap (SYSTEMIC)

**No `rollbackFor` exists anywhere in the entire codebase.** Both `BusinessException` and `FacadeException` extend `Exception` (checked), not `RuntimeException`. Spring's default `@Transactional` does NOT roll back on checked exceptions. This means any method that throws `BusinessException`/`FacadeException` within a `@Transactional` boundary will **commit partial work** instead of rolling back.

This is a pre-existing systemic issue, not introduced by these fixes. However, the fixes should use `@Transactional(rollbackFor = Exception.class)` where they add new transactional boundaries.

### 4d: Review's Gap Suggestions — Assessment

The review identified three gaps. Assessment:

| Gap | Review's Suggestion | Assessment |
|-----|-------------------|------------|
| Cleanup strategy for existing leaked reservations | SQL detection query + scheduled cleanup job | **VALID.** Add post-deployment cleanup query (see Phase 4 below). |
| Rollback plan | Feature flags + monitoring | **Over-engineered.** These are small, surgical fixes — standard git revert is sufficient. Monitoring for `OptimisticLockException` is good practice regardless. |
| Performance impact of pessimistic locks | Benchmark + capacity planning | **Not applicable.** Plan does not add new pessimistic locks — `changeReservedAmount()` already uses them. |

---

## 5. Implementation Plan

### Phase 1: Critical Fixes (Must-Have for This Release)

#### Change 1: Fix `fixPickingPosition()` — Bug #1 — IMPLEMENTED

**File:** `PickingorderPositionService.java`

1. Add `@Transactional(rollbackFor = Exception.class)` to `fixPickingPosition()` method
2. Before the existing reserve call (line 120), add:
   - Read original stock unit ID from `pickingOrderPosition.getPickfromstockunitId()`
   - Check if replacement == original (skip both unreserve and reserve if same)
   - If different: call `changeReservedAmount(original, amount.negate(), true, CODE_FIX_PICK_POSITION, ...)`
3. Add null-guard on `getPickfromstockunitId()` (defensive)
4. Add `LOG.warn` if original stock unit not found (observability improvement from review)

```java
@Transactional(rollbackFor = Exception.class)
public PickingorderPosition fixPickingPosition(PickingorderPosition pickingOrderPosition)
        throws BusinessException, FacadeException {
    // ... existing replacement search logic (lines 76-116) ...

    Long originalStockUnitId = pickingOrderPosition.getPickfromstockunitId();

    if (replacement.getId().equals(originalStockUnitId)) {
        // Same stock unit, different unitload/location — only update metadata
        Unitload unitLoad = unitloadRepository.findById(replacement.getUnitloadId()).get();
        Location location = locationRepository.findById(unitLoad.getStoragelocationId()).get();
        pickingOrderPosition.setPickfromunitloadlabel(unitLoad.getLabelid());
        pickingOrderPosition.setPickfromlocationname(location.getName());
        pickingOrderPosition = pickingorderPositionRepository.save(pickingOrderPosition);
    } else {
        // Different stock unit — unreserve old, reserve new
        if (originalStockUnitId != null) {
            Stockunit originalStockUnit = stockunitRepository.findById(originalStockUnitId)
                .orElse(null);
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

        // Existing code: reserve replacement + update position
        Unitload unitLoad = unitloadRepository.findById(replacement.getUnitloadId()).get();
        Location location = locationRepository.findById(unitLoad.getStoragelocationId()).get();
        stockunitBusinessService.changeReservedAmount(replacement,
            pickingOrderPosition.getAmount(), false,
            CODE_CREATE_PICK_POSITION, pickingOrderPosition.getNumber(),
            "fix picking position");

        pickingOrderPosition.setPickfromstockunitId(replacement.getId());
        pickingOrderPosition.setPickfromunitloadlabel(unitLoad.getLabelid());
        pickingOrderPosition.setPickfromlocationname(location.getName());
        pickingOrderPosition = pickingorderPositionRepository.save(pickingOrderPosition);
    }

    return pickingOrderPosition;
}
```

**Risk:** Low. Additive change with `@Transactional` safety net. The same-stock-unit check prevents double-reservation edge case not in original plan.

#### Change 2: Fix `checkAndCleanUpPickingOrderPositions()` — Bug #2 (REVISED) — IMPLEMENTED

**File:** `CustomerorderService.java`

Replace lines 222-231 with:

```java
for (PickingorderPosition position : poPositions) {
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
    pickingorderPositionRepository.delete(position);
}
```

**Revision notes (from review validation):**
- Added null guard on `position.getPickfromstockunitId()` — the field has no `@NotNull` constraint and is set to null after successful picks (`PickingorderBusinessService.java:279`)
- Changed `.get()` to `.orElse(null)` with null check — defensive against deleted/nirvana stock units
- Added `LOG.warn` for missing stock units
- The query `getPickingorderPositionsByParcelexternalnumber` does not filter by state or null FK, so it can return already-picked positions with null `pickfromstockunitId`

**Note:** `StockunitBusinessService` is already autowired at line 87-88. No new dependency needed.

**Caution:** Class-level `@Transactional` has no `rollbackFor`. The `FacadeException` from `changeReservedAmount()` is caught and re-thrown as `BusinessException` (checked). Spring's default will **not roll back** on this checked exception. If partial success is unacceptable, add `@Transactional(rollbackFor = Exception.class)` to the calling method `setPickingDate()` or to `checkAndCleanUpPickingOrderPositions()`.

**Risk:** Low. Behavioral change is strictly safer (adds locking + audit). Performance acceptable for admin-only batch operations.

#### Change 3: Fix `cancelReplenishmentOrder()` Over-Release — Bug #3 — IMPLEMENTED

**File:** `ReplenishorderService.java`

At line 187, change:
```java
// BEFORE (BUGGY):
sourceStock.getReservedamount().negate()

// AFTER (FIXED):
replenishOrder.getRequestedamount().negate()
```

**Risk:** Very low. One-line fix. Aligns with the correct pattern in `ReplenishmentOrderMaintenanceService.cancelOrder()`.

**Supporting Evidence — Correct Pattern Comparison:**

The correct pattern already exists in `ReplenishmentOrderMaintenanceService.cancelOrder()` (line 356-366):
```java
// ReplenishmentOrderMaintenanceService.java:360-362
BigDecimal releaseAmount = safe(order.getRequestedamount()); // ← uses order's amount, NOT stock's total
if (releaseAmount.compareTo(BigDecimal.ZERO) > 0 && source != null) {
    releaseReservation(source, releaseAmount);
}
```

**Supporting Evidence — Existing Test Masks the Bug:**

The existing test `cancelReplenishmentOrder_activeOrder_cancelsAndReleasesStock` in `ReplenishorderServiceUnitTest.java:278-293` does NOT detect the bug because it sets `reservedamount=50` without setting a distinct `requestedamount`, so both values happen to match. The test verifies `BigDecimal.valueOf(-50)` which passes for both the buggy and correct code.

**Supporting Test Code (to add when fix is applied):**

Update the existing test to use distinct values, and add 2 new tests to `ReplenishorderServiceUnitTest.java`:

```java
// UPDATE existing test: set distinct requestedamount vs reservedamount
@Test
void cancelReplenishmentOrder_activeOrder_cancelsAndReleasesStock() throws FacadeException {
    Replenishorder order = buildReplenishorder(1L, "REP-001");
    order.setState(WmsConstants.State.PROCESSABLE);
    order.setStockunitId(100L);
    order.setRequestedamount(BigDecimal.valueOf(20));

    Stockunit stock = buildStockunit(100L, BigDecimal.valueOf(50));
    stock.setReservedamount(BigDecimal.valueOf(50));

    when(stockunitRepository.findById(100L)).thenReturn(Optional.of(stock));
    when(replenishorderRepository.save(any())).thenReturn(order);

    replenishorderService.cancelReplenishmentOrder(order);

    // Must release only the order's requestedamount (20), NOT the stock unit's total reservedamount (50)
    verify(stockunitBusinessService).changeReservedAmount(stock, BigDecimal.valueOf(-20), true,
        WmsConstants.CODE_REPLENISHMENT_CANCELLED, "REP-001", null);
    verify(replenishorderRepository).save(argThat(o -> o.getState() == WmsConstants.State.CANCELED));
}

// NEW: Proves shared-source over-release bug
@Test
void cancelReplenishmentOrder_sharedSourceStockUnit_releasesOnlyOrderAmount() throws FacadeException {
    // Bug #3: If multiple orders share a source stock unit, cancelling one must NOT wipe out
    // the other orders' reservations. Only this order's requestedamount should be released.
    Replenishorder order = buildReplenishorder(1L, "REP-001");
    order.setState(WmsConstants.State.PROCESSABLE);
    order.setStockunitId(100L);
    order.setRequestedamount(BigDecimal.valueOf(10)); // This order reserved 10

    Stockunit stock = buildStockunit(100L, BigDecimal.valueOf(100));
    stock.setReservedamount(BigDecimal.valueOf(30)); // Total reserved = 30 (10 from this + 20 from another)

    when(stockunitRepository.findById(100L)).thenReturn(Optional.of(stock));
    when(replenishorderRepository.save(any())).thenReturn(order);

    replenishorderService.cancelReplenishmentOrder(order);

    // CRITICAL: must release exactly 10 (this order's amount), not 30 (total reserved)
    verify(stockunitBusinessService).changeReservedAmount(stock, BigDecimal.valueOf(-10), true,
        WmsConstants.CODE_REPLENISHMENT_CANCELLED, "REP-001", null);
    verify(replenishorderRepository).save(argThat(o -> o.getState() == WmsConstants.State.CANCELED));
}

// NEW: Edge case — requestedamount exceeds current reservedamount due to prior partial release
@Test
void cancelReplenishmentOrder_requestedAmountExceedsReserved_usesZeroIfNegative() throws FacadeException {
    Replenishorder order = buildReplenishorder(1L, "REP-001");
    order.setState(WmsConstants.State.PROCESSABLE);
    order.setStockunitId(100L);
    order.setRequestedamount(BigDecimal.valueOf(50));

    Stockunit stock = buildStockunit(100L, BigDecimal.valueOf(100));
    stock.setReservedamount(BigDecimal.valueOf(20)); // Less than requested due to prior partial release

    when(stockunitRepository.findById(100L)).thenReturn(Optional.of(stock));
    when(replenishorderRepository.save(any())).thenReturn(order);

    replenishorderService.cancelReplenishmentOrder(order);

    // Releases requestedamount (50), zeroIfNegative=true in changeReservedAmount clamps to zero
    verify(stockunitBusinessService).changeReservedAmount(stock, BigDecimal.valueOf(-50), true,
        WmsConstants.CODE_REPLENISHMENT_CANCELLED, "REP-001", null);
    verify(replenishorderRepository).save(argThat(o -> o.getState() == WmsConstants.State.CANCELED));
}
```

**Verification Results (from dry-run):** These 3 tests were temporarily applied alongside the one-line fix and ran successfully (`BUILD SUCCESS`, 27 tests, 0 failures). The updated existing test **fails against the buggy code** (expects `-20` but buggy code passes `-50`), confirming the bug is real and the fix is correct.

#### Change 4: Fix `redirectSource()` Atomicity — Bug #4 — IMPLEMENTED

**File:** `ReplenishorderService.java`

Add `@Transactional(rollbackFor = Exception.class)` to three methods:

```java
// Method 1: redirectSource() — the core fix
@Transactional(rollbackFor = Exception.class)
public Replenishorder redirectSource(Replenishorder replenishOrder, Stockunit stockUnit) throws BusinessException, FacadeException {
    // ... existing code unchanged ...
}

// Method 2: update() — wraps full unit of work including priority change
@Transactional(rollbackFor = Exception.class)
public Replenishorder update(Long id, Long stockUnitId, Integer priority) throws BusinessException, FacadeException {
    // ... existing code unchanged ...
}

// Method 3: updateSourceStockUnit() — alternative entry point
@Transactional(rollbackFor = Exception.class)
public Replenishorder updateSourceStockUnit(Long id, Long stockUnitId) throws BusinessException, FacadeException {
    // ... existing code unchanged ...
}
```

**Why this is sufficient:**
- `changeReservedAmount()` has `@Transactional(REQUIRED)` — it joins the outer transaction created by `redirectSource()`
- `changeReservedAmount()` already calls `findByIdForUpdate()` (pessimistic lock) internally — no additional locking needed
- All operations commit or roll back atomically
- No need for `REQUIRES_NEW` — that would prevent joining outer transactions and break composability

**Risk:** Low. Ensures the unreserve + reserve are atomic. Default `REQUIRED` propagation is safe with all existing callers (none have their own `@Transactional`).

**Import needed:** Add `import org.springframework.transaction.annotation.Transactional;` to `ReplenishorderService.java`.

#### Change 5: Constants — IMPLEMENTED

**File:** `WmsConstants.java`

Add:
```java
public static final String CODE_FIX_PICK_POSITION = "FIX_PICK_POSITION";
public static final String CODE_CLEANUP_PICKING_POSITION = "CLEANUP_PICKING_POSITION";
```

#### Change 6: REST DELETE Protection — IMPLEMENTED

**File:** `PickingorderPositionRepository.java`

Change line 17:
```java
// BEFORE:
extends PagingAndSortingRepository<PickingorderPosition, Long>

// AFTER:
extends NoDeletePagingAndSortingRepository<PickingorderPosition, Long>
```

Add import for `NoDeletePagingAndSortingRepository`.

**Risk:** Zero. No frontend or integration uses REST DELETE on this entity. Programmatic `delete()` still works.

### Phase 2: Hardening (Follow-Up)

| # | Change | File | Risk |
|---|--------|------|------|
| 8 | Log at ERROR level when `releaseReservation()` fails | `ReplenishmentOrderMaintenanceService.java:370` | None |
| 9 | Consider `NoDeletePagingAndSortingRepository` for `StockunitRepository` | `StockunitRepository.java:25` | Low — verify no REST PATCH usage |
| 10 | Audit `@Transactional(rollbackFor = Exception.class)` across codebase | All service classes | Systemic — separate analysis needed |

### Phase 3: Post-Deployment Cleanup (from review Gap 1)

#### Leaked Reservation Detection Query

Run after deploying Phase 1 fixes to identify and correct existing leaked reservations:

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

## 6. Business Logic Impact Assessment

### Fix #1 Impact (`fixPickingPosition`)

| Concern | Assessment |
|---------|------------|
| Can original stock unit be deleted? | No — "sent to nirvana" sets `entityLock=GOING_TO_DELETE` but row persists. `findById` succeeds. Use `orElse(null)` + `LOG.warn` for safety. |
| Double-unreserve risk? | None with `zeroIfNegative=true` — clamps to zero gracefully |
| Same-stock-unit edge case? | Handled by `replacement.getId().equals(originalStockUnitId)` check |
| `@Transactional` on controller path? | **Required.** Without it, partial failure creates worse state than current bug. Default `REQUIRED` propagation creates new tx from controller, joins existing tx from `processPick()`. |
| Downstream `confirmPick()` impact? | None — `confirmPick()` at `PickingorderBusinessService.java:252` unreserves the **current** `pickfromstockunitId` (the replacement), which is correctly reserved |

### Fix #2 Impact (`checkAndCleanUpPickingOrderPositions`)

| Concern | Assessment |
|---------|------------|
| Null `pickfromstockunitId`? | Can be null — set to null after picks (`PickingorderBusinessService.java:279`), during `forceCancelOrder()` (line 259), during `cancelOrderPosition()` (line 120). Null guard added in revised code. |
| Performance in batch? | Acceptable. Admin-only operation. 50 orders × 5 positions = 250 `SELECT FOR UPDATE` — bounded, infrequent |
| Partial commit on `FacadeException`? | Pre-existing gap (`@Transactional` has no `rollbackFor`). The catch-and-rethrow as `BusinessException` will NOT trigger rollback under default Spring behavior. Consider adding `rollbackFor` to calling method. |
| `StockunitBusinessService` dependency | Already exists at line 87-88 — no change needed |

### Fix #3 Impact (`cancelReplenishmentOrder` Over-Release)

| Concern | Assessment |
|---------|------------|
| Can multiple orders share a source stock unit? | Yes — `ReplenishGeneratorService.calculateOrder()` picks from available stock, multiple orders can reference same stock unit |
| Is `requestedamount` always set? | Yes — set at creation in `ReplenishGeneratorService.java:147` |
| Can `requestedamount` exceed current `reservedamount`? | Yes, if another cancel already released part. `zeroIfNegative=true` handles this |

### Fix #4 Impact (`redirectSource` Atomicity)

| Concern | Assessment |
|---------|------------|
| Caller transaction propagation? | `update()` and `updateSourceStockUnit()` also get `@Transactional` — redundant but harmless (inner `REQUIRED` joins outer). |
| `changeReservedAmount` locking? | Already uses `findByIdForUpdate()` (pessimistic lock) internally. No additional locking needed at caller level. |
| Performance impact of transaction? | Negligible — adds transaction boundary around 2-3 DB operations |

### Fix #6 Impact (`NoDeletePagingAndSortingRepository`)

| Concern | Assessment |
|---------|------------|
| Frontend usage? | None — verified in both web-ui and mobile-ui |
| Programmatic `delete()` still works? | Yes — `@RestResource(exported = false)` only hides REST endpoints |
| First repo to use this interface? | Yes, but the interface was designed for this purpose |

### Scheduled Job Conflicts

| Job | Conflict? |
|-----|-----------|
| `ReleaseOrderJobService` (creates picking positions + reserves) | No — only processes `RAW` state orders; cleanup processes `>RAW` states. Mutually exclusive |
| `ReplenishOrderJobService` | No reservation interaction |
| `ReleaseExpiredPickingOrdersFromUserJob` | No reservation interaction — only releases operator assignment |

---

## 7. Testing Checklist

### Bug #1 Tests (`fixPickingPosition`)

- [ ] **Different stock unit swap**: Original's `reservedamount` decremented, replacement's incremented. Net effect = zero
- [ ] **Same stock unit (unitload moved)**: Only metadata updated. No reservation change. No double-reservation
- [ ] **Original stock unit in nirvana**: `orElse(null)` + `LOG.warn` — no exception, fix proceeds
- [ ] **Original stock unit `pickfromstockunitId` is null**: Null-guard prevents NPE
- [ ] **`stockrecord` audit entry**: Created for unreserve with activity `FIX_PICK_POSITION`
- [ ] **Controller path transaction**: Verify unreserve + reserve are atomic (both commit or both rollback)
- [ ] **Mobile path**: Verify existing `@Transactional` on `processPick()` still wraps correctly
- [ ] **Concurrent: fix during pick**: Position fixed while another user picks — verify no double-unreserve

### Bug #2 Tests (`checkAndCleanUpPickingOrderPositions`)

- [ ] **Single order date change**: `stockrecord` entries created for each position with activity `CLEANUP_PICKING_POSITION`
- [ ] **Batch date change (50 orders)**: All positions cleaned, all `stockrecord` entries created
- [ ] **Position with null `pickfromstockunitId`**: Skipped gracefully, no NPE
- [ ] **Stock unit not found (deleted/nirvana)**: `LOG.warn` emitted, position still deleted
- [ ] **Stock unit already partially unreserved**: `zeroIfNegative=true` clamps gracefully
- [ ] **Concurrent: date change during pick**: `@Version` prevents lost update via `OptimisticLockException`

### Bug #3 Tests (`cancelReplenishmentOrder`)

- [ ] **Cancel with shared source stock unit**: Only cancelled order's `requestedamount` released, other orders' reservations intact
- [ ] **Cancel with `requestedamount > reservedamount`**: `zeroIfNegative=true` clamps gracefully
- [ ] **`stockrecord` audit entry**: Amount matches `requestedamount`, not total `reservedamount`

### Bug #4 Tests (`redirectSource` Atomicity)

- [ ] **Successful redirect**: Old unreserved, new reserved, order updated — all in one transaction
- [ ] **Reserve-new fails**: Transaction rolls back — old source reservation restored
- [ ] **Source not found**: Handled gracefully, no partial state
- [ ] **`@Transactional` on `update()`**: Verify priority change + redirect are atomic

### Bonus Tests (REST DELETE Protection)

- [ ] **REST `DELETE /v3/pickingorderPosition/{id}`**: Returns 405 Method Not Allowed
- [ ] **Programmatic `pickingorderPositionRepository.delete(position)`**: Still works

---

## Implementation Evidence (2026-03-08)

### Changes Applied

| Change | File | Status | Notes |
|--------|------|--------|-------|
| 1 | `PickingorderPositionService.java` | DONE | Added `@Transactional(rollbackFor=Exception.class)`, unreserve original stock unit, same-stock-unit guard, `LOG.warn` for missing stock unit, `CODE_FIX_PICK_POSITION` activity code |
| 2 | `CustomerorderService.java` | DONE | Replaced `setReservedamount` with `changeReservedAmount()`, null guard on `pickfromstockunitId`, `.orElse(null)` instead of `.get()`, `CODE_CLEANUP_PICKING_POSITION` activity code. Added `FacadeException` to `checkAndCleanUpPickingOrderPositions`, `setPickingDate`, `batchUpdatePickingDate` throws clauses. Updated `CustomerOrderController.java` catch blocks. |
| 3 | `ReplenishorderService.java:187` | DONE | One-line fix: `sourceStock.getReservedamount()` → `replenishOrder.getRequestedamount()` |
| 4 | `ReplenishorderService.java` | DONE | Added `@Transactional(rollbackFor=Exception.class)` to `redirectSource()`, `update()`, `updateSourceStockUnit()` + Transactional import |
| 5 | `WmsConstants.java` | DONE | Added `CODE_FIX_PICK_POSITION` and `CODE_CLEANUP_PICKING_POSITION` constants |
| 6 | `PickingorderPositionRepository.java` | DONE | Changed to extend `NoDeletePagingAndSortingRepository` + import |

### Test Results

- **Build:** `mvn clean compile` — BUILD SUCCESS
- **Unit Tests:** `ReplenishorderServiceUnitTest` — 27/27 passed (25 existing + 2 new Bug #3 tests)
- **New tests added:**
  - `cancelReplenishmentOrder_sharedStockUnit_releasesOnlyOrderAmount` — verifies only order's `requestedamount` is released, not stock's total `reservedamount`
  - `cancelReplenishmentOrder_zeroReservation_stillCancelsOrder` — verifies graceful handling when stock has zero reservation
- **Existing test fixed:** `cancelReplenishmentOrder_activeOrder_cancelsAndReleasesStock` — added `order.setRequestedamount()` to match the Bug #3 fix

### Files Modified

1. `src/main/java/net/aim_ai/wms/service/PickingorderPositionService.java`
2. `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
3. `src/main/java/net/aim_ai/wms/service/ReplenishorderService.java`
4. `src/main/java/net/aim_ai/wms/service/WmsConstants.java`
5. `src/main/java/net/aim_ai/wms/repo/jpa/PickingorderPositionRepository.java`
6. `src/main/java/net/aim_ai/wms/controller/CustomerOrderController.java`
7. `src/test/java/net/aim_ai/wms/unit/service/ReplenishorderServiceUnitTest.java`

---

## Summary of All Required Changes

| # | Phase | File | Change | Severity | Risk |
|---|-------|------|--------|----------|------|
| 1 | 1 | `PickingorderPositionService.java` | Add `@Transactional(rollbackFor=Exception.class)` + unreserve original + same-stock-unit guard + `LOG.warn` | Critical | Low |
| 2 | 1 | `CustomerorderService.java:222-231` | Replace `setReservedamount` with `changeReservedAmount` + null guards | Medium-High | Low |
| 3 | 1 | `ReplenishorderService.java:187` | Change `sourceStock.getReservedamount()` → `replenishOrder.getRequestedamount()` | Critical | Very Low |
| 4 | 1 | `ReplenishorderService.java` | Add `@Transactional(rollbackFor=Exception.class)` to `redirectSource()`, `update()`, `updateSourceStockUnit()` + add import | High | Low |
| 5 | 1 | `WmsConstants.java` | Add `CODE_FIX_PICK_POSITION` and `CODE_CLEANUP_PICKING_POSITION` | None | None |
| 6 | 1 | `PickingorderPositionRepository.java:17` | Extend `NoDeletePagingAndSortingRepository` | Medium | None |
| 7 | 2 | `ReplenishmentOrderMaintenanceService.java:370` | Log at ERROR level in `releaseReservation()` | Low | None |
| 8 | 2 | `StockunitRepository.java` | Consider `NoDeletePagingAndSortingRepository` | Low | Low |
| 9 | 2 | All service classes | Audit `rollbackFor` across codebase | Systemic | High |
| 10 | 3 | Production DB | Run leaked reservation detection query + manual correction | N/A | Low |
| 11 | Deferred | `CustomerorderService.java:593-633` | Add unreserve for unpicked positions in `cleanUpCancelledOrder()` — see [Deferred Section](#8-deferred-fix-5--cleanupCancelledorder-missing-unreserve) | Medium | Medium |

---

## 8. Deferred: Fix #5 — `cleanUpCancelledOrder()` Missing Unreserve

**Status:** ON HOLD — Validated as a real bug, deferred to a future release.
**Severity:** Medium
**Risk:** Medium — touches the order cancellation workflow, needs careful testing with partially-picked orders.

### Bug Description

**File:** `CustomerorderService.java:593-633`

`cleanUpCancelledOrder()` cancels an order, moves the tote to clearing, and cancels all positions — but **never unreserves picking positions' stock**. Compare with `cancelOrderPosition()` in `CustomerorderPositionService.java:115-121` which properly calls `changeReservedAmount(...negate())`.

**When triggered:**
1. `PickingorderBusinessService.finishPickingOrder()` line 134 — when `markedforcancellation` is true
2. `CustomerorderService.cancelOrder()` line 526 — when order has `pickingconfirmationsent=true`

**Impact:** For partially-picked orders (some positions PICKED, others still PROCESSABLE/STARTED), the un-picked positions still have active reservations that are never released.

**Three cancellation paths in `CustomerorderService`:**
1. `cancelOrder()` when `canOrderPositionBeCancelled=true` → calls `cancelOrderPosition()` → **correctly unreserves**
2. `forceCancelOrder()` → directly calls `changeReservedAmount()` → **correctly unreserves**
3. `cleanUpCancelledOrder()` → sets state to CANCELED but **never unreserves** — the bug

**Review note:** The external review (`260424-Reservation_Leak_Fix_Plan_Review.md`) incorrectly claimed this is INVALID, asserting a "soft cancel" mode that intentionally holds reservations. Re-validation confirmed the review is wrong — `cleanUpCancelledOrder()` sets order state to `CANCELED` (terminal, line 606), sets all positions to `CANCELED` (line 612), and no subsequent processing step exists to release the reservations. The `markedforcancellation` flag is a deferral mechanism, not a "soft cancel mode."

### Implementation Code

**File:** `CustomerorderService.java:593-633`

Before the order state change (line 606), add:

```java
// Unreserve any unpicked picking positions
List<PickingorderPosition> pickingPositions = pickingorderPositionRepository
    .getPickingorderPositionsByParcelexternalnumber(customerOrder.getParcelexternalnumber());
for (PickingorderPosition position : pickingPositions) {
    if (position.getState() < WmsConstants.State.PICKED
            && position.getPickfromstockunitId() != null) {
        Stockunit stockUnit = stockunitRepository.findById(
            position.getPickfromstockunitId()).orElse(null);
        if (stockUnit != null) {
            try {
                stockunitBusinessService.changeReservedAmount(
                    stockUnit,
                    position.getAmount().negate(),
                    true,  // zeroIfNegative
                    WmsConstants.CODE_CANCELLED_ORDER_FROM_WEBSERVICE,
                    position.getNumber(),
                    "cleanup cancelled order - unreserve unpicked"
                );
            } catch (FacadeException e) {
                LOG.error("Failed to unreserve stock for picking position {} during order cleanup: {}",
                    position.getNumber(), e.getMessage());
            }
        }
        // Also clear the FK reference to match the pattern in cancelOrderPosition()
        position.setPickfromstockunitId(null);
        pickingorderPositionRepository.save(position);
    }
}
```

**Why `catch` instead of `throw`:** `cleanUpCancelledOrder()` is called during order finalization. Failing the entire cancellation because one unreserve fails would leave the order in a stuck state. Logging at ERROR and continuing is safer — the reservation leak is minor compared to a stuck order. The class-level `@Transactional` ensures the state changes are atomic within the same transaction.

### Business Logic Impact

| Concern | Assessment |
|---------|------------|
| Is this really a bug? | Yes — three cancel paths exist: `cancelOrder()` and `forceCancelOrder()` correctly unreserve; `cleanUpCancelledOrder()` does not. |
| Already-picked positions? | Filtered by `state < PICKED` check. Picked positions had their `pickfromstockunitId` set to null in `confirmPick()`. |
| Error handling? | Use `catch + LOG.error` not `throw` — failing the cancellation is worse than a leaked reservation. |

### Testing Checklist

- [ ] **Fully picked order**: No unreserve attempted (positions have null `pickfromstockunitId` after `confirmPick`)
- [ ] **Partially picked order**: Only unpicked positions' reservations released, `pickfromstockunitId` set to null
- [ ] **No picking positions**: No-op, no errors
- [ ] **Unreserve fails for one position**: `LOG.error` emitted, cancellation continues, other positions still unreserved
