---
title: "WMS v1 — Function → Documentation Map"
type: architecture
status: active
version: v1
scope: function-map
owner: Nam Park
created: 2026-05-01
updated: 2026-05-01
last_verified: 2026-05-06
verified_by: enumeration of wms1-web-ui + wms1-mobile-ui menus + wms1-api endpoints
related:
  - ./wms1-end-to-end-request-journey.md
  - ./wms1-tenant-routing-datasource-topology.md
  - ./wms1-function-permission-map.md
  - ../../_symptom-index.md
tags:
  - architecture
  - function-map
  - cross-reference
  - wms1
---

# WMS v1 — Function → Documentation Map

**Scope:** Every user-facing function in the WMS v1 platform, mapped to UI entry point, role gate, primary API endpoint, and canonical workflow / architecture doc · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-05-01

---

## 1. Overview

Support-triage entry page and coverage-audit table. Find the row matching the reported function, open the linked doc.

- 📘 Architecture doc · 📕 Workflow doc · 📗 Data-dictionary doc

Source of truth on what exists:

- Mobile menu: `v1/wms-mobile-ui/store/home.js:19-93` (11 workflow pages + error page)
- Web menu: `v1/wms-web-ui/util/appMenuList.js` (role-filtered by group key)
- Web pages: `v1/wms-web-ui/pages/` (~56 page files)
- API endpoints: base prefix `/v3`, mobile controllers under `controller/mobile/`, desktop controllers under `controller/`
- Role constants: `WmsConstants.java:329-405` (inner class `WmsConstants.Roles`)

All mobile requests go to `wms-api` at `${API_BASE_URL}` (default `http://localhost:8088/v3`). Token injected by `v1/wms-mobile-ui/plugins/axios.js`. Role gate resolved by `GET /v3/user/getAllRoles/{username}` — see [wms1-function-permission-map.md](./wms1-function-permission-map.md).

**Key v1 differences from v2:**
- Single-tenant auth (no subdomain routing; env-var keycloak config only)
- Role constants live in `WmsConstants.java`, not a separate auth config
- Web UI uses Keycloak **group** keys (`super-admin`, `inventory-manager`, `outbound-manager`, `receiving`, `outbound-manager,receiving`) — same pattern as v2

---

## 2. Mobile UI Functions (11 pages)

All under base path `/mobile/`. Source: `wms-mobile-ui/pages/*.vue`. Role gate source: `store/home.js:19-93`.

| Function | Mobile page | Role constant (WmsConstants.java:L) | Primary API endpoint(s) | Canonical doc |
|---|---|---|---|---|
| Lookup | `/lookup` | `MOBILE_UI_VIEW_INFO` (L396) | `/v3/lookup/search/{keyword}`, `/searchSku/{keyword}`, `/stockListByItemNumber/{item}`, `/unitLoadListByLocationName/{loc}`, `/locationByLocationName/{loc}` | — (no doc; read-only inventory lookup) |
| Putaway | `/putaway` | `MOBILE_UI_VIEW_PUT_AWAY` (L397) | `/v3/putaway/scanPallet/{input}`, `/calculatePutawayList`, `/scanFlowBinLocation`, `/storeBoxOnLocation`, `/storePalletOnLocation`, `/storePalletBackOnPutawayLane` | 📕 [wms1-receiving-putaway-workflow §5](../workflows/wms1-receiving-putaway-workflow.md) |
| Move Unitload | `/move-unitload` | `MOBILE_UI_VIEW_TRANSFER` (L398) | `/v3/moveUnitload/selectSource/{input}`, `/selectDestination` | 📕 [wms1-move-stock-unitload-workflow](../workflows/wms1-move-stock-unitload-workflow.md) |
| Move Stock | `/move-stock` | `MOBILE_UI_VIEW_STOCK_TRANSFER` (L399) | `/v3/moveStock/selectSource/{input}`, `/selectStockUnit/{id}/{input}`, `/scanDestination` | 📕 [wms1-move-stock-unitload-workflow](../workflows/wms1-move-stock-unitload-workflow.md) |
| Picking | `/picking` | `MOBILE_UI_VIEW_PICKING` (L400) | `/v3/picking/pickingOrders/{input}`, `/releasePickingOrder/{id}`, `/pickingOrderPositionsInfo/{id}`, `/processLocation/{id}/{input}`, `/processPick`, `/processRapidPickScanPackage/{section}/{input}`, `/processRapidPickScanSource`, `/resetPickingOrder` | 📕 [wms1-picking-workflow](../workflows/wms1-picking-workflow.md) |
| Palletizing | `/palletizing` | `MOBILE_UI_VIEW_PALLETIZING` (L401) | `/v3/palletizing/scanParcel/{input}`, `/scanPallet`, `/scanPalletBulk/{input}`, `/scanParcelBulk/{id}/{input}` | 📕 [wms1-bol-truck-loading-workflow §4](../workflows/wms1-bol-truck-loading-workflow.md) |
| Truck Loading | `/truck-loading` | `MOBILE_UI_VIEW_TRUCK_LOADING` (L402) | `/v3/truckLoading/orderList`, `/truckLoadingInfo/{bolName}`, `/loadOrder`, `/scanPallet`, `/scanGate` | 📕 [wms1-bol-truck-loading-workflow §5](../workflows/wms1-bol-truck-loading-workflow.md) |
| Cycle Count | `/cycle-count` | `MOBILE_UI_VIEW_CYCLE_COUNT` (L404) | `/v3/cycleCountLos/orderList`, `/locationList/{orderId}`, `/unitLoadList/{orderId}/{locationId}`, `/processScanUnitLoad`, `/countUnitLoad`, `/recountUnitLoad`, `/scanSingleUnitLoad/{input}`, `/countSingleUnitLoad`, `/recountSingleUnitLoad` | 📕 [wms1-cycle-count-workflow](../workflows/wms1-cycle-count-workflow.md) |
| Replenish Process | `/replenish` | `MOBILE_UI_VIEW_REPLENISHMENT` (L403) | `/v3/replenish/reservedOrder`, `/loadOrderById/{id}`, `/loadOrderByDestination` (web), `/checkSource/{id}/{input}`, `/checkAmount/{id}/{input}`, `/checkDestination/{id}/{input}`, `/order/{id}` PUT, `/multi-unitloads` | 📕 [wms1-replenish-workflow](../workflows/wms1-replenish-workflow.md), [wms1-multi-unitload-replenish](../workflows/wms1-multi-unitload-replenish.md) |
| Replenish Request | `/replenish-request` | `MOBILE_UI_VIEW_REPLENISHMENT` (L403) | `/v3/replenish/requestLocation/{input}`, `/requestAmount`, `/clientList`, `/clientOrderList/{clientNumber}` | 📕 [wms1-replenish-order-creation](../workflows/wms1-replenish-order-creation.md) |
| Transfer Process | `/transfer-order` | `WEB_UI_VIEW_TRANSFER_ORDER` (L340) ⚠ | `/v3/transferOrder/orderList`, `/processOrderPositionSelect`, `/processScanUnitLoad`, `/processScanTransferLane`, `/updateOrder` | 📕 [wms1-transfer-order-workflow](../workflows/wms1-transfer-order-workflow.md) |
| (LPN Association) | *(not in menu)* | `MOBILE_UI_VIEW_LPN_ASSOCIATION` (L405) | — | reserved / unused |

⚠ **Transfer Process** uses a `WEB_UI_*` role on a mobile page — naming oversight preserved from original implementation. See [wms1-function-permission-map.md](./wms1-function-permission-map.md).

---

## 3. Web UI Functions — Operations

Source: `v1/wms-web-ui/util/appMenuList.js`. Group key is the `appMenuList` object key (`super-admin`, `inventory-manager`, etc.).

| Function | Web page | Group(s) | Primary API endpoint(s) | Canonical doc |
|---|---|---|---|---|
| Dashboard | `/dashboard` | all | mixed monitor-view endpoints | 📘 [wms1-entity-enumeration-report.md](./wms1-entity-enumeration-report.md) + per-widget workflow |
| Receiving — Inbound Notices | `/receiving/inbound-notices?tab=open\|closed` | super-admin, inventory-manager, receiving, outbound+receiving | `/v3/advice/*` (AdviceController) | 📕 [wms1-receiving-putaway-workflow §3–4](../workflows/wms1-receiving-putaway-workflow.md) |
| Receiving — Open Notice Detail | `/receiving/openNotice/:id` + `/receive` | same | `/v3/receiving/receive` POST | 📕 same §4 |
| Receiving — Closed Notice Detail | `/receiving/closedNotice/:id` | same | `/v3/goodsReceiptPosition/detailsByAdvicePositionId/{id}` | 📕 same |
| Internal Ops — Replenishment | `/internalOps/replenishment?tab=open\|closed` | super-admin, inventory-manager | `/v3/replenishOrder/detailView`, `/replenishorderDetailsById/{id}` | 📕 [wms1-replenish-workflow](../workflows/wms1-replenish-workflow.md) |
| Internal Ops — Cycle Count | `/internalOps/cycle-count?tab=open\|closed` | super-admin, inventory-manager | `/v3/cycleCount/create`, `/cancel`, `/detailView`, `/cycleCountDetailsById/{id}` | 📕 [wms1-cycle-count-workflow](../workflows/wms1-cycle-count-workflow.md) |
| Cycle Count — Detail (planned/closed) | `/internalOps/cycleCount/{planned\|closed}/:id` | same | `/v3/cycleCount/cycleCountDetailsById/{id}` | 📕 same |
| Outbound — Pick Pack | `/outbound/pick-pack` + detail open/closed `:id` | super-admin, inventory-manager, outbound-manager | `/v3/customerOrder/openPickPack`, `/closedPickPack`, `/detailsByOrderId/{id}` | 📕 [wms1-picking-workflow](../workflows/wms1-picking-workflow.md) |
| Outbound — Club | `/outbound/club` + detail open/closed `:id` + `/parcel-details` | same | `/v3/clubLine/openClubRun`, `/closedClubRun`, `/orderBatch/{id}` | 📕 [wms1-club-order-processing](../workflows/wms1-club-order-processing.md) |
| Outbound — Transfer | `/outbound/transfer` + detail open/closed `:id` | same | `/v3/transfers/transferOrder/{id}`, `/transferOrderByOrderBatchId/{id}` | 📕 [wms1-transfer-order-workflow](../workflows/wms1-transfer-order-workflow.md) |
| Outbound — Outbound BOL | `/outbound/outbound-bol` + detail open/closed `:id` + `/parcel-details` | same | `/v3/billOfLading/openBol`, `/closedBol`, `/bolDetailsById/{id}` | 📕 [wms1-bol-truck-loading-workflow](../workflows/wms1-bol-truck-loading-workflow.md) |
| Processes — Club Run | `/processes/club-run` | super-admin, inventory-manager, outbound-manager | `/v3/clubLine/activeClubRun`, `/inactiveClubRun`, `/skus`, `/unitLoads`, `/parcels`, `/runClubLine/{id}`, `/assignStagingLane/{id}/{locId}`, `/activateBatch/{id}/{locId}` | 📕 [wms1-club-order-processing](../workflows/wms1-club-order-processing.md) |
| Processes — Club Fulfillment | `/processes/club-fulfillment` *(not in menu)* | same | `/v3/clubLine/*` | 📕 same |
| Processes — Transfer Picking | `/processes/transfer-picking` | super-admin, inventory-manager, outbound-manager | `/v3/transfers/activeTransfer`, `/inactiveTransfer`, `/assignTransferLane/{id}/{locId}`, `/activateTransferOrder/{id}/{locId}`, `/runTransfer/{id}` | 📕 [wms1-transfer-order-workflow](../workflows/wms1-transfer-order-workflow.md) |
| Processes — Transfer Fulfillment | `/processes/transfer-fulfillment` *(not in menu)* | same | `/v3/transfers/*` | 📕 same |
| Handling Units | `/handlingUnits/handling-units` | super-admin, inventory-manager, outbound-manager, receiving | `/v3/stockunit/*`, `/v3/unitload/*` | 📗 [wms1-entity-enumeration-report.md](./wms1-entity-enumeration-report.md) |

---

## 4. Web UI Functions — Master Data (CRUD)

| Function | Web page | Group(s) | Primary API endpoint(s) | Doc status |
|---|---|---|---|---|
| Storage Locations | `/masterData/locationData/storage-locations` | super-admin, inventory-manager | `/v3/location/*` | Generic CRUD — entity shape in 📗 [wms1-entity-enumeration-report.md](./wms1-entity-enumeration-report.md) |
| Location Types | `/masterData/locationData/location-types` | same | `/v3/locationType/*` | same |
| Fixed Locations | `/masterData/locationData/fixed-locations` | same | `/v3/fixLocationAssignment/*` | Tuning behavior in 📗 [wms1-sysprop-catalog.md](../data-dictionary/wms1-sysprop-catalog.md) |
| Functional Areas | `/masterData/locationData/functional-areas` | same | `/v3/locationArea/*` (via REST repo) | 📗 [wms1-entity-enumeration-report.md](./wms1-entity-enumeration-report.md) |
| Sections | `/masterData/locationData/sections` | same | `/v3/section/*` | same (drives picking type TOTES_ON_CART vs RAPID_PICKING) |
| Unit Load Types | `/masterData/locationData/unit-load-types` | same | `/v3/unitloadType/*` | same |
| SKU Data | `/masterData/materialData/sku-data` | super-admin, inventory-manager | `/v3/itemData/*` | same |
| SKU Units | `/masterData/materialData/sku-units` | same | `/v3/itemunit/*` | same |
| Packaging | `/masterData/materialData/packaging` | same | `/v3/boxtype/*` | same |

---

## 5. Web UI Functions — Reports (read-only)

| Function | Web page | Group(s) | Primary endpoint | Backed by |
|---|---|---|---|---|
| Inventory Report | `/reports/inventory-report` | all with reports access | `/v3/stockunit/search/*` | entity `Stockunit` |
| Lock Report | `/reports/lock-report` | super-admin, inventory-manager | `/v3/stockunit/*` lock filter | view `LockOverviewDtoView` |
| Receiving Report | `/reports/receiving-report` | super-admin, inventory-manager, receiving, outbound+receiving | `/v3/goodsReceiptPosition/*` | views `ReceivedDtoView`, `ReceivingDtoView` |
| SKU Location Report | `/reports/sku-location-report` | all with reports | mixed | entities + views |
| Flowbin Report | `/reports/flowbin-report` | all with reports | monitor-view endpoint | view `FlowbinMonitorView` |
| Parcel Picking Report | `/reports/parcel-picking-report` | all with reports | monitor-view | view |
| Outbound Parcel Report | `/reports/outbound-parcel-report` | all with reports | monitor-view | view `ParcelMonitorView` |
| Stock Unit Record | `/reports/stock-unit-record` | all with reports | `/v3/stockRecord/*` | entity `Stockrecord` (audit trail) |
| Container Record | `/reports/container-record` | all with reports | `/v3/unitloadRecord/*` | entity `UnitloadRecord` |

---

## 6. Web UI Functions — Admin

| Function | Web page | Role / Group | Primary endpoint(s) | Doc |
|---|---|---|---|---|
| Admin | `/admin` | super-admin group | `/v3/user/*`, `/v3/groups/*`, `/v3/client/*`, `/v3/userRole/*`, `/v3/adminAction/triggerOrderReplenish`, `/v3/systemProperty/*` | 📘 [wms1-function-permission-map.md](./wms1-function-permission-map.md) + project CLAUDE.md |

---

## 7. Error / system pages

| Function | Page | Purpose | Doc |
|---|---|---|---|
| Not affiliated | web `/not-affiliated`, mobile `/not-authorized` | User has no matching Keycloak group / role | 📘 [wms1-function-permission-map.md](./wms1-function-permission-map.md) |
| Not authorized | web `/not-authorized`, mobile `/not-authorized` | User not a WMS user | same |

---

## 8. Legacy / Hidden Pages (flagged for cleanup)

| Path | Observed status |
|---|---|
| `pages/receiving/lookup.vue` | Commented-out from menu |
| `pages/outbound/transfer22.vue` | Numeric suffix suggests old version |
| `pages/masterData/locationData/storage-location_org.vue` | `_org` suffix suggests legacy copy |
| `pages/masterData/strategies/customer-orders.vue` | Test / experimental page (commented out of menu) |
| `pages/masterData/strategies/sku-data-nam.vue` | Test / experimental page (commented out of menu) |
| `pages/reports/data-report.vue` | Generic query tool — commented out of menu |
| `pages/processes/club-fulfillment.vue` | Not in menu — subpage of club-run |
| `pages/processes/transfer-fulfillment.vue` | Not in menu — subpage of transfer-picking |

---

## 9. Service Method → Doc Index

One row per hot service. "Section pointer" = the sbdocs section most relevant to the service's core logic.

| Service | File path (relative to `v1/wms-api/src/main/java/`) | Core responsibility | Primary sbdocs | Key section(s) |
|---|---|---|---|---|
| `CustomerorderService` | `net/aim_ai/wms/service/CustomerorderService.java` | Pick-date, priority, packaging, cancel + cleanup of individual customer orders | 📕 [wms1-picking-workflow](../workflows/wms1-picking-workflow.md), 📕 [wms1-cancel-cascade-workflow](../workflows/wms1-cancel-cascade-workflow.md) | `cancelOrder`, `packageOrder`, `batchUpdatePriorityByOrderIds` |
| `CustomerorderBatchService` | `net/aim_ai/wms/service/CustomerorderBatchService.java` | Club-run orchestration: staging-lane assignment, batch activation, `runClubLine`, cancel cascade at batch level | 📕 [wms1-club-order-processing](../workflows/wms1-club-order-processing.md), 📕 [wms1-cancel-cascade-workflow](../workflows/wms1-cancel-cascade-workflow.md) | `runClubLine`, `cancelBatch`, `activateOrderBatch`, `assignStagingLane` |
| `CustomerorderPositionService` | `net/aim_ai/wms/service/CustomerorderPositionService.java` | Position-level cancel eligibility check and cancel execution | 📕 [wms1-cancel-cascade-workflow](../workflows/wms1-cancel-cascade-workflow.md) | `canOrderPositionBeCancelled`, `cancelOrderPosition` |
| `PickingorderBusinessService` | `net/aim_ai/wms/service/PickingorderBusinessService.java` | Picking-order lifecycle: start, confirm per-pick, finish; triggers stock reservation and post-commit events | 📕 [wms1-picking-workflow](../workflows/wms1-picking-workflow.md), 📘 [wms1-transaction-boundary-map.md](./wms1-transaction-boundary-map.md) | `startPickingOrder`, `confirmPick`, `finishPickingOrder` |
| `MobilePickingService` | `net/aim_ai/wms/service/mobile/MobilePickingService.java` | Mobile scanner flow: section scan, source scan, rapid-pick confirm, reset | 📕 [wms1-picking-workflow](../workflows/wms1-picking-workflow.md) | `processRapidPickScanPackage`, `processPick` |
| `BillofladingService` | `net/aim_ai/wms/service/BillofladingService.java` | BOL lifecycle: create, palletize, set destination, close (single + batch), export, intra-company transfer ship | 📕 [wms1-bol-truck-loading-workflow](../workflows/wms1-bol-truck-loading-workflow.md), 📘 [wms1-state-machine-catalog.md](./wms1-state-machine-catalog.md) | `closeBOL`, `closeBOLs`, `transferOrder`, `finishTransfer` |
| `ReceivingService` | `net/aim_ai/wms/service/ReceivingService.java` | Pallet creation/assignment/unassignment, goods receipt (`receiveGoods`), case-label generation, advice create/update | 📕 [wms1-receiving-putaway-workflow](../workflows/wms1-receiving-putaway-workflow.md) | `receiveGoods`, `createAdviceWithPositions`, `assignPallet` |
| `MobilePutAwayService` | `net/aim_ai/wms/service/mobile/MobilePutAwayService.java` | Mobile putaway: scan pallet, calculate putaway list, store box/pallet on location, store back on putaway lane | 📕 [wms1-receiving-putaway-workflow §5](../workflows/wms1-receiving-putaway-workflow.md) | `calculatePutAwayList`, `storePalletOnLocation`, `storeBoxOnLocation` |
| `AdviceService` | `net/aim_ai/wms/service/AdviceService.java` | Inbound advice (notice) lifecycle: accept hub-and-spoke, close, accept transfer advice, export | 📕 [wms1-receiving-putaway-workflow §3](../workflows/wms1-receiving-putaway-workflow.md), 📕 [wms1-oms-integration-map.md](./wms1-oms-integration-map.md) | `acceptHubAndSpokeAdvice`, `close`, `acceptTransferAdvice` |
| `ReplenishGeneratorService` | `net/aim_ai/wms/service/ReplenishGeneratorService.java` | Auto-generate replenish orders: `refillFixedLocations` (called by scheduler), `calculateOrder`, multi-UL template | 📕 [wms1-replenish-workflow](../workflows/wms1-replenish-workflow.md), 📕 [wms1-replenish-order-creation.md](../workflows/wms1-replenish-order-creation.md) | `refillFixedLocations`, `calculateOrder`, `createOrderFromTemplate` |
| `MobileReplenishService` | `net/aim_ai/wms/service/mobile/MobileReplenishService.java` | Mobile replenish execution: load order, check source/amount/destination, finish, request replenish, multi-UL | 📕 [wms1-replenish-workflow](../workflows/wms1-replenish-workflow.md), 📕 [wms1-multi-unitload-replenish](../workflows/wms1-multi-unitload-replenish.md) | `finishReplenishmentOrder`, `checkSource`, `requestReplenish` |
| `ReplenishorderService` | `net/aim_ai/wms/service/ReplenishorderService.java` | Replenish order CRUD: create, update source/priority, cancel, redirect source stock unit | 📕 [wms1-replenish-workflow](../workflows/wms1-replenish-workflow.md), 📘 [wms1-state-machine-catalog.md](./wms1-state-machine-catalog.md) | `cancelReplenishmentOrder`, `redirectSource`, `recalculateReplenishmentOrderWithoutFixedLocationAssignment` |
| `MobileCycleCountService` | `net/aim_ai/wms/service/mobile/MobileCycleCountService.java` | Mobile cycle-count execution: scan UL, count, recount (single-UL and order-level), sysprop-driven behavior flags | 📕 [wms1-cycle-count-workflow](../workflows/wms1-cycle-count-workflow.md) | `scanSingleUnitLoad`, `countSingleUnitLoad`, `countCycleCountStockUnit` |
| `LosSyspropService` (= `SyspropService`) | `net/aim_ai/wms/service/LosSyspropService.java` | Read/write `los_sysprop` table; all runtime-tunable behavior flags across every workflow | 📗 [wms1-sysprop-catalog.md](../data-dictionary/wms1-sysprop-catalog.md) | `getStringDefault`, `getByKey`, `getSystemByGroupname` |
| `WmsConstants` | `net/aim_ai/wms/service/WmsConstants.java` | Authoritative constants: role strings (L329–L405), order/state codes, area names, error codes | 📘 [wms1-function-permission-map.md](./wms1-function-permission-map.md), 📗 [wms-domain-glossary.md](../data-dictionary/wms-domain-glossary.md) | `Roles` inner class (L329–L405) |
| `StockunitBusinessService` | `net/aim_ai/wms/service/StockunitBusinessService.java` | Core stock mutation: create, transfer between unit-loads, change amount/reserved amount, send to nirvana | 📗 [wms1-stockunit-design.md](../design/wms1-stockunit-design.md), 📘 [wms1-transaction-boundary-map.md](./wms1-transaction-boundary-map.md) | `transferStockToUnitLoad`, `changeAmount`, `changeReservedAmount`, `sendStockUnitToNirvana` |
| `SchedulingConfiguration` + `schedulejob/*.java` | `net/aim_ai/wms/schedulejob/SchedulingConfiguration.java` | Dynamic cron scheduler (DB-driven triggers); jobs: `ReplenishOrderJob` (auto-refill), `OrderReleaseJob`, `ReleaseExpiredPickingOrdersFromUserJob`, `StockSummaryExportJob`, `CleanUpOldMessagesJob`, `StaleClubBatchCleanupJob` | 📘 [wms1-scheduled-jobs-catalog.md](./wms1-scheduled-jobs-catalog.md) | `ReplenishOrderJob.doCalculation` (calls `ReplenishGeneratorService.refillFixedLocations`) |
| `PickPathConfig` | `net/aim_ai/wms/service/PickPathConfig.java` | Reads `PICK_PATH_DIRECTION` sysprop (30 s cache); returns `PickPathDirection` enum (`HORIZONTAL` / `VERTICAL`) consumed by pick, putaway, stock-move, and cycle-count traversal strategies (`util/DefaultStrategy.java`, `util/CycleCountStrategy.java`) | 📗 [wms1-sysprop-catalog.md](../data-dictionary/wms1-sysprop-catalog.md) §14 | `getDirection()` |
| `TenantContext` / `TenantFilter` | — (no class found in v1 codebase; single-tenant) ⚠ | In v1 there is no per-request tenant switch; datasource is fixed per deployment | 📘 [wms1-tenant-routing-datasource-topology.md](./wms1-tenant-routing-datasource-topology.md) | N/A — see v2 for multi-tenant equivalent |

⚠ `TenantContext` / `TenantFilter` classes listed in the task brief do not exist in the v1 codebase at the searched paths. V1 is single-tenant; `AbstractRestController` + `FacilityDto` handle facility-scoping via HTTP headers, but there is no dynamic datasource routing class equivalent to v2's `TenantFilter`.

---

## 10. Coverage Matrix

| Category | Total functions | With workflow doc | Partial / indirect | No doc |
|---|---|---|---|---|
| Mobile ops | 12 | 10 (all ops pages) | 0 | 2 (Lookup — read-only; LPN — reserved) |
| Web ops | 15 | 10 | 2 (handling units, dashboard) | 3 (club-fulfillment, transfer-fulfillment — subpages) |
| Master data | 9 | 0 | 1 (fixed-locations → sysprop) | 8 (generic CRUD) |
| Reports | 9 | 0 | 9 (entity + audit tables) | 0 |
| Admin | 1 | 0 | 1 (permission-map) | 0 |
| Error | 2 | 0 | 2 (permission-map) | 0 |
| Service → doc | 18 services | 15 with direct doc | 2 (WmsConstants, LosSyspropService → catalog) | 1 (TenantContext/Filter — absent in v1) |

---

## 11. How to use this doc

| Starting point | Action |
|---|---|
| Support call: "X feature doesn't work" | Find X in §2 / §3 → open linked doc → use its "How to debug" section |
| New engineer onboarding | Read §2 + §3 for platform overview; pick one workflow to deep-dive |
| Coverage audit | Scan §10 + §4–§7 — any row without a direct doc link is a coverage candidate |
| Touching a service method | Find service in §9 → open listed docs before making changes |
| Security / role audit | Cross-reference role column with 📘 [wms1-function-permission-map.md](./wms1-function-permission-map.md) |
| Deprecating a page | Confirm it's in §8 before deleting |
| v1 → v2 delta | See 📘 [wms1-vs-wms2-delta.md](./wms1-vs-wms2-delta.md) for divergence from v2 equivalents |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Mobile menu (`store/home.js:19-93`), web menu (`util/appMenuList.js`), all page files under `pages/` (both UIs), endpoint patterns from all `controller/` and `controller/mobile/` files, service public-method signatures, `WmsConstants.java:329-405` role constants | 11 mobile pages + 45+ web pages enumerated; 18 services indexed; TenantContext/Filter confirmed absent in v1 | Code grep + file enumeration across v1/wms-api + v1/wms-web-ui + v1/wms-mobile-ui |
| 2026-05-06 | `PickPathConfig.java` confirmed at `net/aim_ai/wms/service/`; `WmsConstants.java:1069-1070` constant confirmed; consumers confirmed as `util/DefaultStrategy.java` + `util/CycleCountStrategy.java`; §9 row added | `PickPathConfig` row added to §9 service index | Code grep |

**Re-verify every 90 days.** Next due: **2026-07-30** — any new page or controller invalidates a row. Pair with the `verify-docs` skill audit on the menu files.
