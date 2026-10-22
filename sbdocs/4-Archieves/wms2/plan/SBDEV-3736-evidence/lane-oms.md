---
ticket: SBDEV-3736
lane: oms
created: 2026-10-13
sources:
  oms-laravel-api: origin/develop @ 1369c109
  siteboss-frontend: origin/main @ 64836f4d
  wms2-api: origin/develop (only to confirm what the WMS sends back to the OMS)
method: read-only, `git show origin/<branch>:<path>` / `git grep`; no DB queries in this lane
---

# SBDEV-3736 — OMS-side evidence: what the OMS persists for a return, and what it sends to the WMS

Legend: **[F]** = fact read from code/schema on the cited ref. **[I]** = inference.

## 0. The live path (which code actually runs)

- **[F]** The QA Manager UI (siteboss-frontend `apps/qa`) does two calls: `apps/qa/src/containers/Returns/useReturns.jsx:7-8`
  > `1. SCAN   — PUT /qa/parcels/returns/{parcelId}   { return_reason, return_location }`
  > `2. MANAGE — PUT /qa/returns/{parcelId}/manage    { disposition, comment, returned_items, receive_now }`
- **[F]** These go to `QaReturnController::processReturn` / `::manageReturn` (`routes/api.php:1084,1090`), which call `QaReturnService::processReturn` and `QaReturnService::updateReturnManagement`.
- **[F]** `receive_now` is set by the UI from the disposition's flag: `ManageReturns.jsx:122` `receive_now: !!selectedDisposition?.advises_wms,`. The UI sends **no** `managed_by` field. It **never** calls `POST /qa/parcels/returns/{id}/receive-in-wms`. No hit for `receive-in-wms` in `apps/`.
- **[F]** The WMS call happens only inside MANAGE: `QaReturnService.php:386-387`
  > `if ($receiveNow && ReturnMgmtLut::dispositionAdvisesWms($disposition)) { $wmsResult = $this->sendReturnRestockAdvice($return, $returnedItems); }`
- Other return entry points on develop. None of them sends a restock advice:
  - **[F]** `ReturnController::manage` (`routes/api.php:890`, `POST /returns/{parcel_id}/manage`) updates `returns` and fires notifications. It does **not** persist `return_item` and does **not** call the WMS (`ReturnController.php:385-440`).
  - **[F]** `LegacyV2ReturnController::store` → `LegacyReturnProcessService::createReturnRecord` inserts into `returns` with a hard-coded `'return_location' => 'SF01'` and makes no WMS call.
  - **[F]** The `ReturnManagementService` callers (`LegacyClientController` startReturn/manageReturn) are routed to `RetiredMerchantEndpointController::gone` (410), see `routes/legacy-services.php:142-143`. **[I]** They are unreachable.
  - **[F]** `ReturnProcessingService::syncReturnAdviceToWms` is called only from `ProcessReturnJob`, and nothing in `app/` or `routes/` dispatches that job. It works on `ReturnOrder->items` / `return_order_item`. The `return_order_item` table is **not in** `database/schema/tenant-baseline.sql`, and no `return_order` table exists either. **[I]** Dead code. Ignore it for this audit.
  - **[F]** `QaReturnService::receiveReturnInWms` ("Flow 2") is routed (`routes/api.php:1093`) but no UI calls it. Its payload carries `items => []` and no `positions` (`WmsApiService::buildAdvicePayload:2585-2614`). **[I]** It cannot advise stock. It is a dormant second advice/create shape.

## 1. Cardinality

- **[F]** `returns` PK = `parcel_id` (`tenant-baseline.sql`: `PRIMARY KEY (\`parcel_id\`)`). That gives **one return per parcel**. An order with N parcels can have up to N returns.
- **[F]** `return_item` PK = `order_item_parcel_id`, one row per parcel line, holding `quantity_damaged / quantity_undamaged / quantity_missing`. It has no `parcel_id` column; the parcel is reachable through `order_item_parcels.parcel_id`.
- **[F]** The disposition is stored **once per return (parcel)** in `returns.disposition`, not per line.
- **[F]** Each return produces at most one WMS advice, `reference_id = 'RETURN' . parcel_id` (`QaReturnService.php:714`). Positions are **merged per (client, SKU)** before sending (`:836-893`), then numbered `RETURN{pid}_1..n` (`:896-903`). **[F]** The OMS does not store the position→`order_item_parcel_id` mapping. **[I]** If one SKU sits on two parcel lines, the WMS-side position cannot be tied back to a specific OMS line.

## 2. The advice/create payload the OMS sends (live path)

`QaReturnService::sendReturnRestockAdvice` (`QaReturnService.php:714-723`):
```php
$advice = [
    'client_id' => $client?->client_code ?? '',
    'facility_code' => $facilityCode,            // returns.return_location ?: order depletion facility
    'day_of_delivery' => app(WarehouseTimeService::class)->todayForFacility($facilityCode),
    'positions' => $positions,
    'delivery_note_number' => $shipmentId,       // 'RETURN' . parcel_id
    'reference_id' => $shipmentId,
    'shipment_id' => $shipmentId,
    'type' => 'RETURN',
];
```
Each position (`:884-903`):
```php
'amount_of_bottles' => $undamaged,
'amount_of_bottles_damaged' => $damaged,
'amount_of_boxes' => 1,
'box_id' => 1,
'sku' => $sku,
'client_id' => $client,
'reference_id' => $shipmentId . '_' . $counter,
```
- **[F]** It is sent as an unauthenticated `PUT {host}/rest/advice/create`, wrapped in a one-element array (`WmsApiService::createReturnAdvice:2222-2245`).
- **[F]** The payload does **not** contain: order id/number, parcel id as its own field, return reason, disposition, comment, QA user, scan/manage timestamps, `qty_missing`, `order_item_parcel_id`.

## 3. Per-field verdict (OMS side)

| # | Field | OMS persists | Sent to WMS | Class |
|---|---|---|---|---|
| 1 | Return ID | `returns.parcel_id` (PK; no surrogate id) | only encoded in strings `RETURN{parcel_id}` | present + sent (encoded) |
| 2 | Original order ID | indirectly: `parcel.order_id` via `returns.parcel_id` | **no** | present, not sent |
| 3 | Original parcel ID | `returns.parcel_id` | encoded in `reference_id`/`delivery_note_number`/`shipment_id` | present + sent (encoded) |
| 4 | Inbound BOL ID (WMS advice) | **not stored** in any column; only inside `service_log.response` text, and only when the WMS warns | n/a | absent |
| 5 | SKU + qty | `return_item` per parcel line (undamaged/damaged/missing); SKU via `order_item_parcels.product_id → product.product_sku` | `sku`, `amount_of_bottles` (undamaged), `amount_of_bottles_damaged`; **missing not sent**; merged per SKU | present + sent (lossy) |
| 6 | Disposition | `returns.disposition` → `return_mgmt_lut` | **no**; it only gates whether an advice is sent | present, not sent |
| 7 | Created unit-load IDs | not stored | n/a | absent |
| 8 | Destination locations | `returns.return_location` = **facility code** only | `facility_code` (facility, not bin) | facility present + sent; bin/location absent |
| 9 | Receiving user | QA users `returns.scanned_by`, `returns.managed_by` (rep_id); WMS receiving user not known | **no** | QA user present, not sent; WMS user absent |
| 10 | Return QA completion ts | `returns.manage_date` (and `scan_date` for check-in) | **no** (only `day_of_delivery` = facility-local date) | present, not sent |
| 11 | Receiving completion ts | not stored; at best `service_log.response_date` of the advice/create call | n/a | absent |

### Field detail and citations

**1. Return ID.** **[F]** The model has `protected $primaryKey = 'parcel_id'; // Primary key is parcel_id, not return_id` (`app/Models/ParcelReturn.php`). `ReturnOrder.php` maps the **same** `returns` table with the same PK. The manage route param `{returnId}` *is* the parcel id (`useReturns.jsx:226` `/qa/returns/${parcelId}/manage`). **[F]** `processReturn` returns `'return_id' => $return->id` and logs it (`QaReturnService.php:173,178`), but `returns` has no `id` column. **[I]** That value is always `null`. The response field is misleading. It is not a linkage source.

**2. Original order ID.** **[F]** `returns` has no `order_id` column (baseline DDL). The order is reached via `parcel.order_id` (`ParcelReturn::parcel()`). **[F]** The restock advice has no order field. Only the dormant `receiveReturnInWms` path sends `'order_number' => $order?->order_number`, and it is not the live path.

**3. Original parcel ID.** **[F]** It is `returns.parcel_id`. The numeric `parcel_id` goes to the WMS only as the suffix of `'RETURN' . $return->parcel_id` (`:714`). **[I]** A WMS-side join must parse that string. The client-facing `parcel_id_str` is not sent on the live path; only the dormant receiveReturnInWms path sends it (`:260`).

**4. Inbound BOL ID.** OMS does not know the WMS advice/BOL id.
- **[F]** On a clean success the WMS returns only `{"status":"success"}` (wms2-api `AdviceRestController.java`, `return ResponseEntity.status(status).body(Collections.singletonMap("status", "success"));`).
- **[F]** On a warning the body carries `warning.advice = autoReceiveOutcome.adviceNumber()` (same file). The OMS reads it in `extractWmsWarning` (`QaReturnService.php:449-460`), returns it in the HTTP response as `wms_warning.advice`, and logs it. It is **not written to any return column**.
- **[F]** The raw response *is* persisted in `service_log`: `createReturnAdvice` calls `$this->logWmsRequest($url, $advice, $response)` → `ServiceLog::logWmsRequest` (`raw_json_string`, `response`, `response_date`). `ServiceLog` uses `UsesTenantConnection`. **[I]** It is written inside the manage `DB::connection('tenant')->transaction`, so a failed advice throws and **rolls the service_log row back with it**. Only successful or warned calls leave a trace, and that trace is unstructured text found by `service_url LIKE '%/rest/advice/create'` plus `raw_json_string LIKE '%RETURN{pid}%'`.
- **[F]** There is no WMS→OMS callback for RETURN advices. OMS `closeAdvice` (`routes/legacy-services.php`, `LegacyAdviceCloseService::closeAdvice`) would upsert `advices(advices_code=reference_id, advice_json, advice_status='Close')`. However, wms2-api `AdviceService.close()` only fires `ADVICE_CLOSE` for REGULAR advices:
  > `if (!advice.getType().equals(WmsConstants.AdviceType.REGULAR)) { throw new BusinessException("Close inbound BOL not allowed for type " + advice.getType()); }`
  **[I]** So the OMS `advices` table never receives a `RETURN…` row. Even for REGULAR advices, the close DTO carries `reference_id = advice.externalid`, positions and amounts, but no WMS advice id (`bol_id` is read by the OMS as `$adviceData['bol_id'] ?? ''`, and the WMS DTO built in `close()` never sets it). Also, `advices` has **no timestamp column** (baseline DDL).

**5. SKU and qty.** **[F]** `persistReturnItems` (`:647-662`):
```php
ReturnItem::on('tenant')->updateOrCreate(
    ['order_item_parcel_id' => (int) $itemId],
    ['quantity_damaged' => ..., 'quantity_undamaged' => ..., 'quantity_missing' => ...]
);
```
- **[F]** The `return_item` columns are `tinyint` (signed, max 127), with no timestamps and no user.
- **[F]** The SKU is resolved at send time via `order_item_parcels → product.product_sku`. It is not stored on the return.
- **[F]** Only undamaged and damaged quantities are sent. Missing is dropped. Lines with no SKU are skipped with only a log warning (`:866-871`).

**6. Disposition.** **[F]** `returns.disposition` (int, an FK by convention to `return_mgmt_lut.return_mgmt_lut_id`). Seeded values (`tenant-seed-data.sql:4938-4941`): 1 *Manually Manage*, 2 *Restock Inventory* (`advises_wms=1`), 3 *Forward to Address*, 4 *Destroy Product*.
- **[F]** Only `advises_wms=1` dispositions produce a WMS advice (`ReturnMgmtLut::dispositionAdvisesWms`).
- **[F]** "Damaged" is **not** a disposition. It is a per-line quantity split, and it reaches the WMS only *inside* a Restock advice as `amount_of_bottles_damaged` (SBDEV-1512, `:769-786` docblock): "The WMS receives the SUM and then locks the damaged part (entity_lock 103 + a move to the Damaged location)."
- **[I]** Damaged units on a Destroy, Forward or Manually Manage return never reach the WMS. All-damaged lines on a Restock return *do* reach it, via the `undamaged + damaged > 0` gate (`:824-826, :856`).
- **[F]** The disposition value itself is never sent. The WMS sees only `type: RETURN`.

**7. Created unit-load IDs.** **[F]** No OMS column or model holds unit-load ids for returns. The advice/create success response carries none (see #4), and no callback exists. Absent.

**8. Destination locations.** **[F]** `returns.return_location varchar(10)` is commented *'Where the return was processed; SBBINFK [facility.facility_code]'*. It is resolved and validated by `resolveReturnLocation` (`:577`). It is sent as `facility_code`, falling back to the order's depletion facility (`:677`). **[F]** No bin, storage-location or Damaged-location id is stored or received.

**9. Receiving user.**
- **[F]** `returns.scanned_by` is set at SCAN: `$returnData['scanned_by'] ?? auth()->user()?->rep_id ?? 1` (`:124`).
- **[F]** `returns.managed_by` is set at MANAGE: `$managementData['managed_by'] ?? auth()->user()?->rep_id ?? 1` (`:353`).
- **[F]** The UI sends neither field, so both come from the auth user. **[I]** If auth resolves no rep, the user silently becomes **rep 1**, which is an attribution hazard for audit.
- **[F]** No user field is in the advice payload. Per wms2 AdviceRestController, the `/rest/**` call is unauthenticated. **[I]** The WMS-side receiving principal is therefore a system user, not the QA operator. Confirm in lane-wms.
- **[F]** `parcel_status_history.updated_by` = scanner at SCAN only (`markParcelReturned`, `:607-640`).

**10. Return QA completion timestamp.** **[F]** `returns.manage_date` = `now()` at manage (`:373`). `returns.scan_date` = `now()` at scan (`:142`). **[F]** Both are MySQL `timestamp` columns. **[F]** `parcel_status_history.status_date` and an `order_status_history` row (with no explicit `created_date` set in the create call) are written at **SCAN only**. MANAGE writes no status-history row.

**11. Receiving completion timestamp.** **[F]** No column. **[I]** wms2 auto-receives synchronously within advice/create; the warning codes `RETURN_AUTO_RECEIVE_PARTIAL/DAMAGE_FAILED/ABORTED` describe an in-request outcome. So the closest OMS-side proxy is `service_log.response_date` of that call, which is roughly equal to `manage_date`. A PARTIAL warning leaves the WMS advice open. **[F]** No callback tells the OMS when it is later finished (see #4).

## 4. Order-history / audit surfaces

- **[F]** History/audit tables in the tenant baseline: `audit_log` (`orderID_int`, `user_action`, `action_details`, `created_by`, `created_date`, `key1`, `key2`), `order_status_history`, `parcel_status_history`, `qascan_item_history` (outbound QA pass/fail per item), `service_log`, `notifications_log`, `events_log`, among others.
- **[F]** The return flow writes:
  - SCAN: `parcel_status_history` (status 5 "Package returned, awaiting processing") and `order_status_history` (status 5 "Parcel returned").
  - MANAGE: nothing in any history table. There is no `audit_log` write (`git grep` for audit_log/AuditLog with return context on `app/` gives no return hits). MANAGE only queues notifications through `ReturnEventNotifier::returnManaged`: the RETURN_MANAGEMENT alert, `ParcelShipped` with `event_type => 'returned'`, and the `return_managed` callback.
- **[F]** **SBDEV-3261** ("OMSv2 - ShipItEZ - Order History Should Record Return Management Disposition") is **Open** in ClickUp. `git log --all --grep=3261` in oms-laravel-api returns nothing, and no branch is named for it. **[I]** Today the disposition chosen at MANAGE does not appear in order history. It lives only in `returns.disposition`.

## 5. Looked for and did not find

- A surrogate return id column or table (`return_order`, `return_order_item`). The models exist, but neither table is in `tenant-baseline.sql`.
- Any OMS column for the WMS advice id / BOL number, goodsreceipt id, unit-load id, storage location, or WMS receiving user.
- Any WMS→OMS callback for RETURN advices. `closeAdvice` is REGULAR-only on the WMS side. `receiveHubAndSpoke`, `closeTransfer` and `stockUpdate` are unrelated to returns. I did not open the stockUpdate payload. **[I]** It is a stock-level sync and is not keyed to a return.
- An order-history or audit write at MANAGE time.
- A field linking a WMS advice position back to `order_item_parcel_id`.
- Any timestamp on `return_item` or `advices`.

## 6. Notable side findings (for the report, not filed)

1. **[I]** `processReturn`'s `return_id` is always null (`$return->id` on a table with no `id` column). It is cosmetic but misleading for anyone building linkage on it.
2. **[I]** The service_log row for a *failed* restock advice is rolled back with the manage transaction. This removes the OMS-side trace of exactly the calls an auditor would most want.
3. **[F]** The `?? 1` fallback for `scanned_by`/`managed_by` (`:124,:353`) can attribute returns to rep 1.
4. **[F]** `return_item` quantities are `tinyint` (signed, max 127 per parcel line).
5. **[F]** `LegacyReturnProcessService` hard-codes `return_location = 'SF01'`.
