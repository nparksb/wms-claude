---
title: "SBDEV-3952 — flowbin_monitor_view: per-flowbin Requested Replenishment and one row per unitload/stock unit"
ticket: "SBDEV-3952"
ticket_url: "https://app.clickup.com/t/868mpmtfq"
type: "bug"
priority: "normal"
status: "archived"
tier: "T3"
db_verified: true
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-10-30"
updated: "2026-10-31"
related:
  - "SBDEV-3952-evidence/analysis.md"
  - "SBDEV-3952-evidence/review-architect.md"
  - "SBDEV-3952-evidence/review-critic.md"
  - "SBDEV-3947 (P34 origin)"
  - "SBDEV-3951 (LIST_KEY)"
tags:
  - plan
---

# SBDEV-3952 — flowbin_monitor_view: per-flowbin Requested Replenishment

**Ticket:** [SBDEV-3952](https://app.clickup.com/t/868mpmtfq) · **Tier:** T3 (Flyway view migration that reaches every tenant) · **Graded against:** `origin/develop` @ `dde23325` · **Evidence:** [analysis.md](SBDEV-3952-evidence/analysis.md) (§n = analysis §n unless prefixed "plan") · **Revision 2**: folds in ralplan round 1 ([architect](SBDEV-3952-evidence/review-architect.md) F1–F6, [critic](SBDEV-3952-evidence/review-critic.md) H1–H2, M1–M4, L1–L4)

## RALPLAN-DR summary (mode: SHORT)
**Principles:**
1. A view column means what its label says: "Requested Replenishment" is per flowbin.
2. Make the bug class impossible, not just this instance: no sum that a join fan-out can multiply.
3. Fix forward, append-only: never DROP a view that carries per-tenant grants.
4. A test asserts what the view computes, not only that it runs.
5. Minimal surface: no DTO or UI change.
6. The output key is unique **because of the join graph**, not because of today's data.

**Decision drivers:**
- **D1:** correctness under fan-out the data cannot show today (0 flowbins with more than one UL or SU on dev or PRD).
- **D2:** `CREATE OR REPLACE` stays legal (the first 14 columns keep name, order and type).
- **D3:** read latency. It is unmeasured on PRD, so the plan shape matters.

| Option | Pros | Cons |
|---|---|---|
| **(D) Pre-aggregated derived table `rr` (one row per destination), no outer GROUP BY** (chosen) | Fan-out-proof: `rr` has at most one row per `destination_id`, so joining it to `loc.id` cannot multiply. Set-based hash join. **Dev EXPLAIN ANALYZE 376 ms**, no JIT on dev. | The view grain becomes per UL/SU, so it needs an explicit key (`unitload_id`, `stock_unit_id`). |
| (A) Correlated scalar subquery, no outer GROUP BY | Same semantics; validated row-for-row (§3.2) | Dev **799 ms**: it runs 2,068 index probes, and its estimated cost (1.5M) triggers JIT. Same grain cost as D. |
| (B) Keep the GROUP BY, add `su.id` and `r.destination_id = loc.id` | Smallest textual diff | Keeps the fan-out-then-sum shape that caused (a), so any future join multiplies again. Must still de-duplicate empty-UL rows. Not measured. |
| (C) `LEFT JOIN LATERAL` | Same semantics as A | Same per-row plan as A, with more syntax |

D beats A on D3: the same answer and about 2× faster. On dev the paged query cost is 85k, under `jit_above_cost` = 100k, so no JIT. Scaled to PRD's table statistics it is about 100k, right at the threshold, so "no JIT" is proven on dev only. B fails Principle 2. C is A with more syntax.
Dev measurements, 2026-10-30, same 7-way join, `EXPLAIN (ANALYZE, timing off)`: D = 376 ms, A = 799 ms; the old view measured 2,021 ms (§3.2).

## 0. Affected sites
Method: `git grep -n -i "flowbin_monitor_view\|FlowbinMonitorView" origin/develop` gave 95 hits, each triaged (§0). External consumers were found with `grep -rn flowbinMonitorView` over `wms2-web-ui`, `wms2-mobile-ui`, `oms-laravel-api` and `siteboss-frontend`. The only one is wms2-web-ui `store/reports/flowbin.js:62` (architect).

| # | Site (origin/develop) | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `db/migration/V2.2.00__base_v2_schema.sql`, view definition | `LEFT JOIN public.replenishorder r ON ((r.itemdata_id = i.id))` … `GROUP BY loc.name, …, f.active, f.*` | yes, both defects | yes, fixed forward by V2.2.43 |
| 2 | `model/FlowbinMonitorView.java` | `@Id @Column(name = "row_id")`, 14 columns | follows the view | yes: add `unitloadId` and `stockUnitId` |
| 3 | `FlowbinMonitorViewRepository` `LIST_KEY` and its comment | `"every mapped column together is"` [unique] | becomes false | yes |
| 4 | `FlowbinMonitorViewRepository#findByClientOffsetAndLimit` ORDER BY and its comment | `"No unique key reaches the output"` | becomes false | yes |
| 5 | `PagedNativeExportTotalOrderArchTest` EXPECTED (Flowbin) and its comment | `"no unique key exists"` | the pin | yes: re-pin |
| 6 | `ReportViewListKeyUnitTest` class Javadoc | `"The views have no unique column"` | stale for Flowbin | yes: one-sentence edit |
| 7 | `ViewDtoService`, 14-key hand-built map | `dto.put("requestedReplenishment", …)` | no | **no**: the new ids are not exposed |
| 8 | `ReportController` `/flowbinMonitorView`; `ReportService` export; wms2-web-ui `store/reports/flowbin.js:62`, `components/reports/flowbinReport.vue` (`item-key="key"` is client-side) | `PagedListSort.of(…, FlowbinMonitorViewRepository.LIST_KEY)` | no | no: they consume rows 3 and 4 unchanged |
| 9 | `v1-to-v2-onboarding/**` copies (D2–D6) and `db/ref/losref*.sql` | run by hand with psql, not scanned by Flyway | yes (copies) | **no**: onboarded tenants reach V2.2.43 through the V2.2.x deltas (§3.4) |
| 10 | `ViewExportOrderByExecutesIT`, `PagedListSortExecutesIT:171-173` | run on an empty view; UI-sortable subset | no | no: still valid |
| 11 | `sbdocs/2-Areas/proposals-register.md` P34 row | recommends "group by `su.id`" | stale recommendation | yes: updated to point here (critic L3, done 2026-10-30) |

## 1. Problem Statement
The Flowbin Report (`/reports/flowbin-report`, `WEB_UI_VIEW_FLOWBIN_MONITOR`) shows the wrong **Requested Replenishment** in two ways.

**(b) Wrong flowbin.** Replens are joined on item only. A flowbin therefore shows replens headed elsewhere, and misses replens for another SKU (or for an empty flowbin) that are headed to it.
- Dev `dev_wh01_om1`, 2026-10-30, destination-only sums:
  - `00-A07` and `05-A06` should be 0; the view shows 12.
  - `00-B03` is an empty flowbin and should be 12; the view shows 0.
  - `00-B01` stocks `22AZCHBTL`, while its open replen (12) is for `23AZPGBTL`. That is the "other SKU headed to it" case. It should be 12; the view shows 0 (architect round 2, N1).
- PRD `wh01_om1_v2`: one row differs, `53-C01` (0 → 24) (§2).

**(a) Merge and multiply.** The GROUP BY has no row identity.
- Equal stock units on one flowbin collapse into one row, and the replen sum is multiplied.
- Several empty unitloads on one flowbin also collapse into one row.
- 0 instances on dev and PRD (`flowbins_2plus_ul = 0`, `flowbins_2plus_su = 0`). The defect is structural, so only the IT covers it.

## 2. Root Cause Analysis
### Bug 1 (b): replen join keyed on item
`V2.2.00` joins `LEFT JOIN public.replenishorder r ON ((r.itemdata_id = i.id))` and sums with `CASE WHEN ((r.state < 600) AND (r.destination_id IS NOT NULL))`. `destination_id` is never compared with `loc.id`. For an empty flowbin `i` is NULL, so the join matches nothing.
### Bug 2 (a): GROUP BY without a row identity
The view groups by `GROUP BY loc.name, c.cl_nr, c.name, i.item_nr, i.name, su.amount, su.reservedamount, f.lowerbound, …, f.*`.
- Two stock units with equal `amount` and `reservedamount` fall into one group.
- Every replen row is joined once per stock unit, so `sum(...)` is multiplied.
**Regression chain:** SBDEV-3947 review finding L2, deferred there as **P34** because it needs a migration (§6). This ticket is P34.

## 3. Fix Design
### Fix A: `V2.2.43__flowbin_monitor_view_per_flowbin_replen.sql`
V2.2.42 is the highest migration on origin/develop. `git log --remotes --diff-filter=A -- 'V2.2.4[3-9]*'` returns nothing, so no in-flight branch has claimed V2.2.43 (architect).
```sql
CREATE OR REPLACE VIEW public.flowbin_monitor_view AS
 SELECT row_number() OVER () AS row_id, loc.name AS location_name, c.cl_nr AS client_id, c.name AS client_name,
    i.item_nr AS sku_id, i.name AS sku_name,
    COALESCE(round(su.amount),(0)::numeric) AS amount, COALESCE(round(su.reservedamount),(0)::numeric) AS reserved,
    COALESCE(round(f.lowerbound),(0)::numeric) AS lower_bound, COALESCE(round(f.middlebound),(0)::numeric) AS middle_bound,
    COALESCE(round(f.upperbound),(0)::numeric) AS upper_bound,
    COALESCE(rr.requested,(0)::numeric) AS requested_replenishment,
    CASE WHEN (f.id IS NULL) THEN 'false'::text ELSE 'true'::text END AS fix_assignment_exists,
    f.active,
    ul.id AS unitload_id,
    su.id AS stock_unit_id
   FROM public.location loc JOIN public.location_type t ON t.id = loc.type_id
     LEFT JOIN public.fix_location_assignment f ON f.assignedlocation_id = loc.id
     LEFT JOIN public.unitload ul ON ul.storagelocation_id = loc.id
     LEFT JOIN public.stockunit su ON su.unitload_id = ul.id
     LEFT JOIN public.itemdata i ON i.id = su.itemdata_id
     LEFT JOIN public.client c ON c.id = i.client_id
     LEFT JOIN (SELECT r.destination_id, sum(round(r.requestedamount)) AS requested
                  FROM public.replenishorder r WHERE r.state < 600 GROUP BY r.destination_id) rr
            ON rr.destination_id = loc.id
  WHERE (t.sltname)::text = 'flowbin'::text;
```
- **Columns 1–14 keep their name, order and type.** The architect checked this against the live `pg_attribute` on dev. `sum(round(numeric(17,4)))` gives `numeric`, matching the old typmod -1.
- **`unitload_id` (15) and `stock_unit_id` (16) are appended** after column 14, in that order.
- **No outer GROUP BY and no view-level ORDER BY.** Every caller orders explicitly; verified by the architect.
- **`f.id IS NULL` replaces `f.* IS NULL`.**
- **`JOIN location_type` is equivalent to the old LEFT JOIN** because `WHERE t.sltname = 'flowbin'` already rejects NULL rows.
- **The header comment** cites the precedents `V2.2.01` and `V2.2.33` (PostgreSQL only allows appending columns). It also says why DROP+CREATE is forbidden: it would lose PRD's `wms2_landlord_app=arwd` grant (§2).
- **Grain (architect F1, critic M2):** one row per (flowbin, unitload or none, stock unit or none).
  - **The key `(location_name, unitload_id, stock_unit_id)` is unique by construction.**
    - Flowbin names are unique.
    - `fix_location_assignment` is UNIQUE per location, so `f` adds no fan-out.
    - `item` and `client` are N:1.
    - Each UL contributes either one row per SU, or exactly one row with a NULL SU.
    - An empty flowbin contributes exactly one row, with both ids NULL.
  - `PagedListSort` appends the key using PostgreSQL's default `ASC NULLS LAST`, so NULLs sort deterministically.

**Validation.** §3.2 compared the 13 old columns with `EXCEPT ALL` using the A-form subquery:
- PRD: 2,149 = 2,149 rows; the only difference is `53-C01`.
- dev: 2,068 = 2,068 rows; 4 differences.
- D computes the same per-destination sum through a different plan. Re-run that comparison against the D form at the TDD gate (plan §5.2 step 1) before committing the migration.

### Fix B: entity and stable key (one commit with Fix A; critic H2)
- **Entity `FlowbinMonitorView`:** add `@Column(name = "unitload_id") private Long unitloadId;` and `@Column(name = "stock_unit_id") private Long stockUnitId;` with getters.
  - **Keep `@Id` on `row_id`.** Both new ids are NULL for an empty flowbin. `row_id` is safe because each page or export chunk gets its own persistence context (OSIV is off, one repository call per request; architect).
- **Key:** append `"unitload_id", "stock_unit_id"` to `LIST_KEY`, to the `findByClientOffsetAndLimit` ORDER BY (`p.unitload_id, p.stock_unit_id`) and to the arch-test EXPECTED.
- **Rewrite the three stale comments.** New text: the key is unique by construction, with the reasoning from the Grain bullet above. Edit the `ReportViewListKeyUnitTest` Javadoc to say Flowbin now has a real key.
- **No `ViewDtoService` or UI change.**

### File Change Summary
| File | Change | Description |
|---|---|---|
| `src/main/resources/db/migration/V2.2.43__flowbin_monitor_view_per_flowbin_replen.sql` | new | Fix A |
| `src/main/java/.../model/FlowbinMonitorView.java` | modify | add `unitloadId` and `stockUnitId` |
| `src/main/java/.../repo/jpa/FlowbinMonitorViewRepository.java` | modify | LIST_KEY, export ORDER BY, 2 comments |
| `src/test/java/.../PagedNativeExportTotalOrderArchTest.java` | modify | re-pin Flowbin EXPECTED and its comment |
| `src/test/java/.../ReportViewListKeyUnitTest.java` | modify | one Javadoc sentence |
| `src/test/java/.../FlowbinMonitorViewPerFlowbinIT.java` | new | 8 IT methods (plan §6) |

## 4. Architecture Overview
**List:** `flowbinReport.vue` → `store/reports/flowbin.js` → `GET /report/flowbinMonitorView` (ReportController) → `ViewDtoService` → `findByKeywordAndClientName` (Page; the count query is derived) + `PagedListSort(LIST_KEY)` → `flowbin_monitor_view`.
**Excel export:** `ReportService` → `findByClientOffsetAndLimit`. It reads in OFFSET/LIMIT chunks, so it needs a total ORDER BY.

## 5. Implementation
### 5.1 Prerequisites
| # | Prerequisite | Action | Notes |
|---|---|---|---|
| 1 | DB state | The target is at V2.2.42. PRD is at 2.2.41 and takes V2.2.42 first (ordinary in-order deploy) | |
| 2 | Flags / sysprops | N/A | A view definition has no toggle |
| 3 | Config / env | N/A | No property is read |
| 4 | Deploy order | N/A | API only; the UI ignores the new columns |
| 5 | Data migration | N/A | A view stores no data |
| 6 | External systems | N/A | No OMS or notification path |
| 7 | Access | **Before deploying, check each tenant:** `SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname = 'flowbin_monitor_view'`. If the owner is not the tenant app role, run `src/main/resources/db/reassign-tenant-ownership.sh` first. Otherwise Flyway fails with **42501** and that tenant stalls | §3.4. PRD owner is `wh01_om1_v2_app` (OK) |
| 8 | Monitoring | N/A | Report read path; latency shows in the existing HTTP metrics |

### 5.2 Steps
1. **Set up the worktree.**
   - Run `.claude/scripts/ticket-lease.sh claim SBDEV-3952`.
   - Create worktree `.claude/worktrees/wms2-api/SBDEV-3952` on `feature/SBDEV-3952-flowbin-per-flowbin-replen`, off a freshly fetched `origin/develop`.
   - Record the baseline suite.
   - Re-run the §3.2 `EXCEPT ALL` comparison on dev with the **D** form. Expect 4 differences, all in the (b) rows.
2. **TDD gate (commit 1).** Write `FlowbinMonitorViewPerFlowbinIT` (plan §6) and re-pin the arch EXPECTED.
   - On the unchanged view, these must be red for the stated reason: IT methods 1, 2, 3, 6, 7 and 8, and `PagedNativeExportTotalOrderArchTest` (EXPECTED ≠ the old ORDER BY).
   - Methods 4 and 5 are green guards.
   - `ReportViewListKeyUnitTest` stays green here and is **not** on the red list (critic H2).
   - **Assertion order (critic H2).** Each IT method first asserts the observable symptom through a JDBC projection of the **14 old columns**. Only after that does it assert anything involving `unitload_id` or `stock_unit_id`. On the old view the symptom assertion fails first, never `BadSqlGrammar`.
   - The IT does not call the new entity getters, so it compiles before Fix B exists.
3. **Fix A + Fix B (commit 2, one atomic change).** Add the migration, the entity fields, LIST_KEY, the ORDER BY, and the comments.
   - Committing these separately would leave either `ddl-auto=validate` or `ReportViewListKeyUnitTest` red.
   - Everything from step 2 goes green.
4. **Verify.**
   - Mutation-check every IT assertion (plan §6) with an attributable kill.
   - Run the full suite and compare against the baseline.
   - Run the independent review lanes, commit, and open a PR into `develop`. The PR body carries the prerequisite-7 check and the D-1 / totals release note.
5. **Docs.**
   - No sbdocs page documents the view's columns: a grep of `3-Resources` hits only the glossary and entity listings.
   - P34 register row: done (§0 row 11).
   - Follow-up P-b: the onboarding README.

**Verify script: none.** The only cross-file invariant is LIST_KEY = export ORDER BY = arch pin. `ReportViewListKeyUnitTest` and `PagedNativeExportTotalOrderArchTest` already enforce it. The view's semantics belong in the IT.

## 6. Testing Plan
**Integration:** `FlowbinMonitorViewPerFlowbinIT`, on Testcontainers `postgres:14-alpine` via `BasePostgresIntegrationTest`, migrating `classpath:db/migration`.
- **Pattern** (copy from `OrderDetailMonitorViewStateFilterIT`): `@Transactional(value = "tenantTransactionManager", propagation = Propagation.NOT_SUPPORTED)`, a class-unique id block, and `JdbcTemplate` seed and cleanup. Use the `PgLaneFixtures` helpers where they fit.

**Seed facts (critic M1):**
- `location_type` id 2 is `flowbin`.
- NOT NULL foreign keys:
  - location: `area_id`, `client_id`, `type_id`
  - unitload: `type_id`, plus `labelid`, which is also UNIQUE
  - itemdata: `handlingunit_id`
  - replenishorder: `number` (UNIQUE), `prio`, `client_id`
- Reference rows in V2.2.00 (around lines 2377, 2451, 2502, 2544 and 3152).
- `fix_location_assignment` is UNIQUE per location and per item. Its **`assignedunitload_id` is NOT NULL, UNIQUE and a foreign key to `unitload`**. Every assignment's unitload therefore sits on a **non-flowbin** location, so it never adds a UL row to the flowbin under test.
- `idx_replenishorder_active_item_dest` is UNIQUE on `(itemdata_id, destination_id) WHERE state < 700`. That is why test 5 uses its own item. A state-600 replen and a state-700 replen can coexist with each other.
- Equal stock units must have equal `amount` **and** equal `reservedamount` (critic L4).

| # | Method | Seed → symptom assertion (old 14 columns) first, then key | Attributable mutation (red message names it) |
|---|---|---|---|
| 1 | `replenToOtherFlowbinIsNotCountedOnThisOne` | X stocks SKU S; an open replen of S goes to Y → X `requested_replenishment = 0` | Key `rr` on item: `GROUP BY r.itemdata_id` … `ON rr.itemdata_id = i.id` (critic r2 L-a) |
| 2 | `twoEqualStockUnitsOnOneFlowbinAreTwoRows` | Two SUs on **one UL**, same item, equal amount and reserved → 2 rows; then distinct `stock_unit_id` | Restore an outer `GROUP BY` without `su.id` |
| 3 | `twoEqualStockUnitsDoNotMultiplyRequested` | Test 2's seed plus one open 5-unit replen to X → **first** assert every row's `requested_replenishment` = 5, then the row count. That way the old view goes red on the multiply, not on the merge (critic r2 L-c) | In `rr`, join `unitload ul2 ON ul2.storagelocation_id = r.destination_id JOIN stockunit su2 ON su2.unitload_id = ul2.id` (each row shows 10; test 2 stays green) (critic H1) |
| 4 | `emptyFlowbinIsStillListedOnce` | Assigned empty flowbin (its assignment UL is on a non-flowbin) → 1 row, `sku_id` NULL, bounds kept, `fix_assignment_exists = 'true'` | `LEFT JOIN unitload` → `JOIN` (kills, because the assignment UL is not on X) (critic M1) |
| 5 | `closedReplenIsExcluded` | Replens at states 600 and 700 to X (own item) → 0 | `r.state < 600` → `r.state <= 600` |
| 6 | `replenToEmptyFlowbinIsShown` | Empty flowbin E with an open 7-unit replen → 7 (D-1) | Re-add the item condition (`rr` keyed on item) |
| 7 | `exportPagesCoverEqualRowsExactlyOnce` | Test 2's seed → page through `findByClientOffsetAndLimit` with limit 1 → 2 entities, both pages non-empty. On the old view this is red because of the merge (1 row) | **Behaviour guard only (critic L2).** "Drop the key from the ORDER BY" is not deterministically killable here; the arch pin is the instrument for that |
| 8 | `twoEmptyUnitloadsOnOneFlowbinAreDistinctByKey` | Two SU-less ULs on flowbin Z → 2 rows; then `count(*) = count(DISTINCT (location_name, unitload_id, stock_unit_id))` over the seeded rows (architect F1/F2) | `ul.id AS unitload_id` → `NULL::bigint AS unitload_id`: the 2-row assertion stays green and the distinct-key assertion goes red (critic r2 L-b). Restoring the GROUP BY also kills it |

**Unit:**
- `PagedNativeExportTotalOrderArchTest` re-pinned to `…, unitload_id, stock_unit_id`. This is the attributable instrument for "key dropped from the export ORDER BY".
- `ReportViewListKeyUnitTest` is unchanged apart from its Javadoc. It goes red if LIST_KEY and the ORDER BY disagree.

**Regression:** `ViewExportOrderByExecutesIT`, `PagedListSortExecutesIT`, and the Report controller, service, DTO and gating tests are unchanged and stay green.

### Acceptance criteria (critic M3)
| AC | Criterion | Encoded by |
|---|---|---|
| AC1 | `requested_replenishment` = Σ `round(requestedamount)` over replens with `destination_id` = this flowbin and `state < 600`, any item (D-1) | IT 1, 5, 6 |
| AC2 | One row per (flowbin, UL or none, SU or none); the replen value is never multiplied | IT 2, 3, 8 |
| AC3 | A flowbin with no UL appears exactly once, with its assignment bounds | IT 4 |
| AC4 | `(location_name, unitload_id, stock_unit_id)` is unique; LIST_KEY, the export ORDER BY and the arch pin keep their 13 columns and end with `unitload_id, stock_unit_id` | IT 8, arch test, `ReportViewListKeyUnitTest` |
| AC5 | Append-only REPLACE: columns 1–14 unchanged, `unitload_id` and `stock_unit_id` are columns 15 and 16 | Enforced by PostgreSQL, which rejects a non-append `CREATE OR REPLACE VIEW` at migrate time in every IT. `ddl-auto=validate` checks the entity |
| AC6 | No whole-row (`f.*`) dependency on `fix_location_assignment` | Code review of V2.2.43 |

### Manual test plan (dev, after merge, via `wms-dev-probe`)
`Q(n)` = `SELECT COALESCE(sum(round(requestedamount)),0) FROM replenishorder r JOIN location l ON l.id = r.destination_id WHERE l.name = :n AND r.state < 600`.
`QI(n)` = item-only open replens of the flowbin's SKU to **other** destinations (the bug's input).

| Scenario | Env | Precondition → dev count (2026-10-30) | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| Replen counted by destination (b) | dev `dev_wh01_om1` | `QI('00-A07')` → 12 and `QI('05-A06')` → 12 (**abort if 0**: the scenario would pass vacuously, critic M4); `Q()` → 0 for both | Flowbin Report, search `00-A07`, then `05-A06` | Requested = 0 for both (today: 12) | |
| Replen to empty flowbin shown (D-1) | dev | `Q('00-B03')` → 12 | Search `00-B03` | One row, empty SKU, Requested = 12 (today: 0) | |
| Replen of another SKU to a stocked flowbin (D-1) | dev | `Q('00-B01')` → 12; stocked SKU `22AZCHBTL`; replen item `23AZPGBTL` | Search `00-B01` | One row, SKU `22AZCHBTL`, Requested = 12 (today: 0) | |
| Row count | dev | flowbins → 2,068; flowbins with >1 UL → 0 | `SELECT count(*) FROM flowbin_monitor_view` | 2,068 | |
| Excel export | dev | same | Export the Flowbin Report | 2,068 data rows | |
| Equal SUs / empty ULs on one flowbin (a) | dev | flowbins with >1 SU or >1 UL → **0** | **dev-infeasible without seeding.** Covered by IT 2, 3 and 8. Optional: seed with `wms-dev-probe` (out-of-band ids, `snapshot.sh` restore proof) | 2 rows; Requested not doubled | |
| UI unchanged | dev | n/a | Sort every column; open the detail popup | Sorting works; no new field shown | |

## 7. Horizontal Scalability Validation
All 10 rows are **No** or **N/A**: the change is one view definition plus two read-only entity fields.

| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state | No |
| 2 | Connection pool math | No |
| 3 | Scheduled jobs | No |
| 4 | Long transactions | No |
| 5 | Request affinity | No |
| 6 | Retry / idempotency | N/A (read-only; the migration is a single re-runnable `CREATE OR REPLACE`) |
| 7 | Tenant context | No |
| 8 | Distributed locks | N/A |
| 9 | Cache invalidation | N/A (not `@Cacheable`) |
| 10 | External notifications | N/A |

**v2-only constraints:**

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | N/A |
| 2 | Transaction manager | **Yes**: the IT uses `tenantTransactionManager` with NOT_SUPPORTED |
| 3 | readOnly | N/A |
| 4 | Caffeine | N/A |
| 5 | Jakarta namespace | **Yes**: the entity already imports `jakarta.persistence.*` |
| 6 | H2-compatible SQL | **Yes**: the test is a Testcontainers IT, not H2 |
| 7 | BaseControllerTest | N/A |
| 8 | Metrics | N/A |

## 8. Risks & Mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| D-1 changes PRD `53-C01` from 0 to 24 | One visible value changes | Intended (Nam, 2026-10-30). State it in the PR and the release note |
| **Requested repeats on every row of a flowbin.** This covers several SUs and an empty-UL row next to a stocked UL. Where the old view showed 0 on such a phantom row, it now shows the flowbin total (critic M2, architect F3) | Excel column totals are **not additive** | By design (D-0, per flowbin). Release note: "Requested Replenishment is a per-flowbin figure; do not sum it". 0 such flowbins today |
| 42501 on a tenant whose view a superuser owns | Flyway stalls that tenant at boot | §5.1 row 7 owner check plus `reassign-tenant-ownership.sh` |
| PRD latency unmeasured (PRD refused EXPLAIN ANALYZE) | The report could be slower than on dev | D form: dev 376 ms against 2,021 ms today; the cost is dominated by the stockunit/unitload seq scans that the old view also runs (architect F4). Time it on UAT/PRD after deploy |
| Rollback | Needs a forward migration | REPLACE cannot drop columns 15 and 16. Rollback means DROP + CREATE of the V2.2.00 body **plus re-granting each tenant's grants** (PRD: `GRANT SELECT, INSERT, UPDATE, DELETE ON flowbin_monitor_view TO wms2_landlord_app`, i.e. `arwd`). Capture `relacl` per tenant first (architect F5) |
| Blind spot: no real data with more than one SKU, SU or UL per flowbin | Real-data validation cannot exercise (a) | IT 2, 3 and 8 seed it |

## 9. Completeness checklist
| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ dev re-run 2026-10-30 (plan §1, plus the D/A EXPLAIN ANALYZE); PRD census §2; `db_verified: true` |
| 1 | All call sites | ✓ plan §0 rows 1–11 |
| 2 | Adjacent bugs | ✓ The same shape exists only in the onboarding copies (excluded). P-a (assignment/stock item mismatch, 0 rows) is a proposal only |
| 3 | Backward compatibility | ✓ AC5: append-only; DTO and UI payload unchanged; sort column names unchanged |
| 4 | Concurrency | No: a read-only view. The DDL runs once per tenant under Flyway's lock |
| 5 | Multi-tenant | ✓ V2.2.43 reaches every tenant through `db/migration`; 42501 check in §5.1 row 7 |
| 6 | Error handling | No: no new throw path |
| 7 | Observability | No: no new failure mode. PRD timing is a follow-up |
| 8 | Rollback / migration | ✓ §8 rollback row, including the grants |
| 9 | Test coverage | ✓ plan §6: 8 IT methods with mutations, the arch re-pin, ACs, manual table |
| 10 | Cross-version | No: v1 is reference-only and has no v1 client (standing rule) |

## 10. Decisions (resolved, Nam 2026-10-30)
- **D-0:** "Requested Replenishment" is **per flowbin**.
- **D-1:** count by **destination only**. Every open replen (`state < 600`) whose `destination_id` is the location counts, whatever its item. PRD `53-C01` going from 0 to 24 is intended.
- **D-2 (ralplan round 1, both reviewers):** expose `unitload_id` in the key rather than hiding empty ULs with a nested join. The nested form is about +40% latency (§3.2), and it would drop the real `05-C09` empty-UL row shape.

## 11. ADR
- **Decision.** Option D. V2.2.43 re-creates `flowbin_monitor_view` as follows:
  - a pre-aggregated per-destination `rr` derived table;
  - no outer GROUP BY and no view-level ORDER BY;
  - `f.id IS NULL`;
  - `unitload_id` and `stock_unit_id` appended as columns 15 and 16, forming the key with `location_name`. LIST_KEY, the export ORDER BY and the arch pin all use that key.
- **Drivers:** D1 (fan-out-proof), D2 (append-only REPLACE), D3 (376 ms against 799 ms for A and 2,021 ms today, on dev).
- **Alternatives:**
  - A, the scalar subquery: same result, about 2× slower, and triggers JIT.
  - B, keep the GROUP BY: fixes this instance but keeps the multiplying shape.
  - C, LATERAL: A with more syntax.
- **Why chosen:** it is the only option that is fan-out-proof and set-based, with a key that is unique by construction.
- **Consequences:**
  - One row per UL/SU. Identical to today's rows on both DBs, because view rows = flowbins.
  - A real total order exists.
  - PRD shows one changed value.
  - Requested is per flowbin and not additive across rows.
  - The onboarding copies stay old; V2.2.43 overrides them.
- **Follow-ups:**
  - P-b: stale `v1-to-v2-onboarding/README.md:34` (SBDEV-3239 moved the IT harness to `db/migration`).
  - Measure PRD report latency after deploy, including whether JIT triggers (estimated cost is about 100k, at the threshold).
  - P-a (assignment/stock item mismatch): proposal only.

## 12. Implementation Status (2026-10-31)
**Where:**
- Worktree `.claude/worktrees/wms2-api/SBDEV-3952`
- Branch `feature/SBDEV-3952-flowbin-per-flowbin-replen`, off `origin/develop` @ `dde23325`

**Commits:**

| SHA | What |
|---|---|
| `65bdce76` | TDD gate: `FlowbinMonitorViewPerFlowbinIT` (8 methods) and the `PagedNativeExportTotalOrderArchTest` re-pin |
| `62b50d17` | Fix A + Fix B in one commit: V2.2.43, entity `unitloadId`/`stockUnitId`, LIST_KEY, export ORDER BY, comments |
| `1830dc2e` | Review fixes (see below) |

**Gate (on the old view):**
- Red for the symptom: IT 1, 2, 3, 6, 7 and 8, and the arch pin. Messages: `expected: 0 but was: 12`, `5 but was: 10`, `7 but was: 0`, `Expected size: 2 but was: 1` ×2, `export page 2` empty.
- Green guards, as planned: IT 4 and 5.
- `ReportViewListKeyUnitTest` stayed green.

**After the fix:**
- IT 9/9: the 8 planned methods plus `nonFlowbinLocationIsNotListed`, added in review.
- Unit: `ReportViewListKeyUnitTest` 6, `PagedNativeExportTotalOrderArchTest` 3, `TestClassTransactionManagerArchTest` 6.
- `ViewExportOrderByExecutesIT` 8/8 and `PagedListSortExecutesIT` 12/12.
- Flyway applied V2.2.43 incrementally over 2.2.42 (AC5) and from scratch.

**Mutation checks:** 8 SQL mutants, each in a fresh container. All killed, each with a message that names the defect:

| Mutant | Killed by |
|---|---|
| M1: replen keyed on item | IT 1, 6 |
| M2: GROUP BY without ids | IT 2, 3, 7, 8 |
| M3: fan-out inside `rr` | IT 3 (`5 but was: 10`) |
| M4: inner-join unitload | IT 4, 6 |
| M5: `state <= 600` | IT 5 |
| M6: `NULL::bigint unitload_id` | IT 8 (`[distinct output keys on Z] 2L but was 1L`) |
| M7: no flowbin filter | `nonFlowbinLocationIsNotListed` |
| M8: `NULL::bigint stock_unit_id` | IT 7 and IT 2 |

M8 first died with an NPE in `Set.of` (not attributable); the assertion was rewritten to AssertJ `doesNotContainNull().doesNotHaveDuplicates()`.

**Review lanes:**
- Conformance (verifier): PASS, AC1–AC6 VERIFIED.
- Code review: COMMENT, 0 High and 0 Medium, 4 Low, all fixed in `1830dc2e`.
- Security: PASS.
- Scoped review of `1830dc2e` APPROVE; scoped review of style commit `87cf77b2` (rewrap only) APPROVE
- Reports: `SBDEV-3952-evidence/review-*.md`.

**Landmines the plan did not predict:**
- **`fix_location_assignment` has no `client_id`.** IT cleanup has to delete it by location id.
- **A test class with `NOT_SUPPORTED` must be declared in `TestClassTransactionManagerArchTest.EXEMPT_NON_TRANSACTIONAL`, with a reason.** Only the full suite caught this; the targeted runs did not.
- **PRD data moved between 2026-10-30 and 2026-10-31.**
  - 53-C01 now shows **12** before the change (REPL062920, 21WH, 12, was added) and still goes to **24**.
  - The frozen migration header therefore carries no per-location PRD values.
  - The PR and release note should say "1 PRD row changes; 53-C01 12 → 24 as of 2026-10-31".
- **The local reused Testcontainers DB is stale.** It causes 16 failures on develop in `PickPackReachableColumnIT`, `MessageRepositoryNativeSearchIT` and `OrderReleaseSectionQueryIT`, via the `seqentities` fixed-id-band guard and the 50-row page. Runs that are compared use fresh containers (`TESTCONTAINERS_REUSE_ENABLE=false`).

**Full suite (`mvn clean verify -Pci`, fresh container):**
- On `1830dc2e`: unit 9,341 with 0 failures; IT 1,147 with 0 failures. That is the develop baseline's 1,138 ITs plus the 9 new ones.
- On develop `dde23325`, the same suite on the stale reused container gave 16 IT failures, all environmental.
- `87cf77b2` (the tip) only rewraps lines. Its 24 targeted tests pass.

**PR:** https://github.com/SiteBossInc/wms2-api/pull/590 (into develop, 2026-10-31), with 3 inline design notes. ClickUp is at `pr submitted`. Not done: merge, `on dev`, Flyway rollout to tenants, archive.

### Merge and dev test (2026-10-31)
**Merge**
- Develop moved 7 commits after the PR check (SBDEV-3974, #589). Merged `origin/develop` into the branch as `f92746c6`. No conflicts, no shared files, no Flyway collision.
- Full suite on that merge (fresh container): unit 9,378 / 0 failures; IT 1,147 / 0 failures.
- PR check `test` passed on `f92746c6`.
- `merge-one.sh` merged #590 as **`9d184321`**, pinned to that head.

**Deploy (`post-merge-verify.sh`: ALL PROVEN)**
- Content is on develop.
- Develop CI test and build passed.
- Dev serves `develop-9d184321`, drift=false.

**Flyway on dev**
- V2.2.43 applied successfully on dev_wh01_om1 at 01:02 UTC.
- `wms2.flyway.tenant.stale` = 0 and `ownership_drift` = 0 on all 3 dev tenants.

**Manual test on dev (read-only; no seed, nothing to restore)**
- ✅ 00-A07 and 05-A06 went 12→0. Precondition: their item-only replens elsewhere were 12.
- ✅ 00-B03 (empty) went 0→12.
- ✅ 00-B01 (cross-SKU) went 0→12.
- ✅ Row count is 2,068.
- ✅ All 9 sort columns, ascending and descending, paged at 500: 2,068 rows, each flowbin exactly once.
- ✅ Two-chunk export (1,100 + 968 = 2,068): 0 duplicates, 14 columns, values match the screen.
- ✅ The new ids are not exposed.
- ⏸ Equal stock units: no data on dev; covered by the IT.

**ClickUp:** `on dev`, ACs 1–4 ticked with evidence.

**Next:** run `archive-plan`. UAT and PRD promotion is devops; check `relowner` on each tenant before promoting.

## 13. Findings disposition at archival (2026-10-31)
| Finding | Disposition |
|---|---|
| Per-tenant `relowner` check of `flowbin_monitor_view` before UAT/PRD promotion (42501 risk) | **Not machine-knowable, owner: devops** at promotion. Stated in the PR #590 body and on the ticket |
| PRD report latency after deploy, including whether JIT triggers (estimated cost ~100k, at the threshold) | **Not machine-knowable, owner: Nam** at PRD promotion. On the ticket |
| ⏸ Manual dev scenario "equal stock units on one flowbin" | **Dropped.** Dev has 0 such flowbins; IT 2, 3, 7 and 8 cover it, and M2, M3 and M8 are killed |
| P-a: a fixed-location assignment's item can differ from the stocked item | **Dropped** (Nam, 2026-10-31). 0 rows on dev and PRD. Joining the assignment on item would hide the bounds of the 2 empty assigned PRD flowbins |
| P-b: `v1-to-v2-onboarding/README.md:34` stale since SBDEV-3239 | **Proposed: P37** in `2-Areas/proposals-register.md`. Ride-along on the next wms2-api change to the onboarding toolkit |
| Proposal P34 (this ticket) | **Fixed:** wms2-api #590, merge `9d184321`, on dev. The P34 register row now points at the archived plan |

> Archived 2026-10-31. No acceptance script (T3 opt-out; the invariants live in JUnit).
> Implementation worktree removed 2026-10-31: wms2-api/SBDEV-3952 (branch merged via #590 as `9d184321`; local branch deleted, remote branch left to GitHub).
