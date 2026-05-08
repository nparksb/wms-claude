# SBDEV-2102: Putaway Fails Due to Unit Load Not Recognized and Gets Stuck to User

**Ticket:** SBDEV-2102
**Priority:** Urgent (Release Blocking) | **Points:** 5 | **Type:** Bug (Regression)
**Assignees:** David Oppenheim, Nam Park, Arden Latraca
**Date:** 2026-04-10
**Status:** IMPLEMENTED — All 7 fixes applied (A-F + Bug 6), 50/50 unit tests passing
**Updated:** 2026-04-13 (v3 — Bug 6 fixed: duplicate `sendToNirvana` in `storeBoxOnLocation` FLOWBIN branch caused `StaleObjectStateException`, unmasked by Bug 4 fix)

---

## 1. Problem Statement

Pallets (unit loads) created during receiving are correctly placed into the putaway lane, but cannot be processed in the putaway workflow. Users see "Unit Load Not Found" on the first scan, then "Container/Pallet not in inbound lane" on retry. The unit load becomes stuck/locked to the user, blocking all putaway operations.

---

## 2. Root Cause Analysis

There are **three compounding bugs** in `MobilePutAwayService.findUnitLoad()` (lines 68-125). Each alone could cause the reported symptoms; together they create an unrecoverable state.

### Bug 1: Location `.equals()` Comparison Instead of ID Comparison (PRIMARY)

**File:** `MobilePutAwayService.java:90`

```java
if (!storageLocation.equals(putAwayLane)) {
```

The `Location.equals()` method (Location.java:232-238) compares by `xpos`, `ypos`, `zpos`, and `name`:
```java
return xpos.equals(location.xpos) && ypos.equals(location.ypos)
    && Objects.equals(zpos, location.zpos) && name.equals(location.name);
```

Per the project's critical rules in CLAUDE.md: **"Only `Location` has `equals`/`hashCode` (and it's broken)."** The `hashCode()` includes `id` and many other fields, violating the contract with `equals()`. Two Location objects loaded separately from the same DB row can potentially fail `.equals()` if their coordinate fields differ due to Hibernate session cache behavior.

**Line 84 already uses the correct ID-based pattern:**
```java
!storageLocation.getId().equals(locationRepository.findByName(WmsConstants.STORAGE_LOCATION_CLEARING).get().getId())
```

But lines 90 and 92 use the broken `.equals()`.

### Bug 2: Transfer Before Validation (CAUSES "STUCK" STATE)

**File:** `MobilePutAwayService.java:102-103`

The code flow in `findUnitLoad()` is:

```
Line 75:  Look up unit load by label               ← can fail (Bug 3)
Line 82:  Get unit load's current storage location
Line 84:  Validate location area (inbound area?)     ← can throw
Line 90:  Validate location is putaway lane          ← can throw (Bug 1)
Line 102: Transfer unit load to user's location      ← MODIFIES STATE
Line 105: Check if pallet or box                     ← can throw
```

Commit `c455937` (SBDEV-1460) **re-enabled** lines 102-103 which were previously commented out in commit `c681796`. This transfer happens AFTER validation at lines 84-97, so Bug 1 would prevent reaching it. However, there's a critical timing issue:

**On second scan attempt:** After the first scan fails at line 90 (Bug 1), the user tries again. If the location data has been cached or the equals comparison works intermittently, the code reaches line 103 and transfers the unit load to the user's location. Now the unit load is NO LONGER in the putaway lane. Any subsequent attempt checks line 90 again — the unit load's `storagelocationId` now points to the user's location (not putaway lane), so it fails with "unitLoadNotInPutAwayLane". The unit load is effectively stuck.

**The `storePalletBackOnPutawayLane()` recovery method (line 151-161) also uses `findByLabelid()` (case-sensitive — Bug 3) and has no error handling if the lookup fails.**

### Bug 3: Case-Sensitive Label Lookup (CONTRIBUTES TO "NOT FOUND")

**File:** `MobilePutAwayService.java:75`

```java
Optional<Unitload> unitLoadOpt = unitloadRepository.findByLabelid(putAwayMobileDto.getUnitLoadName());
```

Uses `findByLabelid()` which is case-sensitive. The repository also has `findByLabelidIgnoreCase()` (line 60-62 of UnitloadRepository), and `MobileReplenishService` (line 763-765) already uses the fallback pattern:

```java
unitloadOpt = unitloadRepository.findByLabelid(label);
if (!unitloadOpt.isPresent()) {
    unitloadOpt = unitloadRepository.findByLabelidIgnoreCase(label);
}
```

`MobilePutAwayService` does NOT use this fallback — it fails immediately if the case doesn't match, producing the "Unit Load Not Found" error.

**This same case-sensitive issue exists at 5 other locations in the file:** lines 130, 154, 166, 305, 394.

---

## 3. The Regression Chain

| Commit | Date | Change | Effect |
|--------|------|--------|--------|
| `a685e07` | Initial | Lines 102-103 active (transfer + validate) | Worked if equals worked |
| `c681796` | 2025-07-16 | **Commented out** lines 102-103 (removed user lock) | Putaway worked but no user assignment |
| `c455937` | 2025-07-25 | **Re-enabled** lines 102-103 + added `storePalletBackOnPutawayLane` | Reintroduced the stuck-state bug; `.equals()` issue was always latent |

The `.equals()` bug (Bug 1) was always present but was masked when the transfer (lines 102-103) was commented out — the validation would fail but the unit load would remain on the putaway lane, so a retry could succeed. With the transfer re-enabled, a partial success (validation passes, transfer completes, then something fails later or on retry) creates an unrecoverable state.

---

## 4. Architecture Overview

### Putaway Scan Flow

```
Mobile Device → PutawayController.scanPallet("IN-000364")
  → MobilePutAwayService.findUnitLoad(dto)
    → unitloadRepository.findByLabelid("IN-000364")           // Bug 3: case-sensitive
    → locationRepository.findById(unitLoad.storagelocationId)
    → Validate: locationArea.useforgoodsin?                     // line 84
    → Validate: storageLocation.equals(putAwayLane)?            // Bug 1: broken equals
    → Transfer: unitload → user location                        // Bug 2: before all checks
    → Check: pallet or box?
  ← Return dto or error
```

### Key Files

| File | Lines | Role |
|------|-------|------|
| `MobilePutAwayService.java` | 68-125 | `findUnitLoad()` — main scan logic with all 3 bugs |
| `MobilePutAwayService.java` | 151-161 | `storePalletBackOnPutawayLane()` — recovery method |
| `PutawayController.java` | 36-59 | HTTP endpoint — catches exceptions but doesn't release locks |
| `UnitloadRepository.java` | 57-62 | `findByLabelid()` and `findByLabelidIgnoreCase()` |
| `Location.java` | 232-243 | Broken `equals()`/`hashCode()` |
| `UnitloadBusinessService.java` | 76-146 | `transferUnitLoadToLocation()` — moves unit load |

---

## 5. Fix Design

### Fix A: Replace `.equals()` with ID Comparison (Bug 1 — Primary)

**File:** `MobilePutAwayService.java:90-96`

```java
// Before (broken):
if (!storageLocation.equals(putAwayLane)) {
    Location inboundWorkStation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_INBOUND_NAME).get();
    if (storageLocation.equals(inboundWorkStation)) {

// After (correct):
if (!storageLocation.getId().equals(putAwayLane.getId())) {
    Location inboundWorkStation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_INBOUND_NAME).get();
    if (storageLocation.getId().equals(inboundWorkStation.getId())) {
```

This matches the existing correct pattern at line 84.

### Fix B: Move Transfer AFTER All Validation (Bug 2 — Prevents Stuck State)

**File:** `MobilePutAwayService.java:68-125`

Reorder `findUnitLoad()` so the transfer to user location (line 102-103) happens AFTER all validation AND after the pallet/box type check:

```java
public PutAwayMobileDto findUnitLoad(final PutAwayMobileDto putAwayMobileDto) throws BusinessException, FacadeException {
    // 1. Validate input
    if (putAwayMobileDto.getUnitLoadName() == null || putAwayMobileDto.getUnitLoadName().isEmpty()) {
        throw new BusinessException("entityNotFoundForName", ...);
    }

    // 2. Look up unit load (with case-insensitive fallback — Fix C)
    Optional<Unitload> unitLoadOpt = unitloadRepository.findByLabelid(putAwayMobileDto.getUnitLoadName());
    if (!unitLoadOpt.isPresent()) {
        unitLoadOpt = unitloadRepository.findByLabelidIgnoreCase(putAwayMobileDto.getUnitLoadName());
    }
    Unitload unitLoad = unitLoadOpt.orElse(null);
    if (unitLoad == null) {
        throw new BusinessException("entityNotFoundForName", ...);
    }

    // 3. Validate location (all checks BEFORE transfer)
    Location storageLocation = locationRepository.findById(unitLoad.getStoragelocationId()).get();
    LocationArea locationArea = locationAreaRepository.findById(storageLocation.getAreaId()).get();
    if (!locationArea.getUseforgoodsin() && !storageLocation.getId().equals(
            locationRepository.findByName(WmsConstants.STORAGE_LOCATION_CLEARING).get().getId())) {
        throw new BusinessException("unitloadNotInInboundArea", ...);
    }

    Location putAwayLane = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE).get();
    if (!storageLocation.getId().equals(putAwayLane.getId())) {  // Fix A: ID comparison
        Location inboundWorkStation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_INBOUND_NAME).get();
        if (storageLocation.getId().equals(inboundWorkStation.getId())) {  // Fix A
            throw new BusinessException("unitLoadStillOnInboundWorkstation", ...);
        } else {
            throw new BusinessException("unitLoadNotInPutAwayLane", ...);
        }
    }

    // 4. Validate pallet/box type BEFORE transfer
    boolean isPallet = unitloadTypeRepository.findById(unitLoad.getTypeId()).get()
        .equals(unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PALLET).get());
    boolean isBox = !isPallet && unitloadTypeRepository.findById(unitLoad.getTypeId()).get()
        .equals(unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_BOX).get());

    if (isPallet) {
        if (unitloadRepository.findByCarrierunitloadId(unitLoad.getId()).isEmpty()) {
            throw new BusinessException("emptyPalletNotSuitableForPutAway", ...);
        }
    } else if (!isBox) {
        throw new BusinessException("entityNotFoundForName", ...);
    }

    // 5. All validation passed — NOW transfer to user location (safe)
    Location location = locationRepository.findByName(SecurityContextUtils.getUserName()).get();
    unitloadBusinessService.transferUnitLoadToLocation(unitLoad, location, false,
        WmsConstants.CODE_ASSIGN_PUT_AWAY, null, null);

    if (isPallet) {
        putAwayMobileDto.setUnitLoadIsPallet(true);
    } else {
        putAwayMobileDto.setUnitLoadIsBox(true);
    }
    return putAwayMobileDto;
}
```

### Fix C: Add Case-Insensitive Label Fallback (Bug 3 — Prevents "Not Found")

Apply the `MobileReplenishService` pattern to ALL 6 label lookups in `MobilePutAwayService`:

| Line | Method | Current | Change |
|------|--------|---------|--------|
| 75 | `findUnitLoad` | `findByLabelid()` | Add `findByLabelidIgnoreCase()` fallback |
| 130 | `storePalletOnLocation` | `findByLabelid().get()` | Add fallback + null check |
| 154 | `storePalletBackOnPutawayLane` | `findByLabelid()` | Add fallback |
| 166 | `calculatePutAwayList` | `findByLabelid().get()` | Add fallback + null check |
| 305 | `updateCurrentItemDataUnitLoadList` | `findByLabelid()` | Add fallback |
| 394 | `storeBoxOnLocation` | `findByLabelid()` | Add fallback |

### Fix D: Add Error Recovery in Controller (Defense in Depth)

**File:** `PutawayController.java:36-59`

Add a try-finally that returns the unit load to the putaway lane if an error occurs after the transfer:

```java
@GetMapping(path= "/scanPallet/{input}", produces = "application/json")
public ResponseEntity<Object> requestLocation(@PathVariable("input") String input) {
    PutAwayMobileDto dto = new PutAwayMobileDto();
    dto.setUnitLoadName(input);
    try {
        dto = mobilePutAwayService.findUnitLoad(dto);
    } catch (BusinessException e) {
        // Attempt to release the unit load if it was transferred
        try {
            mobilePutAwayService.storePalletBackOnPutawayLane(dto);
        } catch (Exception releaseEx) {
            LOG.warn("Failed to release unit load back to putaway lane", releaseEx);
        }
        errors.add(getErrorMessage("Runtime Error", e.getMessage()));
    } catch (FacadeException fe) {
        try {
            mobilePutAwayService.storePalletBackOnPutawayLane(dto);
        } catch (Exception releaseEx) {
            LOG.warn("Failed to release unit load back to putaway lane", releaseEx);
        }
        errors.add(getErrorMessage("Runtime Error", fe.getLocalizedMessage()));
    }
    // ... rest unchanged
}
```

> **Note:** With Fix B (transfer moved after all validation), this safety net should rarely trigger, but it prevents stuck states from any future regressions.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|------------|-------------|
| `MobilePutAwayService.java` | Modify | Fix A: ID comparison at lines 90, 92; Fix B: reorder validation before transfer; Fix C: case-insensitive fallback at 6 locations |
| `PutawayController.java` | Modify | Fix D: error recovery to release unit load on failure |

**No database migration needed. No frontend changes needed.**

---

## 7. Implementation Steps

### Step 1: Fix `.equals()` → `.getId().equals()` (Bug 1)
- Replace `storageLocation.equals(putAwayLane)` with `storageLocation.getId().equals(putAwayLane.getId())` at line 90
- Replace `storageLocation.equals(inboundWorkStation)` with `storageLocation.getId().equals(inboundWorkStation.getId())` at line 92

### Step 2: Reorder findUnitLoad() — Validation Before Transfer (Bug 2)
- Move lines 102-103 (transfer to user location) to AFTER the pallet/box type check (after line 123)
- Restructure the pallet/box checks to run before the transfer

### Step 3: Add Case-Insensitive Label Fallback (Bug 3)
- At each of the 6 `findByLabelid()` calls, add fallback to `findByLabelidIgnoreCase()`
- Follow the MobileReplenishService pattern (lines 763-765)

### Step 4: Add Error Recovery in PutawayController (Fix D)
- Add try-catch around `findUnitLoad()` that calls `storePalletBackOnPutawayLane()` on failure

### Step 5: Build and Test
- `mvn clean package -DskipTests` — verify compilation
- `mvn test` — verify no regressions
- Manual test: receive inventory → complete receiving → scan pallet in putaway → verify success

---

## 8. Testing Plan

### Unit Tests
- [ ] `findUnitLoad()` succeeds when unit load IS on putaway lane (happy path)
- [ ] `findUnitLoad()` with case-mismatched label falls back to case-insensitive lookup
- [ ] `findUnitLoad()` throws "entityNotFoundForName" for truly nonexistent labels
- [ ] `findUnitLoad()` throws "unitLoadNotInPutAwayLane" when unit load is elsewhere
- [ ] `findUnitLoad()` does NOT transfer unit load to user location if validation fails
- [ ] After failed `findUnitLoad()`, unit load remains on putaway lane (not stuck)
- [ ] Retry after failed scan succeeds

### Integration Tests
- [ ] End-to-end: receiving → putaway lane → scan pallet → calculate putaway → store
- [ ] Cart-type containers (not just pallets)
- [ ] Newly created pallets during receiving

### Regression Tests
- [ ] Putaway still assigns unit load to user after successful scan
- [ ] `storePalletBackOnPutawayLane()` correctly releases unit load
- [ ] `storePalletOnLocation()` works for pallet storage
- [ ] `storeBoxOnLocation()` works for box storage to flowbin and overstock
- [ ] `calculatePutAwayList()` correctly builds putaway item list

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Reordering `findUnitLoad()` changes behavior | Medium | Transfer still happens, just later in the method — all downstream code receives the same state |
| Case-insensitive lookup returns wrong unit load | Low | `findByLabelidIgnoreCase` uses `LIMIT 1` — labels are unique in practice; case differences are from scan input vs DB storage |
| `storePalletBackOnPutawayLane` fails during error recovery | Low | Wrapped in try-catch in the controller; logged but not re-thrown |
| UnitloadType `.equals()` comparison (line 105, 117) | Low | UnitloadType entities are looked up by ID and name in the same session — should be same reference. But should be audited in a follow-up ticket |

---

## 10. Implementation Status (2026-04-10)

### Changes Applied

| Fix | File | Status |
|-----|------|--------|
| A: `.equals()` → `.getId().equals()` | `MobilePutAwayService.java:97,99` | ✅ Done |
| B: Reorder validation before transfer | `MobilePutAwayService.java:68-133` | ✅ Done |
| C: Case-insensitive label fallback (6 sites) | `MobilePutAwayService.java:75,138,168,184,328,421` | ✅ Done |
| D: Error recovery in controller | `PutawayController.java:46-50` | ✅ Done |

### Test Results

- **48/48 unit tests passing** in `MobilePutAwayServiceUnitTest`
- **7 new tests added** for SBDEV-2102:
  - `findUnitLoad_CaseMismatch_FallsBackToIgnoreCase` — verifies case-insensitive fallback
  - `findUnitLoad_NotFoundEvenIgnoreCase_ThrowsBusinessException` — both lookups miss
  - `findUnitLoad_SameLocationDifferentObjectRef_SucceedsWithIdComparison` — proves ID comparison works where `.equals()` would fail
  - `findUnitLoad_FailedValidation_DoesNotTransferUnitLoad` — verifies transfer NOT called on failure
  - `findUnitLoad_EmptyPallet_ThrowsBusinessException_NoTransfer` — updated: verifies no transfer on empty pallet
  - `findUnitLoad_UnitloadTypeNotPalletNotBox_ThrowsBusinessException_NoTransfer` — updated: verifies no transfer on unknown type
  - `storePalletBackOnPutawayLane_CaseMismatch_FallsBackToIgnoreCase` — recovery with case mismatch
- **Build succeeds**: `mvn clean package -DskipTests` ✅
- **Pre-existing failures**: 2 errors + 1 failure in `ViewDtoServiceUnitTest` (unrelated to SBDEV-2102, confirmed same on clean branch)

### Remaining

- [ ] Fix Bug 4 (UnitloadType `.equals()`) and Bug 5 (Location `.equals()` in box storage)
- [ ] Manual end-to-end test: receiving → putaway lane → scan → putaway
- [ ] QA verification with example unit loads IN-000420, IN-000364, IN-000608

---

## 11. Bug 4: UnitloadType Reference Equality Fails with OSIV Disabled (v2 — 2026-04-10)

### Why Fixes A-D Did Not Resolve the Issue

The original plan flagged `UnitloadType .equals()` as "Low risk — should be same reference" (Section 9, Risk table). This assessment was **wrong** because it assumed OSIV was enabled. In production, `spring.jpa.open-in-view=false` is set in `application_dev.properties` (the deployed profile), which means:

- Each repository call gets its **own EntityManager/session**
- Hibernate's L1 (session) cache is **NOT shared** between calls
- Two lookups for the same entity return **different Java object instances**
- `Object.equals()` (reference equality) **always returns `false`**

### The Bug

**File:** `MobilePutAwayService.java:107-110`

```java
boolean isPallet = unitloadTypeRepository.findById(unitLoad.getTypeId()).get()
    .equals(unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PALLET).get());
boolean isBox = !isPallet && unitloadTypeRepository.findById(unitLoad.getTypeId()).get()
    .equals(unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_BOX).get());
```

- `UnitloadType` has **no custom `equals()`** — uses `Object.equals()` (reference equality)
- `MobilePutAwayService` has **no `@Transactional`** — no shared persistence context
- With OSIV disabled: `findById()` and `findByName()` use separate EntityManagers → different object instances
- Result: `isPallet` is **always `false`**, `isBox` is **always `false`**
- Line 117 **always throws** `entityNotFoundForName` — putaway is **100% broken**

### Why the Error Message is Misleading

Line 117:
```java
throw new BusinessException("entityNotFoundForName", Unitload.class.getSimpleName(), putAwayMobileDto.getUnitLoadName());
```

This throws "No entity Unitload found for name='IN-000420'" — but the unit load WAS found (line 76-79 succeeded). The error is actually a **type check failure**, not a lookup failure. The error message is reused from the not-found case, making it look like the unit load doesn't exist.

### Why the Unit Load Gets Locked to User

With the SBDEV-2102 fix (transfer after validation), the transfer at line 122-123 is NEVER reached because line 117 always throws first. The unit load stays on PutAwayLane.

However, the controller's error recovery (Fix D, line 48-52) calls `storePalletBackOnPutawayLane(dto)` which finds the unit load and transfers it to PutAwayLane — a no-op since it's already there. **The unit load should NOT be locked to the user with the current code.**

If the user observes the unit load locked to the user location, this is likely from a **previous run** before Fix B was deployed (when the transfer happened before the type check). The "Move Unitload" recovery does not fix the underlying putaway scan issue — the type check still fails every time.

### Fix E: Replace UnitloadType `.equals()` with ID Comparison (Bug 4 — CRITICAL)

**Confidence: 99%** — Directly explains 100% failure rate, confirmed by OSIV=false + no @Transactional + no custom equals().

**File:** `MobilePutAwayService.java:107-110`

```java
// Before (ALWAYS fails with OSIV disabled — different object references):
boolean isPallet = unitloadTypeRepository.findById(unitLoad.getTypeId()).get()
    .equals(unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PALLET).get());
boolean isBox = !isPallet && unitloadTypeRepository.findById(unitLoad.getTypeId()).get()
    .equals(unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_BOX).get());

// After (correct — compares by database ID):
boolean isPallet = unitLoad.getTypeId().equals(
    unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PALLET).get().getId());
boolean isBox = !isPallet && unitLoad.getTypeId().equals(
    unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_BOX).get().getId());
```

**Why this is better than just `.getId().equals()`:** We already have `unitLoad.getTypeId()` — no need to do `findById(typeId)` just to get the same ID back. This eliminates 2 unnecessary DB lookups.

### Fix F: Replace Location `.equals()` with ID Comparison in Box Storage (Bug 5)

**Confidence: 95%** — Same root cause as Bug 1 (Location.equals() is known broken per CLAUDE.md).

**File:** `MobilePutAwayService.java:395`

```java
// Before (broken Location.equals()):
if (!assignedLocation.equals(location)) {

// After (correct ID comparison):
if (!assignedLocation.getId().equals(location.getId())) {
```

This is in the box storage flow — validates that the scanned location matches the fixed assignment. With broken `Location.equals()`, legitimate fixed-assignment locations could be incorrectly rejected.

### Implementation Steps

1. **Fix E:** Replace UnitloadType `.equals()` with ID comparison at lines 107-110 (2 lines changed)
2. **Fix F:** Replace Location `.equals()` with ID comparison at line 395 (1 line changed)
3. **Add unit test:** Verify `findUnitLoad` succeeds when UnitloadType instances are different object refs with the same ID (simulates OSIV=false)
4. **Build & test:** `mvn clean package`

### Updated File Change Summary

| Fix | File | Lines | Status |
|-----|------|-------|--------|
| A: Location `.equals()` → `.getId().equals()` | `MobilePutAwayService.java:97,99` | ✅ Done |
| B: Reorder validation before transfer | `MobilePutAwayService.java:68-133` | ✅ Done |
| C: Case-insensitive label fallback (6 sites) | `MobilePutAwayService.java` | ✅ Done |
| D: Error recovery in controller | `PutawayController.java:46-52` | ✅ Done |
| **E: UnitloadType `.equals()` → ID comparison** | **`MobilePutAwayService.java:107-110`** | **✅ Done** |
| **F: Location `.equals()` → ID comparison (box storage)** | **`MobilePutAwayService.java:395`** | **✅ Done** |

### Test Results (v2)

- **50/50 unit tests passing** in `MobilePutAwayServiceUnitTest`
- **9 total SBDEV-2102 tests** (7 from v1 + 2 new for Bug 4):
  - `findUnitLoad_OsivDisabled_DifferentUnitloadTypeRefs_SucceedsWithIdComparison` — pallet type with separate object refs (OSIV=false simulation)
  - `findUnitLoad_OsivDisabled_BoxType_DifferentRefs_SucceedsWithIdComparison` — box/Case type with separate object refs (OSIV=false simulation)
- **Full suite: 1616 tests, 0 new failures** (2 pre-existing errors in ViewDtoServiceUnitTest, confirmed same on clean branch)
- **Build succeeds**: `mvn clean package -DskipTests` ✅

### Root Cause Chain

```
OSIV disabled (application_dev.properties)
  → No shared EntityManager across repository calls
    → MobilePutAwayService has no @Transactional
      → findById() and findByName() use separate sessions
        → UnitloadType instances are different Java objects
          → Object.equals() (reference equality) returns false
            → isPallet = false, isBox = false (ALWAYS)
              → Line 117 throws "entityNotFoundForName" (ALWAYS)
                → Putaway is 100% broken
```

---

## 12. Bug 6: Duplicate `sendToNirvana` in Box→Flowbin Putaway (v3 — 2026-04-13)

### Why Fixes A–F Did Not Fully Resolve the Issue

Fixes A–F successfully restored the `findUnitLoad()` happy path and let users reach step 4 of the putaway flow (`storeBoxOnLocation`) for the first time in weeks. On the first real end-to-end attempt (user scans a box into a flowbin location), the backend returned HTTP 500 with this stack trace:

```
org.hibernate.StaleObjectStateException: Row was updated or deleted by another transaction
  (or unsaved-value mapping was incorrect) :
  [net.aim_ai.wms.model.Unitload#25548882]
    at org.hibernate.event.internal.DefaultMergeEventListener.entityIsDetached(...)
    at org.springframework.data.jpa.repository.support.SimpleJpaRepository.save(...)
    at UnitloadBusinessService.transferUnitLoadToLocation(UnitloadBusinessService.java:136)
    at UnitloadBusinessService.sendToNirvana(UnitloadBusinessService.java:256)
    at MobilePutAwayService.storeBoxOnLocation(MobilePutAwayService.java:452)
```

Preceding debug line:

```
start with unitloadId=25548882 carrierunitloadId=645108568 storagelocationId=52660
      to destinationLocationId=0 ignoreLock=true activityCode=SEND_TO_NIRWANA
```

### The Bug

Fixes A–F never touched `storeBoxOnLocation`. Its FLOWBIN branch (`MobilePutAwayService.java:437–453`) was:

```java
case WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN:
    Optional<FixLocationAssignment> fixedLocationAssignmentOpt =
        fixLocationAssignmentRepository.findByAssignedlocationId(location.getId());
    FixLocationAssignment fixedLocationAssignment = fixedLocationAssignmentOpt.orElse(null);
    Stockunit sourceStockUnit = stockunitRepository.findByUnitloadId(unitLoad.getId()).get(0);

    if (fixedLocationAssignment == null) {
        Itemdata itemData = itemdataRepository.findById(sourceStockUnit.getItemdataId()).get();
        fixedLocationAssignment = fixLocationAssignmentService.createFixedLocationAssignment(location, itemData);
    }

    Unitload assignedUnitLoad = unitloadRepository.findById(fixedLocationAssignment.getAssignedunitloadId()).get();
    stockunitBusinessService.transferStockToUnitLoad(
        sourceStockUnit, assignedUnitLoad, sourceStockUnit.getAmount(),
        WmsConstants.CODE_PUT_AWAY, null, null,
        /*ignoreLock*/ false, /*removeUnitLoadIfEmpty*/ true);          // (A)
    // send the current unit load to Nirvana when the unit load is moved to the flowbin.
    // flowbin is treated as a unit load
    unitloadBusinessService.sendToNirvana(unitLoad, WmsConstants.CODE_SEND_TO_NIRVANA, null, null); // (B) ← BUG
    break;
```

Call (A) passes `removeUnitLoadIfEmpty = true`. `StockunitBusinessService.transferStockToUnitLoad` (line 211–222) already has the nirvana-send baked in for that flag:

```java
if (destinationStockUnit == null) {
    sourceStockunit.setUnitloadId(destinationUnitload.getId());
    destinationStockUnit = stockunitRepository.save(sourceStockunit);
    stockrecordService.recordTransferStockUnit(...);

    List<Stockunit> sourceStockunitList = stockunitRepository.findByUnitloadId(sourceUnitload.getId());
    List<Unitload>  sourceUnitLoadList  = unitloadRepository.findByCarrierunitloadId(sourceUnitload.getId());

    if (removeUnitLoadIfEmpty && sourceStockunitList.isEmpty() && sourceUnitLoadList.isEmpty()) {
        unitloadBusinessService.sendToNirvana(sourceUnitload, WmsConstants.CODE_SEND_TO_NIRVANA, orderNumber, comment);
    }
}
```

So the box's source UL is sent to nirvana **inside** `transferStockToUnitLoad`. When control returns to `storeBoxOnLocation` line 452, (B) sends *the same box* to nirvana a second time — using a now-**stale Java reference** (loaded at line 424 in its own mini-session; `storeBoxOnLocation` is not `@Transactional` and OSIV is disabled).

Inside the second `sendToNirvana` call:

1. The early-out at `UnitloadBusinessService.java:250` (`if (nirvanaLocation.getId().equals(unitload.getStoragelocationId())) return;`) **does not fire** because the stale reference still carries the pre-nirvana `storagelocationId` (the user's location, `52660` in the log).
2. Line 256 calls `transferUnitLoadToLocation(unitload, nirvanaLocation, true, ...)`.
3. Line 133–136 enters the `if (carrierunitloadId != null)` branch because the stale reference still has `carrierunitloadId=645108568` (the DB row has already been updated to NULL by the first sendToNirvana).
4. `unitloadRepository.save(unitload)` at line 136 performs `EntityManager.merge()` on a detached entity whose `@Version` is two increments behind the DB.
5. Hibernate throws `StaleObjectStateException` → `ObjectOptimisticLockingFailureException` → HTTP 500.

### Evidence from the Debug Log

| Field | Value in log | What it should be after first `sendToNirvana` | Verdict |
|-------|-------------|----------------------------------------|---------|
| `unitloadId` | `25548882` | same | ✓ |
| `carrierunitloadId` | `645108568` | `NULL` | **stale reference** |
| `storagelocationId` | `52660` (user location) | nirvana location id | **stale reference** |
| `destinationLocationId` | `0` | nirvana location id (`0`) | ✓ — nirvana record in this tenant genuinely has id=0 (confirmed with DBA) |
| `activityCode` | `SEND_TO_NIRWANA` | same | ✓ — confirms this is the SECOND call from line 452 |

### Why the Plan Unmasked This — Not Caused It

The double-`sendToNirvana` has existed since this FLOWBIN branch was written. It was latent because **Bug 4** (UnitloadType reference-equality) made `findUnitLoad` 100% broken — no user could ever reach step 4 of the putaway flow. The SBDEV-2102 fix repaired the earlier failure, which surfaced the next dormant defect in the chain. This is expected behavior for layered fixes, not a regression.

### Fix 6: Delete the Duplicate `sendToNirvana` Call

**Confidence: 99%** — Stack trace, debug log, and `transferStockToUnitLoad` contract together prove the mechanism. Mocked unit tests confirm `storeBoxOnLocation` never needs to call `sendToNirvana` directly.

**File:** `MobilePutAwayService.java:437–453`

```java
// Before (buggy):
stockunitBusinessService.transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad,
    sourceStockUnit.getAmount(), WmsConstants.CODE_PUT_AWAY, null, null, false, true);
// send the current unit load to Nirvana when the unit load is moved to the flowbin. flowbin is treated as a unit load
unitloadBusinessService.sendToNirvana(unitLoad, WmsConstants.CODE_SEND_TO_NIRVANA, null, null);
break;

// After (fixed):
// SBDEV-2102 follow-up (Bug 6): transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true) already
// sends the source unit load to nirvana when it becomes empty. Calling sendToNirvana again here
// with the now-stale local reference triggered StaleObjectStateException on the second merge.
stockunitBusinessService.transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad,
    sourceStockUnit.getAmount(), WmsConstants.CODE_PUT_AWAY, null, null, false, true);
break;
```

### Alternatives Considered (and Rejected)

| Option | Change | Why not chosen |
|--------|--------|----------------|
| **Option 2:** Pass `removeUnitLoadIfEmpty=false` and keep the explicit sendToNirvana, but reload `unitLoad` fresh by id before line 452 | Shifts authority to `storeBoxOnLocation` | Larger diff; duplicates the "empty source UL ⇒ nirvana" decision in two places; still fragile if future callers forget the reload. |
| **Option 3:** Harden `UnitloadBusinessService.transferUnitLoadToLocation` to reload the entity at method entry (matching the sibling pattern at lines 153 and 215) | One-time class-wide fix protecting all ~20 callers | Valuable as tech-debt cleanup but out of scope for an urgent release blocker; promoted to a follow-up ticket. |

### Single-Tenant Deployment Note

v1/wms-api is **single-tenant by deployment** — every client runs their own JVM against their own PostgreSQL. This eliminates the multi-tenant/`@PostConstruct` hypothesis for the `destinationLocationId=0` signal and confirmed (via DBA) that the nirvana `Location` row in every client DB has `id=0` by convention. `destinationLocationId=0` is therefore **not** a bug — it's the expected nirvana identifier. No changes needed on that axis.

### Test Changes

**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePutAwayServiceUnitTest.java`

Two existing tests for `storeBoxOnLocation` had to be corrected because their previous assertions required the buggy second `sendToNirvana` call:

| Before | After | Change |
|--------|-------|--------|
| `storeBoxOnLocation_FlowbinNoFixAssignment_CreatesAssignmentAndSendsToNirvana` | `storeBoxOnLocation_FlowbinNoFixAssignment_CreatesAssignmentAndTransfersStock` | Renamed. Replaced `verify(unitloadBusinessService).sendToNirvana(...)` with `verify(unitloadBusinessService, never()).sendToNirvana(any(), anyString(), any(), any())`. |
| `storeBoxOnLocation_FlowbinWithFixAssignment_TransfersStockAndSendsToNirvana` | `storeBoxOnLocation_FlowbinWithFixAssignment_TransfersStockOnly` | Same change. |

Both tests continue to assert that `stockunitBusinessService.transferStockToUnitLoad(...)` is called with `removeUnitLoadIfEmpty=true`, delegating the nirvana-send responsibility to that method. These now serve as regression tests for Bug 6 — if a future change re-introduces a direct `sendToNirvana` call in `storeBoxOnLocation`, both will fail.

### Test Results (v3)

- **50/50 tests passing** in `MobilePutAwayServiceUnitTest` (unchanged count; two test names renamed, assertions flipped to `never()`)
- **Build succeeds**: `mvn test -Dtest=MobilePutAwayServiceUnitTest` ✅

### Follow-up Tickets Created

1. **Harden `UnitloadBusinessService.transferUnitLoadToLocation`** — reload `unitload` fresh by id at method entry to match the sibling pattern in `transferUnitLoadToCarrier` (line 153) and `processTransfer` (line 215). Protects all ~20 callers from stale-reference mistakes. Low-risk, mechanical change. Option 3 from the investigation.

### Root Cause Chain (Bug 6)

```
MobilePutAwayService.storeBoxOnLocation (not @Transactional, OSIV=false)
  → line 424: loads unitLoad in mini-session S1 (version v0)            [Java ref stays, S1 closes]
  → line 450: transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true)
       → opens @Transactional session S2
       → moves sourceStockunit to destination → sourceUnitload now empty
       → unitloadBusinessService.sendToNirvana(sourceUnitload_fresh)     [DB row → v2]
       → S2 commits
  → line 452: sendToNirvana(unitLoad, ...)    ← STALE REF still at v0
       → early-out check sees stale storagelocationId → does NOT return
       → transferUnitLoadToLocation(unitLoad, nirvana, ...)
           → @Transactional session S3
           → line 136: unitloadRepository.save(unitLoad)  ← merge(v0) vs DB(v2)
             → Hibernate StaleObjectStateException → HTTP 500
```
