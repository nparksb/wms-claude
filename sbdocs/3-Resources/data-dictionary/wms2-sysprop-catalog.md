---
title: "WMS v2 — System Property (Sysprop) Catalog"
type: data-dictionary
status: active
version: v2
scope: sysprops
owner: Nam Park
created: 2026-04-19
updated: 2026-07-24
last_verified: 2026-07-24
verified_by: SBDEV-1762/1666 lane-toggle seed provenance (Flyway V2.2.04, PR #93); constants land via open PRs #91/#92. Prior full read of WmsConstants.java + SyspropService.java (2026-04-19)
related:
  - ../architecture/wms2-scheduled-jobs-catalog.md
  - ../architecture/wms2-tenant-routing-datasource-topology.md
  - ./wms2-landlord-vs-tenant-entity-map.md
  - ./wms2-domain-glossary.md
tags:
  - data-dictionary
  - sysprop
  - configuration
  - wms2
---

# WMS v2 — System Property (Sysprop) Catalog

**Scope:** Every `sysprop` key consumed by `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-07-24

---

## 1. Overview

Configuration in `wms2-api` flows through a per-tenant `sysprop` table in the **tenant DB**, accessed via `SyspropService`. Each key has a canonical constant in `WmsConstants.java:879-1069` paired with a `*_DEFAULT_VALUE` companion; the default is used only when the DB row is missing. There is **no application.properties fallback** — if the constant exists in code but has no DB row and no default constant, the consumer either hard-codes a default inline or fails at read time.

Three things to keep in mind:

1. **Sysprop reads hit the tenant DB**, not landlord. They go through `TenantContext` and the routing datasource — a scheduled job must have set tenant context before reading.
2. **`@Cacheable(value = "sysprops", key = "{facilityCode}:{key}")`** is applied to `getSysvalue` and `getByKey`. Changes to `sysprop` table rows are **not** immediately visible to running processes — the cache TTL must expire or the service restart.
3. **Fallback chain** is tenant-DB row → system-client default value (constant) → null. There is no env-var or `application.properties` path.

**Total keys documented:** ~77 (WmsConstants.java lines 879–1069). A handful more use magic strings passed as parameters (see §11).

---

## 2. Access Layer

`net/aim_ai/wms/service/SyspropService.java` exposes:

| Method | Returns | Caching | Behavior when row missing |
|---|---|---|---|
| `getSysvalue(String key)` | `String` | cached | Creates a `sysprop` row with null value, returns null |
| `getStringDefault(String key, String default)` | `String` | cached | Returns the `default` parameter |
| `getByKey(String key)` | `Sysprop` entity | cached | Same as `getSysvalue`: row is auto-created |

The `sysprop` table is defined on the tenant side (see [wms2-landlord-vs-tenant-entity-map.md](./wms2-landlord-vs-tenant-entity-map.md) §Configuration & System — `Sysprop` → table `los_sysprop`).

**Auto-creation side effect:** the first read of any unknown key *writes* a row. If your sysprop audit shows a key with a null value, that row exists only because something read it at least once — not because an operator configured it.

---

## 3. Global Activation Gates

The five business cron jobs (see [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md)) all check these first:

| Constant | Key | Default | Purpose |
|---|---|---|---|
| `SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` | `NEW_CRON_JOB_ACTIVATED` | `true` | Master kill-switch across all five cron jobs |
| `SYSTEM_PROPERTY_OLD_CRON_JOB_ACTIVATED_KEY` | `OLD_CRON_JOB_ACTIVATED` | `false` | Legacy cron path — keep off unless a rollback is in progress |
| `SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG_KEY` | `CRON_JOB_SHOW_LOG` | `false` | Verbose per-job debug logging |

Class-level gate `app.cron` (at `application.properties:111`) is separate — it controls whether `SchedulingConfiguration` registers the cron jobs at all.

---

## 4. Per-Job Timer Keys

Format: cron fields are assembled as `{sec} {MINUTE} {HOUR} * * *`. `*` means "every".

### 4.1 OrderReleaseJob

| Key | Default | Role |
|---|---|---|
| `ORDER_TIMER_MINUTE` | `*` | Cron minute field |
| `ORDER_TIMER_HOUR` | `*` | Cron hour field |
| `ORDER_TIMER_ACTIVATED` | `true` | Per-job activation |

### 4.2 ReplenishOrderJob

| Key | Default | Role |
|---|---|---|
| `REPLENISHMENT_TIMER_MINUTE` | `*` | Cron minute field |
| `REPLENISHMENT_TIMER_HOUR` | `*` | Cron hour field |
| `REPLENISHMENT_TIMER_ACTIVATED` | `true` | Per-job activation |

### 4.3 CleanUpOldMessagesJob

| Key | Default | Role |
|---|---|---|
| `CLEAN_UP_OLD_MESSAGES_TIMER_MINUTE` | `55` | Cron minute field |
| `CLEAN_UP_OLD_MESSAGES_TIMER_HOUR` | `2` | Cron hour field (→ 02:55 daily) |
| `CLEAN_UP_OLD_MESSAGES_PERIOD` | `365` | Days to retain messages. Parsed via `Integer.parseInt`; malformed value throws `BusinessException.INVALID_SYSPROP_VALUE` (SBDEV-2220) |
| `CLEAN_UP_OLD_MESSAGES_ACTIVATED` | `false` | Per-job activation |
| `CLEAN_UP_OLD_MESSAGES_BATCH_SIZE` | `1000` | DELETE batch size per iteration; clamped to [1, 100000] (SBDEV-2220) |
| `CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS` | `0` | Optional inter-batch sleep in ms; clamped to [0, 5000]; default 0 disables throttling (SBDEV-2220) |

### 4.4 StockSummaryExportJob

| Key | Default | Role |
|---|---|---|
| `STOCK_SUMMARY_EXPORT_TIMER_MINUTE` | `0` | Cron minute field |
| `STOCK_SUMMARY_EXPORT_TIMER_HOUR` | `3` | Cron hour field (→ 03:00 daily) |
| `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED` | `true` | Per-job activation |
| `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED` | `true` | Split export into batches |
| `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH` | `250` | Batch size |

### 4.5 ReleaseExpiredPickingOrdersFromUserJob

| Key | Default | Role |
|---|---|---|
| `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` | `40` | Seconds before a PICKED-but-idle order gets released |
| `PICK_TIME_OUT_SYSTEM_ACTIVATED` | `false` | Per-job activation |
| `PICK_TIME_OUT_MOBILE` | `30` | Mobile-side pick countdown (UI) |

### 4.6 RestIdempotencyCleanupJob (SBDEV-2222) — application.properties only

This job does **not** use DB sysprop rows. Its schedule and idempotency enforcement are controlled by `application.properties` entries, not by `los_sysprop` table rows.

| Property | Default | Role |
|---|---|---|
| `app.cron.cleanup-rest-idempotency` | `0 0 2 * * *` | Cron expression for nightly dedup-table cleanup (02:00 daily) |
| `app.idempotency.enforce` | `true` | When `false`, `IdempotencyFilter` passes through all `/rest/**` writes without dedup (dev bypass) |
| `app.idempotency.max-body-bytes` | `5242880` (5 MB) | Requests with body exceeding this size bypass dedup (DoS guard). Checked against Content-Length header first; authoritative post-buffering check handles chunked encoding. |
| `app.idempotency.bridge-mode` | `false` | Set `true` during the UUID→SHA-256 transition window (first 7 days after 260520 deploy) to replay pre-existing UUID-keyed 2xx rows. Disable after Day+7 to avoid extra DB roundtrip on every CLAIMED request. |

### 4.7 OutboxDispatcherJob (SBDEV-2221) — application.properties only

This job does **not** use DB sysprop rows. All tuning knobs are controlled by `application.properties` entries.

| Property | Default | Role |
|---|---|---|
| `app.cron.outbox-dispatcher` | `*/15 * * * * *` | Cron expression — every 15 s; override to slow down in dev |
| `app.outbox.dispatcher.batch-size` | `10` | Max rows claimed per tenant per tick (`FOR UPDATE SKIP LOCKED`) |
| `app.outbox.dispatcher.max-attempts` | `5` | Attempts before a row is marked `FAILED_TERMINAL`; conservative until OMS confirms idempotency-key support |
| `app.outbox.dispatcher.retention-days` | `7` | Days to retain `SENT` rows before cleanup at the end of each tick |

---

## 5. OMS Integration Webservice URLs

Every key here has a `*_URL` suffix; defaults point at `oms-XXXXX.siteboss.net` placeholders and **must** be overridden per-tenant.

| Key | Default (placeholder) |
|---|---|
| `WEBSERVICE_CLOSE_ADVICE` | `https://oms-XXXXX.siteboss.net/services/call/closeAdvice` |
| `WEBSERVICE_ACCEPT_TRANSFER` | `https://oms-XXXXX.siteboss.net/services/call/closeTransfer` |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `https://oms-XXXXX.siteboss.net/services/call/receiveHubAndSpoke` |
| `WEBSERVICE_STOCK_COUNT` | `.../call/inventory/stockCountExport` |
| `WEBSERVICE_STOCK_UPDATE` | `.../call/inventory/stockUpdate` |
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `.../services/call/readytopick` |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `.../services/call/assignedToteID` |
| `WEBSERVICE_ORDER_BATCH_PICKING` | `.../services/call/picking` |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `.../services/call/finishedPicking` |
| `WEBSERVICE_ORDER_BATCH_HELD` | `.../services/call/held` |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `.../services/call/finishedShipping` |
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `.../services/call/palletized` |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `.../services/call/loadedToTruck` |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `.../services/call/cancelPosition` |
| `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` | `false` (activation flag) |
| `WEBSERVICE_TEST_CRM_CONNECTIVITY` | `.../services/call/testPsd` |
| `WEBSERVICE_FACILITY_LIST_LOOKUP` | `.../services/call/facilities` |
| `WEBSERVICE_BEHAVIOUR` | `keep` (possible values: `send`, `discard`, `keep`) |

**`WEBSERVICE_BEHAVIOUR`** is the emergency switch: set to `discard` to drop all OMS callbacks without sending, or `keep` to queue them silently. Use during OMS outages.

---

## 6. Replenishment Tuning

These drive `ReplenishOrderJob` and `ReplenishmentOrderMaintenanceService`.

| Key | Default | Purpose |
|---|---|---|
| `MERGE_PICKING_ORDERS` | `true` | Enable tote-on-cart merge pass |
| `PICKING_BOX_PER_CART` | `6` | Cart capacity cap |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND` | `36` | Fixed-assignment minimum fill % |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND` | `60` | Fixed-assignment middle threshold |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` | `84` | Fixed-assignment full threshold |
| `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` *(sic)* | `false` | Auto-delete empty fixed assignments (typo preserved in code: `EMTPY`) |
| `REPLENISHMENT_ALLOW_ANY_UNIT_LOAD` | `true` | Accept any unit load during replenish |
| `REPLENISHMENT_SHOW_UNIT_LOAD` | `true` | UI flag — show unit load on replenish screen |
| `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` | `0` | Min seconds between recalc passes (`0` = no throttle) |
| `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` | `0` | Epoch-ms timestamp of the last completed `recalculateOpenOrders` pass. Replaces the JVM-local `lastRun` field (SBDEV-2234). Written by `ReplenishmentOrderMaintenanceService.setLastRun` via `SyspropService.setSysvalue`; evicts the `sysprops` Caffeine cache on write. Absent row treated as `Instant.EPOCH` (cadence always elapsed). |
| `REPLENISHMENT_CANCEL_THRESHOLD_FRACTION` | `0.0` | Auto-cancel threshold (fraction of outstanding demand) |
| `REPLENISHMENT_PAGE_SIZE` | `1000` | Page size for paginated drain-queue loops in `ReplenishOrderJob` (all 6 sub-ops). Introduced SBDEV-2228. |
| `REPLENISHMENT_PAGE_LIMIT` | `100` | Max drain-queue iterations per sub-op (all 6 sub-ops including 6a). All sub-ops use drain-queue; empty-page terminates normally. Introduced SBDEV-2228. |
| `FIX_LOCATION_PAGE_LIMIT` | `100` | Max pages for the fix-location prefetch loop in `OrderReleaseJob.releaseOrders`. Logs a warning when cap is hit (map may be incomplete). Introduced SBDEV-2228. |
| `OMS_EXPORT_CONSUMER_TIMEOUT_S` | `120` | Seconds the `StockSummaryExportJob` OMS consumer thread waits to enqueue a chunk, receive the POISON_PILL, and for `join()`. Min 30. Prevents the advisory lock being held indefinitely when OMS is slow. Introduced SBDEV-2228. |
| `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` | `false` | Per-tenant opt-in (SBDEV-1666). When `true`, staging/transfer lanes (`location.staginglane`/`transferlane`) are never selected as a replenishment **source** — threaded as a bound `:excludeLanes` boolean into the gated source/shortage queries (`getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage`, `getAvailableReplenishmentSources`, `findUnitloadsByItemDataIdForReplenish`, `getRefillFixedLocations(Ids)`, `getIdsForItemDataWithoutFixedAssignment(+Page)`), and mirrored in `isSourceUsable`, `syncForMovedStockUnit` (destination-lane guard), and the mobile manual re-source check. OFF path is plan-identical (`:excludeLanes = FALSE` constant-folds). Absent row → `Boolean.parseBoolean(null)=false` → OFF. NOTE: the two HAL display queries (`getStockUnitInfoForReplenishment`, `getStockUnitsForReplenishment`) and the replenishment monitor view exclude lanes **unconditionally** (display-only, not gated by this key). **Seed:** row seeded **default OFF** by Flyway **V2.2.04** (`V2.2.04__seed_lane_behavior_sysprop_toggles.sql`, PR #93); constant + gating land via PR #92 (SBDEV-1666, open). |

---

## 7. Printing & Label Templates

ZPL (Zebra Programming Language) templates and sequence naming.

| Key | Default | Purpose |
|---|---|---|
| `PRINTING_ZPL_CASE_LABEL` | *(no constant default)* | Case-label ZPL template |
| `ZPL_TOTE_LABEL_VERSION` | *(no constant default)* | `REGULAR` or `AUTOMATION` |
| `PRINTING_ZPL_PICKING_TOTE_LABEL` | *(no constant default)* | Picking-tote ZPL |
| `PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION` | *(no constant default)* | Automation variant |
| `PRINTING_ZPL_OUTBOUND_PALLET_LABEL` | `add zpl code` (placeholder) | Outbound-pallet ZPL |
| `PRINTING_TOTE_LABEL_DETAILS` | `LOCATION` | Extra content on tote label |
| `PRINTING_DEFAULT_AMOUNT_TOTE_LABEL` | — | Default count per print job |
| `PRINTING_MAXIMUM_AMOUNT_TOTE_LABEL` | — | Max count per print job |
| `PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL` | — | Default sequence generator name |
| `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` | — | Default label pattern |
| `PRINTING_SEQUENCE_NAME_CLIENT_SPECIFIC_TOTE_LABEL` | — | Client-specific override |
| `PRINTING_PATTERN_CLIENT_SPECIFIC_TOTE_LABEL` | — | Client-specific override |
| `SEQUENCE_NAME_DEFAULT_OUTBOUND_PALLET_LABEL` | `PALLET_OUTBOUND` | Default outbound sequence |
| `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` | `OUT-%1$06d` | Outbound pallet pattern (printf-style) |
| `PRINT_CASE_LABEL` | `true` | Hard-coded `true` default — legacy flag |

### CUPS Printing Server

| Key | Default |
|---|---|
| `CUPS_SERVER_ADDRESS_IP` | `cups-01.advancedinfomanagement.com` |
| `CUPS_SERVER_ADDRESS_PORT` | `631` |
| `CUPS_SERVER_ADDRESS_USERNAME` | `aimprint` |
| `CUPS_SERVER_ADDRESS_PASSWORD` | `Csof-ZP00-lY3C` *(stored plain text in constant — rotate per environment)* |

---

## 8. Barcode / Pattern Validation

Regexes matched against scanned barcodes.

| Key | Default pattern | Matches |
|---|---|---|
| `STRING_PATTERN_INBOUND_PALLET` | `CART-\d{4}\|IN-\d{6}` | `CART-1234` or `IN-123456` |
| `STRING_PATTERN_PICKING_TOTE` | `T-\d{4}` | `T-1234` |
| `STRING_PATTERN_OUTBOUND_PALLET` | `OUT-\d{6}` | `OUT-123456` |
| `STRING_PATTERN_SEPARATE_STOCK` | `SU-\d{6}` | `SU-123456` |
| `STRING_PATTERN_PICKING_PARCEL` | `P-\d{4}` | `P-1234` |

---

## 9. Keycloak / Authentication

No `*_DEFAULT_VALUE` constants — **these rows must be populated per-tenant** or auth will fail.

| Key | Purpose |
|---|---|
| `KEYCLOAK_LOGOUT_URL` | Logout redirect |
| `KEYCLOAK_APP_GROUP_NAME` | Group name that grants WMS access |
| `KEYCLOAK_SERVER_URL` | Keycloak base URL |
| `KEYCLOAK_REALM` | Keycloak realm name |
| `KEYCLOAK_CLIENT` | Client ID |
| `KEYCLOAK_API_USER` | Service-account username |
| `KEYCLOAK_OMS_USER_PREFERRED_SCHEMA` | Used when provisioning OMS users |
| `KEYCLOAK_OMS_USER_GROUP` | OMS user group binding |
| `OMS_API_USER` | OMS-side service account |
| `SYSTEM_OMS_NAME` | OMS instance identifier |
| `SYSTEM_WMS_NAME` | WMS instance identifier |
| `WMS_LOGIN_SECRET` | Legacy login secret (pre-Keycloak paths) |

---

## 10. Cycle Count, Shipping, Inbound, Misc

### Cycle count

| Key | Default | Purpose |
|---|---|---|
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` | `true` | Show expected qty on the count screen |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` | `0` | Only show when diff ≥ N |
| `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT` | `true` | Require comment on recount |

### Shipping

| Key | Default | Purpose |
|---|---|---|
| `SHIPPING_METHOD_ACTIVATED` | `false` | Enable shipping-method feature |
| `SHOW_MANIFEST_LOCATION` | `false` | Show manifest-location column in BOL UI |

### Inbound / Receiving

| Key | Default | Purpose |
|---|---|---|
| `MAXIMUM_RECEIVING_DURING_INBOUND` | `100` | Cap on concurrent inbound rows |
| `INBOUND_UPDATE_STOCK_IMMEDIATELY` | `true` | Apply stock delta on receive (vs batched later) |
| `REQUIRE_RECEIVING_TO_CONTAINER` | `TRUE` | Enforce container scan on receive |

### Picking — UI

| Key | Default | Purpose |
|---|---|---|
| `PICK_SCREEN_SIMPLE` | `false` | Simplified pick screen variant |
| `PICK_PATH_DIRECTION` | `VERTICAL` | Sort direction for picking, putaway, cycle-count, and move-stock: `VERTICAL` = column-first (X→Y), `HORIZONTAL` = row-first (Y→X). Read via `PickPathConfig` → `SyspropService` (cached per-tenant). Seeded by migration V2.1.09. |

### Picking — Order-release behavioral guards

| Key | Default | Purpose |
|---|---|---|
| `ENFORCE_PARTITIONALLOWED` | `true` (default ON) | **SBDEV-2512** kill-switch for the overstock-release `partitionallowed` guard in `ReleaseOrderJobService.releaseOrder`. When ON, a non-partitionable (`partitionallowed=false`) customer-order position that no **single** stock unit can cover is **held** (position `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION`, order `RAW_ON_HOLD`) rather than fragmented across units (Fix A, round-2 cumulative), and a coverable one takes exactly **one** pick from a single covering unit (Fix B, phase 3). Read once per release via `SyspropService.getSysvalue`; **absent/null row also enforces** (`!"false".equalsIgnoreCase(...)`), so it is safe before seeding. Set `false` to restore legacy fragmenting behavior with **no redeploy** (Caffeine `sysprops` TTL ~2 min). Every v2 position is non-partitionable today (`OrderBatchCreationService` hard-codes `setPartitionallowed(false)`), so this is a 100%-blast-radius cron guard — the Fix A hold emits a mandatory `LOG.info`. |

### Transfer orders — lane depletion

| Key | Default | Purpose |
|---|---|---|
| `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` | `false` | Per-tenant opt-in (SBDEV-1762). When `true`, the Transfer-Order "run transfer" flow (`BillofladingService.transferOrder`) deplete-consumes **only** the order's required SKUs + quantities from the transfer lane — club-like — instead of the legacy exact-match + sweep-everything. Read once per `transferOrder` call via `SyspropService.getSysvalue`; absent row → `Boolean.parseBoolean(null)=false` → OFF (byte-identical to legacy). Constant + gating land via PR #91 (SBDEV-1762, open). **Seed:** row seeded **default OFF** by Flyway **V2.2.04** (`V2.2.04__seed_lane_behavior_sysprop_toggles.sql`, PR #93). |

### Misc

| Key | Default | Purpose |
|---|---|---|
| `System Time Zone` | — | Warehouse-local time zone (key literal contains a space) |
| `WAREHOUSE_NAME` | — | Human-readable warehouse name |
| `WMS_INSTANCE_NAME` | — | This WMS instance ID |
| `MOBILE_UI_URL` | `http://localhost:3001/mobile` | Mobile UI base URL |
| `MOBILE_UI_REDIRECT_URL` | — | Post-SSO mobile redirect |
| `WEB_UI_REDIRECT_URL` | — | Post-SSO web redirect |
| `DEFAULT_BOX_TYPE` | `UL_TYPE_BOX_NAME_14` (constant ref) | Default box type for unit loads |
| `MULTIWAREHOUSE_IDENTIFIER` | `add_identifier` (placeholder) | Multi-WH routing tag |
| `ORDER_MONITOR_CALCULATE_OLDER_THAN_DAYS` | `10` | Order-monitor view lookback |
| `EXPORT_LIMIT` | `10000` | Max rows per CSV export |
| `EXPORT_DATE_FORMAT` | `yyyy-MM-dd HH:mm:ss.SSS` | CSV export date format |
| `CSV_FILE_SEPARATOR` | `,` | CSV column separator |
| `DB_VERSION` | — | Current DB schema version (read-only) |
| `OMS_TENANT_ID` | — | OMS-side tenant identifier |

---

## 11. Cleanup / Debt

### Missing `*_DEFAULT_VALUE` constants

The following keys have a `*_KEY` constant but no paired default constant in `WmsConstants.java`. Consumers either hard-code a default inline or require the DB row to exist:

- All 8 Keycloak keys (§9)
- `PRINTING_ZPL_CASE_LABEL`, `ZPL_TOTE_LABEL_VERSION`, `PRINTING_ZPL_PICKING_TOTE_LABEL`, `PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION`
- `WAREHOUSE_NAME`
- `MERGE_PICKING_ORDERS` *(value constant exists but is named `..._VALUE`, not `..._DEFAULT_VALUE`)*
- `INBOUND_UPDATE_STOCK_IMMEDIATELY` *(same)*

Audit these when spinning up a new tenant — missing rows either break features silently or cause NPEs depending on consumer.

### Typo preserved

`FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` — should be `EMPTY`. The DB key string encodes the typo. Fixing it requires a coordinated code + migration change.

### Magic-string consumers (keys not declared as constants)

Two call sites accept a sysprop key as a method parameter rather than a constant reference:

| File:Line | Context |
|---|---|
| `controller/PrinterController.java:235` | `syspropService.getSysvalue(labelKey)` where `labelKey` is a method param |
| `controller/rest/UtilRestController.java:843` | `syspropService.getSysvalue(key)` where `key` is an API param (admin sysprop-read endpoint) |

The `UtilRestController` case is expected — it's a generic read-any-sysprop admin endpoint. The `PrinterController` case warrants auditing to confirm every `labelKey` value caller passes is itself backed by a constant.

---

## 12. How to use this doc

| Task | Start at |
|---|---|
| Provision a fresh client DB's per-client sysprops | Run **`db/configure-client-sysprops.sh`** (SBDEV-2607) — rewrites the base-dump `CHANGE-ME-FOR-NEW-CLIENT` placeholders (`MOBILE_UI_URL`, `MULTIWAREHOUSE_IDENTIFIER`, `WAREHOUSE_NAME`, `OMS_TENANT_ID`, `System Time Zone`, `SYSTEM_OMS_NAME`, `SYSTEM_WMS_NAME`, `WEBS%`) in one verified pass. See `[[wms2-greenfield-db-provisioning]]` §5. |
| Enable a cron job in a new tenant | §3 + §4 (set both the master + per-job `_ACTIVATED` flag + any `_TIMER_*` overrides) |
| Configure OMS callbacks | §5 — every `WEBSERVICE_*` must be overridden away from the placeholder (`CHANGE-ME-FOR-NEW-CLIENT/` in the `V2.2.00` base-dump seed; `configure-client-sysprops.sh --oms-api-base-url` sets them all at once) |
| Bring up a new Keycloak realm | §9 — all 8 keys are mandatory; no defaults exist |
| Tune replenish behavior | §6 |
| Change label print behavior | §7 |
| Audit for unknown sysprop rows | Query `SELECT key FROM los_sysprop EXCEPT` the union of keys in this doc — anything left is either magic-string debt (§11) or stale |
| Update a sysprop but change isn't visible | Remember the `@Cacheable`: restart the service or wait for cache TTL (§2) |

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `WmsConstants.java:879-1069` constants, `SyspropService.java` method signatures + caching annotation, fallback chain, magic-string consumers, "missing default" set | All keys + defaults + consumer shape confirmed | Code read (grep-based) |
| 2026-07-10 | Added `ENFORCE_PARTITIONALLOWED` (SBDEV-2512 overstock-release guard kill-switch, default ON) to §10 Picking — Order-release behavioral guards; total ~75→~76. | New key documented | SBDEV-2512 v2 port |
| 2026-07-19 | Documented `db/configure-client-sysprops.sh` (SBDEV-2607) as the greenfield per-client sysprop seeding tool; noted the `V2.2.00` base-dump placeholder is `CHANGE-ME-FOR-NEW-CLIENT`. No new keys. | Onboarding tooling documented | SBDEV-2607 |
| 2026-07-24 | Added `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` (SBDEV-1762) as new §10 Transfer-orders subsection; added Flyway **V2.2.04** seed provenance (PR #93, default OFF) to it and the existing `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` (SBDEV-1666) §6 entry. Feature constants land via open PRs #91/#92. Total ~76→~77. | New key + seed provenance documented | V2.2.04 seed work |

**Re-verify every 90 days.** Next due: **2026-10-08** — sysprop surface grows slowly; major additions (typically 2-3 keys per quarter) should be spot-checked against this catalog.
