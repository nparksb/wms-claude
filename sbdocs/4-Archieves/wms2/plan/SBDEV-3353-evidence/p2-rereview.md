head: 69de9e8e

# SBDEV-3353 — P2 scoped re-review of the review-fix commit

- **Scope:** `git diff 3bcb4a69..69de9e8e` only (19 files, +945/−96). Tree: `.claude/worktrees/wms2-api/SBDEV-3353-review`, detached at `69de9e8e`, clean before and after (mutants were copied to the scratchpad and restored from that copy).
- **Reviewer:** independent lane (code-reviewer). It did not author the change.
- **Verdict: COMMENT.** Mergeable. Every original finding is closed or deferred by Nam's decision. One new **Medium** (N1, MEDIUM confidence): the L1 re-read inside `@Transactional transferStock` loads the source row into the persistence context before the lock read, and that adds a StaleObjectStateException path on arms that did not have one. The fix is small (a projection read), so I recommend making it before the PR. The five new Lows are wording and consistency.

## Instruments run

| What | Result |
|---|---|
| `mvn -o test` on the 11 modified unit classes (Guard, ParcelSourceRefusal, CancellationReversal, MobileTransferOrder, MobileMoveUnitload, MobilePutAway, NeverMatcherArchTest, ToteContainerRelocation, TransferStockDestination, StockunitServiceUnitTest, UnitloadServiceUnitTest) | **450 run / 0 fail / 0 err / 0 skip**. This matches the p1-fixes per-class sum exactly (11+38+29+39+64+67+4+8+16+90+84). |
| Mutant A: `setLockDamaged` judges the snapshot instead of the re-read (`StockunitService:770`) | **1 red**: `setLockDamaged_shouldRefuse_whenTheReReadRowIsInAParcelButTheSnapshotIsNot`, "no SBDEV-3353 refusal was raised". Matches the claim. |
| Mutant B: delete the `completeReversal` pre-check (`CancellationReversalService:282`) | **2 red**: `CancellationReversalServiceUnitTest.completeReversal_shouldRefuseBeforeTheLockClear_…:1054` and `…ParcelSourceRefusalUnitTest.completeReversal_shouldRefuse_…:610`. Matches the claim. |
| `pgrep -fl "surefire\|failsafe"` before each run | empty |
| Not re-run | the full suite (claimed 7102/0/0/1), PIT, the RTS IT and the L8 IT mutants |

## Per-original-finding table

| Finding | Status | Evidence |
|---|---|---|
| **H1** = sec **S1**: Transfer to Damaged drains a parcel | **CLOSED** | `StockunitService:769` is the first statement after the clamp and debug log, before the lock switch and before `mintUnitloadLabel` / `moveStockToNewDamagedContainer`, which are the first writes. Both `/transferToDamaged` (`StockUnitController:553`) and `/bulkTransferToDamaged` (`:595`) call `setLockDamaged` directly. **Bulk tx semantics:** neither `StockUnitController` nor `setLockDamaged` is `@Transactional` (only `:320`, `:670`, `:889` carry it in StockunitService). The write boundary is `moveStockToNewDamagedContainer`, one per id. The guard throws a `BusinessException` before that boundary, and the per-id `try` inside the loop catches it (`StockUnitController:588-597`, SBDEV-3086 F5). So a parcel in a batch refuses only its own id, leaves no partial state for that id, and the other ids proceed. That is acceptable, and it matches the existing per-id error contract. The ReturnAdviceAutoReceive caller is safe: `AdviceRestController:411/:431` set the position type to `UNIT_LOAD_TYPE_BOX` (verified), and any refusal there would be caught at `ReturnAdviceAutoReceiveService:843` and land on the damage worklist. |
| **M1**: "unreachable" over-claim | **CLOSED**, with a wording residue (N2) | `UnitloadService:704-722` now lists the six call sites and names what stays open (868m9914u, `handleTruckOffLoading`, `adjustAmount`). The `UnitloadServiceUnitTest` `@DisplayName` was narrowed. The one clause the executor added beyond the reviewer's suggested text is false (see N2). |
| **L1** (code + sec): guard reads a detached snapshot | **CLOSED as a narrowing**, with a **new side effect at one of the 3 sites (N1)** | At all 3 sites the re-read is used **only** as the guard's argument. Every downstream statement still uses the original `stockUnit` (`StockunitService:337-338`, `:769-770`, `MobileTransferOrderService:392-393`). Nothing saves the detached instance over the re-read. `setLockDamaged` and mobile `transferStock` are not `@Transactional`: the class has no `@Transactional`, and the controller at `TransferOrderController:27-30` has none either. Their re-read therefore runs in the repository's own read tx and is detached at once, which has no effect on the later write tx. `StockunitService.transferStock` **is** `@Transactional` (`:320`), so its re-read is **managed**, and that changes the later `findByIdForUpdate` (N1). |
| **L2**: `lenient()` fixtures ran through the unresolved-type branch | **CLOSED** | All three stubs are strict again: `ToteContainerRelocation:513`, `TransferStockDestination:527`, `StockunitServiceUnitTest:1693`. Each now resolves the source unit load to a real Tote or Case type row, so the guard answers on the type name and not on a missing row. STRICT_STUBS would fail on an unused stub, and the classes are green (8/16/90). |
| **L3**: ArchTest ratchet comment | **CLOSED** | `NeverMatcherNullBlindnessArchTest` 4/4. The ignoreLock/removeUnitLoadIfEmpty parameters are primitive `boolean` at positions 7-8 of `StockunitBusinessService:168` (verified). |
| **L4**: stale "/ Package" comment | **CLOSED** | `StockunitServiceUnitTest:1994-1995`. |
| **L5**: mobile guard pre-empted non-moving outcomes | **CLOSED** | `MobileTransferOrderService:361-392`. Everything above the guard only reads or throws: `customerorderRepository.findById`, the lane `findById`, two lane throws, `customerorderPositionRepository.findById`, `itemdataService.getById`, `calculateStockOnStagingLane` (a query), and the "No stock required" return (a `unitloadRepository.findById` plus a string). The first write, `createUnitload` or `transferUnitLoadToLocation`, is below `:392`. |
| **L6**: blank label | **CLOSED** | `SourceContainerGuard:114`, `label == null \|\| label.isBlank()`. |
| **L7**: missing same-arm controls | **CLOSED** (tests green; the names were read, not each body) | MobileMove 64/64, MobileTransferOrder 39/39. |
| **L8**: IT lock assertion never shown red | **CLOSED on the claim** (not re-run) | The IT javadoc now describes both layers and the two measurements accurately. The unit mutant B above independently confirms that the first layer is graded. |
| **L9**: dead `case PACKAGE` | **CLOSED** | `MobileMoveUnitloadService:673`. "Unreachable" holds: the guard at `:636` is on the only path into this switch, because the empty-source branch throws at `:643`. The guard's unresolved-type branch cannot reach the case either: the switch's own `findById(...).orElseThrow` at `:652` throws first. |
| **L10**: RTS refused only after the lock-clear write | **CLOSED** | `CancellationReversalService:282` is inside the pre-validate loop (`:216-283`), which completes for every row before the movement loop starts at `:285`. The `setEntityLock` / `save` / `flush` at `:367-369` and `transferStock` at `:372` all come after it. **Construction sites:** `git grep "new CancellationReversalService("` finds exactly 2, both updated (`CancellationReversalServiceUnitTest:127`, `StockunitServiceParcelSourceRefusalUnitTest:590`). Spring uses constructor injection, and both repositories are ordinary beans. The ITs `@Autowired` the service in full contexts. One write does sit above the check, `logRepository.save(log)` at `:241`, and it is rolled back (see N5). |
| **Q1** = sec **S2** (putaway) | **CLOSED** | `MobilePutAwayService:552` is the first statement of the `FLOWBIN` case, before `createFixedLocationAssignment` (`:560`) and the draining `transferStockToUnitLoad(..., true)` (`:568`). The method is `@Transactional(rollbackFor=BusinessException)` (`:505`), and the unit load was read in-tx (`:512-518`), so it has no L1 gap. **Non-draining arms verified:** OVERSTOCK / PALLET_OVERSTOCK / STOCK_RESTRICTION (`:569-580`) and the staging-lane default (`:582-584`) call only `transferUnitLoadToLocation`. Its body (`UnitloadBusinessService:221-345`) contains no `transferStockToUnitLoad`, no `sendToNirvana` and no stock save or amount write, so it relocates the unit load whole. |
| sec **S2** `adjustAmount` | **OPEN, awaiting Nam's decision** (as the security review asked) | It is named as open in the `UnitloadService` javadoc. |
| **Q2**: whole-parcel relocation | **DEFERRED** to 868m9914u (Nam's decision) | Pinned by the putaway scope test. |
| sec **L1**: TOCTOU | **ACCEPTED as residual** (Nam's decision) | Recorded in the `SourceContainerGuard` class javadoc. Plain `findById` as decided, with no `FOR UPDATE`. |
| sec **L2**: silent fail-open | **CLOSED** | 5 WARN branches (`SourceContainerGuard:74-103`), parameterized, ids only, no labels or user data. **Frequency:** they fire only on operator actions (a single move, a bulk damage per id, an RTS row), never in a scheduled or hot loop. The "type row missing" branch needs a `unitload.type_id` pointing at a non-existent `unitload_type` row, which the security review measured at 0 on all 6 tenants. On RTS a fail-open state would log twice, once from the pre-validate and once from `transferStock`. That is harmless. The appender in `SourceContainerGuardUnitTest` is detached, and its level restored, in `@AfterEach` (`:65-69`). |
| sec **S3** | **No change**, by decision | — |

## New findings

### [MEDIUM] N1: the in-transaction re-read in `StockunitService.transferStock` makes the later lock read throw StaleObjectStateException on arms that used to serialize
- **File:** `StockunitService.java:337-338`
  ```java
  SourceContainerGuard.assertStockNotInParcel(
      stockunitRepository.findById(stockUnit.getId()).orElse(stockUnit), unitloadRepository, unitloadTypeRepository);
  ```
- **Confidence:** MEDIUM. The mechanism is measured in-repo (memory `findbyidforupdate-throws-at-the-lock-read-not-at-flush`, SBDEV-3244). I did not reproduce it here with an IT.
- **Issue:**
  - `transferStock` is `@Transactional` (`:320`). The re-read therefore puts the source `Stockunit` into the tenant persistence context at `@Version` v. `Stockunit` extends `AbstractBaseEntity`, whose `@Version` is at `:34`.
  - Every draining arm then reaches `StockunitBusinessService.transferStockToUnitLoad`, which calls `stockunitRepository.findByIdForUpdate(id)` at `:201` and then `entityManager.refresh` at `:203`.
  - If another transaction commits a change to that row between the two reads, Hibernate's lock-mode upgrade on the already-managed entity throws `StaleObjectStateException` inside the lock read. The other transaction could be a picker's reservation change, a replenishment recalc, or packing re-homing the row, which is the race L1 targets. The window includes the time this transaction spends blocked on the row lock. Because the throw happens inside the lock read, the `refresh` on the next line is never reached.
  - Before this commit, three arms touched the row for the **first** time under the lock, so they blocked, read the committed v+1, and proceeded correctly:
    - the existing-container arms, both pallet (`:369-392`) and non-pallet (`:393-396`);
    - the flow-bin new-container arm (`:416-441`).
  - The rack arm was already exposed: `findByUnitloadId` (`:448`) and the SBDEV-3341 F1 re-read (`:552`) already load the row.
  - The failure is safe: the transaction rolls back and `RestExceptionHandler:361` maps the error to its optimistic-lock response. But it turns a serialized success into a spurious refusal.
  - In **`bulkTransferStock`** (`StockUnitController:258-278`), the inner `try` catches only `BusinessException` and `FacadeException`. This RuntimeException therefore escapes the loop: earlier ids stay committed, later ids never run, and the whole request is answered with an error. That is the SBDEV-3086 F5 shape, now reachable by a new trigger.
- **Not affected:**
  - `setLockDamaged` and mobile `transferStock`: they are non-tx, so the re-read is detached at once.
  - RTS: the row is already managed from `CancellationReversalService:255`.
- **Fix:** do not materialise the entity for the guard. `StockunitRepository.findUnitloadIdsByIdIn(Collection<Long>)` (`:57-60`) already exists for exactly this reason (SBDEV-3244 F2: "made changeReservedAmount's own findByIdForUpdate a lock UPGRADE rather than a first touch"). Add `SourceContainerGuard.assertUnitloadNotParcel(Long unitloadId, …)`, or a single-id projection, and judge `unitloadId` from that projection. Alternatively, `entityManager.detach(reRead)` right after the check. Pin it with a test that asserts the guard path makes no `stockunitRepository.findById` call, or with an IT that commits a concurrent version bump.

### [LOW] N2: the "backstop" javadoc credits the set with covering the guard's unresolved-type branches, and calls fail-open branches "fail-closed"
- **File:** `UnitloadService.java:716-720`: "*The set is the backstop: it keeps the whole-container arm from relocating a parcel into a rack if the guard is removed, bypassed, or could not resolve the type (its fail-closed branches).*"
- **Confidence:** HIGH.
- **Issue:**
  - When the guard cannot resolve the type (null `typeId`, or a missing type row), `restsInStorageLocation` cannot either. Its own contract (`:755-759`) answers "not storable" and takes the **split** arm, and that arm drains and retires to Nirvana. So for those inputs the set gives no protection. It backstops only removal or bypass of the guard.
  - The guard's 5 branches proceed unguarded, which makes them fail-**open**. The security review calls them that; the code review, this javadoc, the L2 fixture comments ("not on its fail-closed branch") and `SourceContainerGuardUnitTest`'s assertion message ("a fail-closed proceed must be logged") call them fail-closed.
- **Fix:**
  - Drop "or could not resolve the type (its fail-closed branches)".
  - Say "fail-open (proceed-unguarded) branches" throughout.

### [LOW] N3: two p1-fixes.md claims do not match the code
- **Confidence:** HIGH.
- **Issue:**
  - *L1 row:* "setLockDamaged and the mobile method are not @Transactional, so their re-read is a later read rather than an in-transaction one, **and their comments say so**." The `setLockDamaged` comment does say so (`StockunitService:763`). The mobile comment (`MobileTransferOrderService:385-391`) does not: it says "fresh plain findById, not the controller's detached row" and never mentions the transaction.
  - *L1 row:* "RTS needs no re-read". That is true, but the same row presents the `transferStock` re-read as a pure narrowing. It is not (N1).
- **Fix:** Add the one clause to the mobile comment, and correct the claim table.

### [LOW] N4: `setLockDamaged` guard pre-empts the method's more specific lock diagnoses, the same shape L5 fixed on mobile
- **File:** `StockunitService.java:769` sits above the lock `switch` at `:772-783`.
- **Confidence:** MEDIUM. This is a judgement call.
- **Issue:**
  - Parcel stock that is SHIPPED, GOING_TO_DELETE or PICKED_FOR_GOODSOUT (a packed, not cancelled, parcel) now answers "Container X is a parcel (Package)…" instead of "already shipped", "deleted" or "already Picked for goods out".
  - Nothing is written either way, so this only changes which message the operator sees. But it is exactly the rationale used to move the mobile guard (L5), applied inconsistently.
- **Fix:**
  - Either move the guard below the switch and the amount checks and above `mintUnitloadLabel` (`:806`), which is the first write since that sequence is REQUIRES_NEW.
  - Or state in the comment that the parcel message deliberately wins.

### [LOW] N5: "a refused reversal writes nothing" is true only after rollback
- **File:** `CancellationReversalService.java:276-278`: "*…so a refused reversal writes nothing — not the lock clear + flush below, and not a sibling position's move…*"
- **Confidence:** HIGH.
- **Issue:**
  - The pre-validate loop can `logRepository.save(log)` a recovered `picktostockunit_id` at `:241` before the parcel check, for this row or an earlier row.
  - The method's `rollbackFor = BusinessException` (`:199`) undoes it, so nothing commits. But the sentence reads as "no in-transaction write". The IT javadoc's "leave the database exactly as it found it" is the accurate form.
  - The L10 unit test uses a single position, so "not a sibling position's move" rests on the structural argument (the pre-validate loop finishes first), which does hold.
- **Fix:** Reword to "commits nothing: it runs before the lock clear and before any move; the only earlier write (the SBDEV-3316 recovery save) is rolled back with it".

### [LOW] N6: new `lenient()` type stubs in `CancellationReversalServiceUnitTest.setUp`
- **File:** `CancellationReversalServiceUnitTest.java:141-151`, `lenient().when(unitloadRepository.findById(TOTE_UNITLOAD_ID))…` and `givenType(...)`.
- **Confidence:** MEDIUM.
- **Issue:**
  - These stubs are justified and documented: tests that refuse earlier in the pre-validate never reach the check. They also resolve to **real** types, so this is not the L2 defect.
  - The cost: if a future edit makes the pre-validate stop reaching the guard, the tote-path tests stay green. Only the dedicated L10 test and its Tote pin (`:1041-1086`, strict `when`) would notice.
- **Fix:** Optional. Acceptable as it stands.

## Open questions (low confidence, not blocking)
- None beyond N1's confidence note. The N1 exposure depends on how often a concurrent committed write lands on the **same** stock unit during an existing-container or flow-bin Move Stock. On a picked-from pick face that is plausible (reservations), but I have not measured it.

## Old-literal sweep (item 9)
- `git grep -i` over `src/main` for `unreachable|out of scope|at the top|rests in|no constructor parameter|every caller` restricted to SBDEV-3353 or parcel text: the only hit is `MobileMoveUnitloadService:673`, which is true (L9).
- The "at the top of StockunitService.transferStock" wording in `UnitloadServiceUnitTest` and the IT javadoc is still true.
- The only contradicting prose left is N2.

## Positive observations
- Mutation discipline is real. Both re-run mutants reproduced exactly the claimed reds, and the claimed per-class counts reconcile to the test.
- The L10 pre-check is in the right place, and it is graded by a unit test with `never()` on `save` and `flush` and the in-memory lock still at 100. The L8 IT now describes honestly what it can and cannot distinguish.
- The putaway fix is scoped exactly to the draining arm. The non-draining arms are pinned by a scope test rather than silently left alone.
- `SourceContainerGuard`'s split null branches make each fail-open case observable at WARN with ids only, and the log test cleans up its appender.
- The L1 re-reads were kept off `FOR UPDATE`, which respects the SBDEV-2481 / SBDEV-3341 lock order. N1 is about the persistence-context side effect of that choice, not the choice itself.

## Recommendation
**COMMENT.** No High at HIGH confidence. Fix **N1** before the PR (a projection read, one new test). Fold N2-N5 into the same commit as wording. N6 is optional.
