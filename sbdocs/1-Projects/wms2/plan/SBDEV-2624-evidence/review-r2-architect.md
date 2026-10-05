**Verdict: REVISE (light).** The r2 design holds up and I see no regression in the new surface. The two rebuttals are correct, and I was wrong on L7. What's left is two Medium fixes and a few Lows. None of them changes D1–D3, Q1–Q4 or the H1/H2 shape.

Checked against wms2-api `origin/develop` `62c92dd5` and oms-laravel-api `origin/develop` `dad34d7e`. I also ran three read-only queries on WineCo and Hydra prd.

## A. r1 findings: are the fixes really in the plan body?

| r1 | In the body? | Notes |
|---|---|---|
| H1 | Yes | §3.3 step 3 adds the compare-and-set check on the reloaded row, AC-2a/2b are split, §7.5 #8 is corrected. Follow-up in N2. |
| H2 | Yes | §3.3 step 4 order is collision check → native rewrite → setters → `saveAndFlush`; AC-11 pins it. Batch caveat in N4. |
| M1 | Yes (chose the gap, G6) | The choice is defensible, but the stated reason is wrong (N3). |
| M2 | Yes | §3.5 drift rule and AC-15. Side effect in N7. |
| M3 | Yes; rebuttal accepted | Details below. |
| L1 | Partly | The translations exist but cannot fire on the create branch or a plain update (N1). |
| L2–L5 | Yes | |
| L6 | Yes | The reason given is weak, and that came from my own r1 (N9). |
| L7 | Rebuttal correct; I withdraw it | Details below. |

**L7 (SDR PATCH on itemdata): the plan is right, my r1 citation was wrong.**
- `RestConfiguration.java:498` is `net.aim_ai.wms.model.Itemdata.class,` inside `SDR_WRITE_WITHDRAWN = {` (:452).
- The loop at :568–573 applies `httpMethods.disable(WRITE_VERBS)` to collection, item and association exposure.
- `WRITE_VERBS = {HttpMethod.POST, HttpMethod.PUT, HttpMethod.PATCH, HttpMethod.DELETE}` (:28).
- It is called at :888: `configureUnwrittenResourceWriteExposure(config);   // SBDEV-3157`.
- The `disable(HttpMethod.PUT, HttpMethod.DELETE)` lines I quoted in r1 (:685, :860, :880) are for `Advice`, `Client` and `Cyclecount`.
- `SdrWriteWithdrawalContextTest.java:140` pins `"Itemdata",`. W14 OUT is correct.

**M3 (OMS sends `previous_sku` on delete): the rebuttal is right.**
- `deleteSkuFromProduct(\App\Models\Product $product)` (WmsApiService.php:1709) has only the current model.
- Both callers (`ProductController.php:912`, `LegacyV2ProductController.php:700`) soft-delete with no SKU change, so the OMS has no previous value to send.
- The leftover case is a delete after a failed rename: WMS still holds A, the OMS holds B, the request carries `facility_item_id=X`. The new check returns 400 and keeps X.
- That is no worse than today. Today `findByClientIdAndItemNr(client, "B")` misses and returns 400 `ENTITY_DOES_NOT_EXISTS` (`SkuRestController.java:376-378`). So it is not a regression, but it is silent (N6).

## B. New findings

**N1 — Medium. The 422 translations cannot catch create-branch or plain-update failures, because those rows are written at commit.**
- **Evidence:**
  - `AbstractBaseEntity.java:20`: `@GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "entity_gen")`.
  - The create branch does `itemdataRepository.save(itemData);` (SkuBatchCreateUpdateService.java:66). With a SEQUENCE id that only persists; the INSERT waits for flush or commit.
  - §3.3 step 5 uses plain `save` for a row that is not renamed.
  - The translation table says it is "wrapped around steps 4b–4d and the create insert". But a duplicate-key error from the insert, or a version loser on a plain update, surfaces when the commit interceptor flushes, after `upsertAll` has returned. It escapes as a 500. That is the exact L4 case AC-13 is meant to close, and it contradicts §6 ("lock and optimistic conflicts return 422 instead of … a 500").
  - AC-12 injects the exceptions only "at `saveAndFlush`", so it cannot see this.
- **Fix (either):**
  - Use `saveAndFlush` in the create branch and in step 5, inside the translation wrapper.
  - Or translate in the controller around the `upsertAll` call: catch `DataIntegrityViolationException`, `PessimisticLockingFailureException` and `ObjectOptimisticLockingFailureException` coming out of the proxy.
- **Test:** add a PG-IT case. Commit (c,B) between the uncached re-check and the commit (latch), then assert 422 and not 500.

**N2 — Medium. After a failed rename, a second rename is rejected until someone makes a plain edit.**
- **Sequence:** the WMS is stuck at A after a failed A→B. The operator then renames B→C, which sends `{facility_item_id:X, previous_sku:B, sku:C}`. The row is A, and A ∉ {B, C}, so it returns 108. Every later rename is also rejected.
- S2 and S6 say "the next plain edit … converges". But an operator who sees a wrong code is more likely to rename again than to make a no-op save.
- **Fix:** when the OMS gets 108 back, reload the product from the DB (do not reuse the request copy). Then send one plain update with the current SKU, no `previous_sku`, the same facility id and a new nonce. This is safe in the H1 race: the row is at C and the current SKU is C, so nothing changes. In the stuck case it renames A→C, which is correct.
- Pin it with an OF test, plus a mutant that resends the request copy's `sku`, which must go red.
- This is sub-T3 and belongs on this ticket.

**N3 — Low. The G6 reasoning contradicts H2.**
- §6 says "under either statement order no lock makes the stock writer wait for the rename". But H2 is built on the opposite fact: every child-FK insert takes FOR KEY SHARE on itemdata X, and the rename's FOR UPDATE conflicts with it.
- So a second pass of the same UPDATE right after `saveAndFlush`, in the same tx with no `afterCommit` and no `REQUIRES_NEW`, would pick up the stockrecord rows of every stock tx that inserted a child-FK row for X. The `saveAndFlush` waits for those txs to commit, and READ COMMITTED takes a fresh snapshot per statement, so the second pass sees them. That avoids the SBDEV-3267 trap.
- What it costs: a second index scan while the FOR UPDATE is held. That scan walks the ~44k rows the first pass already rewrote, so it extends H2's lock time.
- **Fix:** either correct the sentence and keep G6, or adopt the second pass as an option behind M-5's timing. The orphan query is fine as written: `index_stockrecord_created` and `index_stockrecord_client_created` exist on WineCo prd.

**N4 — Low. "Milliseconds" lock hold holds only for a batch with one rename.**
- After `saveAndFlush` for item k, X's FOR UPDATE is held until commit, which includes the rewrites for items k+1…n.
- The OMS sends one SKU per update call, and `createSkuBatch` never renames, so it is fine today.
- **Fix:** say so in §7.5 #4.
- Auto-flush is otherwise safe. The reloaded `row` is clean before 4b. Pending plain updates from earlier items that get flushed by the native query only take FOR NO KEY UPDATE, which does not conflict with KEY SHARE. `saveAndFlush` on the managed row still runs `WHERE version=?`, so the version check is still enforced.

**N5 — Low. Two of AC-16's three mutants cannot go red with the stated fixture.**
- `LegacyWmsController.php:441` (`->where('client_id', $client->client_id)`) and `LegacyProductUpdateService.php:164-165` are already client-scoped. An "item_id of another client's product" misses there with or without the fix.
- **Fix:** for those two readers, seed a product of the **same** client that holds a stale global `wms_item_id` equal to the inbound `item_id`.
- Also delete the branch that becomes dead at `LegacyInventoryAdjustService.php:1103` ("only reachable on the wms_item_id path, where no client number was sent").
- **Is T2 right?** Yes. I found no other reader: `git grep wms_item_id` over `app/` shows only O2, O6, R1 and the `Product` fillable/cast lines; nothing in siteboss-frontend (`origin/main`). Removing the backfill breaks nothing.

**N6 — Low. A delete rejected by the new check is invisible.**
- Neither delete caller looks at the `results` array that `deleteSkuFromProduct` returns; they only log exceptions.
- **Fix:** add a wms2 `LOG.warn("SBDEV-2624 SKU_DELETE_PRECONDITION …")` and add it to §7.4. Optionally log a warning on the OMS side when a facility result is a failure.

**N7 — Low. A kept drift row tells `presentAtFacility` that B exists at F.**
- `BatchProcessingService.php:909`: `ProductWmsItem::presentAtFacility(...)` is behind `config('wms.facility_sku_checks')`, which is off by default.
- The WMS still rejects the order, so nothing is lost, but the pre-check is wrong for that row.
- **Fix:** add one line to G7 or S3.

**N8 — Low. AC-8c has no case-only rename.**
- If the OMS compares SKUs case-insensitively, renaming `abc`→`ABC` drops `previous_sku`. It then goes either to the id-recovery path, logged with a misleading BY_ID_RECOVERY warning, or to a new `ABC` twin.
- **Fix:** add a row that requires a case-sensitive `!==` after trimming.
- **Trimmed-equality edge, measured:** WineCo prd has 1 untrimmed `item_nr` of 10,770 with no twin. Hydra prd has 1 of 2,814: id 1919451 `'BONMFPN23 '`, which has a trimmed twin 1927641, and both have 0 stockunits. Reconcile keys on the exact `(string) $itemNr`, so it can never map an id to the untrimmed row. No action needed.

**N9 — Low. The §5.3 reason for wms2-first is weak (this came from my r1 L6).**
- Twins get created during the gap in **either** order, because an old OMS never sends `previous_sku`.
- The real reason to go wms2-first: the old OMS already records per-facility ids from a create response (`WmsApiService.php:1541`, `'wms_item_id' => is_numeric($facilityItemId) …`). So the new 200 + `item_ids` starts filling the map during the gap.
- **Rollback is still safe.** Old wms2 drops the new fields as unknown, the NULL guard keeps stored ids, and an old OMS's `item_id` is ignored. The irreversible part is unchanged: stockrecord rewrites that already ran.
- **Fix:** reword the bullets in §5.3.

**Checked, no action**
- **Error code 108 is free.** The 100 group ends at `CHILD_NOT_PART_OF_PARENT = 107;` (WmsConstants.java:1742), and the next constant is 200.
- **The 108 constructor call matches.** The ctor is `WebserviceBusinessExceptionClientSide(int errorCode, Throwable exception, Object... parameter)`.
- **C1 types match.** `$sourceClientId = (int) $product->client_id;` (ProductController.php:694), so the strict `===` is int against int.
- **C1 scope.** `$previousIdentity` lives inside the transaction closure. Read it outside as `$newlyResolvableAliases['previous_identity']` (:807), not as the bare variable.
- **Drift inversion works.** The WMS item list carries ids: `$wmsItemNrByClientId[...][(string) $itemNr] = $row['id'] ?? true;` (WmsFacilitySyncService.php:242). Because the kept row goes into `observedFacilityItems`, `last_seen_at` is refreshed, so `pruneStale` (`where('last_seen_at', '<', $seenBefore)`) keeps it.

## C. Tradeoff (new, from N2)

- **Safety vs. convergence.** The compare-and-set check makes out-of-order renames safe, but a stuck facility stays stuck until something sends a plain edit.
- Having the OMS resend once with a freshly reloaded SKU on 108 gets both. The cost is one extra round trip, on an OMS code path that is fresh and only covered by tests that run under Docker.
- I see no new steelman against the design. A8 (a stable OMS key on itemdata) remains the strongest rival, and §9 weighs it fairly.

## References
- `/Users/np1076/dev/spk/owl/v2/wms2-api` (origin/develop):
  - `src/main/java/net/aim_ai/wms/RestConfiguration.java:28,452,498,568-573,685,860,880,888`
  - `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java:20`
  - `src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java:66,78`
  - `src/main/java/net/aim_ai/wms/service/WmsConstants.java:1740-1742`
  - `src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java:376-394`
  - `src/test/java/net/aim_ai/wms/security/SdrWriteWithdrawalContextTest.java:140`
- `/Users/np1076/dev/spk/owl/v2/oms-laravel-api` (origin/develop):
  - `app/Services/WmsApiService.php:1541,1709-1752`
  - `app/Services/WmsFacilitySyncService.php:242,279-284,635-652,997-1045`
  - `app/Models/ProductWmsItem.php:81-160`
  - `app/Services/BatchProcessingService.php:895-909`
  - `app/Services/Legacy/LegacyInventoryAdjustService.php:963-990,1103`
  - `app/Http/Controllers/Api/Legacy/LegacyWmsController.php:438-458`
  - `app/Services/Legacy/LegacyProductUpdateService.php:160-171`
  - `app/Http/Controllers/Api/ProductController.php:694,742,807,829,912`
- **DB (read-only, 2026-10-02):**
  - Untrimmed `item_nr`: WineCo prd 1 of 10,770; Hydra prd 1 of 2,814 (1919451 / twin 1927641, 0 stockunits each).
  - Case twins: 0 in both.
  - `stockrecord.created` is indexed (WineCo prd).
- Plan under review: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-2624-evidence/plan-snapshot-r2.md`