---
title: WMS v2 REST API Reference — net.aim_ai.wms.controller.rest
last_verified: 2026-06-11
tags: [api, rest, oms-integration, wms2]
---

# WMS v2 REST API Reference

> **Audience:** OMS developers, integration engineers, QA, and support staff.
> **Base URL:** `https://<host>:<port>` (dev: `:8088`, prod: `:8080`)
> **Swagger UI:** `/swagger-ui/index.html`

---

## 1. Common Concepts

### 1.1 Authentication

All `/rest/**` endpoints require a valid **Keycloak JWT** (`Authorization: Bearer <token>`).  
Public endpoints (health, actuator, tenant discovery) are excluded. Roles required vary by endpoint; standard integration callers use the OMS API user credential configured per tenant.

### 1.2 Multi-Tenancy Headers

Every request **must** include:

| Header | Example | Description |
|---|---|---|
| `tenant_name` | `acme` | 2-char tenant identifier |
| `facility_code` | `W1` | 2-char warehouse/facility code |

The two headers combine into a 4-char routing key that selects the tenant database. Requests missing either header are rejected before reaching the controller.

### 1.3 Facility Code Validation (`facility_code` in body)

Every write DTO that extends `AbstractWebServiceDto` **also** carries a `facility_code` field in the JSON body. The controller validates this body field matches the system-configured warehouse identifier (`MULTIWAREHOUSE_IDENTIFIER` sysprop). Mismatch → `400 Bad Request`.

### 1.4 Idempotency

All `/rest/**` write endpoints are protected by `IdempotencyFilter` (SBDEV-2222).  
The key is auto-derived as `SHA-256(method|path|rawBody)` — no header is required.  
An explicit `Idempotency-Key: <value>` header (max 64 chars, `[A-Za-z0-9_-]`) overrides the auto-key for back-compat.

| Scenario | Behaviour |
|---|---|
| First request | Processed normally; response cached |
| Repeat (same key + same body hash) | Cached 2xx response replayed immediately |
| Same key, different body hash | `409 Conflict` |
| Body > 5 MB | Idempotency bypassed (DoS guard) |
| `app.idempotency.enforce=false` | Filter inactive (dev only) |

### 1.5 Standard Error Response

Every controller catches `WebserviceBusinessExceptionClientSide` and returns:

```json
HTTP 400 Bad Request

{
  "status": "failure",
  "description": "<human-readable error message>"
}
```

The `description` is built from `WmsConstants` error code templates with contextual parameters (entity names, field names, supplied values).

### 1.6 Standard Success Response (write endpoints)

```json
HTTP 204 No Content

{
  "status": "success"
}
```

Read/report endpoints return `HTTP 200 OK` with a JSON body.

### 1.7 Message / Audit Log

Every endpoint records a `Message` row (table `message`) for every call — both successful and failed — via `MessageService.createMessage(...)`. This log is queryable from the WMS Web UI and is the primary audit trail for OMS→WMS interactions.

---

## 2. AdviceRestController — `/rest/advice`

> Advice = an expected inbound delivery (ASN / purchase order / return / transfer notice).

### 2.1 `PUT /rest/advice/create`

**Purpose:** Create one or more regular or return advices (ASNs).

#### Request

```
PUT /rest/advice/create
Content-Type: application/json

List<AdviceDto>
```

**`AdviceDto`** (one element per advice):

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | Must match warehouse sysprop |
| `reference_id` | String | ✅ | External unique ID for this advice (checked for duplicates) |
| `client_id` | String | ✅ | Client number (`cl_nr`) in WMS |
| `type` | String | ✅ | `REGULAR` or `RETURN` (case-sensitive) |
| `day_of_delivery` | String | — | ISO date `yyyy-MM-dd` |
| `day_of_delivery_until` | String | — | ISO date `yyyy-MM-dd` |
| `delivery_note_number` | String | — | Supplier delivery note reference |
| `comment` | String | — | Free-text comment |
| `supplier` | String | — | Supplier name |
| `purchase_order_number` | String | — | PO reference |
| `printer_id` | Long | — | Label printer for inbound labels |
| `positions` | List\<AdvicePositionDto\> | — | Line items (see below) |

**`AdvicePositionDto`** (one per SKU line):

| Field | Type | Required | Description |
|---|---|---|---|
| `reference_id` | String | ✅ | External unique ID for this position |
| `client_id` | String | ✅ | Client number for this position |
| `sku` | String | ✅ | SKU / item number; must exist in WMS for the client |
| `box_id` | String | ✅ | Box type external ID |
| `amount_of_boxes` | Integer | ✅ | Number of cases/boxes expected |
| `amount_of_bottles` | Integer | ✅ | Number of units expected (≥ 0) |

#### Business Rules

- `reference_id` must be unique across all existing advices.
- `client_id` must exist as a `Client` (`cl_nr`).
- For `RETURN` type: the client must have `enable_receiving = true`.
- `type` must be exactly `REGULAR` or `RETURN`; any other value → `400`.
- SKU must exist for the resolved `client_id`.
- Duplicate `sku` within the same advice position list is rejected.
- Created advice state: `OPEN`. Short/over delivery defaults: both allowed.
- A `TRANSFER` type value in this endpoint is currently rejected (TRANSFER advices use `/createTransfer`).

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| `facility_code` missing or wrong | 400 | `FIELD_NOT_SET` / `WRONG_FACILITY_CODE` |
| `reference_id` missing | 400 | `FIELD_NOT_SET` |
| `type` missing | 400 | `FIELD_NOT_SET` |
| `client_id` missing | 400 | `FIELD_NOT_SET` |
| Advice with same `reference_id` exists | 400 | `ENTITY_ALREADY_EXITS` |
| Client not found | 400 | `ENTITY_ALREADY_EXITS` (known naming inconsistency in code) |
| Client not enabled for receiving (RETURN) | 400 | `NOT_ENABLLED_FOR_RECEIVING` |
| `day_of_delivery` not parseable as ISO date | 400 | `FIELD_MALFORMED_FORMAT` |
| `amount_of_bottles` < 0 | 400 | `FIELD_MALFORMED_FORMAT` |
| SKU not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| `box_id` not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Null body | 400 | `PARAMETER_IS_NULL` |
| Empty list | 400 | `NO_POSITION` |

---

### 2.2 `PUT /rest/advice/createTransfer`

**Purpose:** Create a transfer advice from an OMS-initiated transfer BOL. Represents stock moving between facilities (TRANSFER type).

#### Request

```
PUT /rest/advice/createTransfer
Content-Type: application/json

BillOfLadingWebServiceDto
```

**`BillOfLadingWebServiceDto`**:

| Field | Type | Required | Description |
|---|---|---|---|
| `transfer_id` | String | ✅ | Unique transfer ID; must not exist in WMS |
| `positions` | List\<PalletDto\> | ✅ | Exactly one pallet expected |

**`PalletDto`**:

| Field | Type | Description |
|---|---|---|
| `pallet_label` | String | Label for the pallet |
| `positions` | List\<OrderDto\> | Exactly one order allowed per transfer |

**`OrderDto`** (inside PalletDto.positions — only one element allowed):

| Field | Type | Required | Description |
|---|---|---|---|
| `client_id` | String | ✅ | Maps to `cl_nr`; first position determines the client |
| `shippers_id` | String | — | Shipper identifier |
| `positions` | List\<OrderPositionDto\> | ✅ | Line items with SKUs |

**`OrderPositionDto`**:

| Field | Type | Required | Description |
|---|---|---|---|
| `unique_id` | String | ✅ | External position ID |
| `sku_id` | String | ✅ | SKU number |
| `amount` | Integer | ✅ | Quantity |

#### Business Rules

- `transfer_id` must be unique.
- Exactly **one** pallet and **one** order are allowed per batch.
- Client is resolved from the first `OrderDto`.
- Advice type set to `TRANSFER`; short/over delivery: both disabled.
- `Adviceposition.notifiedcases` is always `1`; `notifiedamount` comes from `amount`.

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| Null body | 400 | `PARAMETER_IS_NULL` |
| No pallets | 400 | `NO_POSITION` |
| More than one order in batch | 400 | `TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH` |
| `transfer_id` already exists | 400 | `ENTITY_ALREADY_EXITS` |
| Client not found | 400 | `ENTITY_DOES_NOT_EXISTS` |

---

### 2.3 `PUT /rest/advice/createHubAndSpoke`

**Purpose:** Create a hub-and-spoke (H&S) advice — cross-warehouse transfer of parcels (packages without itemdata).

#### Request

```
PUT /rest/advice/createHubAndSpoke
Content-Type: application/json

BillOfLadingWebServiceDto
```

**`BillOfLadingWebServiceDto`** (H&S-specific fields used):

| Field | Type | Required | Description |
|---|---|---|---|
| `transfer_id` | String | ✅ | Unique transfer ID |
| `destination_warehouse` | String | ✅ | Must match this WMS's warehouse sysprop |
| `source_warehouse` | String | — | Origin warehouse identifier |
| `bol_name` | String | — | Used as delivery note number |
| `positions` | List\<PalletDto\> | ✅ | One or more pallets |

Each **`PalletDto`** → `positions` → **`OrderDto`** (parcel):

| Field | Type | Description |
|---|---|---|
| `unique_id` | String | External parcel ID (used as `externalid` on advice position) |
| `shippers_id` | String | Carrier/shipper identifier; auto-created if unknown |
| `parcel_external_number` | String | Parcel barcode/label |
| `manifest_location` | String | Manifest location reference |

**`PalletDto.palletLabel`** → stored as `adviceposition.palletlabel`.

#### Business Rules

- `destination_warehouse` must match this WMS's `MULTIWAREHOUSE_IDENTIFIER` sysprop.
- `transfer_id` must not already exist.
- Advice type: `HUB_AND_SPOKE`. Client: system client (special internal client).
- Unknown `shippers_id` values are **auto-created** as new `Shipperid` entities with carrier `"default"`.
- `itemdata` is left null on the position (parcels carry no SKU-level data).
- Box type defaults to the system-configured default box type (`SYSTEM_PROPERTY_DEFAULT_BOX_TYPE_KEY`).

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| Null body | 400 | `PARAMETER_IS_NULL` |
| No pallets or no orders | 400 | `NO_POSITION` |
| `destination_warehouse` missing | 400 | `FIELD_NOT_SET` |
| `destination_warehouse` mismatch | 400 | `WRONG_FACILITY_CODE` |
| `transfer_id` already exists | 400 | `ENTITY_ALREADY_EXITS` |
| System client not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Default box type not configured | 400 | `ENTITY_DOES_NOT_EXISTS` |

---

### 2.4 `POST /rest/advice/reopen` ⚠️ NOT IMPLEMENTED

This endpoint exists in the code but throws `RuntimeException("method not supported")`.  
**Do not call this endpoint.**

---

## 3. OrderRestController — `/rest/order`

> Manages customer order batches throughout their lifecycle: creation → priority → cancel → QA → transfer completion.

### 3.1 `PUT /rest/order/create`

**Purpose:** Import one or more order batches (each batch contains one or more orders with line items).

#### Request

```
PUT /rest/order/create
Content-Type: application/json

List<OrderBatchDto>
```

**`OrderBatchDto`**:

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | Must match warehouse sysprop |
| `batch_id` | String | ✅ | Unique batch identifier in OMS |
| `client_id` | String | ✅ | Client number (`cl_nr`) |
| `priority` | Integer | ✅ | 1 (urgent) – 5 (very low) |
| `batch_type` | String | ✅ | `REGULAR`, `CLUB`, `TRANSFER_INTRACOMPANY`, `TRANSFER_OFFSITE` |
| `batch_name` | String | — | Human-readable batch name |
| `batch_instructions` | String | — | Special instructions text |
| `criteria` | String | — | Filtering/selection criteria |
| `transfer_id` | String | ✅ for TRANSFER types | Links to an advice transfer |
| `bol_number` | String | — | BOL reference |
| `positions` | List\<OrderDto\> | ✅ | Orders in this batch (≥ 1) |

**`OrderDto`** (one per shipment/parcel):

| Field | Type | Required | Description |
|---|---|---|---|
| `unique_id` | String | ✅ | External order ID; globally unique |
| `client_id` | String | ✅ | Client number for this order |
| `shippers_id` | String | ✅ | Carrier/shipper identifier |
| `box_sku` | String | ✅ | Box type external ID |
| `weight` | Integer | ✅ | Order weight |
| `fulfillment_type` | String | ✅ | Fulfillment type code |
| `positions` | List\<OrderPositionDto\> | ✅ | Line items (≥ 1) |
| `parcel_external_number` | String | — | Barcode/tracking number; must be globally unique if provided |
| `client_order_number` | String | — | Client's own order reference |
| `tote_label` | String | — | Pre-assigned tote label |
| `brand` | String | — | Brand code |
| `brand_name` | String | — | Brand display name |
| `special_instructions` | String | — | Picker special instructions |
| `manifest_location` | String | — | Manifest location |
| `recipient` | String | — | Recipient name |
| `pallet_label` | String | — | Outbound pallet label |
| `picking_date` | String | — | Requested picking date |

**`OrderPositionDto`** (one per SKU per order):

| Field | Type | Required | Description |
|---|---|---|---|
| `unique_id` | String | ✅ | External position ID; globally unique |
| `client_id` | String | ✅ | Client number |
| `number` | Integer | ✅ | Position number (≥ 0, unique within order) |
| `sku_id` | String | ✅ | SKU/item number; must exist for the client |
| `amount` | Integer | ✅ | Quantity (≥ 1) |

#### Business Rules

- All `unique_id` values (order and position) must be globally unique — checked against the DB.
- All `parcel_external_number` values must be unique and not matching any existing `unitload.labelid`.
- For `CLUB` batch type: all orders must have identical SKU line-ups with matching quantities.
- `TRANSFER_INTRACOMPANY` / `TRANSFER_OFFSITE`: only **one** order per batch; `transfer_id` required; previous non-terminal transfer batch with same ID → rejected.
- `priority` must be 1–5; maps to `PRIORITY_URGENT` → `PRIORITY_VERY_LOW`.
- Position numbers within an order must be unique and non-negative.
- Duplicate SKU within a single order is rejected.
- All referenced clients, box SKUs, and item data are validated up-front before any persistence.

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| `facility_code` wrong | 400 | `WRONG_FACILITY_CODE` |
| `batch_id` duplicate | 400 | `ENTITY_ALREADY_EXITS` |
| `priority` out of range | 400 | `FIELD_MALFORMED_FORMAT` |
| `batch_type` unrecognised | 400 | `FIELD_MALFORMED_FORMAT` |
| Transfer batch > 1 order | 400 | `TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH` |
| `transfer_id` missing for TRANSFER | 400 | `FIELD_NOT_SET` |
| Duplicate active transfer | 400 | `NOT_UNIQUE_VALUE` |
| Duplicate `unique_id` (order or position) | 400 | `NOT_UNIQUE_VALUE` / `ENTITY_ALREADY_EXITS` |
| Duplicate `parcel_external_number` | 400 | `NOT_UNIQUE_VALUE` / `ENTITY_ALREADY_EXITS` |
| Client not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Box type (`box_sku`) not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| SKU not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| CLUB SKU/amount mismatch between orders | 400 | `CLUB_LINE_ERROR_POSITION_SKU_DIFFER` / `CLUB_LINE_ERROR_POSITION_AMOUNT_DIFFER` |
| Null body | 400 | `PARAMETER_IS_NULL` |

---

### 3.2 `POST /rest/order/updatePriority`

**Purpose:** Change the priority of existing order batches.

#### Request

```
POST /rest/order/updatePriority
Content-Type: application/json

List<OrderBatchDto>
```

**Required fields only:**

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | |
| `batch_id` | String | ✅ | Must exist in WMS |
| `priority` | Integer | ✅ | 1–5 |

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| `batch_id` not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| `priority` out of range | 400 | `FIELD_MALFORMED_FORMAT` |

---

### 3.3 `POST /rest/order/cancelPositions`

**Purpose:** Cancel individual orders (positions within a batch) from OMS.

#### Request

```
POST /rest/order/cancelPositions
Content-Type: application/json

List<OrderBatchDto>
```

**Required fields:**

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | |
| `batch_id` | String | ✅ | Batch must exist |
| `positions` | List\<OrderDto\> | ✅ | Orders to cancel; each needs `unique_id` |

Each `OrderDto` only needs `unique_id` (the external order ID).

#### Business Rules

- The batch must exist.
- Each order (`unique_id`) must exist.
- Orders are cancelled via `CustomerorderService.cancelOrder()`. If an order is in a non-cancellable state (e.g., already packed, shipped), `400 WRONG_STATE` is returned.
- Cancellation is all-or-nothing per request: if any order fails, the entire response is a failure.

#### Success Response

```
HTTP 200 OK
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| Batch not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Order not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Order in non-cancellable state | 400 | `WRONG_STATE` (includes current state text) |
| Unexpected error | 400 | `GENERIC_ERROR` |

---

### 3.4 `POST /rest/order/finishedQA`

**Purpose:** Signal that QA inspection is complete for packed orders. Triggers the `packageOrder()` state transition (order moves from `PICKED` → packaged state) and updates/assigns the parcel label.

#### Request

```
POST /rest/order/finishedQA
Content-Type: application/json

List<OrderBatchDto>
```

**Required fields:**

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | |
| `batch_id` | String | ✅ | Batch must exist |
| `positions` | List\<OrderDto\> | ✅ | Orders that finished QA |

Each `OrderDto` needs:

| Field | Type | Required | Description |
|---|---|---|---|
| `unique_id` | String | ✅ | External order ID |
| `parcel_external_number` | String | ✅ | Parcel tracking/barcode; must not already exist as a `Unitload` |

#### Business Rules

- **CLUB** batches and **TRANSFER** batches: QA notification is silently discarded (logged as warning, returns success).
- Batch must not be in terminal state (`FINISHED` or beyond).
- Each order must be in `PICKED` state; other states → `400 WRONG_STATE`.
- Each order must belong to the specified batch.
- The `parcel_external_number` is updated on the order if it changed.
- A new `Unitload` is created for the parcel label; duplicate label → `400 ENTITY_ALREADY_EXITS`.
- `packageOrder()` is called to advance the order state.

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| Batch not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Batch in finished state | 400 | `WRONG_STATE` |
| Order not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Order not in PICKED state | 400 | `WRONG_STATE` |
| Order belongs to different batch | 400 | `CHILD_NOT_PART_OF_PARENT` |
| Parcel label already used | 400 | `ENTITY_ALREADY_EXITS` |
| `packageOrder` fails | 400 | `GENERIC_ERROR` |

---

### 3.5 `PUT /rest/order/finishedTransfer`

**Purpose:** Mark a transfer as completed from the OMS side (e.g., stock acknowledged at destination).

#### Request

```
PUT /rest/order/finishedTransfer
Content-Type: application/json

AcceptTransferDto
```

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | — | (inherited from AbstractWebServiceDto) |
| `transfer_id` | String | ✅ | The transfer to finalise |

#### Business Rules

- Delegates to `BillofladingService.finishTransfer(transferId)`.
- Advances the BOL and associated advice to a terminal state.

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| Transfer not found or illegal state | 400 | `GENERIC_ERROR` (wraps `BusinessException` / `FacadeException`) |

---

## 4. SkuRestController — `/rest/sku`

> Manages SKU (item data) master records. All write operations evict the `itemdata` Caffeine cache.
>
> **Whitespace normalization (since 260610, FreeScout #959):** `sku` and `sku_name` are trimmed of
> leading/trailing whitespace at the entry of `create`, `update`, and `delete` — before the
> required-field checks, so a whitespace-only value fails `FIELD_NOT_SET`. A padded SKU
> (`"BONMFPN23 "`) resolves to the trimmed stored row instead of creating a duplicate. Interior
> whitespace is preserved and still matched exactly.

### 4.1 `PUT /rest/sku/create`

**Purpose:** Create new SKU records in the WMS. Fails if the SKU already exists for the client.

#### Request

```
PUT /rest/sku/create
Content-Type: application/json

List<SkuDto>
```

**`SkuDto`**:

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | Must match warehouse sysprop |
| `sku` | String | ✅ | SKU / item number |
| `sku_name` | String | ✅ | Product display name |
| `client_id` | String | ✅ | Client number (`cl_nr`) |
| `box_id` | String | — | Default box type external ID |
| `unit_identifier_id` | String | — | Unit of measure identifier |
| `bottle_size` | Integer | — | Volume in ml |
| `vintage` | Integer | — | Product vintage year |
| `varietal` | String | — | Grape varietal |
| `wine_type` | String | — | Wine classification |
| `image_filename` | String | — | Product image file reference |

#### Business Rules

- SKU must not already exist for the given client → `422` if it does.
- `client_id` must exist.
- `box_id` must exist in `boxtype` if provided.
- `unit_identifier_id` must exist in `itemunit` if provided.
- New SKU is assigned to the default put-away lane location.
- Cache `itemdata` is fully evicted after the write (`@CacheEvict(allEntries=true)`).

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| SKU already exists for client | 422 | `ENTITY_ALREADY_EXITS` |
| Client not found | 422 | `ENTITY_DOES_NOT_EXISTS` |
| `box_id` not found | 422 | `ENTITY_DOES_NOT_EXISTS` |
| `unit_identifier_id` not found | 422 | `ENTITY_DOES_NOT_EXISTS` |
| `sku` or `sku_name` or `client_id` missing | 422 | `FIELD_NOT_SET` |
| Null body | 422 | `PARAMETER_IS_NULL` |

> **Note:** SKU endpoints return `HTTP 422 Unprocessable Entity` on validation failure, unlike other controllers which return `400`.

---

### 4.2 `POST /rest/sku/update`

**Purpose:** Update existing SKU records. Creates the SKU if it does not yet exist (upsert behaviour via `SkuBatchCreateUpdateService.upsertAll()`).

#### Request

```
POST /rest/sku/update
Content-Type: application/json

List<SkuDto>
```

Same `SkuDto` structure as `/create`. Required fields: `sku`, `sku_name`, `client_id`, `facility_code`.

#### Business Rules

- If the SKU exists for the client, fields are updated.
- If the SKU does not exist, it is created (upsert).
- Cache `itemdata` fully evicted after write.

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

Same structure as `/create` — `HTTP 422 Unprocessable Entity`.

---

### 4.3 `DELETE /rest/sku/delete`

**Purpose:** Delete SKU records from the WMS.

#### Request

```
DELETE /rest/sku/delete
Content-Type: application/json

List<SkuDto>
```

Required fields per `SkuDto`: `facility_code`, `sku`, `client_id`.

#### Business Rules

- Client must exist.
- SKU must exist for the client.
- ⚠️ **Stock check is not yet implemented** (TODO in code). Deleting a SKU with live inventory may cause data integrity issues.

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| Client not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| SKU not found for client | 400 | `ENTITY_DOES_NOT_EXISTS` |
| `sku` or `client_id` missing | 400 | `FIELD_NOT_SET` |

---

## 5. StockCountRestController — `/rest/stockcount`

> Stock count and inventory reporting.

### 5.1 `POST /rest/stockcount/getStockCount`

**Purpose:** Retrieve current stock count figures for a specific client and optionally a specific SKU.

#### Request

```
POST /rest/stockcount/getStockCount
Content-Type: application/json

StockCountDto
```

**`StockCountDto`** (request fields used):

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | Must match warehouse sysprop |
| `clientNumber` | String | ✅ | Client number to query |
| `itemDataNumber` | String | — | SKU/item number; omit for all SKUs of the client |

> **Note:** The JSON keys for `clientNumber` and `itemDataNumber` are **not** snake_case in this DTO (a known inconsistency). Send them as `clientNumber` and `itemDataNumber`.

#### Success Response

```
HTTP 200 OK

List<StockCountDto>
```

Each `StockCountDto` in the response:

| Field | Type | Description |
|---|---|---|
| `clientNumber` | String | Client number |
| `itemDataNumber` | String | SKU/item number |
| `total` | int | Total units on hand |
| `damage` | int | Damaged units |
| `missing` | int | Units flagged as missing |
| `on_hold` | int | Units on hold |
| `transfer` | int | Units in transit/transfer |

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| `facility_code` wrong | 400 | `WRONG_FACILITY_CODE` |
| Client not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| `itemDataNumber` provided without `clientNumber` | 400 | `NOT_UNIQUE_VALUE` |

---

### 5.2 `GET /rest/stockcount/triggerStockCount`

**Purpose:** Manually trigger the stock summary export scheduled job (`StockSummaryExportJob`) outside its normal cron schedule.

#### Request

```
GET /rest/stockcount/triggerStockCount
```

No body or parameters required.

#### Success Response

```
HTTP 200 OK
(empty body — job runs synchronously in the request thread)
```

> ⚠️ **Technical note:** This runs the job synchronously in the HTTP thread. For large warehouses this may be a long-running call. Use with caution in production.

---

## 6. TransactionReportRestController — `/rest/report`

> Warehouse transaction reporting — inventory movement summaries and audit-level detail.

### 6.1 `POST /rest/report/getTransactionReport`

**Purpose:** Retrieve a summarised stock movement report per SKU for a client over a date range.

#### Request

```
POST /rest/report/getTransactionReport
Content-Type: application/json

WarehouseTransactionReportRequest
```

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | Must match warehouse sysprop |
| `client_code` | String | ✅ | Client number |
| `start_date` | String | ✅ | Format: `yyyy-MM-dd HH:mm:ss` |
| `end_date` | String | ✅ | Format: `yyyy-MM-dd HH:mm:ss` |
| `sku` | String | — | Filter by SKU (unused in summary query) |

#### Success Response

```
HTTP 200 OK

List<WarehouseTransactionReportResponse>
```

Each row represents one SKU for the client:

| Field | Type | Description |
|---|---|---|
| `facility_code` | String | Warehouse identifier |
| `client_name` | String | Client display name |
| `client_number` | String | Client number |
| `product_name` | String | SKU display name |
| `sku` | String | SKU / item number |
| `wms_product_id` | long | Internal WMS item ID |
| `vintage` | long | Vintage year (0 if null) |
| `volume` | long | Bottle size in ml (0 if null) |
| `beginning_inventory` | long | Stock at start of period |
| `received` | long | Units received |
| `returned` | long | Units returned |
| `putaway` | long | Units put away |
| `adjustments` | long | Inventory adjustments |
| `damaged` | long | Units damaged |
| `depleted_picked` | long | Units picked (regular orders) |
| `depleted_club` | long | Units picked (club orders) |
| `shipped` | long | Units shipped |
| `ending_inventory` | long | Stock at end of period |
| `net_change` | long | Net inventory change |

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| `client_code` missing | 400 | `FIELD_NOT_SET` |
| `start_date` / `end_date` missing | 400 | `FIELD_NOT_SET` |
| Client not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Date format invalid | 400 | `FIELD_MALFORMED_FORMAT` |
| `facility_code` wrong | 400 | `WRONG_FACILITY_CODE` |

---

### 6.2 `POST /rest/report/getTransactionDetailedReport`

**Purpose:** Retrieve individual transaction-level stock movement records for a client, with optional SKU filter and date range.

#### Request

```
POST /rest/report/getTransactionDetailedReport
Content-Type: application/json

WarehouseTransactionDetailedReportRequest
```

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | Must match warehouse sysprop |
| `client_code` | String | ✅ | Client number |
| `start_date` | String | ✅ | Format: `yyyy-MM-dd HH:mm:ss` |
| `end_date` | String | ✅ | Format: `yyyy-MM-dd HH:mm:ss` |
| `sku` | String | — | Filter by specific SKU; omit or `null` for all SKUs |

#### Success Response

```
HTTP 200 OK

List<WarehouseTransactionDetailedReportResponse>
```

Each row is one individual transaction event:

| Field | Type | Description |
|---|---|---|
| `facility_code` | String | Warehouse identifier |
| `client_name` | String | Client display name |
| `client_number` | String | Client number |
| `sku` | String | SKU / item number |
| `product_name` | String | SKU display name |
| `vintage` | long | Vintage year |
| `volume` | long | Bottle size in ml |
| `location` | String | Warehouse location name |
| `transaction_date` | String | Timestamp `yyyy-MM-dd HH:mm:ss` |
| `transaction_type` | String | Type of transaction (receive, pick, adjust, etc.) |
| `transaction_number` | String | WMS internal transaction reference |
| `order_number` | String | Associated order number |
| `package_id` | String | Associated package number |
| `total` | long | Running total |
| `received` | long | Received delta |
| `returned` | long | Returned delta |
| `adjustments` | long | Adjustment delta |
| `transferred` | long | Transfer delta |
| `damaged` | long | Damaged delta |
| `depleted_picked` | long | Depleted via pick |
| `depleted_club` | long | Depleted via club pick |
| `shipped` | long | Shipped delta |
| `net_change` | long | Net change this transaction |
| `user` | String | Username who performed the action |
| `comment` | String | User comment (empty string if null) |

#### Failure Responses

Same conditions as `/getTransactionReport`, plus:

| Condition | HTTP | Description |
|---|---|---|
| `sku` provided but not found for client | 400 | `ENTITY_DOES_NOT_EXISTS` |

---

## 7. UtilRestController — Not an Active HTTP Controller

`UtilRestController` is annotated `@Service` only — it is **not** a `@RestController` or `@Controller`. Despite having a `@RequestMapping(value = "/initDB", method = POST)` declaration, Spring MVC does **not** register it as a web endpoint. This class is used internally for database initialisation during first-time setup and is invoked programmatically, not via HTTP.

---

## 8. Technical Notes for Integrators

### 8.1 Retry Safety

All `/rest/**` write endpoints are idempotent by design (SBDEV-2222). OMS may safely retry on network failure; the `IdempotencyFilter` will replay the cached response for repeated identical requests.

### 8.2 OMS Notification Flow

After certain state transitions (order picked, advice closed, transfer finished), WMS notifies OMS asynchronously via the **transactional outbox** (`outbox_message` table). The `OutboxDispatcherJob` polls every 15 seconds and POSTs to OMS. Failed notifications are retried with exponential back-off up to 5 attempts.

> **SBDEV-2381 (2026-06-01) — `event_version` on picking-status payloads:** Outbound WMS→OMS picking-status payloads (the `OrderBatchDto` posted to `readytopick` / `picking` / `finishedPicking`) now carry an additive top-level **`event_version`** field equal to the dispatching `outbox_message` row id (a BIGSERIAL, monotonic per parcel). It is injected into the POST body at dispatch time; OMS may use it to **reject stale / out-of-order events**. Existing fields are unchanged. The dispatcher also now claims and sends events in strict per-parcel order (ordering gate + in-Java sort + sequential POST loop) — see `architecture/wms2-oms-integration-map.md` §2.1 for the full mechanism.

### 8.3 Date Format

All date fields in reports use `yyyy-MM-dd HH:mm:ss`. Advice `day_of_delivery` / `day_of_delivery_until` use ISO date `yyyy-MM-dd`.

### 8.4 Priority Mapping

| `priority` value | WMS constant |
|---|---|
| 1 | `PRIORITY_URGENT` |
| 2 | `PRIORITY_HIGH` |
| 3 | `PRIORITY_MEDIUM` |
| 4 | `PRIORITY_LOW` |
| 5 | `PRIORITY_VERY_LOW` |

### 8.5 Batch Type Values

| `batch_type` | Description |
|---|---|
| `REGULAR` | Standard fulfilment order |
| `CLUB` | Club line — all orders in batch must have identical SKU/amount composition |
| `TRANSFER_INTRACOMPANY` | Internal warehouse-to-warehouse transfer; one order per batch |
| `TRANSFER_OFFSITE` | Offsite transfer; one order per batch |

### 8.6 Known Issues / Limitations

| Item | Detail |
|---|---|
| `/advice/create` client-not-found error | Returns `ENTITY_ALREADY_EXITS` instead of `ENTITY_DOES_NOT_EXISTS` (code bug, not a typo in this doc) |
| `/sku/delete` — no live-stock check | Deleting a SKU with live inventory is allowed at the API level; downstream integrity depends on application-level guards |
| `/advice/reopen` — not implemented | Throws `RuntimeException`; do not call |
| `StockCountDto` JSON field names | `clientNumber` / `itemDataNumber` are camelCase (not snake_case) — inconsistent with the rest of the API |
| `StockCountRestController.triggerStockCount` | Runs the export job synchronously in the request thread; no timeout |
