---
title: WMS v1 Entity Enumeration Report
type: architecture
project: wms1
status: stable
created: 2026-04-26
last_verified: 2026-05-01
tags: [wms1, entities, jpa, database, architecture]
---

# WMS v1 Entity Enumeration Report
**v1/wms-api — Java 8, Spring Boot 2.3.7, PostgreSQL**

Generated: 2026-04-26

---

## Critical v1 Pattern: No ORM Associations

**v1 uses `Long foreignKeyId` fields exclusively.** There are NO `@ManyToOne`, `@OneToMany`, or `@ManyToMany` associations on any transactional entity. All related entities must be fetched via explicit repository calls.

```java
// v1 pattern — FK as plain Long field
private Long clientId;       // → Client.id
private Long itemdataId;     // → Itemdata.id

// NOT this (v2 pattern)
@ManyToOne
private Client client;
```

**Table naming**: No entity uses `@Table(name=...)`. Hibernate default physical naming applies: class name lowercased becomes the table name (e.g., `Customerorder` → `customerorder`, `BillofladingPosition` → `billofladingposition`). Exception: view-backed entities map to named PostgreSQL views (documented per entity).

**Note on ORM annotations in system entities**: `MywmsUser`, `MywmsRole`, and `MywmsGroup` declare `@ManyToMany` with `@JoinTable` for their junction tables — these are the only entities with ORM associations, used solely for the user/role/function access control graph.

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| Total @Entity classes | 55 |
| Transactional / master entities | 35 |
| View-backed (read-only) entities | 11 |
| Junction / composite-key entities | 5 |
| Non-entity utility classes | 4 |

---

## Domain Groups

1. [Order](#1-order-domain)
2. [PickingOrder](#2-pickingorder-domain)
3. [Advice / Receipt](#3-advice--receipt-domain)
4. [Bill of Lading](#4-bill-of-lading-domain)
5. [Replenishment](#5-replenishment-domain)
6. [Cycle Count](#6-cycle-count-domain)
7. [Stock / Inventory](#7-stock--inventory-domain)
8. [Unitload](#8-unitload-domain)
9. [Warehouse / Location](#9-warehouse--location-domain)
10. [Item Master](#10-item-master-domain)
11. [Shipping](#11-shipping-domain)
12. [System / User](#12-system--user-domain)
13. [View Entities (Read-Only)](#13-view-entities-read-only)

---

## 1. Order Domain

### Customerorder
- **Table**: `customerorder`
- **PK**: `id` (Long)
- **State**: `state` (Integer) — `WmsConstants.State.*`
- **FK fields**:
  - `clientId` → `Client.id`
  - `orderbatchId` → `CustomerorderBatch.id`
  - `parcelId` → `Unitload.id` (parcel unitload)
  - `pickingtoteId` → `Unitload.id` (tote unitload)
  - `boxtypeId` → `Boxtype.id`
  - `transferlaneId` → `Location.id` (transfer lane location)
  - `shipperidId` → `Shipperid.id`
- **Key business fields**: `number`, `externalnumber`, `clientordernumber`, `prio` (Integer), `pickingdate` (Date), `fulfillmenttype`, `brand`, `recipient`, `weight`

### CustomerorderBatch
- **Table**: `customerorderbatch`
- **PK**: `id` (Long)
- **State**: `state` (Integer) — `WmsConstants.State.*`
- **FK fields**:
  - `clientId` → `Client.id`
  - `staginglaneId` → `Location.id` (staging lane location)
- **Key business fields**: `number`, `batchid`, `transferid`, `type` (WmsConstants.OrderBatchType: PICK_PACK, REGULAR, CLUB, TRANSFER_OFFSITE, TRANSFER_INTRACOMPANY, HUB_AND_SPOKE), `priority`

### CustomerorderPosition
- **Table**: `customerorderposition`
- **PK**: `id` (Long)
- **State**: `state` (Integer) — `WmsConstants.State.*`
- **FK fields**:
  - `clientId` → `Client.id`
  - `itemdataId` → `Itemdata.id`
  - `orderId` → `Customerorder.id`
- **Key business fields**: `amount` (BigDecimal), `amountpicked` (BigDecimal), `number`, `externalid`, `index`, `partitionallowed`

### Order Domain FK Diagram

```
CustomerorderBatch (1)
  └── staginglaneId → Location

CustomerorderBatch (1) ──→ Customerorder (N)
  orderbatchId

Customerorder
  ├── clientId       → Client
  ├── parcelId       → Unitload   (parcel)
  ├── pickingtoteId  → Unitload   (tote)
  ├── boxtypeId      → Boxtype
  ├── transferlaneId → Location   (transfer lane)
  └── shipperidId    → Shipperid

Customerorder (1) ──→ CustomerorderPosition (N)
  orderId

CustomerorderPosition
  ├── clientId   → Client
  └── itemdataId → Itemdata
```

---

## 2. PickingOrder Domain

### Pickingorder
- **Table**: `pickingorder`
- **PK**: `id` (Long)
- **State**: `state` (Integer) — `WmsConstants.State.*`
- **FK fields**:
  - `clientId` → `Client.id`
  - `destinationId` → `Location.id`
  - `operatorId` → `MywmsUser.id`
  - `sectionId` → `Section.id`
- **Key business fields**: `number`, `customerordernumber`, `prio` (Integer, default 50), `manualcreation`, `lockedtooperator`, `pickinginprogress`

### PickingorderPosition
- **Table**: `pickingorderposition`
- **PK**: `id` (Long)
- **State**: `state` (Integer) — `WmsConstants.State.*`
- **FK fields**:
  - `clientId` → `Client.id`
  - `customerorderpositionId` → `CustomerorderPosition.id`
  - `itemdataId` → `Itemdata.id`
  - `pickfromstockunitId` → `Stockunit.id`
  - `picktounitloadId` → `Unitload.id`
  - `pickingorderId` → `Pickingorder.id`
  - `pickedbyoperatorId` → `MywmsUser.id`
- **Key business fields**: `amount` (BigDecimal), `amountpicked` (BigDecimal), `number`, `pickfromlocationname`, `pickfromunitloadlabel`

### PickingorderUnitload
- **Table**: `pickingorderunitload`
- **PK**: `id` (Long)
- **State**: `state` (Integer) — `WmsConstants.State.*`
- **FK fields**:
  - `clientId` → `Client.id`
  - `pickingorderId` → `Pickingorder.id`
  - `unitloadId` → `Unitload.id`
- **Key business fields**: `customerordernumber`, `historytote`, `positionindex`

### PickingOrder Domain FK Diagram

```
Pickingorder
  ├── clientId      → Client
  ├── destinationId → Location
  ├── operatorId    → MywmsUser
  └── sectionId     → Section

Pickingorder (1) ──→ PickingorderPosition (N)
  pickingorderId

PickingorderPosition
  ├── clientId               → Client
  ├── customerorderpositionId → CustomerorderPosition
  ├── itemdataId             → Itemdata
  ├── pickfromstockunitId    → Stockunit
  ├── picktounitloadId       → Unitload
  └── pickedbyoperatorId     → MywmsUser

Pickingorder (1) ──→ PickingorderUnitload (N)
  pickingorderId

PickingorderUnitload
  ├── clientId    → Client
  └── unitloadId  → Unitload
```

---

## 3. Advice / Receipt Domain

### Advice
- **Table**: `advice`
- **PK**: `id` (Long)
- **State**: `state` (String) — `WmsConstants.AdviceState`: CREATED, OPEN, PROCESSING, CLOSED, FINISHED, CANCELLED
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `number`, `name`, `externalid`, `type` (WmsConstants.AdviceType), `dayofdelivery` (Date), `dayofdeliveryuntil` (Date), `deliverynotenumber`, `purchaseordernumber`, `supplier`, `shippedfrom`, `shippedto`, `allowoverdelivery`, `allowshortdelivery`, `transferId`

### Adviceposition
- **Table**: `adviceposition`
- **PK**: `id` (Long)
- **State**: `state` (String) — `WmsConstants.AdviceState`
- **FK fields**:
  - `clientId` → `Client.id`
  - `adviceId` → `Advice.id`
  - `boxtypeId` → `Boxtype.id`
  - `itemdataId` → `Itemdata.id`
  - `unitloadtypeId` → `UnitloadType.id`
  - `shipperidId` → `Shipperid.id`
- **Key business fields**: `number`, `name`, `externalid`, `notifiedamount` (BigDecimal), `notifiedcases` (BigDecimal), `palletlabel`, `parcellabel`, `manifestlocation`

### Goodsreceipt
- **Table**: `goodsreceipt`
- **PK**: `id` (Long)
- **State**: none (state tracked via linked Advice)
- **FK fields**:
  - `clientId` → `Client.id`
  - `adviceId` → `Advice.id`
  - `goodsinlocationId` → `Location.id`
  - `operatorId` → `MywmsUser.id`
- **Key business fields**: `number`, `name`, `deliverynotenumber`, `drivername`, `forwarder`, `licenseplatenumber`, `receiptdate` (Timestamp)

### Goodsreceiptposition
- **Table**: `goodsreceiptposition`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
  - `advicepositionId` → `Adviceposition.id`
  - `goodsreceiptId` → `Goodsreceipt.id`
  - `operatorId` → `MywmsUser.id`
  - `stockunitId` → `Stockunit.id`
  - `unitloadId` → `Unitload.id`
- **Key business fields**: `number`, `name`

### Advice / Receipt FK Diagram

```
Advice (1) ──→ Adviceposition (N)
  adviceId

Advice
  └── clientId → Client

Adviceposition
  ├── clientId       → Client
  ├── adviceId       → Advice
  ├── boxtypeId      → Boxtype
  ├── itemdataId     → Itemdata
  ├── unitloadtypeId → UnitloadType
  └── shipperidId    → Shipperid

Advice (1) ──→ Goodsreceipt (1)
  adviceId

Goodsreceipt
  ├── clientId          → Client
  ├── adviceId          → Advice
  ├── goodsinlocationId → Location
  └── operatorId        → MywmsUser

Goodsreceipt (1) ──→ Goodsreceiptposition (N)
  goodsreceiptId

Goodsreceiptposition
  ├── clientId         → Client
  ├── advicepositionId → Adviceposition
  ├── goodsreceiptId   → Goodsreceipt
  ├── operatorId       → MywmsUser
  ├── stockunitId      → Stockunit
  └── unitloadId       → Unitload
```

---

## 4. Bill of Lading Domain

### Billoflading
- **Table**: `billoflading`
- **PK**: `id` (Long)
- **State**: `state` (String) — `WmsConstants.BillOfLadingState`: CREATED, OPEN, TRUCK_LOADING, TRANSFER, CLOSED, CANCELLED
- **FK fields**:
  - `clientId` → `Client.id`
  - `operatorId` → `MywmsUser.id`
  - `outboundlocationId` → `Location.id`
- **Key business fields**: `number`, `name`, `type`, `courier`, `truck`, `sealnumber`, `destination`, `shipped` (Date), `numberOfParcels` (Long), `sharedUniqueBolId`, `trackingDeviceId`, `transferId`

### BillofladingPosition
- **Table**: `billofladingposition`
- **PK**: `id` (Long)
- **State**: `state` (String) — `WmsConstants.BillOfLadingState`
- **FK fields**:
  - `clientId` → `Client.id`
  - `billofladingId` → `Billoflading.id`
  - `carrierId` → `Unitload.id` (carrier/pallet unitload)
  - `itemdataId` → `Itemdata.id`
  - `operatorId` → `MywmsUser.id`
  - `orderId` → `Customerorder.id`
  - `orderpositionId` → `CustomerorderPosition.id`
  - `sourceId` → `Unitload.id` (source parcel unitload)
- **Key business fields**: `number`, `name`, `amount` (Integer)

### Bill of Lading FK Diagram

```
Billoflading
  ├── clientId           → Client
  ├── operatorId         → MywmsUser
  └── outboundlocationId → Location

Billoflading (1) ──→ BillofladingPosition (N)
  billofladingId

BillofladingPosition
  ├── clientId         → Client
  ├── billofladingId   → Billoflading
  ├── carrierId        → Unitload  (pallet/carrier)
  ├── itemdataId       → Itemdata
  ├── operatorId       → MywmsUser
  ├── orderId          → Customerorder
  ├── orderpositionId  → CustomerorderPosition
  └── sourceId         → Unitload  (parcel/source)
```

**Note**: `carrierId` and `sourceId` both point to `Unitload` but represent different roles (carrier pallet vs. source parcel).

---

## 5. Replenishment Domain

### Replenishorder
- **Table**: `replenishorder`
- **PK**: `id` (Long)
- **State**: `state` (Integer) — `WmsConstants.State.*`
- **FK fields**:
  - `clientId` → `Client.id`
  - `destinationId` → `Location.id`
  - `itemdataId` → `Itemdata.id`
  - `operatorId` → `MywmsUser.id`
  - `requestedlocationId` → `Location.id`
  - `requestedrackId` → `LocationRack.id`
  - `stockunitId` → `Stockunit.id`
- **Key business fields**: `number`, `prio` (Integer, WmsConstants.Priority), `requestedamount` (BigDecimal), `sourcelocationname`, `manuallyoverridepriority`

### Replenishment FK Diagram

```
Replenishorder
  ├── clientId            → Client
  ├── destinationId       → Location   (target pick location)
  ├── itemdataId          → Itemdata
  ├── operatorId          → MywmsUser
  ├── requestedlocationId → Location   (source storage location)
  ├── requestedrackId     → LocationRack
  └── stockunitId         → Stockunit
```

**Note**: `destinationId` is the pick-face location being replenished; `requestedlocationId` is the bulk storage location to pull from.

---

## 6. Cycle Count Domain

### Cyclecount
- **Table**: `cyclecount`
- **PK**: `id` (Long)
- **State**: `state` (String) — `WmsConstants.CycleCountState`: CREATED, STARTED, FINISHED, CANCELLED
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `number`, `name`, `type` (String), `subtype` (WmsConstants.CycleCountSubType: SKU, LOCATION), `comment`

### CyclecountPosition
- **Table**: `cyclecountposition`
- **PK**: `id` (Long)
- **State**: `state` (String) — `WmsConstants.CycleCountState`
- **FK fields**:
  - `clientId` → `Client.id`
  - `cyclecountId` → `Cyclecount.id`
  - `locationId` → `Location.id`
  - `unitloadId` → `Unitload.id`
  - `stockunitId` → `Stockunit.id`
  - `itemdataId` → `Itemdata.id`
  - `operatorId` → `MywmsUser.id`
- **Key business fields**: `number`, `name`, `type`, `amountbefore` (BigDecimal), `amountafter` (BigDecimal), `comment`

### Cycle Count FK Diagram

```
Cyclecount
  └── clientId → Client

Cyclecount (1) ──→ CyclecountPosition (N)
  cyclecountId

CyclecountPosition
  ├── clientId    → Client
  ├── cyclecountId → Cyclecount
  ├── locationId  → Location
  ├── unitloadId  → Unitload
  ├── stockunitId → Stockunit
  ├── itemdataId  → Itemdata
  └── operatorId  → MywmsUser
```

---

## 7. Stock / Inventory Domain

### Stockunit
- **Table**: `stockunit`
- **PK**: `id` (Long)
- **State**: none (lock tracked via `entityLock`)
- **FK fields**:
  - `clientId` → `Client.id`
  - `itemdataId` → `Itemdata.id`
  - `unitloadId` → `Unitload.id`
- **Key business fields**: `amount` (BigDecimal), `reservedamount` (BigDecimal)

### Stockrecord
- **Table**: `stockrecord`
- **PK**: `id` (Long)
- **State**: none (audit/log record)
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `activitycode`, `amount` (BigDecimal), `amountstock` (BigDecimal), `reservedamountchange` (BigDecimal), `reservedamountstock` (BigDecimal), `type`, `operator`, `ordernumber`, `fromstockunitidentity`, `tostockunitidentity`, `fromstoragelocation`, `tostoragelocation`, `fromunitload`, `tounitload`, `itemdata`, `unitloadtype`

### InventoryRecord
- **Table**: `inventoryrecord`
- **PK**: `id` (Long)
- **State**: none (snapshot record)
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `number`, `name`, `type`, `operator`, `timestamp` (Timestamp), `itemdatanumber`, `clientnumber`, `total` (BigDecimal), `damage` (BigDecimal), `missing` (BigDecimal), `onHold` (BigDecimal), `transfer` (BigDecimal)

### FixLocationAssignment
- **Table**: `fixlocationassignment`
- **PK**: `id` (Long)
- **State**: `active` (Boolean)
- **FK fields**:
  - `assignedlocationId` → `Location.id`
  - `assignedunitloadId` → `Unitload.id`
  - `itemdataId` → `Itemdata.id`
- **Key business fields**: `lowerbound` (BigDecimal), `middlebound` (BigDecimal), `upperbound` (BigDecimal)

### Stock / Inventory FK Diagram

```
Stockunit
  ├── clientId   → Client
  ├── itemdataId → Itemdata
  └── unitloadId → Unitload  (physical container)

Stockrecord          (audit log — no live FKs, denormalized strings)
  └── clientId → Client

InventoryRecord      (snapshot — no live FKs, denormalized strings)
  └── clientId → Client

FixLocationAssignment
  ├── assignedlocationId → Location
  ├── assignedunitloadId → Unitload
  └── itemdataId         → Itemdata
```

**Note**: `Stockrecord` and `InventoryRecord` are append-only audit logs. Related entity identifiers are stored as denormalized strings (`itemdata`, `operator`, `fromunitload`, etc.), not as FK Longs. Do not attempt FK joins from these tables.

---

## 8. Unitload Domain

### Unitload
- **Table**: `unitload`
- **PK**: `id` (Long)
- **State**: `entityLock` (Integer) — `WmsConstants.BusinessObjectLockState`: NOT_LOCKED(0), GOING_TO_DELETE, PICKED_FOR_GOODSOUT(100), QUALITY_FAULT(103), ON_HOLD(104), NOT_FOUND, TRANSFER, SHIPPED
- **FK fields**:
  - `clientId` → `Client.id`
  - `typeId` → `UnitloadType.id`
  - `carrierunitloadId` → `Unitload.id` (self-reference: parent pallet)
  - `storagelocationId` → `Location.id`
  - `boxtypeId` → `Boxtype.id`
  - `shippingmethodId` → `Shippingmethod.id`
- **Key business fields**: `labelid` (barcode/label)

### UnitloadRecord
- **Table**: `unitloadrecord`
- **PK**: `id` (Long)
- **State**: none (audit log)
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `activitycode`, `recordtype`, `label`, `operator`, `ordernumber`, `fromlocation`, `tolocation`, `fromunitload`, `tounitload`, `unitloadtype`

### UnitloadType
- **Table**: `unitloadtype`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**: none
- **Key business fields**: `name`, `depth`, `height`, `width`, `volume`, `weight`, `stockunitallowed`, `differentstockallowed`, `unitloadallowed`, `onotherunitloadallowed`, `externalid`

### Unitload FK Diagram

```
Unitload
  ├── clientId          → Client
  ├── typeId            → UnitloadType
  ├── carrierunitloadId → Unitload     (self-ref: this unitload sits ON another unitload)
  ├── storagelocationId → Location
  ├── boxtypeId         → Boxtype
  └── shippingmethodId  → Shippingmethod

UnitloadRecord      (audit log — denormalized strings)
  └── clientId → Client
```

**Note**: `carrierunitloadId` is a self-referential FK. A parcel's `carrierunitloadId` points to its parent pallet. Pallets have `carrierunitloadId = null`.

---

## 9. Warehouse / Location Domain

### Location
- **Table**: `location`
- **PK**: `id` (Long)
- **State**: none (lock tracked via `entityLock`)
- **FK fields**:
  - `clientId` → `Client.id`
  - `areaId` → `LocationArea.id`
  - `rackId` → `LocationRack.id`
  - `typeId` → `LocationType.id`
- **Key business fields**: `name`, `xpos` (Integer), `ypos` (Integer), `zpos` (Integer), `staginglane` (Boolean), `transferlane` (Boolean), `automationlane` (Boolean), `crossdockinglane` (Boolean), `gate` (Boolean)
- **Custom equals/hashCode**: YES — equality based on `xpos`, `ypos`, `zpos`, `name` (only entity with custom implementation)

### LocationArea
- **Table**: `locationarea`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `useforgoodsin`, `useforgoodsout`, `useforpicking`, `useforreplenish`, `useforstorage`, `usefortransfer`, `usefordeepstorage`

### LocationRack
- **Table**: `locationrack`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
  - `rackrowId` → `LocationRackRow.id`
- **Key business fields**: `name`, `number`, `aisle`, `numberofcolumns`, `numberofrows`, `ordinalnumber`, `labeloffset`

### LocationRackRow
- **Table**: `locationrackrow`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `number`, `ordinalnumber`

### LocationType
- **Table**: `locationtype`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**: none
- **Key business fields**: `sltname`, `depth`, `height`, `width`, `volume`

### LocationConstraint
- **Table**: `locationconstraint`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `storagelocationtypeId` → `LocationType.id`
  - `unitloadtypeId` → `UnitloadType.id`
- **Key business fields**: `name`, `number`

### Section
- **Table**: `section`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `number`, `sectionpickingtype`

### Client
- **Table**: `client`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `sectionId` → `Section.id`
  - `printerreceivingId` → `Printer.id`
- **Key business fields**: `name`, `clNr`, `enablereceiving`

### Warehouse / Location FK Diagram

```
LocationRackRow (1) ──→ LocationRack (N)
  rackrowId

LocationRack
  ├── clientId  → Client
  └── rackrowId → LocationRackRow

LocationArea
  └── clientId → Client

LocationType    (no FKs — pure master data)

LocationConstraint
  ├── storagelocationtypeId → LocationType
  └── unitloadtypeId        → UnitloadType

Location
  ├── clientId → Client
  ├── areaId   → LocationArea
  ├── rackId   → LocationRack
  └── typeId   → LocationType

Section
  └── clientId → Client

Client
  ├── sectionId          → Section
  └── printerreceivingId → Printer
```

**Note**: `Location` boolean flags (`staginglane`, `transferlane`, `automationlane`, `crossdockinglane`, `gate`) classify a location's functional role. Staging lanes are referenced by `CustomerorderBatch.staginglaneId`; transfer lanes by `Customerorder.transferlaneId`.

---

## 10. Item Master Domain

### Itemdata
- **Table**: `itemdata`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
  - `defultypeId` → `UnitloadType.id` (default unitload type — note typo in field name)
  - `handlingunitId` → `Itemunit.id`
  - `defaultboxtypeId` → `Boxtype.id`
  - `putawaylocationId` → `Location.id`
- **Key business fields**: `name`, `itemNr`, `scale` (Integer), `depth`, `height`, `width`, `weight`, `volume`, `bottleSize`, `vintage`, `varietal`, `winetype`, `imageFilename`

### Itemunit
- **Table**: `itemunit`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `baseunitId` → `Itemunit.id` (self-reference: base unit of measure)
- **Key business fields**: `unitname`, `unittype`, `basefactor`

### Boxtype
- **Table**: `boxtype`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
  - `automationlaneId` → `Location.id`
- **Key business fields**: `name`, `number`, `externalid`, `capacity`, `comment`, `itemunittype`, `boxtypeprocesstype`

### Item Master FK Diagram

```
Itemunit (self-ref)
  └── baseunitId → Itemunit

Itemdata
  ├── clientId          → Client
  ├── defultypeId       → UnitloadType   (typo: "defult" not "default")
  ├── handlingunitId    → Itemunit
  ├── defaultboxtypeId  → Boxtype
  └── putawaylocationId → Location

Boxtype
  ├── clientId        → Client
  └── automationlaneId → Location
```

**Note**: `Itemdata.defultypeId` — field name contains a typo (`defult` instead of `default`). This is the actual Java field name and column name in the DB.

---

## 11. Shipping Domain

### Shippingmethod
- **Table**: `shippingmethod`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `number`, `barcodepattern`, `sequencename`, `description`

### Shipperid
- **Table**: `shipperid`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `number`, `externalid`, `carrier`, `expedited` (Boolean), `description`

### ShippingmethodShipperid
- **Table**: `shippingmethodshipperid`
- **PK**: composite — `shipperidsetId` + `shippingmethodsetId` (via `ShippingmethodShipperidId`)
- **State**: none
- **FK fields** (composite PK — both are FKs):
  - `shipperidsetId` → `Shipperid.id`
  - `shippingmethodsetId` → `Shippingmethod.id`

### Shipping FK Diagram

```
Shippingmethod (N) ←──→ (N) Shipperid
  via ShippingmethodShipperid junction table
  (shipperidsetId → Shipperid, shippingmethodsetId → Shippingmethod)

Shippingmethod
  └── clientId → Client

Shipperid
  └── clientId → Client
```

---

## 12. System / User Domain

### MywmsUser
- **Table**: `mywmsuser`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
  - `printerId` → `Printer.id`
- **Key business fields**: `name`, `firstname`, `lastname`, `email`, `phone`, `locale`, `password`
- **ORM note**: Has `@ManyToMany` to `MywmsGroup` via join table `mywms_group_mywms_user` — exception to the no-ORM-associations rule

### MywmsRole
- **Table**: `mywmsrole`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**: none (junction tables used instead)
- **Key business fields**: `name`, `number`, `description`, `connector`
- **ORM note**: Has `@ManyToMany` to `MywmsFunction` via join table `mywms_role_mywms_function`

### MywmsGroup
- **Table**: `mywmsgroup`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `number`, `connector`
- **ORM note**: Has `@ManyToMany` to `MywmsRole` via join table `mywms_group_mywms_role`

### MywmsFunction
- **Table**: `mywmsfunction`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `number`, `function`

### MywmsGroupMywmsRole
- **Table**: `mywms_group_mywms_role`
- **PK**: composite — `grouplistId` + `rolelistId` (via `MywmsGroupMywmsRoleId`)
- **FK fields**: `grouplistId` → `MywmsGroup.id`, `rolelistId` → `MywmsRole.id`

### MywmsGroupMywmsUser
- **Table**: `mywms_group_mywms_user`
- **PK**: composite — `grouplistId` + `userlistId` (via `MywmsGroupMywmsUserId`)
- **FK fields**: `grouplistId` → `MywmsGroup.id`, `userlistId` → `MywmsUser.id`

### MywmsRoleMywmsFunction
- **Table**: `mywms_role_mywms_function`
- **PK**: composite — `rolelistId` + `functionlistId` (via `MywmsRoleMywmsFunctionId`)
- **FK fields**: `rolelistId` → `MywmsRole.id`, `functionlistId` → `MywmsFunction.id`

### MywmsUserMywmsRole
- **Table**: `mywms_user_mywms_role` (inferred — column names: `user_id`, `roles_id`)
- **PK**: composite — `userId` + `rolesId` (via `MywmsUserMywmsRoleId`)
- **FK fields**: `userId` → `MywmsUser.id`, `rolesId` → `MywmsRole.id`

### Printer
- **Table**: `printer`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `number`, `address`, `type`, `processdefault`

### Message
- **Table**: `message`
- **PK**: `id` (Long)
- **State**: `status` (String)
- **FK fields**:
  - `clientId` → `Client.id`
  - `operatorId` → `MywmsUser.id`
  - `redeliverId` → `MywmsUser.id` (re-delivery target operator)
- **Key business fields**: `name`, `number`, `process`, `destination`, `sender`, `receiver`, `message`, `answer`, `statuscodeanswer`, `resent`

### MessageArchived
- **Table**: `messagearchived`
- **PK**: `id` (Long)
- **State**: `status` (String)
- **FK fields**:
  - `clientId` → `Client.id`
  - `operatorId` → `MywmsUser.id`
  - `redeliverId` → `MywmsUser.id`
- **Key business fields**: same structure as `Message` — archived copy

### LosSequencenumber
- **Table**: `lossequencenumber`
- **PK**: `classname` (String) — note: String PK, not Long
- **State**: none
- **FK fields**: none
- **Key business fields**: `sequencenumber` (Long), `version`

### LosSysprop
- **Table**: `lossysprop`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `syskey`, `sysvalue`, `groupname`, `description`, `workstation`, `hidden`

### Queryrepository
- **Table**: `queryrepository`
- **PK**: `id` (Long)
- **State**: none
- **FK fields**:
  - `clientId` → `Client.id`
- **Key business fields**: `name`, `number`, `query` (text), `headers` (text), `sheetname`, `counter`

### System / User FK Diagram

```
MywmsFunction
  └── clientId → Client

MywmsRole  ──MywmsRoleMywmsFunction──  MywmsFunction
  (rolelist_id → MywmsRole, functionlist_id → MywmsFunction)

MywmsGroup  ──MywmsGroupMywmsRole──  MywmsRole
  (grouplist_id → MywmsGroup, rolelist_id → MywmsRole)
  └── clientId → Client

MywmsUser  ──MywmsGroupMywmsUser──  MywmsGroup
  (userlist_id → MywmsUser, grouplist_id → MywmsGroup)
  ├── clientId  → Client
  └── printerId → Printer

MywmsUser  ──MywmsUserMywmsRole──  MywmsRole
  (user_id → MywmsUser, roles_id → MywmsRole)

Message / MessageArchived
  ├── clientId    → Client
  ├── operatorId  → MywmsUser
  └── redeliverId → MywmsUser

Printer
  └── clientId → Client

LosSysprop / Queryrepository
  └── clientId → Client

LosSequencenumber   (String PK — no FK)
```

---

## 13. View Entities (Read-Only)

These entities map to PostgreSQL views. They are read-only query projections and carry no FK Long fields for live joins — data is denormalized into the view definition.

| Entity Class | DB View Name | PK | Purpose |
|---|---|---|---|
| `CyclecountDtoView` | `cyclecount_dto_view` | `rowId` | Cycle count planning — items with fix assignments |
| `FlowbinMonitorView` | `flowbin_monitor_view` | `rowId` | Flowbin/automation lane stock monitor |
| `LockOverviewDtoView` | `lock_overview_dto_view` | `rowId` | Stock unit lock status overview |
| `OrderDetailMonitorView` | `order_detail_monitor_view` | `rowId` | Per-order detail: state, tote, picking order |
| `OrderMonitorView` | `order_monitor_view` | `rowId` | Aggregated order counts by state and section |
| `ParcelMonitorView` | `parcel_monitor_view` | `rowId` | Parcel/pallet monitor with order linkage |
| `ReceivedDtoView` | `received_dto_view` | `rowId` | Goods receipt position summary |
| `ReceivingDtoView` | `receiving_dto_view` | `rowId` | Advice/receiving workflow projection (materialized view or null-typed view) |
| `ReplenishmentMonitorView` | `replenishment_monitor_view` | `rowId` | Replenishment demand by SKU |
| `StockView` | `stock_view` | `rowId` | Stock aggregation by SKU (null-typed view) |
| `ViewWarehouseLocationReport` | `view_warehouse_location_report` | `id` | Stock-per-location report |

**Key Long fields in views** (these are copied IDs from the underlying tables, not JPA FKs):

| View | Notable Long fields |
|---|---|
| `CyclecountDtoView` | `clientId`, `skuId`, `fixassignmentId` |
| `LockOverviewDtoView` | `stockunitid` |
| `OrderDetailMonitorView` | `pickFromStockUnitId` |
| `OrderMonitorView` | count aggregates (orderImported, orderFuturePickingDate, etc.) |
| `ReceivedDtoView` | `stockunitid` |
| `ReceivingDtoView` | `adviceid`, `advicepositionid`, `defaultunitloadtypeid`, `defaultboxid`, `advicepositionboxid`, `receivedboxes` |
| `ReplenishmentMonitorView` | `roId` (replenish order id), count aggregates |
| `StockView` | `itemId`, `clientId` |
| `ViewWarehouseLocationReport` | `clientId`, `skuId`, `locationId` |

---

## WmsConstants State Reference

### Integer States (`WmsConstants.State`) — used by Customerorder, CustomerorderBatch, CustomerorderPosition, Pickingorder, PickingorderPosition, PickingorderUnitload, Replenishorder

| Value | Constant | Description |
|-------|----------|-------------|
| 0 | RAW | Just created |
| 45 | CLIENT_HAS_NO_SECTION | Client has no section |
| 50 | RAW_ON_HOLD | On hold |
| 55 | RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION | Not enough stock on location |
| 56 | RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION | No fixed assigned location |
| 57 | RAW_ON_HOLD_PROBLEM_WITH_FIXED_ASSIGNED_LOCATION | Problem with fixed assigned location |
| 58 | RAW_ON_HOLD_FIX_ASSIGNMENT_IS_INACTIVE | Fixed assignment is inactive |
| 80 | FUTURE_PICKING_DATE | Future picking date |
| 200 | ASSIGNED | Assigned to pick-from stock/location |
| 300 | PROCESSABLE | Released for user process |
| 400 | RESERVED | Reserved for a user |
| 500 | STARTED | User accepted and handling |
| 505 | CUSTOMER_ORDER_ACTIVATED | Transfer order activated |
| 510 | CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED | Transfer lane assigned |
| 520 | ORDER_BATCH_ACTIVATED | Club run activated |
| 525 | ORDER_BATCH_STAGING_LANE_ASSIGNED | Staging lane assigned |
| 530 | ORDER_BATCH_CLUB_RUN_FINISHED | Club run finished |
| 550 | PENDING | Cannot continue, not finished |
| 600 | PICKED | Material taken |
| 650 | PACKED | Packed to parcel |
| 670 | PALLETIZED | Put on pallet |
| 700 | FINISHED | Operation finished |
| 800 | CANCELED | Canceled |

### String States (`WmsConstants.AdviceState`) — used by Advice, Adviceposition

| Value | Description |
|-------|-------------|
| `CREATED` | Just created / received |
| `OPEN` | Allowed for processing, not started |
| `PROCESSING` | Receiving in progress |
| `CLOSED` | Receiving finished, ERP not notified |
| `FINISHED` | Closed and ERP notified |
| `CANCELLED` | Aborted |

### String States (`WmsConstants.BillOfLadingState`) — used by Billoflading, BillofladingPosition

| Value | Description |
|-------|-------------|
| `CREATED` | Just created |
| `OPEN` | Allowed for processing |
| `TRUCK_LOADING` | Truck loading in progress |
| `TRANSFER` | Shipped to another warehouse, not accepted |
| `CLOSED` | Finished, ERP not notified |
| `CANCELLED` | Aborted |

### String States (`WmsConstants.CycleCountState`) — used by Cyclecount, CyclecountPosition

| Value | Description |
|-------|-------------|
| `CREATED` | Created |
| `STARTED` | In progress |
| `FINISHED` | Completed |
| `CANCELLED` | Cancelled |

### Integer Lock States (`WmsConstants.BusinessObjectLockState`) — used by `entityLock` on Unitload, Location

| Value | Constant | Description |
|-------|----------|-------------|
| 0 | NOT_LOCKED | Normal, available |
| (see code) | GOING_TO_DELETE | Marked for deletion |
| 100 | PICKED_FOR_GOODSOUT | Allocated to outbound |
| 103 | QUALITY_FAULT | QC hold |
| 104 | ON_HOLD | Manual hold |
| (see code) | NOT_FOUND | Not found during count |
| (see code) | TRANSFER | In transfer |
| (see code) | SHIPPED | Shipped |

---

## Quick Entity Lookup

| Entity | Table | Domain | State Field | State Type |
|--------|-------|--------|-------------|------------|
| Advice | `advice` | Receipt | `state` | String (AdviceState) |
| Adviceposition | `adviceposition` | Receipt | `state` | String (AdviceState) |
| Billoflading | `billoflading` | BOL | `state` | String (BillOfLadingState) |
| BillofladingPosition | `billofladingposition` | BOL | `state` | String (BillOfLadingState) |
| Boxtype | `boxtype` | Item Master | — | — |
| Client | `client` | Warehouse | — | — |
| Customerorder | `customerorder` | Order | `state` | Integer (State) |
| CustomerorderBatch | `customerorderbatch` | Order | `state` | Integer (State) |
| CustomerorderPosition | `customerorderposition` | Order | `state` | Integer (State) |
| Cyclecount | `cyclecount` | CycleCount | `state` | String (CycleCountState) |
| CyclecountPosition | `cyclecountposition` | CycleCount | `state` | String (CycleCountState) |
| FixLocationAssignment | `fixlocationassignment` | Stock | `active` | Boolean |
| Goodsreceipt | `goodsreceipt` | Receipt | — | — |
| Goodsreceiptposition | `goodsreceiptposition` | Receipt | — | — |
| InventoryRecord | `inventoryrecord` | Stock | — | — |
| Itemdata | `itemdata` | Item Master | — | — |
| Itemunit | `itemunit` | Item Master | — | — |
| Location | `location` | Warehouse | `entityLock` | Integer (BusinessObjectLockState) |
| LocationArea | `locationarea` | Warehouse | — | — |
| LocationConstraint | `locationconstraint` | Warehouse | — | — |
| LocationRack | `locationrack` | Warehouse | — | — |
| LocationRackRow | `locationrackrow` | Warehouse | — | — |
| LocationType | `locationtype` | Warehouse | — | — |
| LosSequencenumber | `lossequencenumber` | System | — | — |
| LosSysprop | `lossysprop` | System | — | — |
| Message | `message` | System | `status` | String |
| MessageArchived | `messagearchived` | System | `status` | String |
| MywmsFunction | `mywmsfunction` | User | — | — |
| MywmsGroup | `mywmsgroup` | User | — | — |
| MywmsGroupMywmsRole | `mywms_group_mywms_role` | User | — | — |
| MywmsGroupMywmsUser | `mywms_group_mywms_user` | User | — | — |
| MywmsRole | `mywmsrole` | User | — | — |
| MywmsRoleMywmsFunction | `mywms_role_mywms_function` | User | — | — |
| MywmsUser | `mywmsuser` | User | — | — |
| MywmsUserMywmsRole | `mywms_user_mywms_role` | User | — | — |
| Pickingorder | `pickingorder` | PickingOrder | `state` | Integer (State) |
| PickingorderPosition | `pickingorderposition` | PickingOrder | `state` | Integer (State) |
| PickingorderUnitload | `pickingorderunitload` | PickingOrder | `state` | Integer (State) |
| Printer | `printer` | System | — | — |
| Queryrepository | `queryrepository` | System | — | — |
| Replenishorder | `replenishorder` | Replenishment | `state` | Integer (State) |
| Section | `section` | Warehouse | — | — |
| Shipperid | `shipperid` | Shipping | — | — |
| Shippingmethod | `shippingmethod` | Shipping | — | — |
| ShippingmethodShipperid | `shippingmethodshipperid` | Shipping | — | — |
| Stockrecord | `stockrecord` | Stock | — | — |
| Stockunit | `stockunit` | Stock | `entityLock` | Integer (BusinessObjectLockState) |
| Unitload | `unitload` | Unitload | `entityLock` | Integer (BusinessObjectLockState) |
| UnitloadRecord | `unitloadrecord` | Unitload | — | — |
| UnitloadType | `unitloadtype` | Unitload | — | — |

---

## Key Architectural Notes

### 1. No ORM Associations on Transactional Entities
All relationships between transactional entities are expressed as `Long *Id` fields. To traverse a relationship, you must call the corresponding repository explicitly:
```java
// Correct v1 pattern
Itemdata item = itemdataRepository.findById(stockunit.getItemdataId()).orElseThrow(...);

// This will NOT work — no @ManyToOne exists
stockunit.getItemdata();  // compile error
```

### 2. Exception: User/Role/Group Graph Uses ORM
`MywmsUser`, `MywmsRole`, `MywmsGroup` use `@ManyToMany` with `@JoinTable`. This is the sole exception. The junction tables (`MywmsGroupMywmsRole`, `MywmsGroupMywmsUser`, `MywmsRoleMywmsFunction`, `MywmsUserMywmsRole`) also exist as standalone `@Entity` classes for direct query access.

### 3. Denormalized Audit Log Entities
`Stockrecord`, `UnitloadRecord`, and `InventoryRecord` are append-only audit logs. Related entity data is stored as denormalized strings (names, labels, numbers) at the time of the event, not as FK Longs. Do not attempt to join from these tables to live entities.

### 4. Table Naming Convention
No entity uses `@Table(name=...)`. Hibernate's default physical naming strategy maps the Java class name directly to a lowercase table name. Multi-word class names like `BillofladingPosition` (note: one-word compound `Billoflading`) map to `billofladingposition`.

### 5. View-Backed Entities Use Row-Number PKs
All view entities use `rowId = row_number() OVER ()` as their synthetic PK. These IDs are not stable across queries and cannot be used for FK references or caching.

### 6. Notable Field Name Typo
`Itemdata.defultypeId` — the field name contains a deliberate-in-practice typo (`defult` instead of `default`). This is the actual Java field name and PostgreSQL column name. Do not "correct" it without a migration.

### 7. Self-Referential FKs
- `Unitload.carrierunitloadId` → `Unitload.id` (parcel-on-pallet hierarchy)
- `Itemunit.baseunitId` → `Itemunit.id` (unit-of-measure hierarchy)

### 8. `LosSequencenumber` Has a String PK
Unlike every other entity, `LosSequencenumber` uses `classname` (String) as its `@Id`, not a Long. It is the sequence number generator table.


---

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |

**Re-verify every 90 days.** Next due: **2026-07-29**.
