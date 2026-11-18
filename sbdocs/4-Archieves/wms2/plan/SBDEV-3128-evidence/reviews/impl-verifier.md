---
ticket: SBDEV-3128
lane: Phase 3a conformance (impl-verifier)
head: 7fb22890
base: 8171c80a (origin/develop)
tree: scratchpad/verify-3128 (detached at 7fb22890)
date: 2026-11-02
verdict: PASS
---

# SBDEV-3128 P1: conformance verification

**Question:** did 7fb22890 build what plan r4 says, for P1 (wms2-api)?
**Verdict: PASS.** Confidence is high. There are 0 blockers and 6 Low findings.

## Fresh evidence (run in my own tree, one Maven process at a time)

| Check | Command | Result |
|---|---|---|
| Compile | `mvn -o -q clean compile` | exit 0 |
| Unit (11 classes) | `mvn -o test -Dtest='LocationDefaultBoundsRepositoryContractUnitTest,…,TestClassTransactionManagerArchTest'` | **304 run, 0 F, 0 E, 0 S**, BUILD SUCCESS. Per-class counts from surefire XML: RepoContract 12, ServiceBoundsContract 2, EndpointContract 3, FLA svc unit 74, FLA ctrl unit 33, LocationController 8, LocationService 25, ViewDto 110, Sbdev3017 5, FunctionGuardArch 26, TestClassTxMgrArch 6 |
| ITs (3 classes) | `mvn -o verify -Dit.test='LocationDefaultBoundsMigrationIT,FixLocationAssignmentServiceIT,MobilePutawayServiceIntegrationTest' -Dtest=ZzzNone …` | **33 run, 0 F, 0 E**, BUILD SUCCESS. MigrationIT 14, MobilePutaway 9, FLA-IT 10 (9 reported under `$CreateEditRace` because of the nested-report trap, 1 under `$AdjustCommitted`). 6 failsafe XMLs. The `[ERROR] An error has occured … Connection refused` line comes from the springdoc-openapi generate plugin and is not a test result. |
| Migration vs plan §3.1 | `sed -n 153,228p plan` vs `V2.2.45__location_default_fla_bounds.sql`, `diff` | **IDENTICAL** (diff exit 0). The checksum-frozen header and the SQL are byte-exact. |
| Migration collision | `git ls-tree origin/develop` (local ref) | no V2.2.45+ on develop. V2.2.44 is the predecessor. |
| D8, entity untouched | `git diff --name-only 8171c80a...7fb22890` | no `model/` file in the 27 changed files. `Location.java` and `FixLocationAssignment.java` are unchanged. |
| Placeholders | diff grep `@Disabled\|TODO\|FIXME\|UnsupportedOperationException\|assume` | none added. The only `@Disabled` mention is historical javadoc in FLA-IT:45 ("GATE STATUS - RUNNING"). |

Not re-run, by instruction: the full unit suite and the 63-class IT batch. The author's `impl-3128-unit.log` shows `Tests run: 9491, Failures: 0, Errors: 0, Skipped: 1`. That log predates 7fb22890: it shows `$UpdateLocationBoundDefaults` with 11 tests, and HEAD has 15. The delta 31263d28→7fb22890 is **test-only** (2 files, +54 lines), and I ran both classes fresh above. I did not find a log for the "63 IT classes, 461 run" claim in the scratchpad.

## §0 Affected sites: P1 in-scope rows

| Row | Plan | Status | Evidence (file · snippet) | Test |
|---|---|---|---|---|
| R2 | FLA `getDetailView` +4 columns | VERIFIED | `FixLocationAssignmentRepository`: `"fla.bounds_inherited as boundsInherited, " "l.default_lowerbound as locationDefaultMinAmount, " …`; `FixLocationAssignmentDetailView` +4 getters | `LocationDefaultBoundsRepositoryContractUnitTest.flaGetDetailView_shouldSelectInheritanceColumns`, `projections_shouldDeclareNewGetters` |
| S1 | create seeding point | VERIFIED | `FixLocationAssignmentService.createFixedLocationAssignment`: `Bounds bounds = featureColumns ? lockAndResolveDefaultBounds(storageLocation.getId()) : systemDefaultBounds();` | `$Create.*`, `$FeatureColumnsAbsent.create_probeFalse_legacyPath` |
| S4 | `ViewDtoService:708` (D-1, post-plan decision) | VERIFIED (as D-1) | the read is removed: `// SBDEV-3128 D-1: the UPPER_BOUND sysprop read that stood here was dead …`; `getStockPerLocation(page)` loses the param | `ViewDtoServiceUnitTest$Sbdev3128DefaultBoundsViews.replenishOrderViewByKeyword_absentUpperSysprop_fallsBackTo84`, `…_paddedAndDecimal_parse` (each `verify(syspropService, never()).getSysvalue(UP)`) |
| W1 | create: lock, then native read, then seed, then `markInherited` | VERIFIED | `if (featureColumns && fixLocationAssignmentRepository.markInherited(fixedLocationAssignment.getId()) != 1) { throw new IllegalStateException(…)` after `save` | `$Create.create_probeTrue_locksBeforeCreateUnitload` (InOrder lockById → findDefaultBoundsById → createUnitload), `_markInheritedZero_throwsIllegalState`; IT `create_marksInheritedOnRealPg` |
| W2 | move re-seeds when inherited | VERIFIED | `if (locationRepository.featureColumnsPresent() && fixLocationAssignmentRepository.findBoundsInheritedById(fixedLocationAssignmentId).orElse(false)) { Bounds bounds = lockAndResolveDefaultBounds(destination.getId()); …set*}` before `save`; `requireFlowbin(destination, "Can't move fix assignment. Destination is not a flowbin!")` keeps the message | `$MoveSuccessfulOperations$Move.inheritedReseeds`, `overriddenKeeps`, `probeFalse_neverReadsFlag`; IT `move_inheritedTakesDestinationDefault` |
| W3 | `adjust*` + `@Transactional(tenantTM, rollbackFor Business+Facade)` + `markOverridden(id, version)==1` else OOLFE | VERIFIED | `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` on all 3; private `markOverridden(...)` runs after validation and before the setter, probe-guarded, and throws `ObjectOptimisticLockingFailureException` | `Adjust{Lower,Middle,Upper}Bound.marksOverridden` and `.staleVersion_rejected`; `FixLocationAssignmentServiceBoundsContractUnitTest.boundsWriters_shouldBeTenantTransactional`; IT `AdjustCommitted.adjust_flipsFlagOnRealPg` (method-level `NOT_SUPPORTED`), `markOverridden_staleVersion_noRow` |
| W9 | NEW `updateLocationBoundDefaults` and `resetBoundsToLocationDefault` | VERIFIED | edit order: validate → `requireFeatureColumns()` → `lockById` → `requireFlowbin` (set only) → `updateDefaultBounds` → `writeThroughInherited` → `requestForItem` iff n==1 → `LocationBoundDefaultsResult`. reset: guard → `findById` → `lockAndResolveDefaultBounds` → `resetBounds(...)!=1` → OOLFE → `requestForItem`; never saves | `$UpdateLocationBoundDefaults.*` (15), `$Reset.*` (3) |
| L4 | `getLocationDetails` +3 keys, only when the probe is true | VERIFIED | `if (locationRepository.featureColumnsPresent()) { … details.put("defaultMinAmount", …) }` | `LocationServiceUnitTest$GetLocationDetails.locationDetails_includesDefaults`, `locationDetails_columnsAbsent_omitsKeys` |
| L5 | Location `getDetailView` +3 columns **and** +3 `dto.put` | VERIFIED | repo: `"l.default_lowerbound as defaultMinAmount, " …`; ViewDtoService: `dto.put("defaultMinAmount", result.getDefaultMinAmount());` ×3 | `RepositoryContract.locationGetDetailView_shouldSelectDefaultColumns`; `ViewDtoServiceUnitTest.locationView_includesDefaults` (asserts values 24/36/48) |
| L10 | NEW LocationRepository methods `@RestResource(exported = false)` | VERIFIED | `lockById`, `featureColumnsPresent`, `findDefaultBoundsById` and `updateDefaultBounds` each carry `@RestResource(exported = false)`; so do the 5 FLA-repo methods; none carries `@Transactional` | `RepositoryContract.newRepositoryMethods_shouldBeUnexportedAndNotTransactional`, `lockById_shouldBePessimisticWrite_whenDeclared`, `featureColumnsPresent_shouldProbeInformationSchemaForBoundsInherited` |

Unchanged rows (R1, R3–R15, S2/S3, W1c, W4–W8, L2/L3/L9) have no file in the diff, as planned. §0.4 U1–U5 belong to P2 and are out of scope.

## §3 design spot checks

- **§3.2 SQL.** Every native statement matches the table. `resetBounds` carries `version = version + 1, modified = :now … where id = :id and assignedlocation_id = :locationId`. `writeThroughInherited` carries `… where assignedlocation_id = :locationId and bounds_inherited`. `markOverridden` carries `where id = :id and version = :version`. `@Modifying(flushAutomatically = true)` appears on exactly the two flag writes. `updateDefaultBounds` does not touch `version`.
- **§3.3.** `requireFeatureColumns` message: `"Replenishment defaults are unavailable until database migration V2.2.45 applies on this tenant"`, verbatim. The partial-null message `"Min, Hysteresis and Max must all be set, or all be empty"` is verbatim. The non-flowbin message `"Replenishment defaults can only be set on flowbin locations"` is verbatim.
- **§3.4.** `POST /v3/location/updateBoundDefaults` has a method-level `@RequiresFunction(WEB_UI_VIEW_STORAGE_LOCATION)` and parses with `new BigDecimal(value.toString())`. `POST /v3/fixedAssignment/resetBoundsToDefault` sits under the class gate and returns `getMessageResponse("id = " + id, "Updated")`. `LocationController`'s ctor gains `FixLocationAssignmentService`. The FLA view has `defaultSource` LOCATION/SYSTEM/SYSTEM_INVALID and `boundsOutOfDate` by `compareTo`. The sysprop is read once per request, with an NFE catch.
- **§3.5.** No `@CacheEvict` was added.
- **§3.8.** `TestDatabaseConfig.sbdev3128UnmappedColumns` has `@DependsOn("tenantEntityManagerFactory")`, runs on `landlordDataSource`, and issues 4 `ADD COLUMN IF NOT EXISTS`.

## Task items 2–3

| Item | Status | Evidence |
|---|---|---|
| V2.2.45 header equals §3.1 (checksum-frozen) | VERIFIED | `diff` of plan lines 153–228 against the migration file: identical |
| Migration SQL equals §3.1 | VERIFIED | same diff: lock_timeout 5s, 3 ADD COLUMN, guarded CHECK, `bounds_inherited boolean NOT NULL DEFAULT false`, the CTE backfill with regex guard and `ORDER BY client_id LIMIT 1` |
| D8: no new column mapped on an entity | VERIFIED | no `model/` file changed. New columns appear only in native `@Query` strings and projections |
| D9: probe guards create | VERIFIED | `boolean featureColumns = locationRepository.featureColumnsPresent();`. False: `systemDefaultBounds()`, no lock or read, no `markInherited` (`create_probeFalse_legacyPath`: `never()` on `lockById`, `findDefaultBoundsById`, `markInherited`) |
| D9: probe guards adjust* | VERIFIED | `markOverridden(...)` helper begins `if (locationRepository.featureColumnsPresent() && …)` (`adjust_probeFalse_noMarkOverridden`: `never()` `markOverridden`, `save` called) |
| D9: probe guards move | VERIFIED | `if (locationRepository.featureColumnsPresent() && findBoundsInheritedById…)` (`probeFalse_neverReadsFlag`: `never()` `findBoundsInheritedById`, `lockById`, `findDefaultBoundsById`) |
| D9: probe guards the details popup | VERIFIED | `LocationService.getLocationDetails` has `if (locationRepository.featureColumnsPresent())`, so the keys are omitted when it is false (`locationDetails_columnsAbsent_omitsKeys`: `doesNotContainKeys`, `never()` `findDefaultBoundsById`) |
| D9: edit, clear and reset throw the specified `BusinessException` | VERIFIED | `requireFeatureColumns()`, message above. `$FeatureColumnsAbsent.edit_probeFalse_rejected`, `clear_probeFalse_rejected` and `reset_probeFalse_rejected` each check `isInstanceOf(BusinessException.class).hasMessageContaining("unavailable until database migration V2.2.45")` + `assertNothingWritten()` (`never()` on `lockById`, `updateDefaultBounds`, `writeThroughInherited`, `resetBounds`) |
| D9: lists not guarded | VERIFIED (as planned) | both `getDetailView` SQLs have the comment "Not D9-guarded … raises 42703 until the migration applies (plan D9)" |

## §7.2 acceptance criteria (P1 only)

| AC | Status | Evidence / test (all green in the fresh runs above) |
|---|---|---|
| AC-1 | VERIFIED | `LocationDefaultBoundsMigrationIT.backfill_marksOnlyTenantDefaultTripleInherited`, `backfill_readsTenantSyspropNotHardcoded` |
| AC-2 | VERIFIED | same IT: `backfill_rowAbsent_fallsBack`, `backfill_nonDefaultWorkstationIgnored`, `backfill_lowestClientIdWins` + `_mirrored` (+ the extra `backfill_nonIntegerSysprop_fallsBack`) |
| AC-3 | VERIFIED | `check_rejects_middleBelowLower`, `_partialNull`, `_negativeLower`, `_middleEqualsUpper`; `check_accepts_allNull`, `_zeroZeroOne` |
| AC-4 | VERIFIED | `FixLocationAssignmentServiceUnitTest$Create`: `create_probeTrue_seedsLocationDefault_andMarksInherited`, `_nullLocationDefault_seedsSysprop`, `_markInheritedZero_throwsIllegalState`, `_locksBeforeCreateUnitload` (InOrder), `_unknownLocation_throwsBeforeCreate` |
| AC-4b | VERIFIED | `FixLocationAssignmentServiceIT.create_marksInheritedOnRealPg` |
| AC-5 | VERIFIED | `Adjust{Lower,Middle,Upper}Bound.marksOverridden` and `.staleVersion_rejected` (×3) |
| AC-5b | VERIFIED | `AdjustCommitted.adjust_flipsFlagOnRealPg` carries `@Transactional(value="tenantTransactionManager", propagation=NOT_SUPPORTED)`, a `TransactionTemplate` seed and an `@AfterEach` purge; `markOverridden_staleVersion_noRow` is in the outer class |
| AC-6 | VERIFIED | `$UpdateLocationBoundDefaults.writesThrough` (`times(1)` `requestForItem`), `noInheritedFla_noTrigger` (`never()`) |
| AC-6b | VERIFIED | IT `edit_writesThroughInheritedOnly` |
| AC-7 | VERIFIED | `clear_revertsInheritedToSysprop`: `updateDefaultBounds(LOC, null, null, null)`, write-through captured as 10/50/100 |
| AC-8 | VERIFIED | `rejects_invalidTriple` rows (36,60,60), (61,60,84), (−1,0,1), (−0.0001,0,1), partial-null, 24.00001, each with `never()` on `featureColumnsPresent`, `lockById`, `updateDefaultBounds`, `writeThroughInherited`; boundary rows in `accepts_boundaryTriple` |
| AC-9 | VERIFIED | `$Reset.reset_locationDefault` (`resetBounds(eq(1L), eq(1L), …)` 24/36/48, `never()` `save`, entity not dirtied), `reset_nullLocationDefault_usesSysprop`, `reset_zeroRows_throwsOptimisticLock` |
| AC-9b | VERIFIED | IT `resetBounds_afterMove_noRow` |
| AC-10 | VERIFIED | `Move.inheritedReseeds`, `Move.overriddenKeeps`; IT `move_inheritedTakesDestinationDefault` |
| AC-11 | VERIFIED (plan's encoding) | `Sbdev3017TrancheGateContextTest`: `row("LocationController","/v3/location/updateBoundDefaults","WEB_UI_VIEW_STORAGE_LOCATION")`, `/v3/fixedAssignment/resetBoundsToDefault` in the C1–C7 loop, pin `hasSize(234)` (232 + 2); `LocationControllerUnitTest$UpdateBoundDefaults` ×3; `FixLocationAssignmentControllerUnitTest$ResetBoundsToDefault` ×2; `LocationDefaultBoundsEndpointContractUnitTest` ×3. The 403 is proven by the tranche's existing mechanism (test javadoc :34), not by a new HTTP call; this is what §7.2 specifies |
| AC-14 | VERIFIED | `ViewDtoServiceUnitTest$Sbdev3128DefaultBoundsViews`: `fixedAssignmentView_shouldCarryInheritanceAndDefaultKeys_whenRowRendered` (old 9 keys + 9 new), `_shouldReportSystemSource_whenLocationHasNoDefault`, `_locationDefault_reportsLocationSource`, `_boundsOutOfDate_trueWhenInheritedAndSyspropDiffers`, `_falseWhenEqual` (24.0000 vs 24), `_falseWhenOverridden` |
| AC-14b | VERIFIED | `locationView_includesDefaults` (values, not just keys) |
| AC-14c | VERIFIED | `LocationServiceUnitTest$GetLocationDetails.locationDetails_includesDefaults` |
| AC-15 | PARTIAL | **Unedited: VERIFIED.** None of `RefillFixedLocationPredicateIntegrationTest`, `FlowbinMonitorViewPerFlowbinIT`, `ReplenishmentMonitorViewSchemaIT` or the 3 other H2 tests appears in the diff. **Run: not re-run in this lane** (out of mandate). The author's log shows the 3 PG nets green at 31263d28. The author's report says `MobilePicking`/`MobileReplenish`/`MobileTransferOrderServiceIntegrationTest` were not run in that batch; they may be covered by the claimed 63-class/461 rerun, but I found no log for it |
| AC-16a | VERIFIED | `rejectsSetOnNonFlowbin`: exact message, `never()` `updateDefaultBounds`, `writeThroughInherited` |
| AC-16b | VERIFIED | `allowsClearOnNonFlowbin`: `updateDefaultBounds(LOC, null, null, null)` + write-through |
| AC-17 | VERIFIED | `$CreateEditRace.createThenEdit_flaHasEditedDefault`, `editThenCreate_flaHasEditedDefault` via `HeldRowLockRace`, which asserts the subject is blocked by the holder's pid before releasing. The outcome is checked with `compareTo` 24/36/48 and `bounds_inherited = TRUE` |
| AC-18 | VERIFIED (as D-1) | the 2 tests above. They assert no exception **and** that the removed read stays removed |
| AC-19 | VERIFIED | `fixedAssignmentView_invalidSysprop_rendersSystemInvalid` |
| AC-20 | VERIFIED | `$FeatureColumnsAbsent` ×5 + `Move.probeFalse_neverReadsFlag` + `LocationServiceUnitTest.locationDetails_columnsAbsent_omitsKeys` |
| AC-20b | VERIFIED | `LocationDefaultBoundsMigrationIT.featureColumnsPresent_falseAt2244_trueAfter` |
| AC-20c | VERIFIED | `MobilePutawayServiceIntegrationTest.storeBoxOnLocation_putsWholePalletAway`: `entityManager.flush()`, then the information_schema count = 1, then `select bounds_inherited … where id = :id` = TRUE on the tenant PU. Deviation: it reads through the EntityManager native query rather than `findBoundsInheritedById`. The plan's load-bearing constraint (same tx, tenant PU, not the landlord JdbcTemplate) holds; see L3 |

## Task item 5: test edits that might weaken an existing guard

| Edit | Verdict | Reason |
|---|---|---|
| `FunctionGuardArchTest.fixLocationAssignmentRepository_shouldStillExportItsSiblingSearches`: `containsExactly("findByAssignedlocationId")` → `containsExactlyInAnyOrder("findByAssignedlocationId", "findBoundsInheritedById", "markInherited", "markOverridden", "resetBounds", "writeThroughInherited")` | **Legitimate** | Still an exact-set pin: the 5 additions are named, nothing is wildcarded, and the original member is kept. The rail's question (did a pre-existing sibling lose its export?) is unchanged: un-exporting any of the 8 siblings still goes red. The 5 names are exactly the new FLA-repo methods that L10 requires to be un-exported |
| `TestClassTransactionManagerArchTest.EXEMPT_NON_TRANSACTIONAL`: +`FixLocationAssignmentServiceIT$AdjustCommitted#adjust_flipsFlagOnRealPg`, +`FixLocationAssignmentServiceIT$CreateEditRace` | **Legitimate** | The rail (`nonTransactionalPropagationsMustBeDeclared`, `isEqualTo(EXEMPT_NON_TRANSACTIONAL)`) asks for exactly this: "add or remove the class … in the same commit, and say why". Both entries carry leak/purge rationale. AC-5b's `NOT_SUPPORTED` is plan-mandated, and AC-17's two committed connections need it. The method-level `#` form is what the rail emits (`c.getName() + "#" + m.getName()`) |
| `ViewDtoServiceUnitTest`: 10 strict `when(syspropService.getSysvalue(anyString())).thenReturn("100")` stubs deleted | **Legitimate** | They fed only the read that D-1 removed. Under strict stubs they would raise `UnnecessaryStubbing` against correct code. No assertion was removed, and all 110 tests in the class are green |
| `ViewDtoServiceUnitTest$ReplenishClientScope.detailView_resolvesCallerScope_beforeAnyRead`: InOrder drops `syspropService`, adds `verify(syspropService, never()).getSysvalue(any())` | **Legitimate, slightly strengthened** | The SBDEV-3668 property (scope is resolved before any read) is still ordered against the remaining read (`getOpenViewByKeyword`), and the removed read is now pinned absent. Cosmetic: its `@DisplayName` still says "before the sysprop read" (L1) |
| AC-18 tests: 2 strict stubs on `getSysvalue(UP)` → `lenient()` | **Legitimate** | Each test pairs this with `verify(syspropService, never()).getSysvalue(UP)`, so the leniency cannot hide a re-introduced read: the author's VIEW-AC18-restore-read mutant went red |
| `Sbdev3017TrancheGateContextTest` `hasSize(232)` → `234` | **Legitimate** | +2 net-new routes, each with its own row. This is the ratchet's documented shape |
| `LocationControllerUnitTest` ctor call +1 arg | **Legitimate** | required by the §3.4 ctor change; this is the only `new LocationController(` call site |

## Gaps / findings (all Low, none blocking)

- **L1:** Stale names after D-1. `detailView_resolvesCallerScope_beforeAnyRead`'s `@DisplayName` ("before the sysprop read") and `replenishOrderViewByKeyword_absentUpperSysprop_fallsBackTo84` (nothing falls back to 84 any more) misdescribe the code. Fix: rename them.
- **L2:** AC-15 execution is not independently re-run here. The full-suite log `impl-3128-unit.log` (9491/0/0/1) was produced before 7fb22890, though the delta is test-only and I re-ran it fresh. I found no log for "63 IT classes, 461 run", and the 3 non-Putaway H2 tests are listed as not run in the implementation report. Fix: the Phase-3 full `mvn verify` (or a batched IT rerun) should cite a log at 7fb22890.
- **L3:** AC-20c reads through `entityManager.createNativeQuery`, not `findBoundsInheritedById` as the §7.2 text says (implementation-report Deviation 7). The constraint that matters (same tx, tenant PU, after flush) is met, and the H2-bean mutant goes red. Acceptable; optionally switch it.
- **L4:** Edit ordering (Deviation 5): the effective triple is resolved before `updateDefaultBounds`, while §3.3 lists it at step 5. There is no observable difference, because the tx rolls back on NFE either way and a bad sysprop now fails before any write. Accept.
- **L5:** AC-14's "old 9 keys unchanged" is asserted by key presence in the new test. Values rely on the pre-existing `GetFixedLocationAssignmentView` tests (green, unedited in their assertions). Low.
- **L6:** The D-5 comment edits (`FixLocationAssignmentController:22-24`, `LocationController` C15/C16) are outside §0, but comment-only and declared in the report. No behaviour change.

## Recommendation

**APPROVE (conformance).** Every P1 §0 row and every P1 AC is implemented as plan r4 (+ D-1) specifies. The migration is byte-identical to §3.1. D8 and D9 hold. The 304 targeted unit tests and the 33 targeted ITs pass fresh at 7fb22890. The arch-rail and D-1 test edits are legitimate. Before the PR, close L2 with a full-suite and IT log at 7fb22890.
