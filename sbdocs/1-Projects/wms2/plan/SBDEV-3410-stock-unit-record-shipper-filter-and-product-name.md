---
title: "Stock Unit Record — shipper filter and product name"
ticket: "SBDEV-3410"
ticket_url: ""
type: "feature"
priority: ""
status: "approved"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-18"
updated: "2026-09-18"
db_verified: true
base_commit: "29ce240d (wms2-api origin/develop, evidence base) · a27703eb (wms2-web-ui origin/develop) · 7ebb9c83 (wms2-api origin/develop, round-4 _embedded measurement)"
related:
  - "[[SBDEV-2976]]"
  - "[[SBDEV-3417]]"
  - "[[SBDEV-3017]]"
  - "[[SBDEV-3247]]"
  - "[[SBDEV-2658]]"
  - "[[SBDEV-3239]]"
tags:
  - plan
---

# Stock Unit Record — shipper filter and product name

**Ticket:** SBDEV-3410 (split from SBDEV-2976 Gap 1)
**Project:** wms2 | **Version:** v2 | **Type:** feature
**Status:** approved (round 4, 2026-09-18) — next step is `wms-tdd-gate`
**Date:** 2026-09-18
**Tier:** T3 — Flyway migration + a new SDR-exposed domain type + an authorization-gate widening. Any one of those three is a T3 trigger on its own.

**Evidence base.** Every citation in this plan is lifted from
`sbdocs/1-Projects/wms2/plan/SBDEV-3410-evidence/analysis-bundle.md` (824 lines), which derived them by
`git show origin/develop:<path>` at `wms2-api` `origin/develop = 29ce240db0c9edb747346e2b6fe42287afcd0b63`
(2026-09-18 10:26 -0400) and `wms2-web-ui` `origin/develop = a27703eb32f9f8f4fede697fe82ce13ba6e62a6c`
(2026-09-17 15:37 -0400). **Citations are `file` + a quoted snippet; line numbers appear only as navigation
hints and are not the citation** — they drift.

**Revision history** lives in `SBDEV-3410-evidence/revision-log.md` (rounds 2–4). **The migration SQL** is a
file, not a fence: `SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql`. **The zero-row SDR wire shape** is
measured in `SBDEV-3410-evidence/embedded-shape-measurement.md` — read it before writing §7.4's fixtures.

**DB evidence.** Every measurement is `dev_wh01_om1` @ `localhost:25060` (the `wms2-wineco-dev` target),
2026-09-18, driven with `psql` + `PGPASSWORD` (never a concatenated libpq URL — the password contains `@`).
Leave-as-found was verified: `information_schema.views` shows 0 rows matching `%probe%`, `pg_indexes` for
`stockrecord` shows the same 13 indexes as before, `count(*) = 9,726,795` unchanged.

---

## 0. Affected Sites

Derivation method: `git grep -n` over `origin/develop` for the literals `stockrecord`, `Stockrecord`,
`stock_view`, `StockView`, `exportStockUnitRecord`, `findByKeyword`, `findByOffsetAndLimit`, `getClients`,
plus `git ls-tree -r --name-only` over `components/reports/` and `store/reports/`. **`git grep`, not `grep`** —
`wms2-web-ui` `.gitignore`s `reports/`, which hides 34 files from a plain `grep`, and the local `grep` is
`ugrep`, which silently skips binary files without `-a`.

⚠ **The `getClients` sweep is repo-wide, not scoped to `components/reports/` — that scoping is what hid
the two closest precedents.** `git grep -n "getClients" origin/develop -- '*.vue' '*.js'` returns **26 dispatch
sites in 15 files** (one commented out, `receivingReport.vue`'s
*`// this.$store.dispatch('admin/client/getClients')`*). The eight files outside `components/reports/` are rows
45–52 below. Two of them — `components/handlingUnits/{containerTable,stockUnitsTable}.vue` — are **SBDEV-2976
Gap 2, the sibling half of this ticket's own parent**, and they already decided every question §3.9 re-opens.
They, not `inventoryReport.vue`, are the primary REFERENCE for this plan; `inventoryReport.vue` carries "the
older `clNr` shape, rejected by Q1". The consequence for Q1's recorded cost is in §10.1.

### 0.1 `v2/wms2-api`

| # | File + quoted snippet | Construct | In scope? | Phase |
|---|---|---|---|---|
| 1 | `src/main/resources/db/migration/V2.2.33__stockrecord_view.sql` *(new)* — `CREATE OR REPLACE VIEW public.stockrecord_view` | Flyway migration (DDL) | **YES** | P1 |
| 2 | `src/main/resources/db/migration/V2.2.33__stockrecord_view.sql` *(new, 2nd statement)* — `CREATE INDEX index_stockrecord_client_created ON stockrecord (client_id, created DESC)` | Flyway migration (DDL) | **YES** | P1 |
| 3 | `src/main/java/net/aim_ai/wms/model/StockrecordView.java` *(new)* — `@Entity @Table(name = "stockrecord_view")` | JPA entity (read-only view mapping) | **YES** | P2 |
| 4 | `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordViewRepository.java` *(new)* — `@RepositoryRestResource(collectionResourceRel = "stockrecordView", path = "stockrecordView")` | Spring Data REST repository | **YES** | P2 |
| 5 | `src/main/java/net/aim_ai/wms/RestConfiguration.java` — `config.exposeIdsFor(… Stockrecord.class, Stockunit.class, StockView.class, …)` | SDR config call | **YES** — add `StockrecordView.class` or the details popup breaks (§3.5) | P2 |
| 6 | `src/main/java/net/aim_ai/wms/RestConfiguration.java` (`SDR_WRITE_WITHDRAWN`) — `net.aim_ai.wms.model.StockView.class,` / `net.aim_ai.wms.model.Stockrecord.class,` | SDR write-withdrawal list | **YES — REQUIRED, not parity.** `ReadOnlyPagingAndSortingRepository` suppresses only `save`/`saveAll`; the delete verbs stay exported (§3.5) | P2 |
| 6a | `src/test/java/net/aim_ai/wms/security/SdrWriteWithdrawalContextTest.java` — `assertThat(WITHDRAWN).hasSize(49);` and a javadoc asserting the set is *"IDENTICAL"* to `RestConfiguration.SDR_WRITE_WITHDRAWN` | write-withdrawal pin | **YES** — add the 50th name, bump 49→50, correct the javadoc. Nothing else goes red if this is skipped, so the omission is silent | P2 |
| 7 | `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordRepository.java` — `@RestResource(path = "findByKeyword", rel = "findByKeyword")` / `Page<Stockrecord> findByKeyword(@Param("keyword") String keyword, Pageable p);` | SDR search method | **YES (no edit this ticket)** — the route the table reads today; its withdrawal is **Q5, left OPEN** | P2 |
| 8 | `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordRepository.java` — `@RestResource(path = "findByOffsetAndLimit", …)` / `List<Stockrecord> findByOffsetAndLimit(@Param("keyword") String keyword, @Param("offset") int offset, @Param("limit") int limit);` — **no `exported = false`, so this is a live HTTP route today** | native-SQL export query | **YES — NO EDIT.** Its signature and predicate stay byte-identical; the filtered variant is a **new sibling method** (row 8a). Editing this one in place would have broken it for every caller that omits the new parameter — see §3.6 and §6 | P3 |
| 8a | `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordRepository.java` *(new method)* — `findByClientOffsetAndLimit(keyword, clientId, offset, limit)`, `@RestResource(exported = false)` | native-SQL export query, filtered | **YES** — plain equality on `client_id`, no `OR` arms (§3.6) | P3 |
| 9 | `src/main/java/net/aim_ai/wms/service/ReportService.java` — `public void exportStockUnitRecord(HttpServletResponse response, int offset, int limit, String keyword) throws BusinessException` | service method signature | **YES** — gains `Long clientId` | P3 |
| 10 | `src/main/java/net/aim_ai/wms/service/ReportService.java` — `List<Stockrecord> views = stockrecordRepository.findByOffsetAndLimit(keyword, offset, limit);` | call site | **YES** | P3 |
| 11 | `src/main/java/net/aim_ai/wms/controller/ReportController.java` — `@PostMapping(path= "/exportStockUnitRecord")` … `String keyword = (String) reqMap.get("keyword");` … `reportService.exportStockUnitRecord(response , offset, limit, keyword);` | MVC endpoint | **YES** — must read `filter` from `reqMap` (§3.6) | P3 |
| 12 | `src/main/java/net/aim_ai/wms/controller/DashboardController.java` — `public class DashboardController extends ReportController` | inherited twin route `/v3/dashboard/exportStockUnitRecord` | **YES (no edit)** — both gate pins must stay green | P3 |
| 13 | `src/main/java/net/aim_ai/wms/controller/AdminController.java` — `protected static Long toFilterId(String raw)` | shared filter normaliser | **YES (no edit)** — reused on the MVC export path (§3.6) | P3 |
| 14 | `src/main/java/net/aim_ai/wms/service/StockrecordService.java` — `public Map<String, Object> getStockRecordDetails(Long id)` … `details.put("clientNumber", client.getClNr()); details.put("clientName", client.getName());` — no item name | service method | **YES** — add `itemName` | P4 |
| 15 | `src/main/java/net/aim_ai/wms/repo/jpa/ItemdataRepository.java` — `Optional<Itemdata> findByClientIdAndItemNr(@Param("clientId") Long clientId, @Param("itemNr") String itemNr);` | existing finder | **YES (no edit)** — reused by #14; no new finder needed | P4 |
| 16 | `src/main/java/net/aim_ai/wms/controller/StockRecordController.java` — `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_RECORD)` / `@GetMapping(path= "/stockRecordDetailsById/{id}")` | gated MVC endpoint | **YES (no edit)** — carries #14's new field | P4 |
| 17 | `src/main/java/net/aim_ai/wms/controller/ClientController.java` — `@RequiresFunction({WmsConstants.FunctionEnum.WEB_UI_VIEW_CLIENT, … WEB_UI_VIEW_LOCATION_OVERVIEW})` on `@GetMapping(path = "/allClients")` — `WEB_UI_VIEW_STOCK_UNIT_RECORD` is absent | ANY-of function gate | **YES** — latent empty dropdown (§3.8) | P5 |
| 18 | `src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` — `row("ClientController", "/v3/client/allClients", "WEB_UI_VIEW_CLIENT", …);` | gate pin | **YES** — must change in the same commit as #17 | P5 |
| 19 | `src/main/java/net/aim_ai/wms/controller/StockUnitController.java` — `@RequiresFunction({…WEB_UI_VIEW_STOCK_UNIT, …WEB_UI_VIEW_CONTAINER})` / `@GetMapping(path = "/detailView")` / `@RequestParam(value = "clientId", required = false) String clientId` … `dtoViewService.getStockUnitViewByKeyword(keyword, toFilterId(clientId), toFilterId(itemdataId), p)` | **REFERENCE — the API half of the established convention** | The sibling takes `clientId` as a **String** `@RequestParam` and folds it with `toFilterId`. This is why Q1's "diverges from the six siblings" cost is wrong (§10.1) | — |
| 20 | `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` — `AND (COALESCE(CAST(:clientId AS BIGINT), -1) = -1 OR c.id = CAST(:clientId AS BIGINT))`, `@RestResource(… exported = false)` | **REFERENCE — DO NOT COPY THE PREDICATE SHAPE** | The convention's *parameter* is right and is adopted; its *predicate* carries the generic-plan hazard measured in §3.4 and must not be ported onto a 9.7 M-row table | — |
| 21 | `src/test/java/net/aim_ai/wms/unit/service/ReportServiceUnitTest.java` — **four** `when(stockrecordRepository.findByOffsetAndLimit(any(), anyInt(), anyInt()))` **stubs** (≈ lines 439/470/484/515) | existing stubs | **YES — the STUBS need no edit**, because `findByOffsetAndLimit` keeps its signature under the split. ⚠ **This is true of the stubs and FALSE of the files.** `ReportService.exportStockUnitRecord` gains `Long clientId` (row 9), and every existing call site of it is four-argument and will not compile. Enumerated by `git grep -n '\.exportStockUnitRecord(' origin/develop -- src/test`: **11 sites in 2 files** — `ReportServiceUnitTest` **4** (act lines 443/474/488/522, one inside `assertThatThrownBy`) and `ReportControllerUnitTest` **7** (387/395/407/415/428/436/452 — four `doNothing()/doThrow().when(...)` and three `verify(...)`). A third file, `ReportReadGateUnitTest`, references the route *string* `"/exportStockUnitRecord"` only and does not break. Harmless — it announces itself in seconds — but P3 must budget for it | P3 |
| 22 | `src/test/java/net/aim_ai/wms/unit/config/EntityColumnNameResolutionArchTest.java` — *"Every persistent field of a JPA-mapped class … must either carry an explicit `@Column(name = …)` … or have a Java name that contains no uppercase letter"*, importing `net.aim_ai.wms.model` wholesale | existing repo-wide rail | **YES (no edit)** — it picks up `StockrecordView` automatically, in **surefire**, before any IT. Changes what §7.8's column mutant can attribute (§7.8) | P2 |

**Out of scope, and why.** Writes stay
on the table entity because the view is read-only: `StockrecordService` — `Stockrecord rec = new Stockrecord();`
(7 sites), `StockunitBusinessService` — `Stockrecord stockrecord = new Stockrecord();`, and
`FixLocationAssignmentService` — `stockrecordService.recordRelocation(su, oldLocation, destination, …)`. Two
existing `StockrecordRepository` natives are unaffected: `findAdjustmentAlerts`, which already carries
`"FROM stockrecord sr JOIN client c ON sr.client_id = c.id "` itself, and the PL/pgSQL wrappers
`transactionDetailByClientNumberAndSkuBetweenDates` / `transactionSummaryByClientNumberBetweenDates`, both
`nativeQuery` + `@RestResource(exported = false)`, which call functions rather than the table.
`SdrFunctionRules` (`rules.put(net.aim_ai.wms.model.User.class, USER_ADMIN_VIEW);`, 7 rules, none for
`Stockrecord` or `StockView`) is deliberately **not** edited — the reasoning is §3.5.

### 0.2 `v2/wms2-web-ui`

| # | File + quoted snippet | Construct | In scope? | Phase |
|---|---|---|---|---|
| 25 | `components/reports/stockUnitRecord.vue` — the header block `<div class="mt-1 d-flex justify-end">` … `<v-btn tile icon depressed title="Export" @click="openExport">` — **there is no shipper widget in this file at all** | template | **YES** — add the **`<v-autocomplete clearable>`** (AC-1, §3.9) | P6 |
| 26 | `components/reports/stockUnitRecord.vue` — `<v-data-table id="reportsStockUnitRecordTable" :headers="headers" :items="items" …>` | template | **YES** — SKU Name column lands in `headers` | P6 |
| 27 | `components/reports/stockUnitRecord.vue` — `headers: [ { text: 'SKU ID', align: 'start', sortable: true, value: 'itemdata', class: 'py-3' }, …]` | `data()` header array | **YES** — insert `{ text: 'SKU Name', value: 'itemName', sortable: false }` (Q4) | P6 |
| 28 | `components/reports/stockUnitRecord.vue` — `<export-report :show="showExport" :reportType="reportType" @close="closeExport" />` — no `:filter` | template | **YES** — add **`:filter="String(shipper == null ? -1 : shipper)"`** (AC-2). The `String(...)` is load-bearing, not stylistic: without it `0` (System-Client) is eaten by `exportReport.vue`'s truthiness guard and the export silently returns every shipper (§3.6, with the executed truth table) | P6 |
| 29 | `components/reports/stockUnitRecord.vue` — `:exclude-fields="['id', 'version']"` and `:field-names="{ … 'clientName': 'Shipper Name', 'clientNumber': 'Shipper Code', }"` | `<full-details>` props | **YES** — add `'itemName': 'SKU Name'` (AC-3 popup half) | P6 |
| 30 | `components/reports/stockUnitRecord.vue` — `async updateTable() { … await this.$store.dispatch('reports/stockUnit/searchReport', { page, itemsPerPage, keyword: this.keyword, sortUrl })` | method | **YES** — must also pass `clientId` | P6 |
| 31 | `components/reports/stockUnitRecord.vue` — `data() { return { keyword: '', options: {}, … } }` and `mixins: [SearchUrlSync]` | component state | **YES** — the shipper must be a **computed**, not a `data()` key (§3.9, `searchUrlSync` trap) | P6 |
| 32 | `store/reports/stockUnit.js` — `const urlPart = '?page=' + (data.page - 1) + '&size=' + data.itemsPerPage + '&state=' + data.state + '&keyword=' + data.keyword + (data.sortUrl ? '&sort=' + data.sortUrl : '')` … `$get('/stockrecord/search/findByKeyword' + urlPart)` … `results._embedded.stockrecord` | Vuex action | **YES** — new path, new `_embedded` key, new `clientId` param | P6 |
| 33 | `store/reports/stockUnit.js` — `export const state = () => ({ pagination: {…}, reportItems: [], list: { search: '', sortBy: [], sortDesc: [] } })` — no `shippers`, no `shipperFilter` | Vuex state | **YES** — mirror `store/reports/inventory.js` | P6 |
| 34 | `store/reports/stockUnit.js` — `async export(context, params) { … const exportData = { ...params.data, keyword: context.state.list?.search \|\| '' }; … $post('/report/exportStockUnitRecord', exportData, …) }` | Vuex action | **NO EDIT** — `params.data` already carries `filter` (§3.6) | — |
| 35 | `components/reports/popups/exportReport.vue` — `props: ['show', 'reportType', 'filter', 'includeShipped'],` and `filter: this.filter && this.filter != 'All Shippers' ? this.filter : null,` | shared request-body build | **NO EDIT — but it is a truthiness guard, and this ticket would be the first to hand it a NUMBER.** Row 28's binding sends a **String** instead, so the guard never sees a number (§3.6). Derived: 9 components mount `<export-report>`; the 7 that pass `:filter="shipper"` all use `item-value="clNr"`, i.e. a String, so none of them can currently reach the falsy-`0` branch with a real id | — |
| 36 | `mixins/searchUrlSync.js` — `const possibleProps = ['search', 'keyword', 'filter', 'searchText', 'query', 'searchQuery'];` | mixin constraint | **CONSTRAINT** — §3.9 | P6 |
| 37 | `components/handlingUnits/stockUnitsTable.vue` — `<v-autocomplete id="filterShipper" item-value="id" v-model="selectedShipper" :items="shipperList" :clearable …>` and, at the dispatch site, `clientId: this.selectedShipper == null ? -1 : this.selectedShipper,` under the comment *"`== null ? -1 :`, never `\|\| -1`. Client id 0 is a REAL shipper — 'System-Client' … it would map it onto the "no filter" sentinel and show every shipper's rows"* | **PRIMARY REFERENCE (SBDEV-2976 Gap 2 — the sibling half of this ticket's parent)** | **REFERENCE — copy the folding rule and the widget decision** (§3.9). It also carries the *"DELIBERATE DIVERGENCE"* note on sentinel-row-plus-truthiness | — |
| 38 | `components/handlingUnits/containerTable.vue` — `clientId: this.selectedShipper == null ? -1 : this.selectedShipper,` under the short form of the same comment | **PRIMARY REFERENCE** | **REFERENCE** — the second copy of the rule, at its own dispatch site | — |
| 39 | `store/handlingUnits/stockUnits.js` — `setFilters(state, payload) { state.list = Object.assign({}, state.list, { clientId: payload.clientId ?? -1, … }) }` (*"merge rather than replace"*), `resetList` resetting `clientId: -1` (*"omitting them would leave the grid filtered with an empty toolbar"*), and `urlPart += '&clientId=' + (context.state.list.clientId ?? -1)` appended for **both** branches *"from state rather than from `data`"* | **PRIMARY REFERENCE** | **REFERENCE — copy the merge-not-replace mutation and the from-state append** (§3.9) | — |
| 40 | `store/handlingUnits/container.js` — the same three constructs (`clientId: -1` initial state, `?? -1` merge, from-state append) | **PRIMARY REFERENCE** | **REFERENCE** | — |
| 41 | `components/reports/inventoryReport.vue` — `<v-select … item-value="clNr" v-model="shipper" id="shipper" …>`, the Vuex-backed `shipper` computed, the `'$store.state.admin.client.clients'()` watcher building `[{ name: null, label: 'All Shippers' }, …]`, and the `getClients` dispatch inside the `options` deep watcher | secondary reference | **REFERENCE — the older `clNr` shape, rejected by Q1.** Copy only the *Vuex-backed computed* idiom; the sentinel row, the `item-value` and the store guard are all re-derived from rows 37–40 instead | — |
| 42 | `store/reports/inventory.js` — `if (data.clientNumber != null & data.clientNumber !== 'All Shippers') { urlPart += '&clientNumber=' + data.clientNumber }` | secondary reference | **REFERENCE — DO NOT COPY VERBATIM** (§3.9, two defects) | — |
| 43 | `store/admin/client.js` — `const urlPart = '/allClients'; … $get('/client' + urlPart) … context.commit('setClients', results.content)` | shared dropdown source | **NO EDIT** | — |
| 44 | `store/internalOps/cycleCount.js` — `if (data.clientId) { … }` | **truthiness guard on `clientId`, on another screen** | **NO — out of scope, but it is the same defect class as C-1**: a selected `System-Client` (`id = 0`) is dropped from the Cycle Count filter. Proposed in §10.4, not filed | — |
| 45 | `components/reports/{flowbin,inventory,lock,outboundParcel,parcelPicking,receiving,skuLocation}Report.vue` (**seven** files) plus `components/handlingUnits/{containerTable,stockUnitsTable}.vue`, `components/internalOps/cycleCount/{closed/closedCycleCount,planned/plannedCycleCount,planned/create/createCycleCount}.vue`, `components/internalOps/replenishment/{closed/closedReplenishmentRequests,open/openRequest}.vue`, `components/receiving/open/create/createPurchaseOrder.vue` — every `admin/client/getClients` dispatcher (**26 sites in 15 files**, repo-wide `git grep`, one commented out) | the full dropdown population | **NO EDIT** — but this is the set §3.8's invariant is derived over | — |

**Blind spots of this enumeration.** The grep-based method above **cannot see**: (a) reflective or
string-built references, e.g. a repository path assembled at runtime; (b) files `.gitignore`d out of the
working tree — mitigated by using `git grep` throughout, but not eliminated; (c) binary files, since the
local `grep` is `ugrep` and skips them silently without `-a` — no binary file is believed relevant, which is
an assumption and not a measurement; (d) anything on an unmerged branch. Rows 1–4 are new files and so have
no "existing sites" to miss.

---

## 1. Problem Statement

**Screen:** wms2-web-ui → Reports → **Stock Unit Record** (`components/reports/stockUnitRecord.vue`,
`<v-card-title class="pa-0">Stock Unit Record</v-card-title>`).

Two gaps, split out of SBDEV-2976 Gap 1:

1. **No Shipper / Brand filter.** **Seven** sibling reports (Flowbin, Inventory, Lock, Outbound Parcel, Parcel
   Picking, Receiving, SKU Location — seven names, seven files, by the `getClients` grep in §0 row 45) carry a
   shipper dropdown, and so do eight non-report screens. ⚠ **Seven, not six** — "six" is
   `Sbdev3017TrancheGateContextTest`'s stale in-source comment, the same rotting enumeration §3.8 restates as
   a rule. Count from the grep, not from that comment.
   Stock Unit Record does not: the file contains no `<v-select>` at all. On a tenant the size of
   `dev_wh01_om1` the report is a flat 9,726,795-row audit log with keyword search as the only narrowing
   tool, and the keyword matches only `activitycode`, `fromstoragelocation`, `fromunitload`, `itemdata`,
   `operator` (the five columns named in `StockrecordRepository.findByKeyword`'s `CONCAT(...)`).
2. **No product name.** The table shows `SKU ID` (`value: 'itemdata'`, a SKU *string*) but never the
   product's name, and the details popup does not carry it either. `StockrecordService.getStockRecordDetails`
   issues **22 unconditional `details.put(...)` calls plus two more —
   `details.put("clientNumber", client.getClNr()); details.put("clientName", client.getName());` — inside
   `if (s.getClientId() != null)`**, so the map is 24 keys when the client resolves and 22 when it does not.
   Nothing in it comes from `itemdata`. (22 is the count **without** the two conditional keys; "a 22-key map
   that includes `clientNumber` and `clientName`" is self-contradictory and appears in older notes.)

### Acceptance criteria

Each states the assertion a test makes. `wms-tdd-gate` writes the failing tests
from this table, so an AC that does not name a wire contract or a value cannot be encoded — it becomes an
assertion against whatever shape the implementer happened to choose, which is not a test.

| AC | Statement (assertion form) |
|---|---|
| **AC-1** | The report renders a Shipper / Brand **`<v-autocomplete clearable>`** with `id="shipper"` whose items come from `admin/client/getClients` and contain **no `{ id: null, label: 'All Shippers' }` sentinel row** — clearing the field *is* "All Shippers" (§3.9, decided by Nam 2026-09-18). Type-ahead narrows on `item-text` (`name (clNr)`), so a fragment of either the shipper name or its `cl_nr` matches and nothing matches on `id`. **Wire contract — it grades the ROUTE as well as the parameter, because §3.4 splits the query into two methods:** selecting the shipper whose `id` is *N* targets **`/stockrecordView/search/findByKeywordAndClient`** and carries **`&clientId=N`** (never `null`, never `''`); with "All Shippers" selected the request targets **`/stockrecordView/search/findByKeyword`** and carries **no `clientId` at all**. The response row set is exactly the rows whose `client_id` is *N*. <br>⚠ The parameter is *absent* on the unfiltered branch **by design**: the unfiltered repository method has no `clientId` parameter, so appending `&clientId=-1` there would be an inert string SDR discards, and an assertion on it would grade nothing. The `-1` sentinel still exists — it lives in the store's state and on the **export** body (AC-2), not on the unfiltered read URL. |
| **AC-2** | The export request body's `filter` key reaches `StockrecordRepository` as a `Long`, and the spreadsheet contains exactly the selected shipper's rows. Graded by this matrix, which is the test's parameter list: <br>• key absent → all shippers • JSON `null` → all shippers • `-1` → all shippers • `""` or `"abc"` → all shippers • `60500` (a JSON **number**) → ARW only, **no throw** • **`0` → System-Client only, NOT all shippers**. <br>⚠ The UI sends these as **Strings** (`String(shipper == null ? -1 : shipper)`, §3.6), so the `0` case arrives as `"0"` and the All-Shippers case as `"-1"`; the matrix above is on `toFilterId`'s **output**, which is what the service branches on, and it is unchanged by the type. <br>The 15 export columns and their order are byte-identical to today's (Q2: *filter only*). |
| **AC-3** | `wrapper.vm.headers.map(h => h.value)` contains `'itemName'` with `sortable: false`, and `getStockRecordDetails` returns a map containing `itemName` when the SKU string resolves. **When it does not resolve, the key is ABSENT from the map** (`assertThat(details).doesNotContainKey("itemName")`, not `get() == null`) **and the row still appears in the table** — that second clause is what makes the `LEFT`-not-`INNER` decision an acceptance criterion rather than an implementation detail. |
| **AC-4** | With `clientId=60500` and `keyword=''`: `page.totalElements` equals `SELECT count(*) FROM stockrecord WHERE client_id = 60500` — **not the unfiltered count**. (The realistic regression is not that sorting stops working; it is that the filter reaches the page query but not the count query, so the grid shows 10 ARW rows under a footer reading 9,726,795.) The four combinations to encode, named so two implementers write the same test: **(a)** filter alone; **(b)** filter + non-empty keyword; **(c)** filter + `sort=created,asc`, asserting the first row's `created` is the minimum of the filtered set; **(d)** filter + `page=1`, asserting page 2's ids are disjoint from page 1's under the same filter. Each asserts rows **and** `totalElements`. |

### Why this is T3

Flyway migration (irreversible on a tenant once applied) · a new domain type exposed through Spring Data
REST (an externally-visible route) · an authorization-gate widening. Each is an independent T3 trigger under
`wms-triage`'s router.

---

## 2. Current Architecture

### 2.1 The table read — Spring Data REST, no controller

```
stockUnitRecord.vue  updateTable()
  → store/reports/stockUnit.js  searchReport()
      '?page=' + (data.page - 1) + '&size=' + data.itemsPerPage + '&state=' + data.state
      + '&keyword=' + data.keyword + (data.sortUrl ? '&sort=' + data.sortUrl : '')
  → GET /api/stockrecord/search/findByKeyword
  → StockrecordRepository.findByKeyword  (JPQL, Page<Stockrecord>)
  ← results._embedded.stockrecord, results.page.totalElements
```

There is **no MVC controller on this path** — Spring Data REST dispatches the query-string parameters
straight onto the repository method's `@Param`s. One consequence, carried into §3.4 and §3.9:
`AdminController.toFilterId` is unreachable here, because it is a `protected static` method of a controller
base class. The sentinel fold therefore has to happen somewhere other than a controller — and **not** in the
predicate, which is where §3.4 measures it as non-indexable. It happens in the **store**, which picks between
two repository methods.

`findByKeyword`'s predicate carries **no** empty-keyword escape, where its sibling
`StockViewRepository.findByKeyword` does (`" … LIKE LOWER(concat('%', :keyword,'%')) or :keyword = ''"`):

```java
@Query("SELECT p FROM Stockrecord p WHERE CONCAT(LOWER(p.activitycode), ' ', LOWER(p.fromstoragelocation), ' ', LOWER(p.fromunitload), ' ', LOWER(p.itemdata), ' ', LOWER(p.operator)) LIKE LOWER(concat('%', :keyword,'%'))")
```

Observed oddity, **not in scope**: `searchReport` appends `'&state=' + data.state` but no caller passes
`state`, so the request carries the literal `&state=undefined`. SDR ignores unknown query parameters, so it
is inert. Noted so a reviewer does not read it as new.

### 2.2 The export — MVC, a fully disjoint path

The export is a different transport (`POST /v3/report/exportStockUnitRecord`, MVC), a different repository
method (`findByOffsetAndLimit` — `nativeQuery`, `List<Stockrecord>`, hard-coded `order by p.created DESC`,
`offset :offset limit :limit`), and a different keyword contract: the export **has** the `or :keyword = ''`
escape the table read lacks. Two consequences. First, any test asserting "export output == table output" will
chase a phantom — the keyword semantics already differ today. Second, unlike the SDR read the export **is**
function-gated: `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_RECORD)`.

`DashboardController extends ReportController`, so the same method also serves
`/v3/dashboard/exportStockUnitRecord`. `Sbdev3017TrancheGateContextTest` pins both, and its javadoc says why:
*"The web UI never calls the /v3/dashboard export twins, so no UI test can catch that — only these rows can."*

```java
row("ReportController",    "/v3/report/exportStockUnitRecord",       "WEB_UI_VIEW_STOCK_UNIT_RECORD");
row("ReportController",    "/v3/dashboard/exportStockUnitRecord",    "WEB_UI_VIEW_STOCK_UNIT_RECORD");
```

### 2.3 The details popup

`stockUnitRecord.vue` → `showDetails(item)` → `GET /stockrecord/stockRecordDetailsById/${data.id}` →
`StockRecordController.stockRecordDetailsById` (gated `WEB_UI_VIEW_STOCK_UNIT_RECORD`) →
`StockrecordService.getStockRecordDetails(id)`, which resolves the `Client` by `s.getClientId()` and puts
`clientNumber` / `clientName` into the map. **Nothing resolves `itemdata`.**

### 2.4 The precedent: `stock_view` / `StockView`

The Inventory report already solves the same shape, and every structural decision in §3.1–§3.5 is copied from
it or deliberately diverges from it.

`stock_view` is defined in the base dump `V2.2.00__base_v2_schema.sql`, split by `pg_dump` into a column-shape
placeholder (`CREATE VIEW public.stock_view AS SELECT NULL::bigint AS row_id, …`) with the real body emitted
later as a `RULE`. **That split is a dump artefact and must not be imitated.**

`StockView.java` maps it standing alone — **not** extending `AbstractBaseEntity`, with its own
`equals`/`hashCode` on `rowId`:

```java
@Entity
@Table(name = "stock_view")
public class StockView {
    @Id
    @Column(name = "row_id")
    private Long rowId;
```

`StockViewRepository` supplies two things this plan copies — `ReadOnlyPagingAndSortingRepository` and the
suppression of **all three** `findAll` overloads, with the reason in-source (*"Per critic M3, all three
overloads must be suppressed — omitting findAll(Sort) leaves a sorted-by-default bypass."*) — and two it
**rejects**: its filter column `p.clNr` (Q1 — §3.4 measures the joined column at 4,090 ms against 987 ms for
`client_id`) and its three-valued `AND (p.clNr = :clientNumber OR :clientNumber IS NULL OR :clientNumber = '')`
predicate (§3.4 measures that shape as non-indexable under a generic plan).

**Correction to a widely-held premise:** neither `V2.2.07` nor `V2.2.08` patches `stock_view` — `V2.2.07`
replaces the *function* `stock_history(timestamptz)` which *reads* it, and `V2.2.08` only mentions it in a
comment. The actual view-migration precedent, derived by
`git grep -n 'CREATE OR REPLACE VIEW\|CREATE VIEW' origin/develop -- src/main/resources/db/migration/`
excluding the `V2.2.00` base dump, is **three statements in two files**: `V2.2.01` (one) and `V2.2.02` (two).
`V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql` is the file to read before writing
`V2.2.33`. **Copy its shape, not its naming-strategy claim** — its header contains a known-false sentence
(*"Hibernate resolves it to column `ro_id` via CamelCaseToUnderscoresNamingStrategy"*) left deliberately
unedited because Flyway's CRC32 covers comments; the retraction lives only in
`ReplenishmentMonitorViewSchemaIT`'s javadoc, and is §3.3 of this plan.

---

## 3. Design

### 3.1 `V2.2.33` — the `stockrecord_view` DB VIEW

A PostgreSQL view projecting every `stockrecord` column unchanged, plus `item_id`/`item_name` from
`itemdata` and `cl_nr`/`cl_name` from `client`.

**The five load-bearing arguments — pair join key, both joins `LEFT`, join elimination, do-not-widen-the-
keyword, strict-superset column set — are stated once, in the header of
`SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql`, which is the artefact that ships and the one a future
reader will be standing in front of.** Three things belong here rather than
there, because they are about the plan rather than about the migration:

- **The measurement that proves elimination**, so a reviewer can re-run it:
  ```
  Finalize Aggregate
     ->  Gather  (Workers Planned: 4)
           ->  Partial Aggregate
                 ->  Parallel Seq Scan on stockrecord sr  (actual rows=1945359 loops=5)
  ```
  7,356 / 7,647 ms over the probe view against 7,288 / 7,261 ms directly on the table (+1% to +5%, inside
  run-to-run noise on a shared dev box). Both joins absent from the plan.
- **The zero that licenses `LEFT`, with its control.** 0 of 9,726,795 rows fail to resolve a SKU; control —
  the same query with the predicate poisoned to `i.item_nr = sr.itemdata || '_NOPE'` returns 9,726,795, so
  the instrument reports non-matches. An `INNER JOIN` would therefore look correct in every test against
  real data, which is the reason it must not be used.
- ⚠ **Row-count invariance is a property of each tenant's schema, not of the view text.** The header asserts
  it flatly; what actually guarantees it is `itemdata`'s `UNIQUE (client_id, item_nr)`, declared only in
  `V2.2.00__base_v2_schema.sql` — `ADD CONSTRAINT uk3l3dgof3l6mc1dl7s3lmida65 UNIQUE (client_id, item_nr);` —
  the base dump that legacy tenants were **baselined past rather than ran**. Nothing in `V2.2.33` creates or
  asserts it, and making the view defend itself (`DISTINCT ON`, `LATERAL … LIMIT 1`) is exactly what would
  destroy the elimination, because the planner's proof of non-multiplication *is* the constraint. You cannot
  have both. This plan takes the elimination and **adds a third statement to `V2.2.33` that turns the silent
  cliff into a loud migration failure** (below). The failure mode if the constraint is ever absent **and** a
  duplicate pair exists is not visible duplicate rows: with `@Id` on `stockrecord.id`, Hibernate deduplicates
  by identifier inside the persistence context, so `content` comes back with the same instance repeated while
  `page.totalElements` — from a `count(*)` that does not dedupe — reports the inflated figure. A grid whose
  footer disagrees with its rows reads as a UI bug, not as a lost constraint.

⚠ **The two numbers in the header are different quantities, and one of them is CRC-locked.** 8,808 `itemdata`
rows carry 8,721 distinct `item_nr` values, so `8,808 − 8,721 = 87` is the **excess row count**, not a count of
strings. Measured 2026-09-18 on `dev_wh01_om1`, **71** `item_nr` strings are shared between shippers
(`SELECT count(*) FROM (SELECT item_nr FROM itemdata GROUP BY item_nr HAVING count(*) > 1) d` → 71; `sum(c-1)`
over those groups → 87). The migration file's header therefore says **71 strings / 87 excess
rows**, and it must be proof-read before the first apply: Flyway's CRC32 covers comments, so once `V2.2.33`
runs on any tenant the sentence cannot be corrected without a new migration file.

**Draft SQL** — header modelled on `V2.2.32`'s prose-WHY style and `V2.2.01`'s `Row-count invariance:`
obligation; Flyway wraps each script in a transaction and DDL is transactional on PostgreSQL, so no explicit
`BEGIN`/`COMMIT`.

**The SQL is a FILE, not a fence: `SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql`.** P1 copies it
to `src/main/resources/db/migration/V2.2.33__stockrecord_view.sql` rather than retyping it. It holds all
three statements in order — the `CREATE OR REPLACE VIEW` with the five-argument header above, the companion
index of §3.2, and the constraint assertion below — and it carries the proof-read warning at the top,
because **Flyway's CRC32 covers comments**: once the script applies on any tenant the header's numbers
(71 shared `item_nr` strings / 87 excess rows) cannot be corrected without a new migration file.

**Third statement — assert the constraint the view depends on.** The existing protections
for row-count invariance are an SQL comment, a Testcontainers `viewMultipliesZeroRows` IT and a mutation
check. The latter two run against a schema **built by `db/migration`**, where `V2.2.00` *did* create the
constraint — so they prove the property on the migration-built schema and are structurally blind to a tenant
that was baselined past `V2.2.00`. No per-tenant instrument exists. This one runs on the tenant.

The statement itself is the third one in `SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql`. It is a `DO $$`
block matching on the **column set** (`conkey` over `client_id`,`item_nr`) rather than on the generated
constraint name `uk3l3dgof3l6mc1dl7s3lmida65` — a tenant rebuilt by a different Hibernate run carries a
different generated name, and a name match would fail a tenant that is in fact correct.

Two consequences worth stating: a failed **tenant** Flyway migration does not abort the boot, so this makes
the failure loud in the Flyway history but **not** in a health probe — prereq 8's per-tenant check still has
to be run; and it documents the dependency at the one place a future reader of the view will be standing.
Measured 2026-09-18, the constraint is present as `UNIQUE (client_id, item_nr)` and is `itemdata`'s **only**
unique constraint (`pg_constraint … contype = 'u'` returns exactly 1 row) on `dev_wh01_om1` and on hydra prd;
the architect lane independently found the matching unique index on all 5 MCP-reachable DBs. Blind spot: five
databases is not the tenant population (§5.1 prereq 1), and a constraint present today can be dropped
tomorrow.

⚠ **The migration file's header states the guarantee's expiry, because this statement is a migration-time
gate and nothing else is.** It fires once, when `V2.2.33` applies on that tenant. A constraint dropped *after* that is
undetected: `ddl-auto=none` means nothing validates it at boot, prereq 8's `pg_constraint` check is a one-time
post-deploy action rather than a standing detector, and making the view defend itself (`DISTINCT ON`,
`LATERAL … LIMIT 1`) is exactly what would destroy the join elimination the feature rests on. That residual is
inherent to taking the elimination; it is not a gap to close, but a future reader must not read the `DO $$`
block as a standing invariant.

### 3.2 The companion index — inside `V2.2.33`, second statement

**This is not optional.** Measured, the shipper filter makes the first page **300–900× slower** than not
applying it, because `ORDER BY created DESC LIMIT 10` with a `client_id` predicate walks
`index_stockrecord_created` backwards discarding every other shipper's rows:

| case | plan | time |
|---|---|---|
| unfiltered first page | `Limit` → `Index Scan Backward using index_stockrecord_created`, 10 rows | **5.1 / 6.6 ms** |
| `client_id = 60500` (ARW, 873k rows, newest 2023-08-14) | same shape, skipping every other shipper | **4,709 / 1,531 ms** |
| `client_id = 419803` (C24, 4,366 rows, newest 2022-03-17) — worst case | `Rows Removed by Filter: 7,564,825` | **2,865 / 1,987 ms** |

With the composite index (built in a rolled-back transaction: **6.3 s**, **276 MB**), the worst case becomes
`Index Scan Backward`, `Index Cond: (client_id = 419803)`, **0.455 ms** — a 6,300× speed-up; ARW becomes
0.350 ms. The index also turns the `itemdata` lookup into
`Index Cond: ((client_id = 419803) AND ((item_nr)::text = (sr.itemdata)::text))`, a 10-loop unique probe at
0.005 ms/loop, so the join genuinely costs nothing on a paged read.

⚠ **What plan mode that 0.455 ms belongs to, and what it does NOT license.** It was measured with a
**literal** predicate and the index present. Under a **generic** plan the predicate's *shape* decides whether
any `client_id` index is reachable at all, and the three-valued `OR` §3.4 originally specified is not
reachable. §3.4 therefore uses a plain equality. **Both plan modes, measured on the predicate the code
actually issues** — the keyword arm is present in all three rows, because isolating `client_id = $1` would
grade a query no method renders, and the keyword arm contains its own `or :keyword = ''` disjunct whose right
side does not reference the table:

| predicate (bind params, `plan_cache_mode = force_generic_plan`, `dev_wh01_om1`, 2026-09-18) | generic plan |
|---|---|
| `(kwCONCAT LIKE … or $2 = '') AND p.client_id = $1` — **the shipped shape** | `Aggregate → Index Scan using index_stockrecord_client_id`, **`Index Cond: (client_id = $1)`**, keyword arm demoted to `Filter:` |
| `(kw…) AND (p.client_id = $1 OR $1 IS NULL OR $1 = -1)` — the withdrawn 3-arm form | `Finalize Aggregate → Gather → Parallel Seq Scan`, **`Filter: (…)`** — no index |
| `(kw…) AND (COALESCE(CAST($1 AS BIGINT), -1) = -1 OR p.client_id = CAST($1 AS BIGINT))` — the sibling's shape | `Parallel Seq Scan`, **`Filter: (…)`** — no index |
| custom plan, literal, **with** the composite index | `Index Scan Backward`, `Index Cond: (client_id = 419803)`, 0.455 ms |

**The `or :keyword = ''` disjunct does not contaminate the conjunction**, which is the objection this table
would otherwise invite: a top-level `AND` lets the planner take the indexable conjunct as an index qual and
push the rest to `Filter:`. The hazard is specific to a disjunction *at the top level of the `WHERE`*, which
is exactly what the three-valued form introduces and the split removes.

**The export path plans the same way, and it is a different shape.** Measured under `force_generic_plan`,
**without** the composite index, on the proposed `findByClientOffsetAndLimit`:

```
Limit
  ->  Gather Merge  (Workers Planned: 1)
        ->  Sort  (Sort Key: created DESC)
              ->  Parallel Index Scan using index_stockrecord_client_id on stockrecord p
                    Index Cond: (client_id = $2)
                    Filter: ((concat(...) ~~ lower(concat('%', $1, '%'))) OR ($1 = ''::text))
```

`Index Cond` survives, so the split fixes **both** paths. But note the `Sort`: its estimate is `rows=559`
against an actual of up to **873,021** for ARW — a ~1,560× underestimate, because a generic plan cannot use
the literal. `index_stockrecord_client_created` would remove that sort entirely; whether the planner *chooses*
it is decided by that same wrong estimate, and a 559-row sort looks nearly free. **The open question on the
export is index *selection*, not index *reachability*,** and the reasoning above answers only reachability.
P1 closes it by measurement (§5.2).

**Still unmeasured, and P1 must close it:** the composite index's own *generic-plan* timing, because building
a 276 MB index is a mutation this lane would not make and `hypopg` is not installed on the dev server
(`pg_available_extensions` → 0 rows for `hypopg`; control: 61 extensions listed, so the zero is a measurement
and not a broken query). The claim carried forward is the **plan shape**, which is a property of the qual and
not of which index exists: a plain equality on a leading index column is an indexable operator clause whatever
the parameter's value, so the `Index Cond` survives promotion. P1's checklist therefore requires re-running
the `force_generic_plan` `EXPLAIN` on dev **after** the index exists, and recording the result in this
section. Pre-index, the generic-plan filtered first page reproduces the regression exactly —
`Index Scan Backward using index_stockrecord_created`, `Filter: (client_id = $1)`,
`Rows Removed by Filter: 7,564,825`, **1,936 ms** — so the regression is not a custom-plan artefact either.

**The SDR count query is part of the page's cost and was missing from the table above.** Every `Page` SDR
returns costs a `count` as well as the data query. Measured for ARW on `dev_wh01_om1`:
`Index Only Scan using index_stockrecord_client_id`, `Index Cond: (client_id = $1)`, **`Heap Fetches:
873021`**, **1,743 ms** under `force_generic_plan` in this lane; the architect lane measured the parallel
form of the same query at **602 ms**. Two independent runs, 0.6–1.7 s. The composite index does **not** remove
this: it scans the same 873,021 entries from a wider index, and `Heap Fetches: 873021` says the visibility map
is cold, so the count is heap-bound rather than index-bound. Consequence: a filtered page's user-perceived
latency is *sub-millisecond data query + ~0.6–1.7 s of counting* for the largest shipper on dev. §7.7's
expectation is restated accordingly — "well under a second" was not established and is probably false for a
large shipper.

**DDL as decided by Nam (Q3):**

```sql
CREATE INDEX index_stockrecord_client_created ON stockrecord (client_id, created DESC);
```

It is the **second** statement of `SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql`, where it carries its
own header (the 300–900× regression it exists to remove, the 6.3 s / 276 MB build cost, and why it is not
`CONCURRENTLY`: `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, Flyway wraps every script in
one, and this repo has no precedent for Flyway's transactional-control escape).

Two honest notes on that statement, neither of which changes the decision:

- The measurement above was taken with the index declared **without** `DESC` (`(client_id, created)`), which
  PostgreSQL scanned backwards. A btree serves both directions; `created DESC` only changes the scan
  direction label in the plan, not the cost. The measured 0.455 ms carries over.
- ~~The statement is written **without** `IF NOT EXISTS`, exactly as decided.~~ **SUPERSEDED at
  implementation (2026-09-18, code-review finding J-4). The shipped statement CARRIES `IF NOT EXISTS`.**
  The original reasoning stands as far as it goes — `V2.2.32`'s header correctly records that *"Postgres
  checks ownership BEFORE IF NOT EXISTS, so `IF NOT EXISTS` does not make this safe on such a tenant"*, so
  it buys replay-safety and not ownership-safety. What that argument missed is that **replay-safety is
  exactly what is at risk for this particular index.** It is large enough (276 MB / ~6 s on 9.7 M rows)
  that an operator may reasonably pre-build it out of band to avoid the deploy-time `SHARE` lock this
  very section documents as the accepted cost — and a bare `CREATE INDEX` would then fail `42P07` and
  freeze that tenant's Flyway, which is the same failure class §3.1's guard exists to prevent. The
  sibling precedent agrees: **5 of 5** `CREATE INDEX` statements elsewhere in `db/migration` carry
  `IF NOT EXISTS` (derived by `grep -c 'CREATE INDEX' db/migration/*.sql` cross-checked against each
  hit; blind spot — matches the literal, so an index created inside a `DO` block would be missed).
  The divergence is also recorded in the migration's own header so it can never be read as an oversight.

**Accepted cost (Nam, 2026-09-18), per environment.** A plain `CREATE INDEX` takes a
`SHARE` lock, blocking writes to `stockrecord` for the duration of the build, once per tenant, at the deploy
boot that first applies `V2.2.33`. **The ~6 s / 276 MB figure is the DEV number and dev is the largest
database in the estate by a wide margin** — presenting it as what production sees overstates the cost by
three orders of magnitude on the one prd tenant that can be measured. Measured 2026-09-18:

| database | via | host | `stockrecord` rows | heap | relative to dev |
|---|---|---|---|---|---|
| `dev_wh01_om1` | `wms2-wineco-dev` | localhost:25060 | 9,726,795 | 2,196 MB | 1× |
| `wh01_shipitez_v2` (UAT) | `c1wh-shipitez-uat` | 10.0.0.6 | 1,675,111 | 363 MB | ÷5.8 |
| `wh01_hydra_v2` (UAT) | `nywh-hydra-uat` | 10.0.0.6 | 101,758 | 23 MB | ÷96 |
| `wh02_shipitez_v2` (UAT) | `nywh-shipitez-uat` | 10.0.0.6 | 28,196 | 6,656 kB | ÷345 |
| **`wh01_hydra_v2` (PRD)** | all three prd aliases | 172.18.0.3 | **3,373** | **728 kB** | **÷2,884** |
| ShipItEZ prd ×2 | — | — | **unreachable** | — | — |

On hydra prd the build is milliseconds and the index is kilobytes. ⚠ **Instrument blind spot, and it changes
what "accepted" means here:** `nywh-hydra-prd`, `nywh-shipitez-prd` and `c1wh-shipitez-prd` all return
`current_database() = wh01_hydra_v2`, `inet_server_addr() = 172.18.0.3` — **the three prd aliases are the same
database**, so any claim of the form "across prd tenants" made through this MCP set measured hydra three
times. `landlord-prd` lists three active tenant datasources (`hydra/nywh → wh01_hydra_v2`,
`shipitez/c1wh → wh01_shipitez_v2`, `shipitez/nywh → wh02_shipitez_v2`), so **the thing actually being
accepted is a stall on the two unmeasured ShipItEZ prd databases, not on hydra.** Their UAT counterparts
(1.7 M and 28 k rows) are the closest available proxy and neither is near dev's scale. An operator with real
prd credentials should size those two before P1 merges to a prd-bound ladder; this does not block dev or UAT.

### 3.3 `StockrecordView` — the entity

```java
@Entity
@Table(name = "stockrecord_view")
public class StockrecordView {
    @Id
    private Long id;          // = stockrecord.id, the real PK
    …
}
```

Four rules, each with its evidence:

1. **Do NOT copy `StockView`'s synthetic `row_id` `@Id`.** `stock_view` is a `GROUP BY` aggregate with no
   natural key, so its `@Id` is `row_number() OVER ()` — unstable across executions and with no defined
   ordering. `stockrecord_view` is a per-row projection (no `GROUP BY`, no window function) of a table that
   carries a real PK (`"stockrecord_pkey" PRIMARY KEY, btree (id)` from `\d stockrecord` on `dev_wh01_om1`,
   2026-09-18), and §3.1 proves both joins are non-multiplying, so `sr.id` passes through unique.
   **State the condition, not just the conclusion:** `sr.id` is a safe `@Id` *because* neither join
   multiplies, which is `itemdata`'s `UNIQUE (client_id, item_nr)` — the same external object §3.1's third
   migration statement now asserts. If it is ever absent the symptom is **a deduplicated `content` list
   against an inflated `totalElements`**, not a visible duplicate row.
2. **Do NOT extend `AbstractBaseEntity`.** That superclass carries
   `@Id @GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "entity_gen")`, `@Version private
   Integer version;` and `@EntityListeners(AuditingEntityListener.class)` with `@CreatedDate`/`@LastModifiedDate`.
   A `@Version` column invites Hibernate into optimistic-lock bookkeeping on a read-only view, sequence
   generation from `seqentities` is meaningless for a view, and the auditing listener has nothing to audit.
   `StockView` stands alone for the same reason. **Consequence:** `created` and `modified` must be
   re-declared on `StockrecordView` as `LocalDateTime`, and `equals`/`hashCode` written by hand on `id`, in
   the shape `StockView` uses:
   ```java
   @Override
   public boolean equals(Object o) {
       if (this == o) return true;
       if (!(o instanceof StockrecordView other)) return false;
       return getId() != null && getId().equals(other.getId());
   }
   ```
3. **Every camelCase field needs an explicit `@Column(name = "…")`.** The tenant persistence unit gets **no
   naming strategy** (SBDEV-3247); `ReplenishmentMonitorViewSchemaIT`'s javadoc records it: *"Hibernate falls
   back to `PhysicalNamingStrategyStandardImpl` — identity — and an unannotated `roId` resolves to the
   literal column `roId`, which does not exist."* The fields needing an explicit `@Column` are, by
   inspection of the view's column list in §3.1 against the Java names below: `entityLock` → `entity_lock`,
   `clientId` → `client_id`, `itemId` → `item_id`, `itemName` → `item_name`, `clNr` → `cl_nr`,
   `clName` → `cl_name`. The remaining fields are all-lowercase and identity-resolve — which is exactly how
   `Stockrecord` itself works today (it annotates only `entityLock` and `clientId`). **The schema IT in §7.2
   is what proves this, not this paragraph** — a list of names is precisely the kind of prose enumeration
   that rots.
   ⚠ **A repo-wide rail already covers the annotation half, and it runs first.**
   `src/test/java/net/aim_ai/wms/unit/config/EntityColumnNameResolutionArchTest.java` states the rule
   directly — *"Every persistent field of a JPA-mapped class in this codebase must either carry an explicit
   `@Column(name = …)` / `@JoinColumn(name = …)`, or have a Java name that contains no uppercase letter"* —
   and it imports `net.aim_ai.wms.model` wholesale, so `StockrecordView` is picked up **automatically, in
   surefire, before any IT runs**. That changes two things: the new schema IT's justification (§7.5 row 4)
   and what its column mutant can attribute (§7.8).
4. **Field names must match the UI's sort keys.** Spring Data REST passes `&sort=` straight to JPA, and a
   sort on an unmapped property throws `PropertyReferenceException` → HTTP 500, not a graceful fallback. The
   nine `sortable: true` header `value`s in `stockUnitRecord.vue` are `created`, `type`, `activitycode`,
   `itemdata`, `fromstoragelocation`, `tostoragelocation`, `amount`, `amountstock`, `operator` — derived by
   reading the `headers` array; the derivation cannot see a sort key a user types by hand into the URL,
   which is the same blind spot Q4 records. All nine resolve to projected columns, so all nine survive.
   `id` and `version` must also be mapped: the popup's `:exclude-fields="['id', 'version']"` proves the
   payload carries both today.

### 3.4 `StockrecordViewRepository`

**Two search methods, not one three-valued one.** The obvious single method — one `clientId` parameter with
an `OR :clientId IS NULL OR :clientId = -1` arm — makes the 276 MB index of §3.2 **unreachable under a generic
plan**, measured below. The split is what keeps it reachable.

```java
@RepositoryRestResource(collectionResourceRel = "stockrecordView", path = "stockrecordView")
public interface StockrecordViewRepository extends ReadOnlyPagingAndSortingRepository<StockrecordView, Long> {

    /**
     * ONE copy of the keyword clause, concatenated into both searches below. The split in this interface
     * is a filter split, not a search-semantics split: the two methods must always search the same five
     * columns, or the searched column set silently depends on whether a shipper is selected. §3.10 already
     * names the change that would trip it ("widen the keyword search to item_name / cl_name"), and whoever
     * does that will edit one method. One constant removes the failure mode instead of detecting it.
     * Idiom copied from FixLocationAssignmentRepository.REFILL_ELIGIBILITY_FROM_WHERE, which does exactly
     * this for two @Query values in one interface. A String constant is a compile-time constant expression,
     * so the annotation still carries the full folded text -- reflection in
     * StockrecordViewRepositoryQueryShapeUnitTest sees the whole string.
     */
    String KEYWORD_CLAUSE =
        " (CONCAT(LOWER(p.activitycode), ' ', LOWER(p.fromstoragelocation), ' ', LOWER(p.fromunitload), ' ',"
      + " LOWER(p.itemdata), ' ', LOWER(p.operator)) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '')";

    /**
     * Unfiltered ("All Shippers"). No clientId parameter at all -- see findByKeywordAndClient for why
     * this is two methods and not one three-valued one.
     */
    @RestResource(path = "findByKeyword", rel = "findByKeyword")
    @Query("SELECT p FROM StockrecordView p WHERE" + KEYWORD_CLAUSE)
    Page<StockrecordView> findByKeyword(@Param("keyword") String keyword, Pageable p);

    /**
     * Filtered to one shipper. `p.clientId = :clientId` is a PLAIN EQUALITY and must stay one: adding an
     * `OR :clientId IS NULL OR :clientId = -1` arm to save a method makes the whole predicate
     * non-indexable under a generic plan (a disjunct that does not reference the table can be true for
     * any row, so no index condition is derivable), and pgjdbc reaches a generic plan on its own --
     * plan_cache_mode is `auto` and no prepareThreshold is configured, so it promotes to a server-side
     * prepared statement after five executions on a connection. Measured with force_generic_plan on
     * dev_wh01_om1 2026-09-18: `= $1` keeps `Index Cond: (client_id = $1)`; the three-arm OR and the
     * COALESCE two-arm form both fall to a Parallel Seq Scan with a Filter.
     * Same trap, same reasoning, already written down once in FixLocationAssignmentRepository.
     */
    @RestResource(path = "findByKeywordAndClient", rel = "findByKeywordAndClient")
    @Query("SELECT p FROM StockrecordView p WHERE" + KEYWORD_CLAUSE + " AND p.clientId = :clientId")
    Page<StockrecordView> findByKeywordAndClient(@Param("keyword") String keyword,
                                                 @Param("clientId") Long clientId,
                                                 Pageable p);

    // Per critic M3 on StockViewRepository: all three findAll overloads must be suppressed --
    // omitting findAll(Sort) leaves a sorted-by-default bypass. /api/stockrecordView unbounded over
    // 9.7 M rows is an OOM.
    @Override @RestResource(exported = false) Page<StockrecordView> findAll(Pageable p);
    @Override @RestResource(exported = false) Iterable<StockrecordView> findAll(Sort sort);
    @Override @RestResource(exported = false) Iterable<StockrecordView> findAll();
}
```

**One keyword clause, not two — and this is a hazard the split creates.** Both searches must always match the
same five columns. Copied verbatim into two annotations they would not: §3.10 already names the change that
trips it (*"widen the keyword search to `item_name` / `cl_name` … Needs its own design"*), and whoever takes it
will edit one method, producing a grid whose **searched column set depends on whether a shipper is selected** —
shipper-dependent, silent, and invisible to every test in §7.2, none of which compares the two methods against
each other. The `KEYWORD_CLAUSE` constant removes the failure mode rather than detecting it, and the repo
already does exactly this: `FixLocationAssignmentRepository.REFILL_ELIGIBILITY_FROM_WHERE` is a `String`
constant concatenated into two `@Query` values in one interface. It composes with §7.3's reflection assertion:
a `String` constant is a compile-time constant expression, so the annotation in the class file carries the
whole folded text.

**Why two methods — the measurement.** The three-valued form
`AND (p.clientId = :clientId OR :clientId IS NULL OR :clientId = -1)` renders a disjunction two of whose
branches do not reference `stockrecord`. With a **literal** the planner folds those away and the predicate
becomes an ordinary indexable qual; with a **bind parameter under a generic plan** it cannot, and the
disjunction survives whole. Paired control, same table, same session, count form (no `ORDER BY`/`LIMIT` to
confound the choice), `plan_cache_mode = force_generic_plan` on `dev_wh01_om1`, 2026-09-18 — the table is in
§3.2. `index_stockrecord_client_created`, the 276 MB object `V2.2.33` exists to create, is **unreachable** in
that plan mode, and the filtered first page reverts to the 1,936–4,709 ms case the index was bought to avoid.

This is not a hazard invented by a reviewer. `src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java`
already records it for the same reason — *"the 5x buffer win is **custom-plan-only** … Reaching a generic plan
is possible here: `plan_cache_mode` is `auto`, no `prepareThreshold` is configured so pgjdbc promotes to a
server-side prepared statement after five executions on a connection, and `maxLifetime` keeps a connection 30
minutes"* — and it names the fix it could not use, *"Pinning the literal 700 into the anti-joins would
guarantee the index in every plan mode. It is deliberately NOT done here: it would … change the signature of
an SDR-exported search — a contract change."* SBDEV-3410 is new code, so it does not have that constraint: it
can simply declare the two shapes separately, at a cost of one extra method, one `if` in the store and one
extra IT case.

⚠ **This diverges from the sibling convention deliberately, and the divergence is measured.**
`StockunitRepository.getDetailViewByKeyword` (SBDEV-2976 Gap 2, §0 row 20) folds both sentinels into one
method with `AND (COALESCE(CAST(:clientId AS BIGINT), -1) = -1 OR c.id = CAST(:clientId AS BIGINT))`. I
measured that exact shape against `stockrecord` under `force_generic_plan`: **`Parallel Seq Scan`,
`Filter: ((COALESCE($1, '-1'::bigint) = '-1'::integer) OR (client_id = $1))`** — the same loss. The sibling
can afford it because its grid reads `stockunit` (1,627,714 rows on dev) through a five-way join that is
never going to be an index-only scan; `stockrecord` is 9,726,795 rows and the whole feature rests on one
index. **What is adopted from the sibling is the `clientId` parameter and the `-1` sentinel; what is not
adopted is the predicate shape.** Porting that predicate to this table is proposed as a separate follow-up
(§10.4), not done here.

**Where the sentinel is folded, now that the predicate cannot fold it.** `null` and `-1` still both mean "no
filter" on the wire, exactly as `AdminController.toFilterId`'s javadoc requires — but the fold now happens in
the **caller**, in two places, and neither of them may use truthiness (§3.6, C-1):

| path | who folds | how |
|---|---|---|
| table read (P2/P6) | `store/reports/stockUnit.js` | picks `findByKeywordAndClient` when a shipper is selected and `findByKeyword` otherwise: `data.clientId == null \|\| data.clientId === -1` ⇒ unfiltered route. **`== null`, never `!data.clientId`** — `0` is a real shipper |
| export (P3) | `ReportController.exportStockUnitRecord` | `toFilterId(String.valueOf(reqMap.get("filter")))`, then `-1L` ⇒ the unfiltered repository method (§3.6) |

⚠ `toFilterId` remains unreachable on the SDR read path — it is `protected static` on `AdminController` and
SDR has no controller (§2.1). That was true before this revision and is why the fold moved to the store
rather than to the API on that path.

Carried from the `StockView` precedent: the `or :keyword = ''` escape (which `StockrecordRepository.findByKeyword`
lacks — and A2 in the bundle measured that escape as a free ~30% win on the unfiltered count, 4,945/5,031 ms
vs 7,356/7,647 ms, **treated here as a bonus not a guarantee** because it depends on constant folding, which
happens on pgjdbc's custom-plan path but is not guaranteed once it switches to a generic plan after
`prepareThreshold=5`); `ReadOnlyPagingAndSortingRepository`, which suppresses `save`/`saveAll` from both REST
and Swagger (`@Hidden @RestResource(exported = false) @Override <S extends T> S save(S n);`); and the
three-`findAll` suppression.

**Rejected from the precedent: `p.clNr = :clientNumber`.** Nam's Q1 decision. Measured, all three forms
returning the same 873,021 rows for shipper ARW:

| form | plan | time |
|---|---|---|
| `p.cl_nr = 'ARW'` — the `StockView` idiom | serial `Nested Loop`, no parallelism | **4,090 / 4,280 ms** |
| `p.client_id = 60500` | `Parallel Index Scan using index_stockrecord_client_id`, 4 workers | **987 / 943 ms** |
| `p.client_id = (SELECT c2.id FROM client c2 WHERE c2.cl_nr='ARW')` | `InitPlan` + `Parallel Index Scan`, 2 workers | **1,554 / 1,597 ms** |

Root cause, visible in the plan: with the predicate on the joined column the planner cannot propagate
selectivity across the join and estimates `rows=47,082` against an actual `873,021` — an **18×
underestimate** — so it picks a serial nested loop.

**Three-valued semantics — where they now live.** `null` and `-1` both still mean "no filter" on the wire;
`-1` is the repo's existing "All" sentinel (`AdminController.toFilterId`'s javadoc: *"Returning `-1` rather
than `null` keeps a single meaning on the wire for the repository predicates, which treat `-1` as 'no filter'
(the convention `ReplenishorderRepository.getOpenViewByKeyword` already uses)"*). The predicate does **not**
interpret the sentinels — the two callers in the table above do, which is the whole point of the split.
`-1` is safe as a sentinel because no `client.id` is
negative — measured `SELECT count(*) FROM client WHERE id < 0` → **0**, control `WHERE id > 0` → 158, so the
zero is a measurement (blind spot: one tenant; `-1` is also the established sentinel on four other screens).

### 3.5 SDR registration — three lists, two production edits and one test edit

**`exposeIdsFor` — mandatory.** Spring Data REST omits `id` from the HAL body unless the domain type is
listed in `RestConfiguration`'s `config.exposeIdsFor(Advice.class, …, Stockrecord.class, Stockunit.class,
StockView.class, …)`. `stockUnitRecord.vue` does
`this.details = await this.$store.dispatch('reports/stockUnit/getStockUnitDetail', {id: item.id})` →
`/stockrecord/stockRecordDetailsById/${data.id}`. With `id` absent that becomes
`/stockRecordDetailsById/undefined` and the eye icon 400s. `StockView` is in the list; `StockrecordView`
must be added.

**`SDR_WRITE_WITHDRAWN` — REQUIRED, not parity** (stated so a later reviewer cannot trim it
as cosmetic). `ReadOnlyPagingAndSortingRepository` suppresses **exactly two** methods — read in full at
`origin/develop`, 26 lines, no blind spot at that size: `@Hidden @RestResource(exported = false) @Override
<S extends T> S save(S n);` and the matching `saveAll`. It `extends PagingAndSortingRepository<T, ID>,
CrudRepository<T, ID>`, so `deleteById` / `delete` / `deleteAll` stay **exported**. Without the withdrawal,
SDR routes `DELETE /api/stockrecordView/{id}` to a handler that issues a delete against a **view** — an
unruled, ungated route whose best outcome is a 500. `StockView`, another view-backed entity, is already in
the list for exactly this reason, alongside `Stockrecord`.
**The pin must move in the same commit.** `src/test/java/net/aim_ai/wms/security/SdrWriteWithdrawalContextTest.java`
asserts `assertThat(WITHDRAWN).hasSize(49);` over its own literal set and its javadoc claims that set and
`RestConfiguration.SDR_WRITE_WITHDRAWN` are *"IDENTICAL — 49 names, measured by diffing them, zero difference
in either direction."* Adding a 50th name to the production array and none to the test **breaks nothing** —
the test's set stays 49, all 49 still pass, `StockrecordView`'s withdrawal is simply never verified and the
javadoc's "IDENTICAL" becomes false silently. Nothing in the suite catches that, which is why it is an
explicit P2 task (§0 row 6a) rather than something the suite is trusted to enforce.

**`SdrFunctionRules` — deliberately NOT edited, with the justification corrected.** It holds 7 rules (`User`,
`UserFunction`, `UserGroup`, `UserGroupUser`, `UserRole`, `Sysprop`, `Message`), derived by reading the
`rules.put(...)` calls in that file. Neither `Stockrecord` nor `StockView` has one, so both are "unruled" and
allowed at `ENFORCE_RULED` — `/api/stockrecord/search/findByKeyword` is served to any authenticated user
today, while `/v3/report/exportStockUnitRecord` requires `WEB_UI_VIEW_STOCK_UNIT_RECORD`.
⚠ **"Preserves the asymmetry exactly" is true of the rule COUNT and false of the DATA.**
7 rules before, 7 after — but the existing unruled route serves `stockrecord` columns only, and the new
unruled route additionally serves `item_name`, `cl_nr` and `cl_name` to the same audience. Any authenticated
user gains an unruled, paged, keyword-searchable join of the product catalogue and the client directory onto
the audit log. Small, but a widening, and it lands in the same ticket that widens `allClients` under a gate.
The accurate claim, which is still a decision to defer rather than a reason to act: **it adds no new
*enforcement* gap, because SDR read enforcement is OFF everywhere it has been measured** —
`SdrFunctionRules.java` carries *"⚠ MEASURED 2026-09-03: WMS2_SDR_READ_GUARD_MODE is OFF on both
dev_wh01_om1 and hydra prd"*, so a rule added today would buy nothing live — **and the rule belongs on the
SBDEV-3222/3183 SDR-rules programme's ticket, not this one.** Per the standing ticket policy this sub-T3
finding goes as a note on SBDEV-3410 itself. Expected side effect, not a regression: the counter
`wms2.authz.sdr.unruled{domainType=...}` (`SdrFunctionGuard.METRIC_SDR_UNRULED`) starts emitting a new label
value.

**Which SDR rails a new exported type does and does not trip** (tabulated because a reviewer who
assumes "a new SDR type breaks the inventory tests" wastes a cycle, and one who assumes the opposite ships an
unverified withdrawal). Derived by reading each test's assertions at `origin/develop`:

| rail | breaks on a new exported type? | why |
|---|---|---|
| `SdrRuleInventoryContextTest` | **No** | deliberately not a ratchet — *"The assertion is only that Slice 1 did not accidentally rule everything or nothing"*, `isNotEmpty()` |
| `SdrSurfaceInventoryContextTest` | **No** | asserts only `resources > 20` |
| `SdrSearchParameterConversionContextTest` | **No** | scoped to `Pickingorder` |
| `SdrOmittedPrimitiveParamSearchContextTest` | **No** | *"⚠ Deliberately not a count assertion"*; pins three **named** representatives plus the one withdrawn route |
| `SdrUncalledSurfaceNotExportedContextTest` | **No** | its `WITHDRAWN` (27) and `MUST_REMAIN_EXPORTED` are curated type lists; neither contains `Stockrecord` |
| `SdrWriteWithdrawalContextTest` | **No — and that is the problem** | `hasSize(49)` over its own literal set; see above |

Blind spot: this is the six SDR rails under `src/test/java/net/aim_ai/wms/security/` that carry a set or a
count. It is not a claim about the other thirteen files in that directory, which were not re-read here.

### 3.6 The export — filter only (Nam, Q2)

The `filter` key is **already in the POST body and already reaches the controller**.
`components/reports/popups/exportReport.vue` builds it unconditionally for every report type
(`filter: this.filter && this.filter != 'All Shippers' ? this.filter : null,`) and
`store/reports/stockUnit.js` spreads `...params.data`. Today `stockUnitRecord.vue` passes no `:filter` prop,
so `this.filter` is `undefined`, the field serialises as `null`, and the controller never reads the key.

So AC-2's export half is:

- **UI:** one attribute on the `<export-report>` tag — but **`:filter="String(shipper == null ? -1 : shipper)"`**,
  not `:filter="shipper"` and not the un-stringified fold (see the truth table below).
  `store/reports/stockUnit.js` needs **no change** for the filter.
- **API:** `ReportController.exportStockUnitRecord` reads `filter` from `reqMap` and passes it through;
  `ReportService.exportStockUnitRecord` gains the parameter and **branches on it**;
  `StockrecordRepository` gains a **new** `findByClientOffsetAndLimit` and its existing `findByOffsetAndLimit`
  is left byte-identical. **The export stays on the `stockrecord` table** — the 15 export columns are all base
  columns, so filtering on `client_id` needs no view, and adding `item_name` would change the spreadsheet's
  column contract (Q2: it does not).

**⚠ Why the existing method is not edited in place: it is a live SDR route, and the obvious
predicate silently empties it.** `StockrecordRepository.findByOffsetAndLimit` carries
`@RestResource(path = "findByOffsetAndLimit", rel = "findByOffsetAndLimit")` with **no `exported = false`**,
so `GET /api/stockrecord/search/findByOffsetAndLimit?keyword=&offset=0&limit=100` is routed today. Spring
Data REST binds a missing `Long` parameter to `null`, and the predicate originally proposed here —
`AND (CAST(:clientId AS bigint) = -1 OR p.client_id = CAST(:clientId AS bigint))` — has **no `IS NULL` arm**,
so with `:clientId = NULL` both disjuncts evaluate to `NULL`, the conjunction is `NULL` and **no row
qualifies**. Verified on `dev_wh01_om1`:
`SELECT count(*) FROM stockrecord p WHERE (CAST(NULL AS bigint) = -1 OR p.client_id = CAST(NULL AS bigint))
AND p.client_id = 60500;` → **0**, where the same query without the first conjunct returns **873,021**. Every
existing caller that does not know about the new parameter would get `[]` — not an error. That is precisely
the failure shape this plan flags as untestable elsewhere: *"an over-gated read renders an empty screen rather
than an error… invisible to every test."*

**Adding the `IS NULL` arm would fix the emptiness and re-create the §3.4 problem** — a three-arm disjunction
in native SQL, on the path that pulls thousands of rows rather than ten. The two findings resolve together,
once, the same way §3.4 resolves: **split the method.**

```java
// UNCHANGED BEHAVIOUR. Same name, same signature, same @RestResource, same rendered predicate. The only
// edit is textual: its inline keyword clause moves into the NATIVE_KEYWORD_CLAUSE constant below and is
// concatenated back in, byte-for-byte. Every existing caller -- HTTP or in-process -- sees exactly
// today's behaviour, which is why §6 can still say "No". unfilteredExportRouteIsUnchanged (§7.2) is the
// regression guard for the lift itself.
List<Stockrecord> findByOffsetAndLimit(@Param("keyword") String keyword,
                                       @Param("offset") int offset, @Param("limit") int limit);

// Quoted here in full, the way §3.4 quotes KEYWORD_CLAUSE, so the implementer does not have to reach for
// the one that IS written down. Lifted byte-for-byte from findByOffsetAndLimit at origin/develop,
// INCLUDING the leading space after WHERE and the trailing space before `order by`:
String NATIVE_KEYWORD_CLAUSE =
    " (CONCAT(LOWER(p.activitycode), ' ', LOWER(p.fromstoragelocation), ' ', LOWER(p.fromunitload), ' ',"
  + " LOWER(p.itemdata), ' ', LOWER(p.\"operator\")) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '') ";

// NEW. exported = false: there is no HTTP caller, and the repo's own rail says a search with no HTTP
// caller should be withdrawn rather than ruled (SdrUncalledSurfaceNotExportedContextTest).
// `p.client_id = CAST(:clientId AS bigint)` is a plain equality for the reason in §3.4. The explicit
// CAST follows StockViewRepository.findByClientOffsetAndLimit's `CAST(COALESCE(:filter,'') as TEXT)`:
// a bare bind inside a comparison can draw "could not determine data type of parameter" from Postgres.
// The keyword clause is LIFTED OUT of findByOffsetAndLimit into a constant and concatenated into both,
// for the reason in §3.4: the split is a filter split, not a search-semantics split, and two verbatim
// copies drift. StockrecordRepository.NATIVE_KEYWORD_CLAUSE holds the existing text byte-for-byte --
// changing it is a change to the UNFILTERED route too, which is the point.
//
// ⚠ NATIVE_KEYWORD_CLAUSE IS NOT THE SAME TEXT AS §3.4's KEYWORD_CLAUSE. It is native SQL and it QUOTES
// the operator column -- LOWER(p.\"operator\") -- where the JPQL clause writes LOWER(p.operator). Do not
// copy one into the other: `operator` is an UNRESERVED keyword on Postgres
// (SELECT catcode FROM pg_get_keywords() WHERE word = 'operator' -> U on dev_wh01_om1) and BOTH forms
// execute and return the same rows, so the wrong copy compiles, runs, and silently breaks only the
// byte-identical property that §6's "No" and unfilteredExportRouteIsUnchanged rest on.
@RestResource(exported = false)
@Query(value = "SELECT * FROM Stockrecord p WHERE" + NATIVE_KEYWORD_CLAUSE
             + " AND p.client_id = CAST(:clientId AS bigint) "
             + "order by p.created DESC offset :offset limit :limit", nativeQuery = true)
List<Stockrecord> findByClientOffsetAndLimit(@Param("keyword") String keyword,
                                             @Param("clientId") Long clientId,
                                             @Param("offset") int offset, @Param("limit") int limit);
```

`ReportService.exportStockUnitRecord` then picks: `clientId == null || clientId == -1L` ⇒
`findByOffsetAndLimit`, else `findByClientOffsetAndLimit`. **`== -1L`, never `!clientId`.** One consequence
worth stating: the four existing `when(stockrecordRepository.findByOffsetAndLimit(any(), anyInt(), anyInt()))` **stubs** in
`ReportServiceUnitTest` keep compiling, and §6's row for that route stays honestly "No". ⚠ **That is true of
the repository method only.** `ReportService.exportStockUnitRecord` *is* an in-place signature change, and it
breaks **11** four-argument call sites across `ReportServiceUnitTest` (4) and `ReportControllerUnitTest` (7) —
enumerated in §0.1 row 21. Those are compile errors, not test failures, so they surface in seconds; the split's
real justification is the silently-emptied SDR route above, not the test churn. **Confirm the rendered SQL against the
Testcontainers IT rather than trusting this snippet**; the evidence base captured no Hibernate-generated SQL,
so the statement above is reconstructed by hand.

Note the identical-shape sibling `UnitloadRecordRepository.findByOffsetAndLimit` (it backs
`exportContainerRecord`, and `ReportService` calls it the same way at line 398). Not this ticket's scope;
recorded because the §0 sweep should have surfaced it, and because Container Record is the screen most likely
to want this feature next.

**⚠ The `ClassCastException` trap — still fix it on the API side, even though the UI now sends a String.**
The natural implementation of the controller half is `String filter = (String) reqMap.get("filter");`, copying
the seven existing reads in the file. With `item-value="id"` a `filter` that arrives as a JSON **number**
makes that cast throw. §3.6's `String(...)` fold means *this screen* sends `"0"` / `"-1"` / `"60500"`, so the
number never arrives from here — but the API must not depend on one caller's serialisation for a cast not to
throw, and `/v3/dashboard/exportStockUnitRecord` is the same method behind a second route (§2.2). Read it as
`Object`, not `String`. Belt and braces, deliberately: the two fixes are independent and each is graded by its
own test (§7.3 `filterValueMatrix` for this one, §7.4's client-id-`0` case for the fold).

```java
Long clientId = toFilterId(String.valueOf(reqMap.get("filter")));
```

`String.valueOf((Object) null)` returns the literal `"null"`, which `toFilterId` catches as a
`NumberFormatException` and normalises to `-1L` — so absent, JSON-null, empty-string and non-numeric all
collapse to "no filter" through one existing, already-documented helper, and no cast can throw.

⚠ **What the pre-fix defect looks like when it fires: a 500, NOT a 200 with an error body.** This decides
three test assertions, so it is stated here rather than guessed at each of them. In `ReportController.java`
all **seven** existing `String filter = (String) reqMap.get("filter");` reads sit at the top of their method,
*above* the `try {` — read at `origin/develop`, reads at lines 66/93/121/148/175/202/229 against each method's
`try {` at 72/100/127/154/181/208/235 — the same position as `exportStockUnitRecord`'s own
`Integer offset = (Integer) reqMap.get("offset");`. A cast placed there throws **out of** the method and the
second catch block never sees it: a **500 through Spring's default handler**, and in the MockMvc lane
`mockMvc.perform(...)` itself raises a nested `ServletException`, so there is **no status to assert on**
(§7.3 `numericFilterIsForwarded`, §7.8's mutation row, §7.7's manual row all depend on this). Note also that
the second `catch (Exception e)` is **not** unique to this method — `grep -n "catch (Exception e)"` returns
exactly two hits, `exportStockUnitRecord` (line 270) and `exportContainerRecord` (line 304).

**⚠ `exportReport.vue`'s truthiness guard — and `client.id = 0` is a REAL shipper.** The shared component
builds the request body with `filter: this.filter && this.filter != 'All Shippers' ? this.filter : null`
(verbatim at `components/reports/popups/exportReport.vue`), which treats a **falsy** `this.filter` as "no
filter". `client.id = 0` is a real shipper, so a number-valued binding hits that branch. Two independent
instruments establish the `0`:

1. **The DB.** `SELECT id, cl_nr, name FROM client ORDER BY id LIMIT 3` on `dev_wh01_om1` returns
   `0 | System | System-Client` first. `min(id)` is **0**, not a positive sequence value, and that client owns
   **16 `stockrecord` rows**. Sweeping the reachable estate 2026-09-18, `client.id = 0` exists on **5 of 5**
   databases: `dev_wh01_om1`, `wh01_shipitez_v2` (UAT), `wh01_hydra_v2` (UAT), `wh02_shipitez_v2` (UAT) and
   `wh01_hydra_v2` (**PRD**), where it owns **53 unit loads** and 0 `stockrecord` rows. Blind spot: the two
   ShipItEZ prd databases are unreachable from this MCP set (§3.2).
2. **The repo, at `origin/develop`.** `components/handlingUnits/stockUnitsTable.vue` carries, at its dispatch
   site: *"`== null ? -1 :`, never `|| -1`. Client id 0 is a REAL shipper — 'System-Client', seeded by V2.2.00
   and present on Hydra PRD, where it owns 52 unit loads — and it is returned by the unfiltered allClients, so
   it appears in this very dropdown. `0 || -1` would map it onto the 'no filter' sentinel and show every
   shipper's rows."* `containerTable.vue` repeats the short form at its own dispatch site.

**What breaks without the fix.** Select **System-Client** and `shipper` is the number `0`. `exportReport.vue`
evaluates `this.filter && …` → `0` is falsy → it sends `filter: null` → `toFilterId(String.valueOf(null))`
folds `"null"` to `-1L` → "no filter". The table shows 16 System-Client rows; the downloaded `.xlsx` contains
every shipper's rows. No error, no toast, no non-200 — a silent wrong-data export, landing on the acceptance
criterion that introduces it.

**The fix — chosen by an executed truth table, not by reasoning.** ⚠ The obvious fold,
`:filter="shipper == null ? -1 : shipper"`, **does not work**: it maps `null → -1` and leaves `0` alone, and
`0` is exactly the value the guard eats. The collapse happens *downstream, inside* `exportReport.vue`, so a
fold that only rewrites `null` never reaches it. Executed with `node -e` over the guard as quoted from
`origin/develop` and each candidate binding, across the three values that exist:

| `shipper` | mutant `:filter="shipper"` | `:filter="shipper == null ? -1 : shipper"` | **`:filter="String(shipper == null ? -1 : shipper)"`** |
|---|---|---|---|
| `null` — All Shippers | prop `null` → body `null` → `-1L` | prop `-1` → body `-1` → `-1L` | prop `"-1"` → body `"-1"` → **`-1L`** |
| **`0` — System-Client** | prop `0` → body **`null`** → **`-1L`** ✗ | prop `0` → body **`null`** → **`-1L`** ✗ | prop `"0"` → body `"0"` → **`0L`** ✓ |
| `60500` — ARW | prop `60500` → body `60500` → `60500L` | prop `60500` → body `60500` → `60500L` | prop `"60500"` → body `"60500"` → **`60500L`** |

The API column is `toFilterId(String.valueOf(reqMap.get("filter")))` applied to the body value, with
`toFilterId` read in full from `AdminController.java`: `null`/blank → `-1L`, `Long.parseLong` otherwise,
`NumberFormatException` → `-1L`. `String.valueOf((Object) null)` is the literal `"null"`, which parses as a
`NumberFormatException` and folds to `-1L`.

```html
<export-report :show="showExport" :reportType="reportType"
               :filter="String(shipper == null ? -1 : shipper)" @close="closeExport" />
```

`"0"` is a **non-empty string** and therefore truthy, so it survives the guard; `"0" != 'All Shippers'` holds;
the body carries `"0"`; `toFilterId("0")` → `0L`. It also removes the `ClassCastException` trap as a property
of the value rather than relying on the API-side fix having been applied, and it puts this screen's wire value
in the same type as the seven `clNr` callers' — a String — so the shared component sees nothing new.

**Why not widen the shared guard instead.** The alternative is `this.filter != null && this.filter != 'All
Shippers'` inside `exportReport.vue`. Its blast radius measures as **nil**: all seven other `:filter="shipper"`
callers bind `item-value="clNr"` (verified one file at a time — `flowbin`, `inventory`, `lock`,
`outboundParcel`, `parcelPicking`, `receiving`, `skuLocation`), so their value is either `undefined`, which
`!= null` rejects loosely exactly as truthiness does today, or a non-empty `cl_nr` String, which both forms
accept. So "we did not touch the shared component" is **not** a safety property this plan needs, and it is
recorded here rather than left as an unexamined caution. It is still not taken, for one reason: it changes a
file eight screens render and this ticket's own test surface can only grade one of them, whereas the
`String(...)` fold is graded end-to-end by the Jest case in §7.4 and kills its own mutant. A future ticket that
wants the guard widened has the measurement here.

**The rule this ticket adopts, stated as an invariant rather than as one fix:** *every absence/sentinel check
on `clientId` or `filter` on this path is `== null ? -1 :` or `== null || === -1`; never `||`, never a bare
truthiness test.* Sweep of every such site, so the rule is applied rather than asserted:

| # | site | guard today | verdict |
|---|---|---|---|
| 1 | `stockUnitRecord.vue` — `<export-report :filter>` | none (no prop passed) | **FIX — `String(shipper == null ? -1 : shipper)`.** The un-stringified fold is NOT sufficient: it leaves `0` falsy and site 6 eats it |
| 2 | `store/reports/stockUnit.js` — route choice | new code | **WRITE CORRECTLY — `data.clientId == null \|\| data.clientId === -1`** |
| 3 | `store/reports/stockUnit.js` — `&clientId=` append | new code | **WRITE CORRECTLY — append from state with `?? -1`, per `store/handlingUnits/stockUnits.js`** |
| 4 | `ReportService.exportStockUnitRecord` — method choice | new code | **WRITE CORRECTLY — `clientId == null \|\| clientId == -1L`** |
| 5 | `ReportController.exportStockUnitRecord` — `filter` read | new code | **WRITE CORRECTLY — `toFilterId(String.valueOf(...))`, which is value-blind** |
| 6 | `components/reports/popups/exportReport.vue` — `this.filter && …` | **truthiness** | NO EDIT — fixed upstream at site 1; changing it touches 8 other screens |
| 7 | `store/reports/inventory.js` — `data.clientNumber != null & …` | `!= null` (bitwise `&`, but correct) | NO EDIT — not this screen, and `clNr` is a String |
| 8 | `store/internalOps/cycleCount.js` — `if (data.clientId) {` | **truthiness, on a numeric `clientId`** | NO EDIT — **out of scope but the same defect, live today**: a selected System-Client is dropped from the Cycle Count filter. Proposed in §10.4 |
| 9 | `store/admin/labelPrinting.js` — `if (data && data.clientId)` | **truthiness, on a numeric `clientId`** | NO EDIT — out of scope; label printing, not a filter. **FILED** with site 8 on §10.4's item-1 ticket |
| 10 | `components/handlingUnits/{containerTable,stockUnitsTable}.vue` | `== null ? -1 :` | **already correct — this is the source of the rule** |
| 11 | `store/internalOps/replenishments.js` — `if (data.clientId != null) {`, twice | `!= null` | **already correct** — the rule, on a numeric id |
| 12 | `store/reports/outboundParcel.js` — `const clientNumber = context.state.shipperFilter \|\| null` | **truthiness** | NO EDIT — a `||` fold, but on `clNr` (a non-empty String), so unreachable today. Same class as site 7 |
| 13 | `store/internalOps/cycleCount.js` — `'&clientId=' + (context.state.…ShipperFilter \|\| '')`, twice | **truthiness, second mechanism** | NO EDIT — **a SECOND expression shape in the file site 8 already covers.** `0 \|\| ''` → `''` → `toFilterId("")` → `-1`: the same defect by a different expression. §10.4 item 1 must fix **both**, or it fixes half |

Deriving method: `git grep -n "clientId" origin/develop -- 'store/*.js' 'components/**/*.vue'` plus
`git grep -n "export-report"`, both repo-wide at `a27703eb`, reading every hit; then a second pass over the
names that *hold* a client id without being called `clientId` — `shipper`, `selectedShipper`, `shipperFilter`,
`filter` — which is what produced sites 1, 6, 10 and 12. Blind spots: a guard built at runtime from a string
cannot be seen by any grep; and the name-based second pass is only as complete as the name list, so a guard
on a fifth alias would still be missed. Sites 11–13 were added after an independent re-run of the same method
by a reviewer found them absent — none changes a verdict (11 is already correct, 12 is unreachable, 13 is a
second expression in a file already listed), which is the evidence that the sweep's *conclusions* were right
while its *enumeration* was not complete.

### 3.7 The details popup — `itemName`

`StockrecordService.getStockRecordDetails(Long id)` gains, alongside the existing client resolution:

```java
if (s.getClientId() != null && s.getItemdata() != null) {
    itemdataRepository.findByClientIdAndItemNr(s.getClientId(), s.getItemdata())
        .ifPresent(i -> details.put("itemName", i.getName()));
}
```

`ItemdataRepository.findByClientIdAndItemNr(@Param("clientId") Long clientId, @Param("itemNr") String itemNr)`
already exists — no new finder. Using `ifPresent` (rather than `orElseThrow`, as the sibling `Client`
resolution does) is deliberate: a SKU string that no longer resolves must leave the key **absent**, not
explode the popup. `components/common/fullDetails.vue` renders whatever keys the map carries, so an absent
key simply omits the row, and the `:field-names` entry `'itemName': 'SKU Name'` labels it when present.

### 3.8 `/v3/client/allClients` — the latent empty dropdown

`ClientController.allClients` is gated on an **ANY-of list of eleven** functions:

```java
@RequiresFunction({WmsConstants.FunctionEnum.WEB_UI_VIEW_CLIENT,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_CYCLECOUNT,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_REPLENISHMENT_ORDER,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_INBOUND_BOL,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_FLOWBIN_MONITOR,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_INVENTORY_RECORD,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_PARCEL_MONITOR,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_PARCEL_PICKING,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_LOCATION_OVERVIEW})
```

`WEB_UI_VIEW_STOCK_UNIT_RECORD` is not among them. Adding a shipper dropdown to this report makes it a new
caller of `admin/client/getClients`, so a user holding only `WEB_UI_VIEW_STOCK_UNIT_RECORD` gets a 403 and an
**empty dropdown, not an error** — the exact failure `SdrFunctionGuard`'s javadoc warns about: *"An
over-gated read renders an empty screen rather than an error, so it is invisible to every test and to the
denial counter."*

**Measured blast radius on `dev_wh01_om1`, 2026-09-18, traversing user → group → role → function:**

| | |
|---|---|
| users holding `WEB_UI_VIEW_STOCK_UNIT_RECORD` | **45** |
| of those, users holding **none** of the eleven | **0** |
| positive control — same query, allow-list replaced by a non-existent function | **45** (so the zero is a measurement, not a broken query) |
| positive control — holders of `WEB_UI_VIEW_NOT_A_REAL_FUNCTION` | **0** |

⚠ **That "0 blocked" figure is one tenant at one instant.** `wh01_hydra_v2`, `wh01_shipitez_v2` and the
other prd tenants were not measured, and role assignments change. It is left OPEN as Q6.

**⚠ Apply the invariant; do not add one constant.** The rule is *"every screen carrying a shipper dropdown
contributes its view function to `allClients`"*, and the repo-wide `getClients` sweep (§0 row 45) finds a
screen that **already violates it, live on `develop` today**, shipped under the same parent ticket:

- `util/appMenuList.js`: `{ icon: 'mdi-sitemap', text: 'Handling Units', to: '/handlingUnits/handling-units', fn: ['WEB_UI_VIEW_STOCK_UNIT', 'WEB_UI_VIEW_CONTAINER'] }`
- `components/handlingUnits/{containerTable,stockUnitsTable}.vue` both dispatch `admin/client/getClients` and both render a shipper `<v-autocomplete>`.
- Neither `WEB_UI_VIEW_STOCK_UNIT` nor `WEB_UI_VIEW_CONTAINER` is among `allClients`'s eleven.
- Corroborating: `StockUnitController`'s `/detailView`, the endpoint those two grids read, is itself gated
  `@RequiresFunction({…WEB_UI_VIEW_STOCK_UNIT, …WEB_UI_VIEW_CONTAINER})` — so the pair is the screen's real
  gate, not just its menu entry.

**Derivation of the complete gap set** (so the next reader re-derives rather than trusts a list): map every
`getClients` dispatcher from §0 row 45 to its `appMenuList.js` `fn`, and subtract `allClients`'s eleven.
Cycle Count → `WEB_UI_VIEW_CYCLECOUNT` ✓ · Replenishment → `WEB_UI_VIEW_REPLENISHMENT_ORDER` ✓ · Inbound
Notices (`createPurchaseOrder`) → `WEB_UI_VIEW_INBOUND_BOL` ✓ · the seven reports → `INVENTORY_RECORD`,
`STOCK_UNIT_LOCK_OVERVIEW`, `RECEIVED_STOCK_OVERVIEW`, `LOCATION_OVERVIEW`, `FLOWBIN_MONITOR`,
`PARCEL_PICKING`, `PARCEL_MONITOR` ✓ (seven of the eleven; the eleventh, `WEB_UI_VIEW_CLIENT`, is the admin
Shippers screen). **Remainder: `WEB_UI_VIEW_STOCK_UNIT`, `WEB_UI_VIEW_CONTAINER` (already live) and
`WEB_UI_VIEW_STOCK_UNIT_RECORD` (this ticket).** Blind spot: `appMenuList.js`'s `fn` is the menu-visibility
function, which is the screen's gate for every row checked here but need not be in general; and a screen
reachable without a menu entry would not appear.

The same blast-radius query run for the already-live pair on `dev_wh01_om1`: **45** users hold one of those
two functions and **0** hold none of the eleven — identically latent, same one-tenant caveat. **P5 therefore
takes the list from eleven to fourteen**, which costs nothing extra and fixes the rule rather than the
instance.

**Three edits, all in one commit:**

1. `ClientController.java` — add **`WEB_UI_VIEW_STOCK_UNIT_RECORD`, `WEB_UI_VIEW_STOCK_UNIT` and
   `WEB_UI_VIEW_CONTAINER`** to the `@RequiresFunction` list (eleven → **fourteen**).
2. `Sbdev3017TrancheGateContextTest.java` — add the same three to the matching
   `row("ClientController", "/v3/client/allClients", …)` varargs. **Changing only #1 turns that test red;
   changing only #2 is a false green.** ⚠ A gate pin must carry the **full** varargs and at least one
   **ungated** row, or a class-level annotation change can pass it.
3. The prose in both files. `ClientController`'s comment enumerates ten screens and says *"every one of the
   13 … dispatchers"*; the test's repeats *"All 13 … dispatchers"* and *"six reports"*. All of those counts
   become wrong the moment this ticket lands. Restate them as the **rule**, with the count given as
   derived-at-a-date — do not increment each number and leave the next reader the same trap.

### 3.9 The UI

**The dropdown (AC-1).**

```html
<v-autocomplete
  :items="shippers" item-text="label" item-value="id" clearable
  v-model="shipper" id="shipper" placeholder="Choose Shipper / Brand" … />
```

with `item-value="id"`, not `clNr` (Q1). `admin/client/getClients` already carries `id` — the payload is a
`Page<Client>` of the full entity (`ClientController.allClients` returns
`clientRepository.findAll(PageRequest.of(0, count.intValue(), Sort.by("name")))`).

**✅ `<v-autocomplete>`, not `<v-select>` — DECIDED (Nam, 2026-09-18).** This was round 3's one open
AC-visible choice; it is closed. The sibling that solved this exact problem chose the same widget, with its
reason in-source (`components/handlingUnits/stockUnitsTable.vue`): *"v-autocomplete rather than the v-select
used by the Replenishment and Cycle Count filters: this grid spans 130+ shippers and 3,495 SKUs on the
ShipItEZ warehouse that requested it, which is past the point a scrolling list is usable."* Shipper counts
measured 2026-09-18: `dev_wh01_om1` **159**, `wh01_shipitez_v2` (UAT) **164**, `wh02_shipitez_v2` (UAT)
**125**, `wh01_hydra_v2` (PRD) **147** — every environment past that threshold. `inventoryReport.vue` and the
six other reports use `<v-select>`, so this diverges from the *report* convention and converges on the
*shipper-filter* convention; the divergence is deliberate and measured.

⚠ **Three consequences the implementer and §7.4 must carry, none of which a `<v-select>` would have had:**

1. **`clearable`, and NO sentinel row.** The "All Shippers" entry is dropped from `shippers`; clearing the
   field is what selects "no filter", and the computed's `set(null)` folds to `-1` on dispatch exactly as
   §3.6's rule requires. This is the sibling's *"DELIBERATE DIVERGENCE"* note applied, which warns in so many
   words that *"a null-valued sentinel row plus truthiness is precisely what mapped the real client id 0 onto
   'no filter'."* A sentinel row plus `clearable` would give two spellings of "no filter" and one of them
   (`{id: null}`) is the one that has already caused this bug once.
2. **Type-ahead filters on `item-text`, not on the id.** `item-text="label"` is
   `name + " (" + clNr + ")"`, so typing `ARW` matches on the `cl_nr` inside the label and typing a shipper
   name matches on the name. **Nothing filters on `id`** — a user typing `0` does **not** find System-Client
   unless `0` appears in its label. This is a behaviour difference from a scrolling `<v-select>`, and it is
   why §7.4 asserts the `0` case by **selecting the item**, not by typing.
3. **The empty-input state is `null`, not `''`.** `v-autocomplete` with `clearable` sets the model to `null`
   on clear; the search text is separate state and never reaches `v-model`. So the computed's setter sees
   `null` and §3.6's `== null ? -1 :` rule applies unchanged — but a `set()` that coerced with `||` would
   now be reachable from the clear button as well as from first load.

**⚠ `shipper` must be a computed backed by Vuex, never a `data()` property.** `mixins/searchUrlSync.js`
declares `const possibleProps = ['search', 'keyword', 'filter', 'searchText', 'query', 'searchQuery'];` and
binds the URL `?search=` to the **first** of those found in `this.$data`. `stockUnitRecord.vue` has `keyword`
in `data()`, so `keyword` wins today — and must keep winning, because SBDEV-2658's adjustment-alert toast
deep-links via `?search={sku}` (the `'$route.query.search'` watcher and the `created()` hook both read it).
A `data()` key named `filter` would not break it (`keyword` still sorts first), but a computed cannot appear
in `this.$data` at all, so the hazard is removed rather than merely avoided. `inventoryReport.vue` already
does this:

```js
shipper: {
  get() { return this.$store.state.reports.inventory.shipperFilter },
  set(newVal) { this.$store.commit('reports/inventory/setShipperFilter', newVal) }
}
```

It also gives the filter the same cross-navigation persistence the Inventory report has.

**The store.** Mirror `store/reports/inventory.js`'s `shippers` / `shipperFilter` state, `setShippers` /
`setShipperFilter` / `resetShipperFilter` mutations — **but do not copy `searchReport` verbatim**:

```js
if (data.clientNumber != null & data.clientNumber !== 'All Shippers') {
  urlPart += '&clientNumber=' + data.clientNumber
}
```

has two defects. `&` is the **bitwise** AND, not `&&`; with two booleans it coerces to 0/1 and happens to
behave correctly — by accident. And `!== 'All Shippers'` is **vestigial**: the "All Shippers" entry is
`{ name: null, label: 'All Shippers' }` with no `clNr` key, so `item-value="clNr"` yields `undefined`, which
`undefined != null` already rejects. With `item-value="id"` the condition must be re-derived from scratch,
not ported. The form to write:

**⚠ Take the store shape from `store/handlingUnits/stockUnits.js`, not from `inventory.js`.** That
sibling made three decisions this plan re-opened, each with its reason in-source, and each is adopted:

1. **Merge, never replace.** `setFilters(state, payload) { state.list = Object.assign({}, state.list, {
   clientId: payload.clientId ?? -1 }) }` — *"setList above swaps the whole object… a component-only filter
   would silently drop out of those requests."* Search and sort must survive a filter change.
2. **Append from state — on the FILTERED branch only.** `… + '&clientId=' + clientId`, with `clientId` read
   from `context.state.list`, never from `data`: *"from state rather than from `data`, so a refresh with no
   payload carries the same filters the user can see selected in the toolbar."* `store/reports/stockUnit.js`
   has the same payload-less refresh path. ⚠ **The from-state rule is adopted; the sibling's "on every
   request" is not.** The §3.4 split gives the unfiltered method **no `clientId` parameter**, so AC-1 grades
   the "All Shippers" request as carrying **no `clientId` at all** and §7.4 asserts its absence. Appending
   `&clientId=-1` on that branch reds §7.4. The snippet below routes it correctly; follow the snippet.
3. **Reset it alongside search and sort.** `resetList` sets `clientId: -1` — *"this object REPLACES
   state.list, so omitting them would leave the grid filtered with an empty toolbar — rows missing for no
   visible reason."*
4. **Read the rows through a rel-checking accessor** (not from the sibling — and the reason for it is
   **not** the one rounds 1–3 gave). ⚠ **MEASURED 2026-09-18 — `_embedded` is PRESENT WITH AN EMPTY ARRAY on
   a zero-row SDR page. The claim this plan carried for three rounds was inverted.** Six routes across four
   resource kinds, all 200, all `"_embedded": {"<rel>": []}`; full bodies, method and blind spots in
   `SBDEV-3410-evidence/embedded-shape-measurement.md`. The decisive one is the shape this ticket adds:

   ```json
   GET /v3/stockrecord/search/findByKeyword?keyword=ZZZNOPE&page=0&size=1
   {"_embedded": {"stockrecord": []}, "_links": {…}, "page": {"size":1,"totalElements":0,"totalPages":0,"number":0}}
   ```

   **Two things follow, and both are corrections.** (a) `store/reports/stockUnit.js`'s unguarded
   `results._embedded.stockrecord` does **not** throw on a zero-row page — it evaluates to `[]` — so the
   *"grid keeps the previous shipper's rows under a network toast"* failure mode both review lanes graded
   HIGH **is not live**, on this screen or anywhere else. (b) The in-repo source of the claim,
   `store/admin/group.js`'s SBDEV-3012 javadoc, is **false**, measured on the very shape it describes (an
   association collection, `GET /v3/userGroup/{id}/roles` → `{"_embedded":{"userRole":[]}}`); proposed as a
   comment correction in §10.4.

   **The accessor still ships, for the one arm that is live.** `_embedded` is always present, so a payload
   carrying `_embedded` **without** the `stockrecordView` rel means the `collectionResourceRel` was renamed —
   a routing bug that an unguarded read turns into a silent "no rows". That arm is reachable and is what
   `rowsOf` detects; the `!embedded → []` arm is now known to be unreachable on this stack and is kept as
   defence, not as a fix. Precedent is `rowsOf` / `countOf` in `store/admin/group.js` (local `const`s, not
   exported, so P6 writes them again — six lines).

With the §3.4 split, the store also picks the route, and it must route **both** `null` and `-1` to the
unfiltered method and never use a truthiness test (§3.6 site 2):

```js
// MEASURED (SBDEV-3410, see the plan's §3.9): SDR sends `_embedded: { stockrecordView: [] }` on a
// zero-row page -- PRESENT and empty, not absent. So the live arm here is the REL CHECK: an `_embedded`
// without our rel means the collectionResourceRel was renamed, and reading that as "zero rows" reports an
// empty grid for a routing bug. The `!embedded` arm is unreachable on this stack; kept as defence.
// Shape copied from store/admin/group.js -- but NOT its comment, which asserts the opposite and is wrong.
const rowsOf = (payload, rel) => {
  const embedded = payload && payload._embedded
  if (!embedded) { return [] }
  const rows = embedded[rel]
  if (rows === undefined) { throw new Error(`SBDEV-3410: response carried _embedded without the "${rel}" rel`) }
  return rows
}
// `page` is emitted for a Page-returning resource and NOT for a List-returning one (measured: probes C/E/F
// carry no `page` block). Both of this screen's routes return Page, so it is always there; the fallback is
// defence against a route change, not a measured case.
const countOf = (payload) => (payload && payload.page && typeof payload.page.totalElements === 'number')
  ? payload.page.totalElements : 0

// `== null` / `=== -1`, never `!clientId` — client id 0 is a real shipper (§3.6).
const clientId = context.state.list.clientId ?? -1
const path = (clientId === -1)
  ? '/stockrecordView/search/findByKeyword' + urlPart
  : '/stockrecordView/search/findByKeywordAndClient' + urlPart + '&clientId=' + clientId
const results = await this.$axios.$get(path)
context.commit('setReportItems', { reportItems: rowsOf(results, 'stockrecordView'), totalItems: countOf(results) })
```

Note the two halves differ deliberately, and **only one of them is reachable**. An `_embedded` **present
without the `stockrecordView` rel** throws, because that means the `collectionResourceRel` was renamed and
reading it as zero would report "no rows" for a routing bug — that is the live arm. A **missing `_embedded`**
returns `[]`, and the measurement says SDR never sends that shape, so the arm is defence rather than a case.
`countOf` falls back to `0` for the same reason: SDR emits `page` on every `Page`-returning resource (measured
on both of this screen's route shapes) and omits it on a `List`-returning one, which neither of these routes
is.

⚠ **No "All Shippers" sentinel row** — with `<v-autocomplete clearable` (decided above) the empty model
*is* "All Shippers", and the computed's setter folds `null → -1` on dispatch per §3.6's rule. The
`'$store.state.admin.client.clients'()` watcher therefore builds `shippers` from the payload **without**
prepending `{ id: null, label: 'All Shippers' }`, which is where `inventoryReport.vue` differs.

**The SKU Name column (AC-3, Q4).** Insert into `headers`, next to `SKU ID`:

```js
{ text: 'SKU Name', align: 'start', sortable: false, value: 'itemName', class: 'py-3' },
```

`sortable: false` is Nam's Q4 decision, and it is **policy, not a guarantee** — see §3.10.

**The export prop (AC-2).**
`<export-report :show="showExport" :reportType="reportType" :filter="String(shipper == null ? -1 : shipper)" @close="closeExport" />`
— **the `String(...)` is required, not stylistic.** `:filter="shipper"` and `:filter="shipper == null ? -1 : shipper"`
are byte-identical for `shipper = 0` — both send `filter: null` and export every shipper. §3.6 carries the
executed truth table, the repo-wide guard sweep, and the measured blast radius of the alternative.

**The popup label (AC-3).** Add `'itemName': 'SKU Name',` to `<full-details>`'s `:field-names`.

**Dropdown population.** `this.$store.dispatch('admin/client/getClients')` inside the `options` deep watcher,
as `inventoryReport.vue` does, plus the `'$store.state.admin.client.clients'()` watcher that rebuilds
`shippers` **without** a head entry — the `<v-autocomplete clearable>` decision drops the
`{ id: null, label: 'All Shippers' }` row `inventoryReport.vue` prepends (§3.9) — carrying only the
`map(client => Object.assign(client, { label: client.name + " (" + client.clNr + ")" }))` labels, which are
also what type-ahead matches on. Note the
dispatch fires on **every table option change**; that is the existing sibling behaviour and the `clients`
Caffeine cache (`CacheConfig.buildCaffeineCache("clients", 100, Duration.ofMinutes(5))`) absorbs it. Not
changed here.

### 3.10 Deliberately NOT done

| Not done | Why |
|---|---|
| Widen the keyword search to `item_name` / `cl_name` | Referencing a joined column in `WHERE` defeats join elimination: measured, the unfiltered count goes from ~7.3 s to ~17.9 s (2.5×). Needs its own design, not a longer `CONCAT`. Whoever takes it edits **`KEYWORD_CLAUSE`** (§3.4) and **`NATIVE_KEYWORD_CLAUSE`** (§3.6), not an individual `@Query` — the constants exist so the filtered and unfiltered paths cannot diverge on what they search. |
| Make **SKU Name** sortable | Q4. Measured `order by item_name asc limit 10 offset 0` unfiltered: **17,942 ms**, `Sort (top-N heapsort)` over two `Hash Left Join`s over a `Parallel Seq Scan` of all 9.7 M rows. Filtered to one shipper it becomes `Sort Method: external merge Disk: 54,984 kB` **per worker** (4 workers ≈ 215 MB of temp I/O) at 1,853 ms. For scale: the existing worst case today is `order by operator` unfiltered at **7,847 ms**, so this would be 2.3× worse. |
| Sort by `cl_name` / `cl_nr` | Same shape as `item_name` — a joined column with no index. Would be a third 18-second path. |
| An `SdrFunctionRules` entry for `StockrecordView` | Adds no new **enforcement** gap (the read guard is OFF on every tenant measured) but is **not** a no-op: it widens the payload an unruled reader sees by `item_name`/`cl_nr`/`cl_name` (§3.5). Closing the gap is separate scope on the SBDEV-3222/3183 programme, needing shadow-mode measurement. |
| Change `exportReport.vue`'s truthiness guard | Nine components mount it and seven pass a String `:filter`; changing the guard is a blast radius eight screens wide for a defect fixable in one binding (§3.6). |
| Fold `findByOffsetAndLimit` and `findByClientOffsetAndLimit` into one three-valued method | That is the A-1/C-2 defect: the `OR` form is non-indexable under a generic plan, and adding an `IS NULL` arm to the existing route is what silently empties it for callers that omit the parameter (§3.4, §3.6). |
| `item_name` in the exported spreadsheet | Q2. Changes the 15-column contract a downstream macro may key on by position. |
| Withdraw `/api/stockrecord/search/findByKeyword` | **Q5, left OPEN.** Zero Java callers, but an externally-visible route. |
| Any change to `v2/wms2-mobile-ui` | The Stock Unit Record report is a web-UI screen. The bundle did **not** verify the mobile UI has no counterpart — recorded as a limitation, not a finding. |

**⚠ `sortable: false` has no technical enforcement.** SDR passes `&sort=` straight to JPA, so a user who
hand-types `?sort=itemName,asc` on the URL gets the 17,942 ms plan regardless of the header array. The only
hard stop would be not mapping `itemName` as a sortable property, which directly conflicts with AC-3. Record
it as policy.

---

## 4. File Change Summary

| File | Add/Modify/Delete | Description |
|---|---|---|
| `v2/wms2-api/src/main/resources/db/migration/V2.2.33__stockrecord_view.sql` | **Add** | `CREATE OR REPLACE VIEW public.stockrecord_view` + `CREATE INDEX index_stockrecord_client_created ON stockrecord (client_id, created DESC)` |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/model/StockrecordView.java` | **Add** | Read-only `@Entity` on the view; no `AbstractBaseEntity`; explicit `@Column` on every camelCase field |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/StockrecordViewRepository.java` | **Add** | `@RepositoryRestResource(path = "stockrecordView")`; **two** searches — `findByKeyword(keyword, Pageable)` and `findByKeywordAndClient(keyword, clientId, Pageable)`, the latter a **plain equality** (§3.4); three `findAll` suppressions |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/RestConfiguration.java` | **Modify** | Add `StockrecordView.class` to `exposeIdsFor(...)` **and** to `SDR_WRITE_WITHDRAWN` (the latter is required, not parity — §3.5) |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/security/SdrWriteWithdrawalContextTest.java` | **Modify** | Add `StockrecordView` to `WITHDRAWN`, bump `hasSize(49)` → `50`, correct the "IDENTICAL — 49 names" javadoc. **Skipping this goes unnoticed** (§3.5) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/StockrecordRepository.java` | **Modify** | **Add** `findByClientOffsetAndLimit(keyword, clientId, offset, limit)`, `@RestResource(exported = false)`, plain equality. `findByOffsetAndLimit` is **left byte-identical** — editing it in place empties a live SDR route (§3.6) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/ReportService.java` | **Modify** | `exportStockUnitRecord` gains `Long clientId` and **branches**: `-1L`/null ⇒ `findByOffsetAndLimit`, else `findByClientOffsetAndLimit`. **No `@Transactional`** (§7.5) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/ReportController.java` | **Modify** | Read `filter` as `Object` via `toFilterId(String.valueOf(reqMap.get("filter")))`; pass through |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/StockrecordService.java` | **Modify** | `getStockRecordDetails` resolves `itemName` via `ItemdataRepository.findByClientIdAndItemNr`, `ifPresent` |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/ClientController.java` | **Modify** | Add **`WEB_UI_VIEW_STOCK_UNIT_RECORD`, `WEB_UI_VIEW_STOCK_UNIT`, `WEB_UI_VIEW_CONTAINER`** to `allClients`'s `@RequiresFunction` (11 → 14 — the last two close an already-live gap, §3.8); restate the rotting count comment as a rule |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/security/StockrecordViewHalContextTest.java` | **Add** | MockMvc SDR request asserting `$._embedded.stockrecordView[0].id` exists — the only lane that can execute §7.8's `exposeIdsFor` mutant (§7.2) |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/schema/StockrecordViewSchemaIT.java` | **Add** | View exists after migrate · every `@Column` resolves · zero-multiplication · LEFT-not-INNER · nine sort keys resolve |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/…/StockrecordViewRepositoryFilterIT.java` | **Add** | Filter + keyword + sort + page compose; row set **and** `totalElements`; client id `0`; **a client with zero rows returns an empty page** |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/repo/StockrecordViewRepositoryQueryShapeUnitTest.java` | **Add** | Reflects on `findByKeywordAndClient`'s `@Query` string: the plain-equality conjunct is present and no disjunction follows it. **This is what kills the fold-it-back mutant** — the EXPLAIN IT cannot (§7.2, §7.3) |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/controller/ReportControllerUnitTest.java` | **Modify** | Extend nested `ExportStockUnitRecord` with the AC-2 value matrix (`0 → 0L`). ⚠ **Also fix 7 four-argument call sites** (§0.1 row 21) |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/ReportServiceUnitTest.java` | **Modify** | Extend nested `ExportStockUnitRecord`: the filter reaches `findByClientOffsetAndLimit`; 15 columns unchanged. ⚠ **Also fix 4 four-argument call sites** that stop compiling when the service gains `Long clientId` (§0.1 row 21) |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/StockrecordServiceUnitTest.java` | **Modify** | `itemName` present when the SKU resolves; **key absent** when it does not |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` | **Modify** | Add all **three** function names to the `allClients` row's full varargs; the two `exportStockUnitRecord` rows stay green |
| `v2/wms2-web-ui/components/reports/stockUnitRecord.vue` | **Modify** | Dropdown (**`<v-autocomplete clearable`**, decided — §3.9) · `shipper` computed · SKU Name header (`sortable: false`) · **`:filter="String(shipper == null ? -1 : shipper)"`** · `'itemName'` label · `updateTable` passes `clientId` |
| `v2/wms2-web-ui/store/reports/stockUnit.js` | **Modify** | `shippers` / `shipperFilter` state + **merge-not-replace** mutations and `resetList` (§3.9); `searchReport` picks `findByKeyword` vs `findByKeywordAndClient`, new `_embedded` key, `&clientId=` appended **from state** |
| `v2/wms2-web-ui/test/components/reports/stockUnitRecordShipperFilter.spec.js` | **Add** | Jest: widget renders and mounts **empty** (no "All Shippers" row — §3.9), selection reaches the store and the request; **client id `0` puts `filter: "0"` in the emitted POST body**; **a zero-row response clears the grid**; **a renamed-rel response does not commit** — the only case that grades `rowsOf` (§7.4); plus the three `<v-autocomplete>` behaviours (type-ahead on `item-text`, clear ⇒ `null`, no sentinel row) |

---

## 5. Phased Implementation Plan

Each phase is one branch off freshly-fetched `origin/develop`, one PR, independently reviewable and
independently deployable in the stated order. Work happens in `.claude/worktrees/<repo-dir-name>/SBDEV-3410`
per the repo convention — never in the main sub-repo checkouts.

⚠ **Merging to `develop` on `wms2-api` is a dev deploy and runs Flyway on every tenant at boot.** P1's merge
is therefore the moment the ~6 s `SHARE` lock on `stockrecord` happens. Plan it, don't discover it.

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Every target tenant converged past the `V2.1.16` watermark and applying `db/migration` V2.2.x deltas; `V2.2.32` is the current max on `develop`/`main`/`release`. `stockrecord_view` must not pre-exist — **verified absent on the five databases this MCP set can reach** (`dev_wh01_om1`, `wh01_shipitez_v2` UAT, `wh01_hydra_v2` UAT, `wh02_shipitez_v2` UAT, `wh01_hydra_v2` PRD; control on each — `stock_view` returns 1 row from the same `information_schema.views` query, so the zero is a measurement). **That is not "every tenant": all three prd MCP aliases resolve to the same database, so both ShipItEZ prd databases are unmeasured** (§3.2). An operator must re-derive it there with real prd credentials before P1 reaches a prd-bound ladder | implementer | ⚠ **`V2.2.11` is NOT burned** — `src/main/resources/db/migration/V2.2.11__seed_adjustment_alert_poll_sysprop.sql` exists on `origin/develop`. `db/migration/README.md` still says it is *"deliberately skipped… Do not reuse"*, and that README is stale. Irrelevant to `V2.2.33` itself; correcting the README is proposed in §10.4 |
| 2 | **Feature flags / system properties** | **N/A** — the feature is unconditional; no `los_sysprop` row, no toggle. Rationale: a report column and a filter have no staged-rollout requirement and no kill switch was requested | — | |
| 3 | **Config / env changes** | **N/A** — no new property. Rationale: no datasource, cache, pool or security property changes; also avoids the `.gitignore`-swallows-new-`*.properties` trap, which does not apply because no properties file is added | — | |
| 4 | **Deploy-order dependencies** | **P1 → P2 → (P3, P4, P5 in any order) → P6.** ⚠ **P1 → P2 is a BUILD-order dependency, not only a deploy-order one:** the `postgres-integration` profile runs `spring.jpa.hibernate.ddl-auto=validate` (SBDEV-3285), so a P2 branched off a `develop` that does not yet carry `V2.2.33` fails **every** context load in that lane, not just the new IT — a whole-lane red with a schema-validation message, which is a confusing first failure. **Branch P2 only after P1 has merged.** P6 calls `/api/stockrecordView`, which P2 creates. Two orderings, not one: P6-before-**P3** degrades to "filter ignored on export", not an error (the controller ignores `filter` today, so P6 alone is inert there) — **but P6-before-P2 is a BLANK REPORT, 404 on every page load, which is not a degradation.** "Merged" is not "deployed": gate P6 on `/api/public/version` reporting a SHA that contains P2, because the `:develop` tag race can deploy an older image than the merge order implies | implementer | `oms-laravel-api` is not involved |
| 5 | **Data migration** | **N/A** — no backfill. Rationale: a view computes from existing rows; the index is derived. No one-off SQL, no DBA task beyond the post-deploy verification in row 8 | — | |
| 6 | **External systems** | **N/A** — no OMS webhook, printer, or Keycloak realm change. Rationale: the change is confined to a read path and one existing function gate | — | |
| 7 | **Access / permissions** | **No new `FunctionEnum` constant.** `WEB_UI_VIEW_STOCK_UNIT_RECORD` already exists and is already granted (45 holders on `dev_wh01_om1`). The change is widening `ClientController.allClients`'s existing ANY-of list to include it (§3.8) — a widening, not a new gate, so no `initDB` grant line and no `WmsConstants` edit | implementer | The corresponding `Sbdev3017TrancheGateContextTest` row must change in the same commit |
| 8 | **Monitoring / alerts** | Post-deploy, verify **three** things **per tenant** — `stockrecord_view` in `information_schema.views`, `index_stockrecord_client_created` in `pg_indexes`, **and `itemdata`'s `UNIQUE (client_id, item_nr)` in `pg_constraint`**, which is the object §3.1's third statement asserts and the one whose absence corrupts the view's row count silently. `V2.2.32`'s header: *"Verify per tenant after deploy; do not infer it from a healthy application."* Tenant Flyway failures never abort the boot and `ddl-auto=none` means a missing view boots green and 42P01s on every page load; a **drifted** view has no runtime detector at all (stated in the migration file's header). No new Grafana panel: nothing scrapes Prometheus in this environment yet, so a new metric would not be a working control | implementer | Ownership-drift tool if a tenant is frozen: `src/main/resources/db/reassign-tenant-ownership.sh`. Favourable, measured 2026-09-18: hydra prd is at `flyway_schema_history` 33 applied, `2.2.32` present, **0 failed**, and `stockrecord`'s owner there is `wh01_hydra_v2_app` = `current_user`, so the ownership hazard is discharged on that tenant today |

### 5.2 Phases

#### P1 — `V2.2.33`: the view and the index
**Branch:** `feature/SBDEV-3410-p1-stockrecord-view-migration` (`v2/wms2-api`)

- [ ] Re-run `bash src/main/resources/db/check-migration-version-collision.sh V2.2.33` from the repo root (the script `cd`s to `git rev-parse --show-toplevel` itself). **And run it again immediately before merge** — a sweep cannot see a branch pushed after it ran.
- [ ] **Copy `SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql` to `src/main/resources/db/migration/`** — it already holds the header and **all three** statements (the view, the index, the `UNIQUE (client_id, item_nr)` assertion). Do not retype it. **Proof-read the header's numbers before the first apply**: Flyway's CRC32 covers comments, so the text freezes on first application.
- [ ] ⚠ **Proof-read the header's numbers before the first apply.** Flyway's CRC32 covers comments, so once this file has been applied on any tenant a wrong sentence in it cannot be corrected without a new migration. Specifically: **71 shared `item_nr` strings / 87 excess rows** (not "87 SKU strings").
- [ ] **After the index exists on dev, re-measure BOTH shapes under `plan_cache_mode = force_generic_plan` with bind parameters**, and record the plans and times back into §3.2. **(a) The read path** — the filtered first page; acceptance is `Index Cond: (client_id = $1)` present. **(b) The export path** — `findByClientOffsetAndLimit`'s `ORDER BY created DESC OFFSET/LIMIT`; acceptance is **the `Sort` node is gone**, not merely that an `Index Cond` is present. Pre-index that plan carries `Sort (Sort Key: created DESC)` over a `Parallel Index Scan` on the narrow `index_stockrecord_client_id`, estimated at 559 rows against up to 873,021 actual (§3.2). If the planner keeps the narrow index plus the sort, the composite index is not earning its 276 MB on the export path and that is a finding for the ticket, not something to leave unrecorded. The 0.455 ms figure is custom-plan-and-literal; the generic-plan claim currently rests on the qual's shape, because `hypopg` is not installed on that server (`pg_available_extensions` → 0; control: 61 rows) and building a 276 MB index was outside the read-only review lanes.
- [ ] Write `StockrecordViewSchemaIT` (§7.2) **first**, confirm it fails for the right reason (relation does not exist), then make it pass.
- [ ] Mutation-check: flip `LEFT JOIN … ON i.client_id = sr.client_id AND i.item_nr = sr.itemdata` to `ON i.item_nr = sr.itemdata` and confirm the zero-multiplication assertion goes red **and names the multiplication**; flip `LEFT` → `INNER` and confirm the unresolved-SKU assertion goes red; **delete the `DO $$ … $$` assertion block and confirm `StockrecordViewSchemaIT`'s new `constraintIsAsserted` case goes red** — otherwise the third statement is prose that happens to be executable.
- [ ] Ownership: this is a plain `CREATE` on a name that exists nowhere, so it needs only `CREATE` on schema `public`, not object ownership — materially safer than `V2.2.07`, which froze `wh01_hydra_v2` at `V2.2.06` on 2026-08-05 by trying to *replace* an object owned by someone else. The residual risk is schema-level; mitigate by verifying per tenant post-deploy (prereq 8).

**Independently reviewable because:** it adds a view nothing reads and an index nothing yet needs. Deployed alone it is inert apart from the one-time index build.

#### P2 — `StockrecordView` entity, repository, SDR registration
**Branch:** `feature/SBDEV-3410-p2-stockrecord-view-entity-sdr` (`v2/wms2-api`) — ⚠ **branch it only after P1
has merged to `develop`**; see §5.1 row 4 (`ddl-auto=validate` makes this a build-order dependency).

- [ ] `StockrecordView.java` per §3.3 — no `AbstractBaseEntity`, explicit `@Column` on every camelCase field, hand-written `equals`/`hashCode` on `id`, `created`/`modified` re-declared as `LocalDateTime`.
- [ ] `StockrecordViewRepository.java` per §3.4 — `ReadOnlyPagingAndSortingRepository`, **two** searches (`findByKeyword` unfiltered, `findByKeywordAndClient` with a **plain equality**, no `OR` arms), all three `findAll` overloads suppressed, and **one `KEYWORD_CLAUSE` constant concatenated into both** — not two verbatim copies, which would let the searched column set drift between the filtered and unfiltered paths (§3.4).
- [ ] `RestConfiguration`: add `StockrecordView.class` to `exposeIdsFor(...)` **and** to `SDR_WRITE_WITHDRAWN`.
- [ ] `SdrWriteWithdrawalContextTest`: add the 50th name, bump `hasSize(49)` → `50`, correct the "IDENTICAL — 49 names" javadoc. **Nothing else goes red if this is skipped** (§3.5).
- [ ] `StockrecordViewRepositoryFilterIT`, `StockrecordViewHalContextTest` and `StockrecordViewRepositoryQueryShapeUnitTest` (§7.2, §7.3) written first and failing. ⚠ `StockrecordViewHalContextTest` runs in an **H2** lane and must seed and flush its own row (§7.3) — a red there against correct code is the fixture, not the code.
- [ ] Mutation-checks, each with an **attributable** kill: remove `StockrecordView.class` from `exposeIdsFor` and confirm `StockrecordViewHalContextTest` goes red naming the missing `id`; add an `OR :clientId = -1` arm to `findByKeywordAndClient`'s `@Query` and confirm **`StockrecordViewRepositoryQueryShapeUnitTest.queryShapeForbidsADisjunction`** goes red naming the missing plain-equality conjunct. ⚠ **`filteredSearchKeepsAnIndexCondition` is NOT the killing test** — it holds its own EXPLAIN statement per the `OutboxClaimExplainIT` precedent, so the mutant's edit to the annotation never reaches what it reads (§7.2). ⚠ **Do not use "drop one `@Column(name = …)`"** — `EntityColumnNameResolutionArchTest` already reds on that, repo-wide and in **surefire**, before any IT runs, so the kill would be unattributable (§3.3 rule 3).
- [ ] Do **not** add an `SdrFunctionRules` entry (§3.5). Note the resulting `wms2.authz.sdr.unruled` label on the ticket.

**Independently reviewable because:** it exposes a new read route the UI does not yet call. **Not independently
deployable before P1** — that is the one phase boundary in this plan that is a hard pair.

#### P3 — Export respects the shipper
**Branch:** `feature/SBDEV-3410-p3-export-shipper-filter` (`v2/wms2-api`)

- [ ] `ReportController.exportStockUnitRecord`: `Long clientId = toFilterId(String.valueOf(reqMap.get("filter")));` — **never** `(String) reqMap.get("filter")` (§3.6).
- [ ] `ReportService.exportStockUnitRecord` gains `Long clientId` and **branches** on `clientId == null || clientId == -1L`; **no `@Transactional`** (§7.5 row 3).
- [ ] **Add** `StockrecordRepository.findByClientOffsetAndLimit` with `@RestResource(exported = false)` and a plain `p.client_id = CAST(:clientId AS bigint)`. **`findByOffsetAndLimit`'s rendered predicate stays byte-identical** — it is a live SDR route and an in-place predicate change empties it for every caller that omits the parameter (§3.6). The only edit to it is textual: lift its keyword clause into a `NATIVE_KEYWORD_CLAUSE` constant and concatenate it back, so the filtered and unfiltered exports cannot drift on what they search; `unfilteredExportRouteIsUnchanged` (§7.2) is the regression guard for the lift itself. Confirm the rendered SQL against the IT, not against this document.
- [ ] Extend the existing nested `ExportStockUnitRecord` classes in `ReportControllerUnitTest` and `ReportServiceUnitTest`. The four `when(stockrecordRepository.findByOffsetAndLimit(any(), anyInt(), anyInt()))` **stubs** keep compiling under the split — add stubs for the new method rather than widening theirs. ⚠ **But the service signature change breaks 11 four-argument call sites** (§0.1 row 21): 4 act lines in `ReportServiceUnitTest` and 7 stub/verify lines in `ReportControllerUnitTest`. Fix them in this phase; they are compile errors and the build will not start without them.
- [ ] Confirm both `Sbdev3017TrancheGateContextTest` rows (`/v3/report/...` **and** the inherited `/v3/dashboard/...`) stay green — `DashboardController extends ReportController`, so the signature change moves both routes.
- [ ] Mutation-checks: make the controller ignore `filter` (the controller unit test must go red naming the dropped filter); change the read back to `(String) reqMap.get("filter")` with a JSON-**number** body and confirm the test goes red — expect a **thrown `ClassCastException` out of the handler** (a nested `ServletException` in the MockMvc lane), **not** a 200 with an error body (§3.6).

#### P4 — `itemName` in the details popup
**Branch:** `feature/SBDEV-3410-p4-stock-record-details-item-name` (`v2/wms2-api`)

- [ ] `StockrecordService.getStockRecordDetails` per §3.7 — `ifPresent`, not `orElseThrow`.
- [ ] Extend `StockrecordServiceUnitTest`: key present when the SKU resolves, key **absent** when it does not.
- [ ] Mutation-check: swap `ifPresent` for an unconditional `details.put("itemName", null)` and confirm the absent-key assertion goes red (an `assertThat(map).doesNotContainKey("itemName")` distinguishes absent from null; `get() == null` does not).

#### P5 — `allClients` gate widening
**Branch:** `feature/SBDEV-3410-p5-allclients-stock-unit-record-function` (`v2/wms2-api`)

- [ ] `ClientController` `@RequiresFunction` + `Sbdev3017TrancheGateContextTest` row, **same commit**. **Three** constants, not one: `WEB_UI_VIEW_STOCK_UNIT_RECORD` (this ticket) plus `WEB_UI_VIEW_STOCK_UNIT` and `WEB_UI_VIEW_CONTAINER` (the already-live gap, §3.8). Eleven → fourteen.
- [ ] Restate both files' rotting count comments as the invariant (§3.8 edit 3).
- [ ] Mutation-check: remove **each** of the three constants from the annotation in turn; `Sbdev3017TrancheGateContextTest` must go red each time, with the message naming the missing one. The pin must carry the **full** varargs and keep at least one ungated row, or a class-level change can slip past it.
- [ ] Re-run the blast-radius query on `dev_wh01_om1` with its positive control before merge, **for all three functions**, and record the date — the figure is one tenant at one instant (Q6).

#### P6 — the UI
**Branch:** `feature/SBDEV-3410-p6-shipper-filter-and-sku-name` (`v2/wms2-web-ui`)

- [ ] `store/reports/stockUnit.js`: `shippers` / `shipperFilter` state; **merge-not-replace** `setFilters` and a `resetList` that resets `clientId: -1` alongside search and sort (§3.9, copied from `store/handlingUnits/stockUnits.js`); `searchReport` picks `/stockrecordView/search/findByKeyword` vs `.../findByKeywordAndClient` on `clientId === -1`, and appends `&clientId=` **from state** so a payload-less refresh keeps the filter. ⚠ **`== null` / `=== -1`, never `!data.clientId`** — `0` is a real shipper (§3.6).
- [ ] **Read the rows through `rowsOf(results, 'stockrecordView')`, never `results._embedded.stockrecordView`** (§3.9 item 4). ⚠ The reason is the **renamed-`collectionResourceRel`** case, not a zero-row `TypeError`: `_embedded` is **present with an empty array** on a zero-row page (measured — `SBDEV-3410-evidence/embedded-shape-measurement.md`), so the unguarded read is safe there and unsafe only when the rel moves. Six lines, shape copied from `store/admin/group.js` — **but not its comment, which asserts the opposite and is wrong** (§10.4).
- [ ] `stockUnitRecord.vue`: the shipper widget (**`<v-autocomplete … clearable>`**, decided — §3.9 — with **no** "All Shippers" sentinel row), `item-value="id"`, `shipper` as a **computed** backed by Vuex, `getClients` dispatch + `clients` watcher, SKU Name header with `sortable: false`, **`:filter="String(shipper == null ? -1 : shipper)"`**, `'itemName': 'SKU Name'` in `:field-names`, `updateTable` passing `clientId`.
- [ ] Reset the page to 1 when the shipper changes (the keyword watcher already does this: `this.options.page = 1`).
- [ ] `test/components/reports/stockUnitRecordShipperFilter.spec.js` — nearest existing shapes to copy: `test/components/handlingUnits/shipperSkuFilterBinding.spec.js` and `test/store/handlingUnitsShipperSkuFilter.spec.js`.
- [ ] Regression: confirm the SBDEV-2658 deep link still works — `?search={sku}` must still populate `keyword`, not the shipper.
- [ ] Mutation-check: make `shipper` a `data()` property and confirm **`expect('shipper' in wrapper.vm.$data).toBe(false)`** goes red. ⚠ **Do not grade it with `'filter' in $data === false`** — that cannot kill: the mutant introduces a key named **`shipper`**, which is not in `searchUrlSync`'s `possibleProps` (`['search', 'keyword', 'filter', 'searchText', 'query', 'searchQuery']`) at all, so that assertion stays green. It is also the weaker of the two: §3.9 already notes the `searchUrlSync` hazard is neutralised by `keyword` sorting first.
- [ ] Mutation-check: drop the `String(...)` — `:filter="String(shipper == null ? -1 : shipper)"` → `:filter="shipper == null ? -1 : shipper"` — and confirm the client-id-`0` Jest case goes red with *"expected `filter: \"0\"`, received `filter: null`"*. ⚠ **Do not use `→ :filter="shipper"` as the mutant**: that mutant and the un-stringified fold are byte-identical on `0`, which is the only value that discriminates, so it would kill for the wrong reason or not at all. The assertion must be on the **POST body `exportReport.vue` emits**, not on `wrapper.vm.filter`.
- [ ] ⚠ Per the standing note, **mounting with a value already present is not a reactivity test** — every spec above must change the value **after** mount and assert the emitted request.

---

## 6. Backward Compatibility

| Surface | Before | After | Breaking? |
|---|---|---|---|
| `GET /api/stockrecord/search/findByKeyword` | serves the report | unchanged, still exported, no longer called by this UI | **No** — Q5 (withdrawal) is left open |
| **`GET /api/stockrecord/search/findByOffsetAndLimit`** | a live, exported SDR route: `@RestResource(path = "findByOffsetAndLimit", …)` with **no `exported = false`** | **byte-identical.** The filtered variant is a separate `exported = false` method | **No — and this is the reason for the split.** Had the predicate been added in place, an SDR caller omitting `clientId` would bind it to `null`, both disjuncts of `(CAST(:clientId AS bigint) = -1 OR p.client_id = CAST(:clientId AS bigint))` evaluate to `NULL`, and the route would return `[]` rather than erroring. Measured on `dev_wh01_om1`: that predicate with `NULL` returns **0** where the unfiltered query returns **873,021** |
| `GET /api/stockrecord/search/findByClientOffsetAndLimit` | — | **does not exist as a route**: `@RestResource(exported = false)`; in-process caller `ReportService` only | **No** — nothing is added to the HTTP surface |
| `GET /api/stockrecordView/search/findByKeyword` | 404 | new route, `Page<StockrecordView>`, **unfiltered** | **No** — additive |
| `GET /api/stockrecordView/search/findByKeywordAndClient` | 404 | new route, `Page<StockrecordView>`, filtered, plain equality | **No** — additive |
| `POST /v3/report/exportStockUnitRecord` | ignores `filter` | honours `filter`; absent/null/`-1`/non-numeric all mean "no filter" | **No** — an old client that omits `filter`, or sends `null`, gets today's output |
| `POST /v3/dashboard/exportStockUnitRecord` | same handler by inheritance | same change | **No** |
| `GET /v3/stockrecord/stockRecordDetailsById/{id}` | 24 keys when the client resolves, 22 when it does not | adds `itemName` **when the SKU resolves** | **No** — additive; `fullDetails.vue` renders whatever keys arrive. ⚠ Do not turn this into a size assertion — the count is conditional |
| `GET /v3/client/allClients` | ANY-of 11 functions | ANY-of **14** | **No** — strictly widening; no user loses access |
| HAL payload of `stockrecordView` | — | carries `id` (`exposeIdsFor`), writes withdrawn (`SDR_WRITE_WITHDRAWN`) | **No** |
| DB schema | `stockrecord` + 13 indexes | + `stockrecord_view`, + `index_stockrecord_client_created`, + a migration-time assertion on `itemdata`'s unique constraint | **No** for readers; a `SHARE` lock on `stockrecord` once, at the deploy boot that applies `V2.2.33` — **~6 s / 276 MB on dev; milliseconds and kilobytes on hydra prd; unmeasured on both ShipItEZ prd databases** (§3.2) |
| Export spreadsheet | 15 columns | **15 columns** | **No** — Q2 fixes this |

### What Does NOT Change

- The 15 export column headers, their order, and their content. A downstream macro keying on column
  positions is unaffected.
- The nine existing sortable table columns and their behaviour. All nine resolve to projected columns of the
  view (§3.3 rule 4).
- The keyword search's five matched columns (`activitycode`, `fromstoragelocation`, `fromunitload`,
  `itemdata`, `operator`) — deliberately **not** widened to `item_name`/`cl_name` (§3.10).
- The default page's plan and cost: the unfiltered "All Shippers" read still plans as a bare
  `Parallel Seq Scan on stockrecord`, measured at +1% to +5%, inside noise.
- `stockrecord` write paths. The 7 `new Stockrecord()` sites in `StockrecordService`, the one in
  `StockunitBusinessService` and the `recordRelocation` call in `FixLocationAssignmentService` are untouched;
  the view is read-only.
- `SdrFunctionRules` — 7 rules before, 7 after, and **no new enforcement gap** because SDR read enforcement is
  OFF on every tenant measured. ⚠ It is **not** a no-op in payload terms: the new unruled route serves
  `item_name`, `cl_nr` and `cl_name` alongside the `stockrecord` columns the existing unruled route already
  serves. §3.5 states the widening rather than smoothing it.
- The `clients` Caffeine cache and its `@CacheEvict` sites.
- `v1/wms-api` and both mobile UIs. This is a v2-only, web-UI-only change.
- SBDEV-2658's adjustment-alert deep link: `?search={sku}` still binds to `keyword`.

---

## 7. Testing Strategy

### 7.1 Lane facts that decide where each test goes

Only the facts that decide **where this ticket's tests go**. The repo-wide lane traps that are true of every
ticket (the `-Dit.test` exclusion trap, `mvn`-without-`clean` stale XML, the `,`-not-`+` selector rule, the H2
verdict) belong in `CLAUDE.md`, not here:

- **`*IT.java` DOES run in failsafe**, since SBDEV-3239 — the pom's `<includes>` carries `**/*IT.java`
  alongside `**/*IntegrationTest.java` and `**/*E2ETest.java`, and `<excludes/>` is empty.
- **`*ContextTest` runs in SUREFIRE** — surefire excludes only `*IntegrationTest` and `*E2ETest`. So
  `StockrecordViewHalContextTest`, which needs a MockMvc request, still runs in the fast lane, alongside
  `Sbdev3017TrancheGateContextTest` and `SdrWriteWithdrawalContextTest`.
- **CI runs `mvn verify`, not `mvn test`**, and the PR check is **advisory** — a green PR check is not a gate;
  the implementer's own `mvn verify` is.
- Both export tests live in nested classes named `ExportStockUnitRecord`, so run the whole **outer** class:
  `-Dtest='Outer#method'` matches nothing for a JUnit 5 `@Nested` test and reports 0 + SUCCESS.
- The Testcontainers harness migrates `classpath:db/migration`
  (`AppPostgresDBSetupExtension`: `static final String MIGRATION_LOCATION = "classpath:db/migration";`) — so a
  Flyway view/DDL change **has** a Testcontainers surface and does not qualify for any "no Java test surface"
  gate-skip. That profile also runs `ddl-auto=validate` (SBDEV-3285), which is what makes P1→P2 a build-order
  dependency (§5.1 row 4).

### 7.2 Integration tests (failsafe / Testcontainers)

| Test class | Method | What it asserts |
|---|---|---|
| `StockrecordViewSchemaIT` *(new, `src/test/java/net/aim_ai/wms/integration/schema/`, modelled field-for-field on `ReplenishmentMonitorViewSchemaIT`)* | `viewExistsAfterMigrate` | `stockrecord_view` is present in `information_schema.views` after a full `db/migration` migrate |
| `StockrecordViewSchemaIT` | `everyMappedColumnResolves` | Reflection over `StockrecordView`'s `@Column`/field names reconciled against `information_schema.columns` — the check that would have caught SBDEV-3247 |
| `StockrecordViewSchemaIT` | `viewMultipliesZeroRows` | `count(*)` through the view == `count(*)` on `stockrecord`, on a fixture containing **at least two clients sharing one `item_nr`** |
| `StockrecordViewSchemaIT` | `unresolvedSkuRowSurvivesWithNullItemName` | A `stockrecord` row whose `itemdata` string resolves to no `itemdata` row still appears, with `item_name IS NULL` |
| `StockrecordViewSchemaIT` | `everyUiSortKeyResolves` | The nine sortable header `value`s resolve as properties of `StockrecordView`, **asserted by reflection over a single source-of-truth list**, not nine hand-written cases |
| `StockrecordViewSchemaIT` *(new)* | `constraintIsAsserted` | Dropping `itemdata`'s `UNIQUE (client_id, item_nr)` before the migrate makes `V2.2.33` fail — this is what makes §3.1's third statement an assertion rather than a comment. **Recipe — copy `BillofladingTransferIdNotNullIT`, in the same package this class goes in** (`net/aim_ai/wms/integration/schema/`). It carries both halves this case needs, already written: a `private void migrateTo(String url, String target)` helper that does `cfg.target(MigrationVersion.fromVersion(target))` (`null` ⇒ migrate to head), and a cause-chain walker that returns *"the SQLSTATE of the first `SQLException` in the cause chain"*. So: `migrateTo(url, "2.2.32")` → `ALTER TABLE itemdata DROP CONSTRAINT …` → `catchThrowable(() -> migrateTo(url, null))` → assert the SQLSTATE. ⚠ **Do NOT copy `OutboxItFlyway`** — `BillofladingTransferIdNotNullIT`'s own javadoc records that an earlier revision of that harness copied `executeInTransaction(false)` + `setTransactionalLock(false)` from `OutboxItFlyway` *"without needing either"*, which *"pinned a materially worse aftermath than production's: a `success=f` history row, and every later `V2.2.x` then blocked behind `Validate failed` until an operator ran `flyway repair`"*. (`Flyway.configure()` appears in 17 test files, but `.target(` in exactly two — this one and `CancellationLogPickingorderPositionIdIT`; derived by `git grep -n '\.target(' origin/develop -- src/test`. Blind spot: a `target` built from a variable inside a helper would not match.) ⚠ **Assert the SQLSTATE, not the text.** Flyway wraps the cause and its message quotes the **script filename**, so `hasMessageContaining(<any word from the DO block>)` passes for essentially any failure of that script. A bare `RAISE EXCEPTION` gives **P0001** — assert that, and keep the message check as a secondary |
| `StockrecordViewRepositoryFilterIT` *(new)* | `filterReturnsOnlySelectedShipper` | Row set **and** `page.totalElements` — **AC-4's named regression**: `totalElements` equals the filtered count, not the unfiltered one |
| `StockrecordViewRepositoryFilterIT` | `clientIdZeroIsARealShipper` *(new)* | `findByKeywordAndClient(…, 0L, …)` returns **only** the rows whose `client_id` is 0, on a fixture that also carries another client's rows. Asserted **by id** (repository tests here commit) |
| `StockrecordViewRepositoryFilterIT` | `keywordAndFilterAndSortAndPageCompose` | The **four named** combinations of AC-4 — (a) filter alone, (b) filter + keyword, (c) filter + `sort=created,asc` asserting the first row's `created` is the filtered minimum, (d) filter + page 2 disjoint from page 1 — each asserting rows **and** `totalElements` |
| `StockrecordViewRepositoryFilterIT` | `filteredSearchKeepsAnIndexCondition` *(new)* | `EXPLAIN` of the `findByKeywordAndClient` shape under `plan_cache_mode = force_generic_plan` contains `Index Cond` on `client_id` and **not** `Seq Scan`. ⚠ **This test does NOT on its own protect the split** — the mutant edits the `@Query` annotation, and the repo's only EXPLAIN precedent (`OutboxClaimExplainIT`) holds its statement in a **hand-copied constant** (`private static final String GATE_PROBE_SQL`), so a test written to that precedent never reads what the mutant changed and stays green. There is no `StatementInspector` and no `hibernate.SQL` capture anywhere in `src/test`, so nothing today binds a test's EXPLAIN to a repository's rendered SQL. The mutant is killed by `queryShapeForbidsADisjunction` in §7.3 instead; **keep this test for what it does grade** — that a plain equality *is* index-backed under a generic plan. ⚠ Its fixture needs enough rows for the planner to prefer the index — on a 10-row Testcontainers fixture a seq scan is correct and the assertion is vacuous; pin the plan **shape** with `SET enable_seqscan = off` as the control. That control was verified to *discriminate* rather than merely to force a pass: `enable_seqscan = off` is a `1e10` cost penalty, not a prohibition, and the three-arm `OR` form has **no** index path at any table size (its keyword arm references five unindexed columns, so there is no index-only path either) — so under the control the correct form plans `Index Scan` + `Index Cond` and the mutant plans `Seq Scan` at penalty cost. Do not remove the control as unproven |
| `StockrecordViewRepositoryFilterIT` | `exportPredicateRendersOnPostgres` | The native `CAST(:clientId AS bigint)` form in the **new** `findByClientOffsetAndLimit` executes without a "could not determine data type of parameter" error |
| `StockrecordViewRepositoryFilterIT` | `unfilteredExportRouteIsUnchanged` *(new)* | `findByOffsetAndLimit(keyword, 0, 100)` returns the same row set it returns today — the regression guard for the route §3.6 deliberately did not touch |
| `StockrecordViewRepositoryFilterIT` | `clientWithNoRowsReturnsAnEmptyPage` *(new)* | `findByKeywordAndClient("", <a client id with no stockrecord rows>, PageRequest.of(0, 10))` returns `content` empty **and** `getTotalElements() == 0` — the repository half of the zero-row case. ⚠ Round 4: the UI half is in §7.4 and it does **not** carry a live defect — SDR renders a zero-row page as `_embedded: { stockrecordView: [] }` (measured), so an unguarded read is safe there. This row is the pair's API side and grades AC-4's `totalElements`, which is a real regression surface independent of all that. Fixture: a client committed with no `stockrecord` rows (these tests commit — assert on **that** client's id, never `isEmpty()` over a shared table) |

⚠ **Repository tests in this repo COMMIT, they do not roll back** (wrong transaction manager). Assert **by
id**, never `isEmpty()` / `hasSize()` — a sibling's fixture leaks into yours. And a bare `@PersistenceContext`
with no qualifier is the **landlord** EntityManager.

### 7.3 Unit tests (surefire)

| Test class | Method | What it asserts |
|---|---|---|
| `ReportControllerUnitTest` → nested `ExportStockUnitRecord` *(extend; today it ends at `verify(reportService).exportStockUnitRecord(any(HttpServletResponse.class), eq(0), eq(100), eq("STOCK789"))`)* | `numericFilterIsForwarded` | A body with `"filter": 60500` (a JSON number) reaches the service as `60500L`. ⚠ **Assert the forwarded value, not "does not throw"** — the pre-fix cast throws *out of* the method (§3.6), so in the MockMvc lane `mockMvc.perform(...)` itself raises a nested `ServletException` and there is no status to assert on; a "does not throw" test would have to catch, which grades the wrong thing |
| `ReportControllerUnitTest` → nested `ExportStockUnitRecord` | `filterValueMatrix` | **The AC-2 matrix, parameterised:** key absent · JSON `null` · `-1` · `""` · `"abc"` → `-1L`; `60500` → `60500L`; **`0` → `0L`, NOT `-1L`** |
| `ReportServiceUnitTest` → nested `ExportStockUnitRecord` | `filterReachesRepository` | `clientId = 60500L` ⇒ `verify(stockrecordRepository).findByClientOffsetAndLimit(eq("k"), eq(60500L), anyInt(), anyInt())`; `clientId = 0L` ⇒ the same with `eq(0L)`; `-1L` and `null` ⇒ `verify(stockrecordRepository).findByOffsetAndLimit(...)` and `verify(stockrecordRepository, never()).findByClientOffsetAndLimit(any(), anyLong(), anyInt(), anyInt())` |
| `StockrecordViewHalContextTest` *(new — `src/test/java/net/aim_ai/wms/security/`, `extends BaseControllerIntegrationTest` with `@AutoConfigureMockMvc`, the lane `SdrReadGateEnforcementContextTest` already uses)* | `idIsInTheHalBody` | `mockMvc.perform(get("/v3/stockrecordView/search/findByKeyword?keyword=&page=0&size=1"))` and `$._embedded.stockrecordView[0].id` exists. **Without this test §7.8's `exposeIdsFor` mutant has nothing to execute it**: `exposeIdsFor` affects HAL *rendering*, which neither the schema IT nor a repository IT can see, and §8 step 3 checks it by hand. ⚠ **This lane cannot supply the row on its own — seed one.** `BaseControllerIntegrationTest` → `BaseIntegrationTest` is `@ActiveProfiles("integration")` and `application-integration.properties` carries `jdbc:h2:mem:wms_integration`, `ddl-auto=create-drop`, `spring.flyway.enabled=false`, `app.flyway.migrate-on-startup=false` — so `stockrecord_view` there is an **empty Hibernate-created table**, not the migrated view, and the JSON path resolves against nothing. Insert one `StockrecordView`-shaped row through the tenant `EntityManager` (or `jdbcTemplate`) in `@BeforeEach` and **flush**, because `BaseIntegrationTest` is `@Transactional("tenantTransactionManager")` and the MockMvc request will not otherwise see it. Do **not** repair a red here by weakening the assertion to `status().isOk()` — the sibling `SdrOmittedPrimitiveParamSearchContextTest` records why that reads as a pass (*"200 with an empty `_embedded`, which is the answer that actually proves the route resolves"*) while un-killing this mutant |
| `StockrecordViewRepositoryQueryShapeUnitTest` *(new, `src/test/java/net/aim_ai/wms/unit/repo/`)* | `queryShapeForbidsADisjunction` | **This is the test that kills the fold-it-back-into-one-method mutant**, which `filteredSearchKeepsAnIndexCondition` cannot (§7.2). It reflects on the annotation the mutant edits — the repo's own idiom, `StockrecordRepositoryAdjustmentAlertQueryTest` does exactly this (`StockrecordRepository.class.getMethod(…).getAnnotation(Query.class).value()`), in surefire, with no context. Three lines, executed against the correct text and five mutants before being written down: <br>`String jpql = raw.replaceAll("\\s+", " ");` <br>`assertThat(jpql).contains("AND p.clientId = :clientId");` <br>`assertThat(jpql.substring(jpql.indexOf("AND p.clientId")).toUpperCase(Locale.ROOT)).doesNotContain(" OR ");` <br>⚠ **Take the tail, do not scan the whole string.** The keyword arm legitimately carries `or :keyword = ''` (lower-case, inherited from the `StockView` precedent), so a whole-string `doesNotContain(" OR ")` either reds on correct code or passes vacuously depending on its casing. Slicing at the `clientId` conjunct and upper-casing the tail is what makes it both green on correct code and red on a lower-case `or` mutant |
| `ReportServiceUnitTest` → nested `ExportStockUnitRecord` | `fifteenColumnsUnchanged` | The header names and their order are byte-identical to today's |
| `StockrecordServiceUnitTest` | `detailsCarryItemNameWhenSkuResolves` | `itemName` present |
| `StockrecordServiceUnitTest` | `detailsOmitItemNameWhenSkuDoesNotResolve` | `assertThat(details).doesNotContainKey("itemName")` — **absent**, distinct from null |
| `Sbdev3017TrancheGateContextTest` *(extend)* | the `allClients` `row(...)` | All **three** of `WEB_UI_VIEW_STOCK_UNIT_RECORD`, `WEB_UI_VIEW_STOCK_UNIT`, `WEB_UI_VIEW_CONTAINER` are in the ANY-of list, with the **full** varargs restated |
| `SdrWriteWithdrawalContextTest` *(extend)* | `hasSize(50)` + the set | `StockrecordView` is in `WITHDRAWN`, and the set still matches `RestConfiguration.SDR_WRITE_WITHDRAWN` exactly |
| `Sbdev3017TrancheGateContextTest` *(no edit)* | the two `exportStockUnitRecord` rows | Must stay green through P3's signature change |

⚠ **Mockito trap directly in scope:** when writing a `verify(..., never())` for the "filter not forwarded"
direction, do **not** widen a primitive parameter to `any()` — `any()` returns `null` and the call NPEs at
unboxing. Use `anyLong()` / `anyInt()`.

### 7.4 Frontend tests (jest, `yarn test` in `v2/wms2-web-ui`)

| Spec | What it asserts |
|---|---|
| `test/components/reports/stockUnitRecordShipperFilter.spec.js` | The shipper widget renders (`wrapper.find('#shipper').exists()`); it mounts **empty** — `shipper` is `null` and the first request is unfiltered (there is no "All Shippers" item to be selected, §3.9); **`expect('shipper' in wrapper.vm.$data).toBe(false)`** (the computed rule); changing the selection **after mount** dispatches `searchReport` with the new `clientId` and resets the page to 1; with the field empty or cleared the request targets **`findByKeyword`** with **no `clientId` on the URL** (AC-1); a shipper selection targets **`findByKeywordAndClient`** with `&clientId=N`; `?search={sku}` still binds to `keyword`. <br>**Three cases carry defects nothing else in this plan can see:** <br>• **client id `0`** — selecting `System-Client` produces a table request on `findByKeywordAndClient` with `&clientId=0`, **and an export POST whose body carries `filter: "0"`**. ⚠ **Assert on the request body `exportReport.vue` builds, not on `wrapper.vm.filter` or on the prop.** The whole defect lives *downstream of the prop*, inside the shared component's `this.filter && …` guard, so a prop-level assertion certifies the bug (§3.6). Mount the real `<export-report>` (or stub it at the `$post` boundary) and read the emitted body. <br>• **a zero-row response** — the fixture is **`{ _embedded: { stockrecordView: [] }, page: { totalElements: 0 } }`**, which is the shape SDR actually sends (measured; `SBDEV-3410-evidence/embedded-shape-measurement.md`). It must leave `reportItems` as `[]` and `totalItems` as `0`. ⚠ **This case grades AC-4's empty-page behaviour and nothing about `rowsOf`** — against the real shape the guarded and unguarded reads are identical, so it cannot kill the `rowsOf` mutant. Do not write it as if it could; §7.8 routes that mutant to the case below instead. <br>• **a renamed-rel response** *(this is the `rowsOf` case)* — a payload carrying `_embedded` with the **wrong** rel (`{ _embedded: { stockrecord: [] }, page: { totalElements: 0 } }`, i.e. the `collectionResourceRel` reverted) must **not** commit: `reportItems` keeps its previous value and the error toast fires. Unguarded, `results._embedded.stockrecordView` is `undefined` and the store commits `undefined` — a broken grid reported as zero rows. <br>**Three cases the `<v-autocomplete>` decision adds** (§3.9), none of which a `<v-select>` would have needed: typing a fragment of a shipper **name** and, separately, of its **`cl_nr`** both narrow `shippers`, because `item-text` is `name (clNr)`; **clearing** the field (not selecting a sentinel row) sets the model to `null` and dispatches with `clientId: -1` on the unfiltered route; and `shippers` contains **no** `{ id: null, label: 'All Shippers' }` entry. ⚠ Select the System-Client **item** for the `0` case — typing `0` does not find it, because nothing filters on `id` |

⚠ **Mounting with a value already present is not a reactivity test** — a `data()` snapshot once passed 8/8
against a component that never reacted. Change the value after mount and assert the emitted request.

### 7.5 v2-only constraint checklist

| # | Constraint | Verdict | File evidence |
|---|---|---|---|
| 1 | **Jakarta namespace** | `StockrecordView` imports `jakarta.persistence.*`, never `javax` | `StockView.java`: `import jakarta.persistence.*;` |
| 2 | **OSIV off** | **Unaffected.** A read-only flat view entity with no lazy associations is fully materialized by the repository | `src/main/resources/application.properties`: `spring.jpa.open-in-view=false`; same line in `src/test/resources/application-integration.properties` and `application-postgres-integration.properties` |
| 3 | **Transaction manager / `readOnly`** | **No `@Transactional` added anywhere.** SDR reads open their own read-only tx. `ReportService` deliberately exports outside a transaction, and the reason applies verbatim: *"Not @Transactional: the repository returns a fully materialized list of a flat view entity (no lazy associations), so OSIV-off is a non-issue; wrapping the Excel build + response streaming in a tx would only pin a tenant connection for the whole HTTP response."* If any new service method were added, the package rule binds: bare `@Transactional` means **landlord** in `service`, **tenant** in `repo.jpa` | `ReportService.java`, `exporLockReport` javadoc |
| 4 | **Hibernate naming strategy** | ⚠ **The tenant persistence unit gets NO naming strategy.** Every camelCase field on `StockrecordView` needs an explicit `@Column(name = "…")`, or it 500s at runtime on a column that does not exist. **What catches it:** the *missing-annotation* case is already caught repo-wide, earlier, by `EntityColumnNameResolutionArchTest` in **surefire**, and the `postgres-integration` profile's `ddl-auto=validate` catches it again on every context load. `everyMappedColumnResolves` earns its place on the gap those two leave, which that same javadoc names: *"Hibernate's validator reports the FIRST mismatch and stops, and it verifies a mapped column EXISTS with a compatible type — it does not enforce nullability and ignores columns no entity maps."* A reflection check that enumerates **all** of `StockrecordView`'s columns in one pass is strictly stronger than a validator that stops at the first | `ReplenishmentMonitorViewSchemaIT` javadoc (SBDEV-3247); `EntityColumnNameResolutionArchTest`. ⚠ **`StockView` declares 12 persistent fields**, all 12 carrying `@Column` — but only **11** carry `@Column(name = …)`; the twelfth, `transfer`, is `@Column(columnDefinition = "numeric")` with no `name` and identity-resolves because its Java name is all-lowercase. "Annotates all eleven of its columns" was wrong on both numbers |
| 5 | **SDR registration** | `exposeIdsFor` **must** gain `StockrecordView.class`; `SDR_WRITE_WITHDRAWN` **must** gain it too — required, not parity (§3.5: `ReadOnlyPagingAndSortingRepository` suppresses only `save`/`saveAll`, so the delete verbs stay exported); the repository extends `ReadOnlyPagingAndSortingRepository` and suppresses all three `findAll` overloads | `RestConfiguration.java`: `config.exposeIdsFor(… Stockrecord.class, Stockunit.class, StockView.class, …)`; `StockViewRepository.java` |
| 6 | **Caffeine cache invalidation** | **No new cache.** The view is not cached. The dropdown's source already is, and its eviction already exists | `CacheConfig.java`: `buildCaffeineCache("clients", 100, Duration.ofMinutes(5))`; `ClientController.java`: `@CacheEvict(value = "clients", allEntries = true)` |
| 7 | **Micrometer** | **No new metric.** `wms2.authz.sdr.unruled{domainType=...}` gains a label value because `StockrecordView` is exported without an `SdrFunctionRules` entry — expected, not a regression. No alert is proposed: nothing scrapes Prometheus in this environment yet, so a metric would not be a working control | `SdrFunctionGuard.java`: `METRIC_SDR_UNRULED` |
| 8 | **Flyway / migration conventions** | Version sweep re-run immediately before merge; `CREATE OR REPLACE VIEW` is idempotent; ownership risk is schema-level not object-level because the name exists nowhere; no new `*.properties` file, so the `.gitignore`-swallow trap does not apply; **Testcontainers, not H2**, is the DDL lane | `db/migration/README.md`; `V2.2.32` header; `AppPostgresDBSetupExtension`: `MIGRATION_LOCATION = "classpath:db/migration"` |

### 7.6 Horizontal Scalability Validation

**Seven of the ten standing concerns are "No" for the same reason and are not tabulated individually: this is
a read-only change on the request thread.** In-JVM state (#1) — no new static, `ThreadLocal`, map or cache;
the entity is stateless. Scheduled jobs (#3) — nothing `@Scheduled` added or touched. Long transactions (#4) —
SDR reads open one short read-only tx; the export opens none. Request affinity (#5) — filter state lives in
Vuex and on the query string, so every request is self-describing. Retry/idempotency (#6) — N/A, there is no
write. Tenant context (#7) — no `@Async`, `CompletableFuture` or job thread; `TenantFilter` has already set
the context. External notifications (#10) — N/A.

The three that need a verdict rather than a dismissal:

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 2 | **Connection pool math** | **No** — but load-bearing | No new pool, no new tenant, no longer-held connection. The export deliberately runs **outside** a transaction and **must stay that way**: a 10,000-row export pinning a tenant connection for the whole HTTP response would be a pool-slot regression, and pool exhaustion counts slots, not milliseconds. The stance is documented in-source in `ReportService.java`'s `exporLockReport` javadoc, and P3 adds no `@Transactional` |
| 8 | **Distributed lock correctness** | **No new lock — but a one-time DDL lock** | `CREATE INDEX` takes a `SHARE` lock on `stockrecord`, per tenant, at the deploy boot that applies `V2.2.33`, blocking stock movements for that window. **~6 s on dev (9.7 M rows, 276 MB, measured in a rolled-back transaction); milliseconds on hydra prd (3,373 rows / 728 kB); unmeasured on both ShipItEZ prd databases** — §3.2 carries the per-environment table and the MCP-alias blind spot. Accepted by Nam (Q3). `StartupFlywayMigrator` runs on every boot of every replica and concurrent replicas serialize on Flyway's per-DB lock, so the stall happens once, not once per replica |
| 9 | **Cache invalidation** | **No** | Nothing writes to a cached entity. The `clients` Caffeine cache (`CacheConfig.buildCaffeineCache("clients", 100, Duration.ofMinutes(5))`, three `@CacheEvict` sites, unchanged) is JVM-local under `@Profile("!redis")`, so a `@CacheEvict` on one replica clears only that replica — a property the dropdown **already has** on the seven sibling reports and the two Handling Units grids, and which this ticket does not change |

### 7.7 Manual Test Plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Dropdown renders and defaults | dev (`dev_wh01_om1`) | Reports → Stock Unit Record | A "Filter by Shipper" `<v-autocomplete>` is present and **empty** (its placeholder shows; there is no "All Shippers" row to select — clearing the field is "All Shippers"); table unchanged from today. Type three letters of a shipper name and of a `cl_nr` — both narrow the list, because `item-text` is `name (clNr)` | |
| Filter narrows the table | dev | Select shipper **ARW** | Only ARW rows; `totalItems` drops to ARW's count. ⚠ **Expected timing is NOT "well under a second."** The data query becomes sub-millisecond with the index, but SDR issues a `count` on every `Page` and the filtered count for ARW measured **0.6–1.7 s** on dev across two independent runs (`Heap Fetches: 873021` — heap-bound, and the composite index does not remove it). Expect **~1–2 s total for the largest shipper on dev**, dominated by the count; small shippers are fast. A first page that takes 3 s is not a pass, a first page that takes 1.2 s is | |
| Filter + keyword compose | dev | Select ARW, type a keyword matching one of the five searched columns | Rows satisfy both; pagination footer count is consistent with the rows shown | |
| Filter + sort compose | dev | With ARW selected, sort by Time Stamp asc then desc | Ordering flips; no 500; still sub-second | |
| Filter + pagination | dev | With ARW selected, page 1 → 3 → back to 1 | Rows differ per page; returning to page 1 shows the original rows | |
| Reset to All Shippers | dev | **Clear** the widget (the ✕; there is no "All Shippers" item) | Unfiltered set returns; the request targets **`/stockrecordView/search/findByKeyword`** (the unfiltered method), not `findByKeywordAndClient`, and carries **no `clientId`** (check DevTools Network) | |
| **System-Client (`id = 0`) is filtered, not ignored** | dev | Select the shipper named **System-Client**, then Export | Table shows only its rows (16 on `dev_wh01_om1`); the request carries `clientId=0` and the export body carries `filter: "0"` (a **string**, in DevTools); the `.xlsx` contains **only** those rows. ⚠ This is the C-1 regression — a pass here is `0` surviving every guard on the path | |
| **A zero-row page empties the grid** | **dev** | Select a shipper with rows, let the grid load, then type a keyword that matches nothing (e.g. `ZZZNOPE`) | The grid empties, the footer reads 0, and **no error toast appears**. ⚠ **Round 4 restated this row's environment AND its pass condition.** It used to be run on hydra PRD on the theory that a zero-row page was a `TypeError` and dev could not produce one. Both halves were wrong: SDR sends `_embedded: { stockrecordView: [] }` (measured — `SBDEV-3410-evidence/embedded-shape-measurement.md`), so a zero-row page is ordinary, dev reaches it with any non-matching keyword, and the row grades **AC-4's empty page**, not `rowsOf`. The `rowsOf` guard is graded by §7.4's renamed-rel Jest case, which is the only surface that can see it | |
| Zero-row page from the **filter alone**, on a tenant where one exists | **hydra PRD** | Select **System-Client** from the dropdown | Same expectation as the row above. This variant exists because a shipper that is *selectable and owns nothing* is a real end-user state, and `dev_wh01_om1` cannot produce it — System-Client owns **16** `stockrecord` rows there and **0** on hydra PRD (§3.6). Optional if the dev row passes; it adds the dropdown to the path, nothing more | |
| SKU Name column | dev | Inspect a row whose SKU exists in `itemdata` | SKU Name populated; the column header shows **no sort arrow** | |
| SKU Name for an unresolvable SKU | dev | Find a `stockrecord` row whose `itemdata` matches no `itemdata` row (construct one if none exists) | The row is **still listed**, SKU Name blank — not missing from the report | |
| Details popup | dev | Click the eye icon on any row | Popup opens (proving `id` is in the HAL body), shows "SKU Name" alongside "Shipper Name"/"Shipper Code" | |
| Export respects the filter | dev | Select ARW → Export → open the `.xlsx` | Only ARW rows; **15 columns, unchanged headers**; no error string in the file | |
| Export with All Shippers | dev | Clear the widget → Export | Same output as before this ticket; the POST body carries `filter: "-1"` | |
| Export returns a real workbook | dev | DevTools → confirm the response is a spreadsheet | Valid workbook opens in Excel/LibreOffice. ⚠ **This row is not the `ClassCastException` detector** — that cast throws above the `try`, so its symptom is a **500**, not a 200 with a bad body. §7.3's `numericFilterIsForwarded` is the detector; this row grades the response shape only | |
| SBDEV-2658 deep link regression | dev | Trigger an adjustment alert toast → click View (`?search={sku}`) | The **keyword** box is populated, not the shipper | |
| Dropdown for a narrowly-privileged user | dev | Log in as a user holding `WEB_UI_VIEW_STOCK_UNIT_RECORD` and none of the other eleven (create one if none exists — on `dev_wh01_om1` there are currently 0) | Dropdown is **populated**, not empty | |
| Post-deploy per-tenant DDL check | dev DB, then UAT DB | `SELECT table_name FROM information_schema.views WHERE table_name='stockrecord_view';` · `SELECT indexname FROM pg_indexes WHERE tablename='stockrecord' AND indexname='index_stockrecord_client_created';` · **`SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='public.itemdata'::regclass AND contype='u';`** | One row each, **per tenant**, the third returning `UNIQUE (client_id, item_nr)` — do not infer any of it from a healthy application. ⚠ Run this against **each tenant database by name**, not through an MCP alias: all three prd aliases resolve to `wh01_hydra_v2` (§3.2), so an alias-driven check reads one database three times and reports full coverage | |
| Unfiltered default has not regressed | dev DB | `EXPLAIN (ANALYZE, BUFFERS)` the unfiltered count over `stockrecord_view`, same methodology as §3.1 | Plan is still a bare `Parallel Seq Scan on stockrecord sr`; time within noise of the 7,356/7,647 ms baseline | |

### 7.8 Mutation checks — every new assertion, with an attributable kill

Use **PIT scoped to the changed class**, per the pom's own instruction (`parseSurefireConfig MUST stay false`;
recipe at `sbdocs/9-System/mutation-testing-recipe.md`) — not a hand-rolled harness, which has lied here
before. The kill must be **attributable**: the failure message names the thing broken.

```bash
mvn test-compile
mvn org.pitest:pitest-maven:mutationCoverage \
    -DtargetClasses=net.aim_ai.wms.service.StockrecordService \
    -DtargetTests=net.aim_ai.wms.unit.service.StockrecordServiceUnitTest
```

SQL-level and schema-level assertions are not PIT-reachable; those are mutated by hand, by editing the
migration or the entity and re-running the IT.

Each row names the test that goes red and what its message must say. Three rows below carry an explicit
⚠ **cannot kill** note naming a mutant that looks right and is not — those are the failure mode this table
exists to prevent, and each was established by executing the mutant against the assertion rather than by
reading it.

| Assertion | Mutant that must turn it red | Test that reds, and the attributable message | Fixture the mutant needs |
|---|---|---|---|
| zero-multiplication | `ON i.client_id = sr.client_id AND i.item_nr = sr.itemdata` → `ON i.item_nr = sr.itemdata` | `StockrecordViewSchemaIT.viewMultipliesZeroRows` — "view returned N rows, stockrecord has M" | **two clients sharing one `item_nr`** — without that row the mutant survives |
| LEFT vs INNER | `LEFT JOIN` → `JOIN` | `StockrecordViewSchemaIT.unresolvedSkuRowSurvivesWithNullItemName` — names the vanished id | a row whose `itemdata` string resolves to nothing — on real data that set is empty (0 of 9,726,795 on `dev_wh01_om1`), so the fixture must construct it |
| the constraint assertion *(new)* | delete the `DO $$ … $$` block from `V2.2.33` | `StockrecordViewSchemaIT.constraintIsAsserted` — migrate succeeds where it must fail | a schema with the unique constraint dropped before the migrate |
| the filter predicate stays indexable *(new)* | add `OR :clientId = -1` to `findByKeywordAndClient`'s `@Query` | ⚠ **`StockrecordViewRepositoryQueryShapeUnitTest.queryShapeForbidsADisjunction`** (§7.3) — **two messages are possible and both are correct kills**: assertion 1, *"expected the JPQL to contain `AND p.clientId = :clientId`"*, fires for the 3-arm `OR`, the `COALESCE` form, the deleted conjunct and the `AND (p.clientId = :clientId OR :clientId = -1)` form; assertion 2, *the sliced tail contained `" OR "`*, fires for the un-parenthesised tail and the lower-case `or` tail. Do not "fix" a correct red because the message did not match this row. Executed against this mutant and four others (3-arm `OR`, un-parenthesised `OR` tail, the `COALESCE` sibling form, the conjunct deleted, a lower-case `or` tail): green on the correct text, red on all five. **`filteredSearchKeepsAnIndexCondition` is NOT the killing test** — it holds its own EXPLAIN statement, per `OutboxClaimExplainIT`, so the mutant's edit to the annotation never reaches what it reads (§7.2) | none — reflection only, surefire, no context |
| ~~column resolution~~ **DROPPED** | ~~drop one `@Column(name = "…")`~~ | **Dropped as unattributable.** That mutant reds `EntityColumnNameResolutionArchTest` (surefire, repo-wide, first), *every* `postgres-integration` context load, **and** the new schema IT. A mutant that reds a whole lane does not meet this table's own standard. The rail already covers it | — |
| export filter | make `ReportController` ignore `filter` | `ReportControllerUnitTest.filterValueMatrix` — names the dropped filter | none |
| export filter type | change the read back to `(String) reqMap.get("filter")` | `ReportControllerUnitTest.numericFilterIsForwarded` — ⚠ expect a **thrown `ClassCastException` out of the handler** (nested `ServletException` in the MockMvc lane), **not** a 200 with an error body (§3.6) | a body whose `filter` is a JSON **number** |
| client id `0` reaches the wire *(new)* | drop the `String(...)`: `:filter="String(shipper == null ? -1 : shipper)"` → `:filter="shipper == null ? -1 : shipper"` | the Jest client-id-`0` case — *"expected `filter: \"0\"`, received `filter: null`"*, asserted on the **emitted POST body** | the `System-Client` row (`id: 0`) in the mocked `clients` payload. ⚠ The mutant `→ :filter="shipper"` **cannot kill**: it is byte-identical to the un-stringified fold on `0`, the only discriminating value |
| the renamed-rel response is not read as zero *(new — RE-POINTED in round 4 against the measurement)* | drop the `rowsOf` guard: `rowsOf(results, 'stockrecordView')` → `results._embedded.stockrecordView` | the Jest **renamed-rel** case — *"expected `reportItems` to keep its previous value and the error toast to fire; received `reportItems: undefined`"*. ⚠ The mutant does **not** throw out of the spec: the store's own `try`/`catch` swallows the guard's `Error` into a toast, so the assertion must be on the **committed state** after the dispatch resolves, never on a rejected promise | a payload with `_embedded` carrying the **wrong rel** — `{ _embedded: { stockrecord: [] }, page: { totalElements: 0 } }`. ⚠ **The zero-row fixture CANNOT kill this mutant**, and the previous three rounds of this plan said it could: SDR sends `_embedded: { stockrecordView: [] }` on a zero-row page (**measured**, `SBDEV-3410-evidence/embedded-shape-measurement.md`), so the unguarded read evaluates to `[]` and behaves correctly. A fixture with **no `_embedded` key** would kill it but is a shape the server never sends — a green test against a fiction |
| `itemName` absence | `ifPresent` → unconditional `put("itemName", null)` | `StockrecordServiceUnitTest.detailsOmitItemNameWhenSkuDoesNotResolve` | a row with an unresolvable SKU; assert `doesNotContainKey`, not `get() == null` |
| `allClients` gate | remove **each** of the three constants from the annotation in turn | `Sbdev3017TrancheGateContextTest` — names the missing constant | none; the pin must carry the **full** varargs and keep an ungated row |
| `exposeIdsFor` | remove `StockrecordView.class` from the list | **`StockrecordViewHalContextTest.idIsInTheHalBody`** (§7.3). ⚠ Neither §7.2 test can execute this mutant: `exposeIdsFor` affects HAL *rendering*, which needs a MockMvc request | ⚠ **not "none"** — the `*ContextTest` lane is H2 with `ddl-auto=create-drop` and `spring.flyway.enabled=false`, so `stockrecord_view` is an empty Hibernate-created table there and `$._embedded.stockrecordView[0].id` resolves against nothing. Seed one `StockrecordView`-shaped row through the tenant `EntityManager` in `@BeforeEach` and **flush** (`BaseIntegrationTest` is `@Transactional("tenantTransactionManager")`, so the MockMvc request will not otherwise see it). Do **not** weaken the assertion to `status().isOk()` — that un-kills the mutant |
| shipper-is-a-computed | make `shipper` a `data()` key | **`expect('shipper' in wrapper.vm.$data).toBe(false)`.** ⚠ The obvious assertion (`'filter' in $data === false`) **cannot kill**: the mutant introduces a key named `shipper`, which is not in `searchUrlSync`'s `possibleProps` at all, so it stays green | change the value **after** mount |

### 7.9 Baseline and execution

Counts rot — **derive the baseline fresh at the branch point, before writing any code**, and compare, never
read a suite result absolutely. Both lanes must be green at the branch point:

```bash
cd <worktree>
mvn -q clean test            # surefire lane baseline
mvn -q clean verify          # failsafe lane baseline (includes surefire)
cd v2/wms2-web-ui && yarn test
```

`OutboxConcurrentEnqueueIT` is timing-flaky (SBDEV-3280), and a red `develop` **silently stops deploying** —
so a red in that class at the branch point is a known-flake to re-run, not a reason to proceed on a red
baseline.

| Command | Result | Pass / Fail / Skipped |
|---|---|---|
| `mvn clean test` (branch point) | | |
| `mvn clean verify` (branch point) | | |
| `yarn test` (branch point, wms2-web-ui) | | |
| `mvn verify -Dit.test=StockrecordViewSchemaIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | | |
| `mvn verify -Dit.test=StockrecordViewRepositoryFilterIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | | |
| `mvn test -Dtest=ReportControllerUnitTest,ReportServiceUnitTest,StockrecordServiceUnitTest,Sbdev3017TrancheGateContextTest,StockrecordViewRepositoryQueryShapeUnitTest,StockrecordViewHalContextTest` | | |
| `mvn clean verify` (final, pre-merge) | | |
| `yarn test` (final) | | |

### 7.10 Verify script — OPT-IN, not recommended

**Recommendation: do not ship one.** Every assertion above is routed to a JUnit or Jest test, which runs in
CI, survives refactors and can be mutation-checked. Verify scripts have been a measured net negative in this
repo.

If Nam opts in, the script is `sbdocs/9-System/scripts/verify-SBDEV-3410.sh`, copied from
`sbdocs/9-System/templates/verify-plan-template.sh` (never forked from a sibling — that detaches it from the
mutation-checked guard test `test-verify-plan-template-helpers.sh`), and capped at these **four** rows,
because each is a cross-**repo** invariant no single-repo test can see:

| # | Row | How it goes red against correct code |
|---|---|---|
| 1 | The wire key and the route name agree: `store/reports/stockUnit.js` emits `&clientId=` and targets `findByKeywordAndClient` **and** `StockrecordViewRepository` declares `@RestResource(path = "findByKeywordAndClient")` with `@Param("clientId")` | Rename either side alone → the other grep misses → FAIL. Prove it by replaying the pre-fix `stockUnit.js`. |
| 2 | The `_embedded` key agrees: the store reads `results._embedded.stockrecordView` **and** the repository declares `collectionResourceRel = "stockrecordView"` | Change the `collectionResourceRel` alone → FAIL. Prove it by replaying the pre-fix repository file. |
| 3 | The export key agrees: `exportReport.vue` sends `filter` **and** `ReportController` reads `"filter"` | Revert the controller read → FAIL. Prove it against the pre-fix `ReportController.java`. |
| 4 | `V2.2.33` exists and its version is still free: `bash v2/wms2-api/src/main/resources/db/check-migration-version-collision.sh V2.2.33` exits 0 | Push a colliding `V2.2.33` on any remote ref → FAIL. This is the one row whose input changes after the code is written. |

⚠ Verify-script traps that apply: **scripts do not share a `PROJECT_ROOT` convention** (37 of 44 want the
sub-repo root, 7 want the monorepo root — this one wants the **monorepo** root, since it spans two repos),
and rows shelling out to `mvn`/`yarn` red spuriously when the toolchain is off PATH, because bash's 127
records as an ordinary FAIL. **Negative-test every row before trusting it.**

---

## 8. Rollout Plan

| Step | Action | Gate before proceeding |
|---|---|---|
| 1 | Derive the fresh test baseline at the branch point (§7.9) | Both lanes green (or a known SBDEV-3280 flake re-run green) |
| 2 | Merge **P1** to `develop` → dev deploy, Flyway applies `V2.2.33` on every dev tenant | Per-tenant `information_schema.views` + `pg_indexes` check (§7.7 last two rows). ⚠ This is when the ~6 s `SHARE` lock happens |
| 3 | Merge **P2** | `/api/stockrecordView/search/findByKeyword` returns 200 with `id` in the HAL body; `/api/stockrecordView` (no search) returns 405/404, not 9.7 M rows |
| 4 | Merge **P3**, **P4**, **P5** (any order) | Both `exportStockUnitRecord` gate rows green; `allClients` row green; export produces a real workbook |
| 5 | Merge **P6** | ⚠ **First confirm `/api/public/version` on dev reports a SHA that CONTAINS P2** — "merged" is not "deployed", and the `:develop` tag race can deploy an older image than the merge order implies. P6 shipped ahead of a running P2 is not a degradation, it is a **blank report: 404 on every page load**, with no flag to fall back on (prereq 2 waived one). Then the full §7.7 manual plan on dev |
| 6 | Re-run `check-migration-version-collision.sh V2.2.33` **immediately before** each merge that carries the migration (step 2), not once at planning time | Exit 0 |
| 7 | Promote to UAT per the normal ladder | Repeat the per-tenant DDL check on every UAT tenant |
| 8 | Record the post-merge unfiltered-count plan on dev once, against the §3.1 baseline | Still a bare `Parallel Seq Scan`; no `Hash Left Join` |

**Rollback, with the order stated.** **P6 reverts first, always. P2 cannot be reverted while P6 is
live** — reverting it 404s the report, and prereq 2 waived a flag, so there is nothing to fall back on. Code
phases otherwise revert by reverting their PR. `V2.2.33` does **not** revert by reverting the file — Flyway
has already recorded it. Rolling back the DDL means a new forward migration
(`DROP VIEW public.stockrecord_view;` / `DROP INDEX index_stockrecord_client_created;`), and the `DROP VIEW`
needs ownership on tenants where ownership has drifted. Practically: the UI (P6) is the revert that restores
today's behaviour, and the view + index are inert if nothing reads them — leave them in place rather than
dropping under pressure.

**Only ever merge to `develop`.** `release` and `main` are DevOps-owned.

---

## 9. Alternatives Considered

*9.1, 9.2 and 9.4 are one-line verdicts here; the pros/cons framing and the measurements live once in
`SBDEV-3410-evidence/ralplan-dr.md`'s "Viable options" block. 9.3 is kept in full because it is the only
option that is **not** invalidated. 9.5–9.7 are kept: nothing else states them.*

### 9.1 Interface projection instead of a DB view — **REJECTED (proven impossible)** → RALPLAN-DR **Option D**

### 9.2 Hibernate `@Formula` on `Stockrecord` — **REJECTED (measurement + a positive-controlled zero)** → RALPLAN-DR **Option C**

### 9.3 A hand-written MVC endpoint instead of Spring Data REST — **REJECTED, but its cost was over-stated**

`StockRecordController` could gain a `@GetMapping("/reportView")` returning a DTO page, which would sidestep
SDR entirely, allow `toFilterId` on the read path, and let the endpoint be function-gated.

**Rejected because it abandons SDR's paging and sorting and changes the UI contract.** The store would stop
reading `results._embedded.*` / `results.page.totalElements` and the `&sort=`/`&page=`/`&size=` handling
would have to be re-implemented by hand, for a report whose seven siblings all stay on SDR. It is also the
option that most changes the blast radius: a new gated endpoint needs two new `Sbdev3017TrancheGateContextTest`
rows and a `FunctionEnum` decision, where the chosen design needs neither.

⚠ **"A larger UI diff than the whole rest of this ticket" over-states this option's cost.** The store is
already hand-built — `store/reports/stockUnit.js` assembles its query string by concatenation
(`'?page=' + (data.page - 1) + '&size=' + … + '&keyword=' + …`) and reads `results._embedded.stockrecord` /
`results.page.totalElements` — three touch points, not a framework, and **P6 is already rewriting all three**
(new path, new `_embedded` key, new parameter). The honest cost is "re-implement paging and sorting by hand
and diverge from seven siblings", which is still a real cost and still loses to Option A.
**The conclusion holds for a reason that does not depend on the cost estimate at all: the view is needed for
AC-3 regardless of how the filter is implemented.** SBDEV-3417 closed interface projections and `@Formula` is
positive-controlled to zero occurrences, so even Option B needs `item_name` from somewhere. Revisit only if
the SDR-unruled asymmetry (§3.5) is taken up on its own ticket — at which point Option B becomes the right
answer, because it closes that gap as a side effect.

### 9.4 Filter on `cl_nr` for consistency with the sibling reports — **REJECTED (Q1)** → RALPLAN-DR **Option A** carries the measurement

⚠ **The price this rejection is quoted at needs correcting.** 9.4 was rejected on the right evidence
(4,090–4,280 ms vs 943–987 ms for the same 873,021 rows, an 18× row-estimate miss driving a serial nested
loop — the numbers are in Q1) but priced as *"the wire format differs from the six sibling reports."*
**It does not differ from the two closest ones.** `components/handlingUnits/{containerTable,stockUnitsTable}.vue`
and `StockUnitController#getDetailView` already use `clientId` + `-1` + `toFilterId`. The alternative was
rejected for the right reason at an inflated price — the mirror image of a strawman: the *chosen* option was
handicapped, not the rejected one. See §10.1 Q1.

### 9.5 `CREATE INDEX CONCURRENTLY`, or a separate operator-run `V2.2.34` — **REJECTED (Q3)**

Avoids the ~6 s write stall.

**Rejected because `CREATE INDEX CONCURRENTLY` cannot run inside a transaction and Flyway wraps every script
in one.** The escape is Flyway's per-script transactional control, for which this repo has **no precedent**
(derived by grepping the `db/migration` tree for Flyway script-config files; blind spot: a config could in
principle live outside that tree, unmeasured). Splitting it into an operator-run migration makes the index —
which the feature is useless without — a manual step that can be skipped per tenant, turning a measured 6 s
stall into an unmeasured correctness cliff. Accepted: one migration, at boot, seconds.

### 9.6 Ship the SKU Name column sortable — **REJECTED (Q4)**

**Rejected on measurement: 17,942 ms unfiltered**, and 54,984 kB of external-merge disk spill **per worker**
(≈215 MB across 4 workers) when filtered. AC-4 requires that keyword search, sorting and pagination keep
working *in combination with the shipper filter*; it does not require the *new* column to be sortable. See
§3.10 for the caveat that this is policy with no technical enforcement.

### 9.7 Extend the keyword search to cover product and shipper names — **REJECTED**

The obvious "while we're here" enhancement, and it is a trap: referencing a joined column in `WHERE` defeats
the join elimination that makes the default page free, taking the unfiltered count from ~7.3 s to ~17.9 s
(2.5×) for **every** user on **every** unfiltered page load, including those who never search by name.

---

## 9A. Implementation status — P1 ONLY (2026-09-18)

**P1 is implemented and committed locally. NOT pushed, no PR. P2–P6 are untouched** — each re-enters
`wms-tdd-gate` at its own start.

Worktree `.claude/worktrees/wms2-api/SBDEV-3410`, branch `feature/SBDEV-3410-p1-stockrecord-view-migration`,
off `origin/develop` @ `7ebb9c83`.

| commit | what |
|---|---|
| `bfb5b860` | `V2.2.33` + `StockrecordViewSchemaIT`; fixed the guard that would have frozen every tenant |
| `e8411c6f` | both review lanes' findings; guard moved from `pg_constraint` to `pg_index` |
| (third) | AC-P1f guard pin; J-4/J-5/J-6 |

**Tests:** 6/6 in `StockrecordViewSchemaIT`; unit suite 6,741 run / 0 failures (baseline 0); full
`mvn clean verify` failsafe lane 470 run / 0 failures / 31 skipped.

**Six mutations, every kill attributable:**

| mutation | killed by | message names |
|---|---|---|
| join on `item_nr` alone | AC-P1a + AC-P1c | *"the join MULTIPLIED"*, 5 rows for 3 |
| `LEFT` → `INNER` | AC-P1a + AC-P1b | *"the join DROPPED rows"*, 2 rows for 3 |
| drop a projected column | AC-P1e | names the unprojected column |
| guard vs a wrong column set | migration | `P0001` RAISE |
| **delete the whole `DO` block** | **AC-P1f only** (6 run, 1 failure) | *"nothing else in this class would notice"* |

### Defects found during implementation that the plan did not predict

1. **The guard would have frozen every tenant.** It compared `pg_constraint.conkey` — the constraint's
   *declared* order — against an attnum-*sorted* array. On `dev_wh01_om1`, which HAS the constraint,
   `conkey` is `{20,10}` against the guard's `{10,20}`: no match, so it would have `RAISE`d on a healthy
   tenant, failed `V2.2.33` and stalled that tenant at `V2.2.32` while the app kept booting green.
2. **A second failure in the same block:** `attname` is type `name`, so the corrected comparison raised
   `42883 operator does not exist: name[] = text[]`.
3. **The guard graded the wrong catalog.** Join removal reads `pg_index`, not `pg_constraint` — wrong in
   both directions: a bare unique *index* (which supports elimination) would be falsely RAISEd on, and a
   `DEFERRABLE` constraint (which the planner will not use) would falsely pass.
4. **`archive` exists on `wms2-wineco-dev` and in no migration.** Real tenant drift; the fixture's column
   list must come from `db/migration`, not a live tenant. Likely belongs to SBDEV-3295.
5. **Both ShipItEZ PRD MCP aliases resolve to `wh01_hydra_v2`.** So "no tenant has this view" is verified
   on **1 of 3** active PRD tenant databases. `wh01_shipitez_v2` and `wh02_shipitez_v2` are unchecked for
   view absence, index-name freedom and the constraint — a pre-deploy check is recorded in the migration
   header.

### 🔴 P3's acceptance criterion is unsatisfiable as written — fix before gating P3

§5.2 P1 states the filtered export's acceptance as *"the `Sort` node is gone"*. Measured under
`force_generic_plan` on a disposable 1.2 M-row container:

| export query | plan | time |
|---|---|---|
| `client_id` + `ORDER BY created DESC LIMIT`, **no keyword** | `Index Scan using index_stockrecord_client_created`, **no Sort** | **0.5 ms** |
| the same **with** the keyword `LIKE` (even with no `OR` arm) | `Sort` + bitmap on `index_stockrecord_client_id` | 760 ms |

The cause is **not** the parameter-only `OR` disjunct (that was A-1, and it is fixed). It is the
unindexable leading-wildcard `LIKE`: the planner cannot know how far it must walk to find 1,000 matching
rows, so it prefers bitmap + top-N sort. **Not a regression** — today's export has no shipper filter at
all — but the criterion cannot pass whenever a keyword is supplied, and gating P3 against it would write
a test that can never go green. Suggested restatement: *"the filtered export uses
`index_stockrecord_client_id` or better and does not seq-scan; a `Sort` node is expected whenever a
keyword is supplied."*

**Read path, by contrast, is CONFIRMED.** Under a generic plan:
`Index Scan using index_stockrecord_client_created`, `Index Cond: (client_id = $2)`, **0.191 ms**.
Control: dropping the index regresses it to `Parallel Index Scan Backward using index_stockrecord_created`
at 5.694 ms. Q3's rationale holds, and the repository split restores the index's reachability.

### Still owed
`force_generic_plan` re-measurement against a real tenant is a **post-merge** action — the index does not
exist on dev and Flyway there is at `2.2.32`. The container measurement above establishes plan *shape*;
absolute milliseconds will differ.

---

## 10. Open Questions / Resolved Decisions

### 10.1 Resolved (Nam, 2026-09-18) — fixed constraints, not options

| # | Decision | Rationale | Accepted cost |
|---|---|---|---|
| **Q1** | **Filter on `clientId` (`Long`), not `cl_nr`.** `null` and `-1` both mean no filter | 943–987 ms Parallel Index Scan vs 4,090–4,280 ms serial Nested Loop; the planner estimated 47,082 rows against an actual 873,021, an 18× miss | ⚠ **The cost usually recorded for this decision — *"the wire format differs from the six sibling reports"* — is FALSE, and the decision comes out strictly better supported without it.** **There is no divergence to accept: `clientId` + the `-1` sentinel + `toFilterId` IS the established convention**, set by SBDEV-2976 Gap 2 — the sibling half of this ticket's own parent — in `components/handlingUnits/{containerTable,stockUnitsTable}.vue`, `store/handlingUnits/{container,stockUnits}.js` and `StockUnitController#getDetailView` (`@RequestParam(value = "clientId", …) String clientId` … `toFilterId(clientId)`). The seven `clNr` reports are the **older** shape. The decision stands unchanged; its real cost is only that this screen's wire format differs from seven sibling *reports* while matching two sibling *grids* and the API convention. The mistake is traceable to scoping §0's sweep to `components/reports/` (§0 header) |
| **Q2** | **Export gets the filter ONLY** — no product-name column | Adding `item_name` changes the 15-column spreadsheet contract a downstream macro may key on by position | The SKU name is visible in the UI but not in the export |
| **Q3** | **Plain `CREATE INDEX index_stockrecord_client_created ON stockrecord (client_id, created DESC)` INSIDE `V2.2.33`** | Without it the filtered first page is 2,865 ms (7,564,825 rows discarded) vs 5–7 ms unfiltered; with it 0.455 ms | 6.3 s build, 276 MB, ~6 s `SHARE` lock on `stockrecord` per tenant, once, at the deploy boot. **Not `CONCURRENTLY`** — cannot run inside Flyway's transaction and has no repo precedent |
| **Q4** | **SKU Name column is `sortable: false`** | 17,942 ms unfiltered sort; filtered it spills 54 MB/worker to disk | **Policy, not a guarantee** — a hand-typed `?sort=itemName` still reaches JPA and gets the 17.9 s plan. There is no technical enforcement short of not mapping the property, which conflicts with AC-3 |

**Implementation refinement on Q1.** The decision names `AdminController.toFilterId` as
the normaliser. That helper is `protected static` on an MVC controller base class, and the table read is
served by Spring Data REST, which has **no controller** — so `toFilterId` is reachable on the export path
(P3) and unreachable on the read path (P2). The three-valued `OR` in the JPQL predicate is **not** the
resolution — it makes the whole predicate non-indexable under a generic plan and so unbuilds the index the
feature depends on (§3.4, measured). The sentinel is folded by the **caller** on both paths instead: the store
on the read path, `toFilterId` on the export path. The meaning of `null`/`-1` is unchanged; only the place the
fold happens. AC-1 grades the read path's *route choice* rather than a `clientId=-1` parameter, because the
unfiltered method has no such parameter — flagged rather than silently adapted.

### 10.2 Open — do not decide these without Nam

**Q5 — keep or withdraw `/api/stockrecord/search/findByKeyword` once the UI moves to `stockrecordView`?**
It has **zero Java callers** — derived by `git grep -n 'findByKeyword' origin/develop -- src/` restricted to
`stockrecordRepository.`; blind spot: the sweep cannot see a reflective or string-built repository path, and
cannot see callers outside this repo. Its only known consumer is `store/reports/stockUnit.js`, which this
ticket migrates. Leaving it exported keeps an **unruled** SDR search over 9.7 M rows alive with no caller.
Withdrawing it (`@RestResource(exported = false)`) is a one-line cleanup consistent with the SBDEV-3417
programme. **Proposed, flagged, not decided** — it is an externally-visible route, so it is a contract
change. ⚠ Note the two mechanisms behave differently for a caller: an SDR **withdrawal** returns 405 to
everyone, whereas a `SdrFunctionRules` rule returns 403 — an acceptance criterion written for one cannot
grade the other.
**The repo's own standing position points at withdrawal.**
`SdrUncalledSurfaceNotExportedContextTest`'s assertion message says it directly: *"a search with no HTTP
caller is routed and unguarded. **Withdraw it with `@RestResource(exported = false)` rather than adding an
`SdrFunctionRules` entry** — every tenant is at OFF for `WMS2_SDR_READ_GUARD_MODE`, so a rule closes nothing
today. If an HTTP caller has since appeared, remove the entry here and say where the caller is."* After P6,
`/api/stockrecord/search/findByKeyword` is exactly that shape. This does not decide Q5 — the route may have
callers outside this repo, which no sweep here can see — but it means the default is *withdraw*, and keeping
it is the choice that needs a reason. If Nam says yes, the withdrawal belongs in **P6's** PR, not earlier:
withdrawing before the UI has moved breaks the report.

**Q6 — is the "0 users blocked" figure in §3.8 good enough to call the `allClients` gap latent?**
It is `dev_wh01_om1` at one instant, with a positive control. `wh01_hydra_v2`, `wh01_shipitez_v2` and the
other prd tenants were **not** measured. ⚠ **"A cheap extra query against the prd MCP targets" is not
available as stated**: all three prd aliases resolve to `wh01_hydra_v2` (§3.2), so that query would
measure hydra three times and report full prd coverage. Closing Q6 properly needs real credentials for
`wh01_shipitez_v2` and `wh02_shipitez_v2` prd. The fix in P5 is worth doing either way; only the urgency
label depends on this, and it now covers three functions rather than one (§3.8).

**Q7 — `V2.2.33` collision re-check timing.** Established free by a sweep the plan described as covering
"40 remote refs" — ⚠ **the repo has 310** (`git for-each-ref refs/remotes | wc -l`).
The conclusion is unaffected — an independent sweep,
`git log --all --diff-filter=A --name-only -- 'db/migration/V2.2.3*'`, which covers everything reachable from
`--all`, returns only V2.2.30/31/32 — but the *stated scope* was not what was run. What matters is unchanged:
`db/migration/README.md` requires the sweep to be re-run **immediately before merge**. Whoever merges must
run `bash src/main/resources/db/check-migration-version-collision.sh V2.2.33` from the repo root and must not
trust this document. This is a procedural obligation, not a design question — listed here so it cannot be
lost.

### 10.3 What the evidence base did NOT establish

Stated so absence is not read as evidence.

1. **Measured on one tenant only** (`dev_wh01_om1`). Row counts, client distribution and recency skew differ
   on `wh01_hydra_v2` and `wh01_shipitez_v2`. The **relative** results (join elimination, `client_id` vs
   `cl_nr`, the composite index) are structural and should port; the absolute milliseconds will not.
2. **Literals, not bind parameters.** pgjdbc uses a custom plan for the first `prepareThreshold=5`
   executions, then may switch to a generic plan. The constant-folding win from the `or :keyword = ''` escape
   in particular may not hold on the generic-plan path — it is treated as a bonus, never as a guarantee.
3. **No Hibernate-generated SQL was captured.** §3.4 and §3.6 reconstruct query shapes from JPQL by hand. A
   `hibernate.SQL` log capture on a running app would be a second instrument, and it was not taken — which is
   why §7.2 includes `exportPredicateRendersOnPostgres`.
4. **`v2/wms2-mobile-ui` was not examined.** It is not believed to have a Stock Unit Record counterpart; that
   is an assumption, not a measurement.
5. **No `pg_stat_statements` evidence** of how often the unfiltered default page is actually served, so "is
   7.3 s acceptable" is answered only as "it is the status quo".
6. **Neither test suite was run.** No baseline exists yet; §7.9 says it must be derived at the branch point.
7. **The composite index's generic-plan behaviour is inferred, not measured.** What is
   measured is that a plain equality keeps `Index Cond: (client_id = $1)` and that both `OR` forms do not, on
   the indexes that exist today. The composite index could not be built (a mutation) and `hypopg` is not
   installed (control: 61 available extensions). P1 closes this (§5.2).
8. **"Every tenant" was never measurable from this session.** All three prd MCP aliases
   resolve to `wh01_hydra_v2`; both ShipItEZ prd databases are unreachable. Every claim in this plan of the
   form "on every tenant" means "on the five databases this MCP set reaches", and the affected claims are
   prereq 1 (`stockrecord_view` absent), §3.2 (index cost), §3.6 (`client.id = 0` present) and Q6 (blast
   radius).
9. **The `<v-autocomplete>` decision rests on shipper counts (125–164 across four environments) against a
   threshold that is the sibling's judgement, not a measurement of this screen.** Nam decided it on that
   basis (§3.9). What was measured is the counts; what was not is the point at which a scrolling list stops
   being usable. Nothing downstream depends on the threshold being right — both widgets satisfy AC-1 and the
   `#shipper` assertion — but the three behaviour consequences in §3.9 (no sentinel row, type-ahead on
   `item-text`, clear ⇒ `null`) do follow from the choice and are graded by §7.4.
10. **The §3.6 truth table models the guard expression, not the mounted component.** It was **executed**
   (`node -e`) over `exportReport.vue`'s line-136 expression as quoted from `origin/develop`, across
   `{null, 0, 60500}`, for each candidate binding — not reasoned. Its blind spot: if `exportReport.vue`
   coerced the prop before that line the result would differ. It does not — `props:` is a bare array, so
   there is no type coercion and no default — but that is a read of the component, not an execution of it.
   The same applies to §7.3's `queryShapeForbidsADisjunction`: the two assertions were executed against the
   correct JPQL and five mutants as *strings*, which is exactly what the test reads, so there is no gap
   there; what is untested is whether an implementer's actual `@Query` renders the SQL the plan assumes,
   which is `exportPredicateRendersOnPostgres`'s job.
11. **The zero-row SDR wire shape IS now measured — it was not, for three rounds, and it was backwards.**
   Rounds 1–3 asserted *"`_embedded` is ABSENT, not empty"* in four places, on the authority of one in-repo
   comment about a different endpoint; two review lanes agreed **because they shared that source**. Round 4
   ran the app's own MockMvc lane against six routes at `origin/develop = 7ebb9c83` and observed
   `"_embedded": {"<rel>": []}` on all six, including the association shape the comment describes
   (`SBDEV-3410-evidence/embedded-shape-measurement.md`). What is **still** not measured: a deployed server
   (this was MockMvc in the same application context — see that file's blind-spot list), an `Optional`-returning
   search, and a projection collection.
12. **A prescription that is applied faithfully can still be wrong.** The `:filter="shipper == null ? -1 :
   shipper"` fold was a reviewer's prescription, adopted verbatim, and it did not fix the defect — it left
   `0` untouched, and the mutation row written to protect it was byte-identical to the fix on the only value
   that discriminates. It was caught by writing out the truth table, not by re-reading. Where a fix concerns
   a **value transformation**, this plan now writes the table; where it concerns a **string the code
   contains**, it executes the assertion against the mutants; and where it concerns **a wire shape**, it
   dispatches a real request and writes down the body. All three of those rules were added *after* a
   prescription of that kind shipped wrong — B-1's fold, B-4's vacuous assertion, and the `_embedded` shape.

### 10.4 Findings outside this ticket — two FILED, three PROPOSED

Per the standing ticket policy, sub-T3 fixes found during analysis go onto **this** ticket; each item below is
a **different screen or repo artefact**, so **none is folded in and no phase in §5.2 touches any of them.**
Ordered by what I would do first, with blast radius and cost.

⚠ **Items 1 and 3 are FILED** — two separate tickets, opened 2026-09-18, both at priority **high** on the
Fulfillment Development Backlog and both naming SBDEV-3410 as where they were found:

- **[SBDEV-3437](https://app.clickup.com/t/868m6wfed)** — *Truthiness guards treat System-Client
  (`client.id = 0`) as "no filter" — Cycle Count + one other screen* **(item 1)**
- **[SBDEV-3436](https://app.clickup.com/t/868m6wfa7)** — *Shipper-filter predicates are non-indexable under
  a generic plan — `StockunitRepository.getDetailViewByKeyword`* **(item 3)**

**This plan does not carry either of them.** No phase in §5.2 touches them, no acceptance criterion grades
them, nothing in §7 tests them, and §4 lists none of their files. They are recorded here only so the trail
from this analysis to those tickets is not lost — an implementer working SBDEV-3410 should read rows 1 and 3
and do nothing. Item 1 absorbs what round 3 listed separately as item 5 (`store/admin/labelPrinting.js`),
which is why the numbering skips 5. Items 2, 4 and 6 are still proposals for Nam to rank; none is filed.

| # | Finding | Blast radius | Cost | Do it? |
|---|---|---|---|---|
| 1 | **FILED → [SBDEV-3437](https://app.clickup.com/t/868m6wfed)** — the two live truthiness bugs on other screens: `store/internalOps/cycleCount.js` (drops a selected System-Client from the Cycle Count filter, at **two** expressions — `if (data.clientId) {` and `'&clientId=' + (…ShipperFilter \|\| '')` at two call sites; fixing one fixes half) and `store/admin/labelPrinting.js`'s `if (data && data.clientId)`. SBDEV-3437 carries §3.6's **executed** truth table and the *trace the value all the way to the wire* warning, because the first prescribed fix for this defect class was applied faithfully and still failed — downstream of the prop, inside `exportReport.vue`'s guard | — | — | **Not carried here** |
| 2 | `db/migration/README.md` still lists `V2.2.11` as *"deliberately skipped… Do not reuse"* while `V2.2.11__seed_adjustment_alert_poll_sysprop.sql` exists on `origin/develop`. A future migration author reading it will skip a free number, or worse, trust the rest of the file | documentation only; but it is the file the collision procedure points at | one paragraph | **Yes** — cheap, and it is the authority for a procedure this ticket runs twice |
| 3 | **FILED → [SBDEV-3436](https://app.clickup.com/t/868m6wfa7)** — `StockunitRepository.getDetailViewByKeyword`'s `COALESCE(CAST(:clientId AS BIGINT), -1) = -1 OR …` is non-indexable under a generic plan (measured against `stockrecord`, §3.4) — **and it filters on the joined `c.id`**, which is §3.4's *other* measurement: the planner cannot propagate selectivity across the join, estimates 47,082 rows against an actual 873,021, and picks a serial nested loop. SBDEV-3436 covers **both** predicates on that method and scopes the sweep for other instances of the same literal. It should re-measure on `stockunit` first — the five-way join may dominate and make the split worthless | — | — | **Not carried here** |
| 4 | `UnitloadRecordRepository.findByOffsetAndLimit` is the identical-shape sibling backing `exportContainerRecord`, and Container Record is the screen most likely to want this feature next | one repository + `ReportService` | a copy of P3 | **Later** — only when Container Record actually asks for a shipper filter |
| 6 | **NEW in round 4, from the measurement.** `wms2-web-ui/store/admin/group.js`'s SBDEV-3012 javadoc asserts *"`_embedded` is ABSENT, not empty, when Spring Data REST returns an empty collection"*. **It is false**, measured on the exact shape it describes: `GET /v3/userGroup/{id}/roles` with no roles returns `{"_embedded":{"userRole":[]}}` (`SBDEV-3410-evidence/embedded-shape-measurement.md`, probe E). The `rowsOf` helper it documents is still correct — its `!embedded` arm is simply unreachable and its rel check is the live one — so this is a **comment** defect, not a code defect. It matters because it is the repo's only written statement on the subject and it propagated into three rounds of this plan | one javadoc; no behaviour change | ~4 lines | **Yes, cheap** — but it is a different file on a different screen, so it is proposed rather than folded in. Whoever takes it should also drop the now-dead `!embedded` early return or relabel it as defence |

---

## RALPLAN-DR

Moved to `SBDEV-3410-evidence/ralplan-dr.md` in round 3. It carried Principles 3–6, the top-3 decision
drivers and the four viable options (A chosen; B viable and rejected on cost; C and D invalidated on
measurement). Nothing in §5.2 points at it, so it is a consensus-process artefact rather than an
implementation instruction — §9 already summarises each option's verdict and cites the file for the
evidence.
---

## Revision log

Moved to `SBDEV-3410-evidence/revision-log.md` in round 4 (rounds 2–4, 151 lines). It is pure provenance —
the next reviewer and Nam read it, an implementer does not — and both of those readers are already in the
evidence directory.
