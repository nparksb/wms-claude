# SBDEV-2624 wms2-api: review of the round-1 fix commits (r2)

- head: `02a20c56` (worktree `.claude/worktrees/wms2-api/SBDEV-2624`)
- Scope: `git diff 086cb309..02a20c56`, which is `147e1df2` (D-M3) plus `02a20c56` (the Lows). Nothing outside it was reviewed.
- OMS contract: worktree `.claude/worktrees/oms-laravel-api/SBDEV-2624` at `68c05f52`, read only.
- Reviewer: code-reviewer lane, 2026-10-03. Separate from the authoring lane.
- Evidence:
  - Targeted unit run at HEAD with JDK 21.0.8. `pgrep` was empty first, and it was the only build.
    - `SkuBatchCreateUpdateServiceUnitTest` 36/0/0
    - `SkuRestControllerUnitTest` 48/0/0, all nested classes
    - `StockrecordRenameQueryShapeUnitTest` 1/0/0
    - `CacheEvictionOnWriteUnitTest` 17/0/0
    - `NeverMatcherNullBlindnessArchTest` 4/0/0
  - ITs were not re-run. The fix log's `SkuRenameInPlaceIT` 17/17 is taken as stated.
  - `git grep BY_ID_RECOVERY -- src/main src/test` → 0 hits. Positive control: `SKU_RENAME_STALE_LOOKUP` → 2 hits.

## Verdict: COMMENT

Every claimed fix is present and does what it says. No new HIGH or CRITICAL defect was found.

The two-stale residual is real, and it is worse than the fix log says in two ways:
- **One** stale cache entry is enough.
- D-M3 turned one sub-case of it from a correct rename into a duplicate create.

It can be closed with a one-line change that stays inside D-M3. I recommend doing that before the PR (M1).

## Counts

| Severity | n |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 1 |
| LOW | 6 |
| Info | 6 |

---

## Stage 1: spec compliance (D-M3 and the claimed fixes)

| Claim | Verdict | Where |
|---|---|---|
| D-M3: id hit, no previous_sku, `item_nr ≠ sku` → 108 `SKU_RENAME_PRECONDITION` | ✅ | `SkuBatchCreateUpdateService.rename`: `if (previousSku == null \|\| !oldCode.equals(previousSku))` |
| D-M3: a stale `sku` lookup is discarded and re-checked uncached | ✅ | `upsertAll`: `if (row != null && VIA_SKU.equals(via) && !row.getItemNr().equals(code)) { … row = null; }`, then the existing A-L4 `itemdataRepository.findByClientIdAndItemNr` |
| D-M3: blank previous_sku → null | ✅ | `normalize()`: `sku.setPreviousSku(previousSku.isEmpty() ? null : previousSku)` |
| `SKU_RENAME_BY_ID_RECOVERY` removed | ✅ | 0 hits in src |
| D-M3: exact via (code L8b) | ✅, with L1 below | `resolveForUpdate(…, via)` records the step. `previous_sku == sku` skips step 2 and records `sku` |
| D-M2 HTTP twin | ✅ | IT `update_previousSkuEqualsSku_rowAtOtherCode_rejected` |
| code L1: 23505-only translation | ✅ as code, ⚠ plan not amended (L3) | `translate` / `isUniqueViolation` |
| code L3/L4, sec I3: duplicate (client, sku) → 105 | ✅ | `rejectDuplicateKey` |
| sec L3: one rename per request → 103 | ✅ | update loop `++renames > 1` |
| sec L4: control characters (TAB allowed in sku_name) | ✅ (judged acceptable, see I-2), L4/L5 on the details | `rejectControlCharacters` |
| sec L1: unscoped reload | ✅, side effect on a fixture (L2) | `!Objects.equals(row.getClientId(), clientId)` → miss |
| sec L2: uncached delete fallback with the CAS on both paths | ✅ | `delete`: `itemdataRepository.findByClientIdAndItemNr`, CAS hoisted out of the id branch |
| code L5/L6/L7, conformance M12 | ✅ | tests only |

Stage 1 passes, with one exception: the 23505-only change (L3) departs from the plan's §3.3 translation table, and no D-M amendment sanctions that.

---

## Issues

### [MEDIUM] M1: a stale *negative* cache entry for previous_sku creates a duplicate (c,B). D-M3 also turned the "double-stale" sub-case from a correct rename into that duplicate
- File: `src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java`, `resolveForUpdate`, step 2:
  ```java
  if (sku.getPreviousSku() != null && !sku.getPreviousSku().equals(sku.getSku())) {
      Optional<Itemdata> byPrevious = itemdataService.findByClientIdAndItemNr(clientId, sku.getPreviousSku());
  ```
  The service side is `SkuBatchCreateUpdateService.upsertAll`. Its only uncached re-check is by `code`:
  ```java
  Itemdata recheck = itemdataRepository.findByClientIdAndItemNr(clientId, code).orElse(null);
  ```
- Confidence: HIGH that it is real. Likelihood: LOW (see below).
- Misses are cached. `ItemdataService.findByClientIdAndItemNr` is `@Cacheable("itemdata")`, `CacheConfig` builds `new CaffeineCache(name, cache)`, and `allowNullValues` defaults to true. Redis also caches nulls by default. So `Optional.empty()` is held for the 5-minute TTL.
- **Scenario 1: single-stale. The fix log does not list it. It is pre-existing at `086cb309` and still open.**
  1. X is at A. This JVM holds a stale (c,A) → *miss* from before X reached A. That needs another replica's write, or a concurrent request's cache put landing after this JVM's `finally` clear.
  2. The request is `{sku:B, previous_sku:A}` with no `facility_item_id`.
  3. Step 2 gets the cached miss. Step 3 (c,B) is a true miss.
  4. `existing == null`, then the re-check by B misses, then a **new (c,B) is created**. X stays at A with its stock.
  5. That is the SBDEV-2624 defect itself: create on update.
  - Only the (c,A) entry has to be stale. The (c,B) entry need not be.
- **Scenario 2: double-stale, as in the fix log. A regression introduced by D-M3.**
  1. Add a stale (c,B) → X to scenario 1. X really is at A.
  2. At `086cb309`: step 3 returns X, the reload shows A, `rename()` runs, and the CAS (`previous_sku A == A`) passes. X is renamed correctly.
  3. At `02a20c56`: `via == sku` and `A ≠ B`, so X is discarded. The re-check by B misses, so a duplicate (c,B) is created.
- **How likely is it?**
  - It needs a rename request **without** `facility_item_id`. After the OMS lands D-M2/D-M3, every mapped product sends the id. Step 1 is uncached, so it hits X first and step 2 is never consulted. That leaves unmapped products only: no `product_wms_item` row for that facility.
  - It needs a stale negative entry, so in practice more than one replica (Q5, Joe, is still open) or the narrow put-after-clear race on one JVM.
  - Before the OMS deploys there is no exposure, because the old OMS sends no previous_sku.
  - So the likelihood is low and the blast radius is the ticket's own failure mode. `SKU_RENAME_STALE_LOOKUP` logs scenario 2. **Scenario 1 logs nothing**: it is a silent create.
- **Fix (cheap, closes both scenarios, stays inside D-M3).** Make step 2 uncached:
  ```java
  Optional<Itemdata> byPrevious = itemdataRepository.findByClientIdAndItemNr(clientId, sku.getPreviousSku());
  ```
  - `previous_sku` is already trimmed by `normalize()`, so dropping the service's `trim()` loses nothing.
  - Cost: one indexed query, and only on a request whose `previous_sku ≠ sku` and whose id missed or was absent. Those are renames of unmapped products, which are rare.
  - D-M3 still holds:
    - a rename still happens only with `previous_sku`;
    - `rename()`'s CAS still runs, and passes because `row.itemNr == previous_sku` by construction;
    - the 4a collision check still runs;
    - the stale-`sku` discard is untouched.
  - The fix adds no exposure that §3.2 step 2 does not already have with a fresh cache. Today, with a warm correct cache, step 2 would return the same row.
  - Alternative, if the controller should stay as it is: the same query in `upsertAll` after the code re-check misses, guarded by `!failIfExists && previousSku != null && !previousSku.equals(code)`, setting `via = VIA_PREVIOUS_SKU`. Keep it off the create endpoint: a create must never turn into a rename.
  - Tests:
    - a controller unit test that step 2 calls `itemdataRepository`, not `itemdataService`;
    - an IT that warms (c,A) → miss, then `UPDATE itemdata SET item_nr='A'` behind the cache, then sends `{sku:B, previous_sku:A}` and expects X renamed, `idsFor(C,"B") == [X]`;
    - mutant "cached step 2" → red.
  - Wording: D-M3 says "re-check by code". This extends the uncached lookup to the step that names the expected code, so it is worth a one-line note to Nam.

### [LOW] L1: a missing `via` entry defaults to `VIA_SKU`, which is the unsafe direction for a would-be rename
- File: `SkuBatchCreateUpdateService.upsertAll`:
  ```java
  // A row with no recorded step is treated as the weakest one, a cached lookup by sku.
  String via = viaByClient.getOrDefault(clientId, Collections.emptyMap()).getOrDefault(code, VIA_SKU);
  ```
- Confidence: MEDIUM. It is latent, because both current callers are correct: update records a via for every key, and create passes no `existing`.
- Scenario: a future caller passes an id-resolved `existing` without a via, for `{id X, previous_sku D, sku B}` with X at D.
  - The default `sku` discards X. The re-check by B misses, so a duplicate (c,B) is created.
  - Defaulting to "stale" turns a CAS-guarded rename into an unguarded insert.
  - The unit test `upsertAll_foundRowWithoutRecordedVia_defaultsToSkuStep` pins this behaviour.
- Fix: when `existing != null` and there is no via entry, throw `IllegalStateException`. This is a programming error. Or default to a value that routes into `rename()`, where the CAS can only answer 108 or perform a previous_sku-verified rename. Neither writes a row that the CAS did not check. Then change the pinned test.

### [LOW] L2: the security-L1 client check silently moved the AC-12 rollback test from the update path to the create path
- File: `src/test/java/net/aim_ai/wms/unit/service/SkuBatchCreateUpdateServiceUnitTest.java:107-118` (`upsertAll_shouldRollbackEntireBatch_whenSaveFails`):
  ```java
  Itemdata existing = new Itemdata();
  existing.setId(99L);
  existing.setItemNr("SKU001");          // no setClientId(1L)
  ...
  lenient().when(itemdataRepository.findById(99L)).thenReturn(Optional.of(existing));
  ```
- Confidence: HIGH. The test run at HEAD logs:
  `SKU_RENAME_STALE_LOOKUP clientId=1 itemId=99 rowClientId=null sku=SKU001 via=sku`
- What happens:
  - The reloaded row has `clientId == null`, so the L1 check treats it as a miss.
  - The re-check goes to the unstubbed mock, which returns `Optional.empty()`, so the code takes the create branch.
  - The create `saveAndFlush` throws 105, so the test stays green, but it no longer reaches the step-5 update flush that it was written to cover.
  - This is the "cross-field setter silently un-pins fixtures" pattern, with no diff to the test's assertions.
- Fix: `existing.setClientId(1L)`. Assert that the argument `saveAndFlush` received is `existing` (the update path), or that `itemdataRepository.findByClientIdAndItemNr` was `never()` called. Sweep the other hand-built `Itemdata` fixtures that reach `upsertAll` for the same omission.

### [LOW] L3: the plan's §3.3 translation table and §7.5 #4 do not describe the code as shipped
- Confidence: HIGH.
- `translate()` now rethrows a non-23505 `DataIntegrityViolationException`, so the request gets a 500 through `RestEndpointExceptionHandler`'s `@ExceptionHandler(Exception.class)`. Plan §3.3 still says: `DataIntegrityViolationException | 105 …`.
  - The behaviour is defensible: the 500 was the pre-ticket outcome, and "duplicate value" would name a false cause.
  - But no amendment sanctions it, and this is an error-shape change on the contract.
- The 105 for a duplicate (client, sku) inside the request, and the 103 "one rename per request", are not in §3.x either. §7.5 #4 still reasons about "a batch with several [renames]" being possible.
- Fix:
  - Add one D-M line, or §3.3 edits, for all three.
  - Put the 103 cap in §7.5 #4: "cannot arise, rejected 103".
  - Get Nam's acknowledgement for the 500.
  - Not a code change.

### [LOW] L4: control characters are rejected with FIELD_NOT_SET (100), whose text contradicts the cause
- File: `SkuRestController.rejectControlCharacters`:
  ```java
  throw new WebserviceBusinessExceptionClientSide(WmsConstants.FIELD_NOT_SET, null,
          "sku", "request (control characters are not allowed)");
  ```
  This renders as `"field sku not set for request (control characters are not allowed)"`, but the field *is* set.
- Confidence: HIGH.
- Fix: use `FIELD_MALFORMED_FORMAT` (103), which renders as `"field sku has wrong format for request (control characters are not allowed)"`.
  - Neither code is an OMS resend marker. `WMS_RESYNC_MARKERS` holds only the 108 and 109 phrases.
  - The OMS batch bisect keys on `WmsException`, not on the code. So nothing downstream changes.

### [LOW] L5: `Character.isISOControl` does not cover U+2028 / U+2029, and edge control characters are trimmed silently, not rejected
- File: `SkuRestController.hasControlCharacter`:
  `value.chars().anyMatch(c -> Character.isISOControl(c) && !(allowTab && c == '\t'))`
- Confidence: MEDIUM.
- (a) U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are format characters, not ISO controls. Logback's plain file appender does not split on them, but some log viewers and JSON-line shippers render them as line breaks.
  - Fix: also reject `c == 0x2028 || c == 0x2029` (and optionally `Character.getType(c) == Character.FORMAT`) in `sku` and `previous_sku`. prd impact needs one `item_nr ~ '[  ]'` count first.
- (b) `normalize()` runs first, and Java `trim()` strips everything ≤ U+0020, so `"B\n"` is accepted as `"B"`.
  - That is safe for the logs, since the raw value is never logged.
  - It is a pre-existing OMS/WMS divergence: PHP `trim()` strips only ` \t\n\r\0\x0B`. A product SKU with an edge `\x01`–`\x1F` is stored differently on each side, and its 108 echo would not match the OMS anchored regex (fail-closed skip).
  - Info-level. No change needed in this ticket.

### [LOW] L6: the `isUniqueViolation` cause walk only guards a self-cause
- File: `SkuBatchCreateUpdateService.isUniqueViolation`:
  `for (Throwable t = e; t != null; t = t.getCause() == t ? null : t.getCause())`
- Confidence: LOW. It does not happen with the PG driver or Hibernate.
- A 2-cycle (A→B→A, possible through `initCause`) would loop forever on the request thread while the transaction is open.
- Fix: cap the depth (for example 16), or track an identity set. `NestedExceptionUtils`-style walks do the same.

---

## Info / judgement calls

- **I-1: the duplicate (client, sku) 105 cannot hurt a legitimate OMS create batch of 200 more than today.**
  - The OMS does not deduplicate. `WmsFacilitySyncService` builds `missingByClientCode[$clientCode][] = $product` (around :675) with no seen-set, and the OMS holds duplicate SKUs (Q3). So a 200-batch *can* carry the same SKU twice.
  - At `086cb309` the second copy already failed. The first `saveAndFlush` committed inside the transaction, the uncached re-check found it, and `failIfExists` returned 422 ENTITY_ALREADY_EXITS, rolling back all 200.
  - Now it fails earlier, in the controller before any insert, with 105.
  - `deliverSkuBatch` bisects on any `WmsException`, so the outcome is the same: one created, the other isolated as failed. The request count is about the same.
  - Case-only twins (`abc` and `ABC`) are distinct keys, as they are in the WMS unique constraint, so they are not rejected. That is the same as before.
- **I-2: the TAB allowance in sku_name is the right call.**
  - The audit lines never log `sku_name`. A TAB cannot split a line. Rejecting it would 422 every OMS edit of the 208 prd products with a TAB in the name.
  - The OMS `trim()`s `product_name` (`buildSkuDataFromProduct`), so only inner TABs arrive.
  - Keep it, and keep the C6c pins.
- **I-3: the one-rename 103 cannot be reached from the OMS.**
  - `updateSku` sends one DTO per call (`WmsApiService.php:1345-1364`, called per facility from `updateSkuFromProduct`).
  - `createSkuBatch` never carries `previous_sku`, and create does not count renames anyway.
  - The cap also counts an idempotent retry (`previous_sku ≠ sku` with the row already at sku) as a rename. That over-count is harmless.
- **I-4 (point 3): the double-stale residual.** It is real, and M1 covers it. "Including previous_sku in the uncached re-check" does close it cheaply without breaking D-M3. The cleanest place for it is §3.2 step 2 itself (M1 fix).
- **I-5 (point 4): gate-test edits.**
  - The D-M3 edits are exactly the two declared:
    - AC-2a was rewritten as `update_byFacilityItemIdWithPreviousSkuMatchingRow_renames`;
    - in `viaCases`, `(X,null,"A",…,true)` and `(null,null,"B",…,true)` were removed, and `(null,"A",previous_sku)` was added.
  - Other AC-tagged tests were edited too, all disclosed in the fix log and none weakening:
    - AC-4d: the probe is narrowed to `pg_blocking_pids(pid) @> ARRAY[rawPid]`, and `shutdownNow` moved into an outer finally;
    - AC-10a: the same four assertions, reordered;
    - the shape test gained an assertion;
    - the AC-12 fixtures gained a 23505 cause.
  - Of these, the AC-12 change exists only because of the unsanctioned L3 behaviour change. It is acceptable once L3 is ratified.
  - The real gate-test problem is the silent path change in L2, not an edit.
- **I-6 (point 5): the cross-repo contract matches.**
  - The 108 text is `"sku rename precondition failed: item_id=X is C, expected P"`, and the IT pins it exactly.
  - The OMS regex (`WmsApiService.php`, `resendReloadedUpdate`) is:
    `'/^'.preg_quote(marker).': item_id=(\d+) is (.+), expected '.preg_quote($sentPreviousSku).'$/s'`
  - **Can `"expected previous_sku (none sent)"` reach that parser?** No.
    - The parser runs only when `isset($facilityData['facility_item_id'])` (:1675).
    - Whenever the id is set, the OMS sets `previous_sku = $previousSku ?? $sku` (:1667), where `$sku = trim(product_sku)`.
    - An empty `$sku` is rejected by wms2 first, with FIELD_NOT_SET for sku, before any 108.
    - The resend always sends `previous_sku = $wmsItemNr` (non-empty, edge-whitespace-free) or `$sentPreviousSku` (:1810).
  - **If it ever did reach the parser**, two things could happen:
    1. With the type intact, the anchor `expected <sent>` fails, so `resync-skipped-bad-map` is logged with reason `unparseable description`. That is fail-closed and nothing is written.
    2. With `$sentPreviousSku` null, `resendReloadedUpdate(…, string $sentPreviousSku, …)` would throw `TypeError` instead of skipping. Only an OMS that sends an id without previous_sku could cause that, and none does.
  - Nit on the OMS side: the `unparseable description` reason is logged under the `bad-map` token. Not this repo.

## Positive observations

- The via is now *recorded* at the lookup site instead of being re-derived. That removes a whole class of log/decision drift. The `previous_sku == sku` → `sku` step reasoning (same cache key) is correct and documented in the javadoc.
- `translate()` arguments stay fixed per site, and the comment explains why a re-query after a failed statement is forbidden. The 23505 detection checks both the SQLState and the constraint name, with mutants for each arm.
- The control-character error never echoes the offending value. The TAB deviation is backed by measured prd counts on all four tenant DBs, not by assumption.
- The delete CAS was hoisted so that it covers both lookup paths. The fallback is now uncached.
- The test hygiene is strong:
  - every new assertion has a named mutant;
  - a positive control backs the message-row cleanup;
  - the pid-specific lock probe removes cross-worktree false greens;
  - the intermediate commit was built on its own.

## Recommendation

**COMMENT.** Nothing blocks at HIGH confidence. Before the PR:
1. **M1:** make step 2 uncached, with one IT and one mutant. It is about 1 production line.
2. **L2:** fix the fixture.
3. **L3:** get the plan amendment acknowledged by Nam.

L1 and L4–L6 can go in the same pass, per the "address Lows" rule.
