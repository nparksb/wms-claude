# SBDEV-2624 — oms-laravel-api review round 1 fixes (+ D-M3)

- Worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624`, branch `feature/SBDEV-2624-facility-item-id`. Not pushed or rebased. The main checkout `v2/oms-laravel-api` was not touched.
- **New HEAD: `a1801d2c`**, two commits on top of `361ca2ed`:
  - `ac4a041b` SBDEV-2624: review round 1 — D-M2 expected code, guard hardening, review Lows
  - `a1801d2c` SBDEV-2624: D-M3 — guarded resend carries previous_sku = D
- `git status` is clean. No `.omc` files are in either commit. `git grep MUTANT -- app` returns nothing.
- DB: every run used throwaway containers. `oms-test-mysql` and `oms-test-mongo` were used for targeted runs and mutants (probe: testing/landlord/testing_reporting/mysql → `oms-test-mysql`, tenant/tenant_reporting → `oms-test-mysql` with a dynamic db, mongodb → `oms-test-mongo`). Suite shards each ran on a fresh `oms-test-mysql-r1-*` restored from `fresh.sql`; each printed 229 tables and its connection probe before running, and was removed afterwards.
- Mutants: each file was copied to `/tmp/sbdev2624-r1-orig/`, mutated in place, tested, then restored from that copy. A sha1 check after every restore matched. No git checkout, restore or stash was used.

## Design behaviour now implemented (D-M2 + D-M3)

| Request | `facility_item_id` | `previous_sku` |
|---|---|---|
| update, rename (same client) | sent when the map has a unique id | old SKU (trimmed, case-sensitive) |
| update, plain edit / C3 / client move | sent when the map has a unique id | **current SKU** when the id is sent; none otherwise |
| update, rename, no id | — | old SKU |
| guarded 108 resend | same X | **D** from `item_id=X is D` (D-M3) |
| 109 resend | same X | the original `previous_sku` |

Interpretation stated here: without `facility_item_id`, a plain edit still sends no `previous_sku`. D-M2 and D-M3 constrain only requests that carry the id. The case `no id: unchanged sends none` pins this.

## Findings → fix → test → mutant

| Finding | Fix | Test | Mutant → result |
|---|---|---|---|
| Sec M2 / **D-M2** (plain edit is an unguarded rename by id) | `updateSkuFromProduct`: `previous_sku = $previousSku ?? $sku` whenever `facility_item_id` is sent | AC-8c rewritten: `it_sends_previous_sku_as_the_expected_code` (6 cases); C3 test (mapped); `it_records_the_healed_id_when_the_resend_succeeds` (plain-edit case) | A: previous_sku only on a rename → **RED** (5: 3 AC-8c "by id" cases, healed plain-edit, C3 mapped) |
| AC-8c case sensitivity (kept) | — | AC-8c "case-only rename" by id and without id | B: `strcasecmp` → **RED** (2) |
| Sec L2 (109 resend dropped the CAS) | the 109 resend keeps the original `previous_sku` | AC-7f `…on_concurrent_marker` (rewritten assertion) | C: 109 resend drops previous_sku → **RED**; Q3: 109 resend gets D (null) → **RED** |
| **D-M3** (no request with an id omits previous_sku) | the 108 resend sends `previous_sku = D` | AC-7f `…on_precondition_marker`, healed-id test (both cases) | Q1: resend omits previous_sku → **RED** (3); Q2: resend sends the original previous_sku → **RED** (3); D (round 1): 108 resend keeps the sent previous_sku → **RED** (3) |
| Code M1 (no resend-success test) | — (test gap) | `it_records_the_healed_id_when_the_resend_succeeds` [rename, plain edit]: 2 updates, map = Y, results[F] success, no `rename-not-acknowledged` | J: drop recordSeen on the resend success → **RED** (2); K: key the log on the first attempt's status → **RED** (rename case) |
| Code M1 (marker prefix) | — | `it_does_not_resend_when_the_marker_is_not_at_the_start_of_the_description` | I: `str_contains` → **RED** |
| Code M2 (decoy masked the fail-closed path) | the decoy is seeded only for plain/quote/comma/inactive; `undecodable` is now a plain-text body that a raw fallback would parse whole | `it_skips_resend_…` [undecodable], [malformed] | H: raw-body fallback → **RED** [undecodable]; P2: proceed on a parse failure → **RED** [malformed, other_id]; P: inverted check → RED (ErrorException, recorded but not counted) |
| Sec M1 / code open Q (inactive holder) | the guard uses `Product::query()` (`active()` dropped) | `it_skips_resend_…` [inactive]; `it_logs_resync_skipped_bad_map_…` [inactive] | E: `active()` restored → **RED** (2) |
| Sec L1 (loose parse) | anchored `/^sku rename precondition failed: item_id=(\d+) is (.+), expected <preg_quote(sent previous_sku)>$/s` + `(int)$m[1] === facility_item_id`; the skip log reason is `unparseable description` / `item_id mismatch` | `it_skips_resend_…` [comma] (D contains `, expected `), [other_id] | F: old lazy regex → **RED** [comma]; G: no id check → **RED** [other_id] |
| Code L4 (any HTTP status) | `resyncDescription` requires `getHttpStatusCode() === 422` | `it_does_not_resend_on_a_non_422_marker` (400 with the 108 text) | L: drop the 422 check → **RED** |
| Code L3 (reload not re-checked) | after `Product::find`, skip on not found / virtual kit / empty SKU / client changed; log `SBDEV-2624 resync-skipped` with `reason` | `it_skips_the_resend_when_the_reloaded_product_is_no_longer_syncable` [client changed, empty sku, virtual kit] (asserts the count and the log reason) | M1/M2/M3: drop each arm → **RED** (its case) |
| Code L5 (drift not actionable) | the `backfillFacilityItemMap` completion log carries `code_drift_sample` = the first 50 rows. It is in the service, so it covers both the job and the command | `backfill_logs_the_first_50_code_drift_rows` (51 drifted products) | N1: drop the sample → **RED**; N2: no cap → **RED** |
| Code L6 (`id_missing` meaning) | docblock: it counts WMS itemdata rows with no id, not pruned map rows; command output reworded | doc only | — |
| Code L7 (dead param) | `@param int\|null $wmsItemId @deprecated Ignored …`. The tag sits inside the `@param` description so the method itself is not deprecated; the param is not removed | doc only | — |
| Code L8 (collation) | `resendReloadedUpdate` docblock notes `utf8mb3_general_ci`/PAD SPACE vs case-sensitive WMS codes; errs safe. No BINARY | doc only | — |
| Code L9 (non-atomic upserts) | `ProductWmsItem::recordSeen` comment explains why no transaction is needed | doc only | — |
| Code L1 (stale docs) | `LegacyInventoryController` OA `item_id` description, the `writeSkus` docblock and comment reworded. The repo commits `storage/api-docs/api-docs.json`. **CORRECTION (round 2, M1): the claim that the artifact was reset to one line was FALSE for `ac4a041b`/`a1801d2c`; those commits carried a 620-line unrelated regeneration (new `/api/print-runs`, `/api/batches/next-label`, changed `required` lists). Fixed in `4449bfad`; see Round 2.** Original text: the artifact was reset with `git show HEAD:… >` and only the one generator-produced line applied | doc only | — |
| Code L2 (stale SHAs) | `impl-oms.md` now cites `32b4587b` (gate) / `361ca2ed` (impl), with a note. The plan file had no stale SHAs | — | — |
| Conformance gap: no C3 test | — | `V1ServicesControllerTest::product_patch_never_sends_a_rename_to_the_wms` [mapped: previous_sku == sku, id sent; no map row: no previous_sku] | O1: C3 passes a previous SKU → **RED** (2); O2: drop the C3 WMS call → **RED** (2) |

All 24 mutants (A–L, M1–M3, N1–N2, O1–O2, P, P2, Q1–Q3) went red. Every red was for the assertion it targets (checked per data set), except P, which crashed with an ErrorException instead. P2 replaces P as the assertion-level kill for the malformed case.

### Gate / AC test edits (sanctioned by D-M2 / D-M3)
1. **AC-8c** `it_sends_previous_sku_only_when_sku_changed` → renamed `it_sends_previous_sku_as_the_expected_code`. The old cases "trailing space → none" and "unchanged → none" encoded the superseded rule. By id they now expect the current SKU. Without an id: a rename sends the old SKU, and unchanged sends none.
2. **AC-7f** `assertOneReloadedResendOnMarker`: the old assertion "resend has no previous_sku" (both markers) is replaced. 108 → `previous_sku === D` (D-M3); 109 → `previous_sku === original`. A positive control was added: the first update carries the rename's previous_sku.
3. **AC-7h** `arrangeBadMap`: the decoy was removed for the fail-closed cases, and `undecodable` is now plain text (code M2). This strengthens the test. Three cases were added. The log test is now parameterised (active, inactive).
- Not edited: AC-8e (`it_sends_no_previous_sku_on_client_move`). Its fixture has no map row, so it still holds unchanged. No other gate test was changed.

## Verification

- **§7.2 filter set** (`WmsApiServiceTest|ProductWmsItemTest|LegacyV2ProductWmsSyncTest|ProductControllerTest|FacilityWmsSyncTest|LegacyInventory|LegacyWmsControllerItemIdTest|LegacyProductUpdateServiceItemIdTest`):
  - round 1: **270 passed** (255 + 15 new);
  - after D-M3, with the C3 test added to the filter: **272 passed, 2770 assertions**.
- **Unit + Feature vs `baseline-oms.txt`, per test** (round-1 tree `ac4a041b`; D-M3 changes 1 app line and 2 test assertions, covered by the filter run): same 6 shard lists plus the 2 SBDEV-2624 Feature files (s6, s7), each on a fresh DB; Unit `--testsuite Unit`; all 9 ran in parallel.

| Suite | Tests | Failing now | Baseline | New | Gone |
|---|---|---|---|---|---|
| Unit | 4852 | 185 | 183 | 2 | 0 |
| Feature | 5802 | 609 | 606 | 4 | 1 |

  - Unit new 1: `QaWorkflowServiceStatusTest::test_qa_pass_does_not_buy_a_label_by_default` passes in isolation on a fresh DB. It mocks `WmsApiService`, so it does not touch the change.
  - Unit new 2: `ShippingServiceTest::switching_a_parcel_to_pickup_clears_its_insurance_charge` **also fails on pristine base `dad34d7e`** (scratchpad `base-copy`, fresh DB, 1/22 failing). It is environment or order dependent and not caused by this change. The file does not reference `WmsApiService` or `wms_item_id`.
  - Feature new 4: `OrderFileInteractiveUploadTest::test_205…`, 2× `LegacyOmsCronJobControllerBackorderTest`, and `BackorderAlertServiceTest::test_send_inventory_alert_logs_notification`. This is the same flaky set the P2 report documented (shared `oms-test-mongo` under concurrency). Rerun in isolation on a fresh DB: **OK, 20 tests**. None of the files references `WmsApiService`, `wms_item_id` or `ProductWmsItem`.
  - Feature gone 1: `OrderFileUploadExpectedFormatTest::a_transfer_file…` (order dependent; also gone in the P2 run).
  - **Net: 0 new failures attributable to this change.**
- **Pint** on touched lines (Pint applied to copies, rewritten lines intersected with added lines). My new lines now follow Pint (no-space concat, imports instead of FQNs). The residual overlap is whole-block reflows of blocks that were already dirty: the unsorted `use` blocks of `WmsApiServiceTest` and `FacilityWmsSyncTest` (Pint re-sorts the whole block and adds imports for older FQNs), and the unaligned `LegacyProductUpdateService::updateProduct` docblock (3 lines). The D-M3 commit has 0 overlap.

## Not fixed here (report only)
- **Facility-code case (code open Q).** `facilityItemIds` indexes `$map[$facility]` case-sensitively, while MySQL matches case-insensitively. If a writer stored `wsl` and `wms_url_lut` says `WSL`, the id is silently omitted, which degrades to the pre-fix behaviour. To confirm on prd: `SELECT DISTINCT BINARY facility_code FROM product_wms_item` against `wms_url_lut`.
- Security L3 (unauthenticated inbound legacy routes) is out of scope; it was already proposed on the ticket.
- The floor's independent review of this round has not been done in this lane.

---

# Round 2 — review `review-r2-oms-fixes.md` (M1, L1, L2 docblock, L3, L4, L5, L7)

- **HEAD after the follow-up below: `176d38c0`**; `4449bfad` is the first round-2 commit, on top of `a1801d2c` (its message: "SBDEV-2624: review round 2 — api-docs reset to one line, regex metachar tests, review Lows"). Not pushed, not rebased. `git status` clean. Main checkout `v2/oms-laravel-api` not touched.
- DB: all runs via the `oms-php:8.4` recipe on `oms-test-net`. Before running: `DB_HOST/LANDLORD_HOST/REPORTING_HOST=oms-test-mysql`, `MONGODB_HOST=oms-test-mongo`, 229 tables in `om1_owltest`, processlist idle (no peer running). Mutants: `WmsApiService.php` copied to `/tmp/sbdev2624-r2-orig/`, mutated in place, restored from the copy; sha1 identical after every restore (`f35e0d82…`). No git checkout, restore or stash.
- L2 and L6 plan wording were already done in the plan; only the `resendReloadedUpdate` docblock is touched here. Historic evidence files and plan snapshots still cite the old test names (L5); they are snapshots and were left as they were.

| Finding | Fix | Test | Mutant | Result |
|---|---|---|---|---|
| **M1** api-docs 620-line regeneration | `api-docs.json` rebuilt from `git show 361ca2ed:storage/api-docs/api-docs.json`; only the `item_id` description (the LegacyInventoryController OA text) replaced | `git diff origin/develop -- storage/api-docs/api-docs.json` = 1 insertion, 1 deletion (that line); `git diff 361ca2ed HEAD` on it = the same single line; `json.load` OK | n/a | done |
| **L1** `preg_quote` / suffix untested | none (code was correct) | `it_heals_a_rename_whose_previous_sku_has_regex_metacharacters` (previous `P/12 (A+B).$`, expects 2 updates, resend `previous_sku = D`); badMap case `expected_other` (108 text says `expected OTHER-…`, no resend) and `it_logs_the_distinct_skip_reason[expected_other]` (`resync-skipped-bad-map`, reason `unparseable description`) | L1a: drop `preg_quote($sentPreviousSku, '/')` -> **RED** (metachar test, ErrorException from the broken delimiter, not an assertion); L1b: `expected (.+)$` -> **RED** (2: skip test + reason test, assertion level) | done |
| **L2** docblock | `resendReloadedUpdate` docblock: "no create or update request that carries facility_item_id omits previous_sku (delete sends the id and never a previous_sku, by design)" | doc only | - | done |
| **L3** edge-whitespace D un-healable | docblock "Known limit" note; after the 108 parse, `$wmsItemNr !== trim($wmsItemNr)` skips with `Log::warning('SBDEV-2624 resync-skipped', reason 'wms code has edge whitespace')` (before the holder query) | badMap cases `edge_ws_trailing`, `edge_ws_leading` (no decoy, so only this check can stop the resend) and the reason test for each | L3: condition -> `false` -> **RED** (4: 2 skip tests + 2 reason tests) | done |
| **L4** no-id trailing-space AC-8c row | `'no id: trailing-space-only change abc_ -> abc sends none' => ['abc ', 'abc', false, 'none']` added to `previousSkuCases` | `it_sends_previous_sku_as_the_expected_code` (7 data sets now) | passes on the unchanged code (restores a sanctioned row; the by-id mutant A already kills the others) | done |
| **L5** stale test names | renamed to `it_skips_resend_on_a_bad_map_or_unparseable_108` and `it_logs_resync_skipped_bad_map` | same tests | n/a | done |
| **L7** mapped client move | `it_sends_no_previous_sku_on_client_move` renamed `it_sends_no_previous_sku_on_an_unmapped_client_move`; new `it_sends_the_new_sku_as_previous_sku_on_a_mapped_client_move` (map row for the product; asserts `facility_item_id === X`, `previous_sku === newSku`, `!== oldSku`); both share `assertClientMovePayload` | `ProductControllerTest` | A (D-M2): `previous_sku` only on a rename -> **RED** on the mapped test, on its `previous_sku` assertion (null !== new SKU). (3 `ProductAlternateSkuTest` client-move tests also matched the `client_move` filter and errored under that mutant; not relevant.) | done |

## Verification
- `WmsApiServiceTest|ProductControllerTest|V1ServicesControllerTest|FacilityWmsSyncTest`: **203 passed (2944 assertions)**.
- §7.2 filter set (`WmsApiServiceTest|ProductWmsItemTest|LegacyV2ProductWmsSyncTest|ProductControllerTest|FacilityWmsSyncTest|LegacyInventory|LegacyWmsControllerItemIdTest|LegacyProductUpdateServiceItemIdTest`, plus the C3 and backfill-sample tests): **281 passed, 3576 assertions** (was 272; +9 = metachar 1, badMap 3, reason 3, L4 1, L7 1). WmsApiServiceTest is part of it. The full Unit+Feature suite was not re-run: the only app change is one guarded early return and docblocks.
- No MUTANT/debug markers in `app/`; `git status` clean after the commit.
- Caveat: L1a went red through an `ErrorException` (unquoted `/` breaks the delimiter), so the `+ ( ) $` half of the quoting is not separately killed. A `preg_quote` without the `'/'` argument fails the same way.

## Round 2 follow-up — attributable kill for L1a (`176d38c0`)
- The coordinator rejected L1a as a kill: it went red through an ErrorException (broken `/` delimiter), and the `+ ( ) $` half was unkilled.
- Fix (tests only): `it_heals_a_rename_whose_previous_sku_has_regex_metacharacters` is now a data-provider test with `P/12 (A+B).$` and `A+B.(1)$` (no slash). Unquoted, `A+B.(1)$` does not match its own text, so the guard skips the resend silently.
- Mutant L1a': `preg_quote($sentPreviousSku, '/')` replaced by `$sentPreviousSku` (copy-restore from `/tmp/sbdev2624-r2-orig/`, sha1 `f35e0d82…` after restore). Result: **RED at assertion level** for `A+B.(1)$`: `[A+B.(1)$] expected the update and one resend, the guard skipped it [mutant: drop preg_quote ...]` / `Failed asserting that actual size 1 matches expected size 2`. The slash case still reds through the ErrorException, as before.
- `WmsApiServiceTest`: **120 passed (339 assertions)** on the restored code. DB probe as before (229 tables on `oms-test-mysql`). Separate new commit, nothing amended; `git status` clean.

# Round 3 — `review-r3-oms-fixes.md` (L1, L3; L2 doc names done by the coordinator)

- **New HEAD: `c731dc43`** on top of `176d38c0`. One new commit, nothing amended, not pushed. `git status` clean. DB probe before the runs: 229 tables on `oms-test-mysql`. Mutants via copy to `/tmp/sbdev2624-r3-orig/` and restore (sha1 `b618de3f…` after each restore).

| Finding | Fix | Test | Mutant | Result |
|---|---|---|---|---|
| **L1** PHP `trim()` vs Java `String.trim()` | the edge check is `trim($wmsItemNr, "\x00..\x20")` (every char <= U+0020); the docblock "Known limit" now says whitespace or control characters | new data case `edge_ws_ctrl` (D ends in `\x0C`) in the bad-map skip test and the reason test | default `trim($wmsItemNr)` -> **RED at assertion level** (2: `Failed asserting that 2 is identical to 1` on the skip test, and the reason test's null-context assertion) | done |
| **L3** reason test checked the value set | `it_logs_the_distinct_skip_reason` asserts `$context['reason'] === $reason` | the same test (4 data sets now) | log the reason under key `why` -> **RED** (3 edge-whitespace sets: `null` is not identical to the reason) | done |

- `WmsApiServiceTest`: **122 passed (342 assertions)** on the restored code.

---

# Round 3b — wms2 `review-r3-wms2-fixes.md` cross-repo items (L-a, L-e)

- **New HEAD: `2e48c0ed`** on top of `68c05f52`. One new commit, nothing amended, not pushed. `git status` clean. Main checkout `v2/oms-laravel-api` not touched. DB probe before the runs: 229 tables in `om1_owltest` on `oms-test-mysql` (all connections to the `oms-test-*` containers via `oms-recipe/omsenv.sh`).

| Finding | Fix | Test | Mutant | Result |
|---|---|---|---|---|
| **L-a** OMS default `trim()` lets edge control chars reach a WMS that now answers 103 | `trim(..., "\x00..\x20")` (Java parity) on `previous_sku` (`updateSkuFromProduct`), `sku` in `buildSkuDataFromProduct` (create/update/batch), `sku` in `deleteSkuFromProduct` (the send), and the empty-sku check in the resync guard | `it_trims_edge_control_characters_from_sku_and_previous_sku_before_sending` (create/update/delete/batch; sku ends in `\x0C`, previous_sku ends in `\x0C`) | default `trim()` on previous_sku -> RED (update); on `buildSkuDataFromProduct` sku -> RED (create, update, batch); on the delete sku -> RED (delete). `WmsApiService.php` restored from `/tmp/sbdev2624-r3b/orig`, sha1 identical (`a2124b25…`) | KILLED, each mutant by its own data set |
| **L-e** comments said wms2 trims edge control characters | docblock "Known limit" and the in-method comment now say wms2 rejects them (103) and trims only edge spaces, and the OMS trims first | doc only | - | done |

- The log-context `sku` in the delete-not-acknowledged warning keeps the default trim (log only, not sent).
- Not done: the prd count of OMS `product_sku` with an edge control character (L-a evidence gap). With the OMS trim in place the failure mode is gone, so it is not required before deploy.

## Round 3b verification
- `WmsApiServiceTest`: **126 passed (351 assertions)** (was 122; +4 data sets).
- §7.2 filter set (`WmsApiServiceTest|ProductWmsItemTest|LegacyV2ProductWmsSyncTest|ProductControllerTest|FacilityWmsSyncTest|LegacyInventory|LegacyWmsControllerItemIdTest|LegacyProductUpdateServiceItemIdTest|V1ServicesControllerTest`): **325 passed, 5128 assertions**, OK.
