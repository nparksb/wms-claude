---
name: sbdev-2632-cycle-count-bulk-export-multi-id-500
description: "SBDEV-2632 (v2) / SBDEV-2631 (v1): cycle count BULK export 500s because the UI joins ids into one comma-space string and the controller parseLongs it OUTSIDE the try; plus 77.6% of CREATED CCs silently download a corrupt xlsx"
metadata: 
  node_type: memory
  type: project
  originSessionId: c4efefbe-0109-422d-bcbf-bd1fa5a73aca
  modified: 2026-08-03T01:57:56.387Z
---

**SBDEV-2632** (v2, https://app.clickup.com/t/868keq79q) — subtask of **SBDEV-2264** (high);
sibling **SBDEV-2631** owns v1. Plan drafted + reviewed 2026-08-02, status `in development`, **not yet
implemented**. Plan: `sbdocs/1-Projects/wms2/plan/SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.md`,
verify script `sbdocs/9-System/scripts/verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh`
(pre-fix baseline **9 pass / 42 fail / 2 skip**; target **52 pass / 0 fail**).

**Two bugs, both scoped in:**

1. **Bulk export 500.** `exportCyclePop.vue:61` does `exportList.join(', ')` and sends it as a *scalar*
   `id`, so a 2+ selection posts `{id: "30427858, 30427830"}`. `CycleCountController.java:111` does
   `Long.parseLong((String) reqMap.get("id"))` — **outside** the `try` at `:123`. Single selection works;
   2+ always 500s. **Do NOT confuse with PR #43** (archived plan `260610-excel-export-localdatetime-*`),
   which fixed a *different* cycle-count export 500 with the *identical* UI toast and explicitly listed
   pre-`try` input parsing as out of scope — that is precisely why this survived.
   `/cancel` on the **same controller** (`:82-86`) already parses a CSV id list correctly = the
   reference impl. **Trim trap:** cancel's pop joins with `','` (no space) so its un-trimmed
   `split(",")` survives; export's pop joins with `', '`, so any fix must `trim()`.
2. **Positionless CC ⇒ silently corrupt xlsx.** `CyclecountService.java:159` throws
   `BusinessException`, the controller catches it into the **same 200** response, and the UI reads that
   as a blob → downloads a `.xlsx` whose bytes are `[{field=..., message=...}]` with **no toast**
   (`if (result.errors)` is dead on a Blob). Live wineco-dev: **66/85 = 77.6% of CREATED cycle counts
   have zero positions** (FINISHED: 0/59). Note `errors.toString()` is Java `Map.toString()`, **not
   JSON**.

**Escape path proven:** `RestExceptionHandler` (global `@ControllerAdvice`) has **no**
`Exception`/`RuntimeException` handler, and `RestEndpointExceptionHandler`'s `Exception` catch-all is
`@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")` — which **excludes**
`net.aim_ai.wms.controller`. So `NumberFormatException` → raw 500. But `EntityNotFoundException` **IS**
handled (`:135`), so the pre-`try` `findById` at `:116` is *not* a 500 source — don't over-claim it.

**LANDMINES for the implementer:**
- `response.reset()` in the new error path would strip CORS headers → see [[wms2-response-reset-strips-cors-headers]].
- `parseCycleCountIds` must be **`public static`**, not package-private: zero test classes live in
  `net.aim_ai.wms.controller` (tests are in `net.aim_ai.wms.unit.controller`), so package-private
  won't compile from the test.
- wms2-web-ui jest (27.4.4 / jsdom 16.7) has **no `URL.createObjectURL`** and **no `Blob.prototype.text`**
  — stub both, else the download path throws into its own catch and the "generic toast" test passes for
  the wrong reason (false green). Store-spec pattern to copy: `test/store/internalOps/replenishments.spec.js`
  (`actions.X.call(thisArg, context, payload)`).
- `AbstractBaseEntity.hashCode()` returns `getClass().hashCode()` — **constant** — so the itemdata
  `HashMap` is single-bucket (hence today's arbitrary export row order). Use `LinkedHashMap`, and keep
  the inner map scoped **inside** the per-CC loop or lookup cost goes quadratic.
- `fileExportService` is a `@Mock` in `CyclecountServiceUnitTest`, so **no test there produces xlsx
  bytes** — assert headers/rows with `ArgumentCaptor`. "Byte-identical" for the single-CC path holds
  *by construction* (legacy method untouched), never by byte comparison (POI embeds `dcterms:created`).
- Existing export tests pass `null` as the response; copying that into the merged path NPEs at
  `setHeader`.
- `CycleCountControllerUnitTest` is `@Nested` — `-Dtest='Class#method'` silently no-ops (false green).
- `wms2-api` local checkout was left on `bugfix/SBDEV-2777-...`; branch off fresh `origin/develop`.

**Adjacent defects found while enumerating (both out of scope, recorded):**
- **SBDEV-2797** (filed 2026-08-02): `exportBolPop.vue:72` sends only `selectedItems[0].id`, so BOL
  bulk export **silently exports just the first** selected BOL.
- ≥18 sibling unguarded `@RequestBody Map` numeric coercions in controllers outside `.controller.rest`
  — `PickingController:341` is a character-for-character twin, and **six live in `CycleCountController`
  itself** (`:153,165,166,178,179,180`, `Long.valueOf((Integer) ...)` → `ClassCastException` → 500).
  Cheapest broad fix would be an `@ExceptionHandler(Exception.class)` on `RestExceptionHandler`.
