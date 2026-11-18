# SBDEV-3947 independent code review: a48e3f0d (wms2-api)

Lane: code-review, read-only. Worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3947`, base origin/develop 219ad551.
Method: `git show a48e3f0d`, grep and targeted reads of the view SQL in `src/main/resources/db/migration` (latest definitions) and in `db/v1-to-v2-onboarding/schema` (the definitions that legacy/onboarded tenants and the IT harness actually carry). I also read `target/surefire-reports`, written by the suite that is running now. No mvn, no DB, no edits to the worktree.

## Verdict: REQUEST CHANGES. 1 High, 0 Medium, 6 Low.

The ORDER BY choices are correct: all 11 are total over every row that differs in output, on both schema lineages. One existing unit test is red at this commit and has to be updated before the PR.

---

## HIGH

### H1. `StockrecordExportQueryContractUnitTest` still pins the old ORDER BY, so it fails at a48e3f0d
Confidence: HIGH. The running suite has already recorded the failure.
- `src/test/java/net/aim_ai/wms/unit/repo/StockrecordExportQueryContractUnitTest.java:88`
  ```java
  + "order by p.created DESC "
  + "offset :offset limit :limit";
  ```
  `unfilteredExportQueryTextIsByteIdentical` (line 148) checks this with `isEqualTo(UNFILTERED_QUERY)` against `StockrecordRepository.findByOffsetAndLimit`. The commit changed that query to `order by p.created DESC, p.id DESC` but did not touch the test.
- Evidence: `target/surefire-reports/net.aim_ai.wms.unit.repo.StockrecordExportQueryContractUnitTest.txt`, 17:44, after the 17:34 commit: `Tests run: 5, Failures: 1 ... unfilteredExportQueryTextIsByteIdentical ... expected: "... order by p.created DESC offset ..." but was: "... order by p.created DESC, p.id DESC offset ..."`. At the time of reading (1,911 report files) it was the only failing class.
- The pin is designed so that any change must be made on purpose (its javadoc says exactly that). This change is on purpose.
- Fix: change line 88 to `+ "order by p.created DESC, p.id DESC "`. Add a sentence to the javadoc next to the SBDEV-2907 note, for example "SBDEV-3947 appended `p.id DESC` so OFFSET/LIMIT chunks page over a total order." The second assertion in that class (`startsWith(... indexOf("order by"))`) is unaffected.

---

## Per-view uniqueness check (Q1)

The latest definitions are the same in both lineages: base dump V2.2.00 (+ V2.2.02 for lock) and onboarding V1.2.04 (+ V2.1.17 for lock). Differences are whitespace and quoting only. I compared the column lists and the GROUP BY / DISTINCT clauses side by side.

| Export | ORDER BY | Unique per output row? | Evidence |
|---|---|---|---|
| Receiving | adviceid, advicepositionid | Yes | V2.2.00:4632-4680 `GROUP BY a.id, ..., ap.id, ...`. Every other join is to-one by PK (itemdata, client, unitload_type, boxtype x2, location). `grp` is the only to-many join and it is aggregated. An advice with no positions gives one row with `ap.id` NULL, which is still unique per advice. The comment is accurate. |
| Stock | item_id | Yes | V2.2.00:4685 `GROUP BY i.id, i.item_nr, c.id, c.cl_nr`, and client is to-one. "Not item_nr: unique only per client" is accurate (`uk3l3dgof3l6mc1dl7s3lmida65 UNIQUE (client_id, item_nr)`). |
| Lock / Lock (all) | stockunitid | Yes | V2.2.02:15-61. `FROM stockunit su`, and all five LEFT JOINs are by PK, so each stock unit gives one row. "One row per stock unit" is accurate. |
| SKU location | client_number, sku_number, location_id | Yes | V2.2.00:2248 `GROUP BY itemdata.id, ..., c.id, ..., loc.id, ...`. Each row is one (item, location). `(cl_nr, item_nr)` identifies the item because `client.cl_nr` is `NOT NULL` + `UNIQUE` (`uk_e2cgvit466blvvac3y77crsyg`, V2.2.00:3676, and V1.0.01:157) and itemdata has `UNIQUE (client_id, item_nr)`. V2.2.33 asserts the latter on every tenant. See L5 for the comment wording. |
| Order detail | all 15 columns | Yes | V2.2.00:1642 `SELECT DISTINCT` over exactly these 15 columns. DISTINCT and ORDER BY both treat NULLs as equal, so no two distinct rows can tie. The comment is accurate. |
| Parcel | created DESC, customer_order_number, bol_number | Yes in practice | V2.2.00:1834. `customerorder.number` is `UNIQUE` (`uk_3gimugm3yg5ft57rqwdm7jw6a`), and for a given order only `bop`/`bo` can multiply rows, so only `bol_number` varies. Rows that tie on all three keys are therefore identical in every column except `row_id`. See L1 for the nullable-number edge. |
| Flowbin | location_name + all 12 other columns | Total up to identical rows | V2.2.00:1124. There is no key in the output. Rows that tie on all 13 columns can only be swapped with each other, so the sorted sequence of values is the same on every execution. See L2 and L3. |
| Stockrecord x2 / unitload_record | created DESC, id DESC | Yes | `id bigint NOT NULL`, PK. |

---

## LOW

### L1. Parcel: "order number (UNIQUE)" holds only when the number is not NULL
Confidence: MEDIUM that the gap exists, LOW that it happens in practice.
- `ParcelMonitorViewRepository.java` comment: `// Today's order (co.created DESC), then the order number (UNIQUE) and the BOL.` Arch test EXPECTED comment: `remaining ties are identical rows`.
- `customerorder.number character varying(255)` is nullable (`CREATE TABLE public.customerorder`, line 9 of the table). A PostgreSQL UNIQUE constraint allows any number of NULLs. Two parcels with the same `created`, `number IS NULL` and no BOL would tie while differing in every other column. Orders are numbered by the app, so this is probably impossible on live data. I could not check it, because the DB MCP servers failed to connect in this session.
- Fix: no code change needed. Optionally reword the comment to "UNIQUE; NULL never seen on dev". Or append `p.customer_external_number` (`index_customerorder_externalnumber UNIQUE`), which costs nothing.

### L2. Flowbin's no-key situation is a pre-existing view defect, not only a rounding artifact
Confidence: HIGH that the SQL reads this way. Out of scope for this ticket; ticket-policy proposal.
- V2.2.00:1149 / V1.2.04:91: `GROUP BY loc.name, c.cl_nr, c.name, i.item_nr, i.name, su.amount, su.reservedamount, f.lowerbound, ..., f.*`. The GROUP BY has no `su.id` / `ul.id`. Two stock units of the same SKU on one flowbin with equal `amount`/`reservedamount` collapse into one row that shows a single SU's amount, not the sum. `requested_replenishment = sum(...)` over the `replenishorder` join is multiplied by the number of collapsed SUs.
- The new comment, `No unique key reaches the output (round(amount) of a grouped raw amount)`, is true but describes only half of the problem. The ORDER BY in this commit is still correct for the view as it stands.
- Proposal, not in this PR: a flowbin view fix that sums per (location, item) and pre-aggregates replenishorder. It needs a migration, which the PO excluded here.

### L3. Exported "ID" / "Row ID" columns are `row_number() OVER ()` and still not stable across chunks
Confidence: HIGH. Pre-existing and not made worse.
- `ReportService.java:247` (Flowbin `row[0] = view.getRowId()`), `:209` (SKU location `view.getId()`, `row_number()` in `view_warehouse_location_report`), `:288` (Order detail), `:323` (Parcel, header "Row ID"). Each is numbered over the whole unfiltered view in scan order, separately on every execution. The window is evaluated before the outer ORDER BY.
- After this fix the business rows are partitioned correctly across files, but the ID column of file 2 can repeat values from file 1, and IDs are not ascending within a file. Anyone who dedupes or reconciles a multi-file export by that column will be misled. It also means "ties are identical rows" for Flowbin is true of the data but not of the file.
- Fix, optional follow-up: emit `offset + i + 1` as the ID in ReportService for these four exports, or drop the column. No migration needed.

### L4. Arch test javadoc lists a blind spot that does not exist, and omits two that do
Confidence: HIGH.
- `PagedNativeExportTotalOrderArchTest.java` javadoc: `a paged query written as {@code LIMIT … OFFSET …} ... is not scanned`. This is wrong. `PAGED = "(?i)\\bOFFSET\\s+(?::[A-Za-z]\\w*|\\?\\d+)"` is applied with `find()`, so `... LIMIT :limit OFFSET :offset` matches. `ORDER_BY` is lazy up to `(?:OFFSET|LIMIT)`, so it also reads that spelling correctly. The verify lane (`review-verify.md`, Low 2) repeated the same incorrect claim.
- Blind spots that are real and unstated: (a) `OFFSET CAST(:x AS int)` and `OFFSET (:x)` are not matched, because the regex requires the bind straight after whitespace; (b) Spring Data JPA 3.4+ `@NativeQuery`, which is meta-annotated with `@Query` and so missed by `m.getAnnotation(Query.class)`; (c) native SQL in classes (`entityManager.createNativeQuery`, JdbcTemplate), because only interfaces are scanned. Today none of these exist in src/main. grep finds no `@NativeQuery`, and `createNativeQuery` appears only in `PutawayConfigService:309,494`, neither paged.
- Fix: correct the javadoc sentence. Optionally widen PAGED to `OFFSET\s+(?:\(|CAST\s*\()?\s*(?::\w+|\?\d+)` and use `AnnotatedElementUtils.findMergedAnnotation(m, Query.class)`.

### L5. SKU-location comment names the wrong key
Confidence: HIGH, wording only.
- `ViewWarehouseLocationReportRepository.java`: `(client, sku) is the itemdata key, so the triple is unique`. The itemdata key is `(client_id, item_nr)`, but the ORDER BY uses `client_number` (`c.cl_nr`). The conclusion holds only because `client.cl_nr` is also `NOT NULL UNIQUE`.
- Fix: "(cl_nr is UNIQUE, and (client_id, item_nr) is the itemdata key) so the triple is unique".

### L6. `RecordExportTieOrderIT`: no recorded red run against the old SQL, and the fixture commits rows visible to the shared DB
Confidence: MEDIUM.
- Vacuity: the javadoc reasons that a tie-blind sort "has no reason to produce" id DESC. By PostgreSQL semantics I agree it would not: a bounded heap with bound 1 keeps the first-scanned row, and the insertion sort for n < 7 is stable and ascending. So the test should go red under `created DESC` alone. Neither the commit nor the evidence dir records an actual red run, though, and the verify lane also says it "could not confirm the 11 mutation runs". The floor requires a mutation check for each new assertion.
- Leakage: the seed uses `PostgresTestSupportConfig.jdbcTemplate()`, which has its own `DriverManagerDataSource`, so it auto-commits outside the class's `@Transactional("tenantTransactionManager")`. The rows are visible to anything that reads `stockrecord` or `unitload_record` while the test method runs. One example is `StockrecordViewSchemaIT:211`, which does `SELECT count(*) FROM stockrecord`. This is harmless when ITs run sequentially, and `@BeforeEach wipe()` plus `@AfterEach` cover a crashed previous run. The id block 3947001-3947006 has no other user under src/test (grep). The "auto-commits (SBDEV-3258)" claim is accurate.
- Fix: record one red run (revert `, p.id DESC` / `, id DESC` on the three queries and check the IT fails for the expected reason) in the evidence dir.

---

## Q2: comments inside string concatenation
All new `//` lines sit between `+`-joined string literals, outside the string values, so they do not change the SQL. Accuracy is covered above: Receiving, Stock, Lock and Order detail are accurate; Parcel is L1, Flowbin is L2/L3 and SKU location is L5. The Stockrecord/unitload "shared by 2+ rows on dev" comments match the IT javadoc figures (1,254,464 / 81,674).

## Q4: paged native exports the scan misses
- grep for `"... offset|limit <bind>"` strings in src/main/java found 17 hits. 11 are the pinned exports. The other 6 are `LIMIT`-only without OFFSET: `MessageRepository:101`, `UnitloadRepository:484` (already ordered `md5(...), u.id`), `PickingorderRepository:181,197`, `StockrecordRepository:238` (ordered `created, id`) and `CustomerorderBatchRepository:47`. None of them is chunked by offset, so the scan's set is complete for `OFFSET <bind>` in native `@Query` today.
- `ReportService` has no `setFirstResult`/`setMaxResults`/`Pageable`. Each HTTP request is one chunk, with offset/limit from the user (`ReportController.exportOffset`), so the `row_id` `@Id` cannot collide across chunks in one persistence context.
- Out of scope, noted only: the on-screen grids page the same views through `Pageable` (`findByKeyword(..., PageRequest)`), and with no sort they have the same non-determinism. That is not an export and was not in scope.

## Q3: other tests
- `ViewExportOrderByExecutesIT`: not vacuous for its stated claim. PostgreSQL resolves ORDER BY columns at parse time, so a misspelled column throws even on an empty view. Its blind-spot statement ("proves the SQL is valid, not that the order is total") is accurate. The IT harness builds its schema from `db/v1-to-v2-onboarding/schema` (README), which is the legacy-tenant lineage. That is a plus: it executes against the definitions WineCo-type tenants actually carry.
- `PagedNativeExportTotalOrderArchTest`: has a non-vacuity guard (both bind spellings must be found) and an exact-set check (`containsExactlyInAnyOrderElementsOf`). Surefire: `Tests run: 3, Failures: 0`. Besides L4, "every paged native query in the codebase" is scoped by the scan, and the javadoc states the method.

## Positive observations
- The key choices are right and well reasoned, including the non-obvious ones: `row_id` rejected as a key, `item_nr` rejected because it is per-client, and the full column list for DISTINCT/Flowbin.
- Lock and Receiving now order by an ascending surrogate key, so rows inserted during a multi-file export land at the end and do not shift earlier chunks. That is better than the old `created DESC`.
- The arch test makes the next paged export fail until someone decides its key. That is the right invariant-over-instance guard.
- The verify lane's EXPLAIN follow-up (Incremental Sort, 1348 ms at offset 5M) settles the stockrecord cost question.

## Files
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3947/src/test/java/net/aim_ai/wms/unit/repo/StockrecordExportQueryContractUnitTest.java` (H1, line 88)
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3947/target/surefire-reports/net.aim_ai.wms.unit.repo.StockrecordExportQueryContractUnitTest.txt` (H1 evidence)
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3947/src/test/java/net/aim_ai/wms/unit/repo/PagedNativeExportTotalOrderArchTest.java` (L4)
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3947/src/main/java/net/aim_ai/wms/repo/jpa/ParcelMonitorViewRepository.java` (L1), `ViewWarehouseLocationReportRepository.java` (L5), `FlowbinMonitorViewRepository.java` (L2)
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3947/src/main/java/net/aim_ai/wms/service/ReportService.java` (L3: 209, 247, 288, 323)
- View SQL: `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql` (1124, 1642, 1834, 2248, 4632, 4685), `V2.2.02__lock_report_exclude_shipped.sql`, `src/main/resources/db/v1-to-v2-onboarding/schema/V1.2.04__utc_recreate_views.sql`

---
## Author disposition (2026-10-29)

| # | Finding | Disposition |
|---|---|---|
| HIGH | `StockrecordExportQueryContractUnitTest` pin expects old ORDER BY | Fixed in its own commit: pin text updated, javadoc and assertion message name SBDEV-3947 as the deliberate change |
| L1 | Parcel key tie when `customerorder.number` is NULL | Fixed: ORDER BY now ends with every other output column (agreed key first, unchanged). Dev: 0 NULL order numbers, 0 duplicate keys in 1,367 rows. Arch pin updated; mutant `carrier_m9` killed by the IT and the arch test |
| L2 | Flowbin view GROUP BY lacks `su.id` | Confirmed in the view SQL. Found a second defect while verifying (replens joined on item only, not destination). Proposed as **P34** (T3, needs a view migration), not filed |
| L3 | "ID" column is per-query `row_number()` | Fixed: 4 exports now write `offset + i + 1`. 4 new tests in `ReportServiceUnitTest$ExportIdColumnIsTheAbsolutePosition`; each mutant reverting to the view id was killed with `[7, 3]` named in the message. Sibling sweep: the remaining `getId()` ID columns (stockrecord, unitload_record) are real primary keys |
| L4 | Arch-test javadoc blind spots wrong | Fixed: either clause order is recognised; lists CAST/parenthesised binds, `@NativeQuery`, SQL outside repository interfaces, JPQL/Pageable |
| L5 | SKU-location comment names the wrong key | Fixed; claims verified in V2.2.00: `client.cl_nr NOT NULL` + `UNIQUE (cl_nr)`, `itemdata UNIQUE (client_id, item_nr)` |
| L6 | No recorded failing run of `RecordExportTieOrderIT` on the old SQL | Recorded: TDD gate (pre-fix tree, 219ad551 SQL) 3/3 FAIL, one reading `[3947001, 3947001, 3947003, ...]` (repeat + skip); mutation run on the fix (two reverted to `created DESC`, one to `id ASC`) 3/3 FAIL with "rows sharing created must be paged in id DESC" |
