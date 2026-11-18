---
ticket: SBDEV-3128
phase: P1 (wms2-api)
artifact: tdd-gate-baseline
date: 2026-11-01
plan: ../SBDEV-3128-location-default-fla-bounds.md (r4)
---

## TDD Gate Baseline — SBDEV-3128 (P1, wms2-api)

Branch:   wms2-api@feature/SBDEV-3128-location-default-fla-bounds (off origin/develop 8171c80a; plan cites 1b421d08, delta checked by the main session and found irrelevant)
Worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3128. The executor must implement in this same tree.
Toolchain: JDK 21.0.8 (Microsoft), Maven 3.9.11, Docker 28.4.0 (Testcontainers ran), H2 2.3.232 (confirmed from the H2 error code `[42122-232]`)
No production file changed: `git diff --name-only | grep -c src/main` → 0. Nothing is committed and nothing is stashed.

### Files created / modified (`git status --short`)
```
 M src/test/java/net/aim_ai/wms/integration/service/mobile/MobilePutawayServiceIntegrationTest.java
 M src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java
 M src/test/java/net/aim_ai/wms/unit/service/ViewDtoServiceUnitTest.java
?? src/test/java/net/aim_ai/wms/integration/schema/LocationDefaultBoundsMigrationIT.java
?? src/test/java/net/aim_ai/wms/unit/controller/LocationDefaultBoundsEndpointContractUnitTest.java
?? src/test/java/net/aim_ai/wms/unit/repo/LocationDefaultBoundsRepositoryContractUnitTest.java
?? src/test/java/net/aim_ai/wms/unit/service/FixLocationAssignmentServiceBoundsContractUnitTest.java
```

### Runs (fresh, counts confirmed)
| Lane | Command | Result |
|---|---|---|
| compile | `mvn -o -q test-compile` | OK. All new `.class` files written at 23:05–23:06 |
| surefire | `mvn -o test -Dtest='LocationDefaultBoundsRepositoryContractUnitTest,FixLocationAssignmentServiceBoundsContractUnitTest,LocationDefaultBoundsEndpointContractUnitTest,ViewDtoServiceUnitTest,Sbdev3017TrancheGateContextTest'` | **128 run, 24 failures, 0 errors.** The 24 failures are exactly the new tests. Every pre-existing test in these classes passed, including Sbdev3017's other 4 tests (row-count pin now 234) |
| surefire, arch rails over the new test code | `mvn -o test -Dtest='net/aim_ai/wms/unit/config/**,<the 3 contract classes>,ViewDtoServiceUnitTest'` | **451 run, 23 failures (all new tests), 0 errors.** Every `unit/config` arch test is green. The first run caught `TestIdentifierCountArchTest` objecting to a count in a `@DisplayName` ("the 3 default columns"); the display names were reworded and the test is now green |
| failsafe | `mvn -o verify -Dit.test='LocationDefaultBoundsMigrationIT,MobilePutawayServiceIntegrationTest' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | **21 run, 13 failures, 0 errors.** `failsafe-summary.xml` shows completed=21. The other 8 MobilePutaway tests passed |
| H2 positive control (reverted) | AC-20c's existence query temporarily pointed at `upperbound` | The existence assertion passed and the value read then raised H2 `Column "bounds_inherited" not found [42122-232]`. So the information_schema query does find a column that exists on H2 (lower-case names), and an assertion red cannot come from a broken query. The file was restored, verified by grep |

### Tests written
| Test class | Method | Criterion | Kind |
|---|---|---|---|
| LocationDefaultBoundsMigrationIT | backfill_marksOnlyTenantDefaultTripleInherited | AC-1: 36/60/84 → inherited; 12/24/36 and 36/60/90 → overridden | A |
| 〃 | backfill_readsTenantSyspropNotHardcoded | AC-1: sysprop UPPER=90 → 36/60/90 inherited, 36/60/84 not | A |
| 〃 | backfill_rowAbsent_fallsBack | AC-2: absent UPPER row → 84 | A |
| 〃 | backfill_nonDefaultWorkstationIgnored | AC-2: a WS-OTHER row at client −1 (sorts first) is ignored | A |
| 〃 | backfill_lowestClientIdWins | AC-2: client 1 (=90, inserted later) beats client 5 (=84) | A |
| 〃 | check_rejects_middleBelowLower / _partialNull / _negativeLower / _middleEqualsUpper | AC-3: (10,5,20), (10,NULL,20), (−1,0,1), (10,20,20) → 23514 | A |
| 〃 | check_accepts_allNull / _zeroZeroOne | AC-3: all-NULL and (0,0,1) accepted | A |
| 〃 | featureColumnsPresent_falseAt2244_trueAfter | AC-20b: **executes the `@Query` text of `LocationRepository.featureColumnsPresent`** at 2.2.44 (false) and after HEAD (true) | A+B |
| MobilePutawayServiceIntegrationTest (+1 block in storeBoxOnLocation_putsWholePalletAway) | storeBoxOnLocation_putsWholePalletAway | AC-20c: the FLA created by putaway has `bounds_inherited = true` on H2 | A |
| Sbdev3017TrancheGateContextTest (+2 rows, size pin 232→234) | everyTrancheRouteCarriesItsIntendedFunctions | AC-11: `/v3/location/updateBoundDefaults` → WEB_UI_VIEW_STORAGE_LOCATION; `/v3/fixedAssignment/resetBoundsToDefault` → WEB_UI_VIEW_FIXED_ASSIGNMENT (in the C1–C7 loop array) | A |
| LocationDefaultBoundsEndpointContractUnitTest | updateBoundDefaults_shouldBeGatedAtMethodLevel_onStorageLocationFunction | AC-11 / §3.4: exactly one `@PostMapping("/updateBoundDefaults")`, with a **method-level** `@RequiresFunction(WEB_UI_VIEW_STORAGE_LOCATION)` | B |
| 〃 | resetBoundsToDefault_shouldExist_underClassLevelFixedAssignmentGate | AC-11 / §3.4: exactly one `@PostMapping("/resetBoundsToDefault")`, plus the class gate | B |
| 〃 | locationController_shouldInjectFixLocationAssignmentService | §3.4: the ctor gains FixLocationAssignmentService | B |
| FixLocationAssignmentServiceBoundsContractUnitTest | service_shouldDeclareNewBoundsMethods_whenSbdev3128Lands | W9: resetBoundsToLocationDefault/1 and updateLocationBoundDefaults/4 | B |
| 〃 | boundsWriters_shouldBeTenantTransactional | §3.3: adjust{Lower,Middle,Upper}Bound/2, reset/1 and edit/4 carry `@Transactional("tenantTransactionManager", rollbackFor ⊇ {Business,Facade})` | B |
| LocationDefaultBoundsRepositoryContractUnitTest | locationRepository_shouldDeclareNewNativeMethods_whenSbdev3128Lands | §3.2: lockById/1, featureColumnsPresent/0, findDefaultBoundsById/1, updateDefaultBounds/4 | B |
| 〃 | flaRepository_shouldDeclareNewNativeMethods_whenSbdev3128Lands | §3.2: findBoundsInheritedById/1, markInherited/1, markOverridden/2, resetBounds/6, writeThroughInherited/5 | B |
| 〃 | newRepositoryMethods_shouldBeUnexportedAndNotTransactional | L10 / L-3: `@RestResource(exported=false)` on every new method; no Spring or jakarta `@Transactional`; nativeQuery (lockById = JPQL); `@Modifying` iff a write; writes return int | B |
| 〃 | lockById_shouldBePessimisticWrite_whenDeclared | §3.2: `@Lock(PESSIMISTIC_WRITE)`, returns Optional | B |
| 〃 | flagWrites_shouldFlushAutomatically_whenDeclared | §3.2: markInherited/markOverridden are `@Modifying(flushAutomatically = true)` and return int | B |
| 〃 | featureColumnsPresent_shouldProbeInformationSchemaForBoundsInherited | D9: the probe text names information_schema.columns, 'fix_location_assignment' and 'bounds_inherited' | B |
| 〃 | writeThroughInherited_shouldBePredicatedOnBoundsInherited | §3.2: `and bounds_inherited` predicate + `version = version + 1` | B (text) |
| 〃 | markOverridden_shouldBeVersionPredicated | §3.2: `and version = :version` | B (text) |
| 〃 | resetBounds_shouldBePredicatedOnAssignedLocation | L-1: `and assignedlocation_id = :locationId` + re-marks inherited + version bump | B (text) |
| 〃 | locationGetDetailView_shouldSelectDefaultColumns | L5: 3 aliased default columns | B (text) |
| 〃 | flaGetDetailView_shouldSelectInheritanceColumns | R2: boundsInherited + locationDefault* aliases | B (text) |
| 〃 | projections_shouldDeclareNewGetters | §3.2: LocationDetailView +3, FixLocationAssignmentDetailView +4, `repo.projection.LocationDefaultBoundsView` with 3 getters | B |
| ViewDtoServiceUnitTest$Sbdev3128DefaultBoundsViews | fixedAssignmentView_shouldCarryInheritanceAndDefaultKeys_whenRowRendered | AC-14: the 9 existing keys kept, the new keys present | A |
| 〃 | fixedAssignmentView_shouldReportSystemSource_whenLocationHasNoDefault | AC-14: no location default → `defaultSource=SYSTEM`, effective = sysprop 30/50/70 (compareTo) | A |
| 〃 | fixedAssignmentView_invalidSysprop_rendersSystemInvalid | AC-19: 'abc' → renders, SYSTEM_INVALID, null effective triple | A |
| 〃 | locationView_includesDefaults | AC-14b: getLocationView carries defaultMinAmount/Hysteresis/MaxAmount keys | A |
| 〃 | replenishOrderViewByKeyword_absentUpperSysprop_fallsBackTo84 | AC-18: null UPPER → no NPE | A |
| 〃 | replenishOrderViewByKeyword_paddedAndDecimal_parse | AC-18 / L-5: " 84 " parses (red today), and "84.5" still parses (in the same test, so the test is not green today) | A |

**Totals: 37 red test methods.** Surefire 24: RepoContract 12 + ServiceContract 2 + EndpointContract 3 + ViewDto 6 + the extended Sbdev3017 drift test 1. Failsafe 13: MigrationIT 12 + the extended MobilePutaway test 1. All 37 were observed as assertion failures. The Sbdev3017 size-pin test was edited and **passes by design**. It is row-count housekeeping, not an AC test.

### Failure output (excerpt)
```
LocationDefaultBoundsMigrationIT (11 of 12):  [V2.2.45 must add location.default_lowerbound] Expecting value to be true but was false
LocationDefaultBoundsMigrationIT.featureColumnsPresent_falseAt2244_trueAfter:
   [plan §3.2 / D9: LocationRepository must declare featureColumnsPresent() — ...] Expected size: 1 but was: 0
MobilePutawayServiceIntegrationTest.storeBoxOnLocation_putsWholePalletAway (line 370, after every pre-existing assertion passed):
   [fix_location_assignment.bounds_inherited must exist on H2 — D8 leaves it unmapped, so only the §3.8 TestDatabaseConfig bean can create it] expected: 1 but was: 0
Sbdev3017TrancheGateContextTest.everyTrancheRouteCarriesItsIntendedFunctions: gate drift — 2 of 234 routes wrong.
   FixLocationAssignmentController /v3/fixedAssignment/resetBoundsToDefault=ROUTE NOT DEPLOYED (renamed or deleted?) — expected WEB_UI_VIEW_FIXED_ASSIGNMENT
   LocationController /v3/location/updateBoundDefaults=ROUTE NOT DEPLOYED (renamed or deleted?) — expected WEB_UI_VIEW_STORAGE_LOCATION
LocationDefaultBoundsEndpointContractUnitTest: [LocationController must declare exactly one @PostMapping("/updateBoundDefaults") handler (plan §3.4)] Expected size: 1 but was: 0
FixLocationAssignmentServiceBoundsContractUnitTest: [declared set first — the loop below must not iterate over missing methods] Expecting TreeSet ... to contain ... resetBoundsToLocationDefault/1
LocationDefaultBoundsRepositoryContractUnitTest: [LocationRepository must declare exactly one lockById/1 (plan §3.2)] Expected size: 1 but was: 0   (and analogous lines for every new method)
ViewDtoServiceUnitTest AC-18: [ViewDtoService:708 new BigDecimal(null) NPEs the whole replenish-order screen; plan §3.4 falls back to 84]
   Expecting code not to raise a throwable but caught "java.lang.NullPointerException: Cannot invoke "String.toCharArray()" because "val" is null"
ViewDtoServiceUnitTest AC-18 padded: caught "java.lang.NumberFormatException: Character   is neither a decimal digit number, decimal point, nor "e" notation"
ViewDtoServiceUnitTest AC-19: Expecting actual {active=false, ..., minAmount=36.0000, ...} to contain keys [defaultSource, defaultMinAmount, ...]
ViewDtoServiceUnitTest AC-14 SYSTEM: expected: "SYSTEM" but was: null
```

### Verify-script baseline
None. Plan §"Verify script" ships no script: T3, opt-in, and not opted in. Skipped.

### Verdict
✓ 37 tests fail for the right reason (assertion failures, 0 errors in either lane)
⚠ 1 setup adjustment: display names reworded for `TestIdentifierCountArchTest` (no counts in names); the assertions are unchanged
✗ 0 unexpected passes. (The Sbdev3017 size pin passes by design, see Totals. The "84.5" sub-case was put inside the red padded test on purpose, so that nothing written here is green today.)

**Auto-proceed: NO.** There are more than 2 ACs, and the plan touches `@Transactional`, `@Lock`/pessimistic locks, `@Version` races and function gates. **PAUSE: reply "go" to start implementation, or describe adjustments.**

### What these tests encode
- **Migration IT (11 of them):** V2.2.45 does not exist, so the four columns are absent and the first assertion every test makes (`assertFeatureColumnsExist`) is red.
  - ⚠ **These eleven all fail on the same assertion today.** The backfill and CHECK assertions behind it are unreached until the migration lands, so they have **not yet been seen red for their own reason**. They must be mutation-checked after implementation (table below).
  - **Flyway missing target:** never exercised. The harness migrates to HEAD (`target = null`), not to `2.2.45`, so no "target not found" harness exception can mask the behaviour. `flywayApplied("2.2.45")` is the positive control once the script exists.
- **AC-20b:** the D9 probe method does not exist. The test executes the probe's own `@Query` text on PG, so a probe that names the wrong column is caught by running it, not by matching its text.
- **AC-20c:** H2 has no `bounds_inherited` column. Without the §3.8 bean, create cannot mark the FLA inherited.
- **AC-11, both lanes:** neither route is mapped, and `/updateBoundDefaults` has no method-level gate.
- **Service contract:** `adjust*` is not `@Transactional` today, so a `@Modifying` `markOverridden` would have no transaction. Reset and edit do not exist.
- **Repository contract:** none of the nine native/lock methods exist. Neither the projection getters nor `LocationDefaultBoundsView` exist, and neither getDetailView selects the new columns.
- **AC-14 / 14b / 19:** the FLA and location views emit none of the new keys, and the FLA view never reads the sysprop.
- **AC-18:** `ViewDtoService:708` NPEs on a null sysprop and NFEs on a padded one.

---

## AC → handling map (every P1 AC; UI-* rows are P2 and out of scope)

| AC | Handling | Where |
|---|---|---|
| AC-1 | **A** | MigrationIT `backfill_marksOnlyTenantDefaultTripleInherited`, `backfill_readsTenantSyspropNotHardcoded` |
| AC-2 | **A** | MigrationIT `backfill_rowAbsent_fallsBack`, `_nonDefaultWorkstationIgnored`, `_lowestClientIdWins` |
| AC-3 | **A** | MigrationIT `check_rejects_*` ×4, `check_accepts_*` ×2 |
| AC-4 | **B** now (lockById `@Lock`, markInherited `flushAutomatically`, int return) + **C** | C1 |
| AC-4b | **C** | C2 |
| AC-5 | **B** now (`@Transactional` on adjust*, markOverridden shape and version predicate) + **C** | C3 |
| AC-5b | **B** text pin (`and version = :version`) + **C** | C4 |
| AC-6 | **C** (B: writeThroughInherited declared, `@Modifying`, predicate pinned) | C5 |
| AC-6b | **B** text pin (`and bounds_inherited`) + **C** | C6 |
| AC-7 | **C** | C7 |
| AC-8 | **C** | C8 |
| AC-9 | **B** (reset declared + transactional) + **C** | C9 |
| AC-9b | **B** text pin (`and assignedlocation_id = :locationId`) + **C** | C10 |
| AC-10 | **C** | C11 |
| AC-11 | **A** (Sbdev3017 rows) + **B** (endpoint contract) + **C** (controller unit behaviour) | C12 |
| AC-14 | **A** (key set; SYSTEM source + effective triple) + **C** (LOCATION source, boundsOutOfDate) | C13 |
| AC-14b | **A** (keys present) + **C** (values copied) | C14 |
| AC-14c | **C** | C15 |
| AC-15 | **Existing regression net, not run by this gate** (gate rule 4: run only new tests). Executor runs `RefillFixedLocationPredicateIntegrationTest`, `FlowbinMonitorViewPerFlowbinIT`, `ReplenishmentMonitorViewSchemaIT`, `MobilePickingServiceIntegrationTest`, `MobileReplenishServiceIntegrationTest`, `MobileTransferOrderServiceIntegrationTest`, `MobilePutawayServiceIntegrationTest` **unedited** after implementation. (MobilePutaway's other 8 tests passed in this gate run.) | — |
| AC-16a | **C** | C16 |
| AC-16b | **C** | C17 |
| AC-17 | **B** (lockById `@Lock` pinned) + **C** | C18 |
| AC-18 | **A** | ViewDtoServiceUnitTest `replenishOrderViewByKeyword_absentUpperSysprop_fallsBackTo84`, `…_paddedAndDecimal_parse` |
| AC-19 | **A** | ViewDtoServiceUnitTest `fixedAssignmentView_invalidSysprop_rendersSystemInvalid` |
| AC-20 | **B** (probe declared, text pinned) + **C** | C19 |
| AC-20b | **A+B** | MigrationIT `featureColumnsPresent_falseAt2244_trueAfter` |
| AC-20c | **A** | MobilePutawayServiceIntegrationTest `storeBoxOnLocation_putsWholePalletAway` (+1 block) |

### AC-20c decision (asked for explicitly)
I rejected a raw native `select bounds_inherited …` as the only check. On H2 today it raises `SQLGrammarException: Column "bounds_inherited" not found [42122-232]`, an **error** and not an assertion, which gate Step 4 classifies as broken scaffolding. The test now makes two reads, both inside the test's own transaction, through `@PersistenceContext(unitName = "tenant")` after `em.flush()`:
1. an `information_schema.columns` count, asserted `== 1`. This red names the missing column and pins the §3.8 bean;
2. `select bounds_inherited … where id = :id`, asserted `TRUE`. This pins the H2 probe and `markInherited`.

The positive control above shows that step 1 does detect an existing column on H2. The block sits **after** every pre-existing assertion, so the original test still runs in full; it went red at line 370, after those assertions passed. The landlord `JdbcTemplate` is not used. Once the executor's `findBoundsInheritedById` exists, step 2 may be switched to it.

---

## (C) Deferred to the executor's first commit (behaviour needs the new signatures)
Write each one as soon as the signatures compile, and see it red against a stubbed or unfinished body before making it green.

| # | Class · method(s) | AC |
|---|---|---|
| C1 | `unit/service/FixLocationAssignmentServiceUnitTest` `@Nested Create`: `create_probeTrue_seedsLocationDefault_andMarksInherited`, `create_probeTrue_nullLocationDefault_seedsSysprop`, `create_probeTrue_markInheritedZero_throwsIllegalState`, `create_probeTrue_locksBeforeCreateUnitload` (InOrder) | AC-4 |
| C2 | `service/FixLocationAssignmentServiceIT` (new, `BasePostgresIntegrationTest`) · `create_marksInheritedOnRealPg` | AC-4b |
| C3 | existing `@Nested Adjust{Lower,Middle,Upper}Bound` (:118, :165, :210) · `+ marksOverridden`, `+ staleVersion_rejected` (×3) | AC-5 |
| C4 | ServiceIT `@Nested AdjustCommitted.adjust_flipsFlagOnRealPg` (method-level `@Transactional(propagation = NOT_SUPPORTED)`, committed fixture, explicit `@AfterEach` cleanup); outer `markOverridden_staleVersion_noRow` | AC-5b |
| C5 | ServiceUnitTest `@Nested UpdateLocationBoundDefaults` · `writesThrough`, `noInheritedFla_noTrigger` | AC-6 |
| C6 | ServiceIT · `edit_writesThroughInheritedOnly` | AC-6b |
| C7 | ServiceUnitTest · `clear_revertsInheritedToSysprop` | AC-7 |
| C8 | ServiceUnitTest · `rejects_*` (parameterized: (36,60,60), (61,60,84), (−1,0,1), partial-null, `24.00001`; `never()` on lockById/updateDefaultBounds/writeThroughInherited, full varargs) | AC-8 |
| C9 | ServiceUnitTest `@Nested Reset` (location triple / sysprop when null, trigger once, FLA entity never saved, `resetBounds`=0 → OOLFE) | AC-9 |
| C10 | ServiceIT · `resetBounds_afterMove_noRow` | AC-9b |
| C11 | ServiceUnitTest `@Nested Move` · `inheritedReseeds`, `overriddenKeeps`; ServiceIT · `move_inheritedTakesDestinationDefault` | AC-10 |
| C12 | `LocationControllerUnitTest` · `updateBoundDefaults_*` (also update its `:38` ctor call); `FixLocationAssignmentControllerUnitTest` · `resetBoundsToDefault_*` | AC-11 |
| C13 | ViewDtoServiceUnitTest · `fixedAssignmentView_locationDefault_reportsLocationSource`, `fixedAssignmentView_boundsOutOfDate_trueWhenInheritedAndSyspropDiffers`, `…_falseWhenEqual` (`24.0000` vs `24` via compareTo) | AC-14 |
| C14 | ViewDtoServiceUnitTest · extend `locationView_includesDefaults` to stub the 3 new getters and assert the values | AC-14b |
| C15 | `LocationServiceUnitTest` · `locationDetails_includesDefaults` | AC-14c |
| C16 | ServiceUnitTest · `rejectsSetOnNonFlowbin` | AC-16a |
| C17 | ServiceUnitTest · `allowsClearOnNonFlowbin` | AC-16b |
| C18 | ServiceIT · `createThenEdit_flaHasEditedDefault`, `editThenCreate_flaHasEditedDefault` (harness after `BusinessServiceLockRefreshStaleVersionIT`) | AC-17 |
| C19 | ServiceUnitTest `@Nested FeatureColumnsAbsent` (create/adjust/move/edit/clear/reset with probe false); `LocationServiceUnitTest` · `locationDetails_columnsAbsent_omitsKeys` | AC-20 |
| C20 | **Test-side infra, not a test:** the §3.8 `sbdev3128UnmappedColumns` bean in `common/config/TestDatabaseConfig.java`. AC-20c stays red until it exists | AC-20c |

L-2 precondition (plan §7.2): before editing, confirm the five existing create/adjust unit tests (`FixLocationAssignmentServiceUnitTest:405, :963, :129, :176, :221`) are green. This gate did not touch that class.

---

## Mutation plan (recorded now; run after implementation, since unbuilt code cannot be mutated)
| Test | §7.3 mutant it must go red on |
|---|---|
| MigrationIT `backfill_lowestClientIdWins` | drop `ORDER BY client_id`. ⚠ This relies on heap order (the updated client-5 row is scanned before the later client-1 insert). **Confirm it really goes red**; if the FSM places the insert earlier, reorder the seed |
| MigrationIT `backfill_nonDefaultWorkstationIgnored` | drop `AND workstation = 'DEFAULT'` |
| MigrationIT `backfill_readsTenantSyspropNotHardcoded` / `_marksOnly…` | hardcode 36/60/84; swap the MIDDLE↔UPPER syskey; `DEFAULT false` → `DEFAULT true` (the overridden-row asserts) |
| MigrationIT `check_rejects_middleEqualsUpper` / `_negativeLower` | CHECK `<` → `<=`; drop `>= 0` |
| MigrationIT `featureColumnsPresent_falseAt2244_trueAfter` + RepoContract `featureColumnsPresent_…` | probe names the wrong column |
| RepoContract `lockById_…` (+ C18) | remove `@Lock` from lockById |
| RepoContract `writeThroughInherited_…` (+ C6) | drop `and bounds_inherited` |
| RepoContract `markOverridden_…` (+ C4) | drop `and version = :version` |
| RepoContract `resetBounds_…` (+ C10) | drop `and assignedlocation_id = :locationId` |
| RepoContract `flagWrites_…` | drop `flushAutomatically` → red here (annotation pin). Separately, record C2 **green** under that mutant (M-1 equivalent mutant) |
| RepoContract `newRepositoryMethods_…` | add `@Transactional` to a repo method; flip `exported` to true; drop `@Modifying` |
| ServiceContract `boundsWriters_…` (+ C4) | drop `@Transactional` on adjustUpperBound; bare `@Transactional` (landlord TM) |
| EndpointContract `updateBoundDefaults_…` + Sbdev3017 row | delete the method-level `@RequiresFunction` |
| Sbdev3017 resetBoundsToDefault row | drop the class-level annotation (scratch copy); the row is attributable by name |
| ViewDto `replenishOrderViewByKeyword_*` | restore raw `new BigDecimal(getSysvalue(…))` at :708 |
| ViewDto `fixedAssignmentView_invalidSysprop_…` | remove the try/catch on the view's sysprop read |
| MobilePutaway AC-20c block | delete the H2 bean (the other 3 H2 tests stay green via D9) |
| ViewDto AC-14 / 14b key tests | drop one `dto.put` |

---

## Findings for the main session (sub-T3, belong on this ticket)
1. **AC-18's "upper 84" cannot be observed.** `ViewDtoService:708`'s `upperBound` is passed to `getStockPerLocation(page, upperBound)` (:722, :773), and that method never reads it. It uses `fla.getUpperbound()` only (:801-811). So AC-18 can assert only "no throw", which is what these tests do. Options: drop the dead parameter (and the sysprop read with it, which removes the D-1 NPE at its root), or accept the parse-only fix. This is a design call for the executor and reviewer, not something the gate settles.
2. **The AC-14 and AC-19 stubs assume the view reads the triple through `SyspropService.getSysvalue(key)`**, the same API `parseSyspropLong` uses. If the executor reads it through another `SyspropService` method, re-point the stubs. That is a fixture change, not a weakening.
3. **The three SQL-text pins (B, text) constrain predicates, not formatting.** The regexes tolerate aliases and whitespace. If equivalent SQL trips one, fix the regex, never the predicate. The PG ITs C4/C6/C10 remain the authority.
4. **Row-count pin:** Sbdev3017 `thePinHasNotBeenQuietlyShrunk` went from 232 to 234, with a comment. Any concurrent ticket that adds rows will conflict on this line at merge.

## Full-suite baseline (2026-11-02)
origin/develop 8171c80a, clean detached worktree, JDK 21, `mvn -o test`: **Tests run: 9424, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS. Log: scratchpad baseline-3128-unit.log.
