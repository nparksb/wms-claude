# SBDEV-3952 — analysis lane: flowbin_monitor_view (replen over-count + stock-unit merge)

Graded against origin/develop @ dde23325 (`git show origin/develop:<path>`, not the checkout). DBs: dev `dev_wh01_om1`, PRD `wh01_om1_v2` (read-only, flyway 2.2.41, PG 14.23). 2026-10-30. Produced by the Opus analysis lane; saved by the main session (the harness blocked the lane's own Write).

**Corrections to the brief:**
1. **The integration tests no longer scan the onboarding set.** `CLAUDE.md:225`: "The IT harness migrates `classpath:db/migration` … (changed by SBDEV-3239)". Only the unread `test/resources/flyway.conf:11` still points at the onboarding set. `v1-to-v2-onboarding/README.md:34` is stale on the same point.
2. `fix_location_assignment` is **UNIQUE(assignedlocation_id)** (`V2.2.00:3764`, `uk_qakwvmdhdymic54v3dgie46wa`) and **UNIQUE(itemdata_id)** (`:3716`). Confirmed on dev and PRD with `pg_index`. Assignments cannot multiply rows.

## §0 Affected sites
Method: `git grep -n -i "flowbin_monitor_view\|FlowbinMonitorView" origin/develop`, 95 hits, each one triaged.

### View definitions
| # | File | Flyway-scanned? | Change? |
|---|---|---|---|
| D1 | `db/migration/V2.2.00__base_v2_schema.sql:1124-1156`: `LEFT JOIN public.replenishorder r ON ((r.itemdata_id = i.id))` … `GROUP BY … su.amount, su.reservedamount, …, f.active, f.*` | Yes (prod and every IT) | No. Fix forward in V2.2.43. |
| D2 | `v1-to-v2-onboarding/schema/V1.0.02__wms_views.sql:51` | No (manual psql; ITs don't read it) | No |
| D3 | `schema/V1.2.01__utc_standard_tables.sql:88`: `DROP VIEW … CASCADE` | No | No |
| D4 | `schema/V1.2.04__utc_recreate_views.sql:91`: "verbatim latest definition" | No | No (§3.4) |
| D5 | `rollback/V1.2.99…:54,326,378` (MANUAL USE ONLY) | No | No |
| D6 | `onboarding-tz-variants/V1.2.01…NY:99`, `V1.2.99…NY:63,335,387` (no V1.2.04 NY copy) | No | No |
| D7 | `db/ref/losref*.sql` | No | No |

### Consumers
- `model/FlowbinMonitorView.java:11-13`: `@Id @Column(name="row_id")`, where `row_id` is `row_number() OVER ()`. It is unique within one statement and unstable across statements (already documented in the repository and in ReportService). The test profile uses `ddl-auto=validate`, so entity and view must change together.
- `FlowbinMonitorViewRepository:24-26` `LIST_KEY`, with the comment "every mapped column together is [unique]". **This becomes false once GROUP BY is removed.** Equal stock units give identical rows.
- `:30-33` `findByKeywordAndClientName` (list, `Page<>`) and `:36-44` `findByClientOffsetAndLimit`, whose ORDER BY lists the 13 columns. Its comment, "No unique key reaches the output", needs a rewrite.
- `ReportController:493-503` `/flowbinMonitorView` (`WEB_UI_VIEW_FLOWBIN_MONITOR`): no change.
- `ViewDtoService:1413-1438` builds a 14-key Map by hand, so a new field is not serialized unless it is added there.
- `ReportService:240-283` export, 14 columns, `row[0] = ++rowNumber`: no change.
- `RestConfiguration:494,899` lists the entity; the repository is `exported=false`: no change.
- `PagedNativeExportTotalOrderArchTest:65-68` EXPECTED for Flowbin: **re-pin.**
- `ReportViewListKeyUnitTest:54,68`: "LIST_KEY names every mapped column except row_id", and it must equal the export ORDER BY. It fails automatically if they disagree, which is a free safeguard.
- `ViewExportOrderByExecutesIT:44` (empty view) and `PagedListSortExecutesIT:168`: still valid.
- Controller, Service and ViewDto unit tests, plus the SDR and gating tests: no change.
- **No existing test asserts any value the view computes.** Every IT runs it on an empty view.

## §1 Confirmed defects
- **(b)** Replens are joined on item only. Dev examples: `00-A07` and `05-A06` show 12 where the correct value is 0.
- **(a)** The GROUP BY has no `su.id`, so equal stock units merge and the replen sum is multiplied. 0 cases on both databases; the defect is structural.

## §2 Census (dev | PRD)
| Probe | dev | PRD |
|---|---|---|
| flowbins | 2,068 | 2,149 |
| flowbin SU rows | 1,344 | 1,562 |
| empty flowbins | 724 (1 UL with no SU, `05-C09`) | 587 |
| view rows = flowbins | yes | yes |
| flowbins with >1 SKU / >1 SU / >1 UL | 0 | 0 (**blind spot**: no data exercises these) |
| merge groups (a) | 0 | 0 |
| >1 assignment per flowbin | 0 | 0 (impossible: UNIQUE) |
| assignment item ≠ stocked item | 0 | 0 (positive control: `=` matches 1,344 / 1,562) |
| empty flowbin with an assignment | 0 | **2** (must keep bounds and `fix_assignment_exists='true'`) |
| open replens (all state 300) | 566 (95 no destination) | 560 (25 no destination) |
| open replens to non-flowbins | 0 | 0 |
| **open replen to a flowbin not stocking that SKU** | **2** (`00-B01`, `00-B03` empty) | **1** (`53-C01`) |
| view ≠ destination-only sum | 4 | 1 |
| view ≠ destination+item sum | 2 (the (b) rows; positive control) | **0** |
| dependent views | 0 | 0 |
| owner / ACL | `wh01_om1` / none | `wh01_om1_v2_app` / `{…app=arwdDxt, wms2_landlord_app=arwd}`; single owner across `public` |

**D-1 (Nam's call):** count by destination only, or by destination+item? Destination-only changes 1 PRD row (53-C01 0→24) and shows replens to empty flowbins. Destination+item changes 0 PRD rows and hides those replens. **The lane recommends destination-only**, the literal reading of "PER FLOWBIN". If a flowbin ever holds several stock units, each row would repeat the flowbin total; there are 0 such flowbins today.

**Proposals, not in scope:**
- P-a: assignment/stock item mismatch. 0 rows. Leave the join as-is; joining on item would hide bounds on the 2 empty PRD flowbins.
- P-b: `v1-to-v2-onboarding/README.md:34` is stale (one-line doc fix).

## §3 Fix design
### 3.1 `V2.2.43__flowbin_monitor_view_per_flowbin_replen.sql`
```sql
CREATE OR REPLACE VIEW public.flowbin_monitor_view AS
 SELECT row_number() OVER () AS row_id, loc.name AS location_name, c.cl_nr AS client_id, c.name AS client_name,
    i.item_nr AS sku_id, i.name AS sku_name,
    COALESCE(round(su.amount),(0)::numeric) AS amount, COALESCE(round(su.reservedamount),(0)::numeric) AS reserved,
    COALESCE(round(f.lowerbound),(0)::numeric) AS lower_bound, COALESCE(round(f.middlebound),(0)::numeric) AS middle_bound,
    COALESCE(round(f.upperbound),(0)::numeric) AS upper_bound,
    COALESCE((SELECT sum(round(r.requestedamount)) FROM public.replenishorder r
               WHERE r.destination_id = loc.id AND r.state < 600),(0)::numeric) AS requested_replenishment,
    CASE WHEN (f.id IS NULL) THEN 'false'::text ELSE 'true'::text END AS fix_assignment_exists,
    f.active,
    su.id AS stock_unit_id
   FROM public.location loc JOIN public.location_type t ON t.id = loc.type_id
     LEFT JOIN public.fix_location_assignment f ON f.assignedlocation_id = loc.id
     LEFT JOIN public.unitload ul ON ul.storagelocation_id = loc.id
     LEFT JOIN public.stockunit su ON su.unitload_id = ul.id
     LEFT JOIN public.itemdata i ON i.id = su.itemdata_id
     LEFT JOIN public.client c ON c.id = i.client_id
  WHERE (t.sltname)::text = 'flowbin'::text;
```
- No GROUP BY: one row per stock unit, which fixes (a). The scalar subquery cannot be multiplied. It uses `idx_replenishorder_state_destination`.
- `f.* IS NULL` becomes `f.id IS NULL`, removing the whole-row dependency that `V1.2.01:74-75` warns about.
- The view-level ORDER BY is dropped; every caller orders explicitly.
- The first 14 columns keep name, order and type, and `stock_unit_id` is appended, so `CREATE OR REPLACE` is legal (precedents `V2.2.01`, `V2.2.33:84-85`). DROP+CREATE would lose PRD's `wms2_landlord_app` grant.

### 3.2 Validated with read-only SELECT + `EXCEPT ALL` on the 13 old columns
- PRD: 2,149 = 2,149 rows. 1 difference (`53-C01=24`). 0 duplicates of `(location_name, stock_unit_id)`. 587 NULL rows, at most 1 per location.
- dev: 2,068 = 2,068 rows. Differences: `00-A07=0, 00-B01=12, 00-B03=12, 05-A06=0`.
- Perf (dev): old view 2,021 ms, new view 1,051 ms. A nested `(unitload JOIN stockunit)` form took 1,473 ms, so use plain left joins. PRD refused EXPLAIN ANALYZE, so PRD timing is unmeasured.

### 3.3 Stable key
- `(location_name, stock_unit_id)` is unique (flowbin names are unique; 0 duplicates).
- Entity: add `@Column(name="stock_unit_id") Long stockUnitId`. **Keep `@Id` on row_id**, because a NULL id would drop the empty-flowbin rows.
- Append `stock_unit_id` to `LIST_KEY`, the export ORDER BY and the arch-test EXPECTED, and rewrite the "no unique key" comments.

### 3.4 Onboarding
- README:24-26: "converted v1 client lands at the same schema version as a fresh v2 DB, and both continue on V2.2.x+ deltas". V2.2.43 therefore reaches every tenant. Don't edit D2–D6.
- Risk: a tenant whose views were created by a superuser during psql onboarding hits **42501**. Remedy: `db/reassign-tenant-ownership.sh`. Check `relowner` on all tenants before deploying.

## §4 Tests
- Harness: `BasePostgresIntegrationTest` (`postgres:14-alpine`, migrates `classpath:db/migration`, `ddl-auto=validate`).
- Copy `OrderDetailMonitorViewStateFilterIT`: `@Transactional(tenantTransactionManager, NOT_SUPPORTED)`, a class-unique id block, `JdbcTemplate` seed and cleanup.
- Seed notes: `location_type` id 2 = 'flowbin' (`V2.2.00:2547`). Fixed-location assignments are UNIQUE per location and per item. `idx_replenishorder_active_item_dest` allows one active replen per (item, destination) while state < 700.
- `FlowbinMonitorViewPerFlowbinIT`:
  1. `replenToOtherFlowbinIsNotCountedOnThisOne`
  2. `twoEqualStockUnitsOnOneFlowbinAreTwoRows`
  3. `twoEqualStockUnitsDoNotMultiplyRequested`
  4. `emptyFlowbinIsStillListedOnce`
  5. `closedReplenIsExcluded` (states 600 and 700)
  6. `replenToEmptyFlowbinIsShown` (only if D-1 is destination-only)
  7. `exportOrderIsTotalOverEqualRows`
- Re-pin `PagedNativeExportTotalOrderArchTest`. `ReportViewListKeyUnitTest` follows automatically.

## §5 Acceptance criteria and risks
**Acceptance criteria:**
- AC1: requested = Σ round(requestedamount) over replens with destination = this location and state < 600.
- AC2: one row per stock unit; replen value not multiplied.
- AC3: each empty flowbin appears exactly once, with assignment bounds if it has one.
- AC4: `LIST_KEY`, the export ORDER BY and the arch-test pin all end in `stock_unit_id`.
- AC5: append-only `CREATE OR REPLACE`; `stock_unit_id` is ordinal 15.
- AC6 (optional): no whole-row dependency on `fix_location_assignment`.

**Risks:**
- D-1 changes 1 PRD row.
- PRD performance is unmeasured.
- Web UI (`flowbinReport.vue`): columns use `value:` camelCase names, sort is sent as `camelToSnakeCase` (`:361`), `item-key="key"` is a client-side index, and the detail popup excludes `rowId`, `_links` and `key`. The DTO is built by hand, so recommend not exposing `stockUnitId`. No sortable column is renamed.
- 42501 on other tenants.
- Stale Javadoc to update: repository `:21-23,41-42`, arch test `:63-64`, ListKey test `:37`.

## §6 Prior plans
- SBDEV-3947 `review-code.md:53-57` L2 found the missing `su.id` and the item-only replen join, and proposed **P34** (excluded there because it needed a migration). **This ticket is P34.**
- `architect-consult.md:14` chose "order by all output columns".
- SBDEV-3951 added `LIST_KEY` and `ReportViewListKeyUnitTest`.
- Other hits only touch gating, SDR exposure or filters: 2967-B, 3017-B1, 3142, 3169, 3410, 2624, `260424-Outbound_Parcel`, and 3668 (in passing).
