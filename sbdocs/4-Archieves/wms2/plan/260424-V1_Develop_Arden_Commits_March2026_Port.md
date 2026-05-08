# V1 Develop-Arden Branch Commits (March 2026) — Port to V2

- **Date:** 2026-03-21
- **Status:** Implemented — All 6 PORT items applied. 3739 tests, 0 failures, 39 pre-existing H2/integration errors.
- **Priority:** Mixed (2 High, 1 Low, 3 Medium — new features)
- **V1 Source:** `../wms-api` develop-arden branch, commits after 2026-03-01

---

## Summary

23 commits on v1's `develop-arden` branch since March 1st, 2026. After deep analysis:

- **8 overlap with `develop` branch** — already analyzed in `260424-V1_Develop_Commits_March2026_Port.md`
- **9 additional commits already in v2** — reservation leak fixes, boxtype save, receiving architecture, cleanup/tests
- **6 items need porting** — 2 bug fixes + 4 location CRUD API endpoints (new feature)

---

## Already in V2 (No Action Needed) — 17 commits

### Overlap with `develop` branch (8 commits — see previous port plan)

| Commit | Description |
|--------|-------------|
| `32ff742` | Re-read detached entities in processPick |
| `0e55910` | Compare by ID in OrderRestController |
| `0f8deca` | Picking OMS status race condition fix |
| `536cab1` | Remove REQUIRES_NEW from recalculateForItem |
| `7f3c021` | Persist advice state on close |
| `740130a` | Persist replenish order state on resetOrder |
| `9c78f1c` | Connection pool exhaustion fix phase 1 |
| `becd8a9` | Test case error fix |

### Reservation leak fixes — all 4 bugs already fixed in v2

| V1 Commit | Bug | V2 Status | V2 Evidence |
|-----------|-----|-----------|-------------|
| `9eeace7` | #1: fixPickingPosition unreserve original | Already in v2 | `PickingorderPositionService.java:87-178` — unreserve + same-stock guard + @Transactional |
| `9eeace7` | #2: checkAndCleanUp direct reservedamount manipulation | Already in v2 | `CustomerorderService.java:260-272` — uses changeReservedAmount API + null guards |
| `9eeace7` | #3: cancelReplenishmentOrder releases entire stock reservation | Already in v2 | `ReplenishorderService.java:217` — uses `requestedamount.negate()` (not stock's full amount) |
| `9eeace7` | #4: redirectSource without @Transactional | Already in v2 | `ReplenishorderService.java:96,117,169` — all have `@Transactional(value = "tenantTransactionManager")` |
| `9eeace7` | Constants CODE_FIX_PICK_POSITION, CODE_CLEANUP_PICKING_POSITION | Already in v2 | `WmsConstants.java:827,870` |
| `9eeace7` | PickingorderPositionRepository delete blocking | Already in v2 | Uses `@RestResource(exported = false)` annotations (equivalent to NoDeletePagingAndSortingRepository) |

### Other already-ported commits

| Commit | Description | V2 Status |
|--------|-------------|-----------|
| `c907066` | Persist boxtype for received unitloads | Already in v2 — `UnitloadService.createUnitload()` sets boxtypeId before initial save |
| `542ddd4` | Receiving stockunit unitload error | N/A — v2 has different architecture, always creates new unitloads per case |
| `e408bef` | Remove duplicate methods/variables | Already clean in v2 |
| `2e64361` | Test mocks for processPick | Already handled — v2 tests use `findByIdForUpdate` |
| `2ebc2ec` | Test checked exception declaration | Test-only, v2 tests already correct |
| `c789a26` | Reservation leak plan/review docs | Documentation only |
| `d6b3f32` | Docker image workflow formatting | CI only |
| `3583b69` | Workflow blank line removal | CI only |

---

## Needs Porting — 6 Items

### Phase 1 — Bug Fixes (HIGH priority)

#### PORT-1: Fix search by SKU in parcel picking screen (`95c24e7`)

**File:** `src/main/java/net/aim_ai/wms/repo/jpa/OrderDetailMonitorViewRepository.java`
**Lines:** 17-20 (findByKeyword) and 23-27 (findByClientOffsetAndLimit)
**Effort:** Low (2 line changes)
**Impact:** High — users cannot search by SKU in parcel picking screen

**Problem:** The search queries use CONCAT of multiple fields for keyword matching, but `skuId` is missing from the CONCAT. The entity field exists (`OrderDetailMonitorView.java:41-42`, column `sku_id`).

**Fix for `findByKeyword` (line 17):** Add `LOWER(p.skuId)` to the JPQL CONCAT:
```java
// Add ', ' ', LOWER(p.skuId)' to the CONCAT expression
```

**Fix for `findByClientOffsetAndLimit` (line 24):** Add `LOWER(p.sku_id)` to the native SQL CONCAT.

---

#### PORT-2: Fix Inbound Notices Qty Required/Received sort (`70df507`)

**Files:**
- `src/main/java/net/aim_ai/wms/repo/jpa/AdviceRepository.java` (lines 68-112)
- `src/main/java/net/aim_ai/wms/service/ViewDtoService.java` (lines 934-982)

**Effort:** Medium (rewrite 2 native queries, update projection, simplify service)
**Impact:** High — sorting by qty columns broken, plus N+1 query performance issue

**Problem:** `qtyRequired` and `qtyReceived` are computed in Java (ViewDtoService:969-974) via a separate query per advice row. This means:
- Sorting by these fields via `Pageable` is impossible (not SQL columns)
- N+1 query performance issue on large datasets

**Fix:** Embed qty calculations as subqueries directly in the `getOpenNoticesByKeyword` and `getClosedNoticesByKeyword` native SQL queries. Add `qty_required` and `qty_received` to the `AdviceNoticeView` projection interface. Remove the per-row Java loop in ViewDtoService.

**V2 note:** Also check `ReceivingDtoViewRepository.java:37-52` for related qty subquery patterns to use as reference.

---

### Phase 2 — UX Improvement (LOW priority)

#### PORT-3: Improve cancelled parcel palletization error message (`3799382`)

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizingService.java`
**Lines:** 108-114 (scanParcel), 140-146 (scanPallet), 320-326 (scanParcelBulk)
**Effort:** Low (6 lines across 3 methods)
**Impact:** Low — functionally already works (CANCELED=800 >= FINISHED=700 is caught), but error message says "orderIsAlreadyFinished" instead of a cancellation-specific message

**Fix:** Add explicit CANCELED check before the >= FINISHED check in each method:
```java
if (order.getState() == WmsConstants.State.CANCELED) {
    throw new BusinessException("Order is cancelled and cannot be palletized");
}
```

---

### Phase 3 — New Feature: Location CRUD APIs (MEDIUM priority)

#### PORT-4: Create Location API (`f16fbab` + `b89093a`)

**File:** `src/main/java/net/aim_ai/wms/controller/LocationController.java`
**Also:** `src/main/java/net/aim_ai/wms/service/LocationService.java`
**Effort:** Medium
**Impact:** New feature — location management from UI

**V2 current state:** LocationController only has 2 GET endpoints (detailView, locationDetailsById). No write endpoints.
**V2 getLocationDetails:** Already includes `areaId`, `rackId`, `typeId` (this part of f16fbab is done).

**V2 adjustments required:**
1. **Move business logic to `LocationService`** — v1 put logic in controller. V2 pattern is controller -> service -> repository.
2. **Constructor injection** — v1 used `@Autowired` field injection. V2 must use constructor.
3. **Resolve `getNextId()`** — v1 called `locationRepository.getNextId()` which doesn't exist in v2. Either add a `@Query("SELECT nextval('seqentities')") Long getNextId()` to `LocationRepository`, or rely on JPA `@GeneratedValue` strategy.
4. **Include name validation** from `b89093a` — check `locationRepository.findByName()` before creating.
5. **Add `@Transactional(value = "tenantTransactionManager")`** to the service method.

---

#### PORT-5: Create Location Type API (`b9b791c`)

**File:** `src/main/java/net/aim_ai/wms/controller/LocationController.java`
**Also:** `src/main/java/net/aim_ai/wms/service/LocationService.java`
**Effort:** Medium
**Impact:** New feature

**Same V2 adjustments as PORT-4:** Service layer, constructor injection, getNextId resolution.
**Name validation:** Check `locationTypeRepository.findBySltname()` before creating (already exists in v2).

---

#### PORT-6: Update Location + Location Type APIs (`6fedc26`) — FIX V1 BUG

**File:** `src/main/java/net/aim_ai/wms/controller/LocationController.java`
**Also:** `src/main/java/net/aim_ai/wms/service/LocationService.java`
**Effort:** Medium
**Impact:** New feature

**V1 BUG TO FIX:** The v1 update logic has a bug — when `findByName` returns the same record (user submitting without changing name), it falls into the `if (existingByName.isPresent())` branch but `!existingByName.get().getId().equals(location.getId())` is false, so no error is added. However, `updateLoc` remains null because the update only happens in the `else` branch. Result: HTTP 200 with null body when updating a location without changing its name.

**Correct logic:**
```java
Optional<Location> existingByName = locationRepository.findByName(location.getName());
if (existingByName.isPresent() && !existingByName.get().getId().equals(location.getId())) {
    throw new BusinessException("Location already exists with name: " + location.getName());
}
// Proceed with update regardless of whether name changed
Location existing = locationRepository.findById(location.getId())
    .orElseThrow(() -> new EntityNotFoundException("Location", location.getId()));
// ... update fields and save
```

---

## Implementation Order

```
Phase 1 — Bug Fixes (implement first):
  PORT-1: SKU search fix (Low effort, 2 lines)
  PORT-2: Inbound notices sort fix (Medium effort, native SQL rewrite)

Phase 2 — UX:
  PORT-3: Cancelled parcel error message (Low effort, 6 lines)

Phase 3 — New Feature (implement together):
  PORT-4: Create location API
  PORT-5: Create location type API
  PORT-6: Update location + location type APIs (with v1 bug fix)
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| PORT-1 SKU search breaks existing keyword search | Low | Medium | Only adds a field to CONCAT — existing matches unaffected |
| PORT-2 native SQL rewrite introduces query errors | Medium | High | Test with integration tests; compare results with current Java-computed values |
| PORT-4/5/6 `getNextId()` missing in v2 | High | High | Either add the method or use JPA `@GeneratedValue` — check entity `@Id` strategy first |
| PORT-6 v1 bug carried into v2 | High | Medium | Use the corrected logic described above, not direct v1 port |
| Location CRUD missing authorization | Medium | Medium | Add `@PreAuthorize` annotations matching v2 security patterns |
