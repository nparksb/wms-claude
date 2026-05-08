# Location & LocationType CRUD Porting Plan — v2 Migration Assessment

**Date:** 2026-03-28
**Status:** Implemented — Ready for Code Review
**Priority:** Medium
**Source Plan:** [v1 Location CRUD Porting Plan](../../wms1/plan/260424-Location_CRUD_Porting_Plan.md)
**Scope:** v2 WMS (wms2-api), branch `tmp/np106-v1-fixes-migration`

---

## Summary

All 4 CRUD endpoints from the v1 plan **already exist in v2** with significant improvements (service-layer separation, proper `@Transactional(tenantTransactionManager)`, JPA-managed ID generation). The duplicate-name bug fixes are also present.

**One gap remains:** `LocationService.getLocationDetails()` is missing `areaId`, `rackId`, and `typeId` from the response map — only the resolved names are returned. The UI edit forms need these IDs for dropdown pre-selection.

**One concern identified:** Potential HTTP method mismatches between v2 API endpoints and the wms2-web-ui Vuex store calls need verification.

---

## v2 API Status

| Endpoint | v1 | v2 | Status | Bug Fix |
|----------|----|----|--------|---------|
| Create Location | `PUT /location/create` | `POST` at line 58 | **Present** (improved) | N/A |
| Update Location | `POST /location/update` | `PUT` at line 77 | **Present** (improved) | **Yes** — line 207 |
| Create Location Type | `PUT /location/createLocationType` | `POST` at line 96 | **Present** (improved) | N/A |
| Update Location Type | `POST /location/updateLocationType` | `PUT` at line 115 | **Present** (improved) | **Yes** — line 245 |
| `getLocationDetails()` | Returns areaId, rackId, typeId + names | Returns names only | **Gap** | N/A |

### v2 Improvements Over v1

- **Service-layer separation:** CRUD logic extracted to `LocationService.java` (v1 had everything inline in controller)
- **Proper transactions:** `@Transactional(value = "tenantTransactionManager", ...)` on all write methods
- **JPA ID generation:** No manual `getNextId()` calls — JPA manages IDs
- **Extended fields:** `updateLocationType` updates depth/height/width/volume in addition to additionalcontent and sltname

---

## UI Usage (wms2-web-ui)

**All endpoints are actively used by the UI:**

| UI Component | Vuex Store | API Call |
|-------------|------------|----------|
| `createLocationDialog.vue` (create mode) | `storageLocation.js:120` | `POST /location/create` |
| `createLocationDialog.vue` (edit mode) | `storageLocation.js:139` | `POST /location/update` |
| `createLocationTypeDialog.vue` (create mode) | `locationType.js:63` | `PUT /location/createLocationType` |
| `createLocationTypeDialog.vue` (edit mode) | `locationType.js:82` | `POST /location/updateLocationType` |
| Storage locations list | `storageLocation.js:57` | `GET /location/detailView` |
| Location detail (edit prefill) | `storageLocation.js:89` | `GET /location/locationDetailsById/{id}` |

### HTTP Method Alignment — FIXED in wms2-web-ui

The v2 API used different HTTP methods than the UI was sending. The UI Vuex stores were updated to match the v2 API:

| Endpoint | v2 API | UI Before | UI After | Status |
|----------|--------|-----------|----------|--------|
| `/location/create` | `POST` | `POST` | `POST` | Already matched |
| `/location/update` | `PUT` | `POST` | `PUT` | **Fixed** |
| `/location/createLocationType` | `POST` | `PUT` | `POST` | **Fixed** |
| `/location/updateLocationType` | `PUT` | `POST` | `PUT` | **Fixed** |

**Files changed in wms2-web-ui:**
- `store/masterData/storageLocation.js:139` — `$post` → `$put` for `/location/update`
- `store/masterData/locationType.js:63` — `$put` → `$post` for `/location/createLocationType`
- `store/masterData/locationType.js:82` — `$post` → `$put` for `/location/updateLocationType`

---

## Implementation Plan

### Step 1: Add Missing ID Fields to `getLocationDetails()` (Required)

**File:** `LocationService.java:279-295`

Add `areaId`, `rackId`, `typeId` to the response map alongside the existing name fields:

```java
// At line ~283, alongside "areaName":
details.put("areaId", locationArea.get().getId());

// At line ~288, alongside "rackName":
details.put("rackId", locationRack.get().getId());

// At line ~294, alongside "typeName":
details.put("typeId", locationType.getId());
```

**Effort:** Small — 3 lines.

### Step 2: Verify and Fix HTTP Method Mismatches (If Needed)

**File:** `LocationController.java:77, 96, 115`

If the HTTP methods don't match the UI expectations, change:
- Line 77: `@PutMapping("/update")` → `@PostMapping("/update")` (to match UI's `POST`)
- Line 96: `@PostMapping("/createLocationType")` → `@PutMapping("/createLocationType")` (to match UI's `PUT`)
- Line 115: `@PutMapping("/updateLocationType")` → `@PostMapping("/updateLocationType")` (to match UI's `POST`)

**Effort:** Small — verify first, then 0-3 annotation changes.

### Step 3: Update Tests (If Changes Made)

Update `LocationServiceUnitTest.java` to verify the 3 new ID fields are present in the `getLocationDetails()` response.

---

## Tests

### Existing Test Coverage

- `LocationControllerUnitTest.java` — covers CRUD endpoints
- `LocationServiceUnitTest.java` — covers service-layer operations

### Tests Needed

| Test | Description | Priority |
|------|-------------|----------|
| `getLocationDetails_includesAreaId` | Verify `areaId` in response map | Medium |
| `getLocationDetails_includesRackId` | Verify `rackId` in response map | Medium |
| `getLocationDetails_includesTypeId` | Verify `typeId` in response map | Medium |

---

## Recommendations

### 1. Endpoint Path Verification

Verify the v2 controller endpoint paths match what the UI calls. The v2 controller may use `/location/createLocation` (v2 style) vs `/location/create` (v1 style). If paths differ, the UI will get 404s.

### 2. `deleteLocationType` Endpoint

The UI store at `locationType.js:101` also calls `DELETE /location/deleteLocationType/{id}`. Verify this endpoint exists in v2.

### 3. Error Handling Consistency in `getLocationDetails()`

v2 uses `orElseThrow` for typeId lookup but `isPresent()` for area/rack. Consider making these consistent — either all graceful (`isPresent()`) or all strict (`orElseThrow`).

---

## Current Status

| Item | Status | Action |
|------|--------|--------|
| Create Location endpoint | Already in v2 | None |
| Update Location endpoint (with bug fix) | Already in v2 | None |
| Create LocationType endpoint | Already in v2 | None |
| Update LocationType endpoint (with bug fix) | Already in v2 | None |
| `getLocationDetails()` with areaId/rackId/typeId | **Done** | 3 ID fields added |
| HTTP method alignment with UI | **Done** | 3 UI Vuex stores updated |

### Test Results (2026-03-28, post-implementation)

```
LocationServiceUnitTest:      Tests run: 18, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
LocationControllerUnitTest:   Tests run: 10, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
Total:                        28 tests, 0 failures
```

### Files Changed

**wms2-api:**
- `LocationService.java:282,288,294` — Added `areaId`, `rackId`, `typeId` to `getLocationDetails()` response
- `LocationServiceUnitTest.java` — Updated 2 existing tests to verify new ID fields

**wms2-web-ui:**
- `store/masterData/storageLocation.js:139` — `$post` → `$put` for `/location/update`
- `store/masterData/locationType.js:63` — `$put` → `$post` for `/location/createLocationType`
- `store/masterData/locationType.js:82` — `$post` → `$put` for `/location/updateLocationType`
