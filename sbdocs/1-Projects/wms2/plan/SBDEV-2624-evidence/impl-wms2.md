# SBDEV-2624 P1: wms2-api implementation report

The work is in the worktree `.claude/worktrees/wms2-api/SBDEV-2624`, branch `feature/SBDEV-2624-sku-rename-in-place`, on top of the gate commit `39500235`. Every run used JDK 21.0.8 (`mvn -v` checked). Nothing was pushed or rebased. I did not touch `v2/wms2-api`.

## Commits (`39500235..HEAD`)

| SHA | Subject |
|---|---|
| `b66ada2a` | SBDEV-2624: contract — codes 108/109 with text and name arms, findByIdAndClientId not exported |
| `10436713` | SBDEV-2624: upsertAll renames in place — reload, CAS, collision, ordered rewrite, translated flushes |
| `87a5a30a` | SBDEV-2624: SkuRestController resolves by facility_item_id -> previous_sku -> sku and answers 200 with item_ids |
| `c3593489` | SBDEV-2624: AC-10b — filter transaction_detail on its display label 'Received' |
| `a63b3d89` | SBDEV-2624: mutation follow-up — kill PIT survivors in SkuBatchCreateUpdateService |
| `41db9792` | SBDEV-2624: upsertAll — orElse(null) instead of Optional.get() (OptionalSafetyArchTest) |
| `086cb309` | SBDEV-2624: D-M2 — pin the CAS when previous_sku == sku and the row holds another code |

## Story → plan §

| Story | Plan | Commit | Files |
|---|---|---|---|
| Contract: 108/109 text and name arms, SDR `@RestResource(exported = false)` on `findByIdAndClientId`, DTO comment | §3.1, §0 W8/W10b/W10c | `b66ada2a` | `WmsConstants`, `ItemdataRepository`, `SkuDto`, `StockrecordRepository` (comment only; the SQL is the gate skeleton's, unchanged) |
| `upsertAll`: reload the row; uncached re-check on a miss (create endpoint → 101); CAS (108); direct collision check (105 naming X and Y); `renameItemdataForClient` **before** any entity mutation; `saveAndFlush` on every write inside `translate()` (DIVE → 105; `PessimisticLockingFailureException` / `ObjectOptimisticLockingFailureException` → 109, fixed arguments per site); returns `Map<String, Long>` in request order; the create branch reads the id from `saved` (the merged copy) | §3.3 | `10436713`, `41db9792` | `SkuBatchCreateUpdateService` |
| Controller: lookup order `facility_item_id` (uncached, client-scoped) → `previous_sku` → `sku`, keyed by the request sku (C4); 200 `{status, item_ids}` from create and update; message-log status `200`; `normalize()` trims `previous_sku`; delete compare-and-set (400 + `SKU_DELETE_PRECONDITION`) with fallback to the code lookup | §3.1, §3.2, Q4 | `87a5a30a` | `SkuRestController` |
| stockrecord rewrite: the query is unchanged from the gate skeleton and is now called from §3.3 step 4b | §3.4 | `10436713` | — |
| WARN/INFO tokens: `SBDEV-2624 SKU_RENAME` (INFO, with `via` and `stockrecordRows`), `SKU_RENAME_COLLISION`, `SKU_RENAME_PRECONDITION`, `SKU_RENAME_BY_ID_RECOVERY`, `SKU_DELETE_PRECONDITION` (WARN) | §7.4 | `10436713`, `87a5a30a`, pinned by `a63b3d89` | — |
| D-M2 pin (coordinator, Nam 2026-10-02) | §10 D-M2 | `086cb309` | test only; no production change was needed |

Existing tests updated, none deleted:
- `upsertAll_shouldRollbackEntireBatch_whenSaveFails` now stubs `saveAndFlush`. It expects `WebserviceBusinessExceptionClientSide(105)` caused by the DIVE, which is still a `rollbackFor` exception. This is gate adjustment 7.
- create/update `204 → 200` in four places:
  - `SkuRestControllerUnitTest` ×2
  - `CacheEvictionOnWriteUnitTest` ×1
  - `SkuRestControllerAtomicityIntegrationTest` ×2
  - `SkuRestControllerIntegrationTest` ×2 (create, update)
- The delete 204 assertions are unchanged. `IdempotencyFilterUnitTest`'s 204 is a generic replay fixture, not `/rest/sku`, and was left alone.

## Gate test results (final code, HEAD `086cb309`)

| Lane | Command | Result |
|---|---|---|
| Unit gate + related | `mvn -o test -Dtest=SkuBatchCreateUpdateServiceUnitTest,SkuRestControllerUnitTest,StockrecordRenameQueryShapeUnitTest,WmsConstantsSkuRenameUnitTest,ItemdataRepositorySdrExportUnitTest,OptionalSafetyArchTest,NeverMatcherNullBlindnessArchTest` | **64 run, 0 F, 0 E**. Breakdown: `SkuBatchCreateUpdateServiceUnitTest` 25 (2 pre-existing + 13 gate + 10 new); `SkuRestControllerUnitTest` `$ItemIdsContract` 2, `$DeleteByFacilityItemId` 3, `$Create` 10, `$Update` 7, `$Delete` 8; `WmsConstantsSkuRenameUnitTest` 2; `StockrecordRenameQueryShapeUnitTest` 1; `ItemdataRepositorySdrExportUnitTest` 1 |
| Also green earlier | `CacheEvictionOnWriteUnitTest` 17, `TenantCacheKeyUnitTest` 10, `TestClassTransactionManagerArchTest` 5 | 0 F |
| PG IT | `mvn -o verify -Dit.test=SkuRenameInPlaceIT,SkuRestControllerIntegrationTest,SkuRestControllerAtomicityIntegrationTest -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | **`SkuRenameInPlaceIT` 13/13**, `SkuRestControllerIntegrationTest` 3/3, `SkuRestControllerAtomicityIntegrationTest` 3/3 (TenantCacheKey and SdrWriteWithdrawal "keep green" rows: see the full suite) |

All 28 gate rows are green. That is the 26 RF rows (13 IT, 13 unit) plus the 2 RG rows.

## PIT: `SkuBatchCreateUpdateService` (JDK 21, scoped per the wms-triage floor item 3 recipe)

| Run | Generated | Killed | Survived | No coverage | Line coverage |
|---|---|---|---|---|---|
| 1 (gate tests only) | 47 | 14 (30%) | 28 | 5 | 89% |
| final (after `a63b3d89`, `086cb309`) | 47 | **45 (96%)** | 2 | 0 | 100% (93/93) |

Run 1 survivors were killed by the 9 tests in `a63b3d89`:
- field mapping on create, plain update and rename (setters, the box-type and item-unit ternaries, the version/entity-lock seeds);
- the `item_ids` return, with the merged-copy id;
- CAS 108 and collision 105, each with no rewrite and no write;
- `SKU_RENAME` `stockrecordRows`, `via` (4 cases) and `SKU_RENAME_BY_ID_RECOVERY`.

Final survivors, both **equivalent**:
1. `:119 lambda$upsertAll$1`, "replaced return value with null". This is the step-5 `translate(() -> itemdataRepository.saveAndFlush(target), …)` lambda. Its result is discarded: the row is managed, so the code uses `row`/`itemId`, not the merge return. No observable effect.
2. `:96 removed call to setScale`. `Itemdata.scale` has the field initializer `private Integer scale = 0;` (`Itemdata.java:25`), so `setScale(0)` on a fresh `new Itemdata()` is a no-op.

## Hand mutants (copied to `/tmp/sbdev2624-mutants`, restored from there; every restore was `cmp`-verified; mtime touched after restore to force a recompile; one at a time, a concurrency check before each run)

Harness: `scratchpad/mutants.py`. Every expected test went red, and every row below is **KILLED** with an attributable message.

| # | Mutant (§7.1) | Lane | Red test → message |
|---|---|---|---|
| M1 | AC-1 ignore previous_sku | IT | `update_renameByPreviousSku_keepsRowIdAndStockunitFk`: "expected [X] found [X, N] — the rename created twin N" (AC-4/9/10 also red; they depend on the rename) |
| M2 | AC-2a skip step 1 | IT | `update_byFacilityItemIdWithoutPreviousSku_recoversRename`: "X.item_nr expected B was C — mutant 'skip step 1'" |
| M3 | AC-2b swap steps 1↔2 | IT | `update_idHitWithMismatchedPreviousSku_rejectsPrecondition`: "lookup order: previous_sku resolved before facility_item_id — Z=(c,A) was renamed" |
| M4 | AC-2b drop the CAS | IT | same test: "mutant 'drop CAS': X holds C, neither previous_sku A nor sku B" |
| M5 | AC-3 unscoped `findById` | IT | `update_facilityItemIdOfOtherClient_isMiss`: "X.item_nr changed — mutant 'drop clientId…'" |
| M6 | AC-4 collision check removed (re-run after `41db9792`) | IT | `update_renameOntoExistingSku_422NamingBothIds` and `collisionCheck_ignoresCachedMissForB`: "DIVE translated, but description lacks Y" |
| M7 | AC-4d create branch plain `save` | IT | `create_concurrentInsertOfSameSku_returns422Not500`: "expected 422 was 500 — mutant 'create branch back to plain save'" |
| M8 | AC-5b `itemData.getId()` | IT | both AC-5b tests: "expected <id> was null — mutant 'read itemData.getId()…'" |
| M9 | AC-5 miss → 422 | IT | `update_fullMiss_createsUnderClient`: "no row — mutant 'miss -> 422 (PR #14 shape)'" |
| M10 | AC-9 delete update's `finally` clear | IT | `update_rename_evictsCachedMissForNewCode`: "mutant 'delete the finally clear' gives 'found empty'" |
| M11 | AC-10a drop `client_id` (`OR TRUE`) | IT | AC-10a: "mutant 'drop client_id': client d's 'A' rows were rewritten" |
| M12 | AC-10a drop the exact conjunct | IT | AC-10a: red at "(c,'B') carries the old A rows, expected 3 was 4" (the 'a' row is the 4th). **Partly attributable:** the earlier assertion fires first, so the named `'drop the exact conjunct'` message is not reached. The cause is the right one. I left the gate test unchanged |
| **M13** | **AC-10b: skip the `renameItemdataForClient` call (coordinator request)** | IT | **`update_rename_transactionDetailIncludesPreRenameMovements` red with its own message: "mutant 'no rewrite call': the pre-rename RECEIVING movement is missing from B's history — expected 1L but was 0L".** `update_rename_rewritesStockrecordForClientExactCaseOnly` is red separately with "expected 0 was 3 — stockrecord (c,'A') not rewritten". This is the first time AC-10b has been seen failing for the right reason: in the gate it was red for the wrong one (see Deviation 1) |
| U1 | AC-7a return 204 | U | `create_/update_returns200WithItemIdsBySku`: "expected 200 was 204 — mutant 'return 204'" |
| U2 | AC-7a empty `item_ids` | U | both: "mutant 'empty map'" |
| U3 | AC-14 drop the delete CAS | U | `delete_byFacilityItemId_casOnSku_mismatchRejects`: "mutant 'drop the CAS'" |
| U4 | AC-14 code fallback returns empty | U | `delete_facilityItemIdOfOtherClient_fallsBackToCode`: "the code fallback must delete (c,B)=V" |
| U5 | AC-14 unscoped `findById` in delete | U | same test: "another client's item must never be deleted through facility_item_id" |
| U6 | §3.4 delete `lower()` | U | `renameItemdataForClient_predicateMatchesIndexAndClient`: "mutant 'delete lower()'" |
| U7 | 108 reword marker + 109 drop name arm | U | `codes108and109_haveTextAndNameArms[1]` "mutant 'reword a marker'"; `[2]` "mutant 'drop a name arm'" |
| U8 | SDR remove the annotation | U | `findByIdAndClientId_isNotExported`: "mutant 'remove the annotation'" |
| U9 | AC-11 `setItemNr` before the rewrite | U | AC-11: "mutant 'move setItemNr before the rewrite'… expected A but was B" |
| U10 | AC-6 always call the rewrite | U | `upsertAll_plainUpdate_neverRenames`: "mutant 'always call rewrite'" |
| U11 | AC-13 drop the re-check (re-run after `41db9792`) | U | AC-13 "mutant 'drop the re-check'"; AC-5c also red |
| U12 | AC-5c ignore `failIfExists` (mutant #23) | U | `upsertAll_failIfExists_recheckHit_throws`: "mutant 'ignore failIfExists'" |
| U13 | AC-12 plain `save` in step 5 | U | AC-12 PlainUpdate cases [3], [6], [9]: "mutants 'remove a catch' / 'plain save in step 5' -> no exception at the stub" |
| U14 | AC-12 remove the DIVE catch | U | AC-12 cases [1], [2], [3] (DIVE at all three sites) |
| **DM2** | **D-M2: the CAS ignores previous_sku when it equals sku** | U | **`upsertAll_previousSkuEqualsSku_rowAtOtherCode_throws108`: "mutant 'CAS ignores previous_sku when it equals sku': X at C was renamed to B by a plain edit"** |

Not hand-applied: AC-4c "collision check via the cached `ItemdataService`". The mutant needs a new constructor dependency, and `@InjectMocks` would inject null, giving an NPE rather than an attributable red. It is killed structurally by AC-11: `order.verify(itemdataRepository).findByClientIdAndItemNr(CLIENT_ID, "B")` requires the **direct repository** call. The IT's own guard for AC-4c ("description lacks item_id=Y") fired under M6.

## Full suite vs baseline

| | Command | Tests run | Failures | Errors | Skipped |
|---|---|---|---|---|---|
| Baseline (`baseline-wms2.txt`) | `mvn -o clean test` | 7811 | 19 (the gate RF unit rows) | 0 | 1 |
| Intermediate (before `41db9792`) | `mvn -o clean test` | 7820 | 1: `OptionalSafetyArchTest`, 3× `Optional.get()` in my `upsertAll`. **Caused by me**, fixed in production code in `41db9792` | 0 | 1 |
| **Final (HEAD `086cb309`)** | `mvn -o clean compile` → BUILD SUCCESS; `mvn -o clean test` | **7821** (= 7811 + 10 new tests) | **0** | **0** | 1 (same as baseline) |

`git status --short` is empty. Ignored entries outside `target/`: `.omc/` only (git-ignored). No ArchUnit store or other strays.

## Deviations from the plan

1. **Gate test edited: AC-10b literal (`c3593489`), accepted by the coordinator.** `transaction_detail` labels a RECEIVING stockrecord `'Received'` (V2.2.25: `CASE WHEN tr.received != 0 THEN ''Received''`). I confirmed this on the IT container, where the function returns `BEGINNING / Received / ENDING`. The gate filter `transaction_name = 'RECEIVING'` therefore counted 0 under every implementation, so AC-10b was red in the gate for the wrong reason. I changed only the literal. `== 1` is unchanged, and M13 shows it now goes red for the right reason.
2. **Delete compare-and-set failure reuses code 108** (accepted). The text is `sku rename precondition failed: item_id=X is A, expected B (delete)`, with HTTP 400 and `SKU_DELETE_PRECONDITION` WARN. The plan fixes no code for this 400. The OMS delete callers read no results and never resend (§3.5, A-r2 N6), so the resend marker does no harm.
3. **`via` is worked out in the service, not passed from a controller side map** (accepted). The gate's reflection test pins `upsertAll`'s parameter list, so it cannot take an extra argument. `via()` uses three rules:
   - `facility_item_id` when the id matches the row. This is exact: a step-1 miss means no row of this client has that id.
   - `previous_sku` when the cached hit holds previous_sku.
   - otherwise `sku`.
4. **Plain-update 105 arguments.** The plan fixes none. I used `"sku " + B`, `"update of item_id=" + X`. The gate asserts the code only.
5. **`Optional.get()` → `orElse(null)`** (`41db9792`) to satisfy `OptionalSafetyArchTest`. Behaviour is the same.

## Stopped on

Nothing. Two process notes:
- My **first** targeted unit run started while other worktrees' Maven (SBDEV-3636/3638) was running. It was unit tests only, with no shared Postgres. Every later run waited for `pgrep` to report no Maven process first.
- One background run was stopped by its time limit while still waiting for other Maven builds. It never ran Maven and was re-issued.

Not in P1 scope and still open: the M-5 UAT `EXPLAIN (ANALYZE)` gate (§3.4, pre-merge, needs a writable UAT session), and P2 (OMS).
