# Fix: OMS Status Race Condition (Status 24 Overwrites Status 25)

## Problem Summary

When the last pick of an order is confirmed via `processPick()`, two OMS notifications are sent in the wrong order:

1. **Status 25** (`finishedPicking` / `WAITING_FOR_QA`) is sent **synchronously inside the transaction**
2. **Status 24** (`picking` / `PICKING`) is sent **after the transaction commits** via `afterCommit` callback

OMS receives status 25 first, then status 24 arrives and **overwrites it**, leaving the order stuck at "PICKING" instead of "WAITING_FOR_QA".

## Root Cause Analysis

### Transaction Flow in `MobilePickingService.processPick()` (line 338)

```
processPick() [@Transactional - TX STARTS]
  |
  |-- (1) Tote assignment
  |       registers afterCommit -> customerOrderToteAssigned()     [deferred]
  |
  |-- (2) confirmPick() [@Transactional JOINS existing TX]
  |       |-- sets customerOrder.state = STARTED
  |       |-- registers afterCommit -> customerOrderPickingStarted()  [deferred - STATUS 24]
  |       |-- detects all picks done -> pickingOrder.state = PICKED
  |
  |-- (3) finishPickingOrder() [NO @Transactional - runs in same TX]
  |       |-- manageOrderService.customerOrderPicked()  [SYNCHRONOUS - STATUS 25]
  |       |   ^^ HTTP POST to OMS happens HERE, inside the open TX
  |       |-- customerOrder.pickingconfirmationsent = true
  |       |-- transfers totes to FinishedPicking location
  |       |-- pickingOrder.state = FINISHED
  |
  TX COMMITS
  |
  |-- (4) afterCommit callbacks fire:
  |       |-- customerOrderToteAssigned() -> OMS call (tote label)
  |       |-- customerOrderPickingStarted() -> OMS call (STATUS 24)  <<<< OVERWRITES 25!
```

### Key Code Locations

| File | Lines | What |
|------|-------|------|
| `MobilePickingService.java` | 338-460 | `processPick()` - transaction owner |
| `MobilePickingService.java` | 416-428 | `afterCommit` for tote assigned |
| `PickingorderBusinessService.java` | 286-301 | `afterCommit` for picking started (status 24) |
| `PickingorderBusinessService.java` | 100-177 | `finishPickingOrder()` - synchronous OMS call |
| `PickingorderBusinessService.java` | 138-142 | Synchronous `customerOrderPicked()` call (status 25) |
| `PickingorderBusinessService.java` | 344-349 | "all picks done" check that sets PICKED state |
| `ManageOrderService.java` | 231-272 | `customerOrderPickingStarted()` - sends to `/picking` |
| `ManageOrderService.java` | 274-331 | `customerOrderPicked()` - sends to `/finishedPicking` |

### OMS Status Mapping (defined in OMS PHP, not WMS)

| OMS Status | Value | OMS Endpoint | WMS Method |
|------------|-------|-------------|------------|
| `READY_TO_PICK` | 23 | `/readytopick` | `customerOrderReleaseForPicking()` |
| `PICKING` | 24 | `/picking` | `customerOrderPickingStarted()` |
| `WAITING_FOR_QA` | 25 | `/finishedPicking` | `customerOrderPicked()` |

## Affected Scenarios

### Single-SKU Orders: ALWAYS AFFECTED

For a single-SKU order, the first pick is also the last pick. Within one `processPick()` call:

1. `confirmPick()` sees `customerOrder.state < STARTED` -> registers `afterCommit` for status 24
2. `confirmPick()` detects all picks done -> sets `pickingOrder.state = PICKED`
3. `finishPickingOrder()` sends status 25 synchronously
4. TX commits -> `afterCommit` sends status 24 -> **overwrites status 25**

**This is the primary bug path.**

### Multi-SKU Orders: NOT AFFECTED (normal flow)

For multi-SKU orders, the flow naturally separates:

- **First pick**: `confirmPick()` registers `afterCommit` for status 24, but `finishPickingOrder()` is NOT called (more picks remain). After TX commits, status 24 is sent correctly.
- **Last pick**: `finishPickingOrder()` sends status 25 synchronously, but NO `afterCommit` is registered because `customerOrder.state` is already `>= STARTED`. Status 25 is sent correctly.

### Multi-SKU Edge Case: POTENTIALLY AFFECTED

Could occur if the customer order state is still `< STARTED` when the last pick happens. This is theoretically possible if:
- Multiple picking orders serve the same customer order
- The first picking order's transaction hasn't committed yet when the second picking order completes
- Or the customer order was manually reset to a pre-STARTED state

This edge case is unlikely but not impossible in concurrent picking scenarios.

### Rapid Picking (`rapidPickingScanSource`): SAME ISSUE

The rapid picking flow at `MobilePickingService.java:865` follows the identical pattern:
- Line 953: calls `confirmPick()` (which may register the `afterCommit`)
- Line 967: calls `finishPickingOrder()` (synchronous OMS call)
- Same race condition applies for single-SKU orders.

## Fix Options

### Option A: Skip `afterCommit` When Order Will Be Finished

**Approach**: In `confirmPick()`, after detecting all picks are done, skip the `afterCommit` registration for "picking started" since `finishPickingOrder()` will be called immediately after and will send the higher-priority status 25.

**Changes**: `PickingorderBusinessService.java` only

```java
// Current code (lines 286-301):
if (customerOrder.getState() < WmsConstants.State.STARTED) {
    customerOrder.setState(WmsConstants.State.STARTED);
    customerOrder = customerorderRepository.save(customerOrder);
    if (basicService.isProduction()) {
        final Customerorder pickingStartedOrder = customerOrder;
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronizationAdapter() {
            @Override
            public void afterCommit() {
                try {
                    manageOrderService.customerOrderPickingStarted(Collections.singletonList(pickingStartedOrder));
                } catch (Exception e) {
                    LOG.error("OMS picking started callback failed ...", e);
                }
            }
        });
    }
}
```

**Fix**: Move the `afterCommit` registration AFTER the "all picks done" check (line 344-349), and only register it if the order is NOT fully picked:

```java
// Step 1: Still set customer order to STARTED (line 286-288 unchanged)
boolean customerOrderJustStarted = false;
if (customerOrder.getState() < WmsConstants.State.STARTED) {
    customerOrder.setState(WmsConstants.State.STARTED);
    customerOrder = customerorderRepository.save(customerOrder);
    customerOrderJustStarted = true;
}

// ... existing code for customer order position state check (lines 304-332) ...
// ... existing code for picking order start + unitload start (lines 335-342) ...

// Step 2: Check if all picks are done (lines 344-349 unchanged)
List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
boolean allPicksDone = poPositions.stream().noneMatch(pickPos -> pickPos.getState() < WmsConstants.State.PICKED);
if (allPicksDone && pickingOrder.getState() < WmsConstants.State.PICKED) {
    pickingOrder.setState(WmsConstants.State.PICKED);
    pickingOrder = pickingorderRepository.save(pickingOrder);
}

// Step 3: Only send "picking started" if order is NOT fully picked
// (if fully picked, finishPickingOrder() will send the higher-priority "finished" status)
if (customerOrderJustStarted && !allPicksDone && basicService.isProduction()) {
    final Customerorder pickingStartedOrder = customerOrder;
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronizationAdapter() {
        @Override
        public void afterCommit() {
            try {
                manageOrderService.customerOrderPickingStarted(Collections.singletonList(pickingStartedOrder));
            } catch (Exception e) {
                LOG.error("OMS picking started callback failed for order " + pickingStartedOrder.getNumber(), e);
            }
        }
    });
}

return pickingOrder;
```

**Pros**:
- Surgical fix - only changes `PickingorderBusinessService.confirmPick()`
- No change to transaction boundaries or the `finishPickingOrder()` flow
- For single-SKU orders: status 24 is simply not sent (unnecessary since 25 follows immediately)
- For multi-SKU orders: behavior is unchanged (first pick sends 24, last pick sends 25)
- No risk to other business logic (batch processing, cancellation, admin actions)

**Cons**:
- Single-SKU orders skip status 24 entirely (goes from 23 -> 25). This is acceptable because:
  - The order was in status 24 for zero meaningful time (same HTTP request)
  - OMS already handles status progression (23 -> 25 is valid)
  - The current bug produces the worse outcome (stuck at 24)

---

### Option B: Move `finishPickingOrder` OMS Call to `afterCommit` (RECOMMENDED)

**Approach**: Make the status 25 call also deferred via `afterCommit`, ensuring it runs after status 24's `afterCommit`. Spring's `TransactionSynchronizationManager` fires callbacks in registration order, so status 24 (registered in `confirmPick()`) fires first, then status 25 (registered in `finishPickingOrder()`) fires second. This preserves the correct 23 -> 24 -> 25 status progression.

**Changes**: `PickingorderBusinessService.finishPickingOrder()` (lines 138-142)

```java
// Current code (lines 136-145):
} else if (customerOrder.getState() != WmsConstants.State.CANCELED) {

    if (basicService.isProduction()) {
        LOG.info("WMS is in production mode");
        manageOrderService.customerOrderPicked(Collections.singletonList(customerOrder));
        customerOrder.setPickingconfirmationsent(true);
        customerorderRepository.save(customerOrder);
    } else {
        LOG.warn("WMS is is NOT in production mode");
    }
```

**Fix**: Replace the synchronous OMS call with an `afterCommit` callback, with a guard for callers that may not have an active transaction synchronization context:

```java
} else if (customerOrder.getState() != WmsConstants.State.CANCELED) {

    if (basicService.isProduction()) {
        LOG.info("WMS is in production mode");

        // Set flag optimistically inside the TX.
        // Note: the current code already sets this flag even when the OMS call
        // fails (IOException is caught and swallowed inside ManageOrderService),
        // so setting it before the deferred call is equivalent behavior.
        customerOrder.setPickingconfirmationsent(true);
        customerorderRepository.save(customerOrder);

        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            // Defer the OMS call until after TX commits, ensuring it fires
            // AFTER any previously registered afterCommit callbacks (e.g., status 24).
            final Customerorder pickedOrder = customerOrder;
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronizationAdapter() {
                @Override
                public void afterCommit() {
                    try {
                        manageOrderService.customerOrderPicked(Collections.singletonList(pickedOrder));
                    } catch (Exception e) {
                        LOG.error("OMS picked callback failed for order " + pickedOrder.getNumber(), e);
                    }
                }
            });
        } else {
            // No active TX synchronization (e.g., called from admin controller
            // or non-transactional context). Fall back to synchronous call.
            manageOrderService.customerOrderPicked(Collections.singletonList(customerOrder));
        }
    } else {
        LOG.warn("WMS is is NOT in production mode");
    }
```

#### Why `pickingconfirmationsent` Can Be Set Optimistically

The current code sets the flag AFTER the synchronous OMS call:

```java
manageOrderService.customerOrderPicked(Collections.singletonList(customerOrder));
customerOrder.setPickingconfirmationsent(true);  // set after call
```

However, `ManageOrderService.customerOrderPicked()` (lines 317-327) catches `IOException` internally and logs a `FAILED` message without re-throwing. This means the flag is **always set to `true`** regardless of whether OMS actually received the call. The flag effectively means "we attempted to send", not "OMS confirmed receipt". Setting it optimistically before the `afterCommit` is therefore equivalent to the current behavior.

#### Why the `isSynchronizationActive()` Guard Is Needed

`finishPickingOrder()` is called from 8 different locations:

| Caller | Has Active TX Sync? | Notes |
|--------|---------------------|-------|
| `MobilePickingService.processPick()` | Yes | `@Transactional` on method |
| `MobilePickingService.rapidPickingScanSource()` | Yes | `@Transactional` on method |
| `MobilePickingService.processPickingOrderForStart()` | Yes | `@Transactional` on method |
| `MobilePickingService.startPickingOrder()` | Yes | `@Transactional` on method |
| `MobilePickingService.releasePickingOrder()` | Yes | `@Transactional` on method |
| `CustomerorderService` (cancellation) | Yes | `@Transactional` on class |
| `CustomerorderBatchService` | Yes | `@Transactional` on method |
| `AdminActionController.finishStuckPickingOrder()` | **Maybe not** | No `@Transactional` visible |

The guard ensures that non-transactional callers (like the admin endpoint) still work correctly by falling back to the existing synchronous behavior.

**Pros**:
- Preserves the full 23 -> 24 -> 25 status progression for single-SKU orders
- Both `afterCommit` callbacks fire in registration order (24 first, then 25) - guaranteed by Spring
- Removes the synchronous HTTP call (up to 15s timeout) from inside the DB transaction, reducing TX duration
- `pickingconfirmationsent` flag behavior is equivalent to current code (see analysis above)
- Safe for all 8 call sites via the `isSynchronizationActive()` guard

**Cons**:
- Touches `finishPickingOrder()` which has 8 callers (vs Option A's single-method change)
- Slightly more complex with the synchronization guard
- If the `afterCommit` OMS call fails, the error is logged but there is no in-TX retry (same as the existing `afterCommit` pattern for status 24, and same as current behavior where IOException is swallowed)

---

### Option C: OMS-Side Guard (Don't Downgrade Status)

**Approach**: Modify OMS PHP to reject status transitions from higher to lower values.

**Changes**: OMS `RestapiController.php` - `updateParcelStatusFromWMS()` method

```php
// Add guard: don't allow status downgrade
if ($currentStatus >= $newStatus) {
    // Log and skip - WMS sent an outdated status
    return;
}
```

**Pros**:
- Defensive programming on the receiver side
- Fixes the symptom regardless of WMS call ordering

**Cons**:
- Requires OMS deployment (legacy PHP system)
- Doesn't fix the root cause in WMS
- May mask other ordering issues
- OMS status values aren't strictly linear (e.g., HELD = 26 should be settable from any state)

## Recommendation

**Implement Option B** as the primary fix. It is:

1. **Correct status progression**: Preserves the full 23 -> 24 -> 25 flow for single-SKU orders (no skipped statuses)
2. **Consistent pattern**: Both OMS status calls (`pickingStarted` and `customerOrderPicked`) now use the same `afterCommit` deferral pattern
3. **Reduced TX duration**: Removes a synchronous HTTP call (up to 15s timeout) from inside the database transaction
4. **Safe for all callers**: The `isSynchronizationActive()` guard ensures non-transactional callers fall back to synchronous behavior
5. **Equivalent flag behavior**: `pickingconfirmationsent` is already effectively set regardless of OMS call success/failure

**Option A** remains a valid alternative if a more surgical, single-method change is preferred (at the cost of skipping status 24 for single-SKU orders).

**Optionally implement Option C** as a defensive measure on OMS side, to protect against any future ordering issues.

## Implementation Steps

1. **Modify `PickingorderBusinessService.finishPickingOrder()`** (lines 138-142):
   - Move `pickingconfirmationsent = true` and `save()` before the OMS call
   - Wrap the `customerOrderPicked()` call in an `afterCommit` callback
   - Add `TransactionSynchronizationManager.isSynchronizationActive()` guard with synchronous fallback

2. **Test scenarios**:
   - Single-SKU order: verify status progression is 23 -> 24 -> 25 (both sent after TX commit, in order)
   - Multi-SKU order (first pick): verify status 24 is sent after commit (unchanged)
   - Multi-SKU order (last pick): verify status 25 is sent after commit, after any pending 24
   - Order cancellation: verify no change in behavior (`cleanUpCancelledOrder` path is unaffected)
   - Rapid picking single-SKU: verify same fix applies (`finishPickingOrder` is shared)
   - Admin `finishStuckPickingOrder`: verify synchronous fallback works (no active TX sync)
   - `CustomerorderBatchService` batch path: verify deferred call works correctly

3. **Verify no regression**:
   - Run existing picking integration tests
   - Check `Message` table in test environment to verify correct OMS calls and ordering
   - Test with `app.production=true` in a staging environment
   - Verify `pickingconfirmationsent` flag is set correctly in all scenarios

## Files to Modify

| File | Change |
|------|--------|
| `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | Wrap `customerOrderPicked()` in `afterCommit` with sync fallback in `finishPickingOrder()` |

## Files NOT Modified (no changes needed)

| File | Why |
|------|-----|
| `MobilePickingService.java` | Transaction boundary unchanged, calls finishPickingOrder as before |
| `ManageOrderService.java` | OMS communication layer unchanged |
| `PickingorderBusinessService.confirmPick()` | `afterCommit` for status 24 unchanged |
| `HttpRestService.java` | HTTP client unchanged |

## Sequence Diagrams

### Current (Broken) - Single-SKU Order

```
Mobile UI    MobilePickingService    PickingorderBizSvc    ManageOrderSvc    OMS
   |               |                       |                    |              |
   |--processPick->|                       |                    |              |
   |               |---confirmPick()------>|                    |              |
   |               |                       |--save STARTED----->|              |
   |               |                       |--register afterCommit(status 24)  |
   |               |                       |--all picks done--->|              |
   |               |                       |--state=PICKED----->|              |
   |               |                       |<---return----------|              |
   |               |                       |                    |              |
   |               |--finishPickingOrder-->|                    |              |
   |               |                       |--customerOrderPicked()----------->|
   |               |                       |                    |  POST /finishedPicking (status 25)
   |               |                       |                    |<--200 OK-----|
   |               |                       |--state=FINISHED--->|              |
   |               |                       |                    |              |
   |               |===TX COMMITS===================================          |
   |               |                       |                    |              |
   |               |  afterCommit fires:   |                    |              |
   |               |                       |--customerOrderPickingStarted()--->|
   |               |                       |                    |  POST /picking (status 24)
   |               |                       |                    |  *** OVERWRITES 25! ***
   |               |                       |                    |<--200 OK-----|
```

### Fixed (Option B) - Single-SKU Order

```
Mobile UI    MobilePickingService    PickingorderBizSvc    ManageOrderSvc    OMS
   |               |                       |                    |              |
   |--processPick->|                       |                    |              |
   |               |---confirmPick()------>|                    |              |
   |               |                       |--save STARTED----->|              |
   |               |                       |--register afterCommit(status 24)  |
   |               |                       |--all picks done--->|              |
   |               |                       |--state=PICKED----->|              |
   |               |                       |<---return----------|              |
   |               |                       |                    |              |
   |               |--finishPickingOrder-->|                    |              |
   |               |                       |--pickingconfirmationsent=true     |
   |               |                       |--register afterCommit(status 25)  |
   |               |                       |--state=FINISHED--->|              |
   |               |                       |                    |              |
   |               |===TX COMMITS===================================          |
   |               |                       |                    |              |
   |               |  afterCommit fires (in registration order):              |
   |               |                       |                    |              |
   |               |  (1) customerOrderPickingStarted()---------------------->|
   |               |                       |                    |  POST /picking (status 24)
   |               |                       |                    |<--200 OK-----|
   |               |                       |                    |              |
   |               |  (2) customerOrderPicked()-------------------------------->|
   |               |                       |                    |  POST /finishedPicking (status 25)
   |               |                       |                    |<--200 OK-----|
   |               |                       |                    |              |
   |               |  Correct order: 24 then 25!               |              |
```

### Fixed (Option B) - Multi-SKU Order (unchanged behavior)

```
=== FIRST PICK ===
Mobile UI    MobilePickingService    PickingorderBizSvc    ManageOrderSvc    OMS
   |               |                       |                    |              |
   |--processPick->|                       |                    |              |
   |               |---confirmPick()------>|                    |              |
   |               |                       |--save STARTED----->|              |
   |               |                       |--NOT all picks done|              |
   |               |                       |--register afterCommit(status 24)  |
   |               |                       |<---return----------|              |
   |               |                       |                    |              |
   |               |  (state != PICKED, skip finishPickingOrder)|              |
   |               |===TX COMMITS===================================          |
   |               |                       |                    |              |
   |               |  afterCommit fires:   |                    |              |
   |               |                       |--customerOrderPickingStarted()--->|
   |               |                       |                    |  POST /picking (status 24) OK
   |               |                       |                    |              |

=== LAST PICK ===
   |--processPick->|                       |                    |              |
   |               |---confirmPick()------>|                    |              |
   |               |                       |--order already STARTED            |
   |               |                       |--NO afterCommit for status 24     |
   |               |                       |--all picks done--->|              |
   |               |                       |--state=PICKED----->|              |
   |               |                       |<---return----------|              |
   |               |                       |                    |              |
   |               |--finishPickingOrder-->|                    |              |
   |               |                       |--pickingconfirmationsent=true     |
   |               |                       |--register afterCommit(status 25)  |
   |               |                       |--state=FINISHED--->|              |
   |               |===TX COMMITS===================================          |
   |               |                       |                    |              |
   |               |  afterCommit fires:   |                    |              |
   |               |                       |--customerOrderPicked()----------->|
   |               |                       |                    |  POST /finishedPicking (status 25) OK
```
