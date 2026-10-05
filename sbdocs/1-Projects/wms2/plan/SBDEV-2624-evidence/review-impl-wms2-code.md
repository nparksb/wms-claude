# SBDEV-2624 Phase 3b code review: wms2-api

head: 086cb309b196127b35ea87f16a091f50075d107f (worktree .claude/worktrees/wms2-api/SBDEV-2624; `git diff origin/develop...HEAD`, gate 39500235 + 7 commits)
Reviewer lane: code-reviewer, separate from the implementer and the conformance lanes. Static review only. I did not run Maven, because another worktree's build (SBDEV-3636 `mvn -o clean verify`, pid 69088) was running and the rules forbid running two at once. The conformance lane's fresh run (7821/0/0/1, IT 13/13) is the dynamic evidence.

## Summary
Files reviewed: 6 main, 11 test. Findings: High 0 · Medium 1 · Low 8.
Verdict: **COMMENT**. Please fix M1 before merge. It is a deviation from the plan with a data-integrity effect, and I disagree with the conformance lane's "Info" rating of it.

## Medium

### M1: the "by-id recovery" rename fires on rows that were not found by id
File: `src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java:143` (in `rename`). Confidence: HIGH on the logic; the reachability window is narrow.
```java
if (previousSku == null) {
    // A plain edit that found the row by id: the recovery path for an earlier failed rename.
    LOG.warn("SBDEV-2624 SKU_RENAME_BY_ID_RECOVERY ...
```
Plan §3.3 step 3 allows a rename without `previous_sku` only for "a plain edit that **found the row by id**". The code never checks that the row was found by id. Any hint whose reloaded `item_nr` differs from the request code is renamed. That includes a row found by the **step-3 cached `sku` lookup**. Three ways to reach it:
1. **In-JVM race.** Request R1 renames X from A to B. R2 `{sku:A}` (no id, no previous_sku) resolves A → X through `itemdataService` before R1 commits and evicts. R2's `upsertAll` then reloads X (now B) and renames it back to A, rewriting stockrecord B→A.
2. **Cross-replica stale cache (G4).** Same outcome, for the full TTL.
3. **Same batch.** `[{sku:B, previous_sku:A}, {sku:A}]`: the controller maps "A" → X before `upsertAll` runs. Item 1 renames X to B, and item 2 renames it straight back.

On base, a stale cached entity merged with an old `@Version` and failed (OOLFE → 500). The reload removed that implicit guard. After D-M2 the OMS always sends `previous_sku` whenever it sends `facility_item_id`. So a `previous_sku == null` rename with no id hit can **never** be a legitimate recovery: it is always a stale hint. The effect is the S1 class: product A's WMS item, its stock and its stockrecord history get product B's code and fields. It is only logged, and the next guarded resend skips it as a bad map, so it stays stuck.
The unit test pins the hazard as intended behaviour: `SkuBatchCreateUpdateServiceUnitTest.java:576` `Arguments.of(null, null, "B", "sku", true)`.
**Fix:** in `upsertAll`, before calling `rename`, allow a rename with `previousSku == null` only when `sku.getFacilityItemId() != null && sku.getFacilityItemId().equals(row.getId())`. Otherwise treat the hint as stale: set `row = null` and fall through to the existing uncached re-check by `code`, which creates or plain-updates the real (c, code) holder. Then flip `viaCases` row 4 to "no rename, no stockrecord call". Add unit cases for the same-batch revert and the stale-hint case. An IT twin of scenario 3 would be cheap.

## Low

### L1: every DataIntegrityViolationException is reported as "duplicate value"
File: `SkuBatchCreateUpdateService.java:215`. Confidence: MEDIUM.
`catch (DataIntegrityViolationException e) → NOT_UNIQUE_VALUE "duplicate value sku B found in create"`. Spring maps 22001 (value too long, e.g. `image_filename`), 23502 and 23503 to DIVE as well. Those used to be 500s and now become a 422 that states a false cause: "duplicate value ... (concurrent insert)" on the rename site. The OMS behaviour does not change, because 105 is not a resend marker. The cost is the operator diagnosis.
**Fix:** map to 105 only when the most specific cause is a `SQLException` with SQLState `23505`, or a Hibernate `ConstraintViolationException` whose `getConstraintName()` is `uk3l3dgof3l6mc1dl7s3lmida65`. Let other violations escape as they did before, or give them a neutral code. Add one AC-12 case with a non-unique DIVE.

### L2: `previous_sku: ""` is "absent" in the controller but "present" in the service
Files: `SkuRestController.java:461` (`!sku.getPreviousSku().isEmpty()` skips step 2) and `SkuBatchCreateUpdateService.java:137` (`previousSku != null && !oldCode.equals(previousSku)`). A whitespace or empty `previous_sku` is trimmed to `""` by `normalize()`. On an id hit at another code, the request then gets a spurious 108 instead of the recovery path (or, after M1, the stale-hint path).
**Fix:** in `normalize()`, set `previousSku` to `null` when it is empty after trim. Add a unit test for trim → null. There is currently no test of `previous_sku` trimming at all.

### L3: `item_ids` is keyed by SKU alone
File: `SkuBatchCreateUpdateService.java:103/111/121` (`ids.put(code, ...)`). In a batch that spans two clients with the same SKU code, the second id silently overwrites the first, and the OMS records the wrong id for one facility row. `existingByClient` is client-keyed, but the response is not. The plan fixes the `{sku: id}` shape (PR #14), so this is a contract limitation, not a bug against the plan.
**Fix:** reject a batch with a duplicate (client, sku) up front with 105, or at least `LOG.warn` on overwrite (`if (ids.put(...) != null)`). Document that `item_ids` assumes one client per call.

### L4: duplicate request keys in one update batch share a single resolved row
File: `SkuRestController.java:250` (`existingByClient.get(...).put(sku.getSku(), itemdata)`). Take `[{sku:B, facility_item_id:X}, {sku:B, facility_item_id:W}]`. The second resolution overwrites the first, so both DTOs are applied to W. This is an edge case, since the OMS sends one SKU per update.
**Fix:** same up-front duplicate-key rejection as L3.

### L5: no test for a failure inside the native rewrite
The `translate()` at the rename site wraps `renameItemdataForClient`, which is the likeliest place for 55P03 (row locks held by a concurrent rename of the same code). AC-12 injects only at `saveAndFlush`, and no `src/test` stub throws from `renameItemdataForClient` (grep: 0 hits). If the rewrite were moved out of the wrapper, every test would stay green.
**Fix:** add an AC-12 case: `when(stockrecordRepository.renameItemdataForClient(...)).thenThrow(new CannotAcquireLockException(...))` → 109 `"item_id=X, retry"`, and `saveAndFlush` never called.

### L6: AC-4d's lock-wait probe is not specific to the create's session
File: `SkuRenameInPlaceIT.java:420`: `SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()`. The Testcontainers postgres is reused across worktrees, so another build's lock wait can satisfy the probe. The result is a flaky red (the 101 or "duplicate value" assertion fails), not a false green. Separately, `pool.shutdownNow()` (`:398` executor) runs only on the `pending.get` path. An exception inside the try-with-resources leaks the thread.
**Fix:** capture `raw`'s `pg_backend_pid()` and poll `SELECT count(*) FROM pg_stat_activity WHERE pg_blocking_pids(pid) @> ARRAY[<rawPid>]`. Wrap the whole body in try/finally around `shutdownNow()`.

### L7: IT leaves committed message-log rows behind
`wipe()` (`SkuRenameInPlaceIT.java`, the `for (String table : ...)` loop) deletes stockrecord, stockunit, unitload, itemdata and client by the class's client ids. Every request through the handler also commits a `messageService.createMessage(...)` row (SKU_IMPORT/SKU_UPDATE, RECEIVED/FAILED), and those are never removed. wms2 repository/IT writes commit (`NOT_SUPPORTED` here), so they accumulate in the reused container. Confidence: MEDIUM. I did not open the message table.
**Fix:** also delete the message rows written by this class, for example by a payload marker such as `SBDEV2624C`, or record max(id) in `@BeforeEach` and delete above it.

### L8: style nits
- `Write<T>` (`SkuBatchCreateUpdateService.java`, `@FunctionalInterface private interface Write<T>`) adds nothing over `java.util.function.Supplier<T>`, since no checked exception is declared. Use `Supplier<T>`.
- `via()` reports `previous_sku` when the step-3 `sku` hit carries `previous_sku == existing.itemNr`. That is reachable after D-M2 only on the 108 log line. The conformance lane already noted that `via` is approximate; it is log-only. Passing the controller's actual step as a side map (plan §3.2 C4) would make it exact and would also give M1 its signal for free.

## Checked and found correct
- **Transaction and flush order.** `@Transactional("tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide, BusinessException})` is unchanged and pinned. Every DB write sits inside `translate()` and is flushed there, and the translated exception is a checked rollbackFor type, so commit raises nothing new. The participating `SimpleJpaRepository` call marks the tx rollback-only first; that is consistent, with no UnexpectedRollbackException path. In `rename`, the reloaded `row` and the cached `existing` stay unmutated until after the native UPDATE, so Hibernate AUTO flush has nothing dirty to push early. The collision JPQL also runs on a clean session. Earlier batch items are already flushed. The itemdata key-changing UPDATE (FOR UPDATE) is the last statement of the rename, so it is held from flush to commit. The extension across later items in a multi-rename batch is acknowledged in §7.5 #4.
- **Version check.** The reload means only the reload→flush window is version-checked. A concurrent rename of the same row blocks on the stockrecord row locks or the itemdata row lock, re-evaluates, and loses with OOLFE → 109. Its rewrite rolls back. This matches §3.3.
- **CAS / D-M2.** `previousSku != null && !oldCode.equals(previousSku)` covers `previous_sku == sku` with the row at another code → 108, no write, no rewrite. It is pinned by `upsertAll_previousSkuEqualsSku_rowAtOtherCode_throws108`, which asserts the exact description the OMS regex parses.
- **Client scoping.** Step 1 and the delete use `findByIdAndClientId`. Steps 2 and 3, the re-check and the collision check all take `clientId`. The rewrite is scoped to `client_id` plus the exact-case conjunct (AC-10a IT).
- **Create path.** `saveAndFlush` returns the merged copy and `saved.getId()` is used (AC-5b IT). `failIfExists` turns a re-check hit into 101. A duplicate SKU inside one create batch now yields a clean 101 instead of a 500 at commit. On a 200-SKU batch the cost is one extra indexed SELECT plus a flush per item. Per-flush dirty checking over ≤200 managed entities is negligible.
- **Cache.** The `finally` eviction is untouched on all three handlers, AC-9 covers the cached miss, and the cached detached entity is no longer mutated in place. The base code mutated Caffeine-held instances; that is now gone.
- **SDR.** `findByIdAndClientId` and `saveAndFlush` are `exported = false`. Itemdata writes are already withdrawn (W14). `StockrecordRepository` is type-level unexported.
- **Logging.** All new lines use parameterized SLF4J and carry ids and codes only, with no PII or secrets. The WARN/INFO tokens match §7.4.
- **108/109.** Text and name arms are present. The prefixes end before the first placeholder and match the OMS markers (the conformance lane verified this cross-repo).

## Positive observations
- `translate()` with fixed per-site arguments is the right answer to "the PG tx is aborted, never re-query". The comment explains why.
- The AC-11 test captures `row.getItemNr()` *at the moment of the rewrite call*. That is a direct probe of the auto-flush hazard, not a proxy.
- AC-4d drives a real second PG session and refuses to pass without an observed lock wait, so it has a positive control.
- Assertions check row state first and status second, and assertion messages name the mutant they kill. The mutation evidence (hand mutants plus PIT 45/47) is unusually strong.

## Open questions (not blocking)
- Legacy rows with a padded `item_nr` (pre-260610). An id hit plus D-M2 `previous_sku = "A"` against the DB value `"A "` gives 108 on every plain edit until the guarded resend renames it. That heals the row, but it means one 108 and one resend per such product. Worth a one-off `SELECT count(*) FROM itemdata WHERE item_nr <> trim(item_nr)` per prd tenant before rollout.

## Recommendation
**COMMENT.** No High at high confidence. Fix M1 (small: one condition plus test updates) before merge, plus L1/L2/L5, which are cheap. The rest can be handled in the same pass under the address-Lows rule.
