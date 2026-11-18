---
ticket: SBDEV-3128
phase: P1 (wms2-api)
artifact: implementation-report
date: 2026-11-02
worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3128 (feature/SBDEV-3128-location-default-fla-bounds @ 8171c80a, uncommitted)
status: PARTIAL. Implementation done, targeted lanes green. Verification STOPPED: the harness killed the broad IT run for low system memory and said not to restart it unasked
---

# SBDEV-3128 P1: implementation report

## Verdict

**The implementation is complete per plan r4 + D-1, but the DoD is not fully met.** Items 1, 2 and most of 3 are green with fresh numbers. The harness then killed the broad IT run (DoD 3, remainder) because the machine was critically low on memory (~130 MB free afterwards). Its notice said not to restart it on my own. I therefore did **not** run DoD 4 (full `mvn -o test`), DoD 5 (PIT + 41 hand mutants) or the rest of DoD 3. Everything needed to run them is prepared (below). Nothing is committed and nothing is stashed. No `checkout`, `restore` or `reset` was used.

## Files changed (`git diff --stat` + untracked)

```
 controller/FixLocationAssignmentController.java     |  30 +-   (+ resetBoundsToDefault, D-5 comment)
 controller/LocationController.java                  |  50 +-   (ctor + updateBoundDefaults, D-5 comments)
 repo/jpa/FixLocationAssignmentRepository.java       |  67 ++-   (5 native methods, getDetailView +4)
 repo/jpa/LocationRepository.java                    |  59 ++-   (4 methods, getDetailView +3)
 repo/projection/FixLocationAssignmentDetailView     |   5 +
 repo/projection/LocationDetailView                  |   4 +
 service/FixLocationAssignmentService.java           | 168 +++++-
 service/LocationService.java                        |   9 +
 service/ViewDtoService.java                         |  80 ++-
 test common/config/TestDatabaseConfig.java          |  28 +    (§3.8 H2 bean)
 test MobilePutawayServiceIntegrationTest (gate)     |  29 ++
 test Sbdev3017TrancheGateContextTest (gate)         |  10 +-
 test service/FixLocationAssignmentServiceIT         | 253 +++++  (C2 C4 C6 C10 C11 C18)
 test unit/config/FunctionGuardArchTest              |   6 +-   (see Deviations 3)
 test unit/config/TestClassTransactionManagerArchTest|  11 +-   (see Deviations 4)
 test FixLocationAssignmentControllerUnitTest        |  29 ++    (C12)
 test LocationControllerUnitTest                     |  74 ++-   (C12 + :38 ctor)
 test FixLocationAssignmentServiceUnitTest           | 575 ++++  (C1 C3 C5 C7 C8 C9 C11 C16 C17 C19)
 test LocationServiceUnitTest                        |  42 ++    (C15, C19b)
 test ViewDtoServiceUnitTest (gate + C13/C14 + D-1)  | 223 +++-
 20 files changed, 1713 insertions(+), 39 deletions(-)
?? src/main/resources/db/migration/V2.2.45__location_default_fla_bounds.sql   (76 lines, plan §3.1 lines 153-228 verbatim)
?? src/main/java/net/aim_ai/wms/repo/projection/LocationDefaultBoundsView.java
?? src/main/java/net/aim_ai/wms/json/LocationBoundDefaultsResult.java
?? (the 4 gate test classes, unchanged except MigrationIT +1 test, see Deviations 6)
```

## Per §5 step

- **Step 3: migration, repositories, projections, H2 bean.**
  - The migration was copied byte-for-byte from plan §3.1 with `awk 'NR>=153 && NR<=228'`, so the checksum-frozen header is exact. It includes `SET LOCAL lock_timeout = '5s'`.
  - The nine repository methods follow §3.2. Each has `@RestResource(exported = false)` and none has `@Transactional`. `lockById` is JPQL `select l.id` with `@Lock(PESSIMISTIC_WRITE)` and returns `Optional<Long>`. The probe is the exact information_schema query.
  - Flag writes use `@Modifying(flushAutomatically = true)`. `resetBounds` and `writeThroughInherited` use plain `@Modifying` with `version = version + 1, modified = :now`. `resetBounds` carries `and assignedlocation_id = :locationId`, and `writeThroughInherited` carries `and bounds_inherited`.
  - `LocationDefaultBoundsView` has `BigDecimal` getters. `LocationDetailView` gains +3 getters and `FixLocationAssignmentDetailView` +4.
  - The H2 bean `sbdev3128UnmappedColumns` (`@DependsOn("tenantEntityManagerFactory")`, on `landlordDataSource`) adds the four columns.
- **Step 4: service and views.**
  - The service follows §3.3: `Bounds` record, `systemDefaultBounds`, `effectiveDefaultBounds`, `lockAndResolveDefaultBounds`, `requireFlowbin` (extracted from `move()`, message unchanged), `requireFeatureColumns`, `validateDefaultBounds` and a private `markOverridden` helper.
  - **create:** the probe runs first. When true, `lockById` and the default read come before the unit load, then `save`, then `markInherited == 1` else `IllegalStateException`. When false, create takes today's path plus the probe only.
  - **move:** `requireFlowbin`. After the `:167` setter, if the probe is true and `findBoundsInheritedById` is true, the triple is re-seeded from the destination under the re-entrant `lockById`.
  - **adjust\*:** these are now `@Transactional(tenantTM, rollbackFor Business+Facade)`. When the probe is true, `markOverridden(id, version) == 1` runs after validation and before the setter; otherwise the method throws OOLFE.
  - **reset:** the guard runs first, then `findById`, `lockAndResolve`, `resetBounds == 1` else OOLFE, then `requestForItem`. It never saves or dirties the entity.
  - **edit:** steps 1–6 as §3.3, with one ordering note (Deviations 5).
  - **Views:** `ViewDtoService` adds +3 keys to `getLocationView` and the 10 new keys to the FLA view. The sysprop is read once per request through `SyspropService.getSysvalue`; an NFE yields `SYSTEM_INVALID` with a null triple. `boundsOutOfDate` compares with `compareTo`. The view also carries D-1 (below).
  - **`LocationService.getLocationDetails`:** +3 keys, only when the probe is true.
- **Step 5: controllers.**
  - `POST /v3/location/updateBoundDefaults` has a method-level `@RequiresFunction(WEB_UI_VIEW_STORAGE_LOCATION)`. It parses values with `new BigDecimal(v.toString())` and returns house-style 200 `{errors}` on `BusinessException`/`Exception`.
  - `POST /v3/fixedAssignment/resetBoundsToDefault` sits under the class gate and returns `getMessageResponse(..., "Updated")`.
  - `LocationController`'s ctor gains `FixLocationAssignmentService`. `new LocationController(` had one caller (`LocationControllerUnitTest:38`), and it is updated.
  - D-5: the stale comments at `FixLocationAssignmentController:22-24` and `LocationController` C15 **and C16** are fixed (C16 makes the same stale "KEEPS its SDR write surface" claim).
- **Step 6** (full verify, review lanes, docs, PR) is not reached; the main session owns it.

## D-1 (supersedes the plan's "fall back to 84")

- The `ViewDtoService:708` read is removed, together with `getStockPerLocation`'s `upperBound` parameter (one caller).
- **AC-18 gate tests:** they only asserted "no exception", and I checked that they do not encode 84. Both now **add** `verify(syspropService, never()).getSysvalue(UP)`.
- The padded test's two strict `when(getSysvalue(UP))` stubs became `lenient()`. Otherwise strict stubs would raise `UnnecessaryStubbing` against correct code. Scaffolding only; no assertion was removed.
- **Fallout in pre-existing tests (landmine, see below):**
  - 10 replenish-view tests in `ViewDtoServiceUnitTest` carried a strict `when(syspropService.getSysvalue(anyString())).thenReturn("100")` that only fed the removed read. I deleted those 10 stub lines.
  - `ReplenishClientScope.detailView_resolvesCallerScope_beforeAnyRead` (SBDEV-3668) InOrder-verified that removed read. Its order assertion now covers the remaining read (scope → order query), plus `verify(syspropService, never()).getSysvalue(any())`.
  - Its `@DisplayName` still says "before the sysprop read". I left it unrenamed; the reviewer may want it reworded.

## C1–C20, red-then-green evidence

**Method.** I added signature stubs first: the new service methods threw `UnsupportedOperationException`, and the adjust/create/move bodies stayed unchanged. Then I wrote the tests, ran them red, implemented, and ran them green.

| C | Tests (class · method) | Red (stub/old body) | Green |
|---|---|---|---|
| C1 | `FixLocationAssignmentServiceUnitTest$Create`: `create_probeTrue_seedsLocationDefault_andMarksInherited`, `_nullLocationDefault_seedsSysprop`, `_markInheritedZero_throwsIllegalState`, `_locksBeforeCreateUnitload` (+ `_unknownLocation_throwsBeforeCreate`) | 4 assertion failures + 1 UnnecessaryStubbing (old create never locked) | ✓ |
| C3 | `Adjust{Lower,Middle,Upper}Bound` · `marksOverridden`, `staleVersion_rejected` (×3) | 6 failures (no markOverridden / no OOLFE) | ✓ |
| C5/C7/C8/C16/C17 | `$UpdateLocationBoundDefaults`: `writesThrough`, `noInheritedFla_noTrigger`, `clear_revertsInheritedToSysprop`, `rejects_invalidTriple`[1-5] (36/60/60, 61/60/84, −1/0/1, partial-null, 24.00001; `never()` on probe/lockById/updateDefaultBounds/writeThroughInherited, bare `any()`), `rejectsSetOnNonFlowbin`, `allowsClearOnNonFlowbin` (+ `unknownLocation_throws`) | 11 red (UnsupportedOperation / wrong exception type) | ✓ |
| C9 | `$Reset`: `reset_locationDefault`, `reset_nullLocationDefault_usesSysprop`, `reset_zeroRows_throwsOptimisticLock` | 3 red | ✓ |
| C11 | `$MoveSuccessfulOperations$Move`: `inheritedReseeds`, `overriddenKeeps` (+ `probeFalse_neverReadsFlag`); nested inside MoveSuccessfulOperations to reuse its whole-UL fixture | 3 red (old move never read the flag) | ✓ |
| C19 | `$FeatureColumnsAbsent`: `create_probeFalse_legacyPath`, `adjust_probeFalse_noMarkOverridden`, `edit_/clear_/reset_probeFalse_rejected` | 5 red | ✓ |
| | **Run totals**, `FixLocationAssignmentServiceUnitTest` | **70 run, 22 F + 11 E = 33 red = exactly the new tests**; the 37 pre-existing all green (L-2 precondition holds) | **70/70** |
| C13 | `ViewDtoServiceUnitTest$Sbdev3128DefaultBoundsViews`: `fixedAssignmentView_locationDefault_reportsLocationSource`, `_boundsOutOfDate_trueWhenInheritedAndSyspropDiffers`, `_falseWhenEqual` (24.0000 vs 24), + `_falseWhenOverridden` | Red with the `putBoundsProvenance` call disabled on a saved copy, then restored (`cmp` → RESTORED) | ✓ |
| C14 | extended `locationView_includesDefaults` (values 24/36/48) | **Not yet seen red**: my BSD-sed disable of the three puts did not apply. It is queued as hand mutant `VIEW-AC14b-drop-put` | ✓ |
| C15 / C19b | `LocationServiceUnitTest$GetLocationDetails`: `locationDetails_includesDefaults`, `locationDetails_columnsAbsent_omitsKeys` | 1 F + 1 UnnecessaryStubbing | 25/25 |
| C12 | `LocationControllerUnitTest$UpdateBoundDefaults` ×3 (set, nulls clear, `{errors}`); `FixLocationAssignmentControllerUnitTest$ResetBoundsToDefault` ×2 | Handlers stubbed to `ok().build()`: 5 red ("No value at JSON path") | 44/44 with EndpointContract |
| C2 C4 C6 C10 C11-IT C18 | `FixLocationAssignmentServiceIT`: `create_marksInheritedOnRealPg`, `markOverridden_staleVersion_noRow`, `edit_writesThroughInheritedOnly`, `resetBounds_afterMove_noRow`, `move_inheritedTakesDestinationDefault`; `$AdjustCommitted.adjust_flipsFlagOnRealPg` (method-level NOT_SUPPORTED, TransactionTemplate seed, @AfterEach purge); `$CreateEditRace.createThenEdit_flaHasEditedDefault`, `editThenCreate_flaHasEditedDefault` (HeldRowLockRace, class-level NOT_SUPPORTED) | **Written after the implementation, so not yet seen red.** Each has a queued hand mutant: C2 = markInherited-before-save, C4 = drop `@Transactional` / version predicate, C6 = drop `and bounds_inherited`, C10 = drop location predicate, C11 = drop the re-seed setters, C18 = drop `@Lock` | 10/10 |
| C20 | `TestDatabaseConfig.sbdev3128UnmappedColumns` | AC-20c red in the gate baseline | MobilePutaway 9/9 incl. AC-20c |

## DoD: fresh numbers

1. **Clean compile.** `mvn -o -q clean compile` passed at the stub stage. The later `mvn -o clean verify` (the killed run) did a clean compile and package of the final main code: the log reaches `repackage` and `javadoc` with no compilation error. Main code was not edited after that run started.
2. **Targeted unit classes: GREEN.** The run was `mvn -o test -Dtest='net/aim_ai/wms/unit/config/**,<5 gate classes>,FixLocationAssignmentServiceUnitTest,FixLocationAssignmentControllerUnitTest,LocationControllerUnitTest,LocationServiceUnitTest'` → **596 run, 0 F, 0 E, BUILD SUCCESS**. Per class:
   - RepoContract 12;
   - ServiceContract 2;
   - EndpointContract 3;
   - Sbdev3017 5;
   - ViewDto 110;
   - FLA service unit 70;
   - FLA controller 33;
   - LocationController 8;
   - LocationService 25;
   - 73 `unit/config` report files.

   The first run of this command had 2 arch-rail failures; Deviations 3 and 4 cover them.
3. **ITs: PARTIAL.**
   - **Run 1, green.** `-Dit.test='LocationDefaultBoundsMigrationIT,FixLocationAssignmentServiceIT,MobilePutawayServiceIntegrationTest'` → **31 run, 0 F, 0 E**: MigrationIT 12, MobilePutaway 9 incl. AC-20c, FLA IT 10. The FLA IT's outer tests report under `$CreateEditRace` (CLAUDE.md trap 3): 9 there + 1 in `$AdjustCommitted`.
   - **Run 2, killed for memory.** The broad run covered 63 classes: every `*IT`/`*IntegrationTest` grepping for `FixLocationAssignment|fix_location_assignment|LocationRepository|LocationService|LocationController`, plus `ReplenishmentMonitorViewSchemaIT`. The list is saved at `/private/tmp/claude-503/-Users-np1076-dev-spk-owl/4ddfcc59-1650-45c2-b27a-e5f4e6c95b90/scratchpad/it-list.txt`. **Before it was killed, 25 report lines (19 classes) finished with 0 F and 0 E.** That includes all three AC-15 reader nets, unedited:
     - `RefillFixedLocationPredicateIntegrationTest` 5;
     - `FlowbinMonitorViewPerFlowbinIT` 9;
     - `ReplenishmentMonitorViewSchemaIT` 4.

     The rest that finished:
     - `ReplenishOrderJobClaimIT` 7;
     - `ReplenishmentOrderSourceSyncIT` 10;
     - `EmptyStoragePalletCandidatesIT` 9;
     - `ClientRepositoryTransactionDetailIT` 2;
     - `ReplenishorderRepositoryIntegrationTest` 11;
     - `ManualCutCooldownPredicateIntegrationTest` 5;
     - `LocationRepositoryIntegrationTest` 17;
     - `UnitloadLocationNameIntegrationTest` 2;
     - `LockReadRailIT` 5;
     - `LocationDefaultBoundsMigrationIT` 12;
     - `SkuRestControllerAtomicityIntegrationTest` 3;
     - `ReplenishMaintenanceDeferralIT` 3;
     - `BillofladingServiceFinishTransferIT` 4.
   - **NOT run:**
     - the three other H2 tests (`MobilePicking`/`MobileReplenish`/`MobileTransferOrderServiceIntegrationTest`);
     - the remaining ~44 classes of the list;
     - the new `backfill_nonIntegerSysprop_fallsBack` (Deviations 6).
4. **Full `mvn -o test`: NOT RUN** (memory; see Verdict).
5. **Mutation checks: NOT RUN.** Everything is prepared:
   - `/private/tmp/claude-503/-Users-np1076-dev-spk-owl/4ddfcc59-1650-45c2-b27a-e5f4e6c95b90/scratchpad/mutate.py` is the driver. It requires a single anchor match, restores with a plain copy (fresh mtime, so the original recompiles), checks the restore with a byte compare, and stops on a restore mismatch.
   - `/private/tmp/claude-503/-Users-np1076-dev-spk-owl/4ddfcc59-1650-45c2-b27a-e5f4e6c95b90/scratchpad/mutants.json` holds the **41 mutants**. I checked that every anchor matches exactly once in the current files.
   - They cover every §7.3 row and every orchestrator item: the 7 migration backfill mutants (one per assertion, including ORDER BY, workstation, hardcode, syskey swap, DEFAULT true, fallback, regex guard), the 6 CHECK mutants (each `check_*` its own attributable red), the probe column (IT + unit), the reset / write-through / markOverridden predicates (IT + unit), `@Lock` (IT + unit), `flushAutomatically` (expect C2 **green**, the M-1 equivalent mutant), the adjust `@Transactional` (IT + unit), markInherited-before-save, the move re-seed, the clear guard, the probe hardcoded true (×3), the AC-18 restored read, the AC-19 catch removal, the AC-14b put, `compareTo`→`equals`, the source swap, both gates and the H2 bean.
   - Where a dropped predicate would leave a bound `@Param` unused, the mutant uses `:p = :p`, so the red is the predicate's and not a Spring Data bootstrap error.
   - Run it as `python3 mutate.py mutants.json mutation-table.md`.
   - **PIT** (`-DtargetClasses=net.aim_ai.wms.service.FixLocationAssignmentService -DtargetTests='net.aim_ai.wms.unit.service.FixLocationAssignmentServiceUnitTest'`, JDK 21 confirmed by `mvn -v`: 21.0.8) is also not run.
6. **`git status --short`:** 27 entries. All are intended (listed above); there is no archunit-store drift and no target or log files.

## Deviations from the plan

1. **D-1:** the read and the parameter are removed, not given a fallback (orchestrator decision). AC-18 adds never-read assertions.
2. **`LocationBoundDefaultsResult` lives in `net.aim_ai.wms.json`, not `dto/`.** No `dto` package exists in this repo; `json/` is where response records live (CLAUDE.md: "json/ # DTOs").
3. **`FunctionGuardArchTest.fixLocationAssignmentRepository_shouldStillExportItsSiblingSearches`** pinned FLA-repo `exported=false` to exactly `[findByAssignedlocationId]`. Plan L10 mandates `exported=false` on the 5 new methods, so the pin now lists those 5 by name (`containsExactlyInAnyOrder`), with a comment. The rail's intent, that the pre-existing siblings stay exported, is kept. The reviewer must agree that this is not a weakening.
4. **`TestClassTransactionManagerArchTest.EXEMPT_NON_TRANSACTIONAL`** gains two declared entries, each with its leak and purge rationale: `FixLocationAssignmentServiceIT$AdjustCommitted#adjust_flipsFlagOnRealPg` and `FixLocationAssignmentServiceIT$CreateEditRace`.
5. **Edit ordering:** the effective triple (`systemDefaultBounds()` on clear) is resolved **before** `updateDefaultBounds`, not after it. A garbage sysprop therefore fails before any write. The tx rolls back either way, and the test results are the same.
6. **Added test `LocationDefaultBoundsMigrationIT.backfill_nonIntegerSysprop_fallsBack`** (UPPER='abc', MIDDLE='60.5' → 36/60/84 inherited, migration succeeds). No gate test seeded a non-integer sysprop, so the orchestrator's "regex guard" mutant would have survived. This adds a test and touches no assertion. **It has not been run yet.**
7. AC-20c still reads the flag through the EntityManager native query, as the gate wrote it. The gate's optional switch to `findBoundsInheritedById` was not taken.
8. C11's unit tests are nested as `MoveSuccessfulOperations$Move` to reuse the whole-UL fixture. The move probe-false case lives there (`probeFalse_neverReadsFlag`), not in `$FeatureColumnsAbsent`.

## Landmines the plan did not predict

- **D-1 breaks 11 pre-existing `ViewDtoServiceUnitTest` tests**, through strict `getSysvalue(anyString())` stubs and one InOrder verify of the removed read (handled above). The plan's "fall back to 84" variant would not have caused this.
- **Two arch rails** (`FunctionGuardArchTest` exact un-export pin; `TestClassTransactionManagerArchTest` NOT_SUPPORTED declaration) must change with this feature (Deviations 3 and 4).
- **`createUnitload(any(), …)` with 5 args is overload-ambiguous** (`(String,Location,Long,Long,String)` vs `(Location,Long,Long,String,Long)`). The `never()` verify needs `(String) any()` casts.
- **BSD sed has no `\|` alternation.** It silently skipped my C14 red check (recorded, re-queued as a mutant).
- **Memory.** A 63-class failsafe run in one JVM on this Mac was killed by the harness for system memory. The remaining IT list should run in smaller batches.

## Still to do (in order) before review

1. Rerun DoD 3 in batches (≤15 classes each) from `it-list.txt`, including the 3 H2 tests and the new migration test.
2. Run `python3 mutate.py mutants.json …` (41 hand mutants), and PIT on `FixLocationAssignmentService`. Kill or justify any SURVIVED mutant on new lines.
3. Run the full `mvn -o test`, logged to `impl-3128-unit.log`; compare against the develop baseline.
4. Check whether `mvn test` touched the ArchUnit store; restore it via `git show HEAD:<path>` if so.

## Follow-up 2026-11-02 (after commit 31263d28)

Worktree HEAD `31263d28`, uncommitted. Toolchain: JDK 21.0.8 (`mvn -v`). Each Maven run was scoped and run one at a time.

### Files changed (uncommitted, `git diff --stat`)
```
 .../schema/LocationDefaultBoundsMigrationIT.java   | 23 +++   (main session's backfill_lowestClientIdWins_mirrored; not edited here)
 .../FixLocationAssignmentServiceUnitTest.java      | 31 +++   (this follow-up)
```

### 1. MIG-orderby: KILLED, by the mirrored test only
- `LocationDefaultBoundsMigrationIT` was first run whole: **14 run, 0 F, 0 E**. That is 12 gate tests + `backfill_nonIntegerSysprop_fallsBack` + `backfill_lowestClientIdWins_mirrored`.
- **Mutant:** I dropped `ORDER BY client_id` from **all three** CTE subqueries (anchor count asserted == 3; `grep -c 'ORDER BY'` afterwards = 0) and ran the whole class.
- **Result: 14 run, 1 failure**, `backfill_lowestClientIdWins_mirrored` → `AssertionFailedError: [client 1's 90 wins over client 5's 84]`. That message names the rule the mutant broke.
- `backfill_lowestClientIdWins` (the original) stayed green under the mutant, which agrees with the main session's measurement. With an unordered `LIMIT 1` the scan returns the inserted `-41` row, so exactly one of the pair can see the mutant. Exactly one went red, as the pair is designed.
- **Restore:** a plain `cp` from the saved copy. `cmp` reported byte-equal and `git diff --quiet` on the file was clean.

### 2. PIT survivors killed (`FixLocationAssignmentServiceUnitTest`, +31 lines, no assertion removed)
- **`validateDefaultBounds` ConditionalsBoundary (~439 ×3, ~442, ~445):**
  - New parameterized test `UpdateLocationBoundDefaults.accepts_boundaryTriple`. Each row sits exactly on one edge, and the test verifies `updateDefaultBounds` was called with the values:
    - `(0, 5, 10)`: Min = 0, the `signum() < 0` edge (~442);
    - `(5, 5, 10)`: Min = Hysteresis, the `compareTo > 0` edge (~445);
    - `(24.0001, 36.0001, 48.0001)`: scale 4 on all three, the `scale() > 4` edges (~439 ×3).
  - New row in `rejects_invalidTriple`: `(-0.0001, 0, 1)` → "Min must be zero or greater".
  - Already present: middle == upper `(36,60,60)` rejected, and scale 5 `24.00001` rejected.
- **Removed `requestForItem`.** Each verify was added to a test this ticket wrote; no pre-existing test was edited:
  - adjustLower / Middle / Upper (~214, ~234, ~254): `verify(replenishmentMaintenanceTrigger).requestForItem(1L)` in each `Adjust*.marksOverridden`;
  - create (~117): `requestForItem(testItemdata.getId())` in `Create.create_probeTrue_seedsLocationDefault_andMarksInherited`;
  - move (~195): `requestForItem(testAssignment.getItemdataId())` in `MoveSuccessfulOperations.Move.inheritedReseeds`.

### 3. PIT, scoped exactly as before
`-DtargetClasses=net.aim_ai.wms.service.FixLocationAssignmentService -DtargetTests='net.aim_ai.wms.unit.service.FixLocationAssignmentService*'`

| | Generated | KILLED | SURVIVED | NO_COVERAGE | Line coverage |
|---|---|---|---|---|---|
| before (main session's `mutations.xml`) | 140 | 111 | 16 | 13 | — |
| after | 140 | **121** | **6** | 13 | 219/220 (99%) |

**All 10 targeted mutants are now KILLED, and `mutations.xml` `killingTest` attributes each one:**
- the three `Adjust*.marksOverridden`;
- `Create.create_probeTrue_seedsLocationDefault_andMarksInherited`;
- `Move.inheritedReseeds`;
- `accepts_boundaryTriple` #1 / #2 / #3 for ~442 / ~445 / ~439.

One ~439 scale mutant is first killed by `rejects_invalidTriple` #4 (`-0.0001`, which has scale 4). Under `scale() >= 4` it gets the scale message instead of "Min must be zero or greater", so `hasMessageContaining` fails. That kill is still attributable.

**Remaining survivors, all pre-existing and untouched by this ticket, left alone as instructed:**

| Line | Method | Mutant | Reason left |
|---|---|---|---|
| 221 | adjustMiddleBound | ConditionalsBoundary (`lower > newAmount`) | pre-existing validation, unchanged since before SBDEV-3128 |
| 377 | changeActive | removed `requestForItem` | pre-existing; changeActive not touched (D-4 territory) |
| 366 | delete | removed `requestForItem` | pre-existing; delete not touched |
| 105 | createFixedLocationAssignment | removed `setActive` | pre-existing line; the existing tests never assert `active` on the new FLA |
| 109 | createFixedLocationAssignment | removed `setEntityLock` | pre-existing line |
| 173 | move | removed `Unitload.setLabelid` | pre-existing line |

The 13 NO_COVERAGE mutants are all `orElseThrow` lambdas returning null, i.e. "not found" paths; these were left alone as instructed.

### 4. Unit classes touched, re-run whole
`mvn -o test -Dtest='FixLocationAssignmentServiceUnitTest,FixLocationAssignmentServiceBoundsContractUnitTest'` → **76 run, 0 F, 0 E, BUILD SUCCESS**:
- `FixLocationAssignmentServiceUnitTest` **74**: 70 before + 3 boundary rows + 1 reject row (summed over its report XMLs);
- `FixLocationAssignmentServiceBoundsContractUnitTest` 2.

The migration IT was run separately (14/14 above).

## Review round 1 fixes (2026-11-02, on HEAD 7fb22890, uncommitted)

All three review lanes approved with 0 High and 0 Medium findings. Every Low is fixed in this pass. Constraints held: JDK 21, one scoped Maven process at a time, no stash, checkout, restore or commit.

### Finding → fix → proof

| Finding | Fix | Proof: red before the fix (attributable) → green |
|---|---|---|
| **SEC L1 + CR L-1**: no magnitude or length limit on the decimals | `LocationController.decimalOrNull(reqMap, field)`: accepts only a JSON `Number`; caps `toString()` at 32 characters; maps `NumberFormatException` (Double `Infinity`) to the `BusinessException` "`<field>` must be a finite number". `FixLocationAssignmentService.validateDefaultBounds` rejects `upper.abs() >= 1E+13` ("Max must be below 10,000,000,000,000"), placed after the ordering checks, where Max is provably the largest of the three, so bounding it bounds all three. I chose `abs()` over `precision() - scale()` because it also catches a negative-scale `1E+20` without a second rule. | `LocationControllerUnitTest$UpdateBoundDefaults`: `updateBoundDefaults_stringValue_rejected` (red: no `$.errors[0].field`), `_infinity_rejected` (red: wrong message; `catch (Exception)` had returned JVM text), `_overlongNumber_rejected` (red: no `{errors}`). `FixLocationAssignmentServiceUnitTest.rejects_invalidTriple` new rows `(1, 2, 10000000000000)` and `(1, 2, 1E+20)`, both red because no exception was thrown. New accept row `accepts_boundaryTriple (0, 1, 9999999999999.9999)`, the largest `numeric(17,4)`; it is green before and after, and it pins the edge. PIT kills every mutant on the new conditional. |
| **SEC L2**: `catch (Exception)` echoed SQL and JVM text | `updateBoundDefaults` now catches **only** `BusinessException`. A non-`Number` or missing `id` is caught by an `instanceof` check before the cast (equivalent to catching `ClassCastException \| NullPointerException`, without exception flow) and answers "id must be a number". Everything else propagates to the advice: `EntityNotFound` → 404, `DataAccessException` → 500 without its message. **The sibling handlers in `LocationController` (`create`, `update`, `createLocationType`, `updateLocationType`) still use `catch (Exception)`.** They predate this ticket and are left alone; the new handler follows this review, and its in-code comment says so. | `updateBoundDefaults_dataAccessException_propagates`: a `DataIntegrityViolationException` from the service now reaches MockMvc as the root cause instead of a 200 `{errors}` (red before: 200 with the SQL text, so nothing was thrown). `updateBoundDefaults_nonNumericId_rejected` (red: message was JVM `ClassCastException` text). |
| **SEC L3**: reset cast `id` outside the try | `resetBoundsToDefault` checks `instanceof Number` before the cast and returns `{errors}` "id must be a number" | `FixLocationAssignmentControllerUnitTest$ResetBoundsToDefault.resetBoundsToDefault_nonNumericId_rejected`: red `ServletException: ClassCastException`, now green |
| **SEC L4**: raw `id` logged before its type check | `LOG.debug("updateBoundDefaults id={}", id)` now runs after the `instanceof`, on the `Long` | Review only; a log line has no assertion |
| **CR L-2 + VER L1**: stale AC-18 names | `replenishOrderViewByKeyword_absentUpperSysprop_fallsBackTo84` + `_paddedAndDecimal_parse` are **merged** into `replenishOrderViewByKeyword_neverReadsUpperSysprop`. It keeps every distinct assertion: no exception with the sysprop absent, no exception with `" 84 "` and with `"84.5"` stubbed, and `never().getSysvalue(UP)`. The SBDEV-3668 `@DisplayName` now reads "…before the order query (and reads no sysprop, SBDEV-3128 D-1)". The nested-class javadoc is rewritten. | Rename only; `ViewDtoServiceUnitTest` 109 green (110 − 1 merged) |
| **CR L-3 + CR L-4**: V2.2.45 header wording | ALTER paragraph: "The three ALTERs (two on location, one on fix_location_assignment) take ACCESS EXCLUSIVE, held until commit, and adding the CHECK also scans location". BACKFILL paragraph: "follows" instead of "mirrors", plus "narrower than Long.parseLong, which also accepts 19-digit and non-ASCII digit values; FLAs seeded from such a value then classify OVERRIDDEN, the safe direction". **The identical text is applied to plan §3.1.** A script compared the plan's fenced sql block with the migration file: **IDENTICAL** (5,109 bytes). | `LocationDefaultBoundsMigrationIT` 14/14 (fresh DBs). See Landmine 1 for the reused container. |
| **CR L-5**: duplicated sysprop-triple parse | One helper, `public static long SyspropService.parseLongOrDefault(String value, String defaultValue)`: null → the default, otherwise `Long.parseLong` with no trim, and `NumberFormatException` propagates. `FixLocationAssignmentService.parseSyspropLong` (which keeps its absent WARN) and `ViewDtoService.syspropLongAsDecimal` (which keeps its `SYSTEM_INVALID` catch) both delegate to it. It is static so that each caller still reads through its own proxied, `@Cacheable` `getSysvalue`. A self-invoked instance method would have bypassed the cache and forced re-stubbing of every `getSysvalue` mock. Behaviour is identical. | New `SyspropServiceUnitTest$ParseLongOrDefault.parseLongOrDefault_matchesParseSyspropLongContract`. Hand mutant: adding `.trim()` to the helper → red `[' 84 ' must be rejected, exactly as create's Long.parseLong rejects it]`, restored byte-equal. |
| **VER L5**: AC-14 old keys asserted by presence only | `fixedAssignmentView_shouldCarryInheritanceAndDefaultKeys_whenRowRendered` stubs and asserts the **values** of all 9 pre-existing keys | Hand mutant: `dto.put("clientName", result.getLocation())` → red `expected: "WineCo" but was: "53-B06"`, restored byte-equal |
| **CR L-6**: reset's 409/404 are `ProblemDetail`s | No code change. Plan §3.4 gains a bullet: only `BusinessException` or a non-numeric `id` answer as `{errors}`; OOLFE → 409 and EntityNotFound → 404 `ProblemDetail`, anything else → 500, consistent with sibling `/move`; the P2 UI treats non-2xx as `false`. | Doc only |
| **CR OQ-1**: committed-fixture cleanup vs post-commit maintenance | `deleteCommitted` now first deletes `replenishorder` rows where `requestedlocation_id` or `destination_id` is the fixture location, or `itemdata_id` is a fixture item. That covers all three FKs into the fixture rows; nothing references `replenishorder`. Before this, the cleanup did **not** handle it. | `FixLocationAssignmentServiceIT` 10/10. Probe after the run: `select count(*) from location where name like 'S3128-%'` = 0, and the same on `itemdata` = 0, so no residue. No red is possible today: maintenance writes no order for a stockless item. |

### PIT after the fixes (scoped as before)
**141 generated, 121 KILLED, 7 SURVIVED, 13 NO_COVERAGE.** The +1 generated is the new magnitude conditional, which is killed.

Six survivors are the pre-existing ones already justified in the follow-up section (lines 221, 377, 105, 109, 366, 173). **One is new: 463, `parseSyspropLong` negated `if (value == null)`.** Since CR L-5 that branch only emits the "absent" WARN, and both paths return `SyspropService.parseLongOrDefault(value, default)`. Negating it changes nothing but the log line, so it is an **equivalent mutant**. The old shape had its own `return` inside the branch; it became equivalent only because the parse is now shared.

### Verification (fresh, whole classes, report files present)
- `mvn -o -q clean compile` → exit 0.
- **Unit:** 255 run, 0 failures, 0 errors:

  | Class | Tests |
  |---|---|
  | `LocationControllerUnitTest` | 13 |
  | `FixLocationAssignmentControllerUnitTest` | 34 |
  | `FixLocationAssignmentServiceUnitTest` | 77 |
  | `FixLocationAssignmentServiceBoundsContractUnitTest` | 2 |
  | `LocationDefaultBoundsEndpointContractUnitTest` | 3 |
  | `ViewDtoServiceUnitTest` | 109 |
  | `SyspropServiceUnitTest` | 17 |

  Before the fixes, the same command over the first three classes ran 124 tests with 7 failures and 1 error. Those 8 reds were exactly the new SEC/CR tests.
- **IT:**
  - `LocationDefaultBoundsMigrationIT`: 14/14.
  - `FixLocationAssignmentServiceIT`: 10/10. The 9 outer-class tests report under `$CreateEditRace` (trap 3), and 1 under `$AdjustCommitted`.

### Landmine (new)
1. **The header edit changes V2.2.45's checksum, and any already-migrated *reused* Testcontainers DB rejects it.**
   - The first `FixLocationAssignmentServiceIT` run errored in `AppPostgresDBSetupExtension.beforeAll` with `FlywayValidateException: Migration checksum mismatch for migration version 2.2.45 (applied -1473221570, resolved 919222879)`.
   - Only comments changed, so the schema is identical. I did the equivalent of `flyway repair` for that single row in the local reused container (`wms_test`): `update flyway_schema_history set checksum = 919222879 where version = '2.2.45' and checksum = -1473221570` (UPDATE 1). The IT was then green.
   - `LocationDefaultBoundsMigrationIT` was unaffected because it creates fresh DBs.
   - **Anyone with a reused container that already ran this branch will hit the same error.** The fix is the same one-row repair, or `docker rm -f` of the reused container.
   - CI is unaffected (fresh container). No real environment has applied V2.2.45.
   - From here on, the header must not change again.

### Files changed in this pass (`git diff HEAD --stat`)
```
 controller/FixLocationAssignmentController.java     |  9 ++-
 controller/LocationController.java                  | 47 +++++---
 service/FixLocationAssignmentService.java           | 13 ++-
 service/SyspropService.java                         | 12 ++
 service/ViewDtoService.java                         |  7 +-
 db/migration/V2.2.45__location_default_fla_bounds.sql | 17 +++---  (header comments only)
 test service/FixLocationAssignmentServiceIT.java    | 10 ++-
 test FixLocationAssignmentControllerUnitTest.java   | 11 ++
 test LocationControllerUnitTest.java                | 65 ++++++
 test FixLocationAssignmentServiceUnitTest.java      |  9 ++-
 test SyspropServiceUnitTest.java                    | 20+ ++
 test ViewDtoServiceUnitTest.java                    | 67 ++++----
 + sbdocs plan SBDEV-3128-location-default-fla-bounds.md (§3.1 header identical to the SQL; §3.4 failure-shape bullet)
```
