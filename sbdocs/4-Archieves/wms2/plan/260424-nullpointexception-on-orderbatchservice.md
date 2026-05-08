# Debug Plan: NullPointerException on CustomerorderBatchService — v2 Migration Review

**Date:** 2026-04-01
**Priority:** High
**Source:** `docs/plan/v2-fixes/260424-nullpointexception-on-orderbatchservice.md` (original v2 plan, dated 2026-03-27)
**Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## 1. Applicability Analysis

| Original Fix | v2 Status | Applicable? |
|:-------------|:----------|:------------|
| **Fix A:** Add `@Mock CustomerorderBatchService` to unit test | **Already applied.** Line 90 of `PickingorderBusinessServiceUnitTest.java` has `@Mock private CustomerorderBatchService customerorderBatchService;` | **NO — already done** |
| **Fix B:** Rebuild and redeploy from current HEAD | Deployment concern, not a code change | **N/A — skip** |
| **Fix C:** Add `@Transactional(value = "tenantTransactionManager", ...)` to `finishPickingOrder()` and `cleanUpCancelledOrder()` | **NOT applied.** Line 136 (`finishPickingOrder`) and line 323 (`cleanUpCancelledOrder`) have no `@Transactional` annotation | **YES — needed** |

### Why Fix C is important

Per the project's CLAUDE.md dual-transaction-manager rule: **every `@Transactional` on a tenant service method MUST specify `value = "tenantTransactionManager"`**. Without explicit `@Transactional`, these methods rely entirely on the caller's transaction context. This is fragile:

1. **`finishPickingOrder()`** is called from 7+ locations in `MobilePickingService` (lines 223, 304, 356, 523, 654) and from `PickingorderBusinessService.confirmPick()` (line 560). Most callers have `@Transactional`, but if called from an admin controller or scheduled job without one, the method runs in auto-commit mode — any partial failure in `cleanUpCancelledOrder` leaves the database inconsistent (tote cleared, stock unlocked, but order not fully cancelled).

2. **`cleanUpCancelledOrder()`** modifies multiple entities in sequence: sends tote to clearing, unlocks stock units, cancels the order and positions, finalizes the batch, cancels the picking unitload. If ANY step fails without a transaction, prior steps are already committed and cannot be rolled back.

3. Since `finishPickingOrder` is called through the Spring proxy from external callers, adding `@Transactional(REQUIRED)` is safe: it joins the caller's existing transaction if one exists, or creates a new one if not. No behavior change for the current call paths, but adds a safety net.

4. `cleanUpCancelledOrder` is a `public` method called from within `finishPickingOrder` (line 216) — this is a self-invocation, so the `@Transactional` on `cleanUpCancelledOrder` would NOT trigger via proxy. However, it documents the intent and protects against future external callers. The real transactional safety comes from the annotation on `finishPickingOrder`.

### Test coverage status

- `@Mock CustomerorderBatchService` — already present (line 90)
- `cleanUpCancelledOrder` tests exist at lines 314 and 1156 with good coverage (verifies `finalizeBatchIfComplete`, tote cleanup, stock unlock)
- `cleanUpCancelledOrder` with non-null `orderbatchId` — covered at line 1209 (verifies `finalizeBatchIfComplete` is called)
- No additional tests needed for Fix C — adding `@Transactional` doesn't change behavior under the existing test framework (unit tests bypass Spring proxy)

---

## 2. Implementation Plan

### Fix C: Add `@Transactional` to `finishPickingOrder()` and `cleanUpCancelledOrder()`

**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`

#### Change 1: `finishPickingOrder()` at line 136

```java
// BEFORE (line 136):
    public Pickingorder finishPickingOrder(Pickingorder pickingOrder) throws FacadeException, BusinessException {

// AFTER:
    @Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
    public Pickingorder finishPickingOrder(Pickingorder pickingOrder) throws FacadeException, BusinessException {
```

#### Change 2: `cleanUpCancelledOrder()` at line 323

```java
// BEFORE (line 323):
    public void cleanUpCancelledOrder(Customerorder customerOrder) throws FacadeException, BusinessException {

// AFTER:
    @Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
    public void cleanUpCancelledOrder(Customerorder customerOrder) throws FacadeException, BusinessException {
```

---

## 3. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| Adding `@Transactional(REQUIRED)` to methods called from within existing transactions | No behavior change — `REQUIRED` joins the caller's transaction | This is the default propagation; all current callers already have active transactions |
| `cleanUpCancelledOrder` annotation won't trigger on self-invocation from `finishPickingOrder` | The annotation is a no-op in the current call path | Documents intent; protects future external callers. Real safety comes from `finishPickingOrder`'s annotation. |
| If `finishPickingOrder` is called from a non-tenant context (e.g., landlord service) | Would create a new tenant transaction — could fail if no tenant context is set | All current callers set tenant context before calling. This is a theoretical edge case. |

---

## 4. Task Checklist

- [x] ~~**Fix A (Critical):** Add `@Mock CustomerorderBatchService` to test~~ — Already done in v2
- [x] ~~**Fix B (Critical):** Rebuild and redeploy~~ — Deployment concern, not code
- [x] **Fix C-1 (High):** Add `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` to `finishPickingOrder()` at line 136 ✓ Implemented 2026-04-01
- [x] **Fix C-2 (High):** Add `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` to `cleanUpCancelledOrder()` at line 323 ✓ Implemented 2026-04-01
- [x] Run affected test suite and verify 0 new failures ✓ 40 tests in PickingorderBusinessServiceUnitTest pass with 0 failures.
- [ ] Verify in staging

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | Add `@Transactional` to `finishPickingOrder()` (line 136) and `cleanUpCancelledOrder()` (line 323) |
