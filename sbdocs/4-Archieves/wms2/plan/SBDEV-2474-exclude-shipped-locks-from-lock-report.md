---
title: "SBDEV-2474 — Exclude Shipped Locks from Default Lock Report View (V2)"
ticket: "SBDEV-2474"
ticket_url: "https://app.clickup.com/t/868k3kr3b"
type: "enhancement"
priority: "normal"
status: "superseded"
superseded_by: "[[SBDEV-2474-lock-report-exclude-shipped-locks]] (two-view design; merged wms2-api PR #77 + wms2-web-ui PR #21 → develop 2026-07-16)"
project: [wms2]
version: "v2"
requester: "Brent Campbell"
created: "2026-07-04"
updated: "2026-07-25"
related:
  - "[[wms2-function-to-docs-map]]"
  - "[[wms2-landlord-vs-tenant-entity-map]]"
tags:
  - plan
  - reports
  - lock-report
---

# SBDEV-2474 — Exclude Shipped Locks from Default Lock Report View (V2)

**Ticket:** [SBDEV-2474](https://app.clickup.com/t/868k3kr3b)
**Project:** wms2 | **Version:** v2 | **Type:** enhancement (reports usability + performance)
**Priority:** normal (Effort 1 / Impact 2 / size S per ClickUp)
**Status:** draft
**Date:** 2026-07-04

> **Scope decision:** V2 only (`v2/wms2-api` + `v2/wms2-web-ui`). The ticket flags V1 too; the view/query structure is near-identical in v1, but this plan deliberately does not port. See §4.
> **Approach decision:** Query-level filter with an optional `includeShipped` toggle (default = exclude shipped). Not a DB-view `WHERE`. See §3 for the trade-off that drove this.

---

## 1. Problem Statement

The Lock Report (`/reports/lock-report`) lists inventory/warehouse locks so users can act on damaged inventory, holds, active locks, and exceptions. It currently returns **every stock unit**, including all historically **shipped** units, which retain their lock code forever. On WineCo UAT this is ~**1,846,671 rows**, the overwhelming majority of which are shipped and non-actionable.

**User-visible symptoms:**
- Report is dominated by shipped/historical rows; actionable locks are buried.
- Slow load / large payloads; degraded usability for warehouse users.

**Expected behavior:** the default view excludes shipped locks; shipped data stays in the DB and can be surfaced via an opt-in filter.

**DB-verified (wms2-wineco-dev, `dev_wh01_om1`, 2026-07-04)** — `lock_overview_dto_view` distribution:

| `stockunitlock` | meaning | rows | share |
|---|---|---:|---:|
| 405 | Shipped | 1,392,645 | **85.9%** |
| 2 | To Delete | 210,158 | 13.0% |
| 0 | Not Locked | 16,988 | 1.0% |
| 100 | Picked | 525 | <0.1% |
| 103 | Quality Fault | 269 | <0.1% |
| 104 | On Hold | 2 | <0.1% |
| — | **total** | **1,620,587** | |

Excluding shipped removes 85.9% of rows. Note: after that, the remainder is still ~92% "To Delete" and ~7.5% "Not Locked"; only 796 rows are genuinely actionable (Picked/Quality Fault/On Hold) — see §8 scope note.

**What the default view looks like after the shipped-only exclusion (`stockunitlock <> 405`):**

| `stockunitlock` | meaning | rows | share of default view |
|---|---|---:|---:|
| 2 | To Delete | 210,158 | 92.2% |
| 0 | Not Locked | 16,988 | 7.5% |
| 100 | Picked | 525 | 0.2% |
| 103 | Quality Fault | 269 | 0.1% |
| 104 | On Hold | 2 | <0.1% |
| — | **total remaining** | **227,942** | (from 1,620,587) |

**Queries used** (read-only, against `wms2-wineco-dev` / `dev_wh01_om1`):

```sql
-- Totals + shipped share
SELECT COUNT(*) AS total_rows,
       COUNT(*) FILTER (WHERE stockunitlock = 405) AS shipped_rows,
       COUNT(*) FILTER (WHERE stockunitlock <> 405 OR stockunitlock IS NULL) AS actionable_rows,
       ROUND(100.0 * COUNT(*) FILTER (WHERE stockunitlock = 405) / NULLIF(COUNT(*),0), 1) AS pct_shipped
FROM lock_overview_dto_view;

-- Full distribution by lock state
SELECT stockunitlock, COUNT(*) AS rows
FROM lock_overview_dto_view
GROUP BY stockunitlock ORDER BY COUNT(*) DESC;
```

> Caveat: numbers are from the **dev** DB (`dev_wh01_om1`), not WineCo UAT (where the ticket cites ~1,846,671). The *shape* (shipped ≈ 86% dominant) is expected to hold in UAT/prod; re-run against the target env before sign-off if exact figures matter.

---

## 2. Root Cause Analysis

The Lock Report applies **no lock-state filter at any layer**. A "shipped lock" is a stock unit whose lock code is `405` (`WmsConstants.BusinessObjectLockState.SHIPPED`, rendered "Shipped"). Because shipped units keep `entity_lock = 405` indefinitely and nothing filters them, they accumulate without bound.

**Data model.** The report is backed by the DB view `lock_overview_dto_view`, mapped by entity `LockOverviewDtoView`. The `stockunitlock` column is `stockunit.entity_lock`:

```sql
-- V1.2.04__utc_recreate_views.sql:136
CREATE OR REPLACE VIEW public.lock_overview_dto_view AS
SELECT row_number() OVER () AS row_id,
       su.id AS stockunitid,
       su.entity_lock AS stockunitlock,   -- <-- 405 == SHIPPED
       su.amount, su.reservedamount,
       i.item_nr AS itemnumber, i.name AS itemname,
       ul.labelid AS unitloadnumber, ul.entity_lock AS unitloadlock,
       loc.name AS locationname,
       carrier.labelid AS carriername, carrier.entity_lock AS carrierlock,
       c.name AS clientname, c.cl_nr AS clientnumber
FROM stockunit su
       LEFT JOIN itemdata i  ON i.id  = su.itemdata_id
       LEFT JOIN unitload ul ON ul.id = su.unitload_id
       LEFT JOIN location loc ON loc.id = ul.storagelocation_id
       LEFT JOIN unitload carrier ON carrier.id = ul.carrierunitload_id
       LEFT JOIN client c    ON c.id  = su.client_id
ORDER BY su.created desc, su.modified desc;   -- NOTE: no WHERE clause
```

**Lock code.** `WmsConstants.BusinessObjectLockState` (class at `service/WmsConstants.java:1160`; `SHIPPED = 405` at `:1172`; `getCodeText` at `:1174`): `NOT_LOCKED=0`, `GOING_TO_DELETE=2`, `PICKED_FOR_GOODSOUT=100`, `QUALITY_FAULT=103`, `ON_HOLD=104`, `NOT_FOUND=403`, `TRANSFER=404`, **`SHIPPED=405`**.

**Two consumer paths, neither filters:**
1. **On-screen** — UI `store/reports/lock.js:61` calls Spring Data REST endpoint `GET /lockOverviewDtoView/search/findByKeyword`, backed by `LockOverviewDtoViewRepository.findByKeyword` (JPQL): filters `keyword` + `clientNumber` only.
2. **Excel export** — UI `store/reports/lock.js:87` POSTs `/report/exportLock` → `ReportController.exportLock:84` → `ReportService.exporLockReport:103` → `LockOverviewDtoViewRepository.findByClientOffsetAndLimit` (native SQL): filters `keyword` + `client` only.

**Dead param.** The UI store builds `...&state=' + data.state` (`lock.js:54`), but the component never passes `state` and `findByKeyword` never binds it — it's a no-op (`state=undefined`, ignored by Spring Data REST). It will be replaced by the real `includeShipped` param.

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `v2/wms2-api/.../repo/jpa/LockOverviewDtoViewRepository.java` | 22–40 | `findByKeyword` JPQL — add `includeShipped` param + shipped predicate |
| 2 | `v2/wms2-api/.../repo/jpa/LockOverviewDtoViewRepository.java` | 42–47 | `findByClientOffsetAndLimit` native SQL — add `includeShipped` param + shipped predicate |
| 3 | `v2/wms2-api/.../service/ReportService.java` | 103–110 | `exporLockReport` — thread `includeShipped` through to the repo |
| 4 | `v2/wms2-api/.../controller/ReportController.java` | 84–97 | `exportLock` — read `includeShipped` from request map (default false) |
| 5 | `v2/wms2-web-ui/store/reports/lock.js` | 54, 87 | Replace dead `state` param with `includeShipped`; add to export payload |
| 6 | `v2/wms2-web-ui/components/reports/lockReport.vue` | ~26–60, ~360–383 | Add "Include Shipped" toggle; pass `includeShipped` on search + export |

---

## 3. Design / Proposed Fix

Default behavior everywhere: **exclude `stockunitlock = 405`**. An optional `includeShipped=true` restores the historical set. `NULL`/absent param is treated as `false` (exclude), so existing callers get the new default automatically.

> **Why query-level and not a view `WHERE`.** Filtering inside the view (`WHERE su.entity_lock <> 405`) is the only change that shrinks the underlying scan and gives a full performance win, but it removes shipped rows from the view entirely — leaving no path for a future "Include Shipped" toggle without a second view. The ticket explicitly wants shipped data retained and an optional filter, so we filter at the query with a toggle. **Honest limitation:** the view computes `row_number() OVER ()` across the whole `stockunit` table *before* any outer `WHERE`, so the scan cost is unchanged; the count query and page/export payloads shrink, but raw scan time does not. This satisfies the usability criterion strongly and the performance criterion partially. A true perf fix (view restructure or materialization) is captured as follow-up in §8.

The magic number `405` appears in `@Query` strings (JPQL/native), where a Java constant can't be interpolated; each occurrence carries a `-- BusinessObjectLockState.SHIPPED` comment. Filtering targets `stockunitlock` (the row grain and the report's primary "Stock Lock" column); `unitloadlock`/`carrierlock` are intentionally out of scope.

### 3.1 On-screen query — `findByKeyword`

**Solution:** add `@Param("includeShipped") Boolean includeShipped` and a predicate. `COALESCE(p.stockunitlock, 0)` guards nulls; `:includeShipped = TRUE` is `NULL`/false-safe:

```java
@RestResource(path = "findByKeyword", rel = "findByKeyword")
@Query("""
SELECT p FROM LockOverviewDtoView p
WHERE (
    :keyword = '' OR
    LOWER(p.itemname)       LIKE LOWER(CONCAT('%', :keyword, '%')) OR
    LOWER(p.itemnumber)     LIKE LOWER(CONCAT('%', :keyword, '%')) OR
    LOWER(p.clientname)     LIKE LOWER(CONCAT('%', :keyword, '%')) OR
    LOWER(p.unitloadnumber) LIKE LOWER(CONCAT('%', :keyword, '%')) OR
    LOWER(p.locationname)   LIKE LOWER(CONCAT('%', :keyword, '%')) OR
    LOWER(p.carriername)    LIKE LOWER(CONCAT('%', :keyword, '%'))
)
AND (p.clientnumber = :clientNumber OR :clientNumber IS NULL OR :clientNumber = '')
AND (:includeShipped = TRUE OR COALESCE(p.stockunitlock, 0) <> 405)  -- 405 = BusinessObjectLockState.SHIPPED
""")
Page<LockOverviewDtoView> findByKeyword(
    @Param("keyword") String keyword,
    @Param("clientNumber") String clientNumber,
    @Param("includeShipped") Boolean includeShipped,
    Pageable p
);
```

**Files changed:** `LockOverviewDtoViewRepository.java`.

### 3.2 Export query — `findByClientOffsetAndLimit`

**Solution:** add a 5th positional Boolean param; keep the CLAUDE.md native-SQL safety patterns:

```java
@RestResource(path = "findByClientOffsetAndLimit", rel = "findByClientOffsetAndLimit")
@Query(value =
    "SELECT p.* FROM lock_overview_dto_view p " +
    "WHERE (CONCAT(LOWER(p.itemname),' ',LOWER(p.itemnumber),' ',LOWER(p.clientname),' ',LOWER(p.unitloadnumber),' ',LOWER(p.locationname),' ',LOWER(p.carriername)) LIKE LOWER(CONCAT('%', ?1, '%')) OR ?1 = '') " +
    "AND (COALESCE(p.clientnumber,'') = CAST(COALESCE(?2,'') AS TEXT) OR ?2 IS NULL) " +
    "AND (COALESCE(?5, FALSE) = TRUE OR COALESCE(p.stockunitlock,0) <> 405) " +  // 405 = SHIPPED
    "OFFSET ?3 LIMIT ?4", nativeQuery = true)
List<LockOverviewDtoView> findByClientOffsetAndLimit(String keyword, String filter, int offset, int limit, Boolean includeShipped);
```

**Files changed:** `LockOverviewDtoViewRepository.java`.

### 3.3 Service + controller passthrough

`ReportService.exporLockReport(..., Boolean includeShipped)` forwards to `findByClientOffsetAndLimit(keyword, filter, offset, limit, includeShipped)`. `ReportController.exportLock` reads it default-false:

```java
Boolean includeShipped = Boolean.TRUE.equals(reqMap.get("includeShipped"));
reportService.exporLockReport(response, offset, limit, filter, keyword, includeShipped);
```

**Files changed:** `ReportService.java`, `ReportController.java`.

### 3.4 UI — store + toggle

- `store/reports/lock.js` `searchReport`: drop the dead `&state=` and append `&includeShipped=' + (data.includeShipped ? 'true' : 'false')`.
- `store/reports/lock.js` `export`: add `includeShipped: context.state.includeShipped || false` to `exportData`.
- `components/reports/lockReport.vue`: add an "Include Shipped" `v-checkbox` (default unchecked) next to the Shipper filter; on change, re-dispatch `searchReport` and include it in the export payload. Add store state `includeShipped` + mutation.

**Wiring contract (avoid the "toggle looks wired but always sends false" trap):** the component's `searchReport` dispatch object (currently `components/reports/lockReport.vue:~374`, `{ page, itemsPerPage, keyword, clientNumber, sortUrl }`) **must** add `includeShipped: this.includeShipped` (or read from store). The checkbox binds to store state via the same v-model pattern as `shipper`/`shipperFilter`. Both paths — the `searchReport` URL param **and** the `export` payload property — must carry it; the verify script checks each independently.

**Files changed:** `store/reports/lock.js`, `components/reports/lockReport.vue`.

---

## 4. V1/V2 Applicability

Plan is **V2 only** by decision. Recorded for future porting:

| Aspect | V1 (`wms-api` / `wms-web-ui`) | V2 (`wms2-api` / `wms2-web-ui`) | Impact |
|--------|-------------------------------|---------------------------------|--------|
| View `lock_overview_dto_view` | present, same shape | present, same shape | shipped=405 identical |
| Lock report query | `/v3/stockunit/*` lock filter path (per v1 docs) | `findByKeyword` + `findByClientOffsetAndLimit` | v1 wiring differs; re-scope before porting |
| Lock code SHIPPED=405 | same constant | same constant | shared semantics |

### What Needs Porting
1. Equivalent default-exclude-shipped + toggle in v1's lock report path — **deferred** (open a paired `SBDEV-2474-*` v1 plan if/when prioritized).

### What Does NOT Need Porting
- Nothing from this plan is v2-exclusive infrastructure; the deferral is a scope choice, not a technical incompatibility.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | None — no schema/Flyway change (query-level only) | — | View unchanged |
| 2 | **Feature flags / sysprops** | N/A — behavior gated by request param, not sysprop | — | Default = exclude shipped |
| 3 | **Config / env** | N/A | — | |
| 4 | **Deploy-order** | wms2-api and wms2-web-ui can ship independently; API default-excludes even if UI not yet updated | — | Back-compat: absent param ⇒ exclude |
| 5 | **Data migration** | None — shipped rows retained | — | |
| 6 | **External systems** | N/A | — | |
| 7 | **Access / permissions** | None — same `super-admin` / `inventory-manager` roles | — | |
| 8 | **Monitoring / alerts** | Optional: watch lock-report p95 latency before/after | — | |

### 5.2 Implementation Checklist

- [ ] 3.1 `findByKeyword` — add `includeShipped` param + predicate
- [ ] 3.2 `findByClientOffsetAndLimit` — add `includeShipped` param + predicate
- [ ] 3.3 `ReportService.exporLockReport` — add param + passthrough
- [ ] 3.3 `ReportController.exportLock` — read `includeShipped` (default false)
- [ ] 3.4 UI store — replace `state` with `includeShipped` (search + export)
- [ ] 3.4 UI component — "Include Shipped" toggle + store state/mutation
- [ ] Unit tests added/updated (repo + service + controller)
- [ ] Integration test (Testcontainers) for both queries
- [ ] Code review completed

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Default excludes shipped | Call `findByKeyword` with `includeShipped` null/false over data containing 405 and non-405 rows | No `stockunitlock=405` rows returned; `totalElements` excludes them |
| Toggle includes shipped | Same data, `includeShipped=true` | 405 rows present |
| Export default | POST `/report/exportLock` without `includeShipped` | Excel has no "Shipped" Stock Lock rows |
| Export with toggle | POST with `includeShipped=true` | Excel includes "Shipped" rows |
| Keyword + client + exclude compose | keyword + clientNumber + default | Filters combine; shipped still excluded |
| Null stockunitlock safety | row with null lock | Row retained under default (treated non-shipped) |

> **Repo test-infra facts (verified 2026-07-04, from critic review):** unit tests are `*UnitTest` extending `BaseServiceUnitTest` / `BaseControllerUnitTest`; repository DB tests are `*RepositoryTest extends BaseRepositoryIntegrationTest`. **`BaseRepositoryIntegrationTest` is H2-backed, NOT Testcontainers** — the native `findByClientOffsetAndLimit` query uses PG-specific `CAST(... AS TEXT)`, which H2 may not exercise faithfully; treat the native shipped-exclusion as covered by (a) the H2 repo test for the JPQL path + (b) the staging SQL-path manual check below, and consider a Testcontainers/failsafe IT under `integration/` if exact PG semantics must be proven.

#### New tests

| Test class (correct base) | Test method | What it asserts |
|------------|-------------|-----------------|
| `LockOverviewDtoViewRepositoryTest` (`extends BaseRepositoryIntegrationTest`, H2) | `findByKeyword_excludesShippedByDefault` | JPQL: 405 filtered when `includeShipped` null/false |
| " | `findByKeyword_includesShippedWhenRequested` | JPQL: 405 present when true |
| " | `findByKeyword_nullStockunitlockRetainedByDefault` | COALESCE guard: null lock treated non-shipped |
| " | `findByKeyword_totalElementsExcludesShipped` | derived count query keeps the predicate (`Page.totalElements` correct) |
| " | `findByClientOffsetAndLimit_excludesShippedByDefault` / `_includesShippedWhenRequested` / `_nullStockunitlockRetained` | native query parity (see H2 caveat above) |
| `ReportServiceUnitTest` (`extends BaseServiceUnitTest`) | `exporLockReport_passesIncludeShippedThrough` | service forwards the flag to the repo |
| `ReportControllerUnitTest` (`extends BaseControllerUnitTest`) | `exportLock_defaultsIncludeShippedFalse` / `exportLock_passesIncludeShippedTrue` | absent key ⇒ false; `true` forwarded |

#### Existing tests that MUST be updated (compile-breaking arity changes)

| Test class | Sites | Change |
|---|---|---|
| `ReportControllerUnitTest` | `exporLockReport(...)` at ~129, 137, 149, 157 | add 6th arg matcher (`eq(false)` / `anyBoolean()`) |
| `ReportServiceUnitTest` | `findByClientOffsetAndLimit(...)` stub ~253, `exporLockReport(...)` call ~257 | add 5th / 6th `includeShipped` arg (leave the other `findByClientOffsetAndLimit` stubs for stockView/receiving/flowbin/etc. **unchanged** — different repos, unchanged arity) |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| UI default view | staging | Open Lock Report | Shipped rows absent; count drops sharply | |
| UI toggle | staging | Check "Include Shipped" | Shipped rows appear | |
| UI export both modes | staging | Export with/without toggle | Excel matches on-screen set | |
| SQL sanity | staging DB | `SELECT count(*) FROM lock_overview_dto_view WHERE stockunitlock <> 405;` vs total | filtered ≪ total | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=LockOverviewDtoViewRepositoryTest,ReportServiceUnitTest,ReportControllerUnitTest` | | |
| `mvn verify` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| unitloadlock / carrierlock shipped filtering | Out of scope; row grain and primary column is stockunitlock |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | In-JVM state | | No | Read-only query param; no caches/statics added |
| 2 | Connection pool math | | No | Same per-request connection profile |
| 3 | Scheduled jobs | | No | No `@Scheduled` touched |
| 4 | Long transactions | | No | Single read; no cross-call tx |
| 5 | Request affinity | | No | Stateless request param |
| 6 | Retry / idempotency | | No | Idempotent read |
| 7 | Tenant context | | No | No async boundary added |
| 8 | Distributed lock correctness | | No | No locks |
| 9 | Cache invalidation | | N/A | `LockOverviewDtoView` repo is not `@Cacheable` |
| 10 | External notifications | | No | No external I/O |

### Evidence
| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| — | All "No/N/A"; read-only reporting change | this plan §3 |

---

## 8. Notes

- **Scope note (DB-verified 2026-07-04):** excluding only shipped (405) removes 85.9% of rows, but the remaining default view is still ~92% "To Delete" (2) and ~7.5% "Not Locked" (0) — only 796 rows are genuinely actionable (Picked/Quality Fault/On Hold). The ticket AC is shipped-only, so this plan implements shipped-only; if the product intent is a truly "actionable-only" default, the predicate should widen to exclude `{0, 2, 405}` (or show only true lock states). **Pending system-analyst review** (per Nam, 2026-07-04) — kept out of scope unless the analyst confirms widening. If widened, the single-source change is the `405` literal in the two repo predicates (§3.1/§3.2) → a `NOT IN (...)` set, plus the verify-script regex.
- **Performance follow-up (recommended):** to actually cut scan/load time for tenants like WineCo, filter inside the view or materialize it. Options: (a) a second slimmer view or a partial index concept, (b) restructure `lock_overview_dto_view` so `row_number()` is computed post-filter, (c) periodic purge/archival of shipped stock-unit rows. Track as a separate perf plan; this plan delivers the usability win + partial payload/count reduction now.
- **Back-compat:** API default-excludes shipped even for callers that don't send the param — safe to deploy API before UI.
- **Related docs:** `sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md:118` (Lock Report row); `wms2-landlord-vs-tenant-entity-map.md:222` (`LockOverviewDtoView`).
- **V1 parity** intentionally deferred (§4).
- **Test sequencing (decided 2026-07-04):** run **wms-tdd-gate** to author failing behavioral tests + approval pause — but **only after** the system-analyst filter-scope decision lands (shipped-only vs `{0,2,405}`), to avoid rewriting tests if the predicate widens. Order: analyst scope → wms-tdd-gate (red tests + approve) → executor → verify script 14/14 + tests green → verifier. The existing shape-level verify script is complementary (proves code written, not that it behaves).
- **Plan review (critic, 2026-07-04):** verdict REVISE → design/predicates/null-safety/back-compat/perf-caveat all verified correct; skeptic's "filter in the view" rejected soundly. Three Major findings fixed in this revision: (1) §6 now lists compile-breaking updates to existing `ReportServiceUnitTest`/`ReportControllerUnitTest`; (2) §6 test classes/base-classes corrected to real repo infra (`*UnitTest`/`BaseServiceUnitTest`/`BaseControllerUnitTest`, `*RepositoryTest`/`BaseRepositoryIntegrationTest`, H2 not Testcontainers); (3) verify script now checks the JPQL (`findByKeyword`) and native (`findByClientOffsetAndLimit`) predicates **independently** so it can't pass with the on-screen fix missing. Architect review deemed unnecessary — no architectural decision in question.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2474-exclude-shipped-locks-from-lock-report.sh` — asserts each rollout item by code-shape grep across `wms2-api` + `wms2-web-ui`. Run after every change pass; a "DONE" claim with FAIL lines is not accepted.

### 9.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | ~6 fixes across reports subsystem in two repos |
| **Pre-draft step** | none | analysis complete in this plan |
| **Plan-review step** | critic | Standard+ requires plan review before coding |
| **Implementation shape** | executor | cohesive, single subsystem |
| **Verification step** | verify-script + verifier | mandatory |
| **Code-review step** | code-reviewer | native-SQL + JPQL param change warrants it |
| **Commit step** | git-master | two repos ⇒ two atomic commits with trailers |

#### Persistence
- On ship, if the `row_number()`-before-`WHERE` perf caveat proves impactful, `project_memory_add_directive`: *"Report views using `row_number() OVER ()` don't benefit from outer-query WHERE for scan cost — filter inside the view for perf."*


> **Archived (superseded) 2026-07-25.** This early draft proposed a single-view + `includeShipped` query-param filter, which was **explicitly rejected** in favor of the two-view design in [[SBDEV-2474-lock-report-exclude-shipped-locks]] — the plan that actually shipped (wms2-api PR #77 + wms2-web-ui PR #21 → develop 2026-07-16). Kept for historical trail only; not the implemented design.
