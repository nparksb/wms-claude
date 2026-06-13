---
title: "Replenishment Monitor — Classify Replenishable Stock by Flag, Not Area Name"
ticket: "SBDEV-2384"
ticket_url: "https://app.clickup.com/t/SBDEV-2384"
type: bugfix
priority: high
status: implemented
project: [wms1]
version: "v1/wms-api @ release (0d6f989)"
requester: "Nam Park (WineCo report)"
created: 2026-06-01
updated: 2026-06-01
db_verified: true
related:
  - "[[260601-wineco-replenishment-pickpack-source-and-order-count]]"
  - "[[260602-SBDEV-2384-replenishment-monitor-fix-validation-and-test-plan]]"
  - "[[wms1-replenish-workflow]]"
  - "[[wms1-replenish-order-creation]]"
tags:
  - plan
  - bugfix
  - wms1
  - replenish
---

# Replenishment Monitor — Classify Replenishable Stock by Flag, Not Area Name

**Project:** wms1 | **Version:** v1/wms-api @ release (`0d6f989`) | **Type:** bugfix
**Priority:** High (blocks WineCo shipment confidence in the Replenishment Monitor)
**Status:** draft — reviewed by `architect` + `critic` agents 2026-06-01; findings incorporated (see §10)
**Date:** 2026-06-01

> **Scope (confirmed with requester):** (1) fix **both** read paths — the inline `getReplenishViewSummary` query *and* the deployed `replenishment_monitor_view`; (2) **keep** the `on_non_replenishable_location` bucket as the existing staging set (Inbound/Default/users) — only the replenishable bucket is wrong; (3) the intermittent **order-count fan-out** (`count(co.*)` + `t4`/`t5` row multiplication) is **out of scope** here and will be a separate plan.

> **Read-path shapes differ (review finding).** The inline `getReplenishViewSummary` query returns **26 columns** (adds `section_name`, `sku_type`, `*_location_names`, `ro_id`, `ro_destination_name`, `fix_assignment_upperbound`); the deployed DB view `replenishment_monitor_view` returns **17 columns** (verified via `pg_attribute`). They are **not** copies of one another — they share only the `t3` replenishable/staging CASE predicates. This plan changes only those shared predicates; it does **not** align the two shapes.

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn "Storage and Picking\|on_replenishable\|useforreplenish"` across `src/main/java` and `src/main/resources/db/migration`.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `repo/jpa/ReplenishmentMonitorViewRepository.java:98` | `on_replenishable_location` SUM — `loc_area.name = ANY(ARRAY[...,'Storage and Picking'])` | **yes** | **yes** (Fix A) |
| 2 | `repo/jpa/ReplenishmentMonitorViewRepository.java:102` | `on_replenishable_location_names` `string_agg` — same name list | **yes** | **yes** (Fix A) |
| 3 | `src/main/resources/db/migration/V1.0.02__wms_views.sql:478` | deployed `replenishment_monitor_view`.`on_replenishable_location` — same name list | **yes** | **yes** (Fix B, new migration) |
| 4 | `model/ReplenishmentMonitorView.java:83` | Commented copy of the legacy view DDL (documentation only) | yes (doc) | **yes** (Fix C, comment hygiene) |
| 5 | `repo/jpa/ReplenishmentMonitorViewRepository.java:90,94` | `on_non_replenishable_location(_names)` — `ARRAY['Inbound','Default','users']` | partially | **no** — staging bucket kept intentionally (requester decision) |
| 6 | `db/migration/V1.0.02__wms_views.sql:470` | deployed view `on_non_replenishable_location` — same staging list | partially | **no** — same decision |
| 7 | `service/CustomerorderBatchService.java:820`, `service/TransferOrderService.java:246` | `Arrays.asList(AREA_INBOUND_NAME, AREA_STORAGE_PICKING_NAME, …)` — area-name list for allocation/exclusion | **no** | **no** — different feature, enumerates *all* storage areas, not the replenishable subset |
| 8 | `service/WmsConstants.java:722-726` | `AREA_*_NAME` constants | n/a | **no** — constants are correct; not the defect |

Every in-scope row (1–4) is addressed in §5 Fix Design and mapped to a positive check in `verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix.sh`.

---

## 1. Problem Statement

WineCo operators report: *"System still is using Pick Pack Locations as valid replenishment."*

In the **Replenishment Monitor**, the **"on replenishable location"** figure includes stock that sits on **pick-only** faces, so an operator reading the monitor believes replenishable supply exists when it does not — and expects replenishment to resolve a pick shortage it cannot resolve.

**Concrete evidence (investigation `260601-wineco-replenishment-pickpack-source-and-order-count.md`):**

- **BW23CPN** — all stock is 11 bottles on **10-B01** (area *"Storage and Picking"*, `useforpicking=true`, `useforreplenish=false`), fully reserved. The monitor reports **`on_replenishable_location = 11`**; the true replenishable quantity is **0**.
- **25GNEAH750** — monitor reports **`on_replenishable_location = 655`**; the true replenishable quantity (reserve in *"Storage and Replenish"*) is **588**. The extra **67** is pick-face stock at 45-C02 wrongly classified as replenishable.

**DB verification (read-only, `wms1-wineco`, 2026-06-01):**

```sql
SELECT i.item_nr,
  round(sum(CASE WHEN loc_area.name IN
      ('Storage and Replenish','Deep Storage','Storage, Picking and Replenish (from)','Storage and Picking')
    THEN su.amount ELSE 0 END)) AS current_name_based,
  round(sum(CASE WHEN loc_area.useforreplenish = TRUE
    THEN su.amount ELSE 0 END)) AS proposed_flag_based
FROM stockunit su
  JOIN unitload ul ON ul.id = su.unitload_id
  JOIN location loc ON loc.id = ul.storagelocation_id
  JOIN location_area loc_area ON loc_area.id = loc.area_id
  JOIN itemdata i ON i.id = su.itemdata_id
WHERE su.entity_lock=0 AND ul.entity_lock=0 AND loc.entity_lock=0
  AND i.item_nr IN ('BW23CPN','25GNEAH750')
GROUP BY i.item_nr;
```

| item_nr | current_name_based | proposed_flag_based |
|---|---|---|
| BW23CPN | **11** | **0** |
| 25GNEAH750 | **655** | **588** |

The proposed flag-based figures match the warehouse's true replenishable inventory.

**Reproduction:** Open the Replenishment Monitor for a client that has demand for a SKU whose only stock is on a *"Storage and Picking"* face → the "on replenishable location" column shows that pick-face quantity, implying replenishable supply that does not exist.

---

## 2. Root Cause Analysis

### Bug 1: Replenishable supply is classified by hardcoded area NAME, not by the `useforreplenish` flag

The Monitor query the UI calls — `ReplenishmentMonitorViewRepository.getReplenishViewSummary()` — computes the replenishable bucket from a **string list of area names** that includes the pick-only area `'Storage and Picking'`:

`repo/jpa/ReplenishmentMonitorViewRepository.java:96-103`
```sql
round(sum(CASE
  WHEN loc_area.name::text = ANY (ARRAY[
        'Storage and Replenish','Deep Storage',
        'Storage, Picking and Replenish (from)','Storage and Picking']::text[])   -- ← pick-only area
  THEN su.amount ELSE 0::numeric END)) AS on_replenishable_location,
string_agg(DISTINCT CASE
  WHEN loc_area.name::text = ANY (ARRAY[ ... 'Storage and Picking' ... ]::text[])
  THEN loc.name END, ', ') AS on_replenishable_location_names
```

The deployed view repeats the identical defect:

`src/main/resources/db/migration/V1.0.02__wms_views.sql:477-484`
```sql
ROUND(SUM(CASE WHEN
    loc_area.name IN ('Storage and Replenish','Deep Storage','Storage, Picking and Replenish (from)','Storage and Picking')
  THEN su.amount ELSE 0 END)) AS on_replenishable_location
```

**Why it fails:** the canonical truth for "can this area be a replenishment source" is the boolean column `location_area.useforreplenish`. The WineCo config has:

| area | useforpicking | useforreplenish |
|---|---|---|
| Storage and Replenish | false | **true** |
| Storage and Picking | **true** | **false** ← wrongly listed as replenishable |
| Storage Picking and Replenish (from) | true | true |
| Deep Storage | false | false |

`'Storage and Picking'` has `useforreplenish = false`, yet the name list counts its stock as replenishable. Note the same subquery **already uses the flag correctly** for the *available* bucket (`useforpicking = TRUE AND useforreplenish = FALSE`, `V1.0.02__wms_views.sql:447-448`) — the replenishable bucket simply wasn't migrated off names.

**Secondary defect, fixed for free:** the name list contains `'Storage, Picking and Replenish (from)'` (with a comma) while the actual area name is `'Storage Picking and Replenish (from)'` (no comma — see `WmsConstants.AREA_STORAGE_PICKING_REPLENISH_NAME`, `WmsConstants.java:723`). The literal never matches; switching to the flag removes this fragility. (That area currently has 0 locations, so the typo is latent today.)

This is a reporting/classification bug, not a defect in the replenishment engine. `ReplenishGeneratorService.calculateOrder` selects sources via `StockunitRepository.getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` (which already filters `area.useForReplenish = true`), and all 621 open replenish orders currently source from the proper reserve. Hardening that source query against dual-purpose pick/replenish areas is tracked as a separate "Fix later" item in the investigation report and is **out of scope** here.

### Behavioral deltas the flag switch introduces (review finding — state explicitly)

Switching `on_replenishable_location` from the name list to `useforreplenish = true` changes which area types land in the bucket. Be explicit so the corrected numbers are not mistaken for a regression:

| Area (WineCo) | `useforpicking` / `useforreplenish` | Before (name list) | After (flag) | Note |
|---|---|---|---|---|
| Storage and Replenish | f / **t** | counted | counted | unchanged (correct) |
| Storage and Picking | **t** / f | **counted (bug)** | **not counted** | the fix — pick faces removed |
| Deep Storage | f / f | counted | **not counted** | correct by flag; but verify intent — for WineCo `usefordeepstorage=false` too, so it is *not* a replenish source today |
| Storage Picking and Replenish (from) | **t** / **t** | **not** counted (name-list comma typo never matched) | **counted** | dual-purpose face *becomes* replenishable — correct by flag, but a **direction the name list never had**. 0 locations today, so no live impact; matters if any tenant populates it |
| Outbound | f / f | not counted | not counted | unchanged |

Two consequences to socialize: (a) `Deep Storage`, `Outbound`, and pick faces now appear in **neither** the replenishable nor the staging bucket — by design; (b) for the dual-purpose area the figure can *increase* (not just decrease), so "the new value reflects true replenishable inventory" (§9) means both directions.

---

## 3. Architecture Overview

```
Web UI  ── GET replenishment monitor ──►  ViewDtoService.getReplenishMonitorViewSummary()  (ViewDtoService.java:1148)
                                              │
                                              └─► ReplenishmentMonitorViewRepository.getReplenishViewSummary()   ← Fix A
                                                   (native query; t3 sub-select buckets stock by area NAME)

Spring Data REST ── GET /replenishmentMonitorView (findAll) ─► entity ReplenishmentMonitorView
                                              │
                                              └─► DB VIEW public.replenishment_monitor_view                       ← Fix B (Flyway)
                                                   (defined in V1.0.02__wms_views.sql; same t3 NAME buckets)
```

The two read paths share **only the `t3` replenishable/staging CASE predicates** — they are not copies of one another (the inline query projects 26 columns incl. `section_name`/`ro_id`/`*_names`; the DB view projects 17). Fixing one without the other leaves the bug live on the other path. `findAll` over the entity is a genuine live consumer: `ReplenishmentMonitorView` is `@Entity` with no `@Table`, so Hibernate maps it to the DB view `replenishment_monitor_view`, and `ReplenishmentMonitorViewRepository` is `@RepositoryRestResource` exporting `findAll`. The requester confirmed both must change.

**Key Files**

| File | Lines | Role |
|---|---|---|
| `repo/jpa/ReplenishmentMonitorViewRepository.java` | 96-103 | Inline native query the Monitor UI calls (Fix A) |
| `src/main/resources/db/migration/V1.0.02__wms_views.sql` | 376-527 | Original definition of the deployed view (reference for Fix B) |
| `src/main/resources/db/migration/V1.26.29__*.sql` | new | New migration redefining the view (Fix B) |
| `model/ReplenishmentMonitorView.java` | 12-99 | Entity + commented DDL (Fix C, doc hygiene) |
| `service/ViewDtoService.java` | 1148-1189 | Maps query rows → DTO (no change) |

---

## 5. Fix Design

Principle: **classify the replenishable bucket by `location_area.useforreplenish = TRUE`**, leaving the staging (`on_non_replenishable`) bucket as the explicit `('Inbound','Default','users')` set per the requester's decision.

### Fix A — Inline query `getReplenishViewSummary` (the path the UI uses)

`repo/jpa/ReplenishmentMonitorViewRepository.java`

**Before** (lines 96-103, the two replenishable expressions):
```sql
round(sum(CASE
    WHEN loc_area.name::text = ANY (ARRAY['Storage and Replenish'::character varying, 'Deep Storage'::character varying, 'Storage, Picking and Replenish (from)'::character varying, 'Storage and Picking'::character varying]::text[]) THEN su.amount
    ELSE 0::numeric
END)) AS on_replenishable_location,
string_agg(DISTINCT CASE
    WHEN loc_area.name::text = ANY (ARRAY['Storage and Replenish'::character varying, 'Deep Storage'::character varying, 'Storage, Picking and Replenish (from)'::character varying, 'Storage and Picking'::character varying]::text[])
    THEN loc.name END, ', ') AS on_replenishable_location_names
```

**After:**
```sql
round(sum(CASE
    WHEN loc_area.useforreplenish = true THEN su.amount
    ELSE 0::numeric
END)) AS on_replenishable_location,
string_agg(DISTINCT CASE
    WHEN loc_area.useforreplenish = true
    THEN loc.name END, ', ') AS on_replenishable_location_names
```

The `on_non_replenishable_location(_names)` expressions (the `'Inbound','Default','users'` list, lines 90-95) are **unchanged**.

*Why not also flip non-replenishable to `useforreplenish = false`?* That would silently fold pick faces and Outbound into the staging column, changing what operators see there. The reported defect is solely the replenishable bucket; minimal change preferred (requester decision, §10).

### Fix B — Deployed DB view `replenishment_monitor_view` (Flyway migration)

New migration `src/main/resources/db/migration/V1.26.29__replenishment_monitor_view_flag_based_classification.sql` (version subject to §7.1) that re-creates the view identically except for the replenishable bucket.

**Source of truth for the view body (review finding):** reproduce the **exact 17-column shape currently deployed** — verified columns: `row_id, client_id, client_name, sku_id, sku_name, bottles_needed, order_hold, prio_high, prio_urgent, fix_assignment_location_name, bottles_on_location, bottles_reserved_on_location, on_non_replenishable_location, on_replenishable_location, ro_number, ro_requested_amount, ro_source_name`. This matches `V1.0.02__wms_views.sql:376-527`. Capture the live definition with `SELECT pg_get_viewdef('public.replenishment_monitor_view', true);` and edit *that* (or copy V1.0.02 — they are equivalent; the `count(co.*)` you see in `pg_get_viewdef` vs `COUNT(co)` in the file is the same expression, just `pg_get_viewdef`'s pretty-print). **Do NOT** add the inline query's extra columns (`section_name`, `ro_id`, `*_location_names`, `fix_assignment_upperbound`, …) — the view path never had them, and adding/reordering columns makes `CREATE OR REPLACE VIEW` fail.

**The only line that changes** vs `V1.0.02__wms_views.sql:478`:
```sql
-- before:
--   loc_area.name IN ('Storage and Replenish','Deep Storage','Storage, Picking and Replenish (from)','Storage and Picking')
-- after:
    ROUND(SUM(CASE WHEN loc_area.useforreplenish = TRUE
                   THEN su.amount ELSE 0 END)) AS on_replenishable_location
```
The migration contains the **full** view statement so the object is fully specified in one place. `on_non_replenishable_location` (`'Inbound','Default','users'`) stays as-is. `CREATE OR REPLACE VIEW` is legal **only because** the column list/order/types are identical to the deployed 17-column shape; if you deviate from that shape, use `DROP VIEW` + `CREATE VIEW` instead (no other DB object depends on this view — confirmed in the investigation).

> **Migration version caveat (see §7 Prerequisites):** the repo currently tops out at `V1.1.05` but also contains an out-of-band `V1.26.28`. No `flyway_schema_history`/`schema_version` table was found in the production `public` schema during investigation, so the applied baseline must be confirmed before naming the file. Use a version strictly greater than the highest *applied* version. `CREATE OR REPLACE VIEW` makes the migration safe to re-run/re-order.

### Fix C — Entity comment hygiene

`model/ReplenishmentMonitorView.java:83` carries a commented DDL whose `on_replenishable_location` CASE has the same wrong name list. **Scope Fix C to swapping that one predicate on/around line 83** to `loc_area.useforreplenish = true`. Do **not** try to reconcile the rest of the comment with the deployed view — the comment is an older, simpler 17-column snapshot and reconciling it is out of scope. No behavioral effect (it's a comment), but it stops the next reader from re-introducing the name list.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `repo/jpa/ReplenishmentMonitorViewRepository.java` | Modify | Replace name-list with `useforreplenish = true` in the two `on_replenishable_location(_names)` expressions |
| `src/main/resources/db/migration/V1.26.29__replenishment_monitor_view_flag_based_classification.sql` | Add | `CREATE OR REPLACE VIEW replenishment_monitor_view` with flag-based replenishable bucket |
| `model/ReplenishmentMonitorView.java` | Modify (comment) | Sync commented DDL to flag-based classification |
| `src/test/java/.../repo/ReplenishmentMonitorViewRepositoryIT.java` | Add | Testcontainers integration test asserting pick-only stock is excluded from `on_replenishable_location` |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Concern | Applies? | Detail |
|---|---|---|
| DB state | Yes | Confirmed against `wms1-wineco` (read-only): area `Storage and Picking` has `useforreplenish=false`; flag-based result matches truth (§1). |
| **Is Flyway even managing prod?** | **Yes — must verify FIRST** | No `flyway_schema_history`/`schema_version` table was visible in the production `public` schema during investigation. Before anything else, confirm: `SELECT to_regclass('public.flyway_schema_history'), to_regclass('public.schema_version');` and search other schemas (`SELECT table_schema FROM information_schema.tables WHERE table_name IN ('flyway_schema_history','schema_version');`). **If Flyway is NOT managing prod**, a new migration file will **not** reach production — Fix B must instead be delivered as a **DBA-run `CREATE OR REPLACE VIEW`** against each tenant DB, and the migration file exists only for repo/lower-env consistency. Resolve this before estimating deploy. |
| Flyway version / ordering | **Resolved → `V1.26.29`** | The migration is named **`V1.26.29__…`** (double underscore = valid Flyway versioned migration). This was chosen over the original `V1.1.06`: (a) `develop` already ships a `V1.1.06__…` script, so reusing it would collide on merge; (b) with `outOfOrder=false` (default) a `V1.1.06` file is *lower* than the out-of-band `V1.26.28_wms_functions.sql` already in the repo and would fail validation/skip. `V1.26.29` sits strictly above `V1.26.28`, so it orders correctly and merges cleanly. Still confirm it exceeds the highest **applied** version on the target tenant (`SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;`); note `V1.26.28_` has a **single** underscore so standard Flyway does not treat it as a versioned migration (it may be ignored entirely). |
| Deploy ordering (Fix A vs Fix B) | **Yes** | Fix A ships in the JAR; Fix B is the view. On a normal deploy where Flyway runs at app startup, both flip together. **If the view is applied manually/separately** (likely, per the "no history table" finding), there is a window where the inline-query path (`getReplenishViewSummary`) is corrected but the `findAll`/view path still miscounts (or vice-versa). Apply the view change in the same maintenance window as the code deploy. |
| Feature flags / sysprops | No | None involved. |
| Data migration / backfill | No | View redefinition only; no row changes. |
| External systems | No | No OMS/UI contract change — the JSON keys (`qtyOnReplenishableLocation`, etc.) and the 17 view columns are unchanged; only the numeric value of `on_replenishable_location` becomes correct. |
| Access / monitoring | No | N/A. |
| Rollback (Fix B) | **Yes** | There is no down-migration. To revert, ship a follow-up migration (or DBA-run statement) re-creating the view with the prior predicate. Keep the captured pre-change `pg_get_viewdef` output in the ticket as the rollback artifact. |

### 7.2 Steps (each independently committable)

1. **Baseline the verify script.** `bash sbdocs/9-System/scripts/verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix.sh` → capture FAIL baseline.
2. **Fix A** — edit the two `on_replenishable_location(_names)` expressions in `ReplenishmentMonitorViewRepository.getReplenishViewSummary` to use `loc_area.useforreplenish = true`. Leave the staging bucket untouched.
3. **Fix C** — sync the commented DDL in `ReplenishmentMonitorView.java`.
4. **Fix B** — confirm the Flyway baseline (Prereq), then add `V1.26.29__replenishment_monitor_view_flag_based_classification.sql` with the full `CREATE OR REPLACE VIEW` (flag-based replenishable bucket).
5. **Test** — add `ReplenishmentMonitorViewRepositoryIT` (Testcontainers) seeding one SKU with stock only on a `useforpicking=true, useforreplenish=false` area and asserting `on_replenishable_location = 0`; and one SKU split across a pick face + a `useforreplenish=true` reserve asserting only the reserve counts. Run `mvn verify`.
6. **Re-run the verify script** → must report `Result: N pass, 0 fail`.
7. **Update §10 Implementation Status** with commit SHAs, test names, `mvn verify` summary, and the final verify-script line.

---

## 8. Testing Plan

- **`ReplenishmentMonitorViewRepositoryIT`** (Testcontainers PostgreSQL — required because the query is native PostgreSQL with `::text` casts and `ANY(ARRAY[...])` that H2 cannot run):
  - **Each test inserts its OWN `location_area` rows with explicit flags — do NOT rely on the migration seed.** Review finding: seed `V1.1.02__wms_data.sql` sets `Deep Storage.useforreplenish = true`, but WineCo prod has it `false`. Relying on the seed would test a config that does not match production. Seed deterministic areas: a pick-only (`useforpicking=true, useforreplenish=false`), a reserve (`useforreplenish=true`), and a dual-purpose (`useforpicking=true, useforreplenish=true`).
  - `onReplenishableLocation_excludesPickOnlyArea()` — SKU whose only stock is on a pick-only location; assert `on_replenishable_location = 0` and the SKU still appears with the right `bottles_needed`.
  - `onReplenishableLocation_countsOnlyReplenishAreas()` — pick-face stock + reserve stock; assert `on_replenishable_location` equals only the reserve quantity.
  - `onReplenishableLocation_countsDualPurposeArea()` — **new (review finding):** stock on a `useforpicking=true AND useforreplenish=true` area; assert it **is** counted (the flag switch newly includes it; the old name list's comma typo excluded it).
  - `onNonReplenishableLocation_unchanged()` — stock on `Inbound`; assert it still lands in `on_non_replenishable_location` (regression guard for the kept staging bucket).
- Add the same set against the **DB view** (`SELECT … FROM replenishment_monitor_view`) so Fix B is exercised, not just the inline query (Fix A).
- Mockito note: no static mocking needed (Mockito 3.3.3 OK); this is a repository/SQL test, not a service mock.

### Regression
- Re-run any existing `ViewDtoService` / monitor tests to confirm DTO mapping (`ViewDtoService.java:1148-1189`) is unaffected — column order and names are unchanged.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Pick-only stock not shown as replenishable | staging w/ WineCo-like data | Open Replenishment Monitor; find a SKU whose only stock is on a "Storage and Picking" face | "On replenishable location" shows **0** for that SKU (was = pick-face qty) | |
| Reserve stock still counted | staging | SKU with stock in "Storage and Replenish" | "On replenishable location" = reserve qty (unchanged) | |
| Mixed stock | staging | SKU with both pick-face and reserve stock | Column = reserve qty only (excludes pick face) | |
| Staging bucket unchanged | staging | SKU with stock in Inbound | "On non-replenishable location" still includes it | |
| SQL parity check | target tenant DB (read-only) | Compare `SELECT on_replenishable_location` from the view vs `sum(... useforreplenish=true)` for 5 SKUs | Values match | |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Migration version collides / applies out-of-order (`V1.26.28` already present) | Flyway fails or skips on deploy | Verify highest applied version first (§7.1); use a strictly-greater version; `CREATE OR REPLACE VIEW` is idempotent/re-runnable |
| Inline query and DB view drift again later | Bug silently returns on one path | Both fixed together; verify script asserts the name list is gone from the Java file; entity comment (Fix C) kept in sync |
| Operators relied on the inflated number | Perceived "drop" in replenishable stock | This is the correction; call it out in release notes — the new value reflects true replenishable inventory |
| Other monitor views share the pattern | Out-of-scope miscounts elsewhere | §0 enumeration found none in the replenishable-classification sense; rows 7-8 are a different feature, explicitly excluded |
| `CREATE OR REPLACE` rejected if a column type is inferred differently | Migration error | Column list/types are unchanged from the deployed 17-col shape; if REPLACE is rejected, fall back to `DROP VIEW` + `CREATE VIEW` in the same migration (no other DB object depends on this view) |
| **Flyway may not manage prod at all** (no history table found) | Migration file never reaches production; view stays buggy while everyone believes it's fixed | §7.1 first row — confirm Flyway management before relying on a migration; if absent, deliver Fix B as a DBA-run `CREATE OR REPLACE VIEW` per tenant DB |
| **Deploy-ordering window** between Fix A (JAR) and Fix B (view) | One read path corrected while the other still miscounts | Apply the view change in the same maintenance window as the code deploy (§7.1 deploy-ordering row) |
| Dual-purpose area stock newly counted as replenishable | Monitor figure *increases* for `useforpicking+useforreplenish` faces — could surprise operators | Documented as intended in §2 behavioral-delta table; 0 such locations for WineCo today; covered by `onReplenishableLocation_countsDualPurposeArea()` IT |

---

## 9b. Acceptance

Machine-checkable script: **`sbdocs/9-System/scripts/verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix.sh`**

Final acceptance requires the script to print `Result: N pass, 0 fail` AND `mvn verify` (incl. `ReplenishmentMonitorViewRepositoryIT`) to pass. Paste both in §10 before sign-off.

---

## Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1 — `execute_sql` run on `wms1-wineco` (read-only); `db_verified: true`; flag-based result confirmed (BW23CPN 11→0, 25GNEAH750 655→588) |
| 1 | All callsites enumerated | ✓ §0 — rows 1-4 in scope, all in §5; rows 5-8 excluded with rationale |
| 2 | Adjacent bugs | ✓ §0 rows 7-8 (different feature) excluded; secondary name typo fixed for free (§2) |
| 3 | Backward compatibility | ✓ §7.1 — JSON keys & the 17 view columns unchanged; only the numeric value corrects. §2 documents the value-direction deltas (pick faces drop out; dual-purpose newly counted) |
| 4 | Concurrency | no — read-only reporting query/view; no writes, no locks |
| 5 | Multi-tenant | ✓ query/view are per-tenant by datasource; no cross-tenant assumption introduced |
| 6 | Error handling | no — no new throw paths (SQL predicate swap only) |
| 7 | Observability | no — reporting value correction; no new failure mode. Release note recommended (§9) |
| 8 | Rollback / migration | ✓ §7.1 + §9 — Flyway-management check, version-ordering, deploy-ordering window, and explicit Fix B rollback (re-create view from captured `pg_get_viewdef`) all documented |
| 9 | Test coverage | ✓ §8 — `ReplenishmentMonitorViewRepositoryIT` (Testcontainers) + manual smoke |
| 10 | Cross-version (v1↔v2) | v2 has its own monitor implementation (`wms2-replenishment-design.md`); a paired v2 check is recommended via `wms-v2-migrate` but is a separate plan — not blocking this v1 fix |

---

## 10. Open Questions / Resolved Decisions

- **RESOLVED (requester, 2026-06-01):** Fix **both** the inline query and the DB view.
- **RESOLVED (requester, 2026-06-01):** Keep `on_non_replenishable_location` as the staging set (`Inbound`/`Default`/`users`); only the replenishable bucket changes.
- **RESOLVED (requester, 2026-06-01):** Order-count fan-out (`count(co.*)` + `t4`/`t5` multiplication) is a **separate** plan.
- **OPEN (implementer must resolve at deploy time):** exact Flyway migration version — confirm highest applied version in the target environment before naming the file (§7.1).
- **OPEN (blocking Fix B delivery):** is Flyway managing the prod schema at all? No history table was found. If not, Fix B ships as a DBA-run `CREATE OR REPLACE VIEW`, not a migration (§7.1).
- **OPEN (follow-up):** v2 equivalent — confirm whether `wms2-api`'s replenishment monitor shares the name-based classification; route via `wms-v2-migrate` if so.

### Review findings incorporated (architect + critic, 2026-06-01)

| Finding | Severity | Disposition |
|---|---|---|
| "Deployed view drifted from V1.0.02 (`count(co.*)` vs `COUNT(co)`)" | BLOCKER (claimed) | **Refuted** — verified the deployed view is the 17-col V1.0.02 shape via `pg_attribute`; the difference is `pg_get_viewdef` pretty-printing (`COUNT(co)` ≡ `count(co.*)`). Still hardened §5 Fix B to reproduce the verified 17-col shape and not the 26-col inline query. |
| Inline query (26 col) vs DB view (17 col) are not copies | SHOULD-FIX | Fixed — header note + §3 reworded; §5 Fix B says do not align shapes. |
| Dual-purpose area newly counted as replenishable; "neither bucket" areas | MAJOR | Fixed — §2 behavioral-delta table; new IT `…countsDualPurposeArea()`; §9 risk row. |
| IT relies on seed flags; seed `Deep Storage.useforreplenish=true` ≠ prod `false` | MAJOR | Fixed — §8 now requires each IT to seed its own `location_area` rows with explicit flags. |
| Flyway may not manage prod / version-ordering / `V1.26.28` single-underscore | MAJOR | Fixed — §7.1 first row (confirm Flyway mgmt + concrete queries), version-ordering row, §9 risk rows. |
| Deploy-ordering window (Fix A JAR vs Fix B view) | SHOULD-FIX | Fixed — §7.1 deploy-ordering row + §9 risk. |
| No rollback story for Fix B | SHOULD-FIX | Fixed — §7.1 rollback row (capture `pg_get_viewdef` as rollback artifact). |
| Fix C framing ("copy of deployed view") inaccurate | SHOULD-FIX | Fixed — §5 Fix C rescoped to the single predicate on line 83. |
| Verify-script false-pass holes (A4 single-substring; A5 weak staging guard; no deployed-shape check) | CRITICAL (critic) | Fixed in the script — see updated `verify-…sh` (A4 requires ≥2 flag uses bound to `THEN su.amount`; A5 asserts the staging predicate; new B-checks for the view shape). |
| entity_lock parity between buckets | (predicted trap) | Confirmed non-issue — both buckets share one `WHERE entity_lock=0` clause; flag swap preserves parity. |

---

## 11. Implementation Status

**Status:** ✅ Implemented — 2026-06-02. Branch `task/SBDEV-2384`, commit `9412fa4`. PR [#169 → release](https://github.com/SiteBossInc/wms-api/pull/169).

### Per-fix delivery

| Fix | File | Change |
|---|---|---|
| A | `repo/jpa/ReplenishmentMonitorViewRepository.java` | Both `on_replenishable_location(_names)` CASE predicates → `loc_area.useforreplenish = true`. Staging bucket (`Inbound`/`Default`/`users`) untouched. |
| B | `src/main/resources/db/migration/V1.26.29__replenishment_monitor_view_flag_based_classification.sql` (new) | `CREATE OR REPLACE VIEW replenishment_monitor_view` reproducing the deployed 17-col shape verbatim; only the replenishable bucket changed to `useforreplenish = TRUE`. |
| C | `model/ReplenishmentMonitorView.java` | Commented DDL `on_replenishable_location` predicate → `useforreplenish = true` (single predicate; rest of comment untouched). |
| Test | `src/test/java/.../repo/jpa/ReplenishmentMonitorViewRepositoryIT.java` (new) | Testcontainers IT exercising BOTH read paths. |

### Test class & methods

`ReplenishmentMonitorViewRepositoryIT` (Testcontainers PostgreSQL 12; `@SpringBootTest` with `@MockBean OAuth2RestTemplate` to avoid the eager Keycloak token fetch at context startup):
- `onReplenishableLocation_excludesPickOnlyArea()` — pick-only stock ⇒ `on_replenishable_location = 0` (query + view).
- `onReplenishableLocation_countsOnlyReplenishAreas()` — pick face + reserve ⇒ only the reserve counts (query + view).
- `onReplenishableLocation_countsDualPurposeArea()` — `useforpicking=true AND useforreplenish=true` ⇒ counted (query + view).
- `onNonReplenishableLocation_unchanged()` — `Inbound` stock stays in the staging bucket (query + view; regression guard).

### Verification evidence

```
# Acceptance script (code-shape checks)
$ bash sbdocs/9-System/scripts/verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix.sh
Result: 14 pass, 0 fail, 1 skip   # IT skipped without RUN_MVN

# Behavioral IT (Testcontainers)
$ mvn test -Dtest=ReplenishmentMonitorViewRepositoryIT -Djacoco.skip=true -Dmaven.javadoc.skip=true -DargLine="-Dapi.version=1.41"
Tests run: 4, Failures: 0, Errors: 0, Skipped: 0
BUILD SUCCESS
```

> **Local-env note:** this machine's Docker daemon requires API ≥ 1.40 but the project's pinned `docker-java` (Testcontainers 1.17.6 → docker-java-api 3.2.13) negotiates 1.32; passing `-Dapi.version=1.41` to the forked test JVM resolves it. Not a code change — CI/other environments with a matching daemon need no override. The pre-existing `maven-javadoc-plugin` Javadoc errors in unrelated files (`FacadeException.java`) are skipped via `-Dmaven.javadoc.skip=true`, matching the project's documented build commands.

### Code review

`code-reviewer` (Opus) pass: **APPROVED** — 0 CRITICAL/HIGH. Migration verified byte-identical to `V1.0.02` except the two intended lines. Two LOW findings fixed (stale plan filename in the IT JavaDoc; added the view-path assertion to the staging regression guard). The MEDIUM (migration version ordering) and HIGH open-question (names-string breadth) are deploy-time / intended-behavior items already documented in §7.1 and §2.

### Deploy gates (unchanged from §7.1 — still OPEN)

- Confirm Flyway manages the target schema before relying on the migration (else ship Fix B as a DBA-run `CREATE OR REPLACE VIEW` per tenant DB).
- Migration named **`V1.26.29`** (chosen over `V1.1.06` to avoid colliding with `develop`'s existing `V1.1.06__…` script and to sit above the out-of-band `V1.26.28_` file). Confirm it exceeds the highest **applied** Flyway version on the target tenant before deploy.
- Apply Fix A (JAR) and Fix B (view) in the same maintenance window.
