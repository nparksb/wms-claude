---
title: "SBDEV-2474 — Exclude Shipped Locks from Default Lock Report View (WMS v2)"
ticket: "SBDEV-2474"
ticket_url: "https://app.clickup.com/t/868k3kr3b"
type: "feature"
priority: "normal"
status: "archived"
archived: "2026-07-16"
merged_to_develop: "2026-07-16"
merge_commits:
  - "wms2-api PR #77 → c2a99f2"
  - "wms2-web-ui PR #21 → 9cac41a"
project: ["wms2"]
version: "v2"
requester: "Brent Campbell"
created: "2026-07-14"
updated: "2026-07-17"
db_verified: true
related:
  - "sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md"
tags:
  - plan
  - report
  - lock-report
---

# SBDEV-2474 — Exclude Shipped Locks from Default Lock Report View (WMS v2)

**Ticket:** [SBDEV-2474](https://app.clickup.com/t/868k3kr3b)
**Project:** wms2 | **Version:** v2 | **Type:** Feature / Improvement
**Priority:** Normal (Effort 1, Impact 2, Confidence 90%)
**Status:** Archived — implemented & dev-validated (merged to develop 2026-07-16; wms2-api PR #77 → `c2a99f2`, wms2-web-ui PR #21 → `9cac41a`)
**Date:** 2026-07-14
**Targets:** `v2/wms2-api` + `v2/wms2-web-ui`

> **Archive note (2026-07-16):** Both PRs merged to `develop` and dev test validation complete. Acceptance script retained at `sbdocs/9-System/scripts/verify-SBDEV-2474-lock-report-exclude-shipped-locks.sh`.

> **⚠️ Migration renumbered (2026-07-17).** After this plan was implemented, the `V2.2.00` base dump was re-exported to fold in the `los_sequencenumber` seed; the standalone `V2.2.01__los_sequencenumber_init.sql` was removed and every later `db/migration` delta shifted **down by one**. The version numbers throughout this document have been updated to the **current** on-disk numbering: **this fix now lives at `V2.2.02__lock_report_exclude_shipped.sql`** (implemented as `V2.2.03`), and the prior SBDEV-2384 replenishment delta it refers to is now `V2.2.01` (implemented as `V2.2.02`). The `V2.1.17` onboarding/IT-harness shim is unchanged. See `db/migration/README.md` and `wms2-database-setup-guide.md`.

---

## 0. Affected sites (enumeration before drafting)

| # | File:line | Construct | In-scope? | Phase |
|---|-----------|-----------|-----------|-------|
| 1 | `wms2-api` `src/main/resources/db/migration/V2.2.02__lock_report_exclude_shipped.sql` (**new**) | `CREATE OR REPLACE VIEW lock_overview_dto_view` + `WHERE COALESCE(su.entity_lock,0) <> 405`; `CREATE OR REPLACE VIEW lock_overview_all_view` (no filter) | yes | P1 |
| 2 | `wms2-api` `model/LockOverviewAllDtoView.java` (**new**) | `@Entity @Table(name="lock_overview_all_view")` — mirror of `LockOverviewDtoView` | yes | P1 |
| 3 | `wms2-api` `repo/jpa/LockOverviewAllDtoViewRepository.java` (**new**) | `@RepositoryRestResource(path="lockOverviewAllDtoView")` + `findByKeyword` (JPQL) + `findByClientOffsetAndLimit` (native) | yes | P1 |
| 4 | `wms2-api` `RestConfiguration.java:38` | add `LockOverviewAllDtoView.class` to `exposeIdsFor(...)` | yes | P1 |
| 5 | `wms2-api` `controller/ReportController.java:84-107` | read `includeShipped` from `reqMap`; pass to service | yes | P1 |
| 6 | `wms2-api` `service/ReportService.java:103-134` | add `boolean includeShipped` param; inject + branch to all-view repo | yes | P1 |
| 7 | `wms2-api` `model/LockOverviewDtoView.java:1-29` | **unchanged** — maps to the now-filtered `lock_overview_dto_view` | reference | — |
| 8 | `wms2-api` `repo/jpa/LockOverviewDtoViewRepository.java` | **unchanged** — default (excluding) path | reference | — |
| 9 | `wms2-api` onboarding delta `db/v1-to-v2-onboarding/schema/V2.1.17__lock_report_exclude_shipped.sql` (**new** — byte-identical copy of `V2.2.02`) | **IT-harness parity only** (see §2.5, corrected): the harness scans only `schema/`. **Production-redundant** with `V2.2.02` — a migrated tenant gets the fix from `V2.2.02` post-bridge. **Do NOT edit `V1.2.04`/`V1.0.02`/`V1.1.01` in place** (Flyway checksum drift) | yes | P1 |
| 10 | `wms2-api` `src/test/java/.../unit/service/ReportServiceUnitTest.java` | `includeShipped` true/false branch tests | yes | P1 |
| 11 | `wms2-web-ui` `components/reports/lockReport.vue` (toggle l.19-25/164/308-311) | "Include Shipped Locks" v-switch + reload watcher | yes | P2 |
| 12 | `wms2-web-ui` `store/reports/lock.js:52-108` | endpoint switch (`lockOverviewDtoView` vs `lockOverviewAllDtoView`) + export `includeShipped` flag | yes | P2 |

Every in-scope row is covered in §3 Design and §5 Phased Implementation. Rows 7–8 are explicitly excluded-with-rationale (they read the mutated view unchanged).

---

## 1. Problem Statement

The **Lock Report** (`/reports/lock-report`) lists every stock unit and its lock status. It applies **no lock-status filter**, so shipped inventory — which is historical and not actionable — dominates the report. On WineCo UAT the report showed ~1,846,671 rows; the operator must sift shipped/historical records to find current, actionable locks (damaged, on-hold, quality-fault, etc.).

**Quantified (live, v2 `wineco-dev`, `stockunit` table):**

| entity_lock | Label | Count | % |
|---|---|---:|---:|
| 405 | **Shipped** | 1,392,648 | **85.8%** |
| 2 | To Delete | 210,165 | 13.0% |
| 0 | Not Locked | 18,869 | 1.2% |
| 100 | Picked | 526 | <0.1% |
| 103 | Quality Fault | 273 | <0.1% |
| 104 | On Hold | 2 | <0.1% |
| — | **Total** | **1,622,483** | 100% |

Excluding `entity_lock = 405` removes **85.8%** of rows (1.39M → 229,835 remaining), directly addressing the usability and load-time complaints.

> The ticket's "~1,846,671 rows" figure is from the **WineCo UAT** snapshot; the table above is the live **`wineco-dev`** snapshot (1,622,483 rows). Different environments/snapshots — the ~86%-shipped proportion is the load-bearing figure, not the absolute count.

**Goal:** the default Lock Report (and its Excel export) excludes Shipped locks, while shipped data remains reachable through an explicit **"Include Shipped Locks"** toggle. Shipped rows are never deleted.

---

## 2. Current Architecture

A "lock" is **not** a standalone entity. It is the integer `entity_lock` code on `stockunit` / `unitload`, surfaced by a read-only DB view. Lock code **405 = SHIPPED** (`WmsConstants.BusinessObjectLockState.SHIPPED`, `wms2-api WmsConstants.java:1163-1211`; mirrored in UI `wms2-web-ui/util/constantValues.js:150`).

### 2.1 The view (`lock_overview_dto_view`)

`src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:1330-1351`:

```sql
CREATE VIEW public.lock_overview_dto_view AS
 SELECT row_number() OVER () AS row_id,
    su.id AS stockunitid, su.entity_lock AS stockunitlock, su.amount, su.reservedamount,
    i.item_nr AS itemnumber, i.name AS itemname,
    ul.labelid AS unitloadnumber, ul.entity_lock AS unitloadlock,
    loc.name AS locationname, carrier.labelid AS carriername, carrier.entity_lock AS carrierlock,
    c.name AS clientname, c.cl_nr AS clientnumber
   FROM stockunit su
     LEFT JOIN itemdata i  ON i.id = su.itemdata_id
     LEFT JOIN unitload ul ON ul.id = su.unitload_id
     LEFT JOIN location loc ON loc.id = ul.storagelocation_id
     LEFT JOIN unitload carrier ON carrier.id = ul.carrierunitload_id
     LEFT JOIN client c    ON c.id = su.client_id
  ORDER BY su.created DESC, su.modified DESC;
```

No `WHERE` predicate on `entity_lock` — the view returns every stock unit.

### 2.2 Entity, repository, exposure

- **Entity** `model/LockOverviewDtoView.java:1-29` — `@Entity @Table(name="lock_overview_dto_view")`, `@Id row_id`, flat fields (`stockunitlock`, `amount numeric(17,4)`, `reservedamount numeric(17,4)`, `itemnumber`, `itemname`, `unitloadnumber`, `unitloadlock`, `locationname`, `carriername`, `carrierlock`, `clientname`, `clientnumber`). No lazy associations.
- **Repository** `repo/jpa/LockOverviewDtoViewRepository.java` — `@RepositoryRestResource(collectionResourceRel="lockOverviewDtoView", path="lockOverviewDtoView")` extends `ReadOnlyPagingAndSortingRepository<LockOverviewDtoView, Long>`.
  - `findByKeyword(keyword, clientNumber, Pageable)` — JPQL, on-screen HAL paged endpoint `GET /v3/lockOverviewDtoView/search/findByKeyword`. Uses the safe optional-filter pattern (`... OR :clientNumber IS NULL OR :clientNumber = ''`). **No status filter.**
  - `findByClientOffsetAndLimit(keyword, filter, offset, limit)` — native SQL over `lock_overview_dto_view`, backs the Excel export. Safe native optional-filter (`COALESCE(...)=CAST(COALESCE(...) as TEXT) OR ?2 IS NULL`). **No status filter.**
- **Registration** `RestConfiguration.java:38` — `config.exposeIdsFor(..., LockOverviewDtoView.class, ...)`.

### 2.3 Excel export path

- **Controller** `controller/ReportController.java:84-107` — `@PostMapping("/exportLock")` under `@RequestMapping("/v3/report")`; reads untyped `reqMap` keys `offset, limit, filter, keyword`; streams an Excel file; calls `reportService.exporLockReport(response, offset, limit, filter, keyword)`.
- **Service** `service/ReportService.java:103-134` — `exporLockReport(...)` → `lockOverviewDtoViewRepository.findByClientOffsetAndLimit(...)`; row[0] = `BusinessObjectLockState.getCodeText(view.getStockunitlock())`; headers `{Stock Lock, SKU ID, SKU Name, Shipper/Brand, Amount, Location, Container, Parent Container}`.

### 2.4 Web UI

- **Component** `wms2-web-ui/components/reports/lockReport.vue` — `updateTable()` (l.365-387) dispatches `reports/lock/searchReport` with `{page, itemsPerPage, keyword, clientNumber, sortUrl}`. There is a **commented-out "Hide Unlocked/Shipper Stock" v-switch** (l.19-25) plus a dead `hide` data prop (l.164) and a `hide(newVal)` watcher that only `console.log`s (l.308-311) — the natural home for the new toggle. Columns (l.170-228) include "Stock Lock" (`stockLockText`). No status column, no working toggle.
- **Store** `wms2-web-ui/store/reports/lock.js` — `searchReport` (l.52-68) builds `GET /v3/lockOverviewDtoView/search/findByKeyword?page&size&state&keyword[&sort][&clientNumber]`. It appends `&state=` + `data.state`, but `data.state` is never populated, so the request currently sends the literal `state=undefined` (dead param). `export` (l.70-108) is `POST /v3/report/exportLock` with the same filters.

### 2.5 Migration / onboarding substrate (critical nuance)

Per `wms2-api/CLAUDE.md`:
- **Fresh v2 DB** is built from `db/migration/` (base dump `V2.2.00` + `V2.2.x` deltas). New deltas go in `db/migration/` as the next `V2.2.x`; highest present is **`V2.2.01`**, so this plan adds **`V2.2.02`**.
- **v1→v2 onboarding** of an existing client runs the `db/v1-to-v2-onboarding/schema/` toolkit, which *itself* (re)creates `lock_overview_dto_view` (`V1.2.04__utc_recreate_views.sql:136` holds the "verbatim latest definition").
- The **IT harness** (`AppPostgresDBSetupExtension`, `test/resources/flyway.conf`) scans `classpath:db/v1-to-v2-onboarding/schema` to build test schemas — so the onboarding scripts, not `db/migration/`, define what tests see.

**Consequence (CORRECTED 2026-07-16 — the VERIFY is now resolved):**

The db-dir reorg (commit `43384c0`, 2026-07-10) settled the "does onboarding replay `V2.2.x`?" question that this plan had left open. Per `db/v1-to-v2-onboarding/README.md`, `schema/` is **frozen at the `V2.1.16` watermark** — "that endpoint is exactly what the base dump `V2.2.00` captures … and both [fresh and converted DBs] continue on `V2.2.x+` deltas from `../migration/`." So:

- **(a) existing v2 tenants + (b) fresh v2 DBs + (c) onboarded v1 clients** all get the fix from **`db/migration/V2.2.02`**. For a converted v1 tenant, the UTC runbook's post-bridge step applies the `V2.2.x` deltas after the `V2.1.16` bridge (see `2-Areas/wms-utc-timezone-migration` §4 Phase C). **`V2.2.02` alone covers every production DB.**
- The **only** thing that still needs the change in the onboarding lineage is the **IT harness**: `src/test/resources/flyway.conf` scans *only* `classpath:db/v1-to-v2-onboarding/schema` and never applies `db/migration/V2.2.x`, so without a copy there the tests would build a schema that predates the fix.

**Therefore `V2.1.17` is a test-harness parity shim, NOT an onboarding requirement.** It is production-**redundant** with `V2.2.02`, and it technically pushes the onboarding lineage one delta past the `V2.1.16 == V2.2.00` watermark it is supposed to hold. It is retained here only because pointing the harness at `db/migration` is out of scope for this ticket.

**Recommended clean-up (follow-up, not required for this fix):** add `filesystem:db/migration` to the IT harness's `flyway.conf` (or otherwise apply the `V2.2.x` deltas in tests), then delete `V2.1.17` to restore the frozen watermark. Until then, keep `V2.2.02` and `V2.1.17` byte-identical (§5.1 #9).

---

## 3. Design

**Chosen approach — two-view design** (user-confirmed; single-view+query-param was explicitly rejected, see §9):

- **View A** `lock_overview_dto_view` gains `WHERE COALESCE(su.entity_lock,0) <> 405`. It becomes the **default** — the existing entity/repo (on-screen `findByKeyword`) and the Excel export (`findByClientOffsetAndLimit`) both read it and therefore **default-exclude Shipped with zero Java change to the default path**.
- **View B** `lock_overview_all_view` — identical SELECT, **no** `entity_lock` filter — backs the "Include Shipped Locks" toggle via a **new** mirror entity + repository.
- Only lock code **405** is excluded. Not Locked (0), To Delete (2), Picked (100), Quality Fault (103), On Hold (104), etc. remain visible.

`COALESCE(su.entity_lock, 0) <> 405` is used (not a bare `<> 405`) so any NULL `entity_lock` rows are retained in the default view — a bare `<> 405` would drop NULLs in three-valued logic.

### 3.1 Migration `V2.2.02__lock_report_exclude_shipped.sql` (row 1)

```sql
-- View A: default Lock Report — excludes Shipped (entity_lock = 405).
CREATE OR REPLACE VIEW public.lock_overview_dto_view AS
 SELECT row_number() OVER () AS row_id,
    su.id AS stockunitid, su.entity_lock AS stockunitlock, su.amount, su.reservedamount,
    i.item_nr AS itemnumber, i.name AS itemname,
    ul.labelid AS unitloadnumber, ul.entity_lock AS unitloadlock,
    loc.name AS locationname, carrier.labelid AS carriername, carrier.entity_lock AS carrierlock,
    c.name AS clientname, c.cl_nr AS clientnumber
   FROM stockunit su
     LEFT JOIN itemdata i  ON i.id = su.itemdata_id
     LEFT JOIN unitload ul ON ul.id = su.unitload_id
     LEFT JOIN location loc ON loc.id = ul.storagelocation_id
     LEFT JOIN unitload carrier ON carrier.id = ul.carrierunitload_id
     LEFT JOIN client c    ON c.id = su.client_id
  WHERE COALESCE(su.entity_lock, 0) <> 405
  ORDER BY su.created DESC, su.modified DESC;

-- View B: full Lock Report — every lock incl. Shipped. Backs the "Include Shipped Locks" toggle.
CREATE OR REPLACE VIEW public.lock_overview_all_view AS
 SELECT row_number() OVER () AS row_id,
    su.id AS stockunitid, su.entity_lock AS stockunitlock, su.amount, su.reservedamount,
    i.item_nr AS itemnumber, i.name AS itemname,
    ul.labelid AS unitloadnumber, ul.entity_lock AS unitloadlock,
    loc.name AS locationname, carrier.labelid AS carriername, carrier.entity_lock AS carrierlock,
    c.name AS clientname, c.cl_nr AS clientnumber
   FROM stockunit su
     LEFT JOIN itemdata i  ON i.id = su.itemdata_id
     LEFT JOIN unitload ul ON ul.id = su.unitload_id
     LEFT JOIN location loc ON loc.id = ul.storagelocation_id
     LEFT JOIN unitload carrier ON carrier.id = ul.carrierunitload_id
     LEFT JOIN client c    ON c.id = su.client_id
  ORDER BY su.created DESC, su.modified DESC;
```

`CREATE OR REPLACE VIEW` on `lock_overview_dto_view` keeps the column list byte-identical (required — replace cannot change column names/order), so the existing entity mapping is unaffected.

> **Why two entities/repos (not one entity + two native queries)?** Spring Data REST cannot expose two `@RepositoryRestResource` repositories over the **same** domain type without rel/path ambiguity, and the UI toggle needs two distinct HAL resources (`lockOverviewDtoView` vs `lockOverviewAllDtoView`) to switch endpoints. So the second entity+repo is **required**, not gratuitous. The cost is a real cross-directory maintenance tax: any future column added to the lock view must be applied in **two** view defs (`V2.2.02` migration **and** the `V2.1.17` onboarding delta), **two** entities, and **two** repos, or the resources silently diverge (the exact drift class fixed in `V2.2.01` for `replenishment_monitor_view`). §3.2.1 minimizes the Java half of that tax; §5.1#9 keeps the two SQL defs byte-identical.

### 3.2 New entity `LockOverviewAllDtoView` + shared `LockOverviewRow` interface (row 2)

`LockOverviewAllDtoView` is a byte-for-byte mirror of `LockOverviewDtoView` with `@Table(name="lock_overview_all_view")`. Same `@Id row_id`, same fields, same `columnDefinition` on the two `numeric(17,4)` fields.

#### 3.2.1 `LockOverviewRow` interface (avoids the compile trap in the row-builder)

The two entities share **no** supertype, so a shared export row-builder typed `List<? extends /*shared*/>` **will not compile** (there is nothing to bind the wildcard to). Extract a small interface declaring exactly the getters the Excel row-builder reads (`ReportService.java:114-121`):

```java
public interface LockOverviewRow {
    Integer getStockunitlock();
    String  getItemnumber();
    String  getItemname();
    String  getClientname();
    java.math.BigDecimal getAmount();
    String  getLocationname();
    String  getUnitloadnumber();
    String  getCarriername();
}
```

Both `LockOverviewDtoView` and `LockOverviewAllDtoView` `implements LockOverviewRow` (their existing getters already satisfy it — no getter changes). The shared row-builder is then typed `List<? extends LockOverviewRow>`, and `getCodeText(...)` label mapping lives in exactly one place.

### 3.3 New repository `LockOverviewAllDtoViewRepository` (row 3)

Mirror of `LockOverviewDtoViewRepository`, exposed at a distinct path:

```java
@RepositoryRestResource(collectionResourceRel = "lockOverviewAllDtoView", path = "lockOverviewAllDtoView")
public interface LockOverviewAllDtoViewRepository
        extends ReadOnlyPagingAndSortingRepository<LockOverviewAllDtoView, Long> {

    @RestResource(path = "findByKeyword", rel = "findByKeyword")
    @Query("""
    SELECT p FROM LockOverviewAllDtoView p
    WHERE ( :keyword = ''
        OR LOWER(p.itemname)       LIKE LOWER(CONCAT('%', :keyword, '%'))
        OR LOWER(p.itemnumber)     LIKE LOWER(CONCAT('%', :keyword, '%'))
        OR LOWER(p.clientname)     LIKE LOWER(CONCAT('%', :keyword, '%'))
        OR LOWER(p.unitloadnumber) LIKE LOWER(CONCAT('%', :keyword, '%'))
        OR LOWER(p.locationname)   LIKE LOWER(CONCAT('%', :keyword, '%'))
        OR LOWER(p.carriername)    LIKE LOWER(CONCAT('%', :keyword, '%')) )
    AND (p.clientnumber = :clientNumber OR :clientNumber IS NULL OR :clientNumber = '')
    """)
    Page<LockOverviewAllDtoView> findByKeyword(@Param("keyword") String keyword,
                                               @Param("clientNumber") String clientNumber, Pageable p);

    @RestResource(path = "findByClientOffsetAndLimit", rel = "findByClientOffsetAndLimit")
    @Query(value = "SELECT p.* FROM lock_overview_all_view p " +
        "WHERE (CONCAT(LOWER(p.itemname),' ',LOWER(p.itemnumber),' ',LOWER(p.clientname),' ',LOWER(p.unitloadnumber),' ',LOWER(p.locationname),' ',LOWER(p.carriername)) LIKE LOWER(concat('%', ?1,'%')) or ?1 = '') " +
        "AND (COALESCE(p.clientnumber,'') = CAST(COALESCE(?2,'') as TEXT) OR ?2 IS NULL) " +
        "OFFSET ?3 LIMIT ?4", nativeQuery = true)
    List<LockOverviewAllDtoView> findByClientOffsetAndLimit(String keyword, String filter, int offset, int limit);
}
```

Both queries preserve the project's mandatory safe optional-filter patterns (JPQL: `OR :param = ''`; native: `COALESCE ... CAST ... OR ?n IS NULL`) per `wms2-api/CLAUDE.md` "Query Patterns".

### 3.4 Registration (row 4)

`RestConfiguration.java:38` — add `LockOverviewAllDtoView.class` to the `exposeIdsFor(...)` list so `row_id` is exposed on the HAL resource, matching the existing view.

### 3.5 Excel export toggle (rows 5–6)

- `ReportController.exportLock` reads `Boolean includeShipped = (Boolean) reqMap.get("includeShipped");` (treat null as `false`) and passes it: `reportService.exporLockReport(response, offset, limit, filter, keyword, includeShipped)`.
- `ReportService.exporLockReport(...)` gains a trailing `boolean includeShipped` param. Inject `LockOverviewAllDtoViewRepository`. Branch:
  ```java
  List<? extends /* shared shape */> views = includeShipped
      ? lockOverviewAllDtoViewRepository.findByClientOffsetAndLimit(keyword, filter, offset, limit)
      : lockOverviewDtoViewRepository.findByClientOffsetAndLimit(keyword, filter, offset, limit);
  ```
  Both branches feed a single shared row-builder `List<Object[]> buildRows(List<? extends LockOverviewRow> views)` (§3.2.1), so the Excel column set/order and the `getCodeText(...)` label logic are defined **once** and cannot drift between the two paths. `ReportService` currently has **no** `@Transactional` at all — add `@Transactional(value="tenantTransactionManager", readOnly=true)` to the read path (definite step, not conditional).

### 3.6 Web UI toggle (rows 11–12)

- `lockReport.vue`: replace the dead `hide` control with an **"Include Shipped Locks"** `v-switch` bound to a new `includeShipped` data prop (default `false`). Its watcher calls `updateTable()` (reset to page 1). Thread `includeShipped` into the export dispatch.
- `store/reports/lock.js`:
  - `searchReport`: choose the base resource — `lockOverviewAllDtoView` when `includeShipped` is true, else `lockOverviewDtoView` — for `/search/findByKeyword`. **Also switch the `_embedded.<rel>` key** used to read rows out of the HAL response: `results._embedded.lockOverviewDtoView` vs `results._embedded.lockOverviewAllDtoView` (`lock.js:63`) — the all-view resource returns rows under its own `collectionResourceRel`, so reading the old key yields `undefined`. Remove the dead `&state=undefined` param.
  - `export`: include `includeShipped` in the `POST /v3/report/exportLock` body.

---

## 4. File Change Summary

| File | Change | Description |
|---|---|---|
| `wms2-api .../db/migration/V2.2.02__lock_report_exclude_shipped.sql` | **Add** | Two `CREATE OR REPLACE VIEW`: default excludes 405, all-view unfiltered |
| `wms2-api .../model/LockOverviewAllDtoView.java` | **Add** | Mirror entity mapped to `lock_overview_all_view`; `implements LockOverviewRow` |
| `wms2-api .../model/LockOverviewRow.java` | **Add** | Shared interface (8 getters) implemented by both view entities; unblocks the shared row-builder |
| `wms2-api .../model/LockOverviewDtoView.java` | **Modify** | Add `implements LockOverviewRow` (no getter changes) |
| `wms2-api .../repo/jpa/LockOverviewAllDtoViewRepository.java` | **Add** | REST resource `lockOverviewAllDtoView` + `findByKeyword` + `findByClientOffsetAndLimit` |
| `wms2-api .../RestConfiguration.java` | **Modify** | Add `LockOverviewAllDtoView.class` to `exposeIdsFor` |
| `wms2-api .../controller/ReportController.java` | **Modify** | Read `includeShipped`, pass to service |
| `wms2-api .../service/ReportService.java` | **Modify** | `includeShipped` param + repo branch + shared `buildRows(List<? extends LockOverviewRow>)` + `@Transactional(readOnly=true)` |
| `wms2-api .../db/v1-to-v2-onboarding/schema/V2.1.17__lock_report_exclude_shipped.sql` | **Add** | Onboarding + IT-harness parity: byte-identical copy of `V2.2.02` (excluding default view + all-view). No edit to `V1.2.04`/`V1.0.02`/`V1.1.01` |
| `wms2-api .../unit/service/ReportServiceUnitTest.java` | **Modify** | `includeShipped` true/false branch tests |
| `wms2-web-ui components/reports/lockReport.vue` | **Modify** | "Include Shipped Locks" toggle + reload watcher |
| `wms2-web-ui store/reports/lock.js` | **Modify** | Endpoint switch + export flag; drop dead `state` param |

---

## 5. Prerequisites & Phased Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **Database state** | v2 tenant DB at ≥ `V2.2.01`; `V2.2.02` is the next delta | Verify highest `V2.2.*` in `db/migration/` before authoring (currently `V2.2.01`) |
| 2 | **Feature flags / system properties** | N/A | Behavior is view-driven + additive param; no sysprop toggle introduced |
| 3 | **Config / env changes** | N/A | No properties/jasypt/keycloak changes |
| 4 | **Deploy-order dependencies** | Ship `wms2-api` (Phase 1) **before** `wms2-web-ui` (Phase 2) | UI toggle calls the new `lockOverviewAllDtoView` resource; if UI ships first, "Include Shipped" 404s. Phase 1 alone is safe (default already excludes shipped) |
| 5 | **Data migration** | None — no data mutated | Shipped rows are retained; only view definitions change |
| 6 | **External systems** | N/A | No OMS/printer/Keycloak interaction |
| 7 | **Access / permissions** | Authority is **`wms_user`** (`SecurityConfiguration.java:133` gates `/v3/**` with `hasAnyAuthority("wms_user")`; lock resources are **not** in the admin-only list at `:127-130`) | The new `/v3/lockOverviewAllDtoView/**` inherits the **same** `wms_user` gate as `lockOverviewDtoView` — parity preserved, not public. (There is no report-specific role in this codebase; both views are readable by any warehouse user — the existing posture, not a regression.) Resolves Q3 |
| 8 | **Monitoring / alerts** | N/A | Read-only report; no new metric required |
| 9 | **IT-harness parity** (was "onboarding parity") | Add `db/v1-to-v2-onboarding/schema/V2.1.17__lock_report_exclude_shipped.sql`, byte-identical to `V2.2.02` | **VERIFY resolved (§2.5):** `src/test/resources/flyway.conf` scans **only** `db/v1-to-v2-onboarding/schema` (highest `V2.1.16`, no `V2.2.x`), so the harness needs the copy. **Production is covered by `V2.2.02` alone** — migrated tenants apply `V2.2.x` post-bridge, so `V2.1.17` is production-redundant. `V2.1.17` orders after `V1.2.04`. **Do NOT edit `V1.2.04` in place** (checksum drift). Follow-up: point harness at `db/migration` and drop `V2.1.17` |

### 5.2 Phase 1 — Backend (`wms2-api`)

**Goal:** default Lock Report + Excel export exclude Shipped; new all-view resource + export flag enable "Include Shipped".
**Branch:** `feature/SBDEV-2474-lock-report-exclude-shipped` (off `develop`).
**Changes:** rows 1–6, 9, 10 of §0.
**Testing:** `ReportServiceUnitTest` (both branches, mocked repos); `mvn clean compile`; `mvn test -Dtest=ReportServiceUnitTest`. Testcontainers ITs remain `@Disabled` (SBDEV-2217 — harness cannot boot); add a lock-report IT stub `@Disabled("TODO SBDEV-2217: IT harness cannot boot")` documenting the intended view-level assertion. SQL sanity is verified manually against `wineco-dev` (§6 manual plan).
**Risk:** Low — additive; default path change is a single view predicate.
**Effort:** ~0.5 day.

**Steps:**
- [ ] Add `db/migration/V2.2.02__lock_report_exclude_shipped.sql` (two views).
- [ ] Add `db/v1-to-v2-onboarding/schema/V2.1.17__lock_report_exclude_shipped.sql` — **byte-identical** copy of `V2.2.02` (do NOT edit `V1.2.04`).
- [ ] Add `LockOverviewRow` interface (8 getters).
- [ ] Add `LockOverviewAllDtoView` entity (mirror), `implements LockOverviewRow`.
- [ ] Add `implements LockOverviewRow` to `LockOverviewDtoView` (no getter changes).
- [ ] Add `LockOverviewAllDtoViewRepository` (path `lockOverviewAllDtoView`, both queries, safe filter patterns).
- [ ] Register `LockOverviewAllDtoView.class` in `RestConfiguration.java:38`.
- [ ] Thread `includeShipped` through `ReportController.exportLock` → `ReportService.exporLockReport`; inject all-view repo; extract shared `buildRows(List<? extends LockOverviewRow>)`.
- [ ] Add `@Transactional(value="tenantTransactionManager", readOnly=true)` on the read path (none exists today).
- [ ] `ReportServiceUnitTest`: assert default branch calls `lockOverviewDtoViewRepository`, include-shipped branch calls `lockOverviewAllDtoViewRepository`; assert `includeShipped` null → default; **assert the exported row has all 8 columns in order** (`getCodeText(stockunitlock), itemnumber, itemname, clientname, amount, locationname, unitloadnumber, carriername`) so the row-builder refactor cannot silently reorder the Excel output.
- [ ] Run `mvn clean compile` + `mvn test -Dtest=ReportServiceUnitTest`; run verify script.

### 5.3 Phase 2 — Web UI (`wms2-web-ui`)

**Goal:** surface the "Include Shipped Locks" toggle; wire the store to the two resources + export flag.
**Branch:** `feature/SBDEV-2474-lock-report-include-shipped-toggle`.
**Changes:** rows 11–12 of §0. **Prereq:** Phase 1 deployed to the target env.
**Testing:** `yarn jest` for `store/reports/lock.js` (endpoint selection) if a store spec exists; otherwise manual click-path (§6). Verify default view hides shipped, toggle shows them, export matches the toggle.
**Risk:** Low. **Effort:** ~0.5 day.

**Steps:**
- [ ] Add `includeShipped` data prop + "Include Shipped Locks" `v-switch` (reuse the dead `hide` slot); watcher → `updateTable()` (page 1).
- [ ] `store/reports/lock.js`: endpoint switch in `searchReport`; drop dead `state` param; add `includeShipped` to export body.
- [ ] Manual click-path smoke on staging.

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| Default on-screen report (`findByKeyword`) | all locks incl. Shipped | Shipped (405) hidden | **Intended behavior change** (the ticket) |
| Default Excel export (`/v3/report/exportLock`) | all locks incl. Shipped | Shipped hidden unless `includeShipped=true` | **Intended** (export parity) |
| `exportLock` request body | `offset,limit,filter,keyword` | + optional `includeShipped` (null → false) | **Additive** — existing callers unaffected |
| `lock_overview_dto_view` columns | 14 cols | same 14 cols, `WHERE` added | Entity mapping unchanged |
| New `lock_overview_all_view` / `lockOverviewAllDtoView` resource | — | new | **Additive** |
| Shipped lock rows in DB | present | present (untouched) | **No data change** |
| Error-response shape `{errors:[...]}` | unchanged | unchanged | None |

**What does NOT change:** the `LockOverviewDtoView` entity and its repository; the `exportLock` HTTP path, method, and Excel column set; the lock-code→label mapping (`getCodeText`); the `{errors:[...]}` error contract; UI auth/Vuex/axios wiring; all non-405 lock rows remain visible; no stock data is mutated or deleted.

---

## 7. Testing Strategy

### 7.1 Unit (`ReportServiceUnitTest`)
- `exporLockReport(..., includeShipped=false)` → invokes `lockOverviewDtoViewRepository.findByClientOffsetAndLimit`, never the all-view repo.
- `exporLockReport(..., includeShipped=true)` → invokes `lockOverviewAllDtoViewRepository.findByClientOffsetAndLimit`.
- Controller-level: `includeShipped` absent in `reqMap` → service receives `false`.
- Assert the exported row has **all 8 columns in order**: `getCodeText(stockunitlock)`, `itemnumber`, `itemname`, `clientname`, `amount`, `locationname`, `unitloadnumber`, `carriername` — pins the Excel output against a silent reorder during the `buildRows` refactor.

### 7.2 Integration (Testcontainers)
Blocked by **SBDEV-2217** (Postgres IT lane cannot boot). Add `LockOverviewViewIT` `@Disabled("TODO SBDEV-2217")` asserting: default view has 0 rows with `stockunitlock=405`; all-view has ≥1 such row given a seeded shipped stock unit. Gate Phase 1 on unit tests + `mvn clean compile`.

> **Coverage gap disclosed honestly:** the core behavioral change (default view excludes 405) has **no automated coverage** — unit tests only assert *which repo* is called (repos are mocked), and the view-predicate IT is `@Disabled` under SBDEV-2217. The **only** thing that verifies the feature actually works is the §7.3 SQL sanity check — which is therefore a **required release gate**, not optional.

### 7.3 Manual test plan (§7.3 SQL sanity rows are a REQUIRED release gate — see §7.2)

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Default report hides shipped | staging UI (wineco UAT) | Open `/reports/lock-report` (toggle OFF) | No rows with Stock Lock = "Shipped"; row count ≈ non-shipped total | |
| Toggle shows shipped | staging UI | Turn "Include Shipped Locks" ON | Shipped rows appear; count jumps toward full total | |
| Export parity (default) | staging UI | Export with toggle OFF | Excel has no "Shipped" rows | |
| Export parity (include) | staging UI | Export with toggle ON | Excel includes "Shipped" rows | |
| Keyword + client filter still work | staging UI | Search keyword + pick shipper, both toggle states | Filters apply on both views | |
| SQL sanity — default view | staging DB | `SELECT count(*) FILTER (WHERE stockunitlock=405) FROM lock_overview_dto_view;` | `0` | |
| SQL sanity — all view | staging DB | `SELECT count(*) FILTER (WHERE stockunitlock=405) FROM lock_overview_all_view;` | `> 0` | |

### 7.4 Test execution

**TDD gate baseline captured 2026-07-14** (pre-implementation, wms-tdd-gate):

| Command | Result | Pass/Fail/Skipped |
|---|---|---|
| `mvn clean test-compile` | exit 0 | compiles |
| `mvn test -Dtest='ReportServiceUnitTest$ExporLockReportIncludeShipped'` | exit 1 | **1 pass / 2 fail** (RED baseline as designed) |
| `bash sbdocs/9-System/scripts/verify-...-shipped-locks.sh` (pre-impl) | exit 1 | 2 pass / 21 fail |

Failing tests are the implementation contract (both assertion-red, failing for the right reason — the `includeShipped` branch is unimplemented):
- `exporLockReport_shouldQueryAllViewRepo_whenIncludeShippedTrue` — FAIL "zero interactions" with the all-view repo.
- `exporLockReport_shouldPreserveEightColumnOrder_whenIncludeShippedTrue` — FAIL "Expected size: 1 but was: 0".
- `exporLockReport_shouldQueryDefaultRepo_whenIncludeShippedFalse` — PASS (default-routing guard; green now and after).

Completion command (turns the gate green): `mvn test -Dtest='ReportServiceUnitTest$ExporLockReportIncludeShipped'` → 3 pass.

**Inert TDD scaffolding currently in the `v2/wms2-api` working tree** (uncommitted; the behavioral fix is NOT implemented): new `model/LockOverviewRow.java`, `model/LockOverviewAllDtoView.java`, `repo/jpa/LockOverviewAllDtoViewRepository.java`; `LockOverviewDtoView implements LockOverviewRow`; an **inert** 6-arg `ReportService.exporLockReport(...,includeShipped)` overload (delegates to 5-arg, ignores the flag — replace with the real all-view branch + shared `buildRows`); new tests in `ReportServiceUnitTest`; `@Disabled` `LockOverviewViewIT` stub.

**Post-implementation results (2026-07-15, branch `feature/SBDEV-2474-lock-report-exclude-shipped`):**

| Command | Result | Pass/Fail/Skipped |
|---|---|---|
| `mvn clean test -Dtest='ReportServiceUnitTest,ReportControllerUnitTest,OmsNotificationConfigContextLoadTest'` | BUILD SUCCESS | **77 run, 0 fail, 0 err** |
| `ReportServiceUnitTest$ExporLockReportIncludeShipped` (the 3 gate tests) | pass | 3/0 |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2474-lock-report-exclude-shipped-locks.sh` | pass | **24 pass, 0 fail, 1 skip** |
| §7.3 SQL gate (predicate validated on live wineco-dev data, views not yet applied) | pass | default-view shipped=**0**, all-view shipped=**1,392,648**, default total=**229,835** |
| Code review (oh-my-claudecode:code-reviewer) | 1 HIGH + 2 MEDIUM fixed | HIGH: stale controller test → updated to 6-arg + added includeShipped test; MED: UI double-fetch fixed; MED: removed `@Transactional` (connection-pinning) — read path matches sibling exports |

Implemented on branch `feature/SBDEV-2474-lock-report-exclude-shipped` in both `wms2-api` and `wms2-web-ui`. Docs updated: function-to-docs-map, landlord-vs-tenant-entity-map, entity-enumeration-report.

**PRs (→ `develop`):**
- wms2-api: [PR #77](https://github.com/SiteBossInc/wms2-api/pull/77) (commit `4796cda`)
- wms2-web-ui: [PR #21](https://github.com/SiteBossInc/wms2-web-ui/pull/21) (commit `0e5efc6`) — **merge after** #77 (toggle depends on the new resource).

**Post-merge:** run the §7.3 SQL gate against each target tenant DB after the V2.2.02 view is applied (operator step; the running app does not invoke Flyway).

---

## 7A. v2-only Constraint Checklist

| # | Constraint | Verdict | Where addressed |
|---|---|---|---|
| 1 | OSIV disabled | Yes | Flat view entities, no lazy associations; read path made `@Transactional(readOnly=true)` (§3.5). DTO-shaped, no lazy access outside tx |
| 2 | Transaction manager | Yes | Read path uses `tenantTransactionManager` (§3.5); no landlord write |
| 3 | `@Transactional(readOnly=true)` | Yes | Added to the export read path (§3.5) |
| 4 | Caffeine cache invalidation | N/A | No cached entity written; report is read-only over views |
| 5 | Micrometer metrics | N/A | Read-only report; reuse none; no high-frequency job path |
| 6 | Jakarta namespace | Yes | New entity uses `jakarta.persistence.*` (mirrors existing) |
| 7 | H2-compatible test SQL | Yes | Unit tests mock repos (no H2 view needed); native query changes only run under Postgres/Testcontainers (@Disabled) |
| 8 | `BaseControllerTest` for endpoints | Yes | `exportLock` signature changes — add/adjust a controller test asserting `includeShipped` pass-through (or cover via `ReportServiceUnitTest` + a thin controller test) |

## 7B. Horizontal Scalability Validation (v2 — mandatory)

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | No cache/map/static/ThreadLocal added |
| 2 | Connection pool math | No | Two extra read queries reuse the tenant pool; no new pool/tenant |
| 3 | Scheduled jobs | No | No `@Scheduled` added |
| 4 | Long transactions | No | Short read-only query per request; no external I/O in tx |
| 5 | Request affinity | No | Stateless REST; toggle state lives in the browser |
| 6 | Retry / idempotency | N/A | Read-only; safe to retry |
| 7 | Tenant context | No | Standard request-scoped tenant routing; no async boundary |
| 8 | Distributed lock correctness | N/A | No pessimistic/optimistic lock added |
| 9 | Cache invalidation | N/A | Nothing cached |
| 10 | External notifications | No | None |

No "Yes" rows → no scalability evidence table required.

---

## 8. Rollout Plan

1. **Phase 1 (`wms2-api`)**: branch `feature/SBDEV-2474-lock-report-exclude-shipped` → PR to `develop` → `dev-*` tag → QA → `qa-*`/`ua-*`. `V2.2.02` applies on the next operator-run migration (the running app does not invoke Flyway). Default report/export exclude shipped immediately; the new resource is dormant until the UI ships.
2. **Phase 2 (`wms2-web-ui`)**: branch `feature/SBDEV-2474-lock-report-include-shipped-toggle` → PR → deploy **after** Phase 1 is live in the target env.
3. **Rollback:** re-apply the original (unfiltered) `lock_overview_dto_view` definition via a follow-up `V2.2.x` (or `CREATE OR REPLACE` back to the base def) and revert the UI. No data restore needed — shipped rows were never removed.

---

## 9. Alternatives Considered

| Option | Description | Why rejected |
|---|---|---|
| **Single view + `includeShipped` query param** | Keep one unfiltered view; add `AND (:includeShipped = true OR p.stockunitlock <> 405)` to `findByKeyword` and the export query; toggle flips the param | **Rejected by user** in favor of the two-view design. (Trade-off noted: fewer DB objects, but the default path keeps scanning the full 1.6M-row view and relies on every query remembering the predicate.) |
| **Hard-exclude in the view, no toggle** | Bake `WHERE entity_lock <> 405` into the single view and ship no UI toggle | Rejected — shipped locks become unreachable through the report (audit/troubleshooting need), contradicting the ticket's "remain available historically". |
| **Client-side filter only** | Drop shipped rows in the Vue component | Rejected — still fetches ~1.6M rows, so it fixes neither load time nor the performance complaint; also fragile against pagination. |

**Chosen:** two-view design — default view hard-excludes 405 (fast, cannot be "forgotten" by a query author), a separate full view + resource serves the explicit include-shipped path, and the Excel export mirrors the toggle.

---

## 10. Open Questions / Resolved Decisions

**Resolved (user-confirmed):**
1. **Scope** — v2 only; backend + web UI toggle.
2. **Mechanism** — two-view design (View A excludes 405, View B unfiltered); single-view+param rejected.
3. **Export parity** — Excel export defaults to excluding shipped, switches with `includeShipped`.
4. **Exclusion set** — **Only Shipped (405)**. (The 4th clarifying question returned no explicit answer; defaulted to the ticket's literal ask. Not-Locked/To-Delete stay visible. Revisit only if operators still find the report noisy.)

**Resolved during consensus review:**
- **Q3 (auth) — RESOLVED:** `SecurityConfiguration.java:133` gates `/v3/**` with `hasAnyAuthority("wms_user")`; lock resources are not in the admin-only list (`:127-130`). The new `/v3/lockOverviewAllDtoView/**` inherits the same `wms_user` gate — parity preserved, not public. (Prereq §5.1#7 corrected accordingly.)
- **Q1 (onboarding) — RESOLVED (corrected 2026-07-16):** the reorg (`43384c0`) froze `db/v1-to-v2-onboarding/schema/` at the `V2.1.16` watermark; migrated tenants continue on `db/migration/V2.2.x` post-bridge, so **`V2.2.02` alone covers all production DBs.** `V2.1.17` is a **test-harness shim** (the harness scans only `schema/`), not an onboarding requirement, and is production-redundant. Follow-up ticket: point the harness at `db/migration` and delete `V2.1.17` to restore the frozen watermark. See §2.5 and the UTC runbook §4 Phase C ("post-bridge `V2.2.x` parity").

**Open (close during implementation):**
- **Q2:** Should the on-screen default page size / `ORDER BY su.created DESC` stay as-is? (No change proposed; confirm no perf regression now that the default view is 86% smaller — expected to improve.)
- **Q4 (pre-existing, out of scope):** `row_id = row_number() OVER ()` has no stable ordering, so it is re-assigned per query — a latent OFFSET/LIMIT page-tearing risk on `created`/`modified` ties (already flagged in `LockOverviewDtoViewRepository.java:65`). Adding the `WHERE` renumbers and shrinks the id space but neither fixes nor worsens this. Do **not** rely on `row_id` stability; tracked as pre-existing debt, not in SBDEV-2474 scope.

---

## 9-Acceptance. Acceptance & Implementation

### Acceptance script (machine-checkable)
`sbdocs/9-System/scripts/verify-SBDEV-2474-lock-report-exclude-shipped-locks.sh` — POSITIVE checks:
- `db/migration/V2.2.02__lock_report_exclude_shipped.sql` exists and contains `lock_overview_dto_view` with `<> 405` **and** `lock_overview_all_view`;
- **onboarding parity (row 9):** `db/v1-to-v2-onboarding/schema/V2.1.17__lock_report_exclude_shipped.sql` exists and contains both `lock_overview_dto_view` with `<> 405` and `lock_overview_all_view`;
- `LockOverviewRow` interface exists; `LockOverviewAllDtoView` + `LockOverviewDtoView` both `implements LockOverviewRow`;
- new repo file exists with `path = "lockOverviewAllDtoView"`; `RestConfiguration` references `LockOverviewAllDtoView`;
- `ReportService.exporLockReport` signature has `includeShipped`; `ReportController` reads `includeShipped`;
- UI store references `lockOverviewAllDtoView` and `_embedded.lockOverviewAllDtoView`; `lockReport.vue` has an include-shipped toggle.

NEGATIVE checks:
- the default repo's **active** (non-commented) native `@Query` still targets `lock_overview_dto_view` and does **not** reference `lock_overview_all_view` — scope the grep to the active `@Query` line (there is a commented-out query at `LockOverviewDtoViewRepository.java:51` that also names the view, so a naive grep false-passes); assert absence of `lock_overview_all_view` in the default repo file instead;
- UI store no longer sends `state=undefined`.

Plus `mvn_test_passes ReportServiceUnitTest`.

**Required release gate (beyond the script):** the §7.3 SQL sanity check — `SELECT count(*) FILTER (WHERE stockunitlock=405) FROM lock_overview_dto_view` = 0 and `... FROM lock_overview_all_view` > 0 against a real tenant DB — is the only verification of the actual behavioral change (see §7.2) and must pass before release.

### Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | ~10 sites across one backend subsystem + a thin UI change |
| Pre-draft step | analyst/architect (done) | Investigation + DB verification complete |
| Plan-review step | **critic** | Consensus review via ralplan (this document) |
| Implementation shape | **executor** (Phase 1), then **executor** (Phase 2) | Bounded, sequential; verify script as gate |
| Verification step | verify-script + verifier | Mandatory |
| Code-review step | code-reviewer | Native SQL + view change warrant a review pass |
| Commit step | git-master | Two repos, two logical commits |
