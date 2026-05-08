# Order Cancellation Up To QA - Root Cause and Fix Plan

**Date:** 2026-03-25  
**Branch:** `tmp/np05-cancel-club-to-packed--state`  
**Reported OMS symptoms:**
- Single cancel shows: `The order was NOT cancelled successfully!`
- Multi-select cancel shows: `Not all orders were cancelled successfully!`

## Executive Summary

My earlier plan was **directionally right but too narrow**.

What is still correct:
- the regression was introduced by the packed-order guard in `CustomerorderService.cancelOrder(...)`
- commit `1334bf1` only added a **partial** packed-cancel path
- the fix should be in the **service layer**, not by blindly passing `true` from the REST controller
- batch finalization must run after forced packed cancellation

What needed correction after re-checking the broader requirement:
- the real business rule is **"cancel until QA, block after QA/shipping"**
- `PACKED` is **not a universal cutoff** in this codebase
- `PACKED` means different things in different flows:
  - **club flow:** `PACKED` can still be **pre-QA / cancelable**
  - **regular pick-pack flow:** `PACKED` is reached by `/finishedQA`, so it is already **post-QA / not cancelable**

So the safe fix is **not** "allow `PACKED` everywhere". The safe fix is:
- preserve existing pre-QA cancellation for orders below `PACKED`
- allow forced cancellation for **pre-QA packed club orders only**
- explicitly block cancellation once the parcel/order is **shipped / finished**

## Verified Runtime Flow

### OMS entry point
- OMS single and multi-cancel both end up at:
  - `OrderRestController.cancelPositions()`
  - which calls `customerorderService.cancelOrder(customerOrder, false)`

### Current standard WMS cancellation behavior
For orders **below `PACKED`**, the current logic already has two modes:

1. **Immediate cancellation**
   - if all positions can be cancelled safely now
2. **Deferred cancellation**
   - if picking is active, `cancelOrder()` sets `markedforcancellation = true`
   - later `PickingorderBusinessService` sees that flag and calls `cleanUpCancelledOrder(customerOrder)`

This means the existing code already supports the business idea of:
- "allow cancel during picking"
- "if it cannot be removed immediately, mark it and clean it up at the safe point"

### QA boundary differs by workflow

#### Regular pick-pack orders
- `PickingorderBusinessService` moves fully picked orders to `PICKED`
- `/rest/order/finishedQA` accepts orders in `PICKED`
- `finishedQA()` then calls `customerorderService.packageOrder(customerOrder)`
- `packageOrder()` changes the order to `PACKED`

Therefore for regular orders:
- **awaiting QA** is effectively `PICKED`
- **after QA** is `PACKED`

#### Club orders
- `CustomerorderBatchService.runClubLine()` sets club orders and positions to `PACKED`
- that happens before the later shipping boundary

Therefore for club orders:
- `PACKED` can still be **pre-QA / pre-shipping**
- that is exactly why OMS cancel regressed for club orders

### Shipping / too-late boundary
- `BillofladingService.closeBOL()` bulk-updates customer orders to `FINISHED`
- it also moves unitloads to `STORAGE_LOCATION_SHIPPED`
- and sets parcel / stockunit locks to `BusinessObjectLockState.SHIPPED`

That is the reliable "too late to cancel" boundary.

## Root Cause

The regression is caused by combining **workflow-specific state meanings** with a **single universal guard**:

1. `CustomerorderService.cancelOrder()` rejects all `state >= PACKED` unless `cancellationFromWithinWMS == true`
2. OMS always calls `cancelOrder(order, false)`
3. club orders legitimately become `PACKED` before the true cancellation cutoff
4. OMS therefore gets `400 BAD_REQUEST` for pre-QA club orders

There is also a design flaw underneath it:
- the boolean `cancellationFromWithinWMS` mixes caller origin, permission, cleanup mode, and callback behavior

## What Changed in Code and Why It Broke

### Relevant regression change
Commit `1334bf1` added a partial packed-cancel path:
- `cancelOrder()` may delegate to `forceCancelOrder()`
- but only when `cancellationFromWithinWMS == true`

### Why that was not enough
- OMS callers do **not** pass `true`
- the branch still rejects OMS cancellation for pre-QA packed club orders
- the packed fast path returns before consistent batch-finalization handling
- the WMS-originated callback block still references the wrong sysprop URL key for cancellation messaging

## Revalidated Conclusions About My Previous Plan

### Still valid
- **Do not** fix this by simply changing `OrderRestController.cancelPositions()` to call `cancelOrder(order, true)`
- keep the fix in `CustomerorderService`
- call `customerorderBatchService.finalizeBatchIfComplete(...)` after packed forced cancellation
- later refactor the boolean into an explicit cancellation policy

### Needs correction
My earlier suggestion to broadly relax packed cancellation in `CustomerorderPositionService` was **too broad**.

Why:
- `CustomerorderPositionService.cancelOrderPosition()` is only used by the normal `< PACKED` path
- globally allowing `PACKED` there would also allow **post-QA regular orders**
- that would violate the business rule "cancel until QA, block after QA"

So the packed allowance must be **workflow-aware**, not a blanket `PACKED` rule.

## Recommended Fix Strategy

### Phase 1 - minimal safe hotfix

Implement the hotfix in `CustomerorderService`.

#### 1. Add explicit helpers for cancellation boundary checks
Add helpers with intent like:
- `isAlreadyCancelled(Customerorder order)`
- `isShippedOrPastCancellationBoundary(Customerorder order)`
- `isOmsPreQaPackedCancellationAllowed(Customerorder order)`

Suggested rules:

`isShippedOrPastCancellationBoundary(order)` should return true when any of these are true:
- `order.getState() >= WmsConstants.State.FINISHED`
- the parcel unitload exists and has `entityLock == SHIPPED`
- parcel stock units show shipped lock state

`isOmsPreQaPackedCancellationAllowed(order)` should return true only when:
- order state is `PACKED` or `PALLETIZED`
- order batch type is `CLUB`
- order is **not** shipped / finished

#### 2. Change `cancelOrder()` guard logic
Replace the current top-level packed guard with logic equivalent to:

- if already `CANCELED` -> return success / no-op
- if shipped / finished -> throw business exception
- if state is `PACKED` or `PALLETIZED` and (`cancellationFromWithinWMS` or `isOmsPreQaPackedCancellationAllowed(order)`) -> run `forceCancelOrder(order)`
- otherwise, for states below packed, keep the current immediate-or-deferred cancellation flow

This preserves existing behavior for:
- Released
- Picking
- Awaiting QA regular orders (`PICKED`)

And fixes the broken club path for:
- pre-QA club parcels already marked `PACKED`

#### 3. Always finalize batch state after forced packed cancellation
After `forceCancelOrder(order)`:
- save the order
- call `customerorderBatchService.finalizeBatchIfComplete(order.getOrderbatchId())`

This is required so that:
- fully cancelled batch -> batch becomes `CANCELED`
- partially cancelled batch -> cancelled order is excluded while batch remains valid

#### 4. Do not change controller boolean semantics in Phase 1
Keep:
- `OrderRestController.cancelPositions()` calling `cancelOrder(order, false)`

Reason:
- `true` currently means more than "OMS packed cancel allowed"
- it also touches WMS-originated callback logic
- reusing it from OMS would hide the semantic bug instead of fixing it

### Why this hotfix matches the requirement

It honors all stated scenarios:
- **Released / picking:** existing immediate-or-marked-for-cancellation flow remains active
- **Awaiting QA regular orders:** still cancelable while `PICKED`
- **Awaiting QA club orders:** newly allowed even though they are already `PACKED`
- **After QA / shipped:** still blocked
- **Any parcel already shipped:** blocked via shipped/finished checks

## Better Structural Improvement

The current boolean API is the main long-term risk.

### Recommended refactor
Replace `cancelOrder(Customerorder order, boolean cancellationFromWithinWMS)` with an explicit policy object or enum, for example:
- `STANDARD_OMS`
- `OMS_PRE_QA_PACKED_CLUB`
- `WMS_FORCE`

Or, more simply:
- `cancelOrderFromOms(...)`
- `cancelPackedPreQaClubOrderFromOms(...)`
- `forceCancelOrderFromWms(...)`

The important goal is to separate:
- caller origin
- permission to cross normal state guards
- cleanup strategy
- outbound callback behavior

## Secondary Hardening Improvements

### 1. Make cancel idempotent for already-cancelled orders
If OMS retries an already cancelled order:
- do not return an error
- treat it as success / no-op

This should ideally be handled in `cancelOrder()` so all callers benefit.

### 2. Improve multi-order behavior in `cancelPositions()`
Current controller behavior fails fast on the first bad order.

Safer follow-up behavior:
- process each requested order independently
- allow already-cancelled orders as success
- aggregate genuine failures
- only return `400` if at least one order is truly non-cancellable

### 3. Audit outbound cancellation callback wiring
If the WMS-originated callback path is still needed, move it out of the generic cancellation method and use:
- `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY`

not:
- `SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY`

### 4. Align position-level APIs only if needed
`CustomerorderPositionService.cancelOrderPosition()` currently belongs to the normal `< PACKED` path.

So Phase 1 should **not** globally allow packed positions there.

If future requirements need direct packed position cancellation, then:
- add a shared policy helper
- use the same workflow-aware pre-QA checks there too
- never allow regular post-QA packed positions by default

## Files to Change

### Phase 1
- `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
- `src/test/java/net/aim_ai/wms/unit/service/CustomerorderServiceUnitTest.java`

### Follow-up hardening
- `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java`
- `src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java` *(only if position-level packed cancellation is truly required)*
- `src/test/java/net/aim_ai/wms/unit/service/CustomerorderPositionServiceUnitTest.java`
- controller test covering `/cancelPositions`

## Test Plan

### Service unit tests to add / adjust
- `cancelOrder_packedClubOrder_fromOms_forceCancelsAndFinalizesBatch`
- `cancelOrder_palletizedClubOrder_fromOms_forceCancelsAndFinalizesBatch`
- `cancelOrder_packedRegularOrder_fromOms_throwsBusinessException`
- `cancelOrder_finishedOrShippedOrder_fromOms_throwsBusinessException`
- `cancelOrder_alreadyCanceled_fromOms_isNoOp`
- `cancelOrder_regularPickedAwaitingQa_stillUsesNormalCancellationPath`

### Controller tests to add later
- `cancelPositions_packedClubOrder_returnsSuccess`
- `cancelPositions_alreadyCancelledOrder_returnsSuccess`
- `cancelPositions_finishedOrShippedOrder_returnsBadRequest`
- `cancelPositions_mixedOrders_aggregatesFailures` *(follow-up hardening)*

### Suggested validation commands
- `mvn test -Dtest=CustomerorderServiceUnitTest`
- optionally controller coverage once added

## Acceptance Criteria

- OMS single cancel succeeds for a pre-QA packed club order.
- OMS multi-select cancel succeeds when selected orders are either newly cancelled or already cancelled.
- Orders in active picking remain cancelable via immediate or deferred cleanup.
- Regular orders awaiting QA remain cancelable before `/finishedQA` completes them.
- Once QA/shipping has progressed to the true terminal boundary, cancellation is blocked.
- If any parcel is already shipped, cancellation is blocked.
- When the last active order in a batch is cancelled, the batch becomes `CANCELED` and lane cleanup still occurs through normal batch finalization.

## Final Recommendation

### Is the previous hotfix still valid?
**Partially yes.**

The service-level hotfix is still the right approach, but it must be narrowed to:
- **workflow-aware pre-QA packed cancellation**
- **not** blanket `PACKED` cancellation

### Best implementation order
1. Fix `CustomerorderService.cancelOrder()` boundary logic
2. Add shipped/finished protection
3. Ensure `finalizeBatchIfComplete()` runs after forced packed cancellation
4. Add targeted service tests
5. Then decide whether controller aggregation/idempotency hardening is needed in the same PR or a follow-up

## Implementation Status

**Status: Phase 1 COMPLETE** (2026-03-27)

### What was implemented

All Phase 1 items are done:

1. **Helper methods added** to `CustomerorderService.java`:
   - `isAlreadyCancelled(Customerorder)` — checks `state == CANCELED`
   - `isPackedOrPalletized(Customerorder)` — checks `state == PACKED || PALLETIZED`
   - `isShippedOrPastCancellationBoundary(Customerorder)` — checks `state >= FINISHED` (excluding CANCELED), parcel entityLock == SHIPPED, or stock unit entityLock == SHIPPED
   - `isOmsPreQaPackedCancellationAllowed(Customerorder)` — checks packed/palletized + batch type == CLUB

2. **`cancelOrder()` guard logic updated** with the correct priority:
   - Already cancelled → no-op return
   - Shipped/finished → throw BusinessException
   - Packed/palletized + (WMS or pre-QA club) → `forceCancelOrder()` + `finalizeBatchIfComplete()`
   - Packed/palletized otherwise → throw BusinessException
   - Below packed → existing immediate-or-deferred flow

3. **Batch finalization** runs after forced packed cancellation (line 537)

4. **Immutable list fix** — 4 call sites wrapping `Collections.singletonList()` in `new ArrayList<>()`:
   - `ReleaseOrderJobService.java:551`
   - `PickingorderBusinessService.java:156, 165, 327`

### Tests (48 passing, 0 failures)

All plan-specified tests implemented in `CustomerorderServiceUnitTest.java`:
- `cancelOrder_packedClubOrder_fromOms_forceCancelsAndFinalizesBatch`
- `cancelOrder_palletizedClubOrder_fromOms_forceCancelsAndFinalizesBatch`
- `cancelOrder_packedRegularOrder_fromOms_throwsBusinessException`
- `cancelOrder_finishedOrder_fromOms_throwsBusinessException`
- `cancelOrder_shippedParcel_fromOms_throwsBusinessException`
- `cancelOrder_alreadyCanceled_fromOms_isNoOp`
- `cancelOrder_pickedRegularAwaitingQa_usesNormalCancellationPath`

### Secondary Hardening (COMPLETE, 2026-03-27)

1. **Multi-order aggregation in `cancelPositions()`** — DONE
   - Changed `OrderRestController.cancelPositions()` to process each order independently
   - Errors are collected per-order in a `Map<String, String>` instead of failing fast
   - If any orders fail: returns 400 with `{"status": "partial_failure", "errors": {...}}`
   - If all orders succeed: returns 204 as before
   - Already-cancelled orders succeed (no-op in service layer)

2. **Outbound cancellation callback URL fix** — DONE
   - Fixed `CustomerorderService.java:644`: changed `SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY` to `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY`
   - This was a copy-paste bug — WMS-originated cancellation callbacks were hitting the stock count URL instead of the cancellation URL

3. **Position-level API alignment** — SKIPPED (not needed per plan)

### Controller Tests Added (5 passing)
- `cancelPositions_successfulCancellation_returnsNoContent`
- `cancelPositions_alreadyCancelledOrder_returnsSuccess`
- `cancelPositions_finishedOrder_returnsBadRequest`
- `cancelPositions_mixedOrders_aggregatesFailures`
- `cancelPositions_packedClubOrder_returnsSuccess`

### Remaining (future refactor, not blocking)
- Refactor boolean `cancellationFromWithinWMS` into explicit policy enum