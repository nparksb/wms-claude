---
name: sbdev-3120-monitor-hides-job-holds
description: "SBDEV-3120: the Replenishment Monitor's visibility gate and the release job's hold rule use different definitions of available, so held parcels vanish from the screen; v1 and v2 identical"
metadata: 
  node_type: memory
  type: project
  originSessionId: 411e9e67-30d3-4d8d-9429-961ab41472f2
  modified: 2026-08-27T18:08:36.306Z
---

**SBDEV-3120 / ST#1152 (WineCo).** A parcel sits On Hold with *"Not enough stock on location"* while its
SKU is **absent entirely** from the Replenishment Monitor. Root cause is a **definition mismatch between
two subsystems**, not a data glitch:

- `ReleaseOrderJobService` holds a position when `partitionallowed=false` and **no SINGLE stockunit**
  covers it (the SBDEV-2512 guard), even when the aggregate across units is sufficient.
- The monitor gated row visibility on `HAVING (bottles_needed - available_amount) > 0` where
  `available_amount` is a plain aggregate SUM. For a fragmentation hold that difference is **0**, so the
  row was suppressed. Every position held by that guard was therefore structurally invisible.

**Reproduced on the v2 UAT DB** (`wsl-wineco-uat` = `wh01_om1_v2` :25062): position 34054153, SKU 2508501,
Ackley Brands, amount 2, `partitionallowed=false`, only stock = **two stockunits of 1 each on `Club04`**
(area "Storage and Picking", pick-only). Deployed query returned 1 row and 0 for that SKU, matching the
ticket screenshots artifact-for-artifact (parcel `IV1783961186302` / order `ME101096`, Manifest WSL).

**v1 carries the identical defect** — `origin/release` and `origin/develop` have both clauses byte-identical
to v2; the v1↔v2 diff on that file touches only the `t3` lane exclusions, the projection return type and
cosmetics. But there is **no live v1 occurrence**: v1 PRD had 0 fragmentation holds, and its monitor shows
nothing at all anyway because `t1` hard-filters `cob.type = 'PICK_PACK'` while 85/85 open positions were
`CLUB`/`TRANSFER`.

## The traps that matter for any future work here

1. **Four sites write state 55**, not one: `ReleaseOrderJobService:166, :256` (no-fix-assignment /
   overstock path) and **`:304, :439`** (fix-assignment path, comparing the position against the ONE
   stockunit on the assigned unitload). The SBDEV-2512 guard is additionally gated on
   `if (fixAssignmentID == null)` (`:117`, `:228`), so for any SKU that HAS a fix assignment it never runs.
   **Any stock-derived arm therefore covers at most half the holds.** The robust signal is the job's own
   verdict: `cop.state BETWEEN 50 AND 58` (exactly the five `RAW_ON_HOLD*` states; deliberately excludes
   `CLIENT_HAS_NO_SECTION`=45 and `FUTURE_PICKING_DATE`=80).
2. **A derived arm comparing `max(position)` to `max(unit)` is not enough.** Positions 10 and 3 with units
   10/1/1/1: the job releases the 10 (consuming the big unit) then holds the 3, and both the aggregate and
   the max-vs-max arms evaluate false. Same symptom, still hidden.
3. **`getStockUnitsByItemDataId`** (`StockunitRepository.java:81-93`) is the candidate set the guard
   actually scans, and it filters **`useforpicking` only** — NOT `useforreplenish = false`. Mirroring the
   monitor's narrower `available_amount` predicate produces a false positive whenever the covering unit
   sits in a dual-purpose area. (Unreachable on WineCo: area 51552 has 0 locations.)
4. **State 56 always implies a shortfall** (`:196` — set only when "no fix assignment AND no overstock"),
   so it never needs special quantity handling. 57/58 are the only stock-independent holds and are
   unreachable while all fix assignments are active.
5. **`qtyNeeded` is rendered on the MOBILE Replenish>Critical list** verbatim
   (`wms-mobile-ui components/replenish/process/HeldUpList.vue:59`), so its numeric **scale** is
   user-visible — `cop.amount` is `numeric(17,4)` and `GREATEST` returns its operand verbatim, giving
   "4.0000 items" without an outer `round()`. The web click-through overlay is **dead code**
   (`showDetails()` in `replenishViewTable.vue:266` is never called); the web grid shows only
   `qtyRequested` ("Qty Req") and `qtyHold` ("Parcels").
6. **v1's deployed `replenishment_monitor_view` is a SECOND read path and is SDR-exported**
   (`GET /v3/replenishmentMonitorView`) — v1 has no `RestConfiguration.java`, and
   `MyRepositoryRestConfigurer` explicitly `exposeIdsFor(... ReplenishmentMonitorView.class ...)`. It
   carries all four original defects and a *different* `t2` predicate than the Java query, so the two v1
   paths already disagree. Fixing the Java query does not fix it.
7. **`location_area` has UNIQUE `(name, client_id)`** (`uk1yikbf06ancc8sh1eih66vyqq`), so an IT cannot seed
   two same-named areas for one client — and `Stock.units` only splits an amount EVENLY. Building an
   uneven set of unit sizes needs separate stockunits on one location.

Related: [[wms-fix-effort-tiers-and-the-floor]], [[run-v1-wms-api-testcontainers-its-locally]],
[[wineco-is-a-v2-client-prd-mcp-is-wms1-wineco]]
