# V2 Migration Plan — Order 241019 Cancellation Fix (confirmPick Race Condition)

- **Date:** 2026-03-26
- **Status:** IMPLEMENTED — All 5 code fixes applied, 4 new tests added, 8 existing tests updated. 128 tests run: 0 failures, 4 pre-existing errors (unrelated CustomerorderBatchService null mock)
- **Priority:** High
- **V1 Source Plan:** `docs/plan/v1-fixes/260424-Order_241019_Cancellation_Fix.md`
- **V1 Branch:** `release` (wms-api)
- **V2 Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## Summary

The V1 plan fixed a race condition in `PickingorderBusinessService.confirmPick()` where concurrent "last pick" transactions could both skip parent state promotion, leaving picking orders stuck in an inconsistent state (positions PICKED but parent pickingorder at PROCESSABLE/STARTED). The fix was to lock parent rows (Customerorder and Pickingorder) using `findByIdForUpdate()` before reading and promoting state.

**V2 Analysis Result:** The race condition **still exists** in V2's `confirmPick()`. The fix is **NOT redundant** and **must be applied**.

---

## V1 Fix Applicability Analysis

### Part 1: One-Time Production Repair SQL
**Status:** NOT APPLICABLE to V2 code migration
This was a one-time SQL repair for a specific stuck order in V1 production. No code changes involved. If the same issue occurs in V2 production, the same SQL pattern can be adapted, but this is an operational concern, not a code fix.

### Part 2, Fix 1+2: Lock parent rows in `confirmPick()`
**Status:** APPLICABLE — Race condition confirmed in V2

### Part 2, Fix 3: Extend admin recovery endpoint
**Status:** DEFERRED in V1, skip for V2 migration

### Part 2, Fix 4: Regression tests
**Status:** APPLICABLE — Tests need updating to verify lock usage

### Part 3: Detection SQL
**Status:** NOT APPLICABLE to code migration (operational SQL)

---

## Root Cause Analysis (V2-Specific)

### The Race Condition in V2 `confirmPick()`

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`
**Method:** `confirmPick()` (lines 361-544)

V2's `confirmPick()` reads parent entities without pessimistic locks:

```java
// Line 389 — NO LOCK on Pickingorder
Optional<Pickingorder> pickingOrderOpt = pickingorderRepository.findById(pickingPosition.getPickingorderId());

// Line 475 — NO LOCK on Customerorder
Customerorder customerOrder = customerorderRepository.findById(coPositionOrderId)
    .orElseThrow(() -> new EntityNotFoundException("CustomerOrder", coPositionOrderId));
```

Later, state promotion decisions are made based on these unlocked reads:

- **Line 515-525:** Customerorder state promoted to PICKED/PENDING based on sibling position states
- **Line 537-541:** Pickingorder state promoted to PICKED when all positions are done

**Race mechanism (identical to V1):**
- Transaction A: confirms pick for position 1 -> sets it to PICKED -> reads siblings -> sees position 2 NOT yet PICKED (tx B uncommitted) -> doesn't promote parent
- Transaction B: confirms pick for position 2 -> sets it to PICKED -> reads siblings -> sees position 1 NOT yet PICKED (tx A uncommitted) -> doesn't promote parent
- Both commit -> all positions PICKED but parent pickingorder stays at PROCESSABLE(300) or STARTED(500)

### Caller Analysis

`confirmPick()` is called from two paths:

| Caller | Line | Locks pickingorder before call? | Risk |
|--------|------|-------------------------------|------|
| `MobilePickingService.processPick()` | 520 | **YES** — `findByIdForUpdate` at line 388 | Partial — pickingorder locked, but customerorder is NOT locked |
| `MobilePickingService.rapidPickingScanSource()` | 1144 | **NO** — `findById` at line 1061 | **Full race** — neither parent is locked |

Even though `processPick` locks the pickingorder at line 388, `confirmPick` re-reads it with `findById` at line 389. Since they share the same transaction (both `@Transactional(REQUIRED)`), the JPA persistence context returns the already-managed entity — so the pickingorder lock is preserved for this path. However:

1. **The customerorder is NEVER locked** in the `processPick` path — the race on customerorder state promotion (lines 515-525) is fully exposed
2. **The rapid picking path** (`rapidPickingScanSource`) locks NEITHER parent — both races are fully exposed
3. **No fresh re-read** before final customerorder state promotion — V1 added `findByIdForUpdate` as a fresh re-read before the final promotion check to ensure committed sibling states are visible

---

## Changes by File

### 1. `PickingorderBusinessService.java`

**V2 path:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| **FIX-1a** | Lock Customerorder early (before validation) | 389-395 | **DONE** | Added early customerorder lock via customerorderPosition lookup | High |
| **FIX-1b** | Lock Pickingorder in confirmPick | 396 | **DONE** | Changed `findById` to `findByIdForUpdate` | High |
| **FIX-1c** | Lock Customerorder for state update | 482 | **DONE** | Changed `findById` to `findByIdForUpdate` | High |
| **FIX-1d** | Fresh re-read Customerorder before final promotion | 522-535 | **DONE** | Added `findByIdForUpdate` re-read before state promotion block | High |

#### FIX-1a: Early Customerorder Lock

**Insertion point:** After line 388 (after the `pickingUnitLoad` null check), before line 389 (pickingorder read).

**Why:** Lock ordering must be consistent to prevent deadlocks. V1 established the convention: lock Customerorder first (3rd in lock order), then Pickingorder (5th). By locking the customerorder before the pickingorder, we prevent deadlocks between concurrent `confirmPick` and other operations that lock in the same order.

**Fix:**
```java
// Lock ordering: Customerorder first, then Pickingorder — prevents deadlocks
// between concurrent "last pick" transactions (V1 Order_241019 fix)
CustomerorderPosition copForLock = customerorderPositionRepository.findById(pickingPosition.getCustomerorderpositionId()).orElse(null);
if (copForLock != null) {
    customerorderRepository.findByIdForUpdate(copForLock.getOrderId());
}
```

**Dependencies:** `customerorderPositionRepository` and `customerorderRepository` — both already injected in `PickingorderBusinessService` (verify constructor injection).

#### FIX-1b: Lock Pickingorder

**Current code (line 389):**
```java
Optional<Pickingorder> pickingOrderOpt = pickingorderRepository.findById(pickingPosition.getPickingorderId());
```

**Fix:**
```java
Optional<Pickingorder> pickingOrderOpt = pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId());
```

**Why:** Prevents two concurrent confirmPick calls from both reading the same pickingorder in `< PICKED` state and both skipping the promotion at lines 537-541. The `findByIdForUpdate` method already exists in `PickingorderRepository.java:22-24`.

#### FIX-1c: Lock Customerorder for State Update

**Current code (line 475):**
```java
Customerorder customerOrder = customerorderRepository.findById(coPositionOrderId)
    .orElseThrow(() -> new EntityNotFoundException("CustomerOrder", coPositionOrderId));
```

**Fix:**
```java
Customerorder customerOrder = customerorderRepository.findByIdForUpdate(coPositionOrderId)
    .orElseThrow(() -> new EntityNotFoundException("CustomerOrder", coPositionOrderId));
```

**Why:** This is the read that feeds the state promotion at lines 515-525. Without a lock, two transactions can both read the customerorder as `< PICKED` and both skip or duplicate the promotion.

#### FIX-1d: Fresh Re-Read Before Final State Promotion

**Current code (lines 515-525):**
```java
if (hasAllPicked) {
    if (hasPendingPicks) {
        LOG.info("Found pending picks for order. number={}", customerOrder.getNumber());
        customerOrder.setState(WmsConstants.State.PENDING);
    } else {
        LOG.info("Everything picked for order. Confirm order. number={}", customerOrder.getNumber());
        customerOrder.setState(WmsConstants.State.PICKED);
    }
    customerorderRepository.save(customerOrder);
}
```

**Fix:**
```java
if (hasAllPicked) {
    // Re-read under lock to get fresh state after sibling position saves
    Customerorder freshOrder = customerorderRepository.findByIdForUpdate(customerOrder.getId())
        .orElseThrow(() -> new EntityNotFoundException("CustomerOrder", customerOrder.getId()));

    if (hasPendingPicks) {
        LOG.info("Found pending picks for order. number={}", freshOrder.getNumber());
        freshOrder.setState(WmsConstants.State.PENDING);
    } else {
        LOG.info("Everything picked for order. Confirm order. number={}", freshOrder.getNumber());
        freshOrder.setState(WmsConstants.State.PICKED);
    }
    customerorderRepository.save(freshOrder);
}
```

**Why:** V1 added this pattern (line 354 in V1). Even with the lock at line 475, the sibling position queries at lines 503-513 may see stale data if another transaction committed between line 475 and line 503. The fresh re-read ensures we see the latest committed state before making the promotion decision. This is defense-in-depth.

---

### 2. `MobilePickingService.java` — Rapid Picking Path

**V2 path:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

| # | Fix | V2 Line | Status | Action | Priority |
|---|-----|---------|--------|--------|----------|
| **FIX-2** | Lock Pickingorder in rapidPickingScanSource | 1061 | **DONE** | Changed `findById` to `findByIdForUpdate` | High |

#### FIX-2 Detail

**Current code (line 1061):**
```java
Pickingorder pickingOrder = pickingorderRepository.findById(pickingPosition.getPickingorderId())
    .orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingPosition.getPickingorderId()));
```

**Fix:**
```java
Pickingorder pickingOrder = pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())
    .orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingPosition.getPickingorderId()));
```

**Why:** `rapidPickingScanSource` calls `confirmPick` at line 1144 but never locks the pickingorder. Unlike `processPick` (which locks at line 388), this path is completely unprotected. Two rapid pickers confirming the last two positions concurrently can both skip parent promotion.

**Note:** The customerorder lock will be handled inside `confirmPick` by FIX-1a, so no additional change needed here.

---

### 3. Dependency Verification for `PickingorderBusinessService`

FIX-1a requires `customerorderPositionRepository` to be available in `PickingorderBusinessService`. Verify this:

| Dependency | Needed For | Status |
|-----------|-----------|--------|
| `customerorderPositionRepository` | FIX-1a — look up customerorder from picking position | **Already injected** — field at line 38, constructor at line 68 |
| `customerorderRepository` | FIX-1a, FIX-1c, FIX-1d — `findByIdForUpdate` | **Already injected** — used at line 475 |
| `pickingorderRepository` | FIX-1b — `findByIdForUpdate` | **Already injected** — used at line 389 |

If `customerorderPositionRepository` is NOT injected, add it as a constructor parameter. V2 uses constructor injection exclusively.

---

## V2-Specific Adaptation Notes

1. **Transaction manager:** All `@Transactional` annotations in `confirmPick()` already specify `value = "tenantTransactionManager"` — no change needed
2. **Lock timeout:** `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` is already configured in `application.properties` (from RC-4 in the previous consolidated fix)
3. **`orElseThrow` pattern:** V2 already uses `.orElseThrow(() -> new EntityNotFoundException(...))` — maintain this pattern
4. **Constructor injection:** If `customerorderPositionRepository` needs to be added, add it as a constructor parameter (not `@Autowired` field)
5. **`findByIdForUpdate` availability:** Both `PickingorderRepository.findByIdForUpdate()` and `CustomerorderRepository.findByIdForUpdate()` already exist with `@Lock(LockModeType.PESSIMISTIC_WRITE)`

---

## Implementation Priority

| # | Fix | File | Description | Priority |
|---|-----|------|-------------|----------|
| 1 | FIX-1a | `PickingorderBusinessService` | Early customerorder lock (lock ordering) | **DONE** |
| 2 | FIX-1b | `PickingorderBusinessService` | Lock pickingorder in confirmPick | **DONE** |
| 3 | FIX-1c | `PickingorderBusinessService` | Lock customerorder for state update | **DONE** |
| 4 | FIX-1d | `PickingorderBusinessService` | Fresh re-read before final promotion | **DONE** |
| 5 | FIX-2 | `MobilePickingService` | Lock pickingorder in rapid picking path | **DONE** |
| 6 | TEST-1 | `PickingorderBusinessServiceUnitTest` | Update existing mocks + add lock verification tests | **DONE** |

All fixes should be implemented together as they address the same race condition across different code paths.

---

## Testing Plan

### Existing Tests That Need Updating

The following tests mock `findById` for pickingorder/customerorder — they must be updated to mock `findByIdForUpdate` instead:

**File:** `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java`

| Test Class | Test Method | Lines to Update | Change |
|-----------|------------|----------------|--------|
| `ConfirmPick` | `throwsWhenPickingOrderNotFoundForConfirmPick` | 380 | `pickingorderRepository.findById(999L)` -> `findByIdForUpdate(999L)` |
| `ConfirmPickHappyPath` | `shouldConfirmPickSuccessfully` | 858, 867 | `pickingorderRepository.findById(1L)` -> `findByIdForUpdate(1L)`, `customerorderRepository.findById(100L)` -> `findByIdForUpdate(100L)` |
| `ConfirmPickHappyPath` | `shouldSendEmptyPalletToNirvana` | 941, 952 | Same pattern |
| `ConfirmPickHappyPath` | (customer order position picked test) | 1016, 1025 | Same pattern |
| `ConfirmPickHappyPath` | (all positions picked - order finished) | 1091, 1100 | Same pattern |
| `ConfirmPickHappyPath` | (wrong unit load) | 1139 | `pickingorderRepository.findById(1L)` -> `findByIdForUpdate(1L)` |
| `ConfirmPickAfterCommit` | `shouldDeferPickingStartedToAfterCommit` | 1315, 1325 | Same pattern |
| `ConfirmPickAfterCommit` | `shouldNotRegisterAfterCommitWhenAlreadyStarted` | ~1394, ~1402 | Same pattern |

**Additionally**, add mock for the early customerorder lock (FIX-1a):
```java
when(customerorderPositionRepository.findById(pickingPosition.getCustomerorderpositionId()))
    .thenReturn(Optional.of(coPosition));
when(customerorderRepository.findByIdForUpdate(coPosition.getOrderId()))
    .thenReturn(Optional.of(customerOrder));
```

### New Tests to Create

**File:** `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java`

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| TEST-1 | `confirmPick_locksPickingOrderWithForUpdate` | Verifies `pickingorderRepository.findByIdForUpdate()` is called (not `findById`) |
| TEST-2 | `confirmPick_locksCustomerOrderWithForUpdate` | Verifies `customerorderRepository.findByIdForUpdate()` is called for state update |
| TEST-3 | `confirmPick_locksCustomerOrderEarlyForLockOrdering` | Verifies early customerorder lock is acquired before pickingorder lock |
| TEST-4 | `confirmPick_freshRereadBeforeFinalPromotion` | Verifies `findByIdForUpdate` is called again before final customerorder state promotion when all positions are picked |

**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePickingServiceUnitTest.java`

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| TEST-5 | `rapidPickingScanSource_locksPickingOrderWithForUpdate` | Verifies `findByIdForUpdate` is used in the rapid picking path |

### Test Template (TEST-1 Example)

```java
@Test
@DisplayName("should lock picking order with findByIdForUpdate in confirmPick")
void confirmPick_locksPickingOrderWithForUpdate() throws FacadeException, BusinessException {
    // Arrange - standard happy path setup
    // ... (same setup as shouldConfirmPickSuccessfully)

    when(pickingorderRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(testPickingOrder));
    // ... other mocks ...

    // Act
    pickingorderBusinessService.confirmPick(pickingPosition, pickingUnitLoad, BigDecimal.TEN, testUser);

    // Assert - verify findByIdForUpdate was called, NOT findById
    verify(pickingorderRepository).findByIdForUpdate(1L);
    verify(pickingorderRepository, never()).findById(1L);
}
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Lock ordering mismatch causes deadlock | Low | High | Follow V1 convention: lock Customerorder before Pickingorder consistently |
| `customerorderPositionRepository` not injected in `PickingorderBusinessService` | **None** | N/A | **Confirmed already injected** — field at line 38, constructor parameter at line 68 |
| Lock contention under high throughput | Low | Medium | Lock timeout already configured at 5s; locks held briefly within existing transaction |
| Optimistic lock retry at lines 437-446 conflicts with pessimistic lock | Low | Low | The retry loop re-reads the position, not the parent; pessimistic lock on parent is compatible |
| Existing tests break due to mock changes | Certain | Low | Tests will fail until mocks are updated — this is expected and validates the fix |

---

## What NOT to Do

- **Do NOT** add locks to the `processPick` caller path for pickingorder — it already locks at line 388. Adding a second lock in `confirmPick` (FIX-1b) is harmless (same transaction, same entity) and protects the rapid picking path.
- **Do NOT** change the `@Transactional` propagation — `REQUIRED` (default) is correct; `confirmPick` should join the caller's transaction.
- **Do NOT** add the early customerorder lock (FIX-1a) to `processPick` or `rapidPickingScanSource` — centralizing it in `confirmPick` ensures all callers are protected.
- **Do NOT** port the V1 production repair SQL — it was a one-time fix for a specific order and is not a code change.
