---
title: "Excel Export 500 — UnsupportedOperationException on java.time Cell Types"
ticket: ""
ticket_url: ""
type: "bug"
priority: "high"
status: "implemented"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-06-10"
updated: "2026-06-10"
db_verified: true
related:
  - "../../../4-Archieves/wms2/plan/SBDEV-2233-nametypeservice-date-format-pattern-fix.md"
  - "../../../1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md"
  - "../../../4-Archieves/wms2/plan/SBDEV-2215-adviceservice-no-transaction-wrapping.md"
tags:
  - plan
  - bug
  - export
  - file-export
  - java-time
  - localdatetime
  - reports
  - cyclecount
  - bol
  - advice
---

# Excel Export 500 — `UnsupportedOperationException` on `java.time` Cell Types

**Ticket:** (none — internal defect)
**Project:** wms2/wms2-api | **Version:** v2 (Java 21 / Spring Boot 3.5.x) | **Type:** Bug (regression + latent)
**Priority:** High | **Target branch:** `develop`
**Status:** Draft
**Date:** 2026-06-10
**db_verified:** true (wms2-wineco-dev2 via MCP)

---

## 0. Affected Sites Enumeration

### In scope — six broken exports (all re-verified on `develop` HEAD `576f1dd`)

| # | Feature | Service file:line | Cell value | Static type | Export path |
|---|---------|-------------------|------------|-------------|-------------|
| 1 | Reports → Stock Unit Record | `ReportService.java:328` `row[1] = view.getCreated()` | `Stockrecord.getCreated()` | `LocalDateTime` (`AbstractBaseEntity.java:29`) | `exportExcelFile` (`ReportService.java:357`) |
| 2 | Reports → Container Record | `ReportService.java:374` `row[1] = view.getCreated()` | `UnitloadRecord.getCreated()` | `LocalDateTime` (`AbstractBaseEntity.java:29`) | `exportExcelFile` (`ReportService.java:390`) |
| 3 | Receiving → Inbound Notice export | `AdviceService.java:537-538` `getRow("Day of Delivery"/"... Until", ...)` | `Advice.getDayofdelivery()` / `getDayofdeliveryuntil()` | `LocalDate` (`Advice.java:16-17`) | preHeaderRows → `exportExcelFile` (`AdviceService.java:545`) |
| 4 | Inbound BOL export (detailed) | `BillofladingService.java:892` `getRow("shipped at", billOfLading.getShipped())` | `Billoflading.getShipped()` | `LocalDate` (`Billoflading.java:21`) | preHeaderRows → `exportExcelFile` (`BillofladingService.java:905`) |
| 5 | Cycle Count export (HTTP) | `CyclecountService.java:196` `row[1] = position.getModified()` | `CyclecountPosition.getModified()` | `LocalDateTime` (`AbstractBaseEntity.java:32`) | `getExcelFile` agg (`:189`) + `exportExcelFile` detail (`:208`) |
| 6 | Cycle Count export2 (stream/email) | `CyclecountService.java:258` `row[1] = position.getModified()` | `CyclecountPosition.getModified()` | `LocalDateTime` | `getExcelFile` agg (`:251`) + detail (`:270`) |

**Site 6 (`exportCycleCount2`) dead-code note.** Grep of `src/main/java` finds **zero production callers** of `exportCycleCount2` — the email/stream path was never wired into production. It is, however, **unit-tested at `CyclecountServiceUnitTest.java:558-655`** (5 test references), so the method is not unreferenced in the test tree. It is in scope per user decision; the `FileExportService` fix covers it for free (same `getExcelFile` path). No separate manual test is required (no production click-path exists).

### Not affected — the other seven `ReportService` exports

| Export method | Why not affected |
|---------------|------------------|
| inventory export | passes only `String`/`Integer`/`Long`/`BigDecimal`/`Boolean`/enum-text (`ReportService.java:79-267`) |
| lock export | same — no `java.time` value in any row cell |
| receiving export | same |
| skuLocation export | same |
| flowbin export | same |
| parcelPicking export | same |
| outboundParcel export | same |

No `Instant` or `OffsetDateTime` getter appears in any export row builder on `develop`. `OutboxMessage` (`Instant`) and `CustomerorderCancellationLog` (`OffsetDateTime`) are never routed through these export paths — confirming the `Instant`/`OffsetDateTime` branches in Fix A are **defensive only**.

`readXLSFile` / `readXLSXFile` (`FileExportService.java:300-378`) are the import path (cell→Object). Unaffected. **No change.**

---

## 1. Problem Statement

### Reported symptom

Operators clicking "Export" on any of six pages get an opaque failure. The UI surfaces exactly:

> **Error: Request failed due to a network or server issue. Please retry.**

The backend returns HTTP 500 with an empty body — retrying never succeeds because the cause is deterministic, not transient.

### Affected pages / repro steps

| Page | Repro |
|------|-------|
| Reports → Stock Unit Record | Open the report → click Export Excel → 500 |
| Reports → Container Record | Open the report → click Export Excel → 500 |
| Receiving → Inbound Notice | Open an advice with a Day-of-Delivery → Export → 500 |
| Inbound BOL (detailed) | Open a BOL with a `shipped` date → Export (detailed) → 500 |
| Cycle Count | Run a cycle count → Export → 500 |

### DB verification (wms2-wineco-dev2, live via MCP) — confirms every path is reproducibly broken

```sql
SELECT count(*), max(created)::text FROM stockrecord;
→ cnt=7,313,455   max_created='2026-06-08 17:38:37.795+00'

SELECT count(*), max(created)::text FROM unitload_record;
→ cnt=6,213,707   max_created='2026-06-08 17:38:37.808+00'

SELECT count(*) FILTER (WHERE dayofdelivery IS NOT NULL), max(dayofdelivery)::text, count(*) FROM advice;
→ advice_dod_notnull=14,429   max_dod='2026-06-04'   advice_total=14,997

SELECT count(*) FILTER (WHERE shipped IS NOT NULL), max(shipped)::text, count(*) FROM billoflading;
→ bol_shipped=2,812   max_shipped='2026-06-05'   bol_total=2,812

SELECT count(*) FILTER (WHERE modified IS NOT NULL), max(modified)::text, count(*) FROM cyclecount_position;
→ ccp_modified=4,087   max_modified='2026-02-05 18:05:31.56+00'   ccp_total=4,087

-- Column SQL types
advice.dayofdelivery       = date
advice.dayofdeliveryuntil  = date
billoflading.shipped       = date
stockrecord.created        = timestamp with time zone
unitload_record.created    = timestamp with time zone
cyclecount_position.modified = timestamp with time zone

SELECT syskey, sysvalue FROM los_sysprop WHERE syskey = 'System Time Zone';
→ 'System Time Zone' = 'America/Los_Angeles'
```

**Column-type observation.** The three timestamp columns are `timestamptz` on this tenant (partially migrated ahead of `feature/utc-timezone`). The entity field is still `LocalDateTime` on both branches — Hibernate reads `timestamptz` into `LocalDateTime` via the JVM zone, so the value reaching `FileExportService` is still a `LocalDateTime`. The bug is unchanged by the column type.

---

## 2. Root Cause Analysis

### Bug 1 (root cause) — `FileExportService` has no `java.time` `instanceof` branch

`FileExportService` builds every cell via four `instanceof` chains (preHeader + rows, across `exportExcelFile` and `getExcelFile`). Each chain handles `String`/`Boolean`/`Integer`/`BigInteger`/`Long`/`BigDecimal`/`Date` and then throws:

```java
// FileExportService.java:152-155 (representative of all four chains)
} else if (cellContent instanceof Date d) {
    cell.setCellValue(CELL_TIMESTAMP_FORMAT.format(d.toInstant()));
} else {
    throw new UnsupportedOperationException("row=" + (rowIndex + 1) + " ...");  // L155
}
```

There is **no `LocalDateTime`, `LocalDate`, `Instant`, or `OffsetDateTime` branch**. When `Stockrecord.getCreated()` (a `LocalDateTime`) lands in a cell, it falls through to the four throw sites at **`FileExportService.java:89, 155, 218, 284`**.

Because `UnsupportedOperationException extends RuntimeException`, it bypasses the controllers' `catch (BusinessException e)` and escapes to Spring's default 500 handler.

The existing `Date` branch and the class-level formatter `CELL_TIMESTAMP_FORMAT` at `FileExportService.java:32-33` were added by the archived **SBDEV-2233** plan (which also collapsed four per-call `SimpleDateFormat("YYYY-…")` allocations into one formatter). That plan did **not** add `java.time` branches — entities still used `java.sql.Timestamp` then.

### Bug 2 (latent) — controllers catch only `BusinessException` AND write an empty error body

All five HTTP-visible endpoints (see §2 table below) catch only `BusinessException`. Additionally, inside that catch they populate `errors` via `getErrorMessage(...)` but then write `errorMap.toString()` — a different, empty `HashMap` declared at the top of each method — to the response. So even a genuine `BusinessException` produces a blank body.

```java
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
    response.getWriter().write(errorMap.toString());  // always "{}" — wrong variable
    ...
}
```

### Bug 3 (typo) — `exporContainerRecord`

`ReportService.java:365` declares `public void exporContainerRecord(...)` (missing the `t`). Called at `ReportController.java:277`. Internal-only — the REST path `/exportContainerRecord` and the controller method `exportContainerRecord` (`ReportController.java:266`) are correctly spelled, so the public URL is unaffected.

### Controller endpoints for all five HTTP-visible sites

| # | Controller + method | Mapping | File:line / catch | Catches | Service call |
|---|---------------------|---------|-------------------|---------|--------------|
| 1 | `ReportController.exportStockUnitRecord` | `POST /exportStockUnitRecord` | `ReportController.java:240-262`, catch L253, write L256 | `BusinessException` only | `reportService.exportStockUnitRecord(...)` L252 |
| 2 | `ReportController.exportContainerRecord` | `POST /exportContainerRecord` | `ReportController.java:265-287`, catch L278, write L281 | `BusinessException` only | `reportService.exporContainerRecord(...)` L277 ← typo call |
| 3 | `AdviceController.exportOutboundBol` (maps `/exportInboundNotice`) | `POST /exportInboundNotice` | `AdviceController.java:329-351`, catch L342, write L345 | `BusinessException` only | `adviceService.exportInboundNotice(...)` L341 |
| 4 | `BillOfLadingController.exportOutboundBol` | `POST /exportOutboundBol` | `BillOfLadingController.java:265-287`, catch L278, write L281 | `BusinessException` only | `billofladingService.exportOutboundBOL(...)` L277 |
| 5 | `CycleCountController` (export) | `POST` (cyclecount export) | `CycleCountController.java:108-134`, catch L125, write L128 | `BusinessException` only | `cyclecountService.exportCycleCount(...)` L124 |

### Affected Locations

| # | File | Line | Description | Fix |
|---|------|------|-------------|-----|
| 1 | `service/FileExportService.java` | 89, 155, 218, 284 | four throw sites; no `java.time` branch | A |
| 2 | `service/FileExportService.java` | 32-33 | existing `CELL_TIMESTAMP_FORMAT` (must not clobber) | A |
| 3 | `service/ReportService.java` | 365 | `exporContainerRecord` typo declaration | B |
| 4 | `controller/ReportController.java` | 240-287 | two endpoints, `BusinessException`-only catch + typo call | B, C |
| 5 | `controller/AdviceController.java` | 329-351 | `BusinessException`-only catch | C |
| 6 | `controller/BillOfLadingController.java` | 265-287 | `BusinessException`-only catch | C |
| 7 | `controller/CycleCountController.java` | 108-134 | `BusinessException`-only catch | C |

---

## 3. Regression Chain

**Root-cause commit:** `6e5af846` — *"modernize temporal handling to use java.time API across entities and services"* (Nam Park, **2026-02-18**). `git log -S "private LocalDateTime created"` pins this as the commit that replaced `java.sql.Timestamp created/modified` with `private LocalDateTime created/modified` in `AbstractBaseEntity.java`. Before this, `created`/`modified` were `Timestamp` (which `instanceof java.util.Date`) and hit the existing `Date` branch. After it, the values fall through to the throw.

**Predecessor relationship — SBDEV-2233.** `SBDEV-2233-nametypeservice-date-format-pattern-fix.md` reworked the same four throw sites (to fix a `YYYY` week-year bug) and introduced `CELL_TIMESTAMP_FORMAT` at `FileExportService.java:32-33`, but added only the `Date` branch. The `java.time` gap was created later by `6e5af846`.

**Line-drift note.** SBDEV-2233 documents the throw sites as `L84/152/217/285`. Subsequent commits drifted them 2-3 lines to today's `L89/155/218/284`. Both refer to the same sites. This plan cites the `develop` HEAD (`576f1dd`) numbers throughout.

---

## 4. Architecture Overview

```
[UI export dialog] ── click "Export Excel"
        │  POST /exportStockUnitRecord | /exportContainerRecord | /exportInboundNotice
        │       | /exportOutboundBol | (cyclecount export)
        ▼
[Controller]  ReportController / AdviceController / BillOfLadingController / CycleCountController
        │   try { service.exportX(...) }
        │   catch (BusinessException) → writes errorMap.toString()  ← Bug 2 (empty body)
        │   (NO catch for any broader exception type)               ← Bug 2 (escapes to 500)
        ▼
[Service row-builder]  ReportService / AdviceService / BillofladingService / CyclecountService
        │   builds Object[] rows; places LocalDateTime / LocalDate raw into cells
        │   getRow(String, Object) helpers pass value unchanged
        ▼
[FileExportService.exportExcelFile / getExcelFile]
        │   for each cell: instanceof String/Boolean/Integer/BigInteger/Long/BigDecimal/Date
        │   → no java.time branch
        ▼
   throw new UnsupportedOperationException(...)   ← Bug 1 (FileExportService.java:89/155/218/284)
        │  (unchecked) escapes BusinessException catch → Spring default 500
        ▼
[UI toast] "Error: Request failed due to a network or server issue. Please retry."
```

### Key Files

| File | Role | Anchor lines |
|------|------|-------------|
| `service/FileExportService.java` | cell-type dispatch (bug + fix) | 32-33, 89, 155, 162, 218, 284 |
| `service/ReportService.java` | row builders (sites 1, 2) + typo | 328, 365, 374 |
| `service/AdviceService.java` | preHeader builder (site 3) + `getRow` | 537-538, 553-558 |
| `service/BillofladingService.java` | preHeader builder (site 4) + `getRow` | 892, 905, 913-918 |
| `service/CyclecountService.java` | row builders (sites 5, 6) | 196, 258 |
| `controller/ReportController.java` | endpoints 1, 2 | 240-287 |
| `controller/AdviceController.java` | endpoint 3 | 329-351 |
| `controller/BillOfLadingController.java` | endpoint 4 | 265-287 |
| `controller/CycleCountController.java` | endpoint 5 | 108-134 |
| `model/AbstractBaseEntity.java` | `LocalDateTime created/modified` | 29, 32 |
| `model/Advice.java`, `model/Billoflading.java` | `LocalDate` fields | 16-17 / 21 |
| `service/WmsConstants.java` | `DATE_PATTERN`, `DATE_TIME_PATTERN` | 826-827 |

---

## 5. Fix Design

### Fix A — `FileExportService`: extract `setCellValue` helper + add `java.time` branches (Phase 1)

**Decision (Option 2 from RALPLAN-DR).** Extract one private helper `setCellValue(Cell cell, Object content, CellStyle style, int rowForError)` that consolidates all four byte-identical `instanceof` chains and adds the missing types. This collapses 4× duplication — the very condition that allowed the original gap — into one place, making "fixed 3 of 4 sites" structurally impossible. The caller passes the already-adjusted row index (preHeader sites pass `rowIndex`, row sites pass `rowIndex + 1`), preserving the existing error-message numbering.

**Injection constraint.** `FileExportServiceUnitTest.java:38` and `FileExportServiceTest` both construct `new FileExportService()` (no-arg). Phase 1 does **not** require `SyspropService` (no zone conversion). The no-arg constructor is preserved — **no test-construction change needed for Phase 1.**

**Representation tradeoff (deliberate, recorded).** Dates are written as **`String` cells**, consistent with the existing `Date` branch from SBDEV-2233 (which already does `CELL_TIMESTAMP_FORMAT.format(d.toInstant())`). **Native Excel date cells** (sortable/filterable via a `CellStyle` data format — POI 5.x supports `cell.setCellValue(LocalDateTime)` natively) are **deliberately out of scope** because: (a) they would diverge from the existing `Date` columns in the *same sheet*, producing two date representations in one export and surprising any consumer who already built tooling around the string format; and (b) `setCellValue(Date)` applies the JVM default zone when computing the serial, so mixing native and string cells reintroduces a JVM-zone hazard once `feature/utc-timezone` flips the JVM to UTC — exactly the hazard this plan keeps cleanly in Phase 2. If ops needs sortable/filterable native date columns, file it as a **separate enhancement** that converts *all* date columns (including the `Date` branch) consistently and re-baselines export golden output.

**Phase 1 semantics (target `develop`):**
- `LocalDateTime` (`created`/`modified`) are stored as **LA wall-clock** on `develop` (JVM/Hibernate zone = `America/Los_Angeles`, `application.properties:107-108`). Format directly with `DATE_TIME_PATTERN` — **no conversion is correct here.**
- `LocalDate` (`dayofdelivery`, `dayofdeliveryuntil`, `shipped`) are **calendar dates** (DB column type `date`, already rendered to UI JSON as plain `yyyy-MM-dd` at `AdviceService.java:333`). Format with `DATE_PATTERN` — **no conversion in any phase.**
- `Instant` / `OffsetDateTime` branches are **defensive** — no current caller routes them through exports, but `feature/utc-timezone` may add such fields.

**Before** (representative — `FileExportService.java:152-155`):
```java
} else if (cellContent instanceof Date d) {
    cell.setCellValue(CELL_TIMESTAMP_FORMAT.format(d.toInstant()));
} else {
    throw new UnsupportedOperationException("row=" + (rowIndex + 1) + " ...");
}
```

**After** (new private helper; all four chains delegate to it):
```java
private static final DateTimeFormatter CELL_DATE_FORMAT =
        DateTimeFormatter.ofPattern(WmsConstants.DATE_PATTERN);        // "yyyy-MM-dd"
private static final DateTimeFormatter CELL_DT_FORMAT =
        DateTimeFormatter.ofPattern(WmsConstants.DATE_TIME_PATTERN);   // "yyyy-MM-dd HH:mm:ss"

private void setCellValue(Cell cell, Object content, CellStyle style, int rowForError) {
    if (content == null) return;
    if (content instanceof String s)            { cell.setCellValue(s); }
    else if (content instanceof Boolean b)      { cell.setCellValue(b); }
    else if (content instanceof Integer n)      { cell.setCellValue(n); }
    else if (content instanceof BigInteger bi)  { cell.setCellValue(bi.intValue()); }
    else if (content instanceof Long l)         { cell.setCellValue(l); }
    else if (content instanceof BigDecimal bd)  { cell.setCellValue(bd.intValue()); }
    else if (content instanceof Date d)         { cell.setCellValue(CELL_TIMESTAMP_FORMAT.format(d.toInstant())); }
    // Phase 1 (develop): LocalDateTime stored as LA wall-clock — format directly, no conversion.
    // Phase 2 (post feature/utc-timezone merge): convert UTC→warehouse via TimezoneService.
    else if (content instanceof LocalDateTime ldt) { cell.setCellValue(CELL_DT_FORMAT.format(ldt)); }
    // LocalDate: calendar date — no timezone conversion in any phase.
    else if (content instanceof LocalDate ld)   { cell.setCellValue(CELL_DATE_FORMAT.format(ld)); }
    // Defensive: not in export paths today; future-proof for feature/utc-timezone.
    else if (content instanceof Instant i)          { cell.setCellValue(CELL_TIMESTAMP_FORMAT.format(i)); }
    else if (content instanceof OffsetDateTime odt) { cell.setCellValue(CELL_DT_FORMAT.format(odt.toLocalDateTime())); }
    else {
        throw new UnsupportedOperationException("row=" + rowForError + " contains unsupported type=" + content.getClass());
    }
    cell.setCellStyle(style);
}
```

New imports: `java.time.LocalDateTime`, `java.time.LocalDate`, `java.time.Instant`, `java.time.OffsetDateTime` (add only those not present — `java.time.ZoneId` and `java.time.format.DateTimeFormatter` already imported at L18-19; `java.math.BigInteger` already imported at L17). **No caller changes** — the raw `java.time` values stay in the `Object[]` rows; the `getRow(String, Object)` helpers pass them through unchanged.

**Phase 2 is OUT of scope (follow-up, blocked on merge).** Phase 2 (UTC→warehouse conversion of `LocalDateTime` via `TimezoneService`) must NOT be in this plan because (a) `TimezoneService` does not exist on `develop` — referencing it would not compile; (b) on `develop` the values are already LA-relative, so conversion would be *wrong*; (c) it is only correct after `feature/utc-timezone` flips the JVM to UTC. File Phase 2 as a separate plan blocked on that merge, touching only the `LocalDateTime` branch.

### Fix B — rename `exporContainerRecord` → `exportContainerRecord`

`ReportService.java:365` declaration. The typo appears as **11 occurrences across 4 files** (grep-verified):

| File | Line | Context |
|------|------|---------|
| `ReportService.java` | 365 | method declaration |
| `ReportController.java` | 277 | `reportService.exporContainerRecord(...)` call |
| `ReportServiceUnitTest.java` | 409 | `@DisplayName("exporContainerRecord")` — fix display string too |
| `ReportServiceUnitTest.java` | 433, 447, 487, 517 | call sites |
| `ReportControllerUnitTest.java` | 430, 438, 451, 459 | verify/when call sites |

Count: 1 (decl) + 1 (controller call) + 5 (`ReportServiceUnitTest`) + 4 (`ReportControllerUnitTest`) = **11**.

**Do NOT touch `ReportControllerUnitTest.java:418`** — its `@DisplayName("POST /v3/report/exportContainerRecord")` contains the **correctly-spelled URL**, not the typo. The verify script's `! grep -rn "exporContainerRecord"` will not match it (the URL is spelled with the `t`), so it is safe.

The controller method (`ReportController.java:266`) and `@PostMapping("/exportContainerRecord")` are already correct — **the public REST URL is unaffected.** Internal-only rename.

### Fix C — controller hardening: additive `catch (Exception)` + write populated `errors`

Add a `catch (Exception e)` block after each existing `catch (BusinessException e)` on the five endpoints, and fix the existing `BusinessException` block to write `errors.toString()` instead of the empty `errorMap.toString()`.

**Catch breadth — deliberate choice (`Exception`, not `RuntimeException`).** The goal is **no opaque 500 from the export try-block, ever** — the precise outcome we are fixing. A narrow `catch (RuntimeException)` would leave *checked* exceptions and any future exception type as latent 500 vectors. Notably `FacadeException extends Exception` (checked), and sibling endpoints in this codebase already use `catch (BusinessException | FacadeException)`. Catching `Exception` closes the class of hole rather than one instance of it. Java requires the catch order **`BusinessException` first, then `Exception`** (more-specific-before-more-general) — already satisfied because the existing `BusinessException` catch stays first and unchanged. The handler logs at `LOG.error(..., e)` with full stack trace before writing the body, so genuine programming bugs are **not** hidden from monitoring — they surface in logs while the user gets a structured body instead of an opaque 500.

```java
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
    try {
        response.getWriter().write(errors.toString());   // was errorMap.toString() (empty) — fixed
        response.getWriter().flush();
    } catch (IOException e2) { LOG.error(e2.getMessage()); }
} catch (Exception e) {                                    // NEW — catches UnsupportedOperationException + all others
    LOG.error("export failed unexpectedly: {}", e.getMessage(), e);
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
    try {
        response.getWriter().write(errors.toString());
        response.getWriter().flush();
    } catch (IOException e2) { LOG.error(e2.getMessage()); }
}
```

**Scope of the guarantee (precise).** Fix C guarantees no opaque 500 for **exceptions thrown by the service call inside the `try` block** (e.g. the `UnsupportedOperationException` from `FileExportService`). It does **not** cover code that runs **before** the `try` — e.g. `AdviceController.java:334` `((Integer) reqMap.get("id")).longValue()` and the `adviceRepository.findById(...).orElseThrow(...)` that precede the try can still throw `ClassCastException` / `NullPointerException` / `EntityNotFoundException` and return a 500. Those pre-try casts are **pre-existing and explicitly out of scope** (see §10 risk row and §12). Hardening them is a separate, broader controller-input-validation effort.

**Response-not-committed safety (verified `FileExportService.java:35-169`).** `response.getOutputStream()` is first touched at **`FileExportService.java:162`**, *after* the full workbook is built in memory (instanceof chains run L54-160). No `setHeader`/`setContentType` call exists earlier in `exportExcelFile`. The `UnsupportedOperationException` at L89/L155 fires **before any byte hits the response** — the response is not committed when the exception escapes, so Fix C can safely write a structured error body. Reliable for sites 1-5. Site 6 writes to a `ByteArrayOutputStream` and the exception fires before any write, so a caller (if wired) would receive it cleanly.

**Out of scope for Fix C.** Do **not** rename `AdviceController.exportOutboundBol` (the method name mismatches its `/exportInboundNotice` path — a pre-existing inconsistency; renaming a public method is a separate refactor risk).

**Logging convention:** SLF4J parameterized `LOG.error("...: {}", e.getMessage(), e)`, matching `FileExportService.java:36`.

---

## 5a. Branch / merge interplay with `feature/utc-timezone`

`feature/utc-timezone` is **not merged** into `develop`. Verified diffs for our files:

| File | Diff on `feature/utc-timezone` vs `develop` | Conflict with our hunk? |
|------|---------------------------------------------|------------------------|
| `FileExportService.java` | **None** (identical) | No |
| `ReportService.java` | **None** (identical) | No |
| `CyclecountService.java` | **None** (identical) | No |
| `ReportController.java` | **None** (identical) | No |
| `AdviceService.java` | `new ObjectMapper()` → `WmsObjectMapper.shared()`; no change to `exportInboundNotice`/`getRow` | No |
| `BillofladingService.java` | ObjectMapper field; ctor adds `timezoneService`; `closeBOL` uses `timezoneService.todayInWarehouse()`. None touch `exportOutboundBOL`/`getRow`/preHeader L888-905 | No |
| `AbstractBaseEntity.java` | **Identical** — `LocalDateTime created/modified` on both | (crash exists on `develop` today, independent of the migration) |
| `TimezoneService.java` | **Exists only on `feature/utc-timezone`** | Fix A must NOT reference it |

**Verdict: conflict-free at the line level.** This fix's hunks do not overlap any `feature/utc-timezone` change.

**Operational note.** Between the `feature/utc-timezone` merge and Phase 2 landing, exports will display **raw UTC timestamps** (because the JVM zone flips to UTC but Phase 1 formats `LocalDateTime` as-is). Phase 2 (UTC→warehouse conversion) should ride **immediately behind** the merge to close this window.

---

## 6. File Change Summary

| File | Fix | Change |
|------|-----|--------|
| `service/FileExportService.java` | A | Add `CELL_DATE_FORMAT` / `CELL_DT_FORMAT`; extract `setCellValue` helper with `LocalDateTime`/`LocalDate`/`Instant`/`OffsetDateTime` branches; route all four `instanceof` chains through it; add 4 imports |
| `service/ReportService.java` | B | Rename `exporContainerRecord` → `exportContainerRecord` (declaration L365) |
| `controller/ReportController.java` | B, C | Fix call site L277; add `catch (Exception)` to both endpoints; write `errors.toString()` |
| `controller/AdviceController.java` | C | Add `catch (Exception)`; write `errors.toString()` |
| `controller/BillOfLadingController.java` | C | Add `catch (Exception)`; write `errors.toString()` |
| `controller/CycleCountController.java` | C | Add `catch (Exception)`; write `errors.toString()` |
| `test/.../FileExportServiceUnitTest.java` | A | Add cases 1-5 (§8) |
| `test/.../ReportControllerUnitTest.java` | B, C | Add cases 6-7 (§8); update renamed call sites L430/438/451/459 |
| `test/.../ReportServiceUnitTest.java` | B | Update renamed call sites L409/433/447/487/517 |

---

## 7. Prerequisites & Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | Database state | **N/A** | Pure code fix — no schema, no migration, no seed row. |
| 2 | Feature flags / system properties | **N/A** | No flag/sysprop read in Phase 1 (`System Time Zone` is Phase 2 only). |
| 3 | Config / env changes | **N/A** | No `application.properties`/jasypt/keycloak change. |
| 4 | Deploy-order dependencies | **N/A** | Backend-only; no coordinated deploy. |
| 5 | Data migration | **N/A** | None. |
| 6 | External systems | **N/A** | No OMS/printer/keycloak interaction. |
| 7 | Access / permissions | **N/A** | No new role/authority. |
| 8 | Monitoring / alerts | **N/A** (optional) | Could add a counter for export 500s, but not blocking. |

### 7.2 Implementation Checklist (atomic commits)

Ordered so the **urgent crash fix ships independently of the cosmetic rename**:

- [ ] **Commit 1 (Fix A):** extract `setCellValue` helper in `FileExportService`; add `java.time` branches + formatters + imports; route all four chains through it.
- [ ] **Commit 2 (Fix C):** add `catch (Exception)` to the five export endpoints; fix existing `BusinessException` blocks to write `errors.toString()`.
- [ ] **Commit 3 (tests):** add `FileExportServiceUnitTest` cases 1-5 and `ReportControllerUnitTest` cases 6-7 (the Fix C test). (Fix B's test-call-site renames land in Commit 4.)
- [ ] **Commit 4 (Fix B) — LANDS LAST, independently revertable:** rename `exporContainerRecord` → `exportContainerRecord` (service decl + controller call + test call sites + `@DisplayName` display string). **This commit is purely cosmetic, compile-checked, and touches no behavior.** It is sequenced last and is independently revertable so that any CI friction on the rename (e.g. a missed reference) can never block the urgent crash fix — Commits 1-3 (Fix A + Fix C + their tests) ship regardless.
- [ ] Run verify script → `0 fail`.
- [ ] Code review.

---

## 8. Testing Plan

**H2 / Testcontainers note.** All new tests are **pure unit tests** — `FileExportService` is direct-constructed (`new FileExportService()`), controller tests use `@WebMvcTest`/MockMvc with the service mocked, repo queries are mocked. **No H2 and no Testcontainers scope needed.**

### New / updated tests

| Test class | # | Method | Asserts |
|------------|---|--------|---------|
| `FileExportServiceUnitTest` | 1 | `getExcelFile_withLocalDateTimeInRow_writesFormattedStringAndDoesNotThrow` | row `Object[]` with a `LocalDateTime` → no throw; cell STRING; matches `yyyy-MM-dd HH:mm:ss` |
| `FileExportServiceUnitTest` | 2 | `getExcelFile_withLocalDateInPreHeader_writesIsoDateAndDoesNotThrow` | preHeader `LocalDate` → cell == `yyyy-MM-dd`; no throw |
| `FileExportServiceUnitTest` | 3 | `exportExcelFile_withLocalDateTimeInRow_doesNotThrow` | covers `exportExcelFile` path (sites 1/2) |
| `FileExportServiceUnitTest` | 4 | `exportExcelFile_withLocalDateInPreHeader_doesNotThrow` | covers preHeader path (sites 3/4) |
| `FileExportServiceUnitTest` | 5 | `getExcelFile_withUnsupportedTypeStillThrows` | pass `ArrayList` → still `UnsupportedOperationException` (throw NOT removed) |
| `ReportControllerUnitTest` | 6 | `exportStockUnitRecord_whenServiceThrowsException_returnsErrorBody` | mock service throws `UnsupportedOperationException` → not opaque 500; error body present (Fix C) |
| `ReportControllerUnitTest` | 7 | `exportContainerRecord_afterRename_callsExportContainerRecord` | verifies renamed `exportContainerRecord(...)` is called (Fix B guard) |

### Test commands

```bash
mvn test -Dtest=FileExportServiceUnitTest
mvn test -Dtest=ReportControllerUnitTest
mvn test -Dtest=ReportServiceUnitTest   # rename regression
mvn test                                # full suite before merge
```

### Manual test plan (dev2)

| Scenario | Environment | Steps | Expected |
|----------|-------------|-------|----------|
| Stock Unit Record export | dev2 UI | Reports → Stock Unit Record → Export Excel | XLSX downloads; `created` column shows `yyyy-MM-dd HH:mm:ss`; no 500 |
| Container Record export | dev2 UI | Reports → Container Record → Export Excel | XLSX downloads; `created` formatted; no 500 |
| Inbound Notice export | dev2 UI | Receiving → advice with Day-of-Delivery → Export | XLSX; Day-of-Delivery shows `yyyy-MM-dd`; no 500 |
| Inbound BOL detailed export | dev2 UI | Open BOL with `shipped` → Export (detailed) | XLSX; "shipped at" shows `yyyy-MM-dd`; no 500 |
| Cycle Count export | dev2 UI | Run cycle count → Export | XLSX; `modified` shows `yyyy-MM-dd HH:mm:ss`; no 500 |
| Cycle Count export2 (stream/email) | — | **N/A — no production click-path** (zero production callers; unit-tested only) | Covered by Fix A for free |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Testcontainers/H2 integration test | All paths are unit-testable with direct construction + mocked repos; no SQL/JPQL change. |
| `exportCycleCount2` manual test | No production caller to exercise; unit-tested at `CyclecountServiceUnitTest.java:558-655`. |
| Pre-`try` controller-input hardening (e.g. `AdviceController.java:334` cast) | Pre-existing; out of scope (see §10 risk + §12). |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable, runnable bash)

**Path:** `sbdocs/9-System/scripts/verify-260610-excel-export-localdatetime-unsupported-type.sh`

Authored per `sbdocs/9-System/templates/verify-plan-template.sh` conventions (`run` / `file_contains` / `file_contains_n_times` / `file_not_contains` / `mvn_test_passes` helpers; ends in `Result: N pass, M fail, S skip`). Set `PROJECT_ROOT` to the wms2-api repo root. Per-file checks throughout (no multi-file `grep -c` aggregation).

```bash
#!/usr/bin/env bash
# verify-260610-excel-export-localdatetime-unsupported-type.sh
set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-26s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-26s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
# exact integer-count assertion on a single file
file_count_eq() { local pat=$1 file=$2 n=$3; [ "$(grep -cE "$pat" "$file" 2>/dev/null || echo 0)" -eq "$n" ]; }
# Exit-code based: `mvn -q` suppresses the BUILD SUCCESS banner and surefire summary,
# so grepping output false-fails on passing tests (verified 2026-06-10). Surefire fails
# the build (non-zero exit) on any test failure, so the exit code is the reliable signal.
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1
}
# mvn rows SKIP (not FAIL) when maven is unavailable in the verifying shell —
# grep checks remain authoritative; run the T-rows from a shell with mvn on PATH (e.g. SDKMAN:
# export PATH="$HOME/.sdkman/candidates/maven/current/bin:$PATH").
run_mvn() {
    local id=$1 desc=$2; shift 2
    if ! command -v mvn >/dev/null 2>&1; then
        printf "  SKIP  %-26s  %s (mvn not on PATH)\n" "$id" "$desc"; SKIP=$((SKIP+1)); return
    fi
    run "$id" "$desc" "$@"
}

SVC="src/main/java/net/aim_ai/wms/service"
CTL="src/main/java/net/aim_ai/wms/controller"
FES="$SVC/FileExportService.java"
RPTC="$CTL/ReportController.java"
ADVC="$CTL/AdviceController.java"
BOLC="$CTL/BillOfLadingController.java"
CCC="$CTL/CycleCountController.java"

# --- Fix A: FileExportService java.time branches + helper -------------------
check_fixA_localdatetime()   { file_contains 'instanceof LocalDateTime'  "$FES"; }
check_fixA_localdate()       { file_contains 'instanceof LocalDate'      "$FES"; }
check_fixA_instant()         { file_contains 'instanceof Instant'        "$FES"; }   # defensive
check_fixA_offsetdatetime()  { file_contains 'instanceof OffsetDateTime' "$FES"; }   # defensive
check_fixA_helper()          { file_contains 'private void setCellValue'  "$FES"; }
# NEGATIVE: exactly ONE throw site remains (in the helper), not four
check_fixA_single_throw()    { file_count_eq 'throw new UnsupportedOperationException' "$FES" 1; }

# --- Fix B: rename ----------------------------------------------------------
check_fixB_correct_name()    { file_contains 'public void exportContainerRecord\(' "$SVC/ReportService.java"; }
# NEGATIVE: typo eradicated everywhere in src/main + src/test (URL "exportContainerRecord" has the 't', won't match)
check_fixB_typo_gone()       { ! grep -rqE 'exporContainerRecord' src/main src/test; }

# --- Fix C: per-controller catch (Exception) + populated body ---------------
# POSITIVE catch (Exception) per file. ReportController has TWO endpoints → 2 occurrences.
check_fixC_rptc_catch()      { file_count_eq 'catch \(Exception '          "$RPTC" 2; }
check_fixC_advc_catch()      { file_contains 'catch \(Exception '          "$ADVC"; }
check_fixC_bolc_catch()      { file_contains 'catch \(Exception '          "$BOLC"; }
check_fixC_ccc_catch()       { file_contains 'catch \(Exception '          "$CCC"; }
# POSITIVE populated error body per controller (errors.toString(), not errorMap.toString())
check_fixC_rptc_body()       { file_contains 'response\.getWriter\(\)\.write\(errors\.toString\(\)\)' "$RPTC"; }
check_fixC_advc_body()       { file_contains 'response\.getWriter\(\)\.write\(errors\.toString\(\)\)' "$ADVC"; }
check_fixC_bolc_body()       { file_contains 'response\.getWriter\(\)\.write\(errors\.toString\(\)\)' "$BOLC"; }
check_fixC_ccc_body()        { file_contains 'response\.getWriter\(\)\.write\(errors\.toString\(\)\)' "$CCC"; }
# NEGATIVE: empty-map write gone from each export endpoint.
# ReportController is method-scoped: the file has 10 errorMap.toString() occurrences but only the
# two export endpoints are in Fix C's scope (the other 9 non-export endpoints keep the latent
# pattern — see §12). Anchored on method names, not line numbers, so the check survives drift.
report_export_method(){ awk "/public void $1\\(/,/^    \\}\$/" "$RPTC"; }
check_fixC_rptc_no_emptymap(){
  ! report_export_method exportStockUnitRecord | grep -q 'errorMap\.toString()' \
  && ! report_export_method exportContainerRecord | grep -q 'errorMap\.toString()'
}
check_fixC_advc_no_emptymap(){ file_not_contains 'errorMap\.toString\(\)' "$ADVC"; }
check_fixC_bolc_no_emptymap(){ file_not_contains 'errorMap\.toString\(\)' "$BOLC"; }
check_fixC_ccc_no_emptymap() { file_not_contains 'errorMap\.toString\(\)' "$CCC"; }
# NEGATIVE: no hard-coded timezone string introduced in controllers
check_fixC_no_hardcoded_tz() { ! grep -rqE 'America/Los_Angeles|ZoneId\.systemDefault' "$CTL"; }

echo
echo "verify-260610-excel-export — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A-ldt   "Fix A: LocalDateTime branch present"        check_fixA_localdatetime
run A-ld    "Fix A: LocalDate branch present"            check_fixA_localdate
run A-inst  "Fix A: Instant branch present (defensive)"  check_fixA_instant
run A-odt   "Fix A: OffsetDateTime branch (defensive)"   check_fixA_offsetdatetime
run A-help  "Fix A: setCellValue helper extracted"       check_fixA_helper
run A-throw "Fix A: exactly 1 throw site (was 4)"        check_fixA_single_throw
echo
run B-name  "Fix B: exportContainerRecord present"       check_fixB_correct_name
run B-typo  "Fix B: typo eradicated (src/main+src/test)" check_fixB_typo_gone
echo
run C-rptc-c "Fix C: ReportController 2x catch(Exception)" check_fixC_rptc_catch
run C-advc-c "Fix C: AdviceController catch(Exception)"    check_fixC_advc_catch
run C-bolc-c "Fix C: BillOfLadingController catch(Exception)" check_fixC_bolc_catch
run C-ccc-c  "Fix C: CycleCountController catch(Exception)" check_fixC_ccc_catch
run C-rptc-b "Fix C: ReportController writes errors.toString()" check_fixC_rptc_body
run C-advc-b "Fix C: AdviceController writes errors.toString()" check_fixC_advc_body
run C-bolc-b "Fix C: BillOfLadingController writes errors.toString()" check_fixC_bolc_body
run C-ccc-b  "Fix C: CycleCountController writes errors.toString()" check_fixC_ccc_body
run C-rptc-n "Fix C: ReportController no errorMap.toString()"  check_fixC_rptc_no_emptymap
run C-advc-n "Fix C: AdviceController no errorMap.toString()"  check_fixC_advc_no_emptymap
run C-bolc-n "Fix C: BillOfLadingController no errorMap.toString()" check_fixC_bolc_no_emptymap
run C-ccc-n  "Fix C: CycleCountController no errorMap.toString()"   check_fixC_ccc_no_emptymap
run C-tz     "Fix C: no hard-coded timezone in controllers"   check_fixC_no_hardcoded_tz
echo
run_mvn T-fes   "FileExportServiceUnitTest passes"  mvn_test_passes FileExportServiceUnitTest
run_mvn T-rptc  "ReportControllerUnitTest passes"   mvn_test_passes ReportControllerUnitTest
run_mvn T-rpts  "ReportServiceUnitTest passes"      mvn_test_passes ReportServiceUnitTest

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
```

> Negative-check scoping (RESOLVED — no executor decision needed): `ReportController.java` has **10** `errorMap.toString()` occurrences, of which only the two export endpoints are in Fix C's scope; its negative check is therefore **method-scoped** via the `report_export_method` awk anchor above. `AdviceController` / `BillOfLadingController` / `CycleCountController` each have exactly **1** occurrence (the in-scope export endpoint), so their whole-file negatives are correct as written. The 9 out-of-scope `ReportController` occurrences remain — tracked in §12 as the repo-wide latent pattern.

**Post-implementation gate.** Run the script before changes (expect FAILs on positive checks), implement, run again. A "DONE" claim must paste the runner output ending in **`Result: N pass, 0 fail, S skip`**. Any FAIL line voids the DONE claim.

**Pre-fix baseline (captured 2026-06-10, develop HEAD `576f1dd`, mvn on PATH):** `Result: 5 pass, 19 fail, 0 skip` — the 3 `mvn` rows pass (existing tests green pre-fix), all 19 fix assertions fail, plus the 2 known pre-fix passes (`C-advc-c` cosmetic no-op on a commented-out catch at `AdviceController.java:232`; `C-tz` negative). Post-implementation target: **24 pass, 0 fail, 0 skip**.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 3 fixes across 1 service + 4 controllers; single subsystem |
| **Pre-draft step** | analyst+planner (this doc) + consensus (ralplan) | high-confidence-required date handling |
| **Plan-review step** | critic | Standard+ requires it (this consensus loop) |
| **Implementation shape** | executor | bounded, well-specified |
| **Verification step** | verify-script + verifier | mandatory |
| **Code-review step** | code-reviewer | helper extraction touches a shared service |
| **Commit step** | git-master | 4 atomic commits; rename (Commit 4) lands last + independently revertable |

---

## 10. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Post-`feature/utc-timezone` merge, exports show raw UTC timestamps until Phase 2 | High (once merged) | Medium (display only) | Documented in §5a; Phase 2 rides immediately behind the merge; operational note flagged to release owner |
| Helper extraction silently drops the `throw` (over-broad fix swallows genuinely unsupported types) | Low | Medium | Test case 5 (`getExcelFile_withUnsupportedTypeStillThrows`) + verify check `check_fixA_single_throw` (exactly 1 throw remains) |
| Rename misses a call site → compile break | Low | Low | Compile-time caught; verify check `check_fixB_typo_gone` greps src+test; rename is Commit 4 (last) and independently revertable so it cannot block the crash fix |
| `catch (Exception)` masks a genuine programming bug as a soft error body | Low | Low | Handler logs `LOG.error(..., e)` with full stack trace before writing the body — bug remains visible in logs/monitoring; only the user-facing opaque 500 is replaced |
| Fix C writes to an already-committed response | Very Low | Low | Verified response uncommitted until `FileExportService.java:162`, after all throw sites (§5 Fix C safety argument) |
| Pre-`try` controller-input exceptions still 500 (e.g. `AdviceController.java:334` `(Integer)` cast, `findById(...).orElseThrow(...)`) | Low | Low | **Explicitly out of scope** — Fix C guards only the service call inside the try block; pre-try input hardening is a separate effort (see §12) |
| `CELL_TIMESTAMP_FORMAT` (SBDEV-2233) accidentally clobbered | Low | Medium | Helper reuses the existing constant for `Date`/`Instant`; new constants are additive; SBDEV-2233 referenced in §3 |

---

## 11. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | In-JVM state | per-replica state? | **No** | New formatters are `static final` immutable; `DateTimeFormatter` is thread-safe. |
| 2 | Connection pool math | per-request DB connection use? | **No** | No new query; read-only export path unchanged. |
| 3 | Scheduled jobs | add/modify `@Scheduled`? | **N/A** | Pure HTTP request-path fix. |
| 4 | Long transactions | hold tx across calls/I-O? | **No** | Export methods stay non-transactional (see checklist below); no new tx boundary. |
| 5 | Request affinity | assume same-replica follow-up? | **No** | Stateless request/response. |
| 6 | Retry / idempotency | rely on single-execution? | **No (idempotent)** | Export is read-only; UI retry is safe. |
| 7 | Tenant context | use `TenantContext` across async? | **No** | Synchronous within the request thread; no `@Async`. |
| 8 | Distributed lock | add/rely on locks across replicas? | **No** | No lock involved. |
| 9 | Cache invalidation | write to a cached entity? | **No** | No write; no cache touched. |
| 10 | External notifications | HTTP/message inside tx? | **No** | No external I/O added. |

### v2-only constraint checklist (8 rows)

| # | Check | Verdict | Evidence |
|---|-------|---------|----------|
| 1 | Any of the 6 export methods carry `@Transactional`? | **Only site 4's enclosing `exportOutboundBOL`** (`BillofladingService.java:920`, `tenantTransactionManager`) | Our `getRow` hunk is a preHeader builder inside it — no new annotation |
| 2 | Should export methods add `@Transactional(readOnly)`? | **No** | SBDEV-2215 classified `exportInboundNotice` as read-only out-of-scope; adding it is scope creep |
| 3 | OSIV impact (`open-in-view=false`)? | **None** | Entities are already loaded into the `Object[]` rows before `FileExportService` runs; no lazy access in the helper |
| 4 | Tenant TM rule (`value="tenantTransactionManager"`) respected? | **Yes (unchanged)** | No new `@Transactional` added; existing one already specifies tenant TM |
| 5 | Constructor-injection-only convention? | **Yes** | `FileExportService` keeps its no-arg constructor in Phase 1 (no new field) |
| 6 | SLF4J parameterized logging? | **Yes** | Fix C uses `LOG.error("...: {}", e.getMessage(), e)` per `FileExportService.java:36` |
| 7 | Entity comparison by ID, not `.equals()` ref? | **N/A** | No entity comparison introduced |
| 8 | No `mockStatic` / static mutable state added? | **Yes (clean)** | New constants are `static final` immutable; tests use plain Mockito on instances |

---

## 12. Open Questions / Resolved Decisions

All open decisions from the analysis bundle have been resolved by the user prior to drafting:

| Decision | Resolution | Status |
|----------|-----------|--------|
| Warehouse-tz conversion of `LocalDateTime` | Deferred to **Phase 2**, separate plan blocked on `feature/utc-timezone` merge; Phase 1 formats as-is | **RESOLVED** |
| Which export sites to fix | **All six** (including dead-code `exportCycleCount2`, fixed for free) | **RESOLVED** |
| Ticket reference | **No ticket** — internal defect | **RESOLVED** |
| Controller hardening + typo rename | **Included** (Fix B + Fix C) in this plan | **RESOLVED** |
| Latent `errorMap.toString()` empty-body bug | **Fixed** as part of Fix C (write `errors.toString()`) for the 5 export endpoints | **RESOLVED** |
| Extract `setCellValue` helper vs inline branches | **Extract helper** (Option 2) | **RESOLVED** |
| `Instant`/`OffsetDateTime` defensive branches | **Included** in Phase 1 (cost-free future-proofing) | **RESOLVED** |
| String date cells vs native Excel date cells | **String cells** (consistency with SBDEV-2233 `Date` branch; avoids JVM-zone hazard) — native cells deferred to a separate enhancement | **RESOLVED** (§5 Fix A) |
| Fix C catch breadth | **`catch (Exception)`** (closes checked + future exception types as 500 vectors; `FacadeException extends Exception`) | **RESOLVED** (§5 Fix C) |

**Known limitations / out of scope (not blocking):**
- **Pre-`try` controller input exceptions still 500.** Fix C guards only the service call inside the try block. Casts/lookups before the try (e.g. `AdviceController.java:334` `((Integer) reqMap.get("id")).longValue()`, `findById(...).orElseThrow(...)`) can still throw and return a 500. Hardening controller input parsing is a separate, broader effort.
- **The empty-`errorMap` latent bug is repo-wide.** Many *non-export* endpoints in these and other controllers also write `errorMap.toString()`. Fix C scopes the correction to the 5 export endpoints. A repo-wide audit/fix of the empty-body pattern is a recommended **follow-up**.

No open questions remain for execution. (If any surface during implementation, append to `.omc/plans/open-questions.md`.)

---

## Completeness checklist (wms-bugfix-plan skill)

| # | Item | Status | Reference |
|---|------|--------|-----------|
| 1 | Affected sites enumerated (in + not-affected) | ✓ | §0 |
| 2 | User-visible symptom with exact UI text | ✓ | §1 |
| 3 | DB verification inline (`db_verified: true`) | ✓ | §1 (wms2-wineco-dev2) |
| 4 | Root cause traced to file:line + code | ✓ | §2 (Bug 1/2/3) |
| 5 | Regression commit identified | ✓ | §3 (`6e5af846`, 2026-02-18) |
| 6 | Architecture/flow diagram + key files | ✓ | §4 |
| 7 | Fix design with Before/After + tradeoffs | ✓ | §5 (Fix A/B/C; string-vs-native + catch-breadth tradeoffs recorded) |
| 8 | Test plan (unit + manual) + commands | ✓ | §8 |
| 9 | Machine-checkable acceptance script (runnable bash) | ✓ | §9.1 |
| 10 | Horizontal scalability + v2 constraints | ✓ | §11 |
| 11 | Open questions / resolved decisions + known limits | ✓ | §12 |

---

## 13. ADR — Decision Record (ralplan consensus 2026-06-10)

- **Decision:** Fix the `java.time` export crash centrally in `FileExportService` by extracting a single private `setCellValue` helper consolidating the four duplicated `instanceof` chains, adding `LocalDateTime`/`LocalDate` branches (Phase 1: format as-is, no zone conversion) plus defensive `Instant`/`OffsetDateTime` branches; harden the five export endpoints with `catch (Exception)` writing the populated `errors` body; rename `exporContainerRecord` last as an independently-revertable commit.
- **Drivers:** six user-facing exports fully broken with an opaque 500; silent regression from commit `6e5af846` (2026-02-18); imminent `feature/utc-timezone` merge requires a conflict-free, phase-split design.
- **Alternatives considered:** (1) inline branches at all four sites — rejected, reproduces the duplication-induced partial-coverage defect class; (3) caller-side pre-formatting to `String` — rejected, large diff across four services, contradicts the SBDEV-2233 centralized-formatter design. Steelman (Architect): native Excel date cells with `CellStyle` data formats — rejected for this plan; would diverge from existing `Date`-branch string cells in the same sheets and reintroduce a JVM-zone hazard ahead of the UTC merge; deferred as a separate enhancement.
- **Why chosen:** minimal diff that also eliminates the defect class; conflict-free against `feature/utc-timezone`; preserves the no-arg `FileExportService` constructor (zero test churn in Phase 1).
- **Consequences:** between the `feature/utc-timezone` merge and Phase 2 landing, exports render raw UTC timestamps (crash-free); Phase 2 (UTC→warehouse zone via `TimezoneService`) must ride immediately behind that merge. Nine out-of-scope `errorMap.toString()` sites remain in `ReportController`'s non-export endpoints.
- **Follow-ups:** Phase 2 follow-up plan (blocked on `feature/utc-timezone` merge); optional repo-wide empty-`errorMap` cleanup; optional native-date-cell enhancement if ops needs sortable date columns.

---

## 14. Implementation Status (2026-06-10)

Implemented on branch `fix/excel-export-localdatetime` (v2/wms2-api, off `develop` @ `576f1dd`), via ralph with TDD gate.

| Commit | Fix | Content |
|---|---|---|
| `e87d41b` | Fix A | `FileExportService` — 4 chains → `setCellValue` helper + `LocalDateTime`/`LocalDate` + defensive `Instant`/`OffsetDateTime` branches (Phase 1, no zone conversion) |
| `15508d5` | Fix C | `catch (Exception)` on 5 export endpoints; both catch blocks write `errors.toString()` |
| `a8780d3` | tests | 7 TDD gate tests (5× `JavaTimeCellTypes`, controller error-body, rename reflection guard) |
| `7964d54` | Fix B | `exporContainerRecord` → `exportContainerRecord` (11 occurrences, 4 files; REST path unchanged) |
| `382d746` | review cleanup | 5 dead `errorMap` locals removed; nested test class typo renamed; `.gitignore` rule for `migration.env*` |

**Tests:** `FileExportServiceUnitTest` (+5 new), `ReportControllerUnitTest` (+1), `ReportServiceUnitTest` (+1) — all green; 6 affected test classes `mvn test` exit 0. Full suite: 4161 run, 4 failures — all 4 reproduce identically on clean `develop` @ `576f1dd` (pre-existing: `OptionalSafetyArchTest`, `UtilRestControllerUnitTest` ×2, `RestExceptionHandlerUnitTest`); branch introduces zero new failures.

**Verify script:** `Result: 24 pass, 0 fail, 0 skip` (pre-fix baseline was 5/19/0).

**Code review:** code-reviewer agent — 0 CRITICAL; 1 MAJOR (accidentally committed local `migration.env*` credential files — amended out before push, gitignore guard added) and 2 MINOR fixed; 1 MINOR accepted (no tests for defensive branches, plan-sanctioned). Final helper-parity audit clean (null/style/intValue/row-index all byte-faithful).

**verify-docs:** no drift — implicated wms2 docs (BOL workflow, cycle-count workflow, OMS integration map) cite method-start line anchors that did not move.

**PR:** [SiteBossInc/wms2-api#43](https://github.com/SiteBossInc/wms2-api/pull/43) → `develop` (reviewer-approved branch; awaiting merge).

**Phase 2 reminder:** when `feature/utc-timezone` merges into `develop`, file the follow-up to convert `LocalDateTime` cells UTC→warehouse zone via `TimezoneService` (§5 Fix A Phase 2). Exports render raw UTC in the gap.
