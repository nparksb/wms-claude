---
ticket: SBDEV-3755
lane: code-review (independent, Phase 3b, Fix 1)
head: b37f0d1a66c8154710fd2839d26c6a19ee525093
base: c6f0cbc0 (PR #510 head)
branch: fix/SBDEV-3755-transferstock-replen-held-opt-in
worktree: .claude/worktrees/wms2-api/SBDEV-3755-fix1
date: 2026-10-13
verdict: COMMENT (0 High, 2 Medium, 7 Low; nothing blocking at high confidence)
---

# SBDEV-3755 Fix 1: independent code review

## Method

- Read `git diff c6f0cbc0...HEAD` in full for `src/main` (12 files). Read the new test classes in full: the guard unit test, both ITs, A13, A14, A20, B10, `TransferVerifications`. Spot-read the changed caller tests and the existing rails that were edited (`NeverMatcherNullBlindnessArchTest`, `TestClassTransactionManagerArchTest`, `SdrUncalledSurfaceNotExportedContextTest`).
- Read the plan §0, §4, §5, §8.1, §10 (D1–D4) and §11. `implementation-log.md` and `conformance.md` were used for context only.
- **Runs (JDK 21.0.11, `mvn -o`, one Maven at a time, counts read from report files newer than a marker):**
  - Unit gate set (guard test, Fix B classes, A13, A14, A20, H1 self-test, trigger test, and the related caller classes Maven pulled in): all green, 0 F/E. Examples: guard 21/0, `…ReassignTest` 20/0, `…SourceSyncServiceTest$MultiHolder` 11/0, A14 4/0, A13 2/0, A20 5/0.
  - IT: `mvn verify -Dit.test=ReplenishMultiHolderMoveIT,TransferStockReplenHoldGuardIT -Dtest=ZzzNone`: **9 run, 0 F/E**, BUILD SUCCESS. B8 log line: `bWaitedOnA=true (wait_event_type='Lock', blocked pid=148, blocking pid=147) outcomeA=null outcomeB=null`.
- **Two hand mutants of my own.** For each I copied the file to the scratchpad, edited it, ran it, then restored it from the copy. I recompiled `target/classes` afterwards and checked with `javap` that the mutant bytecode was gone. `git status` is clean.
- **LSP: not run.** `mvn compile` and `test-compile` are clean. I skipped jdtls because it would compete with Maven for the worktree.

## Stage 1: spec compliance (plan §5)

| Plan item | Status |
|---|---|
| A.1 types, overloads, compact constructor, 8/9-arg overloads delegate with REFUSE and return `.stock()` | ✓ `TransferOutcome.java`, `StockunitBusinessService.java:178-190` |
| A.2 predicate `fla == null && A <= amount`, after FLA resolution, before the placeholder block, no earlier write | ✓ `:385`. Only lock reads come before it (`lockOwningPickingorders`, `LockReads.forUpdate` ×5). Both accepted edges are in the javadoc |
| A.3 projection read only when `displacing` | ✓ |
| A.4 REFUSE: blocking candidates first, then the rest; `findById` only on the refuse path; vanished row → next; none left → proceed; `REPLEN_HELD_REFUSED …holder={}@{}`; SU/UL prefix | ✓ `refuseIfHeld` `:515-532` |
| A.5 ALLOW_ANY: null-safe `Objects.equals` filter; one `REPLEN_HELD_DISPLACED` WARN with `NUMBER@state`; displaced holders returned | ✓ `:390-398` |
| A.6 `.orElse(null)` and store line deleted | ✓ (`archunit_store/5fb3fee0…`, one line removed) |
| A.7 only the repository injected into SBS; trigger only in PBS; `UnitloadService` has no trigger | ✓ |
| A.8 `requestIfDisplaced` | ✓ `ReplenishmentMaintenanceTrigger.java:118` |
| A.9 four opt-ins with the decided heal | ✓ #15 `MobileReplenishService` (no heal), #5 `PickingorderBusinessService:1336`, #10 `StockunitService:610` plus the amended SBDEV-2033 comment, #12 `UnitloadService:198` (no heal). No double trigger on #12 |
| B.1–B.7 projection → pre-check by projected state → lock ascending, keep `< FINISHED && same SU` → re-check under lock → re-point, or lock the SU once and run `shareOf`/redirect/cancel per order | ✓ `MovedStockUnitHolders.lockForMove` plus both services |
| B.8 `findIdByStateLessThanAndStockunitId` deleted; `V2.1.04` untouched | ✓ |
| C: `exported = false`, javadoc warning, B10 rail, repository comment corrected | ✓ |
| Deviation: the new `MovedStockUnitHolders` (not listed in §6) | Accepted. It keeps the two copies of the lock-order prefix from drifting apart. It is package-private `final`, has a private constructor and one static method. See M2 for the one side effect |

Stage 1 passes. The implementation is what §5 designed.

## Stage 2: findings

### Medium

**[M1] The "refuse on the projected state" rule has no test. A fall-through mutant survives all 140 Fix B unit tests.**
- File: `src/main/java/net/aim_ai/wms/service/MovedStockUnitHolders.java:60`. Confidence: HIGH (probed).
- Code:
  ```java
  Replenishorder blocking = replenishorderRepository.findById(holder.getId()).orElse(null);
  if (blocking != null) {
      throw new BusinessException(ReplenishmentOrderMessages.replenBlockMessage(blocking));
  ```
- **Why it matters.** Plan §5 B.2 (Ar R2-L4) and this class's own javadoc make "a present row always throws; do not fall through after a present `findById`" a load-bearing rule. A fall-through leaves the order managed below its lock, so the `findByIdForUpdate` that follows becomes the version-checked upgrade that SBDEV-3244 F5 and `LockReadRail` exist to stop.
- **The mutant.** I changed the condition to `blocking != null && ReplenishmentOrderMessages.blocksMove(blocking)`, i.e. "fall through when the loaded row no longer blocks". Running `ReplenishmentOrderSourceSyncServiceTest`, `…SourceSyncServiceBranchTest`, `…MaintenanceServiceReassignTest` and `…MaintenanceServiceUnitTest` gave **140 run, 0 failures: SURVIVED**. I confirmed the mutant bytecode with `javap`.
- **Why nothing catches it.** Every B2 fixture stubs `findById` to return a row whose loaded state is also STARTED. No IT covers this path, so `LockReadRail` cannot see it either.
- **Fix.** Add one unit test per service. Project holder 9 @400, stub `findById(9)` to return a row now @300, and assert a `BusinessException` naming REPL-9 and `verify(replenishorderRepository, never()).findByIdForUpdate(any())`. Then hand-mutate as above to confirm it goes red.

**[M2] The A14 lock fence cannot see the repository being passed to a locking helper, and this change adds exactly that helper.**
- Files: `src/test/java/net/aim_ai/wms/unit/config/StockunitBusinessServiceReplenLockFenceArchTest.java:49` (blind-spot list) and `:134`, together with the new `MovedStockUnitHolders.lockForMove(ReplenishorderRepository, Long)`. Confidence: HIGH (probed).
- **What A14 checks.** It only looks at accesses whose target owner is `ReplenishorderRepository` (direct calls and method references). The new helper sits in the same package as SBS, takes the repository as an argument and calls `findByIdForUpdate` on every holder.
- **The mutant.** I added this to SBS:
  ```java
  private java.util.List<Replenishorder> probeA14(Long id) throws BusinessException {
      return MovedStockUnitHolders.lockForMove(replenishorderRepository, id);
  }
  ```
  `StockunitBusinessServiceReplenLockFenceArchTest` stayed green, **4 run, 0 failures: SURVIVED**.
- **Why it matters.** This is the R3 lock inversion: an order lock taken after the SU lock. The javadoc's *"Remaining blind spot: a native lock or `entityManager.find(…)`"* reads as a complete list, and it is not.
- **Fix, either of these:**
  - (a) Add a rule that SBS has no access to `MovedStockUnitHolders` (or, more generally, never passes the `replenishorderRepository` field as an argument to any call: check `JavaFieldAccess` of that field on a line that also has a `JavaMethodCall` whose parameter types include `ReplenishorderRepository`).
  - (b) At minimum, name helper delegation in the blind-spot javadoc and add a planted-shape self-test for it.

### Low

**[L1] The A14 "subset" rule has no non-vacuity floor.**
- File: `StockunitBusinessServiceReplenLockFenceArchTest.java:134` (`.isSubsetOf(ALLOWED)`). Confidence: HIGH.
- **Problem.** An empty `called` set passes. The positive control (`detector_shouldSeeAKnownMethodReference…`) proves that method references can be seen, not that direct calls on `ReplenishorderRepository` can. If the owner filter ever stopped matching (for example, a call compiled against a supertype owner), the rule would go silently green.
- **Fix.** Also assert `called` contains `findHoldersByStateLessThanAndStockunitIdOrderById` and `findById`. Both are present in SBS today.

**[L2] Orphaned `lenient()` 8-arg stubs are left in the gate tests.**
- Files:
  - `PickingorderBusinessServiceUnitTest.java:4467`, `lenient().when(stockunitBusinessService.transferStockToUnitLoad(any(), any(), any(), any(), any(), any(), eq(true), eq(true)))`;
  - `UnitloadServiceUnitTest.java:2062-2064` (`arrangeHelperCallForEitherOverload`).
- Confidence: HIGH.
- **Problem.** Production now calls only the 10-arg overload, so these stubs are dead. STRICT_STUBS does not report a lenient stub. Plan §6 asks for lenient 8/9-arg stubs to be converted by hand. The implementation log records leaving these two "as harmless". They still tell a future reader that either overload is reachable.
- **Fix.** Delete the 8-arg stubs, make the 10-arg stubs strict, and rename the helper (e.g. `arrangeHelperCall`).

**[L3] B8 asserts no end state, so the drift-skip branch runs on PostgreSQL without being checked.**
- File: `ReplenishMultiHolderMoveIT.java:358` (`stockunitService.adjustReservedAmount(detached, new BigDecimal("3"), …)`) and `:409-417`. Confidence: MEDIUM (on which rows the cut changes).
- **What runs.** The cut runs first, inside leg A, so the move's lock pass meets orders the cut has already rewritten. That is exactly the B.3/B.7 "keep only `< FINISHED` and same SU" filter, and it is otherwise covered only by mocks.
- **What is asserted.** B8 checks only "no 40P01" and "both completed".
- **Fix.** After the legs finish, assert each holder's committed state, and assert `requestedlocation_id = LOC_DST_REPLEN` for every holder still open. This costs nothing and keeps B8 deterministic.

**[L4] Two "every" claims are broader than the code.**
- Files:
  - `MovedStockUnitHolders.java:45`, `@return the locked set: every order still holding {@code stockunitId}`;
  - `ReplenishmentOrderMaintenanceService.java:246`, `Handle every active replenishment order bound to a {@link Stockunit}`.
- Confidence: HIGH.
- **Problem.** A holder inserted after the projection is not in the set. The class javadoc itself says so (*"A holder created after the projection is not seen"*), so these two sentences contradict it.
- **Fix.** Say "every order the holders projection returned that is still open and still bound to `stockunitId`" (and the equivalent in the maintenance javadoc).

**[L5] A self-move of a held SU onto its own unit load is now refused as a "displacement".**
- File: `StockunitBusinessService.java:385`. Confidence: LOW (reachability unconfirmed).
- **How.** If `destinationUnitload` is the source's own UL, `destinationStockUnit` resolves to the source itself. The merge branch adds and subtracts `amount` on the same instance, so nothing moves, but `displacing` is true when `amount == A`. A holder at R = 0 therefore triggers a REFUSE with "holds this stock".
- **Impact.** Operator error at worst, and it fails safe. Before this change the same call was a silent no-op.
- **Fix, optional:** add `&& !Objects.equals(sourceStockunit.getUnitloadId(), destinationUnitload.getId())` to `displacing`, or leave it and note it as an accepted edge in the javadoc.

**[L6] Style nits.**
- `ReplenishmentOrderSourceSyncService.java:13`: `import java.util.List;` sits between the `net.aim_ai` and `org.springframework` groups, separated by a stray blank line. Move it to the `java.*` group.
- `ReplenishmentOrderMaintenanceService.java:248`: the javadoc line is about 150 characters (`…each to another live source if one exists, else cancel it. A move onto a replenishable destination is a no-op here (it is handled by the`). Re-wrap it.
- Confidence: HIGH.

**[L7] No IT covers ALLOW_ANY displacing a sibling holder, end to end.**
- Files: `TransferStockReplenHoldGuardIT` (E1c covers only #15 with its own order) and `ReplenishMaintenanceTriggerUnitTest` (A19, unit). Confidence: MEDIUM.
- **The gap.** The #5 and #10 heal path is pinned only with the trigger mocked: the outcome must be non-empty → after-commit `recalculateForItem` → the sibling is redirected or cancelled. Plan §8.1 did not require such a test (manual row "Damage opt-in" covers it), so this is a suggestion.
- **Suggested test.** A PostgreSQL IT that damages (#10) a held SU and asserts that after commit the holder is at 800 or bound to another SU.

### Open questions (low-confidence, not blocking)

None at CRITICAL/HIGH.

### Findings that dispute the plan's DESIGN (not the code)

- **None of substance.** D1–D4 were not relitigated.
- **Informational only (Low, not counted above):** plan §5 A.1 puts a repository projection type (`ReplenishorderHolderView`) into a service-level return type (`TransferOutcome.displacedHolders`). Callers use only `isEmpty()`, so the field could be a `List<Long>` of ids, or the record could hold only a count, without changing behaviour. This is a layering preference, not a defect, and the plan chose it explicitly.
- M2 is a gap in the rail, not in the design. The design rule ("Fix A takes no order lock") holds in the code as written.

## Focus checklist (from the brief)

| Focus | Verdict |
|---|---|
| **Predicate is exactly re-parent plus drain-to-zero** | ✓ for R ≥ 0. With `fla == null`, a placeholder is created iff `A > amount`, so `A <= amount` is exactly the re-parent (`dst == null`) or the drain merge (`dst != null`, source → 0 → Nirwana). The available guard bounds `amount ≤ A − R`. See L5 for the self-move corner |
| **Runs before any write** | ✓. The A1 test pins `save` never called, `clientRepository.findById` never called and no stockrecord interaction |
| **Projection-only read; `findById` only after deciding to throw** | ✓ (A6 `times(1)`, ALLOW_ANY `never()`). A14 fences the direct-call mechanism, except M2 |
| **Vanished-row fallback** | ✓ Fix A (A8, plus the PIT kill test). ✓ Fix B (`b37f0d1a` tests) |
| **Sibling filter null-safe** | ✓ `Objects.equals(h.getNumber(), orderNumber)`. The `null == null` corner is unreachable because `replenishorder.number` is `NOT NULL` (`V2.2.00`) |
| **WARN tokens** | ✓ `REPLEN_HELD_REFUSED su= ul= code= holder=N@s` and `REPLEN_HELD_DISPLACED … holders=[N@s,…]`, SLF4J-parameterised, captured by `ListAppender` in A10/A11 |
| **Fix B lock order** | ✓ Projection pre-check (no lock) → holders ascending → SU once (non-replenishable path only). This matches the 3622 cut (`findHolders…OrderById` → SU) and the cron (per item, ascending id, order → SU). No new edge: the UL↔order ABBA with the finish and the cross-SU SU→order edge are pre-existing and stated in §4. B8 forced the contention and it serialised (pid 148 waited on 147, no 40P01) |
| **Drift** | ✓ The locked set keeps only `< FINISHED && stockunitId == su`, with a re-check under lock before any write (B3, plus the PIT kill for `<=`) |
| **Share read live per order** | ✓ `shareOf(order, lockedSource)` runs inside the loop. B7 kills the snapshot-once mutant. **Recorded equivalent mutant (plan §8.1 B7, Ar R2.2(d)): "every share computed upfront, before the first redirect" survives B7 by construction.** In that fixture the upfront `others` sums give the same own-shares (3 and 5) as the live reads. Do not "repair" B7 to kill it |
| **`MovedStockUnitHolders` shape** | ✓ package-private, `final`, private constructor, one static method. The javadoc matches the code (L4 aside). Passing the repository as an argument is what opens M2 |
| **Opt-ins: trigger only when displaced** | ✓ `requestIfDisplaced` returns early on an empty list (A19). #12 adds no trigger (A18 reflection plus the `setLockDamaged` `times(1)`). #15 adds no heal by design |
| **DI cycles** | ✓ The repository goes into SBS and the trigger into PBS; `StockunitService` already held the trigger. The full context loads (the ITs ran) |
| **`TransferOutcome` never null-checked** | Safe. The 10-arg overload always returns `new TransferOutcome(destinationStockUnit, …)`. `destinationStockUnit` is non-null on every branch (`createStockUnit`, `save(source)`, or the locked destination SU), and the compact constructor enforces it. Under test, an unstubbed mock returns null, which NPEs loudly. The one swallowing `catch (Exception ignored)` (`PickingorderBusinessServiceUnitTest:505`) now has a strict 10-arg stub, so it cannot hide that |
| **Vacuous or weakened assertions** | None weakened. Removed 8-arg verifies were replaced by 10-arg verifies pinning `eq(ReplenHoldPolicy.ALLOW_ANY)`. Rail inventory decrements in `NeverMatcherNullBlindnessArchTest` each carry a reason. See L1 (A14 floor) and M1 (missing row) |
| **Lenient stubs** | Guard-test holder and `findById` stubs are lenient, with a stated reason, and are backed by `times(1)` / `never()` counts. See L2 for the orphans |
| **Rails A13, A14, A20 non-vacuous** | A13 ✓ (equality map plus a floor ≥ 4). A20 ✓ (positive control ≥ 3, five planted shapes, a non-offender, floor 19). A14: reference rule ✓ (positive control plus planted shape); subset rule has no floor (L1); helper blind spot (M2) |
| **B8 deterministic** | ✓ Latch-forced, with a `pg_stat_activity` / `pg_blocking_pids` positive control inside a 10 s window, and an early exit if leg B finishes. No race on the property under test. The 10 s is a bound on B *starting*, not on lock timing |
| **IT cleanup on the reused container** | ✓ `wipe()` runs in both `@BeforeEach` and `@AfterEach`, children first, keyed on dedicated client ids 37550 and 37570. The id bands do not collide. Both classes are registered in `TestClassTransactionManagerArchTest`, with a reason |
| **Hygiene** | `@Transactional(value = "tenantTransactionManager", …)` on the new overload ✓. Constructor injection ✓. SLF4J parameterised ✓. Log tokens carry no other method's name ✓. Comments are accurate except L4 and L6 |

## Positive observations

- **Decision before load.** The guard decides on the locked branch variables, after the SU lock and before the first write, and loads an entity only once it has decided to refuse. The javadoc explains both residuals (TOCTOU, ALLOW_ANY over STARTED) instead of hiding them.
- **One copy of the lock order.** `MovedStockUnitHolders` keeps a single copy of the Fix B lock-order prefix. Two hand-maintained copies would be the classic place for the ascending order to drift.
- **Disarm-proof `never()`.** H1 (`TransferVerifications` plus the A20 text rail plus a floor) is a real fix for the overload-disarm hazard, and it is self-tested with null slots per overload.
- **Strong B7 fixture.** The moved SU is fully reserved, so it can never be a redirect candidate, and the amounts are distinct, so the snapshot mutant is killed on PostgreSQL, not only in mocks.
- **The rail fix was honest.** A14's first version missed inherited-method handles. The implementer found this by mutation, measured it with `javap`, and fixed the rail rather than the mutant.
- **Strict when it matters.** The swallowing `catch (Exception ignored)` test at `PickingorderBusinessServiceUnitTest:505` was given a strict 10-arg stub, so an NPE from a null outcome cannot hide there.

## Recommendation

**COMMENT.** No High at high confidence, and the code does what plan §5 designed. Fix M1 (one missing test row per service) and M2 (close or document the helper-delegation route around A14) before the PR. Per the repo's "fix every finding, Low included" rule, also fix L1–L4 and L6. L5 and L7 are optional.

---

## Round 2 (fix commits)

```
head: 75346acda98f5a60bbd625f766df15a156af2cfa
range: b37f0d1a..75346acd (d908efb6 M1, 11af88b5 M2+L1, 3dfe7a1a L5, ab56eb20 L4+L6, e5b71d78 L2, 292b8cd8 L3, f7fe0883 SEC-1, 75346acd L7)
verdict: APPROVE (round 2: 0 High, 0 Medium, 1 Low; all round-1 findings resolved)
```

### What I read and ran

- Read `git diff b37f0d1a..HEAD` in full: 4 production files and 8 test files. Read the "Review round 1 fixes" section of `implementation-log.md`.
- **Mutant probes, all KILLED.** Each was applied to the real file, run, and then restored from a scratchpad copy by `scratchpad/r2/mut.sh`.

  | Probe | Mutant | Result |
  |---|---|---|
  | M1 | `blocking != null && blocksMove(blocking)` in `MovedStockUnitHolders` | Killed by both new tests (`…SourceSyncServiceTest$MultiHolder` 12/1 F, `…ReassignTest` 21/1 F) |
  | M2 | `probeA14() { return MovedStockUnitHolders.lockForMove(replenishorderRepository, id); }` added to SBS | Killed by **both** new rules (rail 8 run, 2 F) |
  | SEC-1 (a) | 3dfe7a1a's predicate restored (`Objects.equals(sourceStockunit.getUnitloadId(), destinationUnitload.getId())`) | Killed by `…shouldRefuse_whenOwnUnitLoadHoldsASameItemSiblingListedFirst` |
  | SEC-1 (b) | `&& !selfMerge` dropped | Killed by `…shouldNotRefuse_whenDestinationIsTheSourcesOwnUnitLoad` |
  | L7 | `requestIfDisplaced(damageTransfer, …)` deleted in `StockunitService` | Killed by the L7 IT (6 run, 1 F: `expected 800 but was 300` per the log) |
- **At HEAD:** the unit set (10 patterns) ran **293, 0 F/E**. The ITs `ReplenishMultiHolderMoveIT` and `TransferStockReplenHoldGuardIT` ran **10, 0 F/E**, BUILD SUCCESS. The B8 control fired: blocked pid 149, blocking pid 148, no 40P01.
- That last run recompiled `target/classes` from clean sources. `git status` is clean.

### (1) Round-1 findings: resolved?

| Finding | Resolved | Evidence |
|---|---|---|
| **M1** | ✓ | Tests only, as intended. Both tests project `holder(9L, STARTED, "REPL-9")`, stub `findById(9)` to return a row at `PROCESSABLE`, assert `isInstanceOf(BusinessException.class).hasMessageContaining("REPL-9")` and `verify(replenishorderRepository, never()).findByIdForUpdate(any())`. Under the mutant, the unstubbed `findByIdForUpdate` returns `Optional.empty()`, nothing throws, and the assertion fails. Killed, and the kill is attributable |
| **M2** | ✓ | `replenRepositoryPassedAsArgument` flags a read of the `replenishorderRepository` field on the same line as any call (not one *on* the repository) that has a parameter type `T` with `T.isAssignableFrom(ReplenishorderRepository)` and `T` not `Object`. `sbs_shouldNotAccessMovedStockUnitHolders` bans the class outright. Both rules have a production positive control (`ReplenishmentOrderSourceSyncService` passes the repository to `lockForMove` legitimately) and a planted self-test. The blind-spot javadoc now names a local copy of the field and another bean holding its own repository. See R2-L1 for one more |
| **L1** | ✓ | `.containsAll(ALLOWED)` follows `.isSubsetOf(ALLOWED)` |
| **L2** | ✓ | The 8-arg stub is deleted in `$Sbdev3755ConfirmPickOptIn` and the 10-arg stub is now a strict `when(...)`. `arrangeHelperCallForEitherOverload` is removed and A18 uses the strict `arrangeHelperCall` |
| **L3** | ✓ | B8 now asserts the committed state after both legs: `state(R9) == CANCELED`, `state(R5) == PROCESSABLE`, `requestedLocation(R5) == LOC_DST_REPLEN`, `requestedLocation(R9) == LOC_SRC` (the drift filter skipped it), `boundStockUnit(R5) == SU_MOVED`, `reserved(SU_MOVED) == 3`. These are deterministic: the cut runs entirely before the move's lock pass (latch plus `pg_blocking_pids` control) and cuts newest-first by `created` (R9 is seeded 1 h old, R5 2 h). No new rows, so the existing `wipe()` covers it |
| **L4** | ✓ | `@return … every order the holders projection returned that is still open and still bound to {@code stockunitId} under lock … A holder created after the projection is not in it`. The maintenance and sync javadocs say the same |
| **L5** | ✓ via SEC-1 | 3dfe7a1a is superseded by f7fe0883 (below) |
| **L6** | ✓ | `import java.util.List;` is in the `java.*` group; the javadoc is re-wrapped |
| **L7** | ✓ | `transferStock_shouldHealDisplacedHolderAfterCommit_whenWholeHeldStockUnitIsDamaged`. Y is still on the UL, so this takes the `transferStockToUnitLoad` Damaged arm (#10), not the whole-container route. The after-commit callback runs synchronously inside `transferStock`'s commit, so `replenState() == CANCELED` is read after the heal. No timing dependency. The probe shows the kill is attributable to `requestIfDisplaced`. **Cleanup:** the damaged container is minted with the stock's client (`createUnitload(…, client.getId(), …)`) and is deleted by `wipe()`'s `unitload WHERE client_id`. The cancel and release rows are stockrecords under the same client. Neither `StockunitService` nor the maintenance service writes to the outbox or notifies OMS on this path, so nothing outside `wipe()` is left behind |

### SEC-1: adversarial check of `f7fe0883`

The code:
```java
boolean selfMerge = destinationStockUnit != null
    && Objects.equals(destinationStockUnit.getId(), sourceStockunit.getId());
boolean displacing = fixLocationAssignment == null && sourceStockunit.getAmount().compareTo(amount) <= 0
    && !selfMerge;
```

**Can a displacement still escape the guard?** I went through every shape that can re-parent the source or drain it to 0:

- **Re-parent branch** (`destinationStockUnit == null`, `fla == null`, `A <= amount`). `selfMerge` is false, so the guard applies. A re-parent onto the source's *own* UL cannot happen: the source is in that UL's `findByUnitloadId` list, so a same-item `destinationStockUnit` always resolves.
- **Drain into a sibling** (`destinationStockUnit` is a same-item SU with another id). This holds wherever that SU sits, including the source's own UL and either list order. `selfMerge` is false, so it is guarded. This is the SEC-1 shape, and probe SEC-1 (a) shows the test pins it.
- **`destinationStockUnit` equals the source by some other path.** None exists. The candidate list is `findByUnitloadId(destinationUnitloadId)`, re-read after the destination-UL lock. It can contain the source only when `destinationUnitload` is the source's own UL, whose id is read from the source after the source's `FOR UPDATE`.
- **List order on the own UL.** If a sibling is first, it is the merge target and the move is guarded (SEC-1). If the source is first, it is the merge target, which is a self-merge and a no-op (below). Under `findByUnitloadId`'s unordered result either outcome is correct for its own case.
- **FLA edge.** With `fla != null`, `displacing` is false, as plan §5 A.2 decided. That branch never re-parents (placeholder) and never sends the source to Nirwana (the merge's Nirwana step requires `fla == null`). The source stays at ≥ 0 on its location, which is the plan's accepted "FLA drain-to-zero" edge that heals at 300. Not an escape introduced here.
- **`reservedamount < 0`.** Here `amount` can exceed `A`. Any non-self-merge with `A <= amount` is guarded (over-approximation, accepted). A self-merge with `amount > A` is still a no-op on one instance.
- **Concurrency.** The source is locked before its `unitloadId` is read, and the destination list is re-read under the destination-UL lock. `selfMerge` uses only post-lock values.

**Result: no remaining shape lets a re-parent or drain-to-zero of the source escape the guard.**

**Does `selfMerge` mean exactly "nothing moves"?** Yes. `LockReads.forUpdate` returns the persistence context's managed instance when the entity is already loaded (`getPersistenceContextInternal().getEntity(...)`). So `destinationStockUnit` and `sourceStockunit` are **the same Java instance** whenever their ids match. The merge branch then runs `setAmount(A + amount)` followed by `setAmount((A + amount) − amount) = A` on that one row, and the Nirwana condition (`amount == 0`) is false. No re-parent, no drain, no Nirwana.

The branch still writes two stockrecords (−amount / +amount on the same SU). That is pre-existing behaviour of a self-merge and is not a displacement. Keying on the id rather than on instance identity is equivalent in production, since one persistence context gives one instance per id. The L5 unit test returns the same instance from both lock reads, so it models production correctly.

### (3) M1 projected 500, not 400: correct

`ReplenishmentOrderMessages.blocksMove(Integer state)` returns `state != null && state >= WmsConstants.State.STARTED`, where `STARTED = 500` and `RESERVED = 400`. A 400 projection does not block, so it would never enter the pre-check branch the mutant changes, and the test would prove nothing. **My round-1 M1 text ("projected holder 9 @400") was wrong. The implementer was right to use 500.**

### (2) New defects introduced by the fixes

**[R2-L1] The M2 argument rule cannot see a helper whose parameter is `Object` or an unbounded generic.** Severity Low, confidence MEDIUM.
- File: `StockunitBusinessServiceReplenLockFenceArchTest.java`, in `replenRepositoryPassedAsArgument`:
  ```java
  .anyMatch(t -> t.isAssignableFrom(ReplenishorderRepository.class) && !t.isEquivalentTo(Object.class));
  ```
- **The gap.** Excluding `Object` avoids false positives (logging, `Objects.requireNonNull`). But an unbounded generic parameter (`static <R> … lock(R repo, …)`) erases to `Object` in bytecode, so the field passed to such a helper would not be flagged. The `MovedStockUnitHolders` ban covers only that one class.
- **Not exploitable today.** No such helper exists, and the subset and method-reference rules still cover direct use.
- **Fix.** Name "`Object`-typed or unbounded-generic parameters" in the blind-spot javadoc. Alternatively, keep `Object` parameters in scope and allow-list the known harmless callees (`Objects.requireNonNull`, SLF4J).

No other new defects:
- The L2 stub conversion is strict, and the A16/A18 tests stay green.
- The L3 assertions are stable (see above).
- The SEC-1 change leaves the ReplenHoldGuard suite green (21/0) and adds no new branch beyond the exclusion.
- L4 and L6 are comment and import changes only.

### Findings that dispute the design

None. The `selfMerge` exclusion is a refinement inside the D1 predicate ("re-parent and drain-to-zero only"): a self-merge is neither.

### Round 2 counts and recommendation

**0 High, 0 Medium, 1 Low (R2-L1). APPROVE.** Every round-1 finding is resolved, and the four mutant-bearing fixes (M1, M2, SEC-1, L7) are each proven to kill their mutant. R2-L1 is a javadoc-level blind spot in a rail and does not block. Under the repo's "fix Low too" rule it is a one-line javadoc addition.

---

## Round 3 (06e79608)

```
head: 06e79608b25344a77446837875ba06a4079087b4
scope: git show 06e79608 (R2-L1 fix: M2 rail covers Object-erased parameters; allow-list {java.util.Optional#orElse})
verdict: APPROVE (round 3: 0 High, 0 Medium, 2 Low; R2-L1 resolved)
```

### Probes

Each probe was applied to the real file, run against `StockunitBusinessServiceReplenLockFenceArchTest` (9 tests), and restored from a scratchpad copy. At HEAD the rail is 9/0, the guard test 21/0 and the self-move test 2/0. `javap` shows no probe left in `target/classes`, and `git status` is clean.

| # | Probe (in SBS unless noted) | Result |
|---|---|---|
| P1 | Generic-helper mutant: `private static <R> R lockAnything(R r, Long id)` plus `return lockAnything(replenishorderRepository, id);` | **KILLED** by `sbs_shouldNotPassReplenishorderRepositoryAsArgument` |
| P2 | Allow-list abuse, bare: `return java.util.Optional.empty().orElse(replenishorderRepository);` | **Survives**: `orElse` is exempt whatever its argument (see R3-L2) |
| P3 | Allow-list abuse, chained to a helper on one line: `lockAnything(Optional.empty().orElse(replenishorderRepository), id)` | **KILLED**. `lockAnything` is not exempt, and the field read is on its line |
| P4 | Allow-list abuse, chained to a lock: `((ReplenishorderRepository) Optional.empty().orElse(replenishorderRepository)).findByIdForUpdate(id)` | **KILLED** by the subset rule (`findByIdForUpdate` is not in `ALLOWED`) |
| P5 | Non-vacuity of the new clause (test file): drop `t.isEquivalentTo(Object.class) \|\|` | **KILLED** by the new planted self-test. This also confirms the commit's claim that ArchUnit does not treat an interface as assignable to `Object`, so the explicit clause is load-bearing |
| P6 | Allow-list necessity (test file): `HARMLESS_OBJECT_CALLEES = Set.of()` | **Red** on the SBS rule. The `Optional#orElse` entry really is needed today; it was not added on speculation |

### Questions

**Is the rail non-vacuous?** Yes.
- **Generic shape:** the planted `lockThroughGenericHelper → lockAnything(R, Long)` self-test pins it, and is itself pinned by P5.
- **Plain helper shape:** the production positive control (`ReplenishmentOrderSourceSyncService` passes the repository to `lockForMove`) and the earlier planted test still cover it.
- **Production code:** P1 shows the rule catches a real offender in SBS.

**Can the allow-list hide a real hand-off?** Not on its own.
- The entry is keyed on the **callee only** (`owner#name`), **not the argument**, so `Optional#orElse(replenishorderRepository)` is not flagged (P2).
- But `orElse` cannot lock. Its result can only reach a lock in three ways:
  - a call **on** the repository type, caught by the subset rule (P4);
  - a hand-off to another callee on the same line, caught by the argument rule (P3);
  - a hand-off through a local on a later line. That is the already-named "field copied into a local" blind spot, and it needs no `orElse`: `var r = replenishorderRepository;` does the same.
- So the entry adds no new route. It does make the javadoc's justification narrower than the rule (R3-L2).

**Generic-helper mutant:** probed (P1), KILLED.

**Is the javadoc accurate?** Mostly. The blind-spot list now names the allow-list. Two wording issues are below.

### Findings

**[R3-L1] Two stacked javadoc blocks orphan the method's documentation.** Low, confidence HIGH.
- File: `StockunitBusinessServiceReplenLockFenceArchTest.java:166-178`.
- **Problem.** The new `/** Review R2-L1: … */` block was inserted *between* the existing method javadoc and its method:
  - the old block (`/** Calls in {@code origin} that receive the … field as an argument … takes a {@code ReplenishorderRepository} parameter … */`) now sits directly above another javadoc, attaches to nothing, and leaves `replenRepositoryPassedAsArgument` undocumented;
  - its wording "takes a `ReplenishorderRepository` parameter" is also stale, since `Object` parameters now count.
- **Fix.** Move the original block back down onto `replenRepositoryPassedAsArgument` and change it to "takes a parameter typed `Object` or a supertype of `ReplenishorderRepository`, unless the callee is on `HARMLESS_OBJECT_CALLEES`". Leave the R2-L1 block on the field.

**[R3-L2] The allow-list is keyed on the callee, but the javadoc reads as if it were keyed on the argument; nothing pins the entry as still needed.** Low, confidence HIGH.
- File: `StockunitBusinessServiceReplenLockFenceArchTest.java`, `HARMLESS_OBJECT_CALLEES` and its javadoc.
- **Problem.** The justification (*"the field read on that line is the receiver of `findById`, not an argument"*) describes the one scan hit. The rule, however, exempts **every** `Optional#orElse` call, including `orElse(replenishorderRepository)` (P2). As argued above this is harmless, but a reader could believe the argument is checked.
- **A second gap.** If the SBS line that needs the entry is ever removed, the entry becomes silently dead (P6 shows it is needed today).
- **Fix.**
  - (a) Say in the javadoc that the exemption applies to the callee whatever its argument, and that the repository returned by `orElse` is still caught by the subset rule, by the same-line argument rule, or falls into the local-copy blind spot.
  - (b) Optionally, add a one-line control asserting that the rule would flag at least one call in SBS if the allow-list were empty (P6's shape), so a dead entry turns the build red.

### Round 3 counts and recommendation

**0 High, 0 Medium, 2 Low (R3-L1, R3-L2). APPROVE.** R2-L1 is resolved: Object-erased parameters are in scope, the clause is load-bearing (P5), and the generic mutant is killed (P1). Both Lows concern javadoc and placement and do not block. Under the repo's "fix Low too" rule they are a comment move plus two sentences.

---

## Round 4 (5caf29f2)

```
head: 5caf29f2ad8f881050751888fe6686f45b134671
scope: git show 5caf29f2 (R3-L1/L2 fix: javadoc merged back onto its method; per-callee allow-list javadoc; staleness control)
verdict: APPROVE (round 4: 0 High, 0 Medium, 0 Low; R3-L1 and R3-L2 resolved)
```

### Probes

Each probe was applied to a scratchpad copy and restored with `mut.sh`.

| # | Probe | Result |
|---|---|---|
| P1 | **Staleness control.** In SBS `refuseIfHeld` (`:531`), `replenishorderRepository.findById(candidate.getId()).orElse(null)` was changed to `.orElseGet(() -> null)`. That removes the only allow-listed `Optional#orElse` hit; the parameter becomes a `Supplier`, so the argument rule stays green | **RED**: `allowList_shouldStillMatchACallInSbs_whenScanningProductionCode:232 [allow-list entry java.util.Optional#orElse no longer matches any call …]`. The control is non-vacuous and fires on exactly the stale-entry case |
| P2 | **Regression check on the refactor** into `passedAsArgument(origin, onlyAllowListed)`. The round-3 generic-helper mutant was re-applied (`lockAnything(replenishorderRepository, id)` in SBS) | **KILLED** by `sbs_shouldNotPassReplenishorderRepositoryAsArgument` (`:242`). The main rule is not weakened |

**At HEAD:** the rail is 10/0 and the guard test 21/0. `javap` shows no probe left in `target/classes`, and `git status` is clean.

### Checks

**Is the javadoc accurate?** Yes.
- `replenRepositoryPassedAsArgument` now has one javadoc, directly on the method. It lists the three conditions the code applies, in order:
  - (a) the call is not a call on the repository (`isAssignableTo(ReplenishorderRepository)` → skip);
  - (b) the callee is not on the allow-list;
  - (c) a parameter is typed `ReplenishorderRepository`, a supertype of it, or `Object`, with the reason the `Object` check is explicit (ArchUnit does not report interface → `Object`; confirmed by round-3 P5).
- The allow-list javadoc now says the exemption is **per callee, whatever the argument**. It explains why that is safe (`orElse` cannot lock; onward use on the same line is caught by the argument, finder-subset and method-reference rules) and names the residual (a local copy used on a later line, the class's existing blind spot). This matches round-3 probes P2–P4. A nested `x.orElse(y.orElse(repo))` would also be exempt, but that is still `orElse` and still cannot lock, so the claim holds.

**Is the new control non-vacuous?** Yes (P1).
- It reads `allowListedArgumentHits`, which returns only calls whose `owner#name` is **exactly** an allow-list entry. The `contains("java.util.Optional.orElse")` match therefore cannot be satisfied by an `orElseGet` description; the hit list never contains one.
- It iterates over every entry, so a future second entry is covered too.

**Were any assertions weakened?** No.
- The diff removes no assertion: it deletes only the orphaned javadoc and changes the allow-list `if`.
- The refactor keeps the old behaviour on the rule path: `allowListed != onlyAllowListed` with `onlyAllowListed = false` skips exactly the allow-listed callees, as before. P2 confirms the rule still kills.
- The test count goes 9 → 10, the new test being the control.

### Round 4 counts and recommendation

**0 High, 0 Medium, 0 Low. APPROVE.** R3-L1 and R3-L2 are resolved, and no new defect was introduced. Across rounds 1–4, every finding from this lane is closed.
