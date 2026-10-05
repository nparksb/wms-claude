# SBDEV-2624 P0 TDD gate — oms-laravel-api lane

- Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624` (branch `feature/SBDEV-2624-facility-item-id`, base `dad34d7e`). **Nothing committed.**
- Environment: Docker recipe from memory `oms-laravel-api-has-no-runnable-test-env`, all throwaway (image `oms-php:8.4`, `mysql:8.0`, `mongo:7` on network `oms-test-net`). Before any run I checked `testing`, `landlord`, `testing_reporting`, `tenant` and `mysql`: every one resolved to a throwaway container (`oms-test-mysql*:3306/om1_*owltest*`), and `mongodb` resolved to `oms-test-mongo`.
- Tenant migrations were applied using the SBDEV-3524 drift-retry loop. The bare `tenant-baseline.sql` recipe does **not** create `product_wms_item`, and `ProductWmsItem::tableExists()` would then turn every map test into a silent no-op. Recipe: `oms-recipe/` next to this file.

## Gate results (base + skeleton, fresh run)

Lanes: 33 RF, all red on an assertion (0 PHP errors, 0 missing-table errors). 10 RG, all green.

| File | Test (case) | AC | Kind | Observed — key line |
|---|---|---|---|---|
| WmsApiServiceTest | it_records_item_ids_from_update_response_per_facility | 7b | RF | red — `product_wms_item.wms_item_id expected <X> was NULL [mutant #13]` |
| WmsApiServiceTest | it_does_not_write_global_wms_item_id_on_create | 7b | RF | red — `product.wms_item_id expected null was <X> [mutant #14]` |
| ProductWmsItemTest | record_seen_with_null_id_keeps_stored_id | 7c | RF | red — `expected 77 was NULL [mutant #7]` |
| WmsApiServiceTest | it_records_the_id_for_the_exact_sku_key | 7d | RF | red — `expected <9> was <5> (OTHER's id) [mutant #6]` |
| WmsApiServiceTest | it_logs_rename_not_acknowledged_on_failed_rename | 7e | RF | red — `Log::warning not called with rename-not-acknowledged [mutant #16]` |
| WmsApiServiceTest | it_resends_one_reloaded_plain_update_on_precondition_marker | 7f | RF | red — `resend count expected 1 was 0` |
| WmsApiServiceTest | it_resends_one_reloaded_plain_update_on_concurrent_marker | 7f | RF | red — `resend count expected 1 was 0` |
| WmsApiServiceTest | it_does_not_resend_without_facility_item_id | 7g | RG | green |
| WmsApiServiceTest | it_skips_resend_when_target_code_belongs_to_another_active_product ×4 (renamed in review round 2 to it_skips_resend_on_a_bad_map_or_unparseable_108) (plain D / D with `"` / malformed / undecodable) | 7h | RG | green ×4 |
| WmsApiServiceTest | it_logs_resync_skipped_bad_map_when_target_code_belongs_to_another_active_product | 7h | RF (split out) | red — `no SBDEV-2624 resync-skipped-bad-map log line` |
| WmsApiServiceTest | it_sends_facility_item_id_per_facility_and_omits_null (mapped) | 8a | RF | red — `payload lacks facility_item_id` |
| WmsApiServiceTest | it_sends_facility_item_id_per_facility_and_omits_null (NULL) | 8a | RG | green |
| WmsApiServiceTest | it_never_sends_global_item_id ×4 (create/update/delete/batch) | 8b | RF | red ×4 — `<op>: payload has key item_id [mutant #1]` |
| WmsApiServiceTest | it_sends_previous_sku_only_when_sku_changed (abc→ABC) | 8c | RF | red — `payload lacks previous_sku [mutant #19]` |
| WmsApiServiceTest | it_sends_previous_sku_only_when_sku_changed (abc␠→abc, unchanged) | 8c | RG | green ×2 |
| LegacyV2ProductWmsSyncTest (new) | it_passes_pre_update_sku_on_rename | 8d | RF | red — `payload lacks previous_sku [mutant #8]` |
| ProductControllerTest | it_sends_no_previous_sku_on_client_move (renamed in review round 2 to it_sends_no_previous_sku_on_an_unmapped_client_move) | 8e | RG | green |
| ProductControllerTest | it_sends_previous_sku_on_same_client_rename | 8e companion (added) | RF | red — `payload lacks previous_sku (C1 same-client rename)` |
| WmsApiServiceTest | it_omits_facility_item_id_when_ambiguous_at_facility | 8f | RG | green |
| WmsApiServiceTest | it_sends_a_fresh_request_nonce_per_sync_call | 8g | RF | red — `payload lacks request_nonce` |
| WmsApiServiceTest | it_sends_the_same_request_nonce_to_every_facility_in_one_sync_call | 8g | RF | red — `payload lacks request_nonce` |
| WmsApiServiceTest | it_keeps_the_request_nonce_across_transport_retries | 8g | RF | red — `payload lacks request_nonce` |
| WmsApiServiceTest | it_sends_a_request_nonce_in_create_sku_batch | 8g | RF | red — `payload lacks request_nonce (createSkuBatch) [mutant #4]` |
| WmsApiServiceTest | it_sends_a_request_nonce_in_delete_sku | 8g | RF | red — `payload lacks request_nonce (deleteSku)` |
| WmsApiServiceTest | it_sends_per_facility_item_id_on_delete ×3 (mapped / NULL / ambiguous) | 8h | RF | red ×3 — `payload has item_id (the global id) [mutant #18]` |
| FacilityWmsSyncTest | it_reports_code_drift_and_keeps_the_facility_row | 15 | RF | red — `row pruned … [mutant #10]` |
| FacilityWmsSyncTest | it_does_not_create_a_sku_for_a_code_drifted_product | 15 | RF (split out) | red — `createSkuBatch called 1 time(s) for the drifted SKU, expected never [mutant #10]` |
| FacilityWmsSyncTest | backfill_keeps_drifted_row_with_its_id | 15b | RF | red — `row pruned: backfillFacilityItemMap must keep the drifted row [mutant #12]` |
| FacilityWmsSyncTest | backfill_counts_id_less_rows_as_id_missing | 15b | RF | red — `undefined index id_missing` (assertArrayHasKey, not a PHP warning) |
| FacilityWmsSyncTest | it_does_not_write_global_wms_item_id_when_creating_missing_skus | 15c | RF | red — `expected null was <id> (via writeSkus) [mutant #22]`; positive control (map row = id, so `backfillWmsItemIds` was reached) passed first |
| LegacyInventoryAdjustmentAlertTest | it_ignores_inbound_item_id_and_resolves_by_client_sku | 16 | RF | red — `decoy product inventory changed [mutant #11]` |
| LegacyInventoryStockUpdateReallocationTest | it_ignores_inbound_item_id_and_resolves_by_client_sku_on_stock_count | 16 | RF | red — `decoy product inventory changed [mutant #11]` |
| LegacyWmsControllerItemIdTest (new) | it_ignores_inbound_item_id_and_resolves_by_client_sku | 16 | RF | red — `decoy product inventory changed [mutant #11 findProduct]` |
| LegacyProductUpdateServiceItemIdTest (new) | it_ignores_stale_global_wms_item_id | 16 | RF | red — `decoy product inventory changed [mutant #11]` |

The whole touched files were also run; **all 124 pre-existing tests in them are green**. That includes `it_includes_item_id_in_sku_data_when_product_has_wms_item_id`, `it_captures_wms_item_id_from_create_response` and `it_includes_item_id_in_delete_payload`, which the plan replaces.

## RG mutant results

Each mutant was applied to base + skeleton, run, and reverted by restoring the saved skeleton file. Afterwards `grep -c MUTANT` = 0 and `git diff -- app/` = the skeleton only.

| Mutant (§7.1) | Applied as | Rows | Result |
|---|---|---|---|
| #17 resend without an id / #21 drop the bad-map guard | resend every failed update once | 7g; 7h ×4 | **red ×5** — 7g: `got 2 (… mutant #17 …)`; 7h: count 2 ≠ 1 in all 4 cases |
| #5 drop the ambiguity guard | send the map id with no uniqueness check | 8f | **red** — `ambiguous id sent as facility_item_id` |
| #2 drop the NULL omission | send the map value even when it is NULL | 8a (NULL) | **red** — `NULL-id facility sent facility_item_id`; mapped case went green under the mutant, as expected |
| #3 send previous_sku unconditionally | send `previous_sku` whenever one is passed | 8c (2 not-sent cases) | **red ×2** — `payload has previous_sku for an unchanged SKU` |
| #15 C1 compares the SKU only | C1 passes `previous_identity.product_sku` with no client check, and the service sends it when the SKU differs | 8e | **red** — `a client move sent previous_sku …`; the companion same-client test went **green** under this mutant, so the pair separates the two behaviours |

Cannot be applied on base, so they are deferred to P2: #25 (guard regex on the raw body; needs the guard to exist) and #19 (case-insensitive compare; its row is RF and goes green only once P2 compares). Both are named in the assertion messages.

## Skeleton changes (compile-only, no behaviour)

- `app/Services/WmsApiService.php`: `updateSkuFromProduct(\App\Models\Product $product, ?string $previousSku = null)` (the parameter is unused), plus `public const WMS_RESYNC_MARKERS = ['sku rename precondition failed', 'sku concurrent modification'];` (not read yet). +9/−1.
- The plan lists nothing else for the OMS P0. The tests use literal marker strings, not the constant, so mutant #20 (drop a marker from the constant) stays observable in P2.

## Adjustments and findings

1. **C2 is unreachable over HTTP (finding).** On `dad34d7e`, `LegacyV2ProductController` has no route. `/services/v2/product` is a 410 `RetiredMerchantEndpointController`, and `/v1/services/v2/product` routes to `V1ServicesRestController::productPatch` (C3). The AC-8d test therefore calls `update()` from the container. Worth deciding in P2 whether C2 is still in scope or is dead code.
2. **AC-8e alone cannot catch a C1 that never passes `previous_sku`.** I added `ProductControllerTest::it_sends_previous_sku_on_same_client_rename` (RF). Without it, removing the C1 argument entirely leaves every row green.
3. **AC-7h was split.** The 4-case provider asserts only "no resend" (RG). "`resync-skipped-bad-map` is logged" is its own RF test, because the plan's single row would be red on base and so could not be RG. Case 3 became two provider cases: a malformed description, and an undecodable non-JSON body.
4. **AC-15 was split** into a row-kept/report test (a direct full non-dry `reconcile()`, the only reconcile that prunes) and a no-create test (an HTTP client-scoped execute run). One fixture cannot show both, because client-scoped runs never prune.
5. **Sub-cases are data-provider cases:** 8a ×2, 8b ×4, 8c ×3, 8h ×3, 7h ×4. AC-8g is 5 separate tests (two calls, facilities in one call, transport retries, batch, delete). The 7f markers are 2 tests sharing one helper.
6. **Logs are captured with `Event::listen(MessageLogged)`, not `Log::spy`.** A Mockery count failure is reported as an error, not an assertion failure. The listener gives plain `assertNotNull(…, '<message>')` reds.
7. **Pint:** the 3 new files and the 2 files that were Pint-clean on base (`ProductWmsItemTest`, `LegacyInventoryStockUpdateReallocationTest`) were formatted. Four modified files were already Pint-dirty on base (`WmsApiServiceTest`, `FacilityWmsSyncTest`, `ProductControllerTest`, `LegacyInventoryAdjustmentAlertTest`). They were left as is, so P2's `pint` acceptance will reformat unrelated code in them.
8. **Gate runs used a second throwaway MySQL** (`oms-test-mysql-gate`, restored from the same fresh snapshot) so they would not disturb the baseline running on `oms-test-mysql`.

## Unexpected passes

None. Every RF row was red, and the only greens are the 10 designated RG cases.

## Tests to delete in P2 (green now, will flip)

- `WmsApiServiceTest::it_includes_item_id_in_sku_data_when_product_has_wms_item_id` and `::it_includes_item_id_in_delete_payload`: replaced by `it_never_sends_global_item_id` / `it_sends_per_facility_item_id_on_delete`.
- `WmsApiServiceTest::it_captures_wms_item_id_from_create_response`: rewrite its `$product->fresh()->wms_item_id == 12345` as a `product_wms_item` assertion (plan K-#4). The plan says "update, never delete".
- Any R1 tests that depend on the `wms_item_id` lookup. None were found failing in the touched files.

## Baseline (`baseline-oms.txt`)

| Suite | Tests | Errors | Failures | Skipped |
|---|---|---|---|---|
| Unit (one sequential run) | 4848 | 152 | 31 | 3 |
| Feature (6 file-granular shards, each on its own fresh throwaway DB) | 5748 | 418 | 188 | 22 |

- The single sequential Feature run was CPU-bound in PHP and had slowed to about 13 min per 1% at 40% (ETA over 10 h), so I stopped it and sharded. **Compare per-test outcomes, not totals.**
- Memory baseline: `ba6d92da`, Unit only, Tests 4123 / Errors 499 / Failures 48. The commit differs (+725 Unit tests), and so does the schema recipe: the memory run loaded no tenant migrations. Most of its schema-drift errors are gone here. The remaining dominant class is the same: missing `om1_owltest_reporting.async_*` tables (295 of the Feature failing lines are `Base table or view not found`).
