---
title: "SBDEV-2486 — Club Lane Screen Goes Blank After Split + Quantity Adjust (v1)"
ticket: SBDEV-2486
ticket_url: https://app.clickup.com/t/9006034209/SBDEV-2486
type: bugfix
priority: urgent
status: implemented
project: [wms1]
version: v1
requester: Brent Campbell
created: 2026-06-24
updated: 2026-06-24
status_history: "draft → reviewed (architect + critic APPROVE) → implemented (PRs wms-api#179, wms-web-ui#65 → develop), 2026-06-24"
db_verified: false
related: []
tags:
  - plan
  - bugfix
  - club
  - move-stock
  - wms1
---

# SBDEV-2486 — Club Lane Screen Goes Blank After Split + Quantity Adjust (v1)

**Ticket:** [SBDEV-2486](https://app.clickup.com/t/9006034209/SBDEV-2486)
**Project:** wms1 | **Version:** v1 | **Type:** bugfix
**Priority:** urgent
**Status:** implemented (PRs: wms-api#179, wms-web-ui#65 → `develop`)
**Date:** 2026-06-24

---

## 0. Affected Sites

> Every **in-scope** row below MUST be addressed in §3 (Fix Design) and mapped to at least one check in the companion verify script `verify-SBDEV-2486-club-lane-blank-screen-split-adjust.sh`.

### Backend — `v1/wms-api` `CustomerorderBatchService.java`

| # | Severity | Disposition | Line(s) | Method | Defect |
|---|----------|-------------|---------|--------|--------|
| **B1** | HIGH | **IN-SCOPE** | 1198–1199 | `getClubLineSKUOverview` | `itemdataRepository.findById(...).orElse(null)` then immediate deref `itemData.getHandlingunitId()` (NPE if null); `itemunitRepository.findById(...).orElse(null).getUnitname()` (NPE if itemunit missing). Runs on **every** refresh via `POST /skus`. A raw NPE here → global handler → **HTTP 500**. |
| **B2** | **HIGH** | **IN-SCOPE** | 1166–1167 | `calc()` | (a) **[load-bearing]** `itemData.equals(itemDataMap.get(su.getItemdataId()))` — reference equality on `Itemdata` (violates v1 rule) → **silently wrong sums** (genuine data-correctness bug, independent of any null); (b) **[defensive only]** `su.getAmount().intValue()` would NPE if amount were null — but `stockunit.amount` is NOT NULL (DB-disproven, §1), so this is belt-and-suspenders, not a live defect. |
| **B3** | MEDIUM | **IN-SCOPE** | 1244–1245 | `getCustomerorderBatchDetails` | `clientRepository.findById(...).orElse(null)` then `client.getClNr()` / `client.getName()` deref (NPE if client missing). Backs the details endpoint F2 newly calls. |
| **B4** | LOW (cheap) | **IN-SCOPE** | 832 | `getClubLineUnitLoads` SKU filter | `skuFilter.equals(itemDataMap.get(pos.getItemdataId()).getName())` — unguarded `.get().getName()` (NPE if map miss). |
| **B5** | — | **EXCLUDED (dead code)** | 1069, 1117–1139 | `initializeCaches`, `calculateAmount` | `stockUnit.getAmount().intValue()` (1133) NPEs if null — **but both methods are dead.** `initializeCaches()` has **zero callers**; `calculateAmount()` is only called by its own recursion (line 1125), never from a live path. The live amount path is `calculateUnitLoadAmounts → calc()`. See §2 / §10. |
| **B6** | — | **EXCLUDED (DB-disproven)** | 1023 | `buildDtoList` | `itemUnitMap.get(itemData.getHandlingunitId()).getUnitname()`. DB check: `itemdata.handlingunit_id` is NOT NULL (8776/8776 rows, 0 orphans vs `itemunit`); `itemUnitMap` is built from those same rows (881–889). See §1 + §2. |
| **B7** | — | **EXCLUDED (already guarded)** | 1024 | `buildDtoList` | `locationMap.get(unitLoad.getStoragelocationId()).getName()` — already guarded by `containsKey` at line 1011 (the `continue` skips any UL whose location is absent). |

### Frontend — `v1/wms-web-ui`

| # | Severity | Disposition | File / Line(s) | Defect |
|---|----------|-------------|----------------|--------|
| **F1** | PRIMARY | **IN-SCOPE** | `store/processes/clubRuns.js` 212–227 / 231–246 / 250–266 | `getInventoryOnLane`, `getAvailableInventory`, `getParcelsClubBatch`: each `catch` block omits the `setXLoading(false)` reset. On a rejected request (422/404/500) the spinner never clears → "Loading…" forever = blank. |
| **F2** | HIGH | **IN-SCOPE** | `components/processes/clubRuns/clubRunDetails.vue` 104, 110, 116, 121–135; `pages/processes/club-fulfillment.vue` (whole) | `initialize()` and the tab watcher deref `this.clubRunDetails.id`. `clubRunDetails` is persisted Vuex state; on a hard refresh with cleared/absent persisted state it is `null` → `mounted()→initialize()` throws → blank. The page mounts the component unconditionally and fetches nothing. |
| **F3** | LOW (defense, effectively unreachable) | **IN-SCOPE** | `inventoryOnLaneTable.vue` 154–158, `availableInventory.vue` 147–151, `parcelsClubBatchTable.vue` 81–85, `itemsTable.vue` 116–120 | Computed `hasKey.map(...)` runs whenever the state value is truthy; a non-array body would crash. The store's `!results.errors` guards mean a non-array never actually reaches state — so this is **defensive hardening, not a live firing path**. |
| **F4** | LOW | **IN-SCOPE** | `store/processes/clubRuns.js` 198–208 | `getItemInfo` catch surfaces a toast but never resets `itemInfo`; on a rejected `/skus` the success commit (line 203) is never reached, so `itemInfo` keeps its **stale prior value** and `itemsTable` renders stale rows. |

---

## 1. Problem Statement

> **⚠️ `db_verified: false` — PARTIAL DB VERIFICATION. READ BEFORE STARTING.**
> **Two hypotheses already disproven against the v1 dev DB `wh01_om1`** (schema NOT-NULL constraints are repo-wide via Flyway, so they hold for UAT too):
> - **B6 disproven:** `itemdata.handlingunit_id` is NOT NULL (8776 rows, 0 null, 0 orphans vs `itemunit`) → `buildDtoList:1023` and B1's itemunit deref cannot NPE on referentially-integral data.
> - **B2 null-amount disproven:** `stockunit.amount` is NOT NULL (1,620,871 rows, 0 null) → `calc()`'s `su.getAmount().intValue()` cannot NPE on integral data. **B2's real defect is therefore the reference-equality wrong-sum bug only** (the null-amount guard is belt-and-suspenders).
>
> **Implication for the RCA:** under normal referential integrity, *none* of the enumerated backend NPE sites (B1/B2/B3/B4/B6) are reachable. The most coherent path to a real backend 500 is the ticket's own clue — the reporter **"manually created/adjusted inventory"** as a workaround, and out-of-band DB edits can leave orphaned/inconsistent rows (e.g. a stockunit pointing at a removed itemdata) that bypass FK integrity and trip these sites. The frontend fixes (F1 spinner reset, F2 null-`clubRunDetails` guard) satisfy the "clear error not blank" AC **regardless** of whether any backend site fires, which is why they are the robust half of the fix.
>
> The **UAT tenant DB was unreachable this session**, so before writing code the implementer MUST run these checks against the **affected UAT tenant DB**:
> 1. **Orphaned / inconsistent rows from the manual workaround (highest value):** confirm whether the affected lane has a stockunit whose `itemdata_id` has no `itemdata` row, or whose `itemdata.handlingunit_id` has no `itemunit` row — i.e. the out-of-band inconsistency that makes B1 reachable. Example: `SELECT su.id, su.itemdata_id FROM stockunit su LEFT JOIN itemdata i ON i.id = su.itemdata_id WHERE su.storagelocation_id = <lane> AND i.id IS NULL;`
> 2. **Capture the firing error:** from the screen recording / a fresh repro, capture (a) the **server stack trace + HTTP status** and (b) the **browser console / network status** at the moment the screen blanks. This pins whether it is a backend 500 (B1) or the frontend null-`clubRunDetails` path (F2/H2).
> 3. **Missing-batch behavior of the details endpoint** (verified in code, confirm in UAT): `GET /customerOrderBatch/customerorderBatchDetailsById/{id}` has **no local try/catch** (`CustomerOrderBatchController.java:91–95`) and `throws BusinessException`; on a missing batch → global handler → **HTTP 422 `{errors}`** → axios **rejects**. This is why F2's mount fetch MUST be wrapped in try/catch (§3.6). Confirm the 422 shape against UAT.
> Record the results in §6 (Manual test plan) before flipping `db_verified: true`. **Note:** because the fix is defensive + frontend-resilient, it is correct and shippable independent of this pre-work; the pre-work confirms *which* path produced the reported incident, not whether the fix is valid.

**SBDEV-2486 (urgent, tagged wmsv1 + wmsv2).** "Club Lane Screen Goes Blank After Splitting Unit Load and Adjusting Quantity."

**Environment:** WMS **V1 UAT**, Club Processing → Club Lanes → Unit Loads (the `/processes/club-fulfillment` screen).
**Reporter:** Brent Campbell.

**Reproduction:**
1. Open an active club run → open its detail (`/processes/club-fulfillment`).
2. Split a unit load on the lane.
3. Keep the split unit load on the lane.
4. Adjust the quantity.
5. Hard-refresh the screen (F5).
6. **The lane renders blank.**

**DB disproof of the sub-agent's leading hypothesis (B6).** Against v1 dev DB `wh01_om1`: `itemdata.handlingunit_id` is **NOT NULL** (8776 rows, 0 null, 0 orphans vs `itemunit`). The B6 deref at `buildDtoList:1023` therefore cannot NPE — `itemUnitMap` is built from those exact `itemdata` rows (`CustomerorderBatchService.java:881–889`) and the FK is enforced. B6 is **excluded** (optional one-line guard only; see §3). Because UAT was unreachable, `db_verified` stays **false** and the manual checks above are mandatory pre-work.

---

## 2. Root Cause Analysis

### 2.0 The blank-screen mechanism (and the actual HTTP contract)

A global `@ControllerAdvice` (`RestExceptionHandler.java:120–182`) is the authority for any exception that escapes a controller's local try/catch. Verified mappings (all return a `{errors:[...]}` body):

| Exception | HTTP status (global handler) |
|-----------|------------------------------|
| `BusinessException` | **422** Unprocessable Entity |
| `FacadeException` | **422** |
| `NoSuchElementException` (unguarded `Optional.get()`) | **404** |
| `NullPointerException` | **500** |

The two club endpoints differ in whether they ALSO catch locally:

- **`POST /v3/clubLine/skus`** (`ClubLineController.java:270–275`) has **NO local try/catch** — it just `throws BusinessException` and returns the list. So: success → 200 array; a `BusinessException` from `getClubLineSKUOverview` → **422**; a `NoSuchElementException` → **404**; a **raw NPE → 500**. (Today, B1's `.orElse(null)` derefs throw a raw NPE → **500**.)
- **`POST /v3/clubLine/unitLoads`** (`ClubLineController.java:287–301`) **does** catch `BusinessException` locally → returns **HTTP 200** with `{errors:[...]}`. **But a raw NPE still escapes that local catch** → global handler → **500**. (B2's `su.getAmount().intValue()` would NPE here — but `stockunit.amount` is **NOT NULL** (DB-disproven, §1), so this path is unreachable on integral data; it becomes reachable only via the manual-inventory workaround leaving an inconsistent row.)

**Why the screen goes blank (not just an empty table):**
1. A backend call **rejects** (422 from B1's BusinessException form, 404, or — critically — a raw **500** from a B1/B2 NPE; axios rejects on all non-2xx, and `axios-retry` only retries 401/403).
2. The store action's `catch` block (F1) **never resets the loading flag** → `setXLoading(true)` is never set back to `false` → the component shows "Loading… Please wait" forever → **blank**.

So the bug is a two-layer failure: a **backend raw-NPE 500** (B1/B2) or any rejection, plus a **frontend catch that forgets to reset loading** (F1), which converts the rejection into a permanent blank. The AC ("clear error message instead of a blank screen") is satisfied at the frontend layer (F1/F2); the backend fixes (B1/B3/B4) additionally **downgrade raw 500s to structured 422/404** (better diagnostics + a populated `{errors}` body), and **B2 additionally fixes a genuine data-correctness defect**.

> v1 entity rules in play: only `Location` defines `equals`/`hashCode` (broken); `Itemdata` uses `Object.equals` (reference equality); OSIV is disabled (no shared persistence context across repo calls); Mockito is 3.3.3 (no `mockStatic`).

### 2.1 Hypotheses (confidence-scored)

> **Confidences updated after a second DB disproof (see §1).** With `itemdata.handlingunit_id` and `stockunit.amount` both NOT NULL (repo-wide), the backend NPE sites are unreachable on referentially-integral data — so H1 is only viable via the ticket's manual-inventory workaround creating out-of-band orphaned rows. That pushes weight onto the frontend path (H2).

| ID | Confidence | Hypothesis |
|----|-----------|------------|
| **H1** | **MEDIUM ~40%** | A backend NPE on refresh produces a 500 — but only if the manual inventory workaround left an **orphaned/inconsistent row** (e.g. a stockunit whose itemdata was removed), since schema NOT-NULL + FK integrity otherwise make B1's `.orElse(null)` derefs unreachable (B2's null-amount path is schema-disproven). Then `POST /skus` (B1) → raw NPE → 500, F1 leaves the spinner stuck → blank. |
| **H2** | **MEDIUM-HIGH ~45%** | Persisted `clubRunDetails` is `null` after a hard refresh (cleared/absent `vuex-persistedstate`, deep link, or a rehydration-vs-mount race). `clubRunDetails.vue` `initialize()` then derefs `this.clubRunDetails.id` (line 131) → JS throw in `mounted()` → component never renders = blank. (F2.) Most plausible cause on referentially-integral data. |
| **H3** | **LOW ~10%** | A non-array response body reaching a tab table's `hasKey.map(...)` would crash the render — but the store's `!results.errors` guards mean state is only ever set to a resolved array, so this is **not a live firing path**. F3 is defensive hardening only. |
| **H4** | **LOW ~5%** | The lane is legitimately empty after the adjust (no inventory) and the UI is simply showing nothing distinguishable from "blank". |

Defense-in-depth (B1–B4 backend + F1–F4 frontend) covers both live hypotheses (H1 backend-via-corruption, H2 frontend) and hardens against H3, which is why the plan addresses both layers rather than betting on a single RCA before the UAT trace is captured. The exact firing path is pinned by the §1 pre-work (orphaned-row query + stack-trace capture); the fix is correct either way.

### 2.2 B1 — `getClubLineSKUOverview` double unguarded deref (HIGH)

`CustomerorderBatchService.java:1196–1220`. Per position:
```java
Itemdata itemData = itemdataRepository.findById(position.getItemdataId()).orElse(null);
String unitName = itemunitRepository.findById(itemData.getHandlingunitId()).orElse(null).getUnitname();
```
Two raw NPEs: (a) `itemData.getHandlingunitId()` when `itemData` is null; (b) `.orElse(null).getUnitname()` when the `itemunit` lookup is empty. Neither is wrapped — both escape as a raw `NullPointerException`. `POST /skus` has no local catch → global handler → **HTTP 500**. This endpoint runs on **every** refresh (`getItemInfo`), making it the most probable 500 source.

### 2.3 B2 — `calc()` reference equality (wrong sums) + null amount (HIGH)

`CustomerorderBatchService.java:1164–1168`:
```java
int stockSum = stockUnits.stream()
    .filter(su -> itemData.equals(itemDataMap.get(su.getItemdataId())))
    .mapToInt(su -> su.getAmount().intValue())
    .sum();
```
- **Data-correctness bug (always-on, not cosmetic):** `itemData.equals(...)` is `Object.equals` on `Itemdata` (reference equality). With OSIV disabled, `itemData` (passed down from `buildDtoList`) and `itemDataMap.get(...)` (re-fetched inside `calc`) are **different object instances** for the same row → the filter can silently drop matching stockunits → **wrong (under-counted) sums** on the lane. This is a genuine defect no frontend fix can address — hence B2 is **HIGH** and the one always-required backend change.
- **Null amount (DB-disproven — defensive only):** `su.getAmount().intValue()` would raw-NPE if a stockunit's `amount` were null. However, `stockunit.amount` is **NOT NULL** (1,620,871 rows, 0 null — §1), so this cannot fire on referentially-integral data; the guard is belt-and-suspenders that only matters if the manual-inventory workaround inserted an out-of-band row. **B2's load-bearing fix is the reference-equality wrong-sum correction above, not this guard.**

### 2.4 B3 — `getCustomerorderBatchDetails` client deref (MEDIUM)

`CustomerorderBatchService.java:1243–1247`:
```java
Client client = clientRepository.findById(cob.getClientId()).orElse(null);
details.put("clientNumber", client.getClNr());
details.put("clientName", client.getName());
```
`.orElse(null)` then immediate deref → raw NPE if the client row is missing → global handler → **500**. This method backs `getClubRunFullDetails` (GET `/customerOrderBatch/customerorderBatchDetailsById/{id}`), which F2 will newly call on mount — so it must not 500.

### 2.5 B4 — SKU filter predicate unguarded map lookup (LOW, cheap)

`CustomerorderBatchService.java:830–834`:
```java
positions = positions.stream()
    .filter(pos -> skuFilter.equals(itemDataMap.get(pos.getItemdataId()).getName()))
    .collect(Collectors.toList());
```
`itemDataMap.get(...)` can miss → `.getName()` raw NPE → 500. Only fires when `skuFilter != null`, but a one-line null-guard removes the risk cheaply.

### 2.6 B5 — dead code (EXCLUDED)

`grep` confirms: `initializeCaches()` (1069) has **no callers**; `calculateAmount()` (1117) is referenced **only by its own recursion** at line 1125. The live amount computation path is `calculateUnitLoadAmounts (1040) → calc() (1142)`, which does **not** call either. The `stockUnit.getAmount().intValue()` NPE at line 1133 is therefore unreachable in production. **Excluded** — guarding dead code adds risk without benefit. (Recommend a separate tech-debt ticket to delete `initializeCaches` / `calculateAmount` / the `resultCache`, `carrierToChildrenMap`, `unitLoadToStockMap`, `itemDataMap` fields they use.)

### 2.7 B6 / B7 — EXCLUDED

- **B6** (`buildDtoList:1023`): DB-disproven (see §1). Optional defensive guard only.
- **B7** (`buildDtoList:1024`): already protected by `if (!locationMap.containsKey(unitLoad.getStoragelocationId())) { continue; }` at line 1011. Excluded.

### 2.8 F1 — store catch blocks drop the loading reset (PRIMARY frontend)

`store/processes/clubRuns.js`. Pattern in all three actions:
```js
context.commit("setInventoryOnLaneLoading", true)
try {
  const results = await this.$axios.$post('/clubLine/unitLoads', data)
  if (!results.errors) { context.commit('setInventoryOnLane', results) }
  context.commit("setInventoryOnLaneLoading", false)   // ← only on success
} catch(error) {
  console.log(error)
  this.$toast.error('…')                                // ← loading NOT reset
}
```
On a rejected axios call (422/404/500) the `false` reset is skipped → permanent spinner = blank. Same defect in `getAvailableInventory` (231–246) and `getParcelsClubBatch` (250–266).

### 2.9 F2 — null `clubRunDetails` on hard refresh (HIGH frontend)

`clubRunDetails` is set only by the **list page** before navigation (`pages/processes/club-run.vue:247–250`: dispatch `getClubRunFullDetails(item.id)` → commit `setClubRunDetails` → `$router.push('/processes/club-fulfillment', { query: { orderBatchId: item.id, parcels } })`). It lives in **persisted** Vuex state. On a hard refresh / deep link / cleared persisted state, `clubRunDetails` is `null`:
- The template's `v-if="clubRunDetails"` hides the markup (blank), **and**
- `mounted() → initialize()` (line 126) still runs and derefs `this.clubRunDetails.id` (line 131) → JS `TypeError` → mount aborts.

The route query carries the **numeric** `orderBatchId` (`item.id`) — note `club-run.vue:250` sets `orderBatchId` **twice** (`item.batchId` then `item.id`); JS last-key-wins means `item.id` is what arrives, which is exactly what `getClubRunFullDetails(id)` expects. The store already has `getClubRunFullDetails(id)` + `setClubRunDetails` — so the component can self-heal. **Critical caveat:** `getClubRunFullDetails` (`clubRuns.js:187–194`) returns the `$get` promise **without awaiting it**, so its own internal `try/catch` cannot catch an async rejection. The details endpoint 422s on a missing batch (see §1 / §3.6). Therefore the component's `await dispatch(...)` MUST be wrapped in its own try/catch, or the rejection re-throws inside `initialize()`→`mounted()` and reproduces the blank.

### 2.10 F3 — `hasKey.map` on a non-array (LOW, defensive only)

The four tab computeds guard only truthiness (`if (hasKey)`), not array-ness. In principle a non-array (e.g. `{errors}`) would be truthy and `.map` would throw. In practice the store only commits state when `!results.errors` (inventory/available/parcels) or on a resolved array (`getItemInfo`), so a non-array never reaches state — **this is not a live firing path**. The `Array.isArray` guard is cheap defensive hardening; it does not, by itself, fix any observed blank.

### 2.11 F4 — `getItemInfo` leaves stale `itemInfo` (LOW)

`store/processes/clubRuns.js:198–208`: on a rejected `/skus` (e.g. B1's 500, or a 422 after the B1 fix) the success commit at line 203 (`context.commit('setItemInfo', results)`) is **never reached** (axios rejects; `axios-retry` only retries 401/403). So `itemInfo` retains its **stale prior value** and `itemsTable` renders stale rows from a previous batch. Reset to `[]` in the catch for consistency with F1. (Note: this is about stale prior rows, not an `{errors}` object reaching the table — the success commit never fires on rejection.)

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `v1/wms-api/.../service/CustomerorderBatchService.java` | 1198–1199 | B1 — unguarded itemdata/itemunit deref in `getClubLineSKUOverview` |
| 2 | `v1/wms-api/.../service/CustomerorderBatchService.java` | 1166–1167 | B2 — reference equality (wrong sums) + null amount in `calc()` |
| 3 | `v1/wms-api/.../service/CustomerorderBatchService.java` | 1244–1245 | B3 — client deref in `getCustomerorderBatchDetails` |
| 4 | `v1/wms-api/.../service/CustomerorderBatchService.java` | 832 | B4 — SKU filter map-lookup deref |
| 5 | `v1/wms-web-ui/store/processes/clubRuns.js` | 212–266 | F1 — three catch blocks miss the loading reset |
| 6 | `v1/wms-web-ui/components/processes/clubRuns/clubRunDetails.vue` | 104–135 | F2 — null `clubRunDetails.id` deref on refresh |
| 7 | `v1/wms-web-ui/pages/processes/club-fulfillment.vue` | whole | F2 — page fetches nothing on mount |
| 8 | `v1/wms-web-ui/components/processes/clubRuns/tabTables/inventoryOnLaneTable.vue` | 154–158 | F3 — `hasKey.map` non-array guard (defensive) |
| 9 | `v1/wms-web-ui/components/processes/clubRuns/tabTables/availableInventory.vue` | 147–151 | F3 — same |
| 10 | `v1/wms-web-ui/components/processes/clubRuns/tabTables/parcelsClubBatchTable.vue` | 81–85 | F3 — same |
| 11 | `v1/wms-web-ui/components/processes/clubRuns/itemsTable.vue` | 116–120 | F3 — same |
| 12 | `v1/wms-web-ui/store/processes/clubRuns.js` | 198–208 | F4 — `getItemInfo` reset `itemInfo` on error (stale prior rows) |

---

## 3. Design / Proposed Fix

> Minimal-diff, faithful to the real code. Backend prefers `BusinessException` over raw NPE so a failure becomes a **structured 422 `{errors}`** (handled by the frontend catch + a populated error body) rather than a raw **500** — and the missing-unit case stays a successful **200** with a blank unit name.

### 3.1 B1 — `getClubLineSKUOverview`: guard itemdata + itemunit

**File:** `CustomerorderBatchService.java:1197–1199`
```java
// Before:
positions.forEach(position -> {
    Itemdata itemData = itemdataRepository.findById(position.getItemdataId()).orElse(null);
    String unitName = itemunitRepository.findById(itemData.getHandlingunitId()).orElse(null).getUnitname();

// After:
for (CustomerorderPosition position : positions) {
    Itemdata itemData = itemdataRepository.findById(position.getItemdataId())
        .orElseThrow(() -> new BusinessException("Itemdata not found: " + position.getItemdataId()));
    String unitName = itemunitRepository.findById(itemData.getHandlingunitId())
        .map(Itemunit::getUnitname)
        .orElse(null);
```
> **Effect on the contract:** this converts a raw-NPE **500** into a structured **422 `{errors}`** (for the missing-itemdata case) that the frontend catch handles cleanly; the missing-itemunit case becomes a successful **200** with a blank (`null`) unit name — **not** a "200 graceful empty table". The `positions.forEach(...)` lambda cannot throw the checked `BusinessException`, so it MUST be **converted to an enhanced `for` loop**; `getClubLineSKUOverview` already declares `throws BusinessException`, so propagation is clean. Close the loop body with `}` (replacing the lambda's `});`).

### 3.2 B2 — `calc()`: compare by id, null-safe amount

**File:** `CustomerorderBatchService.java:1159–1168`
```java
// Before:
Map<Long, Itemdata> itemDataMap = itemDataIds.isEmpty() ? Collections.emptyMap() :
    StreamSupport.stream(itemdataRepository.findAllById(itemDataIds).spliterator(), false)
        .collect(Collectors.toMap(Itemdata::getId, Function.identity()));

int stockSum = stockUnits.stream()
    .filter(su -> itemData.equals(itemDataMap.get(su.getItemdataId())))
    .mapToInt(su -> su.getAmount().intValue())
    .sum();

// After:
int stockSum = stockUnits.stream()
    .filter(su -> itemData != null && itemData.getId().equals(su.getItemdataId()))
    .mapToInt(su -> su.getAmount() == null ? 0 : su.getAmount().intValue())
    .sum();
```
> Comparing `itemData.getId()` to `su.getItemdataId()` is the correct id-based identity check and makes the local `itemDataMap` (and its `findAllById` fetch + the `itemDataIds` set that fed only it) **redundant** — remove them in the same edit. Null amount is treated as 0. This fixes the wrong-sum data bug **and** removes the null-amount 500.
>
> **Null-receiver guard (required):** `itemData` is sourced from `buildDtoList:988` (`itemDataMap.get(position.getItemdataId())`), an unguarded map-get that can be null. The original `itemData.equals(...)` was null-safe (returns false); flipping the receiver to `itemData.getId()` would NPE on a null `itemData` — exactly the H1 manual-inventory-corruption path. The leading `itemData != null &&` preserves the original's null-tolerance.

### 3.3 B3 — `getCustomerorderBatchDetails`: guard client

**File:** `CustomerorderBatchService.java:1243–1247`
```java
// Before:
if (cob.getClientId() != null) {
    Client client = clientRepository.findById(cob.getClientId()).orElse(null);
    details.put("clientNumber", client.getClNr());
    details.put("clientName", client.getName());
}

// After:
if (cob.getClientId() != null) {
    clientRepository.findById(cob.getClientId()).ifPresent(client -> {
        details.put("clientNumber", client.getClNr());
        details.put("clientName", client.getName());
    });
}
```
> Missing client → the two keys are simply omitted (UI already tolerates absent `clientName`); no 500.

### 3.4 B4 — SKU filter predicate null-guard

**File:** `CustomerorderBatchService.java:830–834`
```java
// Before:
positions = positions.stream()
    .filter(pos -> skuFilter.equals(itemDataMap.get(pos.getItemdataId()).getName()))
    .collect(Collectors.toList());

// After:
positions = positions.stream()
    .filter(pos -> {
        Itemdata id = itemDataMap.get(pos.getItemdataId());
        return id != null && skuFilter.equals(id.getName());
    })
    .collect(Collectors.toList());
```

### 3.5 F1 — reset loading + toast in every catch

**File:** `store/processes/clubRuns.js` — `getInventoryOnLane` (212–227), `getAvailableInventory` (231–246), `getParcelsClubBatch` (250–266)
```js
// getInventoryOnLane — After (same shape for the other two with their own mutation name):
} catch (error) {
  console.log(error)
  context.commit('setInventoryOnLaneLoading', false)
  this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
}
```
> Mutation names per action (confirmed): `setInventoryOnLaneLoading`, `setAvailableInventoryLoading`, `setParcelsClubBatchLoading`.

### 3.6 F2 — self-heal `clubRunDetails` on mount (rejection-safe); guard null derefs

**File:** `components/processes/clubRuns/clubRunDetails.vue`

(a) Make `initialize()` `async`, fetch details when state is null **inside a try/catch**, and guard the commit:
```js
// initialize() — After:
async initialize() {
  const orderBatchId = parseInt(this.$route.query.orderBatchId)
  // Self-heal: a hard refresh / cleared persisted state leaves clubRunDetails null.
  // getClubRunFullDetails returns the $get promise WITHOUT awaiting, so its own
  // try/catch can't catch a 422/404/500 — wrap the await here.
  if (!this.clubRunDetails && !Number.isNaN(orderBatchId)) {
    try {
      const details = await this.$store.dispatch('processes/clubRuns/getClubRunFullDetails', orderBatchId)
      if (details && !details.errors && details.id) {
        this.$store.commit('processes/clubRuns/setClubRunDetails', details)
      }
    } catch (error) {
      console.log(error)
      this.$toast.error('Error: Unable to load club run details. Please return to Active Club Runs.')
    }
  }
  if (!this.clubRunDetails) {
    return // template v-if shows nothing; no further dispatch, no throw
  }
  this.$store.dispatch('processes/clubRuns/getItemInfo', { orderBatchId })
  this.tabSelected = 0
  this.$store.dispatch('processes/clubRuns/getInventoryOnLane', {
    orderBatchId: this.clubRunDetails.id,
    onlyStagingLocation: true,
    skuFilter: null,
  })
},
```
(b) Guard the tab watcher so it no longer derefs a null `clubRunDetails`:
```js
// watch.tabSelected — After (wrap the existing body):
tabSelected(newVal) {
  if (!this.clubRunDetails) return
  // ... existing newVal === 0 / 1 / 2 dispatches unchanged ...
},
```
> **Missing-batch behavior (verified):** `GET /customerOrderBatch/customerorderBatchDetailsById/{id}` (`CustomerOrderBatchController.java:91–95`) has **no local try/catch** and `throws BusinessException`; on a missing batch `getCustomerorderBatchDetails` throws `BusinessException("Order batch not found: " + id)` → global handler → **HTTP 422 `{errors}`** → axios **rejects**. The try/catch above absorbs that rejection, falls through to `if (!this.clubRunDetails) return`, shows a toast, and leaves a clean empty state — fully closing F2. The route query `orderBatchId` carries the **numeric id** (`item.id`, set at `club-run.vue:250`), which is exactly the argument `getClubRunFullDetails(id)` expects. Optionally add a `v-else` "Club run not found — return to Active Club Runs" block in the template for an explicit empty state (recommended, not required).

### 3.7 F3 — `Array.isArray` guard before `.map` (defensive hardening)

**Files:** `inventoryOnLaneTable.vue` (154–158), `availableInventory.vue` (147–151), `parcelsClubBatchTable.vue` (81–85), `itemsTable.vue` (116–120)
```js
// inventoryOnLaneTable.vue — After:
inventoryOnLane() {
  const hasKey = this.$store.state.processes.clubRuns.inventoryOnLane
  if (Array.isArray(hasKey)) {
    this.skuList = Array.from(new Set(hasKey.map(item => item.itemId)));
    return hasKey.map((item, key) => ({ ...item, key }))
  }
  return []
},
```
> `availableInventory` is identical (with `availableInventory` / `skuList`). `parcelClubBatch` and `itemInfo` use the simpler form: replace `if (hasKey)` with `if (Array.isArray(hasKey))`, keeping the `else return []`. This is defensive only — the store's `!results.errors` guards mean a non-array does not reach state today.

### 3.8 F4 — reset `itemInfo` on error

**File:** `store/processes/clubRuns.js:204–207`
```js
// getItemInfo — After:
} catch (error) {
  console.log(error)
  context.commit('setItemInfo', [])
  this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
}
```
> Clears stale prior rows on a rejected `/skus` (the success commit at line 203 never runs on rejection).

**Files changed:** `CustomerorderBatchService.java`; `store/processes/clubRuns.js`; `clubRunDetails.vue`; `club-fulfillment.vue` (no functional change required — F2 lives in the component; touch only if you add an empty-state passthrough); `inventoryOnLaneTable.vue`; `availableInventory.vue`; `parcelsClubBatchTable.vue`; `itemsTable.vue`.

---

## 4. V1/V2 Applicability

v2 has near-identical defects in the corresponding `CustomerorderBatchService` / club store and components. **v2 is deferred to a paired plan** (`SBDEV-2486-club-lane-blank-screen-split-adjust.md` under `sbdocs/1-Projects/wms2/plan/`, produced via `wms-v2-migrate`, sharing this base filename). This document is **v1-only**.

### Architecture flow (v1 blank-screen path)

```
Hard refresh of /processes/club-fulfillment?orderBatchId=<id>&parcels=<n>
  → club-fulfillment.vue mounts <club-run-details> unconditionally
    → clubRunDetails.vue mounted() → initialize()
        → (F2) clubRunDetails may be null after persisted-state loss → self-heal fetch
              → GET /customerOrderBatch/customerorderBatchDetailsById/{id}
                    → getCustomerorderBatchDetails (B3 client NPE → 500; missing batch → 422)
              → unwrapped await of this rejection would re-throw → blank (fixed by try/catch)
        → getItemInfo  → POST /v3/clubLine/skus  (no local catch)
              → getClubLineSKUOverview  (B1 raw NPE → 500; missing itemdata → 422 after fix)
        → getInventoryOnLane → POST /v3/clubLine/unitLoads (local BusinessException catch → 200+{errors})
              → calc() (B2 ref-equality wrong sums; null amount → raw NPE → 500)
              → buildDtoList (B6/B7 excluded)
    → tab watch / table computeds map state (F3 defensive only — guarded upstream)
  → on any rejection (422/404/500), store catch (F1) never resets *Loading → permanent spinner = blank
```

### Key Files

| File | Lines | Role |
|------|-------|------|
| `CustomerorderBatchService.java` | 1181–1224 | `getClubLineSKUOverview` — B1 (per-refresh `/skus`) |
| `CustomerorderBatchService.java` | 1142–1179 | `calc()` — B2 amount summation |
| `CustomerorderBatchService.java` | 1226–1256 | `getCustomerorderBatchDetails` — B3 |
| `CustomerorderBatchService.java` | 813–913 | `getClubLineUnitLoads` — B4 filter; calls `buildDtoList` |
| `ClubLineController.java` | 270–318 | `/skus` (no local catch → 422/404/500), `/unitLoads` (local catch → 200+{errors}, NPE still 500), `/parcels` |
| `CustomerOrderBatchController.java` | 91–95 | `customerorderBatchDetailsById` — no local catch, `throws BusinessException` (→ 422 on missing batch) |
| `RestExceptionHandler.java` | 120–182 | Global `@ControllerAdvice`: BusinessException→422, FacadeException→422, NoSuchElement→404, NPE→500 |
| `store/processes/clubRuns.js` | 187–266 | `getClubRunFullDetails` (187, unawaited $get), `getItemInfo` (F4), inventory/available/parcels actions (F1) |
| `clubRunDetails.vue` | 96–135 | computed/mount/watch — F2 |
| `club-fulfillment.vue` | whole | mounts the detail component |
| tab tables ×4 | computeds | F3 `hasKey.map` |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No migration. **Manual pre-work (see §1 flag):** UAT SQL checks for null `stockunit.amount` on the affected lane and itemunit integrity for the batch's SKUs. | Implementer | Gate for flipping `db_verified:true`. |
| 2 | **Feature flags / system properties** | N/A — no new sysprop / toggle. | — | Pure code-logic fix. |
| 3 | **Config / env changes** | N/A. | — | |
| 4 | **Deploy-order dependencies** | Ship **wms-api + wms-web-ui together.** Frontend tolerates both the old 500 and the new 422+`{errors}`, so ordering is not strictly required, but pairing is cleaner and avoids a window where only one layer is fixed. | Implementer | |
| 5 | **Data migration** | N/A. | — | |
| 6 | **External systems** | N/A. | — | No OMS/printer/keycloak interaction touched. |
| 7 | **Access / permissions** | N/A. | — | No new authority. |
| 8 | **Monitoring / alerts** | N/A (optional: watch for 500s on `/v3/clubLine/skus` and `/v3/clubLine/unitLoads` post-deploy — they should drop to zero / become 422s). | — | |
| 9 | **Capture the firing error** | Before coding, capture the server stack trace + HTTP status + browser network status from a fresh repro to confirm B1 vs B2 as the actual 500 site. | Implementer | |

### 5.2 Implementation Checklist

- [ ] **Pre-work:** run the §1 UAT DB checks; capture the firing error (status + stack + console); confirm the details-endpoint 422 on missing batch; record in §6; flip `db_verified` if confirmed. *(Deferred to QA on UAT — fix is defensive + frontend-resilient and correct independent of this pre-work; see §1.)*
- [x] B1 — guard itemdata/itemunit in `getClubLineSKUOverview` (convert `forEach`→`for`; itemunit null-safe `.map`). *(`CustomerorderBatchService.java:1191–1219`)*
- [x] B2 — id-based filter + null-safe amount in `calc()`; remove redundant `itemDataMap`/`itemDataIds`/`findAllById`. *(`:1158–1164`, incl. `itemData != null` guard)*
- [x] B3 — `ifPresent` client guard in `getCustomerorderBatchDetails`. *(`:1243–1246`)*
- [x] B4 — null-guard SKU filter predicate. *(`:831–836`)*
- [x] F1 — loading reset + toast in all three store catch blocks. *(`clubRuns.js:225/246/266`)*
- [x] F2 — `async initialize()` with try/catch + `details && !details.errors && details.id` guard + null-guard tab watcher. *(`clubRunDetails.vue:101,127–149`)*
- [x] F3 — `Array.isArray` guard in all four tab computeds.
- [x] F4 — reset `itemInfo` on error. *(`clubRuns.js:206`)*
- [x] Backend unit tests added (`CustomerorderBatchServiceUnitTest`) — 4 methods, all pass.
- [ ] Backend integration test added (Testcontainers). *(Deferred — v1 `@SpringBootTest` ITs currently blocked by the `ro_id` replenishment-view drift, SBDEV-2384; `ClubLineControllerIT` to be added once the view is fixed.)*
- [x] Frontend Jest tests added (store F1 + `clubRunDetails.vue` F2) — 2 suites, 4 tests pass.
- [x] `bash sbdocs/9-System/scripts/verify-SBDEV-2486-club-lane-blank-screen-split-adjust.sh` → **26 pass, 0 fail, 2 skip**.
- [x] Code review completed — code-reviewer (opus): **APPROVE**, 0 medium/high findings.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| B1 itemunit empty | `getClubLineSKUOverview` for a position whose `itemunit` lookup returns empty | No NPE; DTO returned with blank (`null`) unit name; HTTP **200** |
| B1 itemdata missing | position points to a missing itemdata | `BusinessException` → **422** (not raw 500/NPE) |
| B2 null amount | `calc()`/`getClubLineUnitLoads` with a stockunit whose `amount` is null | No NPE; amount treated as 0 |
| B2 identity (wrong sums) | same logical itemdata loaded as two distinct instances (OSIV-off) | Sum **includes** the matching stockunit (id-based filter) — locks the data-correctness fix |
| B3 missing client | `getCustomerorderBatchDetails` for batch whose client row is absent | No NPE; `clientName`/`clientNumber` omitted; HTTP 200 |
| Controller resilience | `POST /clubLine/unitLoads` and `/skus` after simulated split (extra UL + adjusted/null-amount stockunit) | `/unitLoads` → **200** (array or `{errors}`); `/skus` → **200** on success, **422** on missing-itemdata `BusinessException`; **never a raw 500** |
| F1 spinner reset | rejected axios on `getInventoryOnLane` | `setInventoryOnLaneLoading(false)` committed + toast |
| F2 null details + 422 | mount `clubRunDetails.vue` with `clubRunDetails=null` + route `orderBatchId`, details endpoint rejects (422) | No throw; toast shown; clean empty state; not blank |
| F3 non-array (defensive) | tab computed with non-array state | returns `[]`, no crash |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `CustomerorderBatchServiceUnitTest` | `getClubLineSKUOverview_ItemunitMissing_NoNpe_BlankUnit_Returns` | itemunit empty → DTO with null/blank unit, no NPE |
| `CustomerorderBatchServiceUnitTest` | `getClubLineSKUOverview_ItemdataMissing_ThrowsBusinessException` | missing itemdata → `BusinessException` (→422), not raw NPE |
| `CustomerorderBatchServiceUnitTest` | `getClubLineUnitLoads_NullStockAmount_TreatedAsZero` | null amount → no NPE, summed as 0 |
| `CustomerorderBatchServiceUnitTest` | `getClubLineUnitLoads_SameItemdataDifferentRefs_SumsByIdentity` | two distinct `Itemdata` instances, same id → stockunit still summed (locks B2 wrong-sum fix) |
| `CustomerorderBatchServiceUnitTest` | `getCustomerorderBatchDetails_MissingClient_NoNpe` | missing client → keys omitted, no NPE |
| `ClubLineControllerIT` (Testcontainers PG) | `unitLoads200_skus200or422_neverRaw500_afterSplit` | after simulated split: `/unitLoads`→200 (array or `{errors}`); `/skus`→200 on success / 422 on missing-itemdata; never raw 500 |
| `clubRuns.store.spec.js` | `getInventoryOnLane rejected → resets loading + toast` | commits `setInventoryOnLaneLoading(false)` (same for Available/Parcels) |
| `clubRunDetails.spec.js` | `null clubRunDetails + details rejects (422) → no throw, empty state` | `await` rejection caught; no exception escapes `initialize()` |
| `inventoryOnLaneTable.spec.js` | `non-array state → []` | computed returns `[]` (defensive) |

> Mockito 3.3.3: use instance mocks (`@Mock` repositories) and set `SecurityContextHolder` directly where username is needed; **no `mockStatic`**.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Repro happy-path | UAT | active club run → detail → split UL on lane → keep on lane → adjust qty → F5 | Lane renders rows OR clear empty/error state; **never blank / stuck spinner** | |
| Deep-link / cleared state | UAT | clear localStorage → deep-link the `/processes/club-fulfillment?orderBatchId=<id>` URL | Details self-fetch; on success renders, on 422 shows toast + empty state; no blank | |
| SQL sanity (null amount) | UAT DB | `SELECT id, unitload_id, amount FROM stockunit WHERE storagelocation_id=<lane> AND amount IS NULL;` | Record count; confirms/refutes B2 path | |
| Itemunit integrity | UAT DB | confirm every batch-position `itemdata.handlingunit_id` resolves in `itemunit` | No orphans (B1 precondition) | |
| Capture firing error | UAT | fresh repro; capture server stack + HTTP status + browser network | Pins B1 vs B2 firing site | |
| Details endpoint missing-batch | UAT | `GET /customerOrderBatch/customerorderBatchDetailsById/<bogus>` | HTTP **422** `{errors}` (confirms F2 try/catch closes the path) | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=CustomerorderBatchServiceUnitTest#<4 SBDEV-2486 methods>` | ✅ PASS | Tests run: 4, Failures: 0, Errors: 0, Skipped: 0 |
| `mvn verify -Dtest=ClubLineControllerIT` | ⏭ SKIPPED | Deferred — v1 ITs blocked by `ro_id` view drift (SBDEV-2384) |
| `jest --testPathPattern="clubRuns\|clubRunDetails"` | ✅ PASS | Test Suites: 2 passed; Tests: 4 passed |
| `bash verify-SBDEV-2486-…sh` | ✅ PASS | 26 pass, 0 fail, 2 skip |

> Implemented 2026-06-24. PRs: **wms-api [#179](https://github.com/SiteBossInc/wms-api/pull/179)** and **wms-web-ui [#65](https://github.com/SiteBossInc/wms-web-ui/pull/65)**, both → `develop`. Code review: code-reviewer (opus) **APPROVE**, 0 medium/high. `db_verified` remains **false** — the UAT DB pre-work (§1) is deferred to QA; the fix is correct independent of which firing path produced the incident.

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| B5 (`initializeCaches`/`calculateAmount`) | Dead code (no live callers) — see §2.6; deletion deferred to a tech-debt ticket |
| B6 (`buildDtoList:1023`) | DB-disproven (NOT NULL FK); optional one-line guard only |
| B7 (`buildDtoList:1024`) | Already guarded by `containsKey` at line 1011 |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

**N/A — this is a v1 plan.** `v1/wms-api` is **single-tenant by deployment** (one JVM + one PostgreSQL per client) and is not run as multiple load-balanced replicas. None of the in-JVM-state / connection-pool / scheduled-job / distributed-lock concerns in the v2 checklist apply. The v2 horizontal-scalability and v2-constraint analysis belongs in the paired v2 plan produced via `wms-v2-migrate`.

---

## 8. Notes

- Paired v2 plan to be produced via `wms-v2-migrate` (same base filename, `sbdocs/1-Projects/wms2/plan/`).
- B5 dead-code deletion → suggest a follow-up tech-debt ticket.
- F2 adds one `getClubRunFullDetails` request per hard refresh — acceptable (already the list page's pattern; only fires when persisted state is missing).
- Global error contract confirmed at `RestExceptionHandler.java:120–182`: BusinessException/FacadeException→422, NoSuchElement→404, NPE→500, all with `{errors}`.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

`sbdocs/9-System/scripts/verify-SBDEV-2486-club-lane-blank-screen-split-adjust.sh` — spans **both** repos; computes paths from the monorepo root `/home/nampark/dev/wms-claude`. POSITIVE checks for every in-scope fix (B1, B2, B3, B4, F1×3, F2, F3×4, F4), NEGATIVE checks where old code is replaced (incl. no residual `positions.forEach(` after the B1 conversion), and F2 checks for the `async`/`try` rejection-safety and the `details && !details.errors && details.id` guard. Commented `mvn_test_passes` rows for the proposed (not-yet-created) backend test classes.

### Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| **B2 reference-equality→id fix changes sums** | **High (this is the point)** | B2 is a genuine data-correctness bug — the broken `Object.equals` could only ever *under*-count (distinct instances never compare equal under OSIV-off), so the fix can only *correct* sums upward to the true total. The identity unit test (`...SumsByIdentity`) locks the corrected behavior. Promote to HIGH severity and call out in release notes so QA expects possibly-higher lane totals. |
| B1 changing 500→422 changes the `/skus` contract | Medium | `getItemInfo` already checks `!results.errors`; a 422 rejects → F4 resets `itemInfo` + toast. The missing-unit case stays 200 with a blank unit. |
| F2 re-fetch on mount adds a request per hard refresh | Low | Acceptable; only fires when `clubRunDetails` is null. The `await` is try/catch-wrapped so a 422 cannot re-throw. |
| Mockito 3.3.3 cannot `mockStatic` | Low | Use instance mocks + `SecurityContextHolder` per v1 rules. |
| Converting `forEach`→`for` in B1 | Low | Mechanical; `getClubLineSKUOverview` already declares `throws BusinessException`. Verify the closing `}` replaces the lambda's `});`. |

### 9.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 8 in-scope fixes across one backend service + one frontend domain |
| **Pre-draft step** | analyst+planner (done) | RCA + dual-layer scope decided |
| **Plan-review step** | critic | Standard+ requires it (this ralplan consensus loop) |
| **Implementation shape** | executor | one focused pass; verify-script is the gate |
| **Verification step** | verify-script + verifier | mandatory |
| **Code-review step** | code-reviewer | cross-repo + entity-equality rule sensitivity |
| **Commit step** | git-master | two repos → two atomic commits (api, web-ui) |

---

## 10. Open Questions / Resolved Decisions

### Resolved Decisions

1. **Scope = v1 ONLY.** v2 has near-identical defects, deferred to a paired v2 plan via `wms-v2-migrate` (same base filename).
2. **Breadth = BOTH layers** (backend B1–B4 + frontend F1–F4). Frontend (F1/F2) alone clears the literal blank-screen AC at every firing site, but B2 is a genuine data-correctness bug (wrong sums) no frontend fix can address, and B1/B3/B4 downgrade raw 500s to structured 422/404 for diagnostics + populated error bodies.
3. **RCA = confidence-scored hypotheses, `db_verified` partial.** B6 DB-disproven on dev; UAT unreachable → `db_verified:false` with mandatory pre-work in §1.

### Open Questions

- [ ] Which backend site actually fires the 500 in UAT (B1 vs B2)? — resolved by the §1 error capture; does not block the fix (both are addressed).
- [ ] Should `clubRunDetails.vue` render an explicit "not found" empty state, or silently self-fetch + toast? — product/UX preference; either clears the blank-screen AC.

### Completeness Checklist

| # | Item | Status |
|---|------|--------|
| 1 | Every §0 in-scope site addressed in §3 | ✅ B1–B4, F1–F4 |
| 2 | Every in-scope site mapped to a verify check | ✅ §9.1 / verify script |
| 3 | Excluded sites have explicit rationale | ✅ B5 dead, B6 DB-disproven, B7 guarded |
| 4 | Root cause traced symptom→code (with correct HTTP contract) | ✅ §2 (global handler 422/404/500; per-endpoint local-catch behavior) |
| 5 | Confidence-scored hypotheses | ✅ §2.1 (H1 ~40% / H2 ~45% / H3 ~10% defensive / H4 ~5%) |
| 6 | Before/After code per in-scope fix | ✅ §3.1–§3.8 |
| 7 | Prerequisites enumerated (§5.1) | ✅ incl. manual DB pre-work + details-endpoint 422 check |
| 8 | Test plan: unit + integration + manual | ✅ §6 |
| 9 | Risks enumerated (B2 HIGH) | ✅ §9 |
| 10 | v2 / horizontal-scalability marked N/A w/ rationale | ✅ §4, §7 |
| 11 | Resolved decisions recorded | ✅ §10 (3 decisions) |
