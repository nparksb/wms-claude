---
title: "SKU rename in place: OMS→WMS sync resolves by per-facility id, then previous SKU, then SKU; renames itemdata and stockrecord in one tx"
ticket: "SBDEV-2624"
ticket_url: "https://app.clickup.com/t/868keq71z"
type: "feature"
priority: ""
status: "pending approval (consensus: Critic APPROVE r3)"
tier: T3
repos: [wms2-api, oms-laravel-api]
project: ["wms2"]
version: "v2"
target_version: v2
requester: "Nam Park"
created: "2026-10-02"
updated: "2026-10-02"
revision: "r4 — final fold-in of round 3 (critic r3 APPROVE with 12 Minor; architect r3 REVISE-light: R1 Medium, R2–R3 Low, R4 Info). No redesign. Logs r1→r2, r2→r3, r3→r4 in §R."
db_verified: true
db_verified_note: "Read-only, 2026-10-02. wsl-wineco-prd: indexes, EXPLAIN of the rewrite predicate, hot-code row count, create-on-update fingerprint, 30-day pair-join check. nywh-hydra-prd, wh01_shipitez_v2, wh02_shipitez_v2: uk3l3dgof3l6mc1dl7s3lmida65 + stockrecord index set. Architect r1 added (WineCo prd): 8 non-deferrable FKs on itemdata, 5,011 stockrecord rows/day, max 201/day per SKU, 0 user triggers. UAT not checked (MCPs down)."
base_commit: "wms2-api 62c92dd5 (origin/develop); oms-laravel-api dad34d7e (origin/develop; no change since 55f5f93c to any file this plan touches, per critic r1)"
branches:
  wms2-api: "feature/SBDEV-2624-sku-rename-in-place (off origin/develop)"
  oms-laravel-api: "feature/SBDEV-2624-facility-item-id (off origin/develop)"
related:
  - "[[SBDEV-2024]]"            # parent
  - "[[SBDEV-2025]]"            # spike, folded into this plan
  - "[[SBDEV-2623]]"            # v1 twin, CLOSED 2026-10-02: no client on wms v1
  - "[[260610-wms2-sku-trim-normalization]]"   # archived; its §10 deferred this work
  - "[[SBDEV-3135]]"            # finally-eviction on all /rest/sku handlers
  - "[[SBDEV-2681]]"            # product_wms_item existence map
  - "[[SBDEV-2624-evidence/analysis]]"
tags:
  - plan
---

# SBDEV-2624 — SKU rename in the OMS creates a second WMS item instead of renaming the first

**Tier:** T3 (data integrity on prd, two repos, a historical-table rewrite) · **Mode:** ralplan DELIBERATE, round 2
**Evidence:** `SBDEV-2624-evidence/analysis.md` ("bundle §N"), `review-r1-architect.md` ("A-"), `review-r1-critic.md` ("K-").

---

## 0. Affected sites

**Method:** the bundle §0 sweep, re-run at `base_commit`, plus the producers named by A-M2 and K-#3/#4. To find every OMS writer of a duplicate, I enumerated the callers of `buildSkuPayload` (`git grep -n "buildSkuPayload("`, 4 hits) and every reader of `product.wms_item_id` (`git grep -n "wms_item_id"` over OMS `app/`, 7 files).

| # | Site | Scope | Phase |
|---|---|---|---|
| W1 | `SkuRestController.create` | **IN**: 200 + `item_ids`; uncached re-check before insert (A-L4) | P1 |
| W2 | `SkuRestController.update` — the defect site | **IN**: resolve id → previous_sku → sku; 200 + `item_ids` | P1 |
| W3 | `SkuRestController.delete` | **IN** (Q4, A-M3): client-scoped id, compare-and-set on `sku` | P1 |
| W4 | `SkuBatchCreateUpdateService.upsertAll` | **IN**: CAS, collision, ordered rewrite, translations, return ids | P1 |
| W5/W6 | `ItemdataService.findByClientIdAndItemNr` / `getById` (`@Cacheable`) | OUT (unchanged; cross-replica = G4) | — |
| W7 | `evictItemdataCache()` in `finally` (SBDEV-3135) | **IN, kept as is** | P1 |
| W8 | `SkuDto` | **IN**: + `facility_item_id`, `previous_sku` | P1 |
| W9 | `Itemdata.setItemNr` (`itemNr.trim()`) | OUT | — |
| W10 | `StockrecordRepository` (type-level `exported = false`) | **IN**: `renameItemdataForClient` | P1 |
| W10b | `ItemdataRepository` | **IN**: `findByIdAndClientId`, `@RestResource(exported = false)` | P1 |
| W10c | `WmsConstants` | **IN**: `SKU_RENAME_PRECONDITION_FAILED = 108` and `SKU_CONCURRENT_MODIFICATION = 109` (free: the 100 group ends at `CHILD_NOT_PART_OF_PARENT = 107;`, next is 200; `git grep -nE "= 10[89];"` 0 hits), each with arms in `getErrorCodeText` **and** `getErrorCodeName` | P1 |
| W11 | Inbound (client, code) lookups (Advice, StockCount, TransactionReport, Receiving, Replenish, ReturnAdviceAutoReceive, MobileReplenish, FileImport, StockrecordService) | OUT — G3 | — |
| W12 | `findByItemNr` lookups ignoring the client | OUT, pre-existing | — |
| W13 | `OrderRestController` → `findByClientNumberAndSkuSet` (uncached) | OUT | — |
| W14 | SDR `PATCH /v3/itemdata/{id}` (A-L7) | OUT — **already closed**: `Itemdata.class` is in `SDR_WRITE_WITHDRAWN` (`RestConfiguration.java`, the array opens `private static final Class<?>[] SDR_WRITE_WITHDRAWN = {` and its loop calls `httpMethods.disable(WRITE_VERBS)` with `WRITE_VERBS = {POST, PUT, PATCH, DELETE}`), pinned by `SdrWriteWithdrawalContextTest` (`"Itemdata"`). The `disable(PUT, DELETE)` lists are for Client and Cyclecount, not Itemdata | — |
| O1 | `WmsApiService::updateSkuFromProduct` | **IN**: `(Product, ?string $previousSku = null)`; per-facility fields; record ids | P2 |
| O2 | `buildSkuDataFromProduct` (`$data['item_id'] = (int) $product->wms_item_id;`) | **IN**: delete | P2 |
| O3 | `buildSkuPayload` | **IN**: per-facility `facility_item_id`/`previous_sku`; `request_nonce` defaults to a fresh UUID (A-L2) | P2 |
| O4 | `getAllWmsFacilities` | OUT (a full miss still creates — AC-5) | — |
| O5 | `createSkuFromProduct` | **IN**: exact-key id read (A-L3); stop writing global `product.wms_item_id` | P2 |
| O6 | `deleteSkuFromProduct` / `deleteSku` | **IN**: per-facility `facility_item_id` + `request_nonce` in its own payload (K-#15) | P2 |
| O7 | `createSkuBatch` (K-#3). `git grep -n "buildSkuPayload("` = 4 hits: 3 callers (`createSku` :1273, `updateSku` :1350, `createSkuBatch` :4136) + the definition (:1770) | **IN**: nonce per call via the O3 default | P2 |
| C1 | `ProductController` (`$previousIdentity = [` inside the tx closure, read back as `$newlyResolvableAliases['previous_identity']`) | **IN**: previous SKU when that array's `client_id` `=== (int) $product->client_id` (both int: `$sourceClientId = (int) $product->client_id;`) and the SKU changed | P2 |
| C2 | `LegacyV2ProductController` (`->fresh()` copy) | **IN**: capture `$product->product_sku` before `productRepository->update` | P2 |
| C3 | `V1ServicesRestController` (cannot rename) | **IN**, test only | P2 |
| P1 | `ProductWmsItem::recordSeen` | **IN**: NULL never overwrites an id | P2 |
| P2 | `WmsFacilitySyncService` — **two entry points that prune** (K-r2 #1): (a) `reconcileSkus` → `pruneStale` (:283), reached only via `SyncFacilityToWmsJob` from `FacilityWmsSyncController` (operator); (b) `backfillFacilityItemMap` (:997) → `pruneStale` (:1045) **unconditionally, no dry-run gate**, reached via `BackfillFacilityWmsItemsCommand` (`wms:backfill-facility-items`, manual) and `BackfillFacilityWmsItemsJob` (dispatched only by tenant migration `2026_07_23_100001_backfill_product_wms_item_map`, i.e. once per migrate) | **IN**: code-drift keep + report at **both** (AC-15, AC-15b) | P2 |
| R1 | Global `product.wms_item_id` readers/writers (K-#4, K-r2 #7). Readers: `LegacyWmsController` (`Product::where('wms_item_id', $update['item_id'])->where('client_id', …)`), `LegacyProductUpdateService::findProduct` (`->where('wms_item_id', $wmsItemId)`), `LegacyInventoryAdjustService::applyInventoryQuantities` (`Product::where('wms_item_id', $itemId)->first()` — **no client filter**). Writers: those three backfills, `createSkuFromProduct` (O5), and **`WmsFacilitySyncService::backfillWmsItemIds`** (`$product->wms_item_id = (int) $itemNrToId[$sku];`) | **IN** (folded, §10): ignore inbound `item_id`, resolve by client + SKU; delete every global write; delete the dead `if ($clientCode === null) { // only reachable on the wms_item_id path` branch | P2 |

---

## 1. Problem

Rename A→B for client c at facility F, where (c, A) exists (bundle §1):

1. The OMS posts `[{sku: B, item_id: <first facility's id>, facility_code: F}]`.
2. wms2 drops `item_id` (`mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);`).
3. `update` looks up the new code (`itemdataService.findByClientIdAndItemNr(client.getId(), sku.getSku())`), misses, and `upsertAll` creates (`if (existing == null) { Itemdata itemData = new Itemdata(); itemData.setItemNr(sku.getSku());`).
4. (c, A) keeps the stock, orders and putaway settings; (c, B) is an empty twin.

The return leg is broken too. wms2 answers 204 (no body on the wire), so `createSkuFromProduct`'s `if (!empty($responseData['item_ids']))` never fires, and `recordSeen` writes `wms_item_id => null` over any stored id.

---

## 2. Current architecture and DB evidence

### 2.1 Code path (origin/develop 62c92dd5)

- **Controller (no tx):** resolves the client, fills `existingByClient.get(client.getId()).put(sku.getSku(), itemdata)` from the cached lookup, calls `upsertAll`, and runs `finally { evictItemdataCache(); }`.
- **`upsertAll`:** `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`, returns `void`, and never touches `itemNr` on update.
- **Errors:**
  - A `WebserviceBusinessExceptionClientSide` becomes a 422 from create/update (a 400 from delete), with `{status: "failure", description}`.
  - `NOT_UNIQUE_VALUE = 105` renders `"duplicate value %1s found in %2s"`; `%1s` is width-1, not positional.
  - `Itemdata extends AbstractBaseEntity`, which carries `@Version`.
- **OMS:**
  - `processWmsResponse` maps a JSON 2xx to `'data' => $responseData['data'] ?? $responseData`, so a top-level `item_ids` reaches `createSkuFromProduct`.
  - **No 5xx or 4xx is retried** (A-H1, K-#2): `if (!$response->successful()) { throw WmsException::fromHttpStatus(...) }`. The loop catches only `ConnectionException` and `RequestException`.
  - A timeout is retried, but while the first attempt is still running the retry meets `IdempotencyFilter`'s `409 idempotency-in-flight`.
- **Idempotency (F-1, confirmed by both reviewers):** keys are `SHA-256(method|path|body)`, retained 7 days, and only 2xx responses are replayed. The OMS sends no `Idempotency-Key`. So a rename A→B→A→B within 7 days replays the first response and the third edit is silently dropped.

### 2.2 DB evidence (read-only, 2026-10-02)

| Fact | Instrument | Result |
|---|---|---|
| `UNIQUE (client_id, item_nr)` live, plain (A-H2) | `pg_indexes`, 4 prd tenants | `uk3l3dgof3l6mc1dl7s3lmida65` on all 4. 260610 §3 ("no unique index") is false |
| FKs to itemdata (A-H2) | `pg_constraint`, WineCo prd | 8, none deferrable: stockunit, customerorder_position, pickingorder_position, adviceposition, replenishorder, cyclecount_position, billoflading_position, fix_location_assignment |
| stockrecord indexes | `pg_indexes`, 4 prd tenants | 14 each, identical; `index_stockrecord_itemdata (lower((itemdata)::text))`, `index_stockrecord_client_id`; none on (client_id, itemdata) |
| stockrecord size / write rate | count, `pg_total_relation_size`; A-r1 | WineCo prd **7,499,593 rows, 2,936 MB**; 5,011 rows/day, max 201/day per SKU |
| Worst-case rewrite | `pg_stats` MCV → exact count | `'WCI PC'` (client 146701): **44,251 rows** |
| Index used | `EXPLAIN SELECT id FROM stockrecord WHERE lower(itemdata) = lower('WCI PC'::varchar) AND itemdata = 'WCI PC'::varchar AND client_id = 146701::bigint` | Bitmap Index Scan on `index_stockrecord_itemdata` ∧ `index_stockrecord_client_id`, cost **10,817**; without `lower()`: 662,727-row client scan, cost **222,033** |
| `EXPLAIN UPDATE` | MCP | refused; M-5 covers it on UAT |
| Pair join lossless | stockrecord rows from the last 30 days with no `(client_id, item_nr)` match, WineCo prd | **0** (Hydra all-time 0 of 4,237) |
| Create-on-update rows | itemdata created ±1 min of a `SKU_UPDATE` whose payload has `"sku":"<item_nr>"`, with no `SKU_IMPORT` | **264** (Nam: 270, different window). By year 2019–2024: 4/55/131/24/9/41; 2025–26: 0 (v2 cutover was 2026-09-26) |
| Rename signature | of those, an older same-client item with the same `lower(trim(name))` | **13** (reproduces Nam's 13) |
| Duplicate candidates | bundle §3 query | 78 Hydra / 323 WineCo (upper bound) |

### 2.3 Blast radius (bundle §2)

**Safe (by id):** the 8 FK tables, `putawaylocation_id`, 10 views. **Stale (text):** `stockrecord.itemdata` — fixed here; feeds `stock_history()`, `transaction_detail()`, `transaction_summary()`, `stockrecord_view` — plus `inventory_record` and message/outbox/idempotency payloads (G1, G2). **Inbound by code (W11):** G3.

---

## 3. Design

### 3.1 Contract (additive)

| Field | Dir | Rule |
|---|---|---|
| `facility_item_id` (Long, optional) | OMS→WMS | `product_wms_item.wms_item_id` for (product, **this** facility). Omitted when NULL or ambiguous. A new name, so today's global `item_id` is never honoured (C1) |
| `previous_sku` (String, optional) | OMS→WMS, update + delete | The SKU before this edit. Sent only when it differs (trimmed) **and** the client did not change (Q2). Trimmed by `normalize()` |
| `request_nonce` (String) | OMS→WMS | A fresh UUID per logical sync call, the same across `makeWmsRequest` retries. wms2 ignores it (unknown field) |
| `item_id` | — | **Removed** from every OMS SKU payload |
| `item_ids` `{ "<sku>": <id> }` | WMS→OMS | In the 200 body of create **and** update (the PR #14 shape) |

### 3.2 Resolution (controller, per DTO, client resolved)

```
1. facility_item_id → itemdataRepository.findByIdAndClientId(id, clientId)        // uncached; other client = miss
2. miss && previous_sku → itemdataService.findByClientIdAndItemNr(clientId, previous_sku)
3. miss → itemdataService.findByClientIdAndItemNr(clientId, sku)
4. miss → create
```

**C4 re-key:** the found row goes in as `existingByClient.get(clientId).put(sku.getSku(), found)`. The inner key stays the request `sku`, so `upsertAll`'s `.get(sku.getSku())` is unchanged; the value is whichever row the steps found. The controller records which step hit (`via`) on a side map, for logging only.

### 3.3 `upsertAll` (one tenant tx; returns `Map<String, Long>` sku → id, insertion-ordered)

**Create branch (`existing == null`), A-L4:**
- Re-check `itemdataRepository.findByClientIdAndItemNr(clientId, sku)`, direct and uncached.
- If a row is found: on the **update** endpoint, use the update branch on it (today's update-by-code semantics, reached because another replica's cache held a miss); on the **create** endpoint, throw `ENTITY_ALREADY_EXITS` exactly like the handler's own pre-check (K-r3 open Q2: a create must never silently take over an existing item). `upsertAll` gains a `boolean failIfExists` parameter (create passes true). Otherwise insert with **`Itemdata saved = itemdataRepository.saveAndFlush(itemData); ids.put(sku, saved.getId());`**, inside the translation wrapper. Two traps: (i) plain `save` defers the INSERT to commit, past the wrapper, because the id is `@GeneratedValue(strategy = GenerationType.SEQUENCE…)` (A-r2 N1); (ii) the create sets `itemData.setVersion(1)` on a wrapper-typed `@Version Integer`, so Spring Data's `isNew` is false and `saveAndFlush` **merges a copy**. `itemData.getId()` stays null and only the returned `saved` has the id (A-r3 R1; AC-5b).

**Update branch:**
1. **Reload:** `row = itemdataRepository.findById(existing.getId())`. If gone → create branch. The cached detached entity is never trusted for the rename decision.
2. **Rename needed?** `!row.getItemNr().equals(sku)` (case-sensitive). If not, go to step 5.
3. **CAS precondition (A-H1):** if `previous_sku != null` and `row.itemNr ∉ {previous_sku, sku}`:
   - throw `WebserviceBusinessExceptionClientSide(SKU_RENAME_PRECONDITION_FAILED, null, "item_id=" + X + " is " + row.itemNr, "expected " + previous_sku)` → 422. Text arm: `"sku rename precondition failed: %1s, %2s"`; the leading phrase is the OMS resend marker (§3.5).
   - `LOG.warn("SBDEV-2624 SKU_RENAME_PRECONDITION …")`.

   When `previous_sku` is absent (a plain edit that found the row by id), the rename proceeds. That is the recovery path for an earlier failed rename. It logs `LOG.warn("SBDEV-2624 SKU_RENAME_BY_ID_RECOVERY …")`.
4. **Rename, strictly in this order (A-H2):**
   - **a. Collision (D2):** `itemdataRepository.findByClientIdAndItemNr(clientId, sku)`, direct. A different id Y → `NOT_UNIQUE_VALUE` with `"sku " + B + " (item_id=" + Y + ")"`, `"rename of item_id=" + X + " from " + old` → 422; `LOG.warn("SBDEV-2624 SKU_RENAME_COLLISION …")`.
   - **b. Native rewrite:** `n = stockrecordRepository.renameItemdataForClient(clientId, old, sku)` (§3.4).
     - **No entity mutation may precede it.** Hibernate auto-flushes dirty entities before a native query, which would issue the itemdata UPDATE early and take FOR UPDATE.
     - FOR UPDATE is what an UPDATE changing a column of a plain unique key takes, and it conflicts with the FOR KEY SHARE that every FK check on the 8 child tables takes.
   - **c. Then** `row.setItemNr(sku)` plus every field setter (step 5).
   - **d. Last:** `itemdataRepository.saveAndFlush(row)`. The itemdata FOR UPDATE lock is held only from here to commit, i.e. milliseconds, not the rewrite's seconds.
   - **e.** `LOG.info("SBDEV-2624 SKU_RENAME clientId={} itemId={} from={} to={} via={} stockrecordRows={}")`, then **straight to `ids.put(sku, row.getId())`**. The rename path calls `saveAndFlush` exactly once (4d); step 5 is only the tail of the non-rename path (A-r3 R3).
5. **Non-rename path only:** field setters, then **`saveAndFlush`** (not `save`) inside the wrapper, so a version loser on a plain update surfaces here too (N1); then `ids.put(sku, row.getId())`. `row` is managed, so merge returns the same instance and `row.getId()` is correct.

**Translations (A-L1, A-H2, N1), wrapped around every write: steps 4b–4d, the create `saveAndFlush`, the step-5 `saveAndFlush`.** Because every write is flushed inside the wrapper and no constraint is deferrable (8 FKs non-deferrable, plain unique — §2.2), commit cannot raise anything new; this is chosen over a controller-level catch so the error text can name X and Y:

| Exception | Becomes |
|---|---|
| `DataIntegrityViolationException` | 105, with **fixed** arguments, because the PG tx is aborted and the wrapper **never re-queries** (K-r3 #3, A-r3 R3): on the rename flush `"sku " + B + " (concurrent insert)"`, `"rename of item_id=" + X + " from " + old`; on the create flush `"sku " + B`, `"create"`. Only the step-4a collision check (no failed statement yet) names Y |
| `PessimisticLockingFailureException` (55P03, the 5 s lock wait) | 422, code **109**, text `"sku concurrent modification: item_id=X, retry"` |
| `ObjectOptimisticLockingFailureException` | 422, code **109**, same text |

**Why 109 replaces today's 503 for lock waits (K-r3 #2).** On base, `CannotAcquireLockException` and `DeadlockLoserDataAccessException` (both `PessimisticLockingFailureException`) escape the handler and hit `RestEndpointExceptionHandler` (`@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")`): `retryable503(...)` with `Retry-After: 30`. Only the optimistic loss falls to the `@ExceptionHandler(Exception.class)` 500. The OMS honours neither: in `makeWmsRequest` a non-2xx goes to `WmsException::fromHttpStatus` and only `ConnectionException`/`RequestException` loop, so a 503 is never retried and `Retry-After` is ignored. 109 is therefore **strictly better for this caller**: it reaches `updateSku`'s catch like any 4xx, and when the facility id is known it triggers the one reloaded resend (§3.5), which is the retry the 503 only advertised. The change is scoped to `/rest/sku` create/update (the wrapper is in `upsertAll`); every other `/rest` endpoint keeps the 503 contract. A future caller that wants `Retry-After` can still key off 109.

The tx is rollback-only by then and the checked exception rolls it back. An optimistic loser is detected after its rewrite, so that work is discarded. That is the accepted cost of H2.

A case-only rename (`abc`→`ABC`) is a rename (the constraint and lookups are case-sensitive).

### 3.4 stockrecord rewrite (Q1)

```java
// SBDEV-2624 Q1. lower(itemdata) = lower(:old) lets index_stockrecord_itemdata (lower((itemdata)::text))
// serve this on WineCo (7.5M rows); the exact conjunct keeps a case-only rename off other-case rows.
// Without lower() the planner reads the client's whole history (EXPLAIN 2026-10-02: 222k vs 10.8k).
// Has no tx of its own: it JOINS upsertAll's tenant tx; called outside one it throws TransactionRequiredException.
@Modifying
@Query(value = "UPDATE stockrecord SET itemdata = :newItemNr " +
               "WHERE lower(itemdata) = lower(:oldItemNr) AND itemdata = :oldItemNr " +
               "AND client_id = :clientId", nativeQuery = true)
int renameItemdataForClient(@Param("clientId") Long clientId,
                            @Param("oldItemNr") String oldItemNr,
                            @Param("newItemNr") String newItemNr);
```

**Index-use proof, three instruments:**
1. **Done (§2.2):** prd EXPLAIN of the SELECT twin.
2. **M-5, pre-merge:** WineCo UAT, writable session:

   ```
   BEGIN; SET LOCAL plan_cache_mode = force_generic_plan;
   PREPARE r(bigint,varchar,varchar) AS <exact @Query string>;
   EXPLAIN EXECUTE r(…);
   EXPLAIN (ANALYZE, BUFFERS) EXECUTE r(146701,'WCI PC','x');
   ROLLBACK;
   ```

   Record the UAT row count for that code beside the timing and scale it to prd's 44,251 (A-L5).
3. **CI:** `StockrecordRenameQueryShapeUnitTest` pins the predicate text.

**Cost and gate:**
- `git grep -niE "update\s+stockrecord"` over `src/main` and `db/migration` finds no other UPDATE, so row-lock contention is limited to a concurrent rename of the same code.
- After H2, the long statement holds no lock that a child-table insert needs.
- **Gate:** scaled prd time < 10 s.
- **If it fails (K-#10):** do not merge. Propose a T3 ticket for a `(client_id, lower(itemdata))` index (Flyway). A chunked rewrite is rejected because it breaks Q1's single tx.

### 3.5 OMS side

- **Signature:** `updateSkuFromProduct(Product $product, ?string $previousSku = null)`.
  - **C1** passes `$newlyResolvableAliases['previous_identity']['product_sku']` only if its `client_id` `=== (int) $product->client_id`. Values, not `wasChanged()`, because the closure can save more than once (K-#15); the bare `$previousIdentity` is out of scope at the call site (K-r2 #9).
  - **C2** captures `$oldSku = $product->product_sku;` before `$this->productRepository->update(...)`.
  - **C3** is unchanged.
- **Per-facility fields:**
  - Load the map once per call: `ProductWmsItem::where('product_id', $id)->pluck('wms_item_id', 'facility_code')`.
  - Add `facility_item_id` only if the value is non-null and `ProductWmsItem::where('facility_code', $f)->where('wms_item_id', $id)->count() === 1`. This uses `idx_product_wms_item_facility (facility_code)`, then filters on `wms_item_id`; it is not fully indexed, which is acceptable at per-facility catalogue size (K-#13).
- **Record ids:**
  - After a successful create **or** update: `recordSeen($facility, [['product_id' => …, 'wms_item_id' => $responseData['item_ids'][$sku] ?? null]])`. Exact trimmed-SKU key; never `reset()` (A-L3).
  - On a failed update that carried `previous_sku`: `Log::warning('SBDEV-2624 rename-not-acknowledged', [facility, product_id, previous_sku, sku, status])`, so the operator sees G7 (K-#2; AC-7e).
- **One reloaded resend on 108/109 (A-r2 N2), with a bad-map guard (K-r3 #1, adopted):**
  - **Detect:** `updateSku` already catches `\Exception`. When it is a `WmsException` whose `getTechnicalDetails()` (`"HTTP {$statusCode}: {$rawResponse}"`) contains `'"description":"' . $marker` for a marker in the class constant **`WmsApiService::WMS_RESYNC_MARKERS = ['sku rename precondition failed', 'sku concurrent modification']`** (anchored on the JSON key per A-r3 R4; Jackson writes no space), it returns `'reason' => 'resync'` plus the description.
  - **Bad-map guard (108 only):** parse `/item_id=(\d+) is (.+?), expected /` from the description, giving D, the code the WMS row actually holds. **Skip the resend** if `Product::active()->where('client_id', $product->client_id)->where('product_sku', $D)->where('product_id', '!=', $product->product_id)->exists()`. Then X is another live product's item and the map row is wrong; renaming it would be the S1 corruption. Log `SBDEV-2624 resync-skipped-bad-map` with X and D. Also skip if the regex fails (fail closed).
  - **Resend:** otherwise, **once per facility and only if that facility's `facility_item_id` was sent**: `$fresh = Product::find($product->product_id)` (a DB reload, never the request copy); rebuild with `sku = trim($fresh->product_sku)`, **no** `previous_sku`, the same `facility_item_id`, a new nonce; log `SBDEV-2624 resync-resend` with X, D and the target SKU; send. A failure of the resend is logged, never resent.
  - **Outcome:** in the H1 race the row is already at the current SKU, so it is a plain update; in the stuck case (WMS A, OMS now C) it renames A→C via id recovery. With no id: no resend, since a plain update without an id would create a twin (G7).
- **`recordSeen` NULL guard (C5):** rows with a numeric id are upserted on `['wms_item_id','last_seen_at']`; NULL-id rows on `['last_seen_at']` only.
- **Delete (Q4, A-M3):** `deleteSku($facility, $clientCode, $sku, ?int $facilityItemId = null)`; `deleteSkuFromProduct` passes **this facility's** map id (ambiguity guard applies), replacing today's global `$product->wms_item_id ? (int) $product->wms_item_id : null` (AC-8h). The payload carries `facility_item_id` and `request_nonce`, never `item_id`. Neither delete caller reads `results`, so `deleteSkuFromProduct` logs `Log::warning('SBDEV-2624 delete-not-acknowledged', …)` per failed facility (A-r2 N6); wms2 logs `SKU_DELETE_PRECONDITION` on the CAS 400.
- **Global column:**
  - `createSkuFromProduct` stops writing `product.wms_item_id`.
  - The three R1 readers stop consulting it and resolve by client + SKU, the path they already fall back to.
  - Every global write is deleted: the R1 backfills (`$product->wms_item_id = (int) $update['item_id'];`, `$product->wms_item_id = (int) $itemId;`) and `backfillWmsItemIds`'s `$product->wms_item_id = (int) $itemNrToId[$sku];` (its `recordSeen` per-facility half stays).
  - The column stays with no reader and no writer. **P2 acceptance grep (K-r3 #5)** targets the global-column forms only: `git grep -nE "Product::where\('wms_item_id'|table\('product'\)[^;]*wms_item_id|\$product->wms_item_id" -- app/` must return **0**, **and** `git grep -n wms_item_id -- app/Services/Legacy/ app/Http/Controllers/Api/Legacy/` must return **0** (that second grep covers the multi-line `->table('product') … ->where('wms_item_id', $wmsItemId)` in `LegacyProductUpdateService`, which the line-mode first grep misses; base: 13 hits for the first, 13 for the second) (`ProductWmsItem` column uses such as `pluck('wms_item_id', …)` are correct and not matched). Positive control: the same grep on base returns the R1/O2/O5/O6 hits. A-r2 found nothing in siteboss-frontend `origin/main`.
  - Update the `backfillWmsItemIds` docblock, which still describes the global backfill (A-r3 §C).
  - Behaviour change: an inbound message with `item_id` but no client number now returns `Client identifier is required to resolve SKU …` FAILURE (it previously resolved globally). wms2 sends no `item_id` (§10), so nothing hits this today.
- **Facility sync drift (A-M2, K-#3):**
  - In `reconcileSkus`, per chunk, load `ProductWmsItem::where('facility_code',$f)->whereIn('product_id',$ids)->pluck('wms_item_id','product_id')`, and invert `$wmsItemNrByClientId[$wmsClientId]` to id → itemNr.
  - When `!isset($existingItemNrs[$sku])` but the product's stored id is a WMS id of the same client under a different code:
    - append `['product_id','sku','wms_item_nr','wms_item_id']` to a new `code_drift` report list;
    - add it to `$this->observedFacilityItems` with that id, so `pruneStale` (`where('last_seen_at', '<', $seenBefore)`) keeps the row;
    - do **not** add it to `$missingByClientCode`.
  - **`backfillFacilityItemMap` (K-r2 #1):** its `$observed` builder gets the identical rule — a product whose stored per-facility id is a WMS id of the same client under a different code is added to `$observed` **with that id** (so the unconditional `pruneStale` at :1045 keeps it), and counted. Rows whose `itemdata_list` entry has no id (`$row['id'] ?? true`) cannot be inverted, so they are counted as `id_missing` rather than silently pruned (K-r3 #12). An A code that is still another product's current SKU puts X in `$observed` twice; the ambiguity guard then suppresses `facility_item_id` for both, which is acceptable (A-r3 §C). The method's return array gains `'code_drift' => [...]` and `'id_missing' => n`, and both callers log the counts: `BackfillFacilityWmsItemsCommand` prints it, `BackfillFacilityWmsItemsJob` logs `SBDEV-2624 backfill code_drift` (AC-15b, mutant #12).
  - **Side effect, accepted (A-r2 N7, K-r2 #10):** a kept drift row tells `presentAtFacility` (behind `config('wms.facility_sku_checks')`, default off) that B exists at F while the WMS holds A. B's orders then fail loudly at WMS import until the rename heals — better than an empty twin, and listed in S3.
  - Healing is the next ordinary product edit, which takes the id-recovery path in §3.3 step 3. The sync itself only reports.
  - **Triggers:** reconcile is operator-only (`SyncFacilityToWmsJob::dispatch` only in `FacilityWmsSyncController`); the backfill is the manual command plus the one-shot migration dispatch (`git grep -ln BackfillFacilityWmsItemsJob` = the job file + `2026_07_23_100001_backfill_product_wms_item_map.php`). No schedule in `routes/`, `app/Console`, `bootstrap/` (positive control: the grep finds those dispatches).

### 3.6 F-1 replay guard

- `buildSkuPayload(string $facility, array $data, ?string $nonce = null)` sets `'request_nonce' => $nonce ?? (string) Str::uuid()`.
- **Threading (K-r2 #9):** no signature change on `createSku`/`updateSku`. Each `*FromProduct` method generates one `$nonce` per call; inside its facility loop it builds `$facilityData = $skuData + ['request_nonce' => $nonce]`, plus `facility_item_id` / `previous_sku` when they apply to that facility, and passes `$facilityData` as `$skuData`. `buildSkuPayload` keeps keys already present and only adds `request_nonce` when it is absent.
- `createSkuBatch` gets a fresh one per call through the default (A-L2).
- `deleteSku` sets it in its own payload.
- **Why the body, not an `Idempotency-Key` header:** under `app.idempotency.bridge-mode=true`, `tryClaim` matches on the body hash and ignores the key, so only a body field survives a future bridge window (A-r1 §5, K-r1).

---

## 4. File change summary

| Repo | File | Change |
|---|---|---|
| wms2-api | `json/SkuDto.java` | + `facility_item_id`, `previous_sku` |
| wms2-api | `controller/rest/SkuRestController.java` | `normalize()` trims `previousSku`; §3.2; 200 + `item_ids`; message-log status `OK`; delete CAS |
| wms2-api | `service/SkuBatchCreateUpdateService.java` | §3.3; inject `StockrecordRepository` |
| wms2-api | `service/WmsConstants.java` | + 108, 109, each with both arms |
| wms2-api | `repo/jpa/ItemdataRepository.java`, `repo/jpa/StockrecordRepository.java` | §0 W10, W10b |
| oms-laravel-api | `app/Services/WmsApiService.php` | §3.5, §3.6 |
| oms-laravel-api | `app/Models/ProductWmsItem.php` | NULL guard |
| oms-laravel-api | `app/Services/WmsFacilitySyncService.php`, `Console/Commands/BackfillFacilityWmsItemsCommand.php`, `Jobs/BackfillFacilityWmsItemsJob.php` | code-drift keep/report in reconcile **and** backfill; drop `backfillWmsItemIds`'s global write; log the drift count |
| oms-laravel-api | `Api/ProductController.php`, `Api/Legacy/LegacyV2ProductController.php` | previous SKU |
| oms-laravel-api | `Api/Legacy/LegacyWmsController.php`, `Services/Legacy/LegacyProductUpdateService.php`, `Services/Legacy/LegacyInventoryAdjustService.php` | R1: ignore inbound `item_id`, drop the global backfill |

No Flyway, no OMS migration, no sysprop, no gate change.

---

## 5. Phased plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | Confirm `uk3l3dgof3l6mc1dl7s3lmida65` and `index_stockrecord_itemdata` on dev + UAT | executor | Prd done (§2.2) |
| 2 | Feature flags | N/A — the new fields are the switch | — | |
| 3 | Config / env | N/A | — | |
| 4 | Deploy order | **wms2-api FIRST, required (A-L6).** OMS deploys only after `/api/public/version` returns the new SHA on ≥10 consecutive polls (replicas sit behind the LB) | Nam | §5.3 |
| 5 | Data migration | None (D3) | — | |
| 6 | OMS id coverage | Per tenant: `SELECT facility_code, count(*), sum(wms_item_id IS NULL) FROM product_wms_item WHERE product_id<>0 GROUP BY facility_code;` | Nam / OMS DBA | Sizes the G7 exposure |
| 7 | Access | **Writable WineCo UAT psql session for M-5** (K-#10) | Joe | No new function/gate |
| 8 | Monitoring | Log tokens §7.4 + weekly queries §8 | Joe (log search) | Metrics unscraped |
| 9 | Replicas / redis (Q5) | **OPEN** | Joe | G4 |

### 5.2 Phases

**P0 — TDD gate.**
- Worktrees `.claude/worktrees/{wms2-api,oms-laravel-api}/SBDEV-2624` on the frontmatter branches, off freshly fetched `origin/develop`.
- Add **compile-only skeletons** so tests fail on assertions, not on compilation: DTO fields, repository/finder declarations, constants 108 **and** 109, the `failIfExists` parameter, `WMS_RESYNC_MARKERS`, `upsertAll` returning `new LinkedHashMap<>()`, the OMS signature with an unused param. P1/P2 replace every skeleton body.
- Write §7.1. Each **RF** row must go red on base with the stated message; each **RG** row is green on base and proven by its mutant.
- Record both full-suite baselines. Pause for Nam.

**P1 — wms2-api.** §3.1–§3.4.
*Accept:*
- every §7.1 wms2 row green;
- every named mutant red;
- PIT (JDK 21) on `SkuBatchCreateUpdateService` plus the hand mutants on the controller and SQL;
- `mvn clean` then the full suite = baseline.

**P2 — oms-laravel-api.** §3.5–§3.6.
*Accept:*
- every §7.1 OMS row green under the Docker recipe (throwaway MySQL);
- every OMS hand mutant (§7.1) red;
- `./vendor/bin/pint` clean;
- the replaced tests deleted, not skipped.

**P3 — Review and ship.**
- `code-reviewer` per repo plus a `verifier` lane; fix every finding including Low.
- M-1…M-7 on dev, then UAT.
- PRs into `develop`; stop at PR.
- *Accept:* M-5 output in the wms2 PR.

### 5.3 Deploy order

The order is **required: wms2 first** (reason corrected per A-r2 N9). Twins are created during the gap in **either** order, because whichever side is old breaks the rename path. The real reason: the old OMS already records per-facility ids from a create response (`'wms_item_id' => is_numeric($facilityItemId) ? (int) $facilityItemId : null`), so wms2's 200 + `item_ids` starts filling the map during the gap. When the OMS lands, `facility_item_id` is already known for SKUs created in between.

| State | Behaviour |
|---|---|
| wms2 new, OMS old | Global `item_id` ignored (C1); lookup by `sku` = today. 200 + `item_ids` lets `createSkuFromProduct` start recording real ids; old `updateSku` ignores the body; `isFailureResponse` is false for both |
| wms2 old, OMS new (rollback of wms2) | New fields dropped as unknown = today; a 204 gives `data = []`, and the NULL guard keeps stored ids |

- **Rollback:** revert either side independently and you land in one of the states above.
- **Irreversible part:** stockrecord rewrites that already ran, undone only by a reverse rename.

---

## 6. Backward compatibility

**Changes:** create/update success becomes **200** + JSON (A-r1 §5: safe for OMS v2, `createSkuBatch`, v1 OMS `HttpRestJson/Client.php`; no wms2 UI calls `/rest/sku`) · collision and precondition → 422 instead of a silent twin or a 500 · optimistic loss → 422/109 instead of today's 500 · lock wait or deadlock on `/rest/sku` → 422/109 instead of today's **503 + Retry-After 30**, which the OMS never retried (§3.3) · `statuscodeanswer` "204"→"200" · an id-hit delete whose code ≠ `sku` returns 400 (the delete handler's existing client-error status).

**What does NOT change:** payloads without the new fields (AC-5, AC-6) · `itemdata.id` and every FK row · schema (no `db/migration` file, no OMS migration) · the `finally` clear (SBDEV-3135) · `IdempotencyFilter` · client moves create under the new client (Q2) · the `product.wms_item_id` column (kept; no reader or writer left) · the SDR write withdrawal on `Itemdata` (W14).

**Known gaps:**

| # | Gap | Owner / detection |
|---|---|---|
| G1 | `inventory_record.itemdatanumber` keeps the old code (snapshot) | accepted |
| G2 | Queued message/outbox/idempotency payloads carry the old code | accepted |
| G3 | An OMS message composed before the rename and delivered after it fails `ENTITY_DOES_NOT_EXISTS` at W11 | OMS retry/queue delay |
| G4 (Q5) | Other replicas, ≤5 min: a cached miss for B fails W11 lookups of B; `:id:` entries show the old code. W13 order import is uncached | Joe |
| G5 | A duplicate `sku` within one batch is undefined (pre-existing; the OMS sends one per call) | — |
| G6 (A-M1, K-#9) | A stock write that read A before the rename and inserts its stockrecord row after the rewrite statement's snapshot leaves an orphan on code A. Expected ≤ 0.02 rows per rename on the hottest SKU (201 rows/day ≈ 0.0023/s × a ≤10 s window) | Weekly orphan query §8; heal SQL §8 |
| G7 (K-#2, K-r2 #6) | A rename that fails at one facility (5xx not retried, or 409 in-flight on a timeout retry) leaves the WMS at A. Id known → the N2 resend or the next edit heals it. Id unknown → the next edit creates a twin. **Out-of-order with no id** (edit1 A→B, edit2 B→C delivered first): all three lookups miss → (c,C) twin, then edit1 renames A→B; the WMS ends with B and C | `rename-not-acknowledged` log; weekly fingerprint query |

**G6: keep the gap, rather than a same-tx second pass (A-r2 N3 corrects r2's reasoning).** r2 said no lock makes a stock writer wait for the rename. That is wrong for writers that insert a child-FK row: they hold FOR KEY SHARE on X, so our `saveAndFlush` (FOR UPDATE) waits for them to commit. A second run of the same UPDATE after `saveAndFlush`, in the same tx, gets a fresh READ COMMITTED snapshot and would pick up their stockrecord rows — no `afterCommit`, no REQUIRES_NEW. I still recommend **keep-G6**:
- (a) It catches only the writers that insert a child-FK row (receipt, new stockunit). Moves and picks that UPDATE an existing stockunit take no FK lock and are still missed, so it narrows G6 but does not close it.
- (b) It runs **while the FOR UPDATE is held**, the very interval H2 shortened. After pass 1, the `lower('wci pc')` index entries still point at the 44,251 superseded tuples until vacuum, so pass 2 does ~44k heap visibility checks under the lock. That puts the child-FK block back at seconds on the hot SKU.
- (c) Measured exposure is ≤0.02 rows per hot rename; monitor + heal SQL repairs it.

It stays the documented upgrade path if the day+1/+7 orphan query is ever non-zero twice.

---

## 7. Testing

### 7.1 Acceptance criteria → tests → mutants

- **Lanes:**
  - **PG** = `SkuRenameInPlaceIT extends BasePostgresIntegrationTest` (Testcontainers + Flyway, run by failsafe `**/*IT.java`), overridden to `@Transactional(propagation = Propagation.NOT_SUPPORTED)` with by-id cleanup, as in `MoveCronConcurrencyIT`.
  - **U** = unit.
  - **OF/OU** = OMS Feature/Unit.
- **Kind:** **RF** = red-first on base (the expected red message is given); **RG** = regression guard, green on base, proven by its mutant.
- **Assertion order:** row state first, status second. The 200 contract lives only in AC-7a (K-#7).

| AC | One observable assertion | Lane / kind | Test | Mutant → expected red |
|---|---|---|---|---|
| AC-1 | (c,A)=X with a stockunit; POST `{sku:B, previous_sku:A}` → `SELECT id FROM itemdata WHERE client_id=c AND item_nr IN ('A','B')` = `[X]`, X.item_nr='B', stockunit.itemdata_id=X | PG RF: "expected [X] found [X, N]" | `SkuRenameInPlaceIT.update_renameByPreviousSku_keepsRowIdAndStockunitFk` | ignore previous_sku → same red |
| AC-2a | X at C, no `previous_sku`; POST `{facility_item_id:X, sku:B}` → X.item_nr='B', client row count unchanged | PG RF: "X.item_nr expected B was C" | `…update_byFacilityItemIdWithoutPreviousSku_recoversRename` | skip step 1 → same red |
| AC-2b | X at C, **Z=(c,A)** seeded (K-#5); POST `{facility_item_id:X, previous_sku:A, sku:B}` → **first** `count(itemdata where client_id=c)` unchanged (K-r2 #4), then X and Z unchanged (item_nr, version), stockrecord for C and A unchanged, then 422 | PG RF: "expected 2 rows found 3" | `…update_idHitWithMismatchedPreviousSku_rejectsPrecondition` | swap steps 1↔2 → Z renamed, msg `"lookup order: previous_sku resolved before facility_item_id"`; drop CAS → X renamed |
| AC-3 | X under client d; POST under c `{facility_item_id:X, sku:B}` → X byte-identical (item_nr, client_id, version); (c,B) exists | PG RG | `…update_facilityItemIdOfOtherClient_isMiss` | drop `clientId` from `findByIdAndClientId` → "X.item_nr changed" |
| AC-4 | X=(c,A), Y=(c,B); POST `{previous_sku:A, sku:B}` → X, Y unchanged (name, version), stockrecord (c,A) count unchanged; then 422 with `item_id=X` and `item_id=Y` in `description` | PG RF: "Y.name changed" | `…update_renameOntoExistingSku_422NamingBothIds` | collision check removed → DIVE translated, but description lacks Y |
| AC-4c | Warm a cached miss for (c,B) through `itemdataService`, insert (c,B)=Y with committed SQL, POST rename A→B → rows unchanged; 422 whose `description` contains `item_id=<Y>` (K-r2 #2) | PG RF: "expected 422 was 500" | `…collisionCheck_ignoresCachedMissForB` | collision check via the cached service → DIVE-translated 422 → "description lacks item_id=Y" |
| AC-4d | Latch (N1). **Fixture (K-r3 #11):** a **raw tenant-`DataSource` connection** with `setAutoCommit(false)` inserts (c,B) and holds; the context `JdbcTemplate` is the landlord pool with autocommit off and never commits, so it is not used. The POST create B runs on **its own thread** and blocks on the unique index (poll `pg_stat_activity.wait_event_type='Lock'`). Then `commit()` the raw connection. Assert **first** exactly one (c,B) (the raw one), **then** response 422 (105, `"create"` text), not 500 | PG RF: "expected 422 was 500" | `…create_concurrentInsertOfSameSku_returns422Not500` | create branch back to plain `save` → 500 at commit |
| AC-5b | **Returned id is the DB id (A-r3 R1):** PUT create B → `item_ids["B"]` equals `SELECT id FROM itemdata WHERE client_id=c AND item_nr='B'`; same for an update that falls to the create branch. Row assertion first | PG RF: "expected 200 was 204" on base; with the skeleton, "expected <id> was null" | `…create_returnsItemIdEqualToDbId`, `…update_createBranch_returnsItemIdEqualToDbId` | read `itemData.getId()` instead of `saved.getId()` → "expected <id> was null" |
| AC-5c | Create endpoint with a stale cached miss for (c,B) while (c,B)=Y exists → 422 `ENTITY_ALREADY_EXITS`; Y unchanged (K-r3 open Q2) | U RF | `SkuBatchCreateUpdateServiceUnitTest.upsertAll_failIfExists_recheckHit_throws` | ignore `failIfExists` → Y updated |
| AC-5 | No A, no B, no id → exactly one new (c,B) | PG RG | `…update_fullMiss_createsUnderClient` | miss → 422 (PR #14 shape) → "no row" |
| AC-6 | (c,B) exists; `{sku:B}` → `save` on existing id; `renameItemdataForClient` never called | U RG | `SkuBatchCreateUpdateServiceUnitTest.upsertAll_plainUpdate_neverRenames` | always call rewrite → `never()` fails |
| AC-7a | create and update return **200** with `item_ids == {"B": X}` (stub `upsertAll`'s return) | U RF: "expected 200 was 204" | `SkuRestControllerUnitTest.create_returns200WithItemIdsBySku`, `…update_returns200WithItemIdsBySku` | return 204 / empty map |
| AC-7b | An OMS update response with `item_ids` → `product_wms_item(p,F).wms_item_id == X` **and** `product.wms_item_id` stays NULL after a create (K-r2 #5) | OF RF | `WmsApiServiceTest::it_records_item_ids_from_update_response_per_facility`, `…it_does_not_write_global_wms_item_id_on_create` | drop recordSeen on update; restore the global write |
| AC-7c | `recordSeen(F,[[p,null]])` over a stored 77 → 77; `last_seen_at` advanced | OU RF | `ProductWmsItemTest::record_seen_with_null_id_keeps_stored_id` | single upsert again |
| AC-7e | A failed update that carried `previous_sku` logs `SBDEV-2624 rename-not-acknowledged` (`Log::spy`) | OF RF | `…it_logs_rename_not_acknowledged_on_failed_rename` | drop the log |
| AC-7f | Resend shape, **parameterised over both markers (A-r3 R2)**: F answers 422 with the 108 (resp. 109) description **and answers the resend with 108 again** → exactly one resend to F (loop bound), `sku` = the DB-reloaded SKU, no `previous_sku`, a new nonce; `resync-resend` log carries X, D, SKU | OF RF: "resend count expected 1 was 0" | `…it_resends_one_reloaded_plain_update_on_{precondition,concurrent}_marker` | resend the request copy's `sku`; drop the 109 marker → count 0 ≠ 1; resend unbounded → count 2 ≠ 1 |
| AC-7g | No `facility_item_id` was sent to F → no resend on 108/109 (K-r3 #7) | OF RG | `…it_does_not_resend_without_facility_item_id` | resend without id → count 1 ≠ 0 |
| AC-7h | **Bad-map guard (K-r3 #1):** 108 says `item_id=X is D` and another active product of the same client has SKU D → no resend, `resync-skipped-bad-map` logged; a malformed description → no resend | OF RG | `…it_skips_resend_when_target_code_belongs_to_another_active_product` | drop the guard → resend count 1 ≠ 0 |
| AC-7d | Response `item_ids {"OTHER":5,"B":9}` → recorded 9, not 5 (A-L3) | OF RF | `WmsApiServiceTest::it_records_the_id_for_the_exact_sku_key` | `reset()` fallback |
| AC-8a | Map {F1:11, F2:NULL} → F1 has `facility_item_id=11`; F2 has no key | OF RF | `…it_sends_facility_item_id_per_facility_and_omits_null` | send for NULL |
| AC-8b | No create/update/delete/batch payload has the key `item_id` | OF RF | `…it_never_sends_global_item_id` (replaces `it_includes_item_id_in_sku_data_when_product_has_wms_item_id`, `it_includes_item_id_in_delete_payload`) | re-add `item_id` |
| AC-8c | `previous_sku` present iff it differs from the trimmed SKU, compared **case-sensitively** (`abc`→`ABC` sends it; `abc `→`abc` does not) (A-r2 N8) | OF RF | `…it_sends_previous_sku_only_when_sku_changed` | send unconditionally; `strcasecmp` compare |
| AC-8d | C2 rename A→B → payload `previous_sku: A` | OF RF | `tests/Feature/Api/Legacy/LegacyV2ProductWmsSyncTest::it_passes_pre_update_sku_on_rename` (new) | pass `$updatedProduct->product_sku` |
| AC-8e | C1 client move + rename → no `previous_sku` | OF RG (base sends none) | `ProductControllerTest::it_sends_no_previous_sku_on_client_move` | compare SKU only → `previous_sku` present |
| AC-8h | Delete sends F's map id as `facility_item_id`; omitted when NULL or ambiguous; never the global id (K-r2 #5) | OF RF | `…it_sends_per_facility_item_id_on_delete` | pass `$product->wms_item_id` |
| AC-8f | Two map rows at F share an id → `facility_item_id` omitted | OF RF | `…it_omits_facility_item_id_when_ambiguous_at_facility` | drop the guard |
| AC-8g | Two calls → different `request_nonce`; one call's facilities and retries → same; `createSkuBatch` and `deleteSku` carry one | OF RF | `…it_sends_a_fresh_request_nonce_per_sync_call` | constant nonce / missing in batch |
| AC-9 | Same JVM: after rename A→B, `findByClientIdAndItemNr(c,'B')` = X despite a pre-warmed miss; `(c,'A')` empty | PG RF: "expected X found N" (K-r2 #3) | `SkuRenameInPlaceIT.update_rename_evictsCachedMissForNewCode` | delete the `finally` clear → "found empty" |
| AC-10a | After a rename: stockrecord (c,'A') = 0, (c,'B') = the old A count; client d's 'A' rows and an 'a' row untouched | PG RF: "expected 0 was 3" | `…update_rename_rewritesStockrecordForClientExactCaseOnly` | drop `client_id` → d's rows; drop the exact conjunct → 'a' row |
| AC-10b | `transaction_detail(c_nr,'B',…)` includes the pre-rename movement | PG RF | `…update_rename_transactionDetailIncludesPreRenameMovements` | no rewrite call |
| AC-11 | `InOrder`: collision `findByClientIdAndItemNr` → `renameItemdataForClient` → `saveAndFlush`; `setItemNr` invoked after the rewrite (A-H2) | U RF | `SkuBatchCreateUpdateServiceUnitTest.upsertAll_rename_rewritesStockrecordBeforeMutatingAndFlushingItemdata` | move `setItemNr` before the rewrite → InOrder fails |
| AC-12 | DIVE → 105; `PessimisticLockingFailureException`, `ObjectOptimisticLockingFailureException` → **109**; injected at the rename `saveAndFlush`, the create `saveAndFlush` and the step-5 `saveAndFlush` (K-r2 #10, N1) | U RF | `…upsertAll_{dataIntegrityViolation,lockTimeout,optimisticLock}At{Rename,Create,PlainUpdate}_translated` (parameterised, 9 cases) | remove a catch; plain `save` in step 5 → no exception at the stub |
| AC-13 | Create with a cached miss but (c,B) in the DB → no insert, updates Y (A-L4) | U RF | `…upsertAll_createBranch_rechecksRepositoryBeforeInsert` | drop the re-check → `save(new)` |
| AC-14 | Delete `{facility_item_id:X}` with X.item_nr = sku → deleted; X.item_nr ≠ sku → 400, X kept, `SKU_DELETE_PRECONDITION` logged; X under client d → code fallback | U RF | `SkuRestControllerUnitTest.delete_byFacilityItemId_casOnSku`, `…delete_facilityItemIdOfOtherClient_fallsBackToCode` | drop the CAS → X deleted |
| AC-15 | Reconcile with stored id X at F, WMS X under code A, OMS SKU B → `code_drift` has the product; not in the create batch; `pruneStale` keeps the row | OF RF | `FacilityWmsSyncTest::it_reports_code_drift_and_keeps_the_facility_row` | treat as missing → `createSkuBatch` called |
| AC-15b | **Backfill keep rule (K-r2 #1):** stored id X at F, WMS X under A, OMS SKU B; run `backfillFacilityItemMap(F)` → the `product_wms_item(p,F)` row exists with `wms_item_id` = X, and the return has `code_drift` count 1 | OF RF: "row pruned" | `FacilityWmsSyncTest::backfill_keeps_drifted_row_with_its_id` | mutant #12 → row pruned |
| AC-15c | Reconcile with `product.wms_item_id` NULL and a WMS match → after the run `product.wms_item_id` is still NULL; `product_wms_item` has the id (K-r3 #6, 4th writer) | OF RF: "expected null was 123" | `FacilityWmsSyncTest::it_does_not_write_global_wms_item_id_on_reconcile` | restore the `backfillWmsItemIds` global write |
| AC-16 | Readers ignore inbound `item_id`. Fixture per reader (A-r2 N5): `LegacyInventoryAdjustService` — a product of **another** client holds `wms_item_id` = the inbound id; `LegacyWmsController` and `LegacyProductUpdateService` (already client-scoped) — a product of the **same** client holds a stale global `wms_item_id` = the inbound id. Each → the client+SKU product changes, the decoy does not; `product.wms_item_id` not written | OU/OF RF | `LegacyInventoryAdjustmentAlertTest::it_ignores_inbound_item_id_and_resolves_by_client_sku`, a twin in `LegacyInventoryStockUpdateReallocationTest`, `tests/Feature/Api/Legacy/LegacyWmsControllerItemIdTest::it_ignores_inbound_item_id_and_resolves_by_client_sku` (new), `tests/Unit/Services/Legacy/LegacyProductUpdateServiceItemIdTest::it_ignores_stale_global_wms_item_id` (new) | restore any one `wms_item_id` lookup → the decoy changes |
| §3.4 | The `@Query` contains `lower(itemdata) = lower(:oldItemNr)` and `client_id = :clientId` | U RG | `StockrecordRenameQueryShapeUnitTest.renameItemdataForClient_predicateMatchesIndexAndClient` | delete `lower()` → red |
| 108/109 | `getErrorCodeText` and `getErrorCodeName` non-generic for both; 108 text starts `sku rename precondition failed`, 109 `sku concurrent modification` | U RF | `WmsConstantsSkuRenameUnitTest.codes108and109_haveTextAndNameArms` | drop a name arm; reword a marker |
| SDR | `findByIdAndClientId` carries `@RestResource(exported=false)` | U RF | `ItemdataRepositorySdrExportUnitTest.findByIdAndClientId_isNotExported` (new, pure reflection — `ItemdataRepositoryTest` is full-context `BaseRepositoryIntegrationTest`, K-r2 #10) | remove the annotation |

**OMS hand-mutant list (K-#8, no PHP mutation tool):**
1. re-add `item_id`;
2. drop the NULL omission;
3. send `previous_sku` unconditionally;
4. constant nonce;
5. drop the ambiguity guard;
6. `reset()` id read;
7. one `recordSeen` upsert;
8. C2 passes the fresh copy;
9. C1 uses `wasChanged` (AC-8e);
10. reconcile treats drift as missing (AC-15);
11. restore an R1 lookup (AC-16);
12. **backfill prunes drift** — the `backfillFacilityItemMap` keep rule removed (AC-15b);
13. drop `recordSeen` on update (AC-7b);
14. restore the global `product.wms_item_id` write (AC-7b);
15. C1 compares the SKU only, ignoring the client (AC-8e);
16. drop the `rename-not-acknowledged` log (AC-7e);
17. resend the request copy's SKU, or resend without an id (AC-7f);
18. delete passes the global id (AC-8h);
19. case-insensitive SKU compare (AC-8c).

Each must turn its row red. Record the outputs in the P2 report.

**Mutant #9 is equivalent (K-r3 #8), recorded as such.** C1's closure has a single `$product->update($validatedData);` (ProductController slice :694–815, `grep -nE -e '->save\(|->update\('` = 1 hit). `git grep` finds no `ProductObserver`, `Product::observe` or `booted`/`saving` hook in `app/Models/Product.php`. So `wasChanged('client_id')` and the value comparison agree and no test can tell them apart. The value comparison is kept as the more robust form. Also new: #20 drop the 109 marker (AC-7f), #21 drop the bad-map guard (AC-7h), #22 restore the `backfillWmsItemIds` global write (AC-15c), #23 ignore `failIfExists` (AC-5c, wms2 hand mutant).

**OMS red-on-base messages (K-r3 #9):**

| AC | Red on base |
|---|---|
| 7b | "product_wms_item.wms_item_id expected X was null" |
| 7c | "expected 77 was null" |
| 7d | "expected 9 was 5" (base `reset()`) |
| 7e | "Log::warning not called with rename-not-acknowledged" |
| 7f | "resend count expected 1 was 0" |
| 8a | "payload lacks facility_item_id" |
| 8b | "payload has key item_id" |
| 8c / 8d | "payload lacks previous_sku" |
| 8g | "payload lacks request_nonce" |
| 8h | "payload has item_id / lacks facility_item_id" |
| 15 | "createSkuBatch called once, expected never" |
| 15b | "row pruned" |
| 15c | "expected null was 123" |
| 16 | "decoy product inventory changed" |

7g, 7h, 8e and 8f are RG (base never resends and never sends the id) and are proven by their mutants.

**Existing tests to update, never delete:**
- the 204 assertions in create/update (`git grep -cE "isNoContent|NO_CONTENT|204"`: SkuRestControllerUnitTest 4, SkuRestControllerIntegrationTest 3, Atomicity 2, CacheEvictionOnWriteUnitTest 2, IdempotencyFilterUnitTest 2 — check each for create/update vs delete);
- `it_captures_wms_item_id_from_create_response`, whose `$product->fresh()->wms_item_id == 12345` becomes the `product_wms_item` assertion (K-#4);
- the R1 tests that rely on the `wms_item_id` lookup.

Keep green: `SkuRestControllerAtomicityIntegrationTest` (3, H2), `TenantCacheKeyUnitTest` (10), `SdrWriteWithdrawalContextTest`.

### 7.2 Run

- **wms2 (JDK 21):** `mvn -Dtest=SkuBatchCreateUpdateServiceUnitTest,SkuRestControllerUnitTest,StockrecordRenameQueryShapeUnitTest,WmsConstantsSkuRenameUnitTest,ItemdataRepositorySdrExportUnitTest test`.
- **IT alone:** `mvn verify -Dit.test=SkuRenameInPlaceIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` (K-#11). Never `-Dit.test='!X'`. Then `mvn clean verify` against the baseline; `pgrep -f maven` before debugging a red.
- **OMS:** Docker recipe, `php artisan test --filter='WmsApiServiceTest|ProductWmsItemTest|LegacyV2ProductWmsSyncTest|ProductControllerTest|FacilityWmsSyncTest|LegacyInventory|LegacyWmsControllerItemIdTest|LegacyProductUpdateServiceItemIdTest'`.

### 7.3 Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M-1 | Rename happy path | dev (`dev_wh01_om1`) + OMS dev | Rename a SKU with stock in the OMS; query itemdata by id | Same id, new code; stock screen shows the new code | |
| M-2 | Collision | dev | Rename P1 to P2's code | OMS log names both ids; `SKU_RENAME_COLLISION` WARN; nothing changed | |
| M-3 | New facility gets catalogue | dev, 2 facilities | Edit a SKU absent at F2 | F2 creates it; `product_wms_item(F2)` gets the id | |
| M-4 | Report history | UAT wineco | Rename a SKU with history; transaction detail for the new code | Pre-rename movements listed | |
| M-5 | Index + duration | UAT wineco, writable (Joe) | §3.4 instrument 2 | `index_stockrecord_itemdata` in both plans; scaled time < 10 s; else §3.4 fallback | |
| M-6 | Revert (F-1) | dev | A→B, B→A, A→B within minutes | WMS ends at B; three `SKU_RENAME` lines | |
| M-7 | Drift (both entry points) | dev | Break a rename (WMS at A, OMS at B, id known). Run a **real full** facility sync — not dry-run: `pruneStale` runs only `if ($clientIds === null && ! $isDryRun)` (K-r2 #10). Then `php artisan tenants:artisan "wms:backfill-facility-items <F>"` | Product in the sync's `code_drift` and the backfill's count; no twin; map row kept with id X after both; the next OMS edit renames A→B (`SKU_RENAME_BY_ID_RECOVERY`) | |

### 7.4 Observability

- **Stable log tokens (K-#14):**
  - `SBDEV-2624 SKU_RENAME` (INFO)
  - `SKU_RENAME_COLLISION`, `SKU_RENAME_PRECONDITION`, `SKU_RENAME_BY_ID_RECOVERY` (WARN)
  - `SKU_DELETE_PRECONDITION` (WARN, wms2)
  - OMS `SBDEV-2624 rename-not-acknowledged`, `SBDEV-2624 delete-not-acknowledged`, the resend (`SBDEV-2624 resync-resend`)
  - `code_drift` counts from both the sync report and `SBDEV-2624 backfill code_drift`

  Count tokens, not `message LIKE` (the `message` row stores the payload, not the error).
- **DB (weekly, §8):** fingerprint = 0 new; orphan query = 0; OMS NULL-id share falling.

### 7.5 Horizontal Scalability Validation

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | No new | Caffeine pre-existing; G4/Q5 |
| 2 | Connection pool | No | One connection per request, held longer (row 4) |
| 3 | Scheduled jobs | N/A | None; facility sync is operator-triggered |
| 4 | Long transactions | **Yes** | The rewrite (≤44,251 rows) runs **before** the itemdata write, so the FOR UPDATE that blocks the 8 child FK checks is held only from `saveAndFlush` to commit (A-H2, AC-11). That is milliseconds **for a batch with one rename**. In a batch with several, item k's lock is held through the rewrites of k+1…n (A-r2 N4). The OMS sends one SKU per update call and `createSkuBatch` never renames (G5), so this does not arise today. No external I/O. M-5 gate < 10 s |
| 5 | Request affinity | No | Id step, CAS reload and collision check are all uncached DB reads |
| 6 | Retry / idempotency | **Yes** | The OMS retries only connection errors, never a 4xx/5xx (§2.1). A retried rename after commit re-resolves to the renamed row → plain update. 409 in-flight → G7. Nonce prevents replay-drop |
| 7 | Tenant context | No | Request thread only |
| 8 | Distributed lock correctness | **Yes, corrected (A-H1, K-#2)** | `@Version` does **not** catch an out-of-order rename: the reload sees the committed newer code at the current version. The CAS (§3.3 step 3) catches it → 422. Same-row concurrency: version check at `saveAndFlush` → 422 (AC-12); the loser's edit is not retried by the OMS and surfaces as `rename-not-acknowledged` (G7) |
| 9 | Cache invalidation | **Yes** | `finally` clear in the handling JVM (AC-9); other replicas G4 |
| 10 | External notifications | No | None added |

### 7.6 v2 constraint checklist

| # | Constraint | Status |
|---|---|---|
| 1 | Tenant tx manager | No new `@Transactional`. `renameItemdataForClient` has no tx config; it joins `upsertAll`'s `tenantTransactionManager` tx and throws `TransactionRequiredException` outside one (K-#12) |
| 2 | No Flyway | None |
| 3 | Lookups client-scoped | Steps 1–3, collision, create re-check, delete — all take `clientId` (AC-3, AC-14) |
| 4 | No new SDR route | `findByIdAndClientId` `exported=false` (pinned); `StockrecordRepository` type-level `exported = false`; Itemdata writes withdrawn (W14) |
| 5 | Error codes | 105 reused; 108 and 109 added, each with **both** arms (pinned), avoiding the `NOT_ENABLLED_FOR_RECEIVING` missing-name trap |
| 6 | Post-commit-safe eviction | `finally` kept |
| 7 | Native SQL on real PG | `SkuRenameInPlaceIT` |
| 8 | No gate change | `/rest/**` internal-only |

---

## 8. Rollout

1. Merge wms2-api to `develop` (a dev deploy; Flyway no-op). Confirm `/api/public/version`. M-1, M-3 with the OMS old.
2. Merge oms-laravel-api to `develop`. M-1…M-7 on dev.
3. UAT: M-4, M-5 (paste into the PR).
4. Release/main are DevOps. Prd: wms2, confirm the version on every replica (§5.1 #4), then the OMS.
5. Day +1 and +7 per tenant:
   - the fingerprint query (`created > :deploy`) = 0;
   - the token counts;
   - the **orphan query (G6)**: `SELECT count(*) FROM stockrecord sr WHERE sr.created > :deploy AND NOT EXISTS (SELECT 1 FROM itemdata i WHERE i.client_id=sr.client_id AND i.item_nr=sr.itemdata)` = 0.
6. If the orphan query is non-zero, heal (idempotent, same index-friendly predicate, guarded so it never re-labels a live code):

   ```sql
   UPDATE stockrecord SET itemdata = :new
    WHERE lower(itemdata) = lower(:old) AND itemdata = :old AND client_id = :c
      AND NOT EXISTS (SELECT 1 FROM itemdata WHERE client_id = :c AND item_nr = :old);
   ```

   Take `:old` → `:new` from the `SKU_RENAME` log line.
7. Propose (do not file) the D3 cleanup ticket with the §10 query.

---

## 9. Alternatives

| # | Alternative | Rejected because |
|---|---|---|
| A1 | Alias table | ~20 call sites + cache key + a Flyway table; class (b) stores still stale |
| A2 | Never change `item_nr`; add a display code | Schema-wide re-key |
| A3 | OMS deletes and recreates | ~13% of SKUs deletable (SBDEV-3135); abandons stock and orders |
| A4 | PR #14: unscoped `findById`, fail on miss | Violates C2; breaks the broadcast create (AC-5) |
| A5 | Honour today's `item_id` | First facility's id sent everywhere; renames another product (C1) |
| A6 | Accept the stockrecord gap | Nam Q1: rewrite |
| A7 | `previous_sku` only, plus an OMS pending-rename store (A-r1 §1 steelman) | Weighed against the id path's own failure modes (S1, S3), the CAS and the ambiguity guard now bound those. A7 still loses every rename that fails at a facility with no follow-up acknowledgement store, and that store needs an OMS migration (driver 3). The id is retained, guarded |
| A8 | Stable OMS key (`product_id`) on `itemdata` (K-#16) | Strongest rival: one key for every facility, no per-facility plumbing. Needs a Flyway column on itemdata in every tenant plus a backfill keyed by — again — code matching. Rejected on driver 3 (no migration) and because its backfill inherits the same code-match weakness |

---

## 10. Open questions / resolved decisions

**Resolved (Nam, 2026-10-02):** D1 rename in place · D2 collision → 422 naming both ids · D3 no cleanup here · Q1 rewrite stockrecord in the same tx, index-friendly · Q2 client move creates under the new client · Q3 accept the 422 for existing duplicates · Q4 delete uses the same client-scoped lookup.

**Answered (K-r2 open):** `BackfillFacilityWmsItemsJob` runs once per tenant migrate (the `2026_07_23_100001` dispatch), plus whenever an operator runs `wms:backfill-facility-items`; exposure to AC-15b is per invocation, not scheduled. Multi-rename batches: §7.5 #4.

**Open:** **Q5 (Joe)** replica count and the `redis` profile. **K-open:** is prd `app.idempotency.bridge-mode` on? (A-r1 measured `false` in `application.properties:283`; the deploy env may override.) It matters only for a future header-key switch; the body nonce is robust either way.

**Tier verdicts on the coordinator's two items:**
- **R1 (`LegacyInventoryAdjustService` unscoped `wms_item_id` reader) → T2, folded into P2.**
  - **Evidence it is dormant:** wms2 sends no `item_id`. `git grep -n '"item_id"'` over wms2 `src/main` returns only `@Column(name = "item_id")` on `StockView` and `StockrecordView` (DB views, not outbound JSON). The same grep is its own positive control, since it finds those two, and `WmsObjectMapper` has no snake-case naming strategy. v1 WMS has no client.
  - **Blast radius if it ever woke up:** another client's product inventory overwritten at a facility (ShipItEZ has two facilities with separate id sequences).
  - **Why T2, not T3:** the fix removes a lookup that never matches today. It is predictable, reversible, needs no data change, and touches 4 files in one repo (the 3 readers + `backfillWmsItemIds`). A-r2 N5 re-swept `git grep wms_item_id` over `app/` and found no other reader.
- **L7 (SDR PATCH on itemdata) → nothing to do, refuted (W14).**

**D3 detection query (read-only):**

```sql
SELECT i.client_id, i.id older_id, i.item_nr older_nr, i.created older_created,
       j.id newer_id, j.item_nr newer_nr, j.created newer_created,
       (SELECT count(*) FROM stockunit s WHERE s.itemdata_id=i.id) older_su,
       (SELECT count(*) FROM stockunit s WHERE s.itemdata_id=j.id) newer_su,
       (SELECT count(*) FROM customerorder_position p WHERE p.itemdata_id=j.id) newer_cop
FROM itemdata i JOIN itemdata j ON j.client_id=i.client_id AND j.id>i.id
 AND lower(trim(j.name))=lower(trim(i.name)) AND j.item_nr<>i.item_nr
ORDER BY i.client_id, i.id;
```

The narrow 2624 fingerprint (13 rows on WineCo prd) is the §2.2 create-on-update query joined to this.

---

## 11. Pre-mortem (DELIBERATE, K-#1)

Six months on, this change has failed. How?

| # | Scenario | Detection | Mitigation |
|---|---|---|---|
| S1 | **Wrong-row rename or delete through a bad id map.** Two OMS products map to one WMS id, or an id survives after its product's code was re-used. A plain edit, **or the N2 resend after a 108** (which drops `previous_sku` and so bypasses the CAS immediately, not only on the next edit; K-r3 #1), renames or deletes another product of the same client | `SKU_RENAME_BY_ID_RECOVERY` WARN; `resync-skipped-bad-map`; the D3 query; the delete CAS 400 | Client scope (AC-3); OMS ambiguity guard (AC-8f); CAS when `previous_sku` is present (AC-2b) — **but the CAS alone does not cover the resend**, which is why the resend skips when the WMS row's code D is another active product's SKU (AC-7h); delete CAS (AC-14). Reconcile ids are exact client + code matches (A-r1 §5). Rename is reversible by renaming back; delete is guarded |
| S2 | **Lost rename at a facility (G7).** A 5xx, a 409-in-flight, or a 108/109 the resend cannot fix leaves the WMS at A while the OMS moves on; with no known id the next edit creates a twin | `rename-not-acknowledged` OMS WARN; weekly fingerprint query > 0 | The id path heals on the next edit when the id is known; ids now flow on every create/update (AC-7). Residual = products with a NULL map row (§5.1 #6 sizes it). A pending-rename store is the follow-up if the fingerprint stays > 0 |
| S3 | **Facility sync or backfill re-creates the twin** after S2 and prunes the id, making S2 permanent — through either of the two pruning entry points (§0 P2) | `code_drift` in the sync report and the backfill log | Drift keep/report at both (AC-15, AC-15b): no create, row kept from `pruneStale`; heals on the next edit (M-7). Side effect: the kept row makes `presentAtFacility` claim B exists at F (flag off by default); B's orders fail loudly at WMS import until healed |
| S4 | **Hot-SKU rewrite slow or contended** (≥10 s, or lock waits on stockrecord) | M-5 timing before merge; OMS 30 s timeout errors; lock-timeout 422s with the "concurrent modification" text | H2 order keeps the child-FK-blocking lock short; the M-5 gate blocks merge; fallback = propose a `(client_id, lower(itemdata))` index ticket (T3, Flyway) |
| S5 | **stockrecord orphans** break the pair join that reports rely on (G6) | Weekly orphan query | Expected ≤ 0.02 rows per hot rename; idempotent heal SQL (§8 step 6) |
| S6 | **Out-of-order renames** (two editors, edit2 delivered first) | `SKU_RENAME_PRECONDITION` WARN; with no id, the fingerprint query | **Id known:** CAS rejects the stale one; the N2 resend reloads and converges (AC-7f). **Id unknown (residual, K-r2 #6):** all lookups miss and a (c,C) twin is created, then edit1 renames A→B (G7); detected only by the weekly fingerprint query |

---

## §R Review log r1→r2

| Finding | Disposition | Where |
|---|---|---|
| A-H1 out-of-order rename; §7.5 #8 false | Fixed: CAS on the reloaded row when `previous_sku` is present; AC-2 split a/b; #8 corrected | §3.3 step 3, §7.1 AC-2a/2b, §7.5 #8, S6 |
| A-H2 lock held through the rewrite | Fixed: collision → native rewrite → setters → `saveAndFlush` last; no mutation before the native statement; InOrder pin | §3.3 step 4, AC-11, §7.5 #4 |
| A-M1 / K-#9 stockrecord orphans | Chose G6 + monitor + idempotent heal; post-commit re-sweep rejected with reasons (cannot close the window, REQUIRES_NEW-after-commit trap) | §6 G6, §8 steps 5–6, S5 |
| A-M2 / K-#3 sync twin + pruneStale; `createSkuBatch` | Fixed: drift keep/report in reconcile + backfill; O7 added; nonce default | §0 P2/O7, §3.5, §3.6, AC-15, M-7, S3 |
| A-M3 delete by id ignores code | Fixed: delete CAS on `sku` (400 on mismatch). Rebutted the "OMS sends previous_sku on delete" part: `deleteSkuFromProduct(Product)` has only the current model, and both callers (`ProductController`, `LegacyV2ProductController` deactivation) carry no rename | §0 W3, AC-14 |
| A-L1 lock/optimistic → 500 | Fixed: translated to 422 | §3.3 translations, AC-12 |
| A-L2 nonce missing in `createSkuBatch` | Fixed: `buildSkuPayload` default | §3.6, AC-8g |
| A-L3 `reset()` fallback | Fixed: exact key or null | §3.5, AC-7d |
| A-L4 cached miss → create → 500 | Fixed: uncached re-check before insert | §3.3 create branch, AC-13 |
| A-L5 M-5 gate on an unmeasured table | Fixed: record the UAT count, scale to prd | §3.4, M-5 |
| A-L6 "either order safe" overstated | Fixed: wms2-first required, version-confirmed | §5.1 #4, §5.3 |
| A-L7 SDR PATCH on itemdata | **Rebutted**: Itemdata is in `SDR_WRITE_WITHDRAWN` (all 4 write verbs); `SdrWriteWithdrawalContextTest` pins it | §0 W14, §10 |
| A-r1 §1 steelman A7 | Weighed explicitly | §9 A7 |
| K-#1 pre-mortem missing (CRITICAL) | Added, 6 scenarios with detection + mitigation | §11 |
| K-#2 OMS does not retry 5xx; 409 in-flight | Fixed claims; G7 + OMS WARN | §2.1, §6 G7, §7.5 #6/#8, S2 |
| K-#4 readers of `product.wms_item_id`; create-response test | Fixed: R1 folded (T2 verdict); test replaced | §0 R1, §3.5, §10, AC-16, §7.1 |
| K-#5 AC-2 cannot catch the order mutant | Fixed: seed Z=(c,A), named message | AC-2b |
| K-#6 AC-9 in a mock harness | Fixed: moved to the PG IT; cached-collision test added | AC-9, AC-4c |
| K-#7 red-on-base unattainable; multi-assertion ACs | Fixed: RF/RG kinds, row-first order, 200 only in AC-7a, compile skeletons in P0 | §5.2 P0, §7.1 |
| K-#8 mutation floor partial | Fixed: a named mutant per row + OMS hand-mutant list | §7.1 |
| K-#10 M-5 access + fail path | Fixed: owner Joe; fail → index ticket proposal | §5.1 #7, §3.4 |
| K-#11 IT command | Fixed: `-Dtest=ZzzNone` | §7.2 |
| K-#12 tx reason | Fixed | §3.4 comment, §7.6 #1 |
| K-#13 "indexed count" | Fixed wording | §3.5 |
| K-#14 422-rate query | Replaced by stable WARN tokens | §3.3, §7.4 |
| K-#15 delete nonce; client-move detection | Fixed: nonce in the `deleteSku` payload; compare `$previousIdentity['client_id']` | §3.5, §3.6, §0 C1 |
| K-#16 A8 missing | Added | §9 A8 |
| K-#17 verify-script hygiene | Fixed: rows anchored, row 4 dropped, fail-closed, PROJECT_ROOT stated | Acceptance |
| K open Qs | Sync trigger answered (operator-only); bridge-mode → §10; Q5 open | §3.5, §10 |

---

## §R Review log r2→r3

| Finding | Disposition | Where |
|---|---|---|
| K-r2 #1 (MAJOR) backfill keep rule untested | Fixed: both pruning entry points in §0; keep rule spelled out for `backfillFacilityItemMap`; `code_drift` returned + logged; AC-15b; mutant #12; M-7 runs the backfill | §0 P2, §3.5, AC-15b, §7.1 #12, M-7, S3 |
| A-r2 N1 (Medium) commit-time exceptions escape | Fixed: `saveAndFlush` in the create branch and step 5, inside the wrapper (chosen over a controller catch: no deferrable constraints, keeps ids in the text); latch PG-IT AC-4d; AC-12 covers all 3 flush sites | §3.3, AC-4d, AC-12 |
| A-r2 N2 (Medium) stuck facility rejects every rename | Fixed: one DB-reloaded plain resend on 108/109, only when the facility id was sent; AC-7f + mutant #17; the marker is the one kept verify row | §3.5, AC-7f, Acceptance |
| A-r2 N3 G6 reasoning contradicts H2 | Corrected the sentence. Weighed the same-tx second pass (catches FK-inserting writers only, ~44k heap checks under the FOR UPDATE). **Recommend keep-G6**; the second pass is the documented upgrade path | §6 G6 |
| A-r2 N4 "milliseconds" only for one rename | Fixed wording | §7.5 #4 |
| A-r2 N5 AC-16 fixtures can't go red | Fixed: same-client stale-id decoy for the 2 client-scoped readers; dead `:1103` branch deleted; new FAILURE path noted | AC-16, §0 R1, §3.5 |
| A-r2 N6 rejected delete invisible | Fixed: wms2 `SKU_DELETE_PRECONDITION`, OMS `delete-not-acknowledged` | §3.5, AC-14, §7.4 |
| A-r2 N7 / K-r2 #10c kept drift row misleads `presentAtFacility` | Documented as an accepted side effect | §3.5, S3 |
| A-r2 N8 case-only rename on the OMS side | Fixed: case-sensitive compare after trim; AC-8c case added, mutant #19. The untrimmed prd rows (1 WineCo, 1 Hydra with twin 1927641) need no action, per A-r2's measurement | AC-8c |
| A-r2 N9 wms2-first reason weak | Reworded: the old OMS already records create-response ids | §5.3 |
| K-r2 #2 AC-4c mutant survives | Fixed: assert `item_id=<Y>` in `description` | AC-4c |
| K-r2 #3 AC-9 is RF | Relabelled RF, red "expected X found N" | AC-9 |
| K-r2 #4 AC-2b base message | Fixed: row count first, red "expected 2 rows found 3" | AC-2b |
| K-r2 #5 mutant list ≠ table; O6/WARN/global-write untested | Fixed: list reconciled (#9, #13–#19), AC-7b extended, AC-7e, AC-8h | §7.1 |
| K-r2 #6 out-of-order with no id | Residual stated | G7, S6 |
| K-r2 #7 4th global writer; caller count; dead branch | Fixed: `backfillWmsItemIds` write deleted; count = 3 callers + definition; dead branch + new FAILURE noted | §0 O7/R1, §3.5 |
| K-r2 #8 verify rows are shape assertions | Dropped all 3; kept 1 genuinely cross-repo row (resend marker) | Acceptance |
| K-r2 #9 nonce/id threading; `$previousIdentity` scope | Fixed: `$facilityData` keys per facility, no signature change; read `$newlyResolvableAliases['previous_identity']` | §3.6, §3.5, §0 C1 |
| K-r2 #10 SDR lane, M-7 dry-run, map side effect, AC-12 code | Fixed: new pure-reflection `ItemdataRepositorySdrExportUnitTest`; M-7 real full run; side effect in S3; code 109 named | §7.1, M-7, S3, W10c |
| K-r2 open Qs | Backfill trigger answered; multi-rename batches → §7.5 #4 | §10 |

## §R Review log r3→r4

| Finding | Disposition | Where |
|---|---|---|
| A-r3 R1 (Medium) merge returns a copy; create id null | Fixed: `Itemdata saved = itemdataRepository.saveAndFlush(itemData); ids.put(sku, saved.getId())`; PG-IT AC-5b (create + update→create branch) vs the DB id; mutant `itemData.getId()` | §3.3, AC-5b |
| A-r3 R2 109 marker untested on the OMS side | Fixed: AC-7f parameterised over both markers; mutant #20 | AC-7f |
| A-r3 R3 double `saveAndFlush`; create-branch 105 text | Fixed: the rename path ends at 4e → `ids.put`; step 5 is the non-rename tail; fixed 105 argument sets per flush site | §3.3 |
| A-r3 R4 (Info) text matching | Adopted the optional anchor `"description":"<marker>`; `error_code` in `getErrorMap()` declined (touches every client-side 4xx body) | §3.5 |
| K-r3 #1 resend bypasses the CAS (S1) | **Adopted the guard**: parse `item_id=X is D`, skip if another active same-client product has SKU D, fail closed on a parse miss; D in the log; S1 corrected; AC-7h + mutant #21 | §3.5, AC-7h, S1 |
| K-r3 #2 base is 503 + Retry-After for lock waits | Corrected §6. **Kept 109** for `/rest/sku`: the OMS never retries a 503 (non-2xx → `WmsException`, only connection errors loop), while 109 drives the one reloaded resend; other `/rest` endpoints keep 503 | §3.3, §6 |
| K-r3 #3 DIVE translation text | Fixed templates; the wrapper never re-queries; AC-4c's mutant is killed because the race text has no Y | §3.3 |
| K-r3 #4 skeleton omits 109 | Fixed (also `failIfExists`, `WMS_RESYNC_MARKERS`) | §5.2 P0 |
| K-r3 #5 acceptance grep unpassable | Replaced with a global-column-form grep = 0, plus a positive control on base | §3.5 |
| K-r3 #6 4th-writer deletion untested | AC-15c + mutant #22 | AC-15c |
| K-r3 #7 AC-7f split, loop bound, 109 | Split 7f/7g/7h; the stub answers the resend with 108; both markers | §7.1 |
| K-r3 #8 mutant #9 unkillable | Recorded as **equivalent**, with evidence (single `update`, no observer) | §7.1 |
| K-r3 #9 OMS red messages missing | Table added; 7g/7h/8e/8f relabelled RG | §7.1 |
| K-r3 #10 verify row under-specified | Named constant, plain prefix (no `%Ns` stripping), red on base + rewording, symlink shadow root | Acceptance |
| K-r3 #11 AC-4d fixture | Raw tenant connection with explicit commit, own thread, row-first | AC-4d |
| K-r3 #12 inversion silently misses id-less rows | `id_missing` counted and logged | §3.5 |
| K-r3 open Q1 C1 second save | Answered: none (equivalent mutant) | §7.1 |
| K-r3 open Q2 create re-check takes over an item | Fixed: `failIfExists` on the create endpoint → `ENTITY_ALREADY_EXITS`; AC-5c + mutant #23 | §3.3, AC-5c |
| A-r3 §C docblock stale | `backfillWmsItemIds` docblock updated | §3.5 |

## Completeness checklist

| # | Check | Status |
|---|---|---|
| 1 | Every §0 row in/out with phase | ✅ |
| 2 | Every in-scope site has a §7.1 row | ✅ W1–W4, W8, W10–W10c, O1–O3, O5–O7, C1, C2, P1, P2 (both entry points: AC-15, AC-15b), R1 (AC-16 readers, AC-15c the 4th writer) (C3 by `V1ServicesControllerTest`) |
| 3 | DB facts re-measured, instruments named | ✅ §2.2 |
| 4 | Index use: prd EXPLAIN + UAT generic plan + CI pin | ✅ §3.4 |
| 5 | Deploy order fixed and both half-states analysed | ✅ §5.3 |
| 6 | Lookups client-scoped | ✅ §7.6 #3 |
| 7 | Rename/CAS/collision/rewrite in `upsertAll`, ordered | ✅ §3.3, AC-11 |
| 8 | `finally` eviction kept | ✅ |
| 9 | `recordSeen` NULL guard | ✅ AC-7c |
| 10 | All OMS producers of a duplicate handled (3 callers, sync, batch) | ✅ C1–C3, P2, O7 |
| 11 | Known gaps with owner and detection | ✅ G1–G7, §11 |

## Acceptance

Done means: every §7.1 row green in CI lanes (PG via failsafe) · each RF row has a recorded red-on-base message and every row a recorded red mutant · both full suites match their baseline · M-1…M-7 pass, M-5 pasted into the PR · both PRs open into `develop` · one independent review per repo, every finding fixed.

**Verify script (K-r2 #8):** r2's 3 rows are **dropped**. They asserted implementation shape (`.put("item_ids",`, `'facility_item_id' =>`), duplicated AC-7a/AC-8a, and one already matched base. **One row is kept**, because it covers an invariant that no test in either repo can see. `verify-SBDEV-2624.sh` (from `verify-plan-template.sh`), `PROJECT_ROOT` = monorepo root `owl/`:
1. Extract the description literals of `case SKU_RENAME_PRECONDITION_FAILED:` and `case SKU_CONCURRENT_MODIFICATION:` from `v2/wms2-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java`, and the array elements of `WMS_RESYNC_MARKERS` from `v2/oms-laravel-api/app/Services/WmsApiService.php`. Assert each marker is a **plain prefix** of its wms2 literal. No `%Ns` stripping (K-r3 #10): the markers end before the first placeholder, and stripping would mishandle a `%1$s` form.

- **Fails closed** if either literal or the constant is not found.
- Shown red **twice**: on base (fail-closed branch), and on a shadow copy with a one-word rewording of the wms2 text (the narrowed-pattern branch a literal check otherwise cannot detect).
- `PROJECT_ROOT` = a **symlink shadow root** holding both ticket worktrees at `v2/wms2-api` and `v2/oms-laravel-api` (recipe in `wms-plan-executor`), never the main checkouts.

## ADR

| Field | Content |
|---|---|
| **Decision** | Rename `itemdata.item_nr` in place. wms2 resolves by a per-facility, client-scoped `facility_item_id` → `previous_sku` → `sku` → create; a compare-and-set precondition whenever `previous_sku` is present; collision → 422 naming both ids; `stockrecord.itemdata` rewritten **before** the itemdata write, in the same tenant tx; every write flushed inside the translation wrapper (lock/optimistic → 109). Create/update return `item_ids` read from the **returned** entity; the OMS records them per facility, never nulls a known id, stops sending and reading the global `item_id`, resends once (DB-reloaded, id required, bad-map-guarded) on 108/109; facility sync and backfill report drift instead of pruning or creating a twin |
| **Drivers** | (1) No silent data corruption on prd · (2) one id keeps stock, orders and history together · (3) no migration; a safe deploy order with independent rollback |
| **Alternatives** | A1–A8 (§9) |
| **Why chosen** | The only option that keeps every FK-linked row and the transaction reports attached with no schema change. The id survives repeated edits after a failed rename, and the drift report stops sync re-creating the twin; `previous_sku` + CAS covers renames before any id is known and rejects out-of-order ones |
| **Consequences** | Longer tx on hot WineCo SKUs, with the child-FK-blocking lock held only briefly · repeated 422s for existing duplicates until D3 · create/update answer 200 · gaps G1–G7 remain · a stockrecord rewrite is undone only by a reverse rename |
| **Follow-ups** | Same-tx second stockrecord pass if the orphan query is ever non-zero twice (§6 G6) · D3 cleanup (proposal) · Q5 with Joe · OMS pending-rename store if S2's fingerprint stays > 0 · `(client_id, lower(itemdata))` index ticket if M-5 fails · optionally drop `product.wms_item_id` · SBDEV-2623 (v1) closed 2026-10-02 |
