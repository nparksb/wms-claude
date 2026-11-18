---
title: "WMS v2 — System Property (Sysprop) Catalog"
type: data-dictionary
status: active
version: v2
scope: sysprops
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: "Full-surface re-verification 2026-11-11 against wms2-api origin/develop @ df30fa62 (detached worktree): 152 `*_KEY` constants in WmsConstants + AREA_DEFAULT + SdrGuardModeProvider.SYSKEY re-enumerated, every read site re-anchored, defaults re-checked against the call sites that actually apply them, Flyway seeds V2.2.04-V2.2.50 re-diffed, application.properties re-read; see §14. Live DB state (§7.1a, §11.3) was NOT re-read in this pass. Earlier passes follow. SBDEV-3132 doc pass 2026-10-28 — added ONLY the three MOBILE_FORCE_SCAN/OVERRIDE_APPROVER_CAP* rows (§10 Misc, §11.1) against unmerged branch feature/SBDEV-3132-p1-api @ 0c27cbd4; last_verified NOT bumped. SBDEV-3672 docs lane 2026-10-16: added and verified ONLY the WMS_BOL_SHIPPED_OMS_CHUNK_SIZE rows (§10 Shipping, §11.1, §11.2) and the app.outbox.dispatcher.bol-shipped-max-attempts row (§4.7), against wms2-api 1866ab66; last_verified unchanged. SBDEV-3658 2026-10-06: re-verified ONLY the REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED row's query list (§6), against branch bugfix/SBDEV-3658-delete-unused-itemdata-list-query; the unpaged getIdsForItemDataWithoutFixedAssignment was deleted, so six of the seven formerly-gated queries remain; last_verified unchanged. SBDEV-3654 2026-10-05: re-verified ONLY the REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED rows (§6 + §11.2), against branch bugfix/SBDEV-3654-replenish-lane-exclusion-unconditional; last_verified unchanged. SBDEV-3636 2026-10-02: added and verified ONLY the REPLENISH_MANUAL_CUT_COOLDOWN_MINUTES row, against branch bugfix/SBDEV-3636-replen-cooldown-after-manual-cut (PR #449); last_verified below is unchanged because no other row was re-checked. §11 re-verified 2026-09-10: 6 new post-V2.2.00 keys (V2.2.17/22/23/24) added, live los_sysprop re-read across all 6 v2 tenant DBs including Hydra PRD for the first time. Prior full-surface pass: 133-key constant extraction against origin/develop, 2026-08-13. Earlier baseline: reports/260730-wms2-sysprop-current-value-census.md"
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
**Owner:** Nam Park · **Last verified:** 2026-11-11

---

## 1. Overview

Configuration in `wms2-api` flows through a per-tenant `sysprop` table in the **tenant DB**, accessed via `SyspropService`. Each key has a canonical constant in `WmsConstants.java`; 104 of the 152 `*_KEY` constants there have a companion default constant (`*_DEFAULT_VALUE`, or for 9 keys `*_VALUE`). ⚠ **Corrected 2026-11-11 — a default constant is NOT a runtime fallback unless a read site uses it.** The only code that ever wrote those constants into a row (`UtilRestController`'s `createSystemProperty(...)` seeding block) is commented out, and 81 of the 104 default constants have **no live reference anywhere in `src/main/java`** (72 of those 81 keys have a live reader that simply ignores the default: a missing row reads as `null`, i.e. `false` for every `Boolean.parseBoolean(getSysvalue(..))` gate). The `Default` column in §3-§10 therefore means *the companion constant / the value the base-dump or a Flyway seed puts in the row*, not what a tenant with the row deleted gets; §1a lists the effective absent-row behaviour of the keys where the two differ. There is **no application.properties fallback** — a key with no row reaches the consumer as `null`, and the consumer either applies its own inline default, treats it as `false`, or fails at read time (`Integer.parseInt(null)`).

Three things to keep in mind:

1. **Sysprop reads hit the tenant DB**, not landlord. They go through `TenantContext` and the routing datasource — a scheduled job must have set tenant context before reading.
2. **`@Cacheable(value = "sysprops", key = TenantKeyBuilder.cacheKey(currentTenant) + ':' + key)`** (`<tenantName>:<facilityCode>:<key>`; `SyspropService.java:106,333`) is applied to `getSysvalue` only (the cached `getByKey(String)` was deleted by SBDEV-4134 ✓ merged(SBDEV-4134: #676 9f041590 + oms #993 51a9bab2, 2026-11-13)); `getStringDefault`, `getIntValue` and the 3-arg `getByKey` are not themselves cached (`getIntValue` goes through the cached `getSysvalue`). Changes to `sysprop` table rows are **not** immediately visible to running processes — the cache TTL must expire or the service restart.
3. **Fallback chain** at the `SyspropService` read sites is almost always `getSysvalue` (218 `.getSysvalue(` occurrences in `src/main/java`, 10 `getIntValue`, exactly **1** live `getStringDefault` caller — `AdviceService.java:236`): tenant-DB row → `null`, then whatever the caller does with `null`. Only `getStringDefault` writes a default into a row (§2). There is no env-var or `application.properties` path.

**Total keys:** **154** key constants as of 2026-11-11 (`origin/develop` @ `df30fa62`): 147 `SYSTEM_PROPERTY_*_KEY` + 5 un-prefixed `*_KEY` in `WmsConstants` (`REPLENISHMENT_PAGE_SIZE_KEY`, `REPLENISHMENT_PAGE_LIMIT_KEY`, `FIX_LOCATION_PAGE_SIZE_KEY`, `FIX_LOCATION_PAGE_LIMIT_KEY`, `OMS_EXPORT_CONSUMER_TIMEOUT_S_KEY`; `WmsConstants.java:1703-1707`) + the nested
`LocationAreaService.PROPERTY_KEY_AREA_DEFAULT` + `SdrGuardModeProvider.SYSKEY` (`WMS2_SDR_READ_GUARD_MODE`, declared outside `WmsConstants`). Several more reach `SyspropService` as method parameters
(see §12). Counted programmatically against **`origin/develop`**, not a working tree. 21 of the 152 `WmsConstants` key constants have **no live reader** (§12).

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

### 1a. What the `Default` column means — effective behaviour when the row is absent

*Added 2026-11-11. Method: for every `*_KEY` constant, grep its companion default constant for live references (`grep -rn <NAME> src/main/java`, excluding `WmsConstants.java` and comment lines); then read each read site.* Result: 104 keys have a companion constant; **81 of those constants are never referenced by live code**. SBDEV-4126 deletes 70 of them (65 `*_DEFAULT_VALUE` plus 5 `*_VALUE`-named) ✓ merged(SBDEV-4126: #669 722f3ea4, 2026-11-12); the 7 CUPS/CYCLE_COUNT ones go with SBDEV-4125, and 4 stay because seed-consistency tests read them; 21 key constants have no live reader at all (§12). Where a fresh DB has the row, it is the V2.2.00 base-dump or a later Flyway seed (§11) that supplies the value, not the constant. Effective absent-row behaviour for the keys where it differs from the `Default` column:

| Key(s) | `Default` column | Row absent -> what the code does | Read site |
|---|---|---|---|
| `NEW_CRON_JOB_ACTIVATED` | `true` | **OFF** — `!Boolean.parseBoolean(null)`; all 7 gated cron jobs skip the tenant | `OrderReleaseJob.java:245`, `ReplenishOrderJob.java:312`, `CleanUpOldMessagesJob.java:255` |
| every `*_TIMER_ACTIVATED` / `*_ACTIVATED` cleanup flags such as `CLEAN_UP_OLD_MESSAGES_ACTIVATED` / `PICK_TIME_OUT_SYSTEM_ACTIVATED` | `true` / `false` | **OFF** (`parseBoolean(null)`) — including the ones whose `Default` column says `true` | `OrderReleaseJob.java:246`, `ReplenishOrderJob.java:313`, `StockSummaryExportJob.java:310` |
| every `*_TIMER_HOUR` / `*_TIMER_MINUTE` | `*`, `55`, `3`, ... | **job is not scheduled for that tenant** — a null or blank hour or minute makes `deriveSpecForCurrentTenant()` return `null` | `OrderReleaseJob.java:163-166` (same shape: `ReplenishOrderJob.java:224-226`, `CleanUpOldMessagesJob.java:156-158`, `StockSummaryExportJob.java:187-189`, `StaleClubBatchCleanupJob.java:126-128`, `EmptyPalletCleanupJob.java:114-116`) |
| `MERGE_PICKING_ORDERS` | `true` | **OFF** — merge pass skipped | `ReplenishOrderJob.java:561`, `ReleaseOrderJobService.java:843` |
| `PRINT_CASE_LABEL` | `true` | **OFF** — printing disabled (`isPrintingEnabled()` is `false`; `LabelPrintingService.requirePrintingEnabled` throws) | `PrintService.java:99-101`, `LabelPrintingService.java:1083` |
| `INBOUND_UPDATE_STOCK_IMMEDIATELY` | `true` | **OFF** | `ReceivingService.java:650`, `GoodsReceiptPositionService.java:119,238` |
| `REQUIRE_RECEIVING_TO_CONTAINER` | `TRUE` | **`false`** | `ReceivingController.java:489` |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT`, `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT`, `SHIPPING_METHOD_ACTIVATED`, `SHOW_MANIFEST_LOCATION`, `PICK_SCREEN_SIMPLE`, `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` | `true` / `false` | **`false`** (`parseBoolean(null)`) — so the two `true` defaults read as `false` | `MobileCycleCountService.java:337,333`, `MobilePalletizingService.java:171,176`, `MobilePickingService.java:1729`, `BillofladingService.java:945` |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY`, `PICK_TIME_OUT_MOBILE`, `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE`, `MAXIMUM_RECEIVING_DURING_INBOUND` | `0`, `30`, `40`, `100` | **`NumberFormatException`** (`Integer.parseInt/valueOf(null)`); only `ReturnAdviceAutoReceiveService.java:281-289` handles the null | `MobileCycleCountService.java:341`, `PickingController.java:233`, `MobilePickingService.java:1725`, `ReleaseExpiredPickingOrdersFromUserJob.java:386`, `ReceivingService.java:411` |
| `PICKING_BOX_PER_CART` | `6` | `6` in `ReplenishOrderJob.java:571` (`parseSyspropLong(key, DEFAULT)`), and `ReleaseOrderJobService.java:849-851` also falls back to `SYSTEM_PROPERTY_PICKING_BOX_PER_CART_DEFAULT_VALUE` — absent row = `6` on both paths (corrected after review 2026-11-11) | as listed |
| `MOBILE_UI_URL`, `WEBSERVICE_*` URLs, `CUPS_SERVER_ADDRESS_IP` / `_PORT`, `MULTIWAREHOUSE_IDENTIFIER`, `STRING_PATTERN_PICKING_TOTE`, `STRING_PATTERN_OUTBOUND_PALLET`, `STRING_PATTERN_PICKING_PARCEL` | placeholder / pattern | `null` (the placeholders are base-dump seed content, `CHANGE-ME-FOR-NEW-CLIENT/...`, not a code fallback); an unset `STRING_PATTERN_PICKING_PARCEL` means "no scan is recognised as a parcel" | `SystemController.java:60`, `MobilePickingService.java:1715-1718`, `OutboundPalletLabelGuard.java:63` |

Keys whose default **is** applied by code: `REPLENISH_MANUAL_CUT_COOLDOWN_MINUTES` (`ManualCutCooldown.java:49`), `REPLENISHMENT_CLAIM_TIMEOUT_SECONDS` (`ReplenishClaimTimeout.java:21`), `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` (`BolShippedNotificationChunker.java:58`), `WMS_CLUBLINE_MAX_BATCH_SIZE` / `_OMS_CHUNK_SIZE` / `_ASYNC` (`CustomerorderBatchService.java:624,663`, `ClubRunJobService.java:89`), `CLEAN_UP_OLD_MESSAGES_BATCH_SIZE` / `_BATCH_SLEEP_MS` (`CleanUpOldMessageJobService.java:161,190`), `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED` / `_MAX_ROWS` (`WarehouseStockReportService.java:73,84`), `DEFAULT_BOX_TYPE` (`AdviceService.java:236`, `AdviceRestController.java:891`), `STRING_PATTERN_INBOUND_PALLET` (`ReceivingService.java:951-953`), `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` (`MobileReplenishService.java:772-778`), `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_*_BOUND` (`FixLocationAssignmentService.java:690-691`), the two `MOBILE_OVERRIDE_APPROVER_CAP` / `_WINDOW_MIN` limits (`ManualEntryOverrideLimits.java:51,58`), `CLEAN_UP_OLD_MESSAGES_PERIOD` (`CleanUpOldMessageJobService.java:138`), `PICKING_BOX_PER_CART` (`ReplenishOrderJob.java:571`, `ReleaseOrderJobService.java:849-851`), `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` / `_CANCEL_THRESHOLD_FRACTION` (`ReplenishmentOrderMaintenanceService.java:427,1047`), the four page-size/limit keys and `OMS_EXPORT_CONSUMER_TIMEOUT_S` (inline literals `1000`/`100`/`2000`/`100`/`120`, no constant).

---

## 2. Access Layer

`net/aim_ai/wms/service/SyspropService.java` exposes:

| Method | Returns | Caching | Behavior when row missing |
|---|---|---|---|
| `getSysvalue(String key)` (`SyspropService.java:333`) | `String` | cached, `unless #result == null` | Returns `null`. **Does not write.** The reader used at ~all call sites |
| `getIntValue(String key, int default)` (`:367`) | `int` | via `getSysvalue` | Returns `default` on null, blank **or unparseable** (value is trimmed) |
| `getStringDefault(String key, String default)` (`:158`, 4-arg overload `:175`) / `getString(key)` (`:144`, passes `null`) | `String` | **not cached** (the 4-arg overload does 1-4 `findBySyskeyAndClientIdAndWorkstation` lookups) | **INSERTs a row holding `default`** via `createSystemProperty(...)` (`:249`), evicts the key (`:250`), returns the default. 1 live caller: `AdviceService.java:236` |
| ~~`getByKey(String key)`~~: **deleted by SBDEV-4134** ✓ merged(SBDEV-4134: #676 9f041590 + oms #993 51a9bab2, 2026-11-13). The uncached 3-arg `getByKey(client, workstation, key)` remains | `Sysprop` entity | was cached with no `unless` | Had zero live callers in `src/main` |
| `createSystemProperty(client, workstation, key, value, group, description, hidden, reinitialize)` (`:66`) | `void` | `@CacheEvict` | Upsert; the write half of `getStringDefault`. Only other caller: `UtilRestController.java:998`, inside a private helper that nothing calls |
| `parseLongOrDefault(value, default)` (`:348`), `parseLongOrFallback(key, value, default)` (`:358`) | `long` (static) | — | Shared parse for the `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_*_BOUND` triple (SBDEV-3128/3998); the `Fallback` form WARNs and uses the default on a bad value, `OrDefault` throws `NumberFormatException` |
| `getOmsInstanceName()` (`:407`), `getWmsInstanceName()` (`:411`) | `String` | via `getSysvalue` | Read `SYSTEM_OMS_NAME` / `SYSTEM_WMS_NAME` per call (SBDEV-3190: no memoising field, the rows are tenant-scoped) |
| `setSysvalue(String key, String value)` (`:379`) | `void` | `@CacheEvict` | **Creates** the row on the system client, workstation `DEFAULT` (**1** live caller: `ReplenishmentOrderMaintenanceService.java:448`, the `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` write) |

The `sysprop` table is defined on the tenant side (see [wms2-landlord-vs-tenant-entity-map.md](./wms2-landlord-vs-tenant-entity-map.md) §Configuration & System — `Sysprop` → table `los_sysprop`).

> ⚠ **CORRECTED 2026-08-13 — `getSysvalue` does NOT auto-create a row.** This doc previously said the
> first read of an unknown key writes a row with a null value, and several Flyway migrations
> (V2.2.04, V2.2.05, V2.2.06, V2.2.09, V2.2.10) justify their `WHERE NOT EXISTS` guard the same way.
> `SyspropService.java:333-336` is a pure read — `@Cacheable` wrapping a single
> `syspropRepository.findSysvalueBySyskey(key)` with no `save()`. The `save()` calls in that class are
> all on explicit write paths (`setSysvalue`, `createSystemProperty`) — **except** that `getStringDefault` (never `getSysvalue`) calls `createSystemProperty` on a miss, so it *does* INSERT a row holding its default (`SyspropService.java:249`; its only live caller is `AdviceService.java:236`; `DestinationEligibilityService.java:208-211` documents why it must not be used inside a read-only transaction). The migration guards are still
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
key `tenantName:facilityCode:syskey` (`TenantKeyBuilder.cacheKey`, literal `no-tenant` when no tenant is set; `TenantKeyBuilder.java:52-57`), **per JVM replica**. So a direct SQL `UPDATE` — including one run by
a Flyway migration — is invisible for up to 2 minutes, independently per replica, and replicas actively
disagree during that window. `setSysvalue` carries `@CacheEvict` but only evicts on the replica that
served the request; cross-replica invalidation exists only under the `redis` cache profile (`CacheConfig.java:44-65`; `sysprops` TTL is also 2 minutes there).
`unless = "#result == null"` means a missing row is never negatively cached and is re-queried on
every call.

---

## 3. Global Activation Gates

The **seven** cron jobs registered by `SchedulingConfiguration.CONFIGURED_JOB_NAMES` (`:68-71`: `cleanUpOldMessages`, `orderRelease`, `replenish`, `stockSummaryExport`, `releaseExpiredPickingOrdersFromUser`, `staleClubBatchCleanup`, `emptyPalletCleanup`; see [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md)) all check `NEW_CRON_JOB_ACTIVATED` first (each job's `runFor`/manual-trigger path, e.g. `OrderReleaseJob.java:245,348`, `ReleaseExpiredPickingOrdersFromUserJob.java:228,332`, `EmptyPalletCleanupJob.java:255`). *(Corrected 2026-11-11: was "five"; `StaleClubBatchCleanupJob` and `EmptyPalletCleanupJob` also gate on it.)*

| Constant | Key | Default | Purpose |
|---|---|---|---|
| `SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` | `NEW_CRON_JOB_ACTIVATED` | `true` (constant `WmsConstants.java:1374` and base-dump seed `V2.2.00:2679`; ⚠ **absent row = OFF**, see §1a) | Master kill-switch across all seven cron jobs |
| `SYSTEM_PROPERTY_OLD_CRON_JOB_ACTIVATED_KEY` | `OLD_CRON_JOB_ACTIVATED` | constant `false`; base-dump seed `VERSION-1.0-ONLY` (`V2.2.00:2685`) | **Dead key — no live reader** in `src/main/java` (`grep -rn OLD_CRON_JOB_ACTIVATED` hits only `WmsConstants` and a commented `UtilRestController` line). Setting it changes nothing |
| `SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG_KEY` | `CRON_JOB_SHOW_LOG` | `false` | Verbose per-job debug logging (`SchedulingConfiguration.java:826,944,1055,...`, `BasicService.java:224`) |

Class-level gate `app.cron` (`application.properties:196`, default `false`) is separate — `SchedulingConfiguration` is `@ConditionalOnProperty(name = "app.cron", havingValue = "true", matchIfMissing = false)` (`SchedulingConfiguration.java:30`), so it controls whether the per-tenant cron jobs are registered at all. The `@Scheduled` jobs (outbox dispatcher lanes, `RestIdempotencyCleanupJob`, `PendingReversalReconciliationJob`, `ClubRunJobPollerJob`) run regardless.

---

## 4. Per-Job Timer Keys

Format: cron fields are assembled as `{sec} {MINUTE} {HOUR} * * *` with `sec` = `0`, fired in the tenant's warehouse time zone (`OrderReleaseJob.java:163-169`). `*` means "every". ⚠ A null or blank hour **or** minute row means the job is **not scheduled** for that tenant — the `Default` values below are base-dump/seed content, not code fallbacks (§1a). Exception: `releaseExpiredPickingOrdersFromUser` (§4.5) has no timer keys and a fixed cron `"40 * * * * *"` (`SchedulingConfiguration.java:1194`).

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
| `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` | `40` | Seconds a claimed RAPID_PICKING picking order (`lockedtooperator = true`, `pickinginprogress = false`, state below `PICKED`) may sit unmodified before `ReleaseExpiredPickingOrdersFromUserJob` clears the operator and lock (`PickingorderRepository:186-194`). Absent row throws `NumberFormatException` |
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
| `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` | `false` | Per-job activation — **off by default**. ✓ merged(SBDEV-3312: #592 58820570, 2026-10-31): the job then finalizes stuck batches of **every** type, not only CLUB; the key and its "club" description keep their name. WineCo PRD = `true` (2026-10-31) |
| `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` | `3` | Cron hour field |
| `STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE` | `0` | Cron minute field (→ 03:00 daily when activated) |

### 4.6c EmptyPalletCleanupJob (SBDEV-1581)

`schedulejob/EmptyPalletCleanupJob.java`; nightly job that returns empty Pallet/Cart unit loads left in storage areas to EmptyPallets. Seeded by **V2.2.41** (group `Backend`, `workstation='DEFAULT'`, `client_id=0`, `WHERE NOT EXISTS`). Also gated by `NEW_CRON_JOB_ACTIVATED` (§3). *Added 2026-11-11 — it was missing from this catalog.*

| Key | Default | Role |
|---|---|---|
| `EMPTY_PALLET_CLEANUP_ACTIVATED` | `false` | Per-job activation — **off by default** (`EmptyPalletCleanupJob.java:255-256`; constant `WmsConstants.java:1616-1617`) |
| `EMPTY_PALLET_CLEANUP_TIMER_HOUR` | `3` | Cron hour field (`EmptyPalletCleanupJob.java:114`; constant `:1618-1619`) |
| `EMPTY_PALLET_CLEANUP_TIMER_MINUTE` | `15` | Cron minute field (→ 03:15 daily when activated; `:115`; constant `:1620-1621`). Per the seed description a change applies within about 7 minutes (5-minute reconcile) |

The three seed literals are duplicated in `V2.2.41__seed_empty_pallet_cleanup_sysprops.sql` and pinned to the constants (comment at `WmsConstants.java:1614`).

### 4.7 OutboxDispatcherJob (SBDEV-2221) — application.properties only

This job does **not** use DB sysprop rows. All tuning knobs are controlled by `application.properties` entries.

| Property | Default | Role |
|---|---|---|
| `app.cron.outbox-dispatcher` | `*/3 * * * * *` (`application.properties:219`; the `@Scheduled` fallback in `OutboxDispatcherJob.java:62` is still `*/15`) | Cron expression for the DEFAULT lane — every 3 s (was 15 s; must not fire on second 50, see the comment at `:207-218`); override to slow down in dev |
| `app.cron.outbox-dispatcher-club` | `*/3 * * * * *` (`:222`) | CLUB lane consumer, own advisory lock, drains concurrently with the DEFAULT lane (`OutboxDispatcherJob.java:83`) |
| `app.outbox.dispatcher.batch-size` | `25` (`application.properties:263`; was `10`) | Max rows claimed per tenant per tick **per lane** (`FOR UPDATE SKIP LOCKED`); bounded by `OutboxDispatchService.STALE_INFLIGHT_TIMEOUT` = 15 min (`:72`) |
| `app.outbox.dispatcher.max-attempts` | `5` | Attempts before a row is marked `FAILED_TERMINAL`; conservative until OMS confirms idempotency-key support |
| `app.outbox.dispatcher.bol-shipped-max-attempts` | `29` | Replaces `max-attempts` for `ORDER_BATCH_SHIPPED` rows only (single BOL row or chunk): ≈24 h of retries at the 1 h backoff cap (`OutboxDispatchService.java:107,338-341`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |
| `app.outbox.dispatcher.retention-days` | `7` | Days to retain `SENT` rows. ⚠ **No longer cleaned up at the end of each tick** — the sweep moved to the nightly `RestIdempotencyCleanupJob` (`RestIdempotencyCleanupJob.java:57-105`, `app.cron.cleanup-rest-idempotency`) because `deleteSentOlderThan` has no index; a value that is not a positive number of days is floored at 1 day with a WARN |

Two outbox keys **are** DB sysprops, despite the job's tuning living in `application.properties`. Neither has a `*_DEFAULT_VALUE` constant, so a missing row reaches `Boolean.parseBoolean(null)` and reads as `false`. (Corrected 2026-11-11: they are seeded by **different** migrations — `V2.2.06` for the metric flag, `V2.2.05` for the reject flag. The metric flag has a key constant, `WmsConstants.java:1464`; the reject flag has none.)

| Key | Default | Role |
|---|---|---|
| `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` | seeded `false` by Flyway `V2.2.06` | Gates `OutboxDispatchService.sampleStuckAggregates()` (`OutboxDispatchService.java:382-383`) — the held-aggregate gauge (see `[[wms2-unstick-held-outbox-aggregate]]`). Read-only query, but it runs on every dispatcher tick, so enable per tenant. |
| `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` | seeded `false` by Flyway `V2.2.05` | **SBDEV-2736 Phase-2 gate. Inert — nothing reads it yet.** No Java constant exists: it was deliberately deferred to Phase 2, since an unread constant cannot be type-checked against the migration literal. |

> ⚠️ **Do not set `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` to `true`.** Phase 2 enforcement is not built, and
> enforcing against today's rejection rate would wedge aggregates behind `FAILED_TERMINAL` siblings that are
> never auto-deleted. As of 2026-07-30 the row exists only on DEV (`V2.2.05` has not reached `release`).

### 4.8 Other Spring-property-driven jobs (no sysprop rows)

*Added 2026-11-11 — these `application.properties` knobs post-date the last full pass; none is a `los_sysprop` key. Listed here so a reader looking for "where is the schedule of X" does not conclude it is missing.*

| Property | Value (`application.properties`) | Role |
|---|---|---|
| `app.cron.pending-reversal-reconcile` | `0 30 2 * * *` (`:203`) | `PendingReversalReconciliationJob` (SBDEV-3321), nightly 02:30; deliberately not 02:00 (`:198-202`) |
| `app.reconcile.pending-reversal.threshold-hours` | `24` (`:206`) | Age at which a pending reversal is reported — a Spring property, not a sysprop, by design (`:204-205`) |
| `app.cron.club-run-job` | `*/4 * * * * *` (`:226`) | `ClubRunJobPollerJob` (SBDEV-4007; `ClubRunJobPollerJob.java:60`), claims `club_run_job` rows on every replica; `*/4` not `*/5` because `*/5` fires on second 50 (reserved for `SchedulingConfiguration.RECONCILE_CRON`, `:121`) |
| `app.clubline.job.workers` / `lease-seconds` / `max-attempts` | `2` / `300` / `2` (`:232-234`) | Async club-run worker threads per replica, job lease, poison-guard claim limit |
| `app.clubline.sync-wait-seconds` | `45` (`:235`) | Bounded wait of the legacy `GET /runClubLine` |
| `spring.task.scheduling.pool.size` | `15` (`:252`) | Scheduler pool for both replica shapes; must be >= the number of standing triggers (`:239-251`) |

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
| `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY` | `.../services/call/updateBatchPriority` (SBDEV-2573; V2.2.22 seeds it derived from the `..._CANCELLED` host; read at `PriorityChangeNotificationService.java:121`) |
| `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED` | `false` — **gate, not a URL**; no default constant, absent row = OFF (`PriorityChangeNotificationService.java:108-110`) |
| `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE` | `.../services/call/updatePickingDate` (SBDEV-3273, V2.2.24; read at `PickingDateChangeNotificationService.java:88`) |
| `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED` | `false` — **gate, not a URL**; absent row = OFF (`PickingDateChangeNotificationService.java:126-127`) |
| `WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED` | `false` — **gate, not a URL** (constant `WmsConstants.java:1294-1295`; *added 2026-11-11, was missing*). Gates the OMS `readyToPick` / `picking` (RELEASED, STARTED) notifications for a transfer run's customer order; read once per run at `BillofladingService.java:1091-1092`. Ships dark; per the constant's javadoc (`WmsConstants.java:1262-1285`) a terminal OMS rejection could wedge later outbox rows for that order and OMS may not resolve a transfer CO's `unique_id` at all, so enable per tenant only after an observed OMS round trip. Not seeded by any migration |
| ~~`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED`~~ | ~~`false` (activation flag)~~ — **gates nothing**; deleted by SBDEV-3373 `V2.2.37` (PR #466, merged to develop `a0b2c07f`; applied on dev 2026-10-07, not yet on UAT/PRD) |
| `WEBSERVICE_TEST_CRM_CONNECTIVITY` | `.../services/call/testPsd` |
| `WEBSERVICE_FACILITY_LIST_LOOKUP` | `.../services/call/facilities` |
| ~~`WEBSERVICE_BEHAVIOUR`~~ | ~~`keep` (possible values: `send`, `discard`, `keep`)~~ — **gates nothing**; deleted by SBDEV-3373 `V2.2.37` (PR #466, merged to develop `a0b2c07f`; applied on dev 2026-10-07, not yet on UAT/PRD) |

**`WEBSERVICE_BEHAVIOUR` is NOT an emergency switch** (corrected 2026-10-06, SBDEV-3373). This paragraph used to tell operators to set it to `discard` during OMS outages. Nothing in v2 reads the key, so `discard` and `keep` suppress nothing. Both it and `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` are deleted by SBDEV-3373 `V2.2.37` (PR #466, merged to develop `a0b2c07f`; applied on dev 2026-10-07, not yet on UAT/PRD). **The sysprop table holds no global kill-switch for OMS callbacks.** Some callbacks have their own working `*_ACTIVATED` gates, which ship OFF (priority, picking-date, transfer-run picking status). Pausing the outbox dispatcher crons (`app.cron.outbox-dispatcher` / `-club` = `-`) pauses only the outbox-routed callbacks. Several callbacks bypass the outbox (`OmsNotificationService.sendAfterCommit` and direct `HttpRestService` posts) and keep firing. Writing a real outage procedure is a separate task; do not improvise one from this paragraph.

---

## 6. Replenishment Tuning

These drive `ReplenishOrderJob` and `ReplenishmentOrderMaintenanceService`.

| Key | Default | Purpose |
|---|---|---|
| `MERGE_PICKING_ORDERS` | `true` (constant is named `SYSTEM_PROPERTY_MERGE_PICKING_ORDERS_VALUE`, `WmsConstants.java:1669`; ⚠ **absent row = OFF**, §1a) | Enable tote-on-cart merge pass (`ReplenishOrderJob.java:561`, `ReleaseOrderJobService.java:843`) |
| `PICKING_BOX_PER_CART` | `6` | Cart capacity cap. Default applied at `ReplenishOrderJob.java:571` and `ReleaseOrderJobService.java:849-851` (absent row = 6) |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND` | `36` | Fixed-assignment **Min Amount** (`lowerbound`): an absolute stock quantity in the item's unit, not a fill % (`getRefillFixedLocations` compares `stockunit.amount < fla.lowerbound`). Seeds a NEW assignment; ✓ merged(SBDEV-3128: #601 4643acf5, 2026-11-02): a location's own default triple (`location.default_*bound`), when set, seeds first and this sysprop is the fallback (also the V2.2.45 backfill source). Editing it does not rewrite existing assignments |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND` | `60` | Fixed-assignment **Hysteresis** (`middlebound`), absolute quantity; the job path skips an FLA whose on-hand `>= middlebound`. Same seeding rule as above |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` | `84` | Fixed-assignment **Max Amount** (`upperbound`), absolute quantity: refill target and cancel-if-full threshold. Same seeding rule as above. ✓ merged(SBDEV-3128: #601 4643acf5, 2026-11-02): `ViewDtoService` no longer reads this key for the replenish-order list (D-1: the read was dead and NPE'd the screen when the row was absent); the Fixed Locations view still reads all three, via `SyspropService.parseLongOrDefault`, to flag `defaultSource` / `boundsOutOfDate` |
| `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` *(sic)* | `false` | Auto-delete empty fixed assignments (typo preserved in code: `EMTPY`) |
| `REPLENISHMENT_ALLOW_ANY_UNIT_LOAD` | `true` | ~~Accept any unit load during replenish~~ **No reader in code since SBDEV-3638 (merged 2026-10-02, `f839921e`)** — its only reader, `MobileReplenishService.isAllowPickAnyUnitLoad`, was removed with the single-UL `checkSource` endpoint. The row may still exist in tenant DBs; it is inert. |
| `REPLENISHMENT_SHOW_UNIT_LOAD` | `true` | ~~UI flag — show unit load on replenish screen~~ **No reader in code since SBDEV-3638 (merged 2026-10-02, `f839921e`)** — its only reader, `MobileReplenishService.isShowSourceUnitLoad`, had no caller and was deleted; neither wms2 UI reads the key (`git grep` origin/develop, 0 hits). The row may still exist in tenant DBs (seeded by `V2.2.00__base_v2_schema.sql`). |
| `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` | `0` | Min seconds between recalc passes (`0` = no throttle) |
| `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` | `0` | Epoch-ms timestamp of the last **started** `recalculateOpenOrders` pass — `setLastRun(Instant.now())` is the sweep's first statement, so it is written before any order is touched, and by every caller of `recalculateOpenOrders`: the cron (cadence-gated) and any forced caller. ~~**and** the forced `recalculateOpenOrders(true)` in `MobileReplenishService.fulfillMultipleUnitLoads`~~ ⚠ **Corrected 2026-10-07 (SBDEV-3678, merged to develop as `969882a8` on 2026-10-07)** — the multi-UL confirm no longer calls `recalculateOpenOrders` (it runs per-item `recalculateForItem`), so a confirm no longer writes this row. ⚠ Before that change it could not date the cron's last sweep: on DEV 2026-10-01 it read 2026-09-30 22:56:13, which was an operator's manual multi-UL replenish, while the cron sweep had been starved for months (SBDEV-3624). Replaces the JVM-local `lastRun` field (SBDEV-2234). Written by `ReplenishmentOrderMaintenanceService.setLastRun` via `SyspropService.setSysvalue`; evicts the `sysprops` Caffeine cache on write. Absent row treated as `Instant.EPOCH` (cadence always elapsed). ⚠ *unverified 2026-11-11:* the call-graph narrative in this row (which queries / callers are affected) was not re-traced in the 2026-11-11 pass; only the key, its default, the constant and the read/write site were re-checked. |
| `REPLENISHMENT_CANCEL_THRESHOLD_FRACTION` | `0.0` | Auto-cancel threshold (fraction of outstanding demand) |
| `REPLENISHMENT_PAGE_SIZE` | `1000` | Page size for paginated drain-queue loops in `ReplenishOrderJob` (all 6 sub-ops). Introduced SBDEV-2228. |
| `REPLENISHMENT_PAGE_LIMIT` | `100` | Max drain-queue iterations per sub-op (all 6 sub-ops including 6a). All sub-ops use drain-queue; empty-page terminates normally. Since SBDEV-3624 a page that brings no not-yet-attempted id also terminates (WARN `"<sub-op> stalled …"`), so a stuck row is attempted once per run, not up to this many times. Introduced SBDEV-2228. |
| `FIX_LOCATION_PAGE_LIMIT` | `100` | Max pages for the fix-location prefetch loop in `OrderReleaseJob.releaseOrders`. Logs a warning when cap is hit (map may be incomplete). Introduced SBDEV-2228. |
| `FIX_LOCATION_PAGE_SIZE` | `2000` (inline literal, no default constant) | Page size for the fix-location prefetch loop in `OrderReleaseJob.releaseOrders`; `Math.max(1, getIntValue(key, 2000))` (`OrderReleaseJob.java:378`). *Added 2026-11-11 — was missing; read-site anchors for the four page keys: `ReplenishOrderJob.java:676,680`, `OrderReleaseJob.java:378-379`.* |
| `OMS_EXPORT_CONSUMER_TIMEOUT_S` | `120` | Seconds the `StockSummaryExportJob` OMS consumer thread waits to enqueue a chunk, receive the POISON_PILL, and for `join()`. Floor 30, fixed in code (`consumerTimeoutFloorS`; it was briefly the property `app.stock-summary-export.consumer-timeout-floor-s` under SBDEV-4110, removed by SBDEV-4129 ✓ merged(SBDEV-4129: #673 934da58e, 2026-11-12) so a misconfiguration cannot lower it below the POST time). Prevents the advisory lock being held indefinitely when OMS is slow. Introduced SBDEV-2228. Since SBDEV-4110 the POISON_PILL and join waits are a **per-chunk stall bound** (give up only when a single chunk has been in flight this long; an idle consumer never counts), not a total window; the producer's mid-stream enqueue is still a fixed window of this length: as a total, 120 s cut DEV's 59-chunk export after 52-57 POSTs on each of 8 nights 2026-11-05..12 (2-7 chunks lost) while reporting success. A healthy run can now take up to ~50 × POST time past the end of streaming, and the one-key lock makes later tenants wait for it. ✓ merged(SBDEV-4110: #667 736b6f4b, 2026-11-12) |
| `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` | `false` | Per-tenant opt-in (SBDEV-2854). Master switch for accepting a replenishment **destination** that is not a flowbin. **OFF:** the destination must be a flowbin — a single-SKU pick bin addressed through a `FixLocationAssignment` holding exactly one virtual `PICKLOCATION` unit load — so shared club locations (~110 real case/pallet ULs each) can never be a destination. **ON:** a destination is accepted when its functional **area** has `useforpicking = true`, **without** creating a fixed location assignment. Read at `MobileReplenishService.isNonFlowbinDestinationAllowed()` (`:772-778`; null/blank row falls back to the constant); has an explicit `..._DEFAULT_VALUE = "false"` constant, so a null/blank row is also OFF. ⚠ **Capability, not location type, is the axis** — on wineco UAT the 70 club locations share type `cases and pallets` with 472 overstock racks in "Storage and Replenish" (what replenishment sources *from*), 40 outbound lanes, and `PutAwayLane`; a type allow-list would have opened all of them, and `PutAwayLane` sets none of the five lane flags so `isNonStorageLane` cannot see it. Mirrors the source side, which already asks `useforreplenish`. **Never accepted regardless of the flag:** `staginglane`, `gate`, `transferlane`, `automationlane`, `crossdockinglane`. **Seed:** default OFF by Flyway **V2.2.10**. |
| `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` | `false` | **RETIRED — read by nothing since SBDEV-3654** (PR #457, merged to develop as `df8dff6d`, 2026-10-05; decisions by Nam 2026-10-05). Staging/transfer lanes (`location.staginglane`/`transferlane`) are **never** a replenishment source on **any** tenant: the `:excludeLanes` parameter was removed from all 7 formerly-gated queries (`getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage`, `getAvailableReplenishmentSources`, `findUnitloadsByItemDataIdForReplenish`, `getRefillFixedLocations(Ids)`, `getIdsForItemDataWithoutFixedAssignment(+Page)`) and the exclusion is now unconditional SQL. **Six of those seven survive:** SBDEV-3658 deleted the unpaged `getIdsForItemDataWithoutFixedAssignment`, which had no caller in `src/main` and duplicated `getIdsForItemDataWithoutFixedAssignmentPage`'s text verbatim. A grep for the exact call `getIdsForItemDataWithoutFixedAssignment(` now lands nowhere; the bare name still prefix-matches the surviving `…Page` method. `isSourceUsable` and both `isReplenishableDestination` helpers (SourceSync and Maintenance) use `LocationReplenishabilityUtil.isUsableSourceLocation` unconditionally. Pinned by `ReplenishLaneExclusionUnconditionalArchTest` (no `@Query` may reference `:excludeLanes`). Why: SBDEV-3641 made the handheld `/multi-unitloads` refuse a lane source unconditionally, so a tenant with this key OFF could generate an order whose own source the picker is refused at submit. Behaviour change is for tenants that had it **OFF**: lane stock no longer counts for shortage/refill either, so an FLA whose only stock is on a lane gets no order. Every v2 tenant measured 2026-10-05 already had it `true` (Hydra PRD + 4 UATs). On 2026-10-16 ShipItEZ PRD (nywh, c1wh) and WineCo PRD were measured too: all `true`, one DEFAULT/client-0 row each. **Deleted by SBDEV-3659** ✓ merged(SBDEV-3659: #523 ee3747f2, 2026-10-16) (Nam, 2026-10-16, option 3 — the SBDEV-3373 / V2.2.37 precedent). Flyway `V2.2.39__delete_retired_lane_exclusion_sysprop.sql` deletes every row of the key, matched by `syskey` alone, and the `WmsConstants` key is deleted too. V2.2.39 applied on dev 2026-10-16 16:59 UTC (row count 0, sibling intact). It has not run on UAT or PRD yet. Until it does, the row stays there and changing its value has no effect. Live 2026-10-16: present, `true`, `hidden=false` on dev, Hydra PRD and WineCo PRD. History: SBDEV-1666 opt-in, seeded OFF by Flyway **V2.2.04** (PR #93). ⚠ *unverified 2026-11-11:* the call-graph narrative in this row (which queries / callers are affected) was not re-traced in the 2026-11-11 pass; only the key, its default, the constant and the read/write site were re-checked. |
| `REPLENISH_MANUAL_CUT_COOLDOWN_MINUTES` | `60` | SBDEV-3636 (PR #449, merged to develop as `e3dfcc72`, on DEV 2026-10-02). Minutes for which **automatic** replenishment skips a stock unit an operator just cut with Adjust Reserved Amount (a `MANUAL_ADJUSTMENT` stockrecord with a negative `reservedamountchange`, excluding the SBDEV-2610 and SBDEV-3605 system rows). Applies to: the generator source query via `calculateAutomaticOrder` (the FLA refill crons, the no-FLA generation job `ReplenishOrderJobService.generateReplenishmentForItemDataWithoutFixedAssignment`, and the post-finish refill); `getRefillFixedLocations(Ids)` eligibility; and `getAvailableReplenishmentSources`, used by the recalc redirect **and by the re-point after an operator's unit-load move** (`reassignOrCancelForMovedStockUnit`). ⚠ On the move path, when every candidate is cooled the order is **cancelled**: cut a stock unit, then move its unit load within the window, and its order cancels instead of re-pointing. Operator-initiated creates (desktop, handheld) ignore it. Read via `getIntValue(key, 60)`: **no row, blank, non-numeric or beyond int range → 60**; `<= 0` → **off**; above **1440** → clamped to 1440, with a WARN once per tenant per distinct value, which an in-range or `<= 0` value resets (`ManualCutCooldown`). **No Flyway seed**, so the key is invisible on the sysprop screen until a row is inserted. Does not stop a partial cut regrowing on recalc (D-H1, accepted). ⚠ *unverified 2026-11-11:* the call-graph narrative in this row (which queries / callers are affected) was not re-traced in the 2026-11-11 pass; only the key, its default, the constant and the read/write site were re-checked. |
| `REPLENISHMENT_CLAIM_TIMEOUT_SECONDS` | `600` | **SBDEV-3626** (on `origin/develop` as of 2026-11-11 @ `df30fa62`: `V2.2.36__seed_replenishment_claim_timeout_sysprop.sql` present, constant `WmsConstants.java:1475-1476`; seeded by **V2.2.36**). Seconds a handheld claim on a replenishment order (`STARTED 500` + `operator_id`, stamped in `modified` by start and every heartbeat) survives without a heartbeat. `ReplenishOrderJob.releaseExpiredReplenishClaims` (first sub-op of every tick) releases an older claim to `PROCESSABLE`. Returned to the handheld as `claimTimeoutSeconds` on claim; the handheld heartbeats every `max(30, ttl/4)` s. Read through `ReplenishClaimTimeout.seconds` (`getIntValue(key, 600)`, uncached): **no row, blank or non-numeric → 600**; `<= 0` → never released; a positive value **below 60 is raised to 60** (heartbeat floor 30 s, job ticks per minute), and the handheld is told the same effective value. Raise it per tenant if the fleet browser freezes timers with the screen off (plan §7.1 fleet check). `ReplenishClaimTimeoutSeedConsistencyTest` pins the seed literal to the constant. |

---

## 7. Printing & Label Templates

ZPL (Zebra Programming Language) templates and sequence naming.

| Key | Default | Purpose |
|---|---|---|
| `PRINTING_ZPL_CASE_LABEL` | *(no constant default)* | Case-label ZPL template |
| `ZPL_TOTE_LABEL_VERSION` | *(no constant default)* | `REGULAR` or `AUTOMATION` |
| `PRINTING_ZPL_PICKING_TOTE_LABEL` | *(no constant default)* | Picking-tote ZPL |
| `PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION` | *(no constant default)* | Automation variant |
| `PRINTING_ZPL_OUTBOUND_PALLET_LABEL` | `add zpl code` (placeholder constant) | Outbound-pallet ZPL. ⚠ **No live reader** (0 non-comment references; `grep -rn PRINTING_ZPL_OUTBOUND_PALLET_LABEL src/main/java`) |
| `PRINTING_TOTE_LABEL_DETAILS` | no default; `LOCATION` is the **comparison value** (`SYSTEM_PROPERTY_PRINTING_TOTE_LABEL_DETAILS_VALUE`, `WmsConstants.java:1332`) | Extra content on tote label: when the row equals `LOCATION` the label lists each pick location; absent or any other value adds nothing (`OrderMonitorViewService.java:299-301`) |
| `PRINTING_DEFAULT_AMOUNT_TOTE_LABEL` | — | Default count per print job |
| `PRINTING_MAXIMUM_AMOUNT_TOTE_LABEL` | — | Max count per print job |
| `PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL` | — | Default sequence generator name |
| `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` | — | Default label pattern |
| `PRINTING_SEQUENCE_NAME_CLIENT_SPECIFIC_TOTE_LABEL` | — | Client-specific override |
| `PRINTING_PATTERN_CLIENT_SPECIFIC_TOTE_LABEL` | — | Client-specific override |
| `SEQUENCE_NAME_DEFAULT_OUTBOUND_PALLET_LABEL` | `PALLET_OUTBOUND` | Default outbound sequence |
| `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` | `OUT-%1$06d` | Outbound pallet pattern (printf-style) |
| `PRINT_CASE_LABEL` | constant `true` (`WmsConstants.java:1378`, `..._VALUE`) | Legacy flag name; today it is the **master printing switch** (`PrintService.isPrintingEnabled()`, `PrintService.java:99-101`). ⚠ The `true` constant is referenced only by commented-out seeding code, so an **absent row = printing OFF** (§1a) |

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
not been configured yet (template choice `LabelPrintingService.java:649-650`, `:722`; the other three identity labels resolve at `:599`, `:608-609`, `:617`).

Three behaviours to know before editing one:

- **Blank or missing fails loudly.** `requireTemplate()` throws `No ZPL template configured for <key>` —
  printing stops, it does not silently no-op.
- **Removing the identity token is rejected *before* any sequence number is consumed.**
  `requireTemplate(KEY, "{tote_id}")` (`:344`, `:599`) and `requireTemplate(KEY, "{label_id}")` (`:561`, `:609`) exist
  because a template that lost its token would print identity-less labels **while reporting every ID as
  successfully printed**.
- **Unresolved tokens render as `''`**, never left as literal `{...}` in the ZPL.

The seeded defaults deliberately omit `^PW`/`^LL` (so the printer's configured stock applies, matching
`PRINTING_ZPL_CASE_LABEL`) and use `^CI31` (UTF-8) like the existing templates.

**All five are byte-identical to the seeded default on all 5 DEV+UAT tenant DBs as of 2026-08-13**
(md5-compared against the migration literal) — no tenant has customized a label.

#### 7.1a Rollout prerequisites — the new tab depends on OLD keys

*Verified live on all 5 DEV+UAT tenants 2026-08-14. (Not re-read in the 2026-11-11 pass; the code anchors in this section were re-checked.)*

Seeding the five templates does **not** make the tab usable. `generateToteLabels` needs four things
the SBDEV-2861 migrations do not touch:

| Prerequisite | Where | Failure if unmet |
|---|---|---|
| `PRINT_CASE_LABEL` = `true` | sysprop | `requirePrintingEnabled()` throws for the whole tab. `cupsPrint` otherwise discards bytes and returns *normally* — a "successful" run at a printer that never moved |
| a `printer` row of type `OUTBOUND_TOTE` | `printer` table | `resolvePrinter()` fails; no tote generate or reprint |
| a tote **ID pattern** | resolved, see below | `No tote ID pattern configured` |
| `PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL` | sysprop | `No tote ID sequence configured` |

**The ID pattern is resolved in three steps, and the sysprop named for it is the LAST resort**
(`resolveTotePattern`, `LabelPrintingService.java:938`):

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
`SequenceTransactionService.java:34-40` creates the row on first use (now with a WARN, SBDEV-3682) — but it creates it at `0` and
**returns `0`**, so the first tote ever generated on each of these tenants is `T-0000` / `P-0000` /
`C1-0000`, not `…-0001`. The preview's "next ID" sample reads `peekNextSequenceNumber`, which returns
`0` for a missing row (`LabelPrintingService.java:1015-1017`, `.orElse(0L)`), and is labelled a sample in the UI.

#### `PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH` — a constant with no seed

| Key | Constant default | Seeded? | Live rows |
|---|---|---|---|
| `PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH` | `1000` (`FALLBACK_MAXIMUM_LABEL_BATCH`) | **no migration seeds it** | **0 of 5** tenant DBs |

Caps `labelId`s per reprint / location batch. Read via `syspropService.getIntValue(key, 1000)`
(`LabelPrintingService.java:1105-1109`; `FALLBACK_MAXIMUM_LABEL_BATCH = 1000` at `:107`), whose null/blank/**unparseable** fallback makes the absent row safe — the
cap is enforced at 1000 everywhere today. It exists to stop an uploaded list becoming an unbounded SQL
`IN` clause, ZPL buffer and physical print job. Because nothing seeds it, it is **invisible in the config
UI** (the admin screen lists by `groupname`), so raising the cap for a tenant currently requires an
`INSERT`, not an edit.

### CUPS Printing Server

| Key | Default |
|---|---|
| `CUPS_SERVER_ADDRESS_IP` | `cups-01.advancedinfomanagement.com` |
| `CUPS_SERVER_ADDRESS_PORT` | `631` |
| `CUPS_SERVER_ADDRESS_USERNAME` | *(value redacted)* *(⚠ no live reader: `PrintService` reads only `_IP` and `_PORT`)*. Row and constants deleted by V2.2.52 ✓ merged(SBDEV-4125: #668 465a4908, 2026-11-12) |
| `CUPS_SERVER_ADDRESS_PASSWORD` | *(value redacted 2026-11-12: a live credential, see SBDEV-4125. The value that is live on PRD/dev is the `V2.2.00` seed, md5-verified; an older value sat in the deleted constant and `V1.0.04`. Both must be **rotated** by devops)*. No live reader. Row and constant deleted by V2.2.52 ✓ merged(SBDEV-4125: #668 465a4908, 2026-11-12) |

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

> ⚠ *Verified 2026-11-11:* `STRING_PATTERN_SEPARATE_STOCK` has **no live reader** (0 non-comment references outside `WmsConstants`). Of the other four, only `STRING_PATTERN_INBOUND_PALLET` applies its constant when the row is absent (`ReceivingService.java:951-953`); the rest read `null` (§1a).

---

## 9. Keycloak / Authentication

⚠ **Corrected 2026-11-11.** This section previously said these rows "must be populated per-tenant or auth will fail". On `origin/develop` @ `df30fa62` **none of the eight `KEYCLOAK_*` keys has a live reader** (`grep -rn "KEYCLOAK_" src/main/java` outside `WmsConstants` hits only the commented-out seeding block of `UtilRestController`; the two `KEYCLOAK_OMS_USER_*` keys are not even referenced in comments). Per-tenant JWT/issuer configuration comes from the landlord DB (`TenantAuthConfiguration` / `TenantAuthConfigurationRepository`, consumed by `MultiTenantJwtDecoder`, default issuer `rest.security.issuer-uri`, `MultiTenantJwtDecoder.java:43`), not from `los_sysprop`. The rows can exist (the base dump seeds them) and are editable in the UI, but changing them changes nothing. No `*_DEFAULT_VALUE` constants exist for them.

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
| `OMS_API_USER` | OMS-side service account, `user/password` form — split on the first `/` and sent as HTTP Basic auth on every OMS call (`HttpRestService.java:151-153`) |
| `SYSTEM_OMS_NAME` | OMS instance identifier (read per call via `SyspropService.getOmsInstanceName()`, `SyspropService.java:407`) |
| `SYSTEM_WMS_NAME` | WMS instance identifier (`SyspropService.getWmsInstanceName()`, `:411`) |
| `WMS_LOGIN_SECRET` | Legacy login secret (pre-Keycloak paths). ⚠ No live reader |

### 9.1 Secret sysprops: masked on every HTTP read ✓ merged(SBDEV-4133: #678 042f9a13, 2026-11-15)

`WmsConstants.SystemProperty.SECRET_SYSKEYS` = `OMS_API_USER`, `WMS_LOGIN_SECRET`, `KEYCLOAK_API_USER`, `CUPS_SERVER_ADDRESS_PASSWORD` (the last kept as a literal until V2.2.52 is on every tenant). `util.SyspropSecrets.isSecret(syskey)` = on that list **OR** `SensitiveMapRedactor.isSensitive(syskey)` (fragment rule, so a future `*_PASSWORD` / `*_TOKEN` key is covered; the two `*_API_USER` keys need the list). The rule is keyed on **syskey**, never groupname.

- **Reads.** The value shows as `***REDACTED***` on `GET /v3/system/searchSystemByGroupname/{group}` (DTO mask in `SyspropService.getSystemByGroupname`) and on every Jackson write of a `Sysprop` (`@JsonSerialize(using = SysvalueMaskingSerializer.class)` on the field): SDR `/v3/sysprop`, `/{id}`, every `search/find*`, the SDR PUT 200 body, and the MVC `/v3/systemProperty/{create,updateValue,updateClient}` echoes. `Sysprop.getSysvalue()` stays raw for Java callers (printLabel, `HttpRestService`, the `sysprops` cache).
- **Withdrawn.** SDR `search/findSysvalueBySyskey` and `search/findSysvalueByClientIdAndSyskey` are `exported = false` (404); `SyspropService.getSysvalue` still calls the first in-process.
- **Writes.** A value equal to the sentinel is refused 422 (SDR PUT and MVC `/create`, `/updateValue`), so a GET→PUT echo cannot overwrite a secret; type a new value to change one. `SyspropWriteFenceEventHandler` refuses any `groupname` change (including to/from null) and any `syskey` rename over SDR PUT (422), and on a secret row also any `workstation` / `client_id` change, comparing against the committed row (`SyspropService.readCommittedSysprop`). MVC `/create` refuses a secret key in `Labels`; `/updateClient` refuses moving a secret row to another client (422).
- **Printing.** `GET /v3/printer/printLabel/{key}` refuses a secret syskey even when its row sits in `Labels` ("Unknown label", nothing printed).
- **Matching.** The list match ignores case and surrounding whitespace (`oms_api_user` is secret); the fragment rule already normalises.
- **Not closed by this:** a sysprop writer can still redirect `OMS_API_USER` by rewriting a `WEBSERVICE_*_URL` row, or overwrite it (register P100, SBDEV-4131).
- **Changing the list** means editing `SECRET_SYSKEYS` and this section together.

---

## 10. Cycle Count, Shipping, Inbound, Misc

### Cycle count

| Key | Default | Purpose |
|---|---|---|
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` | `true` | Show expected qty on the count screen — **inert: no reader in wms2-api or wms2-mobile-ui; accessors, constants and row deleted by V2.2.52** ✓ merged(SBDEV-4125: #668 465a4908, 2026-11-12) |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` | `0` | Only show when diff ≥ N — **inert: no reader in wms2-api or wms2-mobile-ui; accessors, constants and row deleted by V2.2.52** ✓ merged(SBDEV-4125: #668 465a4908, 2026-11-12) |
| `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT` | `true` | Require comment on recount — **inert: no reader in wms2-api or wms2-mobile-ui; accessors, constants and row deleted by V2.2.52** ✓ merged(SBDEV-4125: #668 465a4908, 2026-11-12) |

### Shipping

| Key | Default | Purpose |
|---|---|---|
| `SHIPPING_METHOD_ACTIVATED` | `false` | Enable shipping-method feature |
| `SHOW_MANIFEST_LOCATION` | `false` | Show manifest-location column in BOL UI |
| `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` | seeded `40` by V2.2.40 (`los_sysprop` group `Operation Options`, `workstation='DEFAULT'`, `client_id=0`, idempotent `WHERE NOT EXISTS`) | Parcels per `ORDER_BATCH_SHIPPED` outbox row (= one OMS `finishedShipping` call) when a REGULAR or HUB_AND_SPOKE BOL is closed; transfers are never chunked. Read **once per close** by `BillofladingService.enqueueBolShippedNotification` (`:848`, read at `:855-856`) via `BolShippedNotificationChunker.resolveChunkSize` (`:58`). Fallback: missing or blank → `40` silently (code default `DEFAULT_CHUNK_SIZE` parses `SYSTEM_PROPERTY_BOL_SHIPPED_OMS_CHUNK_SIZE_DEFAULT_VALUE`, `WmsConstants.java:1455`); non-numeric or < 1 → `40` with a WARN; > 60 (`CHUNK_SIZE_CEILING`) → `60` with a WARN. Never throws, so a bad value cannot fail a close. `BolShippedOmsChunkSizeSeedConsistencyTest` pins the constant to the migration literal ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |

### Inbound / Receiving

| Key | Default | Purpose |
|---|---|---|
| `MAXIMUM_RECEIVING_DURING_INBOUND` | `100` | Cap on concurrent inbound rows |
| `INBOUND_UPDATE_STOCK_IMMEDIATELY` | `true` (constant `..._VALUE`; ⚠ absent row = OFF, §1a) | Apply stock delta on receive (vs batched later) (`ReceivingService.java:650`) |
| `REQUIRE_RECEIVING_TO_CONTAINER` | `TRUE` (⚠ absent row = `false`, §1a) | Enforce container scan on receive (`ReceivingController.java:489`) |

#### `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` (SBDEV-2778) — the only flag that ships ON

| Key | Seed | Default when row absent | Read at |
|---|---|---|---|
| `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` | **`true`** (V2.2.09) | **`true` — ON** | `ReturnAdviceAutoReceiveService.java:212-215` (`isAutoReceiveEnabled`) |

ON: a `POST` of a `type=RETURN` advice is **received and closed at create time**, restoring the v1
behaviour SBDEV-2236 deleted (`AdviceRestController.java:336-343`, batch guard `:210-212`). Set to `false`: the advice stays OPEN and is
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
returns. Without it, `ReceivingService` resolves the operator from
`SecurityContextUtils.getUserName()` *(⚠ unverified 2026-11-11: the old anchor `ReceivingService:359` no longer points at this; the lookup is now `userRepository.findByName(SecurityContextUtils.getUserName())` at `ReceivingService.java:433`; the `anonymous`-stamping consequence was not re-traced)*, and `/rest/**` is unauthenticated, so every auto-received return's
`goodsreceipt.operator_id` and stock-history row would be stamped with the shared `anonymous` user.

### Picking — UI

| Key | Default | Purpose |
|---|---|---|
| `PICK_SCREEN_SIMPLE` | `false` | Simplified pick screen variant |
| `PICK_PATH_DIRECTION` | `VERTICAL` | Sort direction for picking, putaway, cycle-count, and move-stock: `VERTICAL` = column-first (X→Y), `HORIZONTAL` = row-first (Y→X). Read via `PickPathConfig` → `SyspropService` (cached per-tenant). Seeded by `V2.1.09__add_pick_path_direction_sysprop.sql:7` (value `VERTICAL`) — ⚠ that file lives in `db/v1-to-v2-onboarding/schema/`, **not** in `db/migration/`, so Flyway does not apply it. Absent, blank or unknown value -> `VERTICAL` (`PickPathConfig.java:23-31`). |

### Picking — Order-release behavioral guards

| Key | Default | Purpose |
|---|---|---|
| `ENFORCE_PARTITIONALLOWED` | `true` (default ON) | **SBDEV-2512** kill-switch for the overstock-release `partitionallowed` guard in `ReleaseOrderJobService.releaseOrder`. When ON, a non-partitionable (`partitionallowed=false`) customer-order position that no **single** stock unit can cover is **held** (position `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION`, order `RAW_ON_HOLD`) rather than fragmented across units (Fix A, round-2 cumulative), and a coverable one takes exactly **one** pick from a single covering unit (Fix B, phase 3). Read once per release via `SyspropService.getSysvalue`; **absent/null row also enforces** (`!"false".equalsIgnoreCase(...)`), so it is safe before seeding. Set `false` to restore legacy fragmenting behavior with **no redeploy** (Caffeine `sysprops` TTL ~2 min). Every v2 position is non-partitionable today (`OrderBatchCreationService` hard-codes `setPartitionallowed(false)`), so this is a 100%-blast-radius cron guard — the Fix A hold emits a mandatory `LOG.info`. |

### Transfer orders — lane depletion

| Key | Default | Purpose |
|---|---|---|
| `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` | `false` | Per-tenant opt-in (SBDEV-1762). When `true`, the Transfer-Order "run transfer" flow (`BillofladingService.transferOrder`) deplete-consumes **only** the order's required SKUs + quantities from the transfer lane — club-like — instead of the legacy exact-match + sweep-everything. Read once per `transferOrder` call via `SyspropService.getSysvalue`; absent row → `Boolean.parseBoolean(null)=false` → OFF (byte-identical to legacy). Constant + gating are on `origin/develop` (SBDEV-1762; read at `BillofladingService.java:945`). **Seed:** row seeded **default OFF** by Flyway **V2.2.04** (`V2.2.04__seed_lane_behavior_sysprop_toggles.sql`, PR #93). |
| `TRANSFER_DESTINATION_CONSTRAINT_ENFORCED` | `false` | **SBDEV-3340** gate (*added 2026-11-11 — was missing*). When `true`, `StockunitService.assertMintedContainerIsPermittedAtDestination` **refuses** a container mint whose type the destination's `location_constraint` does not permit; when `false` it evaluates and logs `SBDEV-3340 shadow` WARNs only. Covers **only** `transferStock`'s NEW-CONTAINER and PALLET-CARRIER mint routes (not the three mints of `MobileTransferOrderService`). Read with `Boolean.parseBoolean(getSysvalue(KEY))` (`StockunitService.java:275-276`) so absent row = OFF. **Not seeded by any migration** by design — create the row in System Properties to switch a tenant on (comment at `WmsConstants.java:1520-1529`) |
| `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` | `false` | SBDEV-2994 sibling gate for Move Stock destinations — see §11.1 / §11.2 (V2.2.17). Read at `DestinationEligibilityService.java:211` (`enforcing()`, deliberately via `getSysvalue`, not `getStringDefault`) |

### Misc

| Key | Default | Purpose |
|---|---|---|
| `System Time Zone` | — | Warehouse-local time zone (key literal contains a space; constant `SYSTEM_PROPERTY_WAREHOUSE_TIME_ZONE_KEY`, `WmsConstants.java:1193`; read at `TimezoneService.java:82`, `OrderReleaseJob.java:373`) |
| `API_TIMESTAMP_FORMAT` | — *(no default const)* | Timestamp serialisation format for API responses. `ISO8601_UTC` on all 5 DEV+UAT tenants |
| `AREA_DEFAULT` | — *(no default const)* | Default location area. **Only key declared outside the `SYSTEM_PROPERTY_*_KEY` convention** — it lives at `WmsConstants.LocationAreaService.PROPERTY_KEY_AREA_DEFAULT` and is read by `LocationAreaService:66`, so a `SYSTEM_PROPERTY_` grep will miss it |
| `WAREHOUSE_NAME` | — | Human-readable warehouse name |
| `WMS_INSTANCE_NAME` | — | This WMS instance ID. ⚠ No live reader (the live pair is `SYSTEM_OMS_NAME` / `SYSTEM_WMS_NAME`, §9) |
| `MOBILE_UI_URL` | `http://localhost:3001/mobile` (constant, never applied — absent row = `null`, §1a) | Mobile UI base URL (`SystemController.java:60`) |
| `MOBILE_UI_REDIRECT_URL` | — | Post-SSO mobile redirect. ⚠ No live reader |
| `WEB_UI_REDIRECT_URL` | — | Post-SSO web redirect. ⚠ No live reader |
| `DEFAULT_BOX_TYPE` | `UL_TYPE_BOX_NAME_14` (constant ref) | Default box type for unit loads |
| `MULTIWAREHOUSE_IDENTIFIER` | `add_identifier` (placeholder) | Multi-WH routing tag |
| `ORDER_MONITOR_CALCULATE_OLDER_THAN_DAYS` | `10` | Order-monitor view lookback. Read by syskey string in native SQL, not via the constant: `OrderMonitorViewRepository.java:120,209,294,383` (the "old orders" threshold) |
| `EXPORT_LIMIT` | `10000` | Max rows per CSV export. ⚠ No live reader |
| `EXPORT_DATE_FORMAT` | `yyyy-MM-dd HH:mm:ss.SSS` | CSV export date format. ⚠ No live reader |
| `CSV_FILE_SEPARATOR` | `,` | CSV column separator. ⚠ No live reader |
| `DB_VERSION` | — | Current DB schema version (read-only). ⚠ No live reader (only a commented `UtilRestController` seeding line) |
| `OMS_TENANT_ID` | — | OMS-side tenant identifier (sent by `HttpRestService.java:160` when non-null) |
| `MOBILE_FORCE_SCAN_ENABLED` | `false` | Per-tenant switch: when `true`, mobile identity fields accept scans only and typed entry needs a manager override (a client-side deterrent plus a server audit row; the server cannot tell a scan from typing). Holders of `MOBILE_UI_ACTION_MANUAL_ENTRY` are exempt. Default `WmsConstants.java:1627-1628`; read at `MobileForceScanController.java:106` (only the literal `true`, case-insensitive, turns it on); seeded `V2.2.42:62` ✓ merged(SBDEV-3132: #577 ce20ee89, 2026-10-28) |
| `MOBILE_OVERRIDE_APPROVER_CAP` | `10` | Max failed override attempts per approver, all pickers, per cap window. Clamped to 1-100 (`ManualEntryOverrideLimits.java:28-29`, `approverCap():50`); unparseable or out-of-range falls back to `10` with a WARN at most hourly. Default `WmsConstants.java:1629-1630`; seeded `V2.2.42:78` ✓ merged(SBDEV-3132: #577 ce20ee89, 2026-10-28) |
| `MOBILE_OVERRIDE_APPROVER_CAP_WINDOW_MIN` | `15` | Window in minutes for `MOBILE_OVERRIDE_APPROVER_CAP`. Clamped to 10-1440 (`ManualEntryOverrideLimits.java:30-31`, `capWindowMinutes():57`); out-of-range falls back to `15`. Default `WmsConstants.java:1631-1632`; seeded `V2.2.42:94`. Design: [SBDEV-3132 plan](../../1-Projects/wms2/plan/SBDEV-3132-mobile-force-scan-manager-override.md) ✓ merged(SBDEV-3132: #577 ce20ee89, 2026-10-28) |

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

*Added 2026-08-13; seeds and live state re-verified 2026-09-10. Covers every `los_sysprop` seed after
the `V2.2.00` base schema.*

### 11.1 The seeds

Twenty-four of the fifty post-`V2.2.00` migrations (`V2.2.01`-`V2.2.50`) write to `los_sysprop` (`grep -lE '^\s*(INSERT INTO|UPDATE|DELETE FROM)\s+(public\.)?los_sysprop' V2.2.*`, 2026-11-11 @ `df30fa62`): 21 seed keys (`V2.2.04/05/06/09/10/11/13/14/15/16/17/22/23/24/27/29/36/40/41/42/47`), `V2.2.37` and `V2.2.39` delete dead keys, `V2.2.48` rewrites one description; the rest are views, functions and tables only. **30 keys are seeded post-base (30 `INSERT INTO public.los_sysprop` statements), 29 survive** — `V2.2.39` deletes `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED`; `V2.2.37` deletes `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` and `WEBSERVICE_BEHAVIOUR`, which only the base dump ever seeded. *(Recounted 2026-11-11; the 2026-09-10 figures were "14 of 25 migrations, 19 keys".)*

⚠ **Superseded 2026-11-11:** the "IN FLIGHT / NOT merged" labels that used to sit on `V2.2.27` (PR #343), `V2.2.36`, `V2.2.42` and `V2.2.47` are stale — all four files are on `origin/develop` @ `df30fa62`. **§11.3's `/19` denominator is still the 2026-09-10 scope** (the 19 keys that existed then) and was not re-measured; the live DBs have not been re-read in this pass.

| Migration | Key | Seeded value | Group | Ticket |
|---|---|---|---|---|
| V2.2.04 | `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` | `false` | Operation Options | SBDEV-1762 |
| V2.2.04 | `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` | `false` | Operation Options | SBDEV-1666 — **retired by SBDEV-3654**, read by nothing. **Deleted by V2.2.39 (SBDEV-3659)** ✓ merged(SBDEV-3659: #523 ee3747f2, 2026-10-16): a fresh DB still gets the row from V2.2.04, then loses it to V2.2.39 |
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
| V2.2.17 | `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` | `false` (**shadow mode**) | Operation Options | SBDEV-2994 |
| V2.2.22 | `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY` | *derived* from the `…_CANCELLED` host → `/services/call/updateBatchPriority`; else `CHANGE-ME-FOR-NEW-CLIENT/…` | Backend | SBDEV-2573 |
| V2.2.22 | `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED` | `false` | Backend | SBDEV-2573 |
| V2.2.23 | `WMS2_SDR_READ_GUARD_MODE` | `OFF` | Backend | SBDEV-3169 |
| V2.2.24 | `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE` | *derived* as above → `/services/call/updatePickingDate`, `NULLIF`-guarded | Backend | SBDEV-3273 |
| V2.2.24 | `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED` | `false` | Backend | SBDEV-3273 |
| V2.2.36 | `REPLENISHMENT_CLAIM_TIMEOUT_SECONDS` | `600` | Operation Options | SBDEV-3626 (on develop) |
| **V2.2.11 — applies OUT OF ORDER** | `ADJUSTMENT_ALERT_POLL_ACTIVATED` | `false` | Operation Options | SBDEV-2658 |
| V2.2.27 | `WMS_CLUBLINE_MAX_BATCH_SIZE` | `5000` | Operation Options | SBDEV-3304 (on develop) |
| V2.2.29 | `WMS_CLUBLINE_OMS_CHUNK_SIZE` | `1` | Operation Options | SBDEV-3310 — *added 2026-11-11, was missing.* `V2.2.48` rewrites the description to "Keep at 1" (the PRD rollout of 100 was dropped 2026-11-05) |
| V2.2.47 ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06) | `WMS_CLUBLINE_ASYNC` | `'1'` | Operation Options | SBDEV-4007; the same migration creates `club_run_job`. `WHERE NOT EXISTS (syskey, workstation='DEFAULT')`, so a tenant with a row keeps its value |
| V2.2.40 | `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` | `40` | Operation Options | SBDEV-3672 — merged 2026-10-22, on PRD since v0.0.43 (2026-10-27); the same migration adds `outbox_message.last_message_id` ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |
| V2.2.41 | `EMPTY_PALLET_CLEANUP_ACTIVATED` | `false` | Backend | SBDEV-1581 — *added 2026-11-11, was missing* (see §4.6c) |
| V2.2.41 | `EMPTY_PALLET_CLEANUP_TIMER_HOUR` | `3` | Backend | SBDEV-1581 |
| V2.2.41 | `EMPTY_PALLET_CLEANUP_TIMER_MINUTE` | `15` | Backend | SBDEV-1581 |
| V2.2.42 | `MOBILE_FORCE_SCAN_ENABLED` | `false` (OFF) | Operation Options | SBDEV-3132; the same migration creates `mobile_manual_entry_override`, seeds function `MOBILE_UI_ACTION_MANUAL_ENTRY` and grants it to `inventory-manager`, `outbound-manager`, `super-admin` (`V2.2.42:49-54`) ✓ merged(SBDEV-3132: #577 ce20ee89, 2026-10-28) |
| V2.2.42 | `MOBILE_OVERRIDE_APPROVER_CAP` | `10` | Operation Options | SBDEV-3132 ✓ merged(SBDEV-3132: #577 ce20ee89, 2026-10-28) |
| V2.2.42 | `MOBILE_OVERRIDE_APPROVER_CAP_WINDOW_MIN` | `15` | Operation Options | SBDEV-3132 ✓ merged(SBDEV-3132: #577 ce20ee89, 2026-10-28) |

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
| `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` | `BillofladingService.java:945` (read site in the transfer-run flow) deplete-consumes only the order's required SKUs/qty, reserved-adjusted (club-like); remainder stays on the lane | exact-match + sweep-everything — consumes the whole transfer lane |
| `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` | **nothing — retired by SBDEV-3654.** Lanes are never a replenishment source on any tenant, whatever this value | nothing (until SBDEV-3654: lanes were eligible sources) |
| `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` | **nothing — see 11.4** | nothing |
| `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` | `OutboxDispatchService.sampleStuckAggregates()` (gate read at `OutboxDispatchService.java:382-383`) runs the read-only `findStuckAggregateStats()` per tenant per dispatcher tick (3 s since `application.properties:219`; was 15 s) and emits the held-aggregate gauge | returns `null`, no gauge row for that tenant |
| `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` | a `type=RETURN` advice is received **and closed at create time** | (only literal `false`) advice stays OPEN, received at the dock via `POST /v3/receiving/receive` |
| `WMS_CLUBLINE_MAX_BATCH_SIZE` *(SBDEV-3304, V2.2.27, on develop)* | **not a gate — a numeric ceiling.** `CustomerorderBatchService.validateClubLine` refuses a club run whose active-order count exceeds it, with a message naming the value enforced. Clamped at both ends: `< 1` or non-numeric falls back to the code default (a `0` row would otherwise reject every club run in that tenant, including single-order ones); above `CLUBLINE_MAX_BATCH_SIZE_CEILING` (10 000) it clamps — a typo guard, **not** a throughput measurement | falls back to `CustomerorderBatchService.DEFAULT_MAX_CLUB_LINE_BATCH_SIZE`, which reads this same seeded value, so absent and seeded resolve identically. ⚠ There is **no** Spring property any more: SBDEV-3304 deleted `wms.clubline.max-batch-size`, whose env-var spelling was byte-identical to this key. This sysprop is the only surface |
| `WMS_CLUBLINE_ASYNC` *(SBDEV-4007)* ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06) | **kill switch for NEW jobs only.** `'1'` (and ANY value other than exactly `'0'`, including `'false'`): `POST /v3/clubLine/clubRunJobs/{batch}` submits a resumable `club_run_job` and `GET /runClubLine` submits then waits up to 45 s (`ClubRunJobService.isAsyncEnabled`) | exactly `'0'`: submit answers `"Async club run is disabled for this warehouse (WMS_CLUBLINE_ASYNC=0)"` and `GET /runClubLine` runs inline as before; refused while a live job exists for the batch. **Live jobs always keep draining** (the poller ignores the key). A missing or blank row resolves to the code default `'1'` (`WmsConstants.SYSTEM_PROPERTY_CLUBLINE_ASYNC_DEFAULT_VALUE`); `ClublineAsyncSeedConsistencyTest` pins it to the V2.2.47 literal. Per tenant, read on every submit. ⚠ Only a narrow check-then-act window (between `ClubRunJobService.hasLiveJob` and the inline validate) lets an inline run overlap a live job; then the job FAILs with `; batch at 527 owned by another run` ([wms2-club-run-workflow](../workflows/wms2-club-run-workflow.md) §8A.8) |
| `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` *(SBDEV-3672)* | **not a gate — a numeric chunk size.** A REGULAR or HUB_AND_SPOKE BOL with more parcels than this is sent to OMS as N chunk rows; clamped to `[1, 60]`, see §10 Shipping ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | absent or blank resolves to `40`, the seeded value, so absent and seeded behave identically ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |
| `WMS_CLUBLINE_OMS_CHUNK_SIZE` *(SBDEV-3310, V2.2.29)* | **not a gate — a numeric chunk size.** Club orders per OMS picking notification (one outbox row per status per chunk) in `CustomerorderBatchService.enqueueClubNotificationsChunked`; `1` = one row per order; clamped to `[1, 300]` (`CLUBLINE_OMS_CHUNK_SIZE_CEILING`, `CustomerorderBatchService.java:134`) | absent, blank, non-numeric or `< 1` -> `1` (`resolveClubLineOmsChunkSize`, `:662-684`). **Keep at 1 on every tenant** (rollout of 100 dropped 2026-11-05; larger chunks "not safe yet") |
| `REPLENISHMENT_CLAIM_TIMEOUT_SECONDS` *(SBDEV-3626, V2.2.36)* | **not a gate — seconds** a handheld claim on a replenishment order survives without a heartbeat before `ReplenishOrderJob` releases it; `<= 0` never releases; a positive value `< 60` is raised to 60 (`ReplenishClaimTimeout.java:15-24`) | absent, blank or non-numeric -> `600` (`getIntValue(key, 600)`) |
| `EMPTY_PALLET_CLEANUP_ACTIVATED` *(SBDEV-1581, V2.2.41)* | `EmptyPalletCleanupJob` runs at the `_TIMER_HOUR:_TIMER_MINUTE` slot (needs `NEW_CRON_JOB_ACTIVATED` too) and returns empty Pallet/Cart unit loads to EmptyPallets | **job skipped** (`parseBoolean(null)`); an absent hour/minute row also means the job is not scheduled (§1a) |
| `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` | destination accepted when its area has `useforpicking = true`, no FLA created — club locations become valid | destination must be a flowbin with an FLA |
| `DEFAULT_PUTAWAY_LOCATION` | (location id) tier 3 of `SKU > merchant > warehouse > PutAwayLane` | blank = not configured, falls through to tier 4 |
| `ADJUSTMENT_ALERT_POLL_ACTIVATED` | `GET /v3/stockrecord/adjustmentAlerts` serves adjustment stockrecords to the web-UI bell/toast poller. **Audience (SBDEV-4002):** a caller sees only rows whose `operator` is themselves; holders of `WEB_UI_VIEW_ALL_ADJUSTMENT_ALERTS` (super-admin, V2.2.46) see every row ✓ merged(SBDEV-4002: #615 08113d9f, 2026-11-04) | returns an empty item list — the bell stays silent (absent row = OFF) |
| 5 × `PRINTING_ZPL_*` | not toggles — the template *is* the output (§7.1) | blank/missing throws `No ZPL template configured` |
| `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` | `DestinationEligibilityService` **refuses** a Move Stock destination whose lock is not `NOT_LOCKED` or which sits at the Shipped location | **shadow mode** — the rule is still evaluated and a `SBDEV-2994 shadow: would have refused …` WARN logged, but the move is allowed. That WARN is the instrument: one full operating cycle at zero lines, then flip. The Nirvana-sentinel refusal is **not** governed by this row (unconditional, SBDEV-2995) |
| `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED` | `PriorityChangeNotificationService` enqueues an outbox message on every batch- or order-level priority change | no notification; OMS `batch_criteria.priority` keeps the value chosen at batching time. Needs a real URL in `…_UPDATE_PRIORITY` **and** the OMS endpoint deployed first |
| `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED` | `PickingDateChangeNotificationService` enqueues an outbox message on every `CustomerorderService.setPickingDate` | no notification; OMS `order.requested_ship_date` goes stale (QA on SBDEV-2945). Same URL + endpoint prerequisite |
| `WMS2_SDR_READ_GUARD_MODE` | not a boolean — `OFF` \| `SHADOW` \| `ENFORCE_RULED` \| `FAIL_CLOSED`. `SHADOW` measures `wms2.authz.sdr.would_deny`; `ENFORCE_RULED` enforces | `OFF`, and **any unrecognised value also parses to `OFF`** (`SdrGuardMode.parse`). ⚠ Deliberately **not API-writable** — `SystemPropertyController` and `PutawayConfigRepositoryEventHandler` refuse this syskey on every write verb; SQL is the only path (finding F1) |

### 11.3 Live state — all six v2 tenant DBs, 2026-09-10

> ⚠ *unverified 2026-11-11:* the live DBs were **not** re-read in the 2026-11-11 pass. Everything in this subsection is a 2026-09-10 snapshot (plus the dated supersessions inside it). `origin/develop` has since added keys and migrations (V2.2.25-V2.2.50; §11.1), so the `/19` column and the "PRD is two migrations behind" statements are out of date by construction.

Read directly with `psql` against the DSNs in `~/.claude.json` (the MCP servers were unreachable that
session; the DBs were not — see [[wms-mcp-tools-not-surfaced-use-psql-direct]]). **Hydra PRD is
included for the first time.**

| Env | Tenant | DB | Flyway head | Keys /19 | Deviations from seed |
|---|---|---|---|---|---|
| **PRD** | hydra/nywh ✅ (the only v2 PRD tenant, `active=t`) | `wh01_hydra_v2` :25061 | **2.2.21**, 0 failed | **14/19** | none among the 14 — but **V2.2.22/23/24's 5 keys are absent** |
| UAT | wineco/wsl | `wh01_om1_v2` | 2.2.23, 0 failed | 17/19 | none — `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` is back to `false` (it was `true` on 2026-08-13) |
| UAT | hydra/nywh | `wh01_hydra_v2` | 2.2.24, 0 failed | 19/19 | none |
| UAT | shipitez/nywh | `wh02_shipitez_v2` | 2.2.24, 0 failed | 19/19 | `TRANSFER_LANE_PARTIAL_DEPLETION`=**true**, `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES`=**true**, `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS`=**true** |
| UAT | shipitez/c1wh | `wh01_shipitez_v2` | 2.2.24, 0 failed | 19/19 | same three = **true** |
| DEV | wineco/wsl | `dev_wh01_om1` :25060 | 2.2.25, 0 failed | 19/19 | `TRANSFER_LANE_PARTIAL_DEPLETION`=**true**, `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES`=**true**, `ADJUSTMENT_ALERT_POLL_ACTIVATED`=**true** |

Uniform across all six: exactly one row per key, `client_id = 0`, `workstation = 'DEFAULT'`, groupname as
seeded. No duplicates, no client- or workstation-scoped copies, no NULL-groupname strays. All five ZPL
templates byte-identical to the seed (md5-compared) on all six. `DEFAULT_PUTAWAY_LOCATION` blank
everywhere (tier 3 unconfigured). `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` = `true` everywhere.
`WMS2_SDR_READ_GUARD_MODE` = `OFF` on all five DBs that have it.

⚠ **PRD is two migrations behind `origin/main`** (main's head is V2.2.23; `release` is at 2.2.24,
`develop` at 2.2.25). Hydra PRD's last Flyway run was **2026-08-26 15:26 UTC**, which is what dates the
running image — so on PRD today the SBDEV-2573 priority notification and the SBDEV-3273 picking-date
notification have **no URL row and no gate row**, i.e. both features are unavailable there, not merely
switched off. Both arrive with the next PRD deploy (Flyway runs at boot).

⚠ **The `WMS2_SDR_READ_GUARD_MODE` uncached-miss cost has not yet reached PRD, and cannot.** The row is
absent on PRD, which is the condition §11.4-adjacent finding H1 describes (a `null` result is never
cached, so every SDR request re-queries). But `SdrGuardModeProvider` first landed 2026-08-31, *after*
PRD's 2026-08-26 boot, so the guard code is not in the running image. Because `StartupFlywayMigrator`
runs at boot, the deploy that brings the provider also applies V2.2.23 — code and row arrive together
and the window never opens. Do not "fix" this by seeding the row ahead of the deploy.

⚠ **`ADJUSTMENT_ALERT_POLL_ACTIVATED` is now seeded on all six** and is **`true` on DEV only**. The
2026-08-13 pass recorded it as absent everywhere; V2.2.11's out-of-order application closed that.
**Superseded 2026-11-03 (SBDEV-3509):** both ShipItEZ PRD warehouses (`c1wh-shipitez-prd`,
`nywh-shipitez-prd`) read `true`, row `modified` 2026-09-18 ~12:36 UTC. Read by `SELECT * FROM los_sysprop
WHERE syskey ILIKE 'ADJUSTMENT_ALERT%'`. The other PRD/UAT tenants were not re-read in that pass.

⚠ **No two environments are configured alike for the three replenishment/transfer toggles.** The two
shipitez UAT tenants have all three ON; wineco UAT has all three OFF; DEV has two of three ON; PRD has
all three OFF. **No environment rehearses PRD for these features, and UAT does not rehearse itself.**
The 2026-08-13 entry called the two wineco environments "inverse configurations" — that specific shape
is gone (wineco UAT flipped non-flowbin back to `false`), but the general warning holds and is now
broader.

⚠ The dev `wh01_hydra_v2` unmanaged-DB warning from 2026-08-13 was **not** re-checked in this pass; it
is `active = false` in `dev_landlord` and is not one of the six DBs above.

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

As of 2026-11-11, **48 of the 152** `*_KEY` constants in `WmsConstants.java` have no paired default constant (and §1a shows 81 of the 104 that do have one never apply it; SBDEV-4126 deletes 70 of those ✓ merged(SBDEV-4126: #669 722f3ea4, 2026-11-12)). Consumers either hard-code a default inline, read `null`, or require the DB row to exist. The 48:

- All 8 Keycloak keys (§9)
- `PRINTING_ZPL_CASE_LABEL`, `ZPL_TOTE_LABEL_VERSION`, `PRINTING_ZPL_PICKING_TOTE_LABEL`, `PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION`
- All 5 SBDEV-2861 identity templates (§7.1) — no constant default by design; `requireTemplate()` throws instead of falling back, so a missing row is a loud failure rather than a silent wrong label
- `WAREHOUSE_NAME`, `OMS_TENANT_ID`, `OMS_API_USER`, `SYSTEM_OMS_NAME`, `SYSTEM_WMS_NAME`, `System Time Zone`, `API_TIMESTAMP_FORMAT`, `DB_VERSION`, `WMS_INSTANCE_NAME`, `MOBILE_UI_REDIRECT_URL`, `WEB_UI_REDIRECT_URL`, `WMS_LOGIN_SECRET`
- keys read with an inline rule instead of a constant: `ADJUSTMENT_ALERT_POLL_ACTIVATED`, `ENFORCE_PARTITIONALLOWED`, `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`, `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED`, `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED`, `DEFAULT_PUTAWAY_LOCATION`, `PICK_PATH_DIRECTION`
- printing: `PRINTING_DEFAULT_AMOUNT_TOTE_LABEL`, `PRINTING_MAXIMUM_AMOUNT_TOTE_LABEL`, `PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH`, `PRINTING_PATTERN_DEFAULT_TOTE_LABEL`, `PRINTING_PATTERN_CLIENT_SPECIFIC_TOTE_LABEL`, `PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL`, `PRINTING_SEQUENCE_NAME_CLIENT_SPECIFIC_TOTE_LABEL`
- the five un-prefixed page/timeout keys, all inline literals: `REPLENISHMENT_PAGE_SIZE` (1000), `REPLENISHMENT_PAGE_LIMIT` (100), `FIX_LOCATION_PAGE_SIZE` (2000), `FIX_LOCATION_PAGE_LIMIT` (100), `OMS_EXPORT_CONSUMER_TIMEOUT_S` (120)
- **9 keys whose companion is named `..._VALUE`, not `..._DEFAULT_VALUE`** (so a `*_DEFAULT_VALUE` grep misses them): `MERGE_PICKING_ORDERS`, `INBOUND_UPDATE_STOCK_IMMEDIATELY`, `PRINT_CASE_LABEL`, `PRINTING_TOTE_LABEL_DETAILS`, `MOBILE_UI_URL`, `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY`, and the three `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_{LOWER,MIDDLE,UPPER}_BOUND`

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

### Constants with no live reader

*Added 2026-11-11; corrected after review the same day.* 21 `*_KEY` constants in `WmsConstants` have **zero non-comment references** anywhere in `src/main/java` (method: `grep -rn <CONSTANT> src/main/java`, excluding `WmsConstants.java` and lines starting `//` or `*`; confirmed again by a literal-string grep for the key value, 0 hits outside `WmsConstants`). Most appear only in the commented-out seeding block of `UtilRestController`. A row for any of them is inert — editing it in the System Properties screen changes no server behaviour (the UI may still read them generically by `groupname`, which this pass did not check):

`CUPS_SERVER_ADDRESS_USERNAME`, `CUPS_SERVER_ADDRESS_PASSWORD`, `PRINTING_ZPL_OUTBOUND_PALLET_LABEL`, `WMS_INSTANCE_NAME`, `MOBILE_UI_REDIRECT_URL`, `WEB_UI_REDIRECT_URL`, the 8 `KEYCLOAK_*` keys (§9), `WMS_LOGIN_SECRET`, `OLD_CRON_JOB_ACTIVATED`, `CSV_FILE_SEPARATOR`, `STRING_PATTERN_SEPARATE_STOCK`, `EXPORT_LIMIT`, `EXPORT_DATE_FORMAT`, `DB_VERSION`.

### Magic-string consumers (keys not declared as constants)

Call sites that accept a sysprop key as a method parameter or declare it outside `WmsConstants` (re-enumerated 2026-11-11 by listing every `.getSysvalue(` / `.getIntValue(` / `.getStringDefault(` whose first argument is not a `*_KEY` / `WmsConstants.` reference: 213 non-comment call sites outside `SyspropService.java`, 11 with a non-constant first argument, all listed below; only `PrinterController` passes a request value):

| File:Line | Context |
|---|---|
| `controller/PrinterController.java:266` | `syspropService.getSysvalue(labelKey)` where `labelKey` is the `@PathVariable` of `GET /printLabel/{labelKey}` (`:260-261`) — **caller-controlled, any syskey**. Fixed: prints only rows whose `groupname` is `Labels`; unknown and non-Labels keys get one identical refusal ✓ merged(SBDEV-4123: #671 1f3ca03a, 2026-11-12) Since SBDEV-4134 it answers an error instead of "PRINTER LABEL SENT" when `PRINT_CASE_LABEL` is off, or when CUPS refuses the job (`cupsPrintChecked`); `POST /testPrinter`, `POST /unitload/reprintLabel` and the Order Monitor tote-label reprint (`POST …/reprintLabels`) do the same. A refused job's CUPS diagnostics go to the log, not to the `printLabel` caller ✓ merged(SBDEV-4134: #676 9f041590 + oms #993 51a9bab2, 2026-11-13) |
| `controller/rest/UtilRestController.java:992` | `syspropService.getSysvalue(key)` inside `createSystemPropertyIfNotExists(String key, String value)` (`:990-992`), a private helper of the seeding code — **dead code**: `grep -rn createSystemPropertyIfNotExists src/main/java` finds only the declaration, so the old description ("API param, admin sysprop-read endpoint") no longer holds |
| `security/SdrGuardModeProvider.java:37,67` | key **declared as a literal outside `WmsConstants`**: `public static final String SYSKEY = "WMS2_SDR_READ_GUARD_MODE"`, read via `getSysvalue(SYSKEY)` |
| `ReplenishOrderJob.java:909`, `FixLocationAssignmentService.java:766`, `WarehouseStockReportService.java:173,181`, `ManualEntryOverrideLimits.java:64`, `ViewDtoService.java:991`, `LabelPrintingService.java:827,1005`, `BillofladingService.java:1141` | private helpers taking a `key`/`syskey`/`urlKey` parameter; every caller inspected passes a `WmsConstants` constant (`grep -rnE '(parseSyspropLong|syspropLongAsDecimal|parseLongSysprop|parseBooleanSysprop|requireTemplate|clientSpecific)\("[A-Z]'` = 0 hits; callers not individually traced for `ViewDtoService`/`LabelPrintingService`) |

The `PrinterController` case is the live exposure: the key comes straight from the URL, so it is not backed by any constant — see the open item in the 2026-11-11 verification-log entry (§14).

---

## 13. How to use this doc

| Task | Start at |
|---|---|
| Provision a fresh client DB's per-client sysprops | Run **`db/configure-client-sysprops.sh`** (SBDEV-2607) — rewrites the base-dump `CHANGE-ME-FOR-NEW-CLIENT` placeholders (`MOBILE_UI_URL`, `MULTIWAREHOUSE_IDENTIFIER`, `WAREHOUSE_NAME`, `OMS_TENANT_ID`, `System Time Zone`, `SYSTEM_OMS_NAME`, `SYSTEM_WMS_NAME`, `WEBS%`) in one verified pass. See `[[wms2-greenfield-db-provisioning]]` §5. |
| Enable a cron job in a new tenant | §3 + §4 (set both the master + per-job `_ACTIVATED` flag + the `_TIMER_HOUR` and `_TIMER_MINUTE` rows — an absent timer row means the job is not scheduled; §1a) |
| Configure OMS callbacks | §5 — every `WEBSERVICE_*` must be overridden away from the placeholder (`CHANGE-ME-FOR-NEW-CLIENT/` in the `V2.2.00` base-dump seed; `configure-client-sysprops.sh --oms-api-base-url` sets them all at once) |
| Bring up a new Keycloak realm | **Not a sysprop task** — per-tenant issuer/realm config is the landlord `tenant_auth_configuration` row (§9); the 8 `KEYCLOAK_*` sysprops have no live reader |
| Tune replenish behavior | §6 |
| Change label print behavior | §7; identity labels (tote / location / flowbin / overstock / unit-load) §7.1 |
| Know what a Flyway-seeded flag actually switches | §11.2 |
| Check what a tenant currently holds for the seeded keys | §11.3 (point-in-time, 2026-09-10 — not re-read 2026-11-11) |
| Change a key's shipped default | §11.5 — **read (a) and (b) first**; editing an applied migration silently freezes a tenant's whole chain, and a new migration's default is a no-op on existing rows |
| Pick the next `V2.2.x` version number | §11.1 — sweep **all remote branches**; `origin/develop` head is `V2.2.50` as of 2026-11-11 (`V2.2.11` merged out of order in August) |
| Audit for unknown sysprop rows | Query `SELECT key FROM los_sysprop EXCEPT` the union of keys in this doc — anything left is either magic-string debt (§12) or stale |
| Update a sysprop but change isn't visible | Remember the `@Cacheable`: restart the service or wait for cache TTL (§2) |

---

## 14. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-11-11 | **Full-surface re-verification against `wms2-api` `origin/develop` @ `df30fa62`** (detached worktree; the working checkout was not read). Re-enumerated every key constant (`grep -cE 'String SYSTEM_PROPERTY_[A-Z0-9_]*_KEY'` = 147; `grep -cE 'String [A-Z0-9_]+_KEY\s*='` = 152 incl. 5 un-prefixed; + `AREA_DEFAULT`, `SdrGuardModeProvider.SYSKEY`), every non-comment read site (213 `getSysvalue/getIntValue/getStringDefault` sites outside `SyspropService.java`; 10 `getIntValue`, 1 live `getStringDefault`, 0 `getByKey`, 1 `setSysvalue`), every companion default constant's live references, `application.properties` `app.*`, and all 24 `los_sysprop`-writing migrations V2.2.04-V2.2.48. **Corrections:** (1) the `Default` column is not a runtime fallback for 81 of 104 default constants — new §1a; (2) `NEW_CRON_JOB_ACTIVATED` absent = OFF, and 7 not 5 jobs gate on it; `OLD_CRON_JOB_ACTIVATED` is dead; (3) timer rows absent = job not scheduled; (4) `getStringDefault` DOES insert a row; cache key is `tenant:facility:key`; (5) 8 `KEYCLOAK_*` + 14 other constants have no live reader — §9 rewritten (auth is landlord `tenant_auth_configuration`); (6) `PRINT_CASE_LABEL` absent = printing OFF, `PRINTING_TOTE_LABEL_DETAILS` default is a comparison value; (7) outbox dispatcher now `*/3`, batch 25, SENT retention moved to `RestIdempotencyCleanupJob`; metric flag seeded by V2.2.06 not V2.2.05; (8) stale "NOT merged / in flight" labels removed (V2.2.27/36/42/47 on develop); (9) file:line anchors re-pointed. **Added:** `EMPTY_PALLET_CLEANUP_*` x3 (§4.6c, V2.2.41), `WMS_CLUBLINE_OMS_CHUNK_SIZE` (V2.2.29), `TRANSFER_DESTINATION_CONSTRAINT_ENFORCED`, `WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED`, `FIX_LOCATION_PAGE_SIZE`, the UPDATE_PRIORITY / UPDATE_PICKING_DATE rows in §5, §4.8 (property-driven jobs), the `SdrGuardModeProvider.SYSKEY` magic string. **Not done:** live DB state (§7.1a, §11.3) not re-read; §6 call-graph narratives not re-traced (marked inline). **Open item for a human:** `GET /printLabel/{labelKey}` (`PrinterController.java:260-266`) reads an arbitrary syskey from the URL (§12). | 116 targeted edits; 21 no-reader keys listed (§12) — independent review corrected 22→21 (`ORDER_MONITOR_CALCULATE_OLDER_THAN_DAYS` is read in native SQL) and the `PICKING_BOX_PER_CART` absent-row claim | Claude (executor), 2026-11-11 verification pass |
| 2026-11-05 | SBDEV-4007: added `WMS_CLUBLINE_ASYNC` to §11.1 and §11.2, marked ✓ merged(SBDEV-4007: wms2-api #622 57147d50 + wms2-web-ui #197 9d9d3845, 2026-11-06). Read `V2.2.47__club_run_job.sql`, `ClubRunJobService.isAsyncEnabled`, `ClubLineController.runClubLine` on `feature/SBDEV-4007-club-run-async` @ `d70beaaf`. **Scope of this catalog is `los_sysprop` keys only**, so the `app.clubline.job.*` / `app.cron.club-run-job` Spring properties are NOT listed here; see the workflow doc §8A.8. Counts not changed; `last_verified` NOT bumped. | §11.1 +1 row, §11.2 +1 row | SBDEV-4007 docs lane |
| 2026-04-19 | `WmsConstants.java:879-1069` constants, `SyspropService.java` method signatures + caching annotation, fallback chain, magic-string consumers, "missing default" set | All keys + defaults + consumer shape confirmed | Code read (grep-based) |
| 2026-07-10 | Added `ENFORCE_PARTITIONALLOWED` (SBDEV-2512 overstock-release guard kill-switch, default ON) to §10 Picking — Order-release behavioral guards; total ~75→~76. | New key documented | SBDEV-2512 v2 port |
| 2026-07-19 | Documented `db/configure-client-sysprops.sh` (SBDEV-2607) as the greenfield per-client sysprop seeding tool; noted the `V2.2.00` base-dump placeholder is `CHANGE-ME-FOR-NEW-CLIENT`. No new keys. | Onboarding tooling documented | SBDEV-2607 |
| 2026-07-24 | Added `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` (SBDEV-1762) as new §10 Transfer-orders subsection; added Flyway **V2.2.04** seed provenance (PR #93, default OFF) to it and the existing `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` (SBDEV-1666) §6 entry. Feature constants land via open PRs #91/#92. Total ~76→~77. | New key + seed provenance documented | V2.2.04 seed work |

| 2026-07-30 | **Full extraction + live census.** Counted every constant programmatically (123 `SYSTEM_PROPERTY_*_KEY` + nested `AREA_DEFAULT` = 124) and read `los_sysprop` on all 5 active DEV+UAT tenants. Corrected the bogus "~77" total in §1. Added 9 previously-undocumented keys: `API_TIMESTAMP_FORMAT`, `AREA_DEFAULT`, `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED`, the 3 `STALE_CLUB_BATCH_CLEANUP_*` (new §4.6b), `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` + `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` (§4.7), `STOCK_SUMMARY_EXPORT_MAX_ROWS` + `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED` (§4.4). | Catalog coverage 115/124 → **124/124**. Census found 146 live keys, 32 without constants (20 UI-managed, 4 orphans, 7 DEV junk, 1 seeded-ahead-of-code) | Nam Park — [`260730-wms2-sysprop-current-value-census`](../reports/260730-wms2-sysprop-current-value-census.md) |

| 2026-08-10 | Added `DEFAULT_PUTAWAY_LOCATION` (SBDEV-2732 tier 3 of the putaway destination hierarchy) as a new §10 Receiving subsection, with its read path (`findBySyskeyAndClientIdAndWorkstation`, NOT `getSysvalue` — landmines A3/A4), its blank-means-unconfigured semantics, the three `SystemPropertyController` rejections + the SDR handler guard, and D12's delete-and-recreate behaviour. Seeded blank by Flyway `V2.2.13`. Constant count 124 → 125. | **APPLIED — status corrected 2026-08-25.** wms2-api PR #139 merged 2026-08-11; `V2.2.13` recorded success on `dev_wh01_om1` at 2026-08-11 13:50 UTC and the key exists there seeded **blank** (client_id 0 / workstation `DEFAULT`), i.e. tier 3 unconfigured. Per-tenant application beyond wineco-dev NOT swept. | Nam Park — SBDEV-2732 Phase 1-API |

| 2026-08-13 | **Post-`V2.2.00` Flyway seed audit + live re-read.** Extracted all 132 `SYSTEM_PROPERTY_*_KEY` constants from **`origin/develop`** (not a working tree) and diffed against this catalog: **8 undocumented keys** found and added — 5 × `PRINTING_ZPL_*` identity templates (new §7.1), `PRINTING_MAXIMUM_AMOUNT_LABEL_BATCH`, `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` (§6), `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` (§10). New **§11** documents every post-base-schema sysprop seed, what each flag switches, per-tenant live state across 5 DEV+UAT DBs, and default-change semantics. **Corrected §2's auto-creation claim** — `getSysvalue` is a pure read, contradicting both this doc and 5 migration comments. Found: `V2.2.11` is an unmerged-branch hole; `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` has 0 consumers; dev `wh01_hydra_v2` has no `flyway_schema_history` and 0/12 seeded keys; the two wineco environments are inverse configurations. Constant count 125 → **133**. | Catalog coverage **133/133**; 4 UAT + 1 DEV tenant all at Flyway head `2.2.16`, 0 failed | Nam Park — live MCP reads + `origin/develop` grep |

| 2026-08-14 | **Label-printing rollout prerequisites** (new §7.1a). Traced `resolveTotePattern`'s three-step order and confirmed `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` is the **last** resort, not the first — both wineco DBs' `DEFAULT-%1$06d` is inert because step 2 derives `T-%1$04d` from the scan pattern. Read `PRINT_CASE_LABEL`, `STRING_PATTERN_PICKING_TOTE`, the printer table and `los_sequencenumber` on all 5 tenants. **Found: `wh01_shipitez_v2` has no `OUTBOUND_TOTE` printer** (hard blocker); all 5 capped at **10,000** tote IDs by 4-digit scan patterns; no tenant has a `PICKING_TOTE_DEFAULT` sequence row, so the first generated tote is `X-0000` (`SequenceTransactionService` creates at 0 and returns 0). | 4 of 5 tenants ready; 1 blocked on a missing printer row | Nam Park — live MCP reads + `origin/develop` |

| 2026-09-10 | **§11 re-verification + live read of all 6 v2 tenant DBs (first PRD read).** Diffed `origin/develop`'s post-`V2.2.00` seeds against §11: **6 undocumented keys** found and added — `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` (V2.2.17, SBDEV-2994 shadow mode), `WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY` + `_ACTIVATED` (V2.2.22, SBDEV-2573), `WMS2_SDR_READ_GUARD_MODE` (V2.2.23, SBDEV-3169), `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE` + `_ACTIVATED` (V2.2.24, SBDEV-3273). §11.1 recount 13 → **19 keys across 14 of 25 post-base migrations**. §11.2 gained a row per new flag; §11.3 rewritten. Found: **PRD is 2 migrations behind `main`** and lacks all 5 of the V2.2.22–24 keys, so both OMS notification features are absent there rather than off; the SDR-guard uncached-miss cost cannot reach PRD because code and row ship on the same boot; `ADJUSTMENT_ALERT_POLL_ACTIVATED` is now seeded everywhere and `true` on DEV; the three replenishment/transfer toggles differ in **every** environment. | §11 coverage **19/19**; 6/6 DBs 0 failed at heads 2.2.21 (PRD) / 2.2.23 / 2.2.24 ×3 / 2.2.25 (DEV) | Nam Park — direct `psql` reads (MCP servers unreachable) + `origin/develop` grep |

| 2026-09-10 | **`WMS_CLUBLINE_MAX_BATCH_SIZE` added to §11.1/§11.2 (SBDEV-3304, V2.2.27, PR #343 — NOT merged).** Listed but **excluded from the 19-key count and §11.3's `/19` denominator**, because that count is scoped to `origin/develop`; fold it in on merge. Live state at the time of writing, measured with a positive control on `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` in each DB: present on **c1wh-shipitez-uat only** (`5000`, `workstation='DEFAULT'`, `client_id=0`, group `Operation Options`) and **created by hand through System Settings**, not by the seed — the incident that produced SBDEV-3304. Absent on `nywh-shipitez-uat`, `nywh-hydra-uat`, `wsl-wineco-uat`. The seed is idempotent and non-destructive (`WHERE NOT EXISTS` on `syskey` **and** `workstation='DEFAULT'`), so c1wh keeps its operator-set value. Note for §12: this key has a `*_DEFAULT_VALUE` constant AND the code default reads it, so the two cannot drift — `ClublineMaxBatchSizeSeedConsistencyTest` pins the constant to the migration literal. | §11 coverage 19/19 merged + 1 in flight | Claude (SBDEV-3304), on Nam's request |

| 2026-10-05 | `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` marked **RETIRED** (§6 row + §11.2) — SBDEV-3654 removes every read; lanes are excluded unconditionally. Verified by `git grep` on the worktree branch (0 reads) and `ReplenishLaneExclusionUnconditionalArchTest`. | Row rewritten; §11.1 seed provenance unchanged (the row is still seeded) | Claude (executor), SBDEV-3654 |

| 2026-10-06 | `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` §6 row: the un-gated query list now says which six of the seven survive. SBDEV-3658 deleted the unpaged `ItemdataRepository.getIdsForItemDataWithoutFixedAssignment` (no caller in `src/main`; its text duplicated the `…Page` variant's verbatim). Corrected the row's "PR pending" — SBDEV-3654 merged as `df8dff6d`. | §6 row updated; §11.1/§11.2 unchanged | Claude, SBDEV-3658 |

| 2026-10-16 | `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED`: **deletion** decided for SBDEV-3659 (Nam, option 3). `V2.2.39` deletes the row, and the constant is deleted (branch `bugfix/SBDEV-3659-delete-retired-lane-exclusion-sysprop`). The §6 row and §11.1 now say so, both marked ✓ merged(SBDEV-3659: #523 ee3747f2, 2026-10-16). §11.2 is unchanged and still correct: nothing reads the key. | §6 + §11.1 updated | Claude, SBDEV-3659 |
| 2026-10-16 | `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` (V2.2.40, SBDEV-3672, **not merged**) added to §10 Shipping, §11.1 and §11.2; `app.outbox.dispatcher.bol-shipped-max-attempts=29` added to §4.7. Read at wms2-api `1866ab66`: `WmsConstants.java:1407-1408`, `BolShippedNotificationChunker.java:38,46,58`, `BillofladingService.java:844`, migration `V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql`, `application.properties:249`. Excluded from the §11 counts like V2.2.27. No live DB read: the key is not deployed anywhere yet. | New rows marked ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | SBDEV-3672 docs lane |
| 2026-10-28 | `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` / V2.2.40: SBDEV-3672 merged 2026-10-22 (wms2-api#526 `f85789d4`) and on PRD v0.0.43; "NOT merged / in flight" labels removed. Row confirmed seeded `40` on WineCo and c1wh PRD (created 2026-10-27 11:53 UTC). The §11 counts were not re-derived. |

**Re-verify every 90 days.** Last full pass 2026-11-11. Next due: **2027-02-09** — sysprop surface grows slowly; major additions (typically 2-3 keys per quarter) should be spot-checked against this catalog.
