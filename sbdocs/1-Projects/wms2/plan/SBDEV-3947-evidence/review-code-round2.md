---
ticket: SBDEV-3947
kind: code-review
round: 2
scope: "git show 6a017c8f 492c12ac (wms2-api, bugfix/SBDEV-3947-export-order-by)"
reviewer: code-reviewer lane (read-only; no mvn, a full suite was running in the worktree)
date: 2026-10-29
verdict: APPROVE (with 3 Low comment fixes recommended)
---

# SBDEV-3947 code review, round 2 (6a017c8f, 492c12ac)

Scope: only the two fix commits. a48e3f0d was reviewed in `review-code.md`. I checked each claim in that
file's "Author disposition" table against the diff.

**Files reviewed:** 6 (`StockrecordExportQueryContractUnitTest`, `ParcelMonitorViewRepository`,
`ViewWarehouseLocationReportRepository`, `ReportService`, `PagedNativeExportTotalOrderArchTest`,
`ReportServiceUnitTest`)
**Findings:** 0 Critical, 0 High, 0 Medium, 3 Low

## Stage 1: the fixes do what the dispositions say

| Disposition | Verified | Evidence |
|---|---|---|
| HIGH: stockrecord pin | Yes | Pin text `order by p.created DESC, p.id DESC ` matches `StockrecordRepository.java:162`. Only the ORDER BY line changed. The predicate is byte-identical to before. |
| L1: Parcel tie | Yes | The ORDER BY now lists all 13 non-`row_id` columns of `parcel_monitor_view` (V2.2.00:1834-1847): created, customer_order_number, bol_number, client_number, client_order_number, customer_external_number, parcel_name, state, pallet_name, customer_order_fulfillment_type, location_name, priority, carrier. None is missing and none is misspelled. The arch-test `EXPECTED` list matches the SQL element for element, in the same order. The agreed key still comes first. |
| L3: positional ID | Yes, but the rationale comment is wrong (Low-1) | Four exports now write `++rowNumber` starting from `offset`. |
| L4: arch-test blind spots | Yes | `PAGED` uses `find()`, so either clause order is recognised. Ran `grep -rn "@NativeQuery" src/main/java`: 0 hits. No `OFFSET CAST(`/`OFFSET (` occurs in any SQL string. The only `createNativeQuery` calls (`PutawayConfigService:309,494`) have no OFFSET. So the claim "None occurred in src/main on 2026-10-29" holds. |
| L5: SKU-location comment | Yes | V2.2.00: `client.cl_nr ... NOT NULL` (:740) + `UNIQUE (cl_nr)` (:3676); `itemdata.item_nr NOT NULL` (:937), `client_id NOT NULL` (:947), `UNIQUE (client_id, item_nr)` (:3580). The view joins the client through `itemdata.client_id = c.id` (:2264), so `(client_number, sku_number)` does identify one item. The view groups by `loc.id`, so the triple with `location_id` is unique. |

## Stage 2: what the task asked me to check

### ID numbering: type
`FileExportService.setCellValue` (:236-264) handles `Integer` (:241) and `Long` (:245) as separate branches. Any other numeric type would throw `UnsupportedOperationException`.

| Export | Before | After | Same type? |
|---|---|---|---|
| SKU location | `view.getId().intValue()` → Integer | `int rowNumber; row[0] = ++rowNumber` → Integer | yes |
| Flowbin | `view.getRowId().intValue()` → Integer | `int` → Integer | yes |
| Parcel Picking | `view.getRowId()` (`Long`, `OrderDetailMonitorView:44`) | `long` → Long | yes |
| Outbound Parcel | `view.getRowId()` (`Long`, `ParcelMonitorView:40`) | `long` → Long | yes |

The new tests pin the type. `containsExactly(OFFSET + 1, ...)` boxes to Integer for the int exports, and
`OFFSET + 1L` boxes to Long for the long exports. `Integer.equals(Long)` is false, so a type change turns the test red.

### ID numbering: offset semantics
- `ReportController.exportOffset` (:90-96) accepts any whole number ≥ 0. SQL `OFFSET n` skips n rows, so the first row is at position n+1, and `++rowNumber` starting from `offset` is correct.
- The UI (`wms2-web-ui/components/reports/popups/exportReport.vue:97,132,174`) defaults offset to `0`, sends it unchanged and rejects values below 0. So the UI's offset is also 0-based.
- Overflow: `limit ≤ MAX_EXPORT_RECORDS = 10_000` (:68), but `offset` can be as large as `Integer.MAX_VALUE`. The `int` counters for SKU and Flowbin could only wrap if a row existed at position 2^31−10,000 or later. That needs a view of more than 2.1 billion rows, so this cannot happen in practice and is not a finding.

### Does anyone depend on the old ID values?
- No reader exists in the code. Ran `grep` for `XSSFWorkbook|WorkbookFactory` in src/main: only the writer in `BillofladingService:1330`, which is unrelated. Nothing reads an export back in.
- None of the four export URLs is referenced in `sbdocs/3-Resources`.
- In the UI, the four `store/reports/*.js` files only download the blob.
- No existing test asserted `row[0]` for these four exports. The only `row[0]` assertion in `ReportServiceUnitTest` (:1408) belongs to the Lock export.
- So the change is visible to users but nothing depends on the old values (Low-2).

### Tests: STRICT_STUBS
- The class is annotated `@MockitoSettings(strictness = Strictness.STRICT_STUBS)` (:39).
- Removing the 10 `getRowId`/`getId` stubs was required, not optional. The exports no longer call those getters, so under STRICT_STUBS each stub would now raise `UnnecessaryStubbingException`.
- None of those 10 tests asserted the ID. Each one only does `verify(fileExportService).exportExcelFile(any(), eq("Receiving"), any(), any(), any(), any())` (for example :790 and :1076). Removing the stubs therefore removed no assertion.
- New helpers: the id/rowId getter is stubbed with `lenient()`, which is correct because the export must not call it. Every other stub in the helpers is strict, and each one is read by the export:
  - SKU: `getLocationId().longValue()`, `getStockQuantity().intValue()`, `getStockReserved().intValue()`
  - Flowbin: the six `BigDecimal.intValue()` calls
  - Both parcel exports: `getState()` → `getCodeText`
- Each strict stub is also needed: without it the export would hit an NPE when unboxing.
- The view mocks are built inside `List.of(...)` before the repository `when(...)`, so no stubbing is left unfinished. `lenient` comes from the static import `org.mockito.Mockito.*` (:32).
- Mutants these tests kill:
  - reading the view id back: the file gets `[7, 3]`
  - post-increment instead of pre-increment: `[10000, 10001]`
  - a constant `offset + 1`: `[10001, 10001]`
  - a changed boxed type
- I did not run the tests (instruction: no mvn). `target/surefire-reports/` held no `ReportServiceUnitTest` report when I looked. Judging by reading, the code compiles: `BigDecimal` and `IOException` are imported, `.toList()` is available on Java 21, and the raw `ArgumentCaptor` cast follows the existing pattern at :1402.

## Findings

[LOW-1] The rationale comment "restarts at 1 in every file" misdescribes the old ID
File: `src/main/java/net/aim_ai/wms/service/ReportService.java:207-208, 249-250, 294-295, 333-334`. The same claim appears in the `ReportServiceUnitTest$ExportIdColumnIsTheAbsolutePosition` javadoc and in the commit message.
Confidence: HIGH
Quoted: `// ... The view id is row_number() OVER (), which restarts at 1 in every file and does not follow the ORDER BY.`
Issue:
- In all four views, `row_number() OVER ()` sits in the view's own select list (V2.2.00:1125, 1643, 1835, 2249). PostgreSQL cannot push the outer `WHERE` below a window function that has no PARTITION, and it applies the outer `ORDER BY`/`OFFSET` after the window.
- So each query numbers the whole unfiltered view (1..M) in scan order, and the OFFSET slice then takes an arbitrary subset of those numbers.
- File 2's IDs therefore do not restart at 1. They are scattered values that can repeat file 1's and do not ascend. That is exactly how round-1 L3 described it ("numbered over the whole unfiltered view in scan order, separately on every execution").
- The code fix is right regardless; only the explanation is wrong. A reader who checks a file 2, sees IDs that do not start at 1, and concludes the bug was misdiagnosed would be misled.
Fix: replace it with something like `The view id is row_number() OVER () over the whole unfiltered view, recomputed per query in scan order, so it repeats across files and does not follow the ORDER BY.` Apply the same wording to the test javadoc.

[LOW-2] The values in the "ID"/"Row ID" column change for users; record it on the ticket
File: `ReportService.java:213, 255, 300, 339`
Confidence: MEDIUM (that someone notices; no code reader exists, see above)
Issue:
- The column changes from the view's `row_number()` to the row's position in the export. Anyone who kept older exports would see different numbers for the same row.
- Positional numbering is also only consistent across files when the data does not change between the chunk requests. A row inserted between chunk 1 and chunk 2 shifts both the rows and the positions. This is inherent to OFFSET paging and not a regression, but it limits what "ID" means.
Fix: add one line on the ticket or in the release note: "Export ID/Row ID is now the row's 1-based position in the whole export (offset + n), not a view-internal number." No code change.

[LOW-3] The stockrecord pin's javadoc and message still count one deliberate change
File: `src/test/java/net/aim_ai/wms/unit/repo/StockrecordExportQueryContractUnitTest.java:69-70, 80, 140-141`
Confidence: HIGH
Quoted: `Captured byte-for-byte at origin/develop f2ee75f1, before P3 touched the file, and widened once since (below).`. The message reads `SBDEV-3947 another (the id DESC tie-break). §3.6 permitted ONE edit to this method`.
Issue:
- After this commit the text has changed twice (SBDEV-2907, then SBDEV-3947). The phrase "widened once since" is stale, and SBDEV-3947 changed the ordering, not the width.
- "The one edit §3.6 permits" now sits right after two listed changes. §3.6 belongs to SBDEV-2907's plan, but nothing in the text says so, so a reader cannot tell which "one edit" is meant.
Fix: change "widened once since (below)" to "changed twice since (below)", and change "§3.6" to "SBDEV-2907's plan §3.6" in both the javadoc and the assertion message.

## Open questions
None.

## Positive observations
- The type for each export was preserved deliberately: `int` for the two that used `.intValue()`, `long` for the two that wrote `Long`. The tests pin it through boxed equality.
- The lenient stubs return a value the position can never equal (7 and 3 against 10001 and 10002), so reverting to the view id fails with a readable message.
- Positional IDs combined with the 13-column Parcel order make the rows that still tie (fully identical rows) byte-identical in the file, including the ID column. Their relative order is therefore no longer observable at all.
- Each new comment in the repositories has a schema citation behind it, and I checked every one of them.
- The sibling sweep in the disposition holds: the remaining `getId()` ID columns (stockrecord, unitload_record) are real primary keys.

## Recommendation
**APPROVE.** No High or Critical findings at any confidence level. The three Lows concern comment and documentation accuracy only, and the code behaves correctly.
Per the "address Low findings too" rule, fix Low-1 and Low-3 in the comments. Low-2 is a line on the ticket.

---
## Author disposition (2026-10-29), commit 2c342692 (comment/message text only)
- LOW-1: fixed in ReportService (4 comments) and the test-class javadoc: "recomputed per query over the whole view in scan order, so it repeats across files and does not follow the ORDER BY".
- LOW-2: no code change; noted on the ticket and in the PR body (ID / Row ID values change; positions consistent across files only while the data does not change between chunk requests, inherent to OFFSET paging).
- LOW-3: fixed: "changed twice since"; §3.6 attributed to **SBDEV-3410's** plan (the file header names SBDEV-3410 P3; the review's "SBDEV-2907's plan" was a slip). Assertion message reworded accordingly.
