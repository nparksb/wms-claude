# SBDEV-3353 — P2 re-review fix pass

- Worktree `.claude/worktrees/wms2-api/SBDEV-3353`, branch `bugfix/SBDEV-3353-refuse-move-stock-out-of-parcel`. Date 2026-09-24.
- Input: `p2-rereview.md` (N1 Medium, N2–N6 Low). I did not write that review.
- Commit: **`ee40d348`**, `SBDEV-3353: re-review fixes — scalar guard reads before the lock read, setLockDamaged guard below the lock switch, wording`, on top of `69de9e8e`. **Not pushed.**
- No lock-order change was needed, so I did not stop. Both reads are now scalar, and no lock is added or moved.

## N1: the design choice, and why

The reviewer's N1 covers the `Stockunit`. The brief asked me to check the unit load as well, and it has the same defect. It has had it since the first commit `d7c77870`, not only since `69de9e8e`.

- `SourceContainerGuard.assertStockNotInParcel` resolved the source unit load with an entity `unitloadRepository.findById`.
- `StockunitBusinessService.transferStockToUnitLoad` locks that same row with `unitloadRepository.findByIdForUpdate(sourceStockunitUnitloadId)` at `:237`.
- Inside `@Transactional transferStock`, that makes the source `Unitload` managed before its lock read.
- It hits the same two arms as the Stockunit defect: the existing non-pallet container arm and the flow-bin new-container arm. The pallet arm (`:370`) and the rack arm (`:445`) read the source unit load themselves anyway.
- It also hit RTS when the reversal went to a flow-bin location.

So I used **option 1 for both entities: scalar reads, and no entity managed that the method later locks.**

- **Stockunit.** `transferStock` now reads `stockunitRepository.findUnitloadIdsByIdIn(List.of(id))`. That existing JPQL scalar select manages no entity; it exists for the same reason under SBDEV-3244 F2. If the result is empty (row gone, or no unit load), it falls back to the snapshot's id, which is what the old `.orElse(stockUnit)` did.
- **Unitload.** New `UnitloadRepository.findParcelGuardViewById`: `SELECT u.id AS id, u.labelid AS labelid, u.typeId AS typeId`, returning the interface projection `UnitloadParcelGuardView`, `@RestResource(exported=false)`. The guard now uses it for **every** stock-unit caller, not just `transferStock`. That makes "the guard never manages a Unitload" a property of the guard, not of one call site.
- **UnitloadType.** It is still `findById`. That is safe: nothing locks `unitload_type`. I checked this with `git grep ForUpdate`.
- **Rejected: `entityManager.detach(reRead)`.** The guard is a static without an entity manager. Detaching would also break a caller that already holds the same instance managed; RTS does.
- **Rejected: resolve the Unitload with `findById` and call `assertNotParcel`.** It moves the defect to the unit load, as described above.

The javadoc records the choice and the reason in four places: `UnitloadParcelGuardView`, the `SourceContainerGuard` class javadoc ("What it reads"), the javadoc of the new `assertUnitloadNotParcel`, and the call-site comment in `transferStock`.

### The other re-read sites: checked from the annotations

| Site | In a transaction? | Verdict |
|---|---|---|
| `StockunitService.setLockDamaged` | No. `StockunitService` has no class-level `@Transactional`; the method-level ones are at `:320`, `:679` and `:889`, and none is this method. `StockUnitController` has 0 occurrences of `Transactional`. The third caller, `ReturnAdviceAutoReceiveService.applyDamage`, is reached from `execute`/`executeInternal`, which are deliberately not `@Transactional` (`:672`). | The entity re-read is safe, so I left it. The comment now says why. |
| `MobileTransferOrderService.transferStock` | No. 0 occurrences of `Transactional` in `MobileTransferOrderService`, `TransferOrderController` and `AdminController`. | Left, with the one-line reason added (N3). |
| `CancellationReversalService.completeReversal` pre-check | Yes, `@Transactional` at `:199`. | The **stock unit** is already managed by `stockunitRepository.findById` at `:255`. That read predates SBDEV-3353, because the SBDEV-3326 lock check needs it, so the guard adds no new Stockunit exposure. The **unit load** was newly managed by the guard's old entity read and is now read as scalars. The comment says both. |

### The stale-at-lock-read IT: not built

`ReplenishmentStaleVersionAtLockReadIntegrationTest` is the only IT of this mechanism. It has a replenishment-specific fixture, a holder thread, and `pg_stat_activity` block detection. `transferStock` would need its own fixture for the location, location type, FLA and item, plus that choreography. That is a new harness, so I did not build one, per the brief. The unit test pins the invariant instead: no entity `findById` before the move call, with scalars read first. The two RTS ITs run the projection query on real Postgres.

## Finding → fix → proving test / mutant

| Finding | Fix (file + snippet) | Proving test, and the mutant that turns it red |
|---|---|---|
| **N1** (Medium) | `StockunitService.transferStock:345-347`: `Long sourceUnitloadId = stockunitRepository.findUnitloadIdsByIdIn(List.of(stockUnit.getId())).stream().findFirst().orElse(stockUnit.getUnitloadId()); SourceContainerGuard.assertUnitloadNotParcel(sourceUnitloadId, stockUnit.getId(), unitloadRepository, unitloadTypeRepository);`. `SourceContainerGuard:102`: `unitloadRepository.findParcelGuardViewById(unitloadId)`. `assertStockNotInParcel` now delegates to `assertUnitloadNotParcel`, and both it and `assertNotParcel` share a private `judge(id, typeId, label, …)`. The 5 WARN branches and their messages are unchanged. New `repo/projection/UnitloadParcelGuardView.java` and `UnitloadRepository:39-44`. | `StockunitServiceParcelSourceRefusalUnitTest.transferStock_shouldNotLoadTheSourceEntitiesBeforeTheLockRead`, parameterized over the existing-container and flow-bin arms. It checks `never().findById(STOCK_UNIT_ID)` on `stockunitRepository`, `never().findById(SOURCE_UL_ID)` on `unitloadRepository`, then an `inOrder` of `findUnitloadIdsByIdIn` → `findParcelGuardViewById` → `transferStockToUnitLoad`. **Mutant m1** (restore the entity re-read): 2 red. Message: *"SBDEV-3353 N1: transferStock must not load the source Stockunit ENTITY (findById) before transferStockToUnitLoad's findByIdForUpdate — inside this @Transactional method a pre-lock entity read makes the lock read a lock upgrade that throws StaleObjectStateException on a concurrent commit; read the unit load id as a scalar"*. **Mutant m2** (guard back to entity `unitloadRepository.findById`): 8 fail + 1 error. They include `SourceContainerGuardUnitTest.assertStockNotInParcel_shouldNotLoadTheUnitloadEntity` ("SBDEV-3353 N1: the guard must not put a Unitload ENTITY into the persistence context…"), both N1 arms, and the RTS pin `CancellationReversalServiceUnitTest.completeReversal_shouldClearAndMove_whenThePickToStockSitsInATote`, which gained `verify(unitloadRepository, never()).findById(any())`. **Mutant m4** (judge the snapshot's unit load id and skip the scalar re-read): 3 red, including the L1 test `transferStock_shouldRefuse_whenTheReReadRowIsInAParcelButTheSnapshotIsNot` ("no SBDEV-3353 refusal was raised"). So L1 is still graded after the re-read changed shape. New guard tests: `assertUnitloadNotParcel_shouldRefuse_whenTheUnitLoadIsAPackage`, `…_shouldWarn_whenTheIdIsNull` (no lookup at all), `…_shouldWarn_whenTheProjectionHasNoTypeId`. |
| **N2** (Low) | `UnitloadService` set javadoc (`:716-722`) now says the set is "the backstop only if the guard is removed or bypassed … It is NOT a backstop for the guard's fail-open (proceed-unguarded) branches — a null typeId or a missing type row, which this method cannot resolve either, so it answers 'not storable' and the split arm drains the container." The `SourceContainerGuard` class javadoc heading is now "Fail-open: an unknown answers 'not a parcel'". I swept every copy with `git grep -n "fail-closed\|fail closed"` over the branch's files: the fixture comments in CancellationReversal, ToteContainerRelocation, TransferStockDestination and StockunitServiceUnitTest, the ParcelSourceRefusal section header, 3 `@DisplayName`s and a javadoc, and the SourceContainerGuardUnitTest javadoc and assertion message now read "fail-open (proceed-unguarded)". **0 hits remain in SBDEV-3353 text.** One hit is left on purpose: `UnitloadService:777` belongs to SBDEV-3340's `restsInStorageLocation`, and for that predicate "not storable" really is its safe direction. | Wording only. `UnitloadServiceUnitTest` 84/84. |
| **N3** (Low) | I appended a **Corrections** section to `p1-fixes.md` and did not rewrite the original table. It corrects: the mobile-comment claim; the "pure narrowing" claim (N1); the unit-load side of N1, which nobody had flagged; the M1 "backstop for fail-closed" claim; the fail-closed naming; and "writes nothing" (N5). The mobile comment (`MobileTransferOrderService`, above the guard) now says: "An ENTITY re-read is safe here, unlike in StockunitService.transferStock … neither this method nor TransferOrderController is @Transactional, so the row is detached as the repository call returns…". | n/a |
| **N4** (Low) | `StockunitService.setLockDamaged`: the guard moved from above the lock switch to below it and below the three amount checks. It is now just above the `Location location_damaged` lookup (`:811`) and before `mintUnitloadLabel`, the first write, which is a REQUIRES_NEW sequence. Everything between the old and the new position only reads or throws. | `StockunitServiceParcelSourceRefusalUnitTest.setLockDamaged_shouldKeepTheLockMessage_whenALockedParcelIsRefusedByTheLockSwitch`, 3 cases: 405 → "already shipped", 2 → "deleted entity", 100 → "already Picked". Each asserts the fragment, a key other than `transferStockSourceIsParcel`, `never()` on the guard's read, and `never()` on the mint and on the move. **Mutant m3** (guard back above the switch): 3 red, *"SBDEV-3353 N4: a lock-405 parcel must get the lock switch's own refusal, not the generic parcel one — the parcel guard sits BELOW the lock switch"* (likewise for 2 and 100). The existing H1, L1 and Case-control setLockDamaged tests stay green. |
| **N5** (Low) | `CancellationReversalService` pre-check comment: "so a refused reversal COMMITS nothing: the refusal runs before the lock clear + flush below and before any sibling position's move …, and the only earlier write — the SBDEV-3316 recovery logRepository.save above, for this row or an earlier one — is rolled back with it by this method's rollbackFor." | Wording only. Behaviour is covered by `CancellationReversalParcelSourceIntegrationTest` 2/2. |
| **N6** (optional) | **Left as is.** The `lenient()` Tote stubs in `CancellationReversalServiceUnitTest.setUp` stay. The tests that refuse earlier in the pre-validate never reach the guard, so strict stubs would fail them, and each would need its own stub. The stubs resolve to real types. The strict L10 refusal and its Tote pin cover the guard, and the Tote pin now also asserts `findParcelGuardViewById(TOTE_UNITLOAD_ID)` is called, so a pre-validate that stops reaching the guard turns it red. The one stub that changed is `findById(TOTE)`, now `findParcelGuardViewById(TOTE)`. | n/a |

### Test-fixture consequence of N1 (stated so it is not mistaken for L2 regressing)

- The three fixtures that L2 made strict and real now stub `findParcelGuardViewById` in place of the entity `findById`: ToteContainerRelocation, TransferStockDestination, and `StockunitServiceUnitTest$TransferStockToFlowbin`. STRICT_STUBS flagged each one as an unused stub, which is how I found them.
- The shared ParcelSourceRefusal, MobileTransferOrder and RTS fixtures also stub it.
- New `src/test/.../common/fixtures/ParcelGuardViews.of(Unitload)`. It delegates to the entity's getters, so a test that changes a label after stubbing is still judged on the new value.
- The other `StockunitServiceUnitTest` transferStock tests never stubbed the guard's type row, even before this pass. So they already proceeded through a fail-open branch, and now do so one branch earlier (unit load not found, not type row missing). **That is not new, and I did not widen it.**

## Verification

`pgrep -fl "surefire|failsafe"` was empty before every Maven run.

- **Targeted lane:** `mvn -o -ntp test -Dtest='SourceContainerGuardUnitTest,StockunitService*Test,CancellationReversalServiceUnitTest,MobileTransferOrderServiceUnitTest,MobileMoveUnitloadServiceUnitTest,MobileMoveUnitloadServiceTest,MobilePutAwayServiceUnitTest,UnitloadServiceUnitTest,NeverMatcherNullBlindnessArchTest,ReturnAdviceAutoReceiveService*Test,StockUnitControllerUnitTest' -Dsurefire.failIfNoSpecifiedTests=false` → **657 / 0 / 0 / 0**. Every class has a non-zero count:

  | Class | Run |
  |---|---|
  | SourceContainerGuardUnitTest | 15 (was 11) |
  | StockunitServiceParcelSourceRefusalUnitTest | 43 (was 38) |
  | CancellationReversalServiceUnitTest | 29 |
  | MobileTransferOrderServiceUnitTest | 39 |
  | MobileMoveUnitloadServiceUnitTest | 64 |
  | MobileMoveUnitloadServiceTest | 25 |
  | MobilePutAwayServiceUnitTest | 67 |
  | UnitloadServiceUnitTest | 84 |
  | StockunitServiceUnitTest | 90 |
  | StockunitServiceTransferStockDestinationTest | 16 |
  | StockunitServiceToteContainerRelocationUnitTest | 8 |
  | StockunitServiceAuditCommentClampUnitTest | 13 |
  | StockunitServiceLockOnHoldTxTest | 1 |
  | StockunitServiceTransferStockGuardTest | 1 |
  | NeverMatcherNullBlindnessArchTest | 4 |
  | ReturnAdviceAutoReceiveServiceUnitTest | 84 |
  | StockUnitControllerUnitTest | 74 |

  The N1 test's `never()` checks were then moved ahead of its `inOrder`, so that m1 reports the named message. The full suite below includes that edit.
- **RTS ITs:** `mvn -o -ntp verify -Dit.test='CancellationReversalParcelSourceIntegrationTest,CancellationReversalLockClearIntegrationTest' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` → ParcelSource **2/2**, LockClear **8/8**, BUILD SUCCESS. Because the refusal happens, this also confirms the new JPQL projection resolves the type id and the label on real Postgres.
- **Compile:** `mvn -o -ntp clean compile` exit 0, with 5 `[WARNING]`s (the same count as P1: deprecation and varargs warnings in untouched files).
- **Full suite:** `mvn -o -ntp clean test` → **Tests run: 7111, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS. 7111 = 7102 + 9 new tests (4 guard, 2 N1, 3 N4). `git status` afterwards showed only the intended files, with **no ArchUnit store drift**. It was clean after the commit.

## PIT

- Command: `mvn -o org.pitest:pitest-maven:mutationCoverage`.
- Target classes: `SourceContainerGuard,StockunitService`.
- Target tests: `SourceContainerGuardUnitTest,StockunitServiceParcelSourceRefusalUnitTest,CancellationReversalServiceUnitTest,MobileTransferOrderServiceUnitTest`.

| Class | Result |
|---|---|
| `util.SourceContainerGuard` | **11 generated, 11 KILLED (whole class).** On the lines this pass changed, all KILLED: `:81` removed call to `assertUnitloadNotParcel`, `:108` and `:123` removed calls to `judge`, `:128` null-id conditional, and `:141` (×2) the blank-label conditionals. |
| `service.StockunitService` | On branch-added lines, all KILLED: `:347` removed call to `assertUnitloadNotParcel` (transferStock) and `:811` removed call to `assertStockNotInParcel` (setLockDamaged, at its new position). Whole class: 28 killed / 21 survived / 98 no-coverage. All of those are in code this branch did not touch, graded against 4 test classes, so they are out of scope. |

- **Other changed classes:** `CancellationReversalService`, `MobileTransferOrderService` and `UnitloadService` changed only comments. `UnitloadRepository` and `UnitloadParcelGuardView` are interfaces. None of them has a mutation site.
- **Not a PIT site, so covered by hand mutants instead:**
  - the scalar-read expression `findUnitloadIdsByIdIn(...).stream().findFirst().orElse(...)` (m1, m4);
  - the projection-versus-entity choice (m2);
  - the guard's position in `setLockDamaged` (m3).

Each hand mutant was applied from a scratchpad copy and restored from that copy (no git stash, checkout or restore). I diffed the files against the copies afterwards and they were identical.

## Not changed

- The L1 residual (no `FOR UPDATE` on the guard's read) is still accepted as decided. The whole-parcel relocation (868m9914u), `handleTruckOffLoading` and `adjustAmount` are unchanged from P1.

## Corrections (added 2026-09-24 after p3-rereview.md)

- **N2 row was wrong:** "0 hits remain" for the fail-closed wording. A capitalised `Fail-closed` survived at
  `StockunitServiceParcelSourceRefusalUnitTest` (class javadoc), because the sweep was case-sensitive. It is
  fixed in the P3 fix commit, along with three sibling "writes nothing" copies (P3-2) and the
  "measured unreachable" wording (P3-4).
- **Stale citation:** the `:889` reference is now `:904`.
- **Wrong claim, found by the conformance verifier (p3-conformance.md):** "the RTS ITs prove the new projection
  query works on real Postgres". They do not: both run on **H2 in PostgreSQL mode** (`BaseRollbackIntegrationTest`;
  the log shows only `H2Dialect`). The projection is a plain JPQL interface projection, and H2 exercises the same
  Hibernate path. No Postgres-specific SQL is involved, but nothing in this branch ran it against a real Postgres.
