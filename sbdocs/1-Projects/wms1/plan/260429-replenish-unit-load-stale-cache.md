---
title: "Replenish — Unit Load Quantities Stale Due to Cache Short-Circuit"
ticket: ""
ticket_url: ""
type: "bug"
priority: "high"
status: "verified"
project:
  - wms1
version: "v1"
requester: ""
created: "2026-04-29"
updated: "2026-04-29"
related:
  - ""
tags:
  - plan
  - replenish
  - mobile-ui
---

# Replenish — Unit Load Quantities Stale Due to Cache Short-Circuit

**Project:** wms1 | **Version:** v1 | **Type:** bug
**Priority:** high
**Status:** ready-for-review
**Date:** 2026-04-29

> All claims were verified against source code before drafting. Two proposed fixes were confirmed correct; three additional findings were added during verification.

---

## 0. Affected sites (enumeration before drafting)

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `components/replenish/process/selectUnitLoad.vue:207-213` | `fetchSourceOptions` — cache-read branch short-circuits API call | **yes — primary defect** | **yes — Fix A** |
| 2 | `components/replenish/process/selectSource.vue:240` | Stale comment `"then selectUnitLoad will reuse the cached result without another call"` | yes — documentation drift | **yes — Fix B** |
| 3 | `plugins/persistedState.client.js` | `createPersistedState()(store)` — no `paths` option, full store including `unitLoadsCache` persisted to `localStorage` | contributing factor (amplifies defect #1) | **no — follow-up only** |
| 4 | `util/replenishUnitLoads.js:24` | `quantity: row[4] \|\| 'N/A'` — falsy-0 becomes `'N/A'`, causing `qtyInUnitLoad = 0` for zero-quantity ULs | independent bug | **no — separate fix** |
| 5 | `components/replenish/process/selectSource.vue:288-321` | `submit()` unconditionally dispatches `updateOrderSourceLocation` even when location is unchanged | separate UX issue | **no — out of scope** |
| 6 | `components/replenish/process/selectSource.vue:237-241` | `clearUnitLoadsForItem` conditional — only fires when `scannedLocation !== orderSource`; the "suggested source" path never clears | same root-cause (stale data on suggested-source path) | no — Fix A makes this moot |
| 7 | `components/replenish/process/selectUnitLoad.vue:180-182` | `activated()` dead code (no `<keep-alive>` in `pages/replenish.vue`) | no | no — harmless |

---

## 1. Problem Statement

### Symptom

When an operator opens `selectUnitLoad.vue` (replenish step `2.5_unitLoad`), the unit load quantities displayed — and the upper bound used to validate `qtySelected` — can be stale. The values shown may reflect a previous session's data or a prior replenish operation from a different device, because the component reads from `unitLoadsCache` in Vuex state and skips the API call on a cache hit.

### Worst-case scenario

The operator selects a unit load and enters a `qtySelected` that the backend then rejects because the actual available quantity is lower than what the mobile UI showed. The operator sees a confusing error with no clear explanation, and the order is left incomplete.

### Reproduction

1. Complete a replenish operation for item X from location A — this populates `unitLoadsCache[itemDataId]`.
2. Before opening replenish again, another device or backend process moves or depletes stock from location A.
3. Open a new replenish order for the same item X. Navigate to `selectUnitLoad.vue`.
4. The stale cached quantities from step 1 are displayed.
5. Reload the page — same stale data reappears because `vuex-persistedstate` mirrors the full Vuex store (including `unitLoadsCache`) to `localStorage` with no exclusions.

---

## 2. Root Cause Analysis

### Bug 1 — `fetchSourceOptions` short-circuits on cache hit (PRIMARY)

**File:** `components/replenish/process/selectUnitLoad.vue:207-213`

```js
// CURRENT (buggy)
const cached = this.$store.state.replenish.unitLoadsCache
  && this.$store.state.replenish.unitLoadsCache[itemDataId]
if (cached && Array.isArray(cached) && cached.length) {
  this.allSourceOptions = cached          // ← API never called; stale data served
} else {
  this.allSourceOptions = await fetchUnitLoadsForItem(this.$axios, itemDataId)
  this.$store.commit('replenish/setUnitLoadsForItem', { itemDataId, unitLoads: this.allSourceOptions })
}
```

`fetchSourceOptions` is called on every mount via the `order` watcher (`immediate: true`, line 147). However, the first thing it does on line 207 is check `unitLoadsCache[itemDataId]`. If a cache entry exists, the API is never called. Because `vuex-persistedstate` persists the entire Vuex store to `localStorage` (no `paths`/`reducer` option), this cache entry survives page reloads and even browser closes.

**Why the `mounted` / `activated` distinction doesn't help:** `pages/replenish.vue` renders all steps with plain `v-if` (lines 4–8), not `<keep-alive>`. So `selectUnitLoad.vue` IS recreated on every visit — `mounted()` fires. The problem is not "we don't re-enter `fetchSourceOptions`"; the problem is that `fetchSourceOptions` exits through the cache path without ever hitting the API.

### Bug 2 — Stale comment in `selectSource.vue` (DOCUMENTATION)

**File:** `components/replenish/process/selectSource.vue:240`

```js
// CURRENT (stale after Fix A ships)
// then selectUnitLoad will reuse the cached result without another call.
```

This comment was accurate when written but will become misleading after Fix A removes the cache-read in `selectUnitLoad.vue`. It will imply caching behavior that no longer exists.

### Why the "suggested source" path was always broken

`selectSource.vue:237-241` clears the cache only when `scannedLocation !== orderSource`. When the operator does not change the location (the "just hit Next" path), the conditional is false, the cache is NOT cleared, and `selectUnitLoad.vue` would have served stale data. Fix A eliminates this path entirely.

### Contributing factor — `vuex-persistedstate` full-store persistence

`plugins/persistedState.client.js`:
```js
createPersistedState()(store)  // no options → persists ALL state to localStorage
```

This amplifies Bug 1: once `unitLoadsCache` is populated, it survives page reloads indefinitely until the operator logs out or clears `localStorage`. This is a follow-up concern (see §8); it does not block this plan.

---

## 3. Fix Design

### Fix A — Always fetch fresh on entry to `selectUnitLoad.vue`

**File:** `components/replenish/process/selectUnitLoad.vue:207-213`

**Before:**
```js
const cached = this.$store.state.replenish.unitLoadsCache
  && this.$store.state.replenish.unitLoadsCache[itemDataId]
if (cached && Array.isArray(cached) && cached.length) {
  this.allSourceOptions = cached
} else {
  this.allSourceOptions = await fetchUnitLoadsForItem(this.$axios, itemDataId)
  this.$store.commit('replenish/setUnitLoadsForItem', { itemDataId, unitLoads: this.allSourceOptions })
}
```

**After:**
```js
this.allSourceOptions = await fetchUnitLoadsForItem(this.$axios, itemDataId)
this.$store.commit('replenish/setUnitLoadsForItem', { itemDataId, unitLoads: this.allSourceOptions })
```

**Why this and not alternatives:**
- Removing the cache-read is the minimal, targeted change — 4 lines removed, 0 lines added.
- Still commits `setUnitLoadsForItem` so the fresh data overwrites any stale cache entry. Other consumers (if any) and `vuex-persistedstate` will see refreshed data.
- The existing `optionsLoading` flag disables the autocomplete and shows a loading indicator during the fetch — no UX regression.
- The existing `catch` block at line 220 shows a toast on network failure and leaves `allSourceOptions` empty, which correctly renders "No unit loads found in location…" alert. No new error handling needed.
- The `_inFlightByItem` Map in `replenishUnitLoads.js:8` deduplicates concurrent calls for the same `itemDataId` — so even if `selectSource.vue` happens to have an in-flight request for the same item, the second call coalesces with it rather than firing a duplicate HTTP request.

**Side effect — double fetch on `selectSource` → `selectUnitLoad` forward flow:**
`selectSource.vue` also calls `fetchUnitLoadsForItem` at lines 243-248 (its own local `allSourceOptions` for location-validation). After Fix A, both components call it: `selectSource` first (for validation), then `selectUnitLoad` on mount. The `_inFlightByItem` dedup collapses these if they are concurrent; if sequential, there will be two HTTP calls. This is acceptable — correctness over a single extra request.

### Fix B — Remove stale comment in `selectSource.vue`

**File:** `components/replenish/process/selectSource.vue:240`

**Before:**
```js
if (this.scannedLocation && this.scannedLocation !== orderSource) {
  // Clear the old cached list so it doesn't pollute the next screen;
  // then selectUnitLoad will reuse the cached result without another call.
  this.$store.commit('replenish/clearUnitLoadsForItem', { itemDataId })
}
```

**After:**
```js
if (this.scannedLocation && this.scannedLocation !== orderSource) {
  // Clear the stale list so selectUnitLoad fetches fresh data for the new location.
  this.$store.commit('replenish/clearUnitLoadsForItem', { itemDataId })
}
```

**Why:** After Fix A, `selectUnitLoad` always fetches fresh regardless of cache state. The `clearUnitLoadsForItem` here still has value (it ensures the stale entry doesn't linger for other consumers), but the comment's claim that "selectUnitLoad will reuse the cached result" is now false. Update it to accurately describe what the clear achieves.

---

## 4. V1/V2 Applicability

This plan targets `v1/wms-mobile-ui` only. The same codebase pattern (`unitLoadsCache`, `selectUnitLoad.vue`, `selectSource.vue`) exists in `v2/wms2-mobile-ui`. A parallel plan should be filed for v2 once this ships.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | N/A — pure frontend code change, no DB migration | — | |
| 2 | **Feature flags / system properties** | N/A — no sysprop or env var controls this path | — | |
| 3 | **Config / env changes** | N/A | — | |
| 4 | **Deploy-order dependencies** | N/A — no API contract change; backend untouched | — | |
| 5 | **Data migration** | N/A | — | |
| 6 | **External systems** | N/A | — | |
| 7 | **Access / permissions** | N/A | — | |
| 8 | **Monitoring / alerts** | N/A — no new error modes introduced; existing toast-on-catch covers network failure | — | |

### 5.2 Implementation Checklist

- [ ] **Fix A**: In `selectUnitLoad.vue:fetchSourceOptions`, remove the `cached` variable, the `if (cached && ...) { ... } else { ... }` branch; replace the whole block with the unconditional `fetchUnitLoadsForItem` + `setUnitLoadsForItem` commit (4 lines removed, 2 kept).
- [ ] **Fix B**: In `selectSource.vue:240`, update the comment from `"then selectUnitLoad will reuse the cached result without another call"` to `"so selectUnitLoad fetches fresh data for the new location"` (or delete the second sentence).
- [ ] Run `yarn build` in `v1/wms-mobile-ui` to confirm no syntax errors.
- [ ] Manual smoke test per §6 Manual Test Plan before merge.
- [ ] Run `bash sbdocs/9-System/scripts/verify-260429-replenish-unit-load-stale-cache.sh` and confirm 0 FAIL.

---

## 6. Test Plan

### New / updated tests

No unit test harness exists in `v1/wms-mobile-ui` (`package.json` has no `test` script, no Jest config, no `tests/` directory for Vue components). Coverage is manual-only for this repo.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| **Happy path — forward flow, no cache** | dev/staging | 1. Open a replenish order. 2. Scan/confirm source location. 3. Observe `selectUnitLoad` loading indicator. 4. Check browser Network tab: `findByItemForReplenish` fired. | UL list loads fresh; loading spinner visible momentarily; network request confirmed | |
| **Suggested-source path (no location change)** | dev/staging | 1. Open held-up replenish order. 2. On `selectSource`, do NOT change the pre-filled location — just click Next. 3. Observe UL list. | `findByItemForReplenish` called even though location matches `orderSource`; fresh quantities shown | |
| **Stale cache scenario** | dev/staging | 1. Complete a replenish from location A. 2. Open another replenish for same SKU. 3. Navigate to `selectUnitLoad`. | `findByItemForReplenish` is called (not served from cache); no stale quantity shown | |
| **Post-reload staleness** | dev/staging | 1. Navigate to `selectUnitLoad`. 2. Reload browser page (`Cmd+R`). 3. `vuex-persistedstate` restores; navigate back to `selectUnitLoad`. | Still calls `findByItemForReplenish` on mount; fresh quantities after reload | |
| **Network failure** | dev/staging | 1. Disconnect network / set backend to error. 2. Navigate to `selectUnitLoad`. | Toast: "Failed to load source unit load options"; autocomplete disabled; "No unit loads found…" alert; no crash | |
| **Back-and-forth navigation** | dev/staging | 1. `selectUnitLoad` → Back → `selectSource` → Next → `selectUnitLoad` | Each entry to `selectUnitLoad` triggers a fresh fetch; second quantity matches DB | |
| **Build succeeds** | local | `yarn build` in `v1/wms-mobile-ui` | Zero errors; no warnings about removed variables | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Unit tests for `fetchSourceOptions` | No test harness in `v1/wms-mobile-ui` — no Jest config, no component test runner. Manual verification is the only option unless a test suite is added. |
| `selectSource.vue` submit() double-fetch interaction | The fix does not change `selectSource.vue` behavior; double-fetch is an existing pre-fix condition tolerated by `_inFlightByItem` dedup. |

---

## 8. Notes

### Additional findings — not in scope but documented

#### A. `quantity: row[4] || 'N/A'` — falsy-0 normalization (`replenishUnitLoads.js:24`)

```js
quantity: row[4] || 'N/A',   // 0 is falsy → shown as 'N/A', not 0
```

When `row[4]` is the integer `0` (a unit load with zero available quantity), the `||` short-circuits to `'N/A'`. This causes `qtyInUnitLoad` to display as 0 in the UI even when the raw data held a valid zero. The correct fix is `row[4] ?? 'N/A'` (nullish coalescing). **Out of scope here; file a separate plan.**

#### B. `selectSource.vue.submit()` unconditional `updateOrderSourceLocation` dispatch

`submit()` (lines 315) always dispatches `updateOrderSourceLocation` even when `value === orderSource`. The backend call triggers `clearULBatch`. On the happy path where the location is unchanged, this is a wasted write and a cache-clear that erases a valid batch. **Out of scope here; separate UX bug.**

#### C. `activated()` dead code in `selectUnitLoad.vue:180-182`

`pages/replenish.vue` uses plain `v-if` (lines 4-8), not `<keep-alive>`. Vue only fires `activated()` inside `<keep-alive>`. The hook is effectively dead. It only calls `focusAndSelect`, which is harmless if called. Leave in place — it provides a correct fallback if `<keep-alive>` is ever added.

#### D. `vuex-persistedstate` full-store persistence — follow-up

The root amplifier of Bug 1 is that `createPersistedState()(store)` in `plugins/persistedState.client.js` persists the entire Vuex store with no exclusions. Adding a `reducer` or `paths` option to exclude `unitLoadsCache` would prevent stale data from surviving across sessions. This is a worthwhile hardening step but is not required for the fix in this plan.

### Related plans

- A v2 port plan should be filed for `v2/wms2-mobile-ui` (`selectUnitLoad.vue`, `selectSource.vue` in that repo exhibit the same pattern).

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-260429-replenish-unit-load-stale-cache.sh`

Run after implementation:
```bash
bash sbdocs/9-System/scripts/verify-260429-replenish-unit-load-stale-cache.sh
```

A "DONE" claim is not accepted if the script exits non-zero.

### 9.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Trivial | 2 files, ~6 lines changed total, no contract change, no backend touch |
| **Pre-draft step** | none | Analysis already complete; this plan IS the pre-draft output |
| **Plan-review step** | none (optional critic) | Trivial mechanical fix; critic optional |
| **Implementation shape** | executor | Single logical cluster; verify script is the exit gate |
| **Verification step** | verify-script + manual smoke | Mandatory; script checks code shape, smoke confirms UX |
| **Code-review step** | none | Trivial diff; inline review sufficient |
| **Commit step** | git directly | Two small files; one atomic commit |

### Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | **All callsites enumerated** — every row in §0 visited by §3 or excluded with rationale | ✓ §0 rows 1-2 fixed; rows 3-7 explicitly excluded with rationale |
| 2 | **Adjacent bugs** — other classes / methods with the same root-cause pattern | ✓ `selectSource.vue:243-248` also reads `unitLoadsCache` but Fix A makes it irrelevant for `selectUnitLoad`'s staleness; `selectSource`'s own read is acceptable (local validation) |
| 3 | **Backward compatibility** — API contract, DB schema, persisted state, frontend payload shape | ✓ No API change; `setUnitLoadsForItem` commit still present, so `vuex-persistedstate` snapshot format unchanged |
| 4 | **Concurrency** — race conditions | ✓ `_inFlightByItem` dedup in `replenishUnitLoads.js:8-40` collapses concurrent calls for the same `itemDataId`; no new race introduced |
| 5 | **Multi-tenant** | ✓ N/A — v1 mobile UI is single-tenant |
| 6 | **Error handling** — new failure modes | ✓ Existing `catch` at line 220 handles network failure with toast; no new throw paths |
| 7 | **Observability** | ✓ N/A — no new metrics needed; existing toast-on-error covers the operator-facing path |
| 8 | **Rollback / migration** | ✓ N/A — pure JavaScript change; revert is a one-line commit |
| 9 | **Test coverage** | ✓ No test harness exists; manual smoke plan provided in §6 |
| 10 | **Cross-version (v1↔v2)** | ✓ v2 port deferred; documented in §8 Notes |

---

## 10. Implementation Status — 2026-04-29

### Changes made

| File | Change | Lines |
|---|---|---|
| `components/replenish/process/selectUnitLoad.vue` | **Fix A** — removed `const cached` read and `if/else` cache branch; replaced with unconditional `fetchUnitLoadsForItem` + `setUnitLoadsForItem` commit | 207-213 → 2 lines |
| `components/replenish/process/selectSource.vue` | **Fix B** — updated stale comment at line 240 | 1 line |
| `tests/e2e/replenish.spec.ts` | **New** — 18 e2e tests covering Critical list navigation, selectSource flow, and the three cache-bypass scenarios | 420 lines |
| `package.json` | **Restored** — file was gitignored and missing from disk; reconstructed from `package-lock.json` `packages[""]` entry | New file |

### Verification results

```
verify-260429-replenish-unit-load-stale-cache.sh: 7 pass, 0 fail
```

```
Playwright replenish.spec.ts: 18 passed (56.1s)
Playwright full suite:       125 passed, 5 failed (pre-existing — home/navigation/picking; unrelated to this plan)
```

The 5 pre-existing failures (`home.spec.ts:17`, `navigation.spec.ts:10/16/22`, `picking.spec.ts:15`) existed before this plan and are caused by unrelated auth/strict-mode issues in those test files.

### Implementation notes

- `selectSource.vue` retains its own cache-read in `fetchSourceOptions` (lines 243-248). This is intentional — `selectSource` needs cached data to validate the typed location during submit. Only `selectUnitLoad.vue`'s cache bypass was required by this plan.
- The `package.json` was gitignored and missing from disk. Restored from `package-lock.json` v3 `packages[""]` manifest. Added `"test": "playwright test"` script.
- No backend changes required.

## 11. Field Verification — 2026-04-29

### Investigation: "Fix didn't work" report

After implementation, the user reported that the Mobile UI still showed `UL297236 (6)` in the replenish unit load dropdown despite having adjusted the quantity to 7 via the Web UI Stock Units page. This triggered a deeper investigation.

**DB query result (direct via MCP against `wh01_om1`):**

```
stockunit_id: 948959355 | labelid: UL297236 | amount: 6.0000 | reservedamount: 6.0000 | entity_lock: 0
```

**Root cause of the false negative**: At the time of the first test, the DB still had `amount = 6.0000`. The Web UI `adjustAmount` call had not actually been applied to this stockunit record. Fix A was making a fresh HTTP call as designed — the API was truthfully returning 6 because the DB had not been updated.

**Confirmation**: The user re-applied the adjustment to 7 via the Web UI. The Mobile UI replenish dropdown immediately reflected `UL297236 (7)`. **Fix A is confirmed working.**

**Additional observation**: `reservedamount = 6.0000` equals the full `amount` — meaning 0 available stock on this unit load. The `findByItemForReplenish` query returns `su.amount` (total), not `su.amount - su.reservedamount` (available). This is a separate, pre-existing display characteristic and is out of scope for this plan.
