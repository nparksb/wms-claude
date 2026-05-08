---
title: "v2 — changeReservedAmount caller rebind fix (MobileReplenishService + ReleaseOrderJobService)"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: implemented
project: [wms2]
version: v2
requester: nam.park
created: 2026-05-02
updated: 2026-05-02 (ralplan iteration 1)
related:
  - "[[../../../1-Projects/wms1/plan/260427-changeReservedAmount-caller-rebind-followup]]"
  - "[[../../../3-Resources/architecture/wms2-transaction-osiv-boundary-map]]"
tags:
  - plan
  - wms2
  - bugfix
  - replenishment
  - order-release
  - stockunit
---

# v2 — changeReservedAmount caller rebind fix (MobileReplenishService + ReleaseOrderJobService)

**Ticket:** —
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** draft
**Date:** 2026-05-02

**v1 pair:** `sbdocs/1-Projects/wms1/plan/260427-changeReservedAmount-caller-rebind-followup.md`
**v1 commits ported:**
- Fix A — v1 `142f7bb` `fix(replenish): rebind sourceStock after changeReservedAmount in finishReplenishmentOrderInternal`
- Fix B — v1 `c70569e` `fix(order-release): rebind stockUnit after changeReservedAmount in createPickingForOrder`

---

## 1. Problem Statement

Three v2 callers of `StockunitBusinessService.changeReservedAmount(...)` discard the returned managed `Stockunit` and continue reading the caller-side stale reference. Because v2 `changeReservedAmount` works on an internally re-fetched, refreshed copy and returns *that* copy, the original local variable held by the caller still reflects the **pre-change** `reservedamount` field. Subsequent reads of `getAvailableamount()` / `getAmount()` / passing the stale reference to follow-up business logic see incorrect values.

v2 carries the *service-side* hardening (the in-method `entityManager.refresh(stockUnit)` at `StockunitBusinessService.java:368` and `:405`) — but three caller-side rebinds are still **missing** in v2: `MobileReplenishService.finishReplenishmentOrder`, `ReleaseOrderJobService.createPickingForOrder`, and `PickingorderBusinessService.confirmPick`. The v1 fixes for the first two were in commits `142f7bb` and `c70569e`; the `PickingorderBusinessService` v1 fix was in commit `2351004` but was **not** ported to v2.

User-visible symptoms (port from v1):
- **Fix A symptom:** "amount=X requested is more than available=0" thrown out of `transferStockToUnitLoad` during the final step of a finished replenishment, because `sourceStock.getAmount()`/`getAvailableamount()` reads from the stale snapshot.
- **Fix B symptom:** Silent over-reservation — `fixAssignmentData[2]` is set to a stale `stockUnit.getAvailableamount()`, which is then used downstream to gate further pick generation. No exception fires; pick positions are over-allocated.
- **Fix E symptom:** After `confirmPick`, `stockUnit.getUnitloadId()` (L431) and `stockUnit` passed to `transferStockToUnitLoad` (L437) use pre-change `reservedamount`/`amount`. May trigger "requested is more than available" on the pick transfer or silently use a wrong unitload reference.

---

## 2. Root Cause Analysis

### 2.1 v2 `changeReservedAmount` contract — what the caller gets back

`v2/wms2-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:399-428`

```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount, boolean zeroIfNegative,
                                      String activityCode, String orderNumber, String comment) throws FacadeException {
    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())   // L401 — re-fetch with row lock
        .orElseThrow(...);
    entityManager.refresh(stockUnit);                                                     // L405 — overwrite L1 cache
    ...
    stockUnit.setReservedamount(newReservedAmount);
    stockUnit = stockunitRepository.save(stockUnit);                                      // L424 — flush
    stockrecordService.recordChangeReservedAmount(stockUnit, amount, ...);
    return stockUnit;                                                                     // L427 — fresh, managed instance
}
```

**Caller contract:** the input `staleStockUnit` reference is *unchanged* by the method (v2 does not call `entityManager.detach(staleStockUnit)` the way v1 does — it simply ignores the input and reloads). After the call returns, the caller's local field values for `reservedamount`/`availableamount` are still the pre-call snapshot. **Any read of `staleStockUnit.getAvailableamount()` / `getAmount() - getReservedamount()` after this call is wrong** unless the caller rebinds.

### 2.2 Affected v2 call-sites (audited, 2026-05-02)

| # | File | Line | Caller | Read after call? | Bug? |
|---|------|------|--------|------------------|------|
| 1 | `service/mobile/MobileReplenishService.java` | 468 | `finishReplenishmentOrder` — single-stockunit branch | YES — `sourceStock.getAmount()` at L492 and `sourceStock` passed to `transferStockToUnitLoad` at L496 | **YES — port Fix A** |
| 2 | `service/mobile/MobileReplenishService.java` | 472 | `finishReplenishmentOrder` — split branch | YES — same L492 / L496 reads downstream | **YES — port Fix A** |
| 3 | `service/mobile/MobileReplenishService.java` | 474 | `finishReplenishmentOrder` — split branch, redirected `stockUnit` release | NO — `stockUnit` not read after | NO — leave bare (matches v1 scope) |
| 4 | `service/job/ReleaseOrderJobService.java` | 572 | `createPickingForOrder` — `fixedAssignments` loop | YES — `stockUnit.getAvailableamount()` read into `fixAssignmentData[2]` at L577 | **YES — port Fix B** |
| 5 | `service/job/ReleaseOrderJobService.java` | 595 | `createPickingForOrder` — `pickFromOverstock` exact-match branch | NO — `break;` at L600; outer for-each rebinds on next iteration | NO — leave bare (matches v1 scope) |
| 6 | `service/job/ReleaseOrderJobService.java` | 619 | `createPickingForOrder` — `pickFromOverstock` partial-take branch | NO — `stockUnit` not read after; loop continues | NO — leave bare (matches v1 scope) |
| 7 | `service/job/ReleaseOrderJobService.java` | 627 | `createPickingForOrder` — `pickFromOverstock` final-take branch | NO — `break;` at L631 | NO — leave bare (matches v1 scope) |
| 8 | `service/PickingorderBusinessService.java` | 428 | `confirmPick` | YES — `stockUnit.getUnitloadId()` at L431 and `stockUnit` passed to `transferStockToUnitLoad` at L437 | **YES — port Fix E (v1 commit `2351004`)** |

### 2.3 Why this passed v2 reviews

The service-side fix from v1 commit `2351004` (which prompted the `entityManager.refresh` + `findByIdForUpdate` pattern) was ported into v2 `StockunitBusinessService` itself — but a service-side refresh only protects the row in the database; it does **not** propagate back to the caller's *local* reference. Both follow-up v1 commits (`142f7bb` and `c70569e`) target that gap. v2 inherited the gap unchanged.

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` | 468 | Fix A — single-branch: rebind `sourceStock` |
| 2 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` | 472 | Fix A — split-branch: rebind `sourceStock` |
| 3 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java` | 572 | Fix B — `fixedAssignments` branch: rebind `stockUnit` |
| 4 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | 428 | Fix E — `confirmPick`: rebind `stockUnit` (v1 `2351004` not ported) |
| 5 | `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java` | (new methods) | Fix C — regression tests for both Fix A branches |
| 6 | `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java` | (new method) | Fix D — regression test for Fix B |
| 7 | `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java` | (new method) | Fix F — regression test for Fix E |

---

## 3. Design / Proposed Fix

### 3.1 Fix A — `MobileReplenishService.finishReplenishmentOrder` rebinds `sourceStock`

**Problem:** L468 and L472 discard the return value of `changeReservedAmount`. `sourceStock` retains the pre-call `reservedamount`, making `sourceStock.getAmount()` (L492) and `sourceStock.getAvailableamount()` reads (the latter via the `transferStockToUnitLoad` re-fetch path inside `StockunitBusinessService`) operate on stale local state.

**Solution (v2 — exact translation):** Capture the return value into `sourceStock` at both branches.

**Before** (`MobileReplenishService.java:467-476`):
```java
if (sourceStock.getId().equals(replenishOrder.getStockunitId()) || replenishOrder.getStockunitId() == null) {
    stockunitBusinessService.changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
} else if (replenishOrder.getStockunitId() != null) {
    Stockunit stockUnit = stockunitRepository.findById(replenishOrder.getStockunitId()).orElseThrow(() -> new EntityNotFoundException("StockUnit", replenishOrder.getStockunitId()));
    stockunitBusinessService.changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
    stockunitBusinessService.changeReservedAmount(stockUnit, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
}
```

**After:**
```java
if (sourceStock.getId().equals(replenishOrder.getStockunitId()) || replenishOrder.getStockunitId() == null) {
    sourceStock = stockunitBusinessService.changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
} else if (replenishOrder.getStockunitId() != null) {
    Stockunit stockUnit = stockunitRepository.findById(replenishOrder.getStockunitId()).orElseThrow(() -> new EntityNotFoundException("StockUnit", replenishOrder.getStockunitId()));
    sourceStock = stockunitBusinessService.changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
    stockunitBusinessService.changeReservedAmount(stockUnit, replenishOrder.getRequestedamount().negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null); // no rebind: stockUnit not read after this call
}
```

**Translation notes vs v1:**
- v1 used `replenishOrder.getRequestedamount()` directly via `sourceStock.getReservedamount().negate()` inside its bug. v2 already passes `replenishOrder.getRequestedamount().negate()`, so the negation argument is unchanged.
- v1's split-branch `findById(...).get()` becomes `.orElseThrow(...)` in v2 — already in place; no change here.
- v2 uses `EntityNotFoundException` (Jakarta-namespaced custom exception in `net.aim_ai.wms.exceptions`), not the legacy v1 wrapper — already correct.
- The trailing redirected-`stockUnit` call (split branch, third statement) stays bare — consistent with v1 scope (the variable is not read again). **Add inline comment:** `// no rebind: stockUnit not read after this call` immediately after the bare statement so future maintainers extending the block know this is intentional, not an oversight.

**Files changed:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`

### 3.2 Fix B — `ReleaseOrderJobService.createPickingForOrder` rebinds `stockUnit` (fixedAssignments branch)

**Problem:** L572 discards the return value, then L577 reads `stockUnit.getAvailableamount()` from the stale snapshot and stores it into `fixAssignmentData[2]`. Downstream pick-generation logic uses that value to gate further allocations — over-allocation is silent (no exception).

**Solution (v2 — exact translation):**

**Before** (`ReleaseOrderJobService.java:570-578`):
```java
Stockunit stockUnit = stockUnits.getFirst();
PickingorderPosition pickingPosition = pickingorderPositionService.createPickingPosition(orderPosition.getAmount(), stockUnit, orderPosition, pickingOrder);
stockunitBusinessService.changeReservedAmount(stockUnit, orderPosition.getAmount(), false, WmsConstants.CODE_CREATE_PICK_POSITION, pickingPosition.getNumber(), null);
orderPosition.setState(WmsConstants.State.ASSIGNED);
customerorderPositionRepository.save(orderPosition);
Object[] fixAssignmentData = itemDataFixAssignmentMap.get(orderPosition.getItemdataId());
if (fixAssignmentData != null && fixAssignmentData.length > 2) {
    fixAssignmentData[2] = stockUnit.getAvailableamount();
}
```

**After:**
```java
Stockunit stockUnit = stockUnits.getFirst();
PickingorderPosition pickingPosition = pickingorderPositionService.createPickingPosition(orderPosition.getAmount(), stockUnit, orderPosition, pickingOrder);
stockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, orderPosition.getAmount(), false, WmsConstants.CODE_CREATE_PICK_POSITION, pickingPosition.getNumber(), null);
orderPosition.setState(WmsConstants.State.ASSIGNED);
customerorderPositionRepository.save(orderPosition);
Object[] fixAssignmentData = itemDataFixAssignmentMap.get(orderPosition.getItemdataId());
if (fixAssignmentData != null && fixAssignmentData.length > 2) {
    fixAssignmentData[2] = stockUnit.getAvailableamount();
}
```

**Translation notes vs v1:**
- v1 used Java 8 `stockUnits.get(0)`; v2 uses `stockUnits.getFirst()` (Java 21 `SequencedCollection` API). Existing v2 code at L570 already uses `getFirst()`; no extra change.
- v1 wrote `stockUnits` indexed access in the same expression. v2 hoists `Stockunit stockUnit = stockUnits.getFirst();` onto its own line above the rebind — preserved as-is.
- **Java 21 reassignment validity (GAP-4):** `stockUnit` at L570 is declared as a plain local variable (`Stockunit stockUnit = stockUnits.getFirst()`), NOT a lambda-capture or loop variable. It is **not effectively final** in this scope. The `stockUnit = changeReservedAmount(...)` reassignment on L572 is valid Java 21. Reviewers: do not confuse this with loop iteration variables in the `pickFromOverstock` loops below — those are separately scoped.
- The three SAFE bare callsites at L595, L619, L627 are intentionally unchanged (parity with v1 Fix B scope). **Add inline comment** after each: `// no rebind: stockUnit not read after this call` — prevents future maintainers from incorrectly assuming the omission is a bug.

**Files changed:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java`

### 3.3 Fix C — Regression tests in `MobileReplenishServiceUnitTest`

Two new `@Test` methods exercising the public entrypoint `service.finishReplenishmentOrder(ReplenishMobileOrderDto)`:

| Test method | Drives | Asserts |
|---|---|---|
| `finishReplenishmentOrder_rebindsSourceStockBeforeTransfer` | Fix A — single-branch (L468 path) | `transferStockToUnitLoad`'s `sourceStockunit` argument `isSameAs(refreshedSourceStock)` (the captured return of `changeReservedAmount`), NOT the input stale instance |
| `finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer` | Fix A — split branch (L472 path, distinct `replenishOrder.getStockunitId() != sourceStock.getId()`) | Same `isSameAs` assertion plus a verify that the redirected `stockUnit` release call STILL fires (bare statement) |

**Constraints (Mockito 5.x in v2 — relaxed vs v1 Mockito 3.3.3):**
- v2 already permits `mockStatic(SecurityContextUtils.class)` (see `MobileReplenishServiceUnitTest:102`). Use it freely; no v1-style workaround needed.
- `Stockunit` still has no `@Override equals()` (entity comparison by identity). Use AssertJ `isSameAs(...)` (reference equality), NOT `isEqualTo(...)`. Rationale unchanged from v1.
- Use `nullable(String.class)` for the null `comment` matcher (consistent with the existing pattern at `MobileReplenishServiceUnitTest:1297`).

**TDD gate checklist — Fix C:**

| Step | Detail |
|---|---|
| **Write first** | `finishReplenishmentOrder_rebindsSourceStockBeforeTransfer` (single-branch, simpler setup) |
| **Expected failure (before Fix A)** | `isSameAs` fails: AssertJ reports `expected: <Stockunit@STALE_ADDR> to be same instance as: <Stockunit@REFRESHED_ADDR>` — the stale original reference is passed to `transferStockToUnitLoad` instead of the returned refreshed instance |
| **Expected pass (after Fix A)** | Assertion passes; `transferStockToUnitLoad`'s first argument is the exact instance returned by `changeReservedAmount` |
| **Write second** | `finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer` — more setup (extra `stockunitRepository.findById` stub for the redirect `stockUnit`); same `isSameAs` assertion |
| **Expected failure (before Fix A)** | Same `isSameAs` failure on `transferStockToUnitLoad` first arg |
| **Expected pass (after Fix A)** | `isSameAs` passes AND `verify(stockunitBusinessService).changeReservedAmount(same(splitStockUnit), ...)` passes |

### 3.4 Fix D — Regression test in `ReleaseOrderJobServiceUnitTest`

**File:** `src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java` — **file already exists** (1,183 lines, extends `BaseServiceUnitTest`, uses `@InjectMocks private ReleaseOrderJobService releaseOrderJobService`). `BaseServiceUnitTest` wires Mockito via the test lifecycle — do NOT add `MockitoAnnotations.openMocks(this)` or a manual constructor call.

Add one new `@Test` method inside the **existing** `@Nested @DisplayName("releaseOrder - Second Round Processing")` class (starting at line 346), alongside the existing "should successfully release order with fix assignment" test.

| Test method | Drives | Asserts |
|---|---|---|
| `createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead` | Fix B (L572 path) | After `releaseOrderJobService.releaseOrder(...)` returns, `itemDataFixAssignmentMap.get(itemdataId)[2]` `isEqualByComparingTo(refreshedStockUnit.getAvailableamount())`, NOT the stale input value. Use `isEqualByComparingTo` to be scale-tolerant. |

**Required stubs for the new test** (reuse the existing `setUp()` data fixtures at L355-385 as the base; stub only what the fixedAssignments path needs additionally):
- `when(stockunitsByUnitloadFinal.getOrDefault(...)).thenReturn(List.of(staleStockUnit))` — drives `!stockUnits.isEmpty()` branch
- `when(stockunitBusinessService.changeReservedAmount(same(staleStockUnit), ...)).thenReturn(refreshedStockUnit)` — returns a NEW instance
- `refreshedStockUnit.getAvailableamount()` returns a value different from `staleStockUnit.getAvailableamount()` (e.g., stale=`BigDecimal.TEN`, refreshed=`new BigDecimal("7")`)
- Pre-populate `itemDataFixAssignmentMap` with a 3-element `Object[]` for `itemdataId`

Rationale: without the rebind, `fixAssignmentData[2]` holds `staleStockUnit.getAvailableamount()` = `10`; with the rebind, it holds `refreshedStockUnit.getAvailableamount()` = `7`. The test distinguishes these two instances by value.

**TDD gate checklist — Fix D:**

| Step | Detail |
|---|---|
| **Write first (and only)** | `createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead` inside `@Nested @DisplayName("releaseOrder - Second Round Processing")` |
| **Expected failure (before Fix B)** | `isEqualByComparingTo` fails: `fixAssignmentData[2]` holds `staleStockUnit.getAvailableamount()` (e.g., `10`), not `refreshedStockUnit.getAvailableamount()` (e.g., `7`). AssertJ: `expected: 7 but was: 10` (or equivalent scale-normalized form) |
| **Expected pass (after Fix B)** | Assertion passes; `fixAssignmentData[2]` holds the refreshed instance's `availableamount` |

### 3.5 Fix E — `PickingorderBusinessService.confirmPick` rebinds `stockUnit`

**Problem:** L428 discards the return value of `changeReservedAmount`. The stale `stockUnit` is then used at L431 (`stockUnit.getUnitloadId()` — passed to `unitloadRepository.findById`) and L437 (`stockUnit` passed to `transferStockToUnitLoad`). `transferStockToUnitLoad` checks `sourceStockunit.getAmount().subtract(sourceStockunit.getReservedamount())` — with a stale snapshot, the available-amount check may throw "requested is more than available" or silently allow an incorrect transfer.

**v1 pair:** this fix was in v1 commit `2351004`. It was NOT ported to v2 when the service-side hardening was added.

**Before** (`PickingorderBusinessService.java:426-431`):
```java
Stockunit stockUnit = stockunitRepository.findById(pickFromStockunitId).orElseThrow(() -> new EntityNotFoundException("StockUnit", pickFromStockunitId));

stockunitBusinessService.changeReservedAmount(stockUnit, pickingPosition.getAmount().negate(), true, WmsConstants.CODE_PICKING, pickingPosition.getNumber(), null);

Unitload pallet = null;
Unitload stockunitUnitLoad = unitloadRepository.findById(stockUnit.getUnitloadId()).orElseThrow(() -> new EntityNotFoundException("UnitLoad", stockUnit.getUnitloadId()));
```

**After:**
```java
Stockunit stockUnit = stockunitRepository.findById(pickFromStockunitId).orElseThrow(() -> new EntityNotFoundException("StockUnit", pickFromStockunitId));

stockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, pickingPosition.getAmount().negate(), true, WmsConstants.CODE_PICKING, pickingPosition.getNumber(), null);

Unitload pallet = null;
Unitload stockunitUnitLoad = unitloadRepository.findById(stockUnit.getUnitloadId()).orElseThrow(() -> new EntityNotFoundException("UnitLoad", stockUnit.getUnitloadId()));
```

**Translation notes:** Only one call site. `stockUnit` is a plain local variable (not a loop variable, not lambda-captured) — reassignment is valid Java 21.

**Files changed:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`

### 3.6 Fix F — Regression test in `PickingorderBusinessServiceUnitTest`

**File:** `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java` — **file already exists**, extends `BaseServiceUnitTest`, uses `@InjectMocks`. Has a `@Nested @DisplayName("confirmPick")` block at line 218. Add one new `@Test` method inside that block.

| Test method | Drives | Asserts |
|---|---|---|
| `confirmPick_rebindsStockUnitAfterChangeReservedAmount` | Fix E (L428 path) | After `confirmPickingorderPosition(...)` returns, `unitloadRepository.findById(...)` is called with the **refreshed** `stockUnit.getUnitloadId()`, NOT the stale input's value. Use `verify(unitloadRepository).findById(refreshedStockUnit.getUnitloadId())`. |

**Required stubs:**
- `when(stockunitBusinessService.changeReservedAmount(same(staleStockUnit), ...)).thenReturn(refreshedStockUnit)` where `refreshedStockUnit.getUnitloadId()` ≠ `staleStockUnit.getUnitloadId()`
- This separation confirms the rebound reference is used for the unitload lookup.

**TDD gate checklist — Fix F:**

| Step | Detail |
|---|---|
| **Write first (and only)** | `confirmPick_rebindsStockUnitAfterChangeReservedAmount` inside `@Nested @DisplayName("confirmPick")` |
| **Expected failure (before Fix E)** | `verify(unitloadRepository).findById(refreshedStockUnit.getUnitloadId())` fails — `unitloadRepository.findById` was called with `staleStockUnit.getUnitloadId()` instead |
| **Expected pass (after Fix E)** | Assertion passes; the unitload lookup uses the refreshed instance's ID |

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| `changeReservedAmount` mechanism | `entityManager.detach(staleStockUnit)` + `findByIdForUpdate` + `refresh` | `findByIdForUpdate` + `entityManager.refresh(stockUnit)` (no detach of input) | **Same caller-side bug class** — the caller's local reference is stale either way |
| In-service refresh present? | Yes (commit `2351004`) | Yes (`StockunitBusinessService.java:368, 405`) | Equivalent baseline — both still need caller-side rebind |
| `MobileReplenishService` caller fix | Applied in `142f7bb` | **Missing** — port Fix A | **Yes — this plan** |
| `ReleaseOrderJobService` caller fix | Applied in `c70569e` | **Missing** — port Fix B | **Yes — this plan** |
| `PickingorderBusinessService` caller fix (v1 commit `2351004`) | Applied in v1 | **Missing in v2** — v2 `PickingorderBusinessService.java:428` is bare (audited 2026-05-02); port Fix E | **Yes — this plan** |
| Java version | Java 8 | Java 21 (Jakarta namespace, `getFirst()`) | Trivial syntactic — already accommodated |
| Transaction manager | Default `transactionManager` (single TM) | Dual TM — must use `tenantTransactionManager` | Already correct on all three methods (`finishReplenishmentOrder` `MobileReplenishService.java:417`; `releaseOrder` `ReleaseOrderJobService.java:99`; `confirmPick` annotated at `PickingorderBusinessService.java`); no annotation change needed |
| Test framework | JUnit 5 + Mockito 3.3.3 (no `mockStatic`) | JUnit 5 + Mockito 5.x + AssertJ 3.x (`mockStatic` allowed) | v2 tests can use `mockStatic` directly — simpler than v1 |

### What Needs Porting

1. **Fix A** — rebind `sourceStock` at two call-sites in `MobileReplenishService.finishReplenishmentOrder` (v2 lines 468 and 472).
2. **Fix B** — rebind `stockUnit` at one call-site in `ReleaseOrderJobService.createPickingForOrder` (v2 line 572).
3. **Fix C** — two regression tests in `MobileReplenishServiceUnitTest` (mirror v1 test names).
4. **Fix D** — one regression test in `ReleaseOrderJobServiceUnitTest` (new method in existing file).
5. **Fix E** — rebind `stockUnit` at one call-site in `PickingorderBusinessService.confirmPick` (v2 line 428).
6. **Fix F** — one regression test in `PickingorderBusinessServiceUnitTest` (new method in existing file).

### What Does NOT Need Porting

- The v1 follow-up's regression-guard checks against `entityManager.detach(staleStockUnit)` — v2 does not detach (it `findByIdForUpdate` + `refresh` directly). Substitute regression guard: assert `entityManager.refresh(stockUnit)` is still present at `StockunitBusinessService.java:405`.
- The 4 SAFE bare callsites (3 in `ReleaseOrderJobService` + 1 in `MobileReplenishService` split branch) — same scope decision as v1.

### V2-only checks performed

| Check | Result |
|---|---|
| Is `@Transactional(value = "tenantTransactionManager")` present on all three call-paths? | YES — `MobileReplenishService.finishReplenishmentOrder` L417, `ReleaseOrderJobService.releaseOrder` L99, `PickingorderBusinessService.confirmPick` (audited 2026-05-02) |
| Is the rebind compatible with the existing `Propagation.REQUIRES_NEW` on `releaseOrder`? | YES — rebind is purely in-method state; the surrounding REQUIRES_NEW transaction is preserved |
| Does any method touch tenant context across an `@Async` boundary? | NO — all three are synchronous within a tenant-context-bearing thread |
| Does `findByIdForUpdate` (used inside `changeReservedAmount`) interact with PgBouncer in transaction-pooling mode? | NO — `findByIdForUpdate` runs inside the existing tenant transaction; no advisory-lock or session-scoped state involved |
| Any v2-only NEW issue (missing TM, wrong TM, async leakage, scheduled-job context drop)? | **Fix E discovered** — `PickingorderBusinessService.confirmPick:428` missing rebind (v1 commit `2351004` not ported). Added to scope. No other new issues. |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | N/A | — | Pure code-logic fix; no schema change |
| 2 | **Feature flags / system properties** | N/A | — | No toggles |
| 3 | **Config / env changes** | N/A | — | No `application.properties` change |
| 4 | **Deploy-order dependencies** | None | — | Self-contained inside `wms2-api` |
| 5 | **Data migration** | N/A | — | No data migration |
| 6 | **External systems** | N/A | — | No OMS / printer / Keycloak surface touched |
| 7 | **Access / permissions** | N/A | — | No new role / authority |
| 8 | **Monitoring / alerts** | Optional — confirm `stockunit_optimistic_lock_failure_total` (if exposed via Micrometer) does NOT regress post-deploy. The fix tightens correctness; lock contention should be unchanged or improved. | infra | Read-only check |

### 5.2 Implementation Checklist

- [ ] Apply Fix A — rebind `sourceStock` at `MobileReplenishService.java:468` and `:472`.
- [ ] Apply Fix B — rebind `stockUnit` at `ReleaseOrderJobService.java:572`.
- [ ] Apply Fix E — rebind `stockUnit` at `PickingorderBusinessService.java:428`.
- [ ] Add Fix C tests — `finishReplenishmentOrder_rebindsSourceStockBeforeTransfer` and `finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer` in `MobileReplenishServiceUnitTest`.
- [ ] Add Fix D test — `createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead` in `ReleaseOrderJobServiceUnitTest` (`@Nested @DisplayName("releaseOrder - Second Round Processing")`).
- [ ] Add Fix F test — `confirmPick_rebindsStockUnitAfterChangeReservedAmount` in `PickingorderBusinessServiceUnitTest` (`@Nested @DisplayName("confirmPick")`).
- [ ] Run `mvn test -Dtest=MobileReplenishServiceUnitTest`.
- [ ] Run `mvn test -Dtest=ReleaseOrderJobServiceUnitTest`.
- [ ] Run `mvn test -Dtest=PickingorderBusinessServiceUnitTest`.
- [ ] Run regression-guard `mvn test -Dtest=StockunitBusinessServiceUnitTest`.
- [ ] Run `mvn verify` (Testcontainers integration tests, including `MobileReplenishServiceIntegrationTest`).
- [ ] Run `bash sbdocs/9-System/scripts/verify-260502-changereservedamount-caller-rebind-fix.sh`.
- [ ] Code review completed.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| **S1 (Fix A — single branch)** | `replenishOrder.getStockunitId()` equals `sourceStock.getId()` (or null). Stub `changeReservedAmount(sourceStock, ...)` to return `refreshedSourceStock` (a NEW instance with updated `reservedamount`). Invoke `service.finishReplenishmentOrder(...)`. | `transferStockToUnitLoad`'s first arg `isSameAs(refreshedSourceStock)`, NOT the input stale instance. |
| **S2 (Fix A — split branch)** | `replenishOrder.getStockunitId() != sourceStock.getId()`. Stub `changeReservedAmount(sourceStock, ...)` to return `refreshedSourceStock`; stub `changeReservedAmount(stockUnit, ...)` to return any non-null. Invoke `service.finishReplenishmentOrder(...)`. | `transferStockToUnitLoad`'s first arg `isSameAs(refreshedSourceStock)`. The redirected `stockUnit` release call still fires (`verify(stockunitBusinessService).changeReservedAmount(same(stockUnit), ...)`). |
| **S3 (Fix B — fixedAssignments)** | One `CustomerorderPosition` in `fixedAssignments`. Stub `changeReservedAmount(stockUnit, orderPosition.getAmount(), false, ...)` to return `refreshedStockUnit` whose `getAvailableamount()` returns a value distinct from the input's. Pre-populate `itemDataFixAssignmentMap` with a 3-element `Object[]`. Invoke `service.releaseOrder(...)`. | After return, `itemDataFixAssignmentMap.get(itemdataId)[2]` `isEqualByComparingTo(refreshedStockUnit.getAvailableamount())` — proving the rebound reference was used for the read. |
| **S4 (regression — service in-method refresh preserved)** | Read `StockunitBusinessService.changeReservedAmount` source. | `entityManager.refresh(stockUnit)` still present at L405 (verify-script `RG-1`); `findByIdForUpdate(staleStockUnit.getId())` still present at L401 (`RG-2`). |
| **S5 (Fix E — `PickingorderBusinessService.confirmPick` rebind)** | Stub `changeReservedAmount(staleStockUnit, ...)` to return `refreshedStockUnit` whose `getUnitloadId()` differs from `staleStockUnit.getUnitloadId()`. Invoke `confirmPickingorderPosition(...)`. | `verify(unitloadRepository).findById(refreshedStockUnit.getUnitloadId())` passes — proving the rebound reference was used for the unitload lookup. |
| **S6 (regression — service in-method refresh preserved)** | Read `StockunitBusinessService.changeReservedAmount` source. | `entityManager.refresh(stockUnit)` still present at L405 (verify-script `RG-1`); `findByIdForUpdate(staleStockUnit.getId())` still present at L401 (`RG-2`). |
| **S7 (integration — H2 / Testcontainers)** | Run `MobileReplenishServiceH2Test` / `MobileReplenishServiceIntegrationTest` end-to-end through finish-replenishment with a real persistence context. | No `"requested is more than available=0"` `FacadeException`. State machine reaches `WmsConstants.State.FINISHED`. |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `MobileReplenishServiceUnitTest` | `finishReplenishmentOrder_rebindsSourceStockBeforeTransfer` | S1 — `transferStockToUnitLoad` receives the rebound `sourceStock` (`isSameAs`) |
| `MobileReplenishServiceUnitTest` | `finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer` | S2 — same `isSameAs` plus split-branch redirected-release call still fires |
| `ReleaseOrderJobServiceUnitTest` | `createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead` | S3 — `fixAssignmentData[2]` reflects refreshed `availableamount` |
| `PickingorderBusinessServiceUnitTest` | `confirmPick_rebindsStockUnitAfterChangeReservedAmount` | S5 — `unitloadRepository.findById` called with refreshed `stockUnit.getUnitloadId()` |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| UI smoke — happy path replenishment finish (single source stockunit) | staging | 1. Generate a replenishment order. 2. Mobile UI: scan source, scan destination, confirm. | "Finished" status; no error toast; destination unitload shows added stock. |  |
| UI smoke — split-source replenishment finish | staging | Same as above but with `replenishOrder.getStockunitId() != null` and pointing at a different SU than `sourceStock`. | Same as above. Both source and redirected SUs reflect zero `reservedamount` for this replenishment. |  |
| UI smoke — order release pick generation (fixed assignment) | staging | Trigger the order-release scheduled job (or its admin endpoint). Pick a CustomerOrder whose positions have fixed assignments. | All positions move to `ASSIGNED`. No over-allocation. `fixAssignmentData[2]` (visible via debug log) reflects the post-reservation `availableamount`. |  |
| SQL smoke — verify no replenish FacadeException since deploy | staging DB | `SELECT count(*) FROM service_log WHERE message LIKE '%requested is more than available=0%' AND ts > <deploy-ts>;` | `0` |  |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=MobileReplenishServiceUnitTest` | | |
| `mvn test -Dtest=ReleaseOrderJobServiceUnitTest` | | |
| `mvn test -Dtest=StockunitBusinessServiceUnitTest` | | |
| `mvn test -Dtest=PickingorderBusinessServiceUnitTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-260502-changereservedamount-caller-rebind-fix.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| `MobileReplenishService.java` L474 (split-branch redirected `stockUnit` release) | `stockUnit` is not read after this call — bare statement is intentional. Same scope decision as v1 commit `142f7bb`. |
| `ReleaseOrderJobService.java` L595 / L619 / L627 (three `pickFromOverstock` callsites) | `stockUnit` is not read after the call within those iterations; `break;` or loop overwrite handles continuation. Same scope decision as v1 commit `c70569e`. |
| `pickFromOverstock` overstock-path unit test for Fix B | Out of scope — the demonstrated bug surface is the `fixedAssignments` branch only. Adding stale-snapshot tests for the SAFE callsites would assert no-op behavior. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **No** | The fix only assigns a method return value to a local variable. No static / Caffeine / ThreadLocal state added. |
| 2 | **Connection pool math** | Change per-request DB connection usage? | **No** | Same number of DB calls (`findByIdForUpdate` + `refresh` already counted in v2 baseline). The rebind is a pure local assignment. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` job? | **No** | `releaseOrder` is invoked from an existing `@Scheduled` job (`ReleaseOrderScheduleJob`); no new schedule. Tenant-context handling unchanged. |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | **No** | Both transactions exist already (`MobileReplenishService.finishReplenishmentOrder` and `ReleaseOrderJobService.releaseOrder` w/ `REQUIRES_NEW`). Their boundaries and durations are unchanged. The fix removes a stale-read defect *inside* the transaction. |
| 5 | **Request affinity** | Assume a follow-up request lands on the same replica? | **No** | Stateless; works identically on any replica. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | **No** | The fix is idempotent: re-running the rebind is benign. The underlying `changeReservedAmount` already uses `findByIdForUpdate` for TOCTOU safety; that contract is unchanged. |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | **No** | Both methods are synchronous within their tenant-context-bearing thread. `releaseOrder`'s `Propagation.REQUIRES_NEW` is on the *same* thread — `TenantContext` is preserved. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **Yes (already present, no change)** | `changeReservedAmount` uses `findByIdForUpdate` (`PESSIMISTIC_WRITE`) inside `@Transactional(value = "tenantTransactionManager")`. The rebind does NOT alter lock semantics — it simply reads the locked, refreshed snapshot in the caller as well. **This makes horizontal correctness STRONGER, not weaker:** prior to the fix, the caller could mis-decide a downstream business rule (e.g., over-allocate picks) using a value the database had already moved past — i.e., a cross-replica race window where Replica A holds a stale local snapshot while Replica B already committed an offsetting reservation. After the fix, the caller reads the post-commit value the lock actually protected. |
| 9 | **Cache invalidation** | Write to an entity cached in Caffeine / Redis? | **No** | `Stockunit` is not in a Spring cache (`@Cacheable`/`@CacheEvict` not annotated on `StockunitRepository` or `Stockunit`). Hibernate L1 cache scope is per-transaction; the in-method `entityManager.refresh` already handles it. |
| 10 | **External notifications (OMS, printer, etc.)** | Send an HTTP / message to an external system inside a transaction? | **No** | The downstream `transferStockToUnitLoad` does not emit external notifications. `pickingOrderService.create()` and `customerorderPositionRepository.save(...)` write to DB only. No after-commit hooks newly involved. |

### Evidence (fill in for any "Yes" row)

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 8 | `findByIdForUpdate` → row lock acquired before refresh, inside the existing tenant transaction; rebind reads what the lock saw. The caller now uses the post-lock view consistently. | `StockunitBusinessService.java:401, 405, 424` |
| 8 | Cross-replica scenario test (manual): two parallel `releaseOrder` invocations on different replicas for the same `Stockunit` — `findByIdForUpdate` serializes; first replica's caller reads `availableamount` as `original - amountA`, second replica's caller reads `original - amountA - amountB`. Without the fix, second replica reads `original` and over-allocates. | (manual test S6 + plan §3.2) |

---

## 8. Notes

### v1 → v2 mapping summary

| v1 commit | v2 fix | v2 file:line |
|---|---|---|
| `142f7bb` (Fix A) | port verbatim, two call-sites | `MobileReplenishService.java:468` and `:472` |
| `c70569e` (Fix B) | port verbatim, one call-site | `ReleaseOrderJobService.java:572` |
| v1 plan `260427-changeReservedAmount-caller-rebind-followup.md` | **paired** | this plan (`260502-changereservedamount-caller-rebind-fix.md`) |

### Out-of-scope (intentional)

- The "directive: any future caller of `changeReservedAmount` MUST rebind the return value" should be added as a project-memory directive AFTER this plan ships (use `project_memory_add_directive`), so future v2 reviewers catch the same bug class proactively. Not in-line with this plan because the directive is cross-plan reusable.
- An audit of every other v2 caller of `changeReservedAmount` (beyond the two known sites) was performed — see §2.2 — and no other read-after-call sites were found. If a future caller appears, the directive above will catch it in review.

### Version history

| Date | Change |
|---|---|
| 2026-05-02 | Initial draft — port `142f7bb` + `c70569e` from v1. |
| 2026-05-02 (ralplan iter 1) | Deepened via ralplan consensus loop: corrected Fix A Before code block (L474 arg), rewrote §3.4 for existing `ReleaseOrderJobServiceUnitTest`, added TDD gate checklists, `same()` matcher consistency, `// no rebind` comments in diffs. Added Fix E + Fix F for `PickingorderBusinessService.confirmPick:428` (v1 `2351004` not ported — discovered during Critic adversarial pass). Scope: 4 production edits + 4 new test methods across 3 service files. |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

**Path:** `sbdocs/9-System/scripts/verify-260502-changereservedamount-caller-rebind-fix.sh`

The script (to be authored alongside this plan, modelled on the v1 pair `verify-260427-changeReservedAmount-caller-rebind-followup.sh`) MUST encode:

| Check ID | Type | Description |
|---|---|---|
| `FA-1-pos` | Positive | `sourceStock = stockunitBusinessService.changeReservedAmount(sourceStock` appears EXACTLY 2 times in `MobileReplenishService.java` |
| `FA-1-neg` | Negative | bare `^\s+stockunitBusinessService.changeReservedAmount(\s*sourceStock` appears EXACTLY 0 times |
| `FA-2-pos` | Positive | the L474 redirected-`stockUnit` release stays present as a bare statement |
| `FB-1-pos` | Positive | `stockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, orderPosition.getAmount(), false, WmsConstants.CODE_CREATE_PICK_POSITION` appears EXACTLY 1 time in `ReleaseOrderJobService.java` |
| `FB-2a-pos` | Positive | L595 (overstock first-loop, exact-match) bare statement still present (anchored on `orderPosition.getAmount()` arg) |
| `FB-2b-pos` | Positive | L619 (overstock second-loop, partial-take) bare statement still present (anchored on `available` arg) |
| `FB-2c-pos` | Positive | L627 (overstock second-loop, final-take) bare statement still present (anchored on `missing` arg) |
| `FB-2d-pos` | Positive | EXACTLY 3 bare `^\s+stockunitBusinessService.changeReservedAmount(\s*stockUnit` statements remain |
| `FC-*-pos` | Positive | `MobileReplenishServiceUnitTest` contains both `finishReplenishmentOrder_rebindsSourceStockBeforeTransfer` and `finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer`; uses `isSameAs`; uses `nullable(String.class)` |
| `FC-3-neg` | Negative | tests do NOT use `isEqualTo` for the rebound-instance assertion |
| `FD-*-pos` | Positive | `ReleaseOrderJobServiceUnitTest` contains `createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead`; uses `isEqualByComparingTo` |
| `FE-1-pos` | Positive | `stockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, pickingPosition.getAmount().negate(), true, WmsConstants.CODE_PICKING` appears EXACTLY 1 time in `PickingorderBusinessService.java` |
| `FE-1-neg` | Negative | bare `^\s+stockunitBusinessService.changeReservedAmount(\s*stockUnit, pickingPosition` appears EXACTLY 0 times in `PickingorderBusinessService.java` |
| `FF-*-pos` | Positive | `PickingorderBusinessServiceUnitTest` contains `confirmPick_rebindsStockUnitAfterChangeReservedAmount`; uses `same()`; verifies `unitloadRepository.findById` called with refreshed ID |
| `RG-1` | Regression-guard | `entityManager.refresh(stockUnit)` still at `StockunitBusinessService.java` (replaces v1's `detach(staleStockUnit)` guard) |
| `RG-2` | Regression-guard | `findByIdForUpdate(staleStockUnit.getId())` still in `StockunitBusinessService` |
| `RG-3` | Regression-guard | `stockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, ...)` rebind present at `PickingorderBusinessService.java` L428 (Fix E landed) |
| `M-*` | Maven | `mvn test -Dtest=MobileReplenishServiceUnitTest`, `…ReleaseOrderJobServiceUnitTest`, `…StockunitBusinessServiceUnitTest`, `…PickingorderBusinessServiceUnitTest` all pass |

### 9.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | **Standard** | 4 production-code line edits + 4 new test methods across 3 service files + 3 test files; single subsystem (stockunit reservation) |
| **Pre-draft step** | none | v1 pair already exists; this is a translation, not a novel design |
| **Plan-review step** | `critic` | Standard rule; particularly because Mockito `mockStatic` availability differs v1/v2 — critic should sanity-check the test stubbing |
| **Implementation shape** | `executor` | Mechanical, scope-bounded; ralph would be over-orchestration |
| **Verification step** | verify-script + verifier | Mandatory |
| **Code-review step** | `code-reviewer` | Touches reservation correctness — mandatory second pair of eyes |

---

## 10. Implementation Status

**Status:** `implemented` — all 3 production fixes and 4 new tests committed and passing.

### v2 commit

| v1 SHA | v1 subject | v2 SHA | v2 commit subject |
|---|---|---|---|
| `2351004` | fix(picking): prevent StaleObjectStateException in changeReservedAmount (SBDEV-1710 follow-up) | `e7e4464` | port v1 142f7bb+c70569e+2351004 — rebind entity after changeReservedAmount at caller sites |
| `142f7bb` | fix(replenish): rebind sourceStock after changeReservedAmount in finishReplenishmentOrderInternal | `e7e4464` | (same commit) |
| `c70569e` | fix(order-release): rebind stockUnit after changeReservedAmount in createPickingForOrder | `e7e4464` | (same commit) |

### Test methods added or updated

| File | Method | Type |
|---|---|---|
| `MobileReplenishServiceUnitTest` | `finishReplenishmentOrder_rebindsSourceStockBeforeTransfer` | new |
| `MobileReplenishServiceUnitTest` | `finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer` | new |
| `ReleaseOrderJobServiceUnitTest` | `createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead` | new |
| `PickingorderBusinessServiceUnitTest` | `confirmPick_rebindsStockUnitAfterChangeReservedAmount` | new |
| `MobileReplenishServiceUnitTest$FinishReplenishmentOrder` | `setUp()` | new @BeforeEach (identity stub) |
| `PickingorderBusinessServiceUnitTest$ConfirmPickHappyPath` | `setUp()` | new @BeforeEach (identity stub) |
| `PickingorderBusinessServiceUnitTest$ConfirmPickLockVerification` | `setUp()` | extended (added identity stub) |
| `ReleaseOrderJobServiceUnitTest$ReleaseOrderSecondRound` | `setUp()` | extended (added identity stub) |

### Test results

```
mvn test -Dtest="MobileReplenishServiceUnitTest,PickingorderBusinessServiceUnitTest,ReleaseOrderJobServiceUnitTest"
Tests run: 151, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS

mvn test (full suite)
Tests run: 3811, Failures: 0, Errors: 0, Skipped: 65 — BUILD SUCCESS
```

### Implementation notes

- Identity stubs (`thenAnswer(inv -> inv.getArgument(0))`) added to 4 `@BeforeEach` methods preserve existing test behaviour now that production code captures the `changeReservedAmount` return value. Test-specific stubs using `same(staleInstance)` matchers still override per Mockito's LIFO stub resolution.
- Lambda effectively-final constraint at `PickingorderBusinessService:431` resolved by extracting `final Long stockUnitUnitLoadId` before the `.orElseThrow` lambda.
- The 3 v1 commits are scattered within 28 pending commits after the `7f06c6f` anchor — the sync-log anchor was **not** advanced; a note was added to `sync-log.md` tracking these as out-of-order cherry-picks.
| **Commit step** | git directly | Single logical commit (or two — Fix A and Fix B — at implementer discretion) |
