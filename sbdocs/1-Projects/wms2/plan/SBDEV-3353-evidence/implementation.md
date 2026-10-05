# SBDEV-3353 — implementation evidence

- Worktree: `.claude/worktrees/wms2-api/SBDEV-3353`, branch `bugfix/SBDEV-3353-refuse-move-stock-out-of-parcel`, base `origin/develop` `5fa9bef0`. Date 2026-09-24.
- **Not pushed.** No PR. The working tree was clean after every run and every mutant (`git status --short` showed nothing), and the ArchUnit store did not drift.

## Commits

| SHA | Subject |
|---|---|
| `5c3e0609` | SBDEV-3353: failing tests — refuse a stock move out of a Package (parcel) (the gate, pre-existing) |
| `d7c77870` | SBDEV-3353: refuse an operator stock move out of a Package (parcel) |
| `3bcb4a69` | SBDEV-3353: IT — a reversal out of a parcel rolls back its lock clear |

## Files changed

**Production (`d7c77870`)**
- `src/main/java/net/aim_ai/wms/util/SourceContainerGuard.java` (new). A static class that sits beside `SourceLockGuard` and follows its style. It has two methods:
  - `assertStockNotInParcel(Stockunit, UnitloadRepository, UnitloadTypeRepository)`. It returns early on a null `unitloadId`, then resolves the unit load with `findById(...).orElse(null)`.
  - `assertNotParcel(Unitload, UnitloadTypeRepository)`. It returns early on a null unit load or a null `typeId`, so `findById(null)` is never called. It then checks `unitloadTypeRepository.findById(typeId).map(t -> UNIT_LOAD_TYPE_PACKAGE.equals(t.getName())).orElse(false)`. On a match it throws `new BusinessException(MSG_TRANSFER_SOURCE_IS_PARCEL, label-or-id)`.
  - **Why it takes the repositories as arguments (justified in the javadoc):** a guard reached through an injected bean would be a mock in the callers' unit tests, as `SourceLockGuard`'s javadoc argues. The gate tests also mock `UnitloadService`, so putting `isParcel` on that bean would have made every refusal test assert a stub. All three callers already hold both repositories, so no constructor changes.
  - **Why it uses `findById(typeId)` rather than `findByName(PACKAGE)`:** the gate tests accept either. `findByName` would clash in the same way with fixtures that strictly stub `findByName(Pallet/Case)`, so it gains nothing.
- `WmsConstants.MSG_TRANSFER_SOURCE_IS_PARCEL = "transferStockSourceIsParcel"`. It is top-level, next to the `MSG_TRANSFER_DESTINATION_*` siblings, and has a javadoc. This mirrors how `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION` is declared.
- `messages.properties` and `messages_en_US.properties` (both carry the `transferStockDestination*` siblings) now have `transferStockSourceIsParcel=Container %1$s is a parcel (Package). Stock cannot be moved out of a parcel: its contents are recorded on the order and the bill of lading. This needs manual intervention by a supervisor.`
- `StockunitService.transferStock:332`: the guard call, placed after the comment clamp and log line and **before** `if (isTransferToExistingContainer)`.
- `MobileTransferOrderService.transferStock:367`: the guard call at the top.
- `MobileMoveUnitloadService` private `transferStock:636`: `assertNotParcel(sourceUnitLoad, …)`, inside `if (stockUnits.size() > 0)`, immediately before `transferStockToUnitLoad`.
- `UnitloadService`: `UNIT_LOAD_TYPE_PACKAGE` removed from `TYPES_THAT_REST_IN_A_STORAGE_LOCATION`.
  - The set's javadoc is rewritten. Package is now out, with the reason, and the note says the guard and the set must stay together.
  - The "currently EQUAL to `KNOWN_NON_REUSABLE_TYPE_NAMES`" note is replaced by "now DIFFERS by exactly `Package`".
  - `restsInStorageLocation`'s javadoc parenthetical is updated.
- `UnitloadBusinessService:640` comment: "under this ticket" is changed to "under SBDEV-3340". That comment refers to the `Set.of().contains(null)` fix, which SBDEV-3340 made, so it was ambiguous next to 3353.
- `WmsConstants` and `UnitloadBusinessService` changes are javadoc/comment only, apart from the one new constant.

**Tests (`d7c77870`)**
- `UnitloadServiceUnitTest$RestsInStorageLocation.shouldBeTrue_forPackage` **deleted**. This is the sanctioned flip: it duplicated and contradicted the gate test `restsInStorageLocation_shouldBeFalse_whenTheContainerIsAPackage`, so inverting it would only have produced a duplicate. The gate test's comment is updated to say which test it replaces.
- `StockunitServiceParcelSourceRefusalUnitTest`: +4 tests; no existing assertion was changed.
  - `refusal_shouldNameTheParcelByLabel` also pins constant == literal.
  - `refusal_shouldNameTheParcelById_whenItHasNoLabel`.
  - `messageKey_shouldBePresentInEveryBundleWithAPositionalLabel` ×2 bundles, using a per-file UTF-8 `Properties.load`.
- **Three non-gate fixtures had one stub each changed from `when` to `lenient().when`**, each with a comment:
  - `StockunitServiceToteContainerRelocationUnitTest.palletCarrierMintSiteIsAlsoGated:513`
  - `StockunitServiceTransferStockDestinationTest.newContainer_flowbinSameSkuDistinctInstances_isAccepted:527`
  - `StockunitServiceUnitTest$TransferStockToFlowbin.transfersToFlowbinWithNewAssignment:1693`
  - **Cause:** Mockito `PotentialStubbingProblem` (STRICT_STUBS argument mismatch), not a behaviour failure. The guard now reads the source unit load or its type before the stub those fixtures declared, and it reads it with a different id. The unstubbed read returns empty, which the guard treats as "not a parcel", so the test proceeds exactly as before. None of their assertions changed.
  - **Unavoidable under the spec:** the gate tests force the lookup through `unitloadRepository.findById` / `unitloadTypeRepository`, and these fixtures strictly stub those same methods with other ids.

**IT (`3bcb4a69`)**: `src/test/java/net/aim_ai/wms/integration/service/CancellationReversalParcelSourceIntegrationTest.java` (new). It is modelled on `CancellationReversalLockClearIntegrationTest`: `BaseRollbackIntegrationTest`, H2, the real service graph, and no `@Transactional` on the class.

## Guard order vs SBDEV-3490 (MobileMoveUnitloadService)

The parcel guard runs **last**, after every source check in `scanDestination`. In order, those are:
1. `assertNotNirvanaSentinel`
2. 3490's Nirwana/Shipped source location
3. ON_HOLD on the unit load and on its stock units
4. 3490's fixed-assigned source
5. `checkReservedStock`
6. the destination checks

Rationale:
- Those checks are the more specific diagnoses. A shipped parcel standing in Shipped is still told "Can not move unit load from Shipped".
- The spec required the placement inside the `stockUnits.size() > 0` branch, which keeps `Sbdev3452MoveTruckBoundary.shouldNotConsultGuards_whenMoveStockIsSet` (AC-10, a Package with no stock → "has no stocks") green.

All 3490 tests are green: `MobileMoveUnitloadServiceUnitTest` 61/61 and `MobileMoveUnitloadServiceTest` 25/25. The rationale is written as a comment at the call site.

## 1. Targeted tests

```
mvn -ntp test -Dtest='StockunitServiceParcelSourceRefusalUnitTest,CancellationReversalServiceUnitTest,MobileTransferOrderServiceUnitTest,MobileMoveUnitloadServiceUnitTest,MobileMoveUnitloadServiceTest,UnitloadServiceUnitTest,StockunitBusinessServiceFullMoveInvariantUnitTest,NeverMatcherNullBlindnessArchTest,StockunitServiceToteContainerRelocationUnitTest' -Dsurefire.failIfNoSpecifiedTests=false
```
**Tests run: 275, Failures: 0, Errors: 0, Skipped: 0**, against a required count of ≥ 247. `target/surefire-reports` was wiped first. Per class, summed over the @Nested report files:

| Class | Run |
|---|---|
| StockunitServiceParcelSourceRefusalUnitTest | 30 (26 gate + 4 new) |
| CancellationReversalServiceUnitTest | 27 |
| MobileTransferOrderServiceUnitTest | 33 |
| MobileMoveUnitloadServiceUnitTest | 61 |
| MobileMoveUnitloadServiceTest | 25 |
| UnitloadServiceUnitTest | 84 (85 − the deleted flip) |
| StockunitBusinessServiceFullMoveInvariantUnitTest | 3 |
| NeverMatcherNullBlindnessArchTest | 4 |
| StockunitServiceToteContainerRelocationUnitTest | 8 |

All 17 gate refusal tests are green, and no gate test was weakened, skipped, disabled or deleted apart from the sanctioned flip.

## 2. RTS integration test: GREEN (H2, no Docker needed)

```
mvn -ntp verify -Dit.test='CancellationReversalParcelSourceIntegrationTest,CancellationReversalLockClearIntegrationTest' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
```
Result: `CancellationReversalParcelSourceIntegrationTest` 2/2 and the sibling `CancellationReversalLockClearIntegrationTest` 8/8, BUILD SUCCESS.

- **`aReversalOutOfAParcelIsRefusedAndRollsBackTheLockClear`**
  - Fixture: lock-100 stock (plus a sibling stock unit) in a `Package` at a Packaging location, and the order's only pending log.
  - `completeReversal` throws a `BusinessException` with `getKey() == MSG_TRANSFER_SOURCE_IS_PARCEL`.
  - A re-read in a **new read-only `TransactionTemplate(tenantTransactionManager)`** shows: `entity_lock == 100`, `unitload_id` still the parcel, `reversal_completed_at` null, and 0 `ORDER_BATCH_REVERSAL_COMPLETED` outbox rows for the order.
- **`[control] aReversalOutOfACaseCompletesAndEnqueuesTheOutboxRow`**
  - Same fixture, but the container is a Case.
  - The reversal completes: lock 0, the stock moves, the log is stamped, and **exactly 1** outbox row is written.
  - This proves the refusal test's zero is not vacuous. The fixture seeds a real `CustomerorderBatch` and a real `los_sysprop` row for `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED`, which is deleted in `@AfterEach` because the H2 context is shared with the sibling IT.
  - A `@MockitoSpyBean SyspropService` was tried first. The first test's fixture failed with `UnfinishedStubbingException`; I did not chase the cause and replaced the spy with the real row.
- With hand mutant (a) applied, the refusal IT goes **red**: `…:271 Expecting actual not to be null` (no exception thrown).

## 3. Compile and full suite

- `mvn -ntp -q clean compile` → exit 0, no warnings or errors in the log.
- `mvn -ntp clean test` → **Tests run: 7069, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS.
  - The baseline was 7022/0/0/1 on the pre-rebase base; the total moved with 3490 plus this ticket's tests. Failures and errors are both 0, as in the baseline.
  - This run happened while another session was running a failsafe IT in the `SBDEV-3442` worktree. It was green anyway, so that overlap did not affect the result.
- An earlier full run, before the three lenient edits, had exactly 3 errors, all of them `PotentialStubbingProblem` in the three fixtures listed above.
- `git status` after the run: only my intended files; the ArchUnit store was unchanged.

## 4. Mutation testing

### PIT, scoped (`mvn -o org.pitest:pitest-maven:mutationCoverage -DtargetClasses=<FQN> -DtargetTests=<…>`)

| Class | Tests | Mutants on changed lines |
|---|---|---|
| `util.SourceContainerGuard` | ParcelSourceRefusal, MobileTransferOrderServiceUnitTest, MobileMoveUnitloadServiceUnitTest | **7 generated, 7 killed, 0 survived, 0 no-coverage** (null-unitloadId, null-UL/null-typeId, isParcel conditionals; removed `assertNotParcel` call; lambda → true / false) |
| `service.StockunitService` | StockunitServiceParcelSourceRefusalUnitTest | line 332 "removed call to `assertStockNotInParcel`": **KILLED** (the class-wide 22/146 is the rest of the class against one test class, out of scope) |
| `service.mobile.MobileTransferOrderService` | MobileTransferOrderServiceUnitTest | line 367 removed call: **KILLED** |
| `service.mobile.MobileMoveUnitloadService` | MobileMoveUnitloadServiceUnitTest | line 636 removed call: **KILLED** |
| `service.UnitloadService` | UnitloadServiceUnitTest | `restsInStorageLocation` lines 754–766: 8 mutants, **8 killed**. The set literal is not a PIT mutation site; hand mutant (c) covers it |

There are **no surviving mutants on any new line.** The "remove the null-typeId short-circuit" mutant from the gate report is PIT's `negated conditional` on `SourceContainerGuard:71`, and it is killed.

### Hand mutants

Each mutant was applied, run, and then reverted by copying back from the pre-mutation copies in the scratchpad (not `git checkout`). `git status` was clean after every revert.

- **(a) Guard call deleted in `StockunitService.transferStock`.** The targeted lane goes 275 run / **12 failures**, and the RTS IT goes red.
  - All 10 `StockunitServiceParcelSourceRefusalUnitTest.*_shouldRefuse_*` tests fail (including `completeReversal_shouldRefuse_whenThePickToStockSitsInAParcel`), plus `refusal_shouldNameTheParcelByLabel` and `refusal_shouldNameTheParcelById_whenItHasNoLabel`.
  - Message: `a stock move out of a Package (parcel) must be refused with key 'transferStockSourceIsParcel' — no SBDEV-3353 refusal was raised`.
  - IT: `CancellationReversalParcelSourceIntegrationTest.aReversalOutOfAParcelIsRefusedAndRollsBackTheLockClear:271` (no exception).
  - The mobile refusal tests stay green, correctly, because the mobile services have their own call sites; those are killed by PIT above.
- **(b) Type comparison inverted in the helper (`!…equals`).** 275 run / **18 failures + 17 errors**.
  - Every refusal goes red on all three services: the 12 above, `MobileTransferOrderServiceUnitTest$Sbdev3353ParcelSource` ×4 and `MobileMoveUnitloadServiceUnitTest$Sbdev3353ParcelSourceStockMove` ×2.
  - Every control errors with `BusinessException: Container PKG-0002 is a parcel (Package). Stock cannot be moved out of a parcel…`. The controls are: Case/Default/PickLocation ×3 on each arm, the arm-reach controls, `scanDestination_shouldMoveTheStock_whenTheSourceIsACase` / `…ADefaultContainer`, `transferStock_shouldProceed_whenTheSourceContainerIsACase`, and `StockunitServiceToteContainerRelocationUnitTest.storableContainerStillRelocatesTheContainer` (on "T-0002").
- **(c) `Package` put back into `TYPES_THAT_REST_IN_A_STORAGE_LOCATION`.** 275 run / **1 failure**.
  - Failing test: `UnitloadServiceUnitTest$RestsInStorageLocation.restsInStorageLocation_shouldBeFalse_whenTheContainerIsAPackage:2063`.
  - Message: `[a parcel is outbound packaging, not a storage container — relocating it into a rack bin with the goods inside is the same defect SBDEV-3340 fixed for the tote] Expecting value to be false but was true`.

## 5. Old-literal sweep

I ran `git grep -n -i` over `src/` for `parcel ticket`, `Package stays`, `Package is in this set`, `stays on the relocation path`, `deliberately NOT excluded`, `its own disposition`, `tracked separately` and `SBDEV-3353`.
- The only stale copies were in `UnitloadService`: the set javadoc (×2 paragraphs) and the `restsInStorageLocation` parenthetical. Both are rewritten.
- The `UnitloadBusinessService:640` "under this ticket" is disambiguated.
- The deleted `shouldBeTrue_forPackage` carried the other copy ("tracked separately, NOT an oversight").
- The remaining hits are current, accurate SBDEV-3353 comments.
- The gate tests' "the constant does not exist before the fix" wording is historical and true, and a new test pins constant == literal.
- **Not swept:** `sbdocs/` docs (outside `src/`) that describe `TYPES_THAT_REST_IN_A_STORAGE_LOCATION` including Package, e.g. anything written under SBDEV-3340. Run `verify-docs` against this diff.

## Left undone / open

- Not pushed; no PR and no ClickUp status change (per the brief).
- `handleTruckOffLoading` is deliberately unguarded (decision). It is still an open question for Nam whether offloading a returned parcel is legitimate.
- `scanDestination`'s whole-container `transferUnitLoadToLocation` still relocates a Package **whole**. It does not drain it, so it is a sibling concern outside this guard's scope, as the architect consult said.
- `MobileMoveUnitloadService.transferStock`'s `case UNIT_LOAD_TYPE_PACKAGE: // waterfall` is now unreachable from the stock-move path. I left it in place to avoid scope creep.
- The web controller's rendering of the key (a 422 with the bundle text) is not covered by a controller test. The bundle-presence test and the `getLocalizedMessage` rendering test cover the text.
- Independent review lanes have not been run; that is the orchestrator's pass.
