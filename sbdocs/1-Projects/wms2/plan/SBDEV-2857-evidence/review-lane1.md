# SBDEV-2857 — review lane 1 (independent, read-only)

- Commit: `95ec9d3` on `bugfix/SBDEV-2857-transfer-source-guidance` (worktree `.claude/worktrees/wms2-mobile-ui/SBDEV-2857`, 1 ahead of origin/develop)
- Reviewer: code-reviewer lane 1, 2026-10-14. Nothing in the worktree was edited, stashed or committed.
- Vuetify actually installed: **2.7.2** (`node_modules/vuetify/package.json`; package.json says `^2.6.14`).
- Evidence instruments:
  1. Vuetify 2.7.2 source read: `VAutocomplete.js` (filter default L23-27, `onFilteredItemsChanged` L191-213, `setSearch` L362-369, `onInput` L309-317), `VSelect.js` (`onKeyDown` L627-655, `onBlur` override L558 that does NOT clear `isFocused`, click-outside `blur` L273-279), `VMenu.js changeListIndex` L229-254 (Enter clicks `tiles[listIndex]`), `directives/click-outside` (handler deferred by `setTimeout 0`).
  2. **Real-Vuetify jsdom probe** (not stubs): `review-lane1-real-vuetify-probe.spec.js` next to this file. Mounts the real `scanUnitLoad.vue` with `vuetify/dist/vuetify.js`, types char-by-char, then Enter keydown -> keyup. Run from the worktree with
     `npx jest --roots <dir-of-probe> --modulePaths /Users/np1076/dev/spk/owl/v2/wms2-mobile-ui/node_modules --cache=false`. Output:
     ```
     A dispatched ["UL351514"] errors [] sel UL351514            <- scanned "UL35151" (not eligible)
     B dispatched ["UL351514"] errors [] sel UL351514            <- scanned the LOCATION "37-XG06"
     C1 dispatched ["UL351514"] ... inputval "UL351514 — 37-XG06 — qty 6"
     C2 dispatched ["UL351514","UL351514"] sel UL351514 search "UL351514 — 37-XG06 — qty 6UL340022" errors []
     D right after click errors ["UL999 is not an eligible source for this SKU"] search "UL999"
     D after timers errors [] search null dispatched []
     ```
     Caveat: jsdom, not a handheld. The key/microtask ordering it exercises is Vuetify's own, so I expect the device to match, but a device check is still owed.
  3. WineCo PRD (`wsl-wineco-prd`) exposure queries over the exact eligibility predicate of `getStockUnitItemIdAndNotLocked` (entity_lock=0, usefortransfer, amount>0): 12,692 eligible stock units; **0** (label, sku) duplicates; **0** eligible labels that are a case-insensitive substring of another eligible label/item text for the same SKU; **0** case-only label collisions across all unit loads; **1,481** eligible ULs whose label equals their location name; **1,317** (SKU, location) pairs holding more than one eligible UL; 0 eligible labels with >1 stock unit.
  4. `npx jest` on the three new specs: 3 suites / 19 tests PASS.

## Stage 1 — spec compliance

| AC | Verdict |
|---|---|
| Source location shown before UL scan | MET — `suggested-source` block (scanUnitLoad.vue L21-25) shows `pickSources[0]`, which is the server's deep-storage-first order (`MobileTransferOrderService.updateOrderPositionPickSources`, origin/develop L234-320). |
| Eligible ULs and quantities selectable or validated on scan | PARTIALLY MET — selectable yes; "validated on scan" is defeated by H1 (a non-eligible or non-UL scan is silently resolved to an eligible UL) and H2 (a rescan is ignored). |
| Lane visible throughout | MET — selectOrderPosition (pre-existing), scanUnitLoad L7, scanTransferLane L6-10. |
| Clear messages for missing / invalid scans | PARTIALLY MET — Enter path OK for a non-matching scan; M1 (Submit-tap error wiped), M2 (misleading "No eligible source" on an API error). |

Payload contract (focus 2): unchanged and correct. `Object.assign({}, orderPosition)` still carries `transferOrderPositionPickSourceDtoList`, which `validateUnitByUnitLoadInput` iterates; `inputUnitLoad` is now the source's exact `unitLoadLabel`, which `getByUnitLoadLabelId` matches with a case-sensitive `ul.labelId = :labelId` (StockunitRepository L578-582) — sending the canonical label is strictly better than the raw scan. The store's later steps are unaffected: `processTransferLane` -> `updateOrderPosition` refills the list when `amountFulfilled=false` (service L222-227), and the page `v-if`s remount `scanUnitLoad` on every return to `3_unitLoad`, so `selectedLabel` starts null each loop. Lane payload (`inputTransferLane`, trimmed) unchanged; backend compares `transferLane.getName().equals(...)` exactly, as before.

Case-insensitive client match (focus 3): cannot pick the wrong source on PRD data today (0 case collisions; label lookup is the source's own label). Safe. The wrong-source risk is not in `findPickSource` — it is in Vuetify's substring filter (H1).

## Findings

### [HIGH] H1 — Enter on a scan that is only a SUBSTRING of an item's text auto-selects and submits that item
- File: `components/transferOrder/scanUnitLoad.vue:31-33` (`:items="sourceItems"` with composite text + `auto-select-first`), `:84-86`; `util/transferPickSources.js:11-13` (item text includes location and qty)
- Confidence: HIGH (Vuetify source + probe A/B)
- Issue: VAutocomplete's default filter is `itemText.toLowerCase().indexOf(query) > -1` over `"UL — location — qty N"`. With `auto-select-first`, `onFilteredItemsChanged` sets `listIndex=0`; Enter **keydown** queues `menu.changeListIndex` -> `tiles[0].click()` -> `selectItem` in a microtask, so by **keyup** `selectedLabel` is already the first substring match and `searchText` already holds its full text — the exact-match fallback in `submit()` never sees the raw scan. Probe: scanning `UL35151` (not eligible) dispatched `UL351514`; scanning the **location** barcode `37-XG06` dispatched the first UL at that location with no error. The "invalid scan" message only appears when the scan matches no item's text at all — and whether a substring scan is rejected (fallback, exact match) or silently accepted (tile click) depends on whether the menu tiles had rendered before Enter, i.e. on timing.
- Exposure (WineCo PRD): label-substring collisions = 0 today, but 1,317 (SKU, location) pairs hold several eligible ULs, and the new "Go to: <location>" prompt invites scanning the location label — which then picks the first UL at that location instead of the one in hand. Moving stock from a UL the operator did not scan is an inventory discrepancy (the lane screen does show the chosen UL, which is the only backstop).
- Fix: match the Replenishment shape — `:items` of plain labels (`text` = label, so the filter only sees the label) with an `item` slot rendering `pickSourceText`; **and** drop `auto-select-first` (with it false, `onFilteredItemsChanged` sets `listIndex=-1` and Enter clicks nothing), leaving `submit()` to resolve the scan by exact `findPickSource`. Add a real-Vuetify test (see M3) scanning a prefix and a location and asserting no dispatch.

### [HIGH] H2 — A second scan while an item is selected is silently ignored; the previous UL is resubmitted
- File: `components/transferOrder/scanUnitLoad.vue:84-86` (`this.selectedSource || findPickSource(...)` — "A picked item wins")
- Confidence: HIGH (probe C)
- Issue: after a selection Vuetify writes the item text into the input and does not select it, so a wedge scan **appends**: search becomes `"UL351514 — 37-XG06 — qty 6UL340022"`. That matches nothing, `selectedLabel` stays `UL351514`, and `submit()` prefers it — probe C2 dispatched `UL351514` again with no error for a scan of `UL340022`. Realistic triggers: operator taps a list item then scans the UL actually in hand; a backend `{errors}` toast (e.g. `Unknown Stock`, the store keeps the screen) followed by a rescan, which loops on the same failing UL.
- Fix: in `submit()`, when the typed text is non-empty and differs from `pickSourceText(selectedSource)`, resolve the typed text and let it win (or error); additionally select-all on focus / clear `selectedLabel` + `searchText` after an error the way Replenishment's `selectOnFocus` and post-stage reset do (`components/replenish/process/selectUnitLoad.vue:23,227`). Note the append itself still needs clearing, or the typed text will be `"<item text><scan>"` and never match.

### [MEDIUM] M1 — Tapping Submit with an invalid typed label: the error flashes and is wiped, and the text is erased
- File: `components/transferOrder/scanUnitLoad.vue:72-73` (watchers clearing `errorMessages`)
- Confidence: HIGH (Vuetify click-outside + probe D)
- Issue: `submit()` runs on the click and sets `["UL999 is not an eligible source for this SKU"]`; then click-outside's deferred `blur()` -> `isFocused=false` -> `updateSelf()` -> `setSearch()` resets the search to `null`, emitting `update:search-input`, and the `searchText` watcher clears the message. Probe D: errors `[...]` right after click, `[]` one tick later, search `null`. (A VALID typed label + Submit does dispatch, because `submit` runs before the deferred blur — so the typed-fallback path the spec tests works, only its error branch is lost.) Enter-path errors are unaffected.
- Fix: clear errors only on user input (`@update:search-input` from typing, or compare to the previous non-null value), not on a programmatic reset to `null`; e.g. `searchText(v) { if (v) this.errorMessages = [] }`.

### [MEDIUM] M2 — An API error on processOrderPositionSelect now renders as "No eligible source stock found for this SKU"
- File: `components/transferOrder/scanUnitLoad.vue:26-28`; root cause pre-existing at `store/transferOrder.js:71` (commits `result` unconditionally; the `result.errors` branch is commented out)
- Confidence: HIGH
- Issue: `processOrderPositionSelect` returns HTTP 200 `{errors:[...]}` on a BusinessException (e.g. "Order has no transfer lane assigned..." — TransferOrderController L55-66, service L203-208). The store commits that as `orderPosition` and moves to `3_unitLoad`; `pickSourcesOf` returns `[]`, so the new alert blames stock availability. Before this commit the screen was blank (also wrong, but not misleading).
- Fix (in-ticket, small): restore the `result.errors` branch in the store action (toast + stay on `2_orderPosition`), or have the alert check `orderPosition.errors` first and show that message.

### [MEDIUM] M3 — The specs cannot see any Vuetify behaviour; H1, H2 and M1 all pass the suite
- File: `test/components/transfer-order-scan-unit-load.spec.js:27-31,48` (stub `v-autocomplete` that never filters, auto-selects, blurs or emits keyup)
- Confidence: HIGH
- Issue: every interaction is driven through the stub's `input` / `update:search-input` events and the Submit button. Surviving mutants by inspection (none of the 16 could have reached them): delete `@keyup.enter.prevent="submit"` (the primary scanner path is untested); delete or keep `auto-select-first`; swap the `selectedSource || typed` precedence (no test has both a selection and different typed text); delete either error-clearing watcher; delete `:disabled="!pickSources.length"` on the autocomplete (stub has the prop, no assertion); drop the "N other source(s)" span; on the lane screen delete the `scannedValue` watcher or the `:placeholder`. The "accepts a typed scan ... before the list auto-selects it" test drives the Submit button, not Enter, so it does not exercise the race its name describes.
- Fix: add one real-Vuetify mount spec (the attached probe shows it works in this repo's jest with `vuetify/dist/vuetify.js`): Enter after a prefix scan -> no dispatch + error; Enter after a location scan -> no dispatch; select then rescan -> second label dispatched; Submit tap with invalid text -> error still present after `setTimeout 0`. Mutation-check each (re-add `auto-select-first`, flip precedence, restore the unconditional watcher).

### [LOW] L1 — Lane field placeholder is the expected lane value
- File: `components/transferOrder/scanTransferLane.vue:24`
- Confidence: MEDIUM
- Issue: a dense grey `TransferLane19` inside the input reads as pre-filled on a small screen; Enter on an empty field then shows an error the operator may not expect. The lane is already bold in the header (L8).
- Fix: placeholder `Scan transfer lane` (as the error text does), or keep but as `hint`/`persistent-hint`.

### [LOW] L2 — Lane screen keeps a failed scan in the field; the next scan appends
- File: `components/transferOrder/scanTransferLane.vue:59-68`
- Confidence: HIGH (pre-existing, unchanged by this commit)
- Issue: after the backend toasts "Order has transfer lane = X", `scannedValue` remains and the next wedge scan becomes `"BADLANETransferLane19"`. Same shape as H2 on the lane screen.
- Fix: select-on-focus or clear `scannedValue` after a failed dispatch (needs the action to return a success flag).

### [LOW] L3 — "keeps the destination transfer lane on screen" pins pre-existing behaviour
- File: `test/components/transfer-order-scan-unit-load.spec.js:94-97`
- Confidence: HIGH
- Issue: `order.transferlane` was already rendered on this screen on origin/develop (old L7); the test is fine as a pin but not evidence for the change. Not vacuous, just mislabelled as SBDEV-2857 coverage.
- Fix: none needed; optionally reword.

### [LOW] L4 — `String(s.unitLoadLabel)` turns a null label into the string "null"
- File: `util/transferPickSources.js:21`
- Confidence: HIGH (mechanism) / no PRD case (labelid nulls not seen in eligible set)
- Issue: a scan of literal `null` would match a label-less source, and `pickSourceText` would render `null — loc — qty`.
- Fix: `s.unitLoadLabel != null && s.unitLoadLabel.toLowerCase() === wanted`.

### [LOW] L5 — `data-test` attributes shipped in production markup
- File: `components/transferOrder/scanUnitLoad.vue:17,21`
- Confidence: HIGH
- Issue: harmless; mention only for consistency with whatever the repo does elsewhere (`git grep data-test components` to decide).
- Fix: keep, or strip in build if the repo convention requires.

## Open Questions (surfaced, not blocking)

- [LOW] Duplicate `unitLoadLabel` values in the list (two eligible stock units of one SKU on one UL) would give the autocomplete two items with the same value and `findPickSource` would always return the first. PRD has 0 such groups today and the backend `getByUnitLoadLabelId` is `Optional` (would throw on >1 row anyway — pre-existing). Confidence LOW that it occurs.
- Device confirmation of H1/H2/M1 on a Zebra wedge is still owed; the probe is jsdom with real Vuetify. If the device's wedge sends a Tab suffix instead of Enter, `onTabDown` selects the highlighted tile too (VSelect L707-724) — same H1 outcome, and `submit` never fires.

## Positive observations
- The fix uses data the API already returns; no backend change, no store change, payload contract preserved.
- Sending `source.unitLoadLabel` instead of the raw scan is the right call — the backend label lookup is case-sensitive.
- `findPickSource`/`pickSourcesOf` are small, pure and well-tested; the util spec is not vacuous (trim, case, null, empty, order).
- Removing the `console.log` and the dead `this.valueSelected = null` lines; specific error copy instead of "Item is required".
- Spec comments explain why a real Vuex store and an event-emitting `v-btn` stub are needed — good instincts; extend the same honesty to the autocomplete (M3).

## Verdict
**REQUEST CHANGES** — H1 and H2 are HIGH severity at HIGH confidence: on the primary scanner path the screen can submit a unit load the operator did not scan, which is exactly the "validated on scan" AC. Both are fixable inside this ticket (drop `auto-select-first` + label-only item text; typed text wins over a stale selection), with a real-Vuetify spec to pin them.

Counts: Critical 0 · High 2 · Medium 3 · Low 5 · Open Questions 2

---

## Re-review of 37c5151

- Commit `37c5151` on top of `95ec9d3`, same worktree. HEAD verified to be `37c5151`, with a clean tree. This pass was read-only, with no edits, stash, checkout or commit.
- The five transfer suites pass: `transfer-order-*` ×3, `store/transferOrderScanResults`, `util/transferPickSources`, **41/41**. I did not re-run the full suite and am relying on the coordinator's 610-pass / 3-load-fail baseline for that.
- Second real-Vuetify probe: `review-lane1-rereview-probe.spec.js` is next to this file. It is run the same way as the first, from the worktree with `--roots <evidence dir> --modulePaths <wms2-mobile-ui>/node_modules`. It adds a **replace** mode, which models a device where the highlighted text is overwritten by the first scanned char. It also adds a **real tile click** in place of the programmatic `vm.selectedLabel =` assignment. Output:
  ```
  E  scan UL351514 (Enter) -> then replace-scan UL3515: first dispatched UL351514; partial refused "UL3515 is not an eligible source"
  E2 PROGRAMMATIC select UL351514, replace-scan UL3515: listIndex 0 before Enter -> dispatched ["UL351514"], no error
  E3 REAL tile click UL351514 (input text selected: selStart 0, selEnd 8), replace-scan UL3515: listIndex -1 -> refused, nothing sent
  F2 labels UL3515 + UL351514, scan UL3515 then replace-scan UL351514 (no selection): both dispatched correctly
  F4 TAP UL3515, then REPLACE-scan UL351514: dispatched [] errors ["14 is not an eligible source for this SKU"]
  F5 TAP UL3515, then APPENDED scan UL351514: dispatched ["UL351514"]
  G  type UL340022 then Tab: dispatched [], selection null, search reset to null, no error
  H  type "UL3", ArrowDown, Enter: dispatched ["UL351514"]   (deliberate keyboard highlight; not a scanner path)
  ```

### Disposition of the original findings

| # | Status | Evidence |
|---|---|---|
| H1 substring auto-select | **RESOLVED** | `sourceLabels` holds bare labels (scanUnitLoad.vue `sourceLabels()`), and `auto-select-first` is gone. Vuetify spec "partial label" and "location barcode" cases pass, and probe E3 refuses. Without `autoSelectFirst`, `onFilteredItemsChanged` sets `listIndex=-1` unless the previously highlighted item survives the filter (VAutocomplete.js L194-201). |
| H2 rescan ignored | **RESOLVED** | Typed text that is not the selection wins, and the prefix strip handles an append. Probe F5 and E3 pass, as does the spec "sends the unit load scanned after tapping a different one". A real tile click also leaves the input text selected (E3 selStart 0 / selEnd 8). |
| M1 error wiped on Submit tap | **RESOLVED** | Both watchers ignore falsy values. Spec "keeps the error a tap on Submit raised" passes under real Vuetify. `clearField()` sets null before the message, and the null-guarded watchers keep it. |
| M2 misleading "No eligible source" | **RESOLVED** | The `processOrderPositionSelect` refusal branch toasts and does not advance (store spec). |
| M3 stub-only specs | **MOSTLY RESOLVED** | A real-Vuetify spec was added, plus a store spec. Residual gap in R2 below. |
| L1 placeholder | RESOLVED | `placeholder="Scan transfer lane"`, plus the spec "does not prefill". |
| L2 lane field append | RESOLVED | `if (!accepted) this.scannedValue = null`, plus the spec "empties a scan the backend refused". |
| L3 pin labelled | RESOLVED | Comment at scan-unit-load.spec.js:96. |
| L4 null label | RESOLVED | `s.unitLoadLabel != null &&` (util L21), plus a util spec. |
| L5 data-test | ACCEPTED | The precedent was verified at `components/cancellation/cancellationAction.vue:37,39,45`. |

### Answers to the four questions

1. **Does the spec model the device faithfully?** Partly. The spec "taps" by assigning `w.vm.selectedLabel` and then always **appends** the scan. On a device a tap is a tile click. Probe E3 shows a real click leaves the input text fully selected (0..8), so the next scan **replaces** it. The common device path is therefore tap, then replace-scan, and the spec never drives it. That is exactly where R1 lives. The programmatic tap also yields a state a real click does not: E2 shows `listIndex` 0 tracking the selected item, so Enter on a partial scan re-clicks the selection and sends it, while the real click in E3 gives `listIndex` -1 and a correct refusal. The appended case is still worth keeping as the worst case, but it is not the representative one. → R2.
2. **Is the prefix strip ever wrong?** Yes. When the picked label is a true prefix of a different eligible label **and the scan replaced the text**, as on a device: tap `UL3515`, scan `UL351514` → `typed.startsWith('UL3515')` → stripped to `14` → refused with "14 is not an eligible source for this SKU" (probe F4). This is a safe failure, since no wrong UL is sent, but it is a false refusal with a baffling message. PRD exposure today is **0**: the first pass found 0 eligible labels that are a case-insensitive substring of another eligible label for the same SKU. The strip is also case-sensitive (`startsWith`) while matching is case-insensitive. That is harmless, because a case-different append then falls to "not eligible" and is never mis-resolved. → R1.
3. **Does Tab still select something?** No, nothing is selected or sent. `VSelect.onTabDown` clicks only an active tile, and `listIndex` is -1, so it calls `blur()`. `updateSelf()` → `setSearch()` then resets the search to null (probe G). The scan is silently dropped, with no error and no wrong UL. That matches the pre-change `v-text-field`, where Tab only moved focus. It matters only if WineCo's wedges are configured with a Tab suffix. → R3.
4. **Any store regression in `processTransferLane`?** None in flow or state. The commits and process transitions are unchanged. `return true` sits at the end of the else-branch and covers both the fulfilled and the not-fulfilled paths. `return false` is added on the `{errors}` branch and in the catch. The only caller is `scanTransferLane.vue:68`, and `cycleCount/processScanUnitLoad` is a different store, so it is untouched. On success every path changes `process` (`1_select` / `2_orderPosition` / `3_unitLoad`), so the screen unmounts and the `accepted` value is moot. One semantic wrinkle remains: if `transferStock` succeeds but the follow-up `/transferOrder/updateOrder` POST throws, the action has already toasted success, then toasts the error and returns false. The lane field is then emptied although the stock moved. A lane rescan is safe, because the backend sees the lane already holds enough and answers "No stock required…" before any write. → R4. `processOrderPositionSelect` on refusal leaves `orderPosition` = the selected row from its first commit, and `selectOrderPosition.vue` does not read `orderPosition`, so that is harmless.

### New / residual findings

**[LOW] R1 — Prefix strip false-refuses a scan whose label extends the picked label**
- File: `components/transferOrder/scanUnitLoad.vue`, `submit()`: `if (this.selectedLabel && typed.length > this.selectedLabel.length && typed.startsWith(this.selectedLabel)) typed = typed.slice(...)`
- Confidence: HIGH (probe F4); PRD exposure 0 today
- Fix: try the whole typed text first, and strip only when that fails:
  `const whole = findPickSource(this.pickSources, typed); const source = whole || (stripped && findPickSource(this.pickSources, stripped)) || ...`
  Add a spec with labels `UL3515` / `UL351514`: tap the first, then replace-scan the second.

**[LOW] R2 — The real-Vuetify spec's "tap" is a programmatic assignment and always appends**
- File: `test/components/transfer-order-scan-unit-load-vuetify.spec.js`, "sends the unit load scanned after tapping a different one" (`w.vm.selectedLabel = 'UL351514'` followed by `input.element.value += ch`)
- Confidence: HIGH (probe E2 vs E3)
- Issue: neither the real tap (a tile click, which selects the input text) nor the replace-scan that follows it on a device is exercised. The programmatic state also differs from a real tap, since `listIndex` tracks the selection in E2. That spec would therefore not catch a regression on the device path, and it hides R1.
- Fix: tap with `document.querySelectorAll('.v-list-item')[i].click()` after typing a prefix to open the menu (as probe E3 does), and add a replace-mode `scan()` variant (`input.element.value = ''` before the first char). Keep the append case as the worst case.

**[LOW] R3 — A Tab-terminated scan is silently dropped**
- File: `components/transferOrder/scanUnitLoad.vue` (only `@keyup.enter` is bound)
- Confidence: MEDIUM. The mechanism is HIGH (probe G). Whether WineCo's wedges send Tab is unknown.
- Fix: none needed if the scanners send Enter, which matches every other mobile scan screen. Otherwise add `@keydown.tab.prevent="submit"`.

**[LOW] R4 — `processTransferLane` returns false after the stock moved when the follow-up `updateOrder` fails**
- File: `store/transferOrder.js`, `processTransferLane` catch
- Confidence: HIGH (mechanism); rare (second POST failing)
- Issue: false conflates "lane refused" with "moved, but refreshing the order failed". The screen empties the lane field and the operator sees success then error toasts. This is not a regression: the state handling is unchanged and a rescan is safe.
- Fix: optional. Return true once `transferStock` has succeeded, or wrap the `updateOrder` call in its own try and toast its failure without signalling a refusal.

### Open Questions (re-review)
- [LOW] Can a device reach the E2 state, a selection with `listIndex` tracking it outside a tile click? In that state a partial scan that is a substring of the selected label sends the selected UL. Neither of the in-app paths that set `selectedLabel` (a tile click, Enter on an arrow-highlighted tile) reproduced it in the probe. Confidence LOW.
- Still owed from the first pass: a device check on a Zebra wedge. The probes are jsdom with real Vuetify 2.7.2.

### Re-review verdict
**APPROVE** (no CRITICAL, HIGH or MEDIUM open). All original High and Medium findings are resolved with real-Vuetify evidence. Four Lows remain open; R1 and R2 are the ones worth doing in this ticket under the fix-Lows-too rule, and they are one change: a whole-match-first `submit()` plus a real-tap, replace-scan spec.

Open counts after re-review: Critical 0 · High 0 · Medium 0 · Low 4 (R1-R4) · Open Questions 2
