---
title: "SKU rename in place: OMS→WMS sync resolves by per-facility id, then previous SKU, then SKU; renames itemdata and stockrecord in one tx"
ticket: "SBDEV-2624"
ticket_url: "https://app.clickup.com/t/868keq71z"
type: "feature"
priority: ""
status: "pending approval"
tier: T3
repos: [wms2-api, oms-laravel-api]
project: ["wms2"]
version: "v2"
target_version: v2
requester: "Nam Park"
created: "2026-10-02"
updated: "2026-10-02"
revision: "r1 — planner draft for ralplan round 1 (DELIBERATE mode)"
db_verified: true
db_verified_note: "Read-only, 2026-10-02. wsl-wineco-prd: indexes, EXPLAIN of the rewrite predicate, hot-code row count, create-on-update fingerprint, 30-day stockrecord pair-join check. nywh-hydra-prd, c1wh-shipitez-prd (wh01_shipitez_v2), nywh-shipitez-prd (wh02_shipitez_v2): uk3l3dgof3l6mc1dl7s3lmida65 and the stockrecord index set. UAT not checked (MCPs down)."
base_commit: "wms2-api 62c92dd5 (origin/develop); oms-laravel-api 55f5f93c (origin/develop)"
branches:
  wms2-api: "feature/SBDEV-2624-sku-rename-in-place (off origin/develop)"
  oms-laravel-api: "feature/SBDEV-2624-facility-item-id (off origin/develop)"
related:
  - "[[SBDEV-2024]]"            # parent
  - "[[SBDEV-2025]]"            # spike, folded into this plan
  - "[[SBDEV-2623]]"            # v1 twin, PARKED: no client on wms v1
  - "[[260610-wms2-sku-trim-normalization]]"   # archived; its §10 deferred this work
  - "[[SBDEV-3135]]"            # finally-eviction on all /rest/sku handlers
  - "[[SBDEV-2681]]"            # product_wms_item existence map
  - "[[SBDEV-2624-evidence/analysis]]"
tags:
  - plan
---

# SBDEV-2624 — SKU rename in the OMS creates a second WMS item instead of renaming the first

**Ticket:** [SBDEV-2624](https://app.clickup.com/t/868keq71z) · **Tier:** T3 (data integrity on prd, two repos, a historical-table rewrite) · **Mode:** ralplan DELIBERATE
**Evidence bundle (authoritative):** `SBDEV-2624-evidence/analysis.md`. This plan cites it as "bundle §N". Where this plan contradicts the bundle, it says so and gives the instrument.

---

## 0. Affected sites

**Method:** the bundle §0 sweep (`git grep -nE "findByClientIdAndItemNr|findByItemNr|findByClientNumberAndSkuSet|loadItemDataSet"` over wms2 `src/main`, plus the OMS call-site greps), re-run at the `base_commit` SHAs for every in-scope row. Row W10 is new to this plan.

| # | Site | Scope | Phase |
|---|---|---|---|
| W1 | `SkuRestController.create` (`@PutMapping(value = "/create"`) | **IN**: return `200 {"status":"success","item_ids":{sku:id}}` instead of 204 | P1 |
| W2 | `SkuRestController.update` (`@PostMapping(value = "/update"`) — the defect site | **IN**: resolve facility_item_id → previous_sku → sku; return ids | P1 |
| W3 | `SkuRestController.delete` (`@DeleteMapping(value = "/delete"`) | **IN** (Q4): resolve facility_item_id (client-scoped) → sku | P1 |
| W4 | `SkuBatchCreateUpdateService.upsertAll` | **IN**: rename, collision check, stockrecord rewrite, return ids — all in its tenant tx | P1 |
| W5 | `ItemdataService.findByClientIdAndItemNr` (`@Cacheable … ':' + #clientId + ':' + #itemNr`) | OUT (unchanged; still used for steps 2–3 of the lookup) | — |
| W6 | `ItemdataService.getById` (`':id:' + #id`) | OUT (not used by the new path; stale `:id:` entries on other replicas = Q5 gap) | — |
| W7 | `evictItemdataCache()` from `finally` in all three handlers | **IN, keep as is** (SBDEV-3135). No new eviction code | P1 |
| W8 | `SkuDto` | **IN**: add `facility_item_id` (Long) and `previous_sku` (String), additive | P1 |
| W9 | `Itemdata.setItemNr` (`itemNr.trim()`) | OUT (rename inherits trimming) | — |
| W10 | `StockrecordRepository` (`@RepositoryRestResource(... exported = false)`) | **IN** (Q1): new `@Modifying` native `renameItemdataForClient` | P1 |
| W10b | `ItemdataRepository` | **IN**: new `Optional<Itemdata> findByIdAndClientId(...)`, `@RestResource(exported = false)` | P1 |
| W11 | Inbound lookups by (client, code) — `AdviceRestController`, `StockCountRestController`, `TransactionReportRestController`, `ReceivingService`, `ReplenishorderService`, `ReturnAdviceAutoReceiveService`, `MobileReplenishService`, `FileImportController`, `StockrecordService` | OUT. A message carrying the old code after the rename fails `ENTITY_DOES_NOT_EXISTS` (bundle §2 class c) — known gap, §6 | — |
| W12 | `findByItemNr` lookups ignoring the client (`ItemDataController`, `ViewDtoService`, `MobileInfoService`) | OUT, pre-existing hazard, not 2624 | — |
| W13 | `OrderRestController` → `findByClientNumberAndSkuSet` (uncached) | OUT (sees a rename immediately on every replica) | — |
| O1 | `WmsApiService::updateSkuFromProduct` | **IN**: signature `(Product $product, ?string $previousSku = null)`; per-facility payload; record ids | P2 |
| O2 | `buildSkuDataFromProduct` (`$data['item_id'] = (int) $product->wms_item_id;`) | **IN**: delete the global `item_id` | P2 |
| O3 | `updateSku` / `createSku` → `buildSkuPayload` (`$payload['facility_code'] = $facility;`) | **IN**: per-facility `facility_item_id`, `previous_sku`, `request_nonce` added here | P2 |
| O4 | `getAllWmsFacilities` (broadcast to every facility) | OUT (unchanged; a full miss still creates — AC-5) | — |
| O5 | `createSkuFromProduct` (reads `$responseData['item_ids']`) | **IN**: no code change needed for the read; benefits once W1 returns ids. Stop writing the global `product.wms_item_id` | P2 |
| O6 | `deleteSkuFromProduct` / `deleteSku(..., ?int $itemId)` | **IN** (Q4): send per-facility `facility_item_id`, never `item_id` | P2 |
| C1 | `ProductController` (`$previousIdentity = [` … before the write) | **IN**: pass previous SKU when the SKU changed and the client did not (Q2) | P2 |
| C2 | `LegacyV2ProductController` (`$updateData['product_sku'] = $request->input('SKU');`, then `updateSkuFromProduct($updatedProduct)`) | **IN**: capture `$product->product_sku` BEFORE `productRepository->update` (fresh-copy trap) | P2 |
| C3 | `V1ServicesRestController` (field map cannot rename) | **IN** (call stays one-arg; passes null implicitly) — test only | P2 |
| P1 | `ProductWmsItem::recordSeen` (`upsert(..., ['product_id','facility_code'], ['wms_item_id','last_seen_at'])`) | **IN**: never overwrite a non-null id with NULL | P2 |
| P2 | `WmsFacilitySyncService` reconcile/backfill (match by `product_sku`) | OUT (unchanged; still the backfill source of ids) | — |
| P3/P4 | `BatchProcessingService` existence readers; migration `2026_07_23_100000` | OUT (no schema change; existence semantics unchanged) | — |

---

## 1. Problem

Rename A→B for client c at facility F, where (c, A) exists (bundle §1):

1. The OMS posts `[{sku: B, item_id: <FIRST facility's id>, facility_code: F, …}]` to `POST /rest/sku/update`.
2. wms2 drops `item_id` (`WebConfigurer`: `mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);`).
3. `SkuRestController.update` looks up the NEW code — `itemdataService.findByClientIdAndItemNr(client.getId(), sku.getSku())` — misses, and `upsertAll` creates: `if (existing == null) { Itemdata itemData = new Itemdata(); itemData.setItemNr(sku.getSku());`.
4. (c, A) keeps its stock, open orders and putaway settings; (c, B) is an empty twin. `UNIQUE (client_id, item_nr)` does not fire, because (c, B) did not exist.

Second defect on the return leg: wms2 returns `204` with no body (`return ResponseEntity.status(HttpStatus.NO_CONTENT).body(...)` — a 204 carries no body on the wire), so the OMS's `if (!empty($responseData['item_ids']))` in `createSkuFromProduct` never fires and `recordSeen` writes `wms_item_id => null`, overwriting any id a reconcile had stored (bundle §5).

---

## 2. Current architecture and DB evidence

### 2.1 Code path today (origin/develop 62c92dd5)

- **Controller (outside any tx):** validates, resolves the client by `clientRepository.findByClNr(...)`, fills `existingByClient.get(client.getId()).put(sku.getSku(), itemdata)` from the cached lookup, then calls `skuBatchCreateUpdateService.upsertAll(...)`. `finally { evictItemdataCache(); }` clears the whole `itemdata` Caffeine cache on every exit (SBDEV-3135 comment: "an exception can escape AFTER upsertAll has COMMITTED, and @CacheEvict fires only on a NORMAL return").
- **`upsertAll`** is `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`, returns `void`, and its update branch never touches `itemNr`.
- **Errors:** a `WebserviceBusinessExceptionClientSide` becomes `422` with `e.getErrorMap()` = `{status: "failure", description: <getErrorCodeText(code, params)>}`. `NOT_UNIQUE_VALUE = 105` renders `"duplicate value %1s found in %2s"` (`WmsConstants`). Note `%1s` is width-1, not positional; parameters bind in order.
- **`Itemdata`** extends `AbstractBaseEntity`, which carries `@Version`.
- **OMS response handling:** `processWmsResponse` maps a 204 to `'data' => []`, and a JSON 2xx to `'data' => $responseData['data'] ?? $responseData`. So a top-level `item_ids` in a 200 body lands at `$results[$f]['response']['data']['item_ids']`, which is exactly what `createSkuFromProduct` reads. `isFailureResponse` only checks `status === 'failure'`, so 200 and 204 are both success.
- **Idempotency:** `IdempotencyFilter` keys `/rest/**` writes on `SHA-256(method|path|body)` with 7-day retention and replays a cached 2xx. The OMS sends no `Idempotency-Key` (`git grep -n "Idempotency-Key"` over OMS `app/` = 0 hits). **New finding F-1:** a rename A→B, then B→A, then A→B within 7 days sends a byte-identical third body. The filter replays the first response and the rename is silently dropped. Field-value reverts on plain updates have the same hazard today. §3.6 fixes it in the OMS.

### 2.2 DB evidence (read-only, 2026-10-02)

| Fact | Instrument | Result |
|---|---|---|
| `UNIQUE (client_id, item_nr)` live | `pg_indexes` on 4 prd tenants (wsl-wineco-prd, nywh-hydra-prd, wh01_shipitez_v2, wh02_shipitez_v2) | `uk3l3dgof3l6mc1dl7s3lmida65 … (client_id, item_nr)` on all 4. **Archived plan 260610 §3 ("no unique index") is false**; UAT unchecked |
| stockrecord indexes | same query, same 4 DBs | All 4 have the identical set, including `index_stockrecord_itemdata … (lower((itemdata)::text))` and `index_stockrecord_client_id (client_id)`; none has (client_id, itemdata) |
| stockrecord size, WineCo prd | `count(*)` / `pg_total_relation_size` | **7,499,593 rows, 2,936 MB** (Hydra prd 4,237 per bundle) |
| Hottest code, WineCo prd | `pg_stats.most_common_vals` → exact count | `'WCI PC'` (client 146701): **44,251 rows**. This is the worst-case rewrite size for one rename |
| Rewrite predicate uses the index | `EXPLAIN SELECT id FROM stockrecord WHERE lower(itemdata) = lower('WCI PC'::varchar) AND itemdata = 'WCI PC'::varchar AND client_id = 146701::bigint` | `Bitmap Index Scan on index_stockrecord_itemdata` ∧ `index_stockrecord_client_id`, Filter `itemdata = 'WCI PC'`, **cost 10,817** |
| Same without `lower()` | `EXPLAIN … WHERE itemdata = 'WCI PC' AND client_id = 146701` | Parallel bitmap heap scan of **662,727** client rows, **cost 222,033** (20× worse). This corrects bundle §2: with the client filter it is not a 7.5M-row seq scan, but it is still a heap read of the client's whole history inside the SKU tx |
| `EXPLAIN UPDATE` | MCP | Refused ("Error validating query"); the SELECT twin shares the predicate, so it is the proxy. §7.3 M-5 re-runs it on UAT with a writable session |
| Pair join lossless today | `count(*)` stockrecord rows from the last 30 days with no `(client_id, item_nr)` match in itemdata, WineCo prd | **0** (Hydra prd, all time: 0 of 4,237, bundle §2) |
| Create-on-update rows, WineCo prd | itemdata rows created within ±1 min of a `SKU_UPDATE` message whose payload has `"sku":"<item_nr>"`, with no `SKU_IMPORT` in that window | **264** with my window (Nam's figure **270** came from a slightly different window; same order). By year: 2019 4 · 2020 55 · 2021 131 · 2022 24 · 2023 9 · 2024 41 · 2025–26 **0** |
| Rename signature | Of those, rows with an older same-client item having the same `lower(trim(name))` and a different `item_nr` | **13** (reproduces Nam's 13) |
| Existing duplicate candidates | bundle §3 name-match query | 78 pairs Hydra prd, 323 WineCo prd (upper bound) |

WineCo's v2 cutover was 2026-09-26, so the 0 for 2025–26 covers only a few v2 days. It is not evidence that the bug is dormant on v2: the code path in §2.1 is unchanged.

### 2.3 Blast radius of renaming `item_nr` (bundle §2, summarised)

- **By id, safe:** 8 FK tables, `itemdata.putawaylocation_id`, and 10 views that join by id.
- **By text, stale:**
  - `stockrecord.itemdata` is fixed here (Q1). It feeds `stock_history()`, `transaction_detail()`, `transaction_summary()` and `stockrecord_view`. A live `pg_proc` scan found exactly those three functions.
  - `inventory_record` is a known gap.
  - `message`, outbox and `rest_idempotency` payloads are known gaps.
- **Inbound by code (W11):** the OMS retry window is a known gap.

---

## 3. Design

### 3.1 Contract (additive)

`SkuDto` gains two fields; the OMS payload gains three and loses one.

| Field | Dir | Type | Rule |
|---|---|---|---|
| `facility_item_id` | OMS→WMS | Long, optional | `product_wms_item.wms_item_id` for **(product, this facility)**. Absent when NULL or ambiguous (§3.5). **C1:** a new name, so neither side ever honours today's global `item_id` |
| `previous_sku` | OMS→WMS | String, optional | The SKU before this edit. Present only when the SKU changed **and** the client did not (Q2). Trimmed by `normalize()` |
| `request_nonce` | OMS→WMS | String, optional, ignored by wms2 | Fresh per logical sync call and stable across `makeWmsRequest` retries (F-1). Not declared on `SkuDto`, because `FAIL_ON_UNKNOWN_PROPERTIES=false` drops it |
| `item_id` | OMS→WMS | — | **Removed** from create, update and delete payloads |
| `item_ids` | WMS→OMS | `{ "<sku>": <id> }` | In the 200 body of create **and** update (the PR #14 shape the OMS already reads) |

### 3.2 Resolution order (C2, C3) — controller, per DTO, client already resolved

```
1. facility_item_id != null → itemdataRepository.findByIdAndClientId(id, client.getId())   // uncached, client-scoped
2. miss && previous_sku != null → itemdataService.findByClientIdAndItemNr(client.getId(), previous_sku)
3. miss → itemdataService.findByClientIdAndItemNr(client.getId(), sku)                     // today's lookup
4. miss → create (unchanged; how a facility that never had the SKU gets it)
```

- An id that belongs to another client is a miss (AC-3), never a move.
- The found row goes into `existingByClient.get(clientId).put(sku.getSku(), found)`. **C4 re-key:** the inner key stays the request's `sku`, so `upsertAll`'s `.get(sku.getSku())` is unchanged, but the value is now the row actually found by whichever step hit, not only a row whose code equals `sku`.

### 3.3 `upsertAll` (inside the existing tenant tx — C4)

The signature changes from `void` to `Map<String, Long> upsertAll(...)` (an insertion-ordered map of sku → id). For each DTO:

1. `existing == null` → create as today, then `ids.put(sku, saved.getId())`.
2. Otherwise **re-load inside the tx**: `Itemdata row = itemdataRepository.findById(existing.getId()).orElse(null)`.
   - If `null`, the row was deleted between resolution and the tx; treat it as a miss and create.
   - The rename decision and the old code come from `row`, never from the cached detached entity, because another replica may already have renamed it. This also removes the pre-existing stale-`@Version` failure on this path.
3. If `!row.getItemNr().equals(sku.getSku())` → rename (D1):
   - **a. Collision (D2):** `itemdataRepository.findByClientIdAndItemNr(clientId, sku.getSku())` goes direct to the repository, never the cache, so a cached miss cannot hide B. If it finds a row whose id differs from `row`'s → `throw new WebserviceBusinessExceptionClientSide(WmsConstants.NOT_UNIQUE_VALUE, null, "sku " + B + " (item_id=" + Y + ")", "rename of item_id=" + X + " from " + old)`. That gives a 422 whose `description` names X and Y, and `rollbackFor` rolls back.
   - **b.** `String old = row.getItemNr(); row.setItemNr(sku.getSku());`, then `itemdataRepository.saveAndFlush(row)`. A `DataIntegrityViolationException` here (a concurrent create of B between a and b) is caught and rethrown as the same 422. The tx is already rollback-only and the checked exception rolls it back.
   - **c.** `int n = stockrecordRepository.renameItemdataForClient(clientId, old, sku.getSku());` (§3.4).
   - **d.** `LOG.info("SBDEV-2624 SKU rename clientId={} itemId={} from={} to={} via={} stockrecordRows={}", …)`. Use `LOG.warn` when `via=facility_item_id` and `old` is neither `previous_sku` nor `sku` (pre-mortem S1).
4. Apply the field updates exactly as the update branch does today, then `save(row)` and `ids.put(sku, row.getId())`.

A case-only rename (`abc`→`ABC`) is a rename: `equals` is case-sensitive, and so are the constraint and the step-3 lookup.

### 3.4 stockrecord rewrite (Q1) — the SQL and the index proof

Add to `StockrecordRepository`. The interface is already `exported = false` at type level, so SDR adds no route.

```java
// SBDEV-2624 Q1. lower(itemdata) = lower(:old) is what lets index_stockrecord_itemdata
// (lower((itemdata)::text)) serve this on WineCo (7.5M rows). The exact-match conjunct keeps a
// case-only rename from touching other-case rows. Do NOT drop the lower() term: without it the
// planner reads the client's whole history (EXPLAIN 2026-10-02: cost 222k vs 10.8k).
@Modifying
@Query(value = "UPDATE stockrecord SET itemdata = :newItemNr " +
               "WHERE lower(itemdata) = lower(:oldItemNr) AND itemdata = :oldItemNr " +
               "AND client_id = :clientId", nativeQuery = true)
int renameItemdataForClient(@Param("clientId") Long clientId,
                            @Param("oldItemNr") String oldItemNr,
                            @Param("newItemNr") String newItemNr);
```

**How the plan proves the index is used** (three instruments, because each is blind somewhere):

1. **Done (§2.2):** an EXPLAIN of the SELECT twin on WineCo prd shows `Bitmap Index Scan on index_stockrecord_itemdata`. Blind spot: a SELECT, not an UPDATE, and a custom plan for literal values.
2. **Pre-merge, M-5:** on WineCo UAT, in a writable session, `BEGIN; SET LOCAL plan_cache_mode = force_generic_plan; PREPARE r(bigint,varchar,varchar) AS <the exact SQL string copied from the merged @Query>; EXPLAIN EXECUTE r(146701,'WCI PC','x'); ROLLBACK;`. This covers the generic plan pgjdbc switches to after 5 executions. Paste the output into the PR. Pass: `index_stockrecord_itemdata` appears.
3. **In CI:** `StockrecordRenameQueryShapeUnitTest` reads the `@Query` value by reflection and asserts it contains `lower(itemdata) = lower(:oldItemNr)` and `client_id = :clientId`. This pins the shape that instrument 2 proved. It is mutation-checked by deleting the `lower()` term.

**Tx cost:** worst case 44,251 rows, each a new heap tuple plus entries in the 14 stockrecord indexes (count from the §2.2 `pg_indexes` listing, WineCo prd). `git grep -niE "update\s+stockrecord"` over `src/main` and `db/migration` finds no other UPDATE, so row-lock contention is limited to a concurrent rename of the same code. The tenant `lock_timeout` (5 s per acquisition, `WMS_TENANT_LOCK_TIMEOUT_MS`) bounds waits. The duration is measured in M-5 (pass: < 10 s for 'WCI PC', against the OMS's 30 s HTTP timeout × 3 attempts).

### 3.5 OMS side

- **Signature:** `updateSkuFromProduct(Product $product, ?string $previousSku = null)`. The method trims and compares `$previousSku` with the current SKU, and sends `previous_sku` only if they differ.
  - **C1** (`ProductController`) passes `$previousIdentity['product_sku']` unless `$product->wasChanged('client_id')`, in which case it passes null (Q2: a client move creates under the new client).
  - **C2** (`LegacyV2ProductController`) captures `$oldSku = $product->product_sku;` **before** `$this->productRepository->update($product, $updateData)` and passes it. The method must not infer the old SKU from the model, because the `->fresh()` copy has lost the change set.
  - **C3** is unchanged (one argument).
- **Per-facility payload:** load the map once per call, `ProductWmsItem::where('product_id', $id)->pluck('wms_item_id', 'facility_code')`, and inside the facility loop add `facility_item_id` only when the value is non-null **and** unambiguous: `ProductWmsItem::where('facility_code', $f)->where('wms_item_id', $id)->count() === 1`. The ambiguity guard is new to this plan (pre-mortem S1). It costs one indexed count per facility.
- **Record ids:** after each successful create **or** update, `recordSeen($facility, [['product_id' => …, 'wms_item_id' => $responseData['item_ids'][$sku] ?? reset(...)]])`. `createSkuFromProduct` stops writing the global `product.wms_item_id`. The column stays, unused (SBDEV-2681: nothing reads it).
- **`recordSeen` NULL guard (C5):** split the rows. Rows with a numeric id are upserted on `['wms_item_id','last_seen_at']`; rows with a NULL id are upserted on `['last_seen_at']` only. This avoids grammar-specific `COALESCE(VALUES())` and keeps one code path for MySQL and the SQLite/MySQL test DBs.
- **Delete (Q4):** `deleteSku(string $facility, string $clientCode, string $sku, ?int $facilityItemId = null)` puts `facility_item_id` in the payload and never `item_id`. `deleteSkuFromProduct` passes the per-facility id.

### 3.6 F-1 replay guard (OMS, ~5 lines)

`buildSkuPayload` adds `'request_nonce' => $nonce`, where `$nonce = (string) Str::uuid()` is generated once per `createSkuFromProduct`, `updateSkuFromProduct` or `deleteSkuFromProduct` call and passed down. `makeWmsRequest`'s own retries reuse the same body, so a true retry still dedups. A new logical edit always has a new key. wms2 needs no change.

---

## 4. File change summary

| Repo | File | Change |
|---|---|---|
| wms2-api | `json/SkuDto.java` | + `@JsonProperty("facility_item_id") Long facilityItemId`, `@JsonProperty("previous_sku") String previousSku` |
| wms2-api | `controller/rest/SkuRestController.java` | `normalize()` trims `previousSku`; update resolution §3.2; create/update return 200 + `item_ids`; the update/create message log status → `HttpStatus.OK`; delete resolution (Q4) |
| wms2-api | `service/SkuBatchCreateUpdateService.java` | Return `Map<String, Long>`; reload by id; rename + collision + DIVE translation + stockrecord rewrite (§3.3); inject `StockrecordRepository` |
| wms2-api | `repo/jpa/ItemdataRepository.java` | + `@RestResource(exported = false) Optional<Itemdata> findByIdAndClientId(Long id, Long clientId)` |
| wms2-api | `repo/jpa/StockrecordRepository.java` | + `renameItemdataForClient` (§3.4) |
| wms2-api | tests | §7.1 |
| oms-laravel-api | `app/Services/WmsApiService.php` | §3.5/§3.6: signature, per-facility fields, nonce, drop `item_id`, record ids on update, delete id |
| oms-laravel-api | `app/Models/ProductWmsItem.php` | `recordSeen` NULL guard |
| oms-laravel-api | `app/Http/Controllers/Api/ProductController.php` | pass previous SKU (Q2 rule) |
| oms-laravel-api | `app/Http/Controllers/Api/Legacy/LegacyV2ProductController.php` | capture the old SKU before the update, pass it |
| oms-laravel-api | tests | §7.1 |

No Flyway, no OMS migration, no sysprop, no function/gate change (`/rest/**` is internal WMS↔OMS).

---

## 5. Phased plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | None. `uk3l3dgof3l6mc1dl7s3lmida65` and `index_stockrecord_itemdata` present on all 4 prd tenants (§2.2). **Check UAT + dev for both before Phase 3** | executor | UAT MCPs were down on 2026-10-02 |
| 2 | Feature flags / sysprops | N/A — the behaviour activates only when the OMS sends the new fields, which is itself the switch | — | |
| 3 | Config / env | N/A. `WMS_TENANT_LOCK_TIMEOUT_MS` unchanged | — | |
| 4 | Deploy order | **Either order is safe** (§5.3). Recommended: wms2-api first | Nam | |
| 5 | Data migration | None. D3: no duplicate cleanup; the detection query (§10) seeds a separate ticket | Nam | |
| 6 | External systems | OMS per tenant: run `SELECT facility_code, count(*), sum(wms_item_id IS NULL) FROM product_wms_item WHERE product_id<>0 GROUP BY facility_code;`. If NULLs dominate, the id path is dormant until the first create/update round trip; the previous_sku path still fixes renames | Nam / OMS DBA | Bundle §5: not measured |
| 7 | Access / permissions | N/A. No `FunctionEnum` constant; `/rest/**` is internal-only (decision 2026-08-27) | — | |
| 8 | Monitoring | Log-based only (metrics are unscraped). The `SBDEV-2624 SKU rename` INFO/WARN lines + the weekly fingerprint query (§8) | Joe (log search) | |
| 9 | Replicas / redis (Q5) | **OPEN.** Ask Joe: prd wms2 replica count; is the `redis` profile on? | Joe | Known gap §6 |

### 5.2 Phases

**P0 — TDD gate (both repos).** Create worktrees `.claude/worktrees/wms2-api/SBDEV-2624` and `.claude/worktrees/oms-laravel-api/SBDEV-2624` on the branches in frontmatter, off freshly fetched `origin/develop`. Write the failing tests for AC-1…AC-10 (§7.1). Each must fail for the right reason, e.g. AC-1 fails with "expected 1 row for client c, found 2", not with a compile error masked as red. Pause for Nam.
*Accept:* every AC test is red on the base SHA with the expected message; the full-suite baseline is recorded for both repos, taken close in time and never with Maven running concurrently.

**P1 — wms2-api.** §3.1–§3.4.
*Accept:*
- AC-1…AC-6, AC-9 and AC-10 are green.
- Every new assertion is mutation-checked (PIT on JDK 21 for `SkuBatchCreateUpdateService`; hand mutants for the SQL string and the client filter).
- The full suite matches the baseline.
- `mvn clean` before the final run, because stale `target/test-classes` can run deleted tests.

**P2 — oms-laravel-api.** §3.5–§3.6.
*Accept:* AC-7 and AC-8 are green under the Docker recipe (memory `oms-laravel-api-has-no-runnable-test-env`, throwaway MySQL only); `./vendor/bin/pint` is clean; the replaced tests are deleted, not skipped.

**P3 — Review and ship.** One `code-reviewer` lane per repo plus a `verifier` lane. Fix every finding, including Low. Run M-1…M-6 (§7.3) on dev, then on UAT. Open PRs into `develop` (wms2-api) and `develop` (oms-laravel-api). Stop at PR.
*Accept:* M-5 EXPLAIN output pasted into the wms2 PR; ClickUp moved to `pr submitted`.

### 5.3 Explicit deploy order (safe in either order)

| State | OMS old | OMS new |
|---|---|---|
| **wms2 old** | Today | OMS sends `facility_item_id` / `previous_sku` / `request_nonce`; wms2 drops them as unknown → today's behaviour. Gets 204 → `data = []` → `recordSeen(NULL)`, which the NULL guard turns into a no-op on the id. **No regression** |
| **wms2 new** | OMS sends the global `item_id` → **ignored by design (C1)**; no new fields → lookup by `sku` only = today's behaviour. Gets 200 + `item_ids`: `createSkuFromProduct` starts recording real ids; old `updateSku` ignores the body. `isFailureResponse` is false for both. **No regression** | Full fix |

- **Recommended order:** wms2-api first. Ids start flowing to OMS creates immediately, and when the OMS lands, `facility_item_id` is already populated for new SKUs.
- **Rollback:** revert either side independently and you land in one of the two safe half-states above.
- **Irreversible part:** a stockrecord rewrite that already ran stays. It is undone only by renaming back (B→A), which rewrites again.

---

## 6. Backward compatibility

**Changes:**
- `/rest/sku/create` and `/rest/sku/update` success becomes **200** with a JSON body. The previous 204 body was dropped on the wire anyway.
  - OMS v2 handles both.
  - v1 OMS (`INVENTORY/IndexController`) checks `$jsonResponse['status'] != 'success'`, so a body with `status: success` is no worse than the empty 204.
- The update message-log `statuscodeanswer` changes from "204" to "200".
- A rename onto an existing code returns **422** instead of today's silent duplicate, and instead of the 500 a raw `setItemNr` would give (D2). For the 78/323 existing duplicate candidates this repeats on every edit until the D3 cleanup (Q3, accepted).

**What does NOT change:**
- Payloads without the new fields behave exactly as today, including create-on-miss (AC-5, AC-6).
- `itemdata.id` and every FK row (stock, orders, picks, replenishment, cycle counts) follow the renamed row (D1, by construction).
- No schema change: no Flyway file in `db/migration`, no OMS migration.
- Cache mechanism: the `finally` → `itemdataCache.clear()` in all three handlers (SBDEV-3135).
- `IdempotencyFilter` and its `/rest/sku/**` replay-eviction.
- Client moves still create under the new client (Q2).
- `product.wms_item_id` column: kept, no longer written by create.

**Known gaps (documented, not fixed):**
- **G1** `inventory_record.itemdatanumber` keeps the old code (a point-in-time snapshot).
- **G2** Queued `message` / outbox / `rest_idempotency` payloads carry the old code.
- **G3** An inbound OMS message composed before the rename and delivered after it fails `ENTITY_DOES_NOT_EXISTS` on W11 sites.
- **G4 (Q5)** Other replicas, ≤5 min (Caffeine `expireAfterWrite` 5 min, `allowNullValues=true`):
  - a cached miss for B makes W11 lookups of B fail;
  - `:id:` entries show the old `itemNr`;
  - the old-code key still resolves to the renamed row.

  W13 order import is uncached and unaffected.
- **G5** A duplicate `sku` within one batch is undefined (pre-existing; the OMS sends one SKU per call).

---

## 7. Testing

### 7.1 Acceptance criteria → tests

Lane key: **PG** = `SkuRenameInPlaceIT extends BasePostgresIntegrationTest` (Testcontainers + Flyway `db/migration`, run by failsafe since SBDEV-3239). The class overrides to `@Transactional(propagation = Propagation.NOT_SUPPORTED)` with by-id cleanup, following `MoveCronConcurrencyIT`, so the real `upsertAll` commit/rollback is observed rather than a test-tx rollback. **H2** = `BaseIntegrationTest` lane. **U** = unit.

⚠ **Correction to bundle §6:** `SkuRestControllerAtomicityIntegrationTest extends BaseRollbackIntegrationTest`, which is **H2** (`jdbc:h2:mem:rollback_tenant`), not real Postgres. `transaction_detail()` and the `lower(itemdata)` index exist only on PG, so the AC-1, AC-4 and AC-10 assertions go in the new PG class.

| AC | One observable assertion | Lane | Test |
|---|---|---|---|
| AC-1 | (c,A)=X with a stockunit; POST `{sku:B, previous_sku:A}` → 200 **and** `SELECT id FROM itemdata WHERE client_id=c AND item_nr IN ('A','B')` returns exactly `[X]` with `item_nr='B'` | PG | `SkuRenameInPlaceIT.update_renameByPreviousSku_keepsRowIdAndStockunitFk` |
| AC-2 | X has code C; POST `{facility_item_id:X, previous_sku:A, sku:B}` → X.item_nr = 'B' and `count(itemdata where client_id=c)` unchanged | PG | `…update_facilityItemIdBeatsStalePreviousSku` |
| AC-3 | X belongs to client d; POST under c with `facility_item_id:X`, `sku:B` → X row byte-identical before/after (item_nr, client_id, version), and (c,B) created | PG | `…update_facilityItemIdOfOtherClient_isMiss_createsUnderRequestClient` |
| AC-4 | X=(c,A), Y=(c,B); POST `{previous_sku:A, sku:B}` → status 422 **and** body `description` contains `item_id=X` and `item_id=Y`; both rows unchanged; stockrecord for (c,A) unchanged | PG | `…update_renameOntoExistingSku_returns422NamingBothIds_nothingChanged` |
| AC-4b | A concurrent insert of (c,B) between the collision check and the flush → 422 (not 500) | U | `SkuBatchCreateUpdateServiceUnitTest.upsertAll_dataIntegrityViolationOnRenameFlush_translatedToClientSide422` |
| AC-5 | No A, no B, no id → 200 and exactly one new row (c,B) | H2 | `SkuRestControllerIntegrationTest.update_fullMiss_createsUnderClient` |
| AC-6 | (c,B) exists; POST `{sku:B}` → item_nr unchanged, `itemdataRepository.save` called on the existing id, `renameItemdataForClient` **never** called | U | `SkuBatchCreateUpdateServiceUnitTest.upsertAll_plainUpdate_neverRenamesNorRewritesStockrecord` |
| AC-7a | create and update 200 bodies have `item_ids == {"B": X}` | U | `SkuRestControllerUnitTest.create_returns200WithItemIdsBySku`, `…update_returns200WithItemIdsBySku` |
| AC-7b | OMS: an update response with `item_ids` → `product_wms_item(product, F).wms_item_id == X` | OMS Feature | `WmsApiServiceTest::it_records_item_ids_from_update_response_per_facility` |
| AC-7c | `recordSeen(F, [[p, null]])` over a stored id 77 → still 77, `last_seen_at` advanced | OMS Unit | `ProductWmsItemTest::record_seen_with_null_id_keeps_stored_id` |
| AC-8a | Product with map {F1:11, F2:NULL} → F1 payload `facility_item_id=11`; F2 payload has no `facility_item_id` key | OMS Feature | `WmsApiServiceTest::it_sends_facility_item_id_per_facility_and_omits_null` |
| AC-8b | No SKU payload (create/update/delete) contains the key `item_id` | OMS Feature | `WmsApiServiceTest::it_never_sends_global_item_id` (replaces `it_includes_item_id_in_sku_data_when_product_has_wms_item_id` and `it_includes_item_id_in_delete_payload`) |
| AC-8c | `previous_sku` present iff it differs from the trimmed current SKU | OMS Feature | `WmsApiServiceTest::it_sends_previous_sku_only_when_sku_changed` |
| AC-8d | C2 rename A→B → the WMS payload has `previous_sku: A` (fresh-copy trap) | OMS Feature | `tests/Feature/Api/Legacy/LegacyV2ProductWmsSyncTest::it_passes_pre_update_sku_on_rename` (new file) |
| AC-8e | C1 client move + rename → no `previous_sku` | OMS Feature | `ProductControllerTest::it_sends_no_previous_sku_on_client_move` |
| AC-8f | Two map rows at F with the same id → `facility_item_id` omitted | OMS Feature | `WmsApiServiceTest::it_omits_facility_item_id_when_ambiguous_at_facility` |
| AC-8g | Two separate `updateSkuFromProduct` calls → different `request_nonce`; retries inside one call → same | OMS Feature | `WmsApiServiceTest::it_sends_a_fresh_request_nonce_per_sync_call` |
| AC-9 | Same JVM: after a rename A→B through the controller, `itemdataService.findByClientIdAndItemNr(c,'B')` returns X even though a miss for B was cached before the call, and `(c,'A')` is empty | H2 | `CacheEvictionOnWriteUnitTest.update_rename_evictsCachedMissForNewCode` (Spring cache in context) |
| AC-10a | After a rename, `SELECT count(*) FROM stockrecord WHERE client_id=c AND itemdata='A'` = 0 and `…='B'` = the pre-rename A count; client d's rows with code A untouched; an `'a'` (case variant) row untouched | PG | `SkuRenameInPlaceIT.update_rename_rewritesStockrecordForClientExactCaseOnly` |
| AC-10b | `transaction_detail(c_nr, 'B', …)` returns the movement dated before the rename | PG | `…update_rename_transactionDetailIncludesPreRenameMovements` |
| Q4 | DELETE `{facility_item_id:X, sku:<stale>}` (client c) → X deleted; with X under client d → falls back to code, 400 if absent | U | `SkuRestControllerUnitTest.delete_resolvesByFacilityItemIdScopedToClient`, `…delete_facilityItemIdOfOtherClient_fallsBackToCode` |
| §3.4 | The `@Query` string contains `lower(itemdata) = lower(:oldItemNr)` and `client_id = :clientId` | U | `StockrecordRenameQueryShapeUnitTest.renameItemdataForClient_predicateMatchesLowerItemdataIndexAndClient` |
| SDR | `ItemdataRepository.findByIdAndClientId` is not routed | U | `ItemdataRepositoryTest.findByIdAndClientId_isNotExported` (`@RestResource(exported=false)` read reflectively) |

**Mutation checks (floor, every row):**
- Drop the client filter in `findByIdAndClientId` → AC-3 red.
- Swap the lookup order → AC-2 red.
- Collision check through the cached service → AC-4 still green on a fresh JVM, so AC-9's pre-cached-miss variant must also cover the collision. Add `…collisionCheck_ignoresCachedMissForB`.
- Remove the stockrecord call → AC-10a red.
- `client_id` condition removed from the SQL → AC-10a red on client d's rows.
- `recordSeen` back to a single upsert → AC-7c red.
- C2 passing `$updatedProduct->product_sku` → AC-8d red.

**Existing tests to keep green:** `SkuRestControllerUnitTest` (25), `SkuRestControllerAtomicityIntegrationTest` (3, including `update_paddedSkuPayload_updatesExistingTrimmedRow_withoutCreatingDuplicate`), `CacheEvictionOnWriteUnitTest` (17), `TenantCacheKeyUnitTest` (10), `IdempotencyFilterUnitTest`. The 4 SKU test classes that assert 204 for create/update (`git grep -cE "isNoContent|NO_CONTENT|204"`: Unit 4, IT 3, Atomicity 2, CacheEviction 2 hits) are updated to 200, never deleted; `IdempotencyFilterUnitTest` (2 hits) is checked for a create/update 204 fixture. The `delete` 204 stays.

### 7.2 Run

- wms2: JDK 21.
  - `mvn -Dtest=SkuBatchCreateUpdateServiceUnitTest,SkuRestControllerUnitTest,StockrecordRenameQueryShapeUnitTest test`.
  - `mvn -Dit.test=SkuRenameInPlaceIT -Dsurefire.failIfNoSpecifiedTests=false verify`. Never `-Dit.test='!X'`, which discards the pom includes.
  - Then the full suite against the baseline. `pgrep -f maven` before you debug a red.
- OMS: the Docker recipe, `php artisan test --filter='WmsApiServiceTest|ProductWmsItemTest|LegacyV2ProductWmsSyncTest|ProductControllerTest'`.

### 7.3 Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M-1 | Rename happy path | dev (wineco `dev_wh01_om1`) + OMS dev | Pick a SKU with stock; rename in the OMS product screen; query `itemdata` by the old id | Same id, new `item_nr`; WMS stock screen shows the new code on the same stock | |
| M-2 | Collision | dev | Rename P1's SKU to P2's existing code | OMS logs the WMS failure naming both ids; no WMS row changed | |
| M-3 | New facility gets catalogue | dev with 2 facilities | Edit a SKU absent at F2 | F2 creates it; OMS `product_wms_item(F2)` gets the returned id | |
| M-4 | Transaction report history | UAT wineco | Rename a SKU with history; open the transaction detail report for the new code | Movements from before the rename listed | |
| M-5 | Index + duration proof | UAT wineco (writable, inside `BEGIN … ROLLBACK`) | Generic-plan `EXPLAIN EXECUTE` per §3.4; then `EXPLAIN (ANALYZE, BUFFERS)` of the UPDATE for 'WCI PC' → `ROLLBACK` | `index_stockrecord_itemdata` in both; actual time < 10 s | |
| M-6 | Rename revert (F-1) | dev | A→B, B→A, A→B within minutes | WMS ends at B; three `SBDEV-2624 SKU rename` log lines; no replayed response | |

### 7.4 Observability

- **Logs:** `SBDEV-2624 SKU rename …` at INFO; WARN for an id-path rename from an unexpected code; the 422 is logged by the existing `catch` into `message` with `status=FAILED`, `process=SKU_UPDATE`.
- **DB:**
  - The weekly create-on-update fingerprint (§2.2 query, `created > deploy date`) should be 0.
  - `SELECT count(*) FROM message WHERE process='SKU_UPDATE' AND status='FAILED' AND message LIKE '%previous_sku%' AND created > :deploy` gives the Q3 422 rate.
  - OMS: the share of `product_wms_item` rows with a NULL id should fall over time.

### 7.5 Horizontal Scalability Validation

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | No new state | Caffeine `itemdata` is pre-existing; G4 / Q5 documents the cross-replica window |
| 2 | Connection pool math | No | Same single connection per request; the tx is longer (row 4) but holds the same one slot |
| 3 | Scheduled jobs | N/A | None added or changed |
| 4 | Long transactions | **Yes** | The rename tx includes the stockrecord rewrite (≤44,251 rows on WineCo). No external I/O inside. Measured in M-5; pass < 10 s |
| 5 | Request affinity | No | Every request resolves from the DB (the id step is uncached; the collision check is uncached) |
| 6 | Retry / idempotency | **Yes** | A retried rename re-resolves to the already-renamed row → plain update (idempotent). F-1 nonce prevents the reverse problem (a replay dropping a new edit). The filter replays cached 200 + ids, which are the correct ids |
| 7 | Tenant context | No | Synchronous, request thread only |
| 8 | Distributed lock correctness | **Yes** | Concurrent renames of one row: `@Version` on `AbstractBaseEntity`, checked at `saveAndFlush` **before** the stockrecord rewrite; the loser gets an optimistic-lock 500 and the OMS retry is idempotent. Concurrent create of B: the unique constraint, translated to 422 |
| 9 | Cache invalidation | **Yes** | The `finally` clear covers old key, new key, cached miss and `:id:` in the handling JVM (AC-9). Other replicas: G4, Q5 open with Joe |
| 10 | External notifications | No | No outbound call added; outbound DTOs built after commit pick up the new code |

### 7.6 v2 constraint checklist

| # | Constraint | Status |
|---|---|---|
| 1 | Every tenant `@Transactional` names `tenantTransactionManager` | No new annotation; `upsertAll` keeps its own; the repository `@Modifying` inherits the tenant TM from `repo.jpa` |
| 2 | No Flyway migration | None (§4) |
| 3 | Every itemdata lookup is client-scoped | Steps 1–3 and the collision check all take `client.getId()` (§3.2–§3.3); AC-3 |
| 4 | New repository methods not SDR-routed | `findByIdAndClientId` `exported=false` (pinned); `StockrecordRepository` is type-level `exported = false` |
| 5 | Business errors use the client-side exception with a real error code | `NOT_UNIQUE_VALUE` (105) via `WebserviceBusinessExceptionClientSide(int, Throwable, Object...)`; no new code needing two `WmsConstants` arms |
| 6 | Cache eviction survives post-commit throws | `finally` kept (SBDEV-3135) |
| 7 | Native SQL tested on real Postgres | `SkuRenameInPlaceIT` (PG lane) for the UPDATE and `transaction_detail` |
| 8 | No new gate / `FunctionEnum` | `/rest/**` internal-only; unchanged |

---

## 8. Rollout

1. Merge wms2-api to `develop` (a dev deploy, and Flyway runs on boot; no-op here). Check `/api/public/version` shows the SHA. Run M-1, M-3 and M-6 with the OMS still old; expect today's behaviour plus ids recorded on create.
2. Merge oms-laravel-api to `develop`. Run M-1…M-6 on dev.
3. UAT: M-4 and M-5. Paste M-5 into the PR.
4. Release and main are DevOps-owned (merge only to develop). On prd: wms2 first, then the OMS.
5. Day +1 and +7: the fingerprint query = 0 new; the 422 rate query; grep the logs for the WARN line. Any WARN → inspect the pair by hand (pre-mortem S1).
6. File the D3 cleanup ticket as a proposal for Nam, seeded with the §10 query. It is a T3 finding, so propose it, don't file it.

---

## 9. Alternatives (bundle §8)

| # | Alternative | Rejected because |
|---|---|---|
| A1 | Alias table consulted by every lookup | ~20 call sites + the cache key + a new Flyway table, and class (b) stores still go stale |
| A2 | Never change `item_nr`; add a display code | Every view, report and inbound/outbound match keys on `item_nr`: a schema-wide re-key |
| A3 | OMS deletes and recreates on rename | ~13% of SKUs are freely deletable (SBDEV-3135); where delete works it abandons stock, orders and putaway settings |
| A4 | PR #14: unscoped `findById(item_id)`, update fails on a miss | Unscoped by client (C2 violation); fail-on-miss breaks the all-facility broadcast create (AC-5) |
| A5 | Honour today's `item_id` | It is the first facility's id sent to every facility; can rename a different product of the same client — silent corruption (C1) |
| A6 | Accept the stockrecord gap (C6-ii) | Nam Q1: rewrite. The transaction reports are the stale store users notice |
| A7 | `previous_sku` only, no id contract | Viable but weaker: a later edit after a failed rename carries neither key and re-creates the duplicate (bundle §5). Kept as the fallback leg of the chosen design |

---

## 10. Open questions / resolved decisions

**Resolved (Nam, 2026-10-02):**
- **D1:** rename in place even with in-flight work.
- **D2:** a collision returns a 422 naming both ids.
- **D3:** no duplicate cleanup in this ticket.
- **Q1:** rewrite stockrecord in the same tx with an index-friendly predicate (§3.4).
- **Q2:** a client move creates under the new client.
- **Q3:** accept the 422 for existing duplicates.
- **Q4:** delete uses the same client-scoped id lookup.

**Open:**
- **Q5 (Joe):** prd wms2 replica count and whether the `redis` profile is on. Until answered, G4 stands as a documented ≤5-minute gap.
- **F-1 (for Architect/Critic):** this plan adds the `request_nonce` (§3.6) and the OMS ambiguity guard (§3.5). Neither is in the bundle. Both are sub-T3 and sit on this ticket per the findings policy. Strike them if the reviewers judge them out of scope.

**D3 detection query (read-only, for the separate cleanup ticket):**

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

The narrow 2624 fingerprint (13 rows on WineCo prd): the §2.2 create-on-update query (`SKU_UPDATE` message ±1 min of `itemdata.created`, no `SKU_IMPORT`), joined to this one.

---

## Completeness checklist

| # | Check | Status |
|---|---|---|
| 1 | Every §0 row marked in/out with a phase | ✅ |
| 2 | Every in-scope site has a test row in §7.1 | ✅ W1–W4, W8, W10, W10b, O1–O3, O5, O6, C1, C2, P1 (C3 by `V1ServicesControllerTest` regression) |
| 3 | DB facts re-measured, not copied (§2.2 instruments named) | ✅ |
| 4 | Index use proven by EXPLAIN on a real tenant, plus a CI pin | ✅ §3.4 |
| 5 | Both deploy orders analysed | ✅ §5.3 |
| 6 | Lookups client-scoped (C2) | ✅ §7.6 #3 |
| 7 | Tx boundary: rename, collision, rewrite in `upsertAll` (C4) | ✅ §3.3 |
| 8 | `finally` eviction kept (SBDEV-3135) | ✅ |
| 9 | `recordSeen` NULL guard (C5) | ✅ AC-7c |
| 10 | All 3 OMS update callers handled, including the C2 fresh-copy trap | ✅ AC-8d/8e |
| 11 | Known gaps listed with owners | ✅ §6 G1–G5, Q5 |

## Acceptance

Done means:
- AC-1…AC-10 plus the Q4, §3.4 and SDR rows are green in CI lanes (PG via failsafe), each with a recorded red-on-base and a mutant that turns it red.
- Both full suites match their baseline.
- M-1…M-6 pass, with M-5 pasted into the PR.
- Both PRs are open into `develop`.
- One independent review per repo, with every finding fixed.

**Verify script:** recommended, **4 rows, opt-in**, at `sbdocs/9-System/scripts/verify-SBDEV-2624.sh` (from `verify-plan-template.sh`). Only cross-repo string contracts that no single-repo test can see:
1. The wms2 `SkuDto` has `@JsonProperty("facility_item_id")` **and** the OMS `WmsApiService.php` emits `'facility_item_id'`.
2. The same pairing for `previous_sku`.
3. wms2 `SkuRestController` puts `"item_ids"` **and** the OMS reads `['item_ids']`.
4. Negative: the OMS `buildSkuDataFromProduct` and `deleteSku` bodies (awk-scoped) contain no `'item_id'`.

All 4 must be shown red on the base SHAs before use. Everything behavioural stays in JUnit/PHPUnit.

## ADR

- **Decision:** rename `itemdata.item_nr` in place.
  - wms2 resolves the request by a new per-facility, client-scoped `facility_item_id`, then `previous_sku`, then `sku`, else creates.
  - It checks collisions (422 naming both ids), renames, and rewrites `stockrecord.itemdata` for (client, old) in the same tenant tx.
  - Create and update return `item_ids`; the OMS records them per facility without ever nulling a known id, and stops sending the global `item_id`.
- **Drivers:**
  1. No silent data corruption on prd (wrong-row rename, duplicate rows).
  2. Keep stock, orders and history attached to one id.
  3. Safe in either deploy order with no migration.
- **Alternatives:** A1–A7 (§9).
- **Why chosen:**
  - It is the only option that keeps every FK-linked row (8 tables) and the transaction reports attached.
  - It needs no schema change.
  - The new field name makes old and new peers mutually inert.
  - The two keys cover each other: the id survives repeated edits after a failed rename, and `previous_sku` works before any id is known.
- **Consequences:**
  - A rename holds a longer tx on WineCo (≤44k stockrecord rows).
  - Existing duplicates produce repeated 422s until D3.
  - Create/update now answer 200.
  - Gaps G1–G5 remain.
  - The stockrecord rewrite is undone only by a reverse rename.
- **Follow-ups:**
  - D3 duplicate cleanup ticket (proposed, not filed).
  - Q5 answer from Joe; if multi-replica Caffeine, a ticket for cross-replica eviction or Redis.
  - SBDEV-2623 v1 stays parked.
  - Optional: drop `product.wms_item_id` once nothing writes it.
