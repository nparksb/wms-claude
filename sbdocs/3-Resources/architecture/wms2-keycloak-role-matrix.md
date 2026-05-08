---
title: "WMS v2 — Keycloak Role Matrix"
type: architecture
status: active
version: v2
scope: authorization
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-08
verified_by: code read across v2/wms2-api WmsConstants + Authority + AdminController + UtilRestController + wms2-mobile-ui store/home.js
related:
  - ./wms2-end-to-end-request-journey.md
  - ./wms2-tenant-routing-datasource-topology.md
  - ../data-dictionary/wms2-sysprop-catalog.md
tags:
  - architecture
  - authorization
  - keycloak
  - roles
  - wms2
---

# WMS v2 — Keycloak Role Matrix

**Scope:** Every realm role referenced across `wms2-api`, `wms2-web-ui`, and `wms2-mobile-ui`, mapped to the feature it gates · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

v2 uses Keycloak realm roles for coarse page/feature gating and Keycloak group paths for tenant + warehouse scoping. There are **four** role-type namespaces in use:

| Namespace | Example | Gate style |
|---|---|---|
| `sb_admin` | `sb_admin` | Backend `@PreAuthorize(Authority.IS_SB_ADMIN)` — SiteBoss super-admin |
| `WEB_UI_*` | `WEB_UI_VIEW_ORDER_MONITOR`, `WEB_UI_ACTION_DELETE_UNIT_LOAD` | Web UI page + backend service-level checks (via `FunctionEnum`) |
| `MOBILE_UI_*` | `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_LOG_IN` | Mobile UI page (filtered from static menu by `store/home.js`) |
| `SPECIAL_*` | `SPECIAL_DEVELOPER` | Developer access; purpose currently unclear |

**Three load-bearing facts:**

1. **Realm roles are declared in `WmsConstants.FunctionEnum` (lines 344–422).** All 51 constants live there; grep for a role name in just this file to find where it's authoritative.
2. **Backend enforcement is mostly at the service layer, not annotation layer.** `AdminController` uses `@PreAuthorize(Authority.IS_SB_ADMIN)` for user/group management (10 endpoints), but most `WEB_UI_ACTION_*` and `WEB_UI_VIEW_*` roles are checked via `syspropService` / `functionService` calls inside service methods, not declarative annotations.
3. **Mobile menu gating is UI-side only.** The mobile UI calls `GET /user/getAllRoles/{username}` on login and filters the static menu (`store/home.js:98-113`). **The backend does not re-enforce mobile view roles** — an operator who bypasses the menu (deep link, API replay) will hit service logic without the role check. Check §6 for the implications.

---

## 2. Namespace Layout

### 2.1 `sb_admin` — SiteBoss super-admin

- Defined: `Authority.java:19` (`SB_ADMIN_ROLE = "sb_admin"`)
- Expression: `Authority.IS_SB_ADMIN`
- Enforced by: `@PreAuthorize(Authority.IS_SB_ADMIN)` on `AdminController` methods (lines 93–309) — 10 endpoints covering `/v3/user/*` and `/v3/groups/*` administration.
- Typical grantee: SiteBoss engineering / ops staff. Not tenant-scoped.

### 2.2 `WEB_UI_VIEW_*` — Web UI page gates

40 constants at `WmsConstants.FunctionEnum:344–409`. Each one typically corresponds to a top-level page or a sensitive action in `wms2-web-ui`. See §3 for the full table.

### 2.3 `MOBILE_UI_*` — Mobile UI page gates

12 constants at `WmsConstants.FunctionEnum:410–421`. Each one (except `LOG_IN` and `NEVER_TIME_OUT`) is mapped to exactly one mobile workflow page in `wms2-mobile-ui/store/home.js:setStaticMenus`.

### 2.4 `SPECIAL_DEVELOPER` (and the orphans)

`WmsConstants.FunctionEnum:422`. Defined but no referenced consumer found. §5.

---

## 3. Full Role Table

Rows marked — (em dash) in a column mean "not referenced there."

### 3.1 Administrative (backend-enforced)

| Role | Backend | Web UI gate | Mobile UI gate | Purpose |
|---|---|---|---|---|
| `sb_admin` | `Authority.IS_SB_ADMIN` → `AdminController:93-309` (10 endpoints, `/v3/user/*` + `/v3/groups/*`) | — | — | SiteBoss global admin — user/group management |

### 3.2 Web UI — `WEB_UI_LOG_IN` + admin pages

| Role | Web UI page / feature | Backend consumer | Purpose |
|---|---|---|---|
| `WEB_UI_LOG_IN` | Login gate | `UtilRestController` — assigned as baseline to every role | App entry |
| `WEB_UI_VIEW_USER_MANAGEMENT` | User management page | `UtilRestController` (assigned to `role_inventory_manager`) | User admin |
| `WEB_UI_VIEW_IMPORT_DATA` | Data import | — (orphan, see §5) | File import |
| `WEB_UI_VIEW_SYSTEM_PROPERTY` | Sysprop admin | — (orphan) | See [wms2-sysprop-catalog.md](../data-dictionary/wms2-sysprop-catalog.md) |
| `WEB_UI_VIEW_CLIENT` | Client/tenant admin | — (orphan) | Client config |
| `WEB_UI_VIEW_USER` | User list | — (orphan) | User listing |
| `WEB_UI_VIEW_GROUP` | Group admin | — (orphan) | Keycloak group mgmt |
| `WEB_UI_VIEW_ROLE` | Role admin | — (orphan) | Role mgmt |
| `WEB_UI_VIEW_FUNCTION` | Function admin | — (orphan) | Permission/function mgmt |
| `WEB_UI_VIEW_MESSAGES` | Message queue | — (orphan) | OMS message audit |

### 3.3 Web UI — Master data & inventory

| Role | Web UI page | Purpose |
|---|---|---|
| `WEB_UI_VIEW_STOCK_COUNT` | Stock count | Cycle-count list |
| `WEB_UI_VIEW_STORAGE_LOCATION` / `*_TYPE` | Location / type master | Location CRUD |
| `WEB_UI_VIEW_RACK` / `*_ROW` | Rack structure | Rack CRUD |
| `WEB_UI_VIEW_AREA` | Location areas | Area CRUD |
| `WEB_UI_VIEW_SECTION` | Warehouse sections | Section CRUD (drives picking type) |
| `WEB_UI_VIEW_ITEM_DATA` | SKU master | Item CRUD |
| `WEB_UI_VIEW_FIXED_ASSIGNMENT` | Fixed-location assignments | Replenishment-source config |
| `WEB_UI_VIEW_ITEM_UNIT` | UoM conversion | Item unit CRUD |
| `WEB_UI_VIEW_CASE_TYPE` | Case types | Box-type CRUD |
| `WEB_UI_VIEW_UNIT_LOAD_TYPE` | Unit load types | UL type CRUD |
| `WEB_UI_VIEW_STOCK_UNIT` | Stockunit list | Stock browser |
| `WEB_UI_VIEW_CONTAINER` | Container list | Unitload browser |
| `WEB_UI_VIEW_STOCK_UNIT_RECORD` | Stock ledger | Stockrecord audit |
| `WEB_UI_VIEW_UNIT_LOAD_RECORD` | UL history | UnitloadRecord audit |
| `WEB_UI_VIEW_INVENTORY_RECORD` | Inventory export | See `StockSummaryExportJob` |

### 3.4 Web UI — Inbound / Goods receipt

| Role | Purpose |
|---|---|
| `WEB_UI_VIEW_CREATE_INBOUND_BOL` | Inbound BOL entry |
| `WEB_UI_VIEW_RECEIVING` | Receiving dashboard |
| `WEB_UI_VIEW_INBOUND_BOL` / `*_POSITION` | Inbound BOL detail |
| `WEB_UI_VIEW_GOODS_RECEIPT` / `*_POSITION` | Goods receipt detail |

### 3.5 Web UI — Outbound / Picking / BOL

| Role | Typical assignee | Purpose |
|---|---|---|
| `WEB_UI_VIEW_REPLENISHMENT_ORDER` | outbound ops | Replenish order list |
| `WEB_UI_VIEW_ORDER_BATCH` | `role_outbound_manager` | Order batch list |
| `WEB_UI_VIEW_ORDER` / `*_POSITION` | `role_outbound_manager` | Order detail |
| `WEB_UI_VIEW_PICKING_ORDER` / `*_POSITION` | `role_outbound_manager` | Picking detail |
| `WEB_UI_VIEW_BILL_OF_LADING` / `*_POSITION` | `role_outbound_manager` | BOL detail |
| `WEB_UI_VIEW_CLUB_LINE` | — (specific) | Club run UI |
| `WEB_UI_VIEW_TRANSFER_ORDER` | — | Transfer orders (also used by mobile menu — see §3.7) |

### 3.6 Web UI — Monitors / operations dashboards

| Role | Assigned to | Purpose |
|---|---|---|
| `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | `role_inventory_manager` | Lock overview |
| `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | inventory | Received stock summary |
| `WEB_UI_VIEW_LOCATION_OVERVIEW` | `role_outbound_manager` | Location monitor |
| `WEB_UI_VIEW_ORDER_MONITOR` | `role_outbound_manager` | Order monitor |
| `WEB_UI_VIEW_REPLENISHMENT_MONITOR` | `role_inventory_manager` + `role_outbound_manager` | Replenish monitor |
| `WEB_UI_VIEW_FLOWBIN_MONITOR` | `role_inventory_manager` + `role_outbound_manager` | Flowbin monitor |
| `WEB_UI_VIEW_PARCEL_MONITOR` | `role_inventory_manager` + `role_outbound_manager` | Parcel monitor |
| `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` | outbound | Order drill-down |
| `WEB_UI_VIEW_CYCLECOUNT` / `*_POSITION` | inventory | Cycle count monitor |
| `WEB_UI_VIEW_DB_QUERIES` | `role_inventory_manager` + `role_outbound_manager` | Saved-query admin |
| `WEB_UI_VIEW_PRINTER` | ops | Printer config |
| `WEB_UI_VIEW_SEQUENCE_NUMBER` | admin | Sequence counter config |

### 3.7 Web UI — Destructive / sensitive actions

| Role | Purpose | Enforcement |
|---|---|---|
| `WEB_UI_ACTION_DELETE_UNIT_LOAD` / `*_POSITION` | Delete unit load or its position | `UnitLoadController` → service-level `FunctionEnum` check |
| `WEB_UI_ACTION_ADJUST_STOCK` / `*_ORDER` / `*_RESERVATION` | Stock/order/reservation adjustments | Service-level check |
| `WEB_UI_ACTION_PRINT_TOTE_LABELS` | Print labels | Service-level check |

### 3.8 Mobile UI — all 12 roles

These are the authoritative Mobile role set. Source: `wms2-mobile-ui/store/home.js:19-94` (`setStaticMenus`).

| Role | Mobile page | Link | Backend consumer |
|---|---|---|---|
| `MOBILE_UI_LOG_IN` | (gate) | — | `UtilRestController` — assigned to `role_inventory_*`, `role_outbound_*` |
| `MOBILE_UI_NEVER_TIME_OUT` | session override | — | Mobile UI session manager (bypasses auto-logout) |
| `MOBILE_UI_VIEW_INFO` | Lookup | `/lookup` | — |
| `MOBILE_UI_VIEW_PUT_AWAY` | Putaway | `/putaway` | — (see [wms2-receiving-putaway-workflow.md](../workflows/wms2-receiving-putaway-workflow.md)) |
| `MOBILE_UI_VIEW_TRANSFER` | Move Unitload | `/move-unitload` | — |
| `MOBILE_UI_VIEW_STOCK_TRANSFER` | Move Stock | `/move-stock` | — |
| `MOBILE_UI_VIEW_PICKING` | Picking | `/picking` | — (see [wms2-picking-workflow.md](../workflows/wms2-picking-workflow.md)) |
| `MOBILE_UI_VIEW_PALLETIZING` | Palletizing | `/palletizing` | — |
| `MOBILE_UI_VIEW_TRUCK_LOADING` | Truck Loading | `/truck-loading` | — (see [wms2-bol-truck-loading-workflow.md](../workflows/wms2-bol-truck-loading-workflow.md)) |
| `MOBILE_UI_VIEW_CYCLE_COUNT` | Cycle Count | `/cycle-count` | — |
| `MOBILE_UI_VIEW_REPLENISHMENT` | Replenish Process + Replenish Request | `/replenish`, `/replenish-request` | — |
| `MOBILE_UI_VIEW_LPN_ASSOCIATION` | (not in static menu) | — (orphan) | Reserved for future LPN flow |

**Note the odd one:** `WEB_UI_VIEW_TRANSFER_ORDER` appears in the mobile menu (line 86) as the Transfer Process page. This is the only mobile menu entry that uses a `WEB_UI_*` role — likely a naming oversight. Don't rename without coordinating a realm-role migration.

---

## 4. Composite Roles → Function Assignments

`UtilRestController` initializes a fixed set of **composite roles** on first run. Each composite role grants a bundle of functions (the realm roles above). These are the practical "job titles" Keycloak administrators assign to end users.

| Composite role | Persona | Granted functions (summary) |
|---|---|---|
| `group_super_admin` | SiteBoss admin | `WEB_UI_VIEW_USER_MANAGEMENT`, `WEB_UI_LOG_IN` + more |
| `role_inventory_manager` | Warehouse inventory ops lead | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER`, `WEB_UI_LOG_IN`, `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW`, `WEB_UI_VIEW_REPLENISHMENT_MONITOR`, `WEB_UI_VIEW_FLOWBIN_MONITOR`, `WEB_UI_VIEW_PARCEL_MONITOR`, `WEB_UI_VIEW_DB_QUERIES` |
| `role_inventory_worker` | Floor inventory worker | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER` |
| `role_outbound_manager` | Outbound ops lead | Mobile picking/palletizing + most `WEB_UI_VIEW_*` monitors |
| `role_outbound_forklift` | Forklift operator | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_TRUCK_LOADING` |
| `role_outbound_worker` | Packing/palletizing floor | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_PALLETIZING` |

These composites are wired at `UtilRestController` during app init. The mapping is code-declared — changing it requires a backend deploy, not a Keycloak admin change.

---

## 5. Orphans

**Defined but no consumer found (as of 2026-04-19):**

| Role | Likely status |
|---|---|
| `WEB_UI_VIEW_IMPORT_DATA`, `WEB_UI_VIEW_SYSTEM_PROPERTY`, `WEB_UI_VIEW_CLIENT`, `WEB_UI_VIEW_USER`, `WEB_UI_VIEW_GROUP`, `WEB_UI_VIEW_ROLE`, `WEB_UI_VIEW_FUNCTION`, `WEB_UI_VIEW_MESSAGES` | Admin-panel pages that may be gated at the UI router level only (not yet confirmed in web-ui source) |
| `MOBILE_UI_VIEW_LPN_ASSOCIATION` | Not in static menu; reserved |
| `SPECIAL_DEVELOPER` | Purpose unclear |
| All `WEB_UI_ACTION_*` (5 roles) | Service-level `FunctionEnum` checks — not annotation-level |

Orphans fall into two honest categories:

1. **UI-only gated** — web UI hides the page or button, backend does not re-enforce. A determined user can bypass by direct API call.
2. **Reserved** — defined for future use; no feature yet exists.

Audit recommendation: grep the `wms2-web-ui` repo for each "orphan" to classify definitively. This matrix only reports what `wms2-api` + `wms2-mobile-ui` know about.

---

## 6. Group Paths (NOT roles)

Two sysprop-backed group paths gate tenant / warehouse scoping. They are Keycloak **group paths**, not realm roles:

| Sysprop | Default | Purpose |
|---|---|---|
| `APP_GROUP` | `/wms/wh/user` | Standard user — implied warehouse membership |
| `APP_ADMIN_GROUP` | `/wms/wh/wms_admin` | Admin — implied warehouse-admin membership |
| `KEYCLOAK_APP_GROUP_NAME` | — (per-tenant) | Tenant-configurable app group name |

Consumed by:

- `AdminController` endpoints `/v3/user/addUserToWarehouseGroup`, `/removeUserFromWarehouseGroup`, `/isWarehouseUser/{username}`
- `KeycloakService` (service-level integration with Keycloak Admin API)
- Token parsing on the mobile UI (`tokenParsed.warehouse` claim exposes the array of facility codes the user can access — see [wms2-end-to-end-request-journey.md](./wms2-end-to-end-request-journey.md) §3)

Group paths determine *which* tenant+facility a user belongs to. Realm roles determine *what* they can do within that tenant+facility. Both must match for a request to succeed.

---

## 7. Service-Account Role — `KEYCLOAK_API_USER`

Defined as a sysprop (see [wms2-sysprop-catalog.md](../data-dictionary/wms2-sysprop-catalog.md) §9). Used by:

- WMS → OMS calls (OMS-side identity)
- WMS → Keycloak Admin API calls (user/role provisioning)

Not a realm role in the sense above — it's a service-account principal. Its authorization is Keycloak-client-configured; changing it requires Keycloak admin, not WMS deploys.

---

## 8. Known Landmines

1. **Mobile UI gating is client-side only.** `MOBILE_UI_VIEW_*` roles filter the static menu but the backend does not re-enforce them. API replay / deep link bypasses the gate. Security-sensitive mobile workflows should duplicate the check at the backend service layer.
2. **`WEB_UI_VIEW_TRANSFER_ORDER` in the mobile menu** (§3.8) is a naming oversight — the mobile Transfer Process page uses a `WEB_UI_*` role. Don't rename without a realm-role migration.
3. **Most `WEB_UI_ACTION_*` roles are enforced at service layer, not annotation layer.** Removing a service-internal `FunctionEnum` check silently broadens access.
4. **Composite roles are hard-coded in `UtilRestController`.** A new persona requires a code change + deploy, not a Keycloak-only operation.
5. **Group paths vs realm roles are distinct.** A user with all the right roles but no matching group membership will still fail tenant routing — and vice versa.
6. **Orphan roles are defined but unused.** Granting them to a composite role is a no-op. Use the table in §5 before expecting a new permission to take effect.
7. **`sb_admin` is the only annotation-enforced role** (`@PreAuthorize(Authority.IS_SB_ADMIN)` on `AdminController`). Everywhere else, enforcement is service-layer — easier to miss when refactoring.
8. **`MOBILE_UI_NEVER_TIME_OUT` is not a view role.** Granting it changes session timeout behavior on the mobile UI only. Don't assign casually.

---

## 9. How to use this doc

| Task | Start at |
|---|---|
| Security audit (who can hit endpoint X?) | §3 find the role → §4 find the composites that grant it → Keycloak admin (users of that composite) |
| Adding a new mobile page | §3.8 reserve a `MOBILE_UI_VIEW_*` constant in `WmsConstants.FunctionEnum` → add entry in `store/home.js:setStaticMenus` → enforce at service layer (§8 item 1) |
| Adding a new admin page | §2.1 if truly admin-only, guard with `@PreAuthorize(Authority.IS_SB_ADMIN)` on the controller |
| Adding a new composite role | §4 edit `UtilRestController` composite init block → code deploy |
| Debugging "user can't see a page" | Keycloak → composite role → §4 → §3 view-role → UI gate |
| Debugging "user can hit an endpoint they shouldn't" | §8 item 1 — likely service-layer check missing |
| Cleaning up orphans | §5 — audit web UI source, classify, decide keep/remove |

---

## 10. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | All constants in `WmsConstants.FunctionEnum:344-422`, `AdminController` `@PreAuthorize` usage, `UtilRestController` composite role init, `wms2-mobile-ui/store/home.js:setStaticMenus`, `Authority.java` SB_ADMIN definition | All 51 realm-role constants accounted for; 3 composite roles + 3 additional personas enumerated | Code read (grep-based across 3 repos) |

**Re-verify every 60 days.** Next due: **2026-06-18** — role churn is typically 2-4 constants per quarter; any feature that adds a new protected page invalidates this matrix.
