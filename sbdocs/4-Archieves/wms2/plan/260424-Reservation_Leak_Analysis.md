# Reservation Leak Analysis: Two Active Bugs in WMS

**Date:** 2026-03-06
**Status:** Analysis Complete — Fix Implementation Pending
**Priority:** High
**Affects:** v1 (all versions) and v2 (feature/multi-clients-j21)
**Discovered during:** WineCo orphaned reservation forensic analysis (SBDEV-1710)

---

## Executive Summary

Following the v1.26.19 deployment that added explicit `.save()` calls to fix orphaned reservations
under `OSIV=false`, we performed a forensic analysis of WineCo's production database. While the
`.save()` fixes resolved the **primary** leak in the standard picking flow (zero new orphans
post-deploy), we identified **two additional code paths** that can still create orphaned reservations.
Both bugs exist identically in v1 and v2.

| Bug | Method | Severity | Mechanism |
|-----|--------|----------|-----------|
| **#1** | `fixPickingPosition()` | **Critical** | Reserves replacement unit but never unreserves original — guaranteed orphan on every call |
| **#2** | `checkAndCleanUpPickingOrderPositions()` | **High** | Bypasses `changeReservedAmount()` — no audit trail, no row lock, physical deletion of positions |

---

## Bug #1: `fixPickingPosition()` — Guaranteed Orphan Generator

### Location

- **v1:** `PickingorderPositionService.java` line 73–128
- **v2:** `PickingorderPositionService.java` line 81–138

### Callers

| Caller | Location | Trigger |
|--------|----------|---------|
| `PickingOrderPositionController.fixPickingPosition()` | Web UI button: "Fix Picking Position" | User clicks fix on a position with stale location data |
| `MobilePickingService` (line 358 in v1, 383 in v2) | Mobile handheld scan flow | Auto-triggered when `getPickingorderPositionsById()` detects a position with mismatched location/unitload data |

### What `getPickingorderPositionsById` detects

The query (line 54–63 of `PickingorderPositionRepository.java`) finds positions where:
- The `pickfromunitloadlabel` or `pickfromlocationname` on the position no longer matches the actual current label/location of the unitload
- OR the stock unit is no longer on the unitload that was originally recorded

This happens when stock is moved (replenishment, manual moves) after a picking position is created but before it's picked.

### The Bug — Step by Step

```
BEFORE fixPickingPosition():
  ┌─────────────────────────────┐
  │ StockUnit A (original)      │
  │   amount: 10                │
  │   reservedamount: 3  ◄──────┼── Reserved by this position
  └─────────────────────────────┘
  ┌─────────────────────────────┐
  │ PickingOrderPosition #123   │
  │   pickfromstockunit_id: A   │
  │   amount: 3                 │
  └─────────────────────────────┘

DURING fixPickingPosition():
  Step 1: Find replacement StockUnit B with enough available stock  ✓
  Step 2: changeReservedAmount(B, +3)  — reserves on B              ✓
  Step 3: position.setPickfromstockunitId(B.id)  — points to B      ✓
  Step 4: pickingorderPositionRepository.save(position)              ✓
  ❌ MISSING: changeReservedAmount(A, -3)  — unreserve from A

AFTER fixPickingPosition():
  ┌─────────────────────────────┐
  │ StockUnit A (original)      │
  │   amount: 10                │
  │   reservedamount: 3  ◄──────┼── ORPHANED! Nothing points here anymore
  └─────────────────────────────┘
  ┌─────────────────────────────┐
  │ StockUnit B (replacement)   │
  │   amount: 20                │
  │   reservedamount: 3  ◄──────┼── Now reserved by the position
  └─────────────────────────────┘
  ┌─────────────────────────────┐
  │ PickingOrderPosition #123   │
  │   pickfromstockunit_id: B   │  ← Moved from A to B
  │   amount: 3                 │
  └─────────────────────────────┘
```

**Result:** StockUnit A permanently holds 3 units of phantom reservation. Users will see "Reserved stock!" errors when trying to pick from it.

### Current Code (v1, lines 118–124)

```java
// Line 118-120: Reserves on replacement — correct
Unitload unitLoad = unitloadRepository.findById(replacement.getUnitloadId()).get();
Location location = locationRepository.findById(unitLoad.getStoragelocationId()).get();
stockunitBusinessService.changeReservedAmount(replacement, pickingOrderPosition.getAmount(),
    false, CODE_CREATE_PICK_POSITION, pickingOrderPosition.getNumber(), "fix picking position");

// Line 121-124: Updates position to point to replacement — correct
pickingOrderPosition.setPickfromstockunitId(replacement.getId());
pickingOrderPosition.setPickfromunitloadlabel(unitLoad.getLabelid());
pickingOrderPosition.setPickfromlocationname(location.getName());
pickingOrderPosition = pickingorderPositionRepository.save(pickingOrderPosition);

// ❌ MISSING: Unreserve original stock unit
```

### Proposed Fix

Add an unreserve call for the original stock unit **before** reserving the replacement.
Insert before the `changeReservedAmount(replacement, ...)` call:

```java
// Unreserve the original stock unit before switching to replacement
Stockunit originalStockUnit = stockunitRepository.findById(
    pickingOrderPosition.getPickfromstockunitId()
).orElseThrow(() -> new BusinessException(
    "Original stock unit not found: " + pickingOrderPosition.getPickfromstockunitId()
));
stockunitBusinessService.changeReservedAmount(
    originalStockUnit,
    pickingOrderPosition.getAmount().negate(),  // negative = unreserve
    true,   // zeroIfNegative: true — safety net if reservation is already partially consumed
    "FIX_PICK_POSITION",
    pickingOrderPosition.getNumber(),
    "unreserve original stock unit before fix"
);
```

**Why `zeroIfNegative = true`:** If the original stock unit's reservation was already partially
consumed (e.g., by a concurrent pick), we don't want the unreserve to throw an exception. Setting
this flag allows it to clamp to zero gracefully.

**Why use `changeReservedAmount()` instead of `setReservedamount()`:** `changeReservedAmount()`
provides three critical guarantees:
1. **Row-level lock** via `findByIdForUpdate()` — prevents concurrent race conditions
2. **Audit trail** via `stockrecordService.recordChangeReservedAmount()` — creates a traceable record
3. **Boundary checks** — validates the new value doesn't exceed stock or go negative

### New Activity Code Required

Add `CODE_FIX_PICK_POSITION` to `WmsConstants.java` (alongside existing codes like
`CODE_CREATE_PICK_POSITION` at line 816):

```java
public static final String CODE_FIX_PICK_POSITION = "FIX_PICK_POSITION";
```

This allows filtering `stockrecord` audit entries specifically for fix operations.

---

## Bug #2: `checkAndCleanUpPickingOrderPositions()` — Three Issues

### Location

- **v1:** `CustomerorderService.java` line 214–234
- **v2:** `CustomerorderService.java` line 239–259

### When It's Called

Called from `setPickingDate()` when a user changes an order's picking date and the order already
has picking positions created (state between `RAW` and `RESERVED`). Two scenarios:

1. **Date changed to today** → Cleans up existing positions, resets order to `RAW` (will be re-released)
2. **Date changed to future** → Cleans up existing positions, sets order to `FUTURE_PICKING_DATE`

The caller chain: `CustomerOrderController.setPickingDate()` → `CustomerorderService.setPickingDate()`
→ `checkAndCleanUpPickingOrderPositions()` (private method, called at lines 199 and 204 in v1).

This is also called from `batchUpdatePickingDate()` (line 164), which processes multiple orders —
amplifying any bugs across the batch.

### Current Code (v1, lines 222–231)

```java
// picking order positions are already created for this order, remove them and adjust reserved amount
for (PickingorderPosition position : poPositions) {
    // adjust reserved amount
    Stockunit stockUnit = stockunitRepository.findById(position.getPickfromstockunitId()).get();
    stockUnit.setReservedamount(stockUnit.getReservedamount().subtract(position.getAmount()));
    stockunitRepository.save(stockUnit);
    // delete the existing picking order position
    pickingorderPositionRepository.delete(position);
}
```

### Issue 2a: No Audit Trail

**Problem:** Uses `setReservedamount()` directly instead of `changeReservedAmount()`.

The standard reservation API (`StockunitBusinessService.changeReservedAmount()`, line 312) creates a
`stockrecord` entry via `stockrecordService.recordChangeReservedAmount()` for every reservation change.
This method bypasses that entirely — the reservation decrement is invisible in the audit trail.

**Impact:** When investigating orphaned reservations, there's no `stockrecord` entry to explain when
or why the reservation was removed. This makes forensic analysis extremely difficult.

### Issue 2b: No Row-Level Lock (Race Condition)

**Problem:** Uses `findById()` instead of `findByIdForUpdate()`.

The standard API (`changeReservedAmount()`, line 314) acquires a `SELECT ... FOR UPDATE` row lock
before reading the current `reservedamount`. This prevents the classic read-modify-write race:

```
Thread 1: reads reservedamount = 10
Thread 2: reads reservedamount = 10  (same stale value!)
Thread 1: writes reservedamount = 10 - 3 = 7
Thread 2: writes reservedamount = 10 - 5 = 5  ← Thread 1's decrement is LOST
```

Without the row lock, if two concurrent requests modify the same stock unit's reservation
(e.g., batch picking date update + normal picking), one update can overwrite the other, leaving
the reservation permanently incorrect.

**JPA optimistic locking (`@Version`)** would normally catch this, but only if both threads are in
the same JPA transaction. If the version check passes (e.g., they started from different snapshots),
the last writer wins silently.

### Issue 2c: Physical Deletion of Picking Positions

**Problem:** `pickingorderPositionRepository.delete(position)` permanently removes the row.

**Impact:** If the transaction partially fails — for example, the `stockunitRepository.save()` on
the third position succeeds but the fourth fails and rolls back — the positions are gone. But more
importantly, the physical deletion destroys the audit trail:
- The `pickingorder_position` table is the primary evidence linking a reservation to its purpose
- Without the position record, there's no way to determine why a stock unit has a reservation
- This is exactly what makes orphaned reservations hard to diagnose

### Proposed Fix

Replace the manual `setReservedamount` + `save` + `delete` with proper service calls:

```java
private void checkAndCleanUpPickingOrderPositions(Customerorder customerorder)
        throws BusinessException {
    List<PickingorderPosition> poPositions = pickingorderPositionRepository
        .getPickingorderPositionsByParcelexternalnumber(
            customerorder.getParcelexternalnumber());

    if (poPositions.size() > 0) {
        List<PickingorderPosition> poPositionsMerged = pickingorderPositionRepository
            .findByPickingorderId(poPositions.get(0).getPickingorderId());
        boolean hasPickingStarted = poPositionsMerged.stream()
            .anyMatch(p -> p.getState() >= WmsConstants.State.STARTED);

        if (!poPositions.isEmpty() && hasPickingStarted) {
            throw new BusinessException(
                "Cannot set picking date - picking has already started");
        } else {
            for (PickingorderPosition position : poPositions) {
                // Use changeReservedAmount for audit trail + row locking
                Stockunit stockUnit = stockunitRepository.findById(
                    position.getPickfromstockunitId()).get();
                try {
                    stockunitBusinessService.changeReservedAmount(
                        stockUnit,
                        position.getAmount().negate(),
                        true,  // zeroIfNegative — safety net
                        CODE_CLEANUP_PICKING_POSITION,
                        position.getNumber(),
                        "picking date changed - cleanup"
                    );
                } catch (FacadeException e) {
                    throw new BusinessException(
                        "Failed to release reservation: " + e.getMessage());
                }
                pickingorderPositionRepository.delete(position);
            }
        }
    }
}
```

**Key changes:**
1. `setReservedamount()` → `changeReservedAmount()` — adds audit trail + row lock
2. `zeroIfNegative = true` — prevents exceptions if reservation is already partially consumed
3. Activity code `CLEANUP_PICKING_POSITION` — new code for traceability
4. `FacadeException` from `changeReservedAmount` is caught and wrapped in `BusinessException`

**New dependency required** in `CustomerorderService`:
```java
@Autowired
private StockunitBusinessService stockunitBusinessService;
```

**New activity code** in `WmsConstants.java`:
```java
public static final String CODE_CLEANUP_PICKING_POSITION = "CLEANUP_PICKING_POSITION";
```

---

## Bonus: Spring Data REST Exposure of `PickingorderPositionRepository`

### The Problem

`PickingorderPositionRepository` is annotated with:
```java
@RepositoryRestResource(collectionResourceRel = "pickingorderPosition", path = "pickingorderPosition")
```

This means Spring Data REST auto-exposes CRUD endpoints including **DELETE** at:
```
DELETE /v3/pickingorderPosition/{id}
```

A `DELETE` via this endpoint bypasses all business logic — no reservation adjustment, no audit trail,
no state checks. If anyone (or any integration) calls this endpoint, it will:
1. Delete the picking position physically
2. Leave the stock unit's `reservedamount` unchanged → orphaned reservation

### Recommendation

Change `PickingorderPositionRepository` to extend `NoDeletePagingAndSortingRepository` instead of
`PagingAndSortingRepository`. This disables the REST DELETE endpoint while keeping all other
functionality. This pattern is already used by other repositories in the codebase
(see `repo/cinterface/NoDeletePagingAndSortingRepository`).

---

## Summary of All Required Changes

### Code Changes (apply to both v1 and v2)

| # | File | Change | Risk |
|---|------|--------|------|
| 1 | `WmsConstants.java` | Add `CODE_FIX_PICK_POSITION` and `CODE_CLEANUP_PICKING_POSITION` constants | None |
| 2 | `PickingorderPositionService.java` | Add unreserve of original stock unit in `fixPickingPosition()` | Low — additive change |
| 3 | `CustomerorderService.java` | Replace `setReservedamount()` with `changeReservedAmount()` in `checkAndCleanUpPickingOrderPositions()`. Add `StockunitBusinessService` dependency. | Low — behavioral change but strictly safer |
| 4 | `PickingorderPositionRepository.java` | Extend `NoDeletePagingAndSortingRepository` instead of `PagingAndSortingRepository` | Medium — verify no code uses REST DELETE |

### Testing Checklist

- [ ] `fixPickingPosition()` — verify original stock unit's `reservedamount` is decremented
- [ ] `fixPickingPosition()` — verify `stockrecord` entry created for unreserve with activity `FIX_PICK_POSITION`
- [ ] `fixPickingPosition()` — verify replacement stock unit's `reservedamount` is incremented
- [ ] `fixPickingPosition()` — verify net reservation effect is zero (one up, one down)
- [ ] `checkAndCleanUpPickingOrderPositions()` — verify `stockrecord` entries created for each position
- [ ] `checkAndCleanUpPickingOrderPositions()` — verify concurrent access doesn't cause lost updates
- [ ] `batchUpdatePickingDate()` — verify batch operations work correctly with new logic
- [ ] REST DELETE on `pickingorderPosition` — verify it returns 405 (if change #4 applied)

### Production Data Cleanup

The 26 existing orphans on WineCo should be cleaned up using:
**`plans/2026-03-06/WineCo_Orphaned_Reservations_Cleanup.sql`**

This is independent of the code fixes — the code fixes prevent *future* orphans; the SQL cleans up
*existing* ones.