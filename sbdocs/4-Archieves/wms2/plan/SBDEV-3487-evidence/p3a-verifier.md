## Verification Report — SBDEV-3487, Phase 3a conformance

### Verdict
**Status**: PASS. The code does what the plan says. Two process items stay open, listed under Gaps.
**Confidence**: high for code and tests (I re-ran them and ran my own mutants). Medium for the executor's full-suite and PIT claims, which I did not re-run.
**Blockers**: 0

The branch implements all of §0's in-scope sites and every shape in §5.2 to §5.5. Every AC has a test that passes, and each of the 5 mutants I tried was caught by the test the plan names for it. The only gaps are a docs frontmatter field that was not updated, and executor claims with no file on disk behind them.

### Evidence (all fresh, run in the worktree at HEAD `690a4109`)
| Check | Result | Command / source | Output |
|---|---|---|---|
| Unit tests: 5 gate classes + `MobileMoveUnitloadServiceTest` | pass | `mvn -o test -Dtest='MobileTruckLoadingServiceTest,…UnitTest,…WriteServiceUnitTest,MobileMoveUnitloadServiceUnitTest,BillofladingPositionServiceUnitTest,MobileMoveUnitloadServiceTest'` | `Tests run: 145, Failures: 0, Errors: 0`, BUILD SUCCESS (matches the executor's 145) |
| ITs | pass | `mvn -o verify -Dit.test=MobileTruckLoadingClosedBolPurgeIT,MobileMoveUnitloadClosedBolPurgeIT -Dtest=ZzzNone …` | 5/0 + 5/0 = `Tests run: 10, Failures: 0`, BUILD SUCCESS |
| Compile | pass | the two runs above compile main and test | no errors |
| Freshness against develop | pass | `git diff <merge-base> origin/develop -- service/mobile, BillofladingPositionRepository, BillofladingPositionService, mobile tests` | empty; `git merge-tree HEAD origin/develop` is clean |
| Placeholders | pass | grep of changed files for TODO/FIXME/@Disabled/skip | none |
| Hand mutants (5, mine) | all killed | `scratchpad/mutants.sh`; originals checksummed and restored | see the table below; checksums match after restore; `git status` is clean |
| Full `mvn -o test` (6887/0), `clean compile` + context-load test, PIT | **not re-run** | executor's claim | no PIT report in `target/`, no mutation or PIT log in `SBDEV-3487-evidence/` |

| Mutant | Test that failed | Attributable? |
|---|---|---|
| M1: delete V1's `SCAN_GATE_D0_RECHECK` call | `HandleTruckOffLoadingNoClear.zeroRowDeleteRechecksAndThrowsWhenClosed` + `…WithRowGoneWarnsAndContinues` | yes (AC-11) |
| M2: hoist V2's backstop above `if (matches)` | `HandleTruckOffLoading.patternMissRunsNoPositionQuery` | yes (AC-5) |
| M3: move the facade call after the try/catch | `scanGate_shouldRejectAShippedPalletBeforeTheWriteService` | yes (AC-2a) |
| M4a (IT): delete Fix A | AC-1 fails on site: `Expecting actual: SCAN_GATE_D0` | yes, exactly the plan's prediction |
| M4b (IT): drop the R4 predicate | AC-9 `"R4 deleteBolPositionsCarrierIdsNoClear removed a CLOSED child"` | yes |

### §0 in-scope sites
| Site | Status | Evidence |
|---|---|---|
| R3 `deleteBolPositionByIdNoClear` | VERIFIED | `+ " AND (bp.state IS NULL OR bp.state <> 'CLOSED')"`; `int deleteBolPositionByIdNoClear(...)`; javadoc points to R5. AC-9 returns 0 for CLOSED, 1 for TRUCK_LOADING, 1 for null state. |
| R4 `deleteBolPositionsCarrierIdsNoClear` | VERIFIED | Same predicate, still `void`. Killed by M4b. |
| R5 `deleteBolPositionById` | VERIFIED | Predicate plus `int`. Carries the full javadoc: "0 is a signal, not a no-op". |
| R6 `deleteBolPositionsCarrierIds` | VERIFIED | Predicate, `void`, short javadoc reference. |
| R1, R2 | VERIFIED untouched | Not in the diff. |
| V1 `handleTruckOffLoadingNoClear` | VERIFIED | `throws BusinessException` with no wrapping. Inside `if (matches)`, before R1: `assertPalletNotShipped(unitLoadLabel, ShippedGuardSite.SCAN_GATE_D0)`. On a 0-row delete: `SCAN_GATE_D0_RECHECK` + WARN. Comment text matches §5.3 word for word. |
| V2 `handleTruckOffLoading` | VERIFIED | Same shape with `MOVE_UNITLOAD_D0` / `MOVE_UNITLOAD_D0_RECHECK`. Its only caller, `scanDestination:288`, has `rollbackFor = {BusinessException.class, FacadeException.class}`. |
| C1 facade `MobileTruckLoadingService.scanGate` | VERIFIED | New constructor parameter and field. The call comes after `requireOutboundPalletLabel` and outside the try (lines 170 and 174). |
| C1 write-service D0 comment | VERIFIED | "SBDEV-3487: the purge throws on a pallet already shipped on a CLOSED BOL … after B2's pallet lock" |
| C2 `scanDestination` | VERIFIED | Protected through V2. AC-6a/6b are green. |
| `BillofladingPositionService` | VERIFIED | The enum lists all 5 sites. `assertPalletNotShipped` matches §5.2 exactly (null return, scalar finder, WARN with the site as its first argument, key plus `(label, bolName)`). The finder SQL matches §5.2 exactly. The `assertParcelCarrierNotOnTruck` javadoc gained "unless they are CLOSED (SBDEV-3487…)". |

### Acceptance criteria
| AC | Status | Evidence |
|---|---|---|
| AC-1 | VERIFIED | `scanGateMustNotDeleteAShippedPalletsClosedBolPositions`. Order: `catchThrowable` → positions `containsExactlyElementsOf(shippedPositions)`, the other BOL empty, pallet location unchanged → key plus site `SCAN_GATE_FACADE` (enum identity, exactly one WARN). Green; M4a kills it with `SCAN_GATE_D0`. |
| AC-2 (a) | VERIFIED | `scanGate_shouldRejectAShippedPalletBeforeTheWriteService` checks the key and `verifyNoInteractions(truckLoadingWriteService, manageOrderService)`. Killed by M3. |
| AC-2 (b) | VERIFIED | The non-outbound test gained `verify(bps, never()).assertPalletNotShipped(any(), any())`. |
| AC-2 (c) | VERIFIED | The delegate test gained `verify(bps).assertPalletNotShipped("PALLET001", SCAN_GATE_FACADE)`. |
| AC-3 unit | VERIFIED | `HandleTruckOffLoadingNoClear#closedPositionThrowsAndDeletesNothing` checks `never()` on R1, R2, R4 and R3. |
| AC-3 IT | VERIFIED | `writeServiceScanGateDirectRejectsShippedPallet` uses `BOUT-948703`, calls the write service directly, checks data first, then site `SCAN_GATE_D0`. |
| AC-4 | VERIFIED | `HandleTruckOffLoading#closedPositionThrowsAndDeletesNothing` checks `MOVE_UNITLOAD_D0` and `never()` on R1, R2, R6 and R5. |
| AC-5 | VERIFIED | NoClear `patternMiss` + `notConfigured`, and V2 `patternMiss`, all `never()`. Killed by M2 (V2 side). |
| AC-6a | VERIFIED | `selectDestinationOfShippedPalletIsRejectedAndRollsBack`. The fixture mirrors closeBOL (tree to Shipped with lock 405, child stock 405, then `closeBolAsShipped`). Pallet and DEST preconditions are asserted first. It then checks positions intact, pallet still on Shipped with lock 405, and site `MOVE_UNITLOAD_D0`. |
| AC-6b | VERIFIED | Pallet stays on the gate with `entity_lock` 0 and CLOSED positions. It is rejected with `MOVE_UNITLOAD_D0` and keeps its data. The javadoc carries the plan's "do not delete as unrealistic" text. |
| AC-7 | VERIFIED | `transferBolPalletIsStillReScannable` uses `BOUT-948704` with a TRANSFER precondition. X is emptied and Y gets the tree. The control `reScanFromAnOpenBolMovesThePallet` is present. |
| AC-8 (a)–(d) | VERIFIED | `AssertPalletNotShipped` nested class, 4/4 green. It covers: null → no throw and no WARN; key plus `parameter == {LABEL,"BOL-X"}` plus one WARN with site identity; `verifyNoMoreInteractions(repo)`; reflection check that the return type is `String.class`. |
| AC-9 | VERIFIED | One fixture per query, saved through the repository with no preset id and a PREFIX name, each call inside `tx()`. R3 and R5 return 0 with count 1. The R4 and R6 CLOSED child counts are 1. Controls cover TRUCK_LOADING (return 1) and null state through R3. Killed by M4b. |
| AC-10a | VERIFIED | `truckLoadingPalletMoveReallyRelocates`: `t` is null, pallet on DEST, positions empty. |
| AC-10b | VERIFIED, with a deviation I judge correct | It uses `tenantTx()` (`@Qualifier("tenantTransactionManager")`) instead of the plan's `tx()`, because `tx()` turned out to open a landlord transaction (see Finding F1). With `tx()` the probe would pass or fail for the wrong reason. It checks that `getMostSpecificCause` is an `SQLException` with SQLState `55P03`. The value is returned from the lambda (§10 note 2). |
| AC-10 control | VERIFIED | `nowaitProbeSeesAnUnlockedPallet` expects no throwable and `containsExactly(palletId)`. |
| AC-11 ×4 | VERIFIED | For each variant there is a throw-on-recheck test and a row-gone test (no throw, but it checks the re-check call was made). Killed by M1 (V1 side). |
| Regression (§6.1 list) | PARTIAL | Only the unit classes and the two ITs were re-run here. `MobileTruckLoadingRollbackIT`, `MobilePalletizeRepalletizeIT`, `BillofladingPositionRepositoryTest`, `TruckLoadingWriteEntryPointArchTest` and the full `verify` rest on the executor's claim (6887/0 against a baseline of 6873/0). |

### Declared deviations
1. **`doNothing()` stubs in commit `628524bf`: scaffolding, not weakening.** Under STRICT_STUBS, a real call to a stubbed method with other arguments throws `PotentialStubbingProblem`. The gate test only stubbed the `_RECHECK` site, so no implementation that makes the required pre-R1 call could have passed it. `doNothing()` on a void mock is the default behaviour, so the test's meaning is unchanged. The stub is also self-checking: if the D0 call were dropped, strict stubs would raise `UnnecessaryStubbingException`, and the kept `verify(bps).assertPalletNotShipped("OUT-123", …_D0)` would fail too. No assertion was removed. M1 shows both AC-11 tests still catch a missing re-check.
2. **V2 comment is self-authored: acceptable.** "scanDestination's rollbackFor includes BusinessException" is true (`MobileMoveUnitloadService:288`).
3. **Javadoc placement: acceptable.** §5.6 asks for the text "stated once; the siblings reference it". The full text is on R5 and R3, R4 and R6 reference it with `{@link}`. The intent is met.

### Fix E docs (§5.6)
| Item | Status | Evidence |
|---|---|---|
| Move-stock (1): "destination"→"source" in 4 places | VERIFIED | Line 42 "the **source** unit-load label … The destination label is never tested". Flow box `← tests the SOURCE label`. Landmine 3 "only fires when the SOURCE label matches". Symptom row line 410 "the **source** label didn't match". `grep 'Destination matches\|destination label didn'` → 0 hits. |
| Move-stock (2): Shipped-source check is `scanUnitLoad`-only; link SBDEV-3490 | VERIFIED | Flow box "⚠ no Shipped-SOURCE check here — that lives only in scanUnitLoad (SBDEV-3490)". Line 276 row carries the ClickUp link. |
| Move-stock (3): Landmine 4 text; bump `last_verified` | VERIFIED | Line 396 text matches the code (key naming the BOL, R3–R6 predicate, TRANSFER still purged, NoClear twin). `last_verified: 2026-09-24`. |
| BOL workflow D0 row | VERIFIED | Line 195 matches the plan and the code (facade before B1, post-B2 backstop, predicate, 0-row re-check, TRANSFER purged). |
| BOL workflow: bump `last_verified` | **MISSING** | Frontmatter still reads `last_verified: 2026-08-03` (only `updated:` became 2026-09-24). `verified_by` still names SBDEV-2797. |

### Gaps
- BOL workflow `last_verified`/`verified_by` were not updated, although §5.6 asks for it. Risk: low. Fix: set it to 2026-09-24 and name the SBDEV-3487 D0-row check, with the same scoped-check caveat the move-stock doc uses.
- The executor's full-suite (6887/0), `clean compile` + context-load test, and "PIT shows no survivors" claims have no file on disk. `target/pit-reports` does not exist and `SBDEV-3487-evidence/` has no mutation or PIT log. Risk: medium, since these are floor items. Fix: save the PIT summary, the §6.1 mutant table and the suite comparison into `SBDEV-3487-evidence/` before the PR. My 5 mutants and the AC runs back the core claims but do not replace the full suite.
- The `IS NULL` arm is pinned only on R3. Dropping it from R4, R5 or R6 would not be caught. This matches the plan's AC-9 wording ("one null-state childless row deleted by R3"), so it is conformant, but only 1 of the 4 arms is guarded. Risk: low (no null-state rows were found in the measurements). Fix, optional: add null-state controls for R5 and for the R4/R6 children.

### Other findings
- **F1 (Medium, pre-existing, outside this diff):** `AbstractTruckLoadingPgFixture:139` injects `@Autowired private PlatformTransactionManager tenantTransactionManager;` with no qualifier. Spring prefers the `@Primary` bean (`LandlordDatabaseConfig:35/42`) over a field-name match, so `tx()` opens a **landlord** transaction. Tenant repository calls inside it each commit on their own. The executor found this and wrote it up in the AC-10b javadoc. It affects every `tx()` user: `MobileTruckLoadingRaceIT`, `MobileTruckLoadingLockOrderProbeIT`, and `seedPallet`'s supposed atomicity. The ticket rule says to propose this rather than fold it in. Fix: add `@Qualifier("tenantTransactionManager")` on the fixture field, then re-run all 4 subclasses, since some may rely on the per-call commits today.
- **F2 (Low):** the null-label early return in `assertPalletNotShipped` has no unit test. It is harmless, because every caller has already rejected or pattern-matched the label.
- **F3 (Low, informational):** the branch is 10 commits behind `origin/develop`. None of them touch the affected paths, and the merge is clean.

### Recommendation
APPROVE: every §0 site and every AC is implemented as specified and passes fresh runs, and each of my 5 mutants was caught by the named test. Before the PR, update the BOL-doc `last_verified` and save the PIT, mutant and full-suite outputs to `SBDEV-3487-evidence/`.

Files:
- /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java
- /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/BillofladingPositionService.java
- /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java
- /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingService.java
- /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java (F1, line 139)
- /Users/np1076/dev/spk/owl/sbdocs/3-Resources/workflows/wms2-bol-truck-loading-workflow.md (line 10, `last_verified` not updated)
- Logs: /private/tmp/claude-503/-Users-np1076-dev-spk-owl/a541b2e1-815c-4ba3-af51-93b6a1077a65/scratchpad/{unit.log,it.log,m1..m4.log,mutants.out}