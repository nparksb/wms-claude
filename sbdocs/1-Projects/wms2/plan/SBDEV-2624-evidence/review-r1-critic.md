**VERDICT: ITERATE**

**Overall assessment.** The core design is sound and consistent with Nam's §10 decisions: rename in place, a client-scoped id, then `previous_sku`, then `sku`, then create, with the collision check and the stockrecord rewrite in one transaction. Most of the facts I checked hold up. The plan still fails the deliberate-mode gate: the pre-mortem it cites three times does not exist. It also makes two factual claims that turn out to be false, one about OMS retries and one about readers of `product.wms_item_id`. It misses a second code path that still creates the duplicate. Several of the AC and mutation pairings cannot detect the mutant they are assigned to.

**What I verified as correct** (wms2 origin/develop `62c92dd5`; OMS origin/develop is now `dad34d7e`, with no change since `55f5f93c` to any of the five relevant files):
- `upsertAll` returns void and its update branch never touches `itemNr`.
- `NOT_UNIQUE_VALUE = 105` and its message text are as the plan states.
- `SkuRestControllerAtomicityIntegrationTest extends BaseRollbackIntegrationTest`, so the plan's correction (it runs on H2, not Postgres) is right.
- `MoveCronConcurrencyIT` uses `@Transactional(propagation = NOT_SUPPORTED)` as the plan says.
- Failsafe includes `**/*IT.java`, and `WmsObjectMapper` uses `NON_NULL`.
- The 204-assertion counts per test class are 4/3/2/2/2, and the test counts are 25 and 17.
- WineCo prd: stockrecord has 14 indexes, there are 0 user triggers on `stockrecord` or `itemdata`, and the `'WCI PC'` rewrite set is exactly 44,251 rows.
- The `message` table has `process`, `status` and `message` columns, with 77 `SKU_UPDATE`/`FAILED` rows.
- Putting the nonce in the body is the right choice. Under bridge mode, `tryClaim` matches on the body hash and ignores the key, so a fresh `Idempotency-Key` header with an identical body would still replay.

---

### Findings

**1. CRITICAL: the pre-mortem is missing (deliberate-mode gate).**
- The plan cites `(pre-mortem S1)` at §3.3d, §3.5 and §8 step 5. There is no pre-mortem section anywhere, and no S2 or S3.
- Required change: add a pre-mortem with at least three scenarios, each with detection and mitigation. Findings 2, 3 and 9 are the strongest candidates. Also cover the S1 wrong-row rename by id, and M-5 coming in over 10 s.

**2. MAJOR: §7.5 #8 claims the OMS retries a 500, and it does not.**
- The plan says: `"the loser gets an optimistic-lock 500 and the OMS retry is idempotent"`.
- In `WmsApiService::makeWmsRequest`, a 5xx goes to `processWmsResponse`, which throws `WmsException::fromHttpStatus`. The loop catches only `ConnectionException` and `RequestException`, so a 5xx is never retried.
- A timeout is retried, but `IdempotencyFilter` returns `409 idempotency-in-flight` while the first attempt is still running. That 4xx throws, so the OMS records a failure while the WMS commits the rename.
- Either way the rename can be lost at one facility. The next edit carries no `previous_sku` and creates the duplicate again, unless a `facility_item_id` is known.
- Required change: correct #8 and the 30 s × 3 claim in §3.4. Add this path to the pre-mortem and list it as a known gap. Optionally, record a pending rename per facility (bundle §5 mitigation c).

**3. MAJOR: a second code path still creates the duplicate and is marked OUT.**
- `WmsFacilitySyncService` reconcile creates missing SKUs by code: `$missingByClientCode[$clientCode][] = $product` → `deliverSkuBatch` → `createSkuBatch`.
- After a failed rename at facility F (WMS still has A, OMS has B), the next sync run creates the (c, B) twin.
- `pruneStale` (`WmsFacilitySyncService:283,1045`) also deletes the per-facility row and its id, which is what bundle §5 warned about.
- This contradicts the ADR's `"the id survives repeated edits after a failed rename"`.
- `createSkuBatch` (`WmsApiService:4124`) is also missing from §0. It is a fourth caller of `buildSkuPayload`, so the nonce threading in §3.6 must account for it.
- Required change: add P2 and `createSkuBatch` to §0 as known producers of the outcome. Either make reconcile skip SKUs that have a pending or failed rename, or list this as a gap with a monitor. Fix the ADR sentence.

**4. MAJOR: the claim that nothing reads `product.wms_item_id` is false.**
- §3.5 and §6 say `"The column stays, unused (SBDEV-2681: nothing reads it)"`. Three inbound readers exist:
  - `LegacyWmsController:441`: `Product::where('wms_item_id', $update['item_id'])`
  - `LegacyProductUpdateService:165`
  - `LegacyInventoryAdjustService:966`: `Product::where('wms_item_id', $itemId)->first()`. This lookup is **not scoped to the client**, and it compares the global first-facility id with an id sent by any facility. It can resolve the wrong product's inventory. This is the inbound mirror of constraint C1.
- The existing test `it_captures_wms_item_id_from_create_response` asserts `$product->fresh()->wms_item_id == 12345`. It will break and is not in the list of tests to replace.
- Required change:
  - List the three readers and say what stopping the create-side write does to them (they fall back to the SKU lookup, and the self-heal backfill at :456 and :988 still writes the column).
  - Replace that test.
  - **Propose, do not file,** the :966 lookup as a T3 finding with its blast radius (ShipItEZ has two facilities with separate id sequences).

**5. MAJOR: AC-2 cannot catch the mutant it is assigned.**
- The setup is `"X has code C; POST {facility_item_id:X, previous_sku:A, sku:B}"` with no row (c, A).
- If the lookup order is swapped, the `previous_sku` step misses and the id step still finds X, so the test stays green.
- Required change: seed Z = (c, A). Assert that X becomes B and Z keeps A, unchanged. Name the mutant in the assertion message (`"lookup order: previous_sku resolved before facility_item_id"`).

**6. MAJOR: the AC-9 test and the cached-collision mutant are placed in a harness that cannot exercise them.**
- In `CacheEvictionOnWriteUnitTest.ItemdataHarness`, `SkuBatchCreateUpdateService` is a `mock(...)` and the cache is a `ConcurrentMapCacheManager`. No rename and no collision check actually run there.
- AC-9 is therefore green on the base SHA, because the `finally` clear already exists. The plan also labels this lane `H2`; it is a unit test.
- `…collisionCheck_ignoresCachedMissForB` has no class and no lane.
- Required change: move both into `SkuRenameInPlaceIT` (real Spring cache). Warm a miss for B through `itemdataService`, insert (c, B) with committed SQL, then POST the rename and expect 422. Drop AC-9 or relabel it as a regression guard.

**7. MAJOR: "every AC test is red on the base SHA" (P0 acceptance) cannot be met, and several ACs bundle more than one assertion.**
- On the base SHA:
  - AC-3 is green: the id is ignored and (c, B) is created.
  - AC-5 differs only in 204 vs 200.
  - AC-6 does not compile, because `renameItemdataForClient` does not exist yet.
  - AC-9 is green (finding 6).
- AC-1 is `"→ 200 **and** SELECT …"`. If the status is asserted first, it goes red on 204 vs 200, not on the `"found 2"` message P0 promises. AC-4 and AC-10a have the same problem.
- Required change:
  - Classify each AC as either red-first or regression guard; a regression guard is proven by its mutant instead.
  - Assert the row state before the status.
  - Move the 200 status contract into AC-7a only.
  - State the expected red message for each red-first AC.

**8. MAJOR: the mutation floor covers only part of the plan.**
- §7.1 lists 7 mutants against about 25 test rows. There are none for AC-1, AC-5, AC-7a, AC-7b, AC-8a/b/c/f/g, AC-10b, Q4 (delete), the SDR pin, or the §3.4 query-shape test.
- The P1 acceptance relies on PIT, which is scoped to `SkuBatchCreateUpdateService`. The controller's resolution logic is outside that scope.
- P2 (OMS) has no mutation step at all, and there is no PHP mutation tool or hand-mutant list beyond two bullets.
- Required change: one named mutant per row, with the expected failing assertion message. Add an OMS hand-mutant list, for example: re-add `item_id`, drop the NULL omission, send `previous_sku` unconditionally, reuse the nonce across calls, drop the ambiguity guard.

**9. MAJOR: a concurrent stock write can leave stockrecord rows on the old code.**
- The stockrecord writers in `StockrecordService` (:231–553) read the itemdata row uncached with `findById` and insert `rec.setItemdata(…getItemNr())`.
- A stock transaction that read A before the rename commits, and inserts after the rewrite `UPDATE` has run, leaves an orphan row with code A. The rename never sees it under READ COMMITTED.
- This breaks the invariant the plan itself measured (`"Pair join lossless today … 0"`), and it is not in G1–G5.
- Required change: add it as known gap G6. Add the 0-orphan pair-join query (`created > :deploy`) to §7.4 and to rollout day +1 and +7.

**10. MINOR: the M-5 measurement needs writable access the plan does not list.** M-5 needs a writable WineCo UAT session, but prerequisite #7 says `N/A` and the UAT MCPs are down. Name the owner. Also say what happens if M-5 shows 10 s or more, for example a `(client_id, lower(itemdata))` index ticket, or a chunked rewrite.

**11. MINOR: the §7.2 IT command will run the whole unit suite first.** The pom's documented form is `mvn verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`. Without `-Dtest=ZzzNone`, surefire runs every unit test before the IT.

**12. MINOR: §7.6 #1 gives the wrong reason for the transaction.** It says the `@Modifying` method `"inherits the tenant TM from repo.jpa"`. A query method declared on the interface gets no transaction configuration. It works because it joins `upsertAll`'s transaction. Say that, and note that calling it outside a transaction throws `TransactionRequiredException`.

**13. MINOR: the ambiguity-guard count is not fully indexed.** §3.5 calls it `"one indexed count"`, but `product_wms_item` has only `idx_product_wms_item_facility (facility_code)` and `uq (product_id, facility_code)`. The `wms_item_id` predicate is filtered after the index. That is acceptable at this size, but the wording should say so.

**14. MINOR: the 422-rate query in §7.4 cannot isolate collisions.** `message LIKE '%previous_sku%'` misses collisions found by id. The `message` row stores the payload, not the error description, so it also cannot tell a collision from any other 422. Log a stable WARN token for D2 collisions and count that instead.

**15. MINOR: two OMS details are ambiguous.**
- Nonce on delete: `deleteSku` builds its own payload and does not use `buildSkuPayload`. Specify where the nonce goes for delete.
- Client-move detection: C1 detects a client move with `wasChanged('client_id')` after a closure that may save more than once. Compare `$previousIdentity['client_id']` with the current value instead.

**16. MINOR: one strong alternative is missing.** "Store a stable OMS key (product_id) on `itemdata`" is the strongest rival design: one key for every facility, with no per-facility id plumbing. It needs a Flyway column, so its rejection rests on driver 3 ("no migration"). Add it as A8 and say that explicitly.

**17. MINOR: verify-script row hygiene.**
- 4 rows is within the 15-row limit, and red-on-base is stated.
- Rows 1–3 are presence greps that a comment would satisfy. Anchor them to a code pattern rather than a bare string.
- Row 4 (awk-scoped) must **fail closed** if the function body is not found.
- Row 4 duplicates AC-8b, so drop it.
- State the `PROJECT_ROOT` shape (monorepo root, since the rows span both repos).

### What's missing
- A pre-mortem (finding 1).
- Every code path that can still produce a duplicate (findings 2, 3).
- A live monitor for orphaned stockrecord rows (finding 9).
- An OMS mutation plan (finding 8).
- An owner for writable UAT access (finding 10).

### Floor check
- DB query confirming the symptom: done (§2.2: 264 create-on-update rows and 13 rename fingerprints on WineCo prd).
- Failing test first: planned, but the red-on-base claim is wrong for several ACs (finding 7).
- Mutation-check every new assertion: partial (finding 8).
- Independent review: planned (P3).
- Full-suite baseline: planned for both repos.

### Verdict justification
I ran in ADVERSARIAL mode, because finding 1 is a CRITICAL gate failure and there are more than three MAJOR findings.

Realist check:
- Finding 9 stays MAJOR, not MINOR: it is a data-integrity regression of an invariant the plan measured, and the fix is cheap.
- Finding 4 stays MAJOR because of the cross-client lookup at :966. The plan's own change there is low-risk.

To reach APPROVE, the plan needs findings 1–9 fixed.

**Open questions (unscored)**
- Does facility sync run on a schedule or only when an operator triggers it? That sets how often finding 3 happens.
- Is `bridge-mode` on in prd? That affects any future switch to an `Idempotency-Key` header.
- Q5 (replica count and whether the `redis` profile is on) is still with Joe.

---
*Ralplan summary row*
- **Principle/Option consistency:** Fail. Driver 1 ("no silent data corruption") is weakened by findings 2, 3 and 9, which the design does not address.
- **Alternatives depth:** Pass, with one gap (finding 16).
- **Risk/Verification rigor:** Fail (findings 2, 5, 6, 7, 8).
- **Deliberate additions:** Fail. The pre-mortem is missing. The expanded test plan covers unit, integration, manual and observability, but its observability section lacks the orphan monitor.