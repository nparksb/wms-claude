<!-- analysis lane output, wms2-api origin/develop 62c92dd5, oms-laravel-api origin/develop 55f5f93c, 2026-10-02 -->
# SBDEV-2624 — analysis bundle

**The stated root cause is confirmed, and three facts change the design.**

1. **Confirmed.**
   - `SkuRestController.update` looks up the item by the NEW code: `itemdataService.findByClientIdAndItemNr(client.getId(), sku.getSku())`.
   - `SkuBatchCreateUpdateService.upsertAll` creates a row when that misses: `if (existing == null) { Itemdata itemData = new Itemdata(); itemData.setItemNr(sku.getSku());`.
   - `SkuDto` has no key field. Its fields are `sku, client_id, box_id, image_filename, sku_name, bottle_size, unit_identifier_id, vintage, varietal, wine_type`, plus `facility_code` inherited from `AbstractWebServiceDto`.

2. **New: the OMS already sends a key, and wms2 silently throws it away.**
   - `buildSkuDataFromProduct` does `if ($product->wms_item_id) { $data['item_id'] = (int) $product->wms_item_id; }`.
   - wms2 ignores unknown JSON fields: `WebConfigurer` sets `FAIL_ON_UNKNOWN_PROPERTIES, false`.
   - It is also **the wrong key to honour**. `product.wms_item_id` is one global column holding the first facility's id (`if ($firstItemId !== null && $product->wms_item_id === null) { $product->wms_item_id = $firstItemId;`), but it is sent to every facility. Each facility is a separate database with its own id numbering.

3. **New: there was a prior attempt.**
   - Branch `origin/feat/sku-item-id-sync` (PR #14, commits `52266733` and `97aa4ea5`, 2026-05-14) was never merged.
   - It added `item_id` to `SkuDto`, and `item_id` to `StockCountDto` for stock-count exports.
   - It looked the item up with `itemdataRepository.findById(sku.getItemId())`, which is **not limited to the client**.
   - It made update fail instead of creating, and it returned `item_ids`.
   - The OMS code that reads `$responseData['item_ids']` in `createSkuFromProduct` was written against that branch. wms2 never returns `item_ids`: `git grep '"item_ids"'` over wms2 `src/main` finds 0 hits, while the same string does appear in the OMS `WmsApiService.php`. So **the OMS create path never learns an id**.
   - The archived plan 260610 §10 deferred exactly this work: "`item_id` 1:1 contract + no-upsert-on-update … deferred until an OMS-side ticket exists".

## §0 Affected sites (found by `git grep` on origin/develop)

**Method:** `git grep -nE "findByClientIdAndItemNr|findByItemNr|findByClientNumberAndSkuSet|loadItemDataSet"` over `src/main`.
**Blind spot:** native SQL that filters on `item_nr` without using these method names. §2 covers that with a separate grep and a database scan.

**wms2 sites**

| # | Site | What it does with the code | Role in 2624 |
|---|---|---|---|
| W1 | `SkuRestController.create` (`@PutMapping(value = "/create"`) | `findByClientIdAndItemNr(...).isPresent()` → 422 `ENTITY_ALREADY_EXITS` | Logic unchanged, but it must **return the created id** so the OMS can record it |
| W2 | `SkuRestController.update` (`@PostMapping(value = "/update"`) | Looks up by the new code, then stores the result in `existingByClient` keyed by `sku.getSku()` | **The defect site** |
| W3 | `SkuRestController.delete` (`@DeleteMapping(value = "/delete"`) | Looks up by code. The OMS `deleteSku(..., ?int $itemId)` also sends an `item_id` that is ignored | Sibling of the defect (Q4) |
| W4 | `SkuBatchCreateUpdateService.upsertAll` (`@Transactional(value = "tenantTransactionManager", rollbackFor = {...})`) | `.get(sku.getSku())`; the update branch never changes `itemNr` | Where the rename and the collision check belong (inside the transaction) |
| W5 | `ItemdataService.findByClientIdAndItemNr`, `@Cacheable` key `…+ ':' + #clientId + ':' + #itemNr` | Trims the argument but builds the cache key from the raw one | Cache (§4) |
| W6 | `ItemdataService.getById`, `@Cacheable … ':id:' + #id` | Caches the whole entity, including `itemNr` | After a rename, other replicas show the old `itemNr` for up to 5 minutes |
| W7 | `evictItemdataCache()`, called from `finally` in all three handlers | `itemdataCache.clear()` | Already evicts both old and new keys, but only in the JVM that handled the request |
| W8 | `SkuDto` | No key field | Add `previous_sku` and a per-facility id field |
| W9 | `Itemdata.setItemNr` | `itemNr.trim()` | A rename gets trimming for free |
| W11 | Inbound lookups by (client, code): `AdviceRestController:405,670`, `StockCountRestController:81`, `TransactionReportRestController:230`, `ReceivingService:241,293`, `ReplenishorderService:94`, `ReturnAdviceAutoReceiveService:416`, `MobileReplenishService:469,931,1052`, `FileImportController:388,464`, `StockrecordService:663` | Resolve by the current code | Class (c) in §2 |
| W12 | Lookups that ignore the client (`findByItemNr`): `ItemDataController:219` (`.get(0)`), `ViewDtoService:1361`, `MobileInfoService:113,270` | Take the first match across all clients | Pre-existing hazard, not part of 2624 |
| W13 | `OrderRestController:400` → `findByClientNumberAndSkuSet` | Order import by code; goes straight to the repository, **not cached** | Class (c). Sees a rename immediately on every replica |

**OMS sites**

| # | Site | Snippet / behaviour | Note |
|---|---|---|---|
| O1 | `WmsApiService::updateSkuFromProduct` | Builds one `$skuData` and sends it to every facility in a loop | No per-facility key is possible today |
| O2 | `buildSkuDataFromProduct` | Sends the global `item_id` | Wrong per facility (C1) |
| O3 | `updateSku` → `buildSkuPayload` | `$payload['facility_code'] = $facility` | The place to add per-facility fields |
| O4 | `getAllWmsFacilities` | `WmsUrlLut::orderBy('facility_code')->pluck('facility_code')` | Sends to every facility, including ones that never had the SKU |
| O5 | `createSkuFromProduct` | Looks for `item_ids` in the response (never there), then calls `ProductWmsItem::recordSeen` with `wms_item_id => null` | Writes NULL ids |
| O6 | `deleteSkuFromProduct` | Sends the global `wms_item_id` | Same problem as O2 |

**The three update callers and the per-facility map**

| # | Site | Behaviour | Note |
|---|---|---|---|
| C1 | `ProductController:829` | `$previousIdentity = ['product_sku' => …, 'client_id' => $sourceClientId]`, computed before the write, every time | Can rename **and** move the product to another client |
| C2 | `LegacyV2ProductController:640` | Can rename via `$updateData['product_sku'] = $request->input('SKU')`, but passes a `->fresh()` copy (`ProductRepository::update`: `$product->update($data); return $product->fresh();`) | Computes no previous SKU, and the fresh copy has lost `getPrevious()`/`wasChanged`. The caller must capture the old SKU before the update |
| C3 | `V1ServicesRestController:162` | Its field map is `productName, shortDescription, longDescription, retailPrice, wineVintage, pctAlcohol, wineVineyard, wineCOLA` | **Cannot rename.** Only needs the id key |
| P1 | `ProductWmsItem::recordSeen` | `upsert(..., ['product_id','facility_code'], ['wms_item_id','last_seen_at'])` | **Overwrites a known id with NULL** |
| P2 | `WmsFacilitySyncService` (`reconcileSkus`, `backfillWmsItemIds`, `backfillFacilityItemMap`), `BackfillFacilityWmsItems{Command,Job}` | Match WMS rows to products **by the `product_sku` string** | The id is only as good as the code match |
| P3 | Readers: `presentAtFacility` / `facilityHasCoverage` in `BatchProcessingService:897,909` | Existence checks only | Nothing currently reads `wms_item_id` |
| P4 | Migration `2026_07_23_100000` | `wms_item_id` is nullable; unique on (`product_id`, `facility_code`) | — |

## §1 What happens today (rename A→B at facility F, where A exists)

1. The OMS posts `{sku: B, item_id: <first facility's id>, facility_code: F}`.
2. wms2 drops `item_id`.
3. The lookup for (c, "B") misses, so `upsertAll` inserts a new row (c, B).
4. Row (c, A) keeps all its stock, orders and putaway settings.

The unique constraint doesn't stop this, because (c, B) didn't exist yet.

## §2 Blast radius of renaming `item_nr` in place

**How this was derived — two instruments:**
- **Source:** an awk scan of string columns named like itemdata/item_nr/sku/itemnumber/article/product in `CREATE TABLE` blocks of `V2.2.00__base_v2_schema.sql`, plus `git grep` over the later `db/migration` and `db/v1-to-v2-onboarding` files. The later files had 0 hits.
- **Database:** the same name regex over `information_schema.columns` on hydra prd, plus a foreign-key scan for tables that reference `itemdata`.
- **Positive control:** both instruments return `itemdata.item_nr`.
- **Result:** both return the same three base-table string columns.

**Blind spots:**
- Both instruments match on column names. A code stored under an unrelated name is invisible, so JSON payload columns are listed separately below.
- Only Hydra prd was scanned for columns. WineCo prd was checked only for the constraint, indexes and row counts.

**Foreign keys (hydra prd):** 8 tables point at `itemdata(id)` through `itemdata_id`: `adviceposition`, `billoflading_position`, `customerorder_position`, `cyclecount_position`, `fix_location_assignment`, `pickingorder_position`, `replenishorder`, `stockunit`.

**Classification**
- **(a) Linked by id — safe.**
  - The 8 tables above, plus `putawaylocation_id` on itemdata itself. Open orders, picks, stock, replenishment and cycle counts all follow the row. This is why renaming in place beats creating a new row.
  - 11 views project `i.item_nr` and join by id, so they show the new code immediately: `cyclecount_dto_view`, `flowbin_monitor_view`, `lock_overview_all_view`, `lock_overview_dto_view`, `order_detail_monitor_view`, `received_dto_view`, `receiving_dto_view`, `replenishment_monitor_view`, `stock_view`, `view_warehouse_location_report`, plus `stockrecord_view`. `stockrecord_view` is the exception: it also joins `stockrecord` by code (next bullet).
- **(b) Stores the code as text — goes stale.**
  - **`stockrecord.itemdata`** is `varchar` with no foreign key. It is written by `StockrecordService` (7 sites, `rec.setItemdata(…getItemNr())`) and `StockunitBusinessService:152`. A rename **detaches the history from the item**. It is joined by code in:
    - `stock_history()`: `ON received_recordset.itemdata = sv.item_nr` (V2.2.07)
    - `transaction_detail()`: `i.item_nr = sr.itemdata AND sr.client_id = c.id` (V2.2.12)
    - `transaction_summary()`: `LEFT JOIN stockrecord sr ON sr.itemdata = i.item_nr` (V2.2.00)
    - `stockrecord_view` (joins on the client+code pair, V2.2.33)
    - `StockrecordService.getDetails` (old rows lose `itemName`)
    - the adjustment-alert feed (`item.put("sku", row.getItemdata())`) and `ReportService:386`

    A live scan of `pg_proc` (`prosrc ~* 'stockrecord|sr\.itemdata'`) returns exactly `stock_history`, `transaction_detail` and `transaction_summary`.
  - **`inventory_record.itemdatanumber` and `clientnumber`** are point-in-time snapshots. `client_id` is 0 ("System") on hydra prd. Nothing in `src/main` reads it except the SDR repository. Historically accurate, so leave it stale as a known gap.
  - **`message.payload`, outbox payloads and `rest_idempotency`** hold serialized JSON. Outbound DTOs pick up the code when they are built (`CustomerorderService:793`, `BillofladingService:610`, `SharedService:135`, `AdviceService:363`, `CancellationReversalService:908`). Messages built after the rename carry B; messages already queued carry A. This is a cross-system gap, not WMS data.
- **(c) Inbound OMS requests matched by code** (W11, W13). A request carrying A after the rename fails with `ENTITY_DOES_NOT_EXISTS` or `EntityNotFoundException`. It takes an OMS message composed before the rename and delivered after it, so the window is the OMS retry/queue delay.

**Sizes (database, 2026-10-02)**

| Table | Hydra prd | WineCo prd |
|---|---|---|
| `itemdata` | 2,814 | 10,770 |
| `stockrecord` | 4,237 | 7,499,593 |
| `inventory_record` | 241,402 | 14,493,247 |

- On WineCo prd the only index on `stockrecord.itemdata` is `index_stockrecord_itemdata (lower(itemdata))`, with no `client_id`. A plain `WHERE itemdata = :old` update can't use it, so it would scan 7.5M rows inside the SKU-update transaction. Index or matching rules on Hydra and ShipItEZ were not checked.
- **Hydra prd `stockrecord` rows with no (client, code) match: 0 of 4,237.** The pair join is lossless today. A rename that doesn't also rewrite `stockrecord` would be the first thing to break it.

## §3 Uniqueness and collisions

- **`UNIQUE (client_id, item_nr)` exists:** constraint `uk3l3dgof3l6mc1dl7s3lmida65` in V2.2.00, and live on both hydra prd and wineco prd (checked in `pg_constraint`).
  - ⚠ The archived plan 260610 §3 says "itemdata has no unique index on (client_id, item_nr) today". **That is false**; don't carry it forward.
  - ShipItEZ and UAT were not checked (the UAT MCPs were down).
- `item_nr` on its own is not unique: the V2.2.33 header records "71 item_nr STRINGS are shared between shippers" on dev. Every lookup has to stay limited to the client, **including the new id lookup**.
- The constraint and the lookup are case-sensitive, so a rename that only changes case (`abc`→`ABC`) is allowed.
- **Collision:** if the target (c, B) already exists, `setItemNr(B)` hits `DataIntegrityViolationException`. That isn't the client-side business exception the handler catches, so it escapes as a 500. Per Nam's decision D2, check first inside `upsertAll` and return a 422 naming both ids. The batch is all-or-nothing, but the OMS sends one SKU per call per facility.
- **Likely existing duplicates** (same client, same trimmed lowercase name, different `item_nr`): **78 pairs on hydra prd, 323 on wineco prd.** This is an upper bound, because genuine same-name variants are counted too. A read-only detection query to start the separate cleanup ticket:

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

To sharpen it: a `SKU_UPDATE` RECEIVED row in the WMS `message` log for `newer_nr`, close to `newer_created`, is the 2624 fingerprint. A `SKU_IMPORT` row means a genuine create. Not run, because a `LIKE` over `message` payloads is heavy on prd.

## §4 Cache

- **Keys:** `<tenant>:<clientId>:<itemNr>` and `<tenant>:id:<id>`; both hold the full entity.
- **Misses are cached too.** `CaffeineCache(name, cache)` keeps Spring's default `allowNullValues=true`, so an empty lookup is stored for the TTL. Settings: 3000 entries, `expireAfterWrite` 5 minutes.
- **What a rename must evict:** the old-code key, the new-code key (it may hold a cached miss) and the `:id:` key.
  - The existing `finally` → `clear()` already covers all three in the handling JVM, so no new eviction code is needed as long as the rename stays inside `update()`.
  - Other evictors are `SdrCacheEvictionEventHandler` and `IdempotencyFilter`.
- **Multiple replicas:** Caffeine is per-JVM. `wms2-caching-strategy.md` already records this gap: "A write on replica A does not invalidate replica B's cache".
  - A Redis cache exists behind `@Profile("redis")`, but nothing in the repo shows it switched on: the only `profiles.active` hit is a commented-out `#ENV SPRING_PROFILES_ACTIVE=wineco` in the Dockerfile. Deploy config lives outside the repo, so this is **unknown; ask Joe**.
  - On another replica, for up to 5 minutes after a rename:
    - **Old-code key:** still resolves to the (now renamed) row. Harmless, even helpful for class (c).
    - **Cached miss for B:** if B was looked up before the rename, inbound requests with B fail with `ENTITY_DOES_NOT_EXISTS`.
    - **`:id:` entries:** return the old `itemNr`.
    - **Stale version on save:** cached detached entities are fed to `save()`, so a second edit routed there within 5 minutes can fail with an optimistic-lock error. This one is pre-existing.
  - Order import (W13) bypasses the cache and is not affected.

## §5 OMS side

**Is `product_wms_item.wms_item_id` reliably filled in? No, and the design makes it unreliable.**
- The writers are:
  - the create broadcast, which always writes NULL because wms2 returns no ids;
  - the facility sync reconcile/backfill, which gets the id by matching on the code;
  - the backfill command.
- `recordSeen` overwrites `wms_item_id` on conflict, so a create broadcast with NULL **wipes an id that was already known**.
- Pruning after a full observation deletes rows not seen in that run, and "seen" means matched by code. **If the WMS still has A while the OMS has B (a failed rename), the next full reconcile deletes the facility row and the id is lost.**
- I couldn't measure how many rows actually have an id (no OMS MySQL access). Query to run per tenant: `SELECT facility_code, count(*), sum(wms_item_id IS NULL) FROM product_wms_item WHERE product_id<>0 GROUP BY facility_code;`

**Fallback when the id is NULL**
- `previous_sku` only helps on the rename request itself. A later edit after a failed rename carries neither the id nor the old SKU, misses, and creates a duplicate — the original bug.
- Mitigations:
  - (a) wms2 returns ids from both create and update, in the `item_ids` shape O5 already reads.
  - (b) `recordSeen` never replaces a stored id with NULL.
  - (c) Optional, extra scope: the OMS keeps the pending rename until each facility acknowledges it.

**Shape and availability of `previous_identity`**
- In C1 it is `['product_sku' => string, 'client_id' => OMS client id int]`. The OMS `client_id` is not the WMS client id; the WMS uses `cl_nr`, which is the OMS `client_code`.
- C2 doesn't compute it, and passes a fresh copy that has lost `getPrevious()`. C3 can't rename.
- Recommendation: change the signature to `updateSkuFromProduct(Product $product, ?string $previousSku = null)` rather than reading old values off the model. C2's fresh-copy problem shows that inference is fragile.

**Client move** (C1 only, `wasChanged('client_id')`)
- Today the update creates the item under the new client, which is arguably correct because stock belongs to the old owner.
- The design must not look up by id without the client filter and move the row (Q2).

**Sending to every facility** (O4)
- A facility that never had the SKU gets an update. A full miss must still **create** the row: it's legitimate, and it's how a newly added facility gets the catalogue.

## §6 Tests and test lanes

**wms2-api**
- `unit/controller/rest/SkuRestControllerUnitTest` — 25 tests, including `update_shouldDelegateToSkuBatchCreateUpdateService_whenValidExistingSku`, `update_paddedSku_matchesExistingTrimmedRowAndUpsertsTrimmedDto` and `update_fiftySkuBatchBadClientIdAtPosition30_returns422_withNoSkusPersisted`.
- `unit/service/SkuBatchCreateUpdateServiceUnitTest` — 2 tests (the transaction-annotation check and rollback on save failure). Nothing pins the create-on-miss branch of update.
- `integration/controller/rest/SkuRestControllerIntegrationTest` (`createTest`, `updateTest`, `deleteTest`).
- `integration/SkuRestControllerAtomicityIntegrationTest` (3 tests, including `update_paddedSkuPayload_updatesExistingTrimmedRow_withoutCreatingDuplicate`). This is the place for the rename and collision ACs, because the unique constraint only bites on real Postgres.
- `unit/config/CacheEvictionOnWriteUnitTest` (17) and `TenantCacheKeyUnitTest` (10) guard the cache.
- **How to run:**
  - Use `mvn test` with JDK 21.
  - Run the ITs one class at a time with `-Dtest=<Class> -Dsurefire.failIfNoSpecifiedTests=false`; `*IntegrationTest` classes aren't in surefire.
  - Take the full-suite baseline close in time to the change, and don't run Maven concurrently.

**oms-laravel-api**
- `tests/Feature/Services/WmsApiServiceTest.php`. Its `it_includes_item_id_in_sku_data_when_product_has_wms_item_id` **locks in the wrong global key and must change.** It also has `it_builds_sku_data_from_product_with_correct_wms_field_names`, `it_builds_sku_payload_with_facility_code`, `it_trims_sku_and_sku_name_in_sku_data` and `it_creates_sku_in_all_tenant_facilities`.
- `tests/Feature/Api/FacilityWmsSyncTest.php` and `ProductMerchantWriteAccessTest.php`.
- No CI runs these, and there is no PHP on this machine. Use the Docker recipe in the memory note `oms-laravel-api-has-no-runnable-test-env`, against a throwaway MySQL only.

## §7 Prior plans and decisions

- **260610 SKU trim normalization** (archived; merged as PR #44): all lookups trim at one choke point, and `setItemNr` trims. Its §10 deferred the item_id contract plus no-create-on-update, saying "each half alone is dead code or breaking". This ticket is that work. Its "no unique index" claim is false (§3).
- **SBDEV-2496** (archived, v1 and v2): trailing-space duplicates; normalisation in order import and advice.
- **SBDEV-3135:** all three `/rest/sku` handlers evict the cache in `finally`, because an exception can escape after `upsertAll` has committed. Keep that mechanism.
- **SBDEV-2681:** `product_wms_item` is an existence map with a "default-open" coverage marker. Its `wms_item_id` is incidental and nothing reads it.
- **SBDEV-2270:** `previous_identity` exists for Unknown-SKU resolution, not WMS sync.
- **SBDEV-2026:** no hits in sbdocs or in either repo's git log. Unknown.
- **PR #14 (`feat/sku-item-id-sync`):** reuse its `item_ids` response shape. Reject its id lookup without the client filter, and reject "update fails on miss", which breaks the all-facility create.

## §8 Design: decisions, constraints, alternatives, candidate ACs

**Nam's decisions (2026-10-02, settled):**
- **D1:** Rename in place, even when the old code is on open orders or in-flight picks. `itemdata.id` is kept; anything storing the code as text is either fixed or listed as a known gap.
- **D2:** If the new code already exists as another item for the same client, reject with a 422 that names both item ids. No merge.
- **D3:** Cleaning up existing duplicates is out of scope (separate ticket). The §3 query is its starting point.

**Constraints**
- **C1 — Use a NEW field name for the per-facility id (e.g. `facility_item_id`), filled only from `product_wms_item` for that facility. Never honour `item_id` as the OMS sends it today.** If wms2 starts reading `item_id` before the OMS changes, facility B will look up facility A's id. Even limited to the client, that can match a *different product of the same client*, which would then be **renamed** — silent data corruption. A new field name makes either deploy order safe. Also drop the global `item_id` from the payload and from the delete call (O6).
- **C2 — The id lookup must be limited to the client.** An id that belongs to a different client counts as a miss, never as a reason to move the row.
- **C3 — Lookup order:** facility id → `previous_sku` → `sku`.
  - If the found row's `itemNr` differs from `sku`, check for a collision first (D2), then rename.
  - The collision check applies to every row found, including one found by id whose current code is neither A nor B.
  - If nothing is found, create.
- **C4 — Keep the rename inside `upsertAll`'s transaction and inside `update()`'s `finally` eviction.** `existingByClient` is keyed by `sku.getSku()` and has to be re-keyed by the row actually found, otherwise rows found by id or `previous_sku` are missed.
- **C5 — wms2 returns ids from both create and update**, and the OMS records them per facility with `recordSeen`. `recordSeen` stops overwriting known ids with NULL.
- **C6 — `stockrecord` (class b):** either (i) rewrite `stockrecord.itemdata` for (client, old code) in the same transaction, using an index-friendly predicate (7.5M rows on WineCo), or (ii) accept the gap and list it. `inventory_record` and the message/outbox payloads are known gaps.
- DTO changes are additive only. No Flyway migration is needed for the core design.

**Alternatives considered and rejected**
1. **Alias table** consulted by every lookup: about 20 call sites plus the cache key, a new Flyway table, and it still leaves the class (b) stores stale. Too big for this defect.
2. **Never change `item_nr`, add a separate display code:** every view, report and inbound/outbound match keys on `item_nr`, so this is a schema-wide re-key.
3. **OMS deletes and recreates on rename:** about 87% of SKUs can't be deleted because other rows reference them (SBDEV-3135: "Only ~13% of SKUs are freely deletable"). Where delete works, it abandons the stock, orders and putaway settings on the old row.
4. **Update fails on a miss (PR #14):** breaks the create that the all-facility broadcast relies on.

**Candidate acceptance criteria (each needs a mutation check)**
- **AC-1 — Rename by previous SKU (real-Postgres IT).**
  - Setup: (c, A) exists; POST `{sku:B, previous_sku:A}`.
  - Expect 204, and the same row id now has `item_nr=B`.
  - Exactly one row for client c has code A or B.
  - Stock and orders still point at that id.
- **AC-2 — The facility id beats a stale previous SKU.**
  - Setup: row X currently has code C; POST `{facility_item_id:X, previous_sku:A, sku:B}`.
  - Expect X renamed to B, and no new row.
- **AC-3 — The id lookup is limited to the client.**
  - Setup: X belongs to client d; POST under client c with `facility_item_id:X`.
  - Expect X untouched, and the request falls through to the code lookup or create under c.
- **AC-4 — Collision (D2).**
  - Setup: X=(c, A) and Y=(c, B); POST `{previous_sku:A, sku:B}`.
  - Expect 422 naming X and Y, both rows unchanged, and no 500.
- **AC-5 — A full miss still creates.**
  - Setup: no A, no B and no id at the facility.
  - Expect 204 and one new (c, B).
- **AC-6 — Plain update still works (regression).**
  - Setup: `{sku:B}` with (c, B) existing.
  - Expect fields updated, `item_nr` unchanged, no insert.
- **AC-7 — Ids are returned and recorded.**
  - Create and update responses carry `item_ids` (SKU → id).
  - The OMS records them per facility.
  - A `recordSeen` with NULL does not overwrite a stored id.
- **AC-8 — The OMS payload is correct per facility.**
  - For facility F, `facility_item_id` is `product_wms_item.wms_item_id` for (product, F), and absent when that is NULL.
  - The global `item_id` is not sent.
  - `previous_sku` is present exactly when the SKU changed.
  - C2 sends the SKU from before the update (test the fresh-copy trap).
- **AC-9 — Cache in the same JVM after a rename.**
  - Looking up (c, B) returns X, with no stale cached miss.
  - Looking up (c, A) misses.
- **AC-10 — If C6(i) is chosen.**
  - `stockrecord` rows for (c, A) read B.
  - `transaction_detail` for B includes movements from before the rename.

## §9 Questions that need Nam

- **Q1 — Stockrecord history (C6):** rewrite `stockrecord.itemdata` on rename, or accept the report gap? Rewriting changes an audit log in a WineCo-sized table whose only index is on `lower(itemdata)`. I recommend rewriting, with a predicate that matches that index: it's the only stale store a user will notice, in the transaction reports.
- **Q2 — Client moves in the OMS** (ProductController only): keep today's "create under the new client"? I recommend yes, because stock is owned per client. D1–D3 don't cover this.
- **Q3 — Repeated 422s for existing duplicates:** with the id looked up first, a product whose facility id points at the older row while (c, B) already exists gets a **422 on every future edit** at that facility, until the D3 cleanup runs. This affects up to the 78 Hydra / 323 WineCo candidates. Accept that (it surfaces the victims), or until cleanup, update the B row, skip the rename and log a warning?
- **Q4 — Delete:** should `/rest/sku/delete` take the same per-facility id? O6 sends the wrong global id today, which is the same C1 hazard. I recommend yes, in the same pass; that adds scope to the ticket.
- **Q5 — Replicas (owner: Joe):** is prd wms2 running more than one replica, and is the `redis` profile on? With several Caffeine replicas there is a window of up to 5 minutes on the other replicas where a cached miss makes the new code fail. Accept that, or require Redis?
## §10 Resolved by Nam (2026-10-02, after this bundle)
- Q1 → **Rewrite `stockrecord.itemdata`** (client, old code) → new code in the SAME transaction; predicate must use the `lower(itemdata)` index (WineCo 7.5M rows).
- Q2 → **Client move: keep today's create-under-new-client.** An id/previous_sku hit belonging to a different client is a miss (C2).
- Q3 → **Accept the 422** on collision for existing duplicates; no soft fallback.
- Q4 → **Delete in the same pass**: `/rest/sku/delete` resolves by `facility_item_id` (client-scoped) then code; the global `item_id` is dropped from all OMS payloads.
- Q5 (replicas / redis profile, owner Joe) → still OPEN; plan documents the ≤5-min cross-replica cached-miss window as a known gap and asks Joe.
