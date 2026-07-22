---
type: architecture
status: active
system: wms2
last_verified: 2026-06-01
---

# WMS2 ↔ OMS Integration Map

Reference for developers diagnosing OMS→WMS2 call failures, missing WMS2→OMS callbacks, or adding new integration points. All evidence derived from `v2/wms2-api/src/main/java/`.

---

## §1 Inbound — OMS Calls WMS2

All inbound REST endpoints extend `AbstractRestController`, which validates `facility_code` in every request body against the `MULTIWAREHOUSE_IDENTIFIER` sysprop before any business logic runs. Authentication is via Spring Security OAuth2/OIDC (Keycloak JWT). Base path is `/rest/`.

### 1.1 OrderRestController — `POST /rest/order`

| Method | HTTP | Path | Request body | Success code | Purpose |
|--------|------|------|-------------|-------------|---------|
| `create` | PUT | `/rest/order/create` | `List<OrderBatchDto>` | 204 | Create outbound order batches with positions |
| `updatePriority` | POST | `/rest/order/updatePriority` | `List<OrderBatchDto>` | 204 | Change priority (1–5) of existing order batches |
| `cancelPositions` | POST | `/rest/order/cancelPositions` | `List<OrderBatchDto>` | 200 | Cancel individual orders within a batch |
| `finishedQA` | POST | `/rest/order/finishedQA` | `List<OrderBatchDto>` | 204 | Mark orders as QA-complete (sets parcel label, packages order); silently discards CLUB and TRANSFER type batches |
| `finishedTransfer` | PUT | `/rest/order/finishedTransfer` | `AcceptTransferDto` | 204 | Signal that an outbound transfer BOL has been received at the destination; delegates to `BillofladingService.finishTransfer()` |

**Key validation rules for `create`:**
- `batch_id`, `priority` (1–5), `client_id`, `positions` are all required.
- `facility_code` must match the warehouse's `MULTIWAREHOUSE_IDENTIFIER` sysprop.
- Duplicate `parcel_external_number` values (against existing non-cancelled orders and unitloads) are rejected.

### 1.2 AdviceRestController — `PUT /rest/advice`

| Method | HTTP | Path | Request body | Success code | Purpose |
|--------|------|------|-------------|-------------|---------|
| `create` | PUT | `/rest/advice/create` | `List<AdviceDto>` | 204 | Create inbound advice (purchase-order / delivery notice) |
| `createTransfer` | PUT | `/rest/advice/createTransfer` | `BillOfLadingWebServiceDto` | 204 | Create a TRANSFER-type advice (intracompany stock move); exactly one order per batch enforced |
| `createHubAndSpoke` | PUT | `/rest/advice/createHubAndSpoke` | `BillOfLadingWebServiceDto` | 204 | Create a HUB_AND_SPOKE advice; `destination_warehouse` must match this WMS's identifier |
| `reopen` | POST | `/rest/advice/reopen` | `List<Advice>` | — | Stub — throws `RuntimeException("method not supported")` |

### 1.3 SkuRestController — `POST /rest/sku`

| Method | HTTP | Path | Request body | Success code | Validation failure | Purpose |
|--------|------|------|-------------|-------------|-------------------|---------|
| `create` | PUT | `/rest/sku/create` | `List<SkuDto>` | 204 | **422** (SBDEV-2235) | Create new SKU/item-data records |
| `update` | POST | `/rest/sku/update` | `List<SkuDto>` | 204 | **422** (SBDEV-2235) | Update existing SKU records |
| `delete` | DELETE | `/rest/sku/delete` | `List<SkuDto>` | 204 | 400 | Delete SKU records |

> **SBDEV-2235 OMS contract change:** `/rest/sku/create` and `/rest/sku/update` now return `422 UNPROCESSABLE_ENTITY` on validation failure (previously 400). `/delete` remains 400. OMS-side parser must be updated to accept 422 before this ships. Coordinate with David Oppenheim.

### 1.4 StockCountRestController — `POST /rest/stockcount`

| Method | HTTP | Path | Request body / params | Success code | Purpose |
|--------|------|------|----------------------|-------------|---------|
| `getStockCount` | POST | `/rest/stockcount/getStockCount` | `StockCountRequest` (JSON) | 200 | Query current stock count for given SKUs/locations |
| `triggerStockCount` | GET | `/rest/stockcount/triggerStockCount` | query params | 200 | Manually trigger a full stock-count export back to OMS |

### 1.5 TransactionReportRestController — `POST /rest/report`

| Method | HTTP | Path | Request body | Success code | Purpose |
|--------|------|------|-------------|-------------|---------|
| `getTransactionReport` | POST | `/rest/report/getTransactionReport` | `WarehouseTransactionReportRequest` | 200 | Summary transaction report for a date range |
| `getTransactionDetailedReport` | POST | `/rest/report/getTransactionDetailedReport` | `WarehouseTransactionDetailedReportRequest` | 200 | Detailed line-item transaction report |

---

## §2 Outbound — WMS2 Calls OMS

All outbound calls are made via `HttpRestService` (Spring `RestClient`, 5 s connect / 15 s read timeout). Each call:
1. Looks up the target URL from the tenant's `sysprop` table using the key shown below.
2. Posts JSON (or GETs) with `Authorization: Basic <OMS_API_USER>` and `x-tenant: <OMS_TENANT_ID>` headers.
3. Logs a `Message` record (WMS→OMS direction) with status SENT or FAILED.

Failed calls log the message record with status=FAILED and HTTP code 503, but **do not retry automatically** — a manual resend is possible via `MessageService.resendMessage()`.

### 2.1 Order Lifecycle Callbacks (ManageOrderService)

> **SBDEV-2214 (2026-05-10):** all 7 ManageOrderService callbacks below now POST to OMS via `omsNotificationService.sendAfterCommit(urlPath, payload, processType)` — registered as a `TransactionSynchronization.afterCommit` listener. The HTTP POST fires only AFTER the surrounding transaction commits; if the caller transaction rolls back, the POST never happens. `HttpRestService` and `MessageService` are no longer constructor-injected into `ManageOrderService`. The audit `Message` row (SENT / FAILED) is now written by `OmsNotificationService.doSend` on the listener side, not inline at the call-site.

| Sysprop key | Default OMS path | Triggered by | Java method | Payload |
|------------|-----------------|-------------|-------------|---------|
| `WEBSERVICE_ORDER_BATCH_HELD` | `/services/call/held` | Warehouse operator puts batch on hold | `ManageOrderService.customerOrderOnHold()` | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `/services/call/readytopick` | Batch released to picking queue | `ReleaseOrderJobService.releaseOrder()` → outbox; club runs → `CustomerorderBatchService.finalizeClubLine()` → outbox ² (was `ManageOrderService.customerOrderReleaseForPicking()`, now retired no-op shim) | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `/services/call/assignedToteID` | Tote assigned to a picker for the batch | `ManageOrderService.customerOrderToteAssigned()` | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_PICKING` | `/services/call/picking` | Picking started on the batch | `PickingorderBusinessService.confirmPick()` → outbox ² (SBDEV-2381: skips the enqueue when the CO already advanced — `state≥PICKED` or `pickingconfirmationsent`) | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `/services/call/finishedPicking` | All items picked for the batch | `PickingorderBusinessService.finishPickingOrder()` → outbox ² | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `/services/call/palletized` | Orders palletized onto outbound pallet | `ManageOrderService.customerOrderPalletized()` | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `/services/call/loadedToTruck` | Pallet loaded to truck (BOL context) | `ManageOrderService.customerOrderLoadedToTruck()` | `OrderBatchDto[]` |

> ² **2026-05-20 (picking-finished fix):** `PICKING_STARTED` (`confirmPick`) and `PICKING_FINISHED` (`finishPickingOrder`) previously triggered a nested `registerSynchronization` inside `OmsNotificationService.sendAfterCommit`, which Spring silently discarded after the TX committed (double-afterCommit bug). Both `PickingorderBusinessService` call-sites now call `outboxService.enqueue(OutboxMessage)` directly inside the open `@Transactional("tenantTransactionManager")` — the outbox row commits atomically with the state change. ~~`ManageOrderService.customerOrderPickingStarted()` and `customerOrderPicked()` are retained (`@Deprecated`) for `CustomerorderBatchService` batch-level callers which still use the `sendAfterCommit` path.~~ **Superseded by SBDEV-2381 (2026-06-01):** `customerOrderReleaseForPicking`, `customerOrderPickingStarted`, and `customerOrderPicked` are now retired to deprecated no-op shims (return `false` — they no longer dispatch). The club-batch RELEASE/PICKING_STARTED/PICKING_FINISHED notifications they previously served are now enqueued in-tx per CO inside `CustomerorderBatchService.finalizeClubLine` (see the SBDEV-2381 note below). **`OmsNotificationService.sendAfterCommit` guard upgraded:** now checks `isSynchronizationActive() && isActualTransactionActive()` before registering; if the caller is already inside an `afterCommit` callback (`syncActive=true, txActive=false`), the POST is issued synchronously instead of being discarded. **Safety net:** `MobilePickingService.releaseRegularPickingOrder` Case 1 calls `PickingorderBusinessService.reenqueuePickingFinishedIfMissing(pickingOrder)` to recover any CO with `state≥PICKED` AND `pickingconfirmationsent=false`.

> **SBDEV-2381 (2026-06-01) — outbox ordering + club-line unify:** Outbox dispatch was sending WMS→OMS parcel-status events out of order (the `UPDATE … RETURNING` heap order is not insertion order; DB-verified 43% of PICKING_STARTED/FINISHED pairs inverted), regressing parcels Ready-to-QA → Picking. Five changes:
> - **Claim query** (`OutboxMessageRepository.findAndClaimPending`): now `ORDER BY next_attempt_at, id` plus a **fail-closed cross-tick `NOT EXISTS` gate** — a row is not claimed while a lower-`id` sibling of the *same aggregate* is still `PENDING/FAILED_RETRY/IN_FLIGHT/FAILED_TERMINAL` (a later event is HELD if its predecessor is unsent **or** terminally failed — prevents FINISHED-without-STARTED). Outer `UPDATE … RETURNING *` retained.
> - **Dispatch** (`OutboxDispatchService.dispatchBatch`): the claimed batch is sorted in Java by `(nextAttemptAt, aggregateType, aggregateId, id)` before a **sequential** POST loop (no `parallelStream`). Ordering key is the existing `id` BIGSERIAL — monotonic per aggregate because STARTED commits in an earlier CO-row-locked tx than FINISHED; no synthetic sequence column was added.
> - **`event_version`** (`OutboxDispatchService.dispatchOne`): injects `event_version = outbox row id` as a top-level field in the OMS POST **body** (Jackson; verbatim fallback for non-object payloads). Additive; lets OMS reject stale/out-of-order events (OMS-side rejection is a paired ticket).
> - **Club-line unify** (`CustomerorderBatchService`): the 3 former Phase-4 fire-and-forget `sendAfterCommit` notifications (RELEASE/STARTED/FINISHED) are removed from `runClubLine` Phase 4 and now `outboxService.enqueue(...)` **per-CO, in-tx, inside `finalizeClubLine`** (ascending ids RELEASE<STARTED<FINISHED). A failed enqueue now ROLLS BACK finalize (atomic transactional outbox) instead of being swallowed.
> - **Retired dispatchers** (`ManageOrderService`): `customerOrderReleaseForPicking`, `customerOrderPickingStarted`, `customerOrderPicked` are deprecated no-op shims (return `false`). `ReleaseOrderJobService.releaseOrder` migrated its RELEASE notification onto the outbox. `PickingorderBusinessService.confirmPick` gained the backward guard (skip PICKING_STARTED enqueue when CO already advanced).
> - **Migration:** `V2.1.14__add_outbox_aggregate_order_index.sql` — `CREATE INDEX CONCURRENTLY` (non-transactional, `-- flyway:executeInTransaction=false`, DROP-IF-EXISTS rerun guard) on `outbox_message (aggregate_type, aggregate_id, id, status)`. The `outbox_message` table itself is now created by **V2.1.11** (renamed from V1.1.16 by develop's V2.1.x renumber); latest migration before this was V2.1.13.

### 2.2 Shipment / BOL Callback (BillofladingService)

| Sysprop key | Default OMS path | Triggered by | Java method | Payload |
|------------|-----------------|-------------|-------------|---------|
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `/services/call/finishedShipping` | BOL closed (`closeBOL`) | `BillofladingService.closeBOL()` | `BillOfLadingWebServiceDto` (includes BOL ID, pallets, orders, seal, truck, carrier, shared unique BOL ID, tracking device ID, transfer ID, source/destination warehouse) |

> **SBDEV-2221 pilot (2026-05-17):** `BillofladingService.closeBOL` no longer calls `omsNotificationService.sendAfterCommit`. Instead it calls `OutboxService.enqueue(OutboxMessage)` **inside the still-open BOL transaction** — the outbox row and the BOL state change commit atomically. The `OutboxDispatcherJob` (every 15 s, advisory lock 100008L) then polls `outbox_message` and POSTs to OMS via `HttpRestService.postWithIdempotencyKey`. Serialisation failure now throws `FacadeException` and rolls back the BOL state change (was silently swallowed before). Five additional call-sites were migrated in SBDEV-2238 Phase-2 (2026-05-19): `CustomerorderService.cancelOrder`, `CustomerorderBatchService.cancelBatch`, `AdviceService.acceptHubAndSpokeAdvice`, `AdviceService.close`, and `AdviceService.acceptTransferAdvice` — see §2.3 and §2.4 notes. The remaining 11 `sendAfterCommit` call-sites are deferred to Phase-3.

### 2.3 Cancellation Callbacks

| Sysprop key | Default OMS path | Triggered by | Java method | Condition |
|------------|-----------------|-------------|-------------|-----------|
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `/services/call/cancelPosition` | Batch cancelled in WMS | `CustomerorderBatchService.cancelBatch()` | Always when a batch is cancelled |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `/services/call/cancelPosition` | Individual order cancelled from within WMS | `CustomerorderService.cancelOrder()` | Only when `cancellationFromWithinWMS=true`; uses `WEBSERVICE_STOCK_COUNT_URL` key — see note |
| `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` | _(flag, not URL)_ | Global toggle for cancel callbacks | — | Default `false`; when `false`, cancel callbacks from `CustomerorderBatchService` are still sent (key is consulted as a gate in v1; v2 sends unconditionally via `cancelBatch`) |

> **Note on CustomerorderService cancel:** When `cancellationFromWithinWMS=true`, `cancelOrder()` sends a notification using the `WEBSERVICE_STOCK_COUNT_URL_KEY` sysprop (not the cancel URL). The `MessageProcessType` is `ORDER_BATCH_CANCELLED_FROM_WMS`. This is a known inconsistency — the stock-count URL is reused to signal a WMS-initiated cancellation.

> **SBDEV-2238 Phase-2 (2026-05-19):** `CustomerorderBatchService.cancelBatch` and `CustomerorderService.cancelOrder` no longer call `omsNotificationService.sendAfterCommit`. Both now call `outboxService.enqueue(OutboxMessage)` inside the still-open tenant transaction — the outbox row and the state change commit atomically. `aggregateType` is `CUSTOMER_ORDER_BATCH` (for `cancelBatch`) and `CUSTOMER_ORDER` (for `cancelOrder`). Serialisation failure throws `FacadeException` and rolls back the state change. `UtilRestController.resetOrdersInReleasedStatus` (admin loop) wraps `cancelOrder` in try/catch so a serialisation failure logs-and-continues rather than aborting the loop.

### 2.4 Inbound Advice Callbacks (AdviceService)

| Sysprop key | Default OMS path | Triggered by | Java method | Payload |
|------------|-----------------|-------------|-------------|---------|
| `WEBSERVICE_CLOSE_ADVICE` | `/services/call/closeAdvice` | Regular advice (purchase order) closed after receiving | `AdviceService.close()` | `AdviceDto` (with actual received quantities per position) |
| `WEBSERVICE_ACCEPT_TRANSFER` | `/services/call/closeTransfer` | Transfer advice accepted (all stock received) | `AdviceService.acceptTransferAdvice()` | `AcceptTransferDto` (transfer ID only) |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `/services/call/receiveHubAndSpoke` | Hub-and-spoke advice accepted | `AdviceService.acceptHubAndSpokeAdvice()` | `HubAndSpokeAcceptDto` (positions accepted) |

> **SBDEV-2238 Phase-2 (2026-05-19):** All three `AdviceService` callers (`acceptHubAndSpokeAdvice`, `close`, `acceptTransferAdvice`) no longer call `omsNotificationService.sendAfterCommit`. All three now call `outboxService.enqueue(OutboxMessage)` inside the still-open tenant transaction — the outbox row and the advice state change commit atomically. `aggregateType` for all three is `ADVICE`. Serialisation failure throws `FacadeException` and rolls back the state change. `AdviceController.closeMultipleInboundBol` and `closeInboundBol` catch `FacadeException` in addition to `BusinessException`.

### 2.5 Inventory Callbacks (MessageService / ItemDataController / StockSummaryExportJob)

| Sysprop key | Default OMS path | Triggered by | Caller | Payload |
|------------|-----------------|-------------|--------|---------|
| `WEBSERVICE_STOCK_UPDATE` | `/call/inventory/stockUpdate` | Stock level changes (picks, receives, adjustments) | `MessageService.sendStockChangeMessage()` → **delegates to `StockChangeNotificationService.sendAfterCommit(List<StockChangeDto>)`** (SBDEV-2214) — which serializes the payload and calls `OmsNotificationService.sendAfterCommit(urlPath, payload, STOCK_UPDATE)` to defer the HTTP POST until after the caller transaction commits. | `List<StockChangeDto>` |
| `WEBSERVICE_STOCK_COUNT` | `/call/inventory/stockCountExport` | Scheduled stock export job | `StockSummaryExportJob` | Stock summary JSON — **SBDEV-2219:** payload shape unchanged, but `sendList(chunk)` is now invoked once per chunk (≤ split-size, hard-ceiled at 10K when split-flag off), not once per export. OMS receivers MUST tolerate multiple POSTs per export window. |
| `WEBSERVICE_STOCK_UPDATE` | `/call/inventory/stockUpdate` | Item/SKU data change in WMS | `ItemDataController` (internal trigger) | Stock update payload |

> **SBDEV-2217 cascade — Q9 wrap pattern.** After SBDEV-2217 made `MessageService.createMessage` declare `throws BusinessException` (checked), the failure-log success/failure paths in `StockSummaryExportJob.sendList` (lines 182, 193), `OmsNotificationService.sendAfterCommit/doSend`, and `ManageOrderService.customerOrder*` × 7 wrap the `messageService.createMessage` call in a local `try/catch BusinessException` that logs and swallows. Rationale: these paths are best-effort failure-log persistence invoked from `afterCommit()` callbacks and `forEach` lambdas where checked exceptions can't propagate. The original `IOException` / cron path's primary error semantics are preserved; only the secondary failure-of-the-failure-log is silenced. See SBDEV-2217 plan §10 Q9 for the full enumeration.

### 2.5.1 Metrics — `wms2.oms.notification.failed` (SBDEV-2214 Fix C)

`OmsNotificationService.doSend` increments a Micrometer `Counter` `wms2.oms.notification.failed` whenever the deferred HTTP POST throws or returns a non-2xx response. Tags:

- `tenant` — current tenant name from `TenantContext.getCurrentTenant()`, or `"unknown"` if the listener fires without a tenant context
- `processType` — the OMS process-type enum (e.g. `ORDER_BATCH_LOADED_TO_TRUCK`, `STOCK_UPDATE`, `ADVICE_ACCEPT_HUB_AND_SPOKE`, etc.)

Operators consume this counter via `/actuator/metrics/wms2.oms.notification.failed` or via Prometheus scrape. Suggested alert: any non-zero increment in a 5-min window pages the on-call engineer because every failed POST means OMS state is now drifting from WMS state for that tenant + process-type.

### 2.6 Facility Lookup (BillofladingService — WMS calls OMS to GET data)

| Sysprop key | Default OMS path | Direction | Java method | Purpose |
|------------|-----------------|-----------|-------------|---------|
| `WEBSERVICE_FACILITY_LIST_LOOKUP` | `/services/call/facilities` | WMS → OMS (GET) | `BillofladingService.getFacilities()` | Retrieve available destination facilities for BOL creation |

### 2.7 Admin / Connectivity Test

| Sysprop key | Default OMS path | Triggered by | Java method |
|------------|-----------------|-------------|-------------|
| `WEBSERVICE_TEST_CRM_CONNECTIVITY` | `/services/call/testPsd` | Admin action (manual) | `AdminActionController` (GET to OMS) |

### 2.8 Message Resend

`MessageService.resendMessage()` can replay any previously logged WMS→OMS message. It POSTs to the original `destination` URL stored in the `Message` record. This is the only retry path for `sendAfterCommit`-based notifications — there is no automatic retry on first failure for those sites.

For the **transactional outbox pilot site** (`BillofladingService.closeBOL`, SBDEV-2221), automatic retries ARE supported: `OutboxDispatcherJob` retries `FAILED_RETRY` rows with exponential backoff (`min(60s × 2^attempts, 1h)`) up to `app.outbox.dispatcher.max-attempts=5`. Terminal failures (4xx non-retryable or attempts exhausted) are logged at ERROR level with aggregate_type + aggregate_id + idempotency_key and metered at `wms2.outbox.dispatched{outcome=terminal}`. A `FAILED_TERMINAL` row also **holds** later same-aggregate events behind the SBDEV-2381 fail-closed gate; this stuck condition is surfaced by `wms2.outbox.stuck_aggregate{tenant,facility}` (+ `.oldest_age_seconds`) — per-tenant `MultiGauge`s sampled by the dispatcher (SBDEV-2381 Prereq #8 / plan 260614, sysprop-gated `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`, default OFF). Recovery: runbook `wms2-unstick-held-outbox-aggregate.md`.

> **² 2026-05-21 (plan 260521 Fix B — service-log gap):** `OutboxDispatchService` now calls `writeServiceLog()` after every dispatch outcome (2xx SENT, terminal failure, retry). This writes a `message` table row using `MessageService.createMessage()` in best-effort fashion (exceptions swallowed; metered at `wms2.outbox.message_log.failed`). All 9 outbox notification types (PICKING_STARTED, PICKING_FINISHED, plus the 7 SBDEV-2238 Phase-2 callers) now appear in the **Service Log** admin page — closing the gap where outbox-dispatched notifications were invisible in the UI while legacy `sendAfterCommit` callers wrote rows via `OmsNotificationService.doSend`.

---

## §3 `WEBSERVICE_BEHAVIOUR` Switch (v2-only)

**Sysprop key:** `WEBSERVICE_BEHAVIOUR`
**Default value:** `keep`
**Valid values:** `send` | `discard` | `keep`

This sysprop is defined in `WmsConstants` and its commented-out provisioning code exists in `UtilRestController`. It is **declared but not read at runtime** in the current v2 codebase — no production code path calls `getSysvalue(SYSTEM_PROPERTY_WEBSERVICE_BEHAVIOUR_KEY)`. It was intended as an emergency switch to control outbound callback behaviour:

| Value | Intended behaviour |
|-------|--------------------|
| `send` | Send all outbound callbacks immediately |
| `discard` | Drop all outbound callbacks silently |
| `keep` | Queue/keep messages for later sending |

**Current status:** The switch is not wired to any `httpRestService.post()` call. All outbound callbacks fire unconditionally. The switch exists as a future integration point or was used in a prior implementation that has since been replaced by direct `HttpRestService` calls.

---

## §4 v1 vs v2 Integration Delta

### 4.1 Inbound endpoints (OMS → WMS)

| Endpoint | v1 | v2 | Notes |
|----------|----|----|-------|
| `PUT /rest/order/create` | Yes | Yes | Same contract |
| `POST /rest/order/updatePriority` | Yes | Yes | Same contract |
| `POST /rest/order/cancelPositions` | Yes | Yes | Same contract |
| `POST /rest/order/finishedQA` | Yes | Yes | Same contract |
| `PUT /rest/order/finishedTransfer` | No | **Yes** | v2-only endpoint |
| `PUT /rest/advice/create` | Yes | Yes | Same contract |
| `PUT /rest/advice/createTransfer` | Yes | Yes | Same contract |
| `PUT /rest/advice/createHubAndSpoke` | Yes | Yes | Same contract |
| `PUT /rest/sku/create` | Yes | Yes | Same contract |
| `POST /rest/sku/update` | Yes | Yes | Same contract |
| `DELETE /rest/sku/delete` | Yes | Yes | Same contract |
| `POST /rest/stockcount/getStockCount` | Yes | Yes | Same contract |
| `GET /rest/stockcount/triggerStockCount` | Yes | Yes | Same contract |
| `POST /rest/report/getTransactionReport` | No | **Yes** | v2-only |
| `POST /rest/report/getTransactionDetailedReport` | No | **Yes** | v2-only |

### 4.2 Outbound callbacks (WMS → OMS)

| Callback (sysprop key) | v1 | v2 | Notes |
|------------------------|----|----|-------|
| `WEBSERVICE_ORDER_BATCH_HELD` | Yes | Yes | Same |
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | Yes | Yes | Same |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | Yes | Yes | Same |
| `WEBSERVICE_ORDER_BATCH_PICKING` | Yes | Yes | Same |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | Yes | Yes | Same |
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | No | **Yes** | v2-only; new lifecycle stage |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | No | **Yes** | v2-only; new lifecycle stage |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | Yes | Yes | v2 payload enriched with `sharedUniqueBolId`, `trackingDeviceId`, `sourceWarehouse`, `destinationWarehouse` |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | Yes | Yes | v2 fires from `cancelBatch` unconditionally; v1 gated by `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` flag |
| `WEBSERVICE_CLOSE_ADVICE` | Yes | Yes | Same |
| `WEBSERVICE_ACCEPT_TRANSFER` | Yes | Yes | Same |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | Yes | Yes | Same |
| `WEBSERVICE_STOCK_UPDATE` | Yes | Yes | Same |
| `WEBSERVICE_STOCK_COUNT` | Yes | Yes | Same |
| `WEBSERVICE_FACILITY_LIST_LOOKUP` | Yes | Yes | Same (GET) |
| `WEBSERVICE_TEST_CRM_CONNECTIVITY` | Yes | Yes | Same (GET) |

### 4.3 Infrastructure changes v1 → v2

| Aspect | v1 | v2 |
|--------|----|----|
| HTTP client | JAX-RS `Client` + `Invocation.Builder` | Spring `RestClient` (fluent API) |
| Timeouts | Not explicitly set (JAX-RS defaults) | 5 s connect, 15 s read |
| URL resolution | `losSyspropRepository.findSysvalueBySyskey()` (direct repo call) | `syspropService.getSysvalue()` (service layer, cached) |
| Auth headers | `Authorization: Basic` built manually in `getBuilder()` | `HttpRestService.applyHeaders()` centralises Basic auth + `x-tenant` header |
| `x-tenant` header | Yes (in `getBuilder()`) | Yes (in `applyHeaders()`) |
| Message logging | Per-call `MessageService.createMessage()` | Same pattern; `MessageProcessType` constants expanded |

---

## §5 Integration Failure Modes

### 5.1 Inbound (OMS → WMS2 call fails)

| Symptom | Likely cause | Where to look |
|---------|-------------|---------------|
| `400 Bad Request` with error map | Validation failure (`WebserviceBusinessExceptionClientSide`) on most endpoints | Response body — JSON error map with `error_code`, field name, offending DTO |
| `422 Unprocessable Entity` with error map | Validation failure on `/rest/sku/create` and `/rest/sku/update` (SBDEV-2235) | Same JSON error map shape; `/rest/sku/delete` stays 400 |
| `WRONG_FACILITY_CODE` error | `facility_code` in request does not match `MULTIWAREHOUSE_IDENTIFIER` sysprop | `sysprop` table, key `MULTIWAREHOUSE_IDENTIFIER` |
| `ENTITY_ALREADY_EXISTS` on advice create | Duplicate `reference_id` / `transfer_id` | `advice` table — check `externalid` column |
| `ENTITY_DOES_NOT_EXISTS` on order create | `client_id` not found in WMS | `client` table — `cl_nr` column |
| `WRONG_STATE` on `cancelPositions` / `finishedQA` | Order not in expected state | `customerorder.state` column; see state-machine-catalog |
| `500` / no response | Application exception or DB error | WMS application logs; Spring `RestExceptionHandler` |

### 5.2 Outbound (WMS2 → OMS callback fails)

| Symptom | Likely cause | Diagnostic steps |
|---------|-------------|-----------------|
| Callback never received by OMS | Sysprop URL not configured or blank | Check `sysprop` table for the relevant `WEBSERVICE_*` key; default values in `WmsConstants` use `oms-XXXXX.siteboss.net` placeholder |
| `Message` record shows status=FAILED, code=503 | Network/timeout or OMS returned error | `message` table — `status`, `statuscodeanswer`, `answer` columns; `destination` column shows the URL attempted |
| Auth error from OMS (401/403) | `OMS_API_USER` sysprop missing or wrong format (must be `user/password`) | `sysprop` table, key `OMS_API_USER`; also check `OMS_TENANT_ID` |
| `x-tenant` missing | `OMS_TENANT_ID` sysprop not set | `sysprop` table, key `OMS_TENANT_ID` |
| WMS-initiated cancel not reaching OMS | `WEBSERVICE_ORDER_BATCH_CANCELLED` URL not set | Check sysprop; also note `CustomerorderService.cancelOrder()` uses `WEBSERVICE_STOCK_COUNT_URL_KEY` for its cancellation notification — this is a known inconsistency |
| `PALLETIZED` / `LOADED_TO_TRUCK` callbacks not firing | These are v2-only — OMS must handle them; if OMS is v1 these endpoints may not exist | Verify OMS version; these callbacks did not exist in v1/wms-api |
| Callback fires but OMS rejects payload | Payload schema mismatch | Compare `BillOfLadingWebServiceDto` / `OrderBatchDto` with OMS expected contract; v2 `SHIPPED` payload has additional fields vs v1 |
| Parcel regresses Ready-to-QA → Picking; FINISHED arrives before STARTED | Outbox dispatched events out of aggregate order | Fixed by SBDEV-2381 (§2.1 note): dispatcher claims with the cross-tick `NOT EXISTS` gate + `ORDER BY next_attempt_at, id`, sorts the batch in-Java, and posts sequentially; each POST body carries `event_version = outbox id` so OMS can reject stale events. Inspect `outbox_message` `id` vs `aggregate_id` ordering for the affected parcel |
| Manual resend needed | `MessageService.resendMessage()` | Call via WMS admin UI or directly; re-POSTs to `message.destination`; creates a new `Message` record with `resent=true` on original |

### 5.3 `WEBSERVICE_BEHAVIOUR` gotcha

The `WEBSERVICE_BEHAVIOUR` sysprop is declared but **not consulted at runtime**. Setting it has no effect on outbound callback behaviour. All callbacks fire unconditionally. Do not rely on this switch to suppress callbacks in a v2 environment.

### 5.4 REST Inbound Idempotency (content-derived key, optional header)

Implemented in SBDEV-2222; updated in 260520 (content-derived key). OMS retries POST/PUT on network failure; WMS auto-derives the idempotency key from `SHA-256(method + "|" + path + "|" + rawBodyBytes)` — the `Idempotency-Key` header is **optional**. An explicit header overrides the auto-derived key (back-compat for OMS callers that still send one). A matching key+body hash replays the cached 2xx; a key+hash mismatch returns 409. Requests with body > 5 MB bypass dedup (DoS guard). Bridge-mode (`app.idempotency.bridge-mode=true`) replays pre-existing UUID-keyed rows during the UUID→SHA-256 transition window. Controlled by `app.idempotency.enforce=true` — set `false` to bypass in dev. Dedup rows are cleaned up after 7 days by `RestIdempotencyCleanupJob`.

---

## §6 OMS v2 Client-Side Implementation

Documents how `v2/oms-laravel-api` constructs and dispatches calls to the WMS REST endpoints described in §1. All evidence derived from `v2/oms-laravel-api/`.

### 6.1 Gateway Architecture

All WMS calls are funnelled through a single gateway class. Callers never construct HTTP requests directly.

```
oms-laravel-api (PHP / Laravel 12)
        │
        │  Illuminate\Support\Facades\Http  (wraps GuzzleHttp 7.x)
        ▼
app/Services/WmsApiService.php          ← single HTTP gateway (2 893 lines)
        │
        │  resolves base URL per facility  ──► app/Models/WmsUrlLut.php
        │  loads endpoint paths            ──► config/wms.php
        │  applies auth + tenant headers
        │  retries with exponential back-off
        ▼
WMS Java API  /rest/**  (IP-restricted, no auth headers)
             /v3/**    (Keycloak service-account JWT)
```

**Key files:**

| File | Role |
|------|------|
| `app/Services/WmsApiService.php` | Central HTTP client — every WMS call goes through here |
| `config/wms.php` | 25+ named endpoint paths; each individually env-overridable via `WMS_*_ENDPOINT` |
| `app/Models/WmsUrlLut.php` | `facility_code → base_url` + per-facility auth config; backed by `wms_url_lut` DB table |
| `app/Services/WmsConnectionStatusService.php` | Health-check / endpoint status monitor |

### 6.2 HTTP Client Details

| Property | Value |
|----------|-------|
| Library | `Illuminate\Support\Facades\Http` (GuzzleHttp 7.x under the hood) |
| Timeout | 30 s (connect + read) |
| Retry attempts | 3, exponential back-off: 1 s → 2 s → 4 s |
| Token refresh | On 401, clears cached service-account token and retries once |
| Default headers | `Content-Type: application/json`, `Accept: application/json`, `X-Tenant-ID: {tenant_name}`, `facility_code: {facility_code}` |

### 6.3 Facility URL Resolution

Base URL is resolved at runtime per request:

1. Look up row in `wms_url_lut` table for the active `facility_code`.
2. Fall back to env var `WMS_FACILITY_{FACILITY}_URL` if no DB row exists.
3. All HTTP calls are constructed as `{base_url}/{endpoint_path}` where `endpoint_path` comes from `config/wms.php`.

### 6.4 Authentication Modes

Auth type is stored per-facility in `wms_url_lut.config['auth_type']`:

| Auth type | Used for | Behaviour |
|-----------|----------|-----------|
| `none` | `/rest/**` endpoints | IP-restricted at network level; no auth headers sent |
| `basic` | Some internal environments | HTTP Basic credentials from facility config |
| `token` | Facility-specific token auth | Bearer token from facility config |
| `keycloak` | `/v3/**` endpoints | Keycloak service-account JWT via `KeycloakService`; auto-refreshes on 401 |

### 6.5 Endpoint Configuration (`config/wms.php`)

Named endpoints and their default WMS path:

| Config key | WMS path | HTTP method |
|------------|----------|-------------|
| `order_create` | `rest/order/create` | PUT |
| `qa_complete` | `rest/order/finishedQA` | POST |
| `order_cancel_positions` | `rest/order/cancelPositions` | POST |
| `order_update_priority` | `rest/order/updatePriority` | POST |
| `order_finished_transfer` | `rest/order/finishedTransfer` | PUT |
| `return_scanned` | `rest/order/returnScanned` | POST |
| `status_change` | `rest/order/statusChange` | POST |
| `multi_parcel_hold` | `rest/order/multiParcelHold` | POST |
| `advice_create` | `rest/advice/create` | PUT |
| `advice_create_transfer` | `rest/advice/createTransfer` | PUT |
| `advice_hub_and_spoke` | `rest/advice/createHubAndSpoke` | PUT |
| `sku_create` | `rest/sku/create` | PUT |
| `sku_update` | `rest/sku/update` | POST |
| `sku_delete` | `rest/sku/delete` | DELETE |
| `stockcount_get` | `rest/stockcount/getStockCount` | POST |
| `stockcount_trigger` | `rest/stockcount/triggerStockCount` | GET |
| `inventory_adjust` | `rest/inventory/adjust` | POST |
| `shipping_label_sync` | `rest/shipping/labelSync` | POST |
| `transaction_report_summary` | `rest/report/getTransactionReport` | POST |
| `transaction_report_detailed` | `rest/report/getTransactionDetailedReport` | POST |
| `client_create` | `rest/client/create` | POST |
| `client_update` | `rest/client/update` | POST |
| `get_parcel` | `rest/parcel/{parcel_id}` | GET |
| `printer_search_by_type` | `/v3/printer/search/findByType` | GET |

Each path is individually overridable via a matching `WMS_*_ENDPOINT` env var.

### 6.6 OMS Laravel Caller → WMS Endpoint Map

| WMS endpoint (§1 reference) | OMS Laravel caller |
|-----------------------------|--------------------|
| `PUT /rest/order/create` | `BatchProcessingService::createBatch()` |
| `POST /rest/order/updatePriority` | `OrderProcessingService::updatePriority()` |
| `POST /rest/order/cancelPositions` | `OrderProcessingService::cancelOrders()` |
| `POST /rest/order/finishedQA` | `QaWorkflowService::notifyWmsQaComplete()` |
| `PUT /rest/order/finishedTransfer` | `LegacyTransferCloseService::close()` |
| `POST /rest/order/returnScanned` | `QaReturnService` |
| `POST /rest/order/statusChange` | `OrderProcessingService` |
| `POST /rest/order/multiParcelHold` | `ParcelService` |
| `PUT /rest/advice/create` | `ReturnProcessingService::createAdvice()` |
| `PUT /rest/advice/createTransfer` | `LegacyInventoryTransferService` |
| `PUT /rest/advice/createHubAndSpoke` | `TransferService` (hub distribution) |
| `PUT /rest/sku/create` | `ProductController`, `InventoryService` |
| `POST /rest/sku/update` | `ProductController`, `InventoryService` |
| `DELETE /rest/sku/delete` | `ProductController`, `InventoryService` |
| `POST /rest/stockcount/getStockCount` | `InventoryService::getStockCount()` |
| `GET /rest/stockcount/triggerStockCount` | `InventoryService::triggerStockExport()` |
| `POST /rest/report/getTransactionReport` | `TransactionReportService` |
| `POST /rest/report/getTransactionDetailedReport` | `TransactionReportService` |
| `GET /v3/printer/search/findByType` | `WmsApiService::getWmsPrinters()` |

### 6.7 Request / Response Contract

- **Request body**: JSON array `[{…}]` for most endpoints — matches the WMS Java `@RequestBody List<Dto>` signature. `GET` endpoints use query parameters instead.
- **Response shape**: `{ status, message, data, timestamp }`. `WmsApiService` inspects `status` and throws `WmsException` on any non-success value.
- **4xx errors**: `WmsException` with user-facing message (non-retryable).
- **5xx errors**: `WmsException` with `temporary=true` flag set; eligible for retry.
- **Connection errors**: Retried with exponential back-off (see §6.2).

### 6.8 Service Registration

`WmsApiService` is registered as a singleton via the Laravel service container (service provider). It is injected by constructor into `BatchProcessingService`, `TransactionReportService`, and legacy services, and resolved ad-hoc via `app(WmsApiService::class)` in some controllers and queued jobs.

---

*Source files verified: `controller/rest/OrderRestController.java`, `AdviceRestController.java`, `SkuRestController.java`, `StockCountRestController.java`, `TransactionReportRestController.java`, `AbstractRestController.java`, `rest/UtilRestController.java`; `controller/AdviceController.java`; `service/ManageOrderService.java`, `AdviceService.java`, `BillofladingService.java`, `CustomerorderBatchService.java`, `CustomerorderService.java`, `MessageService.java`, `HttpRestService.java`, `WmsConstants.java` (lines 873–909); `controller/ItemDataController.java`, `AdminActionController.java`; `schedulejob/StockSummaryExportJob.java`. v1 delta verified against `v1/wms-api` equivalents. OMS v2 client verified against `v2/oms-laravel-api/app/Services/WmsApiService.php`, `config/wms.php`, `app/Models/WmsUrlLut.php`, `app/Services/WmsConnectionStatusService.php`. SBDEV-2381 verified against `repository/OutboxMessageRepository.java` (`findAndClaimPending`), `service/job/OutboxDispatchService.java` (`dispatchBatch`, `dispatchOne`), `service/CustomerorderBatchService.java` (`finalizeClubLine`, `runClubLine`), `service/ManageOrderService.java` (retired shims), `service/job/ReleaseOrderJobService.java`, `service/PickingorderBusinessService.java` (`confirmPick`), and migration `db/v1-to-v2-onboarding/schema/V2.1.14__add_outbox_aggregate_order_index.sql` (2026-06-01).*
