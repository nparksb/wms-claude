---
type: design
status: active
system: wms1
last_verified: 2026-04-27
verified_by: Claude (executor)
tags: [wms1, stock, inventory, unitload, reservation]
---

## TL;DR

- Describes the physical inventory layer in `v1/wms-api`: `Stockunit` (SKU qty + reservation on a container), `Unitload` (physical container at a location), and their immutable audit log entities `Stockrecord` / `UnitloadRecord`.
- Available qty = `amount − reservedamount`; reservations are managed exclusively through `StockunitBusinessService.changeReservedAmount` using a pessimistic row lock.
- `entityLock` (int) is the lifecycle signal — key values: `0` (normal), `2` (going-to-delete / Nirvana), `100` (picked for goods-out), `403` (not found in count), `405` (shipped/terminal).
- Zero-amount stock is soft-deleted by sending to the "Nirwana" unit load (`sendStockUnitToNirvana`); actual DB deletion is a separate cleanup job.
- `transferStockToUnitLoad` enforces lock-state checks unless `ignoreLock=true` (picking confirm and BOL packing bypass them); mixed-SKU transfers are blocked when `UnitloadType.differentStockAllowed=false`.
- v2 difference: v2 uses the same conceptual model but different entity names and JPA mappings — do not assume field parity.
- Read this doc before touching any code path that reads or writes stock quantities, reservations, unit-load placement, or `entityLock` (picking, replenishment, cycle count, BOL, transfers).

# WMS1 Stock Unit / Unit Load Design

Module-level design for the `Stockunit` / `Unitload` inventory layer in `v1/wms-api`.
Audience: engineers about to touch any code path that reads or writes stock quantities, reservations, or unit-load placement.

---

## §0 Module Inventory

| Class | Role | Covered in |
|---|---|---|
| `Stockunit` (entity) | Physical stock record: SKU + qty + reservation | §4 |
| `Unitload` (entity) | Physical container holding stock units | §4 |
| `Stockrecord` (entity) | Immutable audit log of every stock mutation | §4 |
| `UnitloadRecord` (entity) | Immutable audit log of every unit-load movement | §4 |
| `PickingorderUnitload` (entity) | Tote/pallet assigned to a picking order | §4 |
| `UnitloadType` (entity) | Container type master (stockunitallowed, differentstockallowed) | §4 |
| `Itemunit` (entity) | SKU-level unit-of-measure definitions | §4 (out of scope for mutation flows) |
| `StockView` (entity/view) | Read-only stock summary view | §7 |
| `StockunitService` | User-facing mutation API (transfer, lock, adjust, label) | §2, §3 |
| `StockunitBusinessService` | Core mutation primitives (create, transfer, changeAmount, changeReservedAmount, sendToNirvana) | §2, §3 |
| `StockunitRepository` | JPA repo with native queries for stock queries | §7 |
| `StockrecordService` | Writes `Stockrecord` audit rows | §3 |
| `UnitloadBusinessService` | Unit-load placement primitives (sendToNirvana, transferToLocation, transferToCarrier) | §3 |
| `UnitloadService` | Unit-load creation | §3 |
| `ReplenishmentOrderMaintenanceService` | Re-evaluates open replenishment orders after stock moves | §6 |
| `PickingorderBusinessService` | Calls `changeReservedAmount` + `transferStockToUnitLoad` at pick-confirm | §6 |
| `MobileReplenishService` | Calls `changeReservedAmount` twice in `finishReplenishmentOrderInternal` to clear source reservation (L420, L424) — rebinds return value (260427 fix) | §6 |
| `ReleaseOrderJobService` | Calls `changeReservedAmount` in `createPickingForOrder` for fixed-assignment positions (L473) — rebinds return value (260427 fix) | §6 |
| `ReplenishorderService` | Calls `changeReservedAmount` on redirect/cancel | §6 |
| `ReplenishGeneratorService` | Calls `changeReservedAmount` when creating replenishment orders | §6 |
| `BillofladingService` | Calls `transferStockToUnitLoad` to move stock onto parcels at BOL close | §6 |
| `CyclecountService` | Reads `getStockUnitsBySkuSetAndAreaSetAndStates` for count scope | §6 |
| `WmsConstants.BusinessObjectLockState` | Integer lock-state constants on `entityLock` field | §5 |
| `WmsConstants.StockRecordType` | String type constants written to `Stockrecord.type` | §5 |
| `WmsConstants.CODE_*` | Activity code strings threaded through every mutation | §5 |
| `StockunitBusinessServiceUnitTest` | 27 unit tests | §10 |
| `StockunitServiceUnitTest` | 22 unit tests | §10 |
| `StockunitBusinessServiceConcurrencyIT` | 2 concurrency integration tests | §10 |

---

## §1 Purpose

### What it does

The stock unit / unit load subsystem is the **source of truth for physical inventory** in WMS1.

- A **`Stockunit`** records that a specific SKU (`itemdata_id`) for a specific client (`client_id`) is physically located on a container (`unitload_id`) in some quantity (`amount`). The `reservedamount` field tracks how much of that quantity is already committed to open orders — the available quantity is always `amount − reservedamount`.
- A **`Unitload`** is a physical container (box, tote, pallet, cart …) sitting at a named storage location (`storagelocation_id`). Containers can be nested: a box can sit on a pallet via `carrierunitload_id`.
- Every mutation writes an immutable audit row to `Stockrecord` (stock moves) or `UnitloadRecord` (container moves).

### What it deliberately does NOT do

- No cross-client stock merging — each `Stockunit` belongs to exactly one client.
- No soft-delete — zero-amount stock units are sent to the "Nirwana" unit load and marked `GOING_TO_DELETE (2)`; actual DB deletion is handled by a separate cleanup job.
- No optimistic-lock retry in the business layer — `changeReservedAmount` uses a pessimistic lock (`findByIdForUpdate`) and throws `FacadeException` on contention.
- No multi-SKU merging — `transferStockToUnitLoad` rejects mixed-SKU transfers when `UnitloadType.differentStockAllowed = false`.
- No bulk write above safe chunk sizes — `updateEntityLockByUnitloadIds` is called in chunks of 500 by `BillofladingService`.

---

## §2 Public API / Contract

All methods throw `BusinessException` (user-facing, i18n-ready) or `FacadeException` (system-level, keyed messages) unless noted.

### `StockunitService` — user-facing API

| Method | Signature summary | `@Transactional` | Throws | Notes |
|---|---|---|---|---|
| `create` | `(clientId, unitLoadId, itemDataId, amount) → Stockunit` | No | — | Low-level raw create; no `Stockrecord` written. Used only in legacy/import paths. |
| `transferStock` | `(stockUnit, amountToTransfer, isTransferToExistingContainer, locationName, unitLoadLabelId, comment, printLabel)` | Yes (method-level) | B, F | Orchestrates all manual split/transfer flows. Calls `stockunitBusinessService.transferStockToUnitLoad` internally. Triggers `replenishmentOrderMaintenanceService.recalculateForItem` after every transfer. |
| `setLockOnHold` | `(stockUnit, comment, principal) → Stockunit` | No | B, F | Sets `entityLock = ON_HOLD (104)`. Guards: stock must be `NOT_LOCKED (0)`, unit load unlocked, location unlocked, location not a flowbin, single SU on unit load, unit load not on a carrier. |
| `setLockDamaged` | `(stockUnit, amount, comment, printLabel, principal) → Stockunit` | No | B, F | Transfers `amount` to a new unit load at location "Damaged", sets `entityLock = QUALITY_FAULT (103)`. Only allowed when source is `NOT_LOCKED`. |
| `adjustAmount` | `(stockUnit, amount, comment) → Stockunit` | No | F, B | Sets absolute quantity. Blocked on `SHIPPED` or `GOING_TO_DELETE`. Delegates to `changeAmount`. Sends OMS notification deferred to commit. |
| `adjustReservedAmount` | `(stockUnit, reservedAmount, comment) → Stockunit` | No | F, B | Sets absolute reserved amount. Blocked if picking already `STARTED`. Deliberately does NOT trigger replenishment recalculation (see comment at line 447). |
| `removeLock` | `(stockUnitId, comment, principal) → Stockunit` | No | B | Clears `entityLock` back to `NOT_LOCKED`. Only works for `QUALITY_FAULT` and `ON_HOLD`. Blocked on flowbin locations. |
| `getStockunitDetails` | `(id) → Map<String, Object>` | No | B | Read-only detail view used by UI. |
| `createCaseLabel` | `(unitLoad, stockUnit, warehouseName) → byte[]` | No | B | Generates ZPL/case label bytes for printing. |
| `createCaseLabelMultiStock` | `(unitLoad, warehouseName, amount, clientName) → byte[]` | No | — | Multi-SKU variant of case label. |

**B** = `BusinessException`, **F** = `FacadeException`

### `StockunitBusinessService` — mutation primitives

| Method | Signature summary | `@Transactional` | Notes |
|---|---|---|---|
| `createStockUnit` | `(client, item, amount, recordZeroAmount, unitload, activityCode, orderNumber) → Stockunit` | No | Creates SU + writes `STOCK_CREATED` `Stockrecord`. Called by receiving, cycle count, replenishment. |
| `transferStockToUnitLoad` | `(sourceStockunit, destinationUnitload, amount, activityCode, orderNumber, comment, ignoreLock, removeUnitLoadIfEmpty) → Stockunit` | Yes (method-level) | Core transfer primitive. If same SKU exists on dest, merges amounts. If source becomes 0 and no FLA, sends source SU to Nirvana and optionally sends source unit load to Nirvana. |
| `sendStockUnitToNirvana` | `(staleStockUnit, activityCode, orderNumber, comment)` | No | Zeroes amount then moves SU to Nirvana unit load, sets `GOING_TO_DELETE (2)`. Guard: throws if `reservedamount > 0`. |
| `changeAmount` | `(stockUnit, amount, activityCode, orderNumber, comment) → Stockunit` | No | Sets absolute amount. Guard: cannot reduce below `reservedamount`. Writes `STOCK_ALTERED` record. |
| `changeReservedAmount` | `(staleStockUnit, amount, zeroIfNegative, activityCode, orderNumber, comment) → Stockunit` | Yes (method-level) | **Pessimistic lock** (`findByIdForUpdate`). Detaches stale instance from L1 cache before lock to avoid `StaleObjectStateException` (SBDEV-1710 fix). Positive `amount` = reserve more; negative = release. `zeroIfNegative=true` clamps to 0 rather than throwing. **Caller contract: the input reference is detached and stale after the call returns — callers MUST rebind the local variable to the return value** (`su = changeReservedAmount(su, …)`). Failure to rebind causes subsequent `getAvailableamount()` reads to use the frozen pre-lock snapshot, producing incorrect availability checks (260427 bug — `MobileReplenishService` L420/L424, `ReleaseOrderJobService` L473). |

---

## §3 Key Classes and Services

```
StockunitService          (orchestration, user-facing)
  └─► StockunitBusinessService   (primitives: create, transfer, changeAmount, changeReservedAmount, nirvana)
        └─► StockrecordService         (writes Stockrecord audit rows)
        └─► UnitloadBusinessService    (sendToNirvana, transferToLocation, transferToCarrier)
  └─► UnitloadService            (createUnitload)
  └─► ReplenishmentOrderMaintenanceService  (recalculateForItem after every stock transfer)
  └─► MessageService             (OMS notification via OmsNotificationHelper.deferToCommit)
  └─► PrintService               (CUPS label printing)
  └─► AccessService              (permission checks, e.g. WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)
  └─► FixLocationAssignmentService / Repository  (flowbin assignment enforcement)
```

**Transaction boundary note (v1):** `StockunitService` has no class-level `@Transactional`. Only `transferStock` (line 106) is annotated at the method level. `StockunitBusinessService.transferStockToUnitLoad` and `changeReservedAmount` carry their own `@Transactional`. This means callers of `setLockDamaged`, `adjustAmount`, `removeLock` etc. are NOT wrapped in an outer transaction — each sub-call commits independently. A failure mid-way through `setLockDamaged` (after the unit-load is created but before the entity lock is set) leaves an orphaned unit load.

---

## §4 Data Model

### Entity Relationship Sketch

```
Location  1 ──< N  Unitload  (storagelocation_id)
Unitload  1 ──< N  Unitload  (carrierunitload_id — nesting: box on pallet)
Unitload  1 ──< N  Stockunit (unitload_id)
Itemdata  1 ──< N  Stockunit (itemdata_id)
Client    1 ──< N  Stockunit (client_id)
Client    1 ──< N  Unitload  (client_id)
UnitloadType 1 ──< N Unitload (type_id)
Stockunit 1 ──< N  Stockrecord (via fromstockunitidentity / tostockunitidentity — string FK!)
Unitload  1 ──< N  UnitloadRecord (via label — string FK!)
Pickingorder 1 ──< N PickingorderUnitload (pickingorder_id)
Unitload  1 ──< 1  PickingorderUnitload (unitload_id — nullable)
```

### `stockunit` table

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `bigint` | PK | Sequence via `seqentities` |
| `amount` | `numeric(17,4)` | NOT NULL | Physical quantity on hand |
| `reservedamount` | `numeric(17,4)` | nullable, default 0 | Quantity committed to open orders |
| `entity_lock` | `integer` | nullable | See `BusinessObjectLockState` §5 |
| `client_id` | `bigint` | NOT NULL, FK → client | |
| `itemdata_id` | `bigint` | NOT NULL, FK → itemdata | |
| `unitload_id` | `bigint` | NOT NULL, FK → unitload | The container holding this stock |
| `additionalcontent` | `varchar(255)` | nullable | Free-text comment (set on lock operations) |
| `version` | `integer` | NOT NULL | JPA `@Version` — optimistic lock |
| `created` / `modified` | `timestamp` | auditing | Set by `AuditingEntityListener` |

**Computed (transient):** `getAvailableamount() = amount − reservedamount` — not persisted, calculated in-memory.

### `unitload` table

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `bigint` | PK | |
| `labelid` | `varchar(255)` | NOT NULL, unique | Human-readable barcode / scan label |
| `client_id` | `bigint` | NOT NULL | |
| `type_id` | `bigint` | FK → unitload_type | Controls what stock is allowed |
| `storagelocation_id` | `bigint` | NOT NULL, FK → location | Current physical location |
| `carrierunitload_id` | `bigint` | nullable, FK → unitload (self) | Non-null when this container is on a pallet |
| `boxtype_id` | `bigint` | nullable, FK → boxtype | Box dimensions |
| `shippingmethod_id` | `bigint` | nullable | |
| `entity_lock` | `integer` | nullable | Same `BusinessObjectLockState` as stockunit |
| `version` | `integer` | NOT NULL | `@Version` |

### `stockrecord` table

Immutable audit log. Every call to `StockrecordService.record*` inserts one row; nothing ever updates it.

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint` | PK |
| `type` | `varchar(255)` | `StockRecordType` constant (see §5) |
| `activitycode` | `varchar(255)` | `CODE_*` constant (see §5) |
| `amount` | `numeric(17,4)` | Delta in this record |
| `amountstock` | `numeric(17,4)` | Stock balance after mutation |
| `reservedamountchange` | `numeric(17,4)` | Delta to reserved amount (if applicable) |
| `reservedamountstock` | `numeric(17,4)` | Reserved balance after mutation |
| `fromstockunitidentity` | `varchar` | Source SU id (string) |
| `tostockunitidentity` | `varchar` | Destination SU id (string) |
| `fromunitload` / `tounitload` | `varchar` | Unitload labelid strings |
| `fromstoragelocation` / `tostoragelocation` | `varchar` | Location name strings |
| `itemdata` | `varchar` | Item number string |
| `operator` | `varchar` | Username from `SecurityContextUtils.getUserName()` |
| `unitloadtype` | `varchar` | Unitload type name |
| `ordernumber` | `varchar` | Picking/replenish order number |
| `client_id` | `bigint` | |

### `unitload_record` table

Same audit pattern for container moves. Written by `UnitloadBusinessService`.

Key fields: `fromlocation`, `tolocation`, `label` (unitload labelid), `fromunitload`, `tounitload`, `recordtype`, `activitycode`, `operator`, `ordernumber`.

### `unitload_type` table (via `UnitloadType` entity)

Controls what stock operations are allowed on containers of this type.

| Field | Type | Notes |
|---|---|---|
| `name` | `varchar` | See unit load type names below |
| `stockunitallowed` | `boolean` | If false, `transferStockToUnitLoad` throws |
| `differentstockallowed` | `boolean` | If false, multi-SKU transfers throw |

**Known unit load type names** (`WmsConstants`):

| Constant | String value | Notes |
|---|---|---|
| `UNIT_LOAD_TYPE_DEFAULT` | `"Default"` | |
| `UNIT_LOAD_TYPE_PICKLOCATION` | `"PickLocation"` | Fixed pick-face containers |
| `UNIT_LOAD_TYPE_TOTE` | `"Tote"` | Outbound tote |
| `UNIT_LOAD_TYPE_PACKAGE` | `"Package"` | |
| `UNIT_LOAD_TYPE_BOX` | `"Case"` | Default for most stock; used for damaged stock |
| `UNIT_LOAD_TYPE_PALLET` | `"Pallet"` | Carrier container — stock goes on a child box |
| `UNIT_LOAD_TYPE_CART` | `"Cart"` | |

### `pickingorder_unitload` table

Associates a tote/pallet with a picking order. Not a stock-bearing table — it tracks the output container lifecycle.

| Column | Notes |
|---|---|
| `pickingorder_id` | FK → pickingorder |
| `unitload_id` | FK → unitload (nullable — tote assigned later) |
| `state` | `WmsConstants.State` integer (0=RAW initial) |
| `customerordernumber` | Denormalized for display |
| `historytote` / `positionindex` | Tote history and position |

---

## §5 State Model

### `Stockunit.entityLock` — `BusinessObjectLockState`

Stockunit has no "lifecycle state" column — the lifecycle is modeled via `entityLock` (int) on the `stockunit` row and separately on the `unitload` row.

| Value | Constant | Meaning | How set | How cleared |
|---|---|---|---|---|
| `0` | `NOT_LOCKED` | Normal, available stock | Default on creation | `removeLock()` |
| `2` | `GOING_TO_DELETE` | Zeroed, awaiting DB cleanup | `sendStockUnitToNirvana` | Not clearable |
| `100` | `PICKED_FOR_GOODSOUT` | On BOL parcel, awaiting shipment | `BillofladingService` (entity lock bulk update) | BOL cancel |
| `103` | `QUALITY_FAULT` | Damaged stock at "Damaged" location | `setLockDamaged()`, `transferStock` to Damaged | `removeLock()` |
| `104` | `ON_HOLD` | Manually quarantined | `setLockOnHold()` | `removeLock()` |
| `403` | `NOT_FOUND` | Missing from cycle count | `CyclecountService` | Cycle count resolution |
| `404` | `TRANSFER` | In-transit intercompany transfer | Transfer order flow | Transfer acceptance |
| `405` | `SHIPPED` | Shipped and closed | BOL close / shipping | Not clearable |

**Lock transitions that `transferStockToUnitLoad` respects:**
- When `ignoreLock = false`: throws if source SU, source UL, source location, destination SU, destination UL, or destination location is anything other than `NOT_LOCKED (0)`.
- When `ignoreLock = true` (used by picking confirm, BOL packing): lock checks are bypassed entirely.

### `StockRecordType` — audit record types

| Constant | String | When written |
|---|---|---|
| `STOCK_CREATED` | `"STOCK_CREATED"` | `createStockUnit` |
| `STOCK_SPLITTED` | `"STOCK_SPLITTED"` | Legacy split path |
| `STOCK_ALTERED` | `"STOCK_ALTERED"` | `changeAmount` |
| `STOCK_REMOVED` | `"STOCK_REMOVED"` | `StockrecordService.recordRemoval` |
| `STOCK_TRANSFERRED` | `"STOCK_TRANSFERRED"` | `StockrecordService.recordTransferStockUnit` |
| `STOCK_COUNTED` | `"STOCK_COUNTED"` | Cycle count adjustment |
| `STOCK_RESERVED_CHANGED` | `"STOCK_RESERVED_CHANGED"` | `changeReservedAmount` |

### `CODE_*` Activity codes (key ones)

| Constant | String | Context |
|---|---|---|
| `CODE_RECEIVING_REGULAR` | `"RECEIVING"` | Goods receipt |
| `CODE_RECEIVING_RETURN` | `"RETURN"` | Returns receipt |
| `CODE_STOCK_IMPORT` | `"STOCK_IMPORT"` | Import/initial stock load |
| `CODE_MANUAL_SPLIT` | — | Manual stock transfer/split via UI |
| `CODE_PICKING` | `"PICKING"` | Pick confirmation |
| `CODE_REPLENISHMENT` | `"REPLENISHMENT"` | Replenishment execution |
| `CODE_REPLENISHMENT_CREATED` | `"REPLENISHMENT_CREATED"` | Reserve on new replenishment order |
| `CODE_REPLENISHMENT_CANCELLED` | `"REPLENISHMENT_CANCELLED"` | Release on cancel |
| `CODE_REPLENISHMENT_SWITCHED` | `"REPLENISHMENT_SWITCHED"` | Source redirected |
| `CODE_CYCLE_COUNT` | `"CYCLE_COUNT"` | Cycle count adjustment |
| `CODE_SEND_TO_NIRVANA` | `"SEND_TO_NIRWANA"` | Nirvana / soft-delete |
| `CODE_DAMAGED` | `"DAMAGED"` | Damaged stock move |
| `CODE_ON_HOLD` | `"ON_HOLD"` | On-hold lock set |
| `CODE_MANAGE_INVENTORY` | `"MANAGE_INVENTORY"` | Manual quantity adjustment |
| `CODE_MANUAL_ADJUSTMENT` | — | Manual reserved amount adjustment |
| `CODE_SHIPPING` | `"SHIPPING"` | BOL / shipping |
| `CODE_TRUCK_LOADING` | `"TRUCKLOADING"` | Truck loading |

---

## §6 Reservation Model

### How reservations work

`Stockunit.reservedamount` is the exclusive field governing what is committed. Available = `amount − reservedamount`.

**Reserve (increase):**
```
changeReservedAmount(su, +qty, zeroIfNegative=false, activityCode, orderNumber, null)
```
Throws `FacadeException("CANNOT_RESERVE_MORE_THAN_AVAILABLE")` if `amount < reservedamount + qty`.

**Release (decrease):**
```
changeReservedAmount(su, -qty, zeroIfNegative=true, activityCode, orderNumber, null)
```
`zeroIfNegative=true` clamps to 0 to handle races where the same amount is released twice.

**Pessimistic lock:** `changeReservedAmount` always calls `findByIdForUpdate` inside its own `@Transactional`. The caller's possibly-stale entity is **detached from the L1 cache first** (SBDEV-1710 fix, `StockunitBusinessService:338`) to prevent `StaleObjectStateException` from Hibernate's version check during lock acquisition.

**Caller contract:** Because the input is detached, the return value is the only managed, up-to-date instance. **Every caller must rebind its local variable to the return value** — `su = changeReservedAmount(su, …)` — before reading `getAvailableamount()` or passing the reference to `transferStockToUnitLoad`. Not doing so silently reads the frozen pre-lock snapshot. Fixed in `MobileReplenishService` (L420, L424) and `ReleaseOrderJobService` (L473) by plan 260427. See regression tests `MobileReplenishServiceUnitTest` and `ReleaseOrderJobServiceUnitTest`.

**Race site:** If two threads call `changeReservedAmount` on the same SU concurrently, one will block waiting for the DB row lock. This is by design. The concurrency integration test (`StockunitBusinessServiceConcurrencyIT`) verifies this behaviour.

### Reservation lifecycle by subsystem

| Event | Method called | `amount` sign | `zeroIfNegative` | Activity code |
|---|---|---|---|---|
| Replenishment order created | `ReplenishGeneratorService` → `changeReservedAmount` | positive | false | `REPLENISHMENT_CREATED` |
| Replenishment source redirected (old) | `ReplenishorderService.updateSourceStockUnit` | negative | true | `REDIRECT_REPLENISHMENT_SOURCE` |
| Replenishment source redirected (new) | same method | positive | false | `REDIRECT_REPLENISHMENT_SOURCE` |
| Replenishment cancelled | `ReplenishorderService.cancelReplenishment` | negative | true | `REPLENISHMENT_CANCELLED` |
| Replenishment maintenance recalc | `ReplenishmentOrderMaintenanceService` | delta | true | `REPLENISHMENT` / `REPLENISHMENT_SWITCHED` / `REPLENISHMENT_CANCELLED` |
| Pick position confirmed | `PickingorderBusinessService.confirmPickPosition` | negative | true | `PICKING` |
| Manual reserved amount edit | `StockunitService.adjustReservedAmount` | delta | true | `MANUAL_ADJUSTMENT` |

**Key invariant:** `transferStockToUnitLoad` checks `amount − reservedamount >= amountToTransfer` at line 127 before any mutation. It will throw if you try to move more than the available (unreserved) amount.

---

## §7 Cross-Service Interactions

### Picking (`PickingorderBusinessService`)

At pick confirmation (`confirmPickPosition`, lines 268–306):

1. Load `Stockunit` by `pickingPosition.pickfromstockunitId`.
2. Call `changeReservedAmount(su, -amount, true, CODE_PICKING, …)` — releases the reservation.
3. Call `transferStockToUnitLoad(su, puUnitLoad, amount, CODE_PICKING, …, ignoreLock=true, removeUnitLoad=true)` — moves picked qty to the pick-up (PU) unit load.
4. The source SU may be sent to Nirvana if emptied; source unit load sent to Nirvana if also emptied.
5. `pickingPosition.pickfromstockunitId` is set to `null` after confirm.

**Note:** `ignoreLock=true` means picking bypasses all lock checks. A `QUALITY_FAULT` stock unit can technically be picked if a position was already assigned before the lock was set.

### Replenishment (`ReplenishGeneratorService`, `ReplenishorderService`, `ReplenishmentOrderMaintenanceService`)

**At replenishment order creation** (`ReplenishGeneratorService`):
1. Query `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` to find source candidates (unlocked, ordered by amount ASC, deep storage first).
2. Call `changeReservedAmount(source, requestedAmount, false, CODE_REPLENISHMENT_CREATED, …)` — reserves the qty.
3. Save replenishment order with `stockunit_id` pointing to the reserved SU.

**At replenishment completion** (`MobileReplenishService`):
- Source SU stock is transferred to the pick-face unit load.
- Reservation is released as part of the transfer.

**At replenishment maintenance** (`ReplenishmentOrderMaintenanceService.recalculateOrder`):
- Called after every `transferStock` via `triggerReplenishmentMaintenance` (StockunitService:594).
- Recalculates whether source stock is still sufficient; may switch source SU, adjust `reservedamount`, or cancel orders.

**At cancel** (`ReplenishorderService.cancelReplenishment`, line 197):
- `changeReservedAmount(sourceStock, -requestedAmount, true, CODE_REPLENISHMENT_CANCELLED, …)`.

### Bill of Lading (`BillofladingService`)

At BOL close (packing stock onto parcels):
1. For each unit load assigned to the BOL, load all `Stockunit` rows via `findByUnitloadId`.
2. Call `transferStockToUnitLoad(su, parcel, su.getAmount(), CODE_SHIPPING, …)` for each SU — moves qty to the parcel unit load.
3. Bulk-update `entity_lock = PICKED_FOR_GOODSOUT (100)` on all child unit loads via `updateEntityLockByUnitloadIds` in chunks of 500.

At BOL shipment:
- Entity lock is advanced to `SHIPPED (405)`.

### Cycle Count (`CyclecountService`)

- Uses `getStockUnitsBySkuSetAndAreaSetAndStates` to find stock units within the count scope.
- The query filters by `entity_lock NOT IN (SHIPPED=405, GOING_TO_DELETE=2)`.
- At count completion, `changeAmount` is called to reconcile differences; writes `STOCK_COUNTED` record.
- Discrepant units may be set to `NOT_FOUND (403)`.

---

## §8 Key Repositories and Critical Native Queries

### `StockunitRepository`

| Method | Type | Purpose |
|---|---|---|
| `getNextId()` | native | `select nextval('seqentities')` — shared sequence |
| `findByIdForUpdate(id)` | JPQL | Pessimistic lock; used exclusively by `changeReservedAmount` |
| `findByUnitloadId(unitloadId)` | Spring Data | All SUs on a container — most frequent call |
| `findByUnitloadIdIn(ids)` | native | Batch fetch by multiple unit load IDs |
| `updateEntityLockByUnitloadIds(lock, ids)` | native | Bulk lock update — called in 500-row chunks by BOL service |
| `getStockUnitsForReplenishment(itemDataId)` | native | SUs in pick areas, not locked, for replenishment source search |
| `getAvailableReplenishmentSources(itemDataId)` | native | Returns `(id, amount, reservedamount, unitload_id, locationId, locationName, areaId)` — used by replenishment generator |
| `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage(notLocked, itemDataId, useForDeepStorage)` | native | Source candidate search, ordered by `amount ASC, created ASC` |
| `getStockUnitsBySkuSetAndAreaSetAndStates(skuSet, areaSet, …)` | native | Cycle count scope query |
| `getStockUnitAvailable(stockUnitId)` | native | Sum available stock joining through location_area |
| `countByUnitloadId(unitloadId)` | native | Count SUs on a unit load |

**Native query sensitivity:** All `nativeQuery=true` queries bypass Hibernate's JPQL validation. They are sensitive to schema column renames — the column names `unitload_id`, `storagelocation_id`, `entity_lock`, `reservedamount`, `useforpicking`, `usefordeepstorage` are hardcoded strings.

### `UnitloadRepository`

Key method: `findByCarrierunitloadId(carrierunitloadId)` — used to check whether a pallet has child unit loads before sending the pallet to Nirvana.

---

## §9 Extension Points

- **`FixLocationAssignment`**: Controls whether a storage location has a fixed SKU assignment (flowbin). `StockunitBusinessService.transferStockToUnitLoad` checks for a `FixLocationAssignment` on the source location — if present, the source SU is never zeroed even when fully transferred (the unit load stays in place as a placeholder).
- **`UnitloadType.stockunitallowed` / `differentstockallowed`**: Adding a new unit load type with custom rules requires only setting these boolean fields — the transfer logic reads them at runtime.
- **`WmsConstants.CODE_*`**: Every stock mutation records an activity code. Adding a new workflow means defining a new `CODE_*` constant and passing it through to audit records.
- **`OmsNotificationHelper.deferToCommit`**: All OMS notifications (stock change messages) are deferred to transaction commit. New mutation paths should follow this pattern to avoid notifying OMS on rolled-back transactions.
- **`ReplenishmentOrderMaintenanceService.recalculateForItem`**: Called automatically after every `transferStock`. Any new mutation that changes available quantity should call `triggerReplenishmentMaintenance(itemDataId)` to keep replenishment orders consistent.

---

## §10 Error Handling

- `BusinessException`: User-facing. Message is shown directly in the UI. Example: `"Can not set stock to on hold, stock unit is locked!"`.
- `FacadeException`: Keyed messages (`STOCKUNIT_HAS_RESERVATION`, `CANNOT_RESERVE_MORE_THAN_AVAILABLE`, `STOCKUNIT_NOT_FOUND`). Resolved via `ResourceBundle`.
- Not-found handling: All repository lookups use `.orElseThrow(() → new BusinessException("X not found: " + id))` — never `NoSuchElementException` or NPE to the client.
- `StaleObjectStateException`: Prevented in `changeReservedAmount` by the L1-cache detach before pessimistic lock (SBDEV-1710). If seen in other mutation paths, apply the same pattern.

---

## §11 Testing Approach

### Test classes

| Class | Type | What it covers |
|---|---|---|
| `StockunitBusinessServiceUnitTest` | Unit (Mockito) | 27 tests: `transferStockToUnitLoad` (lock guards, mixed-stock, merge vs. new SU, nirvana path), `changeAmount`, `changeReservedAmount`, `sendStockUnitToNirvana`, `createStockUnit` |
| `StockunitServiceUnitTest` | Unit (Mockito) | 22 tests: `transferStock` (flowbin, pallet path, new container, full-unit-load move), `setLockOnHold`, `setLockDamaged`, `adjustAmount`, `adjustReservedAmount`, `removeLock` |
| `StockunitBusinessServiceConcurrencyIT` | Integration (Testcontainers) | 2 tests: concurrent `changeReservedAmount` calls on same SU — verifies pessimistic lock prevents double-reservation |

### Typical mock setup (unit tests)

```java
// Standard Mockito 3.3.3 pattern — no mockStatic
@Mock StockunitRepository stockunitRepository;
@Mock UnitloadRepository unitloadRepository;
@Mock StockrecordService stockrecordService;
@InjectMocks StockunitBusinessService sut;

// For SecurityContextUtils.getUserName() in createStockUnit:
SecurityContext ctx = SecurityContextHolder.createEmptyContext();
ctx.setAuthentication(new UsernamePasswordAuthenticationToken("testUser", null));
SecurityContextHolder.setContext(ctx);
```

### How to add a test for a new mutation

1. Add to `StockunitBusinessServiceUnitTest` for primitive-level logic.
2. Add to `StockunitServiceUnitTest` for orchestration (lock guards, replenishment trigger, OMS notification).
3. Add to `StockunitBusinessServiceConcurrencyIT` only if the change touches `changeReservedAmount` or introduces a new locked read.

---

## §12 Known Limitations

1. **No outer transaction on `setLockDamaged`**: The method creates a new unit load then calls `transferStockToUnitLoad`, but has no outer `@Transactional`. A failure between unit-load creation and SU lock assignment leaves an orphaned unit load at the Damaged location. A plan to add an outer transaction wrapper is a downstream fix. _(Downstream plan needs a verify script.)_

2. **`adjustReservedAmount` deliberately skips replenishment recalculation** (line 447 comment): This is by design — triggering recalculation would immediately re-reserve stock the user just released. However, it means replenishment orders sit over-reserved until the next scheduled recalculation cycle. Operators should be aware of this lag.

3. **`findByIdForUpdate` in `StockunitBusinessService` is JPQL, not `SELECT … FOR UPDATE`**: The current implementation (`@Query("SELECT s FROM Stockunit s WHERE s.id = :id")`) does not actually issue a database-level lock. The pessimistic locking relies on the surrounding `@Transactional` + Hibernate's `LockModeType`. Verify actual lock mode if upgrading Hibernate version. _(Investigate before any Spring Boot upgrade.)_

4. **String FK in `Stockrecord`**: `fromstockunitidentity` and `tostockunitidentity` are `varchar`, not `bigint` FKs. There is no referential integrity — a deleted stock unit leaves orphaned audit rows pointing to its old id as a string. Querying stockrecord history requires string-to-bigint casting in SQL.

5. **`create()` in `StockunitService` writes no `Stockrecord`** (line 90–104): The low-level `create()` method used in some import paths does not audit the creation. Only `createStockUnit()` in `StockunitBusinessService` writes a `STOCK_CREATED` record.

6. **`Itemdata.equals()` is used in `transferStockToUnitLoad:148`**: The `!destFirstItemdata.equals(sourceStockunitItemdata)` check at line 148 of `StockunitBusinessService` uses `.equals()` on `Itemdata`. Per v1 codebase rules, `.equals()` on entities without overridden `hashCode`/`equals` falls back to reference equality — two separately-fetched instances of the same entity will compare as not-equal, potentially falsely blocking a same-SKU transfer. The comment at line 147 (`// TODO First item <> other first item`) acknowledges this is known. _(Downstream plan needs a verify script.)_

7. **Potential dead code:** `StockunitService.create()` (the no-audit raw create at line 90) may only be called from legacy import paths. Zero grep hits from non-import callers as of this writing — verify before any refactor.

---

## §13 Related Docs

- `sbdocs/3-Resources/architecture/` — entity reports, state machine catalog, transaction/OSIV maps
- `v1/wms-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java` — all state/lock/code constants
- `v1/wms-api/src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` — replenishment recalc logic
- `v1/wms-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` — pick-confirm flow (lines 268–306)

---

## §14 Verification Log

| Date | Verified by | Method | Notes |
|---|---|---|---|
| 2026-04-27 | Claude executor | Full source read + grep | `StockunitService.java` (635 lines), `StockunitBusinessService.java` (369 lines), all 8 model entities, `WmsConstants.java` (lock states, record types, codes), 3 cross-service callers (Picking, Replenish, BOL), `StockunitRepository` query map, 3 test classes enumerated |
