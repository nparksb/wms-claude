---
type: architecture
status: active
system: wms1
last_verified: 2026-06-26
---

## TL;DR

- Authoritative catalog of every HTTP call crossing the OMS↔WMS1 boundary in `v1/wms-api` + `v1/oms`.
- **Inbound (OMS→WMS):** REST endpoints under `/rest/**` — unauthenticated, warehouse-validated via `facility_code`, audit-logged in `message` table. Controllers: `OrderRestController`, `AdviceRestController`, `StockCountRestController`.
- **Outbound (WMS→OMS):** HTTP Basic auth, 5s connect / 15s read timeout, **no retry**; most calls deferred post-commit via `OmsNotificationHelper.deferToCommit` — rollback silently drops the callback.
- **Key constraint:** `WEBSERVICE_BEHAVIOUR=keep` does NOT suppress outbound HTTP; it only affects `MessageService` routing. There is no runtime kill-switch for callbacks.
- **Failure modes:** missing sysprop URL → 503 NPE; non-200 OMS response → logged WARN but no exception; OMS-initiated cancel never triggers the cancel callback (by design).
- **Consult this doc** when: an integration call returns an unexpected error, a callback is missing in OMS, adding a new OMS↔WMS endpoint, or debugging `message` table anomalies.

# WMS1 ↔ OMS Integration Map

This document is the authoritative reference for every call that crosses the OMS↔WMS1 boundary: inbound (OMS calls WMS REST endpoints) and outbound (WMS fires HTTP callbacks back to OMS). It is the first document to check when an integration call fails, a callback goes missing, or a new integration point is needed.

**Code base:** `v1/wms-api` (Java 8 / Spring Boot 2.3.7)
**OMS:** `v1/oms` (PHP 5.6 / Zend Framework 2)
**Auth on `/rest/**`:** none — `SecurityConfiguration` explicitly excludes these paths from Keycloak JWT validation.

---

## §1 Inbound — OMS calls WMS

All inbound endpoints share two properties:

- **Base security:** unauthenticated — Spring Security does not check JWT on `/rest/**`.
- **Warehouse validation:** every endpoint calls `AbstractRestController.validateWarehouse(dto)`, which reads `SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY` from `LosSysprop` and rejects requests whose `facility_code` does not match.
- **Audit:** every request (success and failure) writes a `Message` row via `MessageService.createMessage(omsInstance, wmsInstance, payload, processType, "N/A", status, httpCode, null)`.
- **Error format:** on `WebserviceBusinessExceptionClientSide`, controllers return `400 Bad Request` with the exception's `errorMap` as JSON body.

---

### 1.1 `OrderRestController` — `/rest/order`

#### `PUT /rest/order/create`

| Field | Value |
|---|---|
| HTTP method | `PUT` |
| Path | `/rest/order/create` |
| Auth | None |
| Request body | `List<OrderBatchDto>` |
| Success response | `204 No Content` — `{"status":"success"}` |
| Error response | `400 Bad Request` — `errorMap` JSON |

**Request DTO — `OrderBatchDto` key fields:**

| Field | Required | Notes |
|---|---|---|
| `facility_code` | yes | Must match warehouse identifier sysprop |
| `batch_id` | yes | Must be unique in `customerorder_batch` |
| `client_id` | yes | Must exist in `client` table (`cl_nr`) |
| `priority` | yes | Integer 1–5 (1=urgent, 5=very-low) |
| `batch_type` | yes | Enum: `REGULAR`, `CLUB`, `TRANSFER_INTRACOMPANY`, `TRANSFER_OFFSITE`, `HUB_AND_SPOKE` |
| `transfer_id` | conditional | Required for `TRANSFER_*` types; must be unique or in terminal state |
| `positions` | yes | `List<OrderDto>` — at least one |

Each `OrderDto` requires: `unique_id`, `client_id`, `shippers_id`, `weight`, `box_sku` (must exist in `boxtype.external_id`), `fulfillment_type`, and `positions` (`List<OrderPositionDto>`). Each position requires: `unique_id`, `client_id`, `sku_id`, `amount ≥ 1`.

**What it does:** validates all input, then persists `CustomerorderBatch` + `Customerorder` + `CustomerorderPosition` rows in state `RAW`. If `picking_date` is future-dated, orders land in `FUTURE_PICKING_DATE` state instead. Club batch validation enforces identical SKU/amount across all orders in the batch. Transfer batches allow only one order per batch.

**Error conditions (400):**
- `PARAMETER_IS_NULL` — null list
- `FIELD_NOT_SET` — any required field missing
- `ENTITY_ALREADY_EXITS` — `batch_id` already exists; `unique_id` already in `customerorder`; `parcel_external_number` already in `unitload`
- `ENTITY_DOES_NOT_EXISTS` — `client_id`, `box_sku`, or `sku_id` not found
- `NOT_UNIQUE_VALUE` — duplicate `unique_id`, `parcel_external_number`, or `transfer_id` on active batch
- `TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH` — transfer batch contains >1 order
- `CLUB_LINE_ERROR_POSITION_AMOUNT_DIFFER` / `CLUB_LINE_ERROR_POSITION_SKU_DIFFER` — club SKU mismatch
- `WRONG_FACILITY_CODE` — facility_code mismatch

---

#### `POST /rest/order/updatePriority`

| Field | Value |
|---|---|
| HTTP method | `POST` |
| Path | `/rest/order/updatePriority` |
| Auth | None |
| Request body | `List<OrderBatchDto>` (only `facility_code`, `batch_id`, `priority` are used) |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**What it does:** looks up each `CustomerorderBatch` by `batch_id` and calls `CustomerorderBatchService.setPriority()` (which uses `OptimisticLockRetryTemplate` for concurrent-write safety). Cascades priority down to all `Customerorder` rows in the batch.

**Error conditions (400):** `ENTITY_DOES_NOT_EXISTS` if batch not found; `WRONG_FACILITY_CODE`; `FIELD_NOT_SET`/`FIELD_MALFORMED_FORMAT` for missing/invalid priority.

---

#### `POST /rest/order/cancelPositions`

| Field | Value |
|---|---|
| HTTP method | `POST` |
| Path | `/rest/order/cancelPositions` |
| Auth | None |
| Request body | `List<OrderBatchDto>` — each with `batch_id` and `positions` (list of `OrderDto` with `unique_id`) |
| Success response | `204 No Content` |
| Partial-failure response | `400 Bad Request` — `{"status":"partial_failure","errors":{...}}` |
| Error response | `400 Bad Request` |

**What it does:** cancels individual orders within a batch by calling `CustomerorderService.cancelOrder(order, false)`. Cancellation from OMS sets `cancellationFromWithinWMS=false` — **no outbound OMS callback is fired** for OMS-initiated cancels. Errors per order are collected; if any fail, returns partial-failure. Batch-level state not changed here.

**Critical note:** cancels that originate from OMS (`cancelPositions`) do **not** trigger the `WEBSERVICE_ORDER_BATCH_CANCELLED` outbound callback. Only WMS-initiated cancels do (see §2.7).

**Error conditions (400):** `ENTITY_DOES_NOT_EXISTS` for missing batch or order.

---

#### `POST /rest/order/finishedQA`

| Field | Value |
|---|---|
| HTTP method | `POST` |
| Path | `/rest/order/finishedQA` |
| Auth | None |
| Request body | `List<OrderBatchDto>` — each with `batch_id` and `positions` (with `unique_id` and `parcel_external_number`) |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**What it does:** for each order: verifies current state is `PICKED`, optionally updates `parcel_external_number`, then calls `CustomerorderService.packageOrder()` which moves the order to `PACKED` state and creates the parcel `Unitload`. Discards QA messages for `CLUB` and `TRANSFER_*` batch types (logs a warning and skips). Rejects the batch if it is already in a `FINISHED` or beyond state.

**Error conditions (400):** `WRONG_STATE` if batch or order not in expected state; `ENTITY_ALREADY_EXITS` if `parcel_external_number` already exists in `unitload`; `ENTITY_DOES_NOT_EXISTS` for missing batch or order.

---

#### `PUT /rest/order/finishedTransfer`

| Field | Value |
|---|---|
| HTTP method | `PUT` |
| Path | `/rest/order/finishedTransfer` |
| Auth | None |
| Request body | `AcceptTransferDto` — `{ "transfer_id": "..." }` |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**What it does:** calls `BillofladingService.finishTransfer(transferId)` to close the outbound transfer BOL and move associated orders to a terminal state.

---

### 1.2 `AdviceRestController` — `/rest/advice`

#### `PUT /rest/advice/create`

| Field | Value |
|---|---|
| HTTP method | `PUT` |
| Path | `/rest/advice/create` |
| Auth | None |
| Request body | `List<AdviceDto>` |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**Request DTO — `AdviceDto` key fields:**

| Field | Required | Notes |
|---|---|---|
| `facility_code` | yes | Warehouse validation |
| `reference_id` | yes | External ID — must be unique in `advice.external_id` |
| `type` | yes | `REGULAR` or `RETURN` (TRANSFER handled separately) |
| `client_id` | yes | Must exist; `RETURN`/`TRANSFER` types require `client.enable_receiving=true` |
| `positions` | yes | `List<AdvicePositionDto>` |

Each `AdvicePositionDto` requires: `reference_id`, `client_id`, `sku` (must exist), `amount_of_bottles ≥ 0`, `box_id` (if present, must exist in `boxtype`).

**What it does:** creates `Advice` + `Adviceposition` rows in state `OPEN`. For `RETURN` type: immediately calls `ReceivingService.receiveGoods()` for each position (auto-receive), sets positions and advice to `FINISHED`. For `REGULAR` type: persists in `OPEN` state for manual warehouse receiving.

**Error conditions (400):** `ENTITY_ALREADY_EXITS` for duplicate `reference_id` or client not found; `ENTITY_DOES_NOT_EXISTS` for SKU, box type, unit load type not found; `NOT_ENABLLED_FOR_RECEIVING` if client not enabled.

---

#### `PUT /rest/advice/createTransfer`

| Field | Value |
|---|---|
| HTTP method | `PUT` |
| Path | `/rest/advice/createTransfer` |
| Auth | None |
| Request body | `BillOfLadingWebServiceDto` |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**Key DTO fields:** `transfer_id` (must be unique), one `PalletDto` in `positions`, which must contain exactly one `OrderDto`, which contains `OrderPositionDto[]`.

**What it does:** creates a `TRANSFER`-type `Advice` record and its `Adviceposition` rows in `OPEN` state. The WMS staff then physically receives the transfer goods against this advice. Completing receipt triggers `AdviceService.acceptTransferAdvice()` (see §2.3).

**Error conditions (400):** `ENTITY_ALREADY_EXITS` for duplicate `transfer_id`; `TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH` if >1 order in pallet; `ENTITY_DOES_NOT_EXISTS` for client not found.

---

#### `PUT /rest/advice/createHubAndSpoke`

| Field | Value |
|---|---|
| HTTP method | `PUT` |
| Path | `/rest/advice/createHubAndSpoke` |
| Auth | None |
| Request body | `BillOfLadingWebServiceDto` |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**Key DTO fields:** `transfer_id`, `destination_warehouse` (must match this WMS's `MULTIWAREHOUSE_IDENTIFIER`), `source_warehouse`, `bol_name`, `positions` (list of `PalletDto` each with `OrderDto[]` containing parcel info).

**What it does:** creates a `HUB_AND_SPOKE`-type `Advice` with one `Adviceposition` per parcel. Uses the system client. Completing the physical acceptance triggers `AdviceService.acceptHubAndSpokeAdvice()` (see §2.2).

**Error conditions (400):** `WRONG_FACILITY_CODE` if `destination_warehouse` doesn't match; `ENTITY_ALREADY_EXITS` for duplicate `transfer_id`; `ENTITY_DOES_NOT_EXISTS` for system client.

---

#### `POST /rest/advice/reopen`

Throws `RuntimeException("method not supported")` — **not implemented, do not call**.

---

### 1.3 `SkuRestController` — `/rest/sku`

#### `PUT /rest/sku/create`

| Field | Value |
|---|---|
| HTTP method | `PUT` |
| Path | `/rest/sku/create` |
| Auth | None |
| Request body | `List<SkuDto>` |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**Key DTO fields:** `facility_code`, `sku` (item number), `sku_name`, `client_id`, `unit_identifier_id` (optional — must exist in `itemunit.unitname`), `box_id` (optional — must exist in `boxtype.external_id`), `bottle_size`, `varietal`, `vintage`, `wine_type`, `image_filename`.

**What it does:** creates a new `Itemdata` row. Sets `putaway_location` to the `STORAGE_LOCATION_PUTAWAY_LANE` location. Fails if the SKU already exists for that client.

**Error conditions (400):** `ENTITY_ALREADY_EXITS` for duplicate SKU; `ENTITY_DOES_NOT_EXISTS` for client, unit type, or box type; `FIELD_NOT_SET` for a blank/whitespace-only SKU.

> **SKU normalization (SBDEV-2496, 2026-06-26).** Inbound SKU codes (`sku` / `item_nr`) are whitespace-normalized — trimmed via `SkuCodes.normalize`, blank→null — both when persisted (`Itemdata.setItemNr` trims) and at every ingress lookup (`SkuRestController` create/update/delete, `OrderRestController` order-line resolution, `AdviceRestController`, `FileImportController`). This prevents a trailing-space variant (`"PRSHW222 "` vs `"PRSHW222"`) from minting a duplicate `Itemdata` and stranding orders at "No fixed assigned location". Postgres `=`/`IN` are trailing-space sensitive, so normalization happens application-side; a one-time migration (`V1.26.31`) trimmed existing `item_nr` rows. Club-order SKU matching and the order-import per-order dedup also compare normalized values.

---

#### `POST /rest/sku/update`

| Field | Value |
|---|---|
| HTTP method | `POST` |
| Path | `/rest/sku/update` |
| Auth | None |
| Request body | `List<SkuDto>` |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**What it does:** updates existing `Itemdata` row (name, unit type, box type, wine attributes). If the SKU does not exist, delegates to `/rest/sku/create` (upsert behaviour).

---

#### `DELETE /rest/sku/delete`

| Field | Value |
|---|---|
| HTTP method | `DELETE` |
| Path | `/rest/sku/delete` |
| Auth | None |
| Request body | `List<SkuDto>` — only `facility_code`, `sku`, `client_id` used |
| Success response | `204 No Content` |
| Error response | `400 Bad Request` |

**What it does:** hard-deletes `Itemdata` row. **No stock-presence check is performed** (there is a `// TODO check that no item exists` comment). Deleting a SKU that has live stock will leave orphaned records.

**Note:** no `Message` audit row is written for the delete endpoint.

---

### 1.4 `StockCountRestController` — `/rest/stockcount`

#### `POST /rest/stockcount/getStockCount`

| Field | Value |
|---|---|
| HTTP method | `POST` |
| Path | `/rest/stockcount/getStockCount` |
| Auth | None |
| Request body | `StockCountDto` — `{ "facility_code": "...", "client_number": "...", "item_data_number": "..." }` |
| Success response | `200 OK` — `List<StockCountDto>` |
| Error response | `400 Bad Request` |

**What it does:** returns current stock counts from `WarehouseStockReportService.getStockCount(clientId, itemDataId)`. Both `client_number` and `item_data_number` are optional filters; `item_data_number` requires `client_number`.

**Note:** no `Message` audit row is written for this endpoint.

---

#### `GET /rest/stockcount/triggerStockCount`

| Field | Value |
|---|---|
| HTTP method | `GET` |
| Path | `/rest/stockcount/triggerStockCount` |
| Auth | None |
| Request body | none |
| Response | `void` (200) |

**What it does:** immediately triggers `StockSummaryExportJob.doCalculation(false)` synchronously (the `false` flag bypasses the cron-activation sysprop check). This fires the full `WEBSERVICE_STOCK_COUNT` outbound POST to OMS (see §2.9).

---

### 1.5 `TransactionReportRestController` — `/rest/report`

#### `POST /rest/report/getTransactionReport`

| Field | Value |
|---|---|
| HTTP method | `POST` |
| Path | `/rest/report/getTransactionReport` |
| Auth | None |
| Request body | `WarehouseTransactionReportRequest` — `{ "facility_code", "client_code", "start_date", "end_date" }` (dates: `yyyy-MM-dd HH:mm:ss`) |
| Success response | `200 OK` — `List<WarehouseTransactionReportResponse>` |
| Error response | `400 Bad Request` |

**What it does:** runs `ClientRepository.getTransactionSummary()` (native SQL) and returns summarised inventory movement per SKU for the period: beginning inventory, received, returned, putaway, adjustments, damaged, depleted-picked, depleted-club, shipped, ending inventory, net change.

---

#### `POST /rest/report/getTransactionDetailedReport`

| Field | Value |
|---|---|
| HTTP method | `POST` |
| Path | `/rest/report/getTransactionDetailedReport` |
| Auth | None |
| Request body | `WarehouseTransactionDetailedReportRequest` — adds optional `sku` filter to the above |
| Success response | `200 OK` — `List<WarehouseTransactionDetailedReportResponse>` |
| Error response | `400 Bad Request` |

**What it does:** runs `ClientRepository.getTransactionDetail()` (native SQL) returning one row per transaction event with location, transaction number, order number, package ID, user, and comment fields.

---

## §2 Outbound — WMS calls OMS

All outbound calls share these properties:

**HTTP client (`HttpRestService`):**
- Library: RESTEasy JAX-RS client
- Connect timeout: **5 seconds**
- Read timeout: **15 seconds**
- Auth: HTTP Basic — credentials from `LosSysprop` key `SYSTEM_PROPERTY_OMS_API_USER_KEY` (`user/password` split on first `/`). If missing, logs ERROR and proceeds without auth.
- Tenant header: `x-tenant: <value>` — from `SYSTEM_PROPERTY_OMS_TENANT_ID_KEY` if present.
- **No retry logic** — single attempt only.
- Non-200/201 responses are logged as WARN but do **not** throw; the call returns the status code in the response map.

**Failure handling:** all outbound calls catch `IOException` (network failure, serialization error), write a `Message` row with `status=FAILED` and `code=503`, then log `ERROR`. The exception is **not re-thrown** — the originating transaction is unaffected. OMS never knows the call failed.

**Deferred vs synchronous:**
- `deferToCommit` callers: the OMS POST fires in Spring's `afterCommit` hook — only if the DB transaction commits successfully. On rollback the OMS call is silently dropped. No retry, no persistence of intent.
- Synchronous callers (`ManageOrderService`): fire the OMS POST **within** the service method, before transaction commit. A network failure here throws (wrapping the `IOException`), which can cause the caller to fail or log an error depending on exception handling in the controller.

**Behaviour gate (`WEBSERVICE_BEHAVIOUR`):** `LosSysprop` key `WEBSERVICE_BEHAVIOUR` with values `send` / `discard` / `keep`. Default: `keep`. However, inspection of `HttpRestService` shows this sysprop is read by `MessageService` for routing decisions, not by `HttpRestService.post()` itself — the HTTP POST is always attempted regardless of this flag.

**URL configuration:** all URLs are stored as `LosSysprop` rows. The default values below are templates — the real value per environment is set in the DB.

---

### 2.1 Close Regular Advice (Receiving Complete)

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_CLOSE_ADVICE` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/closeAdvice` |
| HTTP method | `POST` |
| Trigger | `AdviceService.close(advice, principal)` |
| Condition | Called when WMS staff closes a `REGULAR`-type advice after all receiving is done. Advice must be in state `OPEN`; any other state throws `BusinessException`. |
| Deferred | Yes — `OmsNotificationHelper.deferToCommit("closeAdvice", ...)` |
| Payload class | `AdviceDto` |
| Payload shape | `{ "facility_code", "reference_id", "client_id", "positions": [{ "reference_id", "sku", "amount_of_boxes", "amount_of_bottles" }], "delivery_note_number", "comment", "transfer_id", "purchase_order_number", "day_of_delivery" }` |
| Message process type | `ADVICE_CLOSE` |
| On failure | Logs ERROR with message ID; `Message` row persisted with `status=FAILED`, `code=503`. No retry. OMS not notified of failure. |

---

### 2.2 Accept Hub-and-Spoke Advice

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/receiveHubAndSpoke` |
| HTTP method | `POST` |
| Trigger | `AdviceService.acceptHubAndSpokeAdvice(advice, location)` |
| Condition | Called when the WMS accepts the inbound hub-and-spoke pallet at a receiving location. Advice must be type `HUB_AND_SPOKE` and in state `OPEN`. |
| Deferred | Yes — `OmsNotificationHelper.deferToCommit("acceptHubAndSpokeAdvice", ...)` |
| Payload class | `HubAndSpokeAcceptDto` |
| Payload shape | `{ "facility_code", "positions": ["<external_order_id>", ...] }` — list of external order IDs accepted |
| Message process type | `ADVICE_HUB_AND_SPOKE_RECEIVED` |
| On failure | Logs ERROR with message ID; `Message` row with `FAILED`/`503`. No retry. |

---

### 2.3 Accept Transfer Advice

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ACCEPT_TRANSFER` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/closeTransfer` |
| HTTP method | `POST` |
| Trigger | `AdviceService.acceptTransferAdvice(advice, principal)` |
| Condition | Called when WMS staff accepts a `TRANSFER`-type advice after receiving the stock. Advice must be in state `OPEN` or `CREATED`. If `allow_short_delivery=false`, all notified quantities must be fully received. |
| Deferred | Yes — `OmsNotificationHelper.deferToCommit("acceptTransferAdvice", ...)` |
| Payload class | `AcceptTransferDto` |
| Payload shape | `{ "transfer_id": "..." }` |
| Message process type | `ADVICE_ACCEPT_TRANSFER` |
| On failure | Logs ERROR with message ID; `Message` row with `FAILED`/`503`. No retry. |

---

### 2.4 Order Batch On Hold

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ORDER_BATCH_HELD` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/held` |
| HTTP method | `POST` |
| Trigger | `ManageOrderService.customerOrderOnHold(customerOrderList)` |
| Condition | Called when the order release job determines that one or more orders in a batch cannot yet be assigned (stock or resource constraint). |
| Deferred | **No — synchronous** (fires within the service method, before transaction commit) |
| Payload class | `OrderBatchDto` |
| Payload shape | `OrderBatchDto` with orders, each carrying `reason_id` (state code) and `reason_text` |
| Message process type | `ORDER_BATCH_ON_HOLD` |
| On failure | Logs ERROR with message ID; `Message` row with `FAILED`/`503`. Exception caught and logged — caller does not propagate it. |

---

### 2.5 Order Batch Released for Picking

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/readytopick` |
| HTTP method | `POST` |
| Trigger | `ManageOrderService.customerOrderReleaseForPicking(customerOrderList)` |
| Condition | Called when the order release job successfully assigns a batch to picking. Already-cancelled orders are filtered out before the POST. |
| Deferred | **No — synchronous** |
| Payload class | `OrderBatchDto` |
| Payload shape | `OrderBatchDto` with batch metadata and order list |
| Message process type | `ORDER_BATCH_PICKING_RELEASED` |
| On failure | Logs ERROR with message ID; `Message` row with `FAILED`/`503`. |

---

### 2.6 Order Batch Picking Tote Assigned

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/assignedToteID` |
| HTTP method | `POST` |
| Trigger | `ManageOrderService.customerOrderToteAssigned(customerOrderList)` |
| Condition | Called when a picking tote is assigned to one or more orders. Orders are grouped by batch; each order's `tote_label` is included. Pick-pack orders (no tote assigned, `picking_tote_id=null`) send a null `tote_label`. |
| Deferred | **No — synchronous** |
| Payload class | `OrderBatchDto[]` (array — one entry per batch) |
| Payload shape | Array of `OrderBatchDto`, each order has `tote_label` |
| Message process type | `ORDER_BATCH_PICKING_TOTE_ASSIGNED` |
| On failure | Logs ERROR with message ID; `Message` row with `FAILED`/`503`. |

---

### 2.7 Order Batch Picking Started

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ORDER_BATCH_PICKING` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/picking` |
| HTTP method | `POST` |
| Trigger | `ManageOrderService.customerOrderPickingStarted(customerOrderList)` |
| Condition | Called when a picker begins picking an order batch. Cancelled orders are filtered out. |
| Deferred | **No — synchronous** |
| Payload class | `OrderBatchDto` |
| Payload shape | Standard `OrderBatchDto` with order list |
| Message process type | `ORDER_BATCH_PICKING_STARTED` |
| On failure | Logs ERROR with message ID; `Message` row with `FAILED`/`503`. |

---

### 2.8 Order Batch Finished Picking

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/finishedPicking` |
| HTTP method | `POST` |
| Trigger | `ManageOrderService.customerOrderPicked(customerOrderList)` |
| Condition | Called when picking is complete for all orders in a batch. For Club batches, `tote_label` carries the `historytote` UUID (assigned by `assignClubHistoryTotes()` within the same transaction). For pick-pack orders, carries the physical tote label. Cancelled orders are filtered out. |
| Deferred | **No — synchronous** |
| Payload class | `OrderBatchDto` |
| Payload shape | `OrderBatchDto` with orders, each carrying `tote_label` |
| Message process type | `ORDER_BATCH_PICKING_FINISHED` |
| On failure | Logs ERROR with message ID; `Message` row with `FAILED`/`503`. |

---

### 2.9 Order Batch Cancelled (WMS-initiated)

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ORDER_BATCH_CANCELLED` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/cancelPosition` |
| HTTP method | `POST` |
| Trigger | Two callers: (a) `CustomerorderBatchService.cancelBatch()` — whole-batch cancel; (b) `CustomerorderService.cancelOrder(order, cancellationFromWithinWMS=true)` — single-order cancel from within WMS |
| Condition | Only fires when cancellation originates **inside WMS** (e.g., stock adjustment, picking failure, manual cancel). Does **not** fire for OMS-initiated cancels via `/rest/order/cancelPositions` (that path uses `cancellationFromWithinWMS=false`). The `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` sysprop (`default: false`) is defined but **not checked** in the current code — the callback fires unconditionally. |
| Deferred | Yes — `OmsNotificationHelper.deferToCommit(...)` |
| Payload class | `OrderBatchDto` |
| Payload shape | `{ "facility_code", "batch_id", "positions": [{ "unique_id", "positions": [{ "unique_id", "sku_id", "amount", "number" }] }] }` |
| Message process type | `ORDER_BATCH_CANCELLED_FROM_WMS` |
| On failure | Logs ERROR with message ID; `Message` row with `FAILED`/`503`. No retry. |

---

### 2.10 Order Batch Shipped

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_ORDER_BATCH_SHIPPED` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/finishedShipping` |
| HTTP method | `POST` |
| Trigger | `BillofladingService.closeBOL(...)` — the BOL close operation (Phase 8 of the `closeBOL` pipeline) |
| Condition | Called once per BOL close, after all pallet trees are transferred to the `SHIPPED` location (Phase 4) and stock is locked with `BusinessObjectLockState.SHIPPED`. Fires post-commit to ensure WMS DB state is durable before OMS is notified. |
| Deferred | Yes — `OmsNotificationHelper.deferToCommit("closeBOL", ...)` using `createMessageInNewTransaction` (REQUIRES_NEW) for audit-row durability |
| Payload class | `BillOfLadingWebServiceDto` |
| Payload shape | `{ "transfer_id", "bol_name", "truck_id", "carrier_id", "source_warehouse", "destination_warehouse", "positions": [PalletDto[]] }` |
| Message process type | `ORDER_BATCH_SHIPPED` |
| On failure | Logs ERROR `"OMS ORDER_BATCH_SHIPPED POST failed for BOL <id>"`; persists `FAILED`/`503` audit row in new TX. No retry. |

---

### 2.11 Stock Count Export (Scheduled)

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_STOCK_COUNT` |
| Default URL | `https://oms-XXXXX.siteboss.net/call/inventory/stockCountExport` |
| HTTP method | `POST` |
| Trigger | `StockSummaryExportJob.doCalculation(isCronJob)` |
| Condition | Runs on cron schedule (when `SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY=true` and `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED_KEY=true`). Can also be triggered manually via `GET /rest/stockcount/triggerStockCount` (bypasses activation check). Optionally splits large payloads into chunks controlled by `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED_KEY` and `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH_KEY`. |
| Deferred | **No — synchronous** (direct call within job thread) |
| Payload class | `List<StockCountDto>` |
| Payload shape | `[{ "client_number", "item_data_number", "total", "damage", "missing", "on_hold", "transfer", "facility_code" }]` |
| Message process type | `INVENTORY_FULL_EXPORT` |
| On failure | Logs ERROR; `Message` row with `FAILED`/`503`. Continues to next chunk if split mode. No retry. |

---

### 2.12 Facility List Lookup (Not yet in production use)

| Field | Value |
|---|---|
| Sysprop key | `WEBSERVICE_FACILITY_LIST_LOOKUP` |
| Default URL | `https://oms-XXXXX.siteboss.net/services/call/facilities` |
| HTTP method | `GET` |
| Trigger | `BillofladingService` — line 1191 (`httpRestService.get(urlPath)`) |
| Condition | Called during BOL creation to look up valid destination facilities. Only visible in commented-out code in the shipped section (`BillofladingService.java:810-831`); the live call at line 1191 is in the hub-and-spoke BOL creation path. |
| Deferred | No — synchronous |
| Payload | None (GET request) |
| Message process type | N/A (no audit row observed) |

---

## §3 Integration Failure Modes

### 3.1 Missing or wrong `WEBSERVICE_*` sysprop URL

**Symptom:** `NullPointerException` inside `httpRestService.post(null, ...)` → logged as network error; `Message` row shows `503 FAILED` with no URL.

**Diagnosis:** `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey LIKE 'WEBSERVICE_%'` — check for null or placeholder (`XXXXX`) values.

**Fix:** update the row to the correct OMS URL for the environment.

---

### 3.2 OMS returns non-200 (4xx/5xx)

**Symptom:** `Message` row shows `status=SENT` but `status_code=4xx/5xx` and `answer` contains OMS error body. WMS treats this as a successful send. No exception is thrown, no retry, no alert.

**Diagnosis:** `SELECT * FROM message WHERE status_code NOT IN ('200','201') AND process_type = '<type>' ORDER BY created_at DESC LIMIT 20`.

**Fix:** resolve the OMS-side issue. The WMS call can be manually re-triggered (for stock counts: `GET /rest/stockcount/triggerStockCount`; for others: re-run the WMS business action).

---

### 3.3 Callback silently dropped due to transaction rollback

**Symptom:** WMS action appears to succeed (no error logged by caller) but OMS never receives the callback. Can happen for any `deferToCommit` callback when the DB transaction rolls back after the business logic runs (e.g., optimistic lock failure, constraint violation in a later phase).

**Diagnosis:** check `Message` table — absence of any row for the expected `process_type` + entity confirms the callback was never attempted (the deferred registration was dropped with the rollback). Cross-check with exception logs around the same timestamp.

**Fix:** re-run the business action if idempotent; or manually POST the OMS endpoint if a one-time fix is needed.

---

### 3.4 OMS-initiated cancel not triggering WMS→OMS cancel callback

**Symptom:** OMS cancels orders via `/rest/order/cancelPositions` but expects to receive a `WEBSERVICE_ORDER_BATCH_CANCELLED` callback — it never arrives.

**Root cause:** by design. `cancelOrder(order, false)` (OMS-initiated path) skips the `deferToCommit` block that fires the cancel callback. Only `cancellationFromWithinWMS=true` triggers it.

**Diagnosis:** confirm which path triggered the cancel by checking `message.process_type=ORDER_BATCH_CANCELLED_FROM_PSD` (inbound from OMS) vs `ORDER_BATCH_CANCELLED_FROM_WMS` (outbound from WMS).

---

### 3.5 `WEBSERVICE_BEHAVIOUR=keep` misunderstood as "suppress callbacks"

**Symptom:** developer sets `WEBSERVICE_BEHAVIOUR=keep` thinking it disables outbound calls. Callbacks still fire.

**Root cause:** `HttpRestService.post()` does not read this sysprop. The flag is consumed by `MessageService` for message routing/retention, not for HTTP dispatch.

**Fix:** there is no runtime switch to disable outbound callbacks short of setting bad URLs or removing the OMS host from network routing.

---

### 3.6 `HttpRestService` credential missing

**Symptom:** OMS rejects all callbacks with 401. WMS logs `ERROR: OMS api user info not found in the db` but continues with an unauthenticated request.

**Diagnosis:** `SELECT sysvalue FROM los_sysprop WHERE syskey = 'OMS_API_USER'` — should be `user/password`.

**Fix:** insert/update the sysprop row.

---

### 3.7 Stock count split causing partial delivery

**Symptom:** OMS receives only some SKUs in the stock count export and builds an incorrect inventory view.

**Root cause:** `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED_KEY=true` splits the payload into chunks. If any chunk fails (network), only that chunk gets a `FAILED` message row — the others succeed. OMS has no transaction concept across chunks.

**Diagnosis:** `SELECT COUNT(*), status_code FROM message WHERE process_type='INVENTORY_FULL_EXPORT' AND DATE(created_at)=CURRENT_DATE GROUP BY status_code`.

**Fix:** either disable split mode or resolve the network issue and re-trigger the full export manually.

---

### 3.8 `finishedQA` discards Club/Transfer batches silently

**Symptom:** OMS sends `finishedQA` for a Club or Transfer batch. WMS returns `204` but does nothing. Orders remain in `PICKED` state indefinitely.

**Root cause:** `OrderRestController.finishedQA` explicitly skips `CLUB` and `TRANSFER_*` batch types with a `LOG.warn` + `continue`. This is intentional — Club orders proceed through a different path (`runClubLine`); transfer acknowledgment goes through `finishedTransfer`.

**Diagnosis:** check `message` table for `process_type=ORDER_BATCH_QA_FINISHED` with `status=RECEIVED` — then check the batch type in `customerorder_batch`.

---

## Appendix: Sysprop Key Reference

| Constant name | Sysprop key | Default URL / value |
|---|---|---|
| `SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY` | `WEBSERVICE_CLOSE_ADVICE` | `.../services/call/closeAdvice` |
| `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY` | `WEBSERVICE_ACCEPT_TRANSFER` | `.../services/call/closeTransfer` |
| `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL_KEY` | `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `.../services/call/receiveHubAndSpoke` |
| `SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY` | `WEBSERVICE_STOCK_COUNT` | `.../call/inventory/stockCountExport` |
| `SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY` | `WEBSERVICE_STOCK_UPDATE` | `.../call/inventory/stockUpdate` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING_URL_KEY` | `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `.../services/call/readytopick` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED_URL_KEY` | `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `.../services/call/assignedToteID` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_PICKING_URL_KEY` | `WEBSERVICE_ORDER_BATCH_PICKING` | `.../services/call/picking` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_FINISHED_PICKING_URL_KEY` | `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `.../services/call/finishedPicking` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_HELD_URL_KEY` | `WEBSERVICE_ORDER_BATCH_HELD` | `.../services/call/held` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY` | `WEBSERVICE_ORDER_BATCH_SHIPPED` | `.../services/call/finishedShipping` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` | `WEBSERVICE_ORDER_BATCH_CANCELLED` | `.../services/call/cancelPosition` |
| `SYSTEM_PROPERTY_WEBSERVICE_FACILITY_LIST_LOOKUP_URL_KEY` | `WEBSERVICE_FACILITY_LIST_LOOKUP` | `.../services/call/facilities` |
| `SYSTEM_PROPERTY_WEBSERVICE_BEHAVIOUR_KEY` | `WEBSERVICE_BEHAVIOUR` | `keep` |
| `SYSTEM_PROPERTY_OMS_API_USER_KEY` | `OMS_API_USER` | `<user>/<password>` |
| `SYSTEM_PROPERTY_OMS_TENANT_ID_KEY` | (OMS_TENANT_ID) | optional `x-tenant` header value |

All host portions shown as `oms-XXXXX.siteboss.net` — replace with the actual OMS hostname for each environment.
