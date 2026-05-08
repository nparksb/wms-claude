# Outbound Parcel Report Filter Fix — v2 Migration Assessment

**Date:** 2026-03-28
**Status:** Implemented — Ready for Code Review
**Priority:** High
**Source Plan:** [v1 Outbound Parcel Report Filter Fix](../../wms1/plan/260424-Outbound_Parcel_Report_Filter_Fix.md)
**Scope:** v2 WMS (wms2-api + wms2-web-ui), branch `tmp/np106-v1-fixes-migration`

---

## Summary

Both v1 bugs are **present in v2**:
1. `ReportController.parcelMonitorView` uses `@Param` (JPA annotation) instead of `@RequestParam` (Spring MVC) — `parcelFilter` may silently arrive as `null` in production
2. `ViewDtoService.getParcelMonitorViewByKeyword` uses fragile `parcelFilter.equals()` pattern instead of null-safe `"constant".equals(parcelFilter)`

Additionally, `@Param` misuse is a **codebase-wide issue** affecting 10+ controllers in v2.

The UI correctly sends `parcelFilter` but has a bitwise AND bug (`&` instead of `&&`) in 7 report store files.

---

## Bug 1: `@Param` Instead of `@RequestParam` (Critical)

**File:** `ReportController.java:366-374`

```java
// Current v2 (WRONG — uses JPA annotation, not Spring MVC):
public Map<String, Object> parcelMonitorView(@Param("keyword") String keyword,
                                         @Param("page") Integer page,
                                         @Param("size") Integer size,
                                         @Param("sort") String sort,
                                         @Param("order") String order,
                                         @Param("clientNumber") String clientNumber,
                                         @Param("parcelFilter") String parcelFilter,
```

**Fix:**
```java
public Map<String, Object> parcelMonitorView(@RequestParam(value = "keyword", required = false) String keyword,
                                         @RequestParam("page") Integer page,
                                         @RequestParam("size") Integer size,
                                         @RequestParam(value = "sort", required = false) String sort,
                                         @RequestParam(value = "order", required = false) String order,
                                         @RequestParam(value = "clientNumber", required = false) String clientNumber,
                                         @RequestParam(value = "parcelFilter", defaultValue = "All") String parcelFilter,
```

**Why this matters:** Spring MVC does NOT recognize `@Param` — it falls through to parameter name matching from debug symbols. Works in dev but fails silently in production builds without `-parameters` flag.

---

## Bug 2: Fragile `.equals()` Pattern (Medium)

**File:** `ViewDtoService.java:1296-1298`

```java
// Current v2 (fragile):
if (parcelFilter == null || parcelFilter.equals("All")) {
    ...
} else if (parcelFilter.equals("Palletized")) {
```

**Fix:**
```java
if (parcelFilter == null || "All".equals(parcelFilter)) {
    ...
} else if ("Palletized".equals(parcelFilter)) {
```

The v2 code does have a null check on line 1296, so it won't NPE *currently*. But the pattern is fragile — future changes could introduce NPE risk. The constant-on-left pattern is the established safe practice.

---

## Codebase-Wide `@Param` Issue (Systemic)

`@Param` (from `org.springframework.data.repository.query.Param`) is used on GET endpoint parameters across **10+ controllers**:

| Controller | Affected Lines |
|-----------|---------------|
| `ReportController.java` | 327-332, 347-352, 367-373 |
| `StockUnitController.java` | 529-533 |
| `ItemDataController.java` | 149-153, 168 |
| `AdviceController.java` | 307-312 |
| `BillOfLadingController.java` | 348-352, 374-378 |
| `CycleCountController.java` | 180-186 |
| `UnitLoadController.java` | 174-178 |
| `ClubLineController.java` | 192-196, 211-215, 230-234, 307 |
| `ReplenishOrderController.java` | 265-271 |
| `MessageController.java` | 77-82 |
| `CustomerOrderController.java` | 129, 148-152, 167-171 |

**Note:** MockMvc tests do NOT catch this bug because `.param()` bypasses annotation-based binding.

**Recommendation:** Fix all controllers as part of the parcel filter fix — the changes are mechanical and low-risk.

### UI-API Parameter Alignment Verification

**All parameter names match perfectly** between the v2 API and wms2-web-ui. No UI changes needed for the `@Param` → `@RequestParam` fix. Cross-referenced every affected endpoint against the corresponding Vuex store:

| Controller Endpoint | UI Store File | Parameters Match? |
|---------------------|--------------|-------------------|
| `GET /report/flowbinMonitorView` | `store/reports/flowbin.js:55` | Yes |
| `GET /report/parcelPickingView` | `store/reports/parcelPicking.js:58` | Yes |
| `GET /report/parcelMonitorView` | `store/reports/outboundParcel.js:59` | Yes |
| `GET /stockUnit/detailView` | `store/handlingUnits/stockUnits.js:57` | Yes |
| `GET /itemData/detailView` | `store/masterData/skuData.js:67` | Yes |
| `GET /itemData/detailViewByKeyword` | `store/masterData/skuData.js:52` | Yes |
| `GET /advice/detailView` | `store/receiving/inboundNotices.js:120` | Yes |
| `GET /billOfLading/openBol` | `store/outbound/outboundBols.js:108` | Yes |
| `GET /billOfLading/closedBol` | `store/outbound/outboundBols.js:135` | Yes |
| `GET /cycleCount/detailView` | `store/internalOps/cycleCount.js:119` | Yes |
| `GET /unitLoad/detailView` | `store/handlingUnits/container.js:51` | Yes |
| `GET /clubLine/openClubRun` | `store/outbound/club.js:143` | Yes |
| `GET /clubLine/closedClubRun` | `store/outbound/club.js:171` | Yes |
| `GET /clubLine/activeClubRun` | `store/processes/clubRuns.js:131` | Yes |
| `GET /clubLine/availableStagingLanes` | `store/processes/clubRuns.js:174` | Yes |
| `GET /replenishOrder/detailView` | `store/internalOps/replenishments.js:124` | Yes |
| `GET /message/detailView` | `store/admin/serviceLogs.js:41` | Yes (note: UI never sends `state`) |
| `GET /customerOrder/detailsByBolId` | `store/outbound/outboundBols.js:176` | Yes |
| `GET /customerOrder/openPickPack` | `store/outbound/pickPack.js:120` | Yes |
| `GET /customerOrder/closedPickPack` | `store/outbound/pickPack.js:149` | Yes |

### Parameter Required/Optional Classification

All endpoints follow the same pattern:
- **Required:** `page`, `size`, `state` (when used by Advice/CycleCount/Replenish), `bolId`, `pallet`, `orderBatchId`
- **Optional (`required=false`):** `keyword`, `sort`, `order`, `clientNumber`, `clientId`, `parcelFilter`, `state` (MessageController only — UI never sends it)
- **Special:** `parcelFilter` should have `defaultValue = "All"` to prevent null; `sectionName` on ReplenishOrderController is already correctly `@RequestParam`

---

## UI Status (wms2-web-ui)

### Search Flow — Works Correctly
The UI sends `parcelFilter` correctly in the search request via `store/reports/outboundParcel.js:63-64`.

### Bitwise AND Bug — 7 Files Affected
`data.clientNumber != null & data.clientNumber !== 'All Shippers'` uses single `&` (bitwise AND) instead of `&&` (logical AND). Works by accident but is technically incorrect.

**Affected files:**
- `store/reports/outboundParcel.js:60`
- `store/reports/flowbin.js:56`
- `store/reports/receiving.js:55`
- `store/reports/parcelPicking.js:59`
- `store/reports/skuLocation.js:55`
- `store/reports/inventory.js:64`
- `store/reports/lock.js:55`

### Export Flow — Does Not Include parcelFilter
The export action (`outboundParcel.js:78-91`) does not include `parcelFilter` in the export request. Exports always return all parcels regardless of filter. This is a separate enhancement, not a regression.

---

## Implementation Plan

### Phase 1: Fix parcelMonitorView (Required — matches v1 fix)

| Step | Action | File | Effort |
|------|--------|------|--------|
| 1 | Replace `@Param` with `@RequestParam` on `parcelMonitorView` | `ReportController.java:366-374` | Small |
| 2 | Add `defaultValue = "All"` to `parcelFilter` param | `ReportController.java:373` | Small |
| 3 | Change to null-safe constant-on-left `.equals()` | `ViewDtoService.java:1296,1298` | Small |
| 4 | Add ViewDtoService tests for Palletized/Unpalletized/null | `ViewDtoServiceUnitTest.java` | Small |

### Phase 2: Fix bitwise AND in UI (Optional — low priority)

| Step | Action | File(s) | Effort |
|------|--------|---------|--------|
| 5 | Replace `&` with `&&` in clientNumber check | 7 store files in wms2-web-ui | Small |

### Phase 3: Fix codebase-wide `@Param` (Recommended — same PR, mechanical change)

| Step | Action | File(s) | Effort |
|------|--------|---------|--------|
| 6 | Replace 73 `@Param` with `@RequestParam` on 20 endpoints | 11 controllers (see table above) | Medium |

**No UI changes needed** — all parameter names match exactly. Only annotation changes on the API side.

---

## Tests

### Existing Tests
- `ReportControllerUnitTest.java:725-800` — 3 tests, but all pass `isNull()` for `parcelFilter` (don't test actual filter values)
- `ViewDtoServiceUnitTest.java:2062` — Only tests "All" branch

### Tests Needed
| Test | Description | Priority |
|------|-------------|----------|
| `parcelMonitorView_palletizedFilter` | Verify "Palletized" filter dispatches correctly | High |
| `parcelMonitorView_unpalletizedFilter` | Verify "Unpalletized" filter dispatches correctly | High |
| `parcelMonitorView_nullFilterDefaultsToAll` | Verify null/missing parcelFilter defaults to "All" | High |
| `getParcelMonitorViewByKeyword_palletizedFilter` | Service test for Palletized branch | Medium |
| `getParcelMonitorViewByKeyword_unpalletizedFilter` | Service test for Unpalletized branch | Medium |

---

## Current Status

| Item | Status | Action |
|------|--------|--------|
| Bug 1: `@Param` on `parcelMonitorView` | **Done** | Fixed with `@RequestParam` |
| Bug 2: Fragile `.equals()` pattern | **Done** | Fixed to constant-on-left |
| UI search sends parcelFilter | Working | None |
| UI bitwise AND bug (7 files) | **Done** | Fixed `&` → `&&` |
| Codebase-wide `@Param` (11 controllers) | **Done** | All 73 annotations fixed |
| Export ignores parcelFilter | Pre-existing limitation | Separate enhancement |

### Test Results (2026-03-28, post-implementation)

```
375 tests, 0 failures — BUILD SUCCESS
```

### Files Changed

**wms2-api (13 files):**
- `ReportController.java` — 3 endpoints: `@Param` → `@RequestParam` + `parcelFilter` defaultValue
- `ViewDtoService.java` — null-safe constant-on-left `.equals()`
- `StockUnitController.java` — 1 endpoint: `@Param` → `@RequestParam`
- `ItemDataController.java` — 2 endpoints: `@Param` → `@RequestParam`
- `AdviceController.java` — 1 endpoint: `@Param` → `@RequestParam`
- `BillOfLadingController.java` — 2 endpoints: `@Param` → `@RequestParam`
- `CycleCountController.java` — 1 endpoint: `@Param` → `@RequestParam`
- `UnitLoadController.java` — 1 endpoint: `@Param` → `@RequestParam`
- `ClubLineController.java` — 4 endpoints: `@Param` → `@RequestParam`
- `ReplenishOrderController.java` — 1 endpoint: `@Param` → `@RequestParam`
- `MessageController.java` — 1 endpoint: `@Param` → `@RequestParam`
- `CustomerOrderController.java` — 3 endpoints: `@Param` → `@RequestParam`

**wms2-api tests (3 files updated):**
- `ReportControllerUnitTest.java` — Updated mock to expect `"All"` instead of `null` for parcelFilter
- `CycleCountControllerUnitTest.java` — Added required `state` param to test URLs
- `CustomerOrderControllerUnitTest.java` — Added required `pallet` param to test URL

**wms2-web-ui (7 files):**
- `store/reports/outboundParcel.js` — `&` → `&&`
- `store/reports/flowbin.js` — `&` → `&&`
- `store/reports/receiving.js` — `&` → `&&`
- `store/reports/parcelPicking.js` — `&` → `&&`
- `store/reports/skuLocation.js` — `&` → `&&`
- `store/reports/inventory.js` — `&` → `&&`
- `store/reports/lock.js` — `&` → `&&`
