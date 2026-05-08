---
title: "Move Stock - 'Location with Stock' Shows N/A Despite Existing Stock"
ticket: ""
ticket_url: ""
type: bug
priority: medium
status: planning
project:
  - wms-api-v1
  - wms-mobile-ui-v1
version: v1
requester: Internal
created: 2026-04-16
updated: 2026-04-16 (Fix 1 implemented)
related: []
tags:
  - plan
  - move-stock
  - mobile
---

# Move Stock - "Location with Stock" Shows N/A Despite Existing Stock

**Type:** Bug
**Priority:** Medium
**Status:** PLANNING
**Date:** 2026-04-16

---

## 1. Problem Statement

On the "Scan Destination Container" page of `wms-mobile-ui`, the field **"Location with Stock:"** displays **"N/A"** even when the item has stock in storage locations.

For item 702435, the database query returns two valid storage locations:

| id | name | type_id | area_id |
|----|------|---------|---------|
| 64097 | 06-XB01 | 51507 | 51551 |
| 225899 | SH-B12 | 51502 (flowbin) | 51553 |

Type_id 51502 is confirmed as `flowbin`. The backend switch statement in `selectStockUnit()` correctly handles flowbin and adds "SH-B12" to `locationList`. Yet the UI shows "N/A".

---

## 2. Root Cause Analysis

### The Backend Is NOT the Problem

The `MobileMoveStockService.selectStockUnit()` switch at line 181-194 correctly captures the flowbin location "SH-B12". When the service completes successfully, the serialized `StockTransferDto` JSON includes `"existingLocation": "SH-B12"`.

### The Real Bug: Frontend Navigation Without Error Checking

The bug is in **`inputAmount.vue:96-111`**. The `submit()` method unconditionally navigates to the destination page, regardless of whether the `selectStockUnit` API call succeeded.

**File:** `wms-mobile-ui/components/moveStock/inputAmount.vue:96-111`

```javascript
async submit() {
    // ...
    await this.$store.dispatch('moveStock/selectStockUnit', data);   // (1) may fail

    this.$store.commit('moveStock/setAmount', this.scannedValue)     // (2) always runs
    this.$store.commit('moveStock/setProcess', '3_destination')      // (3) ALWAYS NAVIGATES
    // ...
}
```

And the store action at `moveStock.js:98-116`:

```javascript
async selectStockUnit(context, data) {
    try {
        const result = await this.$axios.$get(`/moveStock/selectStockUnit/${data.id}/${data.value}`)
        if (result.errors) {
            this.$toast.error(result.errors[0].message)    // ← shows toast, does NOT setStock
        } else {
            context.commit('setStock', result)              // ← only on success
            context.commit('setProcess', '3_destination')
        }
    } catch(error) {
        this.$toast.error('Error: ' + error)               // ← shows toast, does NOT setStock
    }
}
```

### The Bug Chain

```
Step 1: selectSource succeeds
        → setStock(selectSourceDTO) — locationList=[], existingLocation="N/A"
        → state.stock = { ..., existingLocation: "N/A" }

Step 2: inputAmount.submit() dispatches selectStockUnit
        → API call FAILS (error response or exception)
        → Action shows toast error, does NOT call setStock
        → state.stock UNCHANGED (still selectSource DTO with "N/A")

Step 3: inputAmount.submit() continues after await
        → commits setProcess('3_destination') UNCONDITIONALLY
        → scanDestination.vue renders
        → reads stock.existingLocation from STALE state.stock
        → displays "N/A"
```

### Why state.stock Is Stale

Two contributing factors:

1. **`selectSource` never populates `locationList`** (`MobileMoveStockService.selectSource()` lines 75-155). It only populates `stockUnitList` and `stockUnitInfoDtos`. The location lookup requires knowing which specific stock unit the user selected (its `itemdataId`), so it's deferred to `selectStockUnit`. This means the `selectSource` DTO always has `existingLocation: "N/A"`.

2. **`selectStockUnit` action swallows errors** — it shows a toast message but does not throw or return a success indicator. The caller (`inputAmount.vue`) has no way to determine whether the dispatch succeeded.

### Why selectStockUnit Fails for Item 702435

The `selectStockUnit` service processes locations in sorted order (`DefaultStrategy`: RackRow → Rack → Xpos → Ypos). The two locations have different xpos values:

| name | xpos | ypos | type_id | Sort Position |
|------|------|------|---------|---------------|
| 06-XB01 | 1 | 1 | 51507 | **First** (lower xpos) |
| SH-B12 | 12 | 1 | 51502 (flowbin) | **Second** |

"06-XB01" (type_id 51507) is processed first. The service calls `locationTypeRepository.findById(51507).get()`. If this location type lookup fails — or if the `DefaultStrategy` sort encounters missing rack/rackrow data — the exception aborts the entire service before the flowbin location "SH-B12" is ever reached:

```java
for (Location location : resultList) {
    LocationType locationType = locationTypeRepository.findById(location.getTypeId()).get();  // ← can throw
    switch (locationType.getSltname()) {
        case "flowbin":
            dto.getLocationList().add(0, location.getName());  // ← never reached if prior iteration throws
```

The exception propagates to the controller's `catch (Exception e)` block, which returns an error response. The toast may auto-dismiss quickly, making the error invisible to the user.

### Confirming the Root Cause

To verify, check:
1. **Server logs** — look for exceptions during `selectStockUnit` for this item
2. **Browser console** — the action has `console.log('selectStockUnit returned', result)` and `console.log('Error:', ...)` 
3. **Database** — confirm `location_type` with id=51507 exists and has valid `sltname`

---

## 3. Affected Locations

| # | File | Line | Layer | Description |
|---|------|------|-------|-------------|
| 1 | `inputAmount.vue` | 104-107 | Frontend | `submit()` unconditionally navigates to `3_destination` after `selectStockUnit` dispatch |
| 2 | `moveStock.js` | 98-116 | Frontend | `selectStockUnit` action swallows errors — no return value or throw for caller to check |
| 3 | `MobileMoveStockService.java` | 181-194 | Backend | Unguarded `.get()` on `locationTypeRepository.findById()` — exception on first location aborts processing of subsequent locations |

---

## 4. Proposed Fix

### Fix 1 (Primary): inputAmount.vue — Check Action Result Before Navigating

The `selectStockUnit` action should return a success indicator. `inputAmount.vue` should only navigate on success.

**File:** `wms-mobile-ui/store/moveStock.js` — modify `selectStockUnit` action:

```javascript
async selectStockUnit(context, data) {
    try {
        const result = await this.$axios.$get(`/moveStock/selectStockUnit/${data.id}/${data.value}`)
        if (result.errors) {
            this.$toast.error(result.errors[0].message)
            return false                                    // ← signal failure
        } else {
            this.$toast.info('Stock unit selected')
            context.commit('setStock', result)
            return true                                     // ← signal success
        }
    } catch(error) {
        this.$toast.error('Error: ' + error)
        return false                                        // ← signal failure
    }
}
```

**File:** `wms-mobile-ui/components/moveStock/inputAmount.vue` — modify `submit()`:

```javascript
async submit() {
    this.$refs.scan.validate();
    if (this.$refs.scan.validate()) {
        const data = {
            id: this.currentStock.stockUnit.id,
            value: this.scannedValue
        }
        const success = await this.$store.dispatch('moveStock/selectStockUnit', data);
        if (!success) return;                               // ← stop on failure

        this.$store.commit('moveStock/setAmount', this.scannedValue)
        this.$store.commit('moveStock/setProcess', '3_destination')
        if (this.currentMode === 'new') {
            await this.$store.dispatch('moveStock/getLocations')
        }
    }
}
```

Also remove the redundant `setProcess('3_destination')` from the action itself — let the caller control navigation:

```javascript
// In selectStockUnit action — remove this line:
context.commit('setProcess', '3_destination')   // ← REMOVE (caller handles navigation)
```

### Fix 2 (Defensive): Backend — Resilient Location Type Lookup

Make the location processing loop resilient so one bad location doesn't abort the entire list.

**File:** `MobileMoveStockService.java:181-194`

```java
for (Location location : resultList) {
    Optional<LocationType> locationTypeOpt = locationTypeRepository.findById(location.getTypeId());
    if (!locationTypeOpt.isPresent()) {
        LOG.warn("Location type not found for typeId={} location={}", location.getTypeId(), location.getName());
        continue;
    }
    LocationType locationType = locationTypeOpt.get();
    if (WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(locationType.getSltname())) {
        dto.getLocationList().add(0, location.getName());
    } else {
        dto.getLocationList().add(location.getName());
    }
}
```

This fix:
- Uses `findById().isPresent()` instead of unguarded `.get()` — prevents `NoSuchElementException`
- Logs a warning for missing types (visible in production, unlike the current DEBUG log)
- Includes all storage locations (query already filters by `useforstorage = 'true'`)
- Preserves flowbin priority (index 0)

---

## 5. Implementation Checklist

- [x] **Fix 1a**: Modify `moveStock.js` `selectStockUnit` action to return `true`/`false`
- [x] **Fix 1b**: Modify `inputAmount.vue` `submit()` to check return value before navigating
- [x] **Fix 1c**: Remove redundant `setProcess('3_destination')` from the action
- [ ] **Fix 2**: Make backend location loop resilient with `isPresent()` guard
- [ ] Verify: Check database for `location_type` id=51507 existence and `sltname` value
- [ ] Unit test: `selectStockUnit` service handles missing location types gracefully
- [ ] Unit test: `selectStockUnit` includes all storage location types, not just flowbin/overstock
- [ ] Manual test: Confirm "Location with Stock" shows location name for item 702435

---

## 6. Test Plan

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Happy path — item with flowbin stock | Scan container, enter valid amount | "Location with Stock" shows flowbin location name |
| API error — amount exceeds available | Enter amount > available | Toast error, stays on amount page (does NOT navigate) |
| API error — missing location type | Item has stock in location with invalid type_id | Toast error, stays on amount page |
| Backend resilience — mixed types | Item with flowbin + invalid-type locations | Service completes, flowbin location shown (invalid type skipped with warning) |
| No stock in storage areas | Item with stock only in non-storage areas | "Location with Stock" shows "N/A" (correct) |

---

## 7. Notes

- The toast error from the `selectStockUnit` action auto-dismisses, making failures invisible to users. Fix 1 addresses this by preventing navigation on failure, which keeps the user on the amount page where they can see the error and retry.
- The `selectSource` API intentionally does not populate `locationList` — it cannot know which stock unit the user will select. This is correct behavior; the issue is solely that the frontend navigates without confirming `selectStockUnit` succeeded.
- **V2 applicability:** Check `wms2-mobile-ui/store/moveStock.js` and `wms2-api/MobileMoveStockService.selectStockUnit()` for the same pattern. The frontend navigation bug and the unguarded `.get()` likely exist in V2 as well.
