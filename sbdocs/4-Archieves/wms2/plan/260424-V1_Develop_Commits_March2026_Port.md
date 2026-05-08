# V1 Develop Branch Commits (March 2026) — Port to V2

- **Date:** 2026-03-21
- **Status:** Implemented — 9 of 10 commits already in v2. 1 gap (GAP-1) fixed. All 160 affected tests pass.
- **Priority:** Low (most work already done)
- **V1 Source:** `../wms-api` develop branch, commits after 2026-03-01

---

## Summary

10 commits were made to v1's develop branch after March 1st, 2026. Deep analysis against the v2 codebase reveals:

- **9 commits already ported** — Code exists in v2 (some with v2-specific improvements)
- **1 gap found** — Synchronous OMS callback in `rapidPickingConnectPackageAndType` needs afterCommit deferral

---

## Commit-by-Commit Analysis

### Already in V2 (No Action Needed)

| # | Commit | Description | V2 Status |
|---|--------|-------------|-----------|
| 1 | `7ac04aa` | Fix `getBoxTypeNameFromUnitLoad` null check | Already in v2 at `StockunitService.java:554-561` — identical pattern |
| 2 | `d8e1600` | Remove REQUIRES_NEW from `recalculateForItem` | Already in v2 at `ReplenishmentOrderMaintenanceService.java:96` — uses `tenantTransactionManager` (better) |
| 3 | `08f8ae7` | SQL-level filtering + remove duplicate `triggerReplenishmentMaintenance` | Already in v2 — `findByStateAndItemdataId` at `ReplenishorderRepository.java:46`, 4 non-duplicate call sites |
| 4 | `3e3c825` | Re-read detached entities in `processPick` | Already in v2 at `MobilePickingService.java:384-391,500-505` — v2 uses `findByIdForUpdate` (stronger) |
| 5 | `a6c283e` | Compare by ID in `OrderRestController` | Already in v2 at `OrderRestController.java:835` |
| 6 | `cfd9269` | Missing save in `AdviceService.close()` | Already in v2 at `AdviceService.java:308-309` — v2 uses `saveAndFlush` (stronger) |
| 7 | `a377010` | Missing save in `MobileReplenishService.resetOrder()` | Already in v2 at `MobileReplenishService.java:261-263` |
| 8 | `423bced` | Defer OMS `pickingStarted` and `toteAssigned` callbacks to afterCommit | Already in v2 — `PickingorderBusinessService.java:482-495` and `MobilePickingService.java:476-496` |
| 9 | `f3a08d1` | Defer OMS `customerOrderPicked` to afterCommit | Already in v2 at `PickingorderBusinessService.java:252-271` |
| 10 | `5d8326b` | ViewDtoServiceUnitTest fix | Test-only — v2 test file exists, passes |

### Gap Found (Needs Fix)

| # | Source Commits | File:Line | Issue | Priority |
|---|---------------|-----------|-------|----------|
| GAP-1 | `423bced` | `MobilePickingService.java:986` | `customerOrderToteAssigned` called synchronously in `rapidPickingConnectPackageAndType` — all 3 other OMS callbacks are deferred to afterCommit | Medium |

---

## GAP-1: Defer `customerOrderToteAssigned` in rapidPickingConnectPackageAndType

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`
**Line:** 986

**Current code (synchronous):**
```java
manageOrderService.customerOrderToteAssigned(Collections.singletonList(customerOrder));
```

**Fix:** Wrap in afterCommit deferral matching the pattern at lines 476-496:
```java
if (TransactionSynchronizationManager.isSynchronizationActive()) {
    final Customerorder toteAssignedOrder = customerOrder;
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
        @Override
        public void afterCommit() {
            try {
                manageOrderService.customerOrderToteAssigned(Collections.singletonList(toteAssignedOrder));
            } catch (Exception e) {
                LOG.error("OMS tote assigned callback failed for order {}", toteAssignedOrder.getNumber(), e);
            }
        }
    });
} else {
    manageOrderService.customerOrderToteAssigned(Collections.singletonList(customerOrder));
}
```

**V2-specific note:** Uses `TransactionSynchronization` interface directly (not `TransactionSynchronizationAdapter` which was removed in Spring 6/Jakarta). This matches the pattern already used in v2 at lines 476-496.

---

## Testing

- ViewDtoServiceUnitTest: Verify passes
- MobilePickingServiceUnitTest: Verify rapidPicking tests still pass after GAP-1 fix
- Full suite: Run and verify no regressions

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| GAP-1 fix breaks rapid picking flow | Low | Medium | Same pattern used successfully in 3 other locations |
| Deferred callback fires after request completes | Low | Low | Fallback to synchronous when no TX active |
