---
title: "WMS v2 — Domain Glossary"
type: data-dictionary
status: active
version: v2
scope: domain-vocabulary
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: 2026-11-11 term-by-term re-verification against wms2-api origin/develop @ df30fa62 (WmsConstants, model/, schedulejob/, landlord/config/) + the 2026-11-11 re-verified state-machine, sysprop and workflow docs
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
**Owner:** Nam Park · **Last verified:** 2026-11-11

---

## 1. Overview

Most WMS bugs that escalate aren't caused by missing code — they're caused by two engineers meaning different things when they say "tote" or "unitload" or "facility". This glossary pins every ambiguous term to its canonical meaning + the code that realizes it. When the definition differs from how the word is used in general logistics, that's called out.

For state values (`RAW`, `PICKED`, `CANCELED` etc.) see [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md). For sysprop keys (`MERGE_PICKING_ORDERS`, `PICK_SCREEN_SIMPLE` etc.) see [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md). For entity class names see [wms2-landlord-vs-tenant-entity-map.md](./wms2-landlord-vs-tenant-entity-map.md).

---

## 2. Physical objects

### unit load
The generic term for "one physical thing that can be moved as a single piece of inventory." Implemented by entity `Unitload` (tenant DB). A unit load has a `UnitloadType` (e.g. pallet, tote, carton) and carries 1..N `Stockunit` rows — the actual amounts of each item it contains. **Has no state field** (see state-machine catalog §4.11); lifecycle is inferred from the state of its parent `PickingorderUnitload` or the pick order it belongs to.

### tote
A specific `UnitloadType` — a plastic picking container. Barcode pattern: `T-\d{4}` (sysprop `STRING_PATTERN_PICKING_TOTE`; constant default `WmsConstants.java:1392`, but an absent row reads `null` — no code fallback, sysprop catalog §1a). Functionally: a unit load whose role is to hold items during the picking phase before they move to pallet / box. A "picking tote" has a ZPL label template separate from the generic tote label (`PRINTING_ZPL_PICKING_TOTE_LABEL`).

### pallet
Another `UnitloadType`. Inbound pallet barcode: `CART-\d{4}|IN-\d{6}`. Outbound pallet barcode: `OUT-\d{6}`. Outbound pallets have their own sequence (`PALLET_OUTBOUND` default, seeded in `V2.2.00__base_v2_schema.sql`) and label format (`OUT-%1$06d`, `SYSTEM_PROPERTY_PRINTING_PATTERN_OUTBOUND_PALLET_LABEL_DEFAULT_VALUE`, `WmsConstants.java:1345`). **"Cart" in the inbound regex is a pallet-ish inbound container, not a picking cart.**

### cart (picking cart)
A physical rolling device that carries multiple totes during a pick wave. Capacity capped by sysprop `PICKING_BOX_PER_CART` (default 6). Used by the `TOTES_ON_CART` picking type. Not an entity — carts are implicit via the groupings created by `PickingOrderMergeService.mergePickingOrders`, driven from `ReplenishOrderJob.mergePickingOrders` (`:557`) and `ReleaseOrderJobService` (`:843`); the merge pass runs only when `MERGE_PICKING_ORDERS` is `true` (absent row = off).

### case / box
A `Boxtype`-backed shipping carton. Sysprop `DEFAULT_BOX_TYPE` picks the default (code default is the constant `UL_TYPE_BOX_NAME_14`, whose value is `"COLLTRL"`, `WmsConstants.java:1085,1663`). A "case label" (ZPL template `PRINTING_ZPL_CASE_LABEL`) is printed during packing.

### parcel
A small single-box shipment. Barcode pattern `P-\d{4}` (sysprop `STRING_PATTERN_PICKING_PARCEL`). Tracked as a unit load (palletise code refers to `UL(parcel P)`) and surfaced via `ParcelMonitorView` (`parcel_monitor_view`).

### stockunit
A row in the `stockunit` table representing "item X has amount Y at this location, of which Z is reserved." Has `amount` + `reservedamount`. **No state field.** Do not confuse with the barcode prefix `SU-\d{6}` (`STRING_PATTERN_SEPARATE_STOCK`) — that pattern is used to identify a physically separated stock unit carrier, not the row itself.

### stockrecord
An audit/ledger entry for stock movements (20 declared fields + 4 inherited from `AbstractBaseEntity`). Written whenever a `Stockunit` amount changes — creates vs deletes vs transfers. Do not query for current stock; use `Stockunit` or `StockView` instead.

---

## 3. Warehouse structure

### facility
The physical warehouse building. Identified by `facility_code` (a short code with no length rule in code — e.g. `wh01`, `nywh`, `develop`; lowercased by `TenantFilter`). Combined with `tenant_name` to form the routing key `first4(tenant)-facility_code`. **A single WMS instance serves one tenant at a time per request**, but one tenant can have multiple facilities (each with its own DB).

### warehouse
Informal synonym for "facility." The sysprop `WAREHOUSE_NAME` stores the human-readable label ("CA Warehouse #1"), distinct from `facility_code` which is the routing identifier. The sysprop whose key literal is `"System Time Zone"` (Java constant `SYSTEM_PROPERTY_WAREHOUSE_TIME_ZONE_KEY`, `WmsConstants.java:1193`; there is no sysprop *named* `WAREHOUSE_TIME_ZONE_KEY`) holds the facility's local TZ.

### section
A logical grouping of locations driven by `sectionpickingtype` (`WmsConstants.SectionPickingType`, exactly two values):
- `TOTES_ON_CART` — operators push a cart loaded with totes, picking into them as they walk the section.
- `RAPID_PICKING` — high-throughput single-tote zone; `ReleaseExpiredPickingOrdersFromUserJob` only selects orders in sections of this picking type.

### location
A physical pick slot — one row in `location`. Has a `LocationType`, belongs to a `LocationArea`, sits on a `LocationRack` / `LocationRackRow`. `LocationConstraint` rows pair a storage-location type with a unit-load type (`storagelocationtypeId` + `unitloadtypeId`) — i.e. which unit-load types a location type accepts; they carry no SKU-class or temperature rule. Boolean flags on `Location` mark special roles: `staginglane`, `transferlane`, `automationlane`, `crossdockinglane`, `gate`.

### fix location assignment (fixlocation)
A binding: "item X always goes at location Y." Stored in `fix_location_assignment`. Central to replenishment — `ReplenishOrderJob` uses these to know where stock should be refilled to. Entity `FixLocationAssignment` (`lowerbound` / `middlebound` / `upperbound`, absolute quantities). Seed thresholds come from sysprops (code defaults `WmsConstants.java:1380-1384`):
- `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND` (default 36) — Min Amount, an absolute quantity, not a %; an FLA below it is refill-eligible
- `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND` (60) — Hysteresis, absolute quantity
- `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` (84) — Max Amount, absolute quantity; the refill target. ✓ merged(SBDEV-3128: #601 4643acf5, 2026-11-02): a location can carry its own default triple that seeds a new FLA before these sysprops

### flowbin
A specific fix-location pattern used in flow-through pick zones. Surfaced via `FlowbinMonitorView`. Treat as a special case of a fix-location assignment; the UI separates them because flowbin refills have tighter constraints (typically gravity-fed, FIFO — ⚠ unverified 2026-11-11: no code or doc states gravity-fed/FIFO for v2; the only code-visible constraint is the capacity cap, `ReplenishOrderJob.cancelReplenishmentIfFlowbinIsFull`).

### staging lane
A designated location where a `CustomerorderBatch` (club run, typically) is staged during the pre-load phase. Set via the `ORDER_BATCH_STAGING_LANE_ASSIGNED` state transition (`CustomerorderBatchService.assignStagingLane`). **Not its own entity** — a staging lane is a `Location` row with `staginglane = true` (`LocationRepository.getAvailableStagingLanes` filters on that flag, not on `LocationType`). The step is optional for the club run: run start accepts `ORDER_BATCH_ACTIVATED` or `ORDER_BATCH_STAGING_LANE_ASSIGNED` (state-machine catalog §4).

### truck lane
Not a code term in v2 (no `trucklane` symbol). Truck loading is done against a **gate**: a `Location` row with `gate = true`, scanned via `scanGate` (`TruckLoadingController` → `MobileTruckLoadingWriteService.scanGate`). Transfer shipments use a separate `transferlane` flag. Neither is its own entity.

---

## 4. Logical entities / business flows

### advice (ASN)
An "Advance Ship Notice" — a supplier's declaration of what's arriving. Entity `Advice` + line entity `Adviceposition`. Lifecycle values (`WmsConstants.AdviceState`): `CREATED → OPEN → PROCESSING → CLOSED → FINISHED` (or `CANCELLED`). ⚠ Only `CREATED`, `OPEN` and `FINISHED` are ever *written* in `src/main`; `PROCESSING`, `CLOSED` and `CANCELLED` exist as constants and in guards but have no writer (state-machine catalog §4). Note **String-typed state**: spelled `CANCELLED` with two L's (vs the Integer-typed entities' `CANCELED`). The `WEBSERVICE_CLOSE_ADVICE` sysprop (default URL `.../services/call/closeAdvice`) is the OMS callback for an advice close; message type `ADVICE_CLOSE`.

### goods receipt
The actual physical receiving event. `Goodsreceipt` header + `Goodsreceiptposition` lines record what was unloaded from a shipment — distinct from the advice (what was *promised*). One advice → 0..N goods receipts.

### customer order
The order we are fulfilling. Entity `Customerorder` — 28 declared fields + 4 inherited from `AbstractBaseEntity`, Integer `state`, the most-referenced entity in the codebase. Every state-machine landmine pivot point tends to be a Customerorder cascade (see state-machine catalog §5).

### customer order batch
A batched set of orders that go through the pick flow together. Primary use case: **club run** (see below). Integer states (`WmsConstants.State`): `RAW(0)`, `STARTED(500)`, `ORDER_BATCH_ACTIVATED(520)`, `ORDER_BATCH_STAGING_LANE_ASSIGNED(525, optional)`, `ORDER_BATCH_CLUB_RUN_IN_PROGRESS(527)`, `ORDER_BATCH_CLUB_RUN_FINISHED(530)`, `FINISHED`, `CANCELED`. Entity: `CustomerorderBatch`.

### picking order
The work package handed to an operator. Distinct from the customer order: one customer order can be split across multiple picking orders, and one picking order can fulfill multiple customer orders. Entity `Pickingorder` + `PickingorderPosition` (line) + `PickingorderUnitload` (the unit load being filled). The `MERGE_PICKING_ORDERS` sysprop controls whether `ReplenishOrderJob` (and `ReleaseOrderJobService`) auto-merges pickable sets (absent row = off).

### replenish order
An instruction to move stock from reserve storage to a pick face. Entity `Replenishorder`. Generated by `ReplenishOrderJob` (via `ReplenishGeneratorService`) when the stock quantity at a fix location drops below its `lowerbound` (Min Amount — an absolute quantity, not a fill %). States: `RAW → PROCESSABLE → STARTED → FINISHED` or `CANCELED`; a `STARTED` claim not stamped for `REPLENISHMENT_CLAIM_TIMEOUT_SECONDS` returns to `PROCESSABLE`.

### bill of lading (BOL)
The manifest that accompanies an outbound truck. Entity `Billoflading` + `BillofladingPosition`. String-typed state: `CREATED → OPEN → TRUCK_LOADING → TRANSFER → CLOSED` or `CANCELLED`. `TRANSFER` is written only for `TRANSFER_INTRACOMPANY` BOLs at `closeBOL`; `finishTransfer` later rewrites it to `CLOSED`. `HUB_AND_SPOKE` BOLs close straight to `CLOSED`. ⚠ `CANCELLED` is checked in guards but has no Java writer (state-machine catalog §4).

### club run / club order
A recurring subscription-style order batch, typically for wine-of-the-month / food-of-the-month customers. A "club run" is one execution of a wave: activate batch → (optionally) assign staging lane → `validateClubLine` (→ `CLUB_RUN_IN_PROGRESS`) → per-order processing → `finalizeClubLine` (→ `CLUB_RUN_FINISHED`); driven by `runClubLine`. OMS picking notifications (RELEASE / STARTED / FINISHED) are enqueued per order as outbox rows inside `finalizeClubLine` (SBDEV-2381), one row per order — chunk size stays 1 on every tenant (`WMS_CLUBLINE_OMS_CHUNK_SIZE`). Several archived bug fixes target this flow (`Cancel_Club_Parcels_Packed_State_Fix`, `Club_Order_Cancellation_*`).

### cycle count
Periodic inventory audit. Entity `Cyclecount` + `CyclecountPosition`. String-typed state: `CREATED → FINISHED` or `CANCELLED` (⚠ `STARTED` is a defined constant that nothing writes; positions and the header go `CREATED → FINISHED` in `MobileCycleCountService`). Sysprops control UI behavior — `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT`, `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT`.

### transfer order
Movement between facilities. Has its own customer-order state track (`CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED`, `CUSTOMER_ORDER_ACTIVATED`). Distinct from intra-facility move stock.

### hub and spoke
A multi-WH pattern where one central hub feeds satellite spokes. Realized via the `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` OMS callback (default `.../receiveHubAndSpoke`), `AdviceType.HUB_AND_SPOKE`, `OrderBatchType.HUB_AND_SPOKE` and `AdviceService.acceptHubAndSpokeAdvice`. A `HUB_AND_SPOKE` BOL closes to `CLOSED`, not `TRANSFER`. Not a deep feature in v2 yet — minimal wiring.

---

## 5. Picking types and strategies

### TOTES_ON_CART
Picking strategy where operators push a cart with multiple totes. Merge-able; one operator fills many orders in one pass. Controlled by `MERGE_PICKING_ORDERS` + `PICKING_BOX_PER_CART`.

### RAPID_PICKING
Single-tote high-throughput zone. Subject to pick-timeout release via `ReleaseExpiredPickingOrdersFromUserJob` (sysprop `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE`, constant default 40 s, but an absent row throws `NumberFormatException`; the job also needs `PICK_TIME_OUT_SYSTEM_ACTIVATED`, constant default `false`).

### rapid picking path (customer order)
Distinct from the `RAPID_PICKING` picking type as a *concept*, but gated by it — refers to an inline arm of `CustomerorderService.cancelOrder` (`:899`; arm at `:984`; there is **no** method named `handleRapidPickingForCancelledOrder`). It fires iff the client's section is `RAPID_PICKING` && order state is `ASSIGNED` && `historytote != null`; the first position's `Pickingorder`, if `STARTED`, goes back to `PROCESSABLE` (`:1032`) and its pick-to `PickingorderUnitload`s go `CANCELED`. Don't simplify the `historytote != null` branch without reading that cascade in full (state-machine catalog §5.1). Data-armed only: the code comment calls it dead estate-wide (no `RAPID_PICKING` section carries orders).

### simple pick screen
UI variant for operators gated by `PICK_SCREEN_SIMPLE` sysprop. Hides advanced controls; used for new/temp workers.

---

## 6. Platform concepts

### landlord
The master PostgreSQL DB that knows "which tenants exist and how to connect to each." Contains 4 entities (`Tenant`, `TenantAuthConfiguration`, `TenantDbConfiguration`, `TenantDiscovery`; see landlord-vs-tenant map §2). Never holds business data.

### tenant
A physical PostgreSQL DB holding one tenant-facility's business data. Implemented as one DB per `(tenant_name, facility_code)` pair. 69 tenant `@Entity` classes in `model/` (+4 landlord in `landlord/model/`) at `df30fa62` (the April count of 62 is stale; includes view entities).  Multi-tenant routing via `hibernate.multiTenancy=DATABASE`.

### tenant_name
The tenant identifier, passed in the `X-Tenant-ID` HTTP header. Lowercased before use. Only the first 4 characters contribute to the routing key.

### facility_code
The facility identifier, passed in the `facility_code` HTTP header. Lowercased before use. Full value used in routing key.

### tenant key / routing key
The string `first4(tenantName) + "-" + facilityCode` (the tenant prefix is 4 characters, or the whole name if shorter; the facility code is appended in full, so the key is not fixed-length). Built by `TenantKeyBuilder.buildKey(...)`; cache keys use the **full** tenant name instead (`TenantKeyBuilder.cacheKey`). Used both for `HikariDataSource` lookup and for Hibernate's `CurrentTenantIdentifierResolver`. Example: tenant `wineco` + facility `cawh` → key `wine-cawh` (and `localhost` + `develop` → `loca-develop`).

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
`@Transactional(propagation = REQUIRES_NEW)`. Creates an isolated inner transaction that commits independently of the outer one. Used at 34 non-comment sites in `src/main/java` (grep `propagation = Propagation.REQUIRES_NEW`), concentrated in job-worker and infrastructure services (`ReplenishOrderJobService` 9, `OutboxService` 6, `ReplenishGeneratorService` 3, `ReleaseOrderJobService` 3, `ClubRunJobClaimService` 3, `SequenceTransactionService` 2, ...) to let one step fail or commit without aborting the whole iteration.

---

## 7. Integrations

### OMS (Order Management System)
The upstream/downstream system that owns customer/order data. WMS receives orders from OMS and fires callbacks back as they progress. All OMS endpoints are sysprops under `WEBSERVICE_*` (see [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md) §5). `SYSTEM_OMS_NAME` / `SYSTEM_WMS_NAME` identify the paired OMS and this WMS instance; `OMS_TENANT_ID` maps WMS tenants to OMS tenants.

### Keycloak
OpenID Connect / OAuth2 identity provider. Per-tenant config in `TenantAuthConfiguration` (landlord). WMS validates JWTs via `MultiTenantJwtDecoder`. The eight `KEYCLOAK_*` sysprops exist in the seed data but have **no live reader** in `src/main` (sysprop catalog §9, re-verified 2026-11-11); authentication config comes from `TenantAuthConfiguration` only.

### CUPS
Linux print-server protocol (Common Unix Printing System). Label printing goes through a CUPS server (address in `CUPS_SERVER_ADDRESS_IP`). The `org.cups4j:cups4j` dependency is flagged for removal in the archived problem-areas plan (row `CUPS_DEPENDENCY_REMOVAL`, "custom bundled JAR instead of Maven artifact"); `CUPS_DEPENDENCY_REMOVAL_PLAN` is **not** a sysprop or constant. ⚠ unverified 2026-11-11: whether the "custom bundled JAR" is still true — `pom.xml` now declares `org.cups4j:cups4j`.

### ZPL
Zebra Programming Language — the label-template format. ZPL templates are stored as sysprop values; there are separate templates for case, tote, outbound-pallet labels (see [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md) §7).

### PSD
Appears as `WEBSERVICE_TEST_CRM_CONNECTIVITY` → `.../services/call/testPsd`. A CRM-style OMS test endpoint. Scope is narrow — only used for connectivity smoke-tests.

---

## 8. People & roles

### operator
A warehouse worker using the mobile UI. Logs in via Keycloak; menu access flows through `MOBILE_UI_VIEW_*` **WMS functions** (`WmsConstants.FunctionEnum`, e.g. `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_VIEW_PUT_AWAY`) held via `mywms_*` role/function rows — not Keycloak realm roles (Keycloak is coarse, `wms_user`). `v2/wms2-mobile-ui/store/home.js` filters the static menu by the function list returned from the caller-scoped `GET /user/getAllRoles/{username}`.

### locked_to_operator
Column on `pickingorder` — when an operator claims a picking order, this is set true and `operator_id` is populated. The `ReleaseExpiredPickingOrdersFromUserJob` watches this: for a `RAPID_PICKING`-section order that is locked, not `pickinginprogress`, in a state **below** `PICKED`, and whose `modified` is older than `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` seconds, it clears `operator_id` and the lock so another operator can claim it (`PickingorderRepository.getPickingOrdersToReleaseExpiredPickingOrders`; gated by `PICK_TIME_OUT_SYSTEM_ACTIVATED`). Invariant: `lockedtooperator = true` implies `operator_id IS NOT NULL`.

### SYSTEM_OMS_NAME / SYSTEM_WMS_NAME (and the dead WMS_INSTANCE_NAME)
Human-readable labels for the paired OMS and this WMS instance. The **live** pair is `SYSTEM_OMS_NAME` / `SYSTEM_WMS_NAME` (`SyspropService.getOmsInstanceName()` / `getWmsInstanceName()`, `WmsConstants.java:1365-1366`). `WMS_INSTANCE_NAME` still exists as a seed row but has no live reader, and there is **no** `OMS_INSTANCE_NAME` key anywhere in the code. Not functional for routing.

---

## 9. Spelling / naming gotchas

| Surface form | What to know |
|---|---|
| **`CANCELED`** (one L) | Integer state — only applies to `Customerorder`, `CustomerorderPosition`, `CustomerorderBatch`, `Pickingorder`, `PickingorderPosition`, `PickingorderUnitload`, `Replenishorder` |
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
| 2026-11-11 | Term-by-term re-check at wms2-api `origin/develop` @ `df30fa62` (~110 terms: entities, state values, constants, sysprops, jobs, classes, headers). Corrections: removed non-existent `handleRapidPickingForCancelledOrder`, `OMS_INSTANCE_NAME`, `WAREHOUSE_TIME_ZONE_KEY`-as-sysprop, `trucklane`; routing key is not 4 chars; facility code is not 2 chars; staging lane is a `Location.staginglane` flag; `LocationConstraint` pairs location type with unit-load type; Advice `PROCESSING`/`CLOSED`/`CANCELLED`, BOL `CANCELLED`/hub-and-spoke `TRANSFER`, cycle-count `STARTED` have no writers; replenish trigger is absolute quantity; pick-timeout job scope (`state < PICKED`, RAPID_PICKING, activation flag); `MOBILE_UI_VIEW_*` are WMS functions not realm roles; `KEYCLOAK_*` sysprops have no reader; `REQUIRES_NEW` 34 sites; entity counts (Stockrecord 20+4, Customerorder 28+4, 69 tenant `@Entity` — corrected from 70 after independent review). Unverified items marked inline | All other terms confirmed | Code read (grep + offset reads) + 2026-11-11 state-machine, sysprop and workflow docs |

**Re-verify every 60 days.** Next due: **2027-01-10** — vocabulary changes slowly, but any new subsystem (e.g. new carrier integration, new automation type) typically introduces 2–4 new terms worth appending.
