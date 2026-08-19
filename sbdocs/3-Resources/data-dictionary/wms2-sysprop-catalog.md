---
title: "WMS v2 — System Property (Sysprop) Catalog"
type: data-dictionary
status: active
version: v2
scope: sysprops
owner: Nam Park
created: 2026-04-19
updated: 2026-08-13
last_verified: 2026-08-13
verified_by: "Full constant extraction (133 keys) against origin/develop + live los_sysprop read across 5 DEV+UAT tenant DBs + every post-V2.2.00 Flyway sysprop seed traced to its consumer, 2026-08-13. Earlier baseline: reports/260730-wms2-sysprop-current-value-census.md"
related:
  - ../reports/260730-wms2-sysprop-current-value-census.md
  - ../architecture/wms2-scheduled-jobs-catalog.md
  - ../architecture/wms2-tenant-routing-datasource-topology.md
  - ../architecture/wms2-oms-integration-map.md
  - ../architecture/wms2-greenfield-db-provisioning.md
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
**Owner:** Nam Park · **Last verified:** 2026-08-13

---

## 1. Overview

Configuration in `wms2-api` flows through a per-tenant `sysprop` table in the **tenant DB**, accessed via `SyspropService`. Each key has a canonical constant in `WmsConstants.java` paired with a `*_DEFAULT_VALUE` companion; the default is used only when the DB row is missing. Only 80 of the then-124 keys had that companion **as measured 2026-07-30** — the other 44 either hard-code a fallback at the call site or fail at read time. That ratio was not re-measured in the 2026-08-13 pass; the 9 keys added since split both ways (`REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` has one, the five `PRINTING_ZPL_*` do not). There is **no application.properties fallback** — if the constant exists in code but has no DB row and no default constant, the consumer either hard-codes a default inline or fails at read time.

Three things to keep in mind:

1. **Sysprop reads hit the tenant DB**, not landlord. They go through `TenantContext` and the routing datasource — a scheduled job must have set tenant context before reading.
2. **`@Cacheable(value = "sysprops", key = "{facilityCode}:{key}")`** is applied to `getSysvalue` and `getByKey`. Changes to `sysprop` table rows are **not** immediately visible to running processes — the cache TTL must expire or the service restart.
3. **Fallback chain** is tenant-DB row → system-client default value (constant) → null. There is no env-var or `application.properties` path.

**Total keys:** **133** constants — 132 `SYSTEM_PROPERTY_*_KEY` plus the nested
`LocationAreaService.PROPERTY_KEY_AREA_DEFAULT`. A handful more use magic strings passed as parameters
(see §12). Counted programmatically against **`origin/develop`**, not a working tree.

> ⚠ **Count against the remote, not your checkout.** The 2026-08-13 pass first read a local `wms2-api`
> that was **24 commits behind `origin/develop`**, which made the five new `PRINTING_ZPL_*` keys look
> like they had *no consumer in the codebase* — the `LabelPrintingService` that reads them merged in
> PR #155 and existed only on the remote. Same failure mode as the SBDEV-2781 enumeration trap:
> `git fetch` and grep the **remote ref** before concluding a key is orphaned.

> The earlier "~77" figure in this section was wrong — it undercounted from the start (the file already held
> 108 keys on 2026-04-19, this doc's own baseline date). Corrected 2026-07-30 from a full extraction; see
> [`260730-wms2-sysprop-current-value-census`](../reports/260730-wms2-sysprop-current-value-census.md) §2.10.

**Live values are not in this doc.** This catalog answers *"what is this key and what is its default."* For what
each tenant actually holds right now, see the dated census report above — values are per-tenant and
operator-editable, so they are captured as point-in-time snapshots rather than embedded here.

**Not every live key has a constant.** A census of the 5 active DEV+UAT tenants on 2026-07-30 found 146 distinct
keys against the 124 constants of that date. Most of the difference is legitimate: ~20 keys are pure UI-managed config that the Admin screen
reads generically via `GET /sysprop/search/findByGroupname?groupname=…` and Java never references by name
(`Warehouse Details`, `Operation Options`, `System Settings`, `System Info` groups). See §12 and census §2.2–2.5.

---

## 2. Access Layer

`net/aim_ai/wms/service/SyspropService.java` exposes:

| Method | Returns | Caching | Behavior when row missing |
|---|---|---|---|
| `getSysvalue(String key)` | `String` | cached, `unless #result == null` | Returns `null`. **Does not write.** |
| `getIntValue(String key, int default)` | `int` | via `getSysvalue` | Returns `default` on null, blank **or unparseable** |
| `getStringDefault(String key, String default)` | `String` | cached | Returns the `default` parameter |
| `getByKey(String key)` | `Sysprop` entity | cached | Returns null |
| `setSysvalue(String key, String value)` | `void` | `@CacheEvict` | **Creates** the row on the system client, workstation `DEFAULT` |

The `sysprop` table is defined on the tenant side (see [wms2-landlord-vs-tenant-entity-map.md](./wms2-landlord-vs-tenant-entity-map.md) §Configuration & System — `Sysprop` → table `los_sysprop`).

> ⚠ **CORRECTED 2026-08-13 — `getSysvalue` does NOT auto-create a row.** This doc previously said the
> first read of an unknown key writes a row with a null value, and several Flyway migrations
> (V2.2.04, V2.2.05, V2.2.06, V2.2.09, V2.2.10) justify their `WHERE NOT EXISTS` guard the same way.
> `SyspropService.java:288-291` is a pure read — `@Cacheable` wrapping a single
> `syspropRepository.findSysvalueBySyskey(key)` with no `save()`. The `save()` calls in that class are
> all on explicit write paths (`setSysvalue`, `createSystemProperty`). The migration guards are still
> **correct and still required** — a prior manual seed, a `setSysvalue` write, or a base-dump row all
> pre-create rows — just not for the stated reason. Do not "clean up" a `WHERE NOT EXISTS` on the
> strength of this correction.

**The read is workstation-pinned and client-blind.** `SyspropRepository:30`:

```sql
select sysvalue from los_sysprop where syskey = :syskey and workstation = 'DEFAULT' order by client_id LIMIT 1
```

Two consequences that cause silent misconfiguration:

1. A row whose `workstation` is anything other than `'DEFAULT'` is **invisible** to every feature flag.
2. `order by client_id LIMIT 1` is facility-wide. Every Flyway seed uses `client_id = 0`, the lowest
   possible value, so a **per-client override row can never win** — setting one of these keys for a
   specific client does nothing at all, with no error. Set the `client_id = 0` row.

**Cache behaviour** (`CacheConfig:36`): Caffeine, `expireAfterWrite` **2 minutes**, max 200 entries,
key `facilityCode + ':' + syskey`, **per JVM replica**. So a direct SQL `UPDATE` — including one run by
a Flyway migration — is invisible for up to 2 minutes, independently per replica, and replicas actively
disagree during that window. `setSysvalue` carries `@CacheEvict` but only evicts on the replica that
served the request; cross-replica invalidation exists only under the `redis` cache profile.
`unless = "#result == null"` means a missing row is never negatively cached and is re-queried on
every call.

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
| `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED` | `true` | Stream the export instead of materialising it |
| `STOCK_SUMMARY_EXPORT_MAX_ROWS` | `1000000` | Hard row ceiling for one export run |

> Neither of the two rows above exists in **any** DEV or UAT tenant (census 2026-07-30 §2.6) — the whole fleet
> runs on the code defaults. There is also a live, constant-less `STOCK_SUMMARY_EXPORT_SUPPRESS_ARCHIVED` key on
> two tenants that **nothing reads**; see census §2.3 before assuming it does anything.

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

### 4.6b StaleClubBatchCleanupJob (SBDEV-2164)

`schedulejob/StaleClubBatchCleanupJob.java`, serialised via `AdvisoryLockService`.

| Key | Default | Role |
|---|---|---|
| `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` | `false` | Per-job activation — **off by default** |
| `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` | `3` | Cron hour field |
| `STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE` | `0` | Cron minute field (→ 03:00 daily when activated) |

### 4.7 OutboxDispatcherJob (SBDEV-2221) — application.properties only

This job does **not** use DB sysprop rows. All tuning knobs are controlled by `application.properties` entries.

| Property | Default | Role |
|---|---|---|
| `app.cron.outbox-dispatcher` | `*/15 * * * * *` | Cron expression — every 15 s; override to slow down in dev |
| `app.outbox.dispatcher.batch-size` | `10` | Max rows claimed per tenant per tick (`FOR UPDATE SKIP LOCKED`) |
| `app.outbox.dispatcher.max-attempts` | `5` | Attempts before a row is marked `FAILED_TERMINAL`; conservative until OMS confirms idempotency-key support |
| `app.outbox.dispatcher.retention-days` | `7` | Days to retain `SENT` rows before cleanup at the end of each tick |

Two outbox keys **are** DB sysprops, despite the job's tuning living in `application.properties`. Both are seeded by `V2.2.05` — note that neither has a `*_DEFAULT_VALUE` constant, so a missing row reaches `Boolean.parseBoolean(null)` and reads as `false`:

| Key | Default | Role |
|---|---|---|
| `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` | seeded `false` by Flyway `V2.2.05` | Gates `OutboxDispatchService.sampleStuckAggregates()` — the held-aggregate gauge (see `[[wms2-unstick-held-outbox-aggregate]]`). Read-only query, but it runs on every dispatcher tick, so enable per tenant. |
| `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` | seeded `false` by Flyway `V2.2.05` | **SBDEV-2736 Phase-2 gate. Inert — nothing reads it yet.** No Java constant exists: it was deliberately deferred to Phase 2, since an unread constant cannot be type-checked against the migration literal. |

> ⚠️ **Do not set `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` to `true`.** Phase 2 enforcement is not built, and
> enforcing against today's rejection rate would wedge aggregates behind `FAILED_TERMINAL` siblings that are
> never auto-deleted. As of 2026-07-30 the row exists only on DEV (`V2.2.05` has not reached `release`).

---

## 5. OMS Integration Webservice URLs

Every key here has a `*_URL` suffix; defaults point at `oms-XXXXX.siteboss.net` placeholders and **must** be overridden per-tenant.

| Key | Default (placeholder) |
|---|---|
| `WEBSERVICE_CLOSE_ADVICE` | `https://oms-XXXXX.siteboss.net/services/call/closeAdvice` |
| `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` | `https://oms-XXXXX.siteboss.net/services/call/batchReversalCompleted` |
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
| `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` | `false` | Per-tenant opt-in (SBDEV-2854). Master switch for accepting a replenishment **destination** that is not a flowbin. **OFF:** the destination must be a flowbin — a single-SKU pick bin addressed through a `FixLocationAssignment` holding exactly one virtual `PICKLOCATION` unit load — so shared club locations (~110 real case/pallet ULs each) can never be a destination. **ON:** a destination is accepted when its functional **area** has `useforpicking = true`, **without** creating a fixed location assignment. Read at `MobileReplenishService.isNonFlowbinDestinationAllowed():853`; has an explicit `..._DEFAULT_VALUE = "false"` constant, so a null/blank row is also OFF. ⚠ **Capability, not location type, is the axis** — on wineco UAT the 70 club locations share type `cases and pallets` with 472 overstock racks in "Storage and Replenish" (what replenishment sources *from*), 40 outbound lanes, and `PutAwayLane`; a type allow-list would have opened all of them, and `PutAwayLane` sets none of the five lane flags so `isNonStorageLane` cannot see it. Mirrors the source side, which already asks `useforreplenish`. **Never accepted regardless of the flag:** `staginglane`, `gate`, `transferlane`, `automationlane`, `crossdockinglane`. **Seed:** default OFF by Flyway **V2.2.10**. |
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

### 7.1 Identity labels — Admin → Label Printing (SBDEV-2861)

Five ZPL templates added by Flyway `V2.2.14`/`V2.2.15`/`V2.2.16` and consumed by
`service/LabelPrintingService.java` (merged PR #155). **These are content, not toggles** — changing a
value changes what the printer emits; it does not turn a feature on or off.

The pre-existing `Labels` rows above are *content* labels (they describe a job: shipper, brand, tracking
number, racks) and cannot render without a `Customerorder`/`Pickingorder`/`Stockunit` behind them. These
five are *identity* labels — the barcode physically stuck on an empty tote or a rack face, carrying
nothing but the ID. That is why they are new templates rather than reuse.

| Key | Seed | Drives | Tokens |
|---|---|---|---|
| `PRINTING_ZPL_TOTE_ID_LABEL` | V2.2.14, 164 ch | tote generate / reprint / preview | `{tote_id} {warehouse} {date}` |
| `PRINTING_ZPL_LOCATION_LABEL` | V2.2.14, 192 ch | location style **GENERIC** | `{location} {area} {rack} {aisle} {warehouse} {date}` |
| `PRINTING_ZPL_FLOWBIN_LABEL` | V2.2.15, 298 ch | location style **FLOWBIN** | derived from the location *name* |
| `PRINTING_ZPL_OVERSTOCK_LABEL` | V2.2.15, 112 ch | location style **OVERSTOCK** | derived from the location *name* |
| `PRINTING_ZPL_UNIT_LOAD_ID_LABEL` | V2.2.16, 171 ch | unit-load identity reprint | `{label_id}` |

GENERIC requires the location row to exist — `area`/`rack`/`aisle` only live in the DB. FLOWBIN and
OVERSTOCK derive every token from the location **name**, so they preview and print for racking that has
not been configured yet (`LabelPrintingService:239`, `:609-621`).

Three behaviours to know before editing one:

- **Blank or missing fails loudly.** `requireTemplate()` throws `No ZPL template configured for <key>` —
  printing stops, it does not silently no-op.
- **Removing the identity token is rejected *before* any sequence number is consumed.**
  `requireTemplate(KEY, "{tote_id}")` (`:318`) and `requireTemplate(KEY, "{label_id}")` (`:532`) exist
  because a template that lost its token would print identity-less labels **while reporting every ID as
  successfully printed**.
- **Unresolved tokens render as `''`**, never left as literal `{...}` in the ZPL.

The seeded defaults deliberately omit `^PW`/`^LL` (so the printer's configured stock applies, matching
`PRINTING_ZPL_CASE_LABEL`) and use `^CI31` (UTF-8) like the existing templates.

**All five are byte-identical to the seeded default on all 5 DEV+UAT tenant DBs as of 2026-08-13**
(md5-compared against the migration literal) — no tenant has customized a label.

#### 7.1a Rollout prerequisites — the new tab depends on OLD keys

*Verified live on all 5 DEV+UAT tenants 2026-08-14.*

Seeding the five templates does **not** make the tab usable. `generateToteLabels` needs four things
the SBDEV-2861 migrations do not touch:

| Prerequisite | Where | Failure if unmet |
|---|---|---|
| `PRINT_CASE_LABEL` = `true` | sysprop | `requirePrintingEnabled()` throws for the whole tab. `cupsPrint` otherwise discards bytes and returns *normally* — a "successful" run at a printer that never moved |
| a `printer` row of type `OUTBOUND_TOTE` | `printer` table | `resolvePrinter()` fails; no tote generate or reprint |
| a tote **ID pattern** | resolved, see below | `No tote ID pattern configured` |
| `PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL` | sysprop | `No tote ID sequence configured` |

**The ID pattern is resolved in three steps, and the sysprop named for it is the LAST resort**
(`resolveTotePattern:890`):

1. `PRINTING_PATTERN_CLIENT_SPECIFIC_TOTE_LABEL` (client override; empty string is rejected loudly)
2. **derived from the scan pattern** — `toteFormatFromScanPattern(STRING_PATTERN_PICKING_TOTE)`,
   e.g. `T-\d{4}` → `T-%1$04d`. Derivation handles `^?<prefix>\d{N}$?` only; alternation, character
   classes and variable widths like `\d{4,5}` decline and fall through.
3. `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` — only if 1 and 2 both yield nothing.

That ordering is deliberate: the scan pattern is what **every pick validates against**, while
`PRINTING_PATTERN_DEFAULT_TOTE_LABEL` shipped as a `DEFAULT-%1$06d` placeholder on real tenants — an
ID no scan would ever accept. Whatever wins is still cross-checked by `requireScannableToteId` before
any sequence number is consumed, so a drifting override fails loudly instead of printing barcodes
picking would refuse.

**Live state, 2026-08-14:**

| Tenant DB | `PRINT_CASE_LABEL` | scan pattern | effective format | `OUTBOUND_TOTE` printer | ID capacity |
|---|---|---|---|---|---|
| `dev_wh01_om1` (dev wineco) | `true` | `T-\d{4}` | `T-%1$04d` (derived) | 2 ✅ | 10,000 |
| `wh01_om1_v2` (UAT wineco) | `true` | `T-\d{4}` | `T-%1$04d` (derived) | 1 ✅ | 10,000 |
| `wh01_hydra_v2` (UAT hydra) | `true` | `P-\d{4}` | `P-%1$04d` (derived) | 1 ✅ | 10,000 |
| `wh01_shipitez_v2` (UAT shipitez c1wh) | `true` | `C1-\d{4}` | `C1-%1$04d` (derived) | **0 ❌** | 10,000 |
| `wh02_shipitez_v2` (UAT shipitez nywh) | `true` | `P-\d{4}` | `P-%1$04d` (derived) | 1 ✅ | 10,000 |

Three things fall out of that table:

- ⚠ **`wh01_shipitez_v2` cannot print tote labels** — it has `INBOUND` and `RETURN` printers but no
  `OUTBOUND_TOTE`. This is the one hard blocker in the fleet; add the printer row before enabling the
  tab there.
- **Both wineco DBs carry `PRINTING_PATTERN_DEFAULT_TOTE_LABEL = DEFAULT-%1$06d`, and it is inert** —
  step 2 derives `T-%1$04d` from the scan pattern and step 3 is never reached. Do not "fix" it by
  aligning it to `T-%1$04d`; it changes nothing. Do not delete it either — it is the fallback for any
  future tenant whose scan pattern is not derivable.
- ⚠ **Every tenant's ceiling is exactly 10,000 tote IDs**, because every scan pattern is 4-digit.
  `requireScannableToteId` rejects the 5-digit ID, so generation hard-stops at the boundary — and a run
  that crosses it mid-batch burns the numbers already drawn. Raising it means editing
  `STRING_PATTERN_PICKING_TOTE`, which **every pick validates against**, so existing 4-digit totes must
  still match: `T-\d{4,5}` widens safely, `T-\d{5}` orphans every tote already on the floor.

**No tenant has a `PICKING_TOTE_DEFAULT` row in `los_sequencenumber`.** That is not a fault:
`SequenceTransactionService:34-38` creates the row on first use — but it creates it at `0` and
**returns `0`**, so the first tote ever generated on each of these tenants is `T-0000` / `P-0000` /
`C1-0000`, not `…-0001`. The preview's "next ID" sample reads `peekNextSequenceNumber`, which returns
`0` for a missing row (`:967`), and is labelled a sample in the UI.

#### `PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH` — a constant with no seed

| Key | Constant default | Seeded? | Live rows |
|---|---|---|---|
| `PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH` | `1000` (`FALLBACK_MAXIMUM_LABEL_BATCH`) | **no migration seeds it** | **0 of 5** tenant DBs |

Caps `labelId`s per reprint / location batch. Read via `syspropService.getIntValue(key, 1000)`
(`LabelPrintingService:1059`), whose null/blank/**unparseable** fallback makes the absent row safe — the
cap is enforced at 1000 everywhere today. It exists to stop an uploaded list becoming an unbounded SQL
`IN` clause, ZPL buffer and physical print job. Because nothing seeds it, it is **invisible in the config
UI** (the admin screen lists by `groupname`), so raising the cap for a tenant currently requires an
`INSERT`, not an edit.

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

#### `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` (SBDEV-2778) — the only flag that ships ON

| Key | Seed | Default when row absent | Read at |
|---|---|---|---|
| `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` | **`true`** (V2.2.09) | **`true` — ON** | `ReturnAdviceAutoReceiveService:176` |

ON: a `POST` of a `type=RETURN` advice is **received and closed at create time**, restoring the v1
behaviour SBDEV-2236 deleted (`AdviceRestController:236`). Set to `false`: the advice stays OPEN and is
received at the dock via `POST /v3/receiving/receive`. `TRANSFER` advices always take the dock route
regardless. Both types pre-validate `client.enablereceiving` before the advice is created.

⚠⚠ **Its absent-row default is ON, unlike every other flag in this catalog.** The read is
`!"false".equalsIgnoreCase(StringUtils.trimToEmpty(raw))` — deliberately **not** the house
`Boolean.parseBoolean(...)` pattern, because `parseBoolean(null) == false` would silently keep the
SBDEV-2778 bug on any tenant that had not yet run V2.2.09, looking identical to the pre-fix symptom.
Consequences:

- **Deleting the row does not disable the feature.** Only the literal `false` does.
- V2.2.09 is *not* what makes the fix safe — the default-ON read is. The migration only makes the
  switch visible and editable in the config UI.
- Do not "consistency-fix" this to `parseBoolean`; the code carries an explicit comment saying so.

A flip to `false` increments `wms2.returns.autoreceive.skipped_switch_off`, so the kill-switch shows up
in metrics rather than silently changing behaviour.

V2.2.09 also inserts a **`mywms_user`** row (not a sysprop) — a dedicated operator for auto-received
returns. Without it, `ReceivingService:359` resolves the operator from
`SecurityContextUtils.getUserName()`, and `/rest/**` is unauthenticated, so every auto-received return's
`goodsreceipt.operator_id` and stock-history row would be stamped with the shared `anonymous` user.

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
| `API_TIMESTAMP_FORMAT` | — *(no default const)* | Timestamp serialisation format for API responses. `ISO8601_UTC` on all 5 DEV+UAT tenants |
| `AREA_DEFAULT` | — *(no default const)* | Default location area. **Only key declared outside the `SYSTEM_PROPERTY_*_KEY` convention** — it lives at `WmsConstants.LocationAreaService.PROPERTY_KEY_AREA_DEFAULT` and is read by `LocationAreaService:66`, so a `SYSTEM_PROPERTY_` grep will miss it |
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

### Receiving — default putaway destination (SBDEV-2732)

| Key | Constant | Default | Purpose |
|---|---|---|---|
| `DEFAULT_PUTAWAY_LOCATION` | `SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY` | `''` (blank) | **Tier 3** of the putaway destination hierarchy: SKU → merchant → **warehouse** → `PutAwayLane` |

Holds a **location id as text**. Seeded blank by Flyway `V2.2.13`, so behaviour is unchanged until an
operator sets it.

**Blank-after-trim means "not configured"** and falls through to the standard `PutAwayLane` — it is not
a parse failure. A non-numeric value *is* a failure and raises `invalidSyspropValue`.

**Read path — do NOT use `SyspropService.getSysvalue` for this key.** The resolver reads it with
`findBySyskeyAndClientIdAndWorkstation(key, systemClientId, 'DEFAULT')`. The unique constraint is
`(client_id, syskey, workstation)`, so the workstation-blind helpers can return an arbitrary row, and
the `sysprops` cache key omits `clientId` (§2 landmines A3/A4). The row is pinned to the **system
client** and workstation `DEFAULT`; a row created under any other client or workstation is invisible
to the resolver.

**This key is not writable from the system-property screen.** `POST /v3/systemProperty/create`,
`/updateValue` and `/updateClient` all reject it with `putawayDestinationUseTypedEndpoint` (422),
because those paths save directly and bypass validation and auditing. Write it through
`PUT /putawayConfig/warehouse`, which validates the destination, records an audit row in
`putaway_config_audit`, and evicts the caches. `PATCH`/`POST` via Spring Data REST (`/v3/sysprop`) is
also guarded, by `PutawayConfigRepositoryEventHandler`.

**Deleting the row is accepted** (D12) — an absent row and a blank row are the same state to the
resolver. The typed writer re-creates it when absent, so deleting does not lock the tier out of the UI.

---

## 11. Flyway-Seeded Keys — Provenance, Live State, Default-Change Semantics

*Added 2026-08-13. Covers every `los_sysprop` seed after the `V2.2.00` base schema.*

### 11.1 The seeds

Eight of the sixteen post-`V2.2.00` migrations touch `los_sysprop`; the rest are views, functions and
tables only. Twelve keys merged, one unmerged.

| Migration | Key | Seeded value | Group | Ticket |
|---|---|---|---|---|
| V2.2.04 | `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` | `false` | Operation Options | SBDEV-1762 |
| V2.2.04 | `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` | `false` | Operation Options | SBDEV-1666 |
| V2.2.05 | `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` | `false` | Operation Options | SBDEV-2736 |
| V2.2.06 | `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` | `false` | Operation Options | SBDEV-2381 |
| V2.2.09 | `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` | **`true`** | Operation Options | SBDEV-2778 |
| V2.2.10 | `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` | `false` | Operation Options | SBDEV-2854 |
| V2.2.13 | `DEFAULT_PUTAWAY_LOCATION` | `''` (blank) | Operation Options | SBDEV-2732 |
| V2.2.14 | `PRINTING_ZPL_TOTE_ID_LABEL` | ZPL, 164 ch | Labels | SBDEV-2861 |
| V2.2.14 | `PRINTING_ZPL_LOCATION_LABEL` | ZPL, 192 ch | Labels | SBDEV-2861 |
| V2.2.15 | `PRINTING_ZPL_FLOWBIN_LABEL` | ZPL, 298 ch | Labels | — |
| V2.2.15 | `PRINTING_ZPL_OVERSTOCK_LABEL` | ZPL, 112 ch | Labels | — |
| V2.2.16 | `PRINTING_ZPL_UNIT_LOAD_ID_LABEL` | ZPL, 171 ch | Labels | — |
| **V2.2.11 — applies OUT OF ORDER** | `ADJUSTMENT_ALERT_POLL_ACTIVATED` | `false` | Operation Options | SBDEV-2658 |

Three things `ls db/migration/` will not tell you:

- ⚠ **`V2.2.11` merged *after* `V2.2.16` and therefore applies out of order.** It was authored on
  `feature/SBDEV-2658-inventory-adjustment-alert` while develop's head was 2.2.10, and merged
  2026-08-16 (PR #138, merge `c75c11a`) once develop had already reached 2.2.16. Every DB already at
  2.2.16 picks it up only because `app.flyway.out-of-order=true` — Flyway's default `outOfOrder=false`
  would reject the straggler and stop that database migrating altogether. Expect a WARN per tenant on
  the first boot after this ships; see `db/check-tenant-migration-drift.sh`. The general rule stands:
  versions are append-only and never reused, so re-sweep every remote ref right before opening a PR.
- `V2.2.14` was **authored as V2.2.10** and renumbered before merge (develop took 2.2.10–2.2.13
  first). It was never applied under the old number.
- `V2.2.09` also inserts a **`mywms_user`** row; `V2.2.16` is partly an `UPDATE` that strips the
  `SBDEV-2861: ` prefix from four earlier descriptions.

### 11.2 What each flag actually switches

| Key | ON does | OFF/absent does |
|---|---|---|
| `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` | `BillofladingService.transferOrder():764` deplete-consumes only the order's required SKUs/qty, reserved-adjusted (club-like); remainder stays on the lane | exact-match + sweep-everything — consumes the whole transfer lane |
| `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` | staging/transfer lanes are never picked as a replenishment **source**; an FLA whose only stock sits on a lane gets no replenish order | lanes are eligible sources (legacy) |
| `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` | **nothing — see 11.4** | nothing |
| `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` | `sampleStuckAggregates():317` runs the read-only `findStuckAggregateStats()` per tenant per dispatcher tick (15 s) and emits the held-aggregate gauge | returns `null`, no gauge row for that tenant |
| `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` | a `type=RETURN` advice is received **and closed at create time** | (only literal `false`) advice stays OPEN, received at the dock via `POST /v3/receiving/receive` |
| `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` | destination accepted when its area has `useforpicking = true`, no FLA created — club locations become valid | destination must be a flowbin with an FLA |
| `DEFAULT_PUTAWAY_LOCATION` | (location id) tier 3 of `SKU > merchant > warehouse > PutAwayLane` | blank = not configured, falls through to tier 4 |
| `ADJUSTMENT_ALERT_POLL_ACTIVATED` | `GET /v3/stockrecord/adjustmentAlerts` serves adjustment stockrecords to the web-UI bell/toast poller | returns an empty item list — the bell stays silent (absent row = OFF) |
| 5 × `PRINTING_ZPL_*` | not toggles — the template *is* the output (§7.1) | blank/missing throws `No ZPL template configured` |

### 11.3 Live state — DEV and UAT, 2026-08-13

**DEV** (landlord `dev_landlord`, one active tenant):

| Tenant | DB | Flyway head | Keys present | Deviations from seed |
|---|---|---|---|---|
| wineco/wsl ✅ active | `dev_wh01_om1` | 2.2.16, 0 failed | 12/12 | `TRANSFER_LANE_PARTIAL_DEPLETION`=**true**, `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES`=**true** |
| hydra/nywh ⛔ inactive | `wh01_hydra_v2` | **no `flyway_schema_history`** | **0/12** | — |
| shipitez/c1wh ⛔ inactive | `wh02_hydra` | not checked | — | — |
| shipitez/nywh ⛔ inactive | `wh01_hydra` | not checked | — | — |

**UAT** (all four active, all `uat.sbo.li`, all head 2.2.16 / 0 failed):

| Tenant | DB | Keys present | Deviations from seed |
|---|---|---|---|
| wineco/wsl | `wh01_om1_v2` | 12/12 | `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS`=**true** |
| hydra/nywh | `wh01_hydra_v2` | 12/12 | none |
| shipitez/c1wh | `wh01_shipitez_v2` | 12/12 | none |
| shipitez/nywh | `wh02_shipitez_v2` | 12/12 | none |

Every row on every DB: exactly one row, `client_id = 0`, `workstation = 'DEFAULT'`, groupname as seeded.
No duplicates, no client-scoped copies, no NULL-groupname strays. All five ZPL templates byte-identical
to the seed (md5-compared) on all five. `ADJUSTMENT_ALERT_POLL_ACTIVATED` absent everywhere.

⚠ **The dev hydra DB is unmanaged.** `wh01_hydra_v2` on dev has no `flyway_schema_history` and none of
the 12 keys despite holding 129 sysprop rows — a legacy psql-provisioned copy. `StartupFlywayMigrator`
calls `.baselineOnMigrate(false)` for tenants, so it is skipped and never auto-baselined; it is also
`active = false` in `dev_landlord`, so the app would not migrate it anyway. Repair once with
`db/backfill-flyway-history.sh --up-to <watermark>` before trusting anything tested against it.

⚠ **The two wineco environments are inverse configurations.** Dev has both lane toggles ON and
non-flowbin OFF; UAT has both lane toggles OFF and non-flowbin ON. Nothing is broken, but **dev is not
a rehearsal of UAT for any of those three features**.

### 11.4 `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` is inert

**Setting it `true` does nothing today.** Zero Java consumers on `origin/develop` — the only files in
the repo that mention it are the V2.2.05 and V2.2.06 migrations. SBDEV-2736 Phase 1 shipped
observability only (`wms2.outbox.oms_rejected`, `wms2.outbox.response_envelope`); Phase 2 enforcement
was never built. The row was seeded ahead of the code deliberately, so enabling Phase 2 later is a
config flip rather than a second operator DB step — the V2.2.04 lesson.

When Phase 2 does land, **do not flip it before the retryability classification is done**.
`OutboxMessageRepository` excludes any aggregate holding an earlier `FAILED_TERMINAL` sibling, and
those rows are never auto-deleted, so enforcing against today's rejection rate would wedge aggregates
that need operator action to clear. See [wms2-oms-integration-map.md](../architecture/wms2-oms-integration-map.md).

### 11.5 What happens when a default changes

"Default" means three different things here, and they fail differently.

**(a) Editing the seeded value in an already-applied migration — silent tenant freeze.**
`StartupFlywayMigrator` runs `.load().migrate()` with `validateOnMigrate` at its default (on) and
`ignoreMigrationPatterns` at its default (`*:future`, which does **not** cover a modified applied
version). Changing one character changes the checksum, so every DB that already applied it fails
validation and **its whole chain stops there**, including all later migrations. Tenant failures never
abort the boot — the migrator logs and moves on — so the app comes up healthy, probes stay green, and
one tenant silently stops receiving schema changes. Same shape as the prd `V2.2.07` ownership incident
— see `v2/wms2-api/CLAUDE.md` §Database and `db/reassign-tenant-ownership.sh`).

Precedent in this very chain: `V2.2.05` was amended after it had been applied to dev. Recovery was to
**re-align dev's history row to the original checksum and move the new seed into a fresh `V2.2.06`** —
never `flyway repair`, which rewrites the checksum to match the edited file and hides real drift.

**(b) Shipping a new migration with a different default — silent no-op.** Every seed is
`INSERT … SELECT … WHERE NOT EXISTS (SELECT 1 FROM los_sysprop WHERE syskey = '<KEY>')`. Idempotent by
design, which means **a new migration carrying a new default does nothing on any DB that already has
the row.** Only freshly provisioned databases get it; every existing tenant keeps the old value
forever, with no error.

Moving existing tenants needs an explicit `UPDATE`, which then overwrites operators' deliberate
settings — on the 11.3 numbers that would silently revert wineco dev's two lane toggles and wineco
UAT's non-flowbin flag. The safe form is `UPDATE … WHERE sysvalue = '<old default>'`, which moves only
the untouched tenants. Note the guard keys on `syskey` **alone**, not `client_id` or `workstation`, so
any pre-existing row with that key blocks the seed however it got there.

**(c) The DB row is not the runtime default.** See §2 for the workstation/client-blind read and the
2-minute per-replica cache. What happens on a missing or NULL row is decided in Java, and it is **not
uniform**:

| Read pattern | Absent/NULL → | Keys |
|---|---|---|
| `Boolean.parseBoolean(getSysvalue(k))` | `false` | lane toggles, outbox metric, adjustment poll |
| explicit `..._DEFAULT_VALUE` constant | `false` | `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` |
| `!"false".equalsIgnoreCase(trimToEmpty(raw))` | **`true`** | `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` |
| `getIntValue(k, fallback)` | the fallback | `PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH` |

⚠ **The two boolean families disagree about non-boolean text, and neither complains.** Under
`parseBoolean`, anything that is not `"true"` is false — so `yes`, `1`, `on` all silently **disable**
the feature. Under the return-advice pattern, anything that is not `false` is true — so `no`, `0`,
`off` all leave it **enabled**. A typo is accepted by both and reported by neither.

**(d) `description` is `varchar(255)`.** Postgres raises `22001` rather than truncating, and Flyway runs
each migration in one transaction — so a single over-long description rolls back **every row in that
file** and leaves the tenant's chain failed. Guarded by `SyspropMigrationDescriptionWidthTest`.
No working test lane catches an over-long value at runtime — the unit test is the only gate.

---

## 12. Cleanup / Debt

### Missing `*_DEFAULT_VALUE` constants

The following keys have a `*_KEY` constant but no paired default constant in `WmsConstants.java`. Consumers either hard-code a default inline or require the DB row to exist:

- All 8 Keycloak keys (§9)
- `PRINTING_ZPL_CASE_LABEL`, `ZPL_TOTE_LABEL_VERSION`, `PRINTING_ZPL_PICKING_TOTE_LABEL`, `PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION`
- All 5 SBDEV-2861 identity templates (§7.1) — no constant default by design; `requireTemplate()` throws instead of falling back, so a missing row is a loud failure rather than a silent wrong label
- `WAREHOUSE_NAME`
- `MERGE_PICKING_ORDERS` *(value constant exists but is named `..._VALUE`, not `..._DEFAULT_VALUE`)*
- `INBOUND_UPDATE_STOCK_IMMEDIATELY` *(same)*

Audit these when spinning up a new tenant — missing rows either break features silently or cause NPEs depending on consumer.

### Typo preserved

`FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` — should be `EMPTY`. The DB key string encodes the typo. Fixing it requires a coordinated code + migration change.

### Seeded but unread

`OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` has a row on all 5 tenant DBs and **zero consumers** in the
codebase (§11.4). It is deliberate, not debt — but it means an operator can toggle it in the config UI
and observe no effect whatsoever. Revisit when SBDEV-2736 Phase 2 lands.

### Constant with no seed and no UI presence

`PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH` (§7.1) has a code constant and a safe `getIntValue` fallback of
`1000`, but no migration seeds it and it is absent from all 5 tenant DBs. Because the admin screen lists
rows by `groupname`, it is invisible there — raising the cap for a tenant today requires an `INSERT`,
not an edit. A one-line seed in the next `V2.2.x` would close it.

### Magic-string consumers (keys not declared as constants)

Two call sites accept a sysprop key as a method parameter rather than a constant reference:

| File:Line | Context |
|---|---|
| `controller/PrinterController.java:235` | `syspropService.getSysvalue(labelKey)` where `labelKey` is a method param |
| `controller/rest/UtilRestController.java:843` | `syspropService.getSysvalue(key)` where `key` is an API param (admin sysprop-read endpoint) |

The `UtilRestController` case is expected — it's a generic read-any-sysprop admin endpoint. The `PrinterController` case warrants auditing to confirm every `labelKey` value caller passes is itself backed by a constant.

---

## 13. How to use this doc

| Task | Start at |
|---|---|
| Provision a fresh client DB's per-client sysprops | Run **`db/configure-client-sysprops.sh`** (SBDEV-2607) — rewrites the base-dump `CHANGE-ME-FOR-NEW-CLIENT` placeholders (`MOBILE_UI_URL`, `MULTIWAREHOUSE_IDENTIFIER`, `WAREHOUSE_NAME`, `OMS_TENANT_ID`, `System Time Zone`, `SYSTEM_OMS_NAME`, `SYSTEM_WMS_NAME`, `WEBS%`) in one verified pass. See `[[wms2-greenfield-db-provisioning]]` §5. |
| Enable a cron job in a new tenant | §3 + §4 (set both the master + per-job `_ACTIVATED` flag + any `_TIMER_*` overrides) |
| Configure OMS callbacks | §5 — every `WEBSERVICE_*` must be overridden away from the placeholder (`CHANGE-ME-FOR-NEW-CLIENT/` in the `V2.2.00` base-dump seed; `configure-client-sysprops.sh --oms-api-base-url` sets them all at once) |
| Bring up a new Keycloak realm | §9 — all 8 keys are mandatory; no defaults exist |
| Tune replenish behavior | §6 |
| Change label print behavior | §7; identity labels (tote / location / flowbin / overstock / unit-load) §7.1 |
| Know what a Flyway-seeded flag actually switches | §11.2 |
| Check what a tenant currently holds for the seeded keys | §11.3 (point-in-time, 2026-08-13) |
| Change a key's shipped default | §11.5 — **read (a) and (b) first**; editing an applied migration silently freezes a tenant's whole chain, and a new migration's default is a no-op on existing rows |
| Pick the next `V2.2.x` version number | §11.1 — sweep **all remote branches**; `V2.2.11` is taken by an unmerged one |
| Audit for unknown sysprop rows | Query `SELECT key FROM los_sysprop EXCEPT` the union of keys in this doc — anything left is either magic-string debt (§12) or stale |
| Update a sysprop but change isn't visible | Remember the `@Cacheable`: restart the service or wait for cache TTL (§2) |

---

## 14. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `WmsConstants.java:879-1069` constants, `SyspropService.java` method signatures + caching annotation, fallback chain, magic-string consumers, "missing default" set | All keys + defaults + consumer shape confirmed | Code read (grep-based) |
| 2026-07-10 | Added `ENFORCE_PARTITIONALLOWED` (SBDEV-2512 overstock-release guard kill-switch, default ON) to §10 Picking — Order-release behavioral guards; total ~75→~76. | New key documented | SBDEV-2512 v2 port |
| 2026-07-19 | Documented `db/configure-client-sysprops.sh` (SBDEV-2607) as the greenfield per-client sysprop seeding tool; noted the `V2.2.00` base-dump placeholder is `CHANGE-ME-FOR-NEW-CLIENT`. No new keys. | Onboarding tooling documented | SBDEV-2607 |
| 2026-07-24 | Added `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` (SBDEV-1762) as new §10 Transfer-orders subsection; added Flyway **V2.2.04** seed provenance (PR #93, default OFF) to it and the existing `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` (SBDEV-1666) §6 entry. Feature constants land via open PRs #91/#92. Total ~76→~77. | New key + seed provenance documented | V2.2.04 seed work |

| 2026-07-30 | **Full extraction + live census.** Counted every constant programmatically (123 `SYSTEM_PROPERTY_*_KEY` + nested `AREA_DEFAULT` = 124) and read `los_sysprop` on all 5 active DEV+UAT tenants. Corrected the bogus "~77" total in §1. Added 9 previously-undocumented keys: `API_TIMESTAMP_FORMAT`, `AREA_DEFAULT`, `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED`, the 3 `STALE_CLUB_BATCH_CLEANUP_*` (new §4.6b), `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` + `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` (§4.7), `STOCK_SUMMARY_EXPORT_MAX_ROWS` + `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED` (§4.4). | Catalog coverage 115/124 → **124/124**. Census found 146 live keys, 32 without constants (20 UI-managed, 4 orphans, 7 DEV junk, 1 seeded-ahead-of-code) | Nam Park — [`260730-wms2-sysprop-current-value-census`](../reports/260730-wms2-sysprop-current-value-census.md) |

| 2026-08-10 | Added `DEFAULT_PUTAWAY_LOCATION` (SBDEV-2732 tier 3 of the putaway destination hierarchy) as a new §10 Receiving subsection, with its read path (`findBySyskeyAndClientIdAndWorkstation`, NOT `getSysvalue` — landmines A3/A4), its blank-means-unconfigured semantics, the three `SystemPropertyController` rejections + the SDR handler guard, and D12's delete-and-recreate behaviour. Seeded blank by Flyway `V2.2.13`. Constant count 124 → 125. | New key documented ahead of merge; **not yet applied to any database** — wms2-api PR #139 open, not merged | Nam Park — SBDEV-2732 Phase 1-API |

| 2026-08-13 | **Post-`V2.2.00` Flyway seed audit + live re-read.** Extracted all 132 `SYSTEM_PROPERTY_*_KEY` constants from **`origin/develop`** (not a working tree) and diffed against this catalog: **8 undocumented keys** found and added — 5 × `PRINTING_ZPL_*` identity templates (new §7.1), `PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH`, `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` (§6), `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` (§10). New **§11** documents every post-base-schema sysprop seed, what each flag switches, per-tenant live state across 5 DEV+UAT DBs, and default-change semantics. **Corrected §2's auto-creation claim** — `getSysvalue` is a pure read, contradicting both this doc and 5 migration comments. Found: `V2.2.11` is an unmerged-branch hole; `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` has 0 consumers; dev `wh01_hydra_v2` has no `flyway_schema_history` and 0/12 seeded keys; the two wineco environments are inverse configurations. Constant count 125 → **133**. | Catalog coverage **133/133**; 4 UAT + 1 DEV tenant all at Flyway head `2.2.16`, 0 failed | Nam Park — live MCP reads + `origin/develop` grep |

| 2026-08-14 | **Label-printing rollout prerequisites** (new §7.1a). Traced `resolveTotePattern`'s three-step order and confirmed `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` is the **last** resort, not the first — both wineco DBs' `DEFAULT-%1$06d` is inert because step 2 derives `T-%1$04d` from the scan pattern. Read `PRINT_CASE_LABEL`, `STRING_PATTERN_PICKING_TOTE`, the printer table and `los_sequencenumber` on all 5 tenants. **Found: `wh01_shipitez_v2` has no `OUTBOUND_TOTE` printer** (hard blocker); all 5 capped at **10,000** tote IDs by 4-digit scan patterns; no tenant has a `PICKING_TOTE_DEFAULT` sequence row, so the first generated tote is `X-0000` (`SequenceTransactionService` creates at 0 and returns 0). | 4 of 5 tenants ready; 1 blocked on a missing printer row | Nam Park — live MCP reads + `origin/develop` |

**Re-verify every 90 days.** Next due: **2026-11-11** — sysprop surface grows slowly; major additions (typically 2-3 keys per quarter) should be spot-checked against this catalog.
