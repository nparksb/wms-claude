---
title: "Putaway blank screen after redeploy — stale persisted Vuex state + unguarded derefs"
ticket: ""
ticket_url: ""
type: bug
priority: High
status: archived
project: [wms1]
version: v1
requester: ""
created: 2026-07-09
updated: "2026-07-15"
related: []
db_verified: false
db_verified_rationale: "Frontend / client-state bug — there is no DB read path involved. Verification is the localStorage / persisted-state probe (§1 repro), not SQL."
tags:
  - plan
  - putaway
  - mobile-ui
  - frontend
  - vuex-persistedstate
---

# Putaway blank screen after redeploy — stale persisted Vuex state + unguarded derefs

**Ticket:** (none — internal bug report)
**Project:** wms1 (v1/wms-mobile-ui) | **Version:** v1 | **Type:** bug
**Priority:** High
**Status:** implemented — 2026-07-09 on `fix/260709-putaway-blank-screen` → PR #98 into develop; verify script 18 pass, 0 fail. (critic APPROVE-WITH-CHANGES + re-review applied)
**Date:** 2026-07-09

> **Repo:** `/home/nampark/dev/wms-claude/v1/wms-mobile-ui` (Nuxt 2.15 / Vue 2.6 / Vuetify 2.6, SPA `ssr:false`, served at `/mobile/`).
> **DB verification:** `db_verified: false` — this is a client-side state/render bug with **no DB read path**. The verification gate is the **localStorage / persisted-state probe** in §1, not a SQL query.

---

## 0. Affected Sites (sweep enumeration)

Every operation page under `pages/` was audited for the **two-part fragility** that produces this bug:

- **(A) Missing on-mount reset** — the page does not commit its store back to the initial `process` / clear its data on `mounted()`/`created()`, so `vuex-persistedstate` rehydrates whatever sub-screen the operator was last on.
- **(B) Unguarded deref of persisted state** — a sub-screen component (or its `computed`) dereferences a persisted object/array that can be `null`, partial, or out-of-range **without a guard**, throwing a render-time `TypeError` that blanks the `<v-card>` subtree.

A page only produces the reported **blank `<v-card>`** when it has **BOTH** (A) and (B). Missing reset alone (A) yields a harmless *stale sub-screen* (data is shown, just from a prior session); unguarded deref alone (B) never fires because a reset forces the safe entry screen.

> **Refinement of the incoming evidence:** the bug report said putaway "is the only page lacking the on-mount reset." That is not literally true — `cycle-count`, `move-stock`, `move-unitload`, `palletizing`, and `transfer-order` also lack a full on-mount reset. The accurate statement is: **putaway is the only page with BOTH (A) and (B)**, which is why it is the only one that renders blank. This distinction is what the sweep exists to surface.

| # | Page (`pages/`) | Store | (A) Missing mount reset? | (B) Unguarded persisted deref? | Blank-screen risk | Disposition |
|---|---|---|---|---|---|---|
| 1 | `putaway.vue` | `putaway` | **YES** | **YES** — `scanFlowBin.vue` computed `putawayItems()` (`putawayInfo.putAwayItemDataList`, line ~76) + `info.emptyPallet` (line 17, **outside** the `v-if="info"` block) + template idx derefs (lines 14, 26-37); `storeBox.vue` lines 8-13 | **HIGH — reported** | **IN SCOPE (primary)** |
| 2 | `transfer-order.vue` | `transferOrder` | YES | Partial — `scanTransferLane.vue:10` `v-if="orderPosition.currentPickSource"` derefs a null-able parent (`orderPosition`) before checking it | LOW-MED (latent; requires `orderPosition===null` while `process==='4_transferLane'` — both persist together so usually a stale non-null object) | **OUT (follow-up recommended)** — see §5.5 |
| 3 | `lookup.vue` | `lookup` | No — `mounted()` commits `setSearchResult(null)` + `setProcess('search')` | YES — `resultUnitLoad/resultLocation/resultStock` do `result.unitLoad[getUlIdx].*` / `unitLoad.stockUnitList[getStockIdx].*` idx derefs | **Low (latent)** — the `mounted()` reset lands the operator on `search`, but (Vue-lifecycle) a result child can still render **once** against stale state before that reset fires; it self-recovers to `search`. Not the reported blank. | OUT (latent — note only; would be fully closed by leaf-level `?.` guards) |
| 4 | `cycle-count.vue` | `cycleCount` | YES (only `tabChanged` resets, no `mounted()`) | No — all `stockUnitInfo.*` derefs sit inside `v-if="stockUnitInfo"` | Stale sub-screen only | OUT (cosmetic; optional reset — §5.5) |
| 5 | `move-stock.vue` | `moveStock` | **YES** | No — `currentStock.*` derefs sit inside `v-card-subtitle v-if="currentStock"` | Stale sub-screen only | OUT (cosmetic; optional reset — §5.5) |
| 6 | `move-unitload.vue` | `moveUnitload` | **YES** | No unguarded nested derefs found | Stale sub-screen only | OUT (cosmetic; optional reset — §5.5) |
| 7 | `palletizing.vue` | `palletizing` | YES (boolean `parcelScan`/`rapidPalletScan` flags; only `tabChanged` resets) | No | Stale sub-screen only | OUT (cosmetic) |
| 8 | `picking.vue` | `picking` | No — `mounted()` commits `setProcess('0_section')` + `setPickingOrders([])` | n/a (guarded / reset) | None | OUT (safe — the baseline to mirror) |
| 9 | `truck-loading.vue` | `truckLoading` | No — `mounted()` commits `setTruckLoadingInfo(null)` + `setSuccessMsg(null)` + `setProcess('1_select')` | n/a | None | OUT (safe) |
| 10 | `replenish.vue` | `replenish` | No — `mounted()` commits `setOrder(null)` + `setProcess('1_select')` | n/a | None | OUT (safe) |
| 11 | `replenish-request.vue` | `replenish` | No — `mounted()` commits `setLocationScan(true)` + `setReplenishOrder(null)` | n/a | None | OUT (safe) |
| 12 | `transfer-order.vue` | (see #2) | — | — | — | (row #2) |
| 13 | `index.vue` | `home` / root | N/A — no `process` state machine (auth landing page) | N/A | None | OUT (N/A) |

**Sweep result:** 1 page in scope (primary), 1 page flagged as a low-severity follow-up (§5.5), the rest out of scope with rationale. The primary fix (§5.1-5.4) resolves the reported blank screen.

---

## 1. Problem Statement

After a **redeploy**, the mobile **Putaway** screen (`/mobile/putaway`) renders a **blank `<v-card>`** — the card frame is present but no title, no scan field, no content. Operators cannot start putaway until the page is recovered. Other operation screens are not reported blank.

### Symptom
- Page: `pages/putaway.vue`. The card chrome renders; the conditional child component (`scanFlowBin.vue` or `storeBox.vue`) renders as an empty subtree.
- No 4xx/5xx network error — the backend is never called on the blank render (the crash happens during Vue's render pass before any user action).
- The browser console shows a Vue render `TypeError` (`Cannot read properties of null/undefined`) originating in a `components/putaway/*` template or computed.

### State-probe reproduction (the verification gate — no SQL)
1. Open `/mobile/putaway`, scan a pallet, and advance into a data sub-screen (e.g. `3_flowbin` or `4_box`). Confirm content renders.
2. Simulate the redeploy event: with the app still mid-flow, **reload the tab** (Ctrl-R / hard reload). → **Putaway renders blank.**
3. **Probe:** open DevTools → Application → Local Storage → the `vuex` key. Observe `putaway.process` is still `"3_flowbin"`/`"4_box"` and `putaway.putawayInfo` holds a stale/partial object (or is `null` after the redeploy wiped the shape the old bundle expected).
4. Run `localStorage.clear()` in the console, reload → **Putaway renders correctly** (back to `1_select`). This confirms the cause is **stale persisted state**, not the new bundle or the backend.

---

## 2. Root Cause Analysis

Three code facts combine into the bug:

### 2.1 The store persists the *entire* Vuex tree, with no filter
`plugins/persistedState.client.js`:
```js
import createPersistedState from 'vuex-persistedstate'
export default ({ store }) => {
  createPersistedState()(store)   // no `paths` / `reducer` — whole store persists
}
```
Every module's state — including `putaway.process`, `putaway.putawayInfo`, `putaway.currentIndex` — is written to `localStorage` on every mutation and **rehydrated on every page load, reload, redeploy, and even after logout** (the plugin does not clear on logout). The project `CLAUDE.md` already warns: *"vuex-persistedstate persists the entire store … reset `process` on page mount."*

### 2.2 `pages/putaway.vue` is the one operation page with **no** on-mount reset
`pages/putaway.vue` (full file) has only a `computed.process` and **no `mounted()`/`created()`**:
```js
export default {
  components: { ScanPallet, ReplenishChoice, ScanFlowBin, StoreBox, StorePallet },
  computed: {
    process() { return this.$store.state.putaway.process }
  },
}
```
Contrast the baseline `pages/picking.vue:35-38`:
```js
mounted() {
  this.$store.commit('picking/setProcess', '0_section')
  this.$store.commit('picking/setPickingOrders', [])
}
```
Because putaway never resets, on reload the persisted `process` (`3_flowbin`/`4_box`) drives `pages/putaway.vue` to render `scanFlowBin.vue` / `storeBox.vue` immediately, against whatever `putawayInfo` survived in `localStorage`.

### 2.3 The data sub-screens dereference persisted state **without guards**
- `components/putaway/scanFlowBin.vue:76` — the `putawayItems()` computed derefs `putawayInfo` with **no guard**, and it runs on every render (used at line 14 `{{ putawayItems.length }}`, which is **not** inside a `v-if`):
  ```js
  putawayItems() {
    return this.$store.state.putaway.putawayInfo.putAwayItemDataList   // throws if putawayInfo is null
  }
  ```
- `components/putaway/scanFlowBin.vue:25-37` — inside `v-card-subtitle v-if="info"`, it derefs `info.putAwayItemDataList[currentIndex].unitLoadList.length` / `.flowBinLocationList.join(...)` / `.overstockLocationList.join(...)`. `info` may be non-null but `putAwayItemDataList[currentIndex]` can be **undefined** (index out of range, or a partial persisted object) → deref of `undefined` throws.
- `components/putaway/storeBox.vue:8-13` — inside `v-card-subtitle v-if="info"`, derefs `info.putAwayItemDataList[currentIndex].itemDataNumber` etc. Lines 15-16 **already** received optional chaining (`info?.putAwayItemDataList?.[currentIndex]?.unitLoadList?.length`) from an earlier partial fix — lines 8-13 were left unguarded.

A thrown `TypeError` during Vue's render aborts the render of that component subtree → the parent `<v-card>` shows empty. That is the blank screen.

### 2.4 Why the store mutation itself is also unsafe
`store/putaway.js:19-22` `setCurrentIndex` derefs `putawayInfo` unconditionally:
```js
setCurrentIndex(state, payload) {
  state.currentIndex = payload
  state.currentItem = state.putawayInfo.putAwayItemDataList[payload]   // throws if putawayInfo is null
},
```
This matters for the fix: a `resetState` that sets `putawayInfo = null` must **not** route through `setCurrentIndex` (it would throw), and any future caller that commits `setCurrentIndex` while `putawayInfo` is null would hit the same crash. `setCurrentIndex` must be made null-safe.

### Affected Locations

| # | File | Line (approx) | Description |
|---|------|-------------|-------------|
| 1 | `pages/putaway.vue` | 18-25 | No on-mount reset — add a `created()` reset (see §5.2 / M-1) |
| 2 | `store/putaway.js` | 1-7, 9 | Add `resetState` mutation |
| 3 | `store/putaway.js` | 19-22 | `setCurrentIndex` derefs null `putawayInfo` — make null-safe |
| 4 | `components/putaway/scanFlowBin.vue` | 76 | `putawayItems()` computed unguarded deref |
| 5 | `components/putaway/scanFlowBin.vue` | 25-37 | `v-if="info"` too weak; idx derefs unguarded |
| 6 | `components/putaway/storeBox.vue` | 8-13 | Idx derefs unguarded (15-16 already fixed) |

---

## 3. Backend Exoneration & Why the Redeploy Event (not a code change) is the Trigger

**The backend is not involved.**
- No merged backend commit touches the putaway read path in this batch; the newest `PutawayService`/`/putaway/*` change **predates** this merge batch.
- The putaway DTOs default their collections to empty `ArrayList` (so a *live* backend response never yields a null `putAwayItemDataList`). The null/partial `putawayInfo` seen at render time comes from **`localStorage`, not from a fresh API call** — on the blank render the API is never hit.
- Neither **SBDEV-2512** (partitionAllowed split-pick overstock guard) nor **SBDEV-2492** is involved — those are backend/API tickets on unrelated paths.

**Why a redeploy *event* triggers it (no code change required):**
The bug is **data-in-`localStorage` dependent, not code-dependent**. A redeploy does two things at once for every operator:
1. It forces every open browser tab to reload the new SPA bundle.
2. That reload happens **while `putaway.process` is still parked on a data sub-screen** (operators leave the handheld mid-flow at shift boundaries; a redeploy is often scheduled exactly then).

On that reload, §2.2 (no reset) + §2.3 (unguarded deref) fire against the stale/partial persisted `putawayInfo`. The redeploy is merely the *event that reloads every tab simultaneously* — the same blank screen reproduces from a plain Ctrl-R mid-flow with **no deploy at all** (see §1 repro). No line of code needed to change for the bug to appear; it has been latent since the page was written without a reset.

---

## 4. Architecture Overview

### 4.1 Store persistence flow
```
mutation commit ──► Vuex state ──► vuex-persistedstate (whole store) ──► localStorage["vuex"]
                                                                              │
   page load / reload / redeploy / (even) logout  ◄───── rehydrate whole tree
```
No `paths`/`reducer` filter → `putaway.{process,putawayInfo,currentIndex,currentItem,pallet}` all survive.

### 4.2 Putaway component tree (state-machine on `process`)
```
pages/putaway.vue  (renders child by computed `process`)
├─ '1_select'  → components/putaway/scanPallet.vue        (safe entry screen)
├─ '2_choice'  → components/putaway/replenishChoice.vue   (guards with `info ? … : 'Unknown'`)
├─ '3_flowbin' → components/putaway/scanFlowBin.vue       ◄ UNGUARDED derefs (crash)
├─ '4_box'     → components/putaway/storeBox.vue          ◄ lines 8-13 unguarded (crash)
└─ '5_store'   → components/putaway/storePallet.vue       (guards with `info ? … : 'Unknown'`)
```
Only `scanFlowBin` (`3_flowbin`) and `storeBox` (`4_box`) crash — precisely the sub-screens an operator is parked on mid-flow.

### 4.3 Key Files

| File | Role |
|------|------|
| `plugins/persistedState.client.js` | Registers whole-store persistence (root cause enabler) |
| `pages/putaway.vue` | Putaway route; renders sub-screen by `process`; **missing reset** |
| `pages/picking.vue` | Baseline pattern — `mounted()` reset to mirror |
| `store/putaway.js` | Putaway module state + mutations (`resetState` to add; `setCurrentIndex` to harden) |
| `components/putaway/scanFlowBin.vue` | `3_flowbin` sub-screen — unguarded computed + idx derefs |
| `components/putaway/storeBox.vue` | `4_box` sub-screen — unguarded idx derefs (8-13) |

---

## 5. Fix Design

Guiding principle: **smallest viable diff**. Primary fix = reset-on-mount (stops the page from ever rendering a stale sub-screen) **plus** defensive guards (so a stale/partial object can never throw even if some other path lands on a data screen). Both layers are cheap and complementary — the reset prevents the trigger; the guards make the components crash-proof by construction.

### 5.1 `store/putaway.js` — add `resetState`, make `setCurrentIndex` null-safe

State shape (confirmed, `store/putaway.js:1-7`): `{ process:'1_select', pallet:null, putawayInfo:null, currentIndex:0, currentItem:null }`.

**Before:**
```js
export const mutations = {
  setPallet(state, payload) { state.pallet = payload },
  setProcess(state, payload) { state.process = payload },
  setPutawayInfo(state, payload) { state.putawayInfo = payload },
  setCurrentIndex(state, payload) {
    state.currentIndex = payload
    state.currentItem = state.putawayInfo.putAwayItemDataList[payload]
  },
  // …
}
```

**After:**
```js
export const mutations = {
  setPallet(state, payload) { state.pallet = payload },
  setProcess(state, payload) { state.process = payload },
  setPutawayInfo(state, payload) { state.putawayInfo = payload },
  setCurrentIndex(state, payload) {
    state.currentIndex = payload
    state.currentItem = state.putawayInfo?.putAwayItemDataList?.[payload] ?? null
  },
  resetState(state) {
    state.process = '1_select'
    state.pallet = null
    state.putawayInfo = null
    state.currentIndex = 0
    state.currentItem = null
  },
  // …
}
```
*(Optional chaining is already used in this repo's templates — `storeBox.vue:15-16` — so `?.`/`??` are safe with the Nuxt 2 babel/core-js build.)* `resetState` sets fields directly and deliberately does **not** call `setCurrentIndex`, avoiding the null deref.

### 5.2 `pages/putaway.vue` — add a `created()` reset (mirror `picking.vue`'s intent, but earlier in the lifecycle)

**Before:**
```js
export default {
  components: { ScanPallet, ReplenishChoice, ScanFlowBin, StoreBox, StorePallet },
  computed: {
    process() { return this.$store.state.putaway.process }
  },
}
```

**After:**
```js
export default {
  components: { ScanPallet, ReplenishChoice, ScanFlowBin, StoreBox, StorePallet },
  computed: {
    process() { return this.$store.state.putaway.process }
  },
  created() {
    this.$store.commit('putaway/resetState')
  },
}
```

> **Lifecycle — use `created()`, not `mounted()` (review M-1).** In Vue 2 a **child renders and mounts before its parent's `mounted()` hook runs**. If the reset were in `mounted()`, then on a hard reload with persisted `process='3_flowbin'` and `putawayInfo=null`, `scanFlowBin` would render **once against the stale/null state before** the parent reset fires — throwing a render `TypeError` and flashing a transient blank (defeating acceptance §8.2 #7 "no Vue render TypeError"). `created()` runs **before** the parent renders, so `process` is reset to `1_select` before any child sub-screen is instantiated — the data sub-screen never mounts against stale state. `picking.vue` happens to use `mounted()` and is safe only because its children have no unguarded top-level deref; putaway must reset in `created()` **and** keep the §5.3/§5.4 guards (defense in depth — the guards also protect any non-reset path that lands on a data screen).

### 5.3 `components/putaway/scanFlowBin.vue` — guard the derefs

**Before:**
```html
<v-card-subtitle v-if="info" :class="[completed() ? 'grey lighten-2 ma-4' : 'ma-4']">
  <div class="text-subtitle-2 mb-3">No of Packages to Putaway: {{
  info.putAwayItemDataList[currentIndex].unitLoadList.length }}</div>
  <div class="text-subtitle-2 mt-3 mb-3">Product on Container {{ info.unitLoadName }}</div>
  <div class="ml-4">
    SKU: {{ info.putAwayItemDataList[currentIndex].itemDataNumber }} <br/>
    Shipper: {{ info.putAwayItemDataList[currentIndex].clientName }} <br/>
    Name: {{ info.putAwayItemDataList[currentIndex].itemDataName }} <br />
  </div>
  <div class="text-subtitle-2 mt-3 mb-3">Storage Information</div>
  <div class="ml-4">
    Pickable Loc.: {{ info.putAwayItemDataList[currentIndex].flowBinLocationList.join(', ') }} <br/>
    Storage Loc.: {{ info.putAwayItemDataList[currentIndex].overstockLocationList.join(', ') }} <br/>
  </div>
</v-card-subtitle>
```
```js
putawayItems() {
  return this.$store.state.putaway.putawayInfo.putAwayItemDataList
},
```

**After:**
```html
<v-card-subtitle v-if="info && info.putAwayItemDataList && info.putAwayItemDataList[currentIndex]"
                 :class="[completed() ? 'grey lighten-2 ma-4' : 'ma-4']">
  <div class="text-subtitle-2 mb-3">No of Packages to Putaway: {{
  info.putAwayItemDataList[currentIndex]?.unitLoadList?.length }}</div>
  <div class="text-subtitle-2 mt-3 mb-3">Product on Container {{ info.unitLoadName }}</div>
  <div class="ml-4">
    SKU: {{ info.putAwayItemDataList[currentIndex]?.itemDataNumber }} <br/>
    Shipper: {{ info.putAwayItemDataList[currentIndex]?.clientName }} <br/>
    Name: {{ info.putAwayItemDataList[currentIndex]?.itemDataName }} <br />
  </div>
  <div class="text-subtitle-2 mt-3 mb-3">Storage Information</div>
  <div class="ml-4">
    Pickable Loc.: {{ info.putAwayItemDataList[currentIndex]?.flowBinLocationList?.join(', ') }} <br/>
    Storage Loc.: {{ info.putAwayItemDataList[currentIndex]?.overstockLocationList?.join(', ') }} <br/>
  </div>
</v-card-subtitle>
```
```js
putawayItems() {
  return this.$store.state.putaway.putawayInfo?.putAwayItemDataList || []
},
```
The strengthened `v-if` (requires `info && info.putAwayItemDataList && info.putAwayItemDataList[currentIndex]`) makes the block render only when the row exists; the inner `?.` are belt-and-suspenders. `putawayItems` returning `[]` keeps `{{ putawayItems.length }}` (line 14, outside the `v-if`) safe when `putawayInfo` is null.

**Also guard `scanFlowBin.vue:17` (review M-1 — the one deref outside the block above).** Line 17 sits in the always-rendered `<div>` (lines 12-23), **not** behind the `v-if="info"` at line 25, so it derefs the nullable `info` unconditionally on every render:

**Before:**
```html
<span v-if="info.emptyPallet" class="mr-3">…</span>
```
**After:**
```html
<span v-if="info && info.emptyPallet" class="mr-3">…</span>
```
Without this, the `created()` reset alone still leaves a first-render deref of `null.emptyPallet` on the `putawayInfo === null` reload path — the `created()` fix removes the *trigger*, but this guard is what makes the component crash-proof regardless of entry path (defense in depth). The verify script gains a negative check that the unguarded `v-if="info.emptyPallet"` form is gone.

### 5.4 `components/putaway/storeBox.vue` — guard lines 8-13 (match 15-16)

**Before:**
```html
SKU: <span class="primary--text">{{ info.putAwayItemDataList[currentIndex].itemDataNumber }}</span><br/>
Shipper: {{ info.putAwayItemDataList[currentIndex].clientName }} <br/>
Name: {{ info.putAwayItemDataList[currentIndex].itemDataName }} <br />
```

**After:**
```html
SKU: <span class="primary--text">{{ info?.putAwayItemDataList?.[currentIndex]?.itemDataNumber }}</span><br/>
Shipper: {{ info?.putAwayItemDataList?.[currentIndex]?.clientName }} <br/>
Name: {{ info?.putAwayItemDataList?.[currentIndex]?.itemDataName }} <br />
```
This matches the optional-chaining style already present at `storeBox.vue:15-16`.

### 5.5 Sweep follow-ups (OUT of primary scope — recorded for a separate change)

These were surfaced by the §0 sweep. They are **not required to fix the reported bug** and are intentionally excluded from the primary diff to keep it minimal; they are recommended as a small hardening follow-up:

- **`transfer-order` (`components/transferOrder/scanTransferLane.vue:10`)** — `v-if="orderPosition.currentPickSource"` derefs `orderPosition` before null-checking it. Recommend `v-if="orderPosition && orderPosition.currentPickSource"` and add a `mounted()` reset to `pages/transfer-order.vue` (`transferOrder/setProcess('1_select')` + clear the order). Low severity (requires `orderPosition===null` on a persisted `4_transferLane`).
- **Consistency resets** for `cycle-count.vue`, `move-stock.vue`, `move-unitload.vue`, `palletizing.vue` — add `mounted()` resets so a redeploy never shows a stale sub-screen. Cosmetic only (their derefs are already `v-if`-guarded; no crash).
- **`lookup` result components** — already protected by `lookup.vue`'s `mounted()` reset; the unguarded `[idx]` derefs are latent. Optional `?.` hardening if touched later.

Consider (separate, larger change — do **not** do here): add a `paths`/`reducer` filter to `plugins/persistedState.client.js` so only intentionally-durable state persists. That is the systemic fix but has broad blast radius across every module; out of scope for this bug.

---

## 6. File Change Summary

| # | File | Change | In primary scope? |
|---|------|--------|-------------------|
| 1 | `store/putaway.js` | Add `resetState` mutation; make `setCurrentIndex` null-safe (`?.`/`??`) | Yes |
| 2 | `pages/putaway.vue` | Add `created()` → `commit('putaway/resetState')` (NOT `mounted()` — see §5.2 / M-1) | Yes |
| 3 | `components/putaway/scanFlowBin.vue` | Strengthen `v-if`, `?.` on idx derefs (25-37), guard `putawayItems()` computed (76) | Yes |
| 4 | `components/putaway/storeBox.vue` | `?.` on idx derefs (8-13) to match 15-16 | Yes |
| 5 | `components/transferOrder/scanTransferLane.vue` + `pages/transfer-order.vue` | Guard `orderPosition.currentPickSource`; add mount reset | No — §5.5 follow-up |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **Database state** | N/A | Frontend/state bug — no DB read path. |
| 2 | **Feature flags / system properties** | N/A | No flags involved. |
| 3 | **Config / env changes** | N/A | No env or `nuxt.config.js` change. |
| 4 | **Deploy-order dependencies** | None | Frontend-only; no backend/OMS coordination. |
| 5 | **Data migration** | N/A | No persisted-schema migration. |
| 6 | **External systems** | N/A | No Keycloak/printer/API contract change. |
| 7 | **Access / permissions** | N/A | No new role. |
| 8 | **Deploy mechanism** | Frontend rebuild + redeploy (`yarn build` → Docker image on git tag; GitLab CI). | **Operator note:** operators whose browser still holds stale `localStorage` from *before* this fix may need **one** hard reload / cache clear after deploy for the new `created()` reset to run. After that first load the reset self-heals every subsequent session. |

### 7.2 Implementation Checklist
- [ ] `store/putaway.js`: add `resetState`; harden `setCurrentIndex`.
- [ ] `pages/putaway.vue`: add `created()` reset (NOT `mounted()` — see §5.2 / M-1).
- [ ] `components/putaway/scanFlowBin.vue`: strengthen `v-if`, add `?.`, guard `putawayItems()`.
- [ ] `components/putaway/storeBox.vue`: add `?.` on lines 8-13.
- [ ] Run acceptance script `verify-260709-putaway-blank-screen-stale-persisted-state.sh` → 0 FAIL.
- [ ] Manual test plan (§8) executed on dev (`yarn dev`), including the `localStorage.clear()` probe and the mid-flow reload scenario.
- [ ] (Optional, separate PR) §5.5 sweep follow-ups.

---

## 8. Testing Plan

> **No test suite exists** in this repo — `CLAUDE.md` states *"No test suite. No `yarn test` script, no Jest config. Manual verification only."* A Jest harness would have to be bootstrapped from scratch (see the `run-v1-wms-web-ui-jest-tests` note in the sibling web-ui repo for the pattern: `nvm` node + `node_modules/.bin/jest --testPathPattern=…`). Given the fix is a small, render-level guard change, the **primary verification is the manual state-probe plan below plus the acceptance script (§9)**. Unit tests are recorded as *optional / deliberately-skipped* unless a Jest harness is stood up.

### 8.1 Optional Jest component render tests (only if a harness is added)
If `@vue/test-utils` + `jest` are bootstrapped, add `components/putaway/__tests__/`:

| Test | What it asserts |
|------|-----------------|
| `scanFlowBin` mounts with `putawayInfo = null` | `mount()` does **not** throw; `putawayItems` computed returns `[]`; card renders empty subtitle, no error. |
| `scanFlowBin` mounts with partial `putawayInfo` (`putAwayItemDataList: []`, `currentIndex: 3`) | No throw (out-of-range index → `v-if` false, `?.` short-circuits). |
| `storeBox` mounts with `putawayInfo = null` and out-of-range index | No throw; lines 8-13 render empty. |
| `putaway.vue created()` | Commits `putaway/resetState`; `process` becomes `'1_select'` regardless of persisted value. |
| `store/putaway.js setCurrentIndex` with `putawayInfo = null` | Does not throw; `currentItem` becomes `null`. |

### 8.2 Manual test plan (primary verification)

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| 1 | Stale-state probe (the repro) | dev (`yarn dev`) | Advance putaway to `3_flowbin`; reload tab | Putaway renders the scan screen (reset to `1_select`), **not** blank | |
| 2 | `localStorage.clear()` confirms cause | dev | Reproduce blank on **pre-fix** build; `localStorage.clear()`; reload | Renders correctly → confirms stale persisted state was the cause | |
| 3 | Mid-flow reload at `4_box` | dev | Advance to `4_box` (storeBox); hard reload | Resets to `1_select`, no blank, no console `TypeError` | |
| 4 | Redeploy simulation | dev | Mid-flow at `3_flowbin`; stop+restart dev server; reload | Resets cleanly; no blank | |
| 5 | Happy path unaffected | dev | Full putaway flow: scan pallet → choice → flowbin → box → store | All sub-screens render and function as before | |
| 6 | Direct-nav guard | dev | Manually set `localStorage` `putaway.process='3_flowbin'`, `putawayInfo=null`; open `/mobile/putaway` | No blank, no throw (reset + guards both hold) | |
| 7 | Console check | dev | Repeat #3 with DevTools console open | No Vue render `TypeError` logged | |

### 8.3 Deliberately-skipped coverage

| What | Why |
|------|-----|
| Automated unit/component tests | No Jest harness in repo (`CLAUDE.md`); bootstrapping is out of scope for this bug. Covered by acceptance script + manual §8.2. |
| Backend/API tests | Backend exonerated (§3); no server code changes. |
| §5.5 sibling pages | Out of primary scope; separate follow-up. |

---

## 9. Risks & Mitigations + Acceptance

### 9.1 Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `resetState` wipes an in-progress putaway an operator wanted to resume after reload | Low | By design: the persisted mid-flow state is already unreliable across a redeploy (partial/stale). `picking`, `truck-loading`, `replenish` all reset on mount — putaway now matches that established UX. Resuming mid-flow across a reload was never a supported contract. |
| Optional chaining unsupported by the Nuxt 2 build | Very low | `?.` already ships in `storeBox.vue:15-16` on the same build; no new toolchain requirement. |
| Operators with pre-fix stale `localStorage` still blank once | Low | Documented in §7.1: one hard reload/cache clear self-heals; thereafter the `created()` reset runs on every load. |
| Strengthened `v-if` hides content when data is legitimately present but index transiently invalid | Very low | The `v-if` mirrors the existing guard already used in `scanFlowBin.completed()` (`info && info.putAwayItemDataList && info.putAwayItemDataList[currentIndex]`), so behavior is consistent with existing code. |

### 9.2 Acceptance

- **Acceptance script:** `sbdocs/9-System/scripts/verify-260709-putaway-blank-screen-stale-persisted-state.sh` must exit `0` (0 FAIL). Run:
  ```bash
  PROJECT_ROOT=/home/nampark/dev/wms-claude/v1/wms-mobile-ui \
    bash sbdocs/9-System/scripts/verify-260709-putaway-blank-screen-stale-persisted-state.sh
  ```
  Positive checks: `putaway.vue` has a `created()`/`mounted()` hook committing `putaway/resetState`; `store/putaway.js` has `resetState` and a null-safe `setCurrentIndex`; `scanFlowBin.vue`/`storeBox.vue` use `?.` on the `putawayInfo` derefs, and `scanFlowBin.vue:17` `emptyPallet` is `info &&`-guarded (F4f). Negative checks: the previously-unguarded deref forms are gone (incl. the bare `v-if="info.emptyPallet"` (F4g) and `storeBox` `clientName`/`itemDataName` (F5c/F5d)). 18 checks total.
- **Manual gate:** §8.2 scenarios #1, #3, #5, #7 all Pass.
- **DONE contract:** a "DONE" claim with any FAIL line in the acceptance script is **not accepted**.

---

## 10. Implementation Status & Resolved Decisions

**Status:** IMPLEMENTED — 2026-07-09 on branch `fix/260709-putaway-blank-screen` (off `develop`) → PR #98.

- **Code changes (v1/wms-mobile-ui):** `pages/putaway.vue` (`created()` reset — not `mounted()`); `store/putaway.js` (`resetState` mutation + null-safe `setCurrentIndex`); `components/putaway/scanFlowBin.vue` (line-17 `emptyPallet` guard, strengthened subtitle `v-if`, optional-chained idx derefs, null-safe `putawayItems`); `components/putaway/storeBox.vue` (optional-chained SKU/Shipper/Name).
- **Acceptance:** verify script `Result: 18 pass, 0 fail, 0 skip`. No Jest harness in repo → manual gate = clear-`localStorage`-and-reload renders the scan screen; mid-flow (`3_flowbin`/`4_box`) reload no longer blanks.
- **Scope:** primary putaway fix only. Sweep follow-up `transfer-order.vue` (plan §5.5) NOT included — recorded as a separate lower-severity item.

**Review (2026-07-09, `critic`, code-grounded): APPROVE-WITH-CHANGES.** State shape, unguarded `setCurrentIndex`, whole-store persistence enabler, and all 13 sweep classifications verified against the live tree. Must-fix items applied:
- **M-1** — (a) reset moved from `mounted()` to **`created()`** (§5.2): in Vue 2 a child renders/mounts *before* the parent's `mounted()`, so `mounted()` would let `scanFlowBin` render once against stale/null state before the reset — `created()` runs before any child instantiates. (b) Added the missed **`scanFlowBin.vue:17` `v-if="info && info.emptyPallet"`** guard (§5.3) — it sits outside the `v-if="info"` block and derefs `null` on the reload path. Verify checks F4f/F4g added.
- **m-1** — verify F1a relaxed to accept `created()`|`mounted()`.
- **m-2** — verify F5 extended with negative checks for the `clientName`/`itemDataName` old forms (F5c/F5d), not just `itemDataNumber`.
- Sweep criterion reworded (row 3 `lookup`): safety is "guarded at the dereferenced leaf," not "protected by the mount reset" (the reset does not prevent the first child render). `lookup` remains a latent, out-of-scope note.

### Resolved Decisions (do not re-litigate)
1. **Scope = Targeted + SWEEP.** (a) Fix putaway (§5.1-5.4). (b) Audit every other operation page for the same two-part fragility and enumerate with in/out disposition (§0). The sweep found putaway is the **only** page with **both** fragilities; `transfer-order` is a low-severity latent follow-up (§5.5); the rest are safe or cosmetic.
2. **Primary fix = reset-on-`created()` + guards.** Add `resetState` to `store/putaway.js`, call it in `pages/putaway.vue` **`created()`** (not `mounted()` — see M-1), make `setCurrentIndex` null-safe, and guard the derefs in `scanFlowBin.vue` (line 76 → `putawayInfo?.putAwayItemDataList || []`; strengthen the `v-if`; `?.` on 26-37; **`info &&` on the line-17 `emptyPallet`**) and `storeBox.vue` (8-10 to match 15-16).
3. **Backend exonerated** (§3). Not SBDEV-2512, not SBDEV-2492. Redeploy is the *event* that reloads tabs; the trigger is stale `localStorage`, not a code change.
4. **`db_verified: false`** — no DB path; verification is the `localStorage`/persisted-state probe.
5. **Systemic `paths`/`reducer` filter on `persistedState.client.js` is out of scope** (broad blast radius); recorded as a future consideration.

### Recommended OMC composition
| Aspect | Value | Rationale |
|---|---|---|
| Size class | Standard (4 files, one subsystem) | Small, contained, one operation. |
| Pre-draft | none | Root cause already traced. |
| Plan-review | critic | Standard tier — review §0 disposition + guard forms before coding. |
| Implementation | executor | Single-subsystem mechanical diff. |
| Verification | verify-script + verifier + manual §8.2 | Mandatory. |
| Code-review | code-reviewer (optional) | Small diff. |
| Commit | git directly | Single logical commit. |

---

## Completeness Checklist (frontend-adapted)

| Item | Status |
|------|--------|
| Root cause traced to file:line (persist plugin + missing reset + unguarded derefs) | ✅ §2 |
| §0 sweep: every `pages/*.vue` enumerated with in/out disposition | ✅ 13 rows |
| Backend exoneration stated explicitly (incl. SBDEV-2512/2492) | ✅ §3 |
| Before/After for every in-scope file | ✅ §5.1-5.4 |
| State shape confirmed against `store/putaway.js` | ✅ §5.1 |
| `setCurrentIndex` null-safety addressed | ✅ §5.1 |
| DB verification correctly marked N/A with rationale (frontend probe instead) | ✅ frontmatter + §1 |
| Prerequisites note: no backend/DB/flag deps; deploy = frontend rebuild; stale-localStorage operator note | ✅ §7.1 |
| Manual test plan incl. `localStorage.clear()` probe + mid-flow reload | ✅ §8.2 |
| No-test-suite reality acknowledged; Jest optional | ✅ §8 |
| Acceptance script path + run command | ✅ §9.2 |
| Risks + mitigations | ✅ §9.1 |
| Sweep follow-ups recorded as separate scope | ✅ §5.5 |
