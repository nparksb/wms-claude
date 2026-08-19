> [!warning] Superseded — 2026-08-06
> This plan was **never implemented** (no commit in v1 or v2 ever changed the gate) and
> the defect resurfaced on the same location as **SBDEV-2854**.
> Active plan: [[SBDEV-2854-replenish-rejects-non-flowbin-destination]].
>
> Its four "Pre-Implementation Verification Needed" questions are now answered against
> live tenant DBs. Two findings invalidate this document's recommendation:
> - `Club01` is `cases and pallets` — Q1 confirmed.
> - **`Club01` already holds 3 unit loads**, so the recommended Option A (widen the
>   location-type allowlist) would *not* have fixed it — control falls through to
>   `"Destination has already a unit load!"` at `MobileReplenishService.java:920`.
>
> Kept for the audit trail only. Do not implement from this file.

# Fix: Replenishment to Club Locations - "Destination is not a flowbin!" Error

## Issue

When using handheld Replenishment to move unitload UL174497 from `65-XJ05` to `Club01`, the system throws:
> **"Destination is not a flowbin!"**

## Root Cause Analysis

The error originates from `MobileReplenishService.java` in **two methods** that share the same flawed logic:

### 1. `checkDestination()` (line 341) — Single-unit-load replenishment
### 2. `assignDestinationForMultiUnitLoads()` (line 805) — Multi-unit-load replenishment

Both methods follow this logic when the user scans a destination location:

```
1. Look up the location by name (e.g., "Club01")               → Found
2. Check if the SKU already has a FixLocationAssignment          → No (Club items don't)
3. Check if the destination location has a FixLocationAssignment  → No (Club01 doesn't)
4. Since no FLA exists, check if the location type is "flowbin"  → Club01 is NOT "flowbin"
5. THROW "Destination is not a flowbin!"                         ← ERROR HERE
```

**The problem**: When there is no existing `FixLocationAssignment` for the destination, the code **only** allows locations of type `"flowbin"`. Club locations (like `Club01`) have a different `LocationType.sltname` (likely `"cases and pallets"`, `"NoRestriction"`, or a custom type), so they are rejected.

### Why it worked before (or was expected to work)

The replenishment process was originally designed exclusively for flowbin replenishment — moving overstock into pick-location flowbins. Club locations were not part of this flow. However, warehouse operations now need to use the handheld replenishment process to move stock to Club locations as well.

### Code Flow (MobileReplenishService.checkDestination, lines 310-367)

```java
// Line 315: Early return if destination already matches the order's destination
if (code.equalsIgnoreCase(dto.getDestinationLocationName()) || ...) return;

// Line 319: Look up location
Location storageLocation = locationRepository.findByName(code);

// Line 330: Check if item already has a FLA
if (currentItemDataOpt.isPresent()) throw "wrong location!";

// Line 336: Check if destination has a FLA
if (!fixedLocationAssignmentOpt.isPresent()) {
    // Line 341: *** THE GATE ***
    if (!locationType.getSltname().equals("flowbin")) {
        throw "Destination is not a flowbin!";  // ← Club01 fails here
    }
    // ... would create FLA and proceed
}
```

### Affected Code Locations

| File | Method | Line | Context |
|------|--------|------|---------|
| `MobileReplenishService.java` | `checkDestination()` | 341 | Single UL replenish |
| `MobileReplenishService.java` | `assignDestinationForMultiUnitLoads()` | 805 | Multi UL replenish |
| `MobileMoveStockService.java` | `scanDestination()` | 256 | Move Stock (same pattern) |

## Proposed Fix

### Option A: Allow specific location types for replenishment (Recommended)

Add a set of allowed location types for replenishment destinations, instead of hard-coding only `"flowbin"`.

**In `WmsConstants.java`**, add a constant or use a system property for allowed replenishment destination types. For now, the simplest approach is to also accept `"cases and pallets"` (or whatever `Club01`'s type is) alongside `"flowbin"`.

**Changes in `MobileReplenishService.java`**:

```java
// BEFORE (line 341):
if (!locationType.getSltname().equals(WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)) {
    throw new BusinessException("Destination is not a flowbin!");
}

// AFTER:
if (!isReplenishableLocationType(locationType)) {
    throw new BusinessException("Destination location type '" + locationType.getSltname() + "' is not allowed for replenishment!");
}
```

Add a helper method:
```java
private boolean isReplenishableLocationType(LocationType locationType) {
    String type = locationType.getSltname();
    return WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(type)
        || WmsConstants.STORAGE_LOCATION_TYPE_STOCK_RESTRICTION.equals(type);
    // "cases and pallets" is the likely type for Club locations
}
```

Apply the same change in `assignDestinationForMultiUnitLoads()` (line 805).

### Option B: Use a system property for allowed types (More flexible)

Store allowed replenishment destination types in `LosSysprop` so it can be configured per-warehouse without code changes.

```java
private boolean isReplenishableLocationType(LocationType locationType) {
    String allowedTypes = losSyspropRepository.findSysvalueBySyskey("REPLENISH_ALLOWED_LOCATION_TYPES");
    if (allowedTypes == null) {
        // Default: only flowbin
        return WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(locationType.getSltname());
    }
    return Arrays.asList(allowedTypes.split(",")).contains(locationType.getSltname());
}
```

### Option C: Skip the location-type check entirely when FLA doesn't exist

This is the least restrictive approach — if the location exists and has no FLA, allow replenishment to it regardless of type. This is risky because it removes a safety guardrail (e.g., someone could accidentally replenish to an overstock pallet location).

**Not recommended.**

## Pre-Implementation Verification Needed

Before implementing, we need to confirm:

1. **What is Club01's `LocationType.sltname`?** Run this query against the database:
   ```sql
   SELECT l.name, lt.sltname
   FROM location l
   JOIN location_type lt ON l.type_id = lt.id
   WHERE l.name = 'Club01';
   ```

2. **Are there other Club locations** (Club02, Club03, etc.) that also need this fix?

3. **Should Club locations create a `FixLocationAssignment`** when replenished to? The current code creates one — this may or may not be desired for Club locations. If Club locations are shared across multiple SKUs, creating an FLA would lock them to one SKU.

4. **Is this the same flow the user is using?** The handheld replenishment flow goes:
   - `ReplenishController.checkDestination()` → calls `MobileReplenishService.checkDestination()`
   - Then `finishReplenishmentOrder()` → transfers stock and creates FLA

   Confirm the user is hitting the Replenish screen (not Move UL or Move Stock).

## Recommendation

**Go with Option A** as the immediate fix. It's simple, targeted, and doesn't change the fundamental safety model. Once we confirm Club01's location type from the DB query, we can add it to the allowed list.

If the warehouse needs more flexibility in the future (e.g., new location types added frequently), we can upgrade to Option B later.

## Files to Change

1. `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` — lines 341 and 805
2. `src/main/java/net/aim_ai/wms/service/WmsConstants.java` — (if adding a new constant)
3. Unit tests for `MobileReplenishService`
