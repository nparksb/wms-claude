---
title: "WMS v2 — Domain Glossary"
type: data-dictionary
status: active
version: v2
scope: domain-vocabulary
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-08
verified_by: code read + existing architecture docs in v2/wms2-api
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-tenant-routing-datasource-topology.md
  - ./wms2-landlord-vs-tenant-entity-map.md
  - ./wms2-sysprop-catalog.md
tags:
  - data-dictionary
  - glossary
  - vocabulary
  - wms2
---

# WMS v2 — Domain Glossary

**Scope:** Warehouse and platform vocabulary used across `v2/wms2-api`, the mobile UI, and integrations · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

Most WMS bugs that escalate aren't caused by missing code — they're caused by two engineers meaning different things when they say "tote" or "unitload" or "facility". This glossary pins every ambiguous term to its canonical meaning + the code that realizes it. When the definition differs from how the word is used in general logistics, that's called out.

For state values (`RAW`, `PICKED`, `CANCELED` etc.) see [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md). For sysprop keys (`MERGE_PICKING_ORDERS`, `PICK_SCREEN_SIMPLE` etc.) see [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md). For entity class names see [wms2-landlord-vs-tenant-entity-map.md](./wms2-landlord-vs-tenant-entity-map.md).

---

## 2. Physical objects

### unit load
The generic term for "one physical thing that can be moved as a single piece of inventory." Implemented by entity `Unitload` (tenant DB). A unit load has a `UnitloadType` (e.g. pallet, tote, carton) and carries 1..N `Stockunit` rows — the actual amounts of each item it contains. **Has no state field** (see state-machine catalog §4.11); lifecycle is inferred from the state of its parent `PickingorderUnitload` or the pick order it belongs to.

### tote
A specific `UnitloadType` — a plastic picking container. Barcode pattern: `T-\d{4}` (sysprop `STRING_PATTERN_PICKING_TOTE`). Functionally: a unit load whose role is to hold items during the picking phase before they move to pallet / box. A "picking tote" has a ZPL label template separate from the generic tote label (`PRINTING_ZPL_PICKING_TOTE_LABEL`).

### pallet
Another `UnitloadType`. Inbound pallet barcode: `CART-\d{4}|IN-\d{6}`. Outbound pallet barcode: `OUT-\d{6}`. Outbound pallets have their own sequence (`PALLET_OUTBOUND` default) and pattern (`OUT-%1$06d`). **"Cart" in the inbound regex is a pallet-ish inbound container, not a picking cart.**

### cart (picking cart)
A physical rolling device that carries multiple totes during a pick wave. Capacity capped by sysprop `PICKING_BOX_PER_CART` (default 6). Used by the `TOTES_ON_CART` picking type. Not an entity — carts are implicit via the groupings created during `mergePickingOrders` in `ReplenishOrderJob`.

### case / box
A `Boxtype`-backed shipping carton. Sysprop `DEFAULT_BOX_TYPE` picks the default (`UL_TYPE_BOX_NAME_14`). A "case label" (ZPL template `PRINTING_ZPL_CASE_LABEL`) is printed during packing.

### parcel
A small single-box shipment. Barcode pattern `P-\d{4}` (sysprop `STRING_PATTERN_PICKING_PARCEL`). Tracked as a unit load and surfaced via `ParcelMonitorView`.

### stockunit
A row in the `stockunit` table representing "item X has amount Y at this location, of which Z is reserved." Has `amount` + `reservedamount`. **No state field.** Do not confuse with the barcode prefix `SU-\d{6}` (`STRING_PATTERN_SEPARATE_STOCK`) — that pattern is used to identify a physically separated stock unit carrier, not the row itself.

### stockrecord
An audit/ledger entry for stock movements (26 fields). Written whenever a `Stockunit` amount changes — creates vs deletes vs transfers. Do not query for current stock; use `Stockunit` or `StockView` instead.

---

## 3. Warehouse structure

### facility
The physical warehouse building. Identified by `facility_code` (a 2-character short code — e.g., `CA`, `TX`). Combined with `tenant_name` to form the 4-char routing key. **A single WMS instance serves one tenant at a time per request**, but one tenant can have multiple facilities (each with its own DB).

### warehouse
Informal synonym for "facility." The sysprop `WAREHOUSE_NAME` stores the human-readable label ("CA Warehouse #1"), distinct from `facility_code` which is the routing identifier. The `WAREHOUSE_TIME_ZONE_KEY` sysprop (key literal: `"System Time Zone"`) holds the facility's local TZ.

### section
A logical grouping of locations driven by `pickingtype`. Primary values:
- `TOTES_ON_CART` — operators push a cart loaded with totes, picking into them as they walk the section.
- `RAPID_PICKING` — high-throughput single-tote zone; the `ReleaseExpiredPickingOrdersFromUserJob` only fires on this picking type.

### location
A physical pick slot — one row in `location`. Has a `LocationType`, belongs to an `Area`, sits on a `Rack` / `Rack Row`. `LocationConstraint` rows attach business rules (e.g. "only SKU class X" / "temperature controlled").

### fix location assignment (fixlocation)
A binding: "item X always goes at location Y." Stored in `fix_location_assignment`. Central to replenishment — `ReplenishOrderJob` uses these to know where stock should be refilled to. Fill thresholds come from sysprops:
- `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND` (default 36%) — trigger replenish
- `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND` (60%) — midpoint
- `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` (84%) — full

### flowbin
A specific fix-location pattern used in flow-through pick zones. Surfaced via `FlowbinMonitorView`. Treat as a special case of a fix-location assignment; the UI separates them because flowbin refills have tighter constraints (typically gravity-fed, FIFO).

### staging lane
A designated location where a `CustomerorderBatch` (club run, typically) is staged during the pre-load phase. Set via `ORDER_BATCH_STAGING_LANE_ASSIGNED` state transition. **Not its own entity** — staging lanes are modeled as `Location` rows with a specific `LocationType`.

### truck lane
Where a loaded pallet is queued for truck loading. Surfaced in the BOL flow; not its own entity either.

---

## 4. Logical entities / business flows

### advice (ASN)
An "Advance Ship Notice" — a supplier's declaration of what's arriving. Entity `Advice` + line entity `Adviceposition`. Lifecycle: `CREATED → OPEN → PROCESSING → CLOSED → FINISHED` (or `CANCELLED`). Note **String-typed state**: spelled `CANCELLED` with two L's (vs the Integer-typed entities' `CANCELED`). The `WEBSERVICE_CLOSE_ADVICE` callback fires to OMS when an advice closes.

### goods receipt
The actual physical receiving event. `Goodsreceipt` header + `Goodsreceiptposition` lines record what was unloaded from a shipment — distinct from the advice (what was *promised*). One advice → 0..N goods receipts.

### customer order
The order we are fulfilling. Entity `Customerorder` — 38 fields, Integer `state`, the most-referenced entity in the codebase. Every state-machine landmine pivot point tends to be a Customerorder cascade (see state-machine catalog §5).

### customer order batch
A batched set of orders that go through the pick flow together. Primary use case: **club run** (see below). Lifecycle with states `ORDER_BATCH_ACTIVATED → ORDER_BATCH_STAGING_LANE_ASSIGNED → ORDER_BATCH_CLUB_RUN_IN_PROGRESS → ORDER_BATCH_CLUB_RUN_FINISHED`. Entity: `CustomerorderBatch`.

### picking order
The work package handed to an operator. Distinct from the customer order: one customer order can be split across multiple picking orders, and one picking order can fulfill multiple customer orders. Entity `Pickingorder` + `PickingorderPosition` (line) + `PickingorderUnitload` (the unit load being filled). The `MERGE_PICKING_ORDERS` sysprop controls whether `ReplenishOrderJob` auto-merges pickable sets.

### replenish order
An instruction to move stock from reserve storage to a pick face. Entity `Replenishorder`. Generated by `ReplenishOrderJob` when fix-location fill % drops below the lower bound. States: `RAW → PROCESSABLE → STARTED → FINISHED` or `CANCELED`.

### bill of lading (BOL)
The manifest that accompanies an outbound truck. Entity `Billoflading` + `BillofladingPosition`. String-typed state: `CREATED → OPEN → TRUCK_LOADING → TRANSFER → CLOSED` or `CANCELLED`. `TRANSFER` applies to hub-and-spoke / multi-WH movement.

### club run / club order
A recurring subscription-style order batch, typically for wine-of-the-month / food-of-the-month customers. A "club run" is one execution of a wave: activate batch → assign staging lane → confirm club orders → finish. Triggers notifications at `CLUB_RUN_IN_PROGRESS` and `CLUB_RUN_FINISHED`. Several archived bug fixes target this flow (`Cancel_Club_Parcels_Packed_State_Fix`, `Club_Order_Cancellation_*`).

### cycle count
Periodic inventory audit. Entity `Cyclecount` + `CyclecountPosition`. String-typed state: `CREATED → STARTED → FINISHED` or `CANCELLED`. Sysprops control UI behavior — `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT`, `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT`.

### transfer order
Movement between facilities. Has its own customer-order state track (`CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`, `CUSTOMER_ORDER_ACTIVATED`). Distinct from intra-facility move stock.

### hub and spoke
A multi-WH pattern where one central hub feeds satellite spokes. Realized via the `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` OMS callback and the `TRANSFER` BOL state. Not a deep feature in v2 yet — minimal wiring.

---

## 5. Picking types and strategies

### TOTES_ON_CART
Picking strategy where operators push a cart with multiple totes. Merge-able; one operator fills many orders in one pass. Controlled by `MERGE_PICKING_ORDERS` + `PICKING_BOX_PER_CART`.

### RAPID_PICKING
Single-tote high-throughput zone. Subject to pick-timeout release via `ReleaseExpiredPickingOrdersFromUserJob` (default 40 s).

### rapid picking path (customer order)
Distinct from `RAPID_PICKING` picking type — refers to a customer-order branch in `CustomerorderService.handleRapidPickingForCancelledOrder` (state machine catalog §5.1). If a cancelled order had already been rapid-picked into a tote, the code bounces the pick order back to `PROCESSABLE` instead of cancelling, so the tote's contents can be redistributed. Don't simplify the `historytote != null` branch without reading that cascade in full.

### simple pick screen
UI variant for operators gated by `PICK_SCREEN_SIMPLE` sysprop. Hides advanced controls; used for new/temp workers.

---

## 6. Platform concepts

### landlord
The master PostgreSQL DB that knows "which tenants exist and how to connect to each." Contains 4 entities (see landlord-vs-tenant map §2). Never holds business data.

### tenant
A physical PostgreSQL DB holding one tenant-facility's business data. Implemented as one DB per `(tenant_name, facility_code)` pair. 62 entities. Multi-tenant routing via `hibernate.multiTenancy=DATABASE`.

### tenant_name
The tenant identifier, passed in the `X-Tenant-ID` HTTP header. Lowercased before use. Only the first 4 characters contribute to the routing key.

### facility_code
The facility identifier, passed in the `facility_code` HTTP header. Lowercased before use. Full value used in routing key.

### tenant key / routing key
The 4-character string `first4(tenantName) + "-" + facilityCode`. Built by `TenantKeyBuilder.buildKey(...)`. Used both for `HikariDataSource` lookup and for Hibernate's `CurrentTenantIdentifierResolver`. Example: tenant `wineco` + facility `cawh` → key `wine-cawh`.

### TenantContext
ThreadLocal holder for the active `TenantProfile`. Set by `TenantFilter` per HTTP request, cleared in `finally`. Does **not** propagate across threads — see [wms2-tenant-routing-datasource-topology.md](../architecture/wms2-tenant-routing-datasource-topology.md) §10 item 1.

### BOOTSTRAP
A literal string returned by `TenantIdentifierResolver` when no tenant context exists. Hibernate uses this as the tenant identifier for startup-time and context-less queries. Never hit this in a request path — if you do, it's a bug.

### sysprop
A tenant-scoped configuration key/value row in the `los_sysprop` table. Read via `SyspropService`. See [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md). **Not** a landlord concept — each tenant has its own row set.

### OSIV
"Open Session In View." Disabled (`spring.jpa.open-in-view=false`). Any lazy association must be resolved inside the `@Transactional` boundary, not at the view/controller layer.

### advisory lock
A PostgreSQL session-level lock used for cross-replica cron-job mutual exclusion. IDs are fixed constants in `AdvisoryLockService.JobLockId`. Will break under PgBouncer `pool_mode=transaction` — see [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §7 item 1.

### REQUIRES_NEW
`@Transactional(propagation = REQUIRES_NEW)`. Creates an isolated inner transaction that commits independently of the outer one. Used ~17 times, almost all inside scheduled jobs to let one step fail without aborting the whole iteration.

---

## 7. Integrations

### OMS (Order Management System)
The upstream/downstream system that owns customer/order data. WMS receives orders from OMS and fires callbacks back as they progress. All OMS endpoints are sysprops under `WEBSERVICE_*` (see [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md) §5). `SYSTEM_OMS_NAME` / `OMS_INSTANCE_NAME` identify the paired OMS instance; `OMS_TENANT_ID` maps WMS tenants to OMS tenants.

### Keycloak
OpenID Connect / OAuth2 identity provider. Per-tenant config in `TenantAuthConfiguration` (landlord). WMS validates JWTs via `MultiTenantJwtDecoder`. Realm, client, and admin service-account config are sysprops under `KEYCLOAK_*`.

### CUPS
Linux print-server protocol (Common Unix Printing System). Label printing goes through a CUPS server (address in `CUPS_SERVER_ADDRESS_IP`). Legacy dependency flagged for removal in `CUPS_DEPENDENCY_REMOVAL_PLAN`.

### ZPL
Zebra Programming Language — the label-template format. ZPL templates are stored as sysprop values; there are separate templates for case, tote, outbound-pallet labels (see [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md) §7).

### PSD
Appears as `WEBSERVICE_TEST_CRM_CONNECTIVITY` → `.../services/call/testPsd`. A CRM-style OMS test endpoint. Scope is narrow — only used for connectivity smoke-tests.

---

## 8. People & roles

### operator
A warehouse worker using the mobile UI. Logs in via Keycloak; role assignments flow through `MOBILE_UI_VIEW_*` Keycloak realm roles (e.g. `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_VIEW_PUT_AWAY`). Each mobile workflow page gates on a matching role — see `v2/wms2-mobile-ui/store/home.js`.

### locked_to_operator
Column on `pickingorder` — when an operator claims a picking order, this is set true and `operator_id` is populated. The `ReleaseExpiredPickingOrdersFromUserJob` watches this: if the order stays locked for longer than `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` seconds, it clears the lock so another operator can claim it.

### WMS_INSTANCE_NAME / OMS_INSTANCE_NAME
Human-readable labels for this environment (e.g. `prod-ca`, `dev-tx`). Used in message envelopes and audit trails — not functional for routing.

---

## 9. Spelling / naming gotchas

| Surface form | What to know |
|---|---|
| **`CANCELED`** (one L) | Integer state — only applies to `Customerorder`, `CustomerorderBatch`, `Pickingorder`, `PickingorderPosition`, `PickingorderUnitload`, `Replenishorder` |
| **`CANCELLED`** (two L's) | String state — only applies to `Advice`, `Adviceposition`, `Billoflading`, `BillofladingPosition`, `Cyclecount`, `CyclecountPosition` |
| **`EMTPY`** (typo preserved in code) | Sysprop key `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY`. Do not "fix" it — the DB row uses this spelling. |
| **`mywms_*`** table prefix | Legacy naming on user/role/group/function tables only. Don't generalize. |
| **`los_*`** table prefix | Legacy naming on `los_sysprop` and `los_sequencenumber` only. |
| **CART-####** | Inbound pallet pattern — **not** a picking cart. |

---

## 10. How to use this doc

| Task | Start at |
|---|---|
| First time reading a WMS service method | Skim §2 + §4 to ground the vocabulary |
| Writing a plan that uses domain terms | Reference this doc by section in the plan's "Scope" block so reviewers share the same definitions |
| Onboarding a new engineer | §2, §3, §4 cover 90% of the terms they'll hit in code review |
| Seeing "CANCELLED" in a log and wondering why the guard didn't fire | §9 first, then state-machine catalog §7 item 2 |

---

## 11. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | Every term cross-referenced against its realizing entity / sysprop / regex / state constant; legacy naming (`mywms_`, `los_`, `EMTPY`) confirmed against `v2/wms2-api/src/main/java` | All terms grounded in code | Code read + existing architecture + data-dictionary docs |

**Re-verify every 120 days.** Next due: **2026-08-17** — vocabulary changes slowly, but any new subsystem (e.g. new carrier integration, new automation type) typically introduces 2–4 new terms worth appending.
