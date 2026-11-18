---
title: WMS v2 REST API Reference — net.aim_ai.wms.controller.rest
last_verified: 2026-11-11
next_due: 2027-01-10
tags: [api, rest, oms-integration, wms2]
---

# WMS v2 REST API Reference

> **Audience:** OMS developers, integration engineers, QA, and support staff.
> **Base URL:** `https://<host>:<port>` (dev: `:8088`, prod: `:8080`)
> **Swagger UI:** `/swagger-ui/index.html`

---

## 1. Common Concepts

### 1.1 Authentication

**`/rest/**` is `permitAll()`: no JWT is required, and none of its endpoints carries `@RequiresFunction` or `@PreAuthorize`.** `SecurityConfiguration` rule B lists `"/rest/**"` with the public paths, ahead of rule E (`anyRequest().authenticated()`), so this surface is internal WMS↔OMS traffic that relies on network placement, not on a token. A tenant database is still selected from the headers in §1.2. The only `/rest` code path that looks at authentication is `IdempotencyFilter`, which answers `401` to an unauthenticated write only when `app.idempotency.require-auth` is `true`. The code default is `true` (`SecurityConfiguration:64-65`), but **`application.properties:322` ships `false`** ("trusted-network mode", because OMS does not send a JWT), so in the shipped config an unauthenticated `/rest` write is processed, not rejected (corrected after independent review 2026-11-11; agrees with `wms2-end-to-end-request-journey.md` and `wms2-rest-idempotency-design.md`). Treat the two as separate facts: `/rest/**` authorization is open, and a JWT on a write is demanded by the idempotency filter alone. By contrast every `/v3/**` endpoint needs the `wms_user` authority plus its own function gate (`@RequiresFunction`) — see §10. (`SecurityConfiguration.java:146-190` at `df30fa62`.)

### 1.2 Multi-Tenancy Headers

Every request **must** include:

| Header | Example | Description |
|---|---|---|
| `X-Tenant-ID` | `acme` | Tenant name (NOT `tenant_name`; that spelling appears only as a `@RequestHeader` on `TenantHealthController` and does not route) |
| `facility_code` | `develop` | Warehouse/facility code |

`TenantFilter` lower-cases both and builds the routing key `first4(tenantName) + "-" + facilityCode` (`TenantKeyBuilder.buildKey`, e.g. `loca-develop`; a tenant name under 4 chars is used whole). **A missing header does not reject the request:** `TenantFilter` sets the tenant context to `null` and the request proceeds against the default/landlord datasource (`TenantFilter.java:23-24,40-49`). On `/rest/**` that surfaces as a wrong-database error or an empty result, not a clean 4xx; `GET /rest/stockcount/triggerStockCount` exports nothing (§5.2). Always send both headers.

### 1.3 Facility Code Validation (`facility_code` in body)

Every write DTO that extends `AbstractWebServiceDto` **also** carries a `facility_code` field in the JSON body. The controller validates this body field matches the system-configured warehouse identifier (`MULTIWAREHOUSE_IDENTIFIER` sysprop). Mismatch → `400 Bad Request`.

### 1.4 Idempotency

Non-GET `/rest/**` endpoints are protected by `IdempotencyFilter` (SBDEV-2222), **except** the paths the filter skips: `GET` requests, `/rest/stockcount/**` (so `POST /rest/stockcount/getStockCount`, a read, and its test-dummy sibling), and the two report reads under `/rest/report/**` (`IdempotencyFilter.shouldNotFilter`). ✓ merged(SBDEV-4114: #662 494d2216, 2026-11-11) Until SBDEV-4114 the skip prefix was `/rest/transactionreport/`, which matches nothing, so on develop `df30fa62` both report POSTs are still enrolled and an identical report query replays the cached 200 body for up to the 7-day retention window (latent: no `/rest/report` rows on either PRD tenant, 2026-11-11).
The key is auto-derived as `SHA-256(method|path|rawBody)` — no header is required.  
An explicit `Idempotency-Key: <value>` header (max 64 chars, `[A-Za-z0-9_-]`) overrides the auto-key for back-compat.

| Scenario | Behaviour |
|---|---|
| First request | Processed normally; response cached |
| Repeat (same key + same body hash) | Cached 2xx response replayed immediately |
| Same key, different body hash | `409 Conflict` |
| Body > 5 MB (`app.idempotency.max-body-bytes`, default 5242880) | Idempotency bypassed (DoS guard) |
| 2xx that reports a business failure (`/rest/order/cancelPositions` partial batch with top-level `"status":"failure"`; SBDEV-3729) | Not cached, so a retry runs the handler again. Non-2xx is never cached |
| `app.idempotency.enforce=false` | Filter inactive (dev only; `application.properties:271` sets `true`) |

### 1.5 Standard Error Response

Every controller catches `WebserviceBusinessExceptionClientSide` and returns:

```json
HTTP 400 Bad Request

{
  "status": "failure",
  "description": "<human-readable error message>"
}
```

The `description` is built from `WmsConstants` error code templates with contextual parameters (entity names, field names, supplied values). The body is `WebserviceBusinessExceptionClientSide.getErrorMap()` (exactly `status` + `description`). **Two exceptions to the 400 rule:** the SKU endpoints answer `422` (§4), and `updateShipper`/`cancelPositions` can answer `200` with a structured body (§3.3, §3.6).

**Anything that is not a `WebserviceBusinessExceptionClientSide` is NOT in this shape.** It escapes the handler (after the FAILED service-log row, §1.7) to the `@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")` chain: `RestEndpointExceptionHandler` (highest precedence) maps transient DB failures (`DataAccessResourceFailureException`, `CannotAcquireLockException`, `DeadlockLoserDataAccessException`, `RecoverableDataAccessException`, `QueryTimeoutException`) to `503`, and `RestEndpointFallbackExceptionHandler` (lowest) answers `HttpMessageNotReadableException`/`TypeMismatchException` (an empty or malformed body: `400 "Malformed request"`) and `FacadeException`, `ConversionNotSupportedException` and any other `Exception` (`500`) as a Spring `ProblemDetail` (`application/problem+json`); `AccessDeniedException` is deliberately rethrown (unreachable today, since `/rest/**` is `permitAll`). The global `RestExceptionHandler` additionally answers WMS's `EntityNotFoundException` as `404` and `BusinessException` as `422`, also as `ProblemDetail`. Clients must therefore branch on status code first and parse `{status, description}` only for `400`/`422` from the handlers above.

A request object in the description is named by its identifier, never dumped: `order <unique_id>`, `order batch <batch_id>`, `order position <unique_id> (sku <sku_id>)`, `advice <reference_id>`, `advice position <reference_id> (sku <sku>)`, `sku <sku>`, `pallet <pallet_label>`, `transfer <transfer_id>`, `stock count request (client <client_number>)`; a missing identifier reads `(no id)`. Since SBDEV-3983 an identifier's control characters are masked as `?`, and anything past 255 characters is cut and ends in `…`. 255 is the width of the identifier columns, so a legal identifier renders unchanged ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02). Any other argument that is not a plain value (string, number, boolean, enum, date) is named by its type only. Before, the whole request's `toString()` was dumped, an order's recipient included, and since SBDEV-3102 E3 also persisted in `message.answer`. WRONG_STATE keeps `action not allowed. position is in different state <State> for …`, whose `different state <State>` span OMS parses (`WmsApiService::isAlreadyPastQa`). `WmsConstants.getErrorCodeText` applies this to every template; `RejectionTextIdentifierContractTest` grades every `net.aim_ai.wms.json` type. ✓ merged(SBDEV-3887: #565 063eb2ed, 2026-10-25)

### 1.6 Standard Success Response (write endpoints)

```json
HTTP 204 No Content

{
  "status": "success"
}
```

Read/report endpoints return `HTTP 200 OK` with a JSON body.

### 1.7 Message / Audit Log

The OMS→WMS import, update and report endpoints record a `Message` row (table `message`) via `MessageService.createMessage(...)`: RECEIVED on success, FAILED on a rejection (`WebserviceBusinessExceptionClientSide`). This log is queryable from the WMS Web UI and is the primary audit trail for OMS→WMS interactions. ✓ merged(SBDEV-3102: #560 4960631d, 2026-10-22)

Which handlers write a row (SBDEV-3102 E4, derived from the handlers at `b399ae5d` + E4):

- **Write RECEIVED + FAILED:** advice create / createTransfer / createHubAndSpoke; order create / updatePriority / cancelPositions / finishedQA / updateShipper / finishedTransfer; sku create / update / **delete** (`SKU_DELETE`, new in E4); **stockcount getStockCount** (`REPORT_STOCK_COUNT`, new in E4); both transaction reports. Before E4, sku delete and getStockCount wrote no row on any path.
- **Write no row:** `GET /rest/unitload/state/{labelId}` and `GET /rest/printer/findByType` (lookups called from the QA station; see the E4 report for why no row was added), `GET /rest/stockcount/triggerStockCount` (the export it runs writes its own `INVENTORY_FULL_EXPORT` rows), `POST /rest/stockcount/sendDummyMessageStockCountList` (test-only dummy, served by `MessageDummyController`, §10), `POST /rest/advice/reopen` (not implemented).
- **An exception that escapes a handler writes a FAILED row and is rethrown unchanged**, so the `/rest` advice chain answers it exactly as before (SBDEV-3887). This covers every row-writing handler above: a runtime exception in all 15 (one `logEscapedFailure` call each: advice 3, order 6, sku 3, getStockCount 1, reports 2; `grep -c` per controller at `df30fa62`), and a `BusinessException` in the six whose body can throw one (advice create / createTransfer / createHubAndSpoke, order create, sku create / update). The row's `answer` is `{"exception":"<class name>"}` and never the exception's message, since a translated JDBC failure quotes the SQL and `Key (col)=(value)`. The exception is WMS's own `EntityNotFoundException`, which adds `"message"` (a WMS-written not-found text, already the 404 body). Its status code is `404` for that exception, `422` for `BusinessException`, and empty otherwise (the advices pick 503 or 500 by type). sku delete adds `"deleted"`, and cancelPositions adds `"errors"` for orders already refused. **No row** is written when the failure is the connection pool's timeout (a Hikari `SQLTransientConnectionException` anywhere in the cause chain, however Spring wrapped it): the row would wait out the pool timeout again before the caller's 5xx. The handler's extra (e.g. the SKUs already deleted) is logged at WARN instead. Any other failure, a transaction-begin failure or a connection broken mid-statement included, still gets its row. Shared helper: `AbstractRestController.logEscapedFailure`. Before SBDEV-3887 only `finishedTransfer` recorded an escaping failure (SBDEV-3728). ✓ merged(SBDEV-3887: #565 063eb2ed, 2026-10-25)
- **sku delete is not atomic** (no `@Transactional`; each SKU's delete commits on its own). Its rows therefore carry which SKUs were actually deleted, as `"deleted":[{"client_id":..,"sku":..},..]` in `answer`: the RECEIVED/204 row's answer is `{"deleted":[..]}` (every SKU in the request), and a FAILED/400 row for a rejection part-way through the batch is the rejection shape plus `"deleted"` listing the SKUs before it. A rejection before any delete has no `"deleted"` key, so its row is the plain v1 shape. The 400 response itself does not say which SKUs were deleted (§4.3). ✓ merged(SBDEV-3102: #560 4960631d, 2026-10-22)
- **A failure writing the row never changes the response**, on the success path as well as the rejection path: each of the 28 `messageService.createMessage` calls a `/rest` controller makes itself (advice, order, sku, stockcount, transaction report) sits in its own `try` with `catch (Exception)` at ERROR. Service-layer writes a handler reaches indirectly, e.g. `OmsNotificationService.sendAfterCommit` (catches only `BusinessException`), are outside this guarantee. Before E4 the success-path (RECEIVED) writes of advice create / createTransfer / createHubAndSpoke, order create / updatePriority / finishedQA, sku create / update and both reports caught only `IOException`, so a logging failure answered a 422 ProblemDetail or a 5xx instead of the success. For the writes this came after the change had committed, and `WmsApiService::makeWmsRequest` does not retry a 4xx or 5xx, so the OMS caller got a failure for a committed change. At order create, on OMS's default record-first path, the scheduled `batch-send-pending` sweep then read the batch back from the WMS and settled it. At `finishedQA` OMS does re-send: `ProcessQaWorkflowJob` or `QaWorkflowService` queues `ProcessWmsNotificationJob` (5 tries), each re-send is rejected WRONG_STATE as already past PICKED (e.g. "different state Packed"), a state OMS's `isAlreadyPastQa` does not treat as done, so the committed packing ended as a failed job. For the two reports (reads) it replaced the 200 report. ✓ merged(SBDEV-3102: #560 4960631d, 2026-10-22)

A rejected call's FAILED row carries the rejection in `answer` as `{"code":..,"errorCodeName":..,"description":..}` — the shape v1 stored, and the same `description` the caller received (SBDEV-3102 E3; before it the answer was null on every `/rest` rejection except `finishedTransfer`'s). Covers advice create / createTransfer / createHubAndSpoke, order create / updatePriority / cancelPositions / finishedQA / updateShipper, sku create / update and both transaction reports. A partial `cancelPositions` batch (HTTP 200, FAILED/400 row) carries instead the body it answered, `{"status":"failure","message":..,"errors":{..}}`. A failure writing any of these rows is logged and never changes the response. The `/rest/order/create` "already exists" rejections name the identifier, not a DTO dump: `entity orderBatch|order|orderPosition|parcel_external_number already exists for <id>`; likewise `duplicate value parcel_external_number found in <parcel number>`. ✓ merged(SBDEV-3102: #556 b399ae5d, 2026-10-22)

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
| `type` | String | ✅ | `REGULAR` or `RETURN` (case-sensitive; compared with `AdviceType` constants). `TRANSFER` and anything else → `400 FIELD_MALFORMED_FORMAT` |
| `day_of_delivery` | String | — | ISO date `yyyy-MM-dd` |
| `day_of_delivery_until` | String | — | ISO date `yyyy-MM-dd` |
| `delivery_note_number` | String | — | Supplier delivery note reference |
| `comment` | String | — | Free-text comment |
| `supplier` | String | — | Supplier name |
| `purchase_order_number` | String | — | PO reference |
| `printer_id` | Long | — | Label printer for inbound labels. Read only by the RETURN auto-receive path (`ReturnAdviceAutoReceiveService.resolvePrinter`) |
| `shipment_id`, `transfer_id` | String | — | Declared on `AdviceDto` but not read by `create` ⚠ unverified 2026-11-11: no `getShipmentId`/`getTransferId` caller found in `AdviceRestController` or `ReturnAdviceAutoReceiveService`; a downstream reader was not searched |
| `positions` | List\<AdvicePositionDto\> | — | Line items (see below). `null` is treated as an empty list |

**`AdvicePositionDto`** (one per SKU line):

| Field | Type | Required | Description |
|---|---|---|---|
| `reference_id` | String | ✅ | External unique ID for this position |
| `client_id` | String | ✅ | Client number for this position |
| `sku` | String | ✅ | SKU / item number; must exist in WMS for the client |
| `box_id` | String | ✅ | Box type external ID |
| `amount_of_boxes` | Integer | ✅ | Number of cases/boxes expected (≥ 0) |
| `amount_of_bottles` | Integer | ✅ | Number of undamaged units expected (≥ 0; missing → `FIELD_NOT_SET`) |
| `amount_of_bottles_damaged` | Integer | — | SBDEV-1512. Damaged units, in addition to `amount_of_bottles`; `null` means 0; negative → `400 FIELD_MALFORMED_FORMAT`. Written to `adviceposition.notifieddamagedamount` |

#### Business Rules

- `reference_id` must be unique across all existing advices (read-then-write check, backed by the UNIQUE index on `advice.externalid`: a concurrent loser also gets `ENTITY_ALREADY_EXITS`, not a 500).
- `client_id` must exist as a `Client` (`cl_nr`).
- For `RETURN` type: the client must have `enable_receiving = true`.
- `type` must be exactly `REGULAR` or `RETURN`; any other value → `400`.
- **RETURN auto-receive (SBDEV-2778).** A `RETURN` advice with at least one position is received and closed inside this call, unless sysprop `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` is the string `false` (default ON; kill switch). With the switch off, or for a RETURN with no positions, the advice stays `OPEN` and is received at the dock via `POST /v3/receiving/receive`. REGULAR advices are never auto-received. Guards: more than 100 RETURN advices in one request → `400 FIELD_MALFORMED_FORMAT` (`adviceList`); while auto-receive is on, any request holding a RETURN advice **and** more than one advice → `400 FIELD_MALFORMED_FORMAT` (an auto-receiving RETURN must arrive alone) (`AdviceRestController:169` and `:211`, `MAX_RETURN_ADVICES_PER_REQUEST`).
- SKU must exist for the resolved `client_id`.
- Duplicate `sku` within the same advice position list is rejected.
- Created advice state: `OPEN` (a successfully auto-received RETURN is then advanced to finished by the auto-receive service). Short/over delivery defaults: both allowed.
- A `TRANSFER` type value in this endpoint is rejected (`FIELD_MALFORMED_FORMAT`; TRANSFER advices use `/createTransfer`).

#### Success Response

```
HTTP 204 No Content
{ "status": "success" }
```

**Warning envelope (RETURN auto-receive only).** When the advice was created but the auto-receive did not fully complete (outcome `PARTIAL`, `SKIPPED` or `DAMAGE_FAILED`), the status is **`200 OK`**, not 204, and the body is `{"status":"success","warning":{"code","reason","correlation_id","advice","sku","received","total","description"}}`. `code` is the error-code name `RETURN_AUTO_RECEIVE_PARTIAL`, `RETURN_AUTO_RECEIVE_ABORTED` (nothing received) or `RETURN_AUTO_RECEIVE_DAMAGE_FAILED` (all stock received, damage step failed: do **not** re-receive at the dock). `reason` is a `FailureReason` name: `PRINTER_UNREACHABLE`, `ZPL_TEMPLATE_MISSING`, `CONFIG_MISSING`, `SKIPPED_NO_POSITIONS`, `DAMAGE_APPLY_FAILED`, `UNKNOWN`. The service-log row carries the same status. A 2xx `status:"success"` caller must therefore check for a `warning` key (`AdviceRestController:606,636`, `ReturnAdviceAutoReceiveService.AutoReceiveOutcome`).

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| `facility_code` missing or wrong | 400 | `FIELD_NOT_SET` / `WRONG_FACILITY_CODE` |
| `reference_id` missing | 400 | `FIELD_NOT_SET` |
| `type` missing | 400 | `FIELD_NOT_SET` |
| `client_id` missing | 400 | `FIELD_NOT_SET` |
| Advice with same `reference_id` exists | 400 | `ENTITY_ALREADY_EXITS` |
| Client not found | 400 | `ENTITY_DOES_NOT_EXISTS` (was `ENTITY_ALREADY_EXITS` in an earlier revision of this page; `AdviceRestController:262`) |
| Client not enabled for receiving (RETURN) | 400 | `NOT_ENABLLED_FOR_RECEIVING` |
| `day_of_delivery` not parseable as ISO date | 400 | `FIELD_MALFORMED_FORMAT` |
| `amount_of_bottles` missing | 400 | `FIELD_NOT_SET` |
| `amount_of_bottles` < 0 | 400 | `FIELD_MALFORMED_FORMAT` |
| `amount_of_bottles_damaged` < 0 | 400 | `FIELD_MALFORMED_FORMAT` |
| position `sku` missing / position `client_id` unknown | 400 | `FIELD_NOT_SET` / `ENTITY_DOES_NOT_EXISTS` |
| SKU not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| `box_id` not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| `box_id` missing or empty on a position | 400 | `FIELD_NOT_SET` (was an NPE → 500 before SBDEV-3983) ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02) |
| `amount_of_boxes` missing on a position | 400 | `FIELD_NOT_SET` (was an NPE → 500 before SBDEV-3983) ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02) |
| `amount_of_boxes` < 0 | 400 | `FIELD_MALFORMED_FORMAT` (was accepted and written) ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02) |
| position `reference_id` longer than 255 characters, or containing a NUL | 400 | `FIELD_MALFORMED_FORMAT` (was a 500 at the position insert, after the advice committed). Checked last, so another fault on the same position wins ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02) |
| advice `reference_id` longer than 255 characters, or containing a NUL | 400 | `FIELD_MALFORMED_FORMAT` (was a 500 at the advice insert) ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02) |
| `null` element inside `positions` | 400 | `FIELD_NOT_SET` for `positions[<i>]`, before RETURN auto-receive validation too (was an NPE → 500) ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02) |
| `null` advice inside the list | 400 | `PARAMETER_IS_NULL` (was an NPE → 500) ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02) |
| Null body | 400 | `PARAMETER_IS_NULL` |
| Empty list | 400 | `NO_POSITION` |
| Batch guards for RETURN auto-receive (see Business Rules) | 400 | `FIELD_MALFORMED_FORMAT` |
| Auto-receive validation (printer, ZPL template, putaway destination, damaged location) | 400 | per `ReturnAdviceAutoReceiveService.validate`; raised before the advice is saved ⚠ unverified 2026-11-11: individual error codes of that service were not enumerated |

**A rejected advice persists nothing** ✓ merged(SBDEV-3983: #598 53bf025b, 2026-11-02). `create()` is not `@Transactional`, so the advice row commits as soon as it is saved. Until SBDEV-3983, every **position** rule ran after that save: a rejected position left an OPEN advice holding the `reference_id`, and every retry was then refused with `ENTITY_ALREADY_EXITS`. Every position is now validated and resolved before the save. The exception is a request with several advices: advices before the rejected one are already committed (pre-existing, out of scope). `positions: null` is treated as an empty list (an OPEN advice with no positions, 204); before, it threw an NPE after the save.

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

Position box type is the SKU's `defaultboxtype` (`itemdata.getDefaultboxtypeId()`), not the system default; no `facility_code` check is made (`BillOfLadingWebServiceDto` is not validated through `validateWarehouse`). Source: `AdviceRestController:694-820`.

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

### 2.4 `POST /rest/advice/reopen` ⚠️ NOT IMPLEMENTED — removed by SBDEV-4115 (route becomes 404) ✓ merged(SBDEV-4115: #664 938c9fe2, 2026-11-11)

This endpoint exists in the code (`@RequestMapping(value = "/reopen", method = POST)`, `AdviceRestController:991`) but throws `RuntimeException("method not supported")`, which the `/rest` advice chain answers as a `500` ProblemDetail. It writes no service-log row.  
**Do not call this endpoint.**

---

## 3. OrderRestController — `/rest/order`

> Manages customer order batches throughout their lifecycle: creation → priority → cancel → QA → ship-method change → transfer completion. Six endpoints (`create`, `updatePriority`, `cancelPositions`, `finishedQA`, `updateShipper`, `finishedTransfer`).

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
| `priority` | Integer | ✅ | 1 (Immediate) – 5 (Low); mapping in §8.4 |
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
- `priority` must be 1–5; mapped by `WmsConstants.Priority.fromOmsLevel` (§8.4).
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
| `batch_id` missing | 400 | `FIELD_NOT_SET` |
| `batch_id` not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| `priority` missing | 400 | `FIELD_NOT_SET` |
| `priority` out of range | 400 | `FIELD_MALFORMED_FORMAT` |
| Null body | 400 | `PARAMETER_IS_NULL` |

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
- Not all-or-nothing. Each order cancels in its own transaction. A refusal (unknown batch or order, non-cancellable state, unexpected error) aborts the request with a 400 before or at that order. A **contained** failure on one order does not: a tote-teardown failure (SBDEV-3339) or a lost concurrent race (SBDEV-3729) leaves that order uncancelled, cancels the rest, and the batch answers the partial 200 below. Re-sending the batch no-ops the orders already cancelled and retries only the failed ones. ✓ merged(SBDEV-3102: #556 b399ae5d, 2026-10-22)

#### Success Responses

```
HTTP 200 OK
{ "status": "success" }
```

Partial batch: some orders were NOT cancelled. The status is still 200, because OMS reads a non-2xx as a refusal. The `status` token must be exactly `"failure"`, because that is what `WmsApiService::isFailureResponse` tests.

```
HTTP 200 OK
{ "status": "failure",
  "message": "<n> order(s) named in 'errors' were NOT cancelled; re-sending the batch retries only them",
  "errors": { "<unique_id>": "<reason>" } }
```

The service-log row for a partial batch is FAILED/400, and its `answer` is this body (§1.7, SBDEV-3102 E3). A failure writing that row never changes this response. ✓ merged(SBDEV-3102: #556 b399ae5d, 2026-10-22)

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| Batch not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Order not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| `unique_id` missing / `positions` missing | 400 | `FIELD_NOT_SET` / `NO_POSITION` when empty |
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
| Parcel label already used | 400 | `ENTITY_ALREADY_EXITS` — `entity parcel_external_number already exists for <label>` (SBDEV-3102 E3; was `entity <label> already exists for <OrderBatchDto dump>`) ✓ merged(SBDEV-3102: #556 b399ae5d, 2026-10-22) |
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
| `facility_code` | String | — | Inherited from `AbstractWebServiceDto`; **not validated** here (`finishedTransfer` never calls `validateWarehouse`, unlike the other five order endpoints) |
| `transfer_id` | String | ✅ | The transfer to finalise |

#### Business Rules

- Delegates to `BillofladingService.finishTransfer(transferId)`.
- Closes the `TRANSFER_INTRACOMPANY` BOL and ships its pallets. It does not touch any advice (an earlier revision of this page said it did). A BOL below `TRANSFER` first gets closeBOL's shipping phase, including an `ORDER_BATCH_SHIPPED` to OMS (SBDEV-3728). Already `CLOSED` is a no-op.
- An unknown `transfer_id` answers `404` through the global `RestExceptionHandler.handleEntityNotFound` (a ProblemDetail whose `detail` is the reason). Any other runtime failure is answered by the `/rest` advice chain by type (503 for transient database failures, 500 otherwise). Both still write a FAILED `ORDER_BATCH_FINISHED_TRANSFER` row; its status code is `404` for the unknown transfer and empty otherwise (SBDEV-3728). The row's `answer` is `{"exception":"<class name>"}`, plus `"message"` for the unknown transfer's WMS-written text only; before SBDEV-3887 it was `e.toString()`, which quotes a JDBC failure's SQL (§1.7). ✓ merged(SBDEV-3887: #565 063eb2ed, 2026-10-25)
- The service-log row (RECEIVED or FAILED) never changes the response: if writing it fails, that is logged and the outcome is answered as it would have been (SBDEV-3728).
- Any other refusal (wrong BOL type, BOL `CANCELLED`) answers `400` with `{"status":"failure","description":"<the reason>"}` and writes a FAILED `ORDER_BATCH_FINISHED_TRANSFER` message row whose `answer` is the same reason (SBDEV-3728; before it, the description was GENERIC_ERROR's fixed text and the answer null).

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

### 3.6 `POST /rest/order/updateShipper`

**Purpose:** OMS moved a parcel already in the warehouse onto another ship method (the carrier booked a different service, or an operator changed it on a Label Exception) and optionally corrected the order's fulfillment type (SBDEV-3841, ST#1518). Previously undocumented here. Source: `OrderRestController:963-1076`.

#### Request

```
POST /rest/order/updateShipper
Content-Type: application/json

List<OrderBatchDto>
```

| Field | Type | Required | Description |
|---|---|---|---|
| `facility_code` | String | ✅ | Must match the warehouse sysprop (`validateWarehouse`) |
| `batch_id` | String | ✅ | Batch must exist |
| `positions` | List\<OrderDto\> | ✅ | One element per order; non-empty |
| `positions[].unique_id` | String | ✅ | External order ID; must exist and belong to the batch |
| `positions[].shippers_id` | String | ✅ | New ship-method code (trimmed). An unknown code is auto-created, as at batch import |
| `positions[].fulfillment_type` | String | — | Blank/absent leaves the order's fulfillment type unchanged |

#### Business Rules

- Every position is validated before any is written, and all are written in one transaction (`CustomerorderShipperService.reassignAll`): a rejected request changes nothing.
- A finished or cancelled order is not changed and is reported under `closed`; that is not a failure.

#### Success Response

```
HTTP 200 OK
{ "status": "success", "updated": ["<unique_id>",..], "unchanged": [..], "closed": [..] }
```

Unlike every other write in this section this is `200` with a body, not `204`.

#### Failure Responses

| Condition | HTTP | Description |
|---|---|---|
| Null body | 400 | `PARAMETER_IS_NULL` |
| `facility_code` missing / wrong | 400 | `FIELD_NOT_SET` / `WRONG_FACILITY_CODE` |
| `batch_id` / `positions` / `unique_id` / `shippers_id` missing | 400 | `FIELD_NOT_SET` (`NO_POSITION` for an empty `positions`) |
| Batch or order not found | 400 | `ENTITY_DOES_NOT_EXISTS` |
| Order not in the named batch | 400 | `CHILD_NOT_PART_OF_PARENT` |
| `reassignAll` raises `BusinessException` | 400 | `GENERIC_ERROR` |

Service log (§1.7): `ORDER_BATCH_UPDATE_SHIPPER`, RECEIVED/200 on success, FAILED/400 on a rejection.

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
| `facility_item_id` | Long | — | **SBDEV-2624.** This facility's `itemdata.id`, as the OMS recorded it from an earlier `item_ids` response. Only update and delete read it, and only client-scoped (`findByIdAndClientId`); an id of another client is a miss |
| `previous_sku` | String | — | **SBDEV-2624.** The code the OMS expects the row to hold now: the old SKU on a rename, the current SKU on a plain edit sent with `facility_item_id`. Blank → null. Rejected (103) if it contains control characters |

`request_nonce` (sent by the OMS) is not a DTO field; it only makes otherwise-identical bodies hash differently for `IdempotencyFilter`.

#### Business Rules

- SKU must not already exist for the given client → `422` if it does. Since SBDEV-2624 this is also re-checked against the DB, uncached, just before the insert, so a stale cached miss cannot slip past it.
- A duplicate (client, sku) inside one request → `422/105` before any write (SBDEV-2624 E-1).
- Control characters in `sku` (checked before trimming) or in `sku_name` (TAB allowed) → `422/103`.
- `client_id` must exist.
- `box_id` must exist in `boxtype` if provided.
- `unit_identifier_id` must exist in `itemunit` if provided.
- New SKU is assigned to the default put-away lane location.
- Cache `itemdata` is fully evicted after the write, programmatically from a `finally` block (SBDEV-3135; no annotation).

#### Success Response

```
HTTP 200 OK
{ "status": "success", "item_ids": { "<sku>": <itemdata.id>, ... } }
```

`item_ids` is the 200 body since SBDEV-2624; it was 204 with no body before. The OMS records these ids per facility in `product_wms_item.wms_item_id`.

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

**Purpose:** Update existing SKU records, including **renaming a SKU in place** (SBDEV-2624). Creates the SKU only if no lookup finds it (via `SkuBatchCreateUpdateService.upsertAll()`).

#### Request

```
POST /rest/sku/update
Content-Type: application/json

List<SkuDto>
```

Same `SkuDto` structure as `/create`. Required fields: `sku`, `sku_name`, `client_id`, `facility_code`.

#### Business Rules

**Lookup order (SBDEV-2624; plan `sbdocs/1-Projects/wms2/plan/SBDEV-2624-sku-rename-in-place-oms-wms-sync.md` §3.2, §10 D-M2/D-M3/E-1).** Each step is client-scoped:
1. `facility_item_id` — `findByIdAndClientId`, uncached.
2. `previous_sku` — uncached (E-1 #5).
3. `sku` — cached. A hit whose reloaded `item_nr ≠ sku` is a stale lookup: it is discarded and re-checked uncached (`SKU_RENAME_STALE_LOOKUP`).
4. Nothing found → create.

**Rename rules** (`upsertAll`, one tenant transaction):
- **No rename without `previous_sku`.** A row found by id whose code differs from `sku`, with no `previous_sku`, gets 108.
- **Compare-and-set:** the row's current code must be `previous_sku` or `sku`, else **108** `sku rename precondition failed: item_id=X is D, expected P` (the OMS resends once, guarded).
- **Collision:** if another row of the client already holds `sku` → **105** naming both item ids. Rows are not merged.
- On rename, `stockrecord.itemdata` rows for (client, old code) are rewritten **in the same transaction, before** the itemdata UPDATE. Order: collision check → native rewrite → setters → `saveAndFlush`, so the FOR UPDATE row lock is held only briefly.
- Lock or optimistic conflicts → **109** `sku concurrent modification: …`.
- At most **one rename per request** → otherwise `422/103`. Duplicate (client, sku) in one request → `422/105`.
- **Only a real unique violation (23505) maps to 105.** Other integrity errors stay a 500.
- Cache `itemdata` is fully evicted in `finally`.

The 108/109 description prefixes are a **cross-repo contract**: the OMS `WMS_RESYNC_MARKERS` constant matches them by prefix. `sbdocs/9-System/scripts/verify-SBDEV-2624-sku-rename-in-place-oms-wms-sync.sh` checks it. Do not reword or localize them.

#### Success Response

```
HTTP 200 OK
{ "status": "success", "item_ids": { "<sku>": <itemdata.id>, ... } }
```

#### Failure Responses

Same structure as `/create` — `HTTP 422 Unprocessable Entity`, plus 108 (rename precondition) and 109 (concurrent modification).

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
- **SBDEV-2624:**
  - If `facility_item_id` is sent, the row is found by id, client-scoped. If its code differs from `sku`, the result is **400/108 `… (delete)`** and nothing is deleted (`SKU_DELETE_PRECONDITION`).
  - Otherwise the row is looked up by code, uncached.
  - Control characters in `sku` → 400/103.
- ⚠️ **Stock check is not yet implemented** (`// TODO check that no item exists`, `SkuRestController:458`). Deleting a SKU with live inventory may cause data integrity issues.

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

Service log (§1.7): `SKU_DELETE`, RECEIVED/204 on success with `answer` `{"deleted":[{"client_id","sku"},..]}`; FAILED/400 on a 400 with the rejection in `answer` plus `"deleted":[..]` when earlier SKUs of the batch were already deleted. Any runtime exception part-way through the batch (typically an FK violation) escapes as a 5xx and, since SBDEV-3887, writes a FAILED row (`answer` `{"exception":"<class>"}` plus `"deleted"` when earlier SKUs went through; §1.7; `SkuRestController` `catch (RuntimeException e)` calls `logEscapedFailure(..., deleted...)`). ✓ merged(SBDEV-3102: #560 4960631d, 2026-10-22; SBDEV-3887: #565 063eb2ed, 2026-10-25)

> ⚠️ **Not atomic.** Each SKU's delete commits on its own. A batch rejected on its Nth SKU has already deleted the SKUs before it, but the 400 body names only the rejection; it does not say which SKUs were deleted. A caller re-sending the whole batch then gets `ENTITY_DOES_NOT_EXISTS` on the first, already-deleted SKU. For a batch ended by a 400 rejection, the service-log row (above) is currently the only record of the partial delete. A batch ended by a runtime exception part-way through (typically an FK violation) now also writes a FAILED row listing the SKUs deleted before it (SBDEV-3887); only the connection-pool-timeout case writes none (§1.7). OMS v2's only caller, `WmsApiService::deleteSku` (oms-laravel-api `a8f73897`), sends one SKU per call (`makeWmsRequest` wraps the single object in a one-element list), so it cannot hit this today; a multi-SKU caller can. ✓ merged(SBDEV-3102: #560 4960631d, 2026-10-22)

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
| `itemDataNumber` | String | ✅ | SKU/item number. **Required**: omitting it answers `400 FIELD_NOT_SET` (there is no "all SKUs of the client" mode; `StockCountRestController:67-110`) |

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
| `clientNumber` missing | 400 | `FIELD_NOT_SET` |
| `itemDataNumber` provided without `clientNumber` | 400 | `NOT_UNIQUE_VALUE` |
| `itemDataNumber` missing | 400 | `FIELD_NOT_SET` |
| Null body | 400 | `PARAMETER_IS_NULL` |
| Unknown item for the client | 404 | `EntityNotFoundException` → ProblemDetail via `RestExceptionHandler` (not the `{status,description}` shape) |

Service log (§1.7): `REPORT_STOCK_COUNT`, RECEIVED/200 on success, FAILED/400 with the rejection in `answer` on a 400. The row's payload is the request's identifying fields only, `{"facility_code","clientNumber","itemDataNumber"}`, not the whole DTO, whose zeroed stock fields would read as an answer. An unknown item escapes as `EntityNotFoundException` (404) and, since SBDEV-3887, writes a FAILED row (`answer` `{"exception":"EntityNotFoundException","message":"..."}`, §1.7). ✓ merged(SBDEV-3102: #560 4960631d, 2026-10-22; SBDEV-3887: #565 063eb2ed, 2026-10-25)

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

> [!warning] **Two behaviour changes as of SBDEV-3198 (merged 2026-09-03, live on dev). Both are visible to OMS callers and neither changes the request or the status code.**
>
> **1. Scope narrowed from every tenant to the caller's tenant.** The handler now calls
> `stockSummaryExportJob.runForCurrentTenant()` (`StockCountRestController:161-170` at `df30fa62`, via `triggerSchedule().run()`);
> it previously called `doCalculation(...)`, which iterated **every active tenant** in the process.
> The tenant is resolved from `TenantContext`, i.e. from the **`X-Tenant-ID` + `facility_code`
> headers** — so a caller that omitted them and relied on the old all-tenants fan-out now exports
> nothing. Send the headers.
>
> **2. HTTP 200 no longer means the export ran.** `triggerStockCount()` returns `void` and
> **discards** `runForCurrentTenant()`'s boolean, so the response is an empty 200 in all of these
> cases: the export completed; no `TenantContext` (refused, ERROR logged); no landlord
> `tenant_db_configuration` row for that tenant/warehouse (refused rather than exporting without
> lock protection); the tenant's id does not narrow to `int4` (refused); the per-tenant advisory
> lock was already held by the scheduled group or another manual trigger (skipped, DEBUG); or the
> export threw. **Do not treat 200 as an acknowledgement.** Confirm from the job's own metrics
> (`tenantSuccess` / `tenantFailure` / `tenantSkippedNotActivated`) or the export's downstream
> effect. See [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §4.

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
| `start_date` | String | ✅ | Format: `yyyy-MM-dd HH:mm:ss`, warehouse-local time (the "System Time Zone" sysprop) |
| `end_date` | String | ✅ | Format: `yyyy-MM-dd HH:mm:ss`, warehouse-local time |
| `sku` | String | — | Filter by SKU. Honoured since SBDEV-3670 (it was ignored before); null, empty or blank = every SKU; otherwise trimmed and must exist for the client, else `400 ENTITY_DOES_NOT_EXISTS` (`resolveSkuFilter`, `TransactionReportRestController:103`) |

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
| `sku` given but unknown for the client | 400 | `ENTITY_DOES_NOT_EXISTS` |

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
| `sku` | String | — | Filter by specific SKU; null, empty or blank for all SKUs (same `resolveSkuFilter` contract as §6.1) |

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

Same conditions as `/getTransactionReport` (including the unknown-`sku` row, which since SBDEV-3670 applies to both reports). Null body is not checked by either report handler ⚠ unverified 2026-11-11: behaviour on a literal `null` body was not exercised.

---

## 7. UtilRestController — Not an Active HTTP Controller

`UtilRestController` (`controller/rest/UtilRestController.java:23`) is annotated `@Service` only — it is **not** a `@RestController` or `@Controller`, and it has no class-level `@RequestMapping`. Its nine method-level `@RequestMapping` declarations (`/initDB`, `/recalculateLocationConstraints`, `/populateCaseTypes`, `/initAdmin` and `/calculateInventoryByMessages` as POST; `/simulateServerFaultException` and `/simulateClientFaultBusinessException` as POST; `/cancelAllNotStartedReplenishmentOrders` and `/resetOrdersInReleasedStatus` as GET) are therefore **not** registered by Spring MVC: none is reachable over HTTP. `WmsConstants:436` records the same fact. It is invoked programmatically for first-time setup / maintenance, if at all ⚠ unverified 2026-11-11: no `.java` reference other than comments was found, so the callers (if any) are not identified.

---

## 8. Technical Notes for Integrators

### 8.1 Retry Safety

Non-GET `/rest/**` endpoints are idempotent through `IdempotencyFilter` (SBDEV-2222), with the exclusions in §1.4 (`/rest/stockcount/**` and, after SBDEV-4114, `/rest/report/**` ✓ merged(SBDEV-4114: #662 494d2216, 2026-11-11); reads need no protection). OMS may safely retry on network failure; the filter replays the cached 2xx response for repeated identical requests. A 2xx body that reports a business failure (`cancelPositions` partial batch) is not cached, so a retry re-runs it.

### 8.2 OMS Notification Flow

After certain state transitions (order picked, advice closed, transfer finished), WMS notifies OMS asynchronously via the **transactional outbox** (`outbox_message` table). `OutboxDispatcherJob` runs on `app.cron.outbox-dispatcher` (`application.properties:219`: every 3 seconds; the in-code default is 15 s) plus a separate club lane (`app.cron.outbox-dispatcher-club`, also 3 s), batch size 25 (`app.outbox.dispatcher.batch-size`), and POSTs to OMS. Failed notifications are retried with exponential back-off (`min(60 s x 2^attempts, 1 h)`) up to `app.outbox.dispatcher.max-attempts=5`, except `ORDER_BATCH_SHIPPED` rows, which get `bol-shipped-max-attempts=29` (SBDEV-3672). 400/404/422 from OMS are terminal immediately.

> **SBDEV-2381 (2026-06-01) — `event_version` on picking-status payloads:** Outbound WMS→OMS picking-status payloads (the `OrderBatchDto` posted to `readytopick` / `picking` / `finishedPicking`) now carry an additive top-level **`event_version`** field equal to the dispatching `outbox_message` row id (a BIGSERIAL, monotonic per parcel). It is injected into the POST body at dispatch time; OMS may use it to **reject stale / out-of-order events**. Existing fields are unchanged. The dispatcher also now claims and sends events in strict per-parcel order (ordering gate + in-Java sort + sequential POST loop) — see `architecture/wms2-oms-integration-map.md` §2.1 for the full mechanism.

### 8.3 Date Format

All date fields in reports use `yyyy-MM-dd HH:mm:ss`. Advice `day_of_delivery` / `day_of_delivery_until` use ISO date `yyyy-MM-dd`.

### 8.4 Priority Mapping

Source: `WmsConstants.Priority.fromOmsLevel` / `toOmsLevel` (`WmsConstants.java:841-927`). An earlier revision of this table named constants that do not exist (`PRIORITY_URGENT`, `PRIORITY_MEDIUM`, `PRIORITY_VERY_LOW`) and had the direction inverted.

| `priority` value | WMS constant | WMS code |
|---|---|---|
| 1 | `PRIORITY_IMMEDIATE` | 100000 |
| 2 | `PRIORITY_HIGH` | 10000 |
| 3 | `PRIORITY_MODERATE` | 1000 |
| 4 | `PRIORITY_NORMAL` | 100 |
| 5 | `PRIORITY_LOW` | 0 |

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
| `/advice/create` duplicate-advice code name | The duplicate-`reference_id` rejection uses the misspelled constant `ENTITY_ALREADY_EXITS` (kept for wire compatibility). The client-not-found rejection was corrected to `ENTITY_DOES_NOT_EXISTS` |
| `/sku/delete` — no live-stock check | Deleting a SKU with live inventory is allowed at the API level (`// TODO check that no item exists`, `SkuRestController:458`); downstream integrity depends on application-level guards |
| `/advice/reopen` — not implemented | Throws `RuntimeException` (500); do not call. Removed by SBDEV-4115 (404) ✓ merged(SBDEV-4115: #664 938c9fe2, 2026-11-11) |
| `StockCountDto` JSON field names | `clientNumber` / `itemDataNumber` are camelCase (not snake_case) — inconsistent with the rest of the API |
| `StockCountRestController.triggerStockCount` | Runs the export job synchronously in the request thread; no timeout. 200 does not mean the export ran (§5.2) |
| `/rest/**` is `permitAll` | No JWT, no function gate on any `/rest` endpoint (§1.1); the SBDEV-2778 comments call `/rest/advice/create` "unauthenticated" and bound its batch size for that reason |

---

## 9. ClubLineController — `/v3/clubLine` async run endpoints ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06)

⚠ **Scope note.** This document otherwise covers only `net.aim_ai.wms.controller.rest` (`/rest/**`). `ClubLineController` is a **web-UI** controller in `net.aim_ai.wms.controller`, not an OMS integration surface; it has no other section here, so only the SBDEV-4007 additions are listed. The full club-line endpoint table is [wms2-club-run-workflow](../workflows/wms2-club-run-workflow.md) §5; semantics are §8A. Re-read 2026-11-11 on `origin/develop` @ `df30fa62` (`ClubLineController.java:186-300`): the four endpoints below are on `develop`. The controller has 16 mapped methods in total (`@RequestMapping("/v3/clubLine")`, extends `AdminController`), all `@RequiresFunction(WEB_UI_VIEW_CLUB_LINE)`.

All four carry `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_CLUB_LINE)`. Errors keep the screen's shape: HTTP **200** with `{"errors":[{...,"message":"..."}]}`.

| Method + path | Success | Notes |
|---|---|---|
| `POST /v3/clubLine/clubRunJobs/{orderBatchId}` | **202** `{jobId, state, batchid}` | Submits a job; an existing live (QUEUED/RUNNING) job for the batch returns the same body. Errors: batch not found, `WMS_CLUBLINE_ASYNC=0`, batch not ACTIVATED / STAGING_LANE_ASSIGNED, active orders above `WMS_CLUBLINE_MAX_BATCH_SIZE` |
| `GET /v3/clubLine/clubRunJobs/{jobId}` | 200 `ClubRunJobStatusDto` | `{jobId, batchid, state, processed, total, lastError, batchState, attempt, startedAt, finishedAt}`; `state` in QUEUED, RUNNING, DONE, FAILED, STUCK. Unknown id: `errors[]` |
| `GET /v3/clubLine/clubRunJobs/byBatch/{orderBatchId}` | 200 `ClubRunJobStatusDto` | Latest job of the batch; none: `errors[]` `"No club run job for batch: <id>"` |
| `GET /v3/clubLine/runClubLine/{orderBatchId}` | 200 | **Behaviour change.** Switch ON (default): submits a job and waits up to `app.clubline.sync-wait-seconds` (45 s). DONE: `{message:"RUN CLUBLINE"}` as before. Not terminal by then: `{field, message:"RUN CLUBLINE QUEUED"` or `"RUN CLUBLINE RUNNING", jobId, state}`. FAILED/STUCK: `errors[]` with `last_error`. Switch OFF: runs inline as before, refused while a live job exists for the batch |

Callers of the legacy GET must treat any `message` other than `"RUN CLUBLINE"` as "not finished yet", and poll the status endpoint (or the batch state). `lastError` carries client-safe text only; the exception is in the server log. Any holder of the screen's function can read any job id in the tenant (accepted, S5).

✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06) **Web UI consumer (P2).** The wms2-web-ui Run Club screen submits with `POST /clubRunJobs/{batchid}` and polls `GET /clubRunJobs/{jobId}` (2 s, then 10 s; 15 s timeout per poll), falling back to the legacy GET only when the submit is refused with `"Async club run is disabled for this warehouse ("`. See [wms2-club-run-workflow](../workflows/wms2-club-run-workflow.md) §8A.9.

---

## 10. Endpoint census and undocumented endpoints (added 2026-11-11)

> **Scope.** Sections 2-9 document the OMS-facing `/rest/**` surface (plus four `ClubLineController` endpoints). This section enumerates everything else in `origin/develop` @ `df30fa62` so a reader can see what exists without a per-endpoint table. **Everything marked "no" in the table below is undocumented here**: its verbs, request/response shapes and per-method gating were NOT re-derived on 2026-11-11. Use Swagger (`/swagger-ui/index.html`), [wms2-function-to-docs-map](../architecture/wms2-function-to-docs-map.md) §9 and the module design docs.

### 10.1 Census method and counts

- `@RestController` classes: **64** (no class uses bare `@Controller`; `@ControllerAdvice` classes are separate).
- Method-level mappings in them: **376** = 372 under `net.aim_ai.wms.controller` + 4 under `landlord/controller` (`TenantDiscoveryController` 1, `TenantProvisioningController` 3). Second instrument, grep per annotation: `@GetMapping`/`@PostMapping`/`@PutMapping`/`@DeleteMapping` on indented lines = 336 (172 GET, 149 POST, 13 PUT, 2 DELETE), plus 36 indented `@RequestMapping(..., method = ...)` = 372, matching. One further method mapping, `TokenController` `@RequestMapping("/detrack")` (no `method`, so all verbs), is not in the 376. `@PatchMapping`: 0 uses.
- `UtilRestController` is a `@Service`, not a controller (§7), and is excluded.
- Spring Data REST: `RestConfiguration` sets `setBasePath("/v3")`. 63 interfaces carry a column-0 `@RepositoryRestResource`; 28 of those say `exported = false` at type level, so up to 35 repositories publish collection/item resources under `/v3/<path>`, and individual finders are hidden or shown by `@RestResource(exported = ...)` (243 `exported = false` hits). The exact SDR URL list was NOT enumerated ⚠ unverified 2026-11-11 (it needs a running app or an annotation-by-annotation read); `ControllerRequestMappingConventionUnitTest` pins the `/v3` prefix convention for controllers.
- Gating: `/rest/**`, `/api/**`, `/api/public/**`, `/v3`, `/v3/token`, `/error`, Swagger UI are `permitAll`; `/v3/**` (and `/putawayConfig/**`, `/api-docs/**`) require authority `wms_user`; `/actuator/**` needs `ADMIN`/`wms_admin`; anything else is `authenticated()` (`SecurityConfiguration:146-190`). Per method, `@RequiresFunction(WmsConstants.FunctionEnum.*)` is the fine-grained gate. The `@RequiresFunction` column below counts annotation occurrences per file; a count under the mapping count means a class-level annotation or ungated methods, and which ⚠ was not verified per endpoint.

### 10.2 Undocumented `/rest/**` endpoints (OMS/QA-facing)

All three are `permitAll`, carry no function gate, and need `X-Tenant-ID` + `facility_code` (§1.1-1.2). None writes a service-log row.

| Method + path | Class | Behaviour |
|---|---|---|
| `GET /rest/printer/findByType?type=<type>` | `PrinterRestController:41` | `type` request param (required). Returns `200` with the JSON array of `Printer` entities of that type (`PrinterRepository.findByType`), used by the OMS QA flow to list return-receiving printers (e.g. `RETURN`). Added so OMS needs no JWT, unlike `/v3/printer/search/findByType`. A missing `type` is a Spring `400` |
| `GET /rest/unitload/state/{labelId}` | `UnitloadRestController:44` | SBDEV-2742. Blank `labelId` → `400` with the plain-text body `labelId is required`. Otherwise always `200` with `ToteStateDto`: `label_id`, `found`, `empty`, `location_name`, `assigned`, `assigned_order_number`, `assigned_state` (Integer), `assigned_state_text`, `last_activity_at`. An unknown label is `found:false`, not an error. ⚠ unverified 2026-11-11: the DTO's remaining fields past `last_activity_at` were not read |
| `POST /rest/stockcount/sendDummyMessageStockCountList` | `MessageDummyController:38` | Test-only. Body `List<StockCountDto>`, returns `void` (200). Served by a separate controller class that shares the `/rest/stockcount` prefix |

### 10.3 Every other controller

| Controller | Base path | Mapped methods | `@RequiresFunction` occurrences | `@PreAuthorize` occurrences | Documented |
|---|---|---|---|---|---|
| `PublicVersionController` | `/api/public` | 1 | 0 | 0 | no |
| `TenantDiscoveryController` | `/api/public` | 1 | 0 | 0 | no |
| `TenantProvisioningController` | `/landlord/tenants/{tenant}/warehouses/{warehouse}` | 3 | 0 | 0 | no |
| `AdviceRestController` | `/rest/advice` | 4 | 0 | 0 | §2 |
| `OrderRestController` | `/rest/order` | 6 | 0 | 0 | §3 |
| `PrinterRestController` | `/rest/printer` | 1 | 0 | 0 | §10.2 |
| `TransactionReportRestController` | `/rest/report` | 2 | 0 | 0 | §6 |
| `SkuRestController` | `/rest/sku` | 3 | 0 | 0 | §4 |
| `MessageDummyController` | `/rest/stockcount` | 1 | 0 | 0 | §10.2 |
| `StockCountRestController` | `/rest/stockcount` | 2 | 0 | 0 | §5 |
| `UnitloadRestController` | `/rest/unitload` | 1 | 0 | 0 | §10.2 |
| `AdminController` | `/v3` | 9 | 2 | 9 | no |
| `TokenController` | `/v3` | 2 | 0 | 0 | no |
| `UserAdministrationController` | `/v3` | 4 | 0 | 3 | no |
| `ReplenishmentReconciliationController` | `/v3/admin` | 1 | 0 | 1 | no |
| `AdminActionController` | `/v3/adminAction` | 9 | 8 | 1 | no |
| `AdviceController` | `/v3/advice` | 11 | 11 | 0 | no |
| `BillOfLadingController` | `/v3/billOfLading` | 15 | 15 | 0 | no |
| `BoxTypeController` | `/v3/boxType` | 4 | 3 | 0 | no |
| `OrderCancellationController` | `/v3/cancellation` | 6 | 3 | 0 | no |
| `ClientController` | `/v3/client` | 9 | 8 | 0 | no |
| `ClubLineController` | `/v3/clubLine` | 16 | 16 | 0 | §9 (4 of 16) |
| `CustomerOrderController` | `/v3/customerOrder` | 8 | 8 | 0 | no |
| `CustomerOrderBatchController` | `/v3/customerOrderBatch` | 4 | 4 | 0 | no |
| `CustomerOrderPositionController` | `/v3/customerOrderPosition` | 1 | 1 | 0 | no |
| `CycleCountController` | `/v3/cycleCount` | 8 | 8 | 0 | no |
| `CycleCountLosController` | `/v3/cycleCountLos` | 9 | 1 | 0 | no |
| `DashboardController` | `/v3/dashboard` | 6 | 6 | 0 | no |
| `FixLocationAssignmentController` | `/v3/fixedAssignment` | 10 | 1 | 0 | no |
| `GoodsReceiptPositionController` | `/v3/goodsReceiptPosition` | 3 | 3 | 0 | no |
| `FileImportController` | `/v3/import` | 4 | 1 | 0 | no |
| `ItemDataController` | `/v3/itemData` | 7 | 8 | 0 | no |
| `LabelPrintingController` | `/v3/labelPrinting` | 12 | 1 | 0 | no |
| `LocationController` | `/v3/location` | 7 | 7 | 0 | no |
| `LookupController` | `/v3/lookup` | 5 | 2 | 0 | no |
| `MessageController` | `/v3/message` | 3 | 3 | 0 | no |
| `MobileForceScanController` | `/v3/mobile` | 2 | 1 | 0 | no |
| `MoveStockController` | `/v3/moveStock` | 2 | 1 | 0 | no |
| `MoveUnitloadController` | `/v3/moveUnitload` | 2 | 1 | 0 | no |
| `PalletizingController` | `/v3/palletizing` | 4 | 1 | 0 | no |
| `PickingController` | `/v3/picking` | 11 | 1 | 0 | no |
| `PickingOrderPositionController` | `/v3/pickingOrderPosition` | 1 | 1 | 0 | no |
| `PrinterController` | `/v3/printer` | 11 | 11 | 0 | no |
| `PutawayController` | `/v3/putaway` | 6 | 1 | 0 | no |
| `PutawayConfigController` | `/v3/putawayConfig` | 5 | 6 | 0 | no |
| `ReceivingController` | `/v3/receiving` | 8 | 9 | 0 | no |
| `ReplenishController` | `/v3/replenish` | 11 | 6 | 0 | no |
| `ReplenishOrderController` | `/v3/replenishOrder` | 11 | 12 | 0 | no |
| `ReportController` | `/v3/report` | 15 | 15 | 0 | no |
| `SectionController` | `/v3/section` | 4 | 4 | 0 | no |
| `ShipperIdController` | `/v3/shipperId` | 3 | 2 | 0 | no |
| `StockUnitController` | `/v3/stockUnit` | 17 | 21 | 0 | no |
| `StockRecordController` | `/v3/stockrecord` | 2 | 2 | 0 | no |
| `SystemController` | `/v3/system` | 2 | 1 | 0 | no |
| `SystemPropertyController` | `/v3/systemProperty` | 3 | 1 | 0 | no |
| `TenantHealthController` | `/v3/tenant` | 1 | 0 | 0 | no |
| `TransferOrderController` | `/v3/transferOrder` | 5 | 1 | 0 | no |
| `TransfersController` | `/v3/transfers` | 16 | 16 | 0 | no |
| `TruckLoadingController` | `/v3/truckLoading` | 5 | 1 | 0 | no |
| `UnitLoadController` | `/v3/unitLoad` | 9 | 9 | 0 | no |
| `UnitloadRecordController` | `/v3/unitloadRecord` | 1 | 1 | 0 | no |
| `UserController` | `/v3/user` | 12 | 3 | 1 | no |
| `UserGroupController` | `/v3/userGroup` | 4 | 1 | 1 | no |
| `UserRoleController` | `/v3/userRole` | 5 | 2 | 1 | no |
| **64 controllers** | | **376** | | | |

### 10.4 Other non-`/v3` surfaces

| Method + path | Class | Notes |
|---|---|---|
| `GET /api/public/version`, `GET /api/public/authConfig` | `PublicVersionController:34`, `TenantDiscoveryController:24` | Public; `TenantFilter` skips tenant resolution under `/api/public/` |
| `PUT`, `GET /landlord/tenants/{tenant}/warehouses/{warehouse}` and `POST .../demo-reset` | `TenantProvisioningController:52,60,66` | Landlord provisioning; ⚠ unverified 2026-11-11: gating and request/response shapes not read |
| `GET /v3/tenant/health` | `TenantHealthController:35` | Reads a `tenant_name` `@RequestHeader` (the only place that spelling occurs; §1.2) |

---

## Verification log

| Date | Scope | Result |
|---|---|---|
| 2026-11-11 | Full re-verification against `origin/develop` @ `df30fa62` (every section; code read only from that tree) | Corrected: §1.1 (`/rest/**` is `permitAll`, not JWT), §1.2 (header is `X-Tenant-ID`; missing header does not reject), §1.4 (idempotency exclusions; `/rest/report` is enrolled), §1.5 (error shapes beyond 400), §1.7 (15 not 14 escaping handlers), §2.1 (RETURN auto-receive, 200 warning envelope, `amount_of_bottles_damaged`, client-not-found code, TRANSFER type), §2.4, §3 (priority text, missing FIELD_NOT_SET rows, `finishedTransfer` facility_code, new §3.6 `updateShipper`), §4.3 (FAILED row on runtime exception), §5.1 (`itemDataNumber` required, 404 writes a row), §5.2 (anchor), §6 (`sku` honoured, warehouse-local dates), §7 (nine mappings, not reachable), §8.2 (3 s cron, attempts), §8.4 (priority table was wrong), §8.6, §9 (on `develop`). Added §10 census and undocumented-endpoint list. Earlier partial pass (2026-09-06, §5.2 only) superseded. Next due 2027-01-10 |
