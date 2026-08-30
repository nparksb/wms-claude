---
title: "WMS v2 — Function → Documentation Map"
type: architecture
status: active
version: v2
scope: function-map
owner: Nam Park
created: 2026-04-19
updated: 2026-08-24
last_verified: 2026-08-29
verified_by: enumeration of wms2-web-ui + wms2-mobile-ui menus + wms2-api endpoints; §9 symbol axis derived from find(*Controller*.java) + symbol grep over workflows/architecture/design docs (SBDEV-2803). 2026-08-24 (SBDEV-3063): §9's five security rows re-verified against origin/develop @ 5b704e5 and corrected — GUARDED 11→14, AccessDecision gained CONFLICTING_ANNOTATIONS, PublicHandler row added, FunctionGuardInterceptor's SDR reachability corrected per SBDEV-3017 slice A. last_verified deliberately NOT bumped: only those rows were checked, not the whole map
related:
  - ./wms2-keycloak-role-matrix.md
  - ./wms2-end-to-end-request-journey.md
  - ../../_symptom-index.md
tags:
  - architecture
  - function-map
  - cross-reference
  - wms2
---

# WMS v2 — Function → Documentation Map

**Scope:** Every user-facing function in the WMS v2 platform, mapped to UI entry point, role gate, primary API endpoint, and canonical workflow / architecture doc · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

This is the support-triage entry page and coverage-audit table. When a user reports a problem, start here: find the row that matches the reported function, open the linked doc. When auditing documentation coverage, rows with "—" or "gap" in the last column are the open surface.

- 📘 Architecture doc · 📕 Workflow doc · 📗 Data-dictionary doc · 📙 Design doc

**Two lookup axes — pick the one matching what you have:**

| You have | Use | Coverage |
|---|---|---|
| A user-facing function, page path, or endpoint | §2–§8 | Complete as of the §12 log — every menu-reachable page in both UIs is enumerated |
| A Java class or method name (code change, stack trace, plan) | **§9** | Controllers complete (all 61); services primary-only, not exhaustive |

**How complete is this file?** The function axis (§2–§8) is an enumeration, so a missing page means the map is stale — re-verify. The symbol axis (§9) is an *index*, deliberately not exhaustive at method level: **a symbol not listed means "not indexed yet", never "no docs exist."** Never conclude from a failed grep here that a subsystem is undocumented — confirm against `workflows/` and `design/` directly before deciding no doc applies.

Source of truth on what exists:

- Mobile menu: `v2/wms2-mobile-ui/store/home.js:19-94` (11 workflow pages + error pages)
- Web menu: `v2/wms2-web-ui/util/appMenuList.js` + `layouts/default.vue:30-86,248-268` (role-filtered)
- Web pages: `v2/wms2-web-ui/pages/` (~57 page files)
- API endpoints: base prefix `/v3`, mobile prefix `/mobile/*`, public prefix `/api/public/*`

All mobile requests inject headers `Authorization`, `X-Tenant-ID`, `facility_code` via `v2/wms2-mobile-ui/plugins/axios.js:95-139`; web UI uses the analogous plugin. See [wms2-end-to-end-request-journey.md](./wms2-end-to-end-request-journey.md) for the full journey.

---

## 2. Mobile UI Functions (12 pages)

All under base path `/mobile/`. Source of page list: `wms2-mobile-ui/pages/*.vue`. Role gate source: `store/home.js:19-94`.

| Function | Mobile page | Role | Primary API endpoint(s) | Canonical doc |
|---|---|---|---|---|
| Lookup (global search) | `/lookup` | `MOBILE_UI_VIEW_INFO` | `/lookup/search/{value}`, `/lookup/stockListByItemNumber/{item}`, `/lookup/unitLoadListByLocationName/{loc}`, `/lookup/locationByLocationName/{loc}` | 📗 [landlord-vs-tenant-entity-map](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md) (read-only lookup; no workflow) |
| Putaway | `/putaway` | `MOBILE_UI_VIEW_PUT_AWAY` | `/mobile/putAway/*` | 📕 [wms2-receiving-putaway-workflow §5](../workflows/wms2-receiving-putaway-workflow.md) |
| Move Unitload | `/move-unitload` | `MOBILE_UI_VIEW_TRANSFER` | `/mobile/moveUnitload/*` | 📕 [wms2-move-stock-unitload-workflow](../workflows/wms2-move-stock-unitload-workflow.md) |
| Move Stock | `/move-stock` | `MOBILE_UI_VIEW_STOCK_TRANSFER` | `/mobile/moveStock/*` | 📕 [wms2-move-stock-unitload-workflow](../workflows/wms2-move-stock-unitload-workflow.md) |
| Picking | `/picking` | `MOBILE_UI_VIEW_PICKING` | `/mobile/picking/*` | 📕 [wms2-picking-workflow](../workflows/wms2-picking-workflow.md) |
| Palletizing | `/palletizing` | `MOBILE_UI_VIEW_PALLETIZING` | `/mobile/palletizing/*` | 📕 [wms2-bol-truck-loading-workflow §4](../workflows/wms2-bol-truck-loading-workflow.md) |
| Truck Loading | `/truck-loading` | `MOBILE_UI_VIEW_TRUCK_LOADING` | `/mobile/truckLoading/loadOrder`, `/scanPallet`, `/scanGate` | 📕 [wms2-bol-truck-loading-workflow §5](../workflows/wms2-bol-truck-loading-workflow.md) |
| Cycle Count | `/cycle-count` | `MOBILE_UI_VIEW_CYCLE_COUNT` | `/cycleCountLos/orderList`, `/locationList/{id}`, `/unitLoadList/{orderId}/{locationId}`, `/processScanUnitLoad`, `/countUnitLoad`, `/recountUnitLoad` | 📕 [wms2-cycle-count-workflow](../workflows/wms2-cycle-count-workflow.md) |
| Replenish Process | `/replenish` | `MOBILE_UI_VIEW_REPLENISHMENT` | `/mobile/replenish/*` | 📕 [wms2-replenish-workflow](../workflows/wms2-replenish-workflow.md), [wms2-multi-unitload-replenish](../workflows/wms2-multi-unitload-replenish.md) |
| Replenish Request | `/replenish-request` | `MOBILE_UI_VIEW_REPLENISHMENT` | `/mobile/replenish/request/*` | 📕 [wms2-replenish-order-creation](../workflows/wms2-replenish-order-creation.md) |
| Transfer Process | `/transfer-order` | `WEB_UI_VIEW_TRANSFER_ORDER` ⚠ | `/mobile/transferOrder/*` | 📕 [wms2-transfer-order-workflow](../workflows/wms2-transfer-order-workflow.md) |
| (LPN Association) | *(not in menu)* | `MOBILE_UI_VIEW_LPN_ASSOCIATION` | — | reserved / unused |

⚠ **Transfer Process** uses a `WEB_UI_*` role on a mobile page — naming oversight preserved to avoid breaking existing Keycloak realm config. See [wms2-keycloak-role-matrix.md §3.8](./wms2-keycloak-role-matrix.md).

---

## 3. Web UI Functions — Operations

Source: `util/appMenuList.js` + `pages/`. Role selection by Keycloak **group** (`super-admin`, `inventory-manager`, `outbound-manager`, `receiving`, combos); not per-page realm role.

| Function | Web page | Group(s) | Primary API endpoint(s) | Canonical doc |
|---|---|---|---|---|
| Dashboard | `/dashboard` | all | mixed — monitor-view endpoints | 📘 [entity-enumeration-report](./wms2-entity-enumeration-report.md) + per-widget workflow |
| Receiving — Inbound Notices | `/receiving/inbound-notices?tab=open\|closed` | super-admin, inventory-manager, receiving, outbound+receiving | `/inboundNotice/search/*`, `/inboundNotice/{id}` | 📕 [wms2-receiving-putaway-workflow §3–4](../workflows/wms2-receiving-putaway-workflow.md) |
| Receiving — Open Notice Detail | `/receiving/openNotice/:id` + `/receive` | same | `/inboundNotice/{id}/receive` POST | 📕 same §4 |
| Receiving — Closed Notice Detail | `/receiving/closedNotice/:id` | same | `/inboundNotice/{id}` GET | 📕 same |
| Internal Ops — Replenishment | `/internalOps/replenishment?tab=open\|closed` | super-admin, inventory-manager | `/replenishment/search/*` | 📕 [wms2-replenish-workflow](../workflows/wms2-replenish-workflow.md) |
| Internal Ops — Cycle Count | `/internalOps/cycle-count?tab=open\|closed` | super-admin, inventory-manager | `/cycleCountLos/*` | 📕 [wms2-cycle-count-workflow](../workflows/wms2-cycle-count-workflow.md) |
| Cycle Count — Detail (planned/closed) | `/internalOps/cycleCount/{planned\|closed}/:id` | same | `/cycleCountLos/{id}` | 📕 same |
| Outbound — Pick-Pack | `/outbound/pick-pack` + detail `:id` | super-admin, inventory-manager, outbound-manager | `/pickPackLo/search/*` | 📕 [wms2-picking-workflow](../workflows/wms2-picking-workflow.md) |
| Outbound — Club (order list) | `/outbound/club` + detail `:id` + `/parcel-details` | same | `/clubLine/search/*` | 📕 [wms2-club-run-workflow](../workflows/wms2-club-run-workflow.md) |
| Outbound — Transfer (order list) | `/outbound/transfer` + detail `:id` | same | `/transfers/search/*` | 📕 [wms2-transfer-order-workflow](../workflows/wms2-transfer-order-workflow.md) |
| Outbound — Outbound BOL | `/outbound/outbound-bol` + detail `:id` + `/parcel-details` | same | `/v3/billOfLading/*` | 📕 [wms2-bol-truck-loading-workflow](../workflows/wms2-bol-truck-loading-workflow.md) |
| Processes — Club Run (execution) | `/processes/club-run` | super-admin, inventory-manager, outbound-manager | `/clubLine/activeClubRun`, `/clubLine/inactiveClubRun`, `/clubLine/skus`, `/unitLoads`, `/parcels`, `/runClubLine/{id}` | 📕 [wms2-club-run-workflow](../workflows/wms2-club-run-workflow.md) |
| Processes — Club Fulfillment | `/processes/club-fulfillment` *(not in menu)* | same | `/clubLine/*` | 📕 same |
| Processes — Transfer Picking | `/processes/transfer-picking` | super-admin, inventory-manager, outbound-manager | `/transfers/activeTransfer`, `/inactiveTransfer`, `/skus`, `/unitLoads`, `/runTransfer/{id}` | 📕 [wms2-transfer-order-workflow](../workflows/wms2-transfer-order-workflow.md) |
| Processes — Transfer Fulfillment | `/processes/transfer-fulfillment` *(not in menu)* | same | `/transfers/*` | 📕 same |
| Handling Units | `/handlingUnits/handling-units` | super-admin, inventory-manager, outbound-manager, receiving | `/unitLoad/search/*`, `/container/search/*`, `/stockUnit/search/*` | 📗 [landlord-vs-tenant-entity-map §3.5–3.6](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md) |

---

## 4. Web UI Functions — Master Data (CRUD)

| Function | Web page | Group(s) | Primary API endpoint(s) | Doc status |
|---|---|---|---|---|
| Storage Locations | `/masterData/locationData/storage-locations` | super-admin, inventory-manager | `/storageLocation/search/*`, `/storageLocation`, `/{id}` | Generic CRUD — entity shape in 📗 [landlord-vs-tenant-entity-map §3.7](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md) |
| Location Types | `/masterData/locationData/location-types` | same | `/locationType/*` | same |
| Fixed Locations | `/masterData/locationData/fixed-locations` | same | `/fixLocationAssignment/*` | Tuning behavior in 📗 [sysprop-catalog §6](../data-dictionary/wms2-sysprop-catalog.md) (FIX_LOCATION_ASSIGNMENT_*) |
| Functional Areas | `/masterData/locationData/functional-areas` | same | `/locationArea/*` | 📗 [landlord-vs-tenant-entity-map §3.7](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md) |
| Sections | `/masterData/locationData/sections` | same | `/section/*` | same (drives picking type TOTES_ON_CART vs RAPID_PICKING) |
| Unit Load Types | `/masterData/locationData/unit-load-types` | same | `/unitloadType/*` | same |
| SKU Data | `/masterData/materialData/sku-data` | same | `/sku/search/*`, `/sku`, `/{id}` | same |
| SKU Units | `/masterData/materialData/sku-units` | same | `/itemunit/*` | same |
| Packaging | `/masterData/materialData/packaging` | same | `/boxtype/*` | same |

**Why no workflow doc for any of the above?** Generic CRUD — no state cascade, no backend business logic beyond entity validation. If a CRUD page fails, it's a frontend framework issue. The one exception (`fixed-locations`) affects replenishment thresholds and is covered in the sysprop catalog.

---

## 5. Web UI Functions — Reports (read-only)

| Function | Web page | Group(s) | Primary endpoint | Backed by |
|---|---|---|---|---|
| Inventory Report | `/reports/inventory-report` | all with reports access | `/stockUnit/search/*` | entity `Stockunit` + view `StockView` |
| Lock Report | `/reports/lock-report` | super-admin, inventory-manager | search for locks | views `LockOverviewDtoView` (default, excludes Shipped=405) + `LockOverviewAllDtoView` ("Include Shipped Locks" toggle) — SBDEV-2474 |
| Receiving Report | `/reports/receiving-report` | super-admin, inventory-manager, receiving, outbound+receiving | `/inboundNotice/*` | views `ReceivedDtoView`, `ReceivingDtoView` |
| SKU Location Report | `/reports/sku-location-report` | all with reports | mixed | entities + views |
| Flowbin Report | `/reports/flowbin-report` | all with reports | monitor-view endpoint | view `FlowbinMonitorView` |
| Parcel Picking Report | `/reports/parcel-picking-report` | all with reports | monitor-view | view |
| Outbound Parcel Report | `/reports/outbound-parcel-report` | all with reports | monitor-view | view `ParcelMonitorView` |
| Stock Unit Record | `/reports/stock-unit-record` | all with reports | `/stockrecord/*` | entity `Stockrecord` (audit trail) |
| Container Record | `/reports/container-record` | all with reports | `/unitloadRecord/*` | entity `UnitloadRecord` |
| Transaction Report (Detailed) | OMS V2 → Reports → Transaction Report | OMS-side | `/rest/report/getTransactionDetailedReport` | **PL/pgSQL function `transaction_detail()`**, not a view. Current definition: `db/migration/V2.2.12__fix_transaction_detail_ul_picks.sql` (chain: `V2.2.00` base → `V2.2.08` NULL-hardening SBDEV-2801 → `V2.2.12` UL-pick fix SBDEV-2890). Java callers: `ClientRepository:63`, `StockrecordRepository:24` (both `nativeQuery`) |
| Transaction Report (Summary) | OMS V2 → Reports → Transaction Report | OMS-side | `/rest/report/*` | **Function `transaction_summary()`**, defined in `V2.2.00` and **never replaced**. Callers: `ClientRepository:53`, `StockrecordRepository:34` |

**⚠ The two transaction-report functions are not interchangeable, and do not assume they reconcile.** They use different row-admission models — `transaction_summary` has *no* activitycode WHERE clause and classifies inside `CASE … ELSE 0` aggregates, while `transaction_detail` uses an explicit allow-list. Only the `depleted_picked` term is known to reconcile between them (pinned by `TransactionDetailUlPickIntegrationTest` AC-5). They also window on different columns — detail on `sr.modified`, summary on `sr.created` — so the same row can land in different periods for the two reports. See `sbdocs/1-Projects/wms2/plan/SBDEV-2890-transaction-detail-ul-picks-excluded.md` §8.3 / §10.4.

**Landmine:** a value CASE in `transaction_detail` can classify an `activitycode`/`type` pair its own WHERE allow-list never admits, producing an unreachable arm and silent divergence from Summary. That was SBDEV-1319 → SBDEV-2890 (picking), and one latent instance remains (`received` / `STOCK_REMOVED`+`STOCK_ALTERED`). `TransactionDetailAllowListStructuralIntegrationTest` guards the class.

**Why no workflow doc?** Reports are projections over views / audit tables — no user action, no state cascade. Inventory enumeration in 📘 [wms2-entity-enumeration-report.md](./wms2-entity-enumeration-report.md) and view-entity listing in 📗 [landlord-vs-tenant-entity-map §3.13](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md) cover the substrate. If a report is wrong, fix the view SQL.

---

## 6. Web UI Functions — Admin

| Function | Web page | Role | Primary endpoint(s) | Doc |
|---|---|---|---|---|
| Admin (dashboard) | `/admin` | `sb_admin` / super-admin group | `/v3/user/*`, `/v3/groups/*`, `/client/search/*`, `/userRole/search/*`, `/import/clients`, `/import/locations`, `/import/skus`, `/import/inbound-bols`, `/adminAction/triggerOrderReplenish`, `/triggerUpdateStock` | 📘 [keycloak-role-matrix §2.1 + §4](./wms2-keycloak-role-matrix.md) + individual CLAUDE.md for ad-hoc tasks |

**Why no workflow doc?** One-time setup / admin tasks. Better served by the role matrix + project CLAUDE.md than by a workflow walkthrough.

---

## 7. Error / system pages

| Function | Page | Purpose | Doc |
|---|---|---|---|
| Not affiliated | web `/not-affiliated`, mobile `/not-authorized` | User has no matching Keycloak group / role | 📘 [keycloak-role-matrix §2.1, §4](./wms2-keycloak-role-matrix.md) |
| Not authorized | web `/not-authorized`, mobile `/not-authorized` | User not a WMS user | same |
| Unknown tenant | both UIs `/unknown-tenant` | Subdomain didn't resolve to a tenant | 📘 [end-to-end-request-journey §3.1](./wms2-end-to-end-request-journey.md) |
| Unhealthy tenant | both UIs `/unhealthy-tenant` | `/tenant/health` returned false | 📘 [tenant-routing-datasource-topology §6.3](./wms2-tenant-routing-datasource-topology.md) |

---

## 8. Legacy / Hidden Pages (flagged for cleanup)

These files exist in the codebase but are not wired into any menu. Reachable by direct URL — audit and remove if dead.

| Path | Observed status |
|---|---|
| `pages/receiving/lookup.vue` | Commented-out from menu |
| `pages/outbound/transfer22.vue` | Numeric suffix suggests old version |
| `pages/masterData/locationData/storage-location_org.vue` | `_org` suffix suggests legacy |
| `pages/masterData/strategies/customer-orders.vue` | Test / experimental page |
| `pages/masterData/strategies/sku-data-nam.vue` | Test / experimental page (personal name) |
| `pages/reports/data-report.vue` | Generic query tool — commented out |

Recommendation: remove or quarantine in a dedicated folder after confirming no direct links point to them.

---

## 9. API Symbol → Doc Index

> **Added 2026-08-20 (SBDEV-2968 branch, not yet on `develop`).** New symbols, so a future grep by class name
> resolves rather than silently missing:
>
> | Symbol | What it is |
> |---|---|
> | `net.aim_ai.wms.security.RequiresFunction` | the gating annotation; values must be `FunctionEnum` constant **references** so a rename is a compile error |
> | `net.aim_ai.wms.security.FunctionGuardInterceptor` | the enforcement point; resolves on the **declaring class**, fail-closed inside an explicit **14**-controller set. Registered as a `MappedInterceptor` **bean** since SBDEV-3017 slice A, so Spring Data REST requests DO reach it (reaching ≠ gating: SDR's declaring classes carry no annotation and are outside the set, so they fall through allowed) |
> | `net.aim_ai.wms.security.FunctionGuardStartupAssertion` | fails the boot when a guarded handler carries no annotation **and no `@PublicHandler`**; also exposes two pure static seams (`findPublicHandlers`, `findMarkedHandlersOutsideGuarded`) so the boot enumeration is unit-assertable |
> | `net.aim_ai.wms.security.AccessDecision` | the decision record — `ALLOWED` / `MISSING_FUNCTION` / `NO_FUNCTIONS` / `USER_NOT_PROVISIONED` / `CONFLICTING_ANNOTATIONS`, each carrying its own metric tag |
> | `net.aim_ai.wms.security.PublicHandler` | **SBDEV-3063** — the deliberately-open marker. `@Target(METHOD)` only, mandatory `reason()`, resolved BEFORE any `@RequiresFunction` lookup so neither a method- nor class-level annotation can shadow it. Lets a controller join `GUARDED` while keeping named handlers open (`UserController`'s two UI bootstrap reads). Mutually exclusive with `@RequiresFunction` on the same method — both ⇒ `CONFLICTING_ANNOTATIONS`. ⚠️ Membership of `GUARDED` gives **default-to-class-function**, not fail-closed, once the class carries a class-level annotation: an unannotated new handler inherits that function rather than being denied |
> | `net.aim_ai.wms.service.AccessAuditService` | `GET /v3/adminAction/accessAudit`; one bulk Keycloak call, never per-row |
> | `net.aim_ai.wms.controller.UserAdministrationController` | **pre-existing since SBDEV-2870 PR #166 and previously unindexed here** — four `/v3/user/*` endpoints gated on `WEB_UI_VIEW_USER_MANAGEMENT` |
>
> ⚠️ `OrderCancellationController` **moved** from `controller/` to `controller/mobile/` on that branch. A grep
> against the old package will miss it.


**Why this section exists.** §2–§8 index the platform by *user-facing function and endpoint*. The workflow the root `CLAUDE.md` mandates — "grep this map for the affected service/method" — starts from a **Java symbol** instead, and before 2026-08-03 this file contained no class or method names at all, so every such grep returned nothing and read as "no docs apply". This section is that missing axis. Added per SBDEV-2803 (surfaced by SBDEV-2632, where a cycle-count change grepped `CycleCountController` / `CyclecountService` and found nothing, though `wms2-cycle-count-workflow.md` covered the subsystem in detail).

**v1 counterpart:** [wms1-function-to-docs-map §9 *Service Method → Doc Index*](./wms1-function-to-docs-map.md) — v1 had this axis from the start and v2 did not, which is the actual gap SBDEV-2803 closes. The two are shaped differently on purpose: v1 lists 18 hot services one-per-row with file paths and section pointers (no controllers); v2 groups by subsystem so all 61 controllers fit without a 61-row table.

**Granularity: controllers plus primary services, not every method.** A grep for a method name (`exportCycleCount`) will still miss; a grep for its controller or service will land. When you only have a method, grep the enclosing class instead. Rows are derived from the symbols the target docs actually name (`grep -ohE "[A-Z][A-Za-z]*(Controller|Service)\b"` over `workflows/wms2-*.md` + `architecture/wms2-*.md` + `design/wms2-*.md`), so a row here means the doc genuinely discusses the symbol — not that it merely sounds related.

| Subsystem | Controllers | Primary services | Docs |
|---|---|---|---|
| Receiving / putaway | `AdviceController`, `AdviceRestController`, `ReceivingController`, `GoodsReceiptPositionController`, `PutawayController`, `FileImportController`, **`PutawayConfigController`** | `AdviceService`, `ReceivingService`, `GoodsreceiptService`, `MobilePutAwayService`, **`PutawayDestinationResolver`**, **`PutawayDestinationQueryService`**, **`PutawayDestinationValidator`**, **`PutawayConfigService`**, **`PutawayConfigAuditService`** | 📕 [wms2-receiving-putaway-workflow](../workflows/wms2-receiving-putaway-workflow.md) §4.2, §5.2 · destination hierarchy: 📗 [sysprop-catalog](../data-dictionary/wms2-sysprop-catalog.md) §10 (`DEFAULT_PUTAWAY_LOCATION`) · plan `SBDEV-2732` (BOTH PHASES MERGED 2026-08-11; PR #139 landed) |
| Picking | `PickingController`, `PickingOrderPositionController` | `MobilePickingService`, `PickingorderBusinessService`, `PickingOrderMergeService`, `PickingorderPositionService`, `ReleaseOrderJobService`, **`LocationPathOrdering`** + `InMemoryLocationComparator` / `DefaultStrategy` / `CycleCountStrategy` (SBDEV-3133 — pick-path tier order, §9.1 of the workflow doc) | 📕 [wms2-picking-workflow](../workflows/wms2-picking-workflow.md) |
| Replenishment | `ReplenishController`, `ReplenishOrderController`, `ReplenishmentReconciliationController` | `MobileReplenishService`, `ReplenishGeneratorService`, `ReplenishorderService`, `ReplenishOrderJobService`, `ReplenishmentOrderMaintenanceService`, `ReplenishmentOrderSourceSyncService` | 📕 [wms2-replenish-workflow](../workflows/wms2-replenish-workflow.md) · 📕 [order-creation](../workflows/wms2-replenish-order-creation.md) · 📕 [multi-unitload](../workflows/wms2-multi-unitload-replenish.md) · 📙 [replenishment-design](../design/wms2-replenishment-design.md) |
| Cycle count | `CycleCountController`, `CycleCountLosController` | `CyclecountService`, `MobileCycleCountService` | 📕 [wms2-cycle-count-workflow](../workflows/wms2-cycle-count-workflow.md) |
| Move stock / unit load | `MoveStockController`, `MoveUnitloadController`, `UnitLoadController`, `UnitloadRecordController`, `UnitloadRestController` | `MobileMoveStockService`, `MobileMoveUnitloadService`, `UnitloadBusinessService`, `UnitloadRecordService`, `StockunitBusinessService`, `UnitloadService`, **`ScannedCodeResolver`** (SBDEV-3134 — scanned-identifier case resolution, §4.2 of the workflow doc) | 📕 [wms2-move-stock-unitload-workflow](../workflows/wms2-move-stock-unitload-workflow.md) · 📙 [stockunit-design](../design/wms2-stockunit-design.md) |
| BOL / palletizing / truck loading | `BillOfLadingController`, `PalletizingController`, `TruckLoadingController` | `BillofladingService`, `BillofladingPositionService`, `MobilePalletizingService`, `MobileTruckLoadingService` | 📕 [wms2-bol-truck-loading-workflow](../workflows/wms2-bol-truck-loading-workflow.md) |
| Transfer orders | `TransferOrderController`, `TransfersController` | `TransferOrderService`, `MobileTransferOrderService`, `TransferService` | 📕 [wms2-transfer-order-workflow](../workflows/wms2-transfer-order-workflow.md) |
| Club runs | `ClubLineController`, `CustomerOrderBatchController` | `CustomerorderBatchService`, `ManageOrderService`, `StaleClubBatchCleanupJobService` | 📕 [wms2-club-run-workflow](../workflows/wms2-club-run-workflow.md) |
| Order cancellation | `OrderCancellationController`, `CustomerOrderController`, `CustomerOrderPositionController` | `CustomerorderService`, `CustomerorderPositionService` | 📕 [wms2-cancel-cascade-workflow](../workflows/wms2-cancel-cascade-workflow.md) |
| OMS integration / legacy REST | `OrderRestController`, `SkuRestController`, `StockCountRestController`, `TransactionReportRestController`, `UtilRestController`, `AdminActionController`, `AbstractRestController`, `MessageController`, `MessageDummyController` | `OmsNotificationService`, `OutboxService`, `OutboxDispatchService`, `NotificationService`, `StockChangeNotificationService`, `MessageService`, `HttpRestService` | 📘 [wms2-oms-integration-map](./wms2-oms-integration-map.md) · 📙 [rest-api-reference](../design/wms2-rest-api-reference.md) · 📙 [rest-idempotency-design](../design/wms2-rest-idempotency-design.md) |
| Auth / users / roles | `UserController`, `UserGroupController`, `UserRoleController`, `TokenController`, `AdminController` | `KeycloakService`, `RoleService`, `GroupService`, `AccessService` | 📘 [wms2-keycloak-role-matrix](./wms2-keycloak-role-matrix.md) |
| Tenant routing / health / system | `TenantDiscoveryController`, `TenantHealthController`, `SystemController`, `PublicVersionController` | `TenantHealthService`, `LandlordService`, `AdvisoryLockService`, `LockService` | 📘 [wms2-tenant-routing-datasource-topology](./wms2-tenant-routing-datasource-topology.md) · 📘 [end-to-end-request-journey](./wms2-end-to-end-request-journey.md) |
| Master data (CRUD) | `BoxTypeController`, `ClientController`, `LocationController`, `SectionController`, `ShipperIdController`, `ItemDataController`, `LookupController`, `FixLocationAssignmentController`, `SystemPropertyController` | `LocationService`, `ItemdataService`, `ClientService`, `SyspropService`, `FixLocationAssignmentService`, `SkuBatchCreateUpdateService` | Mostly generic CRUD — entity shapes in 📗 [landlord-vs-tenant-entity-map](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md); sysprop behavior in 📗 [sysprop-catalog](../data-dictionary/wms2-sysprop-catalog.md) · 📘 [caching-strategy](./wms2-caching-strategy.md); fixed locations in 📙 [replenishment-design](../design/wms2-replenishment-design.md) |
| Reports / dashboards / stock views | `ReportController`, `DashboardController`, `StockRecordController`, `StockUnitController` | `StockrecordService`, `StockunitService`, `WarehouseStockReportService`, `StockReportService`, `ViewDtoService`, `ParcelMonitorViewService` | 📘 [wms2-entity-enumeration-report](./wms2-entity-enumeration-report.md) — no workflow doc by design (rationale in §5) |
| Printing | `PrinterController`, `PrinterRestController` | `PrintService` | **Gap — no doc** (tracked: SBDEV-2808). Nearest coverage is the label-reprint discussion inside 📙 [stockunit-design](../design/wms2-stockunit-design.md), which covers *when* a reprint is eligible, not how printing works |
| Scheduled jobs (no controller) | — | `OrderReleaseJobService`, `ReplenishOrderJobService`, `ReleaseOrderJobService`, `CleanupBatchService`, `MessageCleanupBatchService`, `CleanUpOldMessageJobService` | 📘 [wms2-scheduled-jobs-catalog](./wms2-scheduled-jobs-catalog.md) |
| Cross-cutting (any symbol above) | — | — | 📘 [transaction-osiv-boundary-map](./wms2-transaction-osiv-boundary-map.md) (tx + OSIV boundaries) · 📘 [state-machine-catalog](./wms2-state-machine-catalog.md) (state transitions) · 📘 [exception-taxonomy](./wms-exception-taxonomy.md) |

**Completeness of this section:** all 61 `*Controller` classes under `v2/wms2-api/src/main/java` are accounted for above (verified by enumeration — see §12). Services are the *primary* ones per subsystem, not exhaustive; `wms2-java-package-analysis.md` is the full inventory. A symbol absent here is **not indexed yet** — it does not mean no doc covers it. Re-run the derivation grep in §9's preamble after adding a controller or a workflow doc.

---

## 10. Coverage Matrix

| Category | Total functions | With workflow doc | Partial / indirect | No doc (intentional) |
|---|---|---|---|---|
| Mobile ops | 12 | 11 (incl. transfer-order via workflow doc) | 0 | 1 (LPN reserved) |
| Web ops | 15 | 10 | 2 (handling units, dashboard — covered by entity + monitor docs) | 3 (club-fulfillment, transfer-fulfillment — subpages of their parents) |
| Master data | 9 | 0 | 1 (fixed-locations → sysprop tuning) | 8 (generic CRUD) |
| Reports | 9 | 0 | 9 (view entities + audit tables) | 0 |
| Admin | 1 | 0 | 1 (role matrix) | 0 |
| Error | 4 | 0 | 4 (request-journey + role-matrix + tenant-routing) | 0 |

**Coverage verdict:** ~83% of operational functions have a direct workflow doc; the remaining ~17% are either indirect (covered by entity / sysprop / monitor docs) or genuinely not worth their own workflow (generic CRUD, read-only reports, one-time admin).

---

## 11. How to use this doc

| Starting point | Action |
|---|---|
| Support call: "X feature doesn't work" | Find X in §2 / §3 → open linked doc → use its "How to debug" section |
| **Code change: you have a class / method name** | Look it up in **§9** (API Symbol → Doc Index) → read the linked doc's relevant section before writing code or a plan. This is the lookup the root `CLAUDE.md` mandates. A miss means "not indexed", not "no docs exist" |
| New engineer onboarding | Read §2 + §3 to understand what the platform offers; pick one workflow to deep-dive |
| Coverage audit | Scan §10 + §4–§7 — any row without a direct doc link is a coverage candidate |
| Security audit | Cross-reference role column with 📘 [keycloak-role-matrix](./wms2-keycloak-role-matrix.md) |
| Deprecating a page | Confirm it's in §8 before deleting |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-08-29 | §9 rows extended: **`ScannedCodeResolver`** added to *Move stock / unit load* (SBDEV-3134) and **`LocationPathOrdering`** + the three comparators added to *Picking* (SBDEV-3133), both merged 2026-08-29. Neither class was reachable by a §9 class-name grep before this. | Both confirmed present on `origin/develop` at `e5daa8ca` and confirmed indexed here afterwards (grep count 1 each). Scoped to §9 — §2–§8 menu rows were NOT re-walked, and no UI page was added by these PRs. | Code read + grep of this doc |
| 2026-04-19 | Mobile menu (`store/home.js:19-94`), web menu (`util/appMenuList.js`, `layouts/default.vue:248-268`), all page files under `pages/` (both UIs), endpoint patterns from Vuex actions | 45 distinct functions enumerated; 12 mobile + 33 web (ops / master / reports / admin / error / legacy) | Code read (grep + file listing across both UI repos) |
| 2026-08-03 | **§9 symbol axis added (SBDEV-2803).** Enumerated every `*Controller*.java` under `v2/wms2-api/src/main/java`; derived symbol→doc rows from `grep -ohE "[A-Z][A-Za-z]*(Controller\|Service)\b"` over `workflows/wms2-*.md`, `architecture/wms2-*.md`, `design/wms2-*.md` | 61 controllers found, all 61 mapped to a subsystem row. Pre-existing state confirmed: **0** Java symbols anywhere in this file, so the `CLAUDE.md`-mandated symbol grep returned nothing for *every* subsystem, not only cycle count. One real coverage gap surfaced: printing (`PrinterController`, `PrinterRestController`, `PrintService`) has no doc → filed as SBDEV-2808 | Code read + doc-symbol derivation grep |

**Re-verify every 90 days.** Next due: **2026-11-27** — any new page added to either UI invalidates a §2–§8 row; any new controller or new workflow doc invalidates §9. Pair this with the verify-docs skill audit on the menu files.

**§9 re-derivation one-liner** (run from the repo root; compare output against §9):

```bash
find v2/wms2-api/src/main/java -name "*Controller*.java" | sed 's|.*/||;s|\.java||' | sort
cd sbdocs/3-Resources && for f in workflows/wms2-*.md architecture/wms2-*.md design/wms2-*.md; do
  s=$(grep -ohE "[A-Z][A-Za-z]*(Controller|Service)\b" "$f" | sort -u | tr '\n' ' ')
  [ -n "$s" ] && printf '%-46s %s\n' "$(basename "$f" .md)" "$s"
done
```
