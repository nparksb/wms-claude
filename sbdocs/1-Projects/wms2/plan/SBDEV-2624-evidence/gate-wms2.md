# SBDEV-2624 P0 TDD gate: wms2-api lane

Worktree `.claude/worktrees/wms2-api/SBDEV-2624` (branch `feature/SBDEV-2624-sku-rename-in-place`, base `7762aa64`), JDK 21.0.8. Nothing committed. No production behaviour implemented.

## Results

| Class | Method | AC | Kind | Observed | Key failure line |
|---|---|---|---|---|---|
| SkuRenameInPlaceIT | update_renameByPreviousSku_keepsRowIdAndStockunitFk | AC-1 | RF | RED | expected [X] found [X, N]: actual `[9530, 11828]` |
| SkuRenameInPlaceIT | update_byFacilityItemIdWithoutPreviousSku_recoversRename | AC-2a | RF | RED | X.item_nr expected B was C |
| SkuRenameInPlaceIT | update_idHitWithMismatchedPreviousSku_rejectsPrecondition | AC-2b | RF | RED | expected 2 rows found 3 |
| SkuRenameInPlaceIT | update_facilityItemIdOfOtherClient_isMiss | AC-3 | RG | GREEN | n/a |
| SkuRenameInPlaceIT | update_renameOntoExistingSku_422NamingBothIds | AC-4 | RF | RED | Y.name changed |
| SkuRenameInPlaceIT | collisionCheck_ignoresCachedMissForB | AC-4c | RF | RED | expected 422 was 500 |
| SkuRenameInPlaceIT | create_concurrentInsertOfSameSku_returns422Not500 | AC-4d | RF | RED | expected 422 was 500 (lock wait observed; exactly one (c,B) row) |
| SkuRenameInPlaceIT | create_returnsItemIdEqualToDbId | AC-5b | RF | RED | expected 200 was 204 |
| SkuRenameInPlaceIT | update_createBranch_returnsItemIdEqualToDbId | AC-5b | RF | RED | expected 200 was 204 |
| SkuRenameInPlaceIT | update_fullMiss_createsUnderClient | AC-5 | RG | GREEN | n/a |
| SkuRenameInPlaceIT | update_rename_evictsCachedMissForNewCode | AC-9 | RF | RED | expected X found N (expected 9530) |
| SkuRenameInPlaceIT | update_rename_rewritesStockrecordForClientExactCaseOnly | AC-10a | RF | RED | expected 0 was 3 |
| SkuRenameInPlaceIT | update_rename_transactionDetailIncludesPreRenameMovements | AC-10b | RF | RED | mutant 'no rewrite call': movement missing from B's history |
| SkuBatchCreateUpdateServiceUnitTest | upsertAll_failIfExists_recheckHit_throws | AC-5c | RF | RED | expected WebserviceBusinessExceptionClientSide(101) but nothing was thrown |
| SkuBatchCreateUpdateServiceUnitTest | upsertAll_plainUpdate_neverRenames | AC-6 | RG | GREEN | n/a |
| SkuBatchCreateUpdateServiceUnitTest | upsertAll_rename_rewritesStockrecordBeforeMutatingAndFlushingItemdata | AC-11 | RF | RED | AC-11 step 4a: wanted but not invoked findByClientIdAndItemNr(1, "B") |
| SkuBatchCreateUpdateServiceUnitTest | upsertAll_flushFailure_translated [9 cases] | AC-12 | RF | RED x9 | `<kind>` injected at the `<site>` saveAndFlush must surface as WBECS(105/109): no exception at the stub |
| SkuBatchCreateUpdateServiceUnitTest | upsertAll_createBranch_rechecksRepositoryBeforeInsert | AC-13 | RF | RED | mutant 'drop the re-check': inserted a new row (id null) |
| SkuRestControllerUnitTest$ItemIdsContract | create_returns200WithItemIdsBySku | AC-7a | RF | RED | expected 200 was 204 |
| SkuRestControllerUnitTest$ItemIdsContract | update_returns200WithItemIdsBySku | AC-7a | RF | RED | expected 200 was 204 |
| SkuRestControllerUnitTest$DeleteByFacilityItemId | delete_byFacilityItemId_casOnSku_matchDeletesX | AC-14 | RF | RED | wanted but not invoked delete(X) |
| SkuRestControllerUnitTest$DeleteByFacilityItemId | delete_byFacilityItemId_casOnSku_mismatchRejects | AC-14 | RF | RED | mutant 'drop the CAS': base deleted the (c,B) row found by code |
| SkuRestControllerUnitTest$DeleteByFacilityItemId | delete_facilityItemIdOfOtherClient_fallsBackToCode | AC-14 | GREEN on base | GREEN | see "Unexpected passes" |
| StockrecordRenameQueryShapeUnitTest | renameItemdataForClient_predicateMatchesIndexAndClient | §3.4 | RG | GREEN | n/a |
| WmsConstantsSkuRenameUnitTest | codes108and109_haveTextAndNameArms [108, 109] | 108/109 | RF | RED x2 | mutant 'drop the text arm': code 108/109 renders the generic text |
| ItemdataRepositorySdrExportUnitTest | findByIdAndClientId_isNotExported | SDR | RF | RED | mutant 'remove the annotation': no @RestResource |

Every RF test is red at its stated assertion. None is a compile error, setup NPE or UnsupportedOperationException.

## RG mutants (each applied temporarily, the file restored from a backup, then `cmp`-verified)

| Row | Mutant | Result |
|---|---|---|
| AC-6 | always call `renameItemdataForClient` in the update branch | RED: "mutant 'always call rewrite' ..." |
| §3.4 | delete `lower()` from the @Query | RED: "mutant 'delete lower()' ..." |
| AC-14 fallback | the code lookup returns `Optional.empty()` | RED: "the code fallback must delete (c,B)=V" |
| AC-3 (PG) | the controller resolves `facility_item_id` with an unscoped `findById` | RED: "X.item_nr changed — mutant 'drop clientId ...'" |
| AC-5 (PG) | a miss throws `ENTITY_DOES_NOT_EXISTS` (422) | RED: "no row — mutant 'miss -> 422 (PR #14 shape)'" |

`grep -rn MUTANT src/` finds no leftovers.

## Skeleton (compile-only) files

- `json/SkuDto.java`: adds `facility_item_id` (Long) and `previous_sku`. There is no `request_nonce`, because wms2 ignores it.
- `repo/jpa/ItemdataRepository.java`: adds `findByIdAndClientId` without `@RestResource`, on purpose, so the SDR row stays red until P1. Also declares `<S extends Itemdata> S saveAndFlush(S)`.
- `repo/jpa/StockrecordRepository.java`: adds `renameItemdataForClient`, @Modifying native, the plan's exact SQL, with no caller yet.
- `service/WmsConstants.java`: adds the constants 108 and 109 only.
- `service/SkuBatchCreateUpdateService.java`: injects `StockrecordRepository`, adds `boolean failIfExists` and the return type `Map<String, Long>`. The body is the base body and returns `new LinkedHashMap<>()`.
- `controller/rest/SkuRestController.java`: create passes `true` and update passes `false`. The return value is ignored, so the response is still 204.

Existing tests updated mechanically:

- `SkuRestControllerUnitTest` and `CacheEvictionOnWriteUnitTest`: `+anyBoolean()` on the upsertAll verifies.
- `SkuBatchCreateUpdateServiceUnitTest`: `boolean.class` and `false` in the reflection and call sites.
- Two rail inventories: `NeverMatcherNullBlindnessArchTest` gains `"SkuRestControllerUnitTest:4"` (a primitive param), and `TestClassTransactionManagerArchTest.EXEMPT_NON_TRANSACTIONAL` gains `SkuRenameInPlaceIT`.

## Adjustments vs the plan / brief

1. **108/109 text arms are NOT in the skeleton.** The brief said "with BOTH text arms", but the plan labels `WmsConstantsSkuRenameUnitTest` as RF. With the arms in place it would pass on base. P1 adds both arms.
2. **ItemdataRepository is not a JpaRepository.** The plan's `saveAndFlush` did not exist, so the skeleton declares it. Spring Data routes it to `SimpleJpaRepository`. The IT lane booted the context with it.
3. **AC-5b red message is "expected 200 was 204".** The plan's alternative ("expected <id> was null") assumed the skeleton returns 200. That would be behaviour, so the controller stays at 204.
4. **AC-14 is split into 3 methods**, one per sub-case. `delete_byFacilityItemId_casOnSku` became `_matchDeletesX` and `_mismatchRejects`.
5. **AC-12 is one `@ParameterizedTest`** whose display names render the plan's 9 `upsertAll_{kind}At{site}_translated` names. A lock timeout is modelled as `CannotAcquireLockException` (a `PessimisticLockingFailureException`). The 105 at the plain-update site asserts the code only, because the plan fixes no arguments for it.
6. **IT harness:** MockMvc `standaloneSetup` with the real `RestEndpointExceptionHandler`. There is no IdempotencyFilter, which would replay identical bodies. Each request names `unit_identifier_id=BOTTLE` (seeded itemunit 0), because `Itemdata.handlingunitId` is @NotNull. Fixed ids are in the band 9520-9549, which is unused elsewhere, and cleanup by client id runs in both @BeforeEach and @AfterEach.
7. **P1 must change an existing test.** `SkuBatchCreateUpdateServiceUnitTest.upsertAll_shouldRollbackEntireBatch_whenSaveFails` stubs `save` to throw a DIVE and expects it to propagate. AC-12 requires `saveAndFlush`, translated to 105, so that test has to be updated in P1, not deleted.

## Unexpected passes

- **`delete_facilityItemIdOfOtherClient_fallsBackToCode` is GREEN on base.** This is inherent: base never reads `facility_item_id`, so it always takes the code fallback. It still guards P1, because an unscoped `findById` stub returns client d's X with the same code. It was proven by the fallback mutant above.
- AC-3 and AC-5 are RG by plan and green as expected.

## Full-suite baseline (`mvn clean test`, after the concurrency check)

`Tests run: 7811, Failures: 19, Errors: 0, Skipped: 1`. All 19 failures are the new RF unit cases; there are 0 pre-existing failures. The full list is in `baseline-wms2.txt`. The failsafe IT is not part of `mvn test`. Its result when run alone is 13 run, 11 RF red and 2 RG green.
