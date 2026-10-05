# SBDEV-2624 r4: review of wms2 f35352d7 + OMS 2e48c0ed (fixes for r3 L-a, L-b, L-d, L-e, I-1)
head: wms2 f35352d7 (worktree .claude/worktrees/wms2-api/SBDEV-2624, clean)
head: OMS 2e48c0ed (worktree .claude/worktrees/oms-laravel-api/SBDEV-2624, clean)
Run: wms2 SkuRestControllerUnitTest 53/0/0 (nested classes; new edge tests are in $ReviewRound1) and SkuBatchCreateUpdateServiceUnitTest 38/0/0, JDK 21. OMS: `php` is not on PATH, so the PHP test was NOT run (read only). Mutants not run (no edits).

## Verdict: APPROVE. 0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW, 3 Info

## Check 1: OMS Java-parity trim is complete on outbound sku/previous_sku
- Every default `trim(` left in WmsApiService.php is not an outbound sku/previous_sku: `:1911` sku_name (the WMS trims sku_name before its control check, r3 I-4), `:2696/:2700` transfer_id, `:3619` client_code, `:3773` previousCode (client code), `:970-:1083` URLs.
- Masked `"\x00..\x20"` now: `:1652` previous_sku (update), `:1904` sku in buildSkuDataFromProduct, `:2022` and `:2030` delete sku, `:1793` empty-sku guard, `:1757` resend wmsItemNr.
- Single funnel: create, update, batch (`skuDataFromProduct`, `WmsFacilitySyncService:991`) and the resend (`:1822`, built from `$fresh` through buildSkuDataFromProduct, previous_sku = already-trimmed `$sentPreviousSku` or `$wmsItemNr`) all go through those lines. createSku/updateSku/deleteSku have no other caller in app/.
- Other `trim(product_sku)` (ProductController:721/1336, Legacy*) are inbound or lookups, not sent to the WMS.

## Check 2: can the new tests fail
- wms2 create/delete (`SkuRestControllerUnitTest:1106`, `:1173`): "B\n" is trimmed to "B" if `rejectControlCharacters` moves after `normalize()` (create `:98`, delete `:384`). Create would then not return 422; delete would reach `repository.delete`. Both asserts (status, exact description, `never().delete`) fail under that mutant. Closes r3 L-b.
- OMS `it_trims_edge_control_characters...`: PHP default trim does not strip `\x0C`, so the default-trim mutant leaves `S…\x0C` and the assertSame fails. Covers create, update (sku and previous_sku), delete, batch.
- I-1 removal at `:247` is behaviour-neutral. `getCause()` returns null on a self-cause, and the existing 2-cycle test still passes.

## Issues
[LOW] OMS test not executed here and has no kill proof recorded. Confidence MEDIUM. File: tests/Feature/Services/WmsApiServiceTest.php:2837. Fix: run it once (and under mutant `trim($x)`) in the OMS env and record it in fix-r2/r4 evidence.
[LOW] Untested sites: the `:1793` empty-sku guard (sku of only control chars) and the delete log `sku` at `:2030` are not pinned. Confidence HIGH. Reverting `:1793` alone would pass every test. Fix: one case with `product_sku = "\x0C"` expecting `skipped`/'empty sku'.

## Info
- L-d fixed: the DisplayName at `:1056` now says FIELD_MALFORMED_FORMAT. Verified by the diff.
- L-e partly done: the OMS comments (`:1727`, `:1754`) are now correct. The plan-side items from r3 L-e (E-1 #4 says 422/103 though delete answers 400/103; U+2028/U+2029 not mentioned) are not in these commits. Confirm they were edited in the plan.
- Also not in these commits: r3 L-a's prd count of edge control characters in OMS product_sku. The trim removes that exposure going forward, so only a historical count is left. r3 L-c (error code change, whitespace-only sku now 103) is unaddressed, which is acceptable.

## Regression
None found. The wms2 change only removes dead code. The OMS changes only widen the trim mask to Java's range, and PHP's default mask is a strict subset of it. A whitespace-only sku now trims to '' in a few more cases and is caught by the existing empty-sku skip.

## Positive
- One masked trim per outbound field, with comments naming the Java `String.trim()` range.
- Tests name their mutants in the assertion messages, and the data provider covers all four operations.
