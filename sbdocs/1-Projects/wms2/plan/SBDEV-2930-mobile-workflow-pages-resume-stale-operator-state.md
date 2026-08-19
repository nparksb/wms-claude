---
title: "wms2-mobile-ui — workflow pages resume the previous operator's state from the persisted Vuex blob"
ticket: "SBDEV-2930"
ticket_url: "https://app.clickup.com/t/868kq7yfm"
type: "bugfix"
priority: "normal"
status: "MERGED 2026-08-12 — wms2-mobile-ui PR #32 into develop, merge 98eae72, ClickUp `on dev`. DO NOT ARCHIVE until the §8.4 manual rows are run on DEV — they are the only compensating control (no telemetry surface), and M10 is the sole runtime check on the review Medium."
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-08-12"
updated: "2026-08-12"
db_verified: false
related:
  - "SBDEV-2732-configurable-default-putaway-location-hierarchy"
  - "260709-putaway-blank-screen-stale-persisted-state"
tags:
  - plan
  - wms2-mobile-ui
  - vuex
  - persisted-state
---

# wms2-mobile-ui — workflow pages resume the previous operator's state from the persisted Vuex blob

**Ticket:** [SBDEV-2930](https://app.clickup.com/t/868kq7yfm)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Repo:** `v2/wms2-mobile-ui` (Nuxt 2.15 / Vue 2.7.16 / Vuetify 2)
**Priority:** normal
**Status:** draft — awaiting review
**Date:** 2026-08-12

**Paired v1 ticket:** [SBDEV-2932](https://app.clickup.com/t/868kqbajb) — `v1/wms-mobile-ui` has the identical
gap *plus* an unhardened `persistedState` config. Deliberately **not** in this plan (§11 Q3).

> **`db_verified: false` — and that is correct here, not a gap.**
> This defect lives entirely in browser `localStorage` and Vuex. It has no database surface: no query can
> confirm or refute it, because the corrupt state never reaches the server — the *harm* is that an operator
> is placed in a position to send a **valid** request carrying someone else's context. The analysis-protocol
> DB gate is satisfied instead by **direct runtime reproduction under Jest** (§2.4), which is strictly
> stronger evidence than a SQL probe would have been. No manual DB check is owed by the implementer.

---

## 0. Affected sites (enumeration before drafting)

Enumerated from `origin/develop` (`git ls-tree`), not from the ticket. **The ticket's table is incomplete
and wrong in three places** — see §1.2.

`localStorage['vuex-mobile']` holds the whole Vuex root state minus three keys
(`plugins/persistedState.client.js:29-32` excludes only `warehouseTimezone`, `selectedWarehouse`,
`warehouses`). Every row below therefore rehydrates in full on every app boot and survives every
in-session navigation.

| # | Page | Module | Entry state | Hook today | Verdict | In scope |
|---|------|--------|-------------|-----------|---------|----------|
| 1 | `pages/cancellation.vue` | `cancellation` | `process:'0_scan'` | **none** | resumes mid-flow | **yes** |
| 2 | `pages/cycle-count.vue` | `cycleCount` | `process:'11_select'` | **none** | resumes mid-flow | **yes** |
| 3 | `pages/move-stock.vue` | `moveStock` | `process:'1_select'` | **none** | resumes mid-flow | **yes** |
| 4 | `pages/move-unitload.vue` | `moveUnitload` | `process:'1_select'` | **none** | resumes mid-flow | **yes** |
| 5 | `pages/transfer-order.vue` | `transferOrder` | `process:'1_select'` | **none** | resumes mid-flow | **yes** |
| 6 | `pages/palletizing.vue` | `palletizing` | `parcelScan:true`, `rapidPalletScan:true` | **none** | resumes mid-flow | **yes — ticket omits this page entirely** |
| 7 | `pages/picking.vue` | `picking` | `process:'0_section'` | `mounted()` partial | stale sub-screen renders; working set kept | **yes** |
| 8 | `pages/replenish.vue` | `replenish` | `process:'1_select'` | `mounted()` partial | stale sub-screen renders; working set kept | **yes** |
| 9 | `pages/replenish-request.vue` | `replenish` *(shared)* | `locationScan:true` | `mounted()` partial | stale sub-screen renders | **yes — ticket omits this page entirely** |
| 10 | `pages/truck-loading.vue` | `truckLoading` | `process:'1_select'` | `mounted()` partial | stale sub-screen renders; working set kept | **yes** |
| 11 | `pages/lookup.vue` | `lookup` | `process:'search'` | `mounted()` near-full | stale sub-screen renders | **yes — ticket marks this "yes, resets"** |
| 12 | `pages/putaway.vue` | `putaway` | `process:'1_select'` | **`created()` full** | **correct** | **control / regression guard only** |

**Non-workflow modules — explicitly excluded:**

| Module | Why out of scope |
|---|---|
| `store/index.js` (root) | Holds `selectedWarehouse` / `warehouses` / `warehouseTimezone` / `tenantHealth`. Two of those are already excluded from the blob, and all are re-derived at boot. Resetting them would re-break SBDEV-2726. **Must not be touched.** |
| `store/home.js` | `menus` / `profile` / `page` / `pageList`. Re-fetched via `home/refreshMenus` and cleared at logout by PR #31. No `process` marker, renders no workflow sub-screen. See §11 Q4 for the one residual concern. |

**Count:** 12 pages render off a persisted workflow module. **11 need a change**; `putaway.vue` is already
correct and serves as the control. 10 distinct modules need a `resetState` mutation (`replenish` serves two
pages; `putaway` already has one but is being reshaped — §4.1).

**Cross-reference grep** (`sbdocs/1-Projects/`, `sbdocs/4-Archieves/`): the only prior plan touching this
code path is `4-Archieves/wms1/plan/260709-putaway-blank-screen-stale-persisted-state.md`, which is the
precedent that produced row 12's `created()` hook. No in-flight plan conflicts.

---

## 1. Problem Statement

### 1.1 Symptom

Handhelds running `wms2-mobile-ui` are **shared between shifts**. An operator opens a workflow page and
lands part-way through the *previous operator's* job, with that operator's working set still populated —
selected order, scanned location, staged unit loads, entered counts — and is positioned to continue or
complete it.

Concretely, for Cycle Count: with `process:'14_count'` and `unitLoadInfo` left in the blob, opening
`/cycle-count` renders `components/cycleCount/bySku/countUnitLoad.vue` directly. That screen's
submit path posts `cyclecountPosition: this.unitLoadInfo.cycleCountPosition`
(`countUnitLoad.vue:51`) — the previous operator's position id. The request is **well-formed and the API
will accept it.** Nothing downstream can detect that the wrong human pressed the button.

This is not hypothetical framing: it is the same failure class already patched once in this app.
`pages/putaway.vue:25-27` carries a comment explaining its `created()` reset exists *because* stale
persisted state made a data sub-screen render and throw. It was fixed one page at a time, and the
remaining pages were never done.

### 1.2 Three corrections to the ticket

The ticket's coverage table was written from a read of the page files. Enumeration plus runtime probes
contradict it in three places, and all three **widen** the fix:

1. **`pages/palletizing.vue` is missing from the ticket.** It has no lifecycle hook, and it renders off
   `palletizing.parcelScan` / `rapidPalletScan` — booleans, so a stale `false` silently lands the operator
   on the second screen of the flow with `scannedParcel` / `rapidScannedPallet` populated. Sixth unreset page.

2. **`pages/replenish-request.vue` is missing from the ticket.** It shares the `replenish` module with
   `replenish.vue` and renders off `replenish.locationScan`. This matters for the *design*, not just the
   count: one module backs two pages with two different entry screens (§4.2).

3. **The "partial" and "yes" rows are not partially broken — they are broken.** The ticket treats a
   `mounted()` reset as a lesser variant of the same fix. It is not: §2.4 demonstrates at runtime that a
   `mounted()` reset **still renders the stale sub-screen**, because the parent's `mounted()` fires after
   its children have already been created, mounted, and painted. `lookup.vue`, which the ticket marks
   "yes — resets", is in this category.

### 1.3 Reproduction

No special data condition is required — any interrupted workflow reproduces it.

1. On a handheld, log in as operator A. Open Cycle Count, select an order, scan a unit load, advance to
   the count screen (`process` is now `'14_count'`).
2. Press the hardware home key / navigate to the main menu. **Do not log out** — this is the shift-handover
   case, and it is also what an accidental navigation looks like.
3. Hand the device to operator B (or simply re-open the app; the blob survives a full browser restart).
4. Open Cycle Count.

**Observed:** the count screen for operator A's unit load, pre-populated.
**Expected:** the order-selection screen, empty.

Substitute any of rows 1–11 in §0 for the same result.

---

## 2. Root Cause Analysis

### Bug 1 — six pages never reset their module on entry

`plugins/persistedState.client.js:29-32`:

```js
createPersistedState({
  key: 'vuex-mobile',
  reducer: ({ warehouseTimezone, selectedWarehouse, warehouses, ...persisted }) => persisted,
})(store)
```

The reducer is a **denylist of exactly three keys**. Every workflow module — including its `process` step
marker and its entire working set — is persisted verbatim and rehydrated on every boot.

Each affected page then renders directly off that rehydrated marker. `pages/cancellation.vue:18-22` is
representative:

```js
computed: {
  process() {
    return this.$store.state.cancellation.process
  }
},
// ← no created(), no mounted(), no beforeRouteEnter
```

with a template that switches on it (`pages/cancellation.vue:3-6`):

```html
<cancellation-scan   v-if="process === '0_scan'" />
<cancellation-list   v-else-if="process === '0_list'" />
<cancellation-detail v-else-if="process === '1_detail'" />
<cancellation-action v-else-if="process === '2_action'" />
```

There is no code path between "blob rehydrates" and "sub-screen renders". Rows 1–6 of §0 are all this shape.

Only `store/putaway.js:49-55` has a `resetState` mutation. The other ten modules have none, so even a page
that *wanted* to reset has nothing to call.

### Bug 2 — `mounted()` is the wrong hook, so the five "partial" pages are also broken

Rows 7–11 do reset, in `mounted()`. `pages/picking.vue:35-38`:

```js
mounted() {
  this.$store.commit('picking/setProcess', '0_section')
  this.$store.commit('picking/setPickingOrders', [])
}
```

Two independent defects here.

**2a — the reset lands after the stale child has already rendered.** In Vue 2 the parent's `mounted()` runs
*after* all children are created and mounted. So the sequence on entering `/picking` with a stale
`process:'12_pick'` is:

```
picking.vue created()          → (nothing)
  Pick created()               → fires GET /client/search/findByClNr?clNr=System   ← pick.vue:251
  Pick mounted()               → initPicking()                                     ← pick.vue:257
      → commit picking/initPicking
      → commit picking/nextPickingPosition                                         ← mutates A's state
  Pick painted                 → operator A's pick screen is on the glass
picking.vue mounted()          → NOW resets process to '0_section'
```

The child's own hooks fire against the previous operator's data before the parent gets a turn.
`pick.vue`'s `mounted()` does not merely render — it **commits two mutations**, advancing operator A's
picking position. This is exactly the hazard `pages/putaway.vue:25-27` documents:

```js
// SBDEV plan 260709: use created() (NOT mounted()) — in Vue 2 a child renders/mounts before the
// parent's mounted() hook, so mounted() would let a data sub-screen render once against stale
// persisted state and throw. created() runs before any child is instantiated.
```

**2b — the reset is partial, so the working set survives.** `picking.vue` clears `process` and
`pickingOrders` and leaves the other **18** fields of `store/picking.js` untouched — including
`orderSelected`, `currentPosition`, `pickingOrderPositions`, `currentIndex`, `sectionSelected`.
`components/picking/pick.vue:272` dereferences `this.orderSelected.id` and `:286` dereferences
`this.currentPosition.id`. Same shape in `replenish.vue:104-108` (2 of 11 fields),
`truck-loading.vue:21-25` (3 of 6), `replenish-request.vue:30-33` (2 of 11).

### 2.3 Why the existing fixes do not cover this

| Existing fix | What it covers | Why it is not enough |
|---|---|---|
| `wms2-mobile-ui` PR #31 (merge `2e5a995`) | Clears `vuex-mobile` at all three logout exits | Only fires at the **session boundary**. A shift handover without an explicit logout, an accidental navigation, or moving between two workflows in one session all bypass it entirely. |
| SBDEV-2726 (merge `43d6b6c`) | App-specific `vuex-mobile` key; drops the shared `vuex` blob | Fixes *cross-app* leakage. Says nothing about state outliving its operator inside one app. |
| SBDEV-2732 mobile follow-up | The logout clear above | The plan's own status note records: "SBDEV-2930 filed for the mobile per-page reset gap, which #31 does NOT close." |

### 2.4 Runtime confirmation (substitutes for the DB gate)

All three probes below were executed against `origin/develop` with the repo's own Jest harness
(`jest 27.5.1`, `@vue/test-utils 1.3.6`, `vuex 3.6.2`, `vue 2.7.16`), then removed. The working tree is
clean. They are reproduced here as evidence, and they are the direct template for the TDD-gate tests.

**Probe 1 — Bug 1 reproduces.** `shallowMount(cycle-count.vue)` with a store seeded
`process:'14_count'`, `unitLoadInfo:{cycleCountPosition:99}`:

```
findComponent(CountUnitLoad).exists()  =  true      ← operator A's mid-count screen
findComponent(SelectOrder).exists()    =  false     ← the entry screen never appears
store.state.cycleCount.unitLoadInfo    =  { cycleCountPosition: 99 }
```

**Probe 2 — Bug 2 reproduces on a page the ticket called "partial".** `shallowMount(picking.vue)` seeded
`process:'12_pick'`, `currentPosition:{id:7,pickStatus:'Open'}`, `orderSelected:{id:3}`:

```
store.state.picking.process             =  '0_section'                      ← the reset DID run
findComponent(Pick).exists()            =  true                             ← ...and the stale screen is STILL rendered
findComponent(ScanSection).exists()     =  false                            ← ...and the entry screen is NOT
store.state.picking.currentPosition     =  { id: 7, pickStatus: 'Open' }    ← working set survived
```

This is the load-bearing result. Asserting on `state.process` alone would have reported this page as
**fixed**. Only asserting on the *rendered component* separates a `mounted()` reset from a `created()` one.

**Probe 3 — control group; `created()` behaves correctly.** `shallowMount(putaway.vue)` seeded
`process:'5_store'`, `pallet:'PAL-999'`, `putawayInfo:{…}`, `currentItem:{x:1}`:

```
store.state.putaway.process    =  '1_select'
findComponent(ScanPallet).exists()   =  true     ← entry screen, synchronously
findComponent(StorePallet).exists()  =  false    ← stale screen never rendered
store.state.putaway.pallet     =  null
store.state.putaway.currentItem =  null
```

**The discriminator is therefore `expect(wrapper.findComponent(EntryScreen).exists()).toBe(true)`** —
it passes for `created()` and fails for `mounted()`. Every acceptance criterion in §8 is built on it.

### 2.5 A harness constraint the implementer must know

**Four** `.vue` files use **optional chaining inside their `<template>`**. `vue-template-es2015-compiler`
cannot parse the render function `vue-jest@3.0.7` hands it, so importing them throws
`SyntaxError: Unexpected token`, and the failure propagates to any page that imports them — killing the
whole suite, not just that case:

| File | Blocks mounting |
|---|---|
| `components/putaway/scanFlowBin.vue` | `pages/putaway.vue` |
| `components/putaway/storeBox.vue` | `pages/putaway.vue` |
| `components/replenish/process/selectDestination.vue` | `pages/replenish.vue` |
| `components/replenish/process/selectUnitLoad.vue` | `pages/replenish.vue` |

> ⚠ **This table said three files until the TDD gate ran.** The fourth was missed because the scan that
> produced it bounded the template region with `awk '/<template>/,/<\/template>/'`, which stops at the
> **first** closing tag — and `pages/replenish.vue` opens with nested `<template v-if=…>` blocks, so only
> 8 of its 47 template lines were ever examined. Re-scanned from the first `<template>` to the **last**
> `</template>`; four files, and the per-file counts on the other three were also undercounted. Any future
> scan of Vue templates in this repo must bound on the last closing tag.

Verified workaround (in use in the gate's spec):

```js
jest.mock('@/components/putaway/scanFlowBin.vue', () => ({ name: 'ScanFlowBin', render: (h) => h('div') }))
```

Do **not** "fix" this by rewriting the templates — that is unrelated production change inside a bug-fix PR,
and those `?.` guards are load-bearing. Do not upgrade `vue-jest` either (§10 R4). Stub at the test boundary.

**A second harness constraint, also found by the gate:** `pages/replenish-request.vue` carries a stray
`rapidPalletScan` computed **and** watcher that read `state.palletizing` — copy-paste leftovers from
`palletizing.vue`, unused by its own template. A test store registering only the `replenish` module throws
`TypeError: Cannot read properties of undefined (reading 'rapidPalletScan')` before any assertion runs. The
spec therefore registers **all eleven** workflow modules on every mount, which also matches how Nuxt
auto-registers `store/*.js` in the real app. (The stray computed is pre-existing dead code; removing it is
**not** in scope for this PR.)

---

## 3. Architecture Overview

```
      boot                                     in-session navigation
       │                                              │
       ▼                                              ▼
 localStorage['vuex-mobile']                    router.push('/cycle-count')
       │  rehydrate (whole root state                  │
       │  minus 3 warehouse/tz keys)                   │  store is already live —
       ▼                                               │  PR #31's logout clear
 Vuex root state                                       │  never fires here
   ├── index      (warehouse, tenantHealth) ─── excluded from reset, correctly
   ├── home       (menus, profile)          ─── out of scope (§0)
   └── <workflow module>                    ─── process marker + working set
             │
             ▼
     pages/<workflow>.vue
       computed: process → state.<module>.process
             │
             ├─ created()   ◄── THE FIX GOES HERE (runs before any child exists)
             │
             ▼
       template  v-if="process === '<step>'"
             │
             ▼
       components/<workflow>/<sub-screen>.vue
             ├─ created()  ← may fire API calls          ┐ both run BEFORE the parent's
             └─ mounted()  ← may COMMIT MUTATIONS        ┘ mounted() — hence Bug 2a
```

### Key files

| File | Lines | Role |
|---|---|---|
| `plugins/persistedState.client.js` | 29-32 | 3-key denylist reducer; every workflow module is persisted |
| `store/putaway.js` | 49-55 | The only existing `resetState`; the pattern to generalise |
| `pages/putaway.vue` | 25-30 | The only correct `created()` reset; control group |
| `pages/picking.vue` | 35-38 | Representative partial `mounted()` reset (Bug 2) |
| `components/picking/pick.vue` | 251-259 | Child `created()`+`mounted()` that fire against stale state |
| `store/picking.js` | 1-21 | Largest working set (20 fields) — 18 survive today's reset |
| `jest.config.js` | — | `roots: ['<rootDir>/test']`, `@`/`~` aliases, `vue-jest` transform |

---

## 4. Fix Design

**Decision (§11 Q1):** blanket reset on entry, all 11 pages. **Decision (§11 Q2):** no per-user
ownership stamping.

### 4.1 Fix A — a uniform, drift-proof `resetState` on all 10 workflow modules

Add to each of the ten workflow modules:

```js
export const state = () => ({ /* unchanged */ })

export const mutations = {
  // ... existing mutations unchanged ...

  // SBDEV-2930: the whole root state is persisted to localStorage['vuex-mobile'], so this module's
  // process marker AND working set outlive both the session and the operator. Pages call this from
  // created() so a shared handheld can never open on the previous operator's job.
  // Rebuilt from the state() factory rather than field-by-field: a field added later is covered
  // automatically instead of silently escaping the reset.
  resetState(state) {
    Object.assign(state, initialState())
  },
}
```

with `initialState` hoisted so both the factory and the mutation share one definition:

```js
const initialState = () => ({
  process: '0_scan',
  sourceFlow: '0_scan',
  selectedOrder: null,
  pendingList: [],
  loading: false,
  error: null,
})

export const state = initialState
```

**Why `Object.assign(state, initialState())` and not putaway's field-by-field form.** `store/putaway.js:49-55`
lists its five fields by hand. That was fine for five fields, but it is a standing drift hazard: adding a
sixth field to the factory and forgetting the mutation reintroduces this exact bug for that field, silently.
`store/picking.js` has **20** fields — hand-listing them is how this ends up half-done again. Rebuilding from
the factory makes the mutation correct by construction, and §8's `toEqual(initialState())` assertion pins it.

Vue 2 reactivity is safe here: every key already exists on the observed object, so `Object.assign` writes
through existing reactive setters. No `Vue.set` needed. (This would *not* hold for keys absent from the
factory — there are none.)

**Retrofit `store/putaway.js` to the same shape** (Fix A applies to all ten *including* putaway). It is a
behaviour-preserving refactor of the one module that already works, and it removes the drift hazard from the
module with the documented history. Probe 3's assertions become its regression guard.

**Modules and their entry state:**

| Module | Entry state restored |
|---|---|
| `cancellation` | `process:'0_scan'` |
| `cycleCount` | `process:'11_select'` |
| `lookup` | `process:'search'` |
| `moveStock` | `process:'1_select'` |
| `moveUnitload` | `process:'1_select'` |
| `palletizing` | `parcelScan:true`, `rapidPalletScan:true` — **no `process` field**, see §4.3 |
| `picking` | `process:'0_section'` |
| `putaway` | `process:'1_select'` (retrofit) |
| `replenish` | `process:'1_select'`, `locationScan:true` — **backs two pages**, see §4.2 |
| `transferOrder` | `process:'1_select'` |
| `truckLoading` | `process:'1_select'` |

### 4.2 Fix B — `created()` on all 11 pages

Replace every `mounted()` reset, and add one where there is none. Uniformly:

```js
  // SBDEV-2930: created(), NOT mounted() — in Vue 2 children are created and mounted before the
  // parent's mounted() hook, so a mounted() reset lets the previous operator's sub-screen render
  // (and run its own hooks) first. See pages/putaway.vue and the plan's §2.4 probe 2.
  created() {
    this.$store.commit('<module>/resetState')
  },
```

**Before / after — `pages/picking.vue`:**

```diff
-  mounted() {
-    this.$store.commit('picking/setProcess', '0_section')
-    this.$store.commit('picking/setPickingOrders', [])
-  }
+  created() {
+    this.$store.commit('picking/resetState')
+  },
```

**Before / after — `pages/cancellation.vue`** (no hook exists today):

```diff
   computed: {
     process() {
       return this.$store.state.cancellation.process
     }
   },
+  created() {
+    this.$store.commit('cancellation/resetState')
+  },
 }
```

**`replenish.vue` and `replenish-request.vue` share the `replenish` module**, and a single blanket
`replenish/resetState` satisfies both entry screens — `replenish.vue` needs `process:'1_select'` and
`replenish-request.vue` needs `locationScan:true`, and the factory already yields both. Both pages get the
identical `created()` call; no module split and no per-page variant is required. This is the one place where
a naive "reset only the fields this page reads" design would have gone wrong, which is a further argument
for the factory-rebuild form of Fix A.

**Non-obvious removals.** Three pages do work in `mounted()` beyond the reset, which must be preserved:

| Page | Also in `mounted()` today | Disposition |
|---|---|---|
| `replenish.vue` | `this.fetchHeldUp()` | **Keep in `mounted()`.** It is a data fetch into component-local `data`, not a state reset. Only the two `commit` lines move to `created()`. |
| `lookup.vue` | — | Both commits move; the `watch` on `$store.state.lookup.process` (`:32-45`) is unrelated and stays. |
| `truck-loading.vue` | — | All three commits collapse into `resetState`. |

### 4.3 `palletizing` has no `process` marker

`store/palletizing.js` uses two booleans (`parcelScan`, `rapidPalletScan`) instead of a step string, so its
template switches on `v-if="parcelScan"` / `v-if="rapidPalletScan"` rather than on a step. The fix is
unchanged in shape — `resetState` restores both to `true`, which is each tab's entry screen — but the
acceptance assertion must target `ScanParcel` / `RapidScanPallet`, not a `process` value. Called out because
a copy-paste of the other ten pages' test would silently assert nothing here.

### 4.4 Considered and rejected

| Alternative | Why not |
|---|---|
| Exclude workflow modules from the `persistedState` reducer (kill it at source) | Cleanest-looking, but changes reload semantics app-wide: a deliberate mid-scan F5 would also reset, and handhelds do get reloaded. It *also* does not remove the need for Fix B, because in-session navigation never re-reads localStorage — the live store is already dirty. Strictly more blast radius for strictly less coverage. Rejected; recorded as §11 Q1 option C. |
| Per-user ownership stamp (`_ownerSub` vs Keycloak `sub`) | Preserves accidental-navigation recovery, but needs an ownership field in every module, a migration path for blobs written before the fix, and a rule for an absent stamp. It also still resumes stale state for the *same* operator — the crash-class harm putaway documents. Rejected by the user (§11 Q2). |
| `beforeRouteEnter` instead of `created()` | Fires early enough, but is a vue-router hook with no `this`, requires the `next(vm => …)` form, and would diverge from the `created()` precedent already in the codebase and its explanatory comment. No benefit. |
| A global router `afterEach` that resets every module | One central place, but it resets modules the operator is *not* navigating to, and couples the router to the full module list — a new file to forget to update. The per-page hook keeps the reset next to the thing that needs it. |

---

## 5. File Change Summary

| File | Change | Description |
|---|---|---|
| `store/cancellation.js` | Modify | Hoist `initialState`; add `resetState` |
| `store/cycleCount.js` | Modify | Hoist `initialState`; add `resetState` |
| `store/lookup.js` | Modify | Hoist `initialState`; add `resetState` |
| `store/moveStock.js` | Modify | Hoist `initialState`; add `resetState` |
| `store/moveUnitload.js` | Modify | Hoist `initialState`; add `resetState` |
| `store/palletizing.js` | Modify | Hoist `initialState`; add `resetState` |
| `store/picking.js` | Modify | Hoist `initialState`; add `resetState` |
| `store/putaway.js` | Modify | Retrofit existing `resetState` to the factory-rebuild form |
| `store/replenish.js` | Modify | Hoist `initialState`; add `resetState` (serves 2 pages) |
| `store/transferOrder.js` | Modify | Hoist `initialState`; add `resetState` |
| `store/truckLoading.js` | Modify | Hoist `initialState`; add `resetState` |
| `pages/cancellation.vue` | Modify | Add `created()` reset |
| `pages/cycle-count.vue` | Modify | Add `created()` reset |
| `pages/move-stock.vue` | Modify | Add `created()` reset |
| `pages/move-unitload.vue` | Modify | Add `created()` reset |
| `pages/transfer-order.vue` | Modify | Add `created()` reset |
| `pages/palletizing.vue` | Modify | Add `created()` reset |
| `pages/picking.vue` | Modify | `mounted()` → `created()`; partial → `resetState` |
| `pages/replenish.vue` | Modify | Commits → `created()`/`resetState`; **keep `fetchHeldUp()` in `mounted()`** |
| `pages/replenish-request.vue` | Modify | `mounted()` → `created()`; partial → `resetState` |
| `pages/truck-loading.vue` | Modify | `mounted()` → `created()`; partial → `resetState` |
| `pages/lookup.vue` | Modify | `mounted()` → `created()`; partial → `resetState` |
| `pages/putaway.vue` | **Unchanged** | Already correct — control group |
| `test/store/resetState.spec.js` | **New** | Per-module `resetState` contract (§8.1) |
| `test/pages/workflow-reset-on-entry.spec.js` | **New** | Per-page entry-screen assertions (§8.2) |

**11 pages + 11 store modules + 2 new spec files. No production dependency, config, or build change.**

---

## 6. Implementation Steps

### 6.1 Prerequisites

| Item | Applies | Detail |
|---|---|---|
| DB state | **N/A** | Browser-side only; no schema, no query, no migration. |
| Feature flags / sysprops | **N/A** | Not gated. The fix is a safety correction with no configurable behaviour (§11 Q1 rejected the toggle). |
| Config / env | **N/A** | No `.env`, Nuxt config, or build change. |
| Deploy order | **None** | Purely client-side; independent of any `wms2-api` version. No coordinated release. |
| Data migration | **None needed** | Blobs written before the fix are handled *by* the fix: the first `created()` after deploy overwrites the stale module. No cleanup script. |
| External systems | **N/A** | No API contract touched. |
| Access | Existing repo write + PR into `develop`. |
| Monitoring | **N/A** | See §10 R5 — this bug is invisible to telemetry by nature; the manual plan in §8.4 is the check. |

### 6.2 Steps

Each step is independently committable and independently green.

1. **Branch.** `git fetch origin && git checkout -b bugfix/SBDEV-2930-workflow-page-reset-on-entry origin/develop`.
   Local `develop` is **2 commits behind** `origin/develop` (PR #31) — branch off `origin/develop`, not local.
2. **Baseline.** Run `bash sbdocs/9-System/scripts/verify-SBDEV-2930-mobile-workflow-pages-resume-stale-operator-state.sh`
   with `PROJECT_ROOT` at the worktree and record the FAIL count. Run the Jest suite and record the green baseline.
3. **Fix A ×10** — add `initialState` + `resetState` to the ten modules lacking one. No page changes yet;
   suite must stay green (the mutations are unreferenced at this point).
4. **Fix A retrofit** — reshape `store/putaway.js`'s `resetState`. Suite stays green; probe-3 assertions
   are the guard.
5. **Fix B — the six unreset pages** (rows 1–6): `cancellation`, `cycle-count`, `move-stock`,
   `move-unitload`, `transfer-order`, `palletizing`.
6. **Fix B — the five `mounted()` pages** (rows 7–11): `picking`, `replenish`, `replenish-request`,
   `truck-loading`, `lookup`. **Preserve `replenish.vue`'s `fetchHeldUp()` in `mounted()`** (§4.2).
7. **Tests** — add both spec files (§8). Per the TDD gate these are written *first*, against the unfixed
   build, and must fail for the right reason before steps 3–6 land.
8. **Verify** — re-run the script; require `Result: N pass, 0 fail`. Re-run the full Jest suite.
9. **Manual smoke** — §8.4, on a real handheld or a mobile-emulated browser.
10. **PR into `develop`**, linking SBDEV-2930 and noting SBDEV-2932 as the v1 follow-up.

---

## 7. Horizontal Scalability Validation

`wms2-mobile-ui` is a **client-side Nuxt SPA**. It holds no server-side state, serves no requests, and runs
one instance per handheld browser. The v2 replica-scaling checklist is therefore N/A row-by-row — recorded
in full rather than waved off, because the *analogue* of row 1 is precisely this bug.

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **N/A — but see note** | No JVM. The direct analogue is *in-browser* state shared across operators via `localStorage`, which **is** this defect. The fix reduces its lifetime to one page entry. |
| 2 | Connection pool math | **N/A** | No DB connections. The fix issues no new API calls; it *removes* stale-context calls (§2.2's `pick.vue` chain). |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled`/cron. |
| 4 | Long transactions | **N/A** | No transactions. |
| 5 | Request affinity | **N/A** | No server session; state is device-local. |
| 6 | Retry / idempotency | **N/A** | No new writes. Note the fix **reduces** a non-idempotency risk: today a stale screen can re-submit a completed step. |
| 7 | Tenant context | **No** | Untouched. `resetState` covers workflow modules only; `selectedWarehouse`/`warehouses`/`warehouseTimezone` live in root state and are explicitly excluded (§0). This is the SBDEV-2726 / UTC-migration boundary and the plan does not cross it. |
| 8 | Distributed lock correctness | **N/A** | No locks. |
| 9 | Cache invalidation | **N/A** | No Caffeine/Redis. The `localStorage` blob is the only cache-like surface, and the fix is precisely its invalidation. |
| 10 | External notifications | **N/A** | No message sends. |

---

## 8. Testing Plan

Harness confirmed working on `origin/develop`: `jest 27.5.1`, `@vue/test-utils 1.3.6`, `vuex 3.6.2`,
`vue 2.7.16`, `vue-jest 3.0.7`, `testEnvironment: jsdom`, `roots: ['<rootDir>/test']`.
Run with nvm node (there is no `yarn` on PATH):

```bash
cd v2/wms2-mobile-ui
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
node_modules/.bin/jest
```

Local baseline before any change: **5 suites / 33 tests, all passing** (a 6th suite,
`test/plugins/keycloak-logout-clears-state.spec.js`, arrives with PR #31 on `origin/develop`; SBDEV-2732
records merged `develop` at 39 tests / 0 failures).

### 8.1 Unit — `test/store/resetState.spec.js`

For each of the **11** workflow modules, table-driven:

- `resetState` **exists** as a mutation.
- Applying it to a fully-dirtied state yields **`toEqual(initialState())`** — deep equality against the
  module's own `state()` factory, not a hand-written literal. This is what makes the mutation drift-proof:
  a field added to the factory and missed by the mutation fails here automatically.
- Every key of `state()` is present in the post-reset object (guards a partial `Object.assign`).

### 8.2 Component — `test/pages/workflow-reset-on-entry.spec.js`

The load-bearing suite. For each of the **12** pages (11 fixed + `putaway` as control), `shallowMount`
with a store seeded to a **mid-flow** step and a populated working set, then assert:

1. **`expect(wrapper.findComponent(<EntryScreen>).exists()).toBe(true)`** — the discriminator from §2.4.
   Fails for `mounted()`, passes for `created()`.
2. `expect(wrapper.findComponent(<MidFlowScreen>).exists()).toBe(false)`.
3. The module's working set is cleared — e.g. `picking.currentPosition` is `null`, not just `process` reset.

Named cases (entry / seeded mid-flow screen):

| Page | Assert rendered | Assert absent |
|---|---|---|
| `cancellation` | `CancellationScan` | `CancellationAction` |
| `cycle-count` | `SelectOrder` | `CountUnitLoad` |
| `move-stock` | `ScanSource` | `ScanDestination` |
| `move-unitload` | `ScanSource` | `ScanDestination` |
| `transfer-order` | `SelectOrder` | `ScanTransferLane` |
| `palletizing` | `ScanParcel` **and** `RapidScanPallet` | `ScanPallet`, `RapidScanParcel` (§4.3 — boolean-driven, not `process`) |
| `picking` | `ScanSection` | `Pick` |
| `replenish` | tab list view | `SelectSource` |
| `replenish-request` | `ScanLocation` | `InputAmount` |
| `truck-loading` | `SelectOrder` | `ScanGate` |
| `lookup` | `Search` | `ResultStock` |
| `putaway` *(control)* | `ScanPallet` | `StorePallet` |

Mechanics fixed by the probes: `localVue.use(Vuex)`; stub the Vuetify shell
(`stubs: ['v-card','v-tabs','v-tab','v-tabs-items','v-tab-item']`); and **`jest.mock` the three
optional-chaining components from §2.5** — required for `putaway` and `replenish`.

### 8.3 Regression

- Full existing suite green (`plugins/*`, `util/*` — untouched).
- `putaway` control case still passes after the §4.1 retrofit.
- `replenish.vue` still calls `fetchHeldUp()` on mount (assert the axios stub was hit) — guards the one
  non-reset behaviour that could be lost in the `mounted()`→`created()` move.
- Root state untouched by any `resetState`: assert `selectedWarehouse` / `warehouses` / `warehouseTimezone`
  are unchanged after resetting every module. Guards against re-breaking SBDEV-2726.

### 8.4 Manual test plan

Environment: DEV, on a real handheld or Chrome device-emulation at `/mobile/`. The blob is only observable
in a real browser, so this is not optional.

| # | Scenario | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| M1 | Shift handover, no logout | Operator A: Cycle Count → select order → scan UL → reach count screen. Navigate to main menu. Operator B opens Cycle Count. | Order-selection screen, empty. `countData`/`unitLoadInfo` cleared. | |
| M2 | Survives app restart | As M1, then fully close and reopen the browser/app before re-entering. | Entry screen. Confirms the fix covers rehydration, not just in-session nav. | |
| M3 | Cross-workflow nav in one session | Picking → mid-pick → main menu → Move Stock → main menu → Picking. | Section-scan screen each time; no flash of the pick screen. | |
| M4 | Palletizing (boolean-driven) | Scan a parcel to reach the pallet screen, leave, re-enter. Repeat on the *Pallet to Parcel* tab. | Both tabs open on their first screen; `scannedParcel`/`rapidScannedPallet` cleared. | |
| M5 | Two pages, one module | Replenish → mid-flow → main menu → **Replenish Request**. Then the reverse order. | Each page opens on its own entry screen; neither strands the other. | |
| M6 | No stale flash | Enter each of the 11 pages from a seeded mid-flow state and watch the first paint. | Entry screen on the **first** frame — no visible flash of the mid-flow screen (this is the `mounted()`→`created()` symptom). | |
| M7 | Replenish list still loads | Open Replenish from the main menu. | Critical/All tabs populate as before — `fetchHeldUp()` survived the refactor. | |
| M8 | Warehouse/timezone intact | Reset several workflows, then check the warehouse selector and any date column. | Warehouse and timezone unchanged. Guards SBDEV-2726 / the UTC migration. | |
| M9 | Logout clear still works | Log out via each of the three exits; inspect `localStorage`. | `vuex-mobile` removed — PR #31 not regressed. | |

---

## 9. Acceptance

**Script:** `sbdocs/9-System/scripts/verify-SBDEV-2930-mobile-workflow-pages-resume-stale-operator-state.sh`

```bash
PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-mobile-ui \
  bash sbdocs/9-System/scripts/verify-SBDEV-2930-mobile-workflow-pages-resume-stale-operator-state.sh
```

Final acceptance requires **`Result: N pass, 0 fail`** pasted verbatim in the completion report, plus a
green Jest run. Every in-scope row of §0 maps to at least one positive check; the five `mounted()` pages
additionally carry a negative check that the old partial-reset commits are gone.

### 9.1 The script has already been negative- AND positive-tested (2026-08-12)

Done during plan authoring rather than deferred to the implementer, because an unproven verify script is
the failure mode that let this repo report `57 pass / 0 fail` on a build containing the very defect its
ticket was written to catch.

**Baseline against unmodified `origin/develop` — `Result: 5 pass, 42 fail, 0 skip`.** The five passes are
all genuinely-satisfied pre-existing state, not vacuous rows:

| Row | Passes at baseline because |
|---|---|
| `CTL-putaway` | `pages/putaway.vue` really does already have its `created()` reset — the control group |
| `GUARD-reducer` | The SBDEV-2726 `vuex-mobile` key + 3-key exclusion is already in place and must stay |
| `GUARD-root` | `store/index.js` has no `resetState` today and must not gain one |
| `GUARD-replenfetch` | `replenish.vue` already calls `fetchHeldUp()`; the row exists to catch its loss |
| `T-jest` | The suite is green before the change (5 suites / 33 tests locally) |

Every other row is red, and each maps to a real unimplemented item.

**Positive test.** Fix A + Fix B were then applied to a representative slice in a throwaway worktree at
`origin/develop` — `cancellation` (a no-hook module/page), `picking` (a `mounted()` module/page), and the
`putaway` retrofit. Result: **`14 pass, 33 fail`** — every touched row flipped green, every untouched row
stayed red, and `CTL-putaway` survived the retrofit. So the rows have teeth in both directions.

**Two real bugs in the script were caught by doing this, and are fixed:**

1. `file_contains_ml` interpolated the pattern into perl's `m/.../`, so the `/` in `'putaway/resetState'`
   terminated the regex — `CTL-putaway` reported FAIL on a tree where it is plainly correct. The pattern is
   now passed via the environment (`$ENV{VERIFY_RE}`).
2. The `BNEG-*` rows used line-based `grep` against a **multi-line** construct (a commit inside a `mounted()`
   block). They could never match, so they reported "the old code is gone" while it was still there — a
   vacuous pass. A fail-closed `file_not_contains_ml` was added; they now correctly fail at baseline.

Both are the documented failure modes for this script family (helpers that fail *open*; negatives that are
vacuous). Every helper in the script now guards `[ -f "$2" ] || return 1` first.

### 9.2 Fix design validated behaviourally, not just by grep

The representative slice above was also run under Jest. On `picking.vue` — the page §2.4 probe 2 proved was
still broken — seeded `process:'12_pick'` with a populated working set:

```
process         = '0_section'
ScanSection     = true      ← entry screen renders synchronously  (was false)
Pick (stale)    = false     ← stale screen never renders          (was true)
currentPosition = null      ← working set cleared                 (was { id: 7, … })
orderSelected   = null
sectionSelected = null
```

the exact inverse of the baseline, plus `expect(dirty).toEqual(picking.state())` confirming the
factory-rebuild drift guard of §4.1. **The fix design is confirmed to work before any implementation
session starts.**

---

## 10. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | An operator legitimately relying on resume-after-accidental-navigation loses in-flight scan progress | Medium — re-scan from step 1; **no server-side state is lost or corrupted**, since every step commits server-side as it goes | Accepted deliberately (§11 Q1). Called out in the PR description and manual rows M1/M3 so QA sees the intended behaviour change rather than filing it as a regression. |
| R2 | `mounted()`→`created()` drops a side effect that was not a reset | Medium — a page silently stops loading its data | §4.2 enumerates all three pages with extra `mounted()` work; only `replenish.vue` has any, and it is explicitly kept. §8.3 + M7 assert it. |
| R3 | `Object.assign(state, initialState())` misses a non-reactive key | Low | Every key exists on the factory-produced object, so all writes go through existing reactive setters. §8.1's `toEqual(initialState())` pins it per module. |
| R4 | Someone "fixes" §2.5 by upgrading `vue-jest` or rewriting the `?.` templates | Medium — unrelated churn inside a bug-fix PR; the `?.` guards are load-bearing against exactly this class of stale data | §2.5 states the verified `jest.mock` workaround and forbids both alternatives. Flag in review. |
| R5 | The bug is invisible to telemetry, so a partial fix looks complete | High — this is *how the bug survived three prior patches* | The verify script enumerates all 11 pages; §8.2 asserts on the **rendered component**, the only signal that separates a real fix from a `mounted()` half-fix (§2.4 probe 2). |
| R6 | v1 is left exposed | Low, tracked | SBDEV-2932 filed with full detail, linked both ways (§11 Q3). |
| R7 | A future module is added without `resetState` | Medium — the gap reopens quietly | §11 Q5 records this as a known residual; the factory-rebuild pattern limits blast radius but does not prevent a new module from omitting the mutation entirely. |

---

## 11. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|---|---|
| Q1 | Blanket reset vs. preserving interrupted-workflow resume? | **RESOLVED 2026-08-12 (user):** blanket reset on entry. Matches the `putaway` precedent, needs no new plumbing, and is the only variant safe by construction on a shared handheld. Cost accepted as R1. Option C (excluding workflow modules from the reducer) rejected — §4.4. |
| Q2 | Scope: the ticket's 5 pages, 6, or all? | **RESOLVED 2026-08-12 (user):** all 10 workflow pages named in the ticket's table *plus* the two it omits — 11 changed, `putaway` as control. Driven by §2.4 probe 2 showing the "partial" pages are genuinely broken. |
| Q3 | v1 pairing? | **RESOLVED 2026-08-12 (user):** v2 only; v1 filed as **SBDEV-2932** (created 2026-08-12), which also records that v1's `persistedState` still uses the bare default `vuex` key with no reducer — the SBDEV-2726 hardening v1 never received. |
| Q4 | Should `store/home.js` (`profile`, `menus`) reset too? | **Out of scope, with a caveat.** It has no `process` marker and renders no workflow sub-screen, and PR #31 clears it at logout. **But** in the no-logout handover case of §1.3, `home.profile` still shows operator A's identity. That is a display concern with no transactional consequence, and folding it in would widen this PR past its review scope. Recommend a follow-up ticket if the shared-handheld handover is confirmed to happen without logout in practice. |
| Q5 | What stops the 12th workflow module from reopening this? | **Open — accepted residual (R7).** Nothing structural does today. A lint rule or a test that enumerates `store/*.js` and asserts each non-root module exports `resetState` would close it; deliberately not in this PR. Worth a tech-debt ticket. **Not a blocker for the TDD gate** — it concerns a module that does not exist yet, so no acceptance criterion in §8 depends on it. |

### 11.1 Process note — `ralplan` deliberately skipped

Recorded explicitly rather than left implicit, matching the precedent set by
`SBDEV-2854` and `SBDEV-2781` in this folder.

The consensus loop exists to stress a fix design's *shape*. Here the shape was settled by **direct user
decision on the three questions that actually carried the design space** — scope (Q2), reset policy (Q1),
and v1 pairing (Q3) — each answered against enumerated alternatives with their costs stated, and the
rejected options are preserved in §4.4 rather than discarded. What remained was mechanical and uniform: the
same two-line change applied to 11 pages and 11 modules, with the only genuine subtleties (`palletizing`'s
boolean markers, `replenish`'s two pages on one module, `replenish.vue`'s retained `fetchHeldUp()`) already
enumerated and each pinned by an acceptance row.

The substantive risk in a plan like this is not a wrong design — it is a **half-applied** one, which is
exactly how this bug survived three prior patches. That risk is addressed by mechanisms stronger than a
review pass: §0's enumeration from `git ls-tree` rather than from the ticket, a verify script proven red at
baseline and green post-fix, and §8.2's rendered-component assertion that refuses to accept a `mounted()`
half-fix.

**This is not a substitute for review.** The plan's status is `draft — awaiting review` and it has had no
independent reviewer pass; authoring and review are deliberately kept in separate lanes, so sign-off is the
reviewer's, not the author's.

---

## 12. Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ `db_verified: false`, **justified not omitted** — no DB surface exists (header note + §1). The gate is discharged by stronger evidence: three executed runtime probes in §2.4. No manual DB check owed. |
| 1 | All callsites enumerated | ✓ §0, 12 pages + 11 modules by `git ls-tree` on `origin/develop`; every in-scope row appears in §4/§5/§8.2. Two pages found that the ticket omits. |
| 2 | Adjacent bugs | ✓ §1.2 — `palletizing` (boolean-driven variant), `replenish-request` (shared module), and the whole `mounted()` class the ticket scored as "partial"/"yes". |
| 3 | Backward compatibility | ✓ §6.1 — no API, schema, or payload change. Persisted-blob *shape* is unchanged; only its lifetime. Pre-fix blobs self-heal on first entry, so no migration. |
| 4 | Concurrency | ✓ §7 rows 1/6 — single-threaded browser, no races. The cross-*operator* hazard is the bug itself, addressed by construction. |
| 5 | Multi-tenant | ✓ §7 row 7 + §8.3 — root-state warehouse/tenant/timezone keys explicitly untouched; regression test guards the SBDEV-2726 boundary. |
| 6 | Error handling | ✓ No new throw paths. §2.2 notes the fix *removes* an existing one (stale-deref in `pick.vue`). |
| 7 | Observability | ✓ §10 R5 — no telemetry surface by nature; the verify script + §8.2's rendered-component assertion are the compensating control. |
| 8 | Rollback / migration | ✓ §6.1 — no Flyway, no sysprop, no deploy ordering. Rollback is a plain revert; a reverted build simply resumes the old behaviour. |
| 9 | Test coverage | ✓ §8.1 (11 modules), §8.2 (12 pages incl. control), §8.3 regression, §8.4 nine manual rows. Harness verified working, incl. the §2.5 constraint. |
| 10 | Cross-version (v1↔v2) | ✓ §11 Q3 — v1 confirmed affected *and worse*; deferred to SBDEV-2932 by explicit decision, not omission. |

---

## 13. TDD Gate Baseline (2026-08-12)

Gate run; failing tests written and validated. **No production code changed** — the two spec files are the
only additions to the tree.

**Worktree:** `.claude/worktrees/wms2-mobile-ui/SBDEV-2930`
**Branch:** `bugfix/SBDEV-2930-workflow-page-reset-on-entry` off `origin/develop` (`2e5a995`)

| Spec | Tests | Baseline |
|---|---|---|
| `test/store/resetState.spec.js` | 34 | **30 fail / 4 pass** |
| `test/pages/workflow-reset-on-entry.spec.js` | 38 | **33 fail / 5 pass** |
| Full suite | 111 | **63 fail / 48 pass** — the 6 pre-existing suites (39 tests) all green |

Verify script in the same worktree: **`Result: 9 pass, 38 fail, 0 skip`** (up from 5 pass at plan time —
the five `T-*` spec rows now pass because the gate wrote the specs; `T-jest` correctly still fails).

**The 9 baseline passes are all deliberate controls, not weak tests:**

- `putaway` ×3 in each spec — it already uses `created()`. **Its passing at baseline is the proof the
  assertions are not vacuous**; a baseline where `putaway` also failed would indict the harness, not the code.
- Root-store guard — `store/index.js` must never gain a `resetState`.
- `replenish.vue still loads its Critical list on mount` — guards the one side effect the
  `mounted()`→`created()` move could silently drop.
- `resetting every workflow module leaves root warehouse/timezone state untouched` — the SBDEV-2726 boundary.

**Zero non-assertion failures.** Every one of the 63 is a clean `AssertionError`; no TypeErrors, no
compile errors, no broken scaffolding.

**Satisfiability confirmed.** The fix was applied to two representative slices (`cancellation`, a no-hook
page; `picking`, a `mounted()` page) inside the worktree; all six of their cases flipped green, the full
suite moved 63→51 failures, and the change was then reverted. So the tests can both fail today and pass
after the fix — the two properties a gate exists to establish.

**Two adjustments made during the gate, both recorded above:**

1. A **fourth** optional-chaining template file was found (§2.5) — the plan said three, and the omission
   killed the entire page suite at import time.
2. `replenish-request.vue`'s working-set assertion initially passed at baseline, because today's partial
   reset already nulls the one field it checked. Tightened to also assert `unitLoadQty` and
   `selectedULBatch`, which the partial reset leaves behind. An assertion that passes pre-fix is false
   confidence, so this one was caught and removed rather than shipped.

---

## 14. Implementation Status — MERGED 2026-08-12

**MERGED to `develop`** — PR #32, merge commit `98eae72`, 2026-08-12. All six commits verified as
ancestors of `origin/develop` (no orphans). Docker Develop Image CI fired on the push, so this is
deploying to DEV. ClickUp moved to `on dev`.

**Merged `develop` re-verified independently, not just the branch:**

```
Jest:   115/115, 8 suites
Verify: Result: 49 pass, 0 fail, 0 skip
```

> ### ⚠ DO NOT ARCHIVE YET — the §8.4 manual rows are still owed
>
> The merge was made on explicit instruction before the manual plan ran. That matters more here than
> usual: **this defect has no telemetry surface** (§7 row 1, §10 R5), so nothing will alert if it
> regresses — the ten manual rows are the only compensating control. And **M10 is the sole runtime
> check on the review Medium**, which was derived from the call graph and never reproduced live.
>
> Fast reproduction without walking a workflow — seed the blob from the browser console on DEV:
>
> ```js
> const b = JSON.parse(localStorage.getItem('vuex-mobile') || '{}')
> b.cycleCount = { ...(b.cycleCount || {}), process: '14_count',
>   order: { id: 999 }, unitLoadInfo: { cycleCountPosition: 999 }, countData: { count: 42 } }
> localStorage.setItem('vuex-mobile', JSON.stringify(b))
> location.reload()
> ```
>
> Then open Cycle Count → must land on the empty order-selection screen.
>
> For M10, watch the countdown rate after leaving and re-entering rapid picking:
> `setInterval(() => console.log($nuxt.$store.state.picking.count), 1000)` — must drop by **1** per
> second, not 2, and the operator must not be logged out.

**PR:** https://github.com/SiteBossInc/wms2-mobile-ui/pull/32 → `develop`
**Branch:** `bugfix/SBDEV-2930-workflow-page-reset-on-entry` off `origin/develop` (`2e5a995`)
**Worktree:** `.claude/worktrees/wms2-mobile-ui/SBDEV-2930` (retained for review feedback)
**Scope:** 24 files, +749/-33 — 11 pages, 11 store modules, 2 new specs. Nothing outside `pages/`,
`store/`, `test/`.

| SHA | Commit |
|---|---|
| `021f71e` | `fix(store)`: factory-rebuilt `resetState` on all 11 workflow modules (incl. `putaway` retrofit) |
| `2531dbc` | `fix(pages)`: `created()` reset on all 11 changed pages |
| `6fa66bc` | `test`: make the root-state boundary guard able to fail (review H1) |
| `acc8289` | `fix(picking)`: release the pick-timeout interval on reset (review M1) |
| `d778335` | `test`: actually exercise the root-store case in the boundary guard |
| `11075bb` | `test`: pin the `clearInterval` argument, not just its guard |

**Results**

```
Jest:   115/115, 8 suites          (gate baseline: 63 fail / 48 pass)
Verify: Result: 49 pass, 0 fail, 0 skip   (baseline 9 pass / 38 fail; stable over 5 runs)
```

Tests added: `test/store/resetState.spec.js` (38), `test/pages/workflow-reset-on-entry.spec.js` (38).
The 6 pre-existing suites (39 tests) stayed green throughout.

**Review lanes.** Conformance (`verifier`, opus): **PASS** — all 11 §0 in-scope rows VERIFIED, 0 MISSING,
0 PARTIAL, file set an exact match with §5. It independently replayed both specs against unfixed
`origin/develop` and reproduced the §13 gate baseline exactly. Code review (`code-reviewer`, opus): 1 High
+ 1 Medium, both fixed; 8 Low recorded in the PR body. `security-reviewer` not run — the diff touches no
auth, SQL, upload or secret path.

**The Medium was introduced by this plan's own fix and is worth remembering.** `store/picking.js` `timer`
is a live `setInterval` handle, not data. The `created()` reset nulled it without clearing, breaking an
accidental self-heal (`scanSource.vue`'s `if (!this.timer)` guard), so re-entering Picking ran two
intervals — `count` decrementing twice a second, the `count < 0` watcher firing early and calling
`passScan()`, **auto-passing a pick position**. The obvious fix (`clearInterval(state.timer)`) would have
been worse: `timer` rides the persisted blob, each page load gets a fresh `Window` whose timer-id counter
restarts at 1, and `plugins/keycloak.client.js:320` creates the token-refresh interval during boot and so
holds one of the lowest ids — clearing a rehydrated handle could silently stop token refresh. Resolved with
a module-scoped `liveTimer` outside Vuex. This also kills a **pre-existing** instance of the same bug:
`scanSource.submit()` called `clearTimeOut` unconditionally, so a reload plus one rapid-pick submit already
cleared a foreign id.

**Three of my own claims failed testing and were corrected, not shipped** — recorded because the pattern is
the lesson, not the individual errors:

1. The root guard did not catch a root `resetState`; the bare mutation type was never committed, so it was
   defined and never invoked. Both review lanes caught this independently.
2. Fixing (1) silently broke a *different* detection. `namespaced: false` changes a mutation's **type name**,
   not the state Vuex hands it, so a bare `store.commit('resetState')` placed before the sentinel
   post-condition fires a non-namespaced module's handler **with its own module state** — repairing the very
   fault the sentinel detects. Ordering is now load-bearing and documented in the test.
3. A test claimed to pin the `clearInterval` **argument** but only pinned its guard: because it seeds a
   freshly `resetModules()`'d module, `liveTimer` is always null, so no `liveTimer`-gated implementation can
   reach the assertion. Swapping the argument alone left the suite fully green.

**Two verify-script defects found by negative-testing it** (both fixed): `A-picking-rb` lost containment —
`.*?` under `/s` spans past the mutation, so a hand-listed reset plus any later
`Object.assign(state, initialState())` elsewhere in the file reported PASS, a false green; now
tempered-greedy. And `M1-release` passed on **dead code** if `setTimer` stopped syncing `liveTimer`; it now
requires the ownership assignment too.

**One transient worth knowing about:** a verify run reported `48 pass, 1 fail` immediately after
`jest --clearCache`, with both failing rows (`T-jest`, `M1-release`) being ones that shell out. Five
consecutive re-runs gave `49 pass, 0 fail`, and the isolated grep was 0/20 failures. The script's `run`
helper records a tool that *failed to execute* identically to a false assertion — re-run before believing
either number.

**Deliberately not done:** the §8.4 manual plan (browser-only, 10 rows incl. a new M10 for the rapid-pick
timer) is the reviewer's to execute; `clearTimeOut` still uses `clearInterval(context.state.timer)` rather
than `liveTimer` (defence-in-depth Low, would need another review round); and §11 Q5 remains an accepted
residual — nothing structurally stops a 12th workflow module from omitting `resetState`.

**Not done by this session, by design:** deploy beyond DEV, QA promotion, plan archival, worktree removal.

---

## 15. Archive checklist — BLOCKED, do not run `archive-plan` yet

`archive-plan` was requested on 2026-08-12 and deliberately **held**. Everything below is done; only the
manual gate remains. Run `archive-plan` once the two rows are ticked.

| # | Item | State |
|---|---|---|
| 1 | Code merged to `develop` | ✅ PR #32, merge `98eae72` |
| 2 | Merged `develop` re-verified (not just the branch) | ✅ Jest 115/115, verify 49 pass / 0 fail |
| 3 | CI / DEV image built | ✅ Docker Develop Image CI success, 2m37s |
| 4 | ClickUp status | ✅ `on dev` |
| 5 | Plan §14 + folder README updated | ✅ |
| 6 | **§8.4 M1 — shift handover without logout, on DEV** | ⬜ **BLOCKING** |
| 7 | **§8.4 M10 — rapid-pick timer decrements once/sec, no logout** | ⬜ **BLOCKING** |
| 8 | §8.4 remaining rows (M2–M9) | ⬜ recommended, not blocking |

**Why 6 and 7 block.** This defect has **no telemetry surface** (§7 row 1, §10 R5) — nothing alerts if it
regresses, so the manual rows are the only compensating control that exists. And M10 is the **sole runtime
check** on the review Medium: the double-interval that auto-passes a pick position was derived from the call
graph and never reproduced live. Archiving retires the verify script and removes the worktree — exactly the
tooling you would want if either row fails.

**Deliberately still held for that reason:**

- `sbdocs/9-System/scripts/verify-SBDEV-2930-...-state.sh` — live, not retired to `4-Archieves/scripts/`.
- `.claude/worktrees/wms2-mobile-ui/SBDEV-2930` — present at `11075bb`, so a DEV finding can be fixed
  without rebuilding the tree. Remove with
  `git -C v2/wms2-mobile-ui worktree remove .claude/worktrees/wms2-mobile-ui/SBDEV-2930 && git -C v2/wms2-mobile-ui worktree prune`.

**If a row fails**, the fix belongs on a new branch off the updated `develop` — this one is merged, so do
not reopen PR #32. Record the outcome here either way; a waived gate is fine if it is written down as
waived rather than left looking passed.

**Completion criterion:**

```bash
cd .claude/worktrees/wms2-mobile-ui/SBDEV-2930
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; node_modules/.bin/jest
```

all 111 tests passing, **and**

```bash
PROJECT_ROOT=$PWD bash sbdocs/9-System/scripts/verify-SBDEV-2930-...-state.sh
```

reporting `Result: 47 pass, 0 fail`. Neither contract may be weakened — not by relaxing an assertion, not
by deleting a case, and not by moving a reset back into `mounted()`.
