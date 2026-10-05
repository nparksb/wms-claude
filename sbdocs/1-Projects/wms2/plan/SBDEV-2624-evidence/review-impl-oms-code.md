# SBDEV-2624 Phase 3b — code review, oms-laravel-api (P2)

head: 361ca2ed292fb0581484bb2700ec6cd8f9d556eb (base origin/develop fde9f044; merge-base dad34d7e — the 2 newer develop commits touch none of the 19 changed files)
Reviewer lane: oh-my-claudecode:code-reviewer, separate from the authoring pass. No worktree file was edited; mutants ran on a scratchpad rsync copy against oms-test-mysql / oms-test-mongo (all 7 connections probed first), and the copy was deleted afterwards. Worktree `git status` was clean and `git grep MUTANT -- app` returned nothing.

## Code Review Summary
**Files reviewed:** 19 (10 app, 9 test). **Total issues:** 11 (High 0 · Medium 2 · Low 9), plus 2 open questions.
**Recommendation: COMMENT.** Nothing blocks at High confidence. Fix M1 and M2 (test gaps proven by surviving mutants) before the PR, and fix the Lows in the same pass (standing rule).

## Stage 1 — plan conformance (§0, §3.5, §3.6)
Conformant. Every IN row (O1–O3, O5–O7, C1, C2, P1, P2a/b, R1) maps to code that does what §3.5/§3.6 describe:
- id read by exact key (no `reset()`); `recordSeen` NULL guard; nonce once per `*FromProduct` call, stable across `makeWmsRequest` retries, fresh on the resend; `buildSkuPayload` only adds the nonce when it is missing.
- Body is decoded before the marker check, with `str_starts_with`; bad-map guard on 108 only; one resend per facility, only when `facility_item_id` was sent; a failed resend is logged and not resent.
- Drift keep rule at both prune sites, plus `code_drift` and `id_missing` in the result.
- Every global `wms_item_id` read and write is gone. I re-ran both §3.5 acceptance greps on HEAD: **0 / 0**.
- Cross-repo literals checked against wms2 worktree `a63b3d89`:
  - `WmsConstants:1807/1810` text arms match `WMS_RESYNC_MARKERS`.
  - `getErrorMap()` = `{status, description}`.
  - `SkuBatchCreateUpdateService:141` CAS args = `"item_id=" + X + " is " + old`, `"expected " + prev`, which the guard regex parses.
  - `successWithItemIds` puts `item_ids` at the top level (`data` falls back to the whole body in `processWmsResponse`).
- Known gap carried over: C3 (`V1ServicesRestController:162`) has no test.

## Issues

### [MEDIUM] M1 — No test covers a resend that succeeds; 3 mutants survive
File: `app/Services/WmsApiService.php` (`updateSkuFromProduct` loop, `resendReloadedUpdate`, `resyncDescription`)
Confidence: HIGH (probed)
```php
$result = $this->resendReloadedUpdate($facility, $product, $facilityData['facility_item_id'], $result['description']) ?? $result;
...
if ($result['status'] !== 'success' && $previousSku !== null) {   // rename-not-acknowledged
...
$this->recordSeenFromResponse($facility, $fresh, $result, $resendData['sku']);   // inside resendReloadedUpdate
...
if (str_starts_with($description, $marker)) {
```
Every AC-7f/7h case answers the resend with another 422, so the success branch of the resend never runs. I applied three mutants together to a copy and ran the whole `WmsApiServiceTest`: **97/97 green, 285 assertions**.
1. `rename-not-acknowledged` keyed on the first attempt's status. It would now log after a resend that succeeded, which is a false alarm to operators.
2. `recordSeenFromResponse` removed from the resend's success branch. The healed id is then never recorded.
3. `str_starts_with` changed to `str_contains`. Any 422 whose description merely contains the marker would then trigger a resend.

I then applied mutant 2 alone: still 97/97 green.

**Fix:**
- Add a test: F answers the first update with a 108 (or 109) and the resend with `200 {"item_ids":{"<db sku>": Y}}`. Assert one resend, `product_wms_item(P,F).wms_item_id === Y`, `results[F].status === 'success'`, and **no** `rename-not-acknowledged` log line.
- Add a test with a 422 whose `description` has the marker after a prefix (e.g. `"client not found; sku rename precondition failed: …"`). Assert exactly one update.

### [MEDIUM] M2 — The bad-map "undecodable" case cannot detect a fallback to the raw body
File: `tests/Feature/Services/WmsApiServiceTest.php` (`arrangeBadMap` / `it_skips_resend_when_target_code_belongs_to_another_active_product`)
Confidence: HIGH (probed)
```php
// Another ACTIVE product of the same client holds D: X is its item, not ours.
$this->sbdevProduct(['product_sku' => $d], $product->client);
...
'undecodable' => Http::response($desc . ' <html>not json', 422),
```
The decoy holding D is seeded in **every** case, including `undecodable` and `malformed`. So when a mutant falls back to the raw body on a decode failure, it parses D from the raw text, and the guard then skips the resend because of the decoy. The test stays green for the wrong reason. Mutant tried: `: $body` instead of `: null` in `resyncDescription`. Result: 8/8 green (`--filter 'bad_map|another_active_product|resends_one|does_not_resend'`). Plan §3.5 wants "a body that fails to decode → no resync, fail closed", and that branch has no test of its own.

**Fix:** for `undecodable` (and `malformed`), seed no decoy, so the only thing that can stop the resend is the fail-closed branch. Keep the decoy for `plain` and `quote` only.

### [LOW] L1 — Stale docs still describe the global id
Confidence: HIGH
- `app/Http/Controllers/Api/Legacy/LegacyInventoryController.php:243`: `description: 'WMS itemdata id (preferred product resolver when present)'`. Since R1 the field is ignored. This is OpenAPI that callers read.
- `app/Services/WmsFacilitySyncService.php:948`: `then backfill product.wms_item_id from a fresh itemdata read.`
- `app/Services/WmsFacilitySyncService.php:964`: `// Backfill wms_item_id for this client's products from fresh itemdata.`

**Fix:** reword all three: ignored by the OMS (SBDEV-2624), and recorded per facility in `product_wms_item`. Regenerate L5-Swagger.

### [LOW] L2 — `impl-oms.md` cites SHAs that are not on the branch
File: `SBDEV-2624-evidence/impl-oms.md:15` (`d2cb8569`, gate `e2a389bc`)
Confidence: HIGH
The branch was rewritten to `32b4587b` and `361ca2ed`. `git range-diff` shows the implementation is identical (`=`). The gate commit differs only by dropping `.omc/state/*` session files: the old `e2a389bc` committed `hud-stdin-cache.json` and similar files. They are absent at HEAD, which is correct.
**Fix:** update the report and plan SHAs to `32b4587b` / `361ca2ed`.

### [LOW] L3 — The resend does not re-check whether the reloaded product is still syncable
File: `app/Services/WmsApiService.php` (`resendReloadedUpdate`)
Confidence: MEDIUM
```php
$fresh = Product::find($product->product_id);
if (! $fresh) { return null; }
$resendData = $this->buildSkuDataFromProduct($fresh);
```
Between the first attempt and the reload, the product can become a virtual kit, get an empty SKU, or move to another client. The normal entry path skips virtual kits (`isVirtualKit`). On a client move, the old facility id belongs to the source client: wms2 then misses by id and creates under the new client, which is benign but not what the resend is for.
**Fix:** return null when `$this->isVirtualKit($fresh)`, when `trim((string) $fresh->product_sku) === ''`, or when `(int) $fresh->client_id !== (int) $product->client_id`, and log the reason under `resync-skipped-bad-map` (or a sibling token).

### [LOW] L4 — `resyncDescription` ignores the HTTP status
File: `app/Services/WmsApiService.php` (`resyncDescription`)
Confidence: MEDIUM
Any `WmsException` whose decoded description starts with the marker qualifies. wms2 also emits code 108 with the text `sku rename precondition failed: … (delete)` as a **400** from `SkuRestController.delete:388`. Today that is not wired to a resend, because `deleteSku` does not call this method. But the contract is 422-only on create and update (plan §3.3).
**Fix:** require `$e->getHttpStatusCode() === 422`.

### [LOW] L5 — An operator cannot act on drift: only counts are logged
Files: `app/Jobs/BackfillFacilityWmsItemsJob.php` (`'code_drift' => \count($result['code_drift'])`), `app/Console/Commands/BackfillFacilityWmsItemsCommand.php`
Confidence: MEDIUM
The plan asks only for counts, and that is what the code does. But the job runs once per migrate and its result is discarded, so the product ids, codes and X are lost. The only way to heal drift is "the next product edit", which needs to know which products to edit.
**Fix:** log `array_slice($result['code_drift'], 0, 50)` in the job, and add a `--verbose` table in the command.

### [LOW] L6 — `id_missing` counts WMS rows, not the OMS map rows lost to the prune
File: `app/Services/WmsFacilitySyncService.php` (`if (! isset($row['id'])) { $idMissing++; }`)
Confidence: MEDIUM
When a drifted product's WMS row has no id, its map row is still pruned (`codeDrift` cannot invert it). The count says how many WMS rows have no id, not how many map rows were dropped because of that. This matches the plan's "counted rather than silently pruned" (deviation 7), but the signal is weaker than the wording suggests.
**Fix:** either document the meaning in the docblock and the command output, or count candidate map rows (stored id not found in `$itemNrById` and SKU absent) as a separate number.

### [LOW] L7 — A dead public parameter is kept on `updateProduct`
File: `app/Services/Legacy/LegacyProductUpdateService.php` (`@param int|null $wmsItemId Ignored (SBDEV-2624 R1)`)
Confidence: HIGH
Implementer deviation 8: it is kept only because the gate test passes it. A parameter that silently does nothing invites a future caller to rely on it.
**Fix:** mark it `@deprecated` with a removal note, or remove it and drop the argument from `LegacyProductUpdateServiceItemIdTest` (the decoy assertion still holds).

### [LOW] L8 — The bad-map guard is collation-loose while the WMS is case-sensitive
File: `app/Services/WmsApiService.php` (`->where('product_sku', $wmsItemNr)`)
Confidence: MEDIUM
`product.product_sku` is `utf8mb3_general_ci`, PAD SPACE (verified with `information_schema` on the test schema). A different product holding `abc` therefore blocks a resend whose D is `ABC`, even though the WMS treats them as distinct codes. The error is on the safe side (skip, never corrupt), so that product needs a manual re-edit.
**Fix:** none required. Note it in the docblock, or compare with `BINARY` if exact parity is wanted. Do not loosen it in the unsafe direction.

### [LOW] L9 — The two `recordSeen` upserts are not atomic
File: `app/Models/ProductWmsItem.php` (`$withId` / `$withoutId` loops)
Confidence: HIGH (impact negligible)
There are two statements with no transaction. A failure between them leaves part of the batch with an advanced `last_seen_at`. Both statements are idempotent and the next observation repeats them, so this is acceptable. The order (id rows first, NULL rows second) is correct even when the same product appears in both lists.
**Fix:** optional. Wrap both loops in `DB::connection('tenant')->transaction(...)`, or leave a comment saying why it is not needed.

## Open Questions (low confidence, not blocking)
- **[MEDIUM] Inactive holder of D passes the guard.**
  - File: `app/Services/WmsApiService.php`, `Product::active()->where('client_id', …)->where('product_sku', $wmsItemNr)`.
  - Confidence: LOW.
  - Scenario: a stale map row points at the WMS item X of a **deactivated** product Q of the same client. Q's WMS delete can fail or be refused (for example, stock still on hand), so X may still be live at the WMS. A 108 naming D = Q's SKU then passes the guard, and the resend renames Q's item to this product's SKU, which is the S1 shape. This conforms to the plan (§3.5 says `active()`).
  - Fix if confirmed: drop `active()`, or add `->orWhere(inactive but with a product_wms_item row at F)`.
- **[LOW] Facility-code case.**
  - `facilityItemIds` indexes `$map[$facility]`, a PHP array key, which is case-sensitive. `pluck('wms_item_id','facility_code')` returns whatever case the row was written with, while MySQL matches case-insensitively.
  - If any writer recorded `wsl` and `WmsUrlLut` says `WSL`, the id is silently omitted, which degrades to the pre-fix behaviour.
  - I found no writer that lowercases. Confirm with `SELECT DISTINCT BINARY facility_code FROM product_wms_item` against `wms_url_lut` on prd.

## Logging / secrets
The new log lines carry facility, product_id, SKU codes, WMS item ids and the HTTP status. There are no credentials, tokens or customer PII. The `service_log` payload logging is pre-existing and unchanged, apart from the added `request_nonce` and `facility_item_id`, which are not sensitive.

## Positive observations
- `recordSeenFromResponse` reads `item_ids[$sku]` by exact key with an `is_numeric` guard. The old `reset()` trap is gone, and mutant #6 is killed by a test that puts the other id first.
- Nonce threading is clean: one per call, the same across facilities and transport retries (a real `ConnectionException` test captures both bodies), and fresh on the resend.
- The resend is structurally bounded: `resendReloadedUpdate` calls `updateSku` directly, never the loop, so a second resend cannot happen.
- Fail-closed paths log a reason (`unparseable description`).
- C1 compares values (`previous_identity.client_id === (int) $product->client_id`), not `wasChanged()`, and both directions are pinned (client move and same-client rename).
- The R1 removal is complete, including the dead `$clientCode === null` branch. The decoy tests use a different-client decoy (adjust service) and a same-client decoy (`findProduct`).
- Drift detection is batched per chunk (one `pluck` per 500 products, an inverted map built once), so there is no N+1. `client` is eager-loaded on both product queries.
- The tests carry positive controls, and each assertion message names the mutant it kills.

## Evidence
- Diff `git diff origin/develop...HEAD` at `361ca2ed`. `git range-diff e2a389bc~1..d2cb8569 32b4587b~1..361ca2ed`: impl `=`, gate `!` (`.omc/state` files dropped).
- P2 greps on HEAD: `git grep -nE "Product::where\('wms_item_id'|table\('product'\)[^;]*wms_item_id|\$product->wms_item_id" -- app/` → 0; `git grep -n wms_item_id -- app/Services/Legacy/ app/Http/Controllers/Api/Legacy/` → 0.
- Mutant runs: `oms-php:8.4` on `oms-test-net` with the recipe ENVS, mounting a scratchpad copy. The connection probe printed testing/tenant/landlord/testing_reporting/tenant_reporting/mysql → `oms-test-mysql` and mongodb → `oms-test-mongo`.
  - Raw-fallback mutant: 8/8 OK.
  - Log-status + recordSeen + str_contains mutants: 97/97 OK.
  - recordSeen-on-resend mutant alone: 97/97 OK.
- PHP lint and LSP were not available on the host (`php` is not on PATH). The implementer's full-suite comparison (Unit identical to baseline, Feature with 0 new failures in the intersection of two runs) is the compile and behaviour evidence. I did not re-run it.
