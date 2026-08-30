# SBDEV-3169 — domain type → gating function map

Derived from `origin/develop @ 79320399` (`Merge pull request #235 from SiteBossInc/bugfix/SBDEV-3157-sdr-gating`, 2026-08-29 14:39 -0400) on 2026-08-29.
Cross-repo evidence from `wms2-web-ui@origin/develop cdaf9b0b` and `wms2-mobile-ui@origin/develop f42ac8d4`.
Nothing was checked out; every read was `git show origin/develop:<path>` / `git grep … origin/develop`.

---

## Method and its limits

### Mechanisms I checked

| mechanism | how I checked it | what I found |
|---|---|---|
| `@RequiresFunction` (method + class level) | `git grep -n "@RequiresFunction" origin/develop -- src/main/java` → 134 hits, then a script that walks every controller file and pairs each `@…Mapping` with the annotations immediately above it, falling back to the class-level annotation | 428 mapping-annotated handlers across 63 controller classes. Class-level on 20 controllers; method-level on ~60 handlers. |
| `@PreAuthorize` | `git grep -n "@PreAuthorize"` | **13 live annotation sites**, all `Authority.IS_SB_ADMIN`, all on `AdminController` (9), `AdminActionController` (1), `ReplenishmentReconciliationController` (1), `PutawayConfigService` (2). **None of them touch an SDR-exported domain type's read path.** |
| `@PostAuthorize`, `@Secured`, `@RolesAllowed`, `@DenyAll`, `@PermitAll` | `git grep -n` for each | **zero hits in `src/main/java`** — despite `MethodSecurityConfig:9` enabling all three families (`prePostEnabled`, `securedEnabled`, `jsr250Enabled`). |
| `FunctionGuardInterceptor.GUARDED` | read `FunctionGuardInterceptor.java:110-146` | 14 classes: the 11 mobile controllers + `UserRoleController`, `UserGroupController`, `UserController`. |
| `SecurityConfiguration.authorizeHttpRequests` | read `SecurityConfiguration.java:144-181` | Only one rule touches `/v3/**`: `:178` `.requestMatchers("/v3/**", "/putawayConfig/**").hasAnyAuthority(Authority.WMS_USER_ROLE)`. **This is the ONLY thing standing between an authenticated principal and every SDR read today** — and per `wms2-authz-axis-keycloak-coarse-functions-fine`, every WMS user holds `wms_user`. So the effective gate on all 62 domain types is "is authenticated". |
| `RestConfiguration` exposure withdrawal | read `RestConfiguration.java:1-140` + the `#235` diff | Withdraws **write verbs only**, from 4 access-chain surfaces (3013) + 48 more resources (3157). **Withdraws no reads.** |

### Declared limits

- **The mechanism set may be incomplete.** These seven are what I found and verified; I did not exhaustively prove no eighth exists. Things I did *not* audit: servlet `Filter`s other than `TenantFilter`, `@ControllerAdvice`, Hibernate `@Filter`/`@Where` row-level predicates, SpEL in repository `@Query`, and any `SecurityFilterChain` beans outside `SecurityConfiguration.java`.
- **`@RequiresFunction` resolves on the DECLARING class** (`FunctionGuardInterceptor:166`, `handlerMethod.getMethod().getDeclaringClass()`). `AdminController` is the base class of 43 controllers; a class-level annotation on a subclass does **not** reach a handler inherited from `AdminController`. I therefore only credited a gate when the annotation and the mapping are in the **same file**. My extractor works file-by-file, so it cannot over-credit an inherited handler — but it also means a handler declared in `AdminController` and routed through a subclass shows up under `AdminController` (10 handlers, all `@PreAuthorize(IS_SB_ADMIN)`), not under the subclass.
- **The 62-type list is the TSV I was handed** (`SBDEV-3157/target/sdr-surface-inventory.tsv`, rows with `exported == true`, 409 rows → 62 distinct domain types). I did **not** regenerate it against `79320399`; `#235` merged after it was produced and changed exposure. It withdrew writes only, so the *read* surface — which is what this map is about — should be unchanged, but I did not prove that.
- **A gate I cite is a gate on a route serving the same ENTITY, not necessarily the same QUERY.** `WEB_UI_VIEW_CLIENT` gates `POST /v3/client/setPrinter`; it does not gate `GET /v3/client/detailView`, which is ungated. See *Contradictions*.

---

## Summary

| confidence | count |
|---|---|
| DERIVED | 30 |
| PROPOSED | 31 |
| UNKNOWN | 1 |

**DERIVED** = I found a real `@RequiresFunction` on an MVC route in the same file that serves the same entity, cited by `file:line`.
**PROPOSED** = no gate exists on any equivalent MVC route; the function is inferred from the web-UI menu leaf that consumes the resource (`wms2-web-ui/util/appMenuList.js`, the repo's own "which screen needs which function" source of truth) or, failing that, from an exact-name-match `FunctionEnum` constant.
**UNKNOWN** = neither.

### 🔴 The headline result is not the per-type function — it is that a single function per type is WRONG for 14 of the 62.

Master-data resources are read by *many* screens with *different* gates. `/unitload` already has the precedent inside the codebase: `UnitLoadController.java:64-67` gates `reprintLabel` on an **ANY-of FOUR** — `{STOCK_UNIT, CONTAINER, CLUB_LINE, TRANSFER_ORDER}` — with an in-file comment explaining that narrowing it 403s half the screen. Any SDR rule source that maps `domainType → one function` will 403 working screens. The table below gives a **primary** function and, where the caller evidence demands it, an **ANY-of** set.

---

## Per-domain-type table

Legend for "gate today": `M:` method-level, `C:` class-level, `—` none. Paths under `src/main/java/net/aim_ai/wms/`.

| # | domainType | equivalent MVC route | gate today (mechanism + file:line) | proposed SDR function | confidence |
|---|---|---|---|---|---|
| 1 | Advice | `/v3/advice` `AdviceController` | M: `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL)` `controller/AdviceController.java:142`; also `CREATE_INBOUND_BOL` at `:71`, `INBOUND_BOL_ITEM_LINES` at `:105` | ANY-of `{WEB_UI_VIEW_INBOUND_BOL, WEB_UI_VIEW_CREATE_INBOUND_BOL}` — `store/receiving/inboundNotices.js` + `store/receiving/createPo.js` | DERIVED |
| 2 | Adviceposition | `/v3/advice/update` | M: `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES)` `AdviceController.java:105` | ANY-of `{WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES, WEB_UI_VIEW_INBOUND_BOL}` | DERIVED |
| 3 | Billoflading | `/v3/billOfLading` `BillOfLadingController` | M: `@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING)` `BillOfLadingController.java:79` | `WEB_UI_VIEW_BILL_OF_LADING` | DERIVED |
| 4 | BillofladingPosition | none of its own; served by `BillOfLadingController` | — (no route mentions it) | ANY-of `{WEB_UI_VIEW_BILL_OF_LADING_POSITION, WEB_UI_VIEW_BILL_OF_LADING}` — the `_POSITION` constant exists and gates nothing today | PROPOSED |
| 5 | Boxtype | `/v3/boxType` `BoxTypeController` | M: `@RequiresFunction(WEB_UI_VIEW_CASE_TYPE)` `BoxTypeController.java:50` | ANY-of `{WEB_UI_VIEW_CASE_TYPE, WEB_UI_VIEW_RECEIVING, WEB_UI_VIEW_CREATE_INBOUND_BOL}` — `/boxtype/search/*` is called from `components/receiving/open/receive/receivingForm.vue` and `store/receiving/createPo.js`, not only from Packaging | DERIVED |
| 6 | Client | `/v3/client` `ClientController` | M: `@RequiresFunction(WEB_UI_VIEW_CLIENT)` `ClientController.java:130` (`setSection`), `:145`, `:161` | ⚠ **Not gateable on one function.** `/client` appears in **22** web-UI files spanning Cycle Count, Shippers, Reports, Receiving, and in mobile `components/picking/pick.vue` + `store/replenish.js` (`/client/search/findByClNr`). Needs a broad ANY-of or an explicit "shipper master data is readable by any `WEB_UI_LOG_IN`/`MOBILE_UI_LOG_IN` holder" decision. | DERIVED |
| 7 | Customerorder | `/v3/customerOrder` `CustomerOrderController` | M: `@RequiresFunction(WEB_UI_VIEW_ORDER)` `CustomerOrderController.java:89`, `:114`; `WEB_UI_VIEW_TRANSFER_ORDER` `:61` | ANY-of `{WEB_UI_VIEW_ORDER, WEB_UI_VIEW_CLUB_LINE, WEB_UI_VIEW_TRANSFER_ORDER, WEB_UI_VIEW_BILL_OF_LADING}` — 6 web callers across club, transfer, pick-pack, BOL details | DERIVED |
| 8 | CustomerorderBatch | `/v3/customerOrderBatch` | M: `@RequiresFunction(WEB_UI_VIEW_ORDER_BATCH)` `CustomerOrderBatchController.java:42`; `WEB_UI_VIEW_CLUB_LINE` `:68` | ANY-of `{WEB_UI_VIEW_ORDER_BATCH, WEB_UI_VIEW_CLUB_LINE}` | DERIVED |
| 9 | CustomerorderPosition | `/v3/customerOrderPosition` `CustomerOrderPositionController` | **— none** (1 handler, ungated) | ANY-of `{WEB_UI_VIEW_ORDER_POSITION, WEB_UI_VIEW_ORDER, WEB_UI_VIEW_CLUB_LINE}`; mobile also reads it (`components/cancellation/cancellationAction.vue` → `MOBILE_UI_VIEW_CANCELLATION`) | PROPOSED |
| 10 | Cyclecount | `/v3/cycleCount` `CycleCountController` | M: `@RequiresFunction(WEB_UI_VIEW_CYCLECOUNT)` `CycleCountController.java:76`, `:97` | `WEB_UI_VIEW_CYCLECOUNT` | DERIVED |
| 11 | CyclecountDtoView | **none** — `CyclecountDtoViewRepository` has zero consumers in `src/main` | — | `WEB_UI_VIEW_CYCLECOUNT` (name match). **Consider un-exporting instead**: no MVC consumer, no UI caller found in either UI. | PROPOSED |
| 12 | CyclecountPosition | `/v3/cycleCount/positionView` `:298` | **— none** on the view endpoints | ANY-of `{WEB_UI_VIEW_CYCLECOUNT_POSITION, WEB_UI_VIEW_CYCLECOUNT, MOBILE_UI_VIEW_CYCLE_COUNT}` — web `cycleCountDetailTable.vue`, mobile `store/cycleCount.js` + `components/cycleCount/bySku/*` | PROPOSED |
| 13 | FixLocationAssignment | `/v3/fixedAssignment` `FixLocationAssignmentController` | **C:** `@RequiresFunction(WEB_UI_VIEW_FIXED_ASSIGNMENT)` `FixLocationAssignmentController.java:31` — covers all 9 handlers | `WEB_UI_VIEW_FIXED_ASSIGNMENT`; also read by `store/admin/configuration.js` → add `WEB_UI_VIEW_SYSTEM_PROPERTY` | DERIVED |
| 14 | FlowbinMonitorView | `/v3/report/flowbinMonitorView` `ReportController.java:352` | **— none** | `WEB_UI_VIEW_FLOWBIN_MONITOR` (menu row 25, `appMenuList.js:113`) | PROPOSED |
| 15 | Goodsreceipt | `/v3/receiving/*` `ReceivingController` | M: `@RequiresFunction(WEB_UI_VIEW_RECEIVING)` `ReceivingController.java:190` (entity-adjacent, not entity-specific) | ANY-of `{WEB_UI_VIEW_GOODS_RECEIPT, WEB_UI_VIEW_INBOUND_BOL, WEB_UI_VIEW_RECEIVING}` — sole web caller is `store/receiving/inboundNotices.js` | PROPOSED |
| 16 | Goodsreceiptposition | `/v3/goodsReceiptPosition` | M: `@RequiresFunction(WEB_UI_VIEW_GOODS_RECEIPT_POSITION)` `GoodsReceiptPositionController.java:61`, `:106` | ANY-of `{WEB_UI_VIEW_GOODS_RECEIPT_POSITION, WEB_UI_VIEW_INBOUND_BOL}` | DERIVED |
| 17 | InventoryRecord | `/v3/report/exportInventory` `ReportController.java:59` | **— none** | `WEB_UI_VIEW_INVENTORY_RECORD` (menu row 21) | PROPOSED |
| 18 | Itemdata | `/v3/itemData` `ItemDataController` (8 handlers) — **entirely ungated**; the only gate on the entity is `PutawayConfigController` | M: `@RequiresFunction(WEB_UI_VIEW_ITEM_DATA)` `controller/PutawayConfigController.java:189` (`setSku`) | ANY-of `{WEB_UI_VIEW_ITEM_DATA, WEB_UI_VIEW_CYCLECOUNT, WEB_UI_VIEW_CREATE_INBOUND_BOL}` — `/itemdata/search/*` callers are `store/internalOps/createCc.js` and `store/receiving/createPo.js`; 16 web files + 4 mobile files reference `/itemdata` overall | DERIVED |
| 19 | Itemunit | **none** — only `FileImportController` and `SkuRestController` (`/rest/**`, internal) | — | `WEB_UI_VIEW_ITEM_UNIT` (menu row 19) | PROPOSED |
| 20 | Location | `/v3/location` `LocationController` | M: `@RequiresFunction(WEB_UI_VIEW_STORAGE_LOCATION)` `LocationController.java:62`, `:84` | ⚠ ANY-of at least `{WEB_UI_VIEW_STORAGE_LOCATION, WEB_UI_VIEW_BILL_OF_LADING, WEB_UI_VIEW_INBOUND_BOL, MOBILE_UI_VIEW_CYCLE_COUNT, MOBILE_UI_VIEW_INFO, MOBILE_UI_VIEW_REPLENISHMENT}` — 23 web files + mobile `store/{cycleCount,lookup,replenish}.js` | DERIVED |
| 21 | LocationArea | **none** | — | `WEB_UI_VIEW_AREA` (menu row 15); also read by `store/internalOps/createCc.js` → add `WEB_UI_VIEW_CYCLECOUNT` | PROPOSED |
| 22 | LocationConstraint | `controller/rest/UtilRestController` — ⚠ that class is `@Service`, **its `@RequestMapping` methods do not route** | — | `WEB_UI_VIEW_TYPE_CAPACITY_CONSTRAINT` (name match); web caller is `store/admin/configuration.js` → also `WEB_UI_VIEW_SYSTEM_PROPERTY` | PROPOSED |
| 23 | LocationRack | **none** | — | ANY-of `{WEB_UI_VIEW_RACK, WEB_UI_VIEW_STORAGE_LOCATION}` — sole caller `store/masterData/storageLocation.js` (menu row 12) | PROPOSED |
| 24 | LocationRackRow | **none** (repo consumed only by services + `FileImportController`) | — | `WEB_UI_VIEW_RACK_ROW` (name match). No UI caller found in either UI. | PROPOSED |
| 25 | LocationType | `/v3/location/createLocationType` | M: `@RequiresFunction(WEB_UI_VIEW_STORAGE_LOCATION_TYPE)` `LocationController.java:106`, `:128` | ANY-of `{WEB_UI_VIEW_STORAGE_LOCATION_TYPE, WEB_UI_VIEW_STORAGE_LOCATION}` | DERIVED |
| 26 | LockOverviewAllDtoView | `/v3/report/exportLock` `ReportController.java:85` | **— none** | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` (menu row 22). Called via a computed resource name at `store/reports/lock.js:56,64` — a literal-string grep misses it. | PROPOSED |
| 27 | LockOverviewDtoView | same as 26 | **— none** | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | PROPOSED |
| 28 | LosSequencenumber | **none** — `LabelPrintingService` / `SequenceTransactionService` only; nearest gated MVC consumer is `LabelPrintingController` (C: `WEB_UI_VIEW_PRINTER` `:55`) | — | `WEB_UI_VIEW_SEQUENCE_NUMBER` (name match; the constant gates nothing today). ⚠ `findByClassnameForUpdate` is a **pessimistic-lock** search — exposing it over HTTP is a DoS primitive independent of authz. | PROPOSED |
| 29 | Message | `/v3/message` `MessageController` (4 handlers) | **— none** | `WEB_UI_VIEW_MESSAGES` (Admin tab, `appMenuList.js:137`) | PROPOSED |
| 30 | MessageArchived | **none** — repo has zero consumers in `src/main` | — | `WEB_UI_VIEW_MESSAGES`. **Consider un-exporting**: no consumer anywhere. | PROPOSED |
| 31 | OrderDetailMonitorView | `/v3/report/parcelPickingView` `ReportController.java:372` | **— none** (the gated handler in that file is `reprintLabels` `:314`) | `WEB_UI_VIEW_PARCEL_PICKING` — explicitly supersedes `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` per `WmsConstants` and `appMenuList.js:115-118` | PROPOSED |
| 32 | OrderMonitorView | `/v3/dashboard/orderMonitorView*` `DashboardController:48-66` | M: `@RequiresFunction(WEB_UI_VIEW_ORDER_MONITOR)` `DashboardController.java:75` — ⚠ on `printToteLabels` only; the four monitor **reads** at `:48-66` are ungated | `WEB_UI_VIEW_ORDER_MONITOR` (menu row 1) | DERIVED |
| 33 | ParcelMonitorView | `/v3/report/parcelMonitorView` `:392` + `/v3/billOfLading/palletize` | M: `@RequiresFunction(WEB_UI_VIEW_PARCEL_MONITOR)` `BillOfLadingController.java:497` | `WEB_UI_VIEW_PARCEL_MONITOR` (menu row 27) | DERIVED |
| 34 | Pickingorder | **no web MVC controller**; mobile `PickingController` (C: `MOBILE_UI_VIEW_PICKING` `:33`, in GUARDED) | C: `controller/mobile/PickingController.java:33` | ANY-of `{WEB_UI_VIEW_PICKING_ORDER, MOBILE_UI_VIEW_PICKING}` (menu row 5) | PROPOSED |
| 35 | PickingorderPosition | `/v3/pickingOrderPosition` `PickingOrderPositionController` (1 handler) | **— none** | ANY-of `{WEB_UI_VIEW_PICKING_POSITION, WEB_UI_VIEW_PICKING_ORDER, MOBILE_UI_VIEW_PICKING}` | PROPOSED |
| 36 | PickingorderUnitload | `AdminController`-declared handlers via `AdminActionController` | M: `@PreAuthorize(Authority.IS_SB_ADMIN)` `AdminActionController.java:341` (one handler only) | ANY-of `{WEB_UI_VIEW_PICKING_UNIT_LOAD, MOBILE_UI_VIEW_PICKING}` | PROPOSED |
| 37 | Printer | `/v3/printer` `PrinterController` | M: `@RequiresFunction(WEB_UI_VIEW_PRINTER)` `PrinterController.java:81`, `:116`, `:155`, `:223` | ANY-of `{WEB_UI_VIEW_PRINTER, WEB_UI_VIEW_PARCEL_PICKING}` — `/printer/search/findByType` is called from `store/reports/parcelPicking.js` as well as `store/admin/printer.js` | DERIVED |
| 38 | Queryrepository | **none** — `QueryrepositoryRepository` has zero consumers in `src/main`; zero UI callers | — | `WEB_UI_VIEW_DB_QUERIES` (exact name match). **Strong un-export candidate** — an SDR-only surface named "query repository" with no client. | PROPOSED |
| 39 | ReceivedDtoView | **none** — zero consumers in `src/main`; zero UI callers | — | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` (menu row 23). **Un-export candidate.** | PROPOSED |
| 40 | ReceivingDtoView | `/v3/receiving` `ReceivingController` | M: `@RequiresFunction(WEB_UI_VIEW_RECEIVING)` `ReceivingController.java:190` (entity-adjacent) | ANY-of `{WEB_UI_VIEW_RECEIVING, WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW, WEB_UI_VIEW_INBOUND_BOL}` — 3 distinct screens call `/receivingDtoView/search/*` | PROPOSED |
| 41 | ReplenishmentMonitorView | `/v3/dashboard/replenishMonitorViewSummary` `DashboardController.java:116` | **— none** | `WEB_UI_VIEW_REPLENISHMENT_MONITOR` (name match) | PROPOSED |
| 42 | Replenishorder | `/v3/replenishOrder` `ReplenishOrderController` | M: `@RequiresFunction(WEB_UI_VIEW_REPLENISHMENT_ORDER)` `ReplenishOrderController.java:78` (+ 5 more) | ANY-of `{WEB_UI_VIEW_REPLENISHMENT_ORDER, MOBILE_UI_VIEW_REPLENISHMENT, MOBILE_UI_VIEW_REPLENISH_REQUEST}` — mobile `store/replenish.js`, `pages/replenish.vue` | DERIVED |
| 43 | Section | `/v3/section` `SectionController` | M: `@RequiresFunction(WEB_UI_VIEW_SECTION)` `SectionController.java:53` | ANY-of `{WEB_UI_VIEW_SECTION, WEB_UI_VIEW_CLIENT, MOBILE_UI_VIEW_PICKING}` — Shippers admin (`addShipper.vue`/`editShipper.vue`) and mobile `store/picking.js` both read it | DERIVED |
| 44 | Shipperid | `/v3/shipperId` `ShipperIdController` | M: `@RequiresFunction(WEB_UI_VIEW_CLIENT)` `ShipperIdController.java:133`, `:162` | ANY-of `{WEB_UI_VIEW_CLIENT, WEB_UI_VIEW_INVENTORY_RECORD}` — `store/reports/inventory.js` reads `/shipperid` for the report's shipper filter | DERIVED |
| 45 | Shippingmethod | **none** — `UnitloadService` / `MobilePalletizingService` only | — | no menu leaf, no name-matching constant, no UI caller. Nearest guesses: `WEB_UI_VIEW_CLIENT` (shipper admin owns shipping methods) or `MOBILE_UI_VIEW_PALLETIZING` (the only runtime consumer). **I could not decide between them.** | **UNKNOWN** |
| 46 | ShippingmethodShipperid | `/v3/shipperId` — `ShipperIdController` consumes `ShippingmethodShipperidRepository` directly | M: `@RequiresFunction(WEB_UI_VIEW_CLIENT)` `ShipperIdController.java:133` | `WEB_UI_VIEW_CLIENT` | DERIVED |
| 47 | StockView | `/v3/report/exportInventory` `ReportController.java:59` | **— none** | `WEB_UI_VIEW_INVENTORY_RECORD` — ⚠ the Inventory Report screen (menu row 21) is gated on `INVENTORY_RECORD` but actually reads `/stockView/search/findByKeyword` (`store/reports/inventory.js`), not `InventoryRecord`. The constant is misnamed relative to the data. | PROPOSED |
| 48 | Stockrecord | `/v3/stockrecord` `StockRecordController` (3 handlers) | **— none** | `WEB_UI_VIEW_STOCK_UNIT_RECORD` (menu row 28). Also read by `plugins/adjustmentAlerts.client.js` — a **global plugin**, so it fires on every page; confirm before gating. | PROPOSED |
| 49 | Stockunit | `/v3/stockUnit` `StockUnitController` | M: `@RequiresFunction({MOBILE_UI_VIEW_STOCK_TRANSFER, WEB_UI_VIEW_STOCK_UNIT})` `StockUnitController.java:116`, `:221`, `:741` | ANY-of `{WEB_UI_VIEW_STOCK_UNIT, MOBILE_UI_VIEW_STOCK_TRANSFER, WEB_UI_VIEW_REPLENISHMENT_ORDER, MOBILE_UI_VIEW_REPLENISHMENT}` — `/stockunit/search/getStockUnitsForReplenishment` is called from `store/internalOps/replenishments.js` | DERIVED |
| 50 | Sysprop | `/v3/systemProperty` `SystemPropertyController` | **C:** `@RequiresFunction(WEB_UI_VIEW_SYSTEM_PROPERTY)` `SystemPropertyController.java:34` | `WEB_UI_VIEW_SYSTEM_PROPERTY` — ⚠ verify no pre-function bootstrap read; `/sysprop/search/findByGroupname` appears in `store/admin/configuration.js`, `store/admin/management.js`, `store/admin/mgmt/overview.js`, `editParamAndConfig.vue` (all admin, so probably safe) | DERIVED |
| 51 | Unitload | `/v3/unitLoad` `UnitLoadController` | M: `@RequiresFunction({WEB_UI_VIEW_STOCK_UNIT, WEB_UI_VIEW_CONTAINER, WEB_UI_VIEW_CLUB_LINE, WEB_UI_VIEW_TRANSFER_ORDER})` `UnitLoadController.java:64-67` | **Reuse that exact 4-way ANY-of**, plus `WEB_UI_VIEW_UNIT_LOAD_TYPE` and `WEB_UI_VIEW_CREATE_INBOUND_BOL` (`store/masterData/unitLoadType.js`, `store/receiving/createPo.js`) and the mobile cycle-count functions | DERIVED |
| 52 | UnitloadRecord | `/v3/unitloadRecord` `UnitloadRecordController` (2 handlers) | **— none** | `WEB_UI_VIEW_UNIT_LOAD_RECORD` (menu row 29) | PROPOSED |
| 53 | UnitloadType | **none** (only `FileImportController`) | — | ANY-of `{WEB_UI_VIEW_UNIT_LOAD_TYPE, WEB_UI_VIEW_CREATE_INBOUND_BOL}` (menu row 17 + `store/receiving/createPo.js`) | PROPOSED |
| 54 | User | `/v3/user` `UserController` | **C:** `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` `UserController.java:83`; in `GUARDED` (`FunctionGuardInterceptor:145`) | `WEB_UI_VIEW_USER_MANAGEMENT`. ⚠ The two bootstrap reads (`isWmsUser` `:276`, `getAllRoles` `:605`) are `@PublicHandler` — they are **MVC**, not SDR, so SDR `/user` is safe to gate. | DERIVED |
| 55 | UserFunction | served by `UserRoleController` (Roles screen) | **C:** `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` `UserRoleController.java:39` | `WEB_UI_VIEW_USER_MANAGEMENT`. Note `WEB_UI_VIEW_FUNCTION` exists as a constant and gates nothing. Callers: `store/admin/function.js`, `store/admin/management.js`. | PROPOSED |
| 56 | UserGroup | `/v3/userGroup` `UserGroupController` | **C:** `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` `UserGroupController.java:46`; in `GUARDED` | 🔴 **`WEB_UI_VIEW_USER_MANAGEMENT` WOULD BREAK LOGIN — see Contradictions #1.** `GET /userGroup/search/findByUsername` runs for **every** user on every web login. Needs a `@PublicHandler`-equivalent carve-out for that one search, or a distinct low function. | DERIVED |
| 57 | UserGroupUser | `/v3/user/saveUserGroups` `UserController.java:536` (access-chain hop 1) | **C:** `WEB_UI_VIEW_USER_MANAGEMENT` `UserController.java:83`. Writes already withdrawn: `RestConfiguration` (`configureAccessChainMembershipWriteExposure`) | `WEB_UI_VIEW_USER_MANAGEMENT` | DERIVED |
| 58 | UserGroupUserRole | `/v3/userGroup/saveGroupRoles` `UserGroupController.java:137` (hop 2) | **C:** `WEB_UI_VIEW_USER_MANAGEMENT` `UserGroupController.java:46`; writes withdrawn | `WEB_UI_VIEW_USER_MANAGEMENT` | DERIVED |
| 59 | UserRole | `/v3/userRole` `UserRoleController` | **C:** `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` `UserRoleController.java:39`; in `GUARDED` | `WEB_UI_VIEW_USER_MANAGEMENT` | DERIVED |
| 60 | UserRoleUserFunction | `/v3/userRole/saveRoleFunctions` `UserRoleController.java:127` (hop 3) | **C:** `WEB_UI_VIEW_USER_MANAGEMENT` `UserRoleController.java:39`; writes withdrawn by SBDEV-3013 door ① (`RestConfiguration.configureRoleFunctionWriteExposure`) | `WEB_UI_VIEW_USER_MANAGEMENT` | DERIVED |
| 61 | UserUserRole | `/v3/user` (direct user→role grant) | **C:** `WEB_UI_VIEW_USER_MANAGEMENT` `UserController.java:83` | `WEB_UI_VIEW_USER_MANAGEMENT`. Per `wms2-direct-user-role-assignment-is-unused`, `getAllRoles` walks user→group→role→function only, so a direct grant confers nothing — **un-export candidate**. | DERIVED |
| 62 | ViewWarehouseLocationReport | `/v3/report/exportSkuLocation` `ReportController.java:138` | **— none** | `WEB_UI_VIEW_LOCATION_OVERVIEW` (menu row 24) | PROPOSED |

---

## Domain types with NO MVC equivalent

**Zero consumers in `src/main` outside their own repository interface — SDR is the ONLY route to the data:**

| domainType | proposed function | note |
|---|---|---|
| Queryrepository | `WEB_UI_VIEW_DB_QUERIES` | no consumer, no UI caller anywhere |
| MessageArchived | `WEB_UI_VIEW_MESSAGES` | no consumer, no UI caller anywhere |
| ReceivedDtoView | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | no consumer, no UI caller anywhere |
| CyclecountDtoView | `WEB_UI_VIEW_CYCLECOUNT` | no consumer, no UI caller anywhere |

All four are stronger candidates for **`@RestResource(exported = false)`** than for a gate: a resource with no MVC route, no service consumer and no UI caller has no client to break. That is the same argument `#235` used for withdrawing writes from 48 resources, applied to reads.

**Consumed only by services / non-routing classes, no MVC route:**

| domainType | consumer | proposed function |
|---|---|---|
| Itemunit | `FileImportController`, `SkuRestController` (`/rest/**` internal), 7 services | `WEB_UI_VIEW_ITEM_UNIT` |
| LocationArea | services + `store/internalOps/createCc.js`, `store/masterData/functionalArea.js` | `WEB_UI_VIEW_AREA` |
| LocationRack | `store/masterData/storageLocation.js` | `{WEB_UI_VIEW_RACK, WEB_UI_VIEW_STORAGE_LOCATION}` |
| LocationRackRow | `FileImportController` + 8 services; **no UI caller** | `WEB_UI_VIEW_RACK_ROW` |
| LocationConstraint | `UtilRestController` (⚠ `@Service`, does not route) + `LocationConstraintService` | `WEB_UI_VIEW_TYPE_CAPACITY_CONSTRAINT` |
| LosSequencenumber | `LabelPrintingService`, `SequenceTransactionService` | `WEB_UI_VIEW_SEQUENCE_NUMBER` |
| Shippingmethod | `UnitloadService`, `MobilePalletizingService` | **UNKNOWN** |
| UnitloadType | `FileImportController` | `{WEB_UI_VIEW_UNIT_LOAD_TYPE, WEB_UI_VIEW_CREATE_INBOUND_BOL}` |
| StockView | `ReportController` export only | `WEB_UI_VIEW_INVENTORY_RECORD` |
| InventoryRecord | `InventoryRecordService`, `ReportController` export | `WEB_UI_VIEW_INVENTORY_RECORD` |
| ViewWarehouseLocationReport | `ReportController` export | `WEB_UI_VIEW_LOCATION_OVERVIEW` |
| LockOverview{,All}DtoView | `ReportService`, `ReportController` export | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` |
| FlowbinMonitorView | `ReportController` | `WEB_UI_VIEW_FLOWBIN_MONITOR` |
| ReplenishmentMonitorView | `ViewDtoService`, `DashboardController` | `WEB_UI_VIEW_REPLENISHMENT_MONITOR` |
| OrderDetailMonitorView | `ReportService`, `ViewDtoService`, `ReportController` | `WEB_UI_VIEW_PARCEL_PICKING` |
| Pickingorder / PickingorderUnitload | mobile services + `AdminActionController` | `{WEB_UI_VIEW_PICKING_ORDER, MOBILE_UI_VIEW_PICKING}` |
| BillofladingPosition | `BillOfLadingController` (entity-adjacent) | `{WEB_UI_VIEW_BILL_OF_LADING_POSITION, WEB_UI_VIEW_BILL_OF_LADING}` |

---

## Contradictions and surprises

**1. 🔴 Gating `UserGroup` on `WEB_UI_VIEW_USER_MANAGEMENT` breaks every non-admin web login.**
`wms2-web-ui/pages/index.vue:148` calls `getAffiliatedGroupsByUsername` inside `redirectPage`, which runs immediately after `ensureFunctionsLoaded` on every login, for every user. That action (`store/index.js:249`) issues `GET /userGroup/search/findByUsername?username=…` — an **SDR search**. This is exactly the shape `@PublicHandler` exists for on `UserController.isWmsUser` / `getAllRoles`: a bootstrap read that a user holding zero functions must still be able to make. It is caught (`store/index.js:256`) so login would not hard-fail, but every non-admin would get an error toast on every login and an empty `affiliatedGroups`. **Any SDR rule source must carve this one search out.**

**2. Gating an SDR read while the MVC equivalent stays open closes nothing — and that is the majority case.** Controllers serving an SDR-exported entity with **zero** `@RequiresFunction` on **any** handler:

| controller | handlers | gates |
|---|---|---|
| `TransfersController` | 17 | 0 |
| `ClubLineController` | 14 | 0 |
| `ItemDataController` | 8 | 0 |
| `MessageController` | 4 | 0 |
| `StockRecordController` | 3 | 0 |
| `UnitloadRecordController` | 2 | 0 |
| `PickingOrderPositionController` | 2 | 0 |
| `CustomerOrderPositionController` | 2 | 0 |
| `SystemController` | 3 | 0 |
| `LabelPrintingController` | 13 | class-level only (`:55`) |
| `ReportController` | 15 | **1** (`reprintLabels` `:314`); all 14 `export*` / `*View` handlers ungated |

`ReportController` is the sharpest case: `StockView`, `LockOverview*`, `ViewWarehouseLocationReport`, `InventoryRecord`, `FlowbinMonitorView`, `OrderDetailMonitorView` and `Stockrecord` would all be gated over SDR while `POST /v3/report/export*` returns the same rows to any `wms_user`.

**3. `ItemDataController` is the controller SBDEV-3017 used to *prove* the SDR gate works — and it is itself entirely ungated.** `RestConfiguration.java:47-49` records the measurement "the gate is invoked for `/v3/itemdata/search/…` and can deny with 403." Meanwhile `ItemDataController.java:99-101` records that dropping a `@RequiresFunction` there "fell through ALLOWED and survived all 5673 tests" because the class is not in `GUARDED`. Gating SDR `itemdata` without gating `/v3/itemData/detailView` leaves an identical route.

**4. A single function per domain type is provably wrong, and the codebase already knows it.** `UnitLoadController.java:60-67` carries a four-line comment explaining why `reprintLabel` needs an ANY-of FOUR and why narrowing it 403s half a screen. 14 of the 62 types have caller evidence spanning ≥2 differently-gated screens: Client (22 files), Location (23), Unitload (8), Itemdata (16), Printer (17), Section (7), Boxtype (3), Customerorder (6), Advice (2), Stockunit (2), CyclecountPosition, ReceivingDtoView, CustomerorderPosition, Shipperid.

**5. Two class-level-gated controllers are NOT in `GUARDED`, so they have no deletion tripwire.** `FixLocationAssignmentController` (`:31`) and `SystemPropertyController` (`:34`) — and `FileImportController` (`:39`), `LabelPrintingController` (`:55`). Delete the class-level annotation on any of them and every handler silently becomes ungated: `FunctionGuardInterceptor:200` returns `true` for an unannotated handler on a non-`GUARDED` class. The javadoc at `FunctionGuardInterceptor:130-140` documents this tripwire property as the actual value of `GUARDED` membership — it just was not extended to these four.

**6. `MethodSecurityConfig:9` enables `securedEnabled` and `jsr250Enabled` for zero users.** There is not one `@Secured`, `@RolesAllowed`, `@DenyAll` or `@PermitAll` in `src/main/java`. Dead configuration, but it also means those are live mechanisms an SDR rule source could be defeated by if someone adds one later.

**7. `WEB_UI_VIEW_INVENTORY_RECORD` gates a screen that does not read `InventoryRecord`.** Menu row 21 (`appMenuList.js:109`) reads `/stockView/search/findByKeyword` (`store/reports/inventory.js`). The constant name and the data it protects have diverged.

**8. `UtilRestController` is `@Service`.** It is the only "controller" referencing `LocationConstraintRepository`, and per `wms2-utilrestcontroller-is-service-not-restcontroller` its `@RequestMapping` methods do not route — so `LocationConstraint` has no MVC route at all, only the SDR one.

**9. `losSequencenumber/search/findByClassnameForUpdate` is an exported pessimistic lock.** Independent of authz: an unauthenticated-to-`wms_user` caller can take a row lock on the sequence table over HTTP. Worth a separate un-export regardless of what function is chosen.

---

## Things I could NOT determine

1. **The right function for `Shippingmethod`** (row 45). No menu leaf, no name-matching constant, no UI caller in either UI, no MVC route. `WEB_UI_VIEW_CLIENT` and `MOBILE_UI_VIEW_PALLETIZING` are both defensible and I have no evidence to choose.
2. **Whether `Sysprop` SDR reads happen before function resolution.** `AccessService` resolves functions from the DB; if any bootstrap path reads a sysprop over SDR before the function list is loaded, gating it is a chicken-and-egg deadlock. The four callers I found are all admin screens, but I did not trace `plugins/` or `middleware/` exhaustively.
3. **Non-UI callers.** I checked `wms2-web-ui` and `wms2-mobile-ui` only. I did **not** check `oms-laravel-api`, `omsv2-UI`, the v1 UIs, Postman/integration clients, or any endpoint-registry config key. `RestConfiguration`'s own javadoc records that a config-key form once hid an OMS caller of `ShipperIdController` — the same trap applies here.
4. **Dynamically-constructed SDR URLs.** `store/reports/lock.js:56` builds the resource name in a variable; a literal grep misses that shape. There may be more. My caller lists are therefore **lower bounds** — a type I marked "no UI caller" may have one.
5. **Whether the collection root and each `/search/*` endpoint need the same function.** The TSV has 409 rows over 62 types; some searches are clearly narrower than others (e.g. `Replenishorder` has 41 searches, several of which are scheduler-internal `getIdsTo*` queries). I mapped at the **domain-type** level only, as asked. A per-search map would likely split several rows.
6. **Whether the TSV's `exported == true` set still holds at `79320399`.** It was generated in the SBDEV-3157 worktree at an unstated commit, before `#235` merged. `#235` withdrew write verbs only, so the read surface should be unchanged — unverified.
7. **`InventoryRecord` vs `StockView` on menu row 21** (Contradiction 7): I could not tell whether the misnaming means row 21's gate should move to `StockView`, or whether `InventoryRecord` belongs to a different screen I did not find.
8. **Whether an eighth gate mechanism exists.** Per the brief's warning, I am not asserting a closed set. I did not audit servlet filters beyond `TenantFilter`, `@ControllerAdvice`, Hibernate row-level filters, or `SecurityFilterChain` beans outside `SecurityConfiguration.java`.
