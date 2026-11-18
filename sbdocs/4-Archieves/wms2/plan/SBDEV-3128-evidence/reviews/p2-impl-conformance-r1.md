head: e61ff93

# SBDEV-3991 (SBDEV-3128 P2) conformance + UI wiring review, round 1

Worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-web-ui/SBDEV-3991 (read-only review; no files modified).

## Evidence
- Jest (3 specs): `Test Suites: 3 passed, 3 total; Tests: 54 passed, 54 total` (matches the expected 54).
- SFC template compile (vue-template-compiler, worktree node_modules): storageLocation, boundDefaultsDialog, fixedLocation, updateBound, moveFixedLocation -> 0 errors, 0 tips each.
- Not run: mutation checks, full suite, real-browser render (Jest does not mount these templates; wiring below is by reading).

## Conformance

| Id | Criterion | Status | Evidence |
|---|---|---|---|
| U1 | Fixed Locations: chip column, default line, reset item, export column | VERIFIED | fixedLocation.vue: header `{ text: 'Bounds', value: 'boundsStatus' }`; slot `#[`item.boundsStatus`]` with `<v-chip v-if="item.boundsStatus" ...>`; derived `boundsStatus: boundsStatus(item), defaultBounds: defaultBoundsLine(item)`; details `'defaultBounds': 'Default (Min / Hyst. / Max)'`; export `bounds: boundsStatus \|\| ''` |
| U2 | updateBound note | VERIFIED | `<v-alert dense text type="warning">{{ overrideNote }}</v-alert>` = "Saving marks this assignment Overridden; it will no longer follow its location's default." (unconditional, matches §3.7) |
| U2b | move note for Overridden rows | VERIFIED | moveFixedLocation.vue `<v-alert v-if="overriddenNote" ...>`; `overriddenNote` = `isOverridden(this.item) ? "This assignment is Overridden: ..." : ''`. Wording differs slightly from plan ("Use the reset item ('Use … default')" vs "Use '…default'"); non-blocking by plan. |
| U3 | store `resetBoundsToDefault` | VERIFIED | store/masterData/fixedLocation.js posts `/fixedAssignment/resetBoundsToDefault` `{ id }`; `{errors}` -> false; catch -> false; success -> reload + true |
| U4 | storageLocation.vue: 3 columns, flowbin Set, non-flowbin Clear (D7) | VERIFIED | headers `defaultMinAmount/defaultHysteresis/defaultMaxAmount`; `v-if="isFlowbin(item)"` Set, `v-else-if="hasBoundDefaults(item)"` Clear; `locationType` is on the detailView row (ViewDtoService.java:823 `dto.put("locationType", result.getSltname())`) |
| U5 | store `updateBoundDefaults`; dead actions untouched | VERIFIED | storageLocation.js `$axios.$post('/location/updateBoundDefaults', body)`; true/false; diff leaves `createStorageLocation`/`updateStorageLocation` unchanged |
| UI-1 | action posts `{id,min,hyst,max}`; Clear = 3 nulls; true/false | VERIFIED | test/store/masterData/boundDefaultsActions.spec.js + boundDefaultsUi.spec.js "clear() posts three nulls" (green) |
| UI-2 | dialog validation 0<=min<=hyst<max, <=4 dp, partial blocked | VERIFIED | util/boundDefaults.js `validateBoundDefaults`; test/util/boundDefaults.spec.js; dialog.submit calls it before dispatch. Extra: rejects >=1e13, matching server |
| UI-3 | Set hidden on non-flowbin | VERIFIED (predicate by Jest, v-if by read) | `isFlowbin` tested in util spec; template v-if wired (see wiring) |
| UI-3b | Clear only on non-flowbin with non-null defaults; posts 3 nulls | VERIFIED | `v-else-if="hasBoundDefaults(item)"`; "clearBoundDefaults posts three nulls" spec |
| UI-4 | reset posts `{id}`; enabled when Overridden or out of date; label switches | VERIFIED | `:disabled="!canResetBounds(item)"`, `{{ resetBoundsLabel(item) }}`; util specs for both predicates; resetBounds spec dispatches `{id}` |
| UI-5 | chip Inherited / Inherited (out of date) / Overridden | VERIFIED | `boundsStatus()` + chip slot; util spec. |
| UI-6 | both new actions false on `{errors}`; dialogs stay open on false | VERIFIED (deviation acceptable) | boundDefaultsActions.spec.js covers actions; boundDefaultsUi.spec.js "stays open when the save is refused" / "clearing is refused". No rows in the SBDEV-3560 sweep specs: the contract is proven directly, so no AC is unproven. Cost: a future sweep-driven audit will not list these two actions. Low. |
| UI-7 | move note only for Overridden | VERIFIED | 3 specs (Overridden shows, Inherited none, null item none) |

ClickUp bullets: Storage Locations Min/Hyst/Max columns VERIFIED; Set only on flowbin VERIFIED; dialog validation + Clear VERIFIED; Clear on non-flowbin with defaults VERIFIED; dead actions not reused VERIFIED; chip / effective default + source VERIFIED; "Use location default" / "Use default (system)" enabled when overridden or out of date VERIFIED; set-bound warning VERIFIED; move note VERIFIED; export Bounds column VERIFIED; write actions resolve true/false and dialogs close only on success VERIFIED for both new actions (dialog closes via `if (saved) this.$emit('close')`; clear-confirm via `if (saved) this.clearDefaultsItem = null`).

Judgement on deviations: util extraction, 3 consolidated spec files, no sweep rows. None leaves an AC unproven. Template wiring itself has no Jest coverage (no mount-level test of the menu v-if, chip slot, `:disabled`); it is verified here by reading only.

## Template wiring (read + compiled)

Correct:
- Menu v-if / v-else-if chain in storageLocation.vue is sibling-adjacent (`v-if="isFlowbin(item)"` then `v-else-if="hasBoundDefaults(item)"`); compiles clean.
- bound-defaults-dialog: `:show="boundDefaultsItem !== null"`, `@close="boundDefaultsItem = null"`; the child's `show` watcher prefills on open; closes only on `saved`. Close via X/Cancel emits close. `persistent` dialog, so no outside-click desync.
- Chip slot name `item.boundsStatus` matches header `value: 'boundsStatus'`; `v-chip v-if` hides it for rows without provenance (old API).
- Reset item `v-if="item.boundsStatus"` (derived row), `:disabled="!canResetBounds(item)"`, label from `resetBoundsLabel`.
- Full details (fixedLocation): `item` passed to showDetails is the derived row, so `boundsStatus` and `defaultBounds` are present and have field-names; the raw provenance keys are all in exclude-fields. Storage details come from `/location/locationDetailsById/{id}`, which the plan says carries the 3 default keys; field-names added.
- `moveFixedLocation`/`updateBound` receive `fixedLocationSelected`, set from the derived row, so `isOverridden` sees `boundsInherited`. Move posts only ids, so the extra derived keys never reach the server.

### Findings

**F1 (Medium) storageLocation.vue + components/masterData/confirmDialog.vue: Clear confirm shows download copy.**
storageLocation.vue: `<confirm-dialog :question="'Clear the replenishment defaults of ' + ... + '?'" :confirm-type="'Replenishment Defaults'" ...>`; confirmDialog.vue hard-codes `<v-card-text class="pa-0 mt-1">This will download the selected {{confirmType}} in the CSV file.</v-card-text>`.
Scenario: an operator clicks "Clear replenishment defaults" and the dialog reads "Confirm Replenishment Defaults ... This will download the selected Replenishment Defaults in the CSV file." Accept then writes three nulls to the location, which also writes inherited FLAs back to the system default (D7). A destructive action is confirmed under text that says it only downloads. Fix: give confirmDialog an optional prop (e.g. `detail`) defaulting to the current text, or use `DeleteDialog`/a small dedicated confirm; add a Jest assertion on the rendered text. Not covered by any current test.

**F2 (Low) storageLocation.vue: Clear-confirm double-accept window.** `clearBoundDefaults` shows the page spinner but the confirm stays open until `saved`; a second Accept click before the overlay mounts would post a second (idempotent) clear. Harmless because the clear is idempotent; noted only.

**F3 (Low) cypress/support/helpers/wmsHelpers.js: unrelated comment edit** (SBDEV-2907 wording) is in this diff. Out of scope for SBDEV-3991; the memory file lists it as a pending fix, so it may be intentional, but it should be called out in the PR body.

**F4 (Low) fixedLocation.vue downloadLocations: scope extension.** Reads `unitLoad` instead of `unitload` (fixes an always-empty column), with the CSV header kept. Sensible and commented, but it changes export content beyond the ticket; mention in the PR. Test exists ("the row key is unitLoad").

**F5 (Low) moveFixedLocation note wording** differs from plan text (see U2b). Non-blocking.

No High findings. No syntax or binding errors found.

## Verdict
**PASS with one Medium (F1) to fix before PR.** All U1-U5 and UI-1..UI-7 and every ClickUp bullet are VERIFIED. Conformance is complete; F1 is a wiring/copy defect in a shared component outside the Jest coverage.
