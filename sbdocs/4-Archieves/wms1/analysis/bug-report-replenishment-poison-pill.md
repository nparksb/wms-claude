# BUG: Single Failing FLA Aborts Refill Loop (and Can Leave Partial Writes)

## Summary

`refillFixedLocations()` processes all fix location assignments (FLAs) that need replenishment in a single transaction with no error handling inside the loop. If **any one** FLA fails — for example because its item has no qualifying source stock — the thrown `FacadeException` aborts the loop. Because `FacadeException` is a **checked** exception and is caught by the caller, Spring will **not** mark the transaction rollback-only by default. Result: earlier FLAs can still commit, but **all later FLAs are skipped** for that cycle.

Separately, if a failure happens **after** a replenish order is saved (e.g., during stock reservation), that checked exception can be caught and still allow the transaction to commit, potentially leaving a **replenish order without reserved stock**.

## Observed Symptom

SKU **DV21CMPN** has 35 units on location **05-A13** with a lower bound of 36. All conditions for replenishment are met:

- Stock (35) is below lower bound (36) → eligible for refill
- No active replenishment orders blocking creation
- 3 pallets of 12 units each available on replenishable locations (TC-OS), all unreserved and unlocked
- Cancel threshold is 0.0, shortage is 49 → order should not be cancelled

Yet no replenishment order exists. Orders may be created and then cancelled/recalculated later in the same job cycle, or the refill loop may abort before this FLA is processed.

## Root Cause

### Bug 1: No error isolation in the refill loop (primary)

**File:** `ReplenishGeneratorService.java`, lines 48–65

```java
public void refillFixedLocations() throws FacadeException {
    List<FixLocationAssignment> assList =
        fixLocationAssignmentRepository.getRefillFixedLocations(WmsConstants.State.FINISHED);

    for (FixLocationAssignment ass : assList) {                    // ← no try-catch
        Unitload unitLoad = unitloadRepository.findById(ass.getAssignedunitloadId()).get();
        List<Stockunit> stockunitList = stockunitRepository.findByUnitloadId(unitLoad.getId());
        BigDecimal required = ass.getUpperbound().subtract(stockunitList.get(0).getAmount());
        calculateOrder(ass.getItemdataId(), required, ass.getAssignedlocationId());  // ← throws
    }
}
```

`calculateOrder()` throws `FacadeException` when no source stock passes its filters (line 99):

```java
throw new FacadeException("No replenish stock available with destination = " + ...);
```

This exception propagates out of the loop unhandled. The caller, `triggerRegularReplenishment()`, catches it:

**File:** `ReplenishOrderJobService.java`, lines 186–199

```java
@Transactional(propagation = Propagation.REQUIRES_NEW)
public void triggerRegularReplenishment() {
    try {
        replenishGeneratorService.refillFixedLocations();
    } catch (FacadeException e) {
        LOG.warn("creating replenishment orders failed: " + e.getLocalizedMessage());
    }
}
```

Because `FacadeException` is **checked**, Spring will not automatically mark the transaction rollback-only. The effect is that the **loop stops immediately**, and **remaining FLAs are skipped**, but earlier orders may still commit.

### Bug 1b: Partial-write risk if reservation fails (secondary but important)

`calculateOrder()` saves a `replenishorder` and then reserves stock. If reservation fails (`changeReservedAmount` throws `FacadeException`), the exception is caught at the outer level and the transaction can still commit, leaving an order without the corresponding reservation.

### Bug 2: Eligibility query is weaker than source query (secondary)

The `getRefillFixedLocations` SQL query includes an `EXISTS` clause to verify source stock, but its checks are **less strict** than what `calculateOrder()` actually requires:

| Check                          | `getRefillFixedLocations` EXISTS | `calculateOrder` source query |
|--------------------------------|:--------------------------------:|:-----------------------------:|
| `su.entity_lock = 0`          | ✅                                | ✅                             |
| `su.amount > 0`               | ✅                                | ✅                             |
| `su.reservedamount = 0`       | ❌ **missing**                    | ✅                             |
| `unitload.entity_lock = 0`    | ❌ **missing**                    | ✅                             |
| `location.entity_lock = 0`    | ❌ **missing**                    | ✅                             |
| `area.entity_lock = 0`        | ❌ **missing**                    | ✅                             |

This means an FLA can pass the eligibility query (source stock "exists"), enter the loop, and then **fail inside `calculateOrder()`** because all stock units have non-zero `reservedamount` or locked unitloads/locations/areas. This widens the blast radius of Bug 1 — even items that appear to have source stock can become poison pills.

## Why This Is a Problem

1. **Silent partial failure:** A single out-of-stock item stops the refill loop early. Later FLAs are skipped for that cycle, and the only sign is a WARN-level log message.
2. **Self-perpetuating:** On every job cycle, the same poison-pill FLA fails early, repeatedly preventing later FLAs from being processed.
3. **Potential data inconsistency:** If reservation fails after an order is saved, a checked exception can still allow the transaction to commit, leaving an order without reserved stock.
4. **Inconsistent with other steps:** Other steps in the same job (e.g., `generateReplenishmentForItemDataWithFixedAssignmentWithOrders` at line 286, `deleteEmptyFixAssignmentWithoutStockToReplenish` at line 218) already wrap each iteration in a try-catch. This step is the exception.

## Execution Flow

```
ReplenishOrderJob.doCalculation()
  └─ triggerRegularReplenishment()                    ← @Transactional(REQUIRES_NEW)
       └─ refillFixedLocations()
            ├─ FLA #1 (item X) → calculateOrder() → ✅ order created
            ├─ FLA #2 (item Y) → calculateOrder() → ✅ order created
            ├─ FLA #3 (item Z) → calculateOrder() → 💥 FacadeException (no source)
            │                                           ↓
            │                                    exception propagates up
            │                                           ↓
            └─ catch (FacadeException e)  →  LOG.warn(...)
                                              ↓
                               loop aborted; later FLAs skipped
                                              ↓
                         ✅ earlier orders may still commit
```

## Implemented Fix (applied)

Three changes were implemented: (1) isolate errors per FLA so one failure doesn’t stop the loop, (2) ensure each FLA in the job path is processed in its **own transaction** that rolls back on `FacadeException`, preventing partial writes, (3) tighten the eligibility query so items without truly available source stock never enter the loop, and (4) defensive try-catch in the mobile path callers.

---

### Fix 1 — Per-FLA transaction isolation in job path (Bug 1 + Bug 1b)

**Files changed:**
- `ReplenishOrderJobService.java` — Removed `triggerRegularReplenishment()`. Added `getRefillFixedLocationIds()` (delegates to new ID-only repository query) and `refillFixedLocationAssignment(long)` with `@Transactional(REQUIRES_NEW, rollbackFor = FacadeException.class)`. The `rollbackFor` ensures if `calculateOrder()` saves an order but `changeReservedAmount()` throws, the entire transaction rolls back (fixes Bug 1b).
- `ReplenishOrderJob.java` — Refactored `triggerRegularReplenishment()` to query IDs then loop with per-FLA try-catch, matching the existing pattern used by `deleteEmptyFixAssignmentWithoutStockToReplenish()`, `generateReplenishmentForItemDataWithoutFixedAssignment()`, etc.
- `ReplenishGeneratorService.java` — Added try-catch inside the `refillFixedLocations()` loop so the mobile path (which still calls this method) also gets error isolation.

**Design decisions:**
- The per-FLA `@Transactional(REQUIRES_NEW)` method lives in `ReplenishOrderJobService` (not `ReplenishGeneratorService`), following the existing pattern where all per-item transactional methods are in the job service class.
- The query + loop orchestration lives in `ReplenishOrderJob.triggerRegularReplenishment()` (not in the job service), matching how all other steps orchestrate.
- A new `getRefillFixedLocationIds()` ID-only query was added (returning `List<Long>`) to match the pattern of other job steps.

### Fix 2 — Defensive try-catch in mobile callers (Bug 1)

**File changed:** `MobileReplenishService.java`
- `finishReplenishmentOrderInternal()` (line 448–450): wrapped `refillFixedLocations()` in try-catch
- `fulfillMultipleUnitLoads()` (line 736): wrapped `refillFixedLocations()` in try-catch — without this, a refill failure would prevent `return result`, causing the entire multi-unitload operation to fail for the mobile user

### Fix 3 — Tighten the eligibility EXISTS clause (Bug 2)

**File changed:** `FixLocationAssignmentRepository.java`

Added 4 missing conditions to **both** the existing `getRefillFixedLocations()` query and the new `getRefillFixedLocationIds()` query: `su.reservedamount = 0`, `ul.entity_lock = 0`, `lo.entity_lock = 0`, `area.entity_lock = 0`. This matches the filters used by `calculateOrder()`’s source stock query.

### Tests updated

- `ReplenishOrderJobServiceUnitTest.java` — Replaced 2 old `triggerRegularReplenishment` tests with 4 new tests for `getRefillFixedLocationIds` and `refillFixedLocationAssignment` (success, empty stockunits, exception propagation).
- `MobileReplenishServiceUnitTest.java` — Added `finishReplenishmentOrder_refillFails_doesNotThrow` test.
- All 1,537 tests pass.

## Diagnostic SQL Query

Run the following query to identify all poison-pill FLAs currently in the refill batch. Any row marked `*** POISON PILL ***` is an FLA that will fail early and skip later FLAs:

```sql
-- POISON PILL FINDER
-- Shows all FLAs that getRefillFixedLocations() would return,
-- and whether each one has source stock that passes calculateOrder()'s stricter filters.
-- Any row with '*** POISON PILL ***' will fail early and skip later FLAs.
SELECT fla.id AS fla_id,
       i.item_nr,
       i.name AS item_name,
       l.name AS location,
       su.amount AS stock_on_location,
       fla.lowerbound,
       fla.upperbound,
       (SELECT COUNT(*)
          FROM stockunit src
          JOIN unitload src_ul ON src.unitload_id = src_ul.id
          JOIN location src_loc ON src_ul.storagelocation_id = src_loc.id
          JOIN location_area src_area ON src_loc.area_id = src_area.id
         WHERE src.itemdata_id = i.id
           AND src.amount > 0
           AND src.reservedamount = 0
           AND src.entity_lock = 0
           AND src_ul.entity_lock = 0
           AND src_loc.entity_lock = 0
           AND src_area.entity_lock = 0
           AND src_area.useforreplenish = true
       ) AS available_source_count,
       CASE
           WHEN (SELECT COUNT(*)
                   FROM stockunit src
                   JOIN unitload src_ul ON src.unitload_id = src_ul.id
                   JOIN location src_loc ON src_ul.storagelocation_id = src_loc.id
                   JOIN location_area src_area ON src_loc.area_id = src_area.id
                  WHERE src.itemdata_id = i.id
                    AND src.amount > 0
                    AND src.reservedamount = 0
                    AND src.entity_lock = 0
                    AND src_ul.entity_lock = 0
                    AND src_loc.entity_lock = 0
                    AND src_area.entity_lock = 0
                    AND src_area.useforreplenish = true
                ) = 0
           THEN '*** POISON PILL *** No source stock → skips later FLAs'
           ELSE 'OK - has source stock'
       END AS diagnosis
  FROM fix_location_assignment fla
  JOIN unitload ON fla.assignedunitload_id = unitload.id
  JOIN itemdata i ON fla.itemdata_id = i.id
  JOIN stockunit su ON su.itemdata_id = i.id AND su.unitload_id = unitload.id
  JOIN location l ON fla.assignedlocation_id = l.id
 WHERE su.amount < fla.lowerbound
   AND fla.active = true
   AND NOT EXISTS (
       SELECT 1 FROM replenishorder ro
        WHERE ro.state < 600
          AND (ro.requestedlocation_id = fla.assignedlocation_id
               OR ro.itemdata_id = fla.itemdata_id)
   )
 ORDER BY available_source_count ASC, i.item_nr;
```

**How to read the results:**

- Rows with `available_source_count = 0` and `*** POISON PILL ***` are FLAs that will throw `FacadeException` inside the loop and **skip later FLAs** for that cycle.
- The query mimics the exact conditions: `getRefillFixedLocations` eligibility (amount < lowerbound, active, no blocking orders) crossed with `calculateOrder`'s stricter source stock requirements (reservedamount = 0, all entity locks = 0, useforreplenish = true).
- Fix the poison pills (restock them, deactivate the FLA, or unlock their source stock) and replenishment will resume for all items.
