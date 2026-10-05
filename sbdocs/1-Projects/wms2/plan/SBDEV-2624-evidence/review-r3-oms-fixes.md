# SBDEV-2624 - round-3 review of the OMS round-2 fix commits

head: 176d38c0 (range a1801d2c..176d38c0 = 4449bfad + 176d38c0). Reviewed in /Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624; `git status` clean before and after. No edit, checkout, restore or stash.
Reviewer lane: code-reviewer, separate from the authoring lane.

## Summary
Files: 4 (WmsApiService.php, api-docs.json, ProductControllerTest, WmsApiServiceTest). Issues: Critical 0, High 0, Medium 0, Low 3.
Recommendation: APPROVE. Every claimed fix (M1, L1-L7) is correct. The new tests fail for their own reasons.

## Evidence
- api-docs.json: `git diff origin/develop 176d38c0 -- storage/api-docs/api-docs.json` (after `git fetch`) is exactly 1 insertion and 1 deletion, the `item_id` description line in LegacyInventoryController. `json.load` OK. `git diff 361ca2ed 176d38c0` on the file is the same single line. M1 is fixed. `git diff --check` is clean.
- Test run on the throwaway recipe. Before running: DB_/LANDLORD_/REPORTING_HOST = oms-test-mysql (om1_owltest, om1_landlord_owltest, om1_owltest_reporting), MONGODB_HOST = oms-test-mongo, 229 tables, processlist idle.
  - Filtered set (skip-reason, bad-map, metachar, previousSkuCases, bad-map log): 24 passed, 43 assertions.
- Mutants, applied by bind-mounting a mutated copy of WmsApiService.php over the container path (worktree untouched, status clean after):
  - A: edge-whitespace condition replaced by `false`: RED, 4 tests (2 skip, 2 reason), all four are the `edge_ws_*` data sets. Attributable.
  - B: `preg_quote($sentPreviousSku, '/')` replaced by the raw value: RED, 2 tests. `P/12 (A+B).$` fails with an ErrorException (broken delimiter). `A+B.(1)$` fails with an ordinary assertion failure (the update count is not 2, so the guard skipped the resend). The `+ ( ) $` half is therefore killed at assertion level, as claimed.
- wms2 contract (read-only, /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-2624): `SkuBatchCreateUpdateService:169` compares `oldCode.equals(previousSku)` exactly, and `SkuRestController.normalize` trims `previous_sku` with `String.trim()`.

## Stage 1 - each fix
| Finding | Verdict |
|---|---|
| M1 api-docs 620-line regeneration | Fixed (see Evidence). The fix-log row 43 carries an explicit CORRECTION of the earlier false claim. |
| L1 preg_quote / suffix untested | Fixed. Metachar test, `expected_other` skip, and reason test are all killed by their mutants. The earlier ErrorException-only kill is now an assertion-level kill for the no-slash case. |
| L2 delete wording | Fixed in the docblock: "no create or update request ... (delete sends the id and never a previous_sku, by design)". Matches `deleteSku`. |
| L3 edge-whitespace D | Fixed as skip-with-reason plus a docblock "Known limit". |
| L4 no-id trailing-space AC-8c row | Restored: `'no id: trailing-space-only change abc_ -> abc sends none' => ['abc ', 'abc', false, 'none']`. Passes. |
| L5 renames | Done. |
| L7 mapped client move | Added, asserts `facility_item_id === X`, `previous_sku === newSku`, `!== oldSku`. |

## The new early return for edge-whitespace D
Correct and cannot block a legitimate heal.
- The 108 resend only succeeds when wms2 finds `row.itemNr.equals(trim(previous_sku))`. We send `previous_sku = D`, and wms2 trims it. If D has edge whitespace (`D != trim(D)`), the row's stored code differs from the trimmed value, so the CAS always answers 108 again. No heal is possible, so skipping loses nothing.
- If D has no edge whitespace, `trim(D) === D` and the guard is a no-op. So there is no case where a healable row is blocked.
- Placement is right: after the parse and the item_id check, before the holder query and the reload. It returns `null` like the other skips, with a distinct log reason (`resync-skipped`, `wms code has edge whitespace`).
- The decoy is correctly absent from the `edge_ws_*` cases, so only this check can stop the resend (mutant A confirms).

## Test renames - coverage
- `it_sends_no_previous_sku_on_client_move` becomes `..._on_an_unmapped_client_move` and shares `assertClientMovePayload` with the new mapped variant. The unmapped branch keeps the original assertion and message text (`assertArrayNotHasKey`, mutant #15 note). No coverage lost, one case gained.
- `it_skips_resend_when_target_code_...` becomes `it_skips_resend_on_a_bad_map_or_unparseable_108`, and the log twin becomes `it_logs_resync_skipped_bad_map`. Same provider, bodies unchanged, three data sets added. No coverage lost.

## Issues

### [LOW] L1 - PHP `trim()` and Java `String.trim()` disagree on the control-character set
File: app/Services/WmsApiService.php:1755 (`$wmsItemNr !== trim($wmsItemNr)`)
Confidence: MEDIUM
PHP `trim` strips ` \t\n\r\0\x0B`. Java `String.trim()` strips every char <= U+0020 (also \x01-\x08, \x0C, \x0E-\x1F). A D ending in e.g. \x0C or \x01 passes the PHP guard, wms2 trims it away, the CAS fails, and the result is one more 108, logged as `resync-resend failed`. It fails safe (no corruption, one wasted call, no loop). The round-2 prd probe found 0 control characters in itemdata, so this is theoretical today.
Fix (optional): trim with an explicit mask of `" \x00..\x20"`, or extend the docblock "Known limit" to say "whitespace or control characters".

### [LOW] L2 - The live plan still cites the old test name
File: /Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-2624-sku-rename-in-place-oms-wms-sync.md:415 (AC-8e: `ProductControllerTest::it_sends_no_previous_sku_on_client_move`). Also :409 AC-7h, which does not name the new tests or the new cases.
Confidence: HIGH
A `--filter` on the AC-8e name now matches zero tests, and PHPUnit reports no tests rather than a failure. `gate-oms.md:21,22,29` and the plan snapshots also cite the old names. The fix log says the snapshots were left as they were deliberately, which is fine for snapshots. The live plan table and `gate-oms.md` are not snapshots.
Fix: update the AC-8e cell to the two new names, and add the `expected_other` and `edge_ws_*` cases to AC-7h.

### [LOW] L3 - Reason test checks the value set, not the key
File: tests/Feature/Services/WmsApiServiceTest.php, `it_logs_the_distinct_skip_reason`
Confidence: LOW
`assertContains($reason, $this->sbdevContextValues($context))` passes if the string appears under any context key. The mutants show it is attributable today. A change that logged the reason under a different key would still pass.
Fix (optional): assert `$context['reason'] === $reason`.

## Positive observations
- Each new bad-map case omits the decoy, so each can only be stopped by its own check.
- The kill note in the test's failure message names the mutant, which makes a future red self-explanatory.
- Distinct log reasons (`unparseable description`, `item_id mismatch`, `wms code has edge whitespace`) allow triage from logs.
- The fix log corrects its earlier false claim in place rather than silently overwriting it.

## Recommendation
APPROVE. Fix L2 in the same pass; L1 and L3 are optional.

head: 176d38c0
