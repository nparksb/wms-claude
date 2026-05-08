---
title: "WMS v1 — Receiving & Putaway Workflow"
type: workflow
status: active
version: v1
scope: receiving-putaway
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-04-26
verified_by: code read of v1/wms-api ReceivingService + AdviceService + AdviceRestController + MobilePutAwayService + GoodsReceiptPositionService
related:
  - wms2-receiving-putaway-workflow.md
tags:
  - workflow
  - receiving
  - putaway
  - wms1
---

## TL;DR
- Documents the full inbound flow in `v1/wms-api`: OMS pushes an `Advice` (ASN) → operator physically receives goods → `Stockunit`/`Unitload` rows created → mobile putaway moves stock to a storage slot.
- Three phases: **Advice lifecycle** (`OPEN → FINISHED` string states via `AdviceService`), **Physical receive** (`ReceivingService.receiveGoods` — creates `Goodsreceipt`, `Goodsreceiptposition`, `Stockunit`, `Unitload`), **Putaway** (`MobilePutAwayService` — mobile scan-and-confirm to a location).
- RETURN advices are fully received and finished in the same REST request (`PUT /rest/advice/create`) with no operator action required.
- Critical constraint: `ReceivingService` has no class-level `@Transactional` — a mid-loop failure leaves partial rows in the DB; `AdviceService` does carry `@Transactional(rollbackFor=...)`.
- `INBOUND_UPDATE_STOCK_IMMEDIATELY` sysprop (default `true`) controls whether a stock-change message fires to OMS on each REGULAR receive; RETURN advices always fire regardless.
- Over-delivery is blocked per `advice.allowoverdelivery` flag; max cases per call gated by `MAXIMUM_RECEIVING_DURING_INBOUND` sysprop (default 100).
- Read this doc for: stuck/duplicate goods receipt rows, RETURN auto-receive failures, putaway location mismatches, `FixLocationAssignment` enforcement during putaway, or OMS callback (`/rest/advice/accept`) behaviour.

# WMS v1 — Receiving & Putaway Workflow

**Scope:** Physical inbound flow in `v1/wms-api` — from OMS advice push through goods receipt, stock creation, and putaway to a storage location · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26

---

## 1. Overview

Receiving turns a promised inbound shipment (an `Advice` / ASN pushed by OMS) into physical stock at a warehouse location. The flow spans three phases:

1. **Advice lifecycle** — the paper trail: `OPEN → FINISHED` (String states). v1 uses fewer intermediate states than v2; the main operational states are `OPEN` and `FINISHED`.
2. **Physical receive** — desktop/scanner-driven ingestion that creates `Goodsreceipt`, `Goodsreceiptposition`, `Stockunit`, and `Unitload` rows per case. Owner: `ReceivingService.receiveGoods()`.
3. **Putaway** — mobile-driven movement from the inbound workstation / putaway lane to a storage slot. Owner: `MobilePutAwayService`.

Three things to hold in mind for v1:

- **No `@Transactional` on `ReceivingService`** — the class has no class-level `@Transactional`. Each call to `receiveGoods` persists incrementally; a mid-loop failure leaves partial rows. `AdviceService` carries `@Transactional(rollbackFor={BusinessException, FacadeException})` at class level.
- **`RETURN` advices are auto-received on import** — when OMS pushes a RETURN advice via `/rest/advice/create`, the controller immediately calls `receiveGoods` for every position and finishes the advice in the same request. No warehouse operator action required.
- **`INBOUND_UPDATE_STOCK_IMMEDIATELY` (default `true`)** gates whether a stock-change message fires to OMS during each receive for REGULAR advice. RETURN advices always fire, ignoring this flag.

---

## 2. Entity Cast

| Entity | Role | State field |
|---|---|---|
| `Advice` | Header for a promised inbound shipment | String `state` (`AdviceState.*`) |
| `Adviceposition` | Line — SKU + expected qty | String `state` (same set) |
| `Goodsreceipt` | Header for the physical receiving event (one per advice) | — (no state) |
| `Goodsreceiptposition` | One physical case received | — |
| `Unitload` | The pallet / box (case) that holds received stock | — |
| `Stockunit` | Amount of a SKU on a unit load | — |
| `Location` | Physical slot or workstation | — |
| `FixLocationAssignment` | Item → designated pick-face binding (enforced during putaway) | — |

**Number prefixes** (from `WmsConstants.EntityPrefixes`):

| Entity | Prefix |
|---|---|
| `Advice` | `IBOL` |
| `Goodsreceipt` | `GRT` |
| `Goodsreceiptposition` | `GRP` |

---

## 3. Advice Lifecycle

```
  OMS pushes advice via REST
            │
            │  AdviceRestController.create / createTransfer / createHubAndSpoke
            ▼
   Advice.state = OPEN
   Adviceposition.state = OPEN
            │
            │  (RETURN type: auto-received immediately in the same REST request)
            │  (REGULAR/TRANSFER: operator performs physical receive at desktop)
            │
            │  ReceivingService.receiveGoods()  [ReceivingService.java:308]
            │  → Goodsreceipt created (first call per advice)
            │  → Goodsreceiptposition created per case
            │  → Unitload + Stockunit created per case
            │
            │  AdviceService.close() [REGULAR]         [AdviceService.java:270]
            │  AdviceService.acceptTransferAdvice() [TRANSFER] [AdviceService.java:381]
            │  AdviceService.acceptHubAndSpokeAdvice() [HUB_AND_SPOKE] [AdviceService.java:122]
            ▼
   Advice.state = FINISHED
   Adviceposition.state = FINISHED
            │
            ▼
   Post-commit OMS callback (type-dependent)
```

### AdviceState constants (`WmsConstants.AdviceState`)

| Constant | String value | Meaning |
|---|---|---|
| `CREATED` | `"CREATED"` | Just created / received — rarely dwelt in for long |
| `OPEN` | `"OPEN"` | Allowed for processing; not yet closed |
| `PROCESSING` | `"PROCESSING"` | Started receiving (defined but not set by current code paths) |
| `CLOSED` | `"CLOSED"` | Finished receiving; info not yet sent to ERP |
| `FINISHED` | `"FINISHED"` | Closed and OMS notified |
| `CANCELLED` | `"CANCELLED"` | Aborted |

In practice, v1 advice moves directly `OPEN → FINISHED`. The intermediate `PROCESSING` and `CLOSED` states are defined but not written in the current service code.

---

## 4. Advice Creation — REST Entry Points

All `/rest/advice/**` endpoints are **unauthenticated** (`SecurityConfiguration` excludes `/rest/**`). Requests are validated against `facility_code` in `AbstractRestController.validateWarehouse()`.

### 4.1 REGULAR and RETURN — `PUT /rest/advice/create`

`AdviceRestController.create` (`AdviceRestController.java:104`)

- Accepts `List<AdviceDto>`. Each DTO must carry: `referenceId`, `type`, `clientId`, and one or more `positions`.
- Creates one `Advice` + N `Adviceposition` rows, all with `state = OPEN`.
- **RETURN auto-receive path** (`AdviceRestController.java:271-317`): after saving positions, iterates every `Adviceposition` and calls `receivingService.receiveGoods(pos.getId(), null, false, notifiedAmount, notifiedAmount, 1, boxtypeId, printer)`. Then calls `advicepositionRepository.updateAdvicepositionToStateByAdviceId(FINISHED, ...)` and `adviceRepository.updateAdviceToStateById(FINISHED, ...)` in-place. The result: RETURN advice is fully received and finished in a single REST call, with no operator intervention.
- A `Message` record with type `ADVICE_IMPORT` is written on success and failure.

**Validation guards:**
- Duplicate `referenceId` (externalid) → `ENTITY_ALREADY_EXITS`
- Unknown `clientId` → `ENTITY_ALREADY_EXITS`
- RETURN or TRANSFER type with `client.enablereceiving == false` → `NOT_ENABLLED_FOR_RECEIVING`
- Unknown SKU (`sku` in position) → `ENTITY_DOES_NOT_EXISTS`
- Unknown box type (`boxId`) → `ENTITY_DOES_NOT_EXISTS`
- Duplicate SKU within one advice → `NOT_UNIQUE_VALUE`

### 4.2 TRANSFER — `PUT /rest/advice/createTransfer`

`AdviceRestController.createTransfer` (`AdviceRestController.java:355`)

- Accepts `BillOfLadingWebServiceDto`. Only one order per batch is allowed (`TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH`).
- Creates `Advice` with `type = TRANSFER`, `allowshortdelivery = false`, `allowoverdelivery = false`, `externalid = transferId`.
- Each `OrderPositionDto` becomes one `Adviceposition` with `notifiedcases = 1`.
- Duplicate `transferId` → `ENTITY_ALREADY_EXITS`.
- A `Message` record with type `ADVICE_TRANSFER_IMPORT` is written.

### 4.3 HUB_AND_SPOKE — `PUT /rest/advice/createHubAndSpoke`

`AdviceRestController.createHubAndSpoke` (`AdviceRestController.java:468`)

- Accepts `BillOfLadingWebServiceDto` with a nested pallet/parcel manifest.
- `destinationWarehouse` must match the warehouse's `MULTIWAREHOUSE_IDENTIFIER` sysprop.
- Creates `Advice` with `type = HUB_AND_SPOKE` under the system client.
- Each parcel (`OrderDto`) becomes one `Adviceposition` carrying `palletlabel`, `parcellabel`, `manifestlocation`, and `shipperidId`. `itemdataId` is set to `null` — no SKU content at inbound time.
- Auto-creates `Shipperid` records for unknown shipper IDs.
- A `Message` record with type `ADVICE_HUB_AND_SPOKE_IMPORT` is written.

### 4.4 Reopen — `POST /rest/advice/reopen`

`AdviceRestController.reopen` (`AdviceRestController.java:631`) — **throws `RuntimeException("method not supported")`**. Not implemented. Do not call.

---

## 5. Physical Receive — `ReceivingService.receiveGoods`

Core inbound operation at `ReceivingService.java:308`. Called from the desktop receiving UI when an operator enters quantities at the inbound workstation, or called programmatically for RETURN advices.

### 5.1 Preconditions

Before entering the per-case loop, `receiveGoods` enforces:

1. `amountBottles`, `amountBottlesPerCase`, `amountCases` all ≥ 1 (`argumentMustBeGreaterZero`).
2. `amountCases` ≤ sysprop `MAXIMUM_RECEIVING_DURING_INBOUND` (default 100) — `exceedMaxAllowedAmountForReceivingBySysProp`.
3. Printer is reachable (CUPS ping) — `Printer not available. Cannot process receiving.`
4. `Adviceposition.state == OPEN` — `unexpectedStateFound`.
5. `Advice.state == OPEN` — `unexpectedStateFound`.
6. Over-delivery guard: if `advice.allowoverdelivery == false`, the sum of existing `Goodsreceiptposition.amount` for this position plus the new `amountBottles` must not exceed `adviceposition.notifiedamount`.
7. Carrier (pallet) must be at `InboundWorkstation` location if `storeOnCarrier == true` — `carrierNotAtWorkstation`.

### 5.2 Goodsreceipt header creation

`ReceivingService.java:440-457`

If no `Goodsreceipt` exists for the advice yet, one is created on first call:
```
Goodsreceipt.clientId     = client.id
Goodsreceipt.adviceId     = advice.id
Goodsreceipt.goodsinlocationId = InboundWorkstation.id
Goodsreceipt.operatorId   = current user
Goodsreceipt.number       = BasicService.generateNumber("GRT", "GOODS_RECEIPT")
```
Subsequent receives for the same advice reuse the existing `Goodsreceipt` (first element of the list).

### 5.3 Per-case loop (`ReceivingService.java:489-533`)

The loop iterates once per case. Given `amountBottles` and `amountBottlesPerCase`, each iteration:

```
amount = min(amountBottles, amountBottlesPerCase)   // last case may be partial
amountBottles -= amountBottlesPerCase

1. unitloadService.createUnitload(InboundWorkstation, unitloadTypeId, clientId, CODE_RECEIVING_*)
2.   unitload.boxtypeId = boxType.id
3. stockunitBusinessService.createStockUnit(client, itemdata, amount, false, unitload, CODE_RECEIVING_*, adviceposition.number)
4. Goodsreceiptposition row:
     .goodsreceiptId     = goodsreceipt.id
     .advicepositionId   = adviceposition.id
     .unitloadId         = unitload.id
     .stockunitId        = stockUnit.id
     .amount             = stockUnit.amount
     .number             = BasicService.generateNumberWithGoodsReceipt(goodsreceipt)
5. if (carrier == null):
     unitloadBusinessService.transferUnitLoadToLocation(unitload, itemdata.putawaylocation, ...)
   else:
     unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier, ...)
6. createCaseLabel(unitload, stockUnit, advice, goodsreceipt, warehouseName) → append to outputStream
```

Each iteration creates: 1 `Unitload` + 1 `Stockunit` + 1 `Goodsreceiptposition`.

**Activity codes** used for stock records:

| Advice type | Code constant | String value |
|---|---|---|
| REGULAR | `CODE_RECEIVING_REGULAR` | `"RECEIVING"` |
| RETURN | `CODE_RECEIVING_RETURN` | `"RETURN"` |
| TRANSFER | `CODE_RECEIVING_TRANSFER` | `"RECEIVING_TRANSFER"` |

### 5.4 OMS stock-change gate (`ReceivingService.java:539-557`)

```java
switch (advice.getType()) {
    case REGULAR:
        if (Boolean.parseBoolean(sysprop(INBOUND_UPDATE_STOCK_IMMEDIATELY_KEY))) {
            list.add(getStockChangeDTO(..., CODE_RECEIVING_REGULAR + ": " + adviceposition.externalid));
        }
        break;
    case RETURN:
        list.add(getStockChangeDTO(..., CODE_RECEIVING_RETURN + ": " + adviceposition.externalid));
        break;
    case TRANSFER:
        // intentionally empty — no stock-change message
        break;
}
messageService.sendStockChangeMessage(list);
```

- `INBOUND_UPDATE_STOCK_IMMEDIATELY` (default `true`) — controls REGULAR only. When `false`, OMS receives no per-receive message; visibility depends on a nightly stock export.
- RETURN always fires. TRANSFER never fires.

### 5.5 Label printing (`ReceivingService.java:562-568`)

Label printing is deferred to after the loop. The ZPL template is fetched from sysprop `PRINTING_ZPL_CASE_LABEL_KEY`. If sysprop `PRINT_CASE_LABEL` is `true`, the concatenated byte stream is sent via `printService.cupsPrint(printer.address, bytes)`.

Labels are printed after all cases are processed, not per-case. If printing fails, a `BusinessException("Cannot connect to the printer")` is thrown — but by this point, all rows have already been persisted (no `@Transactional` rollback).

---

## 6. Goods Receipt Position — Adjustments and Deletions

`GoodsReceiptPositionService` (`GoodsReceiptPositionService.java`) handles post-receive corrections. Both methods carry `@Transactional(rollbackFor={BusinessException, FacadeException})`.

### 6.1 `adjust(position, newAmount)` — `GoodsReceiptPositionService.java:65`

Allowed only when `Advice.state == OPEN`. Changes `Goodsreceiptposition.amount` and calls `stockunitBusinessService.changeAmount(stockUnit, newAmount, STOCK_ALTERED, ...)`. If `newAmount == 0`, delegates to `deletePosition`. If `INBOUND_UPDATE_STOCK_IMMEDIATELY` is `true`, fires a stock-change message for the delta, deferred to post-commit via `OmsNotificationHelper.deferToCommit`.

### 6.2 `delete(position)` — `GoodsReceiptPositionService.java:104`

Guards:
- `Advice.state == OPEN`
- `Stockunit` must still be linked to the `Unitload` recorded on the position (unless already flagged `GOING_TO_DELETE`)
- `Unitload` must still be in an area where `useforgoodsin == true`

On delete: marks `Stockunit` for nirvana (`STOCK_REMOVED`), sends `Unitload` to nirvana if no remaining stock or children, deletes the `Goodsreceiptposition` row. If `INBOUND_UPDATE_STOCK_IMMEDIATELY` is `true`, fires a negative stock-change message (deferred post-commit).

---

## 7. Advice Close / Accept

### 7.1 REGULAR — `AdviceService.close` (`AdviceService.java:270`)

Only allowed in state `OPEN`. Only allowed for `type == REGULAR`. Sets `Advice.state = FINISHED` and bulk-updates all positions to `FINISHED`. Builds `AdviceDto` from actual `Goodsreceiptposition` rows (counts boxes by GRP list size, bottles by summing amounts). Fires OMS callback post-commit via `OmsNotificationHelper.deferToCommit`:

```
POST WEBSERVICE_CLOSE_ADVICE_URL
payload: AdviceDto {referenceId, clientId, positions[{sku, amountOfBoxes, amountOfBottles}], ...}
Message type: ADVICE_CLOSE
```

### 7.2 TRANSFER — `AdviceService.acceptTransferAdvice` (`AdviceService.java:381`)

Allowed in states `OPEN` or `CREATED`. If `allowshortdelivery == false`, all positions must have received at least `notifiedamount` bottles. Sets `Advice` and all positions to `FINISHED`. Fires OMS callback post-commit:

```
POST WEBSERVICE_ACCEPT_TRANSFER_URL
payload: AcceptTransferDto {transferId}
Message type: ADVICE_ACCEPT_TRANSFER
```

### 7.3 HUB_AND_SPOKE — `AdviceService.acceptHubAndSpokeAdvice` (`AdviceService.java:122`)

Allowed in state `OPEN`. Only allowed for `type == HUB_AND_SPOKE`. This method does much more than finalize:

1. Collects unique `palletlabel` values from all positions.
2. Validates none of those labels already exist as `Unitload` records.
3. Creates one `Unitload` (type = Pallet) per unique pallet label at the given location.
4. Creates a `CustomerorderBatch` with `type = HUB_AND_SPOKE`, `state = STARTED`.
5. For each `Adviceposition`: creates a `Unitload` (type = Package) for the parcel, transfers it onto the pallet, sets position `state = FINISHED`, creates a `Customerorder` linked to the batch.
6. Sets `Advice.state = FINISHED`.
7. Fires OMS callback post-commit:

```
POST WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL
payload: HubAndSpokeAcceptDto {facilityCode, positions[externalid]}
Message type: ADVICE_HUB_AND_SPOKE_RECEIVED
```

---

## 8. Pallet / Carrier Management

These methods in `ReceivingService` manage the inbound carrier pallet that groups received cases.

| Method | Line | Activity code | Purpose |
|---|---|---|---|
| `createPallet` | `ReceivingService.java:662` | `CODE_CREATE_INBOUND_PALLET` | Create a new pallet UL at `InboundWorkstation` |
| `assignPallet` | `ReceivingService.java:606` | `CODE_ASSIGN_INBOUND_PALLET` | Move pallet to `InboundWorkstation`; validates pallet is at one of: InboundWorkstation, PutAwayLane, EmptyPallets, Clearing |
| `unassignPallet` | `ReceivingService.java:640` | `CODE_UNASSIGN_INBOUND_PALLET` | Move pallet to `PutAwayLane` (if has children) or `EmptyPallets` (if empty) |
| `resolvePalletByLabelId` | `ReceivingService.java:577` | — | Look up a pallet by label; validates label matches `STRING_PATTERN_INBOUND_PALLET` regex (default `CART-\d{4}\|IN-\d{6}`) |

The `verifyPalletOrCartLabel` method (`ReceivingService.java:571`) enforces the pallet label regex from sysprop `STRING_PATTERN_INBOUND_PALLET`. A label that does not match throws `noValidStringForCartOrInboundPallet`.

---

## 9. Putaway — Mobile Flow

Owner: `MobilePutAwayService` (`service/mobile/MobilePutAwayService.java`). No class-level `@Transactional`; transaction behavior is per-call depending on Spring defaults.

| Method | Line | Purpose |
|---|---|---|
| `findUnitLoad` | `MobilePutAwayService.java:68` | Validate scanned UL is in PutAwayLane; transfer to operator's location |
| `calculatePutAwayList` | `MobilePutAwayService.java:184` | Build SKU-keyed list of flowbin/overstock candidate locations |
| `updateCurrentItemDataUnitLoadList` | `MobilePutAwayService.java:327` | Refresh the per-SKU box list as operator works through the pallet |
| `verifyScannedLocation` | `MobilePutAwayService.java:369` | Validate `FixLocationAssignment` constraint on the scanned location |
| `storeBoxOnLocation` | `MobilePutAwayService.java:417` | Box-level putaway: FLOWBIN merges stock into assigned UL; OVERSTOCK transfers UL to location |
| `storePalletOnLocation` | `MobilePutAwayService.java:138` | Pallet-level putaway: moves the full pallet to the target location |
| `storePalletBackOnPutawayLane` | `MobilePutAwayService.java:168` | Error-recovery: return pallet to `PutAwayLane` |

### 9.1 Scan flow (happy path)

```
Operator scans unit load (pallet or box)
   │
   ▼ findUnitLoad()
   Validate: UL is in Inbound area (useforgoodsin) or Clearing
   Validate: UL is specifically at PutAwayLane (not still at InboundWorkstation)
   Validate: if pallet — must have children; if box — must be type "Case"
   Transfer UL to operator's named location (CODE_ASSIGN_PUT_AWAY)
   │
   ▼ calculatePutAwayList()
   For each box on the pallet (or the single box):
     Get distinct SKUs → for each SKU:
       locationRepository.getStorageLocationsForPutAwayItemData(itemId)
       Classify by LocationType.sltname:
         "flowbin"           → flowBinLocationList
         "overstock box"     → overstockLocationList
         "overstock pallet"  → overstockLocationList
       Sort each list by DefaultStrategy (rack + rack-row)
   │
   ▼ Operator walks to suggested location, scans it
   │
   ▼ verifyScannedLocation()
   Check LocationArea.useforstorage or location.staginglane
   If FLOWBIN: enforce FixLocationAssignment (see §9.3)
   │
   ▼ storeBoxOnLocation() [per box] or storePalletOnLocation() [whole pallet]
   │
   ▼ updateCurrentItemDataUnitLoadList()
   Update remaining boxes for current SKU; flag emptyPallet when all done
```

### 9.2 Target-location classification

`MobilePutAwayService.java:240-257`

```java
List<Location> resultList = locationRepository.getStorageLocationsForPutAwayItemData(currentSku.getId());
for (Location location : resultList) {
    LocationType locationType = locationTypeRepository.findById(location.getTypeId()).get();
    switch (locationType.getSltname()) {
        case "flowbin":          // WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN
            putAwayItemDto.getFlowBinLocationList().add(location.getName()); break;
        case "overstock box":    // WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_OVERSTOCK
        case "overstock pallet": // WmsConstants.STORAGE_LOCATION_TYPE_PALLET_RESTRICTION_OVERSTOCK
            putAwayItemDto.getOverstockLocationList().add(location.getName()); break;
    }
}
```

FLOWBIN locations are pick-face (fast-moving) — the UI prioritizes them. OVERSTOCK absorbs overflow. Locations of any other `sltname` are silently ignored.

### 9.3 Fixed-assignment constraint

`MobilePutAwayService.java:369-414`

When the operator scans a FLOWBIN location, `verifyScannedLocation` checks:

- If the **item** has a `FixLocationAssignment`: scanned location must match the assignment → else `itemDataNotMatchFixedAssignment`.
- If the item has **no** assignment but the **scanned location** has an assignment: reject → `scannedLocationHasDifferentFixedAssignment`.
- If neither side has an assignment: allow.

### 9.4 `storeBoxOnLocation` — FLOWBIN vs OVERSTOCK

`MobilePutAwayService.java:417-470`

```
FLOWBIN:
  Look up FixLocationAssignment for the scanned location
  If no assignment exists: create one (fixLocationAssignmentService.createFixedLocationAssignment)
  stockunitBusinessService.transferStockToUnitLoad(
      sourceStockUnit, assignedUnitLoad, amount, CODE_PUT_AWAY, ..., removeUnitLoadIfEmpty=true)
  // removeUnitLoadIfEmpty=true prevents stale-object-state on consecutive empty transfers

OVERSTOCK (box or pallet) or staging lane:
  unitloadBusinessService.transferUnitLoadToLocation(unitLoad, location, CODE_PUT_AWAY, ...)
```

### 9.5 Location constants

| Constant | String value | Role |
|---|---|---|
| `STORAGE_LOCATION_INBOUND_NAME` | `"InboundWorkstation"` | Desktop receiving workstation |
| `STORAGE_LOCATION_PUTAWAY_LANE` | `"PutAwayLane"` | Staging area between receiving and putaway |
| `STORAGE_LOCATION_EMPTY_PALLETS` | `"EmptyPallets"` | Parking for unloaded pallets |
| `STORAGE_LOCATION_CLEARING` | `"Clearing"` | Exception holding area |

---

## 10. State Transitions Summary

```
Advice / Adviceposition states
──────────────────────────────
OPEN
 │
 ├── receiveGoods() called per adviceposition (positions stay OPEN during receive)
 │
 ├── close() [REGULAR]                → FINISHED  (AdviceService.java:296)
 ├── acceptTransferAdvice() [TRANSFER] → FINISHED  (AdviceService.java:422)
 ├── acceptHubAndSpokeAdvice() [H&S]  → FINISHED  (AdviceService.java:229)
 └── RETURN auto-close via controller → FINISHED  (AdviceRestController.java:316-317)

CANCELLED — defined in AdviceState but no service path currently writes this in v1
```

**Key service method references:**

| Action | Method | File:Line |
|---|---|---|
| Create REGULAR/RETURN advice | `AdviceRestController.create` | `AdviceRestController.java:104` |
| Create TRANSFER advice | `AdviceRestController.createTransfer` | `AdviceRestController.java:355` |
| Create HUB_AND_SPOKE advice | `AdviceRestController.createHubAndSpoke` | `AdviceRestController.java:468` |
| Receive goods (desktop) | `ReceivingService.receiveGoods` | `ReceivingService.java:308` |
| Create/assign inbound pallet | `ReceivingService.createPallet` / `assignPallet` | `ReceivingService.java:662` / `606` |
| Unassign pallet | `ReceivingService.unassignPallet` | `ReceivingService.java:640` |
| Close REGULAR advice | `AdviceService.close` | `AdviceService.java:270` |
| Accept TRANSFER advice | `AdviceService.acceptTransferAdvice` | `AdviceService.java:381` |
| Accept HUB_AND_SPOKE advice | `AdviceService.acceptHubAndSpokeAdvice` | `AdviceService.java:122` |
| Adjust GRP amount | `GoodsReceiptPositionService.adjust` | `GoodsReceiptPositionService.java:65` |
| Delete GRP | `GoodsReceiptPositionService.delete` | `GoodsReceiptPositionService.java:104` |
| Mobile: scan unit load | `MobilePutAwayService.findUnitLoad` | `MobilePutAwayService.java:68` |
| Mobile: calc putaway list | `MobilePutAwayService.calculatePutAwayList` | `MobilePutAwayService.java:184` |
| Mobile: verify location | `MobilePutAwayService.verifyScannedLocation` | `MobilePutAwayService.java:369` |
| Mobile: store box on location | `MobilePutAwayService.storeBoxOnLocation` | `MobilePutAwayService.java:417` |
| Mobile: store pallet on location | `MobilePutAwayService.storePalletOnLocation` | `MobilePutAwayService.java:138` |
| Mobile: return pallet to lane | `MobilePutAwayService.storePalletBackOnPutawayLane` | `MobilePutAwayService.java:168` |

---

## 11. OMS Callbacks

All callbacks use `OmsNotificationHelper.deferToCommit(...)` — fire only after the enclosing transaction commits. A rollback silently drops the callback.

| Callback | Fired from | Sysprop URL key | Message type |
|---|---|---|---|
| Close advice | `AdviceService.close` (line 344) | `WEBSERVICE_CLOSE_ADVICE_URL` | `ADVICE_CLOSE` |
| Accept transfer | `AdviceService.acceptTransferAdvice` (line 434) | `WEBSERVICE_ACCEPT_TRANSFER_URL` | `ADVICE_ACCEPT_TRANSFER` |
| Accept hub-and-spoke | `AdviceService.acceptHubAndSpokeAdvice` (line 233) | `WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL` | `ADVICE_HUB_AND_SPOKE_RECEIVED` |
| Per-receive stock change | `ReceivingService.receiveGoods` (line 557) | via `messageService.sendStockChangeMessage` | — |

Note: the per-receive stock-change message in v1 is sent **synchronously inside the `receiveGoods` method** (not via `deferToCommit`), unlike the advice-close callbacks. If the transaction rolls back, this message may already have been dispatched.

---

## 12. Common Failure Modes

| Symptom | Root cause | Fix path |
|---|---|---|
| "Printer not available. Cannot process receiving." | CUPS printer unreachable before receive starts | Check printer address in `LosSysprop`, verify CUPS connectivity; `receiveGoods` short-circuits at line 322 before creating any rows |
| Advice stuck in `OPEN` after receiving | `close()` only accepts `OPEN` state, only for REGULAR; TRANSFER requires `acceptTransferAdvice` | Confirm advice type and call the correct close method |
| `unexpectedStateFound` on receive | `Adviceposition.state` is not `OPEN` — position was already finished or cancelled | Query `adviceposition` table; if state is `FINISHED` the position was closed, not an error |
| `exceedMaxAllowedAmountForReceivingBySysProp` | `amountCases` exceeds sysprop `MAXIMUM_RECEIVING_DURING_INBOUND` (default 100) | Split the receive into smaller batches or raise the sysprop |
| "Not allowed to receive more than notified!" | `advice.allowoverdelivery == false` and received qty would exceed notified | Matches TRANSFER advices (always false); check actual vs notified in `goodsreceiptposition` table |
| OMS stock not updated after REGULAR receive | `INBOUND_UPDATE_STOCK_IMMEDIATELY == false` | Check sysprop; if false, stock update is deferred to nightly export |
| Label not printed after receive | Printer down at label-print phase (after loop); no `@Transactional` — rows already committed | Re-print via print service; rows are not rolled back |
| GRP delete fails: "UnitLoad not in area for goods in anymore" | Unitload was already moved out of inbound area before GRP was deleted | Putaway completed before correction; admin must handle stock adjustment separately |
| `unitLoadStillOnInboundWorkstation` on mobile putaway scan | Box/pallet is at `InboundWorkstation`, not `PutAwayLane` | Operator must unassign the pallet via desktop first; `unassignPallet` moves it to `PutAwayLane` |
| `itemDataNotMatchFixedAssignment` on mobile putaway | Scanned FLOWBIN location has a `FixLocationAssignment` for a different SKU | Put the box at an OVERSTOCK location, or admin must update the `FixLocationAssignment` |
| Hub-and-spoke accept: "Can not accept. Pallet label already exists" | Pallet label in the advice matches an existing `Unitload` in the DB | Duplicate transfer pushed by OMS; check `advice.transferId` and `unitload.labelid` |
| `NoSuchElementException` on RETURN auto-receive | `boxtypeRepository.findByName(...)` or `printerRepository.findByTypeAndProcessdefaultTrue(RETURN)` returns empty Optional unwrapped with `.get()` | Ensure a default RETURN printer exists in the `printer` table (`processdefault=true`, `type=RETURN`) and item has a resolvable box type |

---

## 13. v1 vs v2 Differences

Key differences for developers familiar with v2 (see [wms2-receiving-putaway-workflow.md](wms2-receiving-putaway-workflow.md)):

| Area | v1 | v2 |
|---|---|---|
| `ReceivingService` transaction | No `@Transactional` — partial commits possible on mid-loop failure | `@Transactional` — full rollback on failure |
| RETURN receive | Auto-received synchronously in REST request | Operator receives manually like REGULAR |
| Advice intermediate states | `PROCESSING` / `CLOSED` defined but never written in practice | `PROCESSING` is actively used during receive |
| `Stockrecord` creation | Not created directly by `receiveGoods`; `createStockUnit` inside `StockunitBusinessService` may create one | `Stockrecord` explicitly created |
| Stock-change message delivery | Sent synchronously inside `receiveGoods` (not deferred) | Sent via `TransactionSynchronizationManager` (post-commit) |
| `AdviceRestController.reopen` | Throws `RuntimeException` — stub only | Not implemented / N/A |
| `MobilePutAwayService` `@Transactional` | No class-level annotation; individual methods rely on default Spring behavior | `@Transactional("tenantTransactionManager")` on each method |
| Multi-tenant routing | Single datasource per deploy; no tenant header routing in service layer | 4-char routing key + `TenantAwareDataSourceRouter` |

---

## 14. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | `AdviceRestController` (create, createTransfer, createHubAndSpoke, reopen stub); `ReceivingService` (receiveGoods full loop, pallet management, label print); `AdviceService` (close, acceptTransferAdvice, acceptHubAndSpokeAdvice); `GoodsReceiptPositionService` (adjust, delete); `MobilePutAwayService` (all 7 methods, location classification, fixed-assignment); `WmsConstants` AdviceState/AdviceType/EntityPrefixes/location type strings | All file:line refs confirmed | Code read (direct) |

**Re-verify every 90 days.** Next due: **2026-07-25** — `ReceivingService` is actively modified for receiving fixes; MobilePutAwayService has SBDEV-2102 history.
