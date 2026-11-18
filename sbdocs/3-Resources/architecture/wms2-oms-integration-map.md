---
type: architecture
status: active
system: wms2
last_verified: 2026-11-11
---

# WMS2 ↔ OMS Integration Map

Reference for developers diagnosing OMS→WMS2 call failures, missing WMS2→OMS callbacks, or adding new integration points. All evidence derived from `v2/wms2-api/src/main/java/`.

---

## §1 Inbound — OMS Calls WMS2

All inbound REST endpoints extend `AbstractRestController`. Its `validateWarehouse(dto)` checks `facility_code` against the `MULTIWAREHOUSE_IDENTIFIER` sysprop, but **only the handlers that call it**: `order/{create,updatePriority,cancelPositions,finishedQA,updateShipper}`, `advice/create`, `sku/{create,update,delete}`, `report/*` and `stockcount/getStockCount`. `createHubAndSpoke` checks `destination_warehouse` inline instead (`AdviceRestController.java:856`). `order/finishedTransfer`, `advice/createTransfer`, `stockcount/triggerStockCount`, `printer/findByType` and `unitload/state/{labelId}` perform no facility check. Base path is `/rest/`.

**Authentication: none, by decision.** `/rest/**` is `permitAll` in `SecurityConfiguration.filterChain` (rule B, `SecurityConfiguration.java:149-154`); only `/v3/**` and the other app surfaces go through the OAuth2/Keycloak JWT resource server. The `/rest/**` surface is internal-only WMS↔OMS traffic and JWT on it is deliberately deferred (owner decision 2026-08-27) — it is not a live exposure and is not a drift to fix. The OMS client likewise sends no Keycloak token to `/rest/*` URLs (OMS `config/wms.php`: `applyAuthentication` keys off the URL *not* containing `/rest/`).

### 1.1 OrderRestController — `/rest/order`

| Method | HTTP | Path | Request body | Success code | Purpose |
|--------|------|------|-------------|-------------|---------|
| `create` | PUT | `/rest/order/create` | `List<OrderBatchDto>` | 204 | Create outbound order batches with positions |
| `updatePriority` | POST | `/rest/order/updatePriority` | `List<OrderBatchDto>` | 204 | Change priority (1–5) of existing order batches |
| `cancelPositions` | POST | `/rest/order/cancelPositions` | `List<OrderBatchDto>` | 200 | Cancel individual orders within a batch |
| `finishedQA` | POST | `/rest/order/finishedQA` | `List<OrderBatchDto>` | 204 | Mark orders as QA-complete (sets parcel label, packages order); silently discards CLUB and TRANSFER type batches |
| `updateShipper` | POST | `/rest/order/updateShipper` | `List<OrderBatchDto>` | 200 + `{status, updated[], unchanged[], closed[]}` | SBDEV-3841 / ST#1518: OMS moved an in-warehouse parcel onto another ship method (`shippers_id`; optional `fulfillment_type`). All positions validated first, written in one transaction; finished/cancelled orders are reported under `closed`, not failed. Service-log process type `ORDER_BATCH_UPDATE_SHIPPER` (`OrderRestController.java:963`) |
| `finishedTransfer` | PUT | `/rest/order/finishedTransfer` | `AcceptTransferDto` | 204 (400 + error map when the service refuses; unknown `transferId` → `EntityNotFoundException` via the /rest advice chain) | Signal that an outbound transfer BOL has been received at the destination; delegates to `BillofladingService.finishTransfer()` (accepts any non-terminal BOL — see [wms2-transfer-order-workflow.md](../workflows/wms2-transfer-order-workflow.md)). No `facility_code` check (`OrderRestController.java:1077`) |

**Key validation rules for `create`:**
- `batch_id`, `priority` (1–5), `client_id`, `positions` are all required.
- `facility_code` must match the warehouse's `MULTIWAREHOUSE_IDENTIFIER` sysprop.
- Duplicate `parcel_external_number` values (against existing non-cancelled orders and unitloads) are rejected.

### 1.2 AdviceRestController — `/rest/advice`

| Method | HTTP | Path | Request body | Success code | Purpose |
|--------|------|------|-------------|-------------|---------|
| `create` | PUT | `/rest/advice/create` | `List<AdviceDto>` | 204 (200 when a RETURN advice auto-receive produced a warning; `AdviceRestController.java:606`) | Create inbound advice (purchase-order / delivery notice) |
| `createTransfer` | PUT | `/rest/advice/createTransfer` | `BillOfLadingWebServiceDto` | 204 | Create a TRANSFER-type advice (intracompany stock move); exactly one order per batch enforced |
| `createHubAndSpoke` | PUT | `/rest/advice/createHubAndSpoke` | `BillOfLadingWebServiceDto` | 204 | Create a HUB_AND_SPOKE advice; `destination_warehouse` must match this WMS's identifier |
| `reopen` | POST | `/rest/advice/reopen` | `List<Advice>` | — | Stub — throws `RuntimeException("method not supported")`. Removed by SBDEV-4115 (route becomes 404) ✓ merged(SBDEV-4115: #664 938c9fe2, 2026-11-11) |

### 1.3 SkuRestController — `/rest/sku`

| Method | HTTP | Path | Request body | Success code | Validation failure | Purpose |
|--------|------|------|-------------|-------------|-------------------|---------|
| `create` | PUT | `/rest/sku/create` | `List<SkuDto>` | **200** + `item_ids` (SBDEV-2624; was 204) | **422** (SBDEV-2235) | Create new SKU/item-data records |
| `update` | POST | `/rest/sku/update` | `List<SkuDto>` | **200** + `item_ids` (SBDEV-2624; was 204) | **422**, incl. 108 rename precondition / 109 concurrent modification | Update SKU records; renames a SKU in place when `previous_sku` / `facility_item_id` identify the row |
| `delete` | DELETE | `/rest/sku/delete` | `List<SkuDto>` | 204 | 400 (incl. 108 `… (delete)` when the row found by `facility_item_id` holds another code) | Delete SKU records |

> **SBDEV-2624 contract (2026-10):**
> - New optional `SkuDto` fields `facility_item_id` (per-facility `itemdata.id`, client-scoped) and `previous_sku`.
> - Create and update return `200 {"status","item_ids":{sku:id}}`, which the OMS records in `product_wms_item.wms_item_id` per facility.
> - On a 422 whose description starts with a 108/109 marker, the OMS resends once (guarded). The prefixes are pinned cross-repo by `verify-SBDEV-2624-sku-rename-in-place-oms-wms-sync.sh`.
> - The global `product.wms_item_id` / inbound `item_id` is no longer read or written by the OMS.
> - **Deploy wms2 first.** Full rules: `design/wms2-rest-api-reference.md` §4.2 and the plan `sbdocs/1-Projects/wms2/plan/SBDEV-2624-sku-rename-in-place-oms-wms-sync.md`.

> **SBDEV-2235 OMS contract change:** `/rest/sku/create` and `/rest/sku/update` now return `422 UNPROCESSABLE_ENTITY` on validation failure (previously 400). `/delete` remains 400. OMS-side parser must be updated to accept 422 before this ships. Coordinate with David Oppenheim.

### 1.4 StockCountRestController — `/rest/stockcount`

| Method | HTTP | Path | Request body / params | Success code | Purpose |
|--------|------|------|----------------------|-------------|---------|
| `getStockCount` | POST | `/rest/stockcount/getStockCount` | `StockCountRequest` (JSON) | 200 | Query current stock count for given SKUs/locations |
| `triggerStockCount` | GET | `/rest/stockcount/triggerStockCount` | query params | 200 | Manually trigger a full stock-count export back to OMS |

### 1.5 TransactionReportRestController — `/rest/report`

| Method | HTTP | Path | Request body | Success code | Purpose |
|--------|------|------|-------------|-------------|---------|
| `getTransactionReport` | POST | `/rest/report/getTransactionReport` | `WarehouseTransactionReportRequest` | 200 | Summary transaction report for a date range |
| `getTransactionDetailedReport` | POST | `/rest/report/getTransactionDetailedReport` | `WarehouseTransactionDetailedReportRequest` | 200 | Detailed line-item transaction report |

### 1.6 PrinterRestController and UnitloadRestController — read-only lookups

| Method | HTTP | Path | Request | Success code | Purpose |
|--------|------|------|---------|-------------|---------|
| `findByType` | GET | `/rest/printer/findByType?type=` | query param `type` | 200 + `List<Printer>` | Printer lookup for the OMS QA flow (`PrinterRestController.java:41`). The Keycloak-gated Spring Data REST equivalent is `/v3/printer/search/findByType` |
| `getToteState` | GET | `/rest/unitload/state/{labelId}` | path `labelId` | 200 + `ToteStateDto` (always 200 for a well-formed label — an unknown label answers `found: false`); 400 for a blank label | Current state of a tote — a tote is reusable the moment QA completes, so only WMS can say what it is doing now (`UnitloadRestController.java:44`, SBDEV-2742) |

**Enumeration (2026-11-11, develop `df30fa62`):** `grep -E '@(Get|Post|Put|Delete)Mapping|@RequestMapping' controller/rest/*RestController.java` finds **19 inbound `/rest/**` endpoints** across 7 controllers (order 6, advice 4 incl. the `reopen` stub, sku 3, stockcount 2, report 2, printer 1, unitload 1). A 20th `/rest` route, `POST /rest/stockcount/sendDummyMessageStockCountList`, lives in `MessageDummyController` outside the `*RestController` naming (see the REST reference §10.2). `UtilRestController` is in the same package but is annotated `@Service`, not `@RestController`, and has no `/rest` prefix: its 9 `@RequestMapping` methods (28 mapping annotations in the package minus 19) are not OMS endpoints. (Command: `grep -hE '^\s*@(Get|Post|Put|Delete)Mapping|method = RequestMethod' *RestController.java | wc -l` = 28.)

---

## §2 Outbound — WMS2 Calls OMS

All outbound calls are made via `HttpRestService` (Spring `RestClient`, 5 s connect / 15 s read timeout). Each call:
1. Looks up the target URL from the tenant's `sysprop` table using the key shown below.
2. Posts JSON (or GETs) with `Authorization: Basic <OMS_API_USER>` and `x-tenant: <OMS_TENANT_ID>` headers.
3. Logs a `Message` record (WMS→OMS direction) with status SENT or FAILED.

Failed calls on the `sendAfterCommit` path (§2.1 HELD / TOTE_ASSIGNED / PALLETIZED / LOADED_TO_TRUCK, and STOCK_UPDATE) log the message record with status=FAILED and HTTP code 503 and **do not retry automatically** — a manual resend is possible via `MessageService.resendMessage()`. Every other notification goes through the transactional outbox, which does retry (§2.8). The full enumeration of both paths is §2.9.

### 2.1 Order Lifecycle Callbacks (ManageOrderService)

> **SBDEV-2214 (2026-05-10):** the ManageOrderService callbacks below now POST to OMS via `omsNotificationService.sendAfterCommit(urlPath, payload, processType)` — registered as a `TransactionSynchronization.afterCommit` listener. The HTTP POST fires only AFTER the surrounding transaction commits; if the caller transaction rolls back, the POST never happens. `HttpRestService` and `MessageService` are no longer constructor-injected into `ManageOrderService`. The audit `Message` row (SENT / FAILED) is now written by `OmsNotificationService.doSend` on the listener side, not inline at the call-site.
>
> **Current state (verified 2026-11-11, develop `df30fa62`):** only **4** `ManageOrderService` methods still use `sendAfterCommit` — `customerOrderOnHold` (`:105`), `customerOrderToteAssigned` (`:187`), `customerOrderPalletized` (`:345`), `customerOrderLoadedToTruck` (`:385`). The other three (RELEASED, PICKING_STARTED, PICKING_FINISHED) were retired and deleted (SBDEV-2381 / SBDEV-3102 D2) and ride the outbox; the HELD, TOTE_ASSIGNED, PALLETIZED and LOADED_TO_TRUCK rows below are the only ones on `sendAfterCommit` here. Repo-wide, `omsNotificationService.sendAfterCommit` call-sites are those 4 plus `StockChangeNotificationService:47` (STOCK_UPDATE) — `grep -rn 'omsNotificationService.sendAfterCommit(' src/main/java` returns 5 code hits (plus one javadoc mention in `OutboxDispatchService:281`). Every other WMS→OMS notification is `outboxService.enqueue` (19 call-sites, enumerated in §2.9).

| Sysprop key | Default OMS path | Triggered by | Java method | Payload |
|------------|-----------------|-------------|-------------|---------|
| `WEBSERVICE_ORDER_BATCH_HELD` | `/services/call/held` | Warehouse operator puts batch on hold | `ManageOrderService.customerOrderOnHold()` | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `/services/call/readytopick` | Batch released to picking queue | Every producer enqueues on the outbox: the release job (`ReleaseOrderJobService.releaseOrder()`; formerly `ManageOrderService.customerOrderReleaseForPicking()`, retired to a no-op shim by SBDEV-2381 and deleted by SBDEV-3102 slice D2, 2026-10-21), club finalize (`CustomerorderBatchService.finalizeClubLine()`) ² and the BOL transfer path (`BillofladingService.transferOrder()`, gated by the transfer-picking-notifications sysprop). Only the job builds with `buildReleasedForPickingPayloadJson`; club finalize and BOL transfer send the STARTED payload (`buildPickingStartedPayloadJson`) | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `/services/call/assignedToteID` | Tote assigned to a picker for the batch | `ManageOrderService.customerOrderToteAssigned()` | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_PICKING` | `/services/call/picking` | Picking started on the batch | `PickingorderBusinessService.confirmPick()` → outbox ² (SBDEV-2381: skips the enqueue when the CO already advanced — `state≥PICKED` or `pickingconfirmationsent`) | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `/services/call/finishedPicking` | All items picked for the batch | `PickingorderBusinessService.finishPickingOrder()` → outbox ² | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `/services/call/palletized` | Orders palletized onto outbound pallet | `ManageOrderService.customerOrderPalletized()` | `OrderBatchDto[]` |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `/services/call/loadedToTruck` | Pallet loaded to truck (BOL context) | `ManageOrderService.customerOrderLoadedToTruck()` | `OrderBatchDto[]` |

> ² **2026-05-20 (picking-finished fix):** `PICKING_STARTED` (`confirmPick`) and `PICKING_FINISHED` (`finishPickingOrder`) previously triggered a nested `registerSynchronization` inside `OmsNotificationService.sendAfterCommit`, which Spring silently discarded after the TX committed (double-afterCommit bug). Both `PickingorderBusinessService` call-sites now call `outboxService.enqueue(OutboxMessage)` directly inside the open `@Transactional("tenantTransactionManager")` — the outbox row commits atomically with the state change. ~~`ManageOrderService.customerOrderPickingStarted()` and `customerOrderPicked()` are retained (`@Deprecated`) for `CustomerorderBatchService` batch-level callers which still use the `sendAfterCommit` path.~~ **Superseded by SBDEV-2381 (2026-06-01):** `customerOrderReleaseForPicking`, `customerOrderPickingStarted`, and `customerOrderPicked` no longer dispatch: SBDEV-2381 retired them to no-op shims and SBDEV-3102 D2 (2026-10-21) deleted them. The club-batch RELEASE/PICKING_STARTED/PICKING_FINISHED notifications they previously served are now enqueued in-tx per CO inside `CustomerorderBatchService.finalizeClubLine` (see the SBDEV-2381 note below). **`OmsNotificationService.sendAfterCommit` guard upgraded:** now checks `isSynchronizationActive() && isActualTransactionActive()` before registering; if the caller is already inside an `afterCommit` callback (`syncActive=true, txActive=false`), the POST is issued synchronously instead of being discarded. **Safety net:** `MobilePickingService.releaseRegularPickingOrder` Case 1 calls `PickingorderBusinessService.reenqueuePickingFinishedIfMissing(pickingOrder)` to recover any CO with `state≥PICKED` AND `pickingconfirmationsent=false`.

> **SBDEV-2381 (2026-06-01) — outbox ordering + club-line unify:** Outbox dispatch was sending WMS→OMS parcel-status events out of order (the `UPDATE … RETURNING` heap order is not insertion order; DB-verified 43% of PICKING_STARTED/FINISHED pairs inverted), regressing parcels Ready-to-QA → Picking. Five changes:
> - **Claim query** (`OutboxMessageRepository.findAndClaimPending`): now `ORDER BY next_attempt_at, id` plus a **fail-closed cross-tick `NOT EXISTS` gate** — a row is not claimed while a lower-`id` sibling of the *same aggregate* is still `PENDING/FAILED_RETRY/IN_FLIGHT/FAILED_TERMINAL` (a later event is HELD if its predecessor is unsent **or** terminally failed — prevents FINISHED-without-STARTED). Outer `UPDATE … RETURNING *` retained.
> - **Dispatch** (`OutboxDispatchService.dispatchBatch`): the claimed batch is sorted in Java by `(nextAttemptAt, aggregateType, aggregateId, id)` before a **sequential** POST loop (no `parallelStream`). Ordering key is the existing `id` BIGSERIAL — monotonic per aggregate because STARTED commits in an earlier CO-row-locked tx than FINISHED; no synthetic sequence column was added.
> - **`event_version`** (`OutboxDispatchService.dispatchOne`): injects `event_version = outbox row id` as a top-level field in the OMS POST **body** (Jackson; verbatim fallback for non-object payloads). Additive; lets OMS reject stale/out-of-order events (OMS-side rejection is a paired ticket).
> - **Club-line unify** (`CustomerorderBatchService`): the 3 former Phase-4 fire-and-forget `sendAfterCommit` notifications (RELEASE/STARTED/FINISHED) are removed from `runClubLine` Phase 4 and now `outboxService.enqueue(...)` **per-CO, in-tx, inside `finalizeClubLine`** (ascending ids RELEASE<STARTED<FINISHED). A failed enqueue now ROLLS BACK finalize (atomic transactional outbox) instead of being swallowed.
> - **Retired dispatchers** (`ManageOrderService`): `customerOrderReleaseForPicking`, `customerOrderPickingStarted`, `customerOrderPicked` were retired to deprecated no-op shims (return `false`); SBDEV-3102 slice D2 (2026-10-21) deleted the shims outright — no production caller remained. `ReleaseOrderJobService.releaseOrder` migrated its RELEASE notification onto the outbox. `PickingorderBusinessService.confirmPick` gained the backward guard (skip PICKING_STARTED enqueue when CO already advanced).
> - **Migration:** `V2.1.14__add_outbox_aggregate_order_index.sql` — `CREATE INDEX CONCURRENTLY` (non-transactional, `-- flyway:executeInTransaction=false`, DROP-IF-EXISTS rerun guard) on `outbox_message (aggregate_type, aggregate_id, id, status)`. The `outbox_message` table itself is now created by **V2.1.11** (renamed from V1.1.16 by develop's V2.1.x renumber); latest migration before this was V2.1.13.

### 2.2 Shipment / BOL Callback (BillofladingService)

| Sysprop key | Default OMS path | Triggered by | Java method | Payload |
|------------|-----------------|-------------|-------------|---------|
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `/services/call/finishedShipping` | BOL closed (`closeBOL`) | `BillofladingService.closeBOL()` | `BillOfLadingWebServiceDto` (includes BOL ID, pallets, orders, seal, truck, carrier, shared unique BOL ID, tracking device ID, transfer ID, source/destination warehouse). **One BOL is 1..N POSTs:** a REGULAR or HUB_AND_SPOKE BOL with more than K parcels (`WMS_BOL_SHIPPED_OMS_CHUNK_SIZE`, default 40, clamp 60) is sent as N chunk rows (`BILL_OF_LADING_CHUNK`, lane CLUB), each with the full header, the same `bol_id`, and `chunk_index`/`chunk_count`; transfers and BOLs with ≤ K parcels stay one `BILL_OF_LADING` row with an unchanged payload (`BillofladingService.java:835-907`, `enqueueBolShippedNotification`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |

> **SBDEV-3672 (2026-10-16):** per-BOL delivery status (`GET /v3/billOfLading/omsNotificationStatus/{id}`) and an operator requeue of failed rows (`POST /v3/billOfLading/requeueOmsNotification/{id}`). The requeue's Service Log audit row (`ORDER_BATCH_SHIPPED_REQUEUE`, destination `'N/A'`) is never sent to OMS. Full behaviour: [wms2-bol-truck-loading-workflow.md §6.5](../workflows/wms2-bol-truck-loading-workflow.md) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

> **SBDEV-2221 pilot (2026-05-17):** `BillofladingService.closeBOL` no longer calls `omsNotificationService.sendAfterCommit`. Instead it calls `OutboxService.enqueue(OutboxMessage)` **inside the still-open BOL transaction** — the outbox row and the BOL state change commit atomically. The `OutboxDispatcherJob` then polls `outbox_message` and POSTs to OMS via `HttpRestService.postWithIdempotencyKey`. It runs **two lanes**: DEFAULT (advisory lock `100008L`, cron `app.cron.outbox-dispatcher`) and CLUB (lock `100009L`, `app.cron.outbox-dispatcher-club`, added for club/BOL-chunk rows so a club run cannot starve pick/pack notifications). The `@Scheduled` fallback is `*/15 * * * * *` in code, but `application.properties` sets **both** lanes to `*/3 * * * * *` (`application.properties:219,222`), so the effective cadence is every 3 s, batch size 25 (`app.outbox.dispatcher.batch-size=25`). Serialisation failure now throws `FacadeException` and rolls back the BOL state change (was silently swallowed before). Five additional call-sites were migrated in SBDEV-2238 Phase-2 (2026-05-19): `CustomerorderService.cancelOrder`, `CustomerorderBatchService.cancelBatch` *(deleted 2026-09-14, SBDEV-3354)*, `AdviceService.acceptHubAndSpokeAdvice`, `AdviceService.close`, and `AdviceService.acceptTransferAdvice` — see §2.3 and §2.4 notes. *(Historical — the "remaining 11 `sendAfterCommit` call-sites" figure is superseded: as of 2026-11-11 only 5 `omsNotificationService.sendAfterCommit` call-sites remain, §2.1 "Current state".)*

### 2.3 Cancellation Callbacks

| Sysprop key | Default OMS path | Triggered by | Java method | Condition |
|------------|-----------------|-------------|-------------|-----------|
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `/services/call/cancelPosition` | Individual order cancelled (WMS- or OMS-initiated) | `CustomerorderService.cancelOrder()` direct branch → `enqueueCancellationSignal` | Unconditional once the order is CANCELED; reads `WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` — see note *(Condition cell corrected 2026-09-26, SBDEV-3362; it said "only when `cancellationFromWithinWMS=true`" and "uses `WEBSERVICE_STOCK_COUNT_URL`", both refuted by the note below)* |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `/services/call/cancelPosition` | PACKED/PALLETIZED order force-cancelled (WMS-initiated, or OMS-initiated pre-QA CLUB) | `CustomerorderService.forceCancelOrder()` → `enqueueCancellationSignal` | Since SBDEV-3362 (2026-09-26); gated on the order reaching CANCELED. Before it, force-cancel sent **nothing** |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `/services/call/cancelPosition` | Deferred cancel of an already-picked order | `PickingorderBusinessService` | `aggregate_type='CUSTOMER_ORDER'`, same process type |
| `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` | _(flag, not URL)_ | Global toggle for cancel callbacks | — | Default `false`. **Neither version reads the key** (v1 `origin/develop`, verified 2026-10-06 (SBDEV-3373): declaration in `WmsConstants` plus a commented-out seed line in `UtilRestController`, no reader); v2 enqueues unconditionally. The v2 Java constant is gone from develop (`grep -rn ORDER_BATCH_CANCELLED_ACTIVATED src/main/java` → no hits at `df30fa62`); `V2.2.37__delete_dead_cancellation_sysprops.sql` deletes the DB row (PR #466, merged to develop `a0b2c07f`). ⚠ unverified 2026-11-11: whether `V2.2.37` has reached UAT/PRD (last recorded: applied on dev 2026-10-07; no DB checked this pass). |

⚠ **CORRECTED 2026-09-14 (SBDEV-3354).** This table previously carried a row reading
*"Batch cancelled in WMS → `CustomerorderBatchService.cancelBatch()` → Always when a batch is
cancelled"*, and the activation row said v2 *"sends unconditionally via `cancelBatch`"*. **`cancelBatch`
had no route and no caller and has been deleted.** A batch cancel arrives at
`OrderRestController.cancelPositions` (`POST /rest/order/cancelPositions`), which loops
`CustomerorderService.cancelOrder` — so it produces **N per-order enqueues, never one batch-scoped
message**.

⚠ **`process_type` alone does not identify the producer.** Every producer row above (the flag row is
not a producer) writes `ORDER_BATCH_CANCELLED_FROM_WMS`, and every surviving producer writes
`aggregate_type = 'CUSTOMER_ORDER'` — so neither column tells the direct, force and deferred paths apart. The `CUSTOMER_ORDER_BATCH` variant died with `cancelBatch`. *Deriving method:*
`git grep -n "ORDER_BATCH_CANCELLED_FROM_WMS" origin/develop -- 'src/main/**'` (2026-09-14). Runtime
corroboration: Hydra PRD `outbox_message` holds **0** rows of the `CUSTOMER_ORDER_BATCH` pair against a
positive control of 3 rows of the same process type under `CUSTOMER_ORDER`; *blind spot:* that table
only reaches back to 2026-07-13.

> **Note on CustomerorderService cancel** *(corrected 2026-09-15, SBDEV-3332 — the previous version of
> this note was wrong on both of its claims)*: `cancelOrder()` reads
> `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY`, **not** the stock-count sysprop, and it
> enqueues **unconditionally** — `cancellationFromWithinWMS` does not gate the notification at all (it
> gates only whether a PACKED/PALLETIZED order is eligible for `forceCancelOrder`). There is no
> "reused stock-count URL" inconsistency to carry forward. *Deriving method:*
> `grep -n "STOCK_COUNT" src/main/java/net/aim_ai/wms/service/CustomerorderService.java` returns
> nothing; repo-wide, `WEBSERVICE_STOCK_COUNT` has exactly three live readers and none is a cancel
> path (`StockSummaryExportJob`, `MessageDummyController`, plus a commented-out seed line in
> `UtilRestController`).

> **SBDEV-3332 (2026-09-15) — the cancel emitters are deduplicated against each other.** Both
> `CustomerorderService.enqueueCancellationSignal` (for `cancelOrder` and, since SBDEV-3362,
> `forceCancelOrder`) and `PickingorderBusinessService.cleanUpCancelledOrder` set
> `idempotencyKey = WmsConstants.CANCELLED_IDEMPOTENCY_KEY_PREFIX + customerOrder.getId()`
> (`"CO-CANCELLED-<id>"`). Because `outbox_message.idempotency_key` carries
> `uk_outbox_message_idempotency_key UNIQUE`, a second `ORDER_BATCH_CANCELLED_FROM_WMS` for one
> customer order is now a constraint violation rather than a second message to OMS. The key is
> deliberately **shared** by every cancel path: the invariant is one cancellation signal per customer
> order, and each path is an emitter of that one business event, not of its own. ⚠ The protection is bounded by
> outbox retention — `OutboxDispatchService` deletes SENT rows older than the retention window
> (`repo.deleteSentOlderThan`), after which the key is free again. Same bound applies to the sibling
> `CO-PICKED-` / `CO-PICKING-STARTED-` / `CO-PICKING-RELEASED-` keys.

> **SBDEV-2238 Phase-2 (2026-05-19)** *(historical — `cancelBatch` was deleted 2026-09-14, SBDEV-3354; read the `cancelBatch` half of this note as a record of what that method did, not as live behaviour)*: `CustomerorderBatchService.cancelBatch` and `CustomerorderService.cancelOrder` no longer call `omsNotificationService.sendAfterCommit`. Both now call `outboxService.enqueue(OutboxMessage)` inside the still-open tenant transaction — the outbox row and the state change commit atomically. `aggregateType` is `CUSTOMER_ORDER_BATCH` (for `cancelBatch`) and `CUSTOMER_ORDER` (for `cancelOrder`). Serialisation failure throws `FacadeException` and rolls back the state change. `UtilRestController.resetOrdersInReleasedStatus` (admin loop) wraps `cancelOrder` in try/catch so a serialisation failure logs-and-continues rather than aborting the loop.

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
| `WEBSERVICE_STOCK_COUNT` | `/call/inventory/stockCountExport` | Scheduled stock export job (also `GET /rest/stockcount/triggerStockCount`; `MessageDummyController` posts a dummy payload to the same URL) | `StockSummaryExportJob` (`:575`) | Stock summary JSON — **SBDEV-2219:** payload shape unchanged, but `sendList(chunk)` is now invoked once per chunk (≤ split-size, hard-ceiled at 10K when split-flag off), not once per export. OMS receivers MUST tolerate multiple POSTs per export window. |
| `WEBSERVICE_STOCK_UPDATE` | `/call/inventory/stockUpdate` | Operator-triggered resend of one item's stock counts (`GET /v3/itemData/sendStockUpdate/{itemdataid}`, `@RequiresFunction(WEB_UI_VIEW_ITEM_DATA)`) — direct `httpRestService.post`, not deferred | `ItemDataController.sendStockUpdate` (`ItemDataController.java:110-127`) | `List<StockCountDto>` |

> **SBDEV-2217 cascade — Q9 wrap pattern.** After SBDEV-2217 made `MessageService.createMessage` declare `throws BusinessException` (checked), the failure-log success/failure paths in `StockSummaryExportJob.sendList` (lines 182, 193), `OmsNotificationService.sendAfterCommit/doSend`, and `ManageOrderService.customerOrder*` × 7 wrap the `messageService.createMessage` call in a local `try/catch BusinessException` that logs and swallows. Rationale: these paths are best-effort failure-log persistence invoked from `afterCommit()` callbacks and `forEach` lambdas where checked exceptions can't propagate. The original `IOException` / cron path's primary error semantics are preserved; only the secondary failure-of-the-failure-log is silenced. See SBDEV-2217 plan §10 Q9 for the full enumeration.

### 2.5.1 Metrics — `wms2.oms.notification.failed` (SBDEV-2214 Fix C)

`OmsNotificationService.doSend` increments a Micrometer `Counter` `wms2.oms.notification.failed` whenever the deferred HTTP POST throws or returns a non-2xx response. Tags:

- `tenant` — current tenant name from `TenantContext.getCurrentTenant()`, or `"unknown"` if the listener fires without a tenant context
- `processType` — the OMS process-type enum (e.g. `ORDER_BATCH_LOADED_TO_TRUCK`, `STOCK_UPDATE`, `ADVICE_ACCEPT_HUB_AND_SPOKE`, etc.)

Operators consume this counter via `/actuator/metrics/wms2.oms.notification.failed` or via Prometheus scrape. Suggested alert: any non-zero increment in a 5-min window pages the on-call engineer because every failed POST means OMS state is now drifting from WMS state for that tenant + process-type.

### 2.5.2 OMS response envelopes — HTTP 2xx does NOT mean accepted (SBDEV-2736)

**The legacy `/services/call/*` surface answers HTTP 200 for business-level failures and carries the real verdict in the response body.** A caller that decides on the status code alone records a refusal as a successful delivery. Until SBDEV-2736 all three WMS→OMS egress paths did exactly that.

Three body shapes exist in production. All three must be handled — a root-only check misses 37.5% of real rejections and reports **zero** for the entire picking family:

| Shape | Where the verdict lives | Example |
|---|---|---|
| (a) raw | root `Status` | `{"Status":"Error","Message":"There are no pallets to process.","Result":[]}` |
| (b) wrapped | `data.Status`, root stamped `"success"` | `{"status":"success","message":"…","data":{"Status":"Error","Result":[…]}}` |
| (c) lowercase | `data.status` | `{"status":"success","data":{"status":"exported","record_count":9232}}` |

Shape (b) comes from `BaseLegacyController::legacySuccessResponse`, which nests the verdict under `data` and hard-codes a top-level lowercase `"success"` regardless of what it is wrapping — so **the root lowercase `status` is a wrapper artefact and must never be read as a verdict.** Normalizing this is [SBDEV-2738](https://app.clickup.com/t/868kgp4h6) on the OMS side.

Measured over 1,206,656 `message` rows on `wms2-wineco-dev` (2026-07-29): 1,193,179 shape (a), 805 shape (b), 12,652 shape (c), 16 null bodies, and 4 PHP fatal-error HTML pages returned with HTTP 200.

> **⚠️ Shape (a) is extinct on `INVENTORY_FULL_EXPORT`.** Last seen 2025-08-12 (`Partially Failed`) and 2025-04-01 (`Error`). OMS moved that process to shape (c) during 2025 and changed the shape-(c) verdict word from `exported` to `SUCCESS` on 2026-07-13. Any analysis of export rejections that filters on a root `Status` is reading a dead envelope and will report zero.

> **⚠️ A shape-(c) `SUCCESS` does not mean every record landed.** The reconcile variant reports per-record outcomes *inside* a success verdict:
> ```json
> {"status":"success","data":{"status":"SUCCESS","records_processed":149,"records_failed":1,
>   "failed_records":[{"record":147,"sku":"LKET1","error":"Product with SKU 'LKET1' not found"}]}}
> ```
> In July 2026 that was **714 of 1,842 export responses and 1,071 dropped records** — the same unmapped-SKU class as SBDEV-2748. Shape (a) expressed this as `Status:"Partially Failed"`. Shapes (a) and (b) do **not** have this problem on the order endpoints: OMS sets `Status:"Error"` whenever `processed < total` there (verified — zero counter-examples across 731 rows with a `total` field).

`service/OmsResponseClassifier.java` is the single decision point, consumed by all three egress paths. Shapes (a) and (b) match **negative space** (anything not `Success` is a rejection) so OMS can add failure words without WMS going blind. Shape (c) matches an **accept-list** (`exported`, `SUCCESS`) instead, because negative space would invert `exported`; an unlisted value there is `UNRECOGNIZED`, never `REJECTED`. A shape-(c) accept-list hit is additionally downgraded to `REJECTED` when `records_failed > 0` or `failed_records` is non-empty.

**The recognition counter does not detect this class of drift.** `recognized="no"` fires when WMS cannot *parse* an envelope; it says nothing about OMS changing what an envelope *means*. Both drifts that have actually occurred were of the second kind and were absorbed by widening the accept-list. **Re-validate the accept-list *and the failure-evidence fields* (`records_failed`, `failed_records`) against a fresh corpus whenever OMS changes this surface**, and watch `response_envelope` broken down by process type — a distribution shift is visible there even while recognition stays `"yes"`. Note the evidence check reads only the root and `data` objects, and only those two field names: a deeper nesting or a differently-named field (`records_skipped`, `errors`) would be missed. That is deliberate — the predicate stays closed, and inventing anchors without corpus evidence is what produced the original defect.

**Phase 1 is observation only** — delivery semantics are unchanged and every 2xx is still marked `SENT`. Counters:

| Counter | Path | Tags |
|---|---|---|
| `wms2.outbox.oms_rejected` | outbox dispatcher | `tenant`, `facility`, `processType` |
| `wms2.outbox.response_envelope` | outbox dispatcher | + `recognized=yes\|no` |
| `wms2.oms.notification.rejected` | `OmsNotificationService.doSend` | `tenant`, `processType` |
| `wms2.oms.export_rejected` | `StockSummaryExportJob` | `tenant`, `facility` |

`response_envelope{recognized="no"}` is the shape-drift alarm: it goes non-zero when OMS emits an envelope WMS cannot read, which is the condition that would otherwise silently reset the rejection baseline to zero.

> **Expect `wms2.oms.export_rejected` to be non-zero on the first deploy.** It reports a pre-existing backlog, not a regression. On WineCo the live rate is ~700 rejections/month, essentially all of them shape-(c) partial failures naming an unmapped SKU ([SBDEV-2748](https://app.clickup.com/t/868khcak2)) — a class that went unnoticed for nineteen months precisely because this counter did not exist. The 10,306 historical shape-(a) refusals on the same process are all pre-2025-08 and will not recur.

Phase 2 (acting on the verdict — retry or terminal instead of `SENT`) is gated behind `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED`, seeded `false` by Flyway `V2.2.05` and **read by nothing yet**.

### 2.6 Facility Lookup (BillofladingService — WMS calls OMS to GET data)

| Sysprop key | Default OMS path | Direction | Java method | Purpose |
|------------|-----------------|-----------|-------------|---------|
| `WEBSERVICE_FACILITY_LIST_LOOKUP` | `/services/call/facilities` | WMS → OMS (GET) | `BillofladingService.getFacilities()` | Retrieve available destination facilities for BOL creation |

### 2.7 Admin / Connectivity Test

| Sysprop key | Default OMS path | Triggered by | Java method |
|------------|-----------------|-------------|-------------|
| `WEBSERVICE_TEST_CRM_CONNECTIVITY` | `/services/call/testPsd` | Admin action (manual), `GET /v3/adminAction/testCrmConnectivity` | `AdminActionController.testCrmConnectivity` (`:207-212`, GET to OMS) |

### 2.8 Message Resend

`MessageService.resendMessage()` can replay any previously logged WMS→OMS message. It POSTs to the original `destination` URL stored in the `Message` record. This is the only retry path for `sendAfterCommit`-based notifications (now just the 5 call-sites of §2.1 "Current state") — there is no automatic retry on first failure for those sites.

For **every transactional-outbox site** (originally the `BillofladingService.closeBOL` pilot, SBDEV-2221; 19 enqueue call-sites today, §2.9), automatic retries ARE supported: `OutboxDispatcherJob` retries `FAILED_RETRY` rows with exponential backoff (`min(60s × 2^attempts, 1h)`) up to `app.outbox.dispatcher.max-attempts=5`. **In-flight reclaim:** `OutboxDispatchService.dispatchBatch` Phase 0 reverts `IN_FLIGHT` rows older than `STALE_INFLIGHT_TIMEOUT` = **15 min** (`OutboxDispatchService.java:72`; was 5 min) to `FAILED_RETRY`, lane-scoped. **Retry budget per process type:** `ORDER_BATCH_SHIPPED` rows (single BOL row or chunk) get `app.outbox.dispatcher.bol-shipped-max-attempts=29` attempts, ≈24 h at the 1 h backoff cap (30 POSTs); every other process type keeps 5; 400/404/422 stay terminal at once (`OutboxDispatchService.java:107,333-343`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). Terminal failures (4xx non-retryable or attempts exhausted) are logged at ERROR level with aggregate_type + aggregate_id + idempotency_key and metered at `wms2.outbox.dispatched{outcome=terminal}`. A `FAILED_TERMINAL` row also **holds** later same-aggregate events behind the SBDEV-2381 fail-closed gate; this stuck condition is surfaced by `wms2.outbox.stuck_aggregate{tenant,facility}` (+ `.oldest_age_seconds`) — per-tenant `MultiGauge`s sampled by the dispatcher (SBDEV-2381 Prereq #8 / plan 260614, sysprop-gated `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`, default OFF). Recovery: runbook `wms2-unstick-held-outbox-aggregate.md`. **Outcome fence** ✓ merged(SBDEV-4110: #667 736b6f4b, 2026-11-12): `markSent/markRetry/markTerminal` take the claim's `modified_at` and are single `UPDATE … WHERE status='IN_FLIGHT' AND modified_at=:claimedAt` statements (`OutboxMessageRepository.mark*IfClaimed`), so a dispatcher that outlived the 15-min reclaim cannot overwrite a row a later tick re-claimed — it counts `wms2.outbox.dispatched{outcome=fenced}` instead. A `markSent` that throws after OMS answered 2xx no longer falls into the retry/terminal catch (which re-POSTed a delivered message, or on the last attempt made it a `FAILED_TERMINAL` blocker); it counts `{outcome=sent_unrecorded}` and leaves the row `IN_FLIGHT`, so stale reclaim re-POSTs it once. OMS lifecycle endpoints do not dedupe on `Idempotency-Key` (only the BOL receipt does), so that one re-POST is the residual cost.

> **² 2026-05-21 (plan 260521 Fix B — service-log gap):** `OutboxDispatchService` now calls `writeServiceLog()` after every dispatch outcome (2xx SENT, terminal failure, retry). This writes a `message` table row using `MessageService.createMessage()` in best-effort fashion (exceptions swallowed; metered at `wms2.outbox.message_log.failed`). Every outbox notification type (at the time 9; 11 distinct process types today, §2.9) appears in the **Service Log** admin page — closing the gap where outbox-dispatched notifications were invisible in the UI while legacy `sendAfterCommit` callers wrote rows via `OmsNotificationService.doSend`.

### 2.9 Outbound census — every WMS→OMS call, by transport (verified 2026-11-11, develop `df30fa62`)

Enumeration commands (run in `src/main/java`): `grep -rn 'outboxService\.enqueue(' --include='*.java' . | grep -v OutboxDispatchService` → **19** code call-sites; `grep -rn 'omsNotificationService.sendAfterCommit(' --include='*.java' .` → **5** code call-sites (plus 1 javadoc mention); `grep -rn 'httpRestService\.\(post\|get\)[A-Za-z]*(' --include='*.java' .` → **8** hits, the 2 on the outbox/notification paths plus 6 direct calls listed below.

**A. Transactional outbox (`outboxService.enqueue`, retried, §2.8) — 19 call-sites, 11 process types**

| Process type | Sysprop URL key | Gate (sysprop) | Enqueue site |
|---|---|---|---|
| `ORDER_BATCH_PICKING_RELEASED` | `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | none; transfer path: `WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED` (default `false`, absent = OFF) | `ReleaseOrderJobService:794`; `CustomerorderBatchService:947` (club, per-order or chunk); `BillofladingService:1150` (transfer, gate at `:1092`) |
| `ORDER_BATCH_PICKING_STARTED` | `WEBSERVICE_ORDER_BATCH_PICKING` | transfer path as above | `PickingorderBusinessService:1449` (`confirmPick`); `CustomerorderBatchService:958`; `BillofladingService:1150` |
| `ORDER_BATCH_PICKING_FINISHED` | `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | none | `PickingorderBusinessService:401, 561`; `CustomerorderBatchService:974` |
| `ORDER_BATCH_SHIPPED` | `WEBSERVICE_ORDER_BATCH_SHIPPED` | none | `BillofladingService:884` (single row) / `:895` (chunk rows) |
| `ORDER_BATCH_CANCELLED_FROM_WMS` | `WEBSERVICE_ORDER_BATCH_CANCELLED` | none (flag row deleted, §2.3) | `CustomerorderService:873`; `PickingorderBusinessService:900` |
| `ORDER_BATCH_REVERSAL_COMPLETED` | `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` (`/services/call/batchReversalCompleted`) | none; skipped with a WARN when the URL is blank | `CancellationReversalService:1007` (SBDEV-3381; `enqueueReversalCompletedIfClosed`) |
| `ORDER_BATCH_UPDATE_PRIORITY` | `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY` (`/services/call/updateBatchPriority`) | `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED`, default OFF (SBDEV-2573); batchless order-scope rows ride their own `aggregate_type='CUSTOMER_ORDER_PRIORITY'`, never the lifecycle `CUSTOMER_ORDER` chain (a dead callback there held every later lifecycle event) ✓ merged(SBDEV-4110: #667 736b6f4b, 2026-11-12) | `PriorityChangeNotificationService:133`; callers `CustomerorderBatchService:377`, `CustomerorderService:675` |
| `ORDER_BATCH_UPDATE_PICKING_DATE` | `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE` (`/services/call/updatePickingDate`) | `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED`, default OFF (SBDEV-3273); rides its own `aggregate_type='CUSTOMER_ORDER_PICKING_DATE'`, never the lifecycle `CUSTOMER_ORDER` chain ✓ merged(SBDEV-4110: #667 736b6f4b, 2026-11-12) | `PickingDateChangeNotificationService:107`; caller `CustomerorderService:362` |
| `ADVICE_CLOSE` | `WEBSERVICE_CLOSE_ADVICE` | none | `AdviceService:381` |
| `ADVICE_ACCEPT_TRANSFER` | `WEBSERVICE_ACCEPT_TRANSFER` | none | `AdviceService:452` |
| `ADVICE_HUB_AND_SPOKE_RECEIVED` | `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | none | `AdviceService:281` |

Lanes: only the club-finalize rows (`CustomerorderBatchService:947/958/974/1102`) and the chunked BOL-shipped rows (`BillofladingService:895`) are enqueued on `LANE_CLUB`; everything else is `DEFAULT`.

**B. `OmsNotificationService.sendAfterCommit` (after-commit POST, no auto-retry) — 5 call-sites, 5 process types**

`ORDER_BATCH_ON_HOLD` (`WEBSERVICE_ORDER_BATCH_HELD`, `ManageOrderService:105`), `ORDER_BATCH_PICKING_TOTE_ASSIGNED` (`…_PICKING_TOTE_ASSIGNED`, `:187`), `ORDER_BATCH_PALLETIZED` (`…_PALLETIZED`, `:345`), `ORDER_BATCH_LOADED_TO_TRUCK` (`…_LOADED_TO_TRUCK`, `:385`), `STOCK_UPDATE` (`WEBSERVICE_STOCK_UPDATE`, `StockChangeNotificationService:47`, via `MessageService.sendStockChangeMessage`). No `_ACTIVATED` gate on any of them.

**C. Direct synchronous `httpRestService` calls**

| Call | Sysprop key | Site |
|---|---|---|
| POST stock summary export (chunked) | `WEBSERVICE_STOCK_COUNT` | `StockSummaryExportJob:579` |
| POST dummy stock-count message | `WEBSERVICE_STOCK_COUNT` | `MessageDummyController:43` |
| POST operator stock-update resend | `WEBSERVICE_STOCK_UPDATE` | `ItemDataController:127` |
| GET connectivity test | `WEBSERVICE_TEST_CRM_CONNECTIVITY` | `AdminActionController:212` |
| GET facility list | `WEBSERVICE_FACILITY_LIST_LOOKUP` | `BillofladingService:1820` (`getFacilities`) |
| POST message resend | the original `message.destination` | `MessageService:189` |

**Sysprop census.** `SYSTEM_PROPERTY_WEBSERVICE_*_URL_KEY` constants in `WmsConstants`: 19 (`grep -c 'SYSTEM_PROPERTY_WEBSERVICE_[A-Z_]*_URL_KEY *='` over lines 1207-1301). Every one is read by a site above (`WEBSERVICE_ORDER_BATCH_CANCELLED` by two). The `WEBSERVICE_*_ACTIVATED` gates that exist and are read: `UPDATE_PRIORITY`, `UPDATE_PICKING_DATE`, `TRANSFER_PICKING_NOTIFICATIONS` (3). `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` and `WEBSERVICE_BEHAVIOUR` no longer exist as Java constants.

**Chunking — three independent knobs, do not conflate:**

| Sysprop | Default | Clamp | What it chunks | Status |
|---|---|---|---|---|
| `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` | `40` (seeded by V2.2.40) | ceiling 60 (`BolShippedNotificationChunker.CHUNK_SIZE_CEILING`) | parcels per `ORDER_BATCH_SHIPPED` row; REGULAR / HUB_AND_SPOKE BOLs only; transfers never chunk | live (SBDEV-3672); aggregate `BILL_OF_LADING_CHUNK`, lane CLUB, key `BOL-SHIPPED-<bolId>-C<i>of<N>` |
| `WMS_CLUBLINE_OMS_CHUNK_SIZE` | `1` (seeded by V2.2.29) | ceiling 300 (`CLUBLINE_OMS_CHUNK_SIZE_CEILING`) | club orders per RELEASED/STARTED/FINISHED row | **stays 1 on every tenant** — the PRD rollout (SBDEV-3310) was dropped 2026-11-05; values above 1 are unsafe until per-record verdict handling (SBDEV-2736 Phase 2) and a requeue path for `CLUB_BATCH_CHUNK` rows exist (`CustomerorderBatchService.java` javadoc above `enqueueClubNotificationsChunked`) |
| `WMS_CLUBLINE_ASYNC` | `1` (SBDEV-4007, V2.2.47) | n/a | not chunking — async club-run job kill switch | live |

---

## §3 `WEBSERVICE_BEHAVIOUR` Switch (v2-only)

> ⚠ **Removed from code:** the Java constants are gone from develop (`grep -rn WEBSERVICE_BEHAVIOUR src/main/java` → no hits at `df30fa62`) and `V2.2.37__delete_dead_cancellation_sysprops.sql` deletes the row (SBDEV-3373, PR #466, merged to develop `a0b2c07f`). ⚠ unverified 2026-11-11: which environments have applied `V2.2.37` (last recorded: dev 2026-10-07, not UAT/PRD). The section below is retained as the historical explanation of why the key never did anything.

**Sysprop key:** `WEBSERVICE_BEHAVIOUR`
**Default value:** `keep` in the Java constant (never used); **`send`** in every DB seed (`V2.2.00`, onboarding `V1.0.04`) and on every live tenant checked
**Valid values:** `send` | `discard` | `keep`

This sysprop *was* defined in `WmsConstants` (with commented-out provisioning code in `UtilRestController`); both are gone from develop. While it existed it was **declared but never read at runtime** — no production code path called `getSysvalue(SYSTEM_PROPERTY_WEBSERVICE_BEHAVIOUR_KEY)`. It was intended as an emergency switch to control outbound callback behaviour:

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
| `PUT /rest/order/finishedTransfer` | Yes | Yes | ⚠ Corrected 2026-11-11: this row said v1 = No, but v1 `origin/develop` (`4cdd945`) has `OrderRestController.finishedTransfer` at `:920`. v2 behaviour is documented in the transfer workflow doc |
| `POST /rest/order/updateShipper` | No | **Yes** | v2-only (SBDEV-3841); no match in v1 `controller/rest/` |
| `PUT /rest/advice/create` | Yes | Yes | Same contract |
| `PUT /rest/advice/createTransfer` | Yes | Yes | Same contract |
| `PUT /rest/advice/createHubAndSpoke` | Yes | Yes | Same contract |
| `PUT /rest/sku/create` | Yes | Yes | Same contract |
| `POST /rest/sku/update` | Yes | Yes | Same contract |
| `DELETE /rest/sku/delete` | Yes | Yes | Same contract |
| `POST /rest/stockcount/getStockCount` | Yes | Yes | Same contract |
| `GET /rest/stockcount/triggerStockCount` | Yes | Yes | Same contract |
| `POST /rest/report/getTransactionReport` | Yes | Yes | ⚠ Corrected 2026-11-11: said v1 = No; v1 `origin/develop` has `TransactionReportRestController` (`@RequestMapping("/rest/report")`, `:40`) |
| `POST /rest/report/getTransactionDetailedReport` | Yes | Yes | ⚠ Corrected 2026-11-11: same controller in v1 (`:188`) |
| `GET /rest/printer/findByType` | No | **Yes** | v2-only; v1 `controller/rest/` has no printer controller |
| `GET /rest/unitload/state/{labelId}` | No | **Yes** | v2-only (SBDEV-2742); no unitload controller in v1 `controller/rest/` |

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
| `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY` | No | **Yes** | v2-only, gated by `_ACTIVATED` (default OFF); v1 `src/main` has only the inbound `ORDER_BATCH_UPDATE_PRIORITY` message type, no outbound key |
| `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE` | No | **Yes** | v2-only, gated by `_ACTIVATED` (default OFF) |
| `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` | No | **Yes** | v2-only (SBDEV-3381) |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | Yes | Yes | v2 payload enriched with `sharedUniqueBolId`, `trackingDeviceId`, `sourceWarehouse`, `destinationWarehouse` |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | Yes | Yes | v2 fires **per order** from `cancelOrder` unconditionally; **v1 as deployed sends no automatic cancel callback.** The only route is a manual resend (`GET /v3/message/resend/{id}`, `MessageController`). The code exists in two places, but neither runs: `CustomerorderService.cancelOrder` posts only when `cancellationFromWithinWMS` is true, and both callers (`OrderRestController`, `UtilRestController`) pass `false`; `CustomerorderBatchService.cancelBatch` has no production caller, only unit tests (verified on v1 `origin/develop`, 2026-10-06). ⚠ Corrected 2026-10-06: this row used to say v1 is gated by `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED`, but v1 never reads that flag either. ⚠ Previously read *"v2 fires from `cancelBatch`"* — that method was deleted 2026-09-14 (SBDEV-3354); v1 still has it. |
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
| WMS-initiated cancel not reaching OMS | `WEBSERVICE_ORDER_BATCH_CANCELLED` URL not set; or (before SBDEV-3362) the order was force-cancelled, which sent nothing | Check sysprop `WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` — the one `enqueueCancellationSignal` reads *(corrected 2026-09-26: this cell said cancelOrder used `WEBSERVICE_STOCK_COUNT_URL_KEY`, refuted in §2.3)* |
| `PALLETIZED` / `LOADED_TO_TRUCK` callbacks not firing | These are v2-only — OMS must handle them; if OMS is v1 these endpoints may not exist | Verify OMS version; these callbacks did not exist in v1/wms-api |
| Callback fires but OMS rejects payload | Payload schema mismatch | Compare `BillOfLadingWebServiceDto` / `OrderBatchDto` with OMS expected contract; v2 `SHIPPED` payload has additional fields vs v1 |
| Parcel regresses Ready-to-QA → Picking; FINISHED arrives before STARTED | Outbox dispatched events out of aggregate order | Fixed by SBDEV-2381 (§2.1 note): dispatcher claims with the cross-tick `NOT EXISTS` gate + `ORDER BY next_attempt_at, id`, sorts the batch in-Java, and posts sequentially; each POST body carries `event_version = outbox id` so OMS can reject stale events. Inspect `outbox_message` `id` vs `aggregate_id` ordering for the affected parcel |
| Manual resend needed | `MessageService.resendMessage()` | Call via WMS admin UI or directly; re-POSTs to `message.destination`; creates a new `Message` record with `resent=true` on original |

### 5.3 `WEBSERVICE_BEHAVIOUR` gotcha

The `WEBSERVICE_BEHAVIOUR` sysprop is declared but **not consulted at runtime**. Setting it has no effect on outbound callback behaviour. All callbacks fire unconditionally. Do not rely on this switch to suppress callbacks in a v2 environment. The Java constants are removed and the row is deleted by SBDEV-3373 `V2.2.37` (PR #466, merged to develop `a0b2c07f`; applied on dev 2026-10-07; ⚠ UAT/PRD application unverified 2026-11-11).

### 5.4 REST Inbound Idempotency (content-derived key, optional header)

Implemented in SBDEV-2222; updated in 260520 (content-derived key). OMS retries POST/PUT on network failure; WMS auto-derives the idempotency key from `SHA-256(method + "|" + path + "|" + rawBodyBytes)` — the `Idempotency-Key` header is **optional**. An explicit header overrides the auto-derived key (back-compat for OMS callers that still send one). A matching key+body hash replays the cached 2xx; a key+hash mismatch returns 409. Requests with body > 5 MB bypass dedup (DoS guard). Bridge-mode (`app.idempotency.bridge-mode=true`) replays pre-existing UUID-keyed rows during the UUID→SHA-256 transition window. Controlled by `app.idempotency.enforce=true` — set `false` to bypass in dev. Dedup rows are cleaned up after 7 days by `RestIdempotencyCleanupJob`.

---

## §6 OMS v2 Client-Side Implementation

Documents how `v2/oms-laravel-api` constructs and dispatches calls to the WMS REST endpoints described in §1. All evidence derived from `v2/oms-laravel-api/`. §6 re-read 2026-11-11 against OMS `origin/develop` (`31b2515c`), **not** the local checkout (`develop` `f61ed952` lags it and lacks `order_update_shipper`); the WMS side of every row was checked against wms2-api `df30fa62`.

### 6.1 Gateway Architecture

All WMS calls are funnelled through a single gateway class. Callers never construct HTTP requests directly.

```
oms-laravel-api (PHP / Laravel 12)
        │
        │  Illuminate\Support\Facades\Http  (wraps GuzzleHttp 7.x)
        ▼
app/Services/WmsApiService.php          ← single HTTP gateway (4 990 lines at `31b2515c`)
        │
        │  resolves base URL per facility  ──► app/Models/WmsUrlLut.php
        │  loads endpoint paths            ──► config/wms.php
        │  applies auth + tenant headers
        │  retries with exponential back-off
        ▼
WMS Java API  /rest/**  (permitAll on the WMS side; OMS sends no auth header — `applyAuthentication` returns early for any URL containing `/rest/`, `WmsApiService.php:3776-3786`)
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
| Retry attempts | default 3 (`wms.facilities.retry_attempts`, `retry_delay` 1000 ms), exponential back-off; per-call overrides since SBDEV-3671 (`attempts`, `timeout` — the order-create batch push sends once with a 30 s timeout, `config/wms.php` `order_create` block). ⚠ unverified 2026-11-11: the 1 s → 2 s → 4 s schedule itself was not re-derived |
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
| `none` | `/rest/**` endpoints | No auth headers sent; the WMS answers `/rest/**` unauthenticated by design (§1). The "IP-restricted at network level" claim is network configuration outside either repo — ⚠ unverified 2026-11-11 |
| `basic` | Some internal environments | HTTP Basic credentials from facility config |
| `token` | Facility-specific token auth | Bearer token from facility config |
| `keycloak` | `/v3/**` endpoints | Keycloak service-account JWT via `KeycloakService`; auto-refreshes on 401 |

### 6.5 Endpoint Configuration (`config/wms.php`)

Named endpoints and their default WMS path (`config/wms.php` `endpoints`, OMS `origin/develop` `31b2515c`; **39 active keys at `31b2515c`, 35 after SBDEV-4127**, of which 4 are legacy — see below, `git show origin/develop:config/wms.php | grep -c "env('WMS_.*ENDPOINT'"`). The `/rest/**` keys:

| Config key | WMS path | HTTP method | Exists on WMS (§1)? |
|------------|----------|-------------|---------------------|
| `order_create` | `rest/order/create` | PUT | yes |
| `qa_complete` | `rest/order/finishedQA` | POST | yes |
| `order_cancel_positions` | `rest/order/cancelPositions` | POST | yes |
| `order_update_priority` | `rest/order/updatePriority` | POST | yes |
| `order_update_shipper` | `rest/order/updateShipper` | POST | yes (§1.1) |
| `order_finished_transfer` | `rest/order/finishedTransfer` | PUT | yes |
| `advice_create` | `rest/advice/create` | PUT | yes |
| `advice_create_transfer` | `rest/advice/createTransfer` | PUT | yes |
| `advice_hub_and_spoke` | `rest/advice/createHubAndSpoke` | PUT | yes |
| `sku_create` / `sku_update` / `sku_delete` | `rest/sku/create` (PUT) / `rest/sku/update` (POST) / `rest/sku/delete` (DELETE) | as shown | yes |
| `stockcount_get` | `rest/stockcount/getStockCount` | POST | yes |
| `stockcount_trigger` | `rest/stockcount/triggerStockCount` | GET | yes |
| `transaction_report_summary` / `transaction_report_detailed` | `rest/report/getTransactionReport` / `rest/report/getTransactionDetailedReport` | POST | yes |
| `unitload_state` | `rest/unitload/state/{label_id}` | GET | yes (§1.6) |
| `printer_search_by_type` | `rest/printer/findByType` | GET | yes (§1.6) — was `/v3/printer/search/findByType`; the v3 form is now only an override for WMS releases that predate the rest endpoint |

Removed from OMS config and **not** to be re-added: `return_scanned` (`rest/order/returnScanned`, never existed on WMS), `shipping_label_sync`, `client_create`/`client_update` as `rest/client/*`, and, as of SBDEV-4127 (OMS PR #994, merged to develop `f0afe7d3` on 2026-11-13), `status_change` (`rest/order/statusChange`), `multi_parcel_hold` (`rest/order/multiParcelHold`), `get_parcel` (`rest/parcel/{parcel_id}`) and `inventory_adjust` (`rest/inventory/adjust`). None of the four had a WMS handler (all four returned 404 on DEV) or a live OMS caller. The `inventory_adjust` chain ran only through `ReturnProcessingService` ← `ProcessReturnJob`, and nothing dispatches that job. An OMS unit test (`WmsApiServiceDeadEndpointsTest`) now fails if they come back. The returns→WMS integration is the RETURN advice raised at manage time (`rest/advice/create`, SBDEV-2778).

The `/v3/**` catalog-sync keys (Keycloak service token): `client_create` `v3/client/create`, `client_find_by_number` `v3/client/search/findByClNr`, `client_update` `v3/client/{id}` (PATCH), `shipperid_create` `v3/shipperId/create`, `boxtype_create` `v3/boxType/create`, reads `client_list`, `itemdata_list`, `shipperid_list`, `boxtype_list`, `itemdata_by_client`, and `customerorder_batch_find_by_batchid`, `customerorder_find_by_orderbatch_id`, `customerorder_find_by_external_id_list`. WMS side spot-checked: `ClientController` `/v3/client/create`, `BoxTypeController` `/v3/boxType/create`, `ShipperIdController` `/v3/shipperId/create`, `CustomerorderRepository` `findByOrderbatchId` / `findByExternalIdList` (`@RestResource`). ⚠ unverified 2026-11-11: the other `/v3` reads (`findByClNr`, `findByBatchid`, `findByClientId`, list endpoints) — outside the `/rest/**` scope of this pass.

Legacy keys `transfer_completion` (`/transfer/complete`), `inventory_update` (`/inventory/update`), `order_cancel` (`rest/order/cancel`), `stock_count` (`/inventory/count`) have no WMS handler. Only `transfer_completion` still has a caller (`WmsApiService.php:108`); the other three have no `getWmsEndpoint(...)` caller in `app/` at `31b2515c` (`git grep -n "getWmsEndpoint('" origin/develop -- app`). `createFacility()`/`updateFacility()`, which called `getWmsEndpoint('facility_create'/'facility_update')` after both keys had been removed from config, were deleted in SBDEV-4127 along with `FacilityController`'s calls to them. ⚠ `transfer_completion`'s only caller is `WmsApiService::notifyTransferCompletion()`, and **nothing in `app/` calls that method** (verified `f0afe7d3`; `LegacyTransferCloseService` says so in a comment and uses `rest/order/finishedTransfer` instead). So all four legacy keys are dead. Proposed as a follow-up in `2-Areas/proposals-register.md`.

Each path is individually overridable via a matching `WMS_*_ENDPOINT` env var.

### 6.6 OMS Laravel Caller → WMS Endpoint Map

| WMS endpoint (§1 reference) | OMS Laravel caller |
|-----------------------------|--------------------|
| `PUT /rest/order/create` | `BatchProcessingService::createBatch()` |
| `POST /rest/order/updatePriority` | `OrderProcessingService::updatePriority()` (`WmsApiService.php:2172`) |
| `POST /rest/order/updateShipper` | `WmsApiService.php:2386` (caller class not traced) |
| `POST /rest/order/cancelPositions` | `OrderProcessingService::cancelOrders()` |
| `POST /rest/order/finishedQA` | `QaWorkflowService::notifyWmsQaComplete()` |
| `PUT /rest/order/finishedTransfer` | `LegacyTransferCloseService::close()` |
| `GET /rest/unitload/state/{labelId}` | `WmsApiService.php:1157` |
| `GET /rest/printer/findByType` | `WmsApiService.php:3061` (`getWmsPrinters`) |
| `PUT /rest/advice/create` | `WmsApiService.php:2568` (callers: `ReturnProcessingService::createAdvice()`, `QaReturnService::receiveReturnInWms()`) |
| `PUT /rest/advice/createTransfer` | `LegacyInventoryTransferService` |
| `PUT /rest/advice/createHubAndSpoke` | `TransferService` (hub distribution) |
| `PUT /rest/sku/create` | `ProductController`, `InventoryService` |
| `POST /rest/sku/update` | `ProductController`, `InventoryService` |
| `DELETE /rest/sku/delete` | `ProductController`, `InventoryService` |
| `POST /rest/stockcount/getStockCount` | `InventoryService::getStockCount()` |
| `GET /rest/stockcount/triggerStockCount` | `InventoryService::triggerStockExport()` |
| `POST /rest/report/getTransactionReport` | `TransactionReportService` |
| `POST /rest/report/getTransactionDetailedReport` | `TransactionReportService` |

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

---

## Verification log

| Date | Verified against | Result |
|------|------------------|--------|
| 2026-11-11 | wms2-api `origin/develop` `df30fa62` (detached worktree); OMS `origin/develop` `31b2515c` for §6; v1 `origin/develop` `4cdd945` for §4 | §1 inbound enumerated (19 endpoints, 7 controllers; added `updateShipper`, printer, unitload; auth corrected to `permitAll`, facility-check scope corrected). §2 outbound enumerated (19 outbox + 5 `sendAfterCommit` + 6 direct call-sites; new §2.9 census; added priority / picking-date / reversal-completed / transfer-picking gates; two outbox lanes, 15 min stale reclaim, `*/3` cron; chunking knobs). §3/§5.3 `WEBSERVICE_BEHAVIOUR` and `_CANCELLED_ACTIVATED` constants confirmed gone. §4 v1 delta corrected (report and `finishedTransfer` exist in v1). §6 OMS config re-read (4 dangling OMS→WMS endpoints named). Open: UAT/PRD application of `V2.2.37`, OMS retry back-off schedule, network-level IP restriction. |

**Next due: 2027-01-10** (60-day cadence).
