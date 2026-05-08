---
title: WMS v1 Club Order Processing
type: workflow
project: wms1
status: stable
created: 2026-04-26
last_verified: 2026-05-01
tags: [wms1, workflow, club-order]
---

# Club Order Processing — End-to-End Analysis

## Overview

Club orders are a specialized batch order type in WMS where multiple customers receive **identical SKU sets in identical quantities**. This enables a streamlined "club line" fulfillment process: stock is staged in a lane, then divided across all parcels in the batch simultaneously — bypassing the standard pick-pack-ship workflow used for regular (PICK_PACK) orders.

This document traces a club order from OMS submission through WMS processing to final shipment.

---

## Table of Contents

1. [Phase 1: Order Submission (OMS → WMS)](#phase-1-order-submission-oms--wms)
2. [Phase 2: Order Ingestion & Validation (WMS REST API)](#phase-2-order-ingestion--validation-wms-rest-api)
3. [Phase 3: Staging Lane Assignment (Web UI)](#phase-3-staging-lane-assignment-web-ui)
4. [Phase 4: Batch Activation (Web UI)](#phase-4-batch-activation-web-ui)
5. [Phase 5: Club Line Run (Core Processing)](#phase-5-club-line-run-core-processing)
6. [Phase 6: BOL Assignment & Truck Loading](#phase-6-bol-assignment--truck-loading)
7. [Phase 7: BOL Close & OMS Notification](#phase-7-bol-close--oms-notification)
8. [State Machine Summary](#state-machine-summary)
9. [Label Generation Analysis](#label-generation-analysis)
10. [Key Differences: Club vs Regular Orders](#key-differences-club-vs-regular-orders)
11. [Key Files Reference](#key-files-reference)

---

## Phase 1: Order Submission (OMS → WMS)

### OMS Side

**Source files (OMS):**
- `oms/htdocs/module/OMS/src/OMS/Controller/OrdersController.php` (lines 4580–5100)
- `oms/htdocs/module/CMF/src/CMF/Controller/Plugin/ProcessOrdersPlugin.php`
- `oms/htdocs/module/OMS/src/OMS/Model/Omsordertypelut.php`

**Flow:**
1. Orders arrive into OMS with `orderType: "Club"` (defined in `API_processOrders.yaml`, line 59).
2. `ProcessOrdersPlugin` (line 93–97) retrieves order type lookup rows and maps them to order data.
3. `OrdersController` (line 3671–3673) detects club orders by checking if any parcel item has `packing_line = "Club"` and sets an `is_club` flag.
4. `OrdersController` (line 4966–4967) assigns `batch_type = 'CLUB'` on the outbound API payload.

**WMS URL Resolution:**
- OMS queries the `wms_url_lut` table (`Wmsurllut` model) to map `facility_code` → WMS base URL.
- Example: `facility_code = "NEW_YORK"` → `https://wms.example.com:8088`.

**HTTP Call:**
- **Method:** HTTP PUT
- **Endpoint:** `{wms_url}/{ORDER_CREATE_PATH}` (configured in OMS config)
- **Content-Type:** `application/json`

### Payload Structure

```json
[
  {
    "batch_id": "CLUB-BATCH-001",
    "batch_name": "February Club Shipment",
    "batch_instructions": "Handle with care",
    "priority": 2,
    "client_id": "WINERY_A",
    "facility_code": "WAREHOUSE_1",
    "criteria": "like_for_like_value",
    "batch_type": "CLUB",
    "transfer_id": "",
    "positions": [
      {
        "parcel_id": 54321,
        "unique_id": 54321,
        "client_id": "WINERY_A",
        "weight": 25,
        "brand": "BRAND_CODE",
        "brand_name": "Brand Name",
        "box_sku": "750ML-12PK",
        "client_order_number": "ORD-99999",
        "parcel_external_number": "EXT-TRACK-001",
        "picking_date": "2026-02-14",
        "manifest_location": "DESTINATION_A",
        "recipient": "John Doe",
        "positions": [
          {
            "unique_id": "54321-0",
            "number": 0,
            "sku_id": "WINE-CAB-2022",
            "client_id": "SUPPLIER_CODE",
            "amount": 6
          },
          {
            "unique_id": "54321-1",
            "number": 1,
            "sku_id": "WINE-MERLOT-2021",
            "client_id": "SUPPLIER_CODE",
            "amount": 6
          }
        ],
        "number_of_items": 12,
        "shippers_id": "UPS",
        "fulfillment_type": "Standard",
        "special_instructions": ""
      }
    ]
  }
]
```

**Key constraint:** Every `position` (parcel/customer) in a CLUB batch must contain the **exact same SKUs in the exact same quantities**. This is enforced by WMS on ingestion (see Phase 2).

---

## Phase 2: Order Ingestion & Validation (WMS REST API)

**Source:** `OrderRestController.create()` — `controller/rest/OrderRestController.java` (lines 250–350)

### Step-by-step

1. **Facility validation** — `AbstractRestController` validates the `facility_code` matches this WMS instance.

2. **Basic field validation** — For each `OrderBatchDto`:
   - `batch_id` must be set and unique (not already in DB).
   - `positions` list must be non-empty.
   - Each position must have `unique_id`, `client_id`, and at least one SKU position.

3. **Club-specific SKU validation** (lines 271–306) — When `batch_type = "CLUB"`:
   - The first order becomes the "club representant" (reference order).
   - Every subsequent order is compared against the representant:
     - **SKU match:** Every SKU in the representant must exist in the candidate order, and vice versa.
     - **Amount match:** For each matching SKU, the amounts must be identical.
   - Violations throw:
     - `CLUB_LINE_ERROR_POSITION_SKU_DIFFER` (code 301) — SKU mismatch between orders.
     - `CLUB_LINE_ERROR_POSITION_AMOUNT_DIFFER` (code 300) — Amount mismatch for same SKU.

4. **Entity creation** (lines 317–350):
   - `CustomerorderBatch` created with `type = "CLUB"`, `state = RAW (0)`, priority mapped (1–5).
   - For each parcel/position in the batch:
     - `Customerorder` created with `state = RAW`, linked to batch via `orderbatchId`.
     - For each line item:
       - `CustomerorderPosition` created with `state = RAW`, linked to order via `orderId`.

5. **Response:** Returns success/failure JSON.

---

## Phase 3: Staging Lane Assignment (Web UI)

**Source:** `ClubLineController` — `controller/ClubLineController.java`
**Source:** `CustomerorderBatchService` — `service/CustomerorderBatchService.java` (lines 506–530)

### Flow

1. **View open club runs** — `GET /v3/clubLine/openClubRun` returns all club batches with state from RAW to PALLETIZED.

2. **View available staging lanes** — `GET /v3/clubLine/availableStagingLanes` queries locations not already assigned to an active club batch (state < `ORDER_BATCH_CLUB_RUN_FINISHED`).

3. **Assign staging lane** — `POST /v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}`:
   - Validates the lane is available (not already assigned to another active batch).
   - **Guard (SBDEV-2163):** if all orders in the batch are `FINISHED` or `CANCELED`, throws `BusinessException("Club batch is finished or cancelled — cannot assign a staging lane.")`. Prevents a finished batch from receiving a new staging lane assignment.
   - Sets `orderBatch.staginglaneId = location.getId()`.
   - Sets `orderBatch.state = ORDER_BATCH_STAGING_LANE_ASSIGNED (525)`.

4. **Unlink staging lane** (if needed) — `POST /v3/clubLine/unlinkStagingLane/{orderBatchId}`:
   - Clears the staging lane assignment.
   - Resets state back to `RAW (0)`.

**Physical operation:** Warehouse staff physically moves the required stock (unit loads with the needed SKUs) to the assigned staging lane location before activation.

---

## Phase 4: Batch Activation (Web UI)

**Source:** `CustomerorderBatchService.activateOrderBatch()` — `service/CustomerorderBatchService.java` (line 299)

### Flow

1. **Activate batch** — `POST /v3/clubLine/activateBatch/{orderBatchId}/{locationId}`:
   - Sets `orderBatch.state = ORDER_BATCH_ACTIVATED (520)`.
   - At this point the operator can review:
     - **SKU overview** — `GET /v3/clubLine/skus` returns `ClubLineSkuDto` list showing each SKU, required amount, and available amount on the staging lane.
     - **Unit loads** — `GET /v3/clubLine/unitLoads` returns `ClubLineUnitLoadDto` list showing all stock on the staging lane, with item details and whether each unit load is printable.

---

## Phase 5: Club Line Run (Core Processing)

**Source:** `CustomerorderBatchService.runClubLine()` — `service/CustomerorderBatchService.java` (lines 403–497)

This is the heart of club order processing. It replaces the entire standard pick-pack workflow with a single batch operation.

### Step-by-step

1. **Stock sufficiency check** (line 416):
   - Calls `isEnoughStockOnStagingLane(orderBatch)`.
   - Throws `BusinessException("Not enough stock on location.")` if insufficient.

2. **Build item-to-stock map** (lines 420–422):
   - Fetches all unit loads at the staging lane location.
   - Maps each `Itemdata` → list of `Stockunit` objects.

3. **Create parcels and transfer stock** (lines 427–473):
   - For each `Customerorder` in the batch:
     - Creates a **package unit load** (parcel) via `unitloadService.createUnitload()`:
       - Label ID = `order.parcelExternalNumber`
       - Location = `PACKAGING` location
       - Type = `UNIT_LOAD_TYPE_PACKAGE`
       - Code = `CODE_PACKAGING_CLUB`
     - Sets `order.parcelId = packageUnitLoad.getId()`.
     - For each `CustomerorderPosition`:
       - Looks up the `Itemdata` and finds matching stock units from the staging lane map.
       - Transfers the required amount from staging stock to the parcel via `stockunitBusinessService.transferStockToUnitLoad()`:
         - If stock unit has **exact amount** needed → transfer all, remove from pool.
         - If stock unit has **more than needed** → transfer partial, keep remainder.
         - If stock unit has **less than needed** → transfer all available, subtract from required, continue to next stock unit.

4. **Send OMS state messages** (lines 477–479):
   - `manageOrderService.customerOrderReleaseForPicking(orders)` — Notifies OMS orders are released.
   - `manageOrderService.customerOrderPickingStarted(orders)` — Notifies OMS picking started.
   - `manageOrderService.customerOrderPicked(orders)` — Notifies OMS picking finished.
   - These three calls are made in rapid succession because the club line run handles all three phases atomically.

5. **Update order states** (lines 482–496):
   - Each `Customerorder` → state = `PACKED (650)`.
   - Each `CustomerorderPosition` → state = `PACKED (650)`.
   - `CustomerorderBatch` → state = `ORDER_BATCH_CLUB_RUN_FINISHED (530)`.

6. **QA bypass** — `OrderRestController.finishedQA()` (lines 784–786):
   - When OMS sends a "finished QA" message for a CLUB batch, WMS **discards it** with a log warning.
   - Club orders do not go through the standard QA/packaging flow since `runClubLine` already handled packaging.

---

## Phase 6: BOL Assignment & Truck Loading

**Source:** `BillOfLadingController` — `controller/BillOfLadingController.java`
**Source:** `BillofladingService` — `service/BillofladingService.java`
**Source:** `MobileTruckLoadingService` — `service/mobile/MobileTruckLoadingService.java`

### Flow

1. **Create BOL** — `POST /v3/billOfLading/create`:
   - Creates a `Billoflading` entity with truck number, courier, seal number, tracking device ID, and type.
   - BOL type can be: REGULAR, CLUB, TRANSFER_OFFSITE, TRANSFER_INTRACOMPANY, HUB_AND_SPOKE.
   - State starts as `OPEN`.

2. **Truck loading (mobile)** — Warehouse staff uses mobile app:
   - `MobileTruckLoadingService.loadOrder()` — Selects BOL and gets truck details.
   - `MobileTruckLoadingService.checkPallet()` — Scans pallet barcode, validates it, shows manifest locations for the orders on that pallet.
   - Creates `BillofladingPosition` hierarchy:
     - **Level 1 (Pallet):** `carrierId = null`, `sourceId = Unitload(pallet)`
     - **Level 2 (Parcel):** `carrierId = pallet_position_id`, `sourceId = Unitload(parcel)`, `orderId = Customerorder.id`
     - **Level 3 (Stock Unit):** `carrierId = parcel_position_id`, `itemdataId`, `orderpositionId`
   - Club orders are grouped by `manifestLocation` on each `Customerorder`.

---

## Phase 7: BOL Close & OMS Notification

**Source:** `BillofladingService.closeBOL()` — `service/BillofladingService.java` (lines 249–508)

### Flow

1. **State validation** — Only accepts BOLs in CREATED, OPEN, or TRUCK_LOADING state.

2. **Traverse position hierarchy:**
   - Iterates pallet positions (Level 1, `carrierId = null`).
   - For each pallet, iterates parcel positions (Level 2).
   - For each parcel, iterates stock unit positions (Level 3).

3. **Finalize orders:**
   - Each `Customerorder` → state = `FINISHED (700)`.
   - Each `CustomerorderPosition` → state = `FINISHED (700)`.
   - Collects batch references to check batch completion.

4. **Transfer pallets:**
   - Moves pallet unit loads to the "SHIPPED" location via `unitloadBusinessService.transferUnitLoadToLocation()`.
   - Sets entity lock state to `SHIPPED (100)`.

5. **Send OMS shipping notification:**
   - Constructs `BillOfLadingWebServiceDto` with:
     - BOL ID, type, truck number, courier, destination, seal number, tracking device ID.
     - Full position hierarchy (pallets → parcels → stock units with SKU details).
     - Manifest locations for each order.
   - Sends HTTP POST to OMS via `ManageOrderService` using URL from system property `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY`.
   - Message type: `ORDER_BATCH_SHIPPED`.

6. **Finalize batch:**
   - If all orders in the batch are now FINISHED, sets `CustomerorderBatch.state = FINISHED (700)`.
   - Sets BOL state to `CLOSED`.

---

## State Machine Summary

### CustomerorderBatch (Club)

```
RAW (0)
  → ORDER_BATCH_STAGING_LANE_ASSIGNED (525)   [staging lane assigned]
    → ORDER_BATCH_ACTIVATED (520)              [batch activated, ready for run]
      → ORDER_BATCH_CLUB_RUN_FINISHED (530)    [club line run completed]
        → FINISHED (700)                        [BOL closed, all orders shipped]
```

### Customerorder (within Club Batch)

```
RAW (0)
  → PACKED (650)     [set by runClubLine - stock transferred to parcel]
    → FINISHED (700)  [set by closeBOL - shipped]
```

Note: Club orders **skip** the standard states ASSIGNED (200), PROCESSABLE (300), STARTED (500), and PICKED (600). The `runClubLine` method sends OMS messages for release/start/pick but jumps the order directly to PACKED.

### CustomerorderPosition (within Club Order)

```
RAW (0)
  → PACKED (650)     [set by runClubLine]
    → FINISHED (700)  [set by closeBOL]
```

### Billoflading

```
OPEN → TRUCK_LOADING → CLOSED
```

---

## Label Generation Analysis

### Summary

**WMS generates labels on-demand, not in advance.** There is no pre-printing or batch label generation scheduled ahead of time. Labels are generated at the moment a user triggers a print action from the Web UI or mobile app.

### Label Types in WMS

| Label Type | Generated By | Trigger | Template Source |
|---|---|---|---|
| **Case Label (Inbound)** | `ReceivingService.createCaseLabel()` | Receiving a unit load | ZPL template from `LosSysprop.PRINTING_ZPL_CASE_LABEL` |
| **Tote Label (Picking)** | `OrderMonitorViewService.generateToteLabel()` | User prints from order monitor | ZPL template from `LosSysprop.PRINTING_ZPL_PICKING_TOTE_LABEL` |
| **Pallet Label (Outbound)** | `ParcelMonitorViewService.palletise()` | Palletization action | ZPL template from `LosSysprop.PRINTING_ZPL_OUTBOUND_PALLET_LABEL` |
| **Stock Unit Label** | `StockunitService.createCaseLabel()` | Stock transfer/damage lock | ZPL template from `LosSysprop.PRINTING_ZPL_CASE_LABEL` |

### Printing Architecture

- **Format:** ZPL (Zebra Programming Language) — raw bytecode sent to label printers.
- **Print Server:** CUPS (Common Unix Printing System) via `cups4j` library.
- **Connection:** HTTP to CUPS server at configurable IP:port with authentication.
- **Templates:** Stored in the `LosSysprop` database table as system properties — not hardcoded. Templates contain placeholders (e.g., `{warehouse}`, `{SKU}`, `{recipient}`) that are substituted at generation time.
- **Barcodes:** Embedded in the ZPL template itself (barcode encoding instructions are part of ZPL), not generated by application code.

### Club Order Label Specifics

Club orders do **not** have a dedicated label type. The relevant labels are:

1. **Tote labels** — Can be printed for club orders via the standard tote label endpoint (`POST /v3/dashboard/printToteLabels`), though club orders typically bypass the tote-based picking flow.
2. **Pallet labels** — Generated during palletization for outbound shipping, applicable to club parcels once palletized.
3. **Reprint** — Available via `POST /v3/unitload/reprintLabel` and `POST /v3/report/reprintLabels` for any previously labeled unit load.

### OMS Label Generation

OMS has its own club label handling separate from WMS:
- `Omsclubprocessing` model manages club label printers (filtered by `output_type = 1`).
- OMS can regenerate club batch labels via its `BatchlabelController.labelgeneration` endpoint.
- These are **shipping/compliance labels managed by OMS**, not warehouse operational labels.

### Conclusion on Labels

| Question | Answer |
|---|---|
| Does WMS generate labels in advance? | **No.** All labels are on-demand. |
| Does WMS generate labels on demand? | **Yes.** Via ZPL templates + CUPS printing triggered by user actions. |
| Does an external application generate labels? | **Partially.** OMS generates its own club shipping/compliance labels independently. WMS labels are self-contained. |

---

## Key Differences: Club vs Regular Orders

| Aspect | Regular (PICK_PACK) | Club |
|---|---|---|
| **SKU constraint** | Each order can have different SKUs and amounts | All orders must have identical SKUs and amounts |
| **Validation** | Standard field validation | Additional club representant comparison (SKU + amount match) |
| **Order release** | Cron job (`OrderReleaseJob`) creates picking orders | No automatic release — manual club line run |
| **Picking** | Individual picking orders assigned to pickers | Bulk stock transfer from staging lane to parcels |
| **State progression** | RAW → ASSIGNED → PROCESSABLE → STARTED → PICKED → PACKED → FINISHED | RAW → PACKED → FINISHED (skips picking states) |
| **QA/Packaging** | `finishedQA` endpoint processes packaging completion from OMS | `finishedQA` **discards** CLUB messages (lines 784–786) |
| **OMS messages** | Sent individually at each state transition | Three messages sent atomically during `runClubLine` (release, start, pick) |
| **Physical flow** | Pick from warehouse locations into totes → pack → palletize → ship | Stage stock in lane → run club line (creates all parcels) → palletize → ship |
| **Staging lane** | Not used | Required — must assign and stock before running |

---

## Key Files Reference

### Controllers
| File | Purpose |
|---|---|
| `controller/rest/OrderRestController.java` | REST API for OMS integration (order create, QA, cancel) |
| `controller/ClubLineController.java` | Web UI for club line operations |
| `controller/BillOfLadingController.java` | BOL creation and management |

### Services
| File | Purpose |
|---|---|
| `service/CustomerorderBatchService.java` | Club line core logic (runClubLine, staging lane, activation) |
| `service/ManageOrderService.java` | OMS message sending (on-hold, release, picked, shipped) |
| `service/BillofladingService.java` | BOL close and shipping finalization |
| `service/CustomerorderService.java` | Order state management (packaging, priority, cancel) |
| `service/job/ReleaseOrderJobService.java` | Automatic order release (not used for club) |
| `service/PrintService.java` | CUPS print server integration |
| `service/OrderMonitorViewService.java` | Tote label generation |
| `service/ViewDtoService.java` | Club run view queries (open/closed/active) |

### Models
| File | Purpose |
|---|---|
| `model/CustomerorderBatch.java` | Batch entity (type, state, staging lane) |
| `model/Customerorder.java` | Individual order entity |
| `model/CustomerorderPosition.java` | Line item entity (SKU, amount) |
| `model/Billoflading.java` | Bill of lading entity |
| `model/BillofladingPosition.java` | BOL position hierarchy (pallet/parcel/stock) |

### DTOs
| File | Purpose |
|---|---|
| `json/OrderBatchDto.java` | Inbound payload from OMS |
| `json/ClubLineSkuDto.java` | SKU overview response |
| `json/ClubLineUnitLoadDto.java` | Unit load availability response |
| `json/ClubLineActiveBatchViewDto.java` | Active club batch view |

### Constants
| Constant | Value | Location |
|---|---|---|
| `OrderBatchType.CLUB` | `"CLUB"` | `WmsConstants.java:483` |
| `State.ORDER_BATCH_ACTIVATED` | `520` | `WmsConstants.java:73` |
| `State.ORDER_BATCH_STAGING_LANE_ASSIGNED` | `525` | `WmsConstants.java:74` |
| `State.ORDER_BATCH_CLUB_RUN_FINISHED` | `530` | `WmsConstants.java:79` |
| `CLUB_LINE_ERROR_POSITION_AMOUNT_DIFFER` | `300` | `WmsConstants.java:1168` |
| `CLUB_LINE_ERROR_POSITION_SKU_DIFFER` | `301` | `WmsConstants.java:1169` |
| `CODE_PACKAGING_CLUB` | `"PACKAGING_CLUB"` | `WmsConstants.java:823` |


---

## Stale Batch Recovery

Club batches can become stuck in `ORDER_BATCH_ACTIVATED` state when all child orders complete individually but the batch finalization step was missed (concurrent `OptimisticLockException`, process crash, or interrupted `runClubLine`). A stuck batch blocks staging lane assignment for the occupied lane and prevents the lane from appearing in `availableStagingLanes`.

**Recovery:** `StaleClubBatchCleanupJob` (SBDEV-2164) runs daily at 03:00 by default, gated on `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` (default `false`). It queries batches in `ORDER_BATCH_ACTIVATED` where all orders are `>= FINISHED`, then calls `CustomerorderBatchService.finalizeBatchIfComplete()` per batch, capped at 500 per run.

See `sbdocs/3-Resources/architecture/wms1-scheduled-jobs-catalog.md §3.6` for full job details.

---

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |

**Re-verify every 60 days.** Next due: **2026-06-30**.
