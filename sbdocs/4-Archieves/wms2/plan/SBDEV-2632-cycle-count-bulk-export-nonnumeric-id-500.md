---
title: "Cycle Count Bulk Export 500 — Multi-Select Ids Parsed With Long.parseLong Outside the try"
ticket: "SBDEV-2632"
ticket_url: "https://app.clickup.com/t/868keq79q"
type: "bug"
priority: "high"
status: "archived"
project: ["wms2"]
version: "v2"
requester: "Arden Latraca (reported), Scott Dalton (split v1/v2)"
created: "2026-08-02"
updated: "2026-08-09"
db_verified: true
related:
  - "../../../4-Archieves/wms2/plan/260610-excel-export-localdatetime-unsupported-type.md"
  - "../../../4-Archieves/wms2/plan/SBDEV-2233-nametypeservice-date-format-pattern-fix.md"
  - "../../../3-Resources/workflows/wms2-cycle-count-workflow.md"
tags:
  - plan
  - bug
  - export
  - file-export
  - cyclecount
  - bulk-action
  - input-validation
  - http-500
---

# Cycle Count Bulk Export 500 — Multi-Select Ids Parsed With `Long.parseLong` Outside the `try`

**Ticket:** [SBDEV-2632](https://app.clickup.com/t/868keq79q) — *V2 Fix: Cycle Count Bulk Export Does Not Work*
**Parent:** [SBDEV-2264](https://app.clickup.com/t/868jmmeya) (high) | **Sibling (v1):** [SBDEV-2631](https://app.clickup.com/t/868keq78n) — mirror plan, **out of scope here**
**Project:** wms2/wms2-api + wms2-web-ui | **Version:** v2 (Java 21 / Spring Boot 3.5.x) | **Type:** Bug (latent, never worked)
**Priority:** High | **Target branch:** `feature/SBDEV-2632-cycle-count-bulk-export` off `origin/develop`
**Status:** ✅ **ARCHIVED 2026-08-09 — MERGED 2026-08-03.** Both PRs merged into `develop`:
`wms2-api` **#119** (merge `37bb39e`) and `wms2-web-ui` **#35** (merge `6ce7878`), both from
`feature/SBDEV-2632-cycle-count-bulk-export`. ClickUp SBDEV-2632 is at **`on dev`**.
*(The line below read "PRs open … awaiting review" for six days after they merged — corrected at archival.)*

> **Archive note.** Acceptance script retired to
> `sbdocs/4-Archieves/scripts/verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh`.
> **No implementation worktree existed** for this ticket, so none was removed.
>
> **Carried forward — do not lose:** §0 row 7 identified a *separate* live defect that is **not** fixed by
> this plan — `exportBolPop.vue:72` sends only `selectedItems[0].id`, so an outbound-BOL multi-select
> **silently exports the first BOL only, with no error**. That is owned by
> **[[SBDEV-2797-outbound-bol-bulk-export-first-only]]**, which is active in `1-Projects/wms2/plan/`.
**Date:** 2026-08-02
**db_verified:** true (wms2-wineco-dev via MCP, 2026-08-02)

> Acceptance script: `sbdocs/9-System/scripts/verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh`

---

## 0. Affected sites (enumeration before drafting)

**Enumeration method (not recall):**
- `grep -rn "join(', ')" --include=*.vue --include=*.js components pages store` in `v2/wms2-web-ui` → **6 hits**, each traced through to its `dispatch` and its backend endpoint.
- `grep -rn 'Long\.parseLong((String) reqMap\.get' src/main/java/net/aim_ai/wms/controller/` **repo-wide across all controllers** (not just this file) → 2 hits; plus `grep -rn 'Long\.valueOf( *(Integer)' ` for the `ClassCastException` sibling shape → 15 hits. Both feed row 13.
- `grep -rn "exportCycleCount" src/main src/test` (caller census).
- `grep -rn 'cycleCount/export'` across **all five** UI trees (`wms2-web-ui`, `wms2-mobile-ui`, `omsv2-UI`, `wms-web-ui`, `wms-mobile-ui`) → confirms no mobile/OMS consumer.

| # | File:line | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `wms2-api .../controller/CycleCountController.java:111` | `Long.parseLong((String) reqMap.get("id"))` **outside** the `try` at :123 | **yes — Bug 1** | **yes** |
| 2 | `wms2-web-ui .../internalOps/cycleCount/exportCyclePop.vue:61,71` | `exportList.join(', ')` sent as a **scalar** `id` | **yes — Bug 1** | **yes** |
| 3 | `wms2-api .../service/CyclecountService.java:154-160` | single-CC-only signature + positionless `BusinessException` | **yes — Bug 2** | **yes** |
| 4 | `wms2-api .../controller/CycleCountController.java:125-142` | `BusinessException` caught into the **same 200** response, non-JSON body | **yes — Bug 2** | **yes** |
| 5 | `wms2-web-ui store/internalOps/cycleCount.js:196-215` | blob-only handler; dead `result.errors` guard; no header read | **yes — Bug 2** | **yes** |
| 6 | `wms2-api .../controller/CycleCountController.java:82-86` (`/cancel`) | `split(",")` + per-id `parseLong` **in a loop** | no — **already correct; this is the reference implementation** | no — untouched. Its un-trimmed `split(",")` is tolerated only because `cancelCycleCountPop.vue:64` joins **without** a space; do not "harmonise" it in this plan |
| 7 | `wms2-web-ui .../outbound/bol/popups/exportBolPop.vue:72` | multi-select sends only `selectedItems[0].id` → **silently exports the first BOL only, no error** | no — different mechanism (silent truncation, not a 500) | **no** — real defect; file a separate ticket (§12) |
| 8 | `wms2-web-ui .../internalOps/replenishment/open/cancelRequestPop.vue:63,70-72` | joined string is **display-only**; loops one dispatch per id | no | no |
| 9 | `wms2-web-ui .../receiving/open/popups/closeOpenNoticePop.vue:66,75-86` | joined string display-only; sends `{ids}` **array** | no | no |
| 10 | `wms2-web-ui .../receiving/open/popups/deleteOpenNotices.vue:48,55` | joined string display-only; passes the object list | no | no |
| 11 | `wms2-web-ui .../outbound/bol/popups/closeBolPop.vue:69,80-84` | display-only; single → `id`, multi → `bolIds` array | no — correctly handled | no |
| 12 | `wms2-api .../service/CyclecountService.java:216` (`exportCycleCount2`) | same row-builder, `ByteArrayOutputStream` variant | **zero** production callers (`grep src/main` → 0); unit-tested in the `ExportCycleCount2` nested class of `CyclecountServiceUnitTest` | no — leave in place, do not delete |
| **13** | **≥18 other unguarded numeric coercions of `@RequestBody Map` values in controllers outside `net.aim_ai.wms.controller.rest`** — the same defect *class*, since §2 proves that package is the only one `RestEndpointExceptionHandler` covers (9 of 50 controllers). Verified instances: `controller/mobile/PickingController.java:341` `Long.parseLong((String) reqMap.get("orderId"))` — a **character-for-character twin**; plus 15 `Long.valueOf((Integer) reqMap.get(...))` casts that raise `ClassCastException` (also unchecked, also pre-`try`, also a raw 500) whenever the client sends a JSON string — including **six in `CycleCountController` itself at `:153, :165, :166, :178, :179, :180`** (`itemDataView` / `locationView` / `positionView`), and in `ClubLineController:258,268,301`, `TransfersController:341,362,369`, `CycleCountLosController:207,208`, `ReceivingController:274`, `PrinterController:111` | **yes — same class** | **no.** Out of scope: none is reachable from the reported bulk-export path, and widening to a 19-site controller-input-hardening sweep would make this high-priority fix un-reviewable. **This is the honest scope boundary — the same kind PR #43 drew around L111 and that this plan is now closing.** Tracked as a §12 follow-up so the next person inherits the enumeration instead of re-deriving it |

Rows 1-5 are all visited by §5 (Fix A–D). Rows 6-12 are excluded with the rationale above.

---

## 1. Problem Statement

### Reported symptom (verbatim)

Operator opens `/internalOps/cycle-count?tab=planned` ("Planned Cycle Counts"), ticks **two or more**
row checkboxes, clicks **"Export Selected Cycle Counts"**, then **"Export File"** in the confirm
dialog. A red toast appears and no file downloads:

> **Error: Request failed due to a network or server issue. Please retry.**

Retrying never succeeds — the cause is deterministic, not transient. Selecting **exactly one** row
(either one checkbox, or the row kebab menu → Export) works.

Toast origin: `v2/wms2-web-ui/store/internalOps/cycleCount.js:213`, the `catch` of the
`exportCycleCount` action — reached only on a non-2xx or network-level failure.

### Reproduction

| # | Step |
|---|---|
| 1 | Log in to the WMS web UI for a tenant with ≥2 cycle counts that have positions (e.g. wineco: `CC000159` 33 pos, `CC000151` 33 pos) |
| 2 | Internal Ops → Cycle Count → **Planned Cycle Counts** tab |
| 3 | Tick the checkbox on **two** rows → the purple bulk bar appears ("2 items selected.") |
| 4 | Click **"Export Selected Cycle Counts"** → **"Export File"** |
| 5 | **Observed:** red toast, no download. Backend logs an unhandled `NumberFormatException`, HTTP 500. |
| 6 | **Expected:** one `CC_Multiple_<timestamp>.xlsx` containing both cycle counts |

Second, distinct reproduction (Bug 2 — no error shown at all):

| # | Step |
|---|---|
| 1 | Same screen; tick **one** row whose cycle count has **zero** positions (e.g. wineco `CC000162`) |
| 2 | Export → **Observed:** a file *does* download, named `CC000162_<timestamp>.xlsx`, but it is not a workbook — its bytes are the text `[{field=Runtime Error, message=Can not export from cycle count without positions!}]`. Excel reports a corrupt file. **No toast, no error.** |
| 3 | **Expected:** no download; an error toast naming the cycle count |

### Why this is NOT the export bug PR #43 already fixed

Archived plan
[`260610-excel-export-localdatetime-unsupported-type.md`](../../../4-Archieves/wms2/plan/260610-excel-export-localdatetime-unsupported-type.md)
fixed a `java.time` cell-type crash on **this same screen** producing **this exact toast string**
(merged as PR [#43](https://github.com/SiteBossInc/wms2-api/pull/43), 2026-06-11). It is a different
defect, and it explicitly recorded the boundary that leaves this one alive — see §3. In short:

- PR #43's site 5 was `CyclecountService.java:196` (`position.getModified()` → `UnsupportedOperationException` inside `FileExportService`).
- PR #43's Fix C added `catch (Exception)` to the export endpoints, but its §5 "Scope of the guarantee" states the guard covers **only exceptions thrown by the service call inside the `try` block** and names pre-`try` casts as out of scope.
- SBDEV-2264 was filed **2026-05-14**, before PR #43, and its bulk path was never exercised: the 260610 manual test plan row reads "Run a cycle count → Export", i.e. **single** selection.

### DB verification (wms2-wineco-dev, live via MCP, 2026-08-02)

```sql
WITH pc AS (
  SELECT c.id, c.state,
         (SELECT count(*) FROM cyclecount_position p WHERE p.cyclecount_id = c.id) AS positions
  FROM cyclecount c
)
SELECT state, count(*) AS total,
       count(*) FILTER (WHERE positions = 0) AS zero_positions,
       round(100.0 * count(*) FILTER (WHERE positions = 0) / count(*), 1) AS pct_zero
FROM pc GROUP BY state ORDER BY state;
```

| state | total | zero positions | % zero |
|---|---|---|---|
| CANCELLED | 18 | 1 | 5.6% |
| **CREATED** | **85** | **66** | **77.6%** |
| FINISHED | 59 | 0 | 0.0% |

```sql
SELECT max(positions), round(avg(positions) FILTER (WHERE positions>0),1),
       sum(positions), count(*) FILTER (WHERE positions>0) FROM pc;
→ max_positions=665   avg_nonzero=61.7   total_positions=5864   exportable_ccs=95
```

Sample of the newest 25 `cyclecount` rows — i.e. exactly the tab in the screenshot — is uniformly
`state=CREATED, type=PLANNED, subtype=SKU`, with `positions=0` on 21 of 25 and `23–39` on the rest.

**What this proves:**
1. There are ≥2 exportable cycle counts on this tenant, so Bug 1 reproduces immediately.
2. **66 of 85 (77.6%) CREATED cycle counts have zero positions** — so on the very tab where the bug
   was reported, most rows cannot produce a real export, and today that failure is *silent*
   (Bug 2). This is not an edge case.
3. `max_positions=665`, `avg_nonzero=61.7` — sizing input for the N+1 risk in §10.

---

## 2. Root Cause Analysis

### Bug 1 (the ticket) — the multi-select id string is parsed with `Long.parseLong` **before** the `try`

**Frontend — joins N ids into ONE comma-space string and sends it as a scalar `id`:**

`v2/wms2-web-ui/components/internalOps/cycleCount/exportCyclePop.vue:53-72`
```js
getExportList(selectedItems) {
  var exportList = []
  selectedItems.map((request) => { exportList.push(request.id) })
  console.log(exportList)
  return exportList.join(', ')                       // L61 → "30427858, 30427830"
},
...
async exportAction() {
  const list = this.getExportList(this.selectedItems).split(', ')
  const fileName = list.length > 1 ? 'CC_Multiple' : this.selectedItems[0].cyclecountNumber
  await this.$store.dispatch('internalOps/cycleCount/exportCycleCount',
      {id: this.getExportList(this.selectedItems), fileName: fileName})   // L71 — scalar `id`
}
```

The `'CC_Multiple'` filename branch is direct evidence that **multi-select export was intended to
produce one combined file** — the frontend was built for it; the backend contract never was.

**Backend — parses that string as a single `Long`, outside the `try`:**

`v2/wms2-api/src/main/java/net/aim_ai/wms/controller/CycleCountController.java:107-143`
```java
@PostMapping(path= "/export")
public void export(@RequestBody Map<String,Object> reqMap, HttpServletResponse response,
                   @AuthenticationPrincipal Principal principal) {
    LOG.debug("start cancel with id ={}", reqMap.toString());
    Long id = Long.parseLong((String) reqMap.get("id"));        // L111 ← NumberFormatException
//  String fileName = (String) reqMap.get("fileName");

    LOG.debug("start action unitload={}", id);
    List<Map<String, String>> errors = new ArrayList<Map<String, String>>();
    Cyclecount cycleCount = cyclecountRepository.findById(id)
        .orElseThrow(() -> new EntityNotFoundException("CycleCount", id));   // L116

    try {                                                                    // L123
        cyclecountService.exportCycleCount(response , cycleCount);            // L124
    } catch (BusinessException e) {                                          // L125
        ...
    } catch (Exception e) {                                                  // L133 (PR #43 Fix C)
        LOG.error("export failed unexpectedly: {}", e.getMessage(), e);
        ...
    }
}
```

`Long.parseLong("30427858, 30427830")` throws `NumberFormatException` at **L111**, which is
**outside** the `try` opened at L123. The `catch (Exception)` added by PR #43 therefore cannot
observe it.

**The escape to a raw 500 is proven, not assumed:**

| Advice | Scope | Handles `NumberFormatException`? |
|---|---|---|
| `exceptions/RestExceptionHandler.java:23-24` — plain `@ControllerAdvice` (**global**) | all controllers | **No.** All 13 `@ExceptionHandler` methods enumerated (`:35, 49, 64, 86, 94, 102, 110, 118, 127, 135, 144, 153`): `ApiInvalidParameterException`, `ApiConstraintViolationException`, `MethodArgumentNotValidException`, `ApiMissingUserException`, 3× SSO, `BusinessException`, `NoSuchElementException`, `EntityNotFoundException`, `ObjectOptimisticLockingFailureException`, `PessimisticLockingFailureException`. There is **no** `Exception` / `RuntimeException` handler. |
| `exceptions/RestEndpointExceptionHandler.java:36-38` — `@Order(HIGHEST_PRECEDENCE)` + `@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")` | **only** `net.aim_ai.wms.controller.rest` | Has `@ExceptionHandler(Exception.class)` at `:84`, but `CycleCountController` is in `net.aim_ai.wms.controller` — **not** `.rest` — so it is **not covered**. |

⇒ `NumberFormatException` reaches Spring's default handler → **HTTP 500**, empty body → axios
rejects → the toast at `store/internalOps/cycleCount.js:213`.

**Precision note — do not over-claim L116.** The pre-`try`
`findById(...).orElseThrow(EntityNotFoundException)` at L116 is **not** a 500 source:
`EntityNotFoundException` *is* handled by `RestExceptionHandler.java:135`, yielding a structured
`ProblemDetail`. **Only L111 produces the raw 500.**

**Why this is a plain omission, not a design gap: the correct implementation is 25 lines above it.**

`CycleCountController.java:75-104` — the `/cancel` endpoint on the **same controller**, driven by the
**same bulk bar on the same screen**, already does exactly the right thing:

```java
@PostMapping(path= "/cancel", produces = "application/json")
public ResponseEntity<Object> cancel(@RequestBody Map<String,Object> reqMap, ...) {
    ...
    String[] ids = reqMap.get("ids").toString().split(",");        // L82
    for (String id: ids) {
        Long cycleCountId = Long.parseLong(id);                    // L86 — per element
        Cyclecount cycleCount = cyclecountRepository.findById(cycleCountId)
            .orElseThrow(() -> new EntityNotFoundException("CycleCount", cycleCountId));
        try { cyclecountService.cancelCycleCount(cycleCount); }
        catch (BusinessException e) { errors.add(getErrorMessage("Runtime Error", e.getMessage())); }
    }
    ...
}
```

Bulk **cancel** works; bulk **export** does not. The `ids`-CSV convention already exists in this
controller.

**The trim trap.** `cancelCycleCountPop.vue:64` joins with `','` (**no** space), so cancel's
un-trimmed `split(",")` survives. `exportCyclePop.vue:61` joins with `', '` (**with** a space).
Any fix **must `trim()` each token** — `Long.parseLong(" 30427830")` throws too.

### Bug 2 (found while DB-verifying) — a positionless cycle count yields a silently corrupt `.xlsx`

`v2/wms2-api/src/main/java/net/aim_ai/wms/service/CyclecountService.java:154-160`
```java
public void exportCycleCount(HttpServletResponse response, Cyclecount cycleCount) throws BusinessException {
    LOG.debug("start");
    List<CyclecountPosition> ccPositions = cyclecountPositionRepository.findByCyclecountId(cycleCount.getId());
    if (ccPositions.size() == 0) {
        throw new BusinessException("Can not export from cycle count without positions!");   // L159
    }
```

The controller catches it and writes into the **same, still-200 response**
(`CycleCountController.java:125-133`):
```java
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
    try {
        response.getWriter().write(errors.toString());   // status stays 200; body = Java Map.toString()
        response.getWriter().flush();
    } catch (IOException e2) { LOG.error(e2.getMessage()); }
}
```

The store reads the response as a **blob** (`store/internalOps/cycleCount.js:196-215`), so:

1. axios **resolves** (HTTP 200) → the `catch` at :211 never runs → **no toast**;
2. `link.click()` at :206 downloads `CC000162_<ts>.xlsx` whose bytes are the text
   `[{field=Runtime Error, message=Can not export from cycle count without positions!}]`;
3. the `if (result.errors)` guard at :207 is **dead code** — `result` is a `Blob`, so
   `result.errors` is always `undefined`.

Two compounding details:
- `errors.toString()` is Java `Map.toString()` → `[{field=…, message=…}]`, which is **not valid
  JSON**. Even a UI that tried to `JSON.parse` the blob today would fail. Any fix must emit real JSON.
- **Blast radius: 66 of 85 CREATED cycle counts (77.6%)** — most rows on the reported tab.

**Response-commit safety (verified).** The first output-stream touch is
`FileExportService.java:129` (`response.getOutputStream()`), *after* the whole workbook is built in
memory; no `setHeader`/`setContentType` runs earlier in `exportExcelFile`. L159 throws before any
byte is written, so the response is **uncommitted** and a status code + JSON body can safely be set.

---

## 3. Relationship to the 260610 plan / PR #43 — a documented boundary, not a regression

There is **no regression chain**: bulk export has never worked. What exists instead is a
deliberately-recorded out-of-scope boundary that this plan now closes.

| Date | Event | Effect on this bug |
|---|---|---|
| 2026-02-18 | `6e5af846` "modernize temporal handling to use java.time" — `AbstractBaseEntity.created/modified` become `LocalDateTime` | Created the *other* cycle-count export 500 (`java.time` cells). Unrelated to id parsing. |
| **2026-05-14** | **SBDEV-2264 filed** ("bulk export does not work", screenshot toast) | The bug in this plan. Predates PR #43. |
| 2026-06-10 | Plan `260610-excel-export-localdatetime-unsupported-type.md` authored. §5 Fix C: *"Fix C guarantees no opaque 500 for exceptions thrown by the service call **inside the `try` block**… It does **not** cover code that runs **before** the `try`."* §12: *"Pre-`try` controller input exceptions still 500… Hardening controller input parsing is a separate, broader effort."* | **Explicitly excluded L111.** |
| 2026-06-11 | PR [#43](https://github.com/SiteBossInc/wms2-api/pull/43) merged: `FileExportService.setCellValue` + `java.time` branches; `catch (Exception)` on 5 export endpoints; `errors.toString()` instead of the empty `errorMap.toString()` | Fixed the `java.time` 500 **and** made single-CC export work. **Bug 1 untouched** (pre-`try`). Also *hardened* Bug 2's symptom from an empty body to a non-JSON body — still a 200, still a corrupt download. |
| 2026-08-02 | This plan | Closes L111 (Bug 1) and the 200-with-error-body contract (Bug 2) for the cycle-count export endpoint. |

Two useful consequences of PR #43 for this plan:
- **No `FileExportService` change is needed.** `setCellValue` (`:236`) already handles
  `LocalDateTime` (`:251`), so `position.getModified()` in the detailed sheet is already safe — the
  merge below is a pure row-building change.
- The repo-wide `errorMap.toString()` empty-body pattern PR #43 flagged as a follow-up remains open
  in *other* controllers; this plan does not widen to them (§12).

---

## 4. Architecture Overview

```
[Planned Cycle Counts tab]  plannedCycleCount.vue:42-58
   │  tick N checkboxes → purple bulk bar → "Export Selected Cycle Counts"
   ▼
[exportCyclePop.vue]  :53-72
   │  getExportList() → exportList.join(', ')        ← Bug 1 (frontend half)
   │  dispatch('exportCycleCount', {id: "id1, id2", fileName: 'CC_Multiple'})
   ▼
[store/internalOps/cycleCount.js]  :196-215
   │  $axios.$post('/cycleCount/export', data, {responseType: 'blob'})
   │  always builds a download link; `if (result.errors)` is dead on a Blob   ← Bug 2 (frontend half)
   │  catch → toast "Error: Request failed due to a network or server issue. Please retry."   :213
   ▼
[CycleCountController.export]  :107-143
   │  Long.parseLong((String) reqMap.get("id"))   :111  ← Bug 1  ✖ OUTSIDE the try
   │  findById(...).orElseThrow(EntityNotFoundException)  :116  (handled → ProblemDetail, NOT a 500)
   │  try { … } catch (BusinessException) → 200 + non-JSON body   :125  ← Bug 2
   │            catch (Exception)        → 200 + non-JSON body   :133  (PR #43; cannot see :111)
   ▼
[CyclecountService.exportCycleCount]  :154-214
   │  findByCyclecountId → if empty → BusinessException   :159  ← Bug 2 (server half)
   │  aggregated rows (per Itemdata)  → getExcelFile(null, "aggregated", …)   :189
   │  detailed rows (per position)    → exportExcelFile(workbook, "detailed", …, response)   :208
   │  clientRepository.findById per position (uncached N+1)   :178, :193
   ▼
[FileExportService]  :44 exportExcelFile / :138 getExcelFile / :236 setCellValue
   │  response.getOutputStream() FIRST TOUCHED at :129  → response uncommitted before this
   ▼
NumberFormatException (unhandled by either advice) → HTTP 500 → red toast
```

### Key Files

| File | Role | Anchor lines |
|---|---|---|
| `wms2-api .../controller/CycleCountController.java` | broken parse (Bug 1); error-response contract (Bug 2); `/cancel` reference impl | **111**, 116, 123-146; 75-104 |
| `wms2-api .../service/CyclecountService.java` | single-CC-only export; positionless throw; row builders; N+1 client lookups | **154-214**, 159, 178, 189, 193, 208; 216 (`exportCycleCount2`) |
| `wms2-api .../service/FileExportService.java` | cell dispatch + response commit point — **no change needed** | 44, 129, 138, 236, 251 |
| `wms2-api .../exceptions/RestExceptionHandler.java` | global advice; **no** `Exception` handler | 23-24, 118, 127, 135 |
| `wms2-api .../exceptions/RestEndpointExceptionHandler.java` | `Exception` catch-all, scoped to `.controller.rest` (excludes us) | 36-38, 84 |
| `wms2-api .../SecurityProperties.java` | `setExposedHeaders(cors.getExposedHeaders())` | 19-30, 69, 97-102 |
| `wms2-api src/main/resources/application.properties` | CORS block — **`exposed-headers` absent** | 98-101 |
| `wms2-api .../util/WmsObjectMapper.java` | `standard()` / `shared()` — already imported by the controller (`:6`, used `:62`) | 37, 51 |
| `wms2-web-ui .../cycleCount/exportCyclePop.vue` | joins ids into one string | 53-72 (61, 71) |
| `wms2-web-ui store/internalOps/cycleCount.js` | blob handler, dead error guard, toast | 196-215 (198, 206, 207, 213) |
| `wms2-web-ui .../cycleCount/planned/plannedCycleCount.vue` | bulk bar + `show-select` table | 42-70, 121, 133-141, 338-341 |
| `wms2-web-ui nuxt.config.js` | cross-origin API base URL (CORS applies) | 74-79, 156-158 |

---

## 5. Fix Design

Four fixes. **Fix A + B are the ticket** (Bug 1); **Fix B + C + D** also close Bug 2.

### Fix A — `CycleCountController.export`: tolerant id parsing, entirely inside a guarded path

**Why this shape and not alternatives.** The minimal diff — wrapping L111 in a `try` — would stop the
500 but leave bulk export non-functional (it would report "invalid id" for a legitimate
multi-selection). Copying `/cancel`'s `split(",")` verbatim would still break on the *space* that
`exportCyclePop.vue` emits. So: one parse helper that accepts **both** wire shapes, trims, dedupes,
and raises `BusinessException` (already mapped, already caught) instead of an unchecked
`NumberFormatException`.

**Before** (`CycleCountController.java:107-143`):
```java
@PostMapping(path= "/export")
public void export(@RequestBody Map<String,Object> reqMap, HttpServletResponse response,
                   @AuthenticationPrincipal Principal principal) {
    LOG.debug("start cancel with id ={}", reqMap.toString());
    Long id = Long.parseLong((String) reqMap.get("id"));                 // ← 500 vector
    List<Map<String, String>> errors = new ArrayList<Map<String, String>>();
    Cyclecount cycleCount = cyclecountRepository.findById(id)
        .orElseThrow(() -> new EntityNotFoundException("CycleCount", id));
    try {
        cyclecountService.exportCycleCount(response , cycleCount);
    } catch (BusinessException e) { … response.getWriter().write(errors.toString()); … }
      catch (Exception e)        { … response.getWriter().write(errors.toString()); … }
}
```

**After:**
```java
// NOTE: EXPORT_SKIPPED_HEADER is declared on CyclecountService (the class that writes it),
// not here — see §5 Fix B decision table for the dependency-direction rationale.

// Request Json: { ids: [1,2] }  (preferred)  |  { id: "1, 2" }  (legacy, still accepted)
@PostMapping(path= "/export")
public void export(@RequestBody Map<String,Object> reqMap, HttpServletResponse response,
                   @AuthenticationPrincipal Principal principal) {
    LOG.debug("start export with reqMap={}", reqMap);
    try {
        List<Long> ids = parseCycleCountIds(reqMap);
        List<Cyclecount> cycleCounts = new ArrayList<>(ids.size());
        for (Long id : ids) {
            cycleCounts.add(cyclecountRepository.findById(id)
                .orElseThrow(() -> new EntityNotFoundException("CycleCount", id)));
        }
        cyclecountService.exportCycleCounts(response, cycleCounts);
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
 * Trims each token (the export dialog joins with ", "), drops blanks, de-duplicates, preserves
 * selection order. Raises BusinessException — never an unchecked NumberFormatException — so the
 * caller's catch chain can render a real message instead of an opaque 500.
 */
public static List<Long> parseCycleCountIds(Map<String, Object> reqMap) throws BusinessException {
    Object raw = reqMap.get("ids") != null ? reqMap.get("ids") : reqMap.get("id");
    if (raw == null) {
        throw new BusinessException("No cycle count selected for export");
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
            throw new BusinessException("Invalid cycle count id: " + trimmed);
        }
    }
    if (ids.isEmpty()) {
        throw new BusinessException("No cycle count selected for export");
    }
    return new ArrayList<>(ids);
}

/** Writes a real JSON error body with a real status, provided nothing has been streamed yet. */
private void writeExportError(HttpServletResponse response, int status, String message) {
    if (response.isCommitted()) {
        LOG.error("cannot report export error, response already committed: {}", message);
        return;
    }
    // resetBuffer(), NOT reset(): reset() clears the response HEADERS as well as the
    // body, which would strip the Access-Control-* headers Spring Security's CorsFilter
    // has ALREADY written to this response before the controller ran — the browser would
    // then block this very error response and the operator would see the generic
    // "network or server issue" toast, i.e. exactly the bug this ticket is about.
    // resetBuffer() clears only the body buffer. See §5 Fix A decision table.
    response.resetBuffer();
    response.setStatus(status);
    response.setContentType(MediaType.APPLICATION_JSON_VALUE);
    response.setCharacterEncoding(StandardCharsets.UTF_8.name());
    try {
        // Unexpected (5xx) messages are NOT echoed to the browser — with findById now
        // inside the try, e.getMessage() can carry JDBC URLs / tenant DB names. The
        // detail stays in LOG.error at the call site.
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
| Status **422** for `BusinessException`, **404** for `EntityNotFoundException`, **500** for anything else | Genuine programming bugs keep surfacing as 5xx to monitoring; only *expected* validation outcomes become 4xx. A blanket 422 would hide real defects. |
| `EntityNotFoundException` now caught locally (it used to reach `RestExceptionHandler:135`) | Intentional: the endpoint is `void`+`HttpServletResponse`, so a locally-written JSON body is what the blob-reading store can parse uniformly. Message text is preserved (`"CycleCount not found with id: N"`). |
| **`response.resetBuffer()`, never `response.reset()`** | **Load-bearing.** CORS is wired through Spring Security's filter (`SecurityConfiguration.java:100` `.cors(...)`), so `DefaultCorsProcessor` has already physically written `Access-Control-Allow-Origin` (and `Access-Control-Expose-Headers`) onto this response before `export()` runs — its `handleInternal` ends in `response.flush()` → `ServletServerHttpResponse.writeHeaders()` → `addHeader`, without committing the response. `ServletResponse.reset()` is specified to clear "the buffer, the status code, **and the headers**", so it would strip those CORS headers, the browser would **block the error response**, axios would reject with **no `error.response`**, and `extractBlobErrorMessage` would fall through to the generic "network or server issue" toast — reproducing the exact symptom this ticket reports. `resetBuffer()` clears only the body buffer. Nothing sets `Content-Type` earlier on this path (`FileExportService` touches the response only at `:129`), so there is no stale header to clear anyway. **Test #17 guards this**; no MockMvc test can catch it incidentally because MockMvc has no `CorsFilter`. |
| 5xx messages are **not** echoed to the client | With `findById` now inside the try, `e.getMessage()` on an unexpected failure can carry JDBC URLs / tenant DB names. 4xx (validation) messages are operator-actionable and are passed through; 5xx returns a fixed string and keeps the detail in `LOG.error(..., e)`. |
| `WmsObjectMapper.standard()` (not `.shared()`) | The controller already uses `standard()` at `:62` — stay consistent, and avoid mutating a shared mapper's config. |
| `parseCycleCountIds` is **`public static`**, not package-private | **Corrected in review.** An earlier draft specified package-private "directly unit-testable" — but `CycleCountController` is in `net.aim_ai.wms.controller` while `CycleCountControllerUnitTest` is in `net.aim_ai.wms.unit.controller`, and **zero** test classes in this repo live in the production controller package (`grep -rl '^package net.aim_ai.wms.controller;' src/test` → 0). Package-private would make the named test for scenarios #11/#12 **fail to compile**. `public static` keeps it directly testable; it is a pure function with no state, so widening visibility costs nothing. |
| De-dup via `LinkedHashSet` | The UI can't currently send duplicates, but a duplicated id would otherwise double rows in the merged sheet. |
| Do **not** touch `/cancel` (§0 row 6) | Out of scope; it works. Harmonising its `split` would be an unrelated behaviour change. |

### Fix B — `CyclecountService.exportCycleCounts`: merge N cycle counts, skip positionless ones

**Signature (new), single-CC path preserved byte-identically:**

```java
/** Header carrying the numbers of cycle counts omitted from a bulk export (no positions). */
public static final String EXPORT_SKIPPED_HEADER = "X-Export-Skipped-Cycle-Counts";

public void exportCycleCounts(HttpServletResponse response, List<Cyclecount> cycleCounts)
        throws BusinessException {
    if (cycleCounts == null || cycleCounts.isEmpty()) {
        throw new BusinessException("No cycle count selected for export");
    }
    // Single selection keeps the legacy columns/sheets EXACTLY — see §12 decision 4.
    if (cycleCounts.size() == 1) {
        exportCycleCount(response, cycleCounts.get(0));
        return;
    }
    … merged path …
}
```

`exportCycleCount(HttpServletResponse, Cyclecount)` (`:154`) stays **unchanged**, so its 8 existing
tests at `CyclecountServiceUnitTest.java:339-556` pass unmodified and a one-row selection produces
today's file. `exportCycleCount2` (`:216`) is likewise untouched (§0 row 12).

**Merged path:**
```java
    Map<Cyclecount, List<CyclecountPosition>> positionsByCc = new LinkedHashMap<>();
    List<String> skipped = new ArrayList<>();
    for (Cyclecount cc : cycleCounts) {
        List<CyclecountPosition> positions = cyclecountPositionRepository.findByCyclecountId(cc.getId());
        if (positions.isEmpty()) {
            skipped.add(cc.getNumber());
        } else {
            positionsByCc.put(cc, positions);
        }
    }
    if (positionsByCc.isEmpty()) {
        throw new BusinessException("Can not export from cycle count without positions: "
                + String.join(", ", skipped));
    }
    if (!skipped.isEmpty()) {
        // Set BEFORE any byte is streamed (FileExportService.java:129 is the commit point).
        response.setHeader(EXPORT_SKIPPED_HEADER, String.join(",", skipped));
    }

    // Client lookups are NOT cached (unlike itemdataService.getById) — memoize per export.
    Map<Long, Client> clientCache = new HashMap<>();

    // --- aggregated sheet: per cycle count, per Itemdata -----------------------
    List<Object[]> rows = new ArrayList<>();
    for (Map.Entry<Cyclecount, List<CyclecountPosition>> e : positionsByCc.entrySet()) {
        Map<Itemdata, Integer[]> itemDataIntegerMap = new LinkedHashMap<>();
        for (CyclecountPosition position : e.getValue()) {
            Itemdata itemData = itemdataService.getById(position.getItemdataId());
            Integer[] amounts = itemDataIntegerMap.get(itemData);
            if (amounts == null) {
                itemDataIntegerMap.put(itemData, new Integer[]{
                        position.getAmountbefore().intValue(), position.getAmountafter().intValue()});
            } else {
                amounts[0] += position.getAmountbefore().intValue();
                amounts[1] += position.getAmountafter().intValue();
            }
        }
        for (Map.Entry<Itemdata, Integer[]> entry : itemDataIntegerMap.entrySet()) {
            Client client = client(clientCache, entry.getKey().getClientId());
            rows.add(new Object[]{
                e.getKey().getNumber(),                 // ← NEW leading "Cycle Count" column
                client.getClNr(), client.getName(),
                entry.getKey().getItemNr(), entry.getKey().getName(),
                entry.getValue()[0], entry.getValue()[1]});
        }
    }
    String[] headerNames = new String[]{"Cycle Count", "Client Name", "Client ID",
            "SKU ID", "SKU Name", "Amount before", "Amount after"};
    Workbook workbook = fileExportService.getExcelFile(null, "aggregated", null, headerNames, rows, null);

    // --- detailed sheet: per cycle count, per position -------------------------
    rows = new ArrayList<>();
    for (Map.Entry<Cyclecount, List<CyclecountPosition>> e : positionsByCc.entrySet()) {
        for (CyclecountPosition position : e.getValue()) {
            Itemdata itemData = itemdataService.getById(position.getItemdataId());
            Client client = client(clientCache, itemData.getClientId());
            rows.add(new Object[]{
                e.getKey().getNumber(),                 // ← NEW leading "Cycle Count" column
                position.getNumber(), position.getModified(),
                client.getClNr(), client.getName(),
                itemData.getItemNr(), itemData.getName(),
                position.getAmountbefore().intValue(), position.getAmountafter().intValue(),
                position.getComment()});
        }
    }
    headerNames = new String[]{"Cycle Count", "Position", "Date", "Client Name", "Client ID",
            "SKU ID", "SKU Name", "Amount before", "Amount after", "Comment"};
    fileExportService.exportExcelFile(workbook, "detailed", null, headerNames, rows, response);
```

with
```java
private Client client(Map<Long, Client> cache, Long clientId) {
    return cache.computeIfAbsent(clientId, id -> clientRepository.findById(id)
            .orElseThrow(() -> new EntityNotFoundException("Client", id)));
}
```

Wrap the merged body in the same `try { … } catch (IOException e) { throw new BusinessException("create file failed: " + e.getMessage()); }` as `:209-211`.

**Deliberate decisions inside Fix B:**

| Decision | Rationale |
|---|---|
| Aggregation stays **per cycle count** (not global per SKU) | Matches the approved output: a SKU appearing in two selected cycle counts yields one row per cycle count, so `Amount before/after` stay attributable. A global aggregate would silently merge counts from different count events. |
| `LinkedHashMap` for both maps | Preserves selection order (outer) and first-seen SKU order (inner) → deterministic output, so a golden-file assertion is stable. This matters more than it looks: `AbstractBaseEntity.hashCode()` (`:78-82`) returns `getClass().hashCode()` — a **constant** for every instance (deliberately, so an id going `null→Long` on persist can't corrupt a map) — and `Itemdata` (`:225-226`) overrides it the same way. So today's `HashMap` at `:163` is a **single-bucket** map that treeifies past 8 entries using identity-hash tie-breaking, which is exactly why current output order is arbitrary. `LinkedHashMap` genuinely fixes it. |
| The inner itemdata map stays **scoped inside** the per-cycle-count loop | **Load-bearing, do not "optimise" by hoisting it.** Because `hashCode()` is constant (row above), lookups are O(n) within a single bucket. Scoped per cycle count, n ≤ that CC's position count (max 665 observed → negligible). Hoisted to span the whole selection, cost grows quadratically in *total* positions. |
| Service (not controller) sets the skipped header, and **`EXPORT_SKIPPED_HEADER` lives on `CyclecountService`**, not the controller | The header must be set before `exportExcelFile` streams, and the service already owns this response — it streams the workbook into it — so setting one header on it is not a new layering break. Declaring the constant on the **service** keeps the dependency arrow pointing one way; a `service → CycleCountController.EXPORT_SKIPPED_HEADER` reference would have no precedent anywhere under `service/`. **Correction:** an earlier draft justified the single-method shape by claiming a two-phase split "would double the position queries" — that is **false**, since a planning call can return the positions it already fetched. The honest reason is below. |
| Single method rather than a two-phase `planExport(...)` / `writeExport(...)` seam | The two-phase seam (considered, see §13 alternatives) is genuinely cleaner on layering and query-neutral for the multi path, but the single-CC path must delegate to the untouched legacy `exportCycleCount` to guarantee byte-identity by construction — and that method re-queries positions, so the seam costs one extra `findByCyclecountId` on the **most common** path, or forces duplicating the legacy row builder (defeating the byte-identity guarantee). Rejected on that specific trade, not on layering grounds. |
| Header value joined with `","`, no space | Symmetric with `/cancel`'s wire format and trivially `split(',')`-able in JS. Cycle count numbers (`CC000159`) contain no commas. |
| `String.join(", ")` **with** space in the *error message* | It is human-facing prose in a toast, not a machine-parsed list. |
| Positionless CCs skipped, not failed (multi) | Approved decision 3 (§12). With 77.6% of CREATED rows empty, all-or-nothing would make "select all → export" useless. |
| Single-CC positionless still **fails** (via unchanged `exportCycleCount`) | Skipping the only selected item would download an empty workbook — strictly worse than a clear error. Fix A now renders it as a 422 with the real message. |

### Fix C — expose the skipped-CC header through CORS (**required**, not optional)

The UI is **cross-origin in every deployed environment** (`wms.wineco.dev.sbo.li` →
`wms-api.wineco.dev.sbo.li`; `nuxt.config.js:156-158` `browserBaseURL: process.env.API_BASE_URL`).
`SecurityProperties.getCorsConfiguration()` calls `setExposedHeaders(cors.getExposedHeaders())`
(`SecurityProperties.java:24`), but `rest.security.cors.exposed-headers` is **absent** from
`application.properties` (which defines only lines 98-101: `allowed-origin-patterns`,
`allowed-headers`, `allowed-methods`, `max-age`) and is overridden **nowhere** in the repo
(`grep -rn 'exposed-headers\|exposedHeaders'` → only the `SecurityProperties` field itself).

⇒ Without this fix, `X-Export-Skipped-Cycle-Counts` is set by the server but **invisible to the
browser**, and the skipped-CC toast silently never fires. `allowed-headers=*` does **not** help —
that governs *request* headers.

**After** (`application.properties`, adjacent to the existing CORS block at 98-101):
```properties
# Response headers the browser is allowed to read (CORS). X-Export-Skipped-Cycle-Counts
# carries the cycle counts omitted from a bulk export — see SBDEV-2632.
rest.security.cors.exposed-headers=X-Export-Skipped-Cycle-Counts
```

**Plus a code-level guarantee, so this stops being an un-assertable deployment prerequisite.** The
property alone is overridable by `REST_SECURITY_CORS_EXPOSED_HEADERS` (Spring relaxed binding means
an env var beats the property file), and the GitLab CI / k8s manifests live outside this repo — so a
property-only fix leaves the whole skipped-CC feature resting on an environment fact no test can
check. `SecurityConfiguration.corsConfigurationSource()` (`:150-156`) is a single choke point:

```java
@Bean
public CorsConfigurationSource corsConfigurationSource() {
    UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
    if (null != securityProperties.getCorsConfiguration()) {
        CorsConfiguration configuration = securityProperties.getCorsConfiguration();
        // Additive and override-proof: this header must be readable by the browser for the
        // bulk-export skipped-cycle-count notice, regardless of environment config (SBDEV-2632).
        configuration.addExposedHeader(CyclecountService.EXPORT_SKIPPED_HEADER);
        source.registerCorsConfiguration("/**", configuration);
    }
    return source;
}
```

`addExposedHeader` **appends**, so it composes with (rather than replaces) whatever the property or an
env override supplies. The property in `application.properties` is retained as documentation of
intent and as the mechanism for any *future* exposed header. This converts §5.1 row 3 from
"deployer must confirm" into a change the verify script and the existing `SecurityConfigurationTest`
can both gate.

### Fix D — web UI: send `ids`, read the header, surface the real error

**D1 — `exportCyclePop.vue` sends a typed array** (backend accepts both, so this can ship in either order):

**Before** (`:71`):
```js
await this.$store.dispatch('internalOps/cycleCount/exportCycleCount',
    {id: this.getExportList(this.selectedItems), fileName: fileName})
```
**After:**
```js
const ids = this.selectedItems.map((request) => request.id)
const fileName = ids.length > 1 ? 'CC_Multiple' : this.selectedItems[0].cyclecountNumber
await this.$store.dispatch('internalOps/cycleCount/exportCycleCount', { ids, fileName })
```
`getExportList()` is retained — it still renders the confirmation sentence ("Are you sure you want
to export Cycle Count: …", `:18`) — but is no longer the source of the request payload.

**There are TWO payload-shaped occurrences, not one — both must go.** `grep -n getExportList` returns
5 hits; the two that build a `{id: …}` object are:

| Line | Occurrence | Action |
|---|---|---|
| `:68` | `console.log('cycle count to export:', {id: this.getExportList(this.selectedItems)})` | **Delete the whole line.** Easy to miss — it is a log, not the request — but it matches the same `{id: this.getExportList(` shape, so leaving it makes verify row `D1-no-scalar` **FAIL** on otherwise-correct code. |
| `:71` | the `dispatch` payload | Replace per the After-block above |
| `:60` | `console.log(exportList)` inside `getExportList` | Delete while here (noise; not payload-shaped) |
| `:69` | `const list = …split(', ')` | Superseded — `ids.length` replaces it |

**D2 — `store/internalOps/cycleCount.js:196-215`: switch to `post` (headers), gate the download, parse the error blob**

**Before:**
```js
const result = await this.$axios.$post('/cycleCount/export', data, {responseType: 'blob'})
const url = URL.createObjectURL(new Blob([result], { type: 'application/vnd.ms-excel' }))
… link.click()
if (result.errors) { this.$toast.error(…) }        // dead on a Blob
} catch(error) { this.$toast.error('Error: Request failed due to a network or server issue. Please retry.') }
```
**After:**
```js
async exportCycleCount(context, data) {
  try {
    const response = await this.$axios.post('/cycleCount/export', data, { responseType: 'blob' })
    const url = URL.createObjectURL(new Blob([response.data], { type: 'application/vnd.ms-excel' }))
    const link = document.createElement('a')
    link.href = url
    const time = this.$moment().format('_YYYY-MM-DD_HH-mm-ss')
    link.setAttribute('download', data.fileName + time + '.xlsx')
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    URL.revokeObjectURL(url)
    const skipped = response.headers['x-export-skipped-cycle-counts']
    if (skipped) {
      this.$toast.error(
        `Skipped ${skipped.split(',').length} cycle count(s) with no positions: ${skipped.split(',').join(', ')}`)
    }
  } catch (error) {
    console.log(error)
    this.$toast.error(await extractBlobErrorMessage(error))
  }
},
```
with a small shared helper (same file, or `util/commonUtility.js` if reused later):
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

**Deliberate decisions inside Fix D:**

| Decision | Rationale |
|---|---|
| Header read via the **lower-cased** key `'x-export-skipped-cycle-counts'` | axios normalises response header names to lower case; reading the mixed-case `'X-Export-Skipped-Cycle-Counts'` returns `undefined`. |
| The download link is only built on a 2xx | Non-2xx now rejects, so no corrupt file is ever written — the core of Bug 2. |
| Skipped notice uses `$toast.error` (not `success`) | It reports data the operator asked for and did not get; a success-styled toast reads as "all good". |
| Generic toast **retained as a fallback** | A genuine network failure (no `error.response`) must still say something; only a parseable body upgrades the message. |
| `revokeObjectURL` + `removeChild` added | Pre-existing leak in the same lines; free to fix while rewriting them. Not a behaviour change. |

---

## 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | **N/A** | — | Pure code + config fix. No schema change, no Flyway migration, no seed row. The current highest `V2.2.*` is untouched. |
| 2 | **Feature flags / system properties** | **N/A** | — | No sysprop read or added. Behaviour change is unconditional (a 500 today has no "working" mode worth preserving behind a flag). |
| 3 | **Config / env changes** | **REQUIRED, but now code-guaranteed** — Fix C makes two changes: `addExposedHeader(CyclecountService.EXPORT_SKIPPED_HEADER)` in `SecurityConfiguration.corsConfigurationSource()` (`:150-156`), **plus** `rest.security.cors.exposed-headers=X-Export-Skipped-Cycle-Counts` in `application.properties` | dev | The `addExposedHeader` call is **additive and override-proof**, so no deployer action is required and the prerequisite is gated by the verify script instead of by trust. The property is retained for intent/documentation. *Previously this row read "deployer must confirm no env var sets `REST_SECURITY_CORS_EXPOSED_HEADERS`" — that was the plan's only un-assertable prerequisite and review replaced it with code.* |
| 4 | **Deploy-order dependencies** | **None (by design)** | — | The API accepts **both** `{id:"1, 2"}` and `{ids:[…]}`, so api-before-ui and ui-before-api both work. Recommended order is api → ui (§7) only so the fix is observable as soon as the UI ships. |
| 5 | **Data migration** | **N/A** | — | No data is read or written differently; export is read-only. |
| 6 | **External systems** | **N/A** | — | No OMS / printer / Keycloak interaction on this path. |
| 7 | **Access / permissions** | **N/A** | — | Endpoint authority unchanged (`/v3/cycleCount/export` keeps its existing `SecurityConfiguration` rule). No new role. |
| 8 | **Monitoring / alerts** | **Optional** | dev | Cycle-count export 500s currently surface only as unhandled-exception log lines. A counter is not added here (§11 row 8); if desired, file it with the §12 follow-up. Post-deploy, grep app logs for `export failed unexpectedly` — it should be absent for the bulk path. |

---

## 6. File Change Summary

### `v2/wms2-api`

| File | Fix | Change Type | Description |
|---|---|---|---|
| `controller/CycleCountController.java` | A | Modify | Add `parseCycleCountIds` (**`public static`** — see §5 Fix A: package-private would not compile from the test package) and `writeExportError` (**`resetBuffer()`**, not `reset()`); rewrite `export()` so **all** parsing/lookup happens inside the try; status-differentiated catches (422/404/500) writing real JSON. `EXPORT_SKIPPED_HEADER` goes on `CyclecountService`, **not** here |
| `service/CyclecountService.java` | B | Modify | Add `exportCycleCounts(HttpServletResponse, List<Cyclecount>)` (merged sheets + `Cycle Count` column + skip-empties + skipped header) and the private `client(...)` memo helper. `exportCycleCount` and `exportCycleCount2` **unchanged** |
| `src/main/resources/application.properties` | C | Modify | Add `rest.security.cors.exposed-headers=X-Export-Skipped-Cycle-Counts` |
| `SecurityConfiguration.java` | C | Modify | `corsConfigurationSource()` (`:150-156`) — `addExposedHeader(CyclecountService.EXPORT_SKIPPED_HEADER)`, additive and override-proof |
| `test/.../unit/controller/CycleCountControllerUnitTest.java` | A | Modify | New export cases 1-2, 6-7, 9-10 (§8) — the class currently has **zero** export tests |
| `test/.../unit/service/CyclecountServiceUnitTest.java` | B | Modify | New `exportCycleCounts` cases 3-5, 8, 11-12 (§8). Existing 8 `exportCycleCount` tests must remain **unmodified** |

### `v2/wms2-web-ui`

| File | Fix | Change Type | Description |
|---|---|---|---|
| `components/internalOps/cycleCount/exportCyclePop.vue` | D1 | Modify | Send `{ ids: [...], fileName }`; keep `getExportList` for the confirmation text only; drop the `console.log` |
| `store/internalOps/cycleCount.js` | D2 | Modify | `$post` → `post`; download only on 2xx; read `x-export-skipped-cycle-counts` → toast; `extractBlobErrorMessage` on failure |
| `test/store/internalOps/cycleCount.spec.js` | D2 | **Add** | New store tests (§8 cases 13-15 + the no-download assertion); no cycle-count spec exists today. Must include the H3 `URL.createObjectURL` / `revokeObjectURL` / `$moment` stubs |
| `test/components/internalOps/cycleCount/exportCyclePop.spec.js` | D1 | **Add** | New component spec for §8 case 16 (payload shape). Without this, #16 has no test file, no method, and no verify row |

---

## 7. Implementation Steps

### 7.1 Ordering rationale

Fix A is the only change that stops the 500, and it is independent of the UI (the tolerant parse
accepts today's payload verbatim). So **the api PR alone fixes the reported bug** — the ui PR is a
contract cleanup plus the Bug 2 UX. Commits are ordered so the 500 fix is first and independently
revertable, and so Fix C (a one-line property) can be reverted without touching code if a
deployment env turns out to override it.

### 7.2 Implementation Checklist (atomic commits)

**Repo `v2/wms2-api`** — branch `feature/SBDEV-2632-cycle-count-bulk-export` off freshly-fetched `origin/develop`:

- [ ] **Commit 1 (Fix A):** `CycleCountController` — `parseCycleCountIds`, `writeExportError`, `EXPORT_SKIPPED_HEADER`, rewritten `export()` with everything inside the try and status-differentiated catches. *Stops the 500 on its own.*
- [ ] **Commit 2 (Fix B):** `CyclecountService.exportCycleCounts` + `client(...)` memo. `exportCycleCount` / `exportCycleCount2` byte-untouched (`git diff` must show no hunk inside `:154-276`).
- [ ] **Commit 3 (Fix C):** `application.properties` — `rest.security.cors.exposed-headers`. One line, independently revertable.
- [ ] **Commit 4 (tests):** `CycleCountControllerUnitTest` + `CyclecountServiceUnitTest` cases per §8, **including test #17** (CORS headers survive the error path — the only guard against the `reset()` trap). Confirm the 8 pre-existing `exportCycleCount` tests are unedited.
- [ ] ⚠️ **`CycleCountControllerUnitTest` is `@Nested`-structured.** Never narrow to `-Dtest='CycleCountControllerUnitTest#someMethod'` — Surefire **silently no-ops** on `@Nested` classes and reports a **false green**. Always run the bare class name.
- [ ] `mvn clean compile` (catches DI/compile drift the unit tests miss).
- [ ] `mvn test -Dtest=CycleCountControllerUnitTest`, `-Dtest=CyclecountServiceUnitTest`, then the full `mvn test`.
- [ ] **Revert the `archunit_store` mutation** that `mvn test` writes into the tracked file before committing.
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2632-…sh` → `0 fail`.

**Repo `v2/wms2-web-ui`** — branch `feature/SBDEV-2632-cycle-count-bulk-export` off `origin/develop`:

- [ ] **Commit 5 (Fix D1):** `exportCyclePop.vue` → `{ ids, fileName }`.
- [ ] **Commit 6 (Fix D2):** `store/internalOps/cycleCount.js` → `post`, header read, `extractBlobErrorMessage`, download only on 2xx.
- [ ] **Commit 7 (tests):** `test/store/internalOps/cycleCount.spec.js`.
- [ ] `node_modules/.bin/jest --testPathPattern=cycleCount` (no `yarn` on PATH — use the nvm node binary).
- [ ] Verify script → `0 fail` with both roots set.
- [ ] Two PRs into `develop`, cross-linked; merge api first (see §7.1).

---

## 8. Testing Plan

**H2 / Testcontainers note.** Every new test is a **pure unit test** — `parseCycleCountIds` is
`public static`, `CyclecountService` is constructed with mocked repositories, and the controller test
extends **`BaseControllerUnitTest`** (standalone MockMvc via `setupMockMvc(controller)`; it wires a
`MockPrincipalArgumentResolver`, so `@AuthenticationPrincipal Principal` resolves). **No H2 and no
Testcontainers scope**, so the broken v2 IT harness (SBDEV-2217) does not block this plan.

> There is **no** class named `BaseControllerUnitTest` in this repo — the class is `BaseControllerUnitTest`.

**Harness obligations the gate MUST satisfy (verified by probing the repos, not assumed):**

| # | Obligation | Why — measured, not guessed |
|---|---|---|
| **H0** | **Merged-workbook content is asserted through the ENDPOINT with a real `CyclecountService`** (mocked repos + mocked `FileExportService`, `ArgumentCaptor` on the captured headers/rows), living in `CycleCountControllerUnitTest$BulkExportWorkbookContent` — **not** in `CyclecountServiceUnitTest`. | Added by the TDD gate (2026-08-02). Asserting merge behaviour from `CyclecountServiceUnitTest` requires the not-yet-existing `exportCycleCounts` signature, so those tests would fail at **javac**, not at an assertion — broken scaffolding rather than a gate. Driving the existing endpoint keeps every assertion expressible with today's signatures, so the suite compiles now and fails on behaviour. Verify row `T-svc-cases` accepts either location. |
| H1 | **Scenarios #4, #17 are direct controller invocations**, not MockMvc: `controller.export(reqMap, response, null)` with a `MockHttpServletResponse`. | MockMvc gives no handle to pre-seed response headers before the handler runs, which #17 requires. `MockHttpServletResponse.reset()` clears headers while `resetBuffer()` does not, so the test has real teeth once written this way. |
| H2 | **`CyclecountService` tests must assert via `ArgumentCaptor`**, not by inspecting bytes. | `fileExportService` is `@Mock` in `CyclecountServiceUnitTest`, so **no test in that class ever produces xlsx bytes**. Existing export tests assert only `verify(fileExportService).getExcelFile(any(), eq("aggregated"), any(), any(), any(), any())` — there is no in-class precedent for asserting header or row content, so the captor approach must be stated rather than left to be invented. |
| H3 | **The web-ui store spec MUST stub `URL.createObjectURL` / `URL.revokeObjectURL`** — e.g. `global.URL.createObjectURL = jest.fn(() => 'blob:mock')` — plus a `$moment` stub on `thisArg`. | **Probed on this repo:** jest 27.4.4 → jsdom 16.7.0, no `setupFiles` in `jest.config.js`; `URL.createObjectURL` is **`undefined`**. Without the stub, `exportCycleCount` throws inside its own `try`, control lands in the `catch`, and the **generic** toast fires — so #13 fails for a misleading reason and **#15 would pass for the wrong reason**, i.e. a false green of exactly the kind this plan's §9.1 warns about. |
| H4 | **#14 must supply `error.response.data` as `{ text: () => Promise.resolve(json) }`**, not a real `Blob`. | **Probed:** `Blob.prototype.text` is **`undefined`** in jsdom 16.7. With a real Blob, `typeof data.text === 'function'` is false, `extractBlobErrorMessage` falls through to the generic message, and #14 cannot pass. Consequence recorded in §12: the real-browser `Blob.text()` path is never exercised by CI. |
| H5 | **Follow the established store-spec call style**: `actions.exportCycleCount.call(thisArg, context, payload)` with `$axios` / `$toast` mocked on `thisArg`. | Existing precedent to copy: `test/store/internalOps/replenishments.spec.js:29,46,58`. |
| H6 | **Pass a real `MockHttpServletResponse`, never `null`, to `exportCycleCounts`.** | Every existing test calls `exportCycleCount(null, testCyclecount)`. Copying that convention into the merged path NPEs at `response.setHeader(...)` on the skip branch. |
| H7 | **Preserve the existing 4-space indentation** of the store action's closing `},`. | Verify rows `D2-no-dead` / `D2-no-dollar` scope the action with `awk '/async exportCycleCount\(/,/^    \},/'`. Re-indenting makes the range run to EOF, where *other* actions legitimately use `$axios.$post` and `if (result.errors)` — permanently unsatisfiable negatives. (§5's After-blocks are shown at column 0 for readability.) |

### Test scenarios (the 10 TDD-gate acceptance criteria, plus 7 derived cases — 17 total)

| # | Scenario | Steps | Expected Result |
|---|---|---|---|
| 1 | Bulk export, legacy comma-**space** payload | `POST /v3/cycleCount/export` `{"id":"<idA>, <idB>"}`, both CCs with positions | **200**, xlsx bytes; both CCs' rows present; `Cycle Count` column = each `cyclecount.number` |
| 2 | Bulk export, new array payload | same with `{"ids":[idA,idB]}` | Identical result to #1 (tolerant parse, both shapes) |
| 3 | Single selection produces today's shape | `{"id":"<idA>"}` | **"Byte-identical" holds *by construction*, not by byte comparison** — the legacy method is not edited and `size()==1` delegates to it. A byte assertion is impossible anyway (POI embeds `docProps/core.xml dcterms:created`) and `fileExportService` is a `@Mock`, so no test in this class produces bytes. Assert instead, all three: (i) `verify(...)` that the single-CC call delegates to the legacy path; (ii) `ArgumentCaptor<String[]>` equality against the literal legacy arrays — `{"Client Name","Client ID","SKU ID","SKU Name","Amount before","Amount after"}` for `aggregated` and `{"Position","Date","Client Name","Client ID","SKU ID","SKU Name","Amount before","Amount after","Comment"}` for `detailed`, i.e. **no** `Cycle Count` element; (iii) `git diff` shows no hunk inside the legacy method |
| 4 | Mixed selection, one CC positionless | `{"ids":[idWithPos, idEmpty]}` | **200** + workbook containing **only** `idWithPos`; response header `X-Export-Skipped-Cycle-Counts: CC000162` |
| 5 | All selected CCs positionless | `{"ids":[idEmpty1, idEmpty2]}` | **non-2xx (422)** + JSON body naming both; **zero** xlsx bytes written (regression test for the corrupt download) |
| 6 | Non-numeric token | `{"id":"abc"}` and `{"id":"1, abc"}` | **4xx (422)** with a structured JSON body — **never 500** (direct Bug 1 regression test) |
| 7 | Missing / empty selection | `{}`, `{"id":""}`, `{"ids":[]}` | **4xx (422)**, not 500 (today `parseLong(null)` throws → 500) |
| 8 | Pre-existing service tests unmodified (**procedural check, not a test case**) | `git diff` on `CyclecountServiceUnitTest.java` — identified **by method name, not line range**, because this commit *adds* tests to the same file and every range shifts | The **6** existing `exportCycleCount` test methods (at old-file lines 343, 372, 482, 494, 515, 541) are unmodified and pass. **Corrected in review:** an earlier draft said "8 tests at `:339-556`" — that range spans 12 tests, 6 of which are the `Edge Cases` nested class (`384-459`) covering create/cancel, not export |
| 9 | Unknown id | `{"ids":[999999999]}` | **404** + JSON body `CycleCount not found with id: 999999999` |
| 10 | Targeted suites green | `mvn test -Dtest=CyclecountServiceUnitTest`, `-Dtest=CycleCountControllerUnitTest` | BUILD SUCCESS |
| 11 | Duplicate ids de-duplicated | `{"ids":[idA, idA]}` | Rows for `idA` appear **once** |
| 12 | Selection order preserved **at the service layer** | `exportCycleCounts(response, List.of(ccB, ccA))` | `ccB`'s rows precede `ccA`'s in **both** sheets, and within a cycle count SKUs follow first-seen order. Asserted with `ArgumentCaptor<List<Object[]>>` on `getExcelFile` / `exportExcelFile`, inspecting `row[0]`. **This is a `CyclecountServiceUnitTest` case, not the controller parse test** — the parse helper only proves *id* order, and the `LinkedHashMap` decision (§5 Fix B) is the thing that actually needs a guard, since `AbstractBaseEntity.hashCode()` is constant and today's `HashMap` yields arbitrary order |
| 13 | Store: skipped header → toast | mock a 200 + `x-export-skipped-cycle-counts: CC1,CC2` | `$toast.error` called naming `CC1, CC2`; download still triggered |
| 14 | Store: JSON error blob → real message | mock a 422 whose blob body is `{"errors":[{"field":"Runtime Error","message":"Can not export…"}]}` | toast shows **that** message, not the generic one; **no** download link created |
| 15 | Store: network failure → generic toast | mock a rejection with no `error.response` | generic "network or server issue" toast (fallback preserved) |
| 16 | Pop sends a typed array | invoke `exportAction` with 2 selected items | dispatch payload `{ ids: [idA, idB], fileName: 'CC_Multiple' }` |
| **17** | **Error path must not clear CORS headers** | pre-seed a `MockHttpServletResponse` with `Access-Control-Allow-Origin: https://wms.example` (and `Access-Control-Expose-Headers`), then drive `export()` down the 422 path | **both headers survive** the error response. This is the only guard against the `reset()`/`resetBuffer()` trap in §5 Fix A — MockMvc has no `CorsFilter`, so **no other test in this plan can catch it**, and the failure mode is invisible until a real browser hits a real origin |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `CycleCountControllerUnitTest` | `export_withCommaSpaceSeparatedIds_exportsAllSelected` | #1 — service receives **both** `Cyclecount`s |
| `CycleCountControllerUnitTest` | `export_withIdsArray_exportsAllSelected` | #2 |
| `CycleCountControllerUnitTest` | `export_withNonNumericId_returns422NotServerError` | #6 — **the ticket's regression test** |
| `CycleCountControllerUnitTest` | `export_withMissingSelection_returns422` | #7 |
| `CycleCountControllerUnitTest` | `export_withUnknownId_returns404WithMessage` | #9 |
| `CycleCountControllerUnitTest` | `export_whenServiceThrowsBusinessException_writesJsonErrorBodyAndNoXlsx` | #5 at the controller layer; body parses as JSON |
| `CycleCountControllerUnitTest` | `parseCycleCountIds_trimsDedupesAndPreservesOrder` | #11, #12 (direct static-helper test) |
| `CycleCountControllerUnitTest` | `export_onError_preservesPreExistingCorsHeaders` | **#17** — asserts `resetBuffer()` semantics, i.e. `Access-Control-*` headers set before the controller ran are still present on the 422 |
| `CyclecountServiceUnitTest` | `exportCycleCounts_withTwoCycleCounts_addsCycleCountColumnAndMergesRows` | #1 header + row content at the service layer |
| `CyclecountServiceUnitTest` | `exportCycleCounts_withSingleCycleCount_delegatesToLegacyExportUnchanged` | #3 — legacy headers, no `Cycle Count` column |
| `CyclecountServiceUnitTest` | `exportCycleCounts_withOnePositionlessCycleCount_skipsItAndSetsHeader` | #4 — header set, skipped CC absent from rows |
| `CyclecountServiceUnitTest` | `exportCycleCounts_withAllPositionlessCycleCounts_throwsBusinessExceptionNamingThem` | #5 — message contains both numbers; `exportExcelFile` **never** invoked |
| `CyclecountServiceUnitTest` | `exportCycleCounts_reusesClientLookupAcrossPositions` | Fix B memo — `clientRepository.findById` invoked **once** per distinct client, not per position |
| `test/store/internalOps/cycleCount.spec.js` | `exportCycleCount_withSkippedHeader_showsSkippedToast` | #13 |
| `test/store/internalOps/cycleCount.spec.js` | `exportCycleCount_withJsonErrorBlob_showsServerMessage` | #14 |
| `test/store/internalOps/cycleCount.spec.js` | `exportCycleCount_withNetworkError_showsGenericToast` | #15 |
| `test/store/internalOps/cycleCount.spec.js` | `exportCycleCount_onError_doesNotCreateDownloadLink` | #14 (no corrupt download) — assert `URL.createObjectURL` (the H3 stub) was **not** called |
| `CyclecountServiceUnitTest` | `exportCycleCounts_preservesSelectionAndSkuOrder` | **#12** — `ArgumentCaptor<List<Object[]>>`, `row[0]` order across both sheets (guards the `LinkedHashMap` decision) |
| **`test/components/internalOps/cycleCount/exportCyclePop.spec.js`** (**new file**) | `exportAction_dispatchesIdsArrayAndMultipleFileName` | **#16** — `ExportCyclePop.methods.exportAction.call(thisArg)` with `CommUtil.showPageSpinner`/`hidePageSpinner` stubbed (called at `:67`/`:73`) and `$store.dispatch` mocked; asserts the payload is `{ ids: [idA, idB], fileName: 'CC_Multiple' }`. `@vue/test-utils ^1.3.0` is available if a full mount is preferred |

### Test commands

```bash
# wms2-api  (SDKMAN PATH needed: export PATH="$HOME/.sdkman/candidates/maven/current/bin:$PATH")
mvn clean compile
mvn test -Dtest=CycleCountControllerUnitTest
mvn test -Dtest=CyclecountServiceUnitTest
mvn test                      # full suite before the PR leaves the branch

# wms2-web-ui  (no yarn on PATH; use the nvm node binary)
node_modules/.bin/jest --testPathPattern=cycleCount
```

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Bulk export, 2 CCs with positions | dev (wineco) | Internal Ops → Cycle Count → Planned → tick `CC000159` + `CC000151` → Export Selected → Export File | One `CC_Multiple_<ts>.xlsx`; `aggregated` + `detailed` sheets; leading `Cycle Count` column showing both numbers; **no toast** | |
| Single CC, kebab-menu path (regression) | dev (wineco) | Row kebab on `CC000159` → Export | `CC000159_<ts>.xlsx`; columns **exactly** as before this change (no `Cycle Count` column) | |
| Single CC via one checkbox | dev (wineco) | Tick only `CC000159` → Export Selected | Same as above — single-selection shape | |
| Mixed selection (skip path) | dev (wineco) | Tick `CC000159` (33 pos) + `CC000162` (0 pos) → Export | Workbook contains only `CC000159`; **error toast** naming `CC000162` as skipped | |
| All positionless (error path) | dev (wineco) | Tick `CC000162` + `CC000163` (both 0 pos) → Export | **No download**; toast "Can not export from cycle count without positions: CC000162, CC000163" | |
| Single positionless (Bug 2 core) | dev (wineco) | Tick only `CC000162` → Export | **No file downloads** (previously a corrupt `.xlsx`); toast names the cycle count | |
| Bulk **cancel** still works (untouched path) | dev (wineco) | Tick 2 planned CCs → Cancel Selected Cycle Counts → confirm | Both cancelled; success toast — proves §0 row 6 was not disturbed | |
| Cross-origin header visible | dev (wineco) | Browser devtools → Network → the mixed-selection export request | `x-export-skipped-cycle-counts` present **and** readable by JS (skipped toast fired) — proves Fix C landed | |
| Large selection sizing | dev (wineco) | Select the 5 largest FINISHED CCs → Export | Completes without timeout; row count equals the sum of their positions | |
| SQL-level sanity | dev DB | `SELECT c.number, count(p.id) FROM cyclecount c LEFT JOIN cyclecount_position p ON p.cyclecount_id=c.id WHERE c.id IN (…) GROUP BY c.number;` | Per-CC counts match the `detailed` sheet row counts per `Cycle Count` value | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Testcontainers / H2 integration test | No SQL, JPQL, or schema change; every path is unit-testable with mocked repositories. Also avoids the broken v2 IT harness (SBDEV-2217). |
| `exportCycleCount2` (`CyclecountService.java:216`) | Zero production callers; untouched by this plan; its 5 existing tests still cover it. |
| Cypress e2e for the bulk path | `cypress/e2e/wms/cycle-count/cycle-count.cy.js` exists but the e2e lane is not part of this repo's PR gate; the manual test plan covers the click path. |
| v1 (`v1/wms-api`, `v1/wms-web-ui`) | Sibling ticket **SBDEV-2631** owns it (§12). |
| A Micrometer counter for export failures | §11 row 8 — no existing metric to extend on this path; deferred rather than inventing one for a fix that removes the failure mode. |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

**Path:** `sbdocs/9-System/scripts/verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh`

Two roots (`PROJECT_ROOT` = wms2-api, `UI_ROOT` = wms2-web-ui); UI rows **SKIP** rather than FAIL
when `UI_ROOT` is absent, so the script is usable from an api-only worktree. Every multi-line
(`perl -0777`) helper carries an explicit `[ -f "$2" ] || return 1` file-existence guard — without
it those helpers **exit 0 on a missing file**, so every assertion about a new file false-greens.
Ends in `Result: N pass, M fail, S skip`; exit 0 only when `M = 0`.

**The committed script is the authoritative list of check ids — read it, not a table here.** An
earlier draft duplicated the row ids in prose and they drifted (8 phantom ids, 19 missing), which
makes a verifier reconcile against a fiction. The summary below groups the script's rows by fix and
is deliberately id-light; run `grep -n '^run' <script>` for the exact set.

| Fix | POSITIVE rows assert | NEGATIVE rows assert |
|---|---|---|
| **A** (controller) | `parseCycleCountIds` exists; trims; reads both `ids` and `id` **inside the helper**; bad token → `BusinessException`; `writeExportError` exists, sets a status, sets JSON content type, uses **`resetBuffer()`**, emits the fixed 5xx string; `isCommitted()` guard; calls `exportCycleCounts` | the bare pre-`try` `Long.parseLong((String) reqMap.get("id"))` is **gone**; `export()` no longer writes `errors.toString()` (method-scoped, so `/cancel` is unaffected); no `orElseThrow` before the `try`; **`reset()` is not used**; no `service → controller` constant reference |
| **B** (service) | `exportCycleCounts` declared taking `List<Cyclecount>`; `"Cycle Count"` column; skipped-list logic; skipped header set; client memo via `computeIfAbsent`; `size()==1` delegates; `EXPORT_SKIPPED_HEADER` **declared** on the service; legacy signature + both legacy header arrays intact (method-scoped); `exportCycleCount2` not deleted | legacy method has **no** `"Cycle Count"` column; no `@Transactional` on any `exportCycleCount*` **or** on the class |
| **C** (config) | `rest.security.cors.exposed-headers` present and naming the header; `addExposedHeader` present in `SecurityConfiguration` | — |
| **D** (web UI) | pop dispatches an `ids` array; store uses `$axios.post`; reads the lower-cased header; parses the JSON error blob; generic fallback retained | scalar `{id: this.getExportList(` gone (**both** occurrences, incl. the `console.log` at `:68`); dead `if (result.errors)` guard gone from the export action; `$post` shorthand gone from the export action |
| **tests** | controller + service + web-ui specs exist and cover the new paths; **test #17 (CORS survival) present**; targeted `mvn` / `jest` suites pass | — |

**Two rows are load-bearing and were mis-authored on the first pass — do not "simplify" them back:**
`A-resetbuffer` / `A-status` / `A-json` / `A-no-5xx-echo` / `B-legacy-hdr` / `B-legacy-detail` are
scoped with the script's `java_method` helper, **not** a `.{0,N}?` character window. Measured against
this plan's own After-code at real 4-space indentation, `response.resetBuffer()` sits **793**
characters after the `private void writeExportError` anchor and `response.setStatus` **825** — so the
original `{0,700}` / `{0,600}` windows **false-red on correct code**. Character windows are a function
of comment length; method scoping is not.
**Negative-tested in BOTH directions at authoring time (2026-08-02) — do not re-derive:**

| Direction | Result | Meaning |
|---|---|---|
| **Pre-fix**, real `develop` code | **`Result: 9 pass, 42 fail, 2 skip`** | Every fix assertion FAILS. The 9 passes are **intentional invariant rows** that must hold before *and* after: `B-legacy-sig`, `B-legacy-hdr`, `B-legacy-detail`, `B-legacy-no-col`, `B-cc2-intact`, `B-no-tx`, `D2-fallback`, plus the two "don't introduce this" negatives `A-no-reset` / `A-no-svc-to-ctl` (vacuously true while the code they guard doesn't exist yet — unavoidable for a guard rail; their teeth are proven by counter-test 1). **Zero vacuous fix rows.** |
| **Post-fix**, synthetic tree from §5's After-code **including the mandated comment block** | **`Result: 49 pass, 1 fail, 3 skip`** — the single fail is `T-docs` | No false-reds. `T-docs` correctly fails because it gates the §12-mandated `wms2-cycle-count-workflow.md` update, which is genuinely still outstanding. |
| **Counter-test 1**: same fixed tree, `reset()` substituted for `resetBuffer()` | `A-resetbuffer` + `A-no-reset` **FAIL**; `A-status`/`A-json` correctly unaffected | Proves the blocking-defect rows detect the one-word regression that would CORS-block every error response. |
| **Counter-test 2**: fixed tree with the fixed 5xx string replaced by `message` | `A-no-5xx-echo` **FAILS** | Proves that row asserts the actual behaviour, not merely that a `status >= 500` branch exists somewhere. |

**Post-implementation target: `Result: 52 pass, 0 fail, 0 skip`** with `mvn` + `jest` on PATH
(`50 pass, 2 skip` without `mvn`), which requires the `wms2-cycle-count-workflow.md` update as well
as the code.

> **Authoring-history note, kept deliberately.** The FIRST validation pass certified
> "45 pass, 0 fail — no false-reds" against a synthetic fixture that **omitted the mandated comment
> block** inside `writeExportError`. Because `A-resetbuffer` / `A-status` used `.{0,N}?` **character**
> windows, and the real code puts `resetBuffer()` **793** characters past the anchor, those rows
> false-red on the very code this plan specifies — and counter-test 1 had appeared to pass for
> `A-resetbuffer` only because it was NOMATCHing in *both* directions. Both are now `java_method`-scoped.
> The lesson generalises: **validate a verify script against the code the plan actually mandates,
> comments and indentation included — not against a stripped-down fixture.**

**Two script-authoring landmines were found and fixed while negative-testing** — both would have
produced a silently worthless script, and both are guarded in the committed version:

1. **Fail-open multi-line helpers.** `perl -0777 -ne` **exits 0 when it cannot open the file**, so
   every multi-line assertion about a new file false-greens. Proven empirically: the unguarded helper
   returns 0 on `/nonexistent/file.java`. Every helper here opens with `[ -f "$2" ] || return 1`.
2. **Perl delimiter break on `/` in the pattern.** Interpolating a pattern containing a slash
   (`application/json`, `/cycleCount/export`) into `m/.../` terminates the match early → the check
   **false-REDs**. Three rows (`A-json`, `D1-ids`, `D2-post`) failed against known-correct code until
   the pattern was passed through the environment (`VERIFY_PAT="$1" perl -0777 -ne '… $ENV{VERIFY_PAT} …'`).

Two further authoring corrections, caught by the pre-fix baseline showing them **passing**:
`A-both` was a whole-file check satisfied by `/cancel`'s pre-existing `reqMap.get("ids")` at L82, and
`B-all-empty` was satisfied by the legacy `"…without positions!"` message. Both are now scoped
(to the parse helper, and to the new `": " + String.join(...)` skipped-list message respectively).

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 4 fixes across 1 controller + 1 service + 1 property + 2 UI files; single subsystem, two repos |
| **Pre-draft step** | analyst+planner (this doc) + consensus | contract + error-shape change with a user-visible behaviour shift |
| **Plan-review step** | critic | required for Standard+ |
| **Implementation shape** | executor (ralph if the verify baseline shows >6 failing rows) | bounded and fully specified |
| **Verification step** | verify-script + verifier | mandatory; two-root invocation |
| **Code-review step** | code-reviewer | error-response contract change + a shared-service signature addition |
| **Commit step** | git-master | 7 atomic commits across 2 repos, ordered so the 500 fix is independently revertable |

---

## 10. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Deployment env overrides `REST_SECURITY_CORS_EXPOSED_HEADERS`, so the skipped-CC toast silently never fires | Medium | Low (the export itself still works; only the notice is lost) | §5.1 row 3 makes the deployer confirm; manual test row "Cross-origin header visible" proves it end-to-end in dev before release |
| Merged export multiplies the existing uncached N+1 `clientRepository.findById` per position (`:178`, `:193`) — avg 61.7 positions/CC, **max 665** | Medium | Medium (slow export on a large multi-selection) | Fix B memoizes clients in a per-export `Map`, which also speeds up today's single export. `itemdataService.getById` is already `@Cacheable("itemdata")` (`ItemdataService.java:47`) so those are mostly cache hits. Manual test row "Large selection sizing" bounds it empirically |
| Single-CC output drifts accidentally, breaking operator tooling built on today's columns | Low | Medium | `exportCycleCount` is not edited at all (Fix B delegates to it); verify row `B-legacy-intact` asserts both its signature and its legacy header literal; test #3 + #8 assert the shape and that the 8 existing tests are unmodified |
| `catch (Exception) → 500 + JSON` masks a genuine bug as a "handled" error | Low | Low | Status stays **500** for unexpected types (only `BusinessException`→422, `EntityNotFoundException`→404), and `LOG.error(..., e)` keeps the full stack trace, so monitoring is unaffected |
| **`response.reset()` used instead of `resetBuffer()`, stripping the CORS headers Spring Security already wrote → browser blocks every new 422/404/500 → operator sees the generic toast again (i.e. the fix appears not to work)** | **Was High — caught in review** | **High** | §5 Fix A mandates `resetBuffer()` with the reasoning inline; **test #17** asserts pre-existing `Access-Control-*` headers survive the error path; verify row `A-resetbuffer` (POS) + `A-no-reset` (NEG) enforce it in code shape. Flagged because **no MockMvc test catches it incidentally** — MockMvc has no `CorsFilter` |
| Response already committed when an error must be reported | Very Low | Low | Guarded by `isCommitted()`; §2 proves every new throw site precedes the first `getOutputStream()` at `FileExportService.java:129`. Residual truncated-download window recorded as §12 T3 |
| Locally catching `EntityNotFoundException` diverges from `RestExceptionHandler:135`'s global handling for this one endpoint | Low | Low | Deliberate and documented (§5 Fix A table); the message text is preserved, and a `void`+`HttpServletResponse` endpoint needs a body the blob-reading store can parse uniformly |
| UI ships before API in some environment | Low | Low | Harmless on **first** deploy: the API accepts both payload shapes, and against the old API the UI's `ids` payload fails exactly as today's payload already does. Worst case is the pre-existing bug persisting until the API deploys |
| **API PR reverted *after* both halves merge** | Low | Medium | Not covered by the "no deploy coupling" property: the UI would send `{ids:[…]}` to restored old code whose `Long.parseLong((String) reqMap.get("id"))` receives `null` → `NumberFormatException` → 500 → generic toast, i.e. the original bug with a different trigger. **Revert both PRs together, or revert the UI first.** Noted in §7.1 |
| `Cycle Count` column shifts every downstream column right in the multi-CC file | Certain (by design) | Low | Approved decision 1 (§12). Single-CC exports — the only shape that exists today — are unaffected, so no existing file layout changes |
| `mvn test` mutates the tracked `archunit_store` and it gets committed | Medium | Low | Explicit checklist step in §7.2 to revert it before committing |
| Two pre-existing `develop` test failures (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) misattributed to this change | Medium | Low | Baseline them on clean `develop` before starting; note in the PR that both reproduce there |

---

## 11. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | introduce per-replica state? | **No** | The only new state is a method-local `Map<Long, Client>` memo, scoped to one request and discarded with the stack frame. `EXPORT_SKIPPED_HEADER` is a `static final String` (immutable). |
| 2 | **Connection pool math** | change per-request DB connection usage? | **Yes (bounded, net-neutral-to-better)** | A bulk export issues `findByCyclecountId` once per selected CC instead of once per request, so query count scales with the selection. No transaction is held (row 4), so each query borrows and returns a connection immediately — pool *occupancy* per request is unchanged. The client memo **reduces** total queries versus the naive merge. See Evidence. |
| 3 | **Scheduled jobs** | add/modify `@Scheduled`? | **N/A** | Pure HTTP request-path fix. `wms2-cycle-count-workflow.md` confirms no cron touches cycle count. |
| 4 | **Long transactions** | hold a tx across calls / I-O? | **No — deliberately** | `CyclecountService` carries **no** `@Transactional` today (grep: zero hits) and this plan adds none. Two arguments, the second decisive: (a) a *method-level* annotation would hold a tenant DB connection across response I/O — exactly what this row forbids. (b) The obvious middle option — a `readOnly` tx scoped to just the *gather* phase, which would **not** span I/O — still buys nothing: **no isolation override exists** anywhere in `application.properties` or config, so PostgreSQL default **READ COMMITTED** applies and takes a **new snapshot per statement**. `@Transactional(readOnly = true)` would therefore give **exactly zero** cross-query consistency across the N `findByCyclecountId` calls while lengthening connection hold; only `isolation = REPEATABLE_READ` would mean anything, which is a materially heavier change for a low-frequency admin report. The residual read-skew (CC-A read pre-count, CC-B read mid-count) is a soft report inconsistency, accepted. Note also `TransactionManagerArchTest` requires any `@Transactional` under `service..` to name a manager, so this would have been a two-part change. All entities are eagerly fetched via `findById`, so OSIV-disabled causes no `LazyInitializationException`. |
| 5 | **Request affinity** | assume a same-replica follow-up? | **No** | Single stateless request/response; the skipped notice rides on that same response's header. |
| 6 | **Retry / idempotency** | rely on single-execution? | **No (idempotent)** | Export is read-only; a UI retry re-reads and re-renders. Nothing is written. |
| 7 | **Tenant context** | use `TenantContext` across async? | **No** | Entirely synchronous on the request thread; no `@Async` / `CompletableFuture` added. |
| 8 | **Distributed lock** | add/rely on locks? | **No** | No `@Lock`, no `findByIdForUpdate`, no advisory lock on this path. |
| 9 | **Cache invalidation** | write to a cached entity? | **No** | Read-only. `itemdataService.getById` is `@Cacheable` and only *read*; no `@CacheEvict` is needed because nothing mutates. The per-request client memo is not a Spring cache and cannot go stale across requests. |
| 10 | **External notifications** | HTTP / message inside a tx? | **No** | No OMS / outbox / printer interaction on this path. |

### Evidence (for the "Yes" row)

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 2 | Query count per bulk export = `N` × `findByCyclecountId` + (distinct clients) × `findById` + (positions) × cached `getById`. Client lookups memoized rather than per-position. Sizing from live DB: avg 61.7 positions/CC, max 665 (§1). No transaction wraps them, so connection occupancy per query is unchanged. | `CyclecountService` Fix B `client(...)` helper (§5); `ItemdataService.java:47` (`@Cacheable`); test `exportCycleCounts_reusesClientLookupAcrossPositions` (§8) |

### v2-only constraint checklist

| # | Check | Verdict | Evidence |
|---|---|---|---|
| 1 | **OSIV disabled** — any lazy access outside a tx? | **No issue** | Every entity is eagerly fetched by `findById` / `findByCyclecountId` into the `Object[]` rows before `FileExportService` runs; no association traversal. No `@Transactional` needed (§11 row 4). |
| 2 | **Transaction manager** — tenant-scoped writes use `tenantTransactionManager`? | **N/A** | No `@Transactional` added and no write performed. |
| 3 | **`@Transactional(readOnly=true)`** on read paths? | **Deliberately not added** | Would hold a tenant connection across the response stream (§11 row 4). Same stance the 260610 plan took for these export methods. |
| 4 | **Caffeine cache invalidation** paired with writes? | **N/A** | Read-only path; `itemdata` cache is read, never written. |
| 5 | **Jakarta namespace** — no `javax.*` imports? | **Yes (clean)** | New imports are `jakarta.servlet.http.HttpServletResponse` (already imported at `CycleCountController.java:29`), `org.springframework.http.HttpStatus`/`MediaType`, `java.nio.charset.StandardCharsets`, `java.util.*` (already wildcard-imported). |
| 6 | **H2-compatible test SQL** | **N/A** | No new query; all new tests mock the repositories. |
| 7 | **`BaseControllerUnitTest` for controller changes** | **Yes** | New `CycleCountControllerUnitTest` cases extend the existing class, which already uses the `BaseControllerUnitTest` MockMvc + tenant-context setup. |
| 8 | **Micrometer metrics** on a high-frequency path? | **No** | Cycle-count export is a low-frequency admin action; no existing counter covers it, and this fix removes the failure mode rather than needing to observe it. Deferred (§5.1 row 8, §12). |

---

## 12. Open Questions / Resolved Decisions

All decisions were resolved with the requester **before** drafting. None are open.

| Decision | Resolution | Status |
|---|---|---|
| What should a bulk export produce? | **One workbook**, all selected CCs merged into the existing `aggregated` + `detailed` sheets, with a new **leading `Cycle Count` column** so rows stay attributable. Matches the UI's pre-existing `CC_Multiple` filename intent. | **RESOLVED** |
| Where to fix the id-list contract? | **Backend accepts both** legacy `{id:"1, 2"}` and new `{ids:[1,2]}`; the UI migrates to `ids` in the paired PR ⇒ **no deploy-order coupling** (§5.1 row 4) | **RESOLVED** |
| Is Bug 2 (positionless CC ⇒ corrupt download) in scope? | **Yes, fully.** Bulk export **skips** positionless CCs and exports the rest, reporting the skipped ones; if **nothing** is exportable → real error toast naming them. Single positionless selection → clear 422, no download. | **RESOLVED** |
| Must the single-CC file stay byte-identical? | **Yes.** A one-row selection produces exactly today's columns and sheet names; the `Cycle Count` column appears only for multi-selection. Two output shapes, both tested (#3, #1). | **RESOLVED** |
| Aggregate globally per SKU, or per cycle count? | **Per cycle count** — a SKU in two selected CCs yields one row per CC (§5 Fix B table) | **RESOLVED** |
| Catch breadth / status mapping | `BusinessException`→**422**, `EntityNotFoundException`→**404**, everything else→**500** + JSON (§5 Fix A table) | **RESOLVED** |
| Scope to v1 as well? | **No** — parent SBDEV-2264 deliberately splits v1/v2; sibling **SBDEV-2631** owns v1 | **RESOLVED** |

### Cross-version (v1) applicability

v1 is **structurally identical** and has **both** bugs:

| Aspect | v1 | v2 |
|---|---|---|
| Bad parse | `v1/wms-api .../CycleCountController.java:110` — same `Long.parseLong((String) reqMap.get("id"))`, also **pre-`try`** (its `try` opens at L116) | `:111` |
| UI join | `v1/wms-web-ui .../cycleCount/exportCyclePop.vue:61` — same `join(', ')` | same |
| Bug 2 severity | **Worse** — v1 still writes the **empty** `errorMap.toString()` (L123), so the corrupt download is literally `{}`; v1 never received PR #43's Fix C | writes non-JSON `errors.toString()` |
| Lookup failure | wraps `findById` **inside** the try and throws `BusinessException` | pre-`try`, throws `EntityNotFoundException` (globally handled) |

⇒ **Applicable, deferred to sibling ticket SBDEV-2631**, which should mirror this plan with the two
v1 adaptations above (plus v1's Mockito 3.3.3 limits — no `mockStatic`). Do **not** fix v1 here.

### Accepted consequences surfaced by architectural review (not blocking, but stated)

| # | Consequence | Why accepted |
|---|---|---|
| T1 | **The file schema keys off *selection* cardinality, not *exportable* cardinality.** Select 2 where 1 is positionless and you get the **multi** shape (leading `Cycle Count` column) containing exactly **one** cycle count, because `size() == 1` branches on the selection. A consuming spreadsheet/macro cannot predict the column count from its own selection alone. | Unavoidable inside settled decisions 3 + 4: branching on *exportable* count would let a 2-selection produce today's schema (a different violation of decision 4), and always emitting the column violates decision 4 outright. Stated rather than hidden. |
| T2 | **The skipped-CC notice is out-of-band**, so a partial export is indistinguishable from a complete one *in the artifact itself* — the workbook is what gets saved, emailed, and audited weeks later, while the toast lasts seconds and the header is lost if any ingress or CDN strips unknown response headers. | An in-workbook notice row would be self-describing and CORS-proof but pollutes a data sheet; the toast is the right UX. Audit gap accepted and recorded. |
| T3 | **Residual corrupt-download window survives.** If `workbook.write(outputStream)` throws *after* `FileExportService:129` has flushed, `isCommitted()` is true, `writeExportError` logs and returns, and the client gets a truncated `.xlsx` with status 200 — the original Bug 2 shape. | Very unlikely (the workbook is fully built in memory before the stream opens) and unclosable without buffering the whole file twice. Recorded so a reviewer doesn't discover it cold. |
| T4 | `parseCycleCountIds` accepts a **scalar** under the `ids` key (`{ids: 5}`) via the `String.valueOf(raw)` fallback. | Harmless and forgiving; the plan does not claim `ids` is array-only. |
| T5 | **No hard cap on selection size.** The whole POI workbook is built in heap before `FileExportService:129` opens the stream, and the Planned table has `show-select` with a page-level select-all (`plannedCycleCount.vue:70`, default `itemsPerPage: 10` at `:385`, options from `pagination.rowsPerPageItems`). At avg 61.7 / max 665 positions per cycle count, a 10-row page is ~600 rows — comfortable. | ~~**Accepted as bounded by page size**, because select-all is page-scoped, not result-scoped. **Implementer action:** confirm `rowsPerPageItems` does not offer an "All" option; if it does, add a `MAX_BULK_EXPORT_CYCLE_COUNTS` guard...~~ **SUPERSEDED AT IMPLEMENTATION — 2026-08-03. Both caps were added.** The implementer action was discharged as written (no `-1`/"All" in any of the four `rowsPerPageItems` declarations, largest page = 100), so under this row's own logic no cap was required — but **the reasoning was wrong in two ways**, both caught in security review. (1) Page-scoped select-all is a **client-side** control; `/v3/cycleCount/export` is directly POST-able, and `SecurityConfiguration` gates `/v3/**` on `wms_user` — the standard warehouse-user role, **not** admin-only as this plan implies. One JVM serves every tenant, so an unbounded selection is a cross-tenant availability risk. (2) This row reasons from a 10-row page (~600 rows); the real page ceiling is 100. Hence `CycleCountController.MAX_BULK_EXPORT_CYCLE_COUNTS = 100`. A second review round then showed **a count cap bounds the wrong dimension** — heap is driven by *positions*, and 100 cycle counts at the observed max (665) is still ~66k rows — so `CyclecountService.MAX_BULK_EXPORT_POSITIONS = 50_000` was added too, checked while gathering so an over-large selection costs the count queries and nothing more. Both raise `BusinessException` → clean 422 via Fix A. |
| T6 | **A single workbook can now interleave cycle counts belonging to different *clients*** within one tenant — a first. There is no authorization check on the submitted ids beyond `findById`. | Accepted: the Planned Cycle Counts screen already lists every client's cycle counts to the same roles (`super-admin`, `inventory-manager`), and the merged file adds a `Client Name` / `Client ID` column pair per row, so nothing is disclosed that the screen does not already show. §11 row 5 / v2-checklist row 1 cover **tenant** isolation, which is unaffected. Stated because a reviewer will ask, and because it would become a real question if this endpoint were ever exposed to a client-scoped role. |

### Verified negatives (recorded so reviewers don't have to re-derive them)

- **Caller census is complete.** Grepping all five UI trees for `cycleCount/export` returns exactly **two** hits, both in `v2/wms2-web-ui` (`exportCyclePop.vue:71`, `store/internalOps/cycleCount.js:198`), plus the v1 mirror pair. **`wms2-mobile-ui`, `v1/wms-mobile-ui` and `omsv2-UI` have zero.** No mobile or OMS consumer is affected.
- **No Spring Data REST exposure concern.** `CyclecountRepository` (`path="cyclecount"`) and `CyclecountPositionRepository` (`path="cyclecountPosition"`, plus an exported `findByCyclecountId`) are both HAL-exported, but this plan changes **no query and no repository method** — so the SBDEV-1666 landmine (a service-layer branch that cannot guard an exported HAL query) does not apply.
- **No `ids` payload collision.** `/cancel` already consumes `ids` on this controller and `/export` consumes `id`; the tolerant helper prefers `ids` and falls back to `id`, displacing no existing contract.
- **No ArchUnit rule blocks the design.** The four rules present (`OptionalSafetyArchTest`, `TransactionManagerArchTest`, `HttpInTransactionArchTest`, `ParallelStreamSafetyArchTest`) cover none of the constructs added here — but note `TransactionManagerArchTest` would force a named manager if anyone later adds `@Transactional` (§11 row 4).
- **Catch order compiles.** `BusinessException extends Exception` (checked) while `EntityNotFoundException extends RuntimeException`, so `catch (BusinessException) / catch (EntityNotFoundException) / catch (Exception)` produces no unreachable-catch error.

### Known limitations / follow-ups (not blocking)

- **§0 row 13 — controller-input hardening sweep.** ≥18 sibling sites share this defect class
  (`PickingController:341` is a character-for-character twin; six `Long.valueOf((Integer) …)` casts
  sit in `CycleCountController` itself at `:153,165,166,178,179,180`). The enumeration is recorded in
  §0 so the next person doesn't re-derive it. Worth one ticket that applies this plan's tolerant-parse
  + `writeExportError` pattern across `net.aim_ai.wms.controller`, **or** — cheaper and broader — adding
  an `@ExceptionHandler(Exception.class)` to the globally-scoped `RestExceptionHandler` so the whole
  package stops leaking raw 500s. Not done here: it would change error responses repo-wide.
- **§0 row 7 — BOL bulk export silently exports only the first selected BOL** — **filed as
  [SBDEV-2797](https://app.clickup.com/t/868kk83r2)** (2026-08-02, normal priority). Also worth noting
  in that ticket: `exportBolPop.vue:64` builds a `join(', ')` string it then discards.
- **The repo-wide `errorMap.toString()` empty-body pattern** flagged by the 260610 plan (§12) is
  still open in `ReportController`'s 9 non-export endpoints and elsewhere. Not widened here.
- **`exportCycleCount2`** (`CyclecountService.java:216`) remains dead production code with live
  tests. Left as-is; a separate cleanup could delete it.
- **No export-failure metric.** Deferred (§11 row 8).
- **Swapped client column labels** — `getClNr()` under `"Client Name"`, `getName()` under `"Client ID"`, in every export method in **both** v1 and v2. Pre-existing; preserved here for consistency. **Filed as [SBDEV-2802](https://app.clickup.com/t/868kkfekz)**. → **RESOLVED for v2 on 2026-08-03** by [SBDEV-2802](SBDEV-2802-cycle-count-export-client-column-headers-swapped.md): the six header arrays now read `"Client ID", "Client Name"` and the bug-parity comment this plan added is deleted. **v1 still has the swap.** This plan's verify script (`:235-236`) was updated to expect the corrected order — do not "repair" it back.
- **`wms2-function-to-docs-map.md` indexes none of the cycle-count symbols**, so the mandated pre-change doc lookup returns a false negative for this subsystem. **Filed as [SBDEV-2803](https://app.clickup.com/t/868kkfeyv)**.
- **Cycle-count workflow doc** (`sbdocs/3-Resources/workflows/wms2-cycle-count-workflow.md:114-115,148`)
  documents the export endpoint as `POST /v3/cycleCount/export {id}` at `CycleCountController:106`.
  Run `verify-docs` after implementation and update that row to `{ids}` / `{id}` plus the new
  status codes.

---

## Completeness checklist (wms-bugfix-plan skill)

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** — `execute_sql` run, result inline in §1, frontmatter `db_verified: true` | ✓ §1 "DB verification" — 3 live queries on wms2-wineco-dev; 77.6% zero-position finding is what surfaced Bug 2 |
| 1 | **All callsites enumerated** — every §0 row visited or excluded with rationale | ✓ §0 (12 rows; 1-5 in scope → §5 Fix A-D; 6-12 excluded with reasons) |
| 2 | **Adjacent bugs** — same-pattern instances found by pattern-grep | ✓ §0 rows 7-11 (frontend `join(', ')` sweep, 6 hits) **and row 13** (backend sweep: ≥18 unguarded `@RequestBody Map` numeric coercions in controllers outside `.controller.rest`, incl. 6 in this very file). Row 7 filed as SBDEV-2797; row 13 recorded as a follow-up. *An earlier draft grepped only the frontend pattern repo-wide and scoped the backend grep to one file — corrected in review.* |
| 3 | **Backward compatibility** — API contract, payload shape, error-response shape | ✓ §5 Fix A (both wire shapes accepted), §5.1 row 4 (no deploy coupling), §12 decision 4 + risk row (single-CC file unchanged); **error-response shape does change** (200-with-body → 422/404/500 + JSON) and is documented as intentional |
| 4 | **Concurrency** — races, locks, idempotency under retry | ✓ §11 rows 4, 6, 8 — read-only, no locks, idempotent under UI retry |
| 5 | **Multi-tenant** — cross-tenant queries, context propagation, cache scoping | ✓ §11 rows 7, 9 + v2 checklist rows 1, 4 — all queries tenant-scoped via the existing routing; `itemdata` cache key already includes the facility code; the new memo is request-scoped |
| 6 | **Error handling** — every new throw path has a handler or a documented contract change | ✓ §5 Fix A (three catches, status-differentiated), §5 Fix B (`BusinessException` for the all-empty case), §2 (proof of today's escape path) |
| 7 | **Observability** — logs, metrics, alert thresholds | ✓ §5 Fix A keeps `LOG.error(..., e)` with the stack trace for unexpected types; §5.1 row 8 + §11 row 8 — no metric added, rationale recorded |
| 8 | **Rollback / migration** — Flyway, backfill, deploy order, flags | ✓ §5.1 rows 1, 4, 5 — none needed; §7.1 orders commits so the 500 fix and the CORS property are independently revertable |
| 9 | **Test coverage** — unit + integration + manual, named classes/methods | ✓ §8 — 17 scenarios (15 test cases + #8/#10 which are procedural checks, not tests), 19 named methods across **4** files (`CycleCountControllerUnitTest`, `CyclecountServiceUnitTest`, `cycleCount.spec.js`, `exportCyclePop.spec.js`), 10-row manual click-path table, skipped-coverage table, **plus 7 explicit harness obligations (H1-H7) verified by probing the repos** — the jsdom/`@Mock`/null-response traps are named rather than left for the gate to discover |
| 10 | **Cross-version (v1↔v2)** | ✓ §12 "Cross-version" — applicable, deferred to **SBDEV-2631** with the two v1 deltas spelled out |

---

## 13. ADR — Decision Record

- **Decision.** Parse the cycle-count export selection with a single tolerant helper
  (`parseCycleCountIds`) that accepts both `{ids:[…]}` and a comma-separated `{id:"…"}`, trims,
  dedupes, and raises `BusinessException` instead of an unchecked `NumberFormatException` — with the
  parse and the entity lookup moved **inside** the try. Add
  `CyclecountService.exportCycleCounts(response, List<Cyclecount>)` that merges the selected cycle
  counts into the existing two sheets behind a new leading `Cycle Count` column, skips positionless
  cycle counts, and reports them via an `X-Export-Skipped-Cycle-Counts` response header (exposed
  through CORS). Leave `exportCycleCount` byte-identical so single-CC output does not change. Make
  the web UI send a typed `ids` array, download only on a 2xx, read the skipped header, and parse the
  JSON error blob for a real toast message.
- **Drivers.** (1) A high-priority bug where the UI was built for multi-select and the API never
  was — bulk export has never worked. (2) The 500 originates *outside* the `try`, so PR #43's
  `catch (Exception)` provably cannot reach it. (3) DB evidence that 77.6% of the affected tab's rows
  hit a second, *silent* defect that downloads a corrupt file — fixing only the 500 would leave most
  of the screen broken in a harder-to-notice way. (4) The correct implementation already exists 25
  lines away in `/cancel`, so this is an omission with a known-good local precedent.
- **Alternatives considered.**
  (a) *Wrap L111 in a `try` only* — rejected: stops the 500 but leaves bulk export non-functional,
  reporting "invalid id" for a legitimate selection.
  (b) *Copy `/cancel`'s `split(",")` verbatim* — rejected: still breaks on the space that
  `exportCyclePop.vue` emits (`join(', ')`), which is precisely the reported payload.
  (c) *Frontend loops one request per id (N downloads)* — rejected by the requester: fires N
  sequential downloads (browsers block multi-file downloads), no atomic all-or-nothing, and
  contradicts the existing `CC_Multiple` filename intent.
  (d) *One sheet-pair per cycle count* — rejected by the requester: Excel's 31-char sheet-name cap
  and unbounded sheet counts on a large selection.
  (e) *UI-only fix sending `ids`, backend typed `List<Long>`* — rejected: creates a hard
  api-before-ui deploy dependency for no benefit, since a tolerant backend has the same end state.
  (f) *All-or-nothing on positionless CCs* — rejected: with 77.6% of CREATED rows empty,
  "select all → export" would never succeed.
  (g) *Global per-SKU aggregation across cycle counts* — rejected: silently merges counts from
  distinct count events, destroying attributability.
  (h) **Steelman (Architect): a two-phase `planExport(List<Cyclecount>) → ExportPlan` /
  `writeExport(response, plan)` seam**, with the controller setting the skipped header — cleaner
  layering, and query-neutral for the multi path since the planning call returns the positions it
  already fetched. **Rejected on a specific trade, not on layering:** the single-CC path must
  delegate to the untouched legacy `exportCycleCount` to guarantee byte-identity *by construction*,
  and that method re-queries positions — so the seam costs an extra `findByCyclecountId` on the most
  common path, or forces duplicating the legacy row builder and thereby forfeits the guarantee.
  Mitigated instead by declaring `EXPORT_SKIPPED_HEADER` on the **service**, so no
  `service → controller` dependency is introduced. Revisit if the single-CC branch is ever dropped.
  (i) *A `@Transactional(readOnly = true)` gather phase for cross-query consistency* — rejected: with
  no isolation override, READ COMMITTED re-snapshots per statement, so it would buy zero consistency
  (§11 row 4).
- **Why chosen.** It is the smallest change that makes the feature work as the UI already implies,
  fixes this instance of the unchecked-parse-escaping-the-advice defect **and establishes the
  tolerant-parse + `writeExportError` pattern** for the ≥18 sibling sites enumerated in §0 row 13
  (an earlier draft claimed it "removes a whole class of 500" — **corrected**: six such sites remain
  in this very file, on other endpoints, deliberately out of scope), and eliminates a
  silent-data-loss failure mode on the same screen —
  while leaving the only output shape that exists today byte-identical and imposing **no**
  deploy-order coupling.
- **Consequences.** The export endpoint's error contract changes from "HTTP 200 with an
  unparseable body" to "422/404/500 with JSON", which the paired UI change consumes; any other
  consumer of `/v3/cycleCount/export` (none found in-repo) would see real status codes. Multi-CC
  files carry one extra leading column. `EntityNotFoundException` on this one endpoint is handled
  locally rather than by the global advice. A one-line CORS property must be present in every
  environment or the skipped-CC notice is silently lost.
- **Follow-ups.** BOL bulk-export truncation ticket **filed as SBDEV-2797**. Controller-input hardening sweep for §0 row 13 (or a global `@ExceptionHandler(Exception.class)`). Mirror this plan for v1 as
  **SBDEV-2631**. Optionally: repo-wide `errorMap.toString()` cleanup, delete dead
  `exportCycleCount2`, add an export-failure counter. Run `verify-docs` and update
  `wms2-cycle-count-workflow.md:114-115,148`.

---

## 14. Implementation Status

**IMPLEMENTED AND MERGED 2026-08-03.** **wms2-api [#119](https://github.com/SiteBossInc/wms2-api/pull/119)** → merge commit `37bb39e` · **wms2-web-ui [#35](https://github.com/SiteBossInc/wms2-web-ui/pull/35)** → merge commit `6ce7878`. Merged API-first as required; all 9 commits verified as ancestors of `origin/develop` in both repos. ClickUp SBDEV-2632 → `on dev`.

**Not deployed to QA/prod, and the three manual checks below remain outstanding.** No deploy prerequisites: no Flyway migration, no schema change, no sysprop, no config action.

Branch `feature/SBDEV-2632-cycle-count-bulk-export` in both repos, off freshly-fetched `origin/develop` (api `e18f00b`, ui `b894bee`).

### Commits

| # | SHA | Repo | Fix |
|---|---|---|---|
| 1 | `78b3a52` | wms2-api | **Fix B** — `exportCycleCounts` merged path, skip logic, skipped header, client memo, `EXPORT_SKIPPED_HEADER` |
| 2 | `7258020` | wms2-api | **Fix A** — tolerant `parseCycleCountIds`, all-inside-try, `writeExportError` 422/404/500, `MAX_BULK_EXPORT_CYCLE_COUNTS`, `sanitizeToken` |
| 3 | `34fa01e` | wms2-api | **Fix C** — CORS property + guarded `addExposedHeader` |
| 4 | `efc766e` | wms2-api | tests (23 methods, 3 classes) |
| 5 | `2ee54c8` | wms2-api | review round 2 — `MAX_BULK_EXPORT_POSITIONS`, parent-bundle `placeholder`, 404 logging, bug-parity comment |
| 6 | `1355ade` | wms2-web-ui | **Fix D1** — typed `ids` array |
| 7 | `bdeef30` | wms2-web-ui | **Fix D2** — `post`, gated download, header read, `extractBlobErrorMessage` |
| 8 | `77376d2` | wms2-web-ui | tests (2 new spec files, 6 tests) |
| 9 | `96245ea` | wms2-web-ui | review — name the `validateStatus` mechanism in the comment |

**§7.2's commit order was not followed, deliberately.** It put Fix A first "independently revertable", but the controller calls `exportCycleCounts`, so that commit **would not have compiled**. A and B are swapped. Verified: `78b3a52`, `7258020`, `34fa01e` each `mvn clean compile` standalone and `efc766e` `mvn clean test-compile` — so the branch is bisectable.

### Results

- `mvn clean compile` → **BUILD SUCCESS**
- `mvn test -Dtest=CycleCountControllerUnitTest` → **41 run, 0 failures** (BulkExport 16 + BulkExportWorkbookContent 9 + 16 pre-existing)
- `mvn test -Dtest=CyclecountServiceUnitTest` → **33 run, 0 failures**; file **byte-untouched** (the 4 `ExportCycleCount` + 4 `ExportCycleCount2` tests unmodified, per §8 #8)
- `mvn test -Dtest=SecurityConfigurationTest` → **7 run, 0 failures**
- `mvn test` (full) → **4585 run, 2 failures, 67 skipped**. Both failures pre-exist on clean `develop` and are unattributable to this change: `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` (**8** violations, all in `MobileReplenishService` / `PickLineRealignmentService` / `ReplenishGeneratorService` / `ToteStateService` / `UnitloadBusinessService` — count unchanged by this diff, and this change adds no `Optional.get()`) and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`.
- `node_modules/.bin/jest --testPathPattern=cycleCount` → **2 suites, 6 tests, all pass**
- **`Result: 53 pass, 0 fail, 0 skip`** (target was 52/0 — the committed script has 53 rows; §9.1 says the script is authoritative, so this is plan-prose drift only). Invoked with **both roots pointed at the worktrees**; wiring proven by the six test-surface rows, which pass only under the worktree roots.
- `archunit_store` mutation reverted before every commit; final `git status` clean in both repos.

### Verification lanes

- **Conformance (verifier, opus):** `PASS`. All 5 in-scope §0 rows and every §8 criterion `VERIFIED` against commands it re-ran itself. Two `PARTIAL`s at first pass — inner-`LinkedHashMap` SKU ordering untested, and `parseCycleCountIds` having no direct test despite §8 naming one — **both closed** before review.
- **Code review (2 independent lanes) + security review:** **0 Critical, 0 High.** Two Mediums, both fixed. 13 Lows: 7 fixed, 6 recorded below.

### Landmines found during implementation that the plan did not predict

1. **The TDD gate's own stubs became wrong.** Scenarios #5 and #17 stubbed the mock's *legacy singular* `exportCycleCount`, which the controller no longer calls, so the stub never fired and both tests failed with 200 instead of 422. Re-pointed to `exportCycleCounts`; every assertion byte-identical. The verifier reconstructed the original and proved by experiment the 2-line change was necessary **and** sufficient.
2. **A comment can break a negative verify row.** `A-no-bare-parse` failed on correct code because an explanatory comment quoted the defect line `Long.parseLong((String) reqMap.get("id"))` verbatim. Reworded. Watch this on any NEG row asserting a construct is *gone*.
3. **`CorsConfiguration.addExposedHeader` does not de-duplicate.** Property + programmatic add emitted `Access-Control-Expose-Headers` with the header listed **twice**. Found by writing the test, not by reading. Guarded with `contains()`.
4. **`resetBuffer()` does not clear the container's `usingOutputStream` flag** (unlike `reset()`), so `getWriter()` throws `IllegalStateException` if `FileExportService:129` already opened the stream and the write then failed pre-commit — escaping a catch block, invisible to the sibling `catch (Exception)`, and an unhandled 500. Now caught. Outcome is a **zero-length body with the intended status**, strictly better than T3's accepted truncated download. No unit test can reproduce it: `MockHttpServletResponse` permits `getWriter()` after `getOutputStream()`.
5. **`placeholder=%1s` lived only in `messages_en_US.properties`.** `BusinessException(String)` renders every plain-string message through `resolveMessage(getDefault(), "placeholder", message)`, so on a JVM whose default locale does not resolve that child bundle the operator's toast reads `placeholder, '<message>'` — and nothing pins the locale in the Dockerfile or CI. Added to the parent bundle. (The child holds **326** keys the parent lacks; that wider gap is pre-existing and untouched.)
6. **A count cap does not bound heap** — see the amended §12 T5.
7. **Pre-existing swapped column labels**, now documented in code: `client.getClNr()` sits under `"Client Name"` and `client.getName()` under `"Client ID"` in **all three** export methods. Preserved deliberately; correcting it changes operator-visible output and needs its own ticket covering all three — **filed as [SBDEV-2802](https://app.clickup.com/t/868kkfekz)** (v1 has the identical swap, so that ticket covers both versions; note SBDEV-2632's tests pin the current header arrays verbatim and will need updating as part of it).

> **RESOLVED for v2, 2026-08-03** — [SBDEV-2802](SBDEV-2802-cycle-count-export-client-column-headers-swapped.md) swapped the **labels** (not the values, so each physical column keeps its contents) across all six header arrays, deleted the bug-parity comment added by `2ee54c8`, and updated the verbatim header pin in this plan's `export_shouldKeepLegacyColumns_whenSingleCycleCountSelected` as anticipated here — **that test is now named `export_shouldKeepLegacySheetShape_whenSingleCycleCountSelected`**, because it pins the sheet *shape*, not the labels, and its old "INVARIANT / passes before AND after" wording had become false. **Two corrections to the note above:** there are **six** header arrays, not "all three methods" worth in the sense implied — and `exportCycleCount2` turned out to be **dead code** (no caller in either version), so only 4 of the 6 are operator-reachable. **v1 remains unfixed and is still owned by SBDEV-2802**, not SBDEV-2631.
8. **`#12b` cannot detect a `LinkedHashMap`→`HashMap` swap.** Mutation-verified: the whole class stays green, because a constant `hashCode()` puts every key in one bin and below the treeify threshold (bin ≥ 8 **and** table ≥ 64, i.e. ~49 entries) that bin iterates in insertion order anyway. A test with teeth would need ~49 SKUs in one cycle count and would then fail only probabilistically, so it was deliberately not written. Disclosed in the test's own comment.

### Deferred (recorded, not silently dropped)

Workbook unclosed on a mid-build failure, and `getAmountafter().intValue()` unguarded on a **nullable** column — both **legacy-identical**, so pre-existing rather than introduced (0 of 6,058 rows null on wineco-dev; `amountbefore` and `cyclecount.number` and `itemdata.client_id` are all `NOT NULL`, so those null paths are unreachable) · skipped-CC message/header text not sanitized (numbers are sequence-generated and DB-constrained; the durable fix is the UI's `innerHTML` toast path) · comma delimiter makes the skipped **count** data-derivable · skipped header survives onto 404/500 responses · N+1 `findById` in the resolve loop (`findAllById` would also name every missing id at once) · `parseCycleCountIds` visibility · `$toast.error` vs `info` for partial success · `wms2-function-to-docs-map.md` has **no entry** for `CycleCountController` / `CyclecountService` / `exportCycleCount` — **filed as [SBDEV-2803](https://app.clickup.com/t/868kkfeyv)**.

### Docs

`sbdocs/3-Resources/workflows/wms2-cycle-count-workflow.md` updated: export contract → `{ids:[1,2]} | {id:"1, 2"}`, the two output shapes, the CORS-exposed skipped header, 422/404/500 + JSON, and the historical root cause. Its `CycleCountController` line anchors were stale **before** this change (`create` said 56, actual 60) and all eight were refreshed; `updated` / `last_verified` bumped to 2026-08-03.

### Not done by this execution, by design

~~Merging either PR · setting ClickUp to `on dev`~~ — **both done 2026-08-03 at the requester's direction** (see header). Still not done: **archiving this plan** (run `archive-plan`) · deploying/tagging beyond dev · the three manual checks below. **No Flyway migration exists in this change**, so there is no unpatched-tenant concern.

### Manual checks that CI cannot cover

1. The plain **single-CC export success path** in the target browser — `URL.revokeObjectURL` is now deferred 1s instead of synchronous after `click()`; that is the everyday path and no test reaches it.
2. The real **`Blob.text()`** error path — jsdom 16.7 lacks `Blob.prototype.text`, so the JSON-error test fakes the reader. Export a positionless cycle count and confirm the toast shows the backend message, not the generic one.
3. The **cross-origin skipped header** being readable by JS on a real deployed origin.

*Original checklist, all items now closed:*

- [x] **Pre-fix verify baseline captured 2026-08-02: `Result: 9 pass, 42 fail, 2 skip`** — all 9 passes are intentional invariant rows (§9.1). Script validated post-fix against a synthetic tree built from §5's After-code *with the mandated comment block* (`49 pass, 1 fail` — the fail is the outstanding doc update) and counter-tested twice (`reset()` substitution → `A-resetbuffer`/`A-no-reset` fail; dropped 5xx string → `A-no-5xx-echo` fails). **Target after implementation: `52 pass, 0 fail, 0 skip`** (`50 pass, 2 skip` without `mvn`).
- [ ] Commit SHAs per fix (A / B / C / D1 / D2 / tests)
- [ ] `mvn clean compile` result
- [ ] `mvn test -Dtest=…` and full-suite counts (passed / failed / skipped), with the 2 known pre-existing `develop` failures called out
- [ ] `node_modules/.bin/jest --testPathPattern=cycleCount` result
- [ ] Final verify line `Result: N pass, 0 fail, S skip`
- [ ] `archunit_store` reverted before commit
- [ ] Code-review outcome (critical / high / medium counts + resolutions)
- [ ] `verify-docs` outcome + `wms2-cycle-count-workflow.md` update
- [ ] PR links (wms2-api, wms2-web-ui) and merge order
- [ ] ClickUp SBDEV-2632 → `pr submitted`
