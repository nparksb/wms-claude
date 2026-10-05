**VERDICT: APPROVE.** r4 can go to the gate. The seven Minor findings below are text or fixture fixes and don't need another review round.

**Base checked:** wms2-api `origin/develop` is now `7762aa64`. The r3 reviews used `62c92dd5`, and the only change since then is new String keys for SBDEV-3622 in `WmsConstants.java`. Codes 108 and 109 are still free (`= 10[89];` finds nothing in `src/main`). oms-laravel-api `origin/develop` is `dad34d7e`, the same commit the r3 reviews used.

### (1) Are the r3 findings addressed in the r4 body?
| Finding | Status in the r4 body |
|---|---|
| A-R1 merge copy / null id | Fixed (§3.3 `saved.getId()`, AC-5b covers create and update→create). Step 5's "`row` is managed" is correct |
| A-R2 109 marker untested | Fixed (AC-7f parameterised over both markers, mutant #20) |
| A-R3 double flush / 105 text | Fixed (4e goes straight to `ids.put`, fixed 105 arguments per flush site) |
| A-R4 anchor | Adopted. `getErrorMap()` is a 2-key map and Jackson writes no space, so the anchor matches |
| A-§C docblock, A-to-another-product edge | Both folded in |
| K #1 resend guard | Adopted, S1 corrected, AC-7h, mutant #21. One gap in the parsing (Minor 1) |
| K #2 base returns 503 | §3.3 and §6 corrected. Keeping 109 is sound (see (2)) |
| K #3–#7, #9–#12, Q1, Q2 | All present in the body. Gaps in AC-15c (Minor 2) and `id_missing` (Minor 6) |
| K #8 mutant #9 | Equivalent, confirmed (see (2)) |

### (2) Checks on what r4 added
- **`failIfExists` (AC-5c) breaks nothing that works today.**
  - Today's create handler already rejects any SKU that exists: `SkuRestController.java:117-120` throws `ENTITY_ALREADY_EXITS` through the cached finder. So a pre-existing SKU already fails the whole 200-SKU batch with a 422.
  - The new uncached re-check only matters when the cached lookup missed (a stale cache, or the same SKU twice in one batch). On base those cases defer the INSERT to commit and return a 500.
  - So failIfExists only turns some of today's 500s into 422s. It never makes a batch fail that used to succeed.
  - `deliverSkuBatch` (`WmsFacilitySyncService.php:897-921`) bisects on any `WmsException`, whether 422, 500 or 503. Batch isolation behaves the same.
  - The update endpoint passes `false`, so update-falls-to-create keeps its semantics.
- **The OMS never retries a 503 — confirmed.**
  - `WmsApiService.php:311-475`: a 4xx throws at :405. Anything else non-2xx throws `WmsException::fromHttpStatus` from `processWmsResponse` (:487).
  - `WmsException` extends `Exception`, not `RequestException`. Only the `ConnectionException`/`RequestException` handlers loop, and nothing calls `->throw()`. `Retry-After` is never read.
  - On base, `RestEndpointExceptionHandler.java:37,49-58` does map lock timeouts and deadlocks to `retryable503`. Using 109 instead is correct for this caller.
- **Mutant #9 is equivalent — confirmed.**
  - The C1 closure has exactly one write, `$product->update($validatedData)`, at `app/Http/Controllers/Api/ProductController.php:771`. The plan calls the file "ProductController"; the real path is under `Api/`.
  - `Product` uses only the `HasFactory` and `UsesTenantConnection` traits. There is no `booted`, no observer, no `ObservedBy`, no `dispatchesEvents`, and no `eloquent.*` listener in `app/`.
- **Both acceptance greps return 13 hits on base — reproduced exactly.** Comments make up part of the second grep's 13 (Minor 3).
- **The "item_id=X is D" parse matches the text arm.** `String.format("…: %1s, %2s", "item_id=X is D", "expected P")` produces a description the regex matches. Edge cases are in Minor 1.

### Findings (all Minor)
1. **The bad-map guard fails open for SKUs containing `"` or `\`.**
   - It parses D out of `getTechnicalDetails()`, which is the raw JSON body (`"HTTP 422: {…}"`). Jackson escapes `"` and `\`, so D comes out escaped, the `product_sku = D` query misses, and the resend goes ahead. That re-opens the S1 rename this guard exists to stop.
   - **Fix:** strip the `HTTP nnn: ` prefix, `json_decode` the body, then run the marker check and the regex on the decoded `description`. Add an AC-7h case with a `"` in the SKU.
2. **AC-15c's fixture is ambiguous and can pass on base for the wrong reason.**
   - `backfillWmsItemIds` runs only from `writeSkus` (`WmsFacilitySyncService.php:869`), for products that were missing and just created.
   - "Reconcile … and a WMS match" reads as "the product already exists in the WMS". That fixture never reaches line 980, so it is green on base and mutant #22 survives.
   - **Fix:** the product is missing at F, the `createSkuBatch` stub succeeds, and the `readItemdataForClient` stub returns B→123.
3. **The second acceptance grep also counts comments.** Six of its 13 base hits are comments or docblocks (`LegacyWmsController:438,455`, `LegacyInventoryAdjustService:963,987,1104`, `LegacyProductUpdateService:158`). The fix should state that these go too, or the P2 gate fails on a leftover comment.
4. **AC-4d says "The POST create B".** `/create` is `@PutMapping` (`SkuRestController.java:71`). A MockMvc `post()` would return 405, red for the wrong reason. AC-5b already says PUT; make AC-4d match.
5. **Gaps in the 109 path:**
   - The 109 text names `item_id=X`, but a lock timeout on the create branch has no X. Define create-branch arguments, the same way R3 was fixed for 105.
   - AC-7f's log asserts "X, D", but a 109 carries no D.
   - The plan should say why the bad-map guard is "108 only". The reason holds: a 109 can only follow a passed CAS. Write it down.
   - "Strictly better" overstates it. The resend is immediate, where the 503 advised waiting 30 s, so it can hit the same lock again and add up to a 5 s wait to a synchronous product save. That cost is bounded and logged, but state it.
6. **AC-5c and `id_missing` are under-pinned.**
   - AC-5c is a unit row but asserts a 422, and it gives no red-on-base message. Assert the exception's code instead.
   - The `id_missing` counter (K-r3 #12) has no AC and no mutant. Add one to AC-15b, or mark it as logging only.
7. **The frontmatter claims more than happened.** `status: "pending approval (consensus: Critic APPROVE r3)"` was written before anyone reviewed r4, and the Architect's r3 verdict was REVISE. Reword it to reflect this round.

**What's missing:** nothing structural. The other r4 claims checked out against the code: OMS callers of `updateSkuFromProduct` (3), `createSkuBatch` (1), the 503 mapping on base, and the Spring Data merge trap.

**Justification:** I stayed in THOROUGH mode, with no CRITICAL or MAJOR finding. The realist check kept #1 at Minor rather than Major because SKUs with quotes or backslashes are rare, and missing them leaves only the exposure the r3 Critic already accepted on the next plain edit. The fix is a one-line `json_decode`, so fold it in anyway.

Files reviewed:
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-2624-evidence/plan-snapshot-r4.md`
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java`
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java`
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestEndpointExceptionHandler.java`
- `/Users/np1076/dev/spk/owl/v2/oms-laravel-api/app/Services/WmsApiService.php`
- `/Users/np1076/dev/spk/owl/v2/oms-laravel-api/app/Services/WmsFacilitySyncService.php`