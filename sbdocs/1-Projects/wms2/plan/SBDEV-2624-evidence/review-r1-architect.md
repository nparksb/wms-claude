## Summary

The core design holds up: rename in place, a client-scoped per-facility id, a collision 422 and an additive contract. Most of the plan's factual claims check out against origin/develop (wms2 `62c92dd5`, OMS `55f5f93c`) and WineCo prd. Two defects need fixing before approval:
- **H1:** the id path can apply an older rename on top of a newer one, and nothing catches it.
- **H2:** the order of steps in `upsertAll` holds a FOR UPDATE lock on a hot itemdata row for the whole stockrecord rewrite, so stock operations on that SKU fail during it.

Neither change touches D1–D3 or Q1–Q4. Verdict: **revise, then approve**.

## 1. Antithesis (steelman)

The id contract adds a second key, and its value comes from a match on code (`WmsFacilitySyncService` reconcile) or from a response field the OMS has never received. Because §3.2 lets the id beat `previous_sku` without any check (AC-2), a WMS row gets renamed to whatever the incoming request's `sku` is, whatever code it holds right now.

That is what makes two things possible: an out-of-order rename (H1) and a wrong-row rename whenever the map is wrong. Per bundle §5, the id's one unique benefit is recovering after a failed rename. A stricter A7 could deliver that too: `previous_sku` plus the OMS keeping a pending rename until each facility acknowledges it (bundle §5 mitigation c). That carries none of the "rename whatever row id X currently is" risk. The plan rejects A7 as "weaker", but it never weighs the id path's own failure modes.

## 2. Tradeoff tensions

- **Recovery vs. ordering safety.**
  - AC-2 ("id beats stale previous_sku") is what heals a failed rename.
  - The same rule is what lets a late or older request revert a newer rename.
  - You cannot have both unless you add a precondition check.
- **Atomic history (Q1) vs. lock hold time.**
  - Rewriting up to 44,251 stockrecord rows in the SKU tx is atomic, as Nam chose.
  - But it means the itemdata row lock is held for the length of the rewrite (H2).
  - Q1 is settled. The **order of statements** inside the tx is not, and it decides who blocks.

## 3. Synthesis

- **Compare-and-set (CAS) when `previous_sku` is present.**
  - Rename only if the reloaded `row.itemNr` is either `previous_sku` or `sku`.
  - Otherwise reject: "precondition failed: item X is C, expected A".
  - When `previous_sku` is **absent** (a plain edit), keep id → rename. That is the recovery path. A failed rename still heals on the next ordinary edit, one edit later than in r1.
- **Reorder `upsertAll`:** collision check → stockrecord rewrite → `setItemNr` plus the field setters → `saveAndFlush` last.

Together these keep AC-2's recovery value, close the revert, and cut the itemdata lock hold time from seconds to milliseconds without breaking Q1's single-tx atomicity.

## 4. Defects

**H1 — High: the id path applies an older rename over a newer one, and `@Version` cannot see it. §7.5 #8 is factually wrong.**
- **Evidence (plan):** §3.3 step 2 reloads with `itemdataRepository.findById(existing.getId())`, then step 3 runs `if (!row.getItemNr().equals(sku.getSku())) → rename`. AC-2 says "X has code C; POST `{facility_item_id:X, previous_sku:A, sku:B}` → X.item_nr = 'B'".
- **Race:**
  - Edit1 is A→B and edit2 is B→C, for example from two LegacyV2 API clients.
  - Edit2 commits first, so the row is now C.
  - Edit1's reload runs after that commit (READ COMMITTED), sees C at the current version, and renames C→B. No version conflict is raised.
  - The OMS ends at C and the WMS ends at B. Stockrecord history for C is rewritten to B.
  - The only signal is the S1 WARN.
- **§7.5 #8** says "the loser gets an optimistic-lock 500 and the OMS retry is idempotent". The OMS **does not retry a 5xx**:
  - `processWmsResponse` does `if (!$response->successful()) { throw WmsException::fromHttpStatus(...) }`.
  - `WmsException extends Exception`, and the retry loop catches only `ConnectionException` and `RequestException` (WmsApiService.php:412, :426).
  - So the loser's edit is simply lost.
- **Fix:**
  - Add the CAS rule from §3 in `upsertAll` step 3, using the reloaded row.
  - Split AC-2 into two tests:
    - (a) id with no `previous_sku`, row at C → renamed (recovery).
    - (b) id with `previous_sku` A, row at C → reject, row unchanged, stockrecord unchanged.
  - Correct §7.5 #8.
  - Mutation check: drop the CAS conjunct → AC-2b goes red.

**H2 — High: the rename takes FOR UPDATE on the itemdata row, which blocks foreign-key checks from all 8 child tables for the whole rewrite.**
- **Evidence (WineCo prd, `pg_constraint`):**
  - `uk3l3dgof3l6mc1dl7s3lmida65` is `UNIQUE (client_id, item_nr)`: not partial and not an expression.
  - 8 foreign keys point at `itemdata`, none deferrable: `stockunit`, `customerorder_position`, `pickingorder_position`, `adviceposition`, `replenishorder`, `cyclecount_position`, `billoflading_position`, `fix_location_assignment`.
- **Mechanism:**
  - That unique constraint makes `item_nr` a "key column" in PostgreSQL's row-lock rules, so an UPDATE that changes it takes **FOR UPDATE**.
  - FOR UPDATE conflicts with the **FOR KEY SHARE** that every foreign-key check on a child insert takes.
- **Plan order:** §3.3 runs b `saveAndFlush(row)` *before* c `renameItemdataForClient`. So the lock is held for the entire rewrite of up to 44k rows, which the plan itself budgets at up to 10 s.
- **Impact:**
  - The tenant lock wait limit is 5 s per acquisition (`LockTimeoutHibernateJpaDialect`, applied to every tenant tx).
  - Any receiving, picking, replenishment or order import that inserts a child row for that SKU during the rename fails with a lock timeout.
  - That is plausible: WineCo prd writes 5,011 stockrecord rows a day, with a maximum of 201 a day for a single SKU.
- **Fix:**
  - Reorder to: collision check → native stockrecord UPDATE → `setItemNr` and all field setters → `saveAndFlush`.
  - Do **no** entity mutation before the native statement. Hibernate auto-flushes pending changes before a native query, which would issue the itemdata UPDATE early.
  - The cost: an optimistic-lock loser is now detected after the rewrite, and that work is rolled back. That is acceptable.
  - Pin the order with a Mockito `InOrder` test.
  - Add it to §7.5 #4 and #8.

**M1 — Medium: the stockrecord rewrite can leave orphaned rows.**
- **Evidence:** `StockrecordService.java:231` and the lines after it read with `itemdataRepository.findById(...)`, then do `rec.setItemdata(stockunitItemdata.getItemNr())`. That read is uncached but runs under READ COMMITTED.
- **Race:** a stock movement that reads row X before the rename commits inserts a stockrecord row with the old code A. If that insert lands after the rewrite statement's snapshot, nothing ever updates it. stockrecord has no foreign key, so the insert never blocks.
- **Consequence:** this breaks the "pair join lossless" invariant that §2.2 measured and that AC-10 relies on.
- **Fix (pick one):**
  - After commit, run the same UPDATE again in a short tx, guarded with `AND NOT EXISTS (SELECT 1 FROM itemdata WHERE client_id=:c AND item_nr=:old)`. It is idempotent and cheap.
  - Or add an "orphan stockrecord rows since deploy" query to §8 and list the race as a new known gap (G6).

**M2 — Medium: after a failed rename, a facility sync run creates the twin and deletes the stored id.**
- **Evidence (`WmsFacilitySyncService.php`):**
  - Reconcile matches by code only: `if (isset($existingItemNrs[$sku]))`. Otherwise the product is "missing" and goes to `createSkuBatch`.
  - On a full run it then calls `ProductWmsItem::pruneStale($facilityCode, $observationStart)`.
  - The plan marks this site P2 as OUT.
- **Sequence:** the WMS still holds A while the OMS holds B, then an operator runs a full sync.
  - The run creates (c,B), which is the original defect through another door.
  - It deletes the product_wms_item row that held X.
  - Every later edit then updates the twin, and (c,A), which carries the stock, is orphaned.
- **Fix:**
  - At minimum: in reconcile, if the product's stored `wms_item_id` is among the WMS ids under a different code, report it as "code drift", don't create it, and make `pruneStale` skip that row.
  - Or list it as a known gap with a dry-run report column.
  - It is sub-T3 and goes on this ticket.

**M3 — Medium: a delete by id ignores a code mismatch, and a delete is not self-healing.**
- **Evidence:** §3.5 / Q4: "resolve facility_item_id (client-scoped) → sku". There is no check of `row.itemNr` against `sku`.
- **Risk:**
  - A mis-mapped id deletes a different product of the same client. This applies to the roughly 13% of SKUs that are freely deletable.
  - A wrong rename can be undone by renaming back; a wrong delete cannot.
- **Fix:** keep Q4's lookup order. On an id hit where `row.itemNr ≠ sku`, return 422 naming both values, and log a WARN.
- **Exception:** the legitimate "failed rename, then delete" case. Allow it by having the OMS send `previous_sku` on delete, and accept when `row.itemNr` equals it (the same CAS rule as H1).

**L1 — Low: lock and optimistic failures still surface as 500.**
- **Evidence:** §3.3 b translates only `DataIntegrityViolationException`.
- **Gaps:**
  - A concurrent create of B that waits past 5 s raises SQLSTATE 55P03 (`CannotAcquireLockException`).
  - A version loser raises `ObjectOptimisticLockingFailureException`.
  - The create handler catches only `WebserviceBusinessExceptionClientSide`.
- **Fix:** in `upsertAll`, translate `PessimisticLockingFailureException` and `ObjectOptimisticLockingFailureException` into a client-side exception with a concurrency message. Test it.

**L2 — Low: the nonce is not wired into the batch create, which now returns ids.**
- **Evidence:** `createSkuBatch` calls `$this->buildSkuPayload($facility, $skuData)` (WmsApiService.php:4112 and the lines after), but §3.6 passes the nonce only from the three `*FromProduct` methods.
- **Risk:** a byte-identical batch body within the 7-day window replays an old 200, possibly with ids of rows since deleted.
- **Fix:** have `buildSkuPayload` default to a fresh UUID when no nonce is passed, and make `createSkuBatch` generate one per call.

**L3 — Low: the OMS's `reset()` fallback for recording ids can record the wrong id.**
- **Evidence (plan §3.5):** `$responseData['item_ids'][$sku] ?? reset(...)`.
- **Risk:** any mismatch in the key silently records the first id in the map.
- **Fix:** use the exact key or null, and never `reset()`.

**L4 — Low: a cached miss for B on another replica causes a 500 on a plain update.**
- **Path:** steps 1 and 2 miss, step 3 hits a cached miss for B, the code goes to create, and the insert raises a `DataIntegrityViolationException` that nobody catches.
- **Fix:** in the `existing == null` branch, re-check through the repository (uncached) inside the tx before inserting.

**L5 — Low: the M-5 timing gate is set on an unmeasured table.**
- **Evidence:** "pass: < 10 s for 'WCI PC'" is run on WineCo UAT, whose stockrecord size is unknown. The 44,251-row figure is from prd.
- **Fix:** record the UAT row count for that SKU next to the timing, and scale the result.

**L6 — Low: "Either order is safe" is true only in the sense of "no regression".**
- **OMS deployed first:** renames during the gap still create twins, as today. Once wms2 lands, the id path collides with those twins, so the set of products that get a 422 on every edit (Q3) grows.
- **Rolling replicas:** an old replica creates the same kind of twin during the rollout.
- **Fix:** make wms2-first **required** in §5.1 #4, and run the OMS deploy only after wms2's `/api/public/version` shows the new SHA on every replica.

**L7 — Low, pre-existing, propose rather than fix: SDR PATCH on itemdata is still open.**
- **Evidence:** `RestConfiguration.java:498` puts `Itemdata.class` in the list that ends `.withItemExposure((metadata, httpMethods) -> httpMethods.disable(HttpMethod.PUT, HttpMethod.DELETE))`.
- **Risk:** a merge PATCH can change `itemNr` and skip the rewrite, the collision 422 and the OMS.
- **Callers:** none. A grep of both UIs finds no itemdata PATCH.
- **Action:** add a row to §0 as OUT, plus a proposal.

## 5. Claims verified (no action)

- **204→200 is safe for every caller.**
  - OMS v2 `processWmsResponse` handles JSON 2xx, and `isFailureResponse` checks only `status`.
  - `createSkuBatch` lets only `WmsException` propagate.
  - v1 OMS `INVENTORY/HttpRestJson/Client.php:142` sets `status=success` on `isSuccess()`.
  - Neither wms2 UI calls `/rest/sku`, and nothing in wms2 `src/main` calls it except the controller.
  - Unit tests that stub `upsertAll` get an empty Map by default, so AC-7a must stub the return value.
- **IdempotencyFilter analysis (F-1) is correct.**
  - With no header, the key is the auto-derived `sha256HexComposite(method, uri, body)`.
  - Only 2xx responses are persisted, so a 422 is never replayed.
  - `app.idempotency.bridge-mode=false` (application.properties:283).
- **The fix belongs on the OMS side.** The OMS already owns the sending side, and a body nonce survives a future `bridge-mode=true`, which matches on body hash and ignores the key. An `Idempotency-Key` header is the documented alternative (`KEY_REGEX` accepts a UUID). It is cleaner, but bridge mode would defeat it. Keep the body nonce and write that reason into §3.6.
- **The `lower()` predicate is right.** A String parameter binds as varchar, so `lower(:old)` matches the `lower((itemdata)::text)` index expression, and a generic plan can still use it. The exact-match conjunct correctly scopes a case-only rename. No triggers on stockrecord or itemdata, and autovacuum is on (WineCo prd).
- **Backfill by code match is not a source of wrong ids.** Reconcile is keyed by the WMS client id and the exact trimmed `itemNr`, case-sensitive (`$wmsItemNrByClientId[$wmsClientId][(string) $itemNr]`). The ambiguity guard covers two OMS products mapped to one id.
- **The reload removes the stale-`@Version` failure** from the cached detached entity. The collision lookup through the repository bypasses the cache. `StockrecordRepository` is type-level `exported = false`.

## References

- `/Users/np1076/dev/spk/owl/v2/wms2-api` — `src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java` (`upsertAll`, update branch); `controller/rest/SkuRestController.java` (update and delete resolution, `finally` eviction); `landlord/config/IdempotencyFilter.java:249-346`; `service/RestIdempotencyService.java:107,211`; `landlord/config/LockTimeoutHibernateJpaDialect.java`; `service/StockrecordService.java:231-556`; `RestConfiguration.java:498,880`
- `/Users/np1076/dev/spk/owl/v2/oms-laravel-api` — `app/Services/WmsApiService.php:311-482` (retry scope), `:485` (`processWmsResponse`), `:1523-1548`, `:4112` (`createSkuBatch`); `app/Services/WmsFacilitySyncService.php:232-243,276-289,591-650`; `app/Models/ProductWmsItem.php:149` (`pruneStale`)
- `/Users/np1076/dev/spk/owl/v1/oms/htdocs/module/INVENTORY/src/INVENTORY/HttpRestJson/Client.php:142`
- WineCo prd (wsl-wineco-prd), 2026-10-02: 8 non-deferrable foreign keys on `itemdata`; plain `UNIQUE (client_id, item_nr)`; 5,011 stockrecord rows/day, at most 201/day for one SKU
- Plan under review: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-2624-evidence/plan-snapshot-r1.md` — §3.3, §3.5, §3.6, §5.3, §7.5 #8