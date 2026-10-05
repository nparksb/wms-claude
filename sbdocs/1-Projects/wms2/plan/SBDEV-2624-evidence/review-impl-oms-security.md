# SBDEV-2624 Phase 3b — oms-laravel-api security review

head: 361ca2ed292fb0581484bb2700ec6cd8f9d556eb
Scope: `git diff origin/develop...HEAD -- app/` in /Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624 (WmsApiService, WmsFacilitySyncService, ProductWmsItem, LegacyWmsController, LegacyInventoryAdjustService, LegacyProductUpdateService, ProductController, LegacyV2ProductController, backfill command/job)
Risk level: MEDIUM. Nothing is remotely exploitable by an outsider through this diff. The risks are data integrity: a WMS item can be renamed by id when the per-facility map is wrong (pre-mortem S1).

Summary: Critical 0 · High 0 · Medium 2 · Low 3 · Info 6

## M1 — The bad-map guard ignores inactive products, so the 108 resend can rename a deactivated product's WMS item
- Severity: MEDIUM. Category: A04 Insecure Design / data integrity.
- Location: app/Services/WmsApiService.php, resendReloadedUpdate
  ```php
  $heldByAnother = Product::active()
      ->where('client_id', $product->client_id)
      ->where('product_sku', $wmsItemNr)
      ->where('product_id', '!=', $product->product_id)
      ->exists();
  ```
- Issue: SKU uniqueness in the OMS covers every product of the client, active or not (the LegacyV2ProductController conflict check has no is_active filter). A deactivated product keeps its SKU, and its WMS item can still exist and hold stock: deleteSkuFromProduct can be refused by the WMS delete CAS and only logs `delete-not-acknowledged`. If X's code D belongs to an inactive product P2, the guard passes. The resend then goes out with `facility_item_id=X` and no `previous_sku`, which bypasses the WMS CAS, and the WMS renames P2's item X to P1's SKU. Its stockrecords are rewritten with it.
- Exploit or trigger: there is no outside attacker. It needs a bad map row (S1) plus D held by an inactive product. One way to get there: P2 is deactivated (delete not acknowledged), and a later backfill or recordSeen then binds X to P1.
- Fix: drop `active()` so any other product of the client that holds D blocks the resend. Healing a product's own old code is still allowed, because no other product holds it.
  ```php
  $heldByAnother = Product::query()            // not ->active()
      ->where('client_id', $product->client_id)
      ->where('product_sku', $wmsItemNr)
      ->where('product_id', '!=', $product->product_id)
      ->exists();
  ```
  Add a test: an inactive P2 holds D, and the test asserts no resend plus a `resync-skipped-bad-map` log line.

## M2 — Every plain edit is an unguarded rename-by-id when the map is wrong (design-accepted S1, widest path)
- Severity: MEDIUM. Category: A04 / A01 (within one client).
- Location: WmsApiService::updateSkuFromProduct
  ```php
  if (isset($facilityItemIds[$facility])) { $facilityData['facility_item_id'] = $facilityItemIds[$facility]; }
  if ($previousSku !== null) { $facilityData['previous_sku'] = $previousSku; }
  ```
  `$previousSku` is set to null whenever the SKU did not change. ProductController.php:835 calls this on every product save.
- Issue: a price or name edit sends `facility_item_id` with no `previous_sku`. Plan §3.3 step 3 says the WMS then renames X to the current SKU with no CAS (`SKU_RENAME_BY_ID_RECOVERY`). The M1 guard runs only after a 108. This path never produces a 108, so the guard never runs. The only defences are the ambiguity guard (two map rows pointing at X) and the WMS collision check. A wrong map row with a single holder therefore lets any ordinary edit rename another same-client product's item.
- Exploit or trigger: an OMS user of the client edits any field on P1 while P1's map row wrongly points at P2's item X.
- Fix (recommended): always send the expected code, so drift produces a 108 and goes through the guard instead of a silent rename. Send `previous_sku = $sku` on unchanged edits, or add an `expected_item_nr` field. Two things to confirm first: that the WMS CAS treats `{previous_sku, sku} = {sku}` correctly, and that only the guarded resend drops it.
  ```php
  $facilityData['previous_sku'] = $previousSku ?? $sku; // the WMS CAS fires on drift and the OMS guard decides
  ```
  If this stays as designed, log it as accepted risk on the ticket.

## L1 — The 108 parse is loose: D can be truncated, and the item_id is never compared with the id that was sent
- Location: resendReloadedUpdate: `preg_match('/item_id=(\d+) is (.+?), expected /', $description, $m)`
- Issue: SKUs are user-supplied strings. If D contains `, expected `, the lazy `(.+?)` stops at the first occurrence. The guard then looks up a truncated D, finds no holder, and the resend goes ahead (fails open). `$m[1]` is also never compared with `$facilityItemId`. There is no ReDoS risk: the pattern is lazy with literal anchors.
- Fix: anchor on the known suffix and check the id.
  ```php
  $re = '/^sku rename precondition failed: item_id=(\d+) is (.+), expected '.preg_quote((string) $sentPreviousSku, '/').'$/s';
  if (! preg_match($re, $description, $m) || (int) $m[1] !== $facilityItemId) { /* skip, log */ return null; }
  ```

## L2 — The 109 resend drops previous_sku, so the CAS is skipped for a row that just changed under a lock
- Location: resendReloadedUpdate. A 109 skips the guard, and the resend is built with no `previous_sku`.
- Issue: a 109 means another writer held X's lock. Between that and the resend, the winner may have renamed X to a code D that is foreign to this product. The resend has no `previous_sku`, so the WMS renames X back with no CAS. The original request would have been rejected as a 108.
- Fix: on a 109, keep the original `previous_sku` on the resend. If the concurrent winner was our own edit, the row already equals sku and nothing is renamed. If it was a foreign rename, the CAS returns a 108, which is logged and not resent again.
  ```php
  if ($isConcurrent && $sentPreviousSku !== null) { $resendData['previous_sku'] = $sentPreviousSku; }
  ```

## L3 (pre-existing, outside this diff) — The inbound WMS legacy endpoints have no app-level authentication
- Location: bootstrap/app.php:26 `Route::middleware('api')->group(base_path('routes/legacy-services.php'))`. routes/legacy-services.php:69 `stockUpdate` has no auth middleware. The tenant comes from `getTenantFromRequest`, and `client_code` comes from the caller. The same applies to routes/legacy-inventory.php `stockUpdate`, which reaches LegacyInventoryAdjustService.
- Effect on this diff: R1 removes `Product::where('wms_item_id', $itemId)->first()`, which was an unscoped, cross-client lookup by a guessable integer. That is a real improvement. But the caller still names the client, so client scoping does not stop an unauthenticated caller. The real control is the network layer, which I could not verify from code.
- Fix: propose a ticket (T3 because it touches authz) for a shared-secret or mTLS middleware on `services/call/*`, unless ingress already restricts it. Not for this ticket.

## Info (checked, no finding)
1. Cross-client and cross-tenant. The three R1 readers now all resolve by `client_id + product_sku` (LegacyWmsController stockUpdate, LegacyInventoryAdjustService applyInventoryQuantities, which now requires a client, and LegacyProductUpdateService findProduct). `facilityItemIds` reads only this product's map rows, and the holder count is per facility. `codeDrift` inverts ids per WMS client id, so drift is never claimed across clients. ProductController Q2 sends `previous_sku` only when `previous_identity.client_id === product.client_id`. After a client move the stale `facility_item_id` is still sent, so cross-client safety then depends on the WMS `findByIdAndClientId` (§3.2 step 1). Confirm that in the wms2 lane. LegacyV2ProductController cannot change client_id, so C2 is safe.
2. Injection. All new queries are parameterised Eloquent builders (`where`, `whereIn`, `pluck`, `upsert`), with no raw SQL. `json_decode` is used with assoc=true and default depth, and checked with is_array/is_string. Both regexes are linear.
3. Logs. The new lines carry facility, product_id, SKU, item ids and HTTP status, with no PII, secrets or request body. They use Monolog structured context, so CR/LF from a WMS-supplied D is JSON-escaped rather than written as a new line. `wms_item_nr` comes from the WMS and is logged as context only.
4. Resend loop. It is bounded. The resend calls `updateSku` directly, and its result is never checked for `reason === 'resync'` again. All callers are synchronous controllers with no queue retries. The worst case is 2 WMS calls per facility per save, each with makeWmsRequest's own transport retries, plus one extra 5 s lock wait on a 109 (plan §3.3 states this cost).
5. Request nonce. `Str::uuid()` is a ramsey v4 UUID from `random_bytes`, 122 random bits. One nonce is used per logical call, and it lives in the body before `makeWmsRequest`, so transport retries replay it on purpose. Sharing it across facilities is safe because `facility_code` changes the body hash. It differentiates replays and does not authenticate, which is fine.
6. Secrets and dependencies. The added lines contain no credentials, and composer.json/lock are unchanged. `composer audit` was not run because composer is not on PATH.

## Checklist
- [x] No hardcoded secrets in the diff
- [x] Inputs validated (the description is decoded before parsing; the SKU is trimmed)
- [x] Injection prevention verified
- [~] Authorization: client scoping is correct in the diff; the inbound endpoints have no app auth (L3, pre-existing)
- [~] Dependencies: unchanged; audit not run (no composer)
