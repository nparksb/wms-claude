---
title: "WMS v2 — Function → Documentation Map"
type: architecture
status: active
version: v2
scope: function-map
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-08
verified_by: enumeration of wms2-web-ui + wms2-mobile-ui menus + wms2-api endpoints
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

- 📘 Architecture doc · 📕 Workflow doc · 📗 Data-dictionary doc

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
| Lock Report | `/reports/lock-report` | super-admin, inventory-manager | search for locks | view `LockOverviewDtoView` |
| Receiving Report | `/reports/receiving-report` | super-admin, inventory-manager, receiving, outbound+receiving | `/inboundNotice/*` | views `ReceivedDtoView`, `ReceivingDtoView` |
| SKU Location Report | `/reports/sku-location-report` | all with reports | mixed | entities + views |
| Flowbin Report | `/reports/flowbin-report` | all with reports | monitor-view endpoint | view `FlowbinMonitorView` |
| Parcel Picking Report | `/reports/parcel-picking-report` | all with reports | monitor-view | view |
| Outbound Parcel Report | `/reports/outbound-parcel-report` | all with reports | monitor-view | view `ParcelMonitorView` |
| Stock Unit Record | `/reports/stock-unit-record` | all with reports | `/stockrecord/*` | entity `Stockrecord` (audit trail) |
| Container Record | `/reports/container-record` | all with reports | `/unitloadRecord/*` | entity `UnitloadRecord` |

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

## 9. Coverage Matrix

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

## 10. How to use this doc

| Starting point | Action |
|---|---|
| Support call: "X feature doesn't work" | Find X in §2 / §3 → open linked doc → use its "How to debug" section |
| New engineer onboarding | Read §2 + §3 to understand what the platform offers; pick one workflow to deep-dive |
| Coverage audit | Scan §9 + §4–§7 — any row without a direct doc link is a coverage candidate |
| Security audit | Cross-reference role column with 📘 [keycloak-role-matrix](./wms2-keycloak-role-matrix.md) |
| Deprecating a page | Confirm it's in §8 before deleting |

---

## 11. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | Mobile menu (`store/home.js:19-94`), web menu (`util/appMenuList.js`, `layouts/default.vue:248-268`), all page files under `pages/` (both UIs), endpoint patterns from Vuex actions | 45 distinct functions enumerated; 12 mobile + 33 web (ops / master / reports / admin / error / legacy) | Code read (grep + file listing across both UI repos) |

**Re-verify every 90 days.** Next due: **2026-07-18** — any new page added to either UI invalidates a row. Pair this with the verify-docs skill audit on the menu files.
