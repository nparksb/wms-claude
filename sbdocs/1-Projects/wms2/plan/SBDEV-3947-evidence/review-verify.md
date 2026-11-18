# SBDEV-3947 verification lane (a48e3f0d) - read-only

Method: read-only (git show, grep, Read). No mvn, no DB, no worktree edits. Base: origin/develop 219ad551.

## Verdict: PASS (confidence medium-high). 0 High, 2 Medium, 3 Low.
Nothing blocks the PR. The Mediums are things to state in the PR body and to double-check; none needs a code change.

## 1. Callers
- All 11 methods have exactly one production caller each, in `service/ReportService.java` (lines 79, 128/129, 171, 205, 243, 284, 319, 379/380, 426). No other caller in src/main.
- No caller sorts afterwards or relies on the old order. `grep -nE "sort|Comparator|stream\(\)" ReportService.java` returns nothing. Rows are copied into `Object[]` in the order received and handed to `fileExportService.exportExcelFile`.
- There is no server-side chunk loop. `ReportController` takes `offset` and `limit` from the request. The UI (`wms2-web-ui/components/reports/popups/exportReport.vue`) has the user type "Offset" and "No of records" for each file. So "chunk offset arithmetic" is the user's own offset, and nothing in the backend can be off by one.
- No huge single limit: `ReportController.MAX_EXPORT_RECORDS = 10_000` (`exportLimit` rejects more). Worst case ORDER BY adds a sort of the filtered set, then OFFSET+LIMIT. Offset is capped only at Integer.MAX_VALUE.
- Low: the UI check allows `noOfRecords` 0 (`< 0` is the only test); the server rejects it (`limit < 1`). Not caused by this commit.

## 2. User-visible order change in the Excel files (for the PR body)
"Before" is the view's own inner ORDER BY. An inner ORDER BY with `OFFSET` on top is honoured in practice but not guaranteed, which is the bug.

| Export | Before | After | Visible change |
|---|---|---|---|
| Receiving (`receiving_dto_view`) | `a.created DESC, a.modified DESC` (V2.2.00:84) | `adviceid, advicepositionid` | YES. Newest-advice-first becomes advice id ascending (oldest first). |
| Lock, default (`lock_overview_dto_view`) | `su.created DESC, su.modified DESC` (V2.2.02) | `stockunitid` | YES. Newest-first becomes stock unit id ascending. |
| Lock, include shipped (`lock_overview_all_view`) | same | `stockunitid` | YES. Same change. |
| Stock/Inventory (`stock_view`) | none (grouped by i.id, unspecified) | `item_id` | Defined order replaces an unspecified one. Likely looks the same. |
| Order detail / Parcel Picking | none (DISTINCT, unspecified) | `client_number, client_order_number, ...` (all 15 columns) | Defined order replaces an unspecified one. It now begins with the client number. |
| Flowbin | `loc.name` | `location_name, then 12 more columns` | No visible change on the primary key. Only ties are reordered. |
| Parcel (`parcel_monitor_view`) | `co.created DESC` | `created DESC, customer_order_number, bol_number` | No visible change. Only ties are reordered. |
| SKU location | `c.cl_nr, itemdata.item_nr` | `client_number, sku_number, location_id` | No visible change. Only ties are reordered. |
| Stockrecord x2, unitload_record | `created DESC` | `created DESC, id DESC` | No visible change. Only ties are reordered. |

Wording check: the commit message says Receiving and Lock lost their order. The migration SQL shows they did have a created-DESC order, so the PR body should say it plainly: "Receiving and Lock exports now sort by id ascending instead of newest first."

## 3. Indexes for stockrecord and unitload_record
- stockrecord: `index_stockrecord_created (created)` (V2.2.00:4303) and `index_stockrecord_client_created (client_id, created DESC)` (V2.2.33:149). No later DROP INDEX on stockrecord (grep).
- unitload_record: only the primary key (`unitload_record_pkey`, V2.2.00:3804). No index on `created`, before or after. Every unitload_record export already sorts a full filtered scan (top-N heap sort for OFFSET+LIMIT). Adding `id DESC` adds a second sort key and no meaningful cost.
- stockrecord with `created DESC, id DESC`: the planner can still use the `created` index with a backward scan, then Incremental Sort on `id` inside each created group (groups are 2 or more tied rows). The filtered query uses `(client_id, created DESC)`, whose client_id equality prefix fits the same way. Incremental Sort needs PostgreSQL 13 or later. Production runs 14.23 (`PostgresTestHarnessPinTest` javadoc, V2.2.33 comment), so it is available. Risk is low.
  - Residual risk: on PG 12 or earlier, or with `enable_incrementalsort=off`, the plan degrades to a full sort of a table of about 9.7M rows. That is a known-cause regression, not a data risk.
  - The keyword predicate (`CONCAT(LOWER(...)) LIKE`) is not index-supported either before or after, so it does not change the picture.
- I did not run EXPLAIN (no DB, per rules). **Medium (M2):** the claim above is derived from PG semantics, not measured. Suggest one EXPLAIN (ANALYZE, BUFFERS) on dev for the unfiltered stockrecord export at a deep offset (e.g. 5,000,000) to confirm "Incremental Sort" over "Index Scan Backward".

## 4. Test adequacy (by reading)
Mutant coverage, 11 ORDER BY clauses:
- `PagedNativeExportTotalOrderArchTest.eachPagedExportOrdersByItsAgreedKey` pins the exact normalised ORDER BY list per method (alias, case and ASC normalised). Removing the clause gives null, so it is caught. Dropping, reordering or misspelling a column makes the list unequal, so it is caught. Dropping a DESC is caught for the three created-DESC users plus Parcel.
- `everyPagedNativeQueryIsPinned` catches a new, unpinned paged query. It has a non-vacuity assertion on both `:name` and `?N` spellings.
- `ViewExportOrderByExecutesIT` executes all 8 view queries on PostgreSQL. Removing a clause is not caught here (the SQL is still valid), but a misspelled column would fail at parse time, even if the Arch EXPECTED list were edited to match.
- `RecordExportTieOrderIT` runs the three record queries over six rows with identical `created`, one row per chunk, and requires id DESC order. Removing `id DESC` is caught behaviourally (the test inserts ids ascending). It also catches `id ASC`.
- Conclusion: every one of the 11 clauses is guarded by at least the Arch test (removal or misspelling), and views by the IT (nonexistent column), records by the IT (tie behaviour). So "removed or misspelled" is caught for all 11. Confirmed by reading. I could not confirm the 11 mutation runs.

Gaps:
- **Medium (M1): uniqueness of the keys is asserted, not tested.** Arch test is text-only; the view IT runs on empty views (its own javadoc says so). Reading the SQL here:
  - Receiving `(adviceid, advicepositionid)`: view groups by a.id, ap.id and by columns that are many-to-one from ap, so one row per pair. Holds.
  - Lock `stockunitid`: `stockunit su` with only LEFT JOINs to parent tables. Unique. Holds.
  - Stock `item_id`: grouped by i.id. Holds.
  - SKU location `(client_number, sku_number, location_id)`: grouped by itemdata.id, c.id, loc.id. Holds.
  - Parcel `(created, customer_order_number, bol_number)`: customer_order_number is unique, so ties exist only where one order has several BOL positions for the parcel, and bol_number then differs. Holds unless one parcel sits on two positions of the same BOL (identical output rows, harmless).
  - Flowbin: not unique by design (amount is round()ed in the output). Ties are rows identical in all 13 output columns, so a swap, skip or repeat among them is invisible in the file. Count could still differ by one in theory if identical rows straddle a chunk boundary. This is acceptable and stated in the commit.
  - Order detail: DISTINCT over the same 15 columns, so unique.
  - Suggestion: a PR-body sentence that uniqueness was checked on dev data and view SQL, as the test javadoc says.
- Low: `PagedNativeExportTotalOrderArchTest` does not see `LIMIT x OFFSET y` spelling or JPQL/Pageable queries (its javadoc admits this). I grepped src/main for other `offset` uses in repositories; the 11 are the only ones I found in `*Repository.java` using `OFFSET` binds.
- Low: the Arch test lives in `unit/repo`, the ITs are failsafe-scope; confirm the CI job runs both (not checked here, no mvn).

## Other findings
- Low: Java comments in the repository annotations sit inside string concatenation as `//` lines. Compiles and passes the test (comments are outside the string value). No issue.
- Lock slowdown (dto 139 to 717 ms/chunk, all-view up to about 5 s/chunk) is accepted by the product owner, tracked as P33. Not re-litigated. Note it in the PR body since 5 s per 10,000-row chunk is user-visible.

## Files
- Commit: a48e3f0d in /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3947
- Caller: src/main/java/net/aim_ai/wms/service/ReportService.java
- Limit cap: src/main/java/net/aim_ai/wms/controller/ReportController.java (MAX_EXPORT_RECORDS)
- Indexes: src/main/resources/db/migration/V2.2.00__base_v2_schema.sql (4303), V2.2.33__stockrecord_view.sql (149)
- View definitions: V2.2.00__base_v2_schema.sql, V2.2.02__lock_report_exclude_shipped.sql

---
## Author follow-up (2026-10-29): M2 measured on dev

dev_wh01_om1, PostgreSQL 16.10, stockrecord 9,727,248 rows. EXPLAIN (ANALYZE) of the unfiltered export, keyword '':

| ORDER BY | offset | plan | time |
|---|---|---|---|
| created DESC (old) | 5,000,000 | Index Scan Backward using index_stockrecord_created | 8738 ms (cold cache, first run) |
| created DESC, id DESC (new) | 5,000,000 | **Incremental Sort** (156,413 groups, 34 kB peak) over the same Index Scan Backward | 1348 ms (warm) |
| created DESC, id DESC (new) | 0 | Incremental Sort over the same index, parallel | fast (first chunk) |

Verdict: no full sort; the existing created index is still used. M2 closed. The cold/warm difference is cache, not the change.
M1: carried into the PR body (uniqueness rests on the view SQL + dev data, recorded on the ticket).
