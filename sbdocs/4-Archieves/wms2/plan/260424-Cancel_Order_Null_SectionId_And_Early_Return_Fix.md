# Cancel Order: Null SectionId Fix + Early Return + Deferred Section Lookup (v2 Migration)

**Date:** 2026-04-01
**Priority:** High
**Source:** Two v1 plans implemented on `release-260327` branch of `wms-api`:
- `docs/plan/v1-fixes/260424-Cancel_Order_Null_SectionId_Fix.md`
- `docs/plan/v1-fixes/260401-Created_State_Cancel_Early_Return_Fix.md`
**Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## 1. Problem Summary

Order cancellation and related flows crash with `NoSuchElementException` or `IllegalArgumentException` when `client.getSectionId()` is `null`. The unsafe pattern `sectionRepository.findById(client.getSectionId()).get()` passes `null` to `findById()` (which Spring Data rejects) or calls `.get()` on an empty Optional.

Additionally, `canOrderPositionBeCancelled()` performs a wasteful and crash-prone section lookup even when no picking positions exist (common for `CREATED`/RAW state orders).

## 2. Applicability Analysis

| v1 Fix | v2 Status | Applicable? |
|:-------|:----------|:------------|
| **`cancelOrder()` null-safe section lookup + deferred inside rapid-picking guard** | **Already fixed in v2.** Lines 613-620 use null-safe `orElse(null)` with `client.getSectionId() != null` guard | **NO — already done** |
| **`canOrderPositionBeCancelled()` null-safe section lookup** | **NOT applied.** Line 60 uses unsafe chained `.get()` | **YES — needed** |
| **`canOrderPositionBeCancelled()` early return when no picking positions** | **NOT applied.** Section lookup happens before picking positions check | **YES — needed** |
| **`packageOrder()` null-safe section/client lookup** | **NOT applied.** Line 512 uses `.orElseThrow()` without null-checking `client.getSectionId()` | **YES — needed** |

### v2-specific observations

1. **`cancelOrder()` is already fixed** — v2 already has the deferred, null-safe pattern at lines 613-620. No changes needed.
2. **`canOrderPositionBeCancelled()` line 60** uses `orElseThrow()` for client (safe for missing client) but `.get()` for section (unsafe if `getSectionId()` is null or section doesn't exist).
3. **`packageOrder()` line 512** uses `orElseThrow()` for both lookups, which is better than `.get()`, but still passes potentially-null `client.getSectionId()` to `findById()`.
4. **`ReleaseOrderJobService` line 485-486** has the same unsafe pattern: `.flatMap(client -> sectionRepository.findById(client.getSectionId())).get()`. This was NOT in the v1 plan scope but is the same bug. Including it here for completeness.

---

## 3. Implementation Plan

### Fix #1 (HIGH): `canOrderPositionBeCancelled()` — Early return + null-safe section

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java`

#### Step 1: Add `getSectionForOrder()` helper

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

#### Step 2: Reorder logic — check picking positions first, early return if empty

**Replace lines 59-64:**

```java
// BEFORE (lines 59-64):
Customerorder customerOrder = customerorderRepository.findById(customerOrderPosition.getOrderId()).orElseThrow(() -> new EntityNotFoundException("CustomerOrder", customerOrderPosition.getOrderId()));
Section section = sectionRepository.findById(clientRepository.findById(customerOrder.getClientId()).orElseThrow(() -> new EntityNotFoundException("Client", customerOrder.getClientId())).getSectionId()).get();
LOG.debug("canOrderPositionBeCancelled: customer order id={}, section name={}", customerOrder.getId(), section.getName());

List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(customerOrderPosition.getId());
LOG.debug("canOrderPositionBeCancelled: picking order positions from customer order size={}", poPositions.size());

// AFTER:
List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(customerOrderPosition.getId());
LOG.debug("canOrderPositionBeCancelled: picking order positions from customer order position size={}", poPositions.size());
if (poPositions.isEmpty()) {
    return true;
}

Customerorder customerOrder = customerorderRepository.findById(customerOrderPosition.getOrderId()).orElseThrow(() -> new EntityNotFoundException("CustomerOrder", customerOrderPosition.getOrderId()));
Section section = getSectionForOrder(customerOrder);
LOG.debug("canOrderPositionBeCancelled: customer order id={}, section name={}", customerOrder.getId(), section != null ? section.getName() : "null");
```

**Why early return is safe:** If no picking positions exist, no picking is in progress — the order position can always be cancelled. The rapid-picking vs regular-picking distinction only matters when there ARE active picking positions. This avoids the section lookup entirely for `CREATED`/RAW orders that haven't been released yet.

**Why null-safe section is needed:** Even after early return, there are orders that HAVE picking positions but whose client has no section configured. The `getSectionForOrder()` helper returns `null`, and the existing guard `if (section != null && ...)` at line 65 correctly falls through to the regular picking `else` branch.

---

### Fix #2 (HIGH): `packageOrder()` — null-safe section lookup with clear BusinessException

**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`

**Replace lines 511-512:**

```java
// BEFORE (lines 511-512):
Client client = clientRepository.findById(customerOrder.getClientId()).orElseThrow(() -> new EntityNotFoundException("Client", customerOrder.getClientId()));
Section section = sectionRepository.findById(client.getSectionId()).orElseThrow(() -> new EntityNotFoundException("Section", client.getSectionId()));

// AFTER:
Client client = clientRepository.findById(customerOrder.getClientId()).orElseThrow(() -> new EntityNotFoundException("Client", customerOrder.getClientId()));
if (client.getSectionId() == null) {
    throw new BusinessException("Cannot package order — client section not configured for order=" + customerOrder.getNumber());
}
Section section = sectionRepository.findById(client.getSectionId())
    .orElseThrow(() -> new BusinessException("Section not found for client=" + client.getClNr()));
```

**Why BusinessException instead of EntityNotFoundException:** `packageOrder()` uses the section in a `switch` statement to decide tote destination. A null section means the business configuration is wrong — this is a business error, not a missing entity. A `BusinessException` gives the user a clear message instead of a cryptic NPE or `IllegalArgumentException`.

**Note:** The exception type changes from `EntityNotFoundException` to `BusinessException` for the section-not-found case. The `section.getSectionId() == null` case is new — previously it would throw `IllegalArgumentException: The given id must not be null!` from Spring Data.

---

### Fix #3 (MEDIUM): `ReleaseOrderJobService` — null-safe section lookup

**File:** `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java`

**Replace lines 485-486:**

```java
// BEFORE (lines 485-486):
Section section = clientRepository.findById(order.getClientId())
    .flatMap(client -> sectionRepository.findById(client.getSectionId())).get();

// AFTER:
Section section = clientRepository.findById(order.getClientId())
    .filter(client -> client.getSectionId() != null)
    .flatMap(client -> sectionRepository.findById(client.getSectionId()))
    .orElseThrow(() -> new BusinessException("Section not configured for order=" + order.getNumber()));
```

**Why `orElseThrow` instead of `orElse(null)`:** In `releaseOrder()`, the section is used to set `pickingOrder.setSectionId(section.getId())` on line 489. A null section would cause NPE immediately after. This is a hard requirement for order release — if no section is configured, the order cannot be released and should fail with a clear message.

**Alternative (softer):** If orders without sections should be skippable rather than failing:
```java
Section section = clientRepository.findById(order.getClientId())
    .filter(client -> client.getSectionId() != null)
    .flatMap(client -> sectionRepository.findById(client.getSectionId()))
    .orElse(null);
if (section == null) {
    LOG.warn("No section configured for order={}, skipping release", order.getClientordernumber());
    return itemDataAvailableAmountUpdateMap;
}
```

**Recommendation:** Use the `orElseThrow` version. If a client has no section, the order shouldn't have been created. Failing fast with a clear message is better than silently skipping.

---

## 4. Test Plan

### 4.1 `CustomerorderPositionServiceUnitTest` — new tests

**File:** `src/test/java/net/aim_ai/wms/unit/service/CustomerorderPositionServiceUnitTest.java`

#### Test 1: Early return when no picking positions

```java
@Test
@DisplayName("returns true without section lookup when no picking positions exist")
void canOrderPositionBeCancelled_noPickingPositions_returnsTrueWithoutSectionLookup() {
    // position state < PACKED
    testPosition.setState(WmsConstants.State.RAW);

    when(pickingorderPositionRepository.findByCustomerorderpositionId(testPosition.getId()))
        .thenReturn(Collections.emptyList());

    boolean result = customerorderPositionService.canOrderPositionBeCancelled(testPosition);

    assertThat(result).isTrue();
    // Verify section lookup was never called — early return
    verify(sectionRepository, never()).findById(anyLong());
    verify(clientRepository, never()).findById(anyLong());
    verify(customerorderRepository, never()).findById(anyLong());
}
```

#### Test 2: Null sectionId falls to regular picking path

```java
@Test
@DisplayName("null sectionId uses regular picking path without crash")
void canOrderPositionBeCancelled_nullSectionId_usesRegularPickingPath() {
    testPosition.setState(WmsConstants.State.PROCESSABLE);

    // Has picking positions, so won't early-return
    PickingorderPosition pp = new PickingorderPosition();
    pp.setId(10L);
    pp.setPickingorderId(20L);
    pp.setState(WmsConstants.State.FINISHED);

    Pickingorder po = new Pickingorder();
    po.setId(20L);
    po.setState(WmsConstants.State.FINISHED);

    when(pickingorderPositionRepository.findByCustomerorderpositionId(testPosition.getId()))
        .thenReturn(List.of(pp));
    when(customerorderRepository.findById(testPosition.getOrderId()))
        .thenReturn(Optional.of(testOrder));

    // Client has null sectionId
    Client client = new Client();
    client.setId(testOrder.getClientId());
    client.setSectionId(null);
    when(clientRepository.findById(testOrder.getClientId()))
        .thenReturn(Optional.of(client));

    when(pickingorderRepository.findById(20L)).thenReturn(Optional.of(po));

    boolean result = customerorderPositionService.canOrderPositionBeCancelled(testPosition);

    assertThat(result).isTrue();
    // Section was never looked up
    verify(sectionRepository, never()).findById(anyLong());
}
```

#### Update existing test: `shouldReturnTrueWhenNoPickingPositionsExist`

The existing test at line ~109 mocks client and section lookup before testing empty picking positions. After the fix, those mocks are unnecessary since the early return happens before the section lookup. Remove the unnecessary stubs to avoid `UnnecessaryStubbingException` (strict mode).

### 4.2 `CustomerorderServiceUnitTest` — new test

#### Test: packageOrder with null sectionId throws BusinessException

```java
@Test
@DisplayName("packageOrder throws BusinessException when client has null sectionId")
void packageOrder_nullSectionId_throwsBusinessException() {
    // Setup order in packagable state
    // Client has null sectionId
    Client client = new Client();
    client.setId(testOrder.getClientId());
    client.setSectionId(null);
    when(clientRepository.findById(testOrder.getClientId())).thenReturn(Optional.of(client));

    // ... (standard packaging setup mocks) ...

    assertThatThrownBy(() -> customerorderService.packageOrder(testOrder.getId()))
        .isInstanceOf(BusinessException.class)
        .hasMessageContaining("client section not configured");
}
```

### 4.3 `ReleaseOrderJobServiceUnitTest` — update existing tests

Existing tests mock `clientRepository.findById()` returning a client with a valid `sectionId`. No new tests strictly needed, but one verification test should confirm the null-safe behavior:

```java
@Test
@DisplayName("releaseOrder throws BusinessException when client has no section configured")
void shouldThrowWhenClientHasNoSection() {
    // Setup order that passes initial guards
    testOrder.setState(WmsConstants.State.RAW);
    testOrder.setPickingdate(LocalDate.now());
    when(customerorderRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(testOrder));

    // Client with null sectionId
    Client client = new Client();
    client.setId(testOrder.getClientId());
    client.setSectionId(null);
    when(clientRepository.findById(testOrder.getClientId())).thenReturn(Optional.of(client));

    // ... (mock enough to reach the section lookup) ...

    assertThatThrownBy(() -> releaseOrderJobService.releaseOrder(1L, Map.of(), Map.of()))
        .isInstanceOf(BusinessException.class)
        .hasMessageContaining("Section not configured");
}
```

---

## 5. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| Early return in `canOrderPositionBeCancelled` changes behavior for orders with no picking positions | None — result is the same (`true`) but avoids unnecessary DB lookups | Behavior preserved: no picking positions = cancellable. Now just faster and crash-proof. |
| `packageOrder` exception type changes from `EntityNotFoundException` to `BusinessException` | Callers catching `EntityNotFoundException` won't catch the new exception | `packageOrder` is called from controllers — `RestExceptionHandler` maps both to appropriate HTTP responses. No caller catches `EntityNotFoundException` specifically. |
| `ReleaseOrderJobService` now throws `BusinessException` instead of `NoSuchElementException` | The outer `OrderReleaseJob` catch block already catches `BusinessException` (line 286) | Existing exception handling covers this. |
| `getSectionForOrder()` helper added only to `CustomerorderPositionService` | Slight code duplication if same pattern needed elsewhere | `CustomerorderService.cancelOrder()` already has its own inline null-safe pattern. Adding a shared utility would require a new service — not worth the abstraction for 2 call sites. |

---

## 6. Out of Scope (Same Pattern, Different Paths)

These locations have the same unsafe section lookup but are not in the cancellation/packaging/release paths:

| File | Lines | Method | Risk |
|:-----|:------|:-------|:-----|
| `OrderMonitorViewService.java` | 134, 141 | `printToteLabels` variants | Medium — UI action, would crash if client has no section |

Recommend fixing in a separate follow-up to limit blast radius.

---

## 7. Task Checklist

- [x] **Fix #1a** (HIGH): Add `getSectionForOrder()` helper to `CustomerorderPositionService` ✓ Implemented 2026-04-01
- [x] **Fix #1b** (HIGH): Reorder `canOrderPositionBeCancelled()` — check picking positions first, early return if empty, null-safe section lookup ✓ Implemented 2026-04-01
- [x] **Fix #2** (HIGH): Null-safe section lookup with BusinessException in `packageOrder()` ✓ Implemented 2026-04-01
- [x] **Fix #3** (MEDIUM): Null-safe section lookup in `ReleaseOrderJobService` lines 485-488 ✓ Implemented 2026-04-01
- [x] **Tests**: Updated `shouldReturnTrueWhenNoPickingPositionsExist` — removed unnecessary stubs, added early-return verification ✓ Implemented 2026-04-01
- [x] **Tests**: Added `shouldReturnTrueWhenClientHasNullSectionId` — null sectionId falls to regular path without crash ✓ Implemented 2026-04-01
- [ ] **Tests**: Add null-sectionId test for `packageOrder` — deferred (requires significant packaging test setup infrastructure)
- [ ] **Tests**: Add null-section test for `releaseOrder` — deferred (requires extensive mock chain to reach section lookup)
- [x] Run affected test suite and verify 0 new failures ✓ 123 tests across CustomerorderPositionServiceUnitTest (11), CustomerorderServiceUnitTest (85), ReleaseOrderJobServiceUnitTest (27) — all pass, 0 failures.
- [ ] Verify in staging

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java` | Add `getSectionForOrder()` helper, reorder `canOrderPositionBeCancelled()` for early return + null-safe section |
| `src/main/java/net/aim_ai/wms/service/CustomerorderService.java` | Null-safe section lookup in `packageOrder()` with BusinessException |
| `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java` | Null-safe section lookup with `.filter()` + `.orElseThrow()` |
| `src/test/java/net/aim_ai/wms/unit/service/CustomerorderPositionServiceUnitTest.java` | 2 new tests, update 1 existing test |
| `src/test/java/net/aim_ai/wms/unit/service/CustomerorderServiceUnitTest.java` | 1 new test for packageOrder |
| `src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java` | 1 new test for null section |
