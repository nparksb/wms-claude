# SBDEV-2624 — round-2 review of the OMS review-fix commits

head: a1801d2c (range 361ca2ed..a1801d2c = ac4a041b round-1 + D-M2, a1801d2c D-M3)
Worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624 (git status clean before and after)
wms2 read (not edited): /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-2624, HEAD 086cb309 plus uncommitted SkuRestController / SkuBatchCreateUpdateService edits
Reviewer lane: code-reviewer, separate from the authoring lane. No file edited. No checkout, restore or stash.

## Code Review Summary
**Files reviewed:** 10 (6 app, 3 test, api-docs.json). **Total issues:** 8 (Critical 0 · High 0 · Medium 1 · Low 7).
**Recommendation: COMMENT.** The behaviour fixes are correct and complete. Nothing blocks at High. M1 is a scope and claim defect: the commit is wrong, the code is not. Fix it before the PR, and fix the Lows in the same pass.

## Evidence
- Tests run on the throwaway recipe. Before running, the probe showed testing, landlord and mysql → `oms-test-mysql/om1_owltest|om1_landlord_owltest`, mongodb → `oms-test-mongo`, and 229 tables. The processlist was idle, so no peer was running.
  - `WmsApiServiceTest`: **OK 111 tests, 323 assertions**.
  - `--filter backfill_logs_the_first_50|product_patch_never_sends_a_rename|it_sends_no_previous_sku_on_client_move`: **OK 4/4**.
  - I did not re-run the full suite.
- Prd read-only checks of `itemdata`:
  - WineCo (`wsl-wineco-prd`): 10770 rows. **212** `item_nr` contain a regex metacharacter (`/ . ( ) + * ? [ ] $ ^ | \`), 1 has edge whitespace, 0 have control characters.
  - Hydra: 2814 rows. 2 contain a metacharacter, 1 has edge whitespace, 0 have control characters.
- wms2 108 text: `WmsConstants:1807` `"sku rename precondition failed: %1s, %2s"`, with args `"item_id=" + itemId + " is " + oldCode` and `"expected " + previousSku` (`SkuBatchCreateUpdateService.rename`). `%1s`/`%2s` are width specifiers, not positional. Both args are longer than 2 characters, so no padding occurs, and the text is exactly `…: item_id=X is D, expected P`. `SkuRestController.normalize` trims `previous_sku` and turns blank into null. The OMS sends trimmed values (`trim($previousSku)`, `$skuData['sku'] = trim(product_sku)`), so the echoed `P` equals `$sentPreviousSku`.

## Stage 1 — each claimed fix

| Finding | Verdict |
|---|---|
| Sec M2 / D-M2 (`previous_sku = $previousSku ?? $sku` inside the id branch) | Correct and complete. Every send that carries an id sets it, because the `previous_sku` assignment is inside `if (isset($facilityItemIds[$facility]))`. |
| Sec M1 (`Product::query()`) | Correct. Product has no global scope or SoftDeletes, so this covers every product of the client. |
| Sec L1 (anchored regex + id check) | Correct. Analysis below. |
| Sec L2 (109 keeps original previous_sku) | Correct. wms2 checks `row.itemNr == code` before the CAS. If our own concurrent edit won, the result is a plain update. If a foreign rename won, the result is a 108, which is logged and not resent. |
| D-M3 (108 resend `previous_sku = D`) | Correct. wms2 finds the row by id, `oldCode = D = previousSku`, so the CAS passes only while X is still at D. The collision check still runs. |
| Code M1 (resend success test, marker prefix) | Present. It asserts the healed id, `results[F]` and the absence of `rename-not-acknowledged`. |
| Code M2 (decoy only where the guard must act; plain-text undecodable body) | Correct and stronger. A raw fallback would now parse the body and resend. |
| Code L3 (reload re-checks) | Correct. `isVirtualKit` uses `loadMissing` on the fresh model, so it reads the DB state. |
| Code L4 (422 only) | Correct. `WmsException::fromHttpStatus` keeps the real status, and the delete CAS answers 400. |
| Code L5 (drift sample) | Correct. The sample is capped at 50 rows of `{product_id, sku, wms_item_nr, wms_item_id}`, about 50×(~2 SKUs) bytes, at most ~25 KB with 255-char SKUs. It holds no PII. It lives in the service, so the job and the command both get it. |
| Code L1 (stale docs) | The wording fixes are fine. **The OpenAPI artifact claim is false: see M1.** |
| Code L6–L9, L2 | Doc only. Accurate. |
| C3 conformance test | Present. Both arms are pinned. |

## Issues

### [MEDIUM] M1 — `api-docs.json` carries a 620-line unrelated regeneration, which contradicts the fix log and the commit message
File: `storage/api-docs/api-docs.json` (commit ac4a041b; `git diff --stat 361ca2ed..a1801d2c` → **620 insertions, 28 deletions**)
Confidence: HIGH
The fix log says: *"The artifact was therefore reset with `git show HEAD:… >` and only the one generator-produced line was applied."* The commit says only *"incl. the OpenAPI description (L1)"*. What actually landed includes the following, and none of it is SBDEV-2624:
```
+        "/api/batches/next-label": {
+        "/api/print-runs": {
+        "/api/print-runs/{id}": {   … /cancel, /retry
-                    "from_email", "from_name", "smtp_server"      (CreateClientEmailConfigRequest.required)
+                    "email_config"
```
`origin/develop` has not touched the file since merge-base `dad34d7e`, so all of this content is introduced by this PR.
- Scenario: the PR diff hides 620 lines of unrelated contract changes, including changed `required` lists, under a SKU-rename ticket. Any other branch that regenerates Swagger gets a conflict. A reviewer who trusts the fix log never looks at it.
- Fix: rebuild the file as `git show 361ca2ed:storage/api-docs/api-docs.json` with only the one `item_id` description line replaced, which is what the log claims was done. Amend ac4a041b or add a fixup. Correct the fix-log sentence. If the drift is real (the source has these endpoints), propose a separate regeneration ticket.

### [LOW] L1 — `preg_quote($sentPreviousSku)` and the suffix binding are untested, yet 212 WineCo prd SKUs contain metacharacters
File: `app/Services/WmsApiService.php` `resendReloadedUpdate`
```php
$pattern = '/^'.preg_quote(self::WMS_RESYNC_MARKERS[0], '/').': item_id=(\d+) is (.+), expected '
    .preg_quote($sentPreviousSku, '/').'$/s';
```
Confidence: HIGH (by inspection; no mutant was run because I could not edit the worktree)
- The code is correct. The `/` delimiter is passed, `/s` without `/x` keeps spaces literal, and greedy `(.+)` with an end anchor reads D up to the last `, expected <P>`, which is the right choice. A preg error returns `false`, the `=== 1` check fails, and the guard skips (fails closed). The backtracking is O(n·m) on an anchored pattern, and SKUs are short.
- Every 108 test uses `previous = 'PREV-<hex>'`, which contains no character that needs quoting. A mutant that drops `preg_quote` on `$sentPreviousSku` (or drops the `'/'` delimiter argument) therefore stays green.
- No test sends a description whose `expected` differs from the sent `previous_sku`. A mutant `expected (.+)$` also survives.
- On prd, unquoted `12/750ML` raises a delimiter error and `A+B` fails to match itself. Healing is then silently lost for 212 WineCo SKUs (only a `resync-skipped-bad-map … unparseable` warning is logged).
- Fix: add two badMap/AC-7f cases.
  - A rename whose previous SKU is `P/12 (A+B).$`. Expect one resend with `previous_sku = D`.
  - A description whose `expected OTHER` differs from the sent value. Expect no resend and reason `unparseable description`.

### [LOW] L2 — "no request that carries facility_item_id omits previous_sku" is false for delete
Files: `app/Services/WmsApiService.php` `resendReloadedUpdate` docblock (*"no request that carries facility_item_id omits previous_sku"*), and plan §10 D-M3 (*"Every request that carries facility_item_id now carries previous_sku"*)
Confidence: HIGH
`deleteSku` sends `facility_item_id` and never sends `previous_sku`. This is correct under the wms2 contract: delete is not a rename, and the uncommitted wms2 delete CAS compares `item_nr` against `sku` for whichever lookup found the row and answers 108/400. So no request breaks. The universal sentence is still wrong, and the next reader may "fix" delete to match it.
Fix: scope both sentences to "every create/update request that carries facility_item_id".

### [LOW] L3 — The D-M3 resend cannot heal a row whose item_nr has edge whitespace
File: `app/Services/WmsApiService.php`, `$resendData['previous_sku'] = $isPrecondition ? $wmsItemNr : $sentPreviousSku;`
Confidence: MEDIUM
- Scenario: the WMS row X holds `"ABC "`. The plain edit gets 108 with D = `"ABC "`, and the resend sends `previous_sku: "ABC "`. wms2 `normalize` trims it to `"ABC"`, which is not equal to `"ABC "`, so the result is another 108, logged as `resync-resend failed`.
- Every later edit repeats this, so the row is permanently un-healable without manual work. Prd has 1 such row on WineCo and 1 on Hydra.
- It fails safe (no corruption).
- Fix: none needed in code. Note it in the `resendReloadedUpdate` docblock, or detect `D !== trim(D)` and log a distinct `reason` so an operator can find it.

### [LOW] L4 — AC-8c lost its no-id trailing-space case, which D-M2 did not sanction
File: `tests/Feature/Services/WmsApiServiceTest.php` `previousSkuCases`
Confidence: HIGH
The old case was `'trailing space only abc_ -> abc does not' => ['abc ', 'abc', false]`. D-M2 redefines AC-8c only for requests by id. The no-id rule for that row is unchanged ("none"), but the row was rewritten to `by id … sends the current code`, and no no-id twin was kept. A "no trim" mutant is still killed by the by-id case, so coverage did not drop. The gate row, however, no longer exists in its sanctioned form.
Fix: add `'no id: trailing-space-only change abc_ -> abc sends none' => ['abc ', 'abc', false, 'none']`.

### [LOW] L5 — Test name no longer matches what it covers
File: `tests/Feature/Services/WmsApiServiceTest.php` `it_skips_resend_when_target_code_belongs_to_another_active_product` and `it_logs_resync_skipped_bad_map_when_target_code_belongs_to_another_active_product`
Confidence: HIGH
They now cover inactive holders and the fail-closed cases (malformed, undecodable, other_id).
Fix: rename to `it_skips_resend_on_a_bad_map_or_unparseable_108` and `…_logs_resync_skipped_bad_map`.

### [LOW] L6 — D-M2 bullet 1 reads as unconditional, while the implementation and the fix log scope it to requests by id
File: plan §10 D-M2. Bullet 1 says *"`previous_sku = <current SKU>` on a plain edit"*. Bullet 4 (AC-8c) and D-M3 scope it to requests that carry `facility_item_id`.
Confidence: HIGH
The fix log's open reading follows bullet 4. Bullet 1, read alone, contradicts it.
Fix: append "when `facility_item_id` is sent" to bullet 1 (judgement below).

### [LOW] L7 — No test covers a client move that has a map row
File: `tests/Feature/Api/ProductControllerTest.php` `it_sends_no_previous_sku_on_client_move` (no `product_wms_item` row in the fixture)
Confidence: MEDIUM
Under D-M2, a mapped client move sends the old client's X together with `previous_sku = <new SKU>`. wms2 `findByIdAndClientId(X, newClient)` misses, and `previous_sku == sku` skips step 2, so the request creates or updates under the new client. That outcome is correct, but nothing pins it. The test name also now claims something that is false when a map row exists.
Fix: add a mapped variant. Assert `previous_sku === newSku` (never the old SKU) and `facility_item_id === X`.

## Stage 2 checks requested

- **Anchored 108 regex / preg_quote:** correct (L1 covers the missing test). `(int)$m[1] !== $facilityItemId` correctly fails closed on a legitimate wms2 case: the id misses, the previous_sku cache hit is stale, and the 108 names another row Z.
- **Fresh-product re-check:** correct. All four arms are logged with `reason`. "client changed" compares against the request copy, which is right because the id X belongs to the client the first request ran under.
- **422-only:** correct. The test pins a 400 that carries the 108 text.
- **Backfill log size:** bounded at 50 rows, a few KB, no PII. The job's own `SBDEV-2624 backfill code_drift` line still logs only the count, which is redundant but harmless.
- **D-M3 resend previous_sku = D:** correct against wms2, including D == fresh SKU, which becomes a plain update. L3 is the only residual case.

## Stage 3 — gate/AC test edits
- AC-8c rewrite: sanctioned by D-M2 for the by-id rows. The no-id trailing-space row was dropped without sanction (L4).
- AC-7f: sanctioned by D-M2 (109) and D-M3 (108). The positive control on the first update is an addition, not a weakening.
- AC-7h: strengthened (decoy removed where only fail-closed can act; plain-text undecodable body).
- AC-8e untouched: still holds, but only for the unmapped fixture (L7).

## Stage 4 — wms2 contract
- No create/update request with `facility_item_id` omits `previous_sku`. The first send is in the id branch, and both resends set it explicitly. There are 3 callers of `updateSkuFromProduct` and no other `updateSku` caller with an id (`git grep facility_item_id|previous_sku -- app/` outside WmsApiService returns 0).
- Delete omits it, and that is correct (L2).
- One SKU per request, so the wms2 "one rename per request" rule (uncommitted) cannot fire.
- The OMS never sends control characters in `previous_sku` from its own data, because it trims SKUs. If a D from the WMS ever held one, wms2 would reject the resend and the OMS would log it. Prd has 0 such rows.

## Judgement on the open reading
*"An unchanged edit without facility_item_id sends no previous_sku"* is **consistent** with D-M2 bullet 4 and D-M3, and with the wms2 lookup order.
- Without an id, `resolveForUpdate` skips the previous_sku step whenever `previous_sku == sku` (`!getPreviousSku().equals(getSku())`). So sending `previous_sku = sku` would be byte-for-byte the same lookup: `via = sku`.
- A sku hit at another code is discarded as a stale lookup (D-M3), never renamed.
- So without an id, a rename cannot happen either way, and sending the current SKU would add nothing.
- Keep the reading, and fix the wording of D-M2 bullet 1 (L6).

## Positive observations
- The 109/108 split is cleanly expressed through `$isPrecondition`, and the resend stays structurally bounded (it calls `updateSku` directly).
- The skip reasons are distinct (`unparseable description`, `item_id mismatch`, the four reload reasons), so operators can triage from the logs.
- Removing the decoy for the fail-closed cases makes each case able to fail only for its own reason.
- The collation-loose guard is documented as erring safe. It was not loosened.
