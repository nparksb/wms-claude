---
title: SBDEV-3183 — caller sweep for the 15 still-unruled SDR domain types
date: 2026-10-20
ticket: SBDEV-3183
kind: evidence (read-only research; no repo file edited, no Maven run)
---

# SBDEV-3183 — who calls the SDR surface of the 15 unruled types

## Sources (all read at `origin/develop` after `git fetch -q origin`, never the working tree)

| Repo | Ref | SHA | Commit date |
|---|---|---|---|
| `v2/wms2-api` | origin/develop | `a49e6ebd2c67dabd37c3c721fdccdd0ef2991f80` | 2026-10-20 16:35 -0400 |
| `v2/wms2-web-ui` | origin/develop | `add0628fc5e68c55157a2409a81b7ff34e4e6eb7` | 2026-10-16 08:52 -0400 |
| `v2/wms2-mobile-ui` | origin/develop | `f51dc6c542c484fa3c7a900fcab3c013cc23726b` | 2026-10-16 15:06 -0400 |
| `v2/oms-laravel-api` | origin/develop | `39bdd0310acdeef305d1144fe09f4c48be35b595` | 2026-10-20 13:48 -0400 |
| `v2/siteboss-frontend` (extra check, not in brief) | origin/main | `15909e56b8fbb101dc31c2b4a460aeba66219ea7` | — |

The UI and OMS trees were extracted with `git archive origin/develop | tar -x` into a scratch directory and swept there.

## Facts that hold for all 15 types

- **Base path `/v3`** (`RestConfiguration.MY_BASE_URI_URI`). Detection strategy is `ANNOTATED`.
- **All 15 types are in `configureUnwrittenResourceWriteExposure`** (SBDEV-3157). Its loop disables `WRITE_VERBS` at collection, item and association level for every type in the array. That array includes all 15 types (Goodsreceiptposition, Itemunit, LocationArea, LocationRack, LocationType, LockOverviewAllDtoView, LockOverviewDtoView, Printer, ReceivingDtoView, Replenishorder, StockView, Unitload, UnitloadRecord, UnitloadType, ViewWarehouseLocationReport). So **the exposed SDR surface is read-only**: collection `GET/HEAD/OPTIONS`, item `GET/HEAD/OPTIONS`, and `GET /search/<name>`. Exception: StockView's `findAll` overloads are `exported=false`, so its collection resource answers `OPTIONS` only and its item `GET` still works. This agrees with `sdr-surface-inventory-4ce87ead.tsv`; I re-derived it from source at `a49e6ebd`.
- **No-annotation query methods are exported under their method name**: Goodsreceiptposition `findByAdvicepositionIdIn` and `countByGoodsreceiptId`, Replenishorder `findByStateAndItemdataId` and `findDetailMapById`, Unitload `findByStoragelocationIdIn`. They are listed below.
- **SDR paths are case-sensitive.** The camel-cased MVC prefixes `/v3/unitLoad`, `/v3/replenishOrder` and `/v3/goodsReceiptPosition` are different handlers and are **not** SDR callers. The mobile app uses only these camel-cased paths.
- **Rule semantics** (`SdrFunctionRules`): one `Set<String>` per domain type, read as any-of. Optional `SearchOverrideKey(domainType, searchPath)` entries take precedence for that search. Collection and item GETs always fall to the base rule.
- **Mobile UI: zero SDR callers for all 15 types.** The only matches are `/unitLoad/search/findByItemForReplenish` and `/replenishOrder/detailView`, both MVC. `UnitLoadController:296-297` is `@RequiresFunction(MOBILE_UI_VIEW_REPLENISHMENT)` and `ReplenishOrderController` is `/v3/replenishOrder`.
- **OMS: zero live SDR callers for all 15 types.** The only reference is a latent, env-switchable Printer override (see Printer). `config/wms.php`'s `unitload_state` is `rest/unitload/state/{label_id}`, which is the `/rest` integration surface, not `/v3` SDR.
- **siteboss-frontend: zero matches** for any of the 15 paths.

---

## 1. Goodsreceiptposition — `/v3/goodsreceiptposition`

**Exported searches:** `findByAdvicepositionId(advicepositionId)`, `findByGoodsreceiptId(goodsReceiptId)`, `generatePositionCountStringByGoodsreceiptId`, `findByUnitloadId`, `getDetailViewByAdvicePositionId`, `findByAdvicepositionIdIn` (no annotation), `countByGoodsreceiptId` (no annotation). `findPrintableUnitLoadIds` is exported=false.
**Verbs:** collection GET, item GET, searches. Writes are withdrawn.
**MVC sharing the prefix:** none. `GoodsReceiptPositionController` is `/v3/goodsReceiptPosition`, a different case, so it does not collide.

| # | Repo / file | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/receiving/inboundNotices.js:349`, action `getGoodsReceiptPositions` | `this.$axios.$get('/goodsreceiptposition/search/findByAdvicepositionId' + urlPart)` | GET search `findByAdvicepositionId` (see ⚠) | `components/receiving/open/openNoticeTable.vue:235`; `components/receiving/closed/closedNoticeTable.vue:130`; `store/receiving/receive.js:92` (`receiveInboundItems`, dispatched by `receivingForm.vue:593`); in-module `deleteGoodsReceiptPosition` (`deleteOpenNoticeReceipt.vue:67`) and `adjustGoodsReceiptPosition` (`adjustAmountOpenNoticeReceipt.vue:80/82`) | `/receiving/inbound-notices` (menu) → `WEB_UI_VIEW_INBOUND_BOL`; `/receiving/openNotice/:id`, `/receiving/closedNotice/:id`, `/receiving/openNotice/receive` (EXTRA_ROUTES) → `WEB_UI_VIEW_INBOUND_BOL` | **live dispatch, malformed URL** |

⚠ **The live caller's URL is malformed and has been since the initial check-in** (`3462148`, 2024-07-16). `urlPart = '/advicepositionId=' + data.advicePositionId` produces `/v3/goodsreceiptposition/search/findByAdvicepositionId/advicepositionId=123`, a slash where a `?` belongs. That 4-segment path cannot match SDR's search mapping. It plausibly matches the property-reference shape `/{repository}/{id}/{property}/{propertyId}` with `id="search"`, so it most likely errors (404/400/500) and never returns rows. I did not probe it. Either way, the guard sees `{repository}=goodsreceiptposition` and no `{search}` variable, so **the base rule governs it, not a search override**. This is a separate UI bug: candidate finding for the current ticket.

**Cypress:** none. **Jest:** none. **OMS/mobile:** none.

**Proposed rule:** `Goodsreceiptposition → {WEB_UI_VIEW_INBOUND_BOL}`.

---

## 2. Itemunit — `/v3/itemunit`

**Exported searches:** `findByUnitname(unitname)`. **Verbs:** collection GET, item GET, search.
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/masterData/skuUnit.js:51`, `getSkuUnits` | `this.$axios.$get('/itemunit' + urlPart)` | GET collection | `components/masterData/material/skuUnits/skuUnit.vue:236` (mounted) | `/masterData/materialData/sku-units` → `WEB_UI_VIEW_ITEM_UNIT` | live |
| 2 | web-ui `store/masterData/packaging.js:78`, `getItemUnitTypes` | `this.$axios.$get('/itemunit')` | GET collection | `components/masterData/material/packaging/editPackagingDialog.vue:96` (`show` watcher) in `packaging.vue` | `/masterData/materialData/packaging` → `WEB_UI_VIEW_CASE_TYPE` | live |

**Cypress/OMS/mobile:** none.

**Proposed rule:** `Itemunit → {WEB_UI_VIEW_ITEM_UNIT, WEB_UI_VIEW_CASE_TYPE}`.

---

## 3. LocationArea — `/v3/locationArea`

**Exported searches:** `findByClientIdAndName`, `findByName`. **Verbs:** collection GET, item GET, searches.
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/masterData/functionalArea.js:51`, `getFunctionalAreas` | `this.$axios.$get('/locationArea' + urlPart)` | GET collection | `components/masterData/location/functionalArea/functionalArea.vue:205` | `/masterData/locationData/functional-areas` → `WEB_UI_VIEW_AREA` | live |
| 2 | web-ui `store/internalOps/createCc.js:55`, `getFunctionalAreas` | `this.$axios.$get('/locationArea')` | GET collection | `components/internalOps/cycleCount/planned/create/createCycleCount.vue:93` (`show` watcher) ← `plannedCycleCount.vue` | `/internalOps/cycle-count` → `WEB_UI_VIEW_CYCLECOUNT` | live |

**Cypress:** `cypress/support/helpers/wmsHelpers.js:880` `cy.wms('GET', '/locationArea')`; `cypress/e2e/wms/cycle-count/cycle-count.cy.js:192-193`. Test token needs CYCLECOUNT or AREA. **OMS/mobile:** none.

**Proposed rule:** `LocationArea → {WEB_UI_VIEW_AREA, WEB_UI_VIEW_CYCLECOUNT}`.

---

## 4. LocationRack — `/v3/locationRack`

**Exported searches:** `findByName`. **Verbs:** collection GET, item GET, search.
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/masterData/storageLocation.js:106`, `getLocationRacks` | `this.$axios.$get('/locationRack')` | GET collection | **nothing**. `getLocationRacks` appears only at its own definition (no component, no in-module dispatch, no mapActions) | — | **dead** |

**Cypress/OMS/mobile:** none.

**Proposed rule:** no live caller, so nothing can break. Proposed `LocationRack → {WEB_UI_VIEW_STORAGE_LOCATION}`: it owns the dead action's store module and matches the existing `Location` rule. An alternative is to withdraw the type from export entirely, which is a separate decision.

---

## 5. LocationType — `/v3/locationType`

**Exported searches:** `findBySltname`. **Verbs:** collection GET, item GET, search. Item DELETE is withdrawn and answers 405.
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/masterData/locationType.js:51`, `getLocationTypes` | `this.$axios.$get('/locationType' + urlPart)` | GET collection | `components/masterData/location/locationTypes/locationType.vue:208`; in-module follow-ons from `createLocationType` (:70), `updateLocationType` (:89) and `deleteLocationType` (:112), none of which is dispatched anywhere | `/masterData/locationData/location-types` → `WEB_UI_VIEW_STORAGE_LOCATION_TYPE` | live (via locationType.vue only) |
| 2 | web-ui `store/masterData/locationType.js:109`, `deleteLocationType` | `this.$axios.$delete('/locationType/' + data.id)` | DELETE item | **nothing dispatches it** | — | **dead**, and already 405 because writes are withdrawn |

Not callers: `layouts/default.vue:444` and `pages/masterData/locationData/location-types.vue:17-18` are store **commits** (`masterData/locationType/setList`), not HTTP calls. `storageLocation.vue:226` is a table column key.

**Cypress/OMS/mobile:** none. (OMS `locationType` hits are FedEx/BoxCheck payload keys, unrelated.)

**Proposed rule:** `LocationType → {WEB_UI_VIEW_STORAGE_LOCATION_TYPE}`.

---

## 6 + 7. LockOverviewDtoView — `/v3/lockOverviewDtoView`; LockOverviewAllDtoView — `/v3/lockOverviewAllDtoView`

**Exported searches (both):** `findByKeyword(keyword, clientNumber, Pageable)`. `findByClientOffsetAndLimit` is exported=false. **Verbs:** collection GET, item GET, search. The repository is ReadOnly.
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/reports/lock.js:56/64`, `searchReport` (**computed URL**) | `const resource = data.includeShipped ? 'lockOverviewAllDtoView' : 'lockOverviewDtoView'` … `this.$axios.$get('/' + resource + '/search/findByKeyword' + urlPart)` | GET search `findByKeyword` on **either** type | `components/reports/lockReport.vue:399` | `/reports/lock-report` → `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | live (both types; the toggle picks one) |

`lock.js` `export` posts to `/report/exportLock`, which is MVC and not SDR.
**Cypress/OMS/mobile:** none.

**Proposed rule:** both types → `{WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW}`. They must be ruled together, or the "Include Shipped Locks" toggle breaks on one side.

---

## 8. Printer — `/v3/printer`

**Exported searches:** `findByTypeAndProcessdefaultTrue(type)`, `findAllTypeAndProcessdefaultTrue(type, id)`, `findByType(type)`. **Verbs:** collection GET, item GET, searches.
**MVC sharing the prefix — `PrinterController @RequestMapping("/v3/printer")`.** Its subpaths are MVC and are not SDR callers:

| Subpath | Gate |
|---|---|
| `/getTypes`, `/create`, `/update`, `/delete/{printerId}`, `/testPrinter`, `/printerDetailsById/{id}`, `/defaultPrintersByType/{type}/{id}` | `WEB_UI_VIEW_PRINTER` |
| `/setDefault/{printerId}` | any-of `PRINTER`, `CLIENT` |
| `/printLabel/{labelKey}` | `SYSTEM_PROPERTY` |
| `/outboundTotePrinters` | any-of `PRINTER`, `ORDER_MONITOR` |
| `/inboundPrinters` | any-of `PRINTER`, `CONTAINER`, `CLUB_LINE`, `TRANSFER_ORDER` |

Also `LabelPrintingController /printers` (MVC) and `PrinterRestController @RequestMapping("/rest/printer")` `/findByType`, an unauthenticated integration route outside SDR.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/admin/printer.js:36`, `getPrinters` | `this.$axios.$get('/printer')` | GET collection | `components/admin/printerSetup/printerSetup.vue:217`; in-module follow-ons after `updatePrinter`/`savePrinter` (`editPrinter.vue:155/159`), `deletePrinter` (`deletePrinterPop.vue:59`) and `setDefault` (`printerSetup.vue:223`) | `/admin`, Printer Setup tab → `WEB_UI_VIEW_PRINTER` | live |
| 2 | same action | (same) | GET collection | `components/admin/userManagement/users/editUser.vue:121` (`itemToEdit` watcher) ← `user.vue` ← `userManagementMain.vue` | `/admin`, User Management tab → `WEB_UI_VIEW_USER_MANAGEMENT` | live |
| 3 | web-ui `store/admin/printer.js:171`, `getPrintersByType` | `this.$axios.$get('/printer/search/findByType' + urlPart)` | GET search `findByType` (`type=INBOUND`) | `components/receiving/open/openNoticeTable.vue:273` | `/receiving/inbound-notices`, `/receiving/openNotice/:id` → `WEB_UI_VIEW_INBOUND_BOL` | live |
| 4 | same action | (same) | GET search `findByType` (`INBOUND`) | `components/admin/shippers/editShipper.vue:175`, `addShipper.vue:77` ← `shipperList.vue` | `/admin`, Shippers tab → `WEB_UI_VIEW_CLIENT` | live |
| 5 | web-ui `store/reports/parcelPicking.js:116`, `getPrinters` | `this.$axios.$get('/printer/search/findByType?type=OUTBOUND_TOTE')` | GET search `findByType` | `components/reports/parcelPickingReport.vue:451` (`reprintLabels`) | `/reports/parcel-picking-report` → `WEB_UI_VIEW_PARCEL_PICKING` | live |
| — | web-ui `components/admin/shippers/shipperList.vue:180`, method `setDefault(shipper)` | `dispatch('admin/printer/setDefault', { id: shipper.id })` | would reach MVC setDefault, then GET collection | **no template reference to the method**. It also passes `id`, not `printerId`, so the URL would be `/printer/setDefault/undefined` | — | **dead** |

**MVC-only web-ui calls (not SDR):** `/printer/update`, `/printer/create`, `/printer/delete/…`, `/printer/setDefault/…`, `/printer/testPrinter`, `/printer/printerDetailsById/…` (`store/admin/printer.js`), `/printer/printLabel/…` (`admin/configuration.js:245`), `/printer/outboundTotePrinters` (`dashboard/pickpackMonitor.js:133`), `/printer/inboundPrinters` (`handlingUnits/container.js:238`).

**Cypress (SDR):**
- `wmsHelpers.js:447` `GET /printer/search/findByType`; `:1252` `GET /printer`.
- `cross-cutting.cy.js:87-115` (findByType BOX/LABEL); `admin.cy.js:392-399` (findByType INBOUND), `:749` (`GET /v3/printer`).

**⚠ OMS — latent caller.** `oms-laravel-api/config/wms.php:228`:

```
'printer_search_by_type' => env('WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT', 'rest/printer/findByType')
```

The default is the MVC `/rest` route, not SDR. The comment at `:224-227` and `WmsApiService::getWmsPrinters` (`:3018-3047`) explicitly keep an env override to `v3/printer/search/findByType` for "a WMS release that predates rest/printer/findByType". The default has been `rest/…` since `c944f4bd` (2026-07-28, oms #259). **If any OMS deployment sets `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT=v3/…`, the OMS S2S identity becomes an SDR `findByType` caller.** That identity holds no WEB_UI functions, so the override below would deny it. I cannot see deployed env from the repo. **Check the OMS deploy env for that variable before enforcing.** Mobile: none.

**Proposed rule (base + one override):**
- `Printer → {WEB_UI_VIEW_PRINTER, WEB_UI_VIEW_USER_MANAGEMENT}`. Covers collection GET rows 1–2, plus item GET and the two uncalled searches.
- Override `(Printer, "findByType") → {WEB_UI_VIEW_PRINTER, WEB_UI_VIEW_INBOUND_BOL, WEB_UI_VIEW_CLIENT, WEB_UI_VIEW_PARCEL_PICKING}`. Covers rows 3–5. `PRINTER` is kept so Printer Setup users and the Cypress helpers are not narrowed.
- A single any-of union of all five functions on the base rule also works, but it opens the full printer collection to INBOUND_BOL, CLIENT and PARCEL_PICKING holders. The override form is tighter.

---

## 9. ReceivingDtoView — `/v3/receivingDtoView`

**Exported searches:** `findByAdvicenumber(adviceNumber)`, `findByAdvicepositionid(positionId)`, `findByKeyword(keyword, clientNumber, Pageable)`. `findByClientOffsetAndLimit` and `getQtyByAdvicenumber` are exported=false. **Verbs:** collection GET, item GET, searches (ReadOnly).
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/receiving/inboundNotices.js:318`, `getReceivingByIbolNumber` | `this.$axios.$get('/receivingDtoView/search/findByAdvicenumber' + urlPart)` | GET search `findByAdvicenumber` | `components/receiving/open/openNoticeDescription.vue:133`, `closed/closedNoticeDescription.vue:227`; `store/receiving/createPo.js:123` (`updateInboundBol` ← `components/receiving/open/popups/addMissingSku.vue:242`); in-module follow-on from `getGoodsReceiptPositions` (:353), which is only reached on its error-free path and so is effectively unreachable (see §1 ⚠) | `/receiving/inbound-notices`, `/receiving/openNotice/:id`, `/receiving/closedNotice/:id` → `WEB_UI_VIEW_INBOUND_BOL` | live |
| 2 | web-ui `components/receiving/open/receive/receivingForm.vue:615`, method `updateQuantities` (component calls axios directly) | ``this.$axios.$get(`/receivingDtoView/search/findByAdvicepositionid${urlPart}`)`` | GET search `findByAdvicepositionid` | called at `receivingForm.vue:519` and `:602` ← `pages/receiving/openNotice/receive.vue` | `/receiving/openNotice/receive` (EXTRA_ROUTES) → `WEB_UI_VIEW_INBOUND_BOL` | live |
| 3 | web-ui `store/reports/receiving.js:61`, `searchReport` | `this.$axios.$get('/receivingDtoView/search/findByKeyword' + urlPart)` | GET search `findByKeyword` | `components/reports/receivingReport.vue:373` | `/reports/receiving-report` → `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | live |
| 4 | web-ui `store/reports/data.js:26`, `searchReport` | `this.$axios.$get('/receivingDtoView/search/findByKeyword' + urlPart)` | GET search `findByKeyword` | **nothing dispatches `reports/data/searchReport`**. Only `reports/data/export` is used (`exportReport.vue:165`), and no `pages/reports/data-report.vue` exists | — | **dead** |

**Cypress:**
- `wmsHelpers.js:187` (findByAdvicenumber), `:194` (findByAdvicepositionid).
- `scenario2/step2…:180`, `step3…:165`, `step4…:224`.
- `inbound-receiving.cy.js:397-402`.

Jest (`test/components/receiving/open/receive/receivingForm*.spec.js`) only mocks URLs containing `receivingDtoView`. **OMS/mobile:** none.

**Proposed rule (base + one override):**
- `ReceivingDtoView → {WEB_UI_VIEW_INBOUND_BOL}`. Covers `findByAdvicenumber` and `findByAdvicepositionid`, plus collection/item GET, which have no caller.
- Override `(ReceivingDtoView, "findByKeyword") → {WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW}`.
- Minimal any-of alternative: `{INBOUND_BOL, RECEIVED_STOCK_OVERVIEW}` on the base, with no override.

---

## 10. Replenishorder — `/v3/replenishorder`

**Exported searches:**
- Annotated: `findByStateLessThan`, `findByStateLessThanAndItemdataId`, `findByStateLessThanAndItemdataIdAndRequestedlocationId`, `findByStateLessThanAndRequestedlocationId`, `findByState`, `sumRequestedAmountForOpenOrders`, `findByStateLessThanEqualAndDestinationIdIsNull`, `findByStateLessThanAndPrioLessThanAndItemdataIdIn`, `getActiveByStateAndItemDataAndLocation`.
- Unannotated, so exported under the method name: `findByStateAndItemdataId`, `findDetailMapById`.
- Every other method is exported=false.

**Verbs:** collection GET, item GET, searches.
**MVC sharing the prefix:** none. `ReplenishOrderController` is `/v3/replenishOrder`, camel-cased, so it does not collide.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/internalOps/replenishments.js:192`, `getFullDetailRequest` | `this.$axios.$get('/replenishorder/' + data.id)` | GET **item** | `components/internalOps/replenishment/open/openRequest.vue:443` (stock-unit dialog), `:450` (`updatePriority`) | `/internalOps/replenishment` → `WEB_UI_VIEW_REPLENISHMENT_ORDER` | live |

**Cypress:**
- `wmsHelpers.js:778` `GET /replenishorder/{id}`.
- `replenishment.cy.js:262-263`, `:402-403`, `:997-998`.

**Mobile:** none. Mobile uses MVC `/replenishOrder/detailView` (`pages/replenish.vue:247`). **OMS:** none; the only hits are release-manifest prose.

**Proposed rule:** `Replenishorder → {WEB_UI_VIEW_REPLENISHMENT_ORDER}`.

---

## 11. StockView — `/v3/stockView`

**Exported searches:** `findByClientIdAndItemId`, `findByKeyword(keyword, clientNumber, Pageable)`. `findAll` ×3, `streamAllBy`, `stockHistoryAfterAsOfDate` and `findByClientOffsetAndLimit` are all exported=false. **Verbs:** collection resource is OPTIONS only (findAll unexported); item GET; searches.
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/reports/inventory.js:69`, `searchReport` | `this.$axios.$get('/stockView/search/findByKeyword' + urlPart)` | GET search `findByKeyword` | `components/reports/inventoryReport.vue:357` | `/reports/inventory-report` → `WEB_UI_VIEW_INVENTORY_RECORD` | live |

**Cypress:**
- `wmsHelpers.js:142`; `cross-cutting.cy.js:194`.
- `scenario2/step1:110,157`, `step3:300`, `step5:281`, `step6:238`.
- `inbound-receiving.cy.js:724`.

All are `findByKeyword`. **OMS/mobile:** none.

**Proposed rule:** `StockView → {WEB_UI_VIEW_INVENTORY_RECORD}`.

---

## 12. Unitload — `/v3/unitload`

**Exported searches:**
- Annotated: `findEmptyByStoragelocationId`, `findByStoragelocationId`, `findByCarrierunitloadId`, `findByLabelid`, `findByLabelidIn`, `findCountByCarrierunitloadId`, `findNameById`, `getBatchLocationsByItemIdAndLaneName`, `getBatchLocationsByItemIdAndTransferableAreas`, `findByCarrierunitloadIdIn`.
- Unannotated, so exported: `findByStoragelocationIdIn`.
- All others are exported=false.

**Verbs:** collection GET, item GET, searches.
**MVC sharing the prefix:** none. `UnitLoadController` is `/v3/unitLoad`, camel-cased. `ClubLineController`/`TransfersController` `/unitLoads` sit under their own class prefixes.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/handlingUnits/container.js:142`, `getChildContainers` | ``this.$axios.$get(`/unitload/search/findByCarrierunitloadId?carrierunitloadId=${data.carrierunitloadId}`)`` | GET search `findByCarrierunitloadId` | **only a commented-out dispatch** (`components/handlingUnits/containerTable.vue:474`, `// const resultList = await this.$store.dispatch(...)`) | — | **dead** |

Not callers:
- `components/admin/labelPrinting/unitLoadLabels.vue:85` and `labelCsvUpload.vue:109/115` are CSV column-name lists.
- `test/plugins/axios-redacts-bearer-token.spec.js` uses `/v3/unitload/1` as a fixture URL.

**Cypress (heaviest SDR user of this type):**
- `wmsHelpers.js:233` (item), `:238` (`findByLabelid`), `:249` (`findByStoragelocationId`).
- `scenario2/step3:205,226`, `step4:265`, `step5:114,214,314`.
- `smoke/phase2-pick:151`, `phase3-qa:129`, `phase4-palletize:126,147`, `phase6-truckload:120,135,139`, `phase7-bol-close:163-164`.

**OMS:** `rest/unitload/state/{label_id}` only, which is MVC `/rest` and not SDR. **Mobile:** none (MVC `/unitLoad/search/findByItemForReplenish`).

**Proposed rule:** no live UI caller. Proposed `Unitload → {WEB_UI_VIEW_STOCK_UNIT, WEB_UI_VIEW_CONTAINER}`, the Handling Units menu leaf's any-of. That is the screen family whose dead action this was. **Cypress smoke and scenario2 tokens must hold one of the two**, or those suites go red under enforcement.

---

## 13. UnitloadRecord — `/v3/unitloadRecord`

**Exported searches:** `findByKeyword(keyword, Pageable)`. `findByOffsetAndLimit`, `findRetireRecords` and `findRetireRecordsForLabels` are exported=false. **Verbs:** collection GET, item GET, search.
**MVC sharing the prefix — `UnitloadRecordController @RequestMapping("/v3/unitloadRecord")`:** `/unitloadRecordDetailsById/{id}` is `@RequiresFunction(WEB_UI_VIEW_UNIT_LOAD_RECORD)`, so that subpath is MVC and not SDR.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/reports/container.js:49`, `searchReport` | `this.$axios.$get('/unitloadRecord/search/findByKeyword' + urlPart)` | GET search `findByKeyword` | `components/reports/containerRecord.vue:293` | `/reports/container-record` → `WEB_UI_VIEW_UNIT_LOAD_RECORD` | live |
| — | web-ui `store/reports/container.js:96` | ``this.$axios.$get(`/unitloadRecord/unitloadRecordDetailsById/${data.id}`)`` | **MVC**, not SDR | (same screen) | (already gated UNIT_LOAD_RECORD) | n/a |

**Cypress/OMS/mobile:** none.

**Proposed rule:** `UnitloadRecord → {WEB_UI_VIEW_UNIT_LOAD_RECORD}`. This matches the MVC sibling's gate.

---

## 14. UnitloadType — `/v3/unitloadType`

**Exported searches:** `findByName`, `findNameById`. **Verbs:** collection GET, item GET, searches.
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/masterData/unitLoadType.js:51`, `getUnitLoadTypes` | `this.$axios.$get('/unitloadType' + urlPart)` | GET collection | `components/masterData/location/unitLoadTypes/unitLoadType.vue:243` | `/masterData/locationData/unit-load-types` → `WEB_UI_VIEW_UNIT_LOAD_TYPE` | live |
| 2 | web-ui `store/receiving/createPo.js:82`, `getUnitLoadTypes` | `this.$axios.$get('/unitloadType')` | GET collection | **nothing dispatches `receiving/createPo/getUnitLoadTypes`**. The only `getUnitLoadTypes` dispatch names the masterData module | — | **dead** |

**Cypress/OMS/mobile:** none.

**Proposed rule:** `UnitloadType → {WEB_UI_VIEW_UNIT_LOAD_TYPE}`.

**Dead caller not covered by the rule (r15 security review L4, 2026-10-21):** row 2, `receiving/createPo/getUnitLoadTypes` (`'/unitloadType'`), is not dispatched as of web-ui `origin/develop` `add0628`. If Create PO ever dispatches it, an INBOUND_BOL-only user is denied once the tenant enforces, so `WEB_UI_VIEW_INBOUND_BOL` must be added to the UnitloadType rule in the same change. The same note sits on the rule in `SdrFunctionRules.java`.

---

## 15. ViewWarehouseLocationReport — `/v3/viewWarehouseLocationReport`

**Exported searches:** `findByKeyword(keyword, clientNumber, Pageable)`, `findByLocation(locationId)`. `findByClientNameOffsetAndLimit` (path `findByClientOffsetAndLimit`) is exported=false. **Verbs:** collection GET, item GET, searches (ReadOnly).
**MVC sharing the prefix:** none.

| # | File | Snippet | Verb + path | Dispatched by | Route → function | Live? |
|---|---|---|---|---|---|---|
| 1 | web-ui `store/reports/skuLocation.js:69`, `searchReport` (inside a `latestRequest` thunk) | `() => this.$axios.$get('/viewWarehouseLocationReport/search/findByKeyword' + urlPart)` | GET search `findByKeyword` | `components/reports/skuLocationReport.vue:339` | `/reports/sku-location-report` → `WEB_UI_VIEW_LOCATION_OVERVIEW` | live |

**Cypress:** `wmsHelpers.js:286`; `scenario2/step6:106`; `inbound-receiving.cy.js:746`. **OMS/mobile:** none.

**Proposed rule:** `ViewWarehouseLocationReport → {WEB_UI_VIEW_LOCATION_OVERVIEW}`.

---

## Summary table

| Type | Live UI callers | Proposed rule | OMS / mobile |
|---|---|---|---|
| Goodsreceiptposition | inbound notices (the URL is malformed) | `{INBOUND_BOL}` | none |
| Itemunit | SKU Units, Packaging | `{ITEM_UNIT, CASE_TYPE}` | none |
| LocationArea | Functional Areas, Cycle Count create | `{AREA, CYCLECOUNT}` | none |
| LocationRack | **none** (dead action) | `{STORAGE_LOCATION}` (nothing to break) | none |
| LocationType | Location Types | `{STORAGE_LOCATION_TYPE}` | none |
| LockOverviewDtoView | Lock Report | `{STOCK_UNIT_LOCK_OVERVIEW}` | none |
| LockOverviewAllDtoView | Lock Report (toggle) | `{STOCK_UNIT_LOCK_OVERVIEW}` | none |
| Printer | Printer Setup, User Mgmt, Inbound Notices, Shippers, Parcel Picking report | base `{PRINTER, USER_MANAGEMENT}` + override `findByType → {PRINTER, INBOUND_BOL, CLIENT, PARCEL_PICKING}` | **OMS latent** via an env override to `v3/printer/search/findByType`; verify env |
| ReceivingDtoView | Inbound notices, receive screen, Receiving Report | base `{INBOUND_BOL}` + override `findByKeyword → {RECEIVED_STOCK_OVERVIEW}` | none |
| Replenishorder | Replenishment (open) | `{REPLENISHMENT_ORDER}` | none (mobile uses MVC camel path) |
| StockView | Inventory Report | `{INVENTORY_RECORD}` | none |
| Unitload | **none** (dead action) | `{STOCK_UNIT, CONTAINER}`; Cypress tokens need one | none (OMS uses `/rest`) |
| UnitloadRecord | Container Record | `{UNIT_LOAD_RECORD}` | none |
| UnitloadType | Unit Load Types | `{UNIT_LOAD_TYPE}` | none |
| ViewWarehouseLocationReport | SKU Location Report | `{LOCATION_OVERVIEW}` | none |

All function names are `WEB_UI_VIEW_*`. Each constant was confirmed present in `WmsConstants.FunctionEnum` at `a49e6ebd`.

Findings for the current ticket. None is filed and none is T3.
1. `inboundNotices.js:345` builds the `goodsreceiptposition` search URL with a `/` instead of a `?`, so the receipt-positions table probably never loads. It has been this way since 2024-07-16. Needs a dev probe.
2. Four store actions are dead and still carry SDR calls:
   - `storageLocation/getLocationRacks`
   - `locationType/deleteLocationType` (it also now 405s)
   - `handlingUnits/container/getChildContainers`
   - `receiving/createPo/getUnitLoadTypes`
3. `reports/data/searchReport` is dead.
4. `shipperList.vue:179` `setDefault` is a dead method that passes the wrong key.

---

## Method + blind spots

**API:**
- Found each type's repository with `git grep -lE '(Repository|JpaRepository|CrudRepository|PagingAndSortingRepository)<\s*<Type>\s*,'` on `origin/develop -- src/main/java`. Exactly one hit per type, all in `repo/jpa`.
- Dumped each repository's `@RepositoryRestResource`, `@RestResource` and method lines. Unannotated query methods are treated as exported under their method name.
- Read `RestConfiguration.java` in full for exposure (UNWRITTEN array, base path, detection strategy).
- Read `SdrFunctionGuard` and `SdrFunctionRules` for rule semantics.
- MVC prefix collisions: listed every `@{Request,Get,Post,Put,Patch,Delete}Mapping` string literal under `src/main/java`, stripped `/v3`, and filtered case-insensitively for the 15 names. Then confirmed class prefixes. Only `PrinterController` and `UnitloadRecordController` share an exact-case prefix.
- Cross-checked the search lists against `sdr-surface-inventory-4ce87ead.tsv`. They match.

**UIs:**
1. Literal sweep: case-sensitive string-context grep for each path name, preceded by `"`, `'`, `` ` `` or `/` and followed by `"`, `'`, `` ` ``, `/`, `?`, `#` or `$`. Covered `*.js|*.vue|*.ts|*.php|*.json` across web-ui (including `cypress/` and `test/`), mobile-ui and oms-laravel-api. This catches bare resource-name strings used in computed URLs (trap 2), e.g. `lock.js:56`.
2. Mobile was re-run case-insensitively. That surfaced only the camel-cased MVC paths, which were then confirmed against the API.
3. Multi-line calls (trap 1): a Python scanner found every `$axios.$get|post|put|patch|delete|request|head(`, `axios.<verb>(`, `cy.wms|request|intercept(` and `fetch(` call. It collapsed the next 220 characters of whitespace and then grepped them for the names. web-ui: 599 call sites; mobile: 100.
4. Listed every call whose first argument is not a string literal: `latestRequest.js`, `returnsAudit.js queryOf`, `labelPrinting.js print(url)`, `clubRuns.js loadDetailRows(url)`, `adjustmentAlerts.client.js`. Each was resolved by reading it; none targets the 15 types.
5. Checked for other HTTP clients (`$http`, `XMLHttpRequest`, `fetch`, `axios.create`) and for HAL `_links` link-following. The only `_links` uses are table `exclude-fields`.
6. `$delete` and `$axios.delete` are covered by the scanner regex (trap 5).

**Liveness (trap 4):**
- For each SDR-calling store action I grepped:
  - `'<ns>/<action>'` across `components pages layouts store mixins plugins`;
  - `mapActions('<ns>'`, of which there are none in the repo;
  - in-module `dispatch('<action>')`;
  - computed `dispatch(<non-literal>)`, which resolves to `returnsAudit` `${NS}` and `defaultPutawayLocationField` scope actions, both unrelated.
- An action with no hit is marked dead. Commented-out dispatches count as dead.

**Route mapping:**
- A script walked each dispatching component up to `pages/`/`layouts/` through both explicit imports and **Nuxt auto-import tag usage** (`components: true` in `nuxt.config.js`), matching bare and path-prefixed component names.
- The page route was then looked up in `util/appMenuList.js` (MENU `fn`, `EXTRA_ROUTES`). For `/admin`, the tab function comes from `pages/admin.vue` `TAB_FUNCTIONS`.

**OMS:** read `config/wms.php` endpoint keys and grepped `app/ routes/ config/` for `v3/`. Only `printer_search_by_type`'s env-override comment is relevant.

**Blind spots:**
- **Deployed environment is invisible.** The OMS `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT` value, and any other env override pointing a key at `v3/<one of the 15>`, cannot be seen from git. Every OMS endpoint key is env-overridable, so in principle any of them could be pointed at SDR. Only Printer's is documented as such.
- **Runtime-built paths** that split a resource name across concatenated literals (e.g. `'/unit' + 'load'`) would be missed. No such construction was found among the computed-URL sites.
- **External consumers** outside these five repos (scripts, Postman collections, BI tools, other services holding a Keycloak token) are not covered.
- The malformed Goodsreceiptposition URL's actual HTTP behaviour is inferred from SDR's mapping shapes, not probed.
- Liveness means a reachable dispatch exists in code. It does not prove a given role can open the dialog that triggers it; for example, the cycle-count create dialog may itself be action-gated. The any-of rules above are sized to the route's view function, which is a superset.
- web-ui Jest specs that mock these URLs (`receivingForm*.spec.js`, `axios-redacts-bearer-token.spec.js`) are not HTTP callers and were excluded.
