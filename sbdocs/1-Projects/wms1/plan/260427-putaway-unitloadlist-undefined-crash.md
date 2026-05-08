---
title: "Putaway — unitLoadList undefined crash in mobile UI"
ticket: ""
ticket_url: ""
type: bug
priority: high
status: draft
project:
  - wms1
version: v1
requester: Nam Park
created: "2026-04-27"
updated: "2026-04-27"
related:
  - ../../../3-Resources/workflows/wms1-receiving-putaway-workflow.md
tags:
  - plan
  - mobile-ui
  - putaway
---

# Putaway — unitLoadList undefined crash in mobile UI

**Project:** wms1 (wms-mobile-ui) | **Version:** v1 | **Type:** bug
**Priority:** high
**Status:** draft
**Date:** 2026-04-27

---

## 0. Affected Sites (Enumeration Before Drafting)

| # | File | Line | Construct | Root cause? | In-scope? |
|---|------|------|-----------|-------------|-----------|
| 1 | `store/putaway.js` | 74–90 | `calculatePutawayList` action — no `setCurrentIndex(0)` reset | **Primary root cause** | Yes — Fix A |
| 2 | `store/putaway.js` | 50–72 | `scanPallet` (non-box path) — no `setCurrentIndex(0)` reset | Same root cause | Yes — Fix A |
| 3 | `components/putaway/scanFlowBin.vue` | 27 | Template: `info.putAwayItemDataList[currentIndex].unitLoadList.length` — unguarded | Defensive gap | Yes — Fix B |
| 4 | `components/putaway/storeBox.vue` | 15–16 | Template: `info.putAwayItemDataList[currentIndex].unitLoadList.length/join` — unguarded | Defensive gap | Yes — Fix C |
| 5 | `components/putaway/scanFlowBin.vue` | 76 | `putawayItems` computed: `putawayInfo.putAwayItemDataList` without null guard | Secondary crash risk | Yes — Fix D |
| 6 | `store/putaway.js` | 101 | `scanFlowBinLocation` commits `data` (request) not `result` (response) | Data integrity gap | Yes — Fix E |
| 7 | `store/putaway.js` | 20–21 | `setCurrentIndex` mutation: no guard on undefined `payload` | Defensive gap | Yes — Fix A (covered) |

---

## 1. Problem Statement

**Symptom:** When using the putaway flow on wms-mobile-ui (Nuxt 2 / Vue 2), a hard JavaScript crash occurs:

```
TypeError: Cannot read properties of undefined (reading 'unitLoadList')
    at f.<anonymous> (fcb438b.js:1:13951)        ← Vue component render
    at f._render (7d0bdca.js:2:48249)
    at f.r (7d0bdca.js:2:78562)
    at t.get (7d0bdca.js:2:28550)
    at new t (7d0bdca.js:2:28463)
    at 7d0bdca.js:2:78576
    at f.$mount (7d0bdca.js:2:78794)             ← during component mount
    at init (7d0bdca.js:2:33370)
```

The crash happens during component mount (`f.$mount → init`) — not on a user interaction. The screen goes blank. The user must hard-reload to recover.

**Affected screens:** `scanFlowBin.vue` (step 3 — scan location) and `storeBox.vue` (step 4 — scan box). The crash is most likely on the `scanFlowBin` component that shows after completing a box store and returning to the location scan screen.

**Reproduction trigger (most reliable):** Complete a multi-item putaway session (advance to item index > 0), then start a NEW putaway session with fewer items. The stale `currentIndex` from the first session exceeds the bounds of the new session's `putAwayItemDataList`.

---

## 2. Root Cause Analysis

### Bug 1 (Root Cause) — Stale `currentIndex` across putaway sessions

**File:** `store/putaway.js:74–90` (`calculatePutawayList` action) and `:50–72` (`scanPallet` action).

**Initial Vuex state:**
```js
export const state = () => ({
  currentIndex: 0,   // starts at 0 only on store initialization
  putawayInfo: null,
  // ...
})
```

When `calculatePutawayList` succeeds it commits:
```js
context.commit('setPutawayInfo', result)   // line 83
context.commit('setProcess', '3_flowbin')  // line 84
// ← NO setCurrentIndex(0) reset!
```

When `scanPallet` encounters a non-box pallet it commits:
```js
context.commit('setPutawayInfo', result)   // line 64
context.commit('setProcess', '2_choice')   // line 65
// ← NO setCurrentIndex(0) reset!
```

Neither code path resets `currentIndex`. In a Nuxt 2 client-side navigation session, the Vuex store persists across route changes. If a user previously advanced `currentIndex` to `3` in an earlier putaway session, and the new session's `putAwayItemDataList` has only 2 items, then:

```
info.putAwayItemDataList[3]  →  undefined
undefined.unitLoadList        →  TypeError ← THE CRASH
```

The `setCurrentIndex` mutation also lacks a guard for out-of-bounds payload:
```js
setCurrentIndex(state, payload) {
  state.currentIndex = payload
  state.currentItem = state.putawayInfo.putAwayItemDataList[payload]  // line 21 — undefined if out of bounds
},
```

### Bug 2 (Defensive Gap) — Unguarded template in `scanFlowBin.vue`

**File:** `components/putaway/scanFlowBin.vue:27`

```html
<v-card-subtitle v-if="info" ...>
  <div class="text-subtitle-2 mb-3">No of Packages to Putaway: {{
    info.putAwayItemDataList[currentIndex].unitLoadList.length }}</div>  <!-- crash here -->
```

The `v-if="info"` guard on the `v-card-subtitle` only checks that `info` (i.e. `putawayInfo`) is truthy. It does NOT protect against `info.putAwayItemDataList[currentIndex]` being `undefined`. Once Bug 1 causes `currentIndex` to be out of bounds, this template expression crashes.

Compare this to `completed()` (same file, line 101) which correctly guards:
```js
if (this.info && this.info.putAwayItemDataList && this.info.putAwayItemDataList[this.currentIndex]) {
```

The template access has no equivalent protection.

### Bug 3 (Defensive Gap) — Unguarded template in `storeBox.vue`

**File:** `components/putaway/storeBox.vue:15-16`

```html
<v-card-subtitle v-if="info">
  ...
  Unit Loads: {{ info.putAwayItemDataList[currentIndex].unitLoadList.length }} <br />
  Packages: {{ info.putAwayItemDataList[currentIndex].unitLoadList.join(', ') }} <br/>
```

Same unguarded pattern as Bug 2. Both `.length` and `.join()` are called directly on `unitLoadList` with no null check.

### Bug 4 (Secondary Crash Risk) — `putawayItems` computed without null guard

**File:** `components/putaway/scanFlowBin.vue:76`

```js
putawayItems() {
  return this.$store.state.putaway.putawayInfo.putAwayItemDataList
},
```

This throws a `TypeError` if `putawayInfo` is `null` (e.g., after `storePalletOnLocation` sets it to `null`, or on a hard refresh). The computed is used in the template at line 14 (`putawayItems.length`).

### Bug 5 (Data Integrity Gap) — `scanFlowBinLocation` discards API response

**File:** `store/putaway.js:101`

```js
async scanFlowBinLocation(context, data) {
  const result = await this.$axios.$post('/putaway/scanFlowBinLocation', data)
  if (!result.errors) {
    context.commit('setPutawayInfo', data)    // ← commits REQUEST, not result
    context.commit('setCurrentIndex', data.currentItemDataPointer)
    context.commit('setProcess', '4_box')
  }
}
```

The API response `result` (a full `PutAwayMobileDto`) is computed by the backend but silently discarded. `putawayInfo` is updated with the client-side request `data` — a shallow copy of the previous `putawayInfo` plus `selectedReplenishStorageLocation`. Any state the backend updates (e.g., validation stamps, modified `putAwayItemDataList`) is lost. This also means if the backend updates `currentItemDataPointer` in its response, that update is ignored.

---

## 3. Architecture Overview

```
pages/putaway.vue
  └── renders one component based on store.putaway.process:
        '1_select'   → scanPallet.vue
        '2_choice'   → replenishChoice.vue
        '3_flowbin'  → scanFlowBin.vue   ← CRASH: Bug 2, Bug 4
        '4_box'      → storeBox.vue      ← CRASH: Bug 3
        '5_store'    → storePallet.vue   (not affected)

store/putaway.js — Vuex module
  state:  process, pallet, putawayInfo, currentIndex, currentItem
  actions: scanPallet → calculatePutawayList → (3_flowbin)
                                             → (2_choice)
           scanFlowBinLocation → (4_box)
           storeBoxOnLocation  → (3_flowbin)  ← stale index risk on re-entry
           storePalletOnLocation → (1_select, resets info to null)
```

### Key Files

| File | Lines | Role |
|------|-------|------|
| `store/putaway.js` | 150 | Vuex module — all putaway state, actions, mutations |
| `components/putaway/scanFlowBin.vue` | 128 | Step 3: scan location component — primary crash site |
| `components/putaway/storeBox.vue` | 75 | Step 4: scan box component — secondary crash site |
| `json/mobile/PutAwayItemDto.java` | 117 | Backend DTO — `unitLoadList` is `List<String>`, defaults to `new ArrayList<>()` |
| `json/mobile/PutAwayMobileDto.java` | ~105 | Backend response DTO — `currentItemDataPointer` is `int`, defaults to `0` |

---

## 4. Fix Design

### Fix A — Reset `currentIndex` in `calculatePutawayList` and `scanPallet` (root cause fix)

**File:** `store/putaway.js`

**Problem:** Neither `calculatePutawayList` nor `scanPallet` (non-box path) reset `currentIndex` to `0` when loading a new putaway session.

**Before (`calculatePutawayList`, lines 83–84):**
```js
context.commit('setPutawayInfo', result)
context.commit('setProcess', '3_flowbin')
```

**After:**
```js
context.commit('setPutawayInfo', result)
context.commit('setCurrentIndex', 0)   // ← reset to 0 for new session
context.commit('setProcess', '3_flowbin')
```

**Before (`scanPallet` non-box path, lines 64–65):**
```js
context.commit('setPutawayInfo', result)
context.commit('setProcess', '2_choice')
```

**After:**
```js
context.commit('setPutawayInfo', result)
context.commit('setCurrentIndex', 0)   // ← reset to 0 for new session
context.commit('setProcess', '2_choice')
```

Note: `setCurrentIndex` must be called AFTER `setPutawayInfo` because the mutation reads `state.putawayInfo.putAwayItemDataList[payload]`.

Also add a defensive guard to the `setCurrentIndex` mutation itself:
```js
setCurrentIndex(state, payload) {
  const idx = (payload !== undefined && payload !== null) ? payload : 0
  state.currentIndex = idx
  state.currentItem = state.putawayInfo
    ? (state.putawayInfo.putAwayItemDataList[idx] || null)
    : null
},
```

### Fix B — Defensive guard in `scanFlowBin.vue` template

**File:** `components/putaway/scanFlowBin.vue`

**Problem:** Template at line 27 accesses `info.putAwayItemDataList[currentIndex].unitLoadList.length` without checking if `putAwayItemDataList[currentIndex]` is defined.

**Add computed property (in `<script>`):**
```js
currentItemData() {
  const info = this.$store.state.putaway.putawayInfo
  const idx = this.$store.state.putaway.currentIndex
  if (!info || !Array.isArray(info.putAwayItemDataList) || idx == null) return null
  return info.putAwayItemDataList[idx] || null
},
```

**Before (line 25–27):**
```html
<v-card-subtitle v-if="info" ...>
  <div class="text-subtitle-2 mb-3">No of Packages to Putaway: {{
    info.putAwayItemDataList[currentIndex].unitLoadList.length }}</div>
```

**After:**
```html
<v-card-subtitle v-if="info && currentItemData" ...>
  <div class="text-subtitle-2 mb-3">No of Packages to Putaway: {{
    currentItemData.unitLoadList ? currentItemData.unitLoadList.length : 0 }}</div>
```

Replace all subsequent `info.putAwayItemDataList[currentIndex].X` references in the same `v-card-subtitle` with `currentItemData.X` (lines 30–37):
- `info.putAwayItemDataList[currentIndex].itemDataNumber` → `currentItemData.itemDataNumber`
- `info.putAwayItemDataList[currentIndex].clientName` → `currentItemData.clientName`
- `info.putAwayItemDataList[currentIndex].itemDataName` → `currentItemData.itemDataName`
- `info.putAwayItemDataList[currentIndex].flowBinLocationList.join(', ')` → `currentItemData.flowBinLocationList ? currentItemData.flowBinLocationList.join(', ') : ''`
- `info.putAwayItemDataList[currentIndex].overstockLocationList.join(', ')` → `currentItemData.overstockLocationList ? currentItemData.overstockLocationList.join(', ') : ''`

### Fix C — Defensive guard in `storeBox.vue` template

**File:** `components/putaway/storeBox.vue`

**Problem:** Same unguarded pattern at lines 8–16.

**Add computed property (in `<script>`):**
```js
currentItemData() {
  const info = this.$store.state.putaway.putawayInfo
  const idx = this.$store.state.putaway.currentIndex
  if (!info || !Array.isArray(info.putAwayItemDataList) || idx == null) return null
  return info.putAwayItemDataList[idx] || null
},
```

**Update `v-if` condition and template references:**
```html
<v-card-subtitle v-if="info && currentItemData">
```

Replace `info.putAwayItemDataList[currentIndex].X` with `currentItemData.X`:
- Line 8: `currentItemData.itemDataNumber`
- Line 9: `currentItemData.clientName`
- Line 10: `currentItemData.itemDataName`
- Line 15: `currentItemData.unitLoadList ? currentItemData.unitLoadList.length : 0`
- Line 16: `currentItemData.unitLoadList ? currentItemData.unitLoadList.join(', ') : ''`

### Fix D — Null-guard `putawayItems` computed in `scanFlowBin.vue`

**File:** `components/putaway/scanFlowBin.vue:76`

**Before:**
```js
putawayItems() {
  return this.$store.state.putaway.putawayInfo.putAwayItemDataList
},
```

**After:**
```js
putawayItems() {
  const info = this.$store.state.putaway.putawayInfo
  return (info && info.putAwayItemDataList) ? info.putAwayItemDataList : []
},
```

### Fix E — `scanFlowBinLocation` should commit `result` not `data`

**File:** `store/putaway.js:101`

**Before:**
```js
context.commit('setPutawayInfo', data)
context.commit('setCurrentIndex', data.currentItemDataPointer)
```

**After:**
```js
context.commit('setPutawayInfo', result)
context.commit('setCurrentIndex', result.currentItemDataPointer)
```

**Rationale:** The backend `PutAwayMobileDto` returned by `/putaway/scanFlowBinLocation` is the authoritative updated state. Using `data` (the shallow-copied request) means any backend-side updates to `putAwayItemDataList` are silently ignored. Using `result` ensures the frontend state stays in sync with backend state.

**Risk note:** Verify that the `scanFlowBinLocation` API response includes all fields that `storeBox.vue` needs (`selectedReplenishStorageLocation`, `unitLoadName`, etc.) before applying this fix. If the backend returns a complete `PutAwayMobileDto`, this is straightforward. If it returns a partial DTO, a merge may be needed instead.

---

## 5. File Change Summary

| File | Change Type | Description |
|------|------------|-------------|
| `store/putaway.js` | Modify | Fix A: add `setCurrentIndex(0)` in `calculatePutawayList` and `scanPallet` (non-box); add guard to `setCurrentIndex` mutation; Fix E: commit `result` in `scanFlowBinLocation` |
| `components/putaway/scanFlowBin.vue` | Modify | Fix B: add `currentItemData` computed; update `v-if` guard; replace inline index access; Fix D: null-guard `putawayItems` |
| `components/putaway/storeBox.vue` | Modify | Fix C: add `currentItemData` computed; update `v-if` guard; replace inline index access |

---

## 6. Implementation Steps

### 6.1 Prerequisites

| # | Prerequisite | Required value | Notes |
|---|---|---|---|
| 1 | **DB state** | N/A — pure frontend JS change | No Flyway migration needed |
| 2 | **Feature flags** | N/A | No toggle needed |
| 3 | **API contract** | Verify `POST /putaway/scanFlowBinLocation` response includes all fields used by `storeBox.vue` before applying Fix E | Check with `mobilePutAwayService.scanFlowBinLocation` return value |
| 4 | **Deploy-order** | None — wms-mobile-ui is independent of wms-api for this fix | |
| 5–8 | N/A | Pure frontend code fix | |

### 6.2 Implementation Checklist

- [ ] **Fix A — `store/putaway.js`:**
  - [ ] Add `context.commit('setCurrentIndex', 0)` after `setPutawayInfo` in `calculatePutawayList` (line 83)
  - [ ] Add `context.commit('setCurrentIndex', 0)` after `setPutawayInfo` in `scanPallet` non-box path (line 64)
  - [ ] Add defensive guard to `setCurrentIndex` mutation (lines 20–22)
- [ ] **Fix B — `components/putaway/scanFlowBin.vue`:**
  - [ ] Add `currentItemData` computed property in `<script>`
  - [ ] Update `v-if="info"` → `v-if="info && currentItemData"` on `v-card-subtitle`
  - [ ] Replace all `info.putAwayItemDataList[currentIndex].X` with `currentItemData.X`
  - [ ] Guard `unitLoadList`, `flowBinLocationList`, `overstockLocationList` with ternary
- [ ] **Fix C — `components/putaway/storeBox.vue`:**
  - [ ] Add `currentItemData` computed property in `<script>`
  - [ ] Update `v-if="info"` → `v-if="info && currentItemData"` on `v-card-subtitle`
  - [ ] Replace all `info.putAwayItemDataList[currentIndex].X` with `currentItemData.X`
  - [ ] Guard `unitLoadList` with ternary
- [ ] **Fix D — `components/putaway/scanFlowBin.vue`:**
  - [ ] Null-guard `putawayItems` computed
- [ ] **Fix E — `store/putaway.js`:** (after API contract verification)
  - [ ] Change `context.commit('setPutawayInfo', data)` → `result` in `scanFlowBinLocation`
  - [ ] Change `context.commit('setCurrentIndex', data.currentItemDataPointer)` → `result.currentItemDataPointer`
- [ ] Run `bash sbdocs/9-System/scripts/verify-260427-putaway-unitloadlist-undefined-crash.sh` — all checks PASS
- [ ] Manual smoke test on mobile device (see §7)

---

## 7. Testing Plan

### Unit / Component tests

Vue 2 / Nuxt 2 component tests use Jest. No `mockStatic` needed (this is JS, not Java).

| Test class | Test method | What it asserts |
|------------|------------|-----------------|
| `test/store/putaway.spec.js` (new) | `calculatePutawayList resets currentIndex to 0` | After dispatching `calculatePutawayList`, `state.currentIndex === 0` regardless of prior value |
| `test/store/putaway.spec.js` (new) | `setCurrentIndex handles undefined payload` | `setCurrentIndex(undefined)` sets `currentIndex = 0`, does not throw |
| `test/components/scanFlowBin.spec.js` (new) | `renders safely when currentIndex out of bounds` | Mount `scanFlowBin.vue` with `putawayInfo` having 1 item and `currentIndex = 5` — no crash, blank state shows |
| `test/components/storeBox.spec.js` (new) | `renders safely when currentIndex out of bounds` | Same as above for `storeBox.vue` |
| `test/components/storeBox.spec.js` (new) | `renders safely when unitLoadList is absent` | Mount with item missing `unitLoadList` — no crash, shows 0 |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|----------|------------|-------|-----------------|-----------|
| Fresh putaway — single item | Mobile staging | Scan pallet (box type) → proceed through flow bin scan → scan box → submit | No crash; item stored; returns to flow bin screen | |
| Fresh putaway — multi-item | Mobile staging | Scan pallet with ≥3 items → advance to item 3 → complete | No crash; all items processable | |
| **Second session after first** (regression) | Mobile staging | Complete first putaway (advance to item 3 of 3) → immediately scan a new pallet with 1 item → proceed to flow bin screen | **No crash**; screen shows item 1 of 1 (index 0) | |
| Stale index on new session | Mobile staging | Do a 5-item putaway, advance to item 4 → navigate away (do not complete) → return to putaway → scan pallet with 2 items | No crash; index resets to 0 | |
| Box scan with existing unitLoadList | Mobile staging | Proceed to storeBox screen (step 4) → verify "Unit Loads: N" and package list display correctly | Correct counts displayed | |
| unitLoadList absent in item | Mobile staging (if reproducible via bad API data) | Use a pallet where `unitLoadList` is empty `[]` | "Unit Loads: 0" shown, no crash | |
| Fix E: Flow bin scan returns fresh data | Mobile staging | Scan flow bin location → verify `storeBox.vue` shows correct `selectedReplenishStorageLocation` from response | Location shown matches API response | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Testcontainers / integration tests | This is a pure frontend JS fix; no backend code changes |
| Backend DTO tests | `PutAwayItemDto` already has `unitLoadList = new ArrayList<>()` — not null-safe concern is in Java |

---

## 8. Rollout Plan

| Step | Branch | Merge target | Notes |
|------|--------|-------------|-------|
| Fixes A–E | `fix/putaway-unitloadlist-crash` | `develop` | Single PR — all fixes are in 3 files |
| QA verification | — | — | Verify manual test plan passes in staging |
| Production | `develop` → `main` | GitLab CI tag | Standard release tag |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Fix E breaks `storeBox.vue` if API response is partial | Medium — `storeBox.vue` may lose `selectedReplenishStorageLocation` or other fields | Verify full `PutAwayMobileDto` is returned by `scanFlowBinLocation` before applying Fix E; if partial, merge `result` into `data` instead of replacing |
| `setCurrentIndex(0)` reset on re-scan breaks resume-putaway feature (if it exists) | Low — no resume feature is visible in the code | None visible; but verify with product owner |
| Template refactor from inline index to `currentItemData` computed introduces regressions | Low — mechanical substitution | Fixes B and C are mechanical replacements; verify all field names match |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Status |
|---|----------|--------|
| 1 | Does `/putaway/scanFlowBinLocation` return a complete `PutAwayMobileDto` including `putAwayItemDataList` with `unitLoadList`? | **Open** — verify before applying Fix E; check `MobilePutAwayService.scanFlowBinLocation` return value |
| 2 | Is there a "resume putaway" feature where `currentIndex > 0` on re-entry is intentional? | **Open** — no evidence of resume in the code, but confirm with product owner before fixing |
| 3 | Should `storePalletOnLocation` also reset `currentIndex` when setting `putawayInfo = null`? | **Resolved** — No: setting `putawayInfo = null` already breaks the `v-if="info"` guard; but `setCurrentIndex(0)` in `calculatePutawayList` is the correct reset point |
| 4 | v2 applicability | **Open** — if v2/wms2-mobile-ui has a putaway flow with the same Vuex pattern, check for the same stale-index bug |

---

## 9.1 Acceptance Script

Verify script: `sbdocs/9-System/scripts/verify-260427-putaway-unitloadlist-undefined-crash.sh`

Run after implementation:
```bash
bash sbdocs/9-System/scripts/verify-260427-putaway-unitloadlist-undefined-crash.sh
```

Required final output: `Result: N pass, 0 fail, M skip`

---

## 9.2 Recommended OMC Composition

| Aspect | Value | Rationale |
|--------|-------|-----------|
| **Size class** | Standard | 3 files, 5 fixes, mechanical substitutions plus one store action fix |
| **Plan-review step** | `critic` | Recommended before implementing Fix E (API contract unknown) |
| **Implementation shape** | `executor` | Mechanical substitution; verify-script provides exit gate |
| **Verification step** | verify-script + manual device smoke | Automated checks cover code shape; manual test covers rendered behavior |
| **Code-review step** | `code-reviewer` | Verify no `info.putAwayItemDataList[currentIndex]` pattern survived in template |
| **Commit step** | `git-master` | Single commit per fix group |

## Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | All callsites enumerated | ✓ §0 — all 7 sites covered or excluded |
| 2 | Adjacent bugs | ✓ §2 — 5 distinct bugs found, all in-scope |
| 3 | Backward compatibility | ✓ §9 — Fix E has an API contract risk flagged; all others are additive guards |
| 4 | Concurrency | no — this is a single-user mobile session; no concurrent access to Vuex store |
| 5 | Multi-tenant | no — putaway flow is per-tenant but the bug is in client-side JS state; no cross-tenant DB query involved |
| 6 | Error handling | ✓ Fix B/C use ternary fallbacks (`? 0 : ''`) so display degrades gracefully |
| 7 | Observability | no — no metrics/logging added; the crash is visible in browser console and is fixed, not logged |
| 8 | Rollout / migration | ✓ §8 — no DB migration; pure frontend deploy |
| 9 | Test coverage | ✓ §7 — unit + manual tests defined |
| 10 | Cross-version (v1↔v2) | ✓ §10 Q4 — flagged as open; check if wms2-mobile-ui has same pattern |
