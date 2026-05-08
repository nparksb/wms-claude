# Cancel Order Null SectionId Fix

**Status: IMPLEMENTED (2026-04-01)**
All fixes applied, tests passing (67/67). Implemented together with `260401-Created_State_Cancel_Early_Return_Fix.md`.

## Issue

`/rest/order/cancelPositions` and related cancellation paths crash with `IllegalArgumentException: The given id must not be null!` when `client.sectionId` is `null`.

Root cause: chained `sectionRepository.findById(client.getSectionId())` calls without null-checking `getSectionId()`. Spring Data rejects `findById(null)`.

## Validated Affected Locations (3 sites)

### 1. `CustomerorderPositionService.canOrderPositionBeCancelled()` — line 50

```java
// CURRENT (unsafe):
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();
```

Three chained failure points:
- `customerOrder.getClientId()` could be null
- `client.getSectionId()` could be null (primary issue)
- Final `.get()` on Optional if section doesn't exist

### 2. `CustomerorderService.cancelOrder()` — line 560

```java
// CURRENT (unsafe):
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();
```

Same triple-chained unsafe pattern.

### 3. `CustomerorderService.packageOrder()` — line 464

```java
// CURRENT (unsafe):
Client client = clientRepository.findById(customerOrder.getClientId()).get();
Section section = sectionRepository.findById(client.getSectionId()).get();
```

Same issue — `client.getSectionId()` can be null. Not in the cancellation path directly, but same class, same bug pattern, and can be hit during order packaging.

## Proposed Fix

### For sites 1 and 2 (cancellation path): null-safe section resolution

Replace the unsafe chained lookup with a null-safe resolution. When section is null (because client or sectionId is missing), treat the order as regular (non-rapid) picking — fall into the `else` branch.

**In `CustomerorderPositionService`:**

Add a private helper:
```java
private Section getSectionForOrder(Customerorder customerOrder) {
    if (customerOrder == null || customerOrder.getClientId() == null) {
        return null;
    }
    Client client = clientRepository.findById(customerOrder.getClientId()).orElse(null);
    if (client == null || client.getSectionId() == null) {
        return null;
    }
    return sectionRepository.findById(client.getSectionId()).orElse(null);
}
```

Replace line 50:
```java
// BEFORE:
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();

// AFTER:
Section section = getSectionForOrder(customerOrder);
```

No other logic changes needed — the existing `if (section != null && ...)` guard on line 55 already handles a null section correctly by falling through to the regular picking `else` branch.

**In `CustomerorderService.cancelOrder()`:**

Add the same private helper to `CustomerorderService`:
```java
private Section getSectionForOrder(Customerorder customerOrder) {
    if (customerOrder == null || customerOrder.getClientId() == null) {
        return null;
    }
    Client client = clientRepository.findById(customerOrder.getClientId()).orElse(null);
    if (client == null || client.getSectionId() == null) {
        return null;
    }
    return sectionRepository.findById(client.getSectionId()).orElse(null);
}
```

Replace line 560:
```java
// BEFORE:
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).get().getSectionId()).get();

// AFTER:
Section section = getSectionForOrder(customerOrder);
```

Again, the existing guard `if (section != null && section.getSectionpickingtype().equals(...))` on line 562 already handles null correctly.

### For site 3 (`packageOrder()`): null-safe with business exception

`packageOrder()` at line 464 is different — it uses the section's picking type in a `switch` statement (line 466) to decide where to move the tote. A null section here means we can't determine the picking type, so it should throw a clear business exception rather than an `IllegalArgumentException`.

Replace lines 463-464:
```java
// BEFORE:
Client client = clientRepository.findById(customerOrder.getClientId()).get();
Section section = sectionRepository.findById(client.getSectionId()).get();

// AFTER:
Client client = clientRepository.findById(customerOrder.getClientId()).orElse(null);
if (client == null || client.getSectionId() == null) {
    throw new BusinessException("Cannot package order — client or section not configured for order=" + customerOrder.getNumber());
}
Section section = sectionRepository.findById(client.getSectionId())
    .orElseThrow(() -> new BusinessException("Section not found for client=" + client.getClNr()));
```

## Behavior Preservation

- **Rapid picking path**: Still triggered when section exists and is `RAPID_PICKING`, order is `ASSIGNED`, and `historytote` is non-null
- **Regular picking path**: Used when section is null OR section is not `RAPID_PICKING` — this is the existing fallthrough behavior, now also covers the null-sectionId case
- **packageOrder**: Throws a clear business exception instead of cryptic `IllegalArgumentException`
- No JPA associations added
- No REST contract changes
- No state rule changes
- No new dependencies

## Out of Scope (same pattern, different paths)

These locations have the same unsafe `findById(client.getSectionId()).get()` but are not in the cancellation/packaging paths:

| File | Line | Method |
|------|------|--------|
| `OrderMonitorViewService.java` | 101, 108 | `getOrderMonitor*()` |
| `ClientService.java` | 132 | client management |
| `ReleaseOrderJobService.java` | 456 | order release job |

Consider fixing these in a separate follow-up to limit blast radius.

## Test Plan

1. **`CustomerorderPositionService.canOrderPositionBeCancelled()`**
   - Client exists with null sectionId -> returns true (regular picking path, no crash)
   - Client exists with valid section (RAPID_PICKING) -> existing rapid picking logic works
   - Client exists with valid section (non-rapid) -> regular picking path

2. **`CustomerorderService.cancelOrder()`**
   - Client with null sectionId -> cancellation proceeds via regular path (no crash)
   - Client with RAPID_PICKING section + ASSIGNED state + historytote -> rapid cleanup runs
   - Regression: full cancel flow with valid section still works

3. **`CustomerorderService.packageOrder()`**
   - Client with null sectionId -> throws BusinessException with clear message
   - Valid section -> existing switch logic works as before

## Validation

```bash
mvn test -Dtest=CustomerorderServiceTest
mvn test -Dtest=CustomerorderPositionServiceTest
```

## Implementation Summary

- Added `getSectionForOrder()` null-safe helper to both `CustomerorderPositionService` and `CustomerorderService`
- Fixed 3 unsafe section lookup sites: `CustomerorderPositionService:50`, `CustomerorderService:560` (cancelOrder), `CustomerorderService:464` (packageOrder)
- Updated existing tests to remove unnecessary stubs after logic reordering
- Added new tests: `canOrderPositionBeCancelled_noPickingPositions_returnsTrueWithoutSectionLookup`, `canOrderPositionBeCancelled_nullSectionId_usesRegularPickingPath`, `cancelOrder_nullSectionId_cancellable_cancelsNormally`, `cancelOrder_nonAssignedState_skipsSectionLookup`
- All 67 tests passing (17 CustomerorderPositionServiceUnitTest + 50 CustomerorderServiceUnitTest)
