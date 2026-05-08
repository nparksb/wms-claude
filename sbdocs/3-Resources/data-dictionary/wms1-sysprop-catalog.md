---
title: "WMS v1 — System Property (Sysprop) Catalog"
type: data-dictionary
status: active
version: v1
scope: sysprops
owner: Nam Park
created: 2026-04-27
updated: 2026-04-27
last_verified: 2026-05-06
verified_by: code read of v1/wms-api WmsConstants.java:862-1062 and active consumer grep across all Java sources
system: wms1
related:
  - ../architecture/wms1-scheduled-jobs-catalog.md
  - ./wms2-sysprop-catalog.md
tags:
  - data-dictionary
  - sysprop
  - configuration
  - wms1
---

# WMS v1 — System Property (Sysprop) Catalog

**Scope:** Every `SYSTEM_PROPERTY_*_KEY` constant consumed by `v1/wms-api` · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-05-06

---

## 1. Overview

Runtime configuration in `wms-api` v1 is stored in the `los_sysprop` PostgreSQL table (tenant DB) and accessed via `LosSyspropRepository`. Every key has a canonical constant in `WmsConstants.java:862-1062`; most have a `*_DEFAULT_VALUE` or `*_VALUE` companion constant used as a fallback when the DB row is missing.

**Total keys documented:** 91 (all `SYSTEM_PROPERTY_*_KEY` constants, lines 862–1070).

Three things to keep in mind:

1. **No caching layer.** Unlike v2, v1 has no `@Cacheable` on sysprop reads. Each `findSysvalueBySyskey()` call hits the DB directly. High-frequency reads (e.g., per-request MULTIWAREHOUSE_IDENTIFIER checks) are live DB queries every time.
2. **Fallback is code-side only.** There is no `application.properties` fallback. When a DB row is missing, the consumer either uses its companion constant inline or returns null. Missing rows do **not** auto-create (unlike v2 `getSysvalue`).
3. **Scheduler reads are startup-time only.** `SchedulingConfiguration` reads timer sysprops once at Spring context refresh and wires fixed `CronTrigger` objects. Changing a schedule sysprop at runtime has no effect until the next restart. See [wms1-scheduled-jobs-catalog.md](../architecture/wms1-scheduled-jobs-catalog.md) §2.3.

---

## 2. Access Layer

`net/aim_ai/wms/repo/jpa/LosSyspropRepository.java` exposes:

| Method | Returns | Behavior when row missing |
|---|---|---|
| `findSysvalueBySyskey(String syskey)` | `String` | Returns null; no auto-create |
| `findBySyskey(String syskey)` | `List<LosSysprop>` | Returns empty list |
| `findSysvalueByClientIdAndSyskey(Long clientId, String syskey)` | `String` | Returns null |
| `findBySyskeyAndClientId(Long clientId, String syskey)` | `Optional<LosSysprop>` | Returns empty Optional |
| `findBySyskeyContaining(String partialKey)` | `List<LosSysprop>` | Returns empty list |

**Key SQL used by `findSysvalueBySyskey`:**
```sql
SELECT sysvalue FROM los_sysprop
WHERE syskey = :syskey AND workstation = 'DEFAULT'
ORDER BY client_id LIMIT 1
```

The `ORDER BY client_id LIMIT 1` means when multiple rows exist for the same key (different clients), the row with the lowest `client_id` is returned. This is a known legacy quirk — the comment in the repository says "legacy code incorrectly assumes one result."

---

## 3. Global Cron Activation Gates

These are checked first by every business cron job. See [wms1-scheduled-jobs-catalog.md](../architecture/wms1-scheduled-jobs-catalog.md) §2.4 for full details.

| Constant | DB Key | Type | Default | Effect |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` | `NEW_CRON_JOB_ACTIVATED` | Boolean | `true` | Master kill-switch; all five cron jobs check this first |
| `SYSTEM_PROPERTY_OLD_CRON_JOB_ACTIVATED_KEY` | `OLD_CRON_JOB_ACTIVATED` | Boolean | `false` | Legacy cron path — keep `false` unless rolling back |
| `SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG_KEY` | `CRON_JOB_SHOW_LOG` | Boolean | `false` | Enables verbose per-job debug logging across all jobs |

**Consumed by:** `schedulejob/SchedulingConfiguration.java` (all three, at startup); individual job classes check `NEW_CRON_JOB_ACTIVATED` at runtime.

---

## 4. Per-Job Timer Keys

Format: cron expression assembled as `"0 " + minutes + " " + hours + " * * *"`. Read once at startup by `SchedulingConfiguration`. Changing these at runtime requires a restart.

### 4.1 OrderReleaseJob

| Constant | DB Key | Type | Default | Role |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_ORDER_TIMER_HOUR_KEY` | `ORDER_TIMER_HOUR` | String (cron field) | `*` | Cron hour field → every hour by default |
| `SYSTEM_PROPERTY_ORDER_TIMER_MINUTE_KEY` | `ORDER_TIMER_MINUTE` | String (cron field) | `*` | Cron minute field → every minute by default |
| `SYSTEM_PROPERTY_ORDER_TIMER_ACTIVATED_KEY` | `ORDER_TIMER_ACTIVATED` | Boolean | `true` | Per-job activation gate |

**Consumed by:** `schedulejob/SchedulingConfiguration.java:98-99` (timer), job class checks `ORDER_TIMER_ACTIVATED`.

### 4.2 ReplenishOrderJob

| Constant | DB Key | Type | Default | Role |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_REPLENISHMENT_TIMER_HOUR_KEY` | `REPLENISHMENT_TIMER_HOUR` | String (cron field) | `*` | Cron hour field |
| `SYSTEM_PROPERTY_REPLENISHMENT_TIMER_MINUTE_KEY` | `REPLENISHMENT_TIMER_MINUTE` | String (cron field) | `*` | Cron minute field |
| `SYSTEM_PROPERTY_REPLENISHMENT_TIMER_ACTIVATED_KEY` | `REPLENISHMENT_TIMER_ACTIVATED` | Boolean | `true` | Per-job activation gate |

**Consumed by:** `schedulejob/SchedulingConfiguration.java:115-116` (timer).

### 4.3 CleanUpOldMessagesJob

| Constant | DB Key | Type | Default | Role |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_TIMER_HOUR_KEY` | `CLEAN_UP_OLD_MESSAGES_TIMER_HOUR` | String (cron field) | `2` | Cron hour field → 02:xx daily by default |
| `SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_TIMER_MINUTE_KEY` | `CLEAN_UP_OLD_MESSAGES_TIMER_MINUTE` | String (cron field) | `55` | Cron minute field → 02:55 daily by default |
| `SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_PERIOD_KEY` | `CLEAN_UP_OLD_MESSAGES_PERIOD` | Integer (days) | `365` | Retain messages younger than N days; older rows deleted |
| `SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY` | `CLEAN_UP_OLD_MESSAGES_ACTIVATED` | Boolean | `false` | Per-job activation gate — off by default |

**Consumed by:** `schedulejob/SchedulingConfiguration.java:81-82` (timer).

### 4.4 StockSummaryExportJob

| Constant | DB Key | Type | Default | Role |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_HOUR_KEY` | `STOCK_SUMMARY_EXPORT_TIMER_HOUR` | String (cron field) | `3` | Cron hour field → 03:00 daily by default |
| `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_MINUTE_KEY` | `STOCK_SUMMARY_EXPORT_TIMER_MINUTE` | String (cron field) | `0` | Cron minute field |
| `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED_KEY` | `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED` | Boolean | `true` | Per-job activation gate |
| `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED_KEY` | `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED` | Boolean | `true` | Split export into batches |
| `SYSTEM_PROPERTY_STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH_KEY` | `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH` | Integer | `250` | SKUs per batch when split is active |

**Consumed by:** `schedulejob/SchedulingConfiguration.java:132-133` (timer); `StockSummaryExportJob` reads split keys at runtime.

### 4.5 ReleaseExpiredPickingOrdersFromUserJob

This job has a **hard-coded** cron schedule (`0 * * * * *` — every minute at :00) — not driven by sysprops. Only the pick timeout behavior is sysprop-controlled.

| Constant | DB Key | Type | Default | Role |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY` | `PICK_TIME_OUT_SYSTEM_ACTIVATED` | Boolean | `false` | Per-job activation gate — off by default |
| `SYSTEM_PROPERTY_PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE_KEY` | `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` | Integer (seconds) | `40` | Idle-pick expiry threshold: PICKED orders idle ≥ N seconds are released back to pool |
| `SYSTEM_PROPERTY_PICK_TIME_OUT_MOBILE_KEY` | `PICK_TIME_OUT_MOBILE` | Integer (seconds) | `30` | Mobile UI countdown displayed to picker (UI-only; does not control server expiry) |

**Consumed by:** job reads `PICK_TIME_OUT_SYSTEM_ACTIVATED` and `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` at runtime; `controller/mobile/PickingController.java:192` reads `PICK_TIME_OUT_MOBILE` for the UI countdown.

### 4.6 StaleClubBatchCleanupJob

| Constant | DB Key | Type | Default | Role |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR_KEY` | `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` | String (cron field) | `3` | Cron hour field → 03:00 daily by default |
| `SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE_KEY` | `STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE` | String (cron field) | `0` | Cron minute field |
| `SYSTEM_PROPERTY_STALE_CLUB_BATCH_CLEANUP_ACTIVATED_KEY` | `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` | Boolean | `false` | Per-job activation gate — off by default |

**Consumed by:** `schedulejob/SchedulingConfiguration.java:164-165` (timer); `StaleClubBatchCleanupJob` checks `NEW_CRON_JOB_ACTIVATED` + `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` at runtime. Seeded by `db/migration/V1.1.07__wms_updates.sql` (IDs 140-142).

---

## 5. OMS Integration Webservice URLs

Every key here is a URL endpoint for OMS callbacks. All defaults point at `oms-XXXXX.siteboss.net` placeholders and **must be overridden per-tenant** before going live. The override format is a full HTTPS URL.

| Constant | DB Key | Default (placeholder) | Effect |
|---|---|---|---|
| `SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY` | `WEBSERVICE_CLOSE_ADVICE` | `https://oms-XXXXX.siteboss.net/services/call/closeAdvice` | Called when an inbound advice is closed |
| `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY` | `WEBSERVICE_ACCEPT_TRANSFER` | `.../services/call/closeTransfer` | Called when a transfer order is accepted |
| `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL_KEY` | `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `.../services/call/receiveHubAndSpoke` | Called when hub-and-spoke receiving is completed |
| `SYSTEM_PROPERTY_WEBSERVICE_STOCK_COUNT_URL_KEY` | `WEBSERVICE_STOCK_COUNT` | `.../call/inventory/stockCountExport` | Stock count export push to OMS; `controller/MessageDummyController.java:40` |
| `SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY` | `WEBSERVICE_STOCK_UPDATE` | `.../call/inventory/stockUpdate` | Stock update push to OMS; `controller/ItemDataController.java:99` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING_URL_KEY` | `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `.../services/call/readytopick` | Callback when order batch released for picking |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED_URL_KEY` | `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `.../services/call/assignedToteID` | Callback when tote assigned to picking batch |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_PICKING_URL_KEY` | `WEBSERVICE_ORDER_BATCH_PICKING` | `.../services/call/picking` | Callback when batch enters picking state |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_FINISHED_PICKING_URL_KEY` | `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `.../services/call/finishedPicking` | Callback when batch picking is complete |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_HELD_URL_KEY` | `WEBSERVICE_ORDER_BATCH_HELD` | `.../services/call/held` | Callback when batch is held |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY` | `WEBSERVICE_ORDER_BATCH_SHIPPED` | `.../services/call/finishedShipping` | Callback when batch shipped; `service/BillofladingService.java:579-580` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` | `WEBSERVICE_ORDER_BATCH_CANCELLED` | `.../services/call/cancelPosition` | Callback when batch cancelled; `service/CustomerorderBatchService.java:232` |
| `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED_KEY` | `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` | `false` | Activation gate for the cancelled callback — must be `true` to send cancellations |
| `SYSTEM_PROPERTY_WEBSERVICE_TEST_CRM_CONNECTIVITY_URL_KEY` | `WEBSERVICE_TEST_CRM_CONNECTIVITY` | `.../services/call/testPsd` | OMS connectivity test endpoint; `controller/AdminActionController.java:122` |
| `SYSTEM_PROPERTY_WEBSERVICE_FACILITY_LIST_LOOKUP_URL_KEY` | `WEBSERVICE_FACILITY_LIST_LOOKUP` | `.../services/call/facilities` | Facility list lookup from OMS; `service/BillofladingService.java:1188` |
| `SYSTEM_PROPERTY_WEBSERVICE_BEHAVIOUR_KEY` | `WEBSERVICE_BEHAVIOUR` | `keep` | Emergency switch: `send` = send callbacks normally, `discard` = drop silently without sending, `keep` = queue/retain without sending. Use `discard` during OMS outages. |

**Note on `WEBSERVICE_BEHAVIOUR`:** The `SYSTEM_PROPERTY_WEBSERVICE_BEHAVIOUR_ADDITIONAL_CONTENT` constant (value: `"possible values: send discard keep"`) is stored alongside this key in `los_sysprop.additionalcontent` as a human-readable hint for operators.

---

## 6. Multi-Warehouse / Facility Keys

| Constant | DB Key | Type | Default | Effect | Where consumed |
|---|---|---|---|---|---|
| `SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY` | `MULTIWAREHOUSE_IDENTIFIER` | String | `add_identifier` (placeholder) | Identifies this WMS instance in multi-warehouse routing. Must be set to the warehouse's routing tag. | `controller/rest/AbstractRestController.java:17`, `controller/rest/AdviceRestController.java:493`, `controller/rest/TransactionReportRestController.java:102,239`, `service/BillofladingService.java:551`, `service/CustomerorderBatchService.java:202` |
| `SYSTEM_PROPERTY_WAREHOUSE_NAME_KEY` | `WAREHOUSE_NAME` | String | `WAREHOUSE_NAME` (placeholder) | Human-readable warehouse display name | `service/BillofladingService.java:1088` (active); `service/ReceivingService.java:466` (commented out) |
| `SYSTEM_PROPERTY_WMS_INSTANCE_NAME_KEY` | `WMS_INSTANCE_NAME` | String | `WAREHOUSE_NAME` (placeholder) | WMS instance identifier (distinct from warehouse name) | Provisioning reference; no active runtime consumer found |
| `SYSTEM_PROPERTY_WAREHOUSE_TIME_ZONE_KEY` | `System Time Zone` | String (IANA tz) | — (no default constant) | Warehouse-local timezone. Note: **key literal contains a space** — `"System Time Zone"` — which is unusual and must match exactly in DB. | Read by `BasicService` time-zone helpers |
| `SYSTEM_PROPERTY_OMS_TENANT_ID_KEY` | `OMS_TENANT_ID` | String | — (no default constant) | OMS-side tenant identifier for cross-system correlation | Provisioning reference; must be set per tenant |

**MULTIWAREHOUSE_IDENTIFIER** is the most frequently read sysprop at runtime — every inbound REST request and BOL operation reads it. An `add_identifier` placeholder value will cause routing to fail.

---

## 7. Replenishment Tuning Keys

These drive `ReplenishOrderJob` and `ReplenishmentOrderMaintenanceService`.

| Constant | DB Key | Type | Default | Effect | Where consumed |
|---|---|---|---|---|---|
| `SYSTEM_PROPERTY_MERGE_PICKING_ORDERS_KEY` | `MERGE_PICKING_ORDERS` | Boolean | `true` | Enable tote-on-cart merge pass during replenishment | `ReplenishmentOrderMaintenanceService` (via `MERGE_PICKING_ORDERS_VALUE`) |
| `SYSTEM_PROPERTY_PICKING_BOX_PER_CART_KEY` | `PICKING_BOX_PER_CART` | Integer | `6` | Cart capacity cap — max totes/boxes per cart | `ReplenishmentOrderMaintenanceService` |
| `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_KEY` | `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND` | Integer (%) | `36` | Fixed-assignment minimum fill threshold (%) | `ReplenishmentOrderMaintenanceService` |
| `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_KEY` | `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND` | Integer (%) | `60` | Fixed-assignment middle threshold (%) | `ReplenishmentOrderMaintenanceService` |
| `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY` | `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` | Integer (%) | `84` | Fixed-assignment full threshold (%); read via `findSysvalueBySyskey` | `service/ReplenishmentOrderMaintenanceService.java:381-383` |
| `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY_KEY` | `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` | Boolean | `false` | Auto-delete empty fixed assignments. **Typo preserved in code and DB key** — `EMTPY` not `EMPTY`. Fixing requires a coordinated code + DB migration change. | `ReplenishmentOrderMaintenanceService` |
| `SYSTEM_PROPERTY_REPLENISHMENT_ALLOW_ANY_UNIT_LOAD_KEY` | `REPLENISHMENT_ALLOW_ANY_UNIT_LOAD` | Boolean | `true` | Accept any unit load type during replenishment | `ReplenishmentOrderMaintenanceService` |
| `SYSTEM_PROPERTY_REPLENISHMENT_SHOW_UNIT_LOAD_KEY` | `REPLENISHMENT_SHOW_UNIT_LOAD` | Boolean | `true` | UI flag — show unit load info on replenishment screen | `ReplenishmentOrderMaintenanceService` |
| `SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_CADENCE_SECONDS_KEY` | `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` | Long (seconds) | `0` | Minimum seconds between replenishment recalculation passes. `0` = no throttle (recalculate every trigger). | `service/ReplenishmentOrderMaintenanceService.java:158-160` |
| `SYSTEM_PROPERTY_REPLENISHMENT_CANCEL_THRESHOLD_FRACTION_KEY` | `REPLENISHMENT_CANCEL_THRESHOLD_FRACTION` | Decimal (fraction) | `0.0` | Auto-cancel replenishment threshold as fraction of outstanding demand. `0.0` = never auto-cancel. | `service/ReplenishmentOrderMaintenanceService.java:387-389` |

---

## 8. Printing & Label Keys

### 8.1 Case and Pallet Labels

| Constant | DB Key | Type | Default | Effect | Where consumed |
|---|---|---|---|---|---|
| `SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY` | `PRINT_CASE_LABEL` | Boolean | `true` | Master gate: if `false`, `PrintService` skips case label printing entirely | `service/PrintService.java:94,135` |
| `SYSTEM_PROPERTY_PRINTING_ZPL_CASE_LABEL_KEY` | `PRINTING_ZPL_CASE_LABEL` | String (ZPL) | — (no default) | ZPL template for case labels | `PrintService` |
| `SYSTEM_PROPERTY_PRINTING_ZPL_OUTBOUND_PALLET_LABEL_KEY` | `PRINTING_ZPL_OUTBOUND_PALLET_LABEL` | String (ZPL) | `add zpl code` (placeholder) | ZPL template for outbound pallet labels | `BillofladingService`, `PrintService` |
| `SYSTEM_PROPERTY_PRINTING_SEQUENCE_NAME_DEFAULT_OUTBOUND_PALLET_LABEL_KEY` | `SEQUENCE_NAME_DEFAULT_OUTBOUND_PALLET_LABEL` | String | `PALLET_OUTBOUND` | Sequence generator name for outbound pallet label IDs | `service/BillofladingService.java:954` |
| `SYSTEM_PROPERTY_PRINTING_PATTERN_OUTBOUND_PALLET_LABEL_KEY` | `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` | String (printf) | `OUT-%1$06d` | Label ID format string; `%1$06d` = zero-padded 6-digit integer | `service/BillofladingService.java:955` |

### 8.2 Tote Labels

| Constant | DB Key | Type | Default | Effect | Where consumed |
|---|---|---|---|---|---|
| `SYSTEM_PROPERTY_PRINTING_ZPL_TOTE_LABEL_VERSION_KEY` | `ZPL_TOTE_LABEL_VERSION` | String enum | — (no default) | Selects tote label variant: `REGULAR` or `AUTOMATION`. Controls which ZPL template key is looked up next. | `service/OrderMonitorViewService.java:199`, `service/PrintService.java:71,73-76` |
| `SYSTEM_PROPERTY_PRINTING_ZPL_PICKING_TOTE_LABEL_KEY` | `PRINTING_ZPL_PICKING_TOTE_LABEL` | String (ZPL) | — (no default) | ZPL template for regular picking tote labels | `service/OrderMonitorViewService.java:206`, `service/PrintService.java:76` |
| `SYSTEM_PROPERTY_PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION_KEY` | `PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION` | String (ZPL) | — (no default) | ZPL template for automation-lane picking tote labels | `service/OrderMonitorViewService.java:204`, `service/PrintService.java:74` |
| `SYSTEM_PROPERTY_PRINTING_TOTE_LABEL_DETAILS_KEY` | `PRINTING_TOTE_LABEL_DETAILS` | String enum | `LOCATION` | Extra content on tote label. Currently `LOCATION` is the only handled value. | `service/OrderMonitorViewService.java:280,282` |
| `SYSTEM_PROPERTY_PRINTING_DEFAULT_AMOUNT_TOTE_LABEL_KEY` | `PRINTING_DEFAULT_AMOUNT_TOTE_LABEL` | Integer | `1` (from provisioning comment) | Default label count per tote print job | `OrderMonitorViewService` |
| `SYSTEM_PROPERTY_PRINTING_MAXIMUM_AMOUNT_TOTE_LABEL_KEY` | `PRINTING_MAXIMUM_AMOUNT_TOTE_LABEL` | Integer | `1000` (from provisioning comment) | Maximum label count per tote print job | `OrderMonitorViewService` |
| `SYSTEM_PROPERTY_PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL_KEY` | `PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL` | String | `PICKING_TOTE_DEFAULT` (from provisioning comment) | Default sequence generator name for tote label IDs | `service/OrderMonitorViewService.java:131` |
| `SYSTEM_PROPERTY_PRINTING_PATTERN_DEFAULT_TOTE_LABEL_KEY` | `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` | String (printf) | `P-%1$04d` (from provisioning comment) | Default tote label ID format (zero-padded 4-digit) | `service/OrderMonitorViewService.java:141` |
| `SYSTEM_PROPERTY_PRINTING_SEQUENCE_NAME_CLIENT_SPECIFIC_TOTE_LABEL_KEY` | `PRINTING_SEQUENCE_NAME_CLIENT_SPECIFIC_TOTE_LABEL` | String | — | Per-client override for tote sequence name; falls back to default if absent | `service/OrderMonitorViewService.java:124` |
| `SYSTEM_PROPERTY_PRINTING_PATTERN_CLIENT_SPECIFIC_TOTE_LABEL_KEY` | `PRINTING_PATTERN_CLIENT_SPECIFIC_TOTE_LABEL` | String (printf) | — | Per-client override for tote label pattern; falls back to default if absent | `service/OrderMonitorViewService.java:134` |

### 8.3 CUPS Printing Server

| Constant | DB Key | Type | Default | Effect | Where consumed |
|---|---|---|---|---|---|
| `SYSTEM_PROPERTY_CUPS_SERVER_ADDRESS_IP_KEY` | `CUPS_SERVER_ADDRESS_IP` | String (hostname/IP) | `cups-01.advancedinfomanagement.com` | CUPS print server hostname or IP | `service/PrintService.java:95,136` |
| `SYSTEM_PROPERTY_CUPS_SERVER_ADDRESS_PORT_KEY` | `CUPS_SERVER_ADDRESS_PORT` | Integer | `631` | CUPS server port (IPP standard port) | `service/PrintService.java:96,137` |
| `SYSTEM_PROPERTY_CUPS_SERVER_ADDRESS_USERNAME_KEY` | `CUPS_SERVER_ADDRESS_USERNAME` | String | `aimprint` | CUPS auth username | `service/PrintService.java:97` |
| `SYSTEM_PROPERTY_CUPS_SERVER_ADDRESS_PASSWORD_KEY` | `CUPS_SERVER_ADDRESS_PASSWORD` | String | `Csof-ZP00-lY3C` | CUPS auth password. **Stored plain text in WmsConstants default.** Override per environment — never use the default in production. | `service/PrintService.java:98` |

---

## 9. Barcode / Pattern Validation Keys

Regex values matched against scanned barcodes throughout the mobile picking and inbound flows.

| Constant | DB Key | Type | Default pattern | Matches | Where consumed |
|---|---|---|---|---|---|
| `SYSTEM_PROPERTY_STRING_PATTERN_INBOUND_PALLET_KEY` | `STRING_PATTERN_INBOUND_PALLET` | Regex | `CART-\d{4}\|IN-\d{6}` | `CART-1234` or `IN-123456` | Inbound / putaway mobile flows |
| `SYSTEM_PROPERTY_STRING_PATTERN_PICKING_TOTE_KEY` | `STRING_PATTERN_PICKING_TOTE` | Regex | `T-\d{4}` | `T-1234` | Picking tote scan validation |
| `SYSTEM_PROPERTY_STRING_PATTERN_OUTBOUND_PALLET_KEY` | `STRING_PATTERN_OUTBOUND_PALLET` | Regex | `OUT-\d{6}` | `OUT-123456` | Outbound pallet scan validation |
| `SYSTEM_PROPERTY_STRING_PATTERN_SEPARATE_STOCK_KEY` | `STRING_PATTERN_SEPARATE_STOCK` | Regex | `SU-\d{6}` | `SU-123456` | Separate stock unit scan validation |
| `SYSTEM_PROPERTY_STRING_PATTERN_PICKING_PARCEL_KEY` | `STRING_PATTERN_PICKING_PARCEL` | Regex | `P-\d{4}` | `P-1234` | Picking parcel scan validation |

---

## 10. Keycloak / Authentication Keys

No `*_DEFAULT_VALUE` constants — all values are `"TO_BE_ADDED"` placeholders. **These rows must be populated per-tenant** or authentication will fail.

| Constant | DB Key | Effect |
|---|---|---|
| `SYSTEM_PROPERTY_KEYCLOAK_LOGOUT_URL_KEY` | `KEYCLOAK_LOGOUT_URL` | Post-logout redirect URL |
| `SYSTEM_PROPERTY_KEYCLOAK_APP_GROUP_NAME_KEY` | `KEYCLOAK_APP_GROUP_NAME` | Keycloak group that grants WMS access |
| `SYSTEM_PROPERTY_KEYCLOAK_SERVER_URL_KEY` | `KEYCLOAK_SERVER_URL` | Keycloak base URL |
| `SYSTEM_PROPERTY_KEYCLOAK_REALM_KEY` | `KEYCLOAK_REALM` | Keycloak realm name |
| `SYSTEM_PROPERTY_KEYCLOAK_CLIENT_KEY` | `KEYCLOAK_CLIENT` | Keycloak client ID |
| `SYSTEM_PROPERTY_KEYCLOAK_API_USER_KEY` | `KEYCLOAK_API_USER` | Service-account username for Keycloak API calls |
| `SYSTEM_PROPERTY_KEYCLOAK_OMS_USER_PREFERRED_SCHEMA_KEY` | `KEYCLOAK_OMS_USER_PREFERRED_SCHEMA` | Schema used when provisioning OMS users via Keycloak |
| `SYSTEM_PROPERTY_KEYCLOAK_OMS_USER_GROUP_KEY` | `KEYCLOAK_OMS_USER_GROUP` | OMS user group binding in Keycloak |
| `SYSTEM_PROPERTY_OMS_API_USER_KEY` | `OMS_API_USER` | OMS-side service account (default: `wms-dev-tst/biteme1234` — always override in production) |
| `SYSTEM_PROPERTY_SYSTEM_OMS_NAME_KEY` | `SYSTEM_OMS_NAME` | OMS instance identifier (default: `ChangeMe`) |
| `SYSTEM_PROPERTY_SYSTEM_WMS_NAME_KEY` | `SYSTEM_WMS_NAME` | WMS instance identifier (default: `WMS`) |
| `SYSTEM_PROPERTY_WMS_LOGIN_SECRET_KEY` | `WMS_LOGIN_SECRET` | Legacy login secret for pre-Keycloak auth paths |

---

## 11. Cycle Count Keys

| Constant | DB Key | Type | Default | Effect |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_KEY` | `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` | Boolean | `true` | Show expected quantity on the cycle count screen |
| `SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY_KEY` | `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` | Integer | `0` | Only show expected qty when counted differs by ≥ N. `0` = always show (with `SHOW_EXPECTED_AMOUNT=true`). |
| `SYSTEM_PROPERTY_CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT_KEY` | `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT` | Boolean | `true` | Require operator comment when recounting after a discrepancy |

---

## 12. Shipping Keys

| Constant | DB Key | Type | Default | Effect |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_SHIPPING_METHOD_ACTIVATED_KEY` | `SHIPPING_METHOD_ACTIVATED` | Boolean | `false` | Enable the shipping-method feature in the UI and service layer |
| `SYSTEM_PROPERTY_SHIPPING_SHOW_MANIFEST_LOCATION_KEY` | `SHOW_MANIFEST_LOCATION` | Boolean | `false` | Show manifest-location column in the bill-of-lading UI |

---

## 13. Inbound / Receiving Keys

| Constant | DB Key | Type | Default | Effect | Where consumed |
|---|---|---|---|---|---|
| `SYSTEM_PROPERTY_MAXIMUM_RECEIVING_DURING_INBOUND_KEY` | `MAXIMUM_RECEIVING_DURING_INBOUND` | Integer | `100` | Cap on concurrent inbound receiving rows | `ReceivingService` |
| `SYSTEM_PROPERTY_INBOUND_UPDATE_STOCK_IMMEDIATELY_KEY` | `INBOUND_UPDATE_STOCK_IMMEDIATELY` | Boolean | `true` | Apply stock delta immediately on receive (`true`) vs. batch update later (`false`) | `ReceivingService` |
| `SYSTEM_PROPERTY_REQUIRE_RECEIVING_TO_CONTAINER_KEY` | `REQUIRE_RECEIVING_TO_CONTAINER` | Boolean | `TRUE` | Enforce container scan during inbound receiving. Note: default is string `"TRUE"` (uppercase) — parsed with `Boolean.parseBoolean()` which is case-insensitive. | `controller/ReceivingController.java:265` |

---

## 14. Picking — UI Keys

| Constant | DB Key | Type | Default | Effect |
|---|---|---|---|---|
| `SYSTEM_PROPERTY_PICK_SCREEN_SIMPLE_KEY` | `PICK_SCREEN_SIMPLE` | Boolean | `false` | Use simplified pick screen variant on mobile |
| `SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY` | `PICK_PATH_DIRECTION` | String (enum) | `VERTICAL` | Location traversal order for picking, putaway, stock moves, and cycle counts. `VERTICAL` = column-first; `HORIZONTAL` = row-first. Read by `service/PickPathConfig.java` (30 s TTL cache). Valid values: `HORIZONTAL`, `VERTICAL`. Seeded by `db/migration/V1.1.09__pick_path_direction.sql` (id=143). |

---

## 15. System / Infrastructure Keys

| Constant | DB Key | Type | Default | Effect | Where consumed |
|---|---|---|---|---|---|
| `SYSTEM_PROPERTY_MOBILE_UI_URL_KEY` | `MOBILE_UI_URL` | String (URL) | `http://localhost:8080/los-mobile` | Mobile UI base URL | UI redirect logic |
| `SYSTEM_PROPERTY_MOBILE_UI_REDIRECT_URL_KEY` | `MOBILE_UI_REDIRECT_URL` | String (URL) | `TO_BE_ADDED` | Post-SSO mobile redirect URL | SSO callback handling |
| `SYSTEM_PROPERTY_WEB_UI_REDIRECT_URL_KEY` | `WEB_UI_REDIRECT_URL` | String (URL) | `TO_BE_ADDED` | Post-SSO web redirect URL | SSO callback handling |
| `SYSTEM_PROPERTY_DEFAULT_BOX_TYPE_KEY` | `DEFAULT_BOX_TYPE` | String | `COLLTRL` (`UL_TYPE_BOX_NAME_14`) | Default unit load box type used when no box type is specified during inbound receiving | `controller/rest/AdviceRestController.java:293,540` |
| `SYSTEM_PROPERTY_ORDER_MONITOR_CALCULATE_OLDER_THAN_DAYS_KEY` | `ORDER_MONITOR_CALCULATE_OLDER_THAN_DAYS` | Integer (days) | `10` | Lookback window in days for order monitor view. **Also embedded directly in `OrderMonitorView` entity SQL** (`model/OrderMonitorView.java:88`) and `OrderMonitorViewRepository` native queries — this key is read at DB query time via a join to `los_sysprop`, not via Java code. | `model/OrderMonitorView.java:88`, `repo/jpa/OrderMonitorViewRepository.java:99,183,263,347` |
| `SYSTEM_PROPERTY_EXPORT_LIMIT_KEY` | `EXPORT_LIMIT` | Integer | `10000` | Maximum rows per CSV export | Export services |
| `SYSTEM_PROPERTY_EXPORT_DATE_FORMAT_KEY` | `EXPORT_DATE_FORMAT` | String (pattern) | `YYYY-MM-dd HH:mm:ss.SSS` | Date format string used in CSV exports |  Export services |
| `SYSTEM_PROPERTY_CSV_FILE_SEPARATOR_KEY` | `CSV_FILE_SEPARATOR` | String (char) | `,` | CSV column separator character | Export services |
| `SYSTEM_PROPERTY_DB_VERSION_KEY` | `DB_VERSION` | String | — (no default) | Current DB schema version; written by the provisioning process, read-only at runtime | Admin/version endpoints |

---

## 16. Debt & Cleanup

### 16.1 Naming inconsistency: `_VALUE` vs `_DEFAULT_VALUE`

Several companion constants use `_VALUE` instead of the expected `_DEFAULT_VALUE` naming convention. They function identically as fallback values but are inconsistent with the majority pattern:

- `SYSTEM_PROPERTY_PRINT_CASE_LABEL_VALUE` (should be `_DEFAULT_VALUE`)
- `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_VALUE`
- `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_VALUE`
- `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_VALUE`
- `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY_VALUE`
- `SYSTEM_PROPERTY_MERGE_PICKING_ORDERS_VALUE`
- `SYSTEM_PROPERTY_INBOUND_UPDATE_STOCK_IMMEDIATELY_VALUE`

### 16.2 Typo preserved in DB key

`FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` — should be `EMPTY`. The typo is encoded in both the Java constant name and the DB key string. Fixing requires a coordinated rename of the constant, a DB migration to rename the `syskey` row, and any client-provisioning scripts that reference it.

### 16.3 Keys with no default constant

These keys have a `*_KEY` constant but **no** companion default in WmsConstants. The consumer either fails silently (null check) or requires the DB row to exist:

- All Keycloak keys (§10) — all 12 are mandatory; no defaults exist
- `PRINTING_ZPL_CASE_LABEL` — ZPL must be in DB
- `ZPL_TOTE_LABEL_VERSION` — version must be in DB; code does not handle null version
- `PRINTING_ZPL_PICKING_TOTE_LABEL` — ZPL must be in DB
- `PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION` — ZPL must be in DB
- `PRINTING_DEFAULT_AMOUNT_TOTE_LABEL` — provisioning comment suggests `1` but no constant
- `PRINTING_MAXIMUM_AMOUNT_TOTE_LABEL` — provisioning comment suggests `1000` but no constant
- `PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL` — provisioning suggests `PICKING_TOTE_DEFAULT`
- `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` — provisioning suggests `P-%1$04d`
- `DB_VERSION` — written by provisioning, no meaningful default
- `OMS_TENANT_ID` — tenant-specific, no default
- `System Time Zone` — warehouse-specific, no default

Audit these when provisioning a new tenant — missing rows either break features silently or cause NPEs.

### 16.4 Commented-out provisioning block

`controller/rest/UtilRestController.java:120-210` contains a large block of commented-out `losSyspropService.createSystemProperty(...)` calls — one for every sysprop key. This was the original auto-provisioning mechanism for new tenants. It is **entirely commented out** and no longer runs. New tenant provisioning must be done manually (or via a separate migration/script).

### 16.5 Magic-string consumers (keys not from constants)

| File:Line | Context |
|---|---|
| `controller/PrinterController.java:237` | `losSyspropRepository.findSysvalueBySyskey(labelKey)` where `labelKey` is a method parameter passed by the caller |
| `controller/rest/UtilRestController.java:827` | `losSyspropRepository.findSysvalueBySyskey(key)` where `key` is an API request parameter — this is the generic admin sysprop-read endpoint, expected behavior |

The `PrinterController` case warrants auditing to confirm every `labelKey` value passed by callers corresponds to a known constant.

### 16.6 `ORDER_MONITOR_CALCULATE_OLDER_THAN_DAYS` — dual-access pattern

This key is consumed both via Java code and **directly in a native SQL view** (`model/OrderMonitorView.java` and `OrderMonitorViewRepository` native queries). The SQL joins `los_sysprop` inline to get the value. This means the key is read at query execution time — not via `findSysvalueBySyskey`. No caching, no Java fallback applies to this path.

---

## 17. How to Use This Doc

| Task | Start at |
|---|---|
| Enable a cron job in a new tenant | §3 (master gate) + §4 (per-job `_ACTIVATED` + `_TIMER_*` overrides) |
| Configure OMS callbacks | §5 — every `WEBSERVICE_*` URL key must be overridden away from the `XXXXX` placeholder |
| Configure multi-warehouse routing | §6 — set `MULTIWAREHOUSE_IDENTIFIER` first; most inbound REST calls fail without it |
| Provision Keycloak auth | §10 — all 12 keys are mandatory; none have defaults |
| Tune replenishment behavior | §7 |
| Set up label printing | §8.2 (`ZPL_TOTE_LABEL_VERSION` must be set), §8.3 (CUPS credentials) |
| Change export format | §15 (`EXPORT_LIMIT`, `EXPORT_DATE_FORMAT`, `CSV_FILE_SEPARATOR`) |
| Audit for missing rows on new tenant | §16.3 — provision these manually; they have no constants as fallback |
| Understand why a sysprop change had no effect on cron timing | §1 point 3 — scheduler reads are startup-time only; restart required |

---

## 18. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-27 | `WmsConstants.java:862-1062` full constant block, `LosSyspropRepository.java` method signatures and SQL, all active consumer references via grep across `src/main/java/`, `schedulejob/SchedulingConfiguration.java` startup reads, `PrintService.java`, `OrderMonitorViewService.java`, `BillofladingService.java`, `ReplenishmentOrderMaintenanceService.java`, `CustomerorderBatchService.java`, `AdviceRestController.java`, `ReceivingController.java`, `PickingController.java`, `AdminActionController.java`, `ItemDataController.java`, `AbstractRestController.java` | All 87 keys cataloged; active consumer file:line references confirmed; default values verified against constant declarations; commented-out provisioning block identified | Code read (grep-based) |
| 2026-05-06 | `WmsConstants.java:1009-1014` (STALE_CLUB_BATCH_CLEANUP_* constants), `WmsConstants.java:1069-1070` (PICK_PATH_DIRECTION constant), `db/migration/V1.1.07__wms_updates.sql` (IDs 140-142), `db/migration/V1.1.09__pick_path_direction.sql` (id=143), `SchedulingConfiguration.java:164-165`, `service/PickPathConfig.java`, `util/DefaultStrategy.java`, `util/CycleCountStrategy.java` | 4 new keys added (§4.6 STALE_CLUB_BATCH_CLEANUP_* × 3, §14 PICK_PATH_DIRECTION × 1); total count updated 87 → 91 | Code grep |

**Re-verify every 90 days.** Next due: **2026-07-26** — sysprop surface in v1 grows slowly; additions are typically added as paired `_KEY` + `_DEFAULT_VALUE` constants in `WmsConstants.java`.
