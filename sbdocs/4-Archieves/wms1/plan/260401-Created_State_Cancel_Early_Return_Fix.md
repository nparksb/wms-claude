---
title: "Created-State Order Cancellation: Early Return + Deferred Section Lookup"
ticket: ""
ticket_url: ""
type: plan
version: v1
status: archived
priority: high
project: [wms1]
scope: cancellation
created: 2026-04-01
updated: 2026-04-22
related:
  - Cancel_Order_Null_SectionId_Fix
tags:
  - moc
  - plan
  - bug
  - cancellation
  - archived
---

# Created-State Order Cancellation: Early Return + Deferred Section Lookup

**Status: IMPLEMENTED (2026-04-01)** — archived 2026-04-22.
All fixes applied, tests passing (67/67). Implemented together with `260424-Cancel_Order_Null_SectionId_Fix.md`.

## Relationship to Other Plans

This plan addresses issues from `docs/plan/input/v1_wms_api_created_state_cancel_fix.md` and **supplements** `docs/plan/260424-Cancel_Order_Null_SectionId_Fix.md`. The null-sectionId plan covers making the section lookup null-safe. This plan adds two further improvements:

1. **Early return** in `canOrderPositionBeCancelled()` when no picking positions exist (avoids section lookup entirely for created-state orders)
2. **Deferred section lookup** in `cancelOrder()` — move the lookup inside the rapid-picking conditional so it only runs when needed

Both plans should be implemented together for complete coverage of the cancellation crash.

## Problem Statement

Orders in `CREATED` (RAW) state typically have no picking positions yet. The current code in `canOrderPositionBeCancelled()` unconditionally resolves `Customerorder -> Client -> Section` before checking whether picking positions exist. This is:
- **Wasteful**: section lookup is unnecessary when there are no picking positions
- **Crash-prone**: if `client.sectionId` is null, `findById(null)` throws `IllegalArgumentException`

Similarly, `cancelOrder()` unconditionally resolves the section at line 560, even when the rapid-picking branch guard (`ASSIGNED` + `historytote != null`) would skip it.

## Validation Against Current Code

### Claim 1: "Early return when no picking positions"
**NOT APPLIED.** Current `CustomerorderPositionService.java` lines 49-53:
```java
// Line 49-50: section is resolved FIRST
Customerorder customerOrder = customerorderRepository.findById(customerOrderPosition.getOrderId()).get();
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();
// Line 53: picking positions checked AFTER
List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(customerOrderPosition.getId());
```
The plan claims the order was reversed (check picking positions first, return early if empty). This was never done.

### Claim 2: "Null-safe `getSectionForOrder()` helper in both services"
**NOT APPLIED.** Grep for `getSectionForOrder` in `src/` returns zero matches. The helper method was never added.

### Claim 3: "Section lookup deferred inside rapid-picking branch in `cancelOrder()`"
**NOT APPLIED.** Line 560 still has the unconditional lookup:
```java
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();
```
This runs regardless of whether the rapid-picking branch applies.

### Claim 4: "Regression tests added"
**PARTIALLY TRUE.** The test files exist:
- `CustomerorderPositionServiceUnitTest.java` — exists, has good coverage of picking states, but **no test for null sectionId** and **no test for created-state early return** (all tests mock valid client + section)
- `CustomerorderServiceUnitTest.java` — exists, has cancel tests, but **no test for null sectionId** and **no test for deferred section lookup**

### Claim 5: Status "Ready to Deploy"
**FALSE.** None of the three claimed code fixes were applied.

## Proposed Fix

### Fix 1: Early return in `canOrderPositionBeCancelled()` (CustomerorderPositionService.java)

Reorder the logic so picking positions are checked first. If none exist, return `true` immediately without touching client/section.

```java
// CURRENT ORDER (lines 43-55):
//   1. Check state >= PACKED → return false
//   2. Load customerOrder
//   3. Load section (UNSAFE)
//   4. Load picking positions
//   5. Branch on rapid vs regular

// PROPOSED ORDER:
//   1. Check state >= PACKED → return false
//   2. Load picking positions
//   3. If empty → return true (EARLY EXIT — no section needed)
//   4. Load customerOrder
//   5. Load section (null-safe, from Cancel_Order_Null_SectionId_Fix plan)
//   6. Branch on rapid vs regular
```

Concrete change — replace lines 49-54:
```java
// BEFORE:
Customerorder customerOrder = customerorderRepository.findById(customerOrderPosition.getOrderId()).get();
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();
LOG.debug("canOrderPositionBeCancelled: customer order id=" + customerOrder.getId()  + ", section name=" + section.getName());

List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(customerOrderPosition.getId());
LOG.debug("canOrderPositionBeCancelled: picking order positions from customer order size=" + poPositions.size());

// AFTER:
List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(customerOrderPosition.getId());
LOG.debug("canOrderPositionBeCancelled: picking order positions from customer order position size=" + poPositions.size());
if (poPositions.isEmpty()) {
    return true;
}

Customerorder customerOrder = customerorderRepository.findById(customerOrderPosition.getOrderId()).get();
Section section = getSectionForOrder(customerOrder);  // null-safe helper from Cancel_Order_Null_SectionId_Fix
LOG.debug("canOrderPositionBeCancelled: customer order id=" + customerOrder.getId() + ", section name=" + (section != null ? section.getName() : "null"));
```

### Fix 2: Deferred section lookup in `cancelOrder()` (CustomerorderService.java)

Move the section lookup inside the rapid-picking guard so it only runs when actually needed.

```java
// BEFORE (line 560-562):
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();

if (section != null && section.getSectionpickingtype().equals(WmsConstants.SectionPickingType.RAPID_PICKING) && customerOrder.getState() == WmsConstants.State.ASSIGNED && customerOrder.getHistorytote() != null) {

// AFTER:
if (customerOrder.getState() == WmsConstants.State.ASSIGNED && customerOrder.getHistorytote() != null) {
    Section section = getSectionForOrder(customerOrder);  // null-safe helper
    if (section != null && section.getSectionpickingtype().equals(WmsConstants.SectionPickingType.RAPID_PICKING)) {
        // existing rapid-picking cleanup logic (lines 563-587 unchanged)
    }
}
```

This is a logic-preserving restructure: the rapid-picking block already requires `ASSIGNED` + `historytote != null`, so checking those first (cheap field reads) avoids the database lookup when they're not met.

### Fix 3: Add `getSectionForOrder()` helper to both services

As defined in `260424-Cancel_Order_Null_SectionId_Fix.md` — the same helper covers both plans.

## Test Gaps to Fill

The existing test files need additional tests:

### `CustomerorderPositionServiceUnitTest.java`

| Test | Purpose |
|------|---------|
| `canOrderPositionBeCancelled_noPickingPositions_returnsTrue` | Verifies early return without section lookup. Assert `sectionRepository` and `clientRepository` are never called. |
| `canOrderPositionBeCancelled_nullSectionId_regularPath` | Client exists but `sectionId` is null. Should not crash; falls to regular picking path. |

### `CustomerorderServiceUnitTest.java`

| Test | Purpose |
|------|---------|
| `cancelOrder_createdState_noPickingPositions_cancelsWithoutSectionLookup` | RAW order with no picking positions. Verify `sectionRepository` never called. |
| `cancelOrder_nullSectionId_cancellable_cancelsNormally` | Cancellable order where `client.sectionId` is null. Should cancel via regular path without crash. |
| `cancelOrder_nonAssignedState_skipsSectionLookup` | Order in PROCESSABLE state (not ASSIGNED). Verify section lookup is skipped entirely. |

## Behavior Preservation

- Created-state orders (no picking positions): return `true` immediately — same result as before, minus the crash risk
- Rapid picking path: still triggers only when section is RAPID_PICKING + ASSIGNED + historytote present
- Regular picking path: unchanged — all existing guards remain
- No JPA associations, no REST contract changes, no state rule changes

## Implementation Summary

All fixes applied in order:
1. Added `getSectionForOrder()` null-safe helper to both services
2. Reordered `canOrderPositionBeCancelled()` to check picking positions first with early return
3. Deferred section lookup in `cancelOrder()` inside the `ASSIGNED + historytote` guard
4. Updated 5 existing tests to remove now-unnecessary client/section stubs
5. Added 4 new tests covering null sectionId and deferred lookup scenarios
6. All 67 tests passing: `mvn test -Dtest=CustomerorderPositionServiceUnitTest,CustomerorderServiceUnitTest`
