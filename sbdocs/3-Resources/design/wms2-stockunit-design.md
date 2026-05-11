---
type: design
status: active
system: wms2
last_verified: 2026-05-10
verified_by: Claude (executor)
tags: [wms2, stock, inventory, unitload, reservation, caffeine, multi-tenant]
---

# WMS2 Stock Unit / Unit Load Design

Module-level design for the `Stockunit` / `Unitload` inventory layer in `v2/wms2-api`.
Audience: engineers about to touch any code path that reads or writes stock quantities, reservations, or unit-load placement.

See `wms1-stockunit-design.md` for the v1 baseline. §10 of this document covers differences.

---

## §0 Module Inventory

| Class | Role | Covered in |
|---|---|---|
| `Stockunit` (entity) | Physical stock record: SKU + qty + reservation | §4 |
| `Unitload` (entity) | Physical container holding stock units | §4 |
| `UnitloadRecord` (entity) | Immutable audit log of every unit-load movement | §4 |
| `UnitloadType` (entity) | Container type master (`stockunitallowed`, `differentstockallowed`, `unitloadallowed`, `onotherunitloadallowed`) | §4 |
| `PickingorderUnitload` (entity) | Tote/pallet assigned to a picking order | §4 |
| `StockunitService` | User-facing mutation API (transfer, lock, adjust, label) | §2, §3 |
| `StockunitBusinessService` | Core mutation primitives (create, transfer, changeAmount, changeReservedAmount, sendToNirvana) | §2, §3 |
| `UnitloadService` | Unit-load creation, deletion, label reprint | §2, §3 |
| `UnitloadBusinessService` | Unit-load placement primitives (sendToNirvana, transferToLocation, transferToCarrier) | §3 |
| `UnitloadRecordService` | Writes `UnitloadRecord` audit rows | §3 |
| `MobileMoveUnitloadService` | Mobile handheld unit-load move flow | §8 |
| `PickingorderUnitloadService` | Associates totes/pallets with picking orders | §8 |
| `StockunitRepository` | JPA repo with native queries for stock queries | §9 |
| `UnitloadRepository` | JPA repo with native queries for unit-load queries | §9 |
| `CacheConfig` | Caffeine L1 cache configuration (sysprops, clients, locations, itemdata) | §7 |
| `ItemdataService` | Cached SKU lookup (`@Cacheable("itemdata")`) — called frequently by stock mutations | §7 |
| `ReplenishmentOrderMaintenanceService` | Re-evaluates open replenishment orders after stock moves | §8 |
| `PickingorderBusinessService` | Calls `changeReservedAmount` + `transferStockToUnitLoad` at pick-confirm | §8 |
| `BillofladingService` | Calls `transferStockToUnitLoad` at BOL close | §8 |
| `MobileCycleCountService` | Reads stock units for cycle count scope | §8 |
| `WmsConstants.BusinessObjectLockState` | Integer lock-state constants on `entityLock` field | §5 |
| `WmsConstants.StockRecordType` | String type constants written to `Stockrecord.type` | §5 |
| `WmsConstants.CODE_*` | Activity code strings threaded through every mutation | §5 |

---

## §1 Purpose

### What it does

The stock unit / unit load subsystem is the **source of truth for physical inventory** in WMS2.

- A **`Stockunit`** records that a specific SKU (`itemdata_id`) for a specific client (`client_id`) is physically located on a container (`unitload_id`) in some quantity (`amount`). The `reservedamount` field tracks how much of that quantity is already committed to open orders — the available quantity is always `amount − reservedamount`.
- A **`Unitload`** is a physical container (box, tote, pallet, cart …) sitting at a named storage location (`storagelocation_id`). Containers can be nested: a box can sit on a pallet via `carrierunitload_id`.
- Every mutation writes an immutable audit row to `Stockrecord` (stock moves) or `UnitloadRecord` (container moves).

### What it deliberately does NOT do

- No cross-client stock merging — each `Stockunit` belongs to exactly one client.
- No soft-delete — zero-amount stock units are sent to the "Nirwana" unit load and marked `GOING_TO_DELETE (2)`; actual DB deletion is handled by a separate cleanup job.
- No multi-SKU merging — `transferStockToUnitLoad` rejects mixed-SKU transfers when `UnitloadType.differentStockAllowed = false`.
- No cross-replica cache coordination — Caffeine caches are JVM-local (see §7 for implications).

---

## §2 Public API / Contract

All methods throw `BusinessException` (user-facing) or `FacadeException` (system-keyed) unless noted.

### `StockunitService` — user-facing API

| Method | Signature summary | `@Transactional` | Throws | Notes |
|---|---|---|---|---|
| `create` | `(clientId, unitLoadId, itemDataId, amount) → Stockunit` | No | — | Low-level raw create; no `Stockrecord` written. Used only in import/legacy paths. |
| `transferStock` | `(stockUnit, amountToTransfer, isTransferToExistingContainer, locationName, unitLoadLabelId, comment, printLabel)` | Yes — `tenantTransactionManager` | B, F | Orchestrates all manual split/transfer flows. Handles pallet, flowbin, and plain location cases. Triggers `replenishmentOrderMaintenanceService.recalculateForItem` after every transfer. |
| `setLockOnHold` | `(stockUnit, comment, principal) → Stockunit` | No | B, F | Sets `entityLock = ON_HOLD (104)`. Guards: stock must be `NOT_LOCKED (0)`, unit load unlocked, location unlocked, location not a flowbin, single SU on unit load, unit load not on a carrier, amount > 0, no reserved amount. |
| `setLockDamaged` | `(stockUnit, amount, comment, printLabel, principal) → Stockunit` | No | B, F | Transfers `amount` to a new Box-type unit load at location "Damaged", sets `entityLock = QUALITY_FAULT (103)`. Only allowed when source is `NOT_LOCKED`. Clamps to `stockUnit.amount` if given amount exceeds it. Requires `availableamount >= amount`. |
| `adjustAmount` | `(stockUnit, amount, comment) → Stockunit` | No | F, B | Sets absolute quantity. Blocked on `SHIPPED` or `GOING_TO_DELETE`. Delegates to `changeAmount`. Sends OMS stock-change notification via `messageService`. Triggers replenishment recalculation. |
| `adjustReservedAmount` | `(stockUnit, reservedAmount, comment) → Stockunit` | Yes — `tenantTransactionManager` | F, B | Sets absolute reserved amount. Blocked if any linked picking position has `state >= STARTED`. Deliberately does NOT trigger replenishment recalculation. |
| `removeLock` | `(stockUnitId, comment, principal) → Stockunit` | No | B | Clears `entityLock` back to `NOT_LOCKED`. Only works for `QUALITY_FAULT` and `ON_HOLD`. Blocked on flowbin locations. `SHIPPED` and `GOING_TO_DELETE` throw. |
| `getStockunitDetails` | `(id) → Map<String, Object>` | No | — | Read-only detail map for UI. |
| `createCaseLabel` | `(unitLoad, stockUnit, warehouseName) → byte[]` | No | — | Generates ZPL case label bytes (single-SKU). |
| `createCaseLabelMultiStock` | `(unitLoad, warehouseName, amount, clientName) → byte[]` | No | — | Multi-SKU label variant. |

**B** = `BusinessException`, **F** = `FacadeException`

### `StockunitBusinessService` — mutation primitives

| Method | Signature summary | `@Transactional` | Notes |
|---|---|---|---|
| `createStockUnit` | `(client, item, amount, recordZeroAmount, unitload, activityCode, orderNumber) → Stockunit` | No | Creates SU + writes `STOCK_CREATED` `Stockrecord`. Two overloads: one auto-fetches location/type-name; second accepts pre-fetched values for loop efficiency (e.g. `receiveGoods`). |
| `transferStockToUnitLoad` | `(sourceStockunit, destinationUnitload, amount, activityCode, orderNumber, comment, ignoreLock, removeUnitLoadIfEmpty) → Stockunit` | Yes — `tenantTransactionManager` | Core transfer primitive. Two overloads: second accepts pre-fetched `FixLocationAssignment` for loop efficiency (e.g. `runClubLine`). If same SKU exists on dest, merges amounts. If source becomes 0 and no FLA, sends source SU to Nirvana and optionally sends source unit load to Nirvana. |
| `sendStockUnitToNirvana` | `(staleStockUnit, activityCode, orderNumber, comment)` | No | Zeroes amount then moves SU to Nirvana unit load, sets `GOING_TO_DELETE (2)`. Guard: throws `FacadeException("STOCKUNIT_HAS_RESERVATION")` if `reservedamount > 0`. Re-fetches SU from DB after `changeAmount` to avoid stale state. |
| `changeAmount` | `(staleStockUnit, amount, activityCode, orderNumber, comment) → Stockunit` | Yes — `tenantTransactionManager` | **Pessimistic lock** (`findByIdForUpdate`) + `entityManager.refresh()` to overwrite stale L1 cache entry. Sets absolute amount. Guard: cannot reduce below `reservedamount`. Writes `STOCK_ALTERED` record. |
| `changeReservedAmount` | `(staleStockUnit, amount, zeroIfNegative, activityCode, orderNumber, comment) → Stockunit` | Yes — `tenantTransactionManager` | **Pessimistic lock** + `entityManager.refresh()`. Positive `amount` = reserve more; negative = release. `zeroIfNegative=true` clamps to 0 rather than throwing. |

**Critical note on `@PersistenceContext`:** `StockunitBusinessService` declares `@PersistenceContext(unitName = "tenant")` and calls `entityManager.refresh(stockUnit)` in both `changeAmount` and `changeReservedAmount`. This is the v2 mechanism to expel the stale Hibernate L1 entry before acquiring a pessimistic row lock — without it, `findByIdForUpdate` would return the stale cached instance and allow double-reservation. This pattern replaces v1's explicit `entityManager.detach()` call.

### `UnitloadService` — unit-load lifecycle

| Method | Signature summary | Notes |
|---|---|---|
| `createUnitload` | multiple overloads: `(location, typeId, clientId, activityCode[, boxtypeId])` | Generates label via `basicService.generateNumber(EntityPrefixes.UNITLOAD, "UNIT_LOAD")`. Idempotent — returns existing if `labelid` already exists. Writes `UnitloadRecord`. Pre-fetched `spawnLocation` overload for loop efficiency. |
| `reprintLabel` | `(unitLoad, printerId)` | Checks `NOT_LOCKED` state, finds stock units, generates label, sends to CUPS printer. Falls back to default inbound printer if `printerId` is null. |
| `deleteUnitLoad` | `(unitLoad, comment, notifyCRM, principal)` | Sends all SUs to Nirvana, then sends unit load to Nirvana. Throws if children exist. |
| `deleteUnitLoadRecursive` | `(unitLoad, comment, notifyCRM, principal)` | Depth-first recursive delete of container tree. |
| `deleteUnitLoadRecursivePreRun` | `(unitLoad, unitLoadList)` | Validation pass — checks for self-reference cycles and existing `FixLocationAssignment` before destructive delete. |

---

## §3 Service Dependency Tree

```
StockunitService          (orchestration, user-facing — no @Transactional at class level)
  ├─► StockunitBusinessService   (primitives: create, transfer, changeAmount, changeReservedAmount, nirvana)
  │     ├─► StockrecordService         (writes Stockrecord audit rows)
  │     ├─► UnitloadBusinessService    (sendToNirvana, transferToLocation, transferToCarrier)
  │     └─► ItemdataService            (cached @Cacheable("itemdata"))
  ├─► UnitloadService            (createUnitload)
  │     ├─► UnitloadRecordService      (writes UnitloadRecord audit rows)
  │     └─► UnitloadBusinessService
  ├─► ReplenishmentOrderMaintenanceService  (recalculateForItem after every stock transfer)
  │     └─► [StockunitRepository, ReplenishorderRepository, …]
  ├─► MessageService             (OMS stock-change notifications via sendStockChangeMessage —
  │                                SBDEV-2214: delegates to StockChangeNotificationService →
  │                                OmsNotificationService.sendAfterCommit; POST is post-commit deferred)
  ├─► PrintService               (CUPS label printing)
  ├─► SyspropService             (cached @Cacheable("sysprops") — warehouse name for labels)
  ├─► AccessService              (permission checks, e.g. WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)
  └─► FixLocationAssignmentService / Repository  (flowbin assignment enforcement)

UnitloadBusinessService   (unit-load placement primitives)
  ├─► UnitloadRecordService
  ├─► LocationConstraintRepository  (type-based placement rules)
  ├─► FixLocationAssignmentRepository
  └─► OptimisticLockRetry          (v2 retry utility — used in transferUnitLoadToLocation carrier-clear)
```

**Transaction boundary note (v2):** `StockunitService` has no class-level `@Transactional`. Only `transferStock` (line 145) and `adjustReservedAmount` (line 434) carry method-level `@Transactional(value = "tenantTransactionManager")`. The primitives `changeAmount` and `changeReservedAmount` in `StockunitBusinessService` are individually transactional. Methods like `setLockDamaged`, `adjustAmount`, and `removeLock` are NOT wrapped in an outer transaction — each sub-call commits independently (same risk as v1: an orphaned unit load is possible if `setLockDamaged` fails between unit-load creation and SU lock assignment).

**Dual transaction manager:** All `@Transactional` annotations in this subsystem explicitly specify `value = "tenantTransactionManager"`. The `@Primary` transaction manager is the landlord TM — omitting `value` would silently route operations to the master config database. See `wms2-api/CLAUDE.md` for the full dual-TM rules.

---

## §4 Data Model

### Entity Relationship Sketch

```
Location     1 ──< N  Unitload       (storagelocation_id)
Unitload     1 ──< N  Unitload       (carrierunitload_id — nesting: box on pallet)
Unitload     1 ──< N  Stockunit      (unitload_id)
Itemdata     1 ──< N  Stockunit      (itemdata_id)
Client       1 ──< N  Stockunit      (client_id)
Client       1 ──< N  Unitload       (client_id)
UnitloadType 1 ──< N  Unitload       (type_id)
Stockunit    1 ──< N  Stockrecord    (via fromstockunitidentity / tostockunitidentity — string FK)
Unitload     1 ──< N  UnitloadRecord (via label — string FK)
Pickingorder 1 ──< N  PickingorderUnitload  (pickingorder_id)
Unitload     1 ──< 1  PickingorderUnitload  (unitload_id — nullable)
```

### `stockunit` table

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `bigint` | PK | Sequence via `seqentities` |
| `amount` | `numeric(17,4)` | NOT NULL, default 0 | Physical quantity on hand |
| `reservedamount` | `numeric(17,4)` | nullable, default 0 | Quantity committed to open orders |
| `entity_lock` | `integer` | nullable | See `BusinessObjectLockState` §5 |
| `client_id` | `bigint` | NOT NULL, FK → client | |
| `itemdata_id` | `bigint` | NOT NULL, FK → itemdata | |
| `unitload_id` | `bigint` | NOT NULL, FK → unitload | The container holding this stock |
| `additionalcontent` | `varchar(255)` | nullable | Free-text comment (set on lock operations) |
| `version` | `integer` | NOT NULL | JPA `@Version` — optimistic lock |
| `created` / `modified` | `timestamp` | auditing | Set by `AuditingEntityListener` |

**Computed (transient):** `getAvailableamount() = amount − reservedamount` — not persisted, calculated in-memory by the `@Transient` getter.

### `unitload` table

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `bigint` | PK | |
| `labelid` | `varchar(255)` | NOT NULL | Human-readable barcode / scan label. Prefixed `"UL"` for generated unit loads. Suffixed `"-X-{id}"` after Nirvana send. |
| `client_id` | `bigint` | NOT NULL | |
| `type_id` | `bigint` | FK → unitload_type | Controls what stock is allowed |
| `storagelocation_id` | `bigint` | NOT NULL, FK → location | Current physical location |
| `carrierunitload_id` | `bigint` | nullable, FK → unitload (self) | Non-null when this container is on a pallet |
| `boxtype_id` | `bigint` | nullable, FK → boxtype | Box dimensions |
| `shippingmethod_id` | `bigint` | nullable | |
| `entity_lock` | `integer` | nullable | Same `BusinessObjectLockState` as stockunit |
| `version` | `integer` | NOT NULL | `@Version` |

### `unitload_record` table

Immutable audit log for container moves. Written by `UnitloadRecordService`.

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint` | PK |
| `recordtype` | `varchar(255)` | `UnitloadRecordType` constant (CREATED, TRANSFERRED) |
| `activitycode` | `varchar(255)` | `CODE_*` constant |
| `fromlocation` / `tolocation` | `varchar` | Location name strings |
| `fromunitload` / `tounitload` | `varchar` | Unitload labelid strings |
| `label` | `varchar` | The moved unit load's labelid |
| `unitloadtype` | `varchar` | Unitload type name |
| `operator` | `varchar` | Username from `SecurityContextUtils.getUserName()` |
| `ordernumber` | `varchar` | Order reference |
| `client_id` | `bigint` | |

### `unitload_type` table (via `UnitloadType` entity)

Controls what stock operations are allowed on containers of this type.

| Field | Type | Notes |
|---|---|---|
| `name` | `varchar` | See unit load type names below |
| `stockunitallowed` | `boolean` | If false, `transferStockToUnitLoad` throws |
| `differentstockallowed` | `boolean` | If false, multi-SKU transfers throw |
| `unitloadallowed` | `boolean` | If false, no child unit loads allowed on this type |
| `onotherunitloadallowed` | `boolean` | If false, this type cannot be placed on a carrier |
| `depth` / `height` / `width` / `weight` / `volume` | `numeric` | Physical dimensions |

**Known unit load type names** (`WmsConstants`):

| Constant | String value | Notes |
|---|---|---|
| `UNIT_LOAD_TYPE_DEFAULT` | `"Default"` | Nirvana unit load type |
| `UNIT_LOAD_TYPE_PICKLOCATION` | `"PickLocation"` | Fixed pick-face containers |
| `UNIT_LOAD_TYPE_TOTE` | `"Tote"` | Outbound tote |
| `UNIT_LOAD_TYPE_PACKAGE` | `"Package"` | |
| `UNIT_LOAD_TYPE_BOX` | `"Case"` | Default for most stock; always used for damaged stock |
| `UNIT_LOAD_TYPE_PALLET` | `"Pallet"` | Carrier container — stock goes on a child box |
| `UNIT_LOAD_TYPE_CART` | `"Cart"` | |

### `pickingorder_unitload` table

Associates a tote/pallet with a picking order. Not a stock-bearing table.

| Column | Notes |
|---|---|
| `pickingorder_id` | FK → pickingorder |
| `unitload_id` | FK → unitload (nullable — tote assigned later) |
| `state` | `WmsConstants.State` integer |
| `customerordernumber` | Denormalized for display |
| `historytote` / `positionindex` | Tote history and position |

---

## §5 State Model

### `Stockunit.entityLock` / `Unitload.entityLock` — `BusinessObjectLockState`

Both `Stockunit` and `Unitload` share the same `BusinessObjectLockState` integer enum on their `entity_lock` column.

| Value | Constant | Meaning | How set | How cleared |
|---|---|---|---|---|
| `0` | `NOT_LOCKED` | Normal, available stock | Default on creation | `removeLock()` |
| `2` | `GOING_TO_DELETE` | Zeroed, awaiting DB cleanup | `sendStockUnitToNirvana` / `sendToNirvana` | Not clearable |
| `100` | `PICKED_FOR_GOODSOUT` | On BOL parcel, awaiting shipment | `BillofladingService` bulk update | BOL cancel |
| `103` | `QUALITY_FAULT` | Damaged stock at "Damaged" location | `setLockDamaged()`, `transferStock` to Damaged | `removeLock()` |
| `104` | `ON_HOLD` | Manually quarantined | `setLockOnHold()` | `removeLock()` |
| `403` | `NOT_FOUND` | Missing from cycle count | `MobileCycleCountService` | Cycle count resolution |
| `404` | `TRANSFER` | In-transit intercompany transfer | Transfer order flow | Transfer acceptance |
| `405` | `SHIPPED` | Shipped and closed | BOL close / shipping | Not clearable |

**Lock transitions that `transferStockToUnitLoad` respects:**
- When `ignoreLock = false`: throws `BusinessException` if source SU, source UL, source location, destination SU, destination UL, or destination location has any value other than `NOT_LOCKED (0)`.
- When `ignoreLock = true` (picking confirm, BOL packing): all lock checks are bypassed entirely.

**Lock propagation in `transferStock`:** When moving stock to the "Damaged" location and the source SU is `NOT_LOCKED`, the destination SU automatically gets `QUALITY_FAULT (103)`. When moving already-damaged stock from within the "Damaged" location, the destination SU preserves `QUALITY_FAULT` (requires `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` permission).

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

### `UnitloadRecordType` — unit-load audit types

| Constant | String | When written |
|---|---|---|
| `CREATED` | `"CREATED"` | `createUnitload` |
| `TRANSFERRED` | `"TRANSFERRED"` | `transferUnitLoadToLocation`, `transferUnitLoadToCarrier` |

### `CODE_*` Activity codes (key ones)

| Constant | String | Context |
|---|---|---|
| `CODE_RECEIVING_REGULAR` | `"RECEIVING"` | Goods receipt |
| `CODE_RECEIVING_RETURN` | `"RETURN"` | Returns receipt |
| `CODE_STOCK_IMPORT` | `"STOCK_IMPORT"` | Import/initial stock load |
| `CODE_MANUAL_SPLIT` | `"MANUAL_SPLIT"` | Manual stock transfer/split via UI |
| `CODE_MANUAL_TRANSFER` | `"MANUAL_TRANSFER"` | Manual full unit-load move |
| `CODE_PICKING` | `"PICKING"` | Pick confirmation |
| `CODE_REPLENISHMENT` | `"REPLENISHMENT"` | Replenishment execution |
| `CODE_REPLENISHMENT_CREATED` | `"REPLENISHMENT_CREATED"` | Reserve on new replenishment order |
| `CODE_REPLENISHMENT_CANCELLED` | `"REPLENISHMENT_CANCELLED"` | Release on cancel |
| `CODE_REPLENISHMENT_SWITCHED` | `"REPLENISHMENT_SWITCHED"` | Source redirected |
| `CODE_CYCLE_COUNT` | `"CYCLE_COUNT"` | Cycle count adjustment |
| `CODE_SEND_TO_NIRVANA` | `"SEND_TO_NIRWANA"` | Nirvana / soft-delete |
| `CODE_MANUAL_REMOVAL` | `"MANUAL_REMOVAL"` | Manual unit-load delete |
| `CODE_DAMAGED` | `"DAMAGED"` | Damaged stock move |
| `CODE_ON_HOLD` | `"ON_HOLD"` | On-hold lock set |
| `CODE_MANAGE_INVENTORY` | `"MANAGE_INVENTORY"` | Manual quantity adjustment |
| `CODE_MANUAL_ADJUSTMENT` | `"MANUAL_ADJUSTMENT"` | Manual reserved amount adjustment |
| `CODE_SHIPPING` | `"SHIPPING"` | BOL / shipping |
| `CODE_TRUCK_LOADING` | `"TRUCKLOADING"` | Truck loading |
| `CODE_TRANSFER` | `"TRANSFER"` | Intercompany transfer |

---

## §6 Reservation Model

### How reservations work

`Stockunit.reservedamount` is the exclusive field governing what is committed. Available = `amount − reservedamount` (transient `getAvailableamount()`).

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

**Pessimistic lock pattern (v2):**
```java
Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
    .orElseThrow(() -> new FacadeException("STOCKUNIT_NOT_FOUND", ...));
entityManager.refresh(stockUnit);   // evict stale L1 entry
```
`findByIdForUpdate` uses `@Lock(LockModeType.PESSIMISTIC_WRITE)` — this issues a `SELECT ... FOR UPDATE` at the DB level. The `entityManager.refresh()` call immediately after is the v2 mechanism to ensure Hibernate's L1 cache does not serve the stale pre-lock snapshot. This differs from v1 where `detach()` was used before the lock.

**Race site:** If two threads call `changeReservedAmount` on the same SU concurrently, one will block on the DB row lock. This is by design.

**`adjustReservedAmount` intentionally skips replenishment recalculation** (comment at `StockunitService:455`): Triggering recalculation would immediately re-reserve the stock the user just released. The scheduled `ReplenishOrderJob` re-evaluates on its next cycle.

### Reservation lifecycle by subsystem

| Event | Method called | `amount` sign | `zeroIfNegative` | Activity code |
|---|---|---|---|---|
| Replenishment order created | `ReplenishGeneratorService` → `changeReservedAmount` | positive | false | `REPLENISHMENT_CREATED` |
| Replenishment source redirected (old source) | `ReplenishorderService` | negative | true | `REPLENISHMENT_SWITCHED` |
| Replenishment source redirected (new source) | same | positive | false | `REPLENISHMENT_SWITCHED` |
| Replenishment cancelled | `ReplenishorderService` | negative | true | `REPLENISHMENT_CANCELLED` |
| Replenishment maintenance recalc | `ReplenishmentOrderMaintenanceService` | delta | true | `REPLENISHMENT` / `REPLENISHMENT_SWITCHED` / `REPLENISHMENT_CANCELLED` |
| Pick position confirmed | `PickingorderBusinessService.confirmPickPosition` | negative | true | `PICKING` |
| Manual reserved amount edit | `StockunitService.adjustReservedAmount` | delta | true | `MANUAL_ADJUSTMENT` |

**Key invariant:** `transferStockToUnitLoad` checks `amount − reservedamount >= amountToTransfer` before any mutation and throws `BusinessException` if violated.

---

## §7 Caffeine Cache Layer

### Overview

WMS2 uses Spring Cache with Caffeine as the L1 backing store. Configuration lives entirely in `CacheConfig` (`net.aim_ai.wms.config`). All caches are JVM-local — there is no distributed cache layer. A comment in `CacheConfig` explicitly notes: _"TTLs reduced for multi-replica safety — local Caffeine caches become stale across replicas. Plan Redis migration for full cross-replica consistency."_

### Cache registry

| Cache name | Max entries | TTL (expireAfterAccess) | What is cached | Key pattern |
|---|---|---|---|---|
| `sysprops` | 200 | 5 minutes | `Sysprop` values by syskey | `{facilityCode}:{syskey}` |
| `clients` | 100 | 5 minutes | `Client` entities by client number or system marker | `{facilityCode}:{clientNumber}` or `{facilityCode}:SYSTEM` |
| `locations` | 2000 | 5 minutes | `Location` entities by name | `{facilityCode}:{name}` |
| `itemdata` | 3000 | 5 minutes | `Itemdata` entities by id or by `(clientId, itemNr)` | `{facilityCode}:id:{id}` or `{facilityCode}:{clientId}:{itemNr}` |

All caches use `expireAfterAccess` (not `expireAfterWrite`). An entry that is accessed continuously will never expire — it is only evicted if not accessed within the TTL window.

`recordStats()` is enabled on every cache — metrics are exported via Micrometer/Actuator.

### Multi-tenant cache key isolation

Every cache key is prefixed with `TenantContext.getCurrentTenant()?.getFacilityCode()`. This 4-character facility code is the isolation boundary. If `facilityCode` is null (bootstrap / async context), the key prefix becomes `null:` — this is a known risk in scheduled jobs that run without tenant context.

**Example key construction (SpEL):**
```java
@Cacheable(value = "itemdata",
    key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':id:' + #id")
```

### Eviction triggers

| Cache | Eviction trigger | Where |
|---|---|---|
| `itemdata` | `@CacheEvict(allEntries = true)` | `ItemDataController.updateItemData`, `FileImportController.importItemData`, `SkuRestController.createSku`, `SkuRestController.updateSku`, `ItemdataService.evictItemdataCache` |
| `sysprops` | `@CacheEvict` by key | `SyspropService.updateSysprop`, `SystemPropertyController.updateSystemProperty` |
| `locations` | `@CacheEvict` by key | `LocationService.updateLocation` |
| `clients` | No explicit eviction observed | Clients rarely change; TTL-based expiry is the only eviction path |

**Important:** `itemdata` uses `allEntries = true` on every write — the entire cache is flushed across all tenants on any SKU update. This is safe (correctness over efficiency) but means a burst of SKU imports causes repeated full-cache rebuilds.

### Impact on the stock mutation path

The stock mutation path calls `ItemdataService.getById()` in multiple hot spots:

- `StockunitBusinessService.transferStockToUnitLoad` — looks up `Itemdata` for both source and destination SUs on every merge.
- `StockunitService.setLockDamaged` — looks up `Itemdata` to set `boxtypeId` on the new damaged unit load.
- `StockunitService.adjustAmount` — looks up `Itemdata` for the OMS stock-change notification DTO.
- `UnitloadService.deleteUnitLoad` — looks up `Itemdata` for each SU being sent to Nirvana.

All of these are served from the `itemdata` Caffeine cache after the first DB fetch. A cache miss results in a direct `itemdataRepository.findById()` call against the tenant DB.

**No `Stockunit` or `Unitload` entities are cached.** All stock mutation reads (`findById`, `findByUnitloadId`, etc.) go directly to the DB on every call. The Hibernate L1 cache (first-level, per-transaction) provides intra-transaction deduplication only.

### Caffeine in `KeycloakService`

`KeycloakService` maintains a separate Caffeine cache (`Cache<String, UserRepresentation>`) instantiated directly (not via Spring Cache):
```java
private final Cache<String, UserRepresentation> userCache = Caffeine.newBuilder()
    .expireAfterAccess(5, TimeUnit.MINUTES)
    .maximumSize(500)
    .build();
```
This is not registered in `CacheConfig` and is not visible to Spring's `CacheManager`. It is unrelated to the stock mutation path.

---

## §8 Cross-Service Interactions

### Picking (`PickingorderBusinessService`)

At pick confirmation (`confirmPickPosition`):

1. Load `Stockunit` by `pickingPosition.pickfromstockunitId`.
2. Call `changeReservedAmount(su, -amount, true, CODE_PICKING, …)` — releases the reservation.
3. Call `transferStockToUnitLoad(su, puUnitLoad, amount, CODE_PICKING, …, ignoreLock=true, removeUnitLoad=true)` — moves picked qty to the pick-up (PU) unit load.
4. Source SU may be sent to Nirvana if emptied; source unit load sent to Nirvana if also emptied.
5. `pickingPosition.pickfromstockunitId` is set to `null` after confirm.

`ignoreLock=true` means picking bypasses all lock checks. A `QUALITY_FAULT` SU can technically be picked if a position was assigned before the lock was set.

### Replenishment (`ReplenishGeneratorService`, `ReplenishorderService`, `ReplenishmentOrderMaintenanceService`)

**At replenishment order creation:**
1. Query `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` — source candidates (unlocked, unreserved, ordered by amount ASC then created ASC).
2. Call `changeReservedAmount(source, requestedAmount, false, CODE_REPLENISHMENT_CREATED, …)`.
3. Save replenishment order with `stockunit_id` pointing to the reserved SU.

**At replenishment completion (`MobileReplenishService`):**
- Source SU stock is transferred to the pick-face unit load; reservation is released as part of the transfer.

**At replenishment maintenance (`ReplenishmentOrderMaintenanceService.recalculateForItem`):**
- Called automatically after every `transferStock` via `StockunitService.triggerReplenishmentMaintenance(itemDataId)`.
- May switch source SU, adjust `reservedamount`, or cancel orders.
- Called with a try/catch in `triggerReplenishmentMaintenance` — failures are logged as warnings and do not roll back the stock transfer.

**At cancel:**
- `changeReservedAmount(sourceStock, -requestedAmount, true, CODE_REPLENISHMENT_CANCELLED, …)`.

### Bill of Lading (`BillofladingService`)

At BOL close:
1. For each unit load assigned to the BOL, load all `Stockunit` rows via `findByUnitloadId`.
2. Call `transferStockToUnitLoad(su, parcel, su.getAmount(), CODE_SHIPPING, …)` for each SU.
3. Entity locks on child unit loads are advanced to `PICKED_FOR_GOODSOUT (100)`.

At BOL shipment: entity lock advanced to `SHIPPED (405)`.

### Cycle Count (`MobileCycleCountService`)

- Uses `getStockUnitsBySkuSetAndAreaSetAndStates` to find SUs within count scope.
- Query filters `entity_lock NOT IN (SHIPPED=405, GOING_TO_DELETE=2)`.
- Discrepant units may be set to `NOT_FOUND (403)`.
- At count completion, `changeAmount` is called to reconcile differences; writes `STOCK_COUNTED` record.

### Mobile Move Unitload (`MobileMoveUnitloadService`, `MoveUnitloadController`)

- Calls `UnitloadBusinessService.transferUnitLoadToLocation` for standard moves.
- Calls `UnitloadBusinessService.transferUnitLoadToCarrier` for pallet palletising flows.
- Uses `OptimisticLockRetry` via `UnitloadBusinessService` when clearing `carrierunitload_id` under contention.

### Transfer Orders (`TransferOrderService`, `MobileTransferOrderService`)

- Sets `entityLock = TRANSFER (404)` on SUs in transit between warehouses.
- Uses `CODE_TRANSFER` activity code.

---

## §9 Repository Native Queries

### `StockunitRepository`

| Method | Type | Purpose |
|---|---|---|
| `findByIdForUpdate(id)` | JPQL + `@Lock(PESSIMISTIC_WRITE)` | Row-level lock for `changeAmount` / `changeReservedAmount` |
| `findByUnitloadId(unitloadId)` | Spring Data | All SUs on a container — most frequent call |
| `findByUnitloadIdAndItemdataId` | JPQL | Same-SKU lookup in `transferStockToUnitLoad` |
| `findByItemdataId` | Spring Data | All SUs for a SKU |
| `findByUnitloadIdIn` | JPQL | Batch fetch by multiple unit load IDs |
| `getAmountAvailable` | native | Sum stock qty by location and itemdata |
| `getStockAndReservedForLocation` | native | Total + reserved qty at a specific location (all locks = 0) |
| `getStockAndReservedForPickingAreas` | native | Total + reserved qty in picking areas (all locks = 0, `useforpicking = true`) |
| `getStockUnitsByItemDataId` | native | Unlocked SUs in pick areas, ordered by amount DESC |
| `getStockUnitsByItemDataIdForUpdate` | native | Same with `FOR UPDATE OF stockunit` |
| `getListByStorageLocationId` | native | `(itemdataId, amount)` pairs by location |
| `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` | native | Source candidates for replenishment (unreserved, `useForReplenish = true`, ordered by amount ASC, created ASC) |
| `getStockUnitsForReplenishment` | native | Unlocked, unreserved SUs in replenish areas, ordered by labelid ASC |
| `getStockUnitInfoForReplenishment` | native | View with `(id, amount, unitLoadLabelId, locationName)` for replenishment UI |
| `getAvailableReplenishmentSources` | native | `(id, amount, reservedamount, unitload_id, locationId, locationName, areaId)` — amount > reservedamount |
| `getStockUnitAvailable` | native | Total and reserved for an itemdata in pick areas |
| `getStockUnitsBySkuSetAndAreaSetAndStates` | native | Cycle count scope query — lock NOT IN (`SHIPPED`, `GOING_TO_DELETE`) |
| `getDetailViewByKeyword` | native | Paginated search UI — lock != 405 |
| `getByUnitLoadLabelId` | native | Single SU by unit load label |
| `getStockUnitItemIdAndNotLocked` | native | Unlocked SUs for transfer areas (`usefortransfer = true`) |
| `getListByLocationIdWithClient` | native | SUs at a location filtered by client |
| `getListByLocationId` | native | All SUs at a location |

**Native query sensitivity:** All `nativeQuery=true` queries hardcode column names (`unitload_id`, `storagelocation_id`, `entity_lock`, `reservedamount`, `useforpicking`, `usefordeepstorage`, `useforreplenish`, `usefortransfer`). Schema column renames break these silently.

### `UnitloadRepository`

| Method | Type | Purpose |
|---|---|---|
| `findByIdForUpdate` | JPQL + `@Lock(PESSIMISTIC_WRITE)` | Row-level lock |
| `findByStoragelocationId` | Spring Data | All ULs at a location |
| `findByCarrierunitloadId` | Spring Data | Children of a pallet / carrier |
| `findByLabelid` | Spring Data | Lookup by scan barcode |
| `findByLabelidIgnoreCase` | native | Case-insensitive barcode lookup (LIMIT 1) |
| `findEmptyByStoragelocationId` | native | ULs with no SUs and no child ULs |
| `findDetailsByCarrierunitloadId` | native | `(labelid, type.name, entity_lock)` for pallet children |
| `findStockUnitDetailByUnitLoadId` | native | `(id, name, itemNr, amount, reservedAmount)` — children detail view |
| `findByTypeNameAndLocatioNamesIn` | native | ULs of a given type at specific locations |
| `findByLabelidIn` | JPQL | Batch fetch by set of labelids |
| `findCountByCarrierunitloadId` | native | Count ULs without carrier (or with specific carrier) |
| `getBatchLocationsByItemIdAndLaneName` | native | ULs with a given SKU at a staging lane |
| `getBatchLocationsByItemIdAndNamedLocations` | native | ULs with SKU at staging lanes or clearing |
| `findUnitloadsByItemDataIdForReplenish` | native | Distinct ULs with available stock in replenish areas |
| `getDetailViewByKeyword` | native | Paginated search UI — lock != 405 |

---

## §10 v1 vs v2 Differences

| Aspect | v1 (wms1-api) | v2 (wms2-api) |
|---|---|---|
| **Java / Spring Boot** | Java 8, Spring Boot 2.3.7 | Java 21, Spring Boot 3.5.x |
| **Jakarta EE** | `javax.persistence.*` | `jakarta.persistence.*` |
| **L1 cache stale-entity fix** | `entityManager.detach(staleEntity)` before `findByIdForUpdate` | `entityManager.refresh(locked)` after `findByIdForUpdate` |
| **L2 / application cache** | None (no Caffeine) | Caffeine L1 on `sysprops`, `clients`, `locations`, `itemdata` (see §7) |
| **Multi-tenant datasource** | HTTP header routing (`tenant_name` + `facility_code`) | Same routing model; explicit `value = "tenantTransactionManager"` required on all `@Transactional` (dual-TM architecture) |
| **`@Transactional` default** | `@Primary` = landlord TM same risk as v2 | `@Primary` = landlord TM — omitting `value` silently breaks tenant writes |
| **Optimistic lock retry** | None in stock path | `OptimisticLockRetry` utility used in `UnitloadBusinessService.transferUnitLoadToLocation` when clearing `carrierunitload_id` |
| **`createStockUnit` overload** | Single signature | v2 adds pre-fetched-location overload to avoid repeated DB lookups in batch receives |
| **`transferStockToUnitLoad` overload** | Single signature | v2 adds pre-fetched-`FixLocationAssignment` overload for club-line batch efficiency |
| **`createUnitload` overload** | Single signature | v2 adds pre-fetched-`spawnLocation` overload |
| **`UnitloadBusinessService` initialization** | `@PostConstruct` runs synchronously | v2 wraps in tenant-context guard: skips initialization during bootstrap (`BOOTSTRAP` facility code); `ensureInitialized()` lazy-re-init pattern |
| **Nirvana unit-load labelid after send** | Unchanged | v2 appends `"-X-{id}"` suffix to avoid labelid collision on re-use |
| **Scheduled jobs tenant context** | Must be set explicitly | Same — jobs run outside HTTP scope, must set/clear `TenantContext` manually |
| **`StockView` entity** | Present (read-only view) | Not observed in v2 source — may be replaced by repository projections |
| **`Itemunit` entity** | Present | Not observed in v2 source as part of stock mutation path |
| **`updateEntityLockByUnitloadIds` bulk update** | Present (500-row chunks, BOL) | Not found in v2 `StockunitRepository`; BOL bulk-lock path may differ |

---

## §11 Known Limitations

1. **No outer transaction on `setLockDamaged`:** The method creates a new unit load then calls `transferStockToUnitLoad`, but has no outer `@Transactional`. A failure between unit-load creation and SU lock assignment leaves an orphaned unit load at the Damaged location. The TODO comments in the code acknowledge the missing lock checks on the unit load and location.

2. **`adjustReservedAmount` deliberately skips replenishment recalculation** (line 455 comment): This is by design — triggering recalculation would immediately re-reserve stock the user just released. However, replenishment orders sit over-reserved until the next scheduled recalculation cycle.

3. **Caffeine L1 caches are JVM-local:** In a multi-replica deployment, `itemdata`, `locations`, `sysprops`, and `clients` can be stale for up to 5 minutes per replica after a write. A SKU update evicts the `itemdata` cache on the replica that handled the write — other replicas continue serving stale data until their TTL expires. The CacheConfig comment explicitly notes a plan for Redis migration.

4. **`create()` in `StockunitService` writes no `Stockrecord`:** The low-level `create()` method used in some import paths does not audit the creation. Only `createStockUnit()` in `StockunitBusinessService` writes a `STOCK_CREATED` record.

5. **String FK in `Stockrecord`:** `fromstockunitidentity` and `tostockunitidentity` are `varchar`, not `bigint` FKs. No referential integrity — a deleted SU leaves orphaned audit rows as string IDs.

6. **`findByIdForUpdate` uses `@Lock(LockModeType.PESSIMISTIC_WRITE)` with JPQL:** This relies on the JPA provider (Hibernate 6.x) generating `SELECT ... FOR UPDATE`. Verify this is still correct if the Hibernate version changes, as the lock hint mechanism differs between Hibernate 5 and 6.

7. **`StockunitBusinessService` `@Lazy` annotation is absent:** `UnitloadBusinessService` is annotated `@Lazy` at the class level and has an explicit null-guard `ensureInitialized()`. `StockunitBusinessService` has `@Lazy` on its `@PostConstruct` method only — the class itself is eagerly wired. If the tenant DB is unavailable at startup, the nirvana-unitload lookup will fail and `initialized` stays `false`, causing deferred initialization on every call to `ensureInitialized()`.

8. **`transferStockToUnitLoad` ID comparison for entity equality:** Uses `.equals()` on `Itemdata` entities for the same-SKU merge check (`destFirstItemdata.getId().equals(sourceStockunitItemdata.getId())`). This is correct (ID comparison). However, the destination-stock-unit loop at line 217 uses `.equals()` on `itemdataId` (Long), which is also correct. The v1 issue with reference equality does not apply here.

---

## §12 Related Docs

- `sbdocs/3-Resources/design/wms1-stockunit-design.md` — v1 baseline for comparison
- `sbdocs/3-Resources/architecture/` — entity reports, state machine catalog, transaction/OSIV maps
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java` — all state/lock/code constants
- `v2/wms2-api/src/main/java/net/aim_ai/wms/config/CacheConfig.java` — Caffeine cache definitions
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` — replenishment recalc
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` — pick-confirm flow
- `v2/wms2-api/CLAUDE.md` — dual transaction manager rules (critical background)

---

## §13 Verification Log

| Date | Verified by | Method | Notes |
|---|---|---|---|
| 2026-04-27 | Claude (executor) | Full source read + grep | `StockunitService.java` (600 lines), `StockunitBusinessService.java` (423 lines), `UnitloadService.java` (457 lines), `UnitloadBusinessService.java` (311 lines), `UnitloadRecordService.java` (140 lines), all model entities, `WmsConstants.java` (lock states, record types, codes, special locations), `CacheConfig.java`, `StockunitRepository.java` (254 lines), `UnitloadRepository.java` (143 lines), cross-service caller list (27 callers), `wms1-stockunit-design.md` for structural reference |
