---
title: "Putaway — new SKU: blank location guidance (UI) + unguarded sysprop parse + missing @Transactional (backend)"
ticket: ""
ticket_url: ""
type: "bug"
priority: "high"
status: "draft"
project: ["wms1"]
version: ""
requester: ""
created: "2026-04-27"
updated: "2026-04-27"
related: ["260427-putaway-unitloadlist-undefined-crash.md", "../../../4-Archieves/wms1/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md"]
tags:
  - plan
  - putaway
  - mobile-ui
---

# Putaway — new SKU: blank location guidance (UI) + unguarded sysprop parse + missing @Transactional (backend)

**Ticket:** N/A
**Project:** wms1 (v1/wms-mobile-ui + v1/wms-api) | **Version:** — | **Type:** bug
**Priority:** high
**Status:** draft
**Date:** 2026-04-27

---

## 0. Affected Sites (Enumeration Before Drafting)

| # | File | Lines | Construct | Same root-cause? | In-scope this plan? |
|---|------|-------|-----------|-----------------|----------------------|
| 1 | `components/putaway/scanFlowBin.vue` | 34–38 | Storage Information block — displays `flowBinLocationList` and `overstockLocationList` with no conditional guidance when both are empty | **Primary (UI)** | Yes — Fix A |
| 2 | `components/putaway/scanFlowBin.vue` | 43 | `<label>Scan Location</label>` — static text gives no hint for the new-SKU path | Same root-cause | Yes — Fix A |
| 3 | `store/putaway.js` | 74–90 | `calculatePutawayList` action — transitions to `3_flowbin` even when all items have empty location lists; no error surfaced | Context only | No — backend returns correct data; store behaviour is fine |
| 4 | `components/putaway/storeBox.vue` | 8–16 | Renders SKU + box info for the `4_box` step — unaffected by empty location lists | No | No — renders correctly once user advances |
| 5 | `components/putaway/storePallet.vue` | — | Overstock pallet path — separate code branch | No | No — different path |
| 6 | `service/FixLocationAssignmentService.java` | 66–68 | `Long.parseLong(losSyspropRepository.findSysvalueBySyskey(...))` — unguarded; returns `NumberFormatException` (→ HTTP 500) if any of three sysprops are absent | **Backend Bug 2** | Yes — Fix B |
| 7 | `service/FixLocationAssignmentService.java` | 70 | `unitloadTypeRepository.findByName(UNIT_LOAD_TYPE_PICKLOCATION).get()` — unguarded `Optional.get()`; throws `NoSuchElementException` if type missing | Adjacent defensive gap | Yes — Fix B (same diff) |
| 8 | `service/mobile/MobilePutAwayService.java` | 416–474 | `storeBoxOnLocation` — no `@Transactional`; `createFixedLocationAssignment` (writes FixLocationAssignment + Unitload) and `transferStockToUnitLoad` run in separate mini-sessions; partial failure leaves orphaned assignment | **Backend Bug 3** | Yes — Fix C |

---

## 1. Problem Statement

**Symptom:** When a user scans a pallet containing a brand-new SKU (no existing stock in any storage-area location), the putaway flow reaches the **Scan Location** screen (`scanFlowBin.vue`, process state `3_flowbin`) but shows:

```
Pickable Loc.:
Storage Loc.:
```

Both fields are blank. There is no label, message, or visual cue explaining that the user should manually scan a flowbin location to create a new fixed storage assignment. Users see what appears to be a broken/empty screen and cannot proceed.

**Reproduction steps (dev environment):**

1. Confirm the pallet is at `PutAwayLane` (or move it back with the SQL from the investigation).
2. Open the mobile putaway screen and scan `IN-000299` (contains box `UL317366`, SKU "Non Alcoholic Wine Product" — no existing storage locations).
3. In the `ReplenishChoice` step, tap **Replenish**.
4. Observe: **Scan Location** screen renders with empty `Pickable Loc.` and `Storage Loc.` fields and no guidance text.
5. Expected: A message such as "New SKU — no existing storage location. Scan a flowbin location to create a new fixed assignment."

**Impact:** Any pallet containing a first-time SKU (one that has never been put away before) is impossible to process without tribal knowledge. The backend supports the new-fixed-location creation path fully; only the UI is missing guidance.

---

## 2. Root Cause Analysis

### Bug 1 (Root Cause) — `scanFlowBin.vue` has no conditional rendering for empty location lists

**File:** `v1/wms-mobile-ui/components/putaway/scanFlowBin.vue:34–43`

**Broken code:**
```vue
<div class="text-subtitle-2 mt-3 mb-3">Storage Information</div>
<div class="ml-4">
  Pickable Loc.: {{ info.putAwayItemDataList[currentIndex].flowBinLocationList.join(', ') }} <br/>
  Storage Loc.: {{ info.putAwayItemDataList[currentIndex].overstockLocationList.join(', ') }} <br/>
</div>
...
<label class="caption" for="putawayScan">Scan Location</label>
```

**Why it fails:** When `calculatePutAwayList` is called for a SKU that has never been stored in any storage-area location, the backend query `getStorageLocationsForPutAwayItemData` returns zero rows. The DTO item has `flowBinLocationList = []` and `overstockLocationList = []`. The template renders empty strings with no explanation. The "Scan Location" label gives no hint that the user is on the new-fixed-assignment path. Users have no indication of what action to take.

**The backend is correct for location list calculation:** `calculatePutAwayList` intentionally returns items with empty lists — these items are valid putaway candidates whose destination is user-chosen. `verifyScannedLocation` and `storeBoxOnLocation` both handle the new-fixed-location creation path. However, two backend gaps exist within the creation path itself (Bugs 2 and 3 below).

---

### Bug 2 — Unguarded sysprop parse in `createFixedLocationAssignment`

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/FixLocationAssignmentService.java:66–70`

**Broken code:**
```java
BigDecimal lowerBound = BigDecimal.valueOf(Long.parseLong(
    losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_KEY)));
BigDecimal middleBound = BigDecimal.valueOf(Long.parseLong(
    losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_KEY)));
BigDecimal upperBound = BigDecimal.valueOf(Long.parseLong(
    losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY)));

UnitloadType virtual = unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PICKLOCATION).get();
```

**Why it fails:**
- `findSysvalueBySyskey` returns `null` if a sysprop row is absent → `Long.parseLong(null)` → `NumberFormatException` → HTTP 500 (not handled by `RestExceptionHandler`).
- `findByName(...).get()` is unguarded → `NoSuchElementException` if `PickLocation` unitload type is absent → HTTP 500.

`WmsConstants` already defines canonical default values (`LOWER=36`, `MIDDLE=60`, `UPPER=84`) — they are just not used as fallbacks. The sysprops exist in the dev DB now, but any new environment (QA, UA, client) that lacks these rows will silently fail on first new-SKU putaway.

---

### Bug 3 — Missing `@Transactional` on `storeBoxOnLocation`

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePutAwayService.java:416–474`

**Problem:** `storeBoxOnLocation` calls `createFixedLocationAssignment` (saves a new `FixLocationAssignment` row + a new `Unitload` at the flowbin) followed by `transferStockToUnitLoad` (moves stock from the scanned box). Both run in separate Spring Data mini-sessions with no wrapping transaction.

If `transferStockToUnitLoad` throws after `createFixedLocationAssignment` succeeds, the `FixLocationAssignment` and its empty `Unitload` are committed to the DB but no stock was transferred. The flowbin slot is locked to the SKU, the source box still has stock, and the pallet is stuck.

**Note on partial idempotency:** The second attempt will find the existing `FixLocationAssignment` and skip creation — the transfer will be retried against the already-created assignment. So recovery is possible via re-scan. However, the intermediate state is inconsistent and can trigger spurious replenishment orders (via `triggerReplenishmentMaintenance`) against an empty slot.

---

## 3. Regression Chain

| Date | Commit | Change | Effect |
|------|--------|--------|--------|
| Initial | `79d7ed8` | Initial checkin of putaway flow | UI gap existed from day one but was unreachable |
| 2025-07-25 | `e7e495d` | SBDEV-1460: fix stuck putaway container UI side | Added `storePalletBackOnPutawayLane` call — did not add new-SKU guidance |
| 2026-04-10 | `227eede` (wms-api) | SBDEV-2102 foundation: prevent stuck unit loads | Fixed `findUnitLoad` validation |
| **2026-04-12** | **`f19bfea`** (wms-api) | **SBDEV-2102 Bug 4: use ID comparison for UnitloadType** | **Unmasked this bug.** Before this fix, `isPallet`/`isBox` check always failed (compared `Long` to `UnitloadType` object) → `findUnitLoad` threw for every scan → no pallet ever reached `calculatePutAwayList`. After fix, the path is reachable. New SKUs now expose the latent UI gap. |
| 2026-04-13 | `77c7518` (wms-api) | SBDEV-2102 Bug 6: remove duplicate `sendToNirvana` | Completed the `storeBoxOnLocation` flowbin path |

The UI guidance gap has existed since `79d7ed8` but was masked until `f19bfea` made the putaway flow actually work.

---

## 4. Architecture Overview

```
Mobile UI                                   Backend (v1/wms-api)
─────────────────────────────────────────────────────────────────
scanPallet.vue
  │ dispatch('scanPallet')
  └─► GET /putaway/scanPallet/{label}
        │ findUnitLoad()
        │   validates: PutAwayLane, pallet type, has children
        │   transfers pallet → user location
        └─► returns {unitLoadIsPallet:true, ...}

replenishChoice.vue (process: 2_choice)
  │ dispatch('calculatePutawayList')
  └─► POST /putaway/calculatePutawayList
        │ calculatePutAwayList()
        │   for each box: getStorageLocationsForPutAwayItemData(itemDataId)
        │   NEW SKU → returns [] → item.flowBinLocationList=[]
        │                          item.overstockLocationList=[]
        │   hasNoAssignedLocation() = true for this item
        └─► returns DTO with item (no error thrown — this is correct)

scanFlowBin.vue (process: 3_flowbin)  ◄── BUG: no guidance shown
  │                                         when location lists empty
  │ submit() → dispatch('scanFlowBinLocation')
  └─► POST /putaway/scanFlowBinLocation
        │ verifyScannedLocation()
        │   flowbin + no existing FixLocationAssignment → PASSES ✓
        └─► returns DTO

storeBox.vue (process: 4_box)
  │ submit() → dispatch('storeBoxOnLocation')
  └─► POST /putaway/storeBoxOnLocation
        │ storeBoxOnLocation()
        │   fixedLocationAssignment == null →
        │     createFixedLocationAssignment(location, itemData) ✓
        │   transferStockToUnitLoad(...) ✓
        │   updateCurrentItemDataUnitLoadList() ✓
        └─► returns updated DTO
```

**Key files:**

| File | Lines | Role |
|------|-------|------|
| `v1/wms-mobile-ui/components/putaway/scanFlowBin.vue` | 1–128 | **Fix target** — scan location screen, process `3_flowbin` |
| `v1/wms-mobile-ui/store/putaway.js` | 74–90 | `calculatePutawayList` Vuex action — no change needed |
| `v1/wms-mobile-ui/pages/putaway.vue` | 1–27 | Process router — no change needed |
| `v1/wms-api/.../service/mobile/MobilePutAwayService.java` | 183–263, 368–474 | `calculatePutAwayList`, `verifyScannedLocation`, `storeBoxOnLocation` — all correct, no change needed |
| `v1/wms-api/.../repo/jpa/LocationRepository.java` | 84–91 | `getStorageLocationsForPutAwayItemData` query — no change needed |

---

## 5. Fix Design

### Fix A — Add new-SKU guidance and dynamic label in `scanFlowBin.vue`

**File:** `v1/wms-mobile-ui/components/putaway/scanFlowBin.vue`

**Before (lines 34–45):**
```vue
<div class="text-subtitle-2 mt-3 mb-3">Storage Information</div>
<div class="ml-4">
  Pickable Loc.: {{ info.putAwayItemDataList[currentIndex].flowBinLocationList.join(', ') }} <br/>
  Storage Loc.: {{ info.putAwayItemDataList[currentIndex].overstockLocationList.join(', ') }} <br/>
</div>

...

<label class="caption" for="putawayScan">Scan Location</label>
```

**After:**
```vue
<div class="text-subtitle-2 mt-3 mb-3">Storage Information</div>
<div class="ml-4">
  Pickable Loc.: {{ info.putAwayItemDataList[currentIndex].flowBinLocationList.join(', ') }} <br/>
  Storage Loc.: {{ info.putAwayItemDataList[currentIndex].overstockLocationList.join(', ') }} <br/>
</div>
<v-alert v-if="hasNoSuggestedLocation" type="info" dense text class="mt-2">
  New SKU — no existing storage location found.<br/>
  Scan a flowbin location to create a new fixed assignment.
</v-alert>

...

<label class="caption" for="putawayScan">
  {{ hasNoSuggestedLocation ? 'Scan Flowbin Location (New Assignment)' : 'Scan Location' }}
</label>
```

**Add to `computed` block (after `currentItem`):**
```js
hasNoSuggestedLocation() {
  const item = this.info && this.info.putAwayItemDataList
    ? this.info.putAwayItemDataList[this.currentIndex]
    : null
  if (!item) return false
  return item.flowBinLocationList.length === 0 && item.overstockLocationList.length === 0
},
```

**Why this fix and not alternatives:**

- **Why not throw a backend error when lists are empty?** That would block the new-fixed-location creation path the user explicitly wants to preserve. The backend returning empty lists is correct — it means "no suggestion; user decides."
- **Why not add a separate UI screen/step for new SKUs?** Over-engineering. The `Scan Location` form already accepts free-form input and routes to `verifyScannedLocation` + `storeBoxOnLocation` — the whole path already works. All that's missing is user guidance.
- **Why `v-alert` over plain text?** Vuetify `v-alert` with `type="info"` provides visual prominence consistent with the existing Vuetify 2 design language in the app. Zero new dependencies.

---

### Fix B — Null-safe sysprop parsing with fallback defaults in `createFixedLocationAssignment`

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/FixLocationAssignmentService.java:66–70`

**Before:**
```java
BigDecimal lowerBound = BigDecimal.valueOf(Long.parseLong(
    losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_KEY)));
BigDecimal middleBound = BigDecimal.valueOf(Long.parseLong(
    losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_KEY)));
BigDecimal upperBound = BigDecimal.valueOf(Long.parseLong(
    losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY)));

UnitloadType virtual = unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PICKLOCATION).get();
```

**After:**
```java
String lbStr = losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_KEY);
String mbStr = losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_KEY);
String ubStr = losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY);
BigDecimal lowerBound = BigDecimal.valueOf(Long.parseLong(lbStr != null ? lbStr : WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_VALUE));
BigDecimal middleBound = BigDecimal.valueOf(Long.parseLong(mbStr != null ? mbStr : WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_VALUE));
BigDecimal upperBound = BigDecimal.valueOf(Long.parseLong(ubStr != null ? ubStr : WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_VALUE));

UnitloadType virtual = unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PICKLOCATION)
    .orElseThrow(() -> new BusinessException("entityNotFoundForName", UnitloadType.class.getSimpleName(), WmsConstants.UNIT_LOAD_TYPE_PICKLOCATION));
```

**Why:** The `WmsConstants` default value strings already exist (36/60/84) — this change uses them as documented fallbacks rather than letting absent sysprops crash with an unhandled `NumberFormatException`. The `.orElseThrow` converts a silent NPE into an auditable `BusinessException`.

---

### Fix C — Add `@Transactional` to `storeBoxOnLocation`

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePutAwayService.java:416`

**Before:**
```java
public PutAwayMobileDto storeBoxOnLocation(PutAwayMobileDto putAwayMobileDto) throws BusinessException, FacadeException {
```

**After:**
```java
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
public PutAwayMobileDto storeBoxOnLocation(PutAwayMobileDto putAwayMobileDto) throws BusinessException, FacadeException {
```

**Why:** Wrapping the method in a transaction makes `createFixedLocationAssignment` + `transferStockToUnitLoad` atomic. If either throws, both roll back — no orphaned `FixLocationAssignment`. Also suppresses the spurious replenishment trigger that `triggerReplenishmentMaintenance` would fire against the empty slot.

**Why not class-level `@Transactional`?** Other methods in `MobilePutAwayService` (`findUnitLoad`, `calculatePutAwayList`, `verifyScannedLocation`) are read-heavy and don't need transaction wrapping. Method-level is the minimal safe change consistent with the v1 mixed transaction strategy.

**Import to add:** `import org.springframework.transaction.annotation.Transactional;`

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `v1/wms-mobile-ui/components/putaway/scanFlowBin.vue` | Modify | Add `hasNoSuggestedLocation` computed property; add `v-alert` guidance block; make scan label dynamic |
| `v1/wms-api/.../service/FixLocationAssignmentService.java` | Modify | Null-safe sysprop parsing with `WmsConstants` default fallbacks; `.orElseThrow` on `findByName(UNIT_LOAD_TYPE_PICKLOCATION)` |
| `v1/wms-api/.../service/mobile/MobilePutAwayService.java` | Modify | Add `@Transactional(rollbackFor = ...)` to `storeBoxOnLocation` |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Prerequisite | Status |
|---|---|
| DB state | N/A — pure UI code change; no schema or data migration |
| Feature flags / sysprops | N/A — no server-side gate |
| Deploy-order dependencies | None — UI change only; deployed independently of wms-api |
| Coordination with sibling plan | `260427-putaway-unitloadlist-undefined-crash.md` touches the same file (`scanFlowBin.vue`). Implement that plan's fixes (Fix B, Fix D) in the same branch/PR to avoid merge conflicts. Review both plans before coding. |
| Test data | `IN-000299` (pallet) + `UL317366` (box, "Non Alcoholic Wine Product") at `PutAwayLane` on dev environment. Run reset SQL if needed: `UPDATE unitload SET storagelocation_id = 51605, modified = NOW(), version = version + 1 WHERE id IN (642969276, 25852287);` |

### 7.2 Implementation

**Step 1 — Add `hasNoSuggestedLocation` computed property**

In `scanFlowBin.vue`, add after the `currentItem` computed property (line 84):

```js
hasNoSuggestedLocation() {
  const item = this.info && this.info.putAwayItemDataList
    ? this.info.putAwayItemDataList[this.currentIndex]
    : null
  if (!item) return false
  return item.flowBinLocationList.length === 0 && item.overstockLocationList.length === 0
},
```

**Step 2 — Add `v-alert` guidance block in the template**

After the `Storage Information` div (after line 38), add:
```vue
<v-alert v-if="hasNoSuggestedLocation" type="info" dense text class="mt-2">
  New SKU — no existing storage location found.<br/>
  Scan a flowbin location to create a new fixed assignment.
</v-alert>
```

**Step 3 — Make scan label dynamic**

Replace static `<label class="caption" for="putawayScan">Scan Location</label>` (line 43) with:
```vue
<label class="caption" for="putawayScan">
  {{ hasNoSuggestedLocation ? 'Scan Flowbin Location (New Assignment)' : 'Scan Location' }}
</label>
```

**Step 4 — Fix B: null-safe sysprop parsing in `FixLocationAssignmentService`**

In `FixLocationAssignmentService.java:66–70`, replace the three unguarded `Long.parseLong(findSysvalueBySyskey(...))` calls with null-safe versions using `WmsConstants` default values as fallback (see Fix B code in §5). Replace the unguarded `.get()` on `findByName(UNIT_LOAD_TYPE_PICKLOCATION)` with `.orElseThrow(...)`.

**Step 5 — Fix C: add `@Transactional` to `storeBoxOnLocation`**

In `MobilePutAwayService.java:416`, add `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` to the `storeBoxOnLocation` method. Verify `import org.springframework.transaction.annotation.Transactional;` is present (other methods in the class may already use it if added by sibling plans).

**Step 6 — Run verify script**

```bash
bash sbdocs/9-System/scripts/verify-260427-putaway-new-sku-no-location-guidance.sh
```

Expected: `Result: 6 pass, 0 fail`

**Step 5 — Manual smoke test** (see §8 Manual Test Plan)

---

## 8. Testing Plan

### Unit / Component Tests

The wms-mobile-ui project has no Vue component test infrastructure (`jest` config for Nuxt 2 is not set up). Automated component tests are therefore not applicable for this change.

**N/A rationale:** wms-mobile-ui has no configured Jest/Vue Test Utils suite. Manual testing is the primary verification path per the project's existing convention.

### Regression Tests

- Verify that existing SKUs with suggested locations still display correctly (non-empty `Pickable Loc.` / `Storage Loc.` fields should show normally; `v-alert` must NOT appear).

### Manual Test Plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|----------|-------------|-------|-----------------|-----------|
| M1 | New SKU — no existing storage locations | Dev (wms1 wineco) | 1. Reset IN-000299 to PutAwayLane (SQL in §7.1). 2. Scan IN-000299 in mobile putaway. 3. Tap Replenish in ReplenishChoice. 4. Observe ScanFlowBin screen. | Blue info alert: "New SKU — no existing storage location found. Scan a flowbin location to create a new fixed assignment." Label reads "Scan Flowbin Location (New Assignment)". | |
| M2 | New SKU — complete the putaway | Dev | Continue from M1. 5. Type `01-A01` in the scan field and submit. 6. Scan `UL317366` in StoreBox screen. 7. Confirm toast "Box UL317366 stored on 01-A01". | `fix_location_assignment` row created for (01-A01, Non Alcoholic Wine Product). UL317366 sent to nirvana. Pallet marked empty. UI returns to home. | |
| M3 | Known SKU — no regression | Dev | Scan a pallet with a SKU that already has existing storage-area stock (e.g. IN-000024 / UL316065, scan a flowbin after fixing location type). | No alert shown. `Pickable Loc.` or `Storage Loc.` shows suggested location name(s). Label reads "Scan Location". | |
| M4 | Multi-SKU pallet — mixed new + known | Dev (if available) | Scan a pallet with ≥2 SKUs where one has existing locations and one does not. Navigate between items. | Alert appears for new-SKU item, does not appear for known-SKU item. Navigation (prev/next) updates alert correctly. | |
| M5 | DB verification after M2 | Dev | `SELECT fla.*, l.name FROM fix_location_assignment fla JOIN location l ON fla.assignedlocation_id = l.id WHERE fla.itemdata_id = 25852281;` | One row: location = 01-A01 (or whichever flowbin was scanned). | |
| M6 | Fix B — sysprop missing resilience | Dev | Temporarily rename one sysprop: `UPDATE los_sysprop SET syskey='DISABLED_FIX_LOWER' WHERE syskey='FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND';` then repeat M1–M2. Restore after test. | Putaway completes using default value (36). No HTTP 500. Restore sysprop when done. | |
| M7 | Fix C — atomicity on transfer failure | Dev | Temporarily make `transferStockToUnitLoad` throw by scanning a box whose stock unit does not exist (e.g. scan a non-existent label in storeBox). | No `FixLocationAssignment` row created (transaction rolled back). Re-scanning the correct box on a subsequent attempt succeeds. | |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Merge conflict with `260427-putaway-unitloadlist-undefined-crash.md` (both modify `scanFlowBin.vue`) | Medium — conflicting edits to same template block | Implement both plans in the same branch/PR. Review sibling plan's Fix B (null guard on line 27) before editing — the null guard wraps the same subtitle block. Ensure the `v-alert` is placed inside the guarded block after Fix B is applied. |
| `v-alert` renders unexpectedly for items with locations (false positive) | Low — user sees misleading alert | `hasNoSuggestedLocation` is computed from the actual list lengths — only true when both are empty. Validated by M3 regression test. |
| New flowbin assignment on wrong location | Low — user scans wrong location | Existing `verifyScannedLocation` rejects locations that: don't exist, aren't in a storage area, or have a conflicting fixed assignment for a different SKU. The alert directs user to scan a flowbin; non-flowbin locations accepted by this validation will still work for overstock paths. |
| v2/wms2-api has same gap | Medium — if v2 putaway has same pattern | Out of scope for this plan — v2 uses a different UI stack. Flag for a v2 sync sweep. |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|----------|------------|
| Q1 | Should the backend also throw an error for this case as a safety net? | **Resolved: No.** Throwing an error would break the new-fixed-location creation path the user explicitly wants to preserve. The backend returning empty lists is the correct contract — the UI adapts. |
| Q2 | v1 only or v1 + v2? | **Resolved: v1 only.** v2/wms2-api has its own mobile UI stack and putaway service. If the same gap exists in v2, it requires a separate investigation and plan. |
| Q3 | Is there a ticket number for this bug? | **Resolved: None assigned.** Using YYMMDD prefix per naming convention. |
| Q4 | Should the alert also appear when `storeBoxOnLocation` returns and the next item also has no locations? | **Resolved: Yes — by design.** `hasNoSuggestedLocation` is a computed property evaluated on the current item at render time. It will automatically show for any item with empty lists, including subsequent items after a box is stored. No additional work needed. |

---

## Completeness Checklist

| # | Concern | Considered? |
|---|---------|-------------|
| 1 | **All callsites enumerated** | ✓ §0 — one primary site (`scanFlowBin.vue:34–43`). No other component displays location suggestion lists. |
| 2 | **Adjacent bugs** | ✓ `storeBox.vue` checked — not affected. `replenishChoice.vue` checked — only dispatches, no rendering gap. |
| 3 | **Backward compatibility** | ✓ No API contract change, no schema change, no DTO shape change. UI change is purely additive (new computed + conditional element). |
| 4 | **Concurrency** | ✓ N/A — pure UI rendering change; no server-side concurrency concern. |
| 5 | **Multi-tenant** | ✓ N/A — UI runs per-user session; tenant context is a backend concern unaffected by this change. |
| 6 | **Error handling** | ✓ `hasNoSuggestedLocation` includes a null guard (`if (!item) return false`) — no crash if item is undefined. |
| 7 | **Observability** | ✓ N/A — no new server-side failure mode; Vue `console.log` already present in the store actions for debugging. |
| 8 | **Rollback / migration** | ✓ No Flyway migration, no sysprop changes. Rollback = revert the Vue file. |
| 9 | **Test coverage** | ✓ No component test infrastructure; manual test plan (M1–M5) provided with DB verification step. |
| 10 | **Cross-version (v1↔v2)** | ✓ v2 out-of-scope — documented in Q2 and §9 risks. |

---

## 11. Acceptance

Run the verify script after implementation:

```bash
bash sbdocs/9-System/scripts/verify-260427-putaway-new-sku-no-location-guidance.sh
```

Expected final line: `Result: 6 pass, 0 fail, 0 skip`

Implementation is not complete until:
1. Verify script reports 0 failures.
2. Manual tests M1–M5 all pass (mark Pass/Fail in the table above).
3. This document's Implementation Status section is filled in with commit SHA and test results.

---

## 12. Implementation Status

_To be filled in after implementation._
