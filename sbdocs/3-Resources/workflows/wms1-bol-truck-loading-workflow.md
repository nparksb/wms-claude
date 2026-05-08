---
title: "WMS v1 — BOL / Truck Loading / Shipping Workflow"
type: workflow
status: active
version: v1
scope: bol-truck-loading
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-04-26
verified_by: code read of v1/wms-api BillofladingService + BillofladingPositionService + MobileTruckLoadingService + ParcelMonitorViewService + BillOfLadingController + TruckLoadingController + WmsConstants
related:
  - ./wms2-bol-truck-loading-workflow.md
tags:
  - workflow
  - bol
  - truck-loading
  - shipping
  - wms1
---

## TL;DR

- Documents the full BOL (Bill of Lading) lifecycle in `v1/wms-api`: order packing through truck loading to shipment and OMS callback.
- **State machine:** `CREATED → OPEN → TRUCK_LOADING → CLOSED` (or `TRANSFER` for intracompany); cancel yields `CANCELLED`.
- **Key services:** `BillofladingService` (hottest file, 38 touches), `ParcelMonitorViewService` (desktop path), `MobileTruckLoadingService` (mobile path), `BillofladingPositionService`.
- **`closeBOL` constraints:** holds an in-memory set guard + DB pessimistic lock; bulk-preloads all positions (Phases 1–2) to avoid N+1; fires single post-commit OMS callback `WEBSERVICE_ORDER_BATCH_SHIPPED` — rollback silently drops it.
- **v1 vs v2 delta:** v1 has only one OMS callback (`ORDER_BATCH_SHIPPED`); v2 adds `ORDER_BATCH_PALLETIZED` and `ORDER_BATCH_LOADED_TO_TRUCK`. No `LOADED_TO_TRUCK` customer order state in v1.
- **Consult this doc** when: debugging a stuck/unclosed BOL, investigating a missing OMS shipped callback, implementing BOL-related features, or comparing v1 vs v2 BOL behaviour.

# WMS v1 — BOL / Truck Loading / Shipping Workflow

**Scope:** From packed customer orders through BOL open / truck loading / close in `v1/wms-api` · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26

---

## 1. Overview

The BOL (Bill of Lading) flow is how picked+packed orders leave the warehouse. It spans a desktop path (`ParcelMonitorViewService`) and a mobile path (`MobileTruckLoadingService`) that converge on the same `Billoflading` state machine.

`BillofladingService` is the hottest file in the v1 codebase — touched 38 times. Its `closeBOL` method is the single most expensive state transition:

- Acquires an **in-memory `bolToClose` set** guard against concurrent closes on the same JVM.
- Uses a **DB pessimistic lock** (`findByIdForUpdate`) to guard against concurrent closes across JVM replicas.
- Bulk pre-loads all BOL positions and referenced entities into memory (Phases 1–2) to avoid N+1 queries.
- Bulk-updates all `BillofladingPosition` states in one native query (Phase 5).
- Bulk-finalizes all `Customerorder` + `CustomerorderPosition` rows to `FINISHED` (Phase 5).
- Bulk-transfers every pallet `Unitload` to the SHIPPED location (Phase 4).
- Bulk-sets entity locks on all unitloads + stock units (Phase 6).
- Fires the `WEBSERVICE_ORDER_BATCH_SHIPPED` OMS callback **post-commit** via a Spring `BolClosedEvent` + `@TransactionalEventListener` (Phase 8).

BOL state machine (all values are Strings — note double-L `CANCELLED`):

```
CREATED → OPEN → TRUCK_LOADING → CLOSED
                               └─► TRANSFER   (TRANSFER_INTRACOMPANY type only)
          └────► CANCELLED
```

Key difference from v2: v1 does **not** have a `LOADED_TO_TRUCK` customer order state or a post-commit `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` callback. The v1 mobile `scanGate` sets BOL state to `TRUCK_LOADING` and builds the position tree but does not advance the `Customerorder.state` further than `PALLETIZED`. The single OMS callback is `ORDER_BATCH_SHIPPED`, fired at BOL close.

---

## 2. Entity Cast

| Entity | Table / File | Role | State type |
|---|---|---|---|
| `Billoflading` | `model/Billoflading.java` | BOL header | `String state` (`BillOfLadingState.*`) |
| `BillofladingPosition` | `model/BillofladingPosition.java` | Position tree (pallet → parcel → stock) | `String state` (same constants) |
| `Customerorder` | `model/Customerorder.java` | Order being shipped | `Integer state` (`WmsConstants.State.*`) |
| `CustomerorderBatch` | `model/CustomerorderBatch.java` | Batch rollup | `Integer state` |
| `Unitload` | `model/Unitload.java` | Pallet / parcel physical carrier | `entityLock` (Integer) |
| `Stockunit` | `model/Stockunit.java` | SKU stock on the carriers | `entityLock` (Integer) |

BOL state constants: `WmsConstants.BillOfLadingState` at `service/WmsConstants.java:228–238`.

```java
// WmsConstants.java:228–238
public static final class BillOfLadingState {
    public static final String CREATED       = "CREATED";       // just created
    public static final String OPEN          = "OPEN";          // allowed for processing but not started yet
    public static final String TRUCK_LOADING = "TRUCK_LOADING"; // started the truck loading process
    public static final String TRANSFER      = "TRANSFER";      // shipped to another warehouse but not accepted yet
    public static final String CLOSED        = "CLOSED";        // finished truck loading, info sent to ERP
    public static final String CANCELLED     = "CANCELLED";     // aborted
}
```

BOL type constants: `WmsConstants.OrderBatchType` (used in `type` field):

| Type constant | Meaning |
|---|---|
| `REGULAR` | Standard outbound BOL |
| `HUB_AND_SPOKE` | Hub-and-spoke distribution |
| `TRANSFER_OFFSITE` | Offsite transfer orders |
| `TRANSFER_INTRACOMPANY` | Transfer between two warehouses within the same company |
| `CLUB` / `PICK_PACK` | **Not allowed** for `closeBOL` — rejected with `BusinessException` |

Entity lock states (Integer) relevant to BOL close:

| Constant | Value | Meaning |
|---|---|---|
| `BusinessObjectLockState.SHIPPED` | `405` | Applied to unitloads + stock on regular close |
| `BusinessObjectLockState.TRANSFER` | `404` | Applied to unitloads + stock on TRANSFER_INTRACOMPANY close |

---

## 3. BOL Lifecycle State Diagram

```
                   REST POST /v3/billOfLading/create
                   BillofladingService.createEntity:186
                              │
                              ▼
                     Billoflading.state = OPEN
                              │
          ┌───────────────────┴───────────────────┐
          │ Desktop path                           │ Mobile path
          │ POST /v3/billOfLading/palletize        │ POST /v3/truckLoading/scanGate
          │ → ParcelMonitorViewService             │ → MobileTruckLoadingService.scanGate:153
          │   .palletise:72  (palletize only)      │
          │   .palletiseAndTruckLoad:165            │
          └──────────────────┬────────────────────┘
                             │
                             ▼
                Billoflading.state = TRUCK_LOADING
                Customerorder.state = PALLETIZED
                BOL position tree created:
                  pallet BillofladingPosition (sourceId = pallet Unitload)
                  └─ parcel BillofladingPosition (carrierId = pallet pos, orderId)
                     └─ stock BillofladingPosition (carrierId = parcel pos, itemdataId, amount)
                             │
                             ▼
          REST GET /v3/billOfLading/closeOutboundBol/{id}
          or  POST /v3/billOfLading/closeOutboundBols
          → BillofladingService.closeBOL:263
                             │
              ┌──────────────┴──────────────────┐
              │ type != TRANSFER_INTRACOMPANY    │ type == TRANSFER_INTRACOMPANY
              ▼                                  ▼
     Billoflading.state = CLOSED       Billoflading.state = TRANSFER
     entityLock = SHIPPED              entityLock = TRANSFER
              │                                  │
              │                         REST GET /v3/billOfLading
              │                           /closeIntraCompanyTransfer/{transferId}
              │                         → BillofladingService.finishTransfer:1119
              │                                  │
              │                                  ▼
              │                        Billoflading.state = CLOSED
              │                        entityLock = SHIPPED
              │
              ▼
   Post-commit: WEBSERVICE_ORDER_BATCH_SHIPPED → OMS finishedShipping
   BOL terminal state: CLOSED
```

---

## 4. Step-by-Step Workflow

### Step 1 — Create BOL

**REST:** `POST /v3/billOfLading/create` (`BillOfLadingController:65`)
**Service:** `BillofladingService.createEntity:186`

What happens:

1. Resolves the system client (`clientService.getSystemClient()`).
2. Allocates BOL `id` from sequence.
3. Generates `number` using `BasicService.generateNumber("OBOL", "BILL_OF_LADING")` — prefix `OBOL`.
4. Generates `sharedUniqueBolId = UUID.randomUUID().toString()` (used as cross-system reference for intracompany transfers).
5. Sets `state = OPEN`, `shipped = null`, `version = 0`.
6. If `gate` is provided, resolves the gate `Location` and sets `outboundlocationId`.
7. Resolves the operator from `SecurityContextUtils.getUserName()` and sets `operatorId`.
8. Saves and returns the new BOL.

**Guard:** none at creation. Gate location is optional at create time — can be set on first mobile `scanGate`.

---

### Step 2 — Palletize Orders (Desktop path)

**REST:** `POST /v3/billOfLading/palletize` (`BillOfLadingController:316`)
**Service:** `ParcelMonitorViewService.palletise:72` (palletize only, no BOL yet) or `.palletiseAndTruckLoad:165` (palletize + load in one call)

#### `palletise` (palletize only) — `ParcelMonitorViewService:72`

1. Accepts a list of `ParcelMonitorDto` objects (customer order external numbers).
2. Guards: if any order `state >= FINISHED`, rejects.
3. For each order with `state < PALLETIZED`: sets `state = PALLETIZED`, saves.
4. Transfers each order's parcel `Unitload` onto the pallet carrier via `unitloadBusinessService.transferUnitLoadToCarrier(parcel, pallet, CODE_PALLETISING, ...)`.
5. Guards: if parcel already appears in an existing BOL position (non-CANCELLED state), throws `BusinessException("Parcel=X loaded to truck more than once!")`.

Note: `palletise` alone does **not** create BOL positions or change BOL state.

#### `palletiseAndTruckLoad` — `ParcelMonitorViewService:165`

Does palletize **and** creates the full BOL position tree in one transaction. BOL state advances:

- `CREATED` or `OPEN` → `TRUCK_LOADING` (waterfall)
- Already `TRUCK_LOADING` → continues
- Any other state → `BusinessException`

After state transition, transfers the pallet to the gate location via `CODE_TRUCK_LOADING`, then builds the BOL position tree (pallet → parcels → stock) identically to the mobile path (§5 below).

---

### Step 3 — Mobile Truck Loading

**REST endpoints** (`TruckLoadingController`, base path `/v3/truckLoading`):

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `GET /v3/truckLoading/orderList` | GET | `48` | Pending orders for truck loading |
| `GET /v3/truckLoading/truckLoadingInfo/{bolName}` | GET | `62` | BOL manifest location summary |
| `POST /v3/truckLoading/loadOrder` | POST | `69` | Lookup BOL by name; returns gate/truck/courier info |
| `POST /v3/truckLoading/scanPallet` | POST | `91` | Validate pallet label format + state |
| `POST /v3/truckLoading/scanGate` | POST | `112` | **Main action** — loads pallet onto BOL, state → TRUCK_LOADING |

#### `loadOrder` — `MobileTruckLoadingService:67`

Looks up BOL by name (`truckLoadingMobileDTO.getSelectedBOLName()`), returns gate name, truck name, and courier from the BOL header. No state changes. **Note:** BOL state and order state validation are marked `// TODO` — not currently enforced.

#### `checkPallet` / `scanPallet` — `MobileTruckLoadingService:91`

1. Validates pallet label format against two system-property patterns (`SYSTEM_PROPERTY_STRING_PATTERN_OUTBOUND_PALLET_KEY` and `SYSTEM_PROPERTY_PRINTING_PATTERN_OUTBOUND_PALLET_LABEL_KEY`).
2. Checks that the pallet `Unitload` exists.
3. Checks existing BOL positions for this pallet — allows `CANCELLED`, `CREATED`, `OPEN`, `TRUCK_LOADING`, `TRANSFER`; **rejects** `CLOSED` with `BusinessException("billOfLadingPositionUnxepectedStateFound")`.
4. Returns manifest location summary for the pallet.

#### `scanGate` — `MobileTruckLoadingService:153`

This is the main truck-loading action. Full flow:

1. Validates pallet label, BOL name, gate location name (all must be non-null).
2. Resolves pallet `Unitload`, `Billoflading`, and gate `Location`.
3. Gate resolution:
   - If BOL has no gate set (`outboundlocationId == null`): sets the scanned gate on the BOL.
   - If BOL has a gate set and it differs from scanned gate: throws `BusinessException("scannedAndRequiredGateDiffer")`.
4. BOL state guard and transition:
   - `CREATED` → `TRUCK_LOADING` (waterfall; code notes "TODO should not be allowed")
   - `OPEN` → `TRUCK_LOADING`
   - `TRUCK_LOADING` → no change, continues
   - `TRANSFER`, `CLOSED`, `CANCELLED` → `BusinessException("billOfLadingUnxepectedStateFound")`
5. Saves BOL with new state.
6. Transfers pallet to gate location: `unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false, CODE_TRUCK_LOADING, bolNumber, null)`.
7. Calls `mobileTransferService.handleTruckOffLoading(palletName)` — handles any in-transit offloading.
8. Resolves the operator from `SecurityContextUtils.getUserName()`.
9. **Builds BOL position tree:**
   - Creates pallet `BillofladingPosition` (`state = TRUCK_LOADING`, `sourceId = pallet.id`).
   - For each parcel `Unitload` on the pallet (children of pallet):
     - Creates parcel `BillofladingPosition` (`carrierId = pallet pos id`, `sourceId = parcel.id`, `orderId = matching order.id`).
     - Resolves the `Customerorder` for this parcel via `customerorderRepository.getByParcelIdList(parcelIds)`.
     - Validates exactly one order per parcel.
     - For each `Stockunit` on the parcel:
       - Creates stock `BillofladingPosition` (`carrierId = parcel pos id`, `itemdataId`, `amount`).
       - Matches to `CustomerorderPosition` by `itemdataId`; sets `orderpositionId` if found (warns if no match — does not throw).
10. Returns updated `TruckLoadingMobileDto`.

**v1 vs v2 difference:** v1 does not set `Customerorder.state = LOADED_TO_TRUCK` in `scanGate` and does not fire any OMS callback at load time. v2 does both.

---

## 5. Position Management Sub-Workflow

The `BillofladingPosition` tree represents the physical load on the truck at three levels:

```
BillofladingPosition (pallet level)
  carrierId  = null
  sourceId   = Unitload.id (pallet)
  orderId    = null
  state      = TRUCK_LOADING

  └─ BillofladingPosition (parcel level)
       carrierId  = pallet position id
       sourceId   = Unitload.id (parcel)
       orderId    = Customerorder.id
       state      = TRUCK_LOADING

       └─ BillofladingPosition (stock level)
            carrierId       = parcel position id
            sourceId        = null (stock is identified by itemdataId)
            itemdataId      = Itemdata.id
            orderpositionId = CustomerorderPosition.id (if matched)
            amount          = qty shipped
            state           = TRUCK_LOADING
```

Position creation: `BillofladingPositionService.createEntity:27`

- Allocates `id` from sequence.
- Sets `billofladingId`, `number` (generated from BOL number + position count), `clientId`, `operatorId`.
- Sets `state = TRUCK_LOADING` (hardcoded).

Position removal (unload from truck): `BillofladingPositionService.removeBOLPositionIfExists:48`

- Accepts only `CREATED`, `OPEN`, `TRUCK_LOADING`, `CANCELLED` states — rejects `CLOSED` with `BusinessException("Parcel=X already shipped!")`.
- Deletes all stock-level child positions first, then the parcel position.

**Garbage positions** (all FK fields null) are cleaned up inside `closeBOL` Phase 1 via `billofladingPositionRepository.deleteGarbageByBillofladingId`.

---

## 6. Close BOL — `BillofladingService.closeBOL:263`

### 6.1 Concurrency Guards

```java
// DB-level pessimistic lock (crosses JVM replicas)
Billoflading billOfLading = billofladingRepository.findByIdForUpdate(bolId)
    .orElseThrow(() -> new BusinessException("BOL not found: " + bolId));

// In-memory set (JVM-local, prevents double-submit on same node)
if (!bolToClose.add(billOfLading.getId())) {
    throw new BusinessException("BOL is currently in process.");
}
```

Both guards are required. The `bolToClose` set is `ConcurrentHashMap.newKeySet()` — it is cleared only on JVM restart. If a close crashes after `add()` but before `bolToClose.remove()`, the BOL will be permanently stuck in the set on that JVM (see §9 Failure Modes).

### 6.2 State Validation

| Current BOL state | Outcome |
|---|---|
| `CREATED` | waterfall — proceeds |
| `OPEN` | waterfall — proceeds |
| `TRUCK_LOADING` | proceeds |
| `TRANSFER` | `BusinessException("Can not close BOL. BOL is in transfer!")` |
| `CLOSED` | `BusinessException("Can not close BOL. BOL already closed!")` |
| `CANCELLED` | `BusinessException("Can not close BOL. BOL already closed!")` |
| unknown | `RuntimeException("unknown state=...")` |

Type validation — only these types are allowed:

| BOL type | Allowed |
|---|---|
| `REGULAR` | yes |
| `TRANSFER_OFFSITE` | yes |
| `TRANSFER_INTRACOMPANY` | yes |
| `HUB_AND_SPOKE` | yes |
| `CLUB` | **no** — `BusinessException` |
| `PICK_PACK` | **no** — `BusinessException` |

Target state and entity lock depend on type:

| BOL type | BOL target state | Entity lock | Activity code |
|---|---|---|---|
| All except TRANSFER_INTRACOMPANY | `CLOSED` | `SHIPPED` (405) | `CODE_SHIPPING` |
| `TRANSFER_INTRACOMPANY` | `TRANSFER` | `TRANSFER` (404) | `CODE_TRANSFER_TRANSFER_IN_SHIPPING` |

### 6.3 Nine-Phase Close Sequence

**Phase 1 — Load positions + build in-memory tree** (`closeBOL:326–356`)

- Loads all `BillofladingPosition` rows for the BOL in one query.
- Classifies into pallet positions (top-level: `carrierId == null` or carrier not in this BOL) and children by carrierId.
- Skips "garbage" positions (all FK fields null) — then bulk-deletes them via `deleteGarbageByBillofladingId`.

**Phase 2 — Bulk pre-load referenced entities** (`closeBOL:358–419`)

- Collects all FK IDs (sourceIds, orderIds, orderPositionIds) from positions.
- Bulk-loads: `Unitload`, `Customerorder`, `CustomerorderPosition`, `CustomerorderBatch`, `Client`, `Shipperid`, `Itemdata`.
- Parcel unitloads (from `Customerorder.parcelId`) that weren't in the source set are fetched separately.

**Phase 3 — Build DTOs** (`closeBOL:421–499`)

- Iterates pallet positions, then their parcel children, then stock children — all from in-memory maps (zero extra queries).
- Builds `PalletDto` → `OrderDto` → `OrderPositionDto` tree for the OMS payload.
- Handles transfer types differently: for transfer BOLs, `parcelExternalNumber` is taken from the BOL position's `sourceId` unitload, and `clientId` from the client number.

**Phase 4 — Bulk transfer pallets to SHIPPED** (`closeBOL:501–505`)

```java
unitloadBusinessService.transferPalletTreesToLocation(
    palletUnitloads, shippedLocation, true, activityCode, bol.getNumber(), null);
```

Moves all pallet unitloads (and their children via `transferPalletTreesToLocation`) to the `Shipped` location. Activity code is `CODE_SHIPPING` or `CODE_TRANSFER_TRANSFER_IN_SHIPPING`.

**Phase 5 — Bulk state updates** (`closeBOL:507–519`)

```java
// All BOL positions in one UPDATE
billofladingPositionRepository.updateStateByBillofladingId(bolState, bol.getId());

// All customer orders in chunks of 500
customerorderRepository.updateStateByIds(WmsConstants.State.FINISHED, orderIds);

// All customer order positions in chunks of 500
customerorderPositionRepository.updateStateByOrderIds(WmsConstants.State.FINISHED, orderIds);
```

Uses `chunked()` helper (`closeBOL:637`) to keep `IN` clause sizes ≤ 500 rows.

**Phase 6 — Bulk entity lock updates** (`closeBOL:521–548`)

- Collects pallet IDs → fetches their child unitload IDs.
- Bulk-updates `entityLock` on all unitloads (pallets + parcels) to `SHIPPED` or `TRANSFER`.
- Bulk-updates `entityLock` on all stockunits under the child unitloads.

**Phase 7 — Save BOL state + flush** (`closeBOL:550–559`)

```java
billOfLading.setState(bolState);
billOfLading.setShipped(new Date());
billofladingRepository.save(billOfLading);
entityManager.flush();
entityManager.clear();
```

Explicit flush + clear required to push all bulk native UPDATEs through before post-commit logic.

**Phase 8 — Build OMS payload + publish event** (`closeBOL:561–615`)

- Constructs `BillOfLadingWebServiceDto` with pallet tree, BOL metadata, warehouse IDs.
- Calls `eventPublisher.publishEvent(new BolClosedEvent(dto, wmsInstanceName, omsInstanceName))`.
- `BolClosedEventListener.handleBolClosed` (`event/BolClosedEventListener.java:34`) handles the event with `@TransactionalEventListener(phase = AFTER_COMMIT)` — the HTTP POST to `WEBSERVICE_ORDER_BATCH_SHIPPED` fires only after the transaction commits.
- On success: persists `Message` row with `status = SENT` via `MessageService.createMessageInNewTransaction` (`REQUIRES_NEW`).
- On failure: caught by the listener — persists `Message` row with `status = FAILED` in a `REQUIRES_NEW` transaction. The close **does not roll back** if the OMS call fails. Failure is **no longer a silent drop** — it is always recorded in the `message` table.

**Phase 9 — Finalize batches** (`closeBOL:617–624`)

```java
customerorderBatchRepository.finalizeBatchesByIds(ids, WmsConstants.State.FINISHED);
```

Bulk-finalizes all `CustomerorderBatch` records whose orders are all `FINISHED`. Uses `chunked()` with size 500.

### 6.4 Batch Close

`POST /v3/billOfLading/closeOutboundBols` (`BillOfLadingController:233`) accepts a JSON list of BOL IDs and calls `closeBOLs:257` which iterates and calls `closeBOL` for each — sequential, not parallel.

---

## 7. Transfer (TRANSFER_INTRACOMPANY) Sub-Workflow

BOLs of type `TRANSFER_INTRACOMPANY` go through a two-step close:

**Step 1 — `closeBOL`** (same flow as §6, but target state = `TRANSFER`, entity lock = `TRANSFER`):

- BOL state: `TRUCK_LOADING → TRANSFER`
- BOL positions: → `TRANSFER` (bulk)
- Unitloads → `Shipped` location, `entityLock = TRANSFER`
- Stockunits → `entityLock = TRANSFER`
- OMS notified via `ORDER_BATCH_SHIPPED` post-commit

**Step 2 — `finishTransfer`** (called by receiving warehouse):

**REST:** `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}` (`BillOfLadingController:291`)
**Service:** `BillofladingService.finishTransfer:1119`

1. Looks up BOL by `transferId` (not by ID).
2. Validates `type == TRANSFER_INTRACOMPANY`.
3. Sets `Billoflading.state = CLOSED`.
4. Iterates pallet positions (those with no `carrierId`):
   - Sets all positions (pallet, parcel, stock) to `CLOSED` individually (row-by-row, unlike closeBOL's bulk path).
   - Transfers pallet unitload to `Shipped` location via `CODE_SHIPPING`.
   - Sets `entityLock = SHIPPED` on pallet, then each parcel, then each stockunit on each parcel.

**Note:** `finishTransfer` does NOT use the bulk-update path — it uses individual `save()` calls for each position. On large BOLs this can be significantly slower than `closeBOL`.

---

## 8. OMS Callbacks

v1 has only one BOL-related OMS callback (unlike v2 which has three):

| Callback | Fired from | Sysprop key | Default URL |
|---|---|---|---|
| `ORDER_BATCH_SHIPPED` | `BillofladingService.closeBOL` Phase 8 (post-commit) | `WEBSERVICE_ORDER_BATCH_SHIPPED` | `https://oms-XXXXX.siteboss.net/services/call/finishedShipping` |

The callback is fired via Spring `ApplicationEventPublisher` + `BolClosedEventListener` (`@TransactionalEventListener(phase = AFTER_COMMIT)`) — fires only after the transaction commits. Rollback drops the event. Audit is persisted in the `message` table via `MessageService.createMessageInNewTransaction` (`REQUIRES_NEW` — survives outer transaction rollback). Unlike the `OmsNotificationHelper.deferToCommit` pattern used elsewhere, failure in the listener is caught and persisted with `status = FAILED` rather than silently dropped.

**v1 does not have:**
- `WEBSERVICE_ORDER_BATCH_PALLETIZED`
- `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK`

These exist in v2 only.

---

## 9. REST Endpoint Reference

### Desktop (`BillOfLadingController`, base path `/v3/billOfLading`)

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `POST /v3/billOfLading/create` | POST | `65` | Create BOL (state = OPEN) |
| `GET /v3/billOfLading/nameExists/{name}` | GET | `105` | Name uniqueness check |
| `POST /v3/billOfLading/setTrackingDeviceID` | POST | `116` | Set tracking device ID (rejects TRANSFER/CLOSED/CANCELLED) |
| `POST /v3/billOfLading/setDestinationFacility` | POST | `177` | Set destination facility code |
| `GET /v3/billOfLading/closeOutboundBol/{id}` | GET | `205` | Single BOL close → `closeBOL` |
| `POST /v3/billOfLading/closeOutboundBols` | POST | `233` | Batch close (sequential) |
| `POST /v3/billOfLading/exportOutboundBol` | POST | `265` | Export BOL as Excel (open, closed, or in-progress) |
| `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}` | GET | `291` | Finish intracompany transfer → `finishTransfer` |
| `POST /v3/billOfLading/palletize` | POST | `316` | Palletize orders → `ParcelMonitorViewService.palletise` |
| `GET /v3/billOfLading/openBol` | GET | `355` | List open BOLs |
| `GET /v3/billOfLading/closedBol` | GET | `380` | List closed BOLs |
| `GET /v3/billOfLading/bolDetailsById/{id}` | GET | `404` | BOL details (includes parcel count + manifest locations) |
| `GET /v3/billOfLading/getDestinations` | GET | `410` | Fetch destination facilities from OMS |

### Mobile (`TruckLoadingController`, base path `/v3/truckLoading`)

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `GET /v3/truckLoading/orderList` | GET | `48` | Pending orders for truck loading |
| `GET /v3/truckLoading/truckLoadingInfo/{bolName}` | GET | `62` | BOL manifest location summary |
| `POST /v3/truckLoading/loadOrder` | POST | `69` | Lookup BOL by name |
| `POST /v3/truckLoading/scanPallet` | POST | `91` | Validate pallet label + check state |
| `POST /v3/truckLoading/scanGate` | POST | `112` | **Main** — load pallet, BOL state → TRUCK_LOADING |

---

## 10. Key Entities — Field Reference

### `Billoflading`

| Field | Type | Notes |
|---|---|---|
| `id` | `Long` | Sequence-allocated |
| `number` | `String` | Generated, prefix `OBOL` |
| `name` | `String` | Human-readable BOL name (used by mobile to look up BOL) |
| `state` | `String` | `BillOfLadingState.*` |
| `type` | `String` | `OrderBatchType.*` |
| `clientId` | `Long` | FK to `Client` (system client) |
| `operatorId` | `Long` | FK to `MywmsUser` (creating operator) |
| `outboundlocationId` | `Long` | FK to gate `Location` |
| `courier` | `String` | Carrier name |
| `truck` | `String` | Truck number |
| `sealnumber` | `String` | Seal number |
| `destination` | `String` | Destination facility code |
| `transferId` | `String` | Transfer ID (for intracompany transfers; used by `finishTransfer`) |
| `sharedUniqueBolId` | `String` | UUID; cross-system reference |
| `trackingDeviceId` | `String` | IoT tracking device (blocked on TRANSFER/CLOSED/CANCELLED) |
| `shipped` | `Date` | Set at close time |
| `version` | `Integer` | Optimistic lock |

### `BillofladingPosition`

| Field | Type | Notes |
|---|---|---|
| `id` | `Long` | Sequence-allocated |
| `billofladingId` | `Long` | Parent BOL FK |
| `carrierId` | `Long` | Parent position FK (null = pallet/top-level) |
| `sourceId` | `Long` | Unitload FK (pallet or parcel) |
| `orderId` | `Long` | Customerorder FK (parcel-level only) |
| `orderpositionId` | `Long` | CustomerorderPosition FK (stock-level only) |
| `itemdataId` | `Long` | Itemdata FK (stock-level only) |
| `amount` | `Integer` | Qty (stock-level only) |
| `operatorId` | `Long` | Operator who performed the loading |
| `state` | `String` | Mirrors BOL state (`TRUCK_LOADING` at creation) |

---

## 11. Common Failure Modes and Stuck States

### BOL stuck in `TRUCK_LOADING`, close rejected

Possible causes:
1. **`bolToClose` set poisoned (JVM crash during close)**: If the JVM crashed between `bolToClose.add()` and `bolToClose.remove()` in the `finally` block, the next close attempt on the same JVM returns "BOL is currently in process." Fix: restart the JVM (this clears the in-memory set). Do not attempt to manually clear via SQL — the DB lock is separate.
2. **DB lock held by a stuck transaction**: Another transaction holds the pessimistic lock from `findByIdForUpdate`. Check `pg_stat_activity` for long-running transactions on the BOL row. Kill the blocking connection if appropriate.
3. **Type is `CLUB` or `PICK_PACK`**: These types are rejected at close with `BusinessException("Only regular, hub and spoke, and transfer types are allowed")`. The BOL type must be corrected via a DB patch.

### BOL stuck in `TRANSFER`

The BOL was closed as `TRANSFER_INTRACOMPANY` (Phase 1 succeeded, state = `TRANSFER`), but the receiving warehouse never called `finishTransfer`. Resolution: invoke `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}` on the receiving warehouse's WMS. Do **not** manually update state in the DB — the entity locks on unitloads/stockunits must also be cleared by `finishTransfer`.

### Position errors — "Parcel loaded to truck more than once"

Thrown by `BillofladingPositionService.removeBOLPositionIfExists:49` when `billOfLadingPositions.size() > 1`. This means the parcel appears in more than one BOL position. Diagnosis: query `billoflading_position` filtering by `source_id = <parcel unitload id>` to find the duplicates. If one is in a non-`CLOSED` BOL, it may be deletable. Never delete positions from a CLOSED BOL directly — the shipment data is audit-critical.

### Position errors — "BOL position has stock with no customer order"

Thrown during Phase 3 of `closeBOL` at line 484: `"BOL position=" + stockPos.getNumber() + " has stock with no customer order"`. A stock-level `BillofladingPosition` has a non-null `orderpositionId` pointing to a `CustomerorderPosition` that no longer exists (or was cancelled). Diagnosis:

1. Find the position: `SELECT * FROM billoflading_position WHERE id = <stockPos.id>`.
2. Check `order_position_id` — if that `customerorder_position` is cancelled or deleted, the position is orphaned.
3. The garbage-position cleanup in Phase 1 only removes positions with **all** FK fields null. This is a different case.
4. Fix: either delete the orphaned BOL position (if the order was legitimately cancelled and no stock shipped) or restore the order position.

### Pallet not found during `closeBOL` (Phase 3)

Thrown at line 430: `"Pallet unitload not found for BOL position: " + palletPos.getId()`. The pallet-level `BillofladingPosition.sourceId` points to a `Unitload` that no longer exists. This can happen if the unitload was deleted (e.g., "sent to nirvana") after truck loading. Fix requires investigation of unitload history in `unitload_record` and potentially re-linking or deleting the orphaned BOL position.

### OMS callback failed (`ORDER_BATCH_SHIPPED`)

The BOL is already `CLOSED` in WMS (state was saved in Phase 7 and committed), but OMS did not receive the callback. Check the `message` table:

```sql
SELECT * FROM message 
WHERE process_type = 'ORDER_BATCH_SHIPPED' 
  AND status = 'FAILED'
ORDER BY created DESC;
```

The `message.payload` column contains the full JSON that was to be sent. Re-delivery: POST the payload manually to the OMS `finishedShipping` endpoint, or invoke via the WMS message retry mechanism if one exists. The WMS BOL state is correct — do not re-close.

### "Can not change tracking device ID. BOL already closed!"

Thrown by `BillofladingService.setTrackingDeviceID:247` when state is `TRANSFER`, `CLOSED`, or `CANCELLED`. The tracking device ID is immutable once the BOL enters a terminal state. If the value is wrong and the BOL is already closed, it must be corrected via a DB update (not exposed through the API).

### Mobile `scanGate` — wrong gate, no error

`MobileTruckLoadingService.scanGate:187–195`: if the BOL has no gate set yet, the first scanned gate is accepted without validation. There is a `// TODO check that gate is a correct location` at line 189. An operator can set an invalid gate at this step. Symptom: pallet is transferred to wrong location. Diagnosis: check `unitload_record` for the pallet to find what location it was moved to.

### `finishTransfer` slow on large BOLs

`finishTransfer:1129` uses individual `save()` calls per position (not bulk JPQL). On BOLs with hundreds of positions this can produce N×3 queries. If the endpoint times out, the BOL state may be partially updated. Fix: re-invoke `finishTransfer` — it is idempotent for already-`CLOSED` positions (though it will re-save them). Consider monitoring execution time and breaking into smaller BOLs for intracompany transfers.

---

## 12. Transaction Boundaries

All BOL-mutating methods on `BillofladingService` are covered by the class-level `@Transactional` annotation (`BillofladingService:29`). There is no method-level override — every public method participates in the caller's transaction or starts a new one.

Key points:

- `closeBOL` and `finishTransfer`: one atomic unit. Partial close is not possible from the outside — either all phases commit or none do.
- `messageService.createMessageInNewTransaction`: uses `Propagation.REQUIRES_NEW` so the `Message` audit row persists even if the outer transaction rolls back (e.g., if the OMS POST throws after commit).
- `BolClosedEvent` / `BolClosedEventListener`: Phase 8 uses Spring `ApplicationEventPublisher.publishEvent` instead of `OmsNotificationHelper.deferToCommit`. The listener's `@TransactionalEventListener(AFTER_COMMIT)` fires outside the transaction — a failure there does not roll back the BOL close, and is caught + recorded as a `FAILED` message row.
- `bolToClose.remove(bolId)` is in a `finally` block: always executes, even if `closeBOL` throws.

---

## 13. v1 vs v2 Differences (BOL/Truck Loading)

| Aspect | v1 | v2 |
|---|---|---|
| `Customerorder` state at scan gate | Not changed (stays `PALLETIZED`) | Advanced to `LOADED_TO_TRUCK` |
| OMS callbacks at truck load | None | `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` (post-commit) |
| OMS callbacks at palletize | None | `WEBSERVICE_ORDER_BATCH_PALLETIZED` (post-commit) |
| OMS callbacks at close | `ORDER_BATCH_SHIPPED` (post-commit) | Same |
| `finishTransfer` position update | Row-by-row `save()` | Bulk JPQL (v2 improved) |
| Palletize service | `ParcelMonitorViewService` | `ParcelMonitorViewService` (same name, updated) |
| Mobile service | `MobileTruckLoadingService` | `MobileTruckLoadingService` (same name, updated) |
| Dashboard tracking | Not present | Order-loaded-to-truck dashboard via `ORDER_LOADED_TO_TRUCK` state |

---

## 14. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | `BillofladingService` (createEntity, closeBOL phases 1–9, finishTransfer, transferOrder, setTrackingDeviceID, exportOutboundBOL); `BillofladingPositionService` (createEntity, removeBOLPositionIfExists); `MobileTruckLoadingService` (loadOrder, checkPallet, scanGate, truckLoadingMobileDTOByBolName); `ParcelMonitorViewService` (palletise, palletiseAndTruckLoad line refs); `BillOfLadingController` all endpoints; `TruckLoadingController` all endpoints; `WmsConstants.BillOfLadingState`, `OrderBatchType`, `BusinessObjectLockState`; `Billoflading` + `BillofladingPosition` entity fields | All file:line refs confirmed against `v1/wms-api/src/main/java` | Code read |

**Re-verify every 90 days.** Next due: **2026-07-25** — `BillofladingService` is the hottest file in the codebase and receives frequent changes.
