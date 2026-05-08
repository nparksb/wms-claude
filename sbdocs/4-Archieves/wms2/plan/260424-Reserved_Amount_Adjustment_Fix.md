# V2 Migration Plan — Reserved Amount Adjustment Fix

- **Date:** 2026-03-26
- **Status:** IMPLEMENTED — 2 code fixes applied, 1 new test added. All 65 StockunitServiceUnitTest tests pass.
- **Priority:** Medium
- **V1 Source Plan:** `docs/plan/v1-fixes/260424-Reserved_Amount_Adjustment_Fix.md`
- **V1 Branch:** `release` (wms-api)
- **V2 Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## Summary

The V1 plan fixed a bug where manually adjusting a stock unit's reserved amount via the admin UI would appear to succeed, but the reservation would immediately reappear on refresh. The root cause was `triggerReplenishmentMaintenance()` being called after `adjustReservedAmount()`, which re-reserved the stock the user just released.

**V2 Analysis Result:** The same bug **exists in V2** at `StockunitService.java:453`. The fix has been applied.

---

## V1 Fix Applicability Analysis

| V1 Item | V1 Status | V2 Status | Action |
|---------|-----------|-----------|--------|
| Remove `triggerReplenishmentMaintenance()` from `adjustReservedAmount()` | DONE | **Was present → FIXED** | Removed trigger, added explanatory comment |
| Missing `@Transactional` on `adjustReservedAmount()` (additional finding) | Noted but not fixed | **Was missing → FIXED** | Added `@Transactional(value = "tenantTransactionManager", ...)` |
| Test: verify no replenishment trigger | DONE | **Was missing → ADDED** | New test added |

---

## Changes by File

### 1. `StockunitService.java` — Remove Replenishment Trigger (Primary Fix)

**V2 path:** `src/main/java/net/aim_ai/wms/service/StockunitService.java`

| # | Fix | Line | Status | Description |
|---|-----|------|--------|-------------|
| **FIX-1** | Remove `triggerReplenishmentMaintenance()` | 453 | **DONE** | Removed call, added explanatory comment |
| **FIX-2** | Add `@Transactional` | 433 | **DONE** | Added `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})` |

#### FIX-1: Remove Replenishment Trigger

**Before (line 453):**
```java
Stockunit newStockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, amount, true, WmsConstants.CODE_MANUAL_ADJUSTMENT, null, comment);

triggerReplenishmentMaintenance(stockUnit.getItemdataId());
```

**After:**
```java
Stockunit newStockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, amount, true, WmsConstants.CODE_MANUAL_ADJUSTMENT, null, comment);

// Note: intentionally NOT triggering replenishment maintenance here.
// Manual reservation adjustment is a deliberate user action; re-triggering
// replenishment would immediately re-reserve the stock the user just released.
// The scheduled ReplenishOrderJob will naturally re-evaluate on its next cycle.
```

**Why:** `triggerReplenishmentMaintenance()` calls `ReplenishmentOrderMaintenanceService.recalculateForItem()`, which finds open replenishment orders for the item and re-reserves stock that was just manually cleared. The scheduled `ReplenishOrderJob` provides a natural backstop — replenishment will be recalculated on the next cron cycle, giving the user a window to complete their intended operation (e.g., marking stock as damaged).

**Other methods that correctly keep the trigger:**
- `transferStock()` — stock moved between locations
- `setLockOnHold()` / `setLockDamaged()` — stock locked, unavailable
- `adjustAmount()` — stock quantity changed
- `removeLock()` — stock unlocked, available again

These all change stock *availability*, making the trigger appropriate.

#### FIX-2: Add @Transactional

**Before:**
```java
public Stockunit adjustReservedAmount(Stockunit stockUnit, BigDecimal reservedAmount, String comment) throws FacadeException, BusinessException {
```

**After:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public Stockunit adjustReservedAmount(Stockunit stockUnit, BigDecimal reservedAmount, String comment) throws FacadeException, BusinessException {
```

**Why:** Without `@Transactional`, the picking-position check (line 443-447) and the `changeReservedAmount()` call run in separate transaction scopes. This is a TOCTOU gap — another thread could start picking between the check and the reservation change. Adding `@Transactional` wraps the entire check-then-act sequence in a single transaction.

---

## Testing

### New Test Added

**File:** `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceUnitTest.java`

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `adjustReservedAmount_doesNotTriggerReplenishmentMaintenance` | Clears reservation from 20 to 0, verifies `recalculateForItem()` is NEVER called |

### Existing Tests

- `StockunitServiceUnitTest`: 65 tests — all pass (no regressions)

---

## Additional Recommendations

### 1. Reserved Amount Recalculation Job

Currently, there is no background job that recalculates reserved amounts from picking position states. If reserved amounts drift due to bugs or crashes, they stay incorrect until manually adjusted. Consider creating a scheduled job that:
1. Iterates all stock units with non-zero reserved amounts
2. Sums picking position amounts where `pickfromstockunitId = stockUnit.id` and state is in `[RESERVED, STARTED, PICKED)` range
3. Adjusts reserved amounts to match the calculated sum

### 2. Audit Other `triggerReplenishmentMaintenance()` Callers

The trigger is called from 4 locations in `StockunitService`:
- Line 251: `transferStock()` — appropriate (stock availability changes)
- Line 387: `setLockOnHold()` / `setLockDamaged()` — appropriate
- Line 427: `adjustAmount()` — appropriate
- ~~Line 453: `adjustReservedAmount()`~~ — **removed** (this fix)

All remaining callers are appropriate — they change stock availability, not user-managed reservations.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Replenishment not recalculated after manual adjustment | Low | Low | Scheduled `ReplenishOrderJob` runs on cron and recalculates naturally |
| @Transactional creates nested transaction | Low | Low | Default propagation is REQUIRED — joins caller's transaction if one exists |
| User clears reservation but replenishment still needed | Low | Medium | Scheduled job will re-reserve on next cycle; user gets a window to act |

---

## Implementation Status

| # | Fix | File | Status |
|---|-----|------|--------|
| FIX-1 | Remove replenishment trigger | `StockunitService.java:453` | **DONE** |
| FIX-2 | Add @Transactional | `StockunitService.java:433` | **DONE** |
| TEST-1 | Verify no trigger on adjustment | `StockunitServiceUnitTest.java` | **DONE** |
