**VERDICT: ITERATE**

r2 fixes 16 of my 17 r1 findings correctly. One MAJOR gap is left, and it reopens r1 #3 on a second entry point. The rest is Minor. Nothing here needs a redesign. r3 can be a targeted check of finding 1 plus the Minor fold-ins.

**Checked against:** wms2 origin/develop `62c92dd5`, OMS origin/develop `dad34d7e`, and WineCo prd (read-only).

### Status of r1 findings
| r1 | Status | Notes |
|---|---|---|
| 1 pre-mortem | **Fixed** | §11 has 6 scenarios, each with detection and mitigation. S6 is weak (finding 6 below) |
| 2 OMS retries | **Fixed** | Matches the code: §2.1 is right, and §7.5 #6/#8 and G7 are corrected |
| 3 sync twin / prune | **Partly fixed** | Correct for `reconcileSkus`. `backfillFacilityItemMap` has no test (finding 1) |
| 4 `wms_item_id` readers | **Fixed** | All three R1 sites confirmed (`LegacyWmsController:441` is client-scoped, `LegacyInventoryAdjustService:966` is not). Dormancy confirmed: wms2 `src/main` has `item_id` only as `@Column` on two view entities, whose Java field is `itemId`. One leftover reader (finding 7) |
| 5 AC-2 order mutant | **Fixed** | AC-2b with Z=(c,A) kills the 1↔2 swap: Z's code A passes the CAS, so Z gets renamed. Its red-on-base message is wrong (finding 4) |
| 6 AC-9 harness | **Fixed in lane, new defect** | Moved to the PG IT. Caffeine is real there (`CacheConfig @Profile("!redis")`). AC-4c's mutant prediction is wrong (finding 2) |
| 7 RF/RG | **Mostly fixed** | Two labels and one message are wrong (findings 3, 4) |
| 8 mutation floor | **Partly fixed** | The OMS list is incomplete (findings 1, 5) |
| 9 stockrecord orphans | **Fixed** | G6, the orphan query and the heal SQL are present. Prd has `index_stockrecord_created` and `(client_id, created DESC)`, so the day +1/+7 query is cheap |
| 10–16 | **Fixed** | 108 is free (constants run 105/106/107). `SDR_WRITE_WITHDRAWN` rebuttal of A-L7 accepted. C1 `previous_identity.client_id` is `$sourceClientId` (an int), so `=== (int)` holds. C2 cannot change client (no `client_id` in `$updateData`) |
| 17 verify rows | **Changed, not fixed** | Finding 8 |

### Findings

**1. MAJOR: the drift keep rule in `backfillFacilityItemMap` has no AC, no mutant and no report, so S3 can come back silently.**
- §3.5 says only `"backfillFacilityItemMap applies the same keep rule."`
- In the code, `backfillFacilityItemMap` (WmsFacilitySyncService.php:997) always calls `ProductWmsItem::pruneStale($facilityCode, $observationStart)` (:1045), with no dry-run gate.
- It runs from `BackfillFacilityWmsItemsCommand:68` and `BackfillFacilityWmsItemsJob:56`. Those are two entry points outside the operator sync flow described in §3.5.
- AC-15 tests only reconcile. OMS hand-mutant #10 covers only reconcile, and M-7 tests only reconcile.
- If the keep rule is missed here, a drifted product's id is pruned and its next edit creates the twin. That is exactly r1 #3, through another entry point, and nothing would flag it (the backfill emits no `code_drift`).
- Completeness checklist #2 (`"Every in-scope site has a §7.1 row"`) is false for P2.
- **Required:**
  - Add AC-15b: `FacilityWmsSyncTest::backfill_keeps_drifted_row_with_its_id`, which seeds a stored id X at F, WMS X under A, OMS SKU B, runs `backfillFacilityItemMap`, and asserts the row exists with `wms_item_id` = X.
  - Add mutant #12: `backfill prunes drift`.
  - Have the backfill return and log a `code_drift` count.
  - Add both entry points to §0 P2.

**2. MINOR: AC-4c's mutant prediction contradicts the plan's own translation table.**
- AC-4c says `"collision check via the cached service → 500"`. But §3.3 translates `DataIntegrityViolationException → the D2 422`.
- Under that mutant, the request is a cached miss for B, then the rewrite runs, then `saveAndFlush` raises a unique-key violation, which is translated to 422. AC-4c asserts `"rows unchanged; 422"`, so the mutant survives.
- AC-4's own mutant text already admits that the DIVE 422 `"lacks Y"`.
- *Mitigated by:* P1 acceptance requires every named mutant to go red, so this shows up on the first run.
- **Required:** AC-4c asserts that `description` contains `item_id=<Y>`, and the expected red becomes `"description lacks item_id=Y"`.

**3. MINOR: AC-9 is labelled RG, but it is red on base.**
- On base, the POST creates a new row (c,B)=N, so `findByClientIdAndItemNr(c,'B')` returns N, not X, and `(c,'A')` is still X.
- **Required:** relabel AC-9 as RF, with the red `"expected X found N"`.

**4. MINOR: AC-2b's stated red-on-base message is wrong, and the AC misses its main assertion.**
- On base, the id and `previous_sku` are ignored and (c,B) is created, so X and Z are unchanged and the row assertions pass.
- The red then comes from the status (`expected 422 was 204`), not from `"lookup order / CAS: X renamed"`.
- The AC also never asserts that no (c,B) row was created.
- **Required:** add `client row count unchanged` as the first assertion. Base then goes red on it with `"expected 2 rows found 3"`.

**5. MINOR: the OMS hand-mutant list does not match the §7.1 table, and some OMS behaviours have no row.**
- The table's AC-7b mutant (`drop recordSeen on update`) is not in the numbered list.
- The table's AC-8e mutant is `"compare SKU only"`, but list #9 is `"C1 uses wasChanged"`. Pick one; both should be listed.
- These have no AC at all:
  - O6, `deleteSkuFromProduct` sending the **per-facility** `facility_item_id`. Today it sends the global `$product->wms_item_id` (WmsApiService.php:1749).
  - The `rename-not-acknowledged` WARN, which is S2's only detector.
  - `createSkuFromProduct` no longer writing the global column. Current code at :1546–1548: `if ($firstItemId !== null && $product->wms_item_id === null) { $product->wms_item_id = $firstItemId;`
- **Required:**
  - Add AC-8h: delete sends F's id, and omits it when the id is NULL or ambiguous.
  - Add AC-7e: a failed update that carried `previous_sku` logs the token.
  - Extend AC-7b to assert `product.wms_item_id` stays NULL.
  - Add the matching mutants to the numbered list.

**6. MINOR: S6 and the CAS cover out-of-order renames only when the facility's id is known.**
- Scenario: edit1 is A→B, edit2 is B→C, and edit2 arrives first with no stored id.
- Step 1 misses, step 2 (`previous_sku`=B) misses, step 3 (C) misses, so a (c,C) twin is created. Edit1 then renames A→B. The WMS ends up with both B and C.
- S6's mitigation (`"CAS rejects the stale one"`) does not apply in this case.
- **Required:** state this residual in S6 and G7. The fingerprint query is its detector.

**7. MINOR: the claim that the global column has no reader is still false.**
- §3.5 and §6 say `"The column stays, with no reader"`.
- `WmsFacilitySyncService::backfillWmsItemIds` (:934) both reads and writes it: `if ($product->wms_item_id !== null || ! $found) { continue; } $product->wms_item_id = (int) $itemNrToId[$sku];`
- That is a fourth global-column writer, with first-facility semantics. It is harmless once R1 lands, but §0 says it enumerated the 7 files and missed this one.
- §0 also says `createSkuBatch` is the `"4th buildSkuPayload caller"`. `git grep "buildSkuPayload("` gives 4 hits: 3 callers (:1273, :1350, :4136) plus the definition (:1770).
- **Required:**
  - Delete that write, or list it.
  - Fix the caller count.
  - Note that the R1 change leaves `LegacyInventoryAdjustService:1103–1110` (`"only reachable on the wms_item_id path"`) dead, and that an inbound message with `item_id` but no client number now returns FAILURE.

**8. MINOR: the verify-script rows assert implementation shape, which the triage skill's row-hygiene rule 1 forbids.**
- Row 3 needs `.put("item_ids",`. A correct `Map.of("status","success","item_ids",ids)` would be permanently red, and rule 5 says a permanently-red row is worse than no row.
- Row 1 needs `'facility_item_id' =>`. A correct `$payload['facility_item_id'] = …` fails it.
- The OMS half of row 3 (`['item_ids']`) already matches base at WmsApiService.php:1527, so it proves nothing.
- All three rows duplicate AC-7a and AC-8a. Triage says to write a row only for something a test cannot see.
- **Required:** drop the script, which is opt-in at T3. Otherwise replace the rows with a cross-repo invariant that no test can see.

**9. MINOR: the nonce and per-facility id threading are underspecified.**
- `buildSkuPayload` is called inside `createSku($facility, $skuData)` and `updateSku($facility, $skuData)`. Neither takes a nonce or a product.
- §3.6 says the `*FromProduct` methods `"pass it to every facility"` but does not say how.
- **Required:** say how they reach `buildSkuPayload`: a new parameter on `createSku`/`updateSku`, or `$skuData` keys set per facility in the `*FromProduct` loop.
- In §3.5, `$previousIdentity` at the C1 call site is actually `$newlyResolvableAliases['previous_identity']` (ProductController:807/:821).

**10. MINOR: lane label, M-7, and a side effect on the existence map.**
- **Lane:** `ItemdataRepositoryTest extends BaseRepositoryIntegrationTest`, which is a full-context test, not U. Put the reflection check in a new `ItemdataRepositorySdrExportUnitTest`, or relabel it.
- **M-7 can't test pruning:** it says `"run facility sync dry-run"`, but `pruneStale` runs only `if ($clientIds === null && ! $isDryRun)`, so `"map row kept"` is vacuous there. Use a real full run on dev.
- **The keep rule changes what the existence map claims:** keeping a drifted `product_wms_item` row tells the pre-batch/pre-Ready checks that B exists at F while WMS holds A. B's orders then fail at the WMS import (loudly) until the rename heals. That is better than an empty twin, but S3 should say it.
- **AC-12:** name the error code for the lock and optimistic-lock 422s (105, 108 or other).

### What's missing
- Tests for the `backfillFacilityItemMap` keep rule and the delete-side id (findings 1, 5).
- The out-of-order no-id residual in the pre-mortem (finding 6).

### Gate check
- **Pre-mortem:** Pass (6 scenarios; S6 incomplete).
- **One assertion per AC and RF/RG labels:** mostly right. Wrong on AC-9, and AC-2b's base message is wrong.
- **Mutant messages:** AC-2b names its mutant. The AC-4c prediction is wrong.
- **OMS hand-mutant list:** Fail (finding 5).
- **Verify-row hygiene:** fail-closed, red-on-base and `PROJECT_ROOT` are stated, but the rows are shape assertions (finding 8).
- **New numbers:** 108 is free, Itemdata is in `exposeIdsFor` (so drift inversion has ids), the G6 math (≈0.023) holds, and the orphan query is indexed. The `buildSkuPayload` caller count is wrong (finding 7).

### Floor
- DB query confirming the symptom: done.
- Failing test first: planned.
- Mutation-check every new assertion: incomplete on OMS (findings 1, 5).
- Independent review: planned.
- Both full-suite baselines: planned.

### Verdict justification
- I reviewed in THOROUGH mode, not adversarial: one MAJOR, no pattern of systemic problems.
- Realist check moved finding 2 from MAJOR to MINOR. Mitigated by: P1 requires every named mutant to go red, so it fails immediately.
- Finding 1 stays MAJOR. Nothing would detect it (the backfill emits no drift report), and it undoes a mitigation for data integrity.
- To get APPROVE: fix finding 1. Findings 2–10 can be folded in without a redesign.

### Open questions (unscored)
- Who runs `BackfillFacilityWmsItemsJob` on prd, and how often? That sets how exposed finding 1 is.
- Batches with several renames (not from the OMS, per G5) would hold an earlier rename's itemdata FOR UPDATE lock through a later rewrite. Should that be noted under §7.5 #4?

*Ralplan summary row*
- **Principle/option consistency:** Pass. Driver 1 still has the finding 1 hole.
- **Alternatives depth:** Pass (A7 and A8 weighed).
- **Risk/verification rigor:** Fail, narrowly (findings 1, 2, 5).
- **Deliberate additions:** Pass (pre-mortem present; observability has the orphan monitor and log tokens).