head: e61f9ab

# SBDEV-3991 (SBDEV-3128 P2, wms2-web-ui): implementation code review, round 2 (scoped)

- Scope: only fix commit `e61ff93..e61f9ab` (8 files, +286/-34), worktree `.claude/worktrees/wms2-web-ui/SBDEV-3991`.
- Server claims checked against `v2/wms2-api` `origin/develop` @ `09683d18` (fetched 2026-11-02).
- Tests: the 3 specs give **71/71 passing** (Node 18.20.5).
- Mutation checks were run on a `git archive e61f9ab` copy in the session scratchpad, never in the worktree. The worktree was not modified (`git status --short` is empty), and no checkout, restore or stash was run.

## Per-finding status

| r1 finding | Status | Evidence |
|---|---|---|
| F1 (Medium): Clear confirm said "download" | **RESOLVED** | `confirmDialog.vue` has a new `detail` prop (default `null`), and `detailText` falls back to the exact old sentence. Only `storageLocation.vue:179` passes `:detail`. The other 5 importers of `masterData/confirmDialog` (fixedLocation, packaging, skuUnit, skuData, storageLocation export) pass none, so their text is unchanged (the `:details=` hits are the fullDetails prop, not this one). `handlingUnits/*` import a different `common/confirmDialog.vue`. Mutations: ignoring `detail` → red; deleting `:detail` → red. The title still reads "Confirm Replenishment Defaults", which is acceptable. |
| F2 (Low): `bounds` column mid-row | **RESOLVED** | `bounds` is now last. Mutation back to the mid-row order → red. |
| F3 (Low): double submit | **RESOLVED** | `saving` (dialog), `clearing` (storageLocation) and `resetting` (fixedLocation) are each set before the await and cleared in `finally`. Save has `:loading`/`:disabled`, and Cancel/X/Clear are `:disabled`. Mutations removing each guard, or the `finally` reset of `saving` / `resetting`, → red. (Removing the `finally` reset of `clearing` is not separately asserted, a Low gap; see N3.) |
| F4 (Low): prefill untested | **RESOLVED** | The watcher specs cover open (including a null → `''` field) and close. `asText` moved to the exported `boundText`. |
| F5 (Low): clear-confirm state untested | **RESOLVED** | Success → `null`, refusal → row kept. |
| F6 (Low): `10^13` / number branch untested | **RESOLVED** | Specs for `1e13` vs `999999999999`, `5e-7` vs `0.0005` as numbers, and trailing zeros. |
| F7 (Low): >15 significant digits | **PARTIALLY RESOLVED** | The 15-significant-digit cap is in and tested (mutation → red). The second half of r1-F7 remains: `9999999999999.9999` still gets "must be less than 10000000000000", because `Number()` rounds it to `1e13` and the `UPPER_LIMIT` check (`util/boundDefaults.js:84`) runs before the significance check (`:85`). See N2. |
| F8 (Low): reset offered under SYSTEM_INVALID | **REFUTATION WRONG**: still open, now conf HIGH | See N1. |
| F9 (Low): no confirm before reset | **RESOLVED** | Menu → `askResetBounds` → persistent `v-dialog` → OK → `resetBounds`. It closes only on `saved`. It shows the target triple but not the current values (r1's optional "current → default"). Acceptable. The template wiring is untested (N3). |
| F10 (Low): nits | **RESOLVED except one cosmetic item** | `BOUNDS_STATUS` constant keys the chip colours. `overrideNote` moved to `data` (a module `const` would be leaner, but this is fine). The dialog Clear is hidden when `!hasBoundDefaults(item)`. Not touched: the `wmsHelpers.js` ~150-char comment line. It is cosmetic and can stay as is. |
| conformance F2 (double-accept) | **RESOLVED** | Via `clearing`. |
| conformance F3/F4/F5 (PR-body notes) | n/a to code | These still need a line in the PR body. |

## New findings

### N1 [Medium, conf HIGH]: the F8 refutation is false; the code, test and confirm copy now claim a server fallback that does not exist
Files: `util/boundDefaults.js:124-125`, `components/masterData/location/fixedLocations/fixedLocation.vue:375`, `test/util/boundDefaults.spec.js:163`.
```
 * It stays enabled under SYSTEM_INVALID: the reset write falls back to the built-in default
 * (FixLocationAssignmentService.systemDefaultBounds → SyspropService.parseLongOrDefault), so it succeeds.
...
const target = item.defaultSource === 'SYSTEM_INVALID' ? 'the built-in system default' : item.defaultBounds
```
Server, `origin/develop`:
- `SyspropService.java:342-347`: "Absent (null) → defaultValue; otherwise Long.parseLong with no trim. **A value it rejects throws NumberFormatException: the write paths let it fail**, the display path maps it to SYSTEM_INVALID." The body is `return Long.parseLong(value == null ? defaultValue : value);`.
- `FixLocationAssignmentService.systemDefaultBounds` javadoc: "a value Long.parseLong rejects still throws".
- `ViewDtoService.java:978-987`: SYSTEM_INVALID is emitted **only** when that same `parseLongOrDefault` throws `NumberFormatException`. A null (absent) sysprop falls back and gives `SYSTEM`, not `SYSTEM_INVALID`.

So SYSTEM_INVALID means, by construction, that the write-path parse throws. `resetBoundsToLocationDefault` → `lockAndResolveDefaultBounds` → `effectiveDefaultBounds` → `systemDefaultBounds()` throws NFE. `FixLocationAssignmentController.resetBoundsToDefault` catches only `BusinessException`, so the NFE escapes to `RestExceptionHandler` as a 500.

Failure scenario: a tenant has `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIN_BOUND = "10.5"`, and a location has no defaults. The row shows "Inherited (out of date)" with "Use default (system)" enabled. The operator opens it and reads "Replace this assignment's Min/Hyst/Max with **the built-in system default**? …", then clicks OK. The result is always a 500 toast. The confirm stays open (handled, no data harm), but the copy promises something the server never does. The spec name "(review F8, refuted)" and the javadoc fix a false server claim into the code. The same NFE also hits the Storage Locations Clear (`updateLocationBoundDefaults`: `clear ? systemDefaultBounds()`), whose new detail line promises a revert "to the system default".

Fix: apply r1-F8 as written. Have `canResetBounds` return false when `row.defaultSource === 'SYSTEM_INVALID'`, or keep it enabled but change the confirm text to "The system default is invalid (an administrator must fix the FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_* sysprops); this reset will fail." Flip the spec at `boundDefaults.spec.js:163` to `toBe(false)`, delete the javadoc claim at `:124-125`, and drop the `'the built-in system default'` branch or its spec at `boundDefaultsUi.spec.js:198`.

### N2 [Low, conf HIGH]: the check order still gives a wrong message just under the limit (residual of F7)
File: `util/boundDefaults.js:84-85`.
```
if (n >= UPPER_LIMIT) return `${LABELS[key]} must be less than 10000000000000`
if (significantDigits(text) > MAX_SIGNIFICANT_DIGITS) {
```
Failure scenario: Max `9999999999999.9999` (17 significant digits, below 10^13) gets "must be less than 10000000000000", because `Number(text)` is `1e13`. The new rule would give the correct message ("too many digits") if it ran first.
Fix: move the `significantDigits` check above the `UPPER_LIMIT` check, and add `triple('0','1','9999999999999.9999')` → `/too many digits/`.

### N3 [Low, conf HIGH]: the new template wiring is not protected by any test
File: `fixedLocation.vue:137` (`@click="askResetBounds(item)"`), `:225` (`@click="resetBounds(resetBoundsItem)"`), and `boundDefaultsDialog.vue:21` (`v-if="hasBoundDefaults(item)"`).
These mutations all stay **71/71 green**:
- revert the menu item to `@click="resetBounds(item)"`, which skips the F9 confirm entirely;
- make OK only close the dialog (`@click="resetBoundsItem = null"`);
- drop the `v-if` on the dialog Clear.

Also not asserted: that `clearing` resets to false after a clear. The F3/F9 fixes are therefore protected only at the method level. This is the known "templates not mounted" deviation, but F1 already established the source-scan pattern for this.
Fix: add source-scan assertions, as the F1 test does: the reset menu item calls `askResetBounds`, the confirm OK calls `resetBounds(resetBoundsItem)`, and the dialog Clear carries `v-if="hasBoundDefaults(item)"`. Also add `expect(scope.clearing).toBe(false)` to the clear in-flight spec.

## Mutation summary (scratch copy of e61f9ab, 3 specs)
Red, as expected: detail ignored · `:detail` removed · `resetting` guard removed · confirm closes on refusal · ask dispatches directly · `resetting` not cleared · `clearing` guard removed · submit guard removed · clear guard removed · `saving` not cleared · sig-digit check disabled · export order reverted.
Green, which is a gap (N3): menu bypasses the confirm · OK doesn't reset · Clear `v-if` removed.

## Positive observations
- Adding `detail` with the old sentence as its fallback is the minimal and correct shape, and no other caller is affected.
- All three in-flight flags are set before the first await and cleared in `finally`. The confirms close only on `saved === true`, which keeps the SBDEV-3560 convention.
- The F1 test checks both the default sentence (backward compatibility) and the caller's override.
- `BOUNDS_STATUS` is frozen and shared by `boundsStatus` and the chip colours.

## Verdict
**COMMENT, fix before the PR.** F1–F6, F9 and F10 are resolved, and F7 is partly resolved. The F8 refutation does not hold against `origin/develop`. SYSTEM_INVALID exists exactly when the write-path parse throws, so the reset (and the clear) always fail there, and the commit has added user-facing copy, a javadoc and a spec that state the opposite (N1, Medium). Nothing is High. N2 and N3 are Low and, under the repo convention, are fixed in the same pass.
