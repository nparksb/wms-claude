head: e61ff936218fb0789494f13a424872432520711b

# SBDEV-3991 (SBDEV-3128 P2, wms2-web-ui): implementation code review, round 1

- Worktree: `.claude/worktrees/wms2-web-ui/SBDEV-3991`, branch `feature/SBDEV-3991-bound-defaults-ui`, diff `origin/develop...HEAD` (25a7643 gate tests, e61ff93 implementation). 12 files, +877/-10.
- Wire contract checked against `v2/wms2-api` `origin/develop`: `LocationController.updateBoundDefaults` (+ `decimalOrNull`), `FixLocationAssignmentController.resetBoundsToDefault`, `ViewDtoService.getLocationView` / `putBoundsProvenance`, `FixLocationAssignmentService.updateLocationBoundDefaults` / `validateDefaultBounds` / `requireFlowbin`, `LocationService.getLocationDetails`.
- Tests: the 3 new specs give 54/54 passing. Full Jest suite gives 149 suites / 2714 tests, all passing (Node 18.20.5).
- Read-only: no file in the worktree was modified, and no checkout, restore or stash was run.

## Stage 1: plan conformance (§0.4 U1–U5, §3.7, §7.2 UI-1…UI-7, D6/D7/L-6)

| Item | Status |
|---|---|
| U4 / §3.7: 3 default columns, flowbin "Set…", non-flowbin "Clear…" only when defaults are non-null (D7) | Conforms (`storageLocation.vue` v-if / v-else-if) |
| U5 / UI-1: `updateBoundDefaults` posts `{id,minAmount,hysteresis,maxAmount}` as JSON numbers, three nulls on clear, returns true/false | Conforms. The server refuses non-Number values (`decimalOrNull`), and the dialog sends `Number(...)` |
| UI-2: client validation `0 ≤ min ≤ hyst < max`, ≤ 4 dp, all three or none | Conforms and mirrors `validateDefaultBounds`, including the `< 10^13` limit |
| U1 / UI-4 / UI-5: chip Inherited / Inherited (out of date) / Overridden; reset enabled when Overridden or out of date; label by `defaultSource` | Conforms |
| U3: `resetBoundsToDefault({id})`, reloads on success, true/false | Conforms |
| U2 / U2b / UI-7: updateBound note; move note only for Overridden | Conforms |
| UI-6: both actions return false on `{errors}` and on rejection; dialogs stay open on false | Conforms in code. The SBDEV-3560 sweep specs were not extended (known deviation) |
| Export: Bounds column | Present, but its position shifts existing columns (F2) |
| Details: "Default: … (location / system / system default invalid)" | Conforms (label "Default (Min / Hyst. / Max)" plus the value line) |

Stage 1 passes. Every finding below is in Stage 2.

## Findings

### F1 [Medium, conf HIGH]: the Clear confirmation tells the operator it will download a CSV
File: `components/masterData/location/storageLocations/storageLocation.vue` (new `<confirm-dialog … :confirm-type="'Replenishment Defaults'" …>`), reusing `components/masterData/confirmDialog.vue`, which hardcodes:
```
<v-card-title class="pa-0">Confirm {{confirmType}}</v-card-title>
...
<v-card-text class="pa-0 mt-1">This will download the selected {{confirmType}} in the CSV file.</v-card-text>
```
Failure scenario: an operator clicks "Clear replenishment defaults" on a non-flowbin row. The dialog says "Confirm Replenishment Defaults … Clear the replenishment defaults of P-01? **This will download the selected Replenishment Defaults in the CSV file.**" The dialog describes a harmless download, but the action is a destructive write. It also writes the location's inherited FLA back to the sysprop default. An operator who trusts the text may accept without meaning to clear anything. Jest cannot see this because the template is not mounted (known deviation), and the manual DEV test is the only thing that would catch it.
Fix: give `masterData/confirmDialog.vue` an optional `detail` prop that defaults to the existing download sentence, so current callers are unchanged. Pass `detail="Inherited assignments at this location revert to the system default."` and a title such as `confirm-type="Clear Replenishment Defaults"`. Another option is a small dedicated confirm. Add a spec that asserts the rendered text, or at minimum the prop wiring.

### F2 [Low, conf HIGH]: the new `bounds` CSV column is inserted mid-row and shifts `clientName` / `active`
File: `components/masterData/location/fixedLocations/fixedLocation.vue` `downloadLocations()`:
```
({location, itemData, unitload: unitLoad, minAmount, hysteresis, maxAmount, bounds: boundsStatus || '', clientName, active}))
```
Failure scenario: the commit keeps the header `unitload` "so existing consumers of the file are unaffected". But a consumer that reads by position (a spreadsheet macro, or an import that maps column 7 to the shipper) now gets `bounds` where `clientName` used to be. The test pins this order (`boundDefaultsUi.spec.js` "Fixed Locations export"), which locks the shift in.
Fix: append `bounds` after `active`, and update the expected header and row in the spec.

### F3 [Low, conf HIGH]: no double-submit guard on Save / Clear / Accept
Files: `boundDefaultsDialog.vue` (`@click="submit"` / `@click="clear"`, no `:loading` / `:disabled`) and the Clear `<confirm-dialog>` in `storageLocation.vue`.
Failure scenario: `CommUtil.showPageSpinner` shows a `v-overlay` with the default z-index 5, which sits below the `v-dialog` content (about 200). The dialog buttons stay clickable while the POST is in flight. A double click sends two POSTs, two success toasts and two reloads. Each write is idempotent, so no data is corrupted, but the spinner hides when the first call finishes while the second is still running. Existing dialogs such as `updateBound.vue` behave the same way.
Fix: add a `saving` flag to the dialog. Set it in `save()` and clear it in `finally`. Bind `:loading="saving"` on Save and `:disabled="saving"` on Clear and Cancel. In `clearBoundDefaults`, return early when a clear is already in flight.

### F4 [Low, conf HIGH]: test gap: the reopen prefill (the `show` watcher and `asText`) has no test
File: `boundDefaultsDialog.vue`:
```
watch: { show(open) { if (open && this.item) { this.minAmount = asText(this.item.defaultMinAmount) ... } } }
```
No spec references the watcher (`grep watch|prefill` over the 3 specs gives 0 hits). Deleting the watcher, or prefilling from a stale field, keeps every test green. In that case the dialog opens with the previous row's values, or empty for a location that already has defaults, and Save writes them.
The code itself is correct. `:value="show"` works with the persistent dialog, the prefill re-runs on every false→true transition, values for a different row are overwritten with '' when that row is null, and API numbers are normalised through `String(Number(v))`.
Fix: add a spec that calls `BoundDefaultsDialog.watch.show.call(scope, true)` with `item.defaultMinAmount = 24.5` (and a null row) and asserts `minAmount === '24.5'` (and `''`).

### F5 [Low, conf HIGH]: test gap: the confirm dialog's state after Clear on Storage Locations (SBDEV-3560 shape) has no test
File: `storageLocation.vue` `clearBoundDefaults`:
```
if (saved) { this.clearDefaultsItem = null }
```
The UI-3b spec checks only the dispatch payload. Moving `this.clearDefaultsItem = null` into `finally`, so the dialog closes on a refusal, keeps every test green. That breaks the convention the ticket cites.
Fix: assert that `scope.clearDefaultsItem` is null after `dispatch → true` and still holds the row after `dispatch → false`.

### F6 [Low, conf HIGH]: test gap: the `10^13` limit and the number branch of `decimalText` have no test
File: `util/boundDefaults.js`:
```
if (n >= UPPER_LIMIT) return `${LABELS[key]} must be less than 10000000000000`
...
if (typeof v === 'number') { ... return v.toFixed(10).replace(/\.?0+$/, '') }
```
Deleting the `UPPER_LIMIT` line keeps everything green, and so does breaking the regex on the `toFixed` path, because only integer numbers are tested. The plan's mutation floor (§7.3) requires every new rule to be seen red.
Fix: add `triple('0','1','10000000000000')` → `/less than/`, `triple('0','1','9999999999999')` → null, and `triple(0.0005, 1.25, 2.5)` as numbers → null.

### F7 [Low, conf MEDIUM]: values with more than 15 significant digits lose precision silently
Files: `boundDefaultsDialog.vue` `submit()` (`Number(this.minAmount)`) and `validateBoundDefaults` (`Number(text)`).
Failure scenario: `numeric(17,4)` holds 17 significant digits, and a JS double holds about 15.9. The input `1234567890123.4567` passes the client checks (4 dp, `< 10^13`) but goes on the wire as `1234567890123.4568`, and the server stores that value. Input just under the limit (`9999999999999.9999`) rounds to `1e13`, and the client says "must be less than 10000000000000" for a value that is in fact below it. These quantities are unrealistic for bin bounds, and the API contract mandates JSON numbers, so this is informational.
Fix: none is needed. Optionally, refuse input with more than 15 significant digits on the client and show a clear message.

### F8 [Low, conf MEDIUM]: reset is offered when it cannot succeed (SYSTEM_INVALID with no location default)
File: `util/boundDefaults.js` `canResetBounds`. `putBoundsProvenance` sets `boundsOutOfDate = true` when `effective == null`, so an Inherited row under `SYSTEM_INVALID` gets an enabled "Use default (system)" item. `resetBoundsToLocationDefault` then fails on the unparseable sysprop. Per plan §3.3, the write paths fail on that sysprop. The failure comes back as `{errors}` or a 500 ProblemDetail, which the action surfaces as a toast, so it is handled, but the UI offers an action that is guaranteed to fail.
Fix: disable the reset, or show a tooltip, when `row.defaultSource === 'SYSTEM_INVALID'`, and add a spec row.

### F9 [Low, conf MEDIUM]: reset overwrites manual (Overridden) bounds in one click, with no confirmation
File: `fixedLocation.vue` menu item `@click="resetBounds(item)"`. The operator's hand-set Min/Hyst/Max are replaced at once, and the old values are not shown anywhere afterwards. The plan does not require a confirm, so this is a UX suggestion only.
Fix (optional): a confirm that shows "current A / B / C → default X / Y / Z (location|system)", built from `defaultBoundsLine`.

### F10 [Low, conf HIGH]: simplification and nits
- `fixedLocation.vue`: `BOUNDS_CHIP_COLORS` is keyed on the display strings returned by `boundsStatus`. A copy edit to the chip text would silently drop the colour. Return a status code (`OVERRIDDEN` / `INHERITED_STALE` / `INHERITED`) with a label map, or colour from `canResetBounds(item)`.
- `updateBound.vue`: `overrideNote` is a constant written as a computed. A literal in the template, or a `const`, is enough, and its UI-7 test asserts a constant.
- `cypress/support/helpers/wmsHelpers.js`: the re-wrapped comment line is about 150 characters while its neighbours are about 110. Cosmetic only. The seven-column claim is accurate, as `StockrecordViewRepository:118` on develop COALESCEs `tounitload`.
- `boundDefaultsDialog.vue`: `clear()` in the dialog posts nulls even when the flowbin has no defaults, and still shows the toast "Replenishment defaults cleared". This is harmless. You could hide or disable Clear when `!hasBoundDefaults(item)`.

## Checked and found correct (no finding)
- Wire keys `locationType`, `defaultMin/Hysteresis/MaxAmount` on `/location/detailView`, and `boundsInherited`, `boundsOutOfDate`, `defaultSource`, effective `default*` and `locationDefault*` on `/fixedAssignment/detailView` all match `ViewDtoService` on develop. `locationDetailsById` also carries the defaults (when `featureColumnsPresent`), so the Storage Locations details panel labels are live.
- Values are sent as JSON numbers. Clear sends three JSON nulls, which the server treats as clear (D7). Flowbin is matched with `=== 'flowbin'`, the same check as `WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN`.
- `{errors}` 200 refusals produce a toast of `errors[0].message` and `false` with no reload. Rejections go through `apiErrorReason`, so the ProblemDetail detail is shown, and return `false`. Spinners are released in `finally`. This is consistent with SBDEV-3560.
- `v-dialog :value="show" persistent` is correct: no v-model on a prop, and close happens only through the `close` event, which is emitted only after `saved === true`.
- Older-API rows with no provenance show no chip and no reset item (`typeof boundsInherited === 'boolean'`).
- The export fix (`row.unitLoad`) is correct. The key is `unitLoad` in `getFixedLocationAssignmentView`.

## Positive observations
- The pure rules live in `util/boundDefaults.js`, with javadoc that cites the exact server source. This makes the wire contract auditable and gives fast tests.
- The store specs use `toBe(true)` / `toBe(false)` and assert that the action exists first, so a stub cannot pass a refusal case.
- The client validation mirrors the server's order and inclusivity (`l ≤ m`, `m < u`, scale ≤ 4, `< 10^13`), and decimal places are counted with trailing zeros ignored, the same way the server parses the JSON double.
- The commit catches and documents the long-standing `unitload` → `unitLoad` export bug.

## Verdict
COMMENT: no High findings. F1 (Medium) should be fixed before the PR, because the confirm text misdescribes a destructive action. F2–F10 are Low and per the repo convention are addressed in the same pass. Tests are green (54/54 new, 2714/2714 full), and F4–F6 list the assertions the mutation floor still needs.
