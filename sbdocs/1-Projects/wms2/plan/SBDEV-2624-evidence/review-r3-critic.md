**VERDICT: APPROVE** (12 Minor findings, all fixable as text or test edits without a redesign)

All ten of my r2 findings are fixed in the plan body. That includes r2 #1, the only MAJOR. Most of the new r3 material passes the gate. I found no CRITICAL or MAJOR issues. The biggest Minor is #1: the r3 automatic resend undoes one of the safeguards S1 claims.

**Checked against:** wms2 origin/develop `62c92dd5` and OMS origin/develop `dad34d7e`, via `git show`/`git grep`. No architect file was read.

### (1) r2 findings 1–10
| r2 | Status | Evidence |
|---|---|---|
| 1 MAJOR, backfill keep rule | **Fixed** | §0 P2 names both pruning entry points. Confirmed: `backfillFacilityItemMap` (:997) calls `recordSeen` → `recordFullObservation` → `pruneStale` (:1045) with no gate. Callers are `BackfillFacilityWmsItemsCommand:68` and `Job:56`. The job is dispatched only by the `2026_07_23_100001` migration. The plan now has the keep rule, `code_drift` in the return, logging in both callers, AC-15b, mutant #12, M-7 and S3 |
| 2 AC-4c | Fixed | It now asserts `item_id=<Y>` in the description (but see #3) |
| 3 AC-9 | Fixed | Relabelled RF, red "expected X found N" |
| 4 AC-2b | Fixed | Row count is asserted first. On base the request creates (c,B), so 3 rows: red is correct |
| 5 mutant list | Fixed | #13–#19 match the table's AC-7b/7e/7f/8c/8e/8h rows. #9 may be unkillable (#8) |
| 6 S6/G7 residual | Fixed | |
| 7 global writer / count | Fixed | `backfillWmsItemIds` :980 `$product->wms_item_id = (int) $itemNrToId[$sku];` is listed. The dead branch at :1104 and the FAILURE text at :973 exist. The deletion is not gated by any test (#6) |
| 8 verify rows | Fixed | The shape rows are dropped. One cross-repo row is kept (#10) |
| 9 threading | Fixed | `buildSkuPayload` (:1770) is `$payload = $data;`, so per-facility keys pass through. `$newlyResolvableAliases['previous_identity']` exists (:807/:822) |
| 10 lane, M-7, side effect, code | Fixed | |

### (2) Gate on the new r3 material
- **Codes 108/109:** both are free. The 100 group ends at `CHILD_NOT_PART_OF_PARENT = 107;` and `= 10[89];` has 0 hits in `src/main`. The exception constructor `(int, Throwable, Object...)` passes `getErrorCodeText` into `error.setDescription`, and both create and update return `e.getErrorMap()`. So the marker does reach the OMS `getTechnicalDetails()` ("HTTP {$statusCode}: {$rawResponse}"). Pass, apart from #4.
- **AC-4d:** RF on base is correct. Base defers the INSERT to commit, the unique violation raises a DataIntegrityViolationException, and `RestEndpointExceptionHandler`'s `@ExceptionHandler(Exception.class)` (:84) turns it into a 500. The mutant prediction holds. Pass, apart from #11.
- **AC-7e, AC-8h:** pass. Base delete sends `$product->wms_item_id ? (int) $product->wms_item_id : null` (WmsApiService ~:1749).
- **AC-15b:** pass. No existing test calls `backfillFacilityItemMap`, so the fixture has to fake `readWmsCollection`.
- **AC-7f:** two scenarios in one AC, and incomplete (#7).
- **Mutants #12–#19:** each maps to a row. Several OMS rows have no stated red message (#9).
- **Verify row:** cross-repo and fail-closed, but under-specified (#10).

### Minor findings
1. **The N2 resend undoes the CAS that S1 lists as a safeguard.** S1 lists `"CAS whenever previous_sku is present (AC-2b)"`. In the bad-map case (X is really another product's item, still at code D), the first request gets a 108. The OMS then resends with no `previous_sku` and the same `facility_item_id`. That takes the id-recovery path and renames X from D to B. r2 already allowed this on the *next plain edit*. r3 makes it happen immediately, including for products that are never edited again.
   - *Mitigated by:* the ambiguity guard (AC-8f) and the `SKU_RENAME_BY_ID_RECOVERY` WARN. The rename is reversible.
   - **Fix:** correct the S1 text. Optionally, parse `"item_id=X is D"` from the 108 response and skip the resend when another active OMS product of the same client has SKU D. Include D in the `resync-resend` log line.
2. **§6 misstates base behaviour.** It says lock and optimistic conflicts return 422 `"instead of … a 500"`. On `/rest` today, `CannotAcquireLockException` and `DeadlockLoserDataAccessException` return **503 with Retry-After 30** (RestEndpointExceptionHandler:49–59). Only an optimistic-lock loss hits the 500 catch-all. Catching `PessimisticLockingFailureException` therefore replaces a 503-retryable contract with 422/109. Say so.
3. **The text of the DataIntegrityViolationException → 422 translation is unspecified.** After a failed statement, the PG transaction is aborted, so the wrapper cannot look up Y. The create-branch case also has no X. AC-4c's mutant is killed only if the translated text omits Y. State the exact template, and state that the wrapper never re-queries.
4. **P0's skeleton list says `"constant 108"` only.** It must include 109, or the 108/109 row and AC-12 fail to compile instead of failing on assertions.
5. **The P2 acceptance grep can never pass as worded.** `"git grep -n wms_item_id over OMS app/ must show only Product fillable/cast and ProductWmsItem"` will always fail: `WmsApiService` (7 hits) and `WmsFacilitySyncService` (12 hits) correctly use the `ProductWmsItem` column, and the plan adds more (`pluck('wms_item_id', …)`). Grep for the global-column forms instead, e.g. `->wms_item_id\b` on a `Product` and `Product::where('wms_item_id'`.
6. **No test covers deleting the `backfillWmsItemIds` global write.** Completeness check #2 claims `"R1 (AC-16, all 4 files)"`, but AC-16's tests cover only the three readers. Add a `FacilityWmsSyncTest` assertion that `product.wms_item_id` stays NULL after reconcile, with a matching mutant, or say that the deletion is untested and harmless.
7. **AC-7f needs splitting and a third case.**
   - Split it into 7f (resend shape) and 7g (no id → no resend).
   - The stub must answer 108 to the resend as well, so `"exactly one"` actually checks the loop limit.
   - Add a 109 case; the marker branch for 109 is currently untested.
8. **Mutant #9 (C1 uses `wasChanged`) probably can't be killed by AC-8e.** I saw a single `$product->update($validatedData)` in the slice of the closure I read (ProductController ~:771). Either add a test that kills it (a closure that saves twice) or record it as an equivalent mutant.
9. **Most OMS RF rows give no red-on-base message.** P0 requires `"go red on base with the stated message"`, but AC-7b, 7c, 7e, 7f, 8a–8h and 16 state none. Add the messages.
10. **The verify row needs four clarifications.**
    - **Extraction anchor:** §3.5 uses inline `contains` strings, which give the script nothing stable to extract. Name an OMS constant (e.g. `WMS_RESYNC_MARKERS`).
    - **Red on base:** this only exercises the fail-closed branch. Also show it red on a one-word rewording in a shadow copy. A check against a literal cannot otherwise detect a narrowed pattern.
    - **PROJECT_ROOT:** it must be the symlink shadow root holding **both** worktrees, at `v2/wms2-api` and `v2/oms-laravel-api`.
    - **`%Ns` stripping:** unnecessary for a prefix check, and it would not match a `%1$s` form, which WmsConstants itself recommends.
11. **AC-4d fixture details.**
    - The second connection must be a raw tenant-DataSource connection with an explicit commit. The context JdbcTemplate (landlord pool, autocommit off) never commits.
    - The POST has to run on its own thread.
    - Assert the row before the status, per the §7.1 ordering rule.
12. **Backfill inversion can silently miss drift.** `$itemsByClientId[…][$itemNr] = $row['id'] ?? true` means an `itemdata_list` row without an id cannot be inverted, so the keep rule falls back to pruning without any signal. Count such rows in the backfill log.

### What's missing
- The bad-map case of the resend (#1).
- A test for the 109 resend (#7).
- A test for the 4th-writer deletion (#6).

### Pre-commitment check
I predicted:
- the new r3 rows would mislabel RF/RG: partly true (missing messages);
- the base error behaviour would be misstated: true (#2);
- the resend would interact badly with the CAS: true (#1);
- the AC-15b fixture would be infeasible: false.

### Verdict justification
I stayed in THOROUGH mode: no CRITICAL, no MAJOR, no systemic pattern. The realist check kept #1 at Minor, mitigated by the ambiguity guard (AC-8f), the `SKU_RENAME_BY_ID_RECOVERY` detector, and the fact that the rename can be reversed. r2 had already accepted the same exposure on the next plain edit. If the author declines the resend guard in #1, that needs Nam's explicit sign-off, because it is a data-integrity trade.

### Open questions (unscored)
- Does any model event or observer save `Product` a second time inside the C1 closure (this decides whether #8 is a real mutant)?
- The create re-check (`"If a row is found, use the update branch"`) lets a new OMS product silently take over a stuck item's attributes and id. Is that an existing behaviour to note under S1?

*Ralplan summary row*
- **Principle/option consistency:** Pass (#1 is a stated-safeguard inconsistency, not a driver conflict).
- **Alternatives depth:** Pass.
- **Risk/verification rigor:** Pass with the Minor fold-ins (#3, #7, #9, #10).
- **Deliberate additions:** Pass (pre-mortem S1–S6, observability tokens, weekly queries).