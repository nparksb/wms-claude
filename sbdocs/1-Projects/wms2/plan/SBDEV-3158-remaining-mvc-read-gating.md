---
title: "MVC read-surface function gating — 95 ungated /v3 read routes"
ticket: "SBDEV-3158"
ticket_url: "https://app.clickup.com/t/868ky46ga"
type: "security / authorization"
priority: "High"
status: "done — all 5 slices merged to develop (slice 5 via PR #302, `a6c22ac7`, 2026-09-04)"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-03"
updated: "2026-09-03"
related:
  - "SBDEV-3017-B1-mvc-write-surface-gating"
  - "SBDEV-3142-report-read-gating"
  - "SBDEV-3154-admin-action-console-gating"
  - "SBDEV-3155-mutating-get-gating"
  - "SBDEV-3169-sdr-read-gating"
  - "SBDEV-3124 (deferred /rest gating, blocked on OMS)"
tags:
  - plan
  - authz
---

# RALPLAN-DR SUMMARY

## Principles

**P1 — Gate a route on its SCREEN's existing function; never invent a constant.**
SBDEV-3017 §9.16 Option B. **Method and its blind spot, stated inline:** all **29 distinct target
constants** named anywhere in §0.5's route table were checked one-by-one against
`src/main/java/net/aim_ai/wms/service/WmsConstants.java` — each is declared exactly once. That is an
exhaustive check of the *constants used*, **not** a sample. Its blind spot: it proves the constant
exists **in source**, not that it exists as a row in every tenant DB — that is a separate check and
§5.1 row 7 owns it. A new constant is a three-part coordinated change (constant + `initDB` grant +
per-tenant seed) and an escalation trigger, not a detail.

**P2 — Never let a function gate 403 a bootstrap or pre-entitlement call.**
A caller holding **zero** functions is a legitimate provisioned state (44 of 99 on dev). No ANY-of set
reaches a user with nothing, so a read on the pre-entitlement path cannot be expressed as a gate.
Those get `@PublicHandler` — documented, allow-listed, metered — never silent omission.

**P3 — ANY-of wherever a handler serves two screens or two UIs.**
A single `WEB_UI_*` gate on a mobile-called handler is an outage. Same where a handler's sibling
function and its *caller's* screen disagree. **16 of the 95 routes are ANY-of** (§0.6).

**P4 — Every gate is pinned against a NAMED ROUTE and mutation-checked.**
Keyed `(declaringClass, path)`, never on a method name — this repo copy-pastes and mis-spells them
(`floowbinMonitorView`, `orderMonitoClientrView`, `activeBatch` serving `/activateBatch`).

**P5 — An UNGATED row is a first-class deliverable, not an absence.**
The only thing catching a class-level `@RequiresFunction` widening to a whole controller is a sibling
row asserted UNGATED. This ticket **consumes** the last such row on `ClubLineController` and
`TransfersController` and must replace that tripwire (§0.4, AC-7).

## Decision drivers (top 3)

**DD1 — Blast radius, measured, with a decision procedure attached.**
§G: on `wms2-wineco-dev`, 17 of 54 *provisioned* users lose Client and Printer; `ursulajimenez` holds
**62** functions and neither `WEB_UI_VIEW_CLIENT` nor `WEB_UI_VIEW_PRINTER`. Draft v1 left "does the
UI already hide it?" as an unresolved OR. **It is now resolved by measurement** (§0.7): every slice-2
caller screen is gated in `wms2-web-ui` on exactly the constant this plan uses, so **slice 2 is
one-repo work**. Only slice 3's `adjustmentAlerts` — a *plugin*, with no menu row at all — is
two-repo.

**DD2 — Reuse the existing pin so the gate is mutation-checkable the same way as every sibling.**
`Sbdev3017TrancheGateContextTest` carries 145 rows across SBDEV-3017/3142/3154/3155/3198. One line per
route, one authority for "which constant sits on which route", drift fails with a named route.

**DD3 — Keep PRD roll-out risk at zero, and keep the claim honest.**
§G.2: on `wms2-hydra` all 7 provisioned users hold all 79 granted functions. Nobody loses anything —
and nobody gains protection. This closes a **live dev/UAT exposure** and a **latent PRD** one.

## Viable options

### Axis A — slice-by-slice PRs vs one PR

| | **A1 — 5 merge-ordered PRs (CHOSEN)** | A2 — one PR |
|---|---|---|
| Pro | Each slice is one controller family, independently reviewable and revertable. Slice 2's blast radius does not hold slices 1/4 hostage. Matches SBDEV-3017's reviewed tranching. | One review pass; one pin edit; no merge-order discipline. |
| Con | All five edit the **same** pin file, so they serialise: a rebase per slice, and the size constant changes 5 times. Each merge to `develop` is a dev deploy + Flyway run. | A 95-annotation diff across 24 files is not reviewable; one wrong target function is invisible. A revert takes back all 95, including the safe 7. |

### Axis B — the §E GET-MUTATE handlers

Draft v1 strawmanned this. The honest framing: **both options are defensible**, and the deciding
factor is the ticket policy's `on dev` carve-out, not elegance.

| | **B1 — gate 2 of 3 on SBDEV-3158 (CHOSEN)** | B2 — file a new small ticket for the 2 annotations |
|---|---|---|
| Pro | Same mechanism, same pin, same review lane; found during **this** enumeration. Leaving them out makes this ticket's completeness claim false, and they would sit owned by nobody in the interim. Zero extra process for two one-line annotations. | Keeps the read/mutate boundary clean, which is a real property: this ticket's title says "read gating" and these two are writes. A separate ticket gets its own tier, its own probe and its own reviewer attention — which is exactly what SBDEV-3155 existing as a separate ticket already demonstrated is worthwhile. |
| Con | Two writes ship under a read-gating ticket. Mitigated by labelling them *action gate* in code, in the pin and in the route table — never folded in silently. | Two tickets for two annotations; and the ticket policy caps proposals at one per fix visit, which is already spent on the springdoc carve-out (Appendix A). |

**Deciding factor:** SBDEV-3155 is already **`on dev`**, so "add them to 3155" — the option that would
have been cleanest — is *unavailable*: the policy forbids adding scope to shipped code. Between B1 and
B2, both legitimate, B1 wins on the proposal cap. **`AdminActionController.triggerUpdateStock` is
rejected from both** — §0.2.

### Axis C — the D.1 bootstrap reads: `@PublicHandler` vs leave-ungated

`PublicHandlerContractArchTest` **AC-7d** asserts every `@PublicHandler` site's declaring class is in
`FunctionGuardInterceptor.GUARDED`. The marker therefore drags its class into `GUARDED`, and
`FunctionGuardStartupAssertion` then **fail-closes the boot** for every *other* handler on that class
resolving no function.

| handler | declared siblings | verdict |
|---|---|---|
| `TenantHealthController.checkHealth` | **none** | ✅ marker + `GUARDED`. Atomic and clean. |
| `SystemController.triggerOrderReplenish` | 1 (`searchSystemByGroupname`, gated by this plan) | ✅ marker + `GUARDED`, atomically with that annotation. |
| `TokenController.user` | 2 — `token` (**login**, `permitAll` at `SecurityConfiguration:150-154`) and `detrack` (external courier callback) | ⛔ **DEFERRED.** `GUARDED` would force markers onto the login endpoint and a webhook — two handlers this ticket never analysed. |

Leave-ungated is rejected for the first two (indistinguishable from oversight; precedent is
`UserController`'s three markers). For `TokenController.user` it is the *interim* answer, made
explicit by a pin row asserting UNGATED plus a code comment.

### Axis D — `PutawayConfigController` `eligibleLocations` / `preview` (D.2)

Genuinely contestable; Nam ruled. Recorded here because the DR section's job is to show the tradeoff
was seen. Both reads take a `PutawayScope` **request parameter** (`PutawayConfigController.java:148`),
and the class's three gated writes each use a *different* function keyed by that scope (`:189` SKU →
`WEB_UI_VIEW_ITEM_DATA`; `:226` merchant → `WEB_UI_VIEW_CLIENT`; `:249` warehouse →
`WEB_UI_VIEW_SYSTEM_PROPERTY`). **The correct function is a runtime value, which `@RequiresFunction`
cannot express.**

| | **(a) ANY-of all three (CHOSEN — Nam)** | (b) `WEB_UI_VIEW_SYSTEM_PROPERTY` alone | (c) in-body scope-keyed `denyUnless…` |
|---|---|---|---|
| Pro | Reversible; matches "may see any putaway-config screen"; both callers are the one Configuration screen (`store/admin/configuration.js:521,640-647`), so nobody legitimate is denied. One annotation. | Simplest; the broadest scope's function. | **Scope-exact** — the only option that actually enforces the intended rule. Precedent exists (`UserAdministrationController`'s `denyUnlessUserManagementAllowed`, §B.1). |
| Con | Weakest of the three: a user holding only `ITEM_DATA` can preview a *warehouse*-scoped config. **Explicitly a documentation-grade gate, not a control** — AC-15 measures exactly this. | Over-gates: denies SKU- and merchant-scope users who legitimately use the screen. | Costs a service-layer guard + its own unit tests; invisible to the pin (which reads annotations only), so it needs a *different* test shape. |

**(a), per Nam.** The residual is recorded rather than smoothed over, and AC-15 forces it to be
reported as a number.

### Axis E — `StockRecordController.adjustmentAlerts` (D.5)

Genuinely contestable; Nam ruled. Its caller is `wms2-web-ui/plugins/adjustmentAlerts.client.js:202,211`
— **timer-driven, not a screen** — so it fires for every logged-in web user. §0.7 confirms it has **no
`util/appMenuList.js` row at all** (the `WEB_UI_VIEW_STOCK_UNIT_RECORD` row at `:120` is the *Stock
Unit Record report* screen, a different caller), so no existing UI gate hides it.

| | **(a) gate + paired `wms2-web-ui` skip guard, same slice (CHOSEN — Nam)** | (b) gate now, UI later | (c) defer the row entirely |
|---|---|---|---|
| Pro | Closes the read and the UX regression together. The `functionsLoaded` skip pattern already exists (`store/handlingUnits/stockUnits.js:56`, `store/handlingUnits/container.js:44`). | Ships the security fix immediately. | No regression. |
| Con | Makes slice 3 two-repo, with a deploy-order constraint (§5.1 row 4). | **Recurring 403 + error toast on a timer** for the 56/100 dev users lacking the function. Noticed within minutes. | Leaves a known ungated read owned by nobody. |

---

---

# MVC read-surface function gating — 95 ungated `/v3` read routes

**Ticket:** SBDEV-3158 · **Project:** wms2 · **Version:** v2 · **Type:** security / authorization
**Priority:** High · **Status:** draft v2 (ralplan round 2) · **Date:** 2026-09-03
**Base:** `origin/develop` @ `3941fb26`, tree clean.

---

## 0. What changed from the handoff, up front

### 0.1 🔴 The count is **89 methods across 89 paths, one-to-one** — not "86 handlers / 91 paths"

The analysis bundle framed the surface as *"86 WMS handlers across 91 paths, 5 of them multi-mapped."*
**Four of those five "multi-mapped methods" are OVERLOADS**, not one method carrying two paths:

| class | name | reality |
|---|---|---|
| `ClubLineController` | `getActiveClubRun` | **2 overloads** — `:234` `(String keyword, …)` → `/activeClubRun`; `:253` `(Principal)` → `/inactiveClubRun` |
| `ClientController` | `getDetailView` | **2 overloads** — `:191` `(Principal)`; `:196` `(Long, Principal)` |
| `ItemDataController` | `itemdataDetailsById` | **3 overloads** — `:178` `(Long, …)`; `:184` `(String, …)`; `:320` `(String, String, …)` |
| `DashboardController` | `orderMonitorViewBySectionName` | **2 overloads** — `:54` `(String, …)`; `:66` `(String, String, …)` |

An overload needs **its own annotation**. Planning for "one annotation covering two paths" would have
shipped 5 ungated routes with the pin green, because the pin is path-keyed and would simply have had
no row for them.

The bundle's dedup key was `declaringClass + handler`, i.e. **method name** — the exact undercount
SBDEV-3142 §7.2 warned about (*"count by `(declaringClass, path)`, not by name"*). Re-derived
path-keyed from `target/surface-inventory.tsv` (generated from the live
`RequestMappingHandlerMapping`, 2026-09-03 11:38):

```
awk -F'\t' 'NR>1 && $7=="read" && $8=="" && $9=="" && $10=="" && $5 ~ /^net\.aim_ai\.wms/'
→ 109 (class#name, path) rows
   −14  RestExceptionHandlerUnitTest$ThrowingController   (TEST classes — the scan sees src/test)
   − 5  non-/v3 (/rest/**, /api/public/**)                 out of scope, Nam 2026-08-27
   − 2  UserAdministrationController                       in-body gated (§0.8)
   = 89 rows / 84 distinct method NAMES / 89 distinct PATHS
```

**89 GET routes, one annotation each.** Plus the 6 POST-as-query reads of §0.3 = **95 routes**.
The "84" in the handoff is the *name-keyed* count and must not be used for planning.

*Blind spot, inline: the TSV sees only `RequestMappingHandlerMapping` — no Spring Data REST route, no
`/rest/**`, no filter, no `@ControllerAdvice`. "Ungated" here is a statement about MVC annotations
only.*

### 0.2 🔴 `AdminActionController.triggerUpdateStock` must **STAY UNGATED**. §E.1 is wrong.

The analysis calls it *"a single miss from the SBDEV-3154 sweep."* It is a **deliberate, documented,
pinned exclusion**, and gating it would destroy the tripwire SBDEV-3198 AC13 installed. From
`Sbdev3017TrancheGateContextTest`, live on `develop`:

> `triggerUpdateStock` is deliberately not gated: `StockCountRestController:103` exposes
> `GET /rest/stockcount/triggerStockCount` onto the **same** `stockSummaryExportJob` (`:110`) and
> `SecurityConfiguration:150-154` `permitAll()`s `/rest/**`, so gating only the adminAction copy
> would be **cosmetic**. Reaffirmed by Nam 2026-09-02 … Owned by **SBDEV-3124**.

Confirmed live in the TSV: `/rest/stockcount/triggerStockCount` present and ungated; OMS calls it
(`oms-laravel-api` `WmsApiService.php:2554` via `config/wms.php:79`).

**Action: leave ungated; keep its UNGATED pin row.** The general rule this yields —
***before gating any action-shaped `/v3` route, grep `controller/rest/` for a twin on the same service
method*** — becomes a blocking prerequisite (§5.1 row 6) and is why `sendStockUpdate` gets the same
check.

### 0.3 🟠 Six POST-as-query reads are **ours**; the GET-only sweep missed them

SBDEV-3142 §7.1 hands these here explicitly (*"reads on `/v3`, so they sit inside SBDEV-3158's ~90 by
construction… cross-referenced on 3158"*). The bundle's `kind=read` filter is **verb-derived**, so
these are labelled `MUTATE` and never entered its candidate set. Verified still ungated on `develop`.
See rows 90-95 of §0.5. **Taken in, gated on a prerequisite audit of the three `*export*` SERVICE
methods** (3142 read only the controller bodies; precedent for export paths writing a flag is
SBDEV-2485's `printable`). Any writer leaves this ticket.

### 0.4 🟠 This ticket **consumes** the last UNGATED pin rows on two controllers

Nine rows currently asserted UNGATED flip to gated here, and the pin says so itself: *"The ~90
remaining `/v3` MVC reads are SBDEV-3158's scope. When 3158 gates them these rows go red, and updating
them is that ticket's job — a red here is the pin working, not drift."*

- `ClubLineController` — `/v3/clubLine/orderBatch/{orderBatchId}`, `/v3/clubLine/openClubRun`
- `TransfersController` — `/v3/transfers/transferOrder/{customerOrderId}`, `/v3/transfers/openTransfer`
- `DashboardController` × 5

`DashboardController` is independently protected (`FunctionGuardArchTest` `SHARED_CONTROLLERS`).
**`ClubLineController` and `TransfersController` are protected by nothing else** — the pin says so.
**AC-7** replaces the tripwire with direct class-level-absence assertions.

#### 0.4.1 ✅ `/v3/clubLine/availableStagingLanes` — both reviewers flagged it; the hypothesis is falsified, and §0.4 survives

Both review lanes independently suspected this route was designated to **stay** ungated, which would
have meant `ClubLineController` keeps a tripwire row and AC-7 is unnecessary. **It is not.** Read the
pin's own words at `Sbdev3017TrancheGateContextTest:422-427`:

> `GET /v3/clubLine/availableStagingLanes` stays ungated while its transfer twin
> `/availableTransferLanes` is gated, so the club screen enumerates lanes then refuses the assignment
> while the transfer screen refuses the enumeration first. Low value and squarely **SBDEV-3158's
> scope**; **deliberately NOT added as an ungated row below**, because asserting it "must stay
> ungated" would assert that asymmetry is correct, **and it is not**.

Three consequences, all confirmed against source and the TSV:

1. It **is** in scope — `ClubLineController.java:314`, `kind=read`, `rf=[]`. It is **row 11** of §0.5,
   gated `WEB_UI_VIEW_CLUB_LINE`. It was already inside the 89; it was never missing from the count.
2. It is **not a pin row at all** — neither gated nor ungated. So it cannot serve as
   `ClubLineController`'s tripwire, and §0.4's claim stands unchanged: after slice 1 that controller
   has **zero** ungated rows. **AC-7 remains blocking.**
3. Gating it **resolves an asymmetry the pin explicitly complains about**: today the club screen
   enumerates staging lanes to anyone and then refuses the assignment, while its transfer twin refuses
   the enumeration first. This is a supporting argument for slice 1, not a caveat.

### 0.5 The route table — all 95, the authority AC-1 re-derives against

Legend: **fn** = target function(s); multiple = **ANY-of**. **Caller** = file:line in `wms2-web-ui`
unless prefixed `mob:` (`wms2-mobile-ui`). **⚠fn** = inferred target, controller has zero gated
siblings (AC-16 obliges the review lane to name these). All verbs GET unless stated.

#### Slice 1 — Outbound (27)

| # | class | path | fn | caller |
|---|---|---|---|---|
| 1 | BillOfLading | `/v3/billOfLading/bolDetailsById/{id}` | `VIEW_BILL_OF_LADING` | 5 gated siblings |
| 2 | BillOfLading | `/v3/billOfLading/closedBol` | `VIEW_BILL_OF_LADING` | *handler named `getClosedClubRun` — misleading* |
| 3 | BillOfLading | `/v3/billOfLading/getDestinations` | `VIEW_BILL_OF_LADING` | |
| 4 | BillOfLading | `/v3/billOfLading/openBol` | `VIEW_BILL_OF_LADING` | *handler named `getOpenClubRun`* |
| 5 | BillOfLading | `/v3/billOfLading/nameExists/{name}` | **`VIEW_BILL_OF_LADING` + `VIEW_CREATE_INBOUND_BOL`** | `createBol.vue:241` (D.4) |
| 6 | ClubLine | `/v3/clubLine/activeClubRun` | `VIEW_CLUB_LINE` | overload 1 of 2 |
| 7 | ClubLine | `/v3/clubLine/inactiveClubRun` | `VIEW_CLUB_LINE` | **overload 2 of 2 — separate annotation** |
| 8 | ClubLine | `/v3/clubLine/closedClubRun` | `VIEW_CLUB_LINE` | |
| 9 | ClubLine | `/v3/clubLine/openClubRun` | `VIEW_CLUB_LINE` | **flips an UNGATED pin row** |
| 10 | ClubLine | `/v3/clubLine/orderBatch/{orderBatchId}` | `VIEW_CLUB_LINE` | no UI caller (D.3); **flips an UNGATED pin row** |
| 11 | ClubLine | `/v3/clubLine/availableStagingLanes` | `VIEW_CLUB_LINE` | §0.4.1 — closes the twin asymmetry |
| 12 | CustomerOrderBatch | `/v3/customerOrderBatch/customerorderBatchDetailsById/{id}` | `VIEW_ORDER_BATCH` | |
| 13 | CustomerOrderBatch | `/v3/customerOrderBatch/orderContents/{orderBatchId}` | **`VIEW_ORDER_BATCH` + `VIEW_CLUB_LINE`** | `store/outbound/club.js:303` |
| 14 | CustomerOrder | `/v3/customerOrder/detailsByBolId` | `VIEW_ORDER` | |
| 15 | CustomerOrder | `/v3/customerOrder/detailsByOrderId/{orderId}` | **`VIEW_ORDER` + `VIEW_CLUB_LINE` + `VIEW_BILL_OF_LADING`** | 3 callers: club / BOL / pickPack |
| 16 | CustomerOrder | `/v3/customerOrder/closedPickPack` | `VIEW_ORDER` | |
| 17 | CustomerOrder | `/v3/customerOrder/detailView/{orderBatchId}` | `VIEW_ORDER` | |
| 18 | CustomerOrder | `/v3/customerOrder/openPickPack` | `VIEW_ORDER` | |
| 19 | CustomerOrderPosition | `/v3/customerOrderPosition/detailsByOrderId/{orderId}` | **⚠fn** `VIEW_ORDER_POSITION` | zero gated siblings |
| 20 | Transfers | `/v3/transfers/activeTransfer` | `VIEW_TRANSFER_ORDER` | 9 gated siblings |
| 21 | Transfers | `/v3/transfers/allOpenTransfer` | `VIEW_TRANSFER_ORDER` | |
| 22 | Transfers | `/v3/transfers/closedTransfer` | `VIEW_TRANSFER_ORDER` | |
| 23 | Transfers | `/v3/transfers/inactiveTransfer` | `VIEW_TRANSFER_ORDER` | |
| 24 | Transfers | `/v3/transfers/openTransfer` | `VIEW_TRANSFER_ORDER` | **flips an UNGATED pin row** |
| 25 | Transfers | `/v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` | `VIEW_TRANSFER_ORDER` | ⚠ *sharpest row — see §3.1* |
| 26 | Transfers | `/v3/transfers/transferOrder/{customerOrderId}` | `VIEW_TRANSFER_ORDER` | no UI caller (D.3); **flips an UNGATED pin row** |
| 27 | BillOfLading | **POST** `/v3/billOfLading/exportOutboundBol` | `VIEW_BILL_OF_LADING` | §0.3 — pending service audit |

#### Slice 2 — Master data (26)

| # | class | path | fn | caller |
|---|---|---|---|---|
| 28 | BoxType | `/v3/boxType/boxtypeDetailsById/{id}` | `VIEW_CASE_TYPE` | |
| 29 | BoxType | `/v3/boxType/detailView` | `VIEW_CASE_TYPE` | |
| 30 | Client | `/v3/client/allClients` | `VIEW_CLIENT` | 3 gated siblings |
| 31 | Client | `/v3/client/{id}/effectivePutawayDestination` | `VIEW_CLIENT` | |
| 32 | Client | `/v3/client/detailView` | `VIEW_CLIENT` | overload 1 of 2 |
| 33 | Client | `/v3/client/detailViewById/{id}` | `VIEW_CLIENT` | **overload 2 of 2** |
| 34 | Client | `/v3/client/receivingPrintIdByNumber/{number}` | **`VIEW_CLIENT` + `VIEW_RECEIVING`** | `receivingForm.vue:565` (D.4) |
| 35 | ItemData | `/v3/itemData/{id}/effectivePutawayDestination` | **⚠fn** `VIEW_ITEM_DATA` | zero gated siblings on class |
| 36 | ItemData | `/v3/itemData/detailView` | **⚠fn** `VIEW_ITEM_DATA` | |
| 37 | ItemData | `/v3/itemData/detailViewByKeyword` | **⚠fn** `VIEW_ITEM_DATA` | *handler `getExportData`* |
| 38 | ItemData | `/v3/itemData/itemdataDetailsById/{id}` | **⚠fn** `VIEW_ITEM_DATA` | overload 1 of 3 |
| 39 | ItemData | `/v3/itemData/itemdataDetailsByNumber/{itemNumber}` | **⚠fn** `VIEW_ITEM_DATA` | overload 2 of 3; no UI caller |
| 40 | ItemData | `/v3/itemData/itemdataDetailsByNumberAndClientNumber/{itemNumber}/{clientNumber}` | **`VIEW_ITEM_DATA` + `VIEW_RECEIVING` + `VIEW_CLUB_LINE`** | overload 3 of 3; **11 web callers** |
| 41 | ItemData | `/v3/itemData/sendStockUpdate/{itemdataid}` | `VIEW_ITEM_DATA` | **ACTION** (§E.2); no UI caller; pending `/rest` twin check |
| 42 | Location | `/v3/location/detailView` | `VIEW_STORAGE_LOCATION` | |
| 43 | Location | `/v3/location/locationDetailsById/{id}` | `VIEW_STORAGE_LOCATION` | |
| 44 | Printer | `/v3/printer/defaultPrintersByType/{type}/{id}` | `VIEW_PRINTER` | no UI caller (D.3) |
| 45 | Printer | `/v3/printer/getTypes` | `VIEW_PRINTER` | no UI caller (D.3) |
| 46 | Printer | `/v3/printer/inboundPrinters` | **`VIEW_PRINTER` + `VIEW_CONTAINER`** | `store/handlingUnits/container.js:208` |
| 47 | Printer | `/v3/printer/outboundTotePrinters` | **`VIEW_PRINTER` + `VIEW_ORDER_MONITOR`** | `store/dashboard/pickpackMonitor.js:133` |
| 48 | Printer | `/v3/printer/printerDetailsById/{id}` | `VIEW_PRINTER` | 4 gated siblings |
| 49 | PutawayConfig | `/v3/putawayConfig/eligibleLocations` | **`VIEW_ITEM_DATA` + `VIEW_CLIENT` + `VIEW_SYSTEM_PROPERTY`** | Axis D; `configuration.js:640-647` |
| 50 | PutawayConfig | `/v3/putawayConfig/preview` | **same 3-way** | Axis D; `configuration.js:521` |
| 51 | Section | `/v3/section/detailView` | `VIEW_SECTION` | |
| 52 | Section | `/v3/section/getPickingTypes` | `VIEW_SECTION` | |
| 53 | Section | `/v3/section/sectionDetailsById/{id}` | `VIEW_SECTION` | |

#### Slice 3 — Inventory (22)

| # | class | path | fn | caller |
|---|---|---|---|---|
| 54 | CycleCount | `/v3/cycleCount/cycleCountDetailsById/{id}` | `VIEW_CYCLECOUNT` | |
| 55 | CycleCount | `/v3/cycleCount/detailView` | `VIEW_CYCLECOUNT` | |
| 56 | ReplenishOrder | `/v3/replenishOrder/detailView` | **`VIEW_REPLENISHMENT_ORDER` + `MOBILE_VIEW_REPLENISHMENT`** | `replenishments.js:155,357`; `mob:pages/replenish.vue:143` |
| 57 | ReplenishOrder | `/v3/replenishOrder/getPickableLocations` | `VIEW_REPLENISHMENT_ORDER` | 6 gated siblings |
| 58 | ReplenishOrder | `/v3/replenishOrder/loadOrderByDestination/{locationName}` | `VIEW_REPLENISHMENT_ORDER` | |
| 59 | ReplenishOrder | `/v3/replenishOrder/replenishorderDetailsById/{id}` | `VIEW_REPLENISHMENT_ORDER` | |
| 60 | ReplenishOrder | `/v3/replenishOrder/stockUnitInfoForReplenishment/{id}` | `VIEW_REPLENISHMENT_ORDER` | |
| 61 | StockRecord | `/v3/stockrecord/adjustmentAlerts` | **⚠fn** `VIEW_STOCK_UNIT_RECORD` | **Axis E — plugin, paired UI change** |
| 62 | StockRecord | `/v3/stockrecord/stockRecordDetailsById/{id}` | **⚠fn** `VIEW_STOCK_UNIT_RECORD` | `store/reports/stockUnit.js:98` |
| 63 | StockUnit | `/v3/stockUnit/detailView` | ANY-of `VIEW_STOCK_UNIT` + `VIEW_CONTAINER` | shipped as ANY-of — /handlingUnits/handling-units toggles both tabs with no per-tab check |
| 64 | StockUnit | `/v3/stockUnit/isUnitLoadIdValid/{labelId}` | **`VIEW_STOCK_UNIT` + `MOBILE_VIEW_STOCK_TRANSFER`** | `stockUnits.js:384`; `mob:store/moveStock.js:239` |
| 65 | StockUnit | `/v3/stockUnit/stockunitDetailsById/{id}` | ANY-of `VIEW_STOCK_UNIT` + `VIEW_CONTAINER` | shipped as ANY-of, same reason as row 63 |
| 66 | UnitLoad | `/v3/unitLoad/childrenUnitloads/{parentId}` | ANY-of `VIEW_STOCK_UNIT` + `VIEW_CONTAINER` | narrowed from a 4-way in review — sole caller is Handling Units only, CLUB_LINE/TRANSFER_ORDER had no caller |
| 67 | UnitLoad | `/v3/unitLoad/search/findByItemForReplenish` | **`MOBILE_VIEW_REPLENISHMENT` (mobile-ONLY)** | `mob:util/replenishUnitLoads.js:18`; **zero web callers** |
| 68 | UnitLoad | `/v3/unitLoad/detailView` | ANY-of `VIEW_STOCK_UNIT` + `VIEW_CONTAINER` | shipped as ANY-of, same reason as row 63 |
| 69 | UnitLoad | `/v3/unitLoad/unitloadDetailsById/{id}` | **4-way as row 66** | 5 web callers |
| 70 | UnitLoad | `/v3/unitLoad/unitloadDetailsByLabelId/{labelId}` | ANY-of `VIEW_CLUB_LINE` + `VIEW_TRANSFER_ORDER` | narrowed from a 4-way in review — all 4 callers are Club Run/Transfer Picking only, unlike its *ById* sibling which also has a Handling Units caller |
| 71 | UnitloadRecord | `/v3/unitloadRecord/unitloadRecordDetailsById/{id}` | **⚠fn** `VIEW_UNIT_LOAD_RECORD` | corroborated by `ReportController.exportContainerRecord` |
| 72 | CycleCount | **POST** `/v3/cycleCount/export` | `VIEW_CYCLECOUNT` | §0.3 — pending service audit |
| 73 | CycleCount | **POST** `/v3/cycleCount/itemDataView` | `VIEW_CYCLECOUNT` | §0.3 |
| 74 | CycleCount | **POST** `/v3/cycleCount/locationView` | `VIEW_CYCLECOUNT` | §0.3 |
| 75 | CycleCount | **POST** `/v3/cycleCount/positionView` | `VIEW_CYCLECOUNT` | §0.3 |

#### Slice 4 — Inbound (7)

| # | class | path | fn | caller |
|---|---|---|---|---|
| 76 | Advice | `/v3/advice/adviceDetailsById/{id}` | `VIEW_INBOUND_BOL` | 5 gated siblings |
| 77 | Advice | `/v3/advice/detailView` | `VIEW_INBOUND_BOL` | |
| 78 | GoodsReceiptPosition | `/v3/goodsReceiptPosition/detailsByAdvicePositionId/{advicePositionId}` | `VIEW_GOODS_RECEIPT_POSITION` | *handler name unrelated to path* |
| 79 | Receiving | `/v3/receiving/getPalletsForReceiving` | `VIEW_RECEIVING` | 6 gated siblings |
| 80 | Receiving | `/v3/receiving/getPutawayDestination/{advicePositionId}` | `VIEW_RECEIVING` | |
| 81 | Receiving | `/v3/receiving/getRequireReceivingToContainer` | `VIEW_RECEIVING` | |
| 82 | Advice | **POST** `/v3/advice/exportInboundNotice` | `VIEW_INBOUND_BOL` | *declared as `exportOutboundBol`* ⚠; §0.3 |

#### Slice 5 — Dashboard + admin/system (13)

| # | class | path | fn | caller |
|---|---|---|---|---|
| 83 | Dashboard | `/v3/dashboard/orderMonitorClientViewSummary` | `VIEW_ORDER_MONITOR` | **flips an UNGATED pin row** |
| 84 | Dashboard | `/v3/dashboard/orderMonitorViewBySectionName/{sectionName}` | `VIEW_ORDER_MONITOR` | overload 1 of 2; **flips** |
| 85 | Dashboard | `/v3/dashboard/orderMonitoClientrViewBySectionName/{clientName}/{sectionName}` | `VIEW_ORDER_MONITOR` | overload 2 of 2; **live typo — do NOT fix**; **flips** |
| 86 | Dashboard | `/v3/dashboard/orderMonitorViewSummary` | **`VIEW_ORDER_MONITOR` + `MOBILE_VIEW_PICKING`** | `mob:store/picking.js:246`; **flips** |
| 87 | Dashboard | `/v3/dashboard/replenishMonitorViewSummary` | **`VIEW_REPLENISHMENT_MONITOR` + `VIEW_ORDER_MONITOR` + `MOBILE_VIEW_REPLENISHMENT`** ⚠ WIDENED, see below | `mob:pages/replenish.vue:129,149`; **flips** |
| 88 | Message | `/v3/message/detailView` | **⚠fn** `VIEW_MESSAGES` — corroborated real, see below | zero gated siblings |
| 89 | Message | `/v3/message/messageDetailsById/{id}` | **⚠fn** `VIEW_MESSAGES` — corroborated real, see below | |
| 90 | Message | `/v3/message/resend/{messageId}` | `VIEW_MESSAGES` | **ACTION** (§E.3); `store/admin/serviceLogs.js:78` |
| 91 | System | `/v3/system/searchSystemByGroupname/{groupName}` | **⚠fn** `VIEW_SYSTEM_PROPERTY` — corroborated real, see below | 5 callers in `store/admin/configuration.js` |
| 92 | System | `/v3/system/mobileUiUrl` | **`@PublicHandler`** | web-ui ONLY (`pages/index.vue:103`); mobile-ui defines the identical action but dispatches it nowhere — see below |
| 93 | TenantHealth | `/v3/tenant/health` | **`@PublicHandler`** | mobile-ui ONLY (`pages/index.vue:117`); web-ui defines the identical action but dispatches it nowhere — see below |
| 94 | Token | `/v3/user` | **UNGATED — confirmed self-echo, D.6 resolved** | live probe 2026-09-04, see below |
| 95 | AdminAction | `/v3/adminAction/triggerUpdateStock` | **UNGATED — SBDEV-3124** | §0.2 |

**Disposition:** 91 function gates + 2 `@PublicHandler` + 2 recorded-ungated = 95.

**Corrections from slice 5's implementation** (full per-route caller trace,
`SBDEV-3158-evidence/slice5-caller-trace.md`, both UIs, 2026-09-04):

- **Row 87 widened to a 3-way ANY-of.** `VIEW_REPLENISHMENT_MONITOR` is DB-granted but gates ZERO
  menu screens in `wms2-web-ui` (confirmed dead, same H1 method as slice 1's finding). The route's
  real (only) web caller is a widget on the Dashboard page, gated by `VIEW_ORDER_MONITOR` — added per
  D.4 rather than substituting for the dead constant, so the DB-granted-but-unmapped one is not
  silently dropped from the gate's declared intent.
- **Rows 88, 89, 91 (⚠fn) all corroborated as real, live gates** — present in both
  `util/appMenuList.js`'s Admin-row ANY-of array and per-tab `fn:` in `pages/admin.vue`. None turned
  out to be dead constants; the inference held.
- **Rows 92/93's "bootstrap, both UIs" framing was imprecise for each, in opposite directions.** Row
  92 (`/system/mobileUiUrl`) is called unconditionally pre-entitlement only on **web-ui**
  (`pages/index.vue:103`); the identical mobile-ui action exists (`store/index.js`) but is never
  dispatched from anywhere. Row 93 (`/tenant/health`) is the mirror image: called unconditionally
  pre-entitlement only on **mobile-ui** (`pages/index.vue:117`); the identical web-ui action exists
  but is never dispatched, so `state.tenantHealth` sits at its hardcoded `true` default for the whole
  session. Neither correction changes the `@PublicHandler` disposition — each route's one real
  bootstrap caller already requires it on its own.

### 0.6 ANY-of recount: **16 rows**, not 6

Draft v1 said "6 ANY-of rows" — that was the analysis's count of *mobile-driven* ANY-of rows and
ignored the 10 more that D.4's caller-screen rule creates. Precise list: rows **5, 13, 15** (slice 1);
**34, 40, 46, 47, 49, 50** (slice 2); **56, 64, 66, 69, 70** (slice 3); **86, 87** (slice 5).
**4 of the 16 involve a mobile function** (56, 64, 86, 87), plus **row 67 as a separate mobile-only
single-function row** — 67 is not an ANY-of row and must not be counted as one. Every figure downstream — §3.3's framing, §10's risk row, AC-4, AC-15 — uses 16.

### 0.7 ✅ DD1 resolved by measurement: slice 2 is **one-repo**; only slice 3 is two-repo

Draft v1 left this an unresolved OR. The `wms2-web-ui` gating mechanism is two layers:

1. **`util/appMenuList.js`** — each menu row declares `fn:`; rows the user's function set does not
   cover are not rendered. The Admin row is an **ANY-of its seven tabs**.
2. **`pages/admin.vue`** — for admin tabs, each tab declares its own `fn:` and is gated individually.
3. **`middleware/require-function.js`** — the deep-link route guard (`functionsError` /
   `!functionsLoaded` → `/unhealthy-tenant`; loaded-but-missing → `/not-authorized?page=&fn=`).

**The decision procedure** for "is this slice one-repo or two?": for each route, find its calling
screen, look up that screen's `fn:` in `appMenuList.js` (or `pages/admin.vue` for an admin tab), and
compare against this plan's chosen gate.

- Same constant → the UI already hides the screen from exactly the denied population → **one-repo**.
- Different / weaker constant, **or no row at all** → the denied user still reaches the caller → **two-repo**.

Applied and measured:

| gate | UI row | verdict |
|---|---|---|
| `VIEW_CLIENT` | `pages/admin.vue:58` Shippers, `fn: WEB_UI_VIEW_CLIENT` | ✅ one-repo |
| `VIEW_PRINTER` | `pages/admin.vue:60,61` Label Printing + Printer Setup, `fn: WEB_UI_VIEW_PRINTER` | ✅ one-repo |
| `VIEW_SYSTEM_PROPERTY` | `pages/admin.vue:57` Parameters & Configuration | ✅ one-repo |
| `VIEW_MESSAGES` | `pages/admin.vue:62` Service Log | ✅ one-repo |
| `VIEW_STORAGE_LOCATION` / `VIEW_SECTION` / `VIEW_ITEM_DATA` / `VIEW_CASE_TYPE` | `appMenuList.js:87,91,98,100` | ✅ one-repo |
| **`VIEW_STOCK_UNIT_RECORD` via `adjustmentAlerts`** | **no row — the caller is a PLUGIN**, not the report screen at `:120` | ⛔ **two-repo** |

**So DD1's worry resolves in the plan's favour for slice 2**: the 17 denied users already cannot reach
the Client and Printer screens through the UI, so gating the endpoints removes a *direct-URL* exposure
without changing anybody's working day. **Slice 3 row 61 is the sole two-repo row.** AC-10 encodes
this procedure so an implementer can re-run it rather than trust this table.

### 0.8 Exclusions

| what | count | why |
|---|---|---|
| `UserAdministrationController` `isWarehouseUser`, `userExistsInKeycloak` | 2 | **In-body gated** — `:181`/`:225` mappings, `:184`/`:227` `denyUnlessUserManagementAllowed()`, which calls `accessService.doesUserHaveAccess` at `:120` and throws `AccessDeniedException` at `:124`. *Blind spot: this grep finds guards written as a call in the controller; one pushed down into a `@Service` would not match. Six zero-gated-sibling controllers were spot-checked, not exhaustively audited.* |
| springdoc `/v3/api-docs*` | 5 | Third-party classes; `@RequiresFunction` is unwritable on them. **Carved out — Appendix A.** |
| `/rest/**`, `/api/public/**` reads | 5 | Internal WMS↔OMS, `permitAll` by design, deferred (Nam 2026-08-27). |
| `RestExceptionHandlerUnitTest$ThrowingController` | 14 | **Test** classes the src-wide scan sees. |

---

## 1. Problem Statement

**95 WMS-authored `/v3` MVC read routes carry no authorization annotation.** Any authenticated
principal holding the coarse Keycloak `wms_user` role can call every one, regardless of which screens
their WMS `group → role → function` entitlements grant.

Same defect class as SBDEV-2967 / 3017 / 3142 / 3154 / 3155, all merged or `on dev`. Those closed the
write surface, the report/monitor reads (3142 — out of scope here), the admin action console and the
state-changing GETs. This is the remaining general read surface.

### 1.1 Why the coarse role is not a control

Nam's authz axis decision (2026-08-26): **Keycloak is coarse** (`wms_user` = "may reach the app"),
**all fine-grained authorization lives in the WMS function model**. `wms_user` is the design; the
function gate is the half that is missing here.

### 1.2 The exposure denies real people — measured, users not roles

Join chain: `mywms_function → mywms_role_mywms_function → mywms_group_mywms_role →
mywms_group_mywms_user → mywms_user`. On `wms2-wineco-dev` (100 users, 54 holding ≥1 function),
denial is **function-specific**, not "these users are in no group" — holders spread 37→46:

| function | provisioned users | **denied after the fix** |
|---|---|---|
| `WEB_UI_VIEW_CLIENT` | 54 | **17** |
| `WEB_UI_VIEW_PRINTER` | 54 | **17** |
| `WEB_UI_VIEW_IMPORT_DATA` | 54 | **17** |
| `WEB_UI_VIEW_CLUB_LINE` | 54 | **9** |
| `WEB_UI_VIEW_TRANSFER_ORDER` | 54 | **8** |

Concrete: **`ursulajimenez` holds 62 distinct functions** and holds neither `WEB_UI_VIEW_CLIENT` nor
`WEB_UI_VIEW_PRINTER`. She can read `GET /v3/client/allClients` and
`GET /v3/printer/printerDetailsById/{id}` today. Also `markchilcote` (61), `jovanyaguilera` (61),
`daniilandriyenko` (61), `danielvalentim` (51).

### 1.3 🔴 What this ticket does NOT close

1. **PRD.** All 7 provisioned `wms2-hydra` users hold all 79 granted functions. Roll-out risk ~zero
   **and security benefit ~zero**. This closes a **live dev/UAT** exposure and a **latent PRD** one.
2. **Spring Data REST.** Where a gated MVC read has an SDR twin on the same entity, the capability
   survives. SDR read gating is **SBDEV-3169's**, and every tenant is at `SdrGuardMode.OFF`.
   Per-entity substitutability is **not audited here** and must not be implied.
3. **`/rest/**` and `/api/public/**`** — deferred pending an OMS-team plan. §0.2 shows how this bites.
4. **`/v3/api-docs*`** — Appendix A.

---

## 2. Root Cause Analysis

`FunctionGuardInterceptor.preHandle` resolves in this order:

1. Spring Data REST handler → `SdrFunctionGuard` (different rule source).
2. `@PublicHandler` **method-level** (`handlerMethod.getMethodAnnotation`, `:211`) → allow, increment
   `wms2.authz.public` (`:234`).
3. `@RequiresFunction` method-level (captured at **`:216`** as `methodLevel`), else the **class-level
   fallback at `:239-241`** — `AnnotationUtils.findAnnotation(declaring, RequiresFunction.class)`.
4. **Nothing resolves and the declaring class is not in `GUARDED` → ALLOW** (`:243-244`).

Step 4 is the defect. The interceptor is **fail-open** outside `GUARDED` (14 controllers — the mobile
family plus user administration). None of this ticket's 24 controllers is in it, so 95 routes resolve
nothing and are allowed.

Fail-open is deliberate, not a bug: fail-closed on any unannotated handler would take the fleet down
on every new controller. `GUARDED` is the opt-in list where fail-closed applies. **The remedy is to
annotate the handlers, not to flip the default.**

**⚠ Do not "fix" this by widening `GUARDED`.** `ClientController` and `BoxTypeController` carry
**OMS carve-out** routes that OMS calls as a principal with **no `mywms_user` row**; any gate there
resolves `USER_NOT_PROVISIONED → 403` and facility/catalog sync fails **silently**. This plan makes
**no `GUARDED` change except the two required by `@PublicHandler` AC-7d** (§3.5).

### 2.1 The ticket's "landmine #1" is non-exploitable — proof

The ticket warns that `SurfaceInventoryContextTest` resolves on `hm.getBeanType()` (the **subclass**)
while the interceptor resolves on `getDeclaringClass()`, so inherited handlers could be undercounted.
The divergence is real and large but **non-exploitable**:

1. `AdminController` is itself `@RestController @RequestMapping("/v3")` with **9 mapped handlers**, and
   **43 classes extend it** → **410 inherited rows**, 158 carrying a subclass class-level annotation
   the interceptor never finds.
2. All 9 carry method-level `@PreAuthorize(Authority.IS_SB_ADMIN)` (annotations `:79,107,120,133,142,154,175,237,247`;
   mappings `:80,108,…,248` — nine and nine, no gaps), and method security is on
   (`MethodSecurityConfig.java:49`). `sb_admin` is strictly narrower than any `WEB_UI_VIEW_*`.
3. The exploitable shape measures **zero**:
   `awk -F'\t' 'NR>1 && $4!=$5 && $8 ~ /^C:/ && $9=="" && $10==""' target/surface-inventory.tsv | wc -l → 0`

**0 additions.** *Blind spot: this rests on `@EnableMethodSecurity` staying on and `IS_SB_ADMIN`
remaining a real authority — both one line from regression.* §6 adds a pin.

### Affected Locations

| # | File | Sites |
|---|---|---|
| 1 | `controller/{BillOfLading,ClubLine,CustomerOrder,CustomerOrderBatch,CustomerOrderPosition,Transfers}Controller.java` | 27 (slice 1) |
| 2 | `controller/{ItemData,Client,Section,Location,BoxType,Printer,PutawayConfig}Controller.java` | 26 (slice 2) |
| 3 | `controller/{StockUnit,UnitLoad,UnitloadRecord,StockRecord,ReplenishOrder,CycleCount}Controller.java` | 22 (slice 3) |
| 4 | `controller/{Advice,Receiving,GoodsReceiptPosition}Controller.java` | 7 (slice 4) |
| 5 | `controller/{Dashboard,Message,System,TenantHealth,Token}Controller.java` | 13 (slice 5) |
| 6 | `security/FunctionGuardInterceptor.java` | `GUARDED` += `TenantHealthController`, `SystemController` (slice 5) |
| 7 | `test/.../security/Sbdev3017TrancheGateContextTest.java` | every slice; 9 UNGATED rows flip; 2 new class-level-absence tests |
| 8 | `test/.../unit/config/FunctionGuardArchTest.java` | slices 3 & 5 — `REVIEWED_SHARED_GATE_FUNCTIONS` += 18 arity-keyed entries |
| 9 | `test/.../unit/security/PublicHandlerContractArchTest.java` | slice 5 — `REVIEWED_PUBLIC_HANDLERS` += 2 arity-keyed entries |
| 10 | `wms2-web-ui plugins/adjustmentAlerts.client.js` | 1 — slice 3 paired change (Axis E) |

---

## 3. Design / Proposed Fix

### 3.0 Shape

**Method-level `@RequiresFunction` on each route, and nothing else.** No new constants, no Flyway, no
`SecurityConfiguration` change, no service change.

**Method-level, never class-level — uniformly**, including where every handler on a class lands on one
function (`TransfersController` is the tempting case). Reasons: (a) the interceptor's `resolve()`
treats both identically, so there is **no test-visibility gain**; (b) class-level auto-gates every
*future* handler, which is how an OMS carve-out route gets silently 403'd — the measured
`ClientController`/`BoxTypeController` incident in the pin's own comments; (c) it makes the "tidy up
the duplicate method annotations" refactor look attractive, and that refactor is what AC-7 exists to
stop.

### 3.1 Slice 1 — Outbound (27)

Most uniform slice; the pattern-setter. **Before / After**, representative of 18 of the 27:

```java
    @GetMapping(path = "/openTransfer", produces = "application/json")
    public Map<String, Object> getOpenTransfer(@AuthenticationPrincipal Principal principal) {
        return dtoViewService.getOpenTransferView();
    }
```

```java
    @RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_TRANSFER_ORDER)
    @GetMapping(path = "/openTransfer", produces = "application/json")
    public Map<String, Object> getOpenTransfer(@AuthenticationPrincipal Principal principal) {
        return dtoViewService.getOpenTransferView();
    }
```

Specifics: rows 6/7 are **two overloads** — annotate both. Rows 5, 13, 15 are ANY-of (§0.6). **AC-7
lands here** (§0.4). Row 11 closes the §0.4.1 asymmetry. Row 27 waits on the §5.1 service audit.

⚠ **Delete the stale comment at `Sbdev3017TrancheGateContextTest:422-426` in the same commit that
gates row 11.** That comment says `availableStagingLanes` *"stays ungated"*. The moment slice 1 gates
it the comment is **false**, and it is not inert prose: it is the exact text that led **two
independent review passes** in this ticket's own ralplan round to conclude the route was designated
to stay ungated (§0.4.1). Leaving it would re-run that confusion on the next reader, with the code
now contradicting it. Replace it with one line recording that SBDEV-3158 gated the route on
`WEB_UI_VIEW_CLUB_LINE` and that the club/transfer asymmetry it described is closed.

⚠ **Row 25** (`/v3/transfers/transferOrderByOrderBatchId/{orderBatchId}`) — flagged sharpest by
SBDEV-3142 §7.3: it takes *the same key a denied user was just 403'd on* and returns an adjacent
projection. Name it in review; do not let it pass as one list read among many.

### 3.2 Slice 2 — Master data (26)

Worst blast radius (DD1) — **but one-repo, per §0.7**. Six ANY-of rows (34, 40, 46, 47, 49, 50). Rows
32/33 and 38/39/40 are overload sets. Row 41 is an **action** pending the `/rest` twin check. Rows
49/50 take Axis D's 3-way.

⚠ `ClientController.create` and `BoxTypeController.create` are **OMS carve-outs** on classes this
slice edits — **no class-level annotation on either**; their UNGATED pin rows stay (AC-9).

### 3.3 Slice 3 — Inventory (22)

Shipped with **8 ANY-of rows** (56, 63, 64, 65, 66, 68, 69, 70 — up from the 5 the plan
originally named, per the corrections below), the mobile-only row 67, and the sole two-repo row 61.

- **Row 67 `findByItemForReplenish` → `MOBILE_UI_VIEW_REPLENISHMENT`, mobile-ONLY.** Zero web callers.
  **A `WEB_UI_*` gate here 403s the only real caller** — the single highest-risk row in the plan (AC-11).
- **Row 64** reuses the `WEB_UI_VIEW_STOCK_UNIT` + `MOBILE_UI_VIEW_STOCK_TRANSFER` pair already used
  **3×** on `StockUnitController` — strongest precedent in the set. *(A boolean validity probe, not a
  move: `StockUnitController.java:759-762`.)* This route also superseded a prior ticket's (SBDEV-2967-C)
  explicit "must stay UNGATED" pin — a fresh, exhaustive caller trace found that pin's premise (a
  caller reachable independently of the write path) no longer held; Nam confirmed the override.
- **Rows 63/65/68 widened to ANY-of `[STOCK_UNIT, CONTAINER]`, beyond the plan's original single
  function.** `/handlingUnits/handling-units` toggles ContainerTable/StockUnitsTable via a plain
  `v-select` with no per-tab function check — the page's own menu gate is already ANY-of the same
  pair, so a single-function gate on either tab's data-fetch would 403 a real, page-admitted user.
- **Rows 69 reuses the sibling `reprintLabel`'s 4-way ANY-of verbatim** (genuinely has Handling
  Units + Club Run + Transfer Picking callers). **Rows 66 and 70 do NOT** — review found row 66's
  sole caller is Handling Units only and row 70's callers are Club Run/Transfer Picking only (zero
  Handling Units caller, unlike its *ById* sibling) — both narrowed to the 2-way pair their actual
  callers need. The "reused verbatim" framing that worked for row 69 does not transfer to its two
  siblings; re-derive each route's callers individually rather than trusting sibling precedent.
- **Row 61** — Axis E: gate + the paired `wms2-web-ui` skip guard, same slice (shipped and
  Jest-tested, mutation-checked).
- **⚠ `FunctionGuardArchTest` AC-4 rail.** `StockUnitController`, `UnitLoadController` and
  `ReplenishOrderController` are three of the four `SHARED_CONTROLLERS`; every method-level
  `@RequiresFunction` on them must appear in `REVIEWED_SHARED_GATE_FUNCTIONS`, **keyed
  `Class#method/arity`** — 13 new entries here. Omit them and the build reds with an allow-list
  violation, not a gate failure. *Arity, not name: a measured escape exists where a new `removeLock`
  overload passed the whole suite against a name-only key — and §0.1 means this slice ships overloads.*

### 3.4 Slice 4 — Inbound (7)

Cheapest: all web-only, all with gated siblings on one function, zero ANY-of, zero open decisions.
**Ship first.** Row 78's handler name is unrelated to its path — key the pin on the path. Row 82 waits
on the service audit.

### 3.5 Slice 5 — Dashboard + admin/system (13)

Merges **last**.

⚠ **Row 85's typo** (`/orderMonitoClientrViewBySectionName/…`) **is live and the web UI depends on
it. Do not fix it here** — a path change un-gates the route without touching the annotation, and the
pin reports `ROUTE NOT DEPLOYED`.

⚠ A class-level annotation on `DashboardController` 403s two mobile screens; already forbidden by
`FunctionGuardArchTest` AC-4, and the 5 rows flipping from UNGATED do not weaken that.

**The `@PublicHandler` change is atomic across four files** (Axis C / AC-7d):

1. `@PublicHandler(reason = "…")` on rows 92 and 93 — `reason()` has **no default**, so it is mandatory.
2. `FunctionGuardInterceptor.GUARDED` += `TenantHealthController.class`, `SystemController.class`.
3. `PublicHandlerContractArchTest.REVIEWED_PUBLIC_HANDLERS` += `TenantHealthController#checkHealth/1`,
   `SystemController#triggerOrderReplenish/1` — **AC-7a asserts EQUALITY**, so a marker without an
   entry *and* an entry without a marker both fail.
4. Row 91 must be annotated in the **same commit** — a `GUARDED` class with a handler resolving nothing
   throws at `afterSingletonsInstantiated` and **no replica starts**. `TenantHealthController` declares
   only `checkHealth`, so it is safe alone.

*Verified safe:* `SystemController extends AdminController`, so 9 inherited handlers register under
`/v3/system/*` — but the boot assertion and the interceptor both key on `getDeclaringClass()`, which
is `AdminController` (not in `GUARDED`). This is §2.1's result applied, not assumed.

---

## 4. Resolved decisions and open questions

| # | Item | Ruling | Rationale |
|---|---|---|---|
| **D.1** | 3 bootstrap reads → `@PublicHandler`? | **ADOPTED for 2 of 3; 3rd deferred.** | Axis C. The analysis missed **AC-7d**: the marker drags its class into `GUARDED`, and for `TokenController` that forces markers onto the **login endpoint** and a webhook. |
| **D.2** | `PutawayConfig` reads — which function? | **✅ NAM: ANY-of all three.** | Axis D. Residual recorded and measured by AC-15. |
| **D.3** | 4 handlers with no UI caller | **ADOPTED: gate like their siblings.** | One annotation each; the sweep covered only the two Nuxt frontends, so "no UI caller" ≠ "no caller" — §0.2 shows exactly how that bites. Deletion **proposed, not filed**. |
| **D.4** | Sibling fn vs caller's screen disagree | **ADOPTED: ANY-of both.** | P3 + DD1. A `CLIENT`-only gate on row 34 403s receiving clerks mid-receipt. Extended consistently to rows 46, 47 and the multi-caller outbound reads. |
| **D.5** | `adjustmentAlerts` polled by a plugin | **✅ NAM: gate + paired UI fix, same slice.** | Axis E. §0.7 confirms it has **no menu row**, so no existing UI gate hides it. |
| **D.6** | Does `TokenController.user` shadow SDR `/v3/user`? | **✅ RESOLVED by live probe, 2026-09-04.** `GET /v3/user` (panderson, `wineco`/`wsl`, `kc2.dev.sbo.li`) → HTTP 200, body top-level keys `tokenValue, issuedAt, expiresAt, headers, claims, issuer, audience, subject, id` — a bare JWT-principal object, not `_embedded.user`. **MVC wins, as the static analysis predicted.** Row 94 is a harmless self-echo (returns the caller's own token/claims, nothing about other users) — stays UNGATED, no marker needed. Side effect: `store/admin/management.js:120-128`'s read of `results._embedded.user` cannot be getting a HAL collection from this path today — that's a separate, pre-existing User Management concern, not created or closed by this ticket; the SDR-vs-MVC shadowing risk itself still belongs to SBDEV-3169. |
| **D.7** | springdoc `/v3/api-docs*` | **ADOPTED: carve out.** Appendix A. | Different mechanism, different test shape, own regression risk. T1/T2, so a **proposed new ticket** — new scope found mid-analysis, not a T3 finding. |
| **§E.1** | `triggerUpdateStock` | **🔴 REJECTED — stays UNGATED.** | §0.2. |
| **§E.2** | `sendStockUpdate` | **GATED here** as an action, pending the `/rest` twin check. | Axis B. |
| **§E.3** | `resentMessage` | **GATED here** as an action. | Axis B. |
| **§0.3** | 6 POST-as-query reads | **TAKEN IN** (95 routes), pending the 3-service audit. | 3142 §7.1 assigned them here. |

### 4.1 Ticket-structure decision

**One ticket — SBDEV-3158 — five merge-ordered slices, five PRs. No slice splits off.**

SBDEV-3158 **already exists** and is `Open`, so slicing is implementation sequencing *within* it, not
a new-ticket question. Every slice is the same defect class, mechanism, pin file and acceptance shape.
Slice 2 has the worst blast radius and slice 5 the most judgement — sequencing facts (merge later, more
review lanes), not separate projects.

One thing leaves the ticket: **springdoc → a new ticket, proposed not filed** (Appendix A). Folding it
in would re-tier the host — the error SBDEV-3142 made on 2026-08-28 and retracted. `triggerUpdateStock`
stays with SBDEV-3124 (not ours to take). Conversely `sendStockUpdate` and `resentMessage` **stay
here** because 3155 is `on dev` and the policy forbids adding scope to shipped code (Axis B).

**Tier: T3** — authorization, multi-file, cross-repo (slice 3), 95 routes. 4 review lanes, full plan,
ralplan. **Opt-in verify script: NO** — every assertion belongs in JUnit, where it runs in CI, survives
refactors and is mutation-checkable. A script would grep for annotations: the false-green shape §9.1
warns about.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | **N/A** — no schema change, no Flyway. | — | Zero new constants (P1). |
| 2 | **Feature flags** | **N/A** — the gate is unconditional, deliberately **not** behind an OFF/SHADOW/FAIL_CLOSED ladder. | — | ⚠ *Corrected from draft v1, whose stated reason ("a flag ships the exposure and the fix simultaneously") contradicted the `SdrGuardMode` ladder Nam already approved for a larger surface (SBDEV-3169).* **The real reason is the population:** a shadow mode's value is the denial signal it emits before enforcement, and §G.2 shows **no v2 PRD tenant has role separation** — all 7 provisioned hydra users hold all 79 functions, so PRD shadow output is all-green by construction and proves nothing. The signal that *would* be informative is dev/UAT, and there §5.1-8's per-route denial baseline gives the same information at a fraction of the machinery. |
| 3 | **Config / env** | **N/A**. | — | |
| 4 | **Deploy-order** | Slice 3's API change and its `wms2-web-ui` change deploy **together or UI-first**. | impl | UI-first is safe (the skip guard is a no-op while the API is ungated); API-first produces the 403 toast. ⚠ Beware the `:develop` tag race — two UI merges in one build window can deploy the older image. |
| 5 | **Data migration** | **N/A**. | — | |
| 6 | **`/rest/**` TWIN CHECK — BLOCKING** | Before annotating **any** action-shaped route (rows 41, 90, 27, 72, 82), grep `src/main/java/net/aim_ai/wms/controller/rest/` for a handler reaching the same service method. | impl | §0.2. A gate whose capability has a `permitAll` twin is **cosmetic**. Any hit → that route leaves for SBDEV-3124. |
| 7 | **Per-tenant constant check** | For each slice, confirm every target constant exists **in all six tenant DBs**. | impl | **Not optional** — SBDEV-3142's review found `WEB_UI_VIEW_PARCEL_PICKING` **absent from a tenant it had already gated**; a missing constant fails that tenant closed. Tenants: `wms2-wineco-dev`, `wsl-wineco-uat`, `nywh-hydra-uat`, `c1wh-shipitez-uat`, `nywh-shipitez-uat`, `wms2-hydra` (PRD). Query, run per tenant, recording holder counts as SBDEV-3155 did:<br>`SELECT f.name, count(DISTINCT u.id) FROM mywms_function f LEFT JOIN mywms_role_mywms_function rf ON rf.functionlist_id=f.id LEFT JOIN mywms_group_mywms_role gr ON gr.rolelist_id=rf.rolelist_id LEFT JOIN mywms_group_mywms_user gu ON gu.grouplist_id=gr.grouplist_id LEFT JOIN mywms_user u ON u.id=gu.userlist_id WHERE f.name IN (<slice targets>) GROUP BY f.name;`<br>A constant absent from `mywms_function` returns **no row** — that is the failure signal, not a zero count. ⚠ The MCP connection drops its first query after idle; retry. |
| 8 | **Monitoring — quantitative** | **Before** each slice merges, record the **per-route** denial baseline from `wms2.authz.denied`. **After** deploy, diff per route. | impl | Observable at `/actuator/metrics/wms2.authz.denied` and `/actuator/prometheus` (`management.endpoints.web.exposure.include` lists `metrics,prometheus`); `/actuator/**` needs `ADMIN`/`wms_admin` (`SecurityConfiguration:147`). Also assert `wms2.authz.public` is **non-zero** after slice 5 — a drop to zero is the only signal a marker was removed and the bootstrap reads are failing closed. **ROLLBACK TRIGGER, explicit: a non-zero denial count on a route whose caller screen the UI does NOT already hide (§0.7's procedure) → revert that slice.** A denial on a route whose screen *is* hidden is the gate working. |
| 9 | **Service audit (§0.3)** | Read `adviceService.exportInboundNotice`, `billofladingService.exportOutboundBOLs`, `cyclecountService.exportCycleCounts`. | impl | 3142 read only the controller bodies. Precedent for export paths writing a flag: SBDEV-2485's `printable`. A writer leaves this ticket. |
| 10 | **§D.6 probe** | `curl -H "$AUTH" https://wms-api.dev.sbo.li/v3/user`; **"recorded" means pasting the literal response body shape on the ticket** — specifically whether the top level is `_embedded.user` (SDR won) or a bare JWT-principal object (MVC won). | Nam / impl | Blocks **row 94 only**. Do not block slices 1-4. |
| 11 | **Probe accounts** | Reuse SBDEV-3155's harness verbatim: `sbdocs/9-System/scripts/probe-wms2-mutating-get-gating-dev.sh`. | impl | It already solves token-minting: `API=https://wms-api.dev.sbo.li`, `KC=https://kc2.dev.sbo.li/realms/wineco/protocol/openid-connect/token`, `client_id=om1`, headers `X-Tenant-ID: wineco` + `facility_code: wsl`, `PW` from env. **Named accounts, and the seat each occupies:** `wmstest` **0 fns** — the deprived subject (zero is a floor and cannot drift downward); `sbtest` **35 fns** — the two-directional differential (must be denied on some rows and allowed on others; a gate that denies it everything is over-gated, one that allows everything is inert); `panderson` **80 fns** — the entitled control. ⚠ **Re-derive the grants before EVERY run** — 3155 shipped with `truckloading` on a 2-hour-old query, it gained 31 functions in between, and the run reported "5 fail" that looked exactly like an inert gate. ⚠ Use well-formed **non-existent** ids and assert **403-vs-not-403**, never an exact status. |
| 12 | **Account coverage for AC-11 and AC-4** | Two different gaps, **two different answers — decided here, not left to the implementer.** | impl | See the two sub-rows below. |
| 12a | **AC-11's mobile-only account — PROVISION IT** | ⚠ **UNRESOLVED — no such account is known to exist on dev.** Before slice 3, query for a user holding `MOBILE_UI_VIEW_REPLENISHMENT` and **no** `WEB_UI_*` function. If none exists, **provision one** (a dev-only group with that single function) rather than weakening the AC. | impl | Row 67 is the highest-risk row and `wmstest`/`sbtest`/`panderson` cannot test it: `wmstest` (0 fns) would 403 correctly for the wrong reason, and the other two hold web functions. **Provisioning is justified here because no test can substitute:** what AC-11 checks is that the chosen constant actually *reaches the real caller population*, which is a claim about grants in the DB, not about the annotation. A pin cannot see it. |
| 12b | **AC-4's per-member direction — DISCHARGED BY THE PIN, option (b)** | **Do NOT provision accounts for this.** AC-4's "either member alone → 200" direction is satisfied by the **mutation check in §6**: narrow an ANY-of set by one member → the pin reds naming that route. The **live probe covers only the union-denial direction** (holds none of the members → 403), which the three standing accounts can produce. | impl | The alternative — option (a), extending 12a's provisioning pattern — would need up to **32 purpose-built accounts** (16 ANY-of rows × 2 directions) on a **shared, live dev system whose grants demonstrably drift** (§5.1 row 11: 3155 shipped against a 2-hour-old grant query and the run read as an inert gate). That churn buys little: the ANY-of *mechanism* is already proven end-to-end once by the existing `FunctionGateEnforcementPointContextTest` / `StockUnitControllerActionGuardUnitTest` lane, so what remains per-row is **data** — which constants are in the set — and a path-keyed pin checks that for all 32 cases at flat cost, deterministically, in CI. ⚠ **Stated limit:** this discharges the *declared set*, not the *runtime semantics*. If `AccessService` ever changed ANY-of to ALL-of, the pin would stay green — that regression is covered by the enforcement-point lane above, not here, and the two must not be conflated. |
| 13 | **Baseline** | Freshly measure the full-suite baseline on `origin/develop` **immediately before** slice 1 branches. | impl | The count moved 5846→5937 in one day. ⚠ One Maven build per worktree — concurrent builds in one worktree produced 238 phantom errors. |

### 5.2 Implementation checklist

**Merge order: 4 → 1 → 2 → 3 → 5.** Slice 4 first (cheapest, zero decisions); slice 5 last (all the
judgement). All five edit the **same** pin file, so they **serialise** — rebase each on the previous
merge, and make the `thePinHasNotBeenQuietlyShrunk` size constant the **last** edit in each slice so a
conflict there is a one-line resolve, not a semantic merge.

Per slice:

- [ ] Rebase on freshly-fetched `origin/develop`; confirm the previous slice's rows are present.
- [ ] §5.1 rows 6, 7 and (slices 1/3/4) 9 — the blocking pre-checks.
- [ ] Write the **failing** pin rows first (TDD gate), one per route from §0.5. Confirm they fail with
      `expected [X] but was [UNGATED]`, **not** `ROUTE NOT DEPLOYED` — a wrong path is a silent un-gate.
- [ ] Add the annotations. **One per method, including every overload** (§0.1).
- [ ] Flip this slice's UNGATED pin rows (§0.4); update the size constant **last**.
- [ ] Slice 1: add the two class-level-absence tests (AC-7), **and delete the now-false
      `availableStagingLanes` "stays ungated" comment at `Sbdev3017TrancheGateContextTest:422-426`
      in the same commit that gates row 11** (§3.1).
- [ ] Slices 3 & 5: add the 18 `REVIEWED_SHARED_GATE_FUNCTIONS` entries, **arity-keyed**.
- [ ] Slice 5: the 4-file atomic `@PublicHandler` change (§3.5).
- [ ] Slice 3: the paired `wms2-web-ui` skip guard (Axis E).
- [ ] **Mutation-check every new gate**: delete one annotation → the pin reds **naming that route**.
      At minimum one per controller, and **every one of the 16 ANY-of rows**.
- [ ] Live probe (§5.1 row 11): the **three-way** control — no token → **401**, named non-holder →
      **403**, named holder → **200**. Two of the three prove nothing alone: 403-only cannot
      distinguish a working gate from an always-deny.
- [ ] AC-15's residual-denial measurement for every ANY-of row in the slice.
- [ ] Full suite vs the §5.1-13 baseline. One build per worktree.
- [ ] Independent review lane, **file on disk required** (an idle lane is not a pass). Fix **every**
      finding including Low.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected |
|---|---|---|
| Gate denies a real non-holder | `wmstest` (0 fns) → each route | 403 |
| Gate is differential, not blanket | `sbtest` (35 fns) → a route it holds / a route it lacks | 200 / 403 |
| Gate is not always-deny | `panderson` (80 fns) | 200 |
| Gate is not the auth layer | no token | 401, not 403 |
| ANY-of — either member allows | user holding only A; then only B | 200 both |
| ANY-of — neither allows | user holding neither | 403 |
| Mobile-only row 67 | mobile-only user (§5.1 row 12) | 200 |
| Bootstrap survives zero entitlements | 0-function user → rows 92, 93 | 200; `wms2.authz.public` increments |
| Class-level widening caught | add class-level `@RequiresFunction` to `ClubLineController` | AC-7 test reds |
| Overload individually gated | delete the annotation from **one** `itemdataDetailsById` overload | pin reds naming that one path |

### New / updated tests

| Test class | Method | Asserts |
|---|---|---|
| `Sbdev3017TrancheGateContextTest` | `everyTrancheRouteCarriesItsIntendedFunctions` | +93 gated rows; 9 UNGATED flip; 2 stay UNGATED (rows 94, 95) |
| `Sbdev3017TrancheGateContextTest` | `thePinHasNotBeenQuietlyShrunk` | 145 → **236** (145 + 93 new rows − 2 already present as UNGATED and merely re-valued). ⚠ **Recompute from the actual diff at implementation time** — this figure is an output, not an input, and a wrong constant here fails loudly rather than silently. |
| `Sbdev3017TrancheGateContextTest` | `clubLineControllerCarriesNoClassLevelFunctionGate` **(new)** | AC-7 |
| `Sbdev3017TrancheGateContextTest` | `transfersControllerCarriesNoClassLevelFunctionGate` **(new)** | AC-7 |
| `FunctionGuardArchTest` | `REVIEWED_SHARED_GATE_FUNCTIONS` | +18 arity-keyed entries |
| `PublicHandlerContractArchTest` | `REVIEWED_PUBLIC_HANDLERS` | +2 arity-keyed entries (AC-7a is **equality**) |
| `AdminControllerPreAuthorizeContextTest` **(new)** | — | §2.1's blind spot: all 9 `AdminController` mappings still carry `@PreAuthorize(IS_SB_ADMIN)` |

### Mutation-checking

PIT cannot see this change — an annotation is not a branch, so there is no mutant to kill. The check is
**manual and mandatory**: per gate, delete the annotation, run the pin, confirm it reds naming that
route, restore. **For ANY-of rows, additionally NARROW the set to one member and confirm the row reds**
— a widening/narrowing mutation is the failure mode that matters, and an all-or-nothing delete misses it.

### Manual test plan

| Scenario | Env | Steps | Expected |
|---|---|---|---|
| Web UI smoke, holder | dev | `panderson`; open each touched screen | No 403; data renders |
| Web UI smoke, non-holder | dev | `ursulajimenez`; confirm Client/Printer are **hidden** (§0.7) | Menu hides them |
| Mobile smoke | dev | Replenish + Move Stock + Picking | No 403 — the ANY-of rows |
| Adjustment-alerts polling | dev | non-holder, idle 5 min | **No recurring error toast** |
| OMS carve-out | dev | trigger a facility/catalog sync | Succeeds — the 3 carve-out routes still ungated |
| Swagger | dev | `/swagger-ui/index.html` | Still loads |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| SDR substitutability per entity | Out of scope (§1.3.2); **SBDEV-3169** owns SDR read gating, all tenants at `OFF`. **Not audited — do not imply it is.** |
| `/rest/**`, `/api/public/**` | Deferred pending an OMS-team plan. 5 ungated reads there. |
| `SecurityConfiguration` matchers | No Spring-context test can observe them — the bean is `@ConditionalOnProperty(rest.security.enabled)` and the integration profile sets it false. |
| Cypress smoke suite | A **direct caller** neither UI-grep lane can see (SBDEV-3142 §6 learned this). Run before slices 2 and 3 merge. |

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | Annotations are static metadata; `AccessService`'s caching is pre-existing and unchanged. |
| 2 | Connection pool math | **No** | A denied request does **less** DB work — it short-circuits before the handler. |
| 3 | Scheduled jobs | **No** | None added or modified. ⚠ Gating `triggerUpdateStock` **would have** touched a job path — another reason §0.2's rejection is right. |
| 4 | Long transactions | **No** | The interceptor runs before any transaction opens. |
| 5 | Request affinity | **No** | Every replica resolves the same annotations from the same bytecode. |
| 6 | Retry / idempotency | **No** | Reads. The two action gates change *who* may call, not the semantics. |
| 7 | Tenant context | **No** | Consumes the existing per-request context; no async boundary crossed. |
| 8 | Distributed locks | **No** | None added. |
| 9 | Cache invalidation | **N/A** | No writes to cached entities. (SDR write eviction is SBDEV-3176's, untouched.) |
| 10 | External notifications | **N/A — but note** | This plan sends nothing; it **gates** `sendStockUpdate`, which POSTs to OMS. An OMS-side caller lacking `WEB_UI_VIEW_ITEM_DATA` would be denied — hence §5.1 row 6, the mitigation. |

⚠ **Rolling-deploy shape, named rather than left as a surprise:** during a rolling deploy old and new
replicas serve the same route with different gates, so a user sees 200 then 403 intermittently. For a
**read**, that is confusing but not corrupting. Accepted.

---

## 8. v2-only constraint checklist

- [x] **v2 only.** v1/wms-api has no `@RequiresFunction`, no `FunctionGuardInterceptor` and no in-app
      tenant routing — the mechanism does not exist there. (Nam 2026-08-19: v1 is reference-only.)
- [x] No Flyway migration (P1).
- [x] No `SecurityConfiguration` change (carved out — Appendix A).
- [x] No new `FunctionEnum` constant. If any slice wants one → **stop and re-tier**.
- [x] `GUARDED` changes limited to the two required by AC-7d, in slice 5, atomically.
- [x] Merge target is **`develop` only**. `release` and `main` are DevOps'.

---

## 9. Acceptance criteria — **16 distinct criteria**

AC-1…AC-6 apply to **every** slice. AC-7…AC-14 are slice-specific. AC-15/AC-16 apply wherever their
trigger appears. Per-slice totals: **slice 1: 8 · slice 2: 8 · slice 3: 8 · slice 4: 6 · slice 5: 8**,
plus AC-15 (slices 1/2/3/5, wherever an ANY-of row appears) and AC-16 (slices 1/2/3/5, wherever a ⚠fn
row appears).

### Common (AC-1 … AC-6)

- **AC-1 — the set is re-derived server-side and matches §0.5's table row-for-row.** From a freshly
  regenerated `target/surface-inventory.tsv`, keyed `(declaringClass, path)` — **never by method name**
  (§0.1). Mutation-checkable: delete a row from §0.5 and the derivation disagrees.
- **AC-2 — live three-way probe on dev, before AND after, on ≥1 named route per controller**, using
  §5.1 row 11's harness and accounts: no-token → **401**; `wmstest` → **200 before / 403 after**;
  `panderson` → **200 both**; and where the slice's constants allow it, `sbtest` denied on one route
  and allowed on another. ⚠ Re-derive grants before every run. ⚠ Count **users**, not roles.
- **AC-3 — every route is gated or has a RECORDED decision.** Zero silent omissions. Rows 94 and 95
  each carry a pin row **and** a code comment naming the owning ticket.
- **AC-4 — every ANY-of row tested in both directions.** A one-direction test cannot distinguish
  ANY-of from ALL-of. Per §5.1 row 12b the two directions are discharged by **different instruments**,
  and both are required: *(i)* **each member alone → 200** is proven by the **pin mutation** — narrow
  the set by one member, the row reds naming that route; *(ii)* **neither member → 403** is proven by
  the **live probe** with `wmstest`. Neither half alone satisfies AC-4.
- **AC-5 — every gate pinned and mutation-checked against a NAMED route.** Delete → red naming the
  route. **Narrow an ANY-of set by one member → red.**
- **AC-6 — full suite green vs the §5.1-13 baseline**, plus `PublicHandlerContractArchTest`,
  `FunctionGuardArchTest` and `SurfaceInventoryContextTest`. One Maven build per worktree.

### Slice-specific

- **AC-7 (slice 1) — the class-level tripwire is REPLACED, not consumed. BLOCKING.**
  `ClubLineController` and `TransfersController` each gain a direct class-level-absence test
  (the `adminActionControllerCarriesNoClassLevelFunctionGate` pattern). Mutation: add a class-level
  `@RequiresFunction` to either → red. Justified by §0.4 and §0.4.1 — `availableStagingLanes` is **not**
  a pin row, so it cannot serve as the tripwire.
- **AC-8 (slice 1) — `getActiveClubRun`'s two overloads are separately gated**; deleting either
  annotation reds its own path.
- **AC-9 (slice 2) — the OMS carve-out survives, and the invariant names all THREE members.**
  `/v3/client/create`, `/v3/boxType/create` **and** `/v3/shipperId/create`
  (`Sbdev3017OmsCarveOutSourceContractTest:59`) remain UNGATED and free of all seven method-security
  annotations. *`ShipperIdController` has no in-scope reads, so nothing in this slice endangers it —
  but a 3-member invariant is stated with 3 members, not 2.* An OMS facility sync succeeds on dev.
- **AC-10 (slice 2) — the one-repo/two-repo branch is DECIDED by §0.7's procedure, re-run, not
  assumed.** For every route in the slice: identify the calling screen, read its `fn:` from
  `util/appMenuList.js` (or `pages/admin.vue` for an admin tab), and compare against the plan's gate.
  **Same constant → one-repo. Different, weaker, or no row → two-repo, and a paired `wms2-web-ui`
  change ships in this slice.** Expected outcome, already measured: **all slice-2 routes are one-repo**
  (`admin.vue:57,58,60,61,62`; `appMenuList.js:87,91,98,100`). A disagreement with that expectation is
  the finding, and it flips the slice to two-repo.
- **AC-11 (slice 3) — row 67 is reachable by a MOBILE-ONLY user.** Probed on dev with a user holding
  `MOBILE_UI_VIEW_REPLENISHMENT` and **no** `WEB_UI_*` function, provisioned per §5.1 row 12 if none
  exists. `wmstest` cannot substitute — it would 403 correctly for the wrong reason.
- **AC-12 (slice 3) — `adjustmentAlerts` produces no recurring 403 toast** for a non-holder idling 5
  minutes, with the paired UI guard deployed.
- **AC-13 (slice 5) — the `@PublicHandler` change is atomic and the fleet boots.** Marker + `GUARDED`
  + `REVIEWED_PUBLIC_HANDLERS` + row 91's annotation in **one commit**. A zero-function user gets
  **200** on rows 92 and 93, and `wms2.authz.public` is **non-zero** at
  `/actuator/metrics/wms2.authz.public`. Mutations: remove either `GUARDED` entry →
  `PublicHandlerContractArchTest` AC-7d reds; remove row 91's annotation → **the context fails to boot**.
- **AC-14 (slice 5) — row 95 is still UNGATED and still pinned. CLOSED.** §D.6 probe run 2026-09-04
  (panderson, `wineco`/`wsl`): body top level is a bare JWT-principal object, not `_embedded.user` —
  MVC won. Row 94 stays UNGATED, no marker needed (a harmless self-echo); nothing named on SBDEV-3169
  as a result of this probe.

### Cross-cutting

- **AC-15 — RESIDUAL DENIAL is measured and reported for every one of the 16 ANY-of rows.** For each,
  report **holders of the UNION** as a fraction of provisioned users, per tenant. **A union covering
  (say) 53 of 54 provisioned users denies almost nobody: that row is documentation, not a control, and
  the plan must say so rather than count it as closed.** This applies §0.2's own "cosmetic gate"
  standard to this plan's own design, and Axis D's 3-way `PutawayConfig` gate and rows 66/69/70's
  4-way are the rows most likely to fail it. A row that fails it is not a defect to fix — it is a
  claim to withdraw.
- **AC-16 — the review lane's report file NAMES every ⚠fn row and its caller evidence.** The **twelve**
  inferred-target rows — 19 (`CustomerOrderPosition`), 35-39 (`ItemData`), 61-62 (`StockRecord`), 71
  (`UnitloadRecord`), 88-89 (`Message`), 91 (`System`) — sit on controllers with **zero gated siblings**,
  so their target function is inferred
  from the catalogue rather than corroborated. An "LGTM" that does not name them individually is not a
  passing review for this ticket.

---

## 10. Risks & Mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| A `WEB_UI_*`-only gate on a mobile-called handler → 403 mid-shift | **High** | **16 ANY-of rows** identified with file:line callers in both UIs (§0.6); AC-4 + AC-11. Row 67 is the sharpest. |
| An overload left ungated because one annotation was assumed to cover two paths | **High** | §0.1; the pin is path-keyed so a missing overload has **no row** — hence AC-1's path-keyed re-derivation and AC-8. |
| Gating a route whose capability has a `permitAll` `/rest` twin (cosmetic gate) | **High** | §0.2 + §5.1 row 6. Already caught `triggerUpdateStock`. |
| Consuming the last UNGATED pin row → class-level widening becomes invisible | **High** | AC-7, justified by §0.4.1. Measured precedent: with only gated rows present, one class-level annotation left the whole suite green. |
| A target constant missing from one tenant DB → that tenant fails closed | **High** | §5.1 row 7, with the query and the six tenants named. SBDEV-3142's review found exactly this. |
| An ANY-of union so wide the gate denies nobody | **Med** | **AC-15** — measured and reported, not assumed. A failing row withdraws a claim rather than shipping a false one. |
| `SystemController` in `GUARDED` with an unannotated sibling → **no replica starts** | **Med** | AC-13's atomicity; §3.5 step 4. |
| `@PublicHandler` without `GUARDED` → inert marker reading as audited | **Med** | AC-7d + AC-13; the boot assertion also `LOG.error`s it. |
| Slice PRs conflict on the shared pin file | **Med** | Merge order 4→1→2→3→5; size constant edited last. |
| Baseline drift misread as a regression | **Med** | §5.1 row 13; one build per worktree. |
| `sendStockUpdate` / the 3 exports turn out to write | **Med** | §5.1 rows 6 & 9 audit them **before** annotating. |
| Over-claiming the security benefit | **Med** | §1.3: live dev/UAT exposure, latent PRD one. AC-15 extends the same discipline inside the design. |
| An inferred ⚠fn target is simply wrong | **Med** | AC-16 obliges the review lane to name each one. |
| Row 85's live typo "fixed" in passing | **Low** | §3.5 — a path change un-gates the route; the pin reports `ROUTE NOT DEPLOYED`. |
| **Slice 5 (security review, 2026-09-04): row 91's `WEB_UI_VIEW_SYSTEM_PROPERTY` gate has an UNGATED SDR twin** — `SyspropRepository` is `@RepositoryRestResource`-exported at `/v3/sysprop/**`, ruled nowhere in `SdrFunctionRules` (guard ships `OFF` regardless), so `GET /v3/sysprop/search/findByGroupname?groupName=Backend` returns the same data to any `wms_user`, **including live prod credentials** (`OMS_API_USER` on hydra prd, split by `HttpRestService` into user+password). Same shape for rows 88/89 (`MessageRepository`, order-payload bodies, not credentials — lower severity). | **High** (standing exposure; the slice's own gate is correctly scoped, this is what it does NOT close) | **Claim limit, stated explicitly: row 91's gate closes the `/v3` MVC path only, not the capability.** Not fixable inside slice 5 — `exported = false` on `SyspropRepository` would break the very Parameters & Configuration screen the gate protects (`cypress/e2e/wms/admin/admin.cy.js:87,176-180` uses the SDR search directly). The in-mechanism fix is an `SdrFunctionRules` entry ruling `Sysprop` (and `Message` for 88/89) under SBDEV-3169's guard programme — **filed as SBDEV-3222** (2026-09-04), materially more severe than Appendix A's springdoc proposal below. |
| **Slice 5 (security review, 2026-09-04): `TenantHealthController#checkHealth`'s 500 body can leak DB connection detail** — `TenantHealthService.java:87`'s failure branch echoes a raw `SQLException` message, which for pgjdbc can name the tenant DB host/port/role; now formally `@PublicHandler`, reachable by any authenticated zero-function `wms_user` permanently, not just today. Cross-tenant probing is NOT possible (`TenantFilter`/`MultiTenantJwtDecoder` 401 a foreign tenant name before the handler runs). Pre-existing, unchanged by this slice. | **Low** | Recorded here as the caveat's cheapest moment, per the reviewer: `@PublicHandler` makes this handler exempt from any future default-deny posture. Not a blocker; no fix scheduled. |

---

## Appendix A — proposed follow-up ticket (springdoc), NOT YET FILED

> **`/v3/api-docs*` is readable by any authenticated `wms_user`.** Five springdoc handlers
> (`OpenApiWebMvcResource#openapiJson|openapiYaml`, `MultipleOpenApiWebMvcResource#openapiJson|openapiYaml`,
> `SwaggerConfigResource#openapiJson`) serve `/v3/api-docs`, `/v3/api-docs.yaml`,
> `/v3/api-docs/{group}`, `/v3/api-docs.yaml/{group}` and `/v3/api-docs/swagger-config`.
> `SecurityConfiguration.java:150-154` permits `"/v3"` (exact) and `"/api-docs/**"` — **neither
> matches `/v3/api-docs`** — so they fall through to rule D at `:178`
> (`"/v3/**" → hasAnyAuthority(WMS_USER_ROLE)`). Unauthenticated callers are refused, but **any
> authenticated `wms_user` can read the complete API surface listing**, including every admin and
> internal endpoint, regardless of entitlement. Not fixable by annotation: these are third-party
> classes and `FunctionGuardInterceptor` resolves `getDeclaringClass()` to the springdoc type. The
> remedy is a `SecurityConfiguration` matcher (`"/v3/api-docs/**"` → `hasAuthority(WMS_ADMIN_ROLE)`,
> or `permitAll` if open docs are the intent). Carved out of SBDEV-3158 because it is a different
> mechanism with a different test shape and its own regression risk (Swagger UI is used in dev).
> **Severity Low** — information disclosure to authenticated users only. **Tier T1/T2**: one file, one
> matcher, reversible. ⚠ **No Spring-context test in this repo can observe `authorizeHttpRequests`**
> (the bean is `@ConditionalOnProperty(rest.security.enabled)` and the integration profile sets it
> false), so the assertion must follow `Sbdev3017OmsCarveOutSourceContractTest`'s source-contract
> pattern.

## Appendix B — recorded observations, NOT proposals

⚠ *Draft v1 listed these as "proposals" alongside Appendix A, which put three against a cap of one.
They are demoted to **recorded observations**: neither carries a concrete remedy, and the single
proposal slot for this visit is spent on Appendix A.*

- **`AdminController` route explosion.** It is both a mapped `@RestController @RequestMapping("/v3")`
  with 9 handlers **and** the base class of 43 controllers, so Spring registers ~387 duplicate
  user-administration alias URLs. All `@PreAuthorize(IS_SB_ADMIN)`-gated, so **not a live exposure** —
  but it inflates every surface count in the repo and is the root of this ticket's "landmine #1".
- **Four `/v3` handlers with no caller in either UI** (rows 10, 26, 44, 45) — deletion candidates once
  OMS/cron callers are ruled out.

---

## 11. Completeness checklist

- [x] **Every in-scope route enumerated** — §0.5, all 95, path-keyed, with target function and caller
      evidence
- [x] Every exclusion justified with evidence — §0.8
- [x] Every §D item ruled on; the one genuinely un-derivable item marked **needs a probe**
- [x] The §E GET-MUTATE handlers dispositioned individually — **one rejected with evidence**
- [x] The 6 POST-as-query reads reclaimed from SBDEV-3142 §7.1
- [x] `availableStagingLanes` resolved; §0.4's tripwire claim re-verified and upheld — §0.4.1
- [x] ANY-of rows counted precisely (**16**) — §0.6
- [x] The one-repo/two-repo question decided by measurement — §0.7
- [x] Ticket-structure decision argued against the ticket policy
- [x] 16 acceptance criteria, mutation-checkable, per-route; per-slice totals stated
- [x] Blast radius measured on real user populations, **users not roles**
- [x] Claim limits stated (no PRD claim, no SDR claim, no `/rest` claim, and AC-15 applies the same
      discipline to this plan's own ANY-of design)
- [x] Horizontal-scalability checklist complete
- [x] v2-only confirmed
- [x] **CLOSED 2026-09-04, live probe:** D.6 (`/v3/user` shape) — bare JWT-principal object, MVC won; row 94 stays UNGATED
- [ ] **OPEN — needs provisioning:** a mobile-only dev account for AC-11 (§5.1 row 12)
- [ ] **OPEN — needs approval:** Appendix A ticket filing

---

## 12. Implementation Status

### Slice 4 — Inbound (7 routes) — MERGED to develop (`7a1cbee2`, 2026-09-03)

- **Branch:** `feature/SBDEV-3158-slice4-inbound-gating`, off `origin/develop` @ `3941fb26`
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3158`
- **Commits:** `257cd104` (implementation — 7 `@RequiresFunction` annotations + pin extension 145→152), `ef2b37a2` (review fixes — comment/javadoc only, no logic change)
- **PR:** https://github.com/SiteBossInc/wms2-api/pull/289 → `develop`
- **Tests:** `Sbdev3017TrancheGateContextTest` 3/3 passing; full suite `Tests run: 6226, Failures: 0, Errors: 0, Skipped: 67` (identical to pre-implementation baseline, whose 1 failure was these 7 routes)
- **Verify script:** N/A (T3 opt-in, this plan has none)
- **Conformance:** verifier PASS, 6/6 criteria VERIFIED
- **Review:** code-reviewer 0 High/Medium, 2 Low fixed; security-reviewer 0 findings, 1 Medium flagged as explicitly out of scope (SDR read surface stays open — SBDEV-3169's scope, posted as a PR comment, not fixed here)
- **Docs:** none required (verify-docs audit clean — role matrix already documents these functions at the function level, no new controller/constant)
- **Deliberately-skipped coverage:** live three-way dev probe (AC-2/AC-11 style) not run — no confirmed access to mint a named non-holder's token in this session; flagged for Nam before merge

### Slice 1 — Outbound (27 routes) — MERGED to develop (`63e927fe`, 2026-09-03, after resolving a merge conflict in the shared pin file against slice 4's merge; combined pin size 175 = 152 (slice 4) + 23 net-new keys (slice 1))

- **Branch:** `feature/SBDEV-3158-slice1-outbound-gating`, off `origin/develop` @ `f440b534`
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3158-slice1`
- **Commits:** `e82e7742` (implementation — 27 routes), `60878fb1` (review: widen row 19, typo fix), `eb5fd285` (review H1 — widen 8 more rows, systemic finding, see below), `90f0869d` (review S1 — narrow `nameExists`)
- **PR:** https://github.com/SiteBossInc/wms2-api/pull/292 → `develop`
- **Tests:** `Sbdev3017TrancheGateContextTest` 5/5 passing; full suite `Tests run: 6242, Failures: 0, Errors: 0, Skipped: 67` (matches this branch's own pre-implementation baseline `6242/1/67`, whose 1 failure named all 27 routes as UNGATED — different numbers from slice 4's branch, which is expected since `develop` moved forward between the two)
- **Verify script:** N/A
- **Conformance:** verifier PASS, 8/8 criteria VERIFIED
- **Review:** code-reviewer found 1 High (H1) and fixed it; security-reviewer found 0 High/Medium plus 2 Low design questions (S1, S2). See "Cross-slice finding" below — this is the significant outcome of this slice's review.
- **Docs:** none required (verify-docs clean, same conclusion as slice 4)
- **Deliberately-skipped coverage:** live three-way dev probe not run, same reason as slice 4

**⚠ Cross-slice finding (H1, code review) — applies to slices 2/3/5, read before starting any of them.**
**23 of 58 `WEB_UI_VIEW_*` constants gate zero screens in `wms2-web-ui`** (derived by subtracting the function names in `util/appMenuList.js`, `pages/admin.vue`, `pages/index.vue`, `components/masterData/material/skuData/skuData.vue`, and `util/putawayScopeFunctions.js` from `WmsConstants.FunctionEnum`). Any planned target function from that set is a D.4 miss ("sibling function vs. caller's screen disagree → ANY-of both") by construction — 8 of slice 1's 27 rows needed widening for exactly this reason, including one row whose original single function had **no caller on any matching screen at all**.

Partial list of unmapped constants already implicated in slices 2/3's planned targets: `VIEW_GOODS_RECEIPT`, `VIEW_GOODS_RECEIPT_POSITION`, `VIEW_PICKING_POSITION`, `VIEW_PICKING_UNIT_LOAD`, `VIEW_RACK`, `VIEW_RACK_ROW`, `VIEW_STOCK_COUNT`, `VIEW_CYCLECOUNT_POSITION`, `VIEW_USER`, `VIEW_ROLE`, `VIEW_GROUP`, `VIEW_FUNCTION`, `VIEW_SEQUENCE_NUMBER`, `VIEW_DB_QUERIES`, `VIEW_REPLENISHMENT_MONITOR`, `VIEW_ORDER_DETAIL_MONITOR`, `VIEW_BILL_OF_LADING_POSITION`, `VIEW_INBOUND_BOL_ITEM_LINES`, `VIEW_TYPE_CAPACITY_CONSTRAINT`.

**Nam's direction (2026-09-03): sweep each remaining slice's planned target functions against `util/appMenuList.js` (and the four other function-name-bearing UI files) *before* writing that slice's TDD-gate pin rows** — catch this at gate time, not via a second review pass per slice.

**§0.6 is now stale.** It states "16 ANY-of rows" plan-wide; slice 1 alone went from 3 to 9 after review. The true total is at least 23 and needs re-deriving before slice 2's AC-4/AC-15/§5.1-row-12b (which cite the old count) are trusted. Not fixed in this pass — flagged as a PR comment on #292 and here so it isn't lost.

### Slice 2 — Master data (26 routes) — MERGED to develop (`dd0f79c7`, 2026-09-03)

- **Branch:** `feature/SBDEV-3158-slice2-masterdata-gating`, off `origin/develop` @ `63e927fe` (post slices 1+4)
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3158-slice2`
- **Commits:** `5112e71b` (implementation — 26 routes), `68ba722c` (conformance fix, incomplete on first pass), `e2a747c5` (comment corrections), `b9e96d9f` (full per-route caller-trace review — 6 more routes widened, 4 High + 2 Medium)
- **PR:** https://github.com/SiteBossInc/wms2-api/pull/294 → `develop`
- **Tests:** `Sbdev3017TrancheGateContextTest` 5/5 passing; full suite `Tests run: 6254, Failures: 0, Errors: 0, Skipped: 67` (matches this branch's baseline `6254/1/67` pre-implementation)
- **Verify script:** N/A
- **Conformance:** verifier PASS, 8/8 criteria VERIFIED — the one genuine gap it found (`itemdataDetailsById`) needed a SECOND fix round; the first fix (in the same commit chain) was itself still incomplete
- **Review:** code-reviewer found 4 High + 2 Medium (full caller-trace, all fixed, mutation-verified); security-reviewer independently confirmed every fix and found the same class of gap a second time before code-review's fuller pass landed — verdict moved from "not clean, do not merge" to clean only after the full trace
- **Docs:** none required
- **Decisions with Nam:** `allClients`'s resulting 11-way ANY-of shipped as-is (mechanically correct, not vacuous, narrowing means redesigning the endpoint — out of scope); a **pre-existing** (not introduced here) `ReceivingController`/CS-REP screen-vs-API gate mismatch proposed as its own ticket rather than silently widened, since the affected code (slice 4) is already merged — filed as **SBDEV-3221**

**⚠ Second cross-slice lesson (slice 2 review) — a per-FUNCTION sweep is not a per-ROUTE check.**
Slice 1's H1 taught "does this target function map to *some* screen." Slice 2's review found that is necessary but not sufficient: `itemdataDetailsById/{id}` was gated on `WEB_UI_VIEW_ITEM_DATA`, which genuinely maps to the SKU Data screen — but that route's *actual callers* were on 4 other screens entirely (Inbound Notices, Cycle Count, Inventory Report, SKU Location Report), none of which is SKU Data. **The only reliable check is a full per-route caller trace**: grep `wms2-web-ui` for each route's actual caller(s), find the caller's page, read that page's `appMenuList.js` function, and confirm it's in the gate's ANY-of set — for every route, not spot-checks. This cost two extra review rounds in slice 2 (the conformance fix itself needed re-fixing) because it wasn't done exhaustively from the start. **Slices 3 and 5 should budget for a full caller trace as a first-class step, not an afterthought triggered by a review finding.**

### Slice 3 — Inventory (22 routes) — MERGED to develop (wms2-api `2383bf34`, wms2-web-ui `290fae70`, 2026-09-03)

- **Branch:** `feature/SBDEV-3158-slice3-inventory-gating`, off `origin/develop` @ `56fc1035` (post slices 1/2/4)
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3158-slice3` (companion: `.claude/worktrees/wms2-web-ui/SBDEV-3158-slice3`)
- **Commits:** `d4d71367` (implementation — 22 routes, pin 175→197), `c5410868` (verifier fix F1 — stale javadoc), `d3c440b0` (code+security review fixes — narrowed 2 over-widened ANY-ofs, corrected 6 stale comments), `a91b965f` (L-4 citation-scope fix). Companion repo: `88a1e1c` (D.5 skip guard), `a89ddab` (M-4 — added the guard's test).
- **PRs:** https://github.com/SiteBossInc/wms2-api/pull/298 → `develop` (merged); https://github.com/SiteBossInc/wms2-web-ui/pull/113 → `develop` (merged, ahead of the API PR per the deploy-order note). Both branches deleted post-merge.
- **Merge conflict on push (same shape as slice 1/4):** this branch's actual fork point predated slice 2's merge (`dd0f79c7`) despite the base note above saying "post slices 1/2/4" — that note was wrong. `git merge origin/develop` conflicted on the shared pin file (`hasSize(197)` vs. the then-current `hasSize(201)`); resolved by combining both slices' row sections and correcting the ledger to `223 = 201 + 22`. Zero path collisions (entirely different controllers). Full suite re-run post-merge: `6266 run, 0 failures, 0 errors, 67 skipped`. Merge commit `d5066d7b`.
- **Tests:** `Sbdev3017TrancheGateContextTest` 5/5, `FunctionGuardArchTest` 26/26, `ActionGuardAnnotationContractUnitTest` 4/4, `FunctionGuardInterceptorUnitTest` 13/13, `StockUnitBulkTransferGateUnitTest` 3/3; full suite `Tests run: 6263, Failures: 0, Errors: 0, Skipped: 67` (matches this branch's own pre-implementation baseline). `wms2-web-ui`: 4/4 new Jest tests, mutation-checked.
- **Conformance:** verifier PASS, all 5 criteria VERIFIED (report: `slice3-verifier-report.md`)
- **Review:** code-reviewer (full per-route caller trace, all 22 independently re-derived) found 4 Medium + 5 Low; security-reviewer found 2 Medium + 2 Low. The two lanes' Mediums overlapped on the same defect (childrenUnitloads/unitloadDetailsByLabelId over-widened) — both independently re-verified by me before fixing. All Medium/blocking findings fixed; Lows addressed where cheap (comment fixes, a rename), deferred where they're follow-up items (see below).
- **Docs:** this plan doc reconciled (§0.5 rows 63/65/66/68/70, §3.3 narrative, frontmatter status) — code-review's L-5.
- **Systemic finding (both review lanes):** `UnitLoadController#reprintLabel`'s deployed 4-way ANY-of is NOT a safe verbatim-reuse precedent for its siblings — `unitloadDetailsById` genuinely needs all 4 (Handling Units + Club Run + Transfer Picking callers), but `childrenUnitloads` (Handling Units only) and `unitloadDetailsByLabelId` (Club Run/Transfer Picking only, zero Handling Units caller) do not. Both narrowed to their actual 2-way ANY-of. **Lesson for slice 5:** re-derive each route's callers individually even when a sibling route on the same controller already carries a wider, deployed gate — "the sibling needs it" does not mean "this route needs it too."
- **Deferred / not fixed this slice (recorded so they aren't lost):**
  - Code-review L-2: cross-repo merge-order constraint (API + UI must deploy together or UI-first) — put in the PR description, not code.
  - Code-review L-3: the alert-bell badge (`layouts/default.vue`) renders unconditionally but its only data source (row 61) is now gated — 9 of 54 `wms2-wineco-dev` users get a permanently-empty bell rather than an absent one. Not a defect in this diff; worth a follow-up ticket note.
  - Code-review's informational finding: `CycleCountController`, `StockRecordController`, `UnitloadRecordController` are now also 0-of-N ungated but are NOT in `FunctionGuardArchTest.SHARED_CONTROLLERS`, so nothing asserts class-level absence on them (the same P5 shape AC-7 covers for `ClubLine`/`Transfers`). Near-zero real risk (folding these gates to class-level would be behaviour-neutral today), but slice 5 should note it rather than reproduce it on a 4th/5th/6th class without comment.
  - Code-review's F3 (verifier lane) / informational: the `FunctionGuardInterceptorUnitTest` exemplar moved to `DashboardController#orderMonitorViewOverview` this slice. That class's only remaining 5 ungated handlers are exactly slice 5's rows 83-87 — **after slice 5, none of the four `SHARED_CONTROLLERS` will have an ungated handler left**, so this exemplar cannot simply move again. Slice 5 needs a different construction (most likely a test-fixture controller) — budget for this rather than discovering it mid-implementation.
- **Blocked, not verifiable statically (verifier lane):**
  - AC-2 (three-way dev probe) and AC-12 (no recurring 403 toast over 5 idle minutes) both need the build deployed to dev.
  - **AC-11 is currently blocked and is the one worth not skipping** — it requires a user holding `MOBILE_UI_VIEW_REPLENISHMENT` and no `WEB_UI_*` function. Zero such users exist on `wms2-wineco-dev` today (all 41 mobile-function holders also hold a web function). §5.1 row 12 provisioning must happen before this, the plan's own self-declared highest-risk row, can be discharged.

### Slice 5 — Dashboard + admin/system (13 routes) — MERGED to develop (PR #302, `a6c22ac7`, 2026-09-04)

- **Branch:** `feature/SBDEV-3158-slice5-dashboard-admin-gating`, off `origin/develop` @ `2383bf34` (post slices 1/2/3/4)
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3158-slice5`
- **Commits:** `1e3faa08` (implementation — 13 routes, atomic `@PublicHandler` 4-file change, 4 retargeted tests); `65ace7c3` (code review fixes — H1 stale-invariant javadoc, M2 stale-checkout citation, M3 five stale count claims, M4 two ArchUnit rails widened from `GOLDEN_MAP` to the full `GUARDED` set, L1–L7 hygiene); a security-review fix commit follows (F3 tripwire-citation correction)
- **PR:** [#302](https://github.com/SiteBossInc/wms2-api/pull/302) — merged to `develop` 2026-09-04, merge commit `a6c22ac7`
- **Full per-route caller trace:** `SBDEV-3158-evidence/slice5-caller-trace.md` (both UIs, all 11 in-scope rows); one correction found and fixed during code review (a stale `wms2-mobile-ui` checkout, 10 commits behind `origin/develop`, produced one wrong line citation — see the corrections box above §0.5's slice-5 table)
- **Tests:** `Sbdev3017TrancheGateContextTest` 5/5 passing (pin 223→227: 4 net-new keys, 5 `DashboardController` rows flipped from UNGATED with no size change); full suite `Tests run: 6266, Failures: 0, Errors: 0, Skipped: 67` (matches slice 3's baseline exactly), unchanged after both fix commits
- **Verify script:** N/A (T3 opt-out per §4.1 — every assertion lives in JUnit)
- **Mutation checks:** 7 run directly (delete/narrow each new annotation, the ANY-of narrowing on row 86, and the two `GUARDED` entries) — every one red naming the exact route or throwing the exact boot violation, then cleanly reverted. The independent verifier lane additionally re-ran 2 of the 7 itself.
- **Conformance:** verifier PASS — all 13 routes conform to the caller-trace-corrected route table, rows 94/95 confirmed untouched, the atomic 4-file change confirmed genuinely atomic by live mutation revert.
- **Review:** code-reviewer found 1 High + 3 Medium + 7 Low (10 fixed, 1 — a commit-subject nit — deliberately deferred, would require amending a correct prior commit); security-reviewer found 2 Medium/standing-High (F1/F2, SDR twins bypass the new gates on live prod data including credentials — see the new §10 risk rows) + 2 Low (F3, fixed; F4, recorded not fixed). **AC-15's residual-denial measurement is CLOSED, not deferred** — security review measured it directly from each tenant DB (bypassing the Keycloak PW blocker entirely) and found every ANY-of row a real, non-vacuous control on every tenant (row 87's widening in particular adds ZERO users beyond the existing union on all six tenants — population no-op, reasoning confirmed sound). AC-14 (D.6, `/v3/user`'s response shape) is also now CLOSED — see below.
- **Docs:** `wms2-function-to-docs-map.md` §9 updated (GUARDED 14→16, `@PublicHandler` row extended) — the only doc directly falsified by this change, per `verify-docs`.
- **D.6 live probe — run 2026-09-04** (panderson, `kc2.dev.sbo.li` realm `wineco`, `X-Tenant-ID: wineco`/`facility_code: wsl`): `GET /v3/user` → HTTP 200, bare JWT-principal object (`tokenValue`, `claims`, `subject`, …), not `_embedded.user`. MVC won. Row 94 stays UNGATED, no marker needed — a harmless self-echo, nothing named on SBDEV-3169.
- **Findings filed as SBDEV-3222 (security review, 2026-09-04):** SDR twins for `SyspropRepository` (row 91, includes a live prod credential) and `MessageRepository` (rows 88/89, order payloads) bypass the new `/v3` gates entirely — see the two new §10 risk rows. Materially more severe than Appendix A's springdoc proposal. Re-confirmed still open against `develop` tip `a6c22ac7` before filing.
