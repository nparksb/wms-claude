# Outbound Parcel Report - Parcel Filter Fix Plan

## Architecture

- **Web UI**: `release` branch of `wms-web-ui`
- **API**: `tmp/np09-club-order-cancellation-error` branch of `wms-api` (includes all `task/SBDEV-1943` changes)
- **Reference (working)**: `task/SBDEV-1943` branches of both repos

## Problem

The "Filter by Parcel" dropdown (All / Palletized / Unpalletized) on the Outbound Parcel Report page does not work as expected. The Web UI sends the `parcelFilter` query parameter and the API has the filter dispatch code — yet the filter still doesn't work.

## Root Cause Analysis

Both the frontend and backend have the parcel filter code. After deep analysis, there are **two bugs** that cause the filter to fail:

### Bug 1 (Critical): `@Param` annotation used instead of `@RequestParam` on controller

**File:** `src/main/java/net/aim_ai/wms/controller/ReportController.java:366-372`

The controller uses `@Param` (from `org.springframework.data.repository.query.Param`) — a Spring Data annotation meant for naming parameters in `@Query` methods on repositories. The correct annotation for Spring MVC controller query parameters is `@RequestParam` (from `org.springframework.web.bind.annotation`).

```java
// Current (WRONG annotation):
public Map<String, Object> parcelMonitorView(@Param("keyword") String keyword,
                                             @Param("page") Integer page,
                                             ...
                                             @Param("parcelFilter") String parcelFilter,
```

**Why this may cause the filter to fail:**
- Spring MVC does NOT recognize `@Param` — it falls through to a fallback that resolves parameters by method argument name from debug symbols (compiled with `-g`)
- This fallback works **only if** the compiled `.class` file retains parameter names, which depends on the compiler settings (`-parameters` flag or debug info)
- If the deployment environment compiles without debug symbols (e.g., CI/CD with different Maven settings, or the Docker multi-stage build), `parcelFilter` will resolve as `null`
- With `@RequestParam`, Spring MVC would explicitly bind the query parameter by name — guaranteed to work regardless of compiler settings

**Why this worked on `task/SBDEV-1943` but not on `release` deployment:**
- Local dev builds (used during `task/SBDEV-1943` testing) typically include debug symbols → fallback works
- CI/Docker builds for staging/production may strip debug info → fallback fails → `parcelFilter` arrives as `null`

> **Note:** This is a codebase-wide pattern — all controller endpoints use `@Param` instead of `@RequestParam`. It works by accident for existing parameters but is inherently fragile.

### Bug 2 (Critical): NullPointerException when `parcelFilter` is null

**File:** `src/main/java/net/aim_ai/wms/service/ViewDtoService.java:1274`

```java
if (parcelFilter.equals("All")) {   // NPE if parcelFilter is null!
```

When `parcelFilter` arrives as `null` (due to Bug 1, or if the query param is simply omitted), this line throws a `NullPointerException`. The exception propagates as a 500 Internal Server Error. The frontend's `catch(error)` block at `outboundParcel.js:73` silently logs it to console, so the UI just shows no results or stale data with no visible error.

**Chain of failure:**
1. Web UI sends `GET /v3/report/parcelMonitorView?...&parcelFilter=Palletized`
2. Spring MVC doesn't bind `parcelFilter` (due to `@Param` + missing debug symbols) → `null`
3. `ViewDtoService.getParcelMonitorViewByKeyword()` receives `null`
4. `parcelFilter.equals("All")` → **NullPointerException** → 500 error
5. Frontend catches error silently → table shows no results or previous data

### Supporting Evidence

The frontend code is **byte-for-byte identical** between `release` and `task/SBDEV-1943`:
- `store/reports/outboundParcel.js` — identical (correctly sends `parcelFilter`)
- `components/reports/outboundParcelReport.vue` — filter logic identical (only palletize guard logic differs, which is unrelated)
- `pages/reports/outbound-parcel-report.vue` — identical

This confirms the bug is entirely on the API side.

## Fix Plan

### Fix 1: Replace `@Param` with `@RequestParam` on the parcelMonitorView endpoint (Required)

**File:** `src/main/java/net/aim_ai/wms/controller/ReportController.java:366-372`

```java
// Before:
@GetMapping(path = "/parcelMonitorView", produces = "application/json")
public Map<String, Object> parcelMonitorView(@Param("keyword") String keyword,
                                             @Param("page") Integer page,
                                             @Param("size") Integer size,
                                             @Param("sort") String sort,
                                             @Param("order") String order,
                                             @Param("clientNumber") String clientNumber,
                                             @Param("parcelFilter") String parcelFilter,
                                             @AuthenticationPrincipal Principal principal) {

// After:
@GetMapping(path = "/parcelMonitorView", produces = "application/json")
public Map<String, Object> parcelMonitorView(@RequestParam("keyword") String keyword,
                                             @RequestParam("page") Integer page,
                                             @RequestParam("size") Integer size,
                                             @RequestParam(value = "sort", required = false) String sort,
                                             @RequestParam(value = "order", required = false) String order,
                                             @RequestParam(value = "clientNumber", required = false) String clientNumber,
                                             @RequestParam(value = "parcelFilter", defaultValue = "All") String parcelFilter,
                                             @AuthenticationPrincipal Principal principal) {
```

**Key change:** `parcelFilter` gets `defaultValue = "All"` so it can never be null.

**Import change:** Ensure `import org.springframework.web.bind.annotation.RequestParam;` is present (may already be imported for other methods in the file).

### Fix 2: Add null-safety to ViewDtoService (Required — defense in depth)

**File:** `src/main/java/net/aim_ai/wms/service/ViewDtoService.java:1268-1283`

```java
// Before:
public Map<String, Object> getParcelMonitorViewByKeyword(String keyword, String clientNumber, String parcelFilter, Pageable p) {
    Page<ParcelMonitorView> page = null;
    if (parcelFilter.equals("All")) {
        page = parcelMonitorViewRepository.findByKeyword(keyword, clientNumber, p);
    } else if (parcelFilter.equals("Palletized")) {
        page = parcelMonitorViewRepository.findByKeywordAndParcelPalletized(keyword, clientNumber, p);
    } else {
        page = parcelMonitorViewRepository.findByKeywordAndParcelUnpalletized(keyword, clientNumber, p);
    }

// After:
public Map<String, Object> getParcelMonitorViewByKeyword(String keyword, String clientNumber, String parcelFilter, Pageable p) {
    Page<ParcelMonitorView> page = null;
    if (parcelFilter == null || "All".equals(parcelFilter)) {
        page = parcelMonitorViewRepository.findByKeyword(keyword, clientNumber, p);
    } else if ("Palletized".equals(parcelFilter)) {
        page = parcelMonitorViewRepository.findByKeywordAndParcelPalletized(keyword, clientNumber, p);
    } else {
        page = parcelMonitorViewRepository.findByKeywordAndParcelUnpalletized(keyword, clientNumber, p);
    }
```

**Changes:**
- Null check on `parcelFilter` — defaults to "All" behavior
- Reversed `.equals()` calls to `"All".equals(parcelFilter)` — prevents NPE

## Additional Issues Found (Lower Priority)

### 3. Bitwise AND in Web UI store (Latent bug)

**File:** `wms-web-ui/store/reports/outboundParcel.js:60`

```javascript
// Current (bitwise AND - works by accident):
if (data.clientNumber != null & data.clientNumber !== 'All Shippers') {

// Should be (logical AND):
if (data.clientNumber != null && data.clientNumber !== 'All Shippers') {
```

Works by accident because both operands coerce to 0/1, but is technically incorrect.

### 4. Export endpoint does not support parcelFilter

`POST /v3/report/exportOutboundParcel` uses a separate native query (`findByClientOffsetAndLimit`) with no state filter. Exports always return all parcels regardless of filter selection. Separate enhancement if needed.

### 5. INNER JOIN on `shipperid` in view definition

**File:** `src/main/resources/db/migration/V1.1.01__wms_views.sql:17`

```sql
-- Current (excludes orders without a shipper):
JOIN shipperid si on co.shipperid_id = si.id

-- If orders can exist without shipper, change to:
LEFT JOIN shipperid si on co.shipperid_id = si.id
```

## Web UI Changes Required

**None for the filter fix.** The frontend already sends `parcelFilter` correctly. Optionally fix the bitwise AND (issue #3 above).

## Files Changed

| File | Repo | Change |
|------|------|--------|
| `src/main/java/net/aim_ai/wms/controller/ReportController.java` | wms-api | Replace `@Param` with `@RequestParam` on parcelMonitorView endpoint |
| `src/main/java/net/aim_ai/wms/service/ViewDtoService.java` | wms-api | Add null check + reverse `.equals()` calls |

## Testing

1. Deploy updated WMS API
2. Open Outbound Parcel Report page
3. Verify "All" filter shows all parcels (state 601-699)
4. Verify "Palletized" filter shows only parcels with state = 670 (check state column)
5. Verify "Unpalletized" filter shows only parcels with state < 670
6. Verify keyword search works in combination with parcel filter
7. Verify shipper filter works in combination with parcel filter
8. Verify pagination works correctly with each filter
9. Test direct API call without `parcelFilter` param — should return all (not 500 error)
10. Check browser dev tools Network tab — confirm no 500 errors on filter change

## Verification Checklist

- [x] `@RequestParam` used for `parcelFilter` with `defaultValue = "All"`
- [x] `ViewDtoService` uses `"All".equals(parcelFilter)` (null-safe)
- [ ] API returns correct filtered results for each filter value (needs deployment testing)
- [ ] No 500 errors in server logs when changing filters (needs deployment testing)
- [ ] Pagination resets to page 1 when filter changes (needs deployment testing)
- [x] Export still works (separate code path, no changes needed)

## Implementation Status

**Status: IMPLEMENTED — awaiting deployment testing**

### Changes Made (2026-03-26)

#### 1. `ReportController.java` (line 365-384)
- Replaced `@Param` with `@RequestParam` for all parameters on `/parcelMonitorView` endpoint
- Added `defaultValue = "All"` for `parcelFilter` to prevent null
- Added `required = false` for optional parameters (`sort`, `order`, `clientNumber`)

#### 2. `ViewDtoService.java` (line 1274-1282)
- Changed `parcelFilter.equals("All")` → `parcelFilter == null || "All".equals(parcelFilter)` (null-safe)
- Changed `parcelFilter.equals("Palletized")` → `"Palletized".equals(parcelFilter)` (null-safe)

#### 3. `ViewDtoServiceUnitTest.java` — 5 test cases (replaced 1 old test)
- `testGetParcelMonitorViewByKeyword_AllFilter` — verifies "All" filter calls `findByKeyword`
- `testGetParcelMonitorViewByKeyword_PalletizedFilter` — verifies "Palletized" calls `findByKeywordAndParcelPalletized`, returns state text "Palletized"
- `testGetParcelMonitorViewByKeyword_UnpalletizedFilter` — verifies "Unpalletized" calls `findByKeywordAndParcelUnpalletized`, returns state text "Packed"
- `testGetParcelMonitorViewByKeyword_NullFilterDefaultsToAll` — verifies null parcelFilter defaults to "All" behavior (no NPE)
- `testGetParcelMonitorViewByKeyword_EmptyResult` — verifies empty result handling

### Build & Test Results
- **Build**: SUCCESS (mvn clean package -DskipTests)
- **Parcel filter tests**: 5/5 PASSED
- **Pre-existing failures**: 2 unrelated ReplenishOrder tests fail due to test data array size mismatch (index 16 out of bounds on 16-element array) — not caused by these changes
