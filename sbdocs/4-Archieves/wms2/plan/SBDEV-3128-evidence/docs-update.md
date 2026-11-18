# SBDEV-3128 Phase 1 (wms2-api) — Phase 4 doc drift pass

Date 2026-11-02. Code read through `git diff 8171c80a..747b9a39` in the SBDEV-3128 worktree (no code edited, no mvn). Doc scan method: `grep -rnE` over `sbdocs/3-Resources/` for FixLocationAssignment, lowerbound/middlebound/upperbound, FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE, fixedAssignment, flowbin_monitor_view, WEB_UI_VIEW_STORAGE_LOCATION, LocationController, getStockPerLocation / getFixedLocationAssignmentView / getLocationView. Blind spot: a doc that describes the change without any of those tokens would be missed, and `V2.2.4` hit only sysprop-seed rows (V2.2.40/42), none about location.

Unmerged text carries the exact token `✓ merged(SBDEV-3128: #601 4643acf5, 2026-11-02)`. `last_verified` was **not** bumped on any doc: each was checked only at the rows touched, which is the convention these docs already record in their `verified_by` fields. `verified_by` got a prepended SBDEV-3128 entry saying exactly what was checked.

## Docs changed (9)

| Doc | Change |
|---|---|
| `architecture/wms2-function-to-docs-map.md` | §4 Storage Locations / Fixed Locations endpoint cells corrected (D-7, below); new `updateBoundDefaults` and `resetBoundsToDefault` endpoints with their gates (pending-merge); pointer to design §6. |
| `data-dictionary/wms2-sysprop-catalog.md` | §6 three `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_*` rows: "fill %" corrected to absolute Min Amount / Hysteresis / Max Amount (D-7); pending-merge: location default seeds first, sysprop is the fallback and the V2.2.45 backfill source; ViewDtoService UPPER read removed (D-1). |
| `design/wms2-replenishment-design.md` | TL;DR :15 now names lowerbound eligibility, job-path middlebound trigger, upperbound target (D-7); §4 FLA rows :337-339 corrected from "default 0" (D-7); new `bounds_inherited` row; new §6 point 5b (columns, seed, override, write-through, reset, move, new detailView keys, pre-migration behaviour); §10 repository rows; log row. |
| `architecture/wms2-keycloak-role-matrix.md` | §3.3 cell notes on both endpoints' gates; §8 item 10 = I1 cross-screen write-through (storage-location-only user changes inherited FLA bounds); log row. |
| `workflows/wms2-replenish-workflow.md` | One Flow Overview bullet on inherited bounds (pending-merge); log row. |
| `architecture/wms2-entity-enumeration-report.md` | FixLocationAssignment row: `bounds_inherited` and location `default_*bound` exist in the DB but are deliberately unmapped (D8). |
| `data-dictionary/wms2-landlord-vs-tenant-entity-map.md` | FixLocationAssignment row: same unmapped-column note. |
| `data-dictionary/wms2-domain-glossary.md` | Lines 85-87: "36% / 60% / 84%" corrected to absolute quantities (same error as the sysprop catalog); pending-merge note on location default. Not on the analysis list; found by grep. |
| `data-dictionary/wms-domain-glossary.md` | :108 same percentage correction (the sentence is v2-specific). Same provenance as above. |

## Behaviour changes covered (each checked in the diff)

- New columns: `V2.2.45__location_default_fla_bounds.sql` adds `location.default_lowerbound/_middlebound/_upperbound` + `ck_location_default_bounds`, and `fix_location_assignment.bounds_inherited boolean NOT NULL DEFAULT false`.
- Unmapped: `LocationDefaultBoundsView` / native queries; `model/*` not in the diff stat.
- Endpoints and gates: `LocationController` `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STORAGE_LOCATION)` on `@PostMapping(path = "/updateBoundDefaults"`; `FixLocationAssignmentController` class-level `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_FIXED_ASSIGNMENT)` covers `@PostMapping(path= "/resetBoundsToDefault"`.
- New detailView keys: `ViewDtoService.putBoundsProvenance` puts `boundsInherited`, `locationDefault*`, `defaultSource`, `default*`, `boundsOutOfDate`; `getLocationView` puts `defaultMinAmount/Hysteresis/MaxAmount`.
- D-1: diff removes `BigDecimal upperBound = new BigDecimal(syspropService.getSysvalue(...UPPER_BOUND_KEY))` and the `getStockPerLocation(page, upperBound)` parameter.
- Seed order (location default, else sysprop) taken from plan §3.3 / §10.1; the service code is in the diff but only its sysprop helper (`FixLocationAssignmentService:390-392`) was line-checked.

## D-7 items (wrong regardless of this change), each verified before editing

1. **Function map :108,110, wrong endpoints.** Neither `/storageLocation/search/*` nor `/fixLocationAssignment/*` exists as a path in the controllers: `@RequestMapping("/v3/location")` and `@RequestMapping("/v3/fixedAssignment")`. Cross-checked with the UI stores (`wms2-web-ui/store/masterData/storageLocation.js` calls `/location/detailView`, `/location/locationDetailsById/`, `/location/create`; `fixedLocation.js` calls `/fixedAssignment/detailView`, `/move`, `/toggleActiveStatus/`). Fixed. Caveat: `DELETE /location/{id}` is described as SDR on the strength of the controller comment ("only its SDR item DELETE remains writable") and the store call; I did not inspect the SDR route table.
2. **Sysprop catalog :269-271, "fill %".** `FixLocationAssignmentRepository`: `" AND stockunit.amount < fla.lowerbound "` compares a stock quantity; `WmsConstants:1357,1359,1361` default values are `"36"`, `"60"`, `"84"`. Fixed.
3. **Replenishment design :337-339, "default 0".** `FixLocationAssignment.java:19,22,25` is `= BigDecimal.ZERO` (field initializer), but `FixLocationAssignmentService.systemDefaultBounds` (:390-392) seeds from `parseSyspropLong(...LOWER/MIDDLE/UPPER_BOUND_KEY, ...)`, and WmsConstants defaults are 36/60/84. Rows now say initializer `0`, created FLA gets 36/60/84. Fixed.
4. **Replenishment design :15 omits lowerbound.** `REFILL_ELIGIBILITY_FROM_WHERE` has `stockunit.amount < fla.lowerbound`; `ReplenishOrderJobService:183-190` has `middleBound` / `compareTo(middleBound) >= 0`. Fixed. Note §6 point 2 (`< fla.middlebound`) is consistent with the job path and was left alone.

## Stale or untouched, not edited (listing only)

- `design/wms2-replenishment-design.md` `last_verified` 2026-10-02 (31 days), other sections not re-verified.
- `architecture/wms2-scheduled-jobs-catalog.md:296` (last_verified 2026-09-06): lists `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY` as a `ReplenishOrderJob` tunable. Still true: `ReplenishOrderJob.java:759` reads it (not in the diff). Untouched.
- `architecture/wms2-transaction-osiv-boundary-map.md` (last_verified 2026-09-30): no row for `FixLocationAssignmentService.adjust*`, which this diff makes `@Transactional`. Possible gap, not a contradiction; not edited.
- `architecture/wms2-caching-strategy.md` (2026-08-31): plan §3.5 says no cache change; not verified against code here.
- `design/wms2-stockunit-design.md:94,114,137`, `workflows/wms2-receiving-putaway-workflow.md:393`, `workflows/wms2-move-stock-unitload-workflow.md:186,353`: mention FLA create/validation paths; the diff does not alter the behaviour they describe, but `createFixedLocationAssignment` now takes a location lock and an extra probe. Not checked line by line.
- `design/wms2-rest-api-reference.md`: covers only the `/rest/**` integration controllers; `/v3/location` and `/v3/fixedAssignment` are not in it. No edit warranted.
- `data-dictionary/wms2-sysprop-catalog.md` header `last_verified: 2026-09-10`; §2 (:69-115) and §11.3 listed in analysis §8 not re-read.
- `architecture/wms2-keycloak-role-matrix.md` `last_verified` 2026-08-26 (68 days, Yellow) and its own "Next due 2026-10-14" is passed.
- `architecture/wms2-function-to-docs-map.md` `last_verified` 2026-08-29.
- wms1 docs (`wms1-*`, `wms1-sysprop-catalog.md:201-203` "Integer (%)"): v1 is reference-only; the same percentage error likely exists there but I did not verify v1 code.
- `sbdocs/1-Projects/wms2/plan/README.md`, `architecture/README` MOCs: not touched.

## Not done

- No wms2-web-ui (Phase 2) documentation; UI is out of this phase.
- `✓ merged(SBDEV-3128: #601 4643acf5, 2026-11-02)` markers: 22 occurrences over 9 docs (counted with grep -ro; verified_by notes that mention the token inside a log row count too); `wms-merge` flips them.
