# WMS V1 — Picking Glitch Fix Plan

**Date:** 2026-02-13
**Based on:** `docs/WMS_V1_Picking_Glitch_Root_Cause_Analysis.md`
**Branch:** `tmp/release-ul-popping-fix`
**Status:** Pending implementation.

---

## Validation of Root Cause Analysis

The RCA analysis is **substantively correct**. The core diagnosis — missing `@Transactional` on `processPick()` and `confirmPick()` causing partial auto-commits — is validated by code review. The following corrections apply:

### Correction 1: Use `@Transactional`, NOT `@Transactional("tenantTransactionManager")`

Same correction as the UL Popping fix. **No named transaction manager exists in this codebase.** All 17+ existing `@Transactional` annotations use plain `@Transactional` or `@Transactional(propagation = Propagation.REQUIRES_NEW)`. Using `@Transactional("tenantTransactionManager")` would silently fail to create a transaction.

### Correction 2: `spring.jpa.open-in-view` is NOT `false`

Same as UL Popping fix. The property is not set anywhere — defaults to `true` in Spring Boot 2.3.7. However, the RCA's core conclusion remains valid: OSIV keeps the `EntityManager` open but does NOT wrap requests in a transaction. Each `repository.save()` still auto-commits independently.

### Correction 3: The Retry Logic at "lines 302-310" Does NOT Exist

The RCA describes a try-catch with `ObjectOptimisticLockingFailureException` retry at lines 302-310 of `confirmPick()`. **This code does not exist in the actual release branch.** The picking position save at `PickingorderBusinessService.java:253` is a bare `pickingorderPositionRepository.save(pickingPosition)` with no try-catch at all.

This means the code is **more vulnerable than the RCA describes** — there is zero retry for optimistic locking failures. Any stale entity version throws directly to the controller.

### Correction 4: Line Numbers in RCA vs Actual Code

The RCA references line numbers from a different version of the code. Actual line numbers in the current release:
- `processPick()` starts at line **335** (not 331)
- `confirmPick()` starts at line **185** (not 235)
- OMS callback at line **407-408** (not 404)
- `confirmPick()` call at line **429** (not 425)

### Validation: OMS Callback Has No Timeout — CONFIRMED

`HttpRestService.java:85` creates a `ResteasyClient` via `new ResteasyClientBuilder().build()` with **no timeout configuration**. RESTEasy defaults to infinite connect and read timeouts, confirming the 4-minute blocking described in the RCA.

### Validation: Symptom and Cause Are Correct

The chain of events is verified by reading the code:

1. `processPick()` (line 335) — NO `@Transactional`
2. Tote assignment saves auto-commit at lines 393, 401, 405, 413 — **permanent and irreversible**
3. OMS callback at line 407 — blocks with no timeout, holds thread
4. `confirmPick()` call at line 429 — can throw `ObjectOptimisticLockingFailureException`
5. Controller catches exception, returns error — but tote assignment already committed
6. Result: order stuck with tote assigned but never started

**The RCA correctly identifies both the root cause and the amplifier (OMS timeout).**

---

## Critical Design Consideration: OMS Callback Inside Transaction

Adding `@Transactional` to `processPick()` creates a new concern: the OMS callback (`customerOrderToteAssigned`) at line 407 runs **inside** the transaction. This means:

1. If the callback blocks for 4 minutes → database transaction held open 4 minutes → connection pool exhaustion risk
2. If the callback succeeds but `confirmPick()` later fails → transaction rolls back, but OMS already received the tote assignment notification

**This is why Fix 2 (HTTP timeout) MUST be implemented alongside Fix 1 (`@Transactional`).** With a 15-second timeout, the transaction is held for at most ~15 extra seconds — acceptable.

Additionally, the OMS callback should be wrapped defensively so callback failures don't roll back the entire pick operation.

---

## Fix Plan

### Fix 1: Add `@Transactional` to `processPick()` (CRITICAL)

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

Add `@Transactional` to `processPick()` at line 335. This wraps the entire tote assignment + confirmPick in a single transaction. If `confirmPick()` fails, the tote assignment is rolled back automatically.

```java
// ADD import:
import org.springframework.transaction.annotation.Transactional;

// Line 335 — ADD @Transactional:
@Transactional
public Pickingorder processPick(Pickingorder pickingOrder, PickingorderPosition pickingPosition, String toteName)
    throws BusinessException, FacadeException {
```

**Nesting behavior:** `confirmPick()` is called from `processPick()`. When we add `@Transactional` to both (Fix 1 + Fix 3), the inner `confirmPick()` will join the outer transaction (default `Propagation.REQUIRED`). This is correct — one transaction for the entire operation.

**Risk:** Low. Standard Spring pattern. The transaction now encompasses the OMS callback, which is mitigated by Fix 2 (HTTP timeout).

---

### Fix 2: Add HTTP Timeout to OMS Callback Client (CRITICAL — Must Deploy With Fix 1)

**File:** `src/main/java/net/aim_ai/wms/service/HttpRestService.java`

The `ResteasyClientBuilder` at line 85 has no timeout. Add connect and read timeouts:

```java
// Line 85 — BEFORE:
ResteasyClient resteasyClient = new ResteasyClientBuilder().build();

// AFTER:
import java.util.concurrent.TimeUnit;
// ...
ResteasyClient resteasyClient = new ResteasyClientBuilder()
    .connectTimeout(5, TimeUnit.SECONDS)
    .readTimeout(15, TimeUnit.SECONDS)
    .build();
```

**Why this is CRITICAL with Fix 1:** Without timeouts, `@Transactional` on `processPick()` means a 4-minute OMS callback holds the database transaction open for 4 minutes. With timeouts, the maximum blocking is 20 seconds.

**Risk:** Medium. If the OMS normally responds slowly (>15s), this timeout will cause `ProcessingException` to be thrown. However, log evidence shows the OMS responds in <200ms for `finishedPicking` and 2.6s for `assignedToteID` under normal conditions. The 4-minute blocks are anomalies.

---

### Fix 3: Add `@Transactional` to `confirmPick()` (CRITICAL)

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`

Add `@Transactional` to `confirmPick()` at line 185. This ensures stock transfer + position update + state transitions are atomic, even when called from code paths without their own transaction (e.g., rapid picking).

```java
// ADD import:
import org.springframework.transaction.annotation.Transactional;

// Line 185 — ADD @Transactional:
@Transactional
public Pickingorder confirmPick(PickingorderPosition pickingPosition, PickingorderUnitload pickingUnitLoad,
    BigDecimal amountPicked) throws FacadeException, BusinessException {
```

**Note:** `confirmPick()` is also called from `rapidPickingScanSource()` at line 927 of `MobilePickingService.java`. That method has no `@Transactional` either — the `@Transactional` on `confirmPick()` will be the transaction boundary for that path. This is a defense-in-depth measure.

**Risk:** Low. Standard Spring pattern.

---

### Fix 4: Wrap OMS Callback Defensively (HIGH)

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

The OMS callback at line 407 currently only catches `IOException` (inside `ManageOrderService`). With Fix 2 (HTTP timeout), `ProcessingException` can be thrown. Wrap the callback defensively so OMS failures don't prevent the pick from completing:

```java
// Lines 407-408 — BEFORE:
if (basicService.isProduction())
    manageOrderService.customerOrderToteAssigned(Collections.singletonList(customerOrder));

// AFTER:
if (basicService.isProduction()) {
    try {
        manageOrderService.customerOrderToteAssigned(Collections.singletonList(customerOrder));
    } catch (Exception e) {
        LOG.error("OMS tote assigned callback failed for order " + customerOrder.getNumber() + ", continuing with pick", e);
    }
}
```

**Why:** The OMS callback is a notification — it should not prevent the warehouse pick from completing. If OMS wasn't notified, the tote assignment is still recorded in WMS and OMS will be synced on the `finishedPicking` callback later.

**Risk:** Low. Worst case: OMS is temporarily unaware of tote assignment, but `finishedPicking` callback will update OMS when the order completes.

---

### Fix 5: Add `@Transactional` to `rapidPickingScanSource()` (MEDIUM)

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

`rapidPickingScanSource()` at line 840 calls `confirmPick()` at line 927 without a wrapping transaction. While Fix 3 adds `@Transactional` to `confirmPick()` itself, the operations before `confirmPick()` in `rapidPickingScanSource()` (e.g., `pickingorderRepository.save(pickingOrder)` at line 916) are separate auto-commits.

```java
// Line 840 — ADD @Transactional:
@Transactional
public PickingHighPositionInfoDto rapidPickingScanSource(PickingorderPosition pickingPosition, String source)
    throws BusinessException, FacadeException {
```

**Risk:** Low. Same pattern as Fix 1.

---

## Implementation Order

```
Fix 2 (HTTP timeout)     Fix 1 (@Transactional processPick)     Fix 3 (@Transactional confirmPick)
┌──────────────────────┐ ┌─────────────────────────────────┐    ┌──────────────────────────────────┐
│ ResteasyClientBuilder │ │ MobilePickingService            │    │ PickingorderBusinessService       │
│ connect=5s, read=15s  │ │ processPick()                   │    │ confirmPick()                    │
└──────────────────────┘ └─────────────────────────────────┘    └──────────────────────────────────┘
         ▲                         ▲                                      ▲
         │                         │                                      │
    MUST deploy together ──────────┘                                      │
                                                                          │
Fix 4 (Defensive OMS wrap)         Fix 5 (@Transactional rapidPicking)    │
┌──────────────────────────┐       ┌──────────────────────────────────┐   │
│ MobilePickingService     │       │ MobilePickingService             │   │
│ try-catch on callback    │       │ rapidPickingScanSource()         │   │
└──────────────────────────┘       └──────────────────────────────────┘   │
```

**All 5 fixes should be deployed together.** Fix 2 is a hard prerequisite for Fix 1.

---

## Files Changed

| File | Change | Priority |
|------|--------|----------|
| `service/HttpRestService.java` | Add `connectTimeout(5s)` and `readTimeout(15s)` to `ResteasyClientBuilder` | CRITICAL |
| `service/mobile/MobilePickingService.java` | Add `@Transactional` to `processPick()` (line 335) | CRITICAL |
| `service/PickingorderBusinessService.java` | Add `@Transactional` to `confirmPick()` (line 185) | CRITICAL |
| `service/mobile/MobilePickingService.java` | Wrap OMS callback in try-catch at lines 407-408 | HIGH |
| `service/mobile/MobilePickingService.java` | Add `@Transactional` to `rapidPickingScanSource()` (line 840) | MEDIUM |

---

## What This Does NOT Fix (Out of Scope)

1. **OMS-side performance** — The 4-minute `assignedToteID` callback blocking is an OMS issue. The timeout limits the damage but doesn't fix the OMS.
2. **Pessimistic locking on picking positions** — The RCA suggests `SELECT ... FOR UPDATE` on picking positions. This is overly aggressive for this use case and could cause deadlocks in the concurrent multi-picker workflow. The `@Transactional` fix ensures atomicity, which is sufficient.
3. **Optimistic locking retry logic in `confirmPick()`** — The RCA suggests adding retry logic. With `@Transactional` wrapping `processPick()`, a retry inside `confirmPick()` would be ineffective (the entire transaction must be retried from the controller). Retry logic would need to be at the controller level, which is a larger refactor. The `@Transactional` fix prevents the partial-commit damage, which is the actual bug.
4. **`rapidPickingConnectPackageAndType()` (line 729)** — This method also does tote assignment + OMS callback without `@Transactional`. It doesn't call `confirmPick()` so it won't trigger the same stuck-order bug, but it could leave orphaned tote assignments if a later step fails. This is lower risk and can be addressed separately.

---

## Testing Checklist

### Pre-Deployment
- [ ] Verify `ResteasyClientBuilder` accepts `connectTimeout` and `readTimeout` methods (RESTEasy 3.x API)
- [ ] Build succeeds with no compilation errors

### Post-Deployment
- [ ] **Fix 1+3 verification**: Simulate `confirmPick()` failure → verify tote assignment is rolled back (no orphaned `pickingorder_unitload`, no `pickingtote_id` on customer order)
- [ ] **Fix 2 verification**: Simulate slow OMS → verify callback times out after 15s (not blocking for minutes)
- [ ] **Fix 4 verification**: Simulate OMS callback exception → verify pick still completes successfully
- [ ] **Concurrent picking test**: Two pickers on same multi-customer picking order → both complete without stuck orders
- [ ] **Monitor**: No new stuck orders on Pick Pack Monitor dashboard for 48 hours
- [ ] **Monitor**: No `LockTimeoutException` or deadlock errors from concurrent picking

### Regression
- [ ] Single picker, single customer order → pick completes normally
- [ ] Multi-customer picking order → all customer orders progress through states correctly
- [ ] OMS callbacks (`assignedToteID`, `finishedPicking`, `pickingStarted`) all succeed under normal conditions
- [ ] Rapid picking flow still works correctly

---

## Relationship to Unit Load Popping Fix

This fix is on the same feature branch (`tmp/release-ul-popping-fix`) as the UL Popping fixes. Both share the same root cause: **missing `@Transactional` annotations throughout the WMS v1 codebase**.

The UL Popping fix already added `@Transactional` to:
- `UnitloadBusinessService.transferUnitLoadToLocation()` — called from `processPick()` line 398
- `StockunitBusinessService.transferStockToUnitLoad()` — called from `confirmPick()` line 235
- `StockunitBusinessService.changeReservedAmount()` — called from `confirmPick()` line 224

These inner `@Transactional` methods will **join** the outer transaction added by Fixes 1 and 3 (default `Propagation.REQUIRED`). This is correct and desired.
