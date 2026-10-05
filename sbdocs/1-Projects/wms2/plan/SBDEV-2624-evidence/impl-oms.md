# SBDEV-2624 P2 — oms-laravel-api implementation report

- Worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624`, branch `feature/SBDEV-2624-facility-item-id`. Not pushed or rebased.
- The main checkout `v2/oms-laravel-api` was not touched.
- Environment: the throwaway Docker recipe (`oms-recipe/`).
  - Targeted runs and mutants used `oms-test-mysql-gate`.
  - Suite runs used one fresh `mysql:8.0` per shard (`oms-test-mysql-p2-*`), each restored from the P0 snapshot `fresh.sql` (229 tenant tables, checked before every run). They were removed afterwards.
  - Mongo: `oms-test-mongo`.
  - Before every run, a probe printed each connection's host and database (`testing`, `tenant`, `landlord`, `testing_reporting`, `tenant_reporting`, `mysql`, `mongodb`). Every one was a throwaway container. `.env.testing`'s 127.0.0.1 hosts are overridden by `-e`.

## Commits

(SHAs updated in review round 1, code L2: the branch was rewritten from `e2a389bc`/`d2cb8569` to `32b4587b`/`361ca2ed`; `git range-diff` shows the implementation identical and the gate differing only by the dropped `.omc/state/*` files.)

| SHA | Subject |
|---|---|
| `361ca2ed` | SBDEV-2624: rename a SKU in place at the WMS (OMS side, P2) — 11 files, on top of gate `32b4587b` |

## Per-story mapping (§0 rows → code)

| Row | Change | File |
|---|---|---|
| O1 | `updateSkuFromProduct(Product, ?string $previousSku)`. One nonce per call. Per facility, it adds `facility_item_id` and `previous_sku` (trimmed, case-sensitive `!==`, empty → none). After success it calls `recordSeen` with `item_ids[<sku>]`. When a failed update carried `previous_sku`, it logs `SBDEV-2624 rename-not-acknowledged`. On a 108/109 it does one reloaded resend (`resendReloadedUpdate`) | `app/Services/WmsApiService.php` |
| O1 / §3.5 detect | The `updateSku` catch strips `HTTP nnn: ` and calls `json_decode`. It then checks `str_starts_with(description, WMS_RESYNC_MARKERS[i])` → `reason=resync` plus the decoded description (`resyncDescription`). Undecodable → null (fail closed) | same |
| O1 / bad-map guard | 108 only: `/item_id=(\d+) is (.+?), expected /` on the decoded description. It skips the resend when `Product::active()` of the same client holds D under another `product_id`, and also when the regex fails. Logs `SBDEV-2624 resync-skipped-bad-map`. The resend reloads with `Product::find`, sends no `previous_sku`, the same id and a new nonce, and logs `SBDEV-2624 resync-resend` (X, D for 108, target SKU). A failed resend is logged and never resent | same |
| O2 | `buildSkuDataFromProduct` no longer adds `item_id` | same |
| O3 / §3.6 | `buildSkuPayload($facility, $data, ?string $nonce = null)` adds `request_nonce` only when it is absent | same |
| O5 | `createSkuFromProduct`: one nonce per call. It reads the id by exact key (`recordSeenFromResponse`, no `reset()`) and no longer writes `product.wms_item_id` | same |
| O6 | `deleteSku(..., ?int $facilityItemId)` sends `facility_item_id` and `request_nonce`, never `item_id`. `deleteSkuFromProduct` passes the per-facility map id (same ambiguity guard) and logs `SBDEV-2624 delete-not-acknowledged` | same |
| O7 | `createSkuBatch` gets a nonce through the `buildSkuPayload` default | same |
| (8a/8f/8h) | `facilityItemIds()`: one `pluck('wms_item_id','facility_code')` per call. For each facility it keeps the id only when it is non-null and `count()===1` at that facility. Guarded by `ProductWmsItem::tableExists()` | same |
| C1 | Passes `previous_identity.product_sku` only if `previous_identity.client_id === (int) $product->client_id` | `app/Http/Controllers/Api/ProductController.php` |
| C2 (kept IN scope per Nam) | `$oldSku = (string) $product->product_sku` captured before the locked `productRepository->update`, then passed along | `app/Http/Controllers/Api/Legacy/LegacyV2ProductController.php` |
| C3 | Unchanged (tests only) | — |
| P1 | `recordSeen` splits rows: rows with an id upsert `[wms_item_id,last_seen_at]`; NULL rows upsert `[last_seen_at]` only | `app/Models/ProductWmsItem.php` |
| P2 (a) | `reconcileSkus` gains `$facilityCode`. Per chunk, `codeDrift()` uses the stored id plus an inverted id→itemNr map of the same WMS client. A drifted product is added to `code_drift`, observed with X (so `pruneStale` keeps it), and not added to the create list | `app/Services/WmsFacilitySyncService.php` |
| P2 (b) | `backfillFacilityItemMap` applies the same keep rule before its unconditional prune. It counts `id_missing` (itemdata_list rows with no id) and returns `code_drift` and `id_missing`. The command prints both. The job logs `SBDEV-2624 backfill code_drift` | same, `Console/Commands/BackfillFacilityWmsItemsCommand.php`, `Jobs/BackfillFacilityWmsItemsJob.php` |
| R1 | `backfillWmsItemIds` drops the global write and its docblock is updated. `LegacyWmsController`, `LegacyProductUpdateService::findProduct` and `LegacyInventoryAdjustService::applyInventoryQuantities` resolve by client + SKU and ignore inbound `item_id`. Every global backfill is deleted, and so is the dead `if ($clientCode === null) { // only reachable on the wms_item_id path` branch | the three Legacy files |

**Cross-repo literals used verbatim from the plan:**
- fields `facility_item_id`, `previous_sku`, `request_nonce`;
- response key `item_ids`;
- `WMS_RESYNC_MARKERS = ['sku rename precondition failed', 'sku concurrent modification']` (unchanged from the skeleton).

**P2 acceptance greps (§3.5):**
- `git grep -nE "Product::where\('wms_item_id'|table\('product'\)[^;]*wms_item_id|\$product->wms_item_id" -- app/` → **0**.
- `git grep -n wms_item_id -- app/Services/Legacy/ app/Http/Controllers/Api/Legacy/` → **0**.
- Positive control on `32b4587b`: 13 and 13, the plan's base counts.

## Tests

**The 3 replaced tests:**
- `it_includes_item_id_in_sku_data_when_product_has_wms_item_id`: **deleted**.
- `it_includes_item_id_in_delete_payload`: **deleted**.
- `it_captures_wms_item_id_from_create_response`: **rewritten**. The product now has `product_sku 'TEST-SKU'`, so the response key matches, and the test asserts `product_wms_item(p,F).wms_item_id === 12345`. No R1 test depended on the lookup.

**Gate tests:** not edited.

**§7.2 filter run** (`WmsApiServiceTest|ProductWmsItemTest|LegacyV2ProductWmsSyncTest|ProductControllerTest|FacilityWmsSyncTest|LegacyInventory|LegacyWmsControllerItemIdTest|LegacyProductUpdateServiceItemIdTest`):
- **255 tests, 255 pass.**
- Every one of the 43 gate cases (33 RF + 10 RG, data-provider cases counted individually) passes, plus the rewritten test.
- Whole touched files: WmsApiServiceTest 97/97, ProductWmsItemTest 5/5, LegacyV2ProductWmsSyncTest 1/1, ProductControllerTest 29/29, FacilityWmsSyncTest 14/14, LegacyInventoryAdjustmentAlertTest 13/13, LegacyInventoryStockUpdateReallocationTest 4/4, LegacyWmsControllerItemIdTest 1/1, LegacyProductUpdateServiceItemIdTest 1/1, LegacyProductUpdateServiceTest 17/17.

## Mutants (§7.1 OMS list + #20/#21/#22/#24/#25)

**Method:**
- Each mutated file was copied to `/tmp/sbdev2624-mut/`, edited (the anchor had to match exactly once), run, then restored from that copy, and its sha256 was checked.
- No git checkout, restore or stash was used.
- After the whole set: `git status` and the `git diff` hash are byte-identical to before, and `git grep MUTANT -- app` = 0.
- Run on the final code (`mutants-final`). Harness: scratchpad `mutants.py`.

| Mutant | Applied as | AC | Result | Run | Key red line |
|---|---|---|---|---|---|
| #1 | re-add item_id | 8b | **RED** | Tests: 4, Assertions: 8, Failures: 3. | `create: payload has key item_id [mutant #1: re-add item_id]` |
| #2 | drop the NULL omission | 8a (NULL) | **RED** | Tests: 2, Assertions: 5, Failures: 1. | `NULL-id facility sent facility_item_id [mutant #2: drop the NULL omission]` |
| #3 | send previous_sku unconditionally | 8c | **RED** | Tests: 3, Assertions: 7, Failures: 2. | `payload has previous_sku for an unchanged SKU [mutant #3: send unconditionally]` |
| #4a | constant nonce (update) | 8g | **RED** | Tests: 1, Assertions: 3, Failures: 1. | `two calls shared a request_nonce [mutant #4: constant nonce]` |
| #4b | nonce missing in batch (no buildSkuPayload default) | 8g batch | **RED** | Tests: 1, Assertions: 2, Failures: 1. | `payload lacks request_nonce (createSkuBatch) [mutant #4: missing in batch]` |
| #5 | drop the ambiguity guard | 8f, 8h | **RED** | Tests: 4, Assertions: 12, Failures: 2. | `ambiguous id sent as facility_item_id [mutant #5: drop the ambiguity guard]` |
| #6 | reset() id read | 7d | **RED** | Tests: 1, Assertions: 1, Failures: 1. | `expected 984182588 was 984182587 (OTHER's id is 984182587) [mutant #6: reset() id read]` |
| #7 | one recordSeen upsert | 7c | **RED** | Tests: 1, Assertions: 1, Failures: 1. | `expected 77 was NULL [mutant #7: one recordSeen upsert again]` |
| #8 | C2 passes the fresh copy | 8d | **RED** | Tests: 1, Assertions: 4, Failures: 1. | `payload lacks previous_sku [mutant #8: C2 passes the fresh copy]` |
| #9 | C1 uses wasChanged (EQUIVALENT expected) | 8e + companion | **GREEN** | OK (2 tests, 8 assertions) | `` |
| #10 | reconcile treats drift as missing | 15 | **RED** | Tests: 2, Assertions: 3, Failures: 2. | `row pruned: product_wms_item(P,F) must survive the full reconcile with its id [mutant #10: treat drift as missing]` |
| #11a | restore R1 lookup: LegacyInventoryAdjustService (base file) | 16 | **RED** | Tests: 1, Assertions: 2, Failures: 1.; Tests: 1, Assertions: 2, Failures: 1. | `decoy product inventory changed [mutant #11: restore the wms_item_id lookup]` |
| #11b | restore R1 lookup: LegacyWmsController (base file) | 16 | **RED** | Tests: 1, Assertions: 5, Failures: 1. | `decoy product queued for reallocation [mutant #11: restore the controller wms_item_id lookup]` |
| #11c | restore R1 lookup: LegacyProductUpdateService::findProduct (base file) | 16 | **RED** | Tests: 1, Assertions: 2, Failures: 1. | `decoy product inventory changed [mutant #11: restore the findProduct wms_item_id lookup]` |
| #12 | backfill prunes drift (keep rule removed) | 15b | **RED** | Tests: 1, Assertions: 1, Failures: 1. | `row pruned: backfillFacilityItemMap must keep the drifted row with its id [mutant #12: backfill prunes drift]` |
| #13 | drop recordSeen on update | 7b | **RED** | Tests: 1, Assertions: 2, Failures: 1. | `product_wms_item.wms_item_id expected 1395292070 was NULL [mutant #13: drop recordSeen on update]` |
| #14 | restore the global product.wms_item_id write on create | 7b | **RED** | Tests: 1, Assertions: 2, Failures: 1. | `product.wms_item_id expected null was 1113804206 [mutant #14: restore the global product.wms_item_id write]` |
| #15 | C1 compares the SKU only, ignoring the client | 8e | **RED** | Tests: 1, Assertions: 4, Failures: 1. | `a client move sent previous_sku: the old code belongs to the SOURCE client [mutant #15: C1 compares the SKU only, ignoring the client]` |
| #16 | drop the rename-not-acknowledged log | 7e | **RED** | Tests: 1, Assertions: 2, Failures: 1. | `Log::warning not called with rename-not-acknowledged [mutant #16: drop the log]` |
| #17a | resend the request copy's SKU | 7f | **RED** | Tests: 2, Assertions: 4, Failures: 2. | `resend sku expected the DB-reloaded S2624-6.65146227 [mutant #17: resend the request copy's sku]` |
| #17b | resend without an id | 7g | **RED** | Tests: 1, Assertions: 1, Failures: 1. | `expected exactly one update and no resend, got 2 (0 = positive control failed; 2 = mutant #17: resend without an id)` |
| #17c | resend unbounded (resend the resend once more on resync) | 7f | **RED** | Tests: 2, Assertions: 2, Failures: 2. | `resend count expected 1 was 2 [mutants: #20 drop the 109 marker -> 0; unbounded resend -> 2]` |
| #18 | delete passes the global id | 8h | **RED** | Tests: 3, Assertions: 10, Failures: 3. | `Failed asserting that 1036280383 is identical to 1036280384.` |
| #19 | case-insensitive SKU compare | 8c | **RED** | Tests: 3, Assertions: 6, Failures: 1. | `payload lacks previous_sku [mutant #19: case-insensitive compare]` |
| #20 | drop the 109 marker | 7f | **RED** | Tests: 1, Assertions: 1, Failures: 1. | `resend count expected 1 was 0 [mutants: #20 drop the 109 marker -> 0; unbounded resend -> 2]` |
| #21 | drop the bad-map guard | 7h | **RED** | Tests: 5, Assertions: 5, Failures: 3. | `[plain] expected one update and no resend, got 2 [mutants: #21 drop the bad-map guard; #25 regex on the raw body (quote case)]` |
| #22 | restore the backfillWmsItemIds global write | 15c | **RED** | Tests: 1, Assertions: 3, Failures: 1. | `expected null was 1913776161 (via writeSkus) [mutant #22: restore the backfillWmsItemIds global write]` |
| #24 | drop the id_missing increment | 15b | **RED** | Tests: 1, Assertions: 2, Failures: 1. | `expected 1 was 0 [mutant #24: drop the id_missing increment]` |
| #25 | guard regex on the raw body (prefix still checked on the decoded description) | 7h case 2 | **RED** | Tests: 4, Assertions: 4, Failures: 1. | `[quote] expected one update and no resend, got 2 [mutants: #21 drop the bad-map guard; #25 regex on the raw body (quote case)]` |

- **#9 is equivalent**, as §7.1 predicts: `wasChanged('client_id')` and the value comparison agree, since there is a single `$product->update` in the closure. The pair stays green; #15 shows the pair still separates the client-move and same-client cases.
- **#11** was applied three ways, by restoring each reader's base file.
- **#17** was split three ways: request-copy SKU (a), no-id resend (b), unbounded resend (c).
- **#4** was split two ways: constant (a), missing in the batch (b).
- **#23** belongs to wms2.

## Unit + Feature suites vs `baseline-oms.txt` (per test)

**Method:**
- The same sharding as the baseline: the same 6 `shardN.xml` file lists, each on its own fresh throwaway DB from the same snapshot, with `--log-junit`.
- The two new Feature files are not in any shard list, so they ran separately (s6, s7): both green.
- Unit: one sequential `--testsuite Unit` on a fresh DB.

| Suite | Tests | Errors | Failures | Skipped | Failing set vs baseline |
|---|---|---|---|---|---|
| Unit | 4852 (= 4848 + 4 gate) | 152 | 31 | 3 | **identical**: 183 = 183, 0 new, 0 gone |
| Feature (run 1) | 5785 | 419 | 188 | 22 | 607 vs 606: **3 new, 2 gone** |

**Attribution: all 3 run-1 new failures are flaky, not caused by this change.**
- `OrderFileInteractiveUploadTest::test_205_upload_pauses…` and `::test_completing_a_paused_upload…` (shard 0): pass in isolation on a fresh DB (7/7). They also pass in a full shard-0 rerun.
- `ShippingAccountControllerTest::test_scope_columns_survive_create_and_update` (shard 3): it fails with `422 "The selected carrier code is not valid."` from factory data.
  - It fails the same way **on pristine base** (`base-copy`) on a fresh DB, and 6/6 times on both trees.
  - It passes in a full shard-3 rerun.

**Rerun of shards 0 and 3:**
- The 3 above pass.
- 5 different tests fail instead: `OrderGroupControllerTest::test_index_endpoint_sorting_by_order_status_counts`, `ShippingAccountControllerTest::test_nested_store_ignores_a_client_id_in_the_body`, 2× `LegacyOmsCronJobControllerBackorderTest`, and `BackorderAlertServiceTest::test_send_inventory_alert_logs_notification`. The last 3 are Mongo notification assertions on the shared `oms-test-mongo`, run concurrently.
- All 5 passed in run 1.
- **Intersection of new failures across the two runs: 0.**
- None of these 8 test files references `WmsApiService` or `wms_item_id` (grep exit 1; positive control: `WmsApiServiceTest` matches).

**Gone (now pass):** `OrderFileUploadExpectedFormatTest::a_transfer_file_on_the_transfer_uploader…` and `ParcelControllerTest::test_like_for_like_selection_cannot_escape_client_scoping`. Both are the same order-dependent class, and neither touches SKU sync.

## Pint

- `./vendor/bin/pint --test`:
  - **Clean:** `ProductWmsItem.php` and `BackfillFacilityWmsItemsCommand.php`, both clean on base too.
  - **Already dirty on base:** the 8 other app files plus `WmsApiServiceTest.php`. The gate note named 4 dirty **test** files; the app files I changed were dirty too: `WmsApiService`, `WmsFacilitySyncService`, `ProductController`, `LegacyV2ProductController`, `LegacyWmsController`, `LegacyInventoryAdjustService`, `LegacyProductUpdateService`, `BackfillFacilityWmsItemsJob`.
- I did **not** reformat those files whole. That would bury the change under 1,600+ unrelated lines (WmsApiService alone: about 290 lines that Pint would rewrite).
- Check instead: for each file, I applied Pint to a copy and intersected the lines it rewrites with my added lines. I fixed every overlap (imports instead of FQNs in new code, `! $x`, docblock alignment, chain indentation).
- **Remaining overlap: 3 lines, all whole-block reflows of pre-existing blocks:**
  - the 2 `use` lines I added to WmsApiService's unsorted import block (Pint re-sorts the whole block);
  - 1 `@param` line in LegacyProductUpdateService's unaligned docblock.

## Deviations

1. **`createSkuBatch` nonce.** It comes from the `buildSkuPayload` default, as §3.6 says, so each item in one batch body gets its own fresh UUID rather than one shared UUID. Every call's body is still unique.
2. **`createSkuFromProduct` sends `request_nonce` only.** It sends no `facility_item_id`/`previous_sku`; the plan scopes those to update and delete.
3. **Extra `updateSku` failure keys.** The failure array gains `http_status` (for WmsException), plus `reason`/`description` on a marker match. `rename-not-acknowledged` logs `status` = the HTTP status.
4. **New log token.** `SBDEV-2624 resync-resend failed` is OMS-local, not a cross-repo literal; it is the plan's "a failure of the resend is logged".
5. **Extra bad-map log case.** `resync-skipped-bad-map` is also logged, with `reason`, when a 108 description does not parse.
6. **When `rename-not-acknowledged` fires.** It is logged after the final outcome, so also after a failed resend. That matches §3.3's "a final rename-not-acknowledged".
7. **`id_missing` definition.** It is the number of `itemdata_list` rows with no id. Those rows cannot be inverted for the drift check.
8. **Kept parameter.** `LegacyProductUpdateService::updateProduct` keeps its public `?int $wmsItemId` parameter, documented as ignored, because the gate test passes it. `LegacyWmsController` no longer passes it. The private `applyInventoryQuantities` and `findProduct` lost the parameter.
9. **New `reconcileSkus` parameter.** It gained a leading `string $facilityCode` (protected; one caller).
10. **Restored file.** The test runs regenerated `storage/api-docs/api-docs.json`. I restored it from `HEAD` with `git show` and did not commit it.

## Stopped on / open

- Nothing blocked. No gate assertion looked wrong, and the design worked as written.
- C2 is still unreachable over HTTP (gate finding 1). It is implemented and tested from the container, per Nam.
- Not done here: the P3 independent review lane (the floor's review item).
