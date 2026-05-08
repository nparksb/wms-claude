---
type: architecture
status: active
system: wms1
last_verified: 2026-04-27
tags:
  - security
  - permissions
  - auth
  - wms1
---

# WMS v1 — FunctionEnum Permission Map

**Scope:** Every `FunctionEnum` constant in `v1/wms-api`, the DB model that stores them, how they are checked at runtime, and the default role-to-function assignments seeded at setup.

---

## 1. Two-Layer Auth Model

WMS v1 uses two independent authorization layers that must both pass before a user can perform an operation:

```
HTTP Request
    │
    ▼
┌──────────────────────────────────────────────────┐
│ Layer 1 — Keycloak JWT / Spring Security          │
│  SecurityConfiguration (WebSecurityConfigurerAdapter)         │
│  SecurityConfigurer (ResourceServerConfigurerAdapter)         │
│                                                  │
│  • Admin paths (/v3/adminAction/**, /mywmsUser/**,│
│    /import/**, /role/**, /group/**, etc.)         │
│    → requires appAdminGroup OR aim_admin group    │
│                                                  │
│  • All other /v3/** paths                        │
│    → requires appUserGroup OR appAdminGroup       │
│                                                  │
│  • /rest/** paths → unauthenticated (OMS bridge) │
└──────────────────────────────────────────────────┘
    │  passes
    ▼
┌──────────────────────────────────────────────────┐
│ Layer 2 — FunctionEnum (per-user fine-grained)   │
│  AccessService.doesUserHaveAccess(functionName)  │
│                                                  │
│  Resolves: username → groups → roles → functions │
│  via native SQL join across 5 junction tables    │
│                                                  │
│  Called inside service methods (not annotations) │
│  Throws BusinessException on denial              │
└──────────────────────────────────────────────────┘
```

Layer 1 gates HTTP access by Keycloak group membership (coarse). Layer 2 gates specific operations inside service methods by querying the WMS-internal function table (fine-grained, per-user/per-role configurable at runtime).

The two layers are independent: a user with a valid Keycloak token can reach a `/v3/` endpoint but be blocked by a FunctionEnum check inside the service. Conversely, admin-only endpoints are blocked at Layer 1 before Layer 2 is ever consulted.

---

## 2. FunctionEnum Catalog

All 76 constants are defined in `WmsConstants.FunctionEnum` (`src/main/java/net/aim_ai/wms/service/WmsConstants.java`, lines 323–407). The constant value equals the string stored in `mywms_function.name`. There is no separate integer code — the string name is the identity.

### 2.1 System / Login

| Constant | DB name (= string value) | What it enables |
|---|---|---|
| `WEB_UI_LOG_IN` | `WEB_UI_LOG_IN` | Access to the web UI (baseline for all web roles) |
| `MOBILE_UI_LOG_IN` | `MOBILE_UI_LOG_IN` | Access to the mobile UI (baseline for all mobile roles) |
| `MOBILE_UI_NEVER_TIME_OUT` | `MOBILE_UI_NEVER_TIME_OUT` | Disables mobile session timeout |
| `SPECIAL_DEVELOPER` | `SPECIAL_DEVELOPER` | Developer-only flag; assigned to dev user in seed; no backend check found |

### 2.2 Web UI — Administration

| Constant | DB name | What it enables | Checked where |
|---|---|---|---|
| `WEB_UI_VIEW_IMPORT_DATA` | `WEB_UI_VIEW_IMPORT_DATA` | Data import page | UI only |
| `WEB_UI_VIEW_SYSTEM_PROPERTY` | `WEB_UI_VIEW_SYSTEM_PROPERTY` | System properties page | UI only |
| `WEB_UI_VIEW_CLIENT` | `WEB_UI_VIEW_CLIENT` | Client management page | UI only |
| `WEB_UI_VIEW_USER` | `WEB_UI_VIEW_USER` | User list page | UI only |
| `WEB_UI_VIEW_GROUP` | `WEB_UI_VIEW_GROUP` | Group management page | UI only |
| `WEB_UI_VIEW_ROLE` | `WEB_UI_VIEW_ROLE` | Role management page | UI only |
| `WEB_UI_VIEW_FUNCTION` | `WEB_UI_VIEW_FUNCTION` | Function assignment page | UI only |
| `WEB_UI_VIEW_MESSAGES` | `WEB_UI_VIEW_MESSAGES` | System messages page | UI only |
| `WEB_UI_VIEW_USER_MANAGEMENT` | `WEB_UI_VIEW_USER_MANAGEMENT` | Combined user management hub | UI only; assigned directly to admin user |
| `WEB_UI_VIEW_DB_QUERIES` | `WEB_UI_VIEW_DB_QUERIES` | DB query explorer page | UI only |
| `WEB_UI_VIEW_SEQUENCE_NUMBER` | `WEB_UI_VIEW_SEQUENCE_NUMBER` | Sequence number page | UI only |
| `WEB_UI_VIEW_PRINTER` | `WEB_UI_VIEW_PRINTER` | Printer configuration | UI only |

### 2.3 Web UI — Location / Warehouse Config

| Constant | DB name | What it enables |
|---|---|---|
| `WEB_UI_VIEW_STORAGE_LOCATION` | `WEB_UI_VIEW_STORAGE_LOCATION` | Storage location list |
| `WEB_UI_VIEW_STORAGE_LOCATION_TYPE` | `WEB_UI_VIEW_STORAGE_LOCATION_TYPE` | Storage location type config |
| `WEB_UI_VIEW_TYPE_CAPACITY_CONSTRAINT` | `WEB_UI_VIEW_TYPE_CAPACITY_CONSTRAINT` | Capacity constraint config |
| `WEB_UI_VIEW_RACK` | `WEB_UI_VIEW_RACK` | Rack management |
| `WEB_UI_VIEW_RACK_ROW` | `WEB_UI_VIEW_RACK_ROW` | Rack row management |
| `WEB_UI_VIEW_AREA` | `WEB_UI_VIEW_AREA` | Area management |
| `WEB_UI_VIEW_SECTION` | `WEB_UI_VIEW_SECTION` | Section management |
| `WEB_UI_VIEW_CASE_TYPE` | `WEB_UI_VIEW_CASE_TYPE` | Case type configuration |
| `WEB_UI_VIEW_UNIT_LOAD_TYPE` | `WEB_UI_VIEW_UNIT_LOAD_TYPE` | Unit load type config |

### 2.4 Web UI — Item / Stock Master Data

| Constant | DB name | What it enables |
|---|---|---|
| `WEB_UI_VIEW_ITEM_DATA` | `WEB_UI_VIEW_ITEM_DATA` | Item master data |
| `WEB_UI_VIEW_FIXED_ASSIGNMENT` | `WEB_UI_VIEW_FIXED_ASSIGNMENT` | Fixed slot assignments |
| `WEB_UI_VIEW_ITEM_UNIT` | `WEB_UI_VIEW_ITEM_UNIT` | Item unit configuration |
| `WEB_UI_VIEW_STOCK_UNIT` | `WEB_UI_VIEW_STOCK_UNIT` | Stock unit list |
| `WEB_UI_VIEW_CONTAINER` | `WEB_UI_VIEW_CONTAINER` | Container list |
| `WEB_UI_VIEW_STOCK_UNIT_RECORD` | `WEB_UI_VIEW_STOCK_UNIT_RECORD` | Stock unit audit records |
| `WEB_UI_VIEW_UNIT_LOAD_RECORD` | `WEB_UI_VIEW_UNIT_LOAD_RECORD` | Unit load audit records |
| `WEB_UI_VIEW_INVENTORY_RECORD` | `WEB_UI_VIEW_INVENTORY_RECORD` | Inventory transaction records |
| `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | Lock state overview |
| `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | Received stock overview |
| `WEB_UI_VIEW_LOCATION_OVERVIEW` | `WEB_UI_VIEW_LOCATION_OVERVIEW` | Location occupancy overview |

### 2.5 Web UI — Inbound / Receiving

| Constant | DB name | What it enables |
|---|---|---|
| `WEB_UI_VIEW_CREATE_INBOUND_BOL` | `WEB_UI_VIEW_CREATE_INBOUND_BOL` | Create inbound BOL action |
| `WEB_UI_VIEW_RECEIVING` | `WEB_UI_VIEW_RECEIVING` | Receiving list page |
| `WEB_UI_VIEW_CLUB_LINE` | `WEB_UI_VIEW_CLUB_LINE` | Club line (bulk receiving) |
| `WEB_UI_VIEW_INBOUND_BOL` | `WEB_UI_VIEW_INBOUND_BOL` | Inbound BOL list |
| `WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES` | `WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES` | BOL line items |
| `WEB_UI_VIEW_GOODS_RECEIPT` | `WEB_UI_VIEW_GOODS_RECEIPT` | Goods receipt list |
| `WEB_UI_VIEW_GOODS_RECEIPT_POSITION` | `WEB_UI_VIEW_GOODS_RECEIPT_POSITION` | Goods receipt position detail |
| `WEB_UI_VIEW_STOCK_COUNT` | `WEB_UI_VIEW_STOCK_COUNT` | Stock count page |
| `WEB_UI_VIEW_CYCLECOUNT` | `WEB_UI_VIEW_CYCLECOUNT` | Cycle count list |
| `WEB_UI_VIEW_CYCLECOUNT_POSITION` | `WEB_UI_VIEW_CYCLECOUNT_POSITION` | Cycle count position detail |

### 2.6 Web UI — Outbound / Order Management

| Constant | DB name | What it enables |
|---|---|---|
| `WEB_UI_VIEW_TRANSFER_ORDER` | `WEB_UI_VIEW_TRANSFER_ORDER` | Transfer order list |
| `WEB_UI_VIEW_REPLENISHMENT_ORDER` | `WEB_UI_VIEW_REPLENISHMENT_ORDER` | Replenishment order list |
| `WEB_UI_VIEW_ORDER_BATCH` | `WEB_UI_VIEW_ORDER_BATCH` | Order batch list |
| `WEB_UI_VIEW_ORDER` | `WEB_UI_VIEW_ORDER` | Customer order list |
| `WEB_UI_VIEW_ORDER_POSITION` | `WEB_UI_VIEW_ORDER_POSITION` | Order position detail |
| `WEB_UI_VIEW_PICKING_ORDER` | `WEB_UI_VIEW_PICKING_ORDER` | Picking order list |
| `WEB_UI_VIEW_PICKING_POSITION` | `WEB_UI_VIEW_PICKING_POSITION` | Picking position detail |
| `WEB_UI_VIEW_PICKING_UNIT_LOAD` | `WEB_UI_VIEW_PICKING_UNIT_LOAD` | Picking unit load view |
| `WEB_UI_VIEW_BILL_OF_LADING` | `WEB_UI_VIEW_BILL_OF_LADING` | BOL list |
| `WEB_UI_VIEW_BILL_OF_LADING_POSITION` | `WEB_UI_VIEW_BILL_OF_LADING_POSITION` | BOL position detail |

### 2.7 Web UI — Monitors

| Constant | DB name | What it enables |
|---|---|---|
| `WEB_UI_VIEW_ORDER_MONITOR` | `WEB_UI_VIEW_ORDER_MONITOR` | Order fulfilment monitor |
| `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` | `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` | Order detail monitor |
| `WEB_UI_VIEW_REPLENISHMENT_MONITOR` | `WEB_UI_VIEW_REPLENISHMENT_MONITOR` | Replenishment monitor |
| `WEB_UI_VIEW_FLOWBIN_MONITOR` | `WEB_UI_VIEW_FLOWBIN_MONITOR` | Flow-bin monitor |
| `WEB_UI_VIEW_PARCEL_MONITOR` | `WEB_UI_VIEW_PARCEL_MONITOR` | Parcel / shipping monitor |

### 2.8 Web UI — Destructive / Adjustment Actions (backend-enforced)

These are the only constants where the backend calls `accessService.doesUserHaveAccess()` at runtime. All others are UI-gated only.

| Constant | DB name | Enforced in | Controller / endpoint |
|---|---|---|---|
| `WEB_UI_ACTION_DELETE_UNIT_LOAD` | `WEB_UI_ACTION_DELETE_UNIT_LOAD` | `UnitloadService.deleteUnitLoad()` | `UnitLoadController POST /deleteContainer`, `POST /bulkDeleteContainer` |
| `WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE` | `WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE` | `UnitloadService.deleteUnitLoadRecursive()` | `UnitLoadController GET /deleteContainerRecursive/{id}` |
| `WEB_UI_ACTION_ADJUST_AMOUNT` | `WEB_UI_ACTION_ADJUST_AMOUNT` | UI only (no backend check found) | — |
| `WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT` | `WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT` | UI only (no backend check found) | — |
| `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK` | `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK` | UI only (no backend check found) | — |
| `WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD` | `WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD` | UI only (no backend check found) | — |
| `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | `StockunitService` (line 199), `MobileMoveStockService` (lines 231, 236), `MobileMoveUnitloadService` (lines 207, 212) | Web and mobile stock/unitload move flows |
| `WEB_UI_ACTION_PRINT_TOTE_LABELS` | `WEB_UI_ACTION_PRINT_TOTE_LABELS` | UI only (no backend check found) | — |

### 2.9 Mobile UI

| Constant | DB name | What it enables |
|---|---|---|
| `MOBILE_UI_VIEW_INFO` | `MOBILE_UI_VIEW_INFO` | Info / status screen |
| `MOBILE_UI_VIEW_PUT_AWAY` | `MOBILE_UI_VIEW_PUT_AWAY` | Put-away workflow |
| `MOBILE_UI_VIEW_TRANSFER` | `MOBILE_UI_VIEW_TRANSFER` | Transfer workflow |
| `MOBILE_UI_VIEW_STOCK_TRANSFER` | `MOBILE_UI_VIEW_STOCK_TRANSFER` | Stock transfer (unit-level move) |
| `MOBILE_UI_VIEW_PICKING` | `MOBILE_UI_VIEW_PICKING` | Picking workflow |
| `MOBILE_UI_VIEW_PALLETIZING` | `MOBILE_UI_VIEW_PALLETIZING` | Palletizing / packing workflow |
| `MOBILE_UI_VIEW_TRUCK_LOADING` | `MOBILE_UI_VIEW_TRUCK_LOADING` | Truck loading workflow |
| `MOBILE_UI_VIEW_REPLENISHMENT` | `MOBILE_UI_VIEW_REPLENISHMENT` | Replenishment workflow |
| `MOBILE_UI_VIEW_CYCLE_COUNT` | `MOBILE_UI_VIEW_CYCLE_COUNT` | Cycle count workflow |
| `MOBILE_UI_VIEW_LPN_ASSOCIATION` | `MOBILE_UI_VIEW_LPN_ASSOCIATION` | LPN association workflow |

> **Note:** Mobile UI functions are enforced at the menu level in the mobile frontend only. The backend does not re-check `MOBILE_UI_VIEW_*` on API calls — a user who reaches a mobile endpoint without the menu function will not be blocked server-side.

---

## 3. How to Apply a FunctionEnum Check

### Pattern A — Service-layer guard (backend-enforced, used for destructive ops)

```java
// In a @Service method, inject AccessService
@Autowired
private AccessService accessService;

public void someDestructiveOperation(...) throws BusinessException {
    if (!accessService.doesUserHaveAccess(WmsConstants.FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)) {
        throw new BusinessException("No permission to alter damaged stock");
    }
    // ... proceed
}
```

`doesUserHaveAccess` resolves the current authenticated username from `SecurityContextUtils.getUserName()` and runs the native SQL join (see §4). Returns `true` if the user has the function via any role in any group.

### Pattern B — Controller-level pass-through (audit only, NOT a permission check)

```java
// UnitLoadController passes the FunctionEnum string as the "comment" parameter
unitloadService.deleteUnitLoad(unitLoad, WmsConstants.FunctionEnum.WEB_UI_ACTION_DELETE_UNIT_LOAD, true, principal);
```

In `UnitLoadController`, the FunctionEnum constant is passed as the `comment` argument to `deleteUnitLoad()` — it records _what_ triggered the deletion in the audit trail. **This is not a permission check.** The permission enforcement is inside `UnitloadService` itself via `doesUserHaveAccess()`.

### When to add a new check

- New destructive or sensitive operation accessible from the web UI → add a `WEB_UI_ACTION_*` constant to `WmsConstants.FunctionEnum`, call `updateFunctionList()` (or let the admin setup endpoint sync it), then guard with Pattern A in the service.
- New UI page or tab → add a `WEB_UI_VIEW_*` constant, seed it to the appropriate default roles in `UtilRestController.setupDatabase()`, enforce in the frontend only (consistent with existing VIEW constants).
- New mobile workflow screen → add a `MOBILE_UI_*` constant, seed to appropriate roles, enforce in `wms-mobile-ui` store menu filter only.

---

## 4. DB Model

### Tables

```sql
-- mywms_function: one row per FunctionEnum constant
CREATE TABLE public.mywms_function (
    id         bigint PRIMARY KEY,
    name       varchar(255),      -- matches FunctionEnum string value exactly
    number     varchar(255) NOT NULL,
    function   varchar(255) NOT NULL,
    client_id  bigint NOT NULL,
    created    timestamp,
    modified   timestamp,
    version    integer NOT NULL
);

-- mywms_role: named role (e.g. "inventory-manager", "super-admin")
-- mywms_group: named group; connector=true means it is a synthetic link group
-- mywms_user: one row per WMS user (username matches Keycloak subject)

-- Junction tables
mywms_group_mywms_user   (grouplist_id, userlist_id)    -- user ∈ group
mywms_group_mywms_role   (grouplist_id, rolelist_id)    -- role ∈ group
mywms_role_mywms_function (rolelist_id, functionlist_id) -- function ∈ role
```

### Lookup query — "does this user have function X?"

`AccessService.doesUserHaveAccess()` calls `MywmsUserRepository.getAllRoles(username)` which runs:

```sql
SELECT DISTINCT f.name
FROM mywms_user u
JOIN mywms_group_mywms_user  gu ON u.id = gu.userlist_id
JOIN mywms_group_mywms_role  gr ON gr.grouplist_id = gu.grouplist_id
JOIN mywms_role_mywms_function rf ON rf.rolelist_id = gr.rolelist_id
JOIN mywms_function f ON rf.functionlist_id = f.id
WHERE u.name = :username
```

This returns all function names reachable from the user via any group/role path. The caller checks `functions.contains(functionName)`.

### Sync from code to DB

`AccessService.updateFunctionList()` reflects new `FunctionEnum` constants into the DB. It iterates `WmsConstants.FunctionEnum.class.getFields()` via reflection and calls `FunctionService.createEntity(value)` for any name not yet in `mywms_function`. This is called by the admin setup endpoints; it does not auto-run at startup.

### Assigning functions to users

Functions are never assigned directly to users in the data model. The path is always:

```
MywmsUser → MywmsGroup (connector=true) → MywmsRole (connector=true) → MywmsFunction
```

`AccessService.addFunctionToUser()` creates a synthetic group and role (`connector=true`) as a bridge when assigning a function directly to a user.

---

## 5. Admin Bypass — Which Roles Skip FunctionEnum Checks

**There is no code-level bypass of `doesUserHaveAccess()` for admin roles.** The Keycloak `aim_admin` group grants access to admin HTTP paths (Layer 1), but that does not automatically grant all FunctionEnum permissions (Layer 2).

In practice, admin users are seeded with specific functions at setup time by `UtilRestController.setupDatabase()`:

```java
// Admin user gets these two functions directly:
accessService.addFunctionToUser(WEB_UI_VIEW_USER_MANAGEMENT, admin.getId());
accessService.addFunctionToUser(WEB_UI_LOG_IN, admin.getId());
```

The `super-admin` WMS role holds all FunctionEnum constants. A user assigned to `super-admin` effectively bypasses FunctionEnum checks by having every function. See the default role-function matrix below.

### Default role-to-function seed matrix

Source: `UtilRestController.setupDatabase()` — this seeds a fresh installation. Production DBs may diverge.

| WMS Role | Functions granted |
|---|---|
| `inventory-manager` | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER`, `WEB_UI_LOG_IN`, `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW`, `WEB_UI_VIEW_REPLENISHMENT_MONITOR`, `WEB_UI_VIEW_FLOWBIN_MONITOR`, `WEB_UI_VIEW_PARCEL_MONITOR`, `WEB_UI_VIEW_DB_QUERIES` |
| `inventory-worker` | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER` |
| `outbound-forklift` | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_TRUCK_LOADING` |
| `outbound-manager` | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_PALLETIZING`, `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER`, `MOBILE_UI_VIEW_TRUCK_LOADING`, `WEB_UI_LOG_IN`, `WEB_UI_VIEW_BILL_OF_LADING`, `WEB_UI_VIEW_BILL_OF_LADING_POSITION`, `WEB_UI_VIEW_ORDER`, `WEB_UI_VIEW_ORDER_BATCH`, `WEB_UI_VIEW_ORDER_POSITION`, `WEB_UI_VIEW_PICKING_ORDER`, `WEB_UI_VIEW_PICKING_POSITION`, `WEB_UI_VIEW_PICKING_UNIT_LOAD`, `WEB_UI_VIEW_LOCATION_OVERVIEW`, `WEB_UI_VIEW_ORDER_MONITOR`, `WEB_UI_VIEW_REPLENISHMENT_MONITOR`, `WEB_UI_VIEW_FLOWBIN_MONITOR`, `WEB_UI_VIEW_PARCEL_MONITOR`, `WEB_UI_VIEW_DB_QUERIES` |
| `outbound-worker` | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_PALLETIZING`, `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER` |
| `receiving` | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_PUT_AWAY`, `MOBILE_UI_VIEW_REPLENISHMENT`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER`, `WEB_UI_LOG_IN`, `WEB_UI_VIEW_CREATE_INBOUND_BOL`, `WEB_UI_VIEW_GOODS_RECEIPT`, `WEB_UI_VIEW_GOODS_RECEIPT_POSITION`, `WEB_UI_VIEW_INBOUND_BOL`, `WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES`, `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW`, `WEB_UI_VIEW_RECEIVING`, `WEB_UI_VIEW_REPLENISHMENT_ORDER` |
| `super-admin` | All FunctionEnum constants (every `WEB_UI_*`, `MOBILE_UI_*`, and `WEB_UI_ACTION_*`) |

### Group membership at seed time

| WMS Group | Roles it contains |
|---|---|
| `group_inventory_manager` | `inventory-manager`, `inventory-worker` |
| `group_inventory_worker` | `inventory-worker` |
| `group_outbound_forklift` | `outbound-forklift`, `outbound-manager` |
| `group_outbound_manager` | `outbound-forklift`, `outbound-manager`, `outbound-worker` |
| `group_outbound_worker` | `outbound-worker` |
| `group_receiving` | `inventory-worker`, `outbound-worker`, `receiving` |
| `group_super_admin` | `super-admin` |

---

## 6. v1 vs v2: FunctionEnum Comparison

| Aspect | v1 (wms-api) | v2 (wms2-api) |
|---|---|---|
| Constants file | `WmsConstants.FunctionEnum` in `service/` package | `WmsConstants.FunctionEnum` in `service/` package (identical structure) |
| Number of constants | 76 | ~51 (see `wms2-keycloak-role-matrix.md` §2) |
| Storage model | Internal DB tables (`mywms_function`, junction tables) | Same internal DB tables — same schema |
| Check mechanism | `AccessService.doesUserHaveAccess()` → native SQL join | Same `AccessService.doesUserHaveAccess()` pattern |
| Enforcement layer | Mostly UI-side for VIEW constants; backend service for ACTION constants | Same pattern (UI-side VIEW, backend-service ACTION) |
| Admin bypass | No code bypass; `super-admin` role holds all functions | Same — `sb_admin` Keycloak role gates admin HTTP paths; `super-admin` WMS role holds all functions |
| Mobile enforcement | UI menu filter only; backend does not re-check | Same — backend does not re-enforce mobile view functions |
| Notable difference | v1 has 76 constants including `WEB_UI_VIEW_CLUB_LINE`, `WEB_UI_VIEW_CONTAINER`, `WEB_UI_VIEW_TRANSFER_ORDER`, `WEB_UI_VIEW_CLIENT`, `WEB_UI_VIEW_CYCLECOUNT`, `WEB_UI_VIEW_CYCLECOUNT_POSITION`, `WEB_UI_VIEW_STOCK_COUNT`, `WEB_UI_VIEW_SEQUENCE_NUMBER` which are absent or renamed in v2 | v2 adds `WEB_UI_VIEW_CLUB_PACKING` and renames some constants per feature changes |
| Keycloak integration | Keycloak roles = Keycloak group memberships only; FunctionEnum lives entirely in WMS DB | Same — Keycloak is Layer 1 only; FunctionEnum is WMS-internal |

**Key point for v1→v2 migrations:** The `FunctionEnum` constant names and the `doesUserHaveAccess()` pattern are the same in both versions. The DB schema is identical. The difference is that v2 dropped some v1-specific constants (`WEB_UI_VIEW_CLUB_LINE`, `WEB_UI_VIEW_CONTAINER`, `WEB_UI_VIEW_SEQUENCE_NUMBER`, `WEB_UI_VIEW_STOCK_COUNT`) and uses `sb_admin` instead of `aim_admin` as the super-admin Keycloak role name. Consult `wms2-keycloak-role-matrix.md` for the full v2 constant list.

---

## Related Documents

- `wms2-keycloak-role-matrix.md` — v2 role-level access (role constants, Keycloak group paths)
- `wms1-end-to-end-request-journey.md` — full HTTP request path including security filter chain
- `wms1-java-package-analysis.md` — package ownership of `Authority`, `SecurityConfigurer`, `AccessService`
- `wms1-transaction-boundary-map.md` — transactionality of service methods that call `doesUserHaveAccess`
