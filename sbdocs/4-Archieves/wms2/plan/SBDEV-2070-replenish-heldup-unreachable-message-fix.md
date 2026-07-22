---
title: "SBDEV-2070 (V2): Misleading \"Inventory Unreachable / location: 0\" Message on Held-Up Replenishment Rows (mobile-UI message fix)"
ticket: "SBDEV-2070"
ticket_url: "https://app.clickup.com/t/SBDEV-2070"
type: bug
priority: high
status: archived
archived: 2026-07-20
project:
  - wms2
version: v2
requester: WineCo (client-reported)
created: 2026-07-19
updated: 2026-07-19
db_verified: true
related:
  - SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move
  - "../../../4-Archieves/wms2/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md"
  - SBDEV-2481
tags:
  - plan
  - replenishment
  - mobile-ui
  - message-fix
  - sbdev-2070
  - v2
---

# SBDEV-2070 (V2): Misleading "Inventory Unreachable / location: 0" Message on Held-Up Replenishment Rows

> **Archived 2026-07-20** — implemented and merged via wms2-mobile-ui PR [#20](https://github.com/SiteBossInc/wms2-mobile-ui/pull/20) (→ develop).
> Acceptance script retained at `sbdocs/9-System/scripts/verify-SBDEV-2070-replenish-heldup-unreachable-message-fix.sh`.

**Ticket:** [SBDEV-2070](https://app.clickup.com/t/SBDEV-2070)
**Project:** v2/wms2-mobile-ui (Nuxt 2 / Vue 2 / Vuetify 2) | **Version:** v2 | **Type:** Bug (misleading UI copy — NOT a reservation leak)
**Priority:** High / urgent (client-reported; erodes floor-operator trust; ticket also tagged wmsv1)
**Status:** implemented 2026-07-19 (ralplan consensus APPROVED → TDD gate → code-review APPROVE → PR #20; jest 10/0, verify 27/0; pending full authenticated mobile smoke) — see §12
**Date:** 2026-07-19
**Requester:** WineCo (client-reported)

> **Scope is locked (user decision):** this plan changes **mobile-UI message text only**. No backend change. No change to the web "Cancel Replenishment" flow, to `ReplenishorderService.cancelReplenishmentOrder`, or to the async `cancelUnreachableReplenishment` maintenance cron. All existing guards and branch conditions are preserved byte-for-byte; only the *strings the UI shows* change.
>
> **v2 mobile note:** `v2/wms2-mobile-ui` is a Nuxt 2 SPA (`ssr:false`), Vue 2.6 + Vuetify 2.6. Toasts use `@nuxtjs/toast` (`this.$toast.error(html)` — the message may contain `<br/>`). Held-up rows are synthesized client-side in `pages/replenish.vue::fetchAllReplen` from the `GET /dashboard/replenishMonitorViewSummary` payload. Jest **is** configured (`jest.config.js`, `roots:['<rootDir>/test']`, `@vue/test-utils` + `vue-jest`) despite the sub-project `CLAUDE.md` "no test suite" note — so a unit test is feasible (see §8).

---

## 0. Affected Sites (enumeration)

All three sites render the same defective "Inventory Unreachable" copy on a **held-up** row (a summary row with no OPEN replenish order, i.e. `roId == null`). "In scope" rows are each visited by §5. Line numbers verified against the working tree on 2026-07-19.

| # | Site | File:line (v2) | Trigger / guard | Defect | In scope | §5 |
|---|------|----------------|-----------------|--------|:--------:|----|
| 1 | Toast on tapping a non-actionable held-up row | `pages/replenish.vue:216-219` (`selectOrder` else-branch) | fires when `!(item.roId \|\| item.id)` | "**Unable to Perform Replenishment Request**" framing (implies a failed op) + unconditional `Quantity on …: ${item.qtyOnNonReplenishableLocation}` → "…: 0" | **YES** | §5.1 |
| 2 | "All Replenish" list chip | `components/replenish/process/AllReplenList.vue:119` | `v-chip` under `v-if="(!item.source)"` | hard-coded `Inventory Unreachable @<br/>{{item.nonReplenishableLocationNames}} x {{ item.qtyOnNonReplenishableLocation }} items` → "… x 0 items" / "… x undefined items" | **YES** | §5.2 |
| 3 | "Held Up" list chip | `components/replenish/process/HeldUpList.vue:68` | `v-chip` under `v-if="(!item.roSourceName)"` | identical hard-coded chip text | **YES** | §5.3 |
| — | Held-up row mapping (source of the fields) | `pages/replenish.vue:154-174` (`fetchAllReplen`) | maps `id=item.roId`, `source=item.roSourceName`, carries `qtyOnNonReplenishableLocation` + `nonReplenishableLocationNames` | *no change* — enumerated so reviewers see where the fields originate; DTO also exposes `qtyOnReplenishableLocation` / `replenishableLocationNames` **not** currently mapped (optional enrichment, see §10) | context | — |
| — | Shared message helper (new) | `util/replenishMessages.js` (new file) | imported by sites 1-3 | single source of truth for the branch-aware copy | **YES** | §5.0 |

**Explicitly out of scope (no change):** `wms2-api` `ReplenishorderService.cancelReplenishmentOrder`, `ReplenishOrderController.cancelReplenishOrder`, `ViewDtoService.getReplenishMonitorViewSummary`, the `replenishMonitorViewSummary` native query, and the `cancelUnreachableReplenishment` cron. The paired **v1** files (`v1/wms-mobile-ui`) are a follow-up, see §10.

---

## 1. Problem Statement

### User-Visible Symptom (from ticket)
After cancelling a replenishment request, a floor operator sees the SKU still listed on the mobile Replenish screen, and tapping the row raises:

> **Unable to Perform Replenishment Request: Inventory Unreachable! Qty on Non-Replenishable location: 0**

The ticket concludes inventory is "still reserved" and that a cron eventually self-corrects.

> **Copy-string note:** the ticket text says *"Inventory Unreachable!"*; the actual mobile **code** renders *"Inventory not reachable!"* in the toast (`replenish.vue:217`) and *"Inventory Unreachable @…"* in the chips (`AllReplenList.vue:119` / `HeldUpList.vue:68`). Quotes attributed to the ticket keep the ticket's verbatim wording; quotes describing the code use the exact code string.

### Corrected premise (the ticket's root cause is WRONG)
There is **no reservation leak** and **no cron dependency** for the release. The web "Cancel Replenishment" action releases the reservation **synchronously, in one tenant transaction**:

```
Web "Cancel Replenishment"
  → GET /replenishOrder/cancelReplenishOrder/{id}
  → ReplenishOrderController.cancelReplenishOrder (v2, :172)
  → ReplenishorderService.cancelReplenishmentOrder (v2, ReplenishorderService.java:246-270)
        @Transactional(tenantTransactionManager)
        1. changeReservedAmount(sourceStock, -requestedamount, CODE_REPLENISHMENT_CANCELLED)
        2. setState(CANCELED)
        3. save(...)
```

This is byte-for-byte equivalent to v1. The reservation is released the moment the cancel transaction commits — the `cancelUnreachableReplenishment` cron is **not** what fixes it.

The **real, still-present defect** is a **misleading mobile-UI message**. The mobile Replenish screen lists "held-up" SKUs from `GET /dashboard/replenishMonitorViewSummary`. A summary row appears whenever unmet picking demand exists (`HAVING bottles_needed - available > 0`). `roId` (`t4.ro_id`) is **NULL** whenever no OPEN replenish order (`replenishorder.state < 600`) exists for that item. When a row has `roId == null` **and** `qtyOnNonReplenishableLocation == 0`, the UI still interpolates the qty and frames a passive tap as a failed operation → the "…location: 0" nonsense. It conflates *"no open replenish order"* with *"inventory stuck on a non-replenishable location."*

### DB-Verification (inline, `db_verified: true`)
Ran the monitor-summary grouping on **wms2-wineco-dev2** (v2 tenant), bucketed by `(roId IS NULL, on_non_replenishable_location)`:

| `roId` | `qtyOnNonReplenishableLocation` bucket | rows | Meaning |
|--------|----------------------------------------|-----:|---------|
| set    | `= 0`   | 2 | open RO, actionable — opens into source step |
| set    | `> 0`   | 1 | open RO, stock on a non-rep location |
| **NULL** | **`= 0`** | **1** | **the exact ticket case → "…location: 0" nonsense** |

The single `{roId NULL, nonrep=0}` row is precisely the ticket's reported state. (Note: the wms DB MCP drops the first query after idle with "server closed the connection unexpectedly" — retried once, already handled.)

### Reproduction (mobile)
1. Open mobile **Replenish** on a tenant with unmet picking demand but no open replenish order for a SKU (e.g. just after a cancel, or when available stock is all pickable-but-short).
2. The SKU appears as a held-up row.
3. Tap it → toast: *"Unable to Perform Replenishment Request: Inventory Unreachable! … location: 0"*.
4. The "All Replenish" / "Held Up" lists also show the `… x 0 items` chip.

---

## 2. Root Cause Analysis

**RC1 — the `roId == null` branch is the "no open replenish order" state, not an error.**
In `fetchAllReplen` (`pages/replenish.vue:154-174`) held-up rows are mapped with `id: item.roId`. When `roId` is null the row is non-actionable (there is nothing to open into the source step). `selectOrder` (`:208-224`) computes `const id = item?.roId || item?.id` and takes the else-branch when both are falsy — a legitimate "nothing to do here yet" state — but presents it as **"Unable to Perform Replenishment Request"**, i.e. a *failed action*.

**RC2 — `qtyOnNonReplenishableLocation` is interpolated unconditionally.**
All three sites splice the qty into the copy with no guard:
- toast: `Quantity on ${item?.nonReplenishableLocationNames || "…"}: ${item.qtyOnNonReplenishableLocation}` (`replenish.vue:218`)
- chips: `{{item.nonReplenishableLocationNames}} x {{ item.qtyOnNonReplenishableLocation }} items` (`AllReplenList.vue:119`, `HeldUpList.vue:68`)

When the field is `0` (or `undefined` for a row with no non-replenishable stock), the copy degrades to `… : 0` / `… x 0 items` / `… x undefined items`. The number is meaningless in the `roId == null, nonrep == 0` case.

**RC3 — one defect, three copies.**
The same wrong string is hand-duplicated at three sites, so any fix must not re-drift. A single shared helper is the correct shape.

*Regression chain: N/A — this is not a regression from a prior change; the copy has been wrong since the held-up-row feature landed. Section intentionally omitted per template guidance.*

---

## 3. (Regression chain) — N/A

Not applicable. No prior plan/commit introduced this; it is original copy. See §2 RC3 for the duplication cause.

---

## 4. Architecture Overview

### Data flow (summary → mobile → message)

```
GET /dashboard/replenishMonitorViewSummary                      (wms2-api — UNCHANGED)
  └─ ViewDtoService.getReplenishMonitorViewSummary
       └─ ReplenishmentMonitorViewRepository.getReplenishViewSummary  (native query)
            HAVING bottles_needed - available > 0                 ← row appears on unmet demand
            t4.ro_id  → roId  (NULL when no OPEN replenishorder, state < 600)
            fields: roId, roSourceName, qtyOnNonReplenishableLocation, nonReplenishableLocationNames
                                   │
                                   ▼  (client)
pages/replenish.vue :: fetchAllReplen   (:154-174)              ← maps held-up rows
   id = roId,  source = roSourceName,  carries nonrep qty + names
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        ▼                          ▼                          ▼
 selectOrder else-branch     AllReplenList chip          HeldUpList chip
   (replenish.vue:216)          (:119, v-if !source)       (:68, v-if !roSourceName)
        │                          │                          │
        │                          │                          │
        ▼                          └────────────┬─────────────┘
 heldUpReplenMessage(item)   (full, toast)      ▼
        │                          heldUpChipMessage(item)  (terse, chips)
        └──────────────► util/replenishMessages.js ◄──────────┘   (NEW — single source of truth,
                           mirrors util/replenishUnitLoads.js precedent)
   toast  heldUpReplenMessage: qty>0 → "…on a non-replenishable location (<names>, <qty> items). Move it first."
                              else   → "No replenishable stock available for <sku> yet."
   chip   heldUpChipMessage:  qty>0 → "Stock on non-replenishable location (<names>)"
                              else   → "No replenishable stock yet"
```

### Key Files

| File | Role | Change |
|------|------|--------|
| `v2/wms2-mobile-ui/util/replenishMessages.js` | **new** — branch-aware held-up message helpers (toast + chip). Follows the existing `util/replenishUnitLoads.js` precedent, already imported via `~/util/…` in `selectSource.vue:87` and `selectUnitLoad.vue:116` | create |
| `v2/wms2-mobile-ui/pages/replenish.vue` | held-up mapping + `selectOrder` toast (site 1) | edit `:216-219` (+ import) |
| `v2/wms2-mobile-ui/components/replenish/process/AllReplenList.vue` | "All Replenish" chip (site 2) | edit `:119` (+ import/method) |
| `v2/wms2-mobile-ui/components/replenish/process/HeldUpList.vue` | "Held Up" chip (site 3) | edit `:68` (+ import/method) |
| `v2/wms2-mobile-ui/test/util/replenishMessages.spec.js` | **new** — unit test for the helper | create |
| `wms2-api` cancel path + cron | reference only | **no change** |

---

## 5. Fix Design

**Principle:** keep every guard and branch condition exactly as-is; replace only the *text* each branch renders, sourced from one helper. The helper is a pure function so it is unit-testable in isolation and undefined-safe.

### 5.0 New shared helper — `util/replenishMessages.js`

Precedent: this mirrors the existing `util/replenishUnitLoads.js` (imported via `~/util/…` in `components/replenish/process/selectSource.vue:87` and `selectUnitLoad.vue:116`), so the `~/util/` import shape is already established in this exact component tree.

**Two exports — one per render surface** (chip decision = Critic option (a)): the **toast** has room for a full sentence; the **chips** render inside a `width:100%` but small, `text-caption` `v-chip` and previously relied on a literal `<br/>`. Reusing the ~20-word toast sentence in that chip would wrap into a tall multi-line block. So chips get a terse variant.

```js
// util/replenishMessages.js
// SBDEV-2070: branch-aware, undefined-safe copy for a "held-up" replenish
// summary row (a row with NO open replenish order — roId == null).
// Shared constraints (BOTH functions):
//   - MUST NOT emit the substring "location: 0", "x 0 items", or "x undefined items".
//   - qty>0  → name the non-replenishable location(s); qty falsy/0 → no number at all.

// Full sentence — used by the tap toast (has horizontal room).
export function heldUpReplenMessage(item = {}) {
  const sku = item.skuName || 'this item'
  const qty = Number(item.qtyOnNonReplenishableLocation)
  if (Number.isFinite(qty) && qty > 0) {
    const loc = item.nonReplenishableLocationNames || 'a non-replenishable location'
    return `Not replenishable yet — available stock for ${sku} is on a non-replenishable ` +
           `location (${loc}, ${qty} items). Move it to a replenishable location first.`
  }
  return `No replenishable stock available for ${sku} yet.`
}

// Terse chip form — fits a small width:100% v-chip; no <br/>, no long tail.
export function heldUpChipMessage(item = {}) {
  const qty = Number(item.qtyOnNonReplenishableLocation)
  if (Number.isFinite(qty) && qty > 0) {
    const loc = item.nonReplenishableLocationNames || 'a non-replenishable location'
    return `Stock on non-replenishable location (${loc})`
  }
  return 'No replenishable stock yet'
}

export default heldUpReplenMessage
```

### 5.1 Site 1 — `pages/replenish.vue::selectOrder` toast (`:216-219`)

**Before**
```js
} else {
  this.$store.commit('replenish/setOrder', null)
  this.$toast?.error(`Unable to Perform Replenishment Request: Inventory not reachable!
    <br/>Quantity on ${item?.nonReplenishableLocationNames || "Non-replenishable location"}: ${item.qtyOnNonReplenishableLocation}
    `)
}
```

**After** (guard + `setOrder(null)` unchanged; only the string changes; use `$toast?.info` so it no longer reads as a failed operation)
```js
} else {
  this.$store.commit('replenish/setOrder', null)
  this.$toast?.info(heldUpReplenMessage(item))
}
```
Add at top of `<script>`: `import { heldUpReplenMessage } from '~/util/replenishMessages'`.

> **`$toast.info` confirmed present:** `plugins/toast.js:74-77` explicitly defines `info(message, options)` → `originalToast.info(message, options)` (with de-dup). Switching `error`→`info` is safe; the manual-smoke row keeps a belt-and-suspenders check.

### 5.2 Site 2 — `components/replenish/process/AllReplenList.vue` chip (`:114` color, `:119` text)

**Before** (chip block `:112-120`)
```html
<v-row no-gutters class="text-caption align-center" v-if="(!item.source)">
  <v-col cols="12">
    <v-chip color="error"
      small
      class="text-caption mt-2 w-100 py-2"
      style="height:unset;width:100%;"
    >
      Inventory Unreachable @<br/>{{item.nonReplenishableLocationNames}} x {{ item.qtyOnNonReplenishableLocation }} items
    </v-chip>
```

**After** (`v-if="(!item.source)"` guard unchanged; severity now state-bound; text = terse chip helper)
```html
<v-row no-gutters class="text-caption align-center" v-if="(!item.source)">
  <v-col cols="12">
    <v-chip :color="item.qtyOnNonReplenishableLocation > 0 ? 'warning' : 'grey'"
      small
      class="text-caption mt-2 w-100 py-2"
      style="height:unset;width:100%;"
    >
      {{ heldUpChip(item) }}
    </v-chip>
```
Add `import { heldUpChipMessage } from '~/util/replenishMessages'` and a method wrapper (templates cannot call a bare import):
```js
methods: {
  heldUpChip(item) { return heldUpChipMessage(item) },
  // ...existing methods
}
```
Rationale for `color`: hard-coded `error` (red) is inconsistent with the softened `info` toast and with Principle 1 — a held-up-but-not-actionable row is not an error. `warning` (stock parked on a non-rep lane, actionable by moving it) vs `grey` (nothing to show, `qty == 0`).

### 5.3 Site 3 — `components/replenish/process/HeldUpList.vue` chip (`:63` color, `:68` text)

**Before** (chip block `:61-69`)
```html
<v-row no-gutters class="text-caption align-center" v-if="(!item.roSourceName)">
  <v-col cols="12">
    <v-chip color="error"
      small
      class="text-caption mt-2 w-100 py-2"
      style="height:unset;width:100%;"
    >
      Inventory Unreachable @<br/>{{item.nonReplenishableLocationNames}} x {{ item.qtyOnNonReplenishableLocation }} items
    </v-chip>
```

**After** (`v-if="(!item.roSourceName)"` guard unchanged; severity state-bound; terse chip helper)
```html
<v-row no-gutters class="text-caption align-center" v-if="(!item.roSourceName)">
  <v-col cols="12">
    <v-chip :color="item.qtyOnNonReplenishableLocation > 0 ? 'warning' : 'grey'"
      small
      class="text-caption mt-2 w-100 py-2"
      style="height:unset;width:100%;"
    >
      {{ heldUpChip(item) }}
    </v-chip>
```
Same import (`heldUpChipMessage`) + `heldUpChip(item)` method wrapper and same `color` rationale as §5.2.

---

## 6. File Change Summary

| # | File | Change | Guard kept? |
|---|------|--------|:-----------:|
| 1 | `util/replenishMessages.js` | **new** pure helpers: `heldUpReplenMessage(item)` (toast, full) + `heldUpChipMessage(item)` (chip, terse) | n/a |
| 2 | `pages/replenish.vue` | import `heldUpReplenMessage`; replace `:216-219` toast body; drop "Unable to Perform…" framing; `$toast.error`→`$toast.info` | ✅ (`else`-branch + `setOrder(null)`) |
| 3a | `components/replenish/process/AllReplenList.vue` | import `heldUpChipMessage` + `heldUpChip` method; replace `:119` chip text | ✅ (`v-if="(!item.source)"`) |
| 3b | `components/replenish/process/AllReplenList.vue` | chip **color** `:114` `color="error"` → `:color="item.qtyOnNonReplenishableLocation > 0 ? 'warning' : 'grey'"` | ✅ |
| 4a | `components/replenish/process/HeldUpList.vue` | import `heldUpChipMessage` + `heldUpChip` method; replace `:68` chip text | ✅ (`v-if="(!item.roSourceName)"`) |
| 4b | `components/replenish/process/HeldUpList.vue` | chip **color** `:63` `color="error"` → `:color="item.qtyOnNonReplenishableLocation > 0 ? 'warning' : 'grey'"` | ✅ |
| 5 | `test/util/replenishMessages.spec.js` | **new** unit test — both functions × both branches + undefined/0-safety | n/a |

No backend files. No store/API changes.

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Status |
|---|---|---|--------|
| 1 | Database state | none | **N/A** — UI-text only; no schema, no seed rows |
| 2 | Feature flags / system properties | none | **N/A** — no toggle gates this copy |
| 3 | Config / env | none | **N/A** — no env or `nuxt.config` change |
| 4 | Deploy-order dependencies | none | **N/A** — mobile-UI ships independently; backend unchanged |
| 5 | Data migration | none | **N/A** |
| 6 | External systems | none | **N/A** |
| 7 | Access / permissions | none | **N/A** — no new route/role |
| 8 | Monitoring / alerts | none | **N/A** — no new metric |

### 7.2 Implementation Checklist
- [ ] Create `util/replenishMessages.js` with `heldUpReplenMessage` + `heldUpChipMessage` (§5.0).
- [ ] `pages/replenish.vue`: import `heldUpReplenMessage`; replace `selectOrder` else-branch toast; `error`→`info` (§5.1).
- [ ] `AllReplenList.vue`: import `heldUpChipMessage` + `heldUpChip` method; replace chip text (`:119`) **and** chip color (`:114`) (§5.2).
- [ ] `HeldUpList.vue`: import `heldUpChipMessage` + `heldUpChip` method; replace chip text (`:68`) **and** chip color (`:63`) (§5.3).
- [ ] Create `test/util/replenishMessages.spec.js` (§8).
- [ ] Run the helper unit test (green) + the verify script (`0 fail`).
- [ ] Manual click-path smoke (§8 manual table) on a mobile viewport.
- [ ] Code review.

---

## 8. Testing Plan

### Acceptance Criteria (testable — for `wms-tdd-gate`)
1. Tapping a held-up row with `roId == null` **and** `qtyOnNonReplenishableLocation == 0` shows the "no replenishable stock" message and **never** the substring `location: 0`.
2. A row with `qtyOnNonReplenishableLocation > 0` shows the location name(s) + qty and the "move it to a replenishable location first" guidance.
3. Chips in `AllReplenList` / `HeldUpList` render the terse accurate text (`heldUpChipMessage`); never `x 0 items` / `x undefined items` / `Inventory Unreachable @`; and chip color is state-bound (`warning`/`grey`, never `error`).
4. Rows **with** an open replenish order (`roId` set) are unaffected — `selectOrder` still opens into `'2_source'`.
5. Zero backend change; no change to the cancel path or the cron.

### Unit test — `test/util/replenishMessages.spec.js`

`describe('heldUpReplenMessage')` (toast, full):
| Test method (it) | Asserts | AC |
|---|---|---|
| `roId null + qty 0 → no-stock message, no "location: 0"` | returns "No replenishable stock available for … yet."; `.not.toContain('location: 0')` | AC1 |
| `qty > 0 → names + qty + move guidance` | contains names, `${qty} items`, "Move it to a replenishable location" | AC2 |
| `undefined qty/names → no "undefined"/"x 0 items"` | `.not.toMatch(/undefined/)`; `.not.toContain('x 0 items')` | AC3 |
| `missing skuName → "this item" fallback` | contains "this item", no `undefined` | AC3 |

`describe('heldUpChipMessage')` (chip, terse):
| Test method (it) | Asserts | AC |
|---|---|---|
| `qty > 0 → "Stock on non-replenishable location (<names>)"` | contains names; `.not.toMatch(/\bitems\b/)` (no qty tail); short (≤ ~60 chars) | AC2, AC3 |
| `qty 0 → "No replenishable stock yet"` | exact string; `.not.toContain('x 0 items')`; `.not.toContain('location: 0')` | AC1, AC3 |
| `undefined qty/names → no "undefined"/"x 0 items"` | `.not.toMatch(/undefined/)`; `.not.toContain('x 0 items')` | AC3 |

**Run command** (no `yarn` on PATH; node via nvm):
```bash
cd v2/wms2-mobile-ui
PATH="$HOME/.nvm/versions/node/v24.15.0/bin:$PATH" \
  node node_modules/.bin/jest --testPathPattern=replenishMessages
```
> Jest `roots:['<rootDir>/test']` — the spec **must** live under `test/` (e.g. `test/util/`), matching the existing `test/plugins/*.spec.js`. AC4/AC5 are guarded structurally by the verify script (guards preserved, no backend edit) rather than by the pure-helper unit test.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Held-up row, qty = 0 (ticket case) | mobile dev (`:3001`) on wineco-dev2 | Open Replenish → tap a `roId=null, nonrep=0` row | Info toast "No replenishable stock available for {sku} yet."; **no** "location: 0", no "Unable to Perform…" | |
| Held-up row, qty > 0 | mobile dev | Tap a `roId=null, nonrep>0` row | Toast names the location(s) + qty + "move it to a replenishable location first" | |
| Chips render (copy) | mobile dev | View "All Replenish" and "Held Up" lists with the above rows | Chips show the terse accurate copy; never "x 0 items" / "x undefined items"; color `warning` when qty>0, `grey` when qty=0 (no red `error`) | |
| Chip wrap qty>0 @320px | mobile dev, 320px viewport | View a `qty>0` held-up chip | Terse text wraps cleanly inside the `width:100%` chip; no horizontal overflow/truncation, no clipped text | |
| Chip wrap qty=0 @320px | mobile dev, 320px viewport | View a `qty=0` held-up chip | "No replenishable stock yet" fits on ≤2 lines, no overflow/truncation | |
| Actionable row unaffected | mobile dev | Tap a row with `roId` set | Opens into source step (`process '2_source'`); no toast | |

### Test execution (fill in after running)

| Command | Result | Pass/Fail/Skipped |
|---------|--------|-------------------|
| `node node_modules/.bin/jest --testPathPattern=replenishMessages` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2070-replenish-heldup-unreachable-message-fix.sh` | | |

### Deliberately-skipped coverage
| What | Why |
|------|-----|
| Testcontainers / API integration test | UI-only change; backend untouched |
| Component-mount (`@vue/test-utils`) rendering test | pure helper carries the logic; chip is a trivial `{{ heldUpChip(item) }}` interpolation covered by manual smoke + verify grep |

**Acceptance gate:** `bash sbdocs/9-System/scripts/verify-SBDEV-2070-replenish-heldup-unreachable-message-fix.sh` → `0 fail`.

---

## 9. Risks & Mitigations

| # | Risk | Likelihood | Mitigation |
|---|------|:----------:|------------|
| 1 | Template can't call a bare import → chip renders blank | Med | Wrap in a `heldUpChip(item)` **method**; verify script asserts the method call form; manual smoke confirms render |
| 2 | Copy layout: old chip embedded a literal `<br/>` and old toast used `<br/>`. Chip has a tighter space budget than the toast (small `text-caption` `v-chip`, `width:100%` but low height). Reusing the full toast sentence in the chip would wrap tall/ugly | Med | Chips use the **terse** `heldUpChipMessage` (no `<br/>`, ≤ ~60 chars); toast uses full prose. §8 manual-smoke adds explicit chip-wrap rows at 320px for qty>0 and qty=0. `$toast.info` renders plain text fine without `<br/>` |
| 3 | Copy re-drifts across the 3 sites in future edits | Med | Single helper is the source of truth; verify script asserts old strings are gone at all 3 sites |
| 4 | Someone "fixes" the perceived reservation leak in the backend | Low | §1 corrected-premise + §0 out-of-scope list document that the cancel path is already correct; do not touch it |
| 5 | Jest harness surprise (`CLAUDE.md` says "no test suite") | Low | `jest.config.js` + `test/plugins/*.spec.js` prove it runs; spec placed under `test/`; verify script's jest step is `SKIP`-able via `SKIP_JEST=1` |
| 6 | v1 twin left inconsistent | Med | §10 tracks the paired v1 follow-up (identical files/lines) |

**Acceptance script:** `sbdocs/9-System/scripts/verify-SBDEV-2070-replenish-heldup-unreachable-message-fix.sh` (POSITIVE + NEGATIVE grep per site + optional jest run; exits non-zero on any FAIL).

---

## Horizontal Scalability Validation (v2 — MANDATORY)

**N/A — front-end (Nuxt SPA) change only.** No JVM/in-memory state, no DB connection usage, no `@Scheduled` job, no transaction, no request affinity, no cross-replica lock, no cache, no external notification is added or modified. The change is client-side render text in a stateless SPA served to the browser; the 10-row backend concurrency matrix does not apply.

---

## v2-Only Constraint Checklist

| Constraint | Applies? | Rationale |
|---|:---:|---|
| `@Transactional(tenantTransactionManager)` on tenant writes | **N/A** | no backend write |
| Tenant context across async boundaries | **N/A** | no server code |
| Optimistic-lock retry expansion | **N/A** | no entity write |
| Native-SQL / JPQL change → Testcontainers IT | **N/A** | query untouched |
| Caffeine / Redis cache eviction | **N/A** | no cache |
| OMS/printer notification deferred to after-commit | **N/A** | no notification |
| Flyway migration | **N/A** | no schema change |

All rows N/A: this is a `wms2-mobile-ui` (front-end) change, not a `wms2-api` change.

---

## Completeness Checklist

| # | Item | Status |
|---|------|:------:|
| 1 | §0 affected-sites enumeration (3 sites + helper + mapping) | ✅ |
| 2 | §1 problem statement + corrected premise + DB evidence (`db_verified:true`) | ✅ |
| 3 | §2 root cause (RC1-RC3) | ✅ |
| 4 | §3 regression chain marked N/A with rationale | ✅ |
| 5 | §4 data-flow diagram + Key Files table | ✅ |
| 6 | §5 Before/After per site + shared helper | ✅ |
| 7 | §6 file-change summary | ✅ |
| 8 | §7 prerequisites (all N/A w/ rationale) + checklist | ✅ |
| 9 | §8 AC + unit test + jest command + manual table | ✅ |
| 10 | §9 risks + acceptance script path | ✅ |
| 11 | Horizontal Scalability = N/A w/ rationale | ✅ |
| 12 | v2-only constraint checklist = N/A w/ rationale | ✅ |
| 13 | §10 ADR + 3 resolved decisions + v1 follow-up | ✅ |
| 14 | Verify script authored + referenced | ✅ |

---

## 10. Open Questions / Resolved Decisions

### Resolved Decisions (locked by user)
- **D1 — Scope:** mobile-UI **message only**. No backend cancel change, no cron change. (Root cause is a misleading message, not a reservation leak — see §1.)
- **D2 — Behavior:** show a clear, branch-aware "not replenishable / no replenishable stock" message; never emit "location: 0" / "x 0 items". Passive taps are no longer framed as a failed operation (`$toast.error`→`$toast.info`).
- **D3 — Delivery:** single PR against `v2/wms2-mobile-ui` (one helper module + 3 sites + 1 unit test).
- **D4 — Chip copy (Critic option a):** the two chips use a **terse** `heldUpChipMessage` short form, not the full toast sentence, because the small `text-caption` `v-chip` (`width:100%`, low height, previously carried a literal `<br/>`) has a tighter space budget than the toast. The full sentence stays on the tap toast where there is room.
- **D5 — Chip severity:** chip color moves from hard-coded `error` (red) to state-bound `:color="qty > 0 ? 'warning' : 'grey'"`, consistent with the softened `error`→`info` toast and Principle 1 (a non-actionable held-up row is not an error).
- **D6 — Helper location precedent:** `util/replenishMessages.js` follows the existing `util/replenishUnitLoads.js` pattern (imported via `~/util/…` in `selectSource.vue:87` / `selectUnitLoad.vue:116`), so the file placement and import shape are already idiomatic in this component tree.

### Open Questions
- **OQ1** (optional enrichment, non-blocking): the summary DTO also exposes `qtyOnReplenishableLocation` / `replenishableLocationNames`, **not** currently mapped into the mobile held-up row. Should the qty>0 message additionally hint where replenishable stock *does* exist? Deferred — out of scope for this fix; capture only if product wants it.
- **OQ2** (copy wording): the exact prose in §5.0 is a proposal; product may want to tune wording. Constraints (no "location: 0", no "x 0 items") are non-negotiable; the words around them are flexible.

### Cross-version — paired v1 follow-up
Identical defect and files exist in **v1**:
- `v1/wms-mobile-ui/pages/replenish.vue:217` (toast)
- `v1/wms-mobile-ui/components/replenish/process/AllReplenList.vue:119` (chip)
- `v1/wms-mobile-ui/components/replenish/process/HeldUpList.vue:68` (chip)

This plan is **v2-only**. A paired v1 plan should reuse the **same base filename** in `sbdocs/1-Projects/wms1/plan/` (`SBDEV-2070-replenish-heldup-unreachable-message-fix.md`) and can cherry-pick the helper + edits once v2 lands (per the Lane-A UI-sweep convention).

---

## 11. RALPLAN-DR Summary (for Architect / Critic review)

**Mode:** SHORT (low-risk, UI-copy-only; not `--deliberate`).

**Principles**
1. Fix the *message*, not the (already-correct) backend — smallest change that removes the user-visible defect.
2. One source of truth for the copy (a pure helper) so three duplicated strings cannot re-drift.
3. Preserve every existing guard/branch condition byte-for-byte; change only rendered text.
4. Undefined-/zero-safe by construction (never emit "location: 0", "x 0 items", "x undefined items").
5. Testable + machine-verifiable (unit test on the pure helper + grep-based verify script).

**Decision Drivers (top 3)**
1. Client trust — the misleading "Unable to Perform / location: 0" copy must stop.
2. Blast radius — scope locked to mobile-UI text; zero backend risk.
3. Maintainability — de-duplicate the copy so the fix holds.

**Viable Options**
- **Option A (chosen): shared pure helper module (toast full-form + chip terse-form) + method wrappers, `$toast.info`, chip color state-bound.** Pros: single source of truth, unit-testable, undefined-safe, verify-script-friendly, surface-appropriate copy, severity consistent with the softened toast. Cons: one new file with two exports + a method wrapper per component (templates can't call bare imports).
- **Option B: inline the branch expression at each of the 3 sites (no helper).** Pros: no new file. Cons: re-duplicates logic across 3 sites (the RC3 failure mode), not unit-testable, high re-drift risk. **Rejected** — violates Principle 2.
- **Option C (superset, deferred): Option A + map `qtyOnReplenishableLocation`/names and enrich the qty>0 message.** Pros: richer guidance. Cons: expands scope beyond the locked D1 decision, needs product sign-off. **Deferred to OQ1**, not this PR.

### Recommended OMC Composition
| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Trivial** | 3 mechanical text sites + 1 helper + 1 test, single file area |
| Pre-draft | analyst+planner (done, ralplan) | consensus loop |
| Plan-review | **critic** | consensus gate before coding |
| Implementation shape | **executor** (one agent) | trivial, verify script is comprehensive |
| Verification | **verify-script + verifier** | mandatory |
| Code-review | code-reviewer (light) | small diff |
| Commit | git directly | single logical commit |

---

## 12. Implementation Status

**Status: IMPLEMENTED — 2026-07-19.** Committed `3d9db31` on branch `tasks/SBDEV-2070-replenish-heldup-message` → **wms2-mobile-ui PR [#20](https://github.com/SiteBossInc/wms2-mobile-ui/pull/20)** (open, → `develop`). Code-review APPROVE (0 Crit/High/Med; Low follow-ups on the qty>0-missing-names branch applied → jest 8→10). Pending: full authenticated mobile manual smoke (needs running app + tenant); paired v1 follow-up.

### Changes (v2/wms2-mobile-ui — working tree, uncommitted)
| File | Change |
|---|---|
| `util/replenishMessages.js` | **NEW** — `heldUpReplenMessage(item)` (full toast) + `heldUpChipMessage(item)` (terse chip); branch-aware on `qtyOnNonReplenishableLocation`, undefined/0-safe. Default export = `heldUpReplenMessage`. |
| `pages/replenish.vue` | Import `heldUpReplenMessage`; `selectOrder` else-branch toast `error`→`info(heldUpReplenMessage(item))` (guard + `setOrder(null)` unchanged). |
| `components/replenish/process/AllReplenList.vue` | Import `heldUpChipMessage` + `heldUpChip(item)` method; chip text → `{{ heldUpChip(item) }}`; color `error` → `:color="qty>0 ? 'warning' : 'grey'"`; guard `v-if="(!item.source)"` unchanged. |
| `components/replenish/process/HeldUpList.vue` | Same as AllReplenList; guard `v-if="(!item.roSourceName)"` unchanged. |
| `test/util/replenishMessages.spec.js` | **NEW** — 10 tests, both exports, undefined/0-safety + qty>0-missing-names (code-review follow-up). |

### Verification
- **TDD gate**: `node_modules/.bin/jest --testPathPattern=replenishMessages` → **10 pass, 0 fail** (via nvm node v24.15.0; `yarn` not on PATH).
- **Verify script**: `bash sbdocs/9-System/scripts/verify-SBDEV-2070-replenish-heldup-unreachable-message-fix.sh` → **Result: 27 pass, 0 fail, 0 skip**.
- No backend/cron change (scope honored). No ESLint/lint script in repo. `CLAUDE.md` "No test suite" note is stale (jest harness runs fine).

### Remaining
- Manual mobile smoke (§8 table): tap held-up row at `qty=0` (no "location: 0") and `qty>0` (names + move guidance); confirm chips wrap cleanly at ~320px; confirm a `roId`-set row still opens into the source step; confirm `$toast.info` renders.
- ~~Commit + PR~~ — DONE: `3d9db31` → PR [#20](https://github.com/SiteBossInc/wms2-mobile-ui/pull/20) (open, → develop).
- Paired **v1** follow-up (`v1/wms-mobile-ui` — identical files) tracked in §10.
