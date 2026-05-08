# Location & LocationType CRUD Porting Plan

**Date**: 2026-03-25
**Current Branch**: `tmp/np08-develop-argen-migration-gap`
**Source Branch**: `develop-arden`
**Scope**: Port 4 missing controller endpoints + LocationService.getLocationDetails enhancement

---

## Problem

The Web UI's "Create New Location", "Edit Location", "Create New Location Type", and "Edit Location Type" functions call backend endpoints that don't exist on the current branch:

| UI Action | API Call | Current Branch | develop-arden |
|-----------|----------|---------------|---------------|
| Create Location | `PUT /location/create` | **404 — missing** | Present |
| Update Location | `POST /location/update` | **404 — missing** | Present |
| Create Location Type | `PUT /location/createLocationType` | **404 — missing** | Present |
| Update Location Type | `POST /location/updateLocationType` | **404 — missing** | Present |

---

## Source Code Analysis (develop-arden)

### LocationController — 4 new endpoints

All 4 endpoints follow the same pattern:
1. Accept entity via `@RequestBody`
2. Check for duplicate name
3. Set ID from sequence + defaults
4. Save and return entity or error map

#### `PUT /location/create`
- Accepts `Location` entity directly via `@RequestBody`
- Checks `locationRepository.findByName()` for duplicate
- Sets `id` from `locationRepository.getNextId()`, `clientId` from "System" client, `version=1`, `entityLock=0`
- Saves and returns the new Location

#### `POST /location/update`
- Accepts `Location` entity with `id` populated
- Checks `findByName()` for name collision with a DIFFERENT location
- Loads existing location by ID, copies fields, saves
- **Bug in source**: When `findByName()` returns the SAME entity (name unchanged), the `else` branch is skipped and `updateLoc` stays null — the response returns null instead of the updated entity. Should check `existingLocation.get().getId().equals(location.getId())` and proceed to update in that case.

#### `PUT /location/createLocationType`
- Accepts `LocationType` entity
- Checks `locationTypeRepository.findBySltname()` for duplicate
- Sets `id` from `locationTypeRepository.getNextId()`, `version=0`, `entityLock=0`
- Saves and returns

#### `POST /location/updateLocationType`
- Accepts `LocationType` entity with `id`
- Checks `findBySltname()` for name collision with a DIFFERENT entity
- **Same bug as location update**: when name is unchanged, update is skipped
- Only updates `additionalcontent` and `sltname`

### LocationService.getLocationDetails — enhanced

The develop-arden version adds `areaId`, `rackId`, and `typeId` to the details map (in addition to the existing `areaName`, `rackName`, `typeName`). The current branch is missing these IDs, which the UI needs for the edit form's autocomplete pre-selection.

---

## What Already Exists on Current Branch

| Component | Status |
|-----------|--------|
| `LocationController` | Only 2 GET endpoints |
| `LocationRepository.getNextId()` | Present |
| `LocationRepository.findByName()` | Present |
| `LocationTypeRepository.getNextId()` | Present |
| `LocationTypeRepository.findBySltname()` | Present |
| `ClientRepository.findByClNr()` | Present |
| `LocationService.getLocationDetails()` | Present but missing areaId/rackId/typeId |

No new repositories or services needed — only controller endpoints and a small service enhancement.

---

## Implementation Plan

### Step 1: Add imports and dependencies to LocationController

Add to `LocationController.java`:
- Imports: `PostMapping`, `PutMapping`, `RequestBody`, `ArrayList`, `HashMap`, `List`, `Optional`
- Dependencies: `@Autowired ClientRepository`, `@Autowired LocationRepository`, `@Autowired LocationTypeRepository`

### Step 2: Add `PUT /location/create` endpoint

Port from develop-arden with these specifics:
- Accept `@RequestBody Location location`
- Check `findByName()` duplicate
- Set `id` from `getNextId()`, `clientId` from "System" client, `version=1`, `entityLock=0`
- Save and return

### Step 3: Add `POST /location/update` endpoint

Port from develop-arden **with bug fix**:
- When `findByName()` returns the same entity (name unchanged), proceed to update instead of skipping
- The source code only enters the update block in the `else` branch (name not found), which means renaming works but updating other fields without renaming returns null

**Fix**: Change the logic to:
```java
if (existingLocation.isPresent() && !existingLocation.get().getId().equals(location.getId())) {
    errors.add(getErrorMessage(location.getName(), "location already exists with this name"));
} else {
    // load and update...
}
```

### Step 4: Add `PUT /location/createLocationType` endpoint

Port directly from develop-arden — straightforward, no bugs.

### Step 5: Add `POST /location/updateLocationType` endpoint

Port from develop-arden **with same bug fix** as Step 3:
- When `findBySltname()` returns the same entity, proceed to update

### Step 6: Enhance `LocationService.getLocationDetails()`

Add the missing ID fields that the UI edit form needs:
- `details.put("areaId", locationArea.get().getId())` — in the area block
- `details.put("rackId", locationRack.get().getId())` — in the rack block
- `details.put("typeId", locationType.get().getId())` — in the type block

---

## Bug Fix Detail

The source branch's update methods have a logic error in the duplicate-name check:

```java
// SOURCE (buggy):
Optional<Location> existingLocation = locationRepository.findByName(location.getName());
if (existingLocation.isPresent()) {
    if (!existingLocation.get().getId().equals(location.getId())) {
        errors.add(...); // different entity has this name — reject
    }
    // PROBLEM: if same entity has this name (unchanged), falls through without updating
} else {
    updateLoc = locationRepository.findById(location.getId()).get();
    // ... apply updates and save
}

// FIX:
Optional<Location> existingLocation = locationRepository.findByName(location.getName());
if (existingLocation.isPresent() && !existingLocation.get().getId().equals(location.getId())) {
    errors.add(...); // different entity has this name — reject
} else {
    updateLoc = locationRepository.findById(location.getId()).get();
    // ... apply updates and save
}
```

This affects both `update` (Location) and `updateLocationType` (LocationType).

---

## Risk Assessment

| Risk | Level | Mitigation |
|------|-------|-----------|
| Duplicate name check bug from source | LOW | Fix during porting (see above) |
| Missing repository methods | NONE | All needed methods already exist |
| Entity ID generation | LOW | Uses existing `getNextId()` pattern |
| Serialization issues with `@RequestBody Location` | LOW | Entity is already Jackson-annotated (used in Spring Data REST) |
| No `@Transactional` on controller endpoints | LOW | Single save per endpoint — Spring Data implicit transaction suffices |

---

## Implementation Status — DONE

All steps implemented and tested.

**Files changed:**
- `LocationController.java` — Added 4 endpoints: `PUT /create`, `POST /update`, `PUT /createLocationType`, `POST /updateLocationType` (with bug fix for update duplicate-name logic)
- `LocationService.java` — Added `areaId`, `rackId`, `typeId` to `getLocationDetails()` + fixed `locationType.isPresent()` null check

**Tests added:**
- `LocationControllerTest.java` — 10 new tests covering all CRUD operations, duplicate name rejection, and name-unchanged update scenarios

**Test results: 1584 tests, 0 failures, 0 errors**
