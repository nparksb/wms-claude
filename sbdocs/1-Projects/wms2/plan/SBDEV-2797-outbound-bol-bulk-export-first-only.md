---
title: "Outbound BOL Bulk Export — Build the Missing Multi-BOL Path (Latent selectedItems[0] Truncation, Scalar-Only API)"
ticket: "SBDEV-2797"
ticket_url: "https://app.clickup.com/t/868kk83r2"
type: "bug"
priority: "normal"
status: "implemented"
project: ["wms2"]
version: "v2"
requester: "Nam Park (filed from the SBDEV-2632 §0 enumeration, 2026-08-02)"
created: "2026-08-03"
updated: "2026-08-03"
db_verified: true
related:
  - "SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.md"
  - "../../../3-Resources/workflows/wms2-bol-truck-loading-workflow.md"
  - "../../../4-Archieves/wms2/plan/260610-excel-export-localdatetime-unsupported-type.md"
tags:
  - plan
  - bug
  - export
  - file-export
  - billoflading
  - bulk-action
  - input-validation
  - multi-sheet
---

# Outbound BOL Bulk Export — Build the Missing Multi-BOL Path

**Ticket:** [SBDEV-2797](https://app.clickup.com/t/868kk83r2) — *[WMS v2] Outbound BOL bulk export silently exports only the first selected BOL*
**Filed from:** [SBDEV-2632](https://app.clickup.com/t/868keq79q) §0 row 7 / §12 follow-up | **Sibling (v1):** not yet filed — see §14 item 1
**Project:** wms2/wms2-api + wms2-web-ui | **Version:** v2 (Java 21 / Spring Boot 3.5.x) | **Type:** Bug as filed; in reality **latent defect + missing feature surface** (§1)
**Priority:** Normal | **Target branch:** `feature/SBDEV-2797-outbound-bol-bulk-export` off `origin/develop` (both repos)
**Status:** Draft — pending review
**Date:** 2026-08-03
**db_verified:** true (wms2-wineco-dev via MCP, 2026-08-03)

> Acceptance script: `sbdocs/9-System/scripts/verify-SBDEV-2797-outbound-bol-bulk-export-first-only.sh`

---

## 0. Affected sites (enumeration before drafting)

**Enumeration method (not recall):**
- `grep -rn "exportBolPop\|showExportBol" --include=*.vue --include=*.js` in `v2/wms2-web-ui` → 3 callers + the popup.
- `grep -rn "selectedItems\[0\]" --include=*.vue --include=*.js components pages store` → 5 hits, each traced to its dispatch and endpoint.
- `grep -rn "exportOutboundBol" --include=*.java src/main/java` in `v2/wms2-api` → 2 controllers.
- `grep -rln "exportOutboundBOL" src/test/java` → 1 test class, **10** tests in the `ExportOutboundBOL` `@Nested` class (`@Test` at `BillofladingServiceUnitTest.java:903, 915, 928, 941, 957, 973, 1005, 1031, 1067, 1083`). *An earlier draft said 12 — corrected in review; the count is the plan's central extraction guardrail, so it is enumerated line-by-line rather than approximated.*
- `grep -rln "exportOutboundBol\|exportBolPop" sbdocs/1-Projects sbdocs/4-Archieves sbdocs/3-Resources` → 5 docs.
- `git log -L 25,40:components/outbound/bol/openOutboundBol.vue` → provenance of the commented-out button.
- `grep -n "cors" src/main/resources/application*.properties` → confirms **no** `exposed-headers` property exists.

| # | File:line | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `wms2-web-ui .../bol/popups/exportBolPop.vue:72` | `{id: this.selectedItems[0].id}` — hard-coded first element, silent truncation | **yes — Bug 1** | **yes (Fix D)** |
| 2 | `wms2-web-ui .../bol/closedOutboundBol.vue:25-36` | data table has no `show-select` and no `v-model` → no multi-select surface at all | **yes — Bug 1** | **yes (Fix C)** |
| 3 | `wms2-web-ui .../bol/closedOutboundBol.vue:303-305` | `addToSelectedItems` clobbers `selectedItems`; once that array is the table's `v-model` this visibly unchecks the operator's ticks | **yes — introduced by Fix C** | **yes (Fix C)** |
| 4 | `wms2-api .../controller/BillOfLadingController.java:270` | `((Integer) reqMap.get("id")).longValue()` **outside** the `try` at `:275`; scalar-only contract | **yes — Bug 2** | **yes (Fix A)** |
| 5 | `wms2-api .../controller/BillOfLadingController.java:273` | `findById(...).orElseThrow(EntityNotFoundException)` also pre-`try` | **yes — Bug 2** | **yes (Fix A)** |
| 6 | `wms2-api .../service/BillofladingService.java:914` | `exportOutboundBOL(response, Billoflading, boolean)` — single-BOL signature; ends in a stream-closing write at `:1010` | **yes — Bug 3** | **yes (Fix B)** |
| 7 | `wms2-web-ui store/outbound/outboundBols.js:314-333` | `link.click()` at `:324` fires **before** the `result.errors` check at `:325`; with `responseType:'blob'` `result` is a `Blob` so `result.errors` is always `undefined` ⇒ the whole error branch is dead code; object URL + `<a>` never revoked/removed | **yes — Bug 4** | **yes (Fix E)** |
| 8 | `wms2-web-ui .../bol/openOutboundBol.vue:44` | `item-key="key"` but `ViewDtoService.getBolByStatesAndKeyword:1416-1451` emits no `key` field → every row keys on `undefined`, breaking `show-select` for the **already-live** bulk Close | no — separate defect, but it is the selection-reliability precondition this ticket is about, and a one-word fix in the same screen family | **yes (Fix F)** |
| 9 | `wms2-web-ui .../bol/openOutboundBol.vue:33-34` | bulk **"Export BOLs"** button commented out since `3462148 initial check in the code` | n/a | **no** — stays off by decision #4 (§10). Fix C adds a comment citing DB Q2 + `a8af84f` so it isn't "helpfully" uncommented |
| 10 | `wms2-api .../service/BillofladingService.java:1010` | sheet name hard-coded `"Inbound BOL"` on an **outbound** BOL export — a mislabel | no — cosmetic, but it is the **name of the artifact Fix B has to name anyway** | **yes (Fix B) — status changed by user decision 11.** The first draft excluded it and deferred to a §14 follow-up, preserving the mislabel *by construction*. The Architect (finding 10) pointed out that preserving a known-wrong label to avoid 3 test edits was the weakest link in the plan, and that doing so is what forced the cardinality-dependent sheet naming. Both paths now name sheets by BOL number |
| 11 | `wms2-api .../controller/AdviceController.java:330` | a second `exportOutboundBol` with the same `Map<String,Object>` shape | same defect *class*, different endpoint (inbound advice) | **no** — not reachable from the BOL screen; §14 item 3 |
| 12 | `wms2-web-ui .../cycleCount/exportCyclePop.vue:70` | `selectedItems[0].cyclecountNumber` used only for the **filename**; ids are sent separately | no — display-only | **no** — owned by SBDEV-2632 |
| 13 | `wms2-web-ui .../bol/popups/closeBolPop.vue:79-84` | `[0]` for single, `bolIds` array for multi | no — **correct; this is the reference implementation to mirror** | **no** |
| 14 | `v1/wms-web-ui .../bol/popups/exportBolPop.vue:72` + `openOutboundBol.vue:33` | exact mirror of rows 1 and 9 | **yes — same defect** | **no** — decision #2 (§10); paired v1 ticket in §14 item 1 |
| 15 | SBDEV-2632 §0 row 13's ≥18 other unguarded `Map` numeric coercions in controllers outside `net.aim_ai.wms.controller.rest` | same defect class as row 4 | **yes — same class** | **no** — owned by SBDEV-2632's §12 follow-up; do not widen |
| **16** | `wms2-web-ui .../bol/outboundBolDetails.vue:133` (`exportBol`) **and `:137` (`closeBol`)** — added during plan drafting; `:137` added after Architect review | Both do `this.selectedItems.push(...)` with **no reset** (unlike rows 3 and 5's siblings), onto the array shared by *both* mounted popups (`:101-102`). `:133` is harmless today only because `exportBolPop` reads `[0]`; once Fix D maps the whole array, a re-open after a non-`closePop` dismissal sends `ids:[X,X]` and the confirm sentence reads `OBOL000004, OBOL000004`. `:137` does **not** double-close (`closeBolPop.vue:78-81` branches on the `mode` prop and this page hard-codes `mode: 'single'` at `:119`, so it still reads `selectedItems[0]`) — but after an Export→dismiss→Close sequence its confirm sentence names the BOL twice | **yes — `:133` unmasked by Fix D; `:137` is the same latent shape** | **yes (Fix D2)** — both, one line each, same method block, same commit |
| **17** | `wms2-web-ui .../bol/closedOutboundBol.vue:303-307` — **added during plan drafting** | `addToSelectedItems(item, chosenAction)` calls `showExportPop()` **unconditionally**, so the kebab's *"Mark as Received"* item opens the **Export** dialog. `chosenAction` is only `console.log`ged. No close/receive popup component is even imported into this file (`:117` imports `exportBolPop` only) | no — independent mis-wire on the exact method Fix C rewrites | **no** — fixing it means introducing a receive popup this component does not have; that is a separate feature. **Fix C must preserve the existing behaviour and leave a comment**; §14 item 5 |
| **18** | `wms2-api .../controller/BillOfLadingController.java:185` (`setDestinationFacility`) — **added during plan drafting** | `Long id = ((Integer) reqMap.get("id")).longValue();` — a **character-for-character twin** of row 4, in the **same file**, also pre-`try`, also a raw 500 on a JSON-string or absent `id`. (A third occurrence at `:330` in `palletize` is commented out.) | **yes — same class as Bug 2** | **no** — not reachable from the BOL export path; same scope boundary SBDEV-2632 §0 row 13 drew. §14 item 10. ⚠️ **But it constrains the verify script:** a whole-file NEGATIVE assertion on `((Integer) reqMap.get("id")).longValue()` can **never** pass, because `:185` legitimately keeps it. The Fix A NEGATIVE row **must** be `java_method`-scoped to `exportOutboundBol` (§9.2) |

Rows **1-8, 10 and 16** are visited by §5 Fix A-F — **row 10 moved in scope** under user decision 11 (the sheet rename). Rows 9, 11-15, 17 and 18 are excluded with the rationale above.
Every in-scope row maps to at least one POSITIVE check in the verify script (§9.2).

---

## 1. Problem Statement

### The ticket's root-cause narrative is wrong — correct it before anything else

SBDEV-2797 asserts that an operator can tick three outbound BOLs, click bulk **Export**, see all three
named in the confirmation dialog, and receive a workbook containing only the first. **That sequence is
not reachable on `develop`.** The `selectedItems[0]` at `exportBolPop.vue:72` is a **latent** defect —
real, but currently unreachable, because nothing can put a second element into `selectedItems`.

| Evidence | Finding |
|---|---|
| `components/outbound/bol/openOutboundBol.vue:33-34` | The bulk **"Export BOLs"** button in the multi-select action bar is **commented out**. `git log --oneline -8 -L 25,40:...` shows it arrived already commented out in `3462148 initial check in the code` — **never live, so never a regression** |
| `components/outbound/bol/closedOutboundBol.vue:25-36` | The Closed-tab `v-data-table` has **no `show-select`** and no `v-model="selectedItems"`. `selectedItems: []` *is* declared in `data()` (`:206`) but is never bound to the table, and no bulk action bar is rendered |
| `openOutboundBol.vue:314-316` | `addToSelectedItems(item, chosenAction)` does `this.selectedItems = []` then pushes **exactly one** row |
| `closedOutboundBol.vue:303-305` | Same one-item clobber |
| `outboundBolDetails.vue:133` | `exportBol()` pushes the single detail BOL |

So `exportBolPop.vue:72` never sees more than one element, and the confirmation sentence
(`getExportList`, `:57-65`) renders that same one-element array. The "dialog says 3, file has 1"
divergence the ticket describes cannot happen — the dialog is *coincidentally* truthful.

**What is actually wrong is that the feature does not exist.** The Closed tab has no way to select
more than one BOL, the API accepts only a scalar `id`, and the service can write only one workbook.
This plan builds it, and fixes the latent `[0]` on the way in — the order matters, because wiring
`show-select` without Fix A/B/D would turn a latent truncation into live silent data loss.

### Why it is worth building

2,835 BOLs on wineco-dev, and multi-BOL days are routine (186 created 2026-05-29; 40 / 34 / 28 on
other days). Reconciling a day's shipments one download at a time is the workflow this ticket exists
to remove.

### DB verification (wms2-wineco-dev, live via MCP, 2026-08-03)

**Q1 — BOL population by state**

```sql
SELECT state, COUNT(*) AS bols, COUNT(*) FILTER (WHERE shipped IS NOT NULL) AS with_shipped_date
FROM billoflading GROUP BY state ORDER BY bols DESC;
```

| state | bols | with_shipped_date |
|---|---|---|
| CLOSED | 2516 | 2516 |
| OPEN | 316 | 7 |
| TRUCK_LOADING | 3 | 0 |

No `CANCELLED` and no `TRANSFER` rows exist on this tenant — relevant to the CANCELLED decision in
§5 Fix B, which is therefore a defensive contract rather than an observed failure.

**Q2 — replay of the ACTUAL export queries, per state (the decisive one)**

```sql
WITH open_rows AS (   -- mirrors getOpenBOLSkuAmountDetail
  SELECT b.id, COUNT(*) AS export_rows FROM billoflading b
  JOIN billoflading_position bp ON bp.billoflading_id = b.id
  JOIN customerorder o ON bp.order_id = o.id
  JOIN unitload u ON bp.source_id = u.id
  JOIN unitload u2 ON u.carrierunitload_id = u2.id
  JOIN stockunit su ON su.unitload_id = u.id
  JOIN itemdata i ON su.itemdata_id = i.id
  WHERE b.state <> 'CLOSED' GROUP BY b.id),
closed_rows AS (      -- mirrors getClosedBOLSkuAmountDetail
  SELECT b.id, COUNT(DISTINCT i.id) AS export_rows FROM billoflading b
  JOIN billoflading_position bp ON bp.billoflading_id = b.id
  JOIN itemdata i ON i.id = bp.itemdata_id
  WHERE b.state = 'CLOSED' GROUP BY b.id)
SELECT b.state, COUNT(*) AS bols, COUNT(r.id) AS with_rows,
       COUNT(*)-COUNT(r.id) AS exports_EMPTY
FROM billoflading b LEFT JOIN (SELECT * FROM open_rows UNION ALL SELECT * FROM closed_rows) r
  ON r.id=b.id GROUP BY b.state ORDER BY bols DESC;
```

| state | bols | with_rows | exports EMPTY | % empty |
|---|---|---|---|---|
| CLOSED | 2516 | 2298 | 218 | **8.7%** |
| **OPEN** | **316** | **0** | **316** | **100.0%** |
| TRUCK_LOADING | 3 | 2 | 1 | 33.3% |

**Interpretation.** Both export queries hinge on `billoflading_position`, and positions are only
created during truck loading — so an `OPEN` BOL has nothing to export **by construction**. This is
almost certainly why the Open tab's bulk Export button was never enabled, and it is the evidence
behind decision #4 (§10): **multi-select lands on the Closed tab only.**

**Q3 — sizing the export, for the cap decision in §5 Fix A**

```sql
WITH closed_rows AS (
  SELECT b.id, COUNT(DISTINCT i.id) AS export_rows
  FROM billoflading b
  JOIN billoflading_position bp ON bp.billoflading_id = b.id
  JOIN itemdata i ON i.id = bp.itemdata_id
  WHERE b.state = 'CLOSED' GROUP BY b.id)
SELECT count(*) AS closed_with_rows, max(export_rows) AS max_rows,
       round(avg(export_rows),1) AS avg_rows,
       percentile_disc(0.5)  WITHIN GROUP (ORDER BY export_rows) AS p50,
       percentile_disc(0.95) WITHIN GROUP (ORDER BY export_rows) AS p95,
       sum(export_rows) AS total_rows
FROM closed_rows;
```

| closed_with_rows | max_rows | avg_rows | p50 | p95 | total_rows |
|---|---|---|---|---|---|
| 2298 | **493** | **92.5** | 69 | **271** | 212,584 |

**Q4 — sheet-name safety, for §5 Fix B**

```sql
SELECT max(length(number)) AS max_len, min(length(number)) AS min_len, count(*) AS total,
       count(DISTINCT number) AS distinct_numbers,
       count(*) FILTER (WHERE number ~ '[\[\]:*?/\\]') AS with_illegal_sheet_chars,
       min(number) AS sample_min, max(number) AS sample_max
FROM billoflading;
```

| max_len | min_len | total | distinct | illegal chars | sample |
|---|---|---|---|---|---|
| 10 | 10 | 2835 | **2835** | **0** | `OBOL000004` … `OBOL117480` |

⇒ `billoflading.number` is uniformly `OBOL######`, 10 chars, unique, containing none of Excel's
forbidden sheet-name characters. Sheet-name sanitisation and de-duplication in Fix B are therefore
**defensive**, not corrective — but they stay in, because POI throws `IllegalArgumentException` on a
duplicate or malformed sheet name, which would turn a legitimate 100-BOL selection into a 500.

**What the four queries prove:**
1. There is abundant real data for bulk closed-BOL export (2,298 exportable closed BOLs).
2. Bulk export on the **Open** tab would skip 100% of any selection — settling decision #4 on evidence.
3. 8.7% of CLOSED BOLs export **zero rows**, and that is deliberate (§3) — so the design must keep
   their sheets, not skip them.
4. A 100-BOL workbook is ~9,250 rows typically and ≤49,300 in the worst observed case — bounded, and
   the basis for the cap in Fix A.

### Reproduction (after this plan ships; today only step 1-2 exist)

| # | Step |
|---|---|
| 1 | Log in to the WMS web UI for a tenant with ≥2 closed BOLs (wineco-dev: 2,516) |
| 2 | Outbound → Outbound BOL → **Closed** tab |
| 3 | **Today:** there are no row checkboxes. The only export path is the row kebab → *Export BOL*, one at a time |
| 4 | **After:** tick 3 rows → the bulk bar appears ("3 items selected.") → **Export BOLs** → **Export File** |
| 5 | **Expected:** one `BOL_Export_Multiple_<ts>.xlsx` with 3 sheets named `OBOL…`, in selection order, each with its own pre-header + signature block |

Latent-defect reproduction, for the record: temporarily add `show-select` + `v-model="selectedItems"`
to `closedOutboundBol.vue:25-36` on unmodified `develop`, tick 3 rows, export ⇒ a single-sheet file
for the first BOL, no error, no toast. This is the state the TDD gate's UI test #14 must fail against.

---

## 2. Root Cause Analysis

### Bug 1 — no bulk surface, and the popup silently truncates if it ever gets one

`components/outbound/bol/popups/exportBolPop.vue:57-75`:

```js
getExportList(selectedItems) {
  var exportList = []
  selectedItems.map((bol) => { exportList.push(bol.number) })
  console.log(exportList)
  return exportList.join(', ')                          // :64 — joins EVERY number …
},
closePop() { this.$emit('closePop', 'export') },
async exportAction() {
  CommUtil.showPageSpinner(this)
  console.log('Outbound BOL to export:', {id: this.selectedItems[0].id, fileName: 'BOL_Export', exportDetails: true})
  await this.$store.dispatch('outbound/outboundBols/export',
      {id: this.selectedItems[0].id, fileName: 'BOL_Export', exportDetails: true})   // :72 — … sends ONE
  this.closePop()
  CommUtil.hidePageSpinner(this)
}
```

`getExportList` at `:64` already renders **every** selected BOL number into the confirmation sentence
(`:20-21`). `:72` sends `selectedItems[0].id`. The two disagree by construction — the dialog is a
multi-select dialog wired to a single-select request. That mismatch, plus the `join(', ')` string being
built and then discarded, is the same "the frontend was built for it, the backend contract never was"
signature SBDEV-2632 documented for cycle count.

`[0]` discards the tail with **no validation and no error**. Harmless today only because every caller
feeds exactly one item (§1); it becomes live silent data loss the moment `show-select` is wired.

The other half of Bug 1 is that the surface does not exist: `closedOutboundBol.vue:25-36` renders a
`v-data-table` with `item-key="number"` but **no `show-select`, no `v-model`**, and the component
renders no bulk action bar at all — even though `selectedItems: []` sits in `data()` at `:206` and
`exportBolPop` is already mounted at `:104-108` with `:selectedItems="selectedItems"`. The plumbing is
90% present and terminates in nothing.

### Bug 2 — the controller parses input outside the guarded path, and accepts only a scalar

`src/main/java/net/aim_ai/wms/controller/BillOfLadingController.java:264-295`:

```java
// Request Json: { id, exportDetails, fileName }
@PostMapping(path= "/exportOutboundBol", consumes = "application/json", produces = "application/json")
public void exportOutboundBol(@RequestBody Map<String,Object> reqMap, HttpServletResponse response,
                              @AuthenticationPrincipal Principal principal)
        throws WebserviceBusinessExceptionClientSide {
    LOG.debug("start action unitload={}", reqMap.get("id"));
    List<Map<String, String>> errors = new ArrayList<Map<String, String>>();

    Long id = ((Integer) reqMap.get("id")).longValue();                      // :270 ← pre-try
    Boolean exportDetails = (Boolean) reqMap.get("exportDetails");           // :271 ← pre-try

    Billoflading bol = billofladingRepository.findById(id)
        .orElseThrow(() -> new EntityNotFoundException("BillOfLading", id)); // :273 ← pre-try

    try {                                                                    // :275
        billofladingService.exportOutboundBOL(response , bol, exportDetails);
    } catch (BusinessException e) {
        errors.add(getErrorMessage("Runtime Error", e.getMessage()));
        try { response.getWriter().write(errors.toString()); response.getWriter().flush(); }
        catch (IOException e2) { LOG.error(e2.getMessage()); }                // :283
    } catch (Exception e) {
        LOG.error("export failed unexpectedly: {}", e.getMessage(), e);
        errors.add(getErrorMessage("Runtime Error", e.getMessage()));
        try { response.getWriter().write(errors.toString()); response.getWriter().flush(); }
        catch (IOException e2) { LOG.error(e2.getMessage()); }                // :292
    }
}
```

Three raw-500 paths, **all before the `try`**:

| Line | Trigger | Exception | Handled? |
|---|---|---|---|
| `:270` | `id` arrives as a JSON **string** (`{"id":"123"}`) | `ClassCastException` | **No → HTTP 500** |
| `:270` | `id` absent, or `ids` sent instead (which is exactly what Fix D will send) | `NullPointerException` | **No → HTTP 500** |
| `:273` | id is unknown | `EntityNotFoundException` | Yes — `RestExceptionHandler:135` → `ProblemDetail`. Not a 500, but the response is a `ProblemDetail` the blob-reading store cannot surface (Bug 4) |

This is exactly SBDEV-2632's Bug 1 shape. `BillOfLadingController` is in `net.aim_ai.wms.controller`,
**not** `net.aim_ai.wms.controller.rest`, so per SBDEV-2632 §2 it is **not** covered by
`RestEndpointExceptionHandler`'s `@ExceptionHandler(Exception.class)`, and the global
`RestExceptionHandler` has no `Exception`/`RuntimeException` handler. The escape to a raw 500 is
proven there and applies verbatim here — do not re-derive it.

Additionally, `errors.toString()` at `:280` / `:289` is Java `Map.toString()` →
`[{field=Runtime Error, message=…}]`, which is **not valid JSON**, and it is written into a response
whose status is still **200**. Fix A replaces both.

### Bug 3 — the service can only write one BOL, and it closes the stream when it does

`BillofladingService.exportOutboundBOL:912-1016` (declaration at `:914`, tail call at `:1010`):

```java
// TODO: update to return Workbook to controller so the user will get the excel
// file exported                                                          ← :912-913, the original author knew
public void exportOutboundBOL(HttpServletResponse response, Billoflading billOfLading, boolean exportDetails)
        throws BusinessException {
    …
    switch (billOfLading.getState()) {
        case CREATED: case OPEN: case TRUCK_LOADING: case TRANSFER: case CLOSED: break;
        case CANCELLED: throw new BusinessException("Can not export from an cancelled outbound BOL!");
        default: throw new RuntimeException("unexpected billOfLading.getState=" + billOfLading.getState());
    }
    …  // CLOSED → getClosedBOLSkuAmountDetail ; else → getOpenBOLSkuAmountDetail
    …  // headerNames: 3 cols when exportDetails, else 2
    …  // preHeaderRows: 11 rows (BOL name … Signature receiving warehouse) when exportDetails
    try {
        fileExportService.exportExcelFile(null, "Inbound BOL", preHeaderRows, headerNames, rows, response);  // :1010
    } catch (IOException e) {
        throw new BusinessException("create file failed: " + e.getMessage());
    }
}
```

`FileExportService.exportExcelFile:44-135` ends:

```java
ServletOutputStream outputStream = response.getOutputStream();
workbook.write(outputStream);
workbook.close();
outputStream.close();                                     // :129-132
```

⇒ **Calling `exportOutboundBOL` N times would concatenate N complete workbooks into one already-closed
servlet stream and produce a corrupt download.** A loop in the controller is not an option.

**The multi-sheet primitive already exists.** `FileExportService.getExcelFile:138-229` takes a
`Workbook` (null → `new XSSFWorkbook()`), calls `workbook.createSheet(sheetName)` at `:147`, and
**only** writes/closes when `stream != null` (`:222-225`), returning the accumulated `Workbook`. And
`CyclecountService` already uses exactly the accumulate-then-write pairing —
`getExcelFile(null, "aggregated", …, null)` at `:189` followed by
`exportExcelFile(workbook, "detailed", …, response)` at `:208`. Fix B reuses that pattern, so
**`FileExportService` needs no change**.

Note what is **not** wrong here: `exportOutboundBOL` carries no `@Transactional`, and it should not.
See §12 row 1 for the evidence (OSIV off at `application.properties:55`, interface projections,
`Billoflading.java:13-41` carrying zero association annotations, response I/O inside the method, and
`HttpInTransactionArchTest.java:60-67`'s un-scoped rationale).

### Bug 4 — the store downloads first and checks for errors afterwards, into a dead branch

`store/outbound/outboundBols.js:314-333`:

```js
async export(context, data) {
  try {
    const result = await this.$axios.$post('/billOfLading/exportOutboundBol', data, {responseType: 'blob'})
    console.log('exportCycleCount:', result)                     // :315 — copy-pasted label
    const url = URL.createObjectURL(new Blob([result], { type: 'application/vnd.ms-excel' }))
    const link = document.createElement('a')
    link.href = url
    const time = this.$moment().format("_YYYY-MM-DD_HH-mm-ss");
    link.setAttribute('download', data.fileName + time + '.xlsx')
    document.body.appendChild(link)
    link.click()                                                 // :324 — fires unconditionally
    if (result.errors) {                                         // :325 — result is a Blob ⇒ always undefined
      this.$toast.error(result.errors[0].message ? … : …)
    }
  } catch(error) {
    console.log(error)
    this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
  }
},
```

Three defects in twenty lines:

1. **The download happens before any error check** (`:324` precedes `:325`).
2. **The error check can never fire.** `responseType:'blob'` makes `result` a `Blob`; `result.errors`
   is always `undefined`. Dead code.
3. **The object URL and the `<a>` are never released** — no `URL.revokeObjectURL`, no `link.remove()`.

Consequence: when the API writes `errors.toString()` into a still-200 response (`:280`, `:289`), the
operator gets a silently corrupt `.xlsx` and **no toast** — the identical shape SBDEV-2632 measured for
cycle count (77.6% of CREATED CCs). This is why Fix A must switch to real status codes *and* Fix E must
gate the download on them; either alone leaves the silent-corrupt-file mode alive.

---

## 3. The Regression Chain — the empty export is DELIBERATE, do not "fix" it

There is no regression behind the reported symptom (§1: it was never reachable). There *is* one commit
that constrains the design, and getting it wrong would undo three and a half months of intent.

| Date | Commit | What it did |
|---|---|---|
| 2026-04-18 | **`a8af84f`** (wms2-api), cherry-pick of `cb5740d`; ports v1 `8957b9a` / `4c8d500` | Re-anchored `getOpenBOLSkuAmountDetail` **FROM `customerorder` JOIN `billoflading_position`** instead of **FROM `stockunit` JOIN by `outboundlocation_id`**. Commit message: *"Empty (position-less) BOLs therefore appeared in the Excel export with phantom SKU rows… so the result is naturally empty when the BOL has no positions."* |

**Consequence for this plan: an empty sheet for a position-less BOL is correct behaviour**, deliberately
landed on 2026-04-18. Any design that "skips empty BOLs and reports them" would:

- fight that decision directly, and
- on the Open tab skip **100%** of a selection (§1 Q2), and
- drag in a response-header + CORS prerequisite this plan otherwise does not need (§5 Fix B).

So: **empty BOLs keep their sheet** — pre-header + signature block + zero data rows, identical to
today's single-BOL output for the same BOL. §8 test #11 locks this in and must fail if anyone adds a
skip-empties path.

Cross-reference: `sbdocs/3-Resources/workflows/wms2-bol-truck-loading-workflow.md:337` records this
port in its Verification Log (2026-05-08, "v1 `8957b9a` → v2 `a8af84f` (empty BOL export no SKU
rows)"); `:285` maps the endpoint as `POST /v3/billOfLading/exportOutboundBol` at line 265.
`last_verified` is fresh (next re-verify due 2026-08-06 — so expect to update it as part of §14 item 6).

---

## 4. Architecture Overview

```
[Closed Outbound BOLs tab]  closedOutboundBol.vue:25-36
   │  TODAY: no show-select, no v-model, no bulk bar      ← Bug 1 (missing surface)
   │  only path: row kebab → "Export BOL" → addToSelectedItems(item,'export')  :303
   │             (also mis-wired: "Mark as Received" opens the SAME export pop — §0 row 17)
   │  AFTER Fix C: show-select + v-model="selectedItems" + bulk bar with a LIVE Export button
   ▼
[Open Outbound BOLs tab]  openOutboundBol.vue:24-38
   │  bulk bar EXISTS and bulk Close is live; bulk "Export BOLs" is COMMENTED OUT  :33-34
   │  item-key="key" but the DTO has no `key`  :44   ← Fix F
   │  (stays export-disabled — DB Q2: 0/316 OPEN BOLs produce any export row)
   ▼
[outboundBolDetails.vue]  :133  exportBol() pushes one BOL, no reset  ← §0 row 16 / Fix D2
   ▼
[exportBolPop.vue]  :57-75
   │  getExportList() joins EVERY number into the confirm sentence   :64
   │  dispatch('export', {id: selectedItems[0].id, …})               :72  ← Bug 1  ✖ truncates
   ▼
[store/outbound/outboundBols.js]  :313-333
   │  $axios.$post('/billOfLading/exportOutboundBol', data, {responseType:'blob'})
   │  link.click()                     :324  ← fires BEFORE any error check   ← Bug 4
   │  if (result.errors) { … }         :325  ← dead on a Blob                  ← Bug 4
   │  no revokeObjectURL / link.remove()
   │  catch → generic toast            :331
   ▼
[BillOfLadingController.exportOutboundBol]  :264-295
   │  ((Integer) reqMap.get("id")).longValue()          :270  ← Bug 2  ✖ OUTSIDE the try
   │  (Boolean) reqMap.get("exportDetails")             :271  ← also outside
   │  findById(...).orElseThrow(EntityNotFoundException) :273  ← outside (handled → ProblemDetail)
   │  try { … }  catch (BusinessException) → 200 + errors.toString()  :283   ← Bug 2/4
   │             catch (Exception)        → 200 + errors.toString()  :292
   ▼
[BillofladingService.exportOutboundBOL]  :914-1016
   │  state switch — CANCELLED → BusinessException      :931
   │  CLOSED  → billofladingPositionRepository.getClosedBOLSkuAmountDetail(id)   (interface projection)
   │  else    → getOpenBOLSkuAmountDetail(id)                                    (interface projection)
   │  headerNames: 3 cols if exportDetails else 2
   │  preHeaderRows: 11 rows incl. 3 signature lines, only if exportDetails
   │  fileExportService.exportExcelFile(null, "Inbound BOL", …, response)  :1010  ← Bug 3
   ▼
[FileExportService]
   │  exportExcelFile :44   → getOutputStream + write + close + close   :129-132  ← ONE workbook only
   │  getExcelFile    :138  → createSheet :147 ; writes ONLY if stream != null :222-225  ← the primitive Fix B needs
   ▼
corrupt / truncated download, or HTTP 500, depending on which bug fires first
```

### Key Files

| File | Role | Anchor lines |
|---|---|---|
| `wms2-api .../controller/BillOfLadingController.java` | pre-`try` parse + scalar-only contract (Bug 2); 200-with-non-JSON error body; **not** in `.controller.rest` so no `Exception` advice covers it | **264-295** (270, 271, 273, 275, 283, 292); package `net.aim_ai.wms.controller` at `:1`; `extends AdminController` at `:34` (source of `getErrorMessage`, `AdminController.java:247`) |
| `wms2-api .../service/BillofladingService.java` | single-BOL export; state gate; row + pre-header builders; stream-closing tail call | **912-1016** (912-913 the original `TODO: update to return Workbook`, 914 declaration, **931** CANCELLED throw, 936-971 query branch, 973-979 headerNames, 991-1003 preHeaderRows, **1010** tail call), `getRow(...)` at **1018** |
| `wms2-api .../service/FileExportService.java` | `exportExcelFile` writes+closes the servlet stream; `getExcelFile` accumulates sheets — **no change needed** | 44, **129-132**, 138, **147**, **222-225**, 236 (`setCellValue`) |
| `wms2-api .../repo/jpa/BillofladingPositionRepository.java` | the two export queries — native SQL returning **interface projections**, both `@RestResource`-exported | 43-62 (`getOpenBOLSkuAmountDetail`), 64-75 (`getClosedBOLSkuAmountDetail`) |
| `wms2-api .../repo/projection/BolSkuOpenAmountView.java` / `BolSkuClosedAmountView.java` | interface projections (no managed entity, no lazy association) — the reason OSIV is a non-issue | whole files (10 / 9 lines) |
| `wms2-api .../model/Billoflading.java` | `state` is a **`String`**; `name/number/courier/sealnumber/shipped/truck/numberOfParcels` are all scalar columns — **no association is touched by the export** | 13-41, 99 (`getState`) |
| `wms2-api .../service/WmsConstants.java` | `BillOfLadingState` is a `static final String` holder, not an enum — so the `switch` `default:` branch is genuinely reachable | 252-263 |
| `wms2-api .../util/WmsObjectMapper.java` | `standard()` / `shared()` — **not currently imported by `BillOfLadingController`**; Fix A adds the import | 37, 51 |
| `wms2-api .../exceptions/RestExceptionHandler.java` | global advice; **no** `Exception` handler; `EntityNotFoundException` → `ProblemDetail` | 23-24, 135 |
| `wms2-api .../exceptions/RestEndpointExceptionHandler.java` | `@ExceptionHandler(Exception.class)`, scoped to `.controller.rest` — **excludes this controller** | 36-38, 84 |
| `wms2-api .../service/ViewDtoService.java` | `getBolByStatesAndKeyword` — the DTO for **both** tabs; emits `id`+`number`, **no `key`** | **1416-1451** (1428 `id`, 1429 `number`) |
| `wms2-api src/main/resources/application.properties` | CORS block with **`exposed-headers` absent**; `api.paging.max-size=5000`; actuator exposes `metrics`/`prometheus` | 88, 98-101, 104 |
| `wms2-api pom.xml` | Apache POI **5.3.0** — `WorkbookUtil.createSafeSheetName` available | 223-231 |
| `wms2-web-ui .../bol/popups/exportBolPop.vue` | joins every number for display, sends only `[0]` | 57-75 (**64**, **72**) |
| `wms2-web-ui .../bol/closedOutboundBol.vue` | no `show-select`, no bulk bar; `selectedItems` declared but unbound; kebab mis-wire | 25-36, 61-101, **104-108**, **206**, **303-307** |
| `wms2-web-ui .../bol/openOutboundBol.vue` | live bulk bar (Close only); Export commented out; `item-key="key"` | 24-38 (**33-34**), **44**, 314-316 |
| `wms2-web-ui .../bol/outboundBolDetails.vue` | detail-page export; pushes without reset | 101-102, 118, **133**, 140-147 |
| `wms2-web-ui store/outbound/outboundBols.js` | blob handler, click-before-check, dead error guard, leak; **`rowsPerPageItems` max = 100`** | **12**, 46-48, **313-333** (324, 325, 331) |
| `wms2-web-ui jest.config.js` | jsdom, `@/`+`~/` → rootDir, `vue-jest`; **no `setupFiles`** ⇒ `URL.createObjectURL` is undefined | whole file (17 lines) |

---

## 5. Fix Design

Six fixes. **A + B + C + D are the feature**; **E** closes the silent-corrupt-download mode that would
otherwise hide every new error; **F** is the one-word selection-reliability fix on the sibling tab.

### Fix A — `BillOfLadingController.exportOutboundBol`: accept `ids`, everything inside the try

**Why this shape and not alternatives.** The minimal diff — wrapping `:270` in a `try` — would stop the
`ClassCastException`/`NPE` but leave bulk export impossible. A typed `@RequestBody` DTO would be
cleaner but forces a hard API-before-UI deploy coupling with no fallback and diverges from every other
endpoint on this controller. So: one tolerant helper that accepts **both** wire shapes, and a
`writeExportError` that emits real status codes with real JSON — the same pattern SBDEV-2632 Fix A
establishes, deliberately reused rather than reinvented.

**Before** (`BillOfLadingController.java:264-295`) — see §2 Bug 2 for the full block.

**After:**

```java
/**
 * Largest selection accepted in one bulk export. Sized to the Closed-tab page size: the web UI's
 * `paginationClosed.rowsPerPageItems` tops out at 100 (store/outbound/outboundBols.js:12) and
 * Vuetify's select-all header checkbox is page-scoped, so 100 is the largest selection the UI can
 * produce. A lower cap would 422 a legitimate "select all on this page". See SBDEV-2797 §5 Fix A.
 */
static final int MAX_BULK_EXPORT_BOLS = 100;

// Request Json: { ids: [1,2], exportDetails, fileName }  (preferred)
//             | { id: 1,      exportDetails, fileName }  (legacy scalar — per-row kebab + detail page)
@PostMapping(path= "/exportOutboundBol", consumes = "application/json", produces = "application/json")
public void exportOutboundBol(@RequestBody Map<String,Object> reqMap, HttpServletResponse response,
                              @AuthenticationPrincipal Principal principal)
        throws WebserviceBusinessExceptionClientSide {
    LOG.debug("start export with reqMap={}", reqMap);
    try {
        List<Long> ids = parseBolIds(reqMap);
        boolean exportDetails = Boolean.TRUE.equals(reqMap.get("exportDetails"));
        List<Billoflading> bols = new ArrayList<>(ids.size());
        for (Long id : ids) {
            bols.add(billofladingRepository.findById(id)
                .orElseThrow(() -> new EntityNotFoundException("BillOfLading", id)));
        }
        billofladingService.exportOutboundBOLs(response, bols, exportDetails);
    } catch (BusinessException e) {
        writeExportError(response, HttpStatus.UNPROCESSABLE_ENTITY.value(), e.getMessage());
    } catch (EntityNotFoundException e) {
        writeExportError(response, HttpStatus.NOT_FOUND.value(), e.getMessage());
    } catch (Exception e) {
        LOG.error("export failed unexpectedly: {}", e.getMessage(), e);
        writeExportError(response, HttpStatus.INTERNAL_SERVER_ERROR.value(), e.getMessage());
    }
}

/**
 * Accepts {@code ids} as a JSON array OR {@code id} as a single value / comma-separated string.
 * Tolerates Integer, Long and String elements (JSON numbers above 2^31 deserialize as Long, and the
 * legacy dialog sent a scalar), trims each token, drops blanks, de-duplicates while preserving
 * selection order, and enforces {@link #MAX_BULK_EXPORT_BOLS}. Raises BusinessException — never an
 * unchecked ClassCastException / NumberFormatException / NullPointerException — so the caller's catch
 * chain renders a real message instead of an opaque 500.
 */
public static List<Long> parseBolIds(Map<String, Object> reqMap) throws BusinessException {
    Object raw = reqMap.get("ids") != null ? reqMap.get("ids") : reqMap.get("id");
    if (raw == null) {
        throw new BusinessException("No outbound BOL selected for export");
    }
    List<String> tokens = new ArrayList<>();
    if (raw instanceof Collection<?> collection) {
        for (Object o : collection) {
            if (o != null) { tokens.add(String.valueOf(o)); }
        }
    } else {
        tokens.addAll(Arrays.asList(String.valueOf(raw).split(",")));
    }
    Set<Long> ids = new LinkedHashSet<>();
    for (String token : tokens) {
        String trimmed = token.trim();
        if (trimmed.isEmpty()) { continue; }
        try {
            ids.add(Long.valueOf(trimmed));
        } catch (NumberFormatException nfe) {
            throw new BusinessException("Invalid outbound BOL id: " + trimmed);
        }
    }
    if (ids.isEmpty()) {
        throw new BusinessException("No outbound BOL selected for export");
    }
    if (ids.size() > MAX_BULK_EXPORT_BOLS) {
        throw new BusinessException("Too many outbound BOLs selected for one export: "
                + ids.size() + " (maximum " + MAX_BULK_EXPORT_BOLS + ")");
    }
    return new ArrayList<>(ids);
}

/** Writes a real JSON error body with a real status, provided nothing has been streamed yet. */
private void writeExportError(HttpServletResponse response, int status, String message) {
    if (response.isCommitted()) {
        LOG.error("cannot report export error, response already committed: {}", message);
        return;
    }
    // resetBuffer(), NOT reset(): reset() clears the response HEADERS as well as the body, which
    // would strip the Access-Control-* headers Spring Security's CorsFilter has ALREADY written to
    // this response before the controller ran. The browser would then block this very error
    // response, axios would reject with no error.response, and the operator would see the generic
    // "network or server issue" toast — i.e. the fix would look like it did not work.
    // resetBuffer() clears only the body buffer. See SBDEV-2797 §5 Fix A decision table.
    response.resetBuffer();
    response.setStatus(status);
    response.setContentType(MediaType.APPLICATION_JSON_VALUE);
    response.setCharacterEncoding(StandardCharsets.UTF_8.name());
    try {
        // Unexpected (5xx) messages are NOT echoed to the browser — with findById now inside the
        // try, e.getMessage() can carry JDBC URLs / tenant DB names. Detail stays in LOG.error.
        String clientMessage = status >= 500
                ? "Export failed unexpectedly. Please contact support."
                : message;
        Map<String, Object> body = Map.of("errors",
                List.of(getErrorMessage("Runtime Error", clientMessage)));
        response.getWriter().write(WmsObjectMapper.standard().writeValueAsString(body));
        response.getWriter().flush();
    } catch (IOException e) {
        LOG.error("failed writing export error body: {}", e.getMessage());
    }
}
```

**Deliberate decisions inside Fix A:**

| Decision | Rationale |
|---|---|
| **Cap = 100**, not the 50 the analysis suggested | **Evidence-driven, and the analysis bundle was wrong here.** `store/outbound/outboundBols.js:12` sets `paginationClosed.rowsPerPageItems: [5,10,15,20,40,60,80,100]` and there is **no "All" option**; Vuetify's `show-select` header checkbox selects the current page only. So 100 is the largest selection the UI can produce, and a cap of 50 would reject a legitimate select-all on an 80- or 100-row page — the cap would *become* the bug. Sizing at 100 (DB Q3, n=2298 closed BOLs with rows): ~9,250 rows typical, ~27,100 at p95, ≤49,300 worst observed, ×3 columns, plus 12 pre-header rows per sheet. Bounded, single request, no transaction held (§11 row 4). |
| Streaming (`SXSSFWorkbook`) rejected as the memory mitigation | `FileExportService` does `((XSSFWorkbook) workbook).createFont()` **twice** — `:94` in `exportExcelFile` and `:187` in `getExcelFile`, i.e. on both halves of the accumulate-then-write pairing. `SXSSFWorkbook` does **not** extend `XSSFWorkbook`, so either cast would `ClassCastException`. A real streaming migration is a `FileExportService` change affecting every export in the app — out of scope for a normal-priority ticket. The cap is the mitigation. |
| Accept **both** `ids` and `id` | The per-row kebab (`closedOutboundBol.vue:303`, `openOutboundBol.vue:314`) and the detail page (`outboundBolDetails.vue:133`) legitimately export one BOL; forcing them onto `ids` for no benefit widens the UI diff. Tolerance also means **UI-before-API is harmless**, which matters because §7.1's deploy order is API-first and reverts happen. |
| Tolerant `Integer`/`Long`/`String` coercion rather than `(Integer)` cast | Jackson deserializes a JSON number ≤2^31-1 as `Integer` and above it as `Long`. `billoflading.id` comes from the shared `seqentities` sequence, and on **migrated** tenants that sequence carries a foreign high block (see the `wms2-seqentities-dual-island-id-space` incident) — an id above 2^31 is not hypothetical, and today it is a straight 500. |
| `parseBolIds` is **`public static`** | `BillOfLadingController` is in `net.aim_ai.wms.controller`; its test is in `net.aim_ai.wms.unit.controller`. **Zero** test classes in this repo live in the production controller package, so package-private would make the direct helper test fail to **compile** — the exact trap SBDEV-2632 Fix A hit and corrected. It is a pure function with no state, so widening visibility costs nothing. |
| De-dup via `LinkedHashSet` | Preserves selection order (⇒ deterministic sheet order, testable) and prevents duplicate sheet names, which POI rejects with `IllegalArgumentException`. Also absorbs §0 row 16's accumulation if Fix D2 is ever reverted. |
| Status **422** / **404** / **500**, JSON body | Only *expected* validation outcomes become 4xx; genuine defects keep surfacing as 5xx to monitoring. Blanket-422 would hide real bugs. Identical mapping to SBDEV-2632 Fix A — one convention, two endpoints. |
| `EntityNotFoundException` now caught locally (it used to reach `RestExceptionHandler:135`) | Intentional: the endpoint is `void` + `HttpServletResponse`, so a locally-written JSON body is what the blob-reading store can parse uniformly (Fix E). Message text is preserved. |
| 5xx messages are **not** echoed to the client | With `findById` inside the try, `e.getMessage()` on an unexpected failure can carry JDBC URLs / tenant DB names. |
| **`response.resetBuffer()`, never `response.reset()`** | **Load-bearing.** CORS is wired through Spring Security's filter, so `DefaultCorsProcessor` has already physically written `Access-Control-Allow-Origin` onto the response before `exportOutboundBol()` runs. `ServletResponse.reset()` is specified to clear the buffer, the status code **and the headers** — stripping those, the browser blocks the error response, axios rejects with no `error.response`, and Fix E falls through to the generic toast: the exact symptom this plan is meant to remove. **No MockMvc test can catch this** (MockMvc has no `CorsFilter`), so it is guarded by test #20 *and* a verify-script NEGATIVE row. |
| `Boolean.TRUE.equals(reqMap.get("exportDetails"))` replaces `(Boolean) reqMap.get(...)` | The old cast NPEs on unboxing when the key is absent and `ClassCastException`s on `"true"`. The service parameter is a primitive `boolean`; absent ⇒ `false`, which matches the two-column legacy behaviour. Every live caller sends `exportDetails: true`. |
| `WmsObjectMapper.standard()` (not `.shared()`) | Matches SBDEV-2632 Fix A. **Note: this controller does not import `WmsObjectMapper` today** — the import is part of the diff (unlike `CycleCountController`, which already had it). |
| Keep `throws WebserviceBusinessExceptionClientSide` on the signature | Nothing in the new body throws it, but removing it from a public controller method is an unrelated signature change; leave it. |

### Fix B — `BillofladingService.exportOutboundBOLs(response, List<Billoflading>, boolean)`: `Summary` + one sheet per BOL

**Shape decision: extract the shared per-BOL sheet builder.** The full option comparison — extract
vs. duplicate vs. a new `FileExportService.exportExcelFiles(...)` primitive — is recorded in §10
decision 7. Summary: the per-sheet content is **identical** between the single and multi paths
(same pre-header, same headers, same rows — and, after user decision 11, the same naming rule), so
duplicating ~80 lines including the 11-row signature block buys nothing and guarantees drift.

**The guardrail, stated precisely.** There are **10** existing tests in
`BillofladingServiceUnitTest$ExportOutboundBOL` (`@Test` at `:903, 915, 928, 941, 957, 973, 1005, 1031,
1067, 1083` — an earlier draft said 12; corrected in review). All 10 assert only on thrown-exception
messages, `verify(billofladingPositionRepository)…`, or the six arguments passed to the `@Mock`ed
`exportExcelFile`. So:

- **7 must pass unedited.** They pin the 11-row pre-header, the 2-vs-3 column header arrays, the
  CLOSED-vs-open query branch, and the CANCELLED message. If any of these needs editing, the extraction
  changed something it should not have — that is the signal to stop and re-read the diff.
- **3 are edited, once, in the same commit:** `exportsWithDetails` (`:998`), `exportsWithoutDetails`
  (`:1024`), `handlesMultipleSkuRows` (`:1060`), each changing `eq("Inbound BOL")` → `eq("BN-100")`
  (the shared `testBol` fixture sets `setNumber("BN-100")` at `:185`). This is the visible price of
  user decision 11, and it is deliberately **not** deferred to a later commit, where it would read as
  a fixup for a broken test rather than as the intended behaviour change.
- **One invariant the extraction must preserve** (Architect §7.1): `exportsWithoutDetails` asserts
  `isNull()` for `preHeaderRows` at `:1025`, and `FileExportService` branches on
  `preHeaderRows != null` to compute the row offset — so `buildSheetData` must return **`null`**, not
  `List.of()`, when `exportDetails == false`. §8 test #21 extends that guard to the bulk path.

**After** (`BillofladingService.java`, replacing `:912-1016`):

```java
    /** Per-BOL sheet payload, shared by the single-BOL and bulk export paths so they cannot drift. */
    private record BolSheetData(List<Object[]> preHeaderRows, String[] headerNames, List<Object[]> rows) {}

    /**
     * State gate shared by both export paths. Returns null when the BOL is exportable, otherwise the
     * reason. Kept as a returned reason (rather than a throw) so the bulk path can record it per BOL
     * instead of losing a whole workbook — see SBDEV-2797 §5 Fix B.
     */
    private String exportBlockReason(Billoflading billOfLading) {
        switch (billOfLading.getState()) {
            case CREATED:       // waterfall
            case OPEN:          // waterfall
            case TRUCK_LOADING: // waterfall
            case TRANSFER:      // waterfall
            case CLOSED:
                return null;
            case CANCELLED:
                return "Can not export from an cancelled outbound BOL!";
            default:
                throw new RuntimeException("unexpected billOfLading.getState=" + billOfLading.getState());
        }
    }

    /**
     * Unchanged signature and unchanged content. ONE behavioural change (SBDEV-2797 user decision 11):
     * the sheet is now named for the BOL number instead of the hard-coded literal "Inbound BOL", which
     * was a mislabel on an outbound export. Both export paths share {@link #uniqueSheetName} so there
     * is exactly one naming rule.
     */
    public void exportOutboundBOL(HttpServletResponse response, Billoflading billOfLading, boolean exportDetails)
            throws BusinessException {
        LOG.debug("start");
        String blocked = exportBlockReason(billOfLading);
        if (blocked != null) {
            throw new BusinessException(blocked);
        }
        BolSheetData sheet = buildSheetData(billOfLading, exportDetails);
        try {
            fileExportService.exportExcelFile(null,
                    uniqueSheetName(billOfLading, new LinkedHashSet<>()), sheet.preHeaderRows(),
                    sheet.headerNames(), sheet.rows(), response);
        } catch (IOException e) {
            throw new BusinessException("create file failed: " + e.getMessage());
        }
        LOG.debug("end");
    }

    /**
     * Extracted verbatim from the previous exportOutboundBOL body — no behavioural change.
     *
     * <p>INVARIANT: returns {@code null} for preHeaderRows when {@code exportDetails == false} — NOT
     * an empty list. {@code exportsWithoutDetails} (BillofladingServiceUnitTest @Test :1005) asserts
     * {@code isNull()} on that argument at :1025, and FileExportService branches on
     * {@code preHeaderRows != null} to decide the row offset. Pinned by §8 test #21.</p>
     */
    private BolSheetData buildSheetData(Billoflading billOfLading, boolean exportDetails) {
        List<Object[]> rows = new ArrayList<>();
        if (billOfLading.getState().equals(CLOSED)) {
            …  // getClosedBOLSkuAmountDetail loop, unchanged
        } else {
            …  // getOpenBOLSkuAmountDetail loop, unchanged
        }
        String[] headerNames = exportDetails
                ? new String[] { "SKU ID", "Details", "Amount" }
                : new String[] { "SKU ID", "Amount" };
        List<Object[]> preHeaderRows = null;          // ← stays null, see INVARIANT above
        if (exportDetails) {
            …  // the 11 getRow(...) lines, unchanged
        }
        return new BolSheetData(preHeaderRows, headerNames, rows);
    }

    /** Fixed name of the leading index sheet in a multi-BOL workbook (SBDEV-2797 user decision 12). */
    static final String SUMMARY_SHEET_NAME = "Summary";

    /**
     * Bulk export: a leading Summary index sheet, then one sheet per BOL in the same workbook, each
     * tab named by BOL number and keeping its own pre-header + signature block.
     *
     * <p>Deliberately NOT @Transactional: the method's last act streams the workbook into the servlet
     * response, which would pin a per-tenant Hikari connection to the client socket for the whole
     * download — the concern stated un-scoped in HttpInTransactionArchTest:60-67. Both export queries
     * return interface projections and every Billoflading getter used is a scalar column
     * (Billoflading.java:13-41 has zero association annotations), so OSIV-disabled
     * (application.properties:55) raises no LazyInitializationException. See SBDEV-2797 §12 row 1.</p>
     */
    public void exportOutboundBOLs(HttpServletResponse response, List<Billoflading> billsOfLading,
                                   boolean exportDetails) throws BusinessException {
        if (billsOfLading == null || billsOfLading.isEmpty()) {
            throw new BusinessException("No outbound BOL selected for export");
        }
        // A single selection produces exactly one sheet and NO Summary sheet: a one-row index of one
        // BOL restates that BOL's own pre-header and would displace the printable document to tab 2
        // on the highest-frequency path (the per-row kebab). See SBDEV-2797 §10 decision 12.
        if (billsOfLading.size() == 1) {
            exportOutboundBOL(response, billsOfLading.get(0), exportDetails);
            return;
        }

        // Seeded with the Summary name so a BOL numbered "Summary" is renamed by the dedup path
        // rather than making POI throw. Impossible on observed data (all OBOL######) — cheap insurance.
        Set<String> usedSheetNames = new LinkedHashSet<>();
        usedSheetNames.add(SUMMARY_SHEET_NAME);

        // Pass 1 — build every sheet's payload, so the Summary row counts are the SAME numbers the
        // data sheets carry. Building the summary from a second set of queries could disagree with
        // the data under concurrent truck loading (no transaction spans them — §11 row 4).
        List<String> sheetNames = new ArrayList<>(billsOfLading.size());
        List<BolSheetData> sheets = new ArrayList<>(billsOfLading.size());
        List<Object[]> summaryRows = new ArrayList<>(billsOfLading.size());
        for (Billoflading bol : billsOfLading) {
            String sheetName = uniqueSheetName(bol, usedSheetNames);
            String blocked = exportBlockReason(bol);
            BolSheetData sheet = (blocked != null)
                    ? new BolSheetData(
                            List.of(getRow("BOL name", bol.getName()), getRow("NOTE", blocked)),
                            exportDetails ? new String[] { "SKU ID", "Details", "Amount" }
                                          : new String[] { "SKU ID", "Amount" },
                            List.of())
                    : buildSheetData(bol, exportDetails);
            sheetNames.add(sheetName);
            sheets.add(sheet);
            summaryRows.add(new Object[] { sheetName, bol.getNumber(), bol.getName(),
                    bol.getShipped(), bol.getCourier(), sheet.rows().size(),
                    blocked == null ? "" : blocked });
        }

        String[] summaryHeaders = new String[] { "Sheet", "BOL ID", "BOL Name", "Shipped",
                "Courier", "SKU Rows", "Note" };

        // Pass 2 — Summary first (so it is tab 1), then each BOL; the LAST call writes the stream once.
        try {
            Workbook workbook = fileExportService.getExcelFile(null, SUMMARY_SHEET_NAME, null,
                    summaryHeaders, summaryRows, null);
            for (int i = 0; i < sheets.size(); i++) {
                BolSheetData sheet = sheets.get(i);
                if (i == sheets.size() - 1) {
                    // exportExcelFile creates the final sheet AND writes+closes the servlet stream
                    // exactly once — same accumulate-then-write pairing as CyclecountService:189/208.
                    fileExportService.exportExcelFile(workbook, sheetNames.get(i),
                            sheet.preHeaderRows(), sheet.headerNames(), sheet.rows(), response);
                } else {
                    workbook = fileExportService.getExcelFile(workbook, sheetNames.get(i),
                            sheet.preHeaderRows(), sheet.headerNames(), sheet.rows(), null);
                }
            }
        } catch (IOException e) {
            throw new BusinessException("create file failed: " + e.getMessage());
        }
        LOG.debug("end with bols={}", billsOfLading.size());
    }

    /**
     * Excel sheet names are capped at 31 chars, may not contain [ ] : * ? / \, and must be unique —
     * POI throws IllegalArgumentException otherwise, which would turn a legitimate multi-select into
     * a 500. Defensive on current data: 0 of 2835 billoflading.number values need sanitising and all
     * 2835 are distinct (SBDEV-2797 §1 Q4).
     */
    static String uniqueSheetName(Billoflading bol, Set<String> used) {
        String base = WorkbookUtil.createSafeSheetName(
                bol.getNumber() == null || bol.getNumber().isBlank()
                        ? "BOL " + bol.getId() : bol.getNumber());
        String candidate = base;
        int n = 2;
        while (!used.add(candidate)) {
            String suffix = "_" + n++;
            candidate = base.substring(0, Math.min(base.length(), 31 - suffix.length())) + suffix;
        }
        return candidate;
    }
```

**Deliberate decisions inside Fix B:**

| Decision | Rationale |
|---|---|
| **One sheet per BOL**, not merged rows with a leading `BOL` column | Approved decision #5 (§10). Each BOL's export is a *shipping document* with its own pre-header and three signature lines — the 11-row block at `:991-1003` exists to be printed and signed. Merging rows into one sheet would have to drop or repeat that block. The reverse of SBDEV-2632's choice, deliberately, because the artifacts differ. |
| **Both paths name sheets by `bol.getNumber()`; the `"Inbound BOL"` literal is deleted** | **User decision 11** (Architect finding 10). `number` is unique (2835/2835), 10 chars, illegal-char-free (Q4), and is what the operator sees in the table's "Outbound BOL ID" column. `name` is operator-supplied free text and is neither unique nor length-bounded. Deleting the literal retires a mislabel (`"Inbound BOL"` on an **outbound** export) and is what eliminates the cardinality-dependent artifact naming the first draft had to accept. **Price, stated plainly:** the single-BOL output — the only shape in production use — changes, 3 existing assertions are edited (`:998, :1024, :1060` → `eq("BN-100")`), and operators need telling (§14 item 6). |
| **A leading `Summary` index sheet when N ≥ 2** | **User decision 12** (Architect finding 11). Columns: `Sheet, BOL ID, BOL Name, Shipped, Courier, SKU Rows, Note`. It is the navigation index for up to 100 tabs, and its `SKU Rows` column is how an operator sees at a glance which BOLs came back empty — the job the **rejected** skipped-BOL response header would have done, now in-band and CORS-free. One extra `getExcelFile` call; no new primitive, no `FileExportService` change. |
| **No `Summary` sheet at N = 1** | A one-row index of one BOL restates what that BOL's own 11-row pre-header already carries (name, shipped, courier) and displaces the printable shipping document to tab 2 on the **highest-frequency path** — the per-row kebab, which is how all 2,516 closed BOLs are exported today. Paying a daily click for zero information is the wrong trade. This is an **additive** cardinality difference, materially weaker than the naming instability it replaces: every BOL's data sheet is named `OBOL######` at every N, so a consumer that looks a BOL up **by name** is unaffected. Residual recorded as AC1 (§10). |
| `usedSheetNames` is seeded with `"Summary"` before the loop | A BOL numbered `Summary` would otherwise make POI throw `IllegalArgumentException` on the duplicate. Impossible on observed data (all `OBOL######`) — one line of insurance on a path where the exception would be a 500. |
| **Two passes over the selection** (build all payloads, then write sheets) rather than one | The Summary sheet must be **tab 1**, but its `SKU Rows` column is only knowable after each BOL's rows are built. Two passes make the summary's counts the *same numbers* the data sheets carry, by construction; deriving them from a second set of queries could disagree under concurrent truck loading, since no transaction spans them (§11 row 4). **Cost, quantified:** all N `List<Object[]>` payloads are alive at once — at the cap, worst observed 49,300 rows × ~150 bytes (2-3 `Object[]` refs plus the JDBC-fresh Strings and `BigDecimal`) ≈ **7 MB**, against tens of MB of `XSSFCell` objects for the same data. So it is a single-digit-percent addition to peak heap, not the doubling this shape would imply if the payload dominated. Rejected alternative: accumulate all BOL sheets, add Summary last, `workbook.setSheetOrder(SUMMARY_SHEET_NAME, 0)`, then write — correct and single-pass, but the reorder must happen **before** the write, so the service would have to own the final `workbook.write(response.getOutputStream())` itself, forfeiting the "no new POI plumbing, no `FileExportService` change" property this fix rests on. |
| `WorkbookUtil.createSafeSheetName` rather than a hand-rolled regex | POI 5.3.0 ships it (`pom.xml:223-231`); it is the library's own definition of the constraint, so it cannot drift from `createSheet`'s validation. De-duplication is layered on top because `createSafeSheetName` does not do it. |
| Last-BOL `exportExcelFile` + earlier `getExcelFile(…, null)` | The exact accumulate-then-write pairing `CyclecountService:189/208` already uses. **No `FileExportService` change**, and the stream is opened/written/closed exactly once — the direct fix for Bug 3. |
| `size() == 1` delegates to `exportOutboundBOL` | Keeps **one** code path for the single-BOL case, so the per-row kebab, the detail page and a one-tick selection are byte-identical to each other and CANCELLED still surfaces as a 422 exactly as today. After user decision 11 this is no longer a *preservation* argument (the sheet name changes on both paths) — it is a de-duplication argument, plus it is what suppresses the `Summary` sheet at N=1. |
| **Empty (position-less) BOLs keep their sheet** | §3. `a8af84f` deliberately made a position-less BOL export zero rows; the sheet with its signature block is still a valid, printable document. 8.7% of CLOSED BOLs are affected (Q2) — not an edge case. Test #11 locks it in. |
| **CANCELLED among valid ids ⇒ a per-BOL NOTE row in that BOL's sheet**, not a whole-request 422 | Three reasons. (a) Blast radius: a whole-request 422 lets one stale row destroy a 100-sheet workbook the operator waited for. (b) The note lands in the **artifact**, which is what gets saved, emailed and audited weeks later — a toast lasts seconds. (c) It needs no response header, so this plan needs **no `rest.security.cors.exposed-headers` property and no `SecurityConfiguration` change** — unlike SBDEV-2632 Fix C. The Closed tab lists only `CLOSED` BOLs, so this is a hand-crafted-request contract, not an observable UI flow (Q1: zero CANCELLED rows on wineco-dev). |
| The state gate becomes `exportBlockReason` returning a reason, not a throw | Lets the bulk path record per-BOL outcomes while the single path re-throws the **identical** message, so `throwsWhenCancelled` (`BillofladingServiceUnitTest:905-915`, asserting `hasMessageContaining("Can not export from an cancelled outbound BOL")`) passes unedited. |
| `default:` still throws `RuntimeException` | `BillOfLadingState` is a `String` constant holder (`WmsConstants.java:252-263`), not an enum, so an unknown value is genuinely reachable and genuinely a bug. Keep it a 500 (Fix A logs it with the stack trace). |
| **No `@Transactional`** — contradicting the analysis bundle | Four independent reasons, any one sufficient. (1) The method's last act is `workbook.write(response.getOutputStream())`, pinning a per-tenant Hikari connection to the **client socket** for the whole download — at the cap, 101 sheets of assembly plus the full response write. The principle is stated un-scoped in `HttpInTransactionArchTest.java:60-67`'s own `.because(...)`: *“an HTTP round-trip inside an open @Transactional holds the tenant DB connection across external I/O — under multi-replica deployment this starves the per-tenant Hikari pool.”* (**Corrected after review:** the first draft cited `CLAUDE.md:194`, which is bullet 4 of “Scheduled Jobs & Tenant Context” and is job-scoped. Right conclusion, wrong citation.) (2) `readOnly = true` would buy **zero** cross-query consistency: no `isolation` property exists anywhere in `application*.properties`, so PostgreSQL **READ COMMITTED** applies and re-snapshots per statement. (3) The gather-then-write split that would satisfy both concerns is **not free** — a `@Transactional` gather method called from `exportOutboundBOLs()` in the same bean is Spring **self-invocation** and would be silently non-transactional, so it needs a new collaborator bean or an explicit `TransactionTemplate`. (4) OSIV is not a risk here: OSIV is off (`application.properties:55`), both queries return **interface projections** (`BolSkuOpenAmountView`, `BolSkuClosedAmountView`), and `Billoflading.java:13-41` carries **zero** JPA association annotations — every field is `String`/`Long`/`LocalDate` and FKs are raw `Long` ids, so there is no lazy proxy to fail on. Empirical proof: `exportOutboundBOL` has no `@Transactional` today and works. Same stance SBDEV-2632 §11 row 4 took on the identical shape. |
| `usedSheetNames` is a method-local `LinkedHashSet` | Request-scoped, discarded with the stack frame — no per-replica state (§11 row 1). |

### Fix C — `closedOutboundBol.vue`: multi-select and a live bulk Export bar

**C1 — the data table gets a selection model** (`:25-36`):

```html
<!-- Before -->
<v-data-table
  id="outboundBolClosedTable"
  :headers="headers"
  :items="outboundBols"
  item-key="number"
  …

<!-- After -->
<v-data-table
  id="outboundBolClosedTable"
  v-model="selectedItems"
  :headers="headers"
  :items="outboundBols"
  item-key="number"
  show-select
  …
```

`item-key="number"` already resolves — `ViewDtoService:1428` emits `number`, and Q4 proves it is unique
and non-null across all 2,835 rows. It is deliberately **not** changed to `id`: `number` works, and a
gratuitous change here would collide with Fix F's verify rows. (Contrast the Open tab, whose
`item-key="key"` resolves to `undefined` — that is Fix F.)

**C2 — the bulk action bar**, mirroring `openOutboundBol.vue:24-38` but with Export **live** and no
bulk-Close button (these BOLs are already closed):

```html
<div
  v-if="selectedItems.length > 0"
  class="d-flex justify-space-between primary pa-2 align-center"
>
  <v-card-text class="pa-0 white--text">{{ selectedItems.length }} items selected.</v-card-text>
  <div class="d-flex">
    <v-btn text tile depressed dark @click="showExportPop">Export BOLs
      <v-icon small class="ml-2">mdi-export-variant</v-icon></v-btn>
    <v-divider class="mx-2" dark vertical></v-divider>
    <v-btn text tile depressed dark @click="selectedItems = []">Cancel</v-btn>
  </div>
</div>
```

**C3 — the per-row path must stop clobbering the checkbox selection** (`:303-307`):

```js
// Before
addToSelectedItems(item, chosenAction) {
  this.selectedItems = []          // ← once selectedItems is the table's v-model, this
  this.selectedItems.push(item)    //   VISIBLY unchecks every tick the operator made
  console.log('chosen action and data:', chosenAction, this.selectedItems)
  this.showExportPop()
},

// After
addToSelectedItems(item, chosenAction) {
  // Per-row kebab export uses its own array so it cannot disturb the checkbox selection that
  // now drives the bulk bar (SBDEV-2797 Fix C).
  this.rowActionItems = [item]
  // NOTE(SBDEV-2797 §0 row 17): this opens the EXPORT dialog for chosenAction === 'close' too.
  // Pre-existing mis-wire — this component imports no receive/close popup. Tracked separately;
  // deliberately not changed here.
  this.showRowExportPop()
},
showRowExportPop() {
  this.showRowExportBol = true
},
```

with `rowActionItems: []` and `showRowExportBol: false` added to `data()` beside the existing
`selectedItems: []` (`:206`), a **second** `exportBolPop` instance bound to `rowActionItems`, and
`closePop` clearing the right array per dialog:

```html
<!-- bulk: bound to the table's selection -->
<export-bol-pop :showExportBol="showExportBols" :selectedItems="selectedItems" @closePop="closeBulkPop" />
<!-- per-row kebab: bound to its own one-element array -->
<export-bol-pop :showExportBol="showRowExportBol" :selectedItems="rowActionItems" @closePop="closeRowPop" />
```

**C4 — the Open tab's bulk Export button stays commented out** (`openOutboundBol.vue:33-34`), with the
evidence attached so a future reader does not "helpfully" enable it:

```html
<!-- Bulk export is deliberately DISABLED on the Open tab. Both export queries hinge on
     billoflading_position, which only exists after truck loading, so an OPEN BOL has nothing
     to export by construction — 0 of 316 OPEN BOLs on wineco-dev produce a single export row
     (SBDEV-2797 §1 Q2). Making them export empty rather than phantom rows was the deliberate
     point of commit a8af84f (2026-04-18). Enabling this button would produce a workbook of
     empty sheets. Bulk export lives on the Closed tab. See SBDEV-2797 §0 row 9.
<v-btn text tile depressed dark @click="showExportPop">Export BOLs
  <v-icon small class="ml-2">mdi-export-variant</v-icon></v-btn> -->
```

**Deliberate decisions inside Fix C:**

| Decision | Rationale |
|---|---|
| Closed tab only | Decision #4 (§10), on DB Q2 evidence: 0/316 OPEN BOLs are exportable. |
| A **second** `exportBolPop` instance rather than one shared array | The single-array design is what forces the clobber. Two instances keep the bulk selection and the kebab's one-off strictly separate, which is what test #18 asserts. Vuetify dialogs are cheap; `closeBolPop.vue` already demonstrates two popups coexisting in one component (`outboundBolDetails.vue:101-102`). |
| Keep `item-key="number"` on the Closed tab | It already resolves and is unique (Q4). Changing it would be churn and would muddy Fix F's assertions. |
| Do **not** fix the kebab mis-wire (§0 row 17) | "Mark as Received" needs a receive popup this component does not import. Adding one is a feature, not this ticket. The comment records it so review does not read the preserved behaviour as a Fix C bug. |
| No `select-all across pages` | Vuetify's header checkbox is page-scoped and `rowsPerPageItems` maxes at 100, which is exactly the Fix A cap. Nothing to add. |

### Fix D — `exportBolPop.vue`: send every selected id (and stop accumulating on the detail page)

**D1 — the popup** (`exportBolPop.vue:57-75`):

```js
// Before (:64, :71, :72)
getExportList(selectedItems) {
  var exportList = []
  selectedItems.map((bol) => { exportList.push(bol.number) })
  console.log(exportList)
  return exportList.join(', ')
},
async exportAction() {
  CommUtil.showPageSpinner(this)
  console.log('Outbound BOL to export:', {id: this.selectedItems[0].id, fileName: 'BOL_Export', exportDetails: true})
  await this.$store.dispatch('outbound/outboundBols/export',
      {id: this.selectedItems[0].id, fileName: 'BOL_Export', exportDetails: true})
  this.closePop()
  CommUtil.hidePageSpinner(this)
}

// After
getExportList(selectedItems) {
  return selectedItems.map((bol) => bol.number).join(', ')
},
async exportAction() {
  if (!this.selectedItems || this.selectedItems.length === 0) {
    this.closePop()
    return
  }
  CommUtil.showPageSpinner(this)
  try {
    const ids = this.selectedItems.map((bol) => bol.id)
    await this.$store.dispatch('outbound/outboundBols/export', {
      ids,
      fileName: ids.length > 1 ? 'BOL_Export_Multiple' : 'BOL_Export',
      exportDetails: true,
    })
    this.closePop()
  } finally {
    CommUtil.hidePageSpinner(this)
  }
}
```

**D2 — the detail page stops accumulating, in BOTH methods** (`outboundBolDetails.vue:133` and `:137`,
§0 row 16). Both push onto the **same** `selectedItems` array (`:118`), which is bound to **both**
mounted popups (`:101-102`), so the two methods are one defect with two call sites:

```js
// Before  (:132-139)
exportBol() {
  this.selectedItems.push(Object.assign({},this.outboundBol))
  this.showExportBol = true
},
closeBol() {
  this.selectedItems.push(Object.assign({},this.outboundBol))
  this.showCloseBol = true
},
// After
exportBol() {
  // Assign, don't push: a dialog dismissed without closePop() would otherwise leave the previous
  // entry behind and Fix D would send ids:[X,X] (SBDEV-2797 §0 row 16).
  this.selectedItems = [Object.assign({}, this.outboundBol)]
  this.showExportBol = true
},
closeBol() {
  // Same reason. This one does not double-close today — closeBolPop.vue:78-81 branches on the
  // `mode` prop and this page hard-codes mode: 'single' (:119), so it still reads [0] — but after
  // an Export → dismiss → Close sequence the confirm sentence would name the BOL twice.
  this.selectedItems = [Object.assign({}, this.outboundBol)]
  this.showCloseBol = true
},
```

**Why `closeBol()` is in scope even though it is not the reported bug** (Architect finding 8): it is the
same statement in the adjacent method block, in a commit that is already editing the one above it, and
leaving it means the next person reads the asymmetry as intentional. The `mode: 'single'` guard that
makes it currently harmless is one prop away from not being — if this page ever gained a multi mode,
`closeBolPop`'s `selectedItems.map(item => item.id)` branch (`:83`) would close the same BOL twice.

**Deliberate decisions inside Fix D:**

| Decision | Rationale |
|---|---|
| `ids` array, not the `join(', ')` string | The joined string is what SBDEV-2632's cycle-count bug was made of (`Long.parseLong("1, 2")`). Send a typed array; Fix A still tolerates the legacy scalar for anything that has not migrated. |
| `getExportList` retained, simplified | It still renders the confirmation sentence at `:20-21`, and once `ids` carries the whole array the sentence becomes *truthful* rather than coincidentally correct. The `console.log` at `:63` goes. |
| Filename `BOL_Export_Multiple` | Mirrors `exportCyclePop.vue:70`'s `CC_Multiple` convention so operators see a consistent naming scheme across bulk exports. |
| Empty-selection early return | `exportBolPop`'s `<v-card v-if="selectedItems.length > 0">` already hides the body, but `exportAction` is a method on a mounted component; guard it rather than rely on template state. Without the guard, `selectedItems[0].id` was a latent `TypeError`. |
| Delete both `console.log`s (`:63`, `:71`) | `:71` prints BOL data to the browser console; `:63` is noise. `:71` also matches the `{id: this.selectedItems[0]` shape, so leaving it would make the verify NEGATIVE row fail on otherwise-correct code — the exact trap SBDEV-2632 Fix D1 documents. |
| `hidePageSpinner` moved into `finally` | Today a throw in the dispatch leaves the page spinner up forever. One line, same lines being rewritten. |

### Fix E — store `export`: check before downloading, then clean up

**Before** (`store/outbound/outboundBols.js:313-333`) — see §2 Bug 4.

**After:**

```js
async export(context, data) {
  let url = null
  let link = null
  try {
    const response = await this.$axios.post('/billOfLading/exportOutboundBol', data,
        { responseType: 'blob' })
    // The API now answers a non-2xx with a JSON error body, so axios rejects and we never get
    // here on failure. This guard covers the residual case of a 2xx carrying a JSON body.
    const contentType = (response.headers['content-type'] || '')
    if (contentType.includes('application/json')) {
      this.$toast.error(await extractBlobErrorMessage({ response }))
      return
    }
    url = URL.createObjectURL(new Blob([response.data], { type: 'application/vnd.ms-excel' }))
    link = document.createElement('a')
    link.href = url
    const time = this.$moment().format('_YYYY-MM-DD_HH-mm-ss')
    link.setAttribute('download', data.fileName + time + '.xlsx')
    document.body.appendChild(link)
    link.click()
  } catch (error) {
    console.log(error)
    this.$toast.error(await extractBlobErrorMessage(error))
  } finally {
    if (link && link.parentNode) { link.remove() }
    if (url) { URL.revokeObjectURL(url) }
  }
},
```

with the blob-error helper. **Reuse, do not re-declare:** SBDEV-2632 Fix D2 introduces
`extractBlobErrorMessage`; if that plan has landed, import it from wherever it lives (its Fix D2 allows
`util/commonUtility.js`) instead of adding a second copy. §7.1 records the coordination.

```js
// A blob-typed response carries the JSON error body as bytes, so error.response.data is a Blob,
// not an object. Read it back to text before parsing; fall back to the generic message.
export async function extractBlobErrorMessage(error) {
  const generic = 'Error: Request failed due to a network or server issue. Please retry.'
  try {
    const data = error && error.response && error.response.data
    if (!data) return generic
    const text = typeof data.text === 'function' ? await data.text() : data
    const parsed = typeof text === 'string' ? JSON.parse(text) : text
    const first = parsed && parsed.errors && parsed.errors[0]
    return (first && (first.message || first.field)) || generic
  } catch (e) {
    return generic
  }
}
```

**Deliberate decisions inside Fix E:**

| Decision | Rationale |
|---|---|
| `$axios.$post` → `$axios.post` | The `$`-shorthand discards the response envelope, which is why `result.errors` and every header are unreachable. `post` gives `{data, headers, status}`. |
| Download **only** after the content-type check, inside the same `try` | The core of Bug 4: today `link.click()` at `:324` precedes the check at `:325`. Ordering *is* the fix. |
| **Why the `application/json` gate does not swallow the success path** — even though the endpoint declares `produces = "application/json"` | Architect finding 7; a reviewer will ask this. The success path sets **no** `Content-Type` at all: `FileExportService:129-132` touches the response solely via `getOutputStream()` — no `setContentType`, no `Content-Disposition` — and the handler returns **`void`**, so Spring never applies the `produces` negotiation to the response. The xlsx bytes therefore arrive with whatever default the container emits, never `application/json`, while `writeExportError` sets `application/json` **explicitly**. The gate discriminates correctly today. **Flagged as fragile:** if anyone later makes the success path honour `produces` — or adds the `Content-Disposition`/`Content-Type` headers this endpoint arguably should have — **every** export would be swallowed by this gate and no test in this plan would catch it, because the service tests mock `FileExportService` and never set a real content type. A belt-and-braces alternative (also gate on `response.status !== 200`) is not added because the API now rejects with a real non-2xx, so axios never reaches the success branch on error; the residual is the 2xx-carrying-JSON case this gate exists for. Recorded as AC7 (§10). |
| No response-header read for a "skipped" notice | Fix B keeps every per-BOL outcome in-band, so there is nothing to read. This is what keeps the plan free of a CORS prerequisite (§7.1 row 3). |
| Generic toast retained as the fallback | A genuine network failure has no `error.response`; only a parseable body upgrades the message. |
| `revokeObjectURL` + `link.remove()` in `finally` | Pre-existing leak on the same lines being rewritten. Not a behaviour change. |
| `link.parentNode` guard before `remove()` | The `catch` path can run before `appendChild`. |
| Delete the `console.log('exportCycleCount:', result)` at `:315` | Wrong label (copy-paste from cycle count) and it prints the payload. |

### Fix F — `openOutboundBol.vue:44`: `item-key="key"` → `item-key="id"`

```html
<!-- Before -->  <v-data-table id="outboundBolOpenTable" v-model="selectedItems" … item-key="key" show-select
<!-- After  -->  <v-data-table id="outboundBolOpenTable" v-model="selectedItems" … item-key="id" show-select
```

`ViewDtoService.getBolByStatesAndKeyword:1416-1451` builds each row DTO with exactly
`id, number, name, type, state, courier, trackingDeviceId, created, modified, dock, truck, parcels` —
there is **no `key`**. Every row on the Open tab therefore keys on `undefined`, which makes Vuetify's
`show-select` selection tracking unreliable for the **already-live** bulk Close action.

**Deliberate decisions inside Fix F:**

| Decision | Rationale |
|---|---|
| In scope despite a different root cause | It is the selection-reliability precondition for the feature this ticket is about, it is a one-word change in the same screen family, and the same DTO feeds the tab Fix C is wiring. Excluding it would mean shipping reliable multi-select on Closed and leaving it broken on Open. |
| **Stays in this PR, with a Jest test** | **User decision 13** (Architect finding 13). The Architect was right that "same screen family, one word" understates the risk: this changes **selection identity on a bulk-Close path that is live in production today**, and the first draft mitigated it with two manual test rows and no automated test. The chosen resolution is the first of the two options offered — add §8 test **#22** (an Open-tab row built from the real `ViewDtoService` DTO key set resolves `item-key` to a defined, unique value) and keep Fix F in the feature PR. Splitting it into its own PR was rejected: it would add a third PR and a third merge-order edge to a plan that already has a one-directional API→UI coupling, for a change whose risk the test removes. The test ships in the **same commit** as the one-word change (§7.3 Commit 4). |
| `id`, not `number` | `id` is the surrogate key and is what every downstream dispatch on this tab already sends. |
| No API change | The DTO already carries `id` (`ViewDtoService.java:1427`). |

---

## 6. File Change Summary

### `v2/wms2-api`

| File | Fix | Change Type | Description |
|---|---|---|---|
| `controller/BillOfLadingController.java` | A | Modify | Add `MAX_BULK_EXPORT_BOLS = 100`, `public static parseBolIds(Map)`, `private writeExportError(...)` (**`resetBuffer()`**, never `reset()`); rewrite `exportOutboundBol()` so **all** parsing + `findById` happen inside the try; status-differentiated catches (422/404/500) writing real JSON; call `exportOutboundBOLs`. **Adds the `WmsObjectMapper` / `HttpStatus` / `MediaType` / `StandardCharsets` imports** (this controller has none of them today) |
| `service/BillofladingService.java` | B | Modify | Add `exportOutboundBOLs(HttpServletResponse, List<Billoflading>, boolean)`, `private record BolSheetData`, `private buildSheetData(...)`, `private exportBlockReason(...)`, `static uniqueSheetName(...)`. Also adds `SUMMARY_SHEET_NAME` and the leading Summary index sheet for N≥2 (user decision 12). `exportOutboundBOL` keeps its signature and its exact CANCELLED message and delegates row-building to the extracted helper, but **its sheet name changes** from the `"Inbound BOL"` literal to `uniqueSheetName(...)` (user decision 11). **No `@Transactional`** (§12 row 1). Adds `org.apache.poi.ss.util.WorkbookUtil` + `org.apache.poi.ss.usermodel.Workbook` imports |
| `service/FileExportService.java` | — | **No change** | `getExcelFile:138-229` already accumulates sheets and only writes when `stream != null`; `exportExcelFile` already writes+closes once. Verify script asserts it is untouched |
| `test/.../unit/controller/BillOfLadingControllerUnitTest.java` | A | Modify | New `@Nested ExportOutboundBol` class — §8 cases 1-8, 20. The class currently has **zero** export tests (12 `@Nested` classes, none for export) |
| `test/.../unit/service/BillofladingServiceUnitTest.java` | B | Modify | New `@Nested ExportOutboundBOLs` class — §8 cases 9-13, 21, 23-24. Of the existing **10** `ExportOutboundBOL` tests, **7 remain unmodified**; the 3 sheet-name assertions at `:998, :1024, :1060` change `eq("Inbound BOL")` → `eq("BN-100")` (user decision 11) |

### `v2/wms2-web-ui`

| File | Fix | Change Type | Description |
|---|---|---|---|
| `components/outbound/bol/closedOutboundBol.vue` | C | Modify | `show-select` + `v-model="selectedItems"`; bulk action bar; `rowActionItems` / `showRowExportBol` in `data()`; second `exportBolPop` instance; `addToSelectedItems` no longer clobbers the selection; `closeBulkPop` / `closeRowPop` |
| `components/outbound/bol/openOutboundBol.vue` | C4, F | Modify | `item-key="key"` → `item-key="id"`; expand the commented-out Export button's comment with the DB Q2 + `a8af84f` evidence. **Button stays commented out** |
| `components/outbound/bol/popups/exportBolPop.vue` | D1 | Modify | Send `{ ids, fileName, exportDetails }`; empty-selection guard; simplify `getExportList`; drop both `console.log`s; `hidePageSpinner` into `finally` |
| `components/outbound/bol/outboundBolDetails.vue` | D2 | Modify | **Both** `exportBol()` (`:133`) and `closeBol()` (`:137`) assign instead of pushing (§0 row 16, widened after Architect finding 8) |
| `store/outbound/outboundBols.js` | E | Modify | `$post` → `post`; content-type gate before the download; `extractBlobErrorMessage` on failure; `revokeObjectURL` + `link.remove()` in `finally`; drop the mislabelled `console.log` |
| `test/components/outbound/bol/exportBolPop.spec.js` | D1 | **Add** | §8 cases 14-16 |
| `test/components/outbound/bol/closedOutboundBol.spec.js` | C | **Add** | §8 cases 17-18 |
| `test/components/outbound/bol/openOutboundBol.spec.js` | F | **Add** | §8 case 22 — `item-key` resolves to a defined, unique value for DTO-shaped rows (user decision 13; keeps Fix F in this PR) |
| `test/store/outbound/outboundBols.spec.js` | E | **Add** | §8 cases **19a/19b/19c**. No outbound-BOL store spec exists today, so H5's `URL.createObjectURL` stub and H6's `{text: () => …}` error shape must be set up from scratch |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | **N/A** | — | No schema change, no Flyway migration, no seed row. Highest `V2.2.*` untouched. Note the two export queries carry `@RestResource` (HAL-exported), but this plan changes **neither query** — the SBDEV-1666 "service branch cannot guard an exported query" landmine does not apply |
| 2 | **Feature flags / system properties** | **N/A** | — | No sysprop read or added. The change is additive UI surface plus a tolerant API contract; there is no "working" mode today worth gating |
| 3 | **Config / env changes** | **N/A by design** | — | Fix B keeps every per-BOL outcome **in-band**, specifically so no custom response header is needed. `rest.security.cors.exposed-headers` does not exist in `application.properties` (only `:98-101`: `allowed-origin-patterns`, `allowed-headers`, `allowed-methods`, `max-age`) and `SecurityProperties:24` feeds `setExposedHeaders` straight from that absent property — so a header would be invisible to the browser. **This plan requires no CORS or config change**, unlike SBDEV-2632 Fix C |
| 4 | **Deploy-order dependencies** | **API PR must merge and deploy BEFORE the UI PR — and a revert must go in the reverse order** | dev | **Forward:** the UI sends `ids`; against an old API `reqMap.get("id")` is `null` → `((Integer) null).longValue()` → NPE → 500 → generic toast. The reverse (API first, old UI) is safe: Fix A still accepts the legacy scalar `id`. **Revert (promoted here after Architect finding 9 — it was buried in §13 row 8):** once both halves are merged, reverting **only** the API PR restores code whose `((Integer) reqMap.get("id")).longValue()` receives `null` from the UI's `{ids:[…]}` payload ⇒ **every** export 500s, including the single-BOL kebab path that works today. **Reverting the API PR requires reverting the UI PR, or reverting the UI PR first.** State this in **both** PR descriptions, not just this table — a release engineer rolling back at 2am reads the PR, not the plan. **Rejected alternative:** making the UI send `{id}` at length 1 and `{ids}` above would make single-BOL flows revert-safe, but it cannot make the *new feature* work UI-first, and it re-introduces exactly the two-shape payload branching Fix D exists to delete. Architect's ruling and mine agree: **keep API-first** |
| 4a | **Ticket re-classification** | **Post a ClickUp comment on SBDEV-2797 before implementation starts** | dev | The ticket carries `type: Bug` / `priority: normal`, but §1 proves the reported reproduction is **not reachable** on `develop`. A normal-priority bug carries an implicit small-effort, low-blast-radius expectation that 6 fixes across 2 repos, 8 commits, 5 test files and a one-directional deploy coupling violates. The comment must say: (a) SBDEV-2797 **as filed is not reproducible** — the `selectedItems[0]` truncation is latent because no caller can select more than one BOL; (b) this is a **feature build** (bulk BOL export) with the latent-defect fix riding along; (c) the sheet name on the **existing** single-BOL export changes from `Inbound BOL` to the BOL number (user decision 11), which is operator-visible; so whoever schedules it can re-point type/priority/estimate. **The same three points go in both PR descriptions.** Raised by the Architect's steelman: honesty in §1 does not reach the people who consume the *metadata* |
| 5 | **Data migration** | **N/A** | — | Export is read-only; nothing is written |
| 6 | **External systems** | **N/A** | — | No OMS notification, no outbox message, no printer, no Keycloak change on this path |
| 7 | **Access / permissions** | **N/A** | — | `/v3/billOfLading/exportOutboundBol` keeps its existing `SecurityConfiguration` rule; no new role or authority |
| 8 | **Monitoring / alerts** | **None added** | — | Actuator already exposes `metrics` + `prometheus` (`application.properties:88`), so `http.server.requests` gives count/status/latency for this URI without new code. No bespoke counter (§12 row 8). Post-deploy, grep app logs for `export failed unexpectedly` — it should be absent for the bulk path |
| 9 | **Sibling plan coordination** | ✅ **DISCHARGED 2026-08-03 — SBDEV-2632 has MERGED into `develop`** (PR [#119](https://github.com/SiteBossInc/wms2-api/pull/119), merge commit `37bb39e`) | dev | Decision #3 (§10). 2632 establishes the tolerant-parse + `writeExportError` + `extractBlobErrorMessage` conventions this plan reuses, and it is now in the base. **Therefore take the merged branch of this row: `import` 2632's `extractBlobErrorMessage` rather than declaring a second copy** (§5 Fix E) — the "declare it locally + de-duplicate later" fallback is now dead and must not be taken. Read the merged `CycleCountController.parseCycleCountIds` / `writeExportError` and mirror their final shape, which may differ from what 2632's *plan* specified. **Verified the merge does not move this plan's citations:** `BillOfLadingController.java`, `BillofladingService.java`, `FileExportService.java` and both touched test classes are all byte-unchanged by #119. It *did* touch `ViewDtoService.java`, shifting `getBolByStatesAndKeyword` by +6 lines — this plan's citations were corrected accordingly (`:1416-1451`, `id` at `:1428`, `number` at `:1429`); the Fix F evidence itself is unchanged (still 12 keys, still no `key`) |
| 10 | **Baseline the two known `develop` test failures** | `OptionalSafetyArchTest`, `MobilePalletizingServiceTest` fail on clean `develop` (2/4442) | dev | Capture before starting so they are not misattributed. `mvn test` also **mutates the tracked `archunit_store`** — revert it before committing. `mvn`/`java` need the SDKMAN PATH export |

### 7.2 Ordering rationale

Fix A is independently useful and independently revertable: it makes the endpoint stop 500-ing on a
string or missing id and establishes the `ids` contract while still accepting today's payload. Fix B
is the only change that makes a multi-sheet workbook possible. Fix C is the only change that lets an
operator produce a multi-selection — so it must land **last**, after A + B are deployed, or the very
first bulk click hits an API that NPEs. Fix E is grouped with the UI PR because it is the thing that
makes A's new status codes visible to the operator; without it, a 422 still shows the generic toast.

### 7.3 Implementation checklist (atomic commits)

**Repo `v2/wms2-api`** — branch `feature/SBDEV-2797-outbound-bol-bulk-export` off freshly-fetched `origin/develop`:

- [ ] **Commit 1 (Fix A):** `BillOfLadingController` — `MAX_BULK_EXPORT_BOLS`, `parseBolIds`, `writeExportError`, rewritten `exportOutboundBol()` with everything inside the try, status-differentiated catches, new imports. Calls `exportOutboundBOLs` (compiles only once Commit 2 lands — squash-order note: if commits must compile individually, land Commit 2 first).
- [ ] **Commit 2 (Fix B):** `BillofladingService` — `exportOutboundBOLs`, `BolSheetData`, `buildSheetData`, `exportBlockReason`, `uniqueSheetName`; `exportOutboundBOL` delegating and now naming its sheet via the shared `uniqueSheetName`. `git diff` must show **no change** to its signature or the CANCELLED message string; the `"Inbound BOL"` literal is **deliberately deleted** (user decision 11).
- [ ] **Commit 3 (tests):** `BillOfLadingControllerUnitTest` + `BillofladingServiceUnitTest` per §8, **including test #20** (CORS headers survive the error path — the only guard against the `reset()` trap) and **test #11** (empty BOL keeps its sheet — the only guard against regressing `a8af84f`).
- [ ] ⚠️ Both test classes are `@Nested`-structured (`BillOfLadingControllerUnitTest` has 12 `@Nested` classes). **Never** narrow to `-Dtest='BillOfLadingControllerUnitTest#someMethod'` — Surefire **silently no-ops** on `@Nested` classes and reports a **false green**. Always run the bare class name.
- [ ] `mvn clean compile` — catches DI / compile drift the unit tests miss.
- [ ] `mvn test -Dtest=BillofladingServiceUnitTest` → **7 of the 10** pre-existing `ExportOutboundBOL` tests pass **unedited** (the Fix B extraction guardrail); the 3 sheet-name assertions (`:998, :1024, :1060`) are edited to `eq("BN-100")` **in Commit 2, not later** — a test edit in a separate commit reads as a fixup. Then `-Dtest=BillOfLadingControllerUnitTest`, then the full `mvn test`.
- [ ] **Revert the `archunit_store` mutation** `mvn test` writes into the tracked file before committing.
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2797-….sh` → `0 fail` for the API rows.
- [ ] PR into `develop`. **Merge and deploy this PR before the UI PR** (§7.1 row 4).

**Repo `v2/wms2-web-ui`** — branch `feature/SBDEV-2797-outbound-bol-bulk-export` off `origin/develop`:

- [ ] **Commit 4 (Fix F + C4):** `openOutboundBol.vue` — `item-key="id"`, expanded comment on the still-commented-out Export button, **plus `test/components/outbound/bol/openOutboundBol.spec.js`** (§8 test #22). Independently revertable. **The test ships in this commit, not with the other UI specs** — user decision 13 keeps Fix F in-PR specifically because it is tested, so shipping the two apart would recreate the untested-live-path risk the Architect flagged.
- [ ] **Commit 5 (Fix E):** `store/outbound/outboundBols.js` — `post`, content-type gate, `extractBlobErrorMessage`, `finally` cleanup.
- [ ] **Commit 6 (Fix D):** `exportBolPop.vue` → `{ ids, … }`; `outboundBolDetails.vue` → assign-not-push.
- [ ] **Commit 7 (Fix C):** `closedOutboundBol.vue` — `show-select`, `v-model`, bulk bar, `rowActionItems`, second popup instance. **Last**, because it is the commit that makes multi-selection reachable.
- [ ] **Commit 8 (tests):** the three new spec files.
- [ ] `node_modules/.bin/jest --testPathPattern='outbound' ` — **no `yarn` on PATH**; use the nvm node binary.
- [ ] Verify script → `0 fail` with both roots set.
- [ ] PR into `develop`, cross-linked to the API PR, with the merge order stated.

---

## 8. Testing Plan

**H2 / Testcontainers note.** Every new test is a **pure unit test**: `parseBolIds` and
`uniqueSheetName` are static, `BillofladingService` is constructed with mocked repositories and a
mocked `FileExportService`, and the controller test extends the existing `BaseControllerUnitTest`
(standalone MockMvc via `setupMockMvc(controller)`, with a `MockPrincipalArgumentResolver` so
`@AuthenticationPrincipal Principal` resolves). **No H2 and no Testcontainers scope**, so the broken
v2 IT harness (SBDEV-2217) does not block this plan. If any integration test is nonetheless added, it
must be `@Disabled` with a `TODO(SBDEV-2217)`.

### Harness obligations (probe results, not assumptions)

| # | Obligation | Why — measured, not guessed |
|---|---|---|
| **H1** | **`fileExportService` is a `@Mock` in `BillofladingServiceUnitTest`, so no test in that class ever produces xlsx bytes.** Assert sheet names, order, header arrays and row content via `ArgumentCaptor` / `argThat` on `getExcelFile` and `exportExcelFile`. | All 10 existing tests do exactly this — e.g. `verify(fileExportService).exportExcelFile(isNull(), eq("Inbound BOL"), argThat(p -> p != null && p.size() == 11), argThat(h -> h.length == 3), …)` at `:998-1003`. There is no in-class precedent for byte assertions, so the captor approach must be stated rather than invented. |
| **H2** | **Every one of the 10 existing export tests calls `exportOutboundBOL(null, testBol, …)` — a `null` response.** The bulk path must be given a real `MockHttpServletResponse`; copying the `null` convention into `exportOutboundBOLs` NPEs the moment the last-sheet `exportExcelFile` is reached (though with a mocked `FileExportService` it may *appear* to pass — worse). | Verified at `:910, :924, :937, :950, :966, :995, :1021, :1057, :1078, :1092`. |
| **H3** | **Test #11 (empty BOL keeps its sheet) must assert on the `rows` argument being empty AND the `preHeaderRows` argument being the 11-row block** — not merely that no exception was thrown. | The existing `usesClosedQueryWhenClosed` test already passes with an empty result list, so a "does not throw" assertion is vacuous and would not catch a skip-empties regression. This test's whole purpose is to fail if someone adds one. |
| **H4** | **Test #20 must be a direct controller invocation** — `controller.exportOutboundBol(reqMap, response, null)` with a pre-seeded `MockHttpServletResponse` — **not** MockMvc. | MockMvc gives no handle to set response headers before the handler runs, which #20 requires. `MockHttpServletResponse.reset()` clears headers while `resetBuffer()` does not, so the test has real teeth once written this way. |
| **H5** | **The web-ui specs MUST stub `URL.createObjectURL` / `URL.revokeObjectURL`** (`global.URL.createObjectURL = jest.fn(() => 'blob:mock')`) plus a `$moment` stub on `thisArg`. | `jest.config.js` has **no `setupFiles`**; under jsdom `URL.createObjectURL` is **`undefined`**. Without the stub, `export` throws inside its own `try`, the `catch` fires the generic toast, and the "no download on error" test **passes for the wrong reason** — a false green of exactly the kind §9.1 warns about. |
| **H6** | **The error-body test must supply `error.response.data` as `{ text: () => Promise.resolve(json) }`**, not a real `Blob`. | `Blob.prototype.text` is **`undefined`** in the jsdom version this repo pins, so with a real Blob `extractBlobErrorMessage` falls through to the generic message and the test cannot pass. Consequence: the real-browser `Blob.text()` path is never exercised by CI — recorded in §10 C4. |
| **H7** | **Follow the established store-spec call style** — `actions.export.call(thisArg, context, payload)` with `$axios` / `$toast` / `$moment` mocked on `thisArg`. | Precedent to copy: `test/store/internalOps/replenishments.spec.js:29,46,58`. Component precedent: `test/components/processes/clubRuns/clubRunDetails.spec.js`. |
| **H8** | **`CommUtil.showPageSpinner` / `hidePageSpinner` must be stubbed** in the `exportBolPop` spec. | `exportAction` calls both (`:66`, `:73`); unstubbed they touch `this.$store`/DOM state the shallow mount does not provide. |
| **H10** | **Any assertion about a Vuetify table binding MUST read it from the rendered component, never restate it as a literal — and the mount harness has to be built from scratch, because no spec in this repo has ever mounted a `v-data-table`.** Concretely: `shallowMount(OpenOutboundBol, { mocks: { $store, $route, $toast }, stubs: { 'v-data-table': true, … } })`, then `wrapper.find('#outboundBolOpenTable').attributes('item-key')`. With a bare `true` stub the **static** `item-key` and `id` attributes pass straight through to the rendered `<v-data-table-stub>` element, so `attributes()` reads them; `findComponent(...).props('itemKey')` does **not** work here, because that needs a real Vuetify component registration and **no spec in this repo registers Vuetify** — `clubRunDetails.spec.js:26-43` enumerates 13 individual `v-*` stubs precisely because the components are unregistered. **Probed, not assumed:** `grep -rc 'v-data-table' test/` returns **0 matches across all 9 spec files**, so the stub list for `openOutboundBol.vue` / `closedOutboundBol.vue` must be **derived from those two templates** (they use `v-data-table`, `v-pagination`, `v-btn`, `v-icon`, `v-text-field`, `v-card-title`, `v-card-subtitle`, `v-card-text`, `v-menu`, `v-list`, `v-list-item`, `v-divider`, plus `create-bol` / `export-bol-pop`), not copied from `clubRunDetails.spec.js`. | **Critic blocking 4 — this is load-bearing, not hygiene.** A test written as `const itemKey = 'id'; expect(row[itemKey]).toBeDefined()` **can never fail**, which is the exact failure mode that killed revision 1's test #9. And user decision 13 keeps Fix F on a **live bulk-Close path** *because* it is tested — an unfailable test does not discharge that decision, it only appears to. The same read-from-the-render obligation applies to **#17** (the bulk bar's conditional render) and to any later assertion about `show-select` or `v-model`. |
| **H9** | **The workbook-threading tests MUST stub `getExcelFile` to return a mock `Workbook`** — `when(fileExportService.getExcelFile(any(), any(), any(), any(), any(), isNull())).thenReturn(mockWorkbook)` — and then assert that **that same instance** is the first argument of the final `exportExcelFile` call (`verify(fileExportService).exportExcelFile(same(mockWorkbook), …)`). | **Architect finding 2 — the first draft's test #9 was vacuous.** `fileExportService` is a `@Mock`, so an unstubbed `getExcelFile(...)` returns **`null`**; the local `workbook` variable would stay `null` through every iteration and `exportExcelFile(null, …)` would be invoked. An assertion phrased as "called once with the accumulated workbook" therefore **passes against N independent workbooks** — i.e. against Bug 3 unfixed, which is the entire point of Fix B. Instance identity is the only assertion with teeth here, because no test in this class produces bytes (H1). |

### Test scenarios (26)

*1-18 and 20 from the first draft; #9 and #10 rewritten after Architect findings 2 and 6; #1, #2 and #7
restated at the layer that can observe them and #19 split into **19a/19b/19c** after Critic blocking
1-3; 21-24 added by the post-review revisions (the `preHeaderRows == null` invariant, Fix F's Jest
assertion, and the two `Summary`-sheet cases).*

**Three scenarios were corrected for asserting sheet counts at the controller layer, where
`billofladingService` is a `@Mock` and sheets are unobservable — #1, #2 and #7.** Two of those also
carried pre-`Summary` arithmetic. §8 was swept end-to-end for both defects after Critic blocking 1;
#11, #12, #21, #23 and #24 were checked and are correct as written.

| # | Scenario | Steps | Expected Result |
|---|---|---|---|
| 1 | Bulk export, 3 ids — **controller contract only** | `POST /v3/billOfLading/exportOutboundBol` `{"ids":[a,b,c],"exportDetails":true}`, with `billofladingRepository.findById` stubbed for all three | **200**, and an `ArgumentCaptor<List<Billoflading>>` on `billofladingService.exportOutboundBOLs(...)` captures a list of **size 3** whose ids are `[a,b,c]` **in that order**, with `exportDetails == true`. **Deliberately asserts nothing about sheets:** `billofladingService` is a `@Mock` here, so sheet counts and names are unobservable at this layer — #9 and #24 own them. *Corrected twice in review: an earlier draft asserted "3 sheets" at the controller layer (unobservable), and "`getExcelFile` exactly twice" (arithmetically wrong once the `Summary` sheet exists — the correct count is 3).* |
| 2 | Legacy scalar back-compat — **controller contract only** | `{"id":123,"exportDetails":true}`, `findById(123)` stubbed | **200**, and the captor receives a **single-element** list containing that BOL. The single-sheet / no-`Summary` output facts belong to **#24**, which can see them |
| 3 | `id` as a JSON string | `{"id":"123"}`, **with `findById(123L)` stubbed to return a BOL** | **200**, **not 500** — today this is a `ClassCastException` at `:270`. ⚠️ Without the stub this returns **404** (Fix A now catches `EntityNotFoundException` locally), so the test would pass for the wrong reason and stop proving the coercion works |
| 4 | Bad token among ids | `{"ids":["1","abc"]}` | **422** with a JSON body naming `abc`; **not 500** |
| 5 | Missing / empty selection | `{}`, `{"id":""}`, `{"ids":[]}` | **422**, not 500 — today `((Integer) null).longValue()` NPEs |
| 6 | Unknown id | `{"ids":[999999999]}` | **404** + JSON `BillOfLading not found with id: 999999999` |
| 7 | Duplicate ids — **controller contract only** | `{"ids":[a,a,b]}`, `findById` stubbed for `a` and `b` | The captor receives a list of **size 2** with ids `[a,b]`, and `findById(a)` is invoked **once**. *Third instance of the same class as #1/#2, found by sweeping §8 after Critic blocking 1: the earlier wording said "2 **sheets**", which is both unobservable at this layer and wrong post-`Summary` (2 BOLs ⇒ 3 sheets).* |
| 8 | Over the cap | `{"ids":[…101 ids…]}` | **422** naming the count and the maximum; **exactly 100 succeeds** |
| 9 | **Service: 3 BOLs → Summary + 3 sheets, threaded through ONE workbook, written once** | `exportOutboundBOLs(response, List.of(bolB, bolA, bolC), true)` with `getExcelFile` stubbed per **H9** | `getExcelFile` called **exactly 3×** — `Summary`, then B, then A — and `exportExcelFile` called **exactly once** for C, with `same(mockWorkbook)` as its first argument and the real `response` as its last. ⚠️ **`[Summary, B, A, C]` is the *combined* sequence across BOTH methods, not one captor.** Use an `ArgumentCaptor<String>` on `getExcelFile` (expect `[Summary, B, A]`) and a separate `ArgumentCaptor<String>` on `exportExcelFile` (expect `[C]`); a single captor over `getExcelFile` can never see `C`, which makes the assertion unwritable as an earlier draft specified it. **Without H9's stub the `same(mockWorkbook)` half is vacuous** — see H9. *Counts corrected in review: an earlier draft said 4 `getExcelFile` calls while listing 3.* |
| 10 | **Sheet-name safety, including the collision sanitisation *creates*** | three BOLs numbered **`"OBOL/1"`**, **`"OBOL 1"`** and a 40-char number | `WorkbookUtil.createSafeSheetName` maps the illegal `/` to a **space**, so `"OBOL/1"` and `"OBOL 1"` both collapse to the base `"OBOL 1"` — the second must be suffixed `"OBOL 1_2"`. The 40-char number truncates to ≤31. **No `IllegalArgumentException`.** *Corrected after review: the first draft asserted two BOLs with the **same** number, which Q4 proves impossible (2835/2835 distinct) and which misses the only case where sanitisation manufactures a duplicate* |
| 11 | **Empty BOL keeps its sheet** | a CLOSED BOL whose `getClosedBOLSkuAmountDetail` returns `[]`, among two others, `exportDetails=true` | Its sheet **exists**, `rows` argument is **empty**, `preHeaderRows` argument has **11** rows. **Locks in `a8af84f`** — must fail if anyone adds a skip-empties path (see H3) |
| 12 | CANCELLED among valid ids | `exportOutboundBOLs(response, List.of(closedBol, cancelledBol), true)` | Workbook **still produced**, `Summary` + 2 sheets; the cancelled BOL's sheet has a `NOTE` pre-header row containing `Can not export from an cancelled outbound BOL` and **zero** data rows; **its `Summary` row carries the same reason in the `Note` column and `0` in `SKU Rows`**; **no `BusinessException`** escapes |
| 13 | Single CANCELLED still fails | `exportOutboundBOLs(response, List.of(cancelledBol), true)` | `BusinessException` with the **unchanged** message (delegates to `exportOutboundBOL`) ⇒ Fix A renders **422** |
| 14 | **Pop sends every selected id** | `exportBolPop` with 3 selected → invoke `exportAction` | `$store.dispatch` called **once** with `ids.length === 3`, `fileName: 'BOL_Export_Multiple'`. **The ticket's literal regression test** |
| 15 | Pop, one selected | 1 selected | `ids.length === 1`, `fileName: 'BOL_Export'` |
| 16 | Pop, zero selected | `selectedItems: []` | **No dispatch**; `closePop` emitted |
| 17 | Closed tab renders the bulk bar conditionally | Mount per **H10** (`closedOutboundBol.vue` needs its own derived stub list); set `selectedItems: []`, assert, then `setData({selectedItems:[a,b]})` and assert again | Bar **absent**, then **present** showing "2 items selected." **Read from the render** — `wrapper.find(...)`/`wrapper.text()`, never an assertion on `vm.selectedItems.length` alone, which would restate the input rather than test the template (H10) |
| 18 | Per-row export does not clear the checkbox selection | `selectedItems = [a,b]`, then `addToSelectedItems(c,'export')` | `selectedItems` still `[a,b]`; `rowActionItems === [c]`; the row dialog opens |
| **19a** | **Store: a 200 carrying a JSON error body → toast, and NO download.** *This is the only Fix E scenario that can fail against Bug 4* | mock a **resolved** response with `status: 200`, `headers: {'content-type': 'application/json'}` and an error-JSON body | `$toast.error` shows the server message; `URL.createObjectURL` (the H5 stub) is **not** called; `link.click()` is **not** called. **Pre-fix both assertions fail:** `link.click()` at `:324` runs unconditionally before the check at `:325`, and `result.errors` on a `Blob` is `undefined` so no toast fires. **Critic blocking 3:** this shape is not hypothetical — it is exactly today's server behaviour, since `errors.toString()` at `:280`/`:289` never sets a status, so the response is a **200** carrying an error body |
| 19b | Store: a 422 whose blob body is JSON → **server** message, not the generic one | mock a rejection with `error.response.data` supplied per **H6** as `{ text: () => Promise.resolve(json) }` | `$toast.error` shows **that** message; no download. **Pre-fix only the message half fails** (a 422 makes `$axios.$post` reject, so the existing `catch` already fires the *generic* toast and never clicks) — see §9.2 step 1 |
| 19c | Store: network failure → generic toast | reject with no `error.response` | Generic "network or server issue" toast. **Passes pre-fix by design** — the fallback is deliberately retained, so this is a no-regression guard, not a fix assertion |
| **20** | **Error path must not clear CORS headers** | pre-seed a `MockHttpServletResponse` with `Access-Control-Allow-Origin: https://wms.example`, then drive `exportOutboundBol` down the 422 path (`{"ids":["abc"]}`) | The header **survives** on the 422. The only guard against the `reset()`/`resetBuffer()` trap — **no MockMvc test can catch it** (no `CorsFilter`), and the failure is invisible until a real browser hits a real origin |
| **21** | **`preHeaderRows` stays `null`, never an empty list — and the CANCELLED branch is the one deliberate exception** | `exportOutboundBOLs(response, List.of(bolA, bolB, cancelledBol), **false**)` — note the **blocked** BOL, added per Critic non-blocking 6 | For the two **exportable** BOLs the captured `preHeaderRows` is `null`, not `List.of()`. **Architect §7.1:** `exportsWithoutDetails` (`@Test :1005`) already asserts `isNull()` at `:1025` for the single path, and `FileExportService` branches on `preHeaderRows != null` to compute the row offset — so an "empty list is tidier" refactor would silently shift every row down one. For the **blocked** BOL the captured `preHeaderRows` is the **2-row NOTE block even at `exportDetails == false`** — an intentional asymmetry (a blocked sheet must carry its reason regardless of the detail flag, and it has no data rows for the offset to disturb; `FileExportService:153` shifts only that sheet). Asserting both halves in one test is what stops a future reader "harmonising" the asymmetry away |
| **22** | **Open-tab `item-key` resolves to a defined, unique value** (Fix F) | Mount per **H10**. Build 3 row objects with the **exact** `ViewDtoService.getBolByStatesAndKeyword` key set (`id, number, name, type, state, courier, trackingDeviceId, created, modified, dock, truck, parcels` — no `key`). Then **read the binding out of the render**: `const itemKey = wrapper.find('#outboundBolOpenTable').attributes('item-key')` | `itemKey === 'id'`; every row resolves `row[itemKey]` to a **defined** value; the 3 resolved values are **distinct**. **Pre-fix this fails on all three** — the rendered attribute is `key`, so `row[itemKey]` is `undefined` for every row. ⚠️ **H10 is mandatory here:** hardcoding `const itemKey = 'id'` makes the test unfailable, and since user decision 13 keeps Fix F in the feature PR *because* it is tested, an unfailable version silently un-does that decision |
| **23** | **Summary sheet is tab 1 and its counts are the data sheets' own numbers** | `exportOutboundBOLs(response, List.of(bolA, bolB), true)` where A has 3 SKU rows and B has 0 | The **first** `getExcelFile` call is for `"Summary"` with headers `{Sheet, BOL ID, BOL Name, Shipped, Courier, SKU Rows, Note}`; its captured rows are `[[…A…, 3, ""], […B…, 0, ""]]`, and each `SKU Rows` value equals the `rows.size()` captured for that BOL's own sheet. **Plus — this is what gives the "same numbers" claim teeth —** `verify(billofladingPositionRepository, times(1)).getClosedBOLSkuAmountDetail(id)` **per BOL**. *Critic §3: comparing two captured values cannot distinguish "the same numbers" from "separately derived but equal"; only the query count can. A second query set is exactly the implementation this test exists to reject, because under concurrent truck loading it could disagree with the data sheets (no transaction spans them — §11 row 4).* |
| **24** | **No Summary sheet at N = 1** | `exportOutboundBOLs(response, List.of(bolA), true)` | `getExcelFile` is **never** called; `exportExcelFile` is called once with `isNull()` as the workbook and the BOL's number as the sheet name. Pins the N=1 suppression decision (§10 decision 12) so a later "make it uniform" change is a visible test edit |

Procedural checks (not test methods): **7 of the 10** existing `ExportOutboundBOL` tests are unedited and pass, and the 3 edited ones differ **only** in the `eq(...)` sheet-name argument (`git diff` on `:998, :1024, :1060` shows one changed token each);
`FileExportService.java` has zero diff hunks; targeted suites are BUILD SUCCESS.

### New / updated tests

| Test class | Test method | Asserts |
|---|---|---|
| `BillOfLadingControllerUnitTest$ExportOutboundBol` | `exportOutboundBol_withIdsArray_exportsAllSelectedInOrder` | #1 — service receives all three `Billoflading`s in order |
| " | `exportOutboundBol_withLegacyScalarId_stillExportsSingleBol` | #2 |
| " | `exportOutboundBol_withStringId_returns200NotServerError` | #3 |
| " | `exportOutboundBol_withNonNumericToken_returns422NamingIt` | #4 |
| " | `exportOutboundBol_withMissingSelection_returns422` | #5 |
| " | `exportOutboundBol_withUnknownId_returns404WithMessage` | #6 |
| " | `parseBolIds_dedupesTrimsAndPreservesOrder` | #7 (direct static-helper test) |
| " | `parseBolIds_overCap_throwsBusinessExceptionNamingTheMaximum` | #8 |
| " | `exportOutboundBol_onError_preservesPreExistingCorsHeaders` | **#20** — `resetBuffer()` semantics |
| `BillofladingServiceUnitTest$ExportOutboundBOLs` | `exportOutboundBOLs_withThreeBols_threadsOneWorkbookThroughAllSheetsAndWritesOnce` | **#9** — requires the H9 stub; asserts `same(mockWorkbook)` |
| " | `exportOutboundBOLs_sanitisesTruncatesAndDeduplicatesSheetNames` | #10 |
| " | `exportOutboundBOLs_withPositionlessBol_keepsItsSheetWithSignatureBlockAndZeroRows` | **#11** — the `a8af84f` guard |
| " | `exportOutboundBOLs_withCancelledBolAmongValid_recordsNoteRowAndStillProducesWorkbook` | #12 |
| " | `exportOutboundBOLs_withSingleCancelledBol_throwsUnchangedBusinessException` | #13 |
| " | `exportOutboundBOLs_withoutDetails_passesNullPreHeaderRowsNotEmptyList` | **#21** — the extraction invariant the Architect flagged |
| " | `exportOutboundBOLs_summarySheetIsFirstAndRowCountsMatchDataSheets` | **#23** |
| " | `exportOutboundBOLs_withSingleBol_emitsNoSummarySheet` | **#24** |
| `test/components/outbound/bol/openOutboundBol.spec.js` (**new**) | `itemKey_resolvesToDefinedUniqueValueForDtoShapedRows` | **#22** — Fix F, per user decision 13 |
| `test/components/outbound/bol/exportBolPop.spec.js` (**new**) | `exportAction_withThreeSelected_dispatchesAllThreeIds` | **#14** |
| " | `exportAction_withOneSelected_dispatchesSingleIdAndDefaultFileName` | #15 |
| " | `exportAction_withNothingSelected_doesNotDispatch` | #16 |
| `test/components/outbound/bol/closedOutboundBol.spec.js` (**new**) | `bulkBar_rendersOnlyWhenSelectionNonEmpty` | #17 |
| " | `addToSelectedItems_doesNotClearCheckboxSelection` | **#18** |
| `test/store/outbound/outboundBols.spec.js` (**new**) | `export_with200JsonErrorBody_doesNotDownloadAndShowsServerMessage` | **#19a** — the only Fix E method that fails against Bug 4's ordering defect |
| " | `export_with422JsonErrorBlob_showsServerMessageNotGeneric` | #19b |
| " | `export_withNetworkError_showsGenericToast` | #19c |

### Test commands

```bash
# wms2-api  (SDKMAN PATH needed: export PATH="$HOME/.sdkman/candidates/maven/current/bin:$PATH")
mvn clean compile
mvn test -Dtest=BillofladingServiceUnitTest      # bare class name — NEVER Class#method (@Nested)
mvn test -Dtest=BillOfLadingControllerUnitTest
mvn test                                          # full suite before the PR leaves the branch
git checkout -- src/test/resources/archunit_store # mvn test MUTATES this tracked file

# wms2-web-ui  (no yarn on PATH; use the nvm node binary)
node_modules/.bin/jest --testPathPattern='outbound'
```

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Bulk export, 3 closed BOLs | dev (wineco) | Outbound → Outbound BOL → **Closed** → tick 3 rows → **Export BOLs** → **Export File** | One `BOL_Export_Multiple_<ts>.xlsx` with a leading **`Summary`** tab plus **3 sheets** named `OBOL……`, in the order ticked, each with its 11-row pre-header + 3 signature lines | |
| **`Summary` sheet is usable, not just present** | dev (wineco) | From the export above, open tab 1 | 7 columns (`Sheet, BOL ID, BOL Name, Shipped, Courier, SKU Rows, Note`), one row per selected BOL, and each `SKU Rows` value equals that BOL's own sheet's data-row count. Include at least one of the 218 zero-row closed BOLs so `SKU Rows = 0` is visible — this is the reconciliation view user decision 12 exists for | |
| Single BOL via kebab (**changed behaviour**) | dev (wineco) | Closed tab → row kebab → **Export BOL** | `BOL_Export_<ts>.xlsx`, **one** sheet now named `OBOL……` (**was** `Inbound BOL` — user decision 11), **no** `Summary` sheet, and columns + 11-row pre-header exactly as before. This is the one operator-visible regression-shaped change in the plan; it is what §14 item 6's communication covers | |
| Single BOL via one checkbox | dev (wineco) | Tick exactly one row → Export BOLs → Export File | Same single-BOL shape as the kebab path (`size()==1` delegates) | |
| **Kebab does not clear a checkbox selection** | dev (wineco) | Tick 2 rows, then open a *third* row's kebab → Export BOL → Cancel | The 2 ticks are **still checked**; the bulk bar still reads "2 items selected." | |
| Empty-export BOL keeps its sheet | dev (wineco) | Pick a closed BOL from the 218 with zero export rows (SQL below), tick it with 2 normal ones → Export | 3 sheets; the empty one has its pre-header + signature block and **no** SKU rows. **Not skipped** | |
| Select-all on a full page | dev (wineco) | Set rows-per-page to **100** → header checkbox → Export BOLs → Export File | Completes, 100 sheets, **no 422**. This is the cap boundary (§5 Fix A) | |
| Over the cap (contract check) | dev | `curl` the endpoint with 101 ids | **422**, JSON body naming 101 and the maximum of 100; no file | |
| Bad id surfaces a real message | dev | `curl` with `{"ids":["abc"]}` from the browser origin (devtools → fetch) | **422**, and the UI toast shows *"Invalid outbound BOL id: abc"* — **not** the generic network toast. Proves `resetBuffer()` kept the CORS headers | |
| Detail-page export (regression) | dev (wineco) | Open a closed BOL's details → Export → Cancel → Export again | Confirm sentence names the BOL **once**, not twice (§0 row 16) | |
| Open tab unchanged | dev (wineco) | Open tab → tick 2 rows | Bulk bar shows **Close Outbound BOLs** only; **no** Export button. Bulk Close still works (proves Fix F did not break selection) | |
| Bulk close still works (untouched path) | dev (wineco) | Open tab → tick 2 → Close Outbound BOLs → confirm | Both close; success toast — proves §0 row 13 was not disturbed | |
| SQL-level sanity | dev DB | `SELECT b.number, count(DISTINCT i.id) FROM billoflading b JOIN billoflading_position bp ON bp.billoflading_id=b.id JOIN itemdata i ON i.id=bp.itemdata_id WHERE b.id IN (…) GROUP BY b.number;` | Per-BOL counts match each sheet's data-row count; the 218 zero-row BOLs are absent from this result and show empty sheets | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Testcontainers / H2 integration test | No SQL, JPQL, or schema change; every path is unit-testable with mocked repositories. Also avoids the broken v2 IT harness (SBDEV-2217) |
| Byte-level xlsx assertions | `fileExportService` is a `@Mock` in `BillofladingServiceUnitTest`, so no test there produces bytes; and POI embeds `docProps/core.xml dcterms:created`, making byte comparison impossible anyway. `ArgumentCaptor` on sheet names / headers / rows is the assertion surface (H1) |
| The real-browser `Blob.text()` path | jsdom does not implement it (H6); the manual test row "Bad id surfaces a real message" covers it end-to-end |
| Cypress e2e | The e2e lane is not part of this repo's PR gate; the manual click-path table covers it |
| v1 (`v1/wms-web-ui`) | Decision #2 (§10); paired ticket in §14 item 1 |
| The Open tab's bulk export | Decision #4 — 0/316 OPEN BOLs are exportable (Q2); the button stays commented out |
| A Micrometer counter | §12 row 8 — `http.server.requests` already covers it |

---

## 9. Risks & Mitigations, and Acceptance

### 9.1 Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **UI PR deploys before the API PR** ⇒ every bulk export 500s and the operator sees the generic toast | Medium (two repos, two pipelines) | **High** — the feature appears broken on arrival | §7.1 row 4 + §7.2: API merges and deploys first, stated in **both** PR descriptions; Fix A still accepts the legacy scalar so API-first is safe in the other direction |
| **API PR reverted alone after both halves merge** ⇒ the UI's `{ids:[…]}` payload hits restored code whose `((Integer) reqMap.get("id")).longValue()` receives `null` ⇒ **every** export 500s, including the single-BOL kebab path that works today | Low | **High** — worse than the pre-fix state, because it breaks a path that currently works | Promoted out of §13 into **§7.1 row 4** and into **both PR descriptions** after Architect finding 9 — a release engineer rolling back reads the PR, not the plan. **Revert the UI PR first, or revert both together.** The UI-first-safe alternative (send `{id}` at length 1, `{ids}` above) was considered and rejected: it cannot make the new feature work UI-first and it re-introduces the two-shape branching Fix D exists to delete |
| **Operators' saved imports / macros keyed on the `Inbound BOL` tab name break** (AC2) | Low-Medium — unknown how many exist | Medium | Accepted consequence of user decision 11, not a defect. Priced with communication rather than code: §7.1 row 4a's ClickUp comment, both PR descriptions, §14 item 6(b)'s release note, and §8's manual row flagging it as **changed behaviour**. The mislabel was on an *outbound* export, so anything keyed to it was keyed to a bug |
| **Two-pass build holds all N row payloads alive** before POI assembly (needed so the `Summary` counts match the data sheets) | Certain (by design) | Low | Quantified in §5 Fix B: ≈7 MB at the cap's worst observed case (49,300 rows × ~150 bytes), against tens of MB of `XSSFCell` objects for the same data — a single-digit-percent addition to peak heap, not the doubling the shape suggests. The single-pass alternative would force the service to own the final `workbook.write(...)`, forfeiting the "no `FileExportService` change" property |
| **`response.reset()` used instead of `resetBuffer()`**, stripping the CORS headers Spring Security already wrote ⇒ browser blocks every 422/404/500 and the fix looks like it did not work | **Was High — caught in design** | **High** | §5 Fix A mandates `resetBuffer()` with the reasoning inline; **test #20**; verify POSITIVE `resetBuffer` + NEGATIVE `no reset()` rows. Flagged because **no MockMvc test catches it incidentally** |
| **Someone "fixes" the empty-sheet behaviour**, undoing `a8af84f` | Medium — it *looks* like a bug | Medium | §3 documents the intent with the commit message; **test #11** asserts the sheet exists with zero rows and an 11-row pre-header (H3 explains why a "does not throw" assertion would be vacuous); manual row "Empty-export BOL keeps its sheet" |
| **Fix B's extraction changes single-BOL output beyond the one intended change** | Low | Medium — 2,516 closed BOLs' documents | The single-BOL sheet **name** changes deliberately (user decision 11); **nothing else may.** 7 of the 10 existing tests must pass **unedited** (pinning `preHeaders.size()==11`, `headers.length==3`, the query branch and the CANCELLED message), and the 3 edited ones must differ only in the `eq(...)` argument. Verify rows assert the legacy signature and the CANCELLED message string survive, plus §8 test #21 pins the `preHeaderRows == null` invariant the Architect flagged |
| **Heap on a 100-BOL export** — POI XSSF builds the whole workbook in memory | Low | Medium (a replica OOM) | Cap of 100 (Fix A); sizing from DB Q3 (≤49,300 rows × 3 cols worst observed); no transaction held; SXSSF streaming rejected with a concrete reason (the `((XSSFWorkbook) workbook)` casts at `FileExportService:94` **and** `:187`). Manual row "Select-all on a full page" bounds it empirically before release |
| Cap of 100 turns out to be too low for a tenant whose page size is configured higher | Low | Low | `rowsPerPageItems` is hard-coded in `outboundBols.js:12` with no "All" option, so 100 is a UI-enforced ceiling. If it ever changes, `MAX_BULK_EXPORT_BOLS` must move with it — the constant's javadoc says so |
| 100 native queries per bulk request lengthen connection borrow/return churn | Medium | Low | No transaction wraps them, so each query borrows and returns immediately; §11 row 2 does the pool math |
| **A CANCELLED note row is mistaken for data** by a downstream spreadsheet macro | Low | Low | The note lives in the **pre-header** block, above the header row, exactly where `getRow(...)` metadata already lives; the data region is empty. Consequence AC3 (§10) states it |
| `catch (Exception) → 500 + JSON` masks a genuine bug as "handled" | Low | Low | Status stays **500** for unexpected types and `LOG.error(..., e)` keeps the stack trace, so monitoring is unaffected |
| Response already committed when an error must be reported | Very Low | Low | `isCommitted()` guard. **But the bulk path widens the window**: with N sheets, `exportExcelFile` opens the stream on the **last** sheet, so a failure during sheet N's row building happens *before* any byte — while a POI failure inside `workbook.write` happens after. Residual truncated-download window recorded as AC4 (§10) |
| `extractBlobErrorMessage` declared twice (here and by SBDEV-2632) | Medium | Low | §7.1 row 9: import 2632's if it has landed; otherwise declare locally and record the de-dup as §14 item 7 |
| `mvn test` mutates the tracked `archunit_store` and it gets committed | Medium | Low | Explicit checklist step in §7.3 |
| The 2 pre-existing `develop` failures (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) misattributed to this change | Medium | Low | §7.1 row 10 baselines them first; note in the PR that both reproduce on clean `develop` |
| Fix F changes `item-key` on a **live** bulk-Close screen | Low | Medium | `id` is present in the DTO (`ViewDtoService:1427`) and is what every dispatch on that tab already sends; manual rows "Open tab unchanged" + "Bulk close still works" gate it |

### 9.2 Acceptance script

**Path:** `sbdocs/9-System/scripts/verify-SBDEV-2797-outbound-bol-bulk-export-first-only.sh`

Copy `sbdocs/9-System/templates/verify-plan-template.sh`. Two roots: `PROJECT_ROOT` = wms2-api,
`UI_ROOT` = wms2-web-ui; UI rows **SKIP** rather than FAIL when `UI_ROOT` is absent so the script is
usable from an api-only worktree. Ends in `Result: N pass, M fail, S skip`; exit 0 only when `M = 0`.

**Mandatory template repair before writing any check.** The template's multi-line helpers use
`perl -0777 -ne`, which **exits 0 when it cannot open the file** — so every multi-line assertion about
a **new** file (all three UI spec files here) would false-green. **Add `[ -f "$2" ] || return 1` as the
first statement of every helper**, including the single-line `file_contains` / `file_not_contains`.
Also: interpolating a pattern containing `/` into `m/…/` terminates the match early and false-**reds**
— pass patterns through the environment (`VERIFY_PAT="$1" perl -0777 -ne '… $ENV{VERIFY_PAT} …'`).
Copy the six repaired helpers verbatim from
`verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh:73-135` (`file_contains`,
`file_not_contains`, `file_count_eq`, `file_contains_ml`, `file_not_contains_ml`, `java_method`) rather
than re-deriving them.

**Scope negatives with the `java_method` helper, not a `.{0,N}?` character window.** SBDEV-2632's §9.1
records a false-red caused by exactly that: the mandated comment block pushed `resetBuffer()` 793
characters past its anchor, blowing a `{0,700}` window on correct code. Character windows are a
function of comment length; method scoping is not.

**The committed script is the authoritative list of check ids** — run `grep -n '^run' <script>` for the
exact set. The grouping below is deliberately id-light so it cannot drift.

| Fix | POSITIVE rows assert | NEGATIVE rows assert |
|---|---|---|
| **A** (controller) | `parseBolIds` exists and is `public static`; reads **both** `ids` and `id` inside the helper; trims; bad token → `BusinessException`; `MAX_BULK_EXPORT_BOLS = 100` declared and enforced; `writeExportError` exists, sets a status, sets JSON content type, uses **`resetBuffer()`**, emits the fixed 5xx string, has the `isCommitted()` guard; `exportOutboundBOLs` is called; `WmsObjectMapper` imported | `((Integer) reqMap.get("id")).longValue()` is gone **from `exportOutboundBol` only** — ⚠️ `java_method`-scoped, **never** whole-file: §0 row 18 shows `setDestinationFacility:185` legitimately keeps the identical construct, so a whole-file check can never pass. Also: no `orElseThrow` before the `try` (method-scoped); **`response.reset()` is not used anywhere** (whole-file is correct here — `grep -c 'response.reset()'` on `develop` is 0); `exportOutboundBol` no longer writes `errors.toString()` — both of the file's 2 occurrences (`:280`, `:289` — `:283`/`:292` are the `LOG.error(e2.getMessage())` lines) are inside this method, so whole-file would also work here, but keep it method-scoped so a future endpoint adopting the pattern cannot silently break the row |
| **B** (service) | `exportOutboundBOLs(HttpServletResponse, List<Billoflading>, boolean)` declared; `getExcelFile(` accumulation call present; `exportExcelFile(` present exactly for the final sheet; `uniqueSheetName` + `WorkbookUtil.createSafeSheetName`; `exportBlockReason`; `buildSheetData`; `size() == 1` delegation; `SUMMARY_SHEET_NAME` declared **and** `usedSheetNames.add(SUMMARY_SHEET_NAME)` seeding present; the 7-element summary header array; **`exportOutboundBOL` calls `uniqueSheetName`** (user decision 11); legacy `exportOutboundBOL` signature intact; the CANCELLED message string intact | ⚠️ **Two separate rows, never one whole-file check** (Architect finding 5): (i) `java_method`-scoped "no `@Transactional`" over `exportOutboundBOL` **and** `exportOutboundBOLs`, and (ii) a class-**declaration-line** check. A whole-file `@Transactional` negative can **never** pass — `BillofladingService.java` legitimately carries it at `:218, :285, :295, :752, :1025` (`finishTransfer` among them). Same trap §0 row 18 documents for Fix A. Plus: the **`"Inbound BOL"` literal is GONE** (this flipped from a POSITIVE to a NEGATIVE under user decision 11 — do not carry the old row forward); no skip-empties construct (`isEmpty()` → `continue`) inside the loop; `FileExportService.java` unchanged (git-diff row) |
| **C** (closed tab) | `show-select` present; `v-model="selectedItems"` present; the bulk bar's `Export BOLs` button present; `rowActionItems` declared and used by `addToSelectedItems`; the Open-tab comment cites both `a8af84f` and the 0/316 evidence | `addToSelectedItems` no longer contains `this.selectedItems = []` (method-scoped); the Open tab's `Export BOLs` `v-btn` is **still inside an HTML comment** |
| **D** (popup + detail) | `exportBolPop.vue` dispatches an `ids` array; empty-selection guard present; `BOL_Export_Multiple`; `outboundBolDetails.vue` assigns rather than pushes | `exportBolPop.vue` must **NOT** contain `selectedItems[0]`; must **NOT** contain `console.log` |
| **E** (store) | `$axios.post` (not `$post`) in the `export` action; content-type gate before `createObjectURL`; `extractBlobErrorMessage` used; `revokeObjectURL` **and** `link.remove()` present | the dead `if (result.errors)` guard gone from the `export` action; `$axios.$post` gone from the `export` action (**action-scoped** via `awk '/async export\(/,/^  \},/'` — other actions in this file legitimately use `$post`) |
| **F** | `item-key="id"` in `openOutboundBol.vue`; **`test/components/outbound/bol/openOutboundBol.spec.js` exists** (user decision 13 — Fix F stays in-PR only because it is tested) | `item-key="key"` **absent** from `openOutboundBol.vue` |
| **tests** | the two Java test classes contain the new `@Nested` class names; the three new UI spec files exist and reference `ids` / `rowActionItems` / `createObjectURL`; targeted `mvn` / `jest` suites pass | — |

**Negative-test the script in BOTH directions before trusting it.** A `N pass, 0 fail` proves nothing:
SBDEV-2736 scored **57 pass, 0 fail** on a build that still contained the defect its ticket was written
to catch.

1. **Pre-fix baseline** — run against real `develop`. **Every** fix row must FAIL. Record the exact
   `Result:` line in §14. Any fix row that PASSES pre-fix is either vacuous or mis-scoped — the two
   likeliest here are a whole-file `reqMap.get("ids")` check (`closeOutboundBols` already uses `ids`
   nearby) and a whole-file `$axios.post` check (other actions in `outboundBols.js` already use it).
   **Both must be method/action-scoped.** A third instance was found in review: a whole-file
   `@Transactional` negative on `BillofladingService.java` can never pass, because that file
   legitimately carries the annotation at `:218, :285, :295, :752, :1025` — so it is split into a
   `java_method`-scoped row plus a class-declaration-line row (Architect finding 5). Rows that are
   legitimately invariant (`B-legacy-sig`, `B-legacy-cancel-msg`, `B-no-tx-method`, `B-no-tx-class`,
   `A-no-reset`, `E-fallback`, `C-open-still-commented`, `B-fileexport-unchanged`) will pass pre-fix by
   design — enumerate them explicitly so the baseline is auditable. **`B-legacy-sheetname` is NOT on
   that list any more:** under user decision 11 the `"Inbound BOL"` literal must be *gone*, so it is a
   fix row that must FAIL pre-fix.

   **The same enumeration is required for the three Fix E test scenarios, because they do NOT share a
   pre-fix verdict** and a reviewer who expects all three to fail will read a correct baseline as a
   broken one:

   | Scenario | Pre-fix verdict | Why |
   |---|---|---|
   | **#19a** (200 + `content-type: application/json` error body) | **FAILS — both halves** | The only shape that exercises Bug 4's ordering defect. Pre-fix `link.click()` at `:324` runs before the check at `:325`, and `result.errors` on a `Blob` is `undefined`, so the file downloads and no toast fires. **This is the Fix E regression test**; if it passes pre-fix, the test is wrong, not the code |
   | **#19b** (422 with a JSON blob body) | **Half-fails** — the message assertion fails, the no-download assertion **passes** | A 422 makes `$axios.$post` reject, so the pre-fix `catch` already prevents the download; only the *generic-vs-server* message is new contract |
   | **#19c** (network failure, no `error.response`) | **PASSES** — by design | The generic fallback is deliberately retained (§5 Fix E). This is a no-regression guard, not a fix assertion. A pre-fix pass here is **correct** and must not be recorded as a gap |

   Record all three verdicts in the baseline note alongside the invariant verify rows, for the same
   reason: an unexplained pre-fix pass is indistinguishable from a vacuous assertion, and this plan has
   already had four of those caught in review.
2. **Post-fix** — run against a synthetic tree built from §5's After-code **including the mandated
   comment blocks** (that is what caught 2632's false-red). Target `0 fail`.
3. **Counter-test A** — substitute `reset()` for `resetBuffer()`: the `resetBuffer` POSITIVE **and** the
   `no reset()` NEGATIVE must both FAIL.
4. **Counter-test B** — add a skip-empties `continue` to the Fix B loop: the `B-no-skip-empties` row
   must FAIL. Without this, the row that protects `a8af84f` is unproven.
5. **Counter-test C** — restore the `"Inbound BOL"` literal in `exportOutboundBOL`: the
   `B-no-inbound-literal` NEGATIVE **and** the `B-legacy-calls-uniquesheetname` POSITIVE must both
   FAIL. This is the row pair that enforces user decision 11, and it is the one most likely to be
   "helpfully" reverted by someone who reads the literal as intentional.
6. **Counter-test D** — drop the `usedSheetNames.add(SUMMARY_SHEET_NAME)` seeding line: the
   `B-summary-seeded` row must FAIL. Cheap, and it guards the one line whose absence only manifests
   as a POI `IllegalArgumentException` on data that does not exist yet.

### 9.3 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard-plus | 6 fixes across 1 controller + 1 service + 5 UI files + 5 test files, two repos, with a real deploy-order coupling |
| **Pre-draft step** | analyst + planner (this doc) + ralplan consensus | New feature surface with a user-visible behaviour shift and a contract change |
| **Plan-review step** | critic | Required for Standard+; specifically to attack the cap, the `@Transactional` stance, and the Fix B extraction |
| **Implementation shape** | ralph (verify script as the exit gate) | 8 commits across 2 repos; the pre-fix baseline will show >6 failing rows |
| **Verification step** | verify-script + verifier | Mandatory; two-root invocation, and remember `PROJECT_ROOT` must point at a symlink shadow root so the script grades the worktree, not the main checkout |
| **Code-review step** | code-reviewer | Error-response contract change + a shared-service signature addition + an extraction of a live method's body |
| **Commit step** | git-master | 8 atomic commits across 2 repos, ordered so Fix C (the enabler) lands last |

---

## 10. Open Questions / Resolved Decisions

All decisions were resolved with the requester **before** drafting. **None are open.**

| # | Decision | Resolution | Status |
|---|---|---|---|
| 1 | Scope, given the bulk path is unreachable | **Build bulk BOL export properly** (API + UI), not merely harden the `[0]`. §1 corrects the ticket's own root-cause narrative | **RESOLVED** |
| 2 | `v1/wms-web-ui`, which mirrors v2 exactly (§0 row 14) | **v2-only.** A paired v1 ticket is filed as §14 item 1 | **RESOLVED** |
| 3 | Dependency on draft plan SBDEV-2632 | **Author now.** 2632's Fix A-D are the convention this plan reuses; it should land first so the tolerant-parse / error-JSON / `extractBlobErrorMessage` patterns are established once. **Not a hard blocker** (§7.1 row 9) | **RESOLVED** |
| 4 | Which tabs get multi-select | **Closed tab only.** The Open tab's bulk Export button stays commented out, with DB Q2 (0/316) + `a8af84f` recorded in a code comment (Fix C4) | **RESOLVED** |
| 5 | Merged-workbook layout | **One sheet per BOL**, tab named by BOL number, each sheet keeping its pre-header + signature block | **RESOLVED** |
| 6 | Position-less BOLs | **Keep their empty sheet.** `a8af84f` deliberately made them export empty (§3); no skip-and-report design, which also keeps this plan free of any CORS/config prerequisite. Locked in by test #11 | **RESOLVED** |
| 7 | **Fix B shape** — extract or duplicate? | **Extract** a private per-BOL sheet builder that both paths call. The per-sheet content is *identical* between paths, so duplication is pure drift risk; **7 of the 10** existing tests assert only on the mocked `FileExportService` arguments and pass unedited, so they are a mechanical guardrail. User decision 11 strengthened this: both paths now share one naming rule, retiring Option B's only advantage. The rejected alternatives were (B) duplicate the ~80-line builder to leave `exportOutboundBOL` byte-untouched — the SBDEV-2632 precedent, invalidated here because that plan's multi path emits a *different* row shape while this one is identical; and (C) add a `FileExportService.exportExcelFiles(List<SheetSpec>, response)` primitive — rejected because `FileExportService` is shared by every export in the app and the accumulate-then-write primitive it would wrap already exists at `getExcelFile:138-229`. **Would change if** an existing test asserted on something the extraction moves other than the sheet-name string — all 10 were read; none does | **RESOLVED (decided here)** |
| 8 | **Max-ids cap** | **100.** `outboundBols.js:12` offers page sizes up to 100 with no "All" option, and Vuetify select-all is page-scoped, so 100 is the largest selection the UI can produce; a lower cap would 422 a legitimate select-all. Sizing from DB Q3. **The analysis bundle's suggestion of 50 was wrong** | **RESOLVED (decided here)** |
| 9 | **A CANCELLED BOL among valid ids** | **A per-BOL `NOTE` row in that BOL's sheet**, in-band; the workbook is still produced. Not a whole-request 422 (one stale row must not destroy 100 sheets), not a response header (would need a CORS property that does not exist). The single-BOL path keeps today's 422 via delegation | **RESOLVED (decided here)** |
| 10 | **Micrometer counter** | **No.** Actuator exposes `metrics`/`prometheus` (`application.properties:88`), so `http.server.requests` already yields count, status and latency for this URI. The only bespoke export metrics in the repo are job-scoped (`JobMetricsConfiguration:32` `stock_summary_export`, `StockSummaryExportJob:377` `wms2.oms.export_rejected`) — there is no request-path export-metric convention to extend, and the skill's row-8 trigger is high-frequency paths (picking, receiving, replenishment, club runs), which this is not. A **selection-size distribution** is the one thing `http.server.requests` cannot see — §14 item 8 | **RESOLVED (decided here)** |
| 11 | **Retire the `"Inbound BOL"` mislabel — name sheets by BOL number on *every* path** | **Yes.** Escalated by the Architect (finding 10) as a user call rather than decided in-plan, and **accepted**. This eliminates the first draft's cardinality-dependent sheet naming (old C1) and stops the plan preserving a known-wrong label by construction. Cost: the only output shape in production use changes (AC2), 3 assertions are edited (`:998, :1024, :1060` → `eq("BN-100")`), Principle 3 is reworded, and operators need telling (§7.1 row 4a, §14 item 6) | **RESOLVED (user, post-Architect)** |
| 12 | **Add a leading `Summary` index sheet — and only when N ≥ 2** | **Yes to the sheet** (Architect finding 11, accepted): `Sheet, BOL ID, BOL Name, Shipped, Courier, SKU Rows, Note`, one extra `getExcelFile` call, no new primitive. It is the navigation index for up to 100 tabs and the at-a-glance empty-BOL view — the job the rejected skipped-BOL header would have done, in-band and CORS-free, and it is the plan's answer to the flat-reconciliation need §1 cites. **Cardinality decided here: N ≥ 2 only.** At N=1 it restates that BOL's own pre-header and displaces the printable document to tab 2 on the highest-frequency path (the per-row kebab, all 2,516 closed BOLs today) — a daily click for zero information. The residual additive difference is AC1, materially weaker than the naming instability decision 11 removed, because every BOL's data sheet keeps its `OBOL######` name at every N | **RESOLVED (user + decided here)** |
| 13 | **Fix F: Jest test, or split into its own PR?** | **Jest test, stays in-PR** (Architect finding 13, first option, accepted). §8 test #22 asserts an Open-tab row built from the real `ViewDtoService` DTO key set resolves `item-key` to a defined, unique value, and it ships in the **same commit** as the one-word change (§7.3 Commit 4). Splitting was rejected: a third PR adds a third merge-order edge to a plan that already carries a one-directional API→UI coupling, to manage a risk the test removes | **RESOLVED (user, post-Architect)** |

### Cross-version (v1) applicability

`v1/wms-web-ui` is structurally identical: `components/outbound/bol/popups/exportBolPop.vue:72` has the
same `selectedItems[0].id`, and `openOutboundBol.vue:33` has the same commented-out Export button.
`v1/wms-api`'s `BillOfLadingController` has the same `Map`-coercion shape. **Applicable, deferred** by
decision #2 to the paired ticket in §14 item 1, which must also account for v1's Mockito 3.3.3 limits
(no `mockStatic`) and the fact that all v1 `@SpringBootTest` ITs currently fail at context load
(`ro_id` view drift, SBDEV-2384). Do **not** fix v1 here.

### Accepted consequences surfaced during design (not blocking, but stated)

*Labelled **AC**n, renamed from the first draft's `C`n to remove the collision with §5 Fix C's `C1`-`C4`
sub-fix labels. The old **C1** (cardinality-dependent sheet naming) is **gone**, not renumbered —
user decision 11 eliminated it.*

| # | Consequence | Why accepted |
|---|---|---|
| **AC1** | **A `Summary` sheet appears only at N ≥ 2**, so the *number* of sheets in a workbook is still cardinality-dependent — a consumer that assumes "sheet index 1 = the first BOL" breaks at N ≥ 2 | **This replaces the first draft's C1, which user decision 11 genuinely eliminated.** C1 was the strong form: the sheet name *of a given BOL's own data* changed with selection size, so a consumer could not predict where `OBOL000123` lived. That instability is gone — every BOL's data sheet is named `OBOL######` at every N. AC1 is the weak, **additive** form: one extra sheet with a **fixed** name (`Summary`), so a consumer that looks a BOL up **by name** is unaffected at any N. Accepted because suppressing the summary at N=1 protects the highest-frequency path (§10 decision 12), and the mitigation is the fixed name plus seeding `usedSheetNames` with it |
| **AC2** | **The single-BOL sheet name changes** from `Inbound BOL` to the BOL number — an operator-visible change to the only output shape in production use | Deliberate: user decision 11. `Inbound BOL` is a **mislabel on an outbound export**, and preserving a known-wrong name by construction to avoid 3 test edits was the plan's weakest link (Architect finding 10). Priced, not hidden: §7.1 row 4a mandates a ClickUp comment and both PR descriptions call it out, §8's manual table flags it as changed behaviour, and §14 item 6 carries the doc update |
| **AC3** | **A CANCELLED BOL's sheet contains a prose NOTE row**, so a workbook can carry non-data prose | It lives in the pre-header block, where `getRow(...)` metadata already lives, above the header row; the data region is empty. Unreachable from the UI today (the Closed tab lists only CLOSED; Q1 shows zero CANCELLED rows) |
| **AC4** | **The truncated-download window is *wider* than on the single path.** `exportExcelFile` opens the stream on the **last** sheet, so a POI failure during `workbook.write` leaves `isCommitted()` true, `writeExportError` logs and returns, and the client gets a truncated `.xlsx` with status 200 | Unclosable without buffering the whole workbook twice. Lower-probability than it sounds (all N sheets are fully built before the stream opens) but genuinely wider than the single-BOL case — recorded so a reviewer does not discover it cold |
| **AC5** | **The real-browser `Blob.text()` path is never exercised by CI** (H6: jsdom lacks `Blob.prototype.text`) | The manual row "Bad id surfaces a real message" covers it end-to-end before release |
| **AC6** | **`parseBolIds` accepts a scalar under the `ids` key** (`{ids: 5}`) via the `String.valueOf(raw)` fallback | Harmless and forgiving; the plan does not claim `ids` is array-only |
| **AC7** | **Fix E's `application/json` gate depends on the success path setting no `Content-Type`** — true today (`FileExportService:129-132` only calls `getOutputStream()`, and the `void` handler never applies its own `produces = "application/json"`), but nothing enforces it | If anyone later makes the export response honour `produces`, or adds the `Content-Disposition`/`Content-Type` headers this endpoint arguably should have, **every** export would be swallowed by the gate — and no test here would catch it, because the service tests mock `FileExportService` and never set a real content type. Raised by Architect finding 7. Accepted rather than hardened because the API now rejects errors with a real non-2xx (so axios never reaches the success branch on error) and the gate's only job is the residual 2xx-carrying-JSON case; a status-based second condition would be dead code today |
| **AC8** | **One workbook can now interleave BOLs belonging to different clients** within a tenant | The Closed tab already lists every client's BOLs to the same roles, and each row is attributable to its own sheet. Tenant isolation (the thing that matters) is unaffected — §11 row 7 |

### Verified negatives (recorded so reviewers do not re-derive them)

- **Caller census is complete.** `grep -rn "exportBolPop\|showExportBol"` across `wms2-web-ui` returns
  the popup plus exactly three callers (`closedOutboundBol.vue`, `openOutboundBol.vue`,
  `outboundBolDetails.vue`). `wms2-mobile-ui` and `omsv2-UI` have **zero** references to
  `billOfLading/exportOutboundBol`.
- **No Spring Data REST exposure concern.** Both export queries carry `@RestResource`
  (`BillofladingPositionRepository:43, 64`) and are therefore HAL-exported — but this plan changes
  **no query and no repository method**, so the SBDEV-1666 landmine (a service-layer branch cannot
  guard an exported HAL query) does not apply.
- **No `ids` payload collision.** `closeOutboundBols` on this same controller already consumes `bolIds`
  and `/exportOutboundBol` consumes `id`; the tolerant helper prefers `ids` and falls back to `id`,
  displacing no existing contract.
- **No ArchUnit rule blocks the design.** `HttpInTransactionArchTest` keys specifically on
  `HttpRestService` (read at `:57-84`), so it would not fire either way — but the §12 row 1 stance
  means no `@Transactional` is added, so `TransactionManagerArchTest`'s "must name a manager" rule is
  moot too. `OptionalSafetyArchTest` and `ParallelStreamSafetyArchTest` cover no construct added here.
- **Catch order compiles.** `BusinessException extends Exception` (checked) while
  `EntityNotFoundException extends RuntimeException`, so
  `catch (BusinessException) / catch (EntityNotFoundException) / catch (Exception)` produces no
  unreachable-catch error — same ordering SBDEV-2632 Fix A verified.
- **`FileExportService` needs no change.** `getExcelFile:222-225` writes only when `stream != null`,
  and `CyclecountService:189/208` already proves the accumulate-then-write pairing in production.

---

## 11. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change… | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | introduce per-replica state? | **No** | The only new state is method-local — `Set<String> usedSheetNames`, the `Workbook`, and the two pass-1 lists — all scoped to one request and discarded with the stack frame. The two new `static` members are `MAX_BULK_EXPORT_BOLS` (`static final int`) and `SUMMARY_SHEET_NAME` (`static final String`), both immutable. **Evidence:** `grep -nE 'static (?!final)' ` over the Fix A/Fix B After-code → 0 hits; no `ConcurrentHashMap`, no `ThreadLocal`, no `@Cacheable` **write**, no new Caffeine cache is introduced anywhere in the diff |
| 2 | **Connection pool math** | change per-request DB connection usage? | **Yes (bounded)** | A bulk export issues **N** `getClosedBOLSkuAmountDetail` / `getOpenBOLSkuAmountDetail` calls plus **N** `findById` calls instead of one each, N ≤ 100. Because **no transaction is held** (row 4), each query borrows a connection and returns it immediately — pool *occupancy* per request is one connection at a time, unchanged from today. What grows is borrow/return churn and total request duration, not concurrent connections. `replicas × tenants × maxPoolSize` is therefore unaffected. See Evidence |
| 3 | **Scheduled jobs** | add or modify `@Scheduled` / cron? | **N/A** | Pure HTTP request-path change. No `@Scheduled`, no ShedLock consideration. The BOL workflow doc records no cron on the export path |
| 4 | **Long transactions** | hold a tx across repository calls or external I/O? | **No — deliberately** | `exportOutboundBOLs` carries **no `@Transactional`**, so no connection is held across the response write. Full reasoning in §12 row 1 and §5 Fix B: pinning a per-tenant Hikari connection to the client socket for a whole download is the concern `HttpInTransactionArchTest.java:60-67` states un-scoped; `readOnly = true` would buy zero cross-query consistency under READ COMMITTED (no `isolation` property anywhere in `application*.properties`); a same-bean `@Transactional` gather method would be **self-invocation** and silently non-transactional; and OSIV is a non-issue (`application.properties:55`) because both queries return **interface projections** and `Billoflading.java:13-41` has zero association annotations. The residual read-skew (BOL A read before another operator's change, BOL B after) is a soft report inconsistency on a read-only reconciliation document — accepted, same as SBDEV-2632 §11 row 4 |
| 5 | **Request affinity** | assume a follow-up request lands on the same replica? | **No** | One stateless request/response. Every per-BOL outcome rides in the workbook itself — the `Summary` sheet's `Note` column and the blocked sheet's `NOTE` pre-header row (§5 Fix B) — not in session state, a response header, or a follow-up call. That is a second, independent reason the in-band design beats the rejected skipped-BOL header. **Evidence:** `grep -nE 'HttpSession\|@SessionAttributes\|SseEmitter\|WebSocket' ` over the diff → 0 hits |
| 6 | **Retry / idempotency** | rely on single-execution semantics? | **No (idempotent)** | Export is read-only; a UI retry re-reads and re-renders. **Evidence:** the whole diff contains no `save(`, `saveAll(`, `delete(`, `@Modifying`, or `flush(` — `grep -nE 'save\(|saveAll\(|delete\(|@Modifying|\.flush\(' ` over the Fix A/Fix B After-code → 0 hits. So a replica dying mid-export leaves no partial state and a retry from another replica is indistinguishable from the first attempt |
| 7 | **Tenant context** | use `TenantContext` across async boundaries? | **No** | Entirely synchronous on the request thread. No `@Async`, no `CompletableFuture`, no parallel stream added. All queries route through the existing per-request tenant datasource, so a workbook can never mix tenants (AC8 covers the *client* question, which is different) |
| 8 | **Distributed lock correctness** | add or rely on locks across replicas? | **No** | `findById` is a plain read. **Evidence (run, not asserted — per Critic §6):** `grep -n 'findByIdForUpdate' src/main/java/net/aim_ai/wms/service/BillofladingService.java` → exactly 2 call sites, `:307` (`closeBOL`) and `:1032` (`finishTransfer`), plus a comment at `:159` — **never** on either export method. `grep -c '@Lock\|pg_advisory'` on the same file → **0**. No lock is added, and none of the rows this path reads is locked by it |
| 9 | **Cache invalidation** | write to a cached entity? | **No** | The only `@Cacheable` read on this path is `syspropService.getSysvalue(...)` (`SyspropService.java:95` and `:288`, cache `sysprops`, keyed `facilityCode:key`), called from `BillofladingService.java:994`. The path performs **no write**, so no `@CacheEvict`/`@CachePut` is required and nothing can go stale as a result of this change. `grep -c '@Cacheable\|@CacheEvict\|@CachePut' src/main/java/net/aim_ai/wms/service/BillofladingService.java` → **0** (run 2026-08-03); the cached read is reached through the injected `SyspropService` proxy, not annotated locally. The `usedSheetNames` set is not a Spring cache and cannot go stale across requests. *Corrected after Critic blocking 5: an earlier revision claimed "nothing on this path is `@Cacheable`", which was false and contradicted this section's own Evidence row 2* |
| 10 | **External notifications** | send HTTP / a message inside a transaction? | **No** | No OMS notification, no outbox enqueue, no printer call on the export path. `HttpInTransactionArchTest` is satisfied trivially (and no `@Transactional` is added anyway) |

### Evidence (for the "Yes" row)

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 2 | Query count per bulk export = N × `findById` + N × (`getClosedBOLSkuAmountDetail` \| `getOpenBOLSkuAmountDetail`), N ≤ `MAX_BULK_EXPORT_BOLS` = 100. **`syspropService.getSysvalue(WAREHOUSE_NAME)` at `BillofladingService.java:994` runs once per sheet (100× at the cap) but adds only ONE DB hit** — it is `@Cacheable(value = "sysprops", …)` keyed on `facilityCode:key` (`SyspropService.java:95` and `:288`) and is reached through the injected proxy, so it is 1 miss + 99 Caffeine hits (Architect finding 12, verified; hoisting it out of the loop is tidiness, not a fix, and would touch the extracted builder for no behavioural gain). No transaction wraps them ⇒ one connection held at a time, borrowed and returned per query. Sizing from live DB: avg 92.5 export rows/BOL, p95 271, max 493 across 2,298 exportable closed BOLs (§1 Q3) ⇒ ~9,250 rows typical, ≤49,300 worst observed, at 3 columns. Cap enforced at the controller boundary so an over-large request is rejected **before** any query runs | `BillOfLadingController.parseBolIds` + `MAX_BULK_EXPORT_BOLS` (§5 Fix A); `BillofladingService.exportOutboundBOLs` has no `@Transactional` (§12 row 1); test #8 (cap → 422); manual row "Select-all on a full page" |

---

## 12. v2-only constraint checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | **OSIV disabled** — any lazy access outside a transaction? | **No issue — and therefore no `@Transactional` is added.** *This contradicts the analysis bundle, deliberately.* | **Four** independent proofs. (a) Both export queries return **interface projections**, not managed entities: `BolSkuOpenAmountView` / `BolSkuClosedAmountView` declare only `getSkuNumber/getSkuName/getStockQuantity\|getStockAmount/getStockReserved` — no association to traverse. (b) Every `Billoflading` getter used by `buildSheetData` is a **scalar column**: `state`, `name`, `number`, `shipped`, `courier`, `sealnumber`, `truck`, `numberOfParcels` (`Billoflading.java:13-41`) — no `@ManyToOne`, no `@OneToMany` is touched. (c) Empirically, `exportOutboundBOL` has carried no `@Transactional` since it was written and works in production. Adding one would pin a per-tenant Hikari connection to the client socket for the whole download, because the method's last act is `workbook.write(response.getOutputStream())` — the concern `HttpInTransactionArchTest.java:60-67` states un-scoped in its own `.because(...)`. (**Corrected after review:** the first draft cited `CLAUDE.md:194`; that line is bullet 4 under “Scheduled Jobs & Tenant Context” and is scoped to job classes. Conclusion unchanged, citation replaced.) (d) A fourth proof the first draft missed: even the *middle* option is unavailable — a `@Transactional` gather method invoked from `exportOutboundBOLs()` in the same bean is Spring self-invocation and would not be proxied at all |
| 2 | **Transaction manager** — tenant-scoped writes use `tenantTransactionManager`? | **N/A** | No `@Transactional` added and no write performed. `TransactionManagerArchTest` would force a named manager if anyone later adds one — noted so the next person does not add a bare `@Transactional` |
| 3 | **`@Transactional(readOnly = true)`** on read paths? | **Deliberately not added** | Three reasons, re-based after review. (1) It would pin a per-tenant Hikari connection to the **client socket** for the whole download, not merely "hold a connection across some calls" — the response stream is written inside the method (row 1). (2) It would buy **zero** cross-query consistency: `grep -n "isolation\|REPEATABLE_READ" src/main/resources/application*.properties` → no isolation override anywhere, so PostgreSQL **READ COMMITTED** applies and takes a new snapshot per statement. Only `isolation = REPEATABLE_READ` would mean anything, which is a materially heavier change for a low-frequency reconciliation report. (3) **The obvious middle path is not available.** Wrapping only the *gather* phase — which genuinely would not span I/O — cannot be done with an annotation on a method of this same bean: `exportOutboundBOLs()` calling a `@Transactional` gather method on `this` is Spring **self-invocation**, so the proxy is bypassed and the annotation is silently inert. Doing it properly needs a new collaborator bean or an explicit `TransactionTemplate`, and it would keep all N row payloads alive inside the transaction. Not worth it for a read-only reconciliation report over terminal `CLOSED` data. Same stance SBDEV-2632 §11 row 4 and the 260610 plan took for these export methods |
| 4 | **Caffeine cache invalidation** paired with writes? | **N/A — nothing to invalidate** | The path **does** read one cached value — `getSysvalue` is `@Cacheable(value = "sysprops", …)` at `SyspropService.java:95`/`:288` — but it performs **no write to any entity, cached or otherwise**, so there is no `@CacheEvict`/`@CachePut` obligation to pair. *Corrected after Critic blocking 5, same false claim as §11 row 9.* Verdict unchanged |
| 5 | **Jakarta namespace** — no `javax.*` imports? | **Yes (clean)** | `jakarta.servlet.http.HttpServletResponse` is already imported at `BillOfLadingController.java:28` and used by `BillofladingService`. New imports are `org.springframework.http.HttpStatus` / `MediaType`, `java.nio.charset.StandardCharsets`, `net.aim_ai.wms.util.WmsObjectMapper` (controller); `org.apache.poi.ss.usermodel.Workbook`, `org.apache.poi.ss.util.WorkbookUtil` (service). `java.util.*` is already wildcard-imported in both. **Zero `javax.*`** |
| 6 | **H2-compatible test SQL** | **N/A** | No new query and no query edited; both existing export queries are untouched native PostgreSQL. Every new test mocks the repositories, so no H2 and no Testcontainers scope — which also means the broken v2 IT harness (SBDEV-2217) does not block this plan. Any IT nonetheless added must be `@Disabled` with a `TODO(SBDEV-2217)` |
| 7 | **`BaseControllerTest` for controller changes** | **Yes** | The endpoint contract changes (new `ids` key, new status codes), so new cases go in `BillOfLadingControllerUnitTest`, which already `extends BaseControllerUnitTest` (`:38`) with its `MockMvc` + tenant-context + `MockPrincipalArgumentResolver` setup. ⚠️ The class has **12 `@Nested` classes** — Surefire `-Dtest='Class#method'` silently no-ops on `@Nested` and reports a false green; always run the bare class name |
| 8 | **Micrometer metrics** on a high-frequency path? | **No** | BOL reconciliation export is a low-frequency admin action, not one of the row-8 trigger paths (picking, receiving, replenishment, club runs). Actuator already exposes `metrics` + `prometheus` (`application.properties:88`), so `http.server.requests` gives per-URI count, status and latency for `/v3/billOfLading/exportOutboundBol` **without new code** — and this fix *removes* failure modes rather than needing to observe them. The only bespoke export metrics in the repo are job-scoped (`JobMetricsConfiguration:32`, `StockSummaryExportJob:377`, `WarehouseStockReportService:94`); there is no request-path convention to extend, and inventing one would duplicate Actuator. Selection-size distribution deferred to §14 item 8 |

---

## 13. Completeness checklist (wms-bugfix-plan skill, Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** — `execute_sql` run, result inline in §1, frontmatter `db_verified: true` | ✓ §1 "DB verification" — **4** live queries on wms2-wineco-dev (2026-08-03). Q2 (0/316 OPEN BOLs exportable) settled the tab scope; Q3 (avg 92.5 / p95 271 / max 493 rows per closed BOL) sized the cap; Q4 (2835/2835 distinct 10-char `OBOL` numbers, 0 illegal chars) proved sheet-name sanitisation is defensive |
| 1 | **All callsites enumerated** — every §0 row visited or excluded with rationale | ✓ §0 — **18** rows. Rows 1-8, 10 and 16 in scope → §5 Fix A-F (**row 10 moved in** by user decision 11); rows 9, 11-15, 17-18 excluded with reasons. Every in-scope row maps to a POSITIVE verify check (§9.2) |
| 2 | **Adjacent bugs** — same-pattern instances found by pattern-grep | ✓ §0 rows 10-15 from the frontend `selectedItems[0]` sweep (5 hits) and the backend `exportOutboundBol` sweep (2 controllers); §0 row 15 inherits SBDEV-2632's ≥18-site `Map`-coercion enumeration rather than re-deriving it. **Two sites the analysis bundle missed** were added during drafting as rows 16 (`outboundBolDetails.vue:133` push-without-reset, unmasked by Fix D) and 17 (`closedOutboundBol.vue:303-307` kebab mis-wire) |
| 3 | **Backward compatibility** — API contract, payload shape, error-response shape | ✓ §5 Fix A accepts **both** `{id: …}` and `{ids: […]}`; §5 Fix B's `size()==1` delegation keeps one code path for every single-BOL caller and keeps CANCELLED → 422. **Two deliberate breaks, both priced:** (i) the single-BOL sheet **name** changes — AC2, user decision 11, 3 test edits at `:998, :1024, :1060`, operator comms in §7.1 row 4a and §14 item 6(b); (ii) the **error-response shape** changes from 200-with-`Map.toString()` to 422/404/500 + JSON, documented as intentional in §5 Fix A (it needs no AC of its own — no consumer outside this repo was found, §10 Verified negatives). Everything else is pinned by the 7 unedited existing tests plus §8 test #21's `preHeaderRows == null` invariant. Deploy-order coupling is one-directional and recorded (§7.1 row 4) |
| 4 | **Concurrency** — races, locks, idempotency under retry | ✓ §11 rows 4, 6, 8 — read-only, no locks, idempotent under UI retry. The accepted read-skew across N queries (no transaction) is stated in §11 row 4 rather than hidden |
| 5 | **Multi-tenant** — cross-tenant queries, context propagation, cache scoping | ✓ §11 rows 7, 9 + §12 rows 1, 4 — all queries route through the existing per-request tenant datasource, the only `@Cacheable` read on this path is `getSysvalue` and the path performs no write, and the only new state is request-scoped. The cross-**client** (not cross-tenant) consequence is stated as AC8 |
| 6 | **Error handling** — every new throw path has a handler or a documented contract change | ✓ §5 Fix A — three status-differentiated catches, `isCommitted()` guard, `resetBuffer()` (never `reset()`), 5xx detail not echoed; §5 Fix B — `BusinessException` for empty input, `RuntimeException` preserved for an unknown state, CANCELLED demoted to an in-band note in the bulk path only; §2 Bug 2 documents today's escape to a raw 500 (via SBDEV-2632 §2's proof that this controller's package has no `Exception` advice) |
| 7 | **Observability** — logs, metrics, alert thresholds | ✓ §5 Fix A keeps `LOG.error(..., e)` with the full stack trace for unexpected types; `LOG.debug("start export with reqMap={}")` replaces the misleading `"start action unitload="`; §7.1 row 8 + §12 row 8 — **no** bespoke metric, because Actuator's `http.server.requests` already covers count/status/latency per URI, with the reasoning and the one gap (selection-size distribution → §14 item 8) recorded |
| 8 | **Rollback / migration** — Flyway, backfill, deploy order, flags | ✓ §7.1 rows 1, 4, 5 — no Flyway, no backfill, no flag. §7.2 + §7.3 order the 8 commits so Fix A, Fix F and Fix E are each independently revertable and Fix C (the enabler) lands last. The revert hazard (API PR reverted after both merge ⇒ the UI's `ids` payload NPEs old code) is the reason the order is stated in both PR descriptions |
| 9 | **Test coverage** — unit + integration + manual, named classes/methods | ✓ §8 — **26** scenarios (1-18, 19a/19b/19c, 20-24 — verified by counting the table, not estimated), **26** named test methods across **6** files (`BillOfLadingControllerUnitTest`, `BillofladingServiceUnitTest`, and **four** new UI specs incl. `openOutboundBol.spec.js` for Fix F per user decision 13), a 14-row manual click-path table, a skipped-coverage table, **plus 10 harness obligations (H1-H10) verified by probing the repos** — the `@Mock`ed `FileExportService`, the `null`-response convention in all 10 existing tests, the jsdom `URL.createObjectURL`/`Blob.text` gaps, and **four vacuous-assertion traps caught across two review rounds** (test #9 needing H9's instance-identity stub; test #11 needing a positive assertion rather than "does not throw"; test #19 needing the 200-with-JSON-body shape, since a 422 already rejects pre-fix; and tests #17/#22 needing H10's read-from-the-render rule, without which a hardcoded `item-key` literal is unfailable) are named rather than left for the gate to discover |
| 10 | **Cross-version (v1↔v2)** | ✓ §10 "Cross-version (v1) applicability" — applicable and **deferred** by decision #2 to the paired ticket in §14 item 1, with the v1 deltas (Mockito 3.3.3, the SBDEV-2384 IT blocker) spelled out so the sibling plan inherits them |

---

## 14. Follow-ups (not blocking)

1. **Paired v1 ticket** for `v1/wms-web-ui` §0 row 14 — `exportBolPop.vue:72`'s `selectedItems[0].id`
   and `openOutboundBol.vue:33`'s commented-out Export button, plus the v1 `BillOfLadingController`
   `Map`-coercion shape. Decision #2. Mirror this plan with the v1 adaptations named in §10.
2. ~~**`BillofladingService:1010` sheet name says `"Inbound BOL"` on an outbound export**~~ — **CLOSED,
   folded into this plan by user decision 11.** Kept as a struck-through entry rather than deleted so a
   reviewer who read the first draft can see where it went: Fix B now names sheets by BOL number on
   **both** paths, §0 row 10 changed from out-of-scope to in-scope, and the operator-visible
   consequence is AC2 with its communication in §7.1 row 4a.
3. **`AdviceController.java:330`** — a second `exportOutboundBol` with the same unguarded
   `Map<String,Object>` coercion, on the inbound-advice path (§0 row 11). Same class of defect,
   different endpoint, not reachable from the BOL screen.
4. **Open-tab bulk export stays disabled.** Revisit only if `TRUCK_LOADING` / `TRANSFER` volume grows
   — Q1 shows 3 and 0 BOLs respectively today, and Q2 shows 1 of those 3 exports empty.
5. **`closedOutboundBol.vue` kebab mis-wire** (§0 row 17) — *"Mark as Received"* opens the **Export**
   dialog because `addToSelectedItems` calls `showExportPop()` unconditionally and the component
   imports no receive popup. Preserved by Fix C with a comment; needs its own ticket, because fixing
   it means adding a dialog this component does not have.
6. **Doc updates + operator communication — run `verify-docs` after implementation.**
   (a) `sbdocs/3-Resources/workflows/wms2-bol-truck-loading-workflow.md:285` documents the endpoint as
   `POST /v3/billOfLading/exportOutboundBol` at line 265 with no payload shape; update it to
   `{ids} | {id}` plus the new status codes, the one-sheet-per-BOL layout and the `Summary` sheet, and
   add a Verification Log row (`:337` area — the same row region that records the `a8af84f` port). Its
   90-day re-verify was already due **2026-08-06**, so this lands inside the window.
   (b) **Tell operators the single-BOL export's sheet name changes** from `Inbound BOL` to the BOL
   number (AC2). This is the one change in the plan that alters an artifact people already receive; if
   anyone has a spreadsheet macro or a saved import keyed on the tab name, it breaks. The ClickUp
   comment in §7.1 row 4a and both PR descriptions carry it, but a release note is the thing that
   reaches the warehouse.
7. **De-duplicate `extractBlobErrorMessage`** if both this plan and SBDEV-2632 declare it locally —
   promote one copy to `util/commonUtility.js` (§7.1 row 9).
8. **Selection-size observability.** If the 100-BOL cap starts being hit, a Micrometer
   `DistributionSummary` on `ids.size()` is the one signal `http.server.requests` cannot provide
   (§12 row 8). Not added speculatively.
9. **Streaming export (`SXSSFWorkbook`)** if heap ever becomes the binding constraint. It requires
   removing **both** `((XSSFWorkbook) workbook).createFont()` casts in `FileExportService`
   (`:94` and `:187`), which affects **every** export in the application — a standalone ticket, not a
   rider on this one.
10. **`BillOfLadingController.java:185` — `setDestinationFacility`** carries a character-for-character
    twin of Bug 2's `((Integer) reqMap.get("id")).longValue()`, also pre-`try`, also a raw 500 on a
    JSON-string or absent `id` (§0 row 18). Same class as SBDEV-2632 §0 row 13's sweep; not widened
    here because it is unreachable from the BOL export path. Whoever picks up that sweep should apply
    this plan's `parseBolIds` + `writeExportError` pattern.

---

## 15. Implementation Status

*Not yet implemented — but the acceptance script exists and its pre-fix baseline is already captured.*

### Already done at plan time (2026-08-03)

**Verify script written and negative-tested:**
`sbdocs/9-System/scripts/verify-SBDEV-2797-outbound-bol-bulk-export-first-only.sh` — 71 checks.

- [x] **Pre-fix baseline against untouched `develop`: `Result: 8 pass, 63 fail, 3 skip`** (exit 1;
      the 3 skips are the `mvn` rows — maven was not on PATH for the capture). Every one of the 63
      fix rows FAILS pre-fix, as required.
- [x] **The 8 pre-fix passes are all legitimately invariant, and enumerated:** `A-no-reset`,
      `B-legacy-sig`, `B-legacy-cancel-msg`, `B-no-tx-method`, `B-no-tx-class`,
      `B-no-skip-empties`, `B-fileexport-unchanged`, `C-open-still-commented`.
- [x] **One vacuous row was caught by the baseline run itself and fixed.** `B-exportexcelfile` was a
      whole-file check that passed pre-fix because the *legacy* `exportOutboundBOL` already calls
      `exportExcelFile`; it is now `java_method`-scoped to `exportOutboundBOLs`. This is the fifth
      instance of the vacuous-assertion class caught on this plan (after review-round catches on
      tests #9, #11, #19 and #17/#22) — the pattern is now well-evidenced enough that the
      implementer should assume more exist rather than assume none do.
- [x] **4 of the 8 invariant rows counter-tested and proven to have teeth** (each flipped
      PASS → FAIL when the corresponding mutation was applied to a shadow copy):

      | Row | Mutation applied | Result |
      |---|---|---|
      | `A-no-reset` | inject `response.reset()` | FAIL ✓ |
      | `B-no-tx-method` | inject `@Transactional` **above** the signature | FAIL ✓ |
      | `B-fileexport-unchanged` | append a line to `FileExportService.java` | FAIL ✓ |
      | `C-open-still-commented` | uncomment the Open-tab Export button | FAIL ✓ |

      `B-no-tx-method`'s counter-test matters most: `java_method` starts **at** the signature line, so
      an annotation placed above it would escape a naive method-scoped grep. The row uses a 3-line
      look-back helper instead, and `B-no-tx-class` correctly stayed PASS during the mutation — so the
      two rows discriminate rather than both firing.

### TDD gate — API surface, run 2026-08-03

**Worktree:** `.claude/worktrees/wms2-api/SBDEV-2797` on `feature/SBDEV-2797-outbound-bol-bulk-export`,
off freshly-fetched `origin/develop` = `37bb39e` (the SBDEV-2632 merge). The executor MUST reuse this
tree — the gate tests live here and nowhere else.

- [x] **20 failing tests written**, covering §8 Java scenarios 1–13, 20, 21, 23, 24.
      `Tests run: 105, Failures: 3, Errors: 17` across the two classes = **85 pre-existing pass,
      20 new fail, 0 unexpected passes.**
- [x] **Every failure is a correct failure**, thrown from production code rather than scaffolding:
      `ClassCastException: String cannot be cast to Integer` (#3, #5b) and
      `NullPointerException: Integer.longValue() … Map.get is null` (#4, #5a, #5c, #6, #8a, #8b, #20)
      both come from `BillOfLadingController:270` — the pre-`try` coercion this plan exists to fix.
      The service scenarios fail with `UnsupportedOperationException: SBDEV-2797 not implemented`.
- [x] **Pre-existing `ExportOutboundBOL` nested class: 10/10 still passing.** (All 10 pass *now*
      because the production code still emits `"Inbound BOL"`. Fix B's rename is what forces the
      3 edits at `:998`, `:1024`, `:1060` — verified to be exactly 3.)
- [x] `archunit_store` **not** mutated (targeted `-Dtest` runs never load the ArchUnit tests).
- [x] Main checkout left untouched on its own branch (`bugfix/SBDEV-2777-…`), working tree clean.

**⚠️ A GATE SCAFFOLD IS IN THE DIFF AND MUST BE REPLACED, NOT KEPT.**
`BillofladingService.exportOutboundBOLs(...)` currently has a body of
`throw new UnsupportedOperationException("SBDEV-2797 not implemented")`. It exists only so the 11
scenarios that reference the new signature could compile and fail for a clear reason — the gate's own
rules require compiling tests but forbid editing service classes, and for a plan that *adds* a method
those cannot both hold. The stub carries a Javadoc block listing the contract the executor must
satisfy. **Replacing that body is Fix B; leaving it is a broken build.**

### API half implemented 2026-08-03 — `feature/SBDEV-2797-outbound-bol-bulk-export`

**Scope of this run: `v2/wms2-api` only (Fix A + Fix B).** Fixes C/D/E/F (`wms2-web-ui`) are NOT
implemented — they were never TDD-gated and are deferred to a sibling run.

**PR: [wms2-api #121](https://github.com/SiteBossInc/wms2-api/pull/121)** — **MERGED into `develop` 2026-08-03**, merge commit `a0846d1`.
Post-merge verified on `origin/develop`: all 3 commits are ancestors, `mvn clean compile` succeeds, and
`BillofladingServiceUnitTest` + `BillOfLadingControllerUnitTest` report **111 run, 0 fail**.
Merged with **no CI checks configured on this repo and no human review** — the only gates were this
session's conformance / code-review / security lanes and the test+verify suites.

| Commit | Subject |
|---|---|
| `4d88ed3` | `feat(bol): merge multiple outbound BOLs into one export workbook [SBDEV-2797]` |
| `e437049` | `fix(bol): stop HTTP 500 on bulk outbound BOL export [SBDEV-2797]` |
| `200a689` | `test(bol): cover bulk export, error contract and CORS preservation [SBDEV-2797]` |

Each of the first two leaves a compiling tree (verified), so the three are independently revertable.
**Merge order satisfied: #121 is in `develop` FIRST, as required.** The UI PR must follow it, and
**reverting #121 will require reverting the UI PR** once that lands.

**Safe to ship ahead of the UI:** `parseBolIds` still accepts the legacy `{id:N}` the current UI sends,
so single-BOL export is unaffected; and the new 422 makes `$axios.$post` reject, so today's UI shows a
visible toast instead of its previous silently-corrupt download. Bulk export remains unreachable from
the UI until Fixes C/D/E/F land.

| Result | Value |
|---|---|
| `mvn clean compile` | SUCCESS |
| `mvn test -Dtest=BillofladingServiceUnitTest` | **78 run, 0 fail** — `ExportOutboundBOLsBulk` 9, `ExportOutboundBOL` **10/10** |
| `mvn test -Dtest=BillOfLadingControllerUnitTest` | **27 run, 0 fail** — `ExportOutboundBolBulk` 17 |
| Full `mvn test` | **4611 run, 2 fail** — `OptionalSafetyArchTest` + `MobilePalletizingServiceTest`, both pre-existing on clean `develop`; neither report mentions either changed file |
| Verify script (`PROJECT_ROOT`=worktree, `UI_ROOT=/nonexistent`) | **`Result: 44 pass, 0 fail, 30 skip`** — all 38 `A-*`/`B-*` rows pass; the 30 skips are the deferred UI rows |
| `archunit_store` | Reverted; only the 4 intended files modified |

**Extraction guardrail HELD:** 7 of the 10 pre-existing `ExportOutboundBOL` tests are byte-unchanged;
exactly 3 were edited (`:998`, `:1024`, `:1060`), each only `eq("Inbound BOL")` → `eq("BN-100")`.
No 4th pre-existing test was touched.

**Review outcome — 0 critical, 0 high, 6 medium (all fixed), 17 low:**

| From | Finding | Action |
|---|---|---|
| conformance | 3 of my own tests weaker than §8 required (H2 `null` response; #12/#23 asserted Summary *shape* not *values*) | **Fixed**, then counter-tested — hard-coding `row[5]=0` now fails #23; passing `null` for the response fails 5 tests |
| conformance | Dropped the plan's null/blank sheet-name fallback | **Restored** |
| security M1 | The twin's 2 security regression tests (XSS token, 5xx JDBC-URL suppression) were never ported | **Ported** |
| security M2 | Cap tested the *de-duplicated* set, so `{"id":"1,1,1,…"}` allocated ~500k Strings and then passed | **Fixed** — bounded `split(",", cap+2)` + a pre-parse token check. Counter-tested |
| security M3 | 100-BOL cap bounds sheet *count*, not work; rows/BOL unbounded and `OutOfMemoryError` escapes `catch(Exception)` | **Fixed** — `MAX_BULK_EXPORT_ROWS = 250_000` budget during pass 1. Counter-tested |
| review M1 | **POI's duplicate-sheet check is CASE-INSENSITIVE** (probed on 5.3.0) but the guard set was a `LinkedHashSet` — so the `SUMMARY_SHEET_NAME` seed did **not** do what its own comment claimed, and a BOL numbered `summary` would 500 the export | **Fixed** — `TreeSet<>(String.CASE_INSENSITIVE_ORDER)` on both paths + a regression test. Counter-tested |
| review M2 | An `IOException` on write surfaced as **422 with the raw message**, bypassing the 5xx suppression | **Fixed on the bulk path** (`UncheckedIOException` → 500 → generic). **Deliberately NOT on the legacy path** — see the deviation note below |
| review M3 | The 2 direct `parseBolIds` tests §8 names did not exist; the >2^31 `Long` id (the coercion's whole motivation) was untested | **Added** both, covering >2^31, comma-split scalar, trimming, and null elements |
| review lows | L1 mutable shared `static String[]`, L2 `{"exportDetails":"true"}` silently false, L5 duplicated exception format, L8 undocumented `default:` throw, L9/L11/L12 hygiene | **Fixed** (all one-liners in touched code) |

**Deviations from §5, recorded rather than silent:**

1. **`sanitizeToken` added** (not in §5) — mirrors 2632's merged code; the UI toast is a vue-toasted
   `innerHTML` sink. Narrows §8 #4: a token containing `<` now reports `(unreadable)` instead of naming
   itself. Both reviewers endorsed it; the security lane probed the filter and found no bypass.
2. **`MAX_BULK_EXPORT_ROWS` added** (not in §5) — the security lane's M3 fix. §11's heap mitigation was
   the BOL-count cap alone, which bounds sheets rather than work.
3. **Review M2 not applied to the legacy path.** `BusinessException("create file failed: " + …)` is a
   repo-wide convention (AdviceService, ReportService ×10, CyclecountService all emit it and their tests
   assert on it), and `throwsWhenFileExportFails` asserts **both** the type and the text — changing it
   would force an 8th pre-existing-test edit and break the extraction guardrail. **The reviewer's claim
   that "no test asserts on the text" is incorrect; verified.** → §14 follow-up.
4. §12's evidence for row 1 said "two new `static` members, both immutable" — there were three, one
   mutable (`SUMMARY_HEADERS`). Now a method; the row's evidence needs that line.

**Counter-tests run (each flipped PASS → FAIL on the injected violation):** `A-no-reset`,
`B-no-tx-method`, `B-fileexport-unchanged`, `C-open-still-commented`, `B-no-skip-empties`,
`B-summary-seeded`, `A-lookup-in-try`, `B-no-inbound-literal`, plus the M1 case-sensitivity, M2
comma-bomb, M3 row-budget, H2 response-argument and #23 summary-count assertions. **§9.2 counter-tests
B, C and D are discharged** (the conformance lane ran B and D independently).

**Doc drift actioned:** `wms2-bol-truck-loading-workflow.md` — the REST-endpoint export row rewritten
(line moved 265→276; request shape, status codes and sheet naming all changed); `last_verified` bumped
to 2026-08-03.

### Still owed at execution time

- [ ] `B-no-skip-empties` counter-test (§9.2 counter-test B) — **could not** be run at plan time
      because `exportOutboundBOLs` does not exist yet. **Do not treat this row as proven.** It is the
      row that protects `a8af84f`; run the mutation as soon as the loop exists.
- [ ] Counter-tests C and D (§9.2) — same reason; both need the post-fix tree.
- [ ] Post-fix synthetic-tree validation (§9.2 step 2), **including the mandated comment blocks** —
      that omission is what produced 2632's false-red.
- [ ] Commit SHAs per fix (A / B / tests / F+C4 / E / D / C / UI tests)
- [ ] `mvn clean compile` result
- [ ] `mvn test -Dtest=BillofladingServiceUnitTest` — confirm **7 of the 10** pre-existing
      `ExportOutboundBOL` tests are unedited and passing, and that the 3 edited ones
      (`:998, :1024, :1060`) differ **only** in the `eq(...)` sheet-name argument
- [ ] `mvn test -Dtest=BillOfLadingControllerUnitTest` and full-suite counts, with the 2 known
      pre-existing `develop` failures called out
- [ ] `node_modules/.bin/jest --testPathPattern='outbound'` result
- [ ] Final verify line `Result: N pass, 0 fail, S skip`
- [ ] `archunit_store` reverted before commit
- [ ] Code-review outcome (critical / high / medium counts + resolutions)
- [ ] `verify-docs` outcome + `wms2-bol-truck-loading-workflow.md` update
- [ ] PR links (wms2-api, wms2-web-ui) **and confirmation the API PR deployed first**
- [ ] ClickUp SBDEV-2797 → `pr submitted`
