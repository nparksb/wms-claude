---
title: "WMS — Domain Glossary (v1 + v2)"
type: data-dictionary
status: active
system: wms1+wms2
owner: Nam Park
created: 2026-04-27
updated: 2026-04-27
last_verified: 2026-05-08
verified_by: code read of v1/wms-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java + v2/wms2-api source + existing wms2-domain-glossary.md
related:
  - ./wms2-domain-glossary.md
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-tenant-routing-datasource-topology.md
  - ./wms2-landlord-vs-tenant-entity-map.md
  - ./wms2-sysprop-catalog.md
  - ../workflows/wms1-bol-truck-loading-workflow.md
  - ../workflows/wms1-picking-workflow.md
tags:
  - data-dictionary
  - glossary
  - vocabulary
  - wms1
  - wms2
---

# WMS — Domain Glossary (v1 + v2)

**Scope:** Warehouse vocabulary shared across `v1/wms-api` and `v2/wms2-api`, the mobile UIs, and integrations
**Owner:** Nam Park · **Last verified:** 2026-04-27

> **How this doc relates to `wms2-domain-glossary.md`**: That doc covers v2 in depth. This doc is the **combined reference** — it carries forward all v2 terms, adds v1-specific terms and constants, and annotates differences where v1 and v2 diverge. When a term is identical in both versions, no version tag is shown. When it differs, an explicit **v1** / **v2** note is included.

---

## 1. Overview

Most WMS bugs that escalate aren't caused by missing code — they're caused by two engineers meaning different things when they say "tote" or "unitload" or "facility". This glossary pins every ambiguous term to its canonical meaning and the code that realizes it.

For state values (`RAW`, `PICKED`, `CANCELED` etc.) see [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md). For sysprop keys see [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md). For entity class names see [wms2-landlord-vs-tenant-entity-map.md](./wms2-landlord-vs-tenant-entity-map.md).

---

## 2. Physical objects

### cart (picking cart)
A physical rolling device that carries multiple totes during a pick wave. Capacity capped by sysprop `PICKING_BOX_PER_CART` (default 6). Used by the `TOTES_ON_CART` picking type. Not a DB entity — carts are implicit via the groupings created during `mergePickingOrders` / `ReplenishOrderJob`. **Do not confuse** with the `CART-\d{4}` barcode pattern, which identifies an inbound pallet, not a picking cart.

- **v1 unit load type constant:** `UNIT_LOAD_TYPE_CART = "Cart"` (`WmsConstants.java:697`)
- Related: tote, TOTES_ON_CART, pallet

### case / box
A `Boxtype`-backed shipping carton. Sysprop `DEFAULT_BOX_TYPE` picks the default (`UL_TYPE_BOX_NAME_14`). A "case label" (ZPL template `PRINTING_ZPL_CASE_LABEL`) is printed during packing. v1 unit load type constant: `UNIT_LOAD_TYPE_BOX = "Case"`.

- Related: pallet, boxtype, BoxTypeProcessType

### pallet
A `UnitloadType` for bulk shipment. Inbound pallet barcode: `CART-\d{4}|IN-\d{6}` (sysprop `STRING_PATTERN_INBOUND_PALLET`). Outbound pallet barcode: `OUT-\d{6}`. Outbound pallets have their own sequence (`PALLET_OUTBOUND`) and format (`OUT-%1$06d`). v1 constant: `UNIT_LOAD_TYPE_PALLET = "Pallet"`.
- **"Cart" in the inbound regex is a pallet-ish inbound container, not a picking cart.**
- Related: cart, unit load, unitload type

### parcel
A small single-box shipment. Barcode pattern `P-\d{4}` (sysprop `STRING_PATTERN_PICKING_PARCEL`). Tracked as a unit load; surfaced via `ParcelMonitorView`.

- Related: unit load, ParcelMonitorView

### stockunit
A row in the `stockunit` table representing "item X has amount Y at this location, of which Z is reserved." Has `amount` + `reservedamount`. **No state field.** The barcode prefix `SU-\d{6}` (sysprop `STRING_PATTERN_SEPARATE_STOCK`; v1 `EntityPrefixes.STOCKUNIT = "SU"`) identifies a physically separated stock unit carrier — do not conflate with the table row.

- Related: stockrecord, fix location assignment, unitload

### stockrecord
An audit/ledger entry for stock movements. Written whenever a `Stockunit` amount changes — creations, deletions, transfers. **v1:** `StockRecordType` inner class in `WmsConstants` distinguishes `STOCK_CREATED`, `STOCK_TRANSFERRED`, etc. Do not query for current stock levels; use `Stockunit` or `StockView` instead.

- **v1 code:** `WmsConstants.StockRecordType`

### tote
A specific `UnitloadType` — a plastic picking container. Barcode pattern: `T-\d{4}` (sysprop `STRING_PATTERN_PICKING_TOTE`). Functionally: a unit load whose role is to hold items during picking before they move to pallet/box. Picking totes have a separate ZPL label template (`PRINTING_ZPL_PICKING_TOTE_LABEL`). v1 constant: `UNIT_LOAD_TYPE_TOTE = "Tote"`.

- Related: cart (picking cart), unit load, TOTES_ON_CART

### unit load
The generic term for "one physical thing that can be moved as a single piece of inventory." Entity `Unitload` (tenant DB). Has a `UnitloadType` (e.g. pallet, tote, carton, cart) and carries 1..N `Stockunit` rows. **Has no state field** — lifecycle is inferred from the state of its parent `PickingorderUnitload` or its parent pick order.

- **v1 entity prefix:** `EntityPrefixes` does not have a dedicated prefix for generic unit loads; pick-specific loads are addressed via `PickingorderUnitload`.
- Related: unitload type, stockunit, tote, pallet

### unitload type
A classification row for unit loads. v1 named constants: `UNIT_LOAD_TYPE_DEFAULT = "Default"`, `UNIT_LOAD_TYPE_PICKLOCATION = "PickLocation"`, `UNIT_LOAD_TYPE_TOTE = "Tote"`, `UNIT_LOAD_TYPE_PACKAGE = "Package"`, `UNIT_LOAD_TYPE_BOX = "Case"`, `UNIT_LOAD_TYPE_PALLET = "Pallet"`, `UNIT_LOAD_TYPE_CART = "Cart"` (`WmsConstants.java:691–697`).

- Related: unit load

---

## 3. Warehouse structure

### area
A named grouping of locations within a facility. v1 named areas: `"Inbound"`, `"Outbound"`, `"Storage and Replenish"`, `"Storage Picking and Replenish (from)"`, `"Storage and Picking"`, `"users"`, `"Deep Storage"`, `"Default"` (`WmsConstants.java:719–726`). Areas are not entities themselves — they are logical groupings used by `ReplenishOrderJob` and receiving to determine where stock moves.

- Related: location, fix location assignment

### facility
The physical warehouse building. Identified by `facility_code` (a 2-character short code — e.g., `CA`, `TX`). Combined with `tenant_name` to form the 4-char routing key. **A single WMS instance serves one tenant at a time per request**, but one tenant can have multiple facilities.

### fix location assignment (fixlocation)
A binding: "item X always goes at location Y." Stored in `fix_location_assignment`. Central to replenishment — `ReplenishOrderJob` uses these to know where stock should be refilled to.

- **v2** fill thresholds come from sysprops (`FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND` 36%, `MIDDLE_BOUND` 60%, `UPPER_BOUND` 84%). The `EMTPY` typo in `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` is preserved in the DB row — do not "fix" it.
- Related: replenish order, overstock, flowbin

### flowbin
A specific fix-location pattern used in flow-through pick zones. Location type constant: `STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN = "flowbin"`. Constraint name: `CONSTRAINT_FLOWBIN = "only boxes allowed"` / `CONSTRAINT_FLOWBIN_IMPORT_NAME = "Flowbin"` (`WmsConstants.java:700,708–709`). Treat as a special case of a fix-location assignment; flowbin refills have tighter constraints (gravity-fed, FIFO). Surfaced via `FlowbinMonitorView`.

- Related: fix location assignment, overstock, location type

### location
A physical pick slot — one row in `location`. Has a `LocationType`, belongs to an `Area`, sits on a `Rack`/`RackRow`. `LocationConstraint` rows attach business rules. v1 entity prefix: `EntityPrefixes.STORAGE_LOCATION = "LOC"`, `EntityPrefixes.STORAGE_LOCATION_TYPE = "SLT"`.

### location type
A classification for `Location` rows that controls which `UnitloadType` can be placed there. v1 named types:

| Constant | Value | Meaning |
|---|---|---|
| `STORAGE_LOCATION_TYPE_NO_RESTRICTION` | `"NoRestriction"` | Any unit load allowed |
| `STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN` | `"flowbin"` | Boxes only (gravity-fed) |
| `STORAGE_LOCATION_TYPE_BOX_RESTRICTION_OVERSTOCK` | `"overstock box"` | Overstock boxes only |
| `STORAGE_LOCATION_TYPE_PALLET_RESTRICTION_OVERSTOCK` | `"overstock pallet"` | Overstock pallets only |
| `STORAGE_LOCATION_TYPE_TOTES_RESTRICTION` | `"totes"` | Totes only |
| `STORAGE_LOCATION_TYPE_PACKAGES_RESTRICTION` | `"packages"` | Packages only |
| `STORAGE_LOCATION_TYPE_STOCK_RESTRICTION` | `"cases and pallets"` | Cases and pallets |

(`WmsConstants.java:699–705`)

### nirvana (Nirwana)
A special virtual `Location` named `"Nirwana"` (note the German/Dutch spelling — no "a" at the end of "Nirv"). Used as a sink location for stock adjustments that have no valid physical destination — e.g., when a unit load is deleted or stock is written off during a cycle count discrepancy. Not a business flow location; stock sent here is effectively removed from inventory without generating a standard outbound event. v1 constant: `STORAGE_LOCATION_NIRVANA = "Nirwana"` (`WmsConstants.java:729`).

> **Spelling note:** The constant is `"Nirwana"`, not `"Nirvana"`. The DB row uses this spelling. Do not "fix" it.

- Related: clearning location, stockrecord, cycle count

### overstock
A category of warehouse locations designated for reserve/bulk storage that is **not** a primary pick face. Two overstock location types exist: `"overstock box"` (box-sized reserve) and `"overstock pallet"` (pallet-sized reserve). The `OrderReleaseJob` checks overstock locations when a fix-location pick face is depleted — if sufficient stock exists at an overstock location, the order can be released directly from overstock without triggering a replenish order. v1 constants: `STORAGE_LOCATION_TYPE_BOX_RESTRICTION_OVERSTOCK` and `STORAGE_LOCATION_TYPE_PALLET_RESTRICTION_OVERSTOCK` (`WmsConstants.java:701–702`).

- Related: fix location assignment, flowbin, replenish order, deep storage

### putaway lane
A virtual staging location (`"PutAwayLane"`) where inbound stock lands immediately after goods receipt, before it is assigned to a permanent location. The `FileImportController` and `SkuRestController` both reference `STORAGE_LOCATION_PUTAWAY_LANE` when setting a default putaway destination for items. v1 constant: `STORAGE_LOCATION_PUTAWAY_LANE = "PutAwayLane"` (`WmsConstants.java:735`).

- Related: goods receipt, inbound workstation, advice

### section
A logical grouping of locations driven by `pickingtype`. Primary values:
- `TOTES_ON_CART` — operators push a cart loaded with totes, picking into them as they walk the section.
- `RAPID_PICKING` — high-throughput single-tote zone.

v1 entity prefix: `EntityPrefixes` has no dedicated section prefix; sections are implicitly referenced by name.

### staging lane
A designated `Location` (modeled as a `Location` row with a specific `LocationType`) where a `CustomerorderBatch` is staged during the pre-load phase. Set via `ORDER_BATCH_STAGING_LANE_ASSIGNED` state. Named `StagingLane01`–`StagingLane06` in v1 (`WmsConstants.java:748–753`).

- Related: customer order batch, club run, transfer lane

### transfer lane
A `Location` row used as a staging area for transfer orders before the BOL is loaded. Named `TransferLane01`–`TransferLane06` in v1 (`WmsConstants.java:754–759`). Distinct from staging lanes (which are for club runs / customer order batches).

- Related: transfer order, bill of lading, staging lane

### warehouse
Informal synonym for "facility." The sysprop `WAREHOUSE_NAME` stores the human-readable label; `facility_code` is the routing identifier. `WAREHOUSE_TIME_ZONE_KEY` (`"System Time Zone"`) holds the local TZ.

### system locations (virtual / special-purpose)
v1 defines a set of named virtual locations that are not physical pick slots:

| Constant | Value | Purpose |
|---|---|---|
| `STORAGE_LOCATION_CLEARING` | `"Clearing"` | Temporary holding during stock adjustments |
| `STORAGE_LOCATION_NIRVANA` | `"Nirwana"` | Stock sink (deletion / write-off) |
| `STORAGE_LOCATION_SPAWN` | `"Spawn"` | Origin location for newly created stock |
| `STORAGE_LOCATION_CYCLE_COUNT` | `"CycleCount"` | Holding during active count |
| `STORAGE_LOCATION_INBOUND_NAME` | `"InboundWorkstation"` | Receiving desk |
| `STORAGE_LOCATION_FINISHED_PICKING` | `"FinishedPicking"` | Totes placed after pick complete |
| `STORAGE_LOCATION_EMPTY_PALLETS` | `"EmptyPallets"` | Empty pallet staging |
| `STORAGE_LOCATION_PUTAWAY_LANE` | `"PutAwayLane"` | Pre-assignment buffer after goods receipt |
| `STORAGE_LOCATION_PACKAGING` | `"Packaging"` | Packing station |
| `STORAGE_LOCATION_PALLETISING` | `"Palletizing"` | Palletizing station |
| `STORAGE_LOCATION_EMPTY_TOTES` | `"EmptyTotes"` | Returned empty totes |
| `STORAGE_LOCATION_SHIPPED` | `"Shipped"` | Post-BOL-close destination for pallets |
| `STORAGE_LOCATION_TRANSFER` | `"Transfer"` | Staging for transfer shipments |

(`WmsConstants.java:728–740`)

---

## 4. Logical entities and business flows

### advice (ASN / inbound BOL)
An "Advance Ship Notice" — a supplier's declaration of what's arriving. Entity `Advice` + line entity `Adviceposition`. v1 entity prefix: `EntityPrefixes.ADVICE = "IBOL"` (the UI surface calls it "Inbound BOL"). Lifecycle: `CREATED → OPEN → PROCESSING → CLOSED → FINISHED` (or `CANCELLED`). Note **String-typed state** (`WmsConstants.AdviceState`), spelled `CANCELLED` with two L's.

**v1 advice types** (`WmsConstants.AdviceType`):
- `REGULAR` — standard inbound delivery
- `INBOUND` — regular delivery (alternate constant, same semantic)
- `HUB_AND_SPOKE` — cross-docking inbound from the hub
- `TRANSFER_IMPORT` — inbound from a transfer order

The callback `ADVICE_CLOSE` fires to OMS when an advice closes. Additional callbacks: `ADVICE_TRANSFER_IMPORT`, `ADVICE_HUB_AND_SPOKE_IMPORT`, `ADVICE_HUB_AND_SPOKE_RECEIVED`, `ADVICE_ACCEPT_TRANSFER`.

- **v1 vs v2:** v1 calls this entity "Inbound BOL" in the UI (hence the `IBOL` prefix); v2 uses the term "advice" more consistently. The entity and state machine are identical.
- Related: goods receipt, putaway lane, hub and spoke

### bill of lading (BOL / outbound BOL)
The manifest that accompanies an outbound truck. Entity `Billoflading` + `BillofladingPosition`. v1 entity prefixes: `EntityPrefixes.BILL_OF_LADING = "OBOL"`, `EntityPrefixes.BILL_OF_LADING_POSITION = "OBOLP"`. String-typed state (`WmsConstants.BillOfLadingState`): `CREATED → OPEN → TRUCK_LOADING → TRANSFER → CLOSED` (or `CANCELLED`). `TRANSFER` applies to hub-and-spoke / multi-WH movement.

`closeBOL` in `BillofladingService` is the most complex v1 state transition — pessimistic lock + in-memory guard + bulk updates across positions, customer orders, and unitloads. See [wms1-bol-truck-loading-workflow.md](../workflows/wms1-bol-truck-loading-workflow.md).

- Related: truck lane, staging lane, transfer order, hub and spoke

### business object lock state
v1-specific: a `BusinessObjectLockState` integer flag on entities that prevents concurrent modification. States: `NOT_LOCKED`, `GOING_TO_DELETE`, `PICKED_FOR_GOODSOUT` (100), `QUALITY_FAULT`, `ON_HOLD`, `NOT_FOUND` (`WmsConstants.java:1105–1138`). Used to block deletion or modification of a unit load that is in the middle of a goods-out scan.

- **v2:** equivalent concept handled via optimistic locking or state guards; no dedicated `BusinessObjectLockState` enum.
- Related: goodsout, unit load

### customer order
The order being fulfilled. Entity `Customerorder` — 38 fields (v1), Integer `state` (`WmsConstants.State`). The most-referenced entity in both codebases.

**v1 Integer states** (`WmsConstants.State`):
- `FUTURE_PICKING_DATE = 80` — order exists but picking date has not arrived
- `RAW = 100` — just imported
- `PROCESSABLE = 300` — ready to be picked
- `STARTED = 500` — picked
- `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED = 510` — transfer lane assigned
- `ORDER_BATCH_ACTIVATED = 520` — batch activated
- `ORDER_BATCH_STAGING_LANE_ASSIGNED = 525` — staging lane assigned
- `ORDER_BATCH_CLUB_RUN_FINISHED = 530` — club run complete
- `PICKED = 600` — picking confirmed
- `PACKED = 650` — packed into case
- `FINISHED = 700` — shipped / closed

**v1 vs v2:** v1 adds `FUTURE_PICKING_DATE (80)` and `PACKED (650)` that are not present in v2's state sequence. The `TRANSFER_LANE_ASSIGNED (510)` / `ORDER_BATCH_*` states (520–530) exist in both, but v1 holds them as `WmsConstants.State` Integer constants while v2 expresses them via a separate state-machine catalog.

- Related: picking order, customer order batch, replenish order

### customer order batch
A batched set of orders that go through the pick flow together. Entity `CustomerorderBatch`. v1 entity prefix: `EntityPrefixes.ORDER_BATCH = "ODB"`. Primary use case: club runs. States driven by Integer `WmsConstants.State` constants (`ORDER_BATCH_ACTIVATED`, `ORDER_BATCH_STAGING_LANE_ASSIGNED`, `ORDER_BATCH_CLUB_RUN_FINISHED`). Message callbacks: `ORDER_BATCH_PICKING_RELEASED`, `ORDER_BATCH_PICKING_TOTE_ASSIGNED`, `ORDER_BATCH_PICKING_STARTED`, `ORDER_BATCH_PICKING_FINISHED`, `ORDER_BATCH_QA_FINISHED`, `ORDER_BATCH_SHIPPED`, `ORDER_BATCH_FINISHED_TRANSFER`.

**v1 order batch types** (`WmsConstants.OrderBatchType`):
- `REGULAR` — standard pick-pack + club + transfer-offsite outbound batches
- `PICK_PACK` — regular winery picking orders
- `TRANSFER_OFFSITE` — offsite transfer orders
- `TRANSFER_INTRACOMPANY` — warehouse-to-warehouse transfer within the same company
- `HUB_AND_SPOKE` — cross-docking shipments

- Related: club run, staging lane, picking order

### club run / club order
A recurring subscription-style order batch, typically wine-of-the-month / food-of-the-month customers. A "club run" is one wave execution: activate batch → assign staging lane → confirm club orders → finish. Triggers notifications at `CLUB_RUN_IN_PROGRESS` and `CLUB_RUN_FINISHED`. Several archived bug fixes target this flow (`Cancel_Club_Parcels_Packed_State_Fix`, `Club_Order_Cancellation_*`).

- Related: customer order batch, staging lane, picking order

### cycle count
Periodic inventory audit. Entity `Cyclecount` + `CyclecountPosition`. v1 entity prefixes: `EntityPrefixes.CYCLECOUNT = "CC"`, `EntityPrefixes.CYCLECOUNT_POSITION = "CCP"`. String-typed state (`WmsConstants.CycleCountState`): `CREATED → STARTED → FINISHED` (or `CANCELLED`).

**v1 cycle count types** (`WmsConstants.CycleCountType`): constants define the scope of a count (e.g., location-level vs item-level). **v1 cycle count subtypes** (`WmsConstants.CycleCountSubType`): further classify the reason/trigger for a count.

Sysprops control UI behavior: `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT`, `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT`. The system location `"CycleCount"` holds stock physically separated for counting.

- Related: stockunit, nirvana, location

### future picking date
**v1-specific.** A customer order state (`FUTURE_PICKING_DATE = 80`) indicating the order exists in the system but its scheduled pick date has not yet arrived. The `OrderReleaseJob` skips orders in this state. Not present in v2's state model.

- **Code:** `WmsConstants.State.FUTURE_PICKING_DATE = 80`
- Related: customer order, OrderReleaseJob

### goods receipt
The actual physical receiving event. Entity `Goodsreceipt` (header) + `Goodsreceiptposition` (lines). v1 entity prefixes: `EntityPrefixes.GOODS_RECEIPT = "GRT"`, `EntityPrefixes.GOODS_RECEIPT_POSITIONS = "GRP"`. Records what was actually unloaded — distinct from the advice (what was promised). One advice → 0..N goods receipts.

- Related: advice, putaway lane, inbound workstation

### goodsout (goods-out)
**v1-specific term.** Refers to the outbound scanning step where a picked/packed unit load is confirmed for departure — typically a mobile scan against an open BOL. The `BusinessObjectLockState.PICKED_FOR_GOODSOUT = 100` flag marks a unit load that is actively being scanned out, blocking concurrent operations on it. Not its own entity; realized via `BillofladingPosition` state transitions.

- **Code:** `WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT`
- **v2:** the concept exists as truck-loading scan in `MobileTruckLoadingService`; the lock state constant does not carry over.
- Related: bill of lading, business object lock state, truck loading

### hub and spoke
A multi-WH pattern where one central hub feeds satellite spokes. v1 realizes this via:
- `AdviceType.HUB_AND_SPOKE` — inbound from the hub
- `OrderBatchType.HUB_AND_SPOKE` — outbound cross-dock batch
- `BillOfLadingState.TRANSFER` — BOL state during hub-to-spoke movement
- Callbacks `ADVICE_HUB_AND_SPOKE_IMPORT`, `ADVICE_HUB_AND_SPOKE_RECEIVED`, `WEBSERVICE_ACCEPT_HUB_AND_SPOKE`

- **v1 vs v2:** v1 has more wired callback paths for hub-and-spoke; v2 has minimal wiring.
- Related: transfer order, bill of lading, advice

### inventory record
**v1-specific entity.** `InventoryRecord` tracks a high-level inventory event (separate from `Stockrecord`). `WmsConstants.InventoryRecordType` classifies the event type. Distinct from `UnitloadRecord` (which tracks unit-load lifecycle events). Not present as a named entity in v2.

- **Code:** `WmsConstants.InventoryRecordType`
- Related: stockrecord, unitload record

### picking order
The work package handed to an operator. Distinct from the customer order. Entity `Pickingorder` + `PickingorderPosition` (line) + `PickingorderUnitload` (the tote being filled). v1 entity prefixes: `EntityPrefixes.PICKING_ORDER = "PO"`, `EntityPrefixes.PICKING_POSITION = "PP"`, `EntityPrefixes.PICK_ORDER = "PICK"`. State uses the same Integer `WmsConstants.State` as `Customerorder`.

One customer order can split across multiple picking orders; one picking order can service multiple customer orders. The `MERGE_PICKING_ORDERS` sysprop controls auto-merging.

- Related: customer order, replenish order, TOTES_ON_CART, RAPID_PICKING

### replenish order
An instruction to move stock from reserve storage to a pick face. Entity `Replenishorder`. v1 entity prefix: `EntityPrefixes.REPLENISH_ORDER = "REPL"`. States: `RAW → PROCESSABLE → STARTED → FINISHED` (or `CANCELED`). Generated by `ReplenishOrderJob` when fix-location fill % drops below the lower bound.

- Related: fix location assignment, overstock, picking order

### transfer order
Movement of customer orders between facilities. Has its own customer-order state track (`CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED = 510`). v1 `OrderBatchType` distinguishes `TRANSFER_OFFSITE` (to an external site) from `TRANSFER_INTRACOMPANY` (between warehouses within the same company). Distinct from intra-facility stock moves.

- Related: transfer lane, bill of lading, hub and spoke, customer order batch

### unitload record
**v1-specific.** `UnitloadRecord` tracks lifecycle events for a unit load (creation, movement, deletion). `WmsConstants.UnitloadRecordType` classifies the type (e.g., `CREATED`, `TRANSFERRED`). Analogous to `Stockrecord` but at the unit-load level rather than the stock-quantity level.

- **Code:** `WmsConstants.UnitloadRecordType`
- **v2:** equivalent audit trail via `UnitloadRecord` entity (same name, carried forward).
- Related: inventory record, stockrecord, unit load

---

## 5. Picking types and strategies

### FUTURE_PICKING_DATE (customer order state)
See §4 "future picking date."

### PACKED (customer order state)
**v1-specific state.** Integer `650` — customer order has been packed into a case/box but not yet shipped. Sits between `PICKED (600)` and `FINISHED (700)`. Not in v2's defined state sequence.

- **Code:** `WmsConstants.State.PACKED = 650`
- Related: customer order, case/box, bill of lading

### PICK_PACK (order batch type)
**v1-specific.** An `OrderBatchType` for regular (winery) picking orders where each order is picked directly into a box rather than a tote. Distinct from the `REGULAR` batch type (which covers club runs and transfer-offsite outbound). **v2** does not expose this as a named constant.

- **Code:** `WmsConstants.OrderBatchType.PICK_PACK = "PICK_PACK"`
- Related: customer order batch, picking order

### RAPID_PICKING
Single-tote high-throughput picking zone. Subject to pick-timeout release via `ReleaseExpiredPickingOrdersFromUserJob` (default 40 s, sysprop `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE`). **Also used as a customer-order branch** — if a cancelled order had already been rapid-picked into a tote, the service bounces the pick order back to `PROCESSABLE` rather than cancelling, so the tote's contents can be redistributed. Do not simplify the `historytote != null` branch without reading the full cascade.

- **Code:** `WmsConstants.SectionPickingType.RAPID_PICKING = "RAPID_PICKING"`
- Related: section, picking order, TOTES_ON_CART

### simple pick screen
UI variant for operators gated by `PICK_SCREEN_SIMPLE` sysprop. Hides advanced controls; used for new/temp workers.

### TOTES_ON_CART
Picking strategy where operators push a cart carrying multiple totes. Merge-able; one operator fills many orders in one pass. Controlled by `MERGE_PICKING_ORDERS` + `PICKING_BOX_PER_CART`.

- **Code:** `WmsConstants.SectionPickingType.TOTES_ON_CART = "TOTES_ON_CART"`
- Related: section, cart (picking cart), picking order

---

## 6. Entity ID prefixes (v1)

All v1 entity numbers are generated with a string prefix via `EntityPrefixes` inner class in `WmsConstants`. v2 carries the same prefixes forward for backward-compatible identifiers.

| Entity | Prefix constant | Prefix value |
|---|---|---|
| Advice (Inbound BOL) | `ADVICE` | `IBOL` |
| Goods Receipt | `GOODS_RECEIPT` | `GRT` |
| Goods Receipt Position | `GOODS_RECEIPT_POSITIONS` | `GRP` |
| Order Batch | `ORDER_BATCH` | `ODB` |
| Picking Order | `PICKING_ORDER` | `PO` |
| Picking Position | `PICKING_POSITION` | `PP` |
| Pick Order (alt) | `PICK_ORDER` | `PICK` |
| Stockunit (separate carrier) | `STOCKUNIT` | `SU` |
| Storage Location | `STORAGE_LOCATION` | `LOC` |
| Storage Location Type | `STORAGE_LOCATION_TYPE` | `SLT` |
| Replenish Order | `REPLENISH_ORDER` | `REPL` |
| Bill of Lading | `BILL_OF_LADING` | `OBOL` |
| Bill of Lading Position | `BILL_OF_LADING_POSITION` | `OBOLP` |
| Cycle Count | `CYCLECOUNT` | `CC` |
| Cycle Count Position | `CYCLECOUNT_POSITION` | `CCP` |
| Group | `GROUP` | `GROUP` |
| Role | `ROLE` | `ROLE` |

(`WmsConstants.java:547–597`)

---

## 7. Platform concepts

### advisory lock
A PostgreSQL session-level lock used for cross-replica cron-job mutual exclusion. IDs are fixed constants in `AdvisoryLockService.JobLockId` (v2). Will break under PgBouncer `pool_mode=transaction` — see [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §7 item 1.

- **v1:** same concept; v1 uses a Java `synchronized` in-memory guard (`bolToClose` set) for single-JVM mutual exclusion during `closeBOL`, with a DB pessimistic lock for multi-replica safety.

### BOOTSTRAP
A literal string returned by `TenantIdentifierResolver` (v2) when no tenant context exists. Hibernate uses this as the tenant identifier for startup-time and context-less queries. Never hit this in a request path — if you do, it's a bug.

### facility_code
The facility identifier, passed in the `facility_code` HTTP header. Lowercased before use. Full value used in routing key.

### landlord
(v2 only.) The master PostgreSQL DB that knows "which tenants exist and how to connect to each." Contains 4 entities. Never holds business data. v1 has no landlord concept — tenant routing is handled by a static datasource config per deployment.

### OSIV
"Open Session In View." Disabled in v2 (`spring.jpa.open-in-view=false`). Any lazy association must be resolved inside the `@Transactional` boundary. **v1:** same setting — Spring Boot default behavior is overridden; lazy loads outside `@Transactional` will throw.

### REQUIRES_NEW
`@Transactional(propagation = REQUIRES_NEW)`. Creates an isolated inner transaction that commits independently of the outer one. Used in both v1 and v2 inside scheduled jobs to let one step fail without aborting the whole iteration.

### sysprop
A tenant-scoped configuration key/value row in the `los_sysprop` table. Read via `SyspropService`. See [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md). **Not** a landlord concept — each tenant has its own row set.

### tenant
A physical PostgreSQL DB holding one tenant-facility's business data. In v2: one DB per `(tenant_name, facility_code)` pair; 62 entities. In v1: same routing scheme; static datasource per deployment.

### tenant_name
The tenant identifier, passed in the `tenant_name` HTTP header. Lowercased before use.

### tenant key / routing key
The 4-character string `first4(tenantName) + "-" + facilityCode`. Used for datasource lookup and Hibernate tenant identifier resolution. Example: tenant `wineco` + facility `cawh` → key `wine-cawh`.

### TenantContext
(v2 only.) ThreadLocal holder for the active `TenantProfile`. Set by `TenantFilter` per HTTP request, cleared in `finally`. Does **not** propagate across threads.

---

## 8. Integrations

### CUPS
Linux print-server protocol (Common Unix Printing System). Label printing goes through a CUPS server (address in `CUPS_SERVER_ADDRESS_IP`). Legacy dependency flagged for removal in `CUPS_DEPENDENCY_REMOVAL_PLAN`.

### Keycloak
OpenID Connect / OAuth2 identity provider. Per-tenant config in v2's `TenantAuthConfiguration` (landlord). WMS validates JWTs via `MultiTenantJwtDecoder`. Realm, client, and admin service-account config are sysprops under `KEYCLOAK_*`.

### OMS (Order Management System)
The upstream/downstream system that owns customer/order data. WMS receives orders from OMS and fires callbacks back as they progress. All OMS endpoints are sysprops under `WEBSERVICE_*`. Relevant v1 callback constants:

| Constant | Default URL fragment | Trigger |
|---|---|---|
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `.../receiveHubAndSpoke` | Hub-and-spoke advice accepted |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `.../finishedPicking` | Order batch picking completed |
| `ADVICE_CLOSE` | (message type) | Advice closed |

- Related: advice, customer order, hub and spoke

### PSD
Appears as `WEBSERVICE_TEST_CRM_CONNECTIVITY` → `.../services/call/testPsd`. A CRM-style OMS test endpoint used only for connectivity smoke-tests.

### ZPL
Zebra Programming Language — label template format. ZPL templates are stored as sysprop values; separate templates for case, tote, outbound-pallet, picking-tote labels.

---

## 9. People and roles

### operator
A warehouse worker using the mobile UI. Logs in via Keycloak; role assignments flow through `MOBILE_UI_VIEW_*` Keycloak realm roles (e.g. `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_VIEW_PUT_AWAY`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_TRANSFER`, `MOBILE_UI_VIEW_STOCK_TRANSFER`).

### locked_to_operator
Column on `pickingorder` — when an operator claims a picking order, this is set true and `operator_id` is populated. The `ReleaseExpiredPickingOrdersFromUserJob` watches this: if the order stays locked for longer than `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` seconds, it clears the lock so another operator can claim it.

### WMS_INSTANCE_NAME / OMS_INSTANCE_NAME
Human-readable labels for this environment (e.g. `prod-ca`, `dev-tx`). Used in message envelopes and audit trails — not functional for routing.

---

## 10. Spelling and naming gotchas

| Surface form | What to know |
|---|---|
| **`CANCELED`** (one L) | Integer state — applies to `Customerorder`, `CustomerorderBatch`, `Pickingorder`, `PickingorderPosition`, `PickingorderUnitload`, `Replenishorder` |
| **`CANCELLED`** (two L's) | String state — applies to `Advice`, `Adviceposition`, `Billoflading`, `BillofladingPosition`, `Cyclecount`, `CyclecountPosition` |
| **`EMTPY`** (typo preserved) | Sysprop key `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY`. Do not "fix" — the DB row uses this spelling. |
| **`Nirwana`** (not "Nirvana") | Storage location constant `STORAGE_LOCATION_NIRVANA = "Nirwana"`. German/Dutch spelling. Do not rename. |
| **`mywms_*`** table prefix | Legacy naming on user/role/group/function tables only. Don't generalize. |
| **`los_*`** table prefix | Legacy naming on `los_sysprop` and `los_sequencenumber` only. |
| **`CART-####`** | Inbound pallet barcode pattern — **not** a picking cart. |
| **`IBOL`** prefix | Inbound BOL = Advice entity. The UI says "Inbound BOL"; the code says `Advice`/`Adviceposition`. |
| **`OBOL` / `OBOLP`** prefix | Outbound BOL = `Billoflading` / `BillofladingPosition`. |
| **`GRT` / `GRP`** prefix | Goods Receipt header (`GRT`) and positions (`GRP`). |
| **`PICK_PACK`** vs **`REGULAR`** | Both are `OrderBatchType` values. `PICK_PACK` is winery single-box picks; `REGULAR` is used for club runs and transfer-offsite. |
| **`FUTURE_PICKING_DATE = 80`** | v1-only customer order state — order imported but pick date not reached. Skip in v2 state comparisons. |
| **`PACKED = 650`** | v1-only customer order state between `PICKED` and `FINISHED`. No v2 equivalent. |

---

## 11. How to use this doc

| Task | Start at |
|---|---|
| First time reading a WMS service method | Skim §2 + §3 + §4 to ground the vocabulary |
| Writing a plan that uses domain terms | Reference this doc by section in the plan's "Scope" block |
| Onboarding a new engineer | §2, §3, §4 cover 90% of terms they'll hit in code review |
| Seeing "CANCELLED" in a log and wondering why a guard didn't fire | §10 first, then state-machine catalog §7 item 2 |
| Looking up a v1 entity ID prefix | §6 entity prefix table |
| Understanding a v1-only concept (PACKED, FUTURE_PICKING_DATE, goodsout) | §4–5 with "v1-specific" annotations |
| Finding a storage location constant (Nirwana, PutAwayLane, etc.) | §3 "system locations" table |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-27 | v1 terms extracted from `WmsConstants.java` (full file grep); cross-referenced against v2 glossary for duplicates; v1 entity model list from `model/` directory; workflow docs (BOL, picking) for context; overstock/nirvana/putaway confirmed via `OrderReleaseJob` and `FileImportController` references | All terms grounded in code | Code grep + existing wms2-domain-glossary.md |

**Re-verify every 120 days.** Next due: **2026-08-25** — any new subsystem (e.g. new carrier integration, new warehouse area) typically introduces 2–4 new terms worth appending.
