# WMS V1 — Picking Glitch: Orders Getting Stuck with Totes Assigned (ShipItEZ)

**Date:** 2026-02-13
**Status:** In Progress
**Priority:** Critical
**Instance:** ShipItEZ (WMS v1, `origin/release` branch, `:uat` container image)
**Reported By:** CSR — almost daily occurrence, urgent ahead of mini peak next week

---

## Problem Statement

Orders are getting stuck during picking in the ShipItEZ WMS instance. The Pick Pack Monitor dashboard shows these orders as "glitched" — they appear as `order_assigned_to_parcel` (state 200 with a tote assigned) but never progress to picking state (500).

**Specific incident on 2026-02-13:**
- **Tote C1-0056** → Order `008093-000007` (picking order `PICK075386`)
- **Tote C1-0050** → Order `008093-000003` (picking order `PICK075385`)
- Both orders are from **batch 008093** (id: 119990753)

**Business Impact:**
- **Almost daily occurrence** — this is not a one-off
- Stuck orders require manual database intervention to unblock
- Mini peak with clubs and releases starting next week — high risk of increased frequency
- Warehouse loses confidence in picking process

---

## Root Cause Analysis

### The Core Bug: Missing `@Transactional` on `processPick()`

`MobilePickingService.processPick()` (line 331) has **NO `@Transactional` annotation**.

With `spring.jpa.open-in-view=false` (configured in application properties), there is no automatic transaction wrapping for web requests. Every `repository.save()` call **auto-commits immediately** as its own transaction.

This means the method performs **~8 separate auto-committing saves** that cannot be rolled back as a unit:

```
processPick() — NO @Transactional
│
├── Line 389: pickingorderUnitloadService.create()      ← AUTO-COMMITS (creates tote link)
├── Line 394: transferUnitLoadToLocation()               ← AUTO-COMMITS (moves tote)
├── Line 397: pickingorderUnitloadRepository.save()      ← AUTO-COMMITS (sets customer order #)
├── Line 401: customerorderRepository.save()             ← AUTO-COMMITS (sets pickingtote_id) ⚠️
├── Line 404: OMS callback (catches IOException)         ← Side effect, can't undo
├── Lines 406-411: Loop saving each position             ← AUTO-COMMITS each ⚠️
│
└── Line 425: confirmPick()                              ← FAILS HERE → no rollback possible
```

### The Trigger: Optimistic Locking Failure in `confirmPick()`

`PickingorderBusinessService.confirmPick()` (line 235) also has **NO `@Transactional`**.

When multiple pickers work on the **same picking order** simultaneously (which happens when a picking order contains positions from multiple customer orders), they contend on shared entities. The picking position save at line 302-310 throws `ObjectOptimisticLockingFailureException`:

```java
// Line 302-310 in confirmPick()
try {
    pickingPosition = pickingorderPositionRepository.save(pickingPosition);  // ← THROWS
} catch (ObjectOptimisticLockingFailureException e) {
    // Retry once — but can ALSO fail
    pickingPosition = pickingorderPositionRepository.findById(pickingPosition.getId()).get();
    pickingPosition.setAmountpicked(pickingPosition.getAmountpicked().add(amountPicked));
    pickingPosition = pickingorderPositionRepository.save(pickingPosition);  // ← THROWS AGAIN
}
```

### The Result: Partial Commit = Stuck Order

When `confirmPick()` fails, the exception propagates to `PickingController.processPick()` (line 281-287) which catches it and returns an error to the mobile device. **But the tote assignment from the first half of `processPick()` has already been auto-committed and cannot be rolled back.**

The order is now stuck:
- ✅ `pickingorder_unitload` created (tote linked to picking order)
- ✅ `customerorder.pickingtote_id` set (tote assigned)
- ✅ `customerorder.historytote` set
- ✅ OMS callback sent (tote assigned notification)
- ✅ All picking positions have `picktounitload_id` set
- ❌ Stock NOT transferred to tote (or transferred but position not updated)
- ❌ `customerorder.state` still 200 (never advanced to 500 STARTED)
- ❌ `pickingorder_unitload.state` still 0 RAW (never advanced to 500 STARTED)

### The Amplifier: OMS Callback Blocks Thread for 4+ Minutes

The OMS `assignedToteID` callback at line 404 is **synchronous with no HTTP timeout**. The logs show it blocked a Tomcat thread for **4 minutes 13 seconds**. During this time:

1. The tote assignment has already auto-committed (lines 389-401)
2. The thread is frozen waiting for the OMS HTTP response
3. The operator sees no response on the mobile device and retries
4. Each retry auto-commits a NEW tote assignment on a different thread
5. When the blocked thread finally resumes, its JPA entities are stale → optimistic locking failure

Even a single operator can trigger the bug — no concurrent pickers required. The 4-minute block gives the operator time to retry 3-4 times, each creating a new orphaned tote assignment.

### Why This Happens "Almost Daily"

Picking order `PICK075385` contains positions from **6 different customer orders** (003 through 008). When multiple warehouse workers pick from this order concurrently, they all modify entities belonging to the same picking order — triggering optimistic locking conflicts.

**More pickers → more conflicts → more stuck orders.** The OMS callback blocking amplifies this by freezing threads long enough for the operator to create multiple conflicting retries.

This pattern is inherent to how picking orders are structured: multi-customer picking orders are common, and concurrent picking is the normal workflow.

---

## Database Evidence

### Tote C1-0056 — Order 008093-000007

| Entity | State | Evidence |
|--------|-------|----------|
| Customer Order (119990787) | 200 (ASSIGNED) | `pickingtote_id = 4083721`, should be 500 |
| Picking Order PICK075386 (5016001) | 300 (PROCESSABLE) | Never started |
| All 4 Picking Positions | 300 (PROCESSABLE) | `amountpicked = 0`, all have `picktounitload_id = 119994675` |
| Picking Unit Load (119994675) | 0 (RAW) | `unitload_id = 4083721`, should be 500 |
| Stock on Tote C1-0056 | 1 unit of itemdata 4973702 | Stock WAS transferred (auto-committed) |
| OMS Callback (msg 119994683) | SENT, httpcode=200 | Callback succeeded |
| Operator | NULL | No operator assigned |

**Key insight:** Stock IS on the tote (1 unit), meaning `transferStockToUnitLoad()` executed and auto-committed. But the picking position state is still 300 with `amountpicked = 0`, meaning the position save in `confirmPick()` failed.

### Tote C1-0050 — Order 008093-000003

| Entity | State | Evidence |
|--------|-------|----------|
| Customer Order (119990765) | 200 (ASSIGNED) | `pickingtote_id = 5669370` |
| Picking Order PICK075385 (5015997) | 500 (STARTED) | Started by another picker |
| Position 119994125 | 600 (PICKED) | First pick succeeded (`amountpicked = 1.0`) |
| Other 3 positions | 300 (PROCESSABLE) | `amountpicked = 0` |
| Picking Unit Load — First tote C1-0007 (119994669) | 0 (RAW) | Created 08:38:02 |
| Picking Unit Load — Second tote C1-0050 (119994672) | 0 (RAW) | Created 08:40:15 |
| Stock on C1-0007 | 1 unit of itemdata 4973702 | First pick's stock |
| Stock on C1-0050 | ZERO | Second pick never transferred stock |
| Operator | 4845307 (caltemp6) | Operator was assigned |

**Key insight:** This order has TWO `pickingorder_unitload` records. The first pick succeeded (to C1-0007), then a subsequent pick failed. The operator appears to have tried a new tote (C1-0050) but the pick failed again before stock could transfer.

### Both Orders — Same Batch

Both are from batch **008093** (id: 119990753). Other orders in the batch (004, 005, 006) completed successfully with their totes in state 500 — confirming concurrent picking was happening.

---

## Log Analysis

**Source:** Container `jns90k84ewc0glk99cxo7z7gq` (ShipItEZ WH01, California warehouse), single replica running since 2026-02-03T13:00-04:00. Log file: 54.14 MB.

### Timeline of Incident — 2026-02-13 08:35–08:43

**Operator:** caltemp4

| Time | Event | Detail |
|------|-------|--------|
| 08:35:18–08:35:52 | ✅ Successful picks on PICK075385 (5015987) | Positions 119994121→C1-0033, 119994103→C1-0031, 119994113→C1-0033. Orders 001 & 002 fully picked. All OMS `finishedPicking` callbacks respond in <200ms. |
| 08:36:29 | Release & rescan | caltemp4 releases 5015987, scans TempA, sees 5 orders |
| 08:36:45 | Select PICK075385 (5015997) | 18 positions, 4 parcels |
| **08:38:02.500** | **⚠️ ATTEMPT 1: C1-0007 → pos 119994125 (order 003)** | Tote C1-0007 assigned from EmptyTotes→caltemp4. All tote-assignment saves auto-commit. |
| 08:38:02.541 | **OMS callback blocks** | POST to `assignedToteID` — **thread hangs for 4+ minutes** |
| 08:38:17 | Duplicate scan while blocked | caltemp4 sends `C1-0007C1-0007` (double-scan typo, different Tomcat thread) |
| 08:38:30 | Retry with C1-0007 | ERROR: "C1-0007 belongs to different order!" — tote already bound from auto-commit |
| 08:38:37 | Release + reset | caltemp4 releases with reset=true |
| 08:38:52 | Retry with C1-0007 | Same error: "C1-0007 belongs to different order!" |
| 08:39:00 | Release + reset again | |
| **08:40:15.667** | **⚠️ ATTEMPT 2: C1-0050 → pos 119994125 (order 003)** | Tote C1-0050 assigned from EmptyTotes→caltemp4. All saves auto-commit. |
| 08:40:15.692 | **OMS callback blocks** | POST to `assignedToteID` — **thread hangs for ~2 minutes** |
| 08:40:31 | Release + reset | caltemp4 gives up waiting (C1-0050 thread still blocked) |
| 08:41:02 | Retry with C1-0007 | ERROR: "C1-0007 not on empty totes location but caltemp4" — tote moved in attempt 1 |
| 08:41:16 | **Gives up on PICK075385** | Releases 5015997, selects **different** order PICK075386 (5016001), 15 positions |
| **08:42:12.763** | **⚠️ ATTEMPT 3: C1-0056 → pos 119994169 (order 007, PICK075386)** | Tote C1-0056 assigned from EmptyTotes→caltemp4. All saves auto-commit. |
| 08:42:12.803 | OMS callback starts | POST to `assignedToteID` |
| **08:42:15.431** | OMS responds (2.6s — normal) | Status 200, "All tote ids assigned" |
| **08:42:15.462** | **💥 Blocked Thread 1 RESUMES** | The C1-0007 thread from 08:38:02 finally continues after **4 min 13 sec**. Starts `confirmPick()` for pos 119994125. |
| **08:42:15.487** | **💥 TWO more blocked OMS callbacks return** | C1-0007 callback (blocked 4m13s) and C1-0050 callback (blocked 2m) both get status=200 |
| 08:42:15.497 | WARN: OptimisticLocking retry (0) | BasicService attempts retry on position save |
| **08:42:15.501** | **Stock transfer auto-commits** | 1 unit moved from stockunit 4980296 → unitload 39684764 (C1-0007). **PERMANENT.** |
| **08:42:15.510** | C1-0056 thread starts confirmPick | For position 119994169 on the new order |
| **08:42:15.516** | **❌ ERROR #1** | `ObjectOptimisticLockingFailureException` on `PickingorderPosition#119994125` at `MobilePickingService.processPick:413` |
| **08:42:15.516** | **❌ ERROR #2** | `ObjectOptimisticLockingFailureException` on `Customerorder#119990765` at `PickingorderBusinessService.confirmPick:284` |
| 08:42:15.523–08:42:15.540 | **Stock transfer auto-commits** | 1 unit moved from stockunit 4980296 → unitload 4083721 (C1-0056). **PERMANENT.** |
| **08:42:15.556** | **❌ ERROR #3** | `ObjectOptimisticLockingFailureException` on `PickingorderPosition#119994169` at merge in processPick |
| 08:42:49 | caltemp4 releases 5016001 | Gives up |
| 08:43:51 | Tries C1-0056 for different order | ERROR: "C1-0056 belongs to different order!" — tote stuck from glitched transaction |

### Stack Traces (Confirmed)

**Error #1** — `PickingorderPosition#119994125` at `MobilePickingService.processPick:413`:
```
org.hibernate.StaleObjectStateException: Row was updated or deleted by another transaction
  : [net.aim_ai.wms.model.PickingorderPosition#119994125]
  at ...AbstractEntityPersister.check(AbstractEntityPersister.java:2651)
  at ...JpaTransactionManager.doCommit(JpaTransactionManager.java:534)
  at com.sun.proxy.$Proxy262.save(Unknown Source)
  at net.aim_ai.wms.service.mobile.MobilePickingService.processPick(MobilePickingService.java:413)
  at net.aim_ai.wms.controller.mobile.PickingController.processPick(PickingController.java:281)
```

**Error #2** — `Customerorder#119990765` at `PickingorderBusinessService.confirmPick:284`:
```
org.hibernate.StaleObjectStateException: Row was updated or deleted by another transaction
  : [net.aim_ai.wms.model.Customerorder#119990765]
  at ...JpaTransactionManager.doCommit(JpaTransactionManager.java:534)
  at com.sun.proxy.$Proxy248.save(Unknown Source)
  at net.aim_ai.wms.service.PickingorderBusinessService.confirmPick(PickingorderBusinessService.java:284)
  at net.aim_ai.wms.service.mobile.MobilePickingService.processPick(MobilePickingService.java:429)
  at net.aim_ai.wms.controller.mobile.PickingController.processPick(PickingController.java:281)
```

**Error #3** — `PickingorderPosition#119994169` at merge:
```
org.hibernate.StaleObjectStateException: Row was updated or deleted by another transaction
  : [net.aim_ai.wms.model.PickingorderPosition#119994169]
  at ...DefaultMergeEventListener.entityIsDetached(DefaultMergeEventListener.java:341)
```

### Critical Discovery: OMS Callback Blocking (4+ Minutes)

The logs reveal an additional critical factor: the OMS `assignedToteID` HTTP callback is **synchronous and blocks the Tomcat thread** with no timeout, sometimes for **4+ minutes**:

| Callback | Start Time | Response Time | Duration |
|----------|------------|---------------|----------|
| C1-0007 `assignedToteID` | 08:38:02.541 | 08:42:15.487 | **4 min 13 sec** |
| C1-0050 `assignedToteID` | 08:40:15.692 | 08:42:15.487 | **1 min 60 sec** |
| C1-0056 `assignedToteID` | 08:42:12.803 | 08:42:15.431 | 2.6 sec (normal) |

The `finishedPicking` callbacks at 08:35:51–08:35:52 all completed in <200ms, showing the OMS is normally responsive. The 4-minute blocks on `assignedToteID` suggest either OMS load/contention or a network issue during that specific window.

**Impact of blocking:** The tote assignment auto-commits BEFORE the callback (lines 389-401), but the callback blocks the thread BEFORE `confirmPick()` runs (line 425). While the thread is frozen, the operator releases/resets the order and retries — creating new auto-committed tote assignments layered on top. When the blocked thread finally resumes, its JPA entities are hopelessly stale → `ObjectOptimisticLockingFailureException` → stock transfer auto-committed permanently → stuck order.

---

## Code Analysis — Failure Points

### File: `MobilePickingService.java` (lines 331–441)

```java
// LINE 331 — NO @Transactional
public Pickingorder processPick(Pickingorder pickingOrder, PickingorderPosition pickingPosition, String toteName)
    throws BusinessException, FacadeException {

    // ... validation ...

    if (pickingUnitLoad == null) {
        // BLOCK 1: Tote assignment — each save auto-commits
        pickingUnitLoad = pickingorderUnitloadService.create(pickingOrder, tote);     // Line 389
        // ... transfer tote to location ...                                          // Line 394
        pickingUnitLoad.setCustomerordernumber(customerOrder.getNumber());
        pickingUnitLoad = pickingorderUnitloadRepository.save(pickingUnitLoad);       // Line 397 ← COMMITTED

        customerOrder.setPickingtoteId(tote.getId());
        customerOrder.setHistorytote(tote.getLabelid());
        customerorderRepository.save(customerOrder);                                  // Line 401 ← COMMITTED

        if (basicService.isProduction())
            manageOrderService.customerOrderToteAssigned(...);                        // Line 404 ← OMS NOTIFIED

        for (...) {
            pickPos.setPicktounitloadId(pickingUnitLoad.getId());
            pickingorderPositionRepository.save(pickPos);                             // Lines 406-411 ← COMMITTED
        }
    }

    // BLOCK 2: Confirm the pick — THIS IS WHERE IT FAILS
    pickingOrder = pickingorderBusinessService.confirmPick(...);                       // Line 425 ← THROWS

    // ... never reached if confirmPick fails ...
}
```

### File: `PickingorderBusinessService.java` (lines 235–406)

```java
// LINE 235 — NO @Transactional
public Pickingorder confirmPick(PickingorderPosition pickingPosition, PickingorderUnitload pickingUnitLoad,
    BigDecimal amountPicked) throws FacadeException, BusinessException {

    // Line 289: Stock transfer — auto-commits
    stockunitBusinessService.transferStockToUnitLoad(stockUnit, tote, amountPicked, ...);

    // Lines 302-310: Position update — THROWS ObjectOptimisticLockingFailureException
    pickingPosition.setAmountpicked(pickingPosition.getAmountpicked().add(amountPicked));
    if (pickingPosition.getAmountpicked().compareTo(pickingPosition.getAmount()) >= 0) {
        pickingPosition.setState(WmsConstants.State.PICKED);
    }
    try {
        pickingPosition = pickingorderPositionRepository.save(pickingPosition);  // ← CAN THROW
    } catch (ObjectOptimisticLockingFailureException e) {
        // Retry once — but retry CAN ALSO FAIL
        pickingPosition = pickingorderPositionRepository.findById(pickingPosition.getId()).get();
        pickingPosition = pickingorderPositionRepository.save(pickingPosition);  // ← CAN THROW AGAIN
    }

    // Lines 351-356: State transitions — NEVER REACHED if above throws
    if (customerOrder.getState() < WmsConstants.State.STARTED) {
        customerOrder.setState(WmsConstants.State.STARTED);                     // ← NEVER EXECUTED
        customerorderRepository.save(customerOrder);
    }
    if (pickingOrder.getState() < WmsConstants.State.STARTED) {
        pickingOrder = startPickingOrder(pickingOrder);                          // ← NEVER EXECUTED
    }
    if (pickingUnitLoad.getState() < WmsConstants.State.STARTED) {
        pickingUnitLoad.setState(WmsConstants.State.STARTED);                   // ← NEVER EXECUTED
    }
}
```

### File: `PickingController.java` (lines 265–288)

```java
try {
    order = mobilePickingService.processPick(order, orderPosition, toteName);
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));     // ← Error returned to mobile
} catch (FacadeException e) {
    errors.add(getErrorMessage("Runtime Error", e.getLocalizedMessage()));
}
// Exception caught, error returned to user, but tote assignment is PERMANENT
```

---

## Recommended Fixes

### Fix 1: Add `@Transactional` to `processPick()` (CRITICAL — Highest Priority)

**File:** `MobilePickingService.java`, line 331

```java
// BEFORE:
public Pickingorder processPick(Pickingorder pickingOrder, ...) throws BusinessException, FacadeException {

// AFTER:
@Transactional("tenantTransactionManager")
public Pickingorder processPick(Pickingorder pickingOrder, ...) throws BusinessException, FacadeException {
```

This wraps the entire tote assignment + confirmPick in a single transaction. If `confirmPick()` fails, the tote assignment is rolled back automatically.

**⚠️ Note:** Must use `tenantTransactionManager` (not the default `landlordTransactionManager`) since this operates on tenant data.

### Fix 2: Add `@Transactional` to `confirmPick()` (CRITICAL)

**File:** `PickingorderBusinessService.java`, line 235

```java
// BEFORE:
public Pickingorder confirmPick(PickingorderPosition pickingPosition, ...) throws FacadeException, BusinessException {

// AFTER:
@Transactional("tenantTransactionManager")
public Pickingorder confirmPick(PickingorderPosition pickingPosition, ...) throws FacadeException, BusinessException {
```

This ensures stock transfer + position update + state transitions are atomic.

### Fix 3: Improve Optimistic Locking Retry in `confirmPick()` (HIGH)

The current retry logic (lines 311-321) retries once and doesn't re-read all related entities. Should be improved to:

```java
int retries = 0;
final int maxRetries = 3;
while (retries < maxRetries) {
    try {
        pickingPosition = pickingorderPositionRepository.save(pickingPosition);
        break;
    } catch (ObjectOptimisticLockingFailureException e) {
        retries++;
        if (retries >= maxRetries) throw e;
        LOG.warn("Optimistic locking failure on position {}, retry {}/{}",
            pickingPosition.getId(), retries, maxRetries);
        pickingPosition = pickingorderPositionRepository.findById(pickingPosition.getId()).get();
        pickingPosition.setAmountpicked(pickingPosition.getAmountpicked().add(amountPicked));
        if (pickingPosition.getAmountpicked().compareTo(pickingPosition.getAmount()) >= 0) {
            pickingPosition.setState(WmsConstants.State.PICKED);
        }
    }
}
```

### Fix 4: Consider Pessimistic Locking for Picking Positions (MEDIUM)

For picking positions where multiple pickers can contend, use `SELECT ... FOR UPDATE`:

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT pp FROM PickingorderPosition pp WHERE pp.id = :id")
Optional<PickingorderPosition> findByIdForUpdate(@Param("id") Long id);
```

### Fix 5: Make OMS Callback Failure Non-Fatal (MEDIUM)

In `processPick()` line 404, the OMS callback `customerOrderToteAssigned()` currently catches `IOException` but could throw other exceptions. Wrap more defensively:

```java
try {
    if (basicService.isProduction())
        manageOrderService.customerOrderToteAssigned(Collections.singletonList(customerOrder));
} catch (Exception e) {
    LOG.error("OMS tote assigned callback failed for order {}, continuing", customerOrder.getNumber(), e);
}
```

### Fix 6: Add HTTP Timeout to OMS Callbacks (CRITICAL — Quick Win)

The `assignedToteID` OMS callback blocked a Tomcat thread for **4 minutes 13 seconds** with no timeout. This is the primary amplifier of the race condition — it freezes the thread long enough for the operator to retry multiple times, each retry layering auto-committed tote assignments.

**File:** `ManageOrderService.java` (HTTP client configuration)

Add connection and read timeouts to the HTTP client used for OMS callbacks:

```java
// Example using RestTemplate (adapt to actual HTTP client in use)
SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
factory.setConnectTimeout(5000);  // 5 second connection timeout
factory.setReadTimeout(15000);    // 15 second read timeout
RestTemplate restTemplate = new RestTemplate(factory);
```

**Why this is CRITICAL:** Even with `@Transactional` (Fix 1), a 4-minute blocking callback will hold a database transaction open for 4 minutes, which causes its own problems (long-held locks, connection pool exhaustion). The timeout must be added regardless of whether Fix 1 is applied.

---

## Immediate Workaround — Unblock Stuck Orders

### Option A: Reset orders back to releasable state (RECOMMENDED)

Run against the **ShipItEZ PostgreSQL database**:

```sql
-- Step 1: Remove the orphaned pickingorder_unitload records for stuck orders
DELETE FROM pickingorder_unitload WHERE id IN (119994675, 119994672);
-- 119994675 = C1-0056 (order 007), 119994672 = C1-0050 (order 003, second tote)

-- Step 2: Clear tote assignment from customer orders
UPDATE customerorder
SET pickingtote_id = NULL, historytote = NULL
WHERE id IN (119990787, 119990765);
-- 119990787 = order 007, 119990765 = order 003

-- Step 3: Reset picking positions to remove picktounitload assignment
UPDATE pickingorder_position
SET picktounitload_id = NULL
WHERE picktounitload_id IN (119994675);
-- Only for order 007's positions (order 003's positions point to 119994669 which is the first tote)

-- Step 4: Handle stock on tote C1-0056 (has 1 unit of itemdata 4973702)
-- This stock needs to be returned to the pick-from location
-- MANUAL VERIFICATION REQUIRED: Check what the pick-from location should be
-- before moving stock back

-- Step 5: Handle C1-0007 (order 003's first tote, has 1 unit)
-- Position 119994125 is already in state 600 (PICKED) — this pick was valid
-- The pickingorder_unitload 119994669 for C1-0007 should be kept
-- But it needs to be verified manually
```

**⚠️ WARNING:** The stock on totes C1-0056 and C1-0007 needs to be physically verified in the warehouse and returned to the correct pick-from location if the picks are being reset.

### Option B: Advance orders to picking state (ALTERNATIVE)

Only use this if the physical picks were actually completed correctly:

```sql
-- Advance customer orders to STARTED
UPDATE customerorder SET state = 500 WHERE id IN (119990787, 119990765);

-- Advance picking unit loads to STARTED
UPDATE pickingorder_unitload SET state = 500 WHERE id IN (119994675, 119994672);

-- Set operator on picking order PICK075386 (currently NULL)
UPDATE pickingorder SET state = 500, operator_id = 4845307 WHERE id = 5016001;
```

---

## Files Changed

| File | Change | Priority |
|------|--------|----------|
| `v1/wms-api/.../service/mobile/MobilePickingService.java` | Add `@Transactional("tenantTransactionManager")` to `processPick()` | CRITICAL |
| `v1/wms-api/.../service/PickingorderBusinessService.java` | Add `@Transactional("tenantTransactionManager")` to `confirmPick()` | CRITICAL |
| `v1/wms-api/.../service/ManageOrderService.java` | Add HTTP timeout (connect=5s, read=15s) to OMS callbacks | CRITICAL |
| `v1/wms-api/.../service/PickingorderBusinessService.java` | Improve optimistic locking retry logic | HIGH |
| `v1/wms-api/.../service/mobile/MobilePickingService.java` | Wrap OMS callback more defensively | MEDIUM |

---

## Deployment Steps

1. Apply code fixes to `origin/release` branch (or feature branch merged to release)
2. Build new `:uat` container image
3. Deploy to ShipItEZ instance
4. Verify with concurrent picking test (see testing checklist)
5. Monitor Pick Pack Monitor dashboard for stuck orders over 24-48 hours

---

## Testing Checklist

- [ ] Unit test: `processPick()` with `confirmPick()` failure → verify tote assignment is rolled back
- [ ] Unit test: `confirmPick()` with optimistic locking failure → verify retry succeeds
- [ ] Integration test: Two concurrent pickers on same picking order → both complete without stuck orders
- [ ] Manual test: Create multi-customer picking order, have 2+ pickers work it simultaneously
- [ ] Monitor: No new stuck orders on dashboard for 48 hours post-deployment
- [ ] Verify: `@Transactional` uses `tenantTransactionManager` (not landlord)

---

## Relationship to Unit Load Popping Issue

This picking glitch shares the same fundamental root cause as the [Unit Load "Popping" issue](WMS_V1_UnitLoad_Popping_Root_Cause_Analysis.md):

**Missing `@Transactional` annotations throughout the WMS v1 codebase.**

Both issues stem from `spring.jpa.open-in-view=false` combined with no explicit transaction boundaries, causing auto-commit behavior where partial operations persist even when subsequent operations fail.

The fixes should be deployed together to address both issues simultaneously.

---

## Additional Notes

- **Log source:** Container `jns90k84ewc0glk99cxo7z7gq` (ShipItEZ WH01, California warehouse). Single replica running since 2026-02-03T13:00-04:00. All three `ObjectOptimisticLockingFailureException` stack traces were captured and confirmed.
- The `BasicService.getNextSequenceNumber()` optimistic locking warnings in logs are **benign** — they handle contention on sequence counters and retry properly (up to 100 times).
- The OMS callbacks for tote assignment succeeded (httpcode=200) — the OMS is not the failure point. However, the `assignedToteID` callbacks **blocked threads for up to 4+ minutes**, which is the primary amplifier of the race condition.
- The `ManageOrderService.customerOrderToteAssigned()` catches `IOException` but does NOT rethrow, so OMS callback failures would not cause this issue directly. The problem is the **blocking duration**, not the callback result.
- Consider auditing ALL service methods in the picking flow for missing `@Transactional` annotations as a broader code quality initiative.
- The `finishedPicking` OMS callbacks completed in <200ms during the same window, suggesting the `assignedToteID` endpoint specifically may have a server-side bottleneck (e.g., database lock contention in the OMS) that should be investigated separately.
