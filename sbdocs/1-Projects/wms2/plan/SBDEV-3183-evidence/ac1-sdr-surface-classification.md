---
title: "SBDEV-3183 AC-1 — runtime-derived classification of the exported Spring Data REST read surface"
ticket: "SBDEV-3183"
type: "evidence"
project: ["wms2"]
version: "v2"
created: "2026-09-01"
status: "evidence lane complete — classification proposed, not implemented"
derived_from: "wms2-api origin/develop 152108d3 (Merge PR #261, SBDEV-3155 mutating-get gating)"
---

# AC-1 — the exported SDR read surface, classified

**Everything below is derived from `origin/develop`, fetched 2026-09-01.** Commit SHAs at the
moment of measurement:

| repo | `origin/develop` | working checkout was |
|---|---|---|
| `v2/wms2-api` | `152108d3` | `ad681319` (2 commits behind) |
| `v2/wms2-web-ui` | `3117acac` | same |
| `v2/wms2-mobile-ui` | `c79e81c3` | same |
| `v2/oms-laravel-api` | `f1ad0f43` | `809e1eb3` (**5 commits behind**) |

Two of the four checkouts were stale at the start of this lane. Every claim below was re-derived
from the `origin/develop` tree via `git show origin/develop:<path>` / `git grep … origin/develop`,
never from the working tree.

**No production source was modified.** The runtime numbers come from two tests that already exist
on `origin/develop`, run unchanged in a throwaway detached worktree. A third, temporary probe test
was written into that worktree to settle handler precedence and was deleted after the run; its
source is reproduced in §E.3 so the measurement is repeatable.

---

## A. The exported domain types — count and derivation

**62 exported domain types.** Three independent instruments agree:

| instrument | value | how |
|---|---|---|
| **Runtime** — `SdrSurfaceInventoryContextTest` | **62** exported of 70 registered | iterates `ResourceMappings`, reads `ResourceMetadata#isExported()` |
| **Runtime** — `SdrRuleStartupCheck` boot log | **62** exported, 8 ruled, 54 unruled | independent code path, same context |
| **Grep** — `git grep '@RepositoryRestResource(' origin/develop -- src/main/java` | **62** | 65 files contain the token; 3 are javadoc-only mentions (`RestConfiguration.java`, `PutawayConfigRepositoryEventHandler.java`, `ShipperIdController.java`) |

Runtime command (in a detached worktree at `origin/develop`, Java 21 via sdkman):

```
mvn -o -Dtest=SdrSurfaceInventoryContextTest -Djacoco.skip=true test
→ SDR-INVENTORY resources=70 exported=62 searches=336 exportedSearches=336 writableExportedResources=11
```

Raw output: `sdr-surface-inventory.tsv` (this directory), 407 lines = 1 header + 70 collection rows
+ 336 search rows.

### A.1 The 8 registered-but-not-exported repositories

`RestConfiguration` sets `RepositoryDetectionStrategies.ANNOTATED`, so these appear in
`ResourceMappings` with `exported=false` and publish nothing:

`CustomerorderCancellationLog`, `OutboxMessage`, `PutawayConfigAudit`, `RestIdempotency`, `Tenant`,
`TenantAuthConfiguration`, `TenantDbConfiguration`, `TenantDiscovery`.

They contribute **0** search resources (measured: `awk` over the TSV). Reading the TSV without the
`exported` column would inflate the surface by 8; that is why the column exists.

### A.2 The read-path count, and a documented number that does not reproduce

Measured on `origin/develop` today:

| axis | count | instrument |
|---|---|---|
| collection reads (`GET /v3/<path>`) | 62 | runtime |
| item reads (`GET /v3/<path>/{id}`) | 62 | runtime (`itemVerbs` column) |
| search reads (`GET /v3/<path>/search/<name>`) | **336** | runtime |
| association reads (`GET /v3/<path>/{id}/<assoc>`) | **3** | grep + doc cross-check — see §E.1 |

🔴 **Instrument disagreement, unresolved.** `RestConfiguration.java`'s javadoc asserts *"347 exported
searches remain ungated reads"*, and `SBDEV-3169-sdr-read-gating.md` builds its headline "409 read
paths" on that same 347 (`62 + 347`). Today's runtime measures **336**. I checked whether searches
were deleted in between:

```
git log origin/develop -S'347 exported searches' -- src/main/java/net/aim_ai/wms/RestConfiguration.java
  → 4f2d4c83  Fri Aug 28 2026  "SBDEV-3157 — withdraw SDR write verbs…"
git diff --stat 4f2d4c83 origin/develop -- src/main/java/net/aim_ai/wms/repository
  → (empty)
```

**The repository package is byte-identical between the commit that wrote "347" and `origin/develop`,
yet the runtime counts 336.** The repositories cannot have changed, so one of the two numbers is
wrong rather than stale. I could not attribute the 11-path delta without re-running the enumerator
at `4f2d4c83`, which I did not do. Treat **336** as the measured value and **347 / 409 as
unreproduced**; any plan section that sizes work off 409 should be re-derived.

### A.3 A second documented off-by-one

`RestConfiguration`'s javadoc opens *"the **48** exported resources that accept writes over Spring
Data REST and have no writer anywhere"*. The array it documents holds **47** entries:

```
git show origin/develop:src/main/java/net/aim_ai/wms/RestConfiguration.java \
  | sed -n '/SDR_WRITE_WITHDRAWN/,/^    };/p' | grep -c '\.class,\?$'   → 47
```

Arithmetic check that confirms 47 is the real number: 62 exported − 47 withdrawn = **15**, and the
runtime reports **11** still writable. The 4-way gap is the four resources whose writes were
withdrawn by the *separate* `configureRoleFunctionWriteExposure` block rather than by the array
(`UserGroup`/`UserRole` item `PATCH`+`DELETE`, and the `User` blocks above it) — i.e. two withdrawal
mechanisms, not one. Anyone auditing "is X writable?" from the array alone will get the wrong
answer for `UserGroup` and `UserRole`.

---

## B. Every exported read path, classified

### B.0 How the three buckets were separated, and what each name means here

The brief's three buckets overlap as worded (a caller behind a screen function satisfies both
"NEEDS GATING" and "MUST STAY OPEN"). Resolved as follows, stated so the verdicts are auditable:

- **NEEDS GATING** — a live caller exists **and** every one of its call sites sits behind an
  identifiable screen function, so a `SdrFunctionRules` entry can be written that denies nobody who
  can reach the screen.
- **MUST STAY OPEN** — a live caller exists whose entitlement **cannot** be expressed as a screen
  function today: the login bootstrap, an OMS machine-to-machine service token, or a mobile screen
  whose gate is not in `util/appMenuList.js`. Gating these needs a decision, not a rule row.
- **SAFE TO UN-EXPORT** — no caller found by the independent methods named per row.

### B.1 Methods, and what each one cannot see

| # | method | what it matches | blind spot |
|---|---|---|---|
| **A** | `git grep -- "/<path>"` over `*.js *.vue *.ts` in both UIs at `origin/develop` | any textual mention | substring collisions (`/client` matches `/clientOrder`); says nothing about *which* handler serves it |
| **B** | axios call-site extraction — regex matches the axios **instance** methods (`$axios.get`, `$axios.$get`, `axios.delete`) **as well as** the Nuxt shortcuts (`$get(`, `$delete(`) | the URL literal at a real request site, with its verb | truncates at `${…}` / `' +` concatenation; misses fully-computed URLs; **misses Cypress**, which does not use axios |
| **C** | `git grep -- "/<path>"` over **all tracked files**, plus a HAL-rel pattern (`_embedded.<rel>`) | mentions in cypress specs, fixtures, JSON, markdown | same substring collisions as A |
| **D** | `git grep -E "cy\.(wms|request|api)\("` over `cypress/` | Cypress e2e call sites | test-harness callers only |

Method B's truncation was caught, not assumed: three rows it first reported as SDR
(`/advice/acceptHubAndSpokeBol/`, `/message/resend`, `/user/isOmsUser/`) turned out to be an MVC
route, an MVC route, and **a commented-out line**. Every ambiguous row was then read individually —
the same discipline the `Section` near-miss in SBDEV-3157 forced.

Method D was added **because** Method A/C flagged `customerorderBatch` and `pickingorder` as
"mentioned but never called": both are called from Cypress via `cy.wms('GET', …)`, which Method B
structurally cannot see. Two methods would have mis-bucketed them.

**Resolution of a call site to SDR vs MVC** is by exact match against the 755 `/v3/**` MVC paths
emitted by `SurfaceInventoryContextTest` (`surface-inventory.tsv`), not by eyeball. Case is
load-bearing and is the discriminator throughout: `/v3/itemData`, `/v3/stockUnit`, `/v3/unitLoad`,
`/v3/customerOrder`, `/v3/billOfLading`, `/v3/cycleCount`, `/v3/replenishOrder`, `/v3/shipperId`,
`/v3/boxType` are **MVC controllers**; the lowercase `/v3/itemdata`, `/v3/stockunit`, … are the SDR
resources. Conflating them is how an SDR audit picks up 40 controller routes that are already gated.

### B.2 Headline distribution (62 exported types)

| bucket | types | basis |
|---|---|---|
| live SDR **read** caller in app code | **29** | Method B, each ambiguous row read individually |
| SDR **write** caller only, no SDR read | **2** — `Advice`, `Cyclecount` | Method B |
| SDR read caller **only from Cypress** | **2** — `CustomerorderBatch`, `Pickingorder` | Method D |
| **no SDR caller by any of A/B/C/D** | **29** | see B.5 |

29 + 2 + 2 + 29 = 62. ✔

### B.3 MUST STAY OPEN — 6 types

Citations are `file` + a distinctive quoted snippet, not bare line numbers.

| type | path(s) | caller | why it cannot be a screen-function rule |
|---|---|---|---|
| `Client` | `GET /v3/client`, `GET /v3/client/{id}`, `GET /v3/client/search/findByClNr` | **OMS** `app/Services/WmsFacilitySyncService.php` — `readWmsCollection($facilityCode, 'client_list', 'client')`; `WmsApiService.php` — `buildWmsUrl($facility, $this->getWmsEndpoint('client_find_by_number'))` | OMS authenticates with the facility's Keycloak **service token**, not a WMS user. Whether that principal resolves to any `los_userfunction` grant is unverified — see §D.3 |
| `Itemdata` | `GET /v3/itemdata`, `GET /v3/itemdata/search/findByClientId` | **OMS** `WmsFacilitySyncService.php` — `readWmsCollection($facilityCode, 'itemdata_list', 'itemdata')` and `'itemdata_by_client'` | same service-token question |
| `Shipperid` | `GET /v3/shipperid` | **OMS** `WmsFacilitySyncService.php` — `readWmsCollection($facilityCode, 'shipperid_list', 'shipperid')` | same |
| `Boxtype` | `GET /v3/boxtype` | **OMS** `WmsFacilitySyncService.php` — `readWmsCollection($facilityCode, 'boxtype_list', 'boxtype')` | same |
| `Section` | `GET /v3/section`, `GET /v3/section/search/findByName` | **mobile** `wms2-mobile-ui/store/picking.js` — `this.$axios.$get('/section')` and `this.$axios.$get('/section/search/findByName')` | mobile's route guard **fails open** on `!rolesLoaded` and its screens are not in `util/appMenuList.js`; there is no web-UI function that names the mobile picking screen |
| `Stockunit` | `GET /v3/stockunit/search/getAmountAvailable` | **mobile** `wms2-mobile-ui/components/replenish/shared/OrderHeaderBlock.vue` — `$get('/stockunit/search/getAmountAvailable')` | same cross-app problem; the web caller of this type sits behind `WEB_UI_VIEW_REPLENISHMENT_ORDER`, the mobile one behind nothing |

`Printer` is **not** in this table, though OMS can reach it: `config/wms.php` defaults
`printer_search_by_type` to the unauthenticated `rest/printer/findByType`, and only an env override
repoints it at the SDR search. See §D.2.

### B.4 NEEDS GATING — 23 types (26 rows; 3 are shared with B.3)

Each has live app callers, all of which sit behind a nameable function. `fn` is from
`wms2-web-ui/util/appMenuList.js` (`{ text: …, to: …, fn: … }` rows and the `EXTRA_ROUTES` map),
which `middleware/require-function.js` consumes as the route guard.

| type | SDR read paths in use | caller (file + snippet) | screen → function |
|---|---|---|---|
| `Boxtype`¹ | `search/findByBoxtypeprocesstype`, `search/findByAdvicePositionId` | `store/receiving/createPo.js` — `$get('/boxtype/search/findByBoxtypeprocesstype'` | Inbound Notices → `WEB_UI_VIEW_INBOUND_BOL` |
| `Client`¹ | collection, item | `store/admin/client.js` — `$get('/client' + urlPart)`; `store/admin/shippers.js` — `` $get(`/client/${data.id}`) `` | Shippers → `WEB_UI_VIEW_CLIENT` **and** `store/admin/configuration.js` — `` $get(`/client/${sysProp.clientId}`) `` → `WEB_UI_VIEW_SYSTEM_PROPERTY` ⇒ **union of 2** |
| `Customerorder` | collection, item, `search/findByKeyword` | `store/masterData/customerOrder.js` — `$get('/customerorder/search/findByKeyword'`; `components/outbound/bol/outboundBolDetailsTable.vue`; `store/processes/transferPicking.js` | ⇒ **union of ≥3** (`WEB_UI_VIEW_BILL_OF_LADING`, `WEB_UI_VIEW_TRANSFER_ORDER`, + the master-data screen) |
| `Goodsreceiptposition` | `search/findByAdvicepositionId` | `store/receiving/inboundNotices.js` — `$get('/goodsreceiptposition/search/findByAdvicepositionId'` | `WEB_UI_VIEW_INBOUND_BOL` |
| `Itemdata`¹ | `search/findByClientId`, `search/findByClientIdIn` | `store/receiving/createPo.js` — `$get('/itemdata/search/findByClientId'`; `store/internalOps/createCc.js` — `$get('/itemdata/search/findByClientIdIn'` | two screens but **two distinct searches** ⇒ clean per-search override: `findByClientId`→`WEB_UI_VIEW_INBOUND_BOL`, `findByClientIdIn`→`WEB_UI_VIEW_CYCLECOUNT` |
| `Itemunit` | collection | `store/masterData/skuUnit.js` — `$get('/itemunit')`; `store/masterData/packaging.js` | SKU Units → `WEB_UI_VIEW_ITEM_UNIT`; Packaging → `WEB_UI_VIEW_CASE_TYPE` ⇒ **union of 2** |
| `Location` | `search/findByGateTrue`, `search/getAllCrossDockingLanes`, item (Cypress) | `store/outbound/outboundBols.js` — `$get('/location/search/findByGateTrue')`; `store/receiving/inboundNotices.js` — `$get('/location/search/getAllCrossDockingLanes')` | distinct searches ⇒ per-search: `WEB_UI_VIEW_BILL_OF_LADING` / `WEB_UI_VIEW_INBOUND_BOL` |
| `LocationArea` | collection | `store/masterData/functionalArea.js` — `$get('/locationArea')`; `store/internalOps/createCc.js` — `$get('/locationArea')` | **same path, two screens** ⇒ union `{WEB_UI_VIEW_AREA, WEB_UI_VIEW_CYCLECOUNT}`; no per-search narrowing possible |
| `LocationRack` | collection | `store/masterData/storageLocation.js` — `$get('/locationRack')` | Storage Locations → `WEB_UI_VIEW_STORAGE_LOCATION` |
| `LocationType` | collection | `store/masterData/locationType.js` — `$get('/locationType')` | Location Types → `WEB_UI_VIEW_STORAGE_LOCATION_TYPE` |
| `Message` | collection, `search/findByKeyword` | `store/admin/serviceLogs.js` — `$get('/message' + urlPart)`, `$get('/message/search/findByKeyword'` | Service Log → `WEB_UI_VIEW_MESSAGES` |
| `Printer` | collection, `search/findByType` | `store/admin/printer.js` — `$get('/printer')`, `$get('/printer/search/findByType'`; `store/reports/parcelPicking.js` — `$get('/printer/search/findByType'` | **same search, two screens** ⇒ union `{WEB_UI_VIEW_PRINTER, WEB_UI_VIEW_PARCEL_PICKING}` |
| `ReceivingDtoView` | `search/findByKeyword`, `search/findByAdvicenumber`, `search/findByAdvicepositionid` | `store/reports/receiving.js` + `store/reports/data.js` — `$get('/receivingDtoView/search/findByKeyword'`; `store/receiving/inboundNotices.js` — `…/search/findByAdvicenumber` | per-search: `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` / `WEB_UI_VIEW_INBOUND_BOL` |
| `Replenishorder` | item | `store/internalOps/replenishments.js` — `` $get(`/replenishorder/${…}`) `` | Replenishment → `WEB_UI_VIEW_REPLENISHMENT_ORDER` |
| `StockView` | `search/findByKeyword` | `store/reports/inventory.js` — `$get('/stockView/search/findByKeyword'` | Inventory Report → `WEB_UI_VIEW_INVENTORY_RECORD` |
| `Stockrecord` | `search/findByKeyword` | `store/reports/stockUnit.js` — `$get('/stockrecord/search/findByKeyword'` | Stock Unit Record → `WEB_UI_VIEW_STOCK_UNIT_RECORD` |
| `Sysprop` | collection, item, `search/findByGroupname` | `store/admin/configuration.js` — `$get('/sysprop/search/findByGroupname'`; `store/admin/management.js`; `store/admin/mgmt/overview.js` | `WEB_UI_VIEW_SYSTEM_PROPERTY` ∪ `WEB_UI_VIEW_IMPORT_DATA` |
| `Unitload` | `search/findByCarrierunitloadId` (+ `findByLabelid`, `findByStoragelocationId`, item — Cypress) | `store/handlingUnits/container.js` — `$get('/unitload/search/findByCarrierunitloadId'` | Handling Units → any-of `{WEB_UI_VIEW_STOCK_UNIT, WEB_UI_VIEW_CONTAINER}` (already an any-of leaf in `appMenuList.js`) |
| `UnitloadRecord` | `search/findByKeyword` | `store/reports/container.js` — `$get('/unitloadRecord/search/findByKeyword'` | Container Record → `WEB_UI_VIEW_UNIT_LOAD_RECORD` |
| `UnitloadType` | collection | `store/masterData/unitLoadType.js` — `$get('/unitloadType')`; `store/receiving/createPo.js` | `WEB_UI_VIEW_UNIT_LOAD_TYPE` ∪ `WEB_UI_VIEW_INBOUND_BOL` |
| `ViewWarehouseLocationReport` | `search/findByKeyword` | `store/reports/skuLocation.js` — `$get('/viewWarehouseLocationReport/search/findByKeyword'` | SKU Location Report → `WEB_UI_VIEW_LOCATION_OVERVIEW` |
| `User` | item, **association** `/{id}/groups` | `components/admin/userManagement/users/user.vue` — `` $get(`/user/${item.id}`) ``; `store/admin/user.js` — `` $get(`/user/${data.userId}/groups`) `` | **already ruled** — `WEB_UI_VIEW_USER_MANAGEMENT` |
| `UserFunction` | collection, `search/findByKeyword` | `store/admin/function.js` — `$get('/userFunction')` | **already ruled** |
| `UserGroup` | collection, **association** `/{id}/roles`, `search/findByConnectorFalse`, `search/findByName` | `store/admin/group.js` — `` $get(`/userGroup/${data.groupId}/roles`) `` | **already ruled** |
| `UserGroupUser` | `search/findByGrouplistId` | `store/admin/group.js` — `$get('/userGroupUser/search/findByGrouplistId'` | **already ruled** |
| `UserRole` | collection, **association** `/{id}/functions`, `search/findByConnectorFalse`, `search/findByName` | `store/admin/role.js` — `$get('/userRole/search/findByConnectorFalse'`; `store/admin/group.js` — `` $get(`/userRole/${r.id}/functions`) `` | **already ruled** |

¹ `Boxtype`, `Client` and `Itemdata` appear in **both** B.3 and B.4 — they have a screen-gateable UI
caller *and* an OMS service-token caller. They are the highest-risk rows: a rule that satisfies the
UI silently breaks OMS facility sync if the service principal holds no function. Counted once, in
MUST STAY OPEN, in the B.2 tally.

Row arithmetic: 26 rows − 3 dual (`Boxtype`, `Client`, `Itemdata`, already counted in B.3) = **23**
types whose whole caller set is screen-gateable. 23 + 6 (B.3) = 29, the live-SDR-read population
from B.2. ✔

**Cross-screen types needing a union or a per-search override: 10** — `Client`, `Customerorder`,
`Itemdata`, `Itemunit`, `Location`, `LocationArea`, `Printer`, `ReceivingDtoView`, `Sysprop`,
`UnitloadType`. Of these, **4** (`Itemdata`, `Location`,
`ReceivingDtoView`, and partly `Client`) split cleanly on the search path and can use the
`SearchOverrideKey` mechanism `SdrFunctionRules` already ships. **3** (`LocationArea`, `Printer`,
`Itemunit`) read the *same* path from two screens and can only take a union — the exact shape
`SdrFunctionRules`' `USER_ADMIN_VIEW` javadoc warns is "a ceiling, not a fit".

### B.5 SAFE TO UN-EXPORT — 29 types

**24 with zero mention by every method** (A: path grep over `*.js *.vue *.ts`; B: axios call-site
extraction; C: `git grep` over **all** tracked files including the gitignored `reports/` tree and
Cypress fixtures; D: `cy.wms|cy.request|cy.api` sweep). All four returned 0 for each row:

`Billoflading`, `BillofladingPosition`, `CustomerorderPosition`, `CyclecountDtoView`,
`CyclecountPosition`, `FixLocationAssignment`, `InventoryRecord`, `LocationConstraint`,
`LocationRackRow`, `LockOverviewAllDtoView`, `LockOverviewDtoView`, `LosSequencenumber`,
`MessageArchived`, `OrderDetailMonitorView`, `PickingorderPosition`, `PickingorderUnitload`,
`Queryrepository`, `ReceivedDtoView`, `ReplenishmentMonitorView`, `Shippingmethod`,
`ShippingmethodShipperid`, `UserGroupUserRole`, `UserRoleUserFunction`, `UserUserRole`.

Two of these produced non-zero hits on the HAL-rel pattern and were read individually rather than
trusted: `cyclecountPosition` (2) and `pickingorderPosition` (8) are **request-body and
response-property field names** on MVC endpoints (`cy.wms('POST','/cycleCountLos/countUnitLoad')`
bodies; `positionInfo.pickingorderPosition.amount` in `components/picking/rapid/scanSource.vue`),
not SDR reads. Both stay in this bucket.

**5 more where a mention exists but resolves to an MVC route, not the SDR path:**

| type | the mention | what it actually is |
|---|---|---|
| `Adviceposition` | `store/receiving/inboundNotices.js` — `const urlPart = '/advicepositionId=' + …` | a **query-string fragment**, not a path |
| `FlowbinMonitorView` | `store/reports/flowbin.js` — `$get('/report/flowbinMonitorView' + urlPart)` | MVC `ReportController`, not `/v3/flowbinMonitorView` |
| `Goodsreceipt` | `store/receiving/inboundNotices.js` — `$get('/goodsreceiptposition/search/…')` | substring collision with `goodsreceiptposition` |
| `OrderMonitorView` | `store/dashboard/pickpackMonitor.js` — `$get('/dashboard/orderMonitorViewSummary')` | MVC `DashboardController` |
| `ParcelMonitorView` | `cypress/e2e/wms/club/club-line-order.cy.js` — `path: '/report/parcelMonitorView'` | MVC `ReportController` |

⚠ **The three join tables in this bucket are already `SdrFunctionRules` entries.**
`UserGroupUserRole`, `UserRoleUserFunction` and `UserUserRole` carry `USER_ADMIN_VIEW` rules today,
added by SBDEV-3169 Slice 1 with an explicit note that no caller was found. This lane confirms that
finding with two more methods (C and D, neither used by the Slice 1 lane). Un-exporting them is
strictly better than gating them — an un-exported path cannot be over-gated, mis-ruled, or re-opened
by a rule-table edit — and `SdrFunctionRules`' own comment says so.

### B.6 The two Cypress-only types

| type | caller | note |
|---|---|---|
| `CustomerorderBatch` | `cypress/e2e/wms/smoke/_foundation.cy.js` — `cy.wms('GET', '/customerorderBatch', { qs: { size: 1 } })`, asserting *"authenticated GET /customerorderBatch returns 200"* | the only app-code reference, `store/outbound/club.js`, is **commented out** |
| `Pickingorder` | `cypress/e2e/wms/smoke/phase2-pick.cy.js` — `'/pickingorder/search/findByNumber?number=' + …` | no app caller |

Un-exporting either **breaks the Cypress smoke suite**, and `_foundation.cy.js` asserts the 200
explicitly as a foundation check. Gating them breaks it too unless the Cypress test user holds the
function. Neither is a production caller. Recommend: un-export, and update the two specs in the same
change — but this is a decision for the ticket, not an inference I should make here.

---

## C. The 11 kept-writable resources

Runtime-derived (`writable` column of `sdr-surface-inventory.tsv`, `writableExportedResources=11`),
and the set matches the eleven named in `RestConfiguration`'s javadoc exactly.

| type | ruled today? | what writes it over SDR (caller citation) | read paths it exposes |
|---|---|---|---|
| `Section` | **no** | `store/masterData/section.js` — `this.$axios.delete('/section/' + data.section.id)` ⚠ the `$axios.delete` form that SBDEV-3157's first regex missed | collection, item, 3 searches |
| `Advice` | **no** | `store/receiving/inboundNotices.js` — `` $delete(`/advice/${…id}`) `` and `` $patch(`/advice/${data.id}`, data) ``; Cypress `cy.wms('PATCH', '/advice/' + adviceId, …)` | collection, item, 4 searches — **no SDR read caller in app code** |
| `Boxtype` | **no** | `store/masterData/packaging.js` — `` $put(`/boxtype/${…}`) `` and `` $delete(`/boxtype/${…}`) `` | collection, item, 5 searches |
| `Client` | **no** | `store/admin/shippers.js` — `` $patch(`/client/${payload.id}`, payload) ``; **OMS** `WmsApiService.php` — `makeWmsRequest($fullUrl, $payload, 'PATCH', $facility, false)` with the comment *"a Spring Data REST entity resource takes one JSON object"* | collection, item, 12 searches |
| `Customerorder` | **no** | `store/common/order.js` — `` $patch(`/customerorder/${…}`) `` | collection, item, 21 searches |
| `Cyclecount` | **no** | `store/internalOps/cycleCount.js` — `` $patch(`/cyclecount/${…}`) ``; Cypress `cy.wms('PATCH', '/cyclecount/' + cycleCountId, …)` | collection, item, 10 searches — **no SDR read caller in app code** |
| `Location` | **no** | `store/masterData/storageLocation.js` — `$delete('/location/' + data.location.id)` | collection, item, 18 searches |
| `LocationType` | **no** | `store/masterData/locationType.js` — `` $delete(`/locationType/${…}`) `` | collection, item, 1 search |
| `Sysprop` | **no** | `store/admin/configuration.js` — `` $put(`/sysprop/${…}`) `` and `` $delete(`/sysprop/${…}`) ``; `store/admin/management.js` — `$put('/sysprop/'…)` | collection, item, 9 searches |
| `UserGroup` | **YES** (`USER_ADMIN_VIEW`) | `store/admin/group.js` — `$put('/userGroup' + urlPart, data)`. Item `PATCH`+`DELETE` are withdrawn by `configureRoleFunctionWriteExposure`, **not** by the `SDR_WRITE_WITHDRAWN` array — collection `POST` and item `PUT` remain | collection, item, 4 searches, association `/{id}/roles` |
| `UserRole` | **YES** (`USER_ADMIN_VIEW`) | `store/admin/role.js` — `$put('/userRole' + urlPart, data)`. Same split withdrawal as `UserGroup` | collection, item, 4 searches, association `/{id}/functions` |

**9 of 11 are unruled.** Every one of the nine is a master-data or operational table whose *reads*
are currently open to any authenticated `wms_user`, including `Sysprop` (the whole configuration
surface, 9 searches) and `Client` (the customer list). `Advice` and `Cyclecount` are the two where a
read rule would cost nothing today — they have SDR writers but **no SDR read caller in app code**,
so a rule on them denies no working screen.

---

## D. The OMS caller set — measured, not restated

Derived from `v2/oms-laravel-api` at `origin/develop` `f1ad0f43`. The working checkout was 5 commits
behind; this is the failure mode that produced a published false claim on SBDEV-3157 (a tree 838
commits behind made *"OMS's SDR use is reads only"* look true).

### D.1 The measurement

`config/wms.php` declares **11** `v3/*` endpoints. Every one was checked for a live caller in `app/`
(`git grep '<key>' origin/develop -- app/`); all 11 have one.

| config key | URL | resolves to | verb | caller |
|---|---|---|---|---|
| `client_create` | `v3/client/create` | **MVC** `ClientController` `@RequestMapping("/v3/client")` | POST | `WmsApiService.php:3117`, `:3677` |
| `shipperid_create` | `v3/shipperId/create` | **MVC** `ShipperIdController` `@RequestMapping("/v3/shipperId")` | POST | `WmsApiService.php` |
| `boxtype_create` | `v3/boxType/create` | **MVC** `BoxTypeController` `@RequestMapping("/v3/boxType")` | POST | `WmsApiService.php` |
| `client_find_by_number` | `v3/client/search/findByClNr` | **SDR search** | GET | `WmsApiService.php` |
| `client_list` | `v3/client` | **SDR collection** | GET | `WmsFacilitySyncService.php` ×4 |
| `itemdata_list` | `v3/itemdata` | **SDR collection** | GET | `WmsFacilitySyncService.php` ×2 |
| `shipperid_list` | `v3/shipperid` | **SDR collection** | GET | `WmsFacilitySyncService.php` |
| `boxtype_list` | `v3/boxtype` | **SDR collection** | GET | `WmsFacilitySyncService.php` |
| `itemdata_by_client` | `v3/itemdata/search/findByClientId` | **SDR search** | GET | `WmsFacilitySyncService.php` |
| `client_update` | `v3/client/{id}` | **SDR item** | **PATCH** | `WmsApiService.php` |
| `printer_search_by_type` | **default** `rest/printer/findByType` | **MVC**, `/rest` tier | GET | `WmsApiService.php` |

The camelCase/lowercase split is what separates the three creates from the four list reads:
`/v3/shipperId` (controller) and `/v3/shipperid` (SDR) are different paths, verified against the
class-level `@RequestMapping` values on `origin/develop`.

### D.2 Verdict on the ticket's claim

> The ticket claims six SDR reads plus one write (`PATCH v3/client/{id}`).

**Confirmed for the default configuration**, and it is the same set `RestConfiguration`'s javadoc
records ("4 SDR collection reads and 2 SDR search reads"). The six: `v3/client`, `v3/itemdata`,
`v3/shipperid`, `v3/boxtype`, `v3/client/search/findByClNr`, `v3/itemdata/search/findByClientId`.
The one write: `PATCH v3/client/{id}`.

🟡 **One discrepancy to flag: there is a conditional seventh SDR read.**
`printer_search_by_type` defaults to the non-SDR `rest/printer/findByType`, but it is
`env('WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT', …)` and the config comment says to override it to
`v3/printer/search/findByType` *"for a WMS release that predates rest/printer/findByType"*. The
caller already handles both response shapes:

```php
// WmsApiService.php  getWmsPrinters()
// Bare list from rest/printer/findByType; HAL envelope from the v3 SDR search.
$printers = $body['_embedded']['printer'] ?? (…array_is_list($body) ? $body : null);
```

So "six" is a statement about the **default config**, not about the code. If any facility carries
that env override, `Printer` becomes a seventh OMS-read SDR type and a rule on `Printer` breaks its
printer lookup. **I could not check deployed env values** — that requires the facility config, not
the repo. Flagging rather than resolving.

### D.3 The unanswered question this lane cannot close

OMS calls the `/v3` tier with *"the facility's configured Keycloak service token"*
(`config/wms.php`: `applyAuthentication` keys off the URL not containing `/rest/`). A
`SdrFunctionRules` entry on `Client`, `Itemdata`, `Shipperid` or `Boxtype` denies that principal
unless it resolves to a WMS user holding the function. **Nothing in either repo answers whether it
does.** Determining it needs a `los_user` / `los_usergroup` / `los_userfunction` query per tenant
against the service account's username — a DB step outside this lane's scope and a hard prerequisite
before any of those four types gets a rule.

Failure mode if this is wrong: OMS facility sync 403s. `WmsFacilitySyncService.php:145` uses
`client_list` as a **liveness probe** (`getFromWms($facilityCode, 'client_list', ['size' => 1])`),
so a denial there marks the whole facility unreachable — not one degraded read.

---

## E. What these methods cannot see

### E.1 The runtime enumerator UNDER-reports: association paths are absent

`SdrSurfaceInventoryContextTest` iterates `ResourceMappings` for collections and
`SearchResourceMappings` for searches. It emits **no association rows**, so `GET
/v3/<path>/{id}/<assoc>` appears nowhere in its 407-line output.

Filled by a separate instrument — `git grep '@ManyToMany' origin/develop -- src/main/java/.../model`
returns exactly **3** hits (`User.java`, `UserGroup.java`, `UserRole.java`), matching
`RestConfiguration`'s independently-written claim that SDR generates *"exactly THREE association
resources repo-wide — User.groups, UserGroup.roles, UserRole.functions"*. Everything else in this
model uses manual FK columns, so `isAssociation()` is false and no association resource exists.

**All three have live callers**, and Method B found them only because the axios pattern matched the
template literal:

- `store/admin/user.js` — `` $get(`/user/${data.userId}/groups`) ``
- `store/admin/group.js` — `` $get(`/userGroup/${data.groupId}/roles`) ``
- `store/admin/group.js` — `` .map((r) => this.$axios.$get(`/userRole/${r.id}/functions`)) ``

Blind spot of *this* correction: `@ManyToMany` is the only association mapping style in this repo
today. Adding a `@OneToMany` with an exported target would create an association resource the grep
does not match. The grep is a snapshot of a convention, not a proof.

### E.2 The runtime enumerator OVER-reports: exactly one exported path is shadowed by MVC

`RepositoryRestHandlerMapping` sits behind `RequestMappingHandlerMapping`, so an MVC mapping at the
same path wins and the SDR route is unreachable. Measured across all 62 SDR paths against the 755
`/v3/**` MVC paths from `surface-inventory.tsv`: **one** collision, and **zero** on any search path.

```
GET /v3/user  →  RequestMappingHandlerMapping  →  TokenController#user()
```

Precedence verified at runtime, not assumed (§E.3): `RequestMappingHandlerMapping` order **0**,
SDR's `DelegatingHandlerMapping` order **2147483547**. The probe also confirmed the negative —
`/v3/userGroup`, `/v3/section`, `/v3/printer`, `/v3/client` all resolve to
`RepositoryEntityController#getCollectionResource`.

🔴 **This shadow has a live consequence that appears to be an open bug, reported as an observation
rather than a verdict — I did not run the screen.** `wms2-web-ui/store/admin/management.js`
`getUsers` sets `const urlPart = '';`, calls `$get('/user' + urlPart)` — so exactly `/v3/user` — and
then reads `results._embedded.user`. `TokenController#user` returns
`SecurityContextHolder.getContext().getAuthentication().getPrincipal()`, a bare principal with no
`_embedded` key, so that property read throws and the `catch` fires `logApiFailure('getUsers
failed')` plus a generic error toast. The code expects the SDR HAL envelope it cannot reach. If
confirmed, this is a defect independent of SBDEV-3183 and belongs on its own ticket.

For SBDEV-3183 the operative point is narrower: **a rule or un-export on the `User` *collection*
changes nothing observable**, because no request reaches it. `User`'s item and association paths are
a different matter and are correctly ruled today.

### E.3 The precedence probe (deleted after use, reproduced for repeatability)

Written into the throwaway worktree at `origin/develop`, run, then removed. It does not exist on any
branch.

```java
List<HandlerMapping> hms = new ArrayList<>(ctx.getBeansOfType(HandlerMapping.class).values());
hms.sort(OrderComparator.INSTANCE);
MockHttpServletRequest req = new MockHttpServletRequest("GET", path);
req.setRequestURI(path);
for (HandlerMapping hm : hms) {
    HandlerExecutionChain c = hm.getHandler(req);
    if (c != null) { /* first non-null wins */ break; }
}
```

Blind spot: `MockHttpServletRequest` exercises mapping, not the filter chain. It says which handler
*would* serve the path; it does not prove the request survives `FunctionGuardInterceptor`,
`TenantFilter`, or Spring Security.

### E.4 Blind spots of the caller sweep

- **Computed URLs.** Method B keys on a literal starting with `/` on the call line. A URL assembled
  in a variable and passed as `$axios.$get(url)` is invisible to it. Method C (all-file substring)
  partially covers this, which is why every SAFE TO UN-EXPORT row cites both.
- **`git grep`, not ripgrep, throughout.** `wms2-web-ui/.gitignore` hides a `reports/` tree of ~34
  files from ignore-aware tools; index-based `git grep` sees them. Any row here re-derived with
  `rg` may differ.
- **Only two UI repos plus OMS were swept.** A caller in `v1/*`, in an ops script, in a Postman
  collection, or in a customer integration is outside every method used. "No caller found by A/B/C/D
  in `wms2-web-ui`, `wms2-mobile-ui` and `oms-laravel-api` at `origin/develop`" is the claim; "no
  caller exists" is not.
- **Static analysis only — no traffic.** Nothing here is derived from access logs or a live probe.
  A path with no source-code caller can still be receiving production traffic from a bookmark, a
  script, or an integration. An access-log check over a representative window would be the decisive
  second instrument for the SAFE TO UN-EXPORT bucket and was not available to this lane.
- **`H2` context, not PostgreSQL.** Both inventory tests boot `BaseRollbackIntegrationTest`, which
  runs on in-memory H2 with `ddl-auto=create-drop` and Flyway disabled. The SDR *mapping* is derived
  from repository interfaces and `RestConfiguration`, neither of which depends on the dialect, so
  the surface is dialect-independent. Anything data-shaped is not measured here at all.
- **No DB verification in this lane.** The five-item floor requires one DB query confirming the
  symptom. This lane measures a code surface, so the DB step lands on whichever lane sizes the
  exposed row counts and on the §D.3 service-account question — it is not satisfied by this file.

---

## F. Where the instruments disagreed

Recorded because a disagreement is itself a finding, not something to resolve silently.

| # | disagreement | resolution |
|---|---|---|
| 1 | `RestConfiguration` javadoc + SBDEV-3169 plan say **347** searches / **409** read paths; runtime says **336** | **Unresolved.** The repository package is byte-identical between the commit that wrote 347 and `origin/develop`, so this is not drift. Use 336; re-derive anything sized off 409 |
| 2 | `RestConfiguration` javadoc says the withdrawal array covers **48** resources; the array holds **47** | Array wins (47). Reconciles with runtime: 62 − 47 = 15 declared-writable, 11 actually writable, the 4-way gap being `configureRoleFunctionWriteExposure` — **two** withdrawal mechanisms, not one |
| 3 | Runtime inventory says the exported surface is 62 collections + 336 searches; the *reachable* surface is one path smaller | `GET /v3/user` is shadowed by `TokenController#user` (runtime-verified precedence). Exactly 1 over-report, 0 on search paths |
| 4 | Runtime inventory emits no association paths; grep + javadoc say 3 exist, all with live callers | Runtime **under**-reports by 3. Both directions of error are present in the same instrument |
| 5 | Method A/C flagged `customerorderBatch` + `pickingorder` as callerless; Method D found Cypress callers | Method D added *because* of this. Two methods would have mis-bucketed both into SAFE TO UN-EXPORT |
| 6 | Method B's first pass called `/advice/acceptHubAndSpokeBol/`, `/message/resend` and `/user/isOmsUser/` SDR | All three wrong — two MVC routes and one **commented-out line**. Regex truncation at `${`/`+` and no comment filter. Every ambiguous row was then read individually |

---

## G. Summary

- **62** exported domain types (runtime ×2 + grep, all agreeing); 8 more registered but not exported.
- **62** collection + **62** item + **336** search + **3** association exported read paths. The
  documented "409" does not reproduce.
- **29** types have a live SDR read caller in app code; **2** more only a Cypress caller; **2** have
  SDR writers but no SDR reader; **29** have no caller by four independent methods.
- **23** types are cleanly gateable on an existing screen function — **10** types overall need a
  union or a per-search override, and `SdrFunctionRules` already ships the override mechanism for
  the 4 that split cleanly on the search path.
- **6** types must stay open or get an explicit decision: 4 OMS service-token reads
  (`Client`, `Itemdata`, `Shipperid`, `Boxtype`) and 2 mobile reads (`Section`, `Stockunit`).
- **9 of the 11** kept-writable resources have **no read rule at all** today, including `Sysprop`
  and `Client`.
- Hard prerequisite before ruling any OMS-read type: establish what functions the facility Keycloak
  service account holds (§D.3). `client_list` doubles as OMS's facility liveness probe, so a denial
  there fails the whole facility, not one read.

Raw artifacts in this directory: `sdr-surface-inventory.tsv` (runtime SDR surface),
`callsites.tsv` (434 extracted axios call sites, both UIs), `resolved.txt` (per-call-site SDR/MVC
resolution).
