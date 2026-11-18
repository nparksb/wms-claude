---
name: wms2-report-list-rows-are-hand-built-dto-maps
description: "Adding a column to a wms2 report view + entity does NOT reach the screen: ViewDtoService builds list rows key-by-key; the export is a third separate copy"
metadata:
  type: project
---

A wms2 report column lives in up to FOUR places, and the entity field reaches only some of them automatically:
1. the SQL view (Flyway migration),
2. the `@Entity` view class (plus `LIST_KEY` / native export `ORDER BY`, enforced by `ReportViewListKeyUnitTest` and `PagedNativeExportTotalOrderArchTest`),
3. **`ViewDtoService.get<X>ByKeyword`** — the on-screen list endpoint builds each row with `dto.put("key", result.getX())`, so a new entity field is silently absent from the JSON,
4. `ReportService.export<X>` — `Object[]` rows + a positional header array.

**Why:** SBDEV-3552 (2026-10-31) added Manifest Location to view, entity and export; every gate test was green and the screen column would have been blank on every row. Both review lanes caught it; no test of mine went through the list endpoint.

**How to apply:** for any "add a column to report X" ticket, grep `dto.put(` in `ViewDtoService` for the report's method and write one failing test on the list DTO (`containsEntry(key, value)`) alongside the view IT and export test. Related: [[hub-code-traps]], [[hub-wms-ui]].
