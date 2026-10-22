# SBDEV-3142 — web-UI callers of the 16 ungated POST-as-query read endpoints

**Repo:** `/home/nampark/dev/wms-claude/v2/wms2-web-ui`
**Derived from:** `origin/develop` @ **`9e70a73ba0175446d7127ad897c759b53a7f6471`**
(`Merge pull request #99 from SiteBossInc/feature/SBDEV-3031-render-refusal-in-dialog`, 2026-08-29 15:59:05 -0400)
**Local checkout state at time of derivation:** `HEAD == origin/develop`, `git rev-list --count HEAD..origin/develop` = **0**. Every claim below was nonetheless read out of the git object store via `git grep origin/develop` / `git show origin/develop:<path>`, not off the filesystem.
**Cross-repo:** `wms2-mobile-ui` `origin/develop` @ `c79e81c` was also swept (see §Finding F5).
**Date:** 2026-08-31

---

## 1. Search commands actually run

```bash
cd /home/nampark/dev/wms-claude/v2/wms2-web-ui
git fetch origin
git rev-parse origin/develop                       # 9e70a73ba0175446d7127ad897c759b53a7f6471

# M1 — path-fragment sweep, per endpoint, whole tree (git object store)
for p in exportInventory exportLock exportReceiving exportSkuLocation exportFlowbin \
         exportParcelPicking exportOutboundParcel exportStockUnitRecord \
         exportContainerRecord exportStorageLocations; do git grep -n "$p" origin/develop; done
git grep -n "clubLine"    origin/develop
git grep -n "transfers/"  origin/develop
git grep -n "transfers/parcels" origin/develop      # NO MATCH

# M2 — independent cross-check: filesystem `command grep` (bypasses the shell `grep`
#      function AND .gitignore, which hides reports/ — see §Finding F0)
for p in <same 16>; do
  command grep -rn "$p" --include='*.js' --include='*.vue' \
    store components pages layouts plugins middleware util | wc -l
done

# M3 — dynamic / concatenated URL sweep (a call built by string concat would evade M1/M2)
git grep -n '\$post(.\{0,3\}[`'"'"'"]/\?\${\|\$post(url\|\$post(path\|\$post(endpoint\|/report/. *+' \
  origin/develop -- store components pages plugins

# M4 — /dashboard/ twin sweep (each of the 10 exports also answers on /v3/dashboard/*)
git grep -n '\$axios\.\$\(get\|post\|put\|patch\|delete\)(.\{0,3\}/dashboard' \
  origin/develop -- store components pages plugins

# Store-action → component → page tracing
git grep -n "reports/<module>/export" origin/develop -- components pages layouts store
git grep -n "<action-path>"           origin/develop -- components pages layouts middleware
# component → page, BOTH by import statement AND by kebab-case tag (nuxt.config.js:60
# sets `components: true`, so an import statement is NOT required — see §Finding F1)
git grep -n "reports/<component>" origin/develop -- pages components layouts
git grep -n "<kebab-tag"          origin/develop -- pages components layouts

# The gate catalog
git show origin/develop:util/appMenuList.js
git show origin/develop:middleware/require-function.js
git grep -n "<CONSTANT>" origin/develop -- test/support/webFunctionConstants.js
```

**M1 vs M2 agreement:** after excluding the untracked `dist/` build output, M1 and M2 return **identical counts for all 16 endpoints** (table in §Finding F2). The initial disagreement and its resolution are recorded as a finding rather than silently reconciled.

---

## 2. The gate catalog — where `WEB_UI_VIEW_*` is actually asserted

`util/appMenuList.js` is the single source of truth, and it is consumed by **both** the rendered menu and the route guard. Its own header says so:

> `// SBDEV-2967-B Fix A1 — the single source of truth for "which screen needs which function".`

It exports three lists — `MENU` (menu leaves), `EXTRA_ROUTES` (deep-linkable non-menu pages), `UNGATED_ROUTES` (terminals) — plus `requiredFunctionFor(path)`. Enforcement is `middleware/require-function.js`:

> `import { requiredFunctionsFor } from '~/util/appMenuList'` … `const required = requiredFunctionFor(path)` … `return redirect(\`/not-authorized?page=${page}&fn=${encodeURIComponent(need[0])}\`)`

All 13 distinct constants cited in this report were confirmed present in `test/support/webFunctionConstants.js` (e.g. `'WEB_UI_VIEW_INVENTORY_RECORD',` at line 46). None is invented by this report.

---

## 3. Summary — the 16 verdicts

| # | Endpoint (`POST /v3/…`) | Verdict — function that should gate it | Screen |
|---|---|---|---|
| 1 | `report/exportInventory` | `WEB_UI_VIEW_INVENTORY_RECORD` | `/reports/inventory-report` |
| 2 | `report/exportLock` | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | `/reports/lock-report` |
| 3 | `report/exportReceiving` | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | `/reports/receiving-report` |
| 4 | `report/exportSkuLocation` | `WEB_UI_VIEW_LOCATION_OVERVIEW` | `/reports/sku-location-report` |
| 5 | `report/exportFlowbin` | `WEB_UI_VIEW_FLOWBIN_MONITOR` | `/reports/flowbin-report` |
| 6 | `report/exportParcelPicking` | `WEB_UI_VIEW_PARCEL_PICKING` | `/reports/parcel-picking-report` |
| 7 | `report/exportOutboundParcel` | `WEB_UI_VIEW_PARCEL_MONITOR` | `/reports/outbound-parcel-report` |
| 8 | `report/exportStockUnitRecord` | `WEB_UI_VIEW_STOCK_UNIT_RECORD` | `/reports/stock-unit-record` |
| 9 | `report/exportContainerRecord` | `WEB_UI_VIEW_UNIT_LOAD_RECORD` | `/reports/container-record` |
| 10 | `report/exportStorageLocations` | `WEB_UI_VIEW_STORAGE_LOCATION` | `/masterData/locationData/storage-locations` |
| 11 | `clubLine/skus` | `WEB_UI_VIEW_CLUB_LINE` ⚠ **latent ambiguity — see F3** | `/outbound/club/{open,closed}/:id`, `/processes/club-fulfillment` |
| 12 | `clubLine/unitLoads` | `WEB_UI_VIEW_CLUB_LINE` | `/processes/club-fulfillment` |
| 13 | `clubLine/parcels` | `WEB_UI_VIEW_CLUB_LINE` | `/outbound/club`, `/processes/club-fulfillment` |
| 14 | `transfers/unitLoads` | `WEB_UI_VIEW_TRANSFER_ORDER` | `/processes/transfer-fulfillment` |
| 15 | `transfers/parcels` | **UNMAPPED** — no caller found in either UI (F5) | — |
| 16 | `transfers/availableTransferLanes` | `WEB_UI_VIEW_TRANSFER_ORDER` | `/outbound/transfer`, `/processes/transfer-picking` |

**15 of 16 map to a single unambiguous function. One (`transfers/parcels`) is UNMAPPED. Zero are AMBIGUOUS today**, though #11 carries a latent ambiguity behind dead code (F3).

Quantitative note, per claim discipline: "15 of 16" is a **count over the 16 named endpoints**, derived by M1 ∩ M2 (§1) plus the store→component→page trace in §4. Its blind spots are enumerated in §5 — it is not a closed-set claim that no other reachable caller exists.

---

## 4. Per-endpoint detail

Every export handler is reached through the **same three-hop chain**: one report component owns a
`reportType` string → a shared popup `components/reports/popups/exportReport.vue` switches on it →
the matching Vuex module's `export` action issues the POST. Verified per endpoint below.

### 4.1 `POST /v3/report/exportInventory` → `WEB_UI_VIEW_INVENTORY_RECORD`

- **Call site:** `store/reports/inventory.js`, in `async export(context, params)` —
  `` `const result = await this.$axios.$post('/report/exportInventory', exportData, {` ``
- **Dispatcher:** `components/reports/popups/exportReport.vue` —
  `` `} else if (this.reportType == 'Inventory') {` `` → `` `this.$store.dispatch('reports/inventory/export', params)` ``
- **Owner sets `reportType`:** `components/reports/inventoryReport.vue` — `` `this.reportType = 'Inventory'` ``
- **Page:** `pages/reports/inventory-report.vue` — `` `<inventory-report />` `` and
  `` `import InventoryReport from '~/components/reports/inventoryReport.vue'` ``
- **Gate:** `util/appMenuList.js` `MENU` row 21 —
  `` `{ text: 'Inventory Report', to: '/reports/inventory-report', fn: 'WEB_UI_VIEW_INVENTORY_RECORD' }, // 21` ``

### 4.2 `POST /v3/report/exportLock` → `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW`

- **Call site:** `store/reports/lock.js` `export` — `` `this.$axios.$post('/report/exportLock', exportData, {` ``
- **Dispatcher:** `exportReport.vue` — `` `} else if (this.reportType == 'Lock') {` `` → `` `'reports/lock/export'` ``
- **Owner:** `components/reports/lockReport.vue` — `` `this.reportType = 'Lock'` ``
- **Page:** `pages/reports/lock-report.vue` — `` `<lock-report />` ``
- **Gate:** `` `{ text: 'Lock Report', to: '/reports/lock-report', fn: 'WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW' }, // 22` ``

### 4.3 `POST /v3/report/exportReceiving` → `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW`

**Two stores POST this path**, and only one is reachable.

- **Live call site:** `store/reports/receiving.js` `export` — `` `this.$axios.$post('/report/exportReceiving', exportData, {` ``
  Dispatcher: `exportReport.vue` — `` `} else if (this.reportType == 'Receiving') {` `` → `` `'reports/receiving/export'` ``
  Owner: `components/reports/receivingReport.vue` — `` `this.reportType = 'Receiving'` ``
  Page: `pages/reports/receiving-report.vue` — `` `<receiving-report />` ``
- **Unreachable second call site:** `store/reports/data.js` `export` — same path. Its only dispatcher is
  `exportReport.vue` — `` `} else if (this.reportType == 'Data') {` `` → `` `'reports/data/export'` ``.
  `git grep -n 'reportType' origin/develop -- components pages` shows nine assignments
  (`'Inventory'`, `'Lock'`, `'Receiving'`, `'SKU Location'`, `'Flowbin'`, `'Parcel Picking'`,
  `'Outbound Parcel'`, `'Stock Unit'`, `'Container'`) and **none sets `'Data'`** — so that branch
  cannot be entered. Method: grep of the literal token `reportType` across `components/**` and
  `pages/**`; blind spot: a value arriving as a prop from outside those two trees, or computed at
  runtime, would not appear. `git grep -n "reports/data/" origin/develop` (whole tree) returns
  exactly the one `exportReport.vue` line, so no other consumer exists in tracked source.
- **Gate:** `` `{ text: 'Receiving Report', to: '/reports/receiving-report', fn: 'WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW' }, // 23` ``

### 4.4 `POST /v3/report/exportSkuLocation` → `WEB_UI_VIEW_LOCATION_OVERVIEW`

- **Call site:** `store/reports/skuLocation.js` `export` — `` `this.$axios.$post('/report/exportSkuLocation', exportData, {` ``
- **Dispatcher:** `exportReport.vue` — `` `} else if (this.reportType == 'SKU Location') {` ``
- **Owner:** `components/reports/skuLocationReport.vue` — `` `this.reportType = 'SKU Location'` ``
- **Page:** `pages/reports/sku-location-report.vue` — `` `<sku-location-report />` ``
- **Gate:** `` `{ text: 'SKU Location Report', to: '/reports/sku-location-report', fn: 'WEB_UI_VIEW_LOCATION_OVERVIEW' }, // 24` ``

### 4.5 `POST /v3/report/exportFlowbin` → `WEB_UI_VIEW_FLOWBIN_MONITOR`

- **Call site:** `store/reports/flowbin.js` `export` — `` `this.$axios.$post('/report/exportFlowbin', exportData, {` ``
- **Dispatcher:** `exportReport.vue` — `` `} else if (this.reportType == 'Flowbin') {` ``
- **Owner:** `components/reports/flowbinReport.vue` — `` `this.reportType = 'Flowbin'` ``
- **Page:** `pages/reports/flowbin-report.vue` — `` `<flowbin-report />` ``
- **Gate:** `` `{ text: 'Flowbin Report', to: '/reports/flowbin-report', fn: 'WEB_UI_VIEW_FLOWBIN_MONITOR' }, // 25` ``
- Corroboration: the same store's search action reads the sibling read path
  `` `this.$axios.$get('/report/flowbinMonitorView' + urlPart)` `` — same screen, same subsystem.

### 4.6 `POST /v3/report/exportParcelPicking` → `WEB_UI_VIEW_PARCEL_PICKING`

- **Call site:** `store/reports/parcelPicking.js` `export` — `` `this.$axios.$post('/report/exportParcelPicking', exportData, {` ``
- **Dispatcher:** `exportReport.vue` — `` `} else if (this.reportType == 'Parcel Picking') {` ``
- **Owner:** `components/reports/parcelPickingReport.vue` — `` `this.reportType = 'Parcel Picking'` ``
- **Page:** `pages/reports/parcel-picking-report.vue` — `` `<parcel-picking-report />` ``
- **Gate:** `` `{ text: 'Parcel Picking Report', to: '/reports/parcel-picking-report', fn: 'WEB_UI_VIEW_PARCEL_PICKING' }` ``
  ⚠ `appMenuList.js` flags this one in a comment as *"the ONE leaf of thirty with no pre-existing
  constant"* — `WEB_UI_VIEW_PARCEL_PICKING` was **added by SBDEV-2967-B §7.2**, deliberately not
  reusing `PARCEL_MONITOR` (row 27's gate) nor `ORDER_DETAIL_MONITOR`. So this verdict depends on
  SBDEV-2967-B having shipped the constant server-side; it is present in
  `test/support/webFunctionConstants.js` but **that is a UI test fixture, not the API's function
  catalog** — confirm against `wms2-api` before relying on it.

### 4.7 `POST /v3/report/exportOutboundParcel` → `WEB_UI_VIEW_PARCEL_MONITOR`

- **Call site:** `store/reports/outboundParcel.js` `export` — `` `this.$axios.$post('/report/exportOutboundParcel', exportData, {` ``
- **Dispatcher:** `exportReport.vue` — `` `} else if (this.reportType == 'Outbound Parcel') {` ``
- **Owner:** `components/reports/outboundParcelReport.vue` — `` `this.reportType = 'Outbound Parcel'` ``
- **Page:** `pages/reports/outbound-parcel-report.vue` — `` `<outbound-parcel-report />` ``
- **Gate:** `` `{ text: 'Outbound Parcel Report', to: '/reports/outbound-parcel-report', fn: 'WEB_UI_VIEW_PARCEL_MONITOR' }, // 27` ``
- Corroboration: same store reads `` `this.$axios.$get('/report/parcelMonitorView' + urlPart)` ``.

### 4.8 `POST /v3/report/exportStockUnitRecord` → `WEB_UI_VIEW_STOCK_UNIT_RECORD`

- **Call site:** `store/reports/stockUnit.js` `export` — `` `this.$axios.$post('/report/exportStockUnitRecord', exportData, {` ``
- **Dispatcher:** `exportReport.vue` — `` `} else if (this.reportType == 'Stock Unit') {` ``
- **Owner:** `components/reports/stockUnitRecord.vue` — `` `this.reportType = 'Stock Unit'` ``
- **Page:** `pages/reports/stock-unit-record.vue` — `` `<stock-unit-record />` ``
- **Gate:** `` `{ text: 'Stock Unit Record', to: '/reports/stock-unit-record', fn: 'WEB_UI_VIEW_STOCK_UNIT_RECORD' }, // 28` ``

### 4.9 `POST /v3/report/exportContainerRecord` → `WEB_UI_VIEW_UNIT_LOAD_RECORD`

- **Call site:** `store/reports/container.js` `export` — `` `this.$axios.$post('/report/exportContainerRecord', exportData, {` ``
- **Dispatcher:** `exportReport.vue` — `` `} else if (this.reportType == 'Container') {` ``
- **Owner:** `components/reports/containerRecord.vue` — `` `this.reportType = 'Container'` ``
  (note: this component binds the prop kebab-style, `` `:report-type="reportType"` ``, where the
  other eight use `` `:reportType="reportType"` ``. Equivalent in Vue 2; noted so a
  camelCase-only grep is not mistaken for a miss.)
- **Page:** `pages/reports/container-record.vue` — `` `<container-record />` ``
- **Gate:** `` `{ text: 'Container Record', to: '/reports/container-record', fn: 'WEB_UI_VIEW_UNIT_LOAD_RECORD' }, // 29` ``
  ⚠ Note the name mismatch: the endpoint says *Container*, the gate says *UNIT_LOAD*. Same thing in
  this domain (`store/masterData` and the API both use `unitLoad` for what the UI calls a container),
  but do not "fix" the constant.

### 4.10 `POST /v3/report/exportStorageLocations` → `WEB_UI_VIEW_STORAGE_LOCATION`

The one export that does **not** go through `exportReport.vue`.

- **Call site:** `store/masterData/storageLocation.js`, in `async exportStorageLocations(context, data)` —
  `` `const result = await this.$axios.$post(`/report/exportStorageLocations`, {})` ``
  (template literal, no interpolation — this is why the M3 dynamic-URL sweep matters.)
- **Dispatcher:** `components/masterData/location/storageLocations/storageLocation.vue` —
  `` `const data = await this.$store.dispatch('masterData/storageLocation/exportStorageLocations')` ``
- **Page:** `pages/masterData/locationData/storage-locations.vue` — `` `<storage-location />` `` and
  `` `import StorageLocation from '~/components/masterData/location/storageLocations/storageLocation.vue'` ``
- **Gate:** `MENU` row 12 —
  `` `{ text: 'Storage Locations', to: '/masterData/locationData/storage-locations', fn: 'WEB_UI_VIEW_STORAGE_LOCATION' }, // 12` ``

### 4.11 `POST /v3/clubLine/skus` → `WEB_UI_VIEW_CLUB_LINE` ⚠ latent ambiguity

**Two stores POST this path.** One is live, one is dead — and the dead one belongs to a *different*
gate. See **F3**.

- **Live:** `store/processes/clubRuns.js`, in `async getItemInfo(context, data)` —
  `` `const results = await this.$axios.$post('/clubLine/skus', data)` ``
  Dispatchers (two live, one commented out):
  - `components/outbound/club/batchDetails.vue` —
    `` `this.$store.dispatch('processes/clubRuns/getItemInfo', { 'orderBatchId': this.batchDetails.id })` ``
    → mounted by `pages/outbound/club/open/_id.vue` **and** `pages/outbound/club/closed/_id.vue`
    (`` `import BatchDetails from '~/components/outbound/club/batchDetails.vue'` ``)
    → `EXTRA_ROUTES`: `` `'/outbound/club/open/:id': 'WEB_UI_VIEW_CLUB_LINE',` `` and
    `` `'/outbound/club/closed/:id': 'WEB_UI_VIEW_CLUB_LINE',` ``
  - `components/processes/clubRuns/clubRunDetails.vue` —
    `` `this.$store.dispatch('processes/clubRuns/getItemInfo', { 'orderBatchId': orderBatchId })` ``
    → mounted by `pages/processes/club-fulfillment.vue`
    (`` `import ClubRunDetails from '~/components/processes/clubRuns/clubRunDetails.vue'` ``)
    → `EXTRA_ROUTES`: `` `'/processes/club-fulfillment': 'WEB_UI_VIEW_CLUB_LINE',` ``
  - `pages/processes/club-run.vue` — `` `// this.$store.dispatch('processes/clubRuns/getItemInfo', { 'orderBatchId': item.id })` `` — **commented out**.
- **Dead:** `store/outbound/outboundBols.js`, in `async getItemInfo(context, data)` — same path.
  `git grep -n "outbound/outboundBols/getItemInfo" origin/develop -- components pages layouts middleware`
  returns **no dispatcher**. Had it been live its page would be `/outbound/outbound-bol`, gated
  `WEB_UI_VIEW_BILL_OF_LADING` — a *different* function, which is the latent ambiguity in F3.

**Verdict:** `WEB_UI_VIEW_CLUB_LINE` — every live path is CLUB_LINE-gated. Derivation: the
action-name grep above over `components/**`, `pages/**`, `layouts/**`, `middleware/**`. Blind spot:
a dispatch built from a computed/variable action name (e.g. `` `dispatch(`${ns}/getItemInfo`)` ``)
would not match; the M3 sweep found no such construction for these actions, but M3 targeted URL
concatenation, not action-name concatenation.

### 4.12 `POST /v3/clubLine/unitLoads` → `WEB_UI_VIEW_CLUB_LINE`

- **Call sites (2, same store):** `store/processes/clubRuns.js`
  - `async getInventoryOnLane(context, data)` — `` `const results = await this.$axios.$post('/clubLine/unitLoads', data)` ``
  - `async getAvailableInventory(context, data)` — same path
- **Dispatchers:** both from `components/processes/clubRuns/clubRunDetails.vue` —
  `` `this.$store.dispatch('processes/clubRuns/getInventoryOnLane', {` `` (two call sites) and
  `` `this.$store.dispatch('processes/clubRuns/getAvailableInventory', {` ``
- **Page:** `pages/processes/club-fulfillment.vue`
- **Gate:** `` `'/processes/club-fulfillment': 'WEB_UI_VIEW_CLUB_LINE',` ``

### 4.13 `POST /v3/clubLine/parcels` → `WEB_UI_VIEW_CLUB_LINE`

Two stores, **both** live, **both** CLUB_LINE — so this is a genuine multi-caller endpoint that is
nonetheless unambiguous.

- `store/outbound/club.js`, `async getParcelsClubBatch(context, data)` —
  `` `const results = await this.$axios.$post('/clubLine/parcels', data)` ``
  Dispatchers:
  - `components/outbound/club/openClub.vue` — `` `this.$store.dispatch('outbound/club/getParcelsClubBatch', { 'orderBatchId': item.id })     // detail table` ``
  - `components/outbound/club/closedClub.vue` — `` `this.$store.dispatch('outbound/club/getParcelsClubBatch', {'orderBatchId': item.id})     // detail table` ``
    both mounted by `pages/outbound/club/index.vue`
    (`` `import OpenClub from '~/components/outbound/club/openClub.vue'` ``,
    `` `import ClosedClub from '~/components/outbound/club/closedClub.vue'` ``)
    → `MENU` row 6: `` `{ text: 'Club', to: '/outbound/club', fn: 'WEB_UI_VIEW_CLUB_LINE' }, // 6` ``
  - `components/processes/clubRuns/clubRunDetails.vue` — `` `await this.$store.dispatch('outbound/club/getParcelsClubBatch', { 'orderBatchId': details.id })` ``
    → `/processes/club-fulfillment` → `WEB_UI_VIEW_CLUB_LINE`
- `store/processes/clubRuns.js`, `async getParcelsClubBatch(context, data)` — same path.
  Dispatcher: `components/processes/clubRuns/clubRunDetails.vue` — `` `this.$store.dispatch('processes/clubRuns/getParcelsClubBatch', {` ``
  → `/processes/club-fulfillment` → `WEB_UI_VIEW_CLUB_LINE`

### 4.14 `POST /v3/transfers/unitLoads` → `WEB_UI_VIEW_TRANSFER_ORDER`

- **Call sites (2, same store):** `store/processes/transferPicking.js`
  - `async getInventoryOnLane(context, data)` — `` `const results = await this.$axios.$post('/transfers/unitLoads', data)` ``
  - `async getAvailableInventory(context, data)` — same path
- **Dispatchers:** `components/processes/transferPicking/transferPickingDetails.vue` —
  `` `this.$store.dispatch('processes/transferPicking/getInventoryOnLane', {` `` (two sites) and
  `` `this.$store.dispatch('processes/transferPicking/getAvailableInventory', {` ``.
  One further site in `pages/processes/transfer-picking.vue` is **commented out**:
  `` `// await this.$store.dispatch('processes/transferPicking/getInventoryOnLane', {` ``
- **Page:** `pages/processes/transfer-fulfillment.vue`
  (`` `import TransferPickingDetails from '~/components/processes/transferPicking/transferPickingDetails.vue'` ``)
- **Gate:** `` `'/processes/transfer-fulfillment': 'WEB_UI_VIEW_TRANSFER_ORDER',` ``

### 4.15 `POST /v3/transfers/parcels` → **UNMAPPED**

`git grep -n "transfers/parcels" origin/develop` returns **NO MATCH** across the entire tracked
tree — source, tests and Cypress alike. The corrected M2 filesystem sweep also returns 0. The same
sweep on `wms2-mobile-ui` `origin/develop` @ `c79e81c` returns 0 (F5).

**This is "I found no caller", not "there is no caller."** What that verdict does *not* rule out:
- a caller in `v2/omsv2-UI` or `v2/oms-laravel-api` (not swept — out of scope);
- an external/integration consumer calling `/v3/transfers/parcels` directly;
- a caller on a branch other than `origin/develop` in either UI repo;
- a caller that constructs the path dynamically — though M3 found the **only** dynamic-URL `$post`
  in the whole web UI to be `store/admin/labelPrinting.js` `async print(context, { url, payload, successNoun })`
  → `` `const result = await this.$axios.$post(url, payload)` ``, and all four of its callers pass
  literals: `` `url: '/labelPrinting/totes/generate',` ``, `` `'/labelPrinting/totes/reprint'` ``,
  `` `'/labelPrinting/locations/print'` ``, `` `'/labelPrinting/unitLoads/reprint'` ``. So no
  dynamic construction in the web UI can reach any of the 16.

**Recommendation:** gate it `WEB_UI_VIEW_TRANSFER_ORDER` by symmetry with #14 and #16 (its
`TransfersController` siblings) — but record it as a by-analogy assignment with no caller evidence,
and confirm before shipping. Its `ClubLineController` twin `clubLine/parcels` (#13) *is* called,
which suggests `transfers/parcels` is an unfinished symmetry in the API rather than a live screen.

### 4.16 `POST /v3/transfers/availableTransferLanes` → `WEB_UI_VIEW_TRANSFER_ORDER`

Two stores, **both** live, **both** TRANSFER_ORDER.

- `store/outbound/transfer.js`, `async getAvailableTransferLanes(context, data)` —
  `` `const results = await this.$axios.$post('/transfers/availableTransferLanes', data)` ``
  Dispatchers:
  - `components/outbound/transfer/activate/selectLanePop.vue` — `` `this.$store.dispatch('outbound/transfer/getAvailableTransferLanes', {orderBatchId: this.activate1Batch.id})` ``
  - `components/outbound/transfer/activate/changeLanePop.vue` — `` `this.$store.dispatch('outbound/transfer/getAvailableTransferLanes', { orderBatchId: this.batchOrder.id })` ``
  Both imported by `components/outbound/transfer/openTransfers.vue`
  (`` `import SelectLane from './activate/selectLanePop.vue'` ``,
  `` `import ChangeLane from './activate/changeLanePop.vue'` ``), which is mounted by
  `pages/outbound/transfer/index.vue` (`` `import OpenTransfers from '~/components/outbound/transfer/openTransfers.vue'` ``)
  → `MENU` row 7: `` `{ text: 'Transfer', to: '/outbound/transfer', fn: 'WEB_UI_VIEW_TRANSFER_ORDER' }, // 7` ``
- `store/processes/transferPicking.js`, `async getAvailableTransferLanes(context, data)` — same path.
  Dispatcher: `components/processes/transferPicking/activate/selectLanePop.vue` —
  `` `this.$store.dispatch('processes/transferPicking/getAvailableTransferLanes', {orderBatchId: this.activate1Batch.id})` ``
  imported by `components/processes/transferPicking/activate/activateTransferBatch.vue`
  (`` `import SelectLane from './selectLanePop.vue'` ``), mounted by `pages/processes/transfer-picking.vue`
  (`` `<activate-transfer-batch />` ``, `` `import activateTransferBatch from '~/components/processes/transferPicking/activate/activateTransferBatch.vue'` ``)
  → `MENU` row 10: `` `{ text: 'Transfer Picking', to: '/processes/transfer-picking', fn: 'WEB_UI_VIEW_TRANSFER_ORDER' }, // 10` ``

⚠ **`selectLanePop.vue` is a basename shared by at least four files** (`outbound/club/activate/`,
`outbound/transfer/activate/`, `processes/clubRuns/activate/`, `processes/transferPicking/activate/`,
plus `receiving/open/popups/`). A basename grep conflates them. The two relevant files were
disambiguated by resolving each importer's **relative** specifier against its own directory, not by
name. A sibling importer `components/processes/transferPicking/activate/selectBatchPop.vue` has
`` `// import SelectLane from './selectLanePop.vue'` `` — **commented out**, and does not count.

---

## 5. Findings

### F0 — `.gitignore` `reports/` really does hide the report screens
`git check-ignore` confirms the brief's warning is live: `store/reports/`, `components/reports/` and
`pages/reports/` are all inside an ignored `reports/` glob. **Nine of the sixteen endpoints live
entirely inside those directories.** An ignore-aware search tool (or the shell's `grep` wrapper
function) returns zero callers for them and would have produced nine false `UNMAPPED` verdicts.
Everything here used `git grep` (object store) with `command grep` as the independent cross-check.
The files *are* tracked — `.gitignore` only suppresses tooling, not git history.

### F1 — `nuxt.config.js` sets `components: true`, so import-counting is not a complete method
`git show origin/develop:nuxt.config.js` → line 60 `` `components: true,` `` (under
`` `// Auto import components: https://go.nuxtjs.dev/config-components` ``). A component can
therefore be used as a tag with **no import statement anywhere**, so "N files import it" is an
undercount by construction. Every component→page hop above was checked **twice** — once by import
specifier, once by kebab-case tag. The two methods agreed on all ten report/masterData components
(exactly one mount site each). Residual blind spot: a tag written in PascalCase (`<InventoryReport/>`)
or built dynamically via `<component :is="...">` matches neither sweep.

### F2 — M1/M2 disagreed, and the cause was untracked build output
First-pass M2 over the repo root returned 2 hits for `exportInventory` where M1 returned 1, and 5 vs 3
for `exportStorageLocations`. Cause: `./dist/_nuxt/*.js` — minified production bundles, e.g.
`./dist/_nuxt/20660fd.js`. `git ls-tree --name-only origin/develop | grep -x dist` → **not tracked**;
it is a stale local build artifact. Re-running M2 scoped to
`store components pages layouts plugins middleware util` yields **exact agreement with M1 on all 16**:

| endpoint | M1 (`git grep`) | M2 (`command grep`) |
|---|---|---|
| exportInventory | 1 | 1 |
| exportLock | 1 | 1 |
| exportReceiving | 2 | 2 |
| exportSkuLocation | 1 | 1 |
| exportFlowbin | 1 | 1 |
| exportParcelPicking | 1 | 1 |
| exportOutboundParcel | 1 | 1 |
| exportStockUnitRecord | 1 | 1 |
| exportContainerRecord | 1 | 1 |
| exportStorageLocations | 3 | 3 |
| clubLine/skus | 2 | 2 |
| clubLine/unitLoads | 2 | 2 |
| clubLine/parcels | 2 | 2 |
| transfers/unitLoads | 2 | 2 |
| transfers/parcels | 0 | 0 |
| transfers/availableTransferLanes | 2 | 2 |

Worth flagging beyond this ticket: a `dist/` in the working tree will inflate any
non-git-aware audit of this repo.

### F3 — `clubLine/skus` has a dead second caller behind a *different* gate
`store/outbound/outboundBols.js#getItemInfo` POSTs `/clubLine/skus` and has **no dispatcher**. If
someone wires it up — plausible, since the surrounding action `getOrderDetails` in the same store
*is* used by the Outbound BOL screen — then `/clubLine/skus` becomes reachable from
`/outbound/outbound-bol`, gated `WEB_UI_VIEW_BILL_OF_LADING`
(`` `{ text: 'Outbound BOL', to: '/outbound/outbound-bol', fn: 'WEB_UI_VIEW_BILL_OF_LADING' }, // 8` ``).
A `WEB_UI_VIEW_CLUB_LINE` gate on the endpoint would then 403 a BOL-entitled user on a screen the
menu showed them. **Recommend the ticket either delete that dead action or record the coupling**,
so the gate choice is not silently invalidated by a future one-line wiring change.

### F4 — the `/dashboard/` twin of all ten exports has **zero** web-UI callers
The brief notes each export answers on both `/v3/report/*` and `/v3/dashboard/*` because
`DashboardController extends ReportController`. M4 result: the web UI **does** call `/dashboard/*`
paths — six of them, all in `store/dashboard/` (e.g. `` `this.$axios.$get('/dashboard/orderMonitorViewSummary')` ``,
`` `this.$axios.$post('/dashboard/printToteLabels', data)` ``, `` `this.$axios.$get('/dashboard/replenishMonitorViewSummary')` ``)
— but **not one of the ten export handlers on the `/dashboard/` prefix**. Method: the M4 regex over
`store`, `components`, `pages`, `plugins`, cross-read against the full `/report/` inventory in §1.
Blind spot: same as M3 — a dynamically built path, ruled out for this repo in §4.15.

**Implication for the fix — this is the load-bearing one.** A gate expressed as a **URL pattern** on
`/v3/report/export*` leaves all ten `/v3/dashboard/export*` twins open, and no web-UI regression test
can catch it because the UI never exercises that prefix. The gate must attach to the **handler
method** (inherited by `DashboardController` along with the mapping) rather than to the request path.
Note that the many `dashboard/...` strings in `components/homepage/**` and `layouts/default.vue` are
**Vuex namespaces**, not API paths (e.g. `` `this.$store.commit("dashboard/pickpackMonitor/resetClient");` ``) —
a naive `grep dashboard/` conflates the two and suggests dozens of dashboard API calls that do not exist.

### F5 — `wms2-mobile-ui` calls none of the six clubLine/transfers endpoints
Swept `origin/develop` @ `c79e81c`: `transfers/parcels`, `clubLine/parcels`, `transfers/unitLoads`,
`clubLine/unitLoads`, `clubLine/skus`, `transfers/availableTransferLanes` → **0 hits each**. So
gating these six cannot break the mobile UI. Method: `git grep -c` over `*.js`/`*.vue` on that repo's
`origin/develop`. Blind spot: mobile calls built by concatenation were not swept there; the ten
`/report/export*` paths were not swept there either (they are web-report screens with no mobile
analogue, but that is an inference, not a measurement).

### F6 — dead duplicate branch in `exportReport.vue`
The `reportType` chain tests `'Receiving'` **twice**:
`` `} else if (this.reportType == 'Receiving') {` `` → `` `this.$store.dispatch('reports/receiving/export', params)` ``
appears at both the third and the final branch. The final one is unreachable — the earlier test
always wins. Cosmetic, unrelated to authz; noted because it makes a raw dispatcher count read 2
where the live count is 1, which is exactly the kind of thing that turns into a wrong AMBIGUOUS
verdict. Adjacent to it, the `'Data'` branch (F/§4.3) is unreachable for a different reason.

---

## 6. Blind spots of this report, consolidated

1. **Only `wms2-web-ui` was mapped in depth** (plus a six-endpoint sweep of `wms2-mobile-ui`).
   `omsv2-UI` and `oms-laravel-api` were not searched at all; a caller there would not appear.
2. **PascalCase tags and `<component :is>`** defeat both component→page methods (F1).
3. **Dynamically-named Vuex dispatches** (`` dispatch(`${ns}/action`) ``) defeat the action-name
   greps. M3 ruled out dynamic *URL* construction, which is a different axis.
4. **`test/support/webFunctionConstants.js` is a UI fixture, not the API's function catalog.** All 13
   constants exist there; whether each exists in `wms2-api`'s `los_function` seed / enum was **not**
   verified in this pass. `WEB_UI_VIEW_PARCEL_PICKING` is the one at real risk — `appMenuList.js`
   itself calls it newly-added by SBDEV-2967-B §7.2.
5. **`WEB_UI_VIEW_*` today gates a *screen*, and this report proposes reusing it to gate an
   *endpoint*.** Those are different granularities. Where one function currently reveals a page whose
   several endpoints have differing sensitivity, reusing the page's function widens or narrows access
   relative to intent. Nothing in the 16 looked like a case of that, but the report checked screen
   reachability, not per-endpoint sensitivity.
6. **`appMenuList.js` is itself asserted-exhaustive, and its guarantee is narrower than it looks.**
   Its own header cites `test/util/appMenuList.spec.js#everyPageOnDiskIsClassified` as walking
   `pages/` and asserting every route is in exactly one of the three lists. That test was **not run**
   in this pass, and it pins *classification*, not *correctness of the function chosen*. Two rows are
   flagged `⚠ semantics-derived` in the file itself (rows 1 and 5) — neither is one of ours.

---

## 7. Cross-check against SBDEV-3169 prior art

`SBDEV-3169-evidence/3169-lane-functions.md` was derived for the **SDR axis**, not this one, but five
of its rows name endpoints in our set. **All five agree with the verdicts above** — arrived at
independently, since 3169 reasoned entity→controller while this report reasoned endpoint→store→page:

| 3169 row | Endpoint | 3169's proposal | This report | Agree? |
|---|---|---|---|---|
| 17 InventoryRecord | `/v3/report/exportInventory` `ReportController.java:59` | `WEB_UI_VIEW_INVENTORY_RECORD` (menu row 21) | same | ✅ |
| 47 StockView | `/v3/report/exportInventory` (same handler) | `WEB_UI_VIEW_INVENTORY_RECORD` | same | ✅ |
| 26/27 LockOverview*DtoView | `/v3/report/exportLock` `ReportController.java:85` | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` (menu row 22) | same | ✅ |
| 14 FlowbinMonitorView | `/v3/report/flowbinMonitorView` `:352` (sibling read of #5) | `WEB_UI_VIEW_FLOWBIN_MONITOR` (menu row 25) | same for `exportFlowbin` | ✅ |
| 31 OrderDetailMonitorView | `/v3/report/parcelPickingView` `:372` (sibling read of #6) | `WEB_UI_VIEW_PARCEL_PICKING`, superseding `ORDER_DETAIL_MONITOR` | same | ✅ |
| 52 UnitloadRecord | `/v3/unitloadRecord` (entity behind #9) | `WEB_UI_VIEW_UNIT_LOAD_RECORD` (menu row 29) | same for `exportContainerRecord` | ✅ |

3169 also confirms independently that these handlers carry **no** `@RequiresFunction` today
("**— none**" in its gate column for rows 14, 17, 26, 27, 31, 47, 52) — consistent with SBDEV-3142's
premise. The ten remaining endpoints in our set do not appear in 3169 at all.

### One prior-art warning, checked and found not to apply here
3169 row 26 states: *"Called via a computed resource name at `store/reports/lock.js:56,64` — a
literal-string grep misses it."* That is true and it is the exact failure mode that would invalidate
this report's method — so it was verified directly. `git show origin/develop:store/reports/lock.js`
shows the computed name is confined to the **SDR search** action:

```js
const resource = data.includeShipped ? 'lockOverviewAllDtoView' : 'lockOverviewDtoView'
const results = await this.$axios.$get('/' + resource + '/search/findByKeyword' + urlPart)
```

whereas the sibling `export` action in the same file uses a **literal**:
`` `const result = await this.$axios.$post('/report/exportLock', exportData, {` ``.

So the warning lands on the SDR read axis, not the export axis. Combined with the M3 dynamic-URL
sweep (§4.15 — the only dynamic `$post` in the web UI is `store/admin/labelPrinting.js`, and all four
of its callers pass `/labelPrinting/*` literals), **every one of the 16 endpoints is reached, where
reached at all, by a literal path string.** Derivation: M1 ∩ M2 ∩ M3. Blind spot: a path assembled
across two variables or read from config would evade all three; none was observed.

### One prior-art claim NOT relied on
3169 row 101 argues `WEB_UI_VIEW_INVENTORY_RECORD` is *misnamed relative to the data* — the Inventory
Report screen is gated on `INVENTORY_RECORD` but reads `/stockView/search/findByKeyword`. This report
neither confirms nor disputes that; it is consistent with the observation in §4.1 that
`store/reports/inventory.js` contains no `$get('/report/…')` search call. Either way the **gate
verdict is unchanged**, because the verdict follows the screen's menu entry, not the entity name.
