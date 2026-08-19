---
title: "WMSv2: the Web UI has no authorization layer — the menu is hardcoded to super-admin and every user sees all 30 items"
ticket: "SBDEV-2967"
ticket_url: "https://app.clickup.com/t/868krr3rq"
type: "bugfix"
priority: "high"
status: "draft — pending review"
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-16
updated: 2026-08-17
db_verified: true
related:
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
  - ../../../3-Resources/architecture/wms2-keycloak-role-matrix.md
tags:
  - plan
  - security
  - authorization
---

# SBDEV-2967 — The Web UI has no authorization layer

**Ticket:** [SBDEV-2967](https://app.clickup.com/t/868krr3rq)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix (security)
**Repos:** `v2/wms2-web-ui` (primary), `v2/wms2-api`
**Status:** draft — pending review

> **Companion to [SBDEV-2968](SBDEV-2968-mobile-ui-function-gating-enforcement.md).** That plan builds the enforcement mechanism (`@RequiresFunction` + `FunctionGuardInterceptor`); this one consumes it. **2968 must land first** — see §12.

---

## 0. Affected sites

### 0.A The web menu — 9 top-level entries, 30 leaf destinations, **0 gated**

`util/appMenuList.js` defines five persona menus. `layouts/default.vue:284-285` reads exactly one of them:

```js
links() {
  return menuList["super-admin"];   // no argument, no role lookup, no filter
}
```

| # | Site | Finding |
|---|---|---|
| 0.1 | `layouts/default.vue:284-285` | Menu hardcoded to the `super-admin` key |
| 0.2 | `util/appMenuList.js:2, 197, 355, 441, 545` | 5 persona menus; **4 are dead code** |
| 0.3 | `store/index.js:92-101` → `pages/index.vue:114` | `getUserRoles` calls `/user/getAllRoles/{username}`, **commits nothing**, and its only caller ignores the return |
| 0.4 | no `middleware/` directory | No route guards — every page is deep-linkable |
| 0.5 | `pages/admin.vue:51-58` | All 6 admin tabs hardcoded, **including User Management** |
| 0.6 | repo-wide grep for `WEB_UI_VIEW` / `WEB_UI_ACTION` | **zero** hits outside Cypress fixtures |

### 0.A.1 The authoritative menu → function table (all 30 leaves)

Every row's **Endpoints** column is what the leaf's store module actually calls. **Derivation honesty:** where the endpoints identify the subject, the function is endpoint-derived; where they do not, the assignment is **semantics-derived** and marked ⚠ — those are the rows a reviewer should challenge.

> **Corrected at architect review.** An earlier draft marked all 9 report rows ⚠ on the grounds that "they all call the same generic `/report`". **That was wrong.** `/report` is a *class prefix* (`ReportController:30` → `@RequestMapping("/v3/report")`) with a distinct method path per report — `exportInventory`, `exportLock`, `exportReceiving`, `exportSkuLocation`, `exportFlowbin`, `exportParcelPicking`, `exportOutboundParcel`, `exportStockUnitRecord`, `exportContainerRecord`, plus the `*View` GETs. Each report store calls exactly one. So **8 of those 9 rows are properly endpoint-grounded** and the ⚠ is removed. Only **2 rows remain semantics-derived: #1 Dashboard and #5 Pick Pack.**

| # | Menu → leaf | Store module | Endpoints observed | Function | Basis |
|---|---|---|---|---|---|
| 1 | Dashboard | `dashboard/*` | `/dashboard`, `/printer` | `WEB_UI_VIEW_ORDER_MONITOR` | ⚠ semantics — `/dashboard` serves several monitors |
| 2 | Receiving → Inbound Notices | `receiving/*` | `/advice`, `/receiving`, `/goodsreceiptposition`, `/receivingDtoView`, `/itemdata`, `/location`, `/boxtype`, `/unitloadType` | `WEB_UI_VIEW_INBOUND_BOL` | endpoint (`/advice` = inbound BOL) |
| 3 | Internal Ops → Replenishment | `internalOps/replenishments.js` | `/replenishorder`, `/replenishOrder`, `/stockunit` | `WEB_UI_VIEW_REPLENISHMENT_ORDER` | endpoint |
| 4 | Internal Ops → Cycle Count | `internalOps/cycleCount.js`, `createCc.js` | `/cyclecount`, `/cycleCount`, `/itemdata`, `/locationArea` | `WEB_UI_VIEW_CYCLECOUNT` | endpoint |
| 5 | Outbound → Pick Pack | `outbound/pickPack.js` | `/customerOrder`, `/customerOrderPosition` | `WEB_UI_VIEW_PICKING_ORDER` | ⚠ semantics — order endpoints serve 4 leaves |
| 6 | Outbound → Club | `outbound/club.js` | `/clubLine`, `/customerorderBatch`, `/customerOrder…` | `WEB_UI_VIEW_CLUB_LINE` | endpoint (`/clubLine`) |
| 7 | Outbound → Transfer | `outbound/transfer.js` | `/transfers`, `/customerOrder` | `WEB_UI_VIEW_TRANSFER_ORDER` | endpoint (`/transfers`) |
| 8 | Outbound → Outbound BOL | `outbound/outboundBols.js` | `/billOfLading`, `/clubLine`, `/customerOrder`, `/location` | `WEB_UI_VIEW_BILL_OF_LADING` | endpoint |
| 9 | Processes → Club Run | `processes/clubRuns.js` | `/clubLine`, `/customerOrderBatch` | `WEB_UI_VIEW_CLUB_LINE` | endpoint |
| 10 | Processes → Transfer Picking | `processes/transferPicking.js` | `/transfers`, `/customerorder` | `WEB_UI_VIEW_TRANSFER_ORDER` | endpoint |
| 11 | Handling Units | **two stores** — `stockUnits.js` → `/stockUnit`; `container.js` → `/unitLoad`, `/printer` | both | **ANY-of `{WEB_UI_VIEW_STOCK_UNIT, WEB_UI_VIEW_CONTAINER}`** | endpoint — see note |
| 12 | MD → Storage Locations | `masterData/storageLocation.js` | `/location`, `/locationRack`, `/report` | `WEB_UI_VIEW_STORAGE_LOCATION` | endpoint |
| 13 | MD → Location Types | `masterData/locationType.js` | `/locationType`, `/location` | `WEB_UI_VIEW_STORAGE_LOCATION_TYPE` | endpoint |
| 14 | MD → Fixed Locations | `masterData/fixedLocation.js` | `/fixedAssignment` | `WEB_UI_VIEW_FIXED_ASSIGNMENT` | endpoint |
| 15 | MD → Functional Areas | `masterData/functionalArea.js` | `/locationArea` | `WEB_UI_VIEW_AREA` | endpoint |
| 16 | MD → Sections | `masterData/section.js` | `/section` | `WEB_UI_VIEW_SECTION` | endpoint |
| 17 | MD → Unit Load Types | `masterData/unitLoadType.js` | `/unitloadType` | `WEB_UI_VIEW_UNIT_LOAD_TYPE` | endpoint |
| 18 | MD → SKU Data | `masterData/skuData.js` | `/itemData` | `WEB_UI_VIEW_ITEM_DATA` | endpoint |
| 19 | MD → SKU Units | `masterData/skuUnit.js` | `/itemunit` | `WEB_UI_VIEW_ITEM_UNIT` | endpoint |
| 20 | MD → Packaging | `masterData/packaging.js` | `/boxtype`, `/boxType`, `/itemunit` | `WEB_UI_VIEW_CASE_TYPE` | endpoint (`boxtype` = case type) |
| 21 | Rpt → Inventory | `reports/inventory.js` | **`/report/exportInventory`**, `/stockView`, `/itemData` | `WEB_UI_VIEW_INVENTORY_RECORD` | endpoint |
| 22 | Rpt → Lock | `reports/lock.js` | **`/report/exportLock`** | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | endpoint |
| 23 | Rpt → Receiving | `reports/receiving.js` | **`/report/exportReceiving`**, `/receivingDtoView` | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | endpoint |
| 24 | Rpt → SKU Location | `reports/skuLocation.js` | **`/report/exportSkuLocation`**, `/viewWarehouseLocationReport` | `WEB_UI_VIEW_LOCATION_OVERVIEW` | endpoint |
| 25 | Rpt → Flowbin | `reports/flowbin.js` | **`/report/exportFlowbin`**, **`/report/flowbinMonitorView`** | `WEB_UI_VIEW_FLOWBIN_MONITOR` | endpoint |
| 26 | Rpt → Parcel Picking | `reports/parcelPicking.js` | **`/report/exportParcelPicking`**, **`/report/parcelPickingView`**, `/report/reprintLabels`, `/printer` | ⚠ **undecided — §10.9** | no matching constant exists |
| 27 | Rpt → Outbound Parcel | `reports/outboundParcel.js` | **`/report/exportOutboundParcel`**, **`/report/parcelMonitorView`**, `/billOfLading` | `WEB_UI_VIEW_PARCEL_MONITOR` | endpoint — it is this row, not 26, that calls `parcelMonitorView` |
| 28 | Rpt → Stock Unit Record | `reports/stockUnit.js` | **`/report/exportStockUnitRecord`**, `/stockrecord` | `WEB_UI_VIEW_STOCK_UNIT_RECORD` | endpoint |
| 29 | Rpt → Container Record | `reports/container.js` | **`/report/exportContainerRecord`**, `/unitloadRecord` | `WEB_UI_VIEW_UNIT_LOAD_RECORD` | endpoint |
| 30 | Admin | `admin/*` | see §3.4 | ANY-of the 6 tab functions | endpoint per tab |

**Note on #11 — Handling Units is one menu leaf backed by two stores.** `store/handlingUnits/stockUnits.js` reads `/stockUnit`; `store/handlingUnits/container.js` reads `/unitLoad`. A single function would hide the page from someone entitled to half of it, so it takes an **ANY-of**. The page's two tabs should additionally gate individually, or a `CONTAINER`-only user sees an empty Stock Units tab.

**2 of 30 rows remain semantics-derived** — #1 Dashboard and #5 Pick Pack. Dashboard calls `/dashboard`, which like `/report` has per-monitor method paths (`orderMonitorViewSummary`, `replenishMonitorViewSummary`), so row 1 is probably groundable the same way — **not yet checked**, and the honest state is ⚠. Pick Pack shares `/customerOrder*` with three other leaves, so no endpoint can separate it. Those two plus row 26 (§10.9) are the review surface.

**Also noted:** `store/reports/data.js` calls `/report/exportReceiving` — a **tenth** report store. It backs `pages/reports/data-report.vue`, which is **commented out of the menu** (§0.A), so it is correctly absent from this table. If that entry is ever re-enabled it needs a row.

### 0.B The 8 `WEB_UI_ACTION_*` constants — 1 enforced, 3 misused

| Constant | Backend reference | Actually enforced? |
|---|---|---|
| `ADJUST_LOCK_DAMAGED` | `StockunitService:232`, `MobileMoveStockService:251,256`, `MobileMoveUnitloadService:277,282` | ✅ **yes** — the only one |
| `DELETE_UNIT_LOAD` | `UnitLoadController:100, :134` | ❌ **no — passed as the `comment` argument** (§0.C) |
| `DELETE_UNIT_LOAD_RECURSIVE` | `UnitLoadController:163` | ❌ **no — same** |
| `ADJUST_AMOUNT`, `ADJUST_RESERVED_AMOUNT`, `ADJUST_LOCK_RELEASE_LOCK`, `ADJUST_LOCK_ON_HOLD`, `PRINT_TOTE_LABELS` | seed only | ❌ none |

### 0.B.1 `StockUnitController` endpoint-by-endpoint — **0 of 16 guarded**

The constants in §0.B are abstractions; this is the concrete surface behind them. Enumerated 2026-08-17 on the SBDEV-2870 branch. **Fix E's real scope is the 10 rows marked ⬛** — the 8 originally enumerated plus the damaged-lock pair received from SBDEV-2870 on 2026-08-17 (§3.5.1).

| # | Endpoint | Method | Guard today | Fix E target |
|---|---|---|---|---|
| 0.B.1 ⬛ | `POST /v3/stockUnit/transferToDamaged` | `transferToDamaged` (`:444`) | ❌ **none** | `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` — **received from SBDEV-2870, design proven (§3.5.1)** |
| 0.B.2 ⬛ | `POST /v3/stockUnit/bulkTransferToDamaged` | `bulkTransferToDamaged` (`:485`) | ❌ **none** | same — **received from SBDEV-2870** |
| 0.B.3 ⬛ | `POST /v3/stockUnit/adjustAmount` | `adjustAmount` | ❌ **none** | `WEB_UI_ACTION_ADJUST_AMOUNT` |
| 0.B.4 ⬛ | `POST /v3/stockUnit/bulkAdjustAmount` | `bulkAdjustAmount` | ❌ **none** | same |
| 0.B.5 ⬛ | `POST /v3/stockUnit/adjustReservedAmount` | `adjustReservedAmount` | ❌ **none** | `WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT` |
| 0.B.6 ⬛ | `POST /v3/stockUnit/bulkAdjustReservedAmount` | `bulkAdjustReservedAmount` | ❌ **none** | same |
| 0.B.7 ⬛ | `POST /v3/stockUnit/setLockOnHold` | `setLockOnHold` | ❌ **none** | `WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD` |
| 0.B.8 ⬛ | `POST /v3/stockUnit/bulkSetLockOnHold` | `bulkSetLockOnHold` | ❌ **none** | same |
| 0.B.9 ⬛ | `POST /v3/stockUnit/removeLock` | `removeLock` | ❌ **none** | `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK` |
| 0.B.10 ⬛ | `POST /v3/stockUnit/bulkRemoveLock` | `bulkRemoveLock` | ❌ **none** | same |
| 0.B.11 | `POST /v3/stockUnit/transferStock` | `transferStock` | ❌ none | **EXCLUDED — §0.B shared with mobile** |
| 0.B.12 | `POST /v3/stockUnit/bulkTransferStock` | `bulkTransferStock` | ❌ none | see note 3 |
| 0.B.13 | `GET /v3/stockUnit/storageLocationsForStockMovement` | `getStorageLocationsForStockMovement` | ❌ none | **EXCLUDED — §0.B shared with mobile** |
| 0.B.14 | `GET /v3/stockUnit/detailView` | `getDetailView` (`:586`) | ❌ none | `WEB_UI_VIEW_STOCK_UNIT` — **view gating, §1.3 follow-on** |
| 0.B.15 | `GET /v3/stockUnit/stockunitDetailsById/{id}` | `stockunitDetailsById` (`:624`) | ❌ none | same |
| 0.B.16 | `GET /v3/stockUnit/isUnitLoadIdValid/{labelId}` | ⚠ named `getStorageLocationsForStockMovement` (`:615-616`) — see note 4 | ❌ none | same |

**Eight write endpoints that adjust stock quantities or place/release locks are reachable by any authenticated `wms_user` today**, and each maps to a constant that exists, is seeded to `super-admin`, and is enforced nowhere (§0.B).

Four notes the implementer needs:

1. **The single/bulk pairing is the evidence for §3.5's controller placement.** Every one of the four ⬛ actions has a single-item *and* a bulk endpoint converging on one service method. A controller gate needs the annotation on **both** members of each pair — 8 annotations for 4 constants — which is exactly the duplication §3.5 weighs against the service layer, and why the ArchUnit golden map must assert pairs rather than constants.
2. **The bulk members are where a service-layer guard would return HTTP 200.** `StockUnitController:224-254` wraps the loop in `catch (BusinessException) → errors.add(...)` then `return ResponseEntity.ok(errorMap)`. That pattern repeats across all four bulk endpoints, so it is not a one-off.
3. **`bulkTransferStock` (0.B.12) is *not* on the §0.B shared list, but its single-item sibling is.** Verify before gating: if the mobile UI only calls the single `transferStock`, then `bulkTransferStock` is web-only and can carry a plain gate while its sibling needs the cross-namespace ANY-of. That asymmetry is easy to miss and would 403 mobile Move Stock if applied to the wrong one.
4. **Naming trap:** `GET /isUnitLoadIdValid/{labelId}` (`:615`) is served by a method literally *named* `getStorageLocationsForStockMovement` (`:616`) — a copy-paste leftover returning `Boolean` from a unit-load label lookup. Harmless at runtime, but it makes two different endpoints grep to the same method name. Do not use method names as the key when building the route map.

### 0.B.2 `UnitLoadController` endpoint-by-endpoint — **0 of 9 guarded**

Enumerated 2026-08-17, per-method (a first pass with a 50-line window mis-attributed a delete constant to `/reprintLabel`; corrected below).

| # | Endpoint | Method | Constant in body | Service called | Fix E target |
|---|---|---|---|---|---|
| 0.B.17 ⬛ | `POST /v3/unitLoad/deleteContainer` | `deleteContainer` | `DELETE_UNIT_LOAD` — **as the `comment` arg** | `deleteUnitLoad` | `WEB_UI_ACTION_DELETE_UNIT_LOAD` |
| 0.B.18 ⬛ | `POST /v3/unitLoad/bulkDeleteContainer` | `bulkDeleteContainer` | `DELETE_UNIT_LOAD` — same | `deleteUnitLoad` (loop) | same |
| 0.B.19 ⬛ | 🔴 `GET /v3/unitLoad/deleteContainerRecursive/{id}` | `deleteContainerRecursive` | `DELETE_UNIT_LOAD_RECURSIVE` — same | `deleteUnitLoadRecursive` | `WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE` |
| 0.B.20 | `POST /v3/unitLoad/reprintLabel` | `reprintLabel` | — (clean) | `reprintLabel` | none — label reprint, not a listed constant |
| 0.B.21 | `GET /v3/unitLoad/detailView` | — | — | — | `WEB_UI_VIEW_CONTAINER` — view follow-on (§1.3) |
| 0.B.22 | `GET /v3/unitLoad/unitloadDetailsByLabelId/{labelId}` | — | — | `getUnitloadDetails` | same |
| 0.B.23 | `GET /v3/unitLoad/unitloadDetailsById/{id}` | — | — | `getUnitloadDetails` | same |
| 0.B.24 | `GET /v3/unitLoad/childrenUnitloads/{parentId}` | — | — | `getChildrenUnitloadDetails` | same |
| 0.B.25 | `GET /v3/unitLoad/search/findByItemForReplenish` | `findByItemForReplenish` | — | — | same |

Three things:

1. 🔴 **`deleteContainerRecursive` is a `GET` that recursively deletes a container and its children** (`:154`). Independent of authorization that is wrong: GETs are prefetchable, link-previewable, and land in access logs and browser history. It is also the only recursive-delete route. **Not this plan's job to change the verb** — but a gate on a GET is weaker than a gate on a POST, and it should be recorded. Own ticket.
2. **All three delete endpoints pass the constant as the `comment` argument**, which is [SBDEV-2979](https://app.clickup.com/t/868kt336b). §3.5's warning applies verbatim: **do not repurpose that argument as the gate.** The gate goes above the method; the argument gets a real comment.
3. `:156` logs `"start reprintLabel unitload={}"` inside `deleteContainerRecursive` — cosmetic copy-paste, but it is the lineage that produced the constant-as-comment defect, so it corroborates §0.C.

### 0.B.3 The `PRINT_TOTE_LABELS` surface — **the constant has no consumer at all**

`WEB_UI_ACTION_PRINT_TOTE_LABELS` appears in exactly two places: its declaration (`WmsConstants:417`) and the `super-admin` seed (`UtilRestController:413`). **No controller and no service references it.** Meanwhile tote/label printing is spread across **three controllers**:

| # | Endpoint | Controller |
|---|---|---|
| 0.B.26 ⬛ | `POST /v3/dashboard/printToteLabels` | `DashboardController:71` |
| 0.B.27 ⬛ | `POST /v3/report/reprintLabels` | `ReportController:306` |
| 0.B.28 ⬛ | `POST /v3/labelPrinting/totes/generate` | `LabelPrintingController:171` |
| 0.B.29 ⬛ | `POST /v3/labelPrinting/totes/reprint` | `LabelPrintingController:180` |
| 0.B.30 | `GET /v3/labelPrinting/totes` | `LabelPrintingController:86` — read |
| 0.B.31 | `GET /v3/labelPrinting/preview/tote` | `LabelPrintingController:143` — read |
| 0.B.32 | `GET /v3/labelPrinting/types` | `LabelPrintingController:212` — read |

⚠ **So "gate `PRINT_TOTE_LABELS`" is not one annotation — it is a scoping decision across 4 write endpoints in 3 controllers**, and it is materially larger than §3.5 implies. Two sub-questions the implementer cannot answer alone:

- Is `DashboardController:71` (the Pick&Pack monitor's print button) the same *capability* as `LabelPrintingController`'s generate/reprint pair, or are those a separate feature that deserves its own constant?
- `ReportController:306 /reprintLabels` is reached from the Parcel Picking report (`store/reports/parcelPicking.js`), whose own menu function is **undecided** (§10.9). Gating it on `PRINT_TOTE_LABELS` couples two open decisions.

**Recommendation: split `PRINT_TOTE_LABELS` out of Fix E into its own tranche.** The other seven action constants have a clean single/bulk shape on two controllers; this one does not, and bundling it would hold up the rest.

### 0.C ⚠ Found adjacent — the delete constants are being written into the audit trail

`UnitloadService.deleteUnitLoad(Unitload unitLoad, **String comment**, boolean notifyCRM, Principal principal)` — the second parameter is the operator's **comment**, not a function name. `UnitLoadController:100/:134/:163` pass a `FunctionEnum` constant into it, so every web-initiated container deletion records the literal string as its audit reason, and ships it to OMS via `sendStockChangeMessage`.

**Confirmed on WineCo dev: 478 `stockrecord` rows** with `additionalcontent = 'WEB_UI_ACTION_DELETE_UNIT_LOAD'`, `activitycode = 'MANUAL_REMOVAL'`, across 5 operators (`mcervone` 210, `adampetersen` 148, `adriantorres` 78, `bcampbell` 23, `nathanquintanilla` 19), 2025-02-04 → 2025-04-22.

This is **out of scope here** — it is a data-quality bug, not an authorization one — but it must be recorded because it is the trap that makes those two constants *look* enforced at the call site. See §10.3.

### 0.D Backend sites

| # | Site | Role in this plan |
|---|---|---|
| 0.7 | `service/AccessService.java:81-87` | `doesUserHaveAccess`; gains `doesUserHaveAnyAccess`/`checkAnyAccess` in 2968 |
| 0.8 | `security/FunctionGuardInterceptor` (2968) | ⚠ **This plan does NOT extend it for view functions** — see the §1.3 boxed warning. It is used only for the 7 controller-level action gates (§3.5). Its golden map stays at 2968's 11 controllers, none of which the web menu calls. |
| 0.9 | `controller/rest/UtilRestController.java:237-416` | persona seed — extended by §3.6 |
| 0.10 | `src/main/resources/db/migration/` | 2968 claims **V2.2.17**; this plan takes the next free (**re-sweep at PR time**) |
| 0.11 | `WmsConstants.FunctionEnum` | No new constants needed — see §3.6 |

---

## 1. Problem Statement

### 1.1 Symptom

Every authenticated user renders the full **super-admin** navigation — all 30 items, the Admin screen included — regardless of which `UserRole`/`UserGroup` they hold. There is no menu filter, no route guard, and no per-tab gate. The web UI fetches the user's function list on login and throws it away.

The sharp edge is **Admin → User Management**: the screen that edits `UserRole`/`UserGroup`/`UserFunction` rows renders for any `wms_user`.

### 1.2 DB verification — WineCo dev (`db_verified: true`)

Queried live 2026-08-16 on `wms2-wineco-dev`, the primary test client. **52 live users** (excluding `Z-`-prefixed archived rows):

| Bucket | Live users | `WEB_UI_VIEW_*` held |
|---|---|---|
| Full access (`super-admin`) | **39** | 57 |
| Partial web access | **7** | 14 – 24 |
| **No web access at all** | **6** | 0 |

Per-role web/mobile split:

| Role | `WEB_UI_VIEW` | `WEB_UI_ACTION` | `MOBILE_UI` |
|---|---|---|---|
| `super-admin` | 57 | 8 | 11 |
| **`CS-REP`** (tenant-authored) | **26** | 0 | 1 |
| `outbound-manager` | 14 | 0 | 8 |
| `receiving` | 8 | 0 | 6 |
| `inventory-manager` | 5 | 0 | 5 |
| `inventory-worker` / `outbound-worker` / `outbound-forklift` | **0** | 0 | 3–7 |
| `cy-test-role-*` ×2, `test role` | 0 | 0 | 0 |

**Three findings that drive the whole design:**

1. **WineCo already built a differentiated web role and the UI ignores it.** `CS-REP` (4 users) holds 26 `WEB_UI_VIEW_*` — orders, BOL, picking, monitors, receiving reads, records — and deliberately **no** master data, **no** admin, **no** actions. It is a well-formed customer-service role that has never had any effect.
2. **6 live users have zero web functions and no `WEB_UI_LOG_IN`** — mobile-only operators. Today they can open the web UI and reach Admin. `WEB_UI_LOG_IN` **already exists and already separates them correctly**; nothing reads it. That is the cheapest, largest slice of exposure to close.
3. 🔴 **14 of the 29 mapped menu items have a function that NO non-`super-admin` role holds** — all 9 Master Data items, Cycle Count, Transfer, Transfer Picking, Inventory Report, and Admin. **13 of those need grants**; Admin is the exception and correctly stays `super-admin`-only. **This is the defining difference from SBDEV-2968.** Mobile's grants were real because the tile filter was live; the web UI's grants were never populated because nothing ever read them. Filtering on the current data would leave Master Data visible only to the 39 super-admins.

> **Counting note, stated precisely because three different figures are easy to derive here.** The menu has **30 leaf destinations**. **29** have an unambiguous existing constant and were measured in the query above. The 30th — **Reports → Outbound Parcel Report** — has no obvious constant and is an open decision (§10.9). Of the 29, **14** are orphaned, **13** of which take grants under §3.6.

### 1.3 Scope

**In scope:** the 30 menu items, the 6 admin tabs, a route guard, the `WEB_UI_LOG_IN` entry gate, the 8 `WEB_UI_ACTION_*` gates (UI + server), and the grant seed that makes all of it usable.

> 🔴 **Read this before assuming the web view surface is protected. Web VIEW functions are enforced CLIENT-SIDE ONLY in this ticket.**
>
> This plan gates *actions* server-side (§3.5) but **annotates no web controller for view functions**. An earlier draft implied otherwise — §0.8 called the interceptor "the enforcement point this plan extends" and the §4 diagram showed it doing web view gates. Neither was true: 2968's golden map is 11 controllers, **all mobile plus `OrderCancellationController`, and none of the ~21 controllers the web menu calls**.
>
> So after both plans ship, a user denied the SKU Data menu item still gets data from `curl /v3/itemdata`. **That is the same defect class SBDEV-2968 exists to close, on the web side.**
>
> **And extending the golden map would only fix half of it.** Roughly 14 of the ~32 API roots behind the web menu are served *purely* by Spring Data REST repository exports with no controller to annotate — `/v3/locationType` (`LocationTypeRepository:11`), `/v3/unitloadType` (`UnitloadTypeRepository:11`), `/v3/itemunit` (`ItemunitRepository:10`), plus `/v3/itemdata`, `/v3/boxtype`, `/v3/stockunit`, `/v3/locationArea`, `/v3/locationRack`, `/v3/cyclecount`, `/v3/replenishorder`, `/v3/goodsreceiptposition` and others. `RepositoryRestHandlerMapping` does not honour `WebMvcConfigurer.addInterceptors` (2968 §3.1-A9), so the interceptor **structurally cannot reach them** — and they are concentrated on Master Data, exactly the menu group with the largest grant problem.
>
> **Server-side web view gating therefore needs a third mechanism** (`@PreAuthorize` on repository query methods, `SecurityConfiguration` path matchers, or an interceptor registered via `RepositoryRestConfigurer`). That is a real design decision and a substantial scope addition — **explicitly a named follow-on, not silently in or out.** It is why Fix A cannot be shrunk: for about half the menu, the client-side filter is currently the only control that can exist.

**Out of scope:** the 5 shared endpoints (SBDEV-2968 §0.B), the `AdminController` alias surface (§0.C of 2968 / SBDEV-2870), the audit-comment defect (§0.C above), and the 8 `WEB_UI_VIEW_*` constants with no page (§10.2).

---

## 2. Root Cause Analysis

**RC-1 — the filter was written and never wired.** `util/appMenuList.js` contains five complete persona menus. Someone built the data model for a filtered menu; `links()` was never given the argument. The four unused keys are the fossil.

**RC-2 — the roles are fetched and discarded.** `store/index.js:92-101` performs the network call, logs the length, and returns a value `pages/index.vue:114` awaits and ignores. The action commits no mutation, so no component can observe it. Everything needed for the decision is retrieved and thrown away.

**RC-3 — the grant data was never populated, because nothing read it.** Unlike mobile, where the client-side filter forced grants to be real, the web functions are write-only metadata. Hence the 13 orphaned menu items in §1.2. **Enforcement and data must land together or the feature is a regression.**

**RC-4 — nothing in the harness can see the absence.** No web test asserts menu composition; the API-side `@PreAuthorize` lane is invisible to `standaloneSetup` (SBDEV-2863). A UI with no gate and a UI with a correct gate are indistinguishable to CI today.

---

## 3. Fix Design

### 3.1 Fix A — the menu filter (`wms2-web-ui`)

**A1. `util/appMenuList.js`** — attach a `fn` to every leaf, and **delete the four dead persona menus**. One list, each entry declaring the function that reveals it. The `super-admin` key disappears as a key; it becomes just "the full list".

**A2. `store/index.js`** — `getUserRoles` gains a mutation. Add `functions: []`, `functionsLoaded`, `functionsError`; add `ensureFunctionsLoaded()` memoising a single in-flight promise (same shape as 2968's `ensureRolesLoaded`).

**A3. `layouts/default.vue:284-285`** — `links()` filters the single list against `state.functions`. A group (`subLinks`/`linkGroup`) renders only if **at least one child survives** — otherwise an operator sees an empty "Master Data" accordion.

### 3.2 Fix B — route guard (`middleware/require-function.js`, new)

No `middleware/` directory exists. Mirror 2968's B3: unmapped paths pass; mapped paths `await ensureFunctionsLoaded()`, then allow / redirect to `/not-authorized?page=…&fn=…` / redirect to `/unhealthy-tenant?reason=functions` on fetch failure. Register in `nuxt.config.js`.

Deep-linkable pages **not** in the menu (`_id.vue` detail routes, `openNotice/receive`, `parcel-details`) inherit their parent list page's function — enumerated in the route map, not left to fall through.

### 3.3 Fix C — the `WEB_UI_LOG_IN` entry gate

A user without `WEB_UI_LOG_IN` is redirected to `/not-authorized` with a message naming the web UI specifically. **No new constant, no data migration** — the function exists and is already correctly held (`CS-REP`, `inventory-manager`, `outbound-manager`, `receiving`, `super-admin`) and correctly absent from the three mobile-only personas. This single check covers the 6 live WineCo users in §1.2.

### 3.4 Fix D — the 6 Admin tabs (`pages/admin.vue:51-58`)

| Tab | Function |
|---|---|
| System Management | `WEB_UI_VIEW_IMPORT_DATA` |
| Parameters & Configuration | `WEB_UI_VIEW_SYSTEM_PROPERTY` |
| Shippers | `WEB_UI_VIEW_CLIENT` |
| User Management | `WEB_UI_VIEW_USER_MANAGEMENT` |
| Printer Setup | `WEB_UI_VIEW_PRINTER` |
| Service Log | `WEB_UI_VIEW_MESSAGES` |

The Admin **menu entry** renders if the user holds *any* of the six; each tab renders individually. Shippers had no obvious constant — `WEB_UI_VIEW_CLIENT` is chosen because `store/admin/shippers.js` calls `/client` exclusively.

### 3.5 Fix E — the 8 `WEB_UI_ACTION_*` gates, UI **and** server

> **Concrete surface: §0.B.1 – §0.B.3.** The 8 constants resolve to **15 write endpoints across 5 controllers**, not 8: `StockUnitController` 8 (§0.B.1, four single/bulk pairs), `UnitLoadController` 3 (§0.B.2), and the tote surface 4 across `DashboardController` / `ReportController` / `LabelPrintingController` (§0.B.3). **§0.B.3 recommends splitting `PRINT_TOTE_LABELS` into its own tranche** — it has no existing consumer and no clean single/bulk shape, and bundling it would hold up the other seven.

**E1 · UI** — hide or disable the control (disable-with-tooltip preferred for discoverability) in the components identified in §0.B.

**E2 · Server — at the SERVICE layer, not the interceptor.** The reasoning, stated precisely (an earlier draft over-generalised this and the verified breakdown is narrower):

> A **view** function is per-UI, so the controller is the right boundary — that is what 2968's `FunctionGuardInterceptor` does. Most **actions** are *capabilities reachable from both UIs*, so a controller gate would have to be duplicated per entry point and would still miss the other UI.

**Verified reachability, 2026-08-16 — corrected twice, so the evidence is stated in full.**

The mobile UI makes exactly **five** calls into shared controllers, and **none of them is an action endpoint**:

```
store/moveStock.js:157  → /stockUnit/storageLocationsForStockMovement   (read)
store/moveStock.js:169  → /stockUnit/transferStock                      (move, not an ACTION constant)
store/picking.js:244    → /dashboard/orderMonitorViewSummary            (read)
pages/replenish.vue:133 → /dashboard/replenishMonitorViewSummary        (read)
pages/replenish.vue:153 → /dashboard/replenishMonitorViewSummary        (read)
```

A repo-wide grep of `wms2-mobile-ui` for `adjustAmount|adjustReserved|setLock|removeLock|deleteUnitLoad|printToteLabels` returns **nothing**.

| Action | Cross-UI? | Entry points |
|---|---|---|
| `ADJUST_LOCK_DAMAGED` | ✅ **the only one** | `StockunitService:232` + `MobileMoveStockService:252,257` + `MobileMoveUnitloadService:277,282` — mobile reaches it *service-internally* when a move involves damaged stock, never as an endpoint |
| `ADJUST_AMOUNT` | ❌ web-only | `StockUnitController:179` single + ~`:222` bulk |
| `ADJUST_RESERVED_AMOUNT` | ❌ web-only | `:259` single + ~`:300` bulk |
| `ADJUST_LOCK_ON_HOLD` | ❌ web-only | `:334` / `:362` |
| `ADJUST_LOCK_RELEASE_LOCK` | ❌ web-only | `:474` / `:499` |
| `PRINT_TOTE_LABELS` | ❌ web-only | `DashboardController:71` |
| `DELETE_UNIT_LOAD` | ❌ web-only | `UnitLoadController:100`, `:134` |
| `DELETE_UNIT_LOAD_RECURSIVE` | ❌ web-only | `:163` |

> **Correction, recorded rather than quietly fixed.** Two earlier drafts of this section claimed these actions were cross-UI — first all 8, then 6 of 8. **Both were wrong.** The second came from observing that five mobile services mutate `entityLock`/amount, which is true but irrelevant: mutating a lock *during picking or cycle count* is not the same as invoking the *adjust-lock action*. Only `ADJUST_LOCK_DAMAGED` is genuinely shared.

### 🔴 REVERSED at architect review — the gates go on the CONTROLLER, not the service

An earlier draft put all 8 at the service layer, arguing that single + bulk endpoints converge on one service method so one check cannot drift. **The convergence claim is true** (verified: `adjustAmount` `StockUnitController:200`/`:241`, `adjustReservedAmount` `:278`/`:317`, `setLockOnHold` `:346`/`:378`, `removeLock` `:485`/`:514`, `setLockDamaged` `:416`/`:457`, `UnitLoadController:100`/`:134`) — **but it does not make the service the better site.** Three facts, all verified, defeat it:

**1. A service-layer denial does not produce 403. On the bulk paths it produces HTTP 200.** `StockUnitController:224-254` wraps the whole loop in `try { … } catch (BusinessException e) { errors.add(getErrorMessage(...)) }` and then returns **`ResponseEntity.ok(errorMap)`**. The existing guard shape throws `BusinessException` (`StockunitService:232`), so a service-layer gate on any bulk action returns **200 with an errors array** — indistinguishable to the client from a partial success. *A guard that returns 200 is not a guard.*

**2. The denial message is a key, not a sentence.** `getErrorMessage("Runtime Error", e.getMessage())` — with `BusinessException`'s 1-arg constructor the key is `"placeholder"` and `getMessage()` is bundle-dependent. Opaque denial is the exact failure mode §5.1-P6 exists to prevent.

**3. N authorization reads per bulk request.** `AccessService.doesUserHaveAccess` runs an uncached 5-table `getAllRoles` per call. Inside the converged service method that is **once per id**; at the controller it is once per request. §7 row 2's "one short read" was wrong for bulk.

The anti-drift concern is already solved elsewhere: 2968's ArchUnit golden map plus the `SmartInitializingSingleton` startup assertion make a *missing* annotation fail bean initialisation. And method-level annotation **avoids coupling C-1 entirely** — mobile touches only `transferStock` and `storageLocationsForStockMovement` on `StockUnitController`, and those stay unannotated, so no cross-namespace ANY-of is needed.

**Decision:** method-level `@RequiresFunction` on the controller endpoints for the **7 web-only actions** (both the single and the bulk method of each pair), and **`ADJUST_LOCK_DAMAGED` stays at the service layer** because it is genuinely cross-UI and already there. Correct 403s and one read per request beat uniformity.

### 🔴 And the existing `ADJUST_LOCK_DAMAGED` guard is narrower than this plan claimed

`StockunitService:232` is inside **`transferStock` (`:150`)**, in a conditional branch (destination `DAMAGED` **and** lock `QUALITY_FAULT`). **`setLockDamaged` (`:360`) has no guard at all** — verified: no `doesUserHaveAccess` anywhere in that method — and it is reached by `POST /transferToDamaged` (`StockUnitController:416`) and `/bulkTransferToDamaged` (`:457`).

So the dedicated endpoints for the *one action everyone believes is enforced* are **open today**. Two consequences:

- **§6.2 must not pin `setLockDamaged` as an "existing guard, regression pin only."** Following that instruction would pin a guard that does not exist and ship `/transferToDamaged` open.
- The repeated figure "1 of 80 functions is enforced" needs this footnote: it is one function checked in **one conditional branch of one unrelated method**, while that same action's own endpoints are ungated. The true enforcement surface is thinner than the count suggests.

Implementation: `accessService.doesUserHaveAnyAccess(...)` at the entry of the service method backing each action, following the existing `ADJUST_LOCK_DAMAGED` pattern. **Not** `@RequiresFunction`, and **not** the interceptor.

⚠ **Do not reuse the existing `UnitLoadController` call sites as the hook.** Those constants are currently the `comment` argument (§0.C). Adding enforcement there without fixing the argument would either break the audit comment or silently pass the wrong string. Add the check inside `UnitloadService`, and leave §0.C to its own ticket.

### 3.5.1 The damaged-lock pair — received from SBDEV-2870 with a **proven** implementation

Rows 0.B.1/0.B.2 arrived here on 2026-08-17. They were written, tested and ablation-proven on `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin`, then reverted from that branch and re-homed here on a consistency argument:

> "Transfer To Damaged" is **one of six sibling row actions** on the Stock Units page — Lock, Unlock, Adjust Amount, Adjust Reserved, Transfer Stock, Transfer To Damaged. All six dispatch from the same table (`store/handlingUnits/stockUnits.js`), each has a single and a bulk variant, and all twelve endpoints sit on `StockUnitController`. Gating **one** would have removed Transfer To Damaged from ~13 live WineCo users while leaving the other five open to every `wms_user` — an unexplainable state. One tranche, one grant decision.

**Unlike the rest of Fix E, this part is not a proposal. Reuse it verbatim:**

```java
private ResponseEntity<Object> denyUnlessDamagedLockAllowed() {
    if (accessService.doesUserHaveAccess(WmsConstants.FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)) {
        return null;                        // ⚠ null-as-success — see the caveat below
    }
    // WARN log with username + function; 403 + ProblemDetail + X-Authz-Denied header
}
```

Five properties that were established empirically and should not be re-litigated:

1. **Controller-level, not service-level.** Both callers wrap the service call in `catch (BusinessException) → errors.add(...)` then `return ResponseEntity.ok(errorMap)`, so a service-layer guard is reported as **HTTP 200 with an errors array**. Verified. This is the general argument for §3.5's placement and this pair is its proof case.
2. **Before the bulk loop.** One authorization read per request, not per id. Ablation-proven: moving the check inside the loop fails `bulkTransferToDamaged_shouldCheckAuthorizationOncePerRequest`.
3. **Deny tests must stub the happy path.** Otherwise removing the gate fails on an incidental `EntityNotFoundException` rather than on the status — the ablation signal is then accidental. Fixed version yields a clean `expected:<403> but was:<200>`.
4. **`X-Authz-Denied` requires CORS exposure or it is invisible.** `SecurityConfiguration.corsConfigurationSource` must list it (follow the SBDEV-2632 precedent and its de-duplication guard). Without it, §5.1-P8's `retryCondition` fix cannot see the header. **This came here with Fix C precisely because nothing in 2870 could emit it** — the five `@PreAuthorize` gates produce Spring's default 403 and there is no `AccessDeniedHandler` in the codebase.

    ⚠️ **Ownership reassigned 2026-08-17 — this plan CONSUMES the header, it no longer creates it.** Landing it here was wrong on ordering: **SBDEV-2968 lands first** (§12) and needs the same header for its own `retryCondition` fix, so it would have had to wait on a plan scheduled after it. `Authority.AUTHZ_DENIED_HEADER`, the CORS entry and the `SecurityConfigurationTest` extension are now **SBDEV-2968 §3.1-A2b**. Fix E must **reference the existing constant** and find the CORS entry already present — verify that with a grep before writing either, and if 2968 has been descoped or reordered, take both items back here rather than assuming they exist. See 2968 §14-Δ1 and its R13.
5. **`SecurityConfigurationTest` asserts the exposed-header list *exactly*** and will fail when the header is added. Extend the expectation; do not loosen the assertion.

    ⚠️ **Made precise 2026-08-17 — as written this sends you to the wrong test.** `unit/config/SecurityConfigurationTest` has *two* SBDEV-2632 cases and only one is exact: `…_exposesSkippedCycleCountHeader_whenPropertyAbsent` (`:64`) uses `.contains(…)` and stays green; `…_doesNotDuplicateHeader_whenPropertyAlreadySuppliesIt` (`:83`) uses `.containsExactly("X-Export-Skipped-Cycle-Counts")` and **is the one that goes red**. Since the CORS entry itself now lands in SBDEV-2968 §3.1-A2b, **2968 makes this edit** — Fix E should find the list already carrying both headers. Verify, don't re-do.

Two caveats carried over unresolved, both flagged by review and deliberately not self-applied:

- **Null-as-success** — a third call site could discard the return and silently bypass the gate. Preferred shape: `requireDamagedLockAccess()` throwing a dedicated exception mapped in `RestExceptionHandler`, which would also converge the mobile paths (`MobileMoveStockService:252,257`, `MobileMoveUnitloadService:277,282`) onto one denial contract instead of today's two.
- **A class-wide `lenient()` permissive stub** was needed in `StockUnitControllerUnitTest.setUp` so six pre-existing tests kept exercising the handler. It is permanent and class-wide, so **any** future gate on this controller's 16 endpoints becomes silently permissive in every existing test. With Fix E gating 10 of them, prefer per-nested-class stubs so unstubbed means *deny* — failing closed like production.

### 3.6 Fix F — the grant seed (the part that makes this usable)

**29 of the 30** menu items map to an existing `FunctionEnum` constant; the 30th needs a decision (§10.9). For those 29 no new constants are required — what is missing is **grants**.

**Best-fit assignment for the 13 orphaned items.** ⚠ **This asserts who owns master data, which is a business decision — it needs Brent's sign-off per tenant before the migration is written** (§10.1):

| Function(s) | Proposed persona | Rationale |
|---|---|---|
| `STORAGE_LOCATION`, `STORAGE_LOCATION_TYPE`, `FIXED_ASSIGNMENT`, `AREA`, `SECTION`, `UNIT_LOAD_TYPE` | `inventory-manager` | warehouse structure is inventory ops |
| `ITEM_DATA`, `ITEM_UNIT`, `CASE_TYPE` | `inventory-manager` | SKU master |
| `CYCLECOUNT`, `CYCLECOUNT_POSITION` | `inventory-manager` | already owns the mobile cycle-count tile |
| `TRANSFER_ORDER` | `outbound-manager` | owns Transfer + Transfer Picking |
| `INVENTORY_RECORD` | `inventory-manager` | inventory reporting |
| `USER_MANAGEMENT` | **unchanged — `super-admin` only** | correct as-is |

#### 🔴 F3 — ACTION grants, without which Fix E is a silent capability removal

**No non-`super-admin` role holds a single `WEB_UI_ACTION_*` function** (§1.2 — every role shows 0). The VIEW grants above do not change that. So the moment Fix E's server-side gates land, **every `inventory-manager`, `outbound-manager`, `receiving` and `CS-REP` user loses stock adjustment, lock on-hold/release, container delete and tote reprint** — capabilities they exercise today, removed with no menu change to signal it.

That is a **larger and less visible blast radius than the menu work**, because a hidden menu item is obvious and a 403 on a button the user can still see is not.

Proposed ACTION grants — ⚠ **same P2 sign-off as the VIEW table; arguably more sensitive, since these are the destructive operations**:

| Action | Proposed personas | Rationale |
|---|---|---|
| `ADJUST_AMOUNT`, `ADJUST_RESERVED_AMOUNT` | `inventory-manager` | stock correction is inventory ops |
| `ADJUST_LOCK_ON_HOLD`, `ADJUST_LOCK_RELEASE_LOCK`, `ADJUST_LOCK_DAMAGED` | `inventory-manager` | lock management is inventory ops |
| `DELETE_UNIT_LOAD`, `DELETE_UNIT_LOAD_RECURSIVE` | **`super-admin` only** | irreversible and it writes stock history — recommend NOT delegating |
| `PRINT_TOTE_LABELS` | `outbound-manager` | tote reprint is an outbound floor need |

**If Brent declines to delegate any of these, that is a valid answer** — but it must be a decision, because the default (grant nothing) silently removes them from everyone but the 39 super-admins. Whichever way it goes, §5.1-P3's regression predictor must cover **actions as well as menu items**, and R1 must name the action blast radius rather than scoping to menus.

**F1** — extend `UtilRestController.initDB` (fresh tenants).
**F2** — Flyway migration for provisioned tenants: `INSERT … WHERE NOT EXISTS` per (role, function), keyed by role **name**, skipping silently where a role is absent. `mywms_role_mywms_function` has no unique constraint, so **`NOT EXISTS`, never `ON CONFLICT`**. Version = next free after 2968's V2.2.17; **re-sweep all remote branches at PR time**.
**F3** — `CS-REP` and other tenant-authored roles are **not** modified. They are the tenant's own configuration.

### 3.7 Fix G — audit

Reuse SBDEV-2968's `db/audit-access-invariants.sql` + `GET /v3/adminAction/accessAudit`. **Do not build a second one.** Add one web-specific result set: *per user, which of the 30 menu items they will see after the change vs. all 30 today* — the regression predictor for §5.1-P2.

---

## 4. Architecture Overview

```
 wms2-web-ui                                      wms2-api
┌───────────────────────────────┐            ┌──────────────────────────────┐
│ pages/index.vue               │            │ /v3/user/getAllRoles/{u}     │
│   └ ensureFunctionsLoaded ────┼───────────▶│   → List<String> functions   │
│        │                      │            └──────────────────────────────┘
│        ├─ no WEB_UI_LOG_IN ──▶ /not-authorized            ← Fix C
│        │                      │
│ middleware/require-function ──┼─ mapped route, fn missing ▶ /not-authorized   ← Fix B
│        │                      │
│ layouts/default.vue           │
│   links() = MENU.filter(fn ∈ functions)                   ← Fix A
│        │                      │            ┌──────────────────────────────┐
│ pages/admin.vue               │            │ FunctionGuardInterceptor      │
│   tabs.filter(fn ∈ functions) │   ← Fix D  │   (from SBDEV-2968)           │
│        │                      │            │   view gates, per controller  │
│ action controls               │            ├──────────────────────────────┤
│   disabled unless fn held ────┼── Fix E1   │ AccessService.doesUserHaveAny │
└───────────────────────────────┘            │   ACTION gates, service layer │← Fix E2
                                             │   (both UIs converge here)    │
                                             └──────────────────────────────┘
```

**Two layers, two mechanisms, deliberately:** view functions gate at the controller (per-UI); action functions gate at the service (cross-UI). §3.5 explains why.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

D-rollout is **hard-on at deploy, no feature flag** (user decision, consistent with SBDEV-2968). These replace the kill switch.

| # | Prerequisite | Blocking? |
|---|---|---|
| **P1** | **SBDEV-2968 merged.** This plan consumes its interceptor, its `AccessService` methods, and its audit surface. | **YES** |
| **P2** | Brent signs off the §3.6 best-fit grant tables (VIEW **and** ACTION). The VIEW table asserts who owns master data; the ACTION table now covers **all six Stock Units row actions in one decision** — including the damaged-lock pair received from SBDEV-2870 (§3.5.1). Gating a subset is what that relocation exists to avoid. | **YES** |
| **P3** | Run the audit on every tenant + the web regression predictor (§3.7). Any live, Keycloak-mapped user who would lose **a menu item OR a destructive action** they currently use must have a named remediation **before** the image lands. **The action half is the easy one to forget** — see R1b. | **YES** |
| **P4** | Flyway grant migration applied to every tenant **before or with** the UI change. Grants first, filter second — the reverse hides working screens. | **YES** |
| **P5** | Re-sweep `V2.2.*` across all remote branches at PR time (2968 holds V2.2.17). | **YES** |
| **P6** | **Three-step deploy order, not two.** ① grant migration → ② `wms2-web-ui` (menu filter + disabled action controls) → ③ `wms2-api` action gates. Grants must precede the filter or working screens vanish; the UI must precede the server-side action gates or a user sees an enabled button that 403s — the opaque-failure mode SBDEV-2968-P7 exists to prevent. **If ② and ③ ride the same api image, say so and accept the window explicitly.** *(No conflict with 2968-P7's "mobile-ui first": different repos, and P1 forces 2968 to land whole beforehand.)* | **YES** |
| **P7** | Confirm the route map covers every deep-linkable page, including `_id.vue` detail routes. | **YES** |
| **P8** | 🔴 **Fix `retryCondition` in `wms2-web-ui/plugins/axios.js` (`:33-34`, `:86`).** It treats 403 exactly like 401 — retries three times with `$kc.updateToken(5)`, then `$kc.logout()` on an authenticated session. So every action-gate 403 from Fix E **logs the operator out** rather than telling them they lack permission, at 4x the request cost. Skip retry when the response carries **`X-Authz-Denied`**. Shared prerequisite with **SBDEV-2968-P10** — each plan fixes its own repo's `plugins/axios.js`. ⚠️ **Corrected 2026-08-17:** the header is **not** "already emitted by SBDEV-2870's damaged-lock gate" — that gate was reverted from 2870 and arrives *here* as Fix E. The server-side contract (constant + CORS exposure) is built by **SBDEV-2968 §3.1-A2b**, which lands first; Fix E reuses it. See §3.5.1 property 4. **Verify P8 the same way 2968 verifies P10 — a browser test, never a `curl`:** `curl` applies no CORS policy and the DevTools Network panel renders unexposed headers anyway, so both read `X-Authz-Denied` even when JS cannot. Assert the behaviour (denial renders, operator not logged out) plus `headers.get('x-authz-denied')` from the page. Full reasoning in 2968 §14.4. | **YES** |
| **P9** | ~~File the §0.C audit-comment defect as its own ticket.~~ ✅ **Filed 2026-08-17 — [SBDEV-2979](https://app.clickup.com/t/868kt336b).** | Done |

### 5.2 Implementation checklist

1. `util/appMenuList.js` — single list, `fn` per leaf, delete 4 dead menus.
2. `store/index.js` — `functions` state + `ensureFunctionsLoaded()`.
3. `layouts/default.vue` — filter `links()`; hide empty groups.
4. `middleware/require-function.js` + `nuxt.config.js`.
5. `pages/index.vue` — `WEB_UI_LOG_IN` entry gate.
6. `pages/admin.vue` — per-tab filter.
7. Action controls — disable unless held (§0.B component list).
8. `wms2-api` — service-layer action gates following `StockunitService:232`.
9. `UtilRestController` seed + Flyway grant migration.
10. Extend 2968's audit SQL with the web regression predictor.

---

## 6. Test Plan

Rules inherited from 2968: no `@SpringBootTest` (SBDEV-2217); no reliance on `standaloneSetup` evaluating `@PreAuthorize`; assert `BusinessException.getKey()`, never `getMessage()`.

### 6.1 `wms2-web-ui` (Jest)

> ⚠ `wms2-web-ui/CLAUDE.md` is silent on tests but the suite exists. **Baseline: `develop` has 2 always-red *suites* and 0 failing tests** — compare the **tests** count, never the suites count.

`test/util/appMenuList.spec.js` — `everyLeafDeclaresAFunction` · `everyDeclaredFunctionIsAKnownWebConstant` · `theFourDeadPersonaMenusAreGone` · `menuCoversEveryMenuReachablePage`
`test/layouts/default.spec.js` — `rendersOnlyItemsWhoseFunctionIsHeld` · `hidesAGroupWhenNoChildSurvives` · `superAdminStillSeesAllThirty` · **`csRepSeesTheTwelveItemsItsFunctionsAllow`** (uses the real WineCo CS-REP function set as a fixture — the regression this plan exists to enable)
`test/middleware/requireFunction.spec.js` — `waitsForEnsureFunctionsLoadedBeforeDeciding` · `redirectsToNotAuthorizedWithPageAndFn` · `allowsUnmappedRoutes` · `detailRoutesInheritTheirListPageFunction` · `routesToUnhealthyTenantOnFetchFailure`
`test/pages/index.spec.js` — `bouncesUserWithoutWebUiLogIn` · `admitsUserWithWebUiLogIn`
`test/pages/admin.spec.js` — `rendersOnlyTabsWhoseFunctionIsHeld` · `hidesTheAdminMenuEntryWhenNoTabSurvives` · `userManagementTabHiddenWithoutItsFunction`
`test/plugins/axios.spec.js` — `doesNotRetryWhenXAuthzDeniedHeaderPresent` · `stillRetriesAPlain401WithoutTheHeader` · `doesNotLogOutOnAnAuthorizationDenial` (P8 — all three fail today, since the interceptor cannot tell the two 403s apart).
`test/store/index.spec.js` — `getUserRolesCommitsTheFunctions` (**fails today — it commits nothing**) · `ensureFunctionsLoadedIsIdempotentUnderConcurrentCalls`

### 6.2 `wms2-api` (JUnit)

**Action guards span three services, not one** — so this is three test classes, and the plan must name the exact method each guard goes on:

| Service method | Constant | Test class |
|---|---|---|
| `StockunitService.adjustAmount` | `ADJUST_AMOUNT` | `StockunitServiceActionGuardUnitTest` |
| `StockunitService.adjustReservedAmount` | `ADJUST_RESERVED_AMOUNT` | ” |
| `StockunitService.setLockOnHold` | `ADJUST_LOCK_ON_HOLD` | ” |
| `StockunitService.removeLock` | `ADJUST_LOCK_RELEASE_LOCK` | ” |
| `StockunitService.setLockDamaged` (`:360`) | `ADJUST_LOCK_DAMAGED` | ” — 🔴 **UNGUARDED TODAY, must be implemented.** The existing check is at `:232` inside `transferStock` (`:150`), in a conditional branch — *not* on this method. `/transferToDamaged` (`StockUnitController:416`) and `/bulkTransferToDamaged` (`:457`) are open. An earlier draft called this a regression pin; following that would have shipped both endpoints ungated. |
| `UnitloadService.deleteUnitLoad` | `DELETE_UNIT_LOAD` | `UnitloadServiceActionGuardUnitTest` |
| `UnitloadService.deleteUnitLoadRecursive` | `DELETE_UNIT_LOAD_RECURSIVE` | ” |
| the tote path — `orderMonitorDtoService.printToteLabels` (`DashboardController:95`) and `LabelPrintingController:181` | `PRINT_TOTE_LABELS` | `ToteLabelActionGuardUnitTest` — ⚠ **two entry points; confirm they converge on one method before choosing the site** |

One pair per constant: denied without, allowed with. Follow the existing `ADJUST_LOCK_DAMAGED` shape.
`unit/controller/rest/UtilRestControllerSeedUnitTest` — `seedsMasterDataFunctionsToInventoryManager` · `seedsTransferOrderToOutboundManager` · `leavesUserManagementOnSuperAdminOnly`.

### 6.3 Manual test plan

| # | Persona | Action | Expected |
|---|---|---|---|
| M1 | `CS-REP` (real WineCo role) | log into web | 12 menu items, **no Master Data, no Admin** |
| M2 | mobile-only (`marthamina`-shaped: 0 web fns) | log into web | bounced to `/not-authorized`, message names the web UI (Fix C) |
| M3 | same | deep-link `/admin` | bounced, not rendered |
| M4 | `inventory-manager` after the grant migration | log into web | Master Data + Cycle Count + Inventory Report now visible |
| M5 | `outbound-manager` after migration | Transfer + Transfer Picking | visible |
| M6 | `super-admin` | log into web | all 30 items, all 6 admin tabs — unchanged |
| M7 | non-`super-admin` with `WEB_UI_VIEW_STOCK_UNIT` but no `ACTION_ADJUST_AMOUNT` | Handling Units → adjust | control disabled; direct API call **403** |
| M8 | any admin | Admin → 3 tabs held, 3 not | only the 3 render; the Admin entry still appears |
| M9 | any user | hard-refresh a deep page | loads; no spurious bounce (cold-start race) |
| M10 | mobile operator | mobile UI end-to-end | **unaffected** — SBDEV-2968's gates unchanged |

### 6.4 Deliberately-skipped coverage

Full-chain (Keycloak → tenant DB → menu) is unautomatable while SBDEV-2217 is open. §6.3 is the evidence base.

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | UI-side state only; no server cache added |
| 2 | Connection pool | **No** | One uncached `getAllRoles` per request. ⚠ An earlier draft said "one short read on the deny path" while placing gates in the service — that would have been **once per id on bulk paths**, not once per request. Controller placement (§3.5) is what makes this row true. |
| 3 | Scheduled jobs | **N/A** | None |
| 4 | Long transactions | **No** | Guards sit at method entry, before business work |
| 5 | Request affinity | **No** | Stateless |
| 6 | Retry / idempotency | **No** | A denied action never executes |
| 7 | Tenant context | **Yes — load-bearing** | `getAllRoles` reads the tenant DB; guards run inside request scope, after `TenantFilter` |
| 8 | Distributed locks | **N/A** | None |
| 9 | Cache invalidation | **N/A** | No cache (2968 dropped its A6) |
| 10 | External notifications | **N/A** | None |

### v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | ✓ OK — guards return `List<String>`, no lazy proxy escapes |
| 2 | `tenantTransactionManager` | ✓ N/A — no new `@Transactional`; a bare one would bind to the **landlord** TM |
| 3 | `readOnly = true` | ✓ N/A |
| 4 | Caffeine invalidation | ✓ N/A |
| 5 | Jakarta namespace | ✓ N/A — no new servlet code |
| 6 | H2-compatible test SQL | ✓ N/A — Mockito only |
| 7 | `BaseControllerTest` | ✓ N/A — service-layer tests |
| 8 | Micrometer | ✓ Reuses 2968's `wms2.authz.*` |

---

## 8. Risks & Mitigations

| # | Risk | Sev | Mitigation | Residual |
|---|---|---|---|---|
| **R1** | **The 13 orphaned menu items lock working screens.** Master Data etc. vanish for everyone but the 39 super-admins. | **High** | §3.6 grant seed + §5.1-P4 (grants before filter) + P3 regression predictor + M4/M5 | Accepted per hard-on. A missed grant is fixed by an administrator through User Management with no deploy. |
| **R1b** | 🔴 **Fix E silently removes all 8 destructive actions from every non-`super-admin` user**, because no such role holds any `WEB_UI_ACTION_*` today. **Less visible than R1** — a hidden menu item is obvious; an enabled-looking button that 403s is not. | **High** | §3.6's ACTION grant table (needs P2 sign-off); P3's regression predictor must cover actions, not just menu items; P6 sequences the UI's disabled-control state ahead of the server gate; M7 | Accepted only once P2 answers. **If the grants are declined, this stops being a risk and becomes the intended behaviour — but it must be stated, not defaulted into.** |
| **R2** | **Hard-on with no kill switch**, and unlike 2968 there is no pre-existing client-side filter to fall back on. | **High** | P2/P3/P4; deploy order P6 (api first); rollback = revert the UI image | Accepted per decision, named explicitly. |
| **R3** | **The best-fit grant table is a business assertion.** Assigning master data to `inventory-manager` may be wrong for a given tenant. | **High** | P2 — Brent signs off; F3 leaves tenant-authored roles untouched; per-tenant override via User Management | Low after P2. |
| **R3b** | 🔴 **An action-gate 403 logs the operator out.** `wms2-web-ui/plugins/axios.js` retries 403 three times then `$kc.logout()`. Fix E's whole point is a clear denial; the client converts it into a session failure. Found 2026-08-17. | **High** | §5.1-P8 — `X-Authz-Denied` + skip retry. Test `test/plugins/axios.spec.js#doesNotRetryWhenXAuthzDeniedHeaderPresent`. **The header's constant + CORS exposure are built by SBDEV-2968 §3.1-A2b, not here** (reassigned 2026-08-17); this plan's mitigation is therefore **dependent on 2968 landing first** — grep the base branch for `AUTHZ_DENIED_HEADER` before relying on it. | None once P8 lands **and** 2968's A2b is present. Note the UI-side *disabled control* (E1) is what prevents most users ever triggering it. |
| **R3c** | **A gate applied to one member of a single/bulk pair leaves the other open.** §0.B.1 lists 8 such endpoints for 4 constants; the bulk members are also where a service-layer guard silently returns HTTP 200. Related asymmetry: `transferStock` is shared with mobile but `bulkTransferStock` may not be (§0.B.1 note 3) — gating them identically would 403 mobile Move Stock. | **High** | ArchUnit asserts **pairs**, not constants; §0.B.1 is the checklist; AC-13 restated per endpoint. | Low if §0.B.1 is worked row by row. |
| **R4** | Deep-linkable pages not in the menu fall through the guard. | Medium | P7 enumerates `_id.vue` and other non-menu routes; `detailRoutesInheritTheirListPageFunction` | Low. |
| **R5** | Cold-start race — middleware runs before functions load, bouncing every hard refresh. | Medium | Memoised `ensureFunctionsLoaded()` awaited in the guard; M9 | Low. |
| **R6** | Action gate placed at the controller instead of the service would miss the mobile caller. | Medium | §3.5 states service-layer explicitly; tests target the service | Low. |
| **R7** | An implementer hooks the action gate onto `UnitLoadController`'s existing constant argument, which is really the `comment` (§0.C). | Medium | §3.5 warns explicitly; §0.C documents the 478-row evidence | Low. |
| **R8** | Flyway version collides with 2968's V2.2.17 or an unmerged branch. | Medium | P5 re-sweep at PR time | Low. |
| **R9** | Gating a shared controller 403s the mobile UI. | Medium | This plan gates **no** controller — view gates come from 2968's map, action gates are service-layer. SBDEV-2968 §12 C-1 applies if that changes. | Low. |
| **R10** | `CS-REP`-style tenant roles are modified by the seed. | Low | F3 — the migration touches only the 7 seeded personas, keyed by name | Low. |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance criteria

| # | Criterion | Failing test today |
|---|---|---|
| AC-1 | Every menu leaf declares a function | `appMenuList.spec#everyLeafDeclaresAFunction` |
| AC-2 | The 4 dead persona menus are gone | `…#theFourDeadPersonaMenusAreGone` |
| AC-3 | `links()` filters by held functions | `default.spec#rendersOnlyItemsWhoseFunctionIsHeld` |
| AC-4 | A group with no surviving child is hidden | `…#hidesAGroupWhenNoChildSurvives` |
| AC-5 ‡ | `super-admin` still sees all 30 | `…#superAdminStillSeesAllThirty` — **green today** (the menu *is* hardcoded to super-admin); a regression guard, not a gate |
| AC-6 | CS-REP's real function set yields its 12 items | `…#csRepSeesTheTwelveItemsItsFunctionsAllow` |
| AC-7 | `getUserRoles` commits the functions | `store/index.spec#getUserRolesCommitsTheFunctions` — **red today, commits nothing** |
| AC-8 | No `WEB_UI_LOG_IN` → bounced | `pages/index.spec#bouncesUserWithoutWebUiLogIn` |
| AC-9 | Route guard waits for load before deciding | `requireFunction.spec#waitsForEnsureFunctionsLoadedBeforeDeciding` |
| AC-10 | Detail routes inherit their list page's function | `…#detailRoutesInheritTheirListPageFunction` |
| AC-11 | Admin tabs filter individually | `admin.spec#rendersOnlyTabsWhoseFunctionIsHeld` |
| AC-12 | User Management tab hidden without its function | `…#userManagementTabHiddenWithoutItsFunction` |
| AC-13 | Each action denies without its function **on BOTH its single and its bulk endpoint** — §0.B.1 shows 8 endpoints for 4 constants on `StockUnitController` alone. A test covering only the single member would leave the bulk one open. | `StockunitServiceActionGuardUnitTest` / `…ActionGuardUnitTest` per §6.2 — one pair per **endpoint**, not per constant |
| AC-14 ‡ | Action gates live in the service, not a controller | ArchUnit: no `@RequiresFunction` naming a `WEB_UI_ACTION_*` — **green vacuously today AND unwritable until SBDEV-2968 merges** (`@RequiresFunction` does not exist yet). Do not author it pre-2968 |
| AC-15 | Seed grants master data to `inventory-manager` | `UtilRestControllerSeedUnitTest#seedsMasterDataFunctionsToInventoryManager` |
| AC-16 | `USER_MANAGEMENT` stays `super-admin`-only | `…#leavesUserManagementOnSuperAdminOnly` |
| AC-17 | Grant migration is idempotent, `NOT EXISTS`, no `ON CONFLICT` | verify-script rows |
| AC-19 | An authorization 403 is **not** retried and does **not** log the user out; a plain 401 still is retried. | `test/plugins/axios.spec.js#doesNotRetryWhenXAuthzDeniedHeaderPresent`, `#stillRetriesAPlain401WithoutTheHeader` — both red today |
| AC-18 | The grant migration includes **ACTION** grants, not only VIEW | `UtilRestControllerSeedUnitTest#seedsActionFunctionsPerTheApprovedTable` — guards against F3, the silent capability removal |

‡ **Not gates.** AC-5 and AC-14 are green on `develop` today. They are regression pins and are marked so rather than padding the failing-test count.

### 9.2 Verify script

`sbdocs/9-System/scripts/verify-SBDEV-2967-web-ui-function-gating-enforcement.sh` — to be authored with the plan; run before any change for the FAIL baseline. **Guard every helper on file existence** — the template's `file_not_contains` returns true for a missing file and false-greens every negative assertion about a new file.

---

## 10. Open Questions / Resolved Decisions

**Resolved**

- **10.4** Menu filtering, route guard, `WEB_UI_LOG_IN` entry gate, per-tab admin gating, and action gates (UI + server) are all in scope.
- **10.5** Rollout is hard-on, no flag — consistent with SBDEV-2968.
- **10.6** No new `FunctionEnum` constants; all 30 items map to existing ones. The gap is grants, not constants.
- **10.7 REVERSED at architect review.** Action gates go at the **controller**, method-level, for the 7 web-only actions; only `ADJUST_LOCK_DAMAGED` stays at the service layer. A service-layer guard throwing `BusinessException` returns **HTTP 200** on every bulk path (`StockUnitController:224-254` catches it and returns `ResponseEntity.ok(errorMap)`), so it would not be a gate at all. Full evidence in §3.5.
- **10.8** Tenant-authored roles (`CS-REP`) are not modified.

**Open**

- 🔴 **10.1 The §3.6 best-fit grant table needs Brent's sign-off.** It asserts that `inventory-manager` owns master data and `outbound-manager` owns transfers. Plausible, not authoritative. **P2 blocks on this.**
- **10.9 Reports → Parcel Picking has no matching constant** — and this is the *inverse* of what an earlier draft said. Corrected at architect review, then verified directly:
  - `store/reports/parcelPicking.js` calls `/report/exportParcelPicking` and **`/report/parcelPickingView`**.
  - `store/reports/outboundParcel.js` calls `/report/exportOutboundParcel` and **`/report/parcelMonitorView`**.
  - Only **`WEB_UI_VIEW_PARCEL_MONITOR`** exists in `FunctionEnum` — there is no `..._PARCEL_PICKING`.

  So `PARCEL_MONITOR` belongs to **row 27 (Outbound Parcel)**, which is the row that actually calls `parcelMonitorView` — and **row 26 (Parcel Picking) is the genuinely unmapped leaf.** The earlier draft had these backwards and named the wrong row as ambiguous.

  Options for row 26: reuse `WEB_UI_VIEW_PARCEL_MONITOR` as an ANY-of with row 27 (simplest, but conflates two screens); reuse `WEB_UI_VIEW_PICKING_ORDER` (it is a picking report, and that constant already covers Pick Pack); or add `WEB_UI_VIEW_PARCEL_PICKING` — the only option needing a new constant + seed + migration. **No recommendation yet** — this one genuinely needs a product view on whether Parcel Picking is a picking screen or a parcel screen.
- **10.2** The **7** `WEB_UI_VIEW_*` constants with no page (`RACK`, `RACK_ROW`, `TYPE_CAPACITY_CONSTRAINT`, `STOCK_COUNT`, `SEQUENCE_NUMBER`, `DB_QUERIES`, `ORDER_DETAIL_MONITOR`) — retire or leave? Note `CS-REP` holds `STOCK_COUNT` and `DB_QUERIES`, so retiring is not free. Own ticket. **`WEB_UI_VIEW_CLIENT` was previously miscounted into this list — it is not orphaned**; it backs the Admin → Shippers tab (`store/admin/shippers.js` calls `/client` exclusively), per §3.4.
- **10.3 RESOLVED** — the §0.C audit-comment defect (478 rows on WineCo dev) is **[SBDEV-2979](https://app.clickup.com/t/868kt336b)**, filed 2026-08-17. Not authorization; deliberately not folded in here. ⚠️ That ticket carries the warning that these call sites must **not** be repurposed as the authorization hook — gating container deletion is this plan's Fix E, on the controller method, not in the `comment` argument.

---

## 11. Notes

### 11.1 Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1.2 — WineCo dev live, `db_verified: true` |
| 1 | All callsites enumerated | ✓ §0.A–§0.D |
| 2 | Adjacent bugs | ✓ §0.C (478 audit rows), §10.2 |
| 3 | Backward compatibility | ✓ §3.6 grants precede the filter; tenant roles untouched |
| 4 | Concurrency | ✓ §7 rows 4–6; memoised loader for the cold-start race |
| 5 | Multi-tenant | ✓ §7 row 7; grants applied per tenant, keyed by role name |
| 6 | Error handling | ✓ three distinct states — no login / no function / fetch failed |
| 7 | Observability | ✓ reuses 2968's `wms2.authz.*` counters |
| 8 | Rollback / migration | ✓ P4/P5/P6; rollback is a UI image revert |
| 9 | Test coverage | ✓ §6.1–§6.3; §6.4 records the skipped lane |
| 10 | Cross-version | no — v2-only; v1's web UI has the same pattern but its own codebase |

### 11.2 Provenance

Analysis and drafting in-session 2026-08-16, grounded by mapping all 30 menu items to the API roots their store modules actually call (§0.A.1) and validated against `wms2-wineco-dev` live. The SBDEV-2968 ralplan run had all three agent lanes stall before finalizing, so this plan was authored directly and put through an independent **Critic** pass, which returned **ITERATE** with seven findings — all applied.

**Three claims in the first draft were wrong and are corrected rather than quietly removed:**

1. *"Every menu→function assignment is derived from observed endpoint usage."* **False.** All nine report pages call the same generic `/report`, which cannot discriminate between them; Dashboard and Pick Pack are likewise judgement calls. **9 of 30 rows are semantics-derived** and are marked ⚠ in §0.A.1. That table is the review surface.
2. *"Actions are cross-UI capabilities."* **False, twice** — first as "all 8", then as "6 of 8". The mobile UI calls **no** action endpoint at all; only `ADJUST_LOCK_DAMAGED` is shared, and only service-internally. §3.5 now carries the evidence and a different, correct rationale (single + bulk controller entry points converging on one service method).
3. *"All 30 menu items map to existing constants."* **False** — Reports → Outbound Parcel has no clean mapping (§10.9), and the orphan count was 14 items / 13 needing grants, not 13.

The Critic also caught the most consequential omission: **§3.6 had no ACTION grants**, so Fix E would have silently removed all eight destructive actions from every non-`super-admin` user. That is now R1b and a P2 sign-off item.

Anything still resting on an unverified claim is flagged inline.
