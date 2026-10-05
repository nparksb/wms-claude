---
title: "SBDEV-3487 critic review r2"
snapshot_sha1: bac6c5a4d83536acc2c4b3b3f9f1b1505695d724
verdict: ITERATE
---

**Verdict: ITERATE**

r2 correctly resolves all twelve of my round-1 findings, and the C2 derivation now checks out against the code. What blocks approval is the new test plan. Two of the new ITs (AC-6b and AC-10a) crash on a null field in the fixture before they reach the code under test. The §5.8 STOP rule reads that crash as "analysis §2 is wrong" and would withdraw the C2 claim, so it fires for a fixture defect and draws the wrong conclusion. The §6.2 manual expected results also don't match what either controller returns.

## Round-1 findings #1–#12

| # | Status | Notes |
|---|---|---|
| 1 | Resolved | The §2.1 derivation is correct (verified below). R2 is marked unreachable. Fix D is re-justified as protection for future callers and for a flush-order change. A2's rejection is restated, and the C2 clause is gone from §3.3 and the ADR. |
| 2 | Resolved | `throws BusinessException` is added to both D0 variants, and wrapping is forbidden. The only compile break is `MobileTruckLoadingWriteServiceUnitTest:124`. The other test methods that call the variants already declare `throws` (`MobileMoveUnitloadServiceUnitTest:534,550,896`, `MobileMoveUnitloadServiceTest:638`, write-service unit test `:237,:497`). |
| 3 | Resolved in form | AC-6 now asserts in the order throwable, data, key. The rewritten STOP rule now fires on fixture defects (H1). |
| 4 | Resolved | R3/R5 return `int`, a 0-row result triggers the re-check, and AC-11 covers it. |
| 5 | Resolved | AC-2 is in `MobileTruckLoadingServiceTest`, which already builds a real `OutboundPalletLabelGuard(syspropService)` (`:81`). One mutation claim is wrong (L1). |
| 6 | Resolved | AC-9 uses one fixture per query, with childless CLOSED rows for R3/R5. |
| 7 | Resolved | The pre-mortem scenarios are now realistic. |
| 8 | Resolved | Every guard WARN now carries a `ShippedGuardSite` tag. The logger is `LoggerFactory.getLogger(BillofladingPositionService.class)` (`BPS:15`), and WARN is enabled in the PG lane (`application-postgres-integration.properties:214`, `net.aim_ai=INFO`). |
| 9 | Resolved | The coupling with SBDEV-3490 is recorded and AC-6b is added. AC-6b's fixture description is wrong (H1). |
| 10 | Resolved | `git grep -i "UPDATE BillofladingPosition"` finds only `BillofladingService:1512`. |
| 11 | Partly resolved | The manual-test regex is anchored, and DEST is correct: V2.2.00 has no constraint row for type 1 (constraints cover types 2–7 only). But the guards that check the **source** before V2 were not walked (H1). |
| 12 | Resolved | The plan is 391 lines and has a §2.5 RALPLAN-DR section. |

## New findings

**H1 (High): AC-6b and AC-10a throw a NullPointerException in `scanDestination` before V2 runs, and the STOP rule then draws the wrong conclusion.**
- **Where it fails:** `MobileMoveUnitloadService:310` is `if (sourceUnitLoad.getEntityLock() == WmsConstants.BusinessObjectLockState.ON_HOLD)`. `Unitload.entityLock` is an `Integer` (`Unitload:12`) and `ON_HOLD` is an `int` (`WmsConstants:1560`), so a null lock is unboxed and throws.
- **Why the lock is null:** `PgLaneFixtures.unitload` never sets it (`:202-209`), and the column has no default (`V2.2.00:1107`). Nothing on the scanGate path writes a unitload lock: `MobileTruckLoadingWriteService` has no `setEntityLock`, and the `UnitloadBusinessService:178` javadoc confirms that no path locks a unitload before BOL close.
- **Which ACs break:**
  - AC-6a is safe, because it sets 405.
  - AC-10a sets no lock, so it throws every time. It is supposed to be green before the fix, so its red trips the STOP rule: "the §2.1 C2 derivation would then be wrong".
  - AC-6b says the pallet "stays on the fixture storage location with `entity_lock` 0". Both parts are false. The first scanGate leaves the pallet on the **gate** (see the `MobileTruckLoadingClosedBolPurgeIT:138-141` javadoc), and its lock is **null**. So AC-6b also throws. Its data assertions pass (the transaction rolled back), then the key assertion fails, and the STOP rule concludes "C2 claim withdrawn, AC-6 becomes a positive control". That is the wrong call, and it removes Fix C's only IT coverage.
- **The rule's own examples are misclassified:** it lists `EntityNotFound` as evidence that the analysis is wrong. In this lane `EntityNotFound` almost always means a fixture defect.
- **Unacknowledged:** no IT has ever called `scanDestination` (`git grep "scanDestination(" src/test` finds only unit tests). `CODE_TRANSFER` also takes the BLOCK_REALIGN pick-realign path (`PickLineActivityCodeClassifier:36`), which no PG-lane test has run for this tree.
- **Fix:**
  - After the first scanGate, set the pallet's `entity_lock` explicitly: 0 for AC-6b and AC-10a, 405 for AC-6a.
  - Correct AC-6b's description to "pallet on the gate".
  - Assert the preconditions (lock not null, location as expected) before calling the service.
  - Rewrite the STOP rule to classify the throwable first. An NPE, an `EntityNotFound`, or any frame above `:375` means "fix the fixture", not "analysis wrong". Only a non-null `BusinessException` or `FacadeException` thrown from a guard in `scanDestination` or `transferUnitLoadToLocation` disproves §2.
  - Record that this is the first PG-lane run of `scanDestination`.

**M1 (Medium): the new IT class's teardown fails and leaves residue in the reused container.**
- **What breaks:** AC-10a leaves the fixed-label pallet on DEST, and so does AC-6a before the fix. DEST is named with `PREFIX` and is swept. Pallets with fixed labels are not swept, so the base sweep's `delete from location where name like ?` (`AbstractTruckLoadingPgFixture:404`) hits the unitload FK and fails. This is the exact failure measured in `ClosedBolPurgeIT:138-141`.
- **Consequences:**
  - `@AfterEach` fails, so AC-10a goes red and trips the STOP rule.
  - The purge rethrows (`:376`), and the container is reused across builds. Every subclass's `@BeforeEach` purge (`:172`) then fails on later runs, and re-seeding the fixed label collides with the global UNIQUE on `labelid`.
- **Fix:** specify a `purgeByPrefix` override like the one at `ClosedBolPurgeIT:143-155`: move the pallets to the seeded location, call super, then delete `unitload_record` and `unitload` rows by exact label. Use new, distinct `BOUT-` labels. In AC-10b, call `status.setRollbackOnly()`.

**M2 (Medium): the §6.2 manual expected results are wrong.**
- **HTTP status:** both endpoints catch `BusinessException` and return **200** with `{"errors":[…]}`, not a 4xx. See `TruckLoadingController:121-132` and `MoveUnitloadController:76-90`. The success response for selectDestination is `true`.
- **Message text:** it is resolved with `Locale.getDefault()` (`BusinessException:50`), so the `Accept-Language: en-US` header does nothing. Whether the text reads "Pallet … already part of BOL …" depends on the server JVM's default locale.
- **Fix:** expect 200 with an `errors[0]` entry that holds the message, or the raw key on a non-en_US JVM. Drop the header.

**M3 (Medium): AC-1's spec contradicts Step 2's required red reason.** AC-1 is now written as `assertThatThrownBy(...)` first. Before the fix, it therefore fails with "no throwable", not "positions deleted", and the reproduction no longer proves that rows were deleted. AC-3's IT has no stated assertion order at all. **Fix:** use the AC-6 order for AC-1 and for AC-3's IT: `catchThrowable`, then the data assertions, then the key and site.

**L1 (Low): one AC-2 mutation claim is false.** "Move it into … the try → (a) red" doesn't hold. Inside the try, a `BusinessException` is not a `PessimisticLockingFailureException`, so it propagates exactly as it does outside, and `verifyNoInteractions` still passes. That is an equivalent mutant. Only "after the try" is killed. Drop the claim or mark it as equivalent.

**L2 (Low): the site assertion can let a mutant survive.** A plain `contains("SCAN_GATE_D0")` also matches `SCAN_GATE_D0_RECHECK`, so the "delete the backstop → site becomes RECHECK" mutant would survive. Assert on `getArgumentArray()[0] == site`. Also filter on the "SBDEV-3487 shipped-pallet guard" prefix, because `BillofladingPositionService` logs other WARNs (`:89`, `:109`).

**L3 (Low): Step 2's compile-only list is incomplete.** It omits the constructor parameter and field, the finder declaration, and the `ShippedGuardSite` enum. AC-2 and AC-8 don't compile without them.

**L4 (Low): the §8 observability line is muddled.** A `MOVE_UNITLOAD_D0` line can never appear "on scanGate". In production it means a direct selectDestination call, or a handheld move of a pallet that has a CLOSED position but is not on Shipped. The handheld can reach that second case, because `scanUnitLoad` rejects only a Shipped source.

**L5 (Low): AC-9's position fixtures need details.** `billoflading_position.id` has no default, and rows are swept only when `name` matches `PREFIX%`. Say "save through the repository, with `name` = PREFIX + …".

**L6 (Low): the manual test touches a real dev CLOSED record.** Snapshot X's position rows before running it, in case the deployed SHA doesn't carry the fix.

## Claims I verified
- **Route 1:** `processTransfer` dirties the pallet (`UnitloadBusinessService:526-527`) and then runs the JPQL `findByCarrierunitloadId` (`:544`) on the same table, which triggers the AUTO flush. `transferUnitLoadToLocation` enforces only the destination's lock (`:251`) and constraints (`:275-325`).
- **Route 2:** Hibernate 6.6.39 `NativeQueryImpl.prepareForExecution` (`:654-670`) does a full flush when there are no synchronized spaces, and `shouldFlush` returns `isJpaBootstrap()` under AUTO (`:676-692`). The tenant EMF is a `LocalContainerEntityManagerFactoryBean` (`TenantDatabaseConfig:70`).
- **Version check:** `@Version` is at `AbstractBaseEntity:34`. closeBOL's `UPDATE Unitload … version+1` is at `BillofladingService:664-670`, and its flush at `:696`.
- **R2 unreachable:** holds. If closeBOL commits first, C2's stale version fails the check. If C2 goes first, closeBOL blocks and its position flush fails on the deleted rows.
- **finishTransfer:** the BOL lock is at `:1485`, the positions go CLOSED at `:1511-1516`, and the unitloads are updated at `:1588-1596`. `lockContention` covers `40P01` (`MobileTruckLoadingService:242-243`).
- **Mixed tree:** `RestExceptionHandler` has no `DataIntegrityViolationException` handler, so the result is a 500, as the plan says.
- **Before V2, `scanDestination` checks only the destination for Shipped** (`:344-347`), and `assertSourceCarrierNotOnTruck` is a no-op when `carrierId == null` (`BPS:80-81`, `:99-100`).
- **Seed data:** the outbound sysprops (`V2.2.00:2615`, `:2638`) and the Nirwana unitload (`:3139`) are seeded.
- **R5/R6 annotations:** R5/R6 are `clearAutomatically`, and R3/R4 are `flushAutomatically` (`BillofladingPositionRepository:109-162`).

## What must change for APPROVE
1. H1: set the pallet's lock explicitly in the fixture, assert the preconditions, correct AC-6b's description, and make the STOP rule classify the throwable before drawing any conclusion.
2. M1: specify the new class's `purgeByPrefix` override and its labels.
3. M2: correct the §6.2 expected results to 200 with an `errors` body.
4. M3: use the AC-6 assertion order for AC-1 and AC-3's IT.

Fold L1–L6 into the same revision.

**Verdict justification:** I started in thorough mode and escalated to adversarial after H1, because the AC-10a failure is certain as written. Realist check: H1 stays High rather than Critical. The stack trace would point straight at `:310`, but the plan tells the executor the wrong thing to conclude from the red and would remove Fix C's coverage. M1 stays Medium: the sibling class already shows the fix, but residue in the reused container spreads to other test classes.

**Open questions (unscored):**
- Does the BLOCK_REALIGN path (`lockOwningPickingorders`, `realignForMovedStockUnit`, `syncForMovedStockUnit`) run cleanly on this fixture's parcel stock unit? I didn't walk it.
- I did not re-verify the Hydra PRD figures against the database.

*Ralplan summary:*
- **Principle/option consistency: Pass.** P1–P5 map onto the chosen option A1. D3 is covered for every layer except the re-check, which has unit coverage only and shows up in the IT lane only under mutation.
- **Alternatives: Pass.**
- **Risk/verification rigor: Fail.** The STOP rule can fire for a fixture defect (H1, M1), and the manual expected results are wrong (M2).
- **Deliberate additions: Pass.** The pre-mortem is sound, and the expanded test plan covers unit, IT, manual E2E and observability.

Files: the plan is `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/plan-snapshot-r2.md`. Key code, under `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/`:
- `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java` (lines 287–378)
- `src/test/java/net/aim_ai/wms/common/fixtures/PgLaneFixtures.java` (lines 202–209)
- `src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java` (lines 362–405)
- `src/main/java/net/aim_ai/wms/controller/mobile/TruckLoadingController.java` (lines 113–132)
- `src/main/java/net/aim_ai/wms/controller/mobile/MoveUnitloadController.java` (lines 67–90)