# SBDEV-3169 — SDR read caller enumeration

Derived from `origin/develop` of all three repos on **2026-08-29**. Commit SHAs:
- **wms2-web-ui** `cdaf9b0b66d4398db24360485ecc341145f4e0b6`
- **wms2-mobile-ui** `f42ac8d4ab1592b8d8e280a86ab15a22eedadca8`
- **oms-laravel-api** `fa030eda621b44dd78f29eaa394d52b91100430b`
- (cross-check only) **wms2-api** `793203997d85477eb1818d5d32817313db3517e2`

Input surface: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3157/target/sdr-surface-inventory.tsv`
— 418 rows, of which **409 are exported read paths** (62 COLLECTION + 347 SEARCH) across **62 domain types**.
The TSV contains **no ITEM and no association rows**; item reads (`/x/{id}`) are folded into the COLLECTION row.

---

## Method

**No working tree was read.** Each repo was materialised with
`git -C <repo> archive origin/develop | tar -x -C <scratch>/src/<repo>`, and every grep ran against that
extraction. `git archive` emits the full tracked tree, so the `.gitignore`d `reports/` trap does not apply:
I confirmed all **31** `store|components|pages/reports/*` files are tracked in `origin/develop` and present
in the extraction, and every grep used `command grep` (never the shell `grep` function, never an
ignore-aware tool).

Four passes:

1. **Exact search-path sweep (measured, 347/347).** Every exported SEARCH path was fixed-string
   (`grep -F`) matched across all three trees. 36 paths produced at least one hit.
2. **Dynamic-URL sweep.** Templating and concatenation defeat a fixed-string grep, so I extracted every
   string/backtick literal beginning with `/` from all `.js`/`.vue`, filtered to the 62 SDR segments, and
   separately listed every `$axios.$?(get|post|put|patch|delete|head)(…)` call whose first argument is **not**
   a leading-`/` literal (10 such sites) and read each one. This is what caught
   `store/reports/lock.js:64` — `'/' + resource + '/search/findByKeyword'` with
   `resource = includeShipped ? 'lockOverviewAllDtoView' : 'lockOverviewDtoView'` — which pass 1 missed.
   The 10 non-literal call sites all resolve to custom controllers (`/itemData/…`, `/putawayConfig/…`,
   `/replenishOrder/detailView`, `/dashboard/…`, `/api/public/version`), none to SDR.
3. **Collection/item sweep (measured, 62/62).** Every axios call site with a URL literal starting with an
   SDR segment was listed with its verb and read by hand.
4. **SDR-vs-custom-controller disambiguation.** Critical: many segments collide with a custom
   `@RestController` on the *same* path (`/v3/client`, `/v3/user`, `/v3/printer`, `/v3/message`,
   `/v3/section`, `/v3/location`, `/v3/advice`, `/v3/stockrecord`, `/v3/userGroup`, `/v3/userRole`,
   `/v3/unitloadRecord`). I dumped the class-level `@RequestMapping` of all 63 controllers from
   `wms2-api` `origin/develop` and confirmed:
   - **no controller declares a GET on its bare base path**, and
   - **no controller declares `/{id}`** (the sole `/{…}`-shaped GET is
     `ClientController:69 /{id}/effectivePutawayDestination`), and
   - **no controller shadows any of the 36 matched search paths** — the only controller `/search/*` is
     `UnitLoadController:242 GET /v3/unitLoad/search/findByItemForReplenish`, and its base path
     `/v3/unitLoad` (capital L) is a **different path** from the SDR `/unitload`, so
     `mobile/util/replenishUnitLoads.js:18` is a custom-controller caller, not an SDR one.

   Therefore a GET of `/<segment>` or `/<segment>/{id}` for these segments **does** reach SDR, while
   `/client/detailView`, `/user/getDetails`, `/advice/create`, `/printer/inboundPrinters`,
   `/section/sectionDetailsById/{id}`, `/stockrecord/adjustmentAlerts`,
   `/unitloadRecord/unitloadRecordDetailsById/{id}` etc. do **not**.

**Caller-class conventions used below.**
- **app** = production code (web `store/`, `components/`, `pages/`, `plugins/`, `util/`; mobile likewise; OMS `app/`, `config/`).
- **cypress-only** = referenced *only* from `wms2-web-ui/cypress/**` (an e2e API helper library that mirrors
  the app's calls). Not a production caller, but gating it will red the e2e suite.
- **doc-only** = referenced only from an OMS planning markdown, not from code.
- Jest/Playwright unit specs (`test/`, `tests/`) were excluded from "live caller" and add nothing not already
  covered by an app caller.

**Counts checked vs inferred.** All 409 paths were checked mechanically (347 by exact match, 62 by call-site
enumeration), plus the 10 non-literal call sites read individually. Nothing in the caller table is inferred
from naming. The one judgement call is the *bucket*, not the caller.

---

## Summary

| bucket | domain types | exported read paths in those types |
|---|---|---|
| UI-ADMIN | 6 | 27 |
| UI-OPERATIONAL | 19 | 177 |
| MIXED | 6 | 40 |
| OMS (alone) | 0 | 0 |
| UNCALLED | 31 | 165 |
| **total** | **62** | **409** |

Every OMS-consumed domain type is also consumed by a UI, so no type lands in **OMS** alone.

**Path-level reality — this is the headline number:**

| | search paths (347) | collection paths (62) | total (409) |
|---|---|---|---|
| live app caller | 32 | 19 | **51 (12.5%)** |
| cypress-only | 4 | 6 | 10 |
| OMS-doc-only | 2 | 0 | 2 |
| **no reference anywhere** | **309** | **37** | **346 (84.6%)** |

Read that as: even in the 31 domain types that *are* called, the overwhelming majority of individual search
paths are unreferenced — e.g. Replenishorder has **42** exported read paths and exactly **one** live caller
(an item GET); Stockunit has 21 and 2; Unitload has 18 and 1; Customerorder has 23 and 2.

---

## Per-domain-type table

`paths called` counts SDR read paths with a **live app** caller. `exp` = exported read paths for the type.
"coll" = the collection path (covers both `GET /x` and `GET /x/{id}`).

| # | domainType | bucket | caller file:line (up to 3) | paths actually called | exp | notes |
|---|---|---|---|---|---|---|
| 1 | Advice | UNCALLED | — | 0 | 6 | Every `/advice/*` caller is `AdviceController` (`/detailView`, `/create`, `/update`, `/closeInboundBol`, `/adviceDetailsById/{id}`, `/acceptHubAndSpokeBol`, `/exportInboundNotice`, `/setPurchaseOrderNumber`). The only SDR touches are **writes**: `store/receiving/inboundNotices.js:187` DELETE `/advice/{id}`, `:380` PATCH `/advice/{id}`. No read. |
| 2 | Adviceposition | UNCALLED | — | 0 | 5 | |
| 3 | Billoflading | UNCALLED | — | 0 | 9 | All BOL traffic goes to `/v3/billOfLading` (custom). |
| 4 | BillofladingPosition | UNCALLED | — | 0 | 13 | |
| 5 | Boxtype | MIXED (UI-OPERATIONAL + OMS) | `web/store/receiving/createPo.js:71`; `web/components/receiving/open/receive/receivingForm.vue:558`; `oms/app/Services/WmsFacilitySyncService.php:202` | `search/findByBoxtypeprocesstype`, `search/findByAdvicePositionId`, coll (OMS) | 6 | OMS key **`boxtype_list`** → `v3/boxtype`, method `WmsFacilitySyncService::reconcile()`. `search/findByExternalid` is **doc-only** (`oms/docs/plans/sync-skus-shippers-to-facility/02-facility-requirements-inventory.md:96`) — planned, not wired. UI callers are the Receiving screens (`WEB_UI_VIEW_INBOUND_BOL`). |
| 6 | Client | MIXED (UI-ADMIN + UI-OPERATIONAL + OMS) | `web/store/admin/client.js:26`; `mobile/components/picking/pick.vue:253`; `oms/app/Services/WmsFacilitySyncService.php:201` | coll (`GET /client`, `GET /client/{id}`), `search/findByClNr` | 13 | Admin: `store/admin/client.js:26` `GET /client`, `store/admin/shippers.js:72` `GET /client/{id}`, `store/admin/configuration.js:264` `GET /client/{id}` (`WEB_UI_VIEW_CLIENT`). **Operational**: mobile Picking resolves the "System" client via `search/findByClNr`. OMS keys **`client_list`** → `v3/client` (`WmsFacilitySyncService::preflight/reconcile/backfillFacilityItemMap`) and **`client_find_by_number`** → `v3/client/search/findByClNr` (`WmsApiService::resolveWmsClientId`, `WmsFacilitySyncService::resolveWmsClientId`). Gating `/client` **breaks the OMS facility sync**. |
| 7 | Customerorder | UI-OPERATIONAL | `web/components/outbound/bol/outboundBolDetailsTable.vue:200`; `web/store/processes/transferPicking.js:143`; `web/store/masterData/customerOrder.js:29,46` | coll (`GET /customerorder/{id}`), `search/findByKeyword` | 23 | Live reads are item GETs from Outbound BOL (`WEB_UI_VIEW_BILL_OF_LADING`) and Transfer Picking (`WEB_UI_VIEW_TRANSFER_ORDER`). `store/masterData/customerOrder.js` (coll + `findByKeyword`) is dispatched **only** by `components/masterData/Strategies/customerOrder.vue`, which no page or template references — apparently **dead code**. `store/common/order.js:15` is a PATCH (write). |
| 8 | CustomerorderBatch | UNCALLED | (cypress-only: `web/cypress/support/plugins/preflight-task.js:42`) | 0 | 18 | The only app reference, `store/outbound/club.js:316` `GET /customerorderBatch/{id}`, is **commented out**. Live batch traffic goes to `/v3/customerOrderBatch` (custom). |
| 9 | CustomerorderPosition | UNCALLED | — | 0 | 10 | |
| 10 | Cyclecount | UNCALLED | — | 0 | 11 | `store/internalOps/cycleCount.js:250` is a **PATCH** `/cyclecount/{id}` (write). Reads go to `/v3/cycleCount` + `/v3/cycleCountLos` (custom). |
| 11 | CyclecountDtoView | UNCALLED | — | 0 | 1 | |
| 12 | CyclecountPosition | UNCALLED | — | 0 | 7 | |
| 13 | FixLocationAssignment | UNCALLED | — | 0 | 11 | Master Data → Fixed Locations uses `/v3/fixedAssignment` (custom). |
| 14 | FlowbinMonitorView | UNCALLED | — | 0 | 3 | `store/reports/flowbin.js:62` calls **`/report/flowbinMonitorView`** — `ReportController` (`/v3/report`), not SDR. |
| 15 | Goodsreceipt | UNCALLED | — | 0 | 2 | |
| 16 | Goodsreceiptposition | UI-OPERATIONAL | `web/store/receiving/inboundNotices.js:333` | `search/findByAdvicepositionId` | 9 | Inbound Notices (`WEB_UI_VIEW_INBOUND_BOL`). |
| 17 | InventoryRecord | UNCALLED | — | 0 | 1 | |
| 18 | Itemdata | MIXED (UI-OPERATIONAL + OMS) | `web/store/receiving/createPo.js:59`; `web/store/internalOps/createCc.js:44`; `oms/app/Services/WmsFacilitySyncService.php:204,1123` | `search/findByClientId`, `search/findByClientIdIn`, coll (OMS) | 11 | OMS keys **`itemdata_list`** → `v3/itemdata` (`WmsFacilitySyncService::reconcile`, `::backfillFacilityItemMap`) and **`itemdata_by_client`** → `v3/itemdata/search/findByClientId` (`WmsFacilitySyncService::readItemdataForClient`). UI: Create PO (Receiving) and Create Cycle Count. |
| 19 | Itemunit | UI-OPERATIONAL | `web/store/masterData/packaging.js:78`; `web/store/masterData/skuUnit.js:51` | coll | 2 | Master Data → Packaging (`WEB_UI_VIEW_CASE_TYPE`) / SKU Units (`WEB_UI_VIEW_ITEM_UNIT`). Master Data is a **separate top-level menu** from Admin, but each leaf is already function-gated, so this is a viable gating candidate despite the bucket. |
| 20 | Location | UI-OPERATIONAL | `web/store/outbound/outboundBols.js:289`; `web/store/receiving/inboundNotices.js:200` | `search/findByGateTrue`, `search/getAllCrossDockingLanes` | 19 | Everything else on `/location/*` is `LocationController`. `store/masterData/storageLocation.js:73` is a DELETE (write). 17 of 19 read paths unreferenced. |
| 21 | LocationArea | UI-OPERATIONAL | `web/store/masterData/functionalArea.js:51`; `web/store/internalOps/createCc.js:55` | coll | 3 | Master Data → Functional Areas (`WEB_UI_VIEW_AREA`) **and** Internal Ops → Cycle Count creation (`WEB_UI_VIEW_CYCLECOUNT`). Two different screens — gating on the Master Data function alone would break Cycle Count. |
| 22 | LocationConstraint | UNCALLED | — | 0 | 2 | |
| 23 | LocationRack | UI-OPERATIONAL | `web/store/masterData/storageLocation.js:106` | coll | 2 | Master Data → Storage Locations (`WEB_UI_VIEW_STORAGE_LOCATION`). |
| 24 | LocationRackRow | UNCALLED | — | 0 | 2 | |
| 25 | LocationType | UI-OPERATIONAL | `web/store/masterData/locationType.js:51` | coll | 2 | Master Data → Location Types (`WEB_UI_VIEW_STORAGE_LOCATION_TYPE`). `:109` is a DELETE (write). |
| 26 | LockOverviewAllDtoView | UI-OPERATIONAL | `web/store/reports/lock.js:64` | `search/findByKeyword` | 3 | **Dynamically constructed** (`'/' + resource + '/search/findByKeyword'`, `resource` = `'lockOverviewAllDtoView'` when the "Include Shipped Locks" toggle is on). A fixed-string grep misses this. Reports → Lock Report (`WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW`). |
| 27 | LockOverviewDtoView | UI-OPERATIONAL | `web/store/reports/lock.js:64` | `search/findByKeyword` | 3 | Same call site, toggle off (the default). |
| 28 | LosSequencenumber | UNCALLED | — | 0 | 2 | |
| 29 | Message | UI-ADMIN | `web/store/admin/serviceLogs.js:29`; `web/store/admin/serviceLogs.js:64` | coll, `search/findByKeyword` | 5 | Admin → Service Logs. `/message/detailView`, `/message/resend`, `/message/messageDetailsById/{id}` are `MessageController`. Clean gating candidate. |
| 30 | MessageArchived | UNCALLED | — | 0 | 1 | Path is `/message_archived`. |
| 31 | OrderDetailMonitorView | UNCALLED | — | 0 | 3 | Backs Parcel Picking Report via `/v3/report`, not SDR. |
| 32 | OrderMonitorView | UNCALLED | — | 0 | 5 | |
| 33 | ParcelMonitorView | UNCALLED | — | 0 | 5 | `store/reports/outboundParcel.js:78` calls **`/report/parcelMonitorView`** (`ReportController`), not `/parcelMonitorView`. 14 cypress references are all to the `/report/…` form too. |
| 34 | Pickingorder | UNCALLED | (cypress-only: `web/cypress/e2e/wms/smoke/phase2-pick.cy.js:97`) | 0 | 14 | `search/findByNumber` has a cypress caller only; app picking uses `/v3/picking`. |
| 35 | PickingorderPosition | UNCALLED | — | 0 | 12 | |
| 36 | PickingorderUnitload | UNCALLED | — | 0 | 5 | |
| 37 | Printer | MIXED (UI-ADMIN + UI-OPERATIONAL) | `web/store/admin/printer.js:36,171`; `web/store/reports/parcelPicking.js:116`; `oms/app/Services/WmsApiService.php:2421` | coll, `search/findByType` | 4 | Admin → Printers uses both. **But** `store/reports/parcelPicking.js:116` (`WEB_UI_VIEW_PARCEL_PICKING`) also calls `search/findByType?type=OUTBOUND_TOTE` — gating it on the admin function breaks the Parcel Picking Report. OMS key **`printer_search_by_type`** (`WmsApiService::getWmsPrinters`) **defaults to `rest/printer/findByType`** (the unauthenticated `/rest/*` surface), not SDR; `config/wms.php:154` documents that it is env-overridable *to* `v3/printer/search/findByType`. Whether any deployed facility uses that override is **undetermined** (env files are gitignored). |
| 38 | Queryrepository | UNCALLED | — | 0 | 1 | |
| 39 | ReceivedDtoView | UNCALLED | — | 0 | 1 | |
| 40 | ReceivingDtoView | UI-OPERATIONAL | `web/store/reports/receiving.js:61`; `web/store/receiving/inboundNotices.js:302`; `web/components/receiving/open/receive/receivingForm.vue:613` | `search/findByKeyword`, `search/findByAdvicenumber`, `search/findByAdvicepositionid` | 6 | Also `web/store/reports/data.js:26` (`findByKeyword`). Spans Reports → Receiving Report (`WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW`) **and** Receiving → Inbound Notices (`WEB_UI_VIEW_INBOUND_BOL`) — two functions. |
| 41 | ReplenishmentMonitorView | UNCALLED | — | 0 | 2 | Replenish monitor data comes from `/v3/dashboard/replenishMonitorViewSummary`. |
| 42 | Replenishorder | UI-OPERATIONAL | `web/store/internalOps/replenishments.js:169` | coll (`GET /replenishorder/{id}`) | 42 | **1 of 42.** Everything else is `/v3/replenishOrder` (capital O, custom). Internal Ops → Replenishment (`WEB_UI_VIEW_REPLENISHMENT_ORDER`). Largest un-exploited surface in the inventory. |
| 43 | Section | UI-OPERATIONAL | `mobile/store/picking.js:186`; `mobile/store/picking.js:388` | `search/findByName`, coll | 4 | **Mobile only** — web `store/masterData/section.js` uses `SectionController` (`/detailView`, `/create`, `/getPickingTypes`, `/sectionDetailsById/{id}`) plus a DELETE `/section/{id}` (write). Gating `/section` hits mobile Picking, not an admin screen. |
| 44 | Shipperid | MIXED (UI-OPERATIONAL + OMS) | `web/store/reports/inventory.js:129`; `oms/app/Services/WmsFacilitySyncService.php:203` | coll | 2 | UI: the shipper filter on Reports → Inventory Report (`WEB_UI_VIEW_INVENTORY_RECORD`). OMS key **`shipperid_list`** → `v3/shipperid`, method `WmsFacilitySyncService::reconcile()`. `search/findAllOrderByName` is **doc-only** (`oms/docs/plans/.../02-facility-requirements-inventory.md:95`). |
| 45 | Shippingmethod | UNCALLED | — | 0 | 1 | |
| 46 | ShippingmethodShipperid | UNCALLED | — | 0 | 3 | |
| 47 | Stockrecord | UI-OPERATIONAL | `web/store/reports/stockUnit.js:51` | `search/findByKeyword` | 5 | Reports → Stock Unit Record (`WEB_UI_VIEW_STOCK_UNIT_RECORD`). `/stockrecord/stockRecordDetailsById/{id}` and `plugins/adjustmentAlerts.client.js:202 /stockrecord/adjustmentAlerts` are `StockRecordController`. |
| 48 | StockView | UI-OPERATIONAL | `web/store/reports/inventory.js:69` | `search/findByKeyword` | 5 | Reports → Inventory Report (`WEB_UI_VIEW_INVENTORY_RECORD`). |
| 49 | Stockunit | UI-OPERATIONAL | `web/store/internalOps/replenishments.js:197`; `mobile/components/replenish/shared/OrderHeaderBlock.vue:74` | `search/getStockUnitsForReplenishment`, `search/getAmountAvailable` | 21 | 2 of 21. `search/findByItemdataId` is **cypress-only**. Both live callers are replenishment (web Internal Ops + mobile Replenish). |
| 50 | Sysprop | UI-ADMIN | `web/store/admin/management.js:111`; `web/store/admin/configuration.js:104,212`; `web/store/admin/mgmt/overview.js:20` | coll, `search/findByGroupname` | 10 | Also `store/admin/management.js:171,183`. `WEB_UI_VIEW_SYSTEM_PROPERTY`. `:127/:179/:224/:233` are PUT/DELETE (writes). Cleanest gating candidate after Message. |
| 51 | Unitload | UI-OPERATIONAL | `web/store/handlingUnits/container.js:111` | `search/findByCarrierunitloadId` | 18 | 1 of 18. Handling Units (`WEB_UI_VIEW_STOCK_UNIT`/`WEB_UI_VIEW_CONTAINER`). `search/findByLabelid` and `search/findByStoragelocationId` are **cypress-only**. Mobile's `/unitLoad/search/findByItemForReplenish` is `UnitLoadController`, **not** SDR (capital L). |
| 52 | UnitloadRecord | UI-OPERATIONAL | `web/store/reports/container.js:49` | `search/findByKeyword` | 3 | Reports → Container Record (`WEB_UI_VIEW_UNIT_LOAD_RECORD`). `/unitloadRecord/unitloadRecordDetailsById/{id}` is `UnitloadRecordController`. |
| 53 | UnitloadType | UI-OPERATIONAL | `web/store/masterData/unitLoadType.js:51`; `web/store/receiving/createPo.js:82` | coll | 3 | Two screens: Master Data → Unit Load Types (`WEB_UI_VIEW_UNIT_LOAD_TYPE`) **and** Receiving → Create PO (`WEB_UI_VIEW_INBOUND_BOL`). |
| 54 | User | UI-ADMIN | `web/store/admin/management.js:126`; `web/components/admin/userManagement/users/user.vue:304` | coll (`GET /user`, `GET /user/{id}`) | 1 | `WEB_UI_VIEW_USER_MANAGEMENT`. Also the **association resource** `GET /user/{id}/groups` at `store/admin/user.js:59` — not a TSV row (the inventory enumerates no association paths), but it hangs off the same exported repository. All other `/user/*` traffic is `UserController` / `UserAdministrationController`. |
| 55 | UserFunction | UI-ADMIN | `web/store/admin/function.js:27`; `web/store/admin/management.js:141,158` | coll, `search/findByKeyword` | 4 | `WEB_UI_VIEW_USER_MANAGEMENT`. No `UserFunctionController` exists — this domain type is **only** reachable over SDR. |
| 56 | UserGroup | MIXED (UI-ADMIN + UI-OPERATIONAL) | `web/store/admin/group.js:110,122,258`; `web/store/index.js:249` | coll, `search/findByConnectorFalse`, `search/findByName`, `search/findByUsername` | 4 | **All 4 read paths called** — the only fully-exercised domain type. `store/index.js:249 GET /userGroup/search/findByUsername` runs in the **app bootstrap / login path**, not an admin screen; gating it on `WEB_UI_VIEW_USER_MANAGEMENT` would lock every non-admin user out at sign-in. Also association `GET /userGroup/{id}/roles` at `store/admin/group.js:189`. |
| 57 | UserGroupUser | UI-ADMIN | `web/store/admin/group.js:190` | `search/findByGrouplistId` | 4 | `WEB_UI_VIEW_USER_MANAGEMENT`. Note this repo also keeps write verbs (see the access-chain memo) — read gating alone does not close it. |
| 58 | UserGroupUserRole | UNCALLED | — | 0 | 4 | |
| 59 | UserRole | UI-ADMIN | `web/store/admin/role.js:77`; `web/store/admin/role.js:51,62`; `web/store/admin/role.js:172` | coll, `search/findByConnectorFalse`, `search/findByName` | 3 | **All 3 read paths called.** `WEB_UI_VIEW_USER_MANAGEMENT`. Also association `GET /userRole/{id}/functions` at `store/admin/group.js:203`. `role.js:50` is a commented-out `GET /userRole`. |
| 60 | UserRoleUserFunction | UNCALLED | — | 0 | 4 | |
| 61 | UserUserRole | UNCALLED | — | 0 | 1 | Consistent with "direct user→role assignment is unused in v2". |
| 62 | ViewWarehouseLocationReport | UI-OPERATIONAL | `web/store/reports/skuLocation.js:61` | `search/findByKeyword` | 4 | Reports → SKU Location Report (`WEB_UI_VIEW_LOCATION_OVERVIEW`). |

---

## Uncalled domain types (candidates for un-export)

**31 types, 165 exported read paths, zero callers in any of the three repos.**

Tier A — no reference at all, not even cypress or docs (**28 types, 133 paths**):

| domainType | read paths | domainType | read paths |
|---|---|---|---|
| Adviceposition | 5 | OrderDetailMonitorView | 3 |
| Billoflading | 9 | OrderMonitorView | 5 |
| BillofladingPosition | 13 | ParcelMonitorView | 5 |
| CustomerorderPosition | 10 | PickingorderPosition | 12 |
| Cyclecount | 11 | PickingorderUnitload | 5 |
| CyclecountDtoView | 1 | Queryrepository | 1 |
| CyclecountPosition | 7 | ReceivedDtoView | 1 |
| FixLocationAssignment | 11 | ReplenishmentMonitorView | 2 |
| FlowbinMonitorView | 3 | Shippingmethod | 1 |
| Goodsreceipt | 2 | ShippingmethodShipperid | 3 |
| InventoryRecord | 1 | UserGroupUserRole | 4 |
| LocationConstraint | 2 | UserRoleUserFunction | 4 |
| LocationRackRow | 2 | UserUserRole | 1 |
| LosSequencenumber | 2 | MessageArchived | 1 |

Tier B — un-exporting the **read** surface is safe, but the type still has a live **write** or **cypress**
toucher, so do it with eyes open (**3 types, 32 paths**):

| domainType | read paths | what still touches it |
|---|---|---|
| Advice | 6 | `store/receiving/inboundNotices.js:187` DELETE `/advice/{id}`, `:380` PATCH `/advice/{id}` — SDR **writes**, no reads. |
| Cyclecount *(also Tier A by reads)* | 11 | `store/internalOps/cycleCount.js:250` PATCH `/cyclecount/{id}` — SDR **write**. |
| CustomerorderBatch | 18 | `cypress/support/plugins/preflight-task.js:42` `GET /customerorderBatch?size=1`. App reference is commented out. |
| Pickingorder | 14 | `cypress/e2e/wms/smoke/phase2-pick.cy.js:97` `search/findByNumber`. |

Beyond whole types, **309 of 347 search paths** have no reference anywhere. The highest-value narrowing
targets inside *called* types: Replenishorder (41 of 42 unreferenced), Stockunit (19 of 21),
Unitload (17 of 18), Customerorder (21 of 23), Location (17 of 19), Itemdata (9 of 11),
Goodsreceiptposition (8 of 9).

---

## Things I could NOT determine

1. **Whether any consumer outside these three repos calls the SDR surface.** I searched only
   `wms2-web-ui`, `wms2-mobile-ui`, `oms-laravel-api` as instructed. Not searched: `omsv2-UI` (React),
   the two v1 UIs, `v1/oms`, any Postman collection, ops script, BI/reporting job, or third-party
   integration. An "UNCALLED" verdict here means "uncalled by the three repos", not "uncalled".
2. **OMS `WMS_*_ENDPOINT` env overrides in deployed environments.** `config/wms.php` defaults are what I
   read; `.env` is gitignored. In particular `printer_search_by_type` defaults to the **non-SDR**
   `rest/printer/findByType` but `config/wms.php:154` says it is overridable to
   `v3/printer/search/findByType` — I cannot tell whether any facility does that.
3. **HAL `_links`-driven URLs.** `oms/app/Services/WmsApiService.php:3363` explicitly falls back to the
   `_links.self` href returned by SDR (`.../v3/client/42`). A caller that follows a HAL link reaches an
   SDR path that appears in no source literal. I found this one instance; I cannot rule out others,
   and no static sweep can.
4. **Whether the e2e suites run against a gated environment.** 10 read paths are cypress-only. I did not
   run cypress and cannot say whether gating those would red the suite or whether the suite already runs
   as `sb_admin`.
5. **`components/masterData/Strategies/customerOrder.vue` reachability.** No page, template, or
   `<...>` tag reference found, and `nuxt.config.js:60` sets `components: true` (auto-import), so a tag
   could in principle exist in a form my patterns missed. I call it "apparently dead", not "dead".
6. **SDR association resources are not in the inventory at all.** `GET /user/{id}/groups`,
   `GET /userGroup/{id}/roles`, `GET /userRole/{id}/functions` have live admin callers and are served
   by no controller (I checked all 63 class-level mappings), so they are almost certainly SDR
   association resources — but the TSV enumerates zero association rows, so I could not cross-check
   them against the surface, and they are excluded from every count above. **The 409-path denominator
   likely understates the real read surface by the association-resource count, which I did not measure.**
7. **Runtime precedence when a custom controller and SDR share a path.** I established that no controller
   declares a bare-base, `/{id}`, or colliding `/search/*` GET, so no live SDR read call is shadowed.
   I did **not** verify Spring's handler-mapping order empirically (no request was issued); the verdict
   is derived from the mapping declarations, not from a probe.
8. **Verb coverage.** I classified GET reads only. HEAD and OPTIONS (present on every COLLECTION row) were
   not analysed, and write verbs were noted only where they explained an otherwise-suspicious hit.
