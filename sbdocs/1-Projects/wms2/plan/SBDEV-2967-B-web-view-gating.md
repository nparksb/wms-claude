---
title: "WMSv2 Web UI: no view authorization — the menu is hardcoded to super-admin and every user sees all 30 items"
ticket: "SBDEV-2967"
ticket_url: "https://app.clickup.com/t/868krr3rq"
type: "bugfix"
priority: "high"
status: "✅ MERGED + DEPLOYED to WineCo dev 2026-08-22. wms2-api [#183](https://github.com/SiteBossInc/wms2-api/pull/183) merged as `d70204c`, then wms2-web-ui [#72](https://github.com/SiteBossInc/wms2-web-ui/pull/72) merged as `d07ed87` — API FIRST, order honoured. Both GitHub Actions succeeded and fired the dev Portainer redeploy webhooks. **V2.2.19 applied for real for the first time**: `flyway_schema_history` on `dev_wh01_om1` shows version 2.2.19 `success=true` at 12:19:45 UTC (previously it had only ever run inside a deliberately aborted transaction). Data effect measured: role→function grants 305 → 330 (+25), functions 81 → 82 (+1 = `WEB_UI_VIEW_PARCEL_PICKING`, the §7.2/P8 decision). P6 two-step deploy satisfied: `tenant_db_configuration` shows only ONE active datasource on dev (wineco/wsl → `dev_wh01_om1`), the tenant that got the grants; hydra and shipitez rows are all `active=false`, so no reachable tenant is ungranted. Live-bundle deploy check on https://wsl-wineco.wms.dev.sbo.li: the app bundle carries `require-function`, `not-authorized`, `WEB_UI_VIEW_USER_MANAGEMENT` and `WEB_UI_VIEW_PARCEL_PICKING`, and the hardcoded `super-admin` menu key is GONE from every entry bundle. ⚠️ NOT confirmed from the live bundle: the `WEB_UI_LOG_IN` entry gate — it lives in `pages/index.vue:162`, a lazily-loaded route chunk not reachable from index.html; confirm in a browser. 🔴 P9 STILL OPEN for UAT/PRD — this deploy is DEV ONLY. `60aef02` is on `origin/develop` and therefore provably in the dev image, which is what satisfies P9 for dev. It is NOT on `origin/main` (head `cf430ff`, v2.0.128); it IS on `origin/release` (`41cbe77`, v2.0.130). Promoting it to prd is a 43-commit release train, NOT a prerequisite for this dev landing."

project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-16
updated: 2026-08-22
db_verified: true
related:
  - SBDEV-2967-web-ui-function-gating-enforcement.md
  - SBDEV-2967-A-axios-403-denial-not-logout.md
  - SBDEV-2967-C-web-action-gating.md
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
  - ../../../3-Resources/architecture/wms2-keycloak-role-matrix.md
tags:
  - plan
  - security
  - authorization
---

# SBDEV-2967-B — Web UI view gating: menu, routes, entry, admin tabs

**Ticket:** [SBDEV-2967](https://app.clickup.com/t/868krr3rq) · **slice B of 3** (see the [index](SBDEV-2967-web-ui-function-gating-enforcement.md))
**Repos:** `v2/wms2-web-ui` (primary) · `v2/wms2-api` (seed + one Flyway migration)
**Tier:** T3 · **Blocked on:** P2-VIEW, §7.2 · **Independent of:** slices A and C

> **Scope boundary.** This slice covers **view** gating only — which screens a user can reach. Destructive
> **action** gating is [slice C](SBDEV-2967-C-web-action-gating.md); they were split because they have
> opposite failure modes and a deploy-order constraint between them that one PR cannot honour. A hidden
> menu item is loud and revertible; a 403 on a visible button is silent.

---

## 0. Affected sites

### 0.A The web menu — 9 top-level entries, 30 leaf destinations, **0 gated**

`util/appMenuList.js` defines five persona menus. `layouts/default.vue` reads exactly one of them:

```js
links() {
  return menuList["super-admin"];   // no argument, no role lookup, no filter
}
```

| # | Site | Finding |
|---|---|---|
| 0.1 | `layouts/default.vue:303-305` | Menu hardcoded to the `super-admin` key |
| 0.2 | `util/appMenuList.js:2, 197, 355, 441, 545` | 5 persona menus; **4 are dead code** |
| 0.3 | `store/index.js` → `pages/index.vue:114` | `getUserRoles` calls `/user/getAllRoles/{username}`, **commits nothing**, and its only caller ignores the return |
| 0.4 | no `middleware/` directory | No route guards — every page is deep-linkable |
| 0.5 | `pages/admin.vue:51-58` | All 6 admin tabs hardcoded, **including User Management** |
| 0.6 | repo-wide grep for `WEB_UI_VIEW` / `WEB_UI_ACTION` | **zero** hits outside Cypress fixtures |

> **Re-verified on `origin/develop` `99e2359`, 2026-08-21.** All six still hold. `links()` is at `:303-305`
> (was `:284-285` pre-split — line numbers drifted, the defect did not). A repo-wide `git grep WEB_UI_`
> returns **zero files**.

### 0.A.1 The authoritative menu → function table (all 30 leaves)

Every row's **Endpoints** column is what the leaf's store module actually calls. **Derivation honesty:**
where the endpoints identify the subject, the function is endpoint-derived; where they do not, the
assignment is **semantics-derived** and marked ⚠ — those are the rows a reviewer should challenge.

> **Corrected at architect review.** An earlier draft marked all 9 report rows ⚠ on the grounds that "they
> all call the same generic `/report`". **That was wrong.** `/report` is a *class prefix*
> (`ReportController:30` → `@RequestMapping("/v3/report")`) with a distinct method path per report. Each
> report store calls exactly one. So **8 of those 9 rows are properly endpoint-grounded** and the ⚠ is
> removed. Only **2 rows remain semantics-derived: #1 Dashboard and #5 Pick Pack.**

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
| 26 | Rpt → Parcel Picking | `reports/parcelPicking.js` | **`/report/exportParcelPicking`**, **`/report/parcelPickingView`**, `/report/reprintLabels`, `/printer` | ⚠ **undecided — §7.2** | no matching constant exists |
| 27 | Rpt → Outbound Parcel | `reports/outboundParcel.js` | **`/report/exportOutboundParcel`**, **`/report/parcelMonitorView`**, `/billOfLading` | `WEB_UI_VIEW_PARCEL_MONITOR` | endpoint — it is this row, not 26, that calls `parcelMonitorView` |
| 28 | Rpt → Stock Unit Record | `reports/stockUnit.js` | **`/report/exportStockUnitRecord`**, `/stockrecord` | `WEB_UI_VIEW_STOCK_UNIT_RECORD` | endpoint |
| 29 | Rpt → Container Record | `reports/container.js` | **`/report/exportContainerRecord`**, `/unitloadRecord` | `WEB_UI_VIEW_UNIT_LOAD_RECORD` | endpoint |
| 30 | Admin | `admin/*` | see §2.4 | ANY-of the 6 tab functions | endpoint per tab |

**Note on #11 — Handling Units is one menu leaf backed by two stores.** `store/handlingUnits/stockUnits.js`
reads `/stockUnit`; `store/handlingUnits/container.js` reads `/unitLoad`. A single function would hide the
page from someone entitled to half of it, so it takes an **ANY-of**. The page's two tabs should additionally
gate individually, or a `CONTAINER`-only user sees an empty Stock Units tab.

**2 of 30 rows remain semantics-derived** — #1 Dashboard and #5 Pick Pack. Dashboard calls `/dashboard`,
which like `/report` has per-monitor method paths (`orderMonitorViewSummary`, `replenishMonitorViewSummary`),
so row 1 is probably groundable the same way — **not yet checked**, and the honest state is ⚠. Pick Pack
shares `/customerOrder*` with three other leaves, so no endpoint can separate it. Those two plus row 26
(§7.2) are the review surface.

**Also noted:** `store/reports/data.js` calls `/report/exportReceiving` — a **tenth** report store. It backs
`pages/reports/data-report.vue`, which is **commented out of the menu**, so it is correctly absent from this
table. If that entry is ever re-enabled it needs a row.

### 0.B Backend sites

| # | Site | Role in this slice |
|---|---|---|
| 0.7 | `service/AccessService.java` | `doesUserHaveAccess`; `doesUserHaveAnyAccess`/`checkAnyAccess` landed with 2968 — **verified present on `develop` `5506117` at `:82`, `:107`, `:134`** |
| 0.8 | `security/FunctionGuardInterceptor` (2968) | ⚠ **This slice does NOT extend it** — see the §1.3 boxed warning. Its golden map stays at 2968's 11 controllers, none of which the web menu calls. |
| 0.9 | `controller/rest/UtilRestController.java:237-416` | persona seed — extended by §2.6 |
| 0.10 | `src/main/resources/db/migration/` | **Flyway head on `develop` is V2.2.18, confirmed 2026-08-21.** Take the next free above it — **re-sweep all remote branches at PR time; the answer is perishable** |
| 0.11 | `WmsConstants.FunctionEnum` | No new constants needed — see §2.6 |

---

## 1. Problem statement

### 1.1 Symptom

Every authenticated user renders the full **super-admin** navigation — all 30 items, the Admin screen
included — regardless of which `UserRole`/`UserGroup` they hold. There is no menu filter, no route guard,
and no per-tab gate. The web UI fetches the user's function list on login and throws it away.

The sharp edge is **Admin → User Management**: the screen that edits `UserRole`/`UserGroup`/`UserFunction`
rows renders for any `wms_user`.

### 1.2 DB verification — WineCo dev (`db_verified: true`)

Queried live 2026-08-16 on `wms2-wineco-dev`, the primary test client. **52 live users** (excluding
`Z-`-prefixed archived rows):

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

1. **WineCo already built a differentiated web role and the UI ignores it.** `CS-REP` (4 users) holds 26
   `WEB_UI_VIEW_*` — orders, BOL, picking, monitors, receiving reads, records — and deliberately **no**
   master data, **no** admin, **no** actions. It is a well-formed customer-service role that has never had
   any effect.
2. **6 live users have zero web functions and no `WEB_UI_LOG_IN`** — mobile-only operators. Today they can
   open the web UI and reach Admin. `WEB_UI_LOG_IN` **already exists and already separates them correctly**;
   nothing reads it. That is the cheapest, largest slice of exposure to close.
3. 🔴 **14 of the 29 mapped menu items have a function that NO non-`super-admin` role holds** *(measured
   2026-08-16; **now 13** — SBDEV-2968 granted `TRANSFER_ORDER`, see §2.5)* — all 9 Master
   Data items, Cycle Count, Transfer, Transfer Picking, Inventory Report, and Admin. **13 of those needed grants at
   the time of measurement — now 12**, since SBDEV-2968 D4 + V2.2.18 landed `TRANSFER_ORDER`; Admin is the exception and correctly stays `super-admin`-only. **This is the defining
   difference from SBDEV-2968.** Mobile's grants were real because the tile filter was live; the web UI's
   grants were never populated because nothing ever read them. Filtering on the current data would leave
   Master Data visible only to the 39 super-admins.

### 1.2.1 ✅ P3 partially discharged — the auto-named test roles grant nothing exclusive

Measured on `dev_wh01_om1` 2026-08-21, after Nam confirmed that **every role other than `super-admin`
holding a privileged function was created for testing**.

WineCo dev has **140 roles: 11 human-named and 129 auto-named `ROLE#####`.** The naming pattern is *not* a
safe audit filter — **17 of the auto-named roles do have live users** (105 user-links). But they are all
**single-function** roles, and the question that actually matters is whether any user depends on one.

**Answer: almost none.** Exactly three functions are held by any user *exclusively* through an auto-named
role, and **none of them is gated by this plan or by slice C**:

| Function held only via an auto-named role | Users | Gated by this work? |
|---|---|---|
| `MOBILE_UI_NEVER_TIME_OUT` | ~45 | no — session behaviour, not a menu or action gate |
| `SPECIAL_DEVELOPER` | `sbuser1`, `sbuser15` | no |
| **`WEB_UI_VIEW_ORDER_DETAIL_MONITOR`** | `danielvalentim`, `ursulajimenez` | no page — but see §7.3 |

What this discharges:

- **Fix C is safe.** Every one of the 46 users holding `WEB_UI_LOG_IN` also holds it through a named
  persona — `ROLE000009`/`ROLE000011` grant it to nobody exclusively. The entry gate will not lock anyone out.
- **`WEB_UI_VIEW_STOCK_UNIT` (`ROLE000072`) and `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` (`ROLE000073`)** reach
  3 users each, but all of them hold those functions via a persona too — redundant, not load-bearing.
- **All 16 `WEB_UI_ACTION_*` auto-roles (`ROLE000043–50`, `ROLE000092–99`) have ZERO users**, so slice C's
  R1b blast radius is confirmed: effectively only `super-admin` holds action functions.

⚠ **The method still matters even though the answer came out clean.** The regression predictor must compute
a **per-user union across all roles**, never a per-persona table — the per-role view in §1.2 above happens to
agree here only because the test roles are redundant. On another tenant they may not be, and **more will
appear**: these are added ad hoc by whoever is testing.

🔴 **New for §7.3:** `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` is listed there as one of the 7 constants "with no
page". It is also the one function in the table above with **exclusive live holders** — retiring it would
strip two named users. Treat it like `STOCK_COUNT` / `DB_QUERIES` on `CS-REP`: retiring is not free.

### 1.2.2 🔴 P3 run on a SECOND tenant — and it reverses the WineCo-only conclusion

Measured 2026-08-21 on **Hydra UAT** (`wh01_hydra_v2`, 19 live users), after WineCo dev alone suggested the
blast radius was zero. **It is not.** This is the "an empty result set is not an all-clear" warning made
concrete: one tenant would have shipped a false all-clear.

| | WineCo dev | Hydra UAT |
|---|---|---|
| Non-super-admin operators using gated actions (180d) | **0** | **3** |
| Heaviest such operator | — | **`pesposito` — 1,153 rows** (damaged, adjust, manage-inventory, removal, split) |

🔴 **And the affected users hold NO ROLES AT ALL.** `pesposito` and `omallozzi2` have zero roles;
`j.arcate` has no `mywms_user` row. They can act today *only because nothing is enforced*.

| Hydra UAT provisioning gap | Count |
|---|---|
| Live users with **no role** | **4 of 19** |
| `stockrecord` operators with **no `mywms_user` row** | **5** |

**No grant table fixes this** — you cannot grant a function to a user with no role, or to one who does not
exist. See §4-P3a. ✅ **Filed as [SBDEV-3062](https://app.clickup.com/t/868kv11ed)** 2026-08-21.

### 1.2.3 Per-tenant provisioning worklist — all 6 v2 tenant DBs audited 2026-08-21

⚠️ **This corrects §1.2.2's framing.** Bounded properly, the gap is **6 humans**, not the alarming raw
counts. Full detail on [SBDEV-3062](https://app.clickup.com/t/868kv11ed).

| Tenant DB | Live | **Role-less HUMANS** | Role-less system | Active ops w/o user row (90d) |
|---|---|---|---|---|
| `dev_wh01_om1` (wineco dev) | 52 | `sbuser17`, 2×`cyprobe…` (Cypress litter) | `anonymous`, `oms_integration` | `anonymousUser` |
| `wh01_hydra_v2` (**uat**) | 19 | **`pesposito`, `omallozzi2`** | ” | none |
| `wh01_hydra_v2` (**prod**) | 9 | none | ” | `anonymousUser` |
| `wh02_shipitez_v2` | 11 | none | ” | none |
| `wh01_shipitez_v2` | 36 | `tuser03` | ” | `anonymousUser` |
| `wh01_om1_v2` (wineco uat) | 47 | `kimberlyconyers`, `lukamiranda`, `sbuser17` | ” | `anonymousUser` |

⚠️ **Two MCPs both report DB name `wh01_hydra_v2`** on different servers (9 vs 19 users). Never dedupe
tenants by database name.

⚠️ **The unbounded operator query is misleading — do not use it.** On wineco uat it returns ~70 names;
bounded to 90 days it collapses to `anonymousUser` alone. The rest are historical `stockrecord` strings,
largely **case variants** of real users (`AdamPetersen`/`adampetersen`, `j.arcate`/`jarcate`). Always bound
by recency, or this row reads as a crisis.

🔴 **The item that is not a human, and is the one that can break an integration.** `anonymous` and
`oms_integration` are role-less on **all six** tenants — they have `mywms_user` rows with zero roles, so
`checkAnyAccess` yields `MISSING_FUNCTION` → **403** on any gated endpoint. `anonymous` is the busiest actor
in the system (**1,928,752 rows** on wineco uat, last seen 2026-08-17); its recent activity is
`CREATE_PICK_POSITION`, `PACKAGING`, `REPLENISHMENT`, `RETURN` and **`CANCELLED_ORDER_FROM_WEBSERVICE`**.

Those read as scheduled jobs and integration paths, which do not traverse `WebMvcConfigurer` interceptors —
so the gates probably never see them. **That is an inference, not a measurement**, and the webservice one
undercuts it. **Confirm before slice C ships:** a 403 on that path breaks OMS integration silently, and
nothing in the test suite would notice.

### 1.2.4 ✅ P3a DISCHARGED — production is clean; this is no longer a blocker

Completed 2026-08-21 before any database was modified. **The §1.2.2/§1.2.3 framing was too alarming and is
corrected here.**

**Production has exactly ONE active v2 tenant** — per the prd landlord (`wms2_landlord`): `hydra` / `nywh`
→ `wh01_hydra_v2`. Audited directly: **all 7 humans hold roles.** Only `anonymous` and `oms_integration`
are role-less, and both are resolved as no-action (§2.7). **There is no production provisioning gap.**

The 6 role-less humans are all on dev/UAT and all **dormant or never-used** — `omallozzi2` last acted in
**2022**, `pesposito` in **2025-06**, `sbuser17` and `tuser03` never. Granting them warehouse permissions
would *create* access for accounts nobody uses. Recommended action is **archive** (`Z-` prefix), not grant;
`lukamiranda` (wineco uat, active 2026-06) is the only one warranting a real decision.

⚠️ **An earlier claim of mine was misleading and is withdrawn:** "`pesposito` — 1,153 gated-action rows,
heaviest user on the tenant" was a *lifetime* total for a user who stopped acting 14 months ago. On Hydra
UAT only two humans acted at all in 2026, both super-admin. **Lifetime counts overstate live risk — always
bound operator analysis by recency.**

**Consequence: P3a is discharged. This slice and slice C are NOT blocked by
[SBDEV-3062](https://app.clickup.com/t/868kv11ed)**, which reduces to hygiene.

🔴 **But the finding that replaces it is more consequential.** **All 7 production humans hold
`super-admin`** — four hold all six personas *plus* super-admin. So B and C will be a **no-op on
production**: nobody loses anything because everyone already has everything. The rollout is safe and
delivers **no security benefit on prod** until production stops granting blanket super-admin. That is a
prerequisite for this work having value, and it belongs in the same conversation as the grant tables.

> **Counting note, stated precisely because three different figures are easy to derive here.** The menu has
> **30 leaf destinations**. **29** have an unambiguous existing constant and were measured in the query
> above. The 30th — **Reports → Parcel Picking** — has no matching constant and is an open decision (§7.2).
> Of the 29, **14** are orphaned, **13** of which take grants under §2.6.

> ⚠️ **The §1.2 figures are 5 days old and were measured on one tenant.** P3 re-runs the audit on **every**
> tenant before the image lands. Treat this table as the design rationale, not as the pre-deploy gate.

### 1.3 🔴 Web VIEW functions are enforced CLIENT-SIDE ONLY in this slice

> This slice **annotates no web controller for view functions.** An earlier draft implied otherwise — it
> called the interceptor "the enforcement point this plan extends" and diagrammed it doing web view gates.
> Neither was true: 2968's golden map is 11 controllers, **all mobile plus `OrderCancellationController`,
> and none of the ~21 controllers the web menu calls.**
>
> So after this ships, a user denied the SKU Data menu item still gets data from `curl /v3/itemdata`.
> **That is the same defect class SBDEV-2968 exists to close, on the web side.**
>
> **And extending the golden map would only fix half of it.** Roughly 14 of the ~32 API roots behind the web
> menu are served *purely* by Spring Data REST repository exports with no controller to annotate —
> `/v3/locationType` (`LocationTypeRepository:11`), `/v3/unitloadType` (`UnitloadTypeRepository:11`),
> `/v3/itemunit` (`ItemunitRepository:10`), plus `/v3/itemdata`, `/v3/boxtype`, `/v3/stockunit`,
> `/v3/locationArea`, `/v3/locationRack`, `/v3/cyclecount`, `/v3/replenishorder`,
> `/v3/goodsreceiptposition` and others. `RepositoryRestHandlerMapping` does not honour
> `WebMvcConfigurer.addInterceptors` (2968 §3.1-A9), so the interceptor **structurally cannot reach them**
> — and they are concentrated on Master Data, exactly the menu group with the largest grant problem.
>
> **Server-side web view gating therefore needs a third mechanism.** ✅ **Filed as
> [SBDEV-3017](https://app.clickup.com/t/868kufdy1)** — "Authorization coverage beyond the mobile
> controllers". It is a named follow-on with an owner, not a silent gap. It is also why Fix A cannot be
> shrunk: for about half the menu, the client-side filter is currently the only control that can exist.

**Out of scope for this slice:** the shared endpoints (**17+, not 5** — SBDEV-2968 §0.B as corrected by
§14.12), the `AdminController` alias surface (2968 §0.C / SBDEV-2870), the audit-comment defect
([SBDEV-2979](https://app.clickup.com/t/868kt336b)), the 7 `WEB_UI_VIEW_*` constants with no page (§7.3),
all **action** gating (slice C), and the 403-logout defect (slice A).

---

## 2. Root cause & fix design

**RC-1 — the filter was written and never wired.** `util/appMenuList.js` contains five complete persona
menus. Someone built the data model for a filtered menu; `links()` was never given the argument. The four
unused keys are the fossil.

**RC-2 — the roles are fetched and discarded.** `store/index.js` performs the network call, logs the length,
and returns a value `pages/index.vue:114` awaits and ignores. The action commits no mutation, so no
component can observe it.

**RC-3 — the grant data was never populated, because nothing read it.** Unlike mobile, where the
client-side filter forced grants to be real, the web functions are write-only metadata. Hence the 13
orphaned menu items in §1.2. **Enforcement and data must land together or the feature is a regression.**

**RC-4 — nothing in the harness can see the absence.** No web test asserts menu composition. A UI with no
gate and a UI with a correct gate are indistinguishable to CI today.

### 2.1 Fix A — the menu filter (`wms2-web-ui`)

**A1. `util/appMenuList.js`** — attach a `fn` to every leaf, and **delete the four dead persona menus**. One
list, each entry declaring the function that reveals it. The `super-admin` key disappears as a key; it
becomes just "the full list".

**A2. `store/index.js`** — `getUserRoles` gains a mutation. Add `functions: []`, `functionsLoaded`,
`functionsError`; add `ensureFunctionsLoaded()` memoising a single in-flight promise (same shape as 2968's
`ensureRolesLoaded`).

**A3. `layouts/default.vue:303-305`** — `links()` filters the single list against `state.functions`. A group
(`subLinks`/`linkGroup`) renders only if **at least one child survives** — otherwise an operator sees an
empty "Master Data" accordion.

### 2.2 Fix B — route guard (`middleware/require-function.js`, new)

No `middleware/` directory exists. Register in `nuxt.config.js`.

> 🔴 **REWRITTEN 2026-08-21 after the design review. Three changes, each load-bearing.**

**(a) THREE EXHAUSTIVE LISTS, not a menu-derived map with a fall-through.** Prefix-derived inheritance
does not work here and a 13-row supplement rots on the next page anyone adds, because the default for
an unmapped route is *pass*. Measured: `pages/` holds 59 `.vue` files → 30 menu leaves, 6 terminal
pages, 23 non-menu deep-linkable pages, of which only 10 nest under a menu path. For three subsystems
the URLs do not nest at all: `/internalOps/cycleCount/...` vs leaf `/internalOps/cycle-count`
(different casing **and** different word), and `/receiving/{openNotice,closedNotice}/...` vs leaf
`/receiving/inbound-notices`. Prefix matching is also actively unsafe — `/outbound/transfer` prefixes
`/outbound/transfer22`. So `util/appMenuList.js` exports:

1. `MENU` — the 30 leaves, each with `fn` (a constant name, or an array for the two ANY-of leaves).
2. `EXTRA_ROUTES` — every non-menu page written out explicitly, never prefix-derived.
3. `UNGATED_ROUTES` — the terminals: `/`, `/index`, `/not-authorized`, `/unhealthy-tenant`,
   `/unknown-tenant`, `/oauth2callback`, **`/not-affiliated`**.

…plus a test that walks `pages/` **on disk**, converts each file to its Nuxt route pattern, and asserts
every route appears in exactly one of the three. That converts "a new page silently defaults to open"
into a red test, and it is the single highest-value assertion in this slice.

**Six pages are DELETED rather than gated** (Nam, 2026-08-21) — nothing links to any of them:
`/outbound/transfer22`, `/masterData/strategies/customer-orders` and `/reports/data-report` are **live,
working duplicates of gated pages** (transfer22's component imports are byte-identical to
`/outbound/transfer`; data-report dispatches the *live* `reports/receiving` store, **not** the unused
`store/reports/data.js` this plan's §0.A.1 claims). Reachable ungated, they are a client-side bypass of
the only gate slice B ships. `/masterData/locationData/storage-location_org` and
`/masterData/strategies/sku-data-nam` are broken against dead store namespaces; `/receiving/lookup` is
a 16-line stub whose menu entry is commented out.

**(b) FAIL CLOSED — but on a THREE-WAY split, not a binary. 🔴 NARROWED 2026-08-21 after the
re-review.** The first pass said simply "fail closed", which was too broad. Mobile's guard is not
"fail open" either — it is three-way, and it is the **middle** branch it deliberately leaves open,
carrying this comment: *"DECLINE TO DECIDE rather than deny — denying here **is what locked fully
entitled operators out of every cold-start deep link**."* That is a recorded regression on the same
codebase shape from one week earlier, not a style preference. So:

| Guard state | Behaviour | Why |
|---|---|---|
| `functionsError` | → `/unhealthy-tenant?reason=functions` | an outage is not a denial |
| loaded, required constant absent | → `/not-authorized?page=&fn=` | a real denial |
| **barrier settled, principal unresolvable** | **must never reach the guard as an empty entitlement** | see below |

**The third row is the whole subtlety.** `ensureFunctionsLoaded` must set `functionsError = true` when
`$kc.tokenParsed?.preferred_username` is absent *after* awaiting the barrier — and must **never** issue
`getAllRoles/undefined`. It then inherits the recoverable page rather than a terminal denial, and the
guard never has to choose between denying an unauthenticated user and waving one through. Committing
`[]` here instead is exactly what produced mobile's lockout.

**Plus one bounded retry (~1s) inside `ensureFunctionsLoaded` before committing `functionsError`.** It
removes the entire class of single-blip denials for the cost of one `setTimeout`, and it belongs in the
store rather than as a grace path in the guard — a grace path would reintroduce mobile's open branch.
Without the retry, this guard's most likely real-world trigger is not "a user lacking a permission" but
"Keycloak was 300 ms slower than usual", and the answer to that must not be a permanent grey card.

⚠️ **`/unhealthy-tenant` is NOT currently a "retryable neutral page" — the first pass asserted that and
it is false.** It is a 22-line static grey card that nothing routes to today, and mobile's identical
card tells outage victims *"the warehouse is not configured"*. Fail-closed aims **designed** traffic at
it. It must gain a real message and a Retry before this ships; likewise `/not-authorized`, which still
renders a fixed string and reads no `$route.query` — so the new contract that the denial names one
human-askable function is currently pinned against a page that never displays it.

**(b-original) FAIL CLOSED to `/unhealthy-tenant?reason=functions`, not open.** SBDEV-2968's mobile guard fails
open and its own comment says that is defensible *"only because the server gates the workflows' write
paths"*. §1.3 establishes web has **no** server-side counterpart in this slice. The justifying
condition is absent, so the deviation is not inherited. `/unhealthy-tenant` rather than
`/not-authorized` is deliberate: it is a retryable neutral page that does not tell an entitled operator
to call their administrator, and the guard already routes there for `functionsError`.

**(c) `ensureFunctionsLoaded` MUST `await this.$kc.ready`.** `plugins/keycloak.client.js:288` calls
`initKeycloak()` **fire-and-forget** from a synchronous plugin, so Nuxt never awaits it and middleware
runs while `$kc.tokenParsed` is undefined on **every** page load. Without the await the principal is
never resolvable, `functionsLoaded` stays false, and the guard passes every route forever — **while
every middleware test stays green**, because they inject state and never touch the plugin. The barrier
already exists (`plugins/keycloak.client.js:240`, settled on every terminal path including the error
path at `:127`). (b) and (c) ship together; (b) without (c) denies everyone.

### 2.3 Fix C — the `WEB_UI_LOG_IN` entry gate

A user without `WEB_UI_LOG_IN` is redirected to `/not-authorized` with a message naming the web UI
specifically. **No new constant, no data migration** — the function exists and is already correctly held
(`CS-REP`, `inventory-manager`, `outbound-manager`, `receiving`, `super-admin`) and correctly absent from the
three mobile-only personas. This single check covers the 6 live WineCo users in §1.2.

> 🔴 **AND THE LANDING MUST CHANGE (added 2026-08-21).** `pages/index.vue:120` pushes `/dashboard`
> unconditionally, but row 1 gates `/dashboard` on `WEB_UI_VIEW_ORDER_MONITOR` — which, measured on
> `dev_wh01_om1`, **`inventory-manager` and `receiving` do NOT hold**. So the exact persona §2.5 hands
> all of Master Data to logs in, passes the entry gate, and is immediately bounced to
> `/not-authorized`; their nine new screens are reachable only by hand-typing a URL. Latent today only
> because every real user on that tenant is super-admin — it goes live on the deploy that delivers this
> ticket's value. **Land on the first surviving menu leaf**, falling back to `/not-authorized` only when
> the filtered menu is empty. On `functionsError`, push `/unhealthy-tenant?reason=functions` to match
> the guard, or index.vue and the guard fight and the user takes a two-hop bounce.

**This is the cheapest, highest-yield item in the whole SBDEV-2967 family** — one check, no grant
dependency, closes the largest single bucket of exposure. Consider landing it ahead of A/B/D if P2 drags.

### 2.4 Fix D — the **7** Admin tabs (`pages/admin.vue:55-68`)

> 🔴 **CORRECTED 2026-08-21 (design review).** This section tabled **six** tabs and cited `:51-58`.
> There are **seven**, at `:55-68`. `Label Printing` was inserted at index 4 by SBDEV-2861 after this
> plan was drafted. Row 30's Admin ANY-of is therefore an ANY-of **seven**, not six.

| Tab | Function |
|---|---|
| System Management | `WEB_UI_VIEW_IMPORT_DATA` |
| Parameters & Configuration | `WEB_UI_VIEW_SYSTEM_PROPERTY` |
| Shippers | `WEB_UI_VIEW_CLIENT` |
| User Management | `WEB_UI_VIEW_USER_MANAGEMENT` — **super user only** (Nam, 2026-08-21). Two redundant test-created roles also hold it today; see the §2.5 note. |
| **Label Printing** | **`WEB_UI_VIEW_PRINTER`** — decided 2026-08-21 (Nam). No `WEB_UI_VIEW_LABEL_PRINTING` constant exists; the nearest subject match is Printer Setup's, and reusing it avoids a *second* new constant in a slice that already adds `WEB_UI_VIEW_PARCEL_PICKING`. ⚠️ Accepted cost: Label Printing and Printer Setup share one gate, so they are visible and hidden together. **Do NOT reach for `WEB_UI_ACTION_PRINT_TOTE_LABELS`** — it is an ACTION constant, it is effectively super-admin-only today, and slice C defers it to tranche C2. |
| Printer Setup | `WEB_UI_VIEW_PRINTER` |
| Service Log | `WEB_UI_VIEW_MESSAGES` |

The Admin **menu entry** itself is an ANY-of the seven (row 30). Hide the entry when no tab survives.

> 🔴 **THE TAB PANES ARE POSITIONAL — filtering the header list alone renders the WRONG PANE.**
> `pages/admin.vue:6` does `v-for="(tabName, index) in tabs"` while `:13-35` hardcodes seven
> `<v-tab-item>` children in **fixed order**, and both bind the same numeric `v-model`. Filter the
> headers only and an operator holding just Printer Setup + Service Log clicks header 0 and gets
> **System Management's pane**. The in-file comment at `:60-64` already warns that every tab gates its
> data loading on a hardcoded `parentTab` index. `<v-tab-item>` must `v-for` over the SAME filtered
> list as the headers. Compounding it, `plugins/persistedState.client.js:90` restores a persisted
> `admin.parentTab` ordinal that may now address a hidden tab — clamp it.

> **Note the pairing with [SBDEV-3013 — archived](../../../4-Archieves/wms2/plan/SBDEV-3013-role-function-write-surface-gating.md).** Fix D hides the
> User Management *tab*; 3013 gates the *endpoints behind it*. Neither is sufficient alone. ✅ **Both of
> 3013's doors are now MERGED** (door ② `808819d`, door ① `ae5ec98`), so it did land first as expected.

### 2.5 Fix F-VIEW — the grant seed

**29 of the 30** menu items map to an existing `FunctionEnum` constant; the 30th needs a decision (§7.2). For
those 29 no new constants are required — what is missing is **grants**.

> 🔴 **THE ORPHAN COUNT IS 17, NOT 12 — corrected 2026-08-21 by the lane-2 design review.**
> §1.2's per-role table counted **`CS-REP`** as coverage for `CLUB_LINE`, `CONTAINER`,
> `STOCK_UNIT_RECORD` and `UNIT_LOAD_RECORD`. But `CS-REP` is a **WineCo-only, tenant-authored role
> that F3 explicitly refuses to modify**, and it does not exist on hydra (uat or prd) or on either
> shipitez tenant; `STOCK_UNIT` is super-admin-only *everywhere, including WineCo*. Measured on
> **production** (no CS-REP, no test roles — the cleanest read of the seeded persona layout), 17 menu
> functions have no non-super-admin holder at all: the 12 below, `TRANSFER_ORDER` (covered by V2.2.18),
> and the **five** added to the table. Without them five menu rows — Club, Club Run, Handling Units,
> Stock Unit Record, Container Record — go dark for the six live wineco wsl UAT operators, and
> **Club Run is a core WineCo workflow.** That is risk B-R1 firing on items B-R1 does not enumerate.
> ⚠️ **Never count a tenant-authored role as fleet coverage.**

**Best-fit assignment for the orphaned items.** ⚠ **This asserts who owns master data, which is a
business decision — it needs Brent's sign-off per tenant before the migration is written** (P2):

| Function(s) | Proposed persona | Rationale |
|---|---|---|
| `STORAGE_LOCATION`, `STORAGE_LOCATION_TYPE`, `FIXED_ASSIGNMENT`, `AREA`, `SECTION`, `UNIT_LOAD_TYPE` | `inventory-manager` | warehouse structure is inventory ops |
| `ITEM_DATA`, `ITEM_UNIT`, `CASE_TYPE` | `inventory-manager` | SKU master |
| `CYCLECOUNT`, `CYCLECOUNT_POSITION` | `inventory-manager` | 🔴 **rationale corrected 2026-08-21.** The old reason — *"already owns the mobile cycle-count tile"* — is **equally true of `inventory-worker`** (`initDB` grants `MOBILE_UI_VIEW_CYCLE_COUNT` to both), so it invites a reviewer to widen the grant to a persona that holds **no `WEB_UI_LOG_IN`**, where it would be silently inert. The load-bearing reason is narrower: **`inventory-manager` is the only inventory persona with web access at all.** |
| ~~`TRANSFER_ORDER`~~ | ~~`outbound-manager`~~ | ✅ **ALREADY DONE by SBDEV-2968 D4 — do not re-seed.** Verified on `develop`: `UtilRestController` calls `grantFunction(WEB_UI_VIEW_TRANSFER_ORDER, role_inventory_manager, role_outbound_manager, role_outbound_worker, role_super_admin)` for fresh tenants, and `V2.2.18__seed_mobile_workflow_functions.sql` grants it to `outbound-manager` + `inventory-manager` on existing ones. Rows 7 and 10 are grant-satisfied **in code**. ✅ **AND now in the live data too** — V2.2.18 was applied to `dev_wh01_om1` at 2026-08-21 18:37:01 after the dev redeploy; `WEB_UI_VIEW_TRANSFER_ORDER` now reads `inventory-manager, outbound-manager, super-admin`. Orphan count is **12**. |
| `INVENTORY_RECORD` | `inventory-manager` | inventory reporting |
| **`CLUB_LINE`** | **`outbound-manager`** | 🔴 **ADDED 2026-08-21 (design review).** Backs menu rows 6 (Outbound → Club) **and 9 (Processes → Club Run)**. It is an outbound order screen and `outbound-manager` already holds `BILL_OF_LADING`, `PICKING_ORDER`, `ORDER_MONITOR` and `ORDER_BATCH`. |
| **`STOCK_UNIT`**, **`CONTAINER`** | **`inventory-manager`** | 🔴 **ADDED 2026-08-21.** The ANY-of behind row 11 (Handling Units). `inventory-manager` already holds `STOCK_UNIT_LOCK_OVERVIEW`, whose subject is the same stock unit. |
| **`STOCK_UNIT_RECORD`**, **`UNIT_LOAD_RECORD`** | **`inventory-manager`** | 🔴 **ADDED 2026-08-21.** Rows 28 and 29 — audit reads over those same two entities, identical reasoning to `INVENTORY_RECORD` above. |
| **`PARCEL_PICKING`** (new constant, §7.2) | **`super-admin`** + `inventory-manager` + `outbound-manager`, **plus a back-compat clause** | 🔴 **ADDED 2026-08-21.** `super-admin` is **mandatory** — `initDB` enumerates its 81 grants one line at a time, nothing reaches a new constant for free, and without this row **every super-admin on all 6 tenants loses menu row 26** (102 users) and acceptance criterion B-5 is unsatisfiable. The `inventory-manager`/`outbound-manager` pair mirrors row 27 `PARCEL_MONITOR` exactly — the two parcel reports are two views of one flow. **Back-compat clause — KEPT (Nam approved the widening incl. this clause), but it is PROPHYLACTIC, not
load-bearing, and the plan must say so or the next reader will infer it rescued someone.** Measured
2026-08-21: it rescues **zero** live users today, and on the two tenants where it does anything at all
five of its six targets are auto-roles reaching nobody. It is also the one statement in the migration
that derives its audience from a **holder query**, which §2.5 elsewhere explicitly forbids — kept only
because it costs one statement and future-proofs a tenant nobody has provisioned yet. It must be
sequenced **after** the step-1 `mywms_function` INSERT. Concretely: also grant it to every role that
already holds `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` (`SELECT DISTINCT`, V2.2.18 step-2 idiom), which preserves the two deliberately-provisioned wsl operators without naming them and makes retiring `ORDER_DETAIL_MONITOR` later a no-op. |
| `USER_MANAGEMENT` | **do not grant to anyone** | **Super user only** — Nam, 2026-08-21. Correct as intent; the data carries two redundant test-created holders, see the note below. |

**F1** — extend `UtilRestController.initDB` (fresh tenants). ✅ **2968 already added a `grantFunction(constant, role...)` helper there — use it**, rather than adding more of the 300-character `addFunctionToRole(...findByName(...).orElseThrow(...).getId(), role.getId())` lines that make up the surrounding ~140.

**F2** — Flyway migration for provisioned tenants: `INSERT … WHERE NOT EXISTS` per (role, function), keyed
by role **name**, skipping silently where a role is absent. ⚠️ **The conclusion `NOT EXISTS`, never
`ON CONFLICT` is RIGHT, but not for the commonly-stated reason.** 🔴 **AND PRODUCTION CARRIES NEITHER — added 2026-08-21.**
Measured: the base dump (`V2.2.00__base_v2_schema.sql:1512-1515`) has no unique constraint; two live
tenants carry a composite PK **under drifting names**; and **`wh01_hydra_v2` (PRD) has no PK and no
unique index on `mywms_role_mywms_function` at all**. So there are *three* shapes in the fleet, not
two. Anyone who reads the old wording ("both live tenants carry a composite PK") and "simplifies" to
`ON CONFLICT (rolelist_id, functionlist_id)` on that basis **raises 42P10 on production**. Verify row
`H13b` now forbids `ON CONFLICT` outright. Original measurement, still true for the other tenants:
the base dump has no unique constraint, **but two live tenants carry a composite PK under drifting
names** — `…_pkey` on WineCo dev, `…_pk` on Hydra UAT. So
`ON CONFLICT ON CONSTRAINT <name>` breaks on the name drift, and column-inference
`ON CONFLICT (rolelist_id, functionlist_id)` raises **42P10** on base-dump tenants: each form is wrong on a
*different* subset, and `NOT EXISTS` is the only universally safe guard. **Do not "fix" this to an
ON CONFLICT on the grounds that a constraint exists.**

> ⚠️ **Measured 2026-08-21 on two live tenants — and the live data is NOT the specification.**
>
> **Intended state (Nam, 2026-08-21): the super user is the only one who gets User Management.**
>
> Observed on **two distinct databases** (`dev_wh01_om1`, 96 users / 140 roles; `wh01_hydra_v2`,
> 19 users / 14 roles), `WEB_UI_VIEW_USER_MANAGEMENT` is held by **three** roles on each:
>
> | Role | Functions on the role | Reaches | Also in `super-admin`? |
> |---|---|---|---|
> | `super-admin` | many | 38 users (dev) · 15 (uat) | — |
> | `ROLE000008` | **exactly 1** — this function | `admin`, via `GROUP000008` | ✅ **yes** |
> | `ROLE000010` | **exactly 1** — this function | `sbuser1` (dev); no user on uat | ✅ **yes** |
>
> **The two extra grants are redundant.** `admin` and `sbuser1` are *already* in the `super-admin`
> group holding the `super-admin` role on both tenants, so those single-function roles confer
> nothing they do not already have — **removing them costs no access whatsoever**, and the
> intended super-user-only state is reachable with zero capability loss.
>
> 🔴 **Do not derive the gate's audience from this query, now or later.** Testers add roles for
> test purposes, and **until this ticket lands any `wms_user` can grant themselves this very
> function** — which is the defect being fixed. A holder query is therefore a snapshot of
> mutable drift, not a specification. Gate on the function; do not enumerate holders.
>
> **Optional follow-on, NOT silently in scope:** a data cleanup dropping the two redundant
> `(ROLE00000{8,10}, WEB_UI_VIEW_USER_MANAGEMENT)` rows so the holder set matches the intent.
> Zero access impact per the table above. Needs an explicit go-ahead — it is data, not code, and
> it is not required for the gate to be correct.

**F3** — `CS-REP` and other tenant-authored roles are **not** modified. They are the tenant's own
configuration.

⚠️ **`los_sysprop.description` is `varchar(255)`** — if any seed row here writes a description, an over-long
value raises 22001 rather than truncating, and Flyway rolls back the whole file, blocking that tenant's
chain. No test lane catches it.

⚠️ **Tenant object-ownership drift blocks the whole Flyway chain, silently** — tenant migration failures
never abort boot. If a tenant's objects are owned by a different role, this migration freezes that tenant's
chain and nobody is paged. Verify per tenant after applying.

### 2.5b Fix H — do NOT persist the authz state 🔴 **added 2026-08-21; found independently by two review lanes**

`plugins/persistedState.client.js:61-67` persists the **whole root state** minus three named keys
(`warehouseTimezone`, `selectedWarehouse`, `warehouses`) plus an `admin.configuration` carve-out — it is
**allow-by-default at root**. Fix A2 adds `functions`, `functionsLoaded`, `functionsError` to root
state, so all three ride in the `vuex-web` blob. The same file documents the residual at `:47-50`:
*"`vuex-web` is never cleared on logout — only `kcToken` is"*, and names the live vector at `:14-16` as
**same-tenant, cross-USER staleness on a shared workstation** — a warehouse floor PC.

**Failure scenario.** Super-admin logs out on a shared PC. A mobile-only operator logs in.
`vuex-persistedstate` rehydrates *before any plugin body runs* (documented at `:75-77`), so
`functionsLoaded === true` and `functions === [57 super-admin functions]`. An `ensureFunctionsLoaded`
written like mobile's — which short-circuits on `rolesLoaded && !rolesError` — **never fetches**. The
second user gets the first user's full menu and full route access, and the entry gate admits them.
**Fixes A, B, C and D are all defeated simultaneously, from localStorage.** Same class as SBDEV-2726;
SBDEV-2968 deliberately stopped persisting authz identity on mobile for exactly this reason.

**Fix.** Add all three keys to the reducer's exclusion list at `:63`, and add a self-heal
`store.commit('setFunctions', [])` alongside the existing heals at `:82-83` so a pre-fix blob does not
survive the upgrade. Spec: `functionsAreNotPersisted`.

---

> ⚠️ **TRAP FOR THE NEXT PERSON WRITING A GRANT FIX (recorded 2026-08-21, G-10).**
> `UserRepository.getAllRoles` — the query every gate ultimately reads — resolves
> **user → group → role → function ONLY**. The `mywms_user_mywms_role` table is **not in that query**
> and is **empty on all six tenants**. So a direct user→role link grants **nothing**: it is a silent
> dead end, not a second path. Nothing is broken today; the hazard is someone "fixing" a missing grant
> by inserting there and observing no effect, or an audit query that joins it and reports coverage
> that does not exist. Grant through a **group**.

---

### 2.6 Fix G — audit

Reuse SBDEV-2968's `db/audit-access-invariants.sql` + `GET /v3/adminAction/accessAudit`. **Do not build a
second one.** Add one web-specific result set: *per user, which of the 30 menu items they will see after the
change vs. all 30 today* — the regression predictor for P3.

---

## 3. Architecture

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
│        │                      │
│ pages/admin.vue               │
│   tabs.filter(fn ∈ functions) │   ← Fix D
└───────────────────────────────┘
        ⚠ no server-side counterpart in this slice — see §1.3 / SBDEV-3017
```

---

## 4. Prerequisites

Rollout is **hard-on at deploy, no feature flag** (user decision, consistent with SBDEV-2968).

| # | Prerequisite | Blocking? |
|---|---|---|
| **P1** | ~~SBDEV-2968 merged.~~ ✅ **DONE 2026-08-21** — merge `5506117`, PR #178. `AccessService.checkAnyAccess`/`doesUserHaveAnyAccess` and the audit surface are on `develop` and verified. | Done |
| **P2** | ✅ **DISCHARGED 2026-08-21 (Nam), AND RE-CONFIRMED for the WIDENED table.** The original sign-off was given on the 12-row draft; the table now has 18 rows. Nam approved the widening **with each new persona named explicitly** — `CLUB_LINE`→`outbound-manager`, `STOCK_UNIT`/`CONTAINER`/`STOCK_UNIT_RECORD`/`UNIT_LOAD_RECORD`→`inventory-manager`, `PARCEL_PICKING`→`super-admin`+`inventory-manager`+`outbound-manager` plus the back-compat clause. An independent review lane separately judged `CLUB_LINE`→`outbound-manager` **correct and better grounded than this plan states**. Do not re-raise. See §7.1. Ship the §2.5 VIEW grant table as drafted; grants are adjustable afterwards via Admin → User Management with no deploy (that path works because SBDEV-3005 is deployed, `60aef02`). Original framing kept for history: *Brent signs off the §2.5 VIEW grant table — it asserts that `inventory-manager` owns master data and `outbound-manager` owns transfers. Plausible, not authoritative.* | Done |
| **P3a** | ⚠️ **NAMED REMEDIATION, one user, one tenant — not a blocker (scoped 2026-08-21 by the lane-2 review + Nam).** The earlier discharge said "the role-less users are dormant dev/UAT accounts". That framing was wrong in *both* directions because it did not name a database. Measured per copy: on **`dev_wh01_om1` (WineCo dev)** `lukamiranda` holds CS-REP + outbound-worker + **super-admin** and has **0 rows/180d** (last act 2025-04-23) — fully provisioned, genuinely dormant. On **`wh01_om1_v2` (WineCo wsl UAT — a confirmed deploy target)** the same username exists as id 864391850 with **no group at all** and **34,770 `stockrecord` rows in the last 180 days** (last act 2026-06-04). The provisioning and the traffic are in different copies. **PRD is clean** (all 7 humans hold `super-admin`, re-confirmed). ⚠️ Same trap as [[wineco-dev-db-is-dev-wh01-om1-not-the-migration-env-target]]: several WineCo copies answer plausibly and the one carrying the traffic is not the one carrying the correct config — always name the database. **Action before the wsl UAT image lands:** add `lukamiranda` to the group set its three identical peers already hold on that tenant — `inventory-manager, inventory-worker, outbound-forklift, outbound-manager, outbound-worker, receiving` (`markchilcote`, `marthamina`, `estellavasquez` are byte-identical on it). Owner: [SBDEV-3062](https://app.clickup.com/t/868kv11ed). | **Named step** |
| ~~P3a (superseded)~~ | ~~✅ DISCHARGED 2026-08-21 — see §1.2.4. Production has no provisioning gap; the role-less users are dormant dev/UAT accounts.** Original framing kept for history: **PROVISIONING WAS THOUGHT TO BE A PRECONDITION.** Every live operator must hold a role and every `stockrecord` operator must have a `mywms_user` row **before** either slice deploys. Hydra UAT has 4 role-less users and 5 operators with no user row; SBDEV-2968 is **already denying** the latter on mobile. Tracked as **[SBDEV-3062](https://app.clickup.com/t/868kv11ed)**.~~ | ~~Done~~ |
| **P3** | Run the audit on **every tenant** + the web regression predictor (§2.6). Any live, Keycloak-mapped user who would lose a menu item they currently use must have a named remediation **before** the image lands. ⚠ An empty result set is not self-evidently an all-clear — it can mean "the at-risk role has no exclusive holder in this environment." | **YES** |
| **P4** | Flyway grant migration applied to every tenant **before or with** the UI change. **Grants first, filter second** — the reverse hides working screens. | **YES** |
| **P5** | Re-sweep `V2.2.*` across **all remote branches** at PR time. Head is **V2.2.18** as of 2026-08-21. ⚠️ This risk already materialised on 2968, which reserved V2.2.17 on 08-17 and lost it to SBDEV-2994 on 08-19. | **YES** |
| **P6** | **Two-step deploy: ① grant migration → ② `wms2-web-ui`.** (The third step — the api action gates — belongs to slice C and is sequenced in that document.) | **YES** |
| **P7** | Confirm the route map covers every deep-linkable page, including `_id.vue` detail routes. | **YES** |
| **P8** | ✅ **DECIDED 2026-08-21 (Nam) — see §7.2: add `WEB_UI_VIEW_PARCEL_PICKING`.** Needs a new `FunctionEnum` constant + `UtilRestController` seed + a grant-migration row. ⚠ Row 26 also calls `/report/reprintLabels`, so keep slice C tranche C2 (`PRINT_TOTE_LABELS`) deferred until this constant lands. | Done |
| **P9** | 🔴 **DEPLOY GATE, added 2026-08-21.** This slice may **not** be deployed to any environment whose `wms2-api` lacks **`60aef02`** (SBDEV-3005). 🔴 **AND `merge-base` ALONE IS NOT SUFFICIENT — corrected 2026-08-21.** `origin/main` is not the
deployed prd artifact. Proof, measured: prd's Flyway head is **2.2.16 with no row at all for V2.2.11**,
yet `origin/main` carries V2.2.11, sets `app.flyway.migrate-on-startup=true` **and**
`out-of-order=true`, and ships `StartupFlywayMigrator` — an api at `origin/main` would have applied it.
So the running image predates main by an unknown amount, and a green `merge-base` after the promotion
merge still would not prove 3005 is in the running process. **Three checks, in order:**
1. **Artifact identity** — read the deployed image tag from the orchestrator (GitLab CI is tag-driven,
   `v*` = production), then `git rev-list -1 <tag>` and `git merge-base --is-ancestor 60aef02 <sha>`.
   ⚠️ `/actuator/info` is exposed but the pom has **no `build-info` goal**, so it carries no commit
   today; adding `spring-boot-maven-plugin:build-info` is a one-line change that makes this a `curl`
   forever after — **do it**.
2. **A safe behavioural probe** — the only proof that does not rest on trusting a tag, and it is
   **non-destructive** if scoped correctly. The known check is destructive only because it is run
   against a *populated* role. Use a throwaway instead: create scratch role `zz-3005-probe` (no users,
   no functions) → Admin → User Management → tick exactly one function → Save →
   `SELECT rolelist_id, functionlist_id FROM mywms_role_mywms_function WHERE rolelist_id = <probe id>;`
   3005 present ⇒ one correct row. 3005 absent ⇒ 500 + FK violation `23503`, **and nothing of value was
   deleted because the role held nothing.** Drop the scratch role. (Prd role ids are 579–596 and
   function ids 500–579, so a swapped write can only ever resolve for the single overlapping id 579;
   prd has 0 orphan rows in that table today, i.e. the button has never been pressed there.)
3. Keep `merge-base` as a **necessary** condition — never by reading a plan sentence. Measured: it is on `develop` and `release` but **NOT on `origin/main`**, which prd tracks. On a pre-3005 api, Admin → User Management's Save **deletes every grant on the role and then 500s** with a "network issue, please retry" toast. Post-gating, doing that to `super-admin` strips `WEB_UI_LOG_IN` from all 7 production humans and locks the tenant out of the web UI — `AccessService` has **no `sb_admin` bypass**, so even SiteBoss staff are denied and recovery needs direct SQL. This is the mitigation §7.1 leaned on, so on prd it is an amplifier, not a mitigation. Costs nothing: P4 already forces the api promotion. | **YES** |
| **P10** | 🔴 **The grant migration must also INSERT the `mywms_function` row for `WEB_UI_VIEW_PARCEL_PICKING`**, not only the join rows. `AccessService.updateFunctionList()` reflects over `FunctionEnum` but **has no reachable caller** — `UtilRestController` is `@Service`, so its `@RequestMapping` methods do not route and `initDB` never runs on a provisioned tenant. Ship without the INSERT and menu row 26 vanishes for everyone, super-admin included. | **YES** |
| **P11** | ⚠️ **Flyway heads are not where this plan implies.** Measured 2026-08-21: prd is at **2.2.16** and missing 2.2.11 entirely; four tenants are at 2.2.17; only wineco dev has V2.2.18. §2.5's "TRANSFER_ORDER … now in the live data too" is a **wineco-dev-only fact stated generally** — on wsl UAT the Transfer and Transfer Picking rows are still dark until 2.2.18 lands there. | **YES** |
| **P12** | ⚠️ **P6 step ① is not an operation anyone can perform in isolation.** The grant migration only runs when a `wms2-api` image boots, and each env tracks a different branch — so "migration first" on UAT/prd requires a `develop`→`release`→`main` promotion that drags SBDEV-2968, 2984 and 3013 along with it. Plan the promotion, not just the migration. | **YES** |
| **P13** | ✅ **DISCHARGED 2026-08-22 — applied.** `lukamiranda` (user id `864391850`) on `wh01_om1_v2` was given the six groups its three identical peers hold — `inventory-manager, inventory-worker, outbound-forklift, outbound-manager, outbound-worker, receiving` (group ids 51850–51855). Verified through the authoritative `user → group → role → function` path, not by row presence: **0 → 6 groups, `WEB_UI_LOG_IN` absent → present, 0 → 24 web functions**, and the regression predictor now returns a line **byte-identical to `markchilcote`**. The INSERT was guarded with `NOT EXISTS` and is idempotent — ⚠️ the join table has **no unique index**, so an unguarded re-run would duplicate rows. ⚠️ **Only `wh01_om1_v2` was touched**: the same username on WineCo dev is a different row in a different database and was already correctly provisioned (that split is the whole trap — correctly configured where unused, unconfigured where it did 34,770 operations). The 20 menu items still dark for this user are **not** a P13 residue — they are the V2.2.19 grants, and they resolve for all six wsl operators together when the migration runs. | Done |

### 4.1 Implementation checklist

1. `util/appMenuList.js` — single list, `fn` per leaf, delete 4 dead menus.
2. `store/index.js` — `functions` state + `ensureFunctionsLoaded()`.
3. `layouts/default.vue` — filter `links()`; hide empty groups.
4. `middleware/require-function.js` + `nuxt.config.js`.
5. `pages/index.vue` — `WEB_UI_LOG_IN` entry gate.
6. `pages/admin.vue` — per-tab filter.
7. `wms2-api` — `UtilRestController` seed + Flyway VIEW-grant migration.
8. Extend 2968's audit SQL with the web regression predictor.

---

## 5. Test plan

### 5.1 `wms2-web-ui` (Jest)

> ⚠ `wms2-web-ui/CLAUDE.md` is silent on tests but the suite exists. **Baseline: `develop` has 2 always-red
> *suites* and 0 failing tests** — compare the **tests** count, never the suites count. No `yarn` on PATH;
> use nvm node + `node_modules/.bin/jest`.

- `test/util/appMenuList.spec.js` — `everyLeafDeclaresAFunction` · `everyDeclaredFunctionIsAKnownWebConstant` · `theFourDeadPersonaMenusAreGone` · `menuCoversEveryMenuReachablePage`
- `test/layouts/default.spec.js` — `rendersOnlyItemsWhoseFunctionIsHeld` · `hidesAGroupWhenNoChildSurvives` · `superAdminStillSeesAllThirty` · **`csRepSeesTheTwelveItemsItsFunctionsAllow`** (uses the real WineCo CS-REP function set as a fixture — the regression this slice exists to enable)
- `test/middleware/requireFunction.spec.js` — `waitsForEnsureFunctionsLoadedBeforeDeciding` · `redirectsToNotAuthorizedWithPageAndFn` · `allowsUnmappedRoutes` · `detailRoutesInheritTheirListPageFunction` · `routesToUnhealthyTenantOnFetchFailure`
- `test/pages/index.spec.js` — `bouncesUserWithoutWebUiLogIn` · `admitsUserWithWebUiLogIn`
- `test/pages/admin.spec.js` — `rendersOnlyTabsWhoseFunctionIsHeld` · `hidesTheAdminMenuEntryWhenNoTabSurvives` · `userManagementTabHiddenWithoutItsFunction`
- `test/store/index.spec.js` — `getUserRolesCommitsTheFunctions` (**fails today — it commits nothing**) · `ensureFunctionsLoadedIsIdempotentUnderConcurrentCalls`

⚠ **A `:key` remount does NOT reset child state read from stale parent data.** Vue 2 runs the watcher before
render and the reload is async. If the menu filter is implemented with a remount, a test asserting
`$vnode.key` under `shallowMount` goes green on a broken branch.

**Mutation-check every new assertion** (the floor): break what each protects and confirm red. Specifically,
restore `menuList["super-admin"]` and confirm `rendersOnlyItemsWhoseFunctionIsHeld` goes red — a filter test
that passes against the hardcoded menu is asserting nothing.

### 5.2 `wms2-api` (JUnit)

`unit/controller/rest/UtilRestControllerSeedUnitTest` — `seedsMasterDataFunctionsToInventoryManager` ·
`seedsTransferOrderToOutboundManager` · `leavesUserManagementOnSuperAdminOnly`.

No `@SpringBootTest` (SBDEV-2217). Known baseline: 2 pre-existing failures on `develop`. `mvn test` mutates
the tracked `archunit_store` — revert it.

### 5.3 Manual test plan

| # | Persona | Action | Expected |
|---|---|---|---|
| M1 | `CS-REP` (real WineCo role) | log into web | 12 menu items, **no Master Data, no Admin** |
| M2 | mobile-only (0 web fns) | log into web | bounced to `/not-authorized`, message names the web UI (Fix C) |
| M3 | same | deep-link `/admin` | bounced, not rendered |
| M4 | `inventory-manager` after the grant migration | log into web | Master Data + Cycle Count + Inventory Report now visible |
| M5 | `outbound-manager` after migration | Transfer + Transfer Picking | visible |
| M6 | `super-admin` | log into web | all 30 items, all 6 admin tabs — unchanged |
| M8 | any admin | Admin → 3 tabs held, 3 not | only the 3 render; the Admin entry still appears |
| M9 | any user | hard-refresh a deep page | loads; no spurious bounce (cold-start race) |
| M10 | mobile operator | mobile UI end-to-end | **unaffected** — SBDEV-2968's gates unchanged |

### 5.4 Deliberately-skipped coverage

Full-chain (Keycloak → tenant DB → menu) is unautomatable while SBDEV-2217 is open. §5.3 is the evidence
base.

---

## 6. Risks

| # | Risk | Sev | Mitigation | Residual |
|---|---|---|---|---|
| **B-R1** | **The 13 orphaned menu items lock working screens.** Master Data etc. vanish for everyone but the 39 super-admins. | **High** | §2.5 grant seed + P4 (grants before filter) + P3 regression predictor + M4/M5 | Accepted per hard-on. A missed grant is fixed by an administrator through User Management with no deploy. |
| **B-R2** | **Hard-on with no kill switch**, and unlike 2968 there is no pre-existing client-side filter to fall back on. | **High** | P2/P3/P4; deploy order P6; rollback = revert the UI image | Accepted per decision, named explicitly. |
| **B-R3** | **The best-fit grant table is a business assertion.** Assigning master data to `inventory-manager` may be wrong for a given tenant. | **High** | P2; F3 leaves tenant-authored roles untouched; per-tenant override via User Management | Low after P2. |
| **B-R4** | Deep-linkable pages not in the menu fall through the guard. | Medium | P7 enumerates `_id.vue` and other non-menu routes | Low. |
| **B-R5** | Cold-start race — middleware runs before functions load, bouncing every hard refresh. | Medium | Memoised `ensureFunctionsLoaded()` awaited in the guard; M9 | Low. |
| **B-R6** | Flyway version collides with V2.2.18 or an unmerged branch. | Medium | P5 re-sweep immediately before the PR | Low **only at the moment of the sweep**. |
| **B-R7** | `CS-REP`-style tenant roles are modified by the seed. | Low | F3 — the migration touches only the seeded personas, keyed by name | Low. |
| **B-R8** | 🔴 **The slice ships and is read as "the web UI is now secured."** It is not — every gated screen's data is still reachable by `curl`. | **High** | §1.3 says so explicitly; SBDEV-3017 owns the server side. **State this in the PR description, not only in the plan.** | Accepted, named. |

---

## 7. Open decisions

- ✅ **7.1 APPROVED 2026-08-21 (Nam) — ship the §2.5 VIEW table as drafted.** Rationale accepted: grants are adjustable afterwards through Admin → User Management with no deploy, and a hidden menu item is loud and immediately reported. ⚠️ That escape hatch is real but has a dependency — it works because **SBDEV-3005 is deployed** (`60aef02`), which fixed both the reversed role↔function composite key and made the replace atomic. Before this was merged, no function could be added to any role at all.
- 🔴 **7.2 Reports → Parcel Picking (row 26) has no matching constant** — and this is the *inverse* of what
  an earlier draft said. Verified directly: `store/reports/parcelPicking.js` calls
  `/report/exportParcelPicking` and **`/report/parcelPickingView`**; `store/reports/outboundParcel.js` calls
  `/report/exportOutboundParcel` and **`/report/parcelMonitorView`**. Only **`WEB_UI_VIEW_PARCEL_MONITOR`**
  exists in `FunctionEnum` — there is no `..._PARCEL_PICKING`. So `PARCEL_MONITOR` belongs to **row 27**,
  which is the row that actually calls `parcelMonitorView`, and **row 26 is the genuinely unmapped leaf.**

  Options: reuse `WEB_UI_VIEW_PARCEL_MONITOR` as an ANY-of with row 27 (simplest, conflates two screens);
  reuse `WEB_UI_VIEW_PICKING_ORDER` (it is a picking report, and that constant already covers Pick Pack); or
  add `WEB_UI_VIEW_PARCEL_PICKING` — the only option needing a new constant + seed + migration. ✅ **DECIDED 2026-08-21 (Nam): add `WEB_UI_VIEW_PARCEL_PICKING`.** 🔴 **The decision stands but the
  rationale above is FALSE — corrected 2026-08-21.** Row 26 *does* have an endpoint-derived constant.
  All three of its endpoints are backed end-to-end by `OrderDetailMonitorView`
  (`ReportController:363` → `ViewDtoService:1331` → `OrderDetailMonitorViewRepository`;
  `ReportController:189` → `ReportService:277-286`; `ReportController:306-317`), so the matching
  constant is **`WEB_UI_VIEW_ORDER_DETAIL_MONITOR`** — the very constant §7.3 lists as having "no page",
  and which `danielvalentim` and `ursulajimenez` were deliberately provisioned with on **both** wineco
  databases. Somebody granted exactly those two exactly that function, which is only explicable if it
  has a page. So the honest rationale is *"the constant that matches is badly named and we are
  replacing it"*, not *"no matching constant exists"*. Two consequences: (1) the §2.5 row carries a
  **back-compat clause** granting `PARCEL_PICKING` to every role already holding `ORDER_DETAIL_MONITOR`;
  (2) **retiring `ORDER_DETAIL_MONITOR` under §7.3 must sequence AFTER those users move**, or they are
  stripped twice. Move it out of §7.3's "no page" list into "superseded by `PARCEL_PICKING`". It is the only option that does not make two distinct screens share one gate, and the marginal cost is ~3 lines in a grant migration this slice writes anyway. ⚠️ It also touches `/report/reprintLabels`, so it interacts with `PRINT_TOTE_LABELS` — keep tranche C2 deferred until this constant lands. ⚠ It is also coupled to slice C: row 26 calls `/report/reprintLabels`, one of the
  `PRINT_TOTE_LABELS` endpoints.
- **7.3** The **6** `WEB_UI_VIEW_*` constants with no page (`RACK`, `RACK_ROW`,
  `TYPE_CAPACITY_CONSTRAINT`, `STOCK_COUNT`, `SEQUENCE_NUMBER`, `DB_QUERIES`).
  🔴 **`ORDER_DETAIL_MONITOR` was MOVED OUT of this list 2026-08-21 — it is NOT pageless.** §7.2
  establishes it backs menu row 26 end-to-end (`OrderDetailMonitorView`), so it is **superseded by
  `WEB_UI_VIEW_PARCEL_PICKING`, retire only AFTER the migration's back-compat clause has moved its two
  holders** (`danielvalentim`, `ursulajimenez`, on both wineco DBs) — otherwise they are stripped
  twice. This list is what a future retire-ticket will read, which is why the correction lives here and
  not only in §7.2. Remaining pageless constants — retire or leave? 🔴 **`ORDER_DETAIL_MONITOR` has two EXCLUSIVE live holders** (`danielvalentim`, `ursulajimenez`, via `ROLE000143`/`ROLE000144`) — measured 2026-08-21, see §1.2.1. Note `CS-REP`
  holds `STOCK_COUNT` and `DB_QUERIES`, so retiring is not free. Own ticket, not this slice.
  **`WEB_UI_VIEW_CLIENT` was previously miscounted into this list — it is not orphaned**; it backs the
  Admin → Shippers tab.

**Resolved:** menu filtering, route guard, `WEB_UI_LOG_IN` entry gate and per-tab admin gating are all in
scope · rollout is hard-on, no flag · no new `FunctionEnum` constants for the 29 mapped items — the gap is
grants, not constants · tenant-authored roles are not modified.

---

## 8. Acceptance criteria

| # | Criterion | Failing test today |
|---|---|---|
| B-1 | Every menu leaf declares a function | `appMenuList.spec#everyLeafDeclaresAFunction` |
| B-2 | The 4 dead persona menus are gone | `…#theFourDeadPersonaMenusAreGone` |
| B-3 | `links()` filters by held functions | `default.spec#rendersOnlyItemsWhoseFunctionIsHeld` |
| B-4 | A group with no surviving child is hidden | `…#hidesAGroupWhenNoChildSurvives` |
| B-5 | `super-admin` still sees all 30 | `…#superAdminStillSeesAllThirty` — 🔴 **NO LONGER A PIN, corrected 2026-08-21.** With `WEB_UI_VIEW_PARCEL_PICKING` added, "all 30" is reachable only *via the migration*, so this is a real gate. Assert the 30 leaf LABELS and the 9 group labels, not a count of 30 — a count is compatible with many wrong menus (measured: a correct filter followed by a full tree flatten keeps a count-based assertion green while destroying every accordion). |
| B-6 | CS-REP's real function set yields its **15** items | `…#csRepSeesExactlyTheFifteenItemsItsFunctionsAllow` — 🔴 **corrected 2026-08-21: it is 15, not 12**, re-derived twice independently from §0.A.1 crossed with the measured 27-function grant set. Both leaves the old count missed arrive through an **ANY-of** (Handling Units via `CONTAINER`, Admin via `MESSAGES`→Service Log), which is almost certainly how 12 was reached. ⚠️ Row 30's ANY-of therefore makes CS-REP see the Admin **entry**, contradicting §1.2's prose that CS-REP has "no admin". Benign — Service Log is a read — but say so, or the green test reads as a bug. |
| B-7 | `getUserRoles` commits the functions | `store/index.spec#getUserRolesCommitsTheFunctions` — **red today** |
| B-8 | No `WEB_UI_LOG_IN` → bounced | `pages/index.spec#bouncesUserWithoutWebUiLogIn` |
| B-9 | Route guard waits for load before deciding | `requireFunction.spec#waitsForEnsureFunctionsLoadedBeforeDeciding` |
| B-10 | Detail routes inherit their list page's function | `…#detailRoutesInheritTheirListPageFunction` |
| B-11 | Admin tabs filter individually | `admin.spec#rendersOnlyTabsWhoseFunctionIsHeld` |
| B-12 | User Management tab hidden without its function | `…#userManagementTabHiddenWithoutItsFunction` |
| B-13 | Seed grants master data to `inventory-manager` | `UtilRestControllerSeedUnitTest#seedsMasterDataFunctionsToInventoryManager` |
| B-14 ‡ | `USER_MANAGEMENT` stays `super-admin`-only | `…#leavesUserManagementOnSuperAdminOnly` — ‡ **there is no failing test today and there cannot be**: the seed already grants it to `role_super_admin` alone (`UtilRestController:406`). A regression pin that holds the line while the seed is rewritten, not a gate. |
| B-15 | Grant migration is idempotent, `NOT EXISTS`, no `ON CONFLICT` | verify-script rows |
| **B-16** | Every route in `pages/` is in exactly one of `MENU` / `EXTRA_ROUTES` / `UNGATED_ROUTES` | `appMenuList.spec#everyPageOnDiskIsClassified` — the filesystem sweep |
| **B-17** | An ANY-of route admits on **either** function and denies on neither | `requireFunction.spec#anyOfRoutesAdmitOnEitherFunctionAndDenyOnNeither` — 🔴 measured surviving mutant: a verbatim `held.includes(required)` port is 5/5 green while denying a super-admin `/handlingUnits/handling-units` **and** `/admin` |
| **B-18** | `functions*` are never written to `vuex-web` | `persistedState.spec#functionsAreNotPersisted` (Fix H) |
| **B-19** | `ensureFunctionsLoaded` awaits `$kc.ready` before fetching | `store/index.spec#ensureFunctionsLoadedAwaitsKeycloakReadyBeforeFetching` — without it the guard is a permanent no-op |
| **B-20** | The guard denies when functions cannot be loaded | `requireFunction.spec#deniesWhenFunctionsCannotBeLoaded` → `/unhealthy-tenant?reason=functions`, explicitly **not** `/not-authorized` |
| **B-21** | Admin tab PANES track the filtered header list | `admin.spec#panesAlignWithVisibleTabs` — filtering headers alone renders the wrong pane |
| **B-22** | Post-login lands on the first permitted leaf | `pages/index.spec#landsOnTheFirstPermittedLeafWhenDashboardIsDenied` |
| **B-23** | A group with no surviving child is hidden **at every depth** | `default.spec#hidesAnEmptySubGroupInsideMasterData` — 🔴 measured surviving mutant: depth-1-only pruning passes all five existing tests while leaving an empty `Location Data` accordion |
| **B-24** | The migration INSERTs the `mywms_function` row for the new constant | verify row — `updateFunctionList()` has **no reachable caller** (`UtilRestController` is `@Service`, so `initDB` never runs on an existing tenant), so a new `FunctionEnum` constant produces no row and gating row 26 on it hides the report from **everyone including super-admin** |
| **B-25** | The 6 dead/shadow pages are deleted | verify rows — three are live duplicates of gated pages |

‡ **Not a gate.** B-5 is green on `develop` today (the menu *is* hardcoded to super-admin). Marked rather
than padding the failing-test count.

**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2967-B-web-view-gating.sh`. Run before any change
for the FAIL baseline. **Guard every helper on file existence** — the template's `file_not_contains` returns
true for a missing file and false-greens every negative assertion about a new file. Note the template's
`mvn_test_passes` helper is permanently red (`mvn -q` suppresses both strings it greps) — SBDEV-3014.

---

## 8.1 Implementation status — 2026-08-21

**Commits** (both off freshly-fetched `origin/develop`; the base moved mid-flight when SBDEV-3012
landed on both repos, so the worktrees were rebased and every baseline re-measured):

| Repo | Commit | PR | Files |
|---|---|---|---|
| `wms2-api` | `fb069e3` | [#183](https://github.com/SiteBossInc/wms2-api/pull/183) | 5 (+693) |
| `wms2-web-ui` | `0d021f6` | [#72](https://github.com/SiteBossInc/wms2-web-ui/pull/72) | 26 (+2500 / −1400) |

**Results:** web-ui Jest **538 passed, 0 failed** (2 known always-red `labelPrinting` SUITES — compare
the TESTS count, never the suites count); `UtilRestControllerSeedUnitTest` **5/5**; `mvn clean compile`
exit 0; api full suite **5437 tests / 2 failures**, both the known `develop` baseline
(`OptionalSafetyArchTest` ArchUnit drift, `MobilePalletizingServiceTest`); verify script
**`Result: 68 pass, 0 fail, 0 skip`**, negative-tested against six mutants (two of which correctly stay
green because their property moved to Jest — confirmed Jest catches both).

**Tests added:** `test/util/appMenuList.spec.js` (12) · `test/layouts/default.spec.js` (6) ·
`test/middleware/requireFunction.spec.js` (8) · `test/store/index.spec.js` (12) ·
`test/pages/index.spec.js` (6) · `test/pages/admin.spec.js` (8) ·
`test/pages/terminalPages.spec.js` (8) · `test/plugins/persistedStateAuthz.spec.js` (3) ·
`UtilRestControllerSeedUnitTest` (5).

### Landmines this implementation found that the plan did not predict

1. 🔴 **`mywms_function` has FOUR `NOT NULL` columns with no default** beyond the id — `number`,
   `version`, `function`, `client_id`. The first draft of V2.2.19 named only `(id, name)` and raised
   **23502**, which aborts the whole file and freezes that tenant's Flyway chain *silently*. **Nothing
   in either suite could see it**: no test executes SQL (SBDEV-2217) and the verify row checks the
   statement's shape. Found by running the file. Also: the UNIQUE index is on `function`, not `name`,
   so that is the column the NOT EXISTS guard must key on.
2. 🔴 **Filtering the admin tabs renumbers ordinals the panes hardcode.** All seven tab components gate
   their data load on an absolute `admin.parentTab` value (0–6). Committing the *rendered* index means a
   user holding only `WEB_UI_VIEW_MESSAGES` gets Service Log at position 0, its watcher tests
   `newTab === 6`, never fires, and the pane renders an empty table with **no error**. Super-admin holds
   all seven so rendered == canonical — which is why every test and any super-admin manual pass stays
   green. Fixed by carrying a `canonical` ordinal; §2.4 flagged the hazard and the first fix discharged
   only the pane-alignment half.
3. ⚠️ **`typeof [] === 'object'`** — `requiredFunctionsFor` tested the object branch first, so an ANY-of
   array yielded `undefined` and the guard denied `/handlingUnits/handling-units` and `/admin` to
   everyone while rendering `fn=undefined`.
4. ⚠️ **`array_agg` over a varchar column yields `character varying[]`**, and `&&` has no cross-type
   form — the Fix G predictor died with `operator does not exist: text[] && character varying[]` until
   cast. Two further defects in the same query, both measured: `can_enter_web` was NULL rather than
   false for a role-less user so Postgres sorted the **worst-affected users last**, and
   `array_to_string('{NULL}')` returns `''` not NULL so the `(no role)` label could never fire.
5. ⚠️ **`getUserRoles` has no production caller** — `redirectPage` dispatches `ensureFunctionsLoaded`.
   B-7 therefore pins an unreachable action. Relevant to anyone deciding it can be deleted.

### Review outcome — 10 reports, 2 rounds

2 High, 6 Medium, 4 Low, **all fixed**; 1 finding (watcher-only panes not loading on first open)
**refuted** on re-check. **Four of the gate's own assertions were measured vacuous** and rewritten:
`bouncesUserWithoutWebUiLogIn` stayed 5/5 green with the entry gate replaced by `if (false)`; the Fix H
persistence spec passed against a reducer that *explicitly persisted* all three authz keys; two more
asserted source text where the property was behavioural. Every fix is mutation-checked against the
exact mutant that survived.

**Method note worth carrying forward:** every defect in this list was found by *executing* the
artifact — running the SQL, building a reference implementation, probing two orderings side by side —
and none by reading it. See [[verify-rows-cannot-assert-policy-only-jest-can]].

### Deliberately not done

- **Merge, deploy, tag** — P9 gates every environment on `60aef02` and `merge-base` is not sufficient
  (prd runs an image older than `main`); P13 needs `lukamiranda` remediated on `wh01_om1_v2`.
- **Server-side web view gating** — SBDEV-3017, unscheduled. This slice is client-side only.
- **Retiring `WEB_UI_VIEW_ORDER_DETAIL_MONITOR`** — only after V2.2.19's step 6 has run everywhere.
- **Tranche C2 (`PRINT_TOTE_LABELS`)** — slice C.
- **L-5** (three watcher-only admin panes may not load on first open) — investigated, judged
  pre-existing and refuted as a regression from this change.

## 9. Provenance

Analysis and drafting 2026-08-16, grounded by mapping all 30 menu items to the API roots their store modules
actually call (§0.A.1) and validated against `wms2-wineco-dev` live. Put through an independent Critic pass
which returned ITERATE with seven findings, all applied. **Carved out of the monolithic
`SBDEV-2967-web-ui-function-gating-enforcement.md` on 2026-08-21** and re-verified against `origin/develop`
`99e2359` / `5506117`; no evidence was re-derived.

**Three claims in the first draft were wrong and are corrected rather than quietly removed:**

1. *"Every menu→function assignment is derived from observed endpoint usage."* **False** — 2 of 30 rows
   (Dashboard, Pick Pack) are semantics-derived and marked ⚠.
2. *"All 30 menu items map to existing constants."* **False** — row 26 has no clean mapping (§7.2), and the
   orphan count was 14 items / 13 needing grants, not 13.
3. The interceptor was described as this plan's enforcement point for web view functions. **False** — §1.3.
