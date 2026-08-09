---
title: "WMS v2 — Keycloak Role Matrix"
type: architecture
status: active
version: v2
scope: authorization
owner: Nam Park
created: 2026-04-19
updated: 2026-08-07
last_verified: 2026-08-07
verified_by: 2026-08-07 SBDEV-2863 fix + code review (Authority.java, CustomMethodSecurityExpressionRoot/Handler, AdminController @PreAuthorize audit incl. the 5 ungated sites, SecurityConfiguration rule-precedence recheck); prior 2026-06-24 re-read of v2/wms2-api WmsConstants.FunctionEnum (344-423) + Authority.java + AdminController.java (@PreAuthorize audit) + UtilRestController.java (255-420 persona seed) + SecurityConfiguration.java (116-136) + wms2-mobile-ui store/home.js (setStaticMenus)
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
**Owner:** Nam Park · **Last verified:** 2026-08-07

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

1. **Realm roles are declared in `WmsConstants.FunctionEnum` (lines 344–423).** All **80** constants live there (66 `WEB_UI_*` at 344–409, 13 `MOBILE_UI_*` at 410–422, 1 `SPECIAL_*` at 423); grep for a role name in just this file to find where it's authoritative.
2. **Backend enforcement is mostly at the service layer, not annotation layer.** `@PreAuthorize(Authority.IS_SB_ADMIN)` guards **9 active endpoints** (8 on `AdminController` + `ReplenishmentReconciliationController:37`), but most `WEB_UI_ACTION_*` and `WEB_UI_VIEW_*` roles are checked via `syspropService` / `functionService` calls inside service methods, not declarative annotations. ⚠️ **Two separate problems, both in §2.1:** (a) that annotation was **completely broken 2025-10-29 → 2026-08-07** and enforced nothing — it returned HTTP 500 to everyone (SBDEV-2863, now fixed); (b) **five** `AdminController` endpoints remain ungated (SBDEV-2870, urgent).
3. **Mobile menu gating is UI-side only.** The mobile UI calls `GET /user/getAllRoles/{username}` (`store/home.js:106`) on login and filters the static menu (filter at `store/home.js:108-113`). **The backend does not re-enforce mobile view roles** — an operator who bypasses the menu (deep link, API replay) will hit service logic without the role check. Check §6 for the implications.

---

## 2. Namespace Layout

### 2.1 `sb_admin` — SiteBoss super-admin

- Defined: `Authority.java:14` (`SB_ADMIN_ROLE = "sb_admin"`)
- Expression: `Authority.IS_SB_ADMIN` = `"hasAuthority('sb_admin')"` (`Authority.java`, declared immediately below `SB_ADMIN_ROLE`) — a **Spring built-in**, not a custom SpEL method.
- Enforced by: `@PreAuthorize(Authority.IS_SB_ADMIN)` on **9 active** endpoints — 8 on `AdminController`: `findUsers` (:80), `findUserByUsername` (:108), `deleteUserByUsername` (:121), `findUserGroupsByUsername` (:134), `createUser` (:143), `updateUser` (:155), `resetPassword` (:176), `findGroup` (:200) — plus **`ReplenishmentReconciliationController:37`** (per-tenant stranded-reservation reconciliation, SBDEV-2610 C1), which this doc previously omitted.
- Typical grantee: SiteBoss engineering / ops staff. Not tenant-scoped.

> ## 🔴 THIS EXPRESSION WAS BROKEN FOR ~9 MONTHS — 2025-10-29 → 2026-08-07 (SBDEV-2863)
>
> **Everything this section previously described as enforcement was not enforcement.** `IS_SB_ADMIN` read
> `"isSbAdmin()"`, and **no such method has ever existed** on `CustomMethodSecurityExpressionRoot` — its only
> admin predicate is `isAimAdmin()` (`:77`). Spring resolves a `@PreAuthorize` string reflectively against
> that root, so every one of the 9 annotated endpoints threw
> `SpelEvaluationException EL1004E` *inside the authorization check* and returned **HTTP 500 to every
> caller, `sb_admin` included.** Not a denial — a crash. Those endpoints were non-functional, not protected.
>
> **Provenance:** `ded4d644` (2025-10-29, "cleaned up the code") renamed `IS_AIM_ADMIN`/`"isAimAdmin()"` to
> `IS_SB_ADMIN`/`"isSbAdmin()"` and `AIM_ADMIN_ROLE` → `SB_ADMIN_ROLE`, but left the method on the
> expression root named `isAimAdmin()`. A half-finished `aim_admin` → `sb_admin` rebrand. **The expression
> worked before that commit.**
>
> **Operational consequence worth knowing:** `ReplenishmentReconciliationController:37` was added *after*
> 2025-10-29, so **it has never once worked** — every attempt to run the SBDEV-2610 stranded-reservation
> remediation returned 500. Reservations that remediation was meant to clear may still be stranded on every
> tenant.
>
> **Why no test caught it:** `CustomMethodSecurityExpressionRootUnitTest` called `isAimAdmin()` *directly*
> and never evaluated the SpEL string; and `BaseControllerUnitTest:50` uses `MockMvcBuilders.standaloneSetup`,
> which installs no security filter chain and no method-security advisor — so **no controller unit test in
> this repo evaluates `@PreAuthorize` at all.** The `@SpringBootTest` lane that would is down (SBDEV-2217).
>
> **Fixed by SBDEV-2863** → `hasAuthority('sb_admin')`, semantically identical to what `isAimAdmin()`
> delegates to. ⚠️ The constant is a **compile-time constant**, so javac inlines its value into every
> consumer class file — and `pom.xml:440` disables incremental compilation. **Verify this fix only against a
> `mvn clean` build**; a warm `target/` reproduces the old 500. The release path (`Dockerfile:10`,
> `mvn clean package`) is already safe. A durable guard for the whole defect class is tracked by **SBDEV-2872**.

> ⚠️ **SECURITY GAP — STILL OPEN, now tracked by [SBDEV-2870](https://app.clickup.com/t/868knqrwr) (urgent).** **Five** `AdminController` endpoints are ungated. `/v3/**` → `hasAnyAuthority("wms_user")` (**rule D**, `SecurityConfiguration.java:136`) is what applies — *not* rule C's `/user/**` matcher at `:132`, which is root-relative and does **not** match `/v3/user/**`. Either way the effective gate is `wms_user`, so **any authenticated warehouse user** can reach all five:
> - `importUsersFromCsvText` — `AdminController.java:190` (commented), `GET /v3/admin/importUsersFromCsvText` — **bulk Keycloak user creation from CSV; a privilege-escalation path**
> - `addUserToWarehouseGroup` — `AdminController.java:261` (commented), `POST /v3/user/addUserToWarehouseGroup`
> - `removeUserFromWarehouseGroup` — `AdminController.java:285` (commented), `POST /v3/user/removeUserFromWarehouseGroup`
> - `isWarehouseUser` — `AdminController.java:315` (commented), `GET /v3/user/isWarehouseUser`
> - `userExistsInKeycloak` — `AdminController.java:359` (**never had a `@PreAuthorize`**), `GET /v3/user/existsInKeycloak` (Keycloak user-enumeration vector)
>
> **New finding (SBDEV-2863 review): four of the five were most likely commented out *because of* the defect above, not as a decision.** `c8ce58d9` (2026-02-01) *replaced* three previously-**guarded** group endpoints with these warehouse-group endpoints, committing their annotations **already commented out** — three months into the broken window, when the guard returned 500 to everyone. `:190` is the exception (commented by `5ac0262c`, 2024-10-16, before the rename) and is a genuine deliberate choice.
>
> **Do not simply restore the annotations:** `wms2-web-ui` calls three of them from the User Management screen (`store/admin/user.js:175, 193, 207, 218` via `components/admin/userManagement/users/userWarehouseEdit.vue:127-162`), so a guard would 403 that screen for every non-`sb_admin` admin. Coordinated API+UI change — see SBDEV-2870.
>
> Related: `findUsers` (`:80-103`) reads a `jwt.getClaimAsStringList("authorities")` claim that `JwtAccessTokenCustomizer:86-107` never populates, so its SiteBoss-staff filter has never worked and its `else` branch is now unreachable — **SBDEV-2871**.

### 2.2 `WEB_UI_*` — Web UI page + action gates

**66 constants** at `WmsConstants.FunctionEnum:344–409`: 58 `WEB_UI_VIEW_*` / `WEB_UI_LOG_IN` page gates (344–401) plus 8 `WEB_UI_ACTION_*` destructive-action gates (402–409). Each typically corresponds to a top-level page or a sensitive action in `wms2-web-ui`. See §3 for the full table.

### 2.3 `MOBILE_UI_*` — Mobile UI page gates

**13 constants** at `WmsConstants.FunctionEnum:410–422` (`MOBILE_UI_VIEW_CANCELLATION` at :422 was added since the prior audit). Each one (except `LOG_IN` and `NEVER_TIME_OUT`) is mapped to a mobile workflow page in `wms2-mobile-ui/store/home.js:setStaticMenus`.

### 2.4 `SPECIAL_DEVELOPER` (and the orphans)

`WmsConstants.FunctionEnum:423`. Defined but no referenced consumer found. §5.

---

## 3. Full Role Table

Rows marked — (em dash) in a column mean "not referenced there."

### 3.1 Administrative (backend-enforced)

| Role | Backend | Web UI gate | Mobile UI gate | Purpose |
|---|---|---|---|---|
| `sb_admin` | `Authority.IS_SB_ADMIN` → **9 active** `@PreAuthorize` endpoints: `AdminController` :80,108,121,134,143,155,176,200 (`/v3/user/*` + `/v3/groups/*`) + `ReplenishmentReconciliationController:37` | — | — | SiteBoss global admin. ⚠️ **Enforced nothing 2025-10-29 → 2026-08-07 — the expression threw and returned 500 to everyone (SBDEV-2863, fixed).** ⚠️ **5 ungated endpoints remain: :190, 261, 285, 315 (commented) + :359 (never annotated) — SBDEV-2870** |

### 3.2 Web UI — `WEB_UI_LOG_IN` + admin pages

| Role | Web UI page / feature | Backend consumer | Purpose |
|---|---|---|---|
| `WEB_UI_LOG_IN` | Login gate | `UtilRestController` — assigned as baseline to most roles (admin user :258, inventory-manager :278, outbound-manager :302, receiving :331, super-admin :355) | App entry |
| `WEB_UI_VIEW_USER_MANAGEMENT` | User management page | `UtilRestController` — assigned to the `admin` user directly (:257) **and** `role_super_admin` (:406). **Not** `role_inventory_manager`. | User admin |
| `WEB_UI_VIEW_IMPORT_DATA` | Data import | `role_super_admin` (:370) | File import |
| `WEB_UI_VIEW_SYSTEM_PROPERTY` | Sysprop admin | `role_super_admin` (:401) | See [wms2-sysprop-catalog.md](../data-dictionary/wms2-sysprop-catalog.md) |
| `WEB_UI_VIEW_CLIENT` | Client/tenant admin | `role_super_admin` (:360) | Client config |
| `WEB_UI_VIEW_USER` | User list | `role_super_admin` (:405) | User listing |
| `WEB_UI_VIEW_GROUP` | Group admin | `role_super_admin` (:369) | Keycloak group mgmt |
| `WEB_UI_VIEW_ROLE` | Role admin | `role_super_admin` (:393) | Role mgmt |
| `WEB_UI_VIEW_FUNCTION` | Function admin | `role_super_admin` (:366) | Permission/function mgmt |
| `WEB_UI_VIEW_MESSAGES` | Message queue | `role_super_admin` (:381) | OMS message audit |

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
| `WEB_UI_VIEW_INBOUND_BOL` / `WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES` | Inbound BOL header + item lines |
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

There are exactly **8** `WEB_UI_ACTION_*` constants (`WmsConstants.FunctionEnum:402–409`). All 8 are assigned to `role_super_admin` in `UtilRestController` (:351–354, 413–416); enforcement is otherwise service-level `FunctionEnum` checks, not annotations.

| Role | Constant line | Purpose | Enforcement |
|---|---|---|---|
| `WEB_UI_ACTION_DELETE_UNIT_LOAD` | :402 | Delete unit load | Service-level `FunctionEnum` check |
| `WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE` | :403 | Recursive unit-load delete | Service-level check |
| `WEB_UI_ACTION_ADJUST_AMOUNT` | :404 | Adjust stockunit amount | Service-level check |
| `WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT` | :405 | Adjust reserved amount | Service-level check |
| `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK` | :406 | Release stock lock | Service-level check |
| `WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD` | :407 | Place on-hold lock | Service-level check |
| `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | :408 | Place damaged lock | Service-level check |
| `WEB_UI_ACTION_PRINT_TOTE_LABELS` | :409 | Print tote labels | Service-level check |

### 3.8 Mobile UI — all 13 roles

These are the authoritative Mobile role set (13 `MOBILE_UI_*` constants, `WmsConstants.FunctionEnum:410–422`). Menu source: `wms2-mobile-ui/store/home.js:19-99` (`setStaticMenus`).

| Role | Mobile page | Link | Backend consumer |
|---|---|---|---|
| `MOBILE_UI_LOG_IN` | (gate) | — | `UtilRestController` — assigned to all 6 mobile personas (inventory-manager/-worker, outbound-forklift/-manager/-worker, receiving) + super-admin |
| `MOBILE_UI_NEVER_TIME_OUT` | session override | — | Not in menu / not seeded to any persona — Mobile UI session manager only (bypasses auto-logout). Orphan, §5 |
| `MOBILE_UI_VIEW_INFO` | Lookup | `/lookup` | — |
| `MOBILE_UI_VIEW_PUT_AWAY` | Putaway | `/putaway` | `role_receiving` (:327), `role_super_admin` (:346) (see [wms2-receiving-putaway-workflow.md](../workflows/wms2-receiving-putaway-workflow.md)) |
| `MOBILE_UI_VIEW_TRANSFER` | Move Unitload | `/move-unitload` | — |
| `MOBILE_UI_VIEW_STOCK_TRANSFER` | Move Stock | `/move-stock` | — |
| `MOBILE_UI_VIEW_PICKING` | Picking | `/picking` | `role_outbound_manager`/`-worker`, `role_super_admin` (see [wms2-picking-workflow.md](../workflows/wms2-picking-workflow.md)) |
| `MOBILE_UI_VIEW_PALLETIZING` | Palletizing | `/palletizing` | `role_outbound_manager`/`-worker`, `role_super_admin` |
| `MOBILE_UI_VIEW_TRUCK_LOADING` | Truck Loading | `/truck-loading` | `role_outbound_forklift`/`-manager`, `role_super_admin` (see [wms2-bol-truck-loading-workflow.md](../workflows/wms2-bol-truck-loading-workflow.md)) |
| `MOBILE_UI_VIEW_CYCLE_COUNT` | Cycle Count | `/cycle-count` | `role_inventory_manager`/`-worker`, `role_super_admin` |
| `MOBILE_UI_VIEW_REPLENISHMENT` | Replenish Process + Replenish Request | `/replenish`, `/replenish-request` | `role_receiving` (:328), `role_super_admin` (:347) |
| `MOBILE_UI_VIEW_CANCELLATION` | Cancellation Process | `/cancellation` | — (menu role at `store/home.js:89-92`; not seeded to any persona in `UtilRestController`). New since prior audit. Orphan, §5 |
| `MOBILE_UI_VIEW_LPN_ASSOCIATION` | (LPN Associate — menu block **commented out**, `store/home.js:94-98`) | — | Reserved for future LPN flow. Orphan, §5 |

**Note the odd one:** `WEB_UI_VIEW_TRANSFER_ORDER` appears in the mobile menu (`store/home.js:82-87`, the Transfer Process page) as the only mobile menu entry that uses a `WEB_UI_*` role — likely a naming oversight. Don't rename without coordinating a realm-role migration.

---

## 4. Personas (DB-backed `UserRole` / `UserGroup` seed rows) → Function Assignments

`UtilRestController` seeds a fixed set of **7 personas** on first run (`:239-245` create `UserRole`s; `:247-253` create matching `UserGroup`s). **These are NOT Keycloak realm/composite roles** — they are rows in the tenant DB `UserRole` / `UserGroup` tables, created via `userRoleService.createEntity(...)` and `userGroupService.createEntity(...)`, then wired by `accessService.addFunctionToRole(...)` / `addRoleToGroup(...)` / `addGroupToUser(...)`. The `WEB_UI_*` / `MOBILE_UI_*` "roles" they grant are `UserFunction` rows (the `FunctionEnum` constants). The mapping is code-declared in `UtilRestController` — changing it requires a backend deploy, not a Keycloak admin change.

The 7 seeded `UserRole`s (`:239-245`):

| Persona (`UserRole`) | Job title | Granted functions (from `UtilRestController`) |
|---|---|---|
| `inventory-manager` (:239) | Warehouse inventory ops lead | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER`, `WEB_UI_LOG_IN`, `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW`, `WEB_UI_VIEW_REPLENISHMENT_MONITOR`, `WEB_UI_VIEW_FLOWBIN_MONITOR`, `WEB_UI_VIEW_PARCEL_MONITOR`, `WEB_UI_VIEW_DB_QUERIES` (:273-283) |
| `inventory-worker` (:240) | Floor inventory worker | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER` (:285-289) |
| `outbound-forklift` (:241) | Forklift operator | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_TRUCK_LOADING` (:291-293) |
| `outbound-manager` (:242) | Outbound ops lead | Mobile: `LOG_IN`, `INFO`, `PALLETIZING`, `PICKING`, `STOCK_TRANSFER`, `TRANSFER`, `TRUCK_LOADING`; Web: `LOG_IN`, `BILL_OF_LADING`(+`_POSITION`), `ORDER`(+`_BATCH`/`_POSITION`), `PICKING_ORDER`/`_POSITION`/`_UNIT_LOAD`, `LOCATION_OVERVIEW`, `ORDER_MONITOR`, `REPLENISHMENT_MONITOR`, `FLOWBIN_MONITOR`, `PARCEL_MONITOR`, `DB_QUERIES` (:295-316) |
| `outbound-worker` (:243) | Packing/palletizing floor | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_PALLETIZING`, `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER` (:318-323) |
| `receiving` (:244) | Inbound / receiving | Mobile: `LOG_IN`, `INFO`, `PUT_AWAY`, `REPLENISHMENT`, `STOCK_TRANSFER`, `TRANSFER`; Web: `LOG_IN`, `CREATE_INBOUND_BOL`, `GOODS_RECEIPT`(+`_POSITION`), `INBOUND_BOL`(+`_ITEM_LINES`), `RECEIVED_STOCK_OVERVIEW`, `RECEIVING`, `REPLENISHMENT_ORDER` (:325-339) |
| `super-admin` (:245) | SiteBoss / global admin | Nearly every `WEB_UI_*` and `MOBILE_UI_*` function, including all 8 `WEB_UI_ACTION_*`, all 8 admin-panel `WEB_UI_VIEW_*`, and `WEB_UI_VIEW_USER_MANAGEMENT` (:341-416) |

**Group wiring** (`:260-271`): each `UserGroup` aggregates one or more `UserRole`s — e.g. `group_inventory_manager` contains both `role_inventory_manager` and `role_inventory_worker` (:260-261); `group_outbound_manager` contains forklift+manager+worker (:264-266); `group_receiving` aggregates `inventory-worker` + `outbound-worker` + `receiving` (:268-270). The seed `admin` user is placed directly in `group_super_admin` (:255) and additionally granted `WEB_UI_VIEW_USER_MANAGEMENT` + `WEB_UI_LOG_IN` as user-level functions (:257-258).

---

## 5. Orphans

**Defined but no consumer found (as of 2026-06-24):**

The 8 admin-panel `WEB_UI_VIEW_*` (`IMPORT_DATA`, `SYSTEM_PROPERTY`, `CLIENT`, `USER`, `GROUP`, `ROLE`, `FUNCTION`, `MESSAGES`) and **all 8 `WEB_UI_ACTION_*`** are **no longer orphans** — each is now assigned to `role_super_admin` in `UtilRestController` (admin-panel views at :360-405, actions at :351-354, 413-416). The only remaining true orphans:

| Role | Likely status |
|---|---|
| `SPECIAL_DEVELOPER` (`FunctionEnum:423`) | Defined; never seeded to any persona, no consumer found. Purpose unclear |
| `MOBILE_UI_VIEW_LPN_ASSOCIATION` (`:421`) | Menu block commented out (`store/home.js:94-98`); not seeded. Reserved for future LPN flow |
| `MOBILE_UI_VIEW_CANCELLATION` (`:422`) | New; present in mobile menu (`store/home.js:89-92`) but **not seeded to any persona** in `UtilRestController` — UI-only gate, backend `getAllRoles` will never return it from the seeded data |
| `MOBILE_UI_NEVER_TIME_OUT` (`:411`) | Session-timeout override; not a view role, not in the menu, not seeded |

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

- `AdminController` endpoints `POST /v3/user/addUserToWarehouseGroup`, `POST /v3/user/removeUserFromWarehouseGroup`, `GET /v3/user/isWarehouseUser` — ⚠️ all three now have their `@PreAuthorize` commented out (§2.1)
- `KeycloakService` (service-level integration with Keycloak Admin API)
- Token parsing on the mobile UI (`tokenParsed.warehouse` claim exposes the array of facility codes the user can access — see [wms2-end-to-end-request-journey.md](./wms2-end-to-end-request-journey.md) §3)

Group paths determine *which* tenant+facility a user belongs to. Realm roles determine *what* they can do within that tenant+facility. Both must match for a request to succeed.

### 6.1 `SecurityConfiguration` path-level authority rules

The only HTTP-path-level authority enforcement lives in `SecurityConfiguration.java:116-136`. It is coarse — there are **no per-function path matchers**; everything below the actuator tier collapses to `wms_user`:

| Matcher | Authority | Source line |
|---|---|---|
| `/actuator/health/**`, `/actuator/info` | permitAll | :116 |
| `/actuator/**` | `ADMIN` or `wms_admin` | :117 |
| `/`, `/v3`, `/v3/token`, `/error`, `/rest/**`, `/api/**`, `/api-docs/**`, `/swagger-ui/**`, `/swagger-ui.html`, `/api/public/**` | permitAll | :120-124 |
| `/v3/adminAction/**`, `/v3/sysprop/**`, `/v3/systemProperty/**`, `/v3/printer/**`, `/userDetailsById/**`, `/userGroup/**`, `/user/**` | `wms_user` | :130-133 — ⚠️ the last three matchers are **root-relative** and do **not** match `/v3/user/**`; those requests fall through to the `/v3/**` rule below |
| `/v3/**` | `wms_user` | :133 |
| everything else | authenticated | :136 |

This is why the commented-out `@PreAuthorize` guards in §2.1 matter: with the annotation gone, `/v3/user/**` endpoints are reachable by any `wms_user`, not just `sb_admin`.

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
4. **Personas are DB-backed seed rows hard-coded in `UtilRestController`, not Keycloak composite roles.** They are `UserRole`/`UserGroup`/`UserFunction` rows seeded on first run (`:239-416`). A new persona — or a new function added to an existing persona — requires a code change + deploy, not a Keycloak-only operation.
5. **Group paths vs realm roles are distinct.** A user with all the right roles but no matching group membership will still fail tenant routing — and vice versa.
6. **Orphan roles are defined but unused.** Granting them to a persona is a no-op until a consumer exists. Use the table in §5 before expecting a new permission to take effect.
7. **`@PreAuthorize(Authority.IS_SB_ADMIN)` enforcement is thin, and was recently zero.** It guards **9 active** endpoints — and from 2025-10-29 to 2026-08-07 it guarded **none of them**, because the expression named a method that did not exist and threw HTTP 500 for every caller (SBDEV-2863). **Nothing in the test suite could catch that**: `BaseControllerUnitTest:50` uses `standaloneSetup`, so no controller test evaluates `@PreAuthorize` at all, and the `@SpringBootTest` lane is down (SBDEV-2217). A durable guard is tracked by **SBDEV-2872**. Separately, **5** endpoints are ungated (**SBDEV-2870**). Everywhere else enforcement is service-layer — easy to miss when refactoring, and easy to silently disable by commenting an annotation.
8. **`MOBILE_UI_NEVER_TIME_OUT` is not a view role.** Granting it changes session timeout behavior on the mobile UI only. Don't assign casually.

---

## 9. How to use this doc

| Task | Start at |
|---|---|
| Security audit (who can hit endpoint X?) | §3 find the role → §4 find the personas that grant it → the users in that persona's `UserGroup` |
| Adding a new mobile page | §3.8 reserve a `MOBILE_UI_VIEW_*` constant in `WmsConstants.FunctionEnum` → add entry in `store/home.js:setStaticMenus` → seed it to a persona in `UtilRestController` → enforce at service layer (§8 item 1) |
| Adding a new admin page | §2.1 if truly admin-only, guard with `@PreAuthorize(Authority.IS_SB_ADMIN)` on the controller (and check it isn't commented out — §2.1 gap) |
| Adding a new persona | §4 edit `UtilRestController` seed block (`:239-416`) → code deploy |
| Debugging "user can't see a page" | persona (`UserGroup`/`UserRole`) → §4 → §3 view-role → UI gate |
| Debugging "user can hit an endpoint they shouldn't" | §8 item 1 — likely service-layer check missing |
| Cleaning up orphans | §5 — audit web UI source, classify, decide keep/remove |

---

## 10. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | All constants in `WmsConstants.FunctionEnum:344-422`, `AdminController` `@PreAuthorize` usage, `UtilRestController` composite role init, `wms2-mobile-ui/store/home.js:setStaticMenus`, `Authority.java` SB_ADMIN definition | All 51 realm-role constants accounted for; 3 composite roles + 3 additional personas enumerated | Code read (grep-based across 3 repos) |
| 2026-06-24 | Full re-read of `WmsConstants.FunctionEnum:344-423`, `Authority.java`, `AdminController.java` (every `@PreAuthorize`), `UtilRestController.java:239-416` (persona seed + function bundles), `SecurityConfiguration.java:116-136`, `wms2-mobile-ui/store/home.js:setStaticMenus` | **80 constants** (66 `WEB_UI_*` :344-409, 13 `MOBILE_UI_*` :410-422, 1 `SPECIAL_*` :423) — up from 51. **7 DB-backed personas** (added `receiving`); personas are `UserRole`/`UserGroup` seed rows, **not** Keycloak composites — prior characterization corrected. The 8 admin-panel `WEB_UI_VIEW_*` + all 8 `WEB_UI_ACTION_*` are no longer orphans (seeded to `super-admin`). ⚠️ **Security gap:** 4 `AdminController` `@PreAuthorize` guards commented out (:197,261,282,310) + 1 new unguarded endpoint (:350 `/user/existsInKeycloak`) — only 8 endpoints still guarded. | Code read (executor re-verify) |

**Re-verify every 60 days.** Next due: **2026-08-23** — role churn is typically 2-4 constants per quarter; any feature that adds a new protected page invalidates this matrix.
