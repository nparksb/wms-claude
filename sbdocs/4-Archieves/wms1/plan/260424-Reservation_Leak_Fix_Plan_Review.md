# Reservation Leak Fix Plan — Deep Review & Validation

**Reviewer:** Claude (Augment AI)
**Review Date:** 2025-01-XX
**Plan Under Review:** `260424-Reservation_Leak_Fix_Plan.md` (2026-03-07)
**Methodology:** Codebase-wide validation, cross-reference with actual implementation, business logic impact assessment

---

## Executive Summary

**Overall Assessment:** The plan identifies REAL issues but contains **critical gaps** and **incorrect severity assessments**. Of the 5 proposed fixes, **3 are valid and critical**, **1 is valid but low-priority**, and **1 requires significant revision**.

| Fix # | Issue | Verdict | Actual Severity | Notes |
|-------|-------|---------|-----------------|-------|
| Fix #1 | `fixPickingPosition()` leak | ✅ **VALID & CRITICAL** | **CRITICAL** | Confirmed orphaned reservation on every call |
| Fix #2 | `checkAndCleanUpPickingOrderPositions()` | ⚠️ **PARTIALLY VALID** | **MEDIUM** | Audit trail issue real; race condition overstated; deletion concern invalid |
| Fix #3 | Replenishment cancel over-release | ✅ **VALID & CRITICAL** | **CRITICAL** | One-line bug destroys other orders' reservations |
| Fix #4 | Replenishment redirect non-atomic | ✅ **VALID & HIGH** | **HIGH** | Real race window, but existing `@Version` provides partial protection |
| Fix #5 | Cancelled order missing unreserve | ❌ **NOT SUBSTANTIATED** | **N/A** | `cleanUpCancelledOrder()` is terminal, but no reachable reservation leak is shown |

**Critical Finding Not in Plan:** The plan fails to validate whether the proposed fixes introduce **new bugs** or break existing business logic. My analysis found **2 breaking changes** in the proposed implementations.

---

## 1. Fix #1: `fixPickingPosition()` Leak

### Validation: ✅ CONFIRMED CRITICAL

**Evidence Chain:**
1. Method signature: `PickingorderPositionService.fixPickingPosition(PickingorderPosition, Stockunit)` (line 73)
2. Line 120: `changeReservedAmount(replacement, amount, false, ...)` — reserves on new stock unit
3. Line 121: `setPickfromstockunitId(replacement.getId())` — overwrites FK reference
4. Line 124: `save(pickingOrderPosition)` — persists
5. **No unreserve call exists** for the original stock unit (searched entire method body)

**Callers Confirmed:**
- `PickingOrderPositionController.fixPickingPosition()` (line 59) — REST endpoint, no compensation
- `MobilePickingService.processPick()` (line 358) — mobile flow, no compensation

**Business Impact:**
- Every call leaks `pickingOrderPosition.amount` from the original stock unit's `reservedamount`
- Leaked reservations accumulate indefinitely (no cleanup job exists)
- Eventually blocks legitimate picks when `amount - reservedamount < 0`

### Proposed Fix Review: ⚠️ NEEDS REVISION

**Original Proposal:**
```java
@Transactional
public void fixPickingPosition(PickingorderPosition pos, Stockunit replacement) {
    Stockunit original = stockunitRepository.findById(pos.getPickfromstockunitId()).orElse(null);
    if (original != null && !original.getId().equals(replacement.getId())) {
        changeReservedAmount(original, pos.getAmount(), true, ...);
    }
    changeReservedAmount(replacement, pos.getAmount(), false, ...);
    pos.setPickfromstockunitId(replacement.getId());
    save(pos);
}
```

**Issues Found:**

#### Issue 1.1: Missing Null Check on `pos.getPickfromstockunitId()`
**Severity:** HIGH

The current implementation at line 121 shows:
```java
pickingOrderPosition.setPickfromstockunitId(replacement.getId());
```

This means `pickfromstockunitId` can be null initially (new picking position not yet assigned). The proposed fix would throw `NullPointerException` on line 2.

**Correct Fix:**
```java
Long originalStockUnitId = pos.getPickfromstockunitId();
if (originalStockUnitId != null && !originalStockUnitId.equals(replacement.getId())) {
    Stockunit original = stockunitRepository.findById(originalStockUnitId)
        .orElseThrow(() -> new BusinessException("Original stock unit not found: " + originalStockUnitId));
    changeReservedAmount(original, pos.getAmount(), true, ...);
}
```

#### Issue 1.2: Silent Failure on Missing Original Stock Unit
**Severity:** MEDIUM

The proposed `orElse(null)` swallows the case where the original stock unit was deleted. This is a data integrity violation that should be logged or throw an exception.

**Recommendation:** Use `orElseThrow()` with a descriptive exception, OR log a warning if silent continuation is acceptable.

#### Issue 1.3: Missing `@Transactional` Propagation Strategy
**Severity:** MEDIUM

The plan correctly identifies the need for `@Transactional`, but doesn't specify propagation. The method is called from:
- `MobilePickingService.processPick()` which is `@Transactional` (line 341)
- `PickingOrderPositionController.fixPickingPosition()` which has NO transaction

**Correct Annotation:**
```java
@Transactional(propagation = Propagation.REQUIRED)
```

This ensures it joins the existing transaction in `processPick()` but creates a new one when called from the controller.

### Revised Fix #1:

```java
@Transactional(propagation = Propagation.REQUIRED)
public void fixPickingPosition(PickingorderPosition pos, Stockunit replacement) {
    Long originalStockUnitId = pos.getPickfromstockunitId();
    
    // Only unreserve if there was a previous assignment and it's different
    if (originalStockUnitId != null && !originalStockUnitId.equals(replacement.getId())) {
        Stockunit original = stockunitRepository.findById(originalStockUnitId)
            .orElseThrow(() -> new BusinessException(
                "Cannot fix picking position: original stock unit " + originalStockUnitId + " not found"
            ));
        
        // Release reservation from original stock unit
        changeReservedAmount(original, pos.getAmount(), true, 
            "Fix picking position - unreserve from original SU");
    }
    
    // Reserve on replacement stock unit (only if different from original)
    if (originalStockUnitId == null || !originalStockUnitId.equals(replacement.getId())) {
        changeReservedAmount(replacement, pos.getAmount(), false, 
            "Fix picking position - reserve on replacement SU");
    }
    
    // Update FK reference
    pos.setPickfromstockunitId(replacement.getId());
    save(pos);
}
```

---

## 2. Fix #2: `checkAndCleanUpPickingOrderPositions()` Issues

### Validation: ⚠️ PARTIALLY VALID

**File:** `CustomerorderService.java:214-234`

Let me validate each sub-issue:

#### Issue 2a: No Audit Trail — ✅ VALID (MEDIUM-HIGH)

**Evidence:**
- Line 229: `stockUnit.setReservedamount(stockUnit.getReservedamount().subtract(pos.getAmount()));`
- Line 230: `stockunitRepository.save(stockUnit);`
- This is the **only place** in the service layer that directly manipulates `reservedamount` outside `StockunitBusinessService.changeReservedAmount()`

**Comparison with Correct Pattern:**
`CustomerorderService.forceCancelOrder()` at line 258 uses:
```java
stockunitBusinessService.changeReservedAmount(stockUnit, pos.getAmount(), true, ...);
```

**Verdict:** REAL issue. Bypassing the standard API loses audit trail and violates single-responsibility principle.

#### Issue 2b: No Row Lock / Race Condition — ⚠️ OVERSTATED (LOW)

**Plan's Claim:** "No pessimistic lock → silent data corruption in concurrent scenarios"

**Reality Check:**
1. `Stockunit` entity has `@Version` field (line 43-44 in entity definition)
2. Hibernate's optimistic locking prevents silent lost updates
3. Concurrent modifications result in `OptimisticLockException`, not silent corruption
4. The exception propagates to caller and transaction rolls back

**Evidence from Codebase:**
The `StockunitBusinessService.changeReservedAmount()` method (referenced in the plan as the "correct" pattern) also does NOT use pessimistic locking — it relies on the same `@Version` mechanism.

**Actual Risk:** The race condition exists, but the failure mode is **exception + rollback**, not **silent data loss**. This is a **correctness issue** (operation fails) not a **data integrity issue** (data corrupts).

**Severity Downgrade:** HIGH → LOW (in practice, rare due to low concurrency on cleanup operations)

#### Issue 2c: Physical Deletion Without Compensation — ❌ INVALID

**Plan's Claim:** "Physical deletion at line 232 can fail after reservation release at line 230, leaving orphaned reservation"

**Reality Check:**
1. `CustomerorderService` has class-level `@Transactional` (line 27)
2. All operations in `checkAndCleanUpPickingOrderPositions()` are in the same transaction
3. If `delete()` at line 232 fails, the entire transaction rolls back, including the `save()` at line 230
4. **No partial failure is possible** — this is guaranteed by Spring's transaction management

**Verdict:** The partial-failure claim is incorrect. The audit trail concern (2a) is valid, but the atomicity concern is not.

### Proposed Fix Review: ✅ ACCEPTABLE WITH MINOR REVISION

**Original Proposal:**
```java
private void checkAndCleanUpPickingOrderPositions(Customerorder order) {
    List<PickingorderPosition> positions = pickingorderPositionRepository
        .findByCustomerorderIdAndStateNot(order.getId(), WmsConstants.State.PICKED);
    
    for (PickingorderPosition pos : positions) {
        Stockunit stockUnit = stockunitRepository.findById(pos.getPickfromstockunitId()).orElse(null);
        if (stockUnit != null) {
            stockunitBusinessService.changeReservedAmount(stockUnit, pos.getAmount(), true, 
                "Cleanup picking position for cancelled order");
        }
        pickingorderPositionRepository.delete(pos);
    }
}
```

**Minor Issue:** Missing null check on `pos.getPickfromstockunitId()` (same as Fix #1).

**Revised Fix #2:**

```java
private void checkAndCleanUpPickingOrderPositions(Customerorder order) {
    List<PickingorderPosition> positions = pickingorderPositionRepository
        .findByCustomerorderIdAndStateNot(order.getId(), WmsConstants.State.PICKED);
    
    for (PickingorderPosition pos : positions) {
        Long stockUnitId = pos.getPickfromstockunitId();
        if (stockUnitId != null) {
            Stockunit stockUnit = stockunitRepository.findById(stockUnitId).orElse(null);
            if (stockUnit != null) {
                stockunitBusinessService.changeReservedAmount(stockUnit, pos.getAmount(), true, 
                    "Cleanup picking position for cancelled order " + order.getOrdernr());
            } else {
                log.warn("Stock unit {} not found when cleaning up picking position {} for order {}", 
                    stockUnitId, pos.getId(), order.getOrdernr());
            }
        }
        pickingorderPositionRepository.delete(pos);
    }
}
```

---

## 3. Fix #3: Replenishment Cancel Over-Release

### Validation: ✅ CONFIRMED CRITICAL (SECOND VERIFICATION COMPLETE)

**Files:**
- `docs/plan/260424-Reservation_Leak_Fix_Plan.md:122-150`
- `src/main/java/net/aim_ai/wms/service/ReplenishorderService.java:172-190`
- `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:311-338`

**Plan's Claim:** `cancelReplenishmentOrder()` releases the **entire** stock unit reservation instead of just the cancelled order's amount.

**Second Verification Result:** The supporting code added to the plan is accurate, and the live implementation confirms the bug exactly as claimed.

**Evidence Chain:**
1. `ReplenishorderService.cancelReplenishmentOrder()` loads the source stock unit.
2. It calls:
   `changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true, ...)`
3. `StockunitBusinessService.changeReservedAmount()` computes `newReservedAmount = oldReservedAmount.add(amount)`.
4. Passing `sourceStock.getReservedamount().negate()` therefore computes:
   `oldReservedAmount + (-oldReservedAmount) = 0`
5. Result: cancelling a single replenishment order clears the stock unit's **full current reservation**, not just that order's reserved share.

**Why this is critical:**
- Multiple replenishment orders can reserve against the same source stock unit.
- Cancelling one order can wipe out reservations belonging to other still-active orders.
- The `zeroIfNegative=true` flag does **not** make this safe; it only clamps overshoot to zero, which still destroys unrelated reservations.

**Concrete scenario:**
- Stock unit reserved amount = 30
- Order A requested amount = 10
- Order B requested amount = 20
- Cancel Order A → current code passes `-30`, not `-10`
- New reserved amount becomes `0`, so Order B's 20-unit reservation is lost

**Cross-check against corrected pattern:**
`ReplenishmentOrderMaintenanceService.cancelOrder()` correctly derives the release amount from `safe(order.getRequestedamount())` and releases only that order's reservation.

**Verdict:** The Bug #3 claim is now fully substantiated by both the updated plan evidence and the actual production code. Severity remains **CRITICAL**.

**Minimal fix:** Replace `sourceStock.getReservedamount().negate()` with `replenishOrder.getRequestedamount().negate()`.

---

## 4. Fix #4: Replenishment Redirect Non-Atomic

### Validation: ✅ CONFIRMED HIGH (with caveats)

**File:** `ReplenishorderService.redirectSource()` (lines 149+166 referenced in plan)

**Plan's Claim:** The unreserve-old + reserve-new sequence is not atomic, creating a race window.

**Evidence from Plan:**
```java
// Line 149: unreserve old
changeReservedAmount(oldSource, order.getRequestedamount(), true, ...);
// Line 166: reserve new
changeReservedAmount(newSource, order.getRequestedamount(), false, ...);
```

**Race Scenario:**
1. Thread A: unreserves 100 units from stock unit X
2. Thread B: picks 100 units from stock unit X (now appears available)
3. Thread A: reserves 100 units on stock unit Y
4. Result: Stock unit X is over-picked by 100 units

**Reality Check:**
1. `Stockunit` has `@Version` field → optimistic locking
2. If Thread B's pick commits first, Thread A's unreserve will fail with `OptimisticLockException`
3. The transaction rolls back, preventing the over-pick

**However:** The race is still REAL because:
- The failure mode is **operation failure** (redirect fails), not silent corruption
- In high-concurrency scenarios, redirect operations will fail frequently
- This degrades system reliability

**Severity Assessment:** HIGH (not CRITICAL) because:
- Data integrity is protected by `@Version`
- Impact is operational (failed redirects) not data corruption
- Frequency depends on concurrency (likely low in practice)

### Proposed Fix Review: ✅ CORRECT APPROACH

**Original Proposal:**
```java
@Transactional(propagation = Propagation.REQUIRES_NEW)
public void redirectSource(Replenishorder order, Stockunit newSource) {
    Stockunit oldSource = stockunitRepository.findByIdForUpdate(order.getSourceId())
        .orElseThrow(...);
    Stockunit newSourceLocked = stockunitRepository.findByIdForUpdate(newSource.getId())
        .orElseThrow(...);
    
    changeReservedAmount(oldSource, order.getRequestedamount(), true, ...);
    changeReservedAmount(newSourceLocked, order.getRequestedamount(), false, ...);
    
    order.setSourceId(newSource.getId());
    save(order);
}
```

**Validation:**
1. ✅ `REQUIRES_NEW` ensures independent transaction (correct for lock isolation)
2. ✅ `findByIdForUpdate()` acquires pessimistic locks on both stock units
3. ✅ Locks held until transaction commits (atomic unreserve+reserve)
4. ✅ Lock timeout configured (5 seconds per plan) prevents deadlock

**Potential Issue:** Lock ordering could cause deadlock if two threads redirect in opposite directions:
- Thread A: locks SU1, then SU2
- Thread B: locks SU2, then SU1
- Deadlock!

**Recommendation:** Add deterministic lock ordering:
```java
// Lock in ascending ID order to prevent deadlock
Stockunit first, second;
boolean oldIsFirst = oldSource.getId() < newSource.getId();

if (oldIsFirst) {
    first = stockunitRepository.findByIdForUpdate(oldSource.getId()).orElseThrow(...);
    second = stockunitRepository.findByIdForUpdate(newSource.getId()).orElseThrow(...);
} else {
    first = stockunitRepository.findByIdForUpdate(newSource.getId()).orElseThrow(...);
    second = stockunitRepository.findByIdForUpdate(oldSource.getId()).orElseThrow(...);
}

// Now use the locked entities (assign back to oldSource/newSource for clarity)
Stockunit oldSourceLocked = oldIsFirst ? first : second;
Stockunit newSourceLocked = oldIsFirst ? second : first;

changeReservedAmount(oldSourceLocked, order.getRequestedamount(), true, ...);
changeReservedAmount(newSourceLocked, order.getRequestedamount(), false, ...);
```

---

## 5. Fix #5: Cancelled Order Missing Unreserve

### Validation: ❌ NOT SUBSTANTIATED AS A REACHABLE RESERVATION LEAK

**Plan's Claim:** `CustomerorderService.cleanUpCancelledOrder()` performs terminal cancellation but never unreserves stock, so it leaks reservations.

**Re-validation Result:** The first half is correct: `cleanUpCancelledOrder()` is clearly a **terminal** path, and my earlier "soft cancel" explanation was not supported by code. However, that still does **not** prove a leak. After tracing the actual call paths, I do not find evidence that this method is reached while relevant reservations are still outstanding.

**What is confirmed:**
1. `cleanUpCancelledOrder()` sets the order state to `CANCELED`.
2. It also sets all `CustomerorderPosition` records to `CANCELED`.
3. It does **not** call `changeReservedAmount()` and does **not** iterate over `PickingorderPosition` records.

**Why the leak is still unproven:**
1. `cancelOrder()` calls `cleanUpCancelledOrder()` only when `orderCanBeCancelled == false` **and** `customerOrder.getPickingconfirmationsent() == true`.
2. `pickingconfirmationsent` is set in `PickingorderBusinessService.finishPickingOrder()`.
3. `finishPickingOrder()` throws if any `PickingorderPosition` in the picking order is still `< PICKED`.
4. A successful `confirmPick()` already releases the reservation via
   `changeReservedAmount(stockUnit, pickingPosition.getAmount().negate(), true, ...)`
   and then clears `pickfromstockunitId`.
5. The other `cleanUpCancelledOrder()` call site is also inside `finishPickingOrder()` when `markedforcancellation == true`, which again only runs after the same `all positions >= PICKED/CANCELED` gate.

**Comparison with the other cancellation paths:**
- `cancelOrderPosition()` explicitly unreserves because it handles pre-finish cancellation of still-assigned stock.
- `forceCancelOrder()` explicitly unreserves because it cancels before pick completion.
- `cleanUpCancelledOrder()` appears to be a **post-pick cleanup/finalization path** (tote clearing, order/position state cleanup), not the stage where reservation release normally occurs.

**Important correction to my earlier review:**
The prior "soft cancel" rationale was wrong and is withdrawn. The correct reason for rejecting Fix #5 is narrower: the plan has not demonstrated a **reachable scenario** where `cleanUpCancelledOrder()` runs while any corresponding `PickingorderPosition` still has an active reservation to release.

**Residual uncertainty:**
If the plan can show a concrete path where a customer order still has `PickingorderPosition` records with:
- `state < PICKED`, and
- non-null `pickfromstockunitId`, and
- `cleanUpCancelledOrder()` is invoked anyway,
then this verdict should be revisited. I did not find such a path in the current code review.

**Verdict:** Fix #5 should still be removed from the implementation plan **as currently justified**, but for a different reason than I originally wrote: the bug is **not substantiated by the reachable call flow**.

---

## 6. Critical Gaps in the Plan

### Gap 1: No Cleanup Strategy for Existing Leaked Reservations

**Issue:** The plan fixes future leaks but doesn't address existing leaked reservations in production.

**Required Addition:**
1. SQL query to detect leaked reservations:
```sql
SELECT su.id, su.labelid, su.amount, su.reservedamount,
       COALESCE(SUM(pop.amount), 0) as actual_reserved,
       su.reservedamount - COALESCE(SUM(pop.amount), 0) as leaked_amount
FROM stockunit su
LEFT JOIN pickingorder_position pop ON pop.pickfromstockunit_id = su.id 
    AND pop.state < 600  -- not yet picked
WHERE su.reservedamount > 0
GROUP BY su.id
HAVING su.reservedamount > COALESCE(SUM(pop.amount), 0);
```

2. Scheduled job to auto-correct leaks (or manual correction procedure)

### Gap 2: No Rollback Plan

**Issue:** If the fixes introduce regressions, how do we roll back?

**Required Addition:**
1. Feature flag to enable/disable new reservation logic
2. Monitoring to detect increased `OptimisticLockException` rates
3. Rollback procedure (revert commits + run cleanup SQL)

### Gap 3: No Performance Impact Assessment

**Issue:** Adding pessimistic locks (Fix #4) will increase lock contention.

**Required Addition:**
1. Benchmark current redirect operation latency
2. Estimate lock wait time impact (5-second timeout × failure rate)
3. Capacity planning for increased transaction duration

---

## 7. Recommended Implementation Order

**Phase 1: Critical Fixes (Week 1)**
1. Fix #1 (revised version) — stops new leaks immediately
2. Fix #3 (confirmed by second verification) — prevents catastrophic multi-order corruption
3. Deploy to staging, monitor for 48 hours

**Phase 2: Cleanup (Week 2)**
4. Run leaked reservation detection query
5. Manual correction of existing leaks (or automated job)
6. Fix #2 (revised version) — improves audit trail

**Phase 3: Hardening (Week 3)**
7. Fix #4 (with deadlock prevention) — reduces race conditions
8. Add monitoring for `PessimisticLockException` and `OptimisticLockException`
9. Deploy to production with feature flag

**Phase 4: Validation (Week 4)**
10. Run leaked reservation query weekly for 1 month
11. Confirm zero new leaks
12. Remove feature flag

---

## 8. Final Verdict

| Aspect | Rating | Notes |
|--------|--------|-------|
| **Problem Identification** | 8/10 | Correctly identified 3 real critical issues; 1 invalid issue; 1 overstated severity |
| **Root Cause Analysis** | 8/10 | Accurate for Fix #1 and #3; Fix #5 rationale corrected, but the claimed leak still remains unsubstantiated |
| **Proposed Solutions** | 6/10 | Correct approach but missing edge cases (null checks, deadlock prevention) |
| **Completeness** | 4/10 | Missing cleanup strategy, rollback plan, performance assessment |
| **Implementation Readiness** | 5/10 | Needs revisions before coding can begin |

**Overall Recommendation:** **APPROVE WITH MAJOR REVISIONS**

The plan correctly identifies critical reservation leaks but requires:
1. Revised implementations for Fix #1, #2, #4 (per this review)
2. Removal of Fix #5 (not substantiated by reachable code path)
3. Addition of cleanup strategy, rollback plan, monitoring

**Estimated Effort:** 3-4 weeks (revised from plan's implied 1-2 weeks)

---

## Appendix A: Code Patterns to Avoid

**Anti-Pattern 1: Direct `reservedamount` Manipulation**
```java
// ❌ BAD
stockUnit.setReservedamount(stockUnit.getReservedamount().subtract(amount));
stockunitRepository.save(stockUnit);

// ✅ GOOD
stockunitBusinessService.changeReservedAmount(stockUnit, amount, true, "reason");
```

**Anti-Pattern 2: Reservation Change Without Transaction**
```java
// ❌ BAD
public void updateReservation(...) {  // no @Transactional
    changeReservedAmount(...);
}

// ✅ GOOD
@Transactional(propagation = Propagation.REQUIRED)
public void updateReservation(...) {
    changeReservedAmount(...);
}
```

**Anti-Pattern 3: Multi-Entity Update Without Locking**
```java
// ❌ BAD
Stockunit su1 = repo.findById(id1).get();
Stockunit su2 = repo.findById(id2).get();
// modify both, race condition possible

// ✅ GOOD
Stockunit su1 = repo.findByIdForUpdate(id1).get();  // locks row
Stockunit su2 = repo.findByIdForUpdate(id2).get();  // locks row
// modifications are atomic
```

---

**End of Review**
