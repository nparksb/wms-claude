---
title: "WMS v2 — los_sysprop Current-Value Census (DEV + UAT)"
type: investigation
status: concluded
version: v2
scope: "v2/wms2-api — los_sysprop keys, code defaults, and live per-tenant values across 5 active tenant DBs"
owner: "Nam Park"
created: 2026-07-30
updated: 2026-07-30
last_verified: 2026-07-30
verified_by: "Nam Park — live psql against DEV (dev_landlord tenants) + UAT (landlord tenants)"
related:
  - "[[wms2-sysprop-catalog]]"
  - "[[wms2-landlord-vs-tenant-entity-map]]"
  - "[[wms2-greenfield-db-provisioning]]"
tags:
  - investigation
  - report
  - sysprop
  - configuration
  - wms2
  - data-dictionary
---

# WMS v2 — `los_sysprop` Current-Value Census (DEV + UAT)

**Topic:** every `los_sysprop` key, its code default, and its live value in each active tenant | **Version:** v2/wms2-api
**Captured:** 2026-07-30 | **Tenants:** 5 active (1 DEV, 4 UAT) | **Distinct keys observed:** 146

> **This is a point-in-time snapshot, not a reference.** Sysprop values are per-tenant and operator-editable
> through the Admin UI at any moment. The durable "what does this key mean and what is its default" reference
> is [`wms2-sysprop-catalog.md`](../data-dictionary/wms2-sysprop-catalog.md); this report exists to record what
> the fleet actually held on the capture date and to surface drift. Re-run rather than trust an old copy.

---

## 1. Scope & Method

| | |
|---|---|
| Tenant discovery | `tenant_db_configuration WHERE active` — DEV landlord `dev_landlord@25060`, UAT landlord `landlord@25062` |
| Tenants read | DEV `dev_wh01_om1` (wsl) · UAT `wh01_om1_v2` (wsl), `wh01_shipitez_v2` (c1wh), `wh01_hydra_v2` (nywh), `wh02_shipitez_v2` (nywh) |
| Query | `SELECT syskey, sysvalue, workstation, client_id, groupname FROM los_sysprop` — read-only, 679 rows total |
| Code side | `WmsConstants.java` — 123 `SYSTEM_PROPERTY_*_KEY` constants + 1 nested `LocationAreaService.PROPERTY_KEY_AREA_DEFAULT` = **124** |
| Inactive DBs | Excluded. The three DEV hydra scratch copies are abandoned and would report stale config. |

**Reading caveats.**

1. **One row per key per tenant.** No `workstation` / `client_id` variants exist anywhere in the fleet — every row is `DEFAULT` / `0`. Consumers that accept a workstation parameter are therefore all resolving to the same row today.
2. **A value here is not necessarily what a running process sees.** `SyspropService` applies `@Cacheable(value = "sysprops", key = "{facilityCode}:{key}")` to both `getSysvalue` and `getByKey`, so an edited row is invisible until the cache expires or the service restarts.
3. **A missing row is not "unset".** The fallback chain is tenant row → `*_DEFAULT_VALUE` constant → null. A key absent from a tenant is running on its code default, which for 43 of the 124 constants does not exist.
4. **Secrets are redacted.** Two keys hold live credentials in plaintext (§2.8); their values are deliberately not reproduced here.

---

## 2. Findings

### 2.1 Coverage: 124 code constants, 146 live keys, 114 in both

| Set | Count |
|---|---|
| Keys defined as Java constants | 124 |
| Distinct keys present in ≥1 tenant DB | 146 |
| Both | 114 |
| **Code constant, no row in *any* tenant** | **10** — running on code default |
| **DB row, no Java constant** | **32** — see §2.2–2.5 |

### 2.2 Twenty keys are UI-managed config, not backend constants — expected, not debt

The web UI does not look these up by name. `store/admin/configuration.js` and `store/admin/management.js` fetch **`GET /sysprop/search/findByGroupname?groupname=…`** and render whatever comes back, so the Admin → *Parameters & Configuration* screen is driven entirely by the `groupname` column. Any row with a recognised group is editable in the UI whether or not Java knows about it.

That accounts for all of `Warehouse Details` (`Address Line 1/2`, `City / Town`, `County`, `State / Province`, `Zip`, `Warehouse Phone #`, `Contact Line`, `Allow XLSX Export Option`), `Operation Options` (`Accept CC w/o Approval`, `Allow Manual Cycle Count`, `Print Parcel Pick Labels`, `Require Recount if Different`, `PICK_SCREEN_CONFIRMATION`), `System Settings` (`Auto Replenish to Max`, `Smart Stock Synch`, `Synch Stock Every`) and `System Info` (`Build Date`, `Connected DB`, `Status`).

**Verdict: working as designed.** These belong in the catalog as a documented category, but they are not missing constants.

### 2.3 Four keys are invisible from both directions

| Key | Java refs | Web/mobile UI refs | `groupname` |
|---|---|---|---|
| `QUICKSEARCH_FIELD_CONFIG_BOXTYPE` | 0 | 0 | `NULL` |
| `QUICKSEARCH_FIELD_CONFIG_CUSTOMERORDER` | 0 | 0 | `NULL` |
| `STOCK_SUMMARY_EXPORT_SUPPRESS_ARCHIVED` | 0 | 0 | `NULL` |
| `UI_EMPTY_ON_LOAD` | 0 | 0 | `NULL` |

A `NULL` groupname means `findByGroupname` never returns them, so they do **not** appear on the Admin screen either. Nothing in `wms2-api`, `wms2-web-ui`, or `wms2-mobile-ui` references them by literal. They are editable only by direct SQL or by id through the REST resource.

Two of them look like they should matter — `STOCK_SUMMARY_EXPORT_SUPPRESS_ARCHIVED` sits beside real export tuning keys, and setting it today would have no effect on anything.

**Verdict: probable orphans.** Confirm intent before deleting — a consumer could exist outside these three repos.

### 2.4 `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` — DEV only, and deliberately constant-less

Present on `dev_wh01_om1` and nowhere else, with no Java constant. Both facts are expected and were designed that way:

- Seeded by Flyway **`V2.2.05`** (SBDEV-2736 PR #107, merged into `develop` 2026-07-30). DEV was migrated to `2.2.05` on 2026-07-29; the four UAT tenants are still at `2.2.04`, which is why they have no row.
- The Java constant was **deliberately deferred to Phase 2** — an unread constant cannot be type-checked against the migration literal, so it was left out until something reads it.

**Verdict: correct.** It will appear on UAT when `V2.2.05` reaches `release`. Do not flip it to `true` — Phase 2 enforcement is not built.

### 2.5 Seven junk rows, all confined to DEV

| Key | Origin |
|---|---|
| `cy_probe_1783506211135`, `cy_probe_1783506498107` | `wms2-web-ui/cypress/e2e/wms/admin/admin.cy.js:243` — `key: 'cy_probe_' + Date.now()`, the gated "2.V.1 Create sysprop" write test. It creates a real row and does not always clean up. |
| `test`, `test2`, `test3` | Manual rows — one per group (`Patterns`, `Operation Options`, `System Settings`) |
| `OPTION-ARDEN`, `PATTERN-ARDEN` | Manual rows, same pattern |

**Verdict: harmless but worth clearing.** No UAT tenant carries any of them, so the Cypress admin write suite has only ever been pointed at DEV. Worth noting the test creates unbounded rows keyed on `Date.now()` — every gated run adds one more.

### 2.6 Ten constants have no row anywhere — the fleet runs on code defaults

`CLEAN_UP_OLD_MESSAGES_BATCH_SIZE`, `CLEAN_UP_OLD_MESSAGES_BATCH_SLEEP_MS`, `ENFORCE_PARTITIONALLOWED`, `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`, `PRINTING_PATTERN_CLIENT_SPECIFIC_TOTE_LABEL`, `PRINTING_SEQUENCE_NAME_CLIENT_SPECIFIC_TOTE_LABEL`, `REPLENISHMENT_CANCEL_THRESHOLD_FRACTION`, `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS`, `STOCK_SUMMARY_EXPORT_MAX_ROWS`, `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED`.

Two carry no `*_DEFAULT_VALUE` constant either (`ENFORCE_PARTITIONALLOWED`, `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`), so their consumers fall through to `Boolean.parseBoolean(null)` → `false`. Per §2 of the catalog, the first read of any of these **writes a row with a null value** — so this list is also "keys nothing has ever read on these tenants."

> **Superseded for one key, same day.** `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` was seeded on
> `dev_wh01_om1` on 2026-07-30 by an amendment to `V2.2.05` (`groupname = 'Operation Options'`, value
> `false` — the default is unchanged, the row just makes the toggle visible on the Admin screen).
> Nine remain. UAT will receive it with `V2.2.05`. See §8.

### 2.7 No unconfigured placeholders remain

Zero rows across all five tenants still contain `CHANGE-ME-FOR-NEW-CLIENT` or `oms-XXXXX.siteboss.net`. Every `WEBSERVICE_*` URL, `MOBILE_UI_URL`, and `WAREHOUSE_NAME` has been configured away from the `V2.2.00` base-dump seed. `configure-client-sysprops.sh` (SBDEV-2607) has been run everywhere it needed to be.

Also: **zero NULL-valued rows fleet-wide.** The auto-creation side effect described in the catalog has not left artifacts on any active tenant.

### 2.8 Two keys hold plaintext credentials

`CUPS_SERVER_ADDRESS_PASSWORD` and `WMS_LOGIN_SECRET` are non-null on all five tenants and stored in cleartext. **Their values are redacted in the tables below.**

`CUPS_SERVER_ADDRESS_PASSWORD` additionally ships a **hardcoded credential as its `*_DEFAULT_VALUE` constant** at `WmsConstants.java:955`, so the value is in the git history of every clone regardless of DB access. Any tenant that has never overridden the key is using it.

This is consistent with existing practice rather than a new exposure — `tenant_db_configuration.db_password` in the landlord is plaintext too, and the Flyway runbook already treats that table as a secret store. Flagging it so the same handling is applied here: anyone with tenant-DB read access has these, and they are reachable through the Spring Data REST `/sysprop` resource.

### 2.9 UAT `wsl` has 13 keys parked on the literal `VERSION-1.0-ONLY`

`wh01_om1_v2` (UAT wsl, the WineCo tenant) holds the placeholder string `VERSION-1.0-ONLY` as the **value** of 13 keys — including **all eight Keycloak keys**, which the catalog documents as mandatory with no defaults:

`KEYCLOAK_API_USER`, `KEYCLOAK_APP_GROUP_NAME`, `KEYCLOAK_CLIENT`, `KEYCLOAK_LOGOUT_URL`, `KEYCLOAK_OMS_USER_GROUP`, `KEYCLOAK_OMS_USER_PREFERRED_SCHEMA`, `KEYCLOAK_REALM`, `KEYCLOAK_SERVER_URL`, `MOBILE_UI_REDIRECT_URL`, `WEB_UI_REDIRECT_URL`, `WMS_INSTANCE_NAME`, `WMS_LOGIN_SECRET`, `OLD_CRON_JOB_ACTIVATED`.

No other tenant does this — the other four carry real Keycloak realms, clients, and redirect URLs.

**Verdict: consistent with an incomplete migration, not necessarily a defect.** The WineCo `wsl` UAT v1→v2 migration completed Phases C and F on 2026-07-20 with the human steps G–K still outstanding; Keycloak realm setup is plausibly among them. `OLD_CRON_JOB_ACTIVATED` being a non-boolean string is the one that would misbehave if read — it is parsed as a flag elsewhere. **Confirm against the migration checklist before treating this as a bug**, but do not expect this tenant to authenticate against v2 Keycloak in its current state.

### 2.10 The catalog's self-reported key count is wrong

[`wms2-sysprop-catalog.md`](../data-dictionary/wms2-sysprop-catalog.md) §1 states *"Total keys documented: ~77 (WmsConstants.java lines 879–1069)."* It actually documents **115 of the 124** constants. The `~77` figure was already wrong when written — the file held 108 `SYSTEM_PROPERTY_*_KEY` constants on 2026-04-19, the catalog's own baseline date. Growth since then has been modest and matches the doc's "2-3 keys per quarter" estimate (108 → 123 over three months).

Nine constants are genuinely absent from the catalog: `API_TIMESTAMP_FORMAT`, `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED`, `STALE_CLUB_BATCH_CLEANUP_ACTIVATED`, `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR`, `STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE`, `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`, `STOCK_SUMMARY_EXPORT_MAX_ROWS`, `STOCK_SUMMARY_EXPORT_STREAMING_ENABLED`, and the nested `AREA_DEFAULT`.

---

## 3. Recommendations

| # | Action | Priority |
|---|---|---|
| 1 | Correct the catalog's `~77` count and add the 9 missing keys (**done 2026-07-30** — see catalog §13) | done |
| 2 | Decide the fate of the four §2.3 orphans; delete or give them a `groupname` and a constant | medium |
| 3 | Clear the 7 DEV junk rows, and make the Cypress `2.V.1` write test clean up its `cy_probe_*` row | low |
| 4 | Treat `los_sysprop` as secret-bearing (§2.8) in any export, backup-sharing, or support-bundle process | medium |
| 5 | Re-run this census after the next `V2.2.x` reaches UAT, or before any tenant-config audit | as needed |

---

## 4. Census — keys uniform across all five tenants (67)

Same value everywhere. A divergence appearing here later is a signal worth investigating.

| Key | Group | Code default | Value (all 5 tenants) |
|---|---|---|---|
| `API_TIMESTAMP_FORMAT` | Backend | *(no default const)* | `ISO8601_UTC` |
| `AREA_DEFAULT` | System Settings | *(no default const)* | `Default` |
| `Accept CC w/o Approval` | Operation Options | *(no constant)* | `TRUE` |
| `Allow Manual Cycle Count` | Operation Options | *(no constant)* | `TRUE` |
| `Allow XLSX Export Option` | Warehouse Details | *(no constant)* | `TRUE` |
| `Auto Replenish to Max` | System Settings | *(no constant)* | `FALSE` |
| `Build Date` | System Info | *(no constant)* | `44219` |
| `CLEAN_UP_OLD_MESSAGES_ACTIVATED` | System Settings | `false` | `false` |
| `CLEAN_UP_OLD_MESSAGES_PERIOD` | System Settings | `365` | `365` |
| `CLEAN_UP_OLD_MESSAGES_TIMER_HOUR` | System Settings | `2` | `2` |
| `CLEAN_UP_OLD_MESSAGES_TIMER_MINUTE` | System Settings | `55` | `55` |
| `CSV_FILE_SEPARATOR` | Warehouse Details | `,` | `,` |
| `CUPS_SERVER_ADDRESS_IP` | System Settings | `cups-01.advancedinfomanagement.com` | `oms.siteboss.net` |
| `CUPS_SERVER_ADDRESS_PASSWORD` | System Settings | 🔒 *redacted* | 🔒 *redacted* |
| `CUPS_SERVER_ADDRESS_PORT` | System Settings | `631` | `631` |
| `CUPS_SERVER_ADDRESS_USERNAME` | System Settings | `aimprint` | `cupsadmin` |
| `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT` | Operation Options | `true` | `true` |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` | Operation Options | `0` | `0` |
| `Connected DB` | System Info | *(no constant)* | `PostgreSQL 13.3` |
| `County` | Warehouse Details | *(no constant)* | `US` |
| `DEFAULT_BOX_TYPE` | System Settings | *(no default const)* | `COLLTRL` |
| `EXPORT_DATE_FORMAT` | Warehouse Details | `yyyy-MM-dd HH:mm:ss.SSS` | `YYYY-MM-dd HH:mm:ss.SSS` |
| `EXPORT_LIMIT` | Warehouse Details | `10000` | `10000` |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND` | System Settings | *(no default const)* | `36` |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND` | System Settings | *(no default const)* | `60` |
| `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` | System Settings | *(no default const)* | `84` |
| `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` | System Settings | *(no default const)* | `false` |
| `INBOUND_UPDATE_STOCK_IMMEDIATELY` | Operation Options | *(no default const)* | `true` |
| `MERGE_PICKING_ORDERS` | Operation Options | *(no default const)* | `true` |
| `NEW_CRON_JOB_ACTIVATED` | System Settings | `true` | `true` |
| `OMS_API_USER` | Backend | *(no default const)* | `api_user/apiUser@sb` |
| `ORDER_MONITOR_CALCULATE_OLDER_THAN_DAYS` | Operation Options | `10` | `10` |
| `ORDER_TIMER_ACTIVATED` | Operation Options | `true` | `true` |
| `ORDER_TIMER_HOUR` | Operation Options | `*` | `*` |
| `ORDER_TIMER_MINUTE` | Operation Options | `*` | `*` |
| `PICK_PATH_DIRECTION` | Operation Options | *(no default const)* | `VERTICAL` |
| `PICK_SCREEN_SIMPLE` | Operation Options | `false` | `false` |
| `PICK_TIME_OUT_MOBILE` | Operation Options | `30` | `30` |
| `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` | Operation Options | `40` | `40` |
| `PRINTING_SEQUENCE_NAME_DEFAULT_TOTE_LABEL` | Unknown | *(no default const)* | `PICKING_TOTE_DEFAULT` |
| `PRINTING_ZPL_CASE_LABEL` | Labels | *(no default const)* | `^XA^P0N^CI31^FX First section with receiving information.^LRY^FO50,75^A0N,75,75^TBN,800,75^FD{warehouse}^FS…` |
| `PRINTING_ZPL_OUTBOUND_PALLET_LABEL` | Labels | `add zpl code` | `^XA^FT615,200^A0R,70,65^FV{shipping_method}^FS^FX barcode^BY5,2,300^FO200,150^BCR^FD{u_load}^FS^FX Section …` |
| `PRINTING_ZPL_PICKING_TOTE_LABEL` | Labels | *(no default const)* | `^XA^P0N^CI31^FX Top section with order information.^LRY^FO675,0^GB1,750,140^FS^FO730,50^A0R,30,30^FDSHIPPER…` |
| `PRINT_CASE_LABEL` | System Settings | *(no default const)* | `true` |
| `Print Parcel Pick Labels` | Operation Options | *(no constant)* | `TRUE` |
| `REPLENISHMENT_ALLOW_ANY_UNIT_LOAD` | Operation Options | `true` | `true` |
| `REPLENISHMENT_SHOW_UNIT_LOAD` | Operation Options | `true` | `true` |
| `REPLENISHMENT_TIMER_ACTIVATED` | Operation Options | `true` | `true` |
| `REPLENISHMENT_TIMER_HOUR` | Operation Options | `*` | `*` |
| `REPLENISHMENT_TIMER_MINUTE` | Operation Options | `*` | `*` |
| `Require Recount if Different` | Operation Options | *(no constant)* | `TRUE` |
| `SEQUENCE_NAME_DEFAULT_OUTBOUND_PALLET_LABEL` | Unknown | `PALLET_OUTBOUND` | `PALLET_OUTBOUND` |
| `SHIPPING_METHOD_ACTIVATED` | Operation Options | `false` | `false` |
| `STALE_CLUB_BATCH_CLEANUP_ACTIVATED` | Backend | `false` | `false` |
| `STALE_CLUB_BATCH_CLEANUP_TIMER_HOUR` | Backend | `3` | `3` |
| `STALE_CLUB_BATCH_CLEANUP_TIMER_MINUTE` | Backend | `0` | `0` |
| `STOCK_SUMMARY_EXPORT_TIMER_ACTIVATED` | System Settings | `true` | `true` |
| `STOCK_SUMMARY_EXPORT_TIMER_MINUTE` | System Settings | `0` | `0` |
| `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_ACTIVATED` | System Settings | `true` | `true` |
| `STRING_PATTERN_INBOUND_PALLET` | Patterns | `CART-\\d{4}\|IN-\\d{6}` | `CART-\d{4}\|IN-\d{6}` |
| `STRING_PATTERN_SEPARATE_STOCK` | Patterns | `SU-\\d{6}` | `SU-\d{6}` |
| `Smart Stock Synch` | System Settings | *(no constant)* | `TRUE` |
| `Status` | System Info | *(no constant)* | `Good` |
| `Synch Stock Every` | System Settings | *(no constant)* | `48 Hours` |
| `WEBSERVICE_BEHAVIOUR` | Backend | `keep` | `send` |
| `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` | Backend | `false` | `false` |
| `ZPL_TOTE_LABEL_VERSION` | Unknown | *(no default const)* | `REGULAR` |
---

## 5. Census — keys that differ by tenant, or are absent from some (79)

`**—** *(no row)*` means the tenant falls back to the code default in the second column.
The four `PRINTING_ZPL_*` templates are 1–2 KB of raw ZPL and are truncated; read them from the DB when needed.

| Key | Code default | DEV wsl | UAT wsl | UAT c1wh | UAT nywh-hydra | UAT nywh-shipitez |
|---|---|---|---|---|---|---|
| `Address Line 1` | *(no constant)* | `1805 Oxford St SE` | `1805 Oxford St SE` | `1401 S. Cloverdale Blvd.` | `123 Generic Drive West` | `123 Generic Drive West` |
| `Address Line 2` | *(no constant)* | `Michelle Cervone` | `Michelle Cervone` | `<empty>` | `Unit 3-5` | `Unit 3-5` |
| `CRON_JOB_SHOW_LOG` | `false` | `true` | `false` | `false` | `false` | `false` |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` | `true` | `true` | `true` | `false` | `false` | `true` |
| `City / Town` | *(no constant)* | `Salem` | `Salem` | `Cloverdale` | `New York` | `Troy` |
| `Contact Line` | *(no constant)* | `WineCo - Salem` | `WineCo - Salem` | `Cloverdale - Warehouse` | `NY East - Warehouse` | `NY East - Warehouse` |
| `DB_VERSION` | *(no default const)* | `1.15.19` | `1.15.19` | `1.15.16` | `1.15.16` | `1.15.16` |
| `KEYCLOAK_API_USER` | *(no default const)* | `idm-admin/ckyx496vx000209mg60s8aef5` | `VERSION-1.0-ONLY` | `idm-admin/ckyx496vx000209mg60s8aef5` | `idm-admin/ckyx496vx000209mg60s8aef5` | `idm-admin/ckyx496vx000209mg60s8aef5` |
| `KEYCLOAK_APP_GROUP_NAME` | *(no default const)* | `app_wms` | `VERSION-1.0-ONLY` | `app_wms_wh04` | `app_wms_wh03` | `app_wms_wh05` |
| `KEYCLOAK_CLIENT` | *(no default const)* | `om1-api/pf983ouznp4dkGr9ycvtBQgNBxxPTNrs` | `VERSION-1.0-ONLY` | `om1-api/ZLchgUjI8TeShGwmlPVZLGZnaPcFQ5i8` | `om1-api/1Gjj` | `om1-api/ZLchgUjI8TeShGwmlPVZLGZnaPcFQ5i8` |
| `KEYCLOAK_LOGOUT_URL` | *(no default const)* | `https://kc.om1.komatik.co/auth/realms/komatik/protocol/openid-connect/logout?redirect_uri=` | `VERSION-1.0-ONLY` | `https://kc.om1.komatik.co/auth/realms/komatik/protocol/openid-connect/logout?redirect_uri=` | `https://kc.om1.komatik.co/auth/realms/komatik/protocol/openid-connect/logout?redirect_uri=` | `https://kc.om1.komatik.co/auth/realms/komatik/protocol/openid-connect/logout?redirect_uri=` |
| `KEYCLOAK_OMS_USER_GROUP` | *(no default const)* | `client_wineco` | `VERSION-1.0-ONLY` | `client_shipitez` | `client_hydra` | `client_shipitez` |
| `KEYCLOAK_OMS_USER_PREFERRED_SCHEMA` | *(no default const)* | `om1_wineco` | `VERSION-1.0-ONLY` | `om1_shipitez` | `om1_hydra` | `om1_shipitez` |
| `KEYCLOAK_REALM` | *(no default const)* | `komatik` | `VERSION-1.0-ONLY` | `komatik` | `komatik` | `komatik` |
| `KEYCLOAK_SERVER_URL` | *(no default const)* | `https://kc.om1.komatik.co/auth` | `VERSION-1.0-ONLY` | `https://kc.om1.komatik.co/auth` | `https://kc.om1.komatik.co/auth` | `https://kc.om1.komatik.co/auth` |
| `MAXIMUM_RECEIVING_DURING_INBOUND` | `100` | `100` | `100` | `1000` | `1000` | `1000` |
| `MOBILE_UI_REDIRECT_URL` | *(no default const)* | `https://wh01m.komatik.co/oauth2callback?logout=https://wh01m.komatik.co/los-mobile` | `VERSION-1.0-ONLY` | `https://wh04.komatik.co/oauth2callback?logout=https://wh04.komatik.co/los-mobile` | `https://wh03.komatik.co/oauth2callback?logout=https://wh03.komatik.co/los-mobile` | `https://wh05.komatik.co/oauth2callback?logout=https://wh05.komatik.co/los-mobile` |
| `MOBILE_UI_URL` | *(no default const)* | `https://wsl-wineco.wms.dev.sbo.li/mobile` | `https://wms.wineco.sbo.li/mobile` | `https://c1wh-shipitez.wms.uat.sbo.li/mobile` | `https://nywh-hydra.wms.uat.sbo.li/mobile` | `https://nywh-shipitez.wms.uat.sbo.li/mobile` |
| `MULTIWAREHOUSE_IDENTIFIER` | `add_identifier` | `WSL` | `WSL` | `C1WH` | `NYWH` | `NYWH` |
| `OLD_CRON_JOB_ACTIVATED` | `false` | `false` | `VERSION-1.0-ONLY` | `false` | `false` | `false` |
| `OMS_TENANT_ID` | *(no default const)* | `wineco` | `wineco` | `shipitez` | `hydra` | `shipitez` |
| `OPTION-ARDEN` | *(no constant)* | `OPTION-ARDEN1` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` | *(no constant)* | `false` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `PATTERN-ARDEN` | *(no constant)* | `PATTERN-ARDEN` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `PICKING_BOX_PER_CART` | `6` | `6` | `6` | `4` | `8` | `6` |
| `PICK_SCREEN_CONFIRMATION` | *(no constant)* | `true` | `true` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `PICK_TIME_OUT_SYSTEM_ACTIVATED` | `false` | `true` | `true` | `false` | `false` | `false` |
| `PRINTING_DEFAULT_AMOUNT_TOTE_LABEL` | *(no default const)* | `2` | `2` | `1` | `1` | `25` |
| `PRINTING_MAXIMUM_AMOUNT_TOTE_LABEL` | *(no default const)* | `10` | `10` | `1000` | `1000` | `1000` |
| `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` | *(no default const)* | `DEFAULT-%1$06d` | `DEFAULT-%1$06d` | `C1-%1$04d` | `P-%1$04d` | `P-%1$04d` |
| `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` | `OUT-%1$06d` | `PM-%1$06d` | `PM-%1$06d` | `AOUT-%1$06d` | `AOUT-%1$06d` | `AOUT-%1$06d` |
| `PRINTING_TOTE_LABEL_DETAILS` | *(no default const)* | **—** *(no row)* | **—** *(no row)* | `LOCATION` | `LOCATION` | `LOCATION` |
| `PRINTING_ZPL_PICKING_TOTE_LABEL_AUTOMATION` | *(no default const)* | `^XA^FX Top section with order information.^FT730,50^A0R,40,30^FVClient^FS^FT690,50^A0R,40,30^FVBrand^FS^FT6…` | `^XA^FX Top section with order information.^FT730,50^A0R,40,30^FVClient^FS^FT690,50^A0R,40,30^FVBrand^FS^FT6…` | `^XA^FX Top section with order information.^FT730,50^A0R,40,30^FVClient^FS^FT690,50^A0R,40,30^FVBrand^FS^FT6…` | `^XA^FX Top section with order information.^FT730,50^A0R,40,30^FVClient^FS^FT690,50^A0R,40,30^FVBrand^FS^FT6…` | `^XA^FX Top section with order information.^FT730,50^A0R,40,30^FVClient^FS^FT690,50^A0R,40,30^FVBrand^FS^FT6…` |
| `QUICKSEARCH_FIELD_CONFIG_BOXTYPE` | *(no constant)* | `number,name,externalId,comment` | `number,name,externalId,comment` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `QUICKSEARCH_FIELD_CONFIG_CUSTOMERORDER` | *(no constant)* | `number,clientOrderNumber,historyTote,parcelExternalNumber,client,clientName,externalNumber` | `number,clientOrderNumber,historyTote,parcelExternalNumber,client,clientName,externalNumber` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` | `0` | `1784036266691` | `1785411680566` | `1785411683730` | **—** *(no row)* | `1785411683401` |
| `REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED` | `false` | `true` | `false` | `false` | `false` | `false` |
| `REQUIRE_RECEIVING_TO_CONTAINER` | `TRUE` | `false` | `TRUE` | `TRUE` | **—** *(no row)* | `TRUE` |
| `SHOW_MANIFEST_LOCATION` | `false` | `true` | `true` | `false` | `false` | `false` |
| `STOCK_SUMMARY_EXPORT_SUPPRESS_ARCHIVED` | *(no constant)* | `false` | `false` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `STOCK_SUMMARY_EXPORT_TIMER_HOUR` | `3` | `17` | `17` | `18` | `3` | `3` |
| `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_AMOUNT_SKU_PER_BATCH` | `250` | `150` | `150` | `250` | `250` | `250` |
| `STRING_PATTERN_OUTBOUND_PALLET` | `OUT-\\d{6}` | `OUT-\d{6}\|TESTPALLET-\d{4}` | `OUT-\d{6}\|TESTPALLET-\d{4}` | `WC_\d{16}\|OUT-\d{6}\|OUT\d{6}\|OUT-\d{3}\|AOUT-%1$06d` | `WC_\d{16}\|OUT-\d{6}\|OUT\d{6}` | `WC_\d{16}\|OUT-\d{6}\|OUT\d{6}` |
| `STRING_PATTERN_PICKING_PARCEL` | `P-\\d{4}` | `P-\d{4}` | `P-\d{4}` | `C1-\d{4}` | `P-\d{4}` | `P-\d{4}` |
| `STRING_PATTERN_PICKING_TOTE` | `T-\\d{4}` | `T-\d{4}` | `T-\d{4}` | `C1-\d{4}` | `P-\d{4}` | `P-\d{4}` |
| `SYSTEM_OMS_NAME` | *(no default const)* | `OMS_om1` | `OMS_WINECO` | `OMS-Shipitez` | `OMS-Hydra` | `OMS-Shipitez` |
| `SYSTEM_WMS_NAME` | *(no default const)* | `WMS` | `WMS-WSL` | `WMS-C1WH` | `WMS-NYWH` | `WMS-NYWH` |
| `State / Province` | *(no constant)* | `Oregon (OR)` | `Oregon (OR)` | `California (CA)` | `NY` | `New York (NY)` |
| `System Time Zone` | *(no default const)* | `America/Los_Angeles` | `America/Los_Angeles` | `America/Los_Angeles` | `America/New_York` | `America/New_York` |
| `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED` | `false` | `true` | `false` | `false` | `false` | `false` |
| `UI_EMPTY_ON_LOAD` | *(no constant)* | `true` | `true` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `WAREHOUSE_NAME` | *(no default const)* | `WineCo - Salem` | `WineCo - Salem` | `C1WH` | `NYWH` | `NYWH` |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `https://oms-XXXXX.siteboss.net/services/call/receiveHubAndSpoke` | `https://api-oms.dev.sbo.li/services/call/receiveHubAndSpoke` | `https://api-oms.uat.sbo.li/services/call/receiveHubAndSpoke` | `https://api-oms.uat.sbo.li/services/call/receiveHubAndSpoke` | `https://api-oms.uat.sbo.li/services/call/receiveHubAndSpoke` | `https://api-oms.uat.sbo.li/services/call/receiveHubAndSpoke` |
| `WEBSERVICE_ACCEPT_TRANSFER` | `https://oms-XXXXX.siteboss.net/services/call/closeTransfer` | `https://api-oms.dev.sbo.li/services/call/closeTransfer` | `https://api-oms.uat.sbo.li/services/call/closeTransfer` | `https://api-oms.uat.sbo.li/services/call/closeTransfer` | `https://api-oms.uat.sbo.li/services/call/closeTransfer` | `https://api-oms.uat.sbo.li/services/call/closeTransfer` |
| `WEBSERVICE_CLOSE_ADVICE` | `https://oms-XXXXX.siteboss.net/services/call/closeAdvice` | `https://api-oms.dev.sbo.li/services/call/closeAdvice` | `https://api-oms.uat.sbo.li/services/call/closeAdvice` | `https://api-oms.uat.sbo.li/services/call/closeAdvice` | `https://api-oms.uat.sbo.li/services/call/closeAdvice` | `https://api-oms.uat.sbo.li/services/call/closeAdvice` |
| `WEBSERVICE_FACILITY_LIST_LOOKUP` | `https://oms-XXXXX.siteboss.net/services/call/facilities` | `https://api-oms.dev.sbo.li/services/call/facilities` | `https://api-oms.uat.sbo.li/services/call/facilities` | `https://api-oms.uat.sbo.li/services/call/facilities` | `https://api-oms.uat.sbo.li/services/call/facilities` | `https://api-oms.uat.sbo.li/services/call/facilities` |
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `https://oms-XXXXX.siteboss.net/services/call/cancelPosition` | `https://api-oms.dev.sbo.li/services/call/cancelPosition` | `https://api-oms.uat.sbo.li/services/call/cancelPosition` | `https://api-oms.uat.sbo.li/services/call/cancelPosition` | `https://api-oms.uat.sbo.li/services/call/cancelPosition` | `https://api-oms.uat.sbo.li/services/call/cancelPosition` |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `https://oms-XXXXX.siteboss.net/services/call/finishedPicking` | `https://api-oms.dev.sbo.li/services/call/finishedPicking` | `https://api-oms.uat.sbo.li/services/call/finishedPicking` | `https://api-oms.uat.sbo.li/services/call/finishedPicking` | `https://api-oms.uat.sbo.li/services/call/finishedPicking` | `https://api-oms.uat.sbo.li/services/call/finishedPicking` |
| `WEBSERVICE_ORDER_BATCH_HELD` | `https://oms-XXXXX.siteboss.net/services/call/held` | `https://api-oms.dev.sbo.li/services/call/held` | `https://api-oms.uat.sbo.li/services/call/held` | `https://api-oms.uat.sbo.li/services/call/held` | `https://api-oms.uat.sbo.li/services/call/held` | `https://api-oms.uat.sbo.li/services/call/held` |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `https://oms-XXXXX.siteboss.net/services/call/loadedToTruck` | `https://api-oms.dev.sbo.li/services/call/loadedToTruck` | `https://api-oms.uat.sbo.li/services/call/loadedToTruck` | `https://api-oms.uat.sbo.li/services/call/loadedToTruck` | `https://api-oms-dev.siteboss.net/services/call/loadedToTruck` | `https://api-oms.uat.sbo.li/services/call/loadedToTruck` |
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `https://oms-XXXXX.siteboss.net/services/call/palletized` | `https://api-oms.dev.sbo.li/services/call/palletized` | `https://api-oms.uat.sbo.li/services/call/palletized` | `https://api-oms.uat.sbo.li/services/call/palletized` | `https://api-oms-dev.siteboss.net/services/call/palletized` | `https://api-oms.uat.sbo.li/services/call/palletized` |
| `WEBSERVICE_ORDER_BATCH_PICKING` | `https://oms-XXXXX.siteboss.net/services/call/picking` | `https://api-oms.dev.sbo.li/services/call/picking` | `https://api-oms.uat.sbo.li/services/call/picking` | `https://api-oms.uat.sbo.li/services/call/picking` | `https://api-oms.uat.sbo.li/services/call/picking` | `https://api-oms.uat.sbo.li/services/call/picking` |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `https://oms-XXXXX.siteboss.net/services/call/assignedToteID` | `https://api-oms.dev.sbo.li/services/call/assignedToteID` | `https://api-oms.uat.sbo.li/services/call/assignedToteID` | `https://api-oms.uat.sbo.li/services/call/assignedToteID` | `https://api-oms.uat.sbo.li/services/call/assignedToteID` | `https://api-oms.uat.sbo.li/services/call/assignedToteID` |
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `https://oms-XXXXX.siteboss.net/services/call/readytopick` | `https://api-oms.dev.sbo.li/services/call/readytopick` | `https://api-oms.uat.sbo.li/services/call/readytopick` | `https://api-oms.uat.sbo.li/services/call/readytopick` | `https://api-oms.uat.sbo.li/services/call/readytopick` | `https://api-oms.uat.sbo.li/services/call/readytopick` |
| `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` | `https://oms-XXXXX.siteboss.net/services/call/batchReversalCompleted` | `https://api-oms.dev.sbo.li/services/call/batchReversalCompleted` | `https://api-oms.uat.sbo.li/services/call/batchReversalCompleted` | `https://api-oms.uat.sbo.li/services/call/batchReversalCompleted` | `https://api-oms-dev.siteboss.net/services/call/batchReversalCompleted` | `https://api-oms.uat.sbo.li/services/call/batchReversalCompleted` |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `https://oms-XXXXX.siteboss.net/services/call/finishedShipping` | `https://api-oms.dev.sbo.li/services/call/finishedShipping` | `https://api-oms.uat.sbo.li/services/call/finishedShipping` | `https://api-oms.uat.sbo.li/services/call/finishedShipping` | `https://api-oms.uat.sbo.li/services/call/finishedShipping` | `https://api-oms.uat.sbo.li/services/call/finishedShipping` |
| `WEBSERVICE_STOCK_COUNT` | `https://oms-XXXXX.siteboss.net/call/inventory/stockCountExport` | `https://api-oms.dev.sbo.li/call/inventory/stockCountExport` | `https://api-oms.uat.sbo.li/call/inventory/stockCountExport` | `https://api-oms.uat.sbo.li/call/inventory/stockCountExport` | `https://api-oms.uat.sbo.li/call/inventory/stockCountExport` | `https://api-oms.uat.sbo.li/call/inventory/stockCountExport` |
| `WEBSERVICE_STOCK_UPDATE` | `https://oms-XXXXX.siteboss.net/call/inventory/stockUpdate` | `https://api-oms.dev.sbo.li/call/inventory/stockUpdate` | `https://api-oms.uat.sbo.li/call/inventory/stockUpdate` | `https://api-oms.uat.sbo.li/call/inventory/stockUpdate` | `https://api-oms.uat.sbo.li/call/inventory/stockUpdate` | `https://api-oms.uat.sbo.li/call/inventory/stockUpdate` |
| `WEBSERVICE_TEST_CRM_CONNECTIVITY` | `https://oms-XXXXX.siteboss.net/services/call/testPsd` | `https://api-oms.dev.sbo.li/services/call/testPsd` | `https://api-oms.uat.sbo.li/services/call/testPsd` | `https://api-oms.uat.sbo.li/services/call/testPsd` | `https://api-oms.uat.sbo.li/services/call/testPsd` | `https://api-oms.uat.sbo.li/services/call/testPsd` |
| `WEB_UI_REDIRECT_URL` | *(no default const)* | `https://wh01m.komatik.co/oauth2callback?logout=https://wh01m.komatik.co/web/gui` | `VERSION-1.0-ONLY` | `https://wh04.komatik.co/oauth2callback?logout=https://wh04.komatik.co/web/gui` | `https://wh03.komatik.co/oauth2callback?logout=https://wh03.komatik.co/web/gui` | `https://wh05.komatik.co/oauth2callback?logout=https://wh05.komatik.co/web/gui` |
| `WMS_INSTANCE_NAME` | *(no default const)* | `wineco-salem` | `VERSION-1.0-ONLY` | `C1WH` | `NYWH` | `NYWH` |
| `WMS_LOGIN_SECRET` | 🔒 *redacted* | 🔒 *redacted* | 🔒 *redacted* | 🔒 *redacted* | 🔒 *redacted* | 🔒 *redacted* |
| `Warehouse Phone #` | *(no constant)* | `503-399-0514` | `503-399-0514` | `7072008323` | `13155559182` | `13155559182` |
| `Zip` | *(no constant)* | `97303` | `97302` | `95425` | `10005` | `12180` |
| `cy_probe_1783506211135` | *(no constant)* | `test_value` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `cy_probe_1783506498107` | *(no constant)* | `test_value` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `test` | *(no constant)* | `test value` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `test2` | *(no constant)* | `test value` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
| `test3` | *(no constant)* | `test value` | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* | **—** *(no row)* |
---

## 6. Reproduction

```bash
# 1. discover active tenants (per environment)
PGPASSWORD=… psql -h 127.0.0.1 -p 25060 -U wms_landlord -d dev_landlord -X -tA -F$'\t' \
  -c "SELECT warehouse, db_url, db_user_name, db_password FROM tenant_db_configuration WHERE active;"
#    UAT: -p 25062 -d landlord

# 2. per tenant
PGPASSWORD=… psql -h 127.0.0.1 -p <port> -U <db_user_name> -d <dbname> -X -tA -F$'\t' \
  -c "SELECT syskey, coalesce(sysvalue,'<NULL>'), workstation, client_id, groupname
        FROM los_sysprop ORDER BY syskey;"

# 3. code side
grep -E 'public static final String SYSTEM_PROPERTY_\w+_KEY\s*=' \
  v2/wms2-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java
#    plus the nested LocationAreaService.PROPERTY_KEY_AREA_DEFAULT
```

Tunnel ports and landlord DB names per environment are in
[`wms2-apply-pending-tenant-flyway.md`](../../2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md) §4.1 —
note the DEV landlord is `dev_landlord`, not `landlord`.

---

## 7. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-07-30 | `los_sysprop` full read on 5 active tenants (679 rows); `WmsConstants.java` constant extraction; consumer greps across `wms2-api`, `wms2-web-ui`, `wms2-mobile-ui`; `git` history of the constant block at 2026-04-19 / 07-24 / 07-30 | 146 live keys vs 124 constants; 32 constant-less (20 UI-managed, 4 orphans, 7 junk, 1 seeded-ahead-of-code); 10 constants with no row; 0 placeholders; 0 NULLs; 2 plaintext secrets | Nam Park (live psql, read-only) |

**This snapshot expires.** Values are operator-editable at any time; treat anything here older than a release cycle as indicative, not authoritative.

---

## 8. Amendment — `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` seeded (2026-07-30, after capture)

This report's §2.6 listed the key as read-by-code-but-seeded-nowhere. That was acted on the same day, so the census tables above are one row out of date for `dev_wh01_om1`.

**What was wrong.** `OutboxDispatchService.sampleStuckAggregates()` (`:317`) gates on
`Boolean.parseBoolean(syspropService.getSysvalue(OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED))`. There is no
`*_DEFAULT_VALUE` constant and there was no Flyway seed, so the metric was off with **no row an operator
could find**. Worse, the self-healing path made it invisible: `getSysvalue` auto-creates a row with a NULL
value *and a NULL groupname*, and the Admin screen lists rows via `findByGroupname` — so the first
dispatcher read would have created exactly the kind of §2.3 orphan this report flags.

**What changed.** A second idempotent `INSERT … WHERE NOT EXISTS` was appended to the **existing**
`V2.2.05` script rather than added as `V2.2.06`, seeding the key at `false` (default unchanged) with
`groupname = 'Operation Options'` so it appears beside `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED`.

**Why editing an applied migration was acceptable here — and the trap in doing it.**
`dev_wh01_om1` was the only DB in the fleet with `2.2.05` recorded; all four UAT tenants had it merely
*pending* at `2.2.04`, so they receive the amended version cleanly and no checksum was ever recorded for
them. Editing it nonetheless violates the standing rule in `wms2-api/CLAUDE.md` and §8.1 of the Flyway
runbook, and it did immediately break validation on dev (`checksum mismatch for migration version 2.2.05`).

> ⚠️ **`flyway repair` is the wrong recovery.** It realigns the recorded checksum without re-executing, so
> the new INSERT would silently never run while history claimed `2.2.05` complete. The correct sequence,
> and what was done:
> ```sql
> DELETE FROM flyway_schema_history WHERE version = '2.2.05';
> ```
> then `--apply`. Safe **only** because every statement in the script is `INSERT … WHERE NOT EXISTS`.

**Verification.**

| Check | Result |
|---|---|
| Both keys present, one row each | ✓ `OUTBOX_REJECT_…` id 30494306, `OUTBOX_STUCK_…` id 30494307 |
| Pre-existing row not re-inserted | ✓ id and `created` (`2026-07-30 01:15:16.726625+00`) unchanged from pre-state |
| New row correct | ✓ `false`, `groupname='Operation Options'` |
| History checksum updated | ✓ `2141461053` → `-382893208`, `success=t`, rank 6 |
| Drift cleared | ✓ `--status` → `all tenants at 2.2.05`, exit 0 |
| Idempotency of the new statement | ✓ negative-tested — re-running it reports `INSERT 0 0` (rolled back) |

**Renamed, same day.** `V2.2.05__seed_outbox_reject_on_error_sysprop.sql` →
**`V2.2.05__seed_outbox_sysprop_toggles.sql`**, matching the `V2.2.04__seed_lane_behavior_sysprop_toggles.sql`
precedent now that the script seeds two toggles. Done while `dev_wh01_om1` was still the only DB holding it.

This surfaced a second, distinct drift shape worth knowing: a rename fails validation with
**`description mismatch`**, not `checksum mismatch` — Flyway derives the description from the filename after
the `__`, and the content checksum was unchanged (`-382893208` before and after). Same remedy (delete the
history row, re-migrate); both sysprop rows kept their original ids and `created` timestamps across the
re-run, confirming the idempotent guards made it a pure no-op on data. The driver script now names the two
shapes separately and warns against `repair`.

**Follow-up.** Adding an
`OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED_DEFAULT_VALUE` constant would let the consumer use
`getStringDefault` instead of relying on `parseBoolean(null)`; not done, as it is a code change beyond the
scope of the seed.
